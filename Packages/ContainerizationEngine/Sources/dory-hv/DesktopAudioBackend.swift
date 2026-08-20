@preconcurrency import AVFAudio
@preconcurrency import AVFoundation
import DoryHV
import Foundation

/// Bridges the raw Hypervisor.framework virtio-snd device to Core Audio. Guest PCM remains the
/// standard signed 16-bit interleaved format while AVAudioEngine performs host sample-rate and
/// device conversion.
final class DoryMacAudioBackend: VirtioSoundHost, @unchecked Sendable {
    private static let deliveryQueue = DispatchQueue(
        label: "com.dory.desktop.audio.completion",
        qos: .userInteractive
    )

    private struct CaptureRequest {
        var id: UInt64
        var byteCount: Int
        var fallbackArmed: Bool
        var completion: @Sendable (Data?, UInt32) -> Void
    }

    private final class ConverterInput: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        var served = false

        init(buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }
    }

    private let queue = DispatchQueue(label: "com.dory.desktop.audio", qos: .userInteractive)
    // Keep playback and capture on independent graphs. PipeWire may prepare and start them in
    // either order; mutating a shared running graph to add the other direction can leave an
    // AVAudioPlayerNode permanently scheduled but never rendered.
    private let outputEngine = AVAudioEngine()
    private let inputEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let log: @Sendable (String) -> Void

    private var outputParameters: VirtioSoundPCMParameters?
    private var inputParameters: VirtioSoundPCMParameters?
    private var outputRunning = false
    private var inputRunning = false
    private var inputTapInstalled = false
    private var permissionRequestInFlight = false
    private var captureBytes = Data()
    private var captureRequests = [CaptureRequest]()
    private var nextCaptureRequestID: UInt64 = 1
    private var captureTapCount = 0
    private var captureFallbackLogged = false
    private var nextCaptureFallbackUptime: TimeInterval = 0
    private var queuedPlaybackBytes = 0

    init(log: @escaping @Sendable (String) -> Void) {
        self.log = log
        outputEngine.attach(player)
    }

    func configure(
        streamID: Int,
        direction: VirtioSoundDirection,
        parameters: VirtioSoundPCMParameters
    ) -> Bool {
        guard Self.valid(parameters) else { return false }
        return queue.sync {
            switch direction {
            case .output:
                player.stop()
                queuedPlaybackBytes = 0
                outputEngine.disconnectNodeOutput(player)
                guard let format = Self.floatFormat(parameters) else { return false }
                outputEngine.connect(player, to: outputEngine.mainMixerNode, format: format)
                outputParameters = parameters
                outputRunning = false
            case .input:
                removeInputTap()
                failCaptureRequests()
                captureBytes.removeAll(keepingCapacity: true)
                captureTapCount = 0
                captureFallbackLogged = false
                nextCaptureFallbackUptime = 0
                inputParameters = parameters
                inputRunning = false
            }
            return true
        }
    }

    func prepare(streamID: Int, direction: VirtioSoundDirection) -> Bool {
        queue.sync {
            switch direction {
            case .output: guard outputParameters != nil else { return false }
            case .input: guard inputParameters != nil else { return false }
            }
            switch direction {
            case .output:
                if !outputEngine.isRunning { outputEngine.prepare() }
            case .input:
                // An input-only AVAudioEngine has no graph until its tap is installed. Preparing
                // it here raises an Objective-C exception; installInputTapAndStartEngine() owns
                // input graph preparation once macOS microphone access is available.
                break
            }
            return true
        }
    }

    func start(streamID: Int, direction: VirtioSoundDirection) -> Bool {
        queue.sync {
            switch direction {
            case .output:
                outputRunning = true
                guard outputParameters != nil, startOutputEngine() else {
                    outputRunning = false
                    return false
                }
                player.play()
                return true
            case .input:
                guard inputParameters != nil else { return false }
                inputRunning = true
                guard startInputWhenAuthorized() else { return false }
                satisfyCaptureRequests()
                armCaptureFallbacks()
                return true
            }
        }
    }

    func stop(streamID: Int, direction: VirtioSoundDirection) -> Bool {
        queue.sync {
            switch direction {
            case .output:
                player.pause()
                outputRunning = false
            case .input:
                inputRunning = false
                removeInputTap()
                inputEngine.stop()
                nextCaptureFallbackUptime = 0
            }
            return true
        }
    }

    func release(streamID: Int, direction: VirtioSoundDirection) {
        queue.sync {
            switch direction {
            case .output:
                player.stop()
                outputEngine.stop()
                outputRunning = false
                queuedPlaybackBytes = 0
                outputParameters = nil
            case .input:
                inputRunning = false
                removeInputTap()
                inputEngine.stop()
                inputParameters = nil
                captureBytes.removeAll(keepingCapacity: false)
                nextCaptureFallbackUptime = 0
                failCaptureRequests()
            }
        }
    }

    func enqueuePlayback(
        _ data: Data,
        parameters: VirtioSoundPCMParameters,
        completion: @escaping @Sendable (Bool, UInt32) -> Void
    ) -> Bool {
        queue.sync {
            guard outputParameters == parameters,
                  let buffer = Self.playbackBuffer(data: data, parameters: parameters) else {
                return false
            }
            queuedPlaybackBytes += data.count
            // The virtio descriptor protects the guest-owned period, not the audible speaker
            // timeline. We have already copied that period into an AVAudioPCMBuffer, so complete
            // it when Core Audio consumes the buffer. Waiting for `.dataPlayedBack` couples the
            // Linux PCM ring to the host device's presentation callback and can deadlock ALSA on
            // devices that do not publish that callback for an application-owned engine.
            player.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) {
                [weak self] _ in
                guard let self else { return }
                self.queue.async {
                    self.queuedPlaybackBytes = max(0, self.queuedPlaybackBytes - data.count)
                    let latency = UInt32(clamping: self.queuedPlaybackBytes)
                    Self.deliver { completion(true, latency) }
                }
            }
            // AVAudioPlayerNode stops after an empty queue. Linux commonly starts the PCM stream
            // before submitting the first period, so the play() issued by start() may have already
            // gone idle by the time this buffer arrives. Rearm it for every transition from an
            // empty/stopped player to queued audio, otherwise virtio TX descriptors never complete.
            if outputRunning { player.play() }
            return true
        }
    }

    func requestCapture(
        byteCount: Int,
        parameters: VirtioSoundPCMParameters,
        completion: @escaping @Sendable (Data?, UInt32) -> Void
    ) -> Bool {
        queue.sync {
            // Linux primes capture descriptors while the PCM is prepared, before PCM_START. Keep
            // those requests pending just as playback keeps its pre-roll buffers scheduled.
            guard byteCount > 0, inputParameters == parameters else { return false }
            let requestID = nextCaptureRequestID
            nextCaptureRequestID &+= 1
            captureRequests.append(CaptureRequest(
                id: requestID,
                byteCount: byteCount,
                fallbackArmed: false,
                completion: completion
            ))
            satisfyCaptureRequests()
            if inputRunning { armCaptureFallback(requestID: requestID) }
            return true
        }
    }

    func reset() {
        queue.sync {
            player.stop()
            removeInputTap()
            outputEngine.stop()
            inputEngine.stop()
            outputParameters = nil
            inputParameters = nil
            outputRunning = false
            inputRunning = false
            queuedPlaybackBytes = 0
            captureBytes.removeAll(keepingCapacity: false)
            nextCaptureFallbackUptime = 0
            failCaptureRequests()
        }
    }

    private func startInputWhenAuthorized() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return installInputTapAndStartEngine()
        case .notDetermined:
            guard !permissionRequestInFlight else { return true }
            permissionRequestInFlight = true
            log("requesting Mac microphone access; Linux capture will provide paced silence until permission is resolved")
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                guard let self else { return }
                self.queue.async {
                    self.permissionRequestInFlight = false
                    guard self.inputRunning else { return }
                    if granted, self.installInputTapAndStartEngine() { return }
                    self.log("microphone access is unavailable; Linux capture will continue with paced silence")
                    self.armCaptureFallbacks()
                }
            }
            return true
        case .denied, .restricted:
            log("microphone access is denied; enable it for Dory in System Settings > Privacy & Security > Microphone")
            inputRunning = false
            return false
        @unknown default:
            inputRunning = false
            return false
        }
    }

    private func installInputTapAndStartEngine() -> Bool {
        guard inputRunning, let parameters = inputParameters else { return false }
        if !inputTapInstalled {
            let input = inputEngine.inputNode
            let nativeFormat = input.outputFormat(forBus: 0)
            guard nativeFormat.channelCount > 0,
                  nativeFormat.sampleRate > 0,
                  let targetFormat = Self.floatFormat(parameters),
                  let converter = AVAudioConverter(from: nativeFormat, to: targetFormat) else {
                log("the selected Mac input device does not expose a usable audio format")
                return false
            }
            input.installTap(onBus: 0, bufferSize: 1_024, format: nativeFormat) {
                [weak self] buffer, _ in
                let data = Self.convertCapture(
                    buffer: buffer,
                    converter: converter,
                    targetFormat: targetFormat,
                    parameters: parameters
                )
                let inputFrames = buffer.frameLength
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    self.captureTapCount += 1
                    if self.captureTapCount == 1 {
                        self.log("Mac microphone stream active (inputFrames=\(inputFrames), convertedBytes=\(data?.count ?? 0))")
                    }
                    if let data, !data.isEmpty { self.appendCapture(data) }
                }
            }
            inputTapInstalled = true
        }
        return startInputEngine()
    }

    private func startOutputEngine() -> Bool {
        if outputEngine.isRunning {
            if outputRunning, !player.isPlaying { player.play() }
            return true
        }
        do {
            outputEngine.prepare()
            try outputEngine.start()
            if outputRunning, !player.isPlaying { player.play() }
            return true
        } catch {
            log("could not start Mac audio output: \(error)")
            return false
        }
    }

    private func startInputEngine() -> Bool {
        if inputEngine.isRunning { return true }
        do {
            inputEngine.prepare()
            try inputEngine.start()
            return true
        } catch {
            log("could not start Mac audio input: \(error)")
            return false
        }
    }

    private func removeInputTap() {
        guard inputTapInstalled else { return }
        inputEngine.inputNode.removeTap(onBus: 0)
        inputTapInstalled = false
    }

    private func appendCapture(_ data: Data) {
        captureBytes.append(data)
        // Bound stale input if PipeWire temporarily stops submitting receive buffers.
        if captureBytes.count > 4 * 1_024 * 1_024 {
            captureBytes.removeFirst(captureBytes.count - 4 * 1_024 * 1_024)
        }
        satisfyCaptureRequests()
    }

    private func satisfyCaptureRequests() {
        while let request = captureRequests.first, captureBytes.count >= request.byteCount {
            captureRequests.removeFirst()
            let data = Data(captureBytes.prefix(request.byteCount))
            captureBytes.removeFirst(request.byteCount)
            let latency = UInt32(clamping: captureBytes.count)
            Self.deliver { request.completion(data, latency) }
        }
        if captureRequests.isEmpty { nextCaptureFallbackUptime = 0 }
    }

    private func armCaptureFallbacks() {
        for requestID in captureRequests.lazy.filter({ !$0.fallbackArmed }).map(\.id) {
            armCaptureFallback(requestID: requestID)
        }
    }

    private func armCaptureFallback(requestID: UInt64) {
        guard inputRunning,
              let parameters = inputParameters,
              let index = captureRequests.firstIndex(where: { $0.id == requestID }),
              !captureRequests[index].fallbackArmed else { return }
        captureRequests[index].fallbackArmed = true
        let byteCount = captureRequests[index].byteCount
        let frames = byteCount / parameters.bytesPerFrame
        let period = Double(frames) / parameters.sampleRate
        // During a permission prompt, pace from the first period. Once the real input graph is
        // active, allow two periods (at least 100 ms) before treating a missed callback as silence.
        let now = ProcessInfo.processInfo.systemUptime
        let firstDelay = inputTapInstalled ? max(0.1, 2 * period) : period
        let deadline: TimeInterval
        if nextCaptureFallbackUptime > now {
            deadline = nextCaptureFallbackUptime + period
        } else {
            deadline = now + firstDelay
        }
        nextCaptureFallbackUptime = deadline
        queue.asyncAfter(deadline: .now() + max(0, deadline - now)) { [weak self] in
            guard let self,
                  let pendingIndex = self.captureRequests.firstIndex(where: { $0.id == requestID }) else {
                return
            }
            let request = self.captureRequests.remove(at: pendingIndex)
            if !self.captureFallbackLogged {
                self.captureFallbackLogged = true
                self.log("Mac microphone frames are pending; Linux capture is using paced silence")
            }
            if self.captureRequests.isEmpty { self.nextCaptureFallbackUptime = 0 }
            Self.deliver { request.completion(Data(count: request.byteCount), 0) }
        }
    }

    private func failCaptureRequests() {
        let requests = captureRequests
        captureRequests.removeAll(keepingCapacity: false)
        for request in requests { Self.deliver { request.completion(nil, 0) } }
    }

    private static func valid(_ parameters: VirtioSoundPCMParameters) -> Bool {
        parameters.bytesPerSample == 2
            && (parameters.channels == 1 || parameters.channels == 2)
            && (parameters.sampleRate == 44_100 || parameters.sampleRate == 48_000)
            && parameters.bufferBytes > 0
            && parameters.periodBytes > 0
            && parameters.periodBytes <= parameters.bufferBytes
            && parameters.periodBytes % parameters.bytesPerFrame == 0
    }

    private static func floatFormat(_ parameters: VirtioSoundPCMParameters) -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: parameters.sampleRate,
            channels: AVAudioChannelCount(parameters.channels),
            interleaved: false
        )
    }

    private static func playbackBuffer(
        data: Data,
        parameters: VirtioSoundPCMParameters
    ) -> AVAudioPCMBuffer? {
        guard !data.isEmpty,
              data.count % parameters.bytesPerFrame == 0,
              let format = floatFormat(parameters) else { return nil }
        let frames = data.count / parameters.bytesPerFrame
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frames)
        ), let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for frame in 0..<frames {
                for channel in 0..<parameters.channels {
                    let offset = (frame * parameters.channels + channel) * 2
                    let sample = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
                    channels[channel][frame] = Float(Int16(bitPattern: sample)) / 32_768
                }
            }
        }
        return buffer
    }

    private static func convertCapture(
        buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat,
        parameters: VirtioSoundPCMParameters
    ) -> Data? {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(max(1, Int(ceil(Double(buffer.frameLength) * ratio)) + 32))
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }
        let input = ConverterInput(buffer: buffer)
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
            if input.served {
                outStatus.pointee = .noDataNow
                return nil
            }
            input.served = true
            outStatus.pointee = .haveData
            return input.buffer
        }
        guard conversionError == nil,
              status != .error,
              converted.frameLength > 0,
              let channels = converted.floatChannelData else { return nil }

        var bytes = Data(count: Int(converted.frameLength) * parameters.bytesPerFrame)
        bytes.withUnsafeMutableBytes { raw in
            guard let output = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for frame in 0..<Int(converted.frameLength) {
                for channel in 0..<parameters.channels {
                    let scaled = max(-1, min(1, channels[channel][frame]))
                    let integer = Int16(clamping: Int((scaled * 32_767).rounded()))
                    let sample = UInt16(bitPattern: integer)
                    let offset = (frame * parameters.channels + channel) * 2
                    output[offset] = UInt8(truncatingIfNeeded: sample)
                    output[offset + 1] = UInt8(truncatingIfNeeded: sample >> 8)
                }
            }
        }
        return bytes
    }

    private static func deliver(_ operation: @escaping @Sendable () -> Void) {
        deliveryQueue.async(execute: operation)
    }
}
