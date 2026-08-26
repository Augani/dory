import DoryFSWorkerContracts
import Foundation

public enum VirtioSoundDirection: UInt8, Sendable {
    case output = 0
    case input = 1
}

public struct VirtioSoundPCMParameters: Equatable, Sendable {
    public var bufferBytes: Int
    public var periodBytes: Int
    public var sampleRate: Double
    public var channels: Int
    public var bytesPerSample: Int

    public init(
        bufferBytes: Int,
        periodBytes: Int,
        sampleRate: Double,
        channels: Int,
        bytesPerSample: Int = 2
    ) {
        self.bufferBytes = bufferBytes
        self.periodBytes = periodBytes
        self.sampleRate = sampleRate
        self.channels = channels
        self.bytesPerSample = bytesPerSample
    }

    public var bytesPerFrame: Int { channels * bytesPerSample }
}

/// Host audio implementation used by the virtio-snd transport. Dory's production implementation
/// is backed by AVAudioEngine; tests use an in-memory backend so the device state machine and queue
/// completion rules remain deterministic.
public protocol VirtioSoundHost: AnyObject, Sendable {
    func configure(
        streamID: Int,
        direction: VirtioSoundDirection,
        parameters: VirtioSoundPCMParameters
    ) -> Bool
    func prepare(streamID: Int, direction: VirtioSoundDirection) -> Bool
    func start(streamID: Int, direction: VirtioSoundDirection) -> Bool
    func stop(streamID: Int, direction: VirtioSoundDirection) -> Bool
    func release(streamID: Int, direction: VirtioSoundDirection)
    func enqueuePlayback(
        _ data: Data,
        parameters: VirtioSoundPCMParameters,
        completion: @escaping @Sendable (_ success: Bool, _ latencyBytes: UInt32) -> Void
    ) -> Bool
    func requestCapture(
        byteCount: Int,
        parameters: VirtioSoundPCMParameters,
        completion: @escaping @Sendable (_ data: Data?, _ latencyBytes: UInt32) -> Void
    ) -> Bool
    func reset()
}

public struct VirtioSoundStatistics: Equatable, Sendable {
    public var invalidControlChains: UInt64
    public var invalidEventChains: UInt64
    public var invalidPlaybackChains: UInt64
    public var invalidCaptureChains: UInt64
    public var completedPlaybackPeriods: UInt64
    public var completedCapturePeriods: UInt64
    public var timedOutPeriods: UInt64
    public var lateHostCompletions: UInt64
    public var backpressuredPeriods: UInt64
    public var queueFaults: UInt64
    public var publicationFaults: UInt64
    public var boundedDrainStops: UInt64
}

/// Frontend work/retention limits. Byte ceilings intentionally match the production Core Audio
/// backend, while the period and kick ceilings are independent untrusted-guest admission bounds.
struct VirtioSoundLimits: Equatable, Sendable {
    static let production = VirtioSoundLimits(
        maximumBufferBytes: 4 * 1_024 * 1_024,
        maximumPeriodBytes: 1 * 1_024 * 1_024,
        maximumPeriodsPerStream: 64,
        maximumChainsPerKick: 64,
        maximumBytesPerKick: 4 * 1_024 * 1_024,
        maximumRetainedEventBuffers: 64,
        completionTimeout: .seconds(30)
    )

    let maximumBufferBytes: Int
    let maximumPeriodBytes: Int
    let maximumPeriodsPerStream: Int
    let maximumChainsPerKick: Int
    let maximumBytesPerKick: Int
    let maximumRetainedEventBuffers: Int
    let completionTimeout: Duration

    init(
        maximumBufferBytes: Int,
        maximumPeriodBytes: Int,
        maximumPeriodsPerStream: Int,
        maximumChainsPerKick: Int,
        maximumBytesPerKick: Int,
        maximumRetainedEventBuffers: Int,
        completionTimeout: Duration
    ) {
        precondition(maximumBufferBytes > 0)
        precondition(maximumPeriodBytes > 0 && maximumPeriodBytes <= maximumBufferBytes)
        precondition(maximumPeriodsPerStream > 0)
        precondition(maximumChainsPerKick > 0)
        precondition(maximumChainsPerKick <= Int(Virtqueue.maximumSize))
        precondition(maximumBytesPerKick >= maximumPeriodBytes)
        precondition(maximumRetainedEventBuffers > 0)
        precondition(completionTimeout > .zero)
        self.maximumBufferBytes = maximumBufferBytes
        self.maximumPeriodBytes = maximumPeriodBytes
        self.maximumPeriodsPerStream = maximumPeriodsPerStream
        self.maximumChainsPerKick = maximumChainsPerKick
        self.maximumBytesPerKick = maximumBytesPerKick
        self.maximumRetainedEventBuffers = maximumRetainedEventBuffers
        self.completionTimeout = completionTimeout
    }
}

protocol VirtioSoundScheduledOperation: AnyObject, Sendable {
    func cancel()
}

protocol VirtioSoundCompletionScheduling: Sendable {
    func schedule(
        after delay: Duration,
        operation: @escaping @Sendable () -> Void
    ) -> any VirtioSoundScheduledOperation
}

private final class TaskVirtioSoundScheduledOperation:
    VirtioSoundScheduledOperation,
    @unchecked Sendable
{
    private let task: Task<Void, Never>

    init(task: Task<Void, Never>) {
        self.task = task
    }

    func cancel() { task.cancel() }

    deinit { task.cancel() }
}

private struct TaskVirtioSoundCompletionScheduler: VirtioSoundCompletionScheduling {
    func schedule(
        after delay: Duration,
        operation: @escaping @Sendable () -> Void
    ) -> any VirtioSoundScheduledOperation {
        let task = Task<Void, Never> {
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            operation()
        }
        return TaskVirtioSoundScheduledOperation(task: task)
    }
}

/// VirtIO 1.3 sound with one output and one input PCM stream. No optional sound feature is
/// advertised: shared-memory transport, polling, period events, XRUN events, jacks, channel maps,
/// and mixer controls remain unsupported rather than being emulated incompletely.
public final class VirtioSound: VirtioDeviceBackend, @unchecked Sendable {
    public let deviceID: UInt32 = 25
    public let deviceFeatures: UInt64 = 0
    public let queueCount = 4  // control, event, playback TX, capture RX

    private enum Request {
        static let pcmInfo: UInt32 = 0x0100
        static let pcmSetParameters: UInt32 = 0x0101
        static let pcmPrepare: UInt32 = 0x0102
        static let pcmRelease: UInt32 = 0x0103
        static let pcmStart: UInt32 = 0x0104
        static let pcmStop: UInt32 = 0x0105
    }

    private enum Status: UInt32 {
        case ok = 0x8000
        case badMessage = 0x8001
        case notSupported = 0x8002
        case ioError = 0x8003
    }

    private enum Lifecycle {
        case idle
        case parameters
        case prepared
        case running
        case faulted
    }

    private enum PendingKind: Sendable {
        case playback
        case capture
    }

    private enum CompletionSource: Equatable {
        case host
        case hostRejected
        case watchdog
    }

    private struct Stream {
        var direction: VirtioSoundDirection
        var lifecycle: Lifecycle = .idle
        var parameters: VirtioSoundPCMParameters?
    }

    private struct PendingIO {
        var streamID: Int
        var chain: VirtqueueChain
        var generation: UInt64
        var payloadBytes: Int
        var watchdog: (any VirtioSoundScheduledOperation)?
    }

    private struct OrderedLayout {
        var readableBytes: Int
        var writableBytes: Int
    }

    private static let streamCount = 2
    private static let controlStatusSize = 4
    private static let pcmTransferHeaderSize = 4
    private static let pcmStatusSize = 8
    private static let eventSize = 8
    private static let queryInfoSize = 16
    private static let setParametersSize = 24
    private static let pcmHeaderSize = 8
    private static let maximumControlRequestSize = setParametersSize
    private static let pcmInfoSize = 32
    private static let s16Format: UInt8 = 5
    private static let supportedFormats: UInt64 = 1 << s16Format
    private static let rateValues: [UInt8: Double] = [6: 44_100, 7: 48_000]
    private static let supportedRates: UInt64 = rateValues.keys.reduce(0) { $0 | (1 << $1) }

    private let host: VirtioSoundHost
    private let log: @Sendable (String) -> Void
    private let limits: VirtioSoundLimits
    private let completionScheduler: any VirtioSoundCompletionScheduling
    private let lock = NSLock()
    private var streams = [
        Stream(direction: .output),
        Stream(direction: .input),
    ]
    private var nextRequestID: UInt64 = 1
    // Each stream advances independently so releasing capture cannot invalidate an in-flight
    // playback completion (and vice versa).
    private var streamGenerations = [UInt64](repeating: 1, count: streamCount)
    private var pendingPlayback = [UInt64: PendingIO]()
    private var pendingCapture = [UInt64: PendingIO]()
    private var retainedEventBuffers = [VirtqueueChain]()
    private var terminalQueues = Set<Int>()
    private var statisticsState = VirtioSoundStatistics(
        invalidControlChains: 0,
        invalidEventChains: 0,
        invalidPlaybackChains: 0,
        invalidCaptureChains: 0,
        completedPlaybackPeriods: 0,
        completedCapturePeriods: 0,
        timedOutPeriods: 0,
        lateHostCompletions: 0,
        backpressuredPeriods: 0,
        queueFaults: 0,
        publicationFaults: 0,
        boundedDrainStops: 0
    )

    public convenience init(
        host: VirtioSoundHost,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.init(
            host: host,
            log: log,
            limits: .production,
            completionScheduler: TaskVirtioSoundCompletionScheduler()
        )
    }

    init(
        host: VirtioSoundHost,
        log: @escaping @Sendable (String) -> Void = { _ in },
        limits: VirtioSoundLimits,
        completionScheduler: any VirtioSoundCompletionScheduling
    ) {
        self.host = host
        self.log = log
        self.limits = limits
        self.completionScheduler = completionScheduler
    }

    deinit {
        let watchdogs = lock.withLock {
            let values = Array(pendingPlayback.values) + Array(pendingCapture.values)
            pendingPlayback.removeAll()
            pendingCapture.removeAll()
            retainedEventBuffers.removeAll()
            return values.compactMap(\.watchdog)
        }
        watchdogs.forEach { $0.cancel() }
    }

    public var configSpace: [UInt8] {
        var bytes = [UInt8]()
        bytes.appendLE(UInt32(0))
        bytes.appendLE(UInt32(Self.streamCount))
        bytes.appendLE(UInt32(0))
        return bytes
    }

    public var statistics: VirtioSoundStatistics {
        lock.withLock { statisticsState }
    }

    public func handleKick(queue: Int, transport: VirtioMMIOTransport) {
        guard (0..<queueCount).contains(queue), !isTerminal(queue) else { return }
        switch queue {
        case 0: drainControlQueue(transport)
        case 1: drainEventQueue(transport)
        case 2: drainPlaybackQueue(transport)
        case 3: drainCaptureQueue(transport)
        default: break
        }
    }

    public func deviceReset(transport: VirtioMMIOTransport) {
        let watchdogs = lock.withLock {
            for index in streamGenerations.indices { streamGenerations[index] &+= 1 }
            let values = Array(pendingPlayback.values) + Array(pendingCapture.values)
            pendingPlayback.removeAll()
            pendingCapture.removeAll()
            retainedEventBuffers.removeAll()
            terminalQueues.removeAll()
            streams = [Stream(direction: .output), Stream(direction: .input)]
            return values.compactMap(\.watchdog)
        }
        watchdogs.forEach { $0.cancel() }
        host.reset()
    }

    public func queueStateChanged(queue: Int, ready: Bool, transport: VirtioMMIOTransport) {
        guard (0..<queueCount).contains(queue) else { return }
        var discardedPlayback = 0
        var discardedCapture = 0
        let watchdogs: [any VirtioSoundScheduledOperation] = lock.withLock {
            terminalQueues.remove(queue)
            switch queue {
            case 1:
                retainedEventBuffers.removeAll()
                return []
            case 2:
                streamGenerations[0] &+= 1
                let values = Array(pendingPlayback.values)
                discardedPlayback = values.count
                pendingPlayback.removeAll()
                return values.compactMap(\.watchdog)
            case 3:
                streamGenerations[1] &+= 1
                let values = Array(pendingCapture.values)
                discardedCapture = values.count
                pendingCapture.removeAll()
                return values.compactMap(\.watchdog)
            default:
                return []
            }
        }
        watchdogs.forEach { $0.cancel() }
        if discardedPlayback > 0 || discardedCapture > 0 {
            log(
                "virtio sound queue \(queue) reconfigured ready=\(ready) with "
                    + "playback=\(discardedPlayback), capture=\(discardedCapture) pending"
            )
        }
    }

    private func drainControlQueue(_ transport: VirtioMMIOTransport) {
        let queue = transport.queues[0]
        var interrupt = false
        var handled = 0
        while handled < limits.maximumChainsPerKick {
            guard let chain = pop(queue, queueIndex: 0) else { break }
            handled += 1
            let admission = chain.withLeaseHeld { access -> ([UInt8], Int)? in
                guard let layout = Self.orderedLayout(access),
                      !chain.containsZeroLengthDescriptor,
                      layout.readableBytes >= Self.controlStatusSize,
                      layout.readableBytes <= Self.maximumControlRequestSize,
                      layout.writableBytes >= Self.controlStatusSize else { return nil }
                let request = access.readBytes(maximum: Self.maximumControlRequestSize)
                return request.count == layout.readableBytes
                    ? (request, layout.writableBytes)
                    : nil
            } ?? nil
            guard let (request, capacity) = admission else {
                lock.withLock { statisticsState.invalidControlChains &+= 1 }
                guard push(chain, queue: queue, queueIndex: 0, written: 0, interrupt: &interrupt) else {
                    break
                }
                continue
            }
            let response = processControlRequest(
                request,
                responseCapacity: capacity,
                transport: transport
            )
            let written = chain.withLeaseHeld { $0.writeBytes(response) } ?? 0
            guard written == response.count else {
                recordPublicationFault(queue: 0, reason: "short control response write")
                break
            }
            guard push(chain, queue: queue, queueIndex: 0, written: written, interrupt: &interrupt) else {
                break
            }
        }
        recordBoundedStopIfNeeded(handled: handled, queue: queue)
        if interrupt { transport.notifyUsed() }
    }

    /// Linux pre-populates eventq with exact writable 8-byte entries. No event-producing feature
    /// is advertised, but retaining a bounded validated prefix prevents arbitrary guest chains
    /// from becoming hidden state and leaves an explicit admission seam for future event support.
    private func drainEventQueue(_ transport: VirtioMMIOTransport) {
        let queue = transport.queues[1]
        var interrupt = false
        var handled = 0
        while handled < limits.maximumChainsPerKick {
            guard lock.withLock({ retainedEventBuffers.count < limits.maximumRetainedEventBuffers }) else {
                lock.withLock { statisticsState.backpressuredPeriods &+= 1 }
                break
            }
            guard let chain = pop(queue, queueIndex: 1) else { break }
            handled += 1
            let valid = chain.withLeaseHeld { access in
                !chain.containsZeroLengthDescriptor
                    && access.readableSegmentCount == 0
                    && access.writableSegmentCount > 0
                    && access.writableByteCount == Self.eventSize
            } ?? false
            if valid {
                lock.withLock { retainedEventBuffers.append(chain) }
            } else {
                lock.withLock { statisticsState.invalidEventChains &+= 1 }
                guard push(chain, queue: queue, queueIndex: 1, written: 0, interrupt: &interrupt) else {
                    break
                }
            }
        }
        recordBoundedStopIfNeeded(handled: handled, queue: queue)
        if interrupt { transport.notifyUsed() }
    }

    private func drainPlaybackQueue(_ transport: VirtioMMIOTransport) {
        let queue = transport.queues[2]
        var interrupt = false
        var handled = 0
        var copiedBytes = 0
        while handled < limits.maximumChainsPerKick {
            if lock.withLock({ pendingPlayback.count >= limits.maximumPeriodsPerStream }) {
                lock.withLock {
                    statisticsState.backpressuredPeriods &+= 1
                    statisticsState.boundedDrainStops &+= 1
                }
                break
            }
            guard let chain = pop(queue, queueIndex: 2) else { break }
            handled += 1
            let admission = chain.withLeaseHeld { access -> ([UInt8], Int)? in
                guard let layout = Self.orderedLayout(access),
                      !chain.containsZeroLengthDescriptor,
                      layout.readableBytes > Self.pcmTransferHeaderSize,
                      layout.readableBytes <= Self.pcmTransferHeaderSize + limits.maximumPeriodBytes,
                      layout.writableBytes == Self.pcmStatusSize else { return nil }
                let request = access.readBytes(
                    maximum: Self.pcmTransferHeaderSize + limits.maximumPeriodBytes
                )
                return request.count == layout.readableBytes
                    ? (request, layout.readableBytes - Self.pcmTransferHeaderSize)
                    : nil
            } ?? nil
            guard let (request, payloadBytes) = admission else {
                lock.withLock { statisticsState.invalidPlaybackChains &+= 1 }
                guard push(chain, queue: queue, queueIndex: 2, written: 0, interrupt: &interrupt) else {
                    break
                }
                continue
            }
            guard payloadBytes <= limits.maximumBytesPerKick - copiedBytes else {
                lock.withLock {
                    statisticsState.backpressuredPeriods &+= 1
                    statisticsState.boundedDrainStops &+= 1
                }
                guard completePlaybackImmediately(chain, queue: queue, interrupt: &interrupt) else { break }
                continue
            }
            copiedBytes += payloadBytes
            let streamID = Int(request.leUInt32(at: 0))
            let audio = Data(request[Self.pcmTransferHeaderSize...])
            let reservation: (UInt64, VirtioSoundPCMParameters)? = lock.withLock {
                guard streamID == 0,
                      streams[streamID].direction == .output,
                      streams[streamID].lifecycle == .prepared
                        || streams[streamID].lifecycle == .running,
                      let parameters = streams[streamID].parameters,
                      payloadBytes <= parameters.periodBytes,
                      payloadBytes % parameters.bytesPerFrame == 0,
                      pendingPlayback.count < limits.maximumPeriodsPerStream,
                      Self.pendingBytes(pendingPlayback) <= parameters.bufferBytes - payloadBytes else {
                    return nil
                }
                let requestID = allocateRequestID()
                pendingPlayback[requestID] = PendingIO(
                    streamID: streamID,
                    chain: chain,
                    generation: streamGenerations[streamID],
                    payloadBytes: payloadBytes,
                    watchdog: nil
                )
                return (requestID, parameters)
            }
            guard let (requestID, parameters) = reservation else {
                lock.withLock { statisticsState.invalidPlaybackChains &+= 1 }
                guard completePlaybackImmediately(chain, queue: queue, interrupt: &interrupt) else { break }
                continue
            }
            let accepted = host.enqueuePlayback(audio, parameters: parameters) {
                [weak self, weak transport] success, latency in
                guard let self, let transport else { return }
                self.completePlayback(
                    requestID: requestID,
                    success: success,
                    latencyBytes: latency,
                    source: .host,
                    transport: transport
                )
            }
            if accepted {
                installWatchdog(kind: .playback, requestID: requestID, transport: transport)
            } else {
                completePlayback(
                    requestID: requestID,
                    success: false,
                    latencyBytes: 0,
                    source: .hostRejected,
                    transport: transport
                )
            }
        }
        recordBoundedStopIfNeeded(handled: handled, queue: queue)
        if interrupt { transport.notifyUsed() }
    }

    private func drainCaptureQueue(_ transport: VirtioMMIOTransport) {
        let queue = transport.queues[3]
        var interrupt = false
        var handled = 0
        var requestedBytes = 0
        while handled < limits.maximumChainsPerKick {
            if lock.withLock({ pendingCapture.count >= limits.maximumPeriodsPerStream }) {
                lock.withLock {
                    statisticsState.backpressuredPeriods &+= 1
                    statisticsState.boundedDrainStops &+= 1
                }
                break
            }
            guard let chain = pop(queue, queueIndex: 3) else { break }
            handled += 1
            let admission = chain.withLeaseHeld { access -> (UInt32, Int)? in
                guard let layout = Self.orderedLayout(access),
                      !chain.containsZeroLengthDescriptor,
                      layout.readableBytes == Self.pcmTransferHeaderSize,
                      layout.writableBytes > Self.pcmStatusSize,
                      layout.writableBytes <= limits.maximumPeriodBytes + Self.pcmStatusSize else {
                    return nil
                }
                let request = access.readBytes(maximum: Self.pcmTransferHeaderSize)
                guard request.count == Self.pcmTransferHeaderSize else { return nil }
                return (request.leUInt32(at: 0), layout.writableBytes - Self.pcmStatusSize)
            } ?? nil
            guard let (rawStreamID, payloadBytes) = admission else {
                lock.withLock { statisticsState.invalidCaptureChains &+= 1 }
                guard push(chain, queue: queue, queueIndex: 3, written: 0, interrupt: &interrupt) else {
                    break
                }
                continue
            }
            guard payloadBytes <= limits.maximumBytesPerKick - requestedBytes else {
                lock.withLock {
                    statisticsState.backpressuredPeriods &+= 1
                    statisticsState.boundedDrainStops &+= 1
                }
                guard completeCaptureImmediately(
                    chain,
                    payloadBytes: payloadBytes,
                    queue: queue,
                    interrupt: &interrupt
                ) else { break }
                continue
            }
            requestedBytes += payloadBytes
            let streamID = Int(rawStreamID)
            let reservation: (UInt64, VirtioSoundPCMParameters)? = lock.withLock {
                guard streamID == 1,
                      streams[streamID].direction == .input,
                      streams[streamID].lifecycle == .prepared
                        || streams[streamID].lifecycle == .running,
                      let parameters = streams[streamID].parameters,
                      payloadBytes <= parameters.periodBytes,
                      payloadBytes % parameters.bytesPerFrame == 0,
                      pendingCapture.count < limits.maximumPeriodsPerStream,
                      Self.pendingBytes(pendingCapture) <= parameters.bufferBytes - payloadBytes else {
                    return nil
                }
                let requestID = allocateRequestID()
                pendingCapture[requestID] = PendingIO(
                    streamID: streamID,
                    chain: chain,
                    generation: streamGenerations[streamID],
                    payloadBytes: payloadBytes,
                    watchdog: nil
                )
                return (requestID, parameters)
            }
            guard let (requestID, parameters) = reservation else {
                lock.withLock { statisticsState.invalidCaptureChains &+= 1 }
                guard completeCaptureImmediately(
                    chain,
                    payloadBytes: payloadBytes,
                    queue: queue,
                    interrupt: &interrupt
                ) else { break }
                continue
            }
            let accepted = host.requestCapture(byteCount: payloadBytes, parameters: parameters) {
                [weak self, weak transport] data, latency in
                guard let self, let transport else { return }
                self.completeCapture(
                    requestID: requestID,
                    data: data,
                    latencyBytes: latency,
                    source: .host,
                    transport: transport
                )
            }
            if accepted {
                installWatchdog(kind: .capture, requestID: requestID, transport: transport)
            } else {
                completeCapture(
                    requestID: requestID,
                    data: nil,
                    latencyBytes: 0,
                    source: .hostRejected,
                    transport: transport
                )
            }
        }
        recordBoundedStopIfNeeded(handled: handled, queue: queue)
        if interrupt { transport.notifyUsed() }
    }

    private func installWatchdog(
        kind: PendingKind,
        requestID: UInt64,
        transport: VirtioMMIOTransport
    ) {
        let operation = completionScheduler.schedule(after: limits.completionTimeout) {
            [weak self, weak transport] in
            guard let self, let transport else { return }
            switch kind {
            case .playback:
                self.completePlayback(
                    requestID: requestID,
                    success: false,
                    latencyBytes: 0,
                    source: .watchdog,
                    transport: transport
                )
            case .capture:
                self.completeCapture(
                    requestID: requestID,
                    data: nil,
                    latencyBytes: 0,
                    source: .watchdog,
                    transport: transport
                )
            }
        }
        let installed = lock.withLock {
            switch kind {
            case .playback:
                guard var pending = pendingPlayback[requestID] else { return false }
                pending.watchdog = operation
                pendingPlayback[requestID] = pending
            case .capture:
                guard var pending = pendingCapture[requestID] else { return false }
                pending.watchdog = operation
                pendingCapture[requestID] = pending
            }
            return true
        }
        if !installed { operation.cancel() }
    }

    private func completePlayback(
        requestID: UInt64,
        success: Bool,
        latencyBytes: UInt32,
        source: CompletionSource,
        transport: VirtioMMIOTransport
    ) {
        var interrupt = false
        var watchdog: (any VirtioSoundScheduledOperation)?
        var published = false
        transport.withQueueLock {
            let pending: PendingIO? = lock.withLock {
                guard let value = pendingPlayback.removeValue(forKey: requestID),
                      value.generation == streamGenerations[value.streamID] else {
                    if source == .host { statisticsState.lateHostCompletions &+= 1 }
                    return nil
                }
                if source == .watchdog { statisticsState.timedOutPeriods &+= 1 }
                watchdog = value.watchdog
                return value
            }
            guard let pending,
                  !isTerminal(2),
                  transport.queues[2].ready,
                  transport.queues[2].isLeaseValid(pending.chain) else { return }
            let status = Self.ioStatus(success ? .ok : .ioError, latencyBytes: latencyBytes)
            let written = pending.chain.withLeaseHeld { $0.writeBytes(status) } ?? 0
            guard written == Self.pcmStatusSize else {
                recordPublicationFault(queue: 2, reason: "short playback status write")
                return
            }
            published = push(
                pending.chain,
                queue: transport.queues[2],
                queueIndex: 2,
                written: written,
                interrupt: &interrupt
            )
        }
        watchdog?.cancel()
        if published { lock.withLock { statisticsState.completedPlaybackPeriods &+= 1 } }
        if interrupt { transport.notifyUsed() }
    }

    private func completeCapture(
        requestID: UInt64,
        data: Data?,
        latencyBytes: UInt32,
        source: CompletionSource,
        transport: VirtioMMIOTransport
    ) {
        var interrupt = false
        var watchdog: (any VirtioSoundScheduledOperation)?
        var published = false
        transport.withQueueLock {
            let pending: PendingIO? = lock.withLock {
                guard let value = pendingCapture.removeValue(forKey: requestID),
                      value.generation == streamGenerations[value.streamID] else {
                    if source == .host { statisticsState.lateHostCompletions &+= 1 }
                    return nil
                }
                if source == .watchdog { statisticsState.timedOutPeriods &+= 1 }
                watchdog = value.watchdog
                return value
            }
            guard let pending,
                  !isTerminal(3),
                  transport.queues[3].ready,
                  transport.queues[3].isLeaseValid(pending.chain) else { return }
            let validData = data.flatMap { $0.count == pending.payloadBytes ? $0 : nil }
            let publication = pending.chain.withLeaseHeld { access -> Int? in
                var payloadWritten = 0
                if let validData {
                    payloadWritten = access.writeBytes(Array(validData))
                    guard payloadWritten == pending.payloadBytes else { return nil }
                }
                let status = Self.ioStatus(
                    validData == nil ? .ioError : .ok,
                    latencyBytes: latencyBytes
                )
                let statusWritten = access.writeBytes(status, atWritableOffset: pending.payloadBytes)
                guard statusWritten == Self.pcmStatusSize else { return nil }
                return validData == nil ? Self.pcmStatusSize : payloadWritten + statusWritten
            } ?? nil
            guard let written = publication else {
                recordPublicationFault(queue: 3, reason: "short capture response write")
                return
            }
            published = push(
                pending.chain,
                queue: transport.queues[3],
                queueIndex: 3,
                written: written,
                interrupt: &interrupt
            )
        }
        watchdog?.cancel()
        if published { lock.withLock { statisticsState.completedCapturePeriods &+= 1 } }
        if interrupt { transport.notifyUsed() }
    }

    private func completePlaybackImmediately(
        _ chain: VirtqueueChain,
        queue: Virtqueue,
        interrupt: inout Bool
    ) -> Bool {
        let written = chain.withLeaseHeld {
            $0.writeBytes(Self.ioStatus(.ioError, latencyBytes: 0))
        } ?? 0
        return push(
            chain,
            queue: queue,
            queueIndex: 2,
            written: written == Self.pcmStatusSize ? written : 0,
            interrupt: &interrupt
        )
    }

    private func completeCaptureImmediately(
        _ chain: VirtqueueChain,
        payloadBytes: Int,
        queue: Virtqueue,
        interrupt: inout Bool
    ) -> Bool {
        let written = chain.withLeaseHeld {
            $0.writeBytes(Self.ioStatus(.ioError, latencyBytes: 0), atWritableOffset: payloadBytes)
        } ?? 0
        guard written == Self.pcmStatusSize else {
            recordPublicationFault(queue: 3, reason: "short immediate capture status write")
            return false
        }
        return push(
            chain,
            queue: queue,
            queueIndex: 3,
            written: written,
            interrupt: &interrupt
        )
    }

    private func processControlRequest(
        _ request: [UInt8],
        responseCapacity: Int,
        transport: VirtioMMIOTransport?
    ) -> [UInt8] {
        guard responseCapacity >= Self.controlStatusSize else { return [] }
        guard request.count >= Self.controlStatusSize else { return Self.header(.badMessage) }
        let code = request.leUInt32(at: 0)
        switch code {
        case Request.pcmInfo:
            guard request.count == Self.queryInfoSize else { return Self.header(.badMessage) }
            return pcmInfoResponse(request, responseCapacity: responseCapacity)
        case Request.pcmSetParameters:
            guard request.count == Self.setParametersSize else { return Self.header(.badMessage) }
            return setParametersResponse(request, responseCapacity: responseCapacity)
        case Request.pcmPrepare, Request.pcmRelease, Request.pcmStart, Request.pcmStop:
            guard request.count == Self.pcmHeaderSize else { return Self.header(.badMessage) }
            return lifecycleResponse(
                code: code,
                streamID: Int(request.leUInt32(at: 4)),
                responseCapacity: responseCapacity,
                transport: transport
            )
        default:
            return Self.header(.notSupported)
        }
    }

    private func pcmInfoResponse(_ request: [UInt8], responseCapacity: Int) -> [UInt8] {
        let start = Int(request.leUInt32(at: 4))
        let count = Int(request.leUInt32(at: 8))
        let itemSize = Int(request.leUInt32(at: 12))
        guard count > 0, start < Self.streamCount,
              count <= Self.streamCount - start,
              itemSize == Self.pcmInfoSize else {
            return Self.header(.badMessage)
        }
        let requiredCapacity = Self.controlStatusSize + count * Self.pcmInfoSize
        guard responseCapacity >= requiredCapacity else { return Self.header(.badMessage) }
        var response = Self.header(.ok)
        response.reserveCapacity(requiredCapacity)
        for streamID in start..<(start + count) {
            response.appendLE(UInt32(1))
            response.appendLE(UInt32(0))
            response.appendLE(Self.supportedFormats)
            response.appendLE(Self.supportedRates)
            response.append(
                streamID == 0
                    ? VirtioSoundDirection.output.rawValue
                    : VirtioSoundDirection.input.rawValue
            )
            response.append(1)
            response.append(2)
            response.append(contentsOf: repeatElement(0, count: 5))
        }
        return response
    }

    private func setParametersResponse(_ request: [UInt8], responseCapacity: Int) -> [UInt8] {
        guard responseCapacity >= Self.controlStatusSize else { return [] }
        let streamID = Int(request.leUInt32(at: 4))
        let bufferBytes = Int(request.leUInt32(at: 8))
        let periodBytes = Int(request.leUInt32(at: 12))
        let features = request.leUInt32(at: 16)
        let channels = Int(request[20])
        let format = request[21]
        let rate = request[22]
        guard streamID >= 0, streamID < Self.streamCount,
              bufferBytes > 0, bufferBytes <= limits.maximumBufferBytes,
              periodBytes > 0, periodBytes <= limits.maximumPeriodBytes,
              periodBytes <= bufferBytes,
              bufferBytes % periodBytes == 0,
              bufferBytes / periodBytes <= limits.maximumPeriodsPerStream,
              features == 0,
              channels >= 1, channels <= 2,
              format == Self.s16Format,
              let sampleRate = Self.rateValues[rate],
              request[23] == 0 else {
            return Self.header(.notSupported)
        }
        let bytesPerFrame = channels * 2
        guard periodBytes % bytesPerFrame == 0,
              bufferBytes % bytesPerFrame == 0 else {
            return Self.header(.badMessage)
        }
        let current = lock.withLock { () -> Stream? in
            guard pendingPlayback.values.allSatisfy({ $0.streamID != streamID }),
                  pendingCapture.values.allSatisfy({ $0.streamID != streamID }),
                  streams[streamID].lifecycle != .running,
                  streams[streamID].lifecycle != .faulted else { return nil }
            return streams[streamID]
        }
        guard let current else { return Self.header(.ioError) }
        let parameters = VirtioSoundPCMParameters(
            bufferBytes: bufferBytes,
            periodBytes: periodBytes,
            sampleRate: sampleRate,
            channels: channels
        )
        guard host.configure(
            streamID: streamID,
            direction: current.direction,
            parameters: parameters
        ) else {
            return Self.header(.ioError)
        }
        lock.withLock {
            streams[streamID].parameters = parameters
            streams[streamID].lifecycle = .parameters
        }
        return Self.header(.ok)
    }

    private func lifecycleResponse(
        code: UInt32,
        streamID: Int,
        responseCapacity: Int,
        transport: VirtioMMIOTransport?
    ) -> [UInt8] {
        guard responseCapacity >= Self.controlStatusSize else { return [] }
        guard streamID >= 0, streamID < Self.streamCount else { return Self.header(.badMessage) }
        let current = lock.withLock { streams[streamID] }
        switch code {
        case Request.pcmPrepare:
            guard current.parameters != nil,
                  current.lifecycle == .parameters || current.lifecycle == .prepared,
                  host.prepare(streamID: streamID, direction: current.direction) else {
                return Self.header(.ioError)
            }
            lock.withLock { streams[streamID].lifecycle = .prepared }
        case Request.pcmStart:
            guard current.lifecycle == .prepared,
                  host.start(streamID: streamID, direction: current.direction) else {
                return Self.header(.ioError)
            }
            lock.withLock { streams[streamID].lifecycle = .running }
        case Request.pcmStop:
            guard current.lifecycle == .running,
                  host.stop(streamID: streamID, direction: current.direction) else {
                return Self.header(.ioError)
            }
            lock.withLock { streams[streamID].lifecycle = .prepared }
        case Request.pcmRelease:
            guard current.lifecycle == .prepared || current.lifecycle == .parameters else {
                return Self.header(.ioError)
            }
            let flushed: Bool
            if let transport {
                flushed = flushPending(streamID: streamID, transport: transport)
            } else {
                flushed = lock.withLock {
                    pendingPlayback.values.allSatisfy { $0.streamID != streamID }
                        && pendingCapture.values.allSatisfy { $0.streamID != streamID }
                }
            }
            host.release(streamID: streamID, direction: current.direction)
            lock.withLock {
                streams[streamID].lifecycle = flushed ? .parameters : .faulted
            }
            guard flushed else { return Self.header(.ioError) }
        default:
            return Self.header(.notSupported)
        }
        return Self.header(.ok)
    }

    private func flushPending(streamID: Int, transport: VirtioMMIOTransport) -> Bool {
        let playback: [PendingIO]
        let capture: [PendingIO]
        lock.lock()
        streamGenerations[streamID] &+= 1
        playback = pendingPlayback.values.filter { $0.streamID == streamID }
        capture = pendingCapture.values.filter { $0.streamID == streamID }
        pendingPlayback = pendingPlayback.filter { $0.value.streamID != streamID }
        pendingCapture = pendingCapture.filter { $0.value.streamID != streamID }
        lock.unlock()
        (playback + capture).compactMap(\.watchdog).forEach { $0.cancel() }

        if !playback.isEmpty || !capture.isEmpty {
            log("virtio sound stream \(streamID) released with playback=\(playback.count), capture=\(capture.count) pending")
        }

        var interrupt = false
        var succeeded = true
        for pending in playback {
            guard transport.queues[2].ready,
                  transport.queues[2].isLeaseValid(pending.chain) else {
                succeeded = false
                continue
            }
            let written = pending.chain.withLeaseHeld {
                $0.writeBytes(Self.ioStatus(.ioError, latencyBytes: 0))
            } ?? 0
            guard written == Self.pcmStatusSize,
                  push(
                    pending.chain,
                    queue: transport.queues[2],
                    queueIndex: 2,
                    written: written,
                    interrupt: &interrupt
                  ) else {
                succeeded = false
                continue
            }
        }
        for pending in capture {
            guard transport.queues[3].ready,
                  transport.queues[3].isLeaseValid(pending.chain) else {
                succeeded = false
                continue
            }
            let written = pending.chain.withLeaseHeld {
                $0.writeBytes(
                    Self.ioStatus(.ioError, latencyBytes: 0),
                    atWritableOffset: pending.payloadBytes
                )
            } ?? 0
            guard written == Self.pcmStatusSize,
                  push(
                    pending.chain,
                    queue: transport.queues[3],
                    queueIndex: 3,
                    written: written,
                    interrupt: &interrupt
                  ) else {
                succeeded = false
                continue
            }
        }
        if interrupt { transport.notifyUsed() }
        return succeeded
    }

    private static func orderedLayout(_ access: VirtqueueLeaseAccess) -> OrderedLayout? {
        guard !access.segments.isEmpty else { return nil }
        var sawWritable = false
        for segment in access.segments {
            if segment.isDeviceWritable {
                sawWritable = true
            } else if sawWritable {
                return nil
            }
        }
        return OrderedLayout(
            readableBytes: access.readableByteCount,
            writableBytes: access.writableByteCount
        )
    }

    private static func pendingBytes(_ pending: [UInt64: PendingIO]) -> Int {
        pending.values.reduce(into: 0) { total, value in
            let (next, overflow) = total.addingReportingOverflow(value.payloadBytes)
            total = overflow ? Int.max : next
        }
    }

    private func pop(_ queue: Virtqueue, queueIndex: Int) -> VirtqueueChain? {
        do {
            return try queue.pop()
        } catch {
            recordQueueFault(queue: queueIndex, reason: "descriptor pop failed")
            return nil
        }
    }

    private func push(
        _ chain: VirtqueueChain,
        queue: Virtqueue,
        queueIndex: Int,
        written: Int,
        interrupt: inout Bool
    ) -> Bool {
        do {
            interrupt = try queue.push(chain, written: written) || interrupt
            return true
        } catch {
            recordPublicationFault(queue: queueIndex, reason: "used-ring publication failed")
            return false
        }
    }

    private func recordQueueFault(queue: Int, reason: String) {
        lock.withLock {
            statisticsState.queueFaults &+= 1
            terminalQueues.insert(queue)
        }
        log("virtio sound queue \(queue) terminal fault: \(reason)")
    }

    private func recordPublicationFault(queue: Int, reason: String) {
        lock.withLock {
            statisticsState.publicationFaults &+= 1
            terminalQueues.insert(queue)
        }
        log("virtio sound queue \(queue) terminal publication fault: \(reason)")
    }

    private func recordBoundedStopIfNeeded(handled: Int, queue: Virtqueue) {
        if handled == limits.maximumChainsPerKick, queue.hasPending {
            lock.withLock { statisticsState.boundedDrainStops &+= 1 }
        }
    }

    private func isTerminal(_ queue: Int) -> Bool {
        lock.withLock { terminalQueues.contains(queue) }
    }

    private func allocateRequestID() -> UInt64 {
        let value = nextRequestID
        nextRequestID &+= 1
        return value
    }

    private static func header(_ status: Status) -> [UInt8] {
        var bytes = [UInt8]()
        bytes.appendLE(status.rawValue)
        return bytes
    }

    private static func ioStatus(_ status: Status, latencyBytes: UInt32) -> [UInt8] {
        var bytes = header(status)
        bytes.appendLE(latencyBytes)
        return bytes
    }

    // Protocol-level test hook; production requests always arrive through controlq.
    func controlResponseForTesting(_ request: [UInt8], responseCapacity: Int = 4096) -> [UInt8] {
        processControlRequest(request, responseCapacity: responseCapacity, transport: nil)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
