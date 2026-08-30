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

public enum DoryIRStatement: Codable, Sendable, Hashable {
  case copy(destination: DoryIROperand, source: DoryIROperand)
  case binary(
    DoryIRBinaryOperation,
    destination: DoryIROperand,
    source: DoryIROperand,
    writesDestination: Bool
  )
  case unary(DoryIRUnaryOperation, operand: DoryIROperand)
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

    while offset < bytes.count, instructionCount < instructionBudget {
      let instructionAddress = address &+ UInt64(offset)
      let instruction = try decoder.decode(
        Array(bytes.dropFirst(offset).prefix(15)),
        at: instructionAddress,
        mode: mode
      )
      offset += Int(instruction.length)
      instructionCount += 1
      let lowering = lower(instruction)
      let isolatesMemoryAccess = lowering.statements.contains(where: containsMemory)
      if instructionCount > 1, requiresJITFallback(lowering) || isolatesMemoryAccess {
        offset -= Int(instruction.length)
        instructionCount -= 1
        terminator = .next(instructionAddress)
        break
      }
      statements.append(contentsOf: lowering.statements)
      if isolatesMemoryAccess {
        terminator = .next(instruction.nextInstructionAddress)
        break
      }
      if let end = lowering.terminator {
        terminator = end
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
    _ instruction: DoryX86DecodedInstruction
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
    case .jump(let relative):
      return ([], .branch(addRelative(instruction.nextInstructionAddress, relative)))
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
    case .callIndirect, .jumpIndirect, .return, .farCall, .farJump, .farReturn:
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
      where (width == .i32 || width == .i64) && isJITMemoryAddress(address):
        switch source {
        case .register(let register):
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
      guard case .register(let target) = destination, isJITGeneralRegister(target) else {
        return false
      }
      switch source {
      case .register(let register):
        return isJITGeneralRegister(register) && register.width == target.width
      case .immediate(_, let width):
        return width == target.width
      case .memory:
        return false
      }
    case .unary(_, let operand):
      guard case .register(let register) = operand else { return false }
      return isJITGeneralRegister(register)
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

  private func containsMemory(_ statement: DoryIRStatement) -> Bool {
    switch statement {
    case .copy(let destination, let source):
      return isMemory(destination) || isMemory(source)
    case .binary(_, let destination, let source, _):
      return isMemory(destination) || isMemory(source)
    case .unary(_, let operand):
      return isMemory(operand)
    case .effectiveAddress, .helper:
      return false
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
