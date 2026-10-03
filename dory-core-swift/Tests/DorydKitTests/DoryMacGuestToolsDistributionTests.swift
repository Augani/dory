import CryptoKit
import Foundation
@testable import DorydKit
import XCTest

final class DoryMacGuestToolsDistributionTests: XCTestCase {
  private func fixture() throws -> (directory: URL, package: URL, manifest: URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("dory-mac-tools-distribution-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let package = directory.appendingPathComponent("DoryGuestTools-1.2.3-arm64.pkg")
    let manifest = directory.appendingPathComponent("DoryGuestTools-1.2.3-arm64.pkg.json")
    let payload = Data("signed-package-fixture".utf8)
    try payload.write(to: package)
    let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    let document: [String: Any] = [
      "schema": "dory.macos-guest-tools-package@3",
      "package": [
        "filename": package.lastPathComponent,
        "sha256": digest,
        "byteCount": payload.count,
        "installLocation": "/",
        "installedAppPath": "/Applications/DoryGuestTools.app",
        "installerTeamIdentifier": "864H636QW4",
      ],
      "notarization": [
        "status": "stapled",
        "submissionID": UUID().uuidString.lowercased(),
      ],
      "loginAgent": [
        "path": "/Library/LaunchAgents/com.pythonxi.Dory.GuestTools.agent.plist",
        "label": "com.pythonxi.Dory.GuestTools.agent",
        "sha256": String(repeating: "a", count: 64),
      ],
    ]
    try JSONSerialization.data(withJSONObject: document).write(to: manifest)
    return (directory, package, manifest)
  }

  func testAcceptsExactDistributionAndRejectsChangedPackage() throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    XCTAssertNoThrow(try DoryMacGuestToolsDistribution.validate(directoryPath: fixture.directory.path))
    try Data("changed-package-fixture".utf8).write(to: fixture.package)
    XCTAssertThrowsError(try DoryMacGuestToolsDistribution.validate(directoryPath: fixture.directory.path))
  }

  func testRejectsInventoryExpansionAndIndirectPackage() throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let extra = fixture.directory.appendingPathComponent("unexpected.txt")
    try Data("extra".utf8).write(to: extra)
    XCTAssertThrowsError(try DoryMacGuestToolsDistribution.validate(directoryPath: fixture.directory.path))
    try FileManager.default.removeItem(at: extra)
    try FileManager.default.removeItem(at: fixture.package)
    try FileManager.default.createSymbolicLink(at: fixture.package, withDestinationURL: fixture.manifest)
    XCTAssertThrowsError(try DoryMacGuestToolsDistribution.validate(directoryPath: fixture.directory.path))
  }
}
