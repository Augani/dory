import CryptoKit
import Darwin
import DoryOperations
@testable import DorydKit
import DoryVZMacCore
import Foundation
import XCTest

#if DEBUG
final class DoryDaemonNativeMacReleaseActivationQualificationTests: XCTestCase {
    func testActualNativeMacSavedStateThroughProductionActivation() throws {
        let environment = ProcessInfo.processInfo.environment
        if let recoveryFixturePath = environment["DORY_NATIVE_MAC_RELEASE_DAEMON_RECOVERY_FIXTURE"] {
            let helperPath = try XCTUnwrap(environment["DORY_NATIVE_MAC_REAL_VMM_EXECUTABLE"])
            let evidenceRoot = try XCTUnwrap(environment["DORY_NATIVE_MAC_RELEASE_DAEMON_EVIDENCE_ROOT"])
            let gvproxyPath = environment["DORY_NATIVE_MAC_REAL_GVPROXY"]
                ?? "/Applications/Dory.app/Contents/Helpers/gvproxy"
            try DorySecurityDynamicCodeValidator.validate(
                pid: getpid(),
                requirementText: DorydXPCSecurity.productionDaemonRequirement
            )
            FileHandle.standardError.write(Data(
                "release-activation native Mac manager-recovery host pid=\(getpid()) satisfies production daemon requirement\n".utf8
            ))
            try Self.runOnLargeStack {
                try Self.runRecoveryOnlyQualification(
                    sourceFixturePath: recoveryFixturePath,
                    helperPath: helperPath,
                    evidenceRoot: evidenceRoot,
                    gvproxyPath: gvproxyPath
                )
            }
            return
        }
        if let restartFixturePath = environment["DORY_NATIVE_MAC_RELEASE_DAEMON_RESTART_FIXTURE"] {
            let helperPath = try XCTUnwrap(environment["DORY_NATIVE_MAC_REAL_VMM_EXECUTABLE"])
            let evidenceRoot = try XCTUnwrap(environment["DORY_NATIVE_MAC_RELEASE_DAEMON_EVIDENCE_ROOT"])
            let gvproxyPath = environment["DORY_NATIVE_MAC_REAL_GVPROXY"]
                ?? "/Applications/Dory.app/Contents/Helpers/gvproxy"
            try DorySecurityDynamicCodeValidator.validate(
                pid: getpid(),
                requirementText: DorydXPCSecurity.productionDaemonRequirement
            )
            FileHandle.standardError.write(Data(
                "release-activation native Mac restart-only host pid=\(getpid()) satisfies production daemon requirement\n".utf8
            ))
            try Self.runOnLargeStack {
                try Self.runRestartOnlyQualification(
                    sourceFixturePath: restartFixturePath,
                    helperPath: helperPath,
                    evidenceRoot: evidenceRoot,
                    gvproxyPath: gvproxyPath
                )
            }
            return
        }
        guard environment["DORY_NATIVE_MAC_RELEASE_DAEMON_FIXTURE_START"] == "1" else {
            throw XCTSkip("set DORY_NATIVE_MAC_RELEASE_DAEMON_FIXTURE_START=1 to run the physical release-activation native Mac qualification")
        }
        let helperPath = try XCTUnwrap(environment["DORY_NATIVE_MAC_REAL_VMM_EXECUTABLE"])
        let preparedBundlePath = try XCTUnwrap(environment["DORY_NATIVE_MAC_PREPARED_BUNDLE"])
        let ipswPath = try XCTUnwrap(environment["DORY_NATIVE_MAC_IPSW"])
        let evidenceRoot = try XCTUnwrap(environment["DORY_NATIVE_MAC_RELEASE_DAEMON_EVIDENCE_ROOT"])
        let gvproxyPath = environment["DORY_NATIVE_MAC_REAL_GVPROXY"]
            ?? "/Applications/Dory.app/Contents/Helpers/gvproxy"

        try DorySecurityDynamicCodeValidator.validate(
            pid: getpid(),
            requirementText: DorydXPCSecurity.productionDaemonRequirement
        )
        FileHandle.standardError.write(Data(
            "release-activation native Mac qualification host pid=\(getpid()) satisfies production daemon requirement\n".utf8
        ))

        try Self.runOnLargeStack {
            try Self.runQualification(
                helperPath: helperPath,
                preparedBundlePath: preparedBundlePath,
                ipswPath: ipswPath,
                evidenceRoot: evidenceRoot,
                gvproxyPath: gvproxyPath
            )
        }
    }

    private static func runQualification(
        helperPath: String,
        preparedBundlePath: String,
        ipswPath: String,
        evidenceRoot: String,
        gvproxyPath: String
    ) throws {
        let helperDigest = try DoryComponentCatalogVerifier.fileDigest(helperPath)
        try FileManager.default.createDirectory(
            atPath: evidenceRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let signingKeyPath = releaseNativeMacTestSigningKeyPath(evidenceRoot: evidenceRoot)
        let signingKeyRawRepresentation = try loadOrCreateReleaseNativeMacTestSigningKey(
            at: signingKeyPath
        )
        let fixtureRoot = URL(fileURLWithPath: evidenceRoot, isDirectory: true)
            .appendingPathComponent("fixture", isDirectory: true)
        let fixture = try makeActualVMMProductionTrustFixture(
            actualVMMExecutablePath: helperPath,
            gvproxyPath: gvproxyPath,
            fixtureRoot: fixtureRoot,
            testSigningPrivateKeyRawRepresentation: signingKeyRawRepresentation
        )
        try writeReleaseNativeMacFixtureDescriptor(
            root: evidenceRoot,
            fixtureRoot: fixtureRoot.path,
            dataDriveRoot: fixture.drive.root,
            stateDirectory: fixture.machineConfiguration.stateDirectory,
            helperExecutablePath: helperPath,
            helperSHA256: helperDigest,
            gvproxyPath: gvproxyPath,
            testSigningKeyPath: signingKeyPath,
            testSigningKeySHA256: releaseNativeMacSHA256(signingKeyRawRepresentation)
        )
        var completed = false
        defer {
            let outcome = completed ? "success" : "failure"
            FileHandle.standardError.write(Data(
                "release-activation native Mac fixture retained after \(outcome) at \(fixture.root.path)\n".utf8
            ))
        }

        var configuration = fixture.machineConfiguration
        configuration.vmmExecutablePath = helperPath
        configuration.acceleratedDesktopExecutablePath = nil
        configuration.acceleratedDesktopBaseArguments = []
        configuration.runtimeDirectory = "/tmp/dory-release-vzmac-\(getpid())-\(UUID().uuidString.prefix(8))/runtime"
        configuration.logDirectory = evidenceRoot + "/release-logs"
        configuration.handoffReadyTimeoutSeconds = 240
        configuration.desktopHandoffReadyTimeoutSeconds = 240
        configuration.macOSRestoreHandoffReadyTimeoutSeconds = 240
        configuration.startupRestartPolicy = HvRestartPolicy.none

        let factory = Self.releaseNativeMacActivationFactory(
            helperPath: helperPath,
            helperDigest: helperDigest
        )

        let machineID = "native-mac-release-daemon"
        let machineDirectory = configuration.stateDirectory + "/" + machineID
        let restorePath = machineDirectory + "/Restore.ipsw"
        let bundlePath = machineDirectory + "/Machine.dorymac"
        try FileManager.default.createDirectory(
            atPath: machineDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try cloneOrCopyReleaseQualificationItem(source: ipswPath, destination: restorePath)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: restorePath)
        try cloneOrCopyReleaseQualificationItem(source: preparedBundlePath, destination: bundlePath)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bundlePath)

        let loadedBundle = try DoryVZMacMachineBundle.load(
            from: URL(fileURLWithPath: bundlePath, isDirectory: true)
        )
        let bundle = loadedBundle.manifest.installationState == .suspended
            ? try loadedBundle.updatingInstallationState(.stopped)
            : loadedBundle
        try requireReleaseNativeMac(
            bundle.manifest.installationState == .stopped,
            "release activation fixture requires a stopped native macOS bundle source"
        )
        let machine = DoryMachineConfiguration(
            id: machineID,
            guestFamily: .macOS,
            guestArchitecture: .arm64,
            kernelPath: "",
            rootfsPath: "",
            bootMode: .macOSRestore,
            macOSRestoreImagePath: restorePath,
            macOSMachineBundlePath: bundlePath,
            diskSizeBytes: bundle.manifest.resources.diskBytes,
            memoryMB: bundle.manifest.resources.memoryBytes / 1_048_576,
            cpuCount: bundle.manifest.resources.cpuCount,
            displayMode: .desktop
        )
        try Self.writePrivateJSON(machine, to: machineDirectory + "/machine.json")

        let diskReference = stableNativeMacReference(
            namespace: "macos-machine",
            machineID: machineID,
            role: "system-disk",
            digest: bundle.manifest.machineIdentifierSHA256
        )
        let definition = try nativeMacDefinition(
            id: machineID,
            diskReference: diskReference,
            bundle: bundle,
            createdAtUnixMilliseconds: workspaceCreationTimestamp(machineDirectory: machineDirectory)
        )
        try DoryWorkspaceRepository(root: configuration.stateDirectory).create(definition)
        try FileManager.default.removeItem(atPath: restorePath)
        try requireReleaseNativeMac(
            !FileManager.default.fileExists(atPath: restorePath),
            "release activation fixture should prove installed native Mac boot without retained IPSW"
        )

        func activateContext() throws -> DoryDaemonVirtualMachineProductionActivationContext {
            guard case let .activated(context) = factory.activate(
                store: fixture.store,
                machineConfiguration: configuration,
                appVersion: fixture.appVersion,
                publicKey: fixture.publicKey,
                expectedArchitecture: "arm64"
            ) else {
                throw MachineManagerError.persistence("release activation did not return an activated context")
            }
            return context
        }

        var cleanupManager: MachineManager?
        defer {
            if !completed { cleanupManager?.stopAll() }
            try? FileManager.default.removeItem(atPath: configuration.runtimeDirectory)
        }
        var running: DoryMachineStatus!
        var firstSuspend: DoryMachineStatus!
        var restored: DoryMachineStatus!
        var closed: DoryMachineStatus!
        var stopped: DoryMachineStatus!
        var normalColdRestart: DoryMachineStatus!
        var faultReadySuspend: DoryMachineStatus!
        var closedSavedStateBytes: UInt64?
        var activationPlanRevision: UInt64 = 0

        func startAndWait(
            _ manager: MachineManager,
            operationID: UUID,
            label: String
        ) throws -> DoryMachineStatus {
            let call: NativeMacReleaseThreadCall<DoryMachineStatus> = NativeMacReleaseThreadCall.start(name: label) {
                try manager.start(id: machineID, operationID: operationID)
            }
            let running = try waitForReleaseNativeMacStatus(
                manager,
                id: machineID,
                timeout: 240,
                label: label,
                failingWhenFinished: call
            ) { $0.state == .running }
            _ = try call.value()
            return running
        }

        func resumeAndWait(
            _ manager: MachineManager,
            operationID: UUID,
            label: String
        ) throws -> DoryMachineStatus {
            let call: NativeMacReleaseThreadCall<DoryMachineStatus> = NativeMacReleaseThreadCall.start(name: label) {
                try manager.resume(id: machineID, operationID: operationID)
            }
            let running = try waitForReleaseNativeMacStatus(
                manager,
                id: machineID,
                timeout: 240,
                label: label,
                failingWhenFinished: call
            ) { $0.state == .running }
            _ = try call.value()
            return running
        }

        func suspend(
            _ manager: MachineManager,
            operationID: UUID,
            label: String
        ) throws -> DoryMachineStatus {
            try NativeMacReleaseThreadCall.start(name: label) {
                try manager.suspend(id: machineID, operationID: operationID)
            }.value()
        }

        func stop(
            _ manager: MachineManager,
            operationID: UUID,
            label: String
        ) throws -> DoryMachineStatus {
            try NativeMacReleaseThreadCall.start(name: label) {
                try manager.stop(id: machineID, operationID: operationID)
            }.value()
        }

        let savedStateWrapperPath = machineDirectory + "/" + DoryMachineSavedStateStore.directoryName
        let savedStatePayloadPath = savedStateWrapperPath + "/" + DoryMachineSavedStateManifest.stateFileName

        weak var interruptedManager: MachineManager?
        do {
            let context = try activateContext()
            cleanupManager = context.machineManager
            interruptedManager = context.machineManager
            let startOperationID = UUID(uuidString: "88888888-9999-4aaa-8bbb-cccccccccccc")!
            running = try startAndWait(
                context.machineManager,
                operationID: startOperationID,
                label: "release start running"
            )
            let activatedPlan = try requireReleaseNativeMacPlan(
                running.runtimeIdentity.resolvedPlan,
                "release start should install a resolved runtime plan"
            )
            try requireReleaseNativeMac(
                activatedPlan.usesPreparedNativeMacOSBaseline,
                "release start should admit the prepared native macOS baseline"
            )
            try requireReleaseNativeMac(
                activatedPlan.backend == DoryVirtualizationBackendIdentity.appleVirtualizationFramework,
                "release start should select the VZ Mac backend"
            )
            activationPlanRevision = activatedPlan.planRevision

            firstSuspend = try suspend(
                context.machineManager,
                operationID: UUID(uuidString: "99999999-aaaa-4bbb-8ccc-dddddddddddd")!,
                label: "dory-release-native-mac-suspend"
            )
            try requireReleaseNativeMac(firstSuspend.state == .suspended, "release suspend should finish suspended")
            try requireReleaseNativeMac(firstSuspend.savedState != nil, "release suspend should publish saved-state metadata")

            restored = try resumeAndWait(
                context.machineManager,
                operationID: UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!,
                label: "release resume running"
            )
            try requireReleaseNativeMac(restored.savedState == nil, "release resume should consume saved state")

            closed = try suspend(
                context.machineManager,
                operationID: UUID(uuidString: "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff")!,
                label: "dory-release-native-mac-close"
            )
            try requireReleaseNativeMac(closed.state == .suspended, "release close should leave VM suspended")
            try requireReleaseNativeMac(closed.savedState != nil, "release close should publish saved state before cold stop")
            try requireReleaseNativeMac(
                FileManager.default.fileExists(atPath: savedStateWrapperPath),
                "release close should create a managed saved-state wrapper"
            )
            try requireReleaseNativeMac(
                try DoryVZMacMachineBundle.load(
                    from: URL(fileURLWithPath: bundlePath, isDirectory: true)
                ).manifest.installationState == .suspended,
                "release close should mark the native bundle suspended"
            )

            closedSavedStateBytes = (try? FileManager.default.attributesOfItem(
                atPath: savedStatePayloadPath
            )[.size] as? NSNumber)?.uint64Value

            stopped = try stop(
                context.machineManager,
                operationID: UUID(uuidString: "cccccccc-dddd-4eee-8fff-111111111111")!,
                label: "dory-release-native-mac-stop"
            )
            try requireReleaseNativeMac(stopped.state == .stopped, "release cold stop should finish stopped")
            try requireReleaseNativeMac(stopped.savedState == nil, "release cold stop should discard saved-state metadata")
            try requireReleaseNativeMac(
                !FileManager.default.fileExists(atPath: savedStateWrapperPath),
                "release cold stop should remove the managed saved-state wrapper"
            )
            try requireReleaseNativeMac(
                try DoryVZMacMachineBundle.load(
                    from: URL(fileURLWithPath: bundlePath, isDirectory: true)
                ).manifest.installationState == .stopped,
                "release cold stop should mark the native bundle stopped"
            )

            normalColdRestart = try startAndWait(
                context.machineManager,
                operationID: UUID(uuidString: "dddddddd-eeee-4fff-8aaa-222222222222")!,
                label: "release cold restart running"
            )
            faultReadySuspend = try suspend(
                context.machineManager,
                operationID: UUID(uuidString: "eeeeeeee-ffff-4000-8aaa-333333333333")!,
                label: "dory-release-native-mac-fault-ready-suspend"
            )
            try requireReleaseNativeMac(faultReadySuspend.state == .suspended, "release fault setup should suspend before injected cold stop")
            try requireReleaseNativeMac(
                FileManager.default.fileExists(atPath: savedStatePayloadPath),
                "release fault setup should retain a saved-state payload"
            )

            let injectedFault = ReleaseNativeMacFaultRecorder()
            context.machineManager.installLifecycleFaultInjectorForTesting { point in
                if point == .nativeMacColdStopAfterBundleStopped {
                    injectedFault.record()
                    throw MachineLifecycleInjectedCrash()
                }
            }
            var injectedStopThrew = false
            do {
                _ = try stop(
                    context.machineManager,
                    operationID: UUID(uuidString: "ffffffff-1111-4222-8aaa-444444444444")!,
                    label: "dory-release-native-mac-injected-stop"
                )
            } catch {
                injectedStopThrew = true
            }
            try requireReleaseNativeMac(injectedStopThrew, "release injected cold stop should fail the stop operation")
            try requireReleaseNativeMac(injectedFault.observed, "release injected cold stop fault should run")
            try requireReleaseNativeMac(
                try DoryVZMacMachineBundle.load(
                    from: URL(fileURLWithPath: bundlePath, isDirectory: true)
                ).manifest.installationState == .stopped,
                "release injected cold stop should commit the bundle to stopped before crashing"
            )
            try requireReleaseNativeMac(
                FileManager.default.fileExists(atPath: savedStatePayloadPath),
                "release injected cold stop should leave the saved-state payload for partial-discard probing"
            )
            try FileManager.default.removeItem(atPath: savedStatePayloadPath)
            try requireReleaseNativeMac(
                FileManager.default.fileExists(atPath: savedStateWrapperPath),
                "release partial-discard probe should leave the saved-state wrapper manifest for recovery"
            )
            try requireReleaseNativeMac(
                !FileManager.default.fileExists(atPath: savedStatePayloadPath),
                "release partial-discard probe should remove only the saved-state payload"
            )

            cleanupManager = nil
        }

        try requireReleaseNativeMac(
            interruptedManager == nil,
            "release interrupted manager should deallocate before recovery activation"
        )
        let context = try activateContext()
        cleanupManager = context.machineManager
        let recovered = try requireReleaseNativeMacStatus(
            context.machineManager.status(id: machineID),
            "release recovery should reload the machine"
        )
        try requireReleaseNativeMac(
            recovered.state == DoryVirtualMachineState.stopped,
            "release recovery should finish interrupted cold stop as stopped: \(releaseNativeMacStatusDetail(recovered))"
        )
        try requireReleaseNativeMac(recovered.savedState == nil, "release recovery should clear saved-state metadata")
        try requireReleaseNativeMac(
            !FileManager.default.fileExists(atPath: savedStateWrapperPath),
            "release recovery should remove the partial saved-state wrapper"
        )
        try requireReleaseNativeMac(
            try DoryVZMacMachineBundle.load(
                from: URL(fileURLWithPath: bundlePath, isDirectory: true)
            ).manifest.installationState == .stopped,
            "release recovery should preserve the stopped native bundle"
        )

        let recoveredColdStart = try startAndWait(
            context.machineManager,
            operationID: UUID(uuidString: "11111111-2222-4333-8aaa-555555555555")!,
            label: "release recovered cold start running"
        )
        let finalSuspend = try suspend(
            context.machineManager,
            operationID: UUID(uuidString: "22222222-3333-4444-8aaa-666666666666")!,
            label: "dory-release-native-mac-final-suspend"
        )
        try requireReleaseNativeMac(finalSuspend.state == .suspended, "release cleanup should suspend recovered cold start")
        let finalStop = try stop(
            context.machineManager,
            operationID: UUID(uuidString: "33333333-4444-4555-8aaa-777777777777")!,
            label: "dory-release-native-mac-final-stop"
        )
        try requireReleaseNativeMac(finalStop.state == .stopped, "release cleanup should cold-stop recovered run")
        try requireReleaseNativeMac(
            !FileManager.default.fileExists(atPath: savedStateWrapperPath),
            "release cleanup should remove final saved-state wrapper"
        )

        try writeReleaseManagedNativeMacEvidence(
            root: evidenceRoot,
            fixtureRoot: fixture.root.path,
            machineID: machineID,
            machineDirectory: machineDirectory,
            bundlePath: bundlePath,
            helperExecutablePath: helperPath,
            helperSHA256: helperDigest,
            testSigningKeyPath: signingKeyPath,
            testSigningKeySHA256: releaseNativeMacSHA256(signingKeyRawRepresentation),
            activationPlanRevision: activationPlanRevision,
            startStatus: running,
            suspendedStatus: firstSuspend,
            restoredStatus: restored,
            closedStatus: closed,
            stoppedStatus: stopped,
            normalColdRestartStatus: normalColdRestart,
            faultReadySuspendStatus: faultReadySuspend,
            recoveredStatus: recovered,
            recoveredColdStartStatus: recoveredColdStart,
            finalSuspendStatus: finalSuspend,
            finalStopStatus: finalStop,
            closedSavedStateBytes: closedSavedStateBytes,
            partialPayloadRemovedBeforeRecovery: true
        )
        completed = true
    }

    private static func runRestartOnlyQualification(
        sourceFixturePath: String,
        helperPath: String,
        evidenceRoot: String,
        gvproxyPath: String
    ) throws {
        let fixtureRoot = URL(fileURLWithPath: sourceFixturePath, isDirectory: true)
            .standardizedFileURL
        let signingKeyPath = releaseNativeMacExistingFixtureSigningKeyPath(
            fixtureRoot: fixtureRoot.path
        )
        let before = try releaseNativeMacReplayLedger(
            fixtureRoot: fixtureRoot.path,
            helperPath: helperPath,
            signingKeyPath: signingKeyPath
        )
        try FileManager.default.createDirectory(
            atPath: evidenceRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var machineID = "native-mac-release-daemon"
        var machineDirectory = ""
        var helperDigest = before.helperSHA256
        var signingKeySHA256 = before.signingKeySHA256
        var reopenMode = "legacy-reconstructed"
        var finalStatus: DoryMachineStatus?
        var replayError: String?
        var didStart = false
        var context: DoryDaemonVirtualMachineProductionActivationContext?
        do {
            let fixture = try reopenReleaseNativeMacActivationFixture(
                fixtureRoot: fixtureRoot,
                helperPath: helperPath
            )
            machineID = fixture.machineID
            machineDirectory = fixture.machineDirectory
            helperDigest = fixture.helperSHA256
            signingKeySHA256 = fixture.signingKeySHA256
            reopenMode = fixture.reopenMode
            let afterReopen = try releaseNativeMacReplayLedger(
                fixtureRoot: fixtureRoot.path,
                helperPath: helperPath,
                signingKeyPath: fixture.signingKeyPath
            )
            try requireReleaseNativeMac(
                before == afterReopen,
                "release restart-only loader changed fixture files before activation"
            )
            let activated = try activateReleaseNativeMacContext(
                factory: fixture.factory,
                store: fixture.store,
                machineConfiguration: fixture.machineConfiguration,
                appVersion: fixture.appVersion,
                publicKey: fixture.publicKey
            )
            context = activated
            let status = try startReleaseNativeMacAndWait(
                activated.machineManager,
                machineID: fixture.machineID,
                operationID: UUID(uuidString: "44444444-5555-4666-8aaa-888888888888")!,
                label: "release restart-only cold start running"
            )
            didStart = status.state == .running
            finalStatus = status
        } catch {
            replayError = String(describing: error)
            if let context { finalStatus = context.machineManager.status(id: machineID) }
        }
        if didStart { context?.machineManager.stopAll() }
        let after = try releaseNativeMacReplayLedger(
            fixtureRoot: fixtureRoot.path,
            helperPath: helperPath,
            signingKeyPath: signingKeyPath
        )
        try writeReleaseManagedNativeMacRestartOnlyEvidence(
            root: evidenceRoot,
            sourceFixturePath: sourceFixturePath,
            helperExecutablePath: helperPath,
            helperSHA256: helperDigest,
            testSigningKeyPath: signingKeyPath,
            testSigningKeySHA256: signingKeySHA256,
            machineID: machineID,
            machineDirectory: machineDirectory,
            reopenMode: reopenMode,
            startStatus: finalStatus,
            startError: replayError,
            before: before,
            after: after
        )
        try requireReleaseNativeMac(
            before.trustCritical == after.trustCritical,
            "release restart-only replay changed trust-critical fixture files"
        )
        if let replayError {
            throw MachineManagerError.persistence(
                "release restart-only cold start failed after read-only activation: \(replayError)"
            )
        }
    }

    private static func runRecoveryOnlyQualification(
        sourceFixturePath: String,
        helperPath: String,
        evidenceRoot: String,
        gvproxyPath: String
    ) throws {
        let helperDigest = try DoryComponentCatalogVerifier.fileDigest(helperPath)
        try FileManager.default.createDirectory(
            atPath: evidenceRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let fixtureRoot = URL(fileURLWithPath: sourceFixturePath, isDirectory: true)
        let drive = try DoryDataDrive(home: fixtureRoot.path)
        guard case .ready = try drive.inspect() else {
            throw MachineManagerError.persistence("release recovery-only fixture data drive is not ready")
        }
        let machineConfiguration = MachineManagerConfiguration(
            vmmExecutablePath: helperPath,
            armVirtFirmwareBundlePath: fixtureRoot.appendingPathComponent(
                "armvirt-firmware",
                isDirectory: true
            ).path,
            stateDirectory: drive.machinesDirectory,
            runtimeDirectory: fixtureRoot.appendingPathComponent("runtime", isDirectory: true).path,
            acceleratedDesktopBaseArguments: [],
            passMachineArguments: true,
            logDirectory: fixtureRoot.appendingPathComponent("logs", isDirectory: true).path,
            requiresReadyHandoff: true,
            handoffReadyTimeoutSeconds: 120,
            desktopHandoffReadyTimeoutSeconds: 120,
            startupRestartPolicy: .none
        )
        let machineID = "native-mac-release-daemon"
        let machineDirectory = machineConfiguration.stateDirectory + "/" + machineID
        let savedStateWrapperPath = machineDirectory + "/" + DoryMachineSavedStateStore.directoryName
        try requireReleaseNativeMacRecoveryPreconditions(
            machineID: machineID,
            machineDirectory: machineDirectory,
            savedStateWrapperPath: savedStateWrapperPath,
            lifecycleJournalHome: machineConfiguration.lifecycleJournalHome
        )
        let context = MachineManager(configuration: machineConfiguration)
        let status = try requireReleaseNativeMacStatus(
            context.status(id: machineID),
            "release recovery-only manager recovery should reload the machine"
        )
        try requireReleaseNativeMac(
            status.state == DoryVirtualMachineState.stopped,
            "release recovery-only manager recovery should finish interrupted cold stop as stopped: \(releaseNativeMacStatusDetail(status))"
        )
        try requireReleaseNativeMac(
            status.savedState == nil,
            "release recovery-only manager recovery should clear saved-state metadata"
        )
        try requireReleaseNativeMac(
            !FileManager.default.fileExists(atPath: savedStateWrapperPath),
            "release recovery-only manager recovery should remove the partial saved-state wrapper"
        )
        let records = try DoryOperationJournalStore(
            home: machineConfiguration.lifecycleJournalHome
        ).list()
        let coldStopOperationID = UUID(uuidString: "ffffffff-1111-4222-8aaa-444444444444")!
        let coldStopCompleted = records.contains { record in
            record.plan.id == coldStopOperationID
                && record.plan.kind == .workspaceStop
                && record.state.status == .completed
        }
        try requireReleaseNativeMac(
            coldStopCompleted,
            "release recovery-only manager recovery should complete the interrupted cold-stop journal"
        )
        try writeReleaseManagedNativeMacRecoveryOnlyEvidence(
            root: evidenceRoot,
            sourceFixturePath: sourceFixturePath,
            fixtureRoot: fixtureRoot.path,
            machineID: machineID,
            machineDirectory: machineDirectory,
            helperExecutablePath: helperPath,
            helperSHA256: helperDigest,
            recoveredStatus: status
        )
    }

    private static func runOnLargeStack(_ operation: @escaping @Sendable () throws -> Void) throws {
        let call = NativeMacReleaseThreadCall.start(name: "dory-release-native-mac-main", operation)
        try call.value()
    }

    private static func writePrivateJSON<T: Encodable>(_ value: T, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: URL(fileURLWithPath: path), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    private static func nativeMacDefinition(
        id: String,
        diskReference: DoryVMResolverReference,
        bundle: DoryVZMacMachineBundle,
        createdAtUnixMilliseconds: Int64
    ) throws -> DoryVirtualMachineDefinition {
        let guest = DoryGuestPlatform(family: .macOS, architecture: .arm64)
        let graphics = DoryVMGraphicsPolicy(acceptableLevels: [.hostAcceleratedDisplay])
        let displays = [DoryVMDisplayConfiguration()]
        try requireReleaseNativeMac(
            bundle.manifest.installationState == .stopped,
            "native Mac release fixture definition requires a stopped installed bundle"
        )
        let boot = DoryVMBootConfiguration(
            phase: .normal,
            devices: [DoryVMBootMediaReference(
                id: "system",
                role: .system,
                kind: .virtualDisk,
                source: .userProvided,
                artifact: diskReference,
                removable: false
            )],
            order: ["system"]
        )
        let definition = DoryVirtualMachineDefinition(
            identity: DoryVirtualMachineIdentity(id: id, name: id),
            guest: guest,
            workload: .desktop,
            boot: boot,
            platform: .arm64MacOSV1,
            translationConsent: .notRequired,
            graphics: graphics,
            resources: DoryVMProductionResourceBudget.make(
                guest: guest,
                graphics: graphics,
                displays: displays,
                shareCount: 0,
                virtualCPUCount: UInt64(bundle.manifest.resources.cpuCount),
                memoryBytes: bundle.manifest.resources.memoryBytes,
                diskBytes: bundle.manifest.resources.diskBytes
            ),
            storage: [DoryVMStorageAttachment(
                id: "system",
                role: .system,
                artifact: diskReference,
                source: .userProvided,
                capacityBytes: bundle.manifest.resources.diskBytes
            )],
            networkMode: .sharedNAT,
            displays: displays,
            audio: DoryVMAudioConfiguration(inputEnabled: true, outputEnabled: true),
            camera: DoryVMCameraConfiguration(enabled: false),
            input: DoryVMInputConfiguration(),
            integrations: [.clipboard, .dynamicDisplay, .gracefulShutdown],
            clipboardPolicy: .legacyDesktop(.bidirectional),
            lifecycle: DoryVMLifecycleMetadata(
                revision: 1,
                createdAtUnixMilliseconds: createdAtUnixMilliseconds,
                updatedAtUnixMilliseconds: createdAtUnixMilliseconds
            )
        )
        let issues = definition.validate()
        guard issues.isEmpty else {
            throw MachineManagerError.persistence("native Mac definition invalid: \(issues)")
        }
        return definition
    }
}


private struct ReleaseNativeMacReopenedFixture {
    var fixtureRoot: URL
    var drive: DoryDataDrive
    var store: DoryComponentStore
    var machineConfiguration: MachineManagerConfiguration
    var factory: DoryDaemonVirtualMachineProductionTrustFactory
    var appVersion: String
    var publicKey: String
    var signingKeyPath: String
    var signingKeySHA256: String
    var helperSHA256: String
    var machineID: String
    var machineDirectory: String
    var reopenMode: String
}

private struct ReleaseNativeMacFixtureDescriptor: Codable, Equatable {
    var schema: String
    var fixtureRoot: String
    var dataDriveRoot: String
    var stateDirectory: String
    var machineID: String
    var helperExecutablePath: String
    var helperSHA256: String
    var gvproxyPath: String
    var testSigningKeyPath: String
    var testSigningKeySHA256: String
    var armVirtFirmwareBundlePath: String
    var logDirectory: String
    var requiresReadyHandoff: Bool
    var passMachineArguments: Bool
    var handoffReadyTimeoutSeconds: TimeInterval
    var desktopHandoffReadyTimeoutSeconds: TimeInterval
    var macOSRestoreHandoffReadyTimeoutSeconds: TimeInterval
    var startupRestartPolicy: String
    var runtimeDirectoryPolicy: String
}

private struct ReleaseNativeMacReplayLedger: Codable, Equatable {
    var fixtureRoot: String
    var helperSHA256: String
    var signingKeyPath: String
    var signingKeySHA256: String
    var trustCritical: [String: String]
    var machineControl: [String: String]
}

private extension DoryDaemonNativeMacReleaseActivationQualificationTests {
    static func releaseNativeMacActivationFactory(
        helperPath: String,
        helperDigest: String
    ) -> DoryDaemonVirtualMachineProductionTrustFactory {
        DoryDaemonVirtualMachineProductionTrustFactory(
            authorityResolver: { store, key, architecture, appVersion in
                try DoryVirtualMachineQualificationAuthorityResolver.resolve(
                    store: store,
                    publicKey: key,
                    expectedArchitecture: architecture,
                    appVersion: appVersion
                )
            },
            runtimeVerifier: { path, descriptor, component in
                guard path == helperPath,
                      component == "dory-vmm",
                      try DoryComponentCatalogVerifier.fileDigest(path) == helperDigest else {
                    throw DoryDaemonProductionTrustInventoryError.backendUnavailable
                }
                let build = "sha256:\(helperDigest)"
                return DoryDaemonVerifiedBackendRuntime(
                    descriptor: descriptor,
                    executablePath: path,
                    runtimeBuildIdentifier: build,
                    components: [DoryVirtualMachineQualifiedComponent(
                        componentIdentifier: component,
                        buildIdentifier: build,
                        artifactSHA256: helperDigest
                    )]
                )
            },
            hostProbe: { _ in
                DoryDaemonProductionHostObservation(
                    hardwareModelIdentifier: "Mac16,1",
                    operatingSystemBuild: "26A5406c",
                    macOSMajorVersion: 26,
                    virtualizationFrameworkAvailable: true,
                    hypervisorFrameworkAvailable: true,
                    metalAvailable: true,
                    resources: DoryVMHostResources(
                        logicalCPUCount: 12,
                        physicalMemoryBytes: 32 * 1_024 * 1_024 * 1_024,
                        freeStorageBytes: 512 * 1_024 * 1_024 * 1_024
                    )
                )
            },
            daemonIdentityVerifier: {
                DorydXPCSecurity.currentProcessSatisfiesProductionDaemonRequirement()
            },
            planningTransactionAvailable: { true }
        )
    }

    static func reopenReleaseNativeMacActivationFixture(
        fixtureRoot: URL,
        helperPath: String
    ) throws -> ReleaseNativeMacReopenedFixture {
        let helperDigest = try DoryComponentCatalogVerifier.fileDigest(helperPath)
        let descriptor = try readReleaseNativeMacFixtureDescriptor(
            fixtureRoot: fixtureRoot.path
        )
        let drive = try DoryDataDrive(home: fixtureRoot.path)
        guard case .ready = try drive.inspect() else {
            throw MachineManagerError.persistence("release restart-only fixture data drive is not ready")
        }
        let store = DoryComponentStore(drive: drive)
        let signingKeyPath = descriptor?.testSigningKeyPath
            ?? releaseNativeMacExistingFixtureSigningKeyPath(fixtureRoot: fixtureRoot.path)
        let signingKeyRawRepresentation = try readReleaseNativeMacTestSigningKey(
            at: signingKeyPath
        )
        let signingKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: signingKeyRawRepresentation
        )
        let machineID = descriptor?.machineID ?? "native-mac-release-daemon"
        let machineDirectory = drive.machinesDirectory + "/" + machineID
        if let descriptor {
            try validateReleaseNativeMacFixtureDescriptor(
                descriptor,
                fixtureRoot: fixtureRoot.path,
                dataDriveRoot: drive.root,
                stateDirectory: drive.machinesDirectory,
                helperPath: helperPath,
                helperSHA256: helperDigest,
                signingKeyPath: signingKeyPath,
                signingKeySHA256: releaseNativeMacSHA256(signingKeyRawRepresentation),
                machineID: machineID
            )
        }
        let resolvedPlan = try DoryResolvedMachinePlanRepository(
            root: drive.machinesDirectory
        ).read(id: machineID)
        let resolvedVMMComponent = resolvedPlan.components.first {
            $0.componentIdentifier == "dory-vmm"
        }
        try requireReleaseNativeMac(
            resolvedVMMComponent?.artifactSHA256 == helperDigest
                && resolvedVMMComponent?.buildIdentifier == "sha256:\(helperDigest)",
            "release restart-only helper digest must match the durable resolved-plan dory-vmm component"
        )
        try requireReleaseNativeMac(
            FileManager.default.fileExists(atPath: machineDirectory + "/machine.json"),
            "release restart-only fixture must contain persisted machine metadata"
        )
        let machineData = try Data(
            contentsOf: URL(fileURLWithPath: machineDirectory + "/machine.json")
        )
        let machine = try JSONDecoder().decode(DoryMachineConfiguration.self, from: machineData)
        try requireReleaseNativeMac(
            machine.id == machineID
                && machine.macOSMachineBundlePath == machineDirectory + "/Machine.dorymac"
                && machine.macOSRestoreImagePath == machineDirectory + "/Restore.ipsw",
            "release restart-only fixture machine metadata must bind the managed Mac bundle and restore image"
        )
        try requireReleaseNativeMac(
            FileManager.default.fileExists(atPath: machineDirectory + "/workspace-v2.json"),
            "release restart-only fixture must contain persisted workspace definition"
        )
        try requireReleaseNativeMac(
            !FileManager.default.fileExists(atPath: machineDirectory + "/" + DoryMachineSavedStateStore.directoryName),
            "release restart-only fixture must begin cold-stopped without a saved-state wrapper"
        )
        let bundle = try DoryVZMacMachineBundle.load(
            from: URL(fileURLWithPath: machineDirectory + "/Machine.dorymac", isDirectory: true)
        )
        try requireReleaseNativeMac(
            bundle.manifest.installationState == .stopped,
            "release restart-only fixture must begin with the native Mac bundle stopped"
        )
        let configuration = MachineManagerConfiguration(
            vmmExecutablePath: helperPath,
            armVirtFirmwareBundlePath: descriptor?.armVirtFirmwareBundlePath
                ?? fixtureRoot.appendingPathComponent("armvirt-firmware", isDirectory: true).path,
            stateDirectory: drive.machinesDirectory,
            runtimeDirectory: "/tmp/dory-release-vzmac-restart-\(getpid())-\(UUID().uuidString.prefix(8))/runtime",
            acceleratedDesktopBaseArguments: [],
            passMachineArguments: descriptor?.passMachineArguments ?? true,
            logDirectory: descriptor?.logDirectory
                ?? fixtureRoot.appendingPathComponent("logs", isDirectory: true).path,
            requiresReadyHandoff: descriptor?.requiresReadyHandoff ?? true,
            handoffReadyTimeoutSeconds: descriptor?.handoffReadyTimeoutSeconds ?? 240,
            desktopHandoffReadyTimeoutSeconds: descriptor?.desktopHandoffReadyTimeoutSeconds ?? 240,
            macOSRestoreHandoffReadyTimeoutSeconds: descriptor?.macOSRestoreHandoffReadyTimeoutSeconds ?? 240,
            startupRestartPolicy: .none
        )
        return ReleaseNativeMacReopenedFixture(
            fixtureRoot: fixtureRoot,
            drive: drive,
            store: store,
            machineConfiguration: configuration,
            factory: releaseNativeMacActivationFactory(
                helperPath: helperPath,
                helperDigest: helperDigest
            ),
            appVersion: "1.0.0",
            publicKey: signingKey.publicKey.rawRepresentation.base64EncodedString(),
            signingKeyPath: signingKeyPath,
            signingKeySHA256: releaseNativeMacSHA256(signingKeyRawRepresentation),
            helperSHA256: helperDigest,
            machineID: machineID,
            machineDirectory: machineDirectory,
            reopenMode: descriptor == nil ? "legacy-reconstructed-cold-start" : "descriptor-read-only-cold-start"
        )
    }
}

private func activateReleaseNativeMacContext(
    factory: DoryDaemonVirtualMachineProductionTrustFactory,
    store: DoryComponentStore,
    machineConfiguration: MachineManagerConfiguration,
    appVersion: String,
    publicKey: String
) throws -> DoryDaemonVirtualMachineProductionActivationContext {
    switch factory.activate(
        store: store,
        machineConfiguration: machineConfiguration,
        appVersion: appVersion,
        publicKey: publicKey,
        expectedArchitecture: "arm64"
    ) {
    case let .activated(context):
        return context
    case let .unavailable(failure):
        throw MachineManagerError.persistence(
            "release activation unavailable: \(failure.code.rawValue): \(failure.message)"
        )
    }
}

private func startReleaseNativeMacAndWait(
    _ manager: MachineManager,
    machineID: String,
    operationID: UUID,
    label: String
) throws -> DoryMachineStatus {
    let call: NativeMacReleaseThreadCall<DoryMachineStatus> = NativeMacReleaseThreadCall.start(name: label) {
        try manager.start(id: machineID, operationID: operationID)
    }
    _ = try waitForReleaseNativeMacStatus(
        manager,
        id: machineID,
        timeout: 240,
        label: label,
        failingWhenFinished: call
    ) { $0.state == .running }
    return try call.value()
}

private func releaseNativeMacReplayLedger(
    fixtureRoot: String,
    helperPath: String,
    signingKeyPath: String
) throws -> ReleaseNativeMacReplayLedger {
    let drive = try DoryDataDrive(home: fixtureRoot)
    let machineDirectory = drive.machinesDirectory + "/native-mac-release-daemon"
    var trustPaths = [
        helperPath,
        signingKeyPath,
        fixtureRoot + "/qualification.json",
        drive.componentsDirectory + "/catalog.json",
        drive.componentsDirectory + "/catalog.sig",
        drive.componentsDirectory + "/active/linux-machines.json",
        drive.machinesDirectory + "/.vm-production-trust-floor-v1",
    ]
    trustPaths += try releaseNativeMacRegularFiles(
        under: drive.componentsDirectory + "/installed"
    )
    trustPaths += try releaseNativeMacRegularFiles(
        under: drive.machinesDirectory + "/.artifact-authority"
    )
    let machinePaths = [
        machineDirectory + "/machine.json",
        machineDirectory + "/workspace-v2.json",
        machineDirectory + "/resolved-plan.json",
        machineDirectory + "/runtime-identity-v1.json",
        machineDirectory + "/runtime-identity-head-v1.json",
        machineDirectory + "/planning-transaction-v1.json",
        machineDirectory + "/Machine.dorymac/machine.json",
    ]
    let keyData = try readReleaseNativeMacTestSigningKey(at: signingKeyPath)
    return ReleaseNativeMacReplayLedger(
        fixtureRoot: fixtureRoot,
        helperSHA256: try DoryComponentCatalogVerifier.fileDigest(helperPath),
        signingKeyPath: signingKeyPath,
        signingKeySHA256: releaseNativeMacSHA256(keyData),
        trustCritical: try releaseNativeMacHashRequiredFiles(trustPaths),
        machineControl: try releaseNativeMacHashRequiredFiles(machinePaths)
    )
}

private func releaseNativeMacRegularFiles(under root: String) throws -> [String] {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory),
          isDirectory.boolValue else { return [] }
    let entries = try FileManager.default.contentsOfDirectory(
        at: URL(fileURLWithPath: root, isDirectory: true),
        includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
        options: []
    )
    var files: [String] = []
    for entry in entries {
        let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
        if values.isRegularFile == true {
            files.append(entry.path)
        } else if values.isDirectory == true {
            files += try releaseNativeMacRegularFiles(under: entry.path)
        }
    }
    return files
}

private func releaseNativeMacHashRequiredFiles(_ paths: [String]) throws -> [String: String] {
    var hashes: [String: String] = [:]
    for path in paths.sorted() {
        try requireReleaseNativeMac(
            FileManager.default.fileExists(atPath: path),
            "release replay ledger required file missing: \(path)"
        )
        hashes[path] = try DoryComponentCatalogVerifier.fileDigest(path)
    }
    return hashes
}
private final class ReleaseNativeMacFaultRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var observed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func record() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

private final class NativeMacReleaseThreadCall<T>: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: Result<T, Error>?

    static func start(
        name: String,
        stackSize: Int = 8 * 1_024 * 1_024,
        _ body: @escaping @Sendable () throws -> T
    ) -> NativeMacReleaseThreadCall<T> {
        let call = NativeMacReleaseThreadCall<T>()
        let thread = Thread {
            let result = Result { try body() }
            call.condition.lock()
            call.result = result
            call.condition.signal()
            call.condition.unlock()
        }
        thread.name = name
        thread.stackSize = stackSize
        thread.start()
        return call
    }

    func resultIfFinished() -> Result<T, Error>? {
        condition.lock()
        defer { condition.unlock() }
        return result
    }

    func value() throws -> T {
        if Thread.isMainThread {
            while resultIfFinished() == nil {
                _ = RunLoop.current.run(
                    mode: .default,
                    before: Date().addingTimeInterval(0.01)
                )
            }
            return try resultIfFinished()!.get()
        }
        condition.lock()
        defer { condition.unlock() }
        while result == nil { condition.wait() }
        return try result!.get()
    }
}

private func waitForReleaseNativeMacStatus<T>(
    _ manager: MachineManager,
    id: String,
    timeout: TimeInterval,
    label: String,
    failingWhenFinished: NativeMacReleaseThreadCall<T>,
    predicate: (DoryMachineStatus) -> Bool
) throws -> DoryMachineStatus {
    let deadline = Date().addingTimeInterval(timeout)
    var last = manager.status(id: id)
    while Date() < deadline {
        if let result = failingWhenFinished.resultIfFinished() {
            switch result {
            case .success:
                break
            case let .failure(error):
                throw error
            }
        }
        if let status = manager.status(id: id) {
            last = status
            if predicate(status) { return status }
            if status.state == .failed {
                throw MachineManagerError.persistence("\(label) failed: \(releaseNativeMacStatusDetail(status))")
            }
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    throw MachineManagerError.persistence("timeout waiting for \(label): \(releaseNativeMacStatusDetail(last))")
}

private func requireReleaseNativeMacRecoveryPreconditions(
    machineID: String,
    machineDirectory: String,
    savedStateWrapperPath: String,
    lifecycleJournalHome: String
) throws {
    let bundle = try DoryVZMacMachineBundle.load(
        from: URL(fileURLWithPath: machineDirectory + "/Machine.dorymac", isDirectory: true)
    )
    try requireReleaseNativeMac(
        bundle.manifest.installationState == .stopped,
        "release recovery-only fixture must begin with the native Mac bundle already durably stopped"
    )
    try requireReleaseNativeMac(
        FileManager.default.fileExists(atPath: savedStateWrapperPath + "/manifest.json"),
        "release recovery-only fixture must begin with a retained saved-state manifest"
    )
    try requireReleaseNativeMac(
        !FileManager.default.fileExists(atPath: savedStateWrapperPath + "/state.bin"),
        "release recovery-only fixture must begin after partial saved-state payload removal"
    )
    let coldStopOperationID = UUID(uuidString: "ffffffff-1111-4222-8aaa-444444444444")!
    let record = try DoryOperationJournalStore(home: lifecycleJournalHome).read(coldStopOperationID)
    try requireReleaseNativeMac(
        record.plan.kind == .workspaceStop,
        "release recovery-only fixture must carry the interrupted cold-stop journal"
    )
    try requireReleaseNativeMac(
        record.state.status == .running && record.state.phase == .publishing,
        "release recovery-only fixture must begin with stop journal running/publishing"
    )
}

private func requireReleaseNativeMac(
    _ condition: @autoclosure () throws -> Bool,
    _ message: String
) throws {
    guard try condition() else { throw MachineManagerError.persistence(message) }
}

private func requireReleaseNativeMacStatus(
    _ status: DoryMachineStatus?,
    _ message: String
) throws -> DoryMachineStatus {
    guard let status else { throw MachineManagerError.persistence(message) }
    return status
}

private func requireReleaseNativeMacPlan(
    _ plan: DoryResolvedMachinePlan?,
    _ message: String
) throws -> DoryResolvedMachinePlan {
    guard let plan else { throw MachineManagerError.persistence(message) }
    return plan
}

private func releaseNativeMacTestSigningKeyPath(evidenceRoot: String) -> String {
    URL(fileURLWithPath: evidenceRoot, isDirectory: true)
        .appendingPathComponent("test-signing-key.raw", isDirectory: false)
        .standardizedFileURL.path
}

private func releaseNativeMacExistingFixtureSigningKeyPath(fixtureRoot: String) -> String {
    URL(fileURLWithPath: fixtureRoot, isDirectory: true)
        .deletingLastPathComponent()
        .appendingPathComponent("test-signing-key.raw", isDirectory: false)
        .standardizedFileURL.path
}

private func loadOrCreateReleaseNativeMacTestSigningKey(at path: String) throws -> Data {
    if FileManager.default.fileExists(atPath: path) {
        return try readReleaseNativeMacTestSigningKey(at: path)
    }
    let key = Curve25519.Signing.PrivateKey().rawRepresentation
    let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
    if fd < 0 {
        if errno == EEXIST { return try readReleaseNativeMacTestSigningKey(at: path) }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { close(fd) }
    try key.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return }
        var written = 0
        while written < rawBuffer.count {
            let count = write(fd, base.advanced(by: written), rawBuffer.count - written)
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard count > 0 else { throw POSIXError(.EIO) }
            written += count
        }
    }
    guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    try validateReleaseNativeMacTestSigningKeyDescriptor(fd)
    _ = try Curve25519.Signing.PrivateKey(rawRepresentation: key)
    return key
}

private func readReleaseNativeMacTestSigningKey(at path: String) throws -> Data {
    let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(fd) }
    try validateReleaseNativeMacTestSigningKeyDescriptor(fd)
    let data = try readReleaseNativeMacTestSigningKeyDescriptor(fd)
    _ = try Curve25519.Signing.PrivateKey(rawRepresentation: data)
    return data
}

private func validateReleaseNativeMacTestSigningKeyDescriptor(_ fd: Int32) throws {
    var info = stat()
    guard fstat(fd, &info) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    try requireReleaseNativeMac((info.st_mode & S_IFMT) == S_IFREG, "test signing key must be a regular file")
    try requireReleaseNativeMac(info.st_nlink == 1, "test signing key must have one link")
    try requireReleaseNativeMac(info.st_uid == geteuid(), "test signing key must be owned by this user")
    try requireReleaseNativeMac((info.st_mode & 0o077) == 0, "test signing key must not be group/world accessible")
    try requireReleaseNativeMac(info.st_size == 32, "test signing key must be one Curve25519 raw private key")
}

private func readReleaseNativeMacTestSigningKeyDescriptor(_ fd: Int32) throws -> Data {
    guard lseek(fd, 0, SEEK_SET) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    var bytes = [UInt8](repeating: 0, count: 32)
    var offset = 0
    while offset < bytes.count {
        let remaining = bytes.count - offset
        let count = bytes.withUnsafeMutableBytes { buffer in
            read(fd, buffer.baseAddress!.advanced(by: offset), remaining)
        }
        if count < 0 {
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard count > 0 else { throw POSIXError(.EIO) }
        offset += count
    }
    return Data(bytes)
}

private func releaseNativeMacSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func cloneOrCopyReleaseQualificationItem(source: String, destination: String) throws {
    let sourceURL = URL(fileURLWithPath: source)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: source, isDirectory: &isDirectory) else {
        throw MachineManagerError.persistence("source artifact is missing: \(source)")
    }
    if isDirectory.boolValue {
        try FileManager.default.createDirectory(
            atPath: destination,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let entries = try FileManager.default.contentsOfDirectory(
            at: sourceURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        for entry in entries {
            try cloneOrCopyReleaseQualificationItem(
                source: entry.path,
                destination: URL(fileURLWithPath: destination)
                    .appendingPathComponent(entry.lastPathComponent).path
            )
        }
        return
    }
    if clonefile(source, destination, 0) == 0 { return }
    let cloneErrno = errno
    if cloneErrno != ENOTSUP && cloneErrno != EXDEV {
        throw POSIXError(POSIXErrorCode(rawValue: cloneErrno) ?? .EIO)
    }
    try FileManager.default.copyItem(atPath: source, toPath: destination)
}

private func stableNativeMacReference(
    namespace: String,
    machineID: String,
    role: String,
    digest: String
) -> DoryVMResolverReference {
    let material = Data("\(machineID)\0\(role)\0\(digest)".utf8)
    let identifier = SHA256.hash(data: material).map {
        String(format: "%02x", $0)
    }.joined()
    return DoryVMResolverReference(namespace: namespace, identifier: identifier)
}

private func workspaceCreationTimestamp(machineDirectory: String) -> Int64 {
    var info = stat()
    guard lstat(machineDirectory, &info) == 0 else { return 1 }
    let time = info.st_birthtimespec.tv_sec > 0 ? info.st_birthtimespec : info.st_ctimespec
    guard time.tv_sec > 0 else { return 1 }
    let seconds = Int64(time.tv_sec)
    let (milliseconds, overflow) = seconds.multipliedReportingOverflow(by: 1_000)
    guard !overflow else { return Int64.max }
    let nanos = max(Int64(0), Int64(time.tv_nsec)) / 1_000_000
    let (result, additionOverflow) = milliseconds.addingReportingOverflow(nanos)
    return additionOverflow ? Int64.max : result
}

private func writeReleaseNativeMacFixtureDescriptor(
    root: String,
    fixtureRoot: String,
    dataDriveRoot: String,
    stateDirectory: String,
    helperExecutablePath: String,
    helperSHA256: String,
    gvproxyPath: String,
    testSigningKeyPath: String,
    testSigningKeySHA256: String
) throws {
    let descriptor = ReleaseNativeMacFixtureDescriptor(
        schema: "dory.release-activation-native-mac-fixture-descriptor@1",
        fixtureRoot: fixtureRoot,
        dataDriveRoot: dataDriveRoot,
        stateDirectory: stateDirectory,
        machineID: "native-mac-release-daemon",
        helperExecutablePath: helperExecutablePath,
        helperSHA256: helperSHA256,
        gvproxyPath: gvproxyPath,
        testSigningKeyPath: testSigningKeyPath,
        testSigningKeySHA256: testSigningKeySHA256,
        armVirtFirmwareBundlePath: URL(fileURLWithPath: fixtureRoot, isDirectory: true)
            .appendingPathComponent("armvirt-firmware", isDirectory: true).path,
        logDirectory: URL(fileURLWithPath: fixtureRoot, isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true).path,
        requiresReadyHandoff: true,
        passMachineArguments: true,
        handoffReadyTimeoutSeconds: 240,
        desktopHandoffReadyTimeoutSeconds: 240,
        macOSRestoreHandoffReadyTimeoutSeconds: 240,
        startupRestartPolicy: "none",
        runtimeDirectoryPolicy: "ephemeral-restart-only"
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try (encoder.encode(descriptor) + Data("\n".utf8)).write(
        to: URL(fileURLWithPath: root + "/fixture-descriptor.json"),
        options: .atomic
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: root + "/fixture-descriptor.json"
    )
}

private func readReleaseNativeMacFixtureDescriptor(
    fixtureRoot: String
) throws -> ReleaseNativeMacFixtureDescriptor? {
    let descriptorPath = URL(fileURLWithPath: fixtureRoot, isDirectory: true)
        .deletingLastPathComponent()
        .appendingPathComponent("fixture-descriptor.json")
        .standardizedFileURL.path
    guard FileManager.default.fileExists(atPath: descriptorPath) else { return nil }
    let data = try Data(contentsOf: URL(fileURLWithPath: descriptorPath))
    let descriptor = try JSONDecoder().decode(ReleaseNativeMacFixtureDescriptor.self, from: data)
    try requireReleaseNativeMac(
        descriptor.schema == "dory.release-activation-native-mac-fixture-descriptor@1",
        "release fixture descriptor schema is unsupported"
    )
    return descriptor
}

private func validateReleaseNativeMacFixtureDescriptor(
    _ descriptor: ReleaseNativeMacFixtureDescriptor,
    fixtureRoot: String,
    dataDriveRoot: String,
    stateDirectory: String,
    helperPath: String,
    helperSHA256: String,
    signingKeyPath: String,
    signingKeySHA256: String,
    machineID: String
) throws {
    try requireReleaseNativeMac(
        descriptor.fixtureRoot == fixtureRoot,
        "release fixture descriptor root does not match the selected fixture"
    )
    try requireReleaseNativeMac(
        descriptor.dataDriveRoot == dataDriveRoot,
        "release fixture descriptor data-drive root does not match inspection"
    )
    try requireReleaseNativeMac(
        descriptor.stateDirectory == stateDirectory,
        "release fixture descriptor state directory does not match inspection"
    )
    try requireReleaseNativeMac(
        descriptor.machineID == machineID,
        "release fixture descriptor machine id does not match replay target"
    )
    try requireReleaseNativeMac(
        descriptor.helperExecutablePath == helperPath && descriptor.helperSHA256 == helperSHA256,
        "release fixture descriptor helper identity does not match replay helper"
    )
    try requireReleaseNativeMac(
        descriptor.testSigningKeyPath == signingKeyPath
            && descriptor.testSigningKeySHA256 == signingKeySHA256,
        "release fixture descriptor signing key identity does not match replay key"
    )
    try requireReleaseNativeMac(
        descriptor.passMachineArguments
            && descriptor.requiresReadyHandoff
            && descriptor.startupRestartPolicy == "none"
            && descriptor.runtimeDirectoryPolicy == "ephemeral-restart-only",
        "release fixture descriptor launch policy is unsupported"
    )
    try requireReleaseNativeMac(
        FileManager.default.fileExists(atPath: descriptor.armVirtFirmwareBundlePath),
        "release fixture descriptor ARM firmware path is missing"
    )
}

private func writeReleaseManagedNativeMacEvidence(
    root: String,
    fixtureRoot: String,
    machineID: String,
    machineDirectory: String,
    bundlePath: String,
    helperExecutablePath: String,
    helperSHA256: String,
    testSigningKeyPath: String,
    testSigningKeySHA256: String,
    activationPlanRevision: UInt64,
    startStatus: DoryMachineStatus,
    suspendedStatus: DoryMachineStatus,
    restoredStatus: DoryMachineStatus,
    closedStatus: DoryMachineStatus,
    stoppedStatus: DoryMachineStatus,
    normalColdRestartStatus: DoryMachineStatus,
    faultReadySuspendStatus: DoryMachineStatus,
    recoveredStatus: DoryMachineStatus,
    recoveredColdStartStatus: DoryMachineStatus,
    finalSuspendStatus: DoryMachineStatus,
    finalStopStatus: DoryMachineStatus,
    closedSavedStateBytes: UInt64?,
    partialPayloadRemovedBeforeRecovery: Bool
) throws {
    try FileManager.default.createDirectory(
        atPath: root,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let savedStatePath = machineDirectory + "/saved-state-v1/state.bin"
    let savedStateWrapperPresentAfterColdStop = FileManager.default.fileExists(
        atPath: machineDirectory + "/saved-state-v1"
    )
    let restoreImagePresentAtReceipt = FileManager.default.fileExists(
        atPath: machineDirectory + "/Restore.ipsw"
    )
    let bundle = try DoryVZMacMachineBundle.load(
        from: URL(fileURLWithPath: bundlePath, isDirectory: true)
    )
    let payload: [String: Any] = [
        "schema": "dory.release-activation-native-mac-saved-state-qualification@1",
        "scope": "private signed doryd-identity host using ProductionTrustFactory.activate with fixture host admission facts, fixture-signed catalog authority, and substituted runtime verifier; not installed launchd daemon, production catalog trust, or real host-probe qualification",
        "recordedAtUnix": Date().timeIntervalSince1970,
        "hostPID": Int(getpid()),
        "fixtureRoot": fixtureRoot,
        "machineID": machineID,
        "machineDirectory": machineDirectory,
        "bundlePath": bundlePath,
        "helperExecutablePath": helperExecutablePath,
        "helperSHA256": helperSHA256,
        "testSigningKeyPath": testSigningKeyPath,
        "testSigningKeySHA256": testSigningKeySHA256,
        "sourceSHA256": try releaseNativeMacSourceHashes(),
        "activationPlanRevision": activationPlanRevision,
        "manifestInstallationState": bundle.manifest.installationState.rawValue,
        "manifestMachineIdentifierSHA256": bundle.manifest.machineIdentifierSHA256,
        "manifestHardwareModelSHA256": bundle.manifest.hardwareModelSHA256,
        "savedStatePath": savedStatePath,
        "closedSavedStateBytes": closedSavedStateBytes as Any,
        "savedStateWrapperPresentAfterColdStop": savedStateWrapperPresentAfterColdStop,
        "restoreImagePresentAtReceipt": restoreImagePresentAtReceipt,
        "partialPayloadRemovedBeforeRecovery": partialPayloadRemovedBeforeRecovery,
        "statuses": [
            "start": releaseNativeMacEvidenceStatus(startStatus),
            "suspend": releaseNativeMacEvidenceStatus(suspendedStatus),
            "restore": releaseNativeMacEvidenceStatus(restoredStatus),
            "close": releaseNativeMacEvidenceStatus(closedStatus),
            "coldStop": releaseNativeMacEvidenceStatus(stoppedStatus),
            "normalColdRestart": releaseNativeMacEvidenceStatus(normalColdRestartStatus),
            "faultReadySuspend": releaseNativeMacEvidenceStatus(faultReadySuspendStatus),
            "recoveredAfterPartialDiscard": releaseNativeMacEvidenceStatus(recoveredStatus),
            "recoveredColdStart": releaseNativeMacEvidenceStatus(recoveredColdStartStatus),
            "finalSuspend": releaseNativeMacEvidenceStatus(finalSuspendStatus),
            "finalStop": releaseNativeMacEvidenceStatus(finalStopStatus),
        ],
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    try (data + Data("\n".utf8)).write(to: URL(fileURLWithPath: root + "/receipt.json"), options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root + "/receipt.json")
}

private func writeReleaseManagedNativeMacRestartOnlyEvidence(
    root: String,
    sourceFixturePath: String,
    helperExecutablePath: String,
    helperSHA256: String,
    testSigningKeyPath: String,
    testSigningKeySHA256: String,
    machineID: String,
    machineDirectory: String,
    reopenMode: String,
    startStatus: DoryMachineStatus?,
    startError: String?,
    before: ReleaseNativeMacReplayLedger,
    after: ReleaseNativeMacReplayLedger
) throws {
    try FileManager.default.createDirectory(
        atPath: root,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let payload: [String: Any] = [
        "schema": "dory.release-activation-native-mac-restart-only-qualification@1",
        "scope": "private signed doryd-identity host reopening an existing task-owned fixture through ProductionTrustFactory.activate without calling ProductionTrustFixture.create; validates key/helper/catalog/trust-floor pre/post ledgers and probes stopped installed native Mac cold start",
        "recordedAtUnix": Date().timeIntervalSince1970,
        "hostPID": Int(getpid()),
        "sourceFixturePath": sourceFixturePath,
        "machineID": machineID,
        "machineDirectory": machineDirectory,
        "reopenMode": reopenMode,
        "helperExecutablePath": helperExecutablePath,
        "helperSHA256": helperSHA256,
        "testSigningKeyPath": testSigningKeyPath,
        "testSigningKeySHA256": testSigningKeySHA256,
        "sourceSHA256": try releaseNativeMacSourceHashes(),
        "startError": startError ?? NSNull(),
        "startStatus": startStatus.map(releaseNativeMacEvidenceStatus) ?? NSNull(),
        "preReplayLedger": try releaseNativeMacJSONValue(before),
        "postReplayLedger": try releaseNativeMacJSONValue(after),
        "trustCriticalUnchanged": before.trustCritical == after.trustCritical,
        "machineControlUnchanged": before.machineControl == after.machineControl,
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    try (data + Data("\n".utf8)).write(
        to: URL(fileURLWithPath: root + "/restart-only-receipt.json"),
        options: .atomic
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: root + "/restart-only-receipt.json"
    )
}

private func writeReleaseManagedNativeMacRecoveryOnlyEvidence(
    root: String,
    sourceFixturePath: String,
    fixtureRoot: String,
    machineID: String,
    machineDirectory: String,
    helperExecutablePath: String,
    helperSHA256: String,
    recoveredStatus: DoryMachineStatus
) throws {
    try FileManager.default.createDirectory(
        atPath: root,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let sourceSigningKeyPath = releaseNativeMacExistingFixtureSigningKeyPath(
        fixtureRoot: sourceFixturePath
    )
    let sourceSigningKeyHash = releaseNativeMacRecoverySigningKeyHash(
        sourceFixturePath: sourceFixturePath
    )
    let payload: [String: Any] = [
        "schema": "dory.release-activation-native-mac-recovery-only-qualification@1",
        "scope": "private signed doryd-identity host constructing a fresh MachineManager over the original task-owned failed fixture root; verifies native Mac cold-stop saved-state discard recovery without launching Apple Virtualization.framework or a guest; production-factory activation remains separately open",
        "recordedAtUnix": Date().timeIntervalSince1970,
        "hostPID": Int(getpid()),
        "sourceFixturePath": sourceFixturePath,
        "fixtureRoot": fixtureRoot,
        "machineID": machineID,
        "machineDirectory": machineDirectory,
        "helperExecutablePath": helperExecutablePath,
        "helperSHA256": helperSHA256,
        "testSigningKeyPath": sourceSigningKeyPath,
        "testSigningKeySHA256": sourceSigningKeyHash ?? NSNull(),
        "sourceSHA256": try releaseNativeMacSourceHashes(),
        "savedStateWrapperPresentAfterRecovery": FileManager.default.fileExists(
            atPath: machineDirectory + "/saved-state-v1"
        ),
        "recoveredStatus": releaseNativeMacEvidenceStatus(recoveredStatus),
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    try (data + Data("\n".utf8)).write(
        to: URL(fileURLWithPath: root + "/recovery-only-receipt.json"),
        options: .atomic
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: root + "/recovery-only-receipt.json"
    )
}

private func releaseNativeMacRecoverySigningKeyHash(sourceFixturePath: String) -> String? {
    let keyPath = releaseNativeMacExistingFixtureSigningKeyPath(
        fixtureRoot: sourceFixturePath
    )
    guard let data = try? readReleaseNativeMacTestSigningKey(at: keyPath) else { return nil }
    return releaseNativeMacSHA256(data)
}

private func releaseNativeMacJSONValue<T: Encodable>(_ value: T) throws -> Any {
    let data = try JSONEncoder().encode(value)
    return try JSONSerialization.jsonObject(with: data)
}

private func releaseNativeMacSourceHashes(
    testFilePath: String = #filePath
) throws -> [String: String] {
    let paths = [
        "dory-core-swift/Sources/DorydKit/MachineManager.swift",
        "dory-core-swift/Tests/DorydKitTests/DoryDaemonVirtualMachineProductionTrustTests.swift",
        "dory-core-swift/Tests/DorydKitTests/DoryDaemonNativeMacReleaseActivationQualificationTests.swift",
    ]
    let repositoryRoot = URL(fileURLWithPath: testFilePath, isDirectory: false)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    var hashes: [String: String] = [:]
    for path in paths {
        let url = repositoryRoot.appendingPathComponent(path, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MachineManagerError.persistence(
                "release source hash path is unavailable: \(path)"
            )
        }
        let data = try Data(contentsOf: url)
        hashes[path] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    return hashes
}

private func releaseNativeMacEvidenceStatus(_ status: DoryMachineStatus) -> [String: Any] {
    [
        "state": status.state.rawValue,
        "pid": status.pid.map(Int.init) as Any,
        "savedStatePresent": status.savedState != nil,
        "runtimePlanRevision": status.runtimeIdentity.resolvedPlan?.planRevision as Any,
        "controlSocketPath": status.controlSocketPath as Any,
        "handoffSocketPath": status.handoffSocketPath as Any,
        "activeOperationID": status.activeOperationID as Any,
        "lastError": status.lastError as Any,
    ]
}

private func releaseNativeMacStatusDetail(_ status: DoryMachineStatus?) -> String {
    guard let status else { return "<missing>" }
    return "state=\(status.state.rawValue) pid=\(String(describing: status.pid)) op=\(String(describing: status.activeOperationID)) error=\(status.lastError ?? "")"
}
#endif
