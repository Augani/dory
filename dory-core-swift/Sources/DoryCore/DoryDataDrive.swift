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

/// Canonical durable storage for Dory-owned workload data.
///
/// Runtime sockets, logs, prepared kernels, and replaceable root filesystems stay under `~/.dory`.
/// User-owned Docker state, machine disks, snapshots, and backups live in this bundle so they have
/// one discoverable, relocatable, backup-friendly identity on the Mac.
public struct DoryDataDrive: Sendable, Equatable {
    public static let bundleName = "Dory.dorydrive"
    public static let manifestKind = "dev.dory.data-drive"
    public static let schemaVersion = 1

    public let home: String
    public let root: String

    public init(home: String = DoryDataDrive.processHome(), overrideRoot: String? = nil) throws {
        guard home.hasPrefix("/") else {
            throw DoryDataDriveError.invalidRoot(home)
        }
        let standardizedHome = try Self.canonicalPath(home)
        let candidate = overrideRoot?.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = candidate.flatMap { $0.isEmpty ? nil : $0 }
            ?? Self.defaultRoot(home: standardizedHome)
        guard selected.hasPrefix("/") else {
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

    public var manifestPath: String { root + "/drive.json" }
    public var engineDirectory: String { root + "/engine" }
    public var engineDataDiskPath: String { engineDirectory + "/docker-data.ext4" }
    public var machinesDirectory: String { root + "/machines" }
    public var backupsDirectory: String { root + "/backups" }

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
        try requireMountedExternalVolume(fileManager: fileManager)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root, isDirectory: &isDirectory) else {
            return .absent
        }
        guard isDirectory.boolValue else {
            throw DoryDataDriveError.invalidRoot(root)
        }
        try validateManifest(fileManager: fileManager)
        return .ready
    }

    public func prepare(fileManager: FileManager = .default) throws {
        do {
            try requireMountedExternalVolume(fileManager: fileManager)
            if fileManager.fileExists(atPath: manifestPath) {
                try validateManifest(fileManager: fileManager)
            } else {
                if fileManager.fileExists(atPath: root) {
                    let entries = try fileManager.contentsOfDirectory(atPath: root)
                    guard entries.isEmpty else {
                        throw DoryDataDriveError.populatedUnmarkedBundle(root)
                    }
                }
                try fileManager.createDirectory(atPath: root, withIntermediateDirectories: true)
                try writeManifest(fileManager: fileManager)
            }
            for directory in [root, engineDirectory, machinesDirectory, backupsDirectory] {
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
        guard let data = fileManager.contents(atPath: manifestPath),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["kind"] as? String == Self.manifestKind,
              (object["schemaVersion"] as? NSNumber)?.intValue == Self.schemaVersion else {
            throw DoryDataDriveError.invalidManifest(manifestPath)
        }
    }

    private func writeManifest(fileManager: FileManager) throws {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "kind": Self.manifestKind,
                "schemaVersion": Self.schemaVersion,
            ],
            options: [.prettyPrinted, .sortedKeys]
        ) + Data("\n".utf8)
        try data.write(to: URL(fileURLWithPath: manifestPath), options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestPath)
    }

    private func requireMountedExternalVolume(fileManager: FileManager) throws {
        let components = URL(fileURLWithPath: root).pathComponents
        guard components.count >= 3, components[1] == "Volumes" else { return }
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
