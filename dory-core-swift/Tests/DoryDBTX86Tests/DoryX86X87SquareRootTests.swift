import Testing

@testable import DoryDBTX86

// Intel SDM 092 Vol. 2A, FSQRT, and Vol. 1 §§4.9.2 and 8.5:
// FSQRT obeys PC/RC, reports #D before #P, and retains post-operation results.
@Suite struct DoryX86X87SquareRootTests {
  @Test func everyPrecisionAndRoundingModeUsesTheBinary80Payload() throws {
    let cases: [(control: UInt16, lower: UInt64, nearest: UInt64, upper: UInt64)] = [
      (0x007F, 0xB504_F300_0000_0000, 0xB504_F300_0000_0000, 0xB504_F400_0000_0000),
      (0x027F, 0xB504_F333_F9DE_6000, 0xB504_F333_F9DE_6800, 0xB504_F333_F9DE_6800),
      (0x037F, 0xB504_F333_F9DE_6484, 0xB504_F333_F9DE_6484, 0xB504_F333_F9DE_6485),
    ]
    for precision in cases {
      for rounding in 0..<4 {
        var state = try unaryState(
          binary80(significand: 0x8000_0000_0000_0000, exponent: 0x4000),
          controlWord: precision.control | UInt16(rounding << 10)
        )
        try squareRoot(&state)

        let expectedSignificand =
          switch rounding {
          case 0: precision.nearest
          case 2: precision.upper
          default: precision.lower
          }
        let roundedUp = expectedSignificand != precision.lower
        #expect(
          state.floatingPoint.x87[0].bytes
            == binary80(significand: expectedSignificand, exponent: 0x3FFF))
        #expect(state.floatingPoint.x87StatusWord == 0x0020 | (roundedUp ? 0x0200 : 0))
      }
    }
  }

  @Test func nearestEvenUsesTheRetainedBitForExactPC24Ties() throws {
    let cases: [(input: UInt64, expected: UInt64, roundedUp: Bool)] = [
      (0x8000_0100_0000_8000, 0x8000_0000_0000_0000, false),
      (0x8000_0300_0004_8000, 0x8000_0200_0000_0000, true),
    ]
    for value in cases {
      var state = try unaryState(
        binary80(significand: value.input, exponent: 0x3FFF), controlWord: 0x007F)
      try squareRoot(&state)

      #expect(
        state.floatingPoint.x87[0].bytes
          == binary80(significand: value.expected, exponent: 0x3FFF))
      #expect(
        state.floatingPoint.x87StatusWord
          == 0x0020 | (value.roundedUp ? 0x0200 : 0))
    }
  }

  @Test func binary80NearestUsesTheExactRemainderAroundHalfway() throws {
    let cases: [(input: UInt64, exponent: UInt16, expected: UInt64, roundedUp: Bool)] = [
      (0x8000_0000_0000_0001, 0x3FFF, 0x8000_0000_0000_0000, false),
      (0xC000_0000_0000_0000, 0x4000, 0xDDB3_D742_C265_539E, true),
    ]
    for value in cases {
      var state = try unaryState(
        binary80(significand: value.input, exponent: value.exponent), controlWord: 0x037F)
      try squareRoot(&state)

      #expect(
        state.floatingPoint.x87[0].bytes
          == binary80(significand: value.expected, exponent: 0x3FFF))
      #expect(
        state.floatingPoint.x87StatusWord
          == 0x0020 | (value.roundedUp ? 0x0200 : 0))
    }
  }

  @Test func denormalPreOperationAndPrecisionPostOperationHonorTheirMasks() throws {
    let minimumSubnormal = binary80(significand: 1, exponent: 0)
    let expected = binary80(significand: 0xB504_F333_F9DE_6484, exponent: 0x1FE0)

    var masked = try unaryState(minimumSubnormal, controlWord: 0x037F)
    try squareRoot(&masked)
    #expect(masked.floatingPoint.x87[0].bytes == expected)
    #expect(masked.floatingPoint.x87StatusWord == 0x0022)

    var denormalUnmasked = try unaryState(minimumSubnormal, controlWord: 0x037D)
    let original = denormalUnmasked.floatingPoint.x87[0]
    try squareRoot(&denormalUnmasked)
    #expect(denormalUnmasked.floatingPoint.x87[0] == original)
    #expect(denormalUnmasked.floatingPoint.x87StatusWord == 0x8082)

    var precisionUnmasked = try unaryState(minimumSubnormal, controlWord: 0x035F)
    try squareRoot(&precisionUnmasked)
    #expect(precisionUnmasked.floatingPoint.x87[0].bytes == expected)
    #expect(precisionUnmasked.floatingPoint.x87StatusWord == 0x80A2)
  }

  @Test func invalidHasPriorityOverDenormalAndQuietNaNsKeepTheirPayload() throws {
    let negativeSubnormal = binary80(significand: 1, exponent: 0, negative: true)
    var masked = try unaryState(negativeSubnormal, controlWord: 0x037F)
    try squareRoot(&masked)
    #expect(masked.floatingPoint.x87[0].bytes == realIndefinite)
    #expect(masked.floatingPoint.x87StatusWord == 0x0001)

    var unmasked = try unaryState(negativeSubnormal, controlWord: 0x037E)
    let original = unmasked.floatingPoint.x87[0]
    try squareRoot(&unmasked)
    #expect(unmasked.floatingPoint.x87[0] == original)
    #expect(unmasked.floatingPoint.x87StatusWord == 0x8081)

    let quietNaN = binary80(significand: 0xC123_4567_89AB_CDEF, exponent: 0x7FFF)
    var quiet = try unaryState(quietNaN, controlWord: 0x037E, statusWord: 0x0200)
    try squareRoot(&quiet)
    #expect(quiet.floatingPoint.x87[0].bytes == quietNaN)
    #expect(quiet.floatingPoint.x87StatusWord == 0)
  }

  @Test func exactRangeExtremesAndSignedZeroNeverNarrowThroughDouble() throws {
    let cases: [(input: [UInt8], expected: [UInt8])] = [
      (
        binary80(significand: 0x8000_0000_0000_0000, exponent: 0x0001),
        binary80(significand: 0x8000_0000_0000_0000, exponent: 0x2000)
      ),
      (
        binary80(significand: 0x8000_0000_0000_0000, exponent: 0x7FFD),
        binary80(significand: 0x8000_0000_0000_0000, exponent: 0x5FFE)
      ),
      (
        binary80(significand: 0, exponent: 0, negative: true),
        binary80(significand: 0, exponent: 0, negative: true)
      ),
      (
        binary80(significand: 0x8000_0000_0000_0000, exponent: 0x7FFF),
        binary80(significand: 0x8000_0000_0000_0000, exponent: 0x7FFF)
      ),
    ]
    for value in cases {
      var state = try unaryState(value.input, controlWord: 0x037F, statusWord: 0x0200)
      try squareRoot(&state)
      #expect(state.floatingPoint.x87[0].bytes == value.expected)
      #expect(state.floatingPoint.x87StatusWord == 0)
    }
  }

  private var realIndefinite: [UInt8] {
    binary80(
      significand: 0xC000_0000_0000_0000, exponent: 0x7FFF, negative: true)
  }

  private func unaryState(
    _ value: [UInt8], controlWord: UInt16, statusWord: UInt16 = 0
  ) throws -> DoryX86ArchitecturalState {
    var floatingPoint = try DoryX86FloatingPointState(
      x87ControlWord: controlWord,
      x87StatusWord: statusWord,
      x87TagWord: DoryX86X87Transfer.binary80Class(value).tag | 0xFFFC
    )
    floatingPoint.x87[0] = try .init(bytes: value, expectedByteCount: 10)
    return try .init(
      rip: 0x1000,
      cs: .init(selector: 0x28, attributes: 0xA09B, limit: .max),
      control: .init(cr0: 0x31),
      floatingPoint: floatingPoint
    )
  }

  private func squareRoot(_ state: inout DoryX86ArchitecturalState) throws {
    let code: [UInt8] = [0xD9, 0xFA]
    let decoded = try DoryX86Decoder().decode(code, at: 0x1000, mode: .long64)
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code)
    #expect(
      DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
        == .retired(decoded))
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
