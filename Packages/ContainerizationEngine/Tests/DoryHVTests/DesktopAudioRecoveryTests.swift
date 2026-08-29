@preconcurrency import AVFAudio
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

    func record(_ data: Data?) {
        lock.lock()
        completed = true
        dataWasNil = data == nil
        lock.unlock()
    }

    var snapshot: (completed: Bool, dataWasNil: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (completed, dataWasNil)
    }
}
