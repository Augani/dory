import Darwin
import DoryOperations
import Foundation

public enum DoryMachineFlightEventKind: String, Codable, Sendable, CaseIterable {
    case workspaceCreated = "workspace-created"
    case operationStarted = "operation-started"
    case operationPhase = "operation-phase"
    case backendSpawned = "backend-spawned"
    case readinessAccepted = "readiness-accepted"
    case readinessRejected = "readiness-rejected"
    case resourceTransition = "resource-transition"
    case processExited = "process-exited"
    case failureRecorded = "failure-recorded"
    case operationCompleted = "operation-completed"
    case operationFailed = "operation-failed"
    case recoveryRequired = "recovery-required"
    case workspaceDeleted = "workspace-deleted"
}

/// One bounded, path-free flight-recorder row. It deliberately carries only stable identifiers
/// and classified state. Human-readable error text, host paths, process arguments, environment
/// values, guest payloads, and raw telemetry never enter this authority.
public struct DoryMachineFlightEvent: Codable, Sendable, Equatable, Hashable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var sequence: UInt64
    public var occurredAtUnixMilliseconds: Int64
    public var machineID: String
    public var operationID: String?
    public var operationKind: String?
    public var kind: DoryMachineFlightEventKind
    public var phase: String?
    public var machineState: String?
    public var failureCode: DoryMachineFailureCode?
    public var recoveryDisposition: DoryMachineRecoveryDisposition?
    public var backend: DoryVirtualizationBackendIdentity?
    public var virtualHardwareABIVersion: UInt16?
    public var planSHA256: String?
    public var durationMilliseconds: UInt64?
    public var deadlineUnixMilliseconds: Int64?
    public var evidenceReferences: [DoryMachineFailureEvidenceReference]

    public init(
        sequence: UInt64,
        occurredAtUnixMilliseconds: Int64,
        machineID: String,
        operationID: String? = nil,
        operationKind: String? = nil,
        kind: DoryMachineFlightEventKind,
        phase: String? = nil,
        machineState: String? = nil,
        failureCode: DoryMachineFailureCode? = nil,
        recoveryDisposition: DoryMachineRecoveryDisposition? = nil,
        backend: DoryVirtualizationBackendIdentity? = nil,
        virtualHardwareABIVersion: UInt16? = nil,
        planSHA256: String? = nil,
        durationMilliseconds: UInt64? = nil,
        deadlineUnixMilliseconds: Int64? = nil,
        evidenceReferences: [DoryMachineFailureEvidenceReference] = []
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.sequence = sequence
        self.occurredAtUnixMilliseconds = occurredAtUnixMilliseconds
        self.machineID = machineID
        self.operationID = operationID
        self.operationKind = operationKind
        self.kind = kind
        self.phase = phase
        self.machineState = machineState
        self.failureCode = failureCode
        self.recoveryDisposition = recoveryDisposition
        self.backend = backend
        self.virtualHardwareABIVersion = virtualHardwareABIVersion
        self.planSHA256 = planSHA256
        self.durationMilliseconds = durationMilliseconds
        self.deadlineUnixMilliseconds = deadlineUnixMilliseconds
        self.evidenceReferences = evidenceReferences
    }

    public var isValid: Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              sequence > 0,
              occurredAtUnixMilliseconds > 0,
              DoryMachineFlightRecorderStore.isMachineID(machineID),
              (operationID == nil) == (operationKind == nil),
              operationID.map(Self.isOperationID) ?? true,
              operationKind.flatMap(DoryWorkspaceMutationKind.init(rawValue:))
                .map({ _ in true }) ?? (operationKind == nil),
              phase.flatMap(DoryOperationPhase.init(rawValue:))
                .map({ _ in true }) ?? (phase == nil),
              machineState.flatMap(DoryMachineState.init(rawValue:))
                .map({ _ in true }) ?? (machineState == nil),
              virtualHardwareABIVersion.map({ $0 > 0 }) ?? true,
              planSHA256.map(Self.isSHA256) ?? true,
              durationMilliseconds.map({ $0 <= 31 * 24 * 60 * 60 * 1_000 }) ?? true,
              deadlineUnixMilliseconds.map({ $0 > 0 }) ?? true,
              evidenceReferences.count <= 16,
              evidenceReferences.allSatisfy(\.isValid),
              Set(evidenceReferences).count == evidenceReferences.count else {
            return false
        }
        if failureCode == nil, recoveryDisposition != nil { return false }
        if kind == .failureRecorded || kind == .readinessRejected
            || kind == .operationFailed || kind == .recoveryRequired {
            return failureCode != nil && recoveryDisposition != nil
        }
        return true
    }

    private static func isOperationID(_ value: String) -> Bool {
        value.wholeMatch(
            of: /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/
        ) != nil
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

public struct DoryMachineFlightRecorderBatch: Codable, Sendable, Equatable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var machineID: String
    public var headSequence: UInt64
    public var snapshotRequired: Bool
    public var events: [DoryMachineFlightEvent]

    public init(
        machineID: String,
        headSequence: UInt64,
        snapshotRequired: Bool,
        events: [DoryMachineFlightEvent]
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.machineID = machineID
        self.headSequence = headSequence
        self.snapshotRequired = snapshotRequired
        self.events = events
    }
}

enum DoryMachineFlightRecorderStoreError: Error, Equatable {
    case invalidRoot
    case invalidMachineID
    case invalidEvent
    case invalidRecord
    case capacityExceeded
    case sequenceExhausted
    case revisionExhausted
    case filesystem(String)
}

private struct DoryMachineFlightRecorderLog: Codable, Sendable, Equatable {
    var headSequence: UInt64
    var events: [DoryMachineFlightEvent]

    var isValid: Bool {
        guard events.count <= DoryMachineFlightRecorderStore.maximumEventsPerWorkspace,
              events.allSatisfy(\.isValid),
              events == events.sorted(by: { $0.sequence < $1.sequence }),
              Set(events.map(\.sequence)).count == events.count else {
            return false
        }
        if events.isEmpty { return headSequence == 0 }
        guard events.last?.sequence == headSequence,
              let first = events.first?.sequence else { return false }
        let offset = UInt64(events.count - 1)
        guard headSequence >= offset, first == headSequence - offset else { return false }
        return zip(events, events.dropFirst()).allSatisfy { lhs, rhs in
            lhs.sequence < UInt64.max && lhs.sequence + 1 == rhs.sequence
        }
    }
}

private struct DoryMachineFlightRecorderRecord: Codable, Sendable, Equatable {
    static let currentSchemaVersion: UInt16 = 1

    var schemaVersion: UInt16 = Self.currentSchemaVersion
    var revision: UInt64
    var logs: [String: DoryMachineFlightRecorderLog]

    var isValid: Bool {
        schemaVersion == Self.currentSchemaVersion
            && logs.count <= DoryMachineFlightRecorderStore.maximumWorkspaceCount
            && logs.allSatisfy { machineID, log in
                DoryMachineFlightRecorderStore.isMachineID(machineID)
                    && log.isValid
                    && log.events.allSatisfy { $0.machineID == machineID }
            }
    }
}

/// Cross-process, owner-only, bounded flight recorder for local workspaces. Sequence numbers are
/// monotonic per workspace and survive daemon restart. Publication uses an fsync'd temporary file,
/// atomic rename, and parent-directory fsync under one root-wide flock.
final class DoryMachineFlightRecorderStore: @unchecked Sendable {
    static let recordFileName = ".machine-flight-recorder-v1.json"
    static let lockFileName = ".machine-flight-recorder-v1.lock"
    static let temporaryPrefix = ".machine-flight-recorder-v1.tmp-"
    static let maximumWorkspaceCount = 256
    static let maximumEventsPerWorkspace = 256
    private static let maximumRecordBytes: Int64 = 16 * 1_024 * 1_024

    private let root: String
    private let now: @Sendable () -> Int64
    private let lock = NSLock()

    init(
        root: String,
        now: @escaping @Sendable () -> Int64 = {
            Int64(max(1, (Date().timeIntervalSince1970 * 1_000).rounded()))
        }
    ) {
        self.root = URL(fileURLWithPath: root).standardizedFileURL.path
        self.now = now
    }

    @discardableResult
    func append(
        machineID: String,
        operationID: String? = nil,
        operationKind: String? = nil,
        kind: DoryMachineFlightEventKind,
        phase: String? = nil,
        machineState: String? = nil,
        failureCode: DoryMachineFailureCode? = nil,
        recoveryDisposition: DoryMachineRecoveryDisposition? = nil,
        backend: DoryVirtualizationBackendIdentity? = nil,
        virtualHardwareABIVersion: UInt16? = nil,
        planSHA256: String? = nil,
        durationMilliseconds: UInt64? = nil,
        deadlineUnixMilliseconds: Int64? = nil,
        evidenceReferences: [DoryMachineFailureEvidenceReference] = []
    ) throws -> DoryMachineFlightEvent {
        guard Self.isMachineID(machineID) else {
            throw DoryMachineFlightRecorderStoreError.invalidMachineID
        }
        return try synchronized {
            var record = try readRecord()
            if record.logs[machineID] == nil,
               record.logs.count >= Self.maximumWorkspaceCount {
                // Retain active workspace history, but do not let tombstoned workspaces consume
                // recorder capacity forever. Eviction is deterministic across daemon instances.
                guard let evicted = record.logs
                    .filter({ $0.value.events.last?.kind == .workspaceDeleted })
                    .min(by: { lhs, rhs in
                        let lhsTime = lhs.value.events.last?.occurredAtUnixMilliseconds ?? 0
                        let rhsTime = rhs.value.events.last?.occurredAtUnixMilliseconds ?? 0
                        return lhsTime == rhsTime ? lhs.key < rhs.key : lhsTime < rhsTime
                    })?.key else {
                    throw DoryMachineFlightRecorderStoreError.capacityExceeded
                }
                record.logs.removeValue(forKey: evicted)
            }
            var log = record.logs[machineID]
                ?? DoryMachineFlightRecorderLog(headSequence: 0, events: [])
            guard log.headSequence < UInt64.max else {
                throw DoryMachineFlightRecorderStoreError.sequenceExhausted
            }
            let event = DoryMachineFlightEvent(
                sequence: log.headSequence + 1,
                occurredAtUnixMilliseconds: now(),
                machineID: machineID,
                operationID: operationID,
                operationKind: operationKind,
                kind: kind,
                phase: phase,
                machineState: machineState,
                failureCode: failureCode,
                recoveryDisposition: recoveryDisposition,
                backend: backend,
                virtualHardwareABIVersion: virtualHardwareABIVersion,
                planSHA256: planSHA256,
                durationMilliseconds: durationMilliseconds,
                deadlineUnixMilliseconds: deadlineUnixMilliseconds,
                evidenceReferences: evidenceReferences
            )
            guard event.isValid else {
                throw DoryMachineFlightRecorderStoreError.invalidEvent
            }
            log.headSequence = event.sequence
            log.events.append(event)
            if log.events.count > Self.maximumEventsPerWorkspace {
                log.events.removeFirst(log.events.count - Self.maximumEventsPerWorkspace)
            }
            guard record.revision < UInt64.max else {
                throw DoryMachineFlightRecorderStoreError.revisionExhausted
            }
            record.revision += 1
            record.logs[machineID] = log
            try publish(record)
            return event
        }
    }

    func batch(machineID: String, afterSequence: UInt64) throws
        -> DoryMachineFlightRecorderBatch {
        guard Self.isMachineID(machineID) else {
            throw DoryMachineFlightRecorderStoreError.invalidMachineID
        }
        return try synchronized {
            let log = try readRecord().logs[machineID]
                ?? DoryMachineFlightRecorderLog(headSequence: 0, events: [])
            let oldest = log.events.first?.sequence
            let fellBehind = oldest.map { first in
                first > 1 && afterSequence < first - 1
            } ?? false
            let snapshotRequired = afterSequence > log.headSequence || fellBehind
            return DoryMachineFlightRecorderBatch(
                machineID: machineID,
                headSequence: log.headSequence,
                snapshotRequired: snapshotRequired,
                events: snapshotRequired
                    ? log.events
                    : log.events.filter { $0.sequence > afterSequence }
            )
        }
    }

    func headSequences() throws -> [String: UInt64] {
        try synchronized {
            try readRecord().logs.mapValues(\.headSequence)
        }
    }

    func clear(machineID: String) throws {
        guard Self.isMachineID(machineID) else {
            throw DoryMachineFlightRecorderStoreError.invalidMachineID
        }
        try synchronized {
            var record = try readRecord()
            guard record.logs[machineID] != nil else { return }
            guard record.revision < UInt64.max else {
                throw DoryMachineFlightRecorderStoreError.revisionExhausted
            }
            record.revision += 1
            record.logs.removeValue(forKey: machineID)
            try publish(record)
        }
    }

    private func synchronized<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try withFileLock(body)
    }

    private func readRecord() throws -> DoryMachineFlightRecorderRecord {
        let path = root + "/" + Self.recordFileName
        var info = stat()
        if lstat(path, &info) != 0 {
            guard errno == ENOENT else { throw Self.filesystem("inspect flight recorder") }
            return DoryMachineFlightRecorderRecord(revision: 0, logs: [:])
        }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw Self.filesystem("open flight recorder") }
        defer { _ = close(descriptor) }
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1,
              (info.st_mode & 0o077) == 0,
              info.st_size > 0,
              info.st_size <= Self.maximumRecordBytes else {
            throw DoryMachineFlightRecorderStoreError.invalidRecord
        }
        let data = try FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: false
        ).readToEnd() ?? Data()
        guard Int64(data.count) == info.st_size,
              let record = try? JSONDecoder().decode(
                  DoryMachineFlightRecorderRecord.self,
                  from: data
              ), record.isValid else {
            throw DoryMachineFlightRecorderStoreError.invalidRecord
        }
        return record
    }

    private func publish(_ record: DoryMachineFlightRecorderRecord) throws {
        guard record.isValid else { throw DoryMachineFlightRecorderStoreError.invalidRecord }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(record)
        guard !data.isEmpty, data.count <= Int(Self.maximumRecordBytes) else {
            throw DoryMachineFlightRecorderStoreError.invalidRecord
        }
        let path = root + "/" + Self.recordFileName
        let temporary = root + "/" + Self.temporaryPrefix
            + UUID().uuidString.lowercased()
        let descriptor = open(
            temporary,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw Self.filesystem("create flight recorder") }
        var removeTemporary = true
        defer {
            _ = close(descriptor)
            if removeTemporary { _ = unlink(temporary) }
        }
        try data.withUnsafeBytes { bytes in
            var remaining = bytes.count
            guard var pointer = bytes.baseAddress else {
                throw DoryMachineFlightRecorderStoreError.invalidRecord
            }
            while remaining > 0 {
                let count = Darwin.write(descriptor, pointer, remaining)
                if count > 0 {
                    remaining -= count
                    pointer = pointer.advanced(by: count)
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw Self.filesystem("write flight recorder")
                }
            }
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0, fsync(descriptor) == 0 else {
            throw Self.filesystem("sync flight recorder")
        }
        guard rename(temporary, path) == 0 else {
            throw Self.filesystem("publish flight recorder")
        }
        removeTemporary = false
        try Self.syncDirectory(root)
    }

    private func withFileLock<T>(_ body: () throws -> T) throws -> T {
        guard Self.isPrivateDirectory(root) else {
            throw DoryMachineFlightRecorderStoreError.invalidRoot
        }
        let path = root + "/" + Self.lockFileName
        let descriptor = open(
            path,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw Self.filesystem("open flight-recorder lock") }
        defer { _ = close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1,
              (info.st_mode & 0o077) == 0 else {
            throw DoryMachineFlightRecorderStoreError.invalidRecord
        }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw Self.filesystem("acquire flight-recorder lock")
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
        guard descriptor >= 0 else { throw filesystem("open flight-recorder directory") }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw filesystem("sync flight-recorder directory")
        }
    }

    private static func filesystem(
        _ operation: String
    ) -> DoryMachineFlightRecorderStoreError {
        .filesystem("\(operation): \(String(cString: strerror(errno)))")
    }
}
