import Testing

@testable import DoryDBTX86

// Intel SDM Vol. 2A FXTRACT and FSCALE:
// https://cdrdv2-public.intel.com/835757/325383-sdm-vol-2abcd.pdf
@Suite struct DoryX86X87ExactSpecialOperationTests {
  @Test func extractKeepsWideFiniteAndDenormalPayloadsInBinary80Order() throws {
    let wide = binary80(0xFEDC_BA98_7654_3210, 0x6000, negative: true)
    var finite = try unaryState(wide, statusWord: 0x0200)
    try retire(&finite, code: [0xD9, 0xF4])

    #expect(top(finite) == 7)
    #expect(
      finite.floatingPoint.x87[7].bytes
        == binary80(0xFEDC_BA98_7654_3210, 0x3FFF, negative: true))
    #expect(finite.floatingPoint.x87[0].bytes == DoryX86ExtendedFloat(Int64(8193)).bytes())
    #expect(finite.floatingPoint.x87StatusWord & 0x0200 == 0)
    #expect(tag(7, finite) == 0 && tag(0, finite) == 0)

    // 3 * 2^-16445 normalizes to 1.5 * 2^-16444. FXTRACT must report
    // the normalized exponent while retaining all significand bits.
    let denormal = binary80(3, 0, negative: true)
    var masked = try unaryState(denormal)
    try retire(&masked, code: [0xD9, 0xF4])
    #expect(top(masked) == 7)
    #expect(
      masked.floatingPoint.x87[7].bytes
        == binary80(0xC000_0000_0000_0000, 0x3FFF, negative: true))
    #expect(
      masked.floatingPoint.x87[0].bytes
        == DoryX86ExtendedFloat(Int64(-16_444)).bytes())
    #expect(masked.floatingPoint.x87StatusWord & 0x8082 == 2)

    var unmasked = try unaryState(denormal, controlWord: 0x037D)
    let before = unmasked.floatingPoint
    try retire(&unmasked, code: [0xD9, 0xF4])
    expectSuppressed(unmasked, from: before, exception: 2)
  }

  @Test func extractZeroInfinityAndNaNsHonorStatusStackAndPayloadRules() throws {
    let negativeZero = binary80(0, 0, negative: true)
    var maskedZero = try unaryState(negativeZero)
    try retire(&maskedZero, code: [0xD9, 0xF4])
    #expect(top(maskedZero) == 7)
    #expect(maskedZero.floatingPoint.x87[7].bytes == negativeZero)
    #expect(maskedZero.floatingPoint.x87[0].bytes == negativeInfinity)
    #expect(maskedZero.floatingPoint.x87StatusWord & 0x8084 == 4)

    var unmaskedZero = try unaryState(negativeZero, controlWord: 0x037B)
    let zeroBefore = unmaskedZero.floatingPoint
    try retire(&unmaskedZero, code: [0xD9, 0xF4])
    expectSuppressed(unmaskedZero, from: zeroBefore, exception: 4)

    var infinity = try unaryState(negativeInfinity)
    try retire(&infinity, code: [0xD9, 0xF4])
    #expect(top(infinity) == 7)
    #expect(infinity.floatingPoint.x87[7].bytes == negativeInfinity)
    #expect(infinity.floatingPoint.x87[0].bytes == positiveInfinity)
    #expect(infinity.floatingPoint.x87StatusWord & 0x8085 == 0)

    var quiet = try unaryState(quietNaN)
    try retire(&quiet, code: [0xD9, 0xF4])
    #expect(top(quiet) == 7)
    #expect(quiet.floatingPoint.x87[7].bytes == quietNaN)
    #expect(quiet.floatingPoint.x87[0].bytes == quietNaN)
    #expect(quiet.floatingPoint.x87StatusWord & 0x8081 == 0)

    for (source, result) in [
      (signalingNaN, quietedSignalingNaN),
      (unsupported, indefinite),
    ] {
      var masked = try unaryState(source)
      try retire(&masked, code: [0xD9, 0xF4])
      #expect(top(masked) == 7)
      #expect(masked.floatingPoint.x87[7].bytes == result)
      #expect(masked.floatingPoint.x87[0].bytes == result)
      #expect(masked.floatingPoint.x87StatusWord & 0x8081 == 1)

      var unmasked = try unaryState(source, controlWord: 0x037E)
      let before = unmasked.floatingPoint
      try retire(&unmasked, code: [0xD9, 0xF4])
      expectSuppressed(unmasked, from: before, exception: 1)
    }
  }

  @Test func scaleImplementsNonFiniteResultTableWithoutHostNarrowing() throws {
    let negativeWide = binary80(0xFEDC_BA98_7654_3210, 0x6000, negative: true)
    let negativeZero = binary80(0, 0, negative: true)
    let cases: [(first: [UInt8], second: [UInt8], result: [UInt8], invalid: Bool)] = [
      (negativeWide, negativeInfinity, negativeZero, false),
      (negativeWide, positiveInfinity, negativeInfinity, false),
      (negativeZero, negativeInfinity, negativeZero, false),
      (negativeZero, positiveInfinity, indefinite, true),
      (negativeInfinity, negativeInfinity, indefinite, true),
      (negativeInfinity, positiveInfinity, negativeInfinity, false),
    ]
    for item in cases {
      var state = try binaryState(item.first, item.second, statusWord: 0x0200)
      let source = state.floatingPoint.x87[1]
      try retire(&state, code: [0xD9, 0xFD])
      #expect(top(state) == 0)
      #expect(state.floatingPoint.x87[0].bytes == item.result)
      #expect(state.floatingPoint.x87[1] == source)
      #expect(state.floatingPoint.x87StatusWord & 0x8281 == (item.invalid ? 1 : 0))
      #expect(tag(0, state) == (item.result == negativeZero ? 1 : 2))
    }

    for operands in [
      (negativeZero, positiveInfinity),
      (negativeInfinity, negativeInfinity),
    ] {
      var state = try binaryState(operands.0, operands.1, controlWord: 0x037E)
      let before = state.floatingPoint
      try retire(&state, code: [0xD9, 0xFD])
      expectSuppressed(state, from: before, exception: 1)
    }
  }

  @Test func scaleQuietensNaNsRejectsUnsupportedAndPublishesDenormals() throws {
    var quiet = try binaryState(
      DoryX86ExtendedFloat.one.bytes(), quietNaN,
      statusWord: 0x0200)
    try retire(&quiet, code: [0xD9, 0xFD])
    #expect(quiet.floatingPoint.x87[0].bytes == quietNaN)
    #expect(quiet.floatingPoint.x87StatusWord & 0x8281 == 0)

    for (first, second, result) in [
      (DoryX86ExtendedFloat.one.bytes(), signalingNaN, quietedSignalingNaN),
      (quietNaN, signalingNaN, quietNaN),
      (DoryX86ExtendedFloat.one.bytes(), unsupported, indefinite),
    ] {
      var masked = try binaryState(first, second)
      try retire(&masked, code: [0xD9, 0xFD])
      #expect(masked.floatingPoint.x87[0].bytes == result)
      #expect(masked.floatingPoint.x87StatusWord & 0x8081 == 1)
    }

    var unmasked = try binaryState(
      DoryX86ExtendedFloat.one.bytes(), signalingNaN,
      controlWord: 0x037E)
    let invalidBefore = unmasked.floatingPoint
    try retire(&unmasked, code: [0xD9, 0xFD])
    expectSuppressed(unmasked, from: invalidBefore, exception: 1)

    let denormal = binary80(1, 0)
    var maskedScale = try binaryState(DoryX86ExtendedFloat.one.bytes(), denormal)
    try retire(&maskedScale, code: [0xD9, 0xFD])
    #expect(maskedScale.floatingPoint.x87[0].bytes == DoryX86ExtendedFloat.one.bytes())
    #expect(maskedScale.floatingPoint.x87StatusWord & 0x8082 == 2)

    var maskedValue = try binaryState(denormal, DoryX86ExtendedFloat.one.bytes())
    try retire(&maskedValue, code: [0xD9, 0xFD])
    #expect(maskedValue.floatingPoint.x87[0].bytes == binary80(2, 0))
    #expect(maskedValue.floatingPoint.x87StatusWord & 0x8082 == 2)

    var unmaskedDenormal = try binaryState(
      DoryX86ExtendedFloat.one.bytes(), denormal,
      controlWord: 0x037D)
    let denormalBefore = unmaskedDenormal.floatingPoint
    try retire(&unmaskedDenormal, code: [0xD9, 0xFD])
    expectSuppressed(unmaskedDenormal, from: denormalBefore, exception: 2)
  }

  private var positiveInfinity: [UInt8] {
    binary80(0x8000_0000_0000_0000, 0x7FFF)
  }
  private var negativeInfinity: [UInt8] {
    binary80(0x8000_0000_0000_0000, 0x7FFF, negative: true)
  }
  private var quietNaN: [UInt8] {
    binary80(0xC000_0000_0000_1234, 0x7FFF, negative: true)
  }
  private var signalingNaN: [UInt8] {
    binary80(0x8000_0000_0000_5678, 0x7FFF)
  }
  private var quietedSignalingNaN: [UInt8] {
    binary80(0xC000_0000_0000_5678, 0x7FFF)
  }
  private var unsupported: [UInt8] {
    binary80(0x4000_0000_0000_9ABC, 0x4000, negative: true)
  }
  private var indefinite: [UInt8] {
    binary80(0xC000_0000_0000_0000, 0x7FFF, negative: true)
  }

  private func binary80(
    _ significand: UInt64, _ exponent: UInt16, negative: Bool = false
  ) -> [UInt8] {
    (0..<8).map { UInt8(truncatingIfNeeded: significand >> ($0 * 8)) }
      + [
        UInt8(truncatingIfNeeded: exponent),
        UInt8(truncatingIfNeeded: exponent >> 8) | (negative ? 0x80 : 0),
      ]
  }

  private func unaryState(
    _ value: [UInt8], controlWord: UInt16 = 0x037F, statusWord: UInt16 = 0
  ) throws -> DoryX86ArchitecturalState {
    var floatingPoint = try DoryX86FloatingPointState(
      x87ControlWord: controlWord, x87StatusWord: statusWord,
      x87TagWord: classTag(value) | 0xFFFC)
    floatingPoint.x87[0] = try register(value)
    return try architecturalState(floatingPoint)
  }

  private func binaryState(
    _ first: [UInt8], _ second: [UInt8], controlWord: UInt16 = 0x037F,
    statusWord: UInt16 = 0
  ) throws -> DoryX86ArchitecturalState {
    var floatingPoint = try DoryX86FloatingPointState(
      x87ControlWord: controlWord, x87StatusWord: statusWord,
      x87TagWord: classTag(first) | classTag(second) << 2 | 0xFFF0)
    floatingPoint.x87[0] = try register(first)
    floatingPoint.x87[1] = try register(second)
    return try architecturalState(floatingPoint)
  }

  private func architecturalState(
    _ floatingPoint: DoryX86FloatingPointState
  ) throws -> DoryX86ArchitecturalState {
    try .init(
      rip: 0x1000,
      cs: .init(selector: 0x28, attributes: 0xA09B, limit: .max),
      control: .init(cr0: 0x31), floatingPoint: floatingPoint)
  }

  private func register(_ bytes: [UInt8]) throws -> DoryX86RegisterBytes {
    try .init(bytes: bytes, expectedByteCount: 10)
  }

  private func classTag(_ bytes: [UInt8]) -> UInt16 {
    DoryX86X87Transfer.binary80Class(bytes).tag
  }

  private func top(_ state: DoryX86ArchitecturalState) -> Int {
    Int(state.floatingPoint.x87StatusWord >> 11) & 7
  }

  private func tag(_ physical: Int, _ state: DoryX86ArchitecturalState) -> UInt16 {
    state.floatingPoint.x87TagWord >> UInt16(physical * 2) & 3
  }

  private func expectSuppressed(
    _ state: DoryX86ArchitecturalState, from before: DoryX86FloatingPointState,
    exception: UInt16
  ) {
    #expect(top(state) == Int(before.x87StatusWord >> 11) & 7)
    #expect(state.floatingPoint.x87 == before.x87)
    #expect(state.floatingPoint.x87TagWord == before.x87TagWord)
    #expect(state.floatingPoint.x87StatusWord & 0x80BF == 0x8080 | exception)
  }

  private func retire(
    _ state: inout DoryX86ArchitecturalState, code: [UInt8]
  ) throws {
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code)
    let decoded = try DoryX86Decoder().decode(code, at: 0x1000, mode: .long64)
    #expect(
      DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
        == .retired(decoded))
    #expect(state.rip == 0x1002)
  }
}
