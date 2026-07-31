import Foundation

nonisolated enum MigrationImageOCIArchiveIdentity {
    private static let ociIndex = "application/vnd.oci.image.index.v1+json"
    private static let dockerIndex = "application/vnd.docker.distribution.manifest.list.v2+json"
    private static let ociManifest = "application/vnd.oci.image.manifest.v1+json"
    private static let dockerManifest = "application/vnd.docker.distribution.manifest.v2+json"

    static func validatedImageIDs(
        archive: MigrationImageTarArchive,
        configPath: String,
        configBytes: UInt64,
        configSha256: String,
        layers: [MigrationImageLayerFingerprint]
    ) throws -> [String] {
        guard let indexPayload = archive.capturedEntries["index.json"] else {
            guard archive.entries["index.json"] == nil else {
                throw invalid("index.json payload is unavailable")
            }
            return []
        }
        let root = try decodeIndex(indexPayload, expectedMediaType: nil)
        let rootDescriptors = uniqueDescriptors(root.manifests)
        guard rootDescriptors.count == 1 else {
            throw invalid("index.json must contain exactly one image descriptor")
        }
        let rootDescriptor = rootDescriptors[0]
        let rootPayload = try referencedPayload(rootDescriptor, archive: archive)

        let selectedDescriptor: Descriptor
        let selectedPayload: Data
        if isIndexMediaType(rootDescriptor.mediaType) {
            let nested = try decodeIndex(
                rootPayload,
                expectedMediaType: rootDescriptor.mediaType
            )
            let candidates = uniqueDescriptors(
                nested.manifests.filter(isLinuxARM64ImageManifest)
            )
            guard candidates.count == 1 else {
                throw invalid("OCI index must select exactly one linux/arm64 image manifest")
            }
            selectedDescriptor = candidates[0]
            selectedPayload = try referencedPayload(selectedDescriptor, archive: archive)
        } else if isImageManifestMediaType(rootDescriptor.mediaType) {
            selectedDescriptor = rootDescriptor
            selectedPayload = rootPayload
        } else {
            throw invalid("index.json references an unsupported image media type")
        }

        try validateImageManifest(
            selectedPayload,
            descriptor: selectedDescriptor,
            configPath: configPath,
            configBytes: configBytes,
            configSha256: configSha256,
            layers: layers
        )
        return [rootDescriptor.digest, selectedDescriptor.digest]
    }

    /// Remove mutable tag annotations and repeated aliases from the root OCI index while keeping
    /// its tar entry byte count unchanged. The archive validator still rejects distinct images.
    static func strippingAliases(_ index: Data) throws -> Data {
        guard var root = try? JSONSerialization.jsonObject(with: index) as? [String: Any],
              var descriptors = root["manifests"] as? [[String: Any]],
              !descriptors.isEmpty else {
            throw invalid("index.json metadata is malformed")
        }
        let decoded = try decodeIndex(index, expectedMediaType: nil)
        guard decoded.manifests.count == descriptors.count,
              uniqueDescriptors(decoded.manifests).count == 1 else {
            throw invalid("index.json must contain exactly one image descriptor")
        }
        let hasAliases = descriptors.count > 1
        let hasAnnotations = descriptors.contains { $0["annotations"] != nil }
        guard hasAliases || hasAnnotations else { return index }

        var selected = descriptors[0]
        selected.removeValue(forKey: "annotations")
        descriptors = [selected]
        root["manifests"] = descriptors
        guard var sanitized = try? JSONSerialization.data(
            withJSONObject: root,
            options: [.sortedKeys]
        ), sanitized.count <= index.count else {
            throw invalid(
                "index.json aliases could not be removed without changing its tar entry size"
            )
        }
        sanitized.append(Data(repeating: UInt8(ascii: " "), count: index.count - sanitized.count))
        return sanitized
    }
}

private extension MigrationImageOCIArchiveIdentity {
    nonisolated struct Index: Decodable {
        let schemaVersion: Int
        let mediaType: String?
        let manifests: [Descriptor]
    }

    nonisolated struct ImageManifest: Decodable {
        let schemaVersion: Int
        let mediaType: String?
        let config: Descriptor
        let layers: [Descriptor]
    }

    nonisolated struct Descriptor: Decodable {
        let mediaType: String
        let digest: String
        let size: UInt64
        let platform: Platform?
    }

    nonisolated struct Platform: Decodable {
        let architecture: String
        let operatingSystem: String
        let variant: String?

        enum CodingKeys: String, CodingKey {
            case architecture
            case operatingSystem = "os"
            case variant
        }
    }

    nonisolated static func decodeIndex(
        _ payload: Data,
        expectedMediaType: String?
    ) throws -> Index {
        let index: Index
        do {
            index = try JSONDecoder().decode(Index.self, from: payload)
        } catch {
            throw invalid("OCI index metadata is malformed")
        }
        guard index.schemaVersion == 2,
              index.mediaType.map(isIndexMediaType) ?? true else {
            throw invalid("OCI index metadata has an unsupported schema or media type")
        }
        if let expectedMediaType, let mediaType = index.mediaType,
           mediaType != expectedMediaType {
            throw invalid("OCI index descriptor and payload media types disagree")
        }
        return index
    }

    /// Some engines emit one descriptor per tag even when every descriptor points to the same
    /// immutable image manifest. Treat those aliases as one image, but keep rejecting archives
    /// that contain different manifest digests or contracts.
    nonisolated static func uniqueDescriptors(_ descriptors: [Descriptor]) -> [Descriptor] {
        descriptors.reduce(into: []) { result, descriptor in
            let alreadyIncluded = result.contains {
                $0.mediaType == descriptor.mediaType
                    && $0.digest == descriptor.digest
                    && $0.size == descriptor.size
            }
            if !alreadyIncluded { result.append(descriptor) }
        }
    }

    nonisolated static func referencedPayload(
        _ descriptor: Descriptor,
        archive: MigrationImageTarArchive
    ) throws -> Data {
        guard let digest = sha256Digest(descriptor.digest) else {
            throw invalid("OCI descriptor digest is not a lowercase sha256 digest")
        }
        let path = "blobs/sha256/\(digest)"
        guard let entry = archive.entries[path],
              entry.kind == .regular,
              entry.sha256 == digest,
              entry.logicalBytes == descriptor.size,
              let payload = archive.capturedEntries[path],
              UInt64(payload.count) == descriptor.size else {
            throw invalid("OCI descriptor does not match its referenced blob")
        }
        return payload
    }

    nonisolated static func validateImageManifest(
        _ payload: Data,
        descriptor: Descriptor,
        configPath: String,
        configBytes: UInt64,
        configSha256: String,
        layers: [MigrationImageLayerFingerprint]
    ) throws {
        guard isImageManifestMediaType(descriptor.mediaType) else {
            throw invalid("selected OCI descriptor is not an image manifest")
        }
        let manifest: ImageManifest
        do {
            manifest = try JSONDecoder().decode(ImageManifest.self, from: payload)
        } catch {
            throw invalid("OCI image manifest is malformed")
        }
        guard manifest.schemaVersion == 2,
              manifest.mediaType == nil || manifest.mediaType == descriptor.mediaType,
              contentAddressedDigest(configPath) == configSha256,
              manifest.config.digest == "sha256:\(configSha256)",
              manifest.config.size == configBytes,
              manifest.layers.count == layers.count else {
            throw invalid("OCI image manifest does not match manifest.json")
        }
        guard zip(manifest.layers, layers).allSatisfy({ descriptor, layer in
            descriptor.digest == "sha256:\(layer.sha256)"
                && descriptor.size == layer.logicalBytes
                && contentAddressedDigest(layer.archivePath) == layer.sha256
        }) else {
            throw invalid("OCI image manifest layer contract does not match manifest.json")
        }
    }

    nonisolated static func isLinuxARM64ImageManifest(_ descriptor: Descriptor) -> Bool {
        guard isImageManifestMediaType(descriptor.mediaType),
              let platform = descriptor.platform,
              platform.operatingSystem == "linux",
              platform.architecture == "arm64" else { return false }
        return platform.variant == nil || platform.variant == "v8"
    }

    nonisolated static func isIndexMediaType(_ mediaType: String) -> Bool {
        mediaType == ociIndex || mediaType == dockerIndex
    }

    nonisolated static func isImageManifestMediaType(_ mediaType: String) -> Bool {
        mediaType == ociManifest || mediaType == dockerManifest
    }

    nonisolated static func sha256Digest(_ value: String) -> String? {
        guard value.hasPrefix("sha256:") else { return nil }
        let digest = String(value.dropFirst("sha256:".count))
        guard digest.utf8.count == 64,
              digest.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              }) else { return nil }
        return digest
    }

    nonisolated static func contentAddressedDigest(_ path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 3,
              components[0] == "blobs",
              components[1] == "sha256" else { return nil }
        let digest = String(components[2])
        return sha256Digest("sha256:\(digest)")
    }

    nonisolated static func invalid(_ detail: String) -> MigrationImageArchiveError {
        .invalid(detail)
    }
}
