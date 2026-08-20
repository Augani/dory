import CryptoKit
import Darwin
import Foundation

public enum DoryVirtualMachineArtifactAuthorityError:
    Error, Sendable, Equatable, CustomStringConvertible
{
    case invalidReference
    case invalidPath
    case insecureArtifact
    case artifactMissing
    case artifactChanged
    case staleRevision(expected: UInt64, actual: UInt64)
    case invalidRecord
    case filesystem(String)

    public var description: String {
        switch self {
        case .invalidReference: "artifact resolver reference is invalid"
        case .invalidPath: "artifact path must be absolute and canonical"
        case .insecureArtifact: "artifact must be a private owner-controlled single-link file"
        case .artifactMissing: "artifact authority record does not exist"
        case .artifactChanged: "artifact bytes or file identity changed after publication"
        case let .staleRevision(expected, actual):
            "stale artifact revision: expected \(expected), found \(actual)"
        case .invalidRecord: "artifact authority record is invalid or tampered"
        case let .filesystem(message): message
        }
    }
}

public enum DoryVirtualMachineArtifactIdentity: Codable, Sendable, Equatable, Hashable {
    case immutable(sha256: String, byteCount: UInt64)
    case mutable(
        provenance: DoryMutableBootMediaProvenanceReference,
        sha256: String,
        byteCount: UInt64,
        device: UInt64,
        inode: UInt64,
        modifiedSeconds: Int64,
        modifiedNanoseconds: Int64,
        changedSeconds: Int64,
        changedNanoseconds: Int64
    )
}

/// Daemon-private durable mapping. Host paths intentionally remain outside WorkspaceSpec and the
/// public API, while the exact non-secret identity is copied into resolved launch evidence.
public struct DoryVirtualMachineArtifactAuthorityRecord: Codable, Sendable, Equatable {
    public static let schemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var reference: DoryVMResolverReference
    public var path: String
    public var kind: DoryBootMediaKind
    public var source: DoryBootMediaSource
    public var identity: DoryVirtualMachineArtifactIdentity
    public var authorityRevision: UInt64

    public init(
        reference: DoryVMResolverReference,
        path: String,
        kind: DoryBootMediaKind,
        source: DoryBootMediaSource,
        identity: DoryVirtualMachineArtifactIdentity,
        authorityRevision: UInt64
    ) {
        schemaVersion = Self.schemaVersion
        self.reference = reference
        self.path = path
        self.kind = kind
        self.source = source
        self.identity = identity
        self.authorityRevision = authorityRevision
    }
}

public struct DoryVerifiedVirtualMachineArtifact: Sendable {
    public let reference: DoryVMResolverReference
    public let path: String
    public let media: DoryBootMedia
    public let authorityRevision: UInt64
    public let mutableProvenance: DoryTrustedMutableBootMediaProvenance?

    fileprivate init(record: DoryVirtualMachineArtifactAuthorityRecord) {
        reference = record.reference
        path = record.path
        authorityRevision = record.authorityRevision
        switch record.identity {
        case let .immutable(sha256, _):
            media = DoryBootMedia(
                kind: record.kind,
                source: record.source,
                artifactSHA256: sha256
            )
            mutableProvenance = nil
        case let .mutable(provenance, _, _, _, _, _, _, _, _):
            let evidence = DoryMutableBootMediaProvenanceAuditEvidence(
                receiptIdentity: "dory-artifact-authority:\(record.reference.namespace):"
                    + "\(record.reference.identifier):\(provenance.revision)",
                provenance: provenance,
                receiptSHA256: Self.digest(Self.canonicalData(record)),
                resolverID: DoryVirtualMachineArtifactAuthority.resolverID,
                resolverVersion: DoryVirtualMachineArtifactAuthority.resolverVersion
            )
            media = DoryBootMedia(
                kind: record.kind,
                source: record.source,
                mutableProvenance: provenance
            )
            mutableProvenance = DoryTrustedMutableBootMediaProvenance(
                auditEvidence: evidence
            )
        }
    }

    private static func canonicalData<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)) ?? Data()
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Crash-safe daemon authority for path-hostile workspace references. Every artifact, including a
/// mutable disk revision, is rehashed on resolution. Mutable disks require an explicit publication
/// after any write; changed bytes are rejected instead of silently advancing provenance at start.
///
/// A successful resolution is a point-in-time verification snapshot. A launcher must still close
/// the path/exec TOCTOU window with descriptor-bound or immediate pre-spawn verification.
public final class DoryVirtualMachineArtifactAuthority: @unchecked Sendable {
    public static let resolverID = "dory.artifact-authority"
    public static let resolverVersion: UInt16 = 1

    private static let maximumRecordBytes = 1 * 1_024 * 1_024
    private static let temporaryPrefix = ".artifact-authority."
    private static let lockFilename = ".artifact-authority.lock"

    public let root: String
    private let lock = NSLock()
    private let publicationFaultInjector: (@Sendable (PublicationStage) throws -> Void)?
    private let inspectionProgressInjector: (@Sendable (InspectionStage) throws -> Void)?

    enum PublicationStage: Sendable {
        case temporaryFileSynced
    }

    enum InspectionStage: Sendable {
        case firstChunkHashed(path: String)
    }

    public init(root: String) {
        self.root = URL(fileURLWithPath: root).standardizedFileURL.path
        publicationFaultInjector = nil
        inspectionProgressInjector = nil
    }

    init(
        root: String,
        publicationFaultInjector: @escaping @Sendable (PublicationStage) throws -> Void
    ) {
        self.root = URL(fileURLWithPath: root).standardizedFileURL.path
        self.publicationFaultInjector = publicationFaultInjector
        inspectionProgressInjector = nil
    }

    init(
        root: String,
        inspectionProgressInjector: @escaping @Sendable (InspectionStage) throws -> Void
    ) {
        self.root = URL(fileURLWithPath: root).standardizedFileURL.path
        publicationFaultInjector = nil
        self.inspectionProgressInjector = inspectionProgressInjector
    }

    @discardableResult
    public func publishImmutable(
        reference: DoryVMResolverReference,
        path: String,
        kind: DoryBootMediaKind,
        source: DoryBootMediaSource,
        expectedAuthorityRevision: UInt64? = nil
    ) throws -> DoryVerifiedVirtualMachineArtifact {
        try withExclusiveAccess {
            let path = try Self.validatedPath(path)
            let file = try Self.inspect(
                path,
                hashContents: true,
                progressInjector: inspectionProgressInjector
            )
            let current = try readIfPresent(reference)
            try Self.validateExpectedRevision(expectedAuthorityRevision, current: current)
            let revision = try Self.nextRevision(current)
            let record = DoryVirtualMachineArtifactAuthorityRecord(
                reference: reference,
                path: path,
                kind: kind,
                source: source,
                identity: .immutable(
                    sha256: try Self.requiredDigest(file),
                    byteCount: file.byteCount
                ),
                authorityRevision: revision
            )
            try publish(record)
            return DoryVerifiedVirtualMachineArtifact(record: record)
        }
    }

    @discardableResult
    public func publishMutable(
        reference: DoryVMResolverReference,
        path: String,
        kind: DoryBootMediaKind = .virtualDisk,
        source: DoryBootMediaSource,
        expectedAuthorityRevision: UInt64? = nil
    ) throws -> DoryVerifiedVirtualMachineArtifact {
        try withExclusiveAccess {
            guard kind == .virtualDisk else {
                throw DoryVirtualMachineArtifactAuthorityError.invalidRecord
            }
            let path = try Self.validatedPath(path)
            let file = try Self.inspect(
                path,
                hashContents: true,
                progressInjector: inspectionProgressInjector
            )
            let current = try readIfPresent(reference)
            try Self.validateExpectedRevision(expectedAuthorityRevision, current: current)
            let revision = try Self.nextRevision(current)
            let provenance = DoryMutableBootMediaProvenanceReference(
                repositoryIdentity: Self.digest(Data(root.utf8)),
                mediaIdentity: Self.referenceIdentity(reference),
                revision: revision
            )
            let record = DoryVirtualMachineArtifactAuthorityRecord(
                reference: reference,
                path: path,
                kind: kind,
                source: source,
                identity: .mutable(
                    provenance: provenance,
                    sha256: try Self.requiredDigest(file),
                    byteCount: file.byteCount,
                    device: file.device,
                    inode: file.inode,
                    modifiedSeconds: file.modifiedSeconds,
                    modifiedNanoseconds: file.modifiedNanoseconds,
                    changedSeconds: file.changedSeconds,
                    changedNanoseconds: file.changedNanoseconds
                ),
                authorityRevision: revision
            )
            try publish(record)
            return DoryVerifiedVirtualMachineArtifact(record: record)
        }
    }

    public func resolve(
        reference: DoryVMResolverReference,
        kind: DoryBootMediaKind,
        source: DoryBootMediaSource
    ) throws -> DoryVerifiedVirtualMachineArtifact {
        try withExclusiveAccess {
            guard let record = try readIfPresent(reference) else {
                throw DoryVirtualMachineArtifactAuthorityError.artifactMissing
            }
            guard record.kind == kind, record.source == source else {
                throw DoryVirtualMachineArtifactAuthorityError.invalidRecord
            }
            let file: InspectedFile
            switch record.identity {
            case .immutable:
                file = try Self.inspect(
                    record.path,
                    hashContents: true,
                    progressInjector: inspectionProgressInjector
                )
            case .mutable:
                file = try Self.inspect(
                    record.path,
                    hashContents: true,
                    progressInjector: inspectionProgressInjector
                )
            }
            guard Self.file(file, matches: record.identity) else {
                throw DoryVirtualMachineArtifactAuthorityError.artifactChanged
            }
            return DoryVerifiedVirtualMachineArtifact(record: record)
        }
    }

    /// Returns daemon-private publication metadata for optimistic reconciliation. This does not
    /// verify current artifact bytes and therefore never returns an opaque trusted receipt.
    public func authorityRecord(
        reference: DoryVMResolverReference
    ) throws -> DoryVirtualMachineArtifactAuthorityRecord? {
        try withExclusiveAccess { try readIfPresent(reference) }
    }

    private func publish(_ record: DoryVirtualMachineArtifactAuthorityRecord) throws {
        try validate(record)
        let directory = root
        try Self.ensurePrivateDirectory(directory)
        let path = recordPath(record.reference)
        let envelope = RecordEnvelope(
            recordSHA256: Self.digest(Self.canonicalData(record)),
            record: record
        )
        let data = Self.canonicalData(envelope) + Data("\n".utf8)
        let temporary = directory + "/\(Self.temporaryPrefix)\(UUID().uuidString)"
        let descriptor = temporary.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            throw DoryVirtualMachineArtifactAuthorityError.filesystem(
                "create artifact authority record: errno \(errno)"
            )
        }
        var descriptorIsOpen = true
        do {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(
                        descriptor,
                        bytes.baseAddress!.advanced(by: offset),
                        bytes.count - offset
                    )
                    guard count > 0 else {
                        throw DoryVirtualMachineArtifactAuthorityError.filesystem(
                            "write artifact authority record: errno \(errno)"
                        )
                    }
                    offset += count
                }
            }
            guard fsync(descriptor) == 0 else {
                throw DoryVirtualMachineArtifactAuthorityError.filesystem(
                    "sync artifact authority record: errno \(errno)"
                )
            }
            close(descriptor)
            descriptorIsOpen = false
            try publicationFaultInjector?(.temporaryFileSynced)
            guard rename(temporary, path) == 0 else {
                throw DoryVirtualMachineArtifactAuthorityError.filesystem(
                    "publish artifact authority record: errno \(errno)"
                )
            }
            try Self.syncDirectory(directory)
        } catch {
            if descriptorIsOpen { close(descriptor) }
            unlink(temporary)
            throw error
        }
    }

    private func readIfPresent(
        _ reference: DoryVMResolverReference
    ) throws -> DoryVirtualMachineArtifactAuthorityRecord? {
        try Self.validate(reference)
        let path = recordPath(reference)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let descriptor = path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else {
            throw DoryVirtualMachineArtifactAuthorityError.invalidRecord
        }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              status.st_nlink == 1,
              status.st_mode & 0o077 == 0,
              status.st_size > 0,
              status.st_size <= Self.maximumRecordBytes else {
            throw DoryVirtualMachineArtifactAuthorityError.invalidRecord
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0, data.count + count <= Self.maximumRecordBytes else {
                throw DoryVirtualMachineArtifactAuthorityError.invalidRecord
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard let envelope = try? JSONDecoder().decode(RecordEnvelope.self, from: data),
              data == Self.canonicalData(envelope) + Data("\n".utf8),
              envelope.recordSHA256 == Self.digest(Self.canonicalData(envelope.record)),
              envelope.record.reference == reference else {
            throw DoryVirtualMachineArtifactAuthorityError.invalidRecord
        }
        try validate(envelope.record)
        return envelope.record
    }

    private func recordPath(_ reference: DoryVMResolverReference) -> String {
        root + "/" + Self.referenceIdentity(reference) + ".json"
    }

    private struct RecordEnvelope: Codable {
        var recordSHA256: String
        var record: DoryVirtualMachineArtifactAuthorityRecord
    }

    private struct InspectedFile {
        var byteCount: UInt64
        var device: UInt64
        var inode: UInt64
        var modifiedSeconds: Int64
        var modifiedNanoseconds: Int64
        var changedSeconds: Int64
        var changedNanoseconds: Int64
        var sha256: String?
    }

    private static func inspect(
        _ path: String,
        hashContents: Bool,
        progressInjector: (@Sendable (InspectionStage) throws -> Void)?
    ) throws -> InspectedFile {
        let descriptor = path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else {
            throw DoryVirtualMachineArtifactAuthorityError.insecureArtifact
        }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              isPrivateArtifact(before) else {
            throw DoryVirtualMachineArtifactAuthorityError.insecureArtifact
        }
        var digest: String?
        if hashContents {
            var hasher = SHA256()
            var buffer = [UInt8](repeating: 0, count: 1 * 1_024 * 1_024)
            var reportedProgress = false
            while true {
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(descriptor, $0.baseAddress, $0.count)
                }
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else {
                    throw DoryVirtualMachineArtifactAuthorityError.artifactChanged
                }
                if count == 0 { break }
                hasher.update(data: Data(buffer.prefix(count)))
                if !reportedProgress {
                    reportedProgress = true
                    try progressInjector?(.firstChunkHashed(path: path))
                }
            }
            digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              isPrivateArtifact(after),
              sameArtifactSnapshot(before, after) else {
            throw DoryVirtualMachineArtifactAuthorityError.artifactChanged
        }
        return InspectedFile(
            byteCount: UInt64(after.st_size),
            device: UInt64(after.st_dev),
            inode: UInt64(after.st_ino),
            modifiedSeconds: Int64(after.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(after.st_mtimespec.tv_nsec),
            changedSeconds: Int64(after.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(after.st_ctimespec.tv_nsec),
            sha256: digest
        )
    }

    private static func isPrivateArtifact(_ status: stat) -> Bool {
        status.st_mode & S_IFMT == S_IFREG
            && status.st_uid == geteuid()
            && status.st_nlink == 1
            && status.st_mode & 0o077 == 0
            && status.st_size > 0
    }

    private static func sameArtifactSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func file(
        _ file: InspectedFile,
        matches identity: DoryVirtualMachineArtifactIdentity
    ) -> Bool {
        switch identity {
        case let .immutable(sha256, byteCount):
            return file.byteCount == byteCount && file.sha256 == sha256
        case let .mutable(
            _, sha256, byteCount, device, inode, modifiedSeconds, modifiedNanoseconds,
            changedSeconds, changedNanoseconds
        ):
            return file.byteCount == byteCount
                && file.sha256 == sha256
                && file.device == device
                && file.inode == inode
                && file.modifiedSeconds == modifiedSeconds
                && file.modifiedNanoseconds == modifiedNanoseconds
                && file.changedSeconds == changedSeconds
                && file.changedNanoseconds == changedNanoseconds
        }
    }

    private static func requiredDigest(_ file: InspectedFile) throws -> String {
        guard let digest = file.sha256 else {
            throw DoryVirtualMachineArtifactAuthorityError.artifactChanged
        }
        return digest
    }

    private static func validatedPath(_ value: String) throws -> String {
        guard value.hasPrefix("/"), !value.contains("\0") else {
            throw DoryVirtualMachineArtifactAuthorityError.invalidPath
        }
        let standardized = URL(fileURLWithPath: value).standardizedFileURL.path
        guard standardized == value, standardized != "/" else {
            throw DoryVirtualMachineArtifactAuthorityError.invalidPath
        }
        return standardized
    }

    private static func validate(_ reference: DoryVMResolverReference) throws {
        guard reference.isValidForPersistence else {
            throw DoryVirtualMachineArtifactAuthorityError.invalidReference
        }
    }

    private func validate(_ record: DoryVirtualMachineArtifactAuthorityRecord) throws {
        try Self.validate(record.reference)
        guard record.schemaVersion == DoryVirtualMachineArtifactAuthorityRecord.schemaVersion,
              record.authorityRevision > 0,
              (try? Self.validatedPath(record.path)) == record.path else {
            throw DoryVirtualMachineArtifactAuthorityError.invalidRecord
        }
        switch record.identity {
        case let .immutable(sha256, byteCount):
            guard Self.isSHA256(sha256), byteCount > 0 else {
                throw DoryVirtualMachineArtifactAuthorityError.invalidRecord
            }
        case let .mutable(provenance, sha256, byteCount, _, _, _, _, _, _):
            guard record.kind == .virtualDisk,
                  byteCount > 0,
                  Self.isSHA256(sha256),
                  provenance.revision == record.authorityRevision,
                  provenance.mediaIdentity == Self.referenceIdentity(record.reference),
                  provenance.repositoryIdentity == Self.digest(Data(root.utf8)) else {
                throw DoryVirtualMachineArtifactAuthorityError.invalidRecord
            }
        }
    }

    private static func validateExpectedRevision(
        _ expected: UInt64?,
        current: DoryVirtualMachineArtifactAuthorityRecord?
    ) throws {
        guard let expected else {
            guard current == nil else {
                throw DoryVirtualMachineArtifactAuthorityError.staleRevision(
                    expected: 0,
                    actual: current!.authorityRevision
                )
            }
            return
        }
        let actual = current?.authorityRevision ?? 0
        guard expected == actual else {
            throw DoryVirtualMachineArtifactAuthorityError.staleRevision(
                expected: expected,
                actual: actual
            )
        }
    }

    private static func nextRevision(
        _ current: DoryVirtualMachineArtifactAuthorityRecord?
    ) throws -> UInt64 {
        guard let current else { return 1 }
        guard current.authorityRevision < UInt64.max else {
            throw DoryVirtualMachineArtifactAuthorityError.invalidRecord
        }
        return current.authorityRevision + 1
    }

    private static func referenceIdentity(_ reference: DoryVMResolverReference) -> String {
        digest(Data("\(reference.namespace)\u{0}\(reference.identifier)".utf8))
    }

    private static func canonicalData<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)) ?? Data()
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...70).contains(byte)
                || (97...102).contains(byte)
        }
    }

    private static func ensurePrivateDirectory(_ path: String) throws {
        if mkdir(path, mode_t(0o700)) != 0, errno != EEXIST {
            throw DoryVirtualMachineArtifactAuthorityError.filesystem(
                "create artifact authority directory: errno \(errno)"
            )
        }
        var status = stat()
        guard lstat(path, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid(),
              status.st_mode & 0o077 == 0 else {
            throw DoryVirtualMachineArtifactAuthorityError.filesystem(
                "artifact authority directory is not private"
            )
        }
    }

    private static func syncDirectory(_ path: String) throws {
        let descriptor = path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw DoryVirtualMachineArtifactAuthorityError.filesystem(
                "open artifact authority directory: errno \(errno)"
            )
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw DoryVirtualMachineArtifactAuthorityError.filesystem(
                "sync artifact authority directory: errno \(errno)"
            )
        }
    }

    private func withExclusiveAccess<T>(_ body: () throws -> T) throws -> T {
        try lock.withLock {
            try Self.ensurePrivateDirectory(root)
            let lockPath = root + "/" + Self.lockFilename
            let descriptor = lockPath.withCString {
                open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
            }
            guard descriptor >= 0 else {
                throw DoryVirtualMachineArtifactAuthorityError.filesystem(
                    "open artifact authority lock: errno \(errno)"
                )
            }
            defer { close(descriptor) }
            var status = stat()
            guard fstat(descriptor, &status) == 0,
                  status.st_mode & S_IFMT == S_IFREG,
                  status.st_uid == geteuid(),
                  status.st_nlink == 1,
                  status.st_mode & 0o077 == 0 else {
                throw DoryVirtualMachineArtifactAuthorityError.filesystem(
                    "artifact authority lock is not private"
                )
            }
            while flock(descriptor, LOCK_EX) != 0 {
                guard errno == EINTR else {
                    throw DoryVirtualMachineArtifactAuthorityError.filesystem(
                        "lock artifact authority: errno \(errno)"
                    )
                }
            }
            defer { _ = flock(descriptor, LOCK_UN) }
            return try body()
        }
    }
}
