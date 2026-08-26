import Darwin
import DoryGuestMemoryShim
import DoryRendererWorkerContracts
import DoryRendererWorkerMetalTransport
import Foundation
import Metal

public enum DoryRendererWorkerBackendExecution: @unchecked Sendable {
    case success(
        payload: Data,
        descriptors: [FileHandle],
        sharedTextureHandle: MTLSharedTextureHandle? = nil
    )
    case rejected
    case outcomeUnknown
}

/// Typed, path-free boundary between the foreign renderer backend and the XPC service. Production
/// implementations must collapse implementation details into one of these audited stages; the
/// service never serializes an arbitrary `Error` or foreign-library string.
public enum DoryRendererWorkerBackendActivationError: Error, Equatable, Sendable {
    case artifactAuthority
    case rendererInitialization
    case venusCapability
    case venusContext
    case virgl2Capability
    case virgl2Context
    case sharedMemoryExport
    case fenceExport
    case capabilityReceipt

    var failureCode: DoryRendererWorkerRPCFailureCode {
        switch self {
        case .artifactAuthority:
            .bootstrapArtifactAuthorityFailed
        case .rendererInitialization:
            .bootstrapRendererInitializationFailed
        case .venusCapability:
            .bootstrapVenusCapabilityFailed
        case .venusContext:
            .bootstrapVenusContextFailed
        case .virgl2Capability:
            .bootstrapVirgl2CapabilityFailed
        case .virgl2Context:
            .bootstrapVirgl2ContextFailed
        case .sharedMemoryExport:
            .bootstrapSharedMemoryExportFailed
        case .fenceExport:
            .bootstrapFenceExportFailed
        case .capabilityReceipt:
            .bootstrapCapabilityReceiptFailed
        }
    }
}

/// Foreign-renderer adapter owned exclusively by the worker process. `execute` is a bounded
/// admission call: it may enqueue descriptor-backed work but may never synchronously wait for GPU
/// completion or copy a command stream/frame into XPC Data. Implementations may not retain an
/// input FileHandle beyond the call unless they duplicate it and make that lifetime part of the
/// resource generation they own.
public protocol DoryRendererWorkerBackend: AnyObject, Sendable {
    func activate(
        bootstrap: DoryRendererWorkerBootstrap
    ) throws -> DoryRendererCapabilityReceipt
    func execute(
        command: DoryRendererWorkerCommand,
        descriptors: [FileHandle]
    ) throws -> DoryRendererWorkerBackendExecution
    func invalidate()
}

/// Safe default for a packaged service before the audited foreign backend is linked. It returns an
/// authenticated diagnostic receipt with no acceleration claim; the service immediately closes
/// command admission. This executable can therefore never make a software or legacy renderer look
/// like the requested production tuple.
public final class DoryRendererWorkerFailClosedBackend:
    DoryRendererWorkerBackend,
    @unchecked Sendable
{
    public init() {}

    public func activate(
        bootstrap: DoryRendererWorkerBootstrap
    ) throws -> DoryRendererCapabilityReceipt {
        try DoryRendererCapabilityReceipt(
            accepting: bootstrap,
            features: [.isolatedSignedWorker],
            capsets: []
        )
    }

    public func execute(
        command _: DoryRendererWorkerCommand,
        descriptors _: [FileHandle]
    ) throws -> DoryRendererWorkerBackendExecution {
        .rejected
    }

    public func invalidate() {}
}

/// One-shot, one-workspace service state machine. Malformed runner traffic, an uncertain backend
/// outcome, or an incomplete activation receipt permanently revokes this process generation.
public final class DoryRendererWorkerService: @unchecked Sendable {
    private enum State {
        case awaitingBootstrap
        case bootstrapping
        case active(DoryRendererWorkerBootstrap)
        case failed
    }

    private enum DescriptorIdentity: Hashable {
        case filesystem(device: UInt64, inode: UInt64)
        case guestMemory(Data)
    }

    private enum ExchangeAdmission {
        case admitted(DoryRendererWorkerBootstrap)
        case rejected(DoryRendererWorkerRPCFailureCode)
    }

    private struct MutableMetrics {
        var xpcBatchCount: UInt64 = 0
        var xpcControlBytes: UInt64 = 0
        var descriptorBackedCommandBytes: UInt64 = 0
        var totalAdmissionLatencyNanoseconds: UInt64 = 0
        var maximumAdmissionLatencyNanoseconds: UInt64 = 0
        var maximumQueueDepth = 0
        var backpressureRejections: UInt64 = 0
        var replayRejections: UInt64 = 0
    }

    private let backend: any DoryRendererWorkerBackend
    private let lock = NSLock()
    private let executionQueue = DispatchQueue(
        label: "dev.dory.renderer-worker.admission",
        qos: .userInteractive
    )
    private var state: State = .awaitingBootstrap
    private var pendingCommands = 0
    private var metrics = MutableMetrics()
    /// Accessed only on executionQueue. Strict increase gives replay protection without an
    /// attacker-controlled, generation-long Set of request identities.
    private var highestAdmittedRequestID: UInt64 = 0

    public init(backend: any DoryRendererWorkerBackend) {
        self.backend = backend
    }

    public func bootstrap(exactBytes: Data) -> Data {
        let claimed = lock.withLock {
            guard case .awaitingBootstrap = state else { return false }
            state = .bootstrapping
            return true
        }
        guard claimed else {
            return failure(.bootstrapAlreadyAttempted)
        }
        let bootstrap: DoryRendererWorkerBootstrap
        do {
            bootstrap = try DoryRendererWorkerBootstrapCodec.decode(exactBytes)
        } catch {
            failGeneration()
            return failure(.invalidEnvelope)
        }
        do {
            let receipt: DoryRendererCapabilityReceipt
            do {
                receipt = try backend.activate(bootstrap: bootstrap)
            } catch let error as DoryRendererWorkerBackendActivationError {
                throw error
            } catch {
                throw DoryRendererWorkerBackendActivationError.capabilityReceipt
            }
            let receiptBytes = DoryRendererCapabilityReceiptCodec.encode(receipt)
            do {
                _ = try DoryRendererCapabilityReceiptCodec.decode(
                    receiptBytes,
                    accepting: bootstrap
                )
            } catch {
                throw DoryRendererWorkerBackendActivationError.capabilityReceipt
            }
            guard receipt.productionAccelerationIsAdmissible else {
                failGeneration()
                return try DoryRendererWorkerRPCResultCodec.encode(
                    .success(payload: receiptBytes, descriptorCount: 0)
                )
            }
            highestAdmittedRequestID = 0
            lock.withLock { state = .active(bootstrap) }
            return try DoryRendererWorkerRPCResultCodec.encode(
                .success(payload: receiptBytes, descriptorCount: 0)
            )
        } catch let error as DoryRendererWorkerBackendActivationError {
            failGeneration()
            return failure(error.failureCode)
        } catch {
            failGeneration()
            return failure(.bootstrapRejected)
        }
    }

    public func exchange(
        exactFrame: Data,
        descriptors: [FileHandle]
    ) -> (
        result: Data,
        descriptors: [FileHandle],
        sharedTextureHandle: MTLSharedTextureHandle?
    ) {
        let enqueuedAt = DispatchTime.now().uptimeNanoseconds
        let admission = reserveExchange(controlByteCount: exactFrame.count)
        guard case .admitted(let bootstrap) = admission else {
            guard case .rejected(let code) = admission else {
                return (failure(.internalFailure), [], nil)
            }
            return (failure(code), [], nil)
        }
        defer { releaseExchange() }
        return executionQueue.sync {
            recordAdmissionLatency(since: enqueuedAt)
            return executeAdmitted(
                exactFrame: exactFrame,
                descriptors: descriptors,
                bootstrap: bootstrap
            )
        }
    }

    public func metricsSnapshot() -> DoryRendererWorkerServiceMetrics {
        lock.withLock {
            DoryRendererWorkerServiceMetrics(
                xpcBatchCount: metrics.xpcBatchCount,
                xpcControlBytes: metrics.xpcControlBytes,
                descriptorBackedCommandBytes: metrics.descriptorBackedCommandBytes,
                totalAdmissionLatencyNanoseconds: metrics.totalAdmissionLatencyNanoseconds,
                maximumAdmissionLatencyNanoseconds: metrics.maximumAdmissionLatencyNanoseconds,
                currentQueueDepth: pendingCommands,
                maximumQueueDepth: metrics.maximumQueueDepth,
                backpressureRejections: metrics.backpressureRejections,
                replayRejections: metrics.replayRejections,
                scanoutCopyBytes: 0
            )
        }
    }

    public func invalidate() {
        executionQueue.sync { failGeneration() }
    }

    private func executeAdmitted(
        exactFrame: Data,
        descriptors: [FileHandle],
        bootstrap: DoryRendererWorkerBootstrap
    ) -> (
        result: Data,
        descriptors: [FileHandle],
        sharedTextureHandle: MTLSharedTextureHandle?
    ) {
        guard case .active(let current) = lock.withLock({ state }),
              current.generation == bootstrap.generation else {
            return (failure(.capabilityUnavailable), [], nil)
        }
        do {
            let command = try DoryRendererWorkerCommandCodec.decode(
                exactFrame,
                limits: bootstrap.limits
            )
            guard command.generation == bootstrap.generation else {
                return (failure(.staleGeneration), [], nil)
            }
            guard command.deadlineUptimeNanoseconds > DispatchTime.now().uptimeNanoseconds else {
                return (failure(.deadlineExpired), [], nil)
            }
            try command.validateOutOfBandDescriptorCount(descriptors.count)
            try validateDescriptors(descriptors, references: command.sharedRegions)
            guard command.requestID > highestAdmittedRequestID else {
                recordReplayRejection()
                failGeneration()
                return (failure(.protocolViolation), [], nil)
            }
            highestAdmittedRequestID = command.requestID
            if command.operation == .submit3D {
                recordDescriptorBackedCommandBytes(command.sharedRegions[0].length)
            }
            switch try backend.execute(command: command, descriptors: descriptors) {
            case let .success(payload, replyDescriptors, sharedTextureHandle):
                guard replyDescriptors.count <= Int(UInt16.max) else {
                    failGeneration()
                    return (failure(.protocolViolation), [], nil)
                }
                guard sharedTextureHandle == nil || (
                    command.operation == .acquireScanoutLease && replyDescriptors.isEmpty
                ) else {
                    failGeneration()
                    return (failure(.protocolViolation), [], nil)
                }
                let frame = try DoryRendererWorkerRPCResultCodec.encode(
                    .success(
                        payload: payload,
                        descriptorCount: UInt16(replyDescriptors.count)
                    ),
                    maximumPayloadBytes: bootstrap.limits.maximumCommandBytes
                )
                return (frame, replyDescriptors, sharedTextureHandle)
            case .rejected:
                return (failure(.commandRejected), [], nil)
            case .outcomeUnknown:
                failGeneration()
                return (failure(.outcomeUnknown), [], nil)
            }
        } catch {
            failGeneration()
            return (failure(.protocolViolation), [], nil)
        }
    }

    private func reserveExchange(controlByteCount: Int) -> ExchangeAdmission {
        lock.withLock {
            switch state {
            case .awaitingBootstrap, .bootstrapping:
                return .rejected(.bootstrapRequired)
            case .failed:
                return .rejected(.capabilityUnavailable)
            case .active(let bootstrap):
                guard pendingCommands < bootstrap.limits.maximumInFlightCommands else {
                    metrics.backpressureRejections = Self.saturatingAdd(
                        metrics.backpressureRejections,
                        1
                    )
                    return .rejected(.resourceExhausted)
                }
                pendingCommands += 1
                metrics.maximumQueueDepth = max(metrics.maximumQueueDepth, pendingCommands)
                metrics.xpcBatchCount = Self.saturatingAdd(metrics.xpcBatchCount, 1)
                metrics.xpcControlBytes = Self.saturatingAdd(
                    metrics.xpcControlBytes,
                    UInt64(controlByteCount)
                )
                return .admitted(bootstrap)
            }
        }
    }

    private func releaseExchange() {
        lock.withLock {
            if pendingCommands > 0 { pendingCommands -= 1 }
        }
    }

    private func recordAdmissionLatency(since start: UInt64) {
        let now = DispatchTime.now().uptimeNanoseconds
        let latency = now >= start ? now - start : 0
        lock.withLock {
            metrics.totalAdmissionLatencyNanoseconds = Self.saturatingAdd(
                metrics.totalAdmissionLatencyNanoseconds,
                latency
            )
            metrics.maximumAdmissionLatencyNanoseconds = max(
                metrics.maximumAdmissionLatencyNanoseconds,
                latency
            )
        }
    }

    private func recordDescriptorBackedCommandBytes(_ byteCount: UInt64) {
        lock.withLock {
            metrics.descriptorBackedCommandBytes = Self.saturatingAdd(
                metrics.descriptorBackedCommandBytes,
                byteCount
            )
        }
    }

    private func recordReplayRejection() {
        lock.withLock {
            metrics.replayRejections = Self.saturatingAdd(metrics.replayRejections, 1)
        }
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : sum
    }

    private func validateDescriptors(
        _ descriptors: [FileHandle],
        references: [DoryRendererSharedRegionReference]
    ) throws {
        var identities = Set<DescriptorIdentity>()
        let metadata = Dictionary(grouping: references, by: \.descriptorIndex)
        for (index, descriptor) in descriptors.enumerated() {
            guard let descriptorReferences = metadata[UInt16(index)],
                  let reference = descriptorReferences.first,
                  descriptorReferences.allSatisfy({
                      $0.declaredFileSize == reference.declaredFileSize
                  }) else {
                throw DoryRendererWorkerContractError.invalidSharedRegionBounds
            }
            let fd = descriptor.fileDescriptor
            guard fd >= 0 else {
                throw DoryRendererWorkerContractError.invalidSharedRegionBounds
            }
            var status = stat()
            guard fstat(fd, &status) == 0,
                  status.st_nlink == 0,
                  status.st_size >= 0,
                  UInt64(status.st_size) == reference.declaredFileSize else {
                throw DoryRendererWorkerContractError.invalidSharedRegionBounds
            }
            let descriptorIdentity: DescriptorIdentity
            switch status.st_mode & S_IFMT {
            case S_IFREG:
                descriptorIdentity = .filesystem(
                    device: UInt64(status.st_dev),
                    inode: UInt64(status.st_ino)
                )
            case 0:
                guard descriptorReferences.allSatisfy({
                    $0.offset >= DoryGuestMemoryBackingDataOffset()
                }) else {
                    throw DoryRendererWorkerContractError.invalidSharedRegionBounds
                }
                var identity = DoryGuestMemoryBackingIdentity()
                guard DoryReadGuestMemoryBackingIdentity(
                    fd,
                    reference.declaredFileSize,
                    &identity
                ) == 1 else {
                    throw DoryRendererWorkerContractError.invalidSharedRegionBounds
                }
                descriptorIdentity = .guestMemory(
                    withUnsafeBytes(of: &identity) { Data($0) }
                )
            default:
                throw DoryRendererWorkerContractError.invalidSharedRegionBounds
            }
            let openFlags = fcntl(fd, F_GETFL)
            guard openFlags >= 0 else {
                throw DoryRendererWorkerContractError.invalidSharedRegionBounds
            }
            let accessMode = openFlags & O_ACCMODE
            switch reference.access {
            case .readOnly:
                guard accessMode == O_RDONLY else {
                    throw DoryRendererWorkerContractError.invalidSharedRegionBounds
                }
            case .readWrite:
                guard accessMode == O_RDWR else {
                    throw DoryRendererWorkerContractError.invalidSharedRegionBounds
                }
            }
            let descriptorFlags = fcntl(fd, F_GETFD)
            guard descriptorFlags >= 0,
                  fcntl(fd, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else {
                throw DoryRendererWorkerContractError.invalidSharedRegionBounds
            }
            guard identities.insert(descriptorIdentity).inserted else {
                throw DoryRendererWorkerContractError.duplicateSharedRegionIdentity
            }
        }
    }

    private func failGeneration() {
        let shouldInvalidate = lock.withLock {
            guard case .failed = state else {
                state = .failed
                return true
            }
            return false
        }
        if shouldInvalidate { backend.invalidate() }
    }

    private func failure(_ code: DoryRendererWorkerRPCFailureCode) -> Data {
        (try? DoryRendererWorkerRPCResultCodec.encode(.failure(code))) ?? Data()
    }
}
