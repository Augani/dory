@testable import DoryCore
import XCTest

final class DoryEngineShutdownTimingTests: XCTestCase {
    func testShutdownDeadlinesCannotCutOffTheEarlierSafetyStage() {
        XCTAssertGreaterThan(
            DoryEngineShutdownTiming.helperWatchdogSeconds,
            DoryEngineShutdownTiming.reloadGraceSeconds + DoryEngineShutdownTiming.dockerdGraceSeconds
                + 3 * DoryEngineShutdownTiming.serviceGraceSeconds
                + 2 + 5 // bounded trim and filesystem sync/unmount margin
        )
        XCTAssertGreaterThanOrEqual(DoryEngineShutdownTiming.reloadGraceSeconds,
            3 + 2 + DoryEngineShutdownTiming.pollIntervalSeconds)
        XCTAssertGreaterThan(
            DoryEngineShutdownTiming.hostTerminationSeconds,
            DoryEngineShutdownTiming.helperWatchdogSeconds
        )
        XCTAssertGreaterThanOrEqual(DoryEngineShutdownTiming.dockerdPollAttempts, 1)
        XCTAssertEqual(
            Double(DoryEngineShutdownTiming.dockerdPollAttempts)
                * DoryEngineShutdownTiming.pollIntervalSeconds,
            DoryEngineShutdownTiming.dockerdGraceSeconds,
            accuracy: 0.001
        )
    }
}
