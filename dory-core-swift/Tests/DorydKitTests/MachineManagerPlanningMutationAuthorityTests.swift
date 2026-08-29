import CryptoKit
import DoryOperations
import Foundation
import Testing
@testable import DorydKit

@Suite("MachineManager planning mutation authority")
struct MachineManagerPlanningMutationAuthorityTests {
    @Test("fence binds exact persisted machine and blocks every local mutation")
    func exactAuthorityAndLocalMutationExclusion() throws {
        try PlanningMutationFixture.withFixture("local") { fixture in
            let manager = fixture.makeManager()
            _ = try fixture.createMachine(manager)
            _ = try manager.snapshot(id: fixture.machineID, snapshotID: "before")
            let input = try fixture.input()

            let fence = try manager.acquirePlanningMutationFence(
                machine: input.machine,
                definition: input.definition,
                canonicalDefinitionData: input.canonicalDefinitionData
            )
            #expect(fence.authority.isValid)
            #expect(fence.authority.machineID == fixture.machineID)
            #expect(fence.authority.sourceDefinitionRevision
                == input.definition.lifecycle.revision)
            #expect(fence.authority.legacyConfigurationSHA256
                == Self.sha256(input.legacyData))
            #expect(fence.authority.sourceDefinitionSHA256
                == Self.sha256(input.canonicalDefinitionData))
            try fence.revalidate()

            try Self.expectFailure(containing: "active planning mutation") {
                _ = try manager.start(id: fixture.machineID)
            }
            try Self.expectFailure(containing: "active planning mutation") {
                _ = try manager.stop(id: fixture.machineID)
            }
            try Self.expectFailure(containing: "active planning mutation") {
                _ = try manager.update(id: fixture.machineID, memoryMB: 4_096)
            }
            try Self.expectFailure(containing: "active planning mutation") {
                _ = try manager.snapshot(id: fixture.machineID, snapshotID: "blocked")
            }
            try Self.expectFailure(containing: "active planning mutation") {
                _ = try manager.restoreSnapshot(
                    machineID: fixture.machineID,
                    snapshotID: "before"
                )
            }
            try Self.expectFailure(containing: "active planning mutation") {
                try manager.delete(id: fixture.machineID)
            }
            #expect(fixture.processStartCount == 0)

            try fence.complete()
            _ = try manager.update(id: fixture.machineID, memoryMB: 4_096)
            #expect(manager.status(id: fixture.machineID)?.memoryMB == 4_096)
        }
    }

    @Test("cross-process lifecycle and update mutations cannot bypass planning fence")
    func crossProcessMutationExclusion() throws {
        try PlanningMutationFixture.withFixture("cross-process") { fixture in
            let owner = fixture.makeManager()
            _ = try fixture.createMachine(owner)
            _ = try owner.snapshot(id: fixture.machineID, snapshotID: "before")
            let contender = fixture.makeManager(launchPolicy: .legacyCompatibility)
            let input = try fixture.input()
            let fence = try owner.acquirePlanningMutationFence(
                machine: input.machine,
                definition: input.definition,
                canonicalDefinitionData: input.canonicalDefinitionData
            )
            defer { fence.releaseForRecovery() }

            try Self.expectFailure(containing: "already in use") {
                _ = try contender.start(id: fixture.machineID)
            }
            try Self.expectFailure(containing: "mutation authority is busy") {
                _ = try contender.update(id: fixture.machineID, memoryMB: 4_096)
            }
            try Self.expectFailure(containing: "already in use") {
                _ = try contender.snapshot(id: fixture.machineID, snapshotID: "blocked")
            }
            try Self.expectFailure(containing: "already in use") {
                _ = try contender.restoreSnapshot(
                    machineID: fixture.machineID,
                    snapshotID: "before"
                )
            }
            try Self.expectFailure(containing: "already in use") {
                try contender.delete(id: fixture.machineID)
            }
            #expect(fixture.processStartCount == 0)
        }
    }

    @Test("raw legacy byte drift invalidates retained authority")
    func rawLegacyByteDrift() throws {
        try PlanningMutationFixture.withFixture("raw-drift") { fixture in
            let manager = fixture.makeManager()
            _ = try fixture.createMachine(manager)
            let input = try fixture.input()
            let fence = try manager.acquirePlanningMutationFence(
                machine: input.machine,
                definition: input.definition,
                canonicalDefinitionData: input.canonicalDefinitionData
            )
            defer { fence.releaseForRecovery() }

            var changed = input.legacyData
            changed.append(0x0a)
            try fixture.writePrivate(changed, path: fixture.machineJSONPath)
            try Self.expectFailure(containing: "authoritative machine state changed") {
                try fence.revalidate()
            }
            #expect(fixture.processStartCount == 0)
        }
    }

    @Test("migration-fact drift invalidates retained authority")
    func migrationFactDrift() throws {
        try PlanningMutationFixture.withFixture("facts-drift") { fixture in
            let manager = fixture.makeManager()
            _ = try fixture.createMachine(manager)
            let input = try fixture.input()
            let fence = try manager.acquirePlanningMutationFence(
                machine: input.machine,
                definition: input.definition,
                canonicalDefinitionData: input.canonicalDefinitionData
            )
            defer { fence.releaseForRecovery() }

            let rootfs = input.machine.rootfsPath
            let original = try Data(contentsOf: URL(fileURLWithPath: rootfs))
            var changed = original
            changed.append(0x51)
            try fixture.writePrivate(changed, path: rootfs)
            try Self.expectFailure(containing: "migration facts changed") {
                try fence.revalidate()
            }
            #expect(fixture.processStartCount == 0)
        }
    }

    @Test("released interrupted authority is reacquired after daemon restart")
    func restartReacquiresAuthority() throws {
        try PlanningMutationFixture.withFixture("restart") { fixture in
            var owner: MachineManager? = fixture.makeManager()
            _ = try fixture.createMachine(try #require(owner))
            let input = try fixture.input()
            let first = try #require(owner).acquirePlanningMutationFence(
                machine: input.machine,
                definition: input.definition,
                canonicalDefinitionData: input.canonicalDefinitionData
            )
            let firstAuthority = first.authority
            first.releaseForRecovery()
            owner = nil

            let recovered = fixture.makeManager()
            let recoveredInput = try fixture.input()
            let second = try recovered.acquirePlanningMutationFence(
                machine: recoveredInput.machine,
                definition: recoveredInput.definition,
                canonicalDefinitionData: recoveredInput.canonicalDefinitionData
            )
            #expect(second.authority == firstAuthority)
            try second.revalidate()
            try second.complete()
            #expect(fixture.processStartCount == 0)
        }
    }

    @Test("legacy policy and unrepresentable migration facts fail closed")
    func unsupportedPromotionFailsClosed() throws {
        try PlanningMutationFixture.withFixture("unsupported") { fixture in
            let legacy = fixture.makeManager(launchPolicy: .legacyCompatibility)
            _ = try fixture.createMachine(legacy)
            let input = try fixture.input()
            try Self.expectFailure(containing: "resolved-plan launch policy") {
                _ = try legacy.acquirePlanningMutationFence(
                    machine: input.machine,
                    definition: input.definition,
                    canonicalDefinitionData: input.canonicalDefinitionData
                )
            }

            let unsupported = fixture.makeManager(
                launchPolicy: .requireResolvedPlan,
                architecture: "mips64"
            )
            try Self.expectFailure(containing: "unsupported guest architecture") {
                _ = try unsupported.acquirePlanningMutationFence(
                    machine: input.machine,
                    definition: input.definition,
                    canonicalDefinitionData: input.canonicalDefinitionData
                )
            }
            #expect(fixture.processStartCount == 0)
        }
    }

    private static func expectFailure(
        containing fragment: String,
        _ operation: () throws -> Void
    ) throws {
        do {
            try operation()
            Issue.record("Expected operation to fail with \(fragment)")
        } catch {
            #expect(String(describing: error).contains(fragment))
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private final class PlanningMutationFixture: @unchecked Sendable {
    struct Input {
        var machine: DoryMachineConfiguration
        var legacyData: Data
        var definition: DoryVirtualMachineDefinition
        var canonicalDefinitionData: Data
    }

    let machineID = "planning-vm"
    let base: String
    let state: String
    let runtime: String
    let journal: String
    private let countLock = NSLock()
    private var _processStartCount = 0

    var processStartCount: Int { countLock.withLock { _processStartCount } }
    var machineJSONPath: String { state + "/\(machineID)/machine.json" }

    init(label: String) throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-planning-authority-\(label)-\(UUID().uuidString)")
            .path
        state = base + "/machines"
        runtime = base + "/runtime"
        journal = base + "/journal"
        try FileManager.default.createDirectory(
            atPath: base,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    static func withFixture(
        _ label: String,
        _ body: (PlanningMutationFixture) throws -> Void
    ) throws {
        let fixture = try PlanningMutationFixture(label: label)
        defer { try? FileManager.default.removeItem(atPath: fixture.base) }
        try body(fixture)
    }

    func makeManager(
        launchPolicy: DoryMachineLaunchPolicy = .requireResolvedPlan,
        architecture: String = "arm64"
    ) -> MachineManager {
        MachineManager(
            configuration: MachineManagerConfiguration(
                vmmExecutablePath: "/bin/sleep",
                stateDirectory: state,
                runtimeDirectory: runtime,
                lifecycleJournalHome: journal,
                baseArguments: ["30"],
                passMachineArguments: false,
                requiresReadyHandoff: false,
                guestArchitecture: architecture
            ),
            launchPolicy: launchPolicy,
            processStarter: { [weak self] _ in
                self?.countLock.withLock { self?._processStartCount += 1 }
            }
        )
    }

    @discardableResult
    func createMachine(_ manager: MachineManager) throws -> DoryMachineStatus {
        try manager.create(DoryMachineConfiguration(
            id: machineID,
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath,
            memoryMB: 2_048,
            cpuCount: 2
        ))
    }

    func input() throws -> Input {
        let legacyData = try Data(contentsOf: URL(fileURLWithPath: machineJSONPath))
        let machine = try JSONDecoder().decode(
            DoryMachineConfiguration.self,
            from: legacyData
        )
        let recordData = try Data(contentsOf: URL(
            fileURLWithPath: state + "/\(machineID)/" + DoryWorkspaceRepository.recordFileName
        ))
        let record = try JSONDecoder().decode(
            DoryWorkspaceRepositoryRecord.self,
            from: recordData
        )
        return Input(
            machine: machine,
            legacyData: legacyData,
            definition: record.definition,
            canonicalDefinitionData: DoryDaemonVirtualMachinePlanningCoordinator
                .canonicalDefinitionData(record.definition)
        )
    }

    func writePrivate(_ data: Data, path: String) throws {
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: path
        )
    }
}
