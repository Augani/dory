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

    #expect(matrix.gates.count == 12)
    #expect(try matrix.gate(id: "archboot-installer-boot").mediaID == "archboot-2026.08.30-arm64")
    #expect(try matrix.gate(id: "debian-update").receipt.bootAttempts == 3)
    #expect(try matrix.gate(id: "debian-update").gvproxySHA256 != nil)
    #expect(try matrix.gate(id: "debian-installer-boot").gvproxySHA256 == nil)
    #expect(try matrix.gate(id: "fedora-installer-boot").mediaID == "fedora-server-44-1.7-arm64")
    #expect(
      try matrix.gate(id: "fedora-coreos-live-boot").mediaID
        == "fedora-coreos-44.20260802.3.1-arm64")
    let workstationGate = try matrix.gate(id: "fedora-workstation-live-boot")
    #expect(workstationGate.mediaID == "fedora-workstation-44-1.7-arm64")
    #expect(workstationGate.kind == .desktopLiveBoot)
    #expect(
      workstationGate.display
        == DoryARMVirtDisplayExpectation(
          scanoutCount: 2,
          widthPixels: 1_024,
          heightPixels: 768,
          minimumContentFrameCount: 2
        ))
    #expect(
      workstationGate.input
        == DoryARMVirtInputExpectation(
          keyboardMinimumPublishedFrameCount: 1,
          keyboardMinimumPublishedEventCount: 3,
          pointerMinimumPublishedFrameCount: 1,
          pointerMinimumPublishedEventCount: 3
        ))
    #expect(
      workstationGate.audio
        == DoryARMVirtAudioExpectation(
          minimumCompletedPlaybackPeriodCount: 1,
          minimumCompletedCapturePeriodCount: 1,
          minimumPlaybackByteCount: 192_000,
          minimumCaptureByteCount: 192_000
        ))
    #expect(
      workstationGate.guestTools
        == DoryARMVirtGuestToolsExpectation(
          byteCount: 1_402_368,
          sha256: "3d166dbea0ae6bcf60cc400a23ff134cab6bd9cc9d17b7348c691298dfcd5fbe",
          agentSHA256: "74b952b176f2aea7c576bac815a9eb2e3c8f8a2625c14767500b8a45f6b5fd9c"
        ))
    #expect(
      workstationGate.camera
        == DoryARMVirtCameraExpectation(
          busID: "255-1",
          busNumber: 255,
          deviceNumber: 1,
          vendorID: 0xD0F1,
          productID: 0xCA01,
          widthPixels: 1_280,
          heightPixels: 720,
          minimumHostFrameRequestCount: 1,
          minimumJPEGByteCount: 1_024
        ))
    #expect(
      try matrix.gate(id: "opensuse-installer-boot").mediaID == "opensuse-tumbleweed-20260806-arm64"
    )
    #expect(matrix.gates.filter { $0.gvproxySHA256 != nil }.count == 10)
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
      if let guestTools = gate.guestTools {
        #expect(driver.inputContains(guestTools.agentSHA256))
      }
    }
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
