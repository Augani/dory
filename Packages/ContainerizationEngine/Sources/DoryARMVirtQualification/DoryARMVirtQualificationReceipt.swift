import CryptoKit
import Foundation

public struct DoryARMVirtQualificationReceipt: Codable, Equatable, Sendable {
  public static let currentSchemaVersion: UInt32 = 6
  public static let timingClockIdentity = "dispatch-uptime-nanoseconds"

  public let schemaVersion: UInt32
  public let machineABIIdentity: String
  public let firmwareABIIdentity: String
  public let executionEngineIdentity: String
  public let cpuProfileIdentity: String
  public let deviceABIIdentity: String
  public let hostArchitecture: String
  public let hostHardwareModel: String
  public let hostOperatingSystemVersion: String
  public let hostOperatingSystemBuild: String
  public let guestFamily: String?
  public let guestVersion: String?
  public let guestBuild: String?
  public let guestArchitecture: String?
  public let guestVCPUCount: Int
  public let runnerSHA256: String
  public let compatibilityMatrixSHA256: String?
  public let qualificationGateID: String?
  public let buildIdentifier: String
  public let firmwareCodeSHA256: String
  public let expectedConsoleText: String
  public let installerMediaByteCount: UInt64?
  public let installerMediaSHA256: String?
  public let systemDiskByteCount: UInt64
  public let memoryByteCount: UInt64
  public let consoleScriptSHA256: String?
  public let consoleScriptStepCount: Int?
  public let completedConsoleScriptStepCount: Int?
  public let installerMediaTransitionCount: Int
  public let installerMediaAttachedForFinalBoot: Bool
  public let coldSnapshotActionCount: Int
  public let completedColdSnapshotActionCount: Int
  public let coldSnapshotABIIdentity: String?
  public let coldSnapshotSystemDiskSHA256: String?
  public let coldSnapshotVariableStoreGeneration: UInt64?
  public let gvproxySHA256: String?
  public let consoleByteCount: Int
  public let bootAttempts: Int
  public let timingClockIdentity: String
  public let bootDurationNanoseconds: [UInt64]
  public let qualificationDurationNanoseconds: UInt64
  public let variableStoreGeneration: UInt64
  public let stopReason: String

  public init(
    schemaVersion: UInt32 = Self.currentSchemaVersion,
    machineABIIdentity: String,
    firmwareABIIdentity: String,
    executionEngineIdentity: String,
    cpuProfileIdentity: String,
    deviceABIIdentity: String,
    hostArchitecture: String,
    hostHardwareModel: String,
    hostOperatingSystemVersion: String,
    hostOperatingSystemBuild: String,
    guestFamily: String?,
    guestVersion: String?,
    guestBuild: String?,
    guestArchitecture: String?,
    guestVCPUCount: Int,
    runnerSHA256: String,
    compatibilityMatrixSHA256: String?,
    qualificationGateID: String?,
    buildIdentifier: String,
    firmwareCodeSHA256: String,
    expectedConsoleText: String,
    installerMediaByteCount: UInt64?,
    installerMediaSHA256: String?,
    systemDiskByteCount: UInt64,
    memoryByteCount: UInt64,
    consoleScriptSHA256: String?,
    consoleScriptStepCount: Int?,
    completedConsoleScriptStepCount: Int?,
    installerMediaTransitionCount: Int,
    installerMediaAttachedForFinalBoot: Bool,
    coldSnapshotActionCount: Int,
    completedColdSnapshotActionCount: Int,
    coldSnapshotABIIdentity: String?,
    coldSnapshotSystemDiskSHA256: String?,
    coldSnapshotVariableStoreGeneration: UInt64?,
    gvproxySHA256: String?,
    consoleByteCount: Int,
    bootAttempts: Int,
    timingClockIdentity: String = Self.timingClockIdentity,
    bootDurationNanoseconds: [UInt64],
    qualificationDurationNanoseconds: UInt64,
    variableStoreGeneration: UInt64,
    stopReason: String
  ) {
    self.schemaVersion = schemaVersion
    self.machineABIIdentity = machineABIIdentity
    self.firmwareABIIdentity = firmwareABIIdentity
    self.executionEngineIdentity = executionEngineIdentity
    self.cpuProfileIdentity = cpuProfileIdentity
    self.deviceABIIdentity = deviceABIIdentity
    self.hostArchitecture = hostArchitecture
    self.hostHardwareModel = hostHardwareModel
    self.hostOperatingSystemVersion = hostOperatingSystemVersion
    self.hostOperatingSystemBuild = hostOperatingSystemBuild
    self.guestFamily = guestFamily
    self.guestVersion = guestVersion
    self.guestBuild = guestBuild
    self.guestArchitecture = guestArchitecture
    self.guestVCPUCount = guestVCPUCount
    self.runnerSHA256 = runnerSHA256
    self.compatibilityMatrixSHA256 = compatibilityMatrixSHA256
    self.qualificationGateID = qualificationGateID
    self.buildIdentifier = buildIdentifier
    self.firmwareCodeSHA256 = firmwareCodeSHA256
    self.expectedConsoleText = expectedConsoleText
    self.installerMediaByteCount = installerMediaByteCount
    self.installerMediaSHA256 = installerMediaSHA256
    self.systemDiskByteCount = systemDiskByteCount
    self.memoryByteCount = memoryByteCount
    self.consoleScriptSHA256 = consoleScriptSHA256
    self.consoleScriptStepCount = consoleScriptStepCount
    self.completedConsoleScriptStepCount = completedConsoleScriptStepCount
    self.installerMediaTransitionCount = installerMediaTransitionCount
    self.installerMediaAttachedForFinalBoot = installerMediaAttachedForFinalBoot
    self.coldSnapshotActionCount = coldSnapshotActionCount
    self.completedColdSnapshotActionCount = completedColdSnapshotActionCount
    self.coldSnapshotABIIdentity = coldSnapshotABIIdentity
    self.coldSnapshotSystemDiskSHA256 = coldSnapshotSystemDiskSHA256
    self.coldSnapshotVariableStoreGeneration = coldSnapshotVariableStoreGeneration
    self.gvproxySHA256 = gvproxySHA256
    self.consoleByteCount = consoleByteCount
    self.bootAttempts = bootAttempts
    self.timingClockIdentity = timingClockIdentity
    self.bootDurationNanoseconds = bootDurationNanoseconds
    self.qualificationDurationNanoseconds = qualificationDurationNanoseconds
    self.variableStoreGeneration = variableStoreGeneration
    self.stopReason = stopReason
  }
}

public enum DoryARMVirtQualificationReceiptVerifier {
  public static func verify(
    receiptData: Data,
    matrixData: Data,
    gateID: String
  ) throws -> DoryARMVirtQualificationReceipt {
    try validateJSONShape(receiptData)
    let matrix = try JSONDecoder().decode(DoryARMVirtCompatibilityMatrix.self, from: matrixData)
      .validated()
    let gate = try matrix.gate(id: gateID)
    guard let media = matrix.media[gate.mediaID] else {
      throw DoryARMVirtQualificationReceiptError.invalidField("gate.mediaID")
    }
    let receipt = try JSONDecoder().decode(
      DoryARMVirtQualificationReceipt.self,
      from: receiptData
    )
    let matrixSHA256 = SHA256.hash(data: matrixData)
      .map { String(format: "%02x", $0) }.joined()
    try validate(
      receipt,
      matrix: matrix,
      matrixSHA256: matrixSHA256,
      gate: gate,
      media: media
    )
    return receipt
  }

  private static func validate(
    _ receipt: DoryARMVirtQualificationReceipt,
    matrix: DoryARMVirtCompatibilityMatrix,
    matrixSHA256: String,
    gate: DoryARMVirtCompatibilityGate,
    media: DoryARMVirtCompatibilityMedia
  ) throws {
    guard receipt.schemaVersion == DoryARMVirtQualificationReceipt.currentSchemaVersion else {
      throw DoryARMVirtQualificationReceiptError.unsupportedSchemaVersion(receipt.schemaVersion)
    }
    guard receipt.machineABIIdentity == matrix.machineABIIdentity,
      receipt.firmwareABIIdentity == matrix.firmwareABIIdentity,
      receipt.executionEngineIdentity == "dory.native-hv.arm64@1",
      receipt.cpuProfileIdentity == "dory.arm64.generic-v1",
      receipt.deviceABIIdentity == matrix.deviceABIIdentity,
      receipt.hostArchitecture == "arm64",
      receipt.guestVCPUCount == 1
    else {
      throw DoryARMVirtQualificationReceiptError.invalidField("platformIdentity")
    }
    guard receipt.compatibilityMatrixSHA256 == matrixSHA256,
      receipt.qualificationGateID == gate.gateID
    else {
      throw DoryARMVirtQualificationReceiptError.invalidField("qualificationAuthority")
    }
    guard receipt.guestFamily == media.guestFamily,
      receipt.guestVersion == media.guestVersion,
      receipt.guestBuild == media.guestBuild,
      receipt.guestArchitecture == media.guestArchitecture,
      receipt.installerMediaByteCount == media.byteCount,
      receipt.installerMediaSHA256 == media.sha256
    else {
      throw DoryARMVirtQualificationReceiptError.invalidField("guestMediaTuple")
    }
    guard receipt.expectedConsoleText == gate.expectedConsoleText,
      receipt.systemDiskByteCount == gate.systemDiskByteCount,
      receipt.memoryByteCount == gate.memoryByteCount,
      receipt.consoleScriptSHA256 == gate.consoleScriptSHA256,
      receipt.gvproxySHA256 == gate.gvproxySHA256
    else {
      throw DoryARMVirtQualificationReceiptError.invalidField("gateInputs")
    }
    let expectation = gate.receipt
    guard receipt.bootAttempts == expectation.bootAttempts,
      receipt.consoleScriptStepCount == expectation.consoleScriptStepCount,
      receipt.completedConsoleScriptStepCount == expectation.consoleScriptStepCount,
      receipt.installerMediaTransitionCount == expectation.installerMediaTransitionCount,
      receipt.installerMediaAttachedForFinalBoot
        == expectation.installerMediaAttachedForFinalBoot,
      receipt.coldSnapshotActionCount == expectation.coldSnapshotActionCount,
      receipt.completedColdSnapshotActionCount == expectation.coldSnapshotActionCount
    else {
      throw DoryARMVirtQualificationReceiptError.invalidField("lifecycleReceipt")
    }
    try validateSnapshot(receipt, gate: gate)
    try validateTimings(receipt)
    guard isBounded(receipt.hostHardwareModel),
      isBounded(receipt.hostOperatingSystemVersion),
      isBounded(receipt.hostOperatingSystemBuild),
      isBounded(receipt.buildIdentifier),
      isSHA256(receipt.runnerSHA256),
      isSHA256(receipt.firmwareCodeSHA256),
      receipt.consoleByteCount > 0,
      receipt.consoleByteCount <= 1 << 20,
      receipt.variableStoreGeneration > 0,
      receipt.stopReason == "power-off"
    else {
      throw DoryARMVirtQualificationReceiptError.invalidField("runtimeResult")
    }
  }

  private static func validateSnapshot(
    _ receipt: DoryARMVirtQualificationReceipt,
    gate: DoryARMVirtCompatibilityGate
  ) throws {
    if gate.kind == .coldSnapshot {
      guard receipt.coldSnapshotABIIdentity == "dory.snapshot.armvirt.cold@1",
        receipt.coldSnapshotSystemDiskSHA256.map(isSHA256) == true,
        receipt.coldSnapshotVariableStoreGeneration.map({ $0 > 0 }) == true
      else {
        throw DoryARMVirtQualificationReceiptError.invalidField("coldSnapshot")
      }
    } else {
      guard receipt.coldSnapshotABIIdentity == nil,
        receipt.coldSnapshotSystemDiskSHA256 == nil,
        receipt.coldSnapshotVariableStoreGeneration == nil
      else {
        throw DoryARMVirtQualificationReceiptError.invalidField("unexpectedColdSnapshot")
      }
    }
  }

  private static func validateTimings(_ receipt: DoryARMVirtQualificationReceipt) throws {
    guard receipt.timingClockIdentity == DoryARMVirtQualificationReceipt.timingClockIdentity,
      receipt.bootDurationNanoseconds.count == receipt.bootAttempts
    else {
      throw DoryARMVirtQualificationReceiptError.invalidField("timingShape")
    }
    var totalBootNanoseconds: UInt64 = 0
    for duration in receipt.bootDurationNanoseconds {
      guard duration > 0 else {
        throw DoryARMVirtQualificationReceiptError.invalidField("bootDurationNanoseconds")
      }
      let addition = totalBootNanoseconds.addingReportingOverflow(duration)
      guard !addition.overflow else {
        throw DoryARMVirtQualificationReceiptError.invalidField("bootDurationNanoseconds")
      }
      totalBootNanoseconds = addition.partialValue
    }
    guard receipt.qualificationDurationNanoseconds >= totalBootNanoseconds else {
      throw DoryARMVirtQualificationReceiptError.invalidField(
        "qualificationDurationNanoseconds"
      )
    }
  }

  private static func validateJSONShape(_ data: Data) throws {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw DoryARMVirtQualificationReceiptError.invalidJSONShape
    }
    let keys = Set(object.keys)
    guard requiredKeys.isSubset(of: keys), keys.isSubset(of: allowedKeys) else {
      throw DoryARMVirtQualificationReceiptError.invalidJSONShape
    }
  }

  private static func isBounded(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 256
  }

  private static func isSHA256(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  private static let optionalKeys: Set<String> = [
    "guestFamily", "guestVersion", "guestBuild", "guestArchitecture",
    "compatibilityMatrixSHA256", "qualificationGateID", "installerMediaByteCount",
    "installerMediaSHA256", "consoleScriptSHA256", "consoleScriptStepCount",
    "completedConsoleScriptStepCount", "coldSnapshotABIIdentity",
    "coldSnapshotSystemDiskSHA256", "coldSnapshotVariableStoreGeneration", "gvproxySHA256",
  ]
  private static let requiredKeys: Set<String> = [
    "schemaVersion", "machineABIIdentity", "firmwareABIIdentity", "executionEngineIdentity",
    "cpuProfileIdentity", "deviceABIIdentity", "hostArchitecture", "hostHardwareModel",
    "hostOperatingSystemVersion", "hostOperatingSystemBuild", "guestVCPUCount", "runnerSHA256",
    "buildIdentifier", "firmwareCodeSHA256", "expectedConsoleText", "systemDiskByteCount",
    "memoryByteCount", "installerMediaTransitionCount", "installerMediaAttachedForFinalBoot",
    "coldSnapshotActionCount", "completedColdSnapshotActionCount", "consoleByteCount",
    "bootAttempts", "timingClockIdentity", "bootDurationNanoseconds",
    "qualificationDurationNanoseconds", "variableStoreGeneration", "stopReason",
  ]
  private static let allowedKeys = requiredKeys.union(optionalKeys)
}

public enum DoryARMVirtQualificationReceiptError: Error, Equatable, Sendable {
  case invalidJSONShape
  case unsupportedSchemaVersion(UInt32)
  case invalidField(String)
}
