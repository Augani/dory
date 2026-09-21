import DoryHV
import Testing
@testable import dory_hv

@Suite("Desktop relative pointer capture")
struct DesktopPointerCaptureTests {
    @Test("click-in captures once and Control-Command releases without leaking chord events")
    func captureAndReleaseChord() {
        var state = DesktopPointerCaptureState()

        let firstCapture = state.capture()
        let repeatedCapture = state.capture()
        #expect(firstCapture)
        #expect(!repeatedCapture)
        #expect(state.isCaptured)
        #expect(!state.acceptsAbsoluteInput)
        let controlOnly = state.modifierTransition(command: false, control: true)
        let release = state.modifierTransition(command: true, control: true)
        #expect(controlOnly == .forward)
        #expect(release == .release)
        #expect(!state.isCaptured)
        #expect(!state.acceptsAbsoluteInput)
        let commandUp = state.modifierTransition(command: true, control: false)
        let chordReleased = state.modifierTransition(command: false, control: false)
        let nextControl = state.modifierTransition(command: false, control: true)
        #expect(commandUp == .consume)
        #expect(chordReleased == .consume)
        #expect(nextControl == .forward)
    }

    @Test("focus loss cancels capture exactly once")
    func focusLossCancelsCapture() {
        var state = DesktopPointerCaptureState()
        let beforeCapture = state.cancel()
        let captured = state.capture()
        let firstCancel = state.cancel()
        let repeatedCancel = state.cancel()
        #expect(!beforeCapture)
        #expect(captured)
        #expect(firstCancel)
        #expect(!repeatedCancel)
    }

    @Test("relative motion flips AppKit Y and keeps button in the same frame")
    func relativeMotionFrame() {
        #expect(DesktopRelativePointerFrame.events(
            deltaX: 17.4,
            deltaY: 9.6,
            button: 272,
            pressed: true
        ) == [
            VirtioInputEvent(type: 2, code: 0, value: 17),
            VirtioInputEvent(type: 2, code: 1, value: -10),
            VirtioInputEvent(type: 1, code: 272, value: 1),
        ])
        #expect(DesktopRelativePointerFrame.events(deltaX: 0, deltaY: 0).isEmpty)
    }

    @Test("non-finite and oversized deltas cannot overflow evdev values")
    func clampsDeltas() {
        #expect(DesktopRelativePointerFrame.events(
            deltaX: .infinity,
            deltaY: -Double.greatestFiniteMagnitude
        ) == [
            VirtioInputEvent(type: 2, code: 1, value: .max),
        ])
    }
}
