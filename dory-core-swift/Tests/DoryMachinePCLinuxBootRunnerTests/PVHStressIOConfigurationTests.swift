import Foundation
import Testing

@testable import dory_pc_linux_boot_runner

@Suite struct PVHStressIOConfigurationTests {
  private let runID = "fd747216-e661-4b7c-876e-28ab532918e4"

  @Test func IODevicesRequireAnExplicitDirectoryDiagnosticsAndExactWorkloads() throws {
    let configuration = try PVHRunnerConfiguration(arguments: arguments())
    #expect(configuration.stressIODirectory == "/tmp/dory-io-new")
    #expect(configuration.workloads == PVHRunnerConfiguration.stressIOWorkloads.sorted())
    for option in ["--diagnostics", "--workload"] {
      var values = arguments()
      let index = try #require(values.firstIndex(of: option))
      values.removeSubrange(index..<(index + 2))
      #expect(throws: PVHRunnerError.self) { _ = try PVHRunnerConfiguration(arguments: values) }
    }
    var relative = arguments()
    relative[(try #require(relative.firstIndex(of: "--stress-io-directory"))) + 1] = "relative"
    #expect(throws: PVHRunnerError.self) { _ = try PVHRunnerConfiguration(arguments: relative) }
    #expect(throws: PVHRunnerError.self) {
      _ = try PVHRunnerConfiguration(arguments: arguments() + ["--workload", "unexpected"])
    }
    #expect(throws: PVHRunnerError.self) {
      _ = try PVHRunnerConfiguration(arguments: arguments() + ["--stress-io-directory", "/tmp/another"])
    }
  }

  @Test func NetworkMeasurementsSurviveReceiptParsingAndMalformedNumbersReject() throws {
    var receipt = PVHGuestReceipt(schemaVersion: 1, doryPVHBoot: "userspace-ready",
      runID: runID, workloadsPassed: true, workloads: PVHRunnerConfiguration.stressIOWorkloads)
    receipt.ioNetwork = .init(frames: 4096, bytes: 4096 * 1024, elapsedNanoseconds: 5_200_000_000)
    let data = try JSONEncoder().encode(receipt)
    var capture = PVHConsoleCapture()
    capture.consume(Array(data) + [10], runID: runID, workloads: receipt.workloads)
    #expect(capture.receipt?.ioNetwork?.frames == 4096)
    #expect(capture.receipt?.ioNetwork?.bytes == 4096 * 1024)
    #expect(capture.receipt?.ioNetwork?.elapsedNanoseconds == 5_200_000_000)
    let original = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let malformedValues: [(String, Any)] = [("frames", -1), ("bytes", "4194304"),
                                           ("elapsedNanoseconds", -1)]
    for (field, invalid) in malformedValues {
      var object = original
      var measurement = try #require(object["ioNetwork"] as? [String: Any])
      measurement[field] = invalid
      object["ioNetwork"] = measurement
      var rejected = PVHConsoleCapture()
      rejected.consume(Array(try JSONSerialization.data(withJSONObject: object)) + [10],
        runID: runID, workloads: receipt.workloads)
      #expect(rejected.receipt == nil)
    }
  }

  private func arguments() -> [String] {
    ["--kernel", "/kernel", "--kernel-sha256", String(repeating: "a", count: 64),
     "--initrd", "/initrd", "--initrd-sha256", String(repeating: "b", count: 64),
     "--command-line", "console=ttyS0 rdinit=/init", "--tier", "baseline-jit",
     "--memory-mib", "512", "--max-instructions", "10000", "--wall-seconds", "60",
     "--run-id", runID, "--workload", "io.block_flush_reopen",
     "--workload", "io.ethernet_frame_roundtrip", "--diagnostics", "/tmp/dory-io-result.json",
     "--stress-io-directory", "/tmp/dory-io-new"]
  }
}
