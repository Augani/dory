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
  case left, logicalRight, arithmeticRight
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
  case shift(DoryIRShiftOperation, destination: DoryIROperand, count: UInt8)
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
    var terminator: DoryIRTerminator?
    var containsMemoryAccess = false

    while offset < bytes.count, instructionCount < instructionBudget {
      let instructionAddress = address &+ UInt64(offset)
      let instruction = try decoder.decode(
        Array(bytes.dropFirst(offset).prefix(15)),
        at: instructionAddress,
        mode: mode
      )
      offset += Int(instruction.length)
      instructionCount += 1
      let lowering = lower(instruction, mode: mode)
      let statementMemoryBehavior = lowering.statements.reduce(MemoryBehavior.none) {
        max($0, self.memoryBehavior($1))
      }
      let memoryBehavior = max(
        statementMemoryBehavior,
        lowering.terminator.map(terminatorMemoryBehavior) ?? .none
      )
      if instructionCount > 1,
        requiresJITFallback(lowering)
          || (memoryBehavior != .none && containsMemoryAccess)
      {
        offset -= Int(instruction.length)
        instructionCount -= 1
        terminator = .next(instructionAddress)
        break
      }
      statements.append(contentsOf: lowering.statements)
      containsMemoryAccess = containsMemoryAccess || memoryBehavior != .none
      if let end = lowering.terminator {
        terminator = end
        break
      }
      // A write may modify bytes already decoded later in this block, so it remains a hard
      // boundary. One read can safely share a block with pure register work: callback failure
      // discards the native context and replays the unchanged block through the interpreter.
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
    switch instruction.operation {
    case .noOperation, .processorPause, .memoryFence:
      return ([], nil)
    case .move(let destination, let source):
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
            DoryIRBinaryOperation(rawValue: operation.rawValue)!,
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
            DoryIRUnaryOperation(rawValue: operation.rawValue)!,
            operand: operand(
              source,
              instructionRelativeBase: instruction.nextInstructionAddress
            )
          )
        ],
        nil
      )
    case .shift(let operation, let destination, .immediate(let count)):
      let loweredOperation: DoryIRShiftOperation
      switch operation {
      case .shiftLeft: loweredOperation = .left
      case .shiftRight: loweredOperation = .logicalRight
      case .arithmeticShiftRight: loweredOperation = .arithmeticRight
      default: return fallback(instruction, reason: .interpreter)
      }
      return (
        [
          .shift(
            loweredOperation,
            destination: operand(
              destination,
              instructionRelativeBase: instruction.nextInstructionAddress
            ),
            count: count
          )
        ],
        nil
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
    case .jump(let relative):
      return ([], .branch(addRelative(instruction.nextInstructionAddress, relative)))
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
    case .conditionalJump(let condition, let relative):
      return (
        [],
        .conditional(
          condition: conditionName(condition),
          taken: addRelative(instruction.nextInstructionAddress, relative),
          notTaken: instruction.nextInstructionAddress
        )
      )
    case .halt:
      return ([], .exit(.halt, resumeAt: instruction.nextInstructionAddress))
    case .input, .output, .string(.input, _), .string(.output, _):
      return fallback(instruction, reason: .portIO)
    case .callIndirect, .jumpIndirect, .return, .returnAndPop, .farCall, .farJump, .farReturn:
      return fallback(instruction, reason: .indirectControl)
    default:
      return fallback(instruction, reason: .interpreter)
    }
  }

  private func requiresJITFallback(
    _ lowering: (statements: [DoryIRStatement], terminator: DoryIRTerminator?)
  ) -> Bool {
    lowering.statements.contains { !isBaselineJITSupported($0) }
  }

  private func isBaselineJITSupported(_ statement: DoryIRStatement) -> Bool {
    switch statement {
    case .copy(let destination, let source):
      switch destination {
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
    case .binary(_, let destination, let source, _):
      let targetWidth: DoryIRIntegerWidth
      switch destination {
      case .register(let target) where isJITGeneralRegister(target):
        targetWidth = target.width
      case .memory(let address, let width)
      where (width == .i32 || width == .i64) && isJITMemoryAddress(address):
        targetWidth = width
      default:
        return false
      }
      switch source {
      case .register(let register):
        return isJITGeneralRegister(register) && register.width == targetWidth
      case .immediate(_, let width):
        return width == targetWidth
      case .memory(let address, let width):
        guard case .register = destination else { return false }
        return width == targetWidth && isJITMemoryAddress(address)
      }
    case .unary(_, let operand):
      switch operand {
      case .register(let register):
        return isJITGeneralRegister(register)
      case .memory(let address, let width):
        return (width == .i32 || width == .i64) && isJITMemoryAddress(address)
      case .immediate:
        return false
      }
    case .shift(_, let destination, _):
      guard case .register(let register) = destination else { return false }
      return isJITGeneralRegister(register)
    case .signedMultiply(let destination, let lhs, let rhs):
      guard case .register(let target) = destination, target.width == .i32,
        case .register(let left) = lhs, left.width == .i32,
        case .register(let right) = rhs, right.width == .i32
      else { return false }
      return isJITGeneralRegister(target) && isJITGeneralRegister(left)
        && isJITGeneralRegister(right)
    case .extendMove(let destination, let source, let signed):
      guard !signed, case .register(let target) = destination,
        isJITGeneralRegister(target)
      else { return false }
      switch source {
      case .register(let register):
        return register.bank == "x86.gpr" && register.index < 16
          && (register.width == .i8 || register.width == .i16)
      case .memory(let address, let width):
        return (width == .i8 || width == .i16) && isJITMemoryAddress(address)
      default:
        return false
      }
    case .effectiveAddress(let destination, let address):
      guard case .register(let target) = destination, isJITGeneralRegister(target),
        address.segment == nil,
        address.addressWidth == .i32 || address.addressWidth == .i64,
        address.scale == 1 || address.scale == 2 || address.scale == 4 || address.scale == 8
      else { return false }
      return [address.base, address.index].compactMap { $0 }.allSatisfy {
        isJITGeneralRegister($0) && $0.width == address.addressWidth
      }
    case .helper:
      return false
    }
  }

  private func isJITGeneralRegister(_ register: DoryIRRegister) -> Bool {
    register.bank == "x86.gpr" && register.index < 16
      && (register.width == .i32 || register.width == .i64)
  }

  private func isJITMemoryAddress(_ address: DoryIRMemoryAddress) -> Bool {
    address.segment == nil && (address.addressWidth == .i32 || address.addressWidth == .i64)
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
    case .signedMultiply(let destination, let lhs, let rhs):
      if isMemory(destination) { return .write }
      return isMemory(lhs) || isMemory(rhs) ? .read : .none
    case .extendMove(let destination, let source, _):
      if isMemory(destination) { return .write }
      return isMemory(source) ? .read : .none
    case .effectiveAddress, .helper:
      return .none
    }
  }

  private func terminatorMemoryBehavior(_ terminator: DoryIRTerminator) -> MemoryBehavior {
    switch terminator {
    case .call, .indirectCall:
      .write
    case .returnFromCall:
      .read
    case .indirect(let target):
      isMemory(target) ? .read : .none
    case .next, .branch, .conditional, .exit:
      .none
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
      segment: source.ignoresLegacySegmentBase ? nil : source.segment.rawValue
    )
  }

  private func irRegister(
    _ register: DoryX86GeneralRegister,
    width: DoryIRIntegerWidth
  ) -> DoryIRRegister {
    .init(bank: "x86.gpr", index: registerIndex(register), width: width)
  }

  private func registerIndex(_ register: DoryX86GeneralRegister) -> UInt16 {
    UInt16(DoryX86GeneralRegister.allCases.firstIndex(of: register)!)
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
    "x86.condition.\(condition.rawValue)"
  }

  private func addRelative(_ address: UInt64, _ displacement: Int64) -> UInt64 {
    address &+ UInt64(bitPattern: displacement)
  }
}
