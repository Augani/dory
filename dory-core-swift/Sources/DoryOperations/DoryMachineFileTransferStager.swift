import Darwin
import Foundation

public struct DoryStagedMachineFileTransfer: Sendable, Equatable {
    public let rootPath: String
    public let fileCount: UInt64
    public let byteCount: UInt64

    fileprivate init(rootPath: String, fileCount: UInt64, byteCount: UInt64) {
        self.rootPath = rootPath
        self.fileCount = fileCount
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
            "no files were selected"
        case .tooManyFiles:
            "too many files were selected"
        case let .duplicateFileName(name):
            "more than one selected file is named \(name)"
        case let .unsupportedFile(name):
            "selected item is not a supported regular file: \(name)"
        case let .fileTooLarge(name):
            "selected file is too large: \(name)"
        case .transferTooLarge:
            "selected files exceed the transfer size limit"
        case let .sourceChanged(name):
            "selected file changed while it was being staged: \(name)"
        case .unsafeStagingDirectory:
            "file transfer staging directory is not private"
        case let .io(operation, code):
            "file transfer staging \(operation) failed: \(String(cString: strerror(code)))"
        }
    }
}

/// Copies user-selected files into a private, flat handoff tree that doryd can consume after the
/// selecting app's security-scoped access ends. Version 1 intentionally accepts regular files only:
/// directory transfer needs an explicit directory manifest so empty directories are not silently
/// lost by the file-only sync protocol.
public enum DoryMachineFileTransferStager {
    public static let maximumFileCount = 10_000
    public static let maximumFileBytes: UInt64 = 16 * 1024 * 1024 * 1024
    public static let maximumTransferBytes: UInt64 = 64 * 1024 * 1024 * 1024
    private static let copyBufferBytes = 1024 * 1024
    private static let reservedRootName = ".dory-sync-tmp"

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
        for name in names where !isValidFileName(name) {
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

        var totalBytes: UInt64 = 0
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
            guard fstat(sourceDescriptor, &before) == 0,
                  (before.st_mode & S_IFMT) == S_IFREG,
                  before.st_size >= 0 else {
                throw DoryMachineFileTransferStagingError.unsupportedFile(name)
            }
            let size = UInt64(before.st_size)
            guard size <= maximumFileBytes else {
                throw DoryMachineFileTransferStagingError.fileTooLarge(name)
            }
            let (nextTotal, overflow) = totalBytes.addingReportingOverflow(size)
            guard !overflow, nextTotal <= maximumTransferBytes else {
                throw DoryMachineFileTransferStagingError.transferTooLarge
            }

            let destinationDescriptor = openat(
                transferDescriptor,
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

            var after = stat()
            guard fstat(sourceDescriptor, &after) == 0 else {
                throw DoryMachineFileTransferStagingError.io("source revalidation", errno)
            }
            guard sameSnapshot(before, after) else {
                throw DoryMachineFileTransferStagingError.sourceChanged(name)
            }
            totalBytes = nextTotal
        }
        guard fsync(transferDescriptor) == 0, fsync(baseDescriptor) == 0 else {
            throw DoryMachineFileTransferStagingError.io("directory sync", errno)
        }
        completed = true
        return DoryStagedMachineFileTransfer(
            rootPath: transferURL.path,
            fileCount: UInt64(fileURLs.count),
            byteCount: totalBytes
        )
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

    private static func isValidFileName(_ name: String) -> Bool {
        let count = name.utf8.count
        return (1...255).contains(count)
            && name != "."
            && name != ".."
            && name != reservedRootName
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
