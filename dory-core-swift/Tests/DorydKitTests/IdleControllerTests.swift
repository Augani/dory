@testable import DorydKit
import XCTest

final class IdleControllerTests: XCTestCase {
    func testPingDoesNotCountAsActivityOrWake() {
        let idle = IdleController(now: Date(timeIntervalSince1970: 100))
        idle.setSleeping(true)

        XCTAssertFalse(idle.beginRequest(path: "/_ping", now: Date(timeIntervalSince1970: 200)))
        XCTAssertEqual(idle.snapshot.activeRequests, 0)
        XCTAssertEqual(idle.snapshot.lastActivity, Date(timeIntervalSince1970: 100))
    }

    func testClaimSleepOnlyWhenNoRequestsOrControlOpsAreActive() {
        let idle = IdleController(now: Date(timeIntervalSince1970: 0))
        idle.beginRequest(path: "/version", now: Date(timeIntervalSince1970: 1))
        XCTAssertFalse(idle.claimSleepIfIdle(idleAfter: 5, now: Date(timeIntervalSince1970: 20)))

        idle.endRequest(now: Date(timeIntervalSince1970: 2))
        idle.beginControlOperation(now: Date(timeIntervalSince1970: 3))
        XCTAssertFalse(idle.claimSleepIfIdle(idleAfter: 5, now: Date(timeIntervalSince1970: 20)))

        idle.endControlOperation(now: Date(timeIntervalSince1970: 4))
        XCTAssertTrue(idle.claimSleepIfIdle(idleAfter: 5, now: Date(timeIntervalSince1970: 20)))
        XCTAssertTrue(idle.snapshot.sleeping)
    }

    func testMeaningfulRequestWhileSleepingAsksForWake() {
        let idle = IdleController()
        idle.setSleeping(true)

        XCTAssertTrue(idle.beginRequest(path: "/version"))
        XCTAssertEqual(idle.snapshot.activeRequests, 1)

        idle.endRequest()
        XCTAssertEqual(idle.snapshot.activeRequests, 0)
    }
}
