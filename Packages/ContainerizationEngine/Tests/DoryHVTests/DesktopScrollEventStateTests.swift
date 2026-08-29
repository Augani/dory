import DoryHV
import Testing
@testable import dory_hv

@Suite("Desktop host scroll delivery")
struct DesktopScrollEventStateTests {
    @Test("precise vertical and horizontal wheel events reach Linux without filtering")
    func preservesCompleteHighResolutionFrame() {
        var state = DesktopScrollEventState()

        #expect(state.events(
            horizontalDelta: -1,
            verticalDelta: 1,
            hasPreciseDeltas: true
        ) == [
            VirtioInputEvent(type: 2, code: 11, value: 12),
            VirtioInputEvent(type: 2, code: 12, value: -12),
        ])
    }

    @Test("legacy wheel ticks remain paired with high-resolution events")
    func preservesLegacyCompatibilityTicks() {
        var state = DesktopScrollEventState()

        #expect(state.events(
            horizontalDelta: -1,
            verticalDelta: 1,
            hasPreciseDeltas: false
        ) == [
            VirtioInputEvent(type: 2, code: 11, value: 120),
            VirtioInputEvent(type: 2, code: 8, value: 1),
            VirtioInputEvent(type: 2, code: 12, value: -120),
            VirtioInputEvent(type: 2, code: 6, value: -1),
        ])
    }

    @Test("focus reset clears retained sub-tick movement")
    func resetClearsPreciseRemainders() {
        var state = DesktopScrollEventState()
        _ = state.events(horizontalDelta: 0, verticalDelta: 9, hasPreciseDeltas: true)
        state.reset()

        #expect(state.events(
            horizontalDelta: 0,
            verticalDelta: 1,
            hasPreciseDeltas: true
        ) == [VirtioInputEvent(type: 2, code: 11, value: 12)])
    }
}
