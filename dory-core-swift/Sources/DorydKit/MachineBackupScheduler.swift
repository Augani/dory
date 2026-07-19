import Darwin
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
    private let queue: DispatchQueue
    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private let incidentWriter: IncidentWriter?
    private var statuses: [String: DoryMachineBackupStatus] = [:]
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
        statuses = try Self.loadDatabase(path: databasePath)
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
        statuses[schedule.machineID] = status
        try persistLocked()
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
        try persistLocked()
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
            statuses[machineID] = completed
            do {
                try persistLocked()
            } catch {
                lock.unlock()
                throw error
            }
            lock.unlock()
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
        let note = "\(Self.managedNotePrefix) \(schedule.machineID)"
        let snapshot = try machines.snapshot(
            id: schedule.machineID,
            note: note,
            createdISO: Self.iso(date),
            snapshotID: nil
        )
        let destination = try Self.canonicalPath(
            schedule.destinationDirectory ?? "\(rootDirectory)/archives/\(schedule.machineID)"
        )
        try Self.ensurePrivateDirectory(destination)
        let archiveName = Self.archiveName(snapshot: snapshot)
        let archivePath = "\(destination)/\(archiveName)"
        let partialPath = "\(destination)/.\(archiveName).\(UUID().uuidString).partial"
        var importedSnapshot: DoryMachineSnapshot?
        var verificationMachineID: String?
        var publishedArchive = false
        do {
            try machines.exportSnapshot(
                machineID: schedule.machineID,
                snapshotID: snapshot.id,
                toPath: partialPath
            )
            try Self.syncPrivateFile(partialPath)
            importedSnapshot = try machines.importSnapshot(fromPath: partialPath)
            let shouldBootVerify = runNumber == 1 || runNumber % schedule.verifyEveryRuns == 0
            if shouldBootVerify, let importedSnapshot {
                let verifyID = "backup-verify-\(UUID().uuidString.lowercased().prefix(12))"
                verificationMachineID = verifyID
                let status = try machines.cloneSnapshot(
                    machineID: importedSnapshot.machineID,
                    snapshotID: importedSnapshot.id,
                    newID: verifyID
                )
                guard status.state == .running else {
                    throw MachineBackupSchedulerError.verificationFailed(
                        "disposable restore \(verifyID) did not reach running"
                    )
                }
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
            guard rename(partialPath, archivePath) == 0 else {
                throw MachineBackupSchedulerError.persistence(
                    "publish archive failed with errno \(errno)"
                )
            }
            publishedArchive = true
            try Self.syncDirectory(destination)
            let retainedSnapshots = try retainSnapshots(schedule: schedule)
            let retainedArchives = try retainArchives(schedule: schedule, directory: destination)
            return BackupResult(
                snapshot: snapshot,
                archivePath: archivePath,
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
            try? FileManager.default.removeItem(atPath: partialPath)
            if publishedArchive {
                try? FileManager.default.removeItem(atPath: archivePath)
                try? Self.syncDirectory(destination)
            }
            try? machines.deleteSnapshot(
                machineID: schedule.machineID,
                snapshotID: snapshot.id
            )
            throw error
        }
    }

    func retainSnapshots(schedule: DoryMachineBackupSchedule) throws -> Int {
        let managed = try machines.listSnapshots(machineID: schedule.machineID).filter {
            $0.note == "\(Self.managedNotePrefix) \(schedule.machineID)"
        }
        for snapshot in managed.dropFirst(schedule.keepLocal) {
            try machines.deleteSnapshot(machineID: schedule.machineID, snapshotID: snapshot.id)
        }
        return min(managed.count, schedule.keepLocal)
    }

    func retainArchives(
        schedule: DoryMachineBackupSchedule,
        directory: String
    ) throws -> Int {
        let prefix = "\(schedule.machineID)--"
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory).filter {
            $0.hasPrefix(prefix) && $0.hasSuffix(".dorymachine")
        }.sorted(by: >)
        for entry in entries.dropFirst(schedule.keepLocal) {
            try FileManager.default.removeItem(atPath: "\(directory)/\(entry)")
        }
        return min(entries.count, schedule.keepLocal)
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

    func persistLocked() throws {
        let database = MachineBackupDatabase(
            statuses: statuses.values.sorted { $0.schedule.machineID < $1.schedule.machineID }
        )
        do {
            let data = try JSONEncoder.canonical.encode(database)
            try Self.publishPrivateFile(data, to: databasePath)
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
        guard chmod(normalized, 0o700) == 0 else {
            throw MachineBackupSchedulerError.persistence("chmod directory failed with errno \(errno)")
        }
    }

    static func publishPrivateFile(_ data: Data, to path: String) throws {
        let partial = "\(path).\(UUID().uuidString).partial"
        let descriptor = open(partial, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw MachineBackupSchedulerError.persistence("create schedule state failed with errno \(errno)")
        }
        var closeDescriptor = true
        do {
            try data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                var offset = 0
                while offset < rawBuffer.count {
                    let written = Darwin.write(descriptor, base.advanced(by: offset), rawBuffer.count - offset)
                    guard written > 0 else {
                        throw MachineBackupSchedulerError.persistence("write schedule state failed with errno \(errno)")
                    }
                    offset += written
                }
            }
            guard fsync(descriptor) == 0, close(descriptor) == 0 else {
                closeDescriptor = false
                throw MachineBackupSchedulerError.persistence("sync schedule state failed with errno \(errno)")
            }
            closeDescriptor = false
            guard rename(partial, path) == 0 else {
                throw MachineBackupSchedulerError.persistence("publish schedule state failed with errno \(errno)")
            }
            try syncDirectory(URL(fileURLWithPath: path).deletingLastPathComponent().path)
        } catch {
            if closeDescriptor { close(descriptor) }
            try? FileManager.default.removeItem(atPath: partial)
            throw error
        }
    }

    static func syncPrivateFile(_ path: String) throws {
        guard chmod(path, 0o600) == 0 else {
            throw MachineBackupSchedulerError.persistence("chmod archive failed with errno \(errno)")
        }
        try validatePrivateRegularFile(path)
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw MachineBackupSchedulerError.persistence("open archive failed with errno \(errno)")
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw MachineBackupSchedulerError.persistence("sync archive failed with errno \(errno)")
        }
    }

    static func validatePrivateRegularFile(_ path: String) throws {
        var value = stat()
        guard lstat(path, &value) == 0,
              (value.st_mode & S_IFMT) == S_IFREG,
              value.st_uid == geteuid(),
              (value.st_mode & 0o077) == 0 else {
            throw MachineBackupSchedulerError.persistence("unsafe private file: \(path)")
        }
    }

    static func syncDirectory(_ path: String) throws {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw MachineBackupSchedulerError.persistence("open backup directory failed with errno \(errno)")
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw MachineBackupSchedulerError.persistence("sync backup directory failed with errno \(errno)")
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

private extension JSONEncoder {
    static var canonical: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
