import CryptoKit
import Foundation
import Testing

@testable import DoryARMVirtQualification

@Suite struct DoryARMVirtTimingCampaignTests {
  @Test func aggregatesNineExactSamplesWithConservativeNearestRankPercentiles() throws {
    let fixture = try TimingFixture()
    let samples = try (0..<9).map { try fixture.receiptData(sample: $0) }

    let campaign = try DoryARMVirtTimingCampaign.aggregate(
      receiptData: samples,
      matrixData: fixture.matrixData,
      gateID: fixture.gate.gateID
    )

    #expect(campaign.kind == DoryARMVirtTimingCampaignReceipt.kind)
    #expect(campaign.sampleCount == 9)
    #expect(Set(campaign.sampleReceiptSHA256).count == 9)
    #expect(campaign.bootAttempts.count == 1)
    #expect(campaign.bootAttempts[0].distribution.minimumNanoseconds == 1_000_000_000)
    #expect(campaign.bootAttempts[0].distribution.medianNanoseconds == 5_000_000_000)
    #expect(campaign.bootAttempts[0].distribution.p95Nanoseconds == 9_000_000_000)
    #expect(campaign.bootAttempts[0].distribution.p99Nanoseconds == 9_000_000_000)
    #expect(campaign.qualification.medianNanoseconds == 5_500_000_000)
  }

  @Test func rejectsTooFewOrDuplicateSamples() throws {
    let fixture = try TimingFixture()
    let samples = try (0..<9).map { try fixture.receiptData(sample: $0) }
    #expect(throws: DoryARMVirtTimingCampaignError.invalidSampleCount) {
      try DoryARMVirtTimingCampaign.aggregate(
        receiptData: Array(samples.prefix(8)),
        matrixData: fixture.matrixData,
        gateID: fixture.gate.gateID
      )
    }

    var duplicate = samples
    duplicate[8] = duplicate[0]
    #expect(throws: DoryARMVirtTimingCampaignError.duplicateSample) {
      try DoryARMVirtTimingCampaign.aggregate(
        receiptData: duplicate,
        matrixData: fixture.matrixData,
        gateID: fixture.gate.gateID
      )
    }
  }

  @Test func rejectsTupleAndHostConditionDrift() throws {
    let fixture = try TimingFixture()
    var samples = try (0..<9).map { try fixture.receiptData(sample: $0) }
    samples[8] = try fixture.receiptData(
      sample: 8,
      runnerSHA256: String(repeating: "f", count: 64)
    )
    #expect(throws: DoryARMVirtTimingCampaignError.invalidTuple(sampleIndex: 8)) {
      try DoryARMVirtTimingCampaign.aggregate(
        receiptData: samples,
        matrixData: fixture.matrixData,
        gateID: fixture.gate.gateID
      )
    }

    samples[8] = try fixture.receiptData(sample: 8, powerSource: "battery-power")
    #expect(throws: DoryARMVirtTimingCampaignError.invalidHostState(sampleIndex: 8)) {
      try DoryARMVirtTimingCampaign.aggregate(
        receiptData: samples,
        matrixData: fixture.matrixData,
        gateID: fixture.gate.gateID
      )
    }
  }
}

private struct TimingFixture {
  let matrixData: Data
  let matrixSHA256: String
  let gate: DoryARMVirtCompatibilityGate
  let media: DoryARMVirtCompatibilityMedia

  init() throws {
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
    gate = try matrix.gate(id: "debian-installer-boot")
    media = try #require(matrix.media[gate.mediaID])
  }

  func receiptData(
    sample: Int,
    runnerSHA256: String = String(repeating: "1", count: 64),
    powerSource: String = "ac-power"
  ) throws -> Data {
    let start = Date(timeIntervalSince1970: 1_788_076_800 + Double(sample * 10))
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let bootDuration = UInt64(sample + 1) * 1_000_000_000
    let receipt = DoryARMVirtQualificationReceipt(
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
      hostPowerSourceAtStart: powerSource,
      hostPowerSourceAtEnd: powerSource,
      hostLowPowerModeEnabledAtStart: false,
      hostLowPowerModeEnabledAtEnd: false,
      hostThermalStateAtStart: "nominal",
      hostThermalStateAtEnd: "nominal",
      qualificationStartedAt: formatter.string(from: start),
      qualificationCompletedAt: formatter.string(from: start.addingTimeInterval(9)),
      guestFamily: media.guestFamily,
      guestVersion: media.guestVersion,
      guestBuild: media.guestBuild,
      guestArchitecture: media.guestArchitecture,
      guestVCPUCount: 1,
      runnerSHA256: runnerSHA256,
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
      consoleByteCount: 4_096,
      bootAttempts: gate.receipt.bootAttempts,
      bootDurationNanoseconds: [bootDuration],
      qualificationDurationNanoseconds: bootDuration + 500_000_000,
      variableStoreGeneration: UInt64(sample + 1),
      stopReason: "power-off"
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(receipt)
  }
}
