import DoryCore
@testable import DorydKit
import Foundation
import XCTest

final class DoryLinuxVMCalibrationExecTests: XCTestCase {
    func testParserRequiresExplicitBoundaryAndPreservesGuestArguments() throws {
        let parsed = try DoryLinuxVMCalibrationExec.parse(arguments: [
            "--agent-socket", "/tmp/dory-calibration/a.sock",
            "--timeout-ms", "45000",
            "--output-limit-bytes", "4096",
            "--", "/bin/sh", "-lc", "printf ok", "--guest-option",
        ])

        XCTAssertEqual(parsed, DoryLinuxVMCalibrationExecConfiguration(
            agentSocketPath: "/tmp/dory-calibration/a.sock",
            timeoutMs: 45_000,
            outputLimitBytes: 4_096,
            argv: ["/bin/sh", "-lc", "printf ok", "--guest-option"]
        ))
    }

    func testParserAppliesBoundedDefaults() throws {
        let parsed = try DoryLinuxVMCalibrationExec.parse(arguments: [
            "--agent-socket", "/tmp/dory-calibration/a.sock",
            "--", "/usr/bin/true",
        ])

        XCTAssertEqual(
            parsed.timeoutMs,
            DoryLinuxVMCalibrationExecConfiguration.defaultTimeoutMs
        )
        XCTAssertEqual(
            parsed.outputLimitBytes,
            DoryLinuxVMCalibrationExecConfiguration.defaultOutputLimitBytes
        )
    }

    func testParserRejectsUnsafeOrUnboundedInputs() {
        let invalidArguments: [[String]] = [
            ["--agent-socket", "/tmp/a.sock", "/bin/true"],
            ["--agent-socket", "relative.sock", "--", "/bin/true"],
            ["--agent-socket", "/tmp/a.sock", "--timeout-ms", "0", "--", "/bin/true"],
            [
                "--agent-socket", "/tmp/a.sock",
                "--timeout-ms", "600001",
                "--", "/bin/true",
            ],
            [
                "--agent-socket", "/tmp/a.sock",
                "--output-limit-bytes", "16777217",
                "--", "/bin/true",
            ],
            [
                "--agent-socket", "/tmp/a.sock",
                "--agent-socket", "/tmp/b.sock",
                "--", "/bin/true",
            ],
            ["--agent-socket", "/tmp/a.sock", "--"],
        ]

        for arguments in invalidArguments {
            XCTAssertThrowsError(
                try DoryLinuxVMCalibrationExec.parse(arguments: arguments),
                "accepted invalid arguments: \(arguments)"
            )
        }
    }

    func testCanonicalJSONUsesTheExactExecResultFields() throws {
        let result = DoryExecResult(
            exitCode: 7,
            stdout: Data("ok\n".utf8),
            stderr: Data("bad".utf8),
            timedOut: false,
            stdoutTruncated: false,
            stderrTruncated: true
        )

        XCTAssertEqual(
            String(decoding: try DoryLinuxVMCalibrationExec.canonicalJSON(for: result), as: UTF8.self),
            #"{"exitCode":7,"stderr":"bad","stderrTruncated":true,"stdout":"ok\n","stdoutTruncated":false,"timedOut":false}"#
        )
        XCTAssertEqual(DoryLinuxVMCalibrationExec.processExitStatus(for: result), 7)
    }

    func testTimeoutAndNonPortableGuestStatusesMapSafely() {
        func result(exitCode: Int32, timedOut: Bool) -> DoryExecResult {
            DoryExecResult(
                exitCode: exitCode,
                stdout: Data(),
                stderr: Data(),
                timedOut: timedOut,
                stdoutTruncated: false,
                stderrTruncated: false
            )
        }

        XCTAssertEqual(
            DoryLinuxVMCalibrationExec.processExitStatus(
                for: result(exitCode: -1, timedOut: true)
            ),
            124
        )
        XCTAssertEqual(
            DoryLinuxVMCalibrationExec.processExitStatus(
                for: result(exitCode: -1, timedOut: false)
            ),
            1
        )
    }
}
