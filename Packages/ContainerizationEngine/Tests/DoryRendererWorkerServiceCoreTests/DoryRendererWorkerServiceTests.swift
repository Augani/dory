import Darwin
import DoryGuestMemoryShim
import DoryRendererWorkerContracts
import DoryRendererWorkerServiceCore
import Foundation
import Testing

@Suite struct DoryRendererWorkerServiceTests {
    @Test func asynchronousXPCAdmissionPreservesFIFOAndBackpressureWhileCrashControlRemainsResponsive() throws {
        let production = DoryRendererWorkerLimits.production
        let limits = try DoryRendererWorkerLimits(maximumCommandBytes: production.maximumCommandBytes,
            maximumSharedRegions: production.maximumSharedRegions, maximumReferencedBytes: production.maximumReferencedBytes,
            maximumInFlightCommands: 2, maximumLiveScanoutLeases: production.maximumLiveScanoutLeases,
            maximumScanoutBytes: production.maximumScanoutBytes)
        let bootstrap = try makeBootstrap(limits: limits)
        let backend = AdmissibleBackend(blockExecution: true)
        let service = DoryRendererWorkerService(backend: backend)
        _ = service.bootstrap(exactBytes: DoryRendererWorkerBootstrapCodec.encode(bootstrap))
        let replies = AsyncServiceReplies()
        let finished = DispatchSemaphore(value: 0)
        defer { backend.releaseExecution.signal(); backend.releaseExecution.signal() }
        for requestID in UInt64(1)...2 {
            let bytes = try DoryRendererWorkerCommandCodec.encode(resetCommand(bootstrap: bootstrap, requestID: requestID))
            service.exchangeAsynchronously(exactFrame: bytes, descriptors: []) { bytes, descriptors, texture in
                #expect(descriptors.isEmpty && texture == nil)
                replies.record(requestID: requestID, bytes: bytes)
                finished.signal()
            }
        }
        try #require(backend.executeStarted.wait(timeout: .now() + 2) == .success)
        #expect(service.metricsSnapshot().currentQueueDepth == 2)
        #expect(replies.values.isEmpty)
        let rejected = AsyncServiceReplies()
        service.exchangeAsynchronously(exactFrame: try DoryRendererWorkerCommandCodec.encode(
            resetCommand(bootstrap: bootstrap, requestID: 3)), descriptors: []) { bytes, _, _ in
            rejected.record(requestID: 3, bytes: bytes)
        }
        #expect(try DoryRendererWorkerRPCResultCodec.decode(try #require(rejected.values.first?.bytes))
            == .failure(.resourceExhausted))
        #expect(service.metricsSnapshot().backpressureRejections == 1)
        let crash = DoryRendererWorkerQualificationCrashRequest(workspaceID: bootstrap.workspaceID.rawValue,
            workerGeneration: bootstrap.generation.rawValue, challenge: UUID(),
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 2_000_000_000)
        let admission = service.admitQualificationCrash(exactBytes: try crash.encoded())
        #expect(admission.accepted && admission.inFlightCommands == 2)
        #expect(replies.values.isEmpty)
        backend.releaseExecution.signal()
        try #require(finished.wait(timeout: .now() + 2) == .success)
        try #require(backend.executeStarted.wait(timeout: .now() + 2) == .success)
        backend.releaseExecution.signal()
        try #require(finished.wait(timeout: .now() + 2) == .success)
        #expect(replies.values.map(\.requestID) == [1, 2])
        for reply in replies.values {
            #expect(try DoryRendererWorkerRPCResultCodec.decode(reply.bytes) == .success(payload: Data(), descriptorCount: 0))
        }
        #expect(service.metricsSnapshot().currentQueueDepth == 0)
        #expect(service.metricsSnapshot().xpcBatchCount == 2)
    }

    @Test func qualificationCrashRejectsWrongWorkspaceGenerationMalformedAndRepeatedRequests() throws {
        let bootstrap = try makeBootstrap()
        let service = DoryRendererWorkerService(backend: AdmissibleBackend())
        let request = DoryRendererWorkerQualificationCrashRequest(workspaceID: bootstrap.workspaceID.rawValue,
            workerGeneration: bootstrap.generation.rawValue, challenge: UUID(),
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 2_000_000_000)
        #expect(!service.admitQualificationCrash(exactBytes: try request.encoded()).accepted)
        _ = service.bootstrap(exactBytes: DoryRendererWorkerBootstrapCodec.encode(bootstrap))
        #expect(!service.admitQualificationCrash(exactBytes: Data([0])).accepted)
        for invalid in [
            DoryRendererWorkerQualificationCrashRequest(workspaceID: UUID(),
                workerGeneration: bootstrap.generation.rawValue, challenge: UUID(),
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 2_000_000_000),
            DoryRendererWorkerQualificationCrashRequest(workspaceID: bootstrap.workspaceID.rawValue,
                workerGeneration: bootstrap.generation.rawValue + 1, challenge: UUID(),
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 2_000_000_000)
        ] { #expect(!service.admitQualificationCrash(exactBytes: try invalid.encoded()).accepted) }
        let accepted = service.admitQualificationCrash(exactBytes: try request.encoded())
        #expect(accepted.accepted)
        #expect(accepted.inFlightCommands == 0)
        #expect(service.metricsSnapshot().xpcBatchCount == 0)
        #expect(!service.admitQualificationCrash(exactBytes: try request.encoded()).accepted)
        service.invalidate()
        #expect(!service.admitQualificationCrash(exactBytes: try request.encoded()).accepted)
    }

    @Test func qualificationCrashDoesNotWaitForOrQuiesceAnInFlightExchange() throws {
        let bootstrap = try makeBootstrap()
        let backend = AdmissibleBackend(blockExecution: true)
        let service = DoryRendererWorkerService(backend: backend)
        _ = service.bootstrap(exactBytes: DoryRendererWorkerBootstrapCodec.encode(bootstrap))
        let frame = try DoryRendererWorkerCommandCodec.encode(resetCommand(bootstrap: bootstrap, requestID: 1))
        let finished = DispatchSemaphore(value: 0)
        Thread {
            _ = service.exchange(exactFrame: frame, descriptors: [])
            finished.signal()
        }.start()
        defer { backend.releaseExecution.signal() }
        try #require(backend.executeStarted.wait(timeout: .now() + 2) == .success)
        let request = DoryRendererWorkerQualificationCrashRequest(workspaceID: bootstrap.workspaceID.rawValue,
            workerGeneration: bootstrap.generation.rawValue, challenge: UUID(),
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 2_000_000_000)
        let accepted = service.admitQualificationCrash(exactBytes: try request.encoded())
        #expect(accepted.accepted)
        #expect(accepted.inFlightCommands == 1)
        #expect(finished.wait(timeout: .now() + 0.01) == .timedOut)
        backend.releaseExecution.signal()
        #expect(finished.wait(timeout: .now() + 2) == .success)
    }

    @Test func qualificationCrashRejectsExpiredTooShortOrUnboundedDeadlinesWithoutConsumingAdmission() throws {
        let bootstrap = try makeBootstrap()
        let service = DoryRendererWorkerService(backend: AdmissibleBackend())
        _ = service.bootstrap(exactBytes: DoryRendererWorkerBootstrapCodec.encode(bootstrap))
        let now = DispatchTime.now().uptimeNanoseconds
        for deadline in [now - 1, now + 1_000_000, now + 31_000_000_000] {
            let request = DoryRendererWorkerQualificationCrashRequest(workspaceID: bootstrap.workspaceID.rawValue,
                workerGeneration: bootstrap.generation.rawValue, challenge: UUID(), deadlineUptimeNanoseconds: deadline)
            #expect(!service.admitQualificationCrash(exactBytes: try request.encoded()).accepted)
        }
        let valid = DoryRendererWorkerQualificationCrashRequest(workspaceID: bootstrap.workspaceID.rawValue,
            workerGeneration: bootstrap.generation.rawValue, challenge: UUID(),
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 2_000_000_000)
        #expect(service.admitQualificationCrash(exactBytes: try valid.encoded()).accepted)
    }

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

    @Test func bootstrapReturnsExactlyOneArenaDescriptorWithExactDeclaredSize() throws {
        let arenaBytes = DoryRendererWorkerBootstrap.minimumHostVisibleArenaByteCount
        let bootstrap = try makeBootstrap(hostVisibleArenaByteCount: arenaBytes)
        let service = DoryRendererWorkerService(
            backend: try AdmissibleBackend(arenaByteCount: arenaBytes)
        )

        let response = service.bootstrapWithDescriptors(
            exactBytes: DoryRendererWorkerBootstrapCodec.encode(bootstrap)
        )
        defer { for descriptor in response.descriptors { try? descriptor.close() } }
        guard case .success(_, 1) = try DoryRendererWorkerRPCResultCodec.decode(
            response.result
        ) else {
            Issue.record("expected one generation arena descriptor")
            return
        }
        let descriptor = try #require(response.descriptors.first)
        var status = stat()
        #expect(fstat(descriptor.fileDescriptor, &status) == 0)
        #expect(UInt64(status.st_size) == arenaBytes)
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

    @Test func rejectedGuestResourceDoesNotFailTheWorkerGeneration() throws {
        let bootstrap = try makeBootstrap()
        let service = DoryRendererWorkerService(
            backend: AdmissibleBackend(rejectRequestID: 1)
        )
        _ = service.bootstrap(exactBytes: DoryRendererWorkerBootstrapCodec.encode(bootstrap))
        let rejected = service.exchange(
            exactFrame: try DoryRendererWorkerCommandCodec.encode(
                resetCommand(bootstrap: bootstrap, requestID: 1)
            ),
            descriptors: []
        )
        #expect(try DoryRendererWorkerRPCResultCodec.decode(rejected.result)
            == .failure(.commandRejected))
        let later = service.exchange(
            exactFrame: try DoryRendererWorkerCommandCodec.encode(
                resetCommand(bootstrap: bootstrap, requestID: 2)
            ),
            descriptors: []
        )
        #expect(try DoryRendererWorkerRPCResultCodec.decode(later.result)
            == .success(payload: Data(), descriptorCount: 0))
    }

    @Test func exhaustedGuestResourcePreservesTypedFailureAndWorkerGeneration() throws {
        let bootstrap = try makeBootstrap()
        let service = DoryRendererWorkerService(
            backend: AdmissibleBackend(exhaustRequestID: 1)
        )
        _ = service.bootstrap(exactBytes: DoryRendererWorkerBootstrapCodec.encode(bootstrap))
        let exhausted = service.exchange(
            exactFrame: try DoryRendererWorkerCommandCodec.encode(
                resetCommand(bootstrap: bootstrap, requestID: 1)
            ),
            descriptors: []
        )
        #expect(try DoryRendererWorkerRPCResultCodec.decode(exhausted.result)
            == .failure(.resourceExhausted))
        let later = service.exchange(
            exactFrame: try DoryRendererWorkerCommandCodec.encode(
                resetCommand(bootstrap: bootstrap, requestID: 2)
            ),
            descriptors: []
        )
        #expect(try DoryRendererWorkerRPCResultCodec.decode(later.result)
            == .success(payload: Data(), descriptorCount: 0))
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
        limits: DoryRendererWorkerLimits = .production,
        hostVisibleArenaByteCount: UInt64 = 0
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
            limits: limits,
            hostVisibleArenaByteCount: hostVisibleArenaByteCount
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

private final class AsyncServiceReplies: @unchecked Sendable {
    struct Reply: Sendable { let requestID: UInt64; let bytes: Data }
    private let lock = NSLock()
    private var stored = [Reply]()
    var values: [Reply] { lock.withLock { stored } }
    func record(requestID: UInt64, bytes: Data) { lock.withLock { stored.append(.init(requestID: requestID, bytes: bytes)) } }
}

private final class AdmissibleBackend: DoryRendererWorkerBackend, @unchecked Sendable {
    let executeStarted = DispatchSemaphore(value: 0)
    let releaseExecution = DispatchSemaphore(value: 0)
    private let blockExecution: Bool
    private let rejectRequestID: UInt64?
    private let exhaustRequestID: UInt64?
    private let arenaDescriptor: Int32

    init(
        blockExecution: Bool = false,
        arenaByteCount: UInt64 = 0,
        rejectRequestID: UInt64? = nil,
        exhaustRequestID: UInt64? = nil
    ) throws {
        self.blockExecution = blockExecution
        self.rejectRequestID = rejectRequestID
        self.exhaustRequestID = exhaustRequestID
        guard arenaByteCount > 0 else {
            arenaDescriptor = -1
            return
        }
        var template = Array("/tmp/dory-service-arena.XXXXXX".utf8CString)
        let descriptor = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard descriptor >= 0,
              fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
              ftruncate(descriptor, off_t(arenaByteCount)) == 0,
              template.withUnsafeBufferPointer({ unlink($0.baseAddress!) }) == 0 else {
            if descriptor >= 0 { close(descriptor) }
            throw POSIXError(.EIO)
        }
        arenaDescriptor = descriptor
    }

    convenience init(
        blockExecution: Bool = false,
        rejectRequestID: UInt64? = nil,
        exhaustRequestID: UInt64? = nil
    ) {
        try! self.init(
            blockExecution: blockExecution,
            arenaByteCount: 0,
            rejectRequestID: rejectRequestID,
            exhaustRequestID: exhaustRequestID
        )
    }

    deinit { if arenaDescriptor >= 0 { close(arenaDescriptor) } }

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
        command: DoryRendererWorkerCommand,
        descriptors _: [FileHandle]
    ) throws -> DoryRendererWorkerBackendExecution {
        executeStarted.signal()
        if blockExecution {
            _ = releaseExecution.wait(timeout: .now() + 5)
        }
        if let rejectRequestID, command.requestID == rejectRequestID { return .rejected }
        if let exhaustRequestID, command.requestID == exhaustRequestID {
            return .resourceExhausted
        }
        return .success(payload: Data(), descriptors: [])
    }

    func hostVisibleArenaDescriptor() throws -> FileHandle? {
        guard arenaDescriptor >= 0 else { return nil }
        let descriptor = dup(arenaDescriptor)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
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
