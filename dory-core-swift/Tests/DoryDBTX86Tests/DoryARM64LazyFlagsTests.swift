import Testing

@testable import DoryDBTX86

@Suite struct DoryARM64LazyFlagsTests {
  @Test func contextEncodingIsAppendOnlyAndRoundTripsPendingState() throws {
    let state = DoryARM64LazyFlagsState(
      materialized: [.reservedOne, .carry, .direction],
      operation: .addWithCarry,
      width: .i16,
      result: 0x8000,
      source1: 0x7FFF,
      source2: 0
    )
    var context = [UInt64](repeating: 0, count: DoryARM64Tier1ABI.contextWordCount)
    state.write(to: &context)

    #expect(DoryARM64Tier1ABI.ContextWord.lazyFlagsOperation.rawValue == 43)
    #expect(DoryARM64Tier1ABI.ContextWord.lazyFlagsSource2.rawValue == 47)
    #expect(try #require(DoryARM64LazyFlagsState(context: context)) == state)
  }

  @Test func baselineContextPopulationClearsEveryPendingLazyField() throws {
    let architectural = try DoryX86ArchitecturalState(
      rflags: [.reservedOne, .carry, .direction, .interruptEnable])
    var context = [UInt64](repeating: .max, count: DoryARM64Tier1ABI.contextWordCount)
    context.withUnsafeMutableBufferPointer {
      DoryARM64BaselineExecutor.populateExecutionContext(
        $0, from: architectural, memory: nil)
    }

    let lazy = try #require(DoryARM64LazyFlagsState(context: context))
    #expect(lazy.operation == .materialized)
    #expect(lazy.result == 0)
    #expect(lazy.source1 == 0)
    #expect(lazy.source2 == 0)
    #expect(lazy.materialize() == architectural.rflags)
  }

  @Test func binaryArithmeticAndLogicalMaterializationMatchesEagerReference() {
    let widths: [DoryIRIntegerWidth] = [.i8, .i16, .i32, .i64]
    let operations: [DoryARM64LazyFlagsState.Operation] = [
      .add, .addWithCarry, .subtract, .subtractWithBorrow, .logical,
    ]
    let values: [UInt64] = [0, 1, 0x0F, 0x10, 0x7F, 0x80, 0xFF, .max]
    for width in widths {
      let mask = width == .i64 ? UInt64.max : (UInt64(1) << UInt64(width.rawValue)) - 1
      for operation in operations {
        for lhs in values.map({ $0 & mask }) {
          for rhs in values.map({ $0 & mask }) {
            for carry in [false, true] {
              let prior: DoryX86RFLAGS = carry
                ? [.reservedOne, .carry, .direction, .interruptEnable]
                : [.reservedOne, .direction, .interruptEnable]
              let carryValue: UInt64 = carry ? 1 : 0
              let result: UInt64 =
                switch operation {
                case .add: (lhs &+ rhs) & mask
                case .addWithCarry: (lhs &+ rhs &+ carryValue) & mask
                case .subtract: (lhs &- rhs) & mask
                case .subtractWithBorrow: (lhs &- rhs &- carryValue) & mask
                case .logical: (lhs ^ rhs) & mask
                default: 0
                }
              let state = DoryARM64LazyFlagsState(
                materialized: prior,
                operation: operation,
                width: width,
                result: result,
                source1: lhs,
                source2: rhs
              )
              #expect(state.materialize() == eagerFlags(
                operation: operation, width: width, lhs: lhs, rhs: rhs,
                result: result, prior: prior))
            }
          }
        }
      }
    }
  }

  @Test func unaryMaterializationPreservesCarryForIncrementAndDecrement() {
    for width: DoryIRIntegerWidth in [.i8, .i16, .i32, .i64] {
      let mask = width == .i64 ? UInt64.max : (UInt64(1) << UInt64(width.rawValue)) - 1
      let sign = UInt64(1) << UInt64(width.rawValue - 1)
      for carry in [false, true] {
        let prior: DoryX86RFLAGS = carry ? [.reservedOne, .carry, .direction] : [.reservedOne, .direction]
        for (operation, lhs, result): (DoryARM64LazyFlagsState.Operation, UInt64, UInt64) in [
          (.increment, sign - 1, sign),
          (.increment, mask, 0),
          (.decrement, sign, sign - 1),
          (.decrement, 0, mask),
          (.negate, sign, sign),
          (.negate, 0, 0),
        ] {
          let state = DoryARM64LazyFlagsState(
            materialized: prior, operation: operation, width: width,
            result: result, source1: lhs)
          let flags = state.materialize()
          if operation == .increment || operation == .decrement {
            #expect(flags.contains(.carry) == carry)
          } else {
            #expect(flags.contains(.carry) == (lhs != 0))
          }
          #expect(flags.contains(.direction))
          #expect(flags.contains(.reservedOne))
        }
      }
    }
  }

  @Test func shiftAndRotateMaterializersMatchInterpreterAcrossWidthsAndCounts() throws {
    let cases: [(operation: DoryARM64LazyFlagsState.Operation, extension: UInt8)] = [
      (.rotateLeft, 0), (.rotateRight, 1), (.shiftLeft, 4),
      (.logicalShiftRight, 5), (.arithmeticShiftRight, 7),
    ]
    for width: DoryIRIntegerWidth in [.i8, .i16, .i32, .i64] {
      let mask = width == .i64 ? UInt64.max : (UInt64(1) << UInt64(width.rawValue)) - 1
      let values = [UInt64(0), 1, mask >> 1, UInt64(1) << UInt64(width.rawValue - 1), mask]
      let counts = [UInt8(0), 1, UInt8(width.rawValue - 1), UInt8(width.rawValue),
        UInt8(width.rawValue &+ 1), 31, 63]
      for testCase in cases {
        for value in values {
          for count in counts {
            let bytes = shiftBytes(
              width: width, operationExtension: testCase.extension, count: count)
            let prior: DoryX86RFLAGS = [
              .reservedOne, .carry, .parity, .auxiliaryCarry, .zero, .sign,
              .direction, .overflow,
            ]
            var interpreted = try DoryX86ArchitecturalState(
              registers: .init(rax: value), rip: 0x100, rflags: prior)
            let memory = try DoryX86ByteArrayMemory(byteCount: 0x1000)
            try memory.write(at: 0x100, bytes: bytes)
            guard case .retired = DoryX86Interpreter().step(
              state: &interpreted, memory: memory, mode: .long64)
            else {
              Issue.record("interpreter did not retire \(testCase.operation) \(width) \(count)")
              continue
            }
            let lazy = DoryARM64LazyFlagsState(
              materialized: prior,
              operation: testCase.operation,
              width: width,
              result: interpreted.registers.rax & mask,
              source1: value,
              source2: UInt64(count)
            )
            #expect(lazy.materialize() == interpreted.rflags)
          }
        }
      }
    }
  }
}

private func shiftBytes(
  width: DoryIRIntegerWidth,
  operationExtension: UInt8,
  count: UInt8
) -> [UInt8] {
  let modRM = UInt8(0xC0) | operationExtension << 3
  switch width {
  case .i8: return [0xC0, modRM, count]
  case .i16: return [0x66, 0xC1, modRM, count]
  case .i32: return [0xC1, modRM, count]
  case .i64: return [0x48, 0xC1, modRM, count]
  }
}

private func eagerFlags(
  operation: DoryARM64LazyFlagsState.Operation,
  width: DoryIRIntegerWidth,
  lhs: UInt64,
  rhs: UInt64,
  result: UInt64,
  prior: DoryX86RFLAGS
) -> DoryX86RFLAGS {
  let mask = width == .i64 ? UInt64.max : (UInt64(1) << UInt64(width.rawValue)) - 1
  let sign = UInt64(1) << UInt64(width.rawValue - 1)
  let carryIn: UInt64 = prior.contains(.carry) ? 1 : 0
  var flags = prior
  func set(_ flag: DoryX86RFLAGS, _ enabled: Bool) {
    if enabled { flags.insert(flag) } else { flags.remove(flag) }
  }
  switch operation {
  case .add, .addWithCarry:
    let carry = operation == .addWithCarry ? carryIn : 0
    let first = lhs.addingReportingOverflow(rhs)
    let second = first.partialValue.addingReportingOverflow(carry)
    set(.carry, first.overflow || second.overflow || first.partialValue > mask
      || second.partialValue > mask)
    set(.overflow, (~(lhs ^ rhs) & (lhs ^ result) & sign) != 0)
    set(.auxiliaryCarry, (lhs & 0xF) + (rhs & 0xF) + carry > 0xF)
  case .subtract, .subtractWithBorrow:
    let borrow = operation == .subtractWithBorrow ? carryIn : 0
    set(.carry, lhs < rhs || (borrow == 1 && lhs == rhs))
    set(.overflow, ((lhs ^ rhs) & (lhs ^ result) & sign) != 0)
    set(.auxiliaryCarry, (lhs & 0xF) < (rhs & 0xF) + borrow)
  case .logical:
    flags.remove([.carry, .overflow, .auxiliaryCarry])
  default:
    break
  }
  set(.zero, result == 0)
  set(.sign, result & sign != 0)
  set(.parity, (result & 0xFF).nonzeroBitCount.isMultiple(of: 2))
  flags.insert(.reservedOne)
  return flags
}
