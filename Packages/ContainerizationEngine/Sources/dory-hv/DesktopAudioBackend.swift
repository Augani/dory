@preconcurrency import AVFAudio
@preconcurrency import AVFoundation
import DoryHV
import Foundation

enum DoryMacAudioConfigurationRecoveryAction: Equatable {
    case none
    case restartOutput
    case rebuildInput
}

struct DoryMacAudioConfigurationRecoveryState: Equatable {
    var outputConfigured: Bool
    var outputRunning: Bool
    var inputConfigured: Bool
    var inputRunning: Bool

    func action(for direction: VirtioSoundDirection) -> DoryMacAudioConfigurationRecoveryAction {
        switch direction {
        case .output:
            outputConfigured && outputRunning ? .restartOutput : .none
        case .input:
            inputConfigured && inputRunning ? .rebuildInput : .none
        }
    }
}

struct DoryMacAudioQueueCapacity {
    static let maximumBufferBytes = 4 * 1_024 * 1_024
    static let maximumPeriodBytes = 1 * 1_024 * 1_024

    static func accepts(parameters: VirtioSoundPCMParameters) -> Bool {
        parameters.bufferBytes > 0
            && parameters.bufferBytes <= maximumBufferBytes
            && parameters.periodBytes > 0
            && parameters.periodBytes <= maximumPeriodBytes
            && parameters.periodBytes <= parameters.bufferBytes
            && parameters.bufferBytes % parameters.periodBytes == 0
    }

    static func accepts(currentBytes: Int, requestBytes: Int, capacityBytes: Int) -> Bool {
        currentBytes >= 0
            && requestBytes > 0
            && capacityBytes > 0
            && currentBytes <= capacityBytes
            && requestBytes <= capacityBytes - currentBytes
    }
}

enum DoryMacAudioPlaybackCompletionPolicy {
    // VirtIO PCM completion advances Linux's ALSA hardware pointer. A data-consumed callback only
    // means AVAudioPlayerNode removed the buffer from its scheduling queue, which can happen much
    // faster than real time and lets the guest overrun the audible timeline. dataRendered is paced
    // by the engine render timeline without depending on a physical device's played-back callback.
    static let callbackType: AVAudioPlayerNodeCompletionCallbackType = .dataRendered
}

struct DoryMacAudioRuntimeMetrics: Equatable, Sendable {
    var queuedPlaybackBytes: Int
    var pendingCaptureBytes: Int
    var bufferedCaptureBytes: Int
    var droppedPlaybackPeriods: UInt64
    var droppedCapturePeriods: UInt64
    var discardedCaptureBytes: UInt64
    var configurationChanges: Int
    var inputRunning: Bool
    var microphoneAccessDenied: Bool
}

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
        var generation: UUID
        var byteCount: Int
        var fallbackArmed: Bool
        var completion: @Sendable (Data?, UInt32) -> Void
    }

    private struct PlaybackRequest {
        var byteCount: Int
        var completion: @Sendable (Bool, UInt32) -> Void
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
    let outputEngine = AVAudioEngine()
    let inputEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let log: @Sendable (String) -> Void
    private let notificationCenter: NotificationCenter
    private let microphoneAuthorizationStatus: @Sendable () -> AVAuthorizationStatus
    private let microphoneAuthorizationPollingInterval: TimeInterval
    private let requestMicrophoneAccess: @Sendable (
        @escaping @Sendable (Bool) -> Void
    ) -> Void
    private var configurationObservers = [NSObjectProtocol]()

    private var outputParameters: VirtioSoundPCMParameters?
    private var inputParameters: VirtioSoundPCMParameters?
    private var outputRunning = false
    private var inputRunning = false
    private var inputTapInstalled = false
    private var microphoneAccessDenied = false
    private var permissionRequestInFlight = false
    private var permissionRequestID: UUID?
    // A PCM configuration/stop boundary owns a distinct generation. Tap callbacks and permission
    // responses from a retired stream cannot authorize or publish bytes into its successor.
    private var inputGeneration: UUID?
    private var inputTapGeneration: UUID?
    private var microphoneGrantObserved = false
    private var microphoneAuthorizationMonitor: DispatchSourceTimer?
    private var captureBytes = Data()
    private var captureRequests = [CaptureRequest]()
    private var pendingCaptureBytes = 0
    private var nextCaptureRequestID: UInt64 = 1
    private var captureTapCount = 0
    private var captureFallbackLogged = false
    private var nextCaptureFallbackUptime: TimeInterval = 0
    private var queuedPlaybackBytes = 0
    private var playbackRequests = [UInt64: PlaybackRequest]()
    private var nextPlaybackRequestID: UInt64 = 1
    private var observedConfigurationChanges = 0
    private var droppedPlaybackPeriods: UInt64 = 0
    private var droppedCapturePeriods: UInt64 = 0
    private var discardedCaptureBytes: UInt64 = 0

    init(
        log: @escaping @Sendable (String) -> Void,
        notificationCenter: NotificationCenter = .default,
        microphoneAuthorizationStatus: @escaping @Sendable () -> AVAuthorizationStatus = {
            AVCaptureDevice.authorizationStatus(for: .audio)
        },
        microphoneAuthorizationPollingInterval: TimeInterval = 0.1,
        requestMicrophoneAccess: @escaping @Sendable (
            @escaping @Sendable (Bool) -> Void
        ) -> Void = { completion in
            AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
        }
    ) {
        precondition(microphoneAuthorizationPollingInterval.isFinite
            && microphoneAuthorizationPollingInterval > 0
            && microphoneAuthorizationPollingInterval <= 1)
        self.log = log
        self.notificationCenter = notificationCenter
        self.microphoneAuthorizationStatus = microphoneAuthorizationStatus
        self.microphoneAuthorizationPollingInterval = microphoneAuthorizationPollingInterval
        self.requestMicrophoneAccess = requestMicrophoneAccess
        outputEngine.attach(player)
        configurationObservers = [
            notificationCenter.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: outputEngine,
                queue: nil
            ) { [weak self] _ in
                self?.scheduleConfigurationRecovery(for: .output)
            },
            notificationCenter.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: inputEngine,
                queue: nil
            ) { [weak self] _ in
                self?.scheduleConfigurationRecovery(for: .input)
            },
        ]
    }

    deinit {
        microphoneAuthorizationMonitor?.cancel()
        removeInputTap()
        inputEngine.stop()
        player.stop()
        outputEngine.stop()
        // No other call can own the backend once deinit begins. Settle prepared descriptors too;
        // their callbacks must not depend on a tap or permission response that will never arrive.
        failCaptureRequests()
        failPlaybackRequests()
        for observer in configurationObservers {
            notificationCenter.removeObserver(observer)
        }
    }

    var configurationChangeCount: Int { queue.sync { observedConfigurationChanges } }

    var runtimeMetrics: DoryMacAudioRuntimeMetrics {
        queue.sync {
            DoryMacAudioRuntimeMetrics(
                queuedPlaybackBytes: queuedPlaybackBytes,
                pendingCaptureBytes: pendingCaptureBytes,
                bufferedCaptureBytes: captureBytes.count,
                droppedPlaybackPeriods: droppedPlaybackPeriods,
                droppedCapturePeriods: droppedCapturePeriods,
                discardedCaptureBytes: discardedCaptureBytes,
                configurationChanges: observedConfigurationChanges,
                inputRunning: inputRunning,
                microphoneAccessDenied: microphoneAccessDenied
            )
        }
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
                failPlaybackRequests()
                outputEngine.disconnectNodeOutput(player)
                guard let format = Self.floatFormat(parameters) else { return false }
                outputEngine.connect(player, to: outputEngine.mainMixerNode, format: format)
                outputParameters = parameters
                outputRunning = false
            case .input:
                invalidateInputGeneration()
                removeInputTap()
                inputEngine.stop()
                failCaptureRequests()
                captureBytes.removeAll(keepingCapacity: true)
                captureTapCount = 0
                captureFallbackLogged = false
                nextCaptureFallbackUptime = 0
                microphoneAccessDenied = false
                inputParameters = parameters
                inputGeneration = UUID()
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
                if inputGeneration == nil { inputGeneration = UUID() }
                inputRunning = true
                guard startInputWhenAuthorized() else {
                    inputRunning = false
                    invalidateInputGeneration()
                    removeInputTap()
                    inputEngine.stop()
                    captureBytes.removeAll(keepingCapacity: false)
                    failCaptureRequests()
                    return false
                }
                satisfyCaptureRequests()
                armCaptureFallbacks()
                monitorMicrophoneAuthorization()
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
                invalidateInputGeneration()
                // PCM_STOP is not a new host permission grant. Keep an observed denial visible
                // until authorization really changes or the guest releases/reconfigures input.
                if microphoneAccessDenied {
                    microphoneAccessDenied = microphoneAuthorizationStatus() != .authorized
                }
                removeInputTap()
                inputEngine.stop()
                captureBytes.removeAll(keepingCapacity: false)
                failCaptureRequests()
                // ALSA may prime fresh descriptors while stopped, before its next PCM_START.
                inputGeneration = UUID()
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
                failPlaybackRequests()
                outputParameters = nil
            case .input:
                inputRunning = false
                invalidateInputGeneration()
                microphoneAccessDenied = false
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
            guard outputParameters == parameters else {
                return false
            }
            guard DoryMacAudioQueueCapacity.accepts(
                currentBytes: queuedPlaybackBytes,
                requestBytes: data.count,
                capacityBytes: parameters.bufferBytes
            ) else {
                droppedPlaybackPeriods &+= 1
                return false
            }
            guard let buffer = Self.playbackBuffer(data: data, parameters: parameters) else {
                return false
            }
            if outputRunning, !startOutputEngine() { return false }
            let requestID = nextPlaybackRequestID
            nextPlaybackRequestID &+= 1
            playbackRequests[requestID] = PlaybackRequest(
                byteCount: data.count,
                completion: completion
            )
            queuedPlaybackBytes += data.count
            // Completing the VirtIO descriptor advances Linux's ALSA hardware pointer, so this
            // acknowledgement must be paced by Core Audio's render timeline. `.dataConsumed`
            // merely drains the scheduling queue and can make the guest run PCM millions of
            // periods ahead of real time. `.dataPlayedBack` depends on a physical-device callback
            // that some application-owned engines do not publish. `.dataRendered` provides the
            // correct bounded contract between those two stages.
            player.scheduleBuffer(
                buffer,
                completionCallbackType: DoryMacAudioPlaybackCompletionPolicy.callbackType
            ) {
                [weak self] _ in
                guard let self else { return }
                self.queue.async {
                    self.completePlayback(requestID: requestID, success: true)
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
            guard byteCount > 0,
                  inputParameters == parameters,
                  !microphoneAccessDenied else { return false }
            if inputRunning, !validateLiveMicrophoneAuthorization() { return false }
            guard let generation = inputGeneration else { return false }
            guard DoryMacAudioQueueCapacity.accepts(
                currentBytes: pendingCaptureBytes,
                requestBytes: byteCount,
                capacityBytes: parameters.bufferBytes
            ) else {
                droppedCapturePeriods &+= 1
                return false
            }
            let requestID = nextCaptureRequestID
            nextCaptureRequestID &+= 1
            pendingCaptureBytes += byteCount
            captureRequests.append(CaptureRequest(
                id: requestID,
                generation: generation,
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
            invalidateInputGeneration()
            removeInputTap()
            outputEngine.stop()
            inputEngine.stop()
            outputParameters = nil
            inputParameters = nil
            outputRunning = false
            inputRunning = false
            microphoneAccessDenied = false
            failPlaybackRequests()
            captureBytes.removeAll(keepingCapacity: false)
            nextCaptureFallbackUptime = 0
            failCaptureRequests()
        }
    }

    private func startInputWhenAuthorized() -> Bool {
        switch microphoneAuthorizationStatus() {
        case .authorized:
            microphoneAccessDenied = false
            microphoneGrantObserved = true
            return installInputTapAndStartEngine()
        case .notDetermined:
            microphoneAccessDenied = false
            guard !permissionRequestInFlight else { return true }
            guard let generation = inputGeneration else { return false }
            let requestID = UUID()
            permissionRequestInFlight = true
            permissionRequestID = requestID
            log("requesting Mac microphone access; Linux capture will provide paced silence until permission is resolved")
            requestMicrophoneAccess { [weak self] granted in
                guard let self else { return }
                self.queue.async {
                    guard self.permissionRequestID == requestID else { return }
                    self.permissionRequestInFlight = false
                    self.permissionRequestID = nil
                    guard self.inputGeneration == generation else { return }
                    guard self.inputRunning else { return }
                    // A callback is not a lasting grant: permission can change while the reply
                    // waits for this queue, including a denial from an earlier macOS prompt.
                    guard granted, self.microphoneAuthorizationStatus() == .authorized else {
                        self.revokeMicrophoneAuthorization()
                        return
                    }
                    self.microphoneGrantObserved = true
                    if self.installInputTapAndStartEngine() { return }
                    self.log("microphone access is unavailable; Linux capture will continue with paced silence")
                    self.armCaptureFallbacks()
                }
            }
            return true
        case .denied, .restricted:
            revokeMicrophoneAuthorization()
            return false
        @unknown default:
            revokeMicrophoneAuthorization()
            return false
        }
    }

    private func invalidateInputGeneration() {
        inputGeneration = nil
        inputTapGeneration = nil
        microphoneGrantObserved = false
        // Keep one physical macOS prompt in flight across PCM reconfiguration. Retiring the
        // caller does not cancel AVCaptureDevice's request; repeated guest starts must not pile
        // up permission callbacks. Its stale result only frees this bounded request slot.
        microphoneAuthorizationMonitor?.cancel()
        microphoneAuthorizationMonitor = nil
    }

    private func monitorMicrophoneAuthorization() {
        guard inputRunning, microphoneAuthorizationMonitor == nil else { return }
        let monitor = DispatchSource.makeTimerSource(queue: queue)
        monitor.setEventHandler { [weak self] in
            guard let self, self.inputRunning else { return }
            _ = self.validateLiveMicrophoneAuthorization()
        }
        monitor.schedule(
            deadline: .now() + microphoneAuthorizationPollingInterval,
            repeating: microphoneAuthorizationPollingInterval,
            leeway: .milliseconds(5)
        )
        monitor.resume()
        microphoneAuthorizationMonitor = monitor
    }

    /// Check the live grant even when the guest stops posting capture descriptors, rather than
    /// depending on another engine-configuration callback. Recheck publication edges as well.
    @discardableResult
    private func validateLiveMicrophoneAuthorization() -> Bool {
        switch microphoneAuthorizationStatus() {
        case .authorized:
            if !microphoneGrantObserved, !permissionRequestInFlight {
                microphoneGrantObserved = true
                _ = installInputTapAndStartEngine()
            }
            return true
        case .notDetermined where !microphoneGrantObserved:
            // A stale response may have freed the one host prompt slot. Reacquire from this
            // generation's current authorization state, never from that retired response.
            return permissionRequestInFlight || startInputWhenAuthorized()
        default:
            revokeMicrophoneAuthorization()
            return false
        }
    }

    private func revokeMicrophoneAuthorization() {
        inputRunning = false
        microphoneAccessDenied = true
        invalidateInputGeneration()
        removeInputTap()
        inputEngine.stop()
        captureBytes.removeAll(keepingCapacity: false)
        nextCaptureFallbackUptime = 0
        failCaptureRequests()
        log("microphone access is unavailable or revoked; Linux capture was stopped and queued audio discarded")
    }

    private func scheduleConfigurationRecovery(for direction: VirtioSoundDirection) {
        queue.async { [weak self] in
            guard let self else { return }
            observedConfigurationChanges += 1
            let state = DoryMacAudioConfigurationRecoveryState(
                outputConfigured: outputParameters != nil,
                outputRunning: outputRunning,
                inputConfigured: inputParameters != nil,
                inputRunning: inputRunning
            )
            switch state.action(for: direction) {
            case .none:
                return
            case .restartOutput:
                player.stop()
                outputEngine.stop()
                failPlaybackRequests()
                if startOutputEngine() {
                    log("Mac audio output recovered after the host device configuration changed")
                } else {
                    log("Mac audio output is waiting for a usable host device after configuration changed")
                }
            case .rebuildInput:
                invalidateInputGeneration()
                removeInputTap()
                inputEngine.stop()
                failCaptureRequests()
                captureBytes.removeAll(keepingCapacity: true)
                captureTapCount = 0
                captureFallbackLogged = false
                nextCaptureFallbackUptime = 0
                inputGeneration = UUID()
                if startInputWhenAuthorized() {
                    log("Mac audio input recovered after the host device configuration changed")
                } else {
                    log("Mac audio input is unavailable after the host device configuration changed")
                }
                satisfyCaptureRequests()
                if inputRunning {
                    armCaptureFallbacks()
                    monitorMicrophoneAuthorization()
                } else {
                    failCaptureRequests()
                }
            }
        }
    }

    private func installInputTapAndStartEngine() -> Bool {
        guard inputRunning, let generation = inputGeneration,
              let parameters = inputParameters,
              microphoneAuthorizationStatus() == .authorized else { return false }
        if !inputTapInstalled {
            let tapGeneration = UUID()
            inputTapGeneration = tapGeneration
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
                    guard let self, self.inputRunning,
                          self.inputGeneration == generation,
                          self.inputTapGeneration == tapGeneration,
                          self.validateLiveMicrophoneAuthorization() else { return }
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
        inputTapGeneration = nil
        guard inputTapInstalled else { return }
        inputEngine.inputNode.removeTap(onBus: 0)
        inputTapInstalled = false
    }

    private func appendCapture(_ data: Data) {
        captureBytes.append(data)
        // Keep only the newest negotiated buffer when PipeWire temporarily stops submitting
        // receive descriptors. Old microphone frames are less useful than current audio after a
        // stall, and the guest-controlled PCM contract must remain a hard memory bound.
        let capacity = max(0, inputParameters?.bufferBytes ?? 0)
        if captureBytes.count > capacity {
            let discarded = captureBytes.count - capacity
            discardedCaptureBytes &+= UInt64(discarded)
            captureBytes.removeFirst(discarded)
        }
        satisfyCaptureRequests()
    }

    private func satisfyCaptureRequests() {
        guard !inputRunning || validateLiveMicrophoneAuthorization() else { return }
        while let request = captureRequests.first, captureBytes.count >= request.byteCount {
            captureRequests.removeFirst()
            pendingCaptureBytes = max(0, pendingCaptureBytes - request.byteCount)
            let data = Data(captureBytes.prefix(request.byteCount))
            captureBytes.removeFirst(request.byteCount)
            let latency = UInt32(clamping: captureBytes.count)
            deliverCapture(request, data: data, latency: latency)
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
                  self.inputRunning,
                  self.validateLiveMicrophoneAuthorization(),
                  let pendingIndex = self.captureRequests.firstIndex(where: { $0.id == requestID }) else {
                return
            }
            let request = self.captureRequests.remove(at: pendingIndex)
            self.pendingCaptureBytes = max(0, self.pendingCaptureBytes - request.byteCount)
            if !self.captureFallbackLogged {
                self.captureFallbackLogged = true
                self.log("Mac microphone frames are pending; Linux capture is using paced silence")
            }
            if self.captureRequests.isEmpty { self.nextCaptureFallbackUptime = 0 }
            self.deliverCapture(request, data: Data(count: request.byteCount), latency: 0)
        }
    }

    private func deliverCapture(_ request: CaptureRequest, data: Data, latency: UInt32) {
        Self.deliver { [weak self] in
            guard let self else { request.completion(nil, 0); return }
            let admitted = self.queue.sync {
                self.inputGeneration == request.generation
                    && !self.microphoneAccessDenied
                    && (!self.inputRunning || self.validateLiveMicrophoneAuthorization())
            }
            request.completion(admitted ? data : nil, admitted ? latency : 0)
        }
    }

    private func failCaptureRequests() {
        let requests = captureRequests
        captureRequests.removeAll(keepingCapacity: false)
        pendingCaptureBytes = 0
        droppedCapturePeriods &+= UInt64(requests.count)
        for request in requests { Self.deliver { request.completion(nil, 0) } }
    }

    private func completePlayback(requestID: UInt64, success: Bool) {
        guard let request = playbackRequests.removeValue(forKey: requestID) else { return }
        queuedPlaybackBytes = max(0, queuedPlaybackBytes - request.byteCount)
        let latency = UInt32(clamping: queuedPlaybackBytes)
        Self.deliver { request.completion(success, latency) }
    }

    private func failPlaybackRequests() {
        let requestIDs = playbackRequests.keys.sorted()
        droppedPlaybackPeriods &+= UInt64(requestIDs.count)
        for requestID in requestIDs {
            completePlayback(requestID: requestID, success: false)
        }
        queuedPlaybackBytes = 0
    }

    private static func valid(_ parameters: VirtioSoundPCMParameters) -> Bool {
        parameters.bytesPerSample == 2
            && (parameters.channels == 1 || parameters.channels == 2)
            && (parameters.sampleRate == 44_100 || parameters.sampleRate == 48_000
                || parameters.sampleRate == 96_000)
            && DoryMacAudioQueueCapacity.accepts(parameters: parameters)
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
