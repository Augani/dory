import DoryCore
import XCTest

final class DoryCoreTests: XCTestCase {
    func testProtocolVersionComesFromRust() {
        // The Rust PROTO_VERSION is 1; this proves the staticlib is linked and callable.
        XCTAssertEqual(DoryCore.protocolVersion(), 1)
    }

    func testConnectAgentControlOverFDRejectsInvalidFD() {
        XCTAssertThrowsError(try DoryCore.connectAgentControlOverFD(-1))
    }

    func testPushControlStartsWithBoundedPreparingProgress() {
        let control = DoryPushControl()

        XCTAssertEqual(
            control.progress(),
            DoryPushProgress(
                phase: .preparing,
                filesTotal: 0,
                filesCompleted: 0,
                bytesTotal: 0,
                bytesCompleted: 0,
                currentPath: nil
            )
        )
        XCTAssertFalse(control.progress().phase.isTerminal)
        XCTAssertEqual(control.progress().fractionCompleted, 0)
    }

    func testPushProgressFractionPrefersBytesAndIsBounded() {
        XCTAssertEqual(
            DoryPushProgress(
                phase: .transferring,
                filesTotal: 4,
                filesCompleted: 3,
                bytesTotal: 100,
                bytesCompleted: 25,
                currentPath: "src/main.swift"
            ).fractionCompleted,
            0.25
        )
        XCTAssertEqual(
            DoryPushProgress(
                phase: .transferring,
                filesTotal: 4,
                filesCompleted: 5,
                bytesTotal: 0,
                bytesCompleted: 0,
                currentPath: nil
            ).fractionCompleted,
            1
        )
        XCTAssertEqual(
            DoryPushProgress(
                phase: .completed,
                filesTotal: 0,
                filesCompleted: 0,
                bytesTotal: 0,
                bytesCompleted: 0,
                currentPath: nil
            ).fractionCompleted,
            1
        )
    }

    func testPullControlStartsWithBoundedPreparingProgress() {
        let control = DoryPullControl()

        XCTAssertEqual(
            control.progress(),
            DoryPullProgress(
                phase: .preparing,
                filesTotal: 0,
                filesCompleted: 0,
                bytesTotal: 0,
                bytesCompleted: 0,
                currentPath: nil
            )
        )
        XCTAssertFalse(control.progress().phase.isTerminal)
        XCTAssertEqual(control.progress().fractionCompleted, 0)
    }

    func testPullProgressFractionPrefersBytesAndIsBounded() {
        XCTAssertEqual(
            DoryPullProgress(
                phase: .transferring,
                filesTotal: 4,
                filesCompleted: 3,
                bytesTotal: 100,
                bytesCompleted: 25,
                currentPath: "src/main.swift"
            ).fractionCompleted,
            0.25
        )
        XCTAssertEqual(
            DoryPullProgress(
                phase: .transferring,
                filesTotal: 4,
                filesCompleted: 5,
                bytesTotal: 0,
                bytesCompleted: 0,
                currentPath: nil
            ).fractionCompleted,
            1
        )
        XCTAssertEqual(
            DoryPullProgress(
                phase: .completed,
                filesTotal: 0,
                filesCompleted: 0,
                bytesTotal: 0,
                bytesCompleted: 0,
                currentPath: nil
            ).fractionCompleted,
            1
        )
    }
}
