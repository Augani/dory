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
  }

  let materialized: DoryX86RFLAGS
  let operation: Operation
  let width: DoryIRIntegerWidth
  let result: UInt64
  let source1: UInt64
  let source2: UInt64

  init(
    materialized: DoryX86RFLAGS,
    operation: Operation = .materialized,
    width: DoryIRIntegerWidth = .i64,
    result: UInt64 = 0,
    source1: UInt64 = 0,
    source2: UInt64 = 0
  ) {
    self.materialized = materialized
    self.operation = operation
    self.width = width
    self.result = result
    self.source1 = source1
    self.source2 = source2
  }

  init?<Context: RandomAccessCollection>(context: Context)
  where Context.Element == UInt64, Context.Index == Int {
    guard context.count == DoryARM64Tier1ABI.contextWordCount,
      let operation = Operation(rawValue: context[
        DoryARM64Tier1ABI.ContextWord.lazyFlagsOperation.rawValue]),
      let width = DoryIRIntegerWidth(rawValue: UInt8(truncatingIfNeeded: context[
        DoryARM64Tier1ABI.ContextWord.lazyFlagsWidth.rawValue]))
    else { return nil }
    self.init(
      materialized: .init(rawValue: context[DoryARM64Tier1ABI.ContextWord.rflags.rawValue]),
      operation: operation,
      width: width,
      result: context[DoryARM64Tier1ABI.ContextWord.lazyFlagsResult.rawValue],
      source1: context[DoryARM64Tier1ABI.ContextWord.lazyFlagsSource1.rawValue],
      source2: context[DoryARM64Tier1ABI.ContextWord.lazyFlagsSource2.rawValue]
    )
  }

  func write(to context: inout [UInt64]) {
    precondition(context.count == DoryARM64Tier1ABI.contextWordCount)
    context[DoryARM64Tier1ABI.ContextWord.rflags.rawValue] = materialized.rawValue
    context[DoryARM64Tier1ABI.ContextWord.lazyFlagsOperation.rawValue] = operation.rawValue
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

  private func set(
    _ flag: DoryX86RFLAGS,
    _ enabled: Bool,
    in flags: inout DoryX86RFLAGS
  ) {
    if enabled { flags.insert(flag) } else { flags.remove(flag) }
  }
}
