import Testing
import AppKit
import DoryVMDisplayWireContracts
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

        var incompleteInput = base
        incompleteInput[DoryDisplayQualificationLaunch.inputScriptEnvironmentKey] =
            "/tmp/gpu-campaign-1-input.json"
        #expect(throws: DoryDisplayQualificationLaunchError.incompleteInputAuthority) {
            try DoryDisplayQualificationLaunch.parse(environment: incompleteInput)
        }

        var inputPaths = base
        inputPaths[DoryDisplayQualificationLaunch.inputScriptEnvironmentKey] =
            "/tmp/gpu-campaign-1-input.json"
        inputPaths[DoryDisplayQualificationLaunch.inputReceiptEnvironmentKey] =
            "/tmp/gpu-campaign-1-input-receipt.json"
        let inputLaunch = try #require(
            try DoryDisplayQualificationLaunch.parse(environment: inputPaths)
        )
        #expect(inputLaunch.inputScriptPath == "/tmp/gpu-campaign-1-input.json")
        #expect(
            inputLaunch.inputReceiptPath == "/tmp/gpu-campaign-1-input-receipt.json"
        )
    }

    @Test func displayQualificationKeyboardScriptIsBoundedAndBalanced() throws {
        let valid = DoryDisplayQualificationInputScript(
            kind: DoryDisplayQualificationInputScript.kind,
            schemaVersion: DoryDisplayQualificationInputScript.schemaVersion,
            machineID: "gpu-campaign-1",
            steps: [
                .init(delayMilliseconds: 250, events: [
                    .init(type: 1, code: 28, value: 1),
                    .init(type: 1, code: 28, value: 0),
                ]),
            ]
        )
        let encoded = try JSONEncoder().encode(valid)
        let decoded = try DoryDisplayQualificationInputScript.decode(
            encoded,
            machineID: "gpu-campaign-1"
        )
        #expect(decoded == valid)
        #expect(decoded.eventCount == 2)
        #expect(decoded.totalDelayMilliseconds == 250)

        #expect(throws: DoryDisplayQualificationInputError.invalidScript) {
            try DoryDisplayQualificationInputScript.decode(
                encoded,
                machineID: "another-machine"
            )
        }

        let stuckKey = DoryDisplayQualificationInputScript(
            kind: DoryDisplayQualificationInputScript.kind,
            schemaVersion: DoryDisplayQualificationInputScript.schemaVersion,
            machineID: "gpu-campaign-1",
            steps: [
                .init(delayMilliseconds: 0, events: [
                    DoryVMDisplayInputEvent(type: 1, code: 28, value: 1),
                ]),
            ]
        )
        #expect(throws: DoryDisplayQualificationInputError.invalidScript) {
            try stuckKey.validate(machineID: "gpu-campaign-1")
        }

        let pointerEvent = DoryDisplayQualificationInputScript(
            kind: DoryDisplayQualificationInputScript.kind,
            schemaVersion: DoryDisplayQualificationInputScript.schemaVersion,
            machineID: "gpu-campaign-1",
            steps: [
                .init(delayMilliseconds: 0, events: [
                    DoryVMDisplayInputEvent(type: 3, code: 0, value: 16_384),
                ]),
            ]
        )
        #expect(throws: DoryDisplayQualificationInputError.invalidScript) {
            try pointerEvent.validate(machineID: "gpu-campaign-1")
        }
    }

    @Test func displayQualificationInputFilesAreDirectAndReceiptsAreExclusive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dory-display-input-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let script = DoryDisplayQualificationInputScript(
            kind: DoryDisplayQualificationInputScript.kind,
            schemaVersion: DoryDisplayQualificationInputScript.schemaVersion,
            machineID: "gpu-campaign-1",
            steps: [
                .init(delayMilliseconds: 0, events: [
                    .init(type: 1, code: 28, value: 1),
                    .init(type: 1, code: 28, value: 0),
                ]),
            ]
        )
        let scriptURL = root.appendingPathComponent("input.json")
        try JSONEncoder().encode(script).write(to: scriptURL, options: .withoutOverwriting)
        let loaded = try DoryDisplayQualificationInputFiles.loadScript(
            at: scriptURL.path,
            machineID: "gpu-campaign-1"
        )
        #expect(loaded.script == script)
        #expect(loaded.sha256.count == 64)

        let linkURL = root.appendingPathComponent("input-link.json")
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: scriptURL
        )
        #expect(throws: DoryDisplayQualificationInputError.scriptUnavailable) {
            try DoryDisplayQualificationInputFiles.loadScript(
                at: linkURL.path,
                machineID: "gpu-campaign-1"
            )
        }

        let receiptURL = root.appendingPathComponent("receipt.json")
        try DoryDisplayQualificationInputFiles.writeReceipt(
            ["status": "PASS"],
            at: receiptURL.path
        )
        #expect(FileManager.default.fileExists(atPath: receiptURL.path))
        #expect(throws: DoryDisplayQualificationInputError.receiptExists) {
            try DoryDisplayQualificationInputFiles.writeReceipt(
                ["status": "PASS"],
                at: receiptURL.path
            )
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
