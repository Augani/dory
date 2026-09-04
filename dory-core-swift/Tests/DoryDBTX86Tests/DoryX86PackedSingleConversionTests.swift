import Testing

@testable import DoryDBTX86

// Intel SDM 092 Vol. 2A CVTDQ2PS, CVTPS2DQ pp. 3-225–227, CVTTPS2DQ pp. 3-249–251;
// Vol. 1 §11.5.2.1–2 and §11.5.3 (invalid, DAZ, precision and exception priority).
// https://cdrdv2-public.intel.com/922480/253666-092-sdm-vol-2a.pdf
@Suite struct DoryX86PackedSingleConversionTests {
  @Test func exactPrefixesAndAllRegisterModRMFormsDecodeInEachMode() throws {
    for mode in [DoryX86ExecutionMode.real16, .protected16, .protected32, .long64] {
      for prefix: UInt8 in [0x66, 0xF3] {
        for modRM in UInt8(0xC0)...UInt8(0xFF) {
          let instruction = try DoryX86Decoder().decode([prefix, 0x0F, 0x5B, modRM], at: 0x1000, mode: mode)
          #expect(instruction.operation == .convertPackedSingleToDword(truncated: prefix == 0xF3,
            destination: (modRM >> 3) & 7, source: .register(modRM & 7)))
        }
        for extra: [UInt8] in [[prefix], [0x67], [0x3E]] {
          let instruction = try DoryX86Decoder().decode(extra + code(prefix), at: 0x1000, mode: mode)
          #expect(instruction.operation == .convertPackedSingleToDword(truncated: prefix == 0xF3,
            destination: 0, source: .register(1)))
        }
        #expect(throws: DoryX86DecodeError.self) {
          try DoryX86Decoder().decode([0xF0] + code(prefix), at: 0x1000, mode: mode)
        }
      }
      for modRM in UInt8(0xC0)...UInt8(0xFF) {
        let instruction = try DoryX86Decoder().decode(
          [0x0F, 0x5B, modRM], at: 0x1000, mode: mode)
        #expect(instruction.operation == .convertPackedDwordToSingle(
          destination: (modRM >> 3) & 7, source: .register(modRM & 7)))
      }
      for extra: [UInt8] in [[], [0x67], [0x3E]] {
        let instruction = try DoryX86Decoder().decode(
          extra + [0x0F, 0x5B, 0xC1], at: 0x1000, mode: mode)
        #expect(instruction.operation == .convertPackedDwordToSingle(
          destination: 0, source: .register(1)))
      }
      #expect(throws: DoryX86DecodeError.self) {
        try DoryX86Decoder().decode([0xF0, 0x0F, 0x5B, 0xC1], at: 0x1000, mode: mode)
      }
      // F2 and conflicting mandatory prefixes remain invalid.
      for prefix: [UInt8] in [[0xF2], [0x66, 0xF3], [0xF3, 0x66]] {
        #expect(throws: DoryX86DecodeError.self) {
          try DoryX86Decoder().decode(prefix + [0x0F, 0x5B, 0xC1], at: 0x1000, mode: mode)
        }
      }
    }
  }

  @Test func fourLanesObeyRoundingAndTruncationWithSameOrExtendedRegisters() throws {
    let rounded: [[Int32]] = [[2, -2, 2, -4], [1, -2, 2, -4], [2, -1, 3, -3], [1, -1, 2, -3]]
    for prefix: UInt8 in [0x66, 0xF3] {
      for rounding: UInt32 in 0..<4 {
        for sameRegister in [false, true] {
          let destination = sameRegister ? 2 : 8
          let source = sameRegister ? 2 : 9
          let bytes: [UInt8] = [prefix] + (sameRegister ? [] : [0x45])
            + [0x0F, 0x5B, sameRegister ? 0xD2 : 0xC1]
          var state = try initialState(mxcsr: 0x1F80 | (rounding << 13))
          state.floatingPoint.ymm[destination] = try vector([0, 0, 0, 0], tail: upper)
          state.floatingPoint.ymm[source] = try vector(
            [Float(1.5).bitPattern, Float(-1.5).bitPattern, Float(2.5).bitPattern, Float(-3.5).bitPattern],
            tail: sameRegister ? upper : Array(repeating: 0xEE, count: 16))
          var expected = state
          expected.rip += UInt64(bytes.count)
          expected.floatingPoint.mxcsr |= 1 << 5
          let values: [Int32] = prefix == 0xF3 ? [1, -1, 2, -3] : rounded[Int(rounding)]
          expected.floatingPoint.ymm[destination] = try vector(values.map(UInt32.init(bitPattern:)), tail: upper)
          let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: bytes)
          try expectRetired(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64), bytes: bytes)
          #expect(state == expected)
        }
      }
    }
  }

  @Test func maskedInvalidAndRepresentableBoundariesDoNotTrapOrCorruptOtherLanes() throws {
    let invalid: [UInt32] = [0x7FC0_0001, 0x7F80_0001, 0x7F80_0000, 0xFF80_0000,
      0x4F00_0000, 0xCF00_0001, 0x7F7F_FFFF]
    for prefix: UInt8 in [0x66, 0xF3] {
      for bits in invalid {
        var state = try initialState(source: [bits, 0xCF00_0000, 0x4EFF_FFFF, 0x8000_0000])
        var expected = state
        expected.rip += 4
        expected.floatingPoint.mxcsr |= 1
        expected.floatingPoint.ymm[0] = try vector([0x8000_0000, 0x8000_0000, 0x7FFF_FF80, 0], tail: upper)
        let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code(prefix))
        try expectRetired(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64), bytes: code(prefix))
        #expect(state == expected)
      }
    }
  }

  @Test func singlePrecisionDenormalsApplyDAZBeforeWideningAndNeverSignalDenormal() throws {
    for prefix: UInt8 in [0x66, 0xF3] {
      for daz in [false, true] {
        for ftz in [false, true] {
          for rounding: UInt32 in 0..<4 {
            let mxcsr: UInt32 = 0x1F80 | (rounding << 13) | (daz ? 1 << 6 : 0) | (ftz ? 1 << 15 : 0)
            var state = try initialState(source: [1, 0x8000_0001, 0x007F_FFFF, 0x807F_FFFF], mxcsr: mxcsr)
            var expected = state
            expected.rip += 4
            if !daz { expected.floatingPoint.mxcsr |= 1 << 5 }
            let positive: UInt32 = !daz && prefix == 0x66 && rounding == 2 ? 1 : 0
            let negative: UInt32 = !daz && prefix == 0x66 && rounding == 1 ? .max : 0
            expected.floatingPoint.ymm[0] = try vector([positive, negative, positive, negative], tail: upper)
            let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code(prefix))
            try expectRetired(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64), bytes: code(prefix))
            #expect(state == expected)
          }
        }
      }
    }
  }

  @Test func unmaskedExceptionsPreserveDestinationAndPublishOnlyNewStickyFlags() throws {
    let cases: [([UInt32], UInt32, UInt32)] = [
      ([0x7FC0_0001, 0x3FC0_0000, 0, 0], 0x1F00, 1),
      ([0x3FC0_0000, 0, 0, 0], 0x0F80, 1 << 5),
      ([0x7FC0_0001, 0x3FC0_0000, 0, 0], 0x0F80, 1 | (1 << 5)),
    ]
    for prefix: UInt8 in [0x66, 0xF3] {
      for supportsXM in [false, true] {
        for (source, mxcsr, flags) in cases {
          // Rotate exceptional input through every lane to rule out partial destination updates.
          for rotation in 0..<4 {
            let inputs = Array(source[rotation...]) + Array(source[..<rotation])
            var state = try initialState(source: inputs, mxcsr: mxcsr | 4, supportsXM: supportsXM)
            var expected = state
            expected.floatingPoint.mxcsr |= flags
            let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code(prefix))
            #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
              == .exception(.init(kind: supportsXM ? .simdFloatingPoint : .invalidOpcode,
                vector: supportsXM ? 19 : 6, instructionPointer: 0x1000)))
            #expect(state == expected && memory.snapshot() == code(prefix))
          }
        }
      }
      // Sticky IE/PE with their masks clear do not fault a new exact conversion.
      var state = try initialState(source: [0, 0x3F80_0000, 0xBF80_0000, 0xCF00_0000], mxcsr: 0x21)
      let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code(prefix))
      try expectRetired(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64), bytes: code(prefix))
      #expect(state.floatingPoint.mxcsr == 0x21)
    }
  }

  @Test func memoryReadsExactlySixteenBytesAndFaultsBeforeNumericEffects() throws {
    for prefix: UInt8 in [0x66, 0xF3] {
      for variant in 0..<6 {
        let bytes: [UInt8] = (variant == 5 ? [0x36] : []) + [prefix, 0x0F, 0x5B, 0x03]
        let memory = PackedSingleMemory(code: bytes, source: variant == 0 ? words([0, 0x3F80_0000, 0xBF80_0000, 0xCF00_0000]) : nil)
        var state = try initialState(mxcsr: 0)
        if variant == 1 { state.registers.rbx = 0x8001 }
        if variant >= 4 { state.registers.rbx = 0x0000_8000_0000_0000 }
        let mode: DoryX86ExecutionMode = variant == 2 ? .protected32 : .long64
        if variant == 2 { state.cs.attributes = 0xC09B; state.ds.limit = 0x800E }
        var expected = state
        let result = DoryX86Interpreter().step(state: &state, memory: memory, mode: mode)
        if variant == 0 {
          try expectRetired(result, bytes: bytes)
          expected.rip += 4
          expected.floatingPoint.ymm[0] = try vector([0, 1, .max, 0x8000_0000], tail: upper)
        } else if variant == 3 {
          #expect(result == .exception(.init(kind: .pageFault, vector: 14, errorCode: 0,
            instructionPointer: 0x1000, linearAddress: 0x8000)))
          expected.control.cr2 = 0x8000
        } else {
          #expect(result == .exception(.init(kind: variant == 5 ? .stackSegment : .generalProtection,
            vector: variant == 5 ? 12 : 13, errorCode: 0, instructionPointer: 0x1000)))
        }
        #expect(state == expected && memory.writes == 0)
        #expect(memory.reads.count == (variant == 0 || variant == 3 ? 1 : 0))
        if let read = memory.reads.first { #expect(read.address == 0x8000 && read.byteCount == 16) }
      }
    }
  }

  @Test func featureAndExecutionStateChecksWinBeforeAnUnmappedOperand() throws {
    for prefix: UInt8 in [0x66, 0xF3] {
      for variant in 0..<4 {
        let memory = PackedSingleMemory(code: [prefix, 0x0F, 0x5B, 0x03], source: nil)
        var state = try initialState()
        var profile = DoryX86CPUProfile.compatibleV1
        if variant == 0 {
          profile = .init(identifier: profile.identifier, features: profile.features.subtracting([.sse2]),
            physicalAddressBits: profile.physicalAddressBits, linearAddressBits: profile.linearAddressBits,
            virtualTSCFrequencyHz: profile.virtualTSCFrequencyHz)
          state.control.cr0 |= 8
        }
        if variant == 1 { state.control.cr0 |= 4 | 8 }
        if variant == 2 { state.control.cr4 &= ~UInt64(1 << 9) }
        if variant == 3 { state.control.cr0 |= 8 }
        let before = state
        #expect(DoryX86Interpreter(profile: profile).step(state: &state, memory: memory, mode: .long64)
          == .exception(.init(kind: variant == 3 ? .deviceNotAvailable : .invalidOpcode,
            vector: variant == 3 ? 7 : 6, instructionPointer: 0x1000)))
        #expect(state == before && memory.reads.isEmpty && memory.writes == 0)
      }
    }
  }

  @Test func bothNativeTiersDeclineAndPublishACompletedIntegerPrefixExactlyOnce() throws {
    #if arch(arm64)
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        for prefix: UInt8 in [0x66, 0xF3] {
          let bytes: [UInt8] = [0x48, 0xFF, 0xC1] + code(prefix)
          let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: bytes)
          let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 16384, optimization: optimization)
          var state = try initialState(source: [0, 0x3F80_0000, 0xBF80_0000, 0xCF00_0000])
          let execution = try executor.executeChainedSummary(
            byteProvider: { try memory.instructionBytes(at: $0, maximumCount: $1) },
            at: state.rip, mode: .long64, addressSpaceID: 0, maximumInstructions: 2,
            state: &state, memory: memory)
          let summary = try #require(execution)
          #expect(summary.guestInstructionCount == 1 && state.rip == 0x1003 && state.registers.rcx == 1)
          let before = state
          #expect(try executor.executeSummary(
            byteProvider: { try memory.instructionBytes(at: 0x1003, maximumCount: $0) },
            at: state.rip, mode: .long64, addressSpaceID: 0, maximumInstructions: 1,
            state: &state, memory: memory) == nil)
          #expect(state == before)
          try expectRetired(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64),
            bytes: code(prefix), at: 0x1003)
          #expect(state.registers.rcx == 1 && state.rip == 0x1007)
          #expect(state.floatingPoint.ymm[0].bytes == words([0, 1, .max, 0x8000_0000]) + upper)
        }
      }
    #endif
  }

  private var upper: [UInt8] { Array(0xA0..<0xB0) }
  private func code(_ prefix: UInt8) -> [UInt8] { [prefix, 0x0F, 0x5B, 0xC1] }
  private func words(_ values: [UInt32]) -> [UInt8] {
    values.flatMap { value in (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
  }
  private func vector(_ values: [UInt32], tail: [UInt8]) throws -> DoryX86RegisterBytes {
    try .init(bytes: words(values) + tail, expectedByteCount: 32)
  }
  private func initialState(source: [UInt32] = [0, 0, 0, 0], mxcsr: UInt32 = 0x1F80,
    supportsXM: Bool = true) throws -> DoryX86ArchitecturalState {
    var state = try DoryX86ArchitecturalState(registers: .init(rbx: 0x8000), rip: 0x1000,
      rflags: [.reservedOne, .carry, .overflow],
      cs: .init(selector: 8, attributes: 0xA09B, limit: .max),
      ds: .init(selector: 0x10, attributes: 0x0093, limit: .max),
      control: .init(cr0: 0x11, cr2: 0x1234, cr4: (1 << 9) | (supportsXM ? 1 << 10 : 0)),
      floatingPoint: .init(mxcsr: mxcsr))
    state.floatingPoint.ymm[0] = try vector([0xCCCC_CCCC, 0xCCCC_CCCC, 0xCCCC_CCCC, 0xCCCC_CCCC], tail: upper)
    state.floatingPoint.ymm[1] = try vector(source, tail: Array(repeating: 0xEE, count: 16))
    return state
  }
  private func expectRetired(_ result: DoryX86InterpreterResult, bytes: [UInt8], at address: UInt64 = 0x1000) throws {
    let instruction = try DoryX86Decoder().decode(bytes, at: address, mode: .long64)
    #expect(result == .retired(instruction))
  }
}

private final class PackedSingleMemory: DoryX86Memory, @unchecked Sendable {
  let code: [UInt8]
  let source: [UInt8]?
  private(set) var reads: [(address: UInt64, byteCount: Int)] = []
  private(set) var writes = 0
  init(code: [UInt8], source: [UInt8]?) { self.code = code; self.source = source }
  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] { Array(code.prefix(maximumCount)) }
  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    reads.append((address, byteCount))
    guard address == 0x8000, byteCount == 16, let source else {
      throw DoryX86MemoryError.pageFault(address: address, errorCode: 0)
    }
    return source
  }
  func write(at address: UInt64, bytes: [UInt8]) throws {
    writes += 1
    throw DoryX86MemoryError.pageFault(address: address, errorCode: 2)
  }
}
