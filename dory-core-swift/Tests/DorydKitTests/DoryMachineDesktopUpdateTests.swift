import DoryOperations
import Foundation
import Testing
@testable import DorydKit

@Suite("Private desktop update recovery authority", .serialized)
struct DoryMachineDesktopUpdateTests {
    @Test("source, selected component and caller identity are inseparable recovery authority",
          arguments: [
            "configuration", "workspace", "request-id", "request-version", "component",
            "observed-before-apply", "snapshot", "source-helper", "runtime-plan",
            "runtime-definition", "runtime-machine", "native-environment", "source-isa", "source-distro",
            "source-cpu", "timestamp-exhaustion", "native-target-revision",
          ])
    func rejectsCrossedAuthority(mutation: String) throws {
        var fixture = try DesktopUpdateContractFixture()
        try fixture.update.validate(operation: fixture.operation)
        switch mutation {
        case "configuration":
            var machine = try fixture.update.sourceConfiguration
            machine.cpuCount += 1
            fixture.update.sourceConfigurationData = try DoryMachineDesktopUpdateJournal.canonicalData(machine)
        case "workspace":
            var definition = try fixture.update.sourceWorkspace.definition
            definition.lifecycle.revision += 1
            fixture.update.sourceWorkspaceData = try DoryMachineDesktopUpdateJournal.canonicalData(
                DoryWorkspaceRepositoryRecord(definition: definition)
            )
        case "request-id":
            fixture.update.request.operationID = UUID()
        case "native-target-revision":
            fixture.operation.target.definitionRevision = nil
        case "request-version":
            fixture.update.request.version = "different-release"
        case "component":
            fixture.update.componentAuthority.bundleSHA256 = desktopDigest("f")
        case "observed-before-apply":
            fixture.update.componentAuthority.inputSHA256 = desktopDigest("a")
            fixture.operation.target.desktopUpdate?.authoritySHA256 = try fixture.update.authoritySHA256
        case "snapshot":
            fixture.update.snapshotID = "other-snapshot"
        case "source-helper":
            fixture.update.sourceRuntimeOperationID = fixture.update.request.operationID
        case "runtime-plan":
            fixture.operation.source.runtime?.resolved?.planDigest = desktopDigest("f")
        case "runtime-definition", "runtime-machine":
            var plan = try #require(fixture.update.sourceRuntimeIdentity.resolvedPlan)
            if mutation == "runtime-definition" { plan.definitionSHA256 = desktopDigest("f") }
            else { plan.machineID = "another-workspace" }
            #expect(plan.validate().isEmpty)
            fixture.update.sourceRuntimeIdentity = try DoryMachineRuntimeIdentity(
                resolvedPlan: plan, planSHA256: plan.canonicalSHA256()
            )
            fixture.operation.source.runtime = try desktopRuntimeBinding(fixture.update.sourceRuntimeIdentity)
        case "native-environment":
            var machine = try fixture.update.sourceConfiguration
            machine.environment["DORY_DESKTOP_VMM"] = "compatible"
            fixture.update.sourceConfigurationData = try DoryMachineDesktopUpdateJournal.canonicalData(machine)
            fixture.operation.source.configurationAuthority?.legacyConfigurationSHA256
                = DoryMachineDesktopUpdateJournal.sha256(fixture.update.sourceConfigurationData)
        case "source-isa", "source-cpu":
            var machine = try fixture.update.sourceConfiguration
            if mutation == "source-isa" { machine.guestArchitecture = .x86_64 }
            else { machine.cpuCount += 1 }
            fixture.update.sourceConfigurationData = try DoryMachineDesktopUpdateJournal.canonicalData(machine)
            fixture.operation.source.configurationAuthority?.legacyConfigurationSHA256
                = DoryMachineDesktopUpdateJournal.sha256(fixture.update.sourceConfigurationData)
        case "source-distro":
            fixture.update.request.distro = "debian"
            fixture.update.componentAuthority.distributionIdentifier = "debian"
            fixture.update.componentAuthority.distributionComponentIdentifier = DoryComponentID.desktopDebian.rawValue
            fixture.update.componentAuthority.bundleAssetIdentifier = DoryInstalledDesktopPayloadReceipt.bundleAssetIdentifier(for: "debian")
            fixture.operation.target.desktopUpdate?.authoritySHA256 = try fixture.update.authoritySHA256
        case "timestamp-exhaustion":
            var definition = try fixture.update.sourceWorkspace.definition
            definition.lifecycle.updatedAtUnixMilliseconds = Int64.max - 1
            let definitionDigest = try DoryMachineDesktopUpdateJournal.digest(definition)
            fixture.update.sourceWorkspaceData = try DoryMachineDesktopUpdateJournal.canonicalData(
                DoryWorkspaceRepositoryRecord(definition: definition)
            )
            fixture.operation.source.configurationAuthority?.canonicalDefinitionSHA256 = definitionDigest
            var plan = try #require(fixture.update.sourceRuntimeIdentity.resolvedPlan)
            plan.definitionSHA256 = definitionDigest
            fixture.update.sourceRuntimeIdentity = try DoryMachineRuntimeIdentity(
                resolvedPlan: plan, planSHA256: plan.canonicalSHA256()
            )
            fixture.operation.source.runtime = try desktopRuntimeBinding(fixture.update.sourceRuntimeIdentity)
        default:
            Issue.record("unknown test mutation")
        }
        #expect(throws: (any Error).self) {
            try fixture.update.validate(operation: fixture.operation)
        }
    }

    @Test("observed installation fingerprint creates the actual target only after guest apply")
    func observedFingerprintIsNotPreallocatedConfigurationAuthority() throws {
        let fixture = try DesktopUpdateContractFixture()
        #expect(fixture.operation.target.configurationAuthority == nil)
        #expect(fixture.operation.target.plannedRuntime == nil)
        #expect(fixture.update.componentAuthority.inputSHA256 == String(repeating: "0", count: 64))
        for invalid in ["", "not-a-digest", String(repeating: "0", count: 64), String(repeating: "A", count: 64)] {
            #expect(throws: (any Error).self) { try fixture.update.installedConfiguration(inputSHA256: invalid) }
        }
        let first = try fixture.update.installedConfiguration(inputSHA256: desktopDigest("a"))
        let second = try fixture.update.installedConfiguration(inputSHA256: desktopDigest("b"))
        #expect(first.installedDesktopPayloadReceipt?.inputSHA256 == desktopDigest("a"))
        #expect(second.installedDesktopPayloadReceipt?.inputSHA256 == desktopDigest("b"))
        #expect(try DoryMachineDesktopUpdateJournal.digest(first) != DoryMachineDesktopUpdateJournal.digest(second))
        var source = try fixture.update.sourceConfiguration
        source.installedDesktopPayloadReceipt = first.installedDesktopPayloadReceipt
        #expect(first == source)
        #expect(fixture.update.componentAuthority.inputSHA256 == String(repeating: "0", count: 64))
    }

    @Test("native target publication and rollback retain intent while advancing their own lineage")
    func nativePublicationLineage() throws {
        let fixture = try DesktopUpdateContractFixture()
        let source = try fixture.update.sourceWorkspace.definition
        var target = source
        target.lifecycle.revision += 1
        target.lifecycle.updatedAtUnixMilliseconds += 1
        let installed = try fixture.update.installedConfiguration(inputSHA256: desktopDigest("a"))
        let forward = DoryMachineDesktopUpdatePublication(
            configurationData: try DoryMachineDesktopUpdateJournal.canonicalData(installed),
            nativeDefinition: target, expectedWorkspaceRevision: source.lifecycle.revision
        )
        try forward.validate(update: fixture.update, rollback: false)
        var wrongIntent = forward
        wrongIntent.nativeDefinition?.camera.enabled.toggle()
        #expect(throws: (any Error).self) { try wrongIntent.validate(update: fixture.update, rollback: false) }
        var wrongReceipt = installed
        wrongReceipt.installedDesktopPayloadReceipt?.bundleSHA256 = desktopDigest("f")
        var wrongConfiguration = forward
        wrongConfiguration.configurationData = try DoryMachineDesktopUpdateJournal.canonicalData(wrongReceipt)
        #expect(throws: (any Error).self) { try wrongConfiguration.validate(update: fixture.update, rollback: false) }
        var stale = forward
        stale.nativeDefinition = source
        #expect(throws: (any Error).self) { try stale.validate(update: fixture.update, rollback: false) }

        var rollbackDefinition = source
        rollbackDefinition.lifecycle.revision += 2
        rollbackDefinition.lifecycle.updatedAtUnixMilliseconds += 2
        let rollback = DoryMachineDesktopUpdatePublication(
            configurationData: fixture.update.sourceConfigurationData,
            nativeDefinition: rollbackDefinition,
            expectedWorkspaceRevision: source.lifecycle.revision + 1
        )
        try rollback.validate(update: fixture.update, rollback: true)
        var wrongRollback = rollback
        wrongRollback.configurationData = forward.configurationData
        #expect(throws: (any Error).self) { try wrongRollback.validate(update: fixture.update, rollback: true) }
        wrongRollback = rollback
        wrongRollback.expectedWorkspaceRevision += 1
        wrongRollback.nativeDefinition?.lifecycle.revision += 1
        #expect(throws: (any Error).self) { try wrongRollback.validate(update: fixture.update, rollback: true) }
        wrongRollback = rollback
        wrongRollback.nativeDefinition?.lifecycle.createdAtUnixMilliseconds += 1
        #expect(throws: (any Error).self) { try wrongRollback.validate(update: fixture.update, rollback: true) }
    }

    @Test("legacy publication removes only obsolete receipt keys and cannot manufacture native authority")
    func legacyPublicationPreservesSourceAuthority() throws {
        var fixture = try DesktopUpdateContractFixture()
        var source = try fixture.update.sourceConfiguration
        source.environment = [
            "DORY_DESKTOP_DISTRO": "ubuntu",
            DoryInstalledDesktopPayloadReceipt.legacyReleaseVersionEnvironmentKey: "previous-release",
            DoryInstalledDesktopPayloadReceipt.legacyInputSHA256EnvironmentKey: desktopDigest("e"),
            "USER_SETTING": "retained",
        ]
        fixture.update.sourceConfigurationData = try DoryMachineDesktopUpdateJournal.canonicalData(source)
        let sourceSHA256 = DoryMachineDesktopUpdateJournal.sha256(fixture.update.sourceConfigurationData)
        let definition = try fixture.update.sourceWorkspace.definition
        fixture.update.sourceWorkspaceData = try DoryMachineDesktopUpdateJournal.canonicalData(
            DoryWorkspaceRepositoryRecord(definition: definition,
                                          legacyConfigurationSHA256: sourceSHA256,
                                          legacyMigrationFactsSHA256: desktopDigest("c"))
        )
        fixture.operation.source.configurationAuthority?.legacyConfigurationSHA256 = sourceSHA256
        fixture.operation.target.definitionRevision = nil
        fixture.operation.desktopUpdateSpecificationDigest = try DoryOperationSpecification(canonical: fixture.update).digest
        try fixture.update.validate(operation: fixture.operation)
        let installed = try fixture.update.installedConfiguration(inputSHA256: desktopDigest("a"))
        #expect(installed.environment == ["DORY_DESKTOP_DISTRO": "ubuntu", "USER_SETTING": "retained"])
        var publication = DoryMachineDesktopUpdatePublication(
            configurationData: try DoryMachineDesktopUpdateJournal.canonicalData(installed),
            nativeDefinition: nil, expectedWorkspaceRevision: definition.lifecycle.revision
        )
        try publication.validate(update: fixture.update, rollback: false)
        publication.nativeDefinition = definition
        #expect(throws: (any Error).self) { try publication.validate(update: fixture.update, rollback: false) }
        let rollback = DoryMachineDesktopUpdatePublication(
            configurationData: fixture.update.sourceConfigurationData,
            nativeDefinition: nil, expectedWorkspaceRevision: definition.lifecycle.revision + 1
        )
        try rollback.validate(update: fixture.update, rollback: true)
        #expect(try rollback.configuration.environment == source.environment)
    }

    @Test("a same-component legacy reinstall does not promise an invented definition revision")
    func sameComponentLegacyReinstallDefersRevision() throws {
        var fixture = try DesktopUpdateContractFixture()
        let source = try fixture.update.installedConfiguration(inputSHA256: desktopDigest("a"))
        fixture.update.sourceConfigurationData = try DoryMachineDesktopUpdateJournal.canonicalData(source)
        let sourceSHA256 = DoryMachineDesktopUpdateJournal.sha256(fixture.update.sourceConfigurationData)
        let definition = try fixture.update.sourceWorkspace.definition
        fixture.update.sourceWorkspaceData = try DoryMachineDesktopUpdateJournal.canonicalData(
            DoryWorkspaceRepositoryRecord(definition: definition,
                                          legacyConfigurationSHA256: sourceSHA256,
                                          legacyMigrationFactsSHA256: desktopDigest("c"))
        )
        fixture.operation.source.configurationAuthority?.legacyConfigurationSHA256 = sourceSHA256
        fixture.operation.target.definitionRevision = nil
        fixture.operation.desktopUpdateSpecificationDigest = try DoryOperationSpecification(canonical: fixture.update).digest
        try fixture.update.validate(operation: fixture.operation)
        let repeated = try fixture.update.installedConfiguration(inputSHA256: desktopDigest("a"))
        #expect(try DoryMachineDesktopUpdateJournal.canonicalData(repeated) == fixture.update.sourceConfigurationData)
        let publication = DoryMachineDesktopUpdatePublication(
            configurationData: fixture.update.sourceConfigurationData,
            nativeDefinition: nil, expectedWorkspaceRevision: definition.lifecycle.revision
        )
        try publication.validate(update: fixture.update, rollback: false)
        try withLease(fixture) { _, lease in
            let replayed = try DoryMachineDesktopUpdateJournal.read(from: lease)
            #expect(replayed == fixture.update)
        }
        fixture.operation.target.definitionRevision = definition.lifecycle.revision + 1
        #expect(throws: (any Error).self) { try fixture.update.validate(operation: fixture.operation) }
    }

    @Test("private update bytes and immutable checkpoints survive exact replay and reject replacement")
    func checkpointReplayAndPrivateSpecification() throws {
        let fixture = try DesktopUpdateContractFixture()
        try withLease(fixture) { store, lease in
            #expect(try DoryMachineDesktopUpdateJournal.read(from: lease) == fixture.update)
            let qualified = DoryMachineDesktopUpdateQualification(
                inputSHA256: desktopDigest("a"), planSHA256: desktopDigest("b"),
                operationID: fixture.update.request.operationID
            )
            try lease.publishDesktopCheckpoint(qualified, at: .qualified)
            let firstEvents = try lease.events()
            try lease.publishDesktopCheckpoint(qualified, at: .qualified)
            #expect(try lease.events() == firstEvents)
            var changed = qualified
            changed.operationID = UUID()
            #expect(throws: (any Error).self) { try lease.publishDesktopCheckpoint(changed, at: .qualified) }
            #expect(try lease.events() == firstEvents)
            #expect(try lease.desktopCheckpoint(.qualified, as: DoryMachineDesktopUpdateQualification.self) == qualified)

            let digest = try #require(fixture.operation.desktopUpdateSpecificationDigest)
            let path = store.operationDirectory(for: fixture.operation.operationID) + "/specs/objects/" + digest
            try Data("substituted recovery source".utf8).write(to: URL(fileURLWithPath: path))
            #expect(throws: (any Error).self) { try DoryMachineDesktopUpdateJournal.read(from: lease) }
        }
    }

    @Test("ambiguous checkpoint history cannot choose a convenient publication",
          arguments: [false, true])
    func ambiguousCheckpointIsRejected(tamperManifest: Bool) throws {
        let fixture = try DesktopUpdateContractFixture()
        try withLease(fixture) { store, lease in
            try lease.publishDesktopCheckpoint("first", at: .snapshotReady)
            let prefix = "desktop.checkpoint.snapshot-ready."
            let event = try #require(try lease.events().first { $0.stepID.hasPrefix(prefix) })
            let digest = String(event.stepID.dropFirst(prefix.count))
            if tamperManifest {
                let path = store.operationDirectory(for: fixture.operation.operationID) + "/manifests/objects/" + digest
                try Data(#""different""#.utf8).write(to: URL(fileURLWithPath: path))
            } else {
                let secondDigest = try lease.publishManifest(DoryMachineDesktopUpdateJournal.canonicalData("second"))
                let state = try lease.read().state
                _ = try lease.transition(to: state.phase, status: state.status, expectedRevision: state.revision,
                                         stepID: prefix + secondDigest)
            }
            #expect(throws: (any Error).self) { try lease.desktopCheckpoint(.snapshotReady, as: String.self) }
        }
    }

    @Test("checkpoint replay reacquires its private root and cannot annotate an ordinary start")
    func checkpointReplayRequiresDesktopRoot() throws {
        let fixture = try DesktopUpdateContractFixture()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-replay-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = try DoryOperationJournalStore(home: home.path)
        var lease: DoryOperationLease? = try store.begin(
            fixture.operation.journalBinding(dependencyClosureDigest: desktopDigest("9")),
            desktopUpdateSpecification: DoryOperationSpecification(canonical: fixture.update)
        )
        try #require(lease).publishDesktopCheckpoint(fixture.update.snapshotID, at: .snapshotReady)
        let firstPlan = try #require(fixture.update.sourceRuntimeIdentity.resolvedPlan)
        try #require(lease).publishDesktopCheckpoint(firstPlan, at: .sourcePlan)
        var renewedPlan = firstPlan
        renewedPlan.planRevision += 1
        renewedPlan.resourceAdmission?.admissionIdentity = "renewed-admission"
        try #require(lease).publishDesktopCheckpoint(renewedPlan, at: .sourcePlan)
        let events = try #require(lease).events()
        lease = nil
        do {
            let recovered = try store.acquire(fixture.operation.operationID)
            #expect(try recovered.desktopCheckpoint(.snapshotReady, as: String.self) == fixture.update.snapshotID)
            #expect(try recovered.desktopCheckpoint(.sourcePlan, as: DoryResolvedMachinePlan.self) == renewedPlan)
            try recovered.publishDesktopCheckpoint(fixture.update.snapshotID, at: .snapshotReady)
            try recovered.publishDesktopCheckpoint(renewedPlan, at: .sourcePlan)
            #expect(try recovered.events() == events)
        }
        var start = fixture.operation
        start.operationID = UUID()
        start.kind = .starting
        start.source.state = .stopped
        start.source.workspaceID = "plain-start"
        start.target = start.source
        start.target.state = .running
        start.desktopUpdateSpecificationDigest = nil
        #expect(start.validate().isEmpty)
        let startLease = try store.begin(start.journalBinding(dependencyClosureDigest: desktopDigest("9")))
        let originalEvents = try startLease.events()
        #expect(throws: (any Error).self) {
            try startLease.publishDesktopCheckpoint("unbound", at: .snapshotReady)
        }
        #expect(try startLease.events() == originalEvents)
    }

    @Test("renewed admission appends a later plan while preserving its desired composition",
          arguments: [DoryMachineDesktopUpdateCheckpoint.sourcePlan, .targetPlan, .rollbackPlan])
    func planCheckpointRenewal(checkpoint: DoryMachineDesktopUpdateCheckpoint) throws {
        let fixture = try DesktopUpdateContractFixture()
        try withLease(fixture) { _, lease in
            let first = try #require(fixture.update.sourceRuntimeIdentity.resolvedPlan)
            try lease.publishDesktopCheckpoint(first, at: checkpoint)
            let initialEvents = try lease.events()
            try lease.publishDesktopCheckpoint(first, at: checkpoint)
            #expect(try lease.events() == initialEvents)
            var renewed = first
            renewed.planRevision += 1
            renewed.resourceAdmission?.admissionIdentity = "renewed-admission"
            #expect(renewed.validate().isEmpty)
            try lease.publishDesktopCheckpoint(renewed, at: checkpoint)
            #expect(try lease.desktopCheckpoint(checkpoint, as: DoryResolvedMachinePlan.self) == renewed)
            let renewedEvents = try lease.events()
            #expect(renewedEvents.count == initialEvents.count + 1)
            var sameRevision = renewed
            sameRevision.resourceAdmission?.admissionIdentity = "substituted-admission"
            var changedDefinition = renewed
            changedDefinition.planRevision += 1
            changedDefinition.definitionSHA256 = desktopDigest("f")
            for invalid in [first, sameRevision, changedDefinition] {
                #expect(invalid.validate().isEmpty)
                #expect(throws: (any Error).self) { try lease.publishDesktopCheckpoint(invalid, at: checkpoint) }
            }
            #expect(throws: (any Error).self) { try lease.publishDesktopCheckpoint("not-a-plan", at: checkpoint) }
            #expect(try lease.events() == renewedEvents)
            #expect(try DoryMachineDesktopUpdateJournal.read(from: lease) == fixture.update)
        }
    }

    @Test("recovery validates the complete plan renewal history instead of trusting the latest event",
          arguments: [false, true])
    func rejectsCorruptRenewalHistory(tamperEarlierManifest: Bool) throws {
        let fixture = try DesktopUpdateContractFixture()
        try withLease(fixture) { store, lease in
            let first = try #require(fixture.update.sourceRuntimeIdentity.resolvedPlan)
            try lease.publishDesktopCheckpoint(first, at: .targetPlan)
            var renewed = first
            renewed.planRevision += 1
            renewed.resourceAdmission?.admissionIdentity = "renewed-admission"
            try lease.publishDesktopCheckpoint(renewed, at: .targetPlan)
            let prefix = "desktop.checkpoint.target-plan."
            if tamperEarlierManifest {
                let firstEvent = try #require(try lease.events().first { $0.stepID.hasPrefix(prefix) })
                let digest = String(firstEvent.stepID.dropFirst(prefix.count))
                let path = store.operationDirectory(for: fixture.operation.operationID) + "/manifests/objects/" + digest
                try DoryMachineDesktopUpdateJournal.canonicalData(renewed).write(to: URL(fileURLWithPath: path))
            } else {
                var substituted = renewed
                substituted.planRevision += 1
                substituted.definitionSHA256 = desktopDigest("f")
                let digest = try lease.publishManifest(DoryMachineDesktopUpdateJournal.canonicalData(substituted))
                let state = try lease.read().state
                _ = try lease.transition(to: state.phase, status: state.status, expectedRevision: state.revision,
                                         stepID: prefix + digest)
            }
            #expect(throws: (any Error).self) {
                try lease.desktopCheckpoint(.targetPlan, as: DoryResolvedMachinePlan.self)
            }
        }
    }

    private func withLease(
        _ fixture: DesktopUpdateContractFixture,
        body: (DoryOperationJournalStore, DoryOperationLease) throws -> Void
    ) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-private-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = try DoryOperationJournalStore(home: home.path)
        let binding = try fixture.operation.journalBinding(dependencyClosureDigest: desktopDigest("9"))
        let specification = try DoryOperationSpecification(canonical: fixture.update)
        let lease = try store.begin(binding, desktopUpdateSpecification: specification)
        try body(store, lease)
    }
}

/// Structural control-plane fixture; these invented hashes are never physical guest evidence.
private struct DesktopUpdateContractFixture {
    var update: DoryMachineDesktopUpdateJournal
    var operation: DoryWorkspaceLifecycleOperation

    init() throws {
        let source = DoryMachineConfiguration(
            id: "desktop", guestArchitecture: .arm64,
            kernelPath: "/fixture/desktop/kernel", rootfsPath: "/fixture/desktop/rootfs.ext4",
            memoryMB: 8_192, cpuCount: 4, displayMode: .desktop
        )
        var definition = try DoryMachineConfigurationMigrationBridge.migrate(
            source,
            facts: .init(guestArchitecture: .arm64, systemDiskCapacityBytes: 64 * 1_073_741_824,
                         lifecycle: .init(revision: 3, createdAtUnixMilliseconds: 1_700_000_000_000,
                                          updatedAtUnixMilliseconds: 1_700_000_000_000))
        ).definition
        definition.graphics = .init(acceptableLevels: [.software])
        definition.guestIdentityIntent.desktop = .init(distributionIdentifier: "ubuntu")
        definition.resources = DoryVMProductionResourceBudget.make(for: definition)
        let plan = try desktopPlan(definition: definition)
        #expect(plan.validate().isEmpty)
        let runtime = try DoryMachineRuntimeIdentity(resolvedPlan: plan, planSHA256: plan.canonicalSHA256())
        let request = DoryDesktopUpdateRequest(distro: "ubuntu", version: "24.04.4",
                                              distributionInstallationName: "ubuntu-v2", runtimeInstallationName: "runtime-v2")
        update = DoryMachineDesktopUpdateJournal(
            request: request, machineID: source.id,
            sourceConfigurationData: try DoryMachineDesktopUpdateJournal.canonicalData(source),
            sourceWorkspaceData: try DoryMachineDesktopUpdateJournal.canonicalData(DoryWorkspaceRepositoryRecord(definition: definition)),
            sourceRuntimeIdentity: runtime, sourceRuntimeOperationID: UUID(),
            componentAuthority: .verifiedUpdate(
                distributionIdentifier: "ubuntu", releaseVersion: request.version,
                inputSHA256: String(repeating: "0", count: 64), bundleSHA256: desktopDigest("a"),
                distributionComponentIdentifier: DoryComponentID.desktopUbuntu.rawValue,
                distributionInstallationName: request.distributionInstallationName, distributionCatalogSHA256: desktopDigest("b"),
                bundleAssetIdentifier: DoryInstalledDesktopPayloadReceipt.bundleAssetIdentifier(for: "ubuntu"),
                runtimeComponentIdentifier: DoryComponentID.linuxDesktop.rawValue,
                runtimeInstallationName: request.runtimeInstallationName, runtimeCatalogSHA256: desktopDigest("c"),
                kernelAssetIdentifier: DoryInstalledDesktopPayloadReceipt.kernelAssetIdentifier, kernelSHA256: desktopDigest("d")
            ),
            snapshotID: "du-" + request.operationID.uuidString.lowercased()
        )
        operation = DoryWorkspaceLifecycleOperation(
            operationID: request.operationID, kind: .updating,
            source: .init(workspaceID: source.id, state: .running, definitionRevision: 3,
                          runtime: try desktopRuntimeBinding(runtime),
                          configurationAuthority: .init(legacyConfigurationSHA256: DoryMachineDesktopUpdateJournal.sha256(update.sourceConfigurationData),
                                                        canonicalDefinitionSHA256: try DoryMachineDesktopUpdateJournal.digest(definition))),
            target: .init(workspaceID: source.id, state: .running, definitionRevision: 4,
                          desktopUpdate: .init(authoritySHA256: try update.authoritySHA256, virtualHardwareABIVersion: 1)),
            createdAtUnixMilliseconds: 1_700_000_000_000, deadlineUnixMilliseconds: 1_700_000_060_000,
            steps: [.init(id: "update", stage: .mutate, deadlineOffsetMilliseconds: 30_000)],
            readinessGates: [.init(kind: .backendRunning, deadlineOffsetMilliseconds: 50_000)],
            cancellationPolicy: .rollbackRequired,
            recovery: .init(disposition: .rollback, stepIDs: ["update"]),
            desktopUpdateSpecificationDigest: try DoryOperationSpecification(canonical: update).digest
        )
        #expect(operation.validate().isEmpty)
    }
}

private func desktopRuntimeBinding(_ runtime: DoryMachineRuntimeIdentity) throws -> DoryWorkspaceRuntimeBinding {
    let plan = try #require(runtime.resolvedPlan)
    return .resolvedPlan(
        .init(planRevision: plan.planRevision, planDigest: try #require(runtime.resolvedPlanSHA256),
              backendID: plan.backend.rawValue, backendRuntimeBuildID: plan.backendRuntimeBuildIdentifier,
              virtualHardwareABIVersion: runtime.virtualHardwareABIVersion),
        runtimeIdentityDigest: try DoryMachineDesktopUpdateJournal.digest(runtime)
    )
}

private func desktopPlan(definition: DoryVirtualMachineDefinition) throws -> DoryResolvedMachinePlan {
    let devices = DoryDaemonVirtualMachinePlanningCoordinator.devices(for: definition)
    let boot = try #require(definition.boot.devices.first)
    let media = DoryBootMedia(kind: boot.kind, source: boot.source, artifactSHA256: desktopDigest("a"))
    let runtimeBuild = "desktop-fixture-1"
    let guest = definition.guest
    let resources = definition.resources
    let artifacts = (
        resolvedBootLaunchArtifacts(reference: boot.artifact, media: media)
            + [resolvedMutableStorageLaunchArtifact(reference: definition.storage[0].artifact,
                                                    source: .userProvided, identifier: "system")]
    ).sorted {
        ($0.resolverReference.namespace, $0.resolverReference.identifier)
            < ($1.resolverReference.namespace, $1.resolverReference.identifier)
    }
    return DoryResolvedMachinePlan(
        machineID: definition.identity.id, definitionRevision: definition.lifecycle.revision,
        definitionSHA256: try DoryMachineDesktopUpdateJournal.digest(definition), planRevision: 2,
        createdAtUnixMilliseconds: 1_700_000_000_000, updatedAtUnixMilliseconds: 1_700_000_000_000,
        guest: guest, backend: .doryHypervisor, backendImplementationIdentifier: "dory.raw-hv-linux.compatibility.v1",
        backendRuntimeBuildIdentifier: runtimeBuild, virtualHardwareABIVersion: 1,
        armVirtTopology: resolvedARMVirtTestTopology(devices: devices),
        bootMedia: .init(resolverReference: boot.artifact, media: media),
        launchArtifacts: artifacts,
        components: [.init(componentIdentifier: "dory-hv", buildIdentifier: runtimeBuild, artifactSHA256: desktopDigest("b"))],
        devices: devices, graphics: .software, portForwards: [], supportTier: .supported,
        selectionEvidence: .init(disposition: .primary,
                                 plannerRequest: .init(guest: guest, bootMedia: media, acceptableGraphics: [.software], devices: devices,
                                                       backendPreferences: [.doryHypervisor], backendPreferencePolicy: .required),
                                 selectedEvaluationIndex: 0, rejectedCandidates: []),
        qualificationEvidence: .init(
            graphics: .init(manifestIdentity: "graphics-1", artifactSHA256: desktopDigest("a"), manifestSHA256: desktopDigest("c"),
                            signingKeyID: "fixture-key", manifestFormatVersion: 1),
            runtime: .init(qualificationIdentity: "runtime-1", qualificationReportSHA256: desktopDigest("d"),
                           signingKeyID: "fixture-key", qualificationFormatVersion: 1, guest: guest,
                           bootMediaKind: media.kind, immutableArtifactSHA256: media.artifactSHA256,
                           backend: .doryHypervisor, backendRuntimeBuildID: runtimeBuild, virtualHardwareABIVersion: 1,
                           graphics: .software, devices: devices)
        ),
        resourceAdmission: .init(
            admittedVirtualCPUCount: resources.virtualCPUCount, admittedMemoryBytes: resources.memoryBytes,
            admittedStorageBytes: resources.diskBytes, hostLogicalCPUCount: 12,
            hostPhysicalMemoryBytes: 32 * 1_073_741_824, hostFreeStorageBytes: 512 * 1_073_741_824,
            existingVirtualCPUCommitment: 0, existingMemoryCommitmentBytes: 0, existingStorageReservationBytes: 0,
            hostReservedLogicalCPUCount: 2, hostReservedMemoryBytes: 4 * 1_073_741_824, hostReservedStorageBytes: 4 * 1_073_741_824,
            admissionIdentity: "admission-1", admissionReportSHA256: desktopDigest("e"),
            assessorIdentifier: "fixture-resource-policy", assessorVersion: 1
        ),
        hostQualification: .init(qualificationIdentity: "host-1", qualificationReportSHA256: desktopDigest("f"),
                                 hostHardwareModelIdentifier: "Mac16.1", hostOperatingSystemBuild: "26A5406c",
                                 backend: .doryHypervisor, backendRuntimeBuildIdentifier: runtimeBuild,
                                 virtualHardwareABIVersion: 1, qualifierIdentifier: "fixture-host", qualifierVersion: 1),
        resources: resources, persistence: resolvedPersistenceTestBinding(machineID: definition.identity.id)
    )
}

private func desktopDigest(_ character: Character) -> String { String(repeating: character, count: 64) }
