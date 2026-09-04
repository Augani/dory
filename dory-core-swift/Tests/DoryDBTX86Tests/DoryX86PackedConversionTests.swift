import Testing

@testable import DoryDBTX86

// Intel SDM Vol. 2A CVTTPD2DQ/CVTPD2DQ/CVTDQ2PD; Vol. 1 §11.5.3:
// https://cdrdv2-public.intel.com/812383/253666-sdm-vol-2a.pdf
// https://cdrdv2-public.intel.com/835781/325462-sdm-vol-1-2abcd-3abcd-4.pdf
@Suite struct DoryX86PackedConversionTests {
  @Test func mandatoryPrefixesSelectTheCorrectDirectionAndRounding() throws {
    for mode: DoryX86ExecutionMode in [.real16, .protected16, .protected32, .long64] {
      for prefix: UInt8 in [0x66, 0xF2, 0xF3] {
        let instruction = try DoryX86Decoder().decode(code(prefix), at: 0x1000, mode: mode)
        let expected: DoryX86InstructionOperation = prefix == 0xF3
          ? .convertPackedDwordToDouble(destination: 0, source: .register(1))
          : .convertPackedDoubleToDword(truncated: prefix == 0x66,
            destination: 0, source: .register(1))
        #expect(instruction.operation == expected)
      }
      #expect(throws: DoryX86DecodeError.self) {
        try DoryX86Decoder().decode([0x0F, 0xE6, 0xC1], at: 0x1000, mode: mode)
      }
    }
  }

  @Test func maskedInvalidInputsReturnIntegerIndefiniteWithoutHostTraps() throws {
    let invalid: [UInt64] = [
      0x7FF8_0000_0000_0001, 0x7FF0_0000_0000_0001,
      Double.infinity.bitPattern, (-Double.infinity).bitPattern,
      Double(2_147_483_648).bitPattern, Double(-2_147_483_649).bitPattern,
      Double.greatestFiniteMagnitude.bitPattern,
    ]
    for prefix: UInt8 in [0x66, 0xF2] {
      for bits in invalid {
        var state = try state(source: words64([bits, Double(42).bitPattern]))
        let before = state
        let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code(prefix))
        let result = DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
        try expectRetired(result, code: code(prefix))
        #expect(lowDwords(state) == [0x8000_0000, 42])
        #expect(state.floatingPoint.mxcsr == before.floatingPoint.mxcsr | 1)
        expectPreservedOutsideDestination(state, before: before)
      }
    }
  }

  @Test func roundedConversionObeysAllMXCSRModesAndTruncationIgnoresThem() throws {
    let rounded: [[Int32]] = [[2, -2], [1, -2], [2, -1], [1, -1]]
    for prefix: UInt8 in [0x66, 0xF2] {
      for rounding in 0..<4 {
        var state = try state(source: words64([Double(1.5).bitPattern, Double(-1.5).bitPattern]),
          mxcsr: 0x1F80 | UInt32(rounding << 13))
        let before = state
        let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code(prefix))
        try expectRetired(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64),
          code: code(prefix))
        let expected: [Int32] = prefix == 0x66 ? [1, -1] : rounded[rounding]
        #expect(lowDwords(state) == expected.map(UInt32.init(bitPattern:)))
        #expect(state.floatingPoint.mxcsr == before.floatingPoint.mxcsr | (1 << 5))
        expectPreservedOutsideDestination(state, before: before)
      }
    }
  }

  @Test func signedRangeChecksApplyAfterRoundingAndDoNotFlagTheValidMinimum() throws {
    let cases: [(Double, UInt32, UInt32, UInt32)] = [
      (-2_147_483_648.0, 0, 0x8000_0000, 0),
      (2_147_483_647.0, 0, 0x7FFF_FFFF, 0),
      (2_147_483_647.5, 0, 0x8000_0000, 1),
      (2_147_483_647.5, 3, 0x7FFF_FFFF, 1 << 5),
      (-2_147_483_648.5, 0, 0x8000_0000, 1 << 5),
      (-2_147_483_648.5, 1, 0x8000_0000, 1),
      (2.5, 0, 2, 1 << 5), (3.5, 0, 4, 1 << 5),
    ]
    for (value, rounding, expected, flags) in cases {
      var state = try state(source: words64([value.bitPattern, 0]),
        mxcsr: 0x1F80 | (rounding << 13))
      let beforeMXCSR = state.floatingPoint.mxcsr
      let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code(0xF2))
      try expectRetired(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64),
        code: code(0xF2))
      #expect(lowDwords(state) == [expected, 0])
      #expect(state.floatingPoint.mxcsr == beforeMXCSR | flags)
    }
  }

  @Test func signedDwordsConvertExactlyToDoublesWithoutChangingMXCSR() throws {
    for values: [Int32] in [[.min, .max], [-1, 0], [16_777_217, -16_777_217]] {
      for rounding: UInt32 in 0..<4 {
        var state = try state(source: words32(values.map(UInt32.init(bitPattern:))),
          mxcsr: (rounding << 13) | 0x21)
        let before = state
        let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code(0xF3))
        try expectRetired(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64),
          code: code(0xF3))
        #expect(Array(state.floatingPoint.ymm[0].bytes.prefix(16)) == words64(values.map { Double($0).bitPattern }))
        #expect(state.floatingPoint.mxcsr == before.floatingPoint.mxcsr)
        #expect(Array(state.floatingPoint.ymm[0].bytes.suffix(16)) == Array(repeating: 0xA5, count: 16))
        #expect(state.floatingPoint.ymm[1] == before.floatingPoint.ymm[1])
        #expect(state.rflags == before.rflags)
      }
    }
  }

  @Test func denormalsRespectDAZWithoutReportingDenormalExceptions() throws {
    for daz in [false, true] {
      for prefix: UInt8 in [0x66, 0xF2] {
        var state = try state(source: words64([1, 0x8000_0000_0000_0001]),
          mxcsr: 0x1F80 | (2 << 13) | (daz ? 1 << 6 : 0))
        let beforeMXCSR = state.floatingPoint.mxcsr
        let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code(prefix))
        try expectRetired(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64),
          code: code(prefix))
        #expect(lowDwords(state) == [!daz && prefix == 0xF2 ? 1 : 0, 0])
        #expect(state.floatingPoint.mxcsr == beforeMXCSR | (daz ? 0 : 1 << 5))
        #expect(state.floatingPoint.mxcsr & (1 << 1) == 0)
      }
    }
  }

  @Test func unmaskedNumericFaultsPublishOnlyStickyStatusBeforeXMOrUD() throws {
    let cases: [(UInt64, UInt64, UInt32, UInt32)] = [
      (Double.nan.bitPattern, Double(1.5).bitPattern, 0x1F80 & ~(1 << 7), 1),
      (Double(1.5).bitPattern, Double(2).bitPattern, 0x1F80 & ~(1 << 12), 1 << 5),
      (Double.nan.bitPattern, Double(1.5).bitPattern, 0x1F80 & ~(1 << 12), 1 | (1 << 5)),
      (Double.nan.bitPattern, Double(1.5).bitPattern, 0, 1),
    ]
    for prefix: UInt8 in [0x66, 0xF2] {
      for supportsXM in [false, true] {
        for (first, second, masks, flags) in cases {
          var state = try state(source: words64([first, second]), mxcsr: masks | (1 << 2),
            supportsXM: supportsXM)
          let before = state
          let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code(prefix))
          let snapshot = memory.snapshot()
          #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
            == .exception(.init(kind: supportsXM ? .simdFloatingPoint : .invalidOpcode,
              vector: supportsXM ? 19 : 6, instructionPointer: 0x1000)))
          var expected = before
          expected.floatingPoint.mxcsr |= flags
          #expect(state == expected)
          #expect(memory.snapshot() == snapshot)
        }
      }
    }
  }

  @Test func oldStickyFlagsDoNotRaiseNewFaultsForAnExactConversion() throws {
    for prefix: UInt8 in [0x66, 0xF2] {
      var state = try state(source: words64([Double(42).bitPattern, Double(-42).bitPattern]), mxcsr: 0x21)
      let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code(prefix))
      try expectRetired(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64),
        code: code(prefix))
      #expect(lowDwords(state) == [42, UInt32(bitPattern: -42)])
      #expect(state.floatingPoint.mxcsr == 0x21)
    }
  }

  @Test func dwordSourceReadsExactlyEightBytesAtTheMappedPageEnd() throws {
    let physical = try pagedMemory()
    let bytes: [UInt8] = [0xF3, 0x0F, 0xE6, 0x03]
    try physical.write(at: 0x1000, bytes: bytes)
    try physical.write(at: 0x1FF8, bytes: words32([0x8000_0000, 0x7FFF_FFFF]))
    var state = try pagedState(sourceAddress: 0x1FF8)
    let before = state
    let paging = DoryX86PagingUnit()
    try expectRetired(DoryX86Interpreter().step(state: &state, memory: physical, mode: .long64,
      pagingUnit: paging), code: bytes)
    #expect(Array(state.floatingPoint.ymm[0].bytes.prefix(16))
      == words64([Double(Int32.min).bitPattern, Double(Int32.max).bitPattern]))
    #expect(state.floatingPoint.mxcsr == before.floatingPoint.mxcsr)
    #expect(state.control.cr2 == before.control.cr2)
    #expect(Array(state.floatingPoint.ymm[0].bytes.suffix(16)) == Array(repeating: 0xA5, count: 16))
  }

  @Test func memoryFaultsAndAlignmentFailuresPreserveDestinationAndNumericStatus() throws {
    let cases: [(UInt8, UInt64, DoryX86Exception)] = [
      (0x66, 0x2000, .init(kind: .pageFault, vector: 14, errorCode: 4,
        instructionPointer: 0x1000, linearAddress: 0x2000)),
      (0xF2, 0x2000, .init(kind: .pageFault, vector: 14, errorCode: 4,
        instructionPointer: 0x1000, linearAddress: 0x2000)),
      (0xF3, 0x1FFC, .init(kind: .pageFault, vector: 14, errorCode: 4,
        instructionPointer: 0x1000, linearAddress: 0x2000)),
      (0x66, 0x1FF8, .init(kind: .generalProtection, vector: 13, errorCode: 0,
        instructionPointer: 0x1000)),
      (0xF2, 0x1FF8, .init(kind: .generalProtection, vector: 13, errorCode: 0,
        instructionPointer: 0x1000)),
    ]
    for (prefix, sourceAddress, exception) in cases {
      let physical = try pagedMemory()
      try physical.write(at: 0x1000, bytes: [prefix, 0x0F, 0xE6, 0x03])
      try physical.write(at: 0x1FF8, bytes: words64([Double.nan.bitPattern]))
      var state = try pagedState(sourceAddress: sourceAddress)
      var expected = state
      if exception.kind == .pageFault { expected.control.cr2 = 0x2000 }
      #expect(DoryX86Interpreter().step(state: &state, memory: physical, mode: .long64,
        pagingUnit: .init()) == .exception(exception))
      #expect(state == expected)
    }
  }

  @Test func bothNativeTiersDeclineTheseConversionsBeforeTheInterpreterExecutesThem() throws {
    #if arch(arm64)
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        for prefix: UInt8 in [0x66, 0xF2, 0xF3] {
          var state = try state(source: prefix == 0xF3 ? words32([1, 2]) : words64([Double(1).bitPattern, Double(2).bitPattern]))
          let before = state
          let bytes = code(prefix)
          let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: bytes)
          let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 16384, optimization: optimization)
          #expect(try executor.executeSummary(byteProvider: { Array(bytes.prefix($0)) },
            at: 0x1000, mode: .long64, addressSpaceID: 0, maximumInstructions: 1,
            state: &state, memory: memory) == nil)
          #expect(state == before)
          #expect(memory.snapshot() == bytes)
          try expectRetired(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64), code: bytes)
        }
      }
    #endif
  }

  private func code(_ prefix: UInt8) -> [UInt8] { [prefix, 0x0F, 0xE6, 0xC1] }

  private func state(source: [UInt8], mxcsr: UInt32 = 0x1F80, supportsXM: Bool = true) throws
    -> DoryX86ArchitecturalState {
    var floatingPoint = try DoryX86FloatingPointState(mxcsr: mxcsr)
    floatingPoint.ymm[0] = try .init(bytes: Array(repeating: 0xA5, count: 32), expectedByteCount: 32)
    floatingPoint.ymm[1] = try .init(bytes: source + Array(repeating: 0x5A, count: 32 - source.count),
      expectedByteCount: 32)
    return try .init(registers: .init(rax: 0x1122, rbx: 0x2000), rip: 0x1000,
      rflags: [.reservedOne, .carry, .overflow],
      cs: .init(selector: 3, attributes: 0xA0FB, limit: .max),
      control: .init(cr0: 1, cr2: 0x1234, cr4: (1 << 9) | (supportsXM ? 1 << 10 : 0)),
      floatingPoint: floatingPoint)
  }

  private func pagedState(sourceAddress: UInt64) throws -> DoryX86ArchitecturalState {
    var result = try state(source: [])
    result.registers.rbx = sourceAddress
    result.control.cr0 |= 1 << 31
    result.control.cr3 = 0x9000
    result.control.cr4 |= 1 << 5
    result.control.efer = (1 << 10) | (1 << 11)
    return result
  }

  private func pagedMemory() throws -> DoryX86ByteArrayMemory {
    let result = try DoryX86ByteArrayMemory(byteCount: 0x10000)
    for (address, value): (UInt64, UInt64) in [
      (0x9000, 0xA007), (0xA000, 0xB007), (0xB000, 0xC007), (0xC008, 0x1007),
    ] { try result.writeScalar(at: address, value: value, byteCount: 8) }
    return result
  }

  private func words64(_ values: [UInt64]) -> [UInt8] {
    values.flatMap { value in (0..<8).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
  }

  private func words32(_ values: [UInt32]) -> [UInt8] {
    values.flatMap { value in (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
  }

  private func lowDwords(_ state: DoryX86ArchitecturalState) -> [UInt32] {
    let bytes = state.floatingPoint.ymm[0].bytes
    return (0..<2).map { lane in
      (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[lane * 4 + $1]) << ($1 * 8) }
    }
  }

  private func expectRetired(_ result: DoryX86InterpreterResult, code: [UInt8]) throws {
    let instruction = try DoryX86Decoder().decode(code, at: 0x1000, mode: .long64)
    #expect(result == .retired(instruction))
  }

  private func expectPreservedOutsideDestination(_ state: DoryX86ArchitecturalState,
    before: DoryX86ArchitecturalState) {
    #expect(state.rip == 0x1004)
    #expect(state.registers == before.registers && state.rflags == before.rflags)
    #expect(state.control == before.control)
    #expect(state.floatingPoint.ymm[1] == before.floatingPoint.ymm[1])
    #expect(Array(state.floatingPoint.ymm[0].bytes[8..<16]) == Array(repeating: 0, count: 8))
    #expect(Array(state.floatingPoint.ymm[0].bytes.suffix(16)) == Array(repeating: 0xA5, count: 16))
  }
}
