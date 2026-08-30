import Foundation

public enum DoryX86ExecutionMode: String, Codable, Sendable, Hashable {
  case real16
  case protected16
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

public enum DoryX86SegmentRegister: String, Codable, Sendable, Hashable {
  case cs, ds, es, fs, gs, ss
}

public struct DoryX86MemoryOperand: Codable, Sendable, Hashable {
  public let base: DoryX86GeneralRegister?
  public let index: DoryX86GeneralRegister?
  public let scale: UInt8
  public let displacement: Int64
  public let ripRelative: Bool
  public let width: DoryX86OperandWidth
  public let addressWidth: DoryX86OperandWidth
  public let segment: DoryX86SegmentRegister
  public let ignoresLegacySegmentBase: Bool

  public init(
    base: DoryX86GeneralRegister?,
    index: DoryX86GeneralRegister? = nil,
    scale: UInt8 = 1,
    displacement: Int64 = 0,
    ripRelative: Bool = false,
    width: DoryX86OperandWidth,
    addressWidth: DoryX86OperandWidth = .quadword,
    segment: DoryX86SegmentRegister = .ds,
    ignoresLegacySegmentBase: Bool = true
  ) {
    self.base = base
    self.index = index
    self.scale = scale
    self.displacement = displacement
    self.ripRelative = ripRelative
    self.width = width
    self.addressWidth = addressWidth
    self.segment = segment
    self.ignoresLegacySegmentBase = ignoresLegacySegmentBase
  }
}

public enum DoryX86Operand: Codable, Sendable, Hashable {
  case register(DoryX86GeneralRegister, width: DoryX86OperandWidth)
  case highByteRegister(DoryX86GeneralRegister)
  case memory(DoryX86MemoryOperand)
  case immediate(UInt64, width: DoryX86OperandWidth)
  case relative(Int64, width: DoryX86OperandWidth)
}

public enum DoryX86ALUOperation: String, Codable, Sendable, Hashable {
  case add, addWithCarry, or, subtractWithBorrow, and, subtract, xor, compare, test
}

public enum DoryX86UnaryOperation: String, Codable, Sendable, Hashable {
  case increment, decrement, bitwiseNot, negate
}

public enum DoryX86ShiftOperation: String, Codable, Sendable, Hashable {
  case rotateLeft, rotateRight, rotateCarryLeft, rotateCarryRight
  case shiftLeft, shiftRight, arithmeticShiftRight
}

public enum DoryX86ShiftCount: Codable, Sendable, Hashable {
  case immediate(UInt8)
  case cl
}

public enum DoryX86DoubleShiftOperation: String, Codable, Sendable, Hashable {
  case left, right
}

public enum DoryX86AccumulatorArithmeticOperation: String, Codable, Sendable, Hashable {
  case unsignedMultiply, signedMultiply, unsignedDivide, signedDivide
}

public enum DoryX86BitOperation: String, Codable, Sendable, Hashable {
  case test, set, reset, complement
}

public enum DoryX86MemoryFence: String, Codable, Sendable, Hashable {
  case load, store, full
}

public enum DoryX86StringOperation: String, Codable, Sendable, Hashable {
  case move, compare, store, load, scan, input, output
}

public enum DoryX86IOPort: Codable, Sendable, Hashable {
  case immediate(UInt8)
  case dx
}

public enum DoryX86LoopCondition: String, Codable, Sendable, Hashable {
  case countNonzero
  case countNonzeroAndZero
  case countNonzeroAndNotZero
  case countZero
}

public enum DoryX86DescriptorTableRegister: String, Codable, Sendable, Hashable {
  case global, interrupt
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
  case unary(DoryX86UnaryOperation, operand: DoryX86Operand)
  case shift(DoryX86ShiftOperation, destination: DoryX86Operand, count: DoryX86ShiftCount)
  case doubleShift(
    DoryX86DoubleShiftOperation,
    destination: DoryX86Operand,
    source: DoryX86Operand,
    count: DoryX86ShiftCount
  )
  case extendMove(destination: DoryX86Operand, source: DoryX86Operand, signed: Bool)
  case conditionalMove(DoryX86Condition, destination: DoryX86Operand, source: DoryX86Operand)
  case setCondition(DoryX86Condition, destination: DoryX86Operand)
  case signedMultiply(destination: DoryX86Operand, lhs: DoryX86Operand, rhs: DoryX86Operand)
  case accumulatorArithmetic(DoryX86AccumulatorArithmeticOperation, source: DoryX86Operand)
  case signExtendAccumulator(width: DoryX86OperandWidth, intoHighHalf: Bool)
  case exchange(DoryX86Operand, DoryX86Operand)
  case compareExchange(destination: DoryX86Operand, source: DoryX86Operand)
  case exchangeAdd(destination: DoryX86Operand, source: DoryX86Operand)
  case bitTest(DoryX86BitOperation, base: DoryX86Operand, index: DoryX86Operand)
  case bitScan(reverse: Bool, destination: DoryX86Operand, source: DoryX86Operand)
  case byteSwap(DoryX86Operand)
  case compareExchangePair(destination: DoryX86MemoryOperand, doubleQuadword: Bool)
  case memoryFence(DoryX86MemoryFence)
  case waitForCoprocessor
  case initializeFloatingPoint
  case loadX87ControlWord(DoryX86Operand)
  case loadMXCSR(DoryX86Operand)
  case storeMXCSR(DoryX86Operand)
  case loadVector128(register: UInt8, source: DoryX86MemoryOperand)
  case storeVector128(register: UInt8, destination: DoryX86MemoryOperand)
  case processorPause
  case string(DoryX86StringOperation, width: DoryX86OperandWidth)
  case input(port: DoryX86IOPort, width: DoryX86OperandWidth)
  case output(port: DoryX86IOPort, width: DoryX86OperandWidth)
  case descriptorTable(
    DoryX86DescriptorTableRegister,
    load: Bool,
    address: DoryX86MemoryOperand
  )
  case readSegment(DoryX86SegmentRegister, destination: DoryX86Operand)
  case writeSegment(DoryX86SegmentRegister, source: DoryX86Operand)
  case farJump(offset: UInt64, selector: UInt16)
  case farCall(offset: UInt64, selector: UInt16, width: DoryX86OperandWidth)
  case farReturn(popBytes: UInt16, width: DoryX86OperandWidth)
  case machineStatusWord(load: Bool, operand: DoryX86Operand)
  case clearTaskSwitched
  case storeSystemSegment(task: Bool, destination: DoryX86Operand)
  case loadSystemSegment(task: Bool, source: DoryX86Operand)
  case push(DoryX86Operand)
  case pop(DoryX86Operand)
  case call(relative: Int64)
  case callIndirect(DoryX86Operand)
  case `return`
  case jump(relative: Int64)
  case jumpIndirect(DoryX86Operand)
  case conditionalJump(DoryX86Condition, relative: Int64)
  case loop(DoryX86LoopCondition, relative: Int64, counterWidth: DoryX86OperandWidth)
  case cpuid
  case readControlRegister(index: UInt8, destination: DoryX86GeneralRegister)
  case writeControlRegister(index: UInt8, source: DoryX86GeneralRegister)
  case invalidatePage(DoryX86MemoryOperand)
  case readModelSpecificRegister
  case writeModelSpecificRegister
  case readTimestampCounter(includeAuxiliary: Bool)
  case swapGS
  case softwareInterrupt(vector: UInt8)
  case interruptReturn
  case pushFlags(width: DoryX86OperandWidth)
  case popFlags(width: DoryX86OperandWidth)
  case leave(width: DoryX86OperandWidth)
  case setCarry(Bool)
  case complementCarry
  case setDirection(Bool)
  case flagByte(load: Bool)
  case syscall
  case sysret
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
