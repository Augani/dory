import CryptoKit
import Foundation
import Testing

@testable import DoryARMVirtQualification

@Suite struct DoryARMVirtCompatibilityMatrixTests {
  @Test func checkedInMatrixBindsEveryFixtureAndTarget() throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let firmwareRoot = repository.appendingPathComponent("Firmware/DoryARMVirt")
    let matrixData = try Data(
      contentsOf: firmwareRoot.appendingPathComponent("compatibility-matrix.json")
    )
    let matrix = try JSONDecoder().decode(
      DoryARMVirtCompatibilityMatrix.self,
      from: matrixData
    ).validated()

    #expect(matrix.gates.count == 11)
    #expect(try matrix.gate(id: "archboot-installer-boot").mediaID == "archboot-2026.08.30-arm64")
    #expect(try matrix.gate(id: "debian-update").receipt.bootAttempts == 3)
    #expect(try matrix.gate(id: "debian-update").gvproxySHA256 != nil)
    #expect(try matrix.gate(id: "debian-installer-boot").gvproxySHA256 == nil)
    #expect(try matrix.gate(id: "fedora-installer-boot").mediaID == "fedora-server-44-1.7-arm64")
    #expect(try matrix.gate(id: "fedora-coreos-live-boot").mediaID == "fedora-coreos-44.20260802.3.1-arm64")
    #expect(try matrix.gate(id: "opensuse-installer-boot").mediaID == "opensuse-tumbleweed-20260806-arm64")
    #expect(matrix.gates.filter { $0.gvproxySHA256 != nil }.count == 9)
    #expect(throws: DoryARMVirtCompatibilityMatrixError.gateUnavailable("missing")) {
      try matrix.gate(id: "missing")
    }
    for gate in matrix.gates {
      let fixtureData = try Data(
        contentsOf: firmwareRoot.appendingPathComponent(gate.consoleScriptPath)
      )
      #expect(Self.digest(fixtureData) == gate.consoleScriptSHA256)
      let script = try JSONDecoder().decode(DoryConsoleInteractionScript.self, from: fixtureData)
      let driver = try DoryConsoleInteractionDriver(script: script)
      let media = try #require(matrix.media[gate.mediaID])
      let target = try #require(driver.qualificationTarget)
      #expect(target.guestFamily == media.guestFamily)
      #expect(target.guestVersion == media.guestVersion)
      #expect(target.guestBuild == media.guestBuild)
      #expect(target.guestArchitecture == media.guestArchitecture)
      #expect(driver.stepCount == gate.receipt.consoleScriptStepCount)
      #expect(!driver.inputContains(gate.expectedConsoleText))
    }
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
