import Darwin
import CryptoKit
import DoryOperations
import Foundation

public enum DoryMachineEventKind: String, Codable, Sendable, Hashable {
    case updated
    case removed
}

/// A bounded, non-secret status projection used to decide when clients must refresh their full
/// immutable machine list. Host paths, environment values, error text, and process identifiers are
/// deliberately absent from both the durable journal and XPC event rows.
public struct DoryMachineEventStatus: Codable, Sendable, Equatable, Hashable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var machineID: String
    /// SHA-256 of non-secret filesystem identity for the authoritative machine configuration.
    /// This changes when persisted configuration bytes are replaced or edited without placing
    /// environment values or host paths in the event journal.
    public var configurationRevision: String
    /// Digest of bounded, non-secret observed fields that are intentionally not duplicated in the
    /// public event row. This makes agent, address, socket-availability, and balloon changes
    /// observable without persisting their values.
    public var observedRevision: String
    public var state: String
    public var hasFailure: Bool
    public var memoryMB: UInt64
    public var cpuCount: Int
    public var displayMode: String
    public var bootMode: String
    public var installerMediaAttached: Bool
    public var shareCount: Int
    public var integrationHealth: String
    public var runtimeMode: String
    public var virtualHardwareABIVersion: UInt16
    public var planRevision: UInt64?
    public var planSHA256: String?
    public var backend: String?
    public var savedStateSHA256: String?

    init(
        status: DoryMachineStatus,
        configurationRevision: String,
        observedRevision: String
    ) {
        schemaVersion = Self.currentSchemaVersion
        machineID = status.id
        self.configurationRevision = configurationRevision
        self.observedRevision = observedRevision
        state = status.state.rawValue
        hasFailure = status.state == .failed || status.lastError != nil
        memoryMB = status.memoryMB
        cpuCount = status.cpuCount
        displayMode = status.displayMode.rawValue
        bootMode = status.bootMode.rawValue
        installerMediaAttached = status.installerMediaAttached
        shareCount = status.shares.count
        integrationHealth = status.integrationHealth.state.rawValue
        runtimeMode = status.runtimeIdentity.mode.rawValue
        virtualHardwareABIVersion = status.runtimeIdentity.virtualHardwareABIVersion
        planRevision = status.runtimeIdentity.planRevision
        planSHA256 = status.runtimeIdentity.resolvedPlanSHA256
        backend = status.runtimeIdentity.backend?.rawValue
        savedStateSHA256 = status.savedState?.stateFileSHA256
    }

    public var isValid: Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              Self.isMachineID(machineID),
              Self.isSHA256(configurationRevision),
              Self.isSHA256(observedRevision),
              DoryMachineState(rawValue: state) != nil,
              memoryMB > 0,
              cpuCount > 0,
              DoryMachineDisplayMode(rawValue: displayMode) != nil,
              DoryMachineBootMode(rawValue: bootMode) != nil,
              shareCount >= 0,
              DoryGuestIntegrationHealthState(rawValue: integrationHealth) != nil,
              DoryMachineRuntimeIdentityMode(rawValue: runtimeMode) != nil,
              virtualHardwareABIVersion > 0,
              savedStateSHA256.map(Self.isSHA256) ?? true else {
            return false
        }
        if runtimeMode == DoryMachineRuntimeIdentityMode.resolvedPlan.rawValue {
            return planRevision.map({ $0 > 0 }) == true
                && planSHA256.map(Self.isSHA256) == true
                && backend.flatMap(DoryVirtualizationBackendIdentity.init(rawValue:)) != nil
        }
        return planRevision == nil && planSHA256 == nil && backend == nil
    }

    private static func isMachineID(_ value: String) -> Bool {
        value.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_.-]{0,62}/) != nil
            && !value.hasPrefix(".")
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    fileprivate static func observedRevisionPayload(status: DoryMachineStatus) throws -> Data {
        let input = DoryMachineEventObservedRevisionInput(
            agentBuild: status.agentBuild,
            agentProtocolVersion: status.agentProtocolVersion,
            agentCapabilities: status.agentCapabilities
                .map { "\($0.id)@\($0.version)" }
                .sorted(),
            effectiveAddress: status.address,
            configuredAddress: status.configuredAddress,
            runtimeAddress: status.runtimeAddress,
            handoffFDCount: status.handoffFDCount,
            currentBalloonTargetMB: status.currentBalloonTargetMB,
            hasAgentSocket: status.agentSocketPath != nil,
            hasDockerSocket: status.dockerdSocketPath != nil,
            hasShellSocket: status.shellSocketPath != nil,
            hasControlSocket: status.controlSocketPath != nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(input)
    }
}

private struct DoryMachineEventObservedRevisionInput: Codable {
    var agentBuild: String?
    var agentProtocolVersion: UInt32?
    var agentCapabilities: [String]
    var effectiveAddress: String?
    var configuredAddress: String?
    var runtimeAddress: String?
    var handoffFDCount: Int
    var currentBalloonTargetMB: UInt64
    var hasAgentSocket: Bool
    var hasDockerSocket: Bool
    var hasShellSocket: Bool
    var hasControlSocket: Bool
}

public struct DoryMachineEvent: Codable, Sendable, Equatable, Hashable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var sequence: UInt64
    public var observedAtUnixMilliseconds: Int64
    public var machineID: String
    public var kind: DoryMachineEventKind
    public var status: DoryMachineEventStatus?

    public init(
        sequence: UInt64,
        observedAtUnixMilliseconds: Int64,
        machineID: String,
        kind: DoryMachineEventKind,
        status: DoryMachineEventStatus?
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.sequence = sequence
        self.observedAtUnixMilliseconds = observedAtUnixMilliseconds
        self.machineID = machineID
        self.kind = kind
        self.status = status
    }

    public var isValid: Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              sequence > 0,
              observedAtUnixMilliseconds > 0,
              machineID.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_.-]{0,62}/) != nil,
              !machineID.hasPrefix(".") else {
            return false
        }
        switch kind {
        case .updated:
            return status?.machineID == machineID && status?.isValid == true
        case .removed:
            return status == nil
        }
    }
}

public struct DoryMachineEventBatch: Sendable, Equatable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var headSequence: UInt64
    public var snapshotRequired: Bool
    public var events: [DoryMachineEvent]

    public init(
        headSequence: UInt64,
        snapshotRequired: Bool,
        events: [DoryMachineEvent]
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.headSequence = headSequence
        self.snapshotRequired = snapshotRequired
        self.events = events
    }
}

enum DoryMachineEventStoreError: Error, Equatable {
    case invalidRoot
    case invalidStatus
    case invalidRecord
    case sequenceExhausted
    case filesystem(String)
}

private struct DoryMachineEventStoreRecord: Codable, Sendable, Equatable {
    static let currentSchemaVersion: UInt16 = 1

    var schemaVersion: UInt16 = Self.currentSchemaVersion
    var headSequence: UInt64
    var projections: [String: DoryMachineEventStatus]
    var events: [DoryMachineEvent]

    var isValid: Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              projections.allSatisfy({ key, value in
                  key == value.machineID && value.isValid
              }),
              events.allSatisfy(\.isValid),
              events == events.sorted(by: { $0.sequence < $1.sequence }),
              Set(events.map(\.sequence)).count == events.count else {
            return false
        }
        if events.isEmpty { return headSequence == 0 }
        guard events.last?.sequence == headSequence,
              let first = events.first?.sequence else { return false }
        let offset = UInt64(events.count - 1)
        guard headSequence >= offset else { return false }
        let expectedFirst = headSequence - offset
        return first == expectedFirst
            && zip(events, events.dropFirst()).allSatisfy { lhs, rhs in
                lhs.sequence < UInt64.max && lhs.sequence + 1 == rhs.sequence
            }
    }
}

/// Cross-process durable event cursor for daemon machine projections. Reconciliation compares a
/// fresh immutable MachineManager list under the service's query lock, publishes one deterministic
/// event per changed workspace, and retains a bounded replay tail. A stale cursor receives an
/// explicit snapshot requirement instead of a partial history.
final class DoryMachineEventStore: @unchecked Sendable {
    static let recordFileName = ".machine-events-v1.json"
    static let lockFileName = ".machine-events-v1.lock"
    static let keyFileName = ".machine-events-v1.key"
    static let keyTemporaryPrefix = ".machine-events-v1.key.tmp-"
    static let temporaryPrefix = ".machine-events-v1.tmp-"
    private static let maximumRecordBytes: Int64 = 16 * 1_024 * 1_024

    let root: String
    private let historyLimit: Int
    private let now: @Sendable () -> Int64
    private let lock = NSLock()

    init(
        root: String,
        historyLimit: Int = 2_048,
        now: @escaping @Sendable () -> Int64 = {
            Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        }
    ) {
        self.root = URL(fileURLWithPath: root).standardizedFileURL.path
        self.historyLimit = max(1, historyLimit)
        self.now = now
    }

    func reconcile(
        statuses: [DoryMachineStatus],
        afterSequence: UInt64
    ) throws -> DoryMachineEventBatch {
        lock.lock()
        defer { lock.unlock() }
        return try withFileLock {
            var record = try readRecord()
            let observationKey = try loadOrCreateObservationKey()
            let projections = try statuses.map { status in
                DoryMachineEventStatus(
                    status: status,
                    configurationRevision: try configurationRevision(
                        machineID: status.id
                    ),
                    observedRevision: try observedRevision(
                        status: status,
                        key: observationKey
                    )
                )
            }
            guard projections.allSatisfy(\.isValid),
                  Set(projections.map(\.machineID)).count == projections.count else {
                throw DoryMachineEventStoreError.invalidStatus
            }
            let current = Dictionary(uniqueKeysWithValues: projections.map {
                ($0.machineID, $0)
            })
            let changedIDs = Set(record.projections.keys).union(current.keys).filter {
                record.projections[$0] != current[$0]
            }.sorted()
            if !changedIDs.isEmpty {
                let timestamp = now()
                guard timestamp > 0 else {
                    throw DoryMachineEventStoreError.invalidRecord
                }
                for machineID in changedIDs {
                    guard record.headSequence < UInt64.max else {
                        throw DoryMachineEventStoreError.sequenceExhausted
                    }
                    record.headSequence += 1
                    if let projection = current[machineID] {
                        record.events.append(DoryMachineEvent(
                            sequence: record.headSequence,
                            observedAtUnixMilliseconds: timestamp,
                            machineID: machineID,
                            kind: .updated,
                            status: projection
                        ))
                    } else {
                        record.events.append(DoryMachineEvent(
                            sequence: record.headSequence,
                            observedAtUnixMilliseconds: timestamp,
                            machineID: machineID,
                            kind: .removed,
                            status: nil
                        ))
                    }
                }
                record.projections = current
                if record.events.count > historyLimit {
                    record.events.removeFirst(record.events.count - historyLimit)
                }
                guard record.isValid else {
                    throw DoryMachineEventStoreError.invalidRecord
                }
                try publish(record)
            }

            let oldest = record.events.first?.sequence
            let fellBehind = oldest.map { oldestSequence in
                oldestSequence > 1 && afterSequence < oldestSequence - 1
            } ?? false
            let snapshotRequired = afterSequence == 0
                || afterSequence > record.headSequence
                || fellBehind
            let events = snapshotRequired ? [] : record.events.filter {
                $0.sequence > afterSequence
            }
            return DoryMachineEventBatch(
                headSequence: record.headSequence,
                snapshotRequired: snapshotRequired,
                events: events
            )
        }
    }

    private func configurationRevision(machineID: String) throws -> String {
        guard machineID.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_.-]{0,62}/) != nil,
              !machineID.hasPrefix(".") else {
            throw DoryMachineEventStoreError.invalidStatus
        }
        let machineDirectory = root + "/" + machineID
        var directoryInfo = stat()
        guard lstat(machineDirectory, &directoryInfo) == 0,
              (directoryInfo.st_mode & S_IFMT) == S_IFDIR,
              directoryInfo.st_uid == getuid(),
              (directoryInfo.st_mode & 0o077) == 0 else {
            throw DoryMachineEventStoreError.invalidStatus
        }
        let path = machineDirectory + "/machine.json"
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw DoryMachineEventStoreError.invalidStatus
        }
        defer { _ = close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1,
              (info.st_mode & 0o077) == 0,
              info.st_size > 0 else {
            throw DoryMachineEventStoreError.invalidStatus
        }
        let authority = [
            String(info.st_dev),
            String(info.st_ino),
            String(info.st_size),
            String(info.st_ctimespec.tv_sec),
            String(info.st_ctimespec.tv_nsec),
        ].joined(separator: ":")
        return SHA256.hash(data: Data(authority.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private func observedRevision(
        status: DoryMachineStatus,
        key: SymmetricKey
    ) throws -> String {
        let payload = try DoryMachineEventStatus.observedRevisionPayload(status: status)
        return HMAC<SHA256>.authenticationCode(for: payload, using: key).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private func loadOrCreateObservationKey() throws -> SymmetricKey {
        let path = root + "/" + Self.keyFileName
        var info = stat()
        if lstat(path, &info) == 0 {
            let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard descriptor >= 0 else { throw Self.filesystem("open machine event key") }
            defer { _ = close(descriptor) }
            guard fstat(descriptor, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_uid == getuid(),
                  info.st_nlink == 1,
                  (info.st_mode & 0o077) == 0,
                  info.st_size == 32 else {
                throw DoryMachineEventStoreError.invalidRecord
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            let data = try handle.readToEnd() ?? Data()
            guard data.count == 32 else {
                throw DoryMachineEventStoreError.invalidRecord
            }
            return SymmetricKey(data: data)
        }
        guard errno == ENOENT else { throw Self.filesystem("inspect machine event key") }

        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        let temporary = root + "/" + Self.keyTemporaryPrefix
            + UUID().uuidString.lowercased()
        let descriptor = open(
            temporary,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw Self.filesystem("create machine event key") }
        var removeTemporary = true
        defer {
            _ = close(descriptor)
            if removeTemporary { _ = unlink(temporary) }
        }
        try write(data, to: descriptor, operation: "write machine event key")
        guard fchmod(descriptor, mode_t(0o600)) == 0, fsync(descriptor) == 0 else {
            throw Self.filesystem("sync machine event key")
        }
        guard rename(temporary, path) == 0 else {
            throw Self.filesystem("publish machine event key")
        }
        removeTemporary = false
        try Self.syncDirectory(root)
        return key
    }

    private func readRecord() throws -> DoryMachineEventStoreRecord {
        let path = root + "/" + Self.recordFileName
        var info = stat()
        if lstat(path, &info) != 0 {
            guard errno == ENOENT else { throw Self.filesystem("inspect machine event record") }
            return DoryMachineEventStoreRecord(
                headSequence: 0,
                projections: [:],
                events: []
            )
        }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw Self.filesystem("open machine event record") }
        defer { _ = close(descriptor) }
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1,
              (info.st_mode & 0o077) == 0,
              info.st_size > 0,
              info.st_size <= Self.maximumRecordBytes else {
            throw DoryMachineEventStoreError.invalidRecord
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.readToEnd() ?? Data()
        guard Int64(data.count) == info.st_size,
              let record = try? JSONDecoder().decode(
                  DoryMachineEventStoreRecord.self,
                  from: data
              ), record.isValid,
              record.events.count <= historyLimit else {
            throw DoryMachineEventStoreError.invalidRecord
        }
        return record
    }

    private func publish(_ record: DoryMachineEventStoreRecord) throws {
        guard record.isValid else { throw DoryMachineEventStoreError.invalidRecord }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(record)
        guard !data.isEmpty, data.count <= Int(Self.maximumRecordBytes) else {
            throw DoryMachineEventStoreError.invalidRecord
        }
        let path = root + "/" + Self.recordFileName
        let temporary = root + "/" + Self.temporaryPrefix
            + UUID().uuidString.lowercased()
        let descriptor = open(
            temporary,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw Self.filesystem("create machine event record") }
        var removeTemporary = true
        defer {
            _ = close(descriptor)
            if removeTemporary { _ = unlink(temporary) }
        }
        try write(data, to: descriptor, operation: "write machine event record")
        guard fchmod(descriptor, mode_t(0o600)) == 0, fsync(descriptor) == 0 else {
            throw Self.filesystem("sync machine event record")
        }
        guard rename(temporary, path) == 0 else {
            throw Self.filesystem("publish machine event record")
        }
        removeTemporary = false
        try Self.syncDirectory(root)
    }

    private func withFileLock<T>(_ body: () throws -> T) throws -> T {
        guard Self.isPrivateDirectory(root) else {
            throw DoryMachineEventStoreError.invalidRoot
        }
        let path = root + "/" + Self.lockFileName
        let descriptor = open(
            path,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw Self.filesystem("open machine event lock") }
        defer { _ = close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1,
              (info.st_mode & 0o077) == 0 else {
            throw DoryMachineEventStoreError.invalidRecord
        }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw Self.filesystem("acquire machine event lock")
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    private static func isPrivateDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
            && (info.st_mode & S_IFMT) == S_IFDIR
            && info.st_uid == getuid()
            && (info.st_mode & 0o077) == 0
    }

    private func write(_ data: Data, to descriptor: Int32, operation: String) throws {
        try data.withUnsafeBytes { bytes in
            var remaining = bytes.count
            guard var pointer = bytes.baseAddress else {
                throw DoryMachineEventStoreError.invalidRecord
            }
            while remaining > 0 {
                let count = Darwin.write(descriptor, pointer, remaining)
                if count > 0 {
                    remaining -= count
                    pointer = pointer.advanced(by: count)
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw Self.filesystem(operation)
                }
            }
        }
    }

    private static func syncDirectory(_ path: String) throws {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw filesystem("open machine event directory") }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else { throw filesystem("sync machine event directory") }
    }

    private static func filesystem(_ operation: String) -> DoryMachineEventStoreError {
        .filesystem("\(operation): \(String(cString: strerror(errno)))")
    }
}
