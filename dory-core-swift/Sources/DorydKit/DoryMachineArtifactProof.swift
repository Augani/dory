import Darwin
import Foundation

/// Ephemeral evidence for repeated checks under one exclusive mutation context. This cannot be
/// decoded from a journal: acquiring a new context must verify the complete artifacts again.
final class DoryMachineArtifactProof {
    struct Binding: Equatable {
        let path: String
        let evidence: DoryMachineSnapshotArtifact
    }

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
                throw MachineManagerError.persistence("artifact is not a private owned regular file")
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
            guard descriptor >= 0 else { throw MachineManagerError.persistence("could not open verified artifact") }
            var retained = false
            defer { if !retained { close(descriptor) } }
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw MachineManagerError.persistence("could not inspect verified artifact") }
            let identity = try Identity(info)
            guard UInt64(identity.size) == expected.byteCount,
                  try hash(descriptor) == expected.sha256 else {
                throw MachineManagerError.persistence("artifact differs from immutable evidence")
            }
            var after = stat()
            var named = stat()
            guard fstat(descriptor, &after) == 0, lstat(path, &named) == 0,
                  try Identity(after) == identity, try Identity(named) == identity else {
                throw MachineManagerError.persistence("artifact changed during content verification")
            }
            self.path = path; self.expected = expected; self.descriptor = descriptor; self.identity = identity
            retained = true
        }

        func validate() throws {
            var opened = stat()
            var named = stat()
            guard fstat(descriptor, &opened) == 0, lstat(path, &named) == 0,
                  try Identity(opened) == identity, try Identity(named) == identity else {
                throw MachineManagerError.persistence("artifact changed after its content verification")
            }
        }

        deinit { close(descriptor) }
    }

    private let bindings: [Binding]
    private let files: [File]

    init(bindings: [Binding], hash: (Int32) throws -> String) throws {
        guard !bindings.isEmpty, Set(bindings.map(\.path)).count == bindings.count else {
            throw MachineManagerError.persistence("artifact proof requires distinct bound paths")
        }
        self.bindings = bindings
        files = try bindings.map { try File(path: $0.path, expected: $0.evidence, hash: hash) }
        try validate(bindings: bindings)
    }

    convenience init(configuration: DoryMachineConfiguration, evidence: DoryMachineSnapshotArtifactEvidence,
         hash: (Int32) throws -> String) throws {
        try self.init(bindings: Self.bindings(configuration: configuration, evidence: evidence), hash: hash)
    }

    func validate(bindings: [Binding]) throws {
        guard self.bindings == bindings else {
            throw MachineManagerError.persistence("artifact proof belongs to another publication")
        }
        for file in files { try file.validate() }
    }

    func validate(configuration: DoryMachineConfiguration, evidence: DoryMachineSnapshotArtifactEvidence) throws {
        try validate(bindings: Self.bindings(configuration: configuration, evidence: evidence))
    }

    private static func bindings(configuration: DoryMachineConfiguration,
        evidence: DoryMachineSnapshotArtifactEvidence) -> [Binding] {
        [.init(path: configuration.rootfsPath, evidence: evidence.rootfs),
         .init(path: configuration.kernelPath, evidence: evidence.kernel)]
    }
}
