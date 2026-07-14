@testable import DoryOperations
import Darwin
import Foundation
import XCTest

final class DoryDataDriveArchiveTests: XCTestCase {
    func testBackupRestorePreservesSparseDataLinksMetadataAndDriveIdentity() throws {
        let fixture = try makeDriveFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.base) }
        let sourceManifest = try fixture.drive.readManifest()
        let payload = fixture.drive.engineDirectory + "/payload"
        try FileManager.default.createDirectory(atPath: payload, withIntermediateDirectories: true)

        let ordinary = payload + "/ordinary.txt"
        try Data("durable-data\n".utf8).write(to: URL(fileURLWithPath: ordinary))
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: ordinary)
        let xattr = Data([0x00, 0x01, 0xfe, 0xff])
        XCTAssertEqual(xattr.withUnsafeBytes {
            setxattr(ordinary, "dev.dory.test", $0.baseAddress, xattr.count, 0, 0)
        }, 0)
        var times = [
            timespec(tv_sec: 1_700_000_000, tv_nsec: 123_456_789),
            timespec(tv_sec: 1_700_000_001, tv_nsec: 987_654_321),
        ]
        XCTAssertEqual(utimensat(AT_FDCWD, ordinary, &times, 0), 0)

        let sparse = payload + "/sparse.img"
        let sparseDescriptor = open(sparse, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(sparseDescriptor, 0)
        XCTAssertEqual(ftruncate(sparseDescriptor, 32 * 1_024 * 1_024), 0)
        XCTAssertEqual(pwrite(sparseDescriptor, "head", 4, 0), 4)
        XCTAssertEqual(pwrite(sparseDescriptor, "tail", 4, 32 * 1_024 * 1_024 - 4), 4)
        XCTAssertEqual(fsync(sparseDescriptor), 0)
        close(sparseDescriptor)

        try FileManager.default.linkItem(atPath: ordinary, toPath: payload + "/ordinary-hardlink")
        try FileManager.default.createDirectory(atPath: payload + "/b", withIntermediateDirectories: true)
        try Data("cross-directory-hardlink".utf8).write(
            to: URL(fileURLWithPath: payload + "/b/z")
        )
        try FileManager.default.linkItem(atPath: payload + "/b/z", toPath: payload + "/b-")
        try FileManager.default.createSymbolicLink(
            atPath: payload + "/ordinary-link",
            withDestinationPath: "ordinary.txt"
        )

        let archive = fixture.base + "/Full.dorybackup"
        let created = try DoryDataDriveTransaction.backup(from: fixture.drive, to: archive)
        XCTAssertEqual(created.sourceDriveID, sourceManifest.id)
        XCTAssertLessThan(created.storedBytes, created.logicalBytes)
        XCTAssertEqual(try DoryDataDriveArchive.verifyBackup(at: archive), created)

        let restored = try DoryDataDrive(
            home: fixture.base,
            overrideRoot: fixture.base + "/Library/Application Support/Dory/Restored.dorydrive"
        )
        XCTAssertEqual(
            try DoryDataDriveTransaction.restore(at: archive, to: restored),
            created
        )
        XCTAssertEqual(try restored.readManifest().id, sourceManifest.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: restored.lockPath))
        let operations = try DoryOperationJournalStore(home: fixture.base).list()
        XCTAssertEqual(operations.map(\.plan.kind), [.driveBackup, .driveRestore])
        XCTAssertTrue(operations.allSatisfy {
            $0.state.phase == .completed && $0.state.status == .completed
        })
        for operation in operations {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: restored.operationsDirectory + "/"
                    + operation.plan.id.uuidString.lowercased() + ".json"
            ) || operation.plan.kind == .driveBackup)
        }

        let restoredPayload = restored.engineDirectory + "/payload"
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: restoredPayload + "/ordinary.txt")),
            Data("durable-data\n".utf8)
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: restoredPayload + "/ordinary-link"),
            "ordinary.txt"
        )
        var first = stat()
        var second = stat()
        XCTAssertEqual(lstat(restoredPayload + "/ordinary.txt", &first), 0)
        XCTAssertEqual(lstat(restoredPayload + "/ordinary-hardlink", &second), 0)
        XCTAssertEqual(first.st_ino, second.st_ino)
        XCTAssertEqual(first.st_mode & 0o7777, 0o640)
        XCTAssertEqual(first.st_mtimespec.tv_sec, 1_700_000_001)
        XCTAssertEqual(first.st_mtimespec.tv_nsec, 987_654_321)
        var restoredXattr = Data(count: xattr.count)
        let read = restoredXattr.withUnsafeMutableBytes {
            getxattr(restoredPayload + "/ordinary.txt", "dev.dory.test", $0.baseAddress, xattr.count, 0, 0)
        }
        XCTAssertEqual(read, xattr.count)
        XCTAssertEqual(restoredXattr, xattr)
        XCTAssertEqual(lstat(restoredPayload + "/b-", &first), 0)
        XCTAssertEqual(lstat(restoredPayload + "/b/z", &second), 0)
        XCTAssertEqual(first.st_ino, second.st_ino)

        var sparseStatus = stat()
        XCTAssertEqual(lstat(restoredPayload + "/sparse.img", &sparseStatus), 0)
        XCTAssertEqual(sparseStatus.st_size, 32 * 1_024 * 1_024)
        XCTAssertLessThan(UInt64(sparseStatus.st_blocks) * 512, UInt64(sparseStatus.st_size))
        let restoredSparse = open(restoredPayload + "/sparse.img", O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(restoredSparse, 0)
        var head = [UInt8](repeating: 0, count: 4)
        var tail = [UInt8](repeating: 0, count: 4)
        XCTAssertEqual(pread(restoredSparse, &head, 4, 0), 4)
        XCTAssertEqual(pread(restoredSparse, &tail, 4, sparseStatus.st_size - 4), 4)
        close(restoredSparse)
        XCTAssertEqual(head, Array("head".utf8))
        XCTAssertEqual(tail, Array("tail".utf8))
    }

    func testBackupRequiresStoppedDriveAndPublishesNoPartialOnFailure() throws {
        let fixture = try makeDriveFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.base) }
        let archive = fixture.base + "/Busy.dorybackup"
        let lock = try EngineStateDirectoryLock(
            stateDirectory: fixture.drive.root,
            lockFileName: "drive.lock"
        )

        XCTAssertThrowsError(try DoryDataDriveTransaction.backup(from: fixture.drive, to: archive)) {
            guard case let DoryDataDriveArchiveError.sourceInUse(message) = $0 else {
                return XCTFail("unexpected backup error: \($0)")
            }
            XCTAssertTrue(message.contains("stop Dory before backup"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.base).contains {
            $0.contains("Busy.dorybackup") && $0.hasSuffix(".partial")
        })
        withExtendedLifetime(lock) {}
    }

    func testIncompleteAndCorruptArchivesNeverVerifyOrRestore() throws {
        let fixture = try makeDriveFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.base) }
        try Data("payload".utf8).write(
            to: URL(fileURLWithPath: fixture.drive.engineDirectory + "/data.bin")
        )
        let archive = fixture.base + "/Corrupt.dorybackup"
        _ = try DoryDataDriveTransaction.backup(from: fixture.drive, to: archive)
        let completion = archive + "/complete.json"
        let completionData = try Data(contentsOf: URL(fileURLWithPath: completion))
        try FileManager.default.removeItem(atPath: completion)

        XCTAssertThrowsError(try DoryDataDriveArchive.verifyBackup(at: archive))
        let target = try restoredDrive(home: fixture.base, name: "ShouldNotExist")
        XCTAssertThrowsError(try DoryDataDriveTransaction.restore(at: archive, to: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.root))

        try completionData.write(to: URL(fileURLWithPath: completion))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: completion)
        let chunks = try FileManager.default.contentsOfDirectory(atPath: archive + "/chunks")
        XCTAssertFalse(chunks.isEmpty)
        let chunk = archive + "/chunks/" + chunks[0]
        let descriptor = open(chunk, O_WRONLY | O_TRUNC | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(write(descriptor, "bad", 3), 3)
        XCTAssertEqual(fsync(descriptor), 0)
        close(descriptor)
        XCTAssertThrowsError(try DoryDataDriveArchive.verifyBackup(at: archive))
    }

    func testUnsupportedEntryRollsBackTheWholeArchive() throws {
        let fixture = try makeDriveFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.base) }
        let fifo = fixture.drive.engineDirectory + "/runtime.fifo"
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        let archive = fixture.base + "/Unsupported.dorybackup"

        XCTAssertThrowsError(try DoryDataDriveTransaction.backup(from: fixture.drive, to: archive)) {
            guard case DoryDataDriveArchiveError.unsupportedEntry = $0 else {
                return XCTFail("unexpected backup error: \($0)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.base).contains {
            $0.contains("Unsupported.dorybackup") && $0.hasSuffix(".partial")
        })
    }

    func testRestoreNeverOverwritesExistingDataDrive() throws {
        let fixture = try makeDriveFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.base) }
        let archive = fixture.base + "/Safe.dorybackup"
        _ = try DoryDataDriveTransaction.backup(from: fixture.drive, to: archive)
        let target = try restoredDrive(home: fixture.base, name: "Existing")
        try target.prepare()
        let existingID = try target.readManifest().id

        XCTAssertThrowsError(try DoryDataDriveTransaction.restore(at: archive, to: target))
        XCTAssertEqual(try target.readManifest().id, existingID)
        XCTAssertNoThrow(try DoryDataDriveArchive.verifyBackup(at: archive))
    }

    func testIdenticalFilesUseOneContentAddressedChunk() throws {
        let fixture = try makeDriveFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.base) }
        let data = Data(repeating: 0x5a, count: 1_024 * 1_024)
        try data.write(to: URL(fileURLWithPath: fixture.drive.engineDirectory + "/first.bin"))
        try data.write(to: URL(fileURLWithPath: fixture.drive.engineDirectory + "/second.bin"))
        let archive = fixture.base + "/Deduplicated.dorybackup"

        let verification = try DoryDataDriveTransaction.backup(from: fixture.drive, to: archive)
        let chunks = try FileManager.default.contentsOfDirectory(atPath: archive + "/chunks")
        XCTAssertEqual(chunks.count, verification.chunkCount)
        XCTAssertLessThan(verification.storedBytes, verification.logicalBytes)
    }

    func testPublishedBackupResumesFromItsDurableJournal() throws {
        let fixture = try makeDriveFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.base) }
        let archive = fixture.base + "/Resume.dorybackup"
        let manifest = try fixture.drive.readManifest()
        let plan = try DoryDataDriveTransaction.backupPlan(
            drive: fixture.drive,
            manifest: manifest,
            destination: archive
        )
        let operationID: UUID
        do {
            let lease = try DoryOperationJournalStore(home: fixture.base).begin(plan)
            operationID = lease.operationID
            _ = try DoryDataDriveArchive.createBackupPayload(
                from: fixture.drive,
                to: archive,
                operationID: operationID
            )
            try advanceLeaseToPublishing(lease)
        }

        let verification = try DoryDataDriveTransaction.backup(
            from: fixture.drive,
            to: archive
        )
        XCTAssertEqual(verification.backupOperationID, operationID)
        let record = try DoryOperationJournalStore(home: fixture.base).read(operationID)
        XCTAssertEqual(record.state.phase, .completed)
        XCTAssertEqual(record.state.status, .completed)
    }

    func testPublishedRestoreMarkerResumesBeforeTheDriveIsExposed() throws {
        let fixture = try makeDriveFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.base) }
        let archive = fixture.base + "/RestoreResume.dorybackup"
        let backup = try DoryDataDriveTransaction.backup(from: fixture.drive, to: archive)
        let target = try restoredDrive(home: fixture.base, name: "Resumed")
        let plan = try DoryDataDriveTransaction.restorePlan(
            archive: archive,
            verification: backup,
            drive: target
        )
        let operationID: UUID
        do {
            let lease = try DoryOperationJournalStore(home: fixture.base).begin(plan)
            operationID = lease.operationID
            _ = try DoryDataDriveArchive.restoreBackupPayload(
                at: archive,
                to: target,
                operationID: operationID
            )
            try advanceLeaseToPublishing(lease)
        }

        let restored = try DoryDataDriveTransaction.restore(at: archive, to: target)
        XCTAssertEqual(restored.backupOperationID, backup.backupOperationID)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: target.root + "/.dory-restore-owner.json"
        ))
        let record = try DoryOperationJournalStore(home: fixture.base).read(operationID)
        XCTAssertEqual(record.state.phase, .completed)
        XCTAssertEqual(record.state.status, .completed)
    }

    private func makeDriveFixture() throws -> (base: String, drive: DoryDataDrive) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-drive-archive-\(UUID().uuidString)", isDirectory: true)
            .path
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        let drive = try DoryDataDrive(home: base)
        try drive.prepare()
        return (base, drive)
    }

    private func restoredDrive(home: String, name: String) throws -> DoryDataDrive {
        try DoryDataDrive(
            home: home,
            overrideRoot: home + "/Library/Application Support/Dory/\(name).dorydrive"
        )
    }

    private func advanceLeaseToPublishing(_ lease: DoryOperationLease) throws {
        for phase in [
            DoryOperationPhase.quiescing,
            .staging,
            .verifying,
            .readyToPublish,
            .publishing
        ] {
            let record = try lease.read()
            _ = try lease.transition(
                to: phase,
                status: .running,
                expectedRevision: record.state.revision,
                stepID: "test.\(phase.rawValue)"
            )
        }
    }
}
