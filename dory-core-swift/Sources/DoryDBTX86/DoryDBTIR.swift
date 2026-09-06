import Foundation

public enum DoryIRIntegerWidth: UInt8, Codable, Sendable, Hashable {
  case i8 = 8
  case i16 = 16
  case i32 = 32
  case i64 = 64
}

public struct DoryIRRegister: Codable, Sendable, Hashable {
  public let bank: String
  public let index: UInt16
  public let width: DoryIRIntegerWidth

  public init(bank: String, index: UInt16, width: DoryIRIntegerWidth) {
    self.bank = bank
    self.index = index
    self.width = width
  }
}

public struct DoryIRMemoryAddress: Codable, Sendable, Hashable {
  public let base: DoryIRRegister?
  public let index: DoryIRRegister?
  public let scale: UInt8
  public let displacement: Int64
  public let instructionRelativeBase: UInt64?
  public let addressWidth: DoryIRIntegerWidth
  public let segment: String?

  public init(
    base: DoryIRRegister? = nil,
    index: DoryIRRegister? = nil,
    scale: UInt8 = 1,
    displacement: Int64 = 0,
    instructionRelativeBase: UInt64? = nil,
    addressWidth: DoryIRIntegerWidth,
    segment: String? = nil
  ) {
    self.base = base
    self.index = index
    self.scale = scale
    self.displacement = displacement
    self.instructionRelativeBase = instructionRelativeBase
    self.addressWidth = addressWidth
    self.segment = segment
  }
}

public enum DoryIROperand: Codable, Sendable, Hashable {
  case register(DoryIRRegister)
  case memory(DoryIRMemoryAddress, width: DoryIRIntegerWidth)
  case immediate(UInt64, width: DoryIRIntegerWidth)
}

public enum DoryIRBinaryOperation: String, Codable, Sendable, Hashable {
  case add, addWithCarry, or, subtractWithBorrow, and, subtract, xor, compare, test
}

public enum DoryIRUnaryOperation: String, Codable, Sendable, Hashable {
  case increment, decrement, bitwiseNot, negate
}

public enum DoryIRShiftOperation: String, Codable, Sendable, Hashable {
  case left, logicalRight, arithmeticRight, rotateLeft
}

public enum DoryIRShiftCount: Codable, Sendable, Hashable {
  case immediate(UInt8)
  case cl
}

public enum DoryIRStatement: Codable, Sendable, Hashable {
  case copy(destination: DoryIROperand, source: DoryIROperand)
  case binary(
    DoryIRBinaryOperation,
    destination: DoryIROperand,
    source: DoryIROperand,
    writesDestination: Bool
  )
  case unary(DoryIRUnaryOperation, operand: DoryIROperand)
  case shift(DoryIRShiftOperation, destination: DoryIROperand, count: DoryIRShiftCount)
  case conditionalMove(
    DoryX86Condition,
    destination: DoryIROperand,
    source: DoryIROperand
  )
  case setCondition(DoryX86Condition, destination: DoryIROperand)
  case bitTestRegister(operation: DoryX86BitOperation, base: DoryIROperand, index: DoryIROperand)
  case bitTestMemoryImmediate(operation: DoryX86BitOperation, base: DoryIROperand, index: UInt8)
  case bitScan(reverse: Bool, destination: DoryIROperand, source: DoryIROperand)
  case byteSwap(DoryIROperand)
  case stackPush(source: DoryIROperand)
  case stackPushFlags
  case stackPop(destination: DoryIROperand)
  case clearInterruptFlag
  case memoryFence(DoryX86MemoryFence)
  case readSegment(DoryX86SegmentRegister, destination: DoryIROperand)
  case setDirectionFlag(enabled: Bool)
  case readTimestampCounter
  case signExtendAccumulatorHigh(width: DoryIRIntegerWidth)
  case unsignedAccumulatorMultiply(source: DoryIROperand)
  case unsignedAccumulatorDivide(source: DoryIROperand)
  case doubleShiftRightCL(destination: DoryIROperand, source: DoryIROperand)
  case doubleShiftRightImmediate(destination: DoryIROperand, source: DoryIROperand, count: UInt8)
  case compareExchange(destination: DoryIROperand, source: DoryIROperand)
  case exchangeRegisters(lhs: DoryIRRegister, rhs: DoryIRRegister)
  case signedMultiply(destination: DoryIROperand, lhs: DoryIROperand, rhs: DoryIROperand)
  case extendMove(destination: DoryIROperand, source: DoryIROperand, signed: Bool)
  case effectiveAddress(destination: DoryIROperand, address: DoryIRMemoryAddress)
  case helper(identifier: String, payload: [UInt8])
}

public enum DoryIRExitReason: String, Codable, Sendable, Hashable {
  case interpreter
  case halt
  case indirectControl
  case system
  case portIO
  case instructionBudget
}

public enum DoryIRTerminator: Codable, Sendable, Hashable {
  case next(UInt64)
  case branch(UInt64)
  case call(target: UInt64, returnAddress: UInt64)
  case indirectCall(target: DoryIROperand, returnAddress: UInt64)
  case indirect(DoryIROperand)
  case returnFromCall(popBytes: UInt16)
  case conditional(condition: String, taken: UInt64, notTaken: UInt64)
  case exit(DoryIRExitReason, resumeAt: UInt64)
}

public struct DoryIRBasicBlock: Codable, Sendable, Hashable {
  public let guestStart: UInt64
  public let guestByteCount: UInt32
  public let guestInstructionCount: UInt32
  public let statements: [DoryIRStatement]
  public let terminator: DoryIRTerminator

  public init(
    guestStart: UInt64,
    guestByteCount: UInt32,
    guestInstructionCount: UInt32,
    statements: [DoryIRStatement],
    terminator: DoryIRTerminator
  ) {
    self.guestStart = guestStart
    self.guestByteCount = guestByteCount
    self.guestInstructionCount = guestInstructionCount
    self.statements = statements
    self.terminator = terminator
  }
}

public struct DoryX86IRTranslator: Sendable {
  public let decoder: DoryX86Decoder
  public let instructionBudget: Int

  public init(decoder: DoryX86Decoder = .init(), instructionBudget: Int = 64) {
    self.decoder = decoder
    self.instructionBudget = max(1, instructionBudget)
  }

  public func translate(
    _ bytes: [UInt8],
    at address: UInt64,
    mode: DoryX86ExecutionMode
  ) throws -> DoryIRBasicBlock {
    var offset = 0
    var instructionCount = 0
    var statements: [DoryIRStatement] = []
    // Most decoded instructions lower to one or two statements. Reserving the bounded block
    // shape avoids repeatedly reallocating and copying the comparatively large statement enum
    // while translating cold firmware and kernel code.
    statements.reserveCapacity(min(instructionBudget * 2, 128))
    var terminator: DoryIRTerminator?

    while offset < bytes.count, instructionCount < instructionBudget {
      let instructionAddress = address &+ UInt64(offset)
      let instruction = try decoder.decode(
        bytes.dropFirst(offset).prefix(15),
        at: instructionAddress,
        mode: mode
      )
      offset += Int(instruction.length)
      instructionCount += 1
      let lowering = lower(instruction, mode: mode)
      let statementMemoryBehavior = lowering.statements.reduce(MemoryBehavior.none) {
        max($0, self.memoryBehavior($1))
      }
      if instructionCount > 1, requiresJITFallback(lowering) || requiresDispatchBoundary(lowering) {
        offset -= Int(instruction.length)
        instructionCount -= 1
        terminator = .next(instructionAddress)
        break
      }
      statements.append(contentsOf: lowering.statements)
      if let end = lowering.terminator {
        terminator = end
        break
      }
      // A write may modify bytes decoded later in this block, so it remains a hard boundary.
      // Read-only prefixes are restartable: multi-access native blocks use the explicit ordinary-
      // RAM callback contract and discard their temporary context if any read cannot be replayed.
      if statementMemoryBehavior == .write {
        terminator = .next(instruction.nextInstructionAddress)
        break
      }
    }

    if terminator == nil {
      let next = address &+ UInt64(offset)
      terminator =
        instructionCount == instructionBudget && offset < bytes.count
        ? .exit(.instructionBudget, resumeAt: next)
        : .next(next)
    }
    return .init(
      guestStart: address,
      guestByteCount: UInt32(offset),
      guestInstructionCount: UInt32(instructionCount),
      statements: statements,
      terminator: terminator!
    )
  }

  private func lower(
    _ instruction: DoryX86DecodedInstruction,
    mode: DoryX86ExecutionMode
  ) -> (statements: [DoryIRStatement], terminator: DoryIRTerminator?) {
    if instruction.prefixes.lock, !supportsNativeLockPrefix(instruction.operation) {
      return fallback(instruction, reason: .interpreter)
    }
    if DoryX86LegacyFloatingPointPolicy.isX87NoOperation(instruction) {
      // FNOP is still an x87 instruction: preserve its feature and EM/TS checks.
      return fallback(instruction, reason: .interpreter)
    }
    switch instruction.operation {
    case .noOperation, .processorPause:
      return ([], nil)
    case .memoryFence(let kind):
      guard mode == .long64 else { return fallback(instruction, reason: .interpreter) }
      // Isolate synchronization from reads that can fail and require block replay.
      return ([.memoryFence(kind)], .next(instruction.nextInstructionAddress))
    case .move(let destination, let source):
      // MOVNTI shares .move with ordinary stores but requires SSE2. Native entry
      // has no selected feature profile; preserve the precise interpreter gate.
      if DoryX86InstructionFeaturePolicy.isNonTemporalIntegerStore(instruction) {
        return fallback(instruction, reason: .interpreter)
      }
      return (
        [
          .copy(
            destination: operand(
              destination,
              instructionRelativeBase: instruction.nextInstructionAddress
            ),
            source: operand(
              source,
              instructionRelativeBase: instruction.nextInstructionAddress
            )
          )
        ],
        nil
      )
    case .loadEffectiveAddress(let destination, let source):
      return (
        [
          .effectiveAddress(
            destination: operand(destination),
            address: address(
              source,
              instructionRelativeBase: instruction.nextInstructionAddress
            )
          )
        ],
        nil
      )
    case .alu(let operation, let destination, let source):
      return (
        [
          .binary(
            irBinaryOperation(operation),
            destination: operand(
              destination,
              instructionRelativeBase: instruction.nextInstructionAddress
            ),
            source: operand(
              source,
              instructionRelativeBase: instruction.nextInstructionAddress
            ),
            writesDestination: operation != .compare && operation != .test
          )
        ],
        nil
      )
    case .unary(let operation, let source):
      return (
        [
          .unary(
            irUnaryOperation(operation),
            operand: operand(
              source,
              instructionRelativeBase: instruction.nextInstructionAddress
            )
          )
        ],
        nil
      )
    case .shift(let operation, let destination, let count):
      let loweredOperation: DoryIRShiftOperation
      switch operation {
      case .shiftLeft: loweredOperation = .left
      case .shiftRight: loweredOperation = .logicalRight
      case .arithmeticShiftRight: loweredOperation = .arithmeticRight
      case .rotateLeft: loweredOperation = .rotateLeft
      default: return fallback(instruction, reason: .interpreter)
      }
      let loweredCount: DoryIRShiftCount =
        switch count {
        case .immediate(let value): .immediate(value)
        case .cl: .cl
        }
      return (
        [
          .shift(
            loweredOperation,
            destination: operand(
              destination,
              instructionRelativeBase: instruction.nextInstructionAddress
            ),
            count: loweredCount
          )
        ],
        nil
      )
    case .conditionalMove(let condition, let destination, let source):
      return (
        [
          .conditionalMove(
            condition,
            destination: operand(destination),
            source: operand(source, instructionRelativeBase: instruction.nextInstructionAddress)
          )
        ],
        nil
      )
    case .setCondition(let condition, let destination):
      return (
        [
          .setCondition(
            condition,
            destination: operand(destination)
          )
        ],
        nil
      )
    case .bitTest(let operation, let base, let index) where mode == .long64:
      if case .memory(let memory) = base,
        memory.width == .doubleword || memory.width == .quadword,
        case .immediate(let bit, .byte) = index,
        !instruction.prefixes.lock
      {
        return ([.bitTestMemoryImmediate(
          operation: operation,
          base: operand(base, instructionRelativeBase: instruction.nextInstructionAddress),
          index: UInt8(truncatingIfNeeded: bit)
        )], nil)
      }
      guard case .register(_, let baseWidth) = base,
        baseWidth == .doubleword || baseWidth == .quadword
      else { return fallback(instruction, reason: .interpreter) }
      switch index {
      case .register(_, let indexWidth) where indexWidth == baseWidth:
        break
      case .immediate(_, .byte):
        break
      default:
        return fallback(instruction, reason: .interpreter)
      }
      return (
        [
          .bitTestRegister(
            operation: operation,
            base: operand(base),
            index: operand(index)
          )
        ],
        nil
      )
    case .bitScan(let reverse, let destination, let source):
      return (
        [
          .bitScan(
            reverse: reverse,
            destination: operand(destination),
            source: operand(source, instructionRelativeBase: instruction.nextInstructionAddress)
          )
        ],
        nil
      )
    case .byteSwap(let target):
      return ([.byteSwap(operand(target))], nil)
    case .push(let source) where mode == .long64:
      return (
        [
          .stackPush(
            source: operand(
              source,
              instructionRelativeBase: instruction.nextInstructionAddress
            )
          )
        ],
        nil
      )
    case .pushFlags(.quadword) where mode == .long64:
      return ([.stackPushFlags], nil)
    case .pop(let destination) where mode == .long64:
      return (
        [
          .stackPop(
            destination: operand(
              destination,
              instructionRelativeBase: instruction.nextInstructionAddress
            )
          )
        ],
        nil
      )
    case .setInterruptsEnabled(false) where mode == .long64:
      return ([.clearInterruptFlag], nil)
    case .exchange(let lhs, let rhs) where mode == .long64:
      let lhsOperand = operand(lhs, instructionRelativeBase: instruction.nextInstructionAddress)
      let rhsOperand = operand(rhs, instructionRelativeBase: instruction.nextInstructionAddress)
      guard case .register(let lhsRegister) = lhsOperand,
        case .register(let rhsRegister) = rhsOperand,
        lhsRegister.bank == "x86.gpr", rhsRegister.bank == "x86.gpr",
        lhsRegister.index < 16, rhsRegister.index < 16,
        lhsRegister.width == .i64, rhsRegister.width == .i64
      else { return fallback(instruction, reason: .interpreter) }
      return ([.exchangeRegisters(lhs: lhsRegister, rhs: rhsRegister)], nil)
    case .setDirection(let enabled) where mode == .long64:
      return ([.setDirectionFlag(enabled: enabled)], nil)
    case .readTimestampCounter(false) where mode == .long64:
      return ([.readTimestampCounter], .next(instruction.nextInstructionAddress))
    case .signExtendAccumulator(let width, false) where mode == .long64:
      guard irWidth(width) == .i64 else {
        return fallback(instruction, reason: .interpreter)
      }
      return (
        [
          .extendMove(
            destination: .register(.init(bank: "x86.gpr", index: 0, width: .i64)),
            source: .register(.init(bank: "x86.gpr", index: 0, width: .i32)),
            signed: true
          )
        ],
        nil
      )
    case .signExtendAccumulator(let width, true) where mode == .long64:
      let irWidth = irWidth(width)
      guard irWidth == .i32 || irWidth == .i64 else {
        return fallback(instruction, reason: .interpreter)
      }
      return ([.signExtendAccumulatorHigh(width: irWidth)], nil)
    case .accumulatorArithmetic(.unsignedMultiply, let source) where mode == .long64:
      return (
        [
          .unsignedAccumulatorMultiply(
            source: operand(source, instructionRelativeBase: instruction.nextInstructionAddress)
          )
        ],
        nil
      )
    case .accumulatorArithmetic(.unsignedDivide, let source) where mode == .long64:
      guard case .register(_, let width) = source, width == .doubleword || width == .quadword
      else { return fallback(instruction, reason: .interpreter) }
      return (
        [
          .unsignedAccumulatorDivide(
            source: operand(source, instructionRelativeBase: instruction.nextInstructionAddress)
          )
        ],
        .next(instruction.nextInstructionAddress)
      )
    case .doubleShift(.right, let destination, let source, .cl) where mode == .long64:
      return (
        [
          .doubleShiftRightCL(
            destination: operand(
              destination,
              instructionRelativeBase: instruction.nextInstructionAddress
            ),
            source: operand(source, instructionRelativeBase: instruction.nextInstructionAddress)
          )
        ],
        nil
      )
    case .doubleShift(.right, let destination, let source, .immediate(let count)) where mode == .long64:
      return (
        [
          .doubleShiftRightImmediate(
            destination: operand(
              destination,
              instructionRelativeBase: instruction.nextInstructionAddress
            ),
            source: operand(source, instructionRelativeBase: instruction.nextInstructionAddress),
            count: count
          )
        ],
        nil
      )
    case .compareExchange(let destination, let source) where mode == .long64:
      guard case .memory(let memory) = destination,
        memory.width == .doubleword || memory.width == .quadword,
        case .register(_, let sourceWidth) = source,
        sourceWidth == memory.width
      else { return fallback(instruction, reason: .interpreter) }
      return (
        [
          .compareExchange(
            destination: operand(
              destination,
              instructionRelativeBase: instruction.nextInstructionAddress
            ),
            source: operand(
              source,
              instructionRelativeBase: instruction.nextInstructionAddress
            )
          )
        ],
        .next(instruction.nextInstructionAddress)
      )
    case .signedMultiply(let destination, let lhs, let rhs):
      return (
        [
          .signedMultiply(
            destination: operand(destination),
            lhs: operand(lhs, instructionRelativeBase: instruction.nextInstructionAddress),
            rhs: operand(rhs, instructionRelativeBase: instruction.nextInstructionAddress)
          )
        ],
        nil
      )
    case .extendMove(let destination, let source, let signed):
      return (
        [
          .extendMove(
            destination: operand(destination),
            source: operand(source, instructionRelativeBase: instruction.nextInstructionAddress),
            signed: signed
          )
        ],
        nil
      )
    case .readSegment(let segment, let destination) where mode == .long64:
      return (
        [
          .readSegment(
            segment,
            destination: operand(
              destination,
              instructionRelativeBase: instruction.nextInstructionAddress
            )
          )
        ],
        nil
      )
    case .jump(let relative) where mode == .long64 || mode == .protected32:
      return ([], .branch(nearRelativeTarget(instruction, relative: relative, mode: mode)))
    case .call(let relative) where mode == .long64:
      return (
        [],
        .call(
          target: addRelative(instruction.nextInstructionAddress, relative),
          returnAddress: instruction.nextInstructionAddress
        )
      )
    case .callIndirect(let target) where mode == .long64:
      return (
        [],
        .indirectCall(
          target: operand(target, instructionRelativeBase: instruction.nextInstructionAddress),
          returnAddress: instruction.nextInstructionAddress
        )
      )
    case .jumpIndirect(let target) where mode == .long64:
      return (
        [],
        .indirect(
          operand(target, instructionRelativeBase: instruction.nextInstructionAddress)
        )
      )
    case .return where mode == .long64:
      return ([], .returnFromCall(popBytes: 0))
    case .returnAndPop(let popBytes) where mode == .long64:
      return ([], .returnFromCall(popBytes: popBytes))
    case .conditionalJump(let condition, let relative) where mode == .long64 || mode == .protected32:
      return (
        [],
        .conditional(
          condition: conditionName(condition),
          taken: nearRelativeTarget(instruction, relative: relative, mode: mode),
          notTaken: instruction.nextInstructionAddress & (mode == .long64 ? .max : 0xFFFF_FFFF)
        )
      )
    case .halt:
      return ([], .exit(.halt, resumeAt: instruction.nextInstructionAddress))
    case .input, .output, .string(.input, _), .string(.output, _):
      return fallback(instruction, reason: .portIO)
    case .callIndirect, .jumpIndirect, .return, .returnAndPop, .farCall, .farCallIndirect,
      .farJump, .farJumpIndirect, .farReturn:
      return fallback(instruction, reason: .indirectControl)
    default:
      return fallback(instruction, reason: .interpreter)
    }
  }

  private func supportsNativeLockPrefix(_ operation: DoryX86InstructionOperation) -> Bool {
    if case .compareExchange = operation { return true }
    return false
  }

  private func requiresJITFallback(
    _ lowering: (statements: [DoryIRStatement], terminator: DoryIRTerminator?)
  ) -> Bool {
    lowering.statements.contains { !isBaselineJITSupported($0) }
  }

  private func requiresDispatchBoundary(
    _ lowering: (statements: [DoryIRStatement], terminator: DoryIRTerminator?)
  ) -> Bool {
    lowering.statements.contains {
      switch $0 {
      case .readTimestampCounter, .unsignedAccumulatorDivide, .memoryFence:
        return true
      default:
        return false
      }
    }
  }

  private func isBaselineJITSupported(_ statement: DoryIRStatement) -> Bool {
    switch statement {
    case .copy(let destination, let source):
      switch destination {
      case .register(let target) where isJITLowByteRegister(target):
        switch source {
        case .register(let register):
          return isJITLowByteRegister(register)
        case .immediate(_, let width):
          return width == .i8
        case .memory(let address, let width):
          return width == .i8 && isJITMemoryAddress(address)
        }
      case .register(let target) where isJITGeneralRegister(target):
        switch source {
        case .register(let register):
          return isJITGeneralRegister(register) && register.width == target.width
        case .immediate(_, let width):
          return width == target.width
        case .memory(let address, let width):
          return width == target.width && isJITMemoryAddress(address)
        }
      case .memory(let address, let width)
      where (width == .i8 || width == .i16 || width == .i32 || width == .i64)
        && isJITMemoryAddress(address):
        switch source {
        case .register(let register):
          if width == .i8 || width == .i16 {
            return register.bank == "x86.gpr" && register.index < 16
              && register.width == width
          }
          return isJITGeneralRegister(register) && register.width == width
        case .immediate(_, let immediateWidth):
          return immediateWidth == width
        case .memory:
          return false
        }
      default:
        return false
      }
    case .binary(let operation, let destination, let source, let writesDestination):
      if case .register(let target) = destination,
        target.bank == "x86.high8", target.index < 4, target.width == .i8,
        ((operation == .and && writesDestination) || (operation == .test && !writesDestination)),
        case .immediate(_, width: .i8) = source
      {
        return true
      }
      if case .register(let target) = destination,
        target.bank == "x86.gpr", target.index < 16, target.width == .i16,
        operation == .compare, !writesDestination
      {
        switch source {
        case .register(let register):
          return register.bank == "x86.gpr" && register.index < 16 && register.width == .i16
        case .immediate(_, width: .i16):
          return true
        case .memory(let address, width: .i16):
          return isJITMemoryAddress(address)
        default:
          return false
        }
      }
      if case .memory(let address, width: .i16) = destination,
        (!writesDestination && operation == .compare)
          || (writesDestination && (operation == .add || operation == .subtract))
      {
        guard isJITMemoryAddress(address) else { return false }
        switch source {
        case .immediate(_, width: .i16): return true
        case .register(let register):
          return register.bank == "x86.gpr" && register.index < 16 && register.width == .i16
        default: return false
        }
      }
      if case .register(let target) = destination,
        target.bank == "x86.gpr", target.index < 16, target.width == .i16,
        operation == .or, writesDestination,
        case .memory(let address, width: .i16) = source
      {
        return isJITMemoryAddress(address)
      }
      let targetWidth: DoryIRIntegerWidth
      switch destination {
      case .register(let target) where isJITGeneralRegister(target):
        targetWidth = target.width
      case .register(let target)
      where isJITLowByteRegister(target)
        && (
          (!writesDestination && (operation == .compare || operation == .test))
            || (writesDestination && (operation == .and || operation == .or))
        ):
        targetWidth = .i8
      case .memory(let address, let width)
      where isJITMemoryAddress(address)
        && ((width == .i32 || width == .i64)
          || (width == .i8
            && ((!writesDestination && (operation == .compare || operation == .test))
              || (writesDestination && (operation == .and || operation == .or))))):
        targetWidth = width
      default:
        return false
      }
      switch source {
      case .register(let register):
        return targetWidth == .i8
          ? isJITLowByteRegister(register)
          : isJITGeneralRegister(register) && register.width == targetWidth
      case .immediate(_, let width):
        return width == targetWidth
      case .memory(let address, let width):
        if targetWidth == .i8 {
          guard (!writesDestination && (operation == .compare || operation == .test))
            || (writesDestination && operation == .and)
          else { return false }
          guard case .register(let target) = destination else { return false }
          return width == .i8 && isJITLowByteRegister(target) && isJITMemoryAddress(address)
        }
        guard case .register = destination else { return false }
        return width == targetWidth && isJITMemoryAddress(address)
      }
    case .unary(let operation, let operand):
      switch operand {
      case .register(let register):
        return isJITGeneralRegister(register)
          || (operation == .bitwiseNot && isJITLowByteRegister(register))
      case .memory(let address, let width):
        return (width == .i32 || width == .i64) && isJITMemoryAddress(address)
      case .immediate:
        return false
      }
    case .shift(let operation, let destination, let count):
      guard case .register(let register) = destination else { return false }
      if operation == .rotateLeft {
        guard register.width == .i64, case .immediate = count else { return false }
      }
      return isJITGeneralRegister(register)
    case .conditionalMove(_, let destination, let source):
      guard case .register(let target) = destination,
        case .register(let origin) = source,
        target.width == origin.width,
        target.width == .i32 || target.width == .i64
      else { return false }
      return isJITGeneralRegister(target) && isJITGeneralRegister(origin)
    case .setCondition(_, let destination):
      guard case .register(let target) = destination else { return false }
      return isJITLowByteRegister(target)
    case .bitTestMemoryImmediate(_, let base, _):
      guard case .memory(let address, let width) = base else { return false }
      return (width == .i32 || width == .i64) && isJITMemoryAddress(address)
    case .bitTestRegister(_, let base, let index):
      guard case .register(let baseRegister) = base,
        isJITGeneralRegister(baseRegister)
      else { return false }
      switch index {
      case .register(let indexRegister):
        return indexRegister.width == baseRegister.width && isJITGeneralRegister(indexRegister)
      case .immediate(_, let width):
        return width == .i8
      case .memory:
        return false
      }
    case .bitScan(_, let destination, let source):
      guard case .register(let target) = destination else { return false }
      guard isJITGeneralRegister(target) else { return false }
      switch source {
      case .register(let origin):
        return origin.width == target.width && isJITGeneralRegister(origin)
      case .memory(let address, let width):
        return width == target.width && isJITMemoryAddress(address)
      case .immediate:
        return false
      }
    case .byteSwap(let operand):
      guard case .register(let register) = operand else { return false }
      return isJITGeneralRegister(register)
    case .stackPush(let source):
      switch source {
      case .register(let register):
        return register.width == .i64 && isJITGeneralRegister(register)
      case .immediate(_, let width):
        return width == .i64
      case .memory:
        return false
      }
    case .stackPushFlags:
      return true
    case .stackPop(let destination):
      guard case .register(let register) = destination,
        register.width == .i64,
        register.index != 4
      else { return false }
      return isJITGeneralRegister(register)
    case .signedMultiply(let destination, let lhs, let rhs):
      guard case .register(let target) = destination,
        target.width == .i32 || target.width == .i64,
        isJITGeneralRegister(target)
      else { return false }
      let memoryOperandCount = (isMemory(lhs) ? 1 : 0) + (isMemory(rhs) ? 1 : 0)
      guard memoryOperandCount <= 1 else { return false }
      switch lhs {
      case .register(let left):
        guard left.width == target.width && isJITGeneralRegister(left) else { return false }
      case .memory(let address, let width):
        guard width == target.width && isJITMemoryAddress(address) else { return false }
      case .immediate:
        return false
      }
      switch rhs {
      case .register(let right):
        return right.width == target.width && isJITGeneralRegister(right)
      case .immediate(_, let width):
        return width == target.width
      case .memory(let address, let width):
        return width == target.width && isJITMemoryAddress(address)
      }
    case .unsignedAccumulatorMultiply(let source):
      guard case .register(let register) = source else { return false }
      return register.width == .i64 && isJITGeneralRegister(register)
    case .unsignedAccumulatorDivide(let source):
      guard case .register(let register) = source else { return false }
      return (register.width == .i32 || register.width == .i64) && isJITGeneralRegister(register)
    case .doubleShiftRightCL(let destination, let source),
      .doubleShiftRightImmediate(let destination, let source, _):
      guard case .register(let target) = destination,
        case .register(let origin) = source
      else { return false }
      return target.width == .i64 && origin.width == .i64
        && isJITGeneralRegister(target) && isJITGeneralRegister(origin)
    case .extendMove(let destination, let source, let signed):
      guard case .register(let target) = destination,
        isJITGeneralRegister(target)
      else { return false }
      switch source {
      case .register(let register):
        return register.bank == "x86.gpr" && register.index < 16
          && (register.width == .i8 || register.width == .i16
            || (signed && register.width == .i32 && target.width == .i64))
      case .memory(let address, let width):
        return (width == .i8 || width == .i16
          || (signed && width == .i32 && target.width == .i64)) && isJITMemoryAddress(address)
      default:
        return false
      }
    case .effectiveAddress(let destination, let address):
      guard case .register(let target) = destination, isJITGeneralRegister(target),
        address.addressWidth == .i32 || address.addressWidth == .i64,
        address.scale == 1 || address.scale == 2 || address.scale == 4 || address.scale == 8
      else { return false }
      return [address.base, address.index].compactMap { $0 }.allSatisfy {
        isJITGeneralRegister($0) && $0.width == address.addressWidth
      }
    case .exchangeRegisters(let lhs, let rhs):
      return isJITGeneralRegister(lhs) && lhs.width == .i64
        && isJITGeneralRegister(rhs) && rhs.width == .i64
    case .compareExchange(let destination, let source):
      guard case .memory(let address, let width) = destination,
        (width == .i32 || width == .i64) && isJITMemoryAddress(address),
        case .register(let register) = source,
        register.width == width && isJITGeneralRegister(register)
      else { return false }
      return true
    case .readSegment(_, let destination):
      switch destination {
      case .register(let register):
        return register.bank == "x86.gpr" && register.index < 16 && register.width == .i16
      case .memory(let address, let width):
        return width == .i16 && isJITMemoryAddress(address)
      case .immediate:
        return false
      }
    case .signExtendAccumulatorHigh(let width):
      return width == .i32 || width == .i64
    case .clearInterruptFlag, .setDirectionFlag, .readTimestampCounter, .memoryFence:
      return true
    case .helper:
      return false
    }
  }

  private func isJITGeneralRegister(_ register: DoryIRRegister) -> Bool {
    register.bank == "x86.gpr" && register.index < 16
      && (register.width == .i32 || register.width == .i64)
  }

  private func isJITLowByteRegister(_ register: DoryIRRegister) -> Bool {
    register.bank == "x86.gpr" && register.index < 16 && register.width == .i8
  }

  private func isJITMemoryAddress(_ address: DoryIRMemoryAddress) -> Bool {
    (address.segment == nil || address.segment == "fs" || address.segment == "gs")
      && (address.addressWidth == .i32 || address.addressWidth == .i64)
      && (address.scale == 1 || address.scale == 2 || address.scale == 4 || address.scale == 8)
      && [address.base, address.index].compactMap { $0 }.allSatisfy {
        isJITGeneralRegister($0) && $0.width == address.addressWidth
      }
  }

  private enum MemoryBehavior: Int, Comparable {
    case none, read, write

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
  }

  private func memoryBehavior(_ statement: DoryIRStatement) -> MemoryBehavior {
    switch statement {
    case .copy(let destination, let source):
      if isMemory(destination) { return .write }
      return isMemory(source) ? .read : .none
    case .binary(_, let destination, let source, let writesDestination):
      if isMemory(destination) { return writesDestination ? .write : .read }
      return isMemory(source) ? .read : .none
    case .unary(_, let operand):
      return isMemory(operand) ? .write : .none
    case .shift(_, let destination, _):
      return isMemory(destination) ? .write : .none
    case .conditionalMove(_, let destination, let source):
      if isMemory(destination) { return .write }
      return isMemory(source) ? .read : .none
    case .setCondition(_, let destination):
      return isMemory(destination) ? .write : .none
    case .bitTestMemoryImmediate(let operation, _, _):
      return operation == .test ? .read : .write
    case .bitTestRegister:
      return .none
    case .bitScan(_, let destination, let source):
      if isMemory(destination) { return .write }
      return isMemory(source) ? .read : .none
    case .byteSwap:
      return .none
    case .stackPush, .stackPushFlags:
      return .write
    case .stackPop:
      return .read
    case .signedMultiply(let destination, let lhs, let rhs):
      if isMemory(destination) { return .write }
      return isMemory(lhs) || isMemory(rhs) ? .read : .none
    case .unsignedAccumulatorMultiply(let source), .unsignedAccumulatorDivide(let source):
      return isMemory(source) ? .read : .none
    case .doubleShiftRightCL(let destination, let source),
      .doubleShiftRightImmediate(let destination, let source, _):
      if isMemory(destination) { return .write }
      return isMemory(source) ? .read : .none
    case .extendMove(let destination, let source, _):
      if isMemory(destination) { return .write }
      return isMemory(source) ? .read : .none
    case .compareExchange:
      return .write
    case .exchangeRegisters:
      return .none
    case .readSegment(_, let destination):
      return isMemory(destination) ? .write : .none
    case .effectiveAddress, .clearInterruptFlag, .setDirectionFlag, .readTimestampCounter,
      .signExtendAccumulatorHigh, .memoryFence, .helper:
      return .none
    }
  }

  private func isMemory(_ operand: DoryIROperand) -> Bool {
    if case .memory = operand { return true }
    return false
  }

  private func fallback(
    _ instruction: DoryX86DecodedInstruction,
    reason: DoryIRExitReason
  ) -> (statements: [DoryIRStatement], terminator: DoryIRTerminator?) {
    (
      [.helper(identifier: "x86.interpret.one", payload: instruction.bytes)],
      .exit(reason, resumeAt: instruction.address)
    )
  }

  private func operand(
    _ source: DoryX86Operand,
    instructionRelativeBase: UInt64? = nil
  ) -> DoryIROperand {
    switch source {
    case .register(let generalRegister, let width):
      .register(irRegister(generalRegister, width: irWidth(width)))
    case .highByteRegister(let register):
      .register(.init(bank: "x86.high8", index: registerIndex(register), width: .i8))
    case .memory(let memory):
      .memory(
        address(memory, instructionRelativeBase: instructionRelativeBase),
        width: irWidth(memory.width)
      )
    case .immediate(let value, let width):
      .immediate(value, width: irWidth(width))
    case .relative(let value, let width):
      .immediate(UInt64(bitPattern: value), width: irWidth(width))
    }
  }

  private func address(
    _ source: DoryX86MemoryOperand,
    instructionRelativeBase: UInt64?
  ) -> DoryIRMemoryAddress {
    .init(
      base: source.base.map { irRegister($0, width: irWidth(source.addressWidth)) },
      index: source.index.map { irRegister($0, width: irWidth(source.addressWidth)) },
      scale: source.scale,
      displacement: source.displacement,
      instructionRelativeBase: source.ripRelative ? instructionRelativeBase : nil,
      addressWidth: irWidth(source.addressWidth),
      // Long mode ignores legacy segment bases, but FS/GS still contribute their bases.
      // Preserve those segments so a backend without segment support declines the access.
      segment: source.ignoresLegacySegmentBase && source.segment != .fs && source.segment != .gs
        ? nil : source.segment.rawValue
    )
  }

  private func irRegister(
    _ register: DoryX86GeneralRegister,
    width: DoryIRIntegerWidth
  ) -> DoryIRRegister {
    .init(bank: "x86.gpr", index: registerIndex(register), width: width)
  }

  private func registerIndex(_ register: DoryX86GeneralRegister) -> UInt16 {
    switch register {
    case .rax: 0
    case .rcx: 1
    case .rdx: 2
    case .rbx: 3
    case .rsp: 4
    case .rbp: 5
    case .rsi: 6
    case .rdi: 7
    case .r8: 8
    case .r9: 9
    case .r10: 10
    case .r11: 11
    case .r12: 12
    case .r13: 13
    case .r14: 14
    case .r15: 15
    }
  }

  private func irBinaryOperation(_ operation: DoryX86ALUOperation) -> DoryIRBinaryOperation {
    switch operation {
    case .add: .add
    case .addWithCarry: .addWithCarry
    case .or: .or
    case .subtractWithBorrow: .subtractWithBorrow
    case .and: .and
    case .subtract: .subtract
    case .xor: .xor
    case .compare: .compare
    case .test: .test
    }
  }

  private func irUnaryOperation(_ operation: DoryX86UnaryOperation) -> DoryIRUnaryOperation {
    switch operation {
    case .increment: .increment
    case .decrement: .decrement
    case .bitwiseNot: .bitwiseNot
    case .negate: .negate
    }
  }

  private func irWidth(_ width: DoryX86OperandWidth) -> DoryIRIntegerWidth {
    switch width {
    case .byte: .i8
    case .word: .i16
    case .doubleword: .i32
    case .quadword: .i64
    }
  }

  private func conditionName(_ condition: DoryX86Condition) -> String {
    switch condition {
    case .overflow: "x86.condition.0"
    case .notOverflow: "x86.condition.1"
    case .below: "x86.condition.2"
    case .aboveOrEqual: "x86.condition.3"
    case .equal: "x86.condition.4"
    case .notEqual: "x86.condition.5"
    case .belowOrEqual: "x86.condition.6"
    case .above: "x86.condition.7"
    case .sign: "x86.condition.8"
    case .notSign: "x86.condition.9"
    case .parity: "x86.condition.10"
    case .notParity: "x86.condition.11"
    case .less: "x86.condition.12"
    case .greaterOrEqual: "x86.condition.13"
    case .lessOrEqual: "x86.condition.14"
    case .greater: "x86.condition.15"
    }
  }

  // Non-flat legacy code is rejected by the executor before cache/trace entry.
  // Preserve native flat32 branches, including16-bit operand overrides.
  private func nearRelativeTarget(
    _ instruction: DoryX86DecodedInstruction, relative: Int64, mode: DoryX86ExecutionMode
  ) -> UInt64 {
    let target = addRelative(instruction.nextInstructionAddress, relative)
    if mode == .long64 { return target }
    return target & (instruction.prefixes.operandSizeOverride ? 0xFFFF : 0xFFFF_FFFF)
  }

  private func addRelative(_ address: UInt64, _ displacement: Int64) -> UInt64 {
    address &+ UInt64(bitPattern: displacement)
  }
}
