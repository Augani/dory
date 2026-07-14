import CryptoKit
import Darwin
import Foundation

public enum DoryDataDriveArchiveError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidArchive(String)
    case invalidDestination(String)
    case sourceInUse(String)
    case sourceChanged(String)
    case unsupportedEntry(String)
    case insufficientSpace(required: UInt64, available: UInt64)
    case filesystem(String)

    public var description: String {
        switch self {
        case let .invalidArchive(path):
            return "invalid or incomplete Dory backup: \(path)"
        case let .invalidDestination(path):
            return "invalid Dory backup destination: \(path)"
        case let .sourceInUse(message):
            return message
        case let .sourceChanged(path):
            return "Dory data changed while it was being backed up: \(path)"
        case let .unsupportedEntry(path):
            return "Dory data contains an unsupported filesystem entry: \(path)"
        case let .insufficientSpace(required, available):
            return "not enough free space for Dory data operation (need \(required) bytes, have \(available))"
        case let .filesystem(message):
            return message
        }
    }
}

public struct DoryDataDriveArchiveVerification: Codable, Sendable, Equatable {
    public let backupOperationID: UUID
    public let archiveManifestDigest: String
    public let sourceDriveID: UUID
    public let entryCount: Int
    public let chunkCount: Int
    public let logicalBytes: UInt64
    public let storedBytes: UInt64
}

enum DoryDataDriveArchiveEntryKind: String, Codable, Sendable {
    case directory
    case regularFile
    case symbolicLink
    case hardLink
}

struct DoryDataDriveArchiveXattr: Codable, Sendable, Equatable {
    let name: String
    let value: Data
}

struct DoryDataDriveArchiveMetadata: Codable, Sendable, Equatable {
    let mode: UInt32
    let uid: UInt32
    let gid: UInt32
    let modificationSeconds: Int64
    let modificationNanoseconds: Int32
    let xattrs: [DoryDataDriveArchiveXattr]
    let aclText: String?
}

struct DoryDataDriveArchiveChunk: Codable, Sendable, Equatable {
    let digest: String
    let length: UInt64
}

struct DoryDataDriveArchiveExtent: Codable, Sendable, Equatable {
    let offset: UInt64
    let length: UInt64
    let chunks: [DoryDataDriveArchiveChunk]
}

struct DoryDataDriveArchiveEntry: Codable, Sendable, Equatable {
    let path: String
    let kind: DoryDataDriveArchiveEntryKind
    let metadata: DoryDataDriveArchiveMetadata
    let logicalSize: UInt64?
    let extents: [DoryDataDriveArchiveExtent]?
    let linkTarget: String?
}

struct DoryDataDriveArchiveManifest: Codable, Sendable, Equatable {
    static let schemaVersion = 1

    let kind: String
    let schemaVersion: Int
    let operationID: UUID
    let createdAt: String
    let sourcePath: String
    let sourceDrive: DoryDataDriveManifest
    let rootMetadata: DoryDataDriveArchiveMetadata
    let entries: [DoryDataDriveArchiveEntry]

    init(
        operationID: UUID,
        createdAt: Date,
        sourcePath: String,
        sourceDrive: DoryDataDriveManifest,
        rootMetadata: DoryDataDriveArchiveMetadata,
        entries: [DoryDataDriveArchiveEntry]
    ) {
        kind = "dev.dory.data-drive-backup"
        schemaVersion = Self.schemaVersion
        self.operationID = operationID
        self.createdAt = DoryOperationJournalStore.timestamp(createdAt)
        self.sourcePath = sourcePath
        self.sourceDrive = sourceDrive
        self.rootMetadata = rootMetadata
        self.entries = entries
    }
}

private struct DoryDataDriveArchiveCompletion: Codable, Sendable, Equatable {
    static let schemaVersion = 1

    let kind: String
    let schemaVersion: Int
    let operationID: UUID
    let archiveManifestDigest: String
    let sourceDriveID: UUID
    let entryCount: Int
    let chunkCount: Int

    init(
        operationID: UUID,
        archiveManifestDigest: String,
        sourceDriveID: UUID,
        entryCount: Int,
        chunkCount: Int
    ) {
        kind = "dev.dory.data-drive-backup-complete"
        schemaVersion = Self.schemaVersion
        self.operationID = operationID
        self.archiveManifestDigest = archiveManifestDigest
        self.sourceDriveID = sourceDriveID
        self.entryCount = entryCount
        self.chunkCount = chunkCount
    }
}

private struct DoryDataDriveArchiveLoaded {
    let manifest: DoryDataDriveArchiveManifest
    let manifestDigest: String
    let verification: DoryDataDriveArchiveVerification
}

private struct DoryDataDriveRestoreOwner: Codable, Sendable, Equatable {
    static let fileName = ".dory-restore-owner.json"

    let kind: String
    let operationID: UUID
    let archiveManifestDigest: String
    let targetPath: String

    init(operationID: UUID, archiveManifestDigest: String, targetPath: String) {
        kind = "dev.dory.data-drive-restore-owner"
        self.operationID = operationID
        self.archiveManifestDigest = archiveManifestDigest
        self.targetPath = targetPath
    }
}

private final class DoryDataDriveArchiveScanContext {
    let chunkDirectory: String?
    let excludedPaths: Set<String>
    var entries: [DoryDataDriveArchiveEntry] = []
    var hardLinks: [String: (path: String, metadata: DoryDataDriveArchiveMetadata)] = [:]

    init(chunkDirectory: String?, excludedPaths: Set<String>) {
        self.chunkDirectory = chunkDirectory
        self.excludedPaths = excludedPaths
    }
}

/// Sparse, content-addressed full-drive backup and restore.
///
/// The engine's lifetime lock is the quiescence boundary. Archives are private sibling partials
/// until every referenced chunk has been read back and a manifest-bound completion marker exists.
/// Restore follows the same rule: it reconstructs and independently inventories a sibling partial
/// before the `.dorydrive` name becomes visible.
public enum DoryDataDriveArchive {
    static let chunkSize = 8 * 1_024 * 1_024
    static let maximumManifestBytes = 64 * 1_024 * 1_024
    static let maximumEntryCount = 1_000_000
    static let maximumXattrBytes = 8 * 1_024 * 1_024
    static let maximumACLBytes = 1 * 1_024 * 1_024
    static let capacitySafetyBytes: UInt64 = 256 * 1_024 * 1_024

    @discardableResult
    static func createBackupPayload(
        from drive: DoryDataDrive,
        to requestedDestination: String,
        operationID: UUID,
        phase: ((DoryOperationPhase) throws -> Void)? = nil,
        fileManager: FileManager = .default
    ) throws -> DoryDataDriveArchiveVerification {
        try drive.validateManifest(fileManager: fileManager)
        let destination = try canonicalArchivePath(requestedDestination)
        guard !isSameOrDescendant(destination, of: drive.root),
              !isSameOrDescendant(drive.root, of: destination),
              !pathEntryExists(destination) else {
            throw DoryDataDriveArchiveError.invalidDestination(destination)
        }
        let parent = URL(fileURLWithPath: destination).deletingLastPathComponent().path
        try requireWritableLocalAPFS(parent)

        let driveLock: EngineStateDirectoryLock
        do {
            driveLock = try EngineStateDirectoryLock(
                stateDirectory: drive.root,
                lockFileName: "drive.lock"
            )
        } catch let error as EngineStateDirectoryLockError {
            throw DoryDataDriveArchiveError.sourceInUse(
                "stop Dory before backup; \(error.description)"
            )
        }
        defer { withExtendedLifetime(driveLock) {} }
        try phase?(.quiescing)

        let estimated = try estimatedAllocatedBytes(at: drive.root, excludingRootLock: true)
        try requireCapacity(at: parent, payloadBytes: estimated)

        let partial = operationPartialPath(destination: destination, operationID: operationID)
        var published = false
        do {
            if pathEntryExists(partial) { try fileManager.removeItem(atPath: partial) }
            try phase?(.staging)
            try createPrivateDirectory(partial)
            try createPrivateDirectory(partial + "/chunks")
            let inventory = try scanTree(root: drive.root, chunkDirectory: partial + "/chunks")
            let manifest = DoryDataDriveArchiveManifest(
                operationID: operationID,
                createdAt: Date(),
                sourcePath: drive.root,
                sourceDrive: try drive.readManifest(fileManager: fileManager),
                rootMetadata: inventory.rootMetadata,
                entries: inventory.entries
            )
            let manifestData = try encoded(manifest)
            guard manifestData.count <= maximumManifestBytes else {
                throw DoryDataDriveArchiveError.invalidArchive(partial + "/archive.json")
            }
            try writePrivateFile(manifestData, to: partial + "/archive.json")
            try syncDirectory(partial + "/chunks")

            try phase?(.verifying)
            let staged = try loadArchive(at: partial, requireCompletion: false)
            let completion = DoryDataDriveArchiveCompletion(
                operationID: operationID,
                archiveManifestDigest: staged.manifestDigest,
                sourceDriveID: staged.manifest.sourceDrive.id,
                entryCount: staged.verification.entryCount,
                chunkCount: staged.verification.chunkCount
            )
            try writePrivateFile(try encoded(completion), to: partial + "/complete.json")
            _ = try loadArchive(at: partial, requireCompletion: true)
            try syncDirectory(partial)
            try phase?(.readyToPublish)
            try phase?(.publishing)
            try publishExclusive(partial, destination: destination)
            published = true
            try syncDirectory(parent)
            try phase?(.validating)
            return try verifyBackup(at: destination)
        } catch {
            try? fileManager.removeItem(atPath: published ? destination : partial)
            try? syncDirectory(parent)
            throw error
        }
    }

    public static func verifyBackup(
        at requestedArchive: String
    ) throws -> DoryDataDriveArchiveVerification {
        try loadArchive(at: canonicalArchivePath(requestedArchive), requireCompletion: true)
            .verification
    }

    @discardableResult
    static func restoreBackupPayload(
        at requestedArchive: String,
        to drive: DoryDataDrive,
        operationID: UUID,
        phase: ((DoryOperationPhase) throws -> Void)? = nil,
        fileManager: FileManager = .default
    ) throws -> DoryDataDriveArchiveVerification {
        let archive = try canonicalArchivePath(requestedArchive)
        let loaded = try loadArchive(at: archive, requireCompletion: true)
        guard !isSameOrDescendant(drive.root, of: archive),
              !isSameOrDescendant(archive, of: drive.root),
              try drive.inspect(fileManager: fileManager) == .absent else {
            throw DoryDataDriveArchiveError.invalidDestination(drive.root)
        }

        let parent = URL(fileURLWithPath: drive.root).deletingLastPathComponent().path
        do {
            try fileManager.createDirectory(
                atPath: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw DoryDataDriveArchiveError.filesystem(
                "prepare Dory restore destination at \(parent): \(error)"
            )
        }
        try requireWritableLocalAPFS(parent)
        try requireCapacity(at: parent, payloadBytes: loaded.verification.storedBytes)

        let creationLock: EngineStateDirectoryLock
        do {
            creationLock = try EngineStateDirectoryLock(
                stateDirectory: parent,
                lockFileName: ".\(URL(fileURLWithPath: drive.root).lastPathComponent).creation.lock"
            )
        } catch let error as EngineStateDirectoryLockError {
            throw DoryDataDriveArchiveError.sourceInUse(error.description)
        }
        defer { withExtendedLifetime(creationLock) {} }
        try phase?(.quiescing)
        guard !pathEntryExists(drive.root) else {
            throw DoryDataDriveArchiveError.invalidDestination(drive.root)
        }

        let partial = operationPartialPath(destination: drive.root, operationID: operationID)
        var published = false
        do {
            if pathEntryExists(partial) { try fileManager.removeItem(atPath: partial) }
            try phase?(.staging)
            try createPrivateDirectory(partial)
            try restoreEntries(
                loaded.manifest.entries,
                archive: archive,
                destination: partial
            )
            let rebound = try drive.restoredManifest(
                preserving: loaded.manifest.sourceDrive,
                fileManager: fileManager
            )
            try drive.writeRestoredManifest(rebound, into: partial, fileManager: fileManager)
            if let driveManifestEntry = loaded.manifest.entries.first(where: { $0.path == "drive.json" }) {
                try applyMetadata(driveManifestEntry.metadata, to: partial + "/drive.json", symbolicLink: false)
                try removeUnexpectedXattrs(
                    at: partial + "/drive.json",
                    symbolicLink: false,
                    keeping: Set(driveManifestEntry.metadata.xattrs.map(\.name))
                )
            }
            try applyDirectoryMetadata(
                loaded.manifest.entries,
                rootMetadata: loaded.manifest.rootMetadata,
                root: partial
            )
            try phase?(.verifying)
            try verifyRestoredTree(
                root: partial,
                expected: loaded.manifest,
                reboundManifest: rebound
            )
            try syncTreeDirectories(root: partial, entries: loaded.manifest.entries)
            try phase?(.readyToPublish)
            try writeRestoreOwner(
                operationID: operationID,
                archiveManifestDigest: loaded.manifestDigest,
                targetPath: drive.root,
                root: partial
            )
            try syncDirectory(partial)
            try phase?(.publishing)
            try publishExclusive(partial, destination: drive.root)
            published = true
            try syncDirectory(parent)
            try phase?(.validating)
            try drive.validateManifest(fileManager: fileManager)
            return loaded.verification
        } catch {
            try? fileManager.removeItem(atPath: published ? drive.root : partial)
            try? syncDirectory(parent)
            throw error
        }
    }

    private static func restoreEntries(
        _ entries: [DoryDataDriveArchiveEntry],
        archive: String,
        destination: String
    ) throws {
        for entry in entries where entry.kind == .directory {
            let path = destination + "/" + entry.path
            try createPrivateDirectory(path)
        }
        for entry in entries where entry.kind == .regularFile {
            let path = destination + "/" + entry.path
            try restoreRegularFile(entry, archive: archive, destination: path)
            try applyMetadata(entry.metadata, to: path, symbolicLink: false)
            try removeUnexpectedXattrs(
                at: path,
                symbolicLink: false,
                keeping: Set(entry.metadata.xattrs.map(\.name))
            )
        }
        for entry in entries where entry.kind == .symbolicLink {
            guard let target = entry.linkTarget else {
                throw DoryDataDriveArchiveError.invalidArchive(archive)
            }
            let path = destination + "/" + entry.path
            guard target.withCString({ Darwin.symlink($0, path) }) == 0 else {
                throw filesystem("restore symbolic link at \(path)")
            }
            try applyMetadata(entry.metadata, to: path, symbolicLink: true)
            try removeUnexpectedXattrs(
                at: path,
                symbolicLink: true,
                keeping: Set(entry.metadata.xattrs.map(\.name))
            )
        }
        for entry in entries where entry.kind == .hardLink {
            guard let target = entry.linkTarget else {
                throw DoryDataDriveArchiveError.invalidArchive(archive)
            }
            let path = destination + "/" + entry.path
            let targetPath = destination + "/" + target
            guard Darwin.link(targetPath, path) == 0 else {
                throw filesystem("restore hard link at \(path)")
            }
        }
    }

    private static func restoreRegularFile(
        _ entry: DoryDataDriveArchiveEntry,
        archive: String,
        destination: String
    ) throws {
        guard let logicalSize = entry.logicalSize,
              let extents = entry.extents,
              logicalSize <= UInt64(Int64.max) else {
            throw DoryDataDriveArchiveError.invalidArchive(archive)
        }
        let descriptor = destination.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw filesystem("create restored file at \(destination)") }
        defer { Darwin.close(descriptor) }
        guard ftruncate(descriptor, off_t(logicalSize)) == 0 else {
            throw filesystem("size restored sparse file at \(destination)")
        }
        for extent in extents {
            var writeOffset = extent.offset
            for chunk in extent.chunks {
                let data = try readPrivateFile(
                    archive + "/chunks/" + chunk.digest,
                    maximumBytes: chunkSize
                )
                guard data.count == Int(chunk.length),
                      digest(data) == chunk.digest else {
                    throw DoryDataDriveArchiveError.invalidArchive(archive)
                }
                try pwriteAll(data, descriptor: descriptor, offset: writeOffset, path: destination)
                writeOffset += chunk.length
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw filesystem("sync restored file at \(destination)")
        }
    }

    private static func verifyRestoredTree(
        root: String,
        expected: DoryDataDriveArchiveManifest,
        reboundManifest: DoryDataDriveManifest,
        ignoredPath: String? = nil,
        metadataExceptions: Set<String> = []
    ) throws {
        let exclusions = ignoredPath.map { Set([$0]) } ?? []
        guard ignoredPath.map({ path in
            !expected.entries.contains(where: { $0.path == path })
        }) ?? true else {
            throw DoryDataDriveArchiveError.invalidArchive(root)
        }
        let actual = try scanTree(
            root: root,
            chunkDirectory: nil,
            excludedPaths: exclusions
        )
        guard actual.rootMetadata == expected.rootMetadata else {
            throw DoryDataDriveArchiveError.filesystem(
                "restored root metadata mismatch at \(root): expected "
                    + metadataDescription(expected.rootMetadata) + ", found "
                    + metadataDescription(actual.rootMetadata)
            )
        }
        guard actual.entries.count == expected.entries.count else {
            throw DoryDataDriveArchiveError.filesystem(
                "restored entry count mismatch at \(root): expected \(expected.entries.count), "
                    + "found \(actual.entries.count)"
            )
        }
        for (expectedEntry, actualEntry) in zip(expected.entries, actual.entries) {
            guard expectedEntry.path == actualEntry.path,
                  expectedEntry.kind == actualEntry.kind else {
                throw DoryDataDriveArchiveError.invalidArchive(root + "/" + actualEntry.path)
            }
            if !metadataExceptions.contains(expectedEntry.path),
               expectedEntry.metadata != actualEntry.metadata {
                throw DoryDataDriveArchiveError.filesystem(
                    "restored metadata mismatch at \(root)/\(actualEntry.path): expected "
                        + metadataDescription(expectedEntry.metadata) + ", found "
                        + metadataDescription(actualEntry.metadata)
                )
            }
            if expectedEntry.path != "drive.json",
               !entriesMatchContent(expectedEntry, actualEntry) {
                throw DoryDataDriveArchiveError.filesystem(
                    "restored content or sparse extents mismatch at \(root)/\(actualEntry.path)"
                )
            }
        }
        let manifestPath = root + "/drive.json"
        let data = try readPrivateFile(manifestPath, maximumBytes: 1_024 * 1_024)
        guard let restored = try? JSONDecoder().decode(DoryDataDriveManifest.self, from: data),
              restored == reboundManifest else {
            throw DoryDataDriveArchiveError.invalidArchive(manifestPath)
        }
    }

    static func restoreOwnerMatches(
        drive: DoryDataDrive,
        operationID: UUID,
        archiveManifestDigest: String
    ) -> Bool {
        let path = drive.root + "/" + DoryDataDriveRestoreOwner.fileName
        guard let data = try? readPrivateFile(path, maximumBytes: 1_024 * 1_024),
              let owner = try? JSONDecoder().decode(DoryDataDriveRestoreOwner.self, from: data),
              (try? encoded(owner)) == data else {
            return false
        }
        return owner.kind == "dev.dory.data-drive-restore-owner"
            && owner.operationID == operationID
            && owner.archiveManifestDigest == archiveManifestDigest
            && owner.targetPath == drive.root
    }

    static func finalizePublishedRestore(
        archive: String,
        drive: DoryDataDrive,
        operationID: UUID,
        summaryRelativePath: String,
        hasDurableSummary: Bool,
        fileManager: FileManager = .default
    ) throws -> DoryDataDriveArchiveVerification {
        let canonicalArchive = try canonicalArchivePath(archive)
        let loaded = try loadArchive(at: canonicalArchive, requireCompletion: true)
        let markerMatches = restoreOwnerMatches(
            drive: drive,
            operationID: operationID,
            archiveManifestDigest: loaded.manifestDigest
        )
        guard markerMatches || hasDurableSummary else {
            throw DoryDataDriveArchiveError.invalidDestination(drive.root)
        }
        try drive.validateManifest(fileManager: fileManager)
        let rebound = try drive.restoredManifest(
            preserving: loaded.manifest.sourceDrive,
            fileManager: fileManager
        )
        guard try drive.readManifest(fileManager: fileManager) == rebound else {
            throw DoryDataDriveArchiveError.invalidArchive(drive.manifestPath)
        }
        if markerMatches {
            try fileManager.removeItem(
                atPath: drive.root + "/" + DoryDataDriveRestoreOwner.fileName
            )
        }
        try applyMetadata(loaded.manifest.rootMetadata, to: drive.root, symbolicLink: false)
        try removeUnexpectedXattrs(
            at: drive.root,
            symbolicLink: false,
            keeping: Set(loaded.manifest.rootMetadata.xattrs.map(\.name))
        )
        try verifyRestoredTree(
            root: drive.root,
            expected: loaded.manifest,
            reboundManifest: rebound,
            ignoredPath: summaryRelativePath,
            metadataExceptions: ["operations"]
        )
        try syncDirectory(drive.root)
        return loaded.verification
    }

    private static func entriesMatchContent(
        _ lhs: DoryDataDriveArchiveEntry,
        _ rhs: DoryDataDriveArchiveEntry
    ) -> Bool {
        lhs.path == rhs.path
            && lhs.kind == rhs.kind
            && lhs.logicalSize == rhs.logicalSize
            && lhs.extents == rhs.extents
            && lhs.linkTarget == rhs.linkTarget
    }

    private static func metadataDescription(_ metadata: DoryDataDriveArchiveMetadata) -> String {
        "mode=\(String(metadata.mode, radix: 8)) uid=\(metadata.uid) gid=\(metadata.gid) "
            + "mtime=\(metadata.modificationSeconds).\(metadata.modificationNanoseconds) "
            + "xattrs=\(metadata.xattrs.map(\.name)) acl=\(metadata.aclText != nil)"
    }

    private static func loadArchive(
        at archive: String,
        requireCompletion: Bool
    ) throws -> DoryDataDriveArchiveLoaded {
        try validatePrivateDirectory(archive)
        try validatePrivateDirectory(archive + "/chunks")
        let manifestPath = archive + "/archive.json"
        let manifestData = try readPrivateFile(manifestPath, maximumBytes: maximumManifestBytes)
        guard let manifest = try? JSONDecoder().decode(
            DoryDataDriveArchiveManifest.self,
            from: manifestData
        ), try encoded(manifest) == manifestData else {
            throw DoryDataDriveArchiveError.invalidArchive(manifestPath)
        }
        try validateManifest(manifest, archive: archive)
        let manifestDigest = digest(manifestData)
        let referenced = Set(manifest.entries.flatMap { entry in
            (entry.extents ?? []).flatMap { $0.chunks.map(\.digest) }
        })
        let chunkEntries: [String]
        do {
            chunkEntries = try FileManager.default.contentsOfDirectory(atPath: archive + "/chunks")
                .sorted()
        } catch {
            throw DoryDataDriveArchiveError.filesystem(
                "list Dory backup chunks at \(archive): \(error)"
            )
        }
        guard Set(chunkEntries) == referenced,
              chunkEntries.allSatisfy(DoryOperationJournalStore.isDigest) else {
            throw DoryDataDriveArchiveError.invalidArchive(archive + "/chunks")
        }
        var storedBytes: UInt64 = 0
        for name in chunkEntries {
            let data = try readPrivateFile(archive + "/chunks/" + name, maximumBytes: chunkSize)
            guard digest(data) == name else {
                throw DoryDataDriveArchiveError.invalidArchive(archive + "/chunks/" + name)
            }
            storedBytes = try checkedAdd(storedBytes, UInt64(data.count), archive: archive)
        }
        let logicalBytes = try manifest.entries.reduce(UInt64(0)) { partial, entry in
            try checkedAdd(partial, entry.kind == .regularFile ? (entry.logicalSize ?? 0) : 0, archive: archive)
        }
        let verification = DoryDataDriveArchiveVerification(
            backupOperationID: manifest.operationID,
            archiveManifestDigest: manifestDigest,
            sourceDriveID: manifest.sourceDrive.id,
            entryCount: manifest.entries.count,
            chunkCount: chunkEntries.count,
            logicalBytes: logicalBytes,
            storedBytes: storedBytes
        )

        if requireCompletion {
            let completionPath = archive + "/complete.json"
            let completionData = try readPrivateFile(completionPath, maximumBytes: 1_024 * 1_024)
            guard let completion = try? JSONDecoder().decode(
                DoryDataDriveArchiveCompletion.self,
                from: completionData
            ), try encoded(completion) == completionData,
            completion.kind == "dev.dory.data-drive-backup-complete",
            completion.schemaVersion == DoryDataDriveArchiveCompletion.schemaVersion,
            completion.operationID == manifest.operationID,
            completion.archiveManifestDigest == manifestDigest,
            completion.sourceDriveID == manifest.sourceDrive.id,
            completion.entryCount == verification.entryCount,
            completion.chunkCount == verification.chunkCount else {
                throw DoryDataDriveArchiveError.invalidArchive(completionPath)
            }
        } else if pathEntryExists(archive + "/complete.json") {
            throw DoryDataDriveArchiveError.invalidArchive(archive + "/complete.json")
        }
        return DoryDataDriveArchiveLoaded(
            manifest: manifest,
            manifestDigest: manifestDigest,
            verification: verification
        )
    }

    private static func validateManifest(
        _ manifest: DoryDataDriveArchiveManifest,
        archive: String
    ) throws {
        guard manifest.kind == "dev.dory.data-drive-backup",
              manifest.schemaVersion == DoryDataDriveArchiveManifest.schemaVersion,
              DoryOperationJournalStore.isTimestamp(manifest.createdAt),
              manifest.sourcePath.hasPrefix("/"),
              DoryOperationJournalStore.isPrivateText(manifest.sourcePath, maximumLength: 4_096),
              manifest.sourceDrive.isValid,
              metadataIsValid(manifest.rootMetadata),
              manifest.entries.count <= maximumEntryCount,
              manifest.entries == manifest.entries.sorted(by: { $0.path < $1.path }),
              Set(manifest.entries.map(\.path)).count == manifest.entries.count,
              manifest.entries.contains(where: { $0.path == "drive.json" && $0.kind == .regularFile }) else {
            throw DoryDataDriveArchiveError.invalidArchive(archive + "/archive.json")
        }
        var kinds: [String: DoryDataDriveArchiveEntryKind] = [:]
        for entry in manifest.entries {
            try validateEntry(entry, priorKinds: kinds, archive: archive)
            kinds[entry.path] = entry.kind
        }
        for entry in manifest.entries {
            let components = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            if components.count > 1 {
                var parentComponents = components
                parentComponents.removeLast()
                let parent = parentComponents.joined(separator: "/")
                guard kinds[parent] == .directory else {
                    throw DoryDataDriveArchiveError.invalidArchive(archive + "/archive.json")
                }
            }
        }
        let driveEntry = manifest.entries.first { $0.path == "drive.json" }!
        let driveData = try logicalFileData(driveEntry, archive: archive, maximumBytes: 1_024 * 1_024)
        guard let driveManifest = try? JSONDecoder().decode(DoryDataDriveManifest.self, from: driveData),
              driveManifest == manifest.sourceDrive else {
            throw DoryDataDriveArchiveError.invalidArchive(archive + "/archive.json")
        }
    }

    private static func validateEntry(
        _ entry: DoryDataDriveArchiveEntry,
        priorKinds: [String: DoryDataDriveArchiveEntryKind],
        archive: String
    ) throws {
        let components = entry.path.split(separator: "/", omittingEmptySubsequences: false)
        guard !entry.path.isEmpty,
              !entry.path.hasPrefix("/"),
              entry.path.utf8.count <= 16 * 1_024,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !entry.path.unicodeScalars.contains(where: { $0.value == 0 }),
              metadataIsValid(entry.metadata) else {
            throw DoryDataDriveArchiveError.invalidArchive(archive + "/archive.json")
        }
        switch entry.kind {
        case .directory:
            guard entry.logicalSize == nil, entry.extents == nil, entry.linkTarget == nil else {
                throw DoryDataDriveArchiveError.invalidArchive(archive + "/archive.json")
            }
        case .symbolicLink:
            guard entry.logicalSize == nil,
                  entry.extents == nil,
                  entry.linkTarget.map({ !$0.unicodeScalars.contains(where: { $0.value == 0 }) }) == true,
                  entry.linkTarget!.utf8.count <= 16 * 1_024 else {
                throw DoryDataDriveArchiveError.invalidArchive(archive + "/archive.json")
            }
        case .hardLink:
            guard entry.logicalSize == nil,
                  entry.extents == nil,
                  let target = entry.linkTarget,
                  target < entry.path,
                  priorKinds[target] == .regularFile else {
                throw DoryDataDriveArchiveError.invalidArchive(archive + "/archive.json")
            }
        case .regularFile:
            guard let logicalSize = entry.logicalSize,
                  let extents = entry.extents,
                  entry.linkTarget == nil else {
                throw DoryDataDriveArchiveError.invalidArchive(archive + "/archive.json")
            }
            var nextOffset: UInt64 = 0
            for extent in extents {
                guard extent.length > 0,
                      extent.offset >= nextOffset,
                      extent.offset <= logicalSize,
                      extent.length <= logicalSize - extent.offset else {
                    throw DoryDataDriveArchiveError.invalidArchive(archive + "/archive.json")
                }
                var chunkBytes: UInt64 = 0
                for chunk in extent.chunks {
                    guard DoryOperationJournalStore.isDigest(chunk.digest),
                          chunk.length > 0,
                          chunk.length <= UInt64(chunkSize) else {
                        throw DoryDataDriveArchiveError.invalidArchive(archive + "/archive.json")
                    }
                    chunkBytes = try checkedAdd(chunkBytes, chunk.length, archive: archive)
                }
                guard chunkBytes == extent.length else {
                    throw DoryDataDriveArchiveError.invalidArchive(archive + "/archive.json")
                }
                nextOffset = extent.offset + extent.length
            }
        }
    }

    private static func metadataIsValid(_ metadata: DoryDataDriveArchiveMetadata) -> Bool {
        metadata.mode <= 0o7777
            && metadata.modificationNanoseconds >= 0
            && metadata.modificationNanoseconds < 1_000_000_000
            && metadata.xattrs == metadata.xattrs.sorted(by: { $0.name < $1.name })
            && Set(metadata.xattrs.map(\.name)).count == metadata.xattrs.count
            && metadata.xattrs.allSatisfy {
                !$0.name.isEmpty
                    && $0.name.utf8.count <= 1_024
                    && !$0.name.unicodeScalars.contains(where: { $0.value == 0 })
                    && $0.value.count <= maximumXattrBytes
            }
            && metadata.aclText.map {
                $0.utf8.count <= maximumACLBytes
                    && !$0.unicodeScalars.contains(where: { $0.value == 0 })
            } ?? true
    }

    private static func logicalFileData(
        _ entry: DoryDataDriveArchiveEntry,
        archive: String,
        maximumBytes: Int
    ) throws -> Data {
        guard let size = entry.logicalSize,
              size <= UInt64(maximumBytes),
              let extents = entry.extents else {
            throw DoryDataDriveArchiveError.invalidArchive(archive)
        }
        var data = Data(repeating: 0, count: Int(size))
        for extent in extents {
            var offset = Int(extent.offset)
            for chunk in extent.chunks {
                let bytes = try readPrivateFile(
                    archive + "/chunks/" + chunk.digest,
                    maximumBytes: chunkSize
                )
                guard bytes.count == Int(chunk.length), digest(bytes) == chunk.digest else {
                    throw DoryDataDriveArchiveError.invalidArchive(archive)
                }
                data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
                offset += bytes.count
            }
        }
        return data
    }

    private static func scanTree(
        root: String,
        chunkDirectory: String?,
        excludedPaths: Set<String> = []
    ) throws -> (rootMetadata: DoryDataDriveArchiveMetadata, entries: [DoryDataDriveArchiveEntry]) {
        var rootBefore = stat()
        guard root.withCString({ lstat($0, &rootBefore) }) == 0,
              rootBefore.st_mode & S_IFMT == S_IFDIR else {
            throw DoryDataDriveArchiveError.invalidArchive(root)
        }
        let rootMetadata = try metadata(at: root, status: rootBefore, symbolicLink: false)
        let context = DoryDataDriveArchiveScanContext(
            chunkDirectory: chunkDirectory,
            excludedPaths: excludedPaths
        )
        try scanDirectory(root: root, relativeDirectory: "", context: context)
        var rootAfter = stat()
        guard root.withCString({ lstat($0, &rootAfter) }) == 0,
              stable(before: rootBefore, after: rootAfter) else {
            throw DoryDataDriveArchiveError.sourceChanged(root)
        }
        return (
            rootMetadata,
            try canonicalizeHardLinks(context.entries).sorted(by: { $0.path < $1.path })
        )
    }

    private static func canonicalizeHardLinks(
        _ entries: [DoryDataDriveArchiveEntry]
    ) throws -> [DoryDataDriveArchiveEntry] {
        let regularByPath = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
            entry.kind == .regularFile ? (entry.path, entry) : nil
        })
        var groups: [String: [DoryDataDriveArchiveEntry]] = [:]
        for entry in entries where entry.kind == .hardLink {
            guard let target = entry.linkTarget, regularByPath[target] != nil else {
                throw DoryDataDriveArchiveError.invalidArchive(entry.path)
            }
            groups[target, default: []].append(entry)
        }
        var result = entries.filter { entry in
            entry.kind != .hardLink && groups[entry.path] == nil
        }
        for (originalPath, links) in groups {
            let original = regularByPath[originalPath]!
            let paths = ([originalPath] + links.map(\.path)).sorted()
            let canonicalPath = paths[0]
            result.append(DoryDataDriveArchiveEntry(
                path: canonicalPath,
                kind: .regularFile,
                metadata: original.metadata,
                logicalSize: original.logicalSize,
                extents: original.extents,
                linkTarget: nil
            ))
            for path in paths.dropFirst() {
                result.append(DoryDataDriveArchiveEntry(
                    path: path,
                    kind: .hardLink,
                    metadata: original.metadata,
                    logicalSize: nil,
                    extents: nil,
                    linkTarget: canonicalPath
                ))
            }
        }
        return result
    }

    private static func scanDirectory(
        root: String,
        relativeDirectory: String,
        context: DoryDataDriveArchiveScanContext
    ) throws {
        let directory = relativeDirectory.isEmpty ? root : root + "/" + relativeDirectory
        var before = stat()
        guard directory.withCString({ lstat($0, &before) }) == 0,
              before.st_mode & S_IFMT == S_IFDIR else {
            throw DoryDataDriveArchiveError.sourceChanged(directory)
        }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory).sorted()
        } catch {
            throw DoryDataDriveArchiveError.filesystem("list Dory data at \(directory): \(error)")
        }
        for name in names {
            if relativeDirectory.isEmpty, name == "drive.lock" { continue }
            guard name != ".", name != "..", !name.contains("/"),
                  !name.unicodeScalars.contains(where: { $0.value == 0 }) else {
                throw DoryDataDriveArchiveError.unsupportedEntry(directory + "/" + name)
            }
            let relative = relativeDirectory.isEmpty ? name : relativeDirectory + "/" + name
            if context.excludedPaths.contains(relative) { continue }
            try scanEntry(root: root, relative: relative, context: context)
            guard context.entries.count <= maximumEntryCount else {
                throw DoryDataDriveArchiveError.unsupportedEntry(root)
            }
        }
        var after = stat()
        guard directory.withCString({ lstat($0, &after) }) == 0,
              stable(before: before, after: after) else {
            throw DoryDataDriveArchiveError.sourceChanged(directory)
        }
    }

    private static func scanEntry(
        root: String,
        relative: String,
        context: DoryDataDriveArchiveScanContext
    ) throws {
        let path = root + "/" + relative
        var status = stat()
        guard path.withCString({ lstat($0, &status) }) == 0 else {
            throw DoryDataDriveArchiveError.sourceChanged(path)
        }
        let type = status.st_mode & S_IFMT
        let itemMetadata = try metadata(at: path, status: status, symbolicLink: type == S_IFLNK)
        switch type {
        case S_IFDIR:
            context.entries.append(DoryDataDriveArchiveEntry(
                path: relative,
                kind: .directory,
                metadata: itemMetadata,
                logicalSize: nil,
                extents: nil,
                linkTarget: nil
            ))
            try scanDirectory(root: root, relativeDirectory: relative, context: context)
        case S_IFREG:
            let key = "\(status.st_dev):\(status.st_ino)"
            if status.st_nlink > 1, let first = context.hardLinks[key] {
                guard first.metadata == itemMetadata else {
                    throw DoryDataDriveArchiveError.sourceChanged(path)
                }
                context.entries.append(DoryDataDriveArchiveEntry(
                    path: relative,
                    kind: .hardLink,
                    metadata: itemMetadata,
                    logicalSize: nil,
                    extents: nil,
                    linkTarget: first.path
                ))
            } else {
                let content = try scanRegularFile(
                    at: path,
                    expected: status,
                    chunkDirectory: context.chunkDirectory
                )
                context.entries.append(DoryDataDriveArchiveEntry(
                    path: relative,
                    kind: .regularFile,
                    metadata: itemMetadata,
                    logicalSize: content.logicalSize,
                    extents: content.extents,
                    linkTarget: nil
                ))
                if status.st_nlink > 1 {
                    context.hardLinks[key] = (relative, itemMetadata)
                }
            }
        case S_IFLNK:
            let target = try readLink(path)
            context.entries.append(DoryDataDriveArchiveEntry(
                path: relative,
                kind: .symbolicLink,
                metadata: itemMetadata,
                logicalSize: nil,
                extents: nil,
                linkTarget: target
            ))
        default:
            throw DoryDataDriveArchiveError.unsupportedEntry(path)
        }
    }

    private static func scanRegularFile(
        at path: String,
        expected: stat,
        chunkDirectory: String?
    ) throws -> (logicalSize: UInt64, extents: [DoryDataDriveArchiveExtent]) {
        guard expected.st_size >= 0 else {
            throw DoryDataDriveArchiveError.unsupportedEntry(path)
        }
        let descriptor = path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw filesystem("open Dory data at \(path)") }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, stable(before: expected, after: opened) else {
            throw DoryDataDriveArchiveError.sourceChanged(path)
        }
        let logicalSize = UInt64(expected.st_size)
        let ranges = try dataRanges(descriptor: descriptor, size: logicalSize, path: path)
        var extents: [DoryDataDriveArchiveExtent] = []
        for range in ranges {
            var chunks: [DoryDataDriveArchiveChunk] = []
            var offset = range.offset
            let end = range.offset + range.length
            while offset < end {
                let count = Int(min(UInt64(chunkSize), end - offset))
                let data = try preadExactly(
                    descriptor: descriptor,
                    offset: offset,
                    count: count,
                    path: path
                )
                let hash = digest(data)
                if let chunkDirectory {
                    try storeChunk(data, digest: hash, directory: chunkDirectory)
                }
                chunks.append(DoryDataDriveArchiveChunk(digest: hash, length: UInt64(count)))
                offset += UInt64(count)
            }
            extents.append(DoryDataDriveArchiveExtent(
                offset: range.offset,
                length: range.length,
                chunks: chunks
            ))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, stable(before: opened, after: after) else {
            throw DoryDataDriveArchiveError.sourceChanged(path)
        }
        return (logicalSize, extents)
    }

    private static func dataRanges(
        descriptor: Int32,
        size: UInt64,
        path: String
    ) throws -> [(offset: UInt64, length: UInt64)] {
        guard size > 0 else { return [] }
        var result: [(UInt64, UInt64)] = []
        var cursor: UInt64 = 0
        while cursor < size {
            errno = 0
            let data = lseek(descriptor, off_t(cursor), SEEK_DATA)
            if data < 0, errno == ENXIO { break }
            if data < 0, errno == EINVAL || errno == ENOTSUP {
                return [(0, size)]
            }
            guard data >= 0 else { throw filesystem("discover sparse data at \(path)") }
            errno = 0
            let hole = lseek(descriptor, data, SEEK_HOLE)
            if hole < 0, errno == EINVAL || errno == ENOTSUP {
                return [(0, size)]
            }
            guard hole > data else { throw filesystem("discover sparse hole at \(path)") }
            let start = UInt64(data)
            let end = min(UInt64(hole), size)
            guard start < end else { break }
            result.append((start, end - start))
            cursor = end
        }
        return result
    }

    private static func metadata(
        at path: String,
        status: stat,
        symbolicLink: Bool
    ) throws -> DoryDataDriveArchiveMetadata {
        DoryDataDriveArchiveMetadata(
            mode: UInt32(status.st_mode & 0o7777),
            uid: status.st_uid,
            gid: status.st_gid,
            modificationSeconds: Int64(status.st_mtimespec.tv_sec),
            modificationNanoseconds: Int32(status.st_mtimespec.tv_nsec),
            xattrs: try readXattrs(at: path, symbolicLink: symbolicLink),
            aclText: try readACL(at: path)
        )
    }

    private static func readXattrs(
        at path: String,
        symbolicLink: Bool
    ) throws -> [DoryDataDriveArchiveXattr] {
        let options = symbolicLink ? XATTR_NOFOLLOW : 0
        let size = listxattr(path, nil, 0, options)
        guard size >= 0 else { throw filesystem("list extended attributes at \(path)") }
        guard size > 0 else { return [] }
        var names = [CChar](repeating: 0, count: size)
        let read = listxattr(path, &names, size, options)
        guard read == size else { throw filesystem("read extended attribute names at \(path)") }
        return try names.split(separator: 0).compactMap { rawName in
            let name = String(cString: Array(rawName) + [0])
            if isVolatileSystemXattr(name) { return nil }
            let valueSize = getxattr(path, name, nil, 0, 0, options)
            guard valueSize >= 0, valueSize <= maximumXattrBytes else {
                throw DoryDataDriveArchiveError.unsupportedEntry(path + " xattr " + name)
            }
            var value = Data(count: valueSize)
            let valueRead = value.withUnsafeMutableBytes { bytes in
                getxattr(path, name, bytes.baseAddress, valueSize, 0, options)
            }
            guard valueRead == valueSize else {
                throw filesystem("read extended attribute \(name) at \(path)")
            }
            return DoryDataDriveArchiveXattr(name: name, value: value)
        }.sorted(by: { $0.name < $1.name })
    }

    private static func readACL(at path: String) throws -> String? {
        errno = 0
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else {
            if errno == 0 || errno == ENOENT { return nil }
            throw filesystem("read ACL at \(path)")
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        let result = acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry)
        if result == 0 { return nil }
        guard result == 1 else { throw filesystem("inspect ACL at \(path)") }
        var length: ssize_t = 0
        guard let text = acl_to_text(acl, &length), length >= 0, length <= maximumACLBytes else {
            throw DoryDataDriveArchiveError.unsupportedEntry(path + " ACL")
        }
        defer { acl_free(UnsafeMutableRawPointer(text)) }
        return String(cString: text)
    }

    private static func applyMetadata(
        _ metadata: DoryDataDriveArchiveMetadata,
        to path: String,
        symbolicLink: Bool
    ) throws {
        if symbolicLink {
            guard Darwin.lchown(path, metadata.uid, metadata.gid) == 0 else {
                throw filesystem("restore symbolic-link ownership at \(path)")
            }
            try removeUnexpectedXattrs(
                at: path,
                symbolicLink: true,
                keeping: Set(metadata.xattrs.map(\.name))
            )
            for xattr in metadata.xattrs {
                let result = xattr.value.withUnsafeBytes { bytes in
                    setxattr(path, xattr.name, bytes.baseAddress, xattr.value.count, 0, XATTR_NOFOLLOW)
                }
                guard result == 0 else { throw filesystem("restore xattr \(xattr.name) at \(path)") }
            }
            // macOS does not support setting an empty extended ACL on a symbolic link
            // (ENOTSUP). A non-empty link ACL is still rejected at restore rather than lost.
            if let aclText = metadata.aclText {
                try applyACL(aclText, to: path)
            }
            var times = [
                timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
                timespec(
                    tv_sec: time_t(metadata.modificationSeconds),
                    tv_nsec: Int(metadata.modificationNanoseconds)
                ),
            ]
            guard utimensat(AT_FDCWD, path, &times, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw filesystem("restore symbolic-link time at \(path)")
            }
            return
        }

        let descriptor = path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw filesystem("open restored metadata target at \(path)") }
        defer { Darwin.close(descriptor) }
        guard fchown(descriptor, metadata.uid, metadata.gid) == 0,
              fchmod(descriptor, mode_t(metadata.mode)) == 0 else {
            throw filesystem("restore ownership or mode at \(path)")
        }
        try removeUnexpectedXattrs(
            descriptor: descriptor,
            path: path,
            keeping: Set(metadata.xattrs.map(\.name))
        )
        for xattr in metadata.xattrs {
            let result = xattr.value.withUnsafeBytes { bytes in
                fsetxattr(descriptor, xattr.name, bytes.baseAddress, xattr.value.count, 0, 0)
            }
            guard result == 0 else { throw filesystem("restore xattr \(xattr.name) at \(path)") }
        }
        try applyACL(metadata.aclText, to: path)
        let times = [
            timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
            timespec(
                tv_sec: time_t(metadata.modificationSeconds),
                tv_nsec: Int(metadata.modificationNanoseconds)
            ),
        ]
        let result = times.withUnsafeBufferPointer { buffer in
            futimens(descriptor, buffer.baseAddress)
        }
        guard result == 0 else { throw filesystem("restore modification time at \(path)") }
    }

    private static func removeUnexpectedXattrs(
        descriptor: Int32,
        path: String,
        keeping expected: Set<String>
    ) throws {
        let size = flistxattr(descriptor, nil, 0, 0)
        guard size >= 0 else { throw filesystem("list restored xattrs at \(path)") }
        guard size > 0 else { return }
        var names = [CChar](repeating: 0, count: size)
        guard flistxattr(descriptor, &names, size, 0) == size else {
            throw filesystem("read restored xattr names at \(path)")
        }
        for rawName in names.split(separator: 0) {
            let name = String(cString: Array(rawName) + [0])
            if !expected.contains(name), !isVolatileSystemXattr(name),
               fremovexattr(descriptor, name, 0) != 0 {
                throw filesystem("remove unexpected xattr \(name) at \(path)")
            }
        }
    }

    private static func removeUnexpectedXattrs(
        at path: String,
        symbolicLink: Bool,
        keeping expected: Set<String>
    ) throws {
        let options = symbolicLink ? XATTR_NOFOLLOW : 0
        let size = listxattr(path, nil, 0, options)
        guard size >= 0 else { throw filesystem("list restored xattrs at \(path)") }
        guard size > 0 else { return }
        var names = [CChar](repeating: 0, count: size)
        guard listxattr(path, &names, size, options) == size else {
            throw filesystem("read restored xattr names at \(path)")
        }
        for rawName in names.split(separator: 0) {
            let name = String(cString: Array(rawName) + [0])
            if !expected.contains(name), !isVolatileSystemXattr(name),
               removexattr(path, name, options) != 0 {
                throw filesystem("remove unexpected xattr \(name) at \(path)")
            }
        }
    }

    private static func applyACL(_ text: String?, to path: String) throws {
        let acl: acl_t?
        if let text {
            acl = acl_from_text(text)
        } else {
            acl = acl_init(0)
        }
        guard let acl else { throw filesystem("prepare restored ACL at \(path)") }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_set_link_np(path, ACL_TYPE_EXTENDED, acl) == 0 else {
            throw filesystem("restore ACL at \(path)")
        }
    }

    private static func isVolatileSystemXattr(_ name: String) -> Bool {
        // macOS may attach this process-provenance record after a file descriptor closes, even
        // when a restore removed it moments earlier. It is host execution history, not user data;
        // quarantine, Finder metadata, resource forks, and every other xattr remain exact.
        name == "com.apple.provenance"
    }

    private static func applyDirectoryMetadata(
        _ entries: [DoryDataDriveArchiveEntry],
        rootMetadata: DoryDataDriveArchiveMetadata,
        root: String
    ) throws {
        let directories = entries.filter { $0.kind == .directory }.sorted {
            let leftDepth = $0.path.split(separator: "/").count
            let rightDepth = $1.path.split(separator: "/").count
            return leftDepth == rightDepth ? $0.path > $1.path : leftDepth > rightDepth
        }
        for directory in directories {
            let path = root + "/" + directory.path
            try applyMetadata(directory.metadata, to: path, symbolicLink: false)
            try removeUnexpectedXattrs(
                at: path,
                symbolicLink: false,
                keeping: Set(directory.metadata.xattrs.map(\.name))
            )
        }
        try applyMetadata(rootMetadata, to: root, symbolicLink: false)
        try removeUnexpectedXattrs(
            at: root,
            symbolicLink: false,
            keeping: Set(rootMetadata.xattrs.map(\.name))
        )
    }

    private static func storeChunk(_ data: Data, digest: String, directory: String) throws {
        let path = directory + "/" + digest
        if pathEntryExists(path) {
            let existing = try readPrivateFile(path, maximumBytes: chunkSize)
            guard existing == data else { throw DoryDataDriveArchiveError.invalidArchive(path) }
            return
        }
        try writePrivateFile(data, to: path)
    }

    private static func writeRestoreOwner(
        operationID: UUID,
        archiveManifestDigest: String,
        targetPath: String,
        root: String
    ) throws {
        let owner = DoryDataDriveRestoreOwner(
            operationID: operationID,
            archiveManifestDigest: archiveManifestDigest,
            targetPath: targetPath
        )
        try writePrivateFile(
            try encoded(owner),
            to: root + "/" + DoryDataDriveRestoreOwner.fileName
        )
    }

    private static func readLink(_ path: String) throws -> String {
        var buffer = [CChar](repeating: 0, count: 16 * 1_024 + 1)
        let count = path.withCString { Darwin.readlink($0, &buffer, buffer.count - 1) }
        guard count >= 0, count < buffer.count - 1 else {
            throw DoryDataDriveArchiveError.unsupportedEntry(path)
        }
        let bytes = buffer.prefix(count).map(UInt8.init(bitPattern:))
        guard let target = String(bytes: bytes, encoding: .utf8) else {
            throw DoryDataDriveArchiveError.unsupportedEntry(path)
        }
        return target
    }

    private static func stable(before: stat, after: stat) -> Bool {
        before.st_dev == after.st_dev
            && before.st_ino == after.st_ino
            && before.st_mode == after.st_mode
            && before.st_nlink == after.st_nlink
            && before.st_uid == after.st_uid
            && before.st_gid == after.st_gid
            && before.st_size == after.st_size
            && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
            && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
            && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec
            && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    }

    private static func estimatedAllocatedBytes(
        at root: String,
        excludingRootLock: Bool
    ) throws -> UInt64 {
        var total: UInt64 = 0
        func visit(_ path: String, rootLevel: Bool) throws {
            var status = stat()
            guard path.withCString({ lstat($0, &status) }) == 0 else {
                throw DoryDataDriveArchiveError.sourceChanged(path)
            }
            if !(rootLevel && excludingRootLock && URL(fileURLWithPath: path).lastPathComponent == "drive.lock") {
                let blocks = max(Int64(0), Int64(status.st_blocks))
                total = try checkedAdd(total, UInt64(blocks) * 512, archive: path)
            }
            guard status.st_mode & S_IFMT == S_IFDIR else { return }
            let names = try FileManager.default.contentsOfDirectory(atPath: path)
            for name in names where !(rootLevel && excludingRootLock && name == "drive.lock") {
                try visit(path + "/" + name, rootLevel: false)
            }
        }
        var rootStatus = stat()
        guard root.withCString({ lstat($0, &rootStatus) }) == 0 else {
            throw DoryDataDriveArchiveError.sourceChanged(root)
        }
        let rootBlocks = max(Int64(0), Int64(rootStatus.st_blocks))
        total = UInt64(rootBlocks) * 512
        for name in try FileManager.default.contentsOfDirectory(atPath: root) where name != "drive.lock" {
            try visit(root + "/" + name, rootLevel: false)
        }
        return total
    }

    private static func requireCapacity(at path: String, payloadBytes: UInt64) throws {
        var filesystemStatus = statfs()
        guard statfs(path, &filesystemStatus) == 0 else {
            throw filesystem("read free space at \(path)")
        }
        let available = UInt64(filesystemStatus.f_bavail) * UInt64(filesystemStatus.f_bsize)
        let tenPercent = payloadBytes / 10
        let required = try checkedAdd(
            payloadBytes,
            max(capacitySafetyBytes, tenPercent),
            archive: path
        )
        guard available >= required else {
            throw DoryDataDriveArchiveError.insufficientSpace(required: required, available: available)
        }
    }

    private static func requireWritableLocalAPFS(_ path: String) throws {
        var status = statfs()
        guard statfs(path, &status) == 0 else { throw filesystem("inspect backup filesystem at \(path)") }
        let type = withUnsafePointer(to: &status.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSNAMELEN)) { String(cString: $0) }
        }
        guard type == "apfs", status.f_flags & UInt32(MNT_LOCAL) != 0,
              status.f_flags & UInt32(MNT_RDONLY) == 0 else {
            throw DoryDataDriveArchiveError.invalidDestination(path)
        }
    }

    private static func canonicalArchivePath(_ requested: String) throws -> String {
        guard requested.hasPrefix("/"),
              requested.hasSuffix(".dorybackup"),
              !requested.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw DoryDataDriveArchiveError.invalidDestination(requested)
        }
        do {
            let canonical = try DoryDataDrive.canonicalPath(requested)
            guard canonical.hasSuffix(".dorybackup") else {
                throw DoryDataDriveArchiveError.invalidDestination(canonical)
            }
            return canonical
        } catch let error as DoryDataDriveArchiveError {
            throw error
        } catch {
            throw DoryDataDriveArchiveError.invalidDestination(requested)
        }
    }

    private static func isSameOrDescendant(_ path: String, of ancestor: String) -> Bool {
        path == ancestor || path.hasPrefix(ancestor + "/")
    }

    static func operationPartialPath(destination: String, operationID: UUID) -> String {
        let parent = URL(fileURLWithPath: destination).deletingLastPathComponent().path
        return parent + "/." + URL(fileURLWithPath: destination).lastPathComponent
            + "." + operationID.uuidString.lowercased() + ".partial"
    }

    private static func publishExclusive(_ partial: String, destination: String) throws {
        guard renamex_np(partial, destination, UInt32(RENAME_EXCL)) == 0 else {
            throw filesystem("publish Dory data at \(destination)")
        }
    }

    private static func createPrivateDirectory(_ path: String) throws {
        guard path.withCString({ Darwin.mkdir($0, mode_t(0o700)) }) == 0 else {
            throw filesystem("create private Dory data directory at \(path)")
        }
        try validatePrivateDirectory(path)
    }

    private static func validatePrivateDirectory(_ path: String) throws {
        var status = stat()
        guard path.withCString({ lstat($0, &status) }) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == getuid(),
              status.st_mode & 0o077 == 0 else {
            throw DoryDataDriveArchiveError.invalidArchive(path)
        }
    }

    private static func writePrivateFile(_ data: Data, to path: String) throws {
        let descriptor = path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw filesystem("create private Dory data file at \(path)") }
        var complete = false
        defer {
            Darwin.close(descriptor)
            if !complete { _ = Darwin.unlink(path) }
        }
        try writeAll(data, descriptor: descriptor, path: path)
        guard Darwin.fsync(descriptor) == 0 else { throw filesystem("sync Dory data file at \(path)") }
        complete = true
        try syncDirectory(URL(fileURLWithPath: path).deletingLastPathComponent().path)
    }

    private static func readPrivateFile(_ path: String, maximumBytes: Int) throws -> Data {
        let descriptor = path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw DoryDataDriveArchiveError.invalidArchive(path) }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(),
              status.st_mode & 0o077 == 0,
              status.st_nlink == 1,
              status.st_size >= 0,
              status.st_size <= maximumBytes else {
            throw DoryDataDriveArchiveError.invalidArchive(path)
        }
        var result = Data()
        result.reserveCapacity(Int(status.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw filesystem("read Dory data file at \(path)") }
            if count == 0 { break }
            guard result.count <= maximumBytes - count else {
                throw DoryDataDriveArchiveError.invalidArchive(path)
            }
            result.append(buffer, count: count)
        }
        return result
    }

    private static func preadExactly(
        descriptor: Int32,
        offset: UInt64,
        count: Int,
        path: String
    ) throws -> Data {
        var result = Data(count: count)
        var completed = 0
        while completed < count {
            let readCount = result.withUnsafeMutableBytes { bytes in
                Darwin.pread(
                    descriptor,
                    bytes.baseAddress!.advanced(by: completed),
                    count - completed,
                    off_t(offset + UInt64(completed))
                )
            }
            if readCount < 0, errno == EINTR { continue }
            guard readCount > 0 else { throw DoryDataDriveArchiveError.sourceChanged(path) }
            completed += readCount
        }
        return result
    }

    private static func pwriteAll(
        _ data: Data,
        descriptor: Int32,
        offset: UInt64,
        path: String
    ) throws {
        try data.withUnsafeBytes { bytes in
            var completed = 0
            while completed < bytes.count {
                let count = Darwin.pwrite(
                    descriptor,
                    bytes.baseAddress!.advanced(by: completed),
                    bytes.count - completed,
                    off_t(offset + UInt64(completed))
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw filesystem("write restored sparse data at \(path)") }
                completed += count
            }
        }
    }

    private static func writeAll(_ data: Data, descriptor: Int32, path: String) throws {
        try data.withUnsafeBytes { bytes in
            var completed = 0
            while completed < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: completed),
                    bytes.count - completed
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw filesystem("write Dory data at \(path)") }
                completed += count
            }
        }
    }

    private static func syncTreeDirectories(
        root: String,
        entries: [DoryDataDriveArchiveEntry]
    ) throws {
        let directories = entries.filter { $0.kind == .directory }.sorted {
            $0.path.split(separator: "/").count > $1.path.split(separator: "/").count
        }
        for directory in directories {
            try syncDirectory(root + "/" + directory.path)
        }
        try syncDirectory(root)
    }

    private static func syncDirectory(_ path: String) throws {
        let descriptor = path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw filesystem("open Dory directory for sync at \(path)") }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw filesystem("sync Dory directory at \(path)") }
    }

    private static func pathEntryExists(_ path: String) -> Bool {
        var status = stat()
        return path.withCString { lstat($0, &status) } == 0
    }

    private static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value) + Data("\n".utf8)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func checkedAdd(
        _ lhs: UInt64,
        _ rhs: UInt64,
        archive: String
    ) throws -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw DoryDataDriveArchiveError.invalidArchive(archive) }
        return sum
    }

    private static func filesystem(_ action: String) -> DoryDataDriveArchiveError {
        .filesystem("\(action): errno \(errno)")
    }
}
