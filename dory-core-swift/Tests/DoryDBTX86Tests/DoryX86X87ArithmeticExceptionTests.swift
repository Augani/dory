import Testing

@testable import DoryDBTX86

// Intel SDM Vol. 1 §§8.5.1 and 8.5.2: x87 arithmetic and comparison
// instructions retire with sticky status, but an unmasked numeric exception
// suppresses the destination, condition codes, and any requested stack pop.
@Suite struct DoryX86X87ArithmeticExceptionTests {
  @Test func quietNaNPropagatesWithoutInvalidWhileSignalingNaNHonorsIM() throws {
    let code: [UInt8] = [0xDE, 0xC1]  // FADDP ST(1), ST(0)

    var quiet = try binaryState(first: quietNaN, second: one, controlWord: 0x037E)
    try retire(&quiet, code: code)
    #expect(top(quiet) == 1)
    #expect(quiet.floatingPoint.x87StatusWord & 0x8081 == 0)
    #expect(quiet.floatingPoint.x87[1].bytes == quietNaN)
    #expect(tag(1, quiet) == 2)

    var masked = try binaryState(first: signalingNaN, second: one, controlWord: 0x037F)
    try retire(&masked, code: code)
    #expect(top(masked) == 1)
    #expect(masked.floatingPoint.x87StatusWord & 0x8081 == 1)
    #expect(masked.floatingPoint.x87[1].bytes == quietedSignalingNaN)
    #expect(tag(1, masked) == 2)

    var unmasked = try binaryState(first: signalingNaN, second: one, controlWord: 0x037E)
    let originalRegisters = unmasked.floatingPoint.x87
    let originalTags = unmasked.floatingPoint.x87TagWord
    try retire(&unmasked, code: code)
    #expect(top(unmasked) == 0)
    #expect(unmasked.floatingPoint.x87 == originalRegisters)
    #expect(unmasked.floatingPoint.x87TagWord == originalTags)
    #expect(unmasked.floatingPoint.x87StatusWord == 0x8081)
  }

  @Test func invalidFiniteArithmeticCommitsIndefiniteOnlyWhenMasked() throws {
    let code: [UInt8] = [0xDE, 0xC9]  // FMULP ST(1), ST(0)

    var masked = try binaryState(first: zero, second: infinity, controlWord: 0x037F)
    try retire(&masked, code: code)
    #expect(top(masked) == 1)
    #expect(masked.floatingPoint.x87[1].bytes == realIndefinite)
    #expect(masked.floatingPoint.x87StatusWord & 0x8081 == 1)

    var unmasked = try binaryState(first: zero, second: infinity, controlWord: 0x037E)
    let originalRegisters = unmasked.floatingPoint.x87
    let originalTags = unmasked.floatingPoint.x87TagWord
    try retire(&unmasked, code: code)
    #expect(unmasked.rip == 0x1002)
    #expect(top(unmasked) == 0)
    #expect(unmasked.floatingPoint.x87 == originalRegisters)
    #expect(unmasked.floatingPoint.x87TagWord == originalTags)
    #expect(unmasked.floatingPoint.x87StatusWord == 0x8081)
    #expect(unmasked.floatingPoint.x87Opcode == 0x06C9)
  }

  @Test func divideByZeroSuppressesUnmaskedResultAndPop() throws {
    let code: [UInt8] = [0xDE, 0xF9]  // FDIVP ST(1), ST(0)

    var masked = try binaryState(first: zero, second: one, controlWord: 0x037F)
    try retire(&masked, code: code)
    #expect(top(masked) == 1)
    #expect(masked.floatingPoint.x87[1].bytes == infinity)
    #expect(masked.floatingPoint.x87StatusWord & 0x8084 == 4)

    var unmasked = try binaryState(first: zero, second: one, controlWord: 0x037B)
    let originalRegisters = unmasked.floatingPoint.x87
    let originalTags = unmasked.floatingPoint.x87TagWord
    try retire(&unmasked, code: code)
    #expect(top(unmasked) == 0)
    #expect(unmasked.floatingPoint.x87 == originalRegisters)
    #expect(unmasked.floatingPoint.x87TagWord == originalTags)
    #expect(unmasked.floatingPoint.x87StatusWord == 0x8084)
  }

  @Test func finiteArithmeticPublishesPrecisionAndRoundingDirection() throws {
    let code: [UInt8] = [0xDE, 0xF9]  // FDIVP ST(1), ST(0)
    let three = binary80(significand: 0xC000_0000_0000_0000, exponent: 0x4000)
    let roundedThird = binary80(significand: 0xAAAA_AB00_0000_0000, exponent: 0x3FFD)

    // PC=24, round-to-nearest, all exceptions masked. 1/3 increments the
    // retained significand, so #P is sticky and C1 records the increment.
    var masked = try binaryState(first: three, second: one, controlWord: 0x007F)
    try retire(&masked, code: code)
    #expect(top(masked) == 1)
    #expect(masked.floatingPoint.x87[1].bytes == roundedThird)
    #expect(masked.floatingPoint.x87StatusWord & 0x0A20 == 0x0A20)

    // Unmasking #P suppresses both the result and FDIVP's pop while retaining
    // the exception summary and the same C1 rounding indication.
    var unmasked = try binaryState(first: three, second: one, controlWord: 0x005F)
    let originalRegisters = unmasked.floatingPoint.x87
    let originalTags = unmasked.floatingPoint.x87TagWord
    try retire(&unmasked, code: code)
    #expect(top(unmasked) == 0)
    #expect(unmasked.floatingPoint.x87 == originalRegisters)
    #expect(unmasked.floatingPoint.x87TagWord == originalTags)
    #expect(unmasked.floatingPoint.x87StatusWord == 0x82A0)

    // Truncation is still inexact, but it does not increment the retained
    // significand and therefore clears a previously set C1.
    var truncated = try binaryState(
      first: three, second: one, controlWord: 0x0C7F, statusWord: 0x0200)
    try retire(&truncated, code: code)
    #expect(truncated.floatingPoint.x87StatusWord & 0x0220 == 0x0020)
  }

  @Test func orderedAndUnorderedComparisonsDistinguishQuietAndSignalingNaNs() throws {
    let initialFlags: DoryX86RFLAGS = [
      .reservedOne, .interruptEnable, .overflow, .sign, .auxiliaryCarry, .carry,
    ]

    var ordered = try binaryState(
      first: quietNaN, second: one, controlWord: 0x037E,
      statusWord: 0x4100, rflags: initialFlags)
    try retire(&ordered, code: [0xD8, 0xD1])  // FCOM ST(1)
    #expect(ordered.rflags == initialFlags)
    #expect(ordered.floatingPoint.x87StatusWord == 0xC181)

    var unorderedQuiet = try binaryState(
      first: quietNaN, second: one, controlWord: 0x037E,
      rflags: initialFlags)
    try retire(&unorderedQuiet, code: [0xDB, 0xE9])  // FUCOMI ST, ST(1)
    #expect(unorderedQuiet.rflags == [.reservedOne, .interruptEnable, .zero, .parity, .carry])
    #expect(unorderedQuiet.floatingPoint.x87StatusWord & 0x8081 == 0)

    var unorderedSignaling = try binaryState(
      first: signalingNaN, second: one, controlWord: 0x037E,
      rflags: initialFlags)
    try retire(&unorderedSignaling, code: [0xDB, 0xE9])
    #expect(unorderedSignaling.rflags == initialFlags)
    #expect(unorderedSignaling.floatingPoint.x87StatusWord == 0x8081)
  }

  @Test func ftstUsesOrderedNaNExceptionRules() throws {
    let code: [UInt8] = [0xD9, 0xE4]
    var masked = try unaryState(quietNaN, controlWord: 0x037F)
    try retire(&masked, code: code)
    #expect(masked.floatingPoint.x87StatusWord == 0x4501)

    var unmasked = try unaryState(quietNaN, controlWord: 0x037E, statusWord: 0x4100)
    let originalRegister = unmasked.floatingPoint.x87[0]
    try retire(&unmasked, code: code)
    #expect(unmasked.floatingPoint.x87[0] == originalRegister)
    #expect(unmasked.floatingPoint.x87StatusWord == 0xC181)
  }

  @Test func squareRootInvalidWritesIndefiniteOnlyWhenMasked() throws {
    let invalidInputs = [
      binary80(
        significand: 0x8000_0000_0000_0000, exponent: 0x4001, negative: true),
      signalingNaN,
      binary80(significand: 1, exponent: 1),
    ]
    for input in invalidInputs {
      var masked = try unaryState(input, controlWord: 0x037F)
      try retire(&masked, code: [0xD9, 0xFA]) // FSQRT
      #expect(masked.floatingPoint.x87[0].bytes == realIndefinite)
      #expect(masked.floatingPoint.x87StatusWord & 0x8081 == 1)

      var unmasked = try unaryState(input, controlWord: 0x037E)
      let before = unmasked.floatingPoint
      try retire(&unmasked, code: [0xD9, 0xFA])
      #expect(unmasked.floatingPoint.x87 == before.x87)
      #expect(unmasked.floatingPoint.x87TagWord == before.x87TagWord)
      #expect(unmasked.floatingPoint.x87StatusWord & 0x8081 == 0x8081)
    }
  }

  private var zero: [UInt8] { binary80(significand: 0, exponent: 0) }
  private var one: [UInt8] {
    binary80(significand: 0x8000_0000_0000_0000, exponent: 0x3FFF)
  }
  private var infinity: [UInt8] {
    binary80(significand: 0x8000_0000_0000_0000, exponent: 0x7FFF)
  }
  private var quietNaN: [UInt8] {
    binary80(significand: 0xC000_0000_0000_1234, exponent: 0x7FFF)
  }
  private var signalingNaN: [UInt8] {
    binary80(significand: 0x8000_0000_0000_5678, exponent: 0x7FFF)
  }
  private var quietedSignalingNaN: [UInt8] {
    binary80(significand: 0xC000_0000_0000_5678, exponent: 0x7FFF)
  }
  private var realIndefinite: [UInt8] {
    binary80(significand: 0xC000_0000_0000_0000, exponent: 0x7FFF, negative: true)
  }

  private func binaryState(
    first: [UInt8], second: [UInt8], controlWord: UInt16,
    statusWord: UInt16 = 0, rflags: DoryX86RFLAGS = [.reservedOne]
  ) throws -> DoryX86ArchitecturalState {
    var floatingPoint = try DoryX86FloatingPointState(
      x87ControlWord: controlWord, x87StatusWord: statusWord,
      x87TagWord: tag(for: first) | tag(for: second) << 2 | 0xFFF0)
    floatingPoint.x87[0] = try register(first)
    floatingPoint.x87[1] = try register(second)
    return try architecturalState(floatingPoint, rflags: rflags)
  }

  private func unaryState(
    _ value: [UInt8], controlWord: UInt16, statusWord: UInt16 = 0
  ) throws -> DoryX86ArchitecturalState {
    var floatingPoint = try DoryX86FloatingPointState(
      x87ControlWord: controlWord, x87StatusWord: statusWord,
      x87TagWord: tag(for: value) | 0xFFFC)
    floatingPoint.x87[0] = try register(value)
    return try architecturalState(floatingPoint)
  }

  private func architecturalState(
    _ floatingPoint: DoryX86FloatingPointState,
    rflags: DoryX86RFLAGS = [.reservedOne]
  ) throws -> DoryX86ArchitecturalState {
    try .init(
      rip: 0x1000, rflags: rflags,
      cs: .init(selector: 0x28, attributes: 0xA09B, limit: .max),
      control: .init(cr0: 0x31), floatingPoint: floatingPoint)
  }

  private func retire(
    _ state: inout DoryX86ArchitecturalState, code: [UInt8]
  ) throws {
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code)
    let decoded = try DoryX86Decoder().decode(code, at: 0x1000, mode: .long64)
    #expect(
      DoryX86Interpreter().step(
        state: &state, memory: memory, mode: .long64) == .retired(decoded))
  }

  private func top(_ state: DoryX86ArchitecturalState) -> Int {
    Int(state.floatingPoint.x87StatusWord >> 11) & 7
  }

  private func tag(_ physical: Int, _ state: DoryX86ArchitecturalState) -> UInt16 {
    state.floatingPoint.x87TagWord >> UInt16(physical * 2) & 3
  }

  private func tag(for bytes: [UInt8]) -> UInt16 {
    DoryX86X87Transfer.binary80Class(bytes).tag
  }

  private func register(_ bytes: [UInt8]) throws -> DoryX86RegisterBytes {
    try .init(bytes: bytes, expectedByteCount: 10)
  }

  private func binary80(
    significand: UInt64, exponent: UInt16, negative: Bool = false
  ) -> [UInt8] {
    littleEndian(significand, count: 8)
      + littleEndian(UInt64(exponent | (negative ? 0x8000 : 0)), count: 2)
  }

  private func littleEndian(_ value: UInt64, count: Int) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
  }
}
