import CryptoKit
import Foundation

public enum DoryPCQualificationTier: String, Codable, CaseIterable, Sendable {
  case interpreter
  case baselineJIT
  case optimizingJIT
}

public struct DoryPCUEFISmokeReceipt: Decodable, Sendable {
  public let executionTier: DoryPCQualificationTier
  public let completedInstructions: UInt64
  public let architecturalStateSHA256: String
  public let stop: String
  public let serialOutput: String
  public let serialMarkerExpected: String?
  public let serialMarkerMatched: Bool?
  public let bootProbe: Bool
  public let exceptionPolicy: String
  public let firmwareABIIdentity: String
  public let firmwareBuildIdentifier: String
  public let firmwareCodeByteCount: UInt64
  public let firmwareCodeSHA256: String
  public let machineABIIdentity: String
  public let sbomSHA256: String
  public let variableStoreTemplateByteCount: UInt64
  public let variableStoreTemplateSHA256: String
  public let runnerByteCount: UInt64
  public let runnerSHA256: String
  public let initialRTCUnixSeconds: UInt64
  public let memoryBytes: UInt64
  public let processorCount: Int
  public let maximumInstructions: UInt64
  public let bootOrder: [String]
  public let persistentSystemDisk: String
  public let installerMedia: String
  public let interpreterInstructions: UInt64
  public let baselineJITInstructions: UInt64
  public let optimizingJITInstructions: UInt64
}

public struct DoryPCUEFITierEvidence: Codable, Sendable, Equatable {
  public let executionTier: DoryPCQualificationTier
  public let sourceReceiptSHA256: String
  public let interpreterInstructions: UInt64
  public let baselineJITInstructions: UInt64
  public let optimizingJITInstructions: UInt64
}

public struct DoryPCUEFITierQualificationReceipt: Codable, Sendable, Equatable {
  public static let schemaIdentity = "dory.pc-uefi-tier-equivalence@1"

  public let schema: String
  public let qualified: Bool
  public let firmwareBuildIdentifier: String
  public let firmwareCodeSHA256: String
  public let firmwareABIIdentity: String
  public let machineABIIdentity: String
  public let sbomSHA256: String
  public let variableStoreTemplateSHA256: String
  public let runnerSHA256: String
  public let completedInstructions: UInt64
  public let architecturalStateSHA256: String
  public let serialOutputSHA256: String
  public let serialMarker: String
  public let evidence: [DoryPCUEFITierEvidence]
}

public enum DoryPCUEFITierQualificationError: Error, CustomStringConvertible, Equatable {
  case missingTier(DoryPCQualificationTier)
  case invalidReceipt(DoryPCQualificationTier, String)
  case mismatch(String)

  public var description: String {
    switch self {
    case .missingTier(let tier): "missing receipt for \(tier.rawValue)"
    case .invalidReceipt(let tier, let field):
      "invalid \(tier.rawValue) receipt field: \(field)"
    case .mismatch(let field): "execution tiers disagree on \(field)"
    }
  }
}

public enum DoryPCUEFITierQualifier {
  public static func qualify(
    receiptData: [DoryPCQualificationTier: Data]
  ) throws -> DoryPCUEFITierQualificationReceipt {
    let decoder = JSONDecoder()
    var decoded: [(DoryPCQualificationTier, Data, DoryPCUEFISmokeReceipt)] = []
    for tier in DoryPCQualificationTier.allCases {
      guard let data = receiptData[tier] else {
        throw DoryPCUEFITierQualificationError.missingTier(tier)
      }
      let receipt: DoryPCUEFISmokeReceipt
      do {
        receipt = try decoder.decode(DoryPCUEFISmokeReceipt.self, from: data)
      } catch {
        throw DoryPCUEFITierQualificationError.invalidReceipt(tier, "JSON: \(error)")
      }
      try validate(receipt, expectedTier: tier)
      decoded.append((tier, data, receipt))
    }

    let reference = decoded[0].2
    for (_, _, candidate) in decoded.dropFirst() {
      try requireEqual(
        candidate.firmwareBuildIdentifier, reference.firmwareBuildIdentifier,
        "firmwareBuildIdentifier")
      try requireEqual(
        candidate.firmwareCodeSHA256, reference.firmwareCodeSHA256, "firmwareCodeSHA256")
      try requireEqual(
        candidate.firmwareCodeByteCount, reference.firmwareCodeByteCount, "firmwareCodeByteCount")
      try requireEqual(
        candidate.firmwareABIIdentity, reference.firmwareABIIdentity, "firmwareABIIdentity")
      try requireEqual(
        candidate.machineABIIdentity, reference.machineABIIdentity, "machineABIIdentity")
      try requireEqual(candidate.sbomSHA256, reference.sbomSHA256, "sbomSHA256")
      try requireEqual(
        candidate.variableStoreTemplateSHA256, reference.variableStoreTemplateSHA256,
        "variableStoreTemplateSHA256")
      try requireEqual(
        candidate.variableStoreTemplateByteCount, reference.variableStoreTemplateByteCount,
        "variableStoreTemplateByteCount")
      try requireEqual(candidate.runnerSHA256, reference.runnerSHA256, "runnerSHA256")
      try requireEqual(candidate.runnerByteCount, reference.runnerByteCount, "runnerByteCount")
      try requireEqual(
        candidate.initialRTCUnixSeconds, reference.initialRTCUnixSeconds, "initialRTCUnixSeconds")
      try requireEqual(candidate.memoryBytes, reference.memoryBytes, "memoryBytes")
      try requireEqual(candidate.processorCount, reference.processorCount, "processorCount")
      try requireEqual(
        candidate.maximumInstructions, reference.maximumInstructions, "maximumInstructions")
      try requireEqual(candidate.bootOrder, reference.bootOrder, "bootOrder")
      try requireEqual(
        candidate.persistentSystemDisk, reference.persistentSystemDisk, "persistentSystemDisk")
      try requireEqual(candidate.installerMedia, reference.installerMedia, "installerMedia")
      try requireEqual(candidate.exceptionPolicy, reference.exceptionPolicy, "exceptionPolicy")
      try requireEqual(
        candidate.completedInstructions, reference.completedInstructions, "completedInstructions")
      try requireEqual(candidate.stop, reference.stop, "stop")
      try requireEqual(
        candidate.architecturalStateSHA256, reference.architecturalStateSHA256,
        "architecturalStateSHA256")
      try requireEqual(candidate.serialOutput, reference.serialOutput, "serialOutput")
      try requireEqual(
        candidate.serialMarkerExpected, reference.serialMarkerExpected, "serialMarkerExpected")
    }

    return DoryPCUEFITierQualificationReceipt(
      schema: DoryPCUEFITierQualificationReceipt.schemaIdentity,
      qualified: true,
      firmwareBuildIdentifier: reference.firmwareBuildIdentifier,
      firmwareCodeSHA256: reference.firmwareCodeSHA256,
      firmwareABIIdentity: reference.firmwareABIIdentity,
      machineABIIdentity: reference.machineABIIdentity,
      sbomSHA256: reference.sbomSHA256,
      variableStoreTemplateSHA256: reference.variableStoreTemplateSHA256,
      runnerSHA256: reference.runnerSHA256,
      completedInstructions: reference.completedInstructions,
      architecturalStateSHA256: reference.architecturalStateSHA256,
      serialOutputSHA256: sha256(Data(reference.serialOutput.utf8)),
      serialMarker: reference.serialMarkerExpected!,
      evidence: decoded.map { tier, data, receipt in
        DoryPCUEFITierEvidence(
          executionTier: tier,
          sourceReceiptSHA256: sha256(data),
          interpreterInstructions: receipt.interpreterInstructions,
          baselineJITInstructions: receipt.baselineJITInstructions,
          optimizingJITInstructions: receipt.optimizingJITInstructions
        )
      }
    )
  }

  private static func validate(
    _ receipt: DoryPCUEFISmokeReceipt,
    expectedTier: DoryPCQualificationTier
  ) throws {
    guard receipt.executionTier == expectedTier else {
      throw DoryPCUEFITierQualificationError.invalidReceipt(expectedTier, "executionTier")
    }
    guard receipt.bootProbe else {
      throw DoryPCUEFITierQualificationError.invalidReceipt(expectedTier, "bootProbe")
    }
    guard let marker = receipt.serialMarkerExpected, !marker.isEmpty,
      receipt.serialMarkerMatched == true, receipt.serialOutput.contains(marker)
    else {
      throw DoryPCUEFITierQualificationError.invalidReceipt(expectedTier, "serialMarker")
    }
    guard receipt.completedInstructions > 0,
      receipt.completedInstructions <= receipt.maximumInstructions,
      receipt.stop == "poweredOff(instructionCount: \(receipt.completedInstructions))"
    else {
      throw DoryPCUEFITierQualificationError.invalidReceipt(expectedTier, "stop")
    }
    guard receipt.exceptionPolicy == "deliver" else {
      throw DoryPCUEFITierQualificationError.invalidReceipt(expectedTier, "exceptionPolicy")
    }
    guard receipt.initialRTCUnixSeconds == 0 else {
      throw DoryPCUEFITierQualificationError.invalidReceipt(expectedTier, "initialRTCUnixSeconds")
    }
    guard receipt.persistentSystemDisk == "in-memory", receipt.installerMedia == "none",
      receipt.bootOrder == ["system-disk"]
    else {
      throw DoryPCUEFITierQualificationError.invalidReceipt(expectedTier, "bootMedia")
    }
    guard
      [
        receipt.architecturalStateSHA256,
        receipt.firmwareCodeSHA256,
        receipt.sbomSHA256,
        receipt.variableStoreTemplateSHA256,
        receipt.runnerSHA256,
      ].allSatisfy(isSHA256)
    else {
      throw DoryPCUEFITierQualificationError.invalidReceipt(expectedTier, "SHA256")
    }
    let (interpreterAndBaseline, firstOverflow) = receipt.interpreterInstructions
      .addingReportingOverflow(receipt.baselineJITInstructions)
    let (retired, secondOverflow) = interpreterAndBaseline.addingReportingOverflow(
      receipt.optimizingJITInstructions)
    guard !firstOverflow, !secondOverflow, retired == receipt.completedInstructions else {
      throw DoryPCUEFITierQualificationError.invalidReceipt(expectedTier, "instructionAccounting")
    }
    switch expectedTier {
    case .interpreter:
      guard receipt.interpreterInstructions > 0, receipt.baselineJITInstructions == 0,
        receipt.optimizingJITInstructions == 0
      else {
        throw DoryPCUEFITierQualificationError.invalidReceipt(expectedTier, "tierAccounting")
      }
    case .baselineJIT:
      guard receipt.baselineJITInstructions > 0, receipt.optimizingJITInstructions == 0 else {
        throw DoryPCUEFITierQualificationError.invalidReceipt(expectedTier, "tierAccounting")
      }
    case .optimizingJIT:
      guard receipt.optimizingJITInstructions > 0 else {
        throw DoryPCUEFITierQualificationError.invalidReceipt(expectedTier, "tierAccounting")
      }
    }
  }

  private static func requireEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ field: String) throws {
    guard lhs == rhs else { throw DoryPCUEFITierQualificationError.mismatch(field) }
  }

  private static func isSHA256(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
