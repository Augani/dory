import Testing
@testable import Dory

struct StatusPillTests {
    @Test func runStatePillText() {
        #expect(RunState.running.pillText == "Running")
        #expect(RunState.stopped.pillText == "Stopped")
        #expect(RunState.paused.pillText == "Paused")
    }
}
