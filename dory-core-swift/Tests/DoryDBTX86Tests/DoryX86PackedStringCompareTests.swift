import Testing

@testable import DoryDBTX86

// Intel SSE4 Programming Reference, PCMPISTRI operation and Tables 5-1...5-8.
// https://www.intel.com/content/dam/develop/external/us/en/documents/d9156103-705230.pdf
@Suite struct DoryX86PackedStringCompareTests {
  private let profile = DoryX86CPUProfile(
    identifier: "test-only.pcmpistri",
    features: DoryX86CPUProfile.compatibleV1.features.union([.sse42]),
    physicalAddressBits: 40,
    linearAddressBits: 48,
    virtualTSCFrequencyHz: 1_000_000_000,
    allowingUnqualifiedSIMDAndExtendedState: true)

  @Test func equalAnyUsesSecondOperandResultBitsAndSelectsRequestedEnd() throws {
    let lhs: [UInt8] = [20, 40, 0]
    let rhs: [UInt8] = [7, 40, 9, 20, 0]
    for (immediate, expectedIndex): (UInt8, UInt64) in [(0x00, 1), (0x40, 3), (0x80, 1)] {
      var state = try initialState(lhs: lhs, rhs: rhs)
      state.registers.rcx = .max
      state.rflags = [
        .reservedOne, .carry, .parity, .auxiliaryCarry, .zero, .sign, .overflow,
        .direction,
      ]
      try retire(registerForm(immediate), state: &state)
      // Equal-any produces IntRes2 0b1010, indexed by operand 2.
      #expect(state.registers.rcx == expectedIndex)
      #expect(state.rflags == [.reservedOne, .direction, .carry, .zero, .sign])
    }
  }

  @Test func rangesHonorAllSignedUnsignedByteAndWordFormats() throws {
    let cases: [(UInt8, [UInt8], [UInt8])] = [
      (0x04, [10, 250, 0], [200, 0]),
      (0x06, [UInt8(bitPattern: -10), 10, 0], [UInt8(bitPattern: -5), 0]),
      (0x05, words([100, 60_000, 0]), words([50_000, 0])),
      (0x07, signedWords([-100, 100, 0]), signedWords([-50, 0])),
    ]
    for (immediate, lhs, rhs) in cases {
      var state = try initialState(lhs: lhs, rhs: rhs)
      try retire(registerForm(immediate), state: &state)
      #expect(state.registers.rcx == 0)
      #expect(state.rflags.contains(.carry))
      #expect(state.rflags.contains(.zero))
      #expect(state.rflags.contains(.sign))
      #expect(state.rflags.contains(.overflow))
      #expect(!state.rflags.contains(.parity))
      #expect(!state.rflags.contains(.auxiliaryCarry))
    }
  }

  @Test func equalEachAppliesTheArchitecturalInvalidElementOverride() throws {
    var state = try initialState(lhs: words([1, 2, 0]), rhs: words([1, 3, 0]))
    try retire(registerForm(0x49), state: &state)  // unsigned words, equal-each, MSB index
    // Elements 0 and 2...7 match: both invalid elements compare true.
    #expect(state.registers.rcx == 7)
    #expect(state.rflags.contains(.carry))
    #expect(state.rflags.contains(.zero))
    #expect(state.rflags.contains(.sign))
    #expect(state.rflags.contains(.overflow))
  }

  @Test func equalOrderedFindsSubstrings() throws {
    var ordinary = try initialState(
      lhs: Array("ab".utf8) + [0], rhs: Array("xaby".utf8) + [0])
    try retire(registerForm(0x0C), state: &ordinary)
    #expect(ordinary.registers.rcx == 1)
    #expect(ordinary.rflags.contains(.carry))
    #expect(!ordinary.rflags.contains(.overflow))
  }

  @Test func equalOrderedTailOnlyComparesPhysicallyAvailableElements() throws {
    // Intel Table 5-3 initializes IntRes1 to all ones, then compares only
    // i=0...UpperBound-j. At result bit 15, only operand-1 element zero is
    // compared; no synthetic operand-2 element exists beyond the register.
    let cases: [([UInt8], UInt64)] = [
      (Array(repeating: UInt8(ascii: "x"), count: 15) + [UInt8(ascii: "a")], 15),
      (Array(repeating: UInt8(ascii: "x"), count: 14) + Array("ab".utf8), 14),
    ]
    for (rhs, expectedIndex) in cases {
      var boundary = try initialState(lhs: Array("ab".utf8) + [0], rhs: rhs)
      try retire(registerForm(0x4C), state: &boundary)
      #expect(boundary.registers.rcx == expectedIndex)
      #expect(boundary.rflags.contains(.carry))
      #expect(boundary.rflags.contains(.sign))
      #expect(!boundary.rflags.contains(.zero))
      #expect(!boundary.rflags.contains(.overflow))
    }
  }

  @Test func polarityAndMaskedPolarityUseOperandTwoValidity() throws {
    let cases: [(UInt8, UInt64, Bool)] = [
      (0x00, 0, true),  // Positive: IntRes2 = 0001.
      (0x10, 1, false),  // Negative: IntRes2 = FFFE.
      (0x20, 0, true),  // Masked positive is unchanged.
      (0x30, 1, false),  // Masked negative: 0001 XOR valid mask 0011 = 0010.
    ]
    for (immediate, expectedIndex, expectedOverflow) in cases {
      var state = try initialState(lhs: [1, 0], rhs: [1, 2, 0])
      try retire(registerForm(immediate), state: &state)
      #expect(state.registers.rcx == expectedIndex)
      #expect(state.rflags.contains(.carry))
      #expect(state.rflags.contains(.overflow) == expectedOverflow)
    }
  }

  @Test func noMatchReturnsTheFormatElementCountAndDefinesAllSixFlags() throws {
    for (immediate, lhs, rhs, expectedIndex): (UInt8, [UInt8], [UInt8], UInt64) in [
      (0x00, Array(repeating: 7, count: 16), Array(repeating: 8, count: 16), 16),
      (0x01, words(Array(repeating: 7, count: 8)), words(Array(repeating: 8, count: 8)), 8),
    ] {
      var state = try initialState(lhs: lhs, rhs: rhs)
      state.rflags = [
        .reservedOne, .carry, .parity, .auxiliaryCarry, .zero, .sign, .overflow,
        .interruptEnable,
      ]
      try retire(registerForm(immediate), state: &state)
      #expect(state.registers.rcx == expectedIndex)
      #expect(state.rflags == [.reservedOne, .interruptEnable])
    }
  }

  @Test func memoryFormReadsTheCompleteOperandBeforePublishingFlagsOrIndex() throws {
    let bytes = memoryForm(0x00)
    let success = try PackedStringMemory(code: bytes, data: padded([1, 2, 0]))
    var succeeded = try initialState(lhs: [1, 0], rhs: [])
    let decoded = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: .long64)
    #expect(
      DoryX86Interpreter(profile: profile).step(
        state: &succeeded, memory: success, mode: .long64) == .retired(decoded))
    #expect(succeeded.registers.rcx == 0)
    #expect(success.dataReads == [.init(address: 0x2000, byteCount: 16)])

    let fault = try PackedStringMemory(
      code: bytes, data: padded([1, 2, 0]),
      readFault: .pageFault(address: 0x200F, errorCode: 5))
    var failed = try initialState(lhs: [1, 0], rhs: [])
    failed.registers.rcx = 0xA5A5_A5A5_A5A5_A5A5
    failed.rflags = [.reservedOne, .carry, .parity, .direction, .overflow]
    let before = failed
    #expect(
      DoryX86Interpreter(profile: profile).step(
        state: &failed, memory: fault, mode: .long64)
        == .exception(
          .init(
            kind: .pageFault, vector: 14, errorCode: 5,
            instructionPointer: 0x1000, linearAddress: 0x200F)))
    var expected = before
    expected.control.cr2 = 0x200F
    #expect(failed == expected)
    #expect(fault.dataReads == [.init(address: 0x2000, byteCount: 16)])

    let masked = try PackedStringMemory(
      code: bytes, data: padded([1, 2, 0]),
      readFault: .pageFault(address: 0x200F, errorCode: 5))
    var unavailable = try initialState(lhs: [1, 0], rhs: [])
    let unavailableBefore = unavailable
    #expect(
      DoryX86Interpreter(profile: .compatibleV1).step(
        state: &unavailable, memory: masked, mode: .long64)
        == .exception(
          .init(
            kind: .invalidOpcode, vector: 6, instructionPointer: 0x1000)))
    #expect(unavailable == unavailableBefore)
    #expect(masked.dataReads.isEmpty)
  }

  @Test func bothNativeTiersDeclineBeforeAnyArchitecturalEffect() throws {
    #if os(macOS) && arch(arm64)
      let bytes = registerForm(0x00)
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let executor = try DoryARM64BaselineExecutor(
          maximumCodeBytes: 16_384, profile: profile, optimization: optimization)
        let memory = try PackedStringMemory(code: bytes)
        var state = try initialState(lhs: [1, 0], rhs: [1, 0])
        let before = state
        #expect(
          try executor.executeSummary(
            byteProvider: { Array(bytes.prefix($0)) }, at: 0x1000,
            mode: .long64, addressSpaceID: 0, maximumInstructions: 1,
            state: &state, memory: memory) == nil)
        #expect(
          try executor.executeChainedSummary(
            byteProvider: { _, count in Array(bytes.prefix(count)) }, at: 0x1000,
            mode: .long64, addressSpaceID: 0, maximumInstructions: 1,
            state: &state, memory: memory) == nil)
        #expect(state == before)
        #expect(memory.dataReads.isEmpty && memory.writes == 0)
      }
    #endif
  }

  private func initialState(
    lhs: [UInt8], rhs: [UInt8]
  ) throws -> DoryX86ArchitecturalState {
    var floatingPoint = try DoryX86FloatingPointState()
    floatingPoint.ymm[0] = try .init(bytes: padded(lhs, to: 32), expectedByteCount: 32)
    floatingPoint.ymm[1] = try .init(bytes: padded(rhs, to: 32), expectedByteCount: 32)
    return try .init(
      registers: .init(rbx: 0x2000), rip: 0x1000,
      rflags: [.reservedOne], control: .init(cr4: 1 << 9),
      floatingPoint: floatingPoint)
  }

  private func retire(
    _ bytes: [UInt8], state: inout DoryX86ArchitecturalState
  ) throws {
    let memory = try PackedStringMemory(code: bytes)
    let decoded = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: .long64)
    #expect(
      DoryX86Interpreter(profile: profile).step(
        state: &state, memory: memory, mode: .long64) == .retired(decoded))
  }

  private func registerForm(_ immediate: UInt8) -> [UInt8] {
    [0x66, 0x0F, 0x3A, 0x63, 0xC1, immediate]  // PCMPISTRI xmm0,xmm1,imm8
  }

  private func memoryForm(_ immediate: UInt8) -> [UInt8] {
    [0x66, 0x0F, 0x3A, 0x63, 0x03, immediate]  // PCMPISTRI xmm0,[rbx],imm8
  }

  private func padded(_ bytes: [UInt8], to byteCount: Int = 16) -> [UInt8] {
    Array(bytes.prefix(byteCount)) + Array(repeating: 0, count: max(0, byteCount - bytes.count))
  }

  private func words(_ values: [UInt16]) -> [UInt8] {
    values.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)] }
  }

  private func signedWords(_ values: [Int16]) -> [UInt8] {
    words(values.map { UInt16(bitPattern: $0) })
  }
}

private struct PackedStringRead: Equatable {
  let address: UInt64
  let byteCount: Int
}

private final class PackedStringMemory: DoryX86Memory, @unchecked Sendable {
  private let backing: DoryX86ByteArrayMemory
  private let readFault: DoryX86MemoryError?
  private(set) var dataReads: [PackedStringRead] = []
  private(set) var writes = 0

  init(
    code: [UInt8], data: [UInt8] = Array(repeating: 0, count: 16),
    readFault: DoryX86MemoryError? = nil
  ) throws {
    backing = try DoryX86ByteArrayMemory(baseAddress: 0x1000, byteCount: 0x2000)
    self.readFault = readFault
    try backing.write(at: 0x1000, bytes: code)
    try backing.write(at: 0x2000, bytes: data)
  }

  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    try backing.instructionBytes(at: address, maximumCount: maximumCount)
  }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    if address == 0x2000 {
      dataReads.append(.init(address: address, byteCount: byteCount))
      if let readFault { throw readFault }
    }
    return try backing.read(at: address, byteCount: byteCount)
  }

  func validateRead(at address: UInt64, byteCount: Int) throws {
    if address == 0x2000, let readFault { throw readFault }
    try backing.validateRead(at: address, byteCount: byteCount)
  }

  func write(at address: UInt64, bytes: [UInt8]) throws {
    writes += 1
    try backing.write(at: address, bytes: bytes)
  }

  func validateWrite(at address: UInt64, byteCount: Int) throws {
    try backing.validateWrite(at: address, byteCount: byteCount)
  }
}
