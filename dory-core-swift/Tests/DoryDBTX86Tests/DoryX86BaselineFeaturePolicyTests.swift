import Testing

@testable import DoryDBTX86

// CPUID feature columns in Intel SDM 092 Vol. 2A/2B, including PINSRW
// (4-308), PADDQ (4-201), MOVNTI (4-92), and FXSAVE/CLFLUSH:
// https://cdrdv2-public.intel.com/922480/253666-092-sdm-vol-2a.pdf
// https://cdrdv2-public.intel.com/922481/253667-092-sdm-vol-2b.pdf
// Admission tests do not imply arithmetic, MMX exception, or full ISA qualification.
@Suite struct DoryX86BaselineFeaturePolicyTests {
  @Test func representedBaselineFormsRequireTheirOwnFeature() throws {
    for (bytes, feature) in forms {
      let instruction = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: .long64)
      #expect(DoryX86InstructionFeaturePolicy.permits(instruction, profile: .compatibleV1))
      #expect(!DoryX86InstructionFeaturePolicy.permits(instruction, profile: profile(removing: [feature])))
      if feature == .sse {
        #expect(DoryX86InstructionFeaturePolicy.permits(instruction, profile: profile(removing: [.sse2])))
      } else if feature == .sse2 {
        #expect(!DoryX86InstructionFeaturePolicy.permits(instruction, profile: profile(removing: [.sse])))
      }
    }
  }

  @Test func maskingFaultsBeforeAllOperandAndSynchronizationEffects() throws {
    for (bytes, feature) in forms {
      let memory = BaselinePolicyMemory(code: bytes)
      var state = try initialState()
      state.control.cr0 |= 1 << 3 // Missing feature #UD also precedes TS #NM.
      let before = state
      #expect(DoryX86Interpreter(profile: profile(removing: [feature])).step(
        state: &state, memory: memory, mode: .long64) == invalidOpcode)
      #expect(state == before)
      #expect(memory.dataAccesses == 0 && memory.synchronizations == 0)
    }
  }

  @Test func originalMMXAndX87DoNotAcquireSSERequirements() throws {
    let noSSE = profile(removing: [.sse, .sse2])
    for bytes: [UInt8] in [
      [0x0F, 0x6F, 0x03], [0x0F, 0x7F, 0x03], [0x0F, 0x6E, 0x03],
      [0x0F, 0x7E, 0x03], [0x0F, 0xEF, 0xC0], [0x0F, 0xFC, 0xC0],
      [0x0F, 0x71, 0xD0, 1], [0x0F, 0x60, 0xC0], [0x0F, 0x63, 0xC0],
      [0x0F, 0x77], [0xD9, 0xE8], [0xD9, 0xEE],
    ] {
      let instruction = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: .long64)
      #expect(DoryX86InstructionFeaturePolicy.permits(instruction, profile: noSSE))
    }
    // State-management/cache features are independent of the SSE CPUID bits.
    for bytes: [UInt8] in [[0x0F, 0xAE, 0x03], [0x0F, 0xAE, 0x0B], [0x0F, 0xAE, 0x3B]] {
      let instruction = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: .long64)
      #expect(DoryX86InstructionFeaturePolicy.permits(instruction, profile: noSSE))
    }
  }

  @Test func movntiRequiresSSE2ButDoesNotUseXMMEnableStateOrMatchImmediateBytes() throws {
    for prefix: [UInt8] in [[], [0x48], [0x67], [0x3E, 0x48]] {
      let bytes = prefix + [0x0F, 0xC3, 0x03]
      let memory = try DoryX86ByteArrayMemory(byteCount: 0x9000)
      try memory.write(at: 0x1000, bytes: bytes)
      var state = try initialState()
      state.control.cr0 |= (1 << 2) | (1 << 3)
      state.control.cr4 = 0
      state.registers.rax = 0x1122_3344_5566_7788
      let decoded = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: .long64)
      #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64) == .retired(decoded))
      #expect(try memory.readScalar(at: 0x8000, byteCount: 4) == 0x5566_7788)
      #expect(!DoryX86InstructionFeaturePolicy.permits(decoded, profile: profile(removing: [.sse2])))
    }
    let noSSE = profile(removing: [.sse, .sse2])
    for bytes: [UInt8] in [
      [0xB8, 0x0F, 0xC3, 0, 0], // MOV EAX,imm32 containing the opcode bytes.
      [0x8B, 0x83, 0x0F, 0xC3, 0, 0], // MOV EAX,[RBX+disp32].
    ] {
      let decoded = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: .long64)
      #expect(DoryX86InstructionFeaturePolicy.permits(decoded, profile: noSSE))
    }
  }

  @Test func pinsrwSelectsMMXOrXMMLanesAndPreservesTheOtherRegisterBank() throws {
    for xmm in [false, true] {
      for rexW in [false, true] {
        let bytes: [UInt8] = (xmm ? [0x66] : []) + (rexW ? [0x48] : [])
          + [0x0F, 0xC4, 0xC0, 0xFF]
        var state = try initialState()
        state.registers.rax = 0x1122_3344_5566_BBAA
        state.floatingPoint.x87[0] = try .init(bytes: Array(0..<10), expectedByteCount: 10)
        state.floatingPoint.ymm[0] = try .init(bytes: Array(0x40..<0x60), expectedByteCount: 32)
        let before = state
        if !xmm { state.control.cr4 = 0 } // MMX does not require OSFXSR.
        let decoded = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: .long64)
        guard case .insertPackedWord(let destination, let source, let index, let mmx) = decoded.operation else {
          Issue.record("PINSRW did not decode to its represented operation")
          continue
        }
        #expect(destination == 0 && index == (xmm ? 7 : 3) && mmx == !xmm)
        #expect(source == .register(.rax, width: .word))
        let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: bytes)
        let selected = xmm ? DoryX86CPUProfile.compatibleV1 : profile(removing: [.sse2])
        #expect(DoryX86Interpreter(profile: selected).step(state: &state,
          memory: memory, mode: .long64) == .retired(decoded))
        if xmm {
          var expected = before.floatingPoint.ymm[0].bytes
          expected.replaceSubrange(14..<16, with: [0xAA, 0xBB])
          #expect(state.floatingPoint.ymm[0].bytes == expected)
          #expect(state.floatingPoint.x87 == before.floatingPoint.x87)
          #expect(state.floatingPoint.x87TagWord == before.floatingPoint.x87TagWord)
        } else {
          #expect(state.floatingPoint.x87[0].bytes == [0, 1, 2, 3, 4, 5, 0xAA, 0xBB, 0xFF, 0xFF])
          #expect(state.floatingPoint.x87TagWord == 0)
          #expect(state.floatingPoint.ymm == before.floatingPoint.ymm)
        }
        #expect(state.rflags == before.rflags)
      }
    }
  }

  @Test func bothNativeTiersPreserveTheMOVNTIFeatureBoundaryAndCompletedPrefixOnce() throws {
    #if arch(arm64)
      let bytes: [UInt8] = [0x48, 0xFF, 0xC1, 0x0F, 0xC3, 0x03, 0x48, 0xFF, 0xC2]
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 16384, optimization: optimization)
        for _ in 0..<2 {
          let memory = try DoryX86ByteArrayMemory(byteCount: 0x9000)
          try memory.write(at: 0x1000, bytes: bytes)
          try memory.writeScalar(at: 0x8000, value: 5, byteCount: 4)
          var state = try initialState()
          state.registers.rax = 0xAABB_CCDD
          let run = try executor.executeChainedSummary(
            byteProvider: { try memory.instructionBytes(at: $0, maximumCount: $1) },
            at: state.rip, mode: .long64, addressSpaceID: 0, maximumInstructions: 3,
            state: &state, memory: memory)
          let prefix = try #require(run)
          #expect(prefix.guestInstructionCount == 1)
          #expect(state.rip == 0x1003 && state.registers.rcx == 1 && state.registers.rdx == 0)
          #expect(try memory.readScalar(at: 0x8000, byteCount: 4) == 5)
          for _ in 0..<2 {
            let before = state
            let snapshot = memory.snapshot()
            #expect(try executor.executeSummary(
              byteProvider: { try memory.instructionBytes(at: 0x1003, maximumCount: $0) },
              at: state.rip, mode: .long64, addressSpaceID: 0, maximumInstructions: 2,
              state: &state, memory: memory) == nil)
            #expect(state == before && memory.snapshot() == snapshot)
            #expect(DoryX86Interpreter(profile: profile(removing: [.sse2])).step(
              state: &state, memory: memory, mode: .long64) == .exception(.init(
                kind: .invalidOpcode, vector: 6, instructionPointer: 0x1003)))
            #expect(state == before && memory.snapshot() == snapshot)
          }
          let decoded = try DoryX86Decoder().decode([0x0F, 0xC3, 0x03], at: 0x1003, mode: .long64)
          #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64) == .retired(decoded))
          #expect(try memory.readScalar(at: 0x8000, byteCount: 4) == 0xAABB_CCDD)
          #expect(state.registers.rcx == 1 && state.rip == 0x1006)
        }
      }
    #endif
  }

  @Test func pinsrwMemoryIsExactlyOneWordAndFailureDoesNotPublishMMXTagsOrXMM() throws {
    for prefix: [UInt8] in [[], [0x66]] {
      let bytes = prefix + [0x0F, 0xC4, 0x03, 0xFF]
      let memory = try DoryX86ByteArrayMemory(byteCount: 0x8002)
      try memory.write(at: 0x1000, bytes: bytes)
      try memory.write(at: 0x8000, bytes: [0xAA, 0xBB])
      var state = try initialState()
      let decoded = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: .long64)
      #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64) == .retired(decoded))
      state = try initialState()
      let observer = BaselinePolicyMemory(code: bytes)
      let before = state
      let result = DoryX86Interpreter().step(state: &state, memory: observer, mode: .long64)
      #expect(result == .exception(.init(kind: .pageFault, vector: 14, errorCode: 0,
        instructionPointer: 0x1000, linearAddress: 0x8000)))
      var expected = before
      expected.control.cr2 = 0x8000
      #expect(state == expected)
      #expect(observer.dataAccesses == 1)
    }
  }

  @Test func halfStoresRequireMemoryAndRejectReservedRefiningPrefixesPrecisely() throws {
    for bytes: [UInt8] in [
      [0x0F, 0x17, 0xC0], [0x66, 0x0F, 0x17, 0xC0],
      [0xF2, 0x0F, 0x17, 0x03], [0xF3, 0x0F, 0x17, 0x03],
      [0xF2, 0x0F, 0xC4, 0x03, 0], [0xF3, 0x0F, 0xC4, 0x03, 0],
    ] {
      #expect(throws: DoryX86DecodeError.self) {
        try DoryX86Decoder().decode(bytes, at: 0x1000, mode: .long64)
      }
      let memory = BaselinePolicyMemory(code: bytes)
      var state = try initialState()
      let before = state
      #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64) == invalidOpcode)
      #expect(state == before && memory.dataAccesses == 0)
    }
    for prefix: [UInt8] in [[], [0x66]] {
      let bytes = prefix + [0x0F, 0x17, 0x03]
      let memory = try DoryX86ByteArrayMemory(byteCount: 0x8008)
      try memory.write(at: 0x1000, bytes: bytes)
      var state = try initialState()
      state.floatingPoint.ymm[0] = try .init(bytes: Array(0..<32), expectedByteCount: 32)
      let fp = state.floatingPoint
      let decoded = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: .long64)
      #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64) == .retired(decoded))
      #expect(try memory.read(at: 0x8000, byteCount: 8) == Array(8..<16))
      #expect(state.floatingPoint == fp)
    }
  }

  private var forms: [([UInt8], DoryX86Feature)] {
    var result: [([UInt8], DoryX86Feature)] = []
    for opcode: UInt8 in [0x10, 0x11, 0x12, 0x14, 0x15, 0x16, 0x17, 0x28, 0x29,
      0x2E, 0x2F, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5C, 0x5D, 0x5E, 0x5F] {
      result += [([0x0F, opcode, 0x03], .sse), ([0x66, 0x0F, opcode, 0x03], .sse2)]
    }
    for opcode: UInt8 in [0x10, 0x11, 0x2A, 0x2C, 0x2D, 0x51, 0x58, 0x59, 0x5C, 0x5D, 0x5E, 0x5F] {
      result += [([0xF3, 0x0F, opcode, 0x03], .sse), ([0xF2, 0x0F, opcode, 0x03], .sse2)]
    }
    for opcode: UInt8 in [0x60, 0x63, 0x6C, 0x6E, 0x6F, 0x7E, 0x7F, 0xD1, 0xD4, 0xD6,
      0xD8, 0xDA, 0xDB, 0xDE, 0xDF, 0xE0, 0xE4, 0xE7, 0xEA, 0xEB, 0xEE, 0xEF, 0xF4, 0xF6, 0xFC] {
      result.append(([0x66, 0x0F, opcode, 0x03], .sse2))
    }
    for opcode: UInt8 in [0xDA, 0xDE, 0xE0, 0xE3, 0xE4, 0xEA, 0xEE, 0xF6] {
      result.append(([0x0F, opcode, 0x03], .sse))
    }
    for opcode: UInt8 in [0xD4, 0xFB, 0xF4] { result.append(([0x0F, opcode, 0x03], .sse2)) }
    result += [
      ([0xF3, 0x0F, 0x6F, 0x03], .sse2), ([0xF3, 0x0F, 0x7F, 0x03], .sse2),
      ([0xF3, 0x0F, 0x7E, 0x03], .sse2), ([0xF3, 0x0F, 0x5A, 0x03], .sse2),
      ([0xF2, 0x0F, 0x5A, 0x03], .sse2), ([0x66, 0x0F, 0xE6, 0x03], .sse2),
      ([0xF2, 0x0F, 0xE6, 0x03], .sse2), ([0xF3, 0x0F, 0xE6, 0x03], .sse2),
      ([0xF3, 0x0F, 0xC2, 0x03, 0], .sse), ([0xF2, 0x0F, 0xC2, 0x03, 0], .sse2),
      ([0x0F, 0xC6, 0x03, 0], .sse), ([0x66, 0x0F, 0xC6, 0x03, 0], .sse2),
      ([0x66, 0x0F, 0x70, 0x03, 0], .sse2), ([0x66, 0x0F, 0x71, 0xD0, 1], .sse2),
      ([0x66, 0x0F, 0x73, 0xF8, 1], .sse2),
      ([0x0F, 0xC4, 0x03, 0], .sse), ([0x66, 0x0F, 0xC4, 0x03, 0], .sse2),
      ([0x0F, 0xC5, 0xC0, 0], .sse), ([0x66, 0x0F, 0xC5, 0xC0, 0], .sse2),
      ([0x0F, 0xD7, 0xC0], .sse), ([0x66, 0x0F, 0xD7, 0xC0], .sse2),
      ([0x0F, 0x50, 0xC0], .sse), ([0x66, 0x0F, 0x50, 0xC0], .sse2),
      ([0x0F, 0xAE, 0x13], .sse), ([0x0F, 0xAE, 0x1B], .sse),
      ([0x0F, 0xAE, 0x03], .fxsave), ([0x0F, 0xAE, 0x0B], .fxsave),
      ([0x0F, 0xAE, 0x3B], .clflush), ([0x0F, 0xC3, 0x03], .sse2),
    ]
    return result
  }

  private var invalidOpcode: DoryX86InterpreterResult {
    .exception(.init(kind: .invalidOpcode, vector: 6, instructionPointer: 0x1000))
  }

  private func profile(removing features: Set<DoryX86Feature>) -> DoryX86CPUProfile {
    .init(identifier: "test.baseline-feature-policy",
      features: DoryX86CPUProfile.compatibleV1.features.subtracting(features),
      physicalAddressBits: 40, linearAddressBits: 48, virtualTSCFrequencyHz: 1_000_000_000)
  }

  private func initialState() throws -> DoryX86ArchitecturalState {
    try .init(registers: .init(rbx: 0x8000), rip: 0x1000,
      rflags: [.reservedOne, .carry, .overflow],
      cs: .init(attributes: 0xA09B, limit: .max), control: .init(cr0: 0x13, cr4: 1 << 9))
  }
}

private final class BaselinePolicyMemory: DoryX86Memory, @unchecked Sendable {
  let code: [UInt8]
  private(set) var dataAccesses = 0
  private(set) var synchronizations = 0
  init(code: [UInt8]) { self.code = code }
  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    Array(code.prefix(maximumCount))
  }
  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    dataAccesses += 1
    throw DoryX86MemoryError.pageFault(address: address, errorCode: 0)
  }
  func validateWrite(at address: UInt64, byteCount: Int) throws {
    dataAccesses += 1
    throw DoryX86MemoryError.pageFault(address: address, errorCode: 2)
  }
  func write(at address: UInt64, bytes: [UInt8]) throws {
    dataAccesses += 1
    throw DoryX86MemoryError.pageFault(address: address, errorCode: 2)
  }
  func synchronize() { synchronizations += 1 }
}
