import DoryOperations
import Foundation
import Testing
@testable import DorydKit

@Suite("Private workspace creation authority")
struct DoryMachineCreationTests {
    @Test("synchronous create cannot publish caller-prepared native platform identity")
    func nativeCreationRequiresPreparation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("creation-native-boundary-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = MachineManager(configuration: .init(vmmExecutablePath: "/unused", stateDirectory: root.path,
            requiresReadyHandoff: false))
        let machine = DoryMachineConfiguration(id: "native", guestFamily: .macOS, guestArchitecture: .arm64,
            kernelPath: "", rootfsPath: "", bootMode: .macOSRestore,
            macOSRestoreImagePath: "/caller/Restore.ipsw", macOSMachineBundlePath: "/caller/Machine.dorymac",
            displayMode: .desktop)
        do {
            _ = try manager.create(machine)
            Issue.record("synchronous creation accepted caller-owned native platform identity")
        } catch {
            #expect(String(describing: error).contains("asynchronous daemon-owned platform preparation"))
        }
        #expect(manager.status(id: machine.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(machine.id).path))
    }

    @Test("normalized creation remains bound to exact caller intent", arguments: ["cpu", "kernel", "target", "request", "directory", "timestamp", "policy"])
    func intentCannotBeSubstituted(mutation: String) throws {
        var fixture = try CreationContractFixture()
        try fixture.creation.validate(operation: fixture.operation)
        switch mutation {
        case "cpu", "kernel":
            var changed = try fixture.creation.normalizedConfiguration
            if mutation == "cpu" { changed.cpuCount += 1 } else { changed.kernelPath = "/other/kernel" }
            fixture.creation.normalizedConfigurationData = try DoryMachineDesktopUpdateJournal.canonicalData(changed)
        case "target": fixture.operation.target.workspaceID = "someone-else"
        case "request": fixture.creation.request.configuration.memoryMB += 1
        case "directory": fixture.creation.machineDirectory += "/../created"
        case "timestamp": fixture.creation.createdAtUnixMilliseconds += 1
        default: fixture.creation.runtimePolicy = .legacyCompatibility
        }
        #expect(throws: (any Error).self) { try fixture.creation.validate(operation: fixture.operation) }
    }

    @Test("detached snapshots own their immutable source without invented workload authority")
    func detachedSnapshotAuthority() throws {
        var fixture = try CreationContractFixture(detachedClone: true)
        try fixture.creation.validate(operation: fixture.operation)
        #expect(fixture.operation.source.state == .absent)
        #expect(fixture.creation.sourceRuntimeIdentity == nil)
        #expect(fixture.creation.sourceWorkspaceData == nil)
        for mutation in ["runtime", "snapshot-bytes", "snapshot-id", "snapshot-isa", "snapshot-kernel"] {
            var changed = fixture.creation
            switch mutation {
            case "runtime": changed.sourceRuntimeIdentity = .legacyCompatibility()
            case "snapshot-bytes": changed.snapshot?.artifactEvidence?.rootfs.sha256 = String(repeating: "f", count: 64)
            case "snapshot-id": changed.request.sourceSnapshotID = "another"
            case "snapshot-isa": changed.snapshot?.architecture = "x86_64"
            default: changed.snapshot?.kernelPath = "/another/kernel"
            }
            #expect(throws: (any Error).self) { try changed.validate(operation: fixture.operation) }
        }
        fixture.operation.source.runtime = .legacyCompatibility(virtualHardwareABIVersion: 1, runtimeIdentityDigest: String(repeating: "a", count: 64))
        #expect(!fixture.operation.validate().isEmpty)
    }

    @Test("publication proves exact managed paths, clone receipt and native desired-state authority")
    func exactPublication() throws {
        let fixture = try CreationContractFixture(detachedClone: true)
        let publication = try fixture.publication()
        try publication.validate(creation: fixture.creation, native: nil)
        for mutation in ["disk", "receipt", "cpu", "workspace-revision", "workspace-cpu", "workspace-guest", "legacy-authority", "runtime"] {
            var changed = publication
            if mutation == "runtime" { changed.runtimeIdentity = .legacyCompatibility() }
            else if mutation.hasPrefix("workspace-") || mutation == "legacy-authority" {
                var definition = try publication.workspace.definition
                if mutation == "workspace-revision" { definition.lifecycle.revision += 1 }
                if mutation == "workspace-cpu" {
                    definition.resources = .init(virtualCPUCount: definition.resources.virtualCPUCount + 1,
                        memoryBytes: definition.resources.memoryBytes, diskBytes: definition.resources.diskBytes,
                        translationCacheBytes: definition.resources.translationCacheBytes,
                        rendererBytes: definition.resources.rendererBytes,
                        workerOverheadBytes: definition.resources.workerOverheadBytes,
                        stagingBytes: definition.resources.stagingBytes)
                }
                if mutation == "workspace-guest" { definition.guest.architecture = .x86_64 }
                let workspace = DoryWorkspaceRepositoryRecord(definition: definition,
                    legacyConfigurationSHA256: mutation == "legacy-authority" ? String(repeating: "a", count: 64) : nil)
                changed.workspaceData = try DoryMachineDesktopUpdateJournal.canonicalData(workspace)
            } else {
                var machine = try publication.configuration
                if mutation == "disk" { machine.rootfsPath = "/other/rootfs.ext4" }
                else if mutation == "receipt" { machine.cloneReceipt?.sourceMachineID = "another-source" }
                else { machine.cpuCount += 1 }
                changed.configurationData = try DoryMachineDesktopUpdateJournal.canonicalData(machine)
            }
            #expect(throws: (any Error).self) { try changed.validate(creation: fixture.creation, native: nil) }
        }
    }

    @Test("private specification and checkpoints replay immutably and reject on-disk tampering")
    func privateReplay() throws {
        let fixture = try CreationContractFixture()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("creation-private-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = try DoryOperationJournalStore(home: home.path)
        let spec = try DoryOperationSpecification(canonical: fixture.creation)
        let lease = try store.begin(fixture.operation.journalBinding(dependencyClosureDigest: spec.digest), creationSpecification: spec)
        #expect(try DoryMachineCreationJournal.read(from: lease) == fixture.creation)
        let publication = try fixture.publication()
        try lease.publishCreationCheckpoint(publication, at: .publication)
        let events = try lease.events()
        try lease.publishCreationCheckpoint(publication, at: .publication)
        #expect(try lease.events() == events)
        var changed = publication
        changed.configurationData.append(0)
        #expect(throws: (any Error).self) { try lease.publishCreationCheckpoint(changed, at: .publication) }
        #expect(throws: (any Error).self) { try lease.publishCreationCheckpoint("not-a-plan", at: .plan) }
        let prefix = "creation.checkpoint.publication."
        let event = try #require(events.first { $0.stepID.hasPrefix(prefix) })
        let digest = String(event.stepID.dropFirst(prefix.count))
        let path = store.operationDirectory(for: fixture.operation.operationID) + "/manifests/objects/" + digest
        try DoryMachineDesktopUpdateJournal.canonicalData(changed).write(to: URL(fileURLWithPath: path))
        #expect(throws: (any Error).self) { try lease.creationCheckpoint(.publication, as: DoryMachineCreationPublication.self) }
    }
}

private struct CreationContractFixture {
    var creation: DoryMachineCreationJournal
    var operation: DoryWorkspaceLifecycleOperation

    init(detachedClone: Bool = false) throws {
        let machine = DoryMachineConfiguration(id: "created", guestArchitecture: .arm64,
            kernelPath: "/inputs/kernel", rootfsPath: "/inputs/rootfs", memoryMB: 2_048, cpuCount: 2)
        let snapshot: DoryMachineSnapshot? = detachedClone ? .init(id: "snapshot", machineID: "imported",
            note: "imported namespace", createdISO: "2026-09-04T00:00:00Z", rootfsPath: machine.rootfsPath,
            sizeBytes: 4096, kernelPath: machine.kernelPath, architecture: "arm64", memoryMB: machine.memoryMB,
            cpuCount: machine.cpuCount, artifactEvidence: .init(
                rootfs: .init(byteCount: 4096, sha256: String(repeating: "a", count: 64)),
                kernel: .init(byteCount: 4096, sha256: String(repeating: "b", count: 64)))) : nil
        let request = DoryMachineCreationRequest(configuration: machine, typedSettings: nil, sandboxPolicy: nil,
            sourceMachineID: snapshot?.machineID, sourceSnapshotID: snapshot?.id)
        creation = .init(operationID: UUID(), request: request,
            normalizedConfigurationData: try DoryMachineDesktopUpdateJournal.canonicalData(machine),
            machineDirectory: "/managed/created", runtimePolicy: .requireResolvedPlan, usesNativeWorkspaceAuthority: true,
            virtualHardwareABIVersion: 1, createdAtUnixMilliseconds: 1000, snapshot: snapshot)
        let descriptorEncoder = JSONEncoder()
        descriptorEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        operation = .init(operationID: creation.operationID, kind: detachedClone ? .cloning : .provisioning,
            source: .init(workspaceID: snapshot?.machineID ?? machine.id, state: .absent),
            target: .init(workspaceID: machine.id, state: .created, definitionRevision: 1,
                creation: .init(requestSHA256: try request.digest(), virtualHardwareABIVersion: 1, runtimePolicy: .requireResolvedPlan)),
            targetWorkspaceID: detachedClone ? machine.id : nil, targetResourceID: snapshot?.id,
            targetSnapshotAuthority: try snapshot.map { .init(
                descriptorSHA256: DoryMachineDesktopUpdateJournal.sha256(try descriptorEncoder.encode($0)),
                artifactEvidenceSHA256: try DoryMachineDesktopUpdateJournal.digest($0.artifactEvidence!)) },
            createdAtUnixMilliseconds: 1000, deadlineUnixMilliseconds: 2000,
            steps: [.init(id: "stage", stage: .prepare, deadlineOffsetMilliseconds: 500)],
            cancellationPolicy: .beforePublish, recovery: .init(disposition: .retry, stepIDs: ["stage"]),
            creationSpecificationDigest: try DoryOperationSpecification(canonical: creation).digest)
    }

    func publication() throws -> DoryMachineCreationPublication {
        var machine = try creation.normalizedConfiguration
        machine.kernelPath = creation.machineDirectory + "/kernel"
        machine.rootfsPath = creation.machineDirectory + "/rootfs.ext4"
        if let snapshot = creation.snapshot, let evidence = snapshot.artifactEvidence {
            machine.cloneReceipt = .init(sourceMachineID: snapshot.machineID, sourceSnapshotID: snapshot.id,
                sourceRootfsSHA256: evidence.rootfs.sha256, sourceRootfsByteCount: evidence.rootfs.byteCount,
                createdAtUnixMilliseconds: creation.createdAtUnixMilliseconds)
        }
        let definition = try DoryMachineConfigurationMigrationBridge.migrate(machine,
            facts: .init(guestArchitecture: .arm64, systemDiskCapacityBytes: 32 * 1_073_741_824,
                lifecycle: .init(revision: 1, createdAtUnixMilliseconds: 1000, updatedAtUnixMilliseconds: 1000))).definition
        return .init(configurationData: try DoryMachineDesktopUpdateJournal.canonicalData(machine),
            workspaceData: try DoryMachineDesktopUpdateJournal.canonicalData(DoryWorkspaceRepositoryRecord(definition: definition)),
            runtimeIdentity: .requiresReplanning(reason: .planNotInstalled))
    }
}
