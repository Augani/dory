@testable import DorydKit
import XCTest

final class IdlePolicyStoreTests: XCTestCase {
    func testCorruptConfigIsPreservedAndNotSilentlyClobbered() throws {
        let directory = NSTemporaryDirectory() + "dory-idle-\(getpid())-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let configPath = directory + "/config.json"
        let garbage = "{ this is not valid json "
        try garbage.write(toFile: configPath, atomically: true, encoding: .utf8)

        let store = IdlePolicyStore(environment: ["DORY_CONFIG": configPath])
        _ = store.currentPolicy()

        let backupPath = configPath + ".corrupt"
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupPath))
        XCTAssertEqual(try String(contentsOfFile: backupPath, encoding: .utf8), garbage)
        XCTAssertEqual(try String(contentsOfFile: configPath, encoding: .utf8), garbage)
    }

    func testAbsentConfigReturnsDefaultsWithoutBackup() {
        let directory = NSTemporaryDirectory() + "dory-idle-\(getpid())-\(UUID().uuidString)"
        let configPath = directory + "/config.json"
        let store = IdlePolicyStore(environment: ["DORY_CONFIG": configPath])

        let policy = store.currentPolicy()

        XCTAssertEqual(policy.sleepAfterMinutes, 15)
        XCTAssertEqual(store.currentRuntimeMode(), "always-on")
        XCTAssertEqual(store.currentEngineDesiredState(), "running")
        XCTAssertFalse(store.schedulerConfiguration(base: IdleSleepConfiguration()).enabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configPath + ".corrupt"))
    }

    func testEngineDesiredStatePersistsWithoutChangingRuntimeMode() throws {
        let directory = NSTemporaryDirectory() + "dory-engine-intent-\(getpid())-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let configPath = directory + "/config.json"
        let environment = ["DORY_CONFIG": configPath]
        let store = IdlePolicyStore(environment: environment)

        _ = try store.setRuntimeMode("auto-idle")
        try store.setEngineDesiredState("sleeping")

        let reloaded = IdlePolicyStore(environment: environment)
        XCTAssertEqual(reloaded.currentRuntimeMode(), "auto-idle")
        XCTAssertEqual(reloaded.currentEngineDesiredState(), "sleeping")

        try reloaded.setEngineDesiredState("running")
        XCTAssertEqual(store.currentEngineDesiredState(), "running")
        XCTAssertThrowsError(try store.setEngineDesiredState("stopped"))
    }

    func testManagedEngineSleepFollowsRuntimeMode() throws {
        let directory = NSTemporaryDirectory() + "dory-idle-\(getpid())-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let configPath = directory + "/config.json"
        let store = IdlePolicyStore(environment: ["DORY_CONFIG": configPath])

        XCTAssertFalse(store.managedEngineSleepEnabled())

        try store.setRuntimeMode("auto-idle")
        XCTAssertTrue(store.managedEngineSleepEnabled())

        try store.setRuntimeMode("battery-saver")
        XCTAssertTrue(store.managedEngineSleepEnabled())

        try store.setRuntimeMode("manual")
        XCTAssertFalse(store.managedEngineSleepEnabled())
    }

    func testBatterySaverCapsEffectiveDelayWithoutChangingConfiguredPolicy() throws {
        let directory = NSTemporaryDirectory() + "dory-idle-battery-\(getpid())-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let configPath = directory + "/config.json"
        let store = IdlePolicyStore(environment: ["DORY_CONFIG": configPath])
        try store.setPolicy(key: "sleepAfterMinutes", value: "30")

        try store.setRuntimeMode("auto-idle")
        XCTAssertEqual(
            store.schedulerConfiguration(base: IdleSleepConfiguration()).idleAfterSeconds,
            30 * 60
        )

        let status = try store.setRuntimeMode("battery-saver")
        XCTAssertEqual(status["sleep_after_minutes"] as? Int, 30)
        XCTAssertEqual(status["effective_sleep_after_minutes"] as? Int, 5)
        XCTAssertEqual(
            store.schedulerConfiguration(base: IdleSleepConfiguration()).idleAfterSeconds,
            5 * 60
        )
        XCTAssertEqual(store.currentPolicy().sleepAfterMinutes, 30)
    }
}
