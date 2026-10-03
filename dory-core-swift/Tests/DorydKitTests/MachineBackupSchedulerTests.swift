import DoryOperations
@testable import DorydKit
import XCTest

final class MachineBackupSchedulerTests: XCTestCase {
    func testRealMachineManagerBackupRoundTripsBundleABIAndBootVerifies() throws {
        let base = NSTemporaryDirectory()
            + "dory-real-machine-backup-\(getpid())-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let kernel = base + "/kernel"
        let rootfs = base + "/rootfs.ext4"
        try Data("kernel-v1".utf8).write(to: URL(fileURLWithPath: kernel))
        try Data("rootfs-v1".utf8).write(to: URL(fileURLWithPath: rootfs))
        let manager = MachineManager(diagnosticConfiguration: MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: base + "/machines",
            baseArguments: ["30"],
            passMachineArguments: false,
            requiresReadyHandoff: false
        ))
        defer { try? manager.delete(id: "dev") }
        let created = try manager.stageMachineForBootstrap(DoryMachineConfiguration(
            id: "dev",
            kernelPath: kernel,
            rootfsPath: rootfs,
            memoryMB: 2_048,
            cpuCount: 2
        ))
        XCTAssertEqual(created.runtimeIdentity.mode, .legacyCompatibility)
        XCTAssertEqual(
            created.runtimeIdentity.virtualHardwareABIVersion,
            DoryVirtualMachineDefinition.currentVirtualHardwareABIVersion
        )

        let scheduler = try MachineBackupScheduler(
            manager: DiagnosticMachineBackupManager(manager: manager),
            rootDirectory: base + "/backups",
            now: { Date(timeIntervalSince1970: 1_783_392_000) }
        )
        _ = try scheduler.upsert(DoryMachineBackupSchedule(
            machineID: "dev",
            frequency: .daily,
            keepLocal: 1,
            verifyEveryRuns: 1
        ))
        let completed = try scheduler.runNow(machineID: "dev")

        XCTAssertEqual(completed.successfulRuns, 1)
        XCTAssertEqual(completed.retainedSnapshots, 1)
        XCTAssertEqual(completed.retainedArchives, 1)
        XCTAssertNotNil(completed.lastBootVerificationISO)
        let archive = try XCTUnwrap(completed.lastArchivePath)
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: archive))
                .prefix(Data("DORYMACHINE3\n".utf8).count),
            Data("DORYMACHINE3\n".utf8)
        )
        XCTAssertEqual(manager.list().map(\.id), ["dev"])
        let retained = try XCTUnwrap(manager.listSnapshots(machineID: "dev").first)
        XCTAssertEqual(retained.runtimeIdentity, created.runtimeIdentity)

        let imported = try manager.importSnapshot(fromPath: archive)
        defer { try? manager.deleteSnapshot(machineID: imported.machineID, snapshotID: imported.id) }
        XCTAssertEqual(imported.runtimeIdentity, created.runtimeIdentity)
        XCTAssertEqual(
            imported.runtimeIdentity.virtualHardwareABIVersion,
            DoryVirtualMachineDefinition.currentVirtualHardwareABIVersion
        )
        XCTAssertEqual(
            try String(contentsOfFile: imported.rootfsPath, encoding: .utf8),
            "rootfs-v1"
        )
        XCTAssertEqual(
            try String(contentsOfFile: imported.kernelPath, encoding: .utf8),
            "kernel-v1"
        )
    }

    func testRealMachineManagerBackupRollsBackWhenDisposableBootFails() throws {
        let base = NSTemporaryDirectory()
            + "dory-real-machine-backup-failure-\(getpid())-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let kernel = base + "/kernel"
        let rootfs = base + "/rootfs.ext4"
        try Data("kernel-v1".utf8).write(to: URL(fileURLWithPath: kernel))
        try Data("rootfs-v1".utf8).write(to: URL(fileURLWithPath: rootfs))
        let manager = MachineManager(diagnosticConfiguration: MachineManagerConfiguration(
            vmmExecutablePath: base + "/missing-vmm",
            stateDirectory: base + "/machines",
            passMachineArguments: false,
            requiresReadyHandoff: false
        ))
        defer { try? manager.delete(id: "dev") }
        _ = try manager.stageMachineForBootstrap(DoryMachineConfiguration(
            id: "dev",
            kernelPath: kernel,
            rootfsPath: rootfs
        ))
        let scheduler = try MachineBackupScheduler(
            manager: DiagnosticMachineBackupManager(manager: manager),
            rootDirectory: base + "/backups",
            now: { Date(timeIntervalSince1970: 1_783_392_000) }
        )
        _ = try scheduler.upsert(DoryMachineBackupSchedule(
            machineID: "dev",
            keepLocal: 1,
            verifyEveryRuns: 1
        ))

        XCTAssertThrowsError(try scheduler.runNow(machineID: "dev"))
        let failed = try XCTUnwrap(scheduler.list().first)
        XCTAssertEqual(failed.successfulRuns, 0)
        XCTAssertEqual(failed.consecutiveFailures, 1)
        XCTAssertNotNil(failed.lastError)
        XCTAssertTrue(try manager.listSnapshots(machineID: "dev").isEmpty)
        XCTAssertEqual(manager.list().map(\.id), ["dev"])
        let archiveDirectory = base + "/backups/archives/dev"
        let archives = (try? FileManager.default.contentsOfDirectory(atPath: archiveDirectory)) ?? []
        XCTAssertTrue(archives.filter { $0.hasSuffix(".dorymachine") }.isEmpty)
        XCTAssertFalse(archives.contains { $0.hasSuffix(".partial") })
    }

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
        XCTAssertEqual(fixture.manager.cloneCount, 2)
        XCTAssertEqual(fixture.manager.verificationObservationCount, 4, "start must wait through completion before running publication")
        XCTAssertEqual(fixture.manager.deletedMachineIDs.count, 2)
        XCTAssertFalse(fixture.manager.deletedMachineIDs.contains("dev"))
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

    func testVerificationRejectsFailedReadinessAndDeletesOnlyItsClone() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.manager.failReadiness = true
        let scheduler = try fixture.scheduler()
        _ = try scheduler.upsert(DoryMachineBackupSchedule(machineID: "dev"))
        XCTAssertThrowsError(try scheduler.runNow(machineID: "dev"))
        XCTAssertEqual(fixture.manager.cloneCount, 1)
        XCTAssertEqual(fixture.manager.bootVerificationCount, 1)
        XCTAssertEqual(fixture.manager.verificationObservationCount, 1)
        XCTAssertEqual(fixture.manager.deletedMachineIDs.count, 1)
        XCTAssertTrue(fixture.manager.deletedMachineIDs.allSatisfy { $0.hasPrefix("backup-verify-") })
        XCTAssertEqual(scheduler.list().first?.successfulRuns, 0)
    }

    func testVerificationRejectsForeignCloneWithoutStartingOrDeletingIt() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.manager.returnForeignClone = true
        let scheduler = try fixture.scheduler()
        _ = try scheduler.upsert(DoryMachineBackupSchedule(machineID: "dev"))
        XCTAssertThrowsError(try scheduler.runNow(machineID: "dev"))
        XCTAssertEqual(fixture.manager.bootVerificationCount, 0)
        XCTAssertTrue(fixture.manager.deletedMachineIDs.isEmpty)
        XCTAssertEqual(scheduler.list().first?.successfulRuns, 0)
    }

    func testVerificationRejectsRunningObservationOwnedByAnotherStart() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.manager.returnForeignStartOperation = true
        let scheduler = try fixture.scheduler()
        _ = try scheduler.upsert(DoryMachineBackupSchedule(machineID: "dev"))
        XCTAssertThrowsError(try scheduler.runNow(machineID: "dev"))
        XCTAssertEqual(fixture.manager.bootVerificationCount, 1)
        XCTAssertEqual(fixture.manager.verificationObservationCount, 0)
        XCTAssertEqual(fixture.manager.deletedMachineIDs.count, 1)
        XCTAssertTrue(fixture.manager.deletedMachineIDs.allSatisfy { $0.hasPrefix("backup-verify-") })
        XCTAssertEqual(scheduler.list().first?.successfulRuns, 0)
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

    func testPartialRetentionFailureKeepsCommittedRecoveryCopyAndDurableSuccess() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let scheduler = try fixture.scheduler()
        _ = try scheduler.upsert(DoryMachineBackupSchedule(machineID: "dev", keepLocal: 3))
        for _ in 0..<3 {
            _ = try scheduler.runNow(machineID: "dev")
            fixture.clock.date = fixture.clock.date.addingTimeInterval(3_600)
        }
        _ = try scheduler.upsert(DoryMachineBackupSchedule(machineID: "dev", keepLocal: 1))
        fixture.manager.failScheduledDeletionAfter = 1
        fixture.manager.onScheduledSnapshotDeletion = {
            let data = try Data(contentsOf: URL(fileURLWithPath: fixture.root + "/schedules.json"))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let row = try XCTUnwrap((body["statuses"] as? [[String: Any]])?.first)
            XCTAssertEqual(row["successfulRuns"] as? Int, 4, "success must be durable before any prune")
            XCTAssertEqual(row["inProgress"] as? Bool, false)
            let archive = try XCTUnwrap(row["lastArchivePath"] as? String)
            XCTAssertTrue(FileManager.default.fileExists(atPath: archive))
            XCTAssertThrowsError(try scheduler.remove(machineID: "dev"), "the maintenance owner remains busy")
        }

        let completed = try scheduler.runNow(machineID: "dev")
        XCTAssertEqual(completed.successfulRuns, 4)
        XCTAssertEqual(completed.consecutiveFailures, 0)
        XCTAssertTrue(completed.lastError?.contains("snapshot retention") == true)
        XCTAssertEqual(completed.retainedSnapshots, 3)
        XCTAssertEqual(completed.retainedArchives, 1)
        let snapshotID = try XCTUnwrap(completed.lastSnapshotID)
        XCTAssertTrue(try fixture.manager.listSnapshots(machineID: "dev").contains { $0.id == snapshotID })
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(completed.lastArchivePath)))
        XCTAssertEqual(try fixture.scheduler().list().first, completed)
    }

    func testClockRollbackCannotPruneNewlyCommittedSnapshotOrArchive() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let scheduler = try fixture.scheduler()
        _ = try scheduler.upsert(DoryMachineBackupSchedule(machineID: "dev", keepLocal: 1))
        let first = try scheduler.runNow(machineID: "dev")
        fixture.clock.date = fixture.clock.date.addingTimeInterval(-86_400)
        fixture.manager.returnSnapshotsOldestFirst = true

        let completed = try scheduler.runNow(machineID: "dev")
        let snapshots = try fixture.manager.listSnapshots(machineID: "dev")
            .filter { $0.note.hasPrefix(MachineBackupScheduler.managedNotePrefix) }
        XCTAssertEqual(snapshots.map(\.id), [try XCTUnwrap(completed.lastSnapshotID)])
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(completed.lastArchivePath)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(first.lastArchivePath)))
        XCTAssertNil(completed.lastError)
    }

    func testArchiveShapedDirectoryIsNotRecursivelyDeletedByRetention() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let scheduler = try fixture.scheduler()
        _ = try scheduler.upsert(DoryMachineBackupSchedule(machineID: "dev", keepLocal: 1))
        let first = try scheduler.runNow(machineID: "dev")
        let unexpected = fixture.root + "/archives/dev/dev--0000--external.dorymachine"
        try FileManager.default.createDirectory(atPath: unexpected, withIntermediateDirectories: false)
        let sentinel = unexpected + "/must-preserve"
        try Data("external contents".utf8).write(to: URL(fileURLWithPath: sentinel))
        fixture.clock.date = fixture.clock.date.addingTimeInterval(3_600)

        let completed = try scheduler.runNow(machineID: "dev")
        XCTAssertEqual(completed.successfulRuns, 2)
        XCTAssertTrue(completed.lastError?.contains("archive retention") == true)
        XCTAssertEqual(completed.retainedArchives, 2, "an unsafe directory is not a recovery archive")
        XCTAssertEqual(try String(contentsOfFile: sentinel, encoding: .utf8), "external contents")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(first.lastArchivePath)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(completed.lastArchivePath)))
    }

    func testFailureToCommitSuccessRecordNeverRunsRetentionOrDeletesLastGood() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let scheduler = try fixture.scheduler()
        _ = try scheduler.upsert(DoryMachineBackupSchedule(machineID: "dev", keepLocal: 1))
        let first = try scheduler.runNow(machineID: "dev")
        var deletionCount = 0
        fixture.manager.onScheduledSnapshotDeletion = { deletionCount += 1 }
        fixture.manager.afterExport = {
            let path = fixture.root + "/schedules.json"
            try FileManager.default.moveItem(atPath: path, toPath: path + ".saved")
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        }
        fixture.clock.date = fixture.clock.date.addingTimeInterval(3_600)

        XCTAssertThrowsError(try scheduler.runNow(machineID: "dev"))
        XCTAssertEqual(deletionCount, 0, "no prune is allowed without the durable completion record")
        let failed = try XCTUnwrap(scheduler.list().first)
        XCTAssertEqual(failed.successfulRuns, 1)
        XCTAssertEqual(failed.lastSnapshotID, first.lastSnapshotID)
        XCTAssertEqual(failed.lastArchivePath, first.lastArchivePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(first.lastArchivePath)))
        XCTAssertTrue(try fixture.manager.listSnapshots(machineID: "dev").contains { $0.id == first.lastSnapshotID })
    }

    func testLinkedExportCannotChangeExternalFilePermissionsOrBecomeABackup() throws {
        for symbolic in [true, false] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let scheduler = try fixture.scheduler()
            _ = try scheduler.upsert(DoryMachineBackupSchedule(machineID: "dev"))
            let external = fixture.root + "/external-source"
            try Data("preserve external file".utf8).write(to: URL(fileURLWithPath: external))
            XCTAssertEqual(chmod(external, 0o640), 0)
            fixture.manager.afterExport = {
                let directory = fixture.root + "/archives/dev"
                let name = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: directory)
                    .first { $0.hasSuffix(".partial") })
                let path = directory + "/" + name
                try FileManager.default.removeItem(atPath: path)
                if symbolic {
                    try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: external)
                } else {
                    try FileManager.default.linkItem(atPath: external, toPath: path)
                }
            }

            XCTAssertThrowsError(try scheduler.runNow(machineID: "dev"))
            XCTAssertEqual(try fixture.mode(of: external) & 0o777, 0o640)
            XCTAssertEqual(try String(contentsOfFile: external, encoding: .utf8), "preserve external file")
            XCTAssertEqual(fixture.manager.importCount, 0)
            XCTAssertEqual(scheduler.list().first?.successfulRuns, 0)
        }
    }

    func testArchivePublicationNeverOverwritesAnExistingDestination() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let scheduler = try fixture.scheduler()
        _ = try scheduler.upsert(DoryMachineBackupSchedule(machineID: "dev", keepLocal: 1))
        let first = try scheduler.runNow(machineID: "dev")
        var collisionPath: String?
        fixture.manager.afterExport = {
            let directory = fixture.root + "/archives/dev"
            let partial = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: directory)
                .first { $0.hasSuffix(".partial") })
            let archiveSuffix = try XCTUnwrap(partial.range(of: ".dorymachine"))
            let name = String(partial[partial.index(after: partial.startIndex)..<archiveSuffix.upperBound])
            let path = directory + "/" + name
            collisionPath = path
            try Data("pre-existing archive".utf8).write(to: URL(fileURLWithPath: path))
            XCTAssertEqual(chmod(path, 0o600), 0)
        }
        fixture.clock.date = fixture.clock.date.addingTimeInterval(3_600)

        XCTAssertThrowsError(try scheduler.runNow(machineID: "dev"))
        XCTAssertEqual(try String(contentsOfFile: XCTUnwrap(collisionPath), encoding: .utf8), "pre-existing archive")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(first.lastArchivePath)))
        XCTAssertEqual(scheduler.list().first?.lastArchivePath, first.lastArchivePath)
    }

    func testUnrelatedScheduleWriteCannotOverwriteCommittedSuccessDuringRetention() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.manager.availableMachineIDs.insert("other")
        let scheduler = try fixture.scheduler()
        _ = try scheduler.upsert(DoryMachineBackupSchedule(machineID: "dev", keepLocal: 1))
        let first = try scheduler.runNow(machineID: "dev")
        fixture.manager.onScheduledSnapshotDeletion = {
            _ = try scheduler.upsert(DoryMachineBackupSchedule(machineID: "other", enabled: false))
            let data = try Data(contentsOf: URL(fileURLWithPath: fixture.root + "/schedules.json"))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let rows = try XCTUnwrap(body["statuses"] as? [[String: Any]])
            let committed = try XCTUnwrap(rows.first { $0["lastSnapshotID"] as? String == "scheduled-2" })
            XCTAssertEqual(committed["successfulRuns"] as? Int, 2)
            XCTAssertEqual(committed["inProgress"] as? Bool, false)
            XCTAssertNotEqual(committed["lastArchivePath"] as? String, first.lastArchivePath)
            XCTAssertThrowsError(try scheduler.runNow(machineID: "dev"))
            XCTAssertThrowsError(try scheduler.remove(machineID: "dev"))
        }
        fixture.clock.date = fixture.clock.date.addingTimeInterval(3_600)

        let completed = try scheduler.runNow(machineID: "dev")
        XCTAssertEqual(completed.successfulRuns, 2)
        XCTAssertEqual(try fixture.scheduler().list().first { $0.schedule.machineID == "dev" }, completed)
        XCTAssertTrue(scheduler.list().contains { $0.schedule.machineID == "other" })
    }

    func testReplacedExportDirectoryNeverImportsSecuresOrDeletesSuccessorFiles() throws {
        for exporterThrows in [false, true] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let scheduler = try fixture.scheduler()
            _ = try scheduler.upsert(DoryMachineBackupSchedule(machineID: "dev", keepLocal: 1))
            let first = try scheduler.runNow(machineID: "dev")
            let originalImports = fixture.manager.importCount
            let directory = fixture.root + "/archives/dev"
            let retired = fixture.root + "/retired-archives"
            var partialName: String?
            fixture.manager.afterExport = {
                let name = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: directory)
                    .first { $0.hasSuffix(".partial") })
                partialName = name
                try FileManager.default.moveItem(atPath: directory, toPath: retired)
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
                XCTAssertEqual(chmod(directory, 0o700), 0)
                let successor = directory + "/" + name
                try Data("successor must survive".utf8).write(to: URL(fileURLWithPath: successor))
                XCTAssertEqual(chmod(successor, 0o640), 0)
                if exporterThrows { throw MachineBackupSchedulerError.persistence("injected exporter failure") }
            }
            fixture.clock.date = fixture.clock.date.addingTimeInterval(3_600)

            XCTAssertThrowsError(try scheduler.runNow(machineID: "dev"))
            let name = try XCTUnwrap(partialName)
            let successor = directory + "/" + name
            XCTAssertEqual(try String(contentsOfFile: successor, encoding: .utf8), "successor must survive")
            XCTAssertEqual(try fixture.mode(of: successor) & 0o777, 0o640)
            XCTAssertFalse(FileManager.default.fileExists(atPath: retired + "/" + name), "only the pinned partial is cleaned")
            let previousName = URL(fileURLWithPath: try XCTUnwrap(first.lastArchivePath)).lastPathComponent
            XCTAssertTrue(FileManager.default.fileExists(atPath: retired + "/" + previousName))
            XCTAssertEqual(fixture.manager.importCount, originalImports)
            XCTAssertEqual(scheduler.list().first?.successfulRuns, 1)
            XCTAssertEqual(try fixture.manager.listSnapshots(machineID: "dev")
                .filter { $0.note == "\(MachineBackupScheduler.managedNotePrefix) dev" }.map(\.id),
                [try XCTUnwrap(first.lastSnapshotID)])
        }
    }

    func testRetentionCannotPruneAReplacementDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let scheduler = try fixture.scheduler()
        _ = try scheduler.upsert(DoryMachineBackupSchedule(machineID: "dev", keepLocal: 1))
        _ = try scheduler.runNow(machineID: "dev")
        let directory = fixture.root + "/archives/dev"
        let retired = fixture.root + "/retired-archives"
        var successorNames: [String] = []
        fixture.manager.onScheduledSnapshotDeletion = {
            successorNames = try FileManager.default.contentsOfDirectory(atPath: directory)
                .filter { $0.hasSuffix(".dorymachine") }
            try FileManager.default.moveItem(atPath: directory, toPath: retired)
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
            XCTAssertEqual(chmod(directory, 0o700), 0)
            for name in successorNames {
                let path = directory + "/" + name
                try Data("foreign archive".utf8).write(to: URL(fileURLWithPath: path))
                XCTAssertEqual(chmod(path, 0o600), 0)
            }
        }
        fixture.clock.date = fixture.clock.date.addingTimeInterval(3_600)

        let completed = try scheduler.runNow(machineID: "dev")
        XCTAssertEqual(completed.successfulRuns, 2)
        XCTAssertTrue(completed.lastError?.contains("ownership changed") == true)
        XCTAssertEqual(successorNames.count, 2)
        for name in successorNames {
            XCTAssertEqual(try String(contentsOfFile: directory + "/" + name, encoding: .utf8), "foreign archive")
            XCTAssertTrue(FileManager.default.fileExists(atPath: retired + "/" + name))
        }
        XCTAssertTrue(try fixture.manager.listSnapshots(machineID: "dev")
            .contains { $0.id == completed.lastSnapshotID })
        XCTAssertEqual(try fixture.scheduler().list().first?.successfulRuns, 2)
    }

    func testScheduleDatabaseCannotPublishIntoAReplacementRoot() throws {
        for removal in [false, true] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let scheduler = try fixture.scheduler()
            let original = try scheduler.upsert(DoryMachineBackupSchedule(machineID: "dev"))
            let retired = fixture.root + ".retired"
            defer { try? FileManager.default.removeItem(atPath: retired) }
            let originalData = try Data(contentsOf: URL(fileURLWithPath: fixture.root + "/schedules.json"))
            try FileManager.default.moveItem(atPath: fixture.root, toPath: retired)
            try FileManager.default.createDirectory(atPath: fixture.root, withIntermediateDirectories: false)
            XCTAssertEqual(chmod(fixture.root, 0o700), 0)
            let successorPath = fixture.root + "/schedules.json"
            try Data("foreign state".utf8).write(to: URL(fileURLWithPath: successorPath))
            XCTAssertEqual(chmod(successorPath, 0o600), 0)

            if removal {
                XCTAssertThrowsError(try scheduler.remove(machineID: "dev"))
            } else {
                XCTAssertThrowsError(try scheduler.upsert(DoryMachineBackupSchedule(machineID: "dev", enabled: false)))
            }
            XCTAssertEqual(scheduler.list(), [original])
            XCTAssertEqual(try String(contentsOfFile: successorPath, encoding: .utf8), "foreign state")
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: retired + "/schedules.json")), originalData)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root), ["schedules.json"])
        }
    }

    func testRejectedScheduleUpdateOrRemovalPreservesItsInMemoryState() throws {
        for removal in [false, true] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let scheduler = try fixture.scheduler()
            let original = try scheduler.upsert(DoryMachineBackupSchedule(machineID: "dev", keepLocal: 3))
            let path = fixture.root + "/schedules.json"
            try FileManager.default.moveItem(atPath: path, toPath: path + ".saved")
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)

            if removal {
                XCTAssertThrowsError(try scheduler.remove(machineID: "dev"))
            } else {
                XCTAssertThrowsError(try scheduler.upsert(DoryMachineBackupSchedule(machineID: "dev", enabled: false)))
            }
            XCTAssertEqual(scheduler.list(), [original])
            try FileManager.default.removeItem(atPath: path)
            try FileManager.default.moveItem(atPath: path + ".saved", toPath: path)
            XCTAssertEqual(try fixture.scheduler().list(), [original])
        }
    }
}

/// Keeps the tiny bundle/ABI fixture on the explicit diagnostic staging path. Public
/// production clone still requires its real planner; the scheduler always receives a stopped clone.
private struct DiagnosticMachineBackupManager: MachineBackupManaging {
    let manager: MachineManager

    func status(id: String) -> DoryMachineStatus? { manager.status(id: id) }
    func snapshot(id: String, note: String, createdISO: String, snapshotID: String?) throws -> DoryMachineSnapshot {
        try manager.snapshot(id: id, note: note, createdISO: createdISO, snapshotID: snapshotID)
    }
    func listSnapshots(machineID: String?) throws -> [DoryMachineSnapshot] {
        try manager.listSnapshots(machineID: machineID)
    }
    func cloneSnapshot(machineID: String, snapshotID: String, newID: String) throws -> DoryMachineStatus {
        _ = try manager.stageCloneSnapshotForBootstrap(machineID: machineID, snapshotID: snapshotID, newID: newID)
        return try manager.stop(id: newID)
    }
    func start(id: String, operationID: UUID?) throws -> DoryMachineStatus {
        try manager.start(id: id, operationID: operationID)
    }
    func stop(id: String) throws -> DoryMachineStatus { try manager.stop(id: id) }
    func delete(id: String) throws { try manager.delete(id: id) }
    func deleteSnapshot(machineID: String, snapshotID: String) throws {
        try manager.deleteSnapshot(machineID: machineID, snapshotID: snapshotID)
    }
    func exportSnapshot(machineID: String, snapshotID: String, toPath path: String) throws {
        try manager.exportSnapshot(machineID: machineID, snapshotID: snapshotID, toPath: path)
    }
    func importSnapshot(fromPath path: String) throws -> DoryMachineSnapshot {
        try manager.importSnapshot(fromPath: path)
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
    private var _cloneCount = 0
    private var _verificationObservationCount = 0
    private var _deletedMachineIDs: [String] = []
    private var clonedMachineIDs = Set<String>()
    private var startedMachineIDs = Set<String>()
    private var pendingReadinessPublicationIDs = Set<String>()
    var failBootVerification = false
    var failReadiness = false
    var returnForeignClone = false
    var returnForeignStartOperation = false
    var availableMachineIDs: Set<String> = ["dev"]
    var returnSnapshotsOldestFirst = false
    var failScheduledDeletionAfter: Int?
    var onScheduledSnapshotDeletion: (() throws -> Void)?
    var afterExport: (() throws -> Void)?
    private var scheduledDeletionCount = 0

    init(directory: String) {
        self.directory = directory
    }

    var exportCount: Int { lock.withLock { _exportCount } }
    var importCount: Int { lock.withLock { _importCount } }
    var bootVerificationCount: Int { lock.withLock { _bootVerificationCount } }
    var cloneCount: Int { lock.withLock { _cloneCount } }
    var verificationObservationCount: Int { lock.withLock { _verificationObservationCount } }
    var deletedMachineIDs: [String] { lock.withLock { _deletedMachineIDs } }
    var snapshotNotes: [String] { lock.withLock { snapshots.map(\.note) } }

    func addManualSnapshot() {
        lock.withLock {
            snapshots.append(Self.snapshot(id: "manual", note: "manual snapshot", createdISO: "2026-01-01T00:00:00Z"))
        }
    }

    func status(id: String) -> DoryMachineStatus? {
        lock.withLock {
            if availableMachineIDs.contains(id) { return DoryMachineStatus(id: id, state: .running) }
            guard clonedMachineIDs.contains(id) else { return nil }
            guard startedMachineIDs.contains(id) else { return DoryMachineStatus(id: id, state: .stopped) }
            _verificationObservationCount += 1
            if !failReadiness, pendingReadinessPublicationIDs.remove(id) != nil {
                return DoryMachineStatus(id: id, state: .starting)
            }
            return DoryMachineStatus(id: id, state: failReadiness ? .failed : .running)
        }
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
        lock.withLock { returnSnapshotsOldestFirst ? Array(snapshots.reversed()) : snapshots }
    }

    func cloneSnapshot(machineID: String, snapshotID: String, newID: String) throws -> DoryMachineStatus {
        lock.withLock {
            _cloneCount += 1
            if returnForeignClone { return DoryMachineStatus(id: "foreign", state: .stopped) }
            clonedMachineIDs.insert(newID)
            return DoryMachineStatus(id: newID, state: .stopped)
        }
    }

    func start(id: String, operationID: UUID?) throws -> DoryMachineStatus {
        try lock.withLock {
            guard clonedMachineIDs.contains(id), let operationID else {
                throw MachineBackupSchedulerError.verificationFailed("start requires its cloned workspace and UUID")
            }
            _bootVerificationCount += 1
            if failBootVerification {
                throw MachineBackupSchedulerError.verificationFailed("injected boot failure")
            }
            if returnForeignStartOperation {
                return DoryMachineStatus(id: id, state: .running,
                    activeOperationID: UUID().uuidString.lowercased(), activeOperationKind: "starting")
            }
            startedMachineIDs.insert(id)
            pendingReadinessPublicationIDs.insert(id)
            return DoryMachineStatus(id: id, state: .starting,
                activeOperationID: operationID.uuidString.lowercased(), activeOperationKind: "starting")
        }
    }

    func stop(id: String) throws -> DoryMachineStatus {
        DoryMachineStatus(id: id, state: .stopped)
    }

    func delete(id: String) throws {
        lock.withLock {
            _deletedMachineIDs.append(id)
            clonedMachineIDs.remove(id)
            startedMachineIDs.remove(id)
            pendingReadinessPublicationIDs.remove(id)
        }
    }

    func deleteSnapshot(machineID: String, snapshotID: String) throws {
        if snapshotID.hasPrefix("scheduled-") { try onScheduledSnapshotDeletion?() }
        try lock.withLock {
            if snapshotID.hasPrefix("scheduled-") {
                if let failScheduledDeletionAfter, scheduledDeletionCount >= failScheduledDeletionAfter {
                    throw MachineBackupSchedulerError.persistence("injected retention failure")
                }
                scheduledDeletionCount += 1
            }
            snapshots.removeAll { $0.id == snapshotID }
        }
    }

    func exportSnapshot(machineID: String, snapshotID: String, toPath path: String) throws {
        lock.withLock { _exportCount += 1 }
        let data = Data("verified bundle \(snapshotID)".utf8)
        guard FileManager.default.createFile(atPath: path, contents: data) else {
            throw MachineBackupSchedulerError.persistence("fixture export failed")
        }
        try afterExport?()
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
