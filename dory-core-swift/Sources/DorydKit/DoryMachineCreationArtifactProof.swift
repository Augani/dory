import Darwin
import Foundation

/// Ephemeral evidence for repeated checks under one exclusive creation context. This cannot be
/// decoded from a journal: acquiring a new context must verify both complete artifacts again.
final class DoryMachineCreationArtifactProof {
    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init(_ info: stat) throws {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
                  info.st_nlink == 1, info.st_mode & 0o077 == 0, info.st_size >= 0 else {
                throw MachineManagerError.persistence("clone artifact is not a private owned regular file")
            }
            device = info.st_dev; inode = info.st_ino; size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanoseconds = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec; changedNanoseconds = info.st_ctimespec.tv_nsec
        }
    }

    private final class File {
        let path: String
        let expected: DoryMachineSnapshotArtifact
        private let descriptor: Int32
        private let identity: Identity

        init(path: String, expected: DoryMachineSnapshotArtifact,
             hash: (Int32) throws -> String) throws {
            let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else { throw MachineManagerError.persistence("could not open clone publication") }
            var retained = false
            defer { if !retained { close(descriptor) } }
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw MachineManagerError.persistence("could not inspect clone publication") }
            let identity = try Identity(info)
            guard UInt64(identity.size) == expected.byteCount,
                  try hash(descriptor) == expected.sha256 else {
                throw MachineManagerError.persistence("clone publication differs from immutable source artifacts")
            }
            var after = stat()
            var named = stat()
            guard fstat(descriptor, &after) == 0, lstat(path, &named) == 0,
                  try Identity(after) == identity, try Identity(named) == identity else {
                throw MachineManagerError.persistence("clone artifact changed during content verification")
            }
            self.path = path; self.expected = expected; self.descriptor = descriptor; self.identity = identity
            retained = true
        }

        func validate() throws {
            var opened = stat()
            var named = stat()
            guard fstat(descriptor, &opened) == 0, lstat(path, &named) == 0,
                  try Identity(opened) == identity, try Identity(named) == identity else {
                throw MachineManagerError.persistence("clone artifact changed after its content verification")
            }
        }

        deinit { close(descriptor) }
    }

    private let rootfs: File
    private let kernel: File

    init(configuration: DoryMachineConfiguration, evidence: DoryMachineSnapshotArtifactEvidence,
         hash: (Int32) throws -> String) throws {
        rootfs = try File(path: configuration.rootfsPath, expected: evidence.rootfs, hash: hash)
        kernel = try File(path: configuration.kernelPath, expected: evidence.kernel, hash: hash)
        try validate(configuration: configuration, evidence: evidence)
    }

    func validate(configuration: DoryMachineConfiguration, evidence: DoryMachineSnapshotArtifactEvidence) throws {
        guard rootfs.path == configuration.rootfsPath, kernel.path == configuration.kernelPath,
              rootfs.expected == evidence.rootfs, kernel.expected == evidence.kernel else {
            throw MachineManagerError.persistence("clone artifact proof belongs to another publication")
        }
        try rootfs.validate()
        try kernel.validate()
    }
}
