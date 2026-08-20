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

/// VirtIO 1.2 sound device with one stereo-capable output stream and one stereo-capable input
/// stream. The Linux virtio-snd driver sees standard S16_LE 44.1/48 kHz PCM endpoints; actual Mac
/// device conversion and permission handling live behind `VirtioSoundHost`.
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
    }

    private static let streamCount = 2
    private static let pcmInfoSize = 32
    private static let s16Format: UInt8 = 5
    private static let supportedFormats: UInt64 = 1 << s16Format
    private static let rateValues: [UInt8: Double] = [6: 44_100, 7: 48_000]
    private static let supportedRates: UInt64 = rateValues.keys.reduce(0) { $0 | (1 << $1) }

    private let host: VirtioSoundHost
    private let log: @Sendable (String) -> Void
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

    public init(
        host: VirtioSoundHost,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.host = host
        self.log = log
    }

    public var configSpace: [UInt8] {
        var bytes = [UInt8]()
        bytes.appendLE(UInt32(0))
        bytes.appendLE(UInt32(Self.streamCount))
        bytes.appendLE(UInt32(0))
        return bytes
    }

    public func handleKick(queue: Int, transport: VirtioMMIOTransport) {
        switch queue {
        case 0: drainControlQueue(transport)
        case 1: break  // no unsolicited events are advertised
        case 2: drainPlaybackQueue(transport)
        case 3: drainCaptureQueue(transport)
        default: break
        }
    }

    public func deviceReset(transport: VirtioMMIOTransport) {
        lock.lock()
        for index in streamGenerations.indices { streamGenerations[index] &+= 1 }
        pendingPlayback.removeAll()
        pendingCapture.removeAll()
        streams = [Stream(direction: .output), Stream(direction: .input)]
        lock.unlock()
        host.reset()
    }

    public func queueStateChanged(queue: Int, ready: Bool, transport: VirtioMMIOTransport) {
        guard !ready, queue == 2 || queue == 3 else { return }
        lock.lock()
        let streamID = queue == 2 ? 0 : 1
        let playbackCount = pendingPlayback.count
        let captureCount = pendingCapture.count
        streamGenerations[streamID] &+= 1
        if queue == 2 { pendingPlayback.removeAll() }
        if queue == 3 { pendingCapture.removeAll() }
        lock.unlock()
        if playbackCount > 0 || captureCount > 0 {
            log("virtio sound queue \(queue) disabled with playback=\(playbackCount), capture=\(captureCount)")
        }
    }

    private func drainControlQueue(_ transport: VirtioMMIOTransport) {
        let queue = transport.queues[0]
        var interrupt = false
        while let chain = (try? queue.pop()) ?? nil {
            let capacity = chain.writableSegments.reduce(0) { $0 + $1.length }
            let response = processControlRequest(
                chain.readBytes(maximum: 64 * 1024),
                responseCapacity: capacity,
                transport: transport
            )
            let written = chain.writeBytes(response)
            interrupt = ((try? queue.push(chain, written: written)) ?? false) || interrupt
        }
        if interrupt { transport.notifyUsed() }
    }

    private func drainPlaybackQueue(_ transport: VirtioMMIOTransport) {
        let queue = transport.queues[2]
        while let chain = (try? queue.pop()) ?? nil {
            let request = chain.readBytes()
            guard request.count >= 4 else {
                completeImmediately(chain, queue: queue, status: .badMessage, transport: transport)
                continue
            }
            let streamID = Int(request.leUInt32(at: 0))
            let audio = Data(request.dropFirst(4))
            let pending: (UInt64, PendingIO, VirtioSoundPCMParameters)? = lock.withLock {
                guard streamID == 0,
                      streams[streamID].direction == .output,
                      streams[streamID].lifecycle == .prepared || streams[streamID].lifecycle == .running,
                      let parameters = streams[streamID].parameters,
                      !audio.isEmpty,
                      audio.count % parameters.bytesPerFrame == 0 else { return nil }
                let id = allocateRequestID()
                let value = PendingIO(
                    streamID: streamID,
                    chain: chain,
                    generation: streamGenerations[streamID],
                    payloadBytes: audio.count
                )
                pendingPlayback[id] = value
                return (id, value, parameters)
            }
            guard let (requestID, _, parameters) = pending else {
                completeImmediately(chain, queue: queue, status: .ioError, transport: transport)
                continue
            }
            let accepted = host.enqueuePlayback(audio, parameters: parameters) { [weak self, weak transport] success, latency in
                guard let self, let transport else { return }
                self.completePlayback(
                    requestID: requestID,
                    success: success,
                    latencyBytes: latency,
                    transport: transport
                )
            }
            if !accepted {
                completePlayback(
                    requestID: requestID,
                    success: false,
                    latencyBytes: 0,
                    transport: transport
                )
            }
        }
    }

    private func drainCaptureQueue(_ transport: VirtioMMIOTransport) {
        let queue = transport.queues[3]
        while let chain = (try? queue.pop()) ?? nil {
            let request = chain.readBytes(maximum: 4)
            let writableBytes = chain.writableSegments.reduce(0) { $0 + $1.length }
            guard request.count == 4, writableBytes > 8 else {
                completeCaptureImmediately(
                    chain,
                    payloadBytes: max(0, writableBytes - 8),
                    queue: queue,
                    status: .badMessage,
                    transport: transport
                )
                continue
            }
            let streamID = Int(request.leUInt32(at: 0))
            let payloadBytes = writableBytes - 8
            let pending: (UInt64, VirtioSoundPCMParameters)? = lock.withLock {
                guard streamID == 1,
                      streams[streamID].direction == .input,
                      streams[streamID].lifecycle == .prepared || streams[streamID].lifecycle == .running,
                      let parameters = streams[streamID].parameters,
                      payloadBytes % parameters.bytesPerFrame == 0 else { return nil }
                let id = allocateRequestID()
                pendingCapture[id] = PendingIO(
                    streamID: streamID,
                    chain: chain,
                    generation: streamGenerations[streamID],
                    payloadBytes: payloadBytes
                )
                return (id, parameters)
            }
            guard let (requestID, parameters) = pending else {
                completeCaptureImmediately(
                    chain,
                    payloadBytes: payloadBytes,
                    queue: queue,
                    status: .ioError,
                    transport: transport
                )
                continue
            }
            let accepted = host.requestCapture(byteCount: payloadBytes, parameters: parameters) {
                [weak self, weak transport] data, latency in
                guard let self, let transport else { return }
                self.completeCapture(
                    requestID: requestID,
                    data: data,
                    latencyBytes: latency,
                    transport: transport
                )
            }
            if !accepted {
                completeCapture(
                    requestID: requestID,
                    data: nil,
                    latencyBytes: 0,
                    transport: transport
                )
            }
        }
    }

    private func completePlayback(
        requestID: UInt64,
        success: Bool,
        latencyBytes: UInt32,
        transport: VirtioMMIOTransport
    ) {
        var interrupt = false
        transport.withQueueLock {
            let pending: PendingIO? = lock.withLock {
                guard let value = pendingPlayback.removeValue(forKey: requestID),
                      value.generation == streamGenerations[value.streamID] else { return nil }
                return value
            }
            guard let pending else { return }
            let status = Self.ioStatus(success ? .ok : .ioError, latencyBytes: latencyBytes)
            let written = pending.chain.writeBytes(status)
            interrupt = (try? transport.queues[2].push(pending.chain, written: written)) ?? false
        }
        if interrupt { transport.notifyUsed() }
    }

    private func completeCapture(
        requestID: UInt64,
        data: Data?,
        latencyBytes: UInt32,
        transport: VirtioMMIOTransport
    ) {
        var interrupt = false
        transport.withQueueLock {
            let pending: PendingIO? = lock.withLock {
                guard let value = pendingCapture.removeValue(forKey: requestID),
                      value.generation == streamGenerations[value.streamID] else { return nil }
                return value
            }
            guard let pending else { return }
            let validData = data.flatMap { $0.count == pending.payloadBytes ? $0 : nil }
            let payload = validData.map(Array.init) ?? []
            let payloadWritten = pending.chain.writeBytes(payload)
            let status = Self.ioStatus(
                validData == nil ? .ioError : .ok,
                latencyBytes: latencyBytes
            )
            let statusWritten = pending.chain.writeBytes(
                status,
                atWritableOffset: pending.payloadBytes
            )
            let usedLength = validData == nil ? statusWritten : payloadWritten + statusWritten
            interrupt = (try? transport.queues[3].push(pending.chain, written: usedLength)) ?? false
        }
        if interrupt { transport.notifyUsed() }
    }

    private func completeImmediately(
        _ chain: VirtqueueChain,
        queue: Virtqueue,
        status: Status,
        transport: VirtioMMIOTransport
    ) {
        let written = chain.writeBytes(Self.ioStatus(status, latencyBytes: 0))
        if (try? queue.push(chain, written: written)) == true { transport.notifyUsed() }
    }

    private func completeCaptureImmediately(
        _ chain: VirtqueueChain,
        payloadBytes: Int,
        queue: Virtqueue,
        status: Status,
        transport: VirtioMMIOTransport
    ) {
        let written = chain.writeBytes(
            Self.ioStatus(status, latencyBytes: 0),
            atWritableOffset: payloadBytes
        )
        if (try? queue.push(chain, written: written)) == true { transport.notifyUsed() }
    }

    private func processControlRequest(
        _ request: [UInt8],
        responseCapacity: Int,
        transport: VirtioMMIOTransport?
    ) -> [UInt8] {
        guard request.count >= 4 else { return Self.header(.badMessage) }
        let code = request.leUInt32(at: 0)
        switch code {
        case Request.pcmInfo:
            return pcmInfoResponse(request, responseCapacity: responseCapacity)
        case Request.pcmSetParameters:
            return setParametersResponse(request)
        case Request.pcmPrepare, Request.pcmRelease, Request.pcmStart, Request.pcmStop:
            guard request.count >= 8 else { return Self.header(.badMessage) }
            let streamID = Int(request.leUInt32(at: 4))
            return lifecycleResponse(code: code, streamID: streamID, transport: transport)
        default:
            return Self.header(.notSupported)
        }
    }

    private func pcmInfoResponse(_ request: [UInt8], responseCapacity: Int) -> [UInt8] {
        guard request.count >= 16 else { return Self.header(.badMessage) }
        let start = Int(request.leUInt32(at: 4))
        let count = Int(request.leUInt32(at: 8))
        let itemSize = Int(request.leUInt32(at: 12))
        guard start >= 0, count > 0, start <= Self.streamCount,
              count <= Self.streamCount - start,
              itemSize >= Self.pcmInfoSize,
              responseCapacity >= 4 + count * itemSize else {
            return Self.header(.badMessage)
        }
        var response = Self.header(.ok)
        for streamID in start..<(start + count) {
            var item = [UInt8]()
            item.appendLE(UInt32(1))
            item.appendLE(UInt32(0))
            item.appendLE(Self.supportedFormats)
            item.appendLE(Self.supportedRates)
            item.append(streamID == 0 ? VirtioSoundDirection.output.rawValue : VirtioSoundDirection.input.rawValue)
            item.append(1)
            item.append(2)
            item.append(contentsOf: repeatElement(0, count: 5))
            item.append(contentsOf: repeatElement(0, count: itemSize - item.count))
            response.append(contentsOf: item)
        }
        return response
    }

    private func setParametersResponse(_ request: [UInt8]) -> [UInt8] {
        guard request.count >= 24 else { return Self.header(.badMessage) }
        let streamID = Int(request.leUInt32(at: 4))
        let bufferBytes = Int(request.leUInt32(at: 8))
        let periodBytes = Int(request.leUInt32(at: 12))
        let features = request.leUInt32(at: 16)
        let channels = Int(request[20])
        let format = request[21]
        let rate = request[22]
        guard streamID >= 0, streamID < streams.count,
              bufferBytes > 0, periodBytes > 0,
              bufferBytes % periodBytes == 0,
              features == 0,
              channels >= 1, channels <= 2,
              format == Self.s16Format,
              let sampleRate = Self.rateValues[rate] else {
            return Self.header(.notSupported)
        }
        let parameters = VirtioSoundPCMParameters(
            bufferBytes: bufferBytes,
            periodBytes: periodBytes,
            sampleRate: sampleRate,
            channels: channels
        )
        let direction = streams[streamID].direction
        guard host.configure(streamID: streamID, direction: direction, parameters: parameters) else {
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
        transport: VirtioMMIOTransport?
    ) -> [UInt8] {
        guard streamID >= 0, streamID < streams.count else { return Self.header(.badMessage) }
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
            host.release(streamID: streamID, direction: current.direction)
            if let transport { flushPending(streamID: streamID, transport: transport) }
            lock.withLock { streams[streamID].lifecycle = .parameters }
        default:
            return Self.header(.notSupported)
        }
        return Self.header(.ok)
    }

    private func flushPending(streamID: Int, transport: VirtioMMIOTransport) {
        let playback: [PendingIO]
        let capture: [PendingIO]
        lock.lock()
        streamGenerations[streamID] &+= 1
        playback = pendingPlayback.values.filter { $0.streamID == streamID }
        capture = pendingCapture.values.filter { $0.streamID == streamID }
        pendingPlayback = pendingPlayback.filter { $0.value.streamID != streamID }
        pendingCapture = pendingCapture.filter { $0.value.streamID != streamID }
        lock.unlock()

        if !playback.isEmpty || !capture.isEmpty {
            log("virtio sound stream \(streamID) released with playback=\(playback.count), capture=\(capture.count) pending")
        }

        var interrupt = false
        for pending in playback {
            let written = pending.chain.writeBytes(Self.ioStatus(.ioError, latencyBytes: 0))
            interrupt = ((try? transport.queues[2].push(pending.chain, written: written)) ?? false) || interrupt
        }
        for pending in capture {
            let written = pending.chain.writeBytes(
                Self.ioStatus(.ioError, latencyBytes: 0),
                atWritableOffset: pending.payloadBytes
            )
            interrupt = ((try? transport.queues[3].push(pending.chain, written: written)) ?? false) || interrupt
        }
        if interrupt { transport.notifyUsed() }
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
