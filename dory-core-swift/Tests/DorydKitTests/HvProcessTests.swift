@testable import DorydKit
import Darwin
import XCTest

final class HvProcessTests: XCTestCase {
    func testStartsAndStopsChildProcess() throws {
        let process = HvProcess(configuration: HvProcessConfiguration(
            executablePath: "/bin/sleep",
            arguments: ["10"]
        ))

        try process.start()
        XCTAssertTrue(process.isRunning)
        XCTAssertNotNil(process.pid)

        process.stop()
        XCTAssertFalse(process.isRunning)
        XCTAssertNil(process.pid)
    }

    func testSuspendsAndResumesChildProcess() throws {
        let process = HvProcess(configuration: HvProcessConfiguration(
            executablePath: "/bin/sleep",
            arguments: ["10"]
        ))

        try process.start()
        defer { process.stop() }
        let pid = try XCTUnwrap(process.pid)

        XCTAssertTrue(process.suspend())
        XCTAssertTrue(process.isRunning)
        XCTAssertTrue(process.isSuspended)
        XCTAssertEqual(process.pid, pid)

        XCTAssertTrue(process.resume())
        XCTAssertTrue(process.isRunning)
        XCTAssertFalse(process.isSuspended)
        XCTAssertEqual(process.pid, pid)
    }

    func testRestartsUnexpectedExitUpToLimit() throws {
        let directory = "/tmp/dory-hv-process-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let marker = directory + "/runs"
        let script = directory + "/exit-fast.sh"
        try """
        #!/bin/sh
        echo run >> "$1"
        exit 7
        """.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)

        let process = HvProcess(configuration: HvProcessConfiguration(
            executablePath: script,
            arguments: [marker],
            restartPolicy: HvRestartPolicy(maxRestarts: 1, delaySeconds: 0.01)
        ))
        try process.start()

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let runs = (try? String(contentsOfFile: marker, encoding: .utf8))?
                .split(separator: "\n")
                .count ?? 0
            if runs >= 2 { break }
            Thread.sleep(forTimeInterval: 0.02)
        }

        let runs = try String(contentsOfFile: marker, encoding: .utf8)
            .split(separator: "\n")
            .count
        XCTAssertEqual(runs, 2)
        process.stop()
    }

    func testUnexpectedExitNotifiesSupervisor() throws {
        let callback = expectation(description: "unexpected termination callback")
        let captured = LockedTermination()
        let process = HvProcess(
            configuration: HvProcessConfiguration(
                executablePath: "/bin/sleep",
                arguments: ["10"]
            ),
            unexpectedTerminationHandler: { termination in
                captured.set(termination)
                callback.fulfill()
            }
        )
        try process.start()
        let pid = try XCTUnwrap(process.pid)

        XCTAssertEqual(kill(pid, SIGKILL), 0)
        wait(for: [callback], timeout: 1)

        XCTAssertEqual(captured.value?.status, SIGKILL)
        XCTAssertEqual(captured.value?.wasUncaughtSignal, true)
        XCTAssertFalse(process.isRunning)
    }

    func testExplicitStopDoesNotNotifyUnexpectedTerminationHandler() throws {
        let callback = expectation(description: "no unexpected callback")
        callback.isInverted = true
        let process = HvProcess(
            configuration: HvProcessConfiguration(
                executablePath: "/bin/sleep",
                arguments: ["10"]
            ),
            unexpectedTerminationHandler: { _ in callback.fulfill() }
        )
        try process.start()

        process.stop()
        wait(for: [callback], timeout: 0.15)

        XCTAssertFalse(process.isRunning)
        XCTAssertNil(process.pid)
    }

    func testConcurrentStopsShareProcessTerminationCompletion() throws {
        let process = HvProcess(configuration: HvProcessConfiguration(
            executablePath: "/bin/sh",
            arguments: ["-c", "trap 'sleep 0.5; exit 0' TERM; while true; do sleep 0.05; done"]
        ))
        try process.start()
        Thread.sleep(forTimeInterval: 0.1)

        let callersReady = DispatchGroup()
        let callersFinished = DispatchGroup()
        let startGate = DispatchSemaphore(value: 0)
        for _ in 0..<2 {
            callersReady.enter()
            callersFinished.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                callersReady.leave()
                startGate.wait()
                process.stop(timeout: 1.5)
                callersFinished.leave()
            }
        }
        XCTAssertEqual(callersReady.wait(timeout: .now() + 1), .success)

        let startedAt = Date()
        startGate.signal()
        startGate.signal()
        XCTAssertEqual(callersFinished.wait(timeout: .now() + 1), .success)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
        XCTAssertFalse(process.isRunning)
        XCTAssertNil(process.pid)
    }

    func testStopBeforeFirstStartPreventsLateSpawn() throws {
        let process = HvProcess(configuration: HvProcessConfiguration(
            executablePath: "/bin/sleep",
            arguments: ["30"]
        ))

        process.stop()

        XCTAssertThrowsError(try process.start()) { error in
            XCTAssertTrue("\(error)".contains("start was cancelled"), "\(error)")
        }
        XCTAssertFalse(process.isRunning)
        XCTAssertNil(process.pid)
    }
}

private final class LockedTermination: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: HvProcessTermination?

    var value: HvProcessTermination? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ termination: HvProcessTermination) {
        lock.lock()
        stored = termination
        lock.unlock()
    }
}
