/// Deferred x86 arithmetic flags stored at the tier-1 boundary.
///
/// `materialized` retains every non-arithmetic bit and the previous values of flags that a pending
/// operation leaves undefined. Producers record operands and result; consumers materialize only
/// when architectural RFLAGS are observable.
struct DoryARM64LazyFlagsState: Sendable, Equatable {
  enum Operation: UInt64, Sendable, CaseIterable {
    case materialized = 0
    case add
    case addWithCarry
    case subtract
    case subtractWithBorrow
    case logical
    case increment
    case decrement
    case negate
    case shiftLeft
    case logicalShiftRight
    case arithmeticShiftRight
    case rotateLeft
    case rotateRight
    case rotateCarryLeft
    case rotateCarryRight
    case doubleShiftLeft
    case doubleShiftRight
  }

  let materialized: DoryX86RFLAGS
  let operation: Operation
  let width: DoryIRIntegerWidth
  let result: UInt64
  let source1: UInt64
  let source2: UInt64
  let count: UInt8

  init(
    materialized: DoryX86RFLAGS,
    operation: Operation = .materialized,
    width: DoryIRIntegerWidth = .i64,
    result: UInt64 = 0,
    source1: UInt64 = 0,
    source2: UInt64 = 0,
    count: UInt8 = 0
  ) {
    self.materialized = materialized
    self.operation = operation
    self.width = width
    self.result = result
    self.source1 = source1
    self.source2 = source2
    self.count = count
  }

  init?<Context: RandomAccessCollection>(context: Context)
  where Context.Element == UInt64, Context.Index == Int {
    guard context.count == DoryARM64Tier1ABI.contextWordCount,
      context[DoryARM64Tier1ABI.ContextWord.lazyFlagsOperation.rawValue] & ~0xFFFF == 0,
      let operation = Operation(rawValue: context[
        DoryARM64Tier1ABI.ContextWord.lazyFlagsOperation.rawValue] & 0xFF),
      let width = DoryIRIntegerWidth(rawValue: UInt8(truncatingIfNeeded: context[
        DoryARM64Tier1ABI.ContextWord.lazyFlagsWidth.rawValue]))
    else { return nil }
    self.init(
      materialized: .init(rawValue: context[DoryARM64Tier1ABI.ContextWord.rflags.rawValue]),
      operation: operation,
      width: width,
      result: context[DoryARM64Tier1ABI.ContextWord.lazyFlagsResult.rawValue],
      source1: context[DoryARM64Tier1ABI.ContextWord.lazyFlagsSource1.rawValue],
      source2: context[DoryARM64Tier1ABI.ContextWord.lazyFlagsSource2.rawValue],
      count: UInt8(truncatingIfNeeded: context[
        DoryARM64Tier1ABI.ContextWord.lazyFlagsOperation.rawValue] >> 8)
    )
  }

  func write(to context: inout [UInt64]) {
    precondition(context.count == DoryARM64Tier1ABI.contextWordCount)
    context[DoryARM64Tier1ABI.ContextWord.rflags.rawValue] = materialized.rawValue
    context[DoryARM64Tier1ABI.ContextWord.lazyFlagsOperation.rawValue] =
      operation.rawValue | UInt64(count) << 8
    context[DoryARM64Tier1ABI.ContextWord.lazyFlagsWidth.rawValue] = UInt64(width.rawValue)
    context[DoryARM64Tier1ABI.ContextWord.lazyFlagsResult.rawValue] = result
    context[DoryARM64Tier1ABI.ContextWord.lazyFlagsSource1.rawValue] = source1
    context[DoryARM64Tier1ABI.ContextWord.lazyFlagsSource2.rawValue] = source2
  }

  func materialize() -> DoryX86RFLAGS {
    guard operation != .materialized else {
      return materialized.union(.reservedOne)
    }
    let mask = widthMask
    let sign = UInt64(1) << UInt64(width.rawValue - 1)
    let lhs = source1 & mask
    let rhs = source2 & mask
    let value = result & mask
    var flags = materialized

    switch operation {
    case .materialized:
      break
    case .add, .addWithCarry:
      let carryIn: UInt64 = operation == .addWithCarry && materialized.contains(.carry) ? 1 : 0
      let wide = lhs.addingReportingOverflow(rhs)
      let withCarry = wide.partialValue.addingReportingOverflow(carryIn)
      set(.carry, wide.overflow || withCarry.overflow || wide.partialValue > mask
        || withCarry.partialValue > mask, in: &flags)
      set(.overflow, (~(lhs ^ rhs) & (lhs ^ value) & sign) != 0, in: &flags)
      set(.auxiliaryCarry, (lhs & 0xF) + (rhs & 0xF) + carryIn > 0xF, in: &flags)
      setResultFlags(value, sign: sign, in: &flags)
    case .subtract, .subtractWithBorrow:
      let borrow: UInt64 =
        operation == .subtractWithBorrow && materialized.contains(.carry) ? 1 : 0
      set(.carry, lhs < rhs || (borrow == 1 && lhs == rhs), in: &flags)
      set(.overflow, ((lhs ^ rhs) & (lhs ^ value) & sign) != 0, in: &flags)
      set(.auxiliaryCarry, (lhs & 0xF) < (rhs & 0xF) + borrow, in: &flags)
      setResultFlags(value, sign: sign, in: &flags)
    case .logical:
      flags.remove([.carry, .overflow, .auxiliaryCarry])
      setResultFlags(value, sign: sign, in: &flags)
    case .increment:
      let carry = flags.contains(.carry)
      set(.overflow, (~(lhs ^ 1) & (lhs ^ value) & sign) != 0, in: &flags)
      set(.auxiliaryCarry, (lhs & 0xF) + 1 > 0xF, in: &flags)
      setResultFlags(value, sign: sign, in: &flags)
      set(.carry, carry, in: &flags)
    case .decrement:
      let carry = flags.contains(.carry)
      set(.overflow, ((lhs ^ 1) & (lhs ^ value) & sign) != 0, in: &flags)
      set(.auxiliaryCarry, (lhs & 0xF) < 1, in: &flags)
      setResultFlags(value, sign: sign, in: &flags)
      set(.carry, carry, in: &flags)
    case .negate:
      set(.carry, lhs != 0, in: &flags)
      set(.overflow, ((0 ^ lhs) & (0 ^ value) & sign) != 0, in: &flags)
      set(.auxiliaryCarry, ((0 ^ lhs ^ value) & 0x10) != 0, in: &flags)
      setResultFlags(value, sign: sign, in: &flags)
    case .shiftLeft, .logicalShiftRight, .arithmeticShiftRight,
      .rotateLeft, .rotateRight, .rotateCarryLeft, .rotateCarryRight,
      .doubleShiftLeft, .doubleShiftRight:
      materializeShiftOrRotate(
        operation: operation, original: lhs, result: value, sign: sign, in: &flags)
    }
    flags.insert(.reservedOne)
    return flags
  }

  private var widthMask: UInt64 {
    width == .i64 ? .max : (UInt64(1) << UInt64(width.rawValue)) - 1
  }

  private func setResultFlags(
    _ value: UInt64,
    sign: UInt64,
    in flags: inout DoryX86RFLAGS
  ) {
    set(.zero, value == 0, in: &flags)
    set(.sign, value & sign != 0, in: &flags)
    set(.parity, (value & 0xFF).nonzeroBitCount.isMultiple(of: 2), in: &flags)
  }

  private func materializeShiftOrRotate(
    operation: Operation,
    original: UInt64,
    result: UInt64,
    sign: UInt64,
    in flags: inout DoryX86RFLAGS
  ) {
    let bitCount = Int(width.rawValue)
    let countMask: UInt8 = width == .i64 ? 0x3F : 0x1F
    let maskedCount = Int(count & countMask)
    guard maskedCount != 0 else { return }

    switch operation {
    case .rotateLeft:
      set(.carry, result & 1 != 0, in: &flags)
      if maskedCount == 1 {
        set(.overflow, (result & sign != 0) != flags.contains(.carry), in: &flags)
      }
    case .rotateRight:
      set(.carry, result & sign != 0, in: &flags)
      if maskedCount == 1 {
        set(.overflow, ((result >> UInt64(bitCount - 2)) & 3) == 1
          || ((result >> UInt64(bitCount - 2)) & 3) == 2, in: &flags)
      }
    case .rotateCarryLeft, .rotateCarryRight:
      let effectiveCount = maskedCount % (bitCount + 1)
      guard effectiveCount != 0 else { return }
      var rotated = original
      for _ in 0..<effectiveCount {
        if operation == .rotateCarryLeft {
          let outgoing = rotated & sign != 0
          rotated = ((rotated << 1) | (flags.contains(.carry) ? 1 : 0)) & widthMask
          set(.carry, outgoing, in: &flags)
        } else {
          let outgoing = rotated & 1 != 0
          rotated = (rotated >> 1) | (flags.contains(.carry) ? sign : 0)
          set(.carry, outgoing, in: &flags)
        }
      }
      if maskedCount == 1 {
        if operation == .rotateCarryLeft {
          set(.overflow, (result & sign != 0) != flags.contains(.carry), in: &flags)
        } else {
          let topTwo = (result >> UInt64(bitCount - 2)) & 3
          set(.overflow, topTwo == 1 || topTwo == 2, in: &flags)
        }
      }
    case .shiftLeft:
      set(.carry, maskedCount <= bitCount
        && original & (UInt64(1) << UInt64(bitCount - maskedCount)) != 0, in: &flags)
      if maskedCount == 1 {
        set(.overflow, (result & sign != 0) != flags.contains(.carry), in: &flags)
      }
      flags.remove(.auxiliaryCarry)
      setResultFlags(result, sign: sign, in: &flags)
    case .logicalShiftRight:
      set(.carry, maskedCount <= bitCount
        && original & (UInt64(1) << UInt64(maskedCount - 1)) != 0, in: &flags)
      if maskedCount == 1 { set(.overflow, original & sign != 0, in: &flags) }
      flags.remove(.auxiliaryCarry)
      setResultFlags(result, sign: sign, in: &flags)
    case .arithmeticShiftRight:
      if maskedCount <= bitCount {
        set(.carry, original & (UInt64(1) << UInt64(maskedCount - 1)) != 0, in: &flags)
      } else {
        set(.carry, original & sign != 0, in: &flags)
      }
      if maskedCount == 1 { flags.remove(.overflow) }
      flags.remove(.auxiliaryCarry)
      setResultFlags(result, sign: sign, in: &flags)
    case .doubleShiftLeft, .doubleShiftRight:
      guard maskedCount <= bitCount else {
        flags.remove([.carry, .auxiliaryCarry])
        setResultFlags(result, sign: sign, in: &flags)
        return
      }
      if operation == .doubleShiftLeft {
        set(.carry, original & (UInt64(1) << UInt64(bitCount - maskedCount)) != 0,
          in: &flags)
        if maskedCount == 1 {
          set(.overflow, (result & sign != 0) != flags.contains(.carry), in: &flags)
        }
      } else {
        set(.carry, original & (UInt64(1) << UInt64(maskedCount - 1)) != 0,
          in: &flags)
        if maskedCount == 1 {
          set(.overflow, (original & sign != 0) != (result & sign != 0), in: &flags)
        }
      }
      flags.remove(.auxiliaryCarry)
      setResultFlags(result, sign: sign, in: &flags)
    default:
      preconditionFailure("non-shift operation reached shift materializer")
    }
  }

  private func set(
    _ flag: DoryX86RFLAGS,
    _ enabled: Bool,
    in flags: inout DoryX86RFLAGS
  ) {
    if enabled { flags.insert(flag) } else { flags.remove(flag) }
  }
}

@_cdecl("dory_arm64_materialize_lazy_flags_context")
private func doryARM64MaterializeLazyFlagsContext(
  _ context: UnsafeMutablePointer<UInt64>?
) -> UInt64 {
  guard let context else { return DoryX86RFLAGS.reservedOne.rawValue }
  let buffer = UnsafeBufferPointer(
    start: context,
    count: DoryARM64Tier1ABI.contextWordCount
  )
  guard let pending = DoryARM64LazyFlagsState(context: buffer) else {
    return context[DoryARM64Tier1ABI.ContextWord.rflags.rawValue]
  }
  guard pending.operation != .materialized else { return pending.materialize().rawValue }

  let materialized = pending.materialize().rawValue
  context[DoryARM64Tier1ABI.ContextWord.rflags.rawValue] = materialized
  context[DoryARM64Tier1ABI.ContextWord.lazyFlagsOperation.rawValue] =
    DoryARM64LazyFlagsState.Operation.materialized.rawValue
  context[DoryARM64Tier1ABI.ContextWord.lazyFlagsWidth.rawValue] =
    UInt64(DoryIRIntegerWidth.i64.rawValue)
  context[DoryARM64Tier1ABI.ContextWord.lazyFlagsResult.rawValue] = 0
  context[DoryARM64Tier1ABI.ContextWord.lazyFlagsSource1.rawValue] = 0
  context[DoryARM64Tier1ABI.ContextWord.lazyFlagsSource2.rawValue] = 0
  context[DoryARM64Tier1ABI.ContextWord.lazyFlagsMaterializationCount.rawValue] &+= 1
  return materialized
}

func doryARM64LazyFlagsMaterializerAddress() -> UInt64 {
  let materializer: @convention(c) (UnsafeMutablePointer<UInt64>?) -> UInt64 =
    doryARM64MaterializeLazyFlagsContext
  return UInt64(unsafeBitCast(materializer, to: UInt.self))
}
