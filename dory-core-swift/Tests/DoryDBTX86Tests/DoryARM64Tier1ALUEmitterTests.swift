import Testing

@testable import DoryDBTX86

@Suite struct DoryARM64Tier1ALUEmitterTests {
  @Test func nativeProducersPersistLazyRecordsAndMatchInterpreter() throws {
    #if arch(arm64)
      let cases: [(DoryIRBinaryOperation, UInt8, DoryARM64LazyFlagsState.Operation, Bool)] = [
        (.add, 0x01, .add, true),
        (.or, 0x09, .logical, true),
        (.and, 0x21, .logical, true),
        (.subtract, 0x29, .subtract, true),
        (.xor, 0x31, .logical, true),
        (.compare, 0x39, .subtract, false),
        (.test, 0x85, .logical, false),
      ]
      let values: [(UInt64, UInt64)] = [
        (0, 0), (1, 1), (0, 1),
        (0x7FFF_FFFF, 1), (0x8000_0000, 0xFFFF_FFFF),
        (0x7FFF_FFFF_FFFF_FFFF, 1), (.max, 1),
      ]
      let prior: DoryX86RFLAGS = [
        .reservedOne, .carry, .parity, .auxiliaryCarry, .direction, .overflow,
      ]

      for width: DoryIRIntegerWidth in [.i32, .i64] {
        let mask = width == .i64 ? UInt64.max : UInt64(UInt32.max)
        for (operation, opcode, lazyOperation, writesDestination) in cases {
          var words: [UInt32] = []
          DoryARM64Tier1BoundaryEmitter().emitEntry(into: &words)
          let producer = DoryARM64Tier1ALUEmitter().emitBinary(
            operation,
            width: width,
            destinationGuestRegister: 0,
            source: .guestRegister(1),
            writesDestination: writesDestination,
            into: &words
          )
          #expect(producer != nil)
          DoryARM64Tier1BoundaryEmitter().emitExit(.dispatch, into: &words)
          let region = try executableRegion(words)

          for (lhs, rhs) in values {
            var context = makeContext(rax: lhs, rcx: rhs, rdx: 0, rflags: prior)
            #expect(try region.execute(at: 0, context: &context) == .dispatch)

            var interpreted = try DoryX86ArchitecturalState(
              registers: .init(rax: lhs, rcx: rhs), rip: 0x100, rflags: prior)
            let memory = try DoryX86ByteArrayMemory(byteCount: 0x1000)
            var bytes = [opcode, UInt8(0xC8)]
            if width == .i64 { bytes.insert(0x48, at: 0) }
            try memory.write(at: 0x100, bytes: bytes)
            guard case .retired = DoryX86Interpreter().step(
              state: &interpreted, memory: memory, mode: .long64)
            else {
              Issue.record("interpreter did not retire \(operation) \(width)")
              continue
            }

            let lazy = try #require(DoryARM64LazyFlagsState(context: context))
            #expect(lazy.operation == lazyOperation)
            #expect(lazy.width == width)
            #expect(lazy.source1 == lhs & mask)
            #expect(lazy.source2 == rhs & mask)
            #expect(lazy.materialized == prior)
            #expect(lazy.materialize() == interpreted.rflags)
            #expect(context[DoryARM64Tier1ABI.ContextWord.rax.rawValue]
              == interpreted.registers.rax)
          }
        }
      }
    #endif
  }

  @Test func fusedCompareConditionsUseNativeNZCVAndPreserveDestinationUpperBits() throws {
    #if arch(arm64)
      let conditions = allX86Conditions.filter {
        $0 != .parity && $0 != .notParity
      }
      let values: [(UInt64, UInt64)] = [
        (0, 0), (0, 1), (1, 0), (.max, 1),
        (0x7FFF_FFFF_FFFF_FFFF, .max), (0x8000_0000_0000_0000, 1),
      ]
      let upper = UInt64(0xA5A5_A5A5_A5A5_A500)
      let prior: DoryX86RFLAGS = [.reservedOne, .direction]

      for condition in conditions {
        var words: [UInt32] = []
        let boundary = DoryARM64Tier1BoundaryEmitter()
        let alu = DoryARM64Tier1ALUEmitter()
        boundary.emitEntry(into: &words)
        let flags = try #require(alu.emitBinary(
          .compare,
          width: .i64,
          destinationGuestRegister: 0,
          source: .guestRegister(1),
          writesDestination: false,
          into: &words
        ))
        #expect(alu.emitFusedSetCondition(
          condition, flags: flags, destinationGuestRegister: 2, into: &words))
        boundary.emitExit(.dispatch, into: &words)
        let region = try executableRegion(words)

        for (lhs, rhs) in values {
          var context = makeContext(rax: lhs, rcx: rhs, rdx: upper, rflags: prior)
          #expect(try region.execute(at: 0, context: &context) == .dispatch)
          let lazy = try #require(DoryARM64LazyFlagsState(context: context))
          let expected = evaluate(condition, flags: lazy.materialize())
          #expect(context[DoryARM64Tier1ABI.ContextWord.rdx.rawValue]
            == upper | (expected ? 1 : 0))
        }
      }
    #endif
  }

  @Test func fusedAdditionAndLogicalConditionsUseTheirNativeCarryDomains() throws {
    #if arch(arm64)
      let cases: [(DoryIRBinaryOperation, [DoryX86Condition])] = [
        (.add, allX86Conditions.filter {
          $0 != .parity && $0 != .notParity && $0 != .belowOrEqual && $0 != .above
        }),
        (.and, allX86Conditions.filter { $0 != .parity && $0 != .notParity }),
      ]
      let values: [(UInt64, UInt64)] = [
        (0, 0), (0, 1), (1, .max), (.max, 1),
        (0x7FFF_FFFF_FFFF_FFFF, 1), (0x8000_0000_0000_0000, .max),
      ]
      let prior: DoryX86RFLAGS = [.reservedOne, .carry, .direction, .overflow]

      for (operation, conditions) in cases {
        for condition in conditions {
          var words: [UInt32] = []
          let boundary = DoryARM64Tier1BoundaryEmitter()
          let alu = DoryARM64Tier1ALUEmitter()
          boundary.emitEntry(into: &words)
          let flags = try #require(alu.emitBinary(
            operation,
            width: .i64,
            destinationGuestRegister: 0,
            source: .guestRegister(1),
            writesDestination: true,
            into: &words
          ))
          #expect(alu.emitFusedSetCondition(
            condition, flags: flags, destinationGuestRegister: 2, into: &words))
          boundary.emitExit(.dispatch, into: &words)
          let region = try executableRegion(words)

          for (lhs, rhs) in values {
            var context = makeContext(rax: lhs, rcx: rhs, rdx: 0xCC00, rflags: prior)
            #expect(try region.execute(at: 0, context: &context) == .dispatch)
            let lazy = try #require(DoryARM64LazyFlagsState(context: context))
            let expected = evaluate(condition, flags: lazy.materialize())
            #expect(context[DoryARM64Tier1ABI.ContextWord.rdx.rawValue]
              == 0xCC00 | (expected ? 1 : 0))
          }
        }
      }
    #endif
  }

  @Test func fusionRejectsParityAndNonNativeAdditionCarryZeroCombinations() throws {
    let alu = DoryARM64Tier1ALUEmitter()
    var words: [UInt32] = []
    let compareFlags = try #require(alu.emitBinary(
      .compare,
      width: .i64,
      destinationGuestRegister: 0,
      source: .immediate(1),
      writesDestination: false,
      into: &words
    ))
    let compareEnd = words.count
    #expect(!alu.emitFusedSetCondition(
      .parity, flags: compareFlags, destinationGuestRegister: 1, into: &words))
    #expect(words.count == compareEnd)

    let addFlags = try #require(alu.emitBinary(
      .add,
      width: .i32,
      destinationGuestRegister: 0,
      source: .immediate(1),
      writesDestination: true,
      into: &words
    ))
    let addEnd = words.count
    #expect(!alu.emitFusedSetCondition(
      .belowOrEqual, flags: addFlags, destinationGuestRegister: 1, into: &words))
    #expect(!alu.emitFusedSetCondition(
      .above, flags: addFlags, destinationGuestRegister: 1, into: &words))
    #expect(words.count == addEnd)
  }
}

private func executableRegion(_ words: [UInt32]) throws -> DoryJITExecutableRegion {
  let block = DoryARM64CompiledBlock(
    guestStart: 0,
    guestByteCount: 1,
    guestInstructionCount: 1,
    machineWords: words,
    tier: .baseline,
    exitCode: .dispatch
  )
  let region = try DoryJITExecutableRegion(minimumCapacity: 4_096)
  try region.publish(block, at: 0)
  return region
}

private func makeContext(
  rax: UInt64,
  rcx: UInt64,
  rdx: UInt64,
  rflags: DoryX86RFLAGS
) -> [UInt64] {
  var context = [UInt64](repeating: 0, count: DoryARM64Tier1ABI.contextWordCount)
  context[DoryARM64Tier1ABI.ContextWord.rax.rawValue] = rax
  context[DoryARM64Tier1ABI.ContextWord.rcx.rawValue] = rcx
  context[DoryARM64Tier1ABI.ContextWord.rdx.rawValue] = rdx
  context[DoryARM64Tier1ABI.ContextWord.rflags.rawValue] = rflags.rawValue
  context[DoryARM64Tier1ABI.ContextWord.lazyFlagsWidth.rawValue] =
    UInt64(DoryIRIntegerWidth.i64.rawValue)
  return context
}

private func evaluate(_ condition: DoryX86Condition, flags: DoryX86RFLAGS) -> Bool {
  let overflow = flags.contains(.overflow)
  let carry = flags.contains(.carry)
  let zero = flags.contains(.zero)
  let sign = flags.contains(.sign)
  let parity = flags.contains(.parity)
  return switch condition {
  case .overflow: overflow
  case .notOverflow: !overflow
  case .below: carry
  case .aboveOrEqual: !carry
  case .equal: zero
  case .notEqual: !zero
  case .belowOrEqual: carry || zero
  case .above: !carry && !zero
  case .sign: sign
  case .notSign: !sign
  case .parity: parity
  case .notParity: !parity
  case .less: sign != overflow
  case .greaterOrEqual: sign == overflow
  case .lessOrEqual: zero || sign != overflow
  case .greater: !zero && sign == overflow
  }
}

private let allX86Conditions: [DoryX86Condition] = [
  .overflow, .notOverflow, .below, .aboveOrEqual,
  .equal, .notEqual, .belowOrEqual, .above,
  .sign, .notSign, .parity, .notParity,
  .less, .greaterOrEqual, .lessOrEqual, .greater,
]
