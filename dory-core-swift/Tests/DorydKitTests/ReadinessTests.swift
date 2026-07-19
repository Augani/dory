@testable import DorydKit
import Foundation
import XCTest

final class ReadinessTests: XCTestCase {
    func testTrackerPublishesOrderedReasonCodedTimingAndRepairOwnership() throws {
        let tracker = EngineReadinessTracker()
        let start = Date(timeIntervalSince1970: 1_000)
        tracker.beginCycle(trigger: "cold-start", at: start)
        tracker.ready(
            .vmProcess,
            code: "vm.process_ready",
            detail: "pid 42",
            at: start.addingTimeInterval(1.25)
        )
        tracker.begin(.guestAgent, deadlineSeconds: 30, at: start.addingTimeInterval(1.25))
        tracker.blocked(
            .guestAgent,
            code: "guestAgent.rpc_failed",
            detail: "connection refused",
            at: start.addingTimeInterval(2)
        )

        let snapshot = tracker.snapshot(now: start.addingTimeInterval(2))
        XCTAssertEqual(snapshot.trigger, "cold-start")
        XCTAssertEqual(snapshot.overall, .blocked)
        XCTAssertEqual(snapshot.stages.map(\.id), EngineReadinessTracker.engineStageOrder)

        let vm = try XCTUnwrap(snapshot.stages.first { $0.id == .vmProcess })
        XCTAssertEqual(vm.state, .ready)
        XCTAssertEqual(vm.elapsedMilliseconds, 1_250)
        XCTAssertEqual(vm.deadlineAt, start.addingTimeInterval(120))

        let agent = try XCTUnwrap(snapshot.stages.first { $0.id == .guestAgent })
        XCTAssertEqual(agent.state, .blocked)
        XCTAssertEqual(agent.reasonCode, "guestAgent.rpc_failed")
        XCTAssertEqual(agent.repair.owner, "doryd")
        XCTAssertFalse(agent.repair.destructive)
        XCTAssertTrue(agent.repair.mutation.contains("reconnect"))
    }

    func testStoppedEngineStagesAreExplicitlyInactiveAndDoNotFabricateReadiness() {
        let tracker = EngineReadinessTracker()
        tracker.markStopped(detail: "idle sleeping")
        let snapshot = tracker.snapshot()

        XCTAssertEqual(snapshot.overall, .ready)
        XCTAssertTrue(snapshot.stages.allSatisfy { $0.state == .inactive && !$0.required })
        XCTAssertTrue(snapshot.stages.allSatisfy { $0.reasonCode == "engine.stopped" })
    }

    func testDoctorReportEmbedsVersionedReadinessContract() throws {
        let now = Date(timeIntervalSince1970: 123)
        let stage = DoryReadinessStage(
            id: .doryd,
            state: .ready,
            reasonCode: "doryd.ready",
            detail: "ready",
            startedAt: now,
            finishedAt: now,
            deadlineAt: now.addingTimeInterval(5),
            repair: EngineReadinessTracker.repair(for: .doryd)
        )
        let readiness = DoryReadinessSnapshot(
            cycleID: "cycle",
            trigger: "health-probe",
            generatedAt: now,
            stages: [stage]
        )
        let report = DoctorReport(generatedAt: now, results: [], readiness: readiness)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: report.jsonData()) as? [String: Any]
        )
        let body = try XCTUnwrap(json["readiness"] as? [String: Any])
        XCTAssertEqual(body["schema"] as? String, "dev.dory.readiness")
        XCTAssertEqual(body["version"] as? Int, 1)
        XCTAssertEqual(body["overall"] as? String, "ready")
    }
}
