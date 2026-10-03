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
    private let rootDevice: dev_t
    private let rootInode: ino_t
    private let runtimeClaimLock = NSLock()
    private var runtimeClaimID: UUID?
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
        guard Self.hasCurrentIdentity(rootURL: rootURL, rootDevice: rootStatus.st_dev,
                                      rootInode: rootStatus.st_ino, descriptor: descriptor) else {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
            throw DoryVZMacMachineLeaseError.invalidLockFile(lockURL.path)
        }
        self.descriptor = descriptor
        rootDevice = rootStatus.st_dev
        rootInode = rootStatus.st_ino
        self.rootURL = rootURL
    }

    /// A flock on an unlinked or moved lock file is not authority over its replacement.
    /// Admission rechecks this identity around reload while retaining the actual owner.
    func ownsRoot(_ requestedRootURL: URL) -> Bool {
        guard rootURL.standardizedFileURL == requestedRootURL.standardizedFileURL else { return false }
        return Self.hasCurrentIdentity(rootURL: rootURL, rootDevice: rootDevice,
                                       rootInode: rootInode, descriptor: descriptor)
    }

    /// Sharing the flock owner with the adapter must not authorize two writable runtimes.
    /// A claim is installed before reload, which may itself reconcile durable journals.
    func claimRuntime() throws -> DoryVZMacRuntimeLeaseClaim {
        try runtimeClaimLock.withLock {
            guard runtimeClaimID == nil else {
                throw DoryVZMacMachineLeaseError.alreadyInUse(rootURL.path)
            }
            let claimID = UUID()
            runtimeClaimID = claimID
            return DoryVZMacRuntimeLeaseClaim(lease: self, claimID: claimID)
        }
    }

    fileprivate func releaseRuntimeClaim(_ claimID: UUID) {
        runtimeClaimLock.withLock {
            guard runtimeClaimID == claimID else { return }
            runtimeClaimID = nil
        }
    }

    private static func hasCurrentIdentity(
        rootURL: URL, rootDevice: dev_t, rootInode: ino_t, descriptor: Int32
    ) -> Bool {
        var root = stat()
        var heldLock = stat()
        var currentLock = stat()
        guard lstat(rootURL.path, &root) == 0, (root.st_mode & S_IFMT) == S_IFDIR,
              root.st_dev == rootDevice, root.st_ino == rootInode,
              fstat(descriptor, &heldLock) == 0, (heldLock.st_mode & S_IFMT) == S_IFREG,
              heldLock.st_nlink == 1,
              lstat(rootURL.appendingPathComponent(lockName).path, &currentLock) == 0,
              (currentLock.st_mode & S_IFMT) == S_IFREG, currentLock.st_nlink == 1 else { return false }
        return heldLock.st_dev == currentLock.st_dev && heldLock.st_ino == currentLock.st_ino
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

/// Retains the actual flock owner until this exact runtime admission has retired. Closing or
/// deinitializing an old token cannot revoke a successor that reused the same lease object.
final class DoryVZMacRuntimeLeaseClaim: @unchecked Sendable {
    private let lease: DoryVZMacMachineLease
    private let claimID: UUID

    fileprivate init(lease: DoryVZMacMachineLease, claimID: UUID) {
        self.lease = lease
        self.claimID = claimID
    }

    func close() { lease.releaseRuntimeClaim(claimID) }

    deinit { close() }
}
