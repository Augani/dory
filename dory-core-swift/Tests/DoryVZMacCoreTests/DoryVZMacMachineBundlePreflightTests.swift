import Foundation
import XCTest

@testable import DoryVZMacCore

final class DoryVZMacMachineBundlePreflightTests: XCTestCase {
  func testPreflightRejectsInvalidRestoreImageWithoutCreatingMachineArtifacts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "dory-vzmac-preflight-\(UUID().uuidString)", isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let image = root.appendingPathComponent("Restore.ipsw")
    try Data("not-an-Apple-restore-image".utf8).write(to: image)
    let before = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()

    var rejected = false
    do {
      _ = try await DoryVZMacMachineBundle.preflightRestoreImage(
        at: image,
        requestedCPUCount: 4,
        requestedMemoryBytes: 8 * DoryVZMacResourcePlan.gibibyte,
        diskBytes: 80 * DoryVZMacResourcePlan.gibibyte
      )
    } catch {
      rejected = true
    }

    XCTAssertTrue(rejected, "an invalid IPSW must fail before any machine allocation")
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), before)
  }
}
