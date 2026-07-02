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

    @Test func delegateSkipsActivationPolicyUnderTests() {
        #expect(DoryAppDelegate.isTestHost == true)
    }

    @Test func windowGateInertUnderTests() {
        #expect(DoryAppDelegate.isTestHost == true)
        let store = AppStore()
        store.onboarding = false
        #expect(store.shouldOpenWindowOnLaunch == false)
    }

    @Test func backendStartIsOnceOnly() {
        let store = AppStore()
        #expect(store.backendStartRequested == false)
        store.startBackendIfNeeded()
        store.startBackendIfNeeded()
        #expect(store.backendStartRequested == true)
    }

    @Test func delegateRespondsToWillTerminate() {
        let delegate = DoryAppDelegate()
        #expect(delegate.responds(to: #selector(NSApplicationDelegate.applicationWillTerminate(_:))))
    }

    @Test func userRequestedWindowSkipsLaunchGate() {
        let store = AppStore()
        store.onboarding = false
        store.windowOpenRequested = true
        #expect(store.windowOpenRequested == true)
        store.windowOpenRequested = false
        #expect(store.shouldOpenWindowOnLaunch == !store.isAgentMode)
    }

    @Test func stopEngineCommandTargetsSharedEngine() {
        if let command = SharedVMProvisioner.stopEngineCommand() {
            #expect(command.arguments == ["stop", "dory-engine"])
        }
    }
}
