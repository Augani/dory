import Testing
import AppKit
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

    @Test func appDelegateKeepsAppAliveAfterLastWindowCloses() {
        let delegate = DoryAppDelegate()
        #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared) == false)
    }

    @Test func mainWindowIDIsStable() {
        #expect(DoryApp.mainWindowID == "dory-main")
    }

    @Test func openDoryTargetsMainWindow() {
        #expect(DoryCommands.openDoryWindowID == DoryApp.mainWindowID)
    }
}
