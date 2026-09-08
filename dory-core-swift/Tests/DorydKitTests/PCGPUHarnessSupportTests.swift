import Foundation
import XCTest

final class PCGPUHarnessSupportTests: XCTestCase {
    func testCampaignCapsConnectionAndWorkloadBudgets() throws {
        for invalid in [0.0, -1, Double.nan, Double.infinity, 86_401] {
            XCTAssertThrowsError(try PCGPUHarnessDeadline(seconds: invalid))
        }
        let longCampaign = try PCGPUHarnessDeadline(seconds: 7200)
        let attempt = longCampaign.capped(seconds: 120 + 300 + 30)
        XCTAssertGreaterThan(attempt.remainingSeconds, 449)
        XCTAssertLessThanOrEqual(attempt.remainingSeconds, 450)
        let shortCampaign = try PCGPUHarnessDeadline(seconds: 0.01)
        XCTAssertEqual(shortCampaign.capped(seconds: 450).end, shortCampaign.end)
        Thread.sleep(forTimeInterval: 0.02)
        let receipt = PCGPUHarnessProcess.run(executable: "/does/not/exist", arguments: [], deadline: shortCampaign)
        XCTAssertEqual(receipt["terminatedByTimeout"] as? Bool, true)
        XCTAssertNil(receipt["launchError"], "expired campaigns must not spawn a child")
    }

    func testEveryFailedQualificationBoundaryRejects() throws {
        for failingIndex in 0..<4 {
            var gates = [true, true, true, true]
            gates[failingIndex] = false
            XCTAssertThrowsError(try PCGPUHarnessResult.requireSuccess(
                running: gates[0], hardwareGraphics: gates[1], agentReady: gates[2], renderPassed: gates[3]))
        }
        XCTAssertNoThrow(try PCGPUHarnessResult.requireSuccess(
            running: true, hardwareGraphics: true, agentReady: true, renderPassed: true))
        XCTAssertFalse(PCGPUHarnessResult.probePassed([:]))
        XCTAssertFalse(PCGPUHarnessResult.probePassed(["returncode": Int32(0), "terminatedByTimeout": true]))
        XCTAssertFalse(PCGPUHarnessResult.probePassed(["returncode": Int32(1), "terminatedByTimeout": false]))
        XCTAssertTrue(PCGPUHarnessResult.probePassed(["returncode": Int32(0), "terminatedByTimeout": false]))
    }

    func testCleanupWaitsForSuccessfulStopAndPreservesExternalReceipt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)
        let disk = state.appendingPathComponent("disk.img")
        try Data("fixture".utf8).write(to: disk)
        let receipt = root.appendingPathComponent("receipt.json")
        try Data("{}".utf8).write(to: receipt)
        XCTAssertThrowsError(try PCGPUHarnessResult.cleanup(directory: state) {
            throw PCGPUHarnessFailure.guestNotRunning
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: disk.path))
        try PCGPUHarnessResult.cleanup(directory: state) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: disk.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))
        XCTAssertEqual(try Data(contentsOf: receipt), Data("{}".utf8))
    }

    func testProbeCapturesOutputAndRejectsNonzeroExit() throws {
        let result = PCGPUHarnessProcess.run(executable: "/bin/sh", arguments: ["-c", "printf probe-output; exit 7"],
            deadline: try PCGPUHarnessDeadline(seconds: 5))
        XCTAssertEqual(result["stdout"] as? String, "probe-output")
        XCTAssertEqual(result["returncode"] as? Int32, 7)
        XCTAssertFalse(PCGPUHarnessResult.probePassed(result))
    }

    func testProbeEscalatesWhenChildIgnoresTermination() throws {
        let result = PCGPUHarnessProcess.run(executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; while :; do :; done"],
            deadline: try PCGPUHarnessDeadline(seconds: 0.2))
        XCTAssertEqual(result["terminatedByTimeout"] as? Bool, true)
        XCTAssertNotNil(result["returncode"])
        XCTAssertLessThan(result["elapsedSeconds"] as? Double ?? .infinity, 5)
        XCTAssertFalse(PCGPUHarnessResult.probePassed(result))
    }
}
