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

    @Test func reopeningTheMenuBarAppRequestsTheMainWindow() {
        let delegate = DoryAppDelegate()
        #expect(
            delegate.applicationShouldHandleReopen(
                NSApplication.shared,
                hasVisibleWindows: false
            ) == false
        )
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

    @Test func duplicateInstanceDetectionIgnoresCurrentProcess() {
        #expect(!DoryAppDelegate.hasOtherInstance(currentProcessIdentifier: 10, candidates: [10]))
        #expect(DoryAppDelegate.hasOtherInstance(currentProcessIdentifier: 10, candidates: [9, 10]))
    }

    @Test func staleInstancePIDsIgnoreCurrentAndInvalidCandidates() {
        #expect(DoryAppDelegate.staleInstancePIDs(currentProcessIdentifier: 10, candidates: [-1, 0, 10, 11, 12]) == [11, 12])
    }

    @Test func instanceLockPathLivesUnderDoryHome() {
        #expect(DoryAppDelegate.instanceLockPath(home: "/Users/test") == "/Users/test/.dory/dory-app.lock")
    }

    @Test func displayQualificationRequiresAnIsolatedDaemon() throws {
        let environment = [
            DoryDisplayQualificationLaunch.machineIDEnvironmentKey: "gpu-campaign-1",
            DoryDisplayQualificationLaunch.machServiceEnvironmentKey:
                "dev.dory.readiness.gpu-campaign-1",
            DoryDisplayQualificationLaunch.windowReceiptEnvironmentKey:
                "/tmp/gpu-campaign-1-window.json",
        ]
        let launch = try #require(
            try DoryDisplayQualificationLaunch.parse(environment: environment)
        )
        #expect(launch.machineID == "gpu-campaign-1")
        #expect(launch.scanoutID == 0)
        #expect(launch.display.windowTitle == "Dory — gpu-campaign-1 — Display 1")

        #expect(throws: DoryDisplayQualificationLaunchError.productionMachService) {
            try DoryDisplayQualificationLaunch.parse(environment: [
                DoryDisplayQualificationLaunch.machineIDEnvironmentKey: "gpu-campaign-1",
                DoryDisplayQualificationLaunch.machServiceEnvironmentKey:
                    DoryDisplayQualificationLaunch.productionMachServiceName,
                DoryDisplayQualificationLaunch.windowReceiptEnvironmentKey:
                    "/tmp/gpu-campaign-1-window.json",
            ])
        }
        #expect(throws: DoryDisplayQualificationLaunchError.invalidMachService) {
            try DoryDisplayQualificationLaunch.parse(environment: [
                DoryDisplayQualificationLaunch.machineIDEnvironmentKey: "gpu-campaign-1",
            ])
        }
    }

    @Test func displayQualificationValidatesMachineAndScanoutScope() throws {
        let base = [
            DoryDisplayQualificationLaunch.machineIDEnvironmentKey: "gpu-campaign-1",
            DoryDisplayQualificationLaunch.machServiceEnvironmentKey:
                "dev.dory.readiness.gpu-campaign-1",
            DoryDisplayQualificationLaunch.windowReceiptEnvironmentKey:
                "/tmp/gpu-campaign-1-window.json",
        ]
        var secondDisplay = base
        secondDisplay[DoryDisplayQualificationLaunch.scanoutIDEnvironmentKey] = "1"
        let launch = try #require(
            try DoryDisplayQualificationLaunch.parse(environment: secondDisplay)
        )
        #expect(launch.scanoutID == 1)
        #expect(launch.display.windowTitle == "Dory — gpu-campaign-1 — Display 2")

        var invalidMachine = base
        invalidMachine[DoryDisplayQualificationLaunch.machineIDEnvironmentKey] = "../user-vm"
        #expect(throws: DoryDisplayQualificationLaunchError.invalidMachineID) {
            try DoryDisplayQualificationLaunch.parse(environment: invalidMachine)
        }
        var invalidScanout = base
        invalidScanout[DoryDisplayQualificationLaunch.scanoutIDEnvironmentKey] = "16"
        #expect(throws: DoryDisplayQualificationLaunchError.invalidScanoutID) {
            try DoryDisplayQualificationLaunch.parse(environment: invalidScanout)
        }
        var invalidReceipt = base
        invalidReceipt[DoryDisplayQualificationLaunch.windowReceiptEnvironmentKey] =
            "../gpu-campaign-1-window.json"
        #expect(throws: DoryDisplayQualificationLaunchError.invalidWindowReceiptPath) {
            try DoryDisplayQualificationLaunch.parse(environment: invalidReceipt)
        }
    }

    @Test func networkHelperRegistrationModeIsExplicit() {
        #expect(DoryAppDelegate.isNetworkHelperRegistration(arguments: ["Dory", "--register-network-helper"]))
        #expect(!DoryAppDelegate.isNetworkHelperRegistration(arguments: ["Dory", "--other"]))
        #expect(DoryAppDelegate.isNetworkHelperUnregistration(arguments: ["Dory", "--unregister-network-helper"]))
        #expect(!DoryAppDelegate.isNetworkHelperUnregistration(arguments: ["Dory", "--other"]))
        #expect(DoryAppDelegate.isNetworkHelperMaintenance(arguments: ["Dory", "--register-network-helper"]))
        #expect(DoryAppDelegate.isNetworkHelperMaintenance(arguments: ["Dory", "--unregister-network-helper"]))
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

    @Test func daemonAlwaysPersistsAfterAppQuit() throws {
        let suite = "DoryTests.keepDoryd.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(AppStore.resolvedKeepDorydRunningAfterQuit(defaults: defaults))
        defaults.set(true, forKey: AppStore.keepDorydRunningAfterQuitKey)
        #expect(AppStore.resolvedKeepDorydRunningAfterQuit(defaults: defaults))
        defaults.set(false, forKey: AppStore.keepDorydRunningAfterQuitKey)
        #expect(AppStore.resolvedKeepDorydRunningAfterQuit(defaults: defaults))
    }

    @Test func userRequestedWindowSkipsLaunchGate() {
        let store = AppStore()
        store.onboarding = false
        store.windowOpenRequested = true
        #expect(store.windowOpenRequested == true)
        store.windowOpenRequested = false
        #expect(store.shouldOpenWindowOnLaunch == !store.isAgentMode)
    }
}
