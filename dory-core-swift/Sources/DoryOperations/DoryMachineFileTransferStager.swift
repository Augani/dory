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
        try FileManager.default.removeItem(atPath: rootPath)
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

        let stagingDirectory = requestedDirectory
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("dory-machine-transfer-imports", isDirectory: true)
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

        let transferName = "transfer-" + UUID().uuidString.lowercased()
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
