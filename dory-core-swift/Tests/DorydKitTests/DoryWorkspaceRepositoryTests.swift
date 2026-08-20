import Darwin
import DoryOperations
@testable import DorydKit
import Foundation
import Testing

@Suite("Workspace repository")
struct DoryWorkspaceRepositoryTests {
    @Test("authoritative records create read and replace with optimistic revisions")
    func authoritativeLifecycle() throws {
        try withRepository { repository, _ in
            let initial = definition()
            try repository.create(initial)
            #expect(try repository.read(id: initial.identity.id) == initial)

            var replacement = initial
            replacement.identity.name = "Renamed workspace"
            replacement.lifecycle.revision = 2
            replacement.lifecycle.updatedAtUnixMilliseconds += 1
            try repository.replace(replacement, expectedRevision: 1)
            #expect(try repository.read(id: initial.identity.id) == replacement)

            #expect(throws: DoryWorkspaceRepositoryError.staleRevision(expected: 1, actual: 2)) {
                try repository.replace(replacement, expectedRevision: 1)
            }
        }
    }

    @Test("legacy projections are bound to exact authoritative bytes and can be reconciled")
    func legacyProjectionBinding() throws {
        try withRepository { repository, _ in
            let firstLegacy = Data("legacy-v1".utf8)
            let secondLegacy = Data("legacy-v2".utf8)
            let workspace = definition()

            try repository.publishLegacyProjection(
                workspace,
                authoritativeLegacyData: firstLegacy
            )
            #expect(
                try repository.readLegacyProjection(
                    id: workspace.identity.id,
                    authoritativeLegacyData: firstLegacy
                ) == workspace
            )
            #expect(throws: DoryWorkspaceRepositoryError.staleLegacyProjection(workspace.identity.id)) {
                _ = try repository.readLegacyProjection(
                    id: workspace.identity.id,
                    authoritativeLegacyData: secondLegacy
                )
            }
            #expect(throws: DoryWorkspaceRepositoryError.legacyAuthorityRequired(workspace.identity.id)) {
                _ = try repository.read(id: workspace.identity.id)
            }

            var reconciled = workspace
            reconciled.lifecycle.revision = 2
            reconciled.lifecycle.updatedAtUnixMilliseconds += 1
            try repository.publishLegacyProjection(
                reconciled,
                authoritativeLegacyData: secondLegacy
            )
            #expect(
                try repository.readLegacyProjection(
                    id: workspace.identity.id,
                    authoritativeLegacyData: secondLegacy
                ) == reconciled
            )
        }
    }

    @Test("invalid definitions and revision or identity changes fail before publication")
    func validationAndRevisionSafety() throws {
        try withRepository { repository, root in
            var invalid = definition()
            invalid.identity.id = "../escape"
            #expect(throws: DoryWorkspaceRepositoryError.self) {
                try repository.create(invalid)
            }
            #expect(!FileManager.default.fileExists(atPath: root + "/escape"))

            let initial = definition()
            try repository.create(initial)
            var skippedRevision = initial
            skippedRevision.lifecycle.revision = 3
            skippedRevision.lifecycle.updatedAtUnixMilliseconds += 1
            #expect(throws: DoryWorkspaceRepositoryError.invalidRevision(expected: 2, actual: 3)) {
                try repository.replace(skippedRevision, expectedRevision: 1)
            }

            var changedCreation = initial
            changedCreation.lifecycle.revision = 2
            changedCreation.lifecycle.createdAtUnixMilliseconds -= 1
            changedCreation.lifecycle.updatedAtUnixMilliseconds += 1
            #expect(throws: DoryWorkspaceRepositoryError.identityChanged(initial.identity.id)) {
                try repository.replace(changedCreation, expectedRevision: 1)
            }
        }
    }

    @Test("repository rejects symlink hard-link public and oversized records")
    func hostileRecordTypes() throws {
        try withRepository { repository, root in
            let workspace = definition()
            try repository.create(workspace)
            let directory = root + "/" + workspace.identity.id
            let record = directory + "/" + DoryWorkspaceRepository.recordFileName
            let saved = directory + "/saved"
            try FileManager.default.moveItem(atPath: record, toPath: saved)

            #expect(symlink(saved, record) == 0)
            #expect(throws: DoryWorkspaceRepositoryError.self) {
                _ = try repository.read(id: workspace.identity.id)
            }
            #expect(unlink(record) == 0)

            #expect(link(saved, record) == 0)
            #expect(throws: DoryWorkspaceRepositoryError.self) {
                _ = try repository.read(id: workspace.identity.id)
            }
            #expect(unlink(record) == 0)

            try FileManager.default.copyItem(atPath: saved, toPath: record)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: record
            )
            #expect(throws: DoryWorkspaceRepositoryError.self) {
                _ = try repository.read(id: workspace.identity.id)
            }
            try FileManager.default.removeItem(atPath: record)

            #expect(FileManager.default.createFile(atPath: record, contents: Data([0])))
            let descriptor = open(record, O_WRONLY | O_CLOEXEC)
            #expect(descriptor >= 0)
            #expect(ftruncate(descriptor, off_t(17 * 1_024 * 1_024)) == 0)
            _ = close(descriptor)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: record
            )
            #expect(throws: DoryWorkspaceRepositoryError.self) {
                _ = try repository.read(id: workspace.identity.id)
            }
        }
    }

    @Test("remove rejects unsafe identifiers and durably removes one record")
    func removeSafety() throws {
        try withRepository { repository, root in
            let workspace = definition()
            try repository.create(workspace)
            try repository.remove(id: workspace.identity.id)
            #expect(
                !FileManager.default.fileExists(
                    atPath: root + "/" + workspace.identity.id + "/"
                        + DoryWorkspaceRepository.recordFileName
                )
            )
            #expect(throws: DoryWorkspaceRepositoryError.invalidIdentifier("../escape")) {
                try repository.remove(id: "../escape")
            }
        }
    }

    private func withRepository(
        _ body: (DoryWorkspaceRepository, String) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-workspace-repository-\(UUID().uuidString)")
            .path
        defer { try? FileManager.default.removeItem(atPath: root) }
        try body(DoryWorkspaceRepository(root: root), root)
    }

    private func definition() -> DoryVirtualMachineDefinition {
        let disk = DoryVMResolverReference(namespace: "machine", identifier: "disk-main")
        return DoryVirtualMachineDefinition(
            identity: DoryVirtualMachineIdentity(id: "workspace-one", name: "Workspace One"),
            guest: DoryGuestPlatform(family: .linux, architecture: .arm64),
            workload: .desktop,
            boot: DoryVMBootConfiguration(
                phase: .normal,
                devices: [DoryVMBootMediaReference(
                    id: "system",
                    role: .system,
                    kind: .virtualDisk,
                    source: .userProvided,
                    artifact: disk,
                    removable: false
                )],
                order: ["system"]
            ),
            graphics: DoryVMGraphicsPolicy(
                acceptableLevels: [.hardwareAccelerated3D, .software]
            ),
            resources: DoryVMResourceRequest(
                virtualCPUCount: 4,
                memoryBytes: 8 * 1_024 * 1_024 * 1_024,
                diskBytes: 64 * 1_024 * 1_024 * 1_024
            ),
            storage: [DoryVMStorageAttachment(
                id: "system",
                role: .system,
                artifact: disk,
                capacityBytes: 64 * 1_024 * 1_024 * 1_024
            )],
            lifecycle: DoryVMLifecycleMetadata(
                revision: 1,
                createdAtUnixMilliseconds: 1_700_000_000_000,
                updatedAtUnixMilliseconds: 1_700_000_000_000
            )
        )
    }
}
