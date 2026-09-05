import CryptoKit
import Darwin
import DoryOperations
@testable import DorydKit
import DoryVZMacCore
import Foundation
import Testing
import XCTest

@Suite("Production VM planning composition")
struct DoryDaemonVirtualMachineProductionPlanningCompositionTests {
    @Test("authorizer and recovery provider are both mandatory")
    func dependenciesAreMandatory() throws {
        let fixture = try CompositionFixture(ids: [])
        for (hasAuthorizer, hasRecovery, expected) in [
            (false, true,
             DoryDaemonVirtualMachineProductionPlanningCompositionFailureCode
                .mutationAuthorityUnavailable),
            (true, false,
             .recoveryAuthorityUnavailable),
        ] {
            let result = fixture.factory(
                hasMutationAuthority: hasAuthorizer,
                hasRecoveryProvider: hasRecovery
            ).resolve()
            guard case let .unavailable(failure) = result else {
                Issue.record("Expected unavailable planning composition")
                continue
            }
            #expect(failure.code == expected)
            #expect(!result.planningTransactionAvailable)
        }
    }

    @Test("durable recovery completes before readiness is exposed")
    func recoveryPrecedesReadiness() throws {
        let fixture = try CompositionFixture(ids: ["recover-one"])
        try fixture.interrupt("recover-one", at: .planBindingCommitted)

        let readiness = fixture.factory().resolve()
        let context = try readyContext(readiness)
        #expect(fixture.events.values.contains("recovery:recover-one"))
        #expect(fixture.events.values.contains("mutation:recover-one"))
        #expect(context.recoveredTransactionIDs.keys.sorted() == ["recover-one"])
        #expect(try context.plans.read(id: "recover-one").machineID == "recover-one")
        #expect(readiness.planningTransactionAvailable)
    }

    @Test("completed planning history does not replay obsolete desired state during activation")
    func completedPlanningHistoryDoesNotMutate() throws {
        let fixture = try CompositionFixture(ids: ["completed-a"])
        try fixture.interrupt("completed-a", at: .completeJournalPublished)
        let before = fixture.events.values
        let context = try readyContext(fixture.factory().resolve())
        #expect(context.recoveredTransactionIDs.isEmpty)
        #expect(fixture.events.values.filter { $0.hasPrefix("mutation:") } == before.filter { $0.hasPrefix("mutation:") })
        #expect(fixture.recovery.requestedIDs.isEmpty)
    }

    @Test("corrupt planning journal prevents readiness")
    func corruptJournalFailsClosed() throws {
        let fixture = try CompositionFixture(ids: ["corrupt-one"])
        let directory = fixture.root + "/corrupt-one"
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("not-json\n".utf8).write(
            to: URL(fileURLWithPath: directory + "/planning-transaction-v1.json")
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: directory + "/planning-transaction-v1.json"
        )

        guard case let .unavailable(failure) = fixture.factory().resolve() else {
            Issue.record("Expected corrupt recovery to fail closed")
            return
        }
        #expect(failure.code == .recoveryFailed)
        #expect(failure.machineID == "corrupt-one")
        #expect(throws: DoryResolvedMachinePlanRepositoryError.self) {
            _ = try fixture.plans.read(id: "corrupt-one")
        }
    }

    @Test("recovery is isolated per workspace and uses exact repository roots")
    func crossWorkspaceIsolationAndIdentity() throws {
        let ids = ["recover-a", "recover-b"]
        let fixture = try CompositionFixture(ids: ids)
        try fixture.interrupt("recover-b", at: .workspacePublished)
        try fixture.interrupt("recover-a", at: .candidateJournalPublished)

        let context = try readyContext(fixture.factory().resolve())
        #expect(context.recoveredTransactionIDs.keys.sorted() == ids)
        #expect(fixture.recovery.requestedIDs == ids)
        #expect(context.identity.stateDirectory == fixture.root)
        #expect(context.workspaces.root == context.identity.workspaceRepositoryRoot)
        #expect(context.plans.root == context.identity.resolvedPlanRepositoryRoot)
        #expect(context.artifactAuthority.root == context.identity.artifactAuthorityRoot)
        #expect(context.resourceLedger.root
            == context.identity.resourceAdmissionLedgerRoot)
        for id in ids {
            #expect(try context.workspaces.read(id: id).identity.id == id)
            #expect(try context.plans.read(id: id).machineID == id)
        }
        #expect(try context.resourceLedger.snapshot().leases.count == 2)
    }

    @Test("production recovery replays only the exact private machine authority")
    func productionRecoveryReplaysExactMachineAuthority() throws {
        let machineID = "production-recovery-a"
        let fixture = try CompositionFixture(ids: [machineID])
        try fixture.interrupt(machineID, at: .planBindingCommitted)
        try fixture.writeMachineAuthority(machineID)

        let provider = DoryDaemonVirtualMachineProductionRecoveryProvider(
            stateDirectory: fixture.root
        )
        let context = try readyContext(fixture.factory(
            recoveryProvider: provider
        ).resolve())

        #expect(context.recoveredTransactionIDs.keys.sorted() == [machineID])
        #expect(try context.plans.read(id: machineID).machineID == machineID)
    }

    @Test("stale private machine authority cannot replay a durable journal")
    func staleProductionMachineAuthorityFailsClosed() throws {
        let machineID = "stale-production-recovery-b"
        let fixture = try CompositionFixture(ids: [machineID])
        try fixture.interrupt(machineID, at: .planBindingCommitted)
        try fixture.writeMachineAuthority(machineID) { machine in
            machine.cpuCount += 1
        }

        let provider = DoryDaemonVirtualMachineProductionRecoveryProvider(
            stateDirectory: fixture.root
        )
        guard case let .unavailable(failure) = fixture.factory(
            recoveryProvider: provider
        ).resolve() else {
            Issue.record("Expected stale private authority to fail closed")
            return
        }
        #expect(failure.code == .recoveryFailed)
        #expect(failure.machineID == machineID)
        #expect(throws: DoryResolvedMachinePlanRepositoryError.self) {
            _ = try fixture.plans.read(id: machineID)
        }
    }

    @Test("native Mac saved-state replan renews mutable disk provenance through production authority")
    func nativeMacSavedStateReplanRenewsMutableDiskProvenance() throws {
        let machineID = "native-mac-saved-state"
        let fixture = try CompositionFixture(ids: [])
        let native = try fixture.nativeMacPreparedRequest(id: machineID)
        let trust = CompositionArtifactAuthorityTrust(
            root: fixture.root,
            artifactAuthority: native.artifactAuthority,
            machineID: native.request.planning.definition.identity.id,
            restoreReference: native.restoreReference,
            restoreImageBuild: "25G83"
        )
        let coordinator = fixture.coordinator(
            trust: trust,
            capabilityPlanner: DoryAppleSiliconDaemonVirtualMachineCapabilityPlanner()
        )
        let controller = DoryDaemonVirtualMachineProductionPlanningController(
            artifactAuthority: native.artifactAuthority,
            coordinator: coordinator,
            workspaces: fixture.workspaces,
            plans: fixture.plans
        )

        let initial = try controller.resolveReserveAndPublish(
            native.request,
            artifacts: native.publications(expectedDiskRevision: nil)
        )
        let initialPlan = initial.planning.resolvedPlan
        let initialDisk = try #require(initialPlan.launchArtifacts.first { artifact in
            artifact.usages.contains { $0.kind == .storage && $0.identifier == "system" }
        })
        #expect(initialPlan.backend == .appleVirtualizationFramework)
        #expect(initialPlan.bootMedia.media.kind == .macOSRestoreImage)
        #expect(initialDisk.authorityRevision == 1)
        #expect(initialDisk.media.mutableProvenance?.revision == 1)
        try native.artifactAuthority.validateBackingOwnership(
            reference: initialDisk.resolverReference,
            path: native.diskPath,
            media: initialDisk.media,
            authorityRevision: initialDisk.authorityRevision,
            mutableProvenanceEvidence: initialDisk.mutableProvenanceEvidence
        )

        _ = try fixture.ledger.markStopped(
            leaseID: initial.lease.leaseID,
            expectedLeaseRevision: initial.lease.leaseRevision
        )
        try native.writeGuestDiskByte(0x6d)
        #expect(throws: DoryVirtualMachineArtifactAuthorityError.self) {
            _ = try native.artifactAuthority.resolve(
                reference: native.diskReference,
                kind: .virtualDisk,
                source: .userProvided
            )
        }
        try native.artifactAuthority.validateBackingOwnership(
            reference: initialDisk.resolverReference,
            path: native.diskPath,
            media: initialDisk.media,
            authorityRevision: initialDisk.authorityRevision,
            mutableProvenanceEvidence: initialDisk.mutableProvenanceEvidence
        )

        let refreshRequest = try native.replanningRequest(
            operationID: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!,
            expectedPlanRevision: initialPlan.planRevision
        )
        let interrupted = fixture.coordinator(
            trust: trust,
            capabilityPlanner: DoryAppleSiliconDaemonVirtualMachineCapabilityPlanner(),
            fault: CompositionFault(.planBindingCommitted)
        )
        let interruptedController = DoryDaemonVirtualMachineProductionPlanningController(
            artifactAuthority: native.artifactAuthority,
            coordinator: interrupted,
            workspaces: fixture.workspaces,
            plans: fixture.plans
        )
        #expect(throws: (any Error).self) {
            _ = try interruptedController.resolveReserveAndPublish(
                refreshRequest,
                artifacts: native.publications(expectedDiskRevision: initialDisk.authorityRevision)
            )
        }
        let descriptor = try #require(try coordinator.recoveryDescriptor(for: machineID))
        #expect(!descriptor.isComplete)
        #expect(descriptor.matches(refreshRequest))

        let refreshed = try controller.resolveReserveAndPublish(
            refreshRequest,
            artifacts: native.publications(expectedDiskRevision: initialDisk.authorityRevision)
        )
        let refreshedPlan = refreshed.planning.resolvedPlan
        let refreshedDisk = try #require(refreshedPlan.launchArtifacts.first { artifact in
            artifact.usages.contains { $0.kind == .storage && $0.identifier == "system" }
        })
        #expect(refreshedPlan.planRevision == initialPlan.planRevision + 1)
        #expect(refreshedDisk.authorityRevision == initialDisk.authorityRevision + 1)
        #expect(refreshedDisk.media.mutableProvenance?.revision == initialDisk.authorityRevision + 1)
        #expect(refreshedDisk.mutableProvenanceEvidence?.provenance == refreshedDisk.media.mutableProvenance)
        #expect(refreshedPlan != initialPlan)

        let runtimeIdentity = try DoryMachineRuntimeIdentity(
            resolvedPlan: refreshedPlan,
            planSHA256: refreshed.planning.resolvedPlanSHA256
        )
        let manifest = try native.publishSavedStateManifest(runtimeIdentity: runtimeIdentity)
        #expect(manifest.runtimeIdentity == runtimeIdentity)
        #expect(manifest.runtimeIdentity.resolvedPlan?.planRevision == refreshedPlan.planRevision)
        #expect(native.inspectSavedState(runtimeIdentity: runtimeIdentity) == .valid(manifest))
        #expect(native.inspectSavedState(
            runtimeIdentity: try DoryMachineRuntimeIdentity(
                resolvedPlan: initialPlan,
                planSHA256: initial.planning.resolvedPlanSHA256
            )
        ) != .valid(manifest))
    }

    @Test(
        "native Mac MachineManager suspend renews mutable disk provenance with a real prepared bundle",
        .enabled(if: ProcessInfo.processInfo.environment["DORY_NATIVE_MAC_IPSW"] != nil
            && ProcessInfo.processInfo.environment["DORY_NATIVE_MAC_PREPARED_BUNDLE"] != nil)
    )
    func nativeMacMachineManagerSuspendRenewsMutableDiskProvenance() async throws {
        try runNativeMacMachineManagerSuspendRenewsMutableDiskProvenance()
    }

    private func runNativeMacMachineManagerSuspendRenewsMutableDiskProvenance() throws {
        let environment = ProcessInfo.processInfo.environment
        let ipswPath = try #require(environment["DORY_NATIVE_MAC_IPSW"])
        let preparedBundlePath = try #require(environment["DORY_NATIVE_MAC_PREPARED_BUNDLE"])
        guard FileManager.default.isReadableFile(atPath: ipswPath),
              FileManager.default.isReadableFile(
                atPath: preparedBundlePath + "/" + DoryVZMacMachineBundle.manifestName
              ) else {
            throw CompositionTestError.invalidAuthority
        }
        let machineID = "native-mac-manager-saved-state"
        let fixture = try CompositionFixture(ids: [])
        let helperRoot = "/tmp/dory-vzmac-fixture-\(getpid())-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(
            atPath: helperRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        var removeHelperRoot = false
        defer { if removeHelperRoot { try? FileManager.default.removeItem(atPath: helperRoot) } }
        let helper = try NativeMacManagerHelper(root: helperRoot)
        let helperExecutablePath = helper.executablePath
        let managerRuntimeRoot = helper.managerRuntimeRoot
        let managerState = fixture.root + "/manager-state"
        let machineDirectory = managerState + "/" + machineID
        let restorePath = machineDirectory + "/Restore.ipsw"
        let bundlePath = machineDirectory + "/Machine.dorymac"
        try FileManager.default.createDirectory(
            atPath: machineDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try cloneOrCopyPhysicalFixtureItem(source: ipswPath, destination: restorePath)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: restorePath)
        try cloneOrCopyPhysicalFixtureItem(source: preparedBundlePath, destination: bundlePath)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bundlePath)
        let preparedBundle = try DoryVZMacMachineBundle.load(
            from: URL(fileURLWithPath: bundlePath, isDirectory: true)
        )
        let seededMachine = DoryMachineConfiguration(
            id: machineID,
            guestFamily: .macOS,
            guestArchitecture: .arm64,
            kernelPath: "",
            rootfsPath: "",
            bootMode: .macOSRestore,
            macOSRestoreImagePath: restorePath,
            macOSMachineBundlePath: bundlePath,
            diskSizeBytes: preparedBundle.manifest.resources.diskBytes,
            memoryMB: preparedBundle.manifest.resources.memoryBytes / 1_048_576,
            cpuCount: preparedBundle.manifest.resources.cpuCount,
            displayMode: .desktop
        )
        let machineEncoder = JSONEncoder()
        machineEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let seededMachineData = try machineEncoder.encode(seededMachine)
        try seededMachineData.write(
            to: URL(fileURLWithPath: machineDirectory + "/machine.json"),
            options: Data.WritingOptions.atomic
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: machineDirectory + "/machine.json"
        )
        let artifactAuthority = DoryVirtualMachineArtifactAuthority(
            root: fixture.root + "/.manager-artifact-authority"
        )
        let managerWorkspaces = DoryWorkspaceRepository(root: managerState)
        let restoreReference = NativeMacCompositionMaterial.artifactReference(
            namespace: "macos-restore",
            machineID: machineID,
            role: "restore-image",
            digest: preparedBundle.manifest.restoreImageSHA256
        )
        let diskReference = NativeMacCompositionMaterial.artifactReference(
            namespace: "macos-machine",
            machineID: machineID,
            role: "system-disk",
            digest: preparedBundle.manifest.machineIdentifierSHA256
        )
        do {
            _ = try artifactAuthority.publishImmutable(
                reference: restoreReference,
                path: restorePath,
                kind: .macOSRestoreImage,
                source: .userProvided,
                expectedSHA256: preparedBundle.manifest.restoreImageSHA256
            )
        } catch {
            throw MachineManagerError.persistence(
                "publish native Mac restore artifact \(restorePath): \(error)"
            )
        }
        do {
            _ = try artifactAuthority.publishMutable(
                reference: diskReference,
                path: bundlePath + "/" + DoryVZMacMachineBundle.diskName,
                source: .userProvided
            )
        } catch {
            throw MachineManagerError.persistence(
                "publish native Mac disk artifact \(bundlePath)/\(DoryVZMacMachineBundle.diskName): \(error)"
            )
        }
        try managerWorkspaces.create(try NativeMacCompositionMaterial.definition(
            id: machineID,
            restoreReference: restoreReference,
            diskReference: diskReference,
            cpuCount: UInt64(preparedBundle.manifest.resources.cpuCount),
            memoryBytes: preparedBundle.manifest.resources.memoryBytes,
            diskBytes: preparedBundle.manifest.resources.diskBytes,
            audio: DoryVMAudioConfiguration(inputEnabled: true, outputEnabled: true),
            integrations: [.clipboard, .dynamicDisplay, .gracefulShutdown],
            createdAtUnixMilliseconds: NativeMacCompositionMaterial.workspaceCreationTimestamp(
                machineDirectory: machineDirectory
            )
        ))
        let trust = CompositionArtifactAuthorityTrust(
            root: fixture.root + "/manager-state",
            artifactAuthority: artifactAuthority,
            machineID: machineID,
            restoreImageBuild: "25G83",
            runtimeComponentSHA256: try compositionFileSHA256(path: helperExecutablePath)
        )
        let managerConfiguration = MachineManagerConfiguration(
            vmmExecutablePath: helperExecutablePath,
            stateDirectory: fixture.root + "/manager-state",
            runtimeDirectory: managerRuntimeRoot,
            lifecycleJournalHome: fixture.root + "/manager-journal",
            passMachineArguments: true,
            requiresReadyHandoff: true,
            handoffReadyTimeoutSeconds: 150,
            desktopHandoffReadyTimeoutSeconds: 150,
            macOSRestoreHandoffReadyTimeoutSeconds: 150,
            startupRestartPolicy: .none
        )
        let manager = MachineManager(
            diagnosticConfiguration: managerConfiguration,
            launchPolicy: .perWorkspaceAuthority,
            vzLifecycleController: helper.controller
        )
        let launchOperations = manager.resolvedLaunchCompatibilityOperations(
            for: .appleVirtualizationFramework
        )
        let launchRegistry = try BackendRegistry(backends: [
            VirtualizationFrameworkLinuxMachineBackend(
                executablePath: helperExecutablePath,
                operations: launchOperations,
                executableIsAvailable: { _ in true }
            ),
        ])
        let coordinator = DoryDaemonVirtualMachinePlanningTransactionCoordinator(
            stateDirectory: fixture.root,
            registry: launchRegistry,
            trust: trust,
            mutationAuthority: manager,
            workspaces: managerWorkspaces,
            plans: fixture.plans,
            ledger: fixture.ledger,
            capabilityPlanner: DoryAppleSiliconDaemonVirtualMachineCapabilityPlanner(),
            now: { 1_700_000_000_100 }
        )
        let controller = DoryDaemonVirtualMachineProductionPlanningController(
            artifactAuthority: artifactAuthority,
            coordinator: coordinator,
            workspaces: managerWorkspaces,
            plans: fixture.plans
        )
        let startEvidence = DoryDaemonVirtualMachineStartEvidenceCollector(
            registry: launchRegistry,
            inventory: trust
        )
        let launchResolver = DoryDaemonVirtualMachineLaunchPlanResolver(
            registry: launchRegistry,
            plans: fixture.plans,
            evidenceCollector: startEvidence
        )
        try manager.installResolvedLaunchInfrastructure(
            registry: launchRegistry,
            resolver: launchResolver,
            plans: fixture.plans,
            expectedPlanRevision: { id in try? fixture.plans.read(id: id).planRevision },
            productionPlanningController: controller,
            resourceAdmissionLedger: fixture.ledger
        )

        helper.controller.bundlePath = bundlePath

        try? FileManager.default.removeItem(atPath: helper.exitMarkerPath)
        let startCall = NativeMacPhysicalFixtureThreadCall.start(name: "dory-native-mac-start") {
            try manager.start(
                id: machineID,
                operationID: UUID(uuidString: "33333333-4444-4555-8666-777777777777")!
            )
        }
        do {
            let starting = try waitForNativeManagerStatus(
                manager,
                id: machineID,
                timeout: 300,
                label: "start handoff",
                failingWhenFinished: startCall
            ) {
                $0.state == .starting && $0.handoffSocketPath != nil
            }
            let controlSocketPath = nativeHelperControlSocketPath(
                handoffSocketPath: try #require(starting.handoffSocketPath)
            )
            try waitForNativeHelperControlSocket(
                controlSocketPath,
                manager: manager,
                id: machineID,
                call: startCall,
                label: "start control socket"
            )
            try sendVmmHandoff(
                path: try #require(starting.handoffSocketPath),
                ready: VmmReadyMessage(
                    machineID: machineID,
                    operationID: starting.activeOperationID,
                    controlSocketPath: controlSocketPath
                ),
                fileDescriptors: []
            )
        } catch {
            _ = try? startCall.value()
            throw error
        }
        let startedStatus = try startCall.value()
        try requireNativeMacManager(
            startedStatus.state == .running,
            "fake-helper start should publish running status; \(nativeManagerStatusDetail(startedStatus))"
        )
        _ = try waitForNativeManagerStatus(
            manager,
            id: machineID,
            timeout: 60,
            label: "start running"
        ) {
            $0.state == .running
        }
        let initialIdentity = try #require(manager.runtimeIdentity(id: machineID))
        let initialPlan = try fixture.plans.read(id: machineID)
        try NativeMacCompositionMaterial.writeGuestDiskByte(
            at: bundlePath + "/" + DoryVZMacMachineBundle.diskName,
            byte: 0x7a
        )

        let suspended = try NativeMacPhysicalFixtureThreadCall.start(name: "dory-native-mac-suspend") {
            try manager.suspend(
                id: machineID,
                operationID: UUID(uuidString: "44444444-5555-4666-8777-888888888888")!
            )
        }.value()
        try requireNativeMacManager(suspended.state == .suspended, "suspend should publish suspended status")
        #expect(helper.controller.saveCount == 1)
        let refreshedIdentity = try #require(manager.runtimeIdentity(id: machineID))
        let refreshedPlan = try fixture.plans.read(id: machineID)
        try requireNativeMacManager(
            refreshedPlan.planRevision == initialPlan.planRevision + 1,
            "suspend should refresh native Mac plan revision"
        )
        try requireNativeMacManager(
            refreshedIdentity.planRevision == refreshedPlan.planRevision,
            "runtime identity should adopt refreshed plan revision"
        )
        try requireNativeMacManager(
            refreshedIdentity.planRevision != initialIdentity.planRevision,
            "runtime identity should change after native Mac saved-state replan"
        )
        try requireNativeMacManager(
            suspended.runtimeIdentity.resolvedPlan?.planRevision == refreshedPlan.planRevision,
            "suspended status should carry refreshed runtime identity"
        )
        try requireNativeMacManager(suspended.savedState != nil, "suspend should publish saved-state metadata")

        let journal = try DoryOperationJournalStore(home: fixture.root + "/manager-journal")
        let suspendRecords = try journal.list().filter { $0.plan.kind == .workspaceSuspend }
        try requireNativeMacManager(
            suspendRecords.count == 1,
            "suspend should publish exactly one lifecycle journal record"
        )
        let suspendOperation = try journal.acquire(
            UUID(uuidString: "44444444-5555-4666-8777-888888888888")!
        ).readWorkspaceLifecycleOperation()
        try requireNativeMacManager(
            try journal.acquire(
                UUID(uuidString: "44444444-5555-4666-8777-888888888888")!
            ).savedStatePlanCheckpoint()?.planRevision == refreshedPlan.planRevision,
            "suspend journal should checkpoint the refreshed saved-state plan"
        )
        try requireNativeMacManager(
            suspendOperation.targetResourceID == DoryWorkspaceLifecycleOperation.savedStateResourceID,
            "suspend journal should target the saved-state resource"
        )

        try? FileManager.default.removeItem(atPath: helper.exitMarkerPath)
        let restoreCall = NativeMacPhysicalFixtureThreadCall.start(name: "dory-native-mac-resume") {
            try manager.resume(
                id: machineID,
                operationID: UUID(uuidString: "55555555-6666-4777-8888-999999999999")!
            )
        }
        do {
            let restoring = try waitForNativeManagerStatus(
                manager,
                id: machineID,
                timeout: 300,
                label: "resume handoff",
                failingWhenFinished: restoreCall
            ) {
                $0.state == .starting && $0.handoffSocketPath != nil
            }
            let controlSocketPath = nativeHelperControlSocketPath(
                handoffSocketPath: try #require(restoring.handoffSocketPath)
            )
            try waitForNativeHelperControlSocket(
                controlSocketPath,
                manager: manager,
                id: machineID,
                call: restoreCall,
                label: "resume control socket"
            )
            try sendVmmHandoff(
                path: try #require(restoring.handoffSocketPath),
                ready: VmmReadyMessage(
                    machineID: machineID,
                    operationID: restoring.activeOperationID,
                    controlSocketPath: controlSocketPath
                ),
                fileDescriptors: []
            )
        } catch {
            _ = try? restoreCall.value()
            throw error
        }
        let restoredStatus = try restoreCall.value()
        try requireNativeMacManager(restoredStatus.state == .running, "resume should publish running status")
        try requireNativeMacManager(restoredStatus.savedState == nil, "resume should consume daemon saved state")
        try requireNativeMacManager(
            manager.status(id: machineID)?.runtimeIdentity.resolvedPlan?.planRevision == refreshedPlan.planRevision,
            "resume should retain refreshed runtime identity"
        )

        _ = try NativeMacPhysicalFixtureThreadCall.start(name: "dory-native-mac-stop") {
            try manager.stop(id: machineID)
        }.value()
        try NativeMacPhysicalFixtureThreadCall.start(name: "dory-native-mac-delete") {
            try manager.delete(id: machineID)
        }.value()
        removeHelperRoot = true
    }

private func cloneOrCopyPhysicalFixtureItem(source: String, destination: String) throws {
        if clonefile(source, destination, 0) == 0 { return }
        let cloneErrno = errno
        if cloneErrno != ENOTSUP && cloneErrno != EXDEV && cloneErrno != EISDIR {
            throw POSIXError(POSIXErrorCode(rawValue: cloneErrno) ?? .EIO)
        }
        try FileManager.default.copyItem(atPath: source, toPath: destination)
    }

    private func readyContext(
        _ readiness: DoryDaemonVirtualMachineProductionPlanningReadiness
    ) throws -> DoryDaemonVirtualMachineProductionPlanningContext {
        guard case let .ready(context) = readiness else {
            Issue.record("Expected ready production planning composition")
            throw CompositionTestError.notReady
        }
        return context
    }
}

private final class NativeMacPhysicalFixtureThreadCall<T>: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: Result<T, Error>?

    static func start(
        name: String,
        stackSize: Int = 8 * 1_024 * 1_024,
        _ body: @escaping @Sendable () throws -> T
    ) -> NativeMacPhysicalFixtureThreadCall<T> {
        let call = NativeMacPhysicalFixtureThreadCall<T>()
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
        condition.lock()
        defer { condition.unlock() }
        while result == nil { condition.wait() }
        return try result!.get()
    }
}

private final class CompositionFixture: @unchecked Sendable {
    let root: String
    private let preserveRoot: Bool
    let events = CompositionEvents()
    let registry: BackendRegistry
    let backend: RawHVLinuxMachineBackend
    let vzBackend: VirtualizationFrameworkLinuxMachineBackend
    let workspaces: DoryWorkspaceRepository
    let plans: DoryResolvedMachinePlanRepository
    let ledger: DoryVirtualMachineResourceAdmissionLedger
    let trust: CompositionTrust
    let authorizer: CompositionMutationAuthority
    let recovery: CompositionRecovery
    private let requests: [String: DoryDaemonVirtualMachinePlanningTransactionRequest]

    init(ids: [String], rootOverride: String? = nil, preserveRoot: Bool = false) throws {
        self.preserveRoot = preserveRoot
        if let rootOverride {
            root = URL(fileURLWithPath: rootOverride).standardizedFileURL.path
        } else {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "dory-production-planning-composition-\(UUID().uuidString)"
            ).standardizedFileURL.path
        }
        try FileManager.default.createDirectory(
            atPath: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let operations = MachineBackendCompatibilityOperations(
            start: { id in MachineBackendRuntimeObservation(machineID: id, state: .running) },
            stop: { request in
                MachineBackendRuntimeObservation(machineID: request.machineID, state: .stopped)
            },
            pause: { request in
                MachineBackendRuntimeObservation(machineID: request.machineID, state: .paused)
            },
            resume: { request in
                MachineBackendRuntimeObservation(machineID: request.machineID, state: .running)
            }
        )
        backend = RawHVLinuxMachineBackend(
            executablePath: "/fixture/dory-hv",
            operations: operations,
            executableIsAvailable: { _ in true }
        )
        vzBackend = VirtualizationFrameworkLinuxMachineBackend(
            executablePath: "/fixture/dory-vmm",
            operations: operations,
            executableIsAvailable: { _ in true }
        )
        registry = try BackendRegistry(backends: [backend, vzBackend])
        workspaces = DoryWorkspaceRepository(root: root)
        plans = DoryResolvedMachinePlanRepository(root: root)
        ledger = DoryVirtualMachineResourceAdmissionLedger(
            root: root + "/.resource-admissions"
        )
        var requests: [String: DoryDaemonVirtualMachinePlanningTransactionRequest] = [:]
        var snapshots: [String: DoryDaemonVirtualMachineTrustedInventorySnapshot] = [:]
        for id in ids {
            let prepared = try Self.requestAndSnapshot(id: id, root: root)
            requests[id] = prepared.request
            snapshots[id] = prepared.snapshot
        }
        self.requests = requests
        trust = CompositionTrust(snapshots: snapshots)
        authorizer = CompositionMutationAuthority(events: events)
        recovery = CompositionRecovery(requests: requests, events: events)
    }

    deinit { if !preserveRoot { try? FileManager.default.removeItem(atPath: root) } }

    func factory(
        hasMutationAuthority: Bool = true,
        hasRecoveryProvider: Bool = true,
        recoveryProvider:
            (any DoryDaemonVirtualMachinePlanningRecoveryProviding)? = nil
    ) -> DoryDaemonVirtualMachineProductionPlanningCompositionFactory {
        let selectedRecovery: (any DoryDaemonVirtualMachinePlanningRecoveryProviding)?
        if hasRecoveryProvider {
            selectedRecovery = recoveryProvider ?? recovery
        } else {
            selectedRecovery = nil
        }
        return DoryDaemonVirtualMachineProductionPlanningCompositionFactory(
            stateDirectory: root,
            backends: [backend, vzBackend],
            mutationAuthority: hasMutationAuthority ? authorizer : nil,
            recoveryProvider: selectedRecovery,
            capabilityPlanner: CompositionCapabilityPlanner(),
            inventoryBuilder: { [trust] artifactAuthority, resourceLedger in
                _ = artifactAuthority
                _ = resourceLedger
                return trust
            }
        )
    }

    func writeMachineAuthority(
        _ id: String,
        mutate: (inout DoryMachineConfiguration) -> Void = { _ in }
    ) throws {
        var machine = try #require(requests[id]).planning.machine
        mutate(&machine)
        let directory = root + "/" + id
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let path = directory + "/machine.json"
        try encoder.encode(machine).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: path
        )
    }

    func interrupt(
        _ id: String,
        at stage: DoryDaemonVirtualMachinePlanningTransactionCoordinator.PublicationStage
    ) throws {
        let fault = CompositionFault(stage)
        let coordinator = DoryDaemonVirtualMachinePlanningTransactionCoordinator(
            stateDirectory: root,
            registry: registry,
            trust: trust,
            mutationAuthority: authorizer,
            workspaces: workspaces,
            plans: plans,
            ledger: ledger,
            capabilityPlanner: CompositionCapabilityPlanner(),
            now: { 1_700_000_000_100 },
            faultInjector: fault.inject
        )
        do {
            _ = try coordinator.resolveReserveAndPublish(try #require(requests[id]))
            Issue.record("Expected injected transaction interruption")
        } catch is CompositionInjectedFailure {}
    }

    func coordinator<Trust: DoryDaemonVirtualMachineTrustInventory & DoryDaemonVirtualMachinePlanningTrustPreparing>(
        trust: Trust,
        capabilityPlanner: any DoryDaemonVirtualMachineCapabilityPlanning = CompositionCapabilityPlanner(),
        fault: CompositionFault? = nil
    ) -> DoryDaemonVirtualMachinePlanningTransactionCoordinator {
        if let fault {
            return DoryDaemonVirtualMachinePlanningTransactionCoordinator(
                stateDirectory: root,
                registry: registry,
                trust: trust,
                mutationAuthority: authorizer,
                workspaces: workspaces,
                plans: plans,
                ledger: ledger,
                capabilityPlanner: capabilityPlanner,
                now: { 1_700_000_000_100 },
                faultInjector: fault.inject
            )
        }
        return DoryDaemonVirtualMachinePlanningTransactionCoordinator(
            stateDirectory: root,
            registry: registry,
            trust: trust,
            mutationAuthority: authorizer,
            workspaces: workspaces,
            plans: plans,
            ledger: ledger,
            capabilityPlanner: capabilityPlanner,
            now: { 1_700_000_000_100 }
        )
    }

    func nativeMacPreparedRequest(id: String) throws -> NativeMacCompositionMaterial {
        let restoreReference = DoryVMResolverReference(
            namespace: "macos-restore", identifier: "\(id)-restore"
        )
        let diskReference = DoryVMResolverReference(
            namespace: "macos-machine", identifier: "\(id)-system-disk"
        )
        let machineRoot = root + "/" + id
        let bundlePath = machineRoot + "/Machine.dorymac"
        let restorePath = machineRoot + "/Restore.ipsw"
        let diskPath = bundlePath + "/" + DoryVZMacMachineBundle.diskName
        try FileManager.default.createDirectory(
            atPath: bundlePath,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Self.writePrivateFile(
            path: restorePath,
            contents: Data("fixture-native-mac-restore-\(id)".utf8)
        )
        try Self.createSparsePrivateFile(
            path: diskPath,
            size: NativeMacCompositionMaterial.diskBytes
        )
        let definition = try NativeMacCompositionMaterial.definition(
            id: id,
            restoreReference: restoreReference,
            diskReference: diskReference,
            cpuCount: 4,
            memoryBytes: 8 * 1_024 * 1_024 * 1_024,
            diskBytes: NativeMacCompositionMaterial.diskBytes,
            audio: DoryVMAudioConfiguration(inputEnabled: false, outputEnabled: false),
            integrations: []
        )
        let machine = DoryMachineConfiguration(
            id: id,
            guestFamily: .macOS,
            guestArchitecture: .arm64,
            kernelPath: "",
            rootfsPath: "",
            bootMode: .macOSRestore,
            macOSRestoreImagePath: restorePath,
            macOSMachineBundlePath: bundlePath,
            diskSizeBytes: NativeMacCompositionMaterial.diskBytes,
            memoryMB: 8 * 1_024,
            cpuCount: 4,
            displayMode: .desktop
        )
        let request = DoryDaemonVirtualMachinePlanningTransactionRequest(
            operationID: UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!,
            planning: DoryDaemonVirtualMachinePlanningRequest(
                definition: definition,
                canonicalDefinitionData: DoryDaemonVirtualMachinePlanningCoordinator
                    .canonicalDefinitionData(definition),
                machine: machine,
                publication: .create,
                experimentalAuthorization: DoryResolvedExperimentalSupportAuthorization(
                    authorizationIdentity: "composition-native-macos",
                    definitionRevision: definition.lifecycle.revision,
                    backend: .appleVirtualizationFramework,
                    authorizedAtUnixMilliseconds: 1_700_000_000_050
                )
            ),
            workspacePublication: .create
        )
        let authority = DoryVirtualMachineArtifactAuthority(root: root + "/.artifact-authority")
        return NativeMacCompositionMaterial(
            root: root,
            request: request,
            artifactAuthority: authority,
            restoreReference: restoreReference,
            diskReference: diskReference,
            restorePath: restorePath,
            diskPath: diskPath
        )
    }

    private static func writePrivateFile(path: String, contents: Data) throws {
        guard FileManager.default.createFile(
            atPath: path,
            contents: contents,
            attributes: [.posixPermissions: 0o600]
        ) else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func createSparsePrivateFile(path: String, size: UInt64) throws {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        guard ftruncate(descriptor, off_t(size)) == 0, fsync(descriptor) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func requestAndSnapshot(
        id: String,
        root: String
    ) throws -> (
        request: DoryDaemonVirtualMachinePlanningTransactionRequest,
        snapshot: DoryDaemonVirtualMachineTrustedInventorySnapshot
    ) {
        let mediaReference = DoryVMResolverReference(
            namespace: "artifact", identifier: "\(id)-runtime"
        )
        let diskReference = DoryVMResolverReference(
            namespace: "artifact", identifier: "\(id)-disk"
        )
        let resources = DoryVMResourceRequest(
            virtualCPUCount: 2,
            memoryBytes: 4 * 1_024 * 1_024 * 1_024,
            diskBytes: 32 * 1_024 * 1_024 * 1_024
        )
        let definition = DoryVirtualMachineDefinition(
            identity: DoryVirtualMachineIdentity(id: id, name: id),
            guest: DoryGuestPlatform(family: .linux, architecture: .arm64),
            workload: .desktop,
            boot: DoryVMBootConfiguration(
                phase: .normal,
                devices: [DoryVMBootMediaReference(
                    id: "system", role: .system,
                    kind: .installedLinuxBootBundle,
                    source: .bundledByDory,
                    artifact: mediaReference,
                    removable: false
                )],
                order: ["system"]
            ),
            platform: .arm64LinuxV1,
            graphics: DoryVMGraphicsPolicy(acceptableLevels: [.none]),
            resources: resources,
            storage: [DoryVMStorageAttachment(
                id: "system-disk", role: .system, artifact: diskReference,
                capacityBytes: resources.diskBytes
            )],
            audio: DoryVMAudioConfiguration(inputEnabled: false, outputEnabled: false),
            input: DoryVMInputConfiguration(keyboardEnabled: false, pointerEnabled: false),
            lifecycle: DoryVMLifecycleMetadata(
                revision: 1,
                createdAtUnixMilliseconds: 1_700_000_000_000,
                updatedAtUnixMilliseconds: 1_700_000_000_000
            )
        )
        let bootBundlePath = root + "/\(id).installed-linux.boot"
        try DoryInstalledLinuxBootBundle.write(
            assets: DoryLinuxInstallerBootAssets(
                kernel: Data("composition-kernel-\(id)".utf8),
                initrd: Data("composition-initrd-\(id)".utf8),
                kernelISOPath: "/boot/vmlinuz",
                initrdISOPath: "/boot/initrd"
            ),
            rootDevice: "/dev/vda2",
            toPath: bootBundlePath
        )
        let machine = DoryMachineConfiguration(
            id: id,
            kernelPath: bootBundlePath,
            rootfsPath: "/fixture/\(id).raw",
            bootMode: .efi,
            displayMode: .desktop
        )
        let media = DoryBootMedia(
            kind: .installedLinuxBootBundle,
            source: .bundledByDory,
            artifactSHA256: compositionDigest(id.last ?? "a")
        )
        let devices = DoryVirtualMachineDeviceCapabilityRequest.minimumBootable
        let evidence = DoryVirtualMachineRuntimeQualificationEvidence(
            qualificationIdentity: compositionQualificationIdentity(media),
            qualificationReportSHA256: compositionDigest("b"),
            signingKeyID: "dory-test-key",
            qualificationFormatVersion: 1,
            guest: definition.guest,
            bootMediaKind: media.kind,
            immutableArtifactSHA256: media.artifactSHA256,
            backend: .doryHypervisor,
            backendRuntimeBuildID: "raw-runtime-1",
            virtualHardwareABIVersion: 1,
            graphics: .none,
            devices: devices
        )
        let hostQualification = DoryResolvedHostQualificationEvidence(
            qualificationIdentity: evidence.qualificationIdentity,
            qualificationReportSHA256: evidence.qualificationReportSHA256,
            hostHardwareModelIdentifier: "Mac16.1",
            hostOperatingSystemBuild: "26A5406c",
            backend: .doryHypervisor,
            backendRuntimeBuildIdentifier: "raw-runtime-1",
            virtualHardwareABIVersion: 1,
            qualifierIdentifier: "dory-test-qualifier",
            qualifierVersion: 1
        )
        let snapshot = DoryDaemonVirtualMachineTrustedInventorySnapshot(
            hostFacts: compositionHostFacts(),
            media: DoryDaemonVirtualMachineResolvedMedia(
                reference: mediaReference, media: media
            ),
            launchArtifacts: [
                resolvedMutableStorageLaunchArtifact(
                    reference: diskReference,
                    source: .userProvided,
                    identifier: "system-disk"
                ),
                resolvedBootLaunchArtifacts(
                    reference: mediaReference,
                    media: media,
                    identifier: "system"
                )[0],
            ],
            backendRuntimes: [DoryDaemonVirtualMachineBackendRuntimeInventory(
                backend: .doryHypervisor,
                runtimeBuildIdentifier: "raw-runtime-1",
                components: [DoryResolvedBackendComponentEvidence(
                    componentIdentifier: "dory-hv",
                    buildIdentifier: "raw-runtime-1",
                    artifactSHA256: compositionDigest("c")
                )],
                hostQualification: hostQualification
            )],
            resourceAdmission: compositionAdmission(resources),
            persistence: resolvedPersistenceTestBinding(machineID: definition.identity.id, stateDirectory: root)
        )
        let planning = DoryDaemonVirtualMachinePlanningRequest(
            definition: definition,
            canonicalDefinitionData: DoryDaemonVirtualMachinePlanningCoordinator
                .canonicalDefinitionData(definition),
            machine: machine,
            publication: .create
        )
        return (
            DoryDaemonVirtualMachinePlanningTransactionRequest(
                planning: planning,
                workspacePublication: .create
            ),
            snapshot
        )
    }
}

private struct NativeMacCompositionMaterial {
    static let diskBytes: UInt64 = 80 * 1_024 * 1_024 * 1_024

    static func artifactReference(
        namespace: String,
        machineID: String,
        role: String,
        digest: String
    ) -> DoryVMResolverReference {
        let material = Data((machineID + "\u{0}" + role + "\u{0}" + digest).utf8)
        let identifier = SHA256.hash(data: material).map {
            String(format: "%02x", $0)
        }.joined()
        return DoryVMResolverReference(namespace: namespace, identifier: identifier)
    }

    static func definition(
        id: String,
        restoreReference: DoryVMResolverReference,
        diskReference: DoryVMResolverReference,
        cpuCount: UInt64,
        memoryBytes: UInt64,
        diskBytes: UInt64,
        audio: DoryVMAudioConfiguration,
        integrations: [DoryVMGuestIntegration],
        createdAtUnixMilliseconds: Int64 = 1_700_000_000_000
    ) throws -> DoryVirtualMachineDefinition {
        let guest = DoryGuestPlatform(family: .macOS, architecture: .arm64)
        let graphics = DoryVMGraphicsPolicy(acceptableLevels: [.hostAcceleratedDisplay])
        let displays = [DoryVMDisplayConfiguration()]
        let lifecycle = DoryVMLifecycleMetadata(
            revision: 1,
            createdAtUnixMilliseconds: createdAtUnixMilliseconds,
            updatedAtUnixMilliseconds: createdAtUnixMilliseconds
        )
        let definition = DoryVirtualMachineDefinition(
            identity: DoryVirtualMachineIdentity(id: id, name: id),
            guest: guest,
            workload: .desktop,
            boot: DoryVMBootConfiguration(
                phase: .install,
                devices: [DoryVMBootMediaReference(
                    id: "restore",
                    role: .installer,
                    kind: .macOSRestoreImage,
                    source: .userProvided,
                    artifact: restoreReference,
                    removable: true
                )],
                order: ["restore"]
            ),
            platform: .arm64MacOSV1,
            translationConsent: .notRequired,
            graphics: graphics,
            resources: DoryVMProductionResourceBudget.make(
                guest: guest,
                graphics: graphics,
                displays: displays,
                shareCount: 0,
                virtualCPUCount: cpuCount,
                memoryBytes: memoryBytes,
                diskBytes: diskBytes
            ),
            storage: [DoryVMStorageAttachment(
                id: "system",
                role: .system,
                artifact: diskReference,
                source: .userProvided,
                capacityBytes: diskBytes
            )],
            networkMode: .sharedNAT,
            displays: displays,
            audio: audio,
            camera: DoryVMCameraConfiguration(enabled: false),
            input: DoryVMInputConfiguration(),
            integrations: integrations,
            clipboardPolicy: integrations.contains(.clipboard) ? .legacyDesktop(.bidirectional) : .disabled,
            lifecycle: lifecycle
        )
        let issues = definition.validate()
        guard issues.isEmpty else { throw CompositionTestError.invalidAuthority }
        return definition
    }

    static func writeGuestDiskByte(at diskPath: String, byte: UInt8) throws {
        let descriptor = open(diskPath, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        var value = byte
        guard pwrite(descriptor, &value, 1, 0) == 1, fsync(descriptor) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }


    static func workspaceCreationTimestamp(machineDirectory: String) -> Int64 {
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

    var root: String
    var request: DoryDaemonVirtualMachinePlanningTransactionRequest
    var artifactAuthority: DoryVirtualMachineArtifactAuthority
    var restoreReference: DoryVMResolverReference
    var diskReference: DoryVMResolverReference
    var restorePath: String
    var diskPath: String

    func publications(
        expectedDiskRevision: UInt64?
    ) throws -> [DoryDaemonVirtualMachinePlanningArtifactPublication] {
        let requirements = try #require(DoryDaemonVirtualMachinePlanningCoordinator
            .launchArtifactRequirements(for: request.planning.definition))
        return requirements.map { requirement in
            DoryDaemonVirtualMachinePlanningArtifactPublication(
                reference: requirement.reference,
                path: requirement.reference == restoreReference ? restorePath : diskPath,
                kind: requirement.kind,
                source: requirement.source,
                mutability: requirement.mutable ? .mutable : .immutable,
                expectedAuthorityRevision: requirement.reference == diskReference
                    ? expectedDiskRevision : nil
            )
        }
    }

    func replanningRequest(
        operationID: UUID,
        expectedPlanRevision: UInt64
    ) throws -> DoryDaemonVirtualMachinePlanningTransactionRequest {
        var planning = request.planning
        planning.publication = .replace(expectedPlanRevision: expectedPlanRevision)
        return DoryDaemonVirtualMachinePlanningTransactionRequest(
            operationID: operationID,
            planning: planning,
            workspacePublication: .retainExistingExact
        )
    }

    func writeGuestDiskByte(_ byte: UInt8) throws {
        try Self.writeGuestDiskByte(at: diskPath, byte: byte)
    }

    func publishSavedStateManifest(
        runtimeIdentity: DoryMachineRuntimeIdentity
    ) throws -> DoryMachineSavedStateManifest {
        let store = DoryMachineSavedStateStore(root: root)
        let temporary = try store.temporaryStatePath(
            machineID: request.planning.definition.identity.id,
            nonce: UUID(uuidString: "99999999-8888-4777-9666-555555555555")!
        )
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        let payload = Data("native-mac-saved-state".utf8)
        try payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            guard write(descriptor, base, raw.count) == raw.count else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
        return try store.publish(
            temporaryStatePath: temporary,
            machineID: request.planning.definition.identity.id,
            authoritativeConfigurationData: Self.machineAuthorityData(request.planning.machine),
            runtimeIdentity: runtimeIdentity,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func inspectSavedState(
        runtimeIdentity: DoryMachineRuntimeIdentity
    ) -> DoryMachineSavedStateInspection {
        let store = DoryMachineSavedStateStore(root: root)
        return store.inspect(
            machineID: request.planning.definition.identity.id,
            authoritativeConfigurationData: Self.machineAuthorityData(request.planning.machine),
            runtimeIdentity: runtimeIdentity
        )
    }

    private static func machineAuthorityData(_ machine: DoryMachineConfiguration) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(machine)) ?? Data()
    }
}

private final class NativeMacManagerHelperController:
    MachineVZLifecycleControlling, @unchecked Sendable
{
    private let lock = NSLock()
    private let exitMarkerPath: String
    var bundlePath: String?
    private var saves = 0

    init(exitMarkerPath: String) {
        self.exitMarkerPath = exitMarkerPath
    }

    var saveCount: Int { lock.withLock { saves } }

    func pause(socketPath: String) throws {}
    func resume(socketPath: String) throws {}

    func saveMachineState(socketPath: String, statePath: String) throws {
        let descriptor = open(statePath, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        let payload = Data("native-mac-manager-saved-state".utf8)
        try payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            guard write(descriptor, base, raw.count) == raw.count else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
        if let bundlePath {
            _ = try DoryVZMacMachineBundle.load(
                from: URL(fileURLWithPath: bundlePath, isDirectory: true)
            ).updatingInstallationState(.suspended)
        }
        lock.withLock { saves += 1 }
        guard FileManager.default.createFile(
            atPath: exitMarkerPath,
            contents: Data(),
            attributes: [.posixPermissions: 0o600]
        ) else { throw CocoaError(.fileWriteUnknown) }
    }
}

private struct NativeMacManagerHelper {
    let root: String
    let executablePath: String
    let exitMarkerPath: String
    let managerRuntimeRoot: String
    let controller: NativeMacManagerHelperController

    init(root: String) throws {
        self.root = root
        executablePath = root + "/fake-vzmac-helper.sh"
        exitMarkerPath = root + "/fake-vzmac-exit"
        managerRuntimeRoot = root + "/manager-runtime"
        controller = NativeMacManagerHelperController(exitMarkerPath: exitMarkerPath)
        let testBundle = Bundle(for: DoryRuntimeReconnectTests.self).bundlePath
        let developerDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
            ?? "/Applications/Xcode-26.6.0-Release.Candidate.app/Contents/Developer"
        let script = """
        #!/bin/sh
        log='\(root)/fake-vzmac-arguments.log'
        printf '%s\n' "$@" >> "$log"
        control_sock=
        reconnect_fd=
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --control-sock) shift; control_sock="$1" ;;
            --runtime-reconnect-fd) shift; reconnect_fd="$1" ;;
          esac
          shift || exit 2
        done
        if [ -z "$control_sock" ] || [ -z "$reconnect_fd" ]; then
          echo 'missing control socket or reconnect fd' >> "$log"
          exit 2
        fi
        export DORY_RECONNECT_TEST_SOCKET="$control_sock"
        export DORY_RECONNECT_TEST_FD="$reconnect_fd"
        export DORY_RECONNECT_TEST_RETIRE_ON_FILE='\(exitMarkerPath)'
        export DEVELOPER_DIR='\(developerDirectory)'
        exec /usr/bin/xcrun xctest -XCTest DorydKitTests.DoryRuntimeReconnectTests/testReconnectSubprocessServer '\(testBundle)' >> '\(root)/fake-vzmac-xctest.log' 2>&1
        """
        try Data(script.utf8).write(to: URL(fileURLWithPath: executablePath))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executablePath
        )
    }

}



private func waitForNativeManagerStatus(
    _ manager: MachineManager,
    id: String,
    timeout: TimeInterval = 10,
    label: String = "status",
    predicate: (DoryMachineStatus) -> Bool
) throws -> DoryMachineStatus {
    try waitForNativeManagerStatus(
        manager,
        id: id,
        timeout: timeout,
        label: label,
        failingWhenFinished: Optional<NativeMacPhysicalFixtureThreadCall<Void>>.none,
        predicate: predicate
    )
}

private func waitForNativeManagerStatus<T>(
    _ manager: MachineManager,
    id: String,
    timeout: TimeInterval = 10,
    label: String = "status",
    failingWhenFinished call: NativeMacPhysicalFixtureThreadCall<T>?,
    predicate: (DoryMachineStatus) -> Bool
) throws -> DoryMachineStatus {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let status = manager.status(id: id) {
            if predicate(status) { return status }
            if status.state == .failed {
                throw nativeManagerTerminalFailure(label: label, status: status)
            }
        }
        if let result = call?.resultIfFinished() {
            _ = try result.get()
            if let status = manager.status(id: id) {
                throw CompositionTestError.unexpectedStatus(status.state.rawValue)
            }
            throw nativeManagerTimeout(label: label, status: manager.status(id: id))
        }
        Thread.sleep(forTimeInterval: 0.01)
    }
    if let result = call?.resultIfFinished() {
        _ = try result.get()
    }
    throw nativeManagerTimeout(label: label, status: manager.status(id: id))
}


private final class CompositionArtifactAuthorityTrust:
    DoryDaemonVirtualMachineTrustInventory,
    DoryDaemonVirtualMachinePlanningTrustPreparing,
    DoryDaemonVirtualMachinePreSpawnAuthorizationProviding,
    @unchecked Sendable
{
    private let root: String
    private let artifactAuthority: DoryVirtualMachineArtifactAuthority
    private let machineID: String?
    private let restoreReference: DoryVMResolverReference?
    private let restoreImageBuild: String
    private let runtimeComponentSHA256: String

    init(
        root: String,
        artifactAuthority: DoryVirtualMachineArtifactAuthority,
        machineID: String? = nil,
        restoreReference: DoryVMResolverReference? = nil,
        restoreImageBuild: String,
        runtimeComponentSHA256: String = compositionDigest("c")
    ) {
        self.root = root
        self.artifactAuthority = artifactAuthority
        self.machineID = machineID
        self.restoreReference = restoreReference
        self.restoreImageBuild = restoreImageBuild
        self.runtimeComponentSHA256 = runtimeComponentSHA256
    }

    func preparePlanningTrust(
        for request: DoryDaemonVirtualMachineInventoryRequest
    ) throws -> DoryDaemonVirtualMachinePlanningTrustPreparation {
        let prepared = try snapshot(request: request, admission: compositionAdmission(request.resources))
        return DoryDaemonVirtualMachinePlanningTrustPreparation(
            hostResources: compositionHostResources(),
            snapshot: { admission in
                var snapshot = prepared
                snapshot.resourceAdmission = admission
                return snapshot
            },
            publicationAuthorization: DoryDaemonVirtualMachinePlanningPublicationAuthorization { [self] in
                _ = try self.snapshot(request: request, admission: compositionAdmission(request.resources))
            }
        )
    }

    func planningInventory(
        for request: DoryDaemonVirtualMachineInventoryRequest
    ) throws -> DoryDaemonVirtualMachineTrustedInventorySnapshot {
        try snapshot(request: request, admission: compositionAdmission(request.resources))
    }

    func startInventory(
        for request: DoryDaemonVirtualMachineStartInventoryRequest
    ) throws -> DoryDaemonVirtualMachineTrustedInventorySnapshot {
        let inventory = DoryDaemonVirtualMachineInventoryRequest(
            machineID: request.resolvedPlan.machineID,
            definitionRevision: request.resolvedPlan.definitionRevision,
            guest: request.resolvedPlan.guest,
            bootMedia: DoryVMBootMediaReference(
                id: "restore",
                role: .installer,
                kind: request.resolvedPlan.bootMedia.media.kind,
                source: request.resolvedPlan.bootMedia.media.source,
                artifact: request.resolvedPlan.bootMedia.resolverReference
                    ?? restoreReference
                    ?? DoryVMResolverReference(namespace: "invalid", identifier: "invalid"),
                removable: true
            ),
            launchArtifacts: request.resolvedPlan.launchArtifacts.map { artifact in
                DoryDaemonVirtualMachineLaunchArtifactRequirement(
                    reference: artifact.resolverReference,
                    kind: artifact.media.kind,
                    source: artifact.media.source,
                    mutable: artifact.media.mutableProvenance != nil,
                    usages: artifact.usages
                )
            },
            resources: DoryVMResourceRequest(
                virtualCPUCount: request.resolvedPlan.resourceAdmission?.admittedVirtualCPUCount ?? 4,
                memoryBytes: request.resolvedPlan.resourceAdmission?.admittedMemoryBytes ?? 8 * 1_024 * 1_024 * 1_024,
                diskBytes: request.resolvedPlan.resourceAdmission?.admittedStorageBytes ?? NativeMacCompositionMaterial.diskBytes
            ),
            devices: DoryVirtualMachineDeviceCapabilityRequest(
                networkInterface: DoryVirtualMachineNetworkInterfaceCapabilityRequest.stable(
                    machineID: request.resolvedPlan.machineID
                ),
                display: DoryVirtualMachineDisplayCapabilityRequest(
                    widthPixels: 1024,
                    heightPixels: 768
                ),
                audioInput: false,
                audioOutput: false,
                keyboard: true,
                pointer: true,
                clipboard: false,
                clipboardPolicy: .disabled,
                clockSynchronization: false,
                dynamicDisplay: false,
                gracefulShutdown: false
            ),
            acceptableGraphics: [request.resolvedPlan.graphics],
            virtualHardwareABIVersion: request.resolvedPlan.virtualHardwareABIVersion
        )
        return try snapshot(
            request: inventory,
            admission: request.resolvedPlan.resourceAdmission ?? compositionAdmission(inventory.resources)
        )
    }

    func preSpawnAuthorization(
        for request: DoryDaemonVirtualMachineStartInventoryRequest
    ) throws -> DoryDaemonVirtualMachinePreSpawnAuthorization {
        DoryDaemonVirtualMachinePreSpawnAuthorization(purpose: request.purpose) { [self] in
            _ = try self.startInventory(for: request)
        }
    }

    private func snapshot(
        request: DoryDaemonVirtualMachineInventoryRequest,
        admission: DoryResolvedMachineResourceAdmissionEvidence
    ) throws -> DoryDaemonVirtualMachineTrustedInventorySnapshot {
        if let machineID, request.machineID != machineID {
            throw CompositionTestError.invalidAuthority
        }
        let launchArtifacts = try request.launchArtifacts.map { requirement in
            let artifact = try artifactAuthority.resolve(
                reference: requirement.reference,
                kind: requirement.kind,
                source: requirement.source
            )
            return DoryResolvedMachineLaunchArtifact(
                resolverReference: artifact.reference,
                media: artifact.media,
                authorityRevision: artifact.authorityRevision,
                usages: requirement.usages,
                mutableProvenanceEvidence: artifact.mutableProvenance?.persistedAuditEvidence
            )
        }
        let restore = try artifactAuthority.resolve(
            reference: restoreReference ?? request.bootMedia.artifact,
            kind: .macOSRestoreImage,
            source: .userProvided
        )
        let restoreBytes = try FileManager.default.attributesOfItem(
            atPath: restore.path
        )[.size] as? NSNumber
        let preparedRestore = try DoryQualifiedBootMediaInspector
            .inspectPreparedNativeMacOSRestoreImage(
                artifactSHA256: try #require(restore.media.artifactSHA256),
                byteCount: try #require(restoreBytes).uint64Value,
                buildIdentifier: restoreImageBuild
            )
        guard preparedRestore.media == restore.media else {
            throw CompositionTestError.invalidAuthority
        }
        return DoryDaemonVirtualMachineTrustedInventorySnapshot(
            hostFacts: compositionHostFacts(nativeMacOSAvailable: true),
            media: DoryDaemonVirtualMachineResolvedMedia(
                reference: restore.reference,
                media: restore.media,
                bootInspection: preparedRestore.inspection
            ),
            launchArtifacts: launchArtifacts,
            backendRuntimes: [DoryDaemonVirtualMachineBackendRuntimeInventory(
                backend: .appleVirtualizationFramework,
                runtimeBuildIdentifier: "vz-runtime-1",
                components: [DoryResolvedBackendComponentEvidence(
                    componentIdentifier: "dory-vmm",
                    buildIdentifier: "vz-runtime-1",
                    artifactSHA256: runtimeComponentSHA256
                )]
            )],
            resourceAdmission: admission,
            persistence: resolvedPersistenceTestBinding(
                machineID: request.machineID,
                stateDirectory: root
            )
        )
    }
}

private final class CompositionTrust:
    DoryDaemonVirtualMachineTrustInventory,
    DoryDaemonVirtualMachinePlanningTrustPreparing,
    @unchecked Sendable
{
    let snapshots: [String: DoryDaemonVirtualMachineTrustedInventorySnapshot]
    init(snapshots: [String: DoryDaemonVirtualMachineTrustedInventorySnapshot]) {
        self.snapshots = snapshots
    }

    func preparePlanningTrust(
        for request: DoryDaemonVirtualMachineInventoryRequest
    ) throws -> DoryDaemonVirtualMachinePlanningTrustPreparation {
        let base = try #require(snapshots[request.machineID])
        return DoryDaemonVirtualMachinePlanningTrustPreparation(
            hostResources: compositionHostResources(),
            snapshot: { admission in
                var snapshot = base
                snapshot.resourceAdmission = admission
                return snapshot
            },
            publicationAuthorization:
                DoryDaemonVirtualMachinePlanningPublicationAuthorization {}
        )
    }

    func planningInventory(
        for request: DoryDaemonVirtualMachineInventoryRequest
    ) throws -> DoryDaemonVirtualMachineTrustedInventorySnapshot {
        try #require(snapshots[request.machineID])
    }

    func startInventory(
        for request: DoryDaemonVirtualMachineStartInventoryRequest
    ) throws -> DoryDaemonVirtualMachineTrustedInventorySnapshot {
        try #require(snapshots[request.resolvedPlan.machineID])
    }
}

private final class CompositionRecovery:
    DoryDaemonVirtualMachinePlanningRecoveryProviding, @unchecked Sendable
{
    private let lock = NSLock()
    private let requests: [String: DoryDaemonVirtualMachinePlanningTransactionRequest]
    private let events: CompositionEvents
    private var storage: [String] = []

    init(
        requests: [String: DoryDaemonVirtualMachinePlanningTransactionRequest],
        events: CompositionEvents
    ) {
        self.requests = requests
        self.events = events
    }

    var requestedIDs: [String] { lock.withLock { storage } }

    func recoveryRequest(
        for descriptor: DoryDaemonVirtualMachinePlanningRecoveryDescriptor
    ) throws -> DoryDaemonVirtualMachinePlanningTransactionRequest? {
        let machineID = descriptor.machineID
        lock.withLock { storage.append(machineID) }
        events.append("recovery:\(machineID)")
        guard let request = requests[machineID], descriptor.matches(request) else {
            return nil
        }
        return request
    }
}

private final class CompositionMutationAuthority:
    DoryDaemonVirtualMachinePlanningMutationAuthorizing, @unchecked Sendable
{
    private let events: CompositionEvents
    init(events: CompositionEvents) { self.events = events }

    func acquirePlanningMutationFence(
        operationID: UUID,
        machine: DoryMachineConfiguration,
        definition: DoryVirtualMachineDefinition,
        canonicalDefinitionData: Data
    ) throws -> DoryDaemonVirtualMachinePlanningMutationFence {
        guard machine.id == definition.identity.id, !canonicalDefinitionData.isEmpty else {
            throw CompositionTestError.invalidAuthority
        }
        events.append("mutation:\(machine.id)")
        return DoryDaemonVirtualMachinePlanningMutationFence(
            authority: DoryDaemonVirtualMachinePlanningMachineAuthority(
                machineID: machine.id,
                legacyConfigurationSHA256: compositionDigest("e"),
                migrationFactsSHA256: compositionDigest("f"),
                sourceDefinitionRevision: definition.lifecycle.revision,
                sourceDefinitionSHA256:
                    DoryDaemonVirtualMachinePlanningCoordinator.sha256(
                        canonicalDefinitionData
                    ),
                runtimeIdentitySHA256: compositionDigest("a")
            ),
            retainedAuthority: machine.id,
            validation: {}
        )
    }
}

private struct CompositionCapabilityPlanner: DoryDaemonVirtualMachineCapabilityPlanning {
    func plan(
        _ request: DoryVirtualMachineBackendPlanRequest,
        inventory: DoryDaemonVirtualMachineTrustedInventorySnapshot
    ) -> DoryVirtualMachineBackendPlanResult {
        let capabilityRequest = DoryVirtualMachineCapabilityRequest(
            guest: request.guest,
            bootMedia: request.bootMedia,
            backend: .doryHypervisor,
            graphics: request.acceptableGraphics.first ?? .none,
            devices: request.devices,
            virtualHardwareABIVersion: request.virtualHardwareABIVersion
        )
        let descriptor = DoryVirtualMachineCapabilityDescriptor(
            evaluatorVersion:
                DoryVirtualMachineCapabilityDescriptor.appleSiliconEvaluatorVersion,
            request: capabilityRequest,
            availability: DoryCapabilityAvailability(
                supportTier: .supported, state: .available
            ),
            resolvedDevices: request.devices,
            runtimeQualificationEvidence: DoryVirtualMachineRuntimeQualificationEvidence(
                qualificationIdentity: compositionQualificationIdentity(request.bootMedia),
                qualificationReportSHA256: compositionDigest("b"),
                signingKeyID: "dory-test-key",
                qualificationFormatVersion: 1,
                guest: request.guest,
                bootMediaKind: request.bootMedia.kind,
                immutableArtifactSHA256: request.bootMedia.artifactSHA256,
                backend: .doryHypervisor,
                backendRuntimeBuildID: "raw-runtime-1",
                virtualHardwareABIVersion: request.virtualHardwareABIVersion,
                graphics: capabilityRequest.graphics,
                devices: request.devices
            )
        )
        _ = inventory
        return DoryVirtualMachineBackendPlanResult(
            selectedDescriptor: descriptor,
            evaluatedDescriptors: [descriptor],
            failure: nil
        )
    }
}

private final class CompositionEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.withLock { storage } }
    func append(_ value: String) { lock.withLock { storage.append(value) } }
}

private final class CompositionFault: @unchecked Sendable {
    private let lock = NSLock()
    private var stage: DoryDaemonVirtualMachinePlanningTransactionCoordinator.PublicationStage?
    init(_ stage: DoryDaemonVirtualMachinePlanningTransactionCoordinator.PublicationStage) {
        self.stage = stage
    }
    func inject(
        _ current: DoryDaemonVirtualMachinePlanningTransactionCoordinator.PublicationStage
    ) throws {
        try lock.withLock {
            if stage == current {
                stage = nil
                throw CompositionInjectedFailure()
            }
        }
    }
}

private func nativeHelperControlSocketPath(handoffSocketPath: String) -> String {
    (handoffSocketPath as NSString).deletingLastPathComponent + "/c.sock"
}

private func requireNativeMacManager(
    _ condition: @autoclosure () throws -> Bool,
    _ message: String
) throws {
    guard try condition() else {
        throw MachineManagerError.persistence("managed native Mac qualification failed: \(message)")
    }
}


private func waitForNativeHelperControlSocket<T>(
    _ path: String,
    manager: MachineManager,
    id: String,
    call: NativeMacPhysicalFixtureThreadCall<T>,
    label: String,
    timeout: TimeInterval = 150
) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        var info = stat()
        if lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK { return }
        if let status = manager.status(id: id), status.state == .failed {
            throw nativeManagerTerminalFailure(label: label, status: status)
        }
        if let result = call.resultIfFinished(), case .failure = result {
            _ = try result.get()
        }
        Thread.sleep(forTimeInterval: 0.01)
    }
    throw nativeManagerTimeout(label: label, status: manager.status(id: id))
}

private enum CompositionTestError: Error { case notReady, invalidAuthority, unexpectedStatus(String) }

private func nativeManagerTimeout(label: String, status: DoryMachineStatus?) -> Error {
    NSError(domain: "NativeMacManagerFixture", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "timeout \(label): \(nativeManagerStatusDetail(status))",
    ])
}

private func nativeManagerTerminalFailure(label: String, status: DoryMachineStatus) -> Error {
    NSError(domain: "NativeMacManagerFixture", code: 2, userInfo: [
        NSLocalizedDescriptionKey: "terminal failure \(label): \(nativeManagerStatusDetail(status))",
    ])
}

private func nativeManagerStatusDetail(_ status: DoryMachineStatus?) -> String {
    guard let status else { return "status=nil" }
    return "state=\(status.state.rawValue) active=\(status.activeOperationID ?? "nil") handoff=\(status.handoffSocketPath ?? "nil") control=\(status.controlSocketPath ?? "nil") lastError=\(status.lastError ?? "nil") failure=\(status.failure.map { "code=\($0.code.rawValue), disposition=\($0.recoveryDisposition.rawValue)" } ?? "nil")"
}
private struct CompositionInjectedFailure: Error {}

private func compositionHostResources() -> DoryVMHostResources {
    DoryVMHostResources(
        logicalCPUCount: 12,
        physicalMemoryBytes: 32 * 1_024 * 1_024 * 1_024,
        freeStorageBytes: 512 * 1_024 * 1_024 * 1_024
    )
}

private func compositionHostFacts(nativeMacOSAvailable: Bool = false) -> DoryAppleSiliconHostFacts {
    DoryAppleSiliconHostFacts(
        macOSMajorVersion: 26,
        virtualizationFrameworkAvailable: true,
        hypervisorFrameworkAvailable: true,
        doryHypervisorAvailable: true,
        qemuHypervisorFrameworkAvailable: false,
        windowsUEFIFirmwareAvailable: false,
        windowsSecureBootAvailable: false,
        windowsSBSADeviceModelAvailable: false,
        virtualTPM20Available: false,
        windowsGuestDrivers: DoryWindowsGuestDriverFacts(
            storageAvailable: false, networkAvailable: false,
            displayAvailable: false, inputAvailable: false
        ),
        macOSGuestVirtualizationSupported: nativeMacOSAvailable,
        macOSRestoreImageInstallationSupported: nativeMacOSAvailable,
        doryMacOSBackendAvailable: nativeMacOSAvailable,
        doryMacOSBackendQualified: nativeMacOSAvailable,
        metalAvailable: true,
        doryAcceleratedRendererAvailable: true,
        runtimeQualificationContext: DoryVirtualMachineRuntimeQualificationHostContext(
            virtualHardwareABIVersion: 1,
            doryHypervisorRuntimeBuildID: "raw-runtime-1",
            virtualizationFrameworkAdapterBuildID: "vz-runtime-1",
            qemuRuntimeBuildID: ""
        )
    )
}

private func compositionAdmission(
    _ resources: DoryVMResourceRequest
) -> DoryResolvedMachineResourceAdmissionEvidence {
    DoryResolvedMachineResourceAdmissionEvidence(
        admittedVirtualCPUCount: resources.virtualCPUCount,
        admittedMemoryBytes: resources.memoryBytes,
        admittedStorageBytes: resources.diskBytes,
        hostLogicalCPUCount: 12,
        hostPhysicalMemoryBytes: 32 * 1_024 * 1_024 * 1_024,
        hostFreeStorageBytes: 512 * 1_024 * 1_024 * 1_024,
        existingVirtualCPUCommitment: 0,
        existingMemoryCommitmentBytes: 0,
        existingStorageReservationBytes: 0,
        hostReservedLogicalCPUCount: 2,
        hostReservedMemoryBytes: 8 * 1_024 * 1_024 * 1_024,
        hostReservedStorageBytes: 32 * 1_024 * 1_024 * 1_024,
        admissionIdentity: "composition-dummy-admission",
        admissionReportSHA256: compositionDigest("d"),
        assessorIdentifier: DoryVirtualMachineResourceAdmissionLedger.assessorIdentifier,
        assessorVersion: DoryVirtualMachineResourceAdmissionLedger.assessorVersion
    )
}

private func compositionDigest(_ value: Character) -> String {
    String(repeating: String(value), count: 64)
}

private func compositionFileSHA256(path: String) throws -> String {
    try SHA256.hash(data: Data(contentsOf: URL(fileURLWithPath: path)))
        .map { String(format: "%02x", $0) }.joined()
}

private func compositionQualificationIdentity(_ media: DoryBootMedia) -> String {
    "qualification-\((media.artifactSHA256 ?? "missing").prefix(12))"
}
