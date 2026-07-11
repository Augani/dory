import Foundation

public enum VirtioFSError: Error, Equatable {
    case invalidTag(String)
    case invalidDaxWindow
}

public struct VirtioFSDaxConfiguration: Equatable, Sendable {
    public var guestBase: UInt64
    public var length: UInt64

    public init(guestBase: UInt64, length: UInt64 = DaxWindow.defaultSize) {
        self.guestBase = guestBase
        self.length = length
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

public final class VirtioFS: VirtioDeviceBackend, VirtioSharedMemoryRegionProvider {
    public static let tagByteCount = 36
    public static let notificationFeature: UInt64 = 1 << 0
    static let traceInvalidations: Bool = {
        let value = ProcessInfo.processInfo.environment["DORY_FUSE_TRACE_INVAL"] ?? ""
        return ["1", "true", "yes", "on"].contains(value.lowercased())
    }()
    public static let notificationBufferSize: UInt32 = 4096
    /// Upper bound for positive entry and attribute validity in coherent mode. Open-file and
    /// directory cache flags remain disabled because they cannot be revoked after degradation.
    public static let maximumCoherentCacheValiditySeconds: UInt64 = FuseServer.maximumCoherentCacheValiditySeconds
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
    public let hostFS: HostFS
    public let daxConfiguration: VirtioFSDaxConfiguration?
    private let server: FuseServer
    private let stats: VirtioFSStats?
    private let inlineRequests: Bool
    public var deviceFeatures: UInt64 { Self.notificationFeature }

    // Small metadata-heavy workloads are latency-bound: dispatching every FUSE request to another
    // thread costs more than the host syscall. Inline processing is therefore the default, with an
    // environment opt-out for workloads that need the older worker-only behavior. The worker pool is
    // still used when inline mode is disabled and remains available for experimentation.
    private let workers = DispatchQueue(label: "dory-hv.virtiofs.worker", qos: .userInteractive, attributes: .concurrent)
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
    private var activeRequestCount = 0
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

    private let responseFenceTestHookLock = NSLock()
    private var _responseFenceTestHook: (@Sendable (FuseInHeader, FuseOpcode) -> Void)?
    private let requestGateDrainTestHookLock = NSLock()
    private var _requestGateDrainTestHook: (@Sendable (RequestGateDrainTestEvent) -> Void)?

    public convenience init(
        tag: String,
        hostFS: HostFS,
        daxConfiguration: VirtioFSDaxConfiguration? = nil,
        requestQueueCount requestedQueueCount: Int? = nil,
        notificationBacklogLimit requestedNotificationBacklogLimit: Int = 256
    ) throws {
        try self.init(
            tag: tag,
            hostFS: hostFS,
            daxConfiguration: daxConfiguration,
            requestQueueCount: requestedQueueCount,
            notificationBacklogLimit: requestedNotificationBacklogLimit,
            inlineRequests: nil
        )
    }

    init(
        tag: String,
        hostFS: HostFS,
        daxConfiguration: VirtioFSDaxConfiguration? = nil,
        requestQueueCount requestedQueueCount: Int? = nil,
        notificationBacklogLimit requestedNotificationBacklogLimit: Int = 256,
        inlineRequests requestedInlineRequests: Bool?
    ) throws {
        let bytes = Array(tag.utf8)
        guard !bytes.isEmpty, bytes.count < Self.tagByteCount else {
            throw VirtioFSError.invalidTag(tag)
        }
        if let daxConfiguration {
            guard daxConfiguration.guestBase.isMultiple(of: DaxWindow.pageSize),
                  daxConfiguration.length > 0,
                  daxConfiguration.length.isMultiple(of: DaxWindow.pageSize) else {
                throw VirtioFSError.invalidDaxWindow
            }
        }
        self.tag = tag
        self.hostFS = hostFS
        self.daxConfiguration = daxConfiguration
        self.requestQueueCount = Self.clampedRequestQueueCount(
            requestedQueueCount ?? Self.requestQueueCountFromEnvironment()
        )
        self.notificationBacklogLimit = min(4096, max(1, requestedNotificationBacklogLimit))
        self.queueCount = self.requestQueueCount + 2
        self.activeDrainerEpochs = Array(repeating: nil, count: self.queueCount)
        self.kickGenerations = Array(repeating: 0, count: self.queueCount)
        self.queueLifecycleEpochs = Array(repeating: 0, count: self.queueCount)
        self.stats = VirtioFSStats.fromEnvironment(tag: tag)
        self.inlineRequests = requestedInlineRequests ?? Self.inlineRequestsFromEnvironment()
        let daxWindow = try daxConfiguration.map {
            try DaxWindow(guestBase: $0.guestBase, length: $0.length, backend: FileBackedDaxMappingBackend())
        }
        self.server = FuseServer(hostFS: hostFS, daxWindow: daxWindow)
    }

    public var sharedMemoryRegions: [VirtioSharedMemoryRegion] {
        guard let daxConfiguration else { return [] }
        return [VirtioSharedMemoryRegion(id: 0, guestBase: daxConfiguration.guestBase, length: daxConfiguration.length)]
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
        server.coherentCachingActive
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

    var requestPublicationGateClosed: Bool {
        requestGateLock.withLock { requestGateClosed }
    }

    var deferredRequestQueueSnapshot: Set<Int> {
        requestGateLock.withLock { deferredRequestQueues }
    }

    /// Enables one-second positive entry/attribute validity only after notification negotiation, a
    /// ready queue, all 16 stable guest buffers, and FUSE INIT have been observed. Negative dentries,
    /// KEEP_CACHE, and CACHE_DIR remain disabled in every state.
    @discardableResult
    public func activateCoherentCaching() -> VirtioFSCacheActivationResult {
        notificationLock.lock()
        let eligibility = cacheActivationEligibilityLocked()
        guard eligibility.isEligible, server.activateCoherentCaching() else {
            notificationLock.unlock()
            return .ineligible(eligibility)
        }
        responseCacheEpoch &+= 1
        notificationLock.unlock()
        return .activated
    }

    /// Synchronously makes every subsequently encoded FUSE response use zero metadata validity.
    /// KEEP_CACHE and CACHE_DIR are never emitted, including while coherent caching is active.
    public func deactivateCoherentCaching() {
        notificationLock.withLock {
            server.deactivateCoherentCaching()
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
        notificationLock.lock()
        if notificationTransport === transport {
            staleBarriers = removeAllNotificationStateLocked()
        } else {
            staleBarriers = []
        }
        notificationLock.unlock()

        beginConnectionReset(transport: transport)
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
        try await submitInvalidations(invalidations, retainRequestGateForCaller: false)
    }

    private func submitInvalidations(
        _ invalidations: [VirtioFSInvalidation],
        retainRequestGateForCaller: Bool,
        requestGateDeadline: ContinuousClock.Instant? = nil
    ) async throws -> VirtioFSNotificationBarrier {
        guard !invalidations.isEmpty else {
            return VirtioFSNotificationBarrier(notificationCount: 0)
        }
        if Self.traceInvalidations {
            for invalidation in invalidations {
                FileHandle.standardError.write(Data("dory-hv: inval \(invalidation)\n".utf8))
            }
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
        return try submission.get()
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
            throw error
        }
    }

    public func handleKick(queue: Int, transport: VirtioMMIOTransport) {
        guard queue >= 0, queue < queueCount else { return }
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
        if inlineRequests {
            drain(queue: queue, lifecycleEpoch: lifecycleEpoch, transport: transport)
        } else {
            workers.async { [self] in
                drain(queue: queue, lifecycleEpoch: lifecycleEpoch, transport: transport)
            }
        }
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
            while true {
                guard beginRequestProcessing(
                    queue: queue,
                    lifecycleEpoch: lifecycleEpoch,
                    virtqueue: virtqueue,
                    transport: transport
                ) else {
                    requestGateDrainTestHook?(.deferred(queue: queue))
                    break
                }
                guard let chain = popChain(
                    queue: queue,
                    lifecycleEpoch: lifecycleEpoch,
                    virtqueue: virtqueue,
                    transport: transport
                ) else {
                    endRequestProcessing()
                    break
                }
                if process(
                    chain: chain,
                    queue: queue,
                    lifecycleEpoch: lifecycleEpoch,
                    virtqueue: virtqueue,
                    transport: transport
                ) {
                    shouldNotify = true
                }
                endRequestProcessing()
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

    private func popChain(
        queue: Int,
        lifecycleEpoch: UInt64,
        virtqueue: Virtqueue,
        transport: VirtioMMIOTransport
    ) -> VirtqueueChain? {
        transport.withQueueLock {
            guard drainLock.withLock({ queueLifecycleEpochs[queue] == lifecycleEpoch }),
                  virtqueue.ready else { return nil }
            return (try? virtqueue.pop()) ?? nil
        }
    }

    @discardableResult
    private func process(
        chain: VirtqueueChain,
        queue: Int,
        lifecycleEpoch: UInt64,
        virtqueue: Virtqueue,
        transport: VirtioMMIOTransport
    ) -> Bool {
        let requestEpochs: (notification: UInt64?, cache: UInt64) = notificationLock.withLock {
            (
                notificationTransport === transport ? notificationEpoch : nil,
                responseCacheEpoch
            )
        }
        let request = chain.readBytes()
        var written = 0
        var decoded: (header: FuseInHeader, opcode: FuseOpcode)?
        var statsStartNanoseconds: UInt64?
        var completesFuseInit = false
        var lifetimeGrantRolledBack = false
        if let header = try? FuseProtocol.decodeInHeader(request),
           header.length >= UInt32(FuseInHeader.byteCount), Int(header.length) <= request.count,
           let opcode = FuseOpcode(rawValue: header.opcode) {
            decoded = (header, opcode)
            if stats != nil {
                statsStartNanoseconds = DispatchTime.now().uptimeNanoseconds
            }
        }
        if chain.hasWritableSegments, let decoded {
            let header = decoded.header
            let opcode = decoded.opcode
            if opcode == .lookup {
                let payload = request[FuseInHeader.byteCount..<Int(header.length)]
                written = server.writeLookupResponse(header: header, payload: payload, writable: chain.writableSegments)
            } else if opcode == .getattr {
                let payload = request[FuseInHeader.byteCount..<Int(header.length)]
                written = server.writeGetattrResponse(
                    header: header,
                    payload: payload,
                    writable: chain.writableSegments
                )
            } else if opcode == .read {
                // Zero-copy fast path: preadv the payload straight into the guest's read buffers.
                let payload = request[FuseInHeader.byteCount..<Int(header.length)]
                written = server.writeReadResponse(header: header, payload: payload, writable: chain.writableSegments)
            } else if opcode == .write {
                let payload = request[FuseInHeader.byteCount..<Int(header.length)]
                written = server.writeWriteResponse(header: header, payload: payload, writable: chain.writableSegments)
            } else if opcode == .release || opcode == .releasedir {
                let payload = request[FuseInHeader.byteCount..<Int(header.length)]
                written = server.writeReleaseResponse(header: header, payload: payload, writable: chain.writableSegments)
            } else if opcode == .flush {
                let payload = request[FuseInHeader.byteCount..<Int(header.length)]
                written = server.writeFlushResponse(
                    header: header,
                    payload: payload,
                    writable: chain.writableSegments
                )
            } else if opcode == .getxattr {
                written = server.writeGetXattrNoDataResponse(header: header, writable: chain.writableSegments)
            } else if opcode == .create {
                let payload = request[FuseInHeader.byteCount..<Int(header.length)]
                written = server.writeCreateResponse(header: header, payload: payload, writable: chain.writableSegments)
            } else if opcode == .mkdir {
                let payload = request[FuseInHeader.byteCount..<Int(header.length)]
                written = server.writeMkdirResponse(header: header, payload: payload, writable: chain.writableSegments)
            } else if opcode == .unlink || opcode == .rmdir {
                let payload = request[FuseInHeader.byteCount..<Int(header.length)]
                written = server.writeRemoveResponse(header: header, opcode: opcode, payload: payload, writable: chain.writableSegments)
            }
        }
        if written == 0 {
            if let decoded {
                // FORGET/BATCH_FORGET deliberately have no reply. Every other valid FUSE request
                // needs at least one writable descriptor; never execute a stateful operation when
                // the guest supplied nowhere to publish its newly granted node/handle reference.
                if chain.hasWritableSegments
                    || decoded.opcode == .forget
                    || decoded.opcode == .batchForget {
                    let response = server.handle(
                        header: decoded.header,
                        opcode: decoded.opcode,
                        request: request
                    )
                    let responseWritten = chain.writeBytes(response)
                    if responseWritten == response.count {
                        written = responseWritten
                        completesFuseInit = decoded.opcode == .initOp
                            && (try? FuseProtocol.decodeOutHeader(response).error) == 0
                    } else {
                        // The operation may already have succeeded, but a partial FUSE frame is not
                        // publishable. Revoke its server-side grants and return a complete transport
                        // error when the chain can at least hold fuse_out_header.
                        server.rollbackUnpublishedResponse(
                            opcode: decoded.opcode,
                            response: response
                        )
                        lifetimeGrantRolledBack = true
                        var error = [UInt8]()
                        error.appendLE(UInt32(FuseOutHeader.byteCount))
                        error.appendLE(UInt32(bitPattern: -FuseProtocol.linuxErrno(EIO)))
                        error.appendLE(decoded.header.unique)
                        written = chain.writeBytes(error)
                        if written != error.count { written = 0 }
                    }
                }
            } else if chain.hasWritableSegments {
                written = chain.writeBytes(server.handle(request: request))
            }
        }
        if let decoded {
            responseFenceTestHook?(decoded.header, decoded.opcode)
        }
        // `Virtqueue.push` publishes unconditionally once the queue is live; its Bool only reports
        // whether the guest wants a used-ring interrupt (VRING_AVAIL_F_NO_INTERRUPT). Track
        // publication separately: treating interrupt suppression as a failed publish rolled back
        // handle/lookup grants the guest had legitimately received, poisoning rm/npm storms.
        var interruptWanted = false
        var publishFailureReason: String?
        let pushed = transport.withQueueLock {
            guard drainLock.withLock({ queueLifecycleEpochs[queue] == lifecycleEpoch }) else {
                publishFailureReason = "lifecycle epoch changed"
                return false
            }
            guard virtqueue.ready else {
                publishFailureReason = "queue not ready"
                return false
            }
            return notificationLock.withLock {
                if responseCacheEpoch != requestEpochs.cache, let decoded {
                    // Queue-health degradation can overtake a worker outside the register lock.
                    // Such a response may keep its payload, but it cannot carry a pre-degradation
                    // entry/attribute validity grant. Normal host edits use the full request gate,
                    // preserving LOOKUP identities and READ payload ordering as well.
                    _ = server.neutralizeCacheGrants(
                        opcode: decoded.opcode,
                        writable: chain.writableSegments,
                        written: written
                    )
                }
                // A high-level invalidation deadline is a one-way publication boundary. HostFS
                // work admitted before that boundary may already have performed its host syscall
                // and cannot be rolled back here, but its response must never become guest-visible
                // afterward. An already-admitted syscall cannot be canceled and keeps normal host
                // last-writer semantics; this fence covers only response publication and new work.
                return requestGateLock.withLock {
                    guard !requestGateFailureLatched else {
                        publishFailureReason = "request gate latched"
                        return false
                    }
                    do {
                        interruptWanted = try virtqueue.push(chain, written: written)
                        return true
                    } catch {
                        publishFailureReason = "virtqueue push threw: \(error)"
                        return false
                    }
                }
            }
        }
        if pushed, completesFuseInit, let requestNotificationEpoch = requestEpochs.notification {
            notificationLock.withLock {
                guard notificationTransport === transport,
                      notificationEpoch == requestNotificationEpoch else { return }
                server.markFuseInitCompleted()
            }
        }
        if !pushed, !lifetimeGrantRolledBack, let decoded {
            FileHandle.standardError.write(Data(
                "dory-hv: virtiofs response unpublished (\(publishFailureReason ?? "unknown")) op=\(decoded.opcode) unique=\(decoded.header.unique) queue=\(queue)\n".utf8
            ))
            server.rollbackUnpublishedResponse(
                opcode: decoded.opcode,
                writable: chain.writableSegments,
                written: written
            )
        }
        if let decoded, let statsStartNanoseconds {
            stats?.recordCompletion(
                decoded.opcode,
                durationNanoseconds: DispatchTime.now().uptimeNanoseconds &- statsStartNanoseconds
            )
        }
        return pushed && interruptWanted
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
        guard chain.readableSegments.isEmpty,
              chain.writableSegments.count == 1,
              let segment = chain.writableSegments.first,
              segment.length >= Int(Self.notificationBufferSize) else {
            return nil
        }
        // The patched guest reuses its kzalloc'd page but virtio may choose a new descriptor head
        // when it reposts it. GuestMemory has a stable mapping, so its host pointer is a stable
        // identity for the underlying guest buffer across those descriptor changes.
        return NotificationBuffer(key: UInt(bitPattern: segment.pointer), chain: chain)
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
        server.deactivateCoherentCaching(resetFuseInit: resetFuseInit)
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
            fuseInitCompleted: server.fuseInitCompleted
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

    func beginRequestProcessing(
        queue: Int,
        lifecycleEpoch: UInt64,
        virtqueue: Virtqueue,
        transport: VirtioMMIOTransport
    ) -> Bool {
        // Resolve, but do not consume, the next opcode before taking requestGateLock. Queue access
        // always precedes gate state elsewhere too, avoiding a transport -> gate lock inversion.
        let opcode: FuseOpcode? = transport.withQueueLock {
            guard drainLock.withLock({ queueLifecycleEpochs[queue] == lifecycleEpoch }),
                  virtqueue.ready,
                  let chain = try? virtqueue.peek() else { return nil }
            let request = chain.readBytes(maximum: FuseInHeader.byteCount)
            guard let header = try? FuseProtocol.decodeInHeader(request) else { return nil }
            return FuseOpcode(rawValue: header.opcode)
        }
        return requestGateLock.withLock {
            guard !connectionResetPending, !requestGateFailureLatched else {
                deferredRequestQueues.insert(queue)
                return false
            }
            // A delayed write may be writeback copied before the host edit. Keep it in the guest's
            // available ring until reverse invalidation succeeds or the VM is discarded. All other
            // object operations must be able to finish so the guest can release VFS locks needed by
            // its notification worker. Unknown/malformed requests remain fail-closed.
            if requestGateClosed,
               opcode?.mayDrainDuringReverseInvalidation != true {
                deferredRequestQueues.insert(queue)
                return false
            }
            activeRequestCount += 1
            return true
        }
    }

    func endRequestProcessing() {
        let result: (
            waiters: [CheckedContinuation<Result<Void, VirtioFSNotificationError>, Never>],
            shouldReset: Bool
        ) = requestGateLock.withLock {
            precondition(activeRequestCount > 0)
            activeRequestCount -= 1
            guard activeRequestCount == 0 else { return ([], false) }
            let shouldReset = connectionResetPending && !connectionResetInProgress
            if shouldReset {
                connectionResetInProgress = true
            }
            guard requestGateClosed else { return ([], shouldReset) }
            let waiters = Array(requestGateWaiters.values)
            requestGateWaiters.removeAll(keepingCapacity: true)
            return (waiters, shouldReset)
        }
        if result.shouldReset {
            server.resetConnection()
            finishConnectionReset()
        }
        for waiter in result.waiters {
            waiter.resume(returning: .success(()))
        }
    }

    func beginConnectionReset(transport: VirtioMMIOTransport) {
        let shouldReset = requestGateLock.withLock {
            connectionResetPending = true
            connectionResetTransport = transport
            guard activeRequestCount == 0, !connectionResetInProgress else { return false }
            connectionResetInProgress = true
            return true
        }
        guard shouldReset else { return }
        server.resetConnection()
        finishConnectionReset()
    }

    func finishConnectionReset() {
        let release: RequestGateRelease? = requestGateLock.withLock {
            guard connectionResetInProgress else { return nil }
            connectionResetInProgress = false
            connectionResetPending = false
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
        requestGateLock.withLock {
            requestGateClosed = true
            requestGateFailureLatched = true
            if let barrier {
                let identifier = ObjectIdentifier(barrier)
                requestGateBarriers.removeValue(forKey: identifier)
                requestGateCallerRetainedBarriers.remove(identifier)
            }
        }
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

    static func requestQueueCountFromEnvironment() -> Int {
        guard let value = ProcessInfo.processInfo.environment["DORY_FUSE_QUEUES"].flatMap(Int.init) else {
            return min(8, max(1, ProcessInfo.processInfo.activeProcessorCount))
        }
        return value
    }

    static func clampedRequestQueueCount(_ count: Int) -> Int {
        min(16, max(1, count))
    }

    static func inlineRequestsFromEnvironment() -> Bool {
        guard let value = ProcessInfo.processInfo.environment["DORY_FUSE_INLINE"]?.lowercased() else {
            return true
        }
        return !["0", "false", "no", "off"].contains(value)
    }
}

private extension FuseOpcode {
    /// Requests that may be issued while Linux holds an inode, dentry, mapping, or folio lock
    /// needed by reverse invalidation. FUSE_WRITE is deliberately excluded: it can be delayed
    /// writeback copied before the host edit. Connection/control requests do not own those VFS
    /// locks and remain behind the boundary too, keeping the exceptional path minimal.
    var mayDrainDuringReverseInvalidation: Bool {
        switch self {
        case .write, .statfs, .initOp, .destroy, .interrupt, .notifyReply,
             .forget, .batchForget:
            false
        default:
            true
        }
    }
}

private final class VirtioFSStats: @unchecked Sendable {
    private let tag: String
    private let lock = NSLock()
    private var counts: [FuseOpcode: Int] = [:]
    private var durationNanoseconds: [FuseOpcode: UInt64] = [:]
    private var total = 0

    init(tag: String) {
        self.tag = tag
    }

    static func fromEnvironment(tag: String) -> VirtioFSStats? {
        let value = ProcessInfo.processInfo.environment["DORY_FUSE_STATS"] ?? ""
        guard ["1", "true", "yes", "on"].contains(value.lowercased()) else { return nil }
        FileHandle.standardError.write(Data("dory-hv: virtiofs stats enabled tag=\(tag)\n".utf8))
        return VirtioFSStats(tag: tag)
    }

    func recordCompletion(_ opcode: FuseOpcode, durationNanoseconds elapsed: UInt64) {
        let snapshot: (Int, [FuseOpcode: Int], [FuseOpcode: UInt64])? = lock.withLock {
            total += 1
            counts[opcode, default: 0] += 1
            durationNanoseconds[opcode, default: 0] &+= elapsed
            guard total <= 20 || total.isMultiple(of: 100) else { return nil }
            return (total, counts, durationNanoseconds)
        }
        guard let snapshot else { return }
        let line = snapshot.1
            .sorted { lhs, rhs in lhs.key.rawValue < rhs.key.rawValue }
            .map { opcode, count in
                let nanoseconds = snapshot.2[opcode] ?? 0
                let totalMilliseconds = Double(nanoseconds) / 1_000_000
                let averageMicroseconds = count == 0 ? 0 : Double(nanoseconds) / Double(count) / 1_000
                let totalText = String(format: "%.3f", totalMilliseconds)
                let averageText = String(format: "%.1f", averageMicroseconds)
                return "\(opcode)=\(count)/\(totalText)ms/\(averageText)us"
            }
            .joined(separator: " ")
        FileHandle.standardError.write(Data("dory-hv: virtiofs stats tag=\(tag) total=\(snapshot.0) \(line)\n".utf8))
    }
}

extension VirtioFS: @unchecked Sendable {}
