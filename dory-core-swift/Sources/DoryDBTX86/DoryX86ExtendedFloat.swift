import Foundation

private struct DoryX86WideUnsigned: Equatable, Comparable {
  var high: UInt64
  var low: UInt64

  init(_ value: UInt64) {
    high = 0
    low = value
  }

  init(high: UInt64, low: UInt64) {
    self.high = high
    self.low = low
  }

  var leadingZeroBitCount: Int {
    high == 0 ? 64 + low.leadingZeroBitCount : high.leadingZeroBitCount
  }

  static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.high == rhs.high ? lhs.low < rhs.low : lhs.high < rhs.high
  }

  static func + (lhs: Self, rhs: Self) -> Self {
    let (low, carry) = lhs.low.addingReportingOverflow(rhs.low)
    return .init(high: lhs.high &+ rhs.high &+ (carry ? 1 : 0), low: low)
  }

  static func += (lhs: inout Self, rhs: Self) { lhs = lhs + rhs }

  static func - (lhs: Self, rhs: Self) -> Self {
    let (low, borrow) = lhs.low.subtractingReportingOverflow(rhs.low)
    return .init(high: lhs.high &- rhs.high &- (borrow ? 1 : 0), low: low)
  }

  static func -= (lhs: inout Self, rhs: Self) { lhs = lhs - rhs }

  static func | (lhs: Self, rhs: Self) -> Self {
    .init(high: lhs.high | rhs.high, low: lhs.low | rhs.low)
  }

  static func |= (lhs: inout Self, rhs: Self) { lhs = lhs | rhs }

  static func & (lhs: Self, rhs: Self) -> Self {
    .init(high: lhs.high & rhs.high, low: lhs.low & rhs.low)
  }

  static func << (value: Self, shift: Int) -> Self {
    guard shift > 0 else { return value }
    guard shift < 128 else { return .init(0) }
    if shift >= 64 {
      return .init(high: value.low << UInt64(shift - 64), low: 0)
    }
    return .init(
      high: value.high << UInt64(shift) | value.low >> UInt64(64 - shift),
      low: value.low << UInt64(shift)
    )
  }

  static func <<= (value: inout Self, shift: Int) { value = value << shift }

  static func >> (value: Self, shift: Int) -> Self {
    guard shift > 0 else { return value }
    guard shift < 128 else { return .init(0) }
    if shift >= 64 {
      return .init(high: 0, low: value.high >> UInt64(shift - 64))
    }
    return .init(
      high: value.high >> UInt64(shift),
      low: value.low >> UInt64(shift) | value.high << UInt64(64 - shift)
    )
  }

  static func >>= (value: inout Self, shift: Int) { value = value >> shift }

  static func product(_ lhs: UInt64, _ rhs: UInt64) -> Self {
    let product = lhs.multipliedFullWidth(by: rhs)
    return .init(high: product.high, low: product.low)
  }

  func quotientAndRemainder(dividingBy divisor: UInt64) -> (UInt64, UInt64) {
    precondition(divisor != 0 && high < divisor)
    let result = divisor.dividingFullWidth((high: high, low: low))
    return (result.quotient, result.remainder)
  }
}

enum DoryX86FloatingRounding: Sendable {
  case nearestEven, down, up, towardZero
}

struct DoryX86BinaryFloatConversion: Sendable, Equatable {
  let bits: UInt64
  let inexact: Bool
  let tiny: Bool
  let overflow: Bool
  let roundedUp: Bool
}

/// Software representation of the x87 80-bit double-extended format.
///
/// Finite nonzero values are kept normalized as `significand * 2^(exponent - 63)`.
/// Keeping the full 64-bit explicit significand and the full x87 exponent range avoids
/// silently narrowing guest arithmetic to the host's binary64 `Double` implementation.
struct DoryX86ExtendedFloat: Sendable, Hashable {
  private enum Kind: Sendable, Hashable {
    case finite
    case infinity
    case nan(UInt64)
  }

  private let kind: Kind
  let isNegative: Bool
  let exponent: Int
  let significand: UInt64

  static let zero = DoryX86ExtendedFloat(
    kind: .finite, isNegative: false, exponent: 0, significand: 0)
  static let one = DoryX86ExtendedFloat(
    kind: .finite, isNegative: false, exponent: 0, significand: 0x8000_0000_0000_0000)

  var isZero: Bool { kind == .finite && significand == 0 }
  var isFinite: Bool { kind == .finite }
  var isInfinite: Bool { kind == .infinity }
  var isNaN: Bool {
    if case .nan = kind { return true }
    return false
  }
  var isSubnormal: Bool { kind == .finite && significand != 0 && exponent < -16_382 }

  init(bytes: [UInt8]) {
    precondition(bytes.count == 10)
    let rawSignificand = bytes[0..<8].enumerated().reduce(UInt64(0)) {
      $0 | UInt64($1.element) << UInt64($1.offset * 8)
    }
    let signAndExponent = UInt16(bytes[8]) | UInt16(bytes[9]) << 8
    isNegative = signAndExponent & 0x8000 != 0
    let exponentField = Int(signAndExponent & 0x7FFF)
    switch exponentField {
    case 0 where rawSignificand == 0:
      kind = .finite
      exponent = 0
      significand = 0
    case 0:
      kind = .finite
      let shift = rawSignificand.leadingZeroBitCount
      exponent = -16_382 - shift
      significand = rawSignificand << UInt64(shift)
    case 0x7FFF where rawSignificand == 0x8000_0000_0000_0000:
      kind = .infinity
      exponent = 0
      significand = 0
    case 0x7FFF:
      kind = .nan(rawSignificand | 0xC000_0000_0000_0000)
      exponent = 0
      significand = 0
    default:
      kind = .finite
      exponent = exponentField - 16_383
      if rawSignificand == 0 {
        significand = 0
      } else {
        let shift = rawSignificand.leadingZeroBitCount
        significand = rawSignificand << UInt64(shift)
      }
    }
  }

  init(_ value: Double) {
    let bits = value.bitPattern
    let negative = bits >> 63 != 0
    let exponentField = Int(bits >> 52 & 0x7FF)
    let fraction = bits & 0x000F_FFFF_FFFF_FFFF
    switch exponentField {
    case 0 where fraction == 0:
      self.init(kind: .finite, isNegative: negative, exponent: 0, significand: 0)
    case 0:
      let highestBit = 63 - fraction.leadingZeroBitCount
      self.init(
        kind: .finite,
        isNegative: negative,
        exponent: highestBit - 1_074,
        significand: fraction << UInt64(63 - highestBit)
      )
    case 0x7FF where fraction == 0:
      self.init(kind: .infinity, isNegative: negative, exponent: 0, significand: 0)
    case 0x7FF:
      self.init(
        kind: .nan(0xC000_0000_0000_0000 | fraction << 11),
        isNegative: negative,
        exponent: 0,
        significand: 0
      )
    default:
      self.init(
        kind: .finite,
        isNegative: negative,
        exponent: exponentField - 1_023,
        significand: (0x0010_0000_0000_0000 | fraction) << 11
      )
    }
  }

  init(_ value: Int64) {
    guard value != 0 else {
      self = .zero
      return
    }
    let negative = value < 0
    let magnitude = value.magnitude
    let highestBit = 63 - magnitude.leadingZeroBitCount
    self.init(
      kind: .finite,
      isNegative: negative,
      exponent: highestBit,
      significand: magnitude << UInt64(63 - highestBit)
    )
  }

  init(unsigned value: UInt64, negative: Bool = false) {
    guard value != 0 else {
      self.init(kind: .finite, isNegative: negative, exponent: 0, significand: 0)
      return
    }
    let highestBit = 63 - value.leadingZeroBitCount
    self.init(
      kind: .finite,
      isNegative: negative,
      exponent: highestBit,
      significand: value << UInt64(63 - highestBit)
    )
  }

  private init(kind: Kind, isNegative: Bool, exponent: Int, significand: UInt64) {
    self.kind = kind
    self.isNegative = isNegative
    self.exponent = exponent
    self.significand = significand
  }

  func bytes(rounding: DoryX86FloatingRounding = .nearestEven) -> [UInt8] {
    let rawSignificand: UInt64
    let exponentField: UInt16
    switch kind {
    case .infinity:
      rawSignificand = 0x8000_0000_0000_0000
      exponentField = 0x7FFF
    case .nan(let payload):
      rawSignificand = payload | 0xC000_0000_0000_0000
      exponentField = 0x7FFF
    case .finite where significand == 0:
      rawSignificand = 0
      exponentField = 0
    case .finite where exponent > 16_383:
      let infinity = rounding == .nearestEven || rounding == .up && !isNegative
        || rounding == .down && isNegative
      rawSignificand = infinity ? 0x8000_0000_0000_0000 : .max
      exponentField = infinity ? 0x7FFF : 0x7FFE
    case .finite where exponent >= -16_382:
      rawSignificand = significand
      exponentField = UInt16(exponent + 16_383)
    case .finite:
      let shift = -16_382 - exponent
      let rounded = Self.roundedShiftRight(
        DoryX86WideUnsigned(significand), by: shift, negative: isNegative, rounding: rounding)
      if rounded >= DoryX86WideUnsigned(0x8000_0000_0000_0000) {
        rawSignificand = 0x8000_0000_0000_0000
        exponentField = 1
      } else {
        rawSignificand = rounded.low
        exponentField = 0
      }
    }
    var result = (0..<8).map { UInt8(truncatingIfNeeded: rawSignificand >> UInt64($0 * 8)) }
    let signAndExponent = exponentField | (isNegative ? 0x8000 : 0)
    result.append(UInt8(truncatingIfNeeded: signAndExponent))
    result.append(UInt8(truncatingIfNeeded: signAndExponent >> 8))
    return result
  }

  func negated() -> Self {
    .init(kind: kind, isNegative: !isNegative, exponent: exponent, significand: significand)
  }

  func absolute() -> Self {
    .init(kind: kind, isNegative: false, exponent: exponent, significand: significand)
  }

  func adding(
    _ rhs: Self,
    rounding: DoryX86FloatingRounding = .nearestEven,
    precision: Int = 64
  ) -> Self {
    if isNaN { return self }
    if rhs.isNaN { return rhs }
    if isInfinite || rhs.isInfinite {
      if isInfinite, rhs.isInfinite, isNegative != rhs.isNegative { return Self.nan() }
      return isInfinite ? self : rhs
    }
    if isZero, rhs.isZero {
      let negative = isNegative == rhs.isNegative ? isNegative : rounding == .down
      return .init(unsigned: 0, negative: negative)
    }
    if isZero { return rhs.rounded(precision: precision, rounding: rounding) }
    if rhs.isZero { return rounded(precision: precision, rounding: rounding) }

    let lhsFirst = exponent >= rhs.exponent
    let larger = lhsFirst ? self : rhs
    let smaller = lhsFirst ? rhs : self
    let difference = larger.exponent - smaller.exponent
    var lhsMagnitude = DoryX86WideUnsigned(larger.significand) << 3
    let rhsMagnitude = Self.shiftRightJam(
      DoryX86WideUnsigned(smaller.significand) << 3, by: difference)
    var negative = larger.isNegative
    if larger.isNegative == smaller.isNegative {
      lhsMagnitude += rhsMagnitude
    } else if lhsMagnitude >= rhsMagnitude {
      lhsMagnitude -= rhsMagnitude
    } else {
      lhsMagnitude = rhsMagnitude - lhsMagnitude
      negative.toggle()
    }
    guard lhsMagnitude != DoryX86WideUnsigned(0) else {
      return .init(unsigned: 0, negative: rounding == .down)
    }
    return Self.normalized(
      magnitudeWithGuardBits: lhsMagnitude,
      exponent: larger.exponent,
      negative: negative,
      rounding: rounding,
      precision: precision
    )
  }

  func subtracting(
    _ rhs: Self,
    rounding: DoryX86FloatingRounding = .nearestEven,
    precision: Int = 64
  ) -> Self {
    adding(rhs.negated(), rounding: rounding, precision: precision)
  }

  func multiplied(
    by rhs: Self,
    rounding: DoryX86FloatingRounding = .nearestEven,
    precision: Int = 64
  ) -> Self {
    if isNaN { return self }
    if rhs.isNaN { return rhs }
    if (isZero && rhs.isInfinite) || (isInfinite && rhs.isZero) { return Self.nan() }
    let negative = isNegative != rhs.isNegative
    if isInfinite || rhs.isInfinite {
      return .init(kind: .infinity, isNegative: negative, exponent: 0, significand: 0)
    }
    if isZero || rhs.isZero {
      return .init(kind: .finite, isNegative: negative, exponent: 0, significand: 0)
    }
    let product = DoryX86WideUnsigned.product(significand, rhs.significand)
    let topBit = 127 - product.leadingZeroBitCount
    let shift = topBit - 66
    let guarded = Self.shiftRightJam(product, by: shift)
    return Self.normalized(
      magnitudeWithGuardBits: guarded,
      exponent: exponent + rhs.exponent + topBit - 126,
      negative: negative,
      rounding: rounding,
      precision: precision
    )
  }

  func divided(
    by rhs: Self,
    rounding: DoryX86FloatingRounding = .nearestEven,
    precision: Int = 64
  ) -> Self {
    if isNaN { return self }
    if rhs.isNaN { return rhs }
    if (isZero && rhs.isZero) || (isInfinite && rhs.isInfinite) { return Self.nan() }
    let negative = isNegative != rhs.isNegative
    if isInfinite || rhs.isZero {
      return .init(kind: .infinity, isNegative: negative, exponent: 0, significand: 0)
    }
    if isZero || rhs.isInfinite {
      return .init(kind: .finite, isNegative: negative, exponent: 0, significand: 0)
    }
    let quotientExponentAdjustment = significand < rhs.significand ? -1 : 0
    let shift = significand < rhs.significand ? 64 : 63
    let numerator = DoryX86WideUnsigned(significand) << shift
    let (rawQuotient, rawRemainder) = numerator.quotientAndRemainder(
      dividingBy: rhs.significand)
    let quotient = DoryX86WideUnsigned(rawQuotient)
    var remainder = DoryX86WideUnsigned(rawRemainder)
    var guardBits = DoryX86WideUnsigned(0)
    for _ in 0..<3 {
      remainder <<= 1
      let (bit, nextRemainder) = remainder.quotientAndRemainder(
        dividingBy: rhs.significand)
      guardBits = guardBits << 1 | DoryX86WideUnsigned(bit)
      remainder = DoryX86WideUnsigned(nextRemainder)
    }
    var guardedQuotient = quotient << 3 | guardBits
    if remainder != DoryX86WideUnsigned(0) { guardedQuotient |= DoryX86WideUnsigned(1) }
    return Self.normalized(
      magnitudeWithGuardBits: guardedQuotient,
      exponent: exponent - rhs.exponent + quotientExponentAdjustment,
      negative: negative,
      rounding: rounding,
      precision: precision
    )
  }

  func rounded(
    precision: Int,
    rounding: DoryX86FloatingRounding = .nearestEven
  ) -> Self {
    guard kind == .finite, significand != 0, precision < 64 else { return self }
    let shift = 64 - max(1, precision)
    var rounded = Self.roundedShiftRight(
      DoryX86WideUnsigned(significand), by: shift, negative: isNegative, rounding: rounding)
    var resultExponent = exponent
    if rounded >= DoryX86WideUnsigned(1) << precision {
      rounded >>= 1
      resultExponent += 1
    }
    return .init(
      kind: .finite,
      isNegative: isNegative,
      exponent: resultExponent,
      significand: rounded.low << UInt64(64 - precision)
    )
  }

  func roundedToInteger(_ rounding: DoryX86FloatingRounding) -> Self {
    guard kind == .finite, significand != 0, exponent < 63 else { return self }
    let magnitude = Self.roundedShiftRight(
      DoryX86WideUnsigned(significand),
      by: 63 - exponent,
      negative: isNegative,
      rounding: rounding
    )
    return .init(unsigned: magnitude.low, negative: isNegative)
  }

  func scaledByPowerOfTwo(_ power: Int) -> Self {
    guard kind == .finite, significand != 0 else { return self }
    return .init(
      kind: .finite,
      isNegative: isNegative,
      exponent: exponent + power,
      significand: significand
    )
  }

  func signedIntegerBits(
    bitCount: Int,
    rounding: DoryX86FloatingRounding
  ) -> UInt64? {
    precondition((1...64).contains(bitCount))
    guard kind == .finite else { return nil }
    guard significand != 0 else { return 0 }
    // Reject before shifting into the bounded128-bit temporary. Otherwise very
    // large finite operands can lose every bit and incorrectly convert to zero.
    guard exponent < bitCount else { return nil }
    let magnitude: DoryX86WideUnsigned
    if exponent >= 63 {
      magnitude = DoryX86WideUnsigned(significand) << (exponent - 63)
    } else {
      magnitude = Self.roundedShiftRight(
        DoryX86WideUnsigned(significand),
        by: 63 - exponent,
        negative: isNegative,
        rounding: rounding
      )
    }
    let negativeLimit = DoryX86WideUnsigned(1) << (bitCount - 1)
    let positiveLimit = negativeLimit - DoryX86WideUnsigned(1)
    guard magnitude <= (isNegative ? negativeLimit : positiveLimit) else { return nil }
    let raw = isNegative ? UInt64(0) &- magnitude.low : magnitude.low
    if bitCount == 64 { return raw }
    return raw & ((UInt64(1) << UInt64(bitCount)) - 1)
  }

  func signedIntegerConversion(
    bitCount: Int,
    rounding: DoryX86FloatingRounding
  ) -> (bits: UInt64, inexact: Bool, roundedUp: Bool)? {
    guard let bits = signedIntegerBits(bitCount: bitCount, rounding: rounding) else { return nil }
    guard kind == .finite, significand != 0, exponent < 63 else {
      return (bits, false, false)
    }
    let shift = 63 - exponent
    let inexact: Bool
    if shift >= 64 {
      inexact = true
    } else {
      inexact = significand & ((UInt64(1) << UInt64(shift)) - 1) != 0
    }
    guard inexact else { return (bits, false, false) }
    let truncated = signedIntegerBits(bitCount: bitCount, rounding: .towardZero)
    return (bits, true, truncated != bits)
  }

  func float32Bits(rounding: DoryX86FloatingRounding = .nearestEven) -> UInt32 {
    UInt32(truncatingIfNeeded: float32Conversion(rounding: rounding).bits)
  }

  func float64Bits(rounding: DoryX86FloatingRounding = .nearestEven) -> UInt64 {
    float64Conversion(rounding: rounding).bits
  }

  func float32Conversion(
    rounding: DoryX86FloatingRounding = .nearestEven
  ) -> DoryX86BinaryFloatConversion {
    binaryFormatConversion(exponentBits: 8, fractionBits: 23, bias: 127, rounding: rounding)
  }

  func float64Conversion(
    rounding: DoryX86FloatingRounding = .nearestEven
  ) -> DoryX86BinaryFloatConversion {
    binaryFormatConversion(exponentBits: 11, fractionBits: 52, bias: 1_023, rounding: rounding)
  }

  func compared(to rhs: Self) -> ComparisonResult? {
    if isNaN || rhs.isNaN { return nil }
    if isZero, rhs.isZero { return .orderedSame }
    if isNegative != rhs.isNegative { return isNegative ? .orderedAscending : .orderedDescending }
    let magnitude: ComparisonResult
    if isInfinite || rhs.isInfinite {
      magnitude = isInfinite == rhs.isInfinite ? .orderedSame
        : isInfinite ? .orderedDescending : .orderedAscending
    } else if isZero || rhs.isZero {
      magnitude = isZero ? .orderedAscending : .orderedDescending
    } else if exponent != rhs.exponent {
      magnitude = exponent < rhs.exponent ? .orderedAscending : .orderedDescending
    } else if significand != rhs.significand {
      magnitude = significand < rhs.significand ? .orderedAscending : .orderedDescending
    } else {
      magnitude = .orderedSame
    }
    if !isNegative || magnitude == .orderedSame { return magnitude }
    return magnitude == .orderedAscending ? .orderedDescending : .orderedAscending
  }

  var doubleValue: Double {
    Double(bitPattern: float64Bits())
  }

  private func binaryFormatConversion(
    exponentBits: Int,
    fractionBits: Int,
    bias: Int,
    rounding: DoryX86FloatingRounding
  ) -> DoryX86BinaryFloatConversion {
    let sign = isNegative ? UInt64(1) << UInt64(exponentBits + fractionBits) : 0
    let maximumExponentField = (UInt64(1) << UInt64(exponentBits)) - 1
    switch kind {
    case .infinity:
      return .init(bits: sign | maximumExponentField << UInt64(fractionBits),
        inexact: false, tiny: false, overflow: false, roundedUp: false)
    case .nan:
      return .init(bits: sign | maximumExponentField << UInt64(fractionBits)
        | UInt64(1) << UInt64(fractionBits - 1),
        inexact: false, tiny: false, overflow: false, roundedUp: false)
    case .finite where significand == 0:
      return .init(bits: sign, inexact: false, tiny: false, overflow: false, roundedUp: false)
    case .finite:
      break
    }

    let maximumExponent = Int(maximumExponentField - 1) - bias
    if exponent > maximumExponent {
      let bits = overflowBits(
        sign: sign,
        maximumExponentField: maximumExponentField,
        fractionBits: fractionBits,
        rounding: rounding
      )
      return .init(bits: bits, inexact: true, tiny: false, overflow: true,
        roundedUp: bits & (maximumExponentField << UInt64(fractionBits))
          == maximumExponentField << UInt64(fractionBits))
    }
    let minimumNormalExponent = 1 - bias
    let precision = fractionBits + 1
    if exponent >= minimumNormalExponent {
      let shift = 64 - precision
      let discardedMask = (UInt64(1) << UInt64(shift)) - 1
      let discarded = significand & discardedMask
      var rounded = Self.roundedShiftRight(
        DoryX86WideUnsigned(significand),
        by: shift,
        negative: isNegative,
        rounding: rounding
      )
      let roundedUp = discarded != 0 && rounded.low != significand >> UInt64(shift)
      var resultExponent = exponent
      if rounded >= DoryX86WideUnsigned(1) << precision {
        rounded >>= 1
        resultExponent += 1
      }
      if resultExponent > maximumExponent {
        let bits = overflowBits(
          sign: sign,
          maximumExponentField: maximumExponentField,
          fractionBits: fractionBits,
          rounding: rounding
        )
        return .init(bits: bits, inexact: true, tiny: false, overflow: true,
          roundedUp: roundedUp)
      }
      let exponentField = UInt64(resultExponent + bias)
      let fractionMask = (UInt64(1) << UInt64(fractionBits)) - 1
      return .init(bits: sign | exponentField << UInt64(fractionBits) | rounded.low & fractionMask,
        inexact: discarded != 0, tiny: false, overflow: false, roundedUp: roundedUp)
    }

    let shift = 63 + minimumNormalExponent - fractionBits - exponent
    let rounded = Self.roundedShiftRight(
      DoryX86WideUnsigned(significand),
      by: shift,
      negative: isNegative,
      rounding: rounding
    )
    let inexact: Bool
    let truncated: UInt64
    if shift >= 64 {
      inexact = significand != 0
      truncated = 0
    } else {
      let discardedMask = (UInt64(1) << UInt64(shift)) - 1
      inexact = significand & discardedMask != 0
      truncated = significand >> UInt64(shift)
    }
    let roundedUp = inexact && rounded.low != truncated
    if rounded >= DoryX86WideUnsigned(1) << fractionBits {
      return .init(bits: sign | UInt64(1) << UInt64(fractionBits),
        inexact: inexact, tiny: true, overflow: false, roundedUp: roundedUp)
    }
    return .init(bits: sign | rounded.low, inexact: inexact, tiny: true,
      overflow: false, roundedUp: roundedUp)
  }

  private func overflowBits(
    sign: UInt64,
    maximumExponentField: UInt64,
    fractionBits: Int,
    rounding: DoryX86FloatingRounding
  ) -> UInt64 {
    let infinity =
      rounding == .nearestEven || rounding == .up && !isNegative
      || rounding == .down && isNegative
    if infinity { return sign | maximumExponentField << UInt64(fractionBits) }
    let maximumFraction = (UInt64(1) << UInt64(fractionBits)) - 1
    return sign | (maximumExponentField - 1) << UInt64(fractionBits) | maximumFraction
  }

  private static func nan() -> Self {
    .init(
      kind: .nan(0xC000_0000_0000_0000),
      isNegative: false,
      exponent: 0,
      significand: 0
    )
  }

  private static func normalized(
    magnitudeWithGuardBits: DoryX86WideUnsigned,
    exponent: Int,
    negative: Bool,
    rounding: DoryX86FloatingRounding,
    precision: Int
  ) -> Self {
    var magnitude = magnitudeWithGuardBits
    var resultExponent = exponent
    let topBit = 127 - magnitude.leadingZeroBitCount
    if topBit > 66 {
      let shift = topBit - 66
      magnitude = shiftRightJam(magnitude, by: shift)
      resultExponent += shift
    } else if topBit < 66 {
      let shift = 66 - topBit
      magnitude <<= shift
      resultExponent -= shift
    }
    // Round once to the guest precision. Rounding first to64bits can erase
    // the sticky bit and turn a value above a24/53-bit tie into an exact tie.
    let precision = min(64, max(1, precision))
    var rounded = roundedShiftRight(
      magnitude, by: 3 + 64 - precision, negative: negative, rounding: rounding)
    if rounded >= DoryX86WideUnsigned(1) << precision {
      rounded >>= 1
      resultExponent += 1
    }
    return Self(
      kind: .finite,
      isNegative: negative,
      exponent: resultExponent,
      significand: rounded.low << UInt64(64 - precision)
    )
  }

  private static func shiftRightJam(
    _ value: DoryX86WideUnsigned,
    by shift: Int
  ) -> DoryX86WideUnsigned {
    guard shift > 0 else { return value }
    guard shift < 128 else {
      return value == DoryX86WideUnsigned(0)
        ? DoryX86WideUnsigned(0) : DoryX86WideUnsigned(1)
    }
    let discardedMask = (DoryX86WideUnsigned(1) << shift) - DoryX86WideUnsigned(1)
    return value >> shift
      | (value & discardedMask == DoryX86WideUnsigned(0)
        ? DoryX86WideUnsigned(0) : DoryX86WideUnsigned(1))
  }

  private static func roundedShiftRight(
    _ value: DoryX86WideUnsigned,
    by shift: Int,
    negative: Bool,
    rounding: DoryX86FloatingRounding
  ) -> DoryX86WideUnsigned {
    guard shift > 0 else { return value }
    guard shift < 128 else {
      guard value != DoryX86WideUnsigned(0) else { return DoryX86WideUnsigned(0) }
      return rounding == .up && !negative || rounding == .down && negative
        ? DoryX86WideUnsigned(1) : DoryX86WideUnsigned(0)
    }
    let truncated = value >> shift
    let discardedMask = (DoryX86WideUnsigned(1) << shift) - DoryX86WideUnsigned(1)
    let discarded = value & discardedMask
    guard discarded != DoryX86WideUnsigned(0) else { return truncated }
    let increment: Bool
    switch rounding {
    case .towardZero: increment = false
    case .up: increment = !negative
    case .down: increment = negative
    case .nearestEven:
      let halfway = DoryX86WideUnsigned(1) << (shift - 1)
      increment =
        discarded > halfway
        || (discarded == halfway
          && truncated & DoryX86WideUnsigned(1) != DoryX86WideUnsigned(0))
    }
    return increment ? truncated + DoryX86WideUnsigned(1) : truncated
  }
}
