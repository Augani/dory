import Foundation

enum MigrationVolumeManifestError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self {
        case let .invalid(detail): "invalid volume verification manifest: \(detail)"
        }
    }
}

struct MigrationVolumeManifest: Codable, Sendable, Equatable {
    static let schemaVersion = 1
    static let maximumBytes = 256 * 1_024 * 1_024
    static let maximumEntries = 1_000_000

    let schemaVersion: Int
    let root: MigrationVolumeManifestEntry
    let entries: [MigrationVolumeManifestEntry]

    static func decodeAndValidate(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw MigrationVolumeManifestError.invalid("byte limit exceeded")
        }
        try validateJSONShape(data)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let manifest: Self
        do {
            manifest = try decoder.decode(Self.self, from: data)
        } catch {
            throw MigrationVolumeManifestError.invalid("JSON does not match schema 1")
        }
        try manifest.validate()
        return manifest
    }

    var normalizedTarget: Self {
        Self(
            schemaVersion: schemaVersion,
            root: root,
            entries: entries.filter { $0.kind != .socket }
        )
    }

    var socketCount: Int {
        entries.lazy.filter { $0.kind == .socket }.count
    }

    var containsDeviceNodes: Bool {
        entries.contains { $0.kind == .blockDevice || $0.kind == .characterDevice }
    }

    private func validate() throws {
        guard schemaVersion == Self.schemaVersion else {
            throw MigrationVolumeManifestError.invalid("unsupported schema version")
        }
        guard entries.count <= Self.maximumEntries else {
            throw MigrationVolumeManifestError.invalid("entry limit exceeded")
        }
        guard root.pathHex.isEmpty, root.kind == .directory else {
            throw MigrationVolumeManifestError.invalid("root must be the empty-path directory")
        }
        try root.validate(isRoot: true)

        var priorPath: Data?
        var entriesByPath: [Data: MigrationVolumeManifestEntry] = [:]
        entriesByPath.reserveCapacity(entries.count)
        for entry in entries {
            try entry.validate(isRoot: false)
            let path = try Self.decodeHex(entry.pathHex, maximumBytes: 4_096)
            if let priorPath, !priorPath.lexicographicallyPrecedes(path) {
                throw MigrationVolumeManifestError.invalid(
                    "entries are not strictly sorted by raw path bytes"
                )
            }
            if let separator = path.lastIndex(of: UInt8(ascii: "/")) {
                let parent = Data(path[..<separator])
                guard entriesByPath[parent]?.kind == .directory else {
                    throw MigrationVolumeManifestError.invalid(
                        "entry parent must be a prior directory"
                    )
                }
            }
            guard entriesByPath.updateValue(entry, forKey: path) == nil else {
                throw MigrationVolumeManifestError.invalid("duplicate path")
            }
            if entry.kind == .hardLink {
                let target = try Self.decodeHex(
                    entry.hardLinkTargetHex ?? "",
                    maximumBytes: 4_096
                )
                guard target.lexicographicallyPrecedes(path),
                      let targetEntry = entriesByPath[target],
                      targetEntry.kind == .regularFile,
                      entry.hardLinkMetadataMatches(targetEntry) else {
                    throw MigrationVolumeManifestError.invalid(
                        "hard-link identity or metadata is invalid"
                    )
                }
            }
            priorPath = path
        }
    }

    static func decodeHex(_ value: String, maximumBytes: Int) throws -> Data {
        let bytes = Array(value.utf8)
        guard bytes.count.isMultiple(of: 2), bytes.count / 2 <= maximumBytes else {
            throw MigrationVolumeManifestError.invalid("hex field is malformed or too large")
        }
        var decoded = Data(capacity: bytes.count / 2)
        var index = 0
        while index < bytes.count {
            guard let high = nibble(bytes[index]), let low = nibble(bytes[index + 1]) else {
                throw MigrationVolumeManifestError.invalid("hex is not canonical lowercase")
            }
            decoded.append(high << 4 | low)
            index += 2
        }
        return decoded
    }

    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        default: nil
        }
    }
}

enum MigrationVolumeManifestEntryKind: String, Codable, Sendable {
    case regularFile = "regular_file"
    case directory
    case symbolicLink = "symbolic_link"
    case hardLink = "hard_link"
    case fifo
    case socket
    case blockDevice = "block_device"
    case characterDevice = "character_device"
}

struct MigrationVolumeDataExtent: Codable, Sendable, Equatable {
    let offset: UInt64
    let length: UInt64
}

struct MigrationVolumeXattr: Codable, Sendable, Equatable {
    let nameHex: String
    let valueHex: String
}

struct MigrationVolumeManifestEntry: Codable, Sendable, Equatable {
    let pathHex: String
    let kind: MigrationVolumeManifestEntryKind
    let mode: UInt32
    let uid: UInt32
    let gid: UInt32
    let size: UInt64
    let mtimeSeconds: Int64
    let mtimeNanoseconds: UInt32
    let contentSha256: String?
    let linkTargetHex: String?
    let hardLinkTargetHex: String?
    let sparseDataExtents: [MigrationVolumeDataExtent]?
    let deviceMajor: UInt64?
    let deviceMinor: UInt64?
    let xattrs: [MigrationVolumeXattr]

    fileprivate func validate(isRoot: Bool) throws {
        let path = try MigrationVolumeManifest.decodeHex(pathHex, maximumBytes: 4_096)
        try validatePath(path, isRoot: isRoot)
        guard mode <= 0o7777, mtimeNanoseconds < 1_000_000_000 else {
            throw MigrationVolumeManifestError.invalid("mode or modification time is invalid")
        }
        try validateXattrs()
        switch kind {
        case .regularFile:
            try requireDigest(contentSha256)
            try requireNil(linkTargetHex, hardLinkTargetHex, deviceMajor, deviceMinor)
            try validateSparseExtents()
        case .directory, .fifo, .socket:
            try requireZeroAndNoContent()
            try requireNil(deviceMajor, deviceMinor)
        case .symbolicLink:
            guard let linkTargetHex else {
                throw MigrationVolumeManifestError.invalid("symbolic link has no target")
            }
            let target = try MigrationVolumeManifest.decodeHex(linkTargetHex, maximumBytes: 4_096)
            guard !target.contains(0), UInt64(target.count) == size else {
                throw MigrationVolumeManifestError.invalid("symbolic-link target is invalid")
            }
            try requireNil(contentSha256, hardLinkTargetHex, sparseDataExtents, deviceMajor, deviceMinor)
        case .hardLink:
            guard hardLinkTargetHex != nil else {
                throw MigrationVolumeManifestError.invalid("hard link has no target")
            }
            try requireNil(contentSha256, linkTargetHex, sparseDataExtents, deviceMajor, deviceMinor)
        case .blockDevice, .characterDevice:
            try requireZeroAndNoContent()
            guard deviceMajor != nil, deviceMinor != nil else {
                throw MigrationVolumeManifestError.invalid("device identity is missing")
            }
        }
    }

    fileprivate func hardLinkMetadataMatches(_ target: Self) -> Bool {
        mode == target.mode && uid == target.uid && gid == target.gid && size == target.size
            && mtimeSeconds == target.mtimeSeconds
            && mtimeNanoseconds == target.mtimeNanoseconds && xattrs == target.xattrs
    }

    private func validatePath(_ path: Data, isRoot: Bool) throws {
        if isRoot {
            guard path.isEmpty else {
                throw MigrationVolumeManifestError.invalid("root path is not empty")
            }
            return
        }
        guard !path.isEmpty, path.first != UInt8(ascii: "/"), !path.contains(0) else {
            throw MigrationVolumeManifestError.invalid("path is empty, absolute, or contains NUL")
        }
        for component in path.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false) {
            guard !component.isEmpty, component != Data(".".utf8), component != Data("..".utf8) else {
                throw MigrationVolumeManifestError.invalid("path contains an unsafe component")
            }
        }
    }

    private func validateXattrs() throws {
        guard xattrs.count <= 1_024 else {
            throw MigrationVolumeManifestError.invalid("xattr count limit exceeded")
        }
        var priorName: Data?
        for xattr in xattrs {
            let name = try MigrationVolumeManifest.decodeHex(xattr.nameHex, maximumBytes: 255)
            _ = try MigrationVolumeManifest.decodeHex(xattr.valueHex, maximumBytes: 65_536)
            guard !name.isEmpty, !name.contains(0),
                  priorName.map({ $0.lexicographicallyPrecedes(name) }) ?? true else {
                throw MigrationVolumeManifestError.invalid("xattrs are not sorted and unique")
            }
            priorName = name
        }
    }

    private func validateSparseExtents() throws {
        guard let sparseDataExtents else {
            throw MigrationVolumeManifestError.invalid("regular file has unknown sparse layout")
        }
        var previousEnd: UInt64 = 0
        for extent in sparseDataExtents {
            let (end, overflow) = extent.offset.addingReportingOverflow(extent.length)
            guard extent.length > 0, extent.offset >= previousEnd, !overflow, end <= size else {
                throw MigrationVolumeManifestError.invalid("sparse extents are invalid")
            }
            previousEnd = end
        }
    }

    private func requireDigest(_ digest: String?) throws {
        guard let digest,
              (try? MigrationVolumeManifest.decodeHex(digest, maximumBytes: 32).count) == 32,
              digest.count == 64 else {
            throw MigrationVolumeManifestError.invalid("content digest is invalid")
        }
    }

    private func requireZeroAndNoContent() throws {
        guard size == 0 else {
            throw MigrationVolumeManifestError.invalid("non-content entry has nonzero size")
        }
        try requireNil(contentSha256, linkTargetHex, hardLinkTargetHex, sparseDataExtents)
    }

    private func requireNil(_ values: Any?...) throws {
        guard values.allSatisfy({ $0 == nil }) else {
            throw MigrationVolumeManifestError.invalid("entry contains an unexpected field")
        }
    }
}

private extension MigrationVolumeManifest {
    static func validateJSONShape(_ data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              Set(root.keys) == ["schema_version", "root", "entries"],
              let rootEntry = root["root"] as? [String: Any],
              let entries = root["entries"] as? [[String: Any]] else {
            throw MigrationVolumeManifestError.invalid("JSON has unexpected fields")
        }
        try validateEntryShape(rootEntry)
        for entry in entries { try validateEntryShape(entry) }
    }

    static func validateEntryShape(_ entry: [String: Any]) throws {
        let expected: Set<String> = [
            "path_hex", "kind", "mode", "uid", "gid", "size", "mtime_seconds",
            "mtime_nanoseconds", "content_sha256", "link_target_hex", "hard_link_target_hex",
            "sparse_data_extents", "device_major", "device_minor", "xattrs"
        ]
        guard Set(entry.keys) == expected,
              let xattrs = entry["xattrs"] as? [[String: Any]],
              xattrs.allSatisfy({ Set($0.keys) == ["name_hex", "value_hex"] }) else {
            throw MigrationVolumeManifestError.invalid("entry has unexpected fields")
        }
        if let extents = entry["sparse_data_extents"] as? [[String: Any]],
           !extents.allSatisfy({ Set($0.keys) == ["offset", "length"] }) {
            throw MigrationVolumeManifestError.invalid("sparse extent has unexpected fields")
        }
    }
}
