import Darwin
import DoryRendererWorkerContracts
import Foundation

enum DoryRendererWorkerVirtioCommandLaneState: Equatable, Sendable {
    case active(deviceGeneration: UInt64)
    case revoked(deviceGeneration: UInt64)
    case failed(deviceGeneration: UInt64)
}

enum DoryRendererWorkerVirtioCommandLaneError: Error, Equatable, Sendable {
    case notActive(DoryRendererWorkerVirtioCommandLaneState)
    case staleDeviceGeneration(expected: UInt64, actual: UInt64)
    case commandQueueFull(limit: Int)
    case referencedBytesLimit(limit: UInt64, requested: UInt64)
    case invalidSubmitRegions
    case inputDescriptorDuplicationFailed(index: Int)
    case localBlobTeardownRejected
    case duplicateFenceID(UInt64)
    case unexpectedWorkerReply
    case broker(DoryRendererWorkerBrokerError)

    /// True only when this result proves the submit did not mutate renderer state. Callers may
    /// publish a guest error for these cases; every other failure must retain/revoke the chain.
    var provesNoRendererMutation: Bool {
        switch self {
        case .commandQueueFull,
             .referencedBytesLimit,
             .invalidSubmitRegions,
             .inputDescriptorDuplicationFailed,
             .localBlobTeardownRejected,
             .duplicateFenceID:
            true
        case .broker(let error):
            switch error {
            case .workerRejected(.deadlineExpired),
                 .workerRejected(.resourceExhausted),
                 .workerRejected(.commandRejected),
                 .inFlightLimit,
                 .aggregateReferencedBytesLimit,
                 .deadlineExpired,
                 .deadlineTooDistant,
                 .inputDescriptorCountMismatch,
                 .invalidInputDescriptor,
                 .invalidCommand:
                true
            default:
                false
            }
        case .notActive,
             .staleDeviceGeneration,
             .unexpectedWorkerReply:
            false
        }
    }
}

struct DoryRendererWorkerVirtioCommandLaneSnapshot: Equatable, Sendable {
    let state: DoryRendererWorkerVirtioCommandLaneState
    let queuedCommands: Int
    let maximumObservedQueuedCommands: Int
    let queuedReferencedBytes: UInt64
    let rejectedAdmissions: UInt64
    let completedControlCommands: UInt64
    let completedResourceCommands: UInt64
    let completedSubmissions: UInt64
    let armedFences: Int
    let completedFences: UInt64
    let liveScanoutLeases: Int
    let acquiredScanoutLeases: UInt64
    let releasedScanoutLeases: UInt64
}

enum DoryRendererWorkerVirtioSubmissionDisposition: Equatable, Sendable {
    /// The submit was acknowledged and its fence descriptor is armed. Guest completion
    /// still belongs exclusively to the later fence-sink edge.
    case fenceArmed
    /// The worker proved that it rejected the submit before a renderer-visible mutation.
    case provenRejected(DoryRendererWorkerVirtioCommandLaneError)
    /// The submit crossed, or may have crossed, its mutation boundary without a usable fence.
    case outcomeUnknown(DoryRendererWorkerVirtioCommandLaneError)
}

enum DoryRendererWorkerScanoutAuthority: @unchecked Sendable {
    case sharedMemory(DoryRendererWorkerScanout)
    case sharedTexture(DoryRendererWorkerSharedTextureScanout)

    var workerGeneration: DoryRendererWorkerGeneration {
        switch self {
        case .sharedMemory(let value): value.lease.workerGeneration
        case .sharedTexture(let value): value.lease.workerGeneration
        }
    }

    var resourceID: UInt32 {
        switch self {
        case .sharedMemory(let value): value.lease.resourceID
        case .sharedTexture(let value): value.lease.resourceID
        }
    }

    var resourceGeneration: UInt64 {
        switch self {
        case .sharedMemory(let value): value.lease.resourceGeneration
        case .sharedTexture(let value): value.lease.resourceGeneration
        }
    }

    var leaseID: DoryRendererScanoutLeaseID {
        switch self {
        case .sharedMemory(let value): value.lease.leaseID
        case .sharedTexture(let value): value.lease.leaseID
        }
    }

    var releaseToken: DoryRendererScanoutReleaseToken {
        switch self {
        case .sharedMemory(let value): value.lease.releaseToken
        case .sharedTexture(let value): value.lease.releaseToken
        }
    }

    var pixelFormat: DoryRendererScanoutPixelFormat {
        switch self {
        case .sharedMemory(let value): value.lease.pixelFormat
        case .sharedTexture(let value): value.lease.pixelFormat
        }
    }

    var width: UInt32 {
        switch self {
        case .sharedMemory(let value): value.lease.width
        case .sharedTexture(let value): value.lease.width
        }
    }

    var height: UInt32 {
        switch self {
        case .sharedMemory(let value): value.lease.height
        case .sharedTexture(let value): value.lease.height
        }
    }

    func discardTransport() {
        if case .sharedMemory(let value) = self {
            try? value.sharedMemoryDescriptor.close()
        }
    }
}

enum DoryRendererWorkerScanoutDisposition: @unchecked Sendable {
    case acquired(DoryRendererWorkerScanoutAuthority)
    /// The worker proved it rejected acquisition before creating a live lease.
    case provenRejected(DoryRendererWorkerVirtioCommandLaneError)
    /// A live lease may exist and the entire generation was revoked.
    case outcomeUnknown(DoryRendererWorkerVirtioCommandLaneError)
}

/// Ordered asynchronous virtio-gpu command/fence seam for one authenticated worker generation.
///
/// The vCPU-facing caller performs only bounded local admission. Submit dwords stay in an
/// immutable descriptor-backed authority and commands enter one ordered task chain; no caller
/// waits synchronously for XPC or GPU completion. A worker fence descriptor is armed separately
/// and is the only authority that may publish a guest fence completion. Reset, helper death, or an
/// uncertain result revokes the complete device generation and cancels every outstanding fence.
///
/// `VirtioGPU` selects this lane only from the authenticated worker bootstrap receipt; there is no
/// in-process fallback once a worker-backed generation has been admitted.
public final class DoryRendererWorkerVirtioCommandLane: @unchecked Sendable {
    typealias Completion = @Sendable (
        Result<Void, DoryRendererWorkerVirtioCommandLaneError>
    ) -> Void
    typealias ResourceCreationCompletion = @Sendable (
        Result<UInt64, DoryRendererWorkerVirtioCommandLaneError>
    ) -> Void
    typealias BlobMappingCompletion = @Sendable (
        Result<DoryRendererWorkerBlobMapping, DoryRendererWorkerVirtioCommandLaneError>
    ) -> Void
    typealias ScanoutCompletion = @Sendable (
        DoryRendererWorkerScanoutDisposition
    ) -> Void
    /// Runs on the serialized command lane after admission and every predecessor, but before the
    /// worker sees UNMAP_BLOB. Returning false proves that no worker command was sent.
    typealias BeforeBlobUnmap = @Sendable () -> Bool
    typealias FenceSink = @Sendable (
        _ deviceGeneration: UInt64,
        _ contextID: UInt32,
        _ ringIndex: UInt32,
        _ fenceID: UInt64
    ) -> Void
    typealias RuntimeFailureSink = @Sendable (
        _ deviceGeneration: UInt64,
        _ error: DoryRendererWorkerVirtioCommandLaneError
    ) -> Void

    private final class ArmedFence {
        let source: DispatchSourceRead

        init(source: DispatchSourceRead) {
            self.source = source
        }

        func cancel() { source.cancel() }
    }

    private struct FenceKey: Hashable {
        let workerGeneration: UInt64
        let fenceID: UInt64
    }

    private struct LiveScanoutLease: Equatable, Sendable {
        let leaseID: DoryRendererScanoutLeaseID
        let resourceID: UInt32
        let resourceGeneration: UInt64
    }

    let capsets: [VirtioGPUCapset]
    let workerGeneration: DoryRendererWorkerGeneration
    /// Exact authenticated worker admission bound. VirtioGPU uses this instead of a duplicated
    /// device-side literal, so a candidate can never admit more regions than its worker accepts.
    let maximumSharedRegions: Int
    /// Exact authenticated aggregate referenced-byte authority used for target-aware resource
    /// admission before a mutating worker command crosses XPC.
    let maximumReferencedBytes: UInt64

    private let broker: DoryRendererWorkerBroker
    private let maximumQueuedCommands: Int
    private let maximumQueuedReferencedBytes: UInt64
    private let commandDeadlineNanoseconds: UInt64
    private let fenceQueue = DispatchQueue(
        label: "dev.dory.renderer-worker.fence-completion",
        qos: .userInteractive
    )
    private let lock = NSLock()
    private var state: DoryRendererWorkerVirtioCommandLaneState
    private var commandTail: Task<Void, Never>?
    private var queuedCommands = 0
    private var maximumObservedQueuedCommands = 0
    private var queuedReferencedBytes: UInt64 = 0
    private var rejectedAdmissions: UInt64 = 0
    private var completedControlCommands: UInt64 = 0
    private var completedResourceCommands: UInt64 = 0
    private var completedSubmissions: UInt64 = 0
    private var completedFences: UInt64 = 0
    private var acquiredScanoutLeases: UInt64 = 0
    private var releasedScanoutLeases: UInt64 = 0
    private var reservedFenceIDs = Set<UInt64>()
    private var armedFences = [FenceKey: ArmedFence]()
    private var liveScanoutLeases = [DoryRendererScanoutReleaseToken: LiveScanoutLease]()
    private var releasingScanoutTokens = Set<DoryRendererScanoutReleaseToken>()
    private var fenceSink: FenceSink?
    private var runtimeFailureSink: RuntimeFailureSink?

    public init(
        broker: DoryRendererWorkerBroker,
        deviceGeneration: UInt64,
        maximumQueuedCommands: Int? = nil,
        maximumQueuedReferencedBytes: UInt64? = nil,
        commandDeadlineNanoseconds: UInt64 = 5_000_000_000
    ) throws {
        guard deviceGeneration != 0,
              broker.capabilityReceipt.productionAccelerationIsAdmissible else {
            throw DoryRendererWorkerVirtioCommandLaneError.invalidSubmitRegions
        }
        let limits = broker.bootstrap.limits
        let queueLimit = maximumQueuedCommands ?? limits.maximumInFlightCommands
        let byteLimit = maximumQueuedReferencedBytes ?? limits.maximumReferencedBytes
        guard queueLimit > 0, byteLimit > 0,
              commandDeadlineNanoseconds > 0,
              commandDeadlineNanoseconds
                <= DoryRendererWorkerBroker.maximumAdmissionDeadlineNanoseconds else {
            throw DoryRendererWorkerVirtioCommandLaneError.invalidSubmitRegions
        }
        self.broker = broker
        self.workerGeneration = broker.bootstrap.generation
        self.maximumSharedRegions = limits.maximumSharedRegions
        self.maximumReferencedBytes = limits.maximumReferencedBytes
        self.capsets = broker.capabilityReceipt.capsets.map {
            VirtioGPUCapset(
                id: $0.id,
                maxVersion: $0.maximumVersion,
                data: Array($0.data)
            )
        }
        self.maximumQueuedCommands = min(queueLimit, limits.maximumInFlightCommands)
        self.maximumQueuedReferencedBytes = min(byteLimit, limits.maximumReferencedBytes)
        self.commandDeadlineNanoseconds = commandDeadlineNanoseconds
        self.state = .active(deviceGeneration: deviceGeneration)
        broker.installTerminalHandler { [weak self] _, error in
            self?.brokerTerminated(error)
        }
    }

    func installCallbacks(
        fence: @escaping FenceSink,
        runtimeFailure: @escaping RuntimeFailureSink
    ) {
        lock.withLock {
            fenceSink = fence
            runtimeFailureSink = runtimeFailure
        }
    }

    /// Exact authenticated source for GET_CAPSET_INFO/GET_CAPSET at the eventual atomic cutover.
    /// No second renderer query, cache, environment setting, or legacy object participates.
    func capset(id: UInt32, version: UInt32) -> VirtioGPUCapset? {
        capsets.first { $0.id == id && version <= $0.maxVersion }
    }

    func createContext(
        contextID: UInt32,
        capsetID: UInt32,
        name: String,
        deviceGeneration: UInt64,
        completion: @escaping Completion
    ) throws {
        guard contextID != 0 else { throw reject(.invalidSubmitRegions) }
        let payload: DoryRendererContextCreatePayload
        do {
            payload = try DoryRendererContextCreatePayload(
                capsetID: capsetID,
                name: name
            )
        } catch {
            throw reject(.invalidSubmitRegions)
        }
        try enqueueAcknowledgedControl(
            operation: .createContext,
            contextID: contextID,
            payload: payload.encoded,
            deviceGeneration: deviceGeneration,
            completion: completion
        )
    }

    func createResource3D(
        resourceID: UInt32,
        payload: DoryRendererResource3DCreatePayload,
        deviceGeneration: UInt64,
        completion: @escaping ResourceCreationCompletion
    ) throws {
        guard resourceID != 0 else { throw reject(.invalidSubmitRegions) }
        try enqueue(
            deviceGeneration: deviceGeneration,
            referencedBytes: 0,
            reservingFenceID: nil
        ) { [weak self] in
            guard let self else {
                completion(.failure(.unexpectedWorkerReply))
                return
            }
            defer { self.finishAdmission(referencedBytes: 0) }
            guard self.isActive(deviceGeneration: deviceGeneration) else {
                completion(.failure(self.inactiveError(actual: deviceGeneration)))
                return
            }
            do {
                let result = try await self.broker.execute(
                    operation: .createResource3D,
                    resourceID: resourceID,
                    payload: payload.encoded,
                    deadlineUptimeNanoseconds: self.deadline()
                )
                guard case .resourceCreated(let resourceGeneration) = result,
                      resourceGeneration != 0 else {
                    self.failGeneration(
                        deviceGeneration: deviceGeneration,
                        error: .unexpectedWorkerReply
                    )
                    completion(.failure(.unexpectedWorkerReply))
                    return
                }
                guard self.isActive(deviceGeneration: deviceGeneration) else {
                    completion(.failure(self.inactiveError(actual: deviceGeneration)))
                    return
                }
                self.lock.withLock {
                    self.completedResourceCommands = Self.saturatingAdd(
                        self.completedResourceCommands,
                        1
                    )
                }
                completion(.success(resourceGeneration))
            } catch let error as DoryRendererWorkerBrokerError {
                self.handleBrokerError(error, deviceGeneration: deviceGeneration)
                completion(.failure(.broker(error)))
            } catch {
                self.failGeneration(
                    deviceGeneration: deviceGeneration,
                    error: .unexpectedWorkerReply
                )
                completion(.failure(.unexpectedWorkerReply))
            }
        }
    }

    func destroyContext(
        contextID: UInt32,
        deviceGeneration: UInt64,
        completion: @escaping Completion
    ) throws {
        guard contextID != 0 else { throw reject(.invalidSubmitRegions) }
        try enqueueAcknowledgedControl(
            operation: .destroyContext,
            contextID: contextID,
            deviceGeneration: deviceGeneration,
            completion: completion
        )
    }

    func attachResource(
        contextID: UInt32,
        resourceID: UInt32,
        resourceGeneration: UInt64,
        deviceGeneration: UInt64,
        completion: @escaping Completion
    ) throws {
        guard contextID != 0, resourceID != 0, resourceGeneration != 0 else {
            throw reject(.invalidSubmitRegions)
        }
        try enqueueAcknowledgedControl(
            operation: .attachResource,
            contextID: contextID,
            resourceID: resourceID,
            resourceGeneration: resourceGeneration,
            deviceGeneration: deviceGeneration,
            completion: completion
        )
    }

    func detachResource(
        contextID: UInt32,
        resourceID: UInt32,
        resourceGeneration: UInt64,
        deviceGeneration: UInt64,
        completion: @escaping Completion
    ) throws {
        guard contextID != 0, resourceID != 0, resourceGeneration != 0 else {
            throw reject(.invalidSubmitRegions)
        }
        try enqueueAcknowledgedControl(
            operation: .detachResource,
            contextID: contextID,
            resourceID: resourceID,
            resourceGeneration: resourceGeneration,
            deviceGeneration: deviceGeneration,
            completion: completion
        )
    }

    func attachBacking(
        resourceID: UInt32,
        resourceGeneration: UInt64,
        regions: DoryRendererWorkerSharedRegionSet,
        deviceGeneration: UInt64,
        completion: @escaping Completion
    ) throws {
        guard resourceID != 0,
              resourceGeneration != 0,
              !regions.references.isEmpty,
              !regions.descriptors.isEmpty,
              regions.references.allSatisfy({ $0.access == .readWrite }) else {
            throw reject(.invalidSubmitRegions)
        }
        var referencedBytes: UInt64 = 0
        for region in regions.references {
            let (sum, overflow) = referencedBytes.addingReportingOverflow(region.length)
            guard !overflow else { throw reject(.invalidSubmitRegions) }
            referencedBytes = sum
        }
        let admittedReferencedBytes = referencedBytes
        let ownedDescriptors: [FileHandle]
        do {
            ownedDescriptors = try Self.duplicate(regions.descriptors)
        } catch let error as DoryRendererWorkerVirtioCommandLaneError {
            throw reject(error)
        }
        do {
            try enqueue(
                deviceGeneration: deviceGeneration,
                referencedBytes: admittedReferencedBytes,
                reservingFenceID: nil
            ) { [weak self] in
                guard let self else {
                    Self.close(ownedDescriptors)
                    completion(.failure(.unexpectedWorkerReply))
                    return
                }
                defer {
                    Self.close(ownedDescriptors)
                    self.finishAdmission(referencedBytes: admittedReferencedBytes)
                }
                guard self.isActive(deviceGeneration: deviceGeneration) else {
                    completion(.failure(self.inactiveError(actual: deviceGeneration)))
                    return
                }
                do {
                    let result = try await self.broker.execute(
                        operation: .attachBacking,
                        resourceID: resourceID,
                        resourceGeneration: resourceGeneration,
                        sharedRegions: regions.references,
                        descriptors: ownedDescriptors,
                        deadlineUptimeNanoseconds: self.deadline()
                    )
                    guard case .acknowledged = result else {
                        self.failGeneration(
                            deviceGeneration: deviceGeneration,
                            error: .unexpectedWorkerReply
                        )
                        completion(.failure(.unexpectedWorkerReply))
                        return
                    }
                    guard self.isActive(deviceGeneration: deviceGeneration) else {
                        completion(.failure(self.inactiveError(actual: deviceGeneration)))
                        return
                    }
                    self.lock.withLock {
                        self.completedResourceCommands = Self.saturatingAdd(
                            self.completedResourceCommands,
                            1
                        )
                    }
                    completion(.success(()))
                } catch let error as DoryRendererWorkerBrokerError {
                    self.handleBrokerError(error, deviceGeneration: deviceGeneration)
                    completion(.failure(.broker(error)))
                } catch {
                    self.failGeneration(
                        deviceGeneration: deviceGeneration,
                        error: .unexpectedWorkerReply
                    )
                    completion(.failure(.unexpectedWorkerReply))
                }
            }
        } catch {
            Self.close(ownedDescriptors)
            throw error
        }
    }

    func detachBacking(
        resourceID: UInt32,
        resourceGeneration: UInt64,
        deviceGeneration: UInt64,
        completion: @escaping Completion
    ) throws {
        guard resourceID != 0, resourceGeneration != 0 else {
            throw reject(.invalidSubmitRegions)
        }
        try enqueueAcknowledgedControl(
            operation: .detachBacking,
            contextID: 0,
            resourceID: resourceID,
            resourceGeneration: resourceGeneration,
            deviceGeneration: deviceGeneration,
            countsAsResourceCommand: true,
            completion: completion
        )
    }

    func transferToHost3D(
        resourceID: UInt32,
        resourceGeneration: UInt64,
        contextID: UInt32,
        payload: DoryRendererTransfer3DPayload,
        deviceGeneration: UInt64,
        completion: @escaping Completion
    ) throws {
        guard resourceID != 0, resourceGeneration != 0 else {
            throw reject(.invalidSubmitRegions)
        }
        try transfer3D(
            operation: .transferToHost3D,
            resourceID: resourceID,
            resourceGeneration: resourceGeneration,
            contextID: contextID,
            payload: payload,
            deviceGeneration: deviceGeneration,
            completion: completion
        )
    }

    func transferFromHost3D(
        resourceID: UInt32,
        resourceGeneration: UInt64,
        contextID: UInt32,
        payload: DoryRendererTransfer3DPayload,
        deviceGeneration: UInt64,
        completion: @escaping Completion
    ) throws {
        guard resourceID != 0, resourceGeneration != 0 else {
            throw reject(.invalidSubmitRegions)
        }
        try transfer3D(
            operation: .transferFromHost3D,
            resourceID: resourceID,
            resourceGeneration: resourceGeneration,
            contextID: contextID,
            payload: payload,
            deviceGeneration: deviceGeneration,
            completion: completion
        )
    }

    private func transfer3D(
        operation: DoryRendererWorkerOperation,
        resourceID: UInt32,
        resourceGeneration: UInt64,
        contextID: UInt32,
        payload: DoryRendererTransfer3DPayload,
        deviceGeneration: UInt64,
        completion: @escaping Completion
    ) throws {
        precondition(operation == .transferToHost3D || operation == .transferFromHost3D)
        try enqueueAcknowledgedControl(
            operation: operation,
            contextID: contextID,
            resourceID: resourceID,
            resourceGeneration: resourceGeneration,
            payload: payload.encoded,
            deviceGeneration: deviceGeneration,
            countsAsResourceCommand: true,
            completion: completion
        )
    }

    func unrefResource(
        resourceID: UInt32,
        resourceGeneration: UInt64,
        deviceGeneration: UInt64,
        completion: @escaping Completion
    ) throws {
        guard resourceID != 0, resourceGeneration != 0 else {
            throw reject(.invalidSubmitRegions)
        }
        try enqueueAcknowledgedControl(
            operation: .unrefResource,
            contextID: 0,
            resourceID: resourceID,
            resourceGeneration: resourceGeneration,
            deviceGeneration: deviceGeneration,
            countsAsResourceCommand: true,
            completion: completion
        )
    }

    func createBlob(
        resourceID: UInt32,
        contextID: UInt32,
        payload: DoryRendererBlobCreatePayload,
        regions: DoryRendererWorkerSharedRegionSet,
        deviceGeneration: UInt64,
        completion: @escaping ResourceCreationCompletion
    ) throws {
        guard resourceID != 0,
              regions.references.allSatisfy({ $0.access == .readWrite }),
              regions.references.isEmpty == regions.descriptors.isEmpty else {
            throw reject(.invalidSubmitRegions)
        }
        var summedReferencedBytes: UInt64 = 0
        for region in regions.references {
            let (sum, overflow) = summedReferencedBytes.addingReportingOverflow(region.length)
            guard !overflow else { throw reject(.invalidSubmitRegions) }
            summedReferencedBytes = sum
        }
        let referencedBytes = summedReferencedBytes
        let ownedDescriptors: [FileHandle]
        do {
            ownedDescriptors = try Self.duplicate(regions.descriptors)
        } catch let error as DoryRendererWorkerVirtioCommandLaneError {
            throw reject(error)
        }
        do {
            try enqueue(
                deviceGeneration: deviceGeneration,
                referencedBytes: referencedBytes,
                reservingFenceID: nil
            ) { [weak self] in
                guard let self else {
                    Self.close(ownedDescriptors)
                    completion(.failure(.unexpectedWorkerReply))
                    return
                }
                defer {
                    Self.close(ownedDescriptors)
                    self.finishAdmission(referencedBytes: referencedBytes)
                }
                guard self.isActive(deviceGeneration: deviceGeneration) else {
                    completion(.failure(self.inactiveError(actual: deviceGeneration)))
                    return
                }
                do {
                    let result = try await self.broker.execute(
                        operation: .createBlob,
                        contextID: contextID,
                        resourceID: resourceID,
                        sharedRegions: regions.references,
                        descriptors: ownedDescriptors,
                        payload: payload.encoded,
                        deadlineUptimeNanoseconds: self.deadline()
                    )
                    guard case .resourceCreated(let resourceGeneration) = result,
                          resourceGeneration != 0 else {
                        self.failGeneration(
                            deviceGeneration: deviceGeneration,
                            error: .unexpectedWorkerReply
                        )
                        completion(.failure(.unexpectedWorkerReply))
                        return
                    }
                    guard self.isActive(deviceGeneration: deviceGeneration) else {
                        completion(.failure(self.inactiveError(actual: deviceGeneration)))
                        return
                    }
                    self.lock.withLock {
                        self.completedResourceCommands = Self.saturatingAdd(
                            self.completedResourceCommands,
                            1
                        )
                    }
                    completion(.success(resourceGeneration))
                } catch let error as DoryRendererWorkerBrokerError {
                    self.handleBrokerError(error, deviceGeneration: deviceGeneration)
                    completion(.failure(.broker(error)))
                } catch {
                    self.failGeneration(
                        deviceGeneration: deviceGeneration,
                        error: .unexpectedWorkerReply
                    )
                    completion(.failure(.unexpectedWorkerReply))
                }
            }
        } catch {
            Self.close(ownedDescriptors)
            throw error
        }
    }

    func mapBlob(
        resourceID: UInt32,
        resourceGeneration: UInt64,
        deviceGeneration: UInt64,
        completion: @escaping BlobMappingCompletion
    ) throws {
        guard resourceID != 0, resourceGeneration != 0 else {
            throw reject(.invalidSubmitRegions)
        }
        try enqueue(
            deviceGeneration: deviceGeneration,
            referencedBytes: 0,
            reservingFenceID: nil
        ) { [weak self] in
            guard let self else {
                completion(.failure(.unexpectedWorkerReply))
                return
            }
            defer { self.finishAdmission(referencedBytes: 0) }
            guard self.isActive(deviceGeneration: deviceGeneration) else {
                completion(.failure(self.inactiveError(actual: deviceGeneration)))
                return
            }
            do {
                let result = try await self.broker.execute(
                    operation: .mapBlob,
                    resourceID: resourceID,
                    resourceGeneration: resourceGeneration,
                    deadlineUptimeNanoseconds: self.deadline()
                )
                guard case .blobMapping(let mapping) = result else {
                    self.failGeneration(
                        deviceGeneration: deviceGeneration,
                        error: .unexpectedWorkerReply
                    )
                    completion(.failure(.unexpectedWorkerReply))
                    return
                }
                guard self.isActive(deviceGeneration: deviceGeneration) else {
                    try? mapping.sharedMemoryDescriptor.close()
                    completion(.failure(self.inactiveError(actual: deviceGeneration)))
                    return
                }
                self.lock.withLock {
                    self.completedResourceCommands = Self.saturatingAdd(
                        self.completedResourceCommands,
                        1
                    )
                }
                completion(.success(mapping))
            } catch let error as DoryRendererWorkerBrokerError {
                self.handleBrokerError(error, deviceGeneration: deviceGeneration)
                completion(.failure(.broker(error)))
            } catch {
                self.failGeneration(
                    deviceGeneration: deviceGeneration,
                    error: .unexpectedWorkerReply
                )
                completion(.failure(.unexpectedWorkerReply))
            }
        }
    }

    /// Enforces the cross-process blob lifetime order in one serialized authority:
    ///
    /// 1. every prior worker command completes;
    /// 2. the VMM removes the guest HV mapping, munmaps its SHM view, and closes its descriptor;
    /// 3. only then may the worker release its renderer-side mapping.
    ///
    /// Admission failure never invokes `beforeWorkerUnmap`, so the caller may safely retain its
    /// local mapping and reject the guest command. Any failure after the closure ran must be treated
    /// as an uncertain mapping outcome by the caller, even when the worker proves it did not mutate.
    func unmapBlob(
        resourceID: UInt32,
        resourceGeneration: UInt64,
        deviceGeneration: UInt64,
        beforeWorkerUnmap: @escaping BeforeBlobUnmap,
        completion: @escaping Completion
    ) throws {
        guard resourceID != 0, resourceGeneration != 0 else {
            throw reject(.invalidSubmitRegions)
        }
        try enqueue(
            deviceGeneration: deviceGeneration,
            referencedBytes: 0,
            reservingFenceID: nil
        ) { [weak self] in
            guard let self else {
                completion(.failure(.unexpectedWorkerReply))
                return
            }
            defer { self.finishAdmission(referencedBytes: 0) }
            guard self.isActive(deviceGeneration: deviceGeneration) else {
                completion(.failure(self.inactiveError(actual: deviceGeneration)))
                return
            }
            guard beforeWorkerUnmap() else {
                completion(.failure(.localBlobTeardownRejected))
                return
            }
            guard self.isActive(deviceGeneration: deviceGeneration) else {
                completion(.failure(self.inactiveError(actual: deviceGeneration)))
                return
            }
            do {
                let result = try await self.broker.execute(
                    operation: .unmapBlob,
                    resourceID: resourceID,
                    resourceGeneration: resourceGeneration,
                    deadlineUptimeNanoseconds: self.deadline()
                )
                guard case .acknowledged = result else {
                    self.failGeneration(
                        deviceGeneration: deviceGeneration,
                        error: .unexpectedWorkerReply
                    )
                    completion(.failure(.unexpectedWorkerReply))
                    return
                }
                guard self.isActive(deviceGeneration: deviceGeneration) else {
                    completion(.failure(self.inactiveError(actual: deviceGeneration)))
                    return
                }
                self.lock.withLock {
                    self.completedResourceCommands = Self.saturatingAdd(
                        self.completedResourceCommands,
                        1
                    )
                }
                completion(.success(()))
            } catch let error as DoryRendererWorkerBrokerError {
                self.handleBrokerError(error, deviceGeneration: deviceGeneration)
                completion(.failure(.broker(error)))
            } catch {
                self.failGeneration(
                    deviceGeneration: deviceGeneration,
                    error: .unexpectedWorkerReply
                )
                completion(.failure(.unexpectedWorkerReply))
            }
        }
    }

    /// Acquires one SHM scanout lease after the authenticated managed guest's KMS producer wait
    /// and RESOURCE_FLUSH boundary. No duplicate renderer fence or per-frame wait is introduced.
    func acquireScanoutLease(
        resourceID: UInt32,
        resourceGeneration: UInt64,
        width: UInt32,
        height: UInt32,
        virglFormat: UInt32,
        stride: UInt32,
        storageOffset: UInt32,
        deviceGeneration: UInt64,
        completion: @escaping ScanoutCompletion
    ) throws {
        guard resourceID != 0, resourceGeneration != 0 else {
            throw reject(.invalidSubmitRegions)
        }
        try enqueue(
            deviceGeneration: deviceGeneration,
            referencedBytes: 0,
            reservingFenceID: nil
        ) { [weak self] in
            guard let self else {
                completion(.outcomeUnknown(.unexpectedWorkerReply))
                return
            }
            defer { self.finishAdmission(referencedBytes: 0) }
            guard self.isActive(deviceGeneration: deviceGeneration) else {
                completion(.outcomeUnknown(self.inactiveError(actual: deviceGeneration)))
                return
            }
            do {
                let acquirePayload = try DoryRendererScanoutAcquirePayload(
                    width: width,
                    height: height,
                    virglFormat: virglFormat,
                    stride: stride,
                    storageOffset: storageOffset
                )
                let acquireResult = try await self.broker.execute(
                    operation: .acquireScanoutLease,
                    resourceID: resourceID,
                    resourceGeneration: resourceGeneration,
                    payload: acquirePayload.encoded,
                    deadlineUptimeNanoseconds: self.deadline()
                )
                let scanout: DoryRendererWorkerScanoutAuthority
                switch acquireResult {
                case .scanout(let value):
                    scanout = .sharedMemory(value)
                case .sharedTextureScanout(let value):
                    scanout = .sharedTexture(value)
                default:
                    self.failGeneration(
                        deviceGeneration: deviceGeneration,
                        error: .unexpectedWorkerReply
                    )
                    completion(.outcomeUnknown(.unexpectedWorkerReply))
                    return
                }
                guard self.isActive(deviceGeneration: deviceGeneration) else {
                    scanout.discardTransport()
                    completion(.outcomeUnknown(self.inactiveError(actual: deviceGeneration)))
                    return
                }
                let accepted = self.lock.withLock { () -> Bool in
                    guard case .active(let activeGeneration) = self.state,
                          activeGeneration == deviceGeneration,
                          self.liveScanoutLeases[scanout.releaseToken] == nil else {
                        return false
                    }
                    self.liveScanoutLeases[scanout.releaseToken] = LiveScanoutLease(
                        leaseID: scanout.leaseID,
                        resourceID: resourceID,
                        resourceGeneration: resourceGeneration
                    )
                    self.acquiredScanoutLeases = Self.saturatingAdd(
                        self.acquiredScanoutLeases,
                        1
                    )
                    self.completedResourceCommands = Self.saturatingAdd(
                        self.completedResourceCommands,
                        1
                    )
                    return true
                }
                guard accepted else {
                    scanout.discardTransport()
                    self.failGeneration(
                        deviceGeneration: deviceGeneration,
                        error: .unexpectedWorkerReply
                    )
                    completion(.outcomeUnknown(.unexpectedWorkerReply))
                    return
                }
                completion(.acquired(scanout))
            } catch let error as DoryRendererWorkerBrokerError {
                let laneError = DoryRendererWorkerVirtioCommandLaneError.broker(error)
                if laneError.provesNoRendererMutation {
                    self.handleBrokerError(error, deviceGeneration: deviceGeneration)
                    completion(.provenRejected(laneError))
                } else {
                    self.failGeneration(deviceGeneration: deviceGeneration, error: laneError)
                    completion(.outcomeUnknown(laneError))
                }
            } catch let error as DoryRendererWorkerVirtioCommandLaneError {
                self.failGeneration(deviceGeneration: deviceGeneration, error: error)
                completion(.outcomeUnknown(error))
            } catch {
                self.failGeneration(
                    deviceGeneration: deviceGeneration,
                    error: .unexpectedWorkerReply
                )
                completion(.outcomeUnknown(.unexpectedWorkerReply))
            }
        }
    }

    /// Releases one exact live token. Replay and mismatched resource generations fail before XPC.
    func releaseScanoutLease(
        _ lease: DoryRendererScanoutLease,
        deviceGeneration: UInt64,
        completion: @escaping Completion
    ) throws {
        try releaseScanoutLease(
            workerGeneration: lease.workerGeneration,
            resourceID: lease.resourceID,
            resourceGeneration: lease.resourceGeneration,
            leaseID: lease.leaseID,
            releaseToken: lease.releaseToken,
            deviceGeneration: deviceGeneration,
            completion: completion
        )
    }

    func releaseScanoutLease(
        _ lease: DoryRendererSharedTextureScanoutLease,
        deviceGeneration: UInt64,
        completion: @escaping Completion
    ) throws {
        try releaseScanoutLease(
            workerGeneration: lease.workerGeneration,
            resourceID: lease.resourceID,
            resourceGeneration: lease.resourceGeneration,
            leaseID: lease.leaseID,
            releaseToken: lease.releaseToken,
            deviceGeneration: deviceGeneration,
            completion: completion
        )
    }

    private func releaseScanoutLease(
        workerGeneration leaseWorkerGeneration: DoryRendererWorkerGeneration,
        resourceID: UInt32,
        resourceGeneration: UInt64,
        leaseID: DoryRendererScanoutLeaseID,
        releaseToken: DoryRendererScanoutReleaseToken,
        deviceGeneration: UInt64,
        completion: @escaping Completion
    ) throws {
        try lock.withLock {
            guard case .active(let activeGeneration) = state else {
                throw rejectWhileLocked(.notActive(state))
            }
            guard activeGeneration == deviceGeneration else {
                throw rejectWhileLocked(.staleDeviceGeneration(
                    expected: activeGeneration,
                    actual: deviceGeneration
                ))
            }
            guard leaseWorkerGeneration == workerGeneration,
                  liveScanoutLeases[releaseToken] == LiveScanoutLease(
                    leaseID: leaseID,
                    resourceID: resourceID,
                    resourceGeneration: resourceGeneration
                  ),
                  releasingScanoutTokens.insert(releaseToken).inserted else {
                throw rejectWhileLocked(.invalidSubmitRegions)
            }
        }
        do {
            try enqueue(
                deviceGeneration: deviceGeneration,
                referencedBytes: 0,
                reservingFenceID: nil
            ) { [weak self] in
                guard let self else {
                    completion(.failure(.unexpectedWorkerReply))
                    return
                }
                defer { self.finishAdmission(referencedBytes: 0) }
                guard self.isActive(deviceGeneration: deviceGeneration) else {
                    completion(.failure(self.inactiveError(actual: deviceGeneration)))
                    return
                }
                do {
                    let result = try await self.broker.execute(
                        operation: .releaseScanoutLease,
                        resourceID: resourceID,
                        resourceGeneration: resourceGeneration,
                        payload: releaseToken.commandPayload,
                        deadlineUptimeNanoseconds: self.deadline()
                    )
                    guard case .acknowledged = result else {
                        self.failGeneration(
                            deviceGeneration: deviceGeneration,
                            error: .unexpectedWorkerReply
                        )
                        completion(.failure(.unexpectedWorkerReply))
                        return
                    }
                    let removed = self.lock.withLock { () -> Bool in
                        self.releasingScanoutTokens.remove(releaseToken)
                        guard self.liveScanoutLeases.removeValue(
                            forKey: releaseToken
                        ) != nil else { return false }
                        self.releasedScanoutLeases = Self.saturatingAdd(
                            self.releasedScanoutLeases,
                            1
                        )
                        self.completedResourceCommands = Self.saturatingAdd(
                            self.completedResourceCommands,
                            1
                        )
                        return true
                    }
                    guard removed else {
                        self.failGeneration(
                            deviceGeneration: deviceGeneration,
                            error: .unexpectedWorkerReply
                        )
                        completion(.failure(.unexpectedWorkerReply))
                        return
                    }
                    completion(.success(()))
                } catch let error as DoryRendererWorkerBrokerError {
                    let laneError = DoryRendererWorkerVirtioCommandLaneError.broker(error)
                    if laneError.provesNoRendererMutation {
                        _ = self.lock.withLock {
                            self.releasingScanoutTokens.remove(releaseToken)
                        }
                        self.handleBrokerError(error, deviceGeneration: deviceGeneration)
                    } else {
                        self.failGeneration(
                            deviceGeneration: deviceGeneration,
                            error: laneError
                        )
                    }
                    completion(.failure(laneError))
                } catch {
                    self.failGeneration(
                        deviceGeneration: deviceGeneration,
                        error: .unexpectedWorkerReply
                    )
                    completion(.failure(.unexpectedWorkerReply))
                }
            }
        } catch {
            _ = lock.withLock { releasingScanoutTokens.remove(releaseToken) }
            throw error
        }
    }

    func submit3D(
        contextID: UInt32,
        regions: DoryRendererWorkerSharedRegionSet,
        deviceGeneration: UInt64,
        completion: @escaping Completion
    ) throws {
        guard contextID != 0,
              regions.references.count == 1,
              regions.descriptors.count == 1,
              regions.references[0].access == .readOnly,
              regions.references[0].length > 0,
              regions.references[0].length.isMultiple(of: 4) else {
            throw reject(.invalidSubmitRegions)
        }
        let ownedDescriptors: [FileHandle]
        do {
            ownedDescriptors = try Self.duplicate(regions.descriptors)
        } catch let error as DoryRendererWorkerVirtioCommandLaneError {
            throw reject(error)
        }
        let referencedBytes = regions.references[0].length
        do {
            try enqueue(
                deviceGeneration: deviceGeneration,
                referencedBytes: referencedBytes,
                reservingFenceID: nil
            ) { [weak self] in
                guard let self else {
                    Self.close(ownedDescriptors)
                    return
                }
                defer {
                    Self.close(ownedDescriptors)
                    self.finishAdmission(referencedBytes: referencedBytes)
                }
                guard self.isActive(deviceGeneration: deviceGeneration) else {
                    completion(.failure(self.inactiveError(actual: deviceGeneration)))
                    return
                }
                do {
                    let result = try await self.broker.execute(
                        operation: .submit3D,
                        contextID: contextID,
                        sharedRegions: regions.references,
                        descriptors: ownedDescriptors,
                        deadlineUptimeNanoseconds: self.deadline()
                    )
                    guard case .acknowledged = result else {
                        self.failGeneration(
                            deviceGeneration: deviceGeneration,
                            error: .unexpectedWorkerReply
                        )
                        completion(.failure(.unexpectedWorkerReply))
                        return
                    }
                    guard self.isActive(deviceGeneration: deviceGeneration) else {
                        completion(.failure(self.inactiveError(actual: deviceGeneration)))
                        return
                    }
                    self.lock.withLock {
                        self.completedSubmissions = Self.saturatingAdd(
                            self.completedSubmissions,
                            1
                        )
                    }
                    completion(.success(()))
                } catch let error as DoryRendererWorkerBrokerError {
                    self.handleBrokerError(error, deviceGeneration: deviceGeneration)
                    completion(.failure(.broker(error)))
                } catch {
                    self.failGeneration(
                        deviceGeneration: deviceGeneration,
                        error: .unexpectedWorkerReply
                    )
                    completion(.failure(.unexpectedWorkerReply))
                }
            }
        } catch {
            Self.close(ownedDescriptors)
            throw error
        }
    }

    /// Atomically admits one descriptor-backed submit and its fence registration into the
    /// lane's ordered queue. Treating this as one local admission is essential: once the worker
    /// acknowledges the submit, backpressure must not prevent the completion boundary itself from
    /// being created. Any failure after that acknowledgement is outcome-unknown and revokes the
    /// complete worker/device generation.
    func submit3DThenCreateFence(
        contextID: UInt32,
        regions: DoryRendererWorkerSharedRegionSet,
        ringIndex: UInt32,
        fenceID: UInt64,
        contextFence: Bool,
        deviceGeneration: UInt64,
        completion: @escaping @Sendable (
            DoryRendererWorkerVirtioSubmissionDisposition
        ) -> Void
    ) throws {
        guard contextID != 0,
              fenceID != 0,
              (contextFence
                ? ringIndex <= DoryRendererFencePayload.maximumRingIndex
                : ringIndex == 0),
              regions.references.count == 1,
              regions.descriptors.count == 1,
              regions.references[0].access == .readOnly,
              regions.references[0].length > 0,
              regions.references[0].length.isMultiple(of: 4) else {
            throw reject(.invalidSubmitRegions)
        }
        let ownedDescriptors: [FileHandle]
        do {
            ownedDescriptors = try Self.duplicate(regions.descriptors)
        } catch let error as DoryRendererWorkerVirtioCommandLaneError {
            throw reject(error)
        }
        let referencedBytes = regions.references[0].length
        do {
            try enqueue(
                deviceGeneration: deviceGeneration,
                referencedBytes: referencedBytes,
                reservingFenceID: fenceID
            ) { [weak self] in
                guard let self else {
                    Self.close(ownedDescriptors)
                    completion(.outcomeUnknown(.unexpectedWorkerReply))
                    return
                }
                defer {
                    Self.close(ownedDescriptors)
                    self.finishAdmission(referencedBytes: referencedBytes)
                }
                guard self.isActive(deviceGeneration: deviceGeneration) else {
                    self.releaseFenceReservation(fenceID)
                    completion(.outcomeUnknown(
                        self.inactiveError(actual: deviceGeneration)
                    ))
                    return
                }

                var submitWasAcknowledged = false
                do {
                    let submit = try await self.broker.execute(
                        operation: .submit3D,
                        contextID: contextID,
                        sharedRegions: regions.references,
                        descriptors: ownedDescriptors,
                        deadlineUptimeNanoseconds: self.deadline()
                    )
                    guard case .acknowledged = submit else {
                        self.releaseFenceReservation(fenceID)
                        self.failGeneration(
                            deviceGeneration: deviceGeneration,
                            error: .unexpectedWorkerReply
                        )
                        completion(.outcomeUnknown(.unexpectedWorkerReply))
                        return
                    }
                    submitWasAcknowledged = true
                    self.lock.withLock {
                        self.completedSubmissions = Self.saturatingAdd(
                            self.completedSubmissions,
                            1
                        )
                    }
                    guard self.isActive(deviceGeneration: deviceGeneration) else {
                        self.releaseFenceReservation(fenceID)
                        completion(.outcomeUnknown(
                            self.inactiveError(actual: deviceGeneration)
                        ))
                        return
                    }

                    let payload = try DoryRendererFencePayload(
                        flags: contextFence ? DoryRendererFencePayload.contextTimeline : 0,
                        ringIndex: contextFence ? ringIndex : 0,
                        fenceID: fenceID
                    )
                    let fence = try await self.broker.execute(
                        operation: .createFence,
                        contextID: contextID,
                        payload: payload.encoded,
                        deadlineUptimeNanoseconds: self.deadline()
                    )
                    guard case .fence(let receipt) = fence,
                          receipt.workerGeneration == self.workerGeneration,
                          receipt.contextID == contextID,
                          receipt.flags == payload.flags,
                          receipt.ringIndex == payload.ringIndex,
                          receipt.fenceID == fenceID else {
                        self.releaseFenceReservation(fenceID)
                        self.failGeneration(
                            deviceGeneration: deviceGeneration,
                            error: .unexpectedWorkerReply
                        )
                        completion(.outcomeUnknown(.unexpectedWorkerReply))
                        return
                    }
                    try self.arm(
                        receipt: receipt,
                        deviceGeneration: deviceGeneration,
                        completionContextID: contextFence ? contextID : 0,
                        completionRingIndex: contextFence ? ringIndex : 0
                    )
                    completion(.fenceArmed)
                } catch let error as DoryRendererWorkerBrokerError {
                    self.releaseFenceReservation(fenceID)
                    let laneError = DoryRendererWorkerVirtioCommandLaneError.broker(error)
                    if !submitWasAcknowledged, laneError.provesNoRendererMutation {
                        self.handleBrokerError(error, deviceGeneration: deviceGeneration)
                        completion(.provenRejected(laneError))
                    } else {
                        self.failGeneration(
                            deviceGeneration: deviceGeneration,
                            error: laneError
                        )
                        completion(.outcomeUnknown(laneError))
                    }
                } catch let error as DoryRendererWorkerVirtioCommandLaneError {
                    self.releaseFenceReservation(fenceID)
                    self.failGeneration(deviceGeneration: deviceGeneration, error: error)
                    completion(.outcomeUnknown(error))
                } catch {
                    self.releaseFenceReservation(fenceID)
                    self.failGeneration(
                        deviceGeneration: deviceGeneration,
                        error: .unexpectedWorkerReply
                    )
                    completion(.outcomeUnknown(.unexpectedWorkerReply))
                }
            }
        } catch {
            Self.close(ownedDescriptors)
            throw error
        }
    }

    /// Enqueues a global fence behind all prior renderer mutations. Completion reports that the
    /// worker returned a validated descriptor; `fenceSink` fires only when that descriptor signals.
    func createGlobalFence(
        fenceID: UInt64,
        deviceGeneration: UInt64,
        completion: @escaping Completion
    ) throws {
        guard fenceID != 0 else { throw reject(.invalidSubmitRegions) }
        try createFence(
            contextID: 0,
            ringIndex: 0,
            fenceID: fenceID,
            contextFence: false,
            deviceGeneration: deviceGeneration,
            completion: completion
        )
    }

    /// Enqueues a context fence behind all prior renderer mutations. Completion reports that the
    /// worker returned a validated descriptor; `fenceSink` fires only when that descriptor signals.
    func createContextFence(
        contextID: UInt32,
        ringIndex: UInt32,
        fenceID: UInt64,
        deviceGeneration: UInt64,
        completion: @escaping Completion
    ) throws {
        guard contextID != 0,
              fenceID != 0,
              ringIndex <= DoryRendererFencePayload.maximumRingIndex else {
            throw reject(.invalidSubmitRegions)
        }
        try createFence(
            contextID: contextID,
            ringIndex: ringIndex,
            fenceID: fenceID,
            contextFence: true,
            deviceGeneration: deviceGeneration,
            completion: completion
        )
    }

    private func createFence(
        contextID: UInt32,
        ringIndex: UInt32,
        fenceID: UInt64,
        contextFence: Bool,
        deviceGeneration: UInt64,
        completion: @escaping Completion
    ) throws {
        try enqueue(
            deviceGeneration: deviceGeneration,
            referencedBytes: 0,
            reservingFenceID: fenceID
        ) { [weak self] in
            guard let self else { return }
            defer { self.finishAdmission(referencedBytes: 0) }
            guard self.isActive(deviceGeneration: deviceGeneration) else {
                self.releaseFenceReservation(fenceID)
                completion(.failure(self.inactiveError(actual: deviceGeneration)))
                return
            }
            do {
                let payload = try DoryRendererFencePayload(
                    flags: contextFence ? DoryRendererFencePayload.contextTimeline : 0,
                    ringIndex: contextFence ? ringIndex : 0,
                    fenceID: fenceID
                )
                let result = try await self.broker.execute(
                    operation: .createFence,
                    contextID: contextID,
                    payload: payload.encoded,
                    deadlineUptimeNanoseconds: self.deadline()
                )
                guard case .fence(let receipt) = result,
                      receipt.workerGeneration == self.workerGeneration,
                      receipt.contextID == contextID,
                      receipt.flags == payload.flags,
                      receipt.ringIndex == payload.ringIndex,
                      receipt.fenceID == fenceID else {
                    self.releaseFenceReservation(fenceID)
                    self.failGeneration(
                        deviceGeneration: deviceGeneration,
                        error: .unexpectedWorkerReply
                    )
                    completion(.failure(.unexpectedWorkerReply))
                    return
                }
                try self.arm(
                    receipt: receipt,
                    deviceGeneration: deviceGeneration,
                    completionContextID: contextFence ? contextID : 0,
                    completionRingIndex: contextFence ? ringIndex : 0
                )
                completion(.success(()))
            } catch let error as DoryRendererWorkerBrokerError {
                self.releaseFenceReservation(fenceID)
                self.handleBrokerError(error, deviceGeneration: deviceGeneration)
                completion(.failure(.broker(error)))
            } catch let error as DoryRendererWorkerVirtioCommandLaneError {
                self.releaseFenceReservation(fenceID)
                self.failGeneration(deviceGeneration: deviceGeneration, error: error)
                completion(.failure(error))
            } catch {
                self.releaseFenceReservation(fenceID)
                self.failGeneration(
                    deviceGeneration: deviceGeneration,
                    error: .unexpectedWorkerReply
                )
                completion(.failure(.unexpectedWorkerReply))
            }
        }
    }

    func revoke(deviceGeneration: UInt64) {
        let cancellation: [ArmedFence] = lock.withLock {
            guard case .active(let activeGeneration) = state,
                  activeGeneration == deviceGeneration else { return [] }
            state = .revoked(deviceGeneration: activeGeneration)
            reservedFenceIDs.removeAll(keepingCapacity: false)
            liveScanoutLeases.removeAll(keepingCapacity: false)
            releasingScanoutTokens.removeAll(keepingCapacity: false)
            let fences = Array(armedFences.values)
            armedFences.removeAll(keepingCapacity: false)
            return fences
        }
        for fence in cancellation { fence.cancel() }
        Task { await broker.invalidate() }
    }

    /// Moves an authenticated but completely unused worker lane onto the transport generation
    /// created by an initial virtio device reset. Linux writes Status=0 while probing a device;
    /// that protocol transition does not invalidate renderer state when no command, resource,
    /// fence, or scanout lease has ever crossed the worker boundary. Once any admission has
    /// occurred, reset must retain the normal fail-closed generation-replacement path.
    func rebindPristineDeviceGeneration(
        from sourceGeneration: UInt64,
        to successorGeneration: UInt64
    ) -> Bool {
        guard sourceGeneration != 0,
              successorGeneration != 0,
              sourceGeneration != successorGeneration else { return false }
        return lock.withLock {
            guard state == .active(deviceGeneration: sourceGeneration),
                  commandTail == nil,
                  queuedCommands == 0,
                  maximumObservedQueuedCommands == 0,
                  queuedReferencedBytes == 0,
                  rejectedAdmissions == 0,
                  completedControlCommands == 0,
                  completedResourceCommands == 0,
                  completedSubmissions == 0,
                  armedFences.isEmpty,
                  reservedFenceIDs.isEmpty,
                  completedFences == 0,
                  liveScanoutLeases.isEmpty,
                  releasingScanoutTokens.isEmpty,
                  acquiredScanoutLeases == 0,
                  releasedScanoutLeases == 0 else { return false }
            state = .active(deviceGeneration: successorGeneration)
            return true
        }
    }

    /// Runner-owned terminal cutover boundary. The launch owner is in the `dory-hv` executable
    /// module, so it cannot call the lane's internal reset machinery directly. This wrapper keeps
    /// the only public operation terminal and generation-bound; it does not expose command or
    /// fence mutation APIs across the module boundary.
    public func invalidate(deviceGeneration: UInt64) {
        revoke(deviceGeneration: deviceGeneration)
    }

    func snapshot() -> DoryRendererWorkerVirtioCommandLaneSnapshot {
        lock.withLock {
            DoryRendererWorkerVirtioCommandLaneSnapshot(
                state: state,
                queuedCommands: queuedCommands,
                maximumObservedQueuedCommands: maximumObservedQueuedCommands,
                queuedReferencedBytes: queuedReferencedBytes,
                rejectedAdmissions: rejectedAdmissions,
                completedControlCommands: completedControlCommands,
                completedResourceCommands: completedResourceCommands,
                completedSubmissions: completedSubmissions,
                armedFences: armedFences.count,
                completedFences: completedFences,
                liveScanoutLeases: liveScanoutLeases.count,
                acquiredScanoutLeases: acquiredScanoutLeases,
                releasedScanoutLeases: releasedScanoutLeases
            )
        }
    }

    private func enqueue(
        deviceGeneration: UInt64,
        referencedBytes: UInt64,
        reservingFenceID fenceID: UInt64?,
        operation: @escaping @Sendable () async -> Void
    ) throws {
        try lock.withLock {
            guard case .active(let activeGeneration) = state else {
                throw rejectWhileLocked(.notActive(state))
            }
            guard activeGeneration == deviceGeneration else {
                throw rejectWhileLocked(.staleDeviceGeneration(
                    expected: activeGeneration,
                    actual: deviceGeneration
                ))
            }
            guard queuedCommands < maximumQueuedCommands else {
                throw rejectWhileLocked(.commandQueueFull(limit: maximumQueuedCommands))
            }
            let (newBytes, overflow) = queuedReferencedBytes.addingReportingOverflow(
                referencedBytes
            )
            guard !overflow, newBytes <= maximumQueuedReferencedBytes else {
                throw rejectWhileLocked(.referencedBytesLimit(
                    limit: maximumQueuedReferencedBytes,
                    requested: overflow ? UInt64.max : newBytes
                ))
            }
            if let fenceID, !reservedFenceIDs.insert(fenceID).inserted {
                throw rejectWhileLocked(.duplicateFenceID(fenceID))
            }
            queuedCommands += 1
            maximumObservedQueuedCommands = max(maximumObservedQueuedCommands, queuedCommands)
            queuedReferencedBytes = newBytes
            let predecessor = commandTail
            commandTail = Task {
                if let predecessor { await predecessor.value }
                await operation()
            }
        }
    }

    private func enqueueAcknowledgedControl(
        operation: DoryRendererWorkerOperation,
        contextID: UInt32,
        resourceID: UInt32 = 0,
        resourceGeneration: UInt64 = 0,
        payload: Data = Data(),
        deviceGeneration: UInt64,
        countsAsResourceCommand: Bool = false,
        completion: @escaping Completion
    ) throws {
        try enqueue(
            deviceGeneration: deviceGeneration,
            referencedBytes: 0,
            reservingFenceID: nil
        ) { [weak self] in
            guard let self else {
                completion(.failure(.unexpectedWorkerReply))
                return
            }
            defer { self.finishAdmission(referencedBytes: 0) }
            guard self.isActive(deviceGeneration: deviceGeneration) else {
                completion(.failure(self.inactiveError(actual: deviceGeneration)))
                return
            }
            do {
                let result = try await self.broker.execute(
                    operation: operation,
                    contextID: contextID,
                    resourceID: resourceID,
                    resourceGeneration: resourceGeneration,
                    payload: payload,
                    deadlineUptimeNanoseconds: self.deadline()
                )
                guard case .acknowledged = result else {
                    self.failGeneration(
                        deviceGeneration: deviceGeneration,
                        error: .unexpectedWorkerReply
                    )
                    completion(.failure(.unexpectedWorkerReply))
                    return
                }
                guard self.isActive(deviceGeneration: deviceGeneration) else {
                    completion(.failure(self.inactiveError(actual: deviceGeneration)))
                    return
                }
                self.lock.withLock {
                    if countsAsResourceCommand {
                        self.completedResourceCommands = Self.saturatingAdd(
                            self.completedResourceCommands,
                            1
                        )
                    } else {
                        self.completedControlCommands = Self.saturatingAdd(
                            self.completedControlCommands,
                            1
                        )
                    }
                }
                completion(.success(()))
            } catch let error as DoryRendererWorkerBrokerError {
                self.handleBrokerError(error, deviceGeneration: deviceGeneration)
                completion(.failure(.broker(error)))
            } catch {
                self.failGeneration(
                    deviceGeneration: deviceGeneration,
                    error: .unexpectedWorkerReply
                )
                completion(.failure(.unexpectedWorkerReply))
            }
        }
    }

    private func finishAdmission(referencedBytes: UInt64) {
        lock.withLock {
            queuedCommands = max(0, queuedCommands - 1)
            queuedReferencedBytes = queuedReferencedBytes >= referencedBytes
                ? queuedReferencedBytes - referencedBytes
                : 0
        }
    }

    private func arm(
        receipt: DoryRendererWorkerFenceReceipt,
        deviceGeneration: UInt64,
        completionContextID: UInt32,
        completionRingIndex: UInt32
    ) throws {
        let sourceDescriptor = fcntl(
            receipt.completionDescriptor.fileDescriptor,
            F_DUPFD_CLOEXEC,
            0
        )
        try? receipt.completionDescriptor.close()
        guard sourceDescriptor >= 0 else {
            throw DoryRendererWorkerVirtioCommandLaneError
                .inputDescriptorDuplicationFailed(index: 0)
        }
        let source = DispatchSource.makeReadSource(
            fileDescriptor: sourceDescriptor,
            queue: fenceQueue
        )
        let key = FenceKey(
            workerGeneration: workerGeneration.rawValue,
            fenceID: receipt.fenceID
        )
        let armed = ArmedFence(source: source)
        source.setEventHandler { [weak self] in
            self?.fenceBecameReady(
                key: key,
                deviceGeneration: deviceGeneration,
                contextID: completionContextID,
                ringIndex: completionRingIndex,
                fenceID: receipt.fenceID
            )
        }
        source.setCancelHandler { Darwin.close(sourceDescriptor) }
        let accepted = lock.withLock { () -> Bool in
            guard case .active(let currentGeneration) = state,
                  currentGeneration == deviceGeneration,
                  armedFences[key] == nil else { return false }
            armedFences[key] = armed
            return true
        }
        guard accepted else {
            source.cancel()
            throw inactiveError(actual: deviceGeneration)
        }
        source.resume()
    }

    private func fenceBecameReady(
        key: FenceKey,
        deviceGeneration: UInt64,
        contextID: UInt32,
        ringIndex: UInt32,
        fenceID: UInt64
    ) {
        let delivery: (ArmedFence, FenceSink)? = lock.withLock {
            guard case .active(let currentGeneration) = state,
                  currentGeneration == deviceGeneration,
                  key.workerGeneration == workerGeneration.rawValue,
                  let armed = armedFences.removeValue(forKey: key) else { return nil }
            reservedFenceIDs.remove(fenceID)
            completedFences = Self.saturatingAdd(completedFences, 1)
            guard let fenceSink else {
                return (armed, { _, _, _, _ in })
            }
            return (armed, fenceSink)
        }
        guard let delivery else { return }
        delivery.0.cancel()
        delivery.1(deviceGeneration, contextID, ringIndex, fenceID)
    }

    private func releaseFenceReservation(_ fenceID: UInt64) {
        _ = lock.withLock { reservedFenceIDs.remove(fenceID) }
    }

    private func handleBrokerError(
        _ error: DoryRendererWorkerBrokerError,
        deviceGeneration: UInt64
    ) {
        switch error {
        case .workerRejected(.deadlineExpired),
             .workerRejected(.resourceExhausted),
             .workerRejected(.commandRejected),
             .inFlightLimit,
             .aggregateReferencedBytesLimit,
             .deadlineExpired:
            return
        default:
            failGeneration(deviceGeneration: deviceGeneration, error: .broker(error))
        }
    }

    private func brokerTerminated(_ error: DoryRendererWorkerBrokerError) {
        let generation: UInt64? = lock.withLock {
            guard case .active(let generation) = state else { return nil }
            return generation
        }
        guard let generation else { return }
        failGeneration(deviceGeneration: generation, error: .broker(error))
    }

    private func failGeneration(
        deviceGeneration: UInt64,
        error: DoryRendererWorkerVirtioCommandLaneError
    ) {
        let transition: (fences: [ArmedFence], sink: RuntimeFailureSink?)? = lock.withLock {
            guard case .active(let currentGeneration) = state,
                  currentGeneration == deviceGeneration else { return nil }
            state = .failed(deviceGeneration: currentGeneration)
            reservedFenceIDs.removeAll(keepingCapacity: false)
            liveScanoutLeases.removeAll(keepingCapacity: false)
            releasingScanoutTokens.removeAll(keepingCapacity: false)
            let fences = Array(armedFences.values)
            armedFences.removeAll(keepingCapacity: false)
            return (fences, runtimeFailureSink)
        }
        guard let transition else { return }
        for fence in transition.fences { fence.cancel() }
        transition.sink?(deviceGeneration, error)
        Task { await broker.invalidate() }
    }

    private func isActive(deviceGeneration: UInt64) -> Bool {
        lock.withLock {
            guard case .active(let currentGeneration) = state else { return false }
            return currentGeneration == deviceGeneration
        }
    }

    private func inactiveError(
        actual deviceGeneration: UInt64
    ) -> DoryRendererWorkerVirtioCommandLaneError {
        lock.withLock {
            if case .active(let expected) = state, expected != deviceGeneration {
                return .staleDeviceGeneration(expected: expected, actual: deviceGeneration)
            }
            return .notActive(state)
        }
    }

    private func deadline() -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        let (deadline, overflow) = now.addingReportingOverflow(commandDeadlineNanoseconds)
        return overflow ? UInt64.max : deadline
    }

    private func reject(
        _ error: DoryRendererWorkerVirtioCommandLaneError
    ) -> DoryRendererWorkerVirtioCommandLaneError {
        lock.withLock { rejectWhileLocked(error) }
    }

    private func rejectWhileLocked(
        _ error: DoryRendererWorkerVirtioCommandLaneError
    ) -> DoryRendererWorkerVirtioCommandLaneError {
        rejectedAdmissions = Self.saturatingAdd(rejectedAdmissions, 1)
        return error
    }

    private static func duplicate(_ descriptors: [FileHandle]) throws -> [FileHandle] {
        var owned = [FileHandle]()
        owned.reserveCapacity(descriptors.count)
        do {
            for (index, descriptor) in descriptors.enumerated() {
                let duplicate = fcntl(descriptor.fileDescriptor, F_DUPFD_CLOEXEC, 0)
                guard duplicate >= 0 else {
                    throw DoryRendererWorkerVirtioCommandLaneError
                        .inputDescriptorDuplicationFailed(index: index)
                }
                owned.append(FileHandle(fileDescriptor: duplicate, closeOnDealloc: true))
            }
            return owned
        } catch {
            close(owned)
            throw error
        }
    }

    private static func close(_ descriptors: [FileHandle]) {
        for descriptor in descriptors { try? descriptor.close() }
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : sum
    }
}
