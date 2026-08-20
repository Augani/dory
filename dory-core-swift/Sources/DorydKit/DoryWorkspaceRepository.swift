import CryptoKit
import Darwin
import DoryOperations
import Foundation

public enum DoryWorkspaceRepositoryError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidIdentifier(String)
    case invalidDefinition([DoryVMDefinitionValidationIssue])
    case workspaceExists(String)
    case workspaceNotFound(String)
    case staleRevision(expected: UInt64, actual: UInt64)
    case invalidRevision(expected: UInt64, actual: UInt64)
    case identityChanged(String)
    case legacyAuthorityRequired(String)
    case staleLegacyProjection(String)
    case invalidRecord(String)
    case filesystem(String)

    public var description: String {
        switch self {
        case let .invalidIdentifier(id):
            return "invalid workspace identifier: \(id)"
        case let .invalidDefinition(issues):
            return "invalid workspace definition: "
                + issues.map { "\($0.code.rawValue) at \($0.field)" }.joined(separator: ", ")
        case let .workspaceExists(id):
            return "workspace already exists: \(id)"
        case let .workspaceNotFound(id):
            return "workspace does not exist: \(id)"
        case let .staleRevision(expected, actual):
            return "stale workspace revision: expected \(expected), found \(actual)"
        case let .invalidRevision(expected, actual):
            return "invalid replacement workspace revision: expected \(expected), found \(actual)"
        case let .identityChanged(id):
            return "workspace identity cannot change during replacement: \(id)"
        case let .legacyAuthorityRequired(id):
            return "workspace \(id) is a legacy projection and requires authoritative legacy bytes"
        case let .staleLegacyProjection(id):
            return "workspace \(id) does not match the authoritative legacy configuration"
        case let .invalidRecord(path):
            return "invalid workspace repository record: \(path)"
        case let .filesystem(message):
            return message
        }
    }
}

/// One durable desired-state record.
///
/// During migration, `legacyConfigurationSHA256` binds the v2 definition to the exact raw
/// `DoryMachineConfiguration` bytes that remain authoritative. Once all consumers use the v2
/// contract, authoritative records omit this digest and use optimistic lifecycle revisions.
public struct DoryWorkspaceRepositoryRecord: Codable, Sendable, Equatable {
    public static let schemaVersion: UInt16 = 1

    public let schemaVersion: UInt16
    public let legacyConfigurationSHA256: String?
    /// Digest of canonical non-lifecycle facts used by the legacy migration bridge. Raw metadata
    /// alone is insufficient because artifact inspection can change the boot contract in place.
    public let legacyMigrationFactsSHA256: String?
    public let definition: DoryVirtualMachineDefinition

    public init(
        definition: DoryVirtualMachineDefinition,
        legacyConfigurationSHA256: String? = nil,
        legacyMigrationFactsSHA256: String? = nil
    ) {
        schemaVersion = Self.schemaVersion
        self.legacyConfigurationSHA256 = legacyConfigurationSHA256
        self.legacyMigrationFactsSHA256 = legacyMigrationFactsSHA256
        self.definition = definition
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case legacyConfigurationSHA256
        case legacyMigrationFactsSHA256
        case definition
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(UInt16.self, forKey: .schemaVersion)
        legacyConfigurationSHA256 = try container.decodeIfPresent(
            String.self,
            forKey: .legacyConfigurationSHA256
        )
        // Records written before facts became part of legacy authority do not contain this key.
        legacyMigrationFactsSHA256 = try container.decodeIfPresent(
            String.self,
            forKey: .legacyMigrationFactsSHA256
        )
        definition = try container.decode(
            DoryVirtualMachineDefinition.self,
            forKey: .definition
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encodeIfPresent(
            legacyConfigurationSHA256,
            forKey: .legacyConfigurationSHA256
        )
        try container.encodeIfPresent(
            legacyMigrationFactsSHA256,
            forKey: .legacyMigrationFactsSHA256
        )
        try container.encode(definition, forKey: .definition)
    }
}

public enum DoryWorkspaceLegacyProjectionReconcileState: String, Sendable, Equatable {
    case unchanged
    case published
}

public struct DoryWorkspaceLegacyProjectionReconcileResult: Sendable, Equatable {
    public let state: DoryWorkspaceLegacyProjectionReconcileState
    public let definition: DoryVirtualMachineDefinition

    public init(
        state: DoryWorkspaceLegacyProjectionReconcileState,
        definition: DoryVirtualMachineDefinition
    ) {
        self.state = state
        self.definition = definition
    }
}

/// Crash-safe persistence for versioned workspace desired state.
///
/// Records live beside the existing machine artifacts, use owner-only files, reject links, and
/// publish through a fully written and fsynced temporary file. The repository never persists host
/// paths or credentials because `DoryVirtualMachineDefinition` contains resolver references only.
public final class DoryWorkspaceRepository: @unchecked Sendable {
    public static let recordFileName = "workspace-v2.json"

    private static let temporaryPrefix = ".workspace-v2."
    private static let maximumRecordBytes = 16 * 1_024 * 1_024

    public let root: String
    private let lock = NSLock()

    public init(root: String) {
        self.root = URL(fileURLWithPath: root).standardizedFileURL.path
    }

    public func create(_ definition: DoryVirtualMachineDefinition) throws {
        lock.lock()
        defer { lock.unlock() }
        try Self.validate(definition)
        guard definition.lifecycle.revision == 1 else {
            throw DoryWorkspaceRepositoryError.invalidRevision(
                expected: 1,
                actual: definition.lifecycle.revision
            )
        }
        let path = try prepareWorkspaceDirectory(id: definition.identity.id)
            + "/\(Self.recordFileName)"
        guard !Self.pathExists(path) else {
            throw DoryWorkspaceRepositoryError.workspaceExists(definition.identity.id)
        }
        try publish(
            DoryWorkspaceRepositoryRecord(definition: definition),
            path: path,
            replacing: false
        )
    }

    public func replace(
        _ definition: DoryVirtualMachineDefinition,
        expectedRevision: UInt64
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        try Self.validate(definition)
        let current = try readRecordUnlocked(id: definition.identity.id)
        guard current.legacyConfigurationSHA256 == nil else {
            throw DoryWorkspaceRepositoryError.legacyAuthorityRequired(definition.identity.id)
        }
        guard current.definition.lifecycle.revision == expectedRevision else {
            throw DoryWorkspaceRepositoryError.staleRevision(
                expected: expectedRevision,
                actual: current.definition.lifecycle.revision
            )
        }
        guard expectedRevision < UInt64.max,
              definition.lifecycle.revision == expectedRevision + 1 else {
            throw DoryWorkspaceRepositoryError.invalidRevision(
                expected: expectedRevision == UInt64.max ? UInt64.max : expectedRevision + 1,
                actual: definition.lifecycle.revision
            )
        }
        guard definition.identity.id == current.definition.identity.id,
              definition.lifecycle.createdAtUnixMilliseconds
                == current.definition.lifecycle.createdAtUnixMilliseconds else {
            throw DoryWorkspaceRepositoryError.identityChanged(definition.identity.id)
        }
        let path = recordPath(id: definition.identity.id)
        try publish(
            DoryWorkspaceRepositoryRecord(definition: definition),
            path: path,
            replacing: true
        )
    }

    /// Publish a deterministic v2 projection while legacy machine metadata remains authoritative.
    /// A crash on either side of the two-file migration is detected by the bound digest and can be
    /// repaired by projecting the authoritative legacy record again.
    public func publishLegacyProjection(
        _ definition: DoryVirtualMachineDefinition,
        authoritativeLegacyData: Data
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        try Self.validate(definition)
        guard !authoritativeLegacyData.isEmpty else {
            throw DoryWorkspaceRepositoryError.staleLegacyProjection(definition.identity.id)
        }
        let directory = try prepareWorkspaceDirectory(id: definition.identity.id)
        let path = directory + "/\(Self.recordFileName)"
        let replacing = Self.pathExists(path)
        if replacing {
            let current = try readRecordUnlocked(id: definition.identity.id)
            guard current.legacyConfigurationSHA256 != nil else {
                throw DoryWorkspaceRepositoryError.legacyAuthorityRequired(definition.identity.id)
            }
            // This compatibility API cannot validate facts-bound projections. Require callers to
            // use reconcileLegacyProjection rather than silently dropping half the authority.
            guard current.legacyMigrationFactsSHA256 == nil else {
                throw DoryWorkspaceRepositoryError.staleLegacyProjection(definition.identity.id)
            }
            guard current.definition.lifecycle.revision < UInt64.max,
                  definition.lifecycle.revision
                    == current.definition.lifecycle.revision + 1 else {
                throw DoryWorkspaceRepositoryError.invalidRevision(
                    expected: current.definition.lifecycle.revision == UInt64.max
                        ? UInt64.max : current.definition.lifecycle.revision + 1,
                    actual: definition.lifecycle.revision
                )
            }
            guard definition.identity.id == current.definition.identity.id,
                  definition.lifecycle.createdAtUnixMilliseconds
                    == current.definition.lifecycle.createdAtUnixMilliseconds else {
                throw DoryWorkspaceRepositoryError.identityChanged(definition.identity.id)
            }
        } else {
            guard definition.lifecycle.revision == 1 else {
                throw DoryWorkspaceRepositoryError.invalidRevision(
                    expected: 1,
                    actual: definition.lifecycle.revision
                )
            }
        }
        let record = DoryWorkspaceRepositoryRecord(
            definition: definition,
            legacyConfigurationSHA256: Self.sha256(authoritativeLegacyData)
        )
        try publish(
            record,
            path: path,
            replacing: replacing
        )
    }

    /// Atomically reconcile a derived legacy projection and its two-part authority tuple.
    ///
    /// An exact metadata+facts restart does not rewrite or bump. Any changed bytes, changed facts,
    /// or changed derived definition advances the revision while retaining `createdAt`. Invalid
    /// projections can be regenerated, but a native v2 record is never overwritten by legacy.
    public func reconcileLegacyProjection(
        _ candidate: DoryVirtualMachineDefinition,
        authoritativeLegacyData: Data,
        authoritativeMigrationFactsData: Data
    ) throws -> DoryWorkspaceLegacyProjectionReconcileResult {
        lock.lock()
        defer { lock.unlock() }
        try Self.validate(candidate)
        guard !authoritativeLegacyData.isEmpty, !authoritativeMigrationFactsData.isEmpty else {
            throw DoryWorkspaceRepositoryError.staleLegacyProjection(candidate.identity.id)
        }

        let directory = try prepareWorkspaceDirectory(id: candidate.identity.id)
        let path = directory + "/\(Self.recordFileName)"
        let legacyDigest = Self.sha256(authoritativeLegacyData)
        let factsDigest = Self.sha256(authoritativeMigrationFactsData)
        let pathExists = Self.pathExists(path)
        let current: DoryWorkspaceRepositoryRecord?
        if pathExists {
            do {
                current = try readRecordUnlocked(id: candidate.identity.id)
            } catch {
                // A damaged legacy-derived projection is disposable and can be recreated from
                // authority. Native v2 state and ambiguous damage must never be overwritten.
                guard try Self.hasRecoverableLegacyAuthorityMarker(path: path) else {
                    throw error
                }
                current = nil
            }
        } else {
            current = nil
        }

        if let current {
            guard current.legacyConfigurationSHA256 != nil else {
                throw DoryWorkspaceRepositoryError.legacyAuthorityRequired(candidate.identity.id)
            }
            var sameLifecycleCandidate = candidate
            sameLifecycleCandidate.lifecycle = current.definition.lifecycle
            if current.legacyConfigurationSHA256 == legacyDigest,
               current.legacyMigrationFactsSHA256 == factsDigest,
               current.definition == sameLifecycleCandidate {
                return DoryWorkspaceLegacyProjectionReconcileResult(
                    state: .unchanged,
                    definition: current.definition
                )
            }
            guard current.definition.lifecycle.revision < UInt64.max else {
                throw DoryWorkspaceRepositoryError.invalidRevision(
                    expected: UInt64.max,
                    actual: UInt64.max
                )
            }
            var replacement = candidate
            replacement.lifecycle = DoryVMLifecycleMetadata(
                revision: current.definition.lifecycle.revision + 1,
                createdAtUnixMilliseconds: current.definition.lifecycle.createdAtUnixMilliseconds,
                updatedAtUnixMilliseconds: Self.nextUpdatedTimestamp(
                    previous: current.definition.lifecycle.updatedAtUnixMilliseconds,
                    proposed: candidate.lifecycle.updatedAtUnixMilliseconds
                )
            )
            try Self.validate(replacement)
            let record = DoryWorkspaceRepositoryRecord(
                definition: replacement,
                legacyConfigurationSHA256: legacyDigest,
                legacyMigrationFactsSHA256: factsDigest
            )
            try publish(record, path: path, replacing: true)
            return DoryWorkspaceLegacyProjectionReconcileResult(
                state: .published,
                definition: replacement
            )
        }

        guard candidate.lifecycle.revision == 1 else {
            throw DoryWorkspaceRepositoryError.invalidRevision(
                expected: 1,
                actual: candidate.lifecycle.revision
            )
        }
        let record = DoryWorkspaceRepositoryRecord(
            definition: candidate,
            legacyConfigurationSHA256: legacyDigest,
            legacyMigrationFactsSHA256: factsDigest
        )
        try publish(record, path: path, replacing: pathExists)
        return DoryWorkspaceLegacyProjectionReconcileResult(
            state: .published,
            definition: candidate
        )
    }

    public func read(id: String) throws -> DoryVirtualMachineDefinition {
        lock.lock()
        defer { lock.unlock() }
        let record = try readRecordUnlocked(id: id)
        guard record.legacyConfigurationSHA256 == nil else {
            throw DoryWorkspaceRepositoryError.legacyAuthorityRequired(id)
        }
        return record.definition
    }

    /// Reads the validated durable repository envelope without promoting a legacy projection to
    /// native desired-state authority. Transaction coordinators use this only to prove that the
    /// repository still contains the exact record selected while the separate legacy mutation
    /// authority remains held.
    public func readPersistedRecord(id: String) throws -> DoryWorkspaceRepositoryRecord {
        lock.lock()
        defer { lock.unlock() }
        return try readRecordUnlocked(id: id)
    }

    public func readLegacyProjection(
        id: String,
        authoritativeLegacyData: Data
    ) throws -> DoryVirtualMachineDefinition {
        lock.lock()
        defer { lock.unlock() }
        let record = try readRecordUnlocked(id: id)
        guard let expectedDigest = record.legacyConfigurationSHA256 else {
            throw DoryWorkspaceRepositoryError.invalidRecord(recordPath(id: id))
        }
        guard record.legacyMigrationFactsSHA256 == nil else {
            throw DoryWorkspaceRepositoryError.staleLegacyProjection(id)
        }
        guard expectedDigest == Self.sha256(authoritativeLegacyData) else {
            throw DoryWorkspaceRepositoryError.staleLegacyProjection(id)
        }
        return record.definition
    }

    public func readLegacyProjection(
        id: String,
        authoritativeLegacyData: Data,
        authoritativeMigrationFactsData: Data
    ) throws -> DoryVirtualMachineDefinition {
        lock.lock()
        defer { lock.unlock() }
        let record = try readRecordUnlocked(id: id)
        guard let expectedLegacyDigest = record.legacyConfigurationSHA256,
              let expectedFactsDigest = record.legacyMigrationFactsSHA256 else {
            throw DoryWorkspaceRepositoryError.invalidRecord(recordPath(id: id))
        }
        guard expectedLegacyDigest == Self.sha256(authoritativeLegacyData),
              expectedFactsDigest == Self.sha256(authoritativeMigrationFactsData) else {
            throw DoryWorkspaceRepositoryError.staleLegacyProjection(id)
        }
        return record.definition
    }

    public func remove(id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try Self.validateIdentifier(id)
        let path = recordPath(id: id)
        guard Self.pathExists(path) else {
            throw DoryWorkspaceRepositoryError.workspaceNotFound(id)
        }
        _ = try Self.secureRead(path: path)
        guard unlink(path) == 0 else {
            throw DoryWorkspaceRepositoryError.filesystem(
                "remove workspace record at \(path): \(String(cString: strerror(errno)))"
            )
        }
        try Self.fsyncDirectory(workspaceDirectory(id: id))
    }

    private func readRecordUnlocked(id: String) throws -> DoryWorkspaceRepositoryRecord {
        try Self.validateIdentifier(id)
        let path = recordPath(id: id)
        guard Self.pathExists(path) else {
            throw DoryWorkspaceRepositoryError.workspaceNotFound(id)
        }
        let data = try Self.secureRead(path: path)
        let decoder = JSONDecoder()
        guard let record = try? decoder.decode(DoryWorkspaceRepositoryRecord.self, from: data),
              record.schemaVersion == DoryWorkspaceRepositoryRecord.schemaVersion,
              record.definition.identity.id == id,
              record.definition.validate().isEmpty,
              record.legacyConfigurationSHA256.map(Self.isSHA256) ?? true,
              record.legacyMigrationFactsSHA256.map(Self.isSHA256) ?? true,
              record.legacyMigrationFactsSHA256 == nil
                || record.legacyConfigurationSHA256 != nil else {
            throw DoryWorkspaceRepositoryError.invalidRecord(path)
        }
        return record
    }

    private func prepareWorkspaceDirectory(id: String) throws -> String {
        try Self.validateIdentifier(id)
        try Self.preparePrivateDirectory(root)
        let directory = workspaceDirectory(id: id)
        try Self.preparePrivateDirectory(directory)
        return directory
    }

    private func workspaceDirectory(id: String) -> String {
        root + "/" + id
    }

    private func recordPath(id: String) -> String {
        workspaceDirectory(id: id) + "/" + Self.recordFileName
    }

    private func publish(
        _ record: DoryWorkspaceRepositoryRecord,
        path: String,
        replacing: Bool
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(record)
        } catch {
            throw DoryWorkspaceRepositoryError.filesystem(
                "encode workspace record for \(record.definition.identity.id): \(error)"
            )
        }
        guard !data.isEmpty, data.count <= Self.maximumRecordBytes else {
            throw DoryWorkspaceRepositoryError.invalidRecord(path)
        }

        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let temporaryPath = directory + "/\(Self.temporaryPrefix)\(UUID().uuidString.lowercased())"
        let descriptor = open(
            temporaryPath,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw DoryWorkspaceRepositoryError.filesystem(
                "create workspace temporary record at \(temporaryPath): "
                    + String(cString: strerror(errno))
            )
        }
        var shouldRemoveTemporary = true
        defer {
            _ = close(descriptor)
            if shouldRemoveTemporary { _ = unlink(temporaryPath) }
        }
        do {
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var written = 0
                while written < data.count {
                    let count = Darwin.write(
                        descriptor,
                        base.advanced(by: written),
                        data.count - written
                    )
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else {
                        throw DoryWorkspaceRepositoryError.filesystem(
                            "write workspace temporary record at \(temporaryPath): "
                                + String(cString: strerror(errno))
                        )
                    }
                    written += count
                }
            }
            guard fsync(descriptor) == 0 else {
                throw DoryWorkspaceRepositoryError.filesystem(
                    "fsync workspace temporary record at \(temporaryPath): "
                        + String(cString: strerror(errno))
                )
            }
            if replacing {
                guard rename(temporaryPath, path) == 0 else {
                    throw DoryWorkspaceRepositoryError.filesystem(
                        "publish workspace record at \(path): \(String(cString: strerror(errno)))"
                    )
                }
            } else {
                guard link(temporaryPath, path) == 0 else {
                    if errno == EEXIST {
                        throw DoryWorkspaceRepositoryError.workspaceExists(
                            record.definition.identity.id
                        )
                    }
                    throw DoryWorkspaceRepositoryError.filesystem(
                        "publish workspace record at \(path): \(String(cString: strerror(errno)))"
                    )
                }
                guard unlink(temporaryPath) == 0 else {
                    _ = unlink(path)
                    throw DoryWorkspaceRepositoryError.filesystem(
                        "remove workspace temporary record at \(temporaryPath): "
                            + String(cString: strerror(errno))
                    )
                }
            }
            shouldRemoveTemporary = false
            try Self.fsyncDirectory(directory)
        } catch let error as DoryWorkspaceRepositoryError {
            throw error
        } catch {
            throw DoryWorkspaceRepositoryError.filesystem(
                "publish workspace record at \(path): \(error)"
            )
        }
    }

    private static func validate(_ definition: DoryVirtualMachineDefinition) throws {
        let issues = definition.validate()
        guard issues.isEmpty else {
            throw DoryWorkspaceRepositoryError.invalidDefinition(issues)
        }
    }

    private static func validateIdentifier(_ id: String) throws {
        let bytes = Array(id.utf8)
        guard (1...63).contains(bytes.count), isAlphaNumeric(bytes[0]),
              bytes.dropFirst().allSatisfy({ byte in
                  isAlphaNumeric(byte) || byte == 95 || byte == 46 || byte == 45
              }) else {
            throw DoryWorkspaceRepositoryError.invalidIdentifier(id)
        }
    }

    private static func isAlphaNumeric(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57)
            || (byte >= 65 && byte <= 90)
            || (byte >= 97 && byte <= 122)
    }

    private static func preparePrivateDirectory(_ path: String) throws {
        if !pathExists(path) {
            do {
                try FileManager.default.createDirectory(
                    atPath: path,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw DoryWorkspaceRepositoryError.filesystem(
                    "create workspace directory at \(path): \(error)"
                )
            }
            _ = chmod(path, mode_t(0o700))
        }
        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(),
              (info.st_mode & 0o077) == 0 else {
            throw DoryWorkspaceRepositoryError.invalidRecord(path)
        }
    }

    private static func secureRead(path: String) throws -> Data {
        var before = stat()
        guard lstat(path, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_uid == getuid(),
              before.st_nlink == 1,
              (before.st_mode & 0o077) == 0,
              before.st_size > 0,
              before.st_size <= maximumRecordBytes else {
            throw DoryWorkspaceRepositoryError.invalidRecord(path)
        }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw DoryWorkspaceRepositoryError.invalidRecord(path)
        }
        defer { _ = close(descriptor) }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              after.st_size == before.st_size else {
            throw DoryWorkspaceRepositoryError.invalidRecord(path)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        do {
            let data = try handle.read(upToCount: maximumRecordBytes + 1) ?? Data()
            guard !data.isEmpty, data.count <= maximumRecordBytes,
                  data.count == Int(after.st_size) else {
                throw DoryWorkspaceRepositoryError.invalidRecord(path)
            }
            return data
        } catch let error as DoryWorkspaceRepositoryError {
            throw error
        } catch {
            throw DoryWorkspaceRepositoryError.filesystem(
                "read workspace record at \(path): \(error)"
            )
        }
    }

    private static func fsyncDirectory(_ path: String) throws {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw DoryWorkspaceRepositoryError.filesystem(
                "open workspace directory at \(path): \(String(cString: strerror(errno)))"
            )
        }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw DoryWorkspaceRepositoryError.filesystem(
                "fsync workspace directory at \(path): \(String(cString: strerror(errno)))"
            )
        }
    }

    private static func pathExists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }

    private static func hasRecoverableLegacyAuthorityMarker(path: String) throws -> Bool {
        let data = try secureRead(path: path)
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let digest = dictionary["legacyConfigurationSHA256"] as? String else {
            return false
        }
        return isSHA256(digest)
    }

    private static func nextUpdatedTimestamp(previous: Int64, proposed: Int64) -> Int64 {
        guard previous < Int64.max else { return Int64.max }
        return max(previous + 1, proposed)
    }
}
