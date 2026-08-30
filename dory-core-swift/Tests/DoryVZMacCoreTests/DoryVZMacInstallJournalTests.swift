import Foundation
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

    func testWritesAtomicProgressReadableByFailurePath() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dory-vzmac-install-journal-\(UUID().uuidString).json"
        )
        defer { try? FileManager.default.removeItem(at: url) }
        try journal(phase: .installing, progress: 0.42).write(to: url)
        XCTAssertEqual(lastObservedInstallProgress(from: url), 0.42)
        XCTAssertEqual(try DoryVZMacInstallJournal.load(from: url).progress, 0.42)
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
