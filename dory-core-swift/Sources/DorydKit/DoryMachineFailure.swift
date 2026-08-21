import Darwin
import Foundation

public enum DoryMachineFailureCode: String, Codable, Sendable, CaseIterable {
    case lifecycleOperationFailed = "lifecycle-operation-failed"
    case lifecycleRecoveryRequired = "lifecycle-recovery-required"
    case workspaceAuthorityInvalid = "workspace-authority-invalid"
    case backendLaunchFailed = "backend-launch-failed"
    case readinessHandoffFailed = "readiness-handoff-failed"
    case readinessTimedOut = "readiness-timed-out"
    case helperExited = "helper-exited"
    case savedStateInvalid = "saved-state-invalid"
    case resourceAdmissionRejected = "resource-admission-rejected"
    case desktopUpdateRecoveryRequired = "desktop-update-recovery-required"
    case desktopUpdateRolledBack = "desktop-update-rolled-back"
    case deletionFailed = "deletion-failed"
    case diagnosticPersistenceFailed = "diagnostic-persistence-failed"
    case unclassified = "unclassified"
}

public enum DoryMachineFailureCauseCode: String, Codable, Sendable, CaseIterable {
    case configurationAuthority = "configuration-authority"
    case runtimeAuthority = "runtime-authority"
    case artifactAuthority = "artifact-authority"
    case componentAuthority = "component-authority"
    case hostQualification = "host-qualification"
    case resourceAdmission = "resource-admission"
    case processExit = "process-exit"
    case readinessGate = "readiness-gate"
    case journal = "journal"
    case filesystem = "filesystem"
    case guestAgent = "guest-agent"
    case unknown
}

public enum DoryMachineRecoveryDisposition: String, Codable, Sendable, CaseIterable {
    case retry
    case replan
    case repair
    case rollbackCompleted = "rollback-completed"
    case deleteWorkspace = "delete-workspace"
    case inspectDiagnostics = "inspect-diagnostics"
}

public enum DoryMachineFailureEvidenceKind: String, Codable, Sendable, CaseIterable {
    case operation
    case plan
    case backend
    case component
    case media
    case snapshot
    case savedState = "saved-state"
    case journal
    case hostQualification = "host-qualification"
}

public struct DoryMachineFailureEvidenceReference:
    Codable, Sendable, Equatable, Hashable
{
    public var kind: DoryMachineFailureEvidenceKind
    public var identifier: String

    public init(kind: DoryMachineFailureEvidenceKind, identifier: String) {
        self.kind = kind
        self.identifier = identifier
    }

    public var isValid: Bool {
        identifier.utf8.count <= 256
            && identifier.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._:@+-]{0,255}/) != nil
    }
}

/// Stable, path-free failure evidence. Human-readable compatibility detail remains outside this
/// authority because arbitrary error descriptions can contain host paths, process arguments, or
/// guest-controlled strings.
public struct DoryMachineFailure: Codable, Sendable, Equatable, Hashable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var code: DoryMachineFailureCode
    public var occurredAtUnixMilliseconds: Int64
    public var operationID: String?
    public var causalChain: [DoryMachineFailureCauseCode]
    public var recoveryDisposition: DoryMachineRecoveryDisposition
    public var evidenceReferences: [DoryMachineFailureEvidenceReference]

    public init(
        code: DoryMachineFailureCode,
        occurredAtUnixMilliseconds: Int64 = Int64(
            max(1, (Date().timeIntervalSince1970 * 1_000).rounded())
        ),
        operationID: String? = nil,
        causalChain: [DoryMachineFailureCauseCode],
        recoveryDisposition: DoryMachineRecoveryDisposition,
        evidenceReferences: [DoryMachineFailureEvidenceReference] = []
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.code = code
        self.occurredAtUnixMilliseconds = occurredAtUnixMilliseconds
        self.operationID = operationID
        self.causalChain = causalChain
        self.recoveryDisposition = recoveryDisposition
        self.evidenceReferences = evidenceReferences
    }

    public var isValid: Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              occurredAtUnixMilliseconds > 0,
              !causalChain.isEmpty,
              causalChain.count <= 8,
              evidenceReferences.count <= 16,
              evidenceReferences.allSatisfy(\.isValid),
              Set(evidenceReferences).count == evidenceReferences.count else {
            return false
        }
        return operationID.map(Self.isOperationID) ?? true
    }

    public var compatibilitySummary: String {
        switch code {
        case .lifecycleOperationFailed:
            "The requested lifecycle operation failed."
        case .lifecycleRecoveryRequired:
            "A durable lifecycle operation requires recovery."
        case .workspaceAuthorityInvalid:
            "Workspace launch authority is invalid and must be repaired or replanned."
        case .backendLaunchFailed:
            "The selected virtualization backend could not start."
        case .readinessHandoffFailed:
            "The VM helper did not provide a valid readiness handoff."
        case .readinessTimedOut:
            "The VM did not pass its readiness gates before the deadline."
        case .helperExited:
            "The VM helper exited unexpectedly."
        case .savedStateInvalid:
            "The durable saved state is missing, changed, or incompatible."
        case .resourceAdmissionRejected:
            "The VM no longer satisfies its resource admission authority."
        case .desktopUpdateRecoveryRequired:
            "The installed desktop update requires recovery."
        case .desktopUpdateRolledBack:
            "The interrupted desktop update was rolled back."
        case .deletionFailed:
            "Workspace deletion failed and was rolled back."
        case .diagnosticPersistenceFailed:
            "Machine diagnostics could not be persisted safely."
        case .unclassified:
            "The machine failed with an unclassified diagnostic."
        }
    }

    private static func isOperationID(_ value: String) -> Bool {
        value.wholeMatch(
            of: /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/
        ) != nil
    }
}

enum DoryMachineFailureStoreError: Error, Equatable {
    case invalidRoot
    case invalidMachineID
    case invalidRecord
    case revisionExhausted
    case filesystem(String)
}

private struct DoryMachineFailureStoreRecord: Codable, Equatable {
    static let currentSchemaVersion: UInt16 = 1

    var schemaVersion: UInt16 = Self.currentSchemaVersion
    var revision: UInt64
    var failures: [String: DoryMachineFailure]

    var isValid: Bool {
        schemaVersion == Self.currentSchemaVersion
            && failures.allSatisfy { machineID, failure in
                DoryMachineFailureStore.isMachineID(machineID) && failure.isValid
            }
    }
}

/// Owner-only, cross-process durable authority for the latest structured failure of each local
/// workspace. The record contains no free-form detail, environment data, or host paths.
final class DoryMachineFailureStore: @unchecked Sendable {
    static let recordFileName = ".machine-failures-v1.json"
    static let lockFileName = ".machine-failures-v1.lock"
    static let temporaryPrefix = ".machine-failures-v1.tmp-"
    private static let maximumRecordBytes: Int64 = 4 * 1_024 * 1_024

    private let root: String
    private let lock = NSLock()

    init(root: String) {
        self.root = URL(fileURLWithPath: root).standardizedFileURL.path
    }

    func failures() throws -> [String: DoryMachineFailure] {
        try synchronized { try readRecord().failures }
    }

    func set(_ failure: DoryMachineFailure, for machineID: String) throws {
        guard Self.isMachineID(machineID) else {
            throw DoryMachineFailureStoreError.invalidMachineID
        }
        guard failure.isValid else { throw DoryMachineFailureStoreError.invalidRecord }
        try synchronized {
            var record = try readRecord()
            guard record.revision < UInt64.max else {
                throw DoryMachineFailureStoreError.revisionExhausted
            }
            record.revision += 1
            record.failures[machineID] = failure
            try publish(record)
        }
    }

    func clear(_ machineID: String) throws {
        guard Self.isMachineID(machineID) else {
            throw DoryMachineFailureStoreError.invalidMachineID
        }
        try synchronized {
            var record = try readRecord()
            guard record.failures[machineID] != nil else { return }
            guard record.revision < UInt64.max else {
                throw DoryMachineFailureStoreError.revisionExhausted
            }
            record.revision += 1
            record.failures.removeValue(forKey: machineID)
            try publish(record)
        }
    }

    private func synchronized<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try withFileLock(body)
    }

    private func readRecord() throws -> DoryMachineFailureStoreRecord {
        let path = root + "/" + Self.recordFileName
        var info = stat()
        if lstat(path, &info) != 0 {
            guard errno == ENOENT else { throw Self.filesystem("inspect failure record") }
            return DoryMachineFailureStoreRecord(revision: 0, failures: [:])
        }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw Self.filesystem("open failure record") }
        defer { _ = close(descriptor) }
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1,
              (info.st_mode & 0o077) == 0,
              info.st_size > 0,
              info.st_size <= Self.maximumRecordBytes else {
            throw DoryMachineFailureStoreError.invalidRecord
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.readToEnd() ?? Data()
        guard Int64(data.count) == info.st_size,
              let record = try? JSONDecoder().decode(
                  DoryMachineFailureStoreRecord.self,
                  from: data
              ), record.isValid else {
            throw DoryMachineFailureStoreError.invalidRecord
        }
        return record
    }

    private func publish(_ record: DoryMachineFailureStoreRecord) throws {
        guard record.isValid else { throw DoryMachineFailureStoreError.invalidRecord }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(record)
        guard !data.isEmpty, data.count <= Int(Self.maximumRecordBytes) else {
            throw DoryMachineFailureStoreError.invalidRecord
        }
        let path = root + "/" + Self.recordFileName
        let temporary = root + "/" + Self.temporaryPrefix
            + UUID().uuidString.lowercased()
        let descriptor = open(
            temporary,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw Self.filesystem("create failure record") }
        var removeTemporary = true
        defer {
            _ = close(descriptor)
            if removeTemporary { _ = unlink(temporary) }
        }
        try data.withUnsafeBytes { bytes in
            var remaining = bytes.count
            guard var pointer = bytes.baseAddress else {
                throw DoryMachineFailureStoreError.invalidRecord
            }
            while remaining > 0 {
                let count = Darwin.write(descriptor, pointer, remaining)
                if count > 0 {
                    remaining -= count
                    pointer = pointer.advanced(by: count)
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw Self.filesystem("write failure record")
                }
            }
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0, fsync(descriptor) == 0 else {
            throw Self.filesystem("sync failure record")
        }
        guard rename(temporary, path) == 0 else {
            throw Self.filesystem("publish failure record")
        }
        removeTemporary = false
        try Self.syncDirectory(root)
    }

    private func withFileLock<T>(_ body: () throws -> T) throws -> T {
        guard Self.isPrivateDirectory(root) else {
            throw DoryMachineFailureStoreError.invalidRoot
        }
        let path = root + "/" + Self.lockFileName
        let descriptor = open(
            path,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw Self.filesystem("open failure lock") }
        defer { _ = close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1,
              (info.st_mode & 0o077) == 0 else {
            throw DoryMachineFailureStoreError.invalidRecord
        }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw Self.filesystem("acquire failure lock")
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    fileprivate static func isMachineID(_ value: String) -> Bool {
        value.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_.-]{0,62}/) != nil
            && !value.hasPrefix(".")
    }

    private static func isPrivateDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
            && (info.st_mode & S_IFMT) == S_IFDIR
            && info.st_uid == getuid()
            && (info.st_mode & 0o077) == 0
    }

    private static func syncDirectory(_ path: String) throws {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw filesystem("open failure directory") }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else { throw filesystem("sync failure directory") }
    }

    private static func filesystem(_ operation: String) -> DoryMachineFailureStoreError {
        .filesystem("\(operation): \(String(cString: strerror(errno)))")
    }
}
