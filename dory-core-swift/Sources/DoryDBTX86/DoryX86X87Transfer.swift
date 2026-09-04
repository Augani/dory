// Intel SDM 092 Vol. 1 §§4.9.2, 8.1.7, 8.2.2 and 8.5.1–8.5.6;
// Vol. 2A FBLD/FBSTP/FILD/FIST/FISTTP/FLD/FST.
// This helper keeps transfer classification on the guest's original payload.
// In particular, converting binary80 through a host float would destroy the
// unsupported and pseudo-denormal encodings whose tags and exceptions matter.
enum DoryX86X87Transfer {
  enum Binary80Class {
    case zero, normal, denormal, pseudoDenormal, infinity, quietNaN, signalingNaN, unsupported

    var tag: UInt16 {
      switch self {
      case .zero: 1
      case .normal: 0
      default: 2
      }
    }

    var isDenormalOperand: Bool {
      self == .denormal || self == .pseudoDenormal
    }

    var isInvalidIntegerOrBCDSource: Bool {
      switch self {
      case .infinity, .quietNaN, .signalingNaN, .unsupported: true
      default: false
      }
    }
  }

  struct LoadResult {
    let bytes: [UInt8]
    let tag: UInt16
    let flags: UInt16
  }

  struct StoreResult {
    let bytes: [UInt8]
    let flags: UInt16
    let roundedUp: Bool
    let suppressWriteAndPop: Bool
  }

  static func binary80Class(_ bytes: [UInt8]) -> Binary80Class {
    precondition(bytes.count == 10)
    let significand = read(bytes, count: 8)
    let exponent = (UInt16(bytes[8]) | UInt16(bytes[9]) << 8) & 0x7FFF
    let integer = significand & (UInt64(1) << 63) != 0
    let fraction = significand & ~(UInt64(1) << 63)
    switch exponent {
    case 0 where significand == 0: return .zero
    case 0 where integer: return .pseudoDenormal
    case 0: return .denormal
    case 0x7FFF where !integer: return .unsupported
    case 0x7FFF where fraction == 0: return .infinity
    case 0x7FFF where fraction & (UInt64(1) << 62) != 0: return .quietNaN
    case 0x7FFF: return .signalingNaN
    default: return integer ? .normal : .unsupported
    }
  }

  static func load(bytes: [UInt8], format: DoryX87MemoryFormat) -> LoadResult {
    precondition(bytes.count == format.byteCount)
    switch format {
    case .float32:
      let bits = UInt32(truncatingIfNeeded: read(bytes, count: 4))
      let exponent = bits >> 23 & 0xFF
      let fraction = bits & 0x007F_FFFF
      let signaling = exponent == 0xFF && fraction != 0 && fraction & 0x0040_0000 == 0
      let denormal = exponent == 0 && fraction != 0
      let widened = widenFloat32(bits, quiet: signaling)
      return .init(bytes: widened, tag: binary80Class(widened).tag,
        flags: signaling ? 1 : denormal ? 2 : 0)
    case .float64:
      let bits = read(bytes, count: 8)
      let exponent = bits >> 52 & 0x7FF
      let fraction = bits & 0x000F_FFFF_FFFF_FFFF
      let signaling = exponent == 0x7FF && fraction != 0
        && fraction & 0x0008_0000_0000_0000 == 0
      let denormal = exponent == 0 && fraction != 0
      let widened = widenFloat64(bits, quiet: signaling)
      return .init(bytes: widened, tag: binary80Class(widened).tag,
        flags: signaling ? 1 : denormal ? 2 : 0)
    case .extended80:
      return .init(bytes: bytes, tag: binary80Class(bytes).tag, flags: 0)
    case .signedInteger16:
      return exactInteger(Int64(Int16(bitPattern: UInt16(truncatingIfNeeded: read(bytes, count: 2)))))
    case .signedInteger32:
      return exactInteger(Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: read(bytes, count: 4)))))
    case .signedInteger64:
      return exactInteger(Int64(bitPattern: read(bytes, count: 8)))
    }
  }

  static func registerLoad(bytes: [UInt8]) -> LoadResult {
    .init(bytes: bytes, tag: binary80Class(bytes).tag, flags: 0)
  }

  static func packedBCDLoad(_ bytes: [UInt8]) -> LoadResult {
    precondition(bytes.count == 10)
    // Invalid BCD digits have an architecturally undefined result, but FBLD
    // does not list #IA. Treat each nibble as its unsigned value to keep Dory's
    // result deterministic without inventing a numeric exception.
    var magnitude: UInt64 = 0
    var place: UInt64 = 1
    for byte in bytes.prefix(9) {
      magnitude += UInt64(byte & 0xF) * place
      place *= 10
      magnitude += UInt64(byte >> 4) * place
      place *= 10
    }
    let value = DoryX86ExtendedFloat(unsigned: magnitude, negative: bytes[9] & 0x80 != 0)
    let payload = value.bytes()
    return .init(bytes: payload, tag: binary80Class(payload).tag, flags: 0)
  }

  static func store(
    bytes: [UInt8], format: DoryX87MemoryFormat, truncate: Bool, controlWord: UInt16
  ) -> StoreResult {
    precondition(bytes.count == 10)
    if format == .extended80 {
      return .init(bytes: bytes, flags: 0, roundedUp: false, suppressWriteAndPop: false)
    }
    let classification = binary80Class(bytes)
    let rounding: DoryX86FloatingRounding = truncate ? .towardZero : rounding(controlWord)
    switch format {
    case .signedInteger16, .signedInteger32, .signedInteger64:
      return integerStore(bytes: bytes, classification: classification, format: format,
        rounding: rounding, truncate: truncate, controlWord: controlWord)
    case .float32, .float64:
      return floatingStore(bytes: bytes, classification: classification, format: format,
        rounding: rounding, controlWord: controlWord)
    case .extended80:
      preconditionFailure("handled above")
    }
  }

  static func packedBCDStore(bytes: [UInt8], controlWord: UInt16) -> StoreResult {
    precondition(bytes.count == 10)
    let classification = binary80Class(bytes)
    if classification.isInvalidIntegerOrBCDSource {
      return invalidStore(bytes: DoryX86X87Stack.packedBCDIndefinite, controlWord: controlWord)
    }
    let denormal = classification.isDenormalOperand
    if denormal, controlWord & 2 == 0 {
      return .init(bytes: [], flags: 2, roundedUp: false, suppressWriteAndPop: true)
    }
    let value = DoryX86ExtendedFloat(bytes: bytes)
    let conversion = value.signedIntegerConversion(bitCount: 64, rounding: rounding(controlWord))
    guard let conversion else {
      return invalidStore(bytes: DoryX86X87Stack.packedBCDIndefinite, controlWord: controlWord)
    }
    let magnitude = value.isNegative ? UInt64(0) &- conversion.bits : conversion.bits
    guard magnitude < 1_000_000_000_000_000_000 else {
      return invalidStore(bytes: DoryX86X87Stack.packedBCDIndefinite, controlWord: controlWord)
    }
    var result = [UInt8](repeating: 0, count: 10)
    var remaining = magnitude
    for index in 0..<9 {
      let low = UInt8(remaining % 10); remaining /= 10
      let high = UInt8(remaining % 10); remaining /= 10
      result[index] = low | high << 4
    }
    if value.isNegative { result[9] = 0x80 }
    let flags: UInt16 = (denormal ? 2 : 0) | (conversion.inexact ? 0x20 : 0)
    return .init(bytes: result, flags: flags, roundedUp: conversion.roundedUp,
      suppressWriteAndPop: false)
  }

  static func publish(_ result: StoreResult, state: inout DoryX86FloatingPointState) {
    publish(flags: result.flags, roundedUp: result.roundedUp, state: &state)
  }

  static func publish(flags: UInt16, roundedUp: Bool, state: inout DoryX86FloatingPointState) {
    state.x87StatusWord = (state.x87StatusWord & ~UInt16(0x0200)) | (roundedUp ? 0x0200 : 0)
    state.x87StatusWord |= flags & 0x3F
    DoryX86LegacyFloatingPointPolicy.updateExceptionSummary(state: &state)
  }

  private static func integerStore(
    bytes: [UInt8], classification: Binary80Class, format: DoryX87MemoryFormat,
    rounding: DoryX86FloatingRounding, truncate: Bool, controlWord: UInt16
  ) -> StoreResult {
    let bitCount = format.byteCount * 8
    if classification.isInvalidIntegerOrBCDSource {
      return invalidStore(bytes: integerIndefinite(bitCount), controlWord: controlWord)
    }
    let denormal = classification.isDenormalOperand
    if denormal, controlWord & 2 == 0 {
      return .init(bytes: [], flags: 2, roundedUp: false, suppressWriteAndPop: true)
    }
    let conversion = DoryX86ExtendedFloat(bytes: bytes).signedIntegerConversion(
      bitCount: bitCount, rounding: rounding)
    guard let conversion else {
      return invalidStore(bytes: integerIndefinite(bitCount), controlWord: controlWord)
    }
    let result = (0..<format.byteCount).map {
      UInt8(truncatingIfNeeded: conversion.bits >> UInt64($0 * 8))
    }
    let flags: UInt16 = (denormal ? 2 : 0) | (conversion.inexact ? 0x20 : 0)
    return .init(bytes: result, flags: flags,
      roundedUp: truncate ? false : conversion.roundedUp, suppressWriteAndPop: false)
  }

  private static func floatingStore(
    bytes: [UInt8], classification: Binary80Class, format: DoryX87MemoryFormat,
    rounding: DoryX86FloatingRounding, controlWord: UInt16
  ) -> StoreResult {
    let invalid = classification == .unsupported || classification == .signalingNaN
    if invalid {
      let maskedBytes: [UInt8]
      if classification == .signalingNaN {
        maskedBytes = narrowedNaN(bytes, format: format, quiet: true)
      } else {
        maskedBytes = format == .float32
          ? littleEndian(0xFFC0_0000, count: 4) : littleEndian(0xFFF8_0000_0000_0000, count: 8)
      }
      return invalidStore(bytes: maskedBytes, controlWord: controlWord)
    }
    if classification == .quietNaN {
      return .init(bytes: narrowedNaN(bytes, format: format, quiet: true),
        flags: 0, roundedUp: false, suppressWriteAndPop: false)
    }
    let value = DoryX86ExtendedFloat(bytes: bytes)
    let conversion = format == .float32
      ? value.float32Conversion(rounding: rounding) : value.float64Conversion(rounding: rounding)
    // FST/FSTP explicitly do not report #D for a binary80 denormal source;
    // narrowing it is represented by the ordinary #U/#P result conditions.
    var flags: UInt16 = 0
    if conversion.overflow { flags |= 0x08 | 0x20 }
    let underflow = conversion.tiny && (controlWord & 0x10 == 0 || conversion.inexact)
    if underflow { flags |= 0x10 }
    if conversion.inexact { flags |= 0x20 }
    let unmaskedRange = flags & ~controlWord & 0x18 != 0
    if unmaskedRange {
      // A memory-destination #O/#U suppresses the store and does not report #P.
      flags &= ~UInt16(0x20)
      return .init(bytes: [], flags: flags, roundedUp: false, suppressWriteAndPop: true)
    }
    return .init(bytes: littleEndian(conversion.bits, count: format.byteCount),
      flags: flags, roundedUp: conversion.roundedUp, suppressWriteAndPop: false)
  }

  private static func invalidStore(bytes: [UInt8], controlWord: UInt16) -> StoreResult {
    .init(bytes: controlWord & 1 == 0 ? [] : bytes, flags: 1, roundedUp: false,
      suppressWriteAndPop: controlWord & 1 == 0)
  }

  private static func exactInteger(_ value: Int64) -> LoadResult {
    let bytes = DoryX86ExtendedFloat(value).bytes()
    return .init(bytes: bytes, tag: binary80Class(bytes).tag, flags: 0)
  }

  private static func integerIndefinite(_ bitCount: Int) -> [UInt8] {
    (0..<(bitCount / 8)).map { index in
      index == bitCount / 8 - 1 ? 0x80 : 0
    }
  }

  private static func narrowedNaN(
    _ bytes: [UInt8], format: DoryX87MemoryFormat, quiet: Bool
  ) -> [UInt8] {
    let significand = read(bytes, count: 8)
    let negative = bytes[9] & 0x80 != 0
    if format == .float32 {
      var fraction = UInt32(truncatingIfNeeded: significand >> 40) & 0x007F_FFFF
      if quiet { fraction |= 0x0040_0000 }
      if fraction == 0 { fraction = 0x0040_0000 }
      let bits = (negative ? UInt32(1) << 31 : 0) | 0x7F80_0000 | fraction
      return littleEndian(UInt64(bits), count: 4)
    }
    var fraction = significand >> 11 & 0x000F_FFFF_FFFF_FFFF
    if quiet { fraction |= 0x0008_0000_0000_0000 }
    if fraction == 0 { fraction = 0x0008_0000_0000_0000 }
    let bits = (negative ? UInt64(1) << 63 : 0) | 0x7FF0_0000_0000_0000 | fraction
    return littleEndian(bits, count: 8)
  }

  private static func widenFloat32(_ bits: UInt32, quiet: Bool) -> [UInt8] {
    let negative = bits >> 31 != 0
    let exponent = Int(bits >> 23 & 0xFF)
    var fraction = UInt64(bits & 0x007F_FFFF)
    let extendedExponent: UInt16
    let significand: UInt64
    switch exponent {
    case 0 where fraction == 0:
      extendedExponent = 0; significand = 0
    case 0:
      let highest = 63 - fraction.leadingZeroBitCount
      extendedExponent = UInt16(highest - 149 + 16_383)
      significand = fraction << UInt64(63 - highest)
    case 0xFF:
      extendedExponent = 0x7FFF
      fraction <<= 40
      significand = (UInt64(1) << 63) | fraction | (quiet ? UInt64(1) << 62 : 0)
    default:
      extendedExponent = UInt16(exponent - 127 + 16_383)
      significand = (UInt64(1) << 63) | fraction << 40
    }
    return binary80(significand: significand, exponent: extendedExponent, negative: negative)
  }

  private static func widenFloat64(_ bits: UInt64, quiet: Bool) -> [UInt8] {
    let negative = bits >> 63 != 0
    let exponent = Int(bits >> 52 & 0x7FF)
    var fraction = bits & 0x000F_FFFF_FFFF_FFFF
    let extendedExponent: UInt16
    let significand: UInt64
    switch exponent {
    case 0 where fraction == 0:
      extendedExponent = 0; significand = 0
    case 0:
      let highest = 63 - fraction.leadingZeroBitCount
      extendedExponent = UInt16(highest - 1_074 + 16_383)
      significand = fraction << UInt64(63 - highest)
    case 0x7FF:
      extendedExponent = 0x7FFF
      fraction <<= 11
      significand = (UInt64(1) << 63) | fraction | (quiet ? UInt64(1) << 62 : 0)
    default:
      extendedExponent = UInt16(exponent - 1_023 + 16_383)
      significand = (UInt64(1) << 63) | fraction << 11
    }
    return binary80(significand: significand, exponent: extendedExponent, negative: negative)
  }

  private static func binary80(significand: UInt64, exponent: UInt16, negative: Bool) -> [UInt8] {
    littleEndian(significand, count: 8)
      + littleEndian(UInt64(exponent | (negative ? 0x8000 : 0)), count: 2)
  }

  private static func rounding(_ controlWord: UInt16) -> DoryX86FloatingRounding {
    switch controlWord >> 10 & 3 {
    case 0: .nearestEven
    case 1: .down
    case 2: .up
    default: .towardZero
    }
  }

  private static func read(_ bytes: [UInt8], count: Int) -> UInt64 {
    (0..<count).reduce(UInt64(0)) { $0 | UInt64(bytes[$1]) << UInt64($1 * 8) }
  }

  private static func littleEndian(_ value: UInt64, count: Int) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
  }
}
