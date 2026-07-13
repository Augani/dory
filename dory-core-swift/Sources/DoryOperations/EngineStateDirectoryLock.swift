import Darwin
import Foundation

public enum EngineStateDirectoryLockError: Error, CustomStringConvertible, Sendable {
    case cannotOpen(path: String, errno: Int32)
    case alreadyInUse(stateDirectory: String, path: String, owner: String, errno: Int32)

    public var description: String {
        switch self {
        case let .cannotOpen(path, error):
            return "cannot open engine state lock \(path): errno \(error)"
        case let .alreadyInUse(state, path, owner, error):
            return "engine state directory is already in use: \(state)"
                + " (lock \(path), \(owner), errno \(error))"
        }
    }
}

/// Process-wide ownership fence for a persistent engine state directory.
///
/// A second VM mounting the same Docker data disk can corrupt ext4 and containerd even when it
/// publishes different sockets. Keep this advisory lock open for the complete VM lifetime so every
/// engine fails before touching rootfs or data-disk state when another process owns the directory.
public final class EngineStateDirectoryLock: @unchecked Sendable {
    public let path: String
    private let descriptor: Int32

    public init(stateDirectory: String, lockFileName: String = "engine.lock") throws {
        let standardizedState = URL(fileURLWithPath: stateDirectory).standardizedFileURL.path
        try FileManager.default.createDirectory(
            atPath: standardizedState,
            withIntermediateDirectories: true
        )
        guard !lockFileName.isEmpty,
              lockFileName != ".",
              lockFileName != "..",
              !lockFileName.contains("/") else {
            throw EngineStateDirectoryLockError.cannotOpen(
                path: standardizedState + "/" + lockFileName,
                errno: EINVAL
            )
        }
        path = standardizedState + "/" + lockFileName

        let opened = path.withCString {
            Darwin.open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        }
        guard opened >= 0 else {
            throw EngineStateDirectoryLockError.cannotOpen(path: path, errno: errno)
        }
        var status = stat()
        guard fstat(opened, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(),
              status.st_nlink == 1 else {
            Darwin.close(opened)
            throw EngineStateDirectoryLockError.cannotOpen(path: path, errno: EINVAL)
        }
        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            let owner = Self.ownerDescription(descriptor: opened)
            Darwin.close(opened)
            throw EngineStateDirectoryLockError.alreadyInUse(
                stateDirectory: standardizedState,
                path: path,
                owner: owner,
                errno: lockError
            )
        }
        descriptor = opened
        _ = Darwin.fchmod(descriptor, mode_t(0o600))

        let owner = "pid=\(getpid())\nstate=\(standardizedState)\n"
        _ = Darwin.ftruncate(descriptor, 0)
        owner.withCString { pointer in
            _ = Darwin.write(descriptor, pointer, strlen(pointer))
        }
        _ = Darwin.fsync(descriptor)
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }

    private static func ownerDescription(descriptor: Int32) -> String {
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else { return "owner unknown" }
        var bytes = [UInt8](repeating: 0, count: 512)
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        guard count > 0 else { return "owner unknown" }
        guard let text = String(bytes: bytes.prefix(Int(count)), encoding: .utf8) else {
            return "owner unknown"
        }
        let description = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: ", ")
        return description.isEmpty ? "owner unknown" : description
    }
}
