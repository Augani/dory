import Testing

@testable import DoryDBTX86

// Intel SDM092 Vol. 1 §§4.9.1.2, 4.9.2, and 8.5.2: #D is a
// pre-operation exception. A masked #D permits computation and lower-priority
// exceptions; an unmasked #D preserves operands and suppresses every later
// result, condition-code update, and requested pop.
@Suite struct DoryX86X87DenormalOperandTests {
  @Test func registerDenormalsHonorDMAndCanonicalizeOnlyMaskedResults() throws {
    let sources = [
      binary80(significand: 1, exponent: 0),
      binary80(significand: 0x8000_0000_0000_0000, exponent: 0),
    ]
    for source in sources {
      let expected = DoryX86ExtendedFloat(bytes: source).bytes()

      var masked = try binaryState(first: source, second: one, controlWord: 0x037F)
      try retire(&masked, code: [0xDE, 0xC9])  // FMULP ST(1), ST(0)
      #expect(top(masked) == 1)
      #expect(masked.floatingPoint.x87[1].bytes == expected)
      #expect(tag(1, masked) == DoryX86X87Transfer.binary80Class(expected).tag)
      #expect(masked.floatingPoint.x87StatusWord & 0x82E2 == 0x0002)

      var unmasked = try binaryState(
        first: source, second: one, controlWord: 0x037D, statusWord: 0x0200)
      let before = unmasked.floatingPoint
      try retire(&unmasked, code: [0xDE, 0xC9])
      #expect(top(unmasked) == 0)
      #expect(unmasked.floatingPoint.x87 == before.x87)
      #expect(unmasked.floatingPoint.x87TagWord == before.x87TagWord)
      #expect(unmasked.floatingPoint.x87StatusWord == 0x8082)
    }
  }

  @Test func unmaskedDenormalPreemptsWouldBePrecision() throws {
    let denormal = binary80(significand: 1, exponent: 0)

    var masked = try binaryState(first: one, second: denormal, controlWord: 0x037F)
    try retire(&masked, code: [0xD8, 0xC1])  // FADD ST(0), ST(1)
    #expect(masked.floatingPoint.x87[0].bytes == one)
    #expect(masked.floatingPoint.x87StatusWord & 0x82E2 == 0x0022)

    var unmasked = try binaryState(first: one, second: denormal, controlWord: 0x037D)
    let before = unmasked.floatingPoint
    try retire(&unmasked, code: [0xD8, 0xC1])
    #expect(unmasked.floatingPoint.x87 == before.x87)
    #expect(unmasked.floatingPoint.x87TagWord == before.x87TagWord)
    #expect(unmasked.floatingPoint.x87StatusWord == 0x8082)
  }

  @Test func memorySubnormalsKeepTheirSourceFormatClassification() throws {
    let forms: [(opcode: UInt8, source: [UInt8], expected: [UInt8])] = [
      (
        0xD8, littleEndian(1, count: 4),
        DoryX86ExtendedFloat(Double(Float(bitPattern: 1))).bytes()
      ),
      (
        0xDC, littleEndian(1, count: 8),
        DoryX86ExtendedFloat(Double(bitPattern: 1)).bytes()
      ),
    ]
    for form in forms {
      var masked = try unaryState(zero, controlWord: 0x037F, rax: 0x1010)
      try retire(&masked, code: [form.opcode, 0], operand: form.source)
      #expect(masked.floatingPoint.x87[0].bytes == form.expected)
      #expect(masked.floatingPoint.x87StatusWord & 0x82E2 == 0x0002)

      var unmasked = try unaryState(zero, controlWord: 0x037D, rax: 0x1010)
      let before = unmasked.floatingPoint
      try retire(&unmasked, code: [form.opcode, 0], operand: form.source)
      #expect(unmasked.floatingPoint.x87 == before.x87)
      #expect(unmasked.floatingPoint.x87TagWord == before.x87TagWord)
      #expect(unmasked.floatingPoint.x87StatusWord == 0x8082)
    }
  }

  @Test func denormalComparisonUpdatesCodesAndPopsOnlyWhenMasked() throws {
    let denormal = binary80(significand: 1, exponent: 0)

    var masked = try binaryState(first: zero, second: denormal, controlWord: 0x037F)
    try retire(&masked, code: [0xD8, 0xD9])  // FCOMP ST(1)
    #expect(top(masked) == 1)
    #expect(masked.floatingPoint.x87StatusWord & 0x4502 == 0x0102)

    var unmasked = try binaryState(
      first: zero, second: denormal, controlWord: 0x037D, statusWord: 0x4500)
    let before = unmasked.floatingPoint
    try retire(&unmasked, code: [0xD8, 0xD9])
    #expect(top(unmasked) == 0)
    #expect(unmasked.floatingPoint.x87 == before.x87)
    #expect(unmasked.floatingPoint.x87TagWord == before.x87TagWord)
    #expect(unmasked.floatingPoint.x87StatusWord == 0xC582)
  }

  @Test func memorySignalingNaNKeepsInvalidClassificationWhenWidened() throws {
    let source = littleEndian(0x7F80_0001, count: 4)
    let quieted = DoryX86X87Transfer.load(bytes: source, format: .float32).bytes

    var masked = try unaryState(one, controlWord: 0x037F, rax: 0x1010)
    try retire(&masked, code: [0xD8, 0], operand: source)
    #expect(masked.floatingPoint.x87[0].bytes == quieted)
    #expect(masked.floatingPoint.x87StatusWord & 0x8081 == 1)

    var unmasked = try unaryState(one, controlWord: 0x037E, rax: 0x1010)
    let before = unmasked.floatingPoint
    try retire(&unmasked, code: [0xD8, 0], operand: source)
    #expect(unmasked.floatingPoint.x87 == before.x87)
    #expect(unmasked.floatingPoint.x87TagWord == before.x87TagWord)
    #expect(unmasked.floatingPoint.x87StatusWord == 0x8081)
  }

  private var zero: [UInt8] { binary80(significand: 0, exponent: 0) }
  private var one: [UInt8] {
    binary80(significand: 0x8000_0000_0000_0000, exponent: 0x3FFF)
  }

  private func binaryState(
    first: [UInt8], second: [UInt8], controlWord: UInt16,
    statusWord: UInt16 = 0
  ) throws -> DoryX86ArchitecturalState {
    var floatingPoint = try DoryX86FloatingPointState(
      x87ControlWord: controlWord, x87StatusWord: statusWord,
      x87TagWord: tag(for: first) | tag(for: second) << 2 | 0xFFF0)
    floatingPoint.x87[0] = try register(first)
    floatingPoint.x87[1] = try register(second)
    return try architecturalState(floatingPoint)
  }

  private func unaryState(
    _ value: [UInt8], controlWord: UInt16, rax: UInt64 = 0
  ) throws -> DoryX86ArchitecturalState {
    var floatingPoint = try DoryX86FloatingPointState(
      x87ControlWord: controlWord, x87TagWord: tag(for: value) | 0xFFFC)
    floatingPoint.x87[0] = try register(value)
    return try architecturalState(floatingPoint, rax: rax)
  }

  private func architecturalState(
    _ floatingPoint: DoryX86FloatingPointState, rax: UInt64 = 0
  ) throws -> DoryX86ArchitecturalState {
    try .init(
      registers: .init(rax: rax), rip: 0x1000,
      cs: .init(selector: 0x28, attributes: 0xA09B, limit: .max),
      ds: .init(selector: 0x30, attributes: 0x93, limit: .max),
      control: .init(cr0: 0x31), floatingPoint: floatingPoint)
  }

  private func retire(
    _ state: inout DoryX86ArchitecturalState,
    code: [UInt8],
    operand: [UInt8] = []
  ) throws {
    var bytes = [UInt8](repeating: 0, count: max(32, 16 + operand.count))
    bytes.replaceSubrange(0..<code.count, with: code)
    bytes.replaceSubrange(16..<(16 + operand.count), with: operand)
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: bytes)
    let decoded = try DoryX86Decoder().decode(code, at: 0x1000, mode: .long64)
    #expect(
      DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
        == .retired(decoded))
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

  private func binary80(significand: UInt64, exponent: UInt16) -> [UInt8] {
    littleEndian(significand, count: 8) + littleEndian(UInt64(exponent), count: 2)
  }

  private func littleEndian(_ value: UInt64, count: Int) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
  }
}
