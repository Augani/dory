import CryptoKit
import Darwin
import Foundation

enum DoryMacCameraLeaseError: Error, Sendable {
    case unsafeDirectory
    case unsafeLockFile
    case deviceBusy
    case posix(Int32)
}

/// A process-independent, per-user lease for one physical AVFoundation identity. Both the Linux
/// runner and VZMac helper use this backend, so two VMs cannot capture the selected camera at
/// once. Lock files are deliberately retained: unlinking a flock target permits a second inode
/// to acquire a simultaneous lease while the old process still owns the first one.
final class DoryMacCameraLease: @unchecked Sendable {
    private let stateLock = NSLock()
    private var descriptor: Int32

    init(deviceUniqueID: String) throws {
        let directory = "/private/var/tmp/dory-camera-leases-\(getuid())"
        if mkdir(directory, 0o700) != 0, errno != EEXIST {
            throw DoryMacCameraLeaseError.posix(errno)
        }
        let directoryDescriptor = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryDescriptor >= 0 else { throw DoryMacCameraLeaseError.unsafeDirectory }
        defer { close(directoryDescriptor) }
        var directoryStatus = stat()
        guard fstat(directoryDescriptor, &directoryStatus) == 0,
              directoryStatus.st_mode & S_IFMT == S_IFDIR,
              directoryStatus.st_uid == getuid(),
              directoryStatus.st_mode & 0o077 == 0 else {
            throw DoryMacCameraLeaseError.unsafeDirectory
        }

        let digest = SHA256.hash(data: Data(deviceUniqueID.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let fileName = "\(digest).lock"
        let fileDescriptor = openat(
            directoryDescriptor, fileName,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard fileDescriptor >= 0 else { throw DoryMacCameraLeaseError.posix(errno) }
        var fileStatus = stat()
        guard fstat(fileDescriptor, &fileStatus) == 0,
              fileStatus.st_mode & S_IFMT == S_IFREG,
              fileStatus.st_uid == getuid(),
              fileStatus.st_nlink == 1,
              fileStatus.st_mode & 0o077 == 0 else {
            close(fileDescriptor)
            throw DoryMacCameraLeaseError.unsafeLockFile
        }
        guard flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fileDescriptor)
            if code == EWOULDBLOCK || code == EAGAIN {
                throw DoryMacCameraLeaseError.deviceBusy
            }
            throw DoryMacCameraLeaseError.posix(code)
        }
        descriptor = fileDescriptor
    }

    func release() {
        stateLock.lock()
        let held = descriptor
        descriptor = -1
        stateLock.unlock()
        if held >= 0 { close(held) }
    }

    deinit { release() }
}
