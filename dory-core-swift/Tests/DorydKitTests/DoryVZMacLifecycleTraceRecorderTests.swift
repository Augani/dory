import Foundation
@testable import DoryVMMKit
import XCTest

final class DoryVZMacLifecycleTraceRecorderTests: XCTestCase {
  func testOneLaunchWritesOrderedPrivateEventsAndCannotOverwriteItsTrace() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("dory-vzmac-trace-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }

    let operationID = UUID()
    let recorder = try DoryVZMacLifecycleTraceRecorder(
      stateDirectoryURL: directory,
      machineID: "machine-1",
      operationID: operationID,
      launchOperation: .run
    )
    recorder.record(.launchStarted)
    recorder.record(.running)
    recorder.record(.windowResized)
    recorder.close()
    recorder.close()
    recorder.record(.processEnded)

    let path = URL(fileURLWithPath: recorder.path)
    let bytes = try Data(contentsOf: path)
    XCTAssertEqual(bytes.last, 0x0a)
    let lines = bytes.split(separator: 0x0a)
    XCTAssertEqual(lines.count, 3)
    let records = try lines.map { line -> [String: Any] in
      let value = try JSONSerialization.jsonObject(with: Data(line))
      return try XCTUnwrap(value as? [String: Any])
    }
    XCTAssertEqual(records.compactMap { $0["sequence"] as? Int }, [1, 2, 3])
    let monotonic = records.compactMap { $0["monotonicNanoseconds"] as? UInt64 }
    XCTAssertEqual(monotonic.count, 3)
    XCTAssertTrue(zip(monotonic, monotonic.dropFirst()).allSatisfy { $0.0 < $0.1 })
    XCTAssertEqual(records.compactMap { $0["event"] as? String }, [
      "launch-started", "running", "window-resized",
    ])
    XCTAssertTrue(records.allSatisfy {
      $0["schema"] as? String == "dory.vzmac-lifecycle-event@1"
        && $0["machineID"] as? String == "machine-1"
        && $0["operationID"] as? String == operationID.uuidString.lowercased()
        && $0["launchOperation"] as? String == "run"
        && $0["vmmProcessIdentifier"] as? Int == Int(ProcessInfo.processInfo.processIdentifier)
    })
    let permissions = try FileManager.default.attributesOfItem(atPath: recorder.path)
    XCTAssertEqual((permissions[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    XCTAssertThrowsError(try DoryVZMacLifecycleTraceRecorder(
      stateDirectoryURL: directory,
      machineID: "machine-1",
      operationID: operationID,
      launchOperation: .run
    ))
  }
}
