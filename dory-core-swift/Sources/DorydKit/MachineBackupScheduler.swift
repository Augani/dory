import Darwin
import DoryOperations
import Foundation

public enum DoryMachineBackupFrequency: String, Codable, CaseIterable, Sendable {
    case hourly
    case daily
    case weekly

    public var interval: TimeInterval {
        switch self {
        case .hourly: 60 * 60
        case .daily: 24 * 60 * 60
        case .weekly: 7 * 24 * 60 * 60
        }
    }
}

public struct DoryMachineBackupSchedule: Codable, Sendable, Equatable {
    public static let maximumRetention = 100
    public static let maximumVerificationInterval = 100

    public var machineID: String
    public var enabled: Bool
    public var frequency: DoryMachineBackupFrequency
    public var keepLocal: Int
    public var verifyEveryRuns: Int
    public var destinationDirectory: String?

    public init(
        machineID: String,
        enabled: Bool = true,
        frequency: DoryMachineBackupFrequency = .daily,
        keepLocal: Int = 7,
        verifyEveryRuns: Int = 7,
        destinationDirectory: String? = nil
    ) {
        self.machineID = machineID
        self.enabled = enabled
        self.frequency = frequency
        self.keepLocal = keepLocal
        self.verifyEveryRuns = verifyEveryRuns
        self.destinationDirectory = destinationDirectory
    }

    public func validate() throws {
        guard Self.isValidID(machineID) else {
            throw MachineBackupSchedulerError.invalidMachineID(machineID)
        }
        guard (1...Self.maximumRetention).contains(keepLocal) else {
            throw MachineBackupSchedulerError.invalidRetention(keepLocal)
        }
        guard (1...Self.maximumVerificationInterval).contains(verifyEveryRuns) else {
            throw MachineBackupSchedulerError.invalidVerificationInterval(verifyEveryRuns)
        }
        if let destinationDirectory {
            guard destinationDirectory.hasPrefix("/"),
                  !destinationDirectory.contains("\0"),
                  !destinationDirectory.split(separator: "/").contains("..") else {
                throw MachineBackupSchedulerError.invalidDestination(destinationDirectory)
            }
        }
    }

    public init(xpcDictionary value: NSDictionary) throws {
        guard let machineID = value["machineID"] as? String,
              let frequencyRaw = value["frequency"] as? String,
              let frequency = DoryMachineBackupFrequency(rawValue: frequencyRaw),
              let keepLocal = (value["keepLocal"] as? NSNumber)?.intValue,
              let verifyEveryRuns = (value["verifyEveryRuns"] as? NSNumber)?.intValue else {
            throw MachineBackupSchedulerError.persistence("invalid XPC schedule")
        }
        self.init(
            machineID: machineID,
            enabled: (value["enabled"] as? NSNumber)?.boolValue ?? true,
            frequency: frequency,
            keepLocal: keepLocal,
            verifyEveryRuns: verifyEveryRuns,
            destinationDirectory: value["destinationDirectory"] as? String
        )
        try validate()
    }

    fileprivate static func isValidID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 63 && value.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
        }
    }
}

public struct DoryMachineBackupStatus: Codable, Sendable, Equatable {
    public var schedule: DoryMachineBackupSchedule
    public var inProgress: Bool
    public var successfulRuns: Int
    public var consecutiveFailures: Int
    public var lastAttemptISO: String?
    public var lastSuccessISO: String?
    public var lastVerificationISO: String?
    public var lastBootVerificationISO: String?
    public var lastSnapshotID: String?
    public var lastArchivePath: String?
    public var nextRunISO: String?
    public var lastError: String?
    public var retainedSnapshots: Int
    public var retainedArchives: Int

    public init(schedule: DoryMachineBackupSchedule) {
        self.schedule = schedule
        inProgress = false
        successfulRuns = 0
        consecutiveFailures = 0
        lastAttemptISO = nil
        lastSuccessISO = nil
        lastVerificationISO = nil
        lastBootVerificationISO = nil
        lastSnapshotID = nil
        lastArchivePath = nil
        nextRunISO = nil
        lastError = nil
        retainedSnapshots = 0
        retainedArchives = 0
    }

    public var xpcDictionary: NSDictionary {
        var value: [String: Any] = [
            "machineID": schedule.machineID,
            "enabled": schedule.enabled,
            "frequency": schedule.frequency.rawValue,
            "keepLocal": schedule.keepLocal,
            "verifyEveryRuns": schedule.verifyEveryRuns,
            "inProgress": inProgress,
            "successfulRuns": successfulRuns,
            "consecutiveFailures": consecutiveFailures,
            "retainedSnapshots": retainedSnapshots,
            "retainedArchives": retainedArchives,
        ]
        if let destinationDirectory = schedule.destinationDirectory {
            value["destinationDirectory"] = destinationDirectory
        }
        if let lastAttemptISO { value["lastAttemptISO"] = lastAttemptISO }
        if let lastSuccessISO { value["lastSuccessISO"] = lastSuccessISO }
        if let lastVerificationISO { value["lastVerificationISO"] = lastVerificationISO }
        if let lastBootVerificationISO { value["lastBootVerificationISO"] = lastBootVerificationISO }
        if let lastSnapshotID { value["lastSnapshotID"] = lastSnapshotID }
        if let lastArchivePath { value["lastArchivePath"] = lastArchivePath }
        if let nextRunISO { value["nextRunISO"] = nextRunISO }
        if let lastError { value["lastError"] = lastError }
        return value as NSDictionary
    }
}

public enum MachineBackupSchedulerError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidMachineID(String)
    case invalidRetention(Int)
    case invalidVerificationInterval(Int)
    case invalidDestination(String)
    case unknownSchedule(String)
    case scheduleBusy(String)
    case machineUnavailable(String)
    case verificationFailed(String)
    case persistence(String)

    public var description: String {
        switch self {
        case let .invalidMachineID(value): "invalid machine backup ID: \(value)"
        case let .invalidRetention(value): "backup retention must be between 1 and 100, got \(value)"
        case let .invalidVerificationInterval(value):
            "restore verification interval must be between 1 and 100 runs, got \(value)"
        case let .invalidDestination(value): "invalid machine backup destination: \(value)"
        case let .unknownSchedule(value): "no machine backup schedule exists for \(value)"
        case let .scheduleBusy(value): "machine backup is already running for \(value)"
        case let .machineUnavailable(value): "machine is unavailable for backup: \(value)"
        case let .verificationFailed(value): "machine backup verification failed: \(value)"
        case let .persistence(value): "machine backup state could not be persisted: \(value)"
        }
    }
}

private struct MachineBackupDatabase: Codable, Sendable, Equatable {
    static let schemaVersion = 1
    var schemaVersion = Self.schemaVersion
    var statuses: [DoryMachineBackupStatus] = []
}

public protocol MachineBackupManaging: Sendable {
    func status(id: String) -> DoryMachineStatus?
    func snapshot(id: String, note: String, createdISO: String, snapshotID: String?) throws -> DoryMachineSnapshot
    func listSnapshots(machineID: String?) throws -> [DoryMachineSnapshot]
    func cloneSnapshot(machineID: String, snapshotID: String, newID: String) throws -> DoryMachineStatus
    func start(id: String, operationID: UUID?) throws -> DoryMachineStatus
    func stop(id: String) throws -> DoryMachineStatus
    func delete(id: String) throws
    func deleteSnapshot(machineID: String, snapshotID: String) throws
    func exportSnapshot(machineID: String, snapshotID: String, toPath path: String) throws
    func importSnapshot(fromPath path: String) throws -> DoryMachineSnapshot
}

extension MachineManager: MachineBackupManaging {}

/// Durable daemon-owned machine backup scheduler. Each run creates a managed local snapshot,
/// exports a content-verified recovery bundle, re-imports it through the real restore reader, and
/// periodically boots a disposable clone. Retention touches only artifacts carrying this
/// scheduler's note/file prefix; manual snapshots are never deleted.
public final class MachineBackupScheduler: @unchecked Sendable {
    public static let managedNotePrefix = "Dory scheduled backup:"

    private let machines: any MachineBackupManaging
    private let rootDirectory: String
    private let databasePath: String
    private let databaseDirectory: BackupDirectoryAuthority
    private let queue: DispatchQueue
    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private let incidentWriter: IncidentWriter?
    private var statuses: [String: DoryMachineBackupStatus] = [:]
    // Every writer must preserve a durable success while its in-memory run is still busy
    // pruning. Unrelated schedule updates otherwise overwrite it with the old running row.
    private var committedRetentionStatuses: [String: DoryMachineBackupStatus] = [:]
    private var timer: DispatchSourceTimer?

    public convenience init(
        machines: MachineManager,
        home: String = NSHomeDirectory(),
        rootDirectory: String? = nil,
        incidentWriter: IncidentWriter? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        try self.init(
            manager: machines,
            home: home,
            rootDirectory: rootDirectory,
            incidentWriter: incidentWriter,
            now: now
        )
    }

    init(
        manager: any MachineBackupManaging,
        home: String = NSHomeDirectory(),
        rootDirectory: String? = nil,
        incidentWriter: IncidentWriter? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        machines = manager
        self.rootDirectory = try Self.canonicalPath(
            rootDirectory ?? "\(home)/.dory/machine-backups"
        )
        databasePath = "\(self.rootDirectory)/schedules.json"
        queue = DispatchQueue(label: "dev.dory.machine-backups", qos: .utility)
        self.now = now
        self.incidentWriter = incidentWriter
        try Self.ensurePrivateDirectory(self.rootDirectory)
        databaseDirectory = try BackupDirectoryAuthority(path: self.rootDirectory)
        statuses = try Self.loadDatabase(path: databasePath)
        try databaseDirectory.validateCurrentPath()
        for key in Array(statuses.keys) where statuses[key]?.inProgress == true {
            statuses[key]?.inProgress = false
            statuses[key]?.consecutiveFailures += 1
            statuses[key]?.lastError = "the daemon stopped during the previous backup attempt"
        }
        try persistLocked()
    }

    deinit {
        stop()
    }

    public func start(interval: TimeInterval = 60) {
        lock.lock()
        guard timer == nil else { lock.unlock(); return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: max(5, interval), leeway: .seconds(2))
        source.setEventHandler { [weak self] in self?.reconcileDue() }
        timer = source
        lock.unlock()
        source.resume()
    }

    public func stop() {
        lock.lock()
        let source = timer
        timer = nil
        lock.unlock()
        source?.cancel()
    }

    public func list() -> [DoryMachineBackupStatus] {
        lock.lock()
        let values = statuses.values.sorted { $0.schedule.machineID < $1.schedule.machineID }
        lock.unlock()
        return values
    }

    @discardableResult
    public func upsert(_ schedule: DoryMachineBackupSchedule) throws -> DoryMachineBackupStatus {
        try schedule.validate()
        guard machines.status(id: schedule.machineID) != nil else {
            throw MachineBackupSchedulerError.machineUnavailable(schedule.machineID)
        }
        lock.lock()
        defer { lock.unlock() }
        var status = statuses[schedule.machineID] ?? DoryMachineBackupStatus(schedule: schedule)
        guard !status.inProgress else {
            throw MachineBackupSchedulerError.scheduleBusy(schedule.machineID)
        }
        status.schedule = schedule
        status.nextRunISO = nextRunISO(status: status, relativeTo: now())
        let previous = statuses[schedule.machineID]
        statuses[schedule.machineID] = status
        do {
            try persistLocked()
        } catch {
            statuses[schedule.machineID] = previous
            throw error
        }
        return status
    }

    public func remove(machineID: String) throws {
        guard DoryMachineBackupSchedule.isValidID(machineID) else {
            throw MachineBackupSchedulerError.invalidMachineID(machineID)
        }
        lock.lock()
        defer { lock.unlock() }
        guard let status = statuses[machineID] else {
            throw MachineBackupSchedulerError.unknownSchedule(machineID)
        }
        guard !status.inProgress else {
            throw MachineBackupSchedulerError.scheduleBusy(machineID)
        }
        statuses.removeValue(forKey: machineID)
        do {
            try persistLocked()
        } catch {
            statuses[machineID] = status
            throw error
        }
    }

    @discardableResult
    public func runNow(machineID: String) throws -> DoryMachineBackupStatus {
        try run(machineID: machineID, at: now(), force: true)
    }

    public func reconcileDue(at date: Date? = nil) {
        let date = date ?? now()
        let due: [String]
        lock.lock()
        due = statuses.values.filter {
            $0.schedule.enabled && !$0.inProgress && isDue($0, at: date)
        }.map(\.schedule.machineID).sorted()
        lock.unlock()
        for machineID in due {
            do {
                _ = try run(machineID: machineID, at: date, force: false)
            } catch {
                incidentWriter?.record(
                    type: "machine.backup_failed",
                    detail: "\(machineID): \(error)"
                )
            }
        }
    }
}

private extension MachineBackupScheduler {
    func run(
        machineID: String,
        at date: Date,
        force: Bool
    ) throws -> DoryMachineBackupStatus {
        let schedule: DoryMachineBackupSchedule
        let runNumber: Int
        lock.lock()
        guard var status = statuses[machineID] else {
            lock.unlock()
            throw MachineBackupSchedulerError.unknownSchedule(machineID)
        }
        guard !status.inProgress else {
            lock.unlock()
            throw MachineBackupSchedulerError.scheduleBusy(machineID)
        }
        guard force || (status.schedule.enabled && isDue(status, at: date)) else {
            lock.unlock()
            return status
        }
        status.inProgress = true
        status.lastAttemptISO = Self.iso(date)
        status.lastError = nil
        statuses[machineID] = status
        do {
            try persistLocked()
        } catch {
            statuses[machineID]?.inProgress = false
            lock.unlock()
            throw error
        }
        schedule = status.schedule
        runNumber = status.successfulRuns + 1
        lock.unlock()

        do {
            let result = try performBackup(
                schedule: schedule,
                runNumber: runNumber,
                at: date
            )
            try result.directory.validateCurrentPath()
            lock.lock()
            guard var completed = statuses[machineID] else {
                lock.unlock()
                throw MachineBackupSchedulerError.unknownSchedule(machineID)
            }
            completed.inProgress = false
            completed.successfulRuns = runNumber
            completed.consecutiveFailures = 0
            completed.lastSuccessISO = Self.iso(date)
            completed.lastVerificationISO = Self.iso(date)
            if result.bootVerified { completed.lastBootVerificationISO = Self.iso(date) }
            completed.lastSnapshotID = result.snapshot.id
            completed.lastArchivePath = result.archivePath
            completed.lastError = nil
            completed.retainedSnapshots = result.retainedSnapshots
            completed.retainedArchives = result.retainedArchives
            completed.nextRunISO = nextRunISO(status: completed, relativeTo: date)
            do {
                // Publish the recovery copy and its success record before deleting any older
                // artifact. Keep the in-memory run busy until maintenance has finished.
                try persistLocked(completedStatus: completed)
                committedRetentionStatuses[machineID] = completed
            } catch {
                lock.unlock()
                throw error
            }
            lock.unlock()
            let retention = maintainRetention(schedule: schedule, protecting: result)
            completed.retainedSnapshots = retention.snapshots
            completed.retainedArchives = retention.archives
            completed.lastError = retention.warning
            lock.lock()
            statuses[machineID] = completed
            committedRetentionStatuses.removeValue(forKey: machineID)
            do {
                try persistLocked()
            } catch {
                // The success record is already durable. A maintenance/statistics write
                // failure must not turn it into a rollback after older copies were pruned.
                let warning = "backup completed; retention state could not be persisted: \(error)"
                completed.lastError = [completed.lastError, warning].compactMap { $0 }.joined(separator: "; ")
                statuses[machineID] = completed
            }
            lock.unlock()
            if let warning = completed.lastError {
                incidentWriter?.record(type: "machine.backup_retention_failed", detail: "\(machineID): \(warning)")
            }
            incidentWriter?.record(
                type: "machine.backup_completed",
                detail: "\(machineID) \(result.snapshot.id) verified=\(result.bootVerified)"
            )
            return completed
        } catch {
            lock.lock()
            if var failed = statuses[machineID] {
                failed.inProgress = false
                failed.consecutiveFailures += 1
                failed.lastError = String(describing: error)
                failed.nextRunISO = nextRunISO(status: failed, relativeTo: date)
                statuses[machineID] = failed
                try? persistLocked()
            }
            lock.unlock()
            incidentWriter?.record(type: "machine.backup_failed", detail: "\(machineID): \(error)")
            throw error
        }
    }

    struct BackupResult {
        let snapshot: DoryMachineSnapshot
        let archivePath: String
        let directory: BackupDirectoryAuthority
        let bootVerified: Bool
        let retainedSnapshots: Int
        let retainedArchives: Int
    }

    func performBackup(
        schedule: DoryMachineBackupSchedule,
        runNumber: Int,
        at date: Date
    ) throws -> BackupResult {
        guard machines.status(id: schedule.machineID) != nil else {
            throw MachineBackupSchedulerError.machineUnavailable(schedule.machineID)
        }
        try databaseDirectory.validateCurrentPath()
        let destination = try Self.canonicalPath(
            schedule.destinationDirectory ?? "\(rootDirectory)/archives/\(schedule.machineID)"
        )
        try Self.ensurePrivateDirectory(destination)
        let directory = try BackupDirectoryAuthority(path: destination)
        let note = "\(Self.managedNotePrefix) \(schedule.machineID)"
        let snapshot = try machines.snapshot(
            id: schedule.machineID,
            note: note,
            createdISO: Self.iso(date),
            snapshotID: nil
        )
        let archiveName = Self.archiveName(snapshot: snapshot)
        let archivePath = "\(destination)/\(archiveName)"
        let partialName = ".\(archiveName).\(UUID().uuidString).partial"
        let partialPath = "\(destination)/\(partialName)"
        var importedSnapshot: DoryMachineSnapshot?
        var verificationMachineID: String?
        var publishedArchive = false
        do {
            try directory.validateLeaf(archiveName)
            try directory.validateLeaf(partialName)
            try directory.validateCurrentPath()
            try machines.exportSnapshot(
                machineID: schedule.machineID,
                snapshotID: snapshot.id,
                toPath: partialPath
            )
            try directory.validateCurrentPath()
            try directory.syncPrivateFile(partialName)
            importedSnapshot = try machines.importSnapshot(fromPath: partialPath)
            try directory.validateCurrentPath()
            let shouldBootVerify = runNumber == 1 || runNumber % schedule.verifyEveryRuns == 0
            if shouldBootVerify, let importedSnapshot {
                let verifyID = "backup-verify-\(UUID().uuidString.lowercased().prefix(12))"
                let clone = try machines.cloneSnapshot(
                    machineID: importedSnapshot.machineID,
                    snapshotID: importedSnapshot.id,
                    newID: verifyID
                )
                guard clone.id == verifyID,
                      clone.state == .created || clone.state == .stopped else {
                    throw MachineBackupSchedulerError.verificationFailed(
                        "disposable restore did not publish the requested workspace"
                    )
                }
                // Clone publishes a planned workspace. Start owns its separate launch and
                // readiness operation; a clone receipt alone is not a boot verification.
                verificationMachineID = verifyID
                try bootVerificationMachine(id: verifyID)
                _ = try machines.stop(id: verifyID)
                try machines.delete(id: verifyID)
                verificationMachineID = nil
            }
            if let importedSnapshot {
                try machines.deleteSnapshot(
                    machineID: importedSnapshot.machineID,
                    snapshotID: importedSnapshot.id
                )
            }
            importedSnapshot = nil
            try directory.publish(partialName, as: archiveName, exclusively: true)
            publishedArchive = true
            try directory.synchronize()
            try directory.validateCurrentPath()
            let retainedSnapshots = try managedSnapshots(schedule: schedule).count
            let retainedArchives = try managedArchiveCount(schedule: schedule, directory: directory)
            return BackupResult(
                snapshot: snapshot,
                archivePath: archivePath,
                directory: directory,
                bootVerified: shouldBootVerify,
                retainedSnapshots: retainedSnapshots,
                retainedArchives: retainedArchives
            )
        } catch {
            if let verificationMachineID {
                _ = try? machines.stop(id: verificationMachineID)
                try? machines.delete(id: verificationMachineID)
            }
            if let importedSnapshot {
                try? machines.deleteSnapshot(
                    machineID: importedSnapshot.machineID,
                    snapshotID: importedSnapshot.id
                )
            }
            // The exporter is only authorized to produce a regular-file leaf. Never turn
            // error cleanup into recursive deletion if that pathname was replaced.
            directory.removeIfPresent(partialName)
            if publishedArchive {
                directory.removeIfPresent(archiveName)
                try? directory.synchronize()
            }
            try? machines.deleteSnapshot(
                machineID: schedule.machineID,
                snapshotID: snapshot.id
            )
            throw error
        }
    }

    private func bootVerificationMachine(id: String) throws {
        let operationID = UUID()
        var observation = try machines.start(id: id, operationID: operationID)
        let deadline = ProcessInfo.processInfo.systemUptime + DoryMachineControlTiming.startSeconds
        while true {
            guard observation.id == id else {
                throw MachineBackupSchedulerError.verificationFailed("disposable start returned another workspace")
            }
            // Completion clears the operation projection just before publishing running.
            // Allow that short transition while rejecting a different active owner in any state.
            guard observation.activeOperationID == nil
                    || observation.activeOperationID == operationID.uuidString.lowercased() else {
                throw MachineBackupSchedulerError.verificationFailed("disposable start has another active owner")
            }
            if observation.state == .running { return }
            guard observation.state == .starting || observation.state == .recovering else {
                throw MachineBackupSchedulerError.verificationFailed(
                    "disposable restore \(id) did not reach running (\(observation.state.rawValue))"
                )
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw MachineBackupSchedulerError.verificationFailed(
                    "disposable restore \(id) did not complete its start operation"
                )
            }
            Thread.sleep(forTimeInterval: 0.05)
            guard let current = machines.status(id: id) else {
                throw MachineBackupSchedulerError.verificationFailed("disposable restore disappeared during start")
            }
            observation = current
        }
    }

    func managedSnapshots(schedule: DoryMachineBackupSchedule) throws -> [DoryMachineSnapshot] {
        try machines.listSnapshots(machineID: schedule.machineID).filter {
            $0.machineID == schedule.machineID && $0.note == "\(Self.managedNotePrefix) \(schedule.machineID)"
        }.sorted {
            $0.createdISO == $1.createdISO ? $0.id > $1.id : $0.createdISO > $1.createdISO
        }
    }

    func retainSnapshots(
        schedule: DoryMachineBackupSchedule,
        protecting snapshotID: String,
        directory: BackupDirectoryAuthority
    ) throws -> Int {
        let managed = try managedSnapshots(schedule: schedule)
        guard managed.contains(where: { $0.id == snapshotID }) else {
            throw MachineBackupSchedulerError.persistence("committed recovery snapshot is missing")
        }
        // The newly committed copy wins over wall-clock ordering, including a clock rollback.
        let older = managed.filter { $0.id != snapshotID }
        for snapshot in older.dropFirst(schedule.keepLocal - 1) {
            try directory.validateCurrentPath()
            try machines.deleteSnapshot(machineID: schedule.machineID, snapshotID: snapshot.id)
            try directory.validateCurrentPath()
        }
        return min(managed.count, schedule.keepLocal)
    }

    func managedArchives(
        schedule: DoryMachineBackupSchedule,
        directory: BackupDirectoryAuthority
    ) throws -> [String] {
        let prefix = "\(schedule.machineID)--"
        return try directory.entries().filter {
            $0.hasPrefix(prefix) && $0.hasSuffix(".dorymachine")
        }.sorted(by: >)
    }

    func retainArchives(
        schedule: DoryMachineBackupSchedule,
        directory: BackupDirectoryAuthority,
        protecting archivePath: String
    ) throws -> Int {
        let entries = try managedArchives(schedule: schedule, directory: directory)
        let protectedName = URL(fileURLWithPath: archivePath).lastPathComponent
        guard entries.contains(protectedName) else {
            throw MachineBackupSchedulerError.persistence("committed recovery archive is missing")
        }
        // Never recursively remove a directory or follow a link merely because its name
        // resembles a scheduler archive. Validate the entire candidate set before pruning.
        for entry in entries { try directory.validatePrivateRegularFile(entry) }
        for entry in entries.filter({ $0 != protectedName }).dropFirst(schedule.keepLocal - 1) {
            try directory.validateCurrentPath()
            try directory.remove(entry)
        }
        try directory.synchronize()
        return min(entries.count, schedule.keepLocal)
    }

    func managedArchiveCount(schedule: DoryMachineBackupSchedule, directory: BackupDirectoryAuthority) throws -> Int {
        try managedArchives(schedule: schedule, directory: directory).filter {
            (try? directory.validatePrivateRegularFile($0)) != nil
        }.count
    }

    func maintainRetention(
        schedule: DoryMachineBackupSchedule,
        protecting result: BackupResult
    ) -> (snapshots: Int, archives: Int, warning: String?) {
        let directory = result.directory
        var snapshots = result.retainedSnapshots
        var archives = result.retainedArchives
        var warnings: [String] = []
        do {
            // Losing the published destination revokes all pruning, including local
            // snapshots. A successor at the same pathname is never the recovery copy.
            try directory.validateCurrentPath()
        } catch {
            return (snapshots, archives, "backup completed; retention directory: \(error)")
        }
        do {
            snapshots = try retainSnapshots(schedule: schedule, protecting: result.snapshot.id, directory: directory)
        } catch {
            snapshots = (try? managedSnapshots(schedule: schedule).count) ?? snapshots
            warnings.append("snapshot retention: \(error)")
        }
        do {
            archives = try retainArchives(schedule: schedule, directory: directory, protecting: result.archivePath)
        } catch {
            archives = (try? managedArchiveCount(schedule: schedule, directory: directory)) ?? archives
            warnings.append("archive retention: \(error)")
        }
        return (snapshots, archives, warnings.isEmpty ? nil : "backup completed; " + warnings.joined(separator: "; "))
    }

    func isDue(_ status: DoryMachineBackupStatus, at date: Date) -> Bool {
        guard let value = status.lastSuccessISO,
              let last = ISO8601DateFormatter().date(from: value) else { return true }
        return date.timeIntervalSince(last) >= status.schedule.frequency.interval
    }

    func nextRunISO(status: DoryMachineBackupStatus, relativeTo date: Date) -> String? {
        guard status.schedule.enabled else { return nil }
        guard let value = status.lastSuccessISO,
              let last = ISO8601DateFormatter().date(from: value) else {
            return Self.iso(date)
        }
        return Self.iso(last.addingTimeInterval(status.schedule.frequency.interval))
    }

    func persistLocked(completedStatus: DoryMachineBackupStatus? = nil) throws {
        var values = statuses
        values.merge(committedRetentionStatuses) { _, committed in committed }
        if let completedStatus { values[completedStatus.schedule.machineID] = completedStatus }
        let database = MachineBackupDatabase(
            statuses: values.values.sorted { $0.schedule.machineID < $1.schedule.machineID }
        )
        do {
            let data = try JSONEncoder.canonical.encode(database)
            try Self.publishPrivateFile(data, name: "schedules.json", directory: databaseDirectory)
        } catch let error as MachineBackupSchedulerError {
            throw error
        } catch {
            throw MachineBackupSchedulerError.persistence(String(describing: error))
        }
    }

    static func loadDatabase(path: String) throws -> [String: DoryMachineBackupStatus] {
        guard FileManager.default.fileExists(atPath: path) else { return [:] }
        do {
            try validatePrivateRegularFile(path)
            let data = try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
            let database = try JSONDecoder().decode(MachineBackupDatabase.self, from: data)
            guard database.schemaVersion == MachineBackupDatabase.schemaVersion else {
                throw MachineBackupSchedulerError.persistence("unsupported schedule schema")
            }
            var result: [String: DoryMachineBackupStatus] = [:]
            for status in database.statuses {
                try status.schedule.validate()
                guard result.updateValue(status, forKey: status.schedule.machineID) == nil else {
                    throw MachineBackupSchedulerError.persistence("duplicate machine schedule")
                }
            }
            return result
        } catch let error as MachineBackupSchedulerError {
            throw error
        } catch {
            throw MachineBackupSchedulerError.persistence(String(describing: error))
        }
    }

    static func ensurePrivateDirectory(_ path: String) throws {
        let normalized = try canonicalPath(path)
        guard normalized.hasPrefix("/"), normalized != "/" else {
            throw MachineBackupSchedulerError.invalidDestination(path)
        }
        var current = ""
        for component in normalized.split(separator: "/", omittingEmptySubsequences: true) {
            current += "/\(component)"
            var value = stat()
            if lstat(current, &value) == 0 {
                guard (value.st_mode & S_IFMT) == S_IFDIR else {
                    throw MachineBackupSchedulerError.invalidDestination(current)
                }
            } else if errno == ENOENT {
                guard mkdir(current, 0o700) == 0 else {
                    throw MachineBackupSchedulerError.persistence(
                        "mkdir \(current) failed with errno \(errno)"
                    )
                }
            } else {
                throw MachineBackupSchedulerError.persistence(
                    "lstat \(current) failed with errno \(errno)"
                )
            }
        }
        let descriptor = open(normalized, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw MachineBackupSchedulerError.persistence("open private directory failed with errno \(errno)")
        }
        defer { close(descriptor) }
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_uid == geteuid() else {
            throw MachineBackupSchedulerError.invalidDestination(normalized)
        }
        guard fchmod(descriptor, 0o700) == 0 else {
            throw MachineBackupSchedulerError.persistence("chmod directory failed with errno \(errno)")
        }
    }

    static func publishPrivateFile(_ data: Data, name: String, directory: BackupDirectoryAuthority) throws {
        try directory.validateCurrentPath()
        let partial = "\(name).\(UUID().uuidString).partial"
        let descriptor = try directory.createPrivateFile(partial)
        guard descriptor >= 0 else {
            throw MachineBackupSchedulerError.persistence("create schedule state failed with errno \(errno)")
        }
        var published = false
        defer {
            close(descriptor)
            if !published { directory.removeIfPresent(partial) }
        }
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), rawBuffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    throw MachineBackupSchedulerError.persistence("write schedule state failed with errno \(written == 0 ? EIO : errno)")
                }
                offset += written
            }
        }
        while fsync(descriptor) != 0 {
            guard errno == EINTR else {
                throw MachineBackupSchedulerError.persistence("sync schedule state failed with errno \(errno)")
            }
        }
        try directory.publish(partial, as: name, exclusively: false)
        published = true
        try directory.synchronize()
        try directory.validateCurrentPath()
    }

    static func validatePrivateRegularFile(_ path: String) throws {
        var value = stat()
        guard lstat(path, &value) == 0,
              (value.st_mode & S_IFMT) == S_IFREG,
              value.st_uid == geteuid(),
              value.st_nlink == 1,
              (value.st_mode & 0o077) == 0 else {
            throw MachineBackupSchedulerError.persistence("unsafe private file: \(path)")
        }
    }

    static func canonicalPath(_ path: String) throws -> String {
        var existing = URL(fileURLWithPath: path).standardizedFileURL
        var suffix: [String] = []
        while existing.path != "/" {
            var value = stat()
            if lstat(existing.path, &value) == 0 { break }
            guard errno == ENOENT else {
                throw MachineBackupSchedulerError.persistence(
                    "lstat \(existing.path) failed with errno \(errno)"
                )
            }
            suffix.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var resolvedBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(existing.path, &resolvedBuffer) != nil else {
            throw MachineBackupSchedulerError.persistence(
                "resolve \(existing.path) failed with errno \(errno)"
            )
        }
        let terminator = resolvedBuffer.firstIndex(of: 0) ?? resolvedBuffer.endIndex
        var resolved = String(
            decoding: resolvedBuffer[..<terminator].map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        for component in suffix {
            if !resolved.hasSuffix("/") { resolved += "/" }
            resolved += component
        }
        return resolved
    }

    static func archiveName(snapshot: DoryMachineSnapshot) -> String {
        let timestamp = snapshot.createdISO.filter { $0.isNumber }
        return "\(snapshot.machineID)--\(timestamp)--\(snapshot.id).dorymachine"
    }

    static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

/// Pins one private directory object for a complete publication/retention lifetime.
/// Path checks revoke new work if that name changes; cleanup always targets the pinned
/// object, never a replacement reached through the old absolute pathname.
final class BackupDirectoryAuthority: @unchecked Sendable {
    let path: String
    private let descriptor: Int32
    private let device: dev_t
    private let inode: ino_t

    init(path: String) throws {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Self.failure("open backup directory") }
        var value = stat()
        guard fstat(fd, &value) == 0, Self.isPrivateDirectory(value) else {
            close(fd)
            throw Self.failure("unsafe backup directory")
        }
        var namedValue = stat()
        guard lstat(path, &namedValue) == 0, Self.isPrivateDirectory(namedValue),
              namedValue.st_dev == value.st_dev, namedValue.st_ino == value.st_ino else {
            close(fd)
            throw MachineBackupSchedulerError.persistence("backup directory ownership changed: \(path)")
        }
        self.path = path
        descriptor = fd
        device = value.st_dev
        inode = value.st_ino
    }

    deinit { close(descriptor) }

    func validateCurrentPath() throws {
        var value = stat()
        guard lstat(path, &value) == 0, Self.isPrivateDirectory(value),
              value.st_dev == device, value.st_ino == inode else {
            throw MachineBackupSchedulerError.persistence("backup directory ownership changed: \(path)")
        }
    }

    func validateLeaf(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\0") else {
            throw MachineBackupSchedulerError.persistence("invalid backup filename")
        }
    }

    func createPrivateFile(_ name: String) throws -> Int32 {
        try validateLeaf(name)
        try validateCurrentPath()
        let fd = openat(descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.failure("create schedule state") }
        return fd
    }

    func syncPrivateFile(_ name: String) throws {
        try validateLeaf(name)
        try validateCurrentPath()
        let fd = openat(descriptor, name, O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw Self.failure("open archive") }
        defer { close(fd) }
        var value = stat()
        guard fstat(fd, &value) == 0, Self.isPrivateRegularFile(value, requirePrivateMode: false) else {
            throw MachineBackupSchedulerError.persistence("unsafe private archive: \(name)")
        }
        guard fchmod(fd, 0o600) == 0 else { throw Self.failure("chmod archive") }
        try Self.synchronize(fd)
    }

    func validatePrivateRegularFile(_ name: String) throws {
        try validateLeaf(name)
        var value = stat()
        guard fstatat(descriptor, name, &value, AT_SYMLINK_NOFOLLOW) == 0,
              Self.isPrivateRegularFile(value) else {
            throw MachineBackupSchedulerError.persistence("unsafe private file: \(name)")
        }
    }

    func publish(_ partial: String, as name: String, exclusively: Bool) throws {
        try validateLeaf(partial)
        try validateLeaf(name)
        try validateCurrentPath()
        try validatePrivateRegularFile(partial)
        guard renameatx_np(descriptor, partial, descriptor, name, exclusively ? UInt32(RENAME_EXCL) : 0) == 0 else {
            throw Self.failure("publish backup file")
        }
    }

    func remove(_ name: String) throws {
        try validateLeaf(name)
        guard unlinkat(descriptor, name, 0) == 0 else { throw Self.failure("remove old archive") }
    }

    func removeIfPresent(_ name: String) {
        guard (try? validateLeaf(name)) != nil else { return }
        _ = unlinkat(descriptor, name, 0)
    }

    func entries() throws -> [String] {
        try validateCurrentPath()
        // A separate open file description gives each scan its own directory offset.
        let scanFD = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard scanFD >= 0 else { throw Self.failure("open archive scan") }
        guard let stream = fdopendir(scanFD) else {
            let savedError = errno
            close(scanFD)
            throw Self.failure("open archive scan", error: savedError)
        }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw Self.failure("read archive directory") }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." { names.append(name) }
        }
        try validateCurrentPath()
        return names
    }

    func synchronize() throws { try Self.synchronize(descriptor) }

    private static func synchronize(_ fd: Int32) throws {
        while fsync(fd) != 0 {
            guard errno == EINTR else { throw failure("sync backup object") }
        }
    }

    private static func isPrivateDirectory(_ value: stat) -> Bool {
        value.st_mode & S_IFMT == S_IFDIR && value.st_uid == geteuid() && value.st_mode & 0o077 == 0
    }

    private static func isPrivateRegularFile(_ value: stat, requirePrivateMode: Bool = true) -> Bool {
        value.st_mode & S_IFMT == S_IFREG && value.st_uid == geteuid() && value.st_nlink == 1
            && (!requirePrivateMode || value.st_mode & 0o077 == 0)
    }

    private static func failure(_ operation: String, error: Int32 = errno) -> MachineBackupSchedulerError {
        .persistence("\(operation) failed with errno \(error)")
    }
}

private extension JSONEncoder {
    static var canonical: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
