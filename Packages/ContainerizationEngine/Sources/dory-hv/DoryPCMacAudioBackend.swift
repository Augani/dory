import DoryHV
import DoryVirtio
import Foundation

enum DoryPCMacAudioError: Error, Equatable {
    case unsupportedFormat
    case streamNotConfigured(UInt32)
    case hostRejected(String)
    case hostTimedOut(String)
}

/// Adapts DoryPC's transport-neutral synchronous PCM contract to the proven Core Audio backend.
/// Waiting for render/capture completion deliberately paces the translated guest's VirtIO queue
/// to the physical audio timeline instead of allowing it to run unbounded ahead of the Mac.
final class DoryPCMacAudioBackend: DoryVirtioSoundBackend, @unchecked Sendable {
    private struct Stream {
        let direction: VirtioSoundDirection
        let parameters: VirtioSoundPCMParameters
    }

    private let lock = NSLock()
    private let host: any VirtioSoundHost
    private let completionTimeout: DispatchTimeInterval
    private var streams = [UInt32: Stream]()

    init(
        log: @escaping @Sendable (String) -> Void,
        completionTimeout: DispatchTimeInterval = .seconds(30),
        host: (any VirtioSoundHost)? = nil
    ) {
        self.host = host ?? DoryMacAudioBackend(log: log)
        self.completionTimeout = completionTimeout
    }

    func configure(
        streamID: UInt32,
        direction: DoryVirtioSoundDirection,
        parameters: DoryVirtioSoundPCMParameters
    ) throws {
        guard parameters.format == .signed16 else {
            throw DoryPCMacAudioError.unsupportedFormat
        }
        let mappedDirection: VirtioSoundDirection = direction == .output ? .output : .input
        let mapped = VirtioSoundPCMParameters(
            bufferBytes: Int(parameters.bufferBytes),
            periodBytes: Int(parameters.periodBytes),
            sampleRate: Double(parameters.rate.hertz),
            channels: Int(parameters.channels),
            bytesPerSample: parameters.format.bytesPerSample
        )
        guard host.configure(
            streamID: Int(streamID),
            direction: mappedDirection,
            parameters: mapped
        ) else {
            throw DoryPCMacAudioError.hostRejected("configure")
        }
        lock.withLock {
            streams[streamID] = Stream(direction: mappedDirection, parameters: mapped)
        }
    }

    func prepare(streamID: UInt32) throws {
        let stream = try configured(streamID)
        guard host.prepare(streamID: Int(streamID), direction: stream.direction) else {
            throw DoryPCMacAudioError.hostRejected("prepare")
        }
    }

    func start(streamID: UInt32) throws {
        let stream = try configured(streamID)
        guard host.start(streamID: Int(streamID), direction: stream.direction) else {
            throw DoryPCMacAudioError.hostRejected("start")
        }
    }

    func stop(streamID: UInt32) throws {
        let stream = try configured(streamID)
        guard host.stop(streamID: Int(streamID), direction: stream.direction) else {
            throw DoryPCMacAudioError.hostRejected("stop")
        }
    }

    func release(streamID: UInt32) throws {
        let stream = try configured(streamID)
        host.release(streamID: Int(streamID), direction: stream.direction)
        _ = lock.withLock { streams.removeValue(forKey: streamID) }
    }

    func play(streamID: UInt32, pcmBytes: [UInt8]) throws {
        let stream = try configured(streamID)
        guard stream.direction == .output else {
            throw DoryPCMacAudioError.hostRejected("play-direction")
        }
        let completion = DispatchSemaphore(value: 0)
        let result = LockedBox<Bool?>(nil)
        guard host.enqueuePlayback(
            Data(pcmBytes),
            parameters: stream.parameters,
            completion: { success, _ in
                result.withLock { $0 = success }
                completion.signal()
            }
        ) else {
            throw DoryPCMacAudioError.hostRejected("play")
        }
        guard completion.wait(timeout: .now() + completionTimeout) == .success else {
            throw DoryPCMacAudioError.hostTimedOut("play")
        }
        guard result.withLock({ $0 }) == true else {
            throw DoryPCMacAudioError.hostRejected("play-completion")
        }
    }

    func capture(streamID: UInt32, byteCount: Int) throws -> [UInt8] {
        let stream = try configured(streamID)
        guard stream.direction == .input else {
            throw DoryPCMacAudioError.hostRejected("capture-direction")
        }
        let completion = DispatchSemaphore(value: 0)
        let result = LockedBox<Data?>(nil)
        guard host.requestCapture(
            byteCount: byteCount,
            parameters: stream.parameters,
            completion: { data, _ in
                result.withLock { $0 = data }
                completion.signal()
            }
        ) else {
            throw DoryPCMacAudioError.hostRejected("capture")
        }
        guard completion.wait(timeout: .now() + completionTimeout) == .success else {
            throw DoryPCMacAudioError.hostTimedOut("capture")
        }
        guard let data = result.withLock({ $0 }), data.count == byteCount else {
            throw DoryPCMacAudioError.hostRejected("capture-completion")
        }
        return Array(data)
    }

    func reset() {
        host.reset()
        lock.withLock { streams.removeAll(keepingCapacity: true) }
    }

    private func configured(_ streamID: UInt32) throws -> Stream {
        guard let stream = lock.withLock({ streams[streamID] }) else {
            throw DoryPCMacAudioError.streamNotConfigured(streamID)
        }
        return stream
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.withLock { body(&value) }
    }
}
