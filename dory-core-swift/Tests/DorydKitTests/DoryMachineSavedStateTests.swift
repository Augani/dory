import Darwin
import Foundation
import Testing
@testable import DorydKit

@Suite("Durable machine saved-state authority", .serialized)
struct DoryMachineSavedStateTests {
    @Test("saved-state migration preserves source bytes and rejects incomplete current authority",
          arguments: [
            "legacy-canonical", "legacy-vz", "legacy-vz-mac", "legacy-framework",
            "current-canonical", "current-vz", "current-vz-mac", "current-framework",
            "current-missing-format", "future-schema", "legacy-unsafe-backend",
        ])
    func storedSchemaMigrationPreservesArtifacts(caseName: String) throws {
        try withStore(machineID: "migration") { store, root in
            let configuration = Data("retained-machine-json".utf8)
            let runtime = DoryMachineRuntimeIdentity.legacyCompatibility(
                virtualHardwareABIVersion: 1
            )
            let temporary = try store.temporaryStatePath(machineID: "migration")
            try writePrivate(Data("retained-vz-payload".utf8), to: temporary)
            _ = try store.publish(
                temporaryStatePath: temporary,
                machineID: "migration",
                authoritativeConfigurationData: configuration,
                runtimeIdentity: runtime
            )
            let directory = root + "/migration/" + DoryMachineSavedStateStore.directoryName
            let manifestPath = directory + "/" + DoryMachineSavedStateStore.manifestFileName
            var object = try #require(JSONSerialization.jsonObject(
                with: Data(contentsOf: URL(fileURLWithPath: manifestPath))
            ) as? [String: Any])
            if caseName.hasPrefix("legacy-") {
                object["schemaVersion"] = 1
                object.removeValue(forKey: "snapshotFormat")
            }
            if caseName.hasSuffix("-vz") { object["backend"] = "vz" }
            if caseName.hasSuffix("-vz-mac") { object["backend"] = "vz-mac" }
            if caseName.hasSuffix("-framework") { object["backend"] = "virtualization-framework" }
            if caseName == "legacy-unsafe-backend" { object["backend"] = "qemu-hvf" }
            if caseName == "future-schema" { object["schemaVersion"] = 3 }
            if caseName == "current-missing-format" { object.removeValue(forKey: "snapshotFormat") }
            let originalManifest = try JSONSerialization.data(withJSONObject: object, options: .prettyPrinted)
            try writeReplacingPrivate(originalManifest, to: manifestPath)
            let statePath = store.statePath(machineID: "migration")
            let originalPayload = try Data(contentsOf: URL(fileURLWithPath: statePath))
            let originalEntries = try FileManager.default.contentsOfDirectory(atPath: directory).sorted()
            let shouldAccept = caseName == "current-canonical"
                || (caseName.hasPrefix("legacy-") && caseName != "legacy-unsafe-backend")
            for _ in 0..<2 {
                let inspection = store.inspect(
                    machineID: "migration",
                    authoritativeConfigurationData: configuration,
                    runtimeIdentity: runtime
                )
                switch inspection {
                case let .valid(manifest):
                    #expect(shouldAccept)
                    #expect(manifest.backend == .appleVirtualizationFramework)
                    #expect(manifest.snapshotFormat == .appleVZMacV1)
                case .invalid:
                    #expect(!shouldAccept)
                case .absent:
                    Issue.record("migration must retain the original saved state")
                }
            }
            #expect(try Data(contentsOf: URL(fileURLWithPath: manifestPath)) == originalManifest)
            #expect(try Data(contentsOf: URL(fileURLWithPath: statePath)) == originalPayload)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory).sorted() == originalEntries)
        }
    }

    @Test("replanning identity cannot publish or validate a resumable saved state")
    func rejectsReplanningBeforeMutation() throws {
        try withStore(machineID: "replanning") { store, root in
            let machineDirectory = root + "/replanning"
            let payloadPath = machineDirectory + "/retained-payload"
            let bytes = Data("obsolete-runtime-state".utf8)
            try writePrivate(bytes, to: payloadPath)
            let identity = DoryMachineRuntimeIdentity.requiresReplanning(
                virtualHardwareABIVersion: 1, reason: .planRecoveryFailed
            )
            #expect(throws: DoryMachineSavedStateError.self) {
                try store.publish(
                    temporaryStatePath: payloadPath,
                    machineID: "replanning",
                    authoritativeConfigurationData: Data("configuration".utf8),
                    runtimeIdentity: identity
                )
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: machineDirectory) == ["retained-payload"])
            #expect(try Data(contentsOf: URL(fileURLWithPath: payloadPath)) == bytes)
            let manifest = DoryMachineSavedStateManifest(
                machineID: "replanning",
                stateFileSHA256: String(repeating: "a", count: 64),
                stateFileByteCount: UInt64(bytes.count),
                authoritativeConfigurationSHA256: String(repeating: "b", count: 64),
                runtimeIdentity: identity,
                hostHardwareModel: "Mac",
                hostOperatingSystemBuild: "23A",
                createdAtUnixMilliseconds: 1
            )
            #expect(!manifest.isStructurallyValid)
        }
    }

    @Test("unknown saved-state artifacts reject discard before removing any original file")
    func discardPreservesUnknownSchemaContents() throws {
        try withStore(machineID: "future") { store, root in
            let temporary = try store.temporaryStatePath(machineID: "future")
            try writePrivate(Data("saved-vz-state".utf8), to: temporary)
            _ = try store.publish(
                temporaryStatePath: temporary,
                machineID: "future",
                authoritativeConfigurationData: Data("configuration".utf8),
                runtimeIdentity: .legacyCompatibility(virtualHardwareABIVersion: 1)
            )
            let directory = root + "/future/" + DoryMachineSavedStateStore.directoryName
            try writePrivate(Data("future-format-descriptor".utf8), to: directory + "/future-format.json")
            let entries = try FileManager.default.contentsOfDirectory(atPath: directory)
            let original = try Dictionary(uniqueKeysWithValues: entries.map {
                ($0, try Data(contentsOf: URL(fileURLWithPath: directory + "/" + $0)))
            })
            #expect(throws: DoryMachineSavedStateError.self) {
                try store.remove(machineID: "future")
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory).sorted() == entries.sorted())
            for (name, data) in original {
                #expect(try Data(contentsOf: URL(fileURLWithPath: directory + "/" + name)) == data)
            }
        }
    }

    @Test("schema-one VZ aliases migrate in memory while unsafe backends are rejected")
    func savedStateSchemaMigrationMatrix() throws {
        let current = DoryMachineSavedStateManifest(
            machineID: "legacy",
            stateFileSHA256: String(repeating: "a", count: 64),
            stateFileByteCount: 4_096,
            authoritativeConfigurationSHA256: String(repeating: "b", count: 64),
            runtimeIdentity: .legacyCompatibility(virtualHardwareABIVersion: 1),
            hostHardwareModel: "Mac",
            hostOperatingSystemBuild: "23A",
            createdAtUnixMilliseconds: 1
        )
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(current))
                as? [String: Any]
        )
        object["schemaVersion"] = 1
        object["backend"] = "vz"
        object.removeValue(forKey: "snapshotFormat")
        let historicalBytes = try JSONSerialization.data(withJSONObject: object)
        let migrated = try JSONDecoder().decode(
            DoryMachineSavedStateManifest.self,
            from: historicalBytes
        )
        #expect(migrated.schemaVersion == 1)
        #expect(migrated.backend == .appleVirtualizationFramework)
        #expect(migrated.snapshotFormat == .appleVZMacV1)
        #expect(migrated.isStructurallyValid)

        object["backend"] = "qemu-hvf"
        let unsafe = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(DoryMachineSavedStateManifest.self, from: unsafe)
        }
    }

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
