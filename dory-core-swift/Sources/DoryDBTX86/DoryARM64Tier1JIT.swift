import Foundation

/// First-execution compiler for the pinned-register tier-1 ABI.
///
/// Admission is intentionally block-atomic. A statement that cannot be represented without a
/// helper or a precise side exit declines the entire block, allowing the caller to compile it with
/// the old baseline emitter while tier-1 coverage grows.
struct DoryARM64Tier1Emitter: Sendable {
  private let boundary = DoryARM64Tier1BoundaryEmitter()
  private let alu = DoryARM64Tier1ALUEmitter()

  func compile(_ block: DoryIRBasicBlock) -> DoryARM64CompiledBlock? {
    guard block.guestInstructionCount > 0 else { return nil }
    var memoryCallbackCount = 0
    var wroteMemory = false
    for statement in block.statements {
      switch statement {
      case .stackPush, .stackPushFlags:
        guard !wroteMemory else { return nil }
        memoryCallbackCount += 1
        wroteMemory = true
      case .stackPop:
        guard !wroteMemory else { return nil }
        memoryCallbackCount += 1
      default:
        break
      }
    }
    var body: [UInt32] = []
    var nativeFlags: DoryARM64Tier1ALUEmitter.NativeFlags?

    for statement in block.statements {
      switch statement {
      case .copy(let destination, let source):
        guard let destination = lowRegister(destination),
          let source = lowSource(source, matching: destination.width),
          alu.emitCopy(
            width: destination.width,
            destinationGuestRegister: Int(destination.index),
            source: source,
            into: &body
          )
        else { return nil }

      case .binary(let operation, let destination, let source, let writesDestination):
        guard let destination = register(destination) else { return nil }
        if operation == .addWithCarry || operation == .subtractWithBorrow {
          boundary.emitMaterializeLazyFlags(into: &body)
          nativeFlags = nil
        }
        if destination.bank == "x86.high8" {
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
        } else {
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
        guard let destination = lowRegister(destination), destination.width == .i64,
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

      case .stackPushFlags:
        alu.emitPushFlags(into: &body)
        nativeFlags = nil

      case .stackPush(let source):
        guard let source = lowSource(source, matching: .i64),
          alu.emitStackPush(source: source, into: &body)
        else { return nil }
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
      requiresMemoryCallbacks: memoryCallbackCount > 0,
      requiresRestartableMemoryReads: memoryCallbackCount > 1,
      mayExitToInterpreter: memoryCallbackCount > 0
    )
  }

  private func register(_ operand: DoryIROperand) -> DoryIRRegister? {
    guard case .register(let value) = operand, value.index < 16 else { return nil }
    if value.bank == "x86.high8" { return value.index < 4 ? value : nil }
    return value.bank == "x86.gpr" ? value : nil
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
