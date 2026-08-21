import Darwin
import Foundation

public struct DoryStagedMachineFileTransfer: Sendable, Equatable {
    public let rootPath: String
    public let fileCount: UInt64
    public let directoryCount: UInt64
    public let byteCount: UInt64

    fileprivate init(
        rootPath: String,
        fileCount: UInt64,
        directoryCount: UInt64,
        byteCount: UInt64
    ) {
        self.rootPath = rootPath
        self.fileCount = fileCount
        self.directoryCount = directoryCount
        self.byteCount = byteCount
    }

    public func remove() throws {
        do {
            try FileManager.default.removeItem(atPath: rootPath)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // An asynchronous daemon transfer atomically claims the handoff before replying.
            // Client cleanup is therefore deliberately idempotent when ownership has moved.
        }
    }
}

public enum DoryMachineFileTransferStagingError: Error, Sendable, Equatable,
    CustomStringConvertible {
    case emptySelection
    case tooManyFiles
    case tooManyEntries
    case directoryTooDeep(String)
    case duplicateFileName(String)
    case unsupportedFile(String)
    case fileTooLarge(String)
    case transferTooLarge
    case sourceChanged(String)
    case unsafeStagingDirectory
    case io(String, Int32)

    public var description: String {
        switch self {
        case .emptySelection:
            "no files or folders were selected"
        case .tooManyFiles:
            "selected folders contain too many files"
        case .tooManyEntries:
            "selected folders contain too many files and directories"
        case let .directoryTooDeep(name):
            "selected folder is nested too deeply: \(name)"
        case let .duplicateFileName(name):
            "more than one selected file is named \(name)"
        case let .unsupportedFile(name):
            "selected item is not a supported regular file or directory: \(name)"
        case let .fileTooLarge(name):
            "selected file is too large: \(name)"
        case .transferTooLarge:
            "selected files and folders exceed the transfer size limit"
        case let .sourceChanged(name):
            "selected file changed while it was being staged: \(name)"
        case .unsafeStagingDirectory:
            "file transfer staging directory is not private"
        case let .io(operation, code):
            "file transfer staging \(operation) failed: \(String(cString: strerror(code)))"
        }
    }
}

/// Copies user-selected regular files and directory trees into a private handoff that doryd can
/// consume after the selecting app's security-scoped access ends. Traversal never follows symlinks
/// and every opened source is revalidated after its bytes or children have been copied.
public enum DoryMachineFileTransferStager {
    public static let maximumFileCount = 10_000
    public static let maximumEntryCount = 100_000
    public static let maximumFileBytes: UInt64 = 16 * 1024 * 1024 * 1024
    public static let maximumTransferBytes: UInt64 = 64 * 1024 * 1024 * 1024
    private static let copyBufferBytes = 1024 * 1024
    private static let maximumDirectoryDepth = 128
    private static let reservedRootName = ".dory-sync-tmp"
    private static let stagingDirectoryName = "dory-machine-transfer-imports"
    private static let clientStagePrefix = "transfer-"
    private static let daemonStagePrefix = "owned-"
    private static let daemonExportPrefix = "export-"

    public static var defaultStagingDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(stagingDirectoryName, isDirectory: true)
            .standardizedFileURL
    }

    private struct StageState {
        var fileCount = 0
        var directoryCount = 0
        var byteCount: UInt64 = 0

        mutating func reserveFile(name: String, bytes: UInt64) throws {
            guard fileCount < maximumFileCount else {
                throw DoryMachineFileTransferStagingError.tooManyFiles
            }
            guard fileCount + directoryCount < maximumEntryCount else {
                throw DoryMachineFileTransferStagingError.tooManyEntries
            }
            guard bytes <= maximumFileBytes else {
                throw DoryMachineFileTransferStagingError.fileTooLarge(name)
            }
            let (total, overflow) = byteCount.addingReportingOverflow(bytes)
            guard !overflow, total <= maximumTransferBytes else {
                throw DoryMachineFileTransferStagingError.transferTooLarge
            }
            fileCount += 1
            byteCount = total
        }

        mutating func reserveDirectory() throws {
            guard fileCount + directoryCount < maximumEntryCount else {
                throw DoryMachineFileTransferStagingError.tooManyEntries
            }
            directoryCount += 1
        }
    }

    public static func stage(
        fileURLs: [URL],
        stagingDirectory requestedDirectory: URL? = nil
    ) throws -> DoryStagedMachineFileTransfer {
        guard !fileURLs.isEmpty else {
            throw DoryMachineFileTransferStagingError.emptySelection
        }
        guard fileURLs.count <= maximumFileCount else {
            throw DoryMachineFileTransferStagingError.tooManyFiles
        }
        let names = fileURLs.map(\.lastPathComponent)
        var uniqueNames = Set<String>()
        for name in names where !uniqueNames.insert(name).inserted {
            throw DoryMachineFileTransferStagingError.duplicateFileName(name)
        }
        for name in names where !isValidFileName(name, atRoot: true) {
            throw DoryMachineFileTransferStagingError.unsupportedFile(name)
        }

        let stagingDirectory = requestedDirectory ?? defaultStagingDirectory
        if mkdir(stagingDirectory.path, mode_t(0o700)) != 0, errno != EEXIST {
            throw DoryMachineFileTransferStagingError.io("directory creation", errno)
        }
        let baseDescriptor = open(
            stagingDirectory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard baseDescriptor >= 0 else {
            throw DoryMachineFileTransferStagingError.io("directory open", errno)
        }
        defer { close(baseDescriptor) }
        guard isPrivateDirectory(descriptor: baseDescriptor) else {
            throw DoryMachineFileTransferStagingError.unsafeStagingDirectory
        }

        let transferName = clientStagePrefix + UUID().uuidString.lowercased()
        guard mkdirat(baseDescriptor, transferName, mode_t(0o700)) == 0 else {
            throw DoryMachineFileTransferStagingError.io("transfer creation", errno)
        }
        let transferURL = stagingDirectory.appendingPathComponent(
            transferName,
            isDirectory: true
        )
        var completed = false
        defer {
            if !completed {
                try? FileManager.default.removeItem(at: transferURL)
            }
        }
        let transferDescriptor = openat(
            baseDescriptor,
            transferName,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard transferDescriptor >= 0 else {
            throw DoryMachineFileTransferStagingError.io("transfer open", errno)
        }
        defer { close(transferDescriptor) }
        guard isPrivateDirectory(descriptor: transferDescriptor) else {
            throw DoryMachineFileTransferStagingError.unsafeStagingDirectory
        }

        var state = StageState()
        for (sourceURL, name) in zip(fileURLs, names) {
            let securityScope = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if securityScope { sourceURL.stopAccessingSecurityScopedResource() }
            }
            let sourceDescriptor = open(
                sourceURL.path,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
            guard sourceDescriptor >= 0 else {
                throw DoryMachineFileTransferStagingError.io("source open", errno)
            }
            defer { close(sourceDescriptor) }
            var before = stat()
            guard fstat(sourceDescriptor, &before) == 0 else {
                throw DoryMachineFileTransferStagingError.unsupportedFile(name)
            }
            switch before.st_mode & S_IFMT {
            case S_IFREG:
                try stageFile(
                    sourceDescriptor: sourceDescriptor,
                    sourceSnapshot: before,
                    destinationDirectory: transferDescriptor,
                    name: name,
                    displayPath: name,
                    state: &state
                )
            case S_IFDIR:
                try stageDirectory(
                    sourceDescriptor: sourceDescriptor,
                    sourceSnapshot: before,
                    destinationDirectory: transferDescriptor,
                    name: name,
                    displayPath: name,
                    depth: 1,
                    state: &state
                )
            default:
                throw DoryMachineFileTransferStagingError.unsupportedFile(name)
            }
        }
        guard fsync(transferDescriptor) == 0, fsync(baseDescriptor) == 0 else {
            throw DoryMachineFileTransferStagingError.io("directory sync", errno)
        }
        completed = true
        return DoryStagedMachineFileTransfer(
            rootPath: transferURL.path,
            fileCount: UInt64(state.fileCount),
            directoryCount: UInt64(state.directoryCount),
            byteCount: state.byteCount
        )
    }

    /// Returns true only for an app-authored handoff in Dory's exact shared staging namespace.
    /// Arbitrary owner-private directories are intentionally not accepted as transfer authority.
    package static func isClientStagingRoot(_ path: String) -> Bool {
        guard let root = managedRoot(path), root.kind == .client else { return false }
        return isPrivateManagedRoot(root)
    }

    /// Returns true for either a client handoff or a handoff atomically claimed by doryd.
    package static func isManagedStagingRoot(_ path: String) -> Bool {
        guard let root = managedRoot(path) else { return false }
        return isPrivateManagedRoot(root)
    }

    /// Moves one client handoff to an operation-specific daemon-owned name without opening an
    /// app/daemon cleanup race. Once this succeeds, the daemon is solely responsible for removal.
    package static func claimForDaemon(
        _ path: String,
        operationID: String,
        ownerProcessID: pid_t = getpid()
    ) throws -> String {
        guard let source = managedRoot(path), source.kind == .client,
              isValidOperationID(operationID), ownerProcessID > 0 else {
            throw DoryMachineFileTransferStagingError.unsafeStagingDirectory
        }
        let baseDescriptor = try openPrivateStagingDirectory()
        defer { close(baseDescriptor) }
        let sourceDescriptor = openat(
            baseDescriptor,
            source.name,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard sourceDescriptor >= 0 else {
            throw DoryMachineFileTransferStagingError.io("claim source open", errno)
        }
        let sourceIsPrivate = isPrivateDirectory(descriptor: sourceDescriptor)
        close(sourceDescriptor)
        guard sourceIsPrivate else {
            throw DoryMachineFileTransferStagingError.unsafeStagingDirectory
        }

        let destinationName = daemonStagePrefix + String(ownerProcessID) + "-" + operationID
        let result = source.name.withCString { sourceName in
            destinationName.withCString { destinationName in
                renameatx_np(
                    baseDescriptor,
                    sourceName,
                    baseDescriptor,
                    destinationName,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else {
            throw DoryMachineFileTransferStagingError.io("claim rename", errno)
        }
        let claimedPath = defaultStagingDirectory
            .appendingPathComponent(destinationName, isDirectory: true).path
        guard fsync(baseDescriptor) == 0 else {
            let code = errno
            try? removeManagedStagingRoot(claimedPath)
            throw DoryMachineFileTransferStagingError.io("claim sync", code)
        }
        return claimedPath
    }

    /// Reserves a syntactically exact, currently absent output path for one daemon-owned guest
    /// export. The Rust pull engine creates the leaf with create-new semantics; this method owns
    /// only the private parent namespace and never follows a caller-selected path.
    package static func reserveDaemonExportRoot(
        operationID: String,
        ownerProcessID: pid_t = getpid()
    ) throws -> String {
        guard isValidOperationID(operationID), ownerProcessID > 0 else {
            throw DoryMachineFileTransferStagingError.unsafeStagingDirectory
        }
        try ensurePrivateStagingDirectory()
        let baseDescriptor = try openPrivateStagingDirectory()
        defer { close(baseDescriptor) }
        let name = daemonExportPrefix + String(ownerProcessID) + "-" + operationID
        var info = stat()
        guard fstatat(baseDescriptor, name, &info, AT_SYMLINK_NOFOLLOW) != 0,
              errno == ENOENT else {
            throw DoryMachineFileTransferStagingError.unsafeStagingDirectory
        }
        return defaultStagingDirectory.appendingPathComponent(name, isDirectory: true).path
    }

    package static func isDaemonExportRoot(_ path: String) -> Bool {
        guard let root = managedRoot(path), root.kind == .export else { return false }
        return isPrivateManagedRoot(root)
    }

    /// Removes a syntactically exact managed handoff. Missing roots are already clean and succeed.
    package static func removeManagedStagingRoot(_ path: String) throws {
        guard managedRoot(path) != nil else {
            throw DoryMachineFileTransferStagingError.unsafeStagingDirectory
        }
        var status = stat()
        guard lstat(path, &status) == 0 else {
            if errno == ENOENT { return }
            throw DoryMachineFileTransferStagingError.io("cleanup stat", errno)
        }
        guard (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == geteuid(),
              (status.st_mode & 0o077) == 0 else {
            throw DoryMachineFileTransferStagingError.unsafeStagingDirectory
        }
        try makeManagedTreeRemovable(path)
        try FileManager.default.removeItem(atPath: path)
        let baseDescriptor = try openPrivateStagingDirectory()
        defer { close(baseDescriptor) }
        guard fsync(baseDescriptor) == 0 else {
            throw DoryMachineFileTransferStagingError.io("cleanup sync", errno)
        }
    }

    /// Reclaims handoffs owned by daemon processes that no longer exist. Live process names are
    /// left untouched, allowing multiple test/manager instances in one process to coexist safely.
    package static func removeAbandonedDaemonStages() {
        let base = defaultStagingDirectory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: base.path) else {
            return
        }
        for name in names {
            guard let owner = daemonOwnerProcessID(name), !processExists(owner) else { continue }
            try? removeManagedStagingRoot(
                base.appendingPathComponent(name, isDirectory: true).path
            )
        }
    }

    private enum ManagedStageKind {
        case client
        case daemon
        case export
    }

    private struct ManagedStageRoot {
        var name: String
        var kind: ManagedStageKind
    }

    private static func managedRoot(_ path: String) -> ManagedStageRoot? {
        guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard url.path == path,
              url.deletingLastPathComponent().path == defaultStagingDirectory.path else {
            return nil
        }
        let name = url.lastPathComponent
        if name.hasPrefix(clientStagePrefix) {
            let suffix = String(name.dropFirst(clientStagePrefix.count))
            guard let uuid = UUID(uuidString: suffix),
                  uuid.uuidString.lowercased() == suffix else { return nil }
            return ManagedStageRoot(name: name, kind: .client)
        }
        if daemonOwnerProcessID(name, prefix: daemonStagePrefix) != nil {
            return ManagedStageRoot(name: name, kind: .daemon)
        }
        guard daemonOwnerProcessID(name, prefix: daemonExportPrefix) != nil else { return nil }
        return ManagedStageRoot(name: name, kind: .export)
    }

    private static func daemonOwnerProcessID(_ name: String) -> pid_t? {
        daemonOwnerProcessID(name, prefix: daemonStagePrefix)
            ?? daemonOwnerProcessID(name, prefix: daemonExportPrefix)
    }

    private static func daemonOwnerProcessID(_ name: String, prefix: String) -> pid_t? {
        guard name.hasPrefix(prefix) else { return nil }
        let fields = name.dropFirst(prefix.count).split(separator: "-", maxSplits: 1)
        guard fields.count == 2,
              let owner = pid_t(fields[0]), owner > 0,
              isValidOperationID(String(fields[1])) else { return nil }
        return owner
    }

    private static func isValidOperationID(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66)
        }
    }

    private static func isPrivateManagedRoot(_ root: ManagedStageRoot) -> Bool {
        guard let baseDescriptor = try? openPrivateStagingDirectory() else { return false }
        defer { close(baseDescriptor) }
        let descriptor = openat(
            baseDescriptor,
            root.name,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        return isPrivateDirectory(descriptor: descriptor)
    }

    private static func openPrivateStagingDirectory() throws -> Int32 {
        let descriptor = open(
            defaultStagingDirectory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw DoryMachineFileTransferStagingError.io("directory open", errno)
        }
        guard isPrivateDirectory(descriptor: descriptor) else {
            close(descriptor)
            throw DoryMachineFileTransferStagingError.unsafeStagingDirectory
        }
        return descriptor
    }

    private static func ensurePrivateStagingDirectory() throws {
        if mkdir(defaultStagingDirectory.path, mode_t(0o700)) != 0, errno != EEXIST {
            throw DoryMachineFileTransferStagingError.io("directory creation", errno)
        }
        let descriptor = try openPrivateStagingDirectory()
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw DoryMachineFileTransferStagingError.io("directory sync", errno)
        }
    }

    /// A completed pull preserves guest directory modes, including mode 000. Restore owner-only
    /// traversal before recursive cleanup without ever following a symlink. The managed root is
    /// already confined to Dory's private namespace and every child comes from a no-symlink pull.
    private static func makeManagedTreeRemovable(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { return }
            throw DoryMachineFileTransferStagingError.io("cleanup stat", errno)
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return }
        guard fchmodat(AT_FDCWD, path, mode_t(0o700), AT_SYMLINK_NOFOLLOW) == 0 else {
            throw DoryMachineFileTransferStagingError.io("cleanup permissions", errno)
        }
        let children: [String]
        do {
            children = try FileManager.default.contentsOfDirectory(atPath: path)
        } catch let error as CocoaError {
            throw DoryMachineFileTransferStagingError.io(
                "cleanup directory read",
                Int32(error.errorCode)
            )
        }
        for child in children {
            try makeManagedTreeRemovable(
                URL(fileURLWithPath: path, isDirectory: true)
                    .appendingPathComponent(child, isDirectory: false).path
            )
        }
    }

    private static func processExists(_ processID: pid_t) -> Bool {
        if kill(processID, 0) == 0 { return true }
        return errno != ESRCH
    }

    private static func stageFile(
        sourceDescriptor: Int32,
        sourceSnapshot: stat,
        destinationDirectory: Int32,
        name: String,
        displayPath: String,
        state: inout StageState
    ) throws {
        guard sourceSnapshot.st_size >= 0 else {
            throw DoryMachineFileTransferStagingError.unsupportedFile(displayPath)
        }
        let size = UInt64(sourceSnapshot.st_size)
        try state.reserveFile(name: displayPath, bytes: size)
        let destinationDescriptor = openat(
            destinationDirectory,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard destinationDescriptor >= 0 else {
            throw DoryMachineFileTransferStagingError.io("destination open", errno)
        }
        do {
            try copy(
                sourceDescriptor: sourceDescriptor,
                destinationDescriptor: destinationDescriptor
            )
            guard fsync(destinationDescriptor) == 0 else {
                throw DoryMachineFileTransferStagingError.io("file sync", errno)
            }
        } catch {
            close(destinationDescriptor)
            throw error
        }
        close(destinationDescriptor)
        try revalidateSource(
            descriptor: sourceDescriptor,
            expected: sourceSnapshot,
            displayPath: displayPath
        )
    }

    private static func stageDirectory(
        sourceDescriptor: Int32,
        sourceSnapshot: stat,
        destinationDirectory: Int32,
        name: String,
        displayPath: String,
        depth: Int,
        state: inout StageState
    ) throws {
        guard depth <= maximumDirectoryDepth else {
            throw DoryMachineFileTransferStagingError.directoryTooDeep(displayPath)
        }
        try state.reserveDirectory()
        guard mkdirat(destinationDirectory, name, mode_t(0o700)) == 0 else {
            throw DoryMachineFileTransferStagingError.io("directory creation", errno)
        }
        let destinationDescriptor = openat(
            destinationDirectory,
            name,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard destinationDescriptor >= 0 else {
            throw DoryMachineFileTransferStagingError.io("directory open", errno)
        }
        defer { close(destinationDescriptor) }

        for childName in try directoryEntryNames(descriptor: sourceDescriptor) {
            let childPath = displayPath + "/" + childName
            guard isValidFileName(childName, atRoot: false) else {
                throw DoryMachineFileTransferStagingError.unsupportedFile(childPath)
            }
            let childDescriptor = openat(
                sourceDescriptor,
                childName,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
            guard childDescriptor >= 0 else {
                throw DoryMachineFileTransferStagingError.io("source open", errno)
            }
            defer { close(childDescriptor) }
            var childSnapshot = stat()
            guard fstat(childDescriptor, &childSnapshot) == 0 else {
                throw DoryMachineFileTransferStagingError.io("source stat", errno)
            }
            switch childSnapshot.st_mode & S_IFMT {
            case S_IFREG:
                try stageFile(
                    sourceDescriptor: childDescriptor,
                    sourceSnapshot: childSnapshot,
                    destinationDirectory: destinationDescriptor,
                    name: childName,
                    displayPath: childPath,
                    state: &state
                )
            case S_IFDIR:
                try stageDirectory(
                    sourceDescriptor: childDescriptor,
                    sourceSnapshot: childSnapshot,
                    destinationDirectory: destinationDescriptor,
                    name: childName,
                    displayPath: childPath,
                    depth: depth + 1,
                    state: &state
                )
            default:
                throw DoryMachineFileTransferStagingError.unsupportedFile(childPath)
            }
        }
        try revalidateSource(
            descriptor: sourceDescriptor,
            expected: sourceSnapshot,
            displayPath: displayPath
        )
        guard fsync(destinationDescriptor) == 0 else {
            throw DoryMachineFileTransferStagingError.io("directory sync", errno)
        }
    }

    private static func directoryEntryNames(descriptor: Int32) throws -> [String] {
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else {
            throw DoryMachineFileTransferStagingError.io("directory duplicate", errno)
        }
        guard let stream = fdopendir(duplicate) else {
            let code = errno
            close(duplicate)
            throw DoryMachineFileTransferStagingError.io("directory enumeration", code)
        }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else {
                    throw DoryMachineFileTransferStagingError.io(
                        "directory enumeration",
                        errno
                    )
                }
                break
            }
            let name = try withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                try pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXNAMLEN) + 1
                ) { characters in
                    let length = strnlen(characters, Int(MAXNAMLEN) + 1)
                    guard length <= Int(MAXNAMLEN),
                          let name = String(
                              bytes: UnsafeRawBufferPointer(
                                  start: characters,
                                  count: length
                              ),
                              encoding: .utf8
                          ) else {
                        throw DoryMachineFileTransferStagingError.unsupportedFile(
                            "non-UTF-8 directory entry"
                        )
                    }
                    return name
                }
            }
            if name != ".", name != ".." {
                names.append(name)
            }
        }
        names.sort()
        return names
    }

    private static func revalidateSource(
        descriptor: Int32,
        expected: stat,
        displayPath: String
    ) throws {
        var actual = stat()
        guard fstat(descriptor, &actual) == 0 else {
            throw DoryMachineFileTransferStagingError.io("source revalidation", errno)
        }
        guard sameSnapshot(expected, actual) else {
            throw DoryMachineFileTransferStagingError.sourceChanged(displayPath)
        }
    }

    private static func copy(
        sourceDescriptor: Int32,
        destinationDescriptor: Int32
    ) throws {
        var buffer = [UInt8](repeating: 0, count: copyBufferBytes)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(sourceDescriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { return }
            if count < 0 {
                if errno == EINTR { continue }
                throw DoryMachineFileTransferStagingError.io("source read", errno)
            }
            var written = 0
            while written < count {
                let result = buffer.withUnsafeBytes { bytes in
                    Darwin.write(
                        destinationDescriptor,
                        bytes.baseAddress?.advanced(by: written),
                        count - written
                    )
                }
                if result < 0 {
                    if errno == EINTR { continue }
                    throw DoryMachineFileTransferStagingError.io("destination write", errno)
                }
                written += result
            }
        }
    }

    private static func isValidFileName(_ name: String, atRoot: Bool) -> Bool {
        let count = name.utf8.count
        return (1...255).contains(count)
            && name != "."
            && name != ".."
            && (!atRoot || name != reservedRootName)
            && !name.contains("/")
            && !name.contains("\0")
    }

    private static func isPrivateDirectory(descriptor: Int32) -> Bool {
        var info = stat()
        return fstat(descriptor, &info) == 0
            && (info.st_mode & S_IFMT) == S_IFDIR
            && info.st_uid == geteuid()
            && (info.st_mode & 0o077) == 0
    }

    private static func sameSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}
