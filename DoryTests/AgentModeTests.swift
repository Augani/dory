import Testing
@testable import Dory

@MainActor
struct AgentModeTests {
    @Test func setShowMenuBarIconForcesOnInAgentMode() {
        let store = AppStore()
        guard store.isAgentMode else { return }
        store.setShowMenuBarIcon(false)
        #expect(store.showMenuBarIcon == true)
    }

    @Test func windowOpensOnLaunchWhenOnboarding() {
        let store = AppStore()
        store.onboarding = true
        #expect(store.shouldOpenWindowOnLaunch == true)
    }

    @Test func windowSuppressedOnLaunchInAgentModeWhenNotOnboarding() {
        let store = AppStore()
        store.onboarding = false
        #expect(store.shouldOpenWindowOnLaunch == !store.isAgentMode)
    }
}
