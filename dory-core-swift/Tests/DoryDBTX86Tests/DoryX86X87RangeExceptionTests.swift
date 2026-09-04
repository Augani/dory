import Testing

@testable import DoryDBTX86

// Intel SDM 092 Vol. 1 §§4.9.1.4–4.9.1.6 and 8.5.4–8.5.6:
// x87 register-destination #O/#U/#P exceptions commit their rounded result.
// Unmasked #O/#U store a result whose exponent is biased by 24,576.
@Suite struct DoryX86X87RangeExceptionTests {
  @Test func maskedOverflowUsesEveryRoundingDirectionAndPops() throws {
    for rounding in 0..<4 {
      for negative in [false, true] {
        var state = try binaryState(
          first: two,
          second: signed(maximumFinite, negative: negative),
          controlWord: 0x037F | UInt16(rounding << 10)
        )
        try retire(&state, code: [0xDE, 0xC9])  // FMULP ST(1), ST(0)

        let infinityResult =
          rounding == 0 || rounding == 2 && !negative || rounding == 1 && negative
        let expected = signed(infinityResult ? infinity : maximumFinite, negative: negative)
        #expect(top(state) == 1)
        #expect(state.floatingPoint.x87[1].bytes == expected)
        #expect(tag(1, state) == (infinityResult ? 2 : 0))
        #expect(
          state.floatingPoint.x87StatusWord & 0x0A38
            == 0x0828)
      }
    }
  }

  @Test func unmaskedOverflowStoresBiasedResultAndPops() throws {
    var state = try binaryState(
      first: two, second: maximumFinite, controlWord: 0x0377)
    try retire(&state, code: [0xDE, 0xC9])

    #expect(top(state) == 1)
    #expect(
      state.floatingPoint.x87[1].bytes
        == binary80(significand: .max, exponent: 0x1FFF))
    #expect(tag(1, state) == 0)
    #expect(state.floatingPoint.x87StatusWord == 0x88A8)
  }

  @Test func maskedUnderflowDistinguishesExactTinyAndInexactResults() throws {
    var exact = try binaryState(
      first: half, second: minimumNormal, controlWord: 0x037F)
    try retire(&exact, code: [0xDE, 0xC9])
    #expect(top(exact) == 1)
    #expect(
      exact.floatingPoint.x87[1].bytes
        == binary80(significand: 0x4000_0000_0000_0000, exponent: 0))
    #expect(tag(1, exact) == 2)
    #expect(exact.floatingPoint.x87StatusWord == 0x0800)

    for rounding in 0..<4 {
      for negative in [false, true] {
        var state = try binaryState(
          first: two,
          second: signed(minimumSubnormal, negative: negative),
          controlWord: 0x037F | UInt16(rounding << 10)
        )
        try retire(&state, code: [0xDE, 0xF9])  // FDIVP ST(1), ST(0)

        let increment = rounding == 2 && !negative || rounding == 1 && negative
        let expected = signed(increment ? minimumSubnormal : positiveZero, negative: negative)
        #expect(state.floatingPoint.x87[1].bytes == expected)
        #expect(tag(1, state) == (increment ? 2 : 1))
        #expect(
          state.floatingPoint.x87StatusWord
            == 0x0832 | (increment ? 0x0200 : 0))
      }
    }
  }

  @Test func maskedUnderflowRoundsOnceAtTheBinary80Boundary() throws {
    // PC=24. The exact product has the first discarded subnormal bit set and
    // another bit below it. Rounding first to PC and then to the subnormal
    // range would incorrectly turn this above-halfway value into an exact tie.
    let aboveHalfway = binary80(
      significand: 0x8000_0100_0000_0001, exponent: 0x3FD6)
    var state = try binaryState(
      first: aboveHalfway, second: minimumNormal, controlWord: 0x007F)
    try retire(&state, code: [0xDE, 0xC9])

    #expect(top(state) == 1)
    #expect(
      state.floatingPoint.x87[1].bytes
        == binary80(significand: 0x0040_0001, exponent: 0))
    #expect(tag(1, state) == 2)
    #expect(state.floatingPoint.x87StatusWord == 0x0A30)
  }

  @Test func unmaskedUnderflowStoresBiasedExactAndInexactResults() throws {
    var exactNormal = try binaryState(
      first: half, second: minimumNormal, controlWord: 0x036F)
    try retire(&exactNormal, code: [0xDE, 0xC9])
    #expect(top(exactNormal) == 1)
    #expect(
      exactNormal.floatingPoint.x87[1].bytes
        == binary80(significand: 0x8000_0000_0000_0000, exponent: 0x6000))
    #expect(exactNormal.floatingPoint.x87StatusWord == 0x8890)

    var exactSubnormal = try binaryState(
      first: two, second: minimumSubnormal, controlWord: 0x036F)
    try retire(&exactSubnormal, code: [0xDE, 0xF9])
    #expect(top(exactSubnormal) == 1)
    #expect(
      exactSubnormal.floatingPoint.x87[1].bytes
        == binary80(significand: 0x8000_0000_0000_0000, exponent: 0x5FC1))
    #expect(exactSubnormal.floatingPoint.x87StatusWord == 0x8892)

    var inexact = try binaryState(
      first: three, second: minimumSubnormal, controlWord: 0x036F)
    try retire(&inexact, code: [0xDE, 0xF9])
    #expect(top(inexact) == 1)
    #expect(
      inexact.floatingPoint.x87[1].bytes
        == binary80(significand: 0xAAAA_AAAA_AAAA_AAAB, exponent: 0x5FC0))
    #expect(inexact.floatingPoint.x87StatusWord == 0x8AB2)
  }

  private var positiveZero: [UInt8] { binary80(significand: 0, exponent: 0) }
  private var half: [UInt8] {
    binary80(significand: 0x8000_0000_0000_0000, exponent: 0x3FFE)
  }
  private var two: [UInt8] {
    binary80(significand: 0x8000_0000_0000_0000, exponent: 0x4000)
  }
  private var three: [UInt8] {
    binary80(significand: 0xC000_0000_0000_0000, exponent: 0x4000)
  }
  private var minimumNormal: [UInt8] {
    binary80(significand: 0x8000_0000_0000_0000, exponent: 1)
  }
  private var minimumSubnormal: [UInt8] { binary80(significand: 1, exponent: 0) }
  private var maximumFinite: [UInt8] { binary80(significand: .max, exponent: 0x7FFE) }
  private var infinity: [UInt8] {
    binary80(significand: 0x8000_0000_0000_0000, exponent: 0x7FFF)
  }

  private func binaryState(
    first: [UInt8], second: [UInt8], controlWord: UInt16
  ) throws -> DoryX86ArchitecturalState {
    var floatingPoint = try DoryX86FloatingPointState(
      x87ControlWord: controlWord,
      x87TagWord: tag(for: first) | tag(for: second) << 2 | 0xFFF0
    )
    floatingPoint.x87[0] = try register(first)
    floatingPoint.x87[1] = try register(second)
    return try .init(
      rip: 0x1000,
      cs: .init(selector: 0x28, attributes: 0xA09B, limit: .max),
      control: .init(cr0: 0x31),
      floatingPoint: floatingPoint
    )
  }

  private func retire(
    _ state: inout DoryX86ArchitecturalState, code: [UInt8]
  ) throws {
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code)
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

  private func signed(_ bytes: [UInt8], negative: Bool) -> [UInt8] {
    guard negative else { return bytes }
    var result = bytes
    result[9] |= 0x80
    return result
  }

  private func binary80(significand: UInt64, exponent: UInt16) -> [UInt8] {
    littleEndian(significand, count: 8) + littleEndian(UInt64(exponent), count: 2)
  }

  private func littleEndian(_ value: UInt64, count: Int) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
  }
}
