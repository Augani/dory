@preconcurrency import AVFAudio
@preconcurrency import AVFoundation
import DoryHV
import Foundation
import Testing
@testable import dory_hv

@Suite("Desktop audio configuration recovery")
struct DesktopAudioRecoveryTests {
    @Test("VirtIO completion advances only after Core Audio renders a period")
    func playbackCompletionUsesRenderedTimeline() {
        #expect(DoryMacAudioPlaybackCompletionPolicy.callbackType == .dataRendered)
        #expect(DoryMacAudioPlaybackCompletionPolicy.callbackType != .dataConsumed)
        #expect(DoryMacAudioPlaybackCompletionPolicy.callbackType != .dataPlayedBack)
    }

    @Test("negotiated PCM buffers are hard queue bounds")
    func queueCapacityIsBoundedWithoutOverflow() {
        #expect(DoryMacAudioQueueCapacity.accepts(parameters: VirtioSoundPCMParameters(
            bufferBytes: 16_384,
            periodBytes: 4_096,
            sampleRate: 48_000,
            channels: 2
        )))
        #expect(!DoryMacAudioQueueCapacity.accepts(parameters: VirtioSoundPCMParameters(
            bufferBytes: DoryMacAudioQueueCapacity.maximumBufferBytes + 1,
            periodBytes: 4_096,
            sampleRate: 48_000,
            channels: 2
        )))
        #expect(!DoryMacAudioQueueCapacity.accepts(parameters: VirtioSoundPCMParameters(
            bufferBytes: 16_384,
            periodBytes: 5_000,
            sampleRate: 48_000,
            channels: 2
        )))
        #expect(DoryMacAudioQueueCapacity.accepts(
            currentBytes: 0,
            requestBytes: 4_096,
            capacityBytes: 8_192
        ))
        #expect(DoryMacAudioQueueCapacity.accepts(
            currentBytes: 4_096,
            requestBytes: 4_096,
            capacityBytes: 8_192
        ))
        #expect(!DoryMacAudioQueueCapacity.accepts(
            currentBytes: 4_097,
            requestBytes: 4_096,
            capacityBytes: 8_192
        ))
        #expect(!DoryMacAudioQueueCapacity.accepts(
            currentBytes: Int.max,
            requestBytes: 1,
            capacityBytes: Int.max
        ))
        #expect(!DoryMacAudioQueueCapacity.accepts(
            currentBytes: 0,
            requestBytes: 0,
            capacityBytes: 8_192
        ))
    }

    @Test("backend rejects playback and capture beyond the negotiated buffer")
    func backendEnforcesNegotiatedQueueCapacity() {
        let backend = DoryMacAudioBackend(log: { _ in })
        let parameters = VirtioSoundPCMParameters(
            bufferBytes: 8,
            periodBytes: 4,
            sampleRate: 48_000,
            channels: 2
        )
        #expect(backend.configure(
            streamID: 0,
            direction: .output,
            parameters: parameters
        ))
        #expect(backend.enqueuePlayback(Data(count: 4), parameters: parameters) { _, _ in })
        #expect(backend.enqueuePlayback(Data(count: 4), parameters: parameters) { _, _ in })
        #expect(!backend.enqueuePlayback(Data(count: 4), parameters: parameters) { _, _ in })

        #expect(backend.configure(
            streamID: 1,
            direction: .input,
            parameters: parameters
        ))
        #expect(backend.requestCapture(byteCount: 4, parameters: parameters) { _, _ in })
        #expect(backend.requestCapture(byteCount: 4, parameters: parameters) { _, _ in })
        #expect(!backend.requestCapture(byteCount: 4, parameters: parameters) { _, _ in })

        let queued = backend.runtimeMetrics
        #expect(queued.queuedPlaybackBytes == 8)
        #expect(queued.pendingCaptureBytes == 8)
        #expect(queued.droppedPlaybackPeriods == 1)
        #expect(queued.droppedCapturePeriods == 1)

        backend.reset()
        let reset = backend.runtimeMetrics
        #expect(reset.queuedPlaybackBytes == 0)
        #expect(reset.pendingCaptureBytes == 0)
        #expect(reset.droppedPlaybackPeriods == 3)
        #expect(reset.droppedCapturePeriods == 3)
    }

    @Test("denied microphone permission fails primed capture descriptors")
    func deniedMicrophonePermissionFailsPendingCapture() {
        let completion = DispatchSemaphore(value: 0)
        let result = LockedCaptureCompletion()
        let backend = DoryMacAudioBackend(
            log: { _ in },
            microphoneAuthorizationStatus: { .denied },
            requestMicrophoneAccess: { _ in
                Issue.record("denied authorization must not request microphone access")
            }
        )
        let parameters = VirtioSoundPCMParameters(
            bufferBytes: 8,
            periodBytes: 4,
            sampleRate: 48_000,
            channels: 2
        )
        #expect(backend.configure(
            streamID: 1,
            direction: .input,
            parameters: parameters
        ))
        #expect(backend.requestCapture(byteCount: 4, parameters: parameters) { data, _ in
            result.record(data)
            completion.signal()
        })

        #expect(!backend.start(streamID: 1, direction: .input))
        #expect(completion.wait(timeout: .now() + 1) == .success)
        #expect(result.snapshot == (completed: true, dataWasNil: true))
        #expect(!backend.requestCapture(byteCount: 4, parameters: parameters) { _, _ in })
        #expect(backend.runtimeMetrics.pendingCaptureBytes == 0)
        #expect(backend.runtimeMetrics.droppedCapturePeriods == 1)
    }

    @Test("permission prompt denial latches capture unavailable")
    func asynchronousMicrophoneDenialRejectsLaterCapture() {
        let completion = DispatchSemaphore(value: 0)
        let result = LockedCaptureCompletion()
        let backend = DoryMacAudioBackend(
            log: { _ in },
            microphoneAuthorizationStatus: { .notDetermined },
            requestMicrophoneAccess: { callback in callback(false) }
        )
        let parameters = VirtioSoundPCMParameters(
            bufferBytes: 8,
            periodBytes: 4,
            sampleRate: 48_000,
            channels: 2
        )
        #expect(backend.configure(
            streamID: 1,
            direction: .input,
            parameters: parameters
        ))
        #expect(backend.requestCapture(byteCount: 4, parameters: parameters) { data, _ in
            result.record(data)
            completion.signal()
        })

        // The guest may enter PCM_RUNNING while macOS displays its asynchronous permission prompt.
        #expect(backend.start(streamID: 1, direction: .input))
        #expect(completion.wait(timeout: .now() + 1) == .success)
        #expect(result.snapshot == (completed: true, dataWasNil: true))
        #expect(!backend.requestCapture(byteCount: 4, parameters: parameters) { _, _ in })
        #expect(backend.runtimeMetrics.pendingCaptureBytes == 0)
        #expect(backend.runtimeMetrics.droppedCapturePeriods == 1)
    }

    @Test("PCM stop settles primed capture requests exactly once")
    func stoppedCaptureSettlesPendingRequests() {
        let completion = DispatchSemaphore(value: 0)
        let result = LockedCaptureCompletion()
        let backend = DoryMacAudioBackend(log: { _ in })
        let parameters = captureParameters()
        #expect(backend.configure(streamID: 1, direction: .input, parameters: parameters))
        #expect(backend.requestCapture(byteCount: 4, parameters: parameters) { data, _ in
            result.record(data)
            completion.signal()
        })
        #expect(backend.stop(streamID: 1, direction: .input))
        #expect(completion.wait(timeout: .now() + 1) == .success)
        #expect(result.snapshot == (completed: true, dataWasNil: true))
        #expect(backend.runtimeMetrics.pendingCaptureBytes == 0)
        #expect(backend.runtimeMetrics.bufferedCaptureBytes == 0)
        #expect(!backend.runtimeMetrics.inputRunning)
        backend.reset()
        #expect(completion.wait(timeout: .now() + .milliseconds(30)) == .timedOut)
        #expect(result.completionCount == 1)
    }

    @Test("permission replies cannot reject a replacement PCM generation")
    func retiredPermissionReplyCannotAffectReplacement() {
        let permission = LockedMicrophonePermission()
        let backend = DoryMacAudioBackend(
            log: { _ in },
            microphoneAuthorizationStatus: { permission.status },
            microphoneAuthorizationPollingInterval: 0.01,
            requestMicrophoneAccess: { permission.record($0) }
        )
        let parameters = captureParameters()
        #expect(backend.configure(streamID: 1, direction: .input, parameters: parameters))
        #expect(backend.start(streamID: 1, direction: .input))
        #expect(permission.requestCount == 1)
        #expect(backend.stop(streamID: 1, direction: .input))
        #expect(backend.configure(streamID: 1, direction: .input, parameters: parameters))
        #expect(backend.start(streamID: 1, direction: .input))
        #expect(permission.requestCount == 1)

        permission.respond(to: 0, granted: false)
        // Queue synchronization through metrics drains the stale permission callback.
        #expect(backend.runtimeMetrics.inputRunning)
        #expect(!backend.runtimeMetrics.microphoneAccessDenied)
        #expect(backend.requestCapture(byteCount: 4, parameters: parameters) { _, _ in })
        let deadline = Date().addingTimeInterval(1)
        while permission.requestCount < 2, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        #expect(permission.requestCount == 2)
        permission.respond(to: 1, granted: false)
        #expect(!backend.runtimeMetrics.inputRunning)
        #expect(backend.runtimeMetrics.microphoneAccessDenied)
        #expect(backend.runtimeMetrics.pendingCaptureBytes == 0)
    }

    @Test("a nominal permission grant is rechecked before installing capture")
    func delayedGrantMustStillBeAuthorized() {
        let permission = LockedMicrophonePermission()
        let backend = DoryMacAudioBackend(
            log: { _ in },
            microphoneAuthorizationStatus: { permission.status },
            requestMicrophoneAccess: { permission.record($0) }
        )
        let parameters = captureParameters()
        #expect(backend.configure(streamID: 1, direction: .input, parameters: parameters))
        #expect(backend.start(streamID: 1, direction: .input))
        permission.status = .denied
        permission.respond(to: 0, granted: true)
        #expect(!backend.runtimeMetrics.inputRunning)
        #expect(backend.runtimeMetrics.microphoneAccessDenied)
        #expect(!backend.requestCapture(byteCount: 4, parameters: parameters) { _, _ in })
    }

    @Test("reconfiguration cannot queue unbounded host permission prompts")
    func permissionPromptIsBoundedAcrossPCMGenerations() {
        let permission = LockedMicrophonePermission()
        let backend = DoryMacAudioBackend(
            log: { _ in },
            microphoneAuthorizationStatus: { permission.status },
            requestMicrophoneAccess: { permission.record($0) }
        )
        let parameters = captureParameters()
        for _ in 0..<100 {
            #expect(backend.configure(streamID: 1, direction: .input, parameters: parameters))
            #expect(backend.start(streamID: 1, direction: .input))
            #expect(backend.stop(streamID: 1, direction: .input))
        }
        #expect(permission.requestCount == 1)
        permission.respond(to: 0, granted: false)
        #expect(!backend.runtimeMetrics.inputRunning)
        #expect(!backend.runtimeMetrics.microphoneAccessDenied)
    }

    @Test("live permission revocation cancels capture without another guest request")
    func permissionMonitorRevokesIdleCapture() {
        let permission = LockedMicrophonePermission()
        let completion = DispatchSemaphore(value: 0)
        let result = LockedCaptureCompletion()
        let backend = DoryMacAudioBackend(
            log: { _ in },
            microphoneAuthorizationStatus: { permission.status },
            microphoneAuthorizationPollingInterval: 0.01,
            requestMicrophoneAccess: { permission.record($0) }
        )
        // A two-second request gives the monitor a generous interval before silence fallback.
        let parameters = VirtioSoundPCMParameters(
            bufferBytes: 384_000, periodBytes: 384_000, sampleRate: 48_000, channels: 2
        )
        #expect(backend.configure(streamID: 1, direction: .input, parameters: parameters))
        #expect(backend.requestCapture(byteCount: 384_000, parameters: parameters) { data, _ in
            result.record(data)
            completion.signal()
        })
        #expect(backend.start(streamID: 1, direction: .input))
        permission.status = .restricted
        #expect(completion.wait(timeout: .now() + 1) == .success)
        #expect(result.snapshot == (completed: true, dataWasNil: true))
        #expect(backend.runtimeMetrics.microphoneAccessDenied)
        #expect(!backend.runtimeMetrics.inputRunning)
        #expect(backend.runtimeMetrics.pendingCaptureBytes == 0)
        permission.respond(to: 0, granted: true)
        #expect(!backend.runtimeMetrics.inputRunning)
        backend.reset()
        #expect(result.completionCount == 1)
    }

    @Test("backend destruction settles capture descriptors without a live audio graph")
    func destructionSettlesPreparedCapture() {
        let completion = DispatchSemaphore(value: 0)
        let result = LockedCaptureCompletion()
        var backend: DoryMacAudioBackend? = DoryMacAudioBackend(log: { _ in })
        let parameters = captureParameters()
        #expect(backend!.configure(streamID: 1, direction: .input, parameters: parameters))
        #expect(backend!.requestCapture(byteCount: 4, parameters: parameters) { data, _ in
            result.record(data)
            completion.signal()
        })
        backend = nil
        #expect(completion.wait(timeout: .now() + 1) == .success)
        #expect(result.snapshot == (completed: true, dataWasNil: true))
        #expect(result.completionCount == 1)
    }

    private func captureParameters() -> VirtioSoundPCMParameters {
        VirtioSoundPCMParameters(bufferBytes: 192_000, periodBytes: 192_000,
            sampleRate: 48_000, channels: 2)
    }

    @Test("only configured running streams recover")
    func recoveryPolicyRequiresConfiguredRunningStream() {
        let stopped = DoryMacAudioConfigurationRecoveryState(
            outputConfigured: true,
            outputRunning: false,
            inputConfigured: true,
            inputRunning: false
        )
        #expect(stopped.action(for: .output) == .none)
        #expect(stopped.action(for: .input) == .none)

        let output = DoryMacAudioConfigurationRecoveryState(
            outputConfigured: true,
            outputRunning: true,
            inputConfigured: false,
            inputRunning: false
        )
        #expect(output.action(for: .output) == .restartOutput)
        #expect(output.action(for: .input) == .none)

        let input = DoryMacAudioConfigurationRecoveryState(
            outputConfigured: false,
            outputRunning: false,
            inputConfigured: true,
            inputRunning: true
        )
        #expect(input.action(for: .output) == .none)
        #expect(input.action(for: .input) == .rebuildInput)
    }

    @Test("configuration notifications are scoped to the owned audio engines")
    func observesOnlyOwnedAudioEngines() {
        let notificationCenter = NotificationCenter()
        let backend = DoryMacAudioBackend(
            log: { _ in },
            notificationCenter: notificationCenter
        )

        notificationCenter.post(
            name: .AVAudioEngineConfigurationChange,
            object: AVAudioEngine()
        )
        Thread.sleep(forTimeInterval: 0.02)
        #expect(backend.configurationChangeCount == 0)

        notificationCenter.post(
            name: .AVAudioEngineConfigurationChange,
            object: backend.outputEngine
        )
        notificationCenter.post(
            name: .AVAudioEngineConfigurationChange,
            object: backend.inputEngine
        )

        let deadline = Date().addingTimeInterval(1)
        while backend.configurationChangeCount < 2, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        #expect(backend.configurationChangeCount == 2)
        #expect(backend.runtimeMetrics.configurationChanges == 2)
    }
}

private final class LockedCaptureCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var dataWasNil = false
    private var count = 0

    func record(_ data: Data?) {
        lock.lock()
        completed = true
        count += 1
        dataWasNil = data == nil
        lock.unlock()
    }

    var snapshot: (completed: Bool, dataWasNil: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (completed, dataWasNil)
    }

    var completionCount: Int { lock.withLock { count } }
}

private final class LockedMicrophonePermission: @unchecked Sendable {
    private let lock = NSLock()
    private var storedStatus = AVAuthorizationStatus.notDetermined
    private var callbacks = [@Sendable (Bool) -> Void]()

    var status: AVAuthorizationStatus {
        get { lock.withLock { storedStatus } }
        set { lock.withLock { storedStatus = newValue } }
    }
    var requestCount: Int { lock.withLock { callbacks.count } }
    func record(_ callback: @escaping @Sendable (Bool) -> Void) {
        lock.withLock { callbacks.append(callback) }
    }
    func respond(to index: Int, granted: Bool) {
        let callback = lock.withLock { callbacks[index] }
        callback(granted)
    }
}
