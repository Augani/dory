import Darwin
import Foundation

public enum DoryVZMacMachineLeaseError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidRoot(String)
    case invalidLockFile(String)
    case alreadyInUse(String)
    case filesystem(String, Int32)

    public var description: String {
        switch self {
        case .invalidRoot(let path): "VZMac machine root is not a direct directory: \(path)"
        case .invalidLockFile(let path): "VZMac machine lock is not a direct regular file: \(path)"
        case .alreadyInUse(let path): "VZMac machine is already in use: \(path)"
        case .filesystem(let operation, let code): "\(operation) failed with errno \(code)"
        }
    }
}

public final class DoryVZMacMachineLease: @unchecked Sendable {
    public static let lockName = ".machine.lock"

    private let descriptor: Int32
    public let rootURL: URL

    public init(rootURL: URL) throws {
        var rootStatus = stat()
        guard lstat(rootURL.path, &rootStatus) == 0,
              (rootStatus.st_mode & S_IFMT) == S_IFDIR else {
            throw DoryVZMacMachineLeaseError.invalidRoot(rootURL.path)
        }
        let lockURL = rootURL.appendingPathComponent(Self.lockName)
        let descriptor = open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw DoryVZMacMachineLeaseError.filesystem("open VZMac machine lock", errno)
        }
        var lockStatus = stat()
        guard fstat(descriptor, &lockStatus) == 0 else {
            let code = errno
            close(descriptor)
            throw DoryVZMacMachineLeaseError.filesystem("inspect VZMac machine lock", code)
        }
        guard (lockStatus.st_mode & S_IFMT) == S_IFREG, lockStatus.st_nlink == 1 else {
            close(descriptor)
            throw DoryVZMacMachineLeaseError.invalidLockFile(lockURL.path)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK {
                throw DoryVZMacMachineLeaseError.alreadyInUse(rootURL.path)
            }
            throw DoryVZMacMachineLeaseError.filesystem("lock VZMac machine", code)
        }
        self.descriptor = descriptor
        self.rootURL = rootURL
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
