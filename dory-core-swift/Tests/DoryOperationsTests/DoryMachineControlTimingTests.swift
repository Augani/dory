import DoryCore
import XCTest
@testable import DoryOperations

final class DoryMachineControlTimingTests: XCTestCase {
    func testStopBudgetCoversTheSerialLifecycleWorstCaseWithMargin() {
        let guestHandshakeAndReply: TimeInterval = 10 + 30
        let helperAcknowledgement: TimeInterval = 5
        let daemonTermination = DoryEngineShutdownTiming.hostTerminationSeconds

        XCTAssertGreaterThan(
            DoryMachineControlTiming.stopSeconds,
            guestHandshakeAndReply + helperAcknowledgement + daemonTermination
        )
    }

    func testStartRestartAndFileMutationBudgetsCoverDaemonWork() {
        XCTAssertGreaterThan(DoryMachineControlTiming.startSeconds, 180)
        XCTAssertEqual(
            DoryMachineControlTiming.restartSeconds,
            DoryMachineControlTiming.stopSeconds + DoryMachineControlTiming.startSeconds
        )
        XCTAssertGreaterThanOrEqual(DoryMachineControlTiming.fileMutationSeconds, 15 * 60)
    }
}
