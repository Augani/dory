import CryptoKit
import Darwin
import Foundation

struct MigrationTransferHelperMetadata: Codable, Sendable, Equatable {
    let archiveBytes: Int
    let archiveSha256: String
    let helperBytes: Int
    let helperSha256: String
    let imageConfigDigest: String
    let layerDiffId: String
    let platform: String
    let schemaVersion: Int
}

struct MigrationTransferHelperContract: Codable, Sendable, Equatable {
    let archiveSha256: String
    let helperSha256: String
    let imageConfigDigest: String
    let layerDiffId: String
    let platform: String

    init(metadata: MigrationTransferHelperMetadata) {
        archiveSha256 = metadata.archiveSha256
        helperSha256 = metadata.helperSha256
        imageConfigDigest = metadata.imageConfigDigest
        layerDiffId = metadata.layerDiffId
        platform = metadata.platform
    }

    static let appleSiliconV1 = MigrationTransferHelperContract(
        metadata: MigrationTransferHelperMetadata(
            archiveBytes: MigrationTransferHelperPins.appleSiliconV1.archiveBytes,
            archiveSha256: MigrationTransferHelperPins.appleSiliconV1.archiveSha256,
            helperBytes: MigrationTransferHelperPins.appleSiliconV1.helperBytes,
            helperSha256: MigrationTransferHelperPins.appleSiliconV1.helperSha256,
            imageConfigDigest: MigrationTransferHelperPins.appleSiliconV1.imageConfigDigest,
            layerDiffId: MigrationTransferHelperPins.appleSiliconV1.layerDiffId,
            platform: "linux/arm64",
            schemaVersion: 1
        )
    )
}

struct MigrationTransferHelperPins: Sendable, Equatable {
    let archiveBytes: Int
    let archiveSha256: String
    let helperBytes: Int
    let helperSha256: String
    let imageConfigDigest: String
    let layerDiffId: String

    static let appleSiliconV1 = MigrationTransferHelperPins(
        archiveBytes: 583_680,
        archiveSha256: "6c14eb42f746de954c83d1d8af1aebf4854109398577ed08ae17f996997652f5",
        helperBytes: 565_816,
        helperSha256: "4440980c80e72745701b140fa17b02b1860ce3a96c2f48ecfcc4a1df157b1526",
        imageConfigDigest: "sha256:55b921dfc8885caab2f6c054806603d06640da14884b4b749ff7e3294d0b11a5",
        layerDiffId: "sha256:59cc13243aaa2e08ee8c550b4d8bf6602773cb2052bb9ef7331705337224c0ed"
    )
}

enum MigrationTransferHelperError: Error, Sendable, Equatable, CustomStringConvertible {
    case unavailable(String)
    case invalidAsset(String)
    case incompatibleEngine(String)
    case engineOperation(String)

    var description: String {
        switch self {
        case let .unavailable(detail): return "transfer helper is unavailable: \(detail)"
        case let .invalidAsset(detail): return "transfer helper asset is invalid: \(detail)"
        case let .incompatibleEngine(detail): return "transfer helper cannot run: \(detail)"
        case let .engineOperation(detail): return "transfer helper engine operation failed: \(detail)"
        }
    }
}

struct MigrationTransferHelperAsset: Sendable, Equatable {
    static let archiveName = "dory-transfer-helper-image-arm64"
    static let maximumArchiveBytes = 64 * 1_024 * 1_024

    let archive: Data
    let metadata: MigrationTransferHelperMetadata

    init(
        archive: Data,
        metadataData: Data,
        pins: MigrationTransferHelperPins = .appleSiliconV1
    ) throws {
        guard !archive.isEmpty, archive.count <= Self.maximumArchiveBytes else {
            throw MigrationTransferHelperError.invalidAsset("archive size is outside the v1 limit")
        }
        let decoder = JSONDecoder()
        guard let metadata = try? decoder.decode(
            MigrationTransferHelperMetadata.self,
            from: metadataData
        ) else {
            throw MigrationTransferHelperError.invalidAsset("metadata is not the exact v1 schema")
        }
        let encoder = JSONEncoder()
        // Match the deterministic image builder's RFC 8259 representation exactly. JSONEncoder
        // otherwise escapes the harmless slash in `linux/arm64`, producing bytes the bundled
        // Python builder never emits.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var canonicalMetadata = try encoder.encode(metadata)
        canonicalMetadata.append(0x0A)
        guard canonicalMetadata == metadataData else {
            throw MigrationTransferHelperError.invalidAsset("metadata is not canonical JSON")
        }
        guard metadata.schemaVersion == 1,
              metadata.platform == "linux/arm64",
              metadata.archiveBytes == pins.archiveBytes,
              metadata.archiveSha256 == pins.archiveSha256,
              metadata.helperBytes == pins.helperBytes,
              metadata.helperSha256 == pins.helperSha256,
              metadata.imageConfigDigest == pins.imageConfigDigest,
              metadata.layerDiffId == pins.layerDiffId else {
            throw MigrationTransferHelperError.invalidAsset("metadata does not match the audited pins")
        }
        guard archive.count == metadata.archiveBytes,
              Self.sha256(archive) == metadata.archiveSha256 else {
            throw MigrationTransferHelperError.invalidAsset("archive bytes do not match metadata")
        }
        self.archive = archive
        self.metadata = metadata
    }

    static func bundled(in bundle: Bundle = .main) throws -> MigrationTransferHelperAsset {
        #if arch(arm64)
        guard let archiveURL = bundle.url(forResource: archiveName, withExtension: "tar"),
              let metadataURL = bundle.url(forResource: archiveName, withExtension: "json") else {
            throw MigrationTransferHelperError.unavailable("the signed app bundle has no arm64 asset")
        }
        return try MigrationTransferHelperAsset(
            archive: secureRead(archiveURL, maximumBytes: maximumArchiveBytes),
            metadataData: secureRead(metadataURL, maximumBytes: 16 * 1_024)
        )
        #else
        throw MigrationTransferHelperError.unavailable("Apple Silicon is required for public v1")
        #endif
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func secureRead(_ url: URL, maximumBytes: Int) throws -> Data {
        let path = url.path
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw MigrationTransferHelperError.unavailable("cannot securely open \(url.lastPathComponent)")
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_nlink == 1,
              status.st_size > 0,
              status.st_size <= maximumBytes else {
            throw MigrationTransferHelperError.invalidAsset("unsafe file contract for \(url.lastPathComponent)")
        }
        var result = Data(count: Int(status.st_size))
        let count = result.withUnsafeMutableBytes { buffer -> Int in
            guard let address = buffer.baseAddress else { return -1 }
            var offset = 0
            while offset < buffer.count {
                let amount = Darwin.read(descriptor, address.advanced(by: offset), buffer.count - offset)
                if amount < 0, errno == EINTR { continue }
                if amount <= 0 { return -1 }
                offset += amount
            }
            return offset
        }
        guard count == result.count else {
            throw MigrationTransferHelperError.invalidAsset("short read for \(url.lastPathComponent)")
        }
        return result
    }
}
