import Darwin
import Foundation
import Testing
@testable import DorydKit

@Suite("Durable machine saved-state authority", .serialized)
struct DoryMachineSavedStateTests {
    @Test("published state is exact host configuration runtime and content authority")
    func publishInspectAndTamper() throws {
        try withStore { store, root in
            let configuration = Data("authoritative-machine-json".utf8)
            let runtime = DoryMachineRuntimeIdentity.legacyCompatibility(
                virtualHardwareABIVersion: 1
            )
            let temporary = try store.temporaryStatePath(machineID: "dev.one")
            try writePrivate(Data("saved-vz-state".utf8), to: temporary)

            let manifest = try store.publish(
                temporaryStatePath: temporary,
                machineID: "dev.one",
                authoritativeConfigurationData: configuration,
                runtimeIdentity: runtime,
                now: Date(timeIntervalSince1970: 1_700_000_000)
            )
            #expect(manifest.isStructurallyValid)
            #expect(manifest.machineID == "dev.one")
            #expect(manifest.backend == .appleVirtualizationFramework)
            #expect(manifest.stateFileByteCount == UInt64(Data("saved-vz-state".utf8).count))
            #expect(manifest.createdAtUnixMilliseconds == 1_700_000_000_000)
            #expect(store.inspect(
                machineID: "dev.one",
                authoritativeConfigurationData: configuration,
                runtimeIdentity: runtime
            ) == .valid(manifest))

            guard case .invalid = store.inspect(
                machineID: "dev.one",
                authoritativeConfigurationData: Data("changed-machine-json".utf8),
                runtimeIdentity: runtime
            ) else {
                Issue.record("configuration drift must invalidate the saved state")
                return
            }
            guard case .invalid = store.inspect(
                machineID: "dev.one",
                authoritativeConfigurationData: configuration,
                runtimeIdentity: .requiresReplanning(
                    virtualHardwareABIVersion: 1,
                    reason: .definitionChanged
                )
            ) else {
                Issue.record("runtime identity drift must invalidate the saved state")
                return
            }

            let statePath = store.statePath(machineID: "dev.one")
            try writeReplacingPrivate(Data("tampered-state".utf8), to: statePath)
            guard case .invalid = store.inspect(
                machineID: "dev.one",
                authoritativeConfigurationData: configuration,
                runtimeIdentity: runtime
            ) else {
                Issue.record("content tamper must invalidate the saved state")
                return
            }

            try store.remove(machineID: "dev.one")
            #expect(store.inspect(
                machineID: "dev.one",
                authoritativeConfigurationData: configuration,
                runtimeIdentity: runtime
            ) == .absent)
            #expect(!FileManager.default.fileExists(
                atPath: root + "/dev.one/" + DoryMachineSavedStateStore.directoryName
            ))
        }
    }

    @Test("store rejects unsafe IDs and non-private helper output")
    func rejectsUnsafeInputs() throws {
        try withStore(machineID: "dev") { store, _ in
            #expect(throws: DoryMachineSavedStateError.self) {
                _ = try store.temporaryStatePath(machineID: "../dev")
            }
            #expect(throws: DoryMachineSavedStateError.self) {
                _ = try store.temporaryStatePath(machineID: ".hidden")
            }

            let temporary = try store.temporaryStatePath(machineID: "dev")
            _ = FileManager.default.createFile(
                atPath: temporary,
                contents: Data("saved-state".utf8),
                attributes: [.posixPermissions: 0o644]
            )
            #expect(throws: DoryMachineSavedStateError.self) {
                _ = try store.publish(
                    temporaryStatePath: temporary,
                    machineID: "dev",
                    authoritativeConfigurationData: Data("machine".utf8),
                    runtimeIdentity: .legacyCompatibility(
                        virtualHardwareABIVersion: 1
                    )
                )
            }
        }
    }

    @Test("inspection rejects hard-linked files and substituted state directories")
    func rejectsLinkSubstitution() throws {
        let configuration = Data("machine-authority".utf8)
        let runtime = DoryMachineRuntimeIdentity.legacyCompatibility(
            virtualHardwareABIVersion: 1
        )
        try withStore(machineID: "linked") { store, root in
            let temporary = try store.temporaryStatePath(machineID: "linked")
            try writePrivate(Data("saved-state".utf8), to: temporary)
            _ = try store.publish(
                temporaryStatePath: temporary,
                machineID: "linked",
                authoritativeConfigurationData: configuration,
                runtimeIdentity: runtime
            )
            let statePath = store.statePath(machineID: "linked")
            let foreignLink = root + "/linked/foreign-state-link"
            #expect(link(statePath, foreignLink) == 0)
            guard case .invalid = store.inspect(
                machineID: "linked",
                authoritativeConfigurationData: configuration,
                runtimeIdentity: runtime
            ) else {
                Issue.record("a hard-linked state payload must fail closed")
                return
            }
        }

        try withStore(machineID: "redirected") { store, root in
            let temporary = try store.temporaryStatePath(machineID: "redirected")
            try writePrivate(Data("saved-state".utf8), to: temporary)
            _ = try store.publish(
                temporaryStatePath: temporary,
                machineID: "redirected",
                authoritativeConfigurationData: configuration,
                runtimeIdentity: runtime
            )
            let directory = root + "/redirected/"
                + DoryMachineSavedStateStore.directoryName
            let displaced = root + "/redirected/displaced-state"
            #expect(rename(directory, displaced) == 0)
            #expect(symlink(displaced, directory) == 0)
            guard case .invalid = store.inspect(
                machineID: "redirected",
                authoritativeConfigurationData: configuration,
                runtimeIdentity: runtime
            ) else {
                Issue.record("a symlinked saved-state directory must fail closed")
                return
            }
        }
    }

    private func withStore(
        machineID: String = "dev.one",
        _ body: (DoryMachineSavedStateStore, String) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-saved-state-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(
            atPath: root + "/" + machineID,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(atPath: root) }
        try body(DoryMachineSavedStateStore(root: root), root)
    }

    private func writePrivate(_ data: Data, to path: String) throws {
        guard FileManager.default.createFile(
            atPath: path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func writeReplacingPrivate(_ data: Data, to path: String) throws {
        let fd = open(path, O_WRONLY | O_TRUNC | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(fd, base.advanced(by: offset), raw.count - offset)
                guard written > 0 else { throw CocoaError(.fileWriteUnknown) }
                offset += written
            }
        }
        guard fsync(fd) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
