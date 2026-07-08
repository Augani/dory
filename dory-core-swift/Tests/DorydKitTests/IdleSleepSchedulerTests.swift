@testable import DorydKit
import Foundation
import XCTest

final class IdleSleepSchedulerTests: XCTestCase {
    func testSchedulerDoesNotSleepWhenPolicyReportsBlockers() throws {
        let base = "/tmp/dory-idle-scheduler-blocked-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let idle = IdleController(now: Date(timeIntervalSince1970: 0))
        let tier = makeTier(base: base, idle: idle, activity: .empty)
        try tier.start()
        defer { tier.stop() }

        let store = IdlePolicyStore(home: base + "/policy", environment: [:]) {
            .ok([Self.runningContainer()])
        }
        let scheduler = IdleSleepScheduler(
            dockerTier: tier,
            configuration: IdleSleepConfiguration(enabled: true, idleAfterSeconds: 5),
            canAttemptSleep: {
                store.canSleepNow()
            }
        )

        scheduler.evaluateOnce(now: Date().addingTimeInterval(60))

        XCTAssertEqual(tier.status().state, .running)
        XCTAssertNotNil(tier.status().hvPID)
    }

    func testSchedulerStopsEmptyEngineWhenPolicyAllowsSleep() throws {
        let base = "/tmp/dory-idle-scheduler-empty-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let idle = IdleController(now: Date(timeIntervalSince1970: 0))
        let tier = makeTier(base: base, idle: idle, activity: .empty)
        try tier.start()
        defer { tier.stop() }

        let store = IdlePolicyStore(home: base + "/policy", environment: [:]) {
            .ok([])
        }
        let scheduler = IdleSleepScheduler(
            dockerTier: tier,
            configuration: IdleSleepConfiguration(enabled: true, idleAfterSeconds: 5),
            canAttemptSleep: {
                store.canSleepNow()
            }
        )

        scheduler.evaluateOnce(now: Date().addingTimeInterval(60))

        XCTAssertEqual(tier.status().state, .sleeping)
        XCTAssertNil(tier.status().hvPID)
    }

    private func makeTier(
        base: String,
        idle: IdleController,
        activity: DockerContainerActivity
    ) -> DockerTier {
        DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: base + "/forward.sock",
                activitySocketPath: base + "/activity.sock",
                hvProcess: HvProcessConfiguration(
                    executablePath: "/bin/sleep",
                    arguments: ["30"]
                )
            ),
            idleController: idle,
            containerActivityProbe: { _ in activity },
            dockerReadyWaiter: { _, _ in true }
        )
    }

    private static func runningContainer() -> DockerContainerSummary {
        try! JSONDecoder().decode(
            DockerContainerSummary.self,
            from: Data(
                """
                {"Id":"abc123456789","Names":["/web"],"State":"running","Ports":[],"Labels":{}}
                """.utf8
            )
        )
    }
}
