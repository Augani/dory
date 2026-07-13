import Darwin
import Foundation

public enum DoryDataDriveSelectionError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidRecord(String)
    case uninitializedDrive(String)
    case selectedDriveUnavailable(path: String, id: UUID)
    case selectedDriveMismatch(expected: UUID, actual: UUID?, path: String)
    case filesystem(String)

    public var description: String {
        switch self {
        case let .invalidRecord(path):
            return "Dory selected-drive record is invalid: \(path)"
        case let .uninitializedDrive(path):
            return "cannot bind uninitialized Dory data drive at \(path)"
        case let .selectedDriveUnavailable(path, id):
            return "selected Dory data drive \(id.uuidString.lowercased()) is unavailable at \(path); "
                + "refusing to create a replacement"
        case let .selectedDriveMismatch(expected, actual, path):
            return "selected Dory data-drive UUID mismatch at \(path): expected "
                + "\(expected.uuidString.lowercased()), found "
                + "\(actual?.uuidString.lowercased() ?? "no initialized drive")"
        case let .filesystem(message):
            return message
        }
    }
}

public struct DoryDataDriveSelection: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let driveID: UUID
    public let canonicalPath: String
    public let volumeUUID: UUID?
    public let bookmark: Data?
    public let selectedAt: String

    fileprivate init(
        driveID: UUID,
        canonicalPath: String,
        volumeUUID: UUID?,
        bookmark: Data?,
        selectedAt: Date = Date()
    ) {
        schemaVersion = Self.schemaVersion
        self.driveID = driveID
        self.canonicalPath = canonicalPath
        self.volumeUUID = volumeUUID
        self.bookmark = bookmark
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.selectedAt = formatter.string(from: selectedAt)
    }

    fileprivate var isStructurallyValid: Bool {
        guard schemaVersion == Self.schemaVersion,
              canonicalPath.hasPrefix("/"),
              canonicalPath.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else {
            return false
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: selectedAt) != nil
    }
}

/// Durable authority for the one drive Dory may attach automatically.
///
/// This record deliberately lives beside the default drive in Application Support, not in the
/// replaceable ~/.dory runtime cache. The bookmark can rediscover a mounted APFS volume after a
/// rename; the UUIDs prevent a reusable path or stale bookmark from selecting another drive.
public struct DoryDataDriveSelectionStore: Sendable, Equatable {
    public let home: String
    public let path: String

    public init(home: String = DoryDataDrive.processHome()) throws {
        let canonicalHome = try DoryDataDrive.canonicalPath(home)
        self.home = canonicalHome
        path = canonicalHome + "/Library/Application Support/Dory/data-drive-selection.json"
    }

    public func read(fileManager: FileManager = .default) throws -> DoryDataDriveSelection? {
        guard fileManager.fileExists(atPath: path) else { return nil }
        var status = stat()
        guard path.withCString({ lstat($0, &status) }) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(),
              status.st_mode & 0o077 == 0,
              status.st_nlink == 1,
              let data = fileManager.contents(atPath: path),
              let selection = try? JSONDecoder().decode(DoryDataDriveSelection.self, from: data),
              selection.isStructurallyValid,
              (try? DoryDataDrive(home: home, overrideRoot: selection.canonicalPath)) != nil else {
            throw DoryDataDriveSelectionError.invalidRecord(path)
        }
        return selection
    }

    public func selectedPath(fileManager: FileManager = .default) throws -> String? {
        guard let selection = try read(fileManager: fileManager) else { return nil }
        guard let bookmark = selection.bookmark else { return selection.canonicalPath }
        var stale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ), let drive = try? DoryDataDrive(home: home, overrideRoot: resolved.path) else {
            return selection.canonicalPath
        }
        return drive.root
    }

    /// Creates the first selection, or verifies the already-selected identity without ever
    /// creating a replacement at a remembered path. A new path is accepted automatically only
    /// when it contains the same drive UUID (for example after an external-volume rename).
    public func prepareSelection(
        requestedRoot: String? = nil,
        fileManager: FileManager = .default
    ) throws -> DoryDataDrive {
        let existing = try read(fileManager: fileManager)
        let selectedRoot = try requestedRoot ?? selectedPath(fileManager: fileManager)
        let drive = try DoryDataDrive(home: home, overrideRoot: selectedRoot)

        guard let existing else {
            try drive.prepare(fileManager: fileManager)
            try writeSelection(for: drive, fileManager: fileManager)
            return drive
        }
        return try verify(
            drive,
            against: existing,
            recordResolvedPath: true,
            fileManager: fileManager
        )
    }

    /// Verifies and records an already-existing drive. Used when recovering ownership metadata for
    /// a live VM; unlike prepareSelection it cannot initialize an absent bundle.
    public func bindExistingSelection(
        requestedRoot: String,
        fileManager: FileManager = .default
    ) throws -> DoryDataDrive {
        let drive = try DoryDataDrive(home: home, overrideRoot: requestedRoot)
        if let existing = try read(fileManager: fileManager) {
            return try verify(
                drive,
                against: existing,
                recordResolvedPath: true,
                fileManager: fileManager
            )
        }
        guard try drive.inspect(fileManager: fileManager) == .ready else {
            throw DoryDataDriveSelectionError.uninitializedDrive(drive.root)
        }
        try writeSelection(for: drive, fileManager: fileManager)
        return drive
    }

    private func verify(
        _ drive: DoryDataDrive,
        against selection: DoryDataDriveSelection,
        recordResolvedPath: Bool,
        fileManager: FileManager
    ) throws -> DoryDataDrive {
        guard try drive.inspect(fileManager: fileManager) == .ready else {
            throw DoryDataDriveSelectionError.selectedDriveUnavailable(
                path: drive.root,
                id: selection.driveID
            )
        }
        let manifest = try drive.readManifest(fileManager: fileManager)
        guard manifest.id == selection.driveID,
              manifest.volume?.uuid == selection.volumeUUID else {
            throw DoryDataDriveSelectionError.selectedDriveMismatch(
                expected: selection.driveID,
                actual: manifest.id,
                path: drive.root
            )
        }
        try drive.prepare(fileManager: fileManager)
        if recordResolvedPath, drive.root != selection.canonicalPath {
            try writeSelection(for: drive, fileManager: fileManager)
        }
        return drive
    }

    private func writeSelection(
        for drive: DoryDataDrive,
        fileManager: FileManager
    ) throws {
        let manifest = try drive.readManifest(fileManager: fileManager)
        let bookmark: Data?
        if manifest.volume != nil {
            do {
                bookmark = try URL(fileURLWithPath: drive.root).bookmarkData(
                    options: [.minimalBookmark],
                    includingResourceValuesForKeys: [
                        .volumeUUIDStringKey,
                        .volumeNameKey,
                    ],
                    relativeTo: nil
                )
            } catch {
                throw DoryDataDriveSelectionError.filesystem(
                    "create Dory data-drive bookmark for \(drive.root): \(error)"
                )
            }
        } else {
            bookmark = nil
        }
        let selection = DoryDataDriveSelection(
            driveID: manifest.id,
            canonicalPath: drive.root,
            volumeUUID: manifest.volume?.uuid,
            bookmark: bookmark
        )
        do {
            let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
            try fileManager.createDirectory(atPath: parent, withIntermediateDirectories: true)
            var parentStatus = stat()
            guard parent.withCString({ lstat($0, &parentStatus) }) == 0,
                  parentStatus.st_mode & S_IFMT == S_IFDIR,
                  parentStatus.st_uid == getuid() else {
                throw DoryDataDriveSelectionError.invalidRecord(path)
            }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(selection) + Data("\n".utf8)
            try Self.publish(data, to: path, parent: parent, fileManager: fileManager)
            try Self.sync(parent)
        } catch let error as DoryDataDriveSelectionError {
            throw error
        } catch {
            throw DoryDataDriveSelectionError.filesystem(
                "write Dory selected-drive record at \(path): \(error)"
            )
        }
    }

    /// Publishes a fully written, private record with one same-directory rename. This avoids the
    /// brief default-permission window of Foundation's convenience atomic writer and never follows
    /// a final-component symlink.
    private static func publish(
        _ data: Data,
        to destination: String,
        parent: String,
        fileManager: FileManager
    ) throws {
        let temporary = parent + "/.data-drive-selection.\(UUID().uuidString).partial"
        let descriptor = temporary.withCString {
            Darwin.open(
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw DoryDataDriveSelectionError.filesystem(
                "create Dory selected-drive state at \(temporary): errno \(errno)"
            )
        }
        var published = false
        defer {
            Darwin.close(descriptor)
            if !published { try? fileManager.removeItem(atPath: temporary) }
        }

        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if result < 0, errno == EINTR { continue }
                guard result > 0 else {
                    throw DoryDataDriveSelectionError.filesystem(
                        "write Dory selected-drive state at \(temporary): errno \(errno)"
                    )
                }
                offset += result
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw DoryDataDriveSelectionError.filesystem(
                "sync Dory selected-drive state at \(temporary): errno \(errno)"
            )
        }
        guard Darwin.rename(temporary, destination) == 0 else {
            throw DoryDataDriveSelectionError.filesystem(
                "publish Dory selected-drive state at \(destination): errno \(errno)"
            )
        }
        published = true
    }

    private static func sync(_ path: String) throws {
        let descriptor = path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else {
            throw DoryDataDriveSelectionError.filesystem(
                "open Dory selected-drive state for sync at \(path): errno \(errno)"
            )
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw DoryDataDriveSelectionError.filesystem(
                "sync Dory selected-drive state at \(path): errno \(errno)"
            )
        }
    }
}
