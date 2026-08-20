import CryptoKit
import Darwin
import Foundation

enum DoryMachineRuntimeIdentityStoreError: Error, Equatable {
    case invalidMachineID
    case recordNotFound
    case invalidRecord
    case authorityMismatch
    case filesystem(String)
}

struct DoryPersistedMachineRuntimeIdentity: Codable, Sendable, Equatable {
    static let schemaVersion: UInt16 = 2

    var schemaVersion: UInt16
    var machineID: String
    var authorityRevision: UInt64
    var previousRecordSHA256: String?
    var legacyConfigurationSHA256: String
    var identity: DoryMachineRuntimeIdentity

    init(
        machineID: String,
        authorityRevision: UInt64,
        previousRecordSHA256: String?,
        legacyConfigurationSHA256: String,
        identity: DoryMachineRuntimeIdentity
    ) {
        schemaVersion = Self.schemaVersion
        self.machineID = machineID
        self.authorityRevision = authorityRevision
        self.previousRecordSHA256 = previousRecordSHA256?.lowercased()
        self.legacyConfigurationSHA256 = legacyConfigurationSHA256.lowercased()
        self.identity = identity
    }

    var isValid: Bool {
        schemaVersion == Self.schemaVersion
            && Self.isValidMachineID(machineID)
            && authorityRevision > 0
            && ((authorityRevision == 1 && previousRecordSHA256 == nil)
                || (authorityRevision > 1
                    && previousRecordSHA256.map(Self.isSHA256) == true))
            && Self.isSHA256(legacyConfigurationSHA256)
            && identity.validate().isEmpty
            && (identity.resolvedPlan?.machineID == machineID
                || identity.resolvedPlan == nil)
    }

    private static func isValidMachineID(_ value: String) -> Bool {
        value.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_.-]{0,62}/) != nil
            && !value.hasPrefix(".")
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

private struct DoryMachineRuntimeIdentityHead: Codable, Sendable, Equatable {
    static let schemaVersion: UInt16 = 1

    var schemaVersion: UInt16 = Self.schemaVersion
    var machineID: String
    var authorityRevision: UInt64
    var recordSHA256: String

    var isValid: Bool {
        schemaVersion == Self.schemaVersion
            && authorityRevision > 0
            && machineID.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_.-]{0,62}/) != nil
            && !machineID.hasPrefix(".")
            && recordSHA256.utf8.count == 64
            && recordSHA256.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
    }
}

/// Durable per-workspace launch authority. The record contains no paths or secrets and is bound
/// to the exact authoritative legacy machine bytes, so a machine.json change cannot retain stale
/// resolved or compatibility authority across daemon restart.
final class DoryMachineRuntimeIdentityStore: @unchecked Sendable {
    static let recordFileName = "runtime-identity-v1.json"
    static let headFileName = "runtime-identity-head-v1.json"
    static let recordTemporaryPrefix = ".runtime-identity-v1.tmp-"
    static let headTemporaryPrefix = ".runtime-head.tmp-"
    private static let maximumRecordBytes: Int64 = 16 * 1_024 * 1_024

    let root: String
    private let lock = NSLock()

    init(root: String) {
        self.root = URL(fileURLWithPath: root).standardizedFileURL.path
    }

    func readIfPresent(
        machineID: String,
        authoritativeLegacyData: Data
    ) throws -> DoryMachineRuntimeIdentity? {
        lock.lock()
        defer { lock.unlock() }
        let path = try recordPath(machineID: machineID)
        let headPath = try headPath(machineID: machineID)
        let hasRecord = Self.pathExists(path)
        let hasHead = Self.pathExists(headPath)
        guard hasRecord || hasHead else { return nil }
        guard hasRecord, hasHead else {
            throw DoryMachineRuntimeIdentityStoreError.invalidRecord
        }
        let data = try Self.secureRead(path: path)
        guard let record = try? JSONDecoder().decode(
            DoryPersistedMachineRuntimeIdentity.self,
            from: data
        ), record.isValid, record.machineID == machineID else {
            throw DoryMachineRuntimeIdentityStoreError.invalidRecord
        }
        let head = try decodeHead(path: headPath, machineID: machineID)
        let recordSHA256 = Self.sha256(data)
        if head.recordSHA256 != recordSHA256
            || head.authorityRevision != record.authorityRevision {
            // Identity is published before its monotonic head. Complete that one permissible
            // crash ordering; every rollback/substitution shape fails closed.
            guard record.authorityRevision == head.authorityRevision + 1,
                  record.previousRecordSHA256 == head.recordSHA256 else {
                throw DoryMachineRuntimeIdentityStoreError.invalidRecord
            }
            try publishHead(
                DoryMachineRuntimeIdentityHead(
                    machineID: machineID,
                    authorityRevision: record.authorityRevision,
                    recordSHA256: recordSHA256
                ),
                path: headPath
            )
        }
        guard record.legacyConfigurationSHA256 == Self.sha256(authoritativeLegacyData) else {
            throw DoryMachineRuntimeIdentityStoreError.authorityMismatch
        }
        return record.identity
    }

    func publish(
        _ identity: DoryMachineRuntimeIdentity,
        machineID: String,
        authoritativeLegacyData: Data
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        let path = try recordPath(machineID: machineID)
        let headPath = try headPath(machineID: machineID)
        let previous: DoryMachineRuntimeIdentityHead?
        if Self.pathExists(path) || Self.pathExists(headPath) {
            guard Self.pathExists(path), Self.pathExists(headPath) else {
                throw DoryMachineRuntimeIdentityStoreError.invalidRecord
            }
            let oldData = try Self.secureRead(path: path)
            let oldHead = try decodeHead(path: headPath, machineID: machineID)
            guard oldHead.recordSHA256 == Self.sha256(oldData),
                  let oldRecord = try? JSONDecoder().decode(
                    DoryPersistedMachineRuntimeIdentity.self,
                    from: oldData
                  ), oldRecord.isValid,
                  oldRecord.authorityRevision == oldHead.authorityRevision else {
                throw DoryMachineRuntimeIdentityStoreError.invalidRecord
            }
            previous = oldHead
        } else {
            previous = nil
        }
        guard previous?.authorityRevision != UInt64.max else {
            throw DoryMachineRuntimeIdentityStoreError.invalidRecord
        }
        let authorityRevision = (previous?.authorityRevision ?? 0) + 1
        let record = DoryPersistedMachineRuntimeIdentity(
            machineID: machineID,
            authorityRevision: authorityRevision,
            previousRecordSHA256: previous?.recordSHA256,
            legacyConfigurationSHA256: Self.sha256(authoritativeLegacyData),
            identity: identity
        )
        guard record.isValid else {
            throw DoryMachineRuntimeIdentityStoreError.invalidRecord
        }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard Self.isPrivateDirectory(directory) else {
            throw DoryMachineRuntimeIdentityStoreError.filesystem(
                "runtime identity owner is not a private directory"
            )
        }
        let data = try Self.encoded(record)
        guard !data.isEmpty, data.count <= Int(Self.maximumRecordBytes) else {
            throw DoryMachineRuntimeIdentityStoreError.invalidRecord
        }
        let temporary = directory + "/\(Self.recordTemporaryPrefix)\(UUID().uuidString.lowercased())"
        let descriptor = open(
            temporary,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw Self.filesystem("create runtime identity temporary record")
        }
        var removeTemporary = true
        defer {
            _ = close(descriptor)
            if removeTemporary { _ = unlink(temporary) }
        }
        try data.withUnsafeBytes { bytes in
            var remaining = bytes.count
            var pointer = bytes.baseAddress!
            while remaining > 0 {
                let count = Darwin.write(descriptor, pointer, remaining)
                if count > 0 {
                    remaining -= count
                    pointer = pointer.advanced(by: count)
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw Self.filesystem("write runtime identity temporary record")
                }
            }
        }
        guard fsync(descriptor) == 0, fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw Self.filesystem("sync runtime identity temporary record")
        }
        guard rename(temporary, path) == 0 else {
            throw Self.filesystem("publish runtime identity record")
        }
        removeTemporary = false
        try Self.syncDirectory(directory)
        try publishHead(
            DoryMachineRuntimeIdentityHead(
                machineID: machineID,
                authorityRevision: authorityRevision,
                recordSHA256: Self.sha256(data)
            ),
            path: headPath
        )
    }

    private func recordPath(machineID: String) throws -> String {
        guard machineID.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_.-]{0,62}/) != nil,
              !machineID.hasPrefix(".") else {
            throw DoryMachineRuntimeIdentityStoreError.invalidMachineID
        }
        return root + "/" + machineID + "/" + Self.recordFileName
    }

    private func headPath(machineID: String) throws -> String {
        _ = try recordPath(machineID: machineID)
        return root + "/" + machineID + "/" + Self.headFileName
    }

    private func decodeHead(
        path: String,
        machineID: String
    ) throws -> DoryMachineRuntimeIdentityHead {
        let data = try Self.secureRead(path: path)
        guard let head = try? JSONDecoder().decode(
            DoryMachineRuntimeIdentityHead.self,
            from: data
        ), head.isValid, head.machineID == machineID else {
            throw DoryMachineRuntimeIdentityStoreError.invalidRecord
        }
        return head
    }

    private func publishHead(
        _ head: DoryMachineRuntimeIdentityHead,
        path: String
    ) throws {
        guard head.isValid else {
            throw DoryMachineRuntimeIdentityStoreError.invalidRecord
        }
        try Self.publishData(Self.encoded(head), path: path, prefix: Self.headTemporaryPrefix)
    }

    private static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func secureRead(path: String) throws -> Data {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw filesystem("open runtime identity record") }
        defer { _ = close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1,
              (info.st_mode & 0o077) == 0,
              info.st_size > 0,
              info.st_size <= maximumRecordBytes else {
            throw DoryMachineRuntimeIdentityStoreError.invalidRecord
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.readToEnd() ?? Data()
        guard data.count == Int(info.st_size) else {
            throw DoryMachineRuntimeIdentityStoreError.invalidRecord
        }
        return data
    }

    private static func publishData(
        _ data: Data,
        path: String,
        prefix: String
    ) throws {
        guard !data.isEmpty, data.count <= Int(maximumRecordBytes) else {
            throw DoryMachineRuntimeIdentityStoreError.invalidRecord
        }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard isPrivateDirectory(directory) else {
            throw DoryMachineRuntimeIdentityStoreError.filesystem(
                "runtime identity owner is not a private directory"
            )
        }
        let temporary = directory + "/\(prefix)\(UUID().uuidString.lowercased())"
        let descriptor = open(
            temporary,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw filesystem("create runtime authority temporary") }
        var removeTemporary = true
        defer {
            _ = close(descriptor)
            if removeTemporary { _ = unlink(temporary) }
        }
        try data.withUnsafeBytes { bytes in
            var remaining = bytes.count
            var pointer = bytes.baseAddress!
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, remaining)
                if written > 0 {
                    remaining -= written
                    pointer = pointer.advanced(by: written)
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw filesystem("write runtime authority temporary")
                }
            }
        }
        guard fsync(descriptor) == 0, fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw filesystem("sync runtime authority temporary")
        }
        guard rename(temporary, path) == 0 else {
            throw filesystem("publish runtime authority")
        }
        removeTemporary = false
        try syncDirectory(directory)
    }

    private static func isPrivateDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
            && (info.st_mode & S_IFMT) == S_IFDIR
            && info.st_uid == getuid()
            && (info.st_mode & 0o077) == 0
    }

    private static func pathExists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    private static func syncDirectory(_ path: String) throws {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw filesystem("open runtime identity directory") }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else { throw filesystem("sync runtime identity directory") }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func filesystem(_ action: String) -> DoryMachineRuntimeIdentityStoreError {
        .filesystem(action + ": " + String(cString: strerror(errno)))
    }
}
