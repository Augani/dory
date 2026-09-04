import Foundation
import Testing

@testable import DoryDBTX86

/// Exact binary80 boundaries from Intel SDM Vol. 1 §§4.8.3–4.8.4 and
/// Vol. 2A FADD/FIST. Expectations use integer encodings, not host FP results.
@Suite struct DoryX86ExtendedFloatBoundaryTests {
  private let directions: [DoryX86FloatingRounding] = [.nearestEven, .down, .up, .towardZero]

  @Test func infinitiesZerosAndFiniteValuesHaveNumericOrder() {
    let infinity = value(significand: 0x8000_0000_0000_0000, exponentField: 0x7FFF)
    let huge = value(significand: .max, exponentField: 0x7FFE)
    let tiny = value(significand: 1, exponentField: 0)
    let ordered = [infinity.negated(), huge.negated(), .one.negated(), tiny.negated(),
                   DoryX86ExtendedFloat.zero, tiny, .one, huge, infinity]
    for left in ordered.indices {
      for right in ordered.indices {
        let expected: ComparisonResult = left < right ? .orderedAscending
          : left > right ? .orderedDescending : .orderedSame
        #expect(ordered[left].compared(to: ordered[right]) == expected)
      }
    }
    #expect(DoryX86ExtendedFloat.zero.compared(to: .zero.negated()) == .orderedSame)
    let nan = value(significand: 0xC000_0000_0000_0001, exponentField: 0x7FFF)
    for operand in ordered + [nan] {
      #expect(nan.compared(to: operand) == nil)
      #expect(operand.compared(to: nan) == nil)
    }
  }

  @Test func largeIntegerConversionsRejectBeforeWideShiftTruncation() {
    for exponent in [64, 127, 128, 191, 255, 16_383] {
      let large = value(significand: 0x8000_0000_0000_0000,
                        exponentField: UInt16(exponent + 16_383))
      for direction in directions {
        for width in [16, 32, 64] {
          #expect(large.signedIntegerBits(bitCount: width, rounding: direction) == nil)
          #expect(large.negated().signedIntegerBits(bitCount: width, rounding: direction) == nil)
        }
      }
    }
    for width in [16, 32, 64] {
      let limit = value(significand: 0x8000_0000_0000_0000,
                        exponentField: UInt16(width - 1 + 16_383))
      #expect(limit.signedIntegerBits(bitCount: width, rounding: .towardZero) == nil)
      #expect(limit.negated().signedIntegerBits(bitCount: width, rounding: .towardZero)
              == UInt64(1) << (width - 1))
    }
  }

  @Test func exactCancellationAndMixedZerosUseTheRoundingDirection() {
    for direction in directions {
      let negative = direction == .down
      for operand in [DoryX86ExtendedFloat.one, .one.negated(),
                      value(significand: 1, exponentField: 0)] {
        let result = operand.subtracting(operand, rounding: direction)
        #expect(result.isZero)
        #expect(result.isNegative == negative)
      }
      for firstNegative in [false, true] {
        for secondNegative in [false, true] {
          let lhs = firstNegative ? DoryX86ExtendedFloat.zero.negated() : .zero
          let rhs = secondNegative ? DoryX86ExtendedFloat.zero.negated() : .zero
          let result = lhs.adding(rhs, rounding: direction)
          #expect(result.isZero)
          #expect(result.isNegative == (firstNegative == secondNegative ? firstNegative : negative))
        }
      }
    }
  }

  @Test func precisionControlRoundsOnceAtAnExactHalfwayBoundary() {
    for precision in [24, 53] {
      // rhs = 2^-precision + 2^-65. The exact sum is just above
      // the halfway point; first rounding to64bits can erase the final term.
      let rhs = value(significand: 0x8000_0000_0000_0000 | (UInt64(1) << (precision - 2)),
                      exponentField: UInt16(16_383 - precision))
      let ulp = UInt64(1) << (64 - precision)
      let positive = DoryX86ExtendedFloat.one.adding(rhs, precision: precision)
      #expect(positive.exponent == 0)
      #expect(positive.significand == 0x8000_0000_0000_0000 + ulp)
      let negative = DoryX86ExtendedFloat.one.negated().subtracting(rhs, precision: precision)
      #expect(negative.isNegative)
      #expect(negative.significand == positive.significand)
      let halfway = value(significand: 0x8000_0000_0000_0000,
                           exponentField: UInt16(16_383 - precision))
      #expect(DoryX86ExtendedFloat.one.adding(halfway, precision: precision).significand
              == 0x8000_0000_0000_0000)
    }
  }

  @Test func binary80OverflowUsesTheGuestRoundingDirection() {
    let overflow = DoryX86ExtendedFloat.one.scaledByPowerOfTwo(16_384)
    for direction in directions {
      for negative in [false, true] {
        let result = (negative ? overflow.negated() : overflow).bytes(rounding: direction)
        let infinity = direction == .nearestEven || (direction == .up && !negative)
          || (direction == .down && negative)
        let expected = value(significand: infinity ? 0x8000_0000_0000_0000 : .max,
                             exponentField: infinity ? 0x7FFF : 0x7FFE)
        #expect(result == (negative ? expected.negated() : expected).bytes())
      }
    }
  }

  @Test func narrowingThatRoundsToMinimumNormalDoesNotReportUnderflow() {
    // Intel SDM 092 Vol. 1 §4.9.1.5 detects x87 tininess after rounding to
    // destination precision with an unbounded exponent. The threshold is strict:
    // a result rounded to 1.0 * 2^-126 is normal even when its input was smaller.
    let halfwayToFloat32MinimumNormal = value(
      significand: 0xFFFF_FF00_0000_0000,
      exponentField: UInt16(16_383 - 127)
    )

    let conversion = halfwayToFloat32MinimumNormal.float32Conversion()
    #expect(conversion.bits == 0x0080_0000)
    #expect(conversion.inexact && conversion.roundedUp)
    #expect(!conversion.tiny && !conversion.overflow)

    // Leave #U unmasked. Because the rounded result is normal, FST still stores
    // it and reports only #P instead of suppressing the write with a false #U.
    let stored = DoryX86X87Transfer.store(
      bytes: halfwayToFloat32MinimumNormal.bytes(),
      format: .float32,
      truncate: false,
      controlWord: 0x036F
    )
    #expect(stored.bytes == [0, 0, 0x80, 0])
    #expect(stored.flags == 0x20)
    #expect(stored.roundedUp && !stored.suppressWriteAndPop)
  }

  @Test func generatedInvalidArithmeticReturnsX87RealIndefinite() {
    // Intel SDM Vol. 1 §§4.8.3.7 and 8.5.1.2 require a non-NaN invalid
    // arithmetic operation to produce real indefinite. Its double-extended
    // encoding is FFFF C000000000000000H, including the negative sign bit.
    let infinity = value(significand: 0x8000_0000_0000_0000, exponentField: 0x7FFF)
    let zero = DoryX86ExtendedFloat.zero
    let invalidResults = [
      infinity.adding(infinity.negated()),
      infinity.subtracting(infinity),
      infinity.multiplied(by: zero),
      zero.multiplied(by: infinity),
      infinity.divided(by: infinity),
      zero.divided(by: zero),
    ]
    let realIndefinite: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0xC0, 0xFF, 0xFF]

    for result in invalidResults {
      #expect(result.isNaN)
      #expect(result.isNegative)
      #expect(result.bytes() == realIndefinite)
    }
  }

  private func value(significand: UInt64, exponentField: UInt16) -> DoryX86ExtendedFloat {
    let bytes = (0..<8).map { UInt8(truncatingIfNeeded: significand >> ($0 * 8)) }
      + [UInt8(truncatingIfNeeded: exponentField), UInt8(truncatingIfNeeded: exponentField >> 8)]
    return .init(bytes: bytes)
  }
}
