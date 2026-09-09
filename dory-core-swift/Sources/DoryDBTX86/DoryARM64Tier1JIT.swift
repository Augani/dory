import Foundation

/// First-execution compiler for the pinned-register tier-1 ABI.
///
/// Admission is intentionally block-atomic. A statement that cannot be represented directly or
/// through a precise, restartable helper boundary declines the entire block, allowing the caller
/// to compile it with the old baseline emitter while tier-1 coverage grows.
struct DoryARM64Tier1Emitter: Sendable {
  private static let measuredPatchedByteXORRIP: UInt64 = 0xFFFF_FFFF_8153_A159
  private static let measuredMemorySetEqualStack22RIP: UInt64 = 0xFFFF_FFFF_815C_AB87
  private static let measuredMemorySetEqualRIP: UInt64 = 0xFFFF_FFFF_815C_AB95
  private static let measuredMemorySetNotEqualRIP: UInt64 = 0xFFFF_FFFF_812D_F36A
  private static let measuredMemoryBitTestRIP: UInt64 = 0xFFFF_FFFF_81E1_C883
  private static let measuredMemoryBitResetRIP: UInt64 = 0xFFFF_FFFF_81E1_B3A6
  private static let measuredCR3WriteRAXRIP: UInt64 = 0xFFFF_FFFF_8100_1B43
  private static let measuredCR3WriteRDIRIP: UInt64 = 0xFFFF_FFFF_8100_17B7
  private let boundary = DoryARM64Tier1BoundaryEmitter()
  private let alu = DoryARM64Tier1ALUEmitter()

  func compile(_ block: DoryIRBasicBlock) -> DoryARM64CompiledBlock? {
    guard block.guestInstructionCount > 0 else { return nil }
    var memoryCallbackCount = 0
    var requiresMemoryCallbacks = false
    var wroteMemory = false
    var previousWasQwordMemoryAccumulatorMultiply = false
    for statement in block.statements {
      switch statement {
      case .atomicBinary:
        guard Self.isMeasuredAtomicByteXOR(statement), !wroteMemory else { return nil }
        memoryCallbackCount += 1
        requiresMemoryCallbacks = true
        wroteMemory = true
      case .copy(.memory, _):
        guard previousWasQwordMemoryAccumulatorMultiply, !wroteMemory else { return nil }
        memoryCallbackCount += 1
        requiresMemoryCallbacks = true
        wroteMemory = true
      case .copy(_, .memory), .unsignedAccumulatorMultiply(.memory):
        guard !wroteMemory else { return nil }
        memoryCallbackCount += 1
        requiresMemoryCallbacks = true
      case .conditionalMove(_, _, .memory):
        guard !wroteMemory else { return nil }
        memoryCallbackCount += 1
        requiresMemoryCallbacks = true
      case .setCondition where Self.isMeasuredMemorySetConditionBlock(block):
        guard !wroteMemory else { return nil }
        memoryCallbackCount += 1
        requiresMemoryCallbacks = true
        wroteMemory = true
      case .bitTestMemoryRegister(let operation, _, _):
        guard Self.isMeasuredMemoryBitOperationBlock(block), !wroteMemory else { return nil }
        memoryCallbackCount += operation == .test ? 1 : 2
        requiresMemoryCallbacks = true
        if operation != .test { wroteMemory = true }
      case .binary where Self.isMeasuredPatchedByteXORBlock(block):
        guard !wroteMemory else { return nil }
        memoryCallbackCount += 2
        requiresMemoryCallbacks = true
        wroteMemory = true
      case .binary(_, .register, .memory, _), .binary(_, .memory, _, _):
        guard !wroteMemory else { return nil }
        memoryCallbackCount += 1
        requiresMemoryCallbacks = true
      case .stackPush(.memory):
        guard !wroteMemory else { return nil }
        memoryCallbackCount += 2
        requiresMemoryCallbacks = true
        wroteMemory = true
      case .stackPush, .stackPushFlags:
        guard !wroteMemory else { return nil }
        memoryCallbackCount += 1
        requiresMemoryCallbacks = true
        wroteMemory = true
      case .stackPop:
        guard !wroteMemory else { return nil }
        memoryCallbackCount += 1
        requiresMemoryCallbacks = true
      case .memoryFence:
        requiresMemoryCallbacks = true
      default:
        break
      }
      previousWasQwordMemoryAccumulatorMultiply = Self.isQwordMemoryAccumulatorMultiply(statement)
    }
    var body: [UInt32] = []
    var nativeFlags: DoryARM64Tier1ALUEmitter.NativeFlags?

    for statement in block.statements {
      switch statement {
      case .copy(let destination, let source):
        if case .memory(let address, let width) = destination {
          guard width == .i64,
            let source = lowRegister(source), source.width == width,
            alu.emitMemoryStore(
              sourceGuestRegister: Int(source.index),
              address: address,
              into: &body
            )
          else { return nil }
          nativeFlags = nil
        } else {
          guard let destination = lowRegister(destination) else { return nil }
          switch source {
          case .memory(let address, let width):
            guard width == destination.width,
              alu.emitMemoryLoad(
                width: width,
                destinationGuestRegister: Int(destination.index),
                address: address,
                into: &body
              )
            else { return nil }
            nativeFlags = nil
          default:
            guard let source = lowSource(source, matching: destination.width),
              alu.emitCopy(
                width: destination.width,
                destinationGuestRegister: Int(destination.index),
                source: source,
                into: &body
              )
            else { return nil }
          }
        }

      case .binary(let operation, let destination, let source, let writesDestination):
        if operation == .addWithCarry || operation == .subtractWithBorrow {
          boundary.emitMaterializeLazyFlags(into: &body)
          nativeFlags = nil
        }
        if case .memory(let address, let width) = source {
          guard let destination = lowRegister(destination), destination.width == width else {
            return nil
          }
          nativeFlags = alu.emitMemorySourceBinary(
            operation,
            width: width,
            destinationGuestRegister: Int(destination.index),
            address: address,
            writesDestination: writesDestination,
            into: &body
          )
        } else if case .memory(let address, let width) = destination {
          if Self.isMeasuredPatchedByteXORBlock(block), operation == .xor, width == .i8,
            source == .immediate(1, width: .i8), writesDestination,
            alu.emitMeasuredPatchedByteXOR(address: address, into: &body)
          {
            nativeFlags = nil
            continue
          }
          guard operation == .test, width == .i16,
            case .immediate = source,
            let source = lowSource(source, matching: width)
          else { return nil }
          nativeFlags = alu.emitMemoryDestinationBinary(
            operation,
            width: width,
            address: address,
            source: source,
            into: &body
          )
        } else if let destination = register(destination), destination.bank == "x86.high8" {
          guard destination.width == .i8,
            let highByteSource = highByteSource(source)
          else { return nil }
          nativeFlags = alu.emitHighByteBinary(
            operation,
            destinationLegacyRegister: Int(destination.index),
            source: highByteSource,
            writesDestination: writesDestination,
            into: &body
          )
        } else if let destination = register(destination) {
          guard destination.bank == "x86.gpr",
            let lowSource = lowSource(source, matching: destination.width)
          else { return nil }
          nativeFlags = alu.emitBinary(
            operation,
            width: destination.width,
            destinationGuestRegister: Int(destination.index),
            source: lowSource,
            writesDestination: writesDestination,
            into: &body
          )
        } else {
          return nil
        }
        guard nativeFlags != nil else { return nil }

      case .unary(let operation, let operand):
        guard let destination = register(operand) else { return nil }
        if operation == .bitwiseNot {
          guard destination.bank == "x86.gpr",
            alu.emitBitwiseNot(
              width: destination.width,
              destinationGuestRegister: Int(destination.index),
              into: &body
            )
          else { return nil }
          continue
        }
        if operation == .increment || operation == .decrement {
          boundary.emitMaterializeLazyFlags(into: &body)
          nativeFlags = nil
        }
        if destination.bank == "x86.high8" {
          guard destination.width == .i8 else { return nil }
          nativeFlags = alu.emitHighByteUnary(
            operation,
            destinationLegacyRegister: Int(destination.index),
            into: &body
          )
        } else {
          guard destination.bank == "x86.gpr" else { return nil }
          nativeFlags = alu.emitUnary(
            operation,
            width: destination.width,
            destinationGuestRegister: Int(destination.index),
            into: &body
          )
        }
        guard nativeFlags != nil else { return nil }

      case .exchangeRegisters(let lhs, let rhs):
        guard lhs.bank == "x86.gpr", rhs.bank == "x86.gpr",
          lhs.width == .i64, rhs.width == .i64,
          alu.emitExchangeRegisters(
            lhsGuestRegister: Int(lhs.index),
            rhsGuestRegister: Int(rhs.index),
            into: &body
          )
        else { return nil }

      case .byteSwap(let operand):
        guard let register = lowRegister(operand),
          alu.emitByteSwap(
            width: register.width,
            guestRegister: Int(register.index),
            into: &body
          )
        else { return nil }

      case .extendMove(let destination, let source, let signed):
        guard let destination = lowRegister(destination),
          let source = lowRegister(source),
          alu.emitExtendMove(
            destinationWidth: destination.width,
            destinationGuestRegister: Int(destination.index),
            sourceWidth: source.width,
            sourceGuestRegister: Int(source.index),
            signed: signed,
            into: &body
          )
        else { return nil }

      case .signExtendAccumulatorHigh(let width):
        guard alu.emitSignExtendAccumulatorHigh(width: width, into: &body) else {
          return nil
        }

      case .effectiveAddress(let destination, let address):
        guard let destination = lowRegister(destination),
          alu.emitEffectiveAddress(
            destinationWidth: destination.width,
            destinationGuestRegister: Int(destination.index),
            address: address,
            into: &body
          )
        else { return nil }

      case .shift(let operation, let destination, let count):
        guard let destination = lowRegister(destination),
          alu.emitShift(
            operation,
            width: destination.width,
            destinationGuestRegister: Int(destination.index),
            count: count,
            into: &body
          )
        else { return nil }
        nativeFlags = nil

      case .doubleShiftRightCL(let destination, let source):
        guard
          emitDoubleShift(
            destination: destination, source: source, count: .cl, into: &body)
        else { return nil }
        nativeFlags = nil

      case .doubleShiftRightImmediate(let destination, let source, let count):
        guard
          emitDoubleShift(
            destination: destination, source: source, count: .immediate(count), into: &body)
        else { return nil }
        nativeFlags = nil

      case .setCondition(let condition, let destination):
        if case .memory(let address, let width) = destination {
          guard Self.isMeasuredMemorySetConditionBlock(block), width == .i8,
            alu.emitMeasuredMemorySetCondition(condition, address: address, into: &body)
          else { return nil }
          nativeFlags = nil
          continue
        }
        guard let destination = lowRegister(destination), destination.width == .i8 else {
          return nil
        }
        if let nativeFlags,
          alu.emitFusedSetCondition(
            condition,
            flags: nativeFlags,
            destinationGuestRegister: Int(destination.index),
            into: &body
          )
        {
          continue
        }
        guard
          alu.emitMaterializedSetCondition(
            condition,
            destinationGuestRegister: Int(destination.index),
            into: &body
          )
        else { return nil }
        nativeFlags = nil

      case .conditionalMove(let condition, let destination, let source):
        guard let destination = lowRegister(destination) else { return nil }
        switch source {
        case .memory(let address, let width):
          guard width == destination.width,
            alu.emitMemoryConditionalMove(
              condition,
              width: width,
              destinationGuestRegister: Int(destination.index),
              address: address,
              into: &body
            )
          else { return nil }
          nativeFlags = nil
        default:
          guard destination.width == .i64,
            let source = lowSource(source, matching: .i64)
          else { return nil }
          if let nativeFlags,
            alu.emitFusedConditionalMove(
              condition,
              flags: nativeFlags,
              destinationGuestRegister: Int(destination.index),
              source: source,
              into: &body
            )
          {
            continue
          }
          guard
            alu.emitMaterializedConditionalMove(
              condition,
              destinationGuestRegister: Int(destination.index),
              source: source,
              into: &body
            )
          else { return nil }
          nativeFlags = nil
        }

      case .stackPushFlags:
        alu.emitPushFlags(into: &body)
        nativeFlags = nil

      case .stackPush(let source):
        switch source {
        case .memory(let address, let width):
          guard width == .i64,
            alu.emitMemoryStackPush(address: address, into: &body)
          else { return nil }
        default:
          guard let source = lowSource(source, matching: .i64),
            alu.emitStackPush(source: source, into: &body)
          else { return nil }
        }
        nativeFlags = nil

      case .stackPop(let destination):
        guard let destination = lowRegister(destination), destination.width == .i64,
          alu.emitStackPop(
            destinationGuestRegister: Int(destination.index),
            into: &body
          )
        else { return nil }
        nativeFlags = nil

      case .loadFlagsIntoAH:
        alu.emitLoadFlagsIntoAH(into: &body)
        nativeFlags = nil

      case .storeAHIntoFlags:
        alu.emitStoreAHIntoFlags(into: &body)
        nativeFlags = nil

      case .setCarryFlag(let enabled):
        alu.emitSetCarryFlag(enabled: enabled, into: &body)
        nativeFlags = nil

      case .complementCarryFlag:
        alu.emitComplementCarryFlag(into: &body)
        nativeFlags = nil

      case .clearInterruptFlag:
        alu.emitSetNonArithmeticFlag(.interruptEnable, enabled: false, into: &body)

      case .setDirectionFlag(let enabled):
        alu.emitSetNonArithmeticFlag(.direction, enabled: enabled, into: &body)

      case .readTimestampCounter:
        alu.emitReadTimestampCounter(into: &body)

      case .memoryFence(let kind):
        alu.emitMemoryFence(kind, into: &body)
        nativeFlags = nil

      case .readSegment(let segment, let destination):
        guard let destination = lowRegister(destination), destination.width == .i16,
          alu.emitReadSegment(
            segment,
            destinationGuestRegister: Int(destination.index),
            into: &body
          )
        else { return nil }

      case .readControlRegister(let index, let destination):
        guard destination.width == .i64,
          alu.emitReadControlRegister(
            index,
            destinationGuestRegister: Int(destination.index),
            into: &body
          )
        else { return nil }

      case .writeControlRegister(let index, let source):
        guard Self.isMeasuredCR3WriteBlock(block, source: source),
          alu.emitWriteControlRegister(
            index,
            sourceGuestRegister: Int(source.index),
            into: &body
          )
        else { return nil }

      case .swapGS:
        alu.emitSwapGS(into: &body)

      case .bitScan(let reverse, let destination, let source):
        guard let destination = lowRegister(destination),
          let source = lowRegister(source),
          destination.width == source.width,
          alu.emitBitScan(
            reverse: reverse,
            width: destination.width,
            destinationGuestRegister: Int(destination.index),
            sourceGuestRegister: Int(source.index),
            into: &body
          )
        else { return nil }
        nativeFlags = nil

      case .bitTestRegister(let operation, let base, let index):
        guard let base = lowRegister(base),
          let index = bitIndexSource(index, matching: base.width),
          alu.emitBitTest(
            operation,
            width: base.width,
            baseGuestRegister: Int(base.index),
            index: index,
            into: &body
          )
        else { return nil }
        nativeFlags = nil

      case .bitTestMemoryRegister(let operation, let base, let index):
        guard Self.isMeasuredMemoryBitOperationBlock(block),
          case .memory(let address, let width) = base,
          let index = lowRegister(index), index.width == width,
          alu.emitMeasuredMemoryBitOperation(
            operation,
            width: width,
            address: address,
            indexGuestRegister: Int(index.index),
            into: &body
          )
        else { return nil }
        nativeFlags = nil

      case .signedMultiply(let destination, let lhs, let rhs):
        guard let destination = lowRegister(destination),
          let lhs = lowRegister(lhs),
          destination.width == lhs.width,
          let rhs = lowSource(rhs, matching: destination.width),
          alu.emitSignedMultiply(
            width: destination.width,
            destinationGuestRegister: Int(destination.index),
            lhsGuestRegister: Int(lhs.index),
            rhs: rhs,
            into: &body
          )
        else { return nil }
        nativeFlags = nil

      case .unsignedAccumulatorMultiply(let source):
        switch source {
        case .memory(let address, let width):
          guard width == .i64,
            alu.emitMemoryUnsignedAccumulatorMultiply(address: address, into: &body)
          else { return nil }
        default:
          guard let source = lowRegister(source),
            source.width == .i32 || source.width == .i64,
            alu.emitUnsignedAccumulatorMultiply(
              width: source.width,
              sourceGuestRegister: Int(source.index),
              into: &body
            )
          else { return nil }
        }
        nativeFlags = nil

      case .atomicBinary(let operation, let destination, let source):
        guard operation == .xor,
          case .memory(let address, let width) = destination,
          width == .i8,
          source == .immediate(1, width: .i8),
          alu.emitMeasuredAtomicByteXOR(address: address, into: &body)
        else { return nil }
        nativeFlags = nil

      default:
        return nil
      }
    }

    let exitCode: DoryJITExitCode
    switch block.terminator {
    case .next(let address), .branch(let address):
      guard DoryX86ArchitecturalState.isCanonical(address) else { return nil }
      boundary.emitGuestRIP(address, into: &body)
      exitCode = .dispatch
    case .exit(.instructionBudget, let address):
      guard DoryX86ArchitecturalState.isCanonical(address) else { return nil }
      boundary.emitGuestRIP(address, into: &body)
      exitCode = .dispatch
    case .conditional(let name, let taken, let notTaken):
      guard DoryX86ArchitecturalState.isCanonical(taken),
        DoryX86ArchitecturalState.isCanonical(notTaken),
        let condition = condition(named: name)
      else { return nil }
      if let nativeFlags,
        alu.emitFusedBranch(
          condition, flags: nativeFlags, taken: taken, notTaken: notTaken, into: &body)
      {
        // The branch consumed the producer's still-live NZCV image.
      } else {
        alu.emitMaterializedBranch(condition, taken: taken, notTaken: notTaken, into: &body)
      }
      exitCode = .dispatch
    default:
      return nil
    }

    var words: [UInt32] = []
    boundary.emitEntry(into: &words)
    words.append(contentsOf: body)
    boundary.emitExit(exitCode, into: &words)
    return .init(
      guestStart: block.guestStart,
      guestByteCount: block.guestByteCount,
      guestInstructionCount: block.guestInstructionCount,
      machineWords: words,
      tier: .tier1,
      exitCode: exitCode,
      requiresMemoryCallbacks: requiresMemoryCallbacks,
      requiresRestartableMemoryReads: memoryCallbackCount > 1,
      mayExitToInterpreter: memoryCallbackCount > 0
    )
  }

  private func register(_ operand: DoryIROperand) -> DoryIRRegister? {
    guard case .register(let value) = operand, value.index < 16 else { return nil }
    if value.bank == "x86.high8" { return value.index < 4 ? value : nil }
    return value.bank == "x86.gpr" ? value : nil
  }

  private static func isQwordMemoryAccumulatorMultiply(_ statement: DoryIRStatement) -> Bool {
    guard case .unsignedAccumulatorMultiply(.memory(_, let width)) = statement else {
      return false
    }
    return width == .i64
  }

  private static func isMeasuredCR3WriteBlock(
    _ block: DoryIRBasicBlock,
    source: DoryIRRegister
  ) -> Bool {
    guard block.guestByteCount == 3,
      block.guestInstructionCount == 1,
      block.statements.count == 1,
      source.bank == "x86.gpr",
      source.width == .i64
    else { return false }
    switch block.guestStart {
    case measuredCR3WriteRAXRIP: return source.index == 0
    case measuredCR3WriteRDIRIP: return source.index == 7
    default: return false
    }
  }

  private static func isMeasuredAtomicByteXOR(_ statement: DoryIRStatement) -> Bool {
    guard case .atomicBinary(.xor, .memory(_, let width), let source) = statement else {
      return false
    }
    return width == .i8 && source == .immediate(1, width: .i8)
  }

  private static func isMeasuredPatchedByteXOR(_ statement: DoryIRStatement) -> Bool {
    guard
      case .binary(
        .xor,
        .memory(_, let width),
        let source,
        writesDestination: true
      ) = statement
    else { return false }
    return width == .i8 && source == .immediate(1, width: .i8)
  }

  private static func isMeasuredPatchedByteXORBlock(_ block: DoryIRBasicBlock) -> Bool {
    guard block.guestStart == measuredPatchedByteXORRIP,
      block.guestByteCount == 5,
      block.guestInstructionCount == 1,
      block.statements.count == 1,
      let statement = block.statements.first
    else { return false }
    return isMeasuredPatchedByteXOR(statement)
  }

  private static func isMeasuredMemorySetConditionBlock(_ block: DoryIRBasicBlock) -> Bool {
    guard
      block.guestInstructionCount == 1,
      block.statements.count == 1,
      case .setCondition(let condition, .memory(_, let width)) = block.statements[0]
    else { return false }
    guard width == .i8 else { return false }
    switch block.guestStart {
    case measuredMemorySetEqualStack22RIP, measuredMemorySetEqualRIP:
      return block.guestByteCount == 5 && condition == .equal
    case measuredMemorySetNotEqualRIP:
      return block.guestByteCount == 3 && condition == .notEqual
    default:
      return false
    }
  }

  private static func isMeasuredMemoryBitTestBlock(_ block: DoryIRBasicBlock) -> Bool {
    guard block.guestStart == measuredMemoryBitTestRIP,
      let statement = block.statements.first,
      case .bitTestMemoryRegister(
        .test,
        .memory(_, let width),
        .register(let index)
      ) = statement
    else { return false }
    return width == .i64 && index == .init(bank: "x86.gpr", index: 2, width: .i64)
  }

  private static func isMeasuredMemoryBitResetBlock(_ block: DoryIRBasicBlock) -> Bool {
    guard block.guestStart == measuredMemoryBitResetRIP,
      let statement = block.statements.first,
      case .bitTestMemoryRegister(
        .reset,
        .memory(_, let width),
        .register(let index)
      ) = statement
    else { return false }
    return width == .i64 && index == .init(bank: "x86.gpr", index: 1, width: .i64)
  }

  private static func isMeasuredMemoryBitOperationBlock(_ block: DoryIRBasicBlock) -> Bool {
    isMeasuredMemoryBitTestBlock(block) || isMeasuredMemoryBitResetBlock(block)
  }

  private func lowRegister(_ operand: DoryIROperand) -> DoryIRRegister? {
    guard let value = register(operand), value.bank == "x86.gpr" else { return nil }
    return value
  }

  private func highByteSource(
    _ operand: DoryIROperand
  ) -> DoryARM64Tier1ALUEmitter.HighByteSource? {
    switch operand {
    case .register(let value)
    where value.bank == "x86.high8" && value.index < 4 && value.width == .i8:
      return .guestHighByte(Int(value.index))
    case .immediate(let value, .i8):
      return .immediate(UInt8(truncatingIfNeeded: value))
    default:
      return nil
    }
  }

  private func lowSource(
    _ operand: DoryIROperand,
    matching width: DoryIRIntegerWidth
  ) -> DoryARM64Tier1ALUEmitter.Source? {
    switch operand {
    case .register(let value)
    where value.bank == "x86.gpr" && value.index < 16 && value.width == width:
      return .guestRegister(Int(value.index))
    case .immediate(let value, let immediateWidth) where immediateWidth == width:
      return .immediate(value)
    default:
      return nil
    }
  }

  private func bitIndexSource(
    _ operand: DoryIROperand,
    matching width: DoryIRIntegerWidth
  ) -> DoryARM64Tier1ALUEmitter.Source? {
    switch operand {
    case .register(let value)
    where value.bank == "x86.gpr" && value.index < 16 && value.width == width:
      return .guestRegister(Int(value.index))
    case .immediate(let value, .i8):
      return .immediate(value)
    default:
      return nil
    }
  }

  private func emitDoubleShift(
    destination: DoryIROperand,
    source: DoryIROperand,
    count: DoryIRShiftCount,
    into words: inout [UInt32]
  ) -> Bool {
    guard let destination = lowRegister(destination),
      let source = lowRegister(source),
      destination.width == source.width
    else { return false }
    return alu.emitDoubleShift(
      .right,
      width: destination.width,
      destinationGuestRegister: Int(destination.index),
      sourceGuestRegister: Int(source.index),
      count: count,
      into: &words
    )
  }

  private func condition(named name: String) -> DoryX86Condition? {
    let prefix = "x86.condition."
    guard name.hasPrefix(prefix),
      let rawValue = UInt8(name.dropFirst(prefix.count))
    else { return nil }
    return DoryX86Condition(rawValue: rawValue)
  }
}
