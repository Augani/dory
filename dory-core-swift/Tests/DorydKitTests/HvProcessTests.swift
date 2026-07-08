@testable import DorydKit
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
}
