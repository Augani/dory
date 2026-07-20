import Foundation

nonisolated struct MigrationImageTarEntry: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case regular
        case directory
    }

    let path: String
    let kind: Kind
    let logicalBytes: UInt64
    let sha256: String?
}

nonisolated struct MigrationImageTarArchive: Sendable {
    let entries: [String: MigrationImageTarEntry]
    let capturedEntries: [String: Data]
    let manifest: Data
    let archiveBytes: UInt64
}

nonisolated enum MigrationImageArchiveManifest {
    static let maximumManifestBytes: UInt64 = 8 * 1_024 * 1_024

    static func fingerprint(
        _ archive: MigrationImageTarArchive,
        archiveSha256: String
    ) throws -> MigrationImageArchiveFingerprint {
        guard let root = try? JSONSerialization.jsonObject(with: archive.manifest) as? [[String: Any]],
              root.count == 1,
              let record = root.first,
              let config = record["Config"] as? String,
              let layers = record["Layers"] as? [String],
              isSafeFilePath(config),
              Set(layers).count == layers.count,
              layers.allSatisfy(isSafeFilePath),
              repoTagsAreValid(record["RepoTags"]) else {
            throw MigrationImageArchiveError.invalid(
                "manifest.json must describe exactly one image with valid RepoTags"
            )
        }
        let configEntry = try regularEntry(config, archive: archive)
        guard let configSha256 = configEntry.sha256,
              expectedConfigDigest(path: config) == configSha256 else {
            throw MigrationImageArchiveError.invalid(
                "config filename does not match its content digest"
            )
        }
        let layerFingerprints = try layers.enumerated().map { position, path in
            let entry = try regularEntry(path, archive: archive)
            guard let digest = entry.sha256 else {
                throw MigrationImageArchiveError.invalid("layer \(path) has no digest")
            }
            return MigrationImageLayerFingerprint(
                position: position,
                archivePath: path,
                logicalBytes: entry.logicalBytes,
                sha256: digest
            )
        }
        try validateConfig(
            archive: archive,
            path: config,
            layers: layerFingerprints
        )
        let validatedImageIDs = try MigrationImageOCIArchiveIdentity.validatedImageIDs(
            archive: archive,
            configPath: config,
            configBytes: configEntry.logicalBytes,
            configSha256: configSha256,
            layers: layerFingerprints
        )
        return try MigrationImageArchiveFingerprint(
            configArchivePath: config,
            configBytes: configEntry.logicalBytes,
            configSha256: configSha256,
            validatedImageIDs: validatedImageIDs,
            layers: layerFingerprints,
            archiveBytes: archive.archiveBytes,
            archiveEntryCount: archive.entries.count,
            archiveSha256: archiveSha256
        )
    }

    /// Docker-compatible engines disagree about whether saving an image by immutable content ID
    /// includes its mutable repository tags. Source fingerprints accept both forms, but the strict
    /// staging stream must stay untagged so loading cannot publish or overwrite a reference before
    /// the operation reaches its publication boundary. Keep the tar entry size unchanged so the
    /// archive can be rewritten while it streams without changing its header or padding.
    static func strippingRepoTags(_ manifest: Data) throws -> Data {
        guard var root = try? JSONSerialization.jsonObject(with: manifest) as? [[String: Any]],
              root.count == 1,
              var record = root.first,
              repoTagsAreValid(record["RepoTags"]) else {
            throw MigrationImageArchiveError.invalid(
                "manifest.json must describe exactly one image with valid RepoTags"
            )
        }
        guard let tags = record["RepoTags"] as? [String], !tags.isEmpty else {
            return manifest
        }
        record["RepoTags"] = NSNull()
        root[0] = record
        guard var sanitized = try? JSONSerialization.data(
            withJSONObject: root,
            options: [.sortedKeys]
        ), sanitized.count <= manifest.count else {
            throw MigrationImageArchiveError.invalid(
                "manifest.json RepoTags could not be removed without changing its tar entry size"
            )
        }
        sanitized.append(Data(repeating: UInt8(ascii: " "), count: manifest.count - sanitized.count))
        return sanitized
    }
}

private extension MigrationImageArchiveManifest {
    nonisolated static func regularEntry(
        _ path: String,
        archive: MigrationImageTarArchive
    ) throws -> MigrationImageTarEntry {
        guard let entry = archive.entries[path], entry.kind == .regular else {
            throw MigrationImageArchiveError.invalid("manifest references missing file \(path)")
        }
        return entry
    }

    nonisolated static func repoTagsAreValid(_ value: Any?) -> Bool {
        value == nil || value is NSNull || value is [String]
    }

    nonisolated static func expectedConfigDigest(path: String) -> String? {
        let components = path.split(separator: "/").map(String.init)
        let candidate: String
        if components.count == 1, path.hasSuffix(".json") {
            candidate = String(path.dropLast(".json".count))
        } else if components.count == 3,
                  components[0] == "blobs",
                  components[1] == "sha256" {
            candidate = components[2]
        } else {
            return nil
        }
        guard candidate.utf8.count == 64,
              candidate.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            return nil
        }
        return candidate
    }

    nonisolated static func validateConfig(
        archive: MigrationImageTarArchive,
        path: String,
        layers: [MigrationImageLayerFingerprint]
    ) throws {
        guard let payload = archive.capturedEntries[path],
              let config = try? JSONDecoder().decode(MigrationImageConfig.self, from: payload),
              config.architecture == "arm64",
              config.operatingSystem == "linux",
              config.rootfs.type == "layers",
              config.rootfs.diffIDs.count == layers.count,
              zip(config.rootfs.diffIDs, layers).allSatisfy(validatesLayer) else {
            throw MigrationImageArchiveError.invalid(
                "config is not a matching linux/arm64 rootfs contract"
            )
        }
    }

    nonisolated static func validatesLayer(
        diffID: String,
        layer: MigrationImageLayerFingerprint
    ) -> Bool {
        guard diffID.hasPrefix("sha256:"),
              expectedConfigDigest(path: String(diffID.dropFirst("sha256:".count)) + ".json") != nil else {
            return false
        }
        if let blobDigest = contentAddressedBlobDigest(path: layer.archivePath) {
            return blobDigest == layer.sha256
        }
        return diffID == "sha256:\(layer.sha256)"
    }

    nonisolated static func contentAddressedBlobDigest(path: String) -> String? {
        let components = path.split(separator: "/").map(String.init)
        guard components.count == 3,
              components[0] == "blobs",
              components[1] == "sha256" else { return nil }
        return expectedConfigDigest(path: path)
    }

    nonisolated static func isSafeFilePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasSuffix("/"),
              path.utf8.count <= 4_096, !path.utf8.contains(0) else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }
}

private nonisolated struct MigrationImageConfig: Decodable {
    let architecture: String
    let operatingSystem: String
    let rootfs: MigrationImageRootFS

    enum CodingKeys: String, CodingKey {
        case architecture
        case operatingSystem = "os"
        case rootfs
    }
}

private nonisolated struct MigrationImageRootFS: Decodable {
    let type: String
    let diffIDs: [String]

    enum CodingKeys: String, CodingKey {
        case type
        case diffIDs = "diff_ids"
    }
}
