import DoryOperations
import Foundation
import XCTest
@testable import DorydKit
@testable import DoryVZMacCore

final class DoryMachineNativeMacDisplayRepairJournalTests: XCTestCase {
    func testRepairChangesOnlyDisplayBudgetBootAndMonotonicRevision() throws {
        let repair = try fixture()
        let original = try repair.sourceWorkspace.definition
        XCTAssertEqual(repair.targetDefinition.displays.count, 1)
        XCTAssertEqual(repair.targetDefinition.displays[0].widthPixels, 1920)
        XCTAssertEqual(repair.targetDefinition.displays[0].id, "display-0")
        XCTAssertEqual(repair.targetDefinition.lifecycle.revision, original.lifecycle.revision + 1)
        XCTAssertEqual(repair.targetDefinition.lifecycle.createdAtUnixMilliseconds, original.lifecycle.createdAtUnixMilliseconds)
        XCTAssertEqual(repair.targetDefinition.storage, original.storage)
        XCTAssertEqual(repair.targetDefinition.platform, original.platform)
        XCTAssertEqual(repair.targetDefinition.resources, DoryVMProductionResourceBudget.make(for: repair.targetDefinition))
        let operation = try operation(repair)
        XCTAssertTrue(operation.validate().isEmpty, "\(operation.validate())")
        XCTAssertNoThrow(try repair.validate(operation: operation))
        XCTAssertEqual(operation.source.state, .failed)
        XCTAssertEqual(operation.target.state, .stopped)
        XCTAssertEqual(operation.target.runtime?.authorizationState, .requiresReplanning)
        XCTAssertTrue(operation.readinessGates.isEmpty)
    }

    func testExactPrivateSpecificationSurvivesJournalReloadAndRejectsMissingInput() throws {
        let repair = try fixture(), operation = try operation(repair)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("dory-display-repair-journal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        let store = try DoryOperationJournalStore(home: base.path)
        try store.prepare()
        let binding = try operation.journalBinding(dependencyClosureDigest: String(repeating: "e", count: 64))
        XCTAssertThrowsError(try store.begin(binding))
        var lease: DoryOperationLease? = try store.begin(binding,
            nativeMacDisplayRepairSpecification: DoryOperationSpecification(canonical: repair))
        XCTAssertEqual(try DoryMachineNativeMacDisplayRepairJournal.read(from: XCTUnwrap(lease)), repair)
        lease = nil
        lease = try store.acquire(operation.operationID)
        XCTAssertEqual(try DoryMachineNativeMacDisplayRepairJournal.read(from: XCTUnwrap(lease)), repair)
        XCTAssertEqual(try lease?.read().plan.kind, .workspaceRepair)
        lease = nil
    }

    func testChangedChoiceIdentityDiskRevisionOrConfigurationCannotReuseRoot() throws {
        let original = try fixture(), root = try operation(original)
        for vector in ["choice", "hash", "id", "schema", "configuration", "disk", "revision", "display", "runtime"] {
            var repair = original
            switch vector {
            case "choice": repair.selectedDisplayIndex = 0
            case "hash": repair.originalManifestSHA256 = String(repeating: "f", count: 64)
            case "id": repair.operationID = UUID()
            case "schema": repair.schemaVersion = 2
            case "configuration": repair.sourceConfigurationData.append(Data(" ".utf8))
            case "disk": repair.targetDefinition.storage[0].capacityBytes += 1
            case "revision": repair.targetDefinition.lifecycle.revision += 1
            case "display": repair.targetDefinition.displays[0].heightPixels += 1
            default: repair.targetRuntimeIdentity = .legacyCompatibility(virtualHardwareABIVersion: 1)
            }
            XCTAssertThrowsError(try repair.validate(operation: root), vector)
        }
    }

    func testRepairCannotBecomeStartResumeOrRunningAuthority() throws {
        let repair = try fixture(), valid = try operation(repair)
        for kind in [DoryWorkspaceMutationKind.starting, .restoring, .updating, .stopping, .resuming] {
            var wrong = valid; wrong.kind = kind
            XCTAssertFalse(wrong.validate().isEmpty)
            XCTAssertThrowsError(try repair.validate(operation: wrong))
        }
        var running = valid; running.target.state = .running
        XCTAssertFalse(running.validate().isEmpty)
        XCTAssertThrowsError(try repair.validate(operation: running))
    }

    func testXPCRepairRequestRequiresCanonicalUUIDExactKeysAndIntegerChoice() throws {
        let id = UUID().uuidString.lowercased()
        let value: NSDictionary = ["operationID": id, "nativeMacDisplayRepair": ["schemaVersion": 1,
            "originalManifestSHA256": String(repeating: "a", count: 64), "selectedDisplayIndex": 1]]
        XCTAssertEqual(try MachineNativeMacDisplayRepairRequest(value).selectedDisplayIndex, 1)
        for vector in ["uuid", "zero", "extra", "path", "bool", "float", "negative", "range", "schema", "hash"] {
            let outer = NSMutableDictionary(dictionary: value)
            let inner = NSMutableDictionary(dictionary: value["nativeMacDisplayRepair"] as! NSDictionary)
            switch vector {
            case "uuid": outer["operationID"] = id.uppercased()
            case "zero": outer["operationID"] = "00000000-0000-0000-0000-000000000000"
            case "extra": outer["memoryMB"] = 1024
            case "path": inner["bundlePath"] = "/unowned"
            case "bool": inner["selectedDisplayIndex"] = true
            case "float": inner["selectedDisplayIndex"] = 1.5
            case "negative": inner["selectedDisplayIndex"] = -1
            case "range": inner["selectedDisplayIndex"] = 8
            case "schema": inner["schemaVersion"] = 2
            default: inner["originalManifestSHA256"] = String(repeating: "A", count: 64)
            }
            outer["nativeMacDisplayRepair"] = inner
            XCTAssertThrowsError(try MachineNativeMacDisplayRepairRequest(outer), vector)
        }
    }

    func testJournalRejectsLegacyProjectionAndUnsupportedGeometryWithoutPublication() throws {
        var repair = try fixture()
        let original = try repair.sourceWorkspace
        repair.sourceWorkspaceData = try JSONEncoder().encode(DoryWorkspaceRepositoryRecord(
            definition: original.definition, legacyConfigurationSHA256: String(repeating: "a", count: 64)))
        XCTAssertThrowsError(try repair.validate(operation: operation(repair)))
        var unsupported = original.definition
        unsupported.lifecycle.revision = UInt64.max
        XCTAssertThrowsError(try DoryMachineNativeMacDisplayRepairJournal.definition(from: unsupported,
            manifest: fixture().targetManifest, updatedAt: 1000))
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture().targetManifest)) as? [String: Any])
        var resources = try XCTUnwrap(raw["resources"] as? [String: Any])
        resources["displays"] = [["widthInPixels": 16385, "heightInPixels": 1080, "pixelsPerInch": 144]]
        raw["resources"] = resources
        let large = try JSONDecoder().decode(DoryVZMacMachineManifest.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertThrowsError(try DoryMachineNativeMacDisplayRepairJournal.definition(from: original.definition,
            manifest: large, updatedAt: 1000))
    }

    private func operation(_ repair: DoryMachineNativeMacDisplayRepairJournal) throws -> DoryWorkspaceLifecycleOperation {
        .init(operationID: repair.operationID, kind: .repairing,
            source: try repair.condition(target: false), target: try repair.condition(target: true),
            createdAtUnixMilliseconds: 1000, deadlineUnixMilliseconds: 100_000,
            steps: [.init(id: "repair", stage: .mutate, deadlineOffsetMilliseconds: 90_000)],
            cancellationPolicy: .beforeGuestMutation, recovery: .init(disposition: .retry, stepIDs: ["repair"]),
            nativeMacDisplayRepairSpecificationDigest: try DoryOperationSpecification(canonical: repair).digest)
    }

    private func fixture() throws -> DoryMachineNativeMacDisplayRepairJournal {
        let resources = try DoryVZMacResourcePlan(requestedCPUCount: 4, requestedMemoryBytes: 8 * DoryVZMacResourcePlan.gibibyte,
            requestedDiskBytes: 80 * DoryVZMacResourcePlan.gibibyte,
            requestedDisplays: [.init(widthInPixels: 1920, heightInPixels: 1080, pixelsPerInch: 144)],
            minimumCPUCount: 2, minimumMemoryBytes: 4 * DoryVZMacResourcePlan.gibibyte,
            maximumCPUCount: 8, maximumMemoryBytes: 32 * DoryVZMacResourcePlan.gibibyte)
        let manifest = DoryVZMacMachineManifest(createdAt: "2026-09-22T00:00:00Z", installationState: .stopped, origin: .created,
            parentMachineIdentifierSHA256: nil, restoreImageBuild: "26A123", restoreImageVersion: "27.0",
            restoreImageSourceURL: "https://example.invalid/restore.ipsw", restoreImageBytes: 1,
            restoreImageSHA256: String(repeating: "a", count: 64), hardwareModelSHA256: String(repeating: "b", count: 64),
            machineIdentifierSHA256: String(repeating: "c", count: 64), macAddress: "02:11:22:33:44:55", resources: resources)
        let guest = DoryGuestPlatform(family: .macOS, architecture: .arm64)
        let graphics = DoryVMGraphicsPolicy(acceptableLevels: [.hostAcceleratedDisplay])
        let system = MachineManager.nativeMacOSSystemDiskReference(machineID: "mac", manifest: manifest)
        var definition = DoryVirtualMachineDefinition(identity: .init(id: "mac", name: "mac"), guest: guest, workload: .desktop,
            boot: try MachineManager.nativeMacOSBootConfiguration(installationState: .stopped,
                restoreReference: MachineManager.nativeMacOSRestoreReference(machineID: "mac", manifest: manifest), systemReference: system),
            graphics: graphics, resources: .init(virtualCPUCount: 4, memoryBytes: resources.memoryBytes, diskBytes: resources.diskBytes),
            storage: [.init(id: "system", role: .system, artifact: system, source: .userProvided, capacityBytes: resources.diskBytes)],
            displays: [.init(), .init(id: "display-1", widthPixels: 1920, heightPixels: 1080, pixelsPerInch: 144)],
            lifecycle: .init(revision: 3, createdAtUnixMilliseconds: 100, updatedAtUnixMilliseconds: 200))
        definition.resources = DoryVMProductionResourceBudget.make(for: definition)
        XCTAssertTrue(definition.validate().isEmpty, "\(definition.validate())")
        let machine = DoryMachineConfiguration(id: "mac", guestFamily: .macOS, guestArchitecture: .arm64,
            kernelPath: "/owned/mac/Restore.ipsw", rootfsPath: "/owned/mac/Machine.dorymac/Disk.img", bootMode: .macOSRestore,
            macOSRestoreImagePath: "/owned/mac/Restore.ipsw", macOSMachineBundlePath: "/owned/mac/Machine.dorymac",
            diskSizeBytes: resources.diskBytes, memoryMB: 8192, cpuCount: 4, displayMode: .desktop)
        return .init(operationID: UUID(), machineID: "mac", originalManifestSHA256: String(repeating: "a", count: 64), selectedDisplayIndex: 1,
            sourceConfigurationData: try DoryMachineConfigurationMigrationBridge.encodeLegacy(machine),
            sourceWorkspaceData: try JSONEncoder().encode(DoryWorkspaceRepositoryRecord(definition: definition)),
            sourceRuntimeIdentity: .requiresReplanning(virtualHardwareABIVersion: 1, reason: .planRecoveryFailed), targetManifest: manifest,
            targetDefinition: try DoryMachineNativeMacDisplayRepairJournal.definition(from: definition, manifest: manifest, updatedAt: 1000),
            targetRuntimeIdentity: .requiresReplanning(virtualHardwareABIVersion: 1, reason: .definitionChanged))
    }
}
