import Testing

@testable import DoryDBTX86

@Suite struct DoryX86InstructionFeaturePolicyTests {
  private let decoder = DoryX86Decoder()
  private let optionalLegacy: [(DoryX86Feature, [UInt8])] = [
    (.sse3, [0xF2, 0x0F, 0x12, 0x03]), // MOVDDUP [RBX]
    (.sse3, [0xF3, 0x0F, 0x12, 0x03]), // MOVSLDUP [RBX]
    (.sse3, [0xF3, 0x0F, 0x16, 0x03]), // MOVSHDUP [RBX]
    (.ssse3, [0x66, 0x0F, 0x38, 0x00, 0x03]), // PSHUFB
    (.ssse3, [0x66, 0x0F, 0x3A, 0x0F, 0x03, 2]), // PALIGNR
    (.sse41, [0x66, 0x0F, 0x38, 0x17, 0x03]), // PTEST
    (.sse41, [0x66, 0x0F, 0x38, 0x25, 0x03]), // PMOVSXDQ
    (.sse41, [0x66, 0x0F, 0x38, 0x35, 0x03]), // PMOVZXDQ
    (.sse41, [0x66, 0x0F, 0x38, 0x22, 0x03]), // PMOVSXBQ
    (.sse41, [0x66, 0x0F, 0x38, 0x29, 0x03]), // PCMPEQQ
    (.sse41, [0x66, 0x48, 0x0F, 0x3A, 0x22, 0x03, 0]), // PINSRQ
    (.sse42, [0x66, 0x0F, 0x3A, 0x63, 0x03, 0]), // PCMPISTRI
  ]

  @Test func legacyOptionalOperationsRequireTheirOwnAdvertisedFeature() throws {
    for (feature, bytes) in optionalLegacy {
      let decoded = try decoder.decode(bytes, at: 0x1000, mode: .long64)
      #expect(!DoryX86InstructionFeaturePolicy.permits(decoded, profile: .compatibleV1))
      #expect(DoryX86InstructionFeaturePolicy.permits(decoded, profile: profile(adding: [feature])))
      let unrelated: Set<DoryX86Feature> = [.sse3, .ssse3, .sse41, .sse42]
      #expect(!DoryX86InstructionFeaturePolicy.permits(decoded,
        profile: profile(adding: unrelated.subtracting([feature]))))
      #expect(!DoryX86InstructionFeaturePolicy.permits(decoded,
        profile: profile(adding: [feature], removing: [.sse2])))
    }
    // PMOVZXBQ is named by the shared operation type, but its encoding is not
    // implemented by the decoder. A profile opt-in must not make it executable.
    let undecoded: [UInt8] = [0x66, 0x0F, 0x38, 0x32, 0x03]
    #expect(throws: DoryX86DecodeError.self) {
      try decoder.decode(undecoded, at: 0x1000, mode: .long64)
    }
    try expectPreciseInvalidOpcode(undecoded, profile: .compatibleV1)
    try expectPreciseInvalidOpcode(undecoded, profile: profile(adding: [.sse41]))
    // Existing SSE half-moves and the newly corrected packed SSE2 conversion stay admitted.
    for bytes: [UInt8] in [[0x0F, 0x12, 0xC8], [0x0F, 0x16, 0xC8], [0xF3, 0x0F, 0xE6, 0xC8]] {
      #expect(DoryX86InstructionFeaturePolicy.permits(
        try decoder.decode(bytes, at: 0x1000, mode: .long64), profile: .compatibleV1))
    }
  }

  @Test func maskedOptionalInstructionsFaultBeforeAnyDataOperandAccess() throws {
    let vex: [[UInt8]] = [
      [0xC5, 0xF8, 0x10, 0x03], // VMOVUPS load
      [0xC5, 0xF8, 0x11, 0x03], // VMOVUPS store
      [0xC5, 0xFD, 0xEF, 0x03], // VPXOR YMM
      [0xC5, 0xF8, 0xAE, 0x1B], // VSTMXCSR
      [0xC5, 0xF8, 0x77],       // VZEROUPPER has no memory operand.
    ]
    for bytes in optionalLegacy.map(\.1) + vex {
      try expectPreciseInvalidOpcode(bytes, profile: .compatibleV1)
    }
  }

  @Test func fencesUseSSEForStoreAndSSE2ForLoadOrFullWithoutPrematureCallbacks() throws {
    for (modRM, feature): (UInt8, DoryX86Feature) in [(0xF8, .sse), (0xE8, .sse2), (0xF0, .sse2)] {
      let bytes: [UInt8] = [0x0F, 0xAE, modRM]
      let instruction = try decoder.decode(bytes, at: 0x1000, mode: .long64)
      let masked = profile(removing: [feature])
      #expect(!DoryX86InstructionFeaturePolicy.permits(instruction, profile: masked))
      try expectPreciseInvalidOpcode(bytes, profile: masked)
      let sseOnly = profile(removing: [.sse2])
      #expect(DoryX86InstructionFeaturePolicy.permits(instruction, profile: sseOnly) == (feature == .sse))
      let memory = FeaturePolicyOperandMemory(code: bytes)
      var state = try DoryX86ArchitecturalState(rip: 0x1000)
      #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64) == .retired(instruction))
      #expect(memory.synchronizations == 1 && memory.dataAccesses == 0)
      #expect(state.rip == 0x1003)
    }
  }

  @Test func exactVEXOpcodeSeparatesAVXFromAVX2AtBothVectorWidths() throws {
    let avx = profile(adding: [.xsave, .avx])
    let avx2 = profile(adding: [.xsave, .avx, .avx2])
    let vectors: [([UInt8], Bool)] = [
      ([0xC5, 0xFC, 0x57, 0xC8], false), // VXORPS YMM
      ([0xC5, 0xFD, 0x54, 0xC8], false), // VANDPD YMM: pp66 is not sufficient to imply AVX2.
      ([0xC5, 0xFD, 0x6F, 0xC8], false), // VMOVDQA YMM is AVX.
      ([0xC5, 0xF9, 0xEF, 0xC8], false), // VPXOR XMM
      ([0xC5, 0xFD, 0xEF, 0xC8], true),  // VPXOR YMM
      ([0xC5, 0xFD, 0x74, 0xC8], true),  // VPCMPEQB YMM
      ([0xC4, 0xE2, 0x79, 0x00, 0xC8], false), // VPSHUFB XMM
      ([0xC4, 0xE2, 0x7D, 0x00, 0xC8], true),  // VPSHUFB YMM
      ([0xC4, 0xE2, 0x79, 0x18, 0x03], false), // VBROADCASTSS memory
      ([0xC4, 0xE2, 0x79, 0x18, 0xC8], true),  // VBROADCASTSS register
      ([0xC4, 0xE2, 0x7D, 0x19, 0x03], false), // VBROADCASTSD memory
      ([0xC4, 0xE2, 0x7D, 0x19, 0xC8], true),  // VBROADCASTSD register
      ([0xC4, 0xE2, 0x7D, 0x1A, 0x03], false), // VBROADCASTF128
      ([0xC4, 0xE2, 0x7D, 0x5A, 0x03], true),  // VBROADCASTI128
    ]
    for (bytes, requiresAVX2) in vectors {
      let instruction = try decoder.decode(bytes, at: 0x1000, mode: .long64)
      #expect(!DoryX86InstructionFeaturePolicy.permits(instruction, profile: .compatibleV1))
      #expect(DoryX86InstructionFeaturePolicy.permits(instruction, profile: avx) == !requiresAVX2)
      #expect(DoryX86InstructionFeaturePolicy.permits(instruction, profile: avx2))
      #expect(!DoryX86InstructionFeaturePolicy.permits(instruction,
        profile: profile(adding: [.avx, .avx2], removing: [.xsave])))
    }
    // A real admitted register operation can execute only with the explicit synthetic profile.
    let bytes: [UInt8] = [0xC5, 0xFC, 0x57, 0xC0] // VXORPS YMM0,YMM0,YMM0
    let memory = FeaturePolicyOperandMemory(code: bytes)
    var state = try DoryX86ArchitecturalState(rip: 0x1000,
      control: .init(cr4: (1 << 9) | (1 << 18), xcr0: 7))
    state.floatingPoint.ymm[0] = try .init(bytes: .init(repeating: 0xA5, count: 32), expectedByteCount: 32)
    let instruction = try decoder.decode(bytes, at: state.rip, mode: .long64)
    #expect(DoryX86Interpreter(profile: avx).step(state: &state, memory: memory, mode: .long64) == .retired(instruction))
    #expect(state.floatingPoint.ymm[0].bytes == [UInt8](repeating: 0, count: 32))
  }

  @Test func bmi2AndMaskMovesNeverBecomeAVXCapabilities() throws {
    let all = profile(adding: Set(DoryX86Feature.allCases))
    for bytes: [UInt8] in [
      [0xC4, 0xE2, 0xF1, 0xF7, 0x03], // SHLX memory operand
      [0xC4, 0xE2, 0xF2, 0xF7, 0x03], // SARX memory operand
      [0xC4, 0xE2, 0xF3, 0xF7, 0x03], // SHRX memory operand
      [0xC5, 0xFB, 0x93, 0xC8],       // KMOVD, no modeled K-register state
    ] {
      let instruction = try decoder.decode(bytes, at: 0x1000, mode: .long64)
      #expect(!DoryX86InstructionFeaturePolicy.permits(instruction, profile: all))
      try expectPreciseInvalidOpcode(bytes, profile: all)
      try expectPreciseInvalidOpcode(bytes, profile: .compatibleV1)
    }
  }

  @Test func unqualifiedVEXAliasesRemainRejectedEvenWithEveryRepresentedFeature() throws {
    let all = profile(adding: Set(DoryX86Feature.allCases))
    for bytes: [UInt8] in [
      [0xC5, 0xFC, 0x77],       // VZEROALL cannot execute as VZEROUPPER.
      [0xC5, 0xF9, 0xE2, 0xC8], // VPSRAD cannot execute as a per-lane variable shift.
      [0xC5, 0xF9, 0x73, 0xD0, 1], // Packed immediate-shift operand roles remain uncorrected.
      [0xC5, 0xFA, 0x10, 0xC8], // VMOVSS cannot execute as full-width move.
      [0xC5, 0xF9, 0x10, 0x03], // VMOVUPD cannot acquire an alignment requirement.
      [0xC5, 0xFA, 0x6F, 0x03], // VMOVDQU cannot acquire an alignment requirement.
      [0xC4, 0xE2, 0x79, 0x78, 0xC8], // VPBROADCASTB cannot broadcast dwords.
      [0xC4, 0xE2, 0x7D, 0x5A, 0xC8], // VBROADCASTI128 requires memory, never an XMM source.
      [0xC5, 0xFB, 0x2C, 0xC8], // Scalar-to-integer conversion has reversed operand roles.
      [0xC5, 0xF8, 0xAE, 0x13], // VLDMXCSR reserved bits are not validated yet.
      [0xC5, 0xF9, 0xFA, 0xC8], // VPSUBD cannot execute as byte subtraction.
    ] {
      let instruction = try decoder.decode(bytes, at: 0x1000, mode: .long64)
      #expect(!DoryX86InstructionFeaturePolicy.permits(instruction, profile: all))
      try expectPreciseInvalidOpcode(bytes, profile: all)
    }
  }

  private func profile(
    adding: Set<DoryX86Feature> = [], removing: Set<DoryX86Feature> = []
  ) -> DoryX86CPUProfile {
    .init(identifier: "test-only.optional-instruction-policy",
      features: DoryX86CPUProfile.compatibleV1.features.union(adding).subtracting(removing),
      physicalAddressBits: 40, linearAddressBits: 48, virtualTSCFrequencyHz: 1_000_000_000)
  }

  private func expectPreciseInvalidOpcode(_ bytes: [UInt8], profile: DoryX86CPUProfile) throws {
    let memory = FeaturePolicyOperandMemory(code: bytes)
    var state = try DoryX86ArchitecturalState(registers: .init(rax: 0xAA55, rbx: 0x8000), rip: 0x1000,
      rflags: [.reservedOne, .carry, .overflow])
    state.floatingPoint.ymm[0] = try .init(bytes: .init(repeating: 0xA5, count: 32), expectedByteCount: 32)
    let initial = state
    let result = DoryX86Interpreter(profile: profile).step(state: &state, memory: memory, mode: .long64)
    #expect(result == .exception(.init(kind: .invalidOpcode, vector: 6, instructionPointer: 0x1000)))
    #expect(state == initial)
    #expect(memory.dataAccesses == 0)
    #expect(memory.synchronizations == 0)
  }
}

/// A data access would fault and is counted independently of instruction fetch. Each test owns
/// this serial observer, so a zero count proves masking happened before operand validation.
private final class FeaturePolicyOperandMemory: DoryX86Memory, @unchecked Sendable {
  let code: [UInt8]
  private(set) var dataAccesses = 0
  private(set) var synchronizations = 0
  init(code: [UInt8]) { self.code = code }

  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    guard address == 0x1000 else {
      throw DoryX86MemoryError.unmapped(address: address, byteCount: maximumCount, access: .instructionFetch)
    }
    return Array(code.prefix(maximumCount))
  }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    dataAccesses += 1
    throw DoryX86MemoryError.unmapped(address: address, byteCount: byteCount, access: .read)
  }

  func write(at address: UInt64, bytes: [UInt8]) throws {
    dataAccesses += 1
    throw DoryX86MemoryError.unmapped(address: address, byteCount: bytes.count, access: .write)
  }

  func synchronize() { synchronizations += 1 }
}
