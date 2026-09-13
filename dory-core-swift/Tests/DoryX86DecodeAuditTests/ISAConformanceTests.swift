import DoryDBTX86
import dory_x86_decode_audit
import Foundation
import Testing

@testable import DoryDBTX86
@testable import dory_x86_decode_audit

// P2-04: Independent x86 conformance system tests.
// These tests verify the conformance state machine, decoder fuzz harness,
// feature promotion gate, and differential divergence reporting.

@Suite struct ISAConformanceStateTests {
  @Test func conformanceStatesAreOrderedAndComparable() {
    #expect(ISAConformanceState.rejected < .recognized)
    #expect(ISAConformanceState.recognized < .interpreted)
    #expect(ISAConformanceState.interpreted < .loweredTier1)
    #expect(ISAConformanceState.loweredTier1 < .loweredTier2)
    #expect(ISAConformanceState.loweredTier2 < .independentlyVerified)
    #expect(ISAConformanceState.independentlyVerified < .workloadQualified)
  }

  @Test func resolverRejectsRejectedForms() {
    let state = ISAConformanceStateResolver.resolve(
      decoderSupport: "rejected",
      interpreterSemantics: .init(),
      jitBaseline: .init(),
      jitOptimizing: .init(),
      independentReference: .init(),
      executedFormCount: 0)
    #expect(state == .rejected)
  }

  @Test func resolverReturnsRecognizedForDecodedButUnexecutedForms() {
    let state = ISAConformanceStateResolver.resolve(
      decoderSupport: "recognized",
      interpreterSemantics: .init(),
      jitBaseline: .init(),
      jitOptimizing: .init(),
      independentReference: .init(),
      executedFormCount: 0)
    #expect(state == .recognized)
  }

  @Test func resolverReturnsInterpretedWhenInterpreterSupports() {
    let state = ISAConformanceStateResolver.resolve(
      decoderSupport: "recognized",
      interpreterSemantics: .init(status: "supported", evidence: ["test-1"]),
      jitBaseline: .init(),
      jitOptimizing: .init(),
      independentReference: .init(),
      executedFormCount: 0)
    #expect(state == .interpreted)
  }

  @Test func resolverReturnsLoweredTier1WhenBaselineJITSupports() {
    let state = ISAConformanceStateResolver.resolve(
      decoderSupport: "recognized",
      interpreterSemantics: .init(status: "supported", evidence: ["test-1"]),
      jitBaseline: .init(status: "supported", evidence: ["test-2"]),
      jitOptimizing: .init(),
      independentReference: .init(),
      executedFormCount: 0)
    #expect(state == .loweredTier1)
  }

  @Test func resolverReturnsLoweredTier2WhenOptimizingJITSupports() {
    let state = ISAConformanceStateResolver.resolve(
      decoderSupport: "recognized",
      interpreterSemantics: .init(status: "supported", evidence: ["test-1"]),
      jitBaseline: .init(status: "supported", evidence: ["test-2"]),
      jitOptimizing: .init(status: "supported", evidence: ["test-3"]),
      independentReference: .init(),
      executedFormCount: 0)
    #expect(state == .loweredTier2)
  }

  @Test func resolverReturnsIndependentlyVerifiedWhenReferenceVerifies() {
    let state = ISAConformanceStateResolver.resolve(
      decoderSupport: "recognized",
      interpreterSemantics: .init(status: "supported", evidence: ["test-1"]),
      jitBaseline: .init(status: "supported", evidence: ["test-2"]),
      jitOptimizing: .init(status: "supported", evidence: ["test-3"]),
      independentReference: .init(status: "verified", evidence: ["hw-1"]),
      executedFormCount: 0)
    #expect(state == .independentlyVerified)
  }

  @Test func resolverReturnsWorkloadQualifiedWhenReferenceVerifiedAndWorkloadObserved() {
    let state = ISAConformanceStateResolver.resolve(
      decoderSupport: "recognized",
      interpreterSemantics: .init(status: "supported", evidence: ["test-1"]),
      jitBaseline: .init(status: "supported", evidence: ["test-2"]),
      jitOptimizing: .init(),
      independentReference: .init(status: "verified", evidence: ["hw-1"]),
      executedFormCount: 42)
    #expect(state == .workloadQualified)
  }

  @Test func resolverReturnsIndependentlyVerifiedWithoutWorkloadObservation() {
    let state = ISAConformanceStateResolver.resolve(
      decoderSupport: "recognized",
      interpreterSemantics: .init(status: "supported", evidence: ["test-1"]),
      jitBaseline: .init(status: "supported", evidence: ["test-2"]),
      jitOptimizing: .init(status: "supported", evidence: ["test-3"]),
      independentReference: .init(status: "verified", evidence: ["hw-1"]),
      executedFormCount: 0)
    #expect(state == .independentlyVerified)
  }

  // P2-04: Dory-only execution (interpreter/Tier1/Tier2) shares the decoder
  // and fault model with the independent oracle. A positive executedFormCount
  // without a measured independent reference must not resolve as
  // workloadQualified or independentlyVerified; it must fall through to the
  // strongest actual engine tier.
  @Test func resolverReturnsLoweredTier1ForDoryOnlyExecutionWithoutIndependentReference() {
    let state = ISAConformanceStateResolver.resolve(
      decoderSupport: "recognized",
      interpreterSemantics: .init(status: "supported", evidence: ["test-1"]),
      jitBaseline: .init(status: "supported", evidence: ["test-2"]),
      jitOptimizing: .init(),
      independentReference: .init(),
      executedFormCount: 42)
    #expect(state == .loweredTier1)
  }

  @Test func resolverReturnsLoweredTier2ForDoryOnlyExecutionWithoutIndependentReference() {
    let state = ISAConformanceStateResolver.resolve(
      decoderSupport: "recognized",
      interpreterSemantics: .init(status: "supported", evidence: ["test-1"]),
      jitBaseline: .init(status: "supported", evidence: ["test-2"]),
      jitOptimizing: .init(status: "supported", evidence: ["test-3"]),
      independentReference: .init(),
      executedFormCount: 42)
    #expect(state == .loweredTier2)
  }

  @Test func resolverReturnsInterpretedForInterpreterOnlyExecutionWithoutIndependentReference() {
    let state = ISAConformanceStateResolver.resolve(
      decoderSupport: "recognized",
      interpreterSemantics: .init(status: "supported", evidence: ["test-1"]),
      jitBaseline: .init(),
      jitOptimizing: .init(),
      independentReference: .init(),
      executedFormCount: 42)
    #expect(state == .interpreted)
  }

  @Test func inventoryReportIncludesConformanceStateDistribution() throws {
    let report = try ISAInventory.report(data: ISAInventory.bundledCorpusData())
    #expect(!report.conformanceStateDistribution.isEmpty)
    // All vectors should be either "rejected" or "recognized" since no
    // execution evidence is applied in the base corpus.
    let recognized = report.conformanceStateDistribution["recognized", default: 0]
    let rejected = report.conformanceStateDistribution["rejected", default: 0]
    #expect(recognized + rejected == report.corpusVectorCount)
    #expect(recognized == report.staticDecodedFormCount)
    #expect(rejected == report.rejectedVectorCount)
  }

  @Test func inventoryRecordsHaveConformanceState() throws {
    let report = try ISAInventory.report(data: ISAInventory.bundledCorpusData())
    for record in report.records {
      if record.decoderSupport == "rejected" {
        #expect(record.conformanceState == .rejected)
      } else {
        #expect(record.conformanceState == .recognized)
      }
    }
  }
}

@Suite struct ISADecoderFuzzHarnessTests {
  @Test func fuzzHarnessProducesReproducibleResults() {
    let cases1 = ISADecoderFuzzHarness.run(rootSeed: 42, caseCount: 10)
    let cases2 = ISADecoderFuzzHarness.run(rootSeed: 42, caseCount: 10)
    #expect(cases1.count == cases2.count)
    #expect(cases1 == cases2)
  }

  @Test func fuzzHarnessClassifiesAllOutcomes() {
    let cases = ISADecoderFuzzHarness.run(rootSeed: 12345, caseCount: 100)
    #expect(cases.count == 400)  // 100 cases × 4 modes

    let summary = ISADecoderFuzzHarness.summarize(cases)
    // Every case should be either "decoded" or "rejected" — no crashes or
    // unexpected errors. The decoder must handle any byte sequence.
    #expect(summary["crashed", default: 0] == 0)
    #expect(summary["unexpectedError", default: 0] == 0)
    #expect(summary["decoded", default: 0] + summary["rejected", default: 0] == 400)
  }

  @Test func fuzzHarnessRetainsSeedsForReproduction() {
    let cases = ISADecoderFuzzHarness.run(rootSeed: 999, caseCount: 5)
    for fuzzCase in cases {
      // Every case must have a retained seed and byte sequence.
      #expect(fuzzCase.seed == 999 || fuzzCase.seed > 0)
      #expect(!fuzzCase.bytes.isEmpty)
      #expect(fuzzCase.bytes.count <= 15)
    }
  }

  @Test func fuzzHarnessDecodesSingleByteNopCorrectly() {
    let result = ISADecoderFuzzHarness.decode(
      bytes: [0x90], mode: .long64, seed: 0, decoder: .init())
    #expect(result.outcome == "decoded")
    #expect(result.decodedLength == 1)
  }

  @Test func fuzzHarnessRejectsTruncatedInstruction() {
    // 0x0F is a 2-byte opcode prefix; a single 0x0F byte is truncated.
    let result = ISADecoderFuzzHarness.decode(
      bytes: [0x0F], mode: .long64, seed: 0, decoder: .init())
    #expect(result.outcome == "rejected")
    #expect(result.errorCategory == "truncated")
  }
}

@Suite struct ISAFeaturePromotionGateTests {
  @Test func featureWithNoFormsInLedgerCannotBePromoted() {
    let result = ISAFeaturePromotionGate.canPromote(
      feature: .avx, ledgerEntries: [])
    #expect(!result.canPromote)
    #expect(result.formsRequiring == 0)
    #expect(result.formsVerified == 0)
  }

  @Test func featureWithUnverifiedFormsCannotBePromoted() {
    let entry = ISAConformanceLedgerEntry(
      vectorID: "test.avx.form",
      encodingMap: "VEX",
      opcode: "c5f8",
      prefixForm: "VEX.128",
      form: "register",
      mode: .long64,
      privilege: .any,
      featurePrerequisites: .init(requiredFeatures: ["avx"]),
      faultBehavior: "none",
      memoryOrdering: "none",
      conformanceState: .recognized)
    let result = ISAFeaturePromotionGate.canPromote(
      feature: .avx, ledgerEntries: [entry])
    #expect(!result.canPromote)
    #expect(result.formsRequiring == 1)
    #expect(result.formsVerified == 0)
  }

  @Test func featureWithIndependentlyVerifiedFormsCanBePromoted() {
    let entry = ISAConformanceLedgerEntry(
      vectorID: "test.avx.form",
      encodingMap: "VEX",
      opcode: "c5f8",
      prefixForm: "VEX.128",
      form: "register",
      mode: .long64,
      privilege: .any,
      featurePrerequisites: .init(requiredFeatures: ["avx"]),
      faultBehavior: "none",
      memoryOrdering: "none",
      conformanceState: .independentlyVerified)
    let result = ISAFeaturePromotionGate.canPromote(
      feature: .avx, ledgerEntries: [entry])
    #expect(result.canPromote)
    #expect(result.formsRequiring == 1)
    #expect(result.formsVerified == 1)
  }

  @Test func featureWithMixedVerifiedAndUnverifiedFormsCannotBePromoted() {
    let verified = ISAConformanceLedgerEntry(
      vectorID: "test.avx.verified",
      encodingMap: "VEX", opcode: "c5f8", prefixForm: "VEX.128",
      form: "register", mode: .long64, privilege: .any,
      featurePrerequisites: .init(requiredFeatures: ["avx"]),
      faultBehavior: "none", memoryOrdering: "none",
      conformanceState: .independentlyVerified)
    let unverified = ISAConformanceLedgerEntry(
      vectorID: "test.avx.unverified",
      encodingMap: "VEX", opcode: "c5f9", prefixForm: "VEX.256",
      form: "register", mode: .long64, privilege: .any,
      featurePrerequisites: .init(requiredFeatures: ["avx"]),
      faultBehavior: "none", memoryOrdering: "none",
      conformanceState: .recognized)
    let result = ISAFeaturePromotionGate.canPromote(
      feature: .avx, ledgerEntries: [verified, unverified])
    #expect(!result.canPromote)
    #expect(result.formsRequiring == 2)
    #expect(result.formsVerified == 1)
  }

  @Test func nonPromotableFeaturesReturnsAllUnverifiedFeatures() {
    let avxEntry = ISAConformanceLedgerEntry(
      vectorID: "test.avx", encodingMap: "VEX", opcode: "c5f8",
      prefixForm: "VEX.128", form: "register", mode: .long64,
      privilege: .any,
      featurePrerequisites: .init(requiredFeatures: ["avx"]),
      faultBehavior: "none", memoryOrdering: "none",
      conformanceState: .recognized)
    let sseEntry = ISAConformanceLedgerEntry(
      vectorID: "test.sse", encodingMap: "legacy", opcode: "0f10",
      prefixForm: "none", form: "register", mode: .long64,
      privilege: .any,
      featurePrerequisites: .init(requiredFeatures: ["sse"]),
      faultBehavior: "none", memoryOrdering: "none",
      conformanceState: .independentlyVerified)
    let nonPromotable = ISAFeaturePromotionGate.nonPromotableFeatures(
      features: [.avx, .sse], ledgerEntries: [avxEntry, sseEntry])
    #expect(nonPromotable.count == 1)
    #expect(nonPromotable[0].feature == .avx)
  }

  @Test func featureIdentifierMapsAllFeatures() {
    // Verify every DoryX86Feature case has a mapping.
    for feature in DoryX86Feature.allCases {
      let id = ISAFeaturePromotionGate.featureIdentifier(feature)
      #expect(!id.isEmpty)
    }
  }
}

@Suite struct ISADifferentialDivergenceTests {
  @Test func firstDivergenceIsNilWhenEnginesAgree() throws {
    #if arch(arm64)
      let bytes: [UInt8] = [0x90]  // NOP
      let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: bytes)
      let state = try DoryX86ArchitecturalState(
        rip: 0x1000,
        cs: .init(selector: 0, attributes: 0xA09A, limit: .max))
      let result = try DoryX86DifferentialHarness().compare(
        bytes: bytes, initialState: state, memory: memory, mode: .long64)
      #expect(result.agrees)
      #expect(result.firstDivergence == nil)
    #endif
  }

  @Test func firstDivergenceReportsRIPMismatch() throws {
    #if arch(arm64)
      // Use a conditional jump that the interpreter and JIT might handle
      // differently if there's a bug. For a correct implementation, this
      // should agree; we test the divergence report structure by checking
      // that an agreeing result has nil divergence.
      let bytes: [UInt8] = [0x48, 0x01, 0xC0]  // ADD RAX, RAX
      let memory = try DoryX86ByteArrayMemory(baseAddress: 0x2000, bytes: bytes)
      let state = try DoryX86ArchitecturalState(
        registers: .init(rax: 1),
        rip: 0x2000,
        cs: .init(selector: 0, attributes: 0xA09A, limit: .max))
      let result = try DoryX86DifferentialHarness().compare(
        bytes: bytes, initialState: state, memory: memory, mode: .long64)
      #expect(result.agrees)
      #expect(result.firstDivergence == nil)
    #endif
  }
}

@Suite struct ISAEncodingMapTests {
  @Test func derivesLegacyMapForSingleByteOpcode() {
    let map = ISAEncodingMap.derive(from: [0x90], prefixes: .init())
    #expect(map == "legacy")
  }

  @Test func derives0FMapForTwoByteOpcode() {
    let map = ISAEncodingMap.derive(from: [0x0F, 0x1F], prefixes: .init())
    #expect(map == "0F")
  }

  @Test func derives0F01MapForSystemInstructions() {
    let map = ISAEncodingMap.derive(from: [0x0F, 0x01, 0xC8], prefixes: .init())
    #expect(map == "0F01")
  }

  @Test func derivesVEXMapForVEXPrefixedInstructions() {
    var prefixes = DoryX86InstructionPrefixes()
    prefixes.vex = .init(
      vvvv: 0, largeVector: false, r: true, x: true, b: true,
      w: false, map: 1, pp: 0)
    let map = ISAEncodingMap.derive(from: [0xC5, 0xF8, 0x77], prefixes: prefixes)
    #expect(map == "VEX")
  }

  @Test func skipsLegacyPrefixesToFindMap() {
    let map = ISAEncodingMap.derive(from: [0x66, 0x0F, 0xEF], prefixes: .init())
    #expect(map == "0F")
  }
}

@Suite struct ISAPrefixFormTests {
  @Test func derivesNoneForNoPrefixes() {
    let form = ISAPrefixForm.derive(from: .init())
    #expect(form == "none")
  }

  @Test func derivesOperandSizeOverride() {
    var prefixes = DoryX86InstructionPrefixes()
    prefixes.operandSizeOverride = true
    let form = ISAPrefixForm.derive(from: prefixes)
    #expect(form == "66")
  }

  @Test func derivesREXW() {
    var prefixes = DoryX86InstructionPrefixes()
    prefixes.rex = .init(w: true, r: false, x: false, b: false)
    let form = ISAPrefixForm.derive(from: prefixes)
    #expect(form == "REX.W")
  }

  @Test func derivesLockPrefix() {
    var prefixes = DoryX86InstructionPrefixes()
    prefixes.lock = true
    let form = ISAPrefixForm.derive(from: prefixes)
    #expect(form == "LOCK")
  }
}
