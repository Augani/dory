import Foundation

public enum DoryX86ExecutionMode: String, Codable, Sendable, Hashable {
  case real16
  case protected32
  case long64
}

public enum DoryX86OperandWidth: UInt8, Codable, Sendable, Hashable {
  case byte = 8
  case word = 16
  case doubleword = 32
  case quadword = 64

  public var byteCount: Int { Int(rawValue / 8) }
}

public struct DoryX86REXPrefix: Codable, Sendable, Hashable {
  public let w: Bool
  public let r: Bool
  public let x: Bool
  public let b: Bool

  init(byte: UInt8) {
    w = byte & 0x8 != 0
    r = byte & 0x4 != 0
    x = byte & 0x2 != 0
    b = byte & 0x1 != 0
  }
}

public struct DoryX86InstructionPrefixes: Codable, Sendable, Hashable {
  public var lock = false
  public var repeatPrefix: UInt8?
  public var segmentOverride: UInt8?
  public var operandSizeOverride = false
  public var addressSizeOverride = false
  public var rex: DoryX86REXPrefix?

  public init() {}
}

public struct DoryX86MemoryOperand: Codable, Sendable, Hashable {
  public let base: DoryX86GeneralRegister?
  public let index: DoryX86GeneralRegister?
  public let scale: UInt8
  public let displacement: Int64
  public let ripRelative: Bool
  public let width: DoryX86OperandWidth

  public init(
    base: DoryX86GeneralRegister?,
    index: DoryX86GeneralRegister? = nil,
    scale: UInt8 = 1,
    displacement: Int64 = 0,
    ripRelative: Bool = false,
    width: DoryX86OperandWidth
  ) {
    self.base = base
    self.index = index
    self.scale = scale
    self.displacement = displacement
    self.ripRelative = ripRelative
    self.width = width
  }
}

public enum DoryX86Operand: Codable, Sendable, Hashable {
  case register(DoryX86GeneralRegister, width: DoryX86OperandWidth)
  case memory(DoryX86MemoryOperand)
  case immediate(UInt64, width: DoryX86OperandWidth)
  case relative(Int64, width: DoryX86OperandWidth)
}

public enum DoryX86ALUOperation: String, Codable, Sendable, Hashable {
  case add, or, and, subtract, xor, compare, test
}

public enum DoryX86Condition: UInt8, Codable, Sendable, Hashable {
  case overflow = 0
  case notOverflow
  case below
  case aboveOrEqual
  case equal
  case notEqual
  case belowOrEqual
  case above
  case sign
  case notSign
  case parity
  case notParity
  case less
  case greaterOrEqual
  case lessOrEqual
  case greater
}

public enum DoryX86InstructionOperation: Codable, Sendable, Hashable {
  case move(destination: DoryX86Operand, source: DoryX86Operand)
  case loadEffectiveAddress(destination: DoryX86Operand, source: DoryX86MemoryOperand)
  case alu(DoryX86ALUOperation, destination: DoryX86Operand, source: DoryX86Operand)
  case push(DoryX86Operand)
  case pop(DoryX86Operand)
  case call(relative: Int64)
  case `return`
  case jump(relative: Int64)
  case conditionalJump(DoryX86Condition, relative: Int64)
  case cpuid
  case syscall
  case halt
  case setInterruptsEnabled(Bool)
  case noOperation
}

public struct DoryX86DecodedInstruction: Codable, Sendable, Hashable {
  public let address: UInt64
  public let bytes: [UInt8]
  public let prefixes: DoryX86InstructionPrefixes
  public let operation: DoryX86InstructionOperation

  public init(
    address: UInt64,
    bytes: [UInt8],
    prefixes: DoryX86InstructionPrefixes,
    operation: DoryX86InstructionOperation
  ) {
    self.address = address
    self.bytes = bytes
    self.prefixes = prefixes
    self.operation = operation
  }

  public var length: UInt8 { UInt8(bytes.count) }
  public var nextInstructionAddress: UInt64 { address &+ UInt64(bytes.count) }
}
