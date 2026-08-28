import DoryHV
import Testing
@testable import dory_hv

@Suite("Desktop keyboard modifiers")
struct DesktopKeyboardModifierTests {
    @Test("a modifier carried only by keyDown is published before the character")
    func reconcilesSyntheticShiftBeforeCharacter() {
        var state = DesktopKeyboardModifierState()

        #expect(state.reconcile(activeModifiers: [.shift]) == [
            VirtioInputEvent(type: 1, code: 42, value: 1),
        ])
        #expect(state.reconcile(activeModifiers: [.shift]).isEmpty)
    }

    @Test("physical modifier events are not duplicated by the following keyDown")
    func physicalModifierIsNotDuplicated() {
        var state = DesktopKeyboardModifierState()

        #expect(state.update(modifier: .shift, linuxCode: 54, pressed: true) == [
            VirtioInputEvent(type: 1, code: 54, value: 1),
        ])
        #expect(state.reconcile(activeModifiers: [.shift]).isEmpty)
        #expect(state.update(modifier: .shift, linuxCode: 54, pressed: false) == [
            VirtioInputEvent(type: 1, code: 54, value: 0),
        ])
    }

    @Test("the next unmodified key releases a synthesized modifier")
    func releasesSyntheticModifierAtTheNextUnmodifiedEvent() {
        var state = DesktopKeyboardModifierState()
        _ = state.reconcile(activeModifiers: [.shift, .option])

        #expect(state.reconcile(activeModifiers: []) == [
            VirtioInputEvent(type: 1, code: 42, value: 0),
            VirtioInputEvent(type: 1, code: 56, value: 0),
        ])
        #expect(state.reconcile(activeModifiers: []).isEmpty)
    }
}
