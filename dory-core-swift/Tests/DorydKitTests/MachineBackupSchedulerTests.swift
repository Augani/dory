@testable import DorydKit
import XCTest

final class MachineBackupSchedulerTests: XCTestCase {
    func testSchedulePersistsAndReloadsWithOwnerOnlyState() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let scheduler = try fixture.scheduler()

        let saved = try scheduler.upsert(DoryMachineBackupSchedule(
            machineID: "dev",
            frequency: .weekly,
            keepLocal: 9,
            verifyEveryRuns: 4
        ))

        XCTAssertEqual(saved.schedule.frequency, .weekly)
        XCTAssertEqual(try fixture.mode(of: fixture.root + "/schedules.json") & 0o777, 0o600)
        let reloaded = try fixture.scheduler()
        XCTAssertEqual(reloaded.list(), [saved])
    }

    func testRunVerifiesBundleBootsRestoreAndRetainsOnlyManagedArtifacts() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.manager.addManualSnapshot()
        let scheduler = try fixture.scheduler()
        _ = try scheduler.upsert(DoryMachineBackupSchedule(
            machineID: "dev",
            frequency: .hourly,
            keepLocal: 2,
            verifyEveryRuns: 2
        ))

        for offset in 0..<3 {
            fixture.clock.date = fixture.clock.date.addingTimeInterval(offset == 0 ? 0 : 3_600)
            _ = try scheduler.runNow(machineID: "dev")
        }

        let status = try XCTUnwrap(scheduler.list().first)
        XCTAssertEqual(status.successfulRuns, 3)
        XCTAssertEqual(status.retainedSnapshots, 2)
        XCTAssertEqual(status.retainedArchives, 2)
        XCTAssertEqual(fixture.manager.bootVerificationCount, 2, "the first and every second run must boot-check")
        XCTAssertEqual(fixture.manager.importCount, 3, "every bundle must pass the real import reader")
        XCTAssertTrue(fixture.manager.snapshotNotes.contains("manual snapshot"))
        XCTAssertEqual(
            fixture.manager.snapshotNotes.filter { $0.hasPrefix(MachineBackupScheduler.managedNotePrefix) }.count,
            2
        )
        let archives = try FileManager.default.contentsOfDirectory(atPath: fixture.root + "/archives/dev")
            .filter { $0.hasSuffix(".dorymachine") }
        XCTAssertEqual(archives.count, 2)
    }

    func testReconcileRunsOnlyWhenDue() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let scheduler = try fixture.scheduler()
        _ = try scheduler.upsert(DoryMachineBackupSchedule(machineID: "dev", frequency: .daily))

        scheduler.reconcileDue(at: fixture.clock.date)
        XCTAssertEqual(fixture.manager.exportCount, 1)
        scheduler.reconcileDue(at: fixture.clock.date.addingTimeInterval(60))
        XCTAssertEqual(fixture.manager.exportCount, 1)
        scheduler.reconcileDue(at: fixture.clock.date.addingTimeInterval(24 * 60 * 60))
        XCTAssertEqual(fixture.manager.exportCount, 2)
    }

    func testVerificationFailureIsPersistedAndDoesNotCountAsSuccess() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.manager.failBootVerification = true
        let scheduler = try fixture.scheduler()
        _ = try scheduler.upsert(DoryMachineBackupSchedule(machineID: "dev"))

        XCTAssertThrowsError(try scheduler.runNow(machineID: "dev"))
        let failed = try XCTUnwrap(scheduler.list().first)
        XCTAssertFalse(failed.inProgress)
        XCTAssertEqual(failed.successfulRuns, 0)
        XCTAssertEqual(failed.consecutiveFailures, 1)
        XCTAssertNotNil(failed.lastError)

        let reloaded = try fixture.scheduler().list().first
        XCTAssertEqual(reloaded?.consecutiveFailures, 1)
        XCTAssertNotNil(reloaded?.lastError)
    }

    func testInterruptedRunRecoversAsVisibleFailure() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(atPath: fixture.root, withIntermediateDirectories: true)
        let body = """
        {
          "schemaVersion" : 1,
          "statuses" : [
            {
              "schedule" : {
                "machineID" : "dev",
                "enabled" : true,
                "frequency" : "daily",
                "keepLocal" : 7,
                "verifyEveryRuns" : 7
              },
              "inProgress" : true,
              "successfulRuns" : 2,
              "consecutiveFailures" : 0,
              "retainedSnapshots" : 2,
              "retainedArchives" : 2
            }
          ]
        }
        """
        try body.write(toFile: fixture.root + "/schedules.json", atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(fixture.root + "/schedules.json", 0o600), 0)

        let status = try XCTUnwrap(fixture.scheduler().list().first)
        XCTAssertFalse(status.inProgress)
        XCTAssertEqual(status.consecutiveFailures, 1)
        XCTAssertEqual(status.lastError, "the daemon stopped during the previous backup attempt")
    }
}

private final class BackupClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_783_392_000)

    var date: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private final class FakeMachineBackupManager: MachineBackupManaging, @unchecked Sendable {
    private let lock = NSLock()
    private let directory: String
    private var snapshots: [DoryMachineSnapshot] = []
    private var sequence = 0
    private var importedSequence = 0
    private var _exportCount = 0
    private var _importCount = 0
    private var _bootVerificationCount = 0
    var failBootVerification = false

    init(directory: String) {
        self.directory = directory
    }

    var exportCount: Int { lock.withLock { _exportCount } }
    var importCount: Int { lock.withLock { _importCount } }
    var bootVerificationCount: Int { lock.withLock { _bootVerificationCount } }
    var snapshotNotes: [String] { lock.withLock { snapshots.map(\.note) } }

    func addManualSnapshot() {
        lock.withLock {
            snapshots.append(Self.snapshot(id: "manual", note: "manual snapshot", createdISO: "2026-01-01T00:00:00Z"))
        }
    }

    func status(id: String) -> DoryMachineStatus? {
        DoryMachineStatus(id: id, state: .running)
    }

    func snapshot(
        id: String,
        note: String,
        createdISO: String,
        snapshotID: String?
    ) throws -> DoryMachineSnapshot {
        lock.withLock {
            sequence += 1
            let result = Self.snapshot(id: snapshotID ?? "scheduled-\(sequence)", note: note, createdISO: createdISO)
            snapshots.insert(result, at: 0)
            return result
        }
    }

    func listSnapshots(machineID: String?) throws -> [DoryMachineSnapshot] {
        lock.withLock { snapshots }
    }

    func cloneSnapshot(machineID: String, snapshotID: String, newID: String) throws -> DoryMachineStatus {
        try lock.withLock {
            if failBootVerification {
                throw MachineBackupSchedulerError.verificationFailed("injected boot failure")
            }
            _bootVerificationCount += 1
            return DoryMachineStatus(id: newID, state: .running)
        }
    }

    func stop(id: String) throws -> DoryMachineStatus {
        DoryMachineStatus(id: id, state: .stopped)
    }

    func delete(id: String) throws {}

    func deleteSnapshot(machineID: String, snapshotID: String) throws {
        lock.withLock { snapshots.removeAll { $0.id == snapshotID } }
    }

    func exportSnapshot(machineID: String, snapshotID: String, toPath path: String) throws {
        lock.withLock { _exportCount += 1 }
        let data = Data("verified bundle \(snapshotID)".utf8)
        guard FileManager.default.createFile(atPath: path, contents: data) else {
            throw MachineBackupSchedulerError.persistence("fixture export failed")
        }
    }

    func importSnapshot(fromPath path: String) throws -> DoryMachineSnapshot {
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else {
            throw MachineBackupSchedulerError.verificationFailed("empty fixture bundle")
        }
        return lock.withLock {
            _importCount += 1
            importedSequence += 1
            let result = Self.snapshot(
                id: "imported-\(importedSequence)",
                note: "imported verification",
                createdISO: "2026-01-01T00:00:00Z"
            )
            snapshots.insert(result, at: 0)
            return result
        }
    }

    private static func snapshot(id: String, note: String, createdISO: String) -> DoryMachineSnapshot {
        DoryMachineSnapshot(
            id: id,
            machineID: "dev",
            note: note,
            createdISO: createdISO,
            rootfsPath: "/tmp/\(id).ext4",
            sizeBytes: 1_024,
            kernelPath: "/tmp/kernel",
            architecture: "arm64",
            memoryMB: 2_048,
            cpuCount: 2
        )
    }
}

private final class Fixture {
    let root: String
    let manager: FakeMachineBackupManager
    let clock = BackupClock()

    init() throws {
        root = NSTemporaryDirectory() + "dory-machine-backups-\(getpid())-\(UUID().uuidString)"
        manager = FakeMachineBackupManager(directory: root)
    }

    func scheduler() throws -> MachineBackupScheduler {
        try MachineBackupScheduler(
            manager: manager,
            rootDirectory: root,
            now: { [clock] in clock.date }
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(atPath: root)
    }

    func mode(of path: String) throws -> mode_t {
        var value = stat()
        guard lstat(path, &value) == 0 else {
            throw MachineBackupSchedulerError.persistence("fixture lstat failed")
        }
        return value.st_mode
    }
}
