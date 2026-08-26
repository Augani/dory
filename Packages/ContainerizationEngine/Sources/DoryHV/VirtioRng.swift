import Foundation
import Security
import Synchronization

public struct VirtioRngStatistics: Equatable, Sendable {
    public var completedRequests: UInt64
    public var bytesProvided: UInt64
    public var invalidRequests: UInt64
    public var entropyFailures: UInt64
    public var queueFaults: UInt64
    public var boundedDrainStops: UInt64
    public var workerTurns: UInt64
    public var workerYields: UInt64
    public var coalescedWorkerRequests: UInt64
    public var revokedWorkerTurns: UInt64
    public var entropyProcessingNanoseconds: UInt64
    public var maximumEntropyProcessingNanoseconds: UInt64
}

/// Device-specific work bounds. VirtIO permits the device to return fewer bytes than the guest
/// offered, and Linux currently submits only a cache-line-sized buffer. A fixed partial completion
/// therefore avoids guest-sized entropy work while remaining protocol-correct. The turn bound is
/// intentionally much smaller than the ring: a busy guest yields between batches without needing
/// another notification to make progress.
struct VirtioRngLimits: Equatable, Sendable {
    static let production = VirtioRngLimits(
        maximumBytesPerRequest: 4 * 1_024,
        maximumRequestsPerWorkerTurn: 8
    )

    let maximumBytesPerRequest: Int
    let maximumRequestsPerWorkerTurn: Int

    init(maximumBytesPerRequest: Int, maximumRequestsPerWorkerTurn: Int) {
        precondition(maximumBytesPerRequest > 0)
        precondition(maximumRequestsPerWorkerTurn > 0)
        precondition(maximumRequestsPerWorkerTurn <= Int(Virtqueue.maximumSize))
        self.maximumBytesPerRequest = maximumBytesPerRequest
        self.maximumRequestsPerWorkerTurn = maximumRequestsPerWorkerTurn
    }
}

/// virtio-entropy: fills guest buffers from the host CSPRNG. Keeps the guest crng healthy in a
/// machine with almost no interrupt-timing entropy. Queue notifications only schedule a bounded
/// serial worker turn; CSPRNG calls and used-ring publication never run on the notifying vCPU.
public final class VirtioRng: VirtioDeviceBackend, @unchecked Sendable {
    public let deviceID: UInt32 = 4
    public let queueCount = 1
    public let deviceFeatures: UInt64 = 0
    public let kickSynchronization: VirtioKickSynchronization = .backendManaged
    public var configSpace: [UInt8] { [] }

    private final class WeakTransportReference: @unchecked Sendable {
        weak var value: VirtioMMIOTransport?

        init(_ value: VirtioMMIOTransport) {
            self.value = value
        }
    }

    private struct WorkerState {
        var transport: WeakTransportReference?
        var generation: UInt64 = 1
        var scheduled = false
        var kickPending = false
    }

    private enum RequestAdmission {
        case accepted(Int)
        case invalid
        case revoked
    }

    private enum PreparedWork {
        case empty
        case completed(wantsInterrupt: Bool)
        case entropy(chain: VirtqueueChain, requestedBytes: Int)
        case fault
        case stale
    }

    private enum EntropyCompletion {
        case published(wantsInterrupt: Bool)
        case fault
        case stale
    }

    private let limits: VirtioRngLimits
    private let fillEntropy: @Sendable (UnsafeMutableRawBufferPointer) -> Bool
    private let submitWork: (@escaping @Sendable () -> Void) -> Void
    private let monotonicNanoseconds: @Sendable () -> UInt64
    private let workerStateLock = NSLock()
    // Reset and QueueReady callbacks hold the transport lock before entering this fence. A worker
    // never takes the transport lock while holding it. Thus an in-flight entropy fill and its one
    // lease-held guest write finish before lifecycle revocation, without a lock-order cycle.
    private let lifecycleFence = NSLock()
    private var workerState = WorkerState()
    private let completedRequests = Atomic<UInt64>(0)
    private let bytesProvided = Atomic<UInt64>(0)
    private let invalidRequests = Atomic<UInt64>(0)
    private let entropyFailures = Atomic<UInt64>(0)
    private let queueFaults = Atomic<UInt64>(0)
    private let boundedDrainStops = Atomic<UInt64>(0)
    private let workerTurns = Atomic<UInt64>(0)
    private let workerYields = Atomic<UInt64>(0)
    private let coalescedWorkerRequests = Atomic<UInt64>(0)
    private let revokedWorkerTurns = Atomic<UInt64>(0)
    private let entropyProcessingNanoseconds = Atomic<UInt64>(0)
    private let maximumEntropyProcessingNanoseconds = Mutex<UInt64>(0)

    public convenience init() {
        let worker = DispatchQueue(label: "dev.dory.virtio-rng", qos: .utility)
        self.init(
            limits: .production,
            fillEntropy: { buffer in
                guard let baseAddress = buffer.baseAddress else { return false }
                return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
                    == errSecSuccess
            },
            submitWork: { operation in worker.async(execute: operation) }
        )
    }

    init(
        limits: VirtioRngLimits,
        fillEntropy: @escaping @Sendable (UnsafeMutableRawBufferPointer) -> Bool,
        submitWork: @escaping (@escaping @Sendable () -> Void) -> Void,
        monotonicNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        self.limits = limits
        self.fillEntropy = fillEntropy
        self.submitWork = submitWork
        self.monotonicNanoseconds = monotonicNanoseconds
    }

    public func handleKick(queue: Int, transport: VirtioMMIOTransport) {
        guard queue == 0, transport.queues.indices.contains(queue) else { return }
        let generation = workerStateLock.withLock { () -> UInt64? in
            if let reference = workerState.transport {
                if let existing = reference.value {
                    guard existing === transport else {
                        queueFaults.wrappingAdd(1, ordering: .relaxed)
                        return nil
                    }
                } else {
                    // Rebinding a synthetic backend after its transport died must first make every
                    // closure queued for that transport stale.
                    advanceWorkerGenerationLocked()
                    workerState.transport = WeakTransportReference(transport)
                }
            } else {
                workerState.transport = WeakTransportReference(transport)
            }

            if workerState.scheduled {
                workerState.kickPending = true
                coalescedWorkerRequests.wrappingAdd(1, ordering: .relaxed)
                return nil
            }
            workerState.scheduled = true
            return workerState.generation
        }
        guard let generation else { return }
        submitWorkerTurn(generation: generation, transport: transport)
    }

    public func deviceReset(transport: VirtioMMIOTransport) {
        revokeWorker(transport: transport)
    }

    public func queueStateChanged(
        queue: Int,
        ready: Bool,
        transport: VirtioMMIOTransport
    ) {
        _ = ready
        guard queue == 0 else { return }
        revokeWorker(transport: transport)
    }

    private func submitWorkerTurn(generation: UInt64, transport: VirtioMMIOTransport) {
        submitWork { [weak self, weak transport] in
            guard let self, let transport else { return }
            self.runWorkerTurn(generation: generation, transport: transport)
        }
    }

    private func runWorkerTurn(generation: UInt64, transport: VirtioMMIOTransport) {
        guard beginWorkerTurn(generation: generation, transport: transport) else {
            recordRevokedWorkerTurn(generation: generation, transport: transport)
            return
        }
        workerTurns.wrappingAdd(1, ordering: .relaxed)
        var handled = 0
        var wantsInterrupt = false
        var stoppedOnFault = false

        while handled < limits.maximumRequestsPerWorkerTurn {
            switch prepareWork(generation: generation, transport: transport) {
            case .empty:
                finishWorkerTurn(
                    generation: generation,
                    transport: transport,
                    wantsInterrupt: wantsInterrupt,
                    knownPendingWork: false
                )
                return
            case let .completed(interrupt):
                handled += 1
                wantsInterrupt = wantsInterrupt || interrupt
            case let .entropy(chain, requestedBytes):
                handled += 1
                switch completeEntropy(
                    chain,
                    requestedBytes: requestedBytes,
                    generation: generation,
                    transport: transport
                ) {
                case let .published(interrupt):
                    wantsInterrupt = wantsInterrupt || interrupt
                case .fault:
                    stoppedOnFault = true
                case .stale:
                    recordRevokedWorkerTurn(generation: generation, transport: transport)
                    return
                }
            case .fault:
                stoppedOnFault = true
            case .stale:
                recordRevokedWorkerTurn(generation: generation, transport: transport)
                return
            }
            if stoppedOnFault { break }
        }

        let pending = stoppedOnFault ? false : pendingWork(
            generation: generation,
            transport: transport
        )
        if pending {
            boundedDrainStops.wrappingAdd(1, ordering: .relaxed)
        }
        finishWorkerTurn(
            generation: generation,
            transport: transport,
            wantsInterrupt: wantsInterrupt,
            knownPendingWork: pending
        )
    }

    private func prepareWork(
        generation: UInt64,
        transport: VirtioMMIOTransport
    ) -> PreparedWork {
        transport.withQueueLock {
            guard isCurrentWorker(generation: generation, transport: transport) else {
                return .stale
            }
            let virtqueue = transport.queues[0]
            let chain: VirtqueueChain
            do {
                guard let next = try virtqueue.pop() else { return .empty }
                chain = next
            } catch {
                // pop() consumes a malformed available entry before descriptor resolution fails.
                // Stop this turn explicitly rather than walking unrelated later entries.
                queueFaults.wrappingAdd(1, ordering: .relaxed)
                return .fault
            }

            switch admitRequest(chain) {
            case .invalid:
                invalidRequests.wrappingAdd(1, ordering: .relaxed)
                do {
                    switch try virtqueue.pushOutcome(chain, written: 0) {
                    case let .published(wantsInterrupt):
                        return .completed(wantsInterrupt: wantsInterrupt)
                    case .revoked:
                        return .stale
                    }
                } catch {
                    queueFaults.wrappingAdd(1, ordering: .relaxed)
                    return .fault
                }
            case .revoked:
                return .stale
            case let .accepted(requestedBytes):
                // The popped chain and its exact queue lease are retained across the CSPRNG call.
                // Only this chain can be published, and pushOutcome exposes lifecycle revocation.
                return .entropy(chain: chain, requestedBytes: requestedBytes)
            }
        }
    }

    private func completeEntropy(
        _ chain: VirtqueueChain,
        requestedBytes: Int,
        generation: UInt64,
        transport: VirtioMMIOTransport
    ) -> EntropyCompletion {
        // Allocate only the typed device ceiling, never the guest chain length. Entropy remains in
        // a host-owned snapshot until the fill reports success, so a failed CSPRNG call cannot
        // expose partially initialized bytes to the guest.
        var entropy = [UInt8](repeating: 0, count: requestedBytes)
        lifecycleFence.lock()
        guard isCurrentWorker(generation: generation, transport: transport) else {
            lifecycleFence.unlock()
            return .stale
        }
        let startedAt = monotonicNanoseconds()
        let didFill = entropy.withUnsafeMutableBytes(fillEntropy)
        let written = didFill ? (chain.withLeaseHeld { $0.writeBytes(entropy) } ?? 0) : 0
        let elapsed = monotonicNanoseconds() &- startedAt
        lifecycleFence.unlock()

        entropyProcessingNanoseconds.wrappingAdd(elapsed, ordering: .relaxed)
        maximumEntropyProcessingNanoseconds.withLock { maximum in
            maximum = max(maximum, elapsed)
        }

        if didFill {
            guard written == requestedBytes else {
                queueFaults.wrappingAdd(1, ordering: .relaxed)
                return .fault
            }
        } else {
            entropyFailures.wrappingAdd(1, ordering: .relaxed)
        }

        return transport.withQueueLock {
            guard isCurrentWorker(generation: generation, transport: transport) else {
                return .stale
            }
            do {
                switch try transport.queues[0].pushOutcome(chain, written: written) {
                case let .published(wantsInterrupt):
                    if didFill {
                        completedRequests.wrappingAdd(1, ordering: .relaxed)
                        bytesProvided.wrappingAdd(UInt64(written), ordering: .relaxed)
                    }
                    return .published(wantsInterrupt: wantsInterrupt)
                case .revoked:
                    return .stale
                }
            } catch {
                queueFaults.wrappingAdd(1, ordering: .relaxed)
                return .fault
            }
        }
    }

    private func pendingWork(generation: UInt64, transport: VirtioMMIOTransport) -> Bool {
        transport.withQueueLock {
            guard isCurrentWorker(generation: generation, transport: transport) else {
                return false
            }
            do {
                return try transport.queues[0].pendingCount() > 0
            } catch {
                queueFaults.wrappingAdd(1, ordering: .relaxed)
                return false
            }
        }
    }

    private func finishWorkerTurn(
        generation: UInt64,
        transport: VirtioMMIOTransport,
        wantsInterrupt: Bool,
        knownPendingWork: Bool
    ) {
        if wantsInterrupt {
            transport.withQueueLock {
                if isCurrentWorker(generation: generation, transport: transport) {
                    transport.notifyUsed()
                }
            }
        }

        let shouldContinue = workerStateLock.withLock { () -> Bool in
            guard isCurrentWorkerLocked(generation: generation, transport: transport) else {
                return false
            }
            let pending = knownPendingWork || workerState.kickPending
            workerState.kickPending = false
            if !pending {
                workerState.scheduled = false
            }
            return pending
        }
        if shouldContinue {
            workerYields.wrappingAdd(1, ordering: .relaxed)
            submitWorkerTurn(generation: generation, transport: transport)
        }
    }

    private func revokeWorker(transport: VirtioMMIOTransport) {
        lifecycleFence.lock()
        workerStateLock.withLock {
            if let existing = workerState.transport?.value, existing !== transport {
                queueFaults.wrappingAdd(1, ordering: .relaxed)
                return
            }
            if workerState.transport == nil {
                workerState.transport = WeakTransportReference(transport)
            }
            advanceWorkerGenerationLocked()
        }
        lifecycleFence.unlock()
    }

    private func advanceWorkerGenerationLocked() {
        workerState.generation &+= 1
        if workerState.generation == 0 {
            workerState.generation = 1
        }
        workerState.scheduled = false
        workerState.kickPending = false
    }

    private func recordRevokedWorkerTurn(
        generation: UInt64,
        transport: VirtioMMIOTransport
    ) {
        revokedWorkerTurns.wrappingAdd(1, ordering: .relaxed)
        // A typed queue-lease revocation can theoretically precede a lifecycle callback. If the
        // worker generation is otherwise still current, revoke it here so no scheduled bit can
        // strand later kicks. Normal reset/QueueReady paths have already advanced the generation.
        workerStateLock.withLock {
            if isCurrentWorkerLocked(generation: generation, transport: transport) {
                advanceWorkerGenerationLocked()
            }
        }
    }

    private func isCurrentWorker(generation: UInt64, transport: VirtioMMIOTransport) -> Bool {
        workerStateLock.withLock {
            isCurrentWorkerLocked(generation: generation, transport: transport)
        }
    }

    private func beginWorkerTurn(
        generation: UInt64,
        transport: VirtioMMIOTransport
    ) -> Bool {
        workerStateLock.withLock {
            guard isCurrentWorkerLocked(generation: generation, transport: transport) else {
                return false
            }
            // Notifications coalesced before this turn began are covered by the queue snapshot it
            // is about to drain. A later notification sets the bit again and forces a continuation.
            workerState.kickPending = false
            return true
        }
    }

    private func isCurrentWorkerLocked(
        generation: UInt64,
        transport: VirtioMMIOTransport
    ) -> Bool {
        workerState.transport?.value === transport
            && workerState.generation == generation
            && workerState.scheduled
    }

    private func admitRequest(_ chain: VirtqueueChain) -> RequestAdmission {
        chain.withLeaseHeld { access -> RequestAdmission in
            // VirtIO 1.3 section 5.4.6.1 forbids device-readable entropy buffers. A raw
            // zero-length descriptor is also not a usable request, even when another segment in
            // the same chain has data.
            guard !chain.containsZeroLengthDescriptor,
                  access.readableSegmentCount == 0,
                  access.writableSegmentCount > 0,
                  access.writableByteCount > 0 else { return .invalid }
            return .accepted(min(access.writableByteCount, limits.maximumBytesPerRequest))
        } ?? .revoked
    }

    public var statistics: VirtioRngStatistics {
        VirtioRngStatistics(
            completedRequests: completedRequests.load(ordering: .relaxed),
            bytesProvided: bytesProvided.load(ordering: .relaxed),
            invalidRequests: invalidRequests.load(ordering: .relaxed),
            entropyFailures: entropyFailures.load(ordering: .relaxed),
            queueFaults: queueFaults.load(ordering: .relaxed),
            boundedDrainStops: boundedDrainStops.load(ordering: .relaxed),
            workerTurns: workerTurns.load(ordering: .relaxed),
            workerYields: workerYields.load(ordering: .relaxed),
            coalescedWorkerRequests: coalescedWorkerRequests.load(ordering: .relaxed),
            revokedWorkerTurns: revokedWorkerTurns.load(ordering: .relaxed),
            entropyProcessingNanoseconds: entropyProcessingNanoseconds.load(ordering: .relaxed),
            maximumEntropyProcessingNanoseconds: maximumEntropyProcessingNanoseconds.withLock { $0 }
        )
    }
}
