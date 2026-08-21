@preconcurrency import AVFAudio
import DoryHV
import Foundation
import Testing
@testable import dory_hv

@Suite("Desktop audio configuration recovery")
struct DesktopAudioRecoveryTests {
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
    }
}
