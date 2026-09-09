import DoryCore
import Foundation
import XCTest

@testable import DorydKit

final class DoryLinuxVMCalibrationProfileTests: XCTestCase {
  func testParserPreservesExplicitEndpointsAndBoundedDefaults() throws {
    let parsed = try DoryLinuxVMCalibrationProfile.parse(arguments: [
      "--agent-socket", "/tmp/dory-profile/agent.sock",
      "--machine-id", "pc-calibration",
      "--machine-directory", "/tmp/dory-profile/machine",
      "--console-socket", "/tmp/dory-profile/console.sock",
      "--", "/bin/true",
    ])

    XCTAssertEqual(parsed.samples, 5)
    XCTAssertEqual(parsed.serialTimeoutMs, 30_000)
    XCTAssertEqual(parsed.execTimeoutMs, 30_000)
    XCTAssertEqual(parsed.argv, ["/bin/true"])
  }

  func testParserRejectsMissingUnsafeDuplicateAndUnboundedInputs() {
    let base = [
      "--agent-socket", "/tmp/dory-profile/agent.sock",
      "--machine-id", "pc-calibration",
      "--machine-directory", "/tmp/dory-profile/machine",
      "--console-socket", "/tmp/dory-profile/console.sock",
    ]
    let invalid: [[String]] = [
      base + ["/bin/true"],
      Array(base.dropLast(2)) + ["--", "/bin/true"],
      base + ["--samples", "0", "--", "/bin/true"],
      base + ["--samples", "26", "--", "/bin/true"],
      base + ["--serial-timeout-ms", "120001", "--", "/bin/true"],
      base + ["--agent-socket", "/tmp/other.sock", "--", "/bin/true"],
      [
        "--agent-socket", "relative.sock",
        "--machine-id", "pc-calibration",
        "--machine-directory", "/tmp/dory-profile/machine",
        "--console-socket", "/tmp/dory-profile/console.sock",
        "--", "/bin/true",
      ],
    ]
    for arguments in invalid {
      XCTAssertThrowsError(
        try DoryLinuxVMCalibrationProfile.parse(arguments: arguments),
        "accepted invalid arguments: \(arguments)"
      )
    }
  }

  func testNearestRankSummarySeparatesGuestAndResidualComponents() {
    let samples = [
      sample(index: 1, serial: 10, connect: 20, info: 30, command: 100, wait: 40),
      sample(index: 2, serial: 11, connect: 21, info: 31, command: 200, wait: 80),
      sample(index: 3, serial: 12, connect: 22, info: 32, command: 300, wait: 120),
      sample(index: 4, serial: 13, connect: 23, info: 33, command: 400, wait: 160),
      sample(index: 5, serial: 14, connect: 24, info: 34, command: 500, wait: 200),
    ]
    let summary = DoryLinuxVMCalibrationProfile.summarize(samples)

    XCTAssertEqual(summary.commandRPC.p50Nanoseconds, 300)
    XCTAssertEqual(summary.commandRPC.p95Nanoseconds, 500)
    XCTAssertEqual(summary.processWait?.p50Nanoseconds, 120)
    XCTAssertEqual(summary.transportAndHostResidual?.p50Nanoseconds, 150)
    XCTAssertEqual(summary.guestTimingSamples, 5)
    XCTAssertTrue(summary.guestTimingComplete)
    XCTAssertEqual(summary.dominantCommandComponent, "transportAndHostResidual")
  }

  func testCanonicalJSONNamesClockPercentileAndResidualSemantics() throws {
    let receipt = DoryLinuxVMCalibrationProfileReceipt(
      agentProtocolVersion: 1,
      agentBuild: "fixture-agent",
      guestKernel: "fixture-kernel",
      argv: ["/bin/true"],
      samples: [
        sample(index: 3, serial: 12, connect: 22, info: 32, command: 300, wait: 120)
      ]
    )
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: DoryLinuxVMCalibrationProfile.canonicalJSON(for: receipt)
      ) as? [String: Any]
    )

    XCTAssertEqual(object["percentileMethod"] as? String, "nearest-rank")
    XCTAssertTrue((object["measurementClock"] as? String)?.contains("uptimeNanoseconds") == true)
    XCTAssertTrue((object["residualDefinition"] as? String)?.contains("transport") == true)
    let summary = try XCTUnwrap(object["summary"] as? [String: Any])
    XCTAssertEqual(summary["dominantCommandComponent"] as? String, "transportAndHostResidual")
  }

  private func sample(
    index: Int,
    serial: UInt64,
    connect: UInt64,
    info: UInt64,
    command: UInt64,
    wait: UInt64
  ) -> DoryLinuxVMCalibrationProfileSample {
    return DoryLinuxVMCalibrationProfileSample(
      index: index,
      serialRoundTripNanoseconds: serial,
      connectHandshakeNanoseconds: connect,
      protocolInfoRPCNanoseconds: info,
      commandRPCNanoseconds: command,
      agentTiming: DoryExecTiming(
        agentQueueNanoseconds: 5,
        processSpawnNanoseconds: 5,
        processWaitNanoseconds: wait,
        outputDrainNanoseconds: 10,
        agentTotalNanoseconds: wait + 30
      ),
      exitCode: 0,
      timedOut: false,
      stdoutTruncated: false,
      stderrTruncated: false
    )
  }
}
