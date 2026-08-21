import CryptoKit
import Darwin
import DoryOperations
import Foundation

public struct DoryMachineSavedStateManifest: Codable, Sendable, Equatable {
    public static let currentSchemaVersion: UInt16 = 1
    public static let stateFileName = "state.bin"

    public var schemaVersion: UInt16
    public var machineID: String
    public var backend: DoryVirtualizationBackendIdentity
    public var stateFileName: String
    public var stateFileSHA256: String
    public var stateFileByteCount: UInt64
    public var authoritativeConfigurationSHA256: String
    public var runtimeIdentity: DoryMachineRuntimeIdentity
    public var hostHardwareModel: String
    public var hostOperatingSystemBuild: String
    public var createdAtUnixMilliseconds: Int64

    public init(
        machineID: String,
        stateFileSHA256: String,
        stateFileByteCount: UInt64,
        authoritativeConfigurationSHA256: String,
        runtimeIdentity: DoryMachineRuntimeIdentity,
        hostHardwareModel: String,
        hostOperatingSystemBuild: String,
        createdAtUnixMilliseconds: Int64
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.machineID = machineID
        backend = .appleVirtualizationFramework
        stateFileName = Self.stateFileName
        self.stateFileSHA256 = stateFileSHA256.lowercased()
        self.stateFileByteCount = stateFileByteCount
        self.authoritativeConfigurationSHA256 = authoritativeConfigurationSHA256.lowercased()
        self.runtimeIdentity = runtimeIdentity
        self.hostHardwareModel = hostHardwareModel
        self.hostOperatingSystemBuild = hostOperatingSystemBuild
        self.createdAtUnixMilliseconds = createdAtUnixMilliseconds
    }

    public var isStructurallyValid: Bool {
        schemaVersion == Self.currentSchemaVersion
            && Self.isMachineID(machineID)
            && backend == .appleVirtualizationFramework
            && stateFileName == Self.stateFileName
            && Self.isSHA256(stateFileSHA256)
            && stateFileByteCount > 0
            && Self.isSHA256(authoritativeConfigurationSHA256)
            && runtimeIdentity.validate().isEmpty
            && Self.isBoundedHostValue(hostHardwareModel)
            && Self.isBoundedHostValue(hostOperatingSystemBuild)
            && createdAtUnixMilliseconds > 0
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func isMachineID(_ value: String) -> Bool {
        value.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_.-]{0,62}/) != nil
    }

    private static func isBoundedHostValue(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && !value.contains("\0")
    }
}

/// Compact, non-authoritative status projection. The full manifest deliberately remains on disk
/// because it contains the complete resolved plan and is too large to copy through every
/// `MachineEntry`/status operation. Launch and recovery always re-read and validate that durable
/// manifest; this value is only safe evidence for status and UI presentation.
public struct DoryMachineSavedStateStatus: Sendable, Equatable {
    public var schemaVersion: UInt16
    public var backend: DoryVirtualizationBackendIdentity
    public var stateFileSHA256: String
    public var stateFileByteCount: UInt64
    public var hostHardwareModel: String
    public var hostOperatingSystemBuild: String
    public var createdAtUnixMilliseconds: Int64

    public init(manifest: DoryMachineSavedStateManifest) {
        schemaVersion = manifest.schemaVersion
        backend = manifest.backend
        stateFileSHA256 = manifest.stateFileSHA256
        stateFileByteCount = manifest.stateFileByteCount
        hostHardwareModel = manifest.hostHardwareModel
        hostOperatingSystemBuild = manifest.hostOperatingSystemBuild
        createdAtUnixMilliseconds = manifest.createdAtUnixMilliseconds
    }
}

public enum DoryMachineSavedStateInspection: Sendable, Equatable {
    case absent
    case valid(DoryMachineSavedStateManifest)
    case invalid(String)
}

/// Durable same-host saved-state authority. The VZ payload is host-encrypted and is therefore
/// deliberately excluded from portable exports. A manifest is accepted only when its bytes,
/// current machine authority, runtime plan, host model, and OS build all still match exactly.
public struct DoryMachineSavedStateStore: Sendable {
    public static let directoryName = DoryWorkspaceLifecycleOperation.savedStateResourceID
    public static let manifestFileName = "manifest.json"
    public static let temporaryStatePrefix = "state.tmp-"

    private let root: String

    public init(root: String) {
        self.root = URL(fileURLWithPath: root).standardizedFileURL.path
    }

    public func temporaryStatePath(machineID: String, nonce: UUID = UUID()) throws -> String {
        guard Self.isMachineID(machineID) else {
            throw DoryMachineSavedStateError.invalidMachineID
        }
        let directory = try prepareDirectory(machineID: machineID)
        return directory + "/" + Self.temporaryStatePrefix
            + nonce.uuidString.lowercased()
    }

    public func publish(
        temporaryStatePath: String,
        machineID: String,
        authoritativeConfigurationData: Data,
        runtimeIdentity: DoryMachineRuntimeIdentity,
        now: Date = Date()
    ) throws -> DoryMachineSavedStateManifest {
        let directory = try prepareDirectory(machineID: machineID)
        let canonicalTemporary = URL(fileURLWithPath: temporaryStatePath).standardizedFileURL.path
        guard (canonicalTemporary as NSString).deletingLastPathComponent == directory,
              (canonicalTemporary as NSString).lastPathComponent.hasPrefix(Self.temporaryStatePrefix),
              Self.isPrivateRegularFile(canonicalTemporary) else {
            throw DoryMachineSavedStateError.invalidTemporaryState
        }
        let snapshot = try Self.hashStablePrivateFile(canonicalTemporary)
        let host = DoryInstallerHostRuntime.current
        let manifest = DoryMachineSavedStateManifest(
            machineID: machineID,
            stateFileSHA256: snapshot.sha256,
            stateFileByteCount: snapshot.byteCount,
            authoritativeConfigurationSHA256: Self.sha256(authoritativeConfigurationData),
            runtimeIdentity: runtimeIdentity,
            hostHardwareModel: host.hardwareModel,
            hostOperatingSystemBuild: host.operatingSystemBuild,
            createdAtUnixMilliseconds: Int64((now.timeIntervalSince1970 * 1_000).rounded())
        )
        guard manifest.isStructurallyValid else {
            throw DoryMachineSavedStateError.invalidManifest
        }
        let statePath = directory + "/" + DoryMachineSavedStateManifest.stateFileName
        let manifestPath = directory + "/" + Self.manifestFileName
        guard !Self.pathExists(statePath), !Self.pathExists(manifestPath) else {
            throw DoryMachineSavedStateError.alreadyPublished
        }
        guard rename(canonicalTemporary, statePath) == 0 else {
            throw DoryMachineSavedStateError.system("rename state", errno)
        }
        do {
            try Self.syncFile(statePath)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(manifest)
            let temporaryManifest = directory + "/.manifest.tmp-" + UUID().uuidString.lowercased()
            try Self.writeDurablePrivateData(data, path: temporaryManifest)
            guard rename(temporaryManifest, manifestPath) == 0 else {
                _ = unlink(temporaryManifest)
                throw DoryMachineSavedStateError.system("rename manifest", errno)
            }
            try Self.syncDirectory(directory)
            return manifest
        } catch {
            _ = unlink(manifestPath)
            _ = unlink(statePath)
            try? Self.syncDirectory(directory)
            throw error
        }
    }

    public func inspect(
        machineID: String,
        authoritativeConfigurationData: Data,
        runtimeIdentity: DoryMachineRuntimeIdentity
    ) -> DoryMachineSavedStateInspection {
        guard Self.isMachineID(machineID) else {
            return .invalid("saved-state machine identity is invalid")
        }
        let directory = directoryPath(machineID: machineID)
        let statePath = directory + "/" + DoryMachineSavedStateManifest.stateFileName
        let manifestPath = directory + "/" + Self.manifestFileName
        let hasState = Self.pathExists(statePath)
        let hasManifest = Self.pathExists(manifestPath)
        guard hasState || hasManifest else { return .absent }
        guard Self.isPrivateDirectory(directory),
              hasState, hasManifest,
              let data = Self.readPrivateFile(manifestPath),
              let manifest = try? JSONDecoder().decode(
                  DoryMachineSavedStateManifest.self,
                  from: data
              ),
              manifest.isStructurallyValid,
              manifest.machineID == machineID,
              manifest.runtimeIdentity == runtimeIdentity,
              manifest.authoritativeConfigurationSHA256
                == Self.sha256(authoritativeConfigurationData) else {
            return .invalid("saved-state authority is incomplete or does not match the machine")
        }
        let host = DoryInstallerHostRuntime.current
        guard manifest.hostHardwareModel == host.hardwareModel,
              manifest.hostOperatingSystemBuild == host.operatingSystemBuild else {
            return .invalid("saved state belongs to a different host model or OS build")
        }
        do {
            let snapshot = try Self.hashStablePrivateFile(statePath)
            guard snapshot.sha256 == manifest.stateFileSHA256,
                  snapshot.byteCount == manifest.stateFileByteCount else {
                return .invalid("saved-state bytes do not match their manifest")
            }
            return .valid(manifest)
        } catch {
            return .invalid("saved-state bytes cannot be verified")
        }
    }

    public func statePath(machineID: String) -> String {
        directoryPath(machineID: machineID) + "/" + DoryMachineSavedStateManifest.stateFileName
    }

    public func remove(machineID: String) throws {
        let directory = directoryPath(machineID: machineID)
        guard Self.pathExists(directory) else { return }
        guard Self.isPrivateDirectory(directory) else {
            throw DoryMachineSavedStateError.invalidDirectory
        }
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory)
        for entry in entries {
            guard entry == Self.manifestFileName
                    || entry == DoryMachineSavedStateManifest.stateFileName
                    || entry.hasPrefix(Self.temporaryStatePrefix)
                    || entry.hasPrefix(".manifest.tmp-") else {
                throw DoryMachineSavedStateError.invalidDirectory
            }
            let path = directory + "/" + entry
            guard unlink(path) == 0 || errno == ENOENT else {
                throw DoryMachineSavedStateError.system("unlink", errno)
            }
        }
        guard rmdir(directory) == 0 || errno == ENOENT else {
            throw DoryMachineSavedStateError.system("rmdir", errno)
        }
        try Self.syncDirectory(root + "/" + machineID)
    }

    private func prepareDirectory(machineID: String) throws -> String {
        let machineDirectory = root + "/" + machineID
        guard Self.isPrivateDirectory(machineDirectory) else {
            throw DoryMachineSavedStateError.invalidDirectory
        }
        let directory = directoryPath(machineID: machineID)
        if mkdir(directory, 0o700) != 0, errno != EEXIST {
            throw DoryMachineSavedStateError.system("mkdir", errno)
        }
        guard Self.isPrivateDirectory(directory) else {
            throw DoryMachineSavedStateError.invalidDirectory
        }
        try Self.syncDirectory(machineDirectory)
        return directory
    }

    private func directoryPath(machineID: String) -> String {
        root + "/" + machineID + "/" + Self.directoryName
    }

    private static func isMachineID(_ value: String) -> Bool {
        value.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_.-]{0,62}/) != nil
    }

    private static func hashStablePrivateFile(
        _ path: String
    ) throws -> (sha256: String, byteCount: UInt64) {
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw DoryMachineSavedStateError.system("open", errno) }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_uid == getuid(),
              before.st_nlink == 1,
              (before.st_mode & 0o077) == 0,
              before.st_size > 0 else {
            throw DoryMachineSavedStateError.invalidTemporaryState
        }
        var hasher = SHA256()
        var bytes: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw DoryMachineSavedStateError.system("read", errno)
            }
            hasher.update(data: Data(buffer.prefix(count)))
            bytes += UInt64(count)
        }
        var after = stat()
        guard fstat(fd, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw DoryMachineSavedStateError.invalidTemporaryState
        }
        return (
            hasher.finalize().map { String(format: "%02x", $0) }.joined(),
            bytes
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isPrivateRegularFile(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
            && (info.st_mode & S_IFMT) == S_IFREG
            && info.st_uid == getuid()
            && info.st_nlink == 1
            && (info.st_mode & 0o077) == 0
    }

    private static func isPrivateDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
            && (info.st_mode & S_IFMT) == S_IFDIR
            && info.st_uid == getuid()
            && (info.st_mode & 0o077) == 0
    }

    private static func pathExists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    private static func readPrivateFile(_ path: String) -> Data? {
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var before = stat()
        let maximumManifestBytes: off_t = 1024 * 1024
        guard fstat(fd, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_uid == getuid(),
              before.st_nlink == 1,
              (before.st_mode & 0o077) == 0,
              before.st_size >= 0,
              before.st_size <= maximumManifestBytes else {
            return nil
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let data = try? handle.read(upToCount: Int(maximumManifestBytes) + 1),
              data.count <= maximumManifestBytes else {
            return nil
        }
        var after = stat()
        guard fstat(fd, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            return nil
        }
        return data
    }

    private static func syncFile(_ path: String) throws {
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw DoryMachineSavedStateError.system("open", errno) }
        defer { close(fd) }
        guard fsync(fd) == 0 else {
            throw DoryMachineSavedStateError.system("fsync", errno)
        }
    }

    private static func syncDirectory(_ path: String) throws {
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_DIRECTORY)
        guard fd >= 0 else { throw DoryMachineSavedStateError.system("open directory", errno) }
        defer { close(fd) }
        guard fsync(fd) == 0 else {
            throw DoryMachineSavedStateError.system("fsync directory", errno)
        }
    }

    private static func writeDurablePrivateData(_ data: Data, path: String) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw DoryMachineSavedStateError.system("create", errno) }
        var success = false
        defer {
            close(fd)
            if !success { _ = unlink(path) }
        }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = write(fd, base.advanced(by: offset), raw.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw DoryMachineSavedStateError.system("write", errno)
                }
                offset += count
            }
        }
        guard fsync(fd) == 0 else {
            throw DoryMachineSavedStateError.system("fsync", errno)
        }
        success = true
    }
}

public enum DoryMachineSavedStateError: Error, Sendable, CustomStringConvertible {
    case invalidMachineID
    case invalidDirectory
    case invalidTemporaryState
    case invalidManifest
    case alreadyPublished
    case system(String, Int32)

    public var description: String {
        switch self {
        case .invalidMachineID: "saved-state machine ID is invalid"
        case .invalidDirectory: "saved-state directory is not private or has unexpected content"
        case .invalidTemporaryState: "temporary saved-state payload is invalid"
        case .invalidManifest: "saved-state manifest is invalid"
        case .alreadyPublished: "a saved state is already published"
        case let .system(operation, code):
            "saved-state \(operation) failed: \(String(cString: strerror(code)))"
        }
    }
}
