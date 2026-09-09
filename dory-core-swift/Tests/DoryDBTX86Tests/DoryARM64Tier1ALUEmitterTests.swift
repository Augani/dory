import Testing

@testable import DoryDBTX86

@Suite struct DoryARM64Tier1ALUEmitterTests {
  @Test func nativeProducersPersistLazyRecordsAndMatchInterpreter() throws {
    #if arch(arm64)
      let cases:
        [(
          DoryIRBinaryOperation, UInt8, UInt8, DoryARM64LazyFlagsState.Operation, Bool
        )] = [
          (.add, 0x00, 0x01, .add, true),
          (.addWithCarry, 0x10, 0x11, .addWithCarry, true),
          (.or, 0x08, 0x09, .logical, true),
          (.and, 0x20, 0x21, .logical, true),
          (.subtract, 0x28, 0x29, .subtract, true),
          (.subtractWithBorrow, 0x18, 0x19, .subtractWithBorrow, true),
          (.xor, 0x30, 0x31, .logical, true),
          (.compare, 0x38, 0x39, .subtract, false),
          (.test, 0x84, 0x85, .logical, false),
        ]
      let values: [(UInt64, UInt64)] = [
        (0, 0), (1, 1), (0, 1), (0x7F, 1), (0x80, 0xFF), (0xFF, 1),
        (0xA5A5_A5A5_A5A5_7FFF, 1), (0x5A5A_5A5A_5A5A_8000, 0xFFFF),
        (0x7FFF_FFFF, 1), (0x8000_0000, 0xFFFF_FFFF),
        (0x7FFF_FFFF_FFFF_FFFF, 1), (.max, 1),
      ]
      let priorFlags: [DoryX86RFLAGS] = [
        [.reservedOne, .parity, .auxiliaryCarry, .direction, .overflow],
        [.reservedOne, .carry, .parity, .auxiliaryCarry, .direction, .overflow],
      ]

      for width: DoryIRIntegerWidth in [.i8, .i16, .i32, .i64] {
        let mask = width == .i64 ? UInt64.max : (UInt64(1) << width.rawValue) - 1
        for (operation, byteOpcode, wideOpcode, lazyOperation, writesDestination) in cases {
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

          for prior in priorFlags {
            for (lhs, rhs) in values {
              var context = makeContext(rax: lhs, rcx: rhs, rdx: 0, rflags: prior)
              #expect(try region.execute(at: 0, context: &context) == .dispatch)

              var interpreted = try DoryX86ArchitecturalState(
                registers: .init(rax: lhs, rcx: rhs), rip: 0x100, rflags: prior)
              let memory = try DoryX86ByteArrayMemory(byteCount: 0x1000)
              var bytes = [width == .i8 ? byteOpcode : wideOpcode, UInt8(0xC8)]
              if width == .i16 { bytes.insert(0x66, at: 0) }
              if width == .i64 { bytes.insert(0x48, at: 0) }
              try memory.write(at: 0x100, bytes: bytes)
              guard
                case .retired = DoryX86Interpreter().step(
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
              #expect(
                context[DoryARM64Tier1ABI.ContextWord.rax.rawValue]
                  == interpreted.registers.rax)
            }
          }
        }
      }
    #endif
  }

  @Test func nativeUnaryProducersMatchInterpreterAndPreserveCarryWhereRequired() throws {
    #if arch(arm64)
      let cases:
        [(
          DoryIRUnaryOperation, [UInt8], [UInt8], DoryARM64LazyFlagsState.Operation
        )] = [
          (.increment, [0xFE, 0xC0], [0xFF, 0xC0], .increment),
          (.decrement, [0xFE, 0xC8], [0xFF, 0xC8], .decrement),
          (.negate, [0xF6, 0xD8], [0xF7, 0xD8], .negate),
        ]
      let values: [UInt64] = [
        0, 1, 0x7F, 0x80, 0xFF,
        0xA5A5_A5A5_A5A5_7FFF, 0x5A5A_5A5A_5A5A_8000,
        0x7FFF_FFFF, 0x8000_0000,
        0x7FFF_FFFF_FFFF_FFFF, 0x8000_0000_0000_0000, .max,
      ]
      let priorFlags: [DoryX86RFLAGS] = [
        [.reservedOne, .direction], [.reservedOne, .carry, .direction],
      ]

      for width: DoryIRIntegerWidth in [.i8, .i16, .i32, .i64] {
        for (operation, byteOpcode, wideOpcode, lazyOperation) in cases {
          var words: [UInt32] = []
          let boundary = DoryARM64Tier1BoundaryEmitter()
          let alu = DoryARM64Tier1ALUEmitter()
          boundary.emitEntry(into: &words)
          let flags = try #require(
            alu.emitUnary(
              operation,
              width: width,
              destinationGuestRegister: 0,
              into: &words
            ))
          #expect(flags.origin == .unary(operation))
          #expect(
            alu.emitFusedSetCondition(
              .equal, flags: flags, destinationGuestRegister: 2, into: &words))
          if operation != .negate {
            let before = words.count
            #expect(
              !alu.emitFusedSetCondition(
                .below, flags: flags, destinationGuestRegister: 2, into: &words))
            #expect(words.count == before)
          }
          boundary.emitExit(.dispatch, into: &words)
          let region = try executableRegion(words)

          for prior in priorFlags {
            for value in values {
              var context = makeContext(rax: value, rcx: 0, rdx: 0xDD00, rflags: prior)
              #expect(try region.execute(at: 0, context: &context) == .dispatch)

              var interpreted = try DoryX86ArchitecturalState(
                registers: .init(rax: value), rip: 0x100, rflags: prior)
              let memory = try DoryX86ByteArrayMemory(byteCount: 0x1000)
              var bytes = width == .i8 ? byteOpcode : wideOpcode
              if width == .i16 { bytes.insert(0x66, at: 0) }
              if width == .i64 { bytes.insert(0x48, at: 0) }
              try memory.write(at: 0x100, bytes: bytes)
              guard
                case .retired = DoryX86Interpreter().step(
                  state: &interpreted, memory: memory, mode: .long64)
              else {
                Issue.record("interpreter did not retire \(operation) \(width)")
                continue
              }

              let lazy = try #require(DoryARM64LazyFlagsState(context: context))
              #expect(lazy.operation == lazyOperation)
              #expect(lazy.materialize() == interpreted.rflags)
              #expect(
                context[DoryARM64Tier1ABI.ContextWord.rax.rawValue]
                  == interpreted.registers.rax)
              #expect(
                context[DoryARM64Tier1ABI.ContextWord.rdx.rawValue]
                  == 0xDD00 | (interpreted.rflags.contains(.zero) ? 1 : 0))
            }
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
        let flags = try #require(
          alu.emitBinary(
            .compare,
            width: .i64,
            destinationGuestRegister: 0,
            source: .guestRegister(1),
            writesDestination: false,
            into: &words
          ))
        #expect(
          alu.emitFusedSetCondition(
            condition, flags: flags, destinationGuestRegister: 2, into: &words))
        boundary.emitExit(.dispatch, into: &words)
        let region = try executableRegion(words)

        for (lhs, rhs) in values {
          var context = makeContext(rax: lhs, rcx: rhs, rdx: upper, rflags: prior)
          #expect(try region.execute(at: 0, context: &context) == .dispatch)
          let lazy = try #require(DoryARM64LazyFlagsState(context: context))
          let expected = evaluate(condition, flags: lazy.materialize())
          #expect(
            context[DoryARM64Tier1ABI.ContextWord.rdx.rawValue]
              == upper | (expected ? 1 : 0))
        }
      }
    #endif
  }

  @Test func narrowCompareConditionsUseWidthCorrectNativeNZCV() throws {
    #if arch(arm64)
      let conditions = allX86Conditions.filter {
        $0 != .parity && $0 != .notParity
      }
      let values: [(UInt64, UInt64)] = [
        (0, 0), (0, 1), (0x7F, 1), (0x80, 1), (0xFF, 1),
        (0xA5A5_A5A5_A5A5_7FFF, 0x5A5A_5A5A_5A5A_8000),
      ]
      let upper = UInt64(0xD3D3_D3D3_D3D3_D300)

      for width: DoryIRIntegerWidth in [.i8, .i16] {
        for condition in conditions {
          var words: [UInt32] = []
          let boundary = DoryARM64Tier1BoundaryEmitter()
          let alu = DoryARM64Tier1ALUEmitter()
          boundary.emitEntry(into: &words)
          let flags = try #require(
            alu.emitBinary(
              .compare,
              width: width,
              destinationGuestRegister: 0,
              source: .guestRegister(1),
              writesDestination: false,
              into: &words
            ))
          #expect(
            alu.emitFusedSetCondition(
              condition, flags: flags, destinationGuestRegister: 2, into: &words))
          boundary.emitExit(.dispatch, into: &words)
          let region = try executableRegion(words)

          for (lhs, rhs) in values {
            var context = makeContext(
              rax: lhs, rcx: rhs, rdx: upper,
              rflags: [.reservedOne, .carry, .direction, .overflow])
            #expect(try region.execute(at: 0, context: &context) == .dispatch)
            let lazy = try #require(DoryARM64LazyFlagsState(context: context))
            #expect(
              context[DoryARM64Tier1ABI.ContextWord.rdx.rawValue]
                == upper | (evaluate(condition, flags: lazy.materialize()) ? 1 : 0))
          }
        }
      }
    #endif
  }

  @Test func narrowCarryArithmeticRequiresMaterializedConsumers() throws {
    let alu = DoryARM64Tier1ALUEmitter()
    for operation: DoryIRBinaryOperation in [.addWithCarry, .subtractWithBorrow] {
      for width: DoryIRIntegerWidth in [.i8, .i16] {
        var words: [UInt32] = []
        let flags = try #require(
          alu.emitBinary(
            operation,
            width: width,
            destinationGuestRegister: 0,
            source: .guestRegister(1),
            writesDestination: true,
            into: &words
          ))
        let producerEnd = words.count
        for condition in allX86Conditions {
          #expect(
            !alu.emitFusedSetCondition(
              condition, flags: flags, destinationGuestRegister: 2, into: &words))
          #expect(words.count == producerEnd)
        }
      }
    }
  }

  @Test func highByteALUProducersMatchInterpreterAndPreserveSurroundingBits() throws {
    #if arch(arm64)
      let cases: [(DoryIRBinaryOperation, UInt8, Bool)] = [
        (.add, 0x00, true), (.addWithCarry, 0x10, true),
        (.or, 0x08, true), (.and, 0x20, true),
        (.subtract, 0x28, true), (.subtractWithBorrow, 0x18, true),
        (.xor, 0x30, true), (.compare, 0x38, false), (.test, 0x84, false),
      ]
      let values: [(UInt64, UInt64)] = [
        (0, 0), (0x0100, 0x0100), (0x7F00, 0x0100),
        (0xA5A5_A5A5_A5A5_8001, 0x5A5A_5A5A_5A5A_FF02),
        (0x0123_4567_89AB_FFCD, 0xFEDC_BA98_7654_0110),
      ]
      let priorFlags: [DoryX86RFLAGS] = [
        [.reservedOne, .direction, .overflow],
        [.reservedOne, .carry, .direction, .overflow],
      ]
      let conditionDestination: UInt64 = 0xCAFE_BABE_DEAD_BE00

      for (operation, opcode, writesDestination) in cases {
        var words: [UInt32] = []
        let boundary = DoryARM64Tier1BoundaryEmitter()
        let alu = DoryARM64Tier1ALUEmitter()
        boundary.emitEntry(into: &words)
        let flags = try #require(
          alu.emitHighByteBinary(
            operation,
            destinationLegacyRegister: 0,
            source: .guestHighByte(1),
            writesDestination: writesDestination,
            into: &words
          ))
        let canFuse = operation != .addWithCarry && operation != .subtractWithBorrow
        #expect(
          alu.emitFusedSetCondition(
            .equal, flags: flags, destinationGuestRegister: 2, into: &words) == canFuse)
        if !canFuse {
          #expect(
            alu.emitMaterializedSetCondition(
              .equal, destinationGuestRegister: 2, into: &words))
        }
        boundary.emitExit(.dispatch, into: &words)
        let region = try executableRegion(words)

        for prior in priorFlags {
          for (destination, source) in values {
            var context = makeContext(
              rax: destination, rcx: source, rdx: conditionDestination,
              rflags: prior)
            #expect(try region.execute(at: 0, context: &context) == .dispatch)

            var interpreted = try DoryX86ArchitecturalState(
              registers: .init(rax: destination, rcx: source),
              rip: 0x100,
              rflags: prior
            )
            let memory = try DoryX86ByteArrayMemory(byteCount: 0x1000)
            try memory.write(at: 0x100, bytes: [opcode, 0xEC])
            guard
              case .retired = DoryX86Interpreter().step(
                state: &interpreted, memory: memory, mode: .long64)
            else {
              Issue.record("interpreter did not retire high-byte \(operation)")
              continue
            }

            let lazy = try #require(DoryARM64LazyFlagsState(context: context))
            #expect(lazy.materialize() == interpreted.rflags)
            #expect(
              context[DoryARM64Tier1ABI.ContextWord.rax.rawValue]
                == interpreted.registers.rax)
            #expect(context[DoryARM64Tier1ABI.ContextWord.rcx.rawValue] == source)
            #expect(
              context[DoryARM64Tier1ABI.ContextWord.rdx.rawValue]
                == conditionDestination
                | (interpreted.rflags.contains(.zero) ? 1 : 0))
          }
        }
      }
    #endif
  }

  @Test func highByteUnaryProducersMatchInterpreter() throws {
    #if arch(arm64)
      let cases: [(DoryIRUnaryOperation, [UInt8])] = [
        (.increment, [0xFE, 0xC4]),
        (.decrement, [0xFE, 0xCC]),
        (.negate, [0xF6, 0xDC]),
      ]
      let values: [UInt64] = [
        0, 0x0100, 0x7F00, 0x8000, 0xFF00,
        0xA5A5_A5A5_A5A5_80CD, 0x0123_4567_89AB_FF10,
      ]
      let priorFlags: [DoryX86RFLAGS] = [
        [.reservedOne, .direction], [.reservedOne, .carry, .direction],
      ]

      for (operation, opcode) in cases {
        var words: [UInt32] = []
        let boundary = DoryARM64Tier1BoundaryEmitter()
        boundary.emitEntry(into: &words)
        _ = try #require(
          DoryARM64Tier1ALUEmitter().emitHighByteUnary(
            operation, destinationLegacyRegister: 0, into: &words))
        boundary.emitExit(.dispatch, into: &words)
        let region = try executableRegion(words)
        for prior in priorFlags {
          for value in values {
            var context = makeContext(rax: value, rcx: 0, rdx: 0, rflags: prior)
            #expect(try region.execute(at: 0, context: &context) == .dispatch)

            var interpreted = try DoryX86ArchitecturalState(
              registers: .init(rax: value), rip: 0x100, rflags: prior)
            let memory = try DoryX86ByteArrayMemory(byteCount: 0x1000)
            try memory.write(at: 0x100, bytes: opcode)
            guard
              case .retired = DoryX86Interpreter().step(
                state: &interpreted, memory: memory, mode: .long64)
            else {
              Issue.record("interpreter did not retire high-byte \(operation)")
              continue
            }
            let lazy = try #require(DoryARM64LazyFlagsState(context: context))
            #expect(lazy.materialize() == interpreted.rflags)
            #expect(
              context[DoryARM64Tier1ABI.ContextWord.rax.rawValue]
                == interpreted.registers.rax)
          }
        }
      }
    #endif
  }

  @Test func shiftAndRotateProducersMatchInterpreterAcrossWidthsAndCounts() throws {
    #if arch(arm64)
      let operations: [(DoryIRShiftOperation, UInt8)] = [
        (.rotateLeft, 0xC0),
        (.rotateRight, 0xC8),
        (.left, 0xE0),
        (.logicalRight, 0xE8),
        (.arithmeticRight, 0xF8),
      ]
      let values: [UInt64] = [
        0, 1, 0x7F, 0x80, 0xFF, 0x7FFF, 0x8000,
        0xA5A5_A5A5_8000_0001, 0x8000_0000_0000_0001, .max,
      ]
      let counts: [UInt8] = [0, 1, 7, 8, 15, 16, 31, 32, 63, 64, 255]
      let prior: DoryX86RFLAGS = [
        .reservedOne, .carry, .parity, .auxiliaryCarry, .direction, .overflow,
      ]

      for width: DoryIRIntegerWidth in [.i8, .i16, .i32, .i64] {
        for (operation, modRM) in operations {
          for countKind in [DoryIRShiftCount.immediate(0), .cl] {
            let emittedCounts: [UInt8] =
              switch countKind {
              case .immediate: counts
              case .cl: [0]
              }
            for emittedCount in emittedCounts {
              let actualCount: DoryIRShiftCount =
                switch countKind {
                case .immediate: .immediate(emittedCount)
                case .cl: .cl
                }
              var words: [UInt32] = []
              let boundary = DoryARM64Tier1BoundaryEmitter()
              boundary.emitEntry(into: &words)
              #expect(
                DoryARM64Tier1ALUEmitter().emitShift(
                  operation,
                  width: width,
                  destinationGuestRegister: 0,
                  count: actualCount,
                  into: &words
                ))
              boundary.emitExit(.dispatch, into: &words)
              let region = try executableRegion(words)
              let runtimeCounts: [UInt8] =
                switch actualCount {
                case .immediate: [emittedCount]
                case .cl: counts
                }

              for rawCount in runtimeCounts {
                for value in values {
                  var context = makeContext(
                    rax: value, rcx: UInt64(rawCount), rdx: 0, rflags: prior)
                  #expect(try region.execute(at: 0, context: &context) == .dispatch)

                  var interpreted = try DoryX86ArchitecturalState(
                    registers: .init(rax: value, rcx: UInt64(rawCount)),
                    rip: 0x100,
                    rflags: prior
                  )
                  let memory = try DoryX86ByteArrayMemory(byteCount: 0x1000)
                  var bytes: [UInt8] = []
                  if width == .i16 { bytes.append(0x66) }
                  if width == .i64 { bytes.append(0x48) }
                  switch actualCount {
                  case .immediate:
                    bytes.append(width == .i8 ? 0xC0 : 0xC1)
                    bytes.append(modRM)
                    bytes.append(rawCount)
                  case .cl:
                    bytes.append(width == .i8 ? 0xD2 : 0xD3)
                    bytes.append(modRM)
                  }
                  try memory.write(at: 0x100, bytes: bytes)
                  guard
                    case .retired = DoryX86Interpreter().step(
                      state: &interpreted, memory: memory, mode: .long64)
                  else {
                    Issue.record("interpreter did not retire \(operation) \(width)")
                    continue
                  }

                  let lazy = try #require(DoryARM64LazyFlagsState(context: context))
                  #expect(lazy.materialize() == interpreted.rflags)
                  #expect(
                    context[DoryARM64Tier1ABI.ContextWord.rax.rawValue]
                      == interpreted.registers.rax)
                }
              }
            }
          }
        }
      }
    #endif
  }

  @Test func zeroShiftCountsPreserveEarlierLazyFlags() throws {
    #if arch(arm64)
      let boundary = DoryARM64Tier1BoundaryEmitter()
      let alu = DoryARM64Tier1ALUEmitter()

      var immediateWords: [UInt32] = []
      boundary.emitEntry(into: &immediateWords)
      _ = try #require(
        alu.emitBinary(
          .add,
          width: .i64,
          destinationGuestRegister: 0,
          source: .guestRegister(2),
          writesDestination: true,
          into: &immediateWords
        ))
      #expect(
        alu.emitShift(
          .left,
          width: .i64,
          destinationGuestRegister: 0,
          count: .immediate(64),
          into: &immediateWords
        ))
      boundary.emitExit(.dispatch, into: &immediateWords)
      let immediateRegion = try executableRegion(immediateWords)
      var immediateContext = makeContext(
        rax: .max, rcx: 0, rdx: 1,
        rflags: [.reservedOne, .direction, .overflow])
      #expect(try immediateRegion.execute(at: 0, context: &immediateContext) == .dispatch)
      let immediateLazy = try #require(DoryARM64LazyFlagsState(context: immediateContext))
      #expect(immediateLazy.operation == .add)
      #expect(immediateLazy.materialize().contains([.carry, .zero]))
      #expect(
        immediateContext[
          DoryARM64Tier1ABI.ContextWord.lazyFlagsMaterializationCount.rawValue] == 0)

      var clWords: [UInt32] = []
      boundary.emitEntry(into: &clWords)
      _ = try #require(
        alu.emitBinary(
          .add,
          width: .i64,
          destinationGuestRegister: 0,
          source: .guestRegister(2),
          writesDestination: true,
          into: &clWords
        ))
      #expect(
        alu.emitShift(
          .left,
          width: .i64,
          destinationGuestRegister: 0,
          count: .cl,
          into: &clWords
        ))
      boundary.emitExit(.dispatch, into: &clWords)
      let clRegion = try executableRegion(clWords)
      var clContext = makeContext(
        rax: .max, rcx: 64, rdx: 1,
        rflags: [.reservedOne, .direction, .overflow])
      #expect(try clRegion.execute(at: 0, context: &clContext) == .dispatch)
      let clLazy = try #require(DoryARM64LazyFlagsState(context: clContext))
      #expect(clLazy.operation == .materialized)
      #expect(clLazy.materialize() == immediateLazy.materialize())
      #expect(
        clContext[
          DoryARM64Tier1ABI.ContextWord.lazyFlagsMaterializationCount.rawValue] == 1)
    #endif
  }

  @Test func rotateThroughCarryProducersMatchInterpreterAcrossWidthsAndCounts() throws {
    #if arch(arm64)
      let operations: [(DoryARM64Tier1ALUEmitter.CarryRotateOperation, UInt8)] = [
        (.left, 0xD0), (.right, 0xD8),
      ]
      let values: [UInt64] = [
        0, 1, 0x7F, 0x80, 0xFF, 0x8001,
        0xA5A5_A5A5_8000_0001, 0x8000_0000_0000_0001, .max,
      ]
      let counts: [UInt8] = [0, 1, 7, 8, 9, 15, 16, 17, 31, 32, 63, 64, 255]
      let priorFlags: [DoryX86RFLAGS] = [
        [.reservedOne, .parity, .auxiliaryCarry, .direction, .overflow],
        [.reservedOne, .carry, .parity, .auxiliaryCarry, .direction, .overflow],
      ]

      for width: DoryIRIntegerWidth in [.i8, .i16, .i32, .i64] {
        for (operation, modRM) in operations {
          for countKind in [DoryIRShiftCount.immediate(0), .cl] {
            let emittedCounts: [UInt8] =
              switch countKind {
              case .immediate: counts
              case .cl: [0]
              }
            for emittedCount in emittedCounts {
              let actualCount: DoryIRShiftCount =
                switch countKind {
                case .immediate: .immediate(emittedCount)
                case .cl: .cl
                }
              var words: [UInt32] = []
              let boundary = DoryARM64Tier1BoundaryEmitter()
              boundary.emitEntry(into: &words)
              #expect(
                DoryARM64Tier1ALUEmitter().emitRotateThroughCarry(
                  operation,
                  width: width,
                  destinationGuestRegister: 0,
                  count: actualCount,
                  into: &words
                ))
              boundary.emitExit(.dispatch, into: &words)
              let region = try executableRegion(words)
              let runtimeCounts: [UInt8] =
                switch actualCount {
                case .immediate: [emittedCount]
                case .cl: counts
                }

              for rawCount in runtimeCounts {
                for prior in priorFlags {
                  for value in values {
                    var context = makeContext(
                      rax: value, rcx: UInt64(rawCount), rdx: 0, rflags: prior)
                    #expect(try region.execute(at: 0, context: &context) == .dispatch)

                    var interpreted = try DoryX86ArchitecturalState(
                      registers: .init(rax: value, rcx: UInt64(rawCount)),
                      rip: 0x100,
                      rflags: prior
                    )
                    let memory = try DoryX86ByteArrayMemory(byteCount: 0x1000)
                    var bytes: [UInt8] = []
                    if width == .i16 { bytes.append(0x66) }
                    if width == .i64 { bytes.append(0x48) }
                    switch actualCount {
                    case .immediate:
                      bytes.append(width == .i8 ? 0xC0 : 0xC1)
                      bytes.append(modRM)
                      bytes.append(rawCount)
                    case .cl:
                      bytes.append(width == .i8 ? 0xD2 : 0xD3)
                      bytes.append(modRM)
                    }
                    try memory.write(at: 0x100, bytes: bytes)
                    guard
                      case .retired = DoryX86Interpreter().step(
                        state: &interpreted, memory: memory, mode: .long64)
                    else {
                      Issue.record("interpreter did not retire RCR/RCL \(width)")
                      continue
                    }

                    let lazy = try #require(DoryARM64LazyFlagsState(context: context))
                    #expect(lazy.materialize() == interpreted.rflags)
                    #expect(
                      context[DoryARM64Tier1ABI.ContextWord.rax.rawValue]
                        == interpreted.registers.rax)
                  }
                }
              }
            }
          }
        }
      }
    #endif
  }

  @Test func doubleShiftProducersMatchInterpreterAcrossWidthsAndCounts() throws {
    #if arch(arm64)
      let operations: [(DoryARM64Tier1ALUEmitter.DoubleShiftOperation, UInt8, UInt8)] = [
        (.left, 0xA4, 0xA5), (.right, 0xAC, 0xAD),
      ]
      let values: [(UInt64, UInt64)] = [
        (0, 0), (1, .max), (0x7FFF, 0x8001), (0x8000, 0x7FFF),
        (0xA5A5_A5A5_8000_0001, 0x5A5A_5A5A_7FFF_FFFE),
        (0x8000_0000_0000_0001, 0x0123_4567_89AB_CDEF),
      ]
      let counts: [UInt8] = [0, 1, 15, 16, 17, 31, 32, 63, 64, 255]
      let prior: DoryX86RFLAGS = [
        .reservedOne, .carry, .parity, .auxiliaryCarry, .direction, .overflow,
      ]

      for width: DoryIRIntegerWidth in [.i16, .i32, .i64] {
        for (operation, immediateOpcode, clOpcode) in operations {
          for countKind in [DoryIRShiftCount.immediate(0), .cl] {
            let emittedCounts: [UInt8] =
              switch countKind {
              case .immediate: counts
              case .cl: [0]
              }
            for emittedCount in emittedCounts {
              let actualCount: DoryIRShiftCount =
                switch countKind {
                case .immediate: .immediate(emittedCount)
                case .cl: .cl
                }
              var words: [UInt32] = []
              let boundary = DoryARM64Tier1BoundaryEmitter()
              boundary.emitEntry(into: &words)
              #expect(
                DoryARM64Tier1ALUEmitter().emitDoubleShift(
                  operation,
                  width: width,
                  destinationGuestRegister: 0,
                  sourceGuestRegister: 2,
                  count: actualCount,
                  into: &words
                ))
              boundary.emitExit(.dispatch, into: &words)
              let region = try executableRegion(words)
              let runtimeCounts: [UInt8] =
                switch actualCount {
                case .immediate: [emittedCount]
                case .cl: counts
                }

              for rawCount in runtimeCounts {
                for (destination, source) in values {
                  var context = makeContext(
                    rax: destination, rcx: UInt64(rawCount), rdx: source, rflags: prior)
                  #expect(try region.execute(at: 0, context: &context) == .dispatch)

                  var interpreted = try DoryX86ArchitecturalState(
                    registers: .init(
                      rax: destination, rcx: UInt64(rawCount), rdx: source),
                    rip: 0x100,
                    rflags: prior
                  )
                  let memory = try DoryX86ByteArrayMemory(byteCount: 0x1000)
                  var bytes: [UInt8] = []
                  if width == .i16 { bytes.append(0x66) }
                  if width == .i64 { bytes.append(0x48) }
                  bytes.append(0x0F)
                  switch actualCount {
                  case .immediate:
                    bytes.append(immediateOpcode)
                    bytes.append(0xD0)
                    bytes.append(rawCount)
                  case .cl:
                    bytes.append(clOpcode)
                    bytes.append(0xD0)
                  }
                  try memory.write(at: 0x100, bytes: bytes)
                  guard
                    case .retired = DoryX86Interpreter().step(
                      state: &interpreted, memory: memory, mode: .long64)
                  else {
                    Issue.record("interpreter did not retire SHLD/SHRD \(width)")
                    continue
                  }

                  let lazy = try #require(DoryARM64LazyFlagsState(context: context))
                  #expect(lazy.materialize() == interpreted.rflags)
                  #expect(
                    context[DoryARM64Tier1ABI.ContextWord.rax.rawValue]
                      == interpreted.registers.rax)
                }
              }
            }
          }
        }
      }
    #endif
  }

  @Test func fusedArithmeticAndLogicalConditionsUseTheirNativeCarryDomains() throws {
    #if arch(arm64)
      let cases: [(DoryIRBinaryOperation, [DoryX86Condition])] = [
        (
          .add,
          allX86Conditions.filter {
            $0 != .parity && $0 != .notParity && $0 != .belowOrEqual && $0 != .above
          }
        ),
        (
          .addWithCarry,
          allX86Conditions.filter {
            $0 != .parity && $0 != .notParity && $0 != .belowOrEqual && $0 != .above
          }
        ),
        (
          .subtractWithBorrow,
          allX86Conditions.filter {
            $0 != .parity && $0 != .notParity
          }
        ),
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
          let flags = try #require(
            alu.emitBinary(
              operation,
              width: .i64,
              destinationGuestRegister: 0,
              source: .guestRegister(1),
              writesDestination: true,
              into: &words
            ))
          #expect(
            alu.emitFusedSetCondition(
              condition, flags: flags, destinationGuestRegister: 2, into: &words))
          boundary.emitExit(.dispatch, into: &words)
          let region = try executableRegion(words)

          for (lhs, rhs) in values {
            var context = makeContext(rax: lhs, rcx: rhs, rdx: 0xCC00, rflags: prior)
            #expect(try region.execute(at: 0, context: &context) == .dispatch)
            let lazy = try #require(DoryARM64LazyFlagsState(context: context))
            let expected = evaluate(condition, flags: lazy.materialize())
            #expect(
              context[DoryARM64Tier1ABI.ContextWord.rdx.rawValue]
                == 0xCC00 | (expected ? 1 : 0))
          }
        }
      }
    #endif
  }

  @Test func fusionRejectsParityAndNonNativeAdditionCarryZeroCombinations() throws {
    let alu = DoryARM64Tier1ALUEmitter()
    var words: [UInt32] = []
    let compareFlags = try #require(
      alu.emitBinary(
        .compare,
        width: .i64,
        destinationGuestRegister: 0,
        source: .immediate(1),
        writesDestination: false,
        into: &words
      ))
    let compareEnd = words.count
    #expect(
      !alu.emitFusedSetCondition(
        .parity, flags: compareFlags, destinationGuestRegister: 1, into: &words))
    #expect(words.count == compareEnd)

    let addFlags = try #require(
      alu.emitBinary(
        .add,
        width: .i32,
        destinationGuestRegister: 0,
        source: .immediate(1),
        writesDestination: true,
        into: &words
      ))
    let addEnd = words.count
    #expect(
      !alu.emitFusedSetCondition(
        .belowOrEqual, flags: addFlags, destinationGuestRegister: 1, into: &words))
    #expect(
      !alu.emitFusedSetCondition(
        .above, flags: addFlags, destinationGuestRegister: 1, into: &words))
    #expect(
      !alu.emitFusedConditionalMove(
        .belowOrEqual,
        flags: addFlags,
        destinationGuestRegister: 1,
        source: .immediate(0x1234),
        into: &words
      ))
    #expect(
      !alu.emitFusedBranch(
        .above, flags: addFlags, taken: 0x10, notTaken: 0x20, into: &words))
    #expect(words.count == addEnd)
  }

  @Test func onDemandMaterializerPublishesFlagsClearsRecordAndCountsOnce() throws {
    #if arch(arm64)
      var words: [UInt32] = []
      let boundary = DoryARM64Tier1BoundaryEmitter()
      boundary.emitEntry(into: &words)
      _ = try #require(
        DoryARM64Tier1ALUEmitter().emitBinary(
          .add,
          width: .i64,
          destinationGuestRegister: 0,
          source: .guestRegister(1),
          writesDestination: true,
          into: &words
        ))
      boundary.emitMaterializeLazyFlags(into: &words)
      boundary.emitMaterializeLazyFlags(into: &words)
      boundary.emitExit(.dispatch, into: &words)
      let region = try executableRegion(words)
      let prior: DoryX86RFLAGS = [.reservedOne, .direction, .overflow]
      var context = makeContext(rax: .max, rcx: 1, rdx: 0x1234, rflags: prior)

      #expect(try region.execute(at: 0, context: &context) == .dispatch)

      let lazy = try #require(DoryARM64LazyFlagsState(context: context))
      #expect(lazy.operation == .materialized)
      #expect(lazy.result == 0)
      #expect(lazy.source1 == 0)
      #expect(lazy.source2 == 0)
      #expect(
        lazy.materialize() == [
          .reservedOne, .carry, .parity, .auxiliaryCarry, .zero, .direction,
        ])
      #expect(context[DoryARM64Tier1ABI.ContextWord.lazyFlagsMaterializationCount.rawValue] == 1)
      #expect(context[DoryARM64Tier1ABI.ContextWord.rax.rawValue] == 0)
      #expect(context[DoryARM64Tier1ABI.ContextWord.rdx.rawValue] == 0x1234)
    #endif
  }

  @Test func materializerFastPathDoesNotCallAHelperForMaterializedFlags() throws {
    #if arch(arm64)
      var words: [UInt32] = []
      let boundary = DoryARM64Tier1BoundaryEmitter()
      boundary.emitEntry(into: &words)
      boundary.emitMaterializeLazyFlags(into: &words)
      boundary.emitExit(.dispatch, into: &words)
      let region = try executableRegion(words)
      var context = makeContext(
        rax: 0x1122, rcx: 0x3344, rdx: 0x5566,
        rflags: [.reservedOne, .carry, .direction])
      context[DoryARM64Tier1ABI.ContextWord.lazyFlagsMaterializer.rawValue] = 0

      #expect(try region.execute(at: 0, context: &context) == .dispatch)
      #expect(context[DoryARM64Tier1ABI.ContextWord.rax.rawValue] == 0x1122)
      #expect(context[DoryARM64Tier1ABI.ContextWord.rcx.rawValue] == 0x3344)
      #expect(context[DoryARM64Tier1ABI.ContextWord.rdx.rawValue] == 0x5566)
      #expect(
        context[DoryARM64Tier1ABI.ContextWord.rflags.rawValue]
          == (DoryX86RFLAGS.reservedOne.union([.carry, .direction])).rawValue)
      #expect(context[DoryARM64Tier1ABI.ContextWord.lazyFlagsMaterializationCount.rawValue] == 0)
    #endif
  }

  @Test func flagObservingHelperReceivesMaterializedState() throws {
    #if arch(arm64)
      let helper: @convention(c) (UnsafeMutablePointer<UInt64>?) -> UInt64 =
        doryTestObserveMaterializedFlags
      var words: [UInt32] = []
      let boundary = DoryARM64Tier1BoundaryEmitter()
      boundary.emitEntry(into: &words)
      _ = try #require(
        DoryARM64Tier1ALUEmitter().emitBinary(
          .subtract,
          width: .i64,
          destinationGuestRegister: 0,
          source: .guestRegister(1),
          writesDestination: true,
          into: &words
        ))
      boundary.emitHelperCall(
        .init(
          target: .tlbResolver,
          arguments: [.contextPointer],
          liveGuestMask: .max,
          requiresMaterializedFlags: true
        ), into: &words)
      boundary.emitExit(.dispatch, into: &words)
      let region = try executableRegion(words)
      var context = makeContext(
        rax: 0, rcx: 1, rdx: 0xCAFE,
        rflags: [.reservedOne, .direction, .overflow])
      context[DoryARM64Tier1ABI.ContextWord.tlbResolver.rawValue] =
        UInt64(unsafeBitCast(helper, to: UInt.self))

      #expect(try region.execute(at: 0, context: &context) == .dispatch)
      #expect(context[DoryARM64Tier1ABI.ContextWord.rax.rawValue] == .max)
      #expect(context[DoryARM64Tier1ABI.ContextWord.rdx.rawValue] == 0xCAFE)
      #expect(context[DoryARM64Tier1ABI.ContextWord.lazyFlagsOperation.rawValue] == 0)
      #expect(context[DoryARM64Tier1ABI.ContextWord.lazyFlagsMaterializationCount.rawValue] == 1)
      #expect(
        context[DoryARM64Tier1ABI.ContextWord.tsc.rawValue]
          == context[DoryARM64Tier1ABI.ContextWord.rflags.rawValue])
      #expect(context[DoryARM64Tier1ABI.ContextWord.fsBase.rawValue] == 0)
    #endif
  }

  @Test func materializedSetConditionsCoverEveryX86Condition() throws {
    #if arch(arm64)
      let values: [(UInt64, UInt64)] = [
        (0, 0), (0, 1), (1, 0), (.max, 1),
        (0x7FFF_FFFF_FFFF_FFFF, 1), (0x8000_0000_0000_0000, .max),
        (0x55, 0xAA), (0x03, 0),
      ]
      let prior: DoryX86RFLAGS = [.reservedOne, .direction]

      for condition in allX86Conditions {
        var words: [UInt32] = []
        let boundary = DoryARM64Tier1BoundaryEmitter()
        let alu = DoryARM64Tier1ALUEmitter()
        boundary.emitEntry(into: &words)
        _ = try #require(
          alu.emitBinary(
            .compare,
            width: .i64,
            destinationGuestRegister: 0,
            source: .guestRegister(1),
            writesDestination: false,
            into: &words
          ))
        #expect(
          alu.emitMaterializedSetCondition(
            condition, destinationGuestRegister: 2, into: &words))
        boundary.emitExit(.dispatch, into: &words)
        let region = try executableRegion(words)

        for (lhs, rhs) in values {
          let upper = UInt64(0xBEEF_CAFE_1234_5600)
          var context = makeContext(rax: lhs, rcx: rhs, rdx: upper, rflags: prior)
          #expect(try region.execute(at: 0, context: &context) == .dispatch)
          let flags = DoryX86RFLAGS(
            rawValue: context[DoryARM64Tier1ABI.ContextWord.rflags.rawValue])
          #expect(
            context[DoryARM64Tier1ABI.ContextWord.rdx.rawValue]
              == upper | (evaluate(condition, flags: flags) ? 1 : 0))
          #expect(context[DoryARM64Tier1ABI.ContextWord.lazyFlagsOperation.rawValue] == 0)
          #expect(
            context[DoryARM64Tier1ABI.ContextWord.lazyFlagsMaterializationCount.rawValue]
              == 1)
        }
      }
    #endif
  }

  @Test func fusedCompareDrivesConditionalMoveAndBranchWithoutMaterialization() throws {
    #if arch(arm64)
      let conditions = allX86Conditions.filter {
        $0 != .parity && $0 != .notParity
      }
      let values: [(UInt64, UInt64)] = [
        (0, 0), (0, 1), (1, 0), (.max, 1),
        (0x7FFF_FFFF_FFFF_FFFF, 1), (0x8000_0000_0000_0000, .max),
      ]
      let originalDestination: UInt64 = 0x1111_2222_3333_4444
      let source: UInt64 = 0xAAAA_BBBB_CCCC_DDDD
      let taken: UInt64 = 0x1234_5678_9ABC_DEF0
      let notTaken: UInt64 = 0x0FED_CBA9_8765_4321

      for condition in conditions {
        var words: [UInt32] = []
        let boundary = DoryARM64Tier1BoundaryEmitter()
        let alu = DoryARM64Tier1ALUEmitter()
        boundary.emitEntry(into: &words)
        let flags = try #require(
          alu.emitBinary(
            .compare,
            width: .i64,
            destinationGuestRegister: 0,
            source: .guestRegister(1),
            writesDestination: false,
            into: &words
          ))
        #expect(
          alu.emitFusedConditionalMove(
            condition,
            flags: flags,
            destinationGuestRegister: 3,
            source: .guestRegister(2),
            into: &words
          ))
        #expect(
          alu.emitFusedBranch(
            condition, flags: flags, taken: taken, notTaken: notTaken, into: &words))
        boundary.emitExit(.dispatch, into: &words)
        let region = try executableRegion(words)

        for (lhs, rhs) in values {
          var context = makeContext(
            rax: lhs, rcx: rhs, rdx: source, rflags: [.reservedOne, .direction])
          context[DoryARM64Tier1ABI.ContextWord.rbx.rawValue] = originalDestination
          #expect(try region.execute(at: 0, context: &context) == .dispatch)
          let lazy = try #require(DoryARM64LazyFlagsState(context: context))
          let matches = evaluate(condition, flags: lazy.materialize())
          #expect(
            context[DoryARM64Tier1ABI.ContextWord.rbx.rawValue]
              == (matches ? source : originalDestination))
          #expect(
            context[DoryARM64Tier1ABI.ContextWord.rip.rawValue]
              == (matches ? taken : notTaken))
          #expect(lazy.operation == .subtract)
          #expect(
            context[DoryARM64Tier1ABI.ContextWord.lazyFlagsMaterializationCount.rawValue]
              == 0)
        }
      }
    #endif
  }

  @Test func logicalConstantConditionsDriveMoveAndBranchWithoutTouchingNZCV() throws {
    #if arch(arm64)
      var words: [UInt32] = []
      let boundary = DoryARM64Tier1BoundaryEmitter()
      let alu = DoryARM64Tier1ALUEmitter()
      boundary.emitEntry(into: &words)
      let flags = try #require(
        alu.emitBinary(
          .and,
          width: .i64,
          destinationGuestRegister: 0,
          source: .guestRegister(1),
          writesDestination: true,
          into: &words
        ))
      #expect(
        alu.emitFusedConditionalMove(
          .below,
          flags: flags,
          destinationGuestRegister: 3,
          source: .immediate(0xFFFF),
          into: &words
        ))
      #expect(
        alu.emitFusedConditionalMove(
          .aboveOrEqual,
          flags: flags,
          destinationGuestRegister: 2,
          source: .immediate(0xABCD_EF01_2345_6789),
          into: &words
        ))
      #expect(
        alu.emitFusedBranch(
          .aboveOrEqual, flags: flags, taken: 0x1111, notTaken: 0x2222, into: &words))
      boundary.emitExit(.dispatch, into: &words)
      let region = try executableRegion(words)
      var context = makeContext(
        rax: 0xFF00, rcx: 0x0FF0, rdx: 0xAAAA,
        rflags: [.reservedOne, .carry, .overflow])
      context[DoryARM64Tier1ABI.ContextWord.rbx.rawValue] = 0xBBBB

      #expect(try region.execute(at: 0, context: &context) == .dispatch)
      #expect(context[DoryARM64Tier1ABI.ContextWord.rbx.rawValue] == 0xBBBB)
      #expect(
        context[DoryARM64Tier1ABI.ContextWord.rdx.rawValue]
          == 0xABCD_EF01_2345_6789)
      #expect(context[DoryARM64Tier1ABI.ContextWord.rip.rawValue] == 0x1111)
      #expect(context[DoryARM64Tier1ABI.ContextWord.lazyFlagsMaterializationCount.rawValue] == 0)
    #endif
  }

  @Test func materializedConditionalMoveAndBranchCoverEveryX86Condition() throws {
    #if arch(arm64)
      let values: [(UInt64, UInt64)] = [
        (0, 0), (0, 1), (1, 0), (.max, 1),
        (0x7FFF_FFFF_FFFF_FFFF, 1), (0x8000_0000_0000_0000, .max),
        (0x55, 0xAA), (0x03, 0),
      ]
      let originalDestination: UInt64 = 0x1020_3040_5060_7080
      let source: UInt64 = 0x8877_6655_4433_2211
      let taken: UInt64 = 0xAAAA_BBBB_CCCC_DDDD
      let notTaken: UInt64 = 0x1111_2222_3333_4444

      for condition in allX86Conditions {
        var words: [UInt32] = []
        let boundary = DoryARM64Tier1BoundaryEmitter()
        let alu = DoryARM64Tier1ALUEmitter()
        boundary.emitEntry(into: &words)
        _ = try #require(
          alu.emitBinary(
            .compare,
            width: .i64,
            destinationGuestRegister: 0,
            source: .guestRegister(1),
            writesDestination: false,
            into: &words
          ))
        #expect(
          alu.emitMaterializedConditionalMove(
            condition,
            destinationGuestRegister: 3,
            source: .guestRegister(2),
            into: &words
          ))
        alu.emitMaterializedBranch(
          condition, taken: taken, notTaken: notTaken, into: &words)
        boundary.emitExit(.dispatch, into: &words)
        let region = try executableRegion(words)

        for (lhs, rhs) in values {
          var context = makeContext(
            rax: lhs, rcx: rhs, rdx: source, rflags: [.reservedOne, .direction])
          context[DoryARM64Tier1ABI.ContextWord.rbx.rawValue] = originalDestination
          #expect(try region.execute(at: 0, context: &context) == .dispatch)
          let flags = DoryX86RFLAGS(
            rawValue: context[DoryARM64Tier1ABI.ContextWord.rflags.rawValue])
          let matches = evaluate(condition, flags: flags)
          #expect(
            context[DoryARM64Tier1ABI.ContextWord.rbx.rawValue]
              == (matches ? source : originalDestination))
          #expect(
            context[DoryARM64Tier1ABI.ContextWord.rip.rawValue]
              == (matches ? taken : notTaken))
          #expect(context[DoryARM64Tier1ABI.ContextWord.lazyFlagsOperation.rawValue] == 0)
          #expect(
            context[DoryARM64Tier1ABI.ContextWord.lazyFlagsMaterializationCount.rawValue]
              == 1)
        }
      }
    #endif
  }

  @Test func LAHFAndPushedFlagsImageConsumeOneMaterializedRecord() throws {
    #if arch(arm64)
      let values: [(UInt64, UInt64)] = [
        (0, 0), (0, 1), (.max, 1),
        (0x7FFF_FFFF_FFFF_FFFF, 1), (0x55, 0xAA),
      ]
      let prior: DoryX86RFLAGS = [
        .reservedOne, .carry, .parity, .auxiliaryCarry, .zero, .sign,
        .direction, .overflow, .resume, .virtual8086,
      ]
      var words: [UInt32] = []
      let boundary = DoryARM64Tier1BoundaryEmitter()
      let alu = DoryARM64Tier1ALUEmitter()
      boundary.emitEntry(into: &words)
      _ = try #require(
        alu.emitBinary(
          .compare,
          width: .i64,
          destinationGuestRegister: 0,
          source: .guestRegister(1),
          writesDestination: false,
          into: &words
        ))
      alu.emitLoadFlagsIntoAH(into: &words)
      #expect(alu.emitPushedFlagsImage(destinationGuestRegister: 2, into: &words))
      boundary.emitExit(.dispatch, into: &words)
      let region = try executableRegion(words)

      for (lhs, rhs) in values {
        var context = makeContext(rax: lhs, rcx: rhs, rdx: 0, rflags: prior)
        #expect(try region.execute(at: 0, context: &context) == .dispatch)
        let flags = DoryX86RFLAGS(
          rawValue: context[DoryARM64Tier1ABI.ContextWord.rflags.rawValue])
        let ah = (flags.rawValue & 0xD5) | DoryX86RFLAGS.reservedOne.rawValue
        #expect(
          context[DoryARM64Tier1ABI.ContextWord.rax.rawValue]
            == (lhs & ~UInt64(0xFF00)) | ah << 8)
        let pushed =
          (flags.rawValue
            & ~(DoryX86RFLAGS.resume.rawValue | DoryX86RFLAGS.virtual8086.rawValue))
          | DoryX86RFLAGS.reservedOne.rawValue
        #expect(context[DoryARM64Tier1ABI.ContextWord.rdx.rawValue] == pushed)
        #expect(context[DoryARM64Tier1ABI.ContextWord.lazyFlagsOperation.rawValue] == 0)
        #expect(context[DoryARM64Tier1ABI.ContextWord.lazyFlagsMaterializationCount.rawValue] == 1)
      }
    #endif
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
  context[DoryARM64Tier1ABI.ContextWord.lazyFlagsMaterializer.rawValue] =
    doryARM64LazyFlagsMaterializerAddress()
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

@_cdecl("dory_test_observe_materialized_flags")
private func doryTestObserveMaterializedFlags(
  _ context: UnsafeMutablePointer<UInt64>?
) -> UInt64 {
  guard let context else { return 0 }
  context[DoryARM64Tier1ABI.ContextWord.tsc.rawValue] =
    context[DoryARM64Tier1ABI.ContextWord.rflags.rawValue]
  context[DoryARM64Tier1ABI.ContextWord.fsBase.rawValue] =
    context[DoryARM64Tier1ABI.ContextWord.lazyFlagsOperation.rawValue]
  return 0
}
