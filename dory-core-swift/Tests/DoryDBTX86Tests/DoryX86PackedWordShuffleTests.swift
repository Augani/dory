import Testing

@testable import DoryDBTX86

// Intel SDM 092 Vol. 2B PSHUFHW pp. 4-430–432; PSHUFLW pp. 4-433–435,
// plus Vol. 2A Table 2-21 (legacy Type 4 alignment/control exceptions).
// https://cdrdv2-public.intel.com/922481/253667-092-sdm-vol-2b.pdf
// https://cdrdv2-public.intel.com/922480/253666-092-sdm-vol-2a.pdf
@Suite struct DoryX86PackedWordShuffleTests {
  @Test func mandatoryPrefixesSelectWordHalfWithoutChangingPSHUFD() throws {
    for mode in [DoryX86ExecutionMode.real16, .protected16, .protected32, .long64] {
      for (prefix, format) in forms {
        for extra: [UInt8] in [[], [0x67], [0x3E], [prefix]] {
          let bytes: [UInt8] = extra + [prefix, 0x0F, 0x70, 0xD2, 0x1B]
          let instruction = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: mode)
          #expect(instruction.operation == .vectorShuffle(format: format,
            destination: 2, source: .register(2), control: 0x1B))
          #expect(instruction.bytes == bytes)
          #expect(DoryX86InstructionFeaturePolicy.permits(instruction, profile: .compatibleV1))
        }
        #expect(throws: DoryX86DecodeError.self) {
          try DoryX86Decoder().decode([0xF0, prefix, 0x0F, 0x70, 0xD2, 0], at: 0x1000, mode: mode)
        }
      }
    }
    let pshufd = try DoryX86Decoder().decode([0x66, 0x0F, 0x70, 0xD2, 0x1B], at: 0x1000, mode: .long64)
    #expect(pshufd.operation == .vectorShuffle(format: .packedDoublewords,
      destination: 2, source: .register(2), control: 0x1B))
    // The actual stress-guest fault encoding is PSHUFLW xmm2,xmm2,0.
    let guest = try DoryX86Decoder().decode([0xF2, 0x0F, 0x70, 0xD2, 0], at: 0x1003A9F, mode: .long64)
    #expect(guest.operation == .vectorShuffle(format: .packedLowWords,
      destination: 2, source: .register(2), control: 0))
  }

  @Test func everyImmediateSelectsSourceWordsAndPreservesUpperYMM() throws {
    for (prefix, format) in forms {
      for sameRegister in [false, true] {
        for control in UInt8.min...UInt8.max {
          // REX.R/B exercises XMM10/XMM11; the same-register case is XMM2.
          let bytes: [UInt8] = [prefix] + (sameRegister ? [] : [0x45])
            + [0x0F, 0x70, sameRegister ? 0xD2 : 0xD3, control]
          let destination = sameRegister ? 2 : 10
          let source = sameRegister ? 2 : 11
          var state = try initialState()
          state.floatingPoint.ymm[destination] = try .init(
            bytes: [UInt8](repeating: 0xCC, count: 16) + upperSentinel, expectedByteCount: 32)
          state.floatingPoint.ymm[source] = try .init(
            bytes: sourceBytes + (sameRegister ? upperSentinel : [UInt8](repeating: 0xEE, count: 16)),
            expectedByteCount: 32)
          let before = state
          let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: bytes)
          let instruction = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: .long64)
          #expect(DoryX86Interpreter().step(state: &state, memory: memory,
            mode: .long64) == .retired(instruction))
          var expected = before
          expected.rip += UInt64(bytes.count)
          expected.floatingPoint.ymm[destination] = try .init(
            bytes: expectedBytes(format: format, control: control) + upperSentinel, expectedByteCount: 32)
          #expect(state == expected)
        }
      }
    }
  }

  @Test func memorySourceReadsAllSixteenBytesAndCopiesUnshuffledSourceHalf() throws {
    for (prefix, format) in forms {
      let bytes: [UInt8] = [prefix, 0x0F, 0x70, 0x13, 0x1B] // XMM2,[RBX].
      let memory = WordShuffleMemory(code: bytes, source: sourceBytes)
      var state = try initialState()
      state.floatingPoint.ymm[2] = try .init(bytes: [UInt8](repeating: 0xCC, count: 16)
        + upperSentinel, expectedByteCount: 32)
      let instruction = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: .long64)
      #expect(DoryX86Interpreter().step(state: &state, memory: memory,
        mode: .long64) == .retired(instruction))
      #expect(state.floatingPoint.ymm[2].bytes == expectedBytes(format: format, control: 0x1B) + upperSentinel)
      #expect(memory.reads.count == 1 && memory.reads.first?.address == 0x8000
        && memory.reads.first?.byteCount == 16)
      #expect(memory.writes == 0)
    }
  }

  @Test func featureAndControlFaultsPrecedeDataAccessAndPreserveState() throws {
    for (prefix, _) in forms {
      for variant in 0..<4 {
        let memory = WordShuffleMemory(code: [prefix, 0x0F, 0x70, 0x13, 0], source: nil)
        var state = try initialState()
        let profile: DoryX86CPUProfile
        if variant == 0 {
          let base = DoryX86CPUProfile.compatibleV1
          profile = .init(identifier: base.identifier, features: base.features.subtracting([.sse2]),
            physicalAddressBits: base.physicalAddressBits, linearAddressBits: base.linearAddressBits,
            virtualTSCFrequencyHz: base.virtualTSCFrequencyHz)
          state.control.cr0 |= 8 // Missing feature still takes precedence over TS.
        } else {
          profile = .compatibleV1
          if variant == 1 { state.control.cr0 |= 4 | 8 }
          if variant == 2 { state.control.cr4 &= ~UInt64(1 << 9) }
          if variant == 3 { state.control.cr0 |= 8 }
        }
        let before = state
        let expected: DoryX86InterpreterResult = .exception(.init(
          kind: variant == 3 ? .deviceNotAvailable : .invalidOpcode,
          vector: variant == 3 ? 7 : 6, instructionPointer: 0x1000))
        #expect(DoryX86Interpreter(profile: profile).step(state: &state, memory: memory,
          mode: .long64) == expected)
        #expect(state == before && memory.reads.isEmpty && memory.writes == 0)
      }
    }
  }

  @Test func memoryAlignmentBoundsAndReadFaultsDoNotPublishDestination() throws {
    for (prefix, _) in forms {
      for variant in 0..<5 {
        let code: [UInt8] = (variant == 4 ? [0x36] : []) + [prefix, 0x0F, 0x70, 0x13, 0x1B]
        let memory = WordShuffleMemory(code: code, source: nil)
        var state = try initialState()
        let mode: DoryX86ExecutionMode = variant == 1 ? .protected32 : .long64
        if variant == 0 { state.registers.rbx = 0x8001 }
        if variant >= 3 { state.registers.rbx = 0x0000_8000_0000_0000 }
        if variant == 1 {
          state.cs.attributes = 0xC09B
          state.ds.limit = 0x800E // The last byte is outside the segment.
        }
        let before = state
        let expected: DoryX86InterpreterResult = variant == 2
          ? .exception(.init(kind: .pageFault, vector: 14, errorCode: 0,
            instructionPointer: 0x1000, linearAddress: 0x8000))
          : .exception(.init(kind: variant == 4 ? .stackSegment : .generalProtection,
            vector: variant == 4 ? 12 : 13, errorCode: 0, instructionPointer: 0x1000))
        let result = DoryX86Interpreter().step(state: &state, memory: memory, mode: mode)
        #expect(result == expected)
        var expectedState = before
        if variant == 2 { expectedState.control.cr2 = 0x8000 }
        #expect(state == expectedState)
        #expect(memory.reads.count == (variant == 2 ? 1 : 0) && memory.writes == 0)
      }
    }
  }

  @Test func bothNativeTiersFallBackAndPublishCompletedPrefixExactlyOnce() throws {
    #if arch(arm64)
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        for (prefix, format) in forms {
          let bytes: [UInt8] = [0x48, 0xFF, 0xC1, prefix, 0x0F, 0x70, 0xD2, 0]
          let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 16384, optimization: optimization)
          let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: bytes)
          var state = try initialState()
          state.floatingPoint.ymm[2] = try .init(bytes: sourceBytes + upperSentinel, expectedByteCount: 32)
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
          let instruction = try DoryX86Decoder().decode(Array(bytes.dropFirst(3)), at: 0x1003, mode: .long64)
          #expect(DoryX86Interpreter().step(state: &state, memory: memory,
            mode: .long64) == .retired(instruction))
          #expect(state.floatingPoint.ymm[2].bytes == expectedBytes(format: format, control: 0) + upperSentinel)
          #expect(state.registers.rcx == 1 && state.rip == 0x1008)
        }
      }
    #endif
  }

  private var forms: [(UInt8, DoryX86VectorShuffleFormat)] {
    [(0xF2, .packedLowWords), (0xF3, .packedHighWords)]
  }
  private var sourceWords: [UInt16] { (0..<8).map { 0x1000 + UInt16($0) * 0x0101 } }
  private var sourceBytes: [UInt8] { bytes(of: sourceWords) }
  private var upperSentinel: [UInt8] { Array(0x80..<0x90) }

  private func bytes(of words: [UInt16]) -> [UInt8] {
    words.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8($0 >> 8)] }
  }

  private func expectedBytes(format: DoryX86VectorShuffleFormat, control: UInt8) -> [UInt8] {
    let start = format == .packedLowWords ? 0 : 4
    let selectors = [Int(control & 3), Int(control >> 2 & 3), Int(control >> 4 & 3), Int(control >> 6 & 3)]
    let shuffled = selectors.map { sourceWords[start + $0] }
    return bytes(of: start == 0 ? shuffled + Array(sourceWords.suffix(4)) : Array(sourceWords.prefix(4)) + shuffled)
  }

  private func initialState() throws -> DoryX86ArchitecturalState {
    try .init(registers: .init(rbx: 0x8000), rip: 0x1000,
      rflags: [.reservedOne, .carry, .overflow],
      cs: .init(selector: 8, attributes: 0xA09B, limit: .max),
      ds: .init(selector: 0x10, attributes: 0x0093, limit: .max),
      control: .init(cr0: 0x11, cr4: 1 << 9))
  }
}

private final class WordShuffleMemory: DoryX86Memory, @unchecked Sendable {
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
