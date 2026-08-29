import CryptoKit
import DoryOperations
import Foundation
import Testing
@testable import DorydKit

@Suite("MachineManager workspace projection integration")
struct MachineManagerWorkspaceProjectionTests {
    private let gibibyte: UInt64 = 1_073_741_824

    @Test("create update reload and revert preserve authority with monotonic revisions")
    func createUpdateReloadAndRevert() throws {
        try withStateRoot("lifecycle") { base, state in
            let hostShare = base + "/host-secret"
            try FileManager.default.createDirectory(
                atPath: hostShare,
                withIntermediateDirectories: false
            )
            let manager = makeManager(state: state)
            _ = try manager.create(DoryMachineConfiguration(
                id: "dev",
                kernelPath: doryTestKernelPath,
                rootfsPath: doryTestRootfsPath,
                memoryMB: 2_048,
                cpuCount: 2,
                displayMode: .desktop,
                shares: [DoryMachineShareConfiguration(
                    tag: "source",
                    hostPath: hostShare,
                    guestPath: "/workspace/source"
                )],
                environment: ["PRIVATE_TOKEN": "projection-must-not-persist-this"]
            ))

            let firstLegacy = try legacyData(state: state, id: "dev")
            let firstRecord = try record(state: state, id: "dev")
            #expect(firstRecord.definition.lifecycle.revision == 1)
            #expect(firstRecord.legacyConfigurationSHA256 == sha256(firstLegacy))
            #expect(firstRecord.legacyMigrationFactsSHA256 != nil)
            #expect(manager.workspaceProjectionDiagnostic(id: "dev")?.state == .regenerated)

            let workspaceJSON = try #require(String(
                data: Data(contentsOf: URL(fileURLWithPath: recordPath(state: state, id: "dev"))),
                encoding: .utf8
            ))
            #expect(!workspaceJSON.contains(hostShare))
            #expect(!workspaceJSON.contains("projection-must-not-persist-this"))
            #expect(!workspaceJSON.contains(state + "/dev/rootfs.ext4"))
            let machineJSON = try #require(String(data: firstLegacy, encoding: .utf8))
            #expect(machineJSON.contains("projection-must-not-persist-this"))

            _ = try manager.update(id: "dev", memoryMB: 4_096)
            let secondRecord = try record(state: state, id: "dev")
            #expect(secondRecord.definition.lifecycle.revision == 2)
            #expect(secondRecord.definition.lifecycle.createdAtUnixMilliseconds
                == firstRecord.definition.lifecycle.createdAtUnixMilliseconds)
            #expect(secondRecord.definition.lifecycle.updatedAtUnixMilliseconds
                > firstRecord.definition.lifecycle.updatedAtUnixMilliseconds)
            #expect(secondRecord.definition.resources.memoryBytes == 4 * gibibyte)
            #expect(secondRecord.legacyConfigurationSHA256
                == sha256(try legacyData(state: state, id: "dev")))

            let recordBytesBeforeReload = try Data(
                contentsOf: URL(fileURLWithPath: recordPath(state: state, id: "dev"))
            )
            let reloaded = makeManager(state: state)
            #expect(reloaded.status(id: "dev")?.memoryMB == 4_096)
            #expect(reloaded.workspaceProjectionDiagnostic(id: "dev")?.state == .current)
            #expect(try Data(contentsOf: URL(
                fileURLWithPath: recordPath(state: state, id: "dev")
            )) == recordBytesBeforeReload)

            _ = try reloaded.update(id: "dev", memoryMB: 2_048)
            let reverted = try record(state: state, id: "dev")
            #expect(reverted.definition.lifecycle.revision == 3)
            #expect(reverted.definition.lifecycle.createdAtUnixMilliseconds
                == firstRecord.definition.lifecycle.createdAtUnixMilliseconds)
            #expect(reverted.definition.resources.memoryBytes == 2 * gibibyte)
        }
    }

    @Test("noncanonical authoritative bytes remain untouched and missing projection is repaired")
    func noncanonicalLegacyBytesRemainAuthoritative() throws {
        try withStateRoot("noncanonical") { _, state in
            let directory = state + "/legacy"
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            _ = chmod(directory, mode_t(0o700))
            let kernel = directory + "/kernel"
            let rootfs = directory + "/rootfs.ext4"
            try writePrivate(Data("kernel".utf8), path: kernel)
            try writePrivate(Data("rootfs".utf8), path: rootfs)
            let raw = Data(
                "{\"rootfsPath\":\"\(rootfs)\",\"id\":\"legacy\","
                    .appending("\"kernelPath\":\"\(kernel)\"}").utf8
            )
            try writePrivate(raw, path: directory + "/machine.json")

            let manager = makeManager(state: state)
            #expect(manager.status(id: "legacy")?.memoryMB == 2_048)
            #expect(manager.workspaceProjectionDiagnostic(id: "legacy")?.state == .regenerated)
            #expect(try legacyData(state: state, id: "legacy") == raw)
            let projected = try record(state: state, id: "legacy")
            #expect(projected.legacyConfigurationSHA256 == sha256(raw))

            let projectionBytes = try Data(
                contentsOf: URL(fileURLWithPath: recordPath(state: state, id: "legacy"))
            )
            let restarted = makeManager(state: state)
            #expect(restarted.workspaceProjectionDiagnostic(id: "legacy")?.state == .current)
            #expect(try legacyData(state: state, id: "legacy") == raw)
            #expect(try Data(contentsOf: URL(
                fileURLWithPath: recordPath(state: state, id: "legacy")
            )) == projectionBytes)

            try FileManager.default.removeItem(atPath: recordPath(state: state, id: "legacy"))
            let repaired = makeManager(state: state)
            #expect(repaired.workspaceProjectionDiagnostic(id: "legacy")?.state == .regenerated)
            #expect(FileManager.default.fileExists(
                atPath: recordPath(state: state, id: "legacy")
            ))
            #expect(try legacyData(state: state, id: "legacy") == raw)
        }
    }

    @Test("stale projection is repaired from crash-ordered legacy metadata")
    func staleProjectionRepair() throws {
        try withStateRoot("stale") { _, state in
            let manager = makeManager(state: state)
            _ = try manager.create(DoryMachineConfiguration(
                id: "dev",
                kernelPath: doryTestKernelPath,
                rootfsPath: doryTestRootfsPath,
                memoryMB: 2_048
            ))
            let first = try record(state: state, id: "dev")

            let path = state + "/dev/machine.json"
            var authoritative = try JSONDecoder().decode(
                DoryMachineConfiguration.self,
                from: try legacyData(state: state, id: "dev")
            )
            authoritative.memoryMB = 6_144
            let changedBytes = try DoryMachineConfigurationMigrationBridge.encodeLegacy(authoritative)
            try writePrivate(changedBytes, path: path)

            let recovered = makeManager(state: state)
            #expect(recovered.status(id: "dev")?.memoryMB == 6_144)
            #expect(recovered.workspaceProjectionDiagnostic(id: "dev")?.state == .regenerated)
            let repaired = try record(state: state, id: "dev")
            #expect(repaired.definition.lifecycle.revision == first.definition.lifecycle.revision + 1)
            #expect(repaired.definition.resources.memoryBytes == 6 * gibibyte)
            #expect(repaired.legacyConfigurationSHA256 == sha256(changedBytes))
        }
    }

    @Test("inspection fact changes advance projection without rewriting machine metadata")
    func inspectionFactsAreAuthority() throws {
        try withStateRoot("facts") { _, state in
            let manager = makeManager(state: state)
            _ = try manager.create(DoryMachineConfiguration(
                id: "installed",
                kernelPath: doryTestKernelPath,
                rootfsPath: doryTestRootfsPath,
                bootMode: .efi,
                memoryMB: 4_096,
                cpuCount: 4,
                displayMode: .desktop
            ))
            let rawBefore = try legacyData(state: state, id: "installed")
            let firmware = try record(state: state, id: "installed")
            #expect(firmware.definition.boot.devices[0].kind == .virtualDisk)

            try DoryInstalledLinuxBootBundle.write(
                assets: DoryLinuxInstallerBootAssets(
                    kernel: Data(repeating: 0x41, count: 4_096),
                    initrd: Data(repeating: 0x42, count: 8_192),
                    kernelISOPath: "casper/vmlinuz",
                    initrdISOPath: "casper/initrd"
                ),
                rootDevice: "/dev/vda2",
                toPath: state + "/installed/kernel"
            )

            let reconciled = makeManager(state: state)
            #expect(reconciled.workspaceProjectionDiagnostic(id: "installed")?.state == .regenerated)
            #expect(try legacyData(state: state, id: "installed") == rawBefore)
            let direct = try record(state: state, id: "installed")
            #expect(direct.definition.lifecycle.revision == firmware.definition.lifecycle.revision + 1)
            #expect(direct.definition.lifecycle.createdAtUnixMilliseconds
                == firmware.definition.lifecycle.createdAtUnixMilliseconds)
            #expect(direct.definition.boot.devices[0].kind == .installedLinuxBootBundle)
            #expect(direct.legacyConfigurationSHA256 == firmware.legacyConfigurationSHA256)
            #expect(direct.legacyMigrationFactsSHA256 != firmware.legacyMigrationFactsSHA256)
        }
    }

    @Test("projection failure keeps disk and in-memory legacy configuration consistent")
    func projectionFailureAfterLegacyCommitIsNonfatal() throws {
        try withStateRoot("projection-failure") { _, state in
            let manager = makeManager(state: state)
            _ = try manager.create(DoryMachineConfiguration(
                id: "dev",
                kernelPath: doryTestKernelPath,
                rootfsPath: doryTestRootfsPath,
                memoryMB: 2_048
            ))
            let projectionPath = recordPath(state: state, id: "dev")
            try FileManager.default.removeItem(atPath: projectionPath)
            try FileManager.default.createDirectory(
                atPath: projectionPath,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )

            let status = try manager.update(id: "dev", memoryMB: 4_096)
            #expect(status.memoryMB == 4_096)
            let persisted = try JSONDecoder().decode(
                DoryMachineConfiguration.self,
                from: try legacyData(state: state, id: "dev")
            )
            #expect(persisted.memoryMB == 4_096)
            let diagnostic = try #require(manager.workspaceProjectionDiagnostic(id: "dev"))
            #expect(diagnostic.state == .unavailable)
            #expect(diagnostic.failureCode == .repositoryFailure)

            try FileManager.default.removeItem(atPath: projectionPath)
            let repaired = makeManager(state: state)
            #expect(repaired.status(id: "dev")?.memoryMB == 4_096)
            #expect(repaired.workspaceProjectionDiagnostic(id: "dev")?.state == .regenerated)
        }
    }

    @Test("unsupported migration facts do not prevent legacy create or load")
    func unsupportedFactsRemainDiagnosticOnly() throws {
        try withStateRoot("unsupported") { _, state in
            let manager = makeManager(state: state, architecture: "mips64")
            let created = try manager.create(DoryMachineConfiguration(
                id: "legacy",
                kernelPath: doryTestKernelPath,
                rootfsPath: doryTestRootfsPath
            ))
            #expect(created.state == .created)
            let diagnostic = try #require(manager.workspaceProjectionDiagnostic(id: "legacy"))
            #expect(diagnostic.state == .unavailable)
            #expect(diagnostic.failureCode == .unsupportedLegacyConfiguration)
            #expect(FileManager.default.fileExists(atPath: state + "/legacy/machine.json"))
            #expect(!FileManager.default.fileExists(
                atPath: recordPath(state: state, id: "legacy")
            ))

            let reloaded = makeManager(state: state, architecture: "mips64")
            #expect(reloaded.status(id: "legacy")?.state == .stopped)
            #expect(reloaded.workspaceProjectionDiagnostic(id: "legacy")?.failureCode
                == .unsupportedLegacyConfiguration)
        }
    }

    @Test("snapshot restore publishes the restored authoritative configuration")
    func snapshotRestoreProjection() throws {
        try withStateRoot("restore") { _, state in
            let manager = makeManager(state: state)
            _ = try manager.create(DoryMachineConfiguration(
                id: "dev",
                kernelPath: doryTestKernelPath,
                rootfsPath: doryTestRootfsPath,
                memoryMB: 2_048
            ))
            _ = try manager.snapshot(id: "dev", snapshotID: "before")
            _ = try manager.update(id: "dev", memoryMB: 4_096)
            #expect(try record(state: state, id: "dev").definition.lifecycle.revision == 2)

            let restored = try manager.restoreSnapshot(machineID: "dev", snapshotID: "before")
            #expect(restored.memoryMB == 2_048)
            let projection = try record(state: state, id: "dev")
            #expect(projection.definition.lifecycle.revision == 3)
            #expect(projection.definition.resources.memoryBytes == 2 * gibibyte)
            #expect(projection.legacyConfigurationSHA256
                == sha256(try legacyData(state: state, id: "dev")))
        }
    }

    private func makeManager(
        state: String,
        architecture: String = "arm64"
    ) -> MachineManager {
        MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: state,
            passMachineArguments: false,
            requiresReadyHandoff: false,
            guestArchitecture: architecture
        ))
    }

    private func withStateRoot(
        _ label: String,
        _ body: (String, String) throws -> Void
    ) throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-projection-\(label)-\(UUID().uuidString.lowercased())")
            .path
        try FileManager.default.createDirectory(
            atPath: base,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(atPath: base) }
        try body(base, base + "/machines")
    }

    private func legacyData(state: String, id: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: state + "/\(id)/machine.json"))
    }

    private func record(state: String, id: String) throws -> DoryWorkspaceRepositoryRecord {
        try JSONDecoder().decode(
            DoryWorkspaceRepositoryRecord.self,
            from: Data(contentsOf: URL(fileURLWithPath: recordPath(state: state, id: id)))
        )
    }

    private func recordPath(state: String, id: String) -> String {
        state + "/\(id)/" + DoryWorkspaceRepository.recordFileName
    }

    private func writePrivate(_ data: Data, path: String) throws {
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: path
        )
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
