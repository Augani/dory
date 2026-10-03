import Foundation
import Darwin
import XCTest
@testable import DoryVZMacCore

final class DoryVZMacInstallJournalTests: XCTestCase {
    func testValidatesActiveCompletedAndFailedPhases() throws {
        let active = journal(phase: .installing, progress: 0.4)
        try active.validate()
        try active.updating(phase: .completed, progress: 1).validate()
        try active.updating(phase: .failed, progress: 0.4, error: "installer failed").validate()
    }

    func testRejectsInconsistentTerminalPhasesAndMalformedProgress() throws {
        XCTAssertThrowsError(try journal(phase: .completed, progress: 0.9).validate())
        XCTAssertThrowsError(try journal(phase: .failed, progress: 0.4).validate())
        XCTAssertThrowsError(try journal(phase: .installing, progress: 1.1).validate())
    }

    func testRejectsZeroOperationIdentityAndReportsBothFailureCauses() throws {
        let original = journal(phase: .installing, progress: 0.4)
        let invalid = DoryVZMacInstallJournal(
            operationID: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
            startedAt: original.startedAt, updatedAt: original.updatedAt,
            phase: original.phase, progress: original.progress,
            restoreImageSHA256: original.restoreImageSHA256,
            machineIdentifierSHA256: original.machineIdentifierSHA256, error: nil)
        XCTAssertThrowsError(try invalid.validate())
        let error = DoryVZMacInstallJournalError.failureRecording(installation: "installer cancelled", metadata: "disk full")
        XCTAssertTrue(error.description.contains("installer cancelled"))
        XCTAssertTrue(error.description.contains("disk full"))
        XCTAssertTrue(error.description.contains("requires recovery"))
    }

    func testWritesAtomicProgressReadableByFailurePath() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dory-vzmac-install-journal-\(UUID().uuidString).json"
        )
        defer { try? FileManager.default.removeItem(at: url) }
        try journal(phase: .installing, progress: 0.42).write(to: url)
        XCTAssertEqual(lastObservedInstallProgress(from: url), 0.42)
        XCTAssertEqual(try DoryVZMacInstallJournal.load(from: url).progress, 0.42)
        var status = stat()
        XCTAssertEqual(lstat(url.path, &status), 0)
        XCTAssertEqual(status.st_mode & 0o777, 0o600)
    }

    func testInstallJournalRejectsLinkedMetadataWithoutChangingItsTarget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dory-vzmac-linked-install-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = journal(phase: .installing, progress: 0.42)
        let target = root.appendingPathComponent("target.json")
        try original.write(to: target)
        let alias = root.appendingPathComponent("install-operation.json")
        XCTAssertEqual(symlink(target.path, alias.path), 0)
        XCTAssertThrowsError(try DoryVZMacInstallJournal.load(from: alias))
        XCTAssertThrowsError(try original.updating(phase: .completed, progress: 1).write(to: alias))
        XCTAssertEqual(try DoryVZMacInstallJournal.load(from: target), original)
        XCTAssertEqual(unlink(alias.path), 0)
        XCTAssertEqual(link(target.path, alias.path), 0)
        XCTAssertThrowsError(try DoryVZMacInstallJournal.load(from: alias))
        XCTAssertThrowsError(try original.updating(phase: .completed, progress: 1).write(to: alias))
    }

    private func journal(
        phase: DoryVZMacInstallPhase,
        progress: Double,
        error: String? = nil
    ) -> DoryVZMacInstallJournal {
        DoryVZMacInstallJournal(
            operationID: UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!,
            startedAt: "2026-08-30T14:00:00Z",
            updatedAt: "2026-08-30T14:01:00Z",
            phase: phase,
            progress: progress,
            restoreImageSHA256: String(repeating: "a", count: 64),
            machineIdentifierSHA256: String(repeating: "b", count: 64),
            error: error
        )
    }
}
