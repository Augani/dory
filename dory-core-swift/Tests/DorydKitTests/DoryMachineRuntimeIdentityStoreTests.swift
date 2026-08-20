import Foundation
import Testing
@testable import DorydKit

@Suite("Per-workspace runtime identity store", .serialized)
struct DoryMachineRuntimeIdentityStoreTests {
    @Test("identity authority is monotonic across A to B to A configuration history")
    func rejectsRolledBackIdentityRecord() throws {
        try withStore("rollback") { store, directory in
            let dataA = Data("configuration-a".utf8)
            let dataB = Data("configuration-b".utf8)
            try store.publish(
                .legacyCompatibility(virtualHardwareABIVersion: 1),
                machineID: "dev",
                authoritativeLegacyData: dataA
            )
            let recordPath = directory + "/" + DoryMachineRuntimeIdentityStore.recordFileName
            let oldRecord = try Data(contentsOf: URL(fileURLWithPath: recordPath))

            try store.publish(
                .requiresReplanning(
                    virtualHardwareABIVersion: 1,
                    reason: .definitionChanged
                ),
                machineID: "dev",
                authoritativeLegacyData: dataB
            )
            try store.publish(
                .requiresReplanning(
                    virtualHardwareABIVersion: 1,
                    reason: .definitionChanged
                ),
                machineID: "dev",
                authoritativeLegacyData: dataA
            )

            try oldRecord.write(to: URL(fileURLWithPath: recordPath), options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: recordPath
            )
            #expect(throws: DoryMachineRuntimeIdentityStoreError.invalidRecord) {
                _ = try store.readIfPresent(
                    machineID: "dev",
                    authoritativeLegacyData: dataA
                )
            }
        }
    }

    @Test("missing or corrupt identity beside a durable head never becomes absent legacy state")
    func partialAuthorityFailsClosed() throws {
        try withStore("missing") { store, directory in
            let legacyData = Data("configuration".utf8)
            try store.publish(
                .requiresReplanning(
                    virtualHardwareABIVersion: 1,
                    reason: .planNotInstalled
                ),
                machineID: "dev",
                authoritativeLegacyData: legacyData
            )
            let recordPath = directory + "/" + DoryMachineRuntimeIdentityStore.recordFileName
            try FileManager.default.removeItem(atPath: recordPath)
            #expect(throws: DoryMachineRuntimeIdentityStoreError.invalidRecord) {
                _ = try store.readIfPresent(
                    machineID: "dev",
                    authoritativeLegacyData: legacyData
                )
            }
        }
        try withStore("corrupt") { store, directory in
            let legacyData = Data("configuration".utf8)
            try store.publish(
                .legacyCompatibility(virtualHardwareABIVersion: 1),
                machineID: "dev",
                authoritativeLegacyData: legacyData
            )
            let recordPath = directory + "/" + DoryMachineRuntimeIdentityStore.recordFileName
            try Data("not-json".utf8).write(
                to: URL(fileURLWithPath: recordPath),
                options: .atomic
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: recordPath
            )
            #expect(throws: DoryMachineRuntimeIdentityStoreError.invalidRecord) {
                _ = try store.readIfPresent(
                    machineID: "dev",
                    authoritativeLegacyData: legacyData
                )
            }
        }
    }

    @Test("restart completes the one valid identity-before-head crash ordering")
    func healsForwardPublication() throws {
        try withStore("forward") { store, directory in
            let dataA = Data("configuration-a".utf8)
            let dataB = Data("configuration-b".utf8)
            try store.publish(
                .legacyCompatibility(virtualHardwareABIVersion: 1),
                machineID: "dev",
                authoritativeLegacyData: dataA
            )
            let headPath = directory + "/" + DoryMachineRuntimeIdentityStore.headFileName
            let oldHead = try Data(contentsOf: URL(fileURLWithPath: headPath))
            let expected = DoryMachineRuntimeIdentity.requiresReplanning(
                virtualHardwareABIVersion: 1,
                reason: .definitionChanged
            )
            try store.publish(
                expected,
                machineID: "dev",
                authoritativeLegacyData: dataB
            )
            try oldHead.write(to: URL(fileURLWithPath: headPath), options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: headPath
            )

            #expect(try store.readIfPresent(
                machineID: "dev",
                authoritativeLegacyData: dataB
            ) == expected)
            #expect(try store.readIfPresent(
                machineID: "dev",
                authoritativeLegacyData: dataB
            ) == expected)
        }
    }

    private func withStore(
        _ label: String,
        _ body: (DoryMachineRuntimeIdentityStore, String) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-runtime-identity-\(label)-\(UUID().uuidString)")
            .path
        let directory = root + "/dev"
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(atPath: root) }
        try body(DoryMachineRuntimeIdentityStore(root: root), directory)
    }
}
