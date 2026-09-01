import DoryPCQualification
import Foundation
import Testing

@Suite("DoryPC UEFI tier qualification")
struct DoryPCUEFITierQualificationTests {
  @Test("accepts identical machine-visible outcomes with tier-specific accounting")
  func acceptsEquivalentTiers() throws {
    let data = Dictionary(
      uniqueKeysWithValues: DoryPCQualificationTier.allCases.map { tier in
        (tier, receipt(tier: tier))
      })
    let qualification = try DoryPCUEFITierQualifier.qualify(receiptData: data)

    #expect(qualification.schema == "dory.pc-uefi-tier-equivalence@1")
    #expect(qualification.qualified)
    #expect(qualification.completedInstructions == 12)
    #expect(qualification.evidence.map(\.executionTier) == DoryPCQualificationTier.allCases)
    #expect(Set(qualification.evidence.map(\.sourceReceiptSHA256)).count == 3)
  }

  @Test("rejects divergent architectural state")
  func rejectsStateDivergence() throws {
    var data = Dictionary(
      uniqueKeysWithValues: DoryPCQualificationTier.allCases.map { tier in
        (tier, receipt(tier: tier))
      })
    data[.optimizingJIT] = receipt(
      tier: .optimizingJIT, stateSHA256: String(repeating: "b", count: 64))

    #expect(throws: DoryPCUEFITierQualificationError.mismatch("architecturalStateSHA256")) {
      try DoryPCUEFITierQualifier.qualify(receiptData: data)
    }
  }

  @Test("rejects a claimed JIT tier that never executes JIT code")
  func rejectsMissingTierExecution() throws {
    var data = Dictionary(
      uniqueKeysWithValues: DoryPCQualificationTier.allCases.map { tier in
        (tier, receipt(tier: tier))
      })
    data[.baselineJIT] = receipt(
      tier: .baselineJIT,
      interpreterInstructions: 12,
      baselineJITInstructions: 0
    )

    #expect(
      throws: DoryPCUEFITierQualificationError.invalidReceipt(.baselineJIT, "tierAccounting")
    ) {
      try DoryPCUEFITierQualifier.qualify(receiptData: data)
    }
  }

  private func receipt(
    tier: DoryPCQualificationTier,
    stateSHA256: String = String(repeating: "a", count: 64),
    interpreterInstructions: UInt64? = nil,
    baselineJITInstructions: UInt64? = nil
  ) -> Data {
    let accounting: (UInt64, UInt64, UInt64) =
      switch tier {
      case .interpreter: (12, 0, 0)
      case .baselineJIT: (2, 10, 0)
      case .optimizingJIT: (2, 0, 10)
      }
    let object: [String: Any] = [
      "executionTier": tier.rawValue,
      "completedInstructions": 12,
      "architecturalStateSHA256": stateSHA256,
      "stop": "poweredOff(instructionCount: 12)",
      "serialOutput": "DORY-PC-UEFI-BOOT\r\n",
      "serialMarkerExpected": "DORY-PC-UEFI-BOOT",
      "serialMarkerMatched": true,
      "bootProbe": true,
      "exceptionPolicy": "deliver",
      "firmwareABIIdentity": "dory.pc-firmware@1",
      "firmwareBuildIdentifier": "build-1",
      "firmwareCodeByteCount": 1024,
      "firmwareCodeSHA256": String(repeating: "1", count: 64),
      "machineABIIdentity": "DoryPC-v1",
      "sbomSHA256": String(repeating: "2", count: 64),
      "variableStoreTemplateByteCount": 512,
      "variableStoreTemplateSHA256": String(repeating: "3", count: 64),
      "runnerByteCount": 2048,
      "runnerSHA256": String(repeating: "4", count: 64),
      "initialRTCUnixSeconds": 0,
      "memoryBytes": 134_217_728,
      "processorCount": 1,
      "maximumInstructions": 300_000_000,
      "bootOrder": ["system-disk"],
      "persistentSystemDisk": "in-memory",
      "installerMedia": "none",
      "interpreterInstructions": interpreterInstructions ?? accounting.0,
      "baselineJITInstructions": baselineJITInstructions ?? accounting.1,
      "optimizingJITInstructions": accounting.2,
    ]
    return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }
}
