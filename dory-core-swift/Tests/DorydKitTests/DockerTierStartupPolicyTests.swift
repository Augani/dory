@testable import DorydKit
import XCTest

final class DockerTierStartupPolicyTests: XCTestCase {
    func testPersistedRuntimeModeWinsOverStaleLaunchAgentHint() {
        XCTAssertTrue(DockerTierStartupPolicy.shouldAutostartDockerTier(
            environment: ["DORYD_AUTOSTART_DOCKER_TIER": "0"],
            persistedRuntimeMode: "always-on",
            persistedEngineDesiredState: "sleeping"
        ))
        XCTAssertTrue(DockerTierStartupPolicy.shouldAutostartDockerTier(
            environment: ["DORYD_AUTOSTART_DOCKER_TIER": "1"],
            persistedRuntimeMode: "manual",
            persistedEngineDesiredState: "running"
        ))
    }

    func testExplicitForceAutostartCanOverrideForDevelopment() {
        XCTAssertTrue(DockerTierStartupPolicy.shouldAutostartDockerTier(
            environment: ["DORYD_FORCE_AUTOSTART_DOCKER_TIER": "yes"],
            persistedRuntimeMode: "manual",
            persistedEngineDesiredState: "sleeping"
        ))
    }

    func testIdleCapableModesRestoreRunningIntentAfterDaemonOrHostRestart() {
        for mode in ["manual", "auto-idle", "battery-saver"] {
            XCTAssertTrue(DockerTierStartupPolicy.shouldAutostartDockerTier(
                environment: [:],
                persistedRuntimeMode: mode,
                persistedEngineDesiredState: "running"
            ))
        }
    }

    func testIdleCapableModesKeepSleepingIntentAcrossDaemonOrHostRestart() {
        for mode in ["manual", "auto-idle", "battery-saver"] {
            XCTAssertFalse(DockerTierStartupPolicy.shouldAutostartDockerTier(
                environment: [:],
                persistedRuntimeMode: mode,
                persistedEngineDesiredState: "sleeping"
            ))
        }
    }
}
