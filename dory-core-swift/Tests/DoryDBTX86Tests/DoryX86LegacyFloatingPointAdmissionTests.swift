import Testing

@testable import DoryDBTX86

// Intel SDM 092 Vol. 3A Tables 2-2/15-1, Vol. 2A FISTTP/FCMOVcc/FCOMI/
// FNOP/FXSAVE/FXRSTOR and Vol. 2D WAIT. These tests qualify admission only,
// not pending #MF delivery, numeric results, environment layout or MMX tags.
@Suite struct DoryX86LegacyFloatingPointAdmissionTests {
  private let x87: [[UInt8]] = [
    [0xDB, 0xE3], [0xDB, 0xE2], [0xDF, 0xE0], // FNINIT, FNCLEX, FNSTSW AX
    [0xD9, 0x2B], [0xD9, 0x3B], [0xDD, 0x3B], // FLDCW, FNSTCW, FNSTSW m16
    [0xD9, 0x03], [0xD9, 0x13], [0xD9, 0xC9], // FLD, FST, FXCH
    [0xD8, 0xC1], [0xD8, 0xD1], [0xD9, 0xE8], // FADD, FCOM, FLD1
    [0xD9, 0x23], [0xD9, 0x33], // FLDENV, FNSTENV
    [0xDF, 0x23], [0xDF, 0x33], // FBLD, FBSTP
    [0xDD, 0xD1], [0xDD, 0xC1], [0xDA, 0xC1], // FST ST1, FFREE, FCMOVB
    [0xD9, 0xD0], [0x66, 0xD9, 0xD0], // FNOP, operand-size-prefixed FNOP
    [0xDB, 0x0B], [0xDD, 0x0B], [0xDF, 0x0B], // FISTTP 32/64/16
    [0xDB, 0xF1], [0xDF, 0xE9], // FCOMI, FUCOMIP
  ]
  private let mmx: [[UInt8]] = [
    [0x0F, 0x6F, 0x03], [0x0F, 0x7F, 0x03], // MOVQ load/store
    [0x0F, 0x6E, 0x03], [0x0F, 0x7E, 0x03], // MOVD load/store
    [0x0F, 0xEF, 0xC1], [0x0F, 0xFC, 0xC1], // PXOR, PADDB
    [0x0F, 0x71, 0xD0, 1], [0x0F, 0xD1, 0xC1], // PSRLW immediate/register
    [0x0F, 0x60, 0xC1], [0x0F, 0x63, 0xC1], // PUNPCKLBW, PACKSSWB
    [0x0F, 0x77], // EMMS
    [0x0F, 0xC4, 0xC0, 1], [0x0F, 0xC5, 0xC0, 1], [0x0F, 0xD7, 0xC0],
    [0x0F, 0xE0, 0xC1], [0x0F, 0xD4, 0xC1], // SSE PAVGB, SSE2 PADDQ using MMX
  ]

  @Test func x87IncludingNonWaitingFormsChecksEMOrTSBeforeOperandsInEveryMode() throws {
    for mode in modes {
      for bits: UInt64 in 0..<8 where bits & 6 != 0 { // MP, EM, TS in their CR0 order.
        for bytes in x87 {
          var state = try state(mode: mode, cr0: 0x10 | (bits << 1))
          try expectFault(bytes, state: &state, mode: mode, kind: .deviceNotAvailable)
        }
      }
    }
  }

  @Test func mmxEMHasUDPriorityOverTSAndMPDoesNotGateNM() throws {
    for mode in modes {
      for bits: UInt64 in 0..<8 where bits & 6 != 0 {
        for bytes in mmx {
          var state = try state(mode: mode, cr0: 0x10 | (bits << 1))
          try expectFault(bytes, state: &state, mode: mode,
            kind: bits & 2 != 0 ? .invalidOpcode : .deviceNotAvailable)
        }
      }
    }
  }

  @Test func waitChecksOnlyMPAndTSIncludingWhenX87IsEmulated() throws {
    for mode in modes {
      for bits: UInt64 in 0..<8 {
        var state = try state(mode: mode, cr0: 0x10 | (bits << 1))
        let selected = profile(removing: [.x87])
        if bits & 5 == 5 {
          try expectFault([0x9B], state: &state, mode: mode, kind: .deviceNotAvailable, profile: selected)
        } else {
          let before = state
          let memory = AdmissionMemory(code: [0x9B])
          let decoded = try DoryX86Decoder().decode([0x9B], at: state.rip, mode: mode)
          #expect(DoryX86Interpreter(profile: selected).step(state: &state, memory: memory, mode: mode)
            == .retired(decoded))
          #expect(state.rip == before.rip + 1 && state.registers == before.registers)
          #expect(state.control == before.control && memory.dataAccesses == 0)
        }
      }
    }
  }

  @Test func absentBaseAndInstructionFeaturesFaultBeforeTaskStateOrOperands() throws {
    for bytes in x87 {
      var state = try state(cr0: 0x1F)
      try expectFault(bytes, state: &state, kind: .invalidOpcode, profile: profile(removing: [.x87]))
    }
    for bytes in mmx {
      var state = try state(cr0: 0x1B)
      try expectFault(bytes, state: &state, kind: .invalidOpcode, profile: profile(removing: [.mmx]))
    }
    let extensionForms: [(DoryX86Feature, [UInt8])] = [
      (.sse3, [0xDB, 0x0B]), (.sse3, [0xDD, 0x0B]), (.sse3, [0xDF, 0x0B]),
      (.cmov, [0xDA, 0xC1]), (.cmov, [0xDB, 0xC1]),
      (.cmov, [0xDB, 0xF1]), (.cmov, [0xDB, 0xE9]),
      (.cmov, [0xDF, 0xF1]), (.cmov, [0xDF, 0xE9]),
      (.sse, [0x0F, 0xE0, 0xC1]), (.sse, [0x0F, 0xC5, 0xC0, 1]),
      (.sse2, [0x0F, 0xD4, 0xC1]),
      (.fxsave, [0x0F, 0xAE, 0x03]), (.fxsave, [0x0F, 0xAE, 0x0B]),
    ]
    for (feature, bytes) in extensionForms {
      var state = try state(cr0: 0x1B)
      try expectFault(bytes, state: &state, kind: .invalidOpcode, profile: profile(removing: [feature]))
    }
  }

  @Test func fxTransfersCheckEMOrTSButIgnoreMPAndOSFXSRForAdmission() throws {
    for bytes: [UInt8] in [[0x0F, 0xAE, 0x03], [0x0F, 0xAE, 0x0B]] {
      for mode in modes {
        for bits: UInt64 in 0..<8 where bits & 6 != 0 {
          var state = try state(mode: mode, cr0: 0x10 | (bits << 1))
          try expectFault(bytes, state: &state, mode: mode, kind: .deviceNotAvailable)
        }
      }
      for mp: UInt64 in 0..<2 {
        var state = try state(cr0: 0x10 | (mp << 1))
        try expectDataFault(bytes, state: &state, write: bytes[2] == 3)
      }
    }
  }

  @Test func enabledX87AndMMXReachTheirOwnDataFaultWithoutSSEControlState() throws {
    for bytes: [UInt8] in [[0xD9, 0x03], [0xD9, 0x3B], [0xDB, 0x0B],
      [0x0F, 0x6F, 0x03], [0x0F, 0x7F, 0x03]] {
      var state = try state(cr0: 0x13) // MP=1, EM=TS=0, CR4/XCR0 SSE state disabled.
      try expectDataFault(bytes, state: &state, write: bytes == [0xD9, 0x3B]
        || bytes == [0xDB, 0x0B] || bytes == [0x0F, 0x7F, 0x03])
    }
    for bytes: [UInt8] in [[0xD9, 0xD0], [0x0F, 0x77]] {
      var state = try state()
      let memory = AdmissionMemory(code: bytes)
      let decoded = try DoryX86Decoder().decode(bytes, at: state.rip, mode: .long64)
      #expect(DoryX86Interpreter(profile: profile()).step(state: &state, memory: memory, mode: .long64)
        == .retired(decoded))
      #expect(memory.dataAccesses == 0)
    }
  }

  @Test func fetchFaultsPrecedeFeatureChecksAndFNOPBytesInsideIntegerNOPAreNotClassified() throws {
    for bytes in [[UInt8](arrayLiteral: 0xD9, 0xD0), [0x0F, 0x77]] {
      var state = try state(cr0: 0x1F)
      let before = state
      let memory = AdmissionMemory(code: bytes, failFetch: true)
      #expect(DoryX86Interpreter(profile: profile(removing: [.x87, .mmx])).step(
        state: &state, memory: memory, mode: .long64) == .exception(.init(kind: .pageFault,
          vector: 14, errorCode: 0x14, instructionPointer: 0x1000, linearAddress: 0x1000)))
      var expected = before
      expected.control.cr2 = 0x1000
      #expect(state == expected && memory.dataAccesses == 0)
    }
    for bytes: [UInt8] in [[0x90], [0x0F, 0x1F, 0x80, 0xD9, 0xD0, 0, 0]] {
      let instruction = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: .long64)
      #expect(!DoryX86LegacyFloatingPointPolicy.isX87NoOperation(instruction))
      var state = try state(cr0: 0x1F)
      let memory = AdmissionMemory(code: bytes)
      #expect(DoryX86Interpreter(profile: profile(removing: [.x87, .mmx])).step(
        state: &state, memory: memory, mode: .long64) == .retired(instruction))
      #expect(memory.dataAccesses == 0)
    }
  }

  @Test func FNOPIsAnExactNativeFallbackBoundaryWithoutPrefixReplay() throws {
    let fnop: [UInt8] = [0x66, 0xD9, 0xD0]
    let code: [UInt8] = [0x48, 0xFF, 0xC1] + fnop + [0x48, 0xFF, 0xC2]
    let translator = DoryX86IRTranslator()
    let prefix = try translator.translate(code, at: 0x1000, mode: .long64)
    #expect(prefix.guestInstructionCount == 1 && prefix.guestByteCount == 3)
    #expect(prefix.terminator == .next(0x1003))
    let boundary = try translator.translate(fnop, at: 0x1003, mode: .long64)
    #expect(boundary.statements == [.helper(identifier: "x86.interpret.one", payload: fnop)])
    #expect(boundary.terminator == .exit(.interpreter, resumeAt: 0x1003))
    for tier in [DoryARM64CompilationTier.baseline, .optimizing] {
      #expect(DoryARM64BaselineEmitter().compile(boundary, tier: tier).tier == .interpreterFallback)
    }
    #if os(macOS) && arch(arm64)
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 16384, optimization: optimization)
        let memory = AdmissionMemory(code: code)
        var state = try state(cr0: 0x1B)
        let prefix = try #require(executor.executeChainedSummary(
          byteProvider: { try memory.instructionBytes(at: $0, maximumCount: $1) },
          codeGenerationProvider: { _, _ in 1 }, at: state.rip, mode: .long64,
          addressSpaceID: 0, maximumInstructions: 3, state: &state, memory: memory))
        #expect(prefix.guestInstructionCount == 1 && state.rip == 0x1003)
        #expect(state.registers.rcx == 1 && state.registers.rdx == 0)
        let atFNOP = state
        for _ in 0..<2 {
          #expect(try executor.executeChainedSummary(
            byteProvider: { try memory.instructionBytes(at: $0, maximumCount: $1) },
            codeGenerationProvider: { _, _ in 1 }, at: state.rip, mode: .long64,
            addressSpaceID: 0, maximumInstructions: 2, state: &state, memory: memory) == nil)
          #expect(state == atFNOP && memory.dataAccesses == 0)
        }
        #expect(DoryX86Interpreter(profile: profile()).step(state: &state, memory: memory, mode: .long64)
          == .exception(.init(kind: .deviceNotAvailable, vector: 7, instructionPointer: 0x1003)))
        #expect(state == atFNOP)
        state.control.cr0 &= ~UInt64(8)
        let decoded = try DoryX86Decoder().decode(fnop, at: state.rip, mode: .long64)
        #expect(DoryX86Interpreter(profile: profile()).step(state: &state, memory: memory, mode: .long64)
          == .retired(decoded))
        #expect(state.rip == 0x1006 && state.registers.rcx == 1 && state.registers.rdx == 0)
      }
    #endif
  }

  private var modes: [DoryX86ExecutionMode] { [.real16, .protected16, .protected32, .long64] }

  private func profile(removing: Set<DoryX86Feature> = []) -> DoryX86CPUProfile {
    .init(identifier: "test-only.legacy-floating-admission",
      features: DoryX86CPUProfile.compatibleV1.features.union([.sse3]).subtracting(removing),
      physicalAddressBits: 40, linearAddressBits: 48, virtualTSCFrequencyHz: 1_000_000_000,
      allowingUnqualifiedSIMDAndExtendedState: true)
  }

  private func state(mode: DoryX86ExecutionMode = .long64, cr0: UInt64 = 0x11) throws -> DoryX86ArchitecturalState {
    var fp = try DoryX86FloatingPointState()
    fp.x87[0] = try .init(bytes: [0, 0, 0, 0, 0, 0, 0, 0x80, 0xFF, 0x3F], expectedByteCount: 10)
    fp.x87TagWord = 0xFFFC
    let attributes: UInt16 = mode == .long64 ? 0xA09B : mode == .protected32 ? 0xC09B : 0x009B
    return try .init(registers: .init(rax: 0xAA55, rbx: 0x4000), rip: 0x1000,
      rflags: [.reservedOne, .carry, .overflow], cs: .init(attributes: attributes, limit: .max),
      control: .init(cr0: mode == .real16 ? cr0 & ~1 : cr0 | 1, cr2: 0xAB00, cr4: 0, xcr0: 1),
      floatingPoint: fp)
  }

  private func expectFault(_ bytes: [UInt8], state: inout DoryX86ArchitecturalState,
    mode: DoryX86ExecutionMode = .long64, kind: DoryX86Exception.Kind,
    profile selected: DoryX86CPUProfile? = nil) throws {
    _ = try DoryX86Decoder().decode(bytes, at: state.rip, mode: mode)
    let before = state
    let memory = AdmissionMemory(code: bytes)
    #expect(DoryX86Interpreter(profile: selected ?? profile()).step(state: &state, memory: memory, mode: mode)
      == .exception(.init(kind: kind, vector: kind == .invalidOpcode ? 6 : 7, instructionPointer: before.rip)))
    #expect(state == before && memory.dataAccesses == 0)
  }

  private func expectDataFault(_ bytes: [UInt8], state: inout DoryX86ArchitecturalState, write: Bool) throws {
    let before = state
    let memory = AdmissionMemory(code: bytes)
    #expect(DoryX86Interpreter(profile: profile()).step(state: &state, memory: memory, mode: .long64)
      == .exception(.init(kind: .pageFault, vector: 14, errorCode: write ? 7 : 5,
        instructionPointer: 0x1000, linearAddress: 0x4000)))
    var expected = before
    expected.control.cr2 = 0x4000
    #expect(state == expected && memory.dataAccesses == 1)
  }
}

/// Instruction fetch is distinct from deliberately faulting data accesses. Each
/// per-test instance is used serially and holds fewer than fifteen instruction bytes.
private final class AdmissionMemory: DoryX86Memory, @unchecked Sendable {
  let code: [UInt8]
  let failFetch: Bool
  private(set) var dataAccesses = 0
  init(code: [UInt8], failFetch: Bool = false) { self.code = code; self.failFetch = failFetch }
  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    guard !failFetch, address >= 0x1000, address - 0x1000 < UInt64(code.count) else {
      throw DoryX86MemoryError.pageFault(address: address, errorCode: 0x14)
    }
    return Array(code.dropFirst(Int(address - 0x1000)).prefix(maximumCount))
  }
  func validateRead(at address: UInt64, byteCount: Int) throws {
    dataAccesses += 1
    throw DoryX86MemoryError.pageFault(address: address, errorCode: 5)
  }
  func validateWrite(at address: UInt64, byteCount: Int) throws {
    dataAccesses += 1
    throw DoryX86MemoryError.pageFault(address: address, errorCode: 7)
  }
  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    try validateRead(at: address, byteCount: byteCount)
    return []
  }
  func write(at address: UInt64, bytes: [UInt8]) throws {
    try validateWrite(at: address, byteCount: bytes.count)
  }
  func synchronize() {}
}
