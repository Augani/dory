import CryptoKit
import Darwin
import Foundation

public enum DoryVZMacPortableBundleError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    case destinationExists(String)
    case sourceMustBeStopped
    case invalidBundle(String)
    case artifactMismatch(String)

    public var description: String {
        switch self {
        case .destinationExists(let path):
            "portable VZMac destination already exists: \(path)"
        case .sourceMustBeStopped:
            "portable VZMac export requires an installed, stopped machine"
        case .invalidBundle(let detail):
            "invalid portable VZMac bundle: \(detail)"
        case .artifactMismatch(let path):
            "portable VZMac artifact does not match its receipt: \(path)"
        }
    }
}

public struct DoryVZMacPortableFile: Codable, Sendable, Equatable {
    public let relativePath: String
    public let bytes: UInt64
    public let sha256: String

    public init(relativePath: String, bytes: UInt64, sha256: String) {
        self.relativePath = relativePath
        self.bytes = bytes
        self.sha256 = sha256
    }

    public func validate() throws {
        guard Self.allowedRelativePaths.contains(relativePath)
                || Self.dataDiskRelativePaths.contains(relativePath) else {
            throw DoryVZMacPortableBundleError.invalidBundle(
                "unexpected artifact path \(relativePath)"
            )
        }
        guard bytes > 0 else {
            throw DoryVZMacPortableBundleError.invalidBundle(
                "artifact byte count must be positive"
            )
        }
        guard sha256.count == 64,
              sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw DoryVZMacPortableBundleError.invalidBundle(
                "artifact SHA-256 is not canonical"
            )
        }
    }

    fileprivate static let allowedRelativePaths: Set<String> = [
        DoryVZMacMachineBundle.manifestName,
        DoryVZMacMachineBundle.diskName,
        DoryVZMacMachineBundle.auxiliaryStorageName,
        DoryVZMacMachineBundle.hardwareModelName,
        DoryVZMacMachineBundle.machineIdentifierName,
    ]

    fileprivate static let dataDiskRelativePaths: [String] =
        (1...DoryVZMacResourcePlan.maximumDataDiskCount).map {
            "\(DoryVZMacMachineBundle.dataDisksDirectoryName)/\(String(format: "data-%02d.img", $0))"
        }
}

public struct DoryVZMacPortableManifest: Codable, Sendable, Equatable {
    public static let schema = "dory.vzmac-portable@2"
    public static let legacySchema = "dory.vzmac-portable@1"

    public let schema: String
    public let createdAt: String
    public let sourceMachineIdentifierSHA256: String
    public let consistency: String
    public let excludedArtifacts: [String]
    public let files: [DoryVZMacPortableFile]

    public init(
        schema: String = Self.schema,
        createdAt: String,
        sourceMachineIdentifierSHA256: String,
        consistency: String = "cold-stopped",
        excludedArtifacts: [String] = [
            "macOS restore image",
            "framework live/suspended state",
            "host credentials/bookmarks",
            "clipboard and camera/audio data",
        ],
        files: [DoryVZMacPortableFile]
    ) {
        self.schema = schema
        self.createdAt = createdAt
        self.sourceMachineIdentifierSHA256 = sourceMachineIdentifierSHA256
        self.consistency = consistency
        self.excludedArtifacts = excludedArtifacts
        self.files = files
    }

    public func validate() throws {
        guard schema == Self.schema || schema == Self.legacySchema else {
            throw DoryVZMacPortableBundleError.invalidBundle("unsupported receipt schema")
        }
        guard ISO8601DateFormatter().date(from: createdAt) != nil else {
            throw DoryVZMacPortableBundleError.invalidBundle(
                "createdAt is not canonical ISO-8601"
            )
        }
        guard sourceMachineIdentifierSHA256.count == 64,
              sourceMachineIdentifierSHA256.allSatisfy({
                  $0.isHexDigit && !$0.isUppercase
              }) else {
            throw DoryVZMacPortableBundleError.invalidBundle(
                "source machine identity digest is not canonical"
            )
        }
        guard consistency == "cold-stopped" else {
            throw DoryVZMacPortableBundleError.invalidBundle(
                "unsupported portability consistency"
            )
        }
        guard !excludedArtifacts.isEmpty else {
            throw DoryVZMacPortableBundleError.invalidBundle(
                "excluded-artifact disclosure is missing"
            )
        }
        for file in files { try file.validate() }
        let paths = files.map(\.relativePath)
        let dataPaths = Set(paths).subtracting(DoryVZMacPortableFile.allowedRelativePaths)
        guard Set(paths).isSuperset(of: DoryVZMacPortableFile.allowedRelativePaths),
              Set(paths).count == paths.count,
              dataPaths == Set(DoryVZMacPortableFile.dataDiskRelativePaths.prefix(dataPaths.count)),
              schema != Self.legacySchema || dataPaths.isEmpty else {
            throw DoryVZMacPortableBundleError.invalidBundle(
                "portable artifact set is incomplete or duplicated"
            )
        }
    }

    // The portable receipt is not allowed to drop a disk, add an unrelated disk, or
    // reinterpret a legacy export as one with data disks. Both formats bind the exact
    // artifact set to the embedded machine's resource plan before any restore allocation.
    func validateArtifacts(for machine: DoryVZMacMachineManifest) throws {
        try validate()
        try machine.validate()
        guard machine.installationState == .stopped,
              sourceMachineIdentifierSHA256 == machine.machineIdentifierSHA256,
              Set(files.map(\.relativePath))
                == Set(DoryVZMacMachineBundle.artifactPaths(for: machine.resources)) else {
            throw DoryVZMacPortableBundleError.invalidBundle(
                "machine state, identity or managed disk set differs from the portability receipt"
            )
        }
        let diskSizes = Dictionary(uniqueKeysWithValues:
            [(DoryVZMacMachineBundle.diskName, machine.resources.diskBytes)]
                + machine.resources.dataDisks.map {
                    ("\(DoryVZMacMachineBundle.dataDisksDirectoryName)/\($0.fileName)", $0.byteCount)
                }
        )
        for file in files {
            if let expected = diskSizes[file.relativePath], file.bytes != expected {
                throw DoryVZMacPortableBundleError.invalidBundle(
                    "disk capacity differs from the embedded machine resource plan"
                )
            }
        }
    }
}

public struct DoryVZMacPortableBundle: Sendable {
    public static let receiptName = "export.json"
    public static let maximumReceiptBytes = 1_048_576

    public let rootURL: URL
    public let manifest: DoryVZMacPortableManifest

    public static func export(
        machine source: DoryVZMacMachineBundle,
        to destination: URL
    ) throws -> Self {
        guard source.manifest.installationState == .stopped else {
            throw DoryVZMacPortableBundleError.sourceMustBeStopped
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw DoryVZMacPortableBundleError.destinationExists(destination.path)
        }
        let lease = try DoryVZMacMachineLease(rootURL: source.rootURL)
        defer { withExtendedLifetime(lease) {} }
        let source = try DoryVZMacMachineBundle.load(from: source.rootURL)
        guard source.manifest.installationState == .stopped else {
            throw DoryVZMacPortableBundleError.sourceMustBeStopped
        }
        let parent = destination.deletingLastPathComponent()
        try requireDirectDirectory(parent, label: "export parent")
        let staging = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).exporting-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        var committed = false
        defer {
            if !committed { try? FileManager.default.removeItem(at: staging) }
        }

        let relativePaths = DoryVZMacMachineBundle.artifactPaths(for: source.manifest.resources).sorted()
        try copyArtifacts(from: source.rootURL, to: staging, relativePaths: relativePaths)
        var files = [DoryVZMacPortableFile]()
        for relativePath in relativePaths {
            let destinationURL = staging.appendingPathComponent(relativePath)
            files.append(try receipt(for: destinationURL, relativePath: relativePath))
        }
        let manifest = DoryVZMacPortableManifest(
            createdAt: ISO8601DateFormatter().string(from: Date()),
            sourceMachineIdentifierSHA256: source.manifest.machineIdentifierSHA256,
            files: files
        )
        try manifest.validateArtifacts(for: source.manifest)
        try DoryVZMacMetadataFile.write(
            encode(manifest), to: staging.appendingPathComponent(Self.receiptName)
        )
        _ = try load(from: staging)
        try DoryVZMacBundlePublication.publish(
            staging: staging, to: destination, relativeFiles: relativePaths + [Self.receiptName],
            barrierFile: Self.receiptName
        )
        committed = true
        return try load(from: destination)
    }

    public static func load(from rootURL: URL) throws -> Self {
        try requireDirectDirectory(rootURL, label: "portable bundle root")
        let receiptURL = rootURL.appendingPathComponent(Self.receiptName)
        try requireDirectRegularFile(receiptURL, label: Self.receiptName)
        let receiptBytes = try fileBytes(receiptURL)
        guard receiptBytes > 0, receiptBytes <= UInt64(Self.maximumReceiptBytes) else {
            throw DoryVZMacPortableBundleError.invalidBundle("receipt size is invalid")
        }
        let manifest: DoryVZMacPortableManifest
        do {
            manifest = try JSONDecoder().decode(
                DoryVZMacPortableManifest.self,
                from: DoryVZMacMetadataFile.read(
                    from: receiptURL, maximumBytes: Self.maximumReceiptBytes
                )
            )
        } catch {
            throw DoryVZMacPortableBundleError.invalidBundle("receipt JSON cannot be decoded")
        }
        try manifest.validate()
        let machineManifest = try JSONDecoder().decode(
            DoryVZMacMachineManifest.self,
            from: DoryVZMacMetadataFile.read(
                from: rootURL.appendingPathComponent(DoryVZMacMachineBundle.manifestName),
                maximumBytes: DoryVZMacMachineBundle.maximumManifestBytes
            )
        )
        try manifest.validateArtifacts(for: machineManifest)
        if !machineManifest.resources.dataDisks.isEmpty {
            try requireDirectDirectory(
                rootURL.appendingPathComponent(DoryVZMacMachineBundle.dataDisksDirectoryName),
                label: "portable managed data disks"
            )
        }
        guard try !DoryVZMacMetadataFile.entryExists(
            at: rootURL.appendingPathComponent(
                DoryVZMacMachineBundle.suspendedStateDirectoryName, isDirectory: false
            )
        ) else {
            throw DoryVZMacPortableBundleError.invalidBundle(
                "framework live state is forbidden in a portable bundle"
            )
        }
        for file in manifest.files {
            let url = rootURL.appendingPathComponent(file.relativePath)
            try requireDirectRegularFile(url, label: file.relativePath)
            guard try fileBytes(url) == file.bytes,
                  try sha256(url) == file.sha256 else {
                throw DoryVZMacPortableBundleError.artifactMismatch(file.relativePath)
            }
        }
        let machine = try DoryVZMacMachineBundle.load(from: rootURL)
        guard machine.manifest.installationState == .stopped,
              machine.manifest.machineIdentifierSHA256
                == manifest.sourceMachineIdentifierSHA256 else {
            throw DoryVZMacPortableBundleError.invalidBundle(
                "machine state or identity differs from the portability receipt"
            )
        }
        return Self(rootURL: rootURL, manifest: manifest)
    }

    public func restore(to destination: URL) throws -> DoryVZMacMachineBundle {
        let validated = try Self.load(from: rootURL)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw DoryVZMacPortableBundleError.destinationExists(destination.path)
        }
        let parent = destination.deletingLastPathComponent()
        try requireDirectDirectory(parent, label: "restore parent")
        let staging = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).importing-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        var committed = false
        defer {
            if !committed { try? FileManager.default.removeItem(at: staging) }
        }
        let relativePaths = validated.manifest.files.map(\.relativePath)
        try Self.copyArtifacts(from: rootURL, to: staging, relativePaths: relativePaths)
        for file in validated.manifest.files {
            let destinationURL = staging.appendingPathComponent(file.relativePath)
            guard try fileBytes(destinationURL) == file.bytes,
                  try sha256(destinationURL) == file.sha256 else {
                throw DoryVZMacPortableBundleError.artifactMismatch(file.relativePath)
            }
        }
        _ = try DoryVZMacMachineBundle.load(from: staging)
        try DoryVZMacBundlePublication.publish(
            staging: staging, to: destination, relativeFiles: relativePaths
        )
        committed = true
        return try DoryVZMacMachineBundle.load(from: destination)
    }

    static func copyArtifacts(from source: URL, to staging: URL, relativePaths: [String]) throws {
        // Paths come from the resource plan or a validated portable receipt. Validate the
        // complete bounded set before creating anything, including its data-directory root.
        guard Set(relativePaths).count == relativePaths.count,
              relativePaths.count <= 5 + DoryVZMacResourcePlan.maximumDataDiskCount else {
            throw DoryVZMacPortableBundleError.invalidBundle("invalid copy artifact set")
        }
        for path in relativePaths {
            guard DoryVZMacPortableFile.allowedRelativePaths.contains(path)
                    || DoryVZMacPortableFile.dataDiskRelativePaths.contains(path) else {
                throw DoryVZMacPortableBundleError.invalidBundle("unexpected copy artifact path")
            }
        }
        try requireDirectDirectory(source, label: "copy source root")
        try requireDirectDirectory(staging, label: "copy staging root")
        if relativePaths.contains(where: { $0.contains("/") }) {
            try requireDirectDirectory(
                source.appendingPathComponent(DoryVZMacMachineBundle.dataDisksDirectoryName),
                label: "managed data disks"
            )
            try FileManager.default.createDirectory(
                at: staging.appendingPathComponent(DoryVZMacMachineBundle.dataDisksDirectoryName),
                withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
            )
        }
        for path in relativePaths {
            let sourceURL = source.appendingPathComponent(path)
            let destinationURL = staging.appendingPathComponent(path)
            try requireDirectRegularFile(sourceURL, label: path)
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            try requireDirectRegularFile(destinationURL, label: path)
        }
    }
}

private func receipt(for url: URL, relativePath: String) throws -> DoryVZMacPortableFile {
    DoryVZMacPortableFile(
        relativePath: relativePath,
        bytes: try fileBytes(url),
        sha256: try sha256(url)
    )
}

private func fileBytes(_ url: URL) throws -> UInt64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let size = attributes[.size] as? NSNumber else {
        throw DoryVZMacPortableBundleError.invalidBundle(
            "cannot determine artifact size for \(url.lastPathComponent)"
        )
    }
    return size.uint64Value
}

private func sha256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
        let readChunk = try autoreleasepool {
            guard let data = try handle.read(upToCount: 4 * 1_024 * 1_024), !data.isEmpty else { return false }
            hasher.update(data: data)
            return true
        }
        if !readChunk { break }
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

private func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

private func requireDirectDirectory(_ url: URL, label: String) throws {
    var status = stat()
    guard lstat(url.path, &status) == 0,
          (status.st_mode & S_IFMT) == S_IFDIR else {
        throw DoryVZMacPortableBundleError.invalidBundle(
            "\(label) is not a direct directory"
        )
    }
}

private func requireDirectRegularFile(_ url: URL, label: String) throws {
    var status = stat()
    guard lstat(url.path, &status) == 0,
          (status.st_mode & S_IFMT) == S_IFREG else {
        throw DoryVZMacPortableBundleError.invalidBundle(
            "\(label) is not a direct regular file"
        )
    }
}
