import Testing

@testable import DoryDBTX86

// Intel SDM 092 Vol. 2A: SIMD exception classes and (V)CMP*/(V)CVT*.
// Intel SDM 092 Vol. 2B: MOVLPS/MOVLPD, (V)SQRT*, and UNPCK*.
// https://cdrdv2-public.intel.com/922480/253666-092-sdm-vol-2a.pdf
// https://cdrdv2-public.intel.com/922481/253667-092-sdm-vol-2b.pdf
@Suite struct DoryX86SSEBaselineResidualTests {
  private let decoder = DoryX86Decoder()

  @Test func exactMandatoryPrefixesDecodeAndReservedUnpackAliasesFailBeforeModRM() throws {
    #expect(try decoder.decode([0x0F, 0x13, 0x0B], at: 0x1000, mode: .long64).operation
      == .moveVectorQwordHalf(
        destination: .memory(.init(base: .rbx, width: .quadword)),
        source: .register(1), sourceHigh: false, destinationHigh: false))
    #expect(try decoder.decode([0x66, 0x0F, 0x13, 0x0B], at: 0x1000, mode: .long64).operation
      == .moveVectorQwordHalf(
        destination: .memory(.init(base: .rbx, width: .quadword)),
        source: .register(1), sourceHigh: false, destinationHigh: false))
    #expect(try decoder.decode([0x0F, 0x51, 0xC1], at: 0x1000, mode: .long64).operation
      == .scalarSquareRoot(format: .packedSingle, destination: 0, source: .register(1)))
    #expect(try decoder.decode([0x66, 0x0F, 0x51, 0xC1], at: 0x1000, mode: .long64).operation
      == .scalarSquareRoot(format: .packedDouble, destination: 0, source: .register(1)))
    #expect(try decoder.decode([0x0F, 0xC2, 0xC1, 1], at: 0x1000, mode: .long64).operation
      == .scalarCompare(predicate: .lessThan, format: .packedSingle,
        destination: 0, source: .register(1)))
    #expect(try decoder.decode([0x66, 0x0F, 0xC2, 0xC1, 7], at: 0x1000, mode: .long64).operation
      == .scalarCompare(predicate: .ordered, format: .packedDouble,
        destination: 0, source: .register(1)))
    #expect(try decoder.decode([0x0F, 0x5A, 0xC1], at: 0x1000, mode: .long64).operation
      == .convertPackedSingleToDouble(destination: 0, source: .register(1)))
    #expect(try decoder.decode([0x66, 0x0F, 0x5A, 0xC1], at: 0x1000, mode: .long64).operation
      == .convertPackedDoubleToSingle(destination: 0, source: .register(1)))
    #expect(try decoder.decode([0x0F, 0x5B, 0xC1], at: 0x1000, mode: .long64).operation
      == .convertPackedDwordToSingle(destination: 0, source: .register(1)))

    #expect(throws: DoryX86DecodeError.invalidEncoding(
      address: 0x1000, detail: "packed floating unpack rejects repeat prefixes")) {
      try decoder.decode([0xF2, 0x0F, 0x14], at: 0x1000, mode: .long64)
    }
    #expect(throws: DoryX86DecodeError.invalidEncoding(
      address: 0x1000, detail: "packed floating unpack rejects repeat prefixes")) {
      try decoder.decode([0xF3, 0x0F, 0x15], at: 0x1000, mode: .long64)
    }
    #expect(throws: DoryX86DecodeError.self) {
      try decoder.decode([0x0F, 0x13, 0xC1], at: 0x1000, mode: .long64)
    }
  }

  @Test func lowQwordStoresWriteExactlyEightBytesAndPreserveArchitecturalState() throws {
    for code: [UInt8] in [[0x0F, 0x13, 0x0B], [0x66, 0x0F, 0x13, 0x0B]] {
      let target: UInt64 = 0x1100
      var bytes = code + [UInt8](repeating: 0xCC, count: 0x200)
      bytes.replaceSubrange(
        Int(target - 0x1000)..<Int(target - 0x1000 + 16),
        with: repeatElement(0xA5, count: 16))
      let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: bytes)
      var state = try initialState()
      state.registers.rbx = target
      state.floatingPoint.ymm[1] = try vector(
        qwords: [0x0123_4567_89AB_CDEF, 0xFEDC_BA98_7654_3210], upper: upper)
      let before = state
      try expectRetired(DoryX86Interpreter().step(
        state: &state, memory: memory, mode: .long64), code: code)
      #expect(try memory.read(at: target, byteCount: 16)
        == littleEndian(0x0123_4567_89AB_CDEF, bytes: 8) + Array(repeating: 0xA5, count: 8))
      #expect(state.registers == before.registers && state.rflags == before.rflags)
      #expect(state.floatingPoint == before.floatingPoint)
    }
  }

  @Test func packedSquareRootsCoverEveryLaneAndPreserveUpperYMM() throws {
    let cases: [([UInt8], DoryX86RegisterBytes, [UInt8])] = [
      ([0x0F, 0x51, 0xC1], try vector(singles: [4, 9, 16, 25], upper: .init(repeating: 0xEE, count: 16)),
        [2, 3, 4, 5].flatMap { littleEndian(Float($0).bitPattern, bytes: 4) }),
      ([0x66, 0x0F, 0x51, 0xC1], try vector(doubles: [36, 49], upper: .init(repeating: 0xEE, count: 16)),
        [6, 7].flatMap { littleEndian(Double($0).bitPattern, bytes: 8) }),
    ]
    for (code, source, low) in cases {
      let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code)
      var state = try initialState()
      state.floatingPoint.ymm[0] = try .init(
        bytes: Array(repeating: 0xCC, count: 16) + upper, expectedByteCount: 32)
      state.floatingPoint.ymm[1] = source
      try expectRetired(DoryX86Interpreter().step(
        state: &state, memory: memory, mode: .long64), code: code)
      #expect(state.floatingPoint.ymm[0].bytes == low + upper)
      #expect(state.floatingPoint.mxcsr == 0x1F80)
    }
  }

  @Test func packedSquareRootsApplyDAZBeforeNegativeInvalidDetection() throws {
    let cases: [([UInt8], DoryX86RegisterBytes, [UInt8], [UInt8])] = [
      ([0x0F, 0x51, 0xC1],
        try vector(singleBits: Array(repeating: 0x8000_0001, count: 4), upper: upper),
        Array(repeating: 0xFFC0_0000, count: 4).flatMap { littleEndian($0, bytes: 4) },
        Array(repeating: 0x8000_0000, count: 4).flatMap { littleEndian($0, bytes: 4) }),
      ([0x66, 0x0F, 0x51, 0xC1],
        try vector(doubleBits: Array(repeating: 0x8000_0000_0000_0001, count: 2), upper: upper),
        Array(repeating: UInt64(0xFFF8_0000_0000_0000), count: 2)
          .flatMap { littleEndian($0, bytes: 8) },
        Array(repeating: UInt64(0x8000_0000_0000_0000), count: 2)
          .flatMap { littleEndian($0, bytes: 8) }),
    ]
    for (code, source, maskedInvalid, negativeZero) in cases {
      for (mxcsr, expectedLow, expectedMXCSR): (UInt32, [UInt8], UInt32) in [
        (0x1F80, maskedInvalid, 0x1F83),
        (0x1FC0, negativeZero, 0x1FC0),
      ] {
        let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code)
        var state = try initialState(mxcsr: mxcsr)
        state.floatingPoint.ymm[0] = try .init(
          bytes: Array(repeating: 0xCC, count: 16) + upper, expectedByteCount: 32)
        state.floatingPoint.ymm[1] = source
        try expectRetired(DoryX86Interpreter().step(
          state: &state, memory: memory, mode: .long64), code: code)
        #expect(state.floatingPoint.ymm[0].bytes == expectedLow + upper)
        #expect(state.floatingPoint.mxcsr == expectedMXCSR)
      }
    }
  }

  @Test func packedMemoryFormsCheckSixteenByteAlignmentBeforeReading() throws {
    let alignedForms: [[UInt8]] = [
      [0x0F, 0xC2, 0x03, 0], [0x66, 0x0F, 0xC2, 0x03, 0],
      [0x0F, 0x51, 0x03], [0x66, 0x0F, 0x51, 0x03],
      [0x66, 0x0F, 0x5A, 0x03], [0x0F, 0x5B, 0x03],
      [0x0F, 0x14, 0x03], [0x66, 0x0F, 0x15, 0x03],
    ]
    for code in alignedForms {
      let denied = ResidualMemory(code: code, source: nil)
      var unaligned = try initialState()
      unaligned.registers.rbx = 0x8001
      let before = unaligned
      #expect(DoryX86Interpreter().step(
        state: &unaligned, memory: denied, mode: .long64)
        == .exception(.init(kind: .generalProtection, vector: 13,
          errorCode: 0, instructionPointer: 0x1000)))
      #expect(unaligned == before && denied.reads.isEmpty)

      let allowed = ResidualMemory(code: code, source: Array(repeating: 0, count: 16))
      var aligned = try initialState()
      aligned.registers.rbx = 0x8000
      try expectRetired(DoryX86Interpreter().step(
        state: &aligned, memory: allowed, mode: .long64), code: code)
      #expect(allowed.reads == [.init(address: 0x8000, byteCount: 16)])
    }

    // CVTPS2PD is the m64 Type 3 form and remains unaligned-capable.
    let code: [UInt8] = [0x0F, 0x5A, 0x03]
    let memory = ResidualMemory(
      code: code, source: Array(repeating: 0, count: 8), sourceAddress: 0x8001)
    var state = try initialState()
    state.registers.rbx = 0x8001
    try expectRetired(DoryX86Interpreter().step(
      state: &state, memory: memory, mode: .long64), code: code)
    #expect(memory.reads == [.init(address: 0x8001, byteCount: 8)])
  }

  @Test func packedCompareUsesEveryLaneAndPublishesMaskedInvalid() throws {
    let code: [UInt8] = [0x0F, 0xC2, 0xC1, 1] // CMPLTPS
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code)
    var state = try initialState()
    state.floatingPoint.ymm[0] = try vector(singles: [1, 3, 1, 4], upper: upper)
    state.floatingPoint.ymm[1] = try vector(
      singleBits: [Float(2).bitPattern, Float(2).bitPattern, 0x7FC0_0001, Float(4).bitPattern],
      upper: .init(repeating: 0xEE, count: 16))
    try expectRetired(DoryX86Interpreter().step(
      state: &state, memory: memory, mode: .long64), code: code)
    #expect(state.floatingPoint.ymm[0].bytes
      == Array(repeating: 0xFF, count: 4) + Array(repeating: 0, count: 12) + upper)
    #expect(state.floatingPoint.mxcsr == 0x1F81)
  }

  @Test func unmaskedPackedInvalidPreservesDestinationAndPublishesOnlyStatus() throws {
    for code: [UInt8] in [[0x0F, 0x51, 0xC1], [0x66, 0x0F, 0xC2, 0xC1, 1]] {
      let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code)
      var state = try initialState(mxcsr: 0x1F00)
      state.floatingPoint.ymm[0] = try .init(
        bytes: Array(repeating: 0xCC, count: 16) + upper, expectedByteCount: 32)
      state.floatingPoint.ymm[1] = code[0] == 0x66
        ? try vector(doubleBits: [0x7FF8_0000_0000_0001, Double(1).bitPattern], upper: upper)
        : try vector(singleBits: [0xBF80_0000, 0, 0, 0], upper: upper)
      var expected = state
      expected.floatingPoint.mxcsr |= 1
      #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
        == .exception(.init(kind: .simdFloatingPoint, vector: 19, instructionPointer: 0x1000)))
      #expect(state == expected)
    }
  }

  @Test func packedConversionsUseArchitecturalSourceWidthsAndUpperPolicies() throws {
    let cases: [([UInt8], [UInt8], Int, [UInt8])] = [
      ([0x0F, 0x5A, 0x03],
        [Float(-1.5).bitPattern, Float(2.25).bitPattern].flatMap { littleEndian($0, bytes: 4) }, 8,
        [Double(-1.5).bitPattern, Double(2.25).bitPattern].flatMap { littleEndian($0, bytes: 8) }),
      ([0x66, 0x0F, 0x5A, 0x03],
        [Double(1.5).bitPattern, Double(-2.25).bitPattern].flatMap { littleEndian($0, bytes: 8) }, 16,
        [Float(1.5).bitPattern, Float(-2.25).bitPattern].flatMap { littleEndian($0, bytes: 4) }
          + Array(repeating: 0, count: 8)),
      ([0x0F, 0x5B, 0x03],
        [Int32(0), 1, 16_777_217, -16_777_217].flatMap {
          littleEndian(UInt32(bitPattern: $0), bytes: 4)
        }, 16,
        [Float(0).bitPattern, Float(1).bitPattern, Float(16_777_216).bitPattern,
          Float(-16_777_216).bitPattern].flatMap { littleEndian($0, bytes: 4) }),
    ]
    for (code, source, width, expectedLow) in cases {
      let memory = ResidualMemory(code: code, source: source)
      var state = try initialState()
      state.registers.rbx = 0x8000
      state.floatingPoint.ymm[0] = try .init(
        bytes: Array(repeating: 0xCC, count: 16) + upper, expectedByteCount: 32)
      try expectRetired(DoryX86Interpreter().step(
        state: &state, memory: memory, mode: .long64), code: code)
      #expect(memory.reads == [ResidualMemory.Read(address: 0x8000, byteCount: width)])
      #expect(state.floatingPoint.ymm[0].bytes == expectedLow + upper)
      #expect(state.floatingPoint.mxcsr == (code[1] == 0x5B ? 0x1FA0 : 0x1F80))
    }
  }

  @Test func featureAndSSEStateFaultsWinBeforeDataOperands() throws {
    let cases: [([UInt8], DoryX86Feature)] = [
      ([0x0F, 0x51, 0x03], .sse), ([0x0F, 0xC2, 0x03, 0], .sse),
      ([0x66, 0x0F, 0x51, 0x03], .sse2), ([0x66, 0x0F, 0xC2, 0x03, 0], .sse2),
      ([0x0F, 0x5A, 0x03], .sse2), ([0x66, 0x0F, 0x5A, 0x03], .sse2),
      ([0x0F, 0x5B, 0x03], .sse2),
    ]
    for (code, feature) in cases {
      for variant in 0..<4 {
        let memory = ResidualMemory(code: code, source: nil)
        var state = try initialState()
        var profile = DoryX86CPUProfile.compatibleV1
        if variant == 0 {
          profile = .init(identifier: "test.sse-residual-mask",
            features: profile.features.subtracting([feature]),
            physicalAddressBits: profile.physicalAddressBits,
            linearAddressBits: profile.linearAddressBits,
            virtualTSCFrequencyHz: profile.virtualTSCFrequencyHz)
        } else if variant == 1 { state.control.cr0 |= 1 << 2 }
        else if variant == 2 { state.control.cr4 &= ~UInt64(1 << 9) }
        else { state.control.cr0 |= 1 << 3 }
        let expectedKind: DoryX86Exception.Kind = variant == 3 ? .deviceNotAvailable : .invalidOpcode
        let before = state
        #expect(DoryX86Interpreter(profile: profile).step(
          state: &state, memory: memory, mode: .long64)
          == .exception(.init(kind: expectedKind, vector: variant == 3 ? 7 : 6,
            instructionPointer: 0x1000)))
        #expect(state == before && memory.reads.isEmpty)
      }
    }
  }

  @Test func legacyUnpackPreservesUpperYMM() throws {
    let cases: [([UInt8], [UInt8])] = [
      ([0x0F, 0x14, 0xC1],
        Array(0..<4) + Array(0x20..<0x24) + Array(4..<8) + Array(0x24..<0x28)),
      ([0x66, 0x0F, 0x15, 0xC1], Array(8..<16) + Array(0x28..<0x30)),
    ]
    for (code, expectedLow) in cases {
      let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code)
      var state = try initialState()
      state.floatingPoint.ymm[0] = try .init(
        bytes: Array(0..<16) + upper, expectedByteCount: 32)
      state.floatingPoint.ymm[1] = try .init(
        bytes: Array(0x20..<0x30) + Array(repeating: 0xEE, count: 16), expectedByteCount: 32)
      try expectRetired(DoryX86Interpreter().step(
        state: &state, memory: memory, mode: .long64), code: code)
      #expect(state.floatingPoint.ymm[0].bytes == expectedLow + upper)
    }
  }

  @Test func bothNativeTiersDeclineResidualSIMDAtItsExactBoundary() throws {
    #if arch(arm64)
      let residuals: [[UInt8]] = [
        [0x0F, 0x13, 0x0B], [0x0F, 0x51, 0xC1], [0x66, 0x0F, 0xC2, 0xC1, 0],
        [0x0F, 0x5A, 0xC1], [0x66, 0x0F, 0x5A, 0xC1], [0x0F, 0x5B, 0xC1],
      ]
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        for residual in residuals {
          let code: [UInt8] = [0x48, 0xFF, 0xC1] + residual
          let memory = try DoryX86ByteArrayMemory(
            baseAddress: 0x1000, bytes: code + Array(repeating: 0, count: 0x100))
          let executor = try DoryARM64BaselineExecutor(
            maximumCodeBytes: 16_384, optimization: optimization)
          var state = try initialState()
          state.registers.rbx = 0x1080
          state.floatingPoint.ymm[1] = try vector(singles: [1, 4, 9, 16], upper: upper)
          let execution = try executor.executeChainedSummary(
            byteProvider: { try memory.instructionBytes(at: $0, maximumCount: $1) },
            at: state.rip, mode: .long64, addressSpaceID: 0, maximumInstructions: 2,
            state: &state, memory: memory)
          let summary = try #require(execution)
          #expect(summary.guestInstructionCount == 1)
          #expect(state.rip == 0x1003 && state.registers.rcx == 1)
          let before = state
          #expect(try executor.executeSummary(
            byteProvider: { try memory.instructionBytes(at: 0x1003, maximumCount: $0) },
            at: state.rip, mode: .long64, addressSpaceID: 0, maximumInstructions: 1,
            state: &state, memory: memory) == nil)
          #expect(state == before)
        }
      }
    #endif
  }

  private var upper: [UInt8] { Array(0xA0..<0xB0) }

  private func initialState(mxcsr: UInt32 = 0x1F80) throws
    -> DoryX86ArchitecturalState
  {
    try .init(rip: 0x1000, rflags: [.reservedOne, .carry, .overflow],
      cs: .init(attributes: 0xA09B, limit: .max),
      control: .init(cr0: 0x11, cr4: (1 << 9) | (1 << 10)),
      floatingPoint: .init(mxcsr: mxcsr))
  }

  private func vector(singles: [Float], upper: [UInt8]) throws -> DoryX86RegisterBytes {
    try vector(singleBits: singles.map(\.bitPattern), upper: upper)
  }

  private func vector(singleBits: [UInt32], upper: [UInt8]) throws -> DoryX86RegisterBytes {
    try .init(bytes: singleBits.flatMap { littleEndian($0, bytes: 4) } + upper,
      expectedByteCount: 32)
  }

  private func vector(doubles: [Double], upper: [UInt8]) throws -> DoryX86RegisterBytes {
    try vector(doubleBits: doubles.map(\.bitPattern), upper: upper)
  }

  private func vector(doubleBits: [UInt64], upper: [UInt8]) throws -> DoryX86RegisterBytes {
    try .init(bytes: doubleBits.flatMap { littleEndian($0, bytes: 8) } + upper,
      expectedByteCount: 32)
  }

  private func vector(qwords: [UInt64], upper: [UInt8]) throws -> DoryX86RegisterBytes {
    try .init(bytes: qwords.flatMap { littleEndian($0, bytes: 8) } + upper,
      expectedByteCount: 32)
  }

  private func littleEndian<T: FixedWidthInteger>(_ value: T, bytes: Int) -> [UInt8] {
    (0..<bytes).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
  }

  private func expectRetired(
    _ result: DoryX86InterpreterResult, code: [UInt8], at address: UInt64 = 0x1000
  ) throws {
    let expected = try decoder.decode(code, at: address, mode: .long64)
    #expect(result == .retired(expected), "\(code): \(result)")
  }
}

private final class ResidualMemory: DoryX86Memory, @unchecked Sendable {
  struct Read: Equatable { let address: UInt64; let byteCount: Int }
  let code: [UInt8]
  let source: [UInt8]?
  let sourceAddress: UInt64
  private(set) var reads: [Read] = []

  init(code: [UInt8], source: [UInt8]?, sourceAddress: UInt64 = 0x8000) {
    self.code = code
    self.source = source
    self.sourceAddress = sourceAddress
  }

  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    Array(code.prefix(maximumCount))
  }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    reads.append(.init(address: address, byteCount: byteCount))
    guard address == sourceAddress, let source, source.count == byteCount else {
      throw DoryX86MemoryError.pageFault(address: address, errorCode: 0)
    }
    return source
  }

  func write(at address: UInt64, bytes: [UInt8]) throws {
    throw DoryX86MemoryError.pageFault(address: address, errorCode: 2)
  }
}
