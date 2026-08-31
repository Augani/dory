import Testing

@testable import DoryDBTX86

@Suite struct DoryX86ExtendedFloatTests {
  @Test func preservesBinary80PrecisionBeyondDouble() {
    let one = DoryX86ExtendedFloat.one
    let leastBitAtOne = DoryX86ExtendedFloat(
      bytes: [0, 0, 0, 0, 0, 0, 0, 0x80, 0xC0, 0x3F])
    let sum = one.adding(leastBitAtOne)

    #expect(sum.exponent == 0)
    #expect(sum.significand == 0x8000_0000_0000_0001)
    #expect(sum.doubleValue == 1)
  }

  @Test func preservesTheExtendedExponentRangeAndRawSubnormals() {
    let huge = DoryX86ExtendedFloat(
      bytes: [0, 0, 0, 0, 0, 0, 0, 0x80, 0xFE, 0x7F])
    #expect(huge.isFinite)
    #expect(huge.exponent == 16_383)
    #expect(huge.bytes() == [0, 0, 0, 0, 0, 0, 0, 0x80, 0xFE, 0x7F])

    let leastSubnormal = DoryX86ExtendedFloat(
      bytes: [1, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    #expect(leastSubnormal.exponent == -16_445)
    #expect(leastSubnormal.bytes() == [1, 0, 0, 0, 0, 0, 0, 0, 0, 0])
  }

  @Test func multipliesAndDividesWithAFullSixtyFourBitSignificand() {
    let precise = DoryX86ExtendedFloat(
      bytes: [1, 0, 0, 0, 0, 0, 0, 0x80, 0xFF, 0x3F])
    let two = DoryX86ExtendedFloat(Int64(2))
    let doubled = precise.multiplied(by: two)
    #expect(doubled.exponent == 1)
    #expect(doubled.significand == precise.significand)

    let third = DoryX86ExtendedFloat.one.divided(by: DoryX86ExtendedFloat(Int64(3)))
    #expect(third.exponent == -2)
    #expect(third.significand == 0xAAAA_AAAA_AAAA_AAAB)
  }

  @Test func appliesDirectedAndPrecisionControlRounding() {
    let positive = DoryX86ExtendedFloat(
      bytes: [1, 0, 0, 0, 0, 0, 0, 0x80, 0xFF, 0x3F])
    #expect(
      positive.rounded(precision: 53, rounding: .towardZero).significand
        == 0x8000_0000_0000_0000)
    #expect(
      positive.rounded(precision: 53, rounding: .up).significand
        == 0x8000_0000_0000_0800)
  }
}
