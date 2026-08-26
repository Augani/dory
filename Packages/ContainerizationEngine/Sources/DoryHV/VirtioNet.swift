import Darwin
import Foundation
import Synchronization

/// Event totals and bounded-resource gauges for one virtio-net backend. Event totals wrap modulo
/// 2^64. Queue depth, high-watermark, and latency maxima are point-in-time/high-water gauges.
public struct VirtioNetStatistics: Equatable, Sendable {
    public var transmitPackets: UInt64
    public var transmitBytes: UInt64
    public var transmitDrops: UInt64
    public var transmitMalformed: UInt64
    public var transmitOversized: UInt64
    public var transmitInvalidDescriptors: UInt64
    public var transmitBackpressure: UInt64
    public var transmitSocketErrors: UInt64 = 0
    public var transmitRetryWakeups: UInt64 = 0
    public var transmitBoundedDrainStops: UInt64 = 0
    public var transmitCompletions: UInt64 = 0
    public var transmitCompletionLatencyNanoseconds: UInt64 = 0
    public var transmitMaximumCompletionLatencyNanoseconds: UInt64 = 0
    public var transmitOldestPendingLatencyNanoseconds: UInt64 = 0
    public var transmitQueueDepth: UInt64 = 0
    public var transmitQueueHighWatermark: UInt64 = 0
    public var receivePackets: UInt64
    public var receiveBytes: UInt64
    public var receiveDeferred: UInt64
    public var receiveDrops: UInt64
    /// Datagram payloads larger than the configured Ethernet ceiling. Kept under the established
    /// telemetry name because the bounded recv buffer necessarily truncates their discarded tail.
    public var receiveTruncations: UInt64
    public var receiveMalformed: UInt64
    public var receiveInvalidDescriptors: UInt64
    public var receiveInsufficientCapacity: UInt64
    public var receiveBacklogDrops: UInt64
    public var receiveInactiveDrops: UInt64
    public var receiveSocketErrors: UInt64
    public var receiveActivationFailures: UInt64
}

/// Immutable per-device work and memory limits. They are resolved when the backend is constructed;
/// the datapath never derives scheduling or capacity from ambient host CPU/global state.
struct VirtioNetLimits: Equatable, Sendable {
    static let production = VirtioNetLimits(
        maximumDeferredReceiveFrames: 256,
        maximumDeferredReceiveBytes: 4 * 1_024 * 1_024,
        maximumSocketReceiveOperationsPerTurn: 128,
        maximumSocketReceiveBytesPerTurn: 1 * 1_024 * 1_024,
        maximumActivationPurgeTurns: 64,
        maximumTransmitOperationsPerTurn: 64,
        maximumTransmitBytesPerTurn: 256 * 1_024,
        minimumTransmitRetryDelayNanoseconds: 250_000,
        maximumTransmitRetryDelayNanoseconds: 8_000_000
    )

    let maximumDeferredReceiveFrames: Int
    let maximumDeferredReceiveBytes: Int
    let maximumSocketReceiveOperationsPerTurn: Int
    let maximumSocketReceiveBytesPerTurn: Int
    let maximumActivationPurgeTurns: Int
    let maximumTransmitOperationsPerTurn: Int
    let maximumTransmitBytesPerTurn: Int
    let minimumTransmitRetryDelayNanoseconds: Int
    let maximumTransmitRetryDelayNanoseconds: Int

    init(
        maximumDeferredReceiveFrames: Int,
        maximumDeferredReceiveBytes: Int,
        maximumSocketReceiveOperationsPerTurn: Int = 128,
        maximumSocketReceiveBytesPerTurn: Int = 1 * 1_024 * 1_024,
        maximumActivationPurgeTurns: Int = 64,
        maximumTransmitOperationsPerTurn: Int = 64,
        maximumTransmitBytesPerTurn: Int = 256 * 1_024,
        minimumTransmitRetryDelayNanoseconds: Int = 250_000,
        maximumTransmitRetryDelayNanoseconds: Int = 8_000_000
    ) {
        self.maximumDeferredReceiveFrames = maximumDeferredReceiveFrames
        self.maximumDeferredReceiveBytes = maximumDeferredReceiveBytes
        self.maximumSocketReceiveOperationsPerTurn = maximumSocketReceiveOperationsPerTurn
        self.maximumSocketReceiveBytesPerTurn = maximumSocketReceiveBytesPerTurn
        self.maximumActivationPurgeTurns = maximumActivationPurgeTurns
        self.maximumTransmitOperationsPerTurn = maximumTransmitOperationsPerTurn
        self.maximumTransmitBytesPerTurn = maximumTransmitBytesPerTurn
        self.minimumTransmitRetryDelayNanoseconds = minimumTransmitRetryDelayNanoseconds
        self.maximumTransmitRetryDelayNanoseconds = maximumTransmitRetryDelayNanoseconds
    }
}

/// virtio-net wired to a userspace network stack (gvproxy) over a Unix datagram socket, one
/// Ethernet frame per datagram (the vfkit protocol). Dory offers MAC and MTU only: it does not
/// negotiate checksum, segmentation, mergeable-buffer, or guest-offload features.
public final class VirtioNet: VirtioDeviceBackend, @unchecked Sendable {
    public let deviceID: UInt32 = 1
    public let queueCount = 2  // 0 = receive, 1 = transmit
    public let deviceFeatures: UInt64
    public let kickSynchronization: VirtioKickSynchronization = .backendManaged

    /// gvproxy's canonical vfkit guest MAC; its DHCP hands this MAC 192.168.127.2.
    public static let guestMAC: [UInt8] = [0x5A, 0x94, 0xEF, 0xE4, 0x0C, 0xEE]

    private static let headerLength = 12
    private static let ethernetHeaderLength = 14
    private static let minimumSupportedMTU = 1_280
    private static let maximumSupportedMTU = 9_000
    private static let vfkitMagic: [UInt8] = Array("VFKT".utf8)
    private static let knownHeaderFlagsMask: UInt8 = 0x07
    private static let socketPathMutationLock = NSLock()

    private struct SocketPathIdentity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        let generation: UInt32
        let birthTimeSeconds: Int64
        let birthTimeNanoseconds: Int64
        let owner: uid_t
    }

    private struct DirectoryIdentity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        let generation: UInt32
        let birthTimeSeconds: Int64
        let birthTimeNanoseconds: Int64
        let owner: uid_t
        let permissions: mode_t
    }

    private enum ExistingEndpointProbe {
        case live
        case stale
        case indeterminate(Int32)
    }

    private final class SocketOwner: @unchecked Sendable {
        let descriptor: Int32
        let localPath: String
        let localIdentity: SocketPathIdentity
        let parentPath: String
        let parentIdentity: DirectoryIdentity
        let usedPathnamePeerAuthentication: Bool
        private let lock = NSLock()
        private var acceptsOperations = true
        private var hasRetired = false

        init(
            descriptor: Int32,
            localPath: String,
            localIdentity: SocketPathIdentity,
            parentPath: String,
            parentIdentity: DirectoryIdentity,
            usedPathnamePeerAuthentication: Bool
        ) {
            self.descriptor = descriptor
            self.localPath = localPath
            self.localIdentity = localIdentity
            self.parentPath = parentPath
            self.parentIdentity = parentIdentity
            self.usedPathnamePeerAuthentication = usedPathnamePeerAuthentication
        }

        func withDescriptor<Result>(_ body: (Int32) -> Result) -> Result? {
            lock.lock()
            defer { lock.unlock() }
            guard acceptsOperations, !hasRetired else { return nil }
            return body(descriptor)
        }

        func disableOperations() {
            lock.lock()
            acceptsOperations = false
            lock.unlock()
        }

        func retire() {
            lock.lock()
            acceptsOperations = false
            guard !hasRetired else {
                lock.unlock()
                return
            }
            hasRetired = true
            lock.unlock()
            VirtioNet.retireOwnedSocket(
                descriptor: descriptor,
                path: localPath,
                identity: localIdentity,
                parentPath: parentPath,
                parentIdentity: parentIdentity
            )
        }
    }

    private final class WeakTransportReference: @unchecked Sendable {
        weak var value: VirtioMMIOTransport?

        init(_ value: VirtioMMIOTransport) {
            self.value = value
        }
    }

    private struct ReadyTransport {
        let generation: UInt64
        let transport: VirtioMMIOTransport
    }

    private struct PendingReceiveEpoch: Sendable {
        let generation: UInt64
        let transport: WeakTransportReference
        let completedPurgeTurns: Int
    }

    private struct ReceiveSourceRegistration {
        let source: any DispatchSourceRead
        let cancellation: DispatchSemaphore
    }

    private final class TransmitRetryRegistration: @unchecked Sendable {
        let generation: UInt64
        let source: any DispatchSourceTimer
        let cancellation = DispatchSemaphore(value: 0)

        init(generation: UInt64, source: any DispatchSourceTimer) {
            self.generation = generation
            self.source = source
        }
    }

    private struct TransmitHeadObservation: Sendable {
        let lease: VirtqueueLease
        let head: UInt16
        let firstObservedNanoseconds: UInt64

        func matches(_ chain: VirtqueueChain) -> Bool {
            lease == chain.lease && head == chain.head
        }
    }

    private struct TransmitState: Sendable {
        var generation: UInt64 = 1
        var transport: WeakTransportReference?
        var terminal = false
        var drainScheduled = false
        var kickPending = false
        var retryRegistration: TransmitRetryRegistration?
        var consecutiveTransientFailures = 0
        var headObservation: TransmitHeadObservation?
        var queueDepth = 0
        var queueHighWatermark = 0
        var maximumCompletionLatencyNanoseconds: UInt64 = 0

        mutating func advanceGeneration() {
            generation &+= 1
            if generation == 0 { generation = 1 }
        }

        mutating func observeQueueDepth(_ depth: Int) {
            queueDepth = max(0, depth)
            queueHighWatermark = max(queueHighWatermark, queueDepth)
        }

        mutating func clearLifecycleState() -> TransmitRetryRegistration? {
            let retry = retryRegistration
            retryRegistration = nil
            drainScheduled = false
            kickPending = false
            consecutiveTransientFailures = 0
            headObservation = nil
            queueDepth = 0
            return retry
        }
    }

    private enum TransmitRejection: Error {
        case invalidDescriptor
        case malformed
        case oversized
    }

    private enum TransmitPreparation {
        case empty
        case frame(chain: VirtqueueChain, bytes: [UInt8], depth: Int)
        case rejected(wantsInterrupt: Bool, depth: Int, observedAt: UInt64)
        case queueFault(depth: Int)
        case stale
    }

    private enum TransmitFinalization {
        case published(wantsInterrupt: Bool, depth: Int)
        case queueFault(depth: Int)
        case stale
    }

    private struct DeferredFrame {
        let generation: UInt64
        let bytes: [UInt8]
    }

    private struct ReceiveState {
        var generation: UInt64 = 0
        var transport: WeakTransportReference?
        var deviceIsReady = false
        var receiveQueueIsReady = false
        var terminal = false
        var deferredFrames = [DeferredFrame]()
        var deferredHead = 0
        var deferredBytes = 0

        var deferredCount: Int { deferredFrames.count - deferredHead }

        mutating func advanceGeneration() -> UInt64 {
            generation &+= 1
            // Keep zero as the never-ready sentinel even after the practically unreachable wrap.
            if generation == 0 { generation = 1 }
            return generation
        }

        mutating func clearDeferredFrames() -> Int {
            let removed = deferredCount
            deferredFrames.removeAll(keepingCapacity: true)
            deferredHead = 0
            deferredBytes = 0
            return removed
        }

        mutating func dequeueDeferredFrame(generation expectedGeneration: UInt64) {
            guard deferredHead < deferredFrames.count,
                  deferredFrames[deferredHead].generation == expectedGeneration else { return }
            let removedBytes = deferredFrames[deferredHead].bytes.count
            deferredHead += 1
            deferredBytes -= removedBytes
            if deferredHead == deferredFrames.count {
                deferredFrames.removeAll(keepingCapacity: true)
                deferredHead = 0
            } else if deferredHead >= 64 {
                deferredFrames.removeFirst(deferredHead)
                deferredHead = 0
            }
        }
    }

    private enum DescriptorDisposition {
        case writable
        case wrongDirection
        case insufficientCapacity
    }

    private enum DeliveryResult {
        case delivered(wantsInterrupt: Bool)
        case awaitingBuffer(wantsInterrupt: Bool)
        case stale
        case queueFault(wantsInterrupt: Bool)
    }

    private enum DeferredDrainResult: Equatable {
        case drained
        case waiting
        case queueFault
    }

    private enum DeferredAdmission {
        case accepted
        case atCapacity
        case stale
    }

    private enum ReceivedDatagram {
        case frame([UInt8], ReadyTransport?)
        case empty(ReadyTransport?)
        case unavailable
        case retry
        case failed(Int32)
    }

    private enum InactivePurgeResult {
        case drained
        case budgetExhausted
        case failed(Int32)
    }

    private let socketOwner: SocketOwner
    private let macAddress: [UInt8]
    private let maximumTransmissionUnit: UInt16
    private let maximumEthernetFrameLength: Int
    private let limits: VirtioNetLimits
    private let transmitQueue = DispatchQueue(
        label: "dory-hv.net.tx",
        qos: .userInitiated
    )
    private let transmitQueueKey = DispatchSpecificKey<UInt8>()
    private let transmitState = Mutex(TransmitState())
    private let transmitOperationForTesting: (@Sendable ([UInt8]) -> (count: Int, code: Int32))?
    private let receiveQueue = DispatchQueue(
        label: "dory-hv.net.rx",
        qos: RawHVSchedulingPolicy.networkIOWorkerDispatchQoS
    )
    private let receiveQueueKey = DispatchSpecificKey<UInt8>()
    /// Serializes recv() with the pre-ready purge. It is never held while taking the transport lock.
    private let socketReceiveLock = NSLock()
    private let receiveState = Mutex(ReceiveState())
    /// Publishes the source and its cancellation fence as one lifecycle unit. A stale activation
    /// callback can race a newer queue epoch, so source creation must be terminal-aware and
    /// single-winner independently of transport serialization.
    private let receiveSourceLock = NSLock()
    private var receiveSourceRegistration: ReceiveSourceRegistration?

    private let transmitPackets = Atomic<UInt64>(0)
    private let transmitBytes = Atomic<UInt64>(0)
    private let transmitDrops = Atomic<UInt64>(0)
    private let transmitMalformed = Atomic<UInt64>(0)
    private let transmitOversized = Atomic<UInt64>(0)
    private let transmitInvalidDescriptors = Atomic<UInt64>(0)
    private let transmitBackpressure = Atomic<UInt64>(0)
    private let transmitSocketErrors = Atomic<UInt64>(0)
    private let transmitRetryWakeups = Atomic<UInt64>(0)
    private let transmitBoundedDrainStops = Atomic<UInt64>(0)
    private let transmitCompletions = Atomic<UInt64>(0)
    private let transmitCompletionLatencyNanoseconds = Atomic<UInt64>(0)
    private let receivePackets = Atomic<UInt64>(0)
    private let receiveBytes = Atomic<UInt64>(0)
    private let receiveDeferred = Atomic<UInt64>(0)
    private let receiveDrops = Atomic<UInt64>(0)
    private let receiveTruncations = Atomic<UInt64>(0)
    private let receiveMalformed = Atomic<UInt64>(0)
    private let receiveInvalidDescriptors = Atomic<UInt64>(0)
    private let receiveInsufficientCapacity = Atomic<UInt64>(0)
    private let receiveBacklogDrops = Atomic<UInt64>(0)
    private let receiveInactiveDrops = Atomic<UInt64>(0)
    private let receiveSocketErrors = Atomic<UInt64>(0)
    private let receiveActivationFailures = Atomic<UInt64>(0)

    public convenience init(
        socketPath: String,
        remotePath: String,
        macAddress: [UInt8] = VirtioNet.guestMAC,
        maximumTransmissionUnit: UInt16
    ) throws {
        try self.init(
            socketPath: socketPath,
            remotePath: remotePath,
            macAddress: macAddress,
            maximumTransmissionUnit: maximumTransmissionUnit,
            limits: .production
        )
    }

    init(
        socketPath: String,
        remotePath: String,
        macAddress: [UInt8] = VirtioNet.guestMAC,
        maximumTransmissionUnit: UInt16,
        limits: VirtioNetLimits,
        transmitOperationForTesting: (@Sendable ([UInt8]) -> (count: Int, code: Int32))? = nil
    ) throws {
        guard macAddress.count == 6 else {
            throw VMError.invalidConfiguration("a virtio-net MAC address must contain six bytes")
        }
        guard (Self.minimumSupportedMTU...Self.maximumSupportedMTU)
            .contains(Int(maximumTransmissionUnit)) else {
            throw VMError.invalidConfiguration(
                "virtio-net MTU must be \(Self.minimumSupportedMTU)...\(Self.maximumSupportedMTU) bytes"
            )
        }
        guard limits.maximumDeferredReceiveFrames > 0,
              limits.maximumDeferredReceiveBytes > 0,
              limits.maximumSocketReceiveOperationsPerTurn > 0,
              limits.maximumActivationPurgeTurns > 0,
              limits.maximumTransmitOperationsPerTurn > 0,
              limits.maximumTransmitBytesPerTurn > 0,
              limits.minimumTransmitRetryDelayNanoseconds > 0,
              limits.maximumTransmitRetryDelayNanoseconds
                >= limits.minimumTransmitRetryDelayNanoseconds else {
            throw VMError.invalidConfiguration("virtio-net work and retry limits are invalid")
        }

        let maximumFrameLength = Int(maximumTransmissionUnit) + Self.ethernetHeaderLength
        guard limits.maximumSocketReceiveBytesPerTurn >= maximumFrameLength + 1 else {
            throw VMError.invalidConfiguration(
                "virtio-net socket byte budget must hold one maximum-size datagram"
            )
        }
        guard limits.maximumTransmitBytesPerTurn >= maximumFrameLength else {
            throw VMError.invalidConfiguration(
                "virtio-net transmit byte budget must hold one maximum-size frame"
            )
        }
        let ownedSocket = try Self.makeOwnedConnectedSocket(
            socketPath: socketPath,
            remotePath: remotePath
        )

        self.socketOwner = ownedSocket
        self.macAddress = macAddress
        self.maximumTransmissionUnit = maximumTransmissionUnit
        self.maximumEthernetFrameLength = maximumFrameLength
        self.limits = limits
        self.transmitOperationForTesting = transmitOperationForTesting
        self.deviceFeatures = (1 << 5) | (1 << 3)
        self.transmitQueue.setSpecific(
            key: self.transmitQueueKey,
            value: 1
        )
        self.receiveQueue.setSpecific(
            key: self.receiveQueueKey,
            value: 1
        )
    }

    deinit {
        let retry = transmitState.withLock { state -> TransmitRetryRegistration? in
            state.terminal = true
            state.advanceGeneration()
            state.transport = nil
            return state.clearLifecycleState()
        }
        retry?.source.cancel()
        if DispatchQueue.getSpecific(key: transmitQueueKey) == nil {
            if let retry {
                _ = retry.cancellation.wait(timeout: .now() + 2)
            }
            // Joins an active bounded drain and every cancellation handler already queued by a
            // lifecycle transition before the connected socket can be retired below.
            transmitQueue.sync {}
        }
        receiveState.withLock {
            _ = $0.advanceGeneration()
            $0.transport = nil
            $0.deviceIsReady = false
            $0.receiveQueueIsReady = false
            $0.terminal = true
            _ = $0.clearDeferredFrames()
        }
        if let registration = receiveSourceRegistrationSnapshot() {
            registration.source.cancel()
            // Dispatch guarantees the cancel handler follows all source handlers. Bounded waiting
            // here gives normal VM teardown deterministic pathname retirement without ever closing
            // a descriptor underneath a live handler. If deinit itself runs on the receive queue,
            // the handler completes asynchronously to avoid self-deadlock.
            if DispatchQueue.getSpecific(key: receiveQueueKey) == nil {
                _ = registration.cancellation.wait(timeout: .now() + 2)
            }
        } else {
            socketOwner.retire()
        }
    }

    public var configSpace: [UInt8] {
        // virtio_net_config uses fixed offsets: MAC[0...5], status[6...7], max queue pairs
        // [8...9], and MTU[10...11]. Only MAC and MTU are negotiated here.
        return macAddress + [0, 0, 0, 0]
            + [UInt8(truncatingIfNeeded: maximumTransmissionUnit),
               UInt8(truncatingIfNeeded: maximumTransmissionUnit >> 8)]
    }

    public func deviceReady(transport: VirtioMMIOTransport) {
        bindTransmitTransport(transport)
        // Frames queued before DRIVER_OK belong to no live device generation. Publish no transport
        // until a bounded purge reaches EAGAIN; a burst larger than one work turn continues on the
        // receive queue, while a continuously sending peer leaves activation fail-closed.
        let transition = receiveState.withLock {
            state -> (discarded: Int, accepted: Bool, epoch: PendingReceiveEpoch?) in
            guard !state.terminal else { return (0, false, nil) }
            let discarded = state.clearDeferredFrames()
            state.deviceIsReady = true
            state.receiveQueueIsReady = transport.queues[0].ready
            state.transport = nil
            let generation = state.advanceGeneration()
            let epoch = state.receiveQueueIsReady
                ? PendingReceiveEpoch(
                    generation: generation,
                    transport: WeakTransportReference(transport),
                    completedPurgeTurns: 0
                )
                : nil
            return (discarded, true, epoch)
        }
        accountInactiveDrops(transition.discarded)
        guard transition.accepted else { return }
        if let epoch = transition.epoch {
            continueReceiveEpochActivation(epoch)
        } else {
            startReceiveSourceIfNeeded()
        }
    }

    private func startReceiveSourceIfNeeded() {
        receiveSourceLock.lock()
        guard receiveSourceRegistration == nil,
              receiveState.withLock({ !$0.terminal }) else {
            receiveSourceLock.unlock()
            return
        }
        let source = DispatchSource.makeReadSource(
            fileDescriptor: socketOwner.descriptor,
            queue: receiveQueue
        )
        source.setEventHandler { [weak self] in
            self?.drainSocket()
        }
        let socketOwner = socketOwner
        let cancellation = DispatchSemaphore(value: 0)
        source.setCancelHandler {
            socketOwner.retire()
            cancellation.signal()
        }
        receiveSourceRegistration = ReceiveSourceRegistration(
            source: source,
            cancellation: cancellation
        )
        source.resume()
        receiveSourceLock.unlock()
        receiveQueue.async { [weak self] in
            self?.drainSocket()
        }
    }

    private func receiveSourceRegistrationSnapshot() -> ReceiveSourceRegistration? {
        receiveSourceLock.lock()
        defer { receiveSourceLock.unlock() }
        return receiveSourceRegistration
    }

    public func deviceReset(transport: VirtioMMIOTransport) {
        revokeTransmitLifecycle(replacementTransport: nil)
        let discarded = receiveState.withLock { state -> Int in
            _ = state.advanceGeneration()
            state.transport = nil
            state.deviceIsReady = false
            state.receiveQueueIsReady = false
            return state.clearDeferredFrames()
        }
        accountInactiveDrops(discarded)
    }

    public func queueStateChanged(queue: Int, ready: Bool, transport: VirtioMMIOTransport) {
        if queue == 1 {
            revokeTransmitLifecycle(
                replacementTransport: ready ? WeakTransportReference(transport) : nil
            )
            return
        }
        guard queue == 0 else { return }
        // Every QueueReady write is a queue-epoch boundary. Revoke pending frames and late
        // callbacks from the previous epoch. A newly enabled queue stays fail-closed until a
        // socket-serialized, bounded purge proves no disabled-epoch datagrams remain.
        let transition = receiveState.withLock {
            state -> (discarded: Int, epoch: PendingReceiveEpoch?) in
            guard !state.terminal else { return (0, nil) }
            let generation = state.advanceGeneration()
            state.receiveQueueIsReady = ready
            state.transport = nil
            let epoch = state.deviceIsReady && ready
                ? PendingReceiveEpoch(
                    generation: generation,
                    transport: WeakTransportReference(transport),
                    completedPurgeTurns: 0
                )
                : nil
            return (state.clearDeferredFrames(), epoch)
        }
        accountInactiveDrops(transition.discarded)
        if let epoch = transition.epoch {
            continueReceiveEpochActivation(epoch)
        }
    }

    private func continueReceiveEpochActivation(_ epoch: PendingReceiveEpoch) {
        socketReceiveLock.lock()
        guard isPending(epoch) else {
            socketReceiveLock.unlock()
            return
        }
        switch discardQueuedDatagramsAsInactive() {
        case .drained:
            let activated = receiveState.withLock { state -> Bool in
                guard state.generation == epoch.generation,
                      state.deviceIsReady,
                      state.receiveQueueIsReady,
                      !state.terminal,
                      epoch.transport.value != nil else { return false }
                state.transport = epoch.transport
                return true
            }
            socketReceiveLock.unlock()
            if activated { startReceiveSourceIfNeeded() }
        case .budgetExhausted:
            socketReceiveLock.unlock()
            let completedTurns = epoch.completedPurgeTurns + 1
            guard completedTurns < limits.maximumActivationPurgeTurns else {
                failReceiveActivation()
                return
            }
            let continuation = PendingReceiveEpoch(
                generation: epoch.generation,
                transport: epoch.transport,
                completedPurgeTurns: completedTurns
            )
            receiveQueue.async { [weak self] in
                self?.continueReceiveEpochActivation(continuation)
            }
        case let .failed(code):
            socketReceiveLock.unlock()
            handleSocketReceiveFailure(code)
        }
    }

    private func isPending(_ epoch: PendingReceiveEpoch) -> Bool {
        receiveState.withLock { state in
            state.generation == epoch.generation
                && state.deviceIsReady
                && state.receiveQueueIsReady
                && !state.terminal
                && epoch.transport.value != nil
        }
    }

    public func handleKick(queue: Int, transport: VirtioMMIOTransport) {
        if queue == 0 {
            // Linux notifies the receive queue when it replenishes buffers. Drain on the same
            // serial queue as socket events so deferred and newly received frame order is stable.
            receiveQueue.async { [weak self] in
                self?.drainSocket()
            }
            return
        }
        guard queue == 1 else { return }
        scheduleTransmitDrain(for: transport)
    }

    /// A kick only publishes work to the serial TX executor. VirtioMMIO invokes this backend after
    /// releasing its register lock, so a vCPU never performs descriptor walks, copies, send(), or a
    /// whole-ring drain on the MMIO write path.
    private func scheduleTransmitDrain(for transport: VirtioMMIOTransport) {
        let transition = transmitState.withLock {
            state -> (generation: UInt64?, cancelled: TransmitRetryRegistration?) in
            guard !state.terminal else { return (nil, nil) }

            var cancelled: TransmitRetryRegistration?
            if state.transport?.value !== transport {
                state.advanceGeneration()
                cancelled = state.clearLifecycleState()
                state.transport = WeakTransportReference(transport)
            }
            state.kickPending = true
            guard !state.drainScheduled, state.retryRegistration == nil else {
                return (nil, cancelled)
            }
            state.kickPending = false
            state.drainScheduled = true
            return (state.generation, cancelled)
        }
        transition.cancelled?.source.cancel()
        guard let generation = transition.generation else { return }
        enqueueTransmitDrain(generation: generation, transport: transport)
    }

    private func enqueueTransmitDrain(
        generation: UInt64,
        transport: VirtioMMIOTransport
    ) {
        transmitQueue.async { [weak self, weak transport] in
            guard let self, let transport else { return }
            self.drainTransmitQueue(generation: generation, transport: transport)
        }
    }

    /// Processes a bounded number of packets and bytes, then yields back to the serial executor.
    /// The descriptor publication order is intentionally `peek -> copy -> send -> pop -> push`.
    /// A transient send result therefore leaves both lastAvailIndex and the used ring unchanged.
    private func drainTransmitQueue(
        generation: UInt64,
        transport: VirtioMMIOTransport
    ) {
        guard isCurrentTransmitEpoch(generation, transport: transport) else { return }
        var operations = 0
        var processedBytes = 0
        var observedDepth = 0
        var wantsInterrupt = false
        var stoppedOnQueueFault = false
        defer {
            if wantsInterrupt { transport.notifyUsed() }
        }

        while operations < limits.maximumTransmitOperationsPerTurn {
            let observedAt = Self.monotonicNanoseconds()
            switch prepareTransmitHead(
                generation: generation,
                transport: transport,
                observedAt: observedAt
            ) {
            case .empty:
                observedDepth = 0
                observeTransmitQueueDepth(0, generation: generation, transport: transport)
                finishTransmitTurn(
                    generation: generation,
                    transport: transport,
                    knownPendingWork: false
                )
                return
            case .stale:
                return
            case let .queueFault(depth):
                observedDepth = depth
                observeTransmitQueueDepth(depth, generation: generation, transport: transport)
                stoppedOnQueueFault = true
            case let .rejected(interrupt, depth, firstObserved):
                operations += 1
                observedDepth = depth
                wantsInterrupt = wantsInterrupt || interrupt
                observeTransmitQueueDepth(depth, generation: generation, transport: transport)
                recordTransmitCompletionLatency(from: firstObserved)
                continue
            case let .frame(chain, frame, depth):
                observedDepth = depth
                observeTransmitQueueDepth(depth, generation: generation, transport: transport)
                if operations > 0,
                   processedBytes > limits.maximumTransmitBytesPerTurn - frame.count {
                    transmitBoundedDrainStops.wrappingAdd(1, ordering: .relaxed)
                    finishTransmitTurn(
                        generation: generation,
                        transport: transport,
                        knownPendingWork: true
                    )
                    return
                }

                guard let attempted = attemptTransmit(
                    frame,
                    chain: chain,
                    generation: generation,
                    transport: transport,
                    observedAt: observedAt
                ) else { return }

                if Self.isTransientTransmitError(attempted.result) {
                    if Self.isSocketBackpressure(attempted.result.code) {
                        transmitBackpressure.wrappingAdd(1, ordering: .relaxed)
                    }
                    armTransmitRetry(generation: generation, transport: transport)
                    return
                }

                let transmitted = attempted.result.count == frame.count
                if transmitted {
                    transmitPackets.wrappingAdd(1, ordering: .relaxed)
                    transmitBytes.wrappingAdd(UInt64(frame.count), ordering: .relaxed)
                } else {
                    // Datagram sends are atomic. A short nonnegative result is an invariant/socket
                    // failure and receives the same terminal-per-descriptor treatment as errno.
                    transmitSocketErrors.wrappingAdd(1, ordering: .relaxed)
                }

                switch finalizeTransmitHead(
                    chain,
                    generation: generation,
                    transport: transport
                ) {
                case .stale:
                    return
                case let .queueFault(depth):
                    observedDepth = depth
                    observeTransmitQueueDepth(depth, generation: generation, transport: transport)
                    stoppedOnQueueFault = true
                case let .published(interrupt, depth):
                    operations += 1
                    processedBytes += frame.count
                    observedDepth = depth
                    wantsInterrupt = wantsInterrupt || interrupt
                    observeTransmitQueueDepth(depth, generation: generation, transport: transport)
                    if !transmitted {
                        transmitDrops.wrappingAdd(1, ordering: .relaxed)
                    }
                    completeTransmitHead(
                        chain,
                        generation: generation,
                        transport: transport,
                        firstObserved: attempted.firstObserved
                    )
                }
            }

            if stoppedOnQueueFault { break }
        }

        if stoppedOnQueueFault {
            finishTransmitTurn(
                generation: generation,
                transport: transport,
                knownPendingWork: false
            )
            return
        }
        if observedDepth > 0 {
            transmitBoundedDrainStops.wrappingAdd(1, ordering: .relaxed)
        }
        finishTransmitTurn(
            generation: generation,
            transport: transport,
            knownPendingWork: observedDepth > 0
        )
    }

    private func prepareTransmitHead(
        generation: UInt64,
        transport: VirtioMMIOTransport,
        observedAt: UInt64
    ) -> TransmitPreparation {
        transport.withQueueLock {
            guard isCurrentTransmitEpoch(generation, transport: transport) else { return .stale }
            let virtqueue = transport.queues[1]
            let depth: Int
            do {
                depth = Int(try virtqueue.pendingCount())
            } catch {
                transmitInvalidDescriptors.wrappingAdd(1, ordering: .relaxed)
                transmitDrops.wrappingAdd(1, ordering: .relaxed)
                return .queueFault(depth: 0)
            }
            guard depth > 0 else { return .empty }

            let chain: VirtqueueChain
            do {
                guard let candidate = try virtqueue.peek() else { return .empty }
                chain = candidate
            } catch {
                // peek() is non-consuming. pop() advances lastAvailIndex before walking the same
                // malformed descriptor, preventing a hostile head from spinning every work turn.
                _ = try? virtqueue.pop()
                transmitInvalidDescriptors.wrappingAdd(1, ordering: .relaxed)
                transmitDrops.wrappingAdd(1, ordering: .relaxed)
                let remaining = (try? virtqueue.pendingCount()).map(Int.init) ?? max(0, depth - 1)
                return .queueFault(depth: remaining)
            }

            let maximumChainBytes = Self.headerLength + maximumEthernetFrameLength
            let verdict = chain.withLeaseHeld { access -> Result<[UInt8], TransmitRejection> in
                guard access.readableSegmentCount > 0,
                      access.writableSegmentCount == 0 else {
                    return .failure(.invalidDescriptor)
                }
                let readableCount = access.readableByteCount
                guard readableCount <= maximumChainBytes else {
                    return .failure(.oversized)
                }
                guard readableCount >= Self.headerLength + Self.ethernetHeaderLength else {
                    return .failure(.malformed)
                }
                let packet = access.readBytes(maximum: maximumChainBytes)
                guard packet.count == readableCount,
                      Self.isSupportedTransmitHeader(packet) else {
                    return .failure(.malformed)
                }
                let frame = Array(packet.dropFirst(Self.headerLength))
                guard frame.count >= Self.ethernetHeaderLength else {
                    return .failure(.malformed)
                }
                guard frame.count <= maximumEthernetFrameLength else {
                    return .failure(.oversized)
                }
                return .success(frame)
            }
            guard let verdict else {
                transmitInvalidDescriptors.wrappingAdd(1, ordering: .relaxed)
                transmitDrops.wrappingAdd(1, ordering: .relaxed)
                return .queueFault(depth: depth)
            }

            switch verdict {
            case let .success(frame):
                return .frame(chain: chain, bytes: frame, depth: depth)
            case let .failure(reason):
                accountTransmitRejection(reason)
                do {
                    guard let popped = try virtqueue.pop(), Self.sameChain(popped, chain) else {
                        transmitInvalidDescriptors.wrappingAdd(1, ordering: .relaxed)
                        return .queueFault(depth: depth)
                    }
                    switch try virtqueue.pushOutcome(popped, written: 0) {
                    case .revoked:
                        return .stale
                    case let .published(wantsInterrupt):
                        let remaining = Int(try virtqueue.pendingCount())
                        transmitCompletions.wrappingAdd(1, ordering: .relaxed)
                        return .rejected(
                            wantsInterrupt: wantsInterrupt,
                            depth: remaining,
                            observedAt: observedAt
                        )
                    }
                } catch {
                    transmitInvalidDescriptors.wrappingAdd(1, ordering: .relaxed)
                    return .queueFault(depth: max(0, depth - 1))
                }
            }
        }
    }

    private func attemptTransmit(
        _ frame: [UInt8],
        chain: VirtqueueChain,
        generation: UInt64,
        transport: VirtioMMIOTransport,
        observedAt: UInt64
    ) -> (result: (count: Int, code: Int32), firstObserved: UInt64)? {
        transmitState.withLock { state in
            guard state.generation == generation,
                  state.transport?.value === transport,
                  !state.terminal,
                  state.drainScheduled else { return nil }
            let firstObserved: UInt64
            if let observation = state.headObservation, observation.matches(chain) {
                firstObserved = observation.firstObservedNanoseconds
            } else {
                firstObserved = observedAt
                state.headObservation = TransmitHeadObservation(
                    lease: chain.lease,
                    head: chain.head,
                    firstObservedNanoseconds: observedAt
                )
            }

            // The state lock is deliberately held through the nonblocking syscall. Reset and queue
            // reconfiguration take registerLock -> transmitState, so they wait for this bounded
            // attempt and can then revoke the epoch without a send beginning after the callback.
            let result: (count: Int, code: Int32)
            if let transmitOperationForTesting {
                result = transmitOperationForTesting(frame)
            } else {
                result = socketOwner.withDescriptor { descriptor in
                    frame.withUnsafeBytes { buffer in
                        let count = send(descriptor, buffer.baseAddress, buffer.count, MSG_DONTWAIT)
                        return (count, count < 0 ? errno : 0)
                    }
                } ?? (-1, EBADF)
            }
            return (result, firstObserved)
        }
    }

    private func finalizeTransmitHead(
        _ expected: VirtqueueChain,
        generation: UInt64,
        transport: VirtioMMIOTransport
    ) -> TransmitFinalization {
        transport.withQueueLock {
            guard isCurrentTransmitEpoch(generation, transport: transport) else { return .stale }
            let virtqueue = transport.queues[1]
            do {
                guard let popped = try virtqueue.pop(), Self.sameChain(popped, expected) else {
                    transmitInvalidDescriptors.wrappingAdd(1, ordering: .relaxed)
                    let depth = (try? virtqueue.pendingCount()).map(Int.init) ?? 0
                    return .queueFault(depth: depth)
                }
                switch try virtqueue.pushOutcome(popped, written: 0) {
                case .revoked:
                    return .stale
                case let .published(wantsInterrupt):
                    let depth = Int(try virtqueue.pendingCount())
                    transmitCompletions.wrappingAdd(1, ordering: .relaxed)
                    return .published(wantsInterrupt: wantsInterrupt, depth: depth)
                }
            } catch {
                transmitInvalidDescriptors.wrappingAdd(1, ordering: .relaxed)
                let depth = (try? virtqueue.pendingCount()).map(Int.init) ?? 0
                return .queueFault(depth: depth)
            }
        }
    }

    private func accountTransmitRejection(_ rejection: TransmitRejection) {
        switch rejection {
        case .invalidDescriptor:
            transmitInvalidDescriptors.wrappingAdd(1, ordering: .relaxed)
        case .malformed:
            transmitMalformed.wrappingAdd(1, ordering: .relaxed)
        case .oversized:
            transmitOversized.wrappingAdd(1, ordering: .relaxed)
        }
        transmitDrops.wrappingAdd(1, ordering: .relaxed)
    }

    private static func sameChain(_ lhs: VirtqueueChain, _ rhs: VirtqueueChain) -> Bool {
        lhs.head == rhs.head && lhs.lease == rhs.lease
    }

    private static func isSocketBackpressure(_ code: Int32) -> Bool {
        code == EAGAIN || code == EWOULDBLOCK || code == ENOBUFS
    }

    private static func isTransientTransmitError(
        _ result: (count: Int, code: Int32)
    ) -> Bool {
        result.count < 0 && (isSocketBackpressure(result.code) || result.code == EINTR)
    }

    private func bindTransmitTransport(_ transport: VirtioMMIOTransport) {
        let retry = transmitState.withLock { state -> TransmitRetryRegistration? in
            guard !state.terminal, state.transport?.value !== transport else { return nil }
            state.advanceGeneration()
            let retry = state.clearLifecycleState()
            state.transport = WeakTransportReference(transport)
            return retry
        }
        retry?.source.cancel()
    }

    private func revokeTransmitLifecycle(replacementTransport: WeakTransportReference?) {
        let retry = transmitState.withLock { state -> TransmitRetryRegistration? in
            guard !state.terminal else { return nil }
            state.advanceGeneration()
            let retry = state.clearLifecycleState()
            state.transport = replacementTransport
            return retry
        }
        retry?.source.cancel()
    }

    private func terminateTransmitLifecycle() {
        let retry = transmitState.withLock { state -> TransmitRetryRegistration? in
            guard !state.terminal else { return nil }
            state.terminal = true
            state.advanceGeneration()
            state.transport = nil
            return state.clearLifecycleState()
        }
        retry?.source.cancel()
    }

    private func isCurrentTransmitEpoch(
        _ generation: UInt64,
        transport: VirtioMMIOTransport
    ) -> Bool {
        transmitState.withLock {
            $0.generation == generation
                && $0.transport?.value === transport
                && !$0.terminal
                && $0.drainScheduled
        }
    }

    private func observeTransmitQueueDepth(
        _ depth: Int,
        generation: UInt64,
        transport: VirtioMMIOTransport
    ) {
        transmitState.withLock { state in
            guard state.generation == generation,
                  state.transport?.value === transport else { return }
            state.observeQueueDepth(depth)
        }
    }

    private func completeTransmitHead(
        _ chain: VirtqueueChain,
        generation: UInt64,
        transport: VirtioMMIOTransport,
        firstObserved: UInt64
    ) {
        transmitState.withLock { state in
            guard state.generation == generation,
                  state.transport?.value === transport else { return }
            if state.headObservation?.matches(chain) == true {
                state.headObservation = nil
            }
            state.consecutiveTransientFailures = 0
        }
        recordTransmitCompletionLatency(from: firstObserved)
    }

    private func recordTransmitCompletionLatency(from firstObserved: UInt64) {
        let elapsed = Self.monotonicNanoseconds() &- firstObserved
        transmitCompletionLatencyNanoseconds.wrappingAdd(elapsed, ordering: .relaxed)
        transmitState.withLock { state in
            state.maximumCompletionLatencyNanoseconds = max(
                state.maximumCompletionLatencyNanoseconds,
                elapsed
            )
        }
    }

    private func armTransmitRetry(
        generation: UInt64,
        transport: VirtioMMIOTransport
    ) {
        let failureCount = transmitState.withLock { state -> Int? in
            guard state.generation == generation,
                  state.transport?.value === transport,
                  !state.terminal,
                  state.drainScheduled,
                  state.retryRegistration == nil else { return nil }
            state.consecutiveTransientFailures += 1
            return state.consecutiveTransientFailures
        }
        guard let failureCount else { return }

        let delay = transmitRetryDelayNanoseconds(failureCount: failureCount)
        let source = DispatchSource.makeTimerSource(queue: transmitQueue)
        let registration = TransmitRetryRegistration(generation: generation, source: source)
        source.setEventHandler { [weak self, weak transport] in
            guard let self, let transport else { return }
            self.wakeTransmitRetry(generation: generation, transport: transport)
        }
        let cancellation = registration.cancellation
        source.setCancelHandler {
            cancellation.signal()
        }
        source.schedule(
            deadline: .now() + .nanoseconds(delay),
            leeway: .nanoseconds(max(1, min(delay / 4, 1_000_000)))
        )

        let installed = transmitState.withLock { state -> Bool in
            guard state.generation == generation,
                  state.transport?.value === transport,
                  !state.terminal,
                  state.drainScheduled,
                  state.retryRegistration == nil else { return false }
            state.retryRegistration = registration
            state.drainScheduled = false
            return true
        }
        source.activate()
        if !installed { source.cancel() }
    }

    private func transmitRetryDelayNanoseconds(failureCount: Int) -> Int {
        var delay = limits.minimumTransmitRetryDelayNanoseconds
        for _ in 1..<min(failureCount, 32) {
            if delay >= limits.maximumTransmitRetryDelayNanoseconds { break }
            let (doubled, overflow) = delay.multipliedReportingOverflow(by: 2)
            delay = overflow
                ? limits.maximumTransmitRetryDelayNanoseconds
                : min(limits.maximumTransmitRetryDelayNanoseconds, doubled)
        }
        return delay
    }

    private func wakeTransmitRetry(
        generation: UInt64,
        transport: VirtioMMIOTransport
    ) {
        let registration = transmitState.withLock { state -> TransmitRetryRegistration? in
            guard state.generation == generation,
                  state.transport?.value === transport,
                  !state.terminal,
                  !state.drainScheduled,
                  let registration = state.retryRegistration,
                  registration.generation == generation else { return nil }
            state.retryRegistration = nil
            state.kickPending = false
            state.drainScheduled = true
            return registration
        }
        guard let registration else { return }
        registration.source.cancel()
        transmitRetryWakeups.wrappingAdd(1, ordering: .relaxed)
        enqueueTransmitDrain(generation: generation, transport: transport)
    }

    private func finishTransmitTurn(
        generation: UInt64,
        transport: VirtioMMIOTransport,
        knownPendingWork: Bool
    ) {
        let continueDraining = transmitState.withLock { state -> Bool in
            guard state.generation == generation,
                  state.transport?.value === transport,
                  !state.terminal,
                  state.drainScheduled else { return false }
            if knownPendingWork || state.kickPending {
                state.kickPending = false
                return true
            }
            state.drainScheduled = false
            return false
        }
        if continueDraining {
            enqueueTransmitDrain(generation: generation, transport: transport)
        }
    }

    private static func monotonicNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    private static func isSupportedTransmitHeader(_ packet: [UInt8]) -> Bool {
        guard packet.count >= headerLength else { return false }
        let flags = packet[0]
        let gsoType = packet[1]
        // Unknown flag bits are ignored as required for extensibility. Known checksum/data-valid/
        // RSC semantics and every GSO type require features Dory does not offer. hdr_len, gso_size,
        // csum_start, and csum_offset are deliberately not trusted or interpreted. num_buffers is
        // an RX result field and is explicitly unused on transmitted packets, so a device must not
        // turn its contents into a TX admission condition. In particular, Linux uses the 12-byte
        // VERSION_1 header without initializing those two bytes unless MRG_RXBUF was negotiated.
        return flags & knownHeaderFlagsMask == 0
            && gsoType == 0  // VIRTIO_NET_HDR_GSO_NONE
    }

    private func drainSocket() {
        let deferredResult = drainDeferredFrames()
        guard deferredResult != .queueFault else { return }
        var backlogIsWaiting = deferredResult == .waiting
        var receiveBuffer = [UInt8](repeating: 0, count: maximumEthernetFrameLength + 1)
        var receiveOperations = 0
        var receivedBytes = 0
        let maximumBytesBeforeAnotherReceive =
            limits.maximumSocketReceiveBytesPerTurn - receiveBuffer.count

        while receiveOperations < limits.maximumSocketReceiveOperationsPerTurn,
              receivedBytes <= maximumBytesBeforeAnotherReceive {
            receiveOperations += 1
            switch receiveOneDatagram(into: &receiveBuffer) {
            case .unavailable:
                return
            case .retry:
                continue
            case let .failed(code):
                handleSocketReceiveFailure(code)
                return
            case let .empty(ready):
                accountReceivedDatagram(byteCount: 0)
                receiveMalformed.wrappingAdd(1, ordering: .relaxed)
                receiveDrops.wrappingAdd(1, ordering: .relaxed)
                if ready == nil {
                    receiveInactiveDrops.wrappingAdd(1, ordering: .relaxed)
                }
            case let .frame(frame, ready):
                receivedBytes += frame.count
                accountReceivedDatagram(byteCount: frame.count)
                guard frame.count <= maximumEthernetFrameLength else {
                    receiveTruncations.wrappingAdd(1, ordering: .relaxed)
                    receiveDrops.wrappingAdd(1, ordering: .relaxed)
                    continue
                }
                guard frame.count >= Self.ethernetHeaderLength else {
                    receiveMalformed.wrappingAdd(1, ordering: .relaxed)
                    receiveDrops.wrappingAdd(1, ordering: .relaxed)
                    continue
                }
                guard let ready else {
                    receiveInactiveDrops.wrappingAdd(1, ordering: .relaxed)
                    receiveDrops.wrappingAdd(1, ordering: .relaxed)
                    continue
                }

                // Once an older frame is waiting, every later frame joins the bounded backlog and
                // cannot overtake it. Invalid guest buffers are consumed with used length zero.
                if backlogIsWaiting || hasDeferredFrame(generation: ready.generation) {
                    backlogIsWaiting = true
                    deferOrDrop(frame, generation: ready.generation)
                    continue
                }
                switch deliver(frame, ready: ready) {
                case let .delivered(wantsInterrupt):
                    notifyUsedIfCurrent(wantsInterrupt, ready: ready)
                case let .awaitingBuffer(wantsInterrupt):
                    notifyUsedIfCurrent(wantsInterrupt, ready: ready)
                    deferOrDrop(frame, generation: ready.generation)
                    backlogIsWaiting = true
                case .stale:
                    receiveInactiveDrops.wrappingAdd(1, ordering: .relaxed)
                    receiveDrops.wrappingAdd(1, ordering: .relaxed)
                case let .queueFault(wantsInterrupt):
                    notifyUsedIfCurrent(wantsInterrupt, ready: ready)
                    return
                }
            }
        }
        scheduleReceiveDrainContinuation()
    }

    private func scheduleReceiveDrainContinuation() {
        guard receiveState.withLock({ !$0.terminal }) else { return }
        receiveQueue.async { [weak self] in
            self?.drainSocket()
        }
    }

    /// Drains the bounded host backlog before reading another socket frame, preserving arrival
    /// order across yielded socket work turns.
    private func drainDeferredFrames() -> DeferredDrainResult {
        while let pending = receiveState.withLock({ state -> (DeferredFrame, ReadyTransport)? in
            guard state.deferredHead < state.deferredFrames.count,
                  let transport = state.transport?.value else { return nil }
            let frame = state.deferredFrames[state.deferredHead]
            guard frame.generation == state.generation else { return nil }
            return (frame, ReadyTransport(generation: state.generation, transport: transport))
        }) {
            let frame = pending.0
            let ready = pending.1
            switch deliver(frame.bytes, ready: ready) {
            case let .delivered(wantsInterrupt):
                receiveState.withLock {
                    $0.dequeueDeferredFrame(generation: ready.generation)
                }
                notifyUsedIfCurrent(wantsInterrupt, ready: ready)
            case let .awaitingBuffer(wantsInterrupt):
                notifyUsedIfCurrent(wantsInterrupt, ready: ready)
                return .waiting
            case .stale:
                return .drained
            case let .queueFault(wantsInterrupt):
                receiveState.withLock {
                    $0.dequeueDeferredFrame(generation: ready.generation)
                }
                // A malformed later descriptor must not hide valid zero-length completions that
                // were already published while searching for a usable RX buffer.
                notifyUsedIfCurrent(wantsInterrupt, ready: ready)
                return .queueFault
            }
        }
        return .drained
    }

    private func deliver(_ frame: [UInt8], ready: ReadyTransport) -> DeliveryResult {
        ready.transport.withQueueLock {
            guard isCurrent(ready) else { return .stale }
            let virtqueue = ready.transport.queues[0]
            var wantsInterrupt = false

            while isCurrent(ready) {
                let chain: VirtqueueChain
                do {
                    guard let next = try virtqueue.pop() else {
                        return .awaitingBuffer(wantsInterrupt: wantsInterrupt)
                    }
                    chain = next
                } catch {
                    // pop() has consumed this malformed available-ring entry before descriptor
                    // resolution. Do not spin over subsequent entries in the same drain turn.
                    receiveInvalidDescriptors.wrappingAdd(1, ordering: .relaxed)
                    receiveDrops.wrappingAdd(1, ordering: .relaxed)
                    return .queueFault(wantsInterrupt: wantsInterrupt)
                }
                let requiredCapacity = Self.headerLength + frame.count
                let disposition = chain.withLeaseHeld { access -> DescriptorDisposition in
                    guard access.writableSegmentCount > 0,
                          access.readableSegmentCount == 0 else { return .wrongDirection }
                    guard access.writableByteCount >= requiredCapacity else {
                        return .insufficientCapacity
                    }
                    return .writable
                } ?? .wrongDirection

                switch disposition {
                case .wrongDirection:
                    receiveInvalidDescriptors.wrappingAdd(1, ordering: .relaxed)
                    guard let wants = pushReceiveCompletion(
                        chain,
                        written: 0,
                        to: virtqueue
                    ) else { return .queueFault(wantsInterrupt: wantsInterrupt) }
                    wantsInterrupt = wantsInterrupt || wants
                case .insufficientCapacity:
                    receiveInsufficientCapacity.wrappingAdd(1, ordering: .relaxed)
                    guard let wants = pushReceiveCompletion(
                        chain,
                        written: 0,
                        to: virtqueue
                    ) else { return .queueFault(wantsInterrupt: wantsInterrupt) }
                    wantsInterrupt = wantsInterrupt || wants
                case .writable:
                    var packet = [UInt8](repeating: 0, count: Self.headerLength)
                    packet[10] = 1  // num_buffers = 1; MRG_RXBUF is not offered.
                    packet.append(contentsOf: frame)
                    let written = chain.withLeaseHeld { $0.writeBytes(packet) } ?? 0
                    // Capacity and every segment were validated under the same queue lifecycle
                    // lease. A short result can only mean reset revoked publication; used length
                    // zero prevents the guest from observing a partial packet as delivered.
                    guard written == packet.count else {
                        guard let wants = pushReceiveCompletion(
                            chain,
                            written: 0,
                            to: virtqueue
                        ) else { return .queueFault(wantsInterrupt: wantsInterrupt) }
                        return isCurrent(ready)
                            ? .awaitingBuffer(wantsInterrupt: wantsInterrupt || wants)
                            : .stale
                    }
                    guard let wants = pushReceiveCompletion(
                        chain,
                        written: written,
                        to: virtqueue
                    ) else { return .queueFault(wantsInterrupt: wantsInterrupt) }
                    return .delivered(wantsInterrupt: wantsInterrupt || wants)
                }
            }
            return .stale
        }
    }

    private func pushReceiveCompletion(
        _ chain: VirtqueueChain,
        written: Int,
        to virtqueue: Virtqueue
    ) -> Bool? {
        do {
            return try virtqueue.push(chain, written: written)
        } catch {
            receiveInvalidDescriptors.wrappingAdd(1, ordering: .relaxed)
            receiveDrops.wrappingAdd(1, ordering: .relaxed)
            return nil
        }
    }

    private func notifyUsedIfCurrent(_ wantsInterrupt: Bool, ready: ReadyTransport) {
        guard wantsInterrupt else { return }
        ready.transport.withQueueLock {
            guard isCurrent(ready) else { return }
            ready.transport.notifyUsed()
        }
    }

    private func isCurrent(_ ready: ReadyTransport) -> Bool {
        receiveState.withLock { state in
            state.generation == ready.generation
                && state.transport?.value === ready.transport
        }
    }

    private func hasDeferredFrame(generation: UInt64) -> Bool {
        receiveState.withLock { state in
            state.generation == generation && state.deferredCount > 0
        }
    }

    private func deferOrDrop(_ frame: [UInt8], generation: UInt64) {
        let admission = receiveState.withLock { state -> DeferredAdmission in
            guard state.generation == generation,
                  state.transport?.value != nil else { return .stale }
            guard state.deferredCount < limits.maximumDeferredReceiveFrames else {
                return .atCapacity
            }
            let (newByteCount, overflow) = state.deferredBytes.addingReportingOverflow(frame.count)
            guard !overflow, newByteCount <= limits.maximumDeferredReceiveBytes else {
                return .atCapacity
            }
            state.deferredFrames.append(DeferredFrame(generation: generation, bytes: frame))
            state.deferredBytes = newByteCount
            return .accepted
        }
        switch admission {
        case .accepted:
            receiveDeferred.wrappingAdd(1, ordering: .relaxed)
        case .atCapacity:
            receiveBacklogDrops.wrappingAdd(1, ordering: .relaxed)
            receiveDrops.wrappingAdd(1, ordering: .relaxed)
        case .stale:
            receiveInactiveDrops.wrappingAdd(1, ordering: .relaxed)
            receiveDrops.wrappingAdd(1, ordering: .relaxed)
        }
    }

    private func receiveOneDatagram(into buffer: inout [UInt8]) -> ReceivedDatagram {
        socketReceiveLock.lock()
        let ready = receiveState.withLock { state -> ReadyTransport? in
            guard let transport = state.transport?.value else { return nil }
            return ReadyTransport(generation: state.generation, transport: transport)
        }
        let receiveResult: (count: Int, code: Int32)? = socketOwner.withDescriptor { descriptor in
            buffer.withUnsafeMutableBytes {
                let count = recv(descriptor, $0.baseAddress, $0.count, MSG_DONTWAIT)
                return (count, count < 0 ? errno : 0)
            }
        }
        socketReceiveLock.unlock()

        guard let receiveResult else { return .unavailable }
        let received = receiveResult.count
        let code = receiveResult.code

        if received > 0 {
            return .frame(Array(buffer[0..<received]), ready)
        }
        if received == 0 { return .empty(ready) }
        if code == EINTR { return .retry }
        if code == EAGAIN || code == EWOULDBLOCK { return .unavailable }
        return .failed(code)
    }

    /// Called with socketReceiveLock held before a generation becomes ready. One invocation has
    /// exact operation and byte ceilings; callers yield and resume when the socket still has work.
    private func discardQueuedDatagramsAsInactive() -> InactivePurgeResult {
        var buffer = [UInt8](repeating: 0, count: maximumEthernetFrameLength + 1)
        var receiveOperations = 0
        var receivedBytes = 0
        let maximumBytesBeforeAnotherReceive =
            limits.maximumSocketReceiveBytesPerTurn - buffer.count
        while receiveOperations < limits.maximumSocketReceiveOperationsPerTurn,
              receivedBytes <= maximumBytesBeforeAnotherReceive {
            receiveOperations += 1
            guard let result: (count: Int, code: Int32) = socketOwner.withDescriptor({ descriptor in
                buffer.withUnsafeMutableBytes {
                    let count = recv(descriptor, $0.baseAddress, $0.count, MSG_DONTWAIT)
                    return (count, count < 0 ? errno : 0)
                }
            }) else { return .failed(EBADF) }
            let received = result.count
            if received >= 0 {
                receivedBytes += received
                accountReceivedDatagram(byteCount: received)
                if received > maximumEthernetFrameLength {
                    receiveTruncations.wrappingAdd(1, ordering: .relaxed)
                } else if received < Self.ethernetHeaderLength {
                    receiveMalformed.wrappingAdd(1, ordering: .relaxed)
                }
                receiveInactiveDrops.wrappingAdd(1, ordering: .relaxed)
                receiveDrops.wrappingAdd(1, ordering: .relaxed)
                continue
            }
            if result.code == EINTR { continue }
            if result.code == EAGAIN || result.code == EWOULDBLOCK { return .drained }
            return .failed(result.code)
        }
        return .budgetExhausted
    }

    /// A non-transient recv failure is terminal for this connected Unix socket. Keeping a read
    /// source active after EBADF/EIO would spin indefinitely, so one path accounts the failure,
    /// revokes the device generation, and hands descriptor retirement to the source cancel handler.
    /// Internal visibility is an intentional deterministic test seam for an otherwise hard-to-
    /// induce Darwin source error.
    func handleSocketReceiveFailure(_ code: Int32) {
        guard code != EINTR, code != EAGAIN, code != EWOULDBLOCK else { return }
        if quiesceReceiveSocket() {
            receiveSocketErrors.wrappingAdd(1, ordering: .relaxed)
        }
    }

    private func failReceiveActivation() {
        if quiesceReceiveSocket() {
            receiveActivationFailures.wrappingAdd(1, ordering: .relaxed)
        }
    }

    @discardableResult
    private func quiesceReceiveSocket() -> Bool {
        socketOwner.disableOperations()
        // One connected datagram socket serves both directions. A terminal receive failure revokes
        // TX admission too, rather than letting a retry timer consume descriptors against EBADF.
        terminateTransmitLifecycle()
        let transition = receiveState.withLock { state -> (discarded: Int, isNew: Bool) in
            guard !state.terminal else { return (0, false) }
            state.terminal = true
            _ = state.advanceGeneration()
            state.transport = nil
            state.deviceIsReady = false
            state.receiveQueueIsReady = false
            return (state.clearDeferredFrames(), true)
        }
        guard transition.isNew else { return false }
        accountInactiveDrops(transition.discarded)
        if let registration = receiveSourceRegistrationSnapshot() {
            registration.source.cancel()
        } else {
            socketOwner.retire()
        }
        return true
    }

    private func accountReceivedDatagram(byteCount: Int) {
        receivePackets.wrappingAdd(1, ordering: .relaxed)
        receiveBytes.wrappingAdd(UInt64(byteCount), ordering: .relaxed)
    }

    private func accountInactiveDrops(_ count: Int) {
        guard count > 0 else { return }
        let amount = UInt64(count)
        receiveInactiveDrops.wrappingAdd(amount, ordering: .relaxed)
        receiveDrops.wrappingAdd(amount, ordering: .relaxed)
    }

    public var statistics: VirtioNetStatistics {
        let now = Self.monotonicNanoseconds()
        let transmitGauges = transmitState.withLock { state in
            (
                maximumLatency: state.maximumCompletionLatencyNanoseconds,
                oldestPendingLatency: state.headObservation.map {
                    now &- $0.firstObservedNanoseconds
                } ?? 0,
                queueDepth: UInt64(state.queueDepth),
                queueHighWatermark: UInt64(state.queueHighWatermark)
            )
        }
        return VirtioNetStatistics(
            transmitPackets: transmitPackets.load(ordering: .relaxed),
            transmitBytes: transmitBytes.load(ordering: .relaxed),
            transmitDrops: transmitDrops.load(ordering: .relaxed),
            transmitMalformed: transmitMalformed.load(ordering: .relaxed),
            transmitOversized: transmitOversized.load(ordering: .relaxed),
            transmitInvalidDescriptors: transmitInvalidDescriptors.load(ordering: .relaxed),
            transmitBackpressure: transmitBackpressure.load(ordering: .relaxed),
            transmitSocketErrors: transmitSocketErrors.load(ordering: .relaxed),
            transmitRetryWakeups: transmitRetryWakeups.load(ordering: .relaxed),
            transmitBoundedDrainStops: transmitBoundedDrainStops.load(ordering: .relaxed),
            transmitCompletions: transmitCompletions.load(ordering: .relaxed),
            transmitCompletionLatencyNanoseconds: transmitCompletionLatencyNanoseconds.load(
                ordering: .relaxed
            ),
            transmitMaximumCompletionLatencyNanoseconds: transmitGauges.maximumLatency,
            transmitOldestPendingLatencyNanoseconds: transmitGauges.oldestPendingLatency,
            transmitQueueDepth: transmitGauges.queueDepth,
            transmitQueueHighWatermark: transmitGauges.queueHighWatermark,
            receivePackets: receivePackets.load(ordering: .relaxed),
            receiveBytes: receiveBytes.load(ordering: .relaxed),
            receiveDeferred: receiveDeferred.load(ordering: .relaxed),
            receiveDrops: receiveDrops.load(ordering: .relaxed),
            receiveTruncations: receiveTruncations.load(ordering: .relaxed),
            receiveMalformed: receiveMalformed.load(ordering: .relaxed),
            receiveInvalidDescriptors: receiveInvalidDescriptors.load(ordering: .relaxed),
            receiveInsufficientCapacity: receiveInsufficientCapacity.load(ordering: .relaxed),
            receiveBacklogDrops: receiveBacklogDrops.load(ordering: .relaxed),
            receiveInactiveDrops: receiveInactiveDrops.load(ordering: .relaxed),
            receiveSocketErrors: receiveSocketErrors.load(ordering: .relaxed),
            receiveActivationFailures: receiveActivationFailures.load(ordering: .relaxed)
        )
    }

    private static func makeOwnedConnectedSocket(
        socketPath: String,
        remotePath: String
    ) throws -> SocketOwner {
        try validateSocketPath(socketPath)
        try validateSocketPath(remotePath)
        let localParentPath = (socketPath as NSString).deletingLastPathComponent
        let remoteParentPath = (remotePath as NSString).deletingLastPathComponent
        let localParentIdentity = try validateTrustedParentDirectory(of: socketPath)
        let remoteParentIdentity = try validateTrustedParentDirectory(of: remotePath)
        guard let remoteIdentity = socketIdentity(at: remotePath) else {
            throw VMError.invalidConfiguration(
                "virtio-net remote endpoint is not a same-user Unix socket: \(remotePath)"
            )
        }

        socketPathMutationLock.lock()
        defer { socketPathMutationLock.unlock() }
        try retireStaleLocalEndpointIfPresent(
            socketPath,
            parentPath: localParentPath,
            parentIdentity: localParentIdentity
        )

        let descriptor = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard descriptor >= 0 else {
            throw systemCallError("create Unix datagram socket", path: socketPath, code: errno)
        }
        var boundIdentity: SocketPathIdentity?
        do {
            try configureSocket(descriptor)
            var localAddress = try unixAddress(socketPath)
            let bindResult = withUnsafePointer(to: &localAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bindResult == 0 else {
                throw systemCallError("bind Unix datagram socket", path: socketPath, code: errno)
            }
            guard chmod(socketPath, 0o600) == 0 else {
                throw systemCallError("chmod Unix datagram socket", path: socketPath, code: errno)
            }
            guard socketPermissions(at: socketPath) == 0o600 else {
                throw systemCallError(
                    "verify private Unix datagram permissions",
                    path: socketPath,
                    code: EPERM
                )
            }
            guard let identity = socketIdentity(at: socketPath) else {
                throw systemCallError("capture Unix datagram identity", path: socketPath, code: ESTALE)
            }
            boundIdentity = identity
            guard directoryIdentity(at: localParentPath) == localParentIdentity else {
                throw systemCallError("revalidate Unix datagram parent", path: localParentPath, code: ESTALE)
            }

            var remoteAddress = try unixAddress(remotePath)
            let connectResult = withUnsafePointer(to: &remoteAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connectResult == 0 else {
                throw systemCallError("connect Unix datagram socket", path: remotePath, code: errno)
            }
            guard socketIdentity(at: remotePath) == remoteIdentity else {
                throw systemCallError("revalidate Unix datagram peer", path: remotePath, code: ESTALE)
            }
            guard directoryIdentity(at: remoteParentPath) == remoteParentIdentity else {
                throw systemCallError("revalidate Unix datagram peer parent", path: remoteParentPath, code: ESTALE)
            }
            var peerUID: uid_t = 0
            var peerGID: gid_t = 0
            let peerCredentialResult = getpeereid(descriptor, &peerUID, &peerGID)
            let usedPathnamePeerAuthentication: Bool
            if peerCredentialResult == 0 {
                guard peerUID == geteuid() else {
                    throw VMError.invalidConfiguration(
                        "virtio-net remote endpoint belongs to uid \(peerUID), expected \(geteuid())"
                    )
                }
                usedPathnamePeerAuthentication = false
            } else {
                let peerCredentialError = errno
                // Apple Libc's getpeereid(3) is defined only for SOCK_STREAM. XNU's
                // uipc_ctloutput returns EINVAL for LOCAL_PEERCRED on a pathname SOCK_DGRAM that
                // has no reciprocal peer association. Only that documented capability absence (or
                // ENOTSUP on another Darwin release) may fall back to the already captured and
                // post-connect revalidated same-euid socket and trusted-parent identities.
                guard peerCredentialError == EINVAL || peerCredentialError == ENOTSUP else {
                    throw systemCallError(
                        "authenticate Unix datagram peer",
                        path: remotePath,
                        code: peerCredentialError
                    )
                }
                usedPathnamePeerAuthentication = true
            }

            try setSocketBuffer(descriptor, option: SO_SNDBUF, bytes: 1 << 20)
            try setSocketBuffer(descriptor, option: SO_RCVBUF, bytes: 4 << 20)

            // gvproxy <= 0.8.6 requires this handshake; newer releases retain compatibility.
            let magicResult: (count: Int, code: Int32) = vfkitMagic.withUnsafeBytes {
                let count = send(descriptor, $0.baseAddress, $0.count, MSG_DONTWAIT)
                return (count, count < 0 ? errno : 0)
            }
            guard magicResult.count == vfkitMagic.count else {
                // Unix datagram sends are atomic, so a nonnegative short result is an invariant
                // failure rather than an errno-bearing partial registration.
                let code = magicResult.count < 0 ? magicResult.code : EIO
                throw systemCallError("register vfkit peer", path: remotePath, code: code)
            }
            guard socketIdentity(at: socketPath) == identity else {
                throw systemCallError("retain Unix datagram identity", path: socketPath, code: ESTALE)
            }
            guard socketIdentity(at: remotePath) == remoteIdentity else {
                throw systemCallError("retain Unix datagram peer identity", path: remotePath, code: ESTALE)
            }
            guard directoryIdentity(at: localParentPath) == localParentIdentity,
                  directoryIdentity(at: remoteParentPath) == remoteParentIdentity else {
                throw systemCallError("retain Unix datagram parent authority", path: socketPath, code: ESTALE)
            }
            return SocketOwner(
                descriptor: descriptor,
                localPath: socketPath,
                localIdentity: identity,
                parentPath: localParentPath,
                parentIdentity: localParentIdentity,
                usedPathnamePeerAuthentication: usedPathnamePeerAuthentication
            )
        } catch {
            if let boundIdentity,
               directoryIdentity(at: localParentPath) == localParentIdentity {
                unlinkSocketIfOwnedLocked(socketPath, identity: boundIdentity)
            }
            close(descriptor)
            throw error
        }
    }

    private static func retireStaleLocalEndpointIfPresent(
        _ path: String,
        parentPath: String,
        parentIdentity: DirectoryIdentity
    ) throws {
        guard directoryIdentity(at: parentPath) == parentIdentity else {
            throw systemCallError("revalidate Unix datagram parent", path: parentPath, code: ESTALE)
        }
        var info = stat()
        if lstat(path, &info) != 0 {
            guard errno == ENOENT else {
                throw systemCallError("inspect Unix datagram path", path: path, code: errno)
            }
            return
        }
        guard let identity = socketIdentity(at: path) else {
            throw VMError.invalidConfiguration(
                "refusing to replace a non-socket, symlink, multiply-linked, or foreign endpoint: \(path)"
            )
        }
        switch probeExistingDatagramEndpoint(path) {
        case .live:
            throw VMError.invalidConfiguration("refusing to replace a live Unix datagram endpoint: \(path)")
        case let .indeterminate(code):
            throw systemCallError("prove Unix datagram endpoint stale", path: path, code: code)
        case .stale:
            break
        }
        guard socketIdentity(at: path) == identity else {
            throw systemCallError("revalidate stale Unix datagram endpoint", path: path, code: ESTALE)
        }
        guard directoryIdentity(at: parentPath) == parentIdentity else {
            throw systemCallError("revalidate stale Unix datagram parent", path: parentPath, code: ESTALE)
        }
        guard unlink(path) == 0 else {
            throw systemCallError("remove stale Unix datagram endpoint", path: path, code: errno)
        }
    }

    private static func probeExistingDatagramEndpoint(_ path: String) -> ExistingEndpointProbe {
        let descriptor = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { return .indeterminate(errno) }
        defer { close(descriptor) }
        do {
            try configureSocket(descriptor)
            var address = try unixAddress(path)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result == 0 { return .live }
            let code = errno
            if code == ECONNREFUSED || code == ENOENT { return .stale }
            return .indeterminate(code)
        } catch {
            return .indeterminate(errno == 0 ? EIO : errno)
        }
    }

    private static func retireOwnedSocket(
        descriptor: Int32,
        path: String,
        identity: SocketPathIdentity,
        parentPath: String,
        parentIdentity: DirectoryIdentity
    ) {
        socketPathMutationLock.lock()
        if directoryIdentity(at: parentPath) == parentIdentity {
            unlinkSocketIfOwnedLocked(path, identity: identity)
        }
        close(descriptor)
        socketPathMutationLock.unlock()
    }

    private static func unlinkSocketIfOwnedLocked(
        _ path: String,
        identity: SocketPathIdentity
    ) {
        guard socketIdentity(at: path) == identity else { return }
        _ = unlink(path)
    }

    private static func socketIdentity(at path: String) -> SocketPathIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
              info.st_uid == geteuid(),
              info.st_nlink == 1 else { return nil }
        return SocketPathIdentity(
            device: info.st_dev,
            inode: info.st_ino,
            generation: info.st_gen,
            birthTimeSeconds: Int64(info.st_birthtimespec.tv_sec),
            birthTimeNanoseconds: Int64(info.st_birthtimespec.tv_nsec),
            owner: info.st_uid
        )
    }

    private static func socketPermissions(at path: String) -> mode_t? {
        var info = stat()
        guard lstat(path, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK) else { return nil }
        return info.st_mode & 0o777
    }

    private static func directoryIdentity(at path: String) -> DirectoryIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { return nil }
        return DirectoryIdentity(
            device: info.st_dev,
            inode: info.st_ino,
            generation: info.st_gen,
            birthTimeSeconds: Int64(info.st_birthtimespec.tv_sec),
            birthTimeNanoseconds: Int64(info.st_birthtimespec.tv_nsec),
            owner: info.st_uid,
            permissions: info.st_mode & 0o7777
        )
    }

    private static func validateSocketPath(_ path: String) throws {
        let bytes = Array(path.utf8)
        let address = sockaddr_un()
        let maximumBytes = MemoryLayout.size(ofValue: address.sun_path) - 1
        guard path.hasPrefix("/"), !bytes.isEmpty else {
            throw VMError.invalidConfiguration("Unix datagram socket path must be absolute: \(path)")
        }
        guard !bytes.contains(0) else {
            throw VMError.invalidConfiguration("Unix datagram socket path contains a NUL byte: \(path)")
        }
        guard (path as NSString).standardizingPath == path else {
            throw VMError.invalidConfiguration("Unix datagram socket path is not canonical: \(path)")
        }
        guard bytes.count <= maximumBytes else {
            throw VMError.invalidConfiguration(
                "Unix datagram socket path is too long (\(bytes.count) bytes, maximum \(maximumBytes)): \(path)"
            )
        }
    }

    private static func validateTrustedParentDirectory(of path: String) throws -> DirectoryIdentity {
        let parent = (path as NSString).deletingLastPathComponent
        var info = stat()
        guard lstat(parent, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_uid == geteuid(),
              info.st_mode & 0o022 == 0 else {
            throw VMError.invalidConfiguration(
                "Unix datagram socket parent must be a same-user, non-writable directory: \(parent)"
            )
        }

        // A private leaf is not authority if another user can rename it through a writable
        // ancestor. Validate the resolved chain as root/current-user owned and non-writable, with
        // the standard sticky-directory exception that makes /private/tmp safe for owned children.
        guard let resolvedPointer = realpath(parent, nil) else {
            throw systemCallError("resolve Unix datagram parent", path: parent, code: errno)
        }
        defer { free(resolvedPointer) }
        let resolvedParent = String(cString: resolvedPointer)
        var ancestorPath = ""
        for component in resolvedParent.split(separator: "/") {
            ancestorPath += "/" + component
            var ancestor = stat()
            guard lstat(ancestorPath, &ancestor) == 0,
                  ancestor.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  ancestor.st_uid == 0 || ancestor.st_uid == geteuid() else {
                throw VMError.invalidConfiguration(
                    "Unix datagram socket ancestor is not trusted: \(ancestorPath)"
                )
            }
            let isGroupOrWorldWritable = ancestor.st_mode & 0o022 != 0
            let hasStickyOwnershipProtection = ancestor.st_mode & mode_t(S_ISVTX) != 0
            guard !isGroupOrWorldWritable || hasStickyOwnershipProtection else {
                throw VMError.invalidConfiguration(
                    "Unix datagram socket ancestor is writable without sticky protection: \(ancestorPath)"
                )
            }
        }
        guard let identity = directoryIdentity(at: parent) else {
            throw systemCallError("capture Unix datagram parent", path: parent, code: ESTALE)
        }
        return identity
    }

    private static func unixAddress(_ path: String) throws -> sockaddr_un {
        try validateSocketPath(path)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { source in
                destination.baseAddress!.copyMemory(
                    from: source.baseAddress!,
                    byteCount: bytes.count
                )
            }
        }
        return address
    }

    private static func configureSocket(_ descriptor: Int32) throws {
        let descriptorFlags = fcntl(descriptor, F_GETFD)
        guard descriptorFlags >= 0,
              fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else {
            throw systemCallError("set close-on-exec on network socket", path: "", code: errno)
        }
        let statusFlags = fcntl(descriptor, F_GETFL)
        guard statusFlags >= 0,
              fcntl(descriptor, F_SETFL, statusFlags | O_NONBLOCK) == 0 else {
            throw systemCallError("make network socket nonblocking", path: "", code: errno)
        }
        var noSigpipe: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigpipe,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw systemCallError("set no-sigpipe on network socket", path: "", code: errno)
        }
    }

    private static func setSocketBuffer(_ descriptor: Int32, option: Int32, bytes: Int32) throws {
        var value = bytes
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            option,
            &value,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw systemCallError("set network socket buffer option \(option)", path: "", code: errno)
        }
    }

    private static func systemCallError(_ operation: String, path: String, code: Int32) -> VMError {
        let suffix = path.isEmpty ? "" : " \(path)"
        return VMError.invalidConfiguration("cannot \(operation)\(suffix): errno \(code)")
    }

    /// Test-only observability for both halves of the descriptor inheritance invariant.
    var isSocketNonblockingForTesting: Bool {
        let flags = fcntl(socketOwner.descriptor, F_GETFL)
        return flags >= 0 && flags & O_NONBLOCK != 0
    }

    var isSocketCloseOnExecForTesting: Bool {
        let flags = fcntl(socketOwner.descriptor, F_GETFD)
        return flags >= 0 && flags & FD_CLOEXEC != 0
    }

    var usesPathnamePeerAuthenticationForTesting: Bool {
        socketOwner.usedPathnamePeerAuthentication
    }

    var effectiveMTUForTesting: Int {
        maximumEthernetFrameLength - Self.ethernetHeaderLength
    }

    var deferredReceiveResourceSnapshotForTesting: (frames: Int, bytes: Int) {
        receiveState.withLock { ($0.deferredCount, $0.deferredBytes) }
    }

    var isReceiveTerminalForTesting: Bool {
        receiveState.withLock { $0.terminal }
    }

    var isReceiveActiveForTesting: Bool {
        receiveState.withLock { $0.transport?.value != nil }
    }

    func synchronizeReceiveQueueForTesting() {
        receiveQueue.sync {}
    }

    func withReceiveQueueSerializedForTesting<Result>(
        _ body: () throws -> Result
    ) rethrows -> Result {
        try receiveQueue.sync(execute: body)
    }

    func setTransmitDropCountForTesting(_ value: UInt64) {
        transmitDrops.store(value, ordering: .relaxed)
    }

    func synchronizeTransmitQueueForTesting() {
        transmitQueue.sync {}
    }

    @discardableResult
    func triggerTransmitRetryForTesting() -> Bool {
        guard let target = transmitState.withLock({ state in
            state.retryRegistration.flatMap { registration in
                state.transport?.value.map { (registration.generation, $0) }
            }
        }) else { return false }
        wakeTransmitRetry(generation: target.0, transport: target.1)
        return true
    }

    var isTransmitRetryPendingForTesting: Bool {
        transmitState.withLock { $0.retryRegistration != nil }
    }
}

/// A virtio-net function that remains visible to the guest while its carrier is down. This is
/// deliberately a device, rather than an omitted backend: persistent interface identity and guest
/// configuration survive a later reconnect without accidentally granting host connectivity.
public final class VirtioDisconnectedNet: VirtioDeviceBackend, @unchecked Sendable {
    public let deviceID: UInt32 = 1
    public let queueCount = 2
    public let deviceFeatures: UInt64
    public let configSpace: [UInt8]

    public init(
        macAddress: [UInt8] = VirtioNet.guestMAC,
        maximumTransmissionUnit: UInt16
    ) {
        precondition(macAddress.count == 6, "a virtio-net MAC address must contain six bytes")
        precondition(
            (1_280...9_000).contains(Int(maximumTransmissionUnit)),
            "virtio-net MTU must be 1280...9000 bytes"
        )
        // virtio_net_config.mac followed by little-endian status. A zero status keeps LINK_UP
        // clear, which Linux reports as NO-CARRIER while retaining the interface.
        deviceFeatures = (1 << 5) | (1 << 16) | (1 << 3)
        configSpace = macAddress + [0, 0, 0, 0]
            + [UInt8(truncatingIfNeeded: maximumTransmissionUnit),
               UInt8(truncatingIfNeeded: maximumTransmissionUnit >> 8)]
    }

    public func handleKick(queue: Int, transport: VirtioMMIOTransport) {
        guard queue == 1 else { return }
        let virtqueue = transport.queues[1]
        var interrupt = false
        while true {
            do {
                guard let chain = try virtqueue.pop() else { break }
                interrupt = try virtqueue.push(chain, written: 0) || interrupt
            } catch {
                // A malformed disconnected TX queue cannot be completed safely; stop this drain
                // instead of conflating the fault with an empty queue and walking later entries.
                break
            }
        }
        if interrupt { transport.notifyUsed() }
    }
}
