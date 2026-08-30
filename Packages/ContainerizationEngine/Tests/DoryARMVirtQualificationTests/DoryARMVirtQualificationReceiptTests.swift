import CryptoKit
import Foundation
import Testing

@testable import DoryARMVirtQualification

@Suite struct DoryARMVirtQualificationReceiptTests {
  @Test func verifiesExactSchemaTenReceiptAgainstCheckedInMatrix() throws {
    let fixture = try Fixture()
    let receipt = fixture.receipt()

    #expect(
      try DoryARMVirtQualificationReceiptVerifier.verify(
        receiptData: fixture.encode(receipt),
        matrixData: fixture.matrixData,
        gateID: fixture.gate.gateID
      ) == receipt
    )
  }

  @Test func rejectsUnknownFieldsAndOldSchemas() throws {
    let fixture = try Fixture()
    var object = try fixture.object(fixture.receipt())
    object["unreviewedAuthority"] = true
    #expect(throws: DoryARMVirtQualificationReceiptError.invalidJSONShape) {
      try fixture.verify(object)
    }

    object = try fixture.object(fixture.receipt())
    object["schemaVersion"] = 9
    #expect(
      throws: DoryARMVirtQualificationReceiptError.unsupportedSchemaVersion(9)
    ) {
      try fixture.verify(object)
    }
  }

  @Test func rejectsMatrixSidecarAndTimingDrift() throws {
    let fixture = try Fixture()
    var object = try fixture.object(fixture.receipt())
    object["compatibilityMatrixSHA256"] = String(repeating: "f", count: 64)
    #expect(
      throws: DoryARMVirtQualificationReceiptError.invalidField("qualificationAuthority")
    ) {
      try fixture.verify(object)
    }

    object = try fixture.object(fixture.receipt())
    object["gvproxySHA256"] = String(repeating: "a", count: 64)
    #expect(throws: DoryARMVirtQualificationReceiptError.invalidField("gateInputs")) {
      try fixture.verify(object)
    }

    object = try fixture.object(fixture.receipt())
    object["bootDurationNanoseconds"] = [0]
    #expect(
      throws: DoryARMVirtQualificationReceiptError.invalidField(
        "bootDurationNanoseconds"
      )
    ) {
      try fixture.verify(object)
    }
  }

  @Test func rejectsUnexpectedSnapshotAuthority() throws {
    let fixture = try Fixture()
    var object = try fixture.object(fixture.receipt())
    object["coldSnapshotABIIdentity"] = "dory.snapshot.armvirt.cold@1"
    object["coldSnapshotSystemDiskSHA256"] = String(repeating: "a", count: 64)
    object["coldSnapshotVariableStoreGeneration"] = 1
    #expect(
      throws: DoryARMVirtQualificationReceiptError.invalidField("unexpectedColdSnapshot")
    ) {
      try fixture.verify(object)
    }
  }

  @Test func verifiesDesktopContentFrameEvidence() throws {
    let fixture = try Fixture(gateID: "fedora-workstation-live-boot")
    let receipt = fixture.receipt()

    #expect(try fixture.verify(fixture.object(receipt)) == receipt)
  }

  @Test func rejectsMissingOrDriftingDesktopContentFrameEvidence() throws {
    let fixture = try Fixture(gateID: "fedora-workstation-live-boot")
    var object = try fixture.object(fixture.receipt())
    object.removeValue(forKey: "displayContentFrameSHA256")
    #expect(throws: DoryARMVirtQualificationReceiptError.invalidField("display")) {
      try fixture.verify(object)
    }

    object = try fixture.object(fixture.receipt())
    object["displayContentFrameCount"] = 0
    #expect(throws: DoryARMVirtQualificationReceiptError.invalidField("display")) {
      try fixture.verify(object)
    }

    object = try fixture.object(fixture.receipt())
    object["displayContentFrameWidthPixels"] = 800
    #expect(throws: DoryARMVirtQualificationReceiptError.invalidField("display")) {
      try fixture.verify(object)
    }

    object = try fixture.object(fixture.receipt())
    object["displayContentFrameByteCount"] = 1
    #expect(throws: DoryARMVirtQualificationReceiptError.invalidField("display")) {
      try fixture.verify(object)
    }
  }

  @Test func rejectsDisplayEvidenceForNonDesktopGate() throws {
    let fixture = try Fixture()
    var object = try fixture.object(fixture.receipt())
    object["displayContentFrameCount"] = 1
    #expect(
      throws: DoryARMVirtQualificationReceiptError.invalidField("unexpectedDisplay")
    ) {
      try fixture.verify(object)
    }
  }

  @Test func rejectsMissingOrFaultedDesktopInputEvidence() throws {
    let fixture = try Fixture(gateID: "fedora-workstation-live-boot")
    var object = try fixture.object(fixture.receipt())
    object.removeValue(forKey: "keyboardInputPublishedFrameCount")
    #expect(throws: DoryARMVirtQualificationReceiptError.invalidField("input")) {
      try fixture.verify(object)
    }

    object = try fixture.object(fixture.receipt())
    object["pointerInputPublishedEventCount"] = 2
    #expect(throws: DoryARMVirtQualificationReceiptError.invalidField("input")) {
      try fixture.verify(object)
    }

    object = try fixture.object(fixture.receipt())
    object["keyboardInputDroppedFrameCount"] = 1
    #expect(throws: DoryARMVirtQualificationReceiptError.invalidField("input")) {
      try fixture.verify(object)
    }
  }

  @Test func rejectsInputEvidenceForNonInputGate() throws {
    let fixture = try Fixture()
    var object = try fixture.object(fixture.receipt())
    object["keyboardInputPublishedFrameCount"] = 1
    #expect(
      throws: DoryARMVirtQualificationReceiptError.invalidField("unexpectedInput")
    ) {
      try fixture.verify(object)
    }
  }

  @Test func rejectsMissingOrFaultedDesktopAudioEvidence() throws {
    let fixture = try Fixture(gateID: "fedora-workstation-live-boot")
    var object = try fixture.object(fixture.receipt())
    object.removeValue(forKey: "audioCompletedPlaybackPeriodCount")
    #expect(throws: DoryARMVirtQualificationReceiptError.invalidField("audio")) {
      try fixture.verify(object)
    }

    object = try fixture.object(fixture.receipt())
    object["audioCaptureByteCount"] = 0
    #expect(throws: DoryARMVirtQualificationReceiptError.invalidField("audio")) {
      try fixture.verify(object)
    }

    object = try fixture.object(fixture.receipt())
    object["audioDeviceFaultCount"] = 1
    #expect(throws: DoryARMVirtQualificationReceiptError.invalidField("audio")) {
      try fixture.verify(object)
    }
  }

  @Test func rejectsAudioEvidenceForNonAudioGate() throws {
    let fixture = try Fixture()
    var object = try fixture.object(fixture.receipt())
    object["audioPlaybackByteCount"] = 1
    #expect(
      throws: DoryARMVirtQualificationReceiptError.invalidField("unexpectedAudio")
    ) {
      try fixture.verify(object)
    }
  }
}

private struct Fixture {
  let matrixData: Data
  let matrixSHA256: String
  let gate: DoryARMVirtCompatibilityGate
  let media: DoryARMVirtCompatibilityMedia

  init(gateID: String = "debian-installer-boot") throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    matrixData = try Data(
      contentsOf: repository.appendingPathComponent(
        "Firmware/DoryARMVirt/compatibility-matrix.json"
      )
    )
    matrixSHA256 = SHA256.hash(data: matrixData)
      .map { String(format: "%02x", $0) }.joined()
    let matrix = try JSONDecoder().decode(
      DoryARMVirtCompatibilityMatrix.self,
      from: matrixData
    ).validated()
    gate = try matrix.gate(id: gateID)
    media = try #require(matrix.media[gate.mediaID])
  }

  func receipt() -> DoryARMVirtQualificationReceipt {
    DoryARMVirtQualificationReceipt(
      machineABIIdentity: "dory.armvirt@1",
      firmwareABIIdentity: "dory.edk2.armvirt@1",
      executionEngineIdentity: "dory.native-hv.arm64@1",
      cpuProfileIdentity: "dory.arm64.generic-v1",
      deviceABIIdentity: "dory.virtio@1",
      hostArchitecture: "arm64",
      hostHardwareModel: "Mac14,10",
      hostOperatingSystemVersion: "Version 26.0",
      hostOperatingSystemBuild: "26A5421a",
      hostBootSessionUUID: "D8A1C440-174D-4AE8-A564-A56EFB3DE487",
      hostPhysicalMemoryByteCount: 16 << 30,
      hostPowerSourceAtStart: "ac-power",
      hostPowerSourceAtEnd: "ac-power",
      hostLowPowerModeEnabledAtStart: false,
      hostLowPowerModeEnabledAtEnd: false,
      hostThermalStateAtStart: "nominal",
      hostThermalStateAtEnd: "nominal",
      qualificationStartedAt: "2026-08-30T08:00:00.000Z",
      qualificationCompletedAt: "2026-08-30T08:00:05.000Z",
      guestFamily: media.guestFamily,
      guestVersion: media.guestVersion,
      guestBuild: media.guestBuild,
      guestArchitecture: media.guestArchitecture,
      guestVCPUCount: 1,
      runnerSHA256: String(repeating: "1", count: 64),
      compatibilityMatrixSHA256: matrixSHA256,
      qualificationGateID: gate.gateID,
      buildIdentifier: "dory-armvirt-v1-test",
      firmwareCodeSHA256: String(repeating: "2", count: 64),
      expectedConsoleText: gate.expectedConsoleText,
      installerMediaByteCount: media.byteCount,
      installerMediaSHA256: media.sha256,
      systemDiskByteCount: gate.systemDiskByteCount,
      memoryByteCount: gate.memoryByteCount,
      consoleScriptSHA256: gate.consoleScriptSHA256,
      consoleScriptStepCount: gate.receipt.consoleScriptStepCount,
      completedConsoleScriptStepCount: gate.receipt.consoleScriptStepCount,
      installerMediaTransitionCount: gate.receipt.installerMediaTransitionCount,
      installerMediaAttachedForFinalBoot:
        gate.receipt.installerMediaAttachedForFinalBoot,
      coldSnapshotActionCount: gate.receipt.coldSnapshotActionCount,
      completedColdSnapshotActionCount: gate.receipt.coldSnapshotActionCount,
      coldSnapshotABIIdentity: nil,
      coldSnapshotSystemDiskSHA256: nil,
      coldSnapshotVariableStoreGeneration: nil,
      gvproxySHA256: gate.gvproxySHA256,
      displayScanoutCount: gate.display?.scanoutCount,
      displayContentFrameCount: gate.display?.minimumContentFrameCount,
      displayContentFrameWidthPixels: gate.display?.widthPixels,
      displayContentFrameHeightPixels: gate.display?.heightPixels,
      displayContentFrameByteCount: gate.display.map {
        Int($0.widthPixels) * Int($0.heightPixels) * 4
      },
      displayContentFrameNonZeroByteCount: gate.display.map { _ in 1_024 },
      displayContentFrameSHA256: gate.display.map { _ in String(repeating: "3", count: 64) },
      keyboardInputSubmittedFrameCount: gate.input.map { _ in 1 },
      keyboardInputPublishedFrameCount: gate.input?.keyboardMinimumPublishedFrameCount,
      keyboardInputPublishedEventCount: gate.input?.keyboardMinimumPublishedEventCount,
      keyboardInputDroppedFrameCount: gate.input.map { _ in 0 },
      keyboardInputRejectedFrameCount: gate.input.map { _ in 0 },
      pointerInputSubmittedFrameCount: gate.input.map { _ in 1 },
      pointerInputPublishedFrameCount: gate.input?.pointerMinimumPublishedFrameCount,
      pointerInputPublishedEventCount: gate.input?.pointerMinimumPublishedEventCount,
      pointerInputDroppedFrameCount: gate.input.map { _ in 0 },
      pointerInputRejectedFrameCount: gate.input.map { _ in 0 },
      audioConfiguredPlaybackStreamCount: gate.audio.map { _ in 1 },
      audioConfiguredCaptureStreamCount: gate.audio.map { _ in 1 },
      audioStartedPlaybackStreamCount: gate.audio.map { _ in 1 },
      audioStartedCaptureStreamCount: gate.audio.map { _ in 1 },
      audioPlaybackByteCount: gate.audio?.minimumPlaybackByteCount,
      audioCaptureByteCount: gate.audio?.minimumCaptureByteCount,
      audioCompletedPlaybackPeriodCount: gate.audio?.minimumCompletedPlaybackPeriodCount,
      audioCompletedCapturePeriodCount: gate.audio?.minimumCompletedCapturePeriodCount,
      audioDeviceFaultCount: gate.audio.map { _ in 0 },
      consoleByteCount: 4_096,
      bootAttempts: gate.receipt.bootAttempts,
      bootDurationNanoseconds: [4_000_000_000],
      qualificationDurationNanoseconds: 5_000_000_000,
      variableStoreGeneration: 4,
      stopReason: "power-off"
    )
  }

  func encode(_ receipt: DoryARMVirtQualificationReceipt) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(receipt)
  }

  func object(_ receipt: DoryARMVirtQualificationReceipt) throws -> [String: Any] {
    try #require(
      JSONSerialization.jsonObject(with: encode(receipt)) as? [String: Any]
    )
  }

  func verify(_ object: [String: Any]) throws -> DoryARMVirtQualificationReceipt {
    try DoryARMVirtQualificationReceiptVerifier.verify(
      receiptData: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
      matrixData: matrixData,
      gateID: gate.gateID
    )
  }
}
