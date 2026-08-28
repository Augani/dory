import Darwin
import DoryGuestMemoryShim
import DoryRendererWorkerContracts
import DoryRendererWorkerServiceCore
import Foundation
import Testing

@Suite struct DoryRendererWorkerServiceTests {
    @Test func failClosedExecutableNeverAdvertisesPartialAcceleration() throws {
        let bootstrap = try makeBootstrap()
        let service = DoryRendererWorkerService(
            backend: DoryRendererWorkerFailClosedBackend()
        )
        let reply = service.bootstrap(
            exactBytes: DoryRendererWorkerBootstrapCodec.encode(bootstrap)
        )
        guard case .success(let payload, 0) = try DoryRendererWorkerRPCResultCodec.decode(reply)
        else {
            Issue.record("expected a diagnostic capability receipt")
            return
        }
        let receipt = try DoryRendererCapabilityReceiptCodec.decode(
            payload,
            accepting: bootstrap
        )
        #expect(!receipt.productionAccelerationIsAdmissible)

        let command = try DoryRendererWorkerCommand(
            generation: bootstrap.generation,
            requestID: 1,
            operation: .resetAfterDeviceQuiesce,
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 1_000_000_000,
            payload: withUInt64(2)
        )
        let exchange = service.exchange(
            exactFrame: try DoryRendererWorkerCommandCodec.encode(command),
            descriptors: []
        )
        #expect(
            try DoryRendererWorkerRPCResultCodec.decode(exchange.result)
                == .failure(.capabilityUnavailable)
        )
    }

    @Test func oneSuccessfulBootstrapCannotBeReused() throws {
        let bootstrap = try makeBootstrap()
        let service = DoryRendererWorkerService(
            backend: DoryRendererWorkerFailClosedBackend()
        )
        let bytes = DoryRendererWorkerBootstrapCodec.encode(bootstrap)
        _ = service.bootstrap(exactBytes: bytes)
        #expect(
            try DoryRendererWorkerRPCResultCodec.decode(service.bootstrap(exactBytes: bytes))
                == .failure(.bootstrapAlreadyAttempted)
        )
    }

    @Test func backendActivationFailuresExposeOnlyAuditedStages() throws {
        let expected: [(DoryRendererWorkerBackendActivationError,
                        DoryRendererWorkerRPCFailureCode,
                        DoryRendererWorkerBootstrapRejectionReason)] = [
            (.artifactAuthority, .bootstrapArtifactAuthorityFailed, .artifactAuthority),
            (
                .rendererInitialization,
                .bootstrapRendererInitializationFailed,
                .rendererInitialization
            ),
            (.venusCapability, .bootstrapVenusCapabilityFailed, .venusCapability),
            (.venusContext, .bootstrapVenusContextFailed, .venusContext),
            (.virgl2Capability, .bootstrapVirgl2CapabilityFailed, .virgl2Capability),
            (.virgl2Context, .bootstrapVirgl2ContextFailed, .virgl2Context),
            (.sharedMemoryExport, .bootstrapSharedMemoryExportFailed, .sharedMemoryExport),
            (.fenceExport, .bootstrapFenceExportFailed, .fenceExport),
            (.capabilityReceipt, .bootstrapCapabilityReceiptFailed, .capabilityReceipt),
        ]
        let bytes = DoryRendererWorkerBootstrapCodec.encode(try makeBootstrap())

        for (activationError, failureCode, reason) in expected {
            let service = DoryRendererWorkerService(
                backend: RejectingActivationBackend(error: activationError)
            )
            #expect(
                try DoryRendererWorkerRPCResultCodec.decode(
                    service.bootstrap(exactBytes: bytes)
                ) == .failure(failureCode)
            )
            #expect(failureCode.bootstrapRejectionReason == reason)
            #expect(
                try DoryRendererWorkerRPCResultCodec.decode(
                    service.bootstrap(exactBytes: bytes)
                ) == .failure(.bootstrapAlreadyAttempted)
            )
        }
    }

    @Test func malformedBootstrapIsAnEnvelopeFailure() throws {
        let service = DoryRendererWorkerService(backend: AdmissibleBackend())
        #expect(
            try DoryRendererWorkerRPCResultCodec.decode(
                service.bootstrap(exactBytes: Data([0]))
            ) == .failure(.invalidEnvelope)
        )
    }

    @Test func requestIDsAreStrictlyIncreasingAndReplayFailsTheGeneration() throws {
        let bootstrap = try makeBootstrap()
        let backend = AdmissibleBackend()
        let service = DoryRendererWorkerService(backend: backend)
        _ = service.bootstrap(exactBytes: DoryRendererWorkerBootstrapCodec.encode(bootstrap))
        let command = try resetCommand(bootstrap: bootstrap, requestID: 1)
        let frame = try DoryRendererWorkerCommandCodec.encode(command)

        let first = service.exchange(exactFrame: frame, descriptors: [])
        #expect(
            try DoryRendererWorkerRPCResultCodec.decode(first.result)
                == .success(payload: Data(), descriptorCount: 0)
        )
        let replay = service.exchange(exactFrame: frame, descriptors: [])
        #expect(
            try DoryRendererWorkerRPCResultCodec.decode(replay.result)
                == .failure(.protocolViolation)
        )
        let afterReplay = service.exchange(
            exactFrame: try DoryRendererWorkerCommandCodec.encode(
                resetCommand(bootstrap: bootstrap, requestID: 2)
            ),
            descriptors: []
        )
        #expect(
            try DoryRendererWorkerRPCResultCodec.decode(afterReplay.result)
                == .failure(.capabilityUnavailable)
        )
        let metrics = service.metricsSnapshot()
        #expect(metrics.xpcBatchCount == 2)
        #expect(metrics.replayRejections == 1)
        #expect(metrics.currentQueueDepth == 0)
        #expect(metrics.scanoutCopyBytes == 0)
    }

    @Test func maximumInFlightCommandsBoundsTheSerializedAdmissionQueue() async throws {
        let limits = try DoryRendererWorkerLimits(
            maximumCommandBytes: DoryRendererWorkerLimits.production.maximumCommandBytes,
            maximumSharedRegions: DoryRendererWorkerLimits.production.maximumSharedRegions,
            maximumReferencedBytes: DoryRendererWorkerLimits.production.maximumReferencedBytes,
            maximumInFlightCommands: 1,
            maximumLiveScanoutLeases:
                DoryRendererWorkerLimits.production.maximumLiveScanoutLeases,
            maximumScanoutBytes: DoryRendererWorkerLimits.production.maximumScanoutBytes
        )
        let bootstrap = try makeBootstrap(limits: limits)
        let backend = AdmissibleBackend(blockExecution: true)
        let service = DoryRendererWorkerService(backend: backend)
        _ = service.bootstrap(exactBytes: DoryRendererWorkerBootstrapCodec.encode(bootstrap))
        let firstFrame = try DoryRendererWorkerCommandCodec.encode(
            resetCommand(bootstrap: bootstrap, requestID: 1)
        )
        let first = Task.detached {
            service.exchange(exactFrame: firstFrame, descriptors: []).result
        }
        let started: DispatchTimeoutResult = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(
                    returning: backend.executeStarted.wait(timeout: .now() + 5)
                )
            }
        }
        #expect(started == .success)

        let rejected = service.exchange(
            exactFrame: try DoryRendererWorkerCommandCodec.encode(
                resetCommand(bootstrap: bootstrap, requestID: 2)
            ),
            descriptors: []
        )
        #expect(
            try DoryRendererWorkerRPCResultCodec.decode(rejected.result)
                == .failure(.resourceExhausted)
        )
        let queued = service.metricsSnapshot()
        #expect(queued.currentQueueDepth == 1)
        #expect(queued.maximumQueueDepth == 1)
        #expect(queued.backpressureRejections == 1)

        backend.releaseExecution.signal()
        #expect(
            try DoryRendererWorkerRPCResultCodec.decode(await first.value)
                == .success(payload: Data(), descriptorCount: 0)
        )
        let completed = service.metricsSnapshot()
        #expect(completed.currentQueueDepth == 0)
        #expect(completed.xpcBatchCount == 1)
    }

    @Test func submitMetricsSeparateDescriptorCommandBytesFromXPCControl() throws {
        let bootstrap = try makeBootstrap()
        let backend = AdmissibleBackend()
        let service = DoryRendererWorkerService(backend: backend)
        _ = service.bootstrap(exactBytes: DoryRendererWorkerBootstrapCodec.encode(bootstrap))
        let (handle, byteCount) = try makeUnlinkedReadOnlyRegion()
        let region = try DoryRendererSharedRegionReference(
            identity: DoryRendererSharedRegionID(
                rawValue: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9))
            ),
            descriptorIndex: 0,
            access: .readOnly,
            offset: 0,
            length: byteCount,
            declaredFileSize: byteCount
        )
        let command = try DoryRendererWorkerCommand(
            generation: bootstrap.generation,
            requestID: 1,
            operation: .submit3D,
            contextID: 1,
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 1_000_000_000,
            sharedRegions: [region],
            limits: bootstrap.limits
        )
        let frame = try DoryRendererWorkerCommandCodec.encode(command, limits: bootstrap.limits)
        let result = service.exchange(exactFrame: frame, descriptors: [handle])
        #expect(
            try DoryRendererWorkerRPCResultCodec.decode(result.result)
                == .success(payload: Data(), descriptorCount: 0)
        )
        let metrics = service.metricsSnapshot()
        #expect(metrics.xpcBatchCount == 1)
        #expect(metrics.xpcControlBytes == UInt64(frame.count))
        #expect(metrics.descriptorBackedCommandBytes == byteCount)
        #expect(metrics.scanoutCopyBytes == 0)
        #expect(metrics.maximumAdmissionLatencyNanoseconds
            <= metrics.totalAdmissionLatencyNanoseconds)
    }

    @Test func guestMemoryPOSIXDescriptorExcludesAuthorityPage() throws {
        let dataOffset = DoryGuestMemoryBackingDataOffset()
        var identity = DoryGuestMemoryBackingIdentity()
        var declaredFileSize: UInt64 = 0
        let descriptor = DoryCreateGuestMemoryBacking(
            2 * dataOffset,
            &identity,
            &declaredFileSize
        )
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        #expect(DoryGuestMemoryBackingMatches(
            descriptor,
            declaredFileSize,
            &identity
        ) == 1)

        func exchange(offset: UInt64) throws -> DoryRendererWorkerRPCResult {
            let bootstrap = try makeBootstrap()
            let service = DoryRendererWorkerService(backend: AdmissibleBackend())
            _ = service.bootstrap(
                exactBytes: DoryRendererWorkerBootstrapCodec.encode(bootstrap)
            )
            let region = try DoryRendererSharedRegionReference(
                identity: .random(),
                descriptorIndex: 0,
                access: .readWrite,
                offset: offset,
                length: dataOffset,
                declaredFileSize: declaredFileSize
            )
            let command = try DoryRendererWorkerCommand(
                generation: bootstrap.generation,
                requestID: 1,
                operation: .attachBacking,
                resourceID: 1,
                resourceGeneration: 1,
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
                    + 1_000_000_000,
                sharedRegions: [region],
                limits: bootstrap.limits
            )
            return try DoryRendererWorkerRPCResultCodec.decode(
                service.exchange(
                    exactFrame: try DoryRendererWorkerCommandCodec.encode(
                        command,
                        limits: bootstrap.limits
                    ),
                    descriptors: [handle]
                ).result
            )
        }

        #expect(try exchange(offset: dataOffset)
            == .success(payload: Data(), descriptorCount: 0))
        #expect(try exchange(offset: 0) == .failure(.protocolViolation))
    }

    private func makeBootstrap(
        limits: DoryRendererWorkerLimits = .production
    ) throws -> DoryRendererWorkerBootstrap {
        try DoryRendererWorkerBootstrap(
            workspaceID: DoryRendererWorkspaceID(
                rawValue: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
            ),
            generation: DoryRendererWorkerGeneration(rawValue: 1),
            sourceTuple: .productionCandidate,
            producerFenceContract: .managedLinux612106PrepareFBV1,
            requestedCapabilities: .productionAcceleration,
            artifacts: DoryRendererArtifactManifest(
                candidateInventory: digest(1),
                managedGuestKernel: digest(2),
                guestMesa: digest(3),
                rendererWorkerExecutable: digest(4),
                rendererWorkerCodeDirectoryHash: try DoryCodeDirectoryHash(
                    bytes: Data(repeating: 5, count: DoryCodeDirectoryHash.byteCount)
                )
            ),
            limits: limits
        )
    }

    private func resetCommand(
        bootstrap: DoryRendererWorkerBootstrap,
        requestID: UInt64
    ) throws -> DoryRendererWorkerCommand {
        try DoryRendererWorkerCommand(
            generation: bootstrap.generation,
            requestID: requestID,
            operation: .resetAfterDeviceQuiesce,
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 1_000_000_000,
            payload: withUInt64(2),
            limits: bootstrap.limits
        )
    }

    private func makeUnlinkedReadOnlyRegion() throws -> (FileHandle, UInt64) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-renderer-command-\(UUID().uuidString)").path
        let writable = open(path, O_CREAT | O_EXCL | O_RDWR, S_IRUSR | S_IWUSR)
        guard writable >= 0 else { throw POSIXError(.EIO) }
        let byteCount: off_t = 64 * 1_024
        guard ftruncate(writable, byteCount) == 0 else {
            close(writable)
            unlink(path)
            throw POSIXError(.EIO)
        }
        let readOnly = open(path, O_RDONLY)
        guard readOnly >= 0 else {
            close(writable)
            unlink(path)
            throw POSIXError(.EIO)
        }
        guard unlink(path) == 0 else {
            close(readOnly)
            close(writable)
            throw POSIXError(.EIO)
        }
        close(writable)
        return (FileHandle(fileDescriptor: readOnly, closeOnDealloc: true), UInt64(byteCount))
    }

    private func digest(_ seed: UInt8) throws -> DoryRendererArtifactDigest {
        try DoryRendererArtifactDigest(bytes: Data(repeating: seed, count: 32))
    }

    private func withUInt64(_ value: UInt64) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}

private final class AdmissibleBackend: DoryRendererWorkerBackend, @unchecked Sendable {
    let executeStarted = DispatchSemaphore(value: 0)
    let releaseExecution = DispatchSemaphore(value: 0)
    private let blockExecution: Bool

    init(blockExecution: Bool = false) {
        self.blockExecution = blockExecution
    }

    func activate(
        bootstrap: DoryRendererWorkerBootstrap
    ) throws -> DoryRendererCapabilityReceipt {
        try DoryRendererCapabilityReceipt(
            accepting: bootstrap,
            features: .productionAcceleration,
            capsets: [capset(id: 2), capset(id: 4)]
        )
    }

    func execute(
        command _: DoryRendererWorkerCommand,
        descriptors _: [FileHandle]
    ) throws -> DoryRendererWorkerBackendExecution {
        executeStarted.signal()
        if blockExecution {
            _ = releaseExecution.wait(timeout: .now() + 5)
        }
        return .success(payload: Data(), descriptors: [])
    }

    func invalidate() {}

    private func capset(id: UInt32) throws -> DoryRendererCapsetAttestation {
        try DoryRendererCapsetAttestation(
            id: id,
            maximumVersion: id == 2 ? 1 : 0,
            data: Data(repeating: UInt8(truncatingIfNeeded: id), count: 4_096)
        )
    }
}

private final class RejectingActivationBackend:
    DoryRendererWorkerBackend,
    @unchecked Sendable
{
    private let error: DoryRendererWorkerBackendActivationError

    init(error: DoryRendererWorkerBackendActivationError) {
        self.error = error
    }

    func activate(
        bootstrap _: DoryRendererWorkerBootstrap
    ) throws -> DoryRendererCapabilityReceipt {
        throw error
    }

    func execute(
        command _: DoryRendererWorkerCommand,
        descriptors _: [FileHandle]
    ) throws -> DoryRendererWorkerBackendExecution {
        .rejected
    }

    func invalidate() {}
}
