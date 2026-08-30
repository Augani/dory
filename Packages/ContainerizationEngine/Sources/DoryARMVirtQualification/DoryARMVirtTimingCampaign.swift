import CryptoKit
import Foundation

public struct DoryARMVirtTimingDistribution: Codable, Equatable, Sendable {
  public let sampleCount: Int
  public let minimumNanoseconds: UInt64
  public let medianNanoseconds: UInt64
  public let p95Nanoseconds: UInt64
  public let p99Nanoseconds: UInt64
  public let maximumNanoseconds: UInt64
  public let meanNanoseconds: Double
  public let populationVarianceNanosecondsSquared: Double
}

public struct DoryARMVirtBootAttemptTimingDistribution: Codable, Equatable, Sendable {
  public let bootAttempt: Int
  public let distribution: DoryARMVirtTimingDistribution
}

public struct DoryARMVirtTimingCampaignReceipt: Codable, Equatable, Sendable {
  public static let kind = "dev.dory.armvirt-timing-campaign"
  public static let schemaVersion: UInt32 = 1

  public let kind: String
  public let schemaVersion: UInt32
  public let compatibilityMatrixSHA256: String
  public let qualificationGateID: String
  public let hostArchitecture: String
  public let hostHardwareModel: String
  public let hostOperatingSystemVersion: String
  public let hostOperatingSystemBuild: String
  public let hostBootSessionUUID: String
  public let hostPhysicalMemoryByteCount: UInt64
  public let guestFamily: String
  public let guestVersion: String
  public let guestBuild: String
  public let guestArchitecture: String
  public let executionEngineIdentity: String
  public let cpuProfileIdentity: String
  public let machineABIIdentity: String
  public let firmwareABIIdentity: String
  public let deviceABIIdentity: String
  public let runnerSHA256: String
  public let firmwareBuildIdentifier: String
  public let firmwareCodeSHA256: String
  public let timingClockIdentity: String
  public let campaignStartedAt: String
  public let campaignCompletedAt: String
  public let sampleCount: Int
  public let sampleReceiptSHA256: [String]
  public let bootAttempts: [DoryARMVirtBootAttemptTimingDistribution]
  public let qualification: DoryARMVirtTimingDistribution
}

public enum DoryARMVirtTimingCampaign {
  public static let releaseMinimumSampleCount = 9
  public static let maximumSampleCount = 100

  public static func aggregate(
    receiptData: [Data],
    matrixData: Data,
    gateID: String,
    minimumSampleCount: Int = releaseMinimumSampleCount
  ) throws -> DoryARMVirtTimingCampaignReceipt {
    guard (releaseMinimumSampleCount...maximumSampleCount).contains(minimumSampleCount),
      (minimumSampleCount...maximumSampleCount).contains(receiptData.count)
    else {
      throw DoryARMVirtTimingCampaignError.invalidSampleCount
    }
    let receipts = try receiptData.map {
      try DoryARMVirtQualificationReceiptVerifier.verify(
        receiptData: $0,
        matrixData: matrixData,
        gateID: gateID
      )
    }
    let digests = receiptData.map(digest)
    guard Set(digests).count == digests.count else {
      throw DoryARMVirtTimingCampaignError.duplicateSample
    }
    guard let first = receipts.first,
      let matrixSHA256 = first.compatibilityMatrixSHA256,
      let guestFamily = first.guestFamily,
      let guestVersion = first.guestVersion,
      let guestBuild = first.guestBuild,
      let guestArchitecture = first.guestArchitecture
    else {
      throw DoryARMVirtTimingCampaignError.invalidTuple(sampleIndex: 0)
    }
    let tuple = Tuple(receipt: first)
    var previousCompletion: Date?
    for (index, receipt) in receipts.enumerated() {
      guard Tuple(receipt: receipt) == tuple else {
        throw DoryARMVirtTimingCampaignError.invalidTuple(sampleIndex: index)
      }
      guard receipt.hostPowerSourceAtStart == "ac-power",
        receipt.hostPowerSourceAtEnd == "ac-power",
        !receipt.hostLowPowerModeEnabledAtStart,
        !receipt.hostLowPowerModeEnabledAtEnd,
        receipt.hostThermalStateAtStart == "nominal",
        receipt.hostThermalStateAtEnd == "nominal"
      else {
        throw DoryARMVirtTimingCampaignError.invalidHostState(sampleIndex: index)
      }
      guard let start = timestamp(receipt.qualificationStartedAt),
        let completion = timestamp(receipt.qualificationCompletedAt),
        previousCompletion.map({ $0 <= start }) ?? true
      else {
        throw DoryARMVirtTimingCampaignError.invalidChronology(sampleIndex: index)
      }
      previousCompletion = completion
    }
    let bootAttempts = (0..<first.bootAttempts).map { attempt in
      DoryARMVirtBootAttemptTimingDistribution(
        bootAttempt: attempt + 1,
        distribution: distribution(receipts.map { $0.bootDurationNanoseconds[attempt] })
      )
    }
    return DoryARMVirtTimingCampaignReceipt(
      kind: DoryARMVirtTimingCampaignReceipt.kind,
      schemaVersion: DoryARMVirtTimingCampaignReceipt.schemaVersion,
      compatibilityMatrixSHA256: matrixSHA256,
      qualificationGateID: gateID,
      hostArchitecture: first.hostArchitecture,
      hostHardwareModel: first.hostHardwareModel,
      hostOperatingSystemVersion: first.hostOperatingSystemVersion,
      hostOperatingSystemBuild: first.hostOperatingSystemBuild,
      hostBootSessionUUID: first.hostBootSessionUUID,
      hostPhysicalMemoryByteCount: first.hostPhysicalMemoryByteCount,
      guestFamily: guestFamily,
      guestVersion: guestVersion,
      guestBuild: guestBuild,
      guestArchitecture: guestArchitecture,
      executionEngineIdentity: first.executionEngineIdentity,
      cpuProfileIdentity: first.cpuProfileIdentity,
      machineABIIdentity: first.machineABIIdentity,
      firmwareABIIdentity: first.firmwareABIIdentity,
      deviceABIIdentity: first.deviceABIIdentity,
      runnerSHA256: first.runnerSHA256,
      firmwareBuildIdentifier: first.buildIdentifier,
      firmwareCodeSHA256: first.firmwareCodeSHA256,
      timingClockIdentity: first.timingClockIdentity,
      campaignStartedAt: first.qualificationStartedAt,
      campaignCompletedAt: receipts[receipts.count - 1].qualificationCompletedAt,
      sampleCount: receipts.count,
      sampleReceiptSHA256: digests,
      bootAttempts: bootAttempts,
      qualification: distribution(receipts.map(\.qualificationDurationNanoseconds))
    )
  }

  private static func distribution(_ values: [UInt64]) -> DoryARMVirtTimingDistribution {
    let sorted = values.sorted()
    let doubles = values.map(Double.init)
    let mean = doubles.reduce(0, +) / Double(doubles.count)
    let variance =
      doubles.reduce(0) { partial, value in
        let difference = value - mean
        return partial + difference * difference
      } / Double(doubles.count)
    return DoryARMVirtTimingDistribution(
      sampleCount: values.count,
      minimumNanoseconds: sorted[0],
      medianNanoseconds: nearestRank(0.5, in: sorted),
      p95Nanoseconds: nearestRank(0.95, in: sorted),
      p99Nanoseconds: nearestRank(0.99, in: sorted),
      maximumNanoseconds: sorted[sorted.count - 1],
      meanNanoseconds: mean,
      populationVarianceNanosecondsSquared: variance
    )
  }

  private static func nearestRank(_ percentile: Double, in sorted: [UInt64]) -> UInt64 {
    let rank = max(1, Int(ceil(percentile * Double(sorted.count))))
    return sorted[rank - 1]
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func timestamp(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value)
  }

  private struct Tuple: Equatable {
    let compatibilityMatrixSHA256: String?
    let qualificationGateID: String?
    let hostArchitecture: String
    let hostHardwareModel: String
    let hostOperatingSystemVersion: String
    let hostOperatingSystemBuild: String
    let hostBootSessionUUID: String
    let hostPhysicalMemoryByteCount: UInt64
    let guestFamily: String?
    let guestVersion: String?
    let guestBuild: String?
    let guestArchitecture: String?
    let guestVCPUCount: Int
    let executionEngineIdentity: String
    let cpuProfileIdentity: String
    let machineABIIdentity: String
    let firmwareABIIdentity: String
    let deviceABIIdentity: String
    let runnerSHA256: String
    let buildIdentifier: String
    let firmwareCodeSHA256: String
    let installerMediaByteCount: UInt64?
    let installerMediaSHA256: String?
    let systemDiskByteCount: UInt64
    let memoryByteCount: UInt64
    let consoleScriptSHA256: String?
    let gvproxySHA256: String?
    let bootAttempts: Int
    let timingClockIdentity: String

    init(receipt: DoryARMVirtQualificationReceipt) {
      compatibilityMatrixSHA256 = receipt.compatibilityMatrixSHA256
      qualificationGateID = receipt.qualificationGateID
      hostArchitecture = receipt.hostArchitecture
      hostHardwareModel = receipt.hostHardwareModel
      hostOperatingSystemVersion = receipt.hostOperatingSystemVersion
      hostOperatingSystemBuild = receipt.hostOperatingSystemBuild
      hostBootSessionUUID = receipt.hostBootSessionUUID
      hostPhysicalMemoryByteCount = receipt.hostPhysicalMemoryByteCount
      guestFamily = receipt.guestFamily
      guestVersion = receipt.guestVersion
      guestBuild = receipt.guestBuild
      guestArchitecture = receipt.guestArchitecture
      guestVCPUCount = receipt.guestVCPUCount
      executionEngineIdentity = receipt.executionEngineIdentity
      cpuProfileIdentity = receipt.cpuProfileIdentity
      machineABIIdentity = receipt.machineABIIdentity
      firmwareABIIdentity = receipt.firmwareABIIdentity
      deviceABIIdentity = receipt.deviceABIIdentity
      runnerSHA256 = receipt.runnerSHA256
      buildIdentifier = receipt.buildIdentifier
      firmwareCodeSHA256 = receipt.firmwareCodeSHA256
      installerMediaByteCount = receipt.installerMediaByteCount
      installerMediaSHA256 = receipt.installerMediaSHA256
      systemDiskByteCount = receipt.systemDiskByteCount
      memoryByteCount = receipt.memoryByteCount
      consoleScriptSHA256 = receipt.consoleScriptSHA256
      gvproxySHA256 = receipt.gvproxySHA256
      bootAttempts = receipt.bootAttempts
      timingClockIdentity = receipt.timingClockIdentity
    }
  }
}

public enum DoryARMVirtTimingCampaignError: Error, Equatable, Sendable {
  case invalidSampleCount
  case invalidTuple(sampleIndex: Int)
  case invalidHostState(sampleIndex: Int)
  case invalidChronology(sampleIndex: Int)
  case duplicateSample
}
