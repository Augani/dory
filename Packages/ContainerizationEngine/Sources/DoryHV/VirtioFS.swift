import DoryFSWorkerContracts
import Foundation

public enum VirtioFSError: Error, Equatable {
    case invalidTag(String)
}

/// Typed lifecycle boundary reported by one virtio-fs backend. A committed FUSE_DESTROY followed
/// by device reset is normal guest teardown; every other worker loss/reset remains a VM-fatal
/// authority failure. Callers must never infer this distinction from diagnostic strings.
public enum VirtioFSWorkerLifecycleEvent: Equatable, Sendable {
    case connectionTeardown
    case failure(String)

    public var diagnostic: String {
        switch self {
        case .connectionTeardown:
            "filesystem worker connection teardown committed"
        case .failure(let reason):
            reason
        }
    }
}

public struct VirtioFSCacheActivationEligibility: Equatable, Sendable {
    public let notificationFeatureNegotiated: Bool
    public let notificationQueueReady: Bool
    public let stableNotificationBufferCount: Int
    public let requiredStableNotificationBufferCount: Int
    public let fuseInitCompleted: Bool

    public var isEligible: Bool {
        notificationFeatureNegotiated
            && notificationQueueReady
            && stableNotificationBufferCount >= requiredStableNotificationBufferCount
            && fuseInitCompleted
    }
}

public enum VirtioFSCacheActivationResult: Equatable, Sendable {
    case activated
    case ineligible(VirtioFSCacheActivationEligibility)
}

public struct VirtioFSStatistics: Equatable, Sendable {
    public var invalidations: UInt64
    public var invalidationFailures: UInt64
    public var invalidationFailureLatched: Bool

    public init(
        invalidations: UInt64,
        invalidationFailures: UInt64,
        invalidationFailureLatched: Bool
    ) {
        self.invalidations = invalidations
        self.invalidationFailures = invalidationFailures
        self.invalidationFailureLatched = invalidationFailureLatched
    }
}

public struct VirtioFSFrontendStatistics: Equatable, Sendable {
    public let rejectedRequests: UInt64
    public let executedRequests: UInt64
    public let terminalQueueFaults: UInt64

    public init(rejectedRequests: UInt64, executedRequests: UInt64, terminalQueueFaults: UInt64) {
        self.rejectedRequests = rejectedRequests
        self.executedRequests = executedRequests
        self.terminalQueueFaults = terminalQueueFaults
    }
}

/// Payload, concurrency, and end-to-end timing counters for admitted request work. Byte counters
/// describe protocol payloads observed at each ownership boundary; they intentionally do not claim
/// that Foundation or XPC performed one physical copy per byte.
public struct VirtioFSPerformanceStatistics: Equatable, Sendable {
    public let requestPayloadBytes: UInt64
    public let workerResponsePayloadBytes: UInt64
    public let guestPublishedResponseBytes: UInt64
    public let completedRequests: UInt64
    public let failedRequests: UInt64
    public let inFlightRequests: UInt64
    public let peakInFlightRequests: UInt64
    public let totalRequestLatencyNanoseconds: UInt64
    public let maximumRequestLatencyNanoseconds: UInt64

    public init(
        requestPayloadBytes: UInt64,
        workerResponsePayloadBytes: UInt64,
        guestPublishedResponseBytes: UInt64,
        completedRequests: UInt64,
        failedRequests: UInt64,
        inFlightRequests: UInt64,
        peakInFlightRequests: UInt64,
        totalRequestLatencyNanoseconds: UInt64,
        maximumRequestLatencyNanoseconds: UInt64
    ) {
        self.requestPayloadBytes = requestPayloadBytes
        self.workerResponsePayloadBytes = workerResponsePayloadBytes
        self.guestPublishedResponseBytes = guestPublishedResponseBytes
        self.completedRequests = completedRequests
        self.failedRequests = failedRequests
        self.inFlightRequests = inFlightRequests
        self.peakInFlightRequests = peakInFlightRequests
        self.totalRequestLatencyNanoseconds = totalRequestLatencyNanoseconds
        self.maximumRequestLatencyNanoseconds = maximumRequestLatencyNanoseconds
    }
}

public final class VirtioFS: VirtioDeviceBackend {
    public static let tagByteCount = 36
    public static let notificationFeature: UInt64 = 1 << 0
    public static let notificationBufferSize: UInt32 = 4096
    /// Upper bound for positive entry and attribute validity in coherent mode. Open-file and
    /// directory cache flags remain disabled because they cannot be revoked after degradation.
    public static let maximumCoherentCacheValiditySeconds: UInt64 = 0
    /// The matching guest driver posts 16 page-sized notification buffers. Caching is forbidden
    /// until this process has seen every stable backing address in the current transport epoch.
    public static let requiredStableNotificationBufferCountForCaching = 16

    public let deviceID: UInt32 = 26
    /// Queue drains are serialized per queue below and every ring mutation is fenced with the
    /// transport lock. Allow independent request queues to run concurrently instead of holding the
    /// global MMIO register lock across host filesystem work.
    public let kickSynchronization: VirtioKickSynchronization = .backendManaged
    /// Queue 0 is high priority. Queue 1 is reserved for negotiated notifications, and the
    /// remaining N queues are requests. Without negotiation, old guests continue using queue 1 as
    /// their first request queue and simply leave the final device queue unused.
    /// A single request queue serialized npm's parallel metadata storm on one vCPU even though FUSE
    /// advertised PARALLEL_DIROPS. Match the guest's vCPU parallelism (capped for host sanity) so
    /// independent lookups/creates can reach HostFS concurrently.
    public let queueCount: Int
    public let requestQueueCount: Int
    public let notificationBacklogLimit: Int
    public let tag: String
    private let broker: DoryFSWorkerBroker
    private let onWorkerLifecycle: @Sendable (VirtioFSWorkerLifecycleEvent) -> Void
    public var deviceFeatures: UInt64 { Self.notificationFeature }

    private let workers = DispatchQueue(
        label: "dory-hv.virtiofs.worker",
        qos: RawHVSchedulingPolicy.fileSystemWorkerDispatchQoS,
        attributes: .concurrent
    )
    private let drainLock = NSLock()
    /// The lifecycle epoch currently owned by a drainer, or nil when that queue has no drainer.
    /// Reset/reconfiguration clears the slot while the old epoch finishes outside the queue lock,
    /// allowing a kick for the replacement queue to start without accepting the old response.
    private var activeDrainerEpochs: [UInt64?]
    private var kickGenerations: [UInt64]
    private var queueLifecycleEpochs: [UInt64]

    // Notification buffers are guest-owned writable chains retained until the host has an
    // invalidation to publish. Every field below is protected by notificationLock. Queue access
    // additionally holds VirtioMMIOTransport's register lock, always in transport -> state order.
    private let notificationLock = NSLock()
    private weak var notificationTransport: VirtioMMIOTransport?
    private var notificationNegotiated = false
    private var notificationQueueReady = false
    private var availableNotificationBuffers: [NotificationBuffer] = []
    private var availableNotificationBufferKeys: Set<UInt> = []
    private var observedNotificationBufferKeys: Set<UInt> = []
    private var pendingNotifications: [PendingNotification] = []
    private var inFlightNotifications: [UInt: UInt64] = [:]
    private var acknowledgedNotificationSequences: Set<UInt64> = []
    private var notificationBarrierTargets: [NotificationBarrierTarget] = []
    private var nextNotificationSequence: UInt64 = 1
    private var processedNotificationSequence: UInt64 = 0
    private var notificationEpoch: UInt64 = 0
    // Queue-health policy transitions can overtake a worker that is outside the transport lock.
    // The generation prevents such a response from carrying a pre-transition metadata TTL.
    private var responseCacheEpoch: UInt64 = 0

    // Reverse invalidations form a publication epoch boundary. Closing this gate is synchronous.
    // New FUSE_WRITE requests leave their descriptors available because they may contain stale
    // dirty-page data. Other inode/dentry operations are allowed to drain after the pre-boundary
    // active set reaches zero: Linux can hold a VFS lock while awaiting those responses, and the
    // notification worker needs the same lock to order cache invalidation. The guest's fair VFS
    // locks serialize those responses before invalidation; the response-cache epoch strips grants
    // from work that crossed the boundary. Timeout latches all publication closed for this
    // backend's lifetime; success keeps the write fence until every admitted barrier resolves.
    private let requestGateLock = NSLock()
    private var requestGateClosed = false
    /// The broker's shared workspace authority owns capacity. This frontend tracks only requests
    /// that crossed its publication boundary plus per-queue grants already reserved by that shared
    /// authority; it never mirrors the workspace counters with a second semaphore.
    private var activeRequestCount = 0
    private var deferredAdmissionQueues = Set<Int>()
    private var grantedAdmissions = [Int: DoryFSWorkerAdmissionLease]()
    private var admissionWaiterIDs = [DoryFSWorkerAdmissionWaiterID]()
    private var frontendAdmissionTerminationReported = false
    private var requestGateWaiters: [
        UUID: CheckedContinuation<Result<Void, VirtioFSNotificationError>, Never>
    ] = [:]
    private var requestGateSubmissionsInProgress = 0
    private var requestGateBarriers: [ObjectIdentifier: VirtioFSNotificationBarrier] = [:]
    /// High-level coherence invalidations retain their barrier after the guest acknowledges it so
    /// the waiting caller, rather than the queue callback, decides whether requests may resume. A
    /// failed wait latches this backend closed for the rest of its lifetime: a QueueReady toggle or
    /// device reset in the same guest cannot prove that dirty page cache was discarded.
    private var requestGateCallerRetainedBarriers: Set<ObjectIdentifier> = []
    private var requestGateFailureLatched = false
    private weak var requestGateTransport: VirtioMMIOTransport?
    private var deferredRequestQueues: Set<Int> = []
    /// A device reset invalidates the entire FUSE connection, but MMIO reset holds the transport
    /// lock while old workers may still be trying to publish. Mark the reset synchronously, block
    /// new admission, and close server handles only after the last admitted request leaves.
    private var connectionResetPending = false
    private var connectionResetInProgress = false
    private weak var connectionResetTransport: VirtioMMIOTransport?
    private var connectionResetEvent: VirtioFSWorkerLifecycleEvent?

    private let responseFenceTestHookLock = NSLock()
    private var _responseFenceTestHook: (@Sendable (FuseInHeader, FuseOpcode) -> Void)?
    private let requestGateDrainTestHookLock = NSLock()
    private var _requestGateDrainTestHook: (@Sendable (RequestGateDrainTestEvent) -> Void)?
    private let requestExecutionTestHookLock = NSLock()
    private var _requestExecutionTestHook: (@Sendable (FuseInHeader, FuseOpcode) -> Void)?
    private let hostResponseSnapshotTestHookLock = NSLock()
    private var _hostResponseSnapshotTestHook: (@Sendable (FuseInHeader, FuseOpcode, [UInt8]) -> Void)?
    private let telemetryLock = NSLock()
    private var invalidationCount: UInt64 = 0
    private var invalidationFailureCount: UInt64 = 0
    private var hasLatchedInvalidationFailure = false
    private var rejectedRequestCount: UInt64 = 0
    private var executedRequestCount: UInt64 = 0
    private var terminalQueueFaultCount: UInt64 = 0
    private var requestPayloadByteCount: UInt64 = 0
    private var workerResponsePayloadByteCount: UInt64 = 0
    private var guestPublishedResponseByteCount: UInt64 = 0
    private var completedRequestCount: UInt64 = 0
    private var failedRequestCount: UInt64 = 0
    private var inFlightRequestCount: UInt64 = 0
    private var peakInFlightRequestCount: UInt64 = 0
    private var totalRequestLatencyNanoseconds: UInt64 = 0
    private var maximumRequestLatencyNanoseconds: UInt64 = 0
    private var requestFrontendTerminallyFaulted = false
    private var fuseInitCompleted = false
    private var fuseDestroyCommitted = false

    public init(
        tag: String,
        broker: DoryFSWorkerBroker,
        requestQueueCount requestedQueueCount: Int? = nil,
        notificationBacklogLimit requestedNotificationBacklogLimit: Int = 256,
        onWorkerLifecycle: @escaping @Sendable (VirtioFSWorkerLifecycleEvent) -> Void = { event in
            FileHandle.standardError.write(Data("dory-hv: \(event.diagnostic)\n".utf8))
        }
    ) throws {
        let bytes = Array(tag.utf8)
        guard !bytes.isEmpty, bytes.count < Self.tagByteCount else {
            throw VirtioFSError.invalidTag(tag)
        }
        self.tag = tag
        self.broker = broker
        self.onWorkerLifecycle = onWorkerLifecycle
        self.requestQueueCount = Self.clampedRequestQueueCount(
            requestedQueueCount ?? Self.defaultRequestQueueCount()
        )
        self.notificationBacklogLimit = min(4096, max(1, requestedNotificationBacklogLimit))
        self.queueCount = self.requestQueueCount + 2
        self.admissionWaiterIDs = (0..<self.queueCount).map { _ in
            DoryFSWorkerAdmissionWaiterID()
        }
        self.activeDrainerEpochs = Array(repeating: nil, count: self.queueCount)
        self.kickGenerations = Array(repeating: 0, count: self.queueCount)
        self.queueLifecycleEpochs = Array(repeating: 0, count: self.queueCount)
    }

    /// Library callers that do not own a launch policy receive a deterministic host-capability
    /// default. Production launchers pass an explicit daemon-resolved value.
    static func defaultRequestQueueCount(
        activeProcessorCount: Int = ProcessInfo.processInfo.activeProcessorCount
    ) -> Int {
        min(8, max(1, activeProcessorCount))
    }

    public var configSpace: [UInt8] {
        var data = [UInt8](repeating: 0, count: Self.tagByteCount)
        let tagBytes = Array(tag.utf8)
        data.replaceSubrange(0..<tagBytes.count, with: tagBytes)
        var requestQueues = UInt32(requestQueueCount).littleEndian
        withUnsafeBytes(of: &requestQueues) { data.append(contentsOf: $0) }
        var notificationBufferSize = Self.notificationBufferSize.littleEndian
        withUnsafeBytes(of: &notificationBufferSize) { data.append(contentsOf: $0) }
        return data
    }

    /// Reports every local prerequisite for turning on bounded positive caching. The host event
    /// relay remains a separate, higher-level gate; callers should activate only after that relay is
    /// healthy too. This snapshot is fail-closed for a missing/reset transport.
    public var cacheActivationEligibility: VirtioFSCacheActivationEligibility {
        notificationLock.withLock { cacheActivationEligibilityLocked() }
    }

    public var coherentCachingActive: Bool {
        false
    }

    /// Test-only interlock used to stop a request after encoding but before used-ring publication.
    /// Production code leaves it nil; keeping it internal avoids exposing a runtime tuning surface.
    var responseFenceTestHook: (@Sendable (FuseInHeader, FuseOpcode) -> Void)? {
        get { responseFenceTestHookLock.withLock { _responseFenceTestHook } }
        set { responseFenceTestHookLock.withLock { _responseFenceTestHook = newValue } }
    }

    /// Test-only interlock for deterministic coverage of the deferred-drainer ownership handoff.
    /// Production code leaves it nil.
    var requestGateDrainTestHook: (@Sendable (RequestGateDrainTestEvent) -> Void)? {
        get { requestGateDrainTestHookLock.withLock { _requestGateDrainTestHook } }
        set { requestGateDrainTestHookLock.withLock { _requestGateDrainTestHook = newValue } }
    }

    /// Test-only proof that admitted work crosses the single generic FuseServer execution seam.
    var requestExecutionTestHook: (@Sendable (FuseInHeader, FuseOpcode) -> Void)? {
        get { requestExecutionTestHookLock.withLock { _requestExecutionTestHook } }
        set { requestExecutionTestHookLock.withLock { _requestExecutionTestHook = newValue } }
    }

    /// Test-only host-owned response observation. It runs before any guest-memory publication.
    var hostResponseSnapshotTestHook: (@Sendable (FuseInHeader, FuseOpcode, [UInt8]) -> Void)? {
        get { hostResponseSnapshotTestHookLock.withLock { _hostResponseSnapshotTestHook } }
        set { hostResponseSnapshotTestHookLock.withLock { _hostResponseSnapshotTestHook = newValue } }
    }

    var requestPublicationGateClosed: Bool {
        requestGateLock.withLock { requestGateClosed }
    }

    var deferredRequestQueueSnapshot: Set<Int> {
        requestGateLock.withLock { deferredRequestQueues }
    }

    var capacityDeferredRequestQueueSnapshot: Set<Int> {
        requestGateLock.withLock { deferredAdmissionQueues }
    }

    /// Enables one-second positive entry/attribute validity only after notification negotiation, a
    /// ready queue, all 16 stable guest buffers, and FUSE INIT have been observed. Negative dentries,
    /// KEEP_CACHE, and CACHE_DIR remain disabled in every state.
    @discardableResult
    public func activateCoherentCaching() -> VirtioFSCacheActivationResult {
        notificationLock.lock()
        let eligibility = cacheActivationEligibilityLocked()
        notificationLock.unlock()
        return .ineligible(eligibility)
    }

    /// Synchronously makes every subsequently encoded FUSE response use zero metadata validity.
    /// KEEP_CACHE and CACHE_DIR are never emitted, including while coherent caching is active.
    public func deactivateCoherentCaching() {
        notificationLock.withLock {
            responseCacheEpoch &+= 1
        }
    }

    /// Establishes a synchronous, one-way recovery boundary for this backend. Callers use this
    /// when host-side observation can no longer identify every edit (for example, an FSEvents loss
    /// marker): new FUSE work is refused and responses from already-admitted work cannot reach the
    /// used ring. Host syscalls that crossed admission before this call cannot be canceled or
    /// rolled back and retain normal host last-writer semantics; replacing the VM/backend is the
    /// only operation that clears the publication latch.
    public func failStopRequestPublication() {
        latchRequestGateFailure(barrier: nil)
    }

    public func deviceReady(transport: VirtioMMIOTransport) {
        let negotiated = transport.negotiatedFeatures & Self.notificationFeature != 0
        let staleBarriers: [VirtioFSNotificationBarrier]
        notificationLock.lock()
        if notificationTransport === transport, notificationNegotiated == negotiated {
            notificationLock.unlock()
            return
        }
        staleBarriers = removeAllNotificationStateLocked()
        notificationTransport = transport
        notificationNegotiated = negotiated
        notificationQueueReady = negotiated && transport.queues[1].ready
        notificationLock.unlock()

        fail(staleBarriers, with: .transportReset, transport: transport)
    }

    public func queueStateChanged(queue: Int, ready: Bool, transport: VirtioMMIOTransport) {
        advanceQueueLifecycle(queue)
        guard queue == 1 else { return }

        let staleBarriers: [VirtioFSNotificationBarrier]
        notificationLock.lock()
        if notificationTransport === transport {
            staleBarriers = resetNotificationQueueStateLocked(
                queueReady: notificationNegotiated && ready,
                resetFuseInit: false
            )
        } else {
            staleBarriers = []
        }
        notificationLock.unlock()

        fail(staleBarriers, with: .transportReset, transport: transport)
    }

    public func deviceReset(transport: VirtioMMIOTransport) {
        advanceAllQueueLifecycles()
        let staleBarriers: [VirtioFSNotificationBarrier]
        let hadStartedDriverLifecycle: Bool
        let resetEvent: VirtioFSWorkerLifecycleEvent
        notificationLock.lock()
        hadStartedDriverLifecycle = notificationTransport === transport
        resetEvent = fuseDestroyCommitted
            ? .connectionTeardown
            : .failure("filesystem worker generation invalidated by virtio-fs device reset")
        if notificationTransport === transport {
            staleBarriers = removeAllNotificationStateLocked()
        } else {
            staleBarriers = []
        }
        notificationLock.unlock()

        // Linux writes device status 0 while probing an already-reset virtio device, before the
        // DRIVER_OK edge that establishes a guest FUSE connection. Retiring the one-shot worker
        // there makes every normal boot fail. Once this backend has observed DRIVER_OK, however,
        // any reset can strand guest FUSE handles or dirty cache state and remains fail-stop. The
        // sole normal exception is a reset after the exact FUSE_DESTROY response was committed;
        // that retires only this share so sibling shares can finish on the shared worker channel.
        if hadStartedDriverLifecycle {
            beginConnectionReset(transport: transport, event: resetEvent)
        }
        fail(staleBarriers, with: .transportReset, transport: transport)
    }

    private func advanceQueueLifecycle(_ queue: Int) {
        guard queue >= 0, queue < queueCount else { return }
        drainLock.withLock {
            queueLifecycleEpochs[queue] &+= 1
            kickGenerations[queue] &+= 1
            // An old drainer may still be performing host work, but its eventual push is rejected
            // by the epoch check. Release ownership now so the replacement queue can drain.
            activeDrainerEpochs[queue] = nil
        }
    }

    private func advanceAllQueueLifecycles() {
        drainLock.withLock {
            for queue in queueLifecycleEpochs.indices {
                queueLifecycleEpochs[queue] &+= 1
                kickGenerations[queue] &+= 1
                activeDrainerEpochs[queue] = nil
            }
        }
    }

    /// Atomically admits a batch of invalidations. The returned barrier completes only after the
    /// guest kernel has processed the entire ordered prefix and reposted every corresponding
    /// notification buffer.
    public func submitInvalidations(
        _ invalidations: [VirtioFSInvalidation]
    ) async throws -> VirtioFSNotificationBarrier {
        guard !invalidations.isEmpty else {
            return VirtioFSNotificationBarrier(notificationCount: 0)
        }
        do {
            return try await submitInvalidations(
                invalidations,
                retainRequestGateForCaller: false
            )
        } catch {
            recordInvalidationFailure(latched: requestGateLock.withLock {
                requestGateFailureLatched
            })
            throw error
        }
    }

    private func submitInvalidations(
        _ invalidations: [VirtioFSInvalidation],
        retainRequestGateForCaller: Bool,
        requestGateDeadline: ContinuousClock.Instant? = nil
    ) async throws -> VirtioFSNotificationBarrier {
        guard !invalidations.isEmpty else {
            return VirtioFSNotificationBarrier(notificationCount: 0)
        }
        let frames = try invalidations.map { try $0.encoded() }
        guard frames.allSatisfy({ $0.count <= Int(Self.notificationBufferSize) }) else {
            // The public invalidation encoders currently make this unreachable, but preserve the
            // all-or-nothing admission guarantee if new FUSE notification types are added later.
            throw VirtioFSNotificationError.messageTooLarge(limit: Int(Self.notificationBufferSize))
        }

        // Close request admission before touching the transport, then suspend without holding the
        // MMIO register lock until every response from the preceding epoch has reached its used
        // ring. handleKick never waits on this gate, which avoids a register-lock deadlock.
        try await closeRequestGateAndWaitForActiveResponses(deadline: requestGateDeadline)

        // Preserve the actual transport even when notification eligibility is false. A low-level
        // submission failure reopens the request gate and must be able to redrain request queues
        // that were deferred while this operation performed its strict eligibility check below.
        let transport = notificationLock.withLock {
            notificationTransport
        }
        guard let transport else {
            finishRequestGateSubmissionWithoutBarrier(
                transport: nil,
                latchFailure: retainRequestGateForCaller
            )
            throw VirtioFSNotificationError.featureNotNegotiated
        }

        var effects = NotificationEffects()
        var submission: Result<VirtioFSNotificationBarrier, VirtioFSNotificationError>!
        var gateSubmissionBound = false
        transport.withQueueLock {
            notificationLock.lock()
            guard notificationTransport === transport,
                  notificationNegotiated,
                  notificationQueueReady,
                  transport.negotiatedFeatures & Self.notificationFeature != 0,
                  transport.queues[1].ready else {
                notificationLock.unlock()
                submission = .failure(.featureNotNegotiated)
                return
            }

            let outstanding = nextNotificationSequence - processedNotificationSequence - 1
            guard outstanding <= UInt64(notificationBacklogLimit),
                  frames.count <= notificationBacklogLimit - Int(outstanding) else {
                notificationLock.unlock()
                submission = .failure(.backpressure(limit: notificationBacklogLimit))
                return
            }

            let barrier = VirtioFSNotificationBarrier(notificationCount: 1)
            responseCacheEpoch &+= 1
            for frame in frames {
                let sequence = nextNotificationSequence
                nextNotificationSequence &+= 1
                pendingNotifications.append(PendingNotification(sequence: sequence, bytes: frame))
            }
            notificationBarrierTargets.append(NotificationBarrierTarget(
                sequence: nextNotificationSequence - 1,
                barrier: barrier
            ))
            bindRequestGate(
                to: barrier,
                transport: transport,
                retainedByCaller: retainRequestGateForCaller
            )
            gateSubmissionBound = true
            pumpNotificationsLocked(queue: transport.queues[1], effects: &effects)
            notificationLock.unlock()
            submission = .success(barrier)
        }

        if !gateSubmissionBound {
            finishRequestGateSubmissionWithoutBarrier(
                transport: transport,
                latchFailure: retainRequestGateForCaller
            )
        }
        apply(effects, transport: transport)
        let barrier = try submission.get()
        recordInvalidations(frames.count)
        return barrier
    }

    public func submitInvalidation(
        _ invalidation: VirtioFSInvalidation
    ) async throws -> VirtioFSNotificationBarrier {
        try await submitInvalidations([invalidation])
    }

    public func invalidate(
        _ invalidations: [VirtioFSInvalidation],
        timeout: Duration = .seconds(2)
    ) async throws {
        try await invalidateAtomically(
            invalidations,
            maximumBatchSize: max(1, invalidations.count),
            timeout: timeout
        )
    }

    /// Delivers a large ordered invalidation prefix in bounded transport batches while retaining
    /// one request-publication gate across every batch. Reopening that gate between chunks could
    /// expose DELETE/INVAL_ENTRY effects before a later INVAL_INODE expires the matching attributes
    /// or pages, so only the final acknowledged prefix may resume guest requests.
    public func invalidateAtomically(
        _ invalidations: [VirtioFSInvalidation],
        maximumBatchSize: Int,
        timeout: Duration = .seconds(2)
    ) async throws {
        guard !invalidations.isEmpty else { return }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        let batchSize = max(1, min(maximumBatchSize, notificationBacklogLimit))
        var retainedBarriers = [VirtioFSNotificationBarrier]()
        do {
            var start = 0
            while start < invalidations.count {
                let end = min(start + batchSize, invalidations.count)
                let barrier = try await submitInvalidations(
                    Array(invalidations[start..<end]),
                    retainRequestGateForCaller: true,
                    requestGateDeadline: deadline
                )
                retainedBarriers.append(barrier)
                let remaining = clock.now.duration(to: deadline)
                guard remaining > .zero else {
                    throw VirtioFSNotificationError.timedOut
                }
                do {
                    try await barrier.wait(timeout: remaining)
                } catch VirtioFSNotificationError.timedOut {
                    throw VirtioFSNotificationError.acknowledgementTimedOut
                }
                start = end
            }
            for barrier in retainedBarriers {
                releaseCallerRetainedRequestGate(barrier, succeeded: true)
            }
        } catch {
            // Any returned error leaves delivery or cache revocation uncertain. Revoke future TTLs
            // and permanently hold request publication for this backend before the coordinator can
            // schedule a VM restart. In particular, never let a delayed guest WRITE/FSYNC escape
            // between this failure and the host-owned recovery boundary.
            deactivateCoherentCaching()
            for barrier in retainedBarriers {
                releaseCallerRetainedRequestGate(barrier, succeeded: false)
            }
            latchRequestGateFailure(barrier: nil)
            recordInvalidationFailure(latched: true)
            throw error
        }
    }

    public var statistics: VirtioFSStatistics {
        telemetryLock.withLock {
            VirtioFSStatistics(
                invalidations: invalidationCount,
                invalidationFailures: invalidationFailureCount,
                invalidationFailureLatched: hasLatchedInvalidationFailure
            )
        }
    }

    public var frontendStatistics: VirtioFSFrontendStatistics {
        telemetryLock.withLock {
            VirtioFSFrontendStatistics(
                rejectedRequests: rejectedRequestCount,
                executedRequests: executedRequestCount,
                terminalQueueFaults: terminalQueueFaultCount
            )
        }
    }

    public var performanceStatistics: VirtioFSPerformanceStatistics {
        telemetryLock.withLock {
            VirtioFSPerformanceStatistics(
                requestPayloadBytes: requestPayloadByteCount,
                workerResponsePayloadBytes: workerResponsePayloadByteCount,
                guestPublishedResponseBytes: guestPublishedResponseByteCount,
                completedRequests: completedRequestCount,
                failedRequests: failedRequestCount,
                inFlightRequests: inFlightRequestCount,
                peakInFlightRequests: peakInFlightRequestCount,
                totalRequestLatencyNanoseconds: totalRequestLatencyNanoseconds,
                maximumRequestLatencyNanoseconds: maximumRequestLatencyNanoseconds
            )
        }
    }

    private func recordInvalidations(_ count: Int) {
        guard count > 0 else { return }
        let increment = UInt64(count)
        telemetryLock.withLock {
            invalidationCount = Self.saturatingAdd(invalidationCount, increment)
        }
    }

    private func recordInvalidationFailure(latched: Bool) {
        telemetryLock.withLock {
            invalidationFailureCount = Self.saturatingAdd(invalidationFailureCount, 1)
            hasLatchedInvalidationFailure = hasLatchedInvalidationFailure || latched
        }
    }

    private func recordRequestRejection() {
        telemetryLock.withLock {
            rejectedRequestCount = Self.saturatingAdd(rejectedRequestCount, 1)
        }
    }

    private func recordRequestExecution(requestPayloadBytes: Int) {
        telemetryLock.withLock {
            executedRequestCount = Self.saturatingAdd(executedRequestCount, 1)
            requestPayloadByteCount = Self.saturatingAdd(
                requestPayloadByteCount,
                UInt64(requestPayloadBytes)
            )
            inFlightRequestCount = Self.saturatingAdd(inFlightRequestCount, 1)
            peakInFlightRequestCount = max(
                peakInFlightRequestCount,
                inFlightRequestCount
            )
        }
    }

    private func recordWorkerResponsePayload(bytes: Int) {
        telemetryLock.withLock {
            workerResponsePayloadByteCount = Self.saturatingAdd(
                workerResponsePayloadByteCount,
                UInt64(bytes)
            )
        }
    }

    private func recordGuestPublishedResponse(bytes: Int) {
        telemetryLock.withLock {
            guestPublishedResponseByteCount = Self.saturatingAdd(
                guestPublishedResponseByteCount,
                UInt64(bytes)
            )
        }
    }

    private func recordRequestCompletion(
        admittedAtUptimeNanoseconds: UInt64,
        published: Bool
    ) {
        let completedAt = DispatchTime.now().uptimeNanoseconds
        let latency = completedAt >= admittedAtUptimeNanoseconds
            ? completedAt - admittedAtUptimeNanoseconds
            : 0
        telemetryLock.withLock {
            precondition(inFlightRequestCount > 0)
            inFlightRequestCount -= 1
            if published {
                completedRequestCount = Self.saturatingAdd(completedRequestCount, 1)
            } else {
                failedRequestCount = Self.saturatingAdd(failedRequestCount, 1)
            }
            totalRequestLatencyNanoseconds = Self.saturatingAdd(
                totalRequestLatencyNanoseconds,
                latency
            )
            maximumRequestLatencyNanoseconds = max(
                maximumRequestLatencyNanoseconds,
                latency
            )
        }
    }

    private func recordTerminalQueueFault(_ error: any Error, queue: Int) {
        telemetryLock.withLock {
            terminalQueueFaultCount = Self.saturatingAdd(terminalQueueFaultCount, 1)
            requestFrontendTerminallyFaulted = true
        }
        FileHandle.standardError.write(Data(
            "dory-hv: virtiofs terminal queue fault queue=\(queue): \(error)\n".utf8
        ))
        latchRequestGateFailure(barrier: nil)
    }

    private var requestFrontendIsTerminallyFaulted: Bool {
        telemetryLock.withLock { requestFrontendTerminallyFaulted }
    }

    private static func saturatingAdd(_ value: UInt64, _ increment: UInt64) -> UInt64 {
        let (sum, overflow) = value.addingReportingOverflow(increment)
        return overflow ? UInt64.max : sum
    }

    public func handleKick(queue: Int, transport: VirtioMMIOTransport) {
        guard queue >= 0, queue < queueCount else { return }
        guard !requestFrontendIsTerminallyFaulted else { return }
        // Queue notification MMIO is intentionally delivered without the transport lock for this
        // backend. Snapshot only routing/readiness under that lock; every pop/push below takes it
        // again and verifies the queue lifecycle epoch before touching the ring.
        let route = transport.withQueueLock {
            (
                notificationsEnabled: transport.negotiatedFeatures & Self.notificationFeature != 0,
                ready: transport.queues[queue].ready
            )
        }
        guard route.ready else { return }
        let notificationsEnabled = route.notificationsEnabled
        if notificationsEnabled, queue == 1 {
            handleNotificationKick(transport: transport)
            return
        }
        let firstRequestQueue = notificationsEnabled ? 2 : 1
        guard queue == 0 || (queue >= firstRequestQueue && queue < firstRequestQueue + requestQueueCount) else {
            return
        }
        // Exactly one drainer owns a queue lifecycle epoch. Kicks on different queues may overlap,
        // while a same-queue kick only advances the generation so the active drainer sweeps again.
        guard let lifecycleEpoch = beginQueueDrain(queue: queue) else { return }
        drain(queue: queue, lifecycleEpoch: lifecycleEpoch, transport: transport)
    }

    private func drain(queue: Int, lifecycleEpoch: UInt64, transport: VirtioMMIOTransport) {
        let virtqueue = transport.queues[queue]
        while true {
            guard let generation = drainLock.withLock({ () -> UInt64? in
                guard queueLifecycleEpochs[queue] == lifecycleEpoch,
                      activeDrainerEpochs[queue] == lifecycleEpoch else { return nil }
                return kickGenerations[queue]
            }) else {
                finishQueueDrain(queue: queue, lifecycleEpoch: lifecycleEpoch)
                return
            }
            var shouldNotify = false
            requestLoop: while true {
                let requestAdmission = beginRequestProcessing(
                    queue: queue,
                    lifecycleEpoch: lifecycleEpoch,
                    virtqueue: virtqueue,
                    transport: transport
                )
                guard case .process(let admissionLease, let previewOpcode) = requestAdmission else {
                    requestGateDrainTestHook?(.deferred(queue: queue))
                    break
                }
                let popResult = popChain(
                    queue: queue,
                    lifecycleEpoch: lifecycleEpoch,
                    virtqueue: virtqueue,
                    transport: transport
                )
                switch popResult {
                case .chain(let chain):
                    switch process(
                        chain: chain,
                        queue: queue,
                        lifecycleEpoch: lifecycleEpoch,
                        virtqueue: virtqueue,
                        transport: transport,
                        admissionLease: admissionLease,
                        previewOpcode: previewOpcode
                    ) {
                    case .completed(let interruptWanted):
                        shouldNotify = shouldNotify || interruptWanted
                        endRequestProcessing()
                    case .submitted:
                        break
                    }
                case .empty:
                    admissionLease?.release()
                    endRequestProcessing()
                    break requestLoop
                case .terminalFault(let error):
                    admissionLease?.release()
                    endRequestProcessing()
                    recordTerminalQueueFault(error, queue: queue)
                    break requestLoop
                }
            }
            if shouldNotify {
                transport.notifyUsed()
            }
            // Queue looks empty. Exit only if no kick landed while we were draining; otherwise a
            // chain may have arrived in the race window and we must sweep again. This also provides
            // the request-gate handoff: if reopening the gate schedules a kick before this deferred
            // drainer releases ownership, that kick advances the generation and this drainer sweeps
            // the now-open queue itself. drainLock is never held while taking the transport queue
            // lock, so this cannot invert lock order.
            let exit: Bool = drainLock.withLock {
                guard queueLifecycleEpochs[queue] == lifecycleEpoch,
                      activeDrainerEpochs[queue] == lifecycleEpoch else {
                    if activeDrainerEpochs[queue] == lifecycleEpoch {
                        activeDrainerEpochs[queue] = nil
                    }
                    return true
                }
                guard kickGenerations[queue] == generation else { return false }
                activeDrainerEpochs[queue] = nil
                return true
            }
            if exit { break }
        }
    }

    private func beginQueueDrain(queue: Int) -> UInt64? {
        var collidedWithActiveDrainer = false
        let lifecycleEpoch = drainLock.withLock { () -> UInt64? in
            kickGenerations[queue] &+= 1
            let lifecycleEpoch = queueLifecycleEpochs[queue]
            guard activeDrainerEpochs[queue] != lifecycleEpoch else {
                collidedWithActiveDrainer = true
                return nil
            }
            activeDrainerEpochs[queue] = lifecycleEpoch
            return lifecycleEpoch
        }
        if collidedWithActiveDrainer {
            requestGateDrainTestHook?(.kickCollidedWithActiveDrainer(queue: queue))
        }
        return lifecycleEpoch
    }

    private func finishQueueDrain(queue: Int, lifecycleEpoch: UInt64) {
        drainLock.withLock {
            if activeDrainerEpochs[queue] == lifecycleEpoch {
                activeDrainerEpochs[queue] = nil
            }
        }
    }

    private enum ChainPopResult {
        case chain(VirtqueueChain)
        case empty
        case terminalFault(any Error)
    }

    private enum RequestProcessResult {
        case completed(interruptWanted: Bool)
        case submitted
    }

    private enum RequestBeginResult {
        case process(DoryFSWorkerAdmissionLease?, previewOpcode: FuseOpcode?)
        case deferred
    }

    private func popChain(
        queue: Int,
        lifecycleEpoch: UInt64,
        virtqueue: Virtqueue,
        transport: VirtioMMIOTransport
    ) -> ChainPopResult {
        transport.withQueueLock {
            guard drainLock.withLock({ queueLifecycleEpochs[queue] == lifecycleEpoch }),
                  virtqueue.ready else { return .empty }
            do {
                guard let chain = try virtqueue.pop() else { return .empty }
                return .chain(chain)
            } catch {
                return .terminalFault(error)
            }
        }
    }

    private func process(
        chain: VirtqueueChain,
        queue: Int,
        lifecycleEpoch: UInt64,
        virtqueue: Virtqueue,
        transport: VirtioMMIOTransport,
        admissionLease: DoryFSWorkerAdmissionLease?,
        previewOpcode: FuseOpcode?
    ) -> RequestProcessResult {
        let requestNotificationEpoch: UInt64? = notificationLock.withLock {
            notificationTransport === transport ? notificationEpoch : nil
        }
        guard let admission = chain.withLeaseHeld({ access in
            VirtioFSRequestAdmission.inspect(
                chain: chain,
                access: access,
                queue: queue,
                maximumRequestBytes: broker.effectiveAdmissionLimits.maximumRequestBytes,
                maximumResponseBytes: broker.effectiveAdmissionLimits.maximumResponseBytes
            )
        }) else {
            admissionLease?.release()
            return .completed(interruptWanted: false)
        }

        switch admission {
        case .reject(let rejected):
            admissionLease?.release()
            recordRequestRejection()
            let publication = publishResponse(
                rejected.response,
                chain: chain,
                queue: queue,
                lifecycleEpoch: lifecycleEpoch,
                virtqueue: virtqueue,
                transport: transport
            )
            return .completed(
                interruptWanted: publication.pushed && publication.interruptWanted
            )
        case .execute(let request):
            let shape = DoryFSWorkerAdmissionShape(
                requestBytes: request.bytes.count,
                responseBytes: request.maximumResponseBytes
            )
            guard let admissionLease,
                  admissionLease.shape == shape,
                  request.opcode == previewOpcode else {
                admissionLease?.release()
                recordRequestRejection()
                let publication = publishResponse(
                    Self.errorResponse(unique: request.header.unique, errno: EAGAIN),
                    chain: chain,
                    queue: queue,
                    lifecycleEpoch: lifecycleEpoch,
                    virtqueue: virtqueue,
                    transport: transport
                )
                return .completed(
                    interruptWanted: publication.pushed && publication.interruptWanted
                )
            }
            if let opcode = request.opcode {
                requestExecutionTestHook?(request.header, opcode)
            }
            let admittedAtUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
            recordRequestExecution(requestPayloadBytes: request.bytes.count)
            Task { [weak self, weak transport, admissionLease] in
                guard let self else {
                    admissionLease.release()
                    return
                }
                var responsePublished = false
                defer {
                    self.recordRequestCompletion(
                        admittedAtUptimeNanoseconds: admittedAtUptimeNanoseconds,
                        published: responsePublished
                    )
                    self.endRequestProcessing()
                }
                guard let transport else {
                    admissionLease.release()
                    self.failWorker("virtio-fs transport disappeared before request execution")
                    return
                }
                let now = DispatchTime.now().uptimeNanoseconds
                let operationLimit = self.broker.limits.maximumOperationNanoseconds
                let (deadline, overflow) = now.addingReportingOverflow(operationLimit)
                guard !overflow else {
                    admissionLease.release()
                    self.failWorker("virtio-fs worker operation deadline overflow")
                    return
                }
                do {
                    let execution = try await self.broker.execute(
                        correlationID: request.header.unique,
                        opcodeClass: request.opcode?.workerOpcodeClass ?? .control,
                        request: Data(request.bytes),
                        responseCapacity: request.maximumResponseBytes,
                        deadlineUptimeNanoseconds: deadline,
                        admissionLease: admissionLease
                    )
                    self.recordWorkerResponsePayload(bytes: execution.response.count)
                    let normalized = self.normalizedResponse(
                        [UInt8](execution.response),
                        for: request
                    )
                    if let opcode = request.opcode {
                        self.hostResponseSnapshotTestHook?(
                            request.header,
                            opcode,
                            normalized.bytes
                        )
                        self.responseFenceTestHook?(request.header, opcode)
                    }
                    let publication = self.publishResponse(
                        normalized.bytes,
                        chain: chain,
                        queue: queue,
                        lifecycleEpoch: lifecycleEpoch,
                        virtqueue: virtqueue,
                        transport: transport
                    )
                    responsePublished = publication.pushed
                    if publication.pushed {
                        self.recordGuestPublishedResponse(bytes: normalized.bytes.count)
                    }
                    if publication.pushed && normalized.representsWorkerResponse {
                        try await self.broker.commitPublication(execution.publication)
                        if request.opcode == .destroy,
                           (try? FuseProtocol.decodeOutHeader(normalized.bytes).error) == 0 {
                            self.notificationLock.withLock {
                                self.fuseDestroyCommitted = true
                            }
                        }
                    } else {
                        try await self.broker.discardPublication(execution.publication)
                    }
                    if publication.pushed,
                       request.opcode == .initOp,
                       (try? FuseProtocol.decodeOutHeader(normalized.bytes).error) == 0,
                       let requestNotificationEpoch {
                        self.notificationLock.withLock {
                            guard self.notificationTransport === transport,
                                  self.notificationEpoch == requestNotificationEpoch else {
                                return
                            }
                            self.fuseInitCompleted = true
                        }
                    }
                    if publication.pushed && publication.interruptWanted {
                        transport.notifyUsed()
                    }
                    if !publication.pushed, let opcode = request.opcode {
                        FileHandle.standardError.write(Data(
                            "dory-hv: virtiofs response unpublished (\(publication.failureReason ?? "unknown")) op=\(opcode) unique=\(request.header.unique) queue=\(queue)\n".utf8
                        ))
                    }
                } catch {
                    self.failWorker("filesystem worker request failed: \(error)")
                }
            }
            return .submitted
        }
    }

    private struct NormalizedWorkerResponse {
        let bytes: [UInt8]
        let representsWorkerResponse: Bool
    }

    private func normalizedResponse(
        _ serverResponse: [UInt8],
        for request: VirtioFSAdmittedRequest
    ) -> NormalizedWorkerResponse {
        if !request.expectsReply {
            return NormalizedWorkerResponse(
                bytes: [],
                representsWorkerResponse: serverResponse.isEmpty
            )
        }
        if request.opcode == .interrupt, serverResponse.isEmpty {
            return NormalizedWorkerResponse(
                bytes: Self.errorResponse(unique: request.header.unique, errno: 0),
                representsWorkerResponse: false
            )
        }
        guard serverResponse.count >= FuseOutHeader.byteCount,
              serverResponse.count <= request.maximumResponseBytes,
              let header = try? FuseProtocol.decodeOutHeader(serverResponse),
              Int(header.length) == serverResponse.count,
              header.unique == request.header.unique else {
            return NormalizedWorkerResponse(
                bytes: Self.errorResponse(unique: request.header.unique, errno: EIO),
                representsWorkerResponse: false
            )
        }
        return NormalizedWorkerResponse(
            bytes: serverResponse,
            representsWorkerResponse: true
        )
    }

    private struct ResponsePublication {
        let pushed: Bool
        let interruptWanted: Bool
        let failureReason: String?
    }

    private func publishResponse(
        _ response: [UInt8],
        chain: VirtqueueChain,
        queue: Int,
        lifecycleEpoch: UInt64,
        virtqueue: Virtqueue,
        transport: VirtioMMIOTransport
    ) -> ResponsePublication {
        var interruptWanted = false
        var failureReason: String?
        let pushed = transport.withQueueLock {
            guard drainLock.withLock({ queueLifecycleEpochs[queue] == lifecycleEpoch }) else {
                failureReason = "lifecycle epoch changed"
                return false
            }
            guard virtqueue.ready else {
                failureReason = "queue not ready"
                return false
            }
            return requestGateLock.withLock {
                guard !requestGateFailureLatched else {
                    failureReason = "request gate latched"
                    return false
                }
                guard virtqueue.isLeaseValid(chain) else {
                    failureReason = "queue lease changed"
                    return false
                }
                guard chain.withLeaseHeld({ access in
                    access.writeBytes(response) == response.count
                }) == true else {
                    failureReason = "bounded response copy failed"
                    return false
                }
                do {
                    interruptWanted = try virtqueue.push(chain, written: response.count)
                    return true
                } catch {
                    failureReason = "virtqueue push threw: \(error)"
                    return false
                }
            }
        }
        return ResponsePublication(
            pushed: pushed,
            interruptWanted: interruptWanted,
            failureReason: failureReason
        )
    }

    private func failWorker(_ reason: String) {
        latchRequestGateFailure(barrier: nil)
        onWorkerLifecycle(.failure(reason))
    }

    private static func errorResponse(unique: UInt64, errno: Int32) -> [UInt8] {
        FuseProtocol.encodeOutHeader(FuseOutHeader(
            length: UInt32(FuseOutHeader.byteCount),
            error: errno == 0 ? 0 : -FuseProtocol.linuxErrno(errno),
            unique: unique
        ))
    }

}

private struct PendingNotification {
    let sequence: UInt64
    let bytes: [UInt8]
}

private struct NotificationBuffer {
    let key: UInt
    let chain: VirtqueueChain
}

private struct NotificationBarrierTarget {
    let sequence: UInt64
    let barrier: VirtioFSNotificationBarrier
}

private struct NotificationEffects {
    var shouldNotify = false
    var completed: [VirtioFSNotificationBarrier] = []
    var failed: [(VirtioFSNotificationBarrier, VirtioFSNotificationError)] = []
}

private struct RequestGateRelease {
    let transport: VirtioMMIOTransport?
    let queues: [Int]
}

enum RequestGateDrainTestEvent: Equatable, Sendable {
    case deferred(queue: Int)
    case kickCollidedWithActiveDrainer(queue: Int)
}

private extension VirtioFS {
    func handleNotificationKick(transport: VirtioMMIOTransport) {
        var effects = NotificationEffects()
        transport.withQueueLock {
            notificationLock.lock()
            guard notificationTransport === transport,
                  notificationNegotiated,
                  notificationQueueReady,
                  transport.negotiatedFeatures & Self.notificationFeature != 0 else {
                notificationLock.unlock()
                return
            }

            let queue = transport.queues[1]
            guard queue.ready else {
                if !availableNotificationBuffers.isEmpty || !inFlightNotifications.isEmpty {
                    degradeNotificationsLocked(with: .transportReset, effects: &effects)
                }
                notificationLock.unlock()
                return
            }

            do {
                while let chain = try queue.pop() {
                    guard let buffer = makeNotificationBuffer(chain) else {
                        effects.shouldNotify = (try queue.push(chain, written: 0)) || effects.shouldNotify
                        degradeNotificationsLocked(with: .invalidGuestBuffer, effects: &effects)
                        break
                    }

                    if let sequence = inFlightNotifications.removeValue(forKey: buffer.key) {
                        acknowledgeNotificationLocked(sequence, effects: &effects)
                    }

                    observedNotificationBufferKeys.insert(buffer.key)
                    guard availableNotificationBufferKeys.insert(buffer.key).inserted else {
                        effects.shouldNotify = (try queue.push(chain, written: 0)) || effects.shouldNotify
                        degradeNotificationsLocked(with: .invalidGuestBuffer, effects: &effects)
                        break
                    }
                    availableNotificationBuffers.append(buffer)
                }
            } catch {
                degradeNotificationsLocked(with: .invalidGuestBuffer, effects: &effects)
            }

            if notificationTransport === transport, notificationNegotiated, notificationQueueReady {
                pumpNotificationsLocked(queue: queue, effects: &effects)
            }
            notificationLock.unlock()
        }
        apply(effects, transport: transport)
    }

    func makeNotificationBuffer(_ chain: VirtqueueChain) -> NotificationBuffer? {
        chain.withLeaseHeld { access -> NotificationBuffer? in
            guard access.readableSegments.isEmpty,
                  access.writableSegments.count == 1,
                  let segment = access.writableSegments.first,
                  segment.length >= Int(Self.notificationBufferSize) else {
                return nil
            }
            // The patched guest reuses its kzalloc'd page but virtio may choose a new descriptor
            // head when it reposts it. Capture only the integer identity while the lease is held;
            // the raw segment itself never escapes this callback.
            return NotificationBuffer(key: UInt(bitPattern: segment.pointer), chain: chain)
        } ?? nil
    }

    func pumpNotificationsLocked(queue: Virtqueue, effects: inout NotificationEffects) {
        guard queue.ready else { return }
        while !pendingNotifications.isEmpty, let buffer = availableNotificationBuffers.popLast() {
            availableNotificationBufferKeys.remove(buffer.key)
            let pending = pendingNotifications.removeFirst()
            guard buffer.chain.writeBytes(pending.bytes) == pending.bytes.count else {
                degradeNotificationsLocked(with: .invalidGuestBuffer, effects: &effects)
                return
            }

            inFlightNotifications[buffer.key] = pending.sequence
            do {
                effects.shouldNotify = (try queue.push(buffer.chain, written: pending.bytes.count)) || effects.shouldNotify
            } catch {
                inFlightNotifications.removeValue(forKey: buffer.key)
                degradeNotificationsLocked(with: .transportReset, effects: &effects)
                return
            }
        }
    }

    func acknowledgeNotificationLocked(_ sequence: UInt64, effects: inout NotificationEffects) {
        acknowledgedNotificationSequences.insert(sequence)
        while acknowledgedNotificationSequences.remove(processedNotificationSequence + 1) != nil {
            processedNotificationSequence += 1
        }

        var waiting = [NotificationBarrierTarget]()
        waiting.reserveCapacity(notificationBarrierTargets.count)
        for target in notificationBarrierTargets {
            if target.sequence <= processedNotificationSequence {
                effects.completed.append(target.barrier)
            } else {
                waiting.append(target)
            }
        }
        notificationBarrierTargets = waiting
    }

    func degradeNotificationsLocked(
        with error: VirtioFSNotificationError,
        effects: inout NotificationEffects
    ) {
        FileHandle.standardError.write(Data("dory-hv: virtiofs notifications degraded: \(error)\n".utf8))
        effects.failed.append(contentsOf: removeAllNotificationStateLocked().map { ($0, error) })
    }

    func removeAllNotificationStateLocked() -> [VirtioFSNotificationBarrier] {
        let barriers = resetNotificationQueueStateLocked(queueReady: false, resetFuseInit: true)
        notificationTransport = nil
        notificationNegotiated = false
        return barriers
    }

    func resetNotificationQueueStateLocked(
        queueReady: Bool,
        resetFuseInit: Bool
    ) -> [VirtioFSNotificationBarrier] {
        // A QueueReady disable/reconfigure invalidates every retained descriptor immediately. Keep
        // feature negotiation and FUSE INIT only when the device itself remains live, but require a
        // fresh complete set of stable buffers before metadata caching can be reactivated.
        if resetFuseInit { fuseInitCompleted = false }
        responseCacheEpoch &+= 1
        notificationEpoch &+= 1
        let barriers = notificationBarrierTargets.map(\.barrier)
        notificationQueueReady = queueReady
        availableNotificationBuffers.removeAll(keepingCapacity: false)
        availableNotificationBufferKeys.removeAll(keepingCapacity: false)
        observedNotificationBufferKeys.removeAll(keepingCapacity: false)
        pendingNotifications.removeAll(keepingCapacity: false)
        inFlightNotifications.removeAll(keepingCapacity: false)
        acknowledgedNotificationSequences.removeAll(keepingCapacity: false)
        notificationBarrierTargets.removeAll(keepingCapacity: false)
        nextNotificationSequence = 1
        processedNotificationSequence = 0
        return barriers
    }

    func cacheActivationEligibilityLocked() -> VirtioFSCacheActivationEligibility {
        let featureNegotiated = notificationNegotiated && notificationTransport != nil
        return VirtioFSCacheActivationEligibility(
            notificationFeatureNegotiated: featureNegotiated,
            notificationQueueReady: featureNegotiated && notificationQueueReady,
            stableNotificationBufferCount: observedNotificationBufferKeys.count,
            requiredStableNotificationBufferCount: Self.requiredStableNotificationBufferCountForCaching,
            fuseInitCompleted: fuseInitCompleted
        )
    }

    func apply(_ effects: NotificationEffects, transport: VirtioMMIOTransport) {
        if effects.shouldNotify {
            transport.notifyUsed()
        }
        for barrier in effects.completed {
            barrier.acknowledge()
            resolveRequestGateBarrier(barrier, transport: transport)
        }
        for (barrier, error) in effects.failed {
            barrier.fail(error)
            resolveRequestGateBarrier(barrier, transport: transport)
        }
    }

    func fail(
        _ barriers: [VirtioFSNotificationBarrier],
        with error: VirtioFSNotificationError,
        transport: VirtioMMIOTransport
    ) {
        for barrier in barriers {
            barrier.fail(error)
            resolveRequestGateBarrier(barrier, transport: transport)
        }
    }

    func closeRequestGateAndWaitForActiveResponses(
        deadline: ContinuousClock.Instant? = nil
    ) async throws {
        let waiterID = UUID()
        let result: Result<Void, VirtioFSNotificationError> = await withCheckedContinuation { continuation in
            var immediate: Result<Void, VirtioFSNotificationError>?
            var timeout: Duration?
            requestGateLock.withLock {
                requestGateClosed = true
                requestGateSubmissionsInProgress += 1
                if let deadline {
                    let remaining = ContinuousClock().now.duration(to: deadline)
                    guard remaining > .zero else {
                        requestGateSubmissionsInProgress -= 1
                        requestGateFailureLatched = true
                        immediate = .failure(.requestDrainTimedOut(
                            activeRequests: activeRequestCount
                        ))
                        return
                    }
                    timeout = remaining
                }
                guard activeRequestCount > 0 else {
                    immediate = .success(())
                    timeout = nil
                    return
                }
                requestGateWaiters[waiterID] = continuation
            }

            if let timeout {
                Task.detached { [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.timeOutRequestGateWaiter(waiterID)
                }
            }
            if let immediate {
                continuation.resume(returning: immediate)
            }
        }
        try result.get()
    }

    private func beginRequestProcessing(
        queue: Int,
        lifecycleEpoch: UInt64,
        virtqueue: Virtqueue,
        transport: VirtioMMIOTransport
    ) -> RequestBeginResult {
        // Resolve, but do not consume, the next exact admission shape before taking
        // requestGateLock. Queue access always precedes gate state elsewhere too, avoiding a
        // transport -> gate lock inversion. Rejected guest requests need no workspace lease.
        var queueFault: (any Error)?
        let preview: (opcode: FuseOpcode?, shape: DoryFSWorkerAdmissionShape?) =
            transport.withQueueLock {
            guard drainLock.withLock({ queueLifecycleEpochs[queue] == lifecycleEpoch }),
                  virtqueue.ready else { return (nil, nil) }
            let chain: VirtqueueChain
            do {
                guard let pending = try virtqueue.peek() else { return (nil, nil) }
                chain = pending
            } catch {
                queueFault = error
                return (nil, nil)
            }
            guard let preview = chain.withLeaseHeld({ access in
                VirtioFSRequestAdmission.preview(
                    chain: chain,
                    access: access,
                    queue: queue,
                    maximumRequestBytes: broker.effectiveAdmissionLimits.maximumRequestBytes,
                    maximumResponseBytes: broker.effectiveAdmissionLimits.maximumResponseBytes
                )
            }) else { return (nil, nil) }
            guard let requestBytes = preview.requestBytes,
                  let responseBytes = preview.responseBytes else {
                return (preview.opcode, nil)
            }
            return (
                preview.opcode,
                DoryFSWorkerAdmissionShape(
                    requestBytes: requestBytes,
                    responseBytes: responseBytes
                )
            )
        }
        if let queueFault {
            recordTerminalQueueFault(queueFault, queue: queue)
            return .deferred
        }
        return requestGateLock.withLock {
            guard !connectionResetPending, !requestGateFailureLatched else {
                grantedAdmissions.removeValue(forKey: queue)?.release()
                deferredRequestQueues.insert(queue)
                return .deferred
            }
            // A delayed write may be writeback copied before the host edit. Keep it in the guest's
            // available ring until reverse invalidation succeeds or the VM is discarded. All other
            // object operations must be able to finish so the guest can release VFS locks needed by
            // its notification worker. Unknown/malformed requests remain fail-closed.
            if requestGateClosed,
               preview.opcode?.mayDrainDuringReverseInvalidation != true {
                grantedAdmissions.removeValue(forKey: queue)?.release()
                deferredRequestQueues.insert(queue)
                return .deferred
            }
            guard let shape = preview.shape else {
                activeRequestCount += 1
                return .process(nil, previewOpcode: preview.opcode)
            }
            if let granted = grantedAdmissions.removeValue(forKey: queue) {
                guard granted.shape == shape else {
                    granted.release()
                    activeRequestCount += 1
                    return .process(nil, previewOpcode: preview.opcode)
                }
                activeRequestCount += 1
                return .process(granted, previewOpcode: preview.opcode)
            }
            guard !deferredAdmissionQueues.contains(queue) else { return .deferred }
            let waiterID = admissionWaiterIDs[queue]
            let result = broker.requestFrontendAdmission(
                shape: shape,
                waiterID: waiterID
            ) { [weak self, weak transport] resolution in
                switch resolution {
                case .granted(let lease):
                    guard let self, let transport else {
                        lease.release()
                        return
                    }
                    self.receiveGrantedAdmission(lease, queue: queue, transport: transport)
                case .terminated(let error):
                    self?.receiveTerminatedAdmission(error, queue: queue)
                }
            }
            switch result {
            case .admitted(let lease):
                activeRequestCount += 1
                return .process(lease, previewOpcode: preview.opcode)
            case .deferred:
                deferredAdmissionQueues.insert(queue)
                return .deferred
            case .rejected:
                // Exact per-request ceilings were already applied while peeking. If the typed
                // authority still rejects, consume this guest request only to publish retryable
                // EAGAIN; never reinterpret ordinary capacity as worker loss.
                activeRequestCount += 1
                return .process(nil, previewOpcode: preview.opcode)
            }
        }
    }

    func endRequestProcessing() {
        let result: (
            waiters: [CheckedContinuation<Result<Void, VirtioFSNotificationError>, Never>],
            shouldReset: Bool
        ) = requestGateLock.withLock {
            precondition(activeRequestCount > 0)
            activeRequestCount -= 1
            guard activeRequestCount == 0 else {
                return ([], false)
            }
            let shouldReset = connectionResetPending && !connectionResetInProgress
            if shouldReset {
                connectionResetInProgress = true
            }
            guard requestGateClosed else { return ([], shouldReset) }
            let waiters = Array(requestGateWaiters.values)
            requestGateWaiters.removeAll(keepingCapacity: true)
            return (waiters, shouldReset)
        }
        if result.shouldReset { invalidateWorkerForConnectionReset() }
        for waiter in result.waiters {
            waiter.resume(returning: .success(()))
        }
    }

    func receiveGrantedAdmission(
        _ lease: DoryFSWorkerAdmissionLease,
        queue: Int,
        transport: VirtioMMIOTransport
    ) {
        let shouldSchedule = requestGateLock.withLock {
            deferredAdmissionQueues.remove(queue)
            guard !connectionResetPending,
                  !requestGateFailureLatched,
                  grantedAdmissions[queue] == nil else { return false }
            grantedAdmissions[queue] = lease
            return true
        }
        guard shouldSchedule else {
            lease.release()
            return
        }
        workers.async { [weak self, weak transport] in
            guard let self, let transport else {
                lease.release()
                return
            }
            self.handleKick(queue: queue, transport: transport)
        }
    }

    func receiveTerminatedAdmission(
        _ error: DoryFSWorkerBrokerError,
        queue: Int
    ) {
        let shouldReport = requestGateLock.withLock {
            deferredAdmissionQueues.remove(queue)
            guard !frontendAdmissionTerminationReported else { return false }
            frontendAdmissionTerminationReported = true
            return true
        }
        guard shouldReport else { return }
        failWorker("filesystem worker admission terminated: \(error)")
    }

    func beginConnectionReset(
        transport: VirtioMMIOTransport,
        event: VirtioFSWorkerLifecycleEvent
    ) {
        let result = requestGateLock.withLock { () -> (Bool, FrontendAdmissionCleanup) in
            connectionResetPending = true
            connectionResetTransport = transport
            requestGateClosed = true
            requestGateFailureLatched = true
            let cleanup = detachFrontendAdmissionsLocked()
            if connectionResetEvent == nil {
                connectionResetEvent = event
            }
            guard activeRequestCount == 0,
                  !connectionResetInProgress else { return (false, cleanup) }
            connectionResetInProgress = true
            return (true, cleanup)
        }
        releaseFrontendAdmissions(result.1)
        guard result.0 else { return }
        invalidateWorkerForConnectionReset()
    }

    func invalidateWorkerForConnectionReset() {
        Task { [weak self] in
            guard let self else { return }
            let event = requestGateLock.withLock {
                connectionResetEvent
                    ?? .failure("filesystem worker generation invalidated by virtio-fs device reset")
            }
            let reportedEvent: VirtioFSWorkerLifecycleEvent
            switch event {
            case .connectionTeardown:
                do {
                    try await broker.completeConnectionTeardown()
                    reportedEvent = .connectionTeardown
                } catch {
                    await broker.invalidate()
                    reportedEvent = .failure(
                        "filesystem worker connection teardown was not quiescent: \(error)"
                    )
                }
            case .failure:
                await broker.invalidate()
                reportedEvent = event
            }
            onWorkerLifecycle(reportedEvent)
            finishConnectionReset()
        }
    }

    func finishConnectionReset() {
        let release: RequestGateRelease? = requestGateLock.withLock {
            guard connectionResetInProgress else { return nil }
            connectionResetInProgress = false
            connectionResetPending = false
            connectionResetEvent = nil
            if requestGateClosed {
                if requestGateTransport == nil {
                    requestGateTransport = connectionResetTransport
                }
                connectionResetTransport = nil
                return openRequestGateIfResolvedLocked()
            }
            let release = RequestGateRelease(
                transport: connectionResetTransport,
                queues: deferredRequestQueues.sorted()
            )
            connectionResetTransport = nil
            deferredRequestQueues.removeAll(keepingCapacity: true)
            return release
        }
        scheduleDeferredRequestDrains(release)
    }

    /// Establishes the high-level timeout boundary while still holding requestGateLock. Removing
    /// this waiter's submission slot here prevents a later active-response drain from resuming the
    /// timed-out operation or satisfying the normal gate-open bookkeeping.
    func timeOutRequestGateWaiter(_ waiterID: UUID) {
        let timedOut = requestGateLock.withLock {
            guard let waiter = requestGateWaiters.removeValue(forKey: waiterID) else {
                return nil as (
                    waiter: CheckedContinuation<Result<Void, VirtioFSNotificationError>, Never>,
                    activeRequests: Int
                )?
            }
            precondition(requestGateSubmissionsInProgress > 0)
            requestGateSubmissionsInProgress -= 1
            requestGateClosed = true
            requestGateFailureLatched = true
            return (waiter, activeRequestCount)
        }
        if let timedOut {
            timedOut.waiter.resume(returning: .failure(.requestDrainTimedOut(
                activeRequests: timedOut.activeRequests
            )))
        }
    }

    func bindRequestGate(
        to barrier: VirtioFSNotificationBarrier,
        transport: VirtioMMIOTransport,
        retainedByCaller: Bool
    ) {
        requestGateLock.withLock {
            precondition(requestGateClosed && requestGateSubmissionsInProgress > 0)
            requestGateSubmissionsInProgress -= 1
            let identifier = ObjectIdentifier(barrier)
            requestGateBarriers[identifier] = barrier
            if retainedByCaller {
                requestGateCallerRetainedBarriers.insert(identifier)
            }
            requestGateTransport = transport
        }
    }

    func finishRequestGateSubmissionWithoutBarrier(
        transport: VirtioMMIOTransport?,
        latchFailure: Bool
    ) {
        let release = requestGateLock.withLock {
            precondition(requestGateClosed && requestGateSubmissionsInProgress > 0)
            requestGateSubmissionsInProgress -= 1
            if let transport {
                requestGateTransport = transport
            }
            if latchFailure {
                requestGateFailureLatched = true
            }
            return openRequestGateIfResolvedLocked()
        }
        scheduleDeferredRequestDrains(release)
    }

    func resolveRequestGateBarrier(
        _ barrier: VirtioFSNotificationBarrier,
        transport: VirtioMMIOTransport?
    ) {
        let release = requestGateLock.withLock {
            guard requestGateBarriers.removeValue(forKey: ObjectIdentifier(barrier)) != nil else {
                return nil as RequestGateRelease?
            }
            if let transport {
                requestGateTransport = transport
            }
            return openRequestGateIfResolvedLocked()
        }
        scheduleDeferredRequestDrains(release)
    }

    func releaseCallerRetainedRequestGate(
        _ barrier: VirtioFSNotificationBarrier,
        succeeded: Bool
    ) {
        let identifier = ObjectIdentifier(barrier)
        let release = requestGateLock.withLock {
            guard requestGateCallerRetainedBarriers.remove(identifier) != nil else {
                return nil as RequestGateRelease?
            }
            if !succeeded {
                requestGateFailureLatched = true
                requestGateBarriers.removeValue(forKey: identifier)
            }
            return openRequestGateIfResolvedLocked()
        }
        scheduleDeferredRequestDrains(release)
    }

    /// One-way fail-stop for this VirtioFS instance. The machine recovery callback may run on a
    /// different executor, so the publication boundary must be established synchronously here.
    /// Constructing the replacement VM/backend is the only operation that clears this latch.
    func latchRequestGateFailure(barrier: VirtioFSNotificationBarrier?) {
        let cleanup = requestGateLock.withLock {
            requestGateClosed = true
            requestGateFailureLatched = true
            if let barrier {
                let identifier = ObjectIdentifier(barrier)
                requestGateBarriers.removeValue(forKey: identifier)
                requestGateCallerRetainedBarriers.remove(identifier)
            }
            return detachFrontendAdmissionsLocked()
        }
        releaseFrontendAdmissions(cleanup)
    }

    func openRequestGateIfResolvedLocked() -> RequestGateRelease? {
        guard requestGateClosed,
              !connectionResetPending,
              !requestGateFailureLatched,
              requestGateSubmissionsInProgress == 0,
              requestGateBarriers.isEmpty,
              requestGateCallerRetainedBarriers.isEmpty else {
            return nil
        }
        requestGateClosed = false
        let release = RequestGateRelease(
            transport: requestGateTransport,
            queues: deferredRequestQueues.sorted()
        )
        requestGateTransport = nil
        deferredRequestQueues.removeAll(keepingCapacity: true)
        return release
    }

    func scheduleDeferredRequestDrains(_ release: RequestGateRelease?) {
        guard let release, let transport = release.transport else { return }
        for queue in release.queues {
            workers.async { [weak self, weak transport] in
                guard let self, let transport else { return }
                self.handleKick(queue: queue, transport: transport)
            }
        }
    }

    func detachFrontendAdmissionsLocked() -> FrontendAdmissionCleanup {
        let waiters = deferredAdmissionQueues.map { admissionWaiterIDs[$0] }
        let leases = Array(grantedAdmissions.values)
        deferredAdmissionQueues.removeAll(keepingCapacity: false)
        grantedAdmissions.removeAll(keepingCapacity: false)
        return FrontendAdmissionCleanup(waiters: waiters, leases: leases)
    }

    func releaseFrontendAdmissions(_ cleanup: FrontendAdmissionCleanup) {
        for waiter in cleanup.waiters {
            broker.cancelFrontendAdmission(waiterID: waiter)
        }
        for lease in cleanup.leases { lease.release() }
    }

    static func clampedRequestQueueCount(_ count: Int) -> Int {
        min(16, max(1, count))
    }

}

private struct FrontendAdmissionCleanup {
    let waiters: [DoryFSWorkerAdmissionWaiterID]
    let leases: [DoryFSWorkerAdmissionLease]
}

private extension FuseOpcode {
    /// Requests that may be issued while Linux holds an inode, dentry, mapping, or folio lock
    /// needed by reverse invalidation. FUSE_WRITE is deliberately excluded: it can be delayed
    /// writeback copied before the host edit. Connection/control requests do not own those VFS
    /// locks and remain behind the boundary too, keeping the exceptional path minimal.
    var mayDrainDuringReverseInvalidation: Bool {
        switch self {
        case .write, .statfs, .syncfs, .initOp, .destroy, .interrupt, .notifyReply,
             .forget, .batchForget:
            false
        default:
            true
        }
    }
}

extension VirtioFS: @unchecked Sendable {}
