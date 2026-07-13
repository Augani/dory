import Darwin
import Foundation

public enum DoryDataDriveError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidRoot(String)
    case unsafeRuntimeRoot(String)
    case protectedLocation(String)
    case unsupportedLocation(String)
    case invalidManifest(String)
    case unavailableVolume(String)
    case unsupportedVolume(String)
    case populatedUnmarkedBundle(String)
    case filesystem(String)

    public var description: String {
        switch self {
        case let .invalidRoot(path):
            "Dory data drive must be an absolute .dorydrive bundle: \(path)"
        case let .unsafeRuntimeRoot(path):
            "Dory data drive cannot live inside transient ~/.dory runtime state: \(path)"
        case let .protectedLocation(path):
            "Dory data drive cannot use a macOS privacy-protected home folder: \(path)"
        case let .unsupportedLocation(path):
            "Dory data drive must use Dory Application Support or mounted local APFS storage: \(path)"
        case let .invalidManifest(path):
            "Dory data drive has an invalid or incompatible manifest: \(path)"
        case let .unavailableVolume(path):
            "Dory data drive volume is not mounted: \(path)"
        case let .unsupportedVolume(path):
            "Dory data drive volume must be local APFS storage: \(path)"
        case let .populatedUnmarkedBundle(path):
            "refusing to adopt a populated unmarked data-drive bundle: \(path)"
        case let .filesystem(message):
            message
        }
    }
}

public struct DoryDataDriveManifest: Codable, Sendable, Equatable {
    public let kind: String
    public let schemaVersion: Int
    public let id: UUID
    public let product: String
    public let createdAt: String
    public let volume: DoryDataDriveVolumeIdentity?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        volume: DoryDataDriveVolumeIdentity? = nil
    ) {
        kind = DoryDataDrive.manifestKind
        schemaVersion = DoryDataDrive.schemaVersion
        self.id = id
        product = "Dory"
        self.createdAt = Self.timestampFormatter.string(from: createdAt)
        self.volume = volume
    }

    fileprivate var isValid: Bool {
        kind == DoryDataDrive.manifestKind
            && schemaVersion == DoryDataDrive.schemaVersion
            && product == "Dory"
            && Self.timestampFormatter.date(from: createdAt) != nil
            && (volume?.isValid ?? true)
    }

    private static var timestampFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

public struct DoryDataDriveVolumeIdentity: Codable, Sendable, Equatable {
    public let uuid: UUID
    public let nameAtCreation: String
    public let filesystem: String

    public init(uuid: UUID, nameAtCreation: String, filesystem: String = "apfs") {
        self.uuid = uuid
        self.nameAtCreation = nameAtCreation
        self.filesystem = filesystem
    }

    fileprivate var isValid: Bool {
        !nameAtCreation.isEmpty && filesystem == "apfs"
    }
}

/// Canonical durable storage for Dory-owned workload data.
///
/// Runtime sockets, logs, prepared kernels, and replaceable root filesystems stay under `~/.dory`.
/// User-owned Docker state, machine disks, snapshots, and backups live in this bundle so they have
/// one discoverable, relocatable, backup-friendly identity on the Mac.
public struct DoryDataDrive: Sendable, Equatable {
    public static let bundleName = "Dory.dorydrive"
    public static let manifestKind = "dev.dory.data-drive"
    public static let schemaVersion = 2
    private static let developmentSchemaVersion = 1

    public let home: String
    public let root: String

    public init(home: String = DoryDataDrive.processHome(), overrideRoot: String? = nil) throws {
        guard home.hasPrefix("/"), !Self.hasControlCharacter(home) else {
            throw DoryDataDriveError.invalidRoot(home)
        }
        let standardizedHome = try Self.canonicalPath(home)
        let candidate = overrideRoot?.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = candidate.flatMap { $0.isEmpty ? nil : $0 }
            ?? Self.defaultRoot(home: standardizedHome)
        guard selected.hasPrefix("/"), !Self.hasControlCharacter(selected) else {
            throw DoryDataDriveError.invalidRoot(selected)
        }
        let url = URL(fileURLWithPath: try Self.canonicalPath(selected))
        guard url.path.hasPrefix("/"), url.lastPathComponent.hasSuffix(".dorydrive"), url.path != "/" else {
            throw DoryDataDriveError.invalidRoot(selected)
        }
        let runtimeRoot = URL(fileURLWithPath: standardizedHome + "/.dory").standardizedFileURL.path
        guard url.path != runtimeRoot, !url.path.hasPrefix(runtimeRoot + "/") else {
            throw DoryDataDriveError.unsafeRuntimeRoot(url.path)
        }
        let protectedHomeRoots = [
            "Desktop",
            "Documents",
            "Downloads",
            "Library/CloudStorage",
            "Library/Mobile Documents",
        ].map {
            URL(fileURLWithPath: standardizedHome).appendingPathComponent($0).standardizedFileURL.path
        }
        guard !protectedHomeRoots.contains(where: {
            url.path == $0 || url.path.hasPrefix($0 + "/")
        }) else {
            throw DoryDataDriveError.protectedLocation(url.path)
        }
        let applicationSupportRoot = URL(fileURLWithPath: standardizedHome)
            .appendingPathComponent("Library/Application Support/Dory", isDirectory: true)
            .standardizedFileURL.path
        let isApplicationSupport = url.path.hasPrefix(applicationSupportRoot + "/")
        let isMountedVolumePath = url.path.hasPrefix("/Volumes/")
        guard isApplicationSupport || isMountedVolumePath else {
            throw DoryDataDriveError.unsupportedLocation(url.path)
        }
        self.home = standardizedHome
        self.root = url.path
    }

    public static func defaultRoot(home: String = DoryDataDrive.processHome()) -> String {
        let canonicalHome = (try? canonicalPath(home)) ?? lexicalAbsolutePath(home)
        return URL(fileURLWithPath: canonicalHome)
            .appendingPathComponent("Library/Application Support/Dory", isDirectory: true)
            .appendingPathComponent(bundleName, isDirectory: true)
            .path
    }

    /// Returns the explicit process home used by launchd, the standalone runtime, and isolated
    /// qualification homes. `NSHomeDirectory()` can remain bound to the login account even when a
    /// caller intentionally supplies `HOME`, so it is only the fallback.
    public static func processHome(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        guard let home = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              home.hasPrefix("/") else {
            return NSHomeDirectory()
        }
        return home
    }

    /// Produces one stable path spelling even when the destination does not exist yet. Foundation
    /// may remove `/private` while standardizing an existing home but retain it for a missing
    /// descendant. Canonicalize the deepest existing ancestor once, then append the missing suffix
    /// so both sides of every authorization/identity comparison use the same filesystem spelling.
    public static func canonicalPath(_ path: String) throws -> String {
        guard path.hasPrefix("/") else {
            throw DoryDataDriveError.invalidRoot(path)
        }
        let lexicalPath = lexicalAbsolutePath(path)
        var ancestor = URL(fileURLWithPath: lexicalPath)
        var missingComponents: [String] = []
        while ancestor.path != "/", !pathEntryExists(ancestor.path) {
            missingComponents.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        guard pathEntryExists(ancestor.path) else {
            throw DoryDataDriveError.filesystem("canonicalize Dory data-drive path: no existing ancestor for \(path)")
        }
        var canonical = ancestor.resolvingSymlinksInPath()
        for component in missingComponents.reversed() {
            canonical.appendPathComponent(component)
        }
        return canonical.path
    }

    private static func lexicalAbsolutePath(_ path: String) -> String {
        var components: [String] = []
        for component in URL(fileURLWithPath: path).pathComponents {
            switch component {
            case "/", "", ".":
                continue
            case "..":
                if !components.isEmpty { components.removeLast() }
            default:
                components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    private static func pathEntryExists(_ path: String) -> Bool {
        var status = stat()
        return path.withCString { lstat($0, &status) } == 0
    }

    private static func hasControlCharacter(_ path: String) -> Bool {
        path.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }

    public var manifestPath: String { root + "/drive.json" }
    public var engineDirectory: String { root + "/engine" }
    public var engineDataDiskPath: String { engineDirectory + "/docker-data.ext4" }
    public var kubernetesDirectory: String { root + "/kubernetes" }
    public var machinesDirectory: String { root + "/machines" }
    public var snapshotsDirectory: String { root + "/snapshots" }
    public var exportsDirectory: String { root + "/exports" }
    public var operationsDirectory: String { root + "/operations" }
    public var backupsDirectory: String { exportsDirectory }
    public var lockPath: String { root + "/drive.lock" }

    /// Explicit recovery candidates, ordered from the newest development layout to the oldest
    /// Apple-container store. A fresh product launch never adopts them automatically; callers must
    /// opt in, and adoption always clones without moving, editing, or deleting the rollback source.
    public var legacyEngineDataDiskPaths: [String] {
        [
            home + "/.dory/hv/docker-data.ext4",
            home + "/Library/Application Support/com.apple.container/volumes/dory-engine-data/volume.img",
        ]
    }

    public var legacyMachinesDirectory: String { home + "/.dory/machines" }

    public enum MachineAdoption: Sendable, Equatable {
        case noLegacyData
        case destinationAlreadyPopulated
        case adopted(source: String)
    }

    public enum Inspection: Sendable, Equatable {
        case absent
        case ready
    }

    /// Inspects the bundle without creating or changing it. Diagnostics use this path so a health
    /// check cannot accidentally recreate an unmounted external drive on the Mac's internal disk.
    public func inspect(fileManager: FileManager = .default) throws -> Inspection {
        let mountedVolume = try mountedExternalVolumeIdentity(fileManager: fileManager)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root, isDirectory: &isDirectory) else {
            return .absent
        }
        guard isDirectory.boolValue else {
            throw DoryDataDriveError.invalidRoot(root)
        }
        let manifest = try readManifest(fileManager: fileManager)
        try validateVolumeIdentity(manifest, mountedVolume: mountedVolume)
        return .ready
    }

    public func prepare(fileManager: FileManager = .default) throws {
        do {
            let mountedVolume = try mountedExternalVolumeIdentity(fileManager: fileManager)
            let parent = URL(fileURLWithPath: root).deletingLastPathComponent().path
            try fileManager.createDirectory(atPath: parent, withIntermediateDirectories: true)
            let creationLock = try EngineStateDirectoryLock(
                stateDirectory: parent,
                lockFileName: ".\(URL(fileURLWithPath: root).lastPathComponent).creation.lock"
            )
            defer { withExtendedLifetime(creationLock) {} }
            let manifest: DoryDataDriveManifest
            if fileManager.fileExists(atPath: manifestPath) {
                manifest = try readOrUpgradeManifest(
                    mountedVolume: mountedVolume,
                    fileManager: fileManager
                )
            } else {
                if fileManager.fileExists(atPath: root) {
                    let entries = try fileManager.contentsOfDirectory(atPath: root)
                    guard entries.isEmpty else {
                        throw DoryDataDriveError.populatedUnmarkedBundle(root)
                    }
                }
                manifest = try createFreshBundle(
                    mountedVolume: mountedVolume,
                    fileManager: fileManager
                )
            }
            try validateVolumeIdentity(manifest, mountedVolume: mountedVolume)
            for directory in durableDirectories(root: root) {
                try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
            }
        } catch let error as DoryDataDriveError {
            throw error
        } catch {
            throw DoryDataDriveError.filesystem("prepare Dory data drive at \(root): \(error)")
        }
    }

    /// Clones the pre-drive machine tree once. The rollback source is never moved or removed, and
    /// an interrupted copy is confined to a uniquely named partial directory that is cleaned up.
    @discardableResult
    public func adoptLegacyMachinesIfNeeded(fileManager: FileManager = .default) throws -> MachineAdoption {
        try prepare(fileManager: fileManager)
        var legacyIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: legacyMachinesDirectory, isDirectory: &legacyIsDirectory),
              legacyIsDirectory.boolValue else {
            return .noLegacyData
        }
        let existing = try fileManager.contentsOfDirectory(atPath: machinesDirectory)
        guard existing.isEmpty else { return .destinationAlreadyPopulated }

        let partial = root + "/.machines-adoption-\(UUID().uuidString).partial"
        try? fileManager.removeItem(atPath: partial)
        do {
            try cloneTree(from: legacyMachinesDirectory, to: partial, fileManager: fileManager)
            try fileManager.removeItem(atPath: machinesDirectory)
            try fileManager.moveItem(atPath: partial, toPath: machinesDirectory)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: machinesDirectory)
            try (legacyMachinesDirectory + "\n").write(
                toFile: machinesDirectory + "/.migrated-from-legacy",
                atomically: true,
                encoding: .utf8
            )
            return .adopted(source: legacyMachinesDirectory)
        } catch {
            try? fileManager.removeItem(atPath: partial)
            // Recreate the canonical empty directory if publication failed after removing it.
            try? fileManager.createDirectory(atPath: machinesDirectory, withIntermediateDirectories: true)
            throw DoryDataDriveError.filesystem(
                "adopt legacy Dory machines from \(legacyMachinesDirectory): \(error)"
            )
        }
    }

    public func validateManifest(fileManager: FileManager = .default) throws {
        let mountedVolume = try mountedExternalVolumeIdentity(fileManager: fileManager)
        let manifest = try readManifest(fileManager: fileManager)
        try validateVolumeIdentity(manifest, mountedVolume: mountedVolume)
    }

    public func readManifest(fileManager: FileManager = .default) throws -> DoryDataDriveManifest {
        try requirePrivateRegularManifest()
        guard let data = fileManager.contents(atPath: manifestPath),
              let manifest = try? JSONDecoder().decode(DoryDataDriveManifest.self, from: data),
              manifest.isValid else {
            throw DoryDataDriveError.invalidManifest(manifestPath)
        }
        return manifest
    }

    private func readOrUpgradeManifest(
        mountedVolume: DoryDataDriveVolumeIdentity?,
        fileManager: FileManager
    ) throws -> DoryDataDriveManifest {
        if let manifest = try? readManifest(fileManager: fileManager) {
            return manifest
        }
        try requirePrivateRegularManifest()
        guard let data = fileManager.contents(atPath: manifestPath),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["kind"] as? String == Self.manifestKind,
              (object["schemaVersion"] as? NSNumber)?.intValue == Self.developmentSchemaVersion else {
            throw DoryDataDriveError.invalidManifest(manifestPath)
        }
        let manifest = DoryDataDriveManifest(volume: mountedVolume)
        try writeManifest(manifest, at: manifestPath, fileManager: fileManager)
        return manifest
    }

    private func requirePrivateRegularManifest() throws {
        var status = stat()
        guard manifestPath.withCString({ lstat($0, &status) }) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(),
              status.st_mode & 0o077 == 0,
              status.st_nlink == 1 else {
            throw DoryDataDriveError.invalidManifest(manifestPath)
        }
    }

    private func createFreshBundle(
        mountedVolume: DoryDataDriveVolumeIdentity?,
        fileManager: FileManager
    ) throws -> DoryDataDriveManifest {
        let destination = URL(fileURLWithPath: root)
        let parent = destination.deletingLastPathComponent().path
        let partial = parent + "/.\(destination.lastPathComponent).\(UUID().uuidString).partial"
        try? fileManager.removeItem(atPath: partial)
        do {
            for directory in durableDirectories(root: partial) {
                try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
            }
            let manifest = DoryDataDriveManifest(volume: mountedVolume)
            try writeManifest(
                manifest,
                at: partial + "/drive.json",
                fileManager: fileManager
            )
            try Self.syncDirectory(partial)
            if fileManager.fileExists(atPath: root) {
                let entries = try fileManager.contentsOfDirectory(atPath: root)
                guard entries.isEmpty else {
                    throw DoryDataDriveError.populatedUnmarkedBundle(root)
                }
                try fileManager.removeItem(atPath: root)
            }
            try fileManager.moveItem(atPath: partial, toPath: root)
            try Self.syncDirectory(parent)
            return manifest
        } catch {
            try? fileManager.removeItem(atPath: partial)
            throw error
        }
    }

    private func durableDirectories(root: String) -> [String] {
        [
            root,
            root + "/engine",
            root + "/kubernetes",
            root + "/machines",
            root + "/snapshots",
            root + "/exports",
            root + "/operations",
        ]
    }

    private func writeManifest(
        _ manifest: DoryDataDriveManifest,
        at path: String,
        fileManager: FileManager
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest) + Data("\n".utf8)
        try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        try Self.syncFile(path)
        try Self.syncDirectory(URL(fileURLWithPath: path).deletingLastPathComponent().path)
    }

    private static func syncFile(_ path: String) throws {
        let descriptor = path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else {
            throw DoryDataDriveError.filesystem("open Dory data-drive file for sync at \(path): errno \(errno)")
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw DoryDataDriveError.filesystem("sync Dory data-drive file at \(path): errno \(errno)")
        }
    }

    private static func syncDirectory(_ path: String) throws {
        let descriptor = path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC) }
        guard descriptor >= 0 else {
            throw DoryDataDriveError.filesystem("open Dory data-drive directory for sync at \(path): errno \(errno)")
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw DoryDataDriveError.filesystem("sync Dory data-drive directory at \(path): errno \(errno)")
        }
    }

    private func mountedExternalVolumeIdentity(
        fileManager: FileManager
    ) throws -> DoryDataDriveVolumeIdentity? {
        let components = URL(fileURLWithPath: root).pathComponents
        guard components.count >= 3, components[1] == "Volumes" else { return nil }
        let volumeRoot = "/Volumes/\(components[2])"
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: volumeRoot, isDirectory: &isDirectory),
              isDirectory.boolValue,
              Self.isMountedVolumeRoot(volumeRoot) else {
            throw DoryDataDriveError.unavailableVolume(volumeRoot)
        }
        var filesystem = statfs()
        guard statfs(volumeRoot, &filesystem) == 0 else {
            throw DoryDataDriveError.unavailableVolume(volumeRoot)
        }
        let type = withUnsafePointer(to: &filesystem.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSNAMELEN)) {
                String(cString: $0)
            }
        }
        guard type == "apfs", filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else {
            throw DoryDataDriveError.unsupportedVolume(volumeRoot)
        }
        do {
            let values = try URL(fileURLWithPath: volumeRoot).resourceValues(forKeys: [
                .volumeUUIDStringKey,
                .volumeNameKey,
                .volumeIsLocalKey,
                .volumeIsReadOnlyKey,
            ])
            guard values.volumeIsLocal == true,
                  values.volumeIsReadOnly == false,
                  let uuidString = values.volumeUUIDString,
                  let uuid = UUID(uuidString: uuidString),
                  let name = values.volumeName,
                  !name.isEmpty else {
                throw DoryDataDriveError.unsupportedVolume(volumeRoot)
            }
            return DoryDataDriveVolumeIdentity(uuid: uuid, nameAtCreation: name)
        } catch let error as DoryDataDriveError {
            throw error
        } catch {
            throw DoryDataDriveError.filesystem(
                "read Dory data-drive volume identity at \(volumeRoot): \(error)"
            )
        }
    }

    private func validateVolumeIdentity(
        _ manifest: DoryDataDriveManifest,
        mountedVolume: DoryDataDriveVolumeIdentity?
    ) throws {
        switch (manifest.volume, mountedVolume) {
        case (nil, nil):
            return
        case let (.some(recorded), .some(current)) where recorded.uuid == current.uuid:
            return
        default:
            throw DoryDataDriveError.invalidManifest(manifestPath)
        }
    }

    static func isMountedVolumeRoot(_ path: String) -> Bool {
        var volume = stat()
        var parent = stat()
        guard stat(path, &volume) == 0,
              stat(URL(fileURLWithPath: path).deletingLastPathComponent().path, &parent) == 0 else {
            return false
        }
        return volume.st_dev != parent.st_dev
    }

    private func cloneTree(from source: String, to destination: String, fileManager: FileManager) throws {
        try fileManager.createDirectory(atPath: destination, withIntermediateDirectories: true)
        let entries = try fileManager.contentsOfDirectory(atPath: source)
        for entry in entries {
            let sourcePath = source + "/" + entry
            let destinationPath = destination + "/" + entry
            let attributes = try fileManager.attributesOfItem(atPath: sourcePath)
            guard let type = attributes[.type] as? FileAttributeType else { continue }
            switch type {
            case .typeDirectory:
                try cloneTree(from: sourcePath, to: destinationPath, fileManager: fileManager)
            case .typeRegular:
                if clonefile(sourcePath, destinationPath, 0) != 0 {
                    try? fileManager.removeItem(atPath: destinationPath)
                    try fileManager.copyItem(atPath: sourcePath, toPath: destinationPath)
                }
            case .typeSymbolicLink:
                let target = try fileManager.destinationOfSymbolicLink(atPath: sourcePath)
                try fileManager.createSymbolicLink(atPath: destinationPath, withDestinationPath: target)
            default:
                // Live handoff/control sockets and other transient nodes are intentionally rebuilt.
                continue
            }
        }
    }
}
