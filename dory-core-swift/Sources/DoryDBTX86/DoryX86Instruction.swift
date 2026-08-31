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

public enum DoryX86VectorOperand: Codable, Sendable, Hashable {
  case register(UInt8)
  case memory(DoryX86MemoryOperand)
}

public enum DoryX86VectorScalarUpperPolicy: String, Codable, Sendable, Hashable {
  case preserve
  case zero
  case zeroOnMemorySource
}

public enum DoryX86VectorBitwiseOperation: String, Codable, Sendable, Hashable {
  case and, andNot, or, xor
}

public enum DoryX86VectorFloatingOperation: String, Codable, Sendable, Hashable {
  case add, multiply, subtract, minimum, divide, maximum
}

public enum DoryX86VectorFloatingFormat: String, Codable, Sendable, Hashable {
  case packedSingle, packedDouble, scalarSingle, scalarDouble
}

public enum DoryX86VectorIntegerOperation: String, Codable, Sendable, Hashable {
  case add, subtract, equal, greaterThan
  case addSignedSaturating, addUnsignedSaturating
  case subtractSignedSaturating, subtractUnsignedSaturating
  case minimumSigned, maximumSigned, minimumUnsigned, maximumUnsigned
  case averageUnsigned, sumAbsoluteDifferences
  case multiplyLow, multiplyHighSigned, multiplyHighUnsigned
  case multiplyUnsignedDoubleword, multiplyAddWords
}

public enum DoryX86VectorPackOperation: String, Codable, Sendable, Hashable {
  case signedSaturating, unsignedSaturating
}

public enum DoryX86VectorShiftOperation: String, Codable, Sendable, Hashable {
  case logicalLeft, logicalRight, arithmeticRight
}

public enum DoryX86VectorShiftCount: Codable, Sendable, Hashable {
  case immediate(UInt8)
  case vector(DoryX86VectorOperand)
}

public enum DoryX86VectorLaneWidth: UInt8, Codable, Sendable, Hashable {
  case byte = 1
  case word = 2
  case doubleword = 4
  case quadword = 8
}

public enum DoryX86VectorShuffleFormat: String, Codable, Sendable, Hashable {
  case packedSingle, packedDouble, packedDoublewords
}

public enum DoryX87MemoryFormat: String, Codable, Sendable, Hashable {
  case float32, float64, extended80
  case signedInteger16, signedInteger32, signedInteger64

  public var byteCount: Int {
    switch self {
    case .float32, .signedInteger32: 4
    case .float64, .signedInteger64: 8
    case .extended80: 10
    case .signedInteger16: 2
    }
  }
}

public enum DoryX87Operand: Codable, Sendable, Hashable {
  case register(UInt8)
  case memory(DoryX86MemoryOperand, format: DoryX87MemoryFormat)
}

public enum DoryX87BinaryOperation: String, Codable, Sendable, Hashable {
  case add, multiply, subtract, subtractReverse, divide, divideReverse
}

public enum DoryX87SpecialOperation: String, Codable, Sendable, Hashable {
  case changeSign, absolute, test, examine
  case loadOne, loadLog2Ten, loadLog2E, loadPi, loadLog10Two, loadLnTwo, loadZero
  case twoToXMinusOne, yLog2X, tangent, arctangent, extract
  case partialRemainderNearest, decrementTop, incrementTop, partialRemainder
  case yLog2XPlusOne, squareRoot, sineCosine, roundToInteger, scale, sine, cosine
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
  case cacheLineFlush(DoryX86MemoryOperand)
  case waitForCoprocessor
  case initializeFloatingPoint
  case loadX87ControlWord(DoryX86Operand)
  case storeX87ControlWord(DoryX86Operand)
  case loadX87(DoryX87Operand)
  case storeX87(
    destination: DoryX86MemoryOperand,
    format: DoryX87MemoryFormat,
    pop: Bool,
    truncate: Bool
  )
  case exchangeX87(UInt8)
  case x87Binary(
    DoryX87BinaryOperation,
    destination: UInt8,
    source: DoryX87Operand,
    pop: Bool
  )
  case compareX87(
    source: DoryX87Operand,
    popCount: UInt8,
    ordered: Bool,
    setIntegerFlags: Bool
  )
  case x87Special(DoryX87SpecialOperation)
  case loadX87Environment(DoryX86MemoryOperand)
  case storeX87Environment(DoryX86MemoryOperand)
  case loadX87PackedBCD(DoryX86MemoryOperand)
  case storeX87PackedBCD(DoryX86MemoryOperand, pop: Bool)
  case moveX87(destination: UInt8, source: UInt8, pop: Bool)
  case freeX87(UInt8, pop: Bool)
  case conditionalMoveX87(DoryX86Condition, source: UInt8)
  case clearX87Exceptions
  case storeX87StatusWord(DoryX86Operand)
  case saveFloatingPointState(DoryX86MemoryOperand)
  case restoreFloatingPointState(DoryX86MemoryOperand)
  case loadMXCSR(DoryX86Operand)
  case storeMXCSR(DoryX86Operand)
  case moveMMX(
    destination: DoryX86VectorOperand,
    source: DoryX86VectorOperand,
    byteCount: UInt8
  )
  case moveIntegerToMMX(destination: UInt8, source: DoryX86Operand)
  case moveMMXToInteger(destination: DoryX86Operand, source: UInt8)
  case mmxBitwise(
    DoryX86VectorBitwiseOperation,
    destination: UInt8,
    source: DoryX86VectorOperand
  )
  case mmxIntegerBinary(
    DoryX86VectorIntegerOperation,
    laneWidth: DoryX86VectorLaneWidth,
    destination: UInt8,
    source: DoryX86VectorOperand
  )
  case mmxIntegerShift(
    DoryX86VectorShiftOperation,
    laneWidth: DoryX86VectorLaneWidth,
    destination: UInt8,
    count: DoryX86VectorShiftCount
  )
  case mmxIntegerInterleave(
    high: Bool,
    laneWidth: DoryX86VectorLaneWidth,
    destination: UInt8,
    source: DoryX86VectorOperand
  )
  case mmxIntegerPack(
    DoryX86VectorPackOperation,
    sourceLaneWidth: DoryX86VectorLaneWidth,
    destination: UInt8,
    source: DoryX86VectorOperand
  )
  case emptyMMXState
  case moveVector128(
    destination: DoryX86VectorOperand,
    source: DoryX86VectorOperand,
    requiresAlignment: Bool
  )
  case moveVectorScalar(
    destination: DoryX86VectorOperand,
    source: DoryX86VectorOperand,
    byteCount: UInt8,
    upperPolicy: DoryX86VectorScalarUpperPolicy
  )
  case moveIntegerToVector(destination: UInt8, source: DoryX86Operand)
  case moveVectorToInteger(destination: DoryX86Operand, source: UInt8)
  case extractPackedWord(
    destination: DoryX86Operand,
    source: UInt8,
    index: UInt8,
    mmx: Bool
  )
  case moveVectorMask(
    destination: DoryX86Operand,
    source: DoryX86VectorOperand,
    laneWidth: DoryX86VectorLaneWidth,
    vectorByteCount: UInt8
  )
  case vectorBitwise(
    DoryX86VectorBitwiseOperation,
    destination: UInt8,
    source: DoryX86VectorOperand
  )
  case vectorFloatingBinary(
    DoryX86VectorFloatingOperation,
    format: DoryX86VectorFloatingFormat,
    destination: UInt8,
    source: DoryX86VectorOperand
  )
  case vectorIntegerBinary(
    DoryX86VectorIntegerOperation,
    laneWidth: DoryX86VectorLaneWidth,
    destination: UInt8,
    source: DoryX86VectorOperand
  )
  case vectorIntegerShift(
    DoryX86VectorShiftOperation,
    laneWidth: DoryX86VectorLaneWidth,
    destination: UInt8,
    count: DoryX86VectorShiftCount
  )
  case vectorByteShift(left: Bool, destination: UInt8, count: UInt8)
  case vectorFloatingCompare(
    format: DoryX86VectorFloatingFormat,
    destination: UInt8,
    source: DoryX86VectorOperand,
    quiet: Bool
  )
  case vectorIntegerInterleave(
    high: Bool,
    laneWidth: DoryX86VectorLaneWidth,
    destination: UInt8,
    source: DoryX86VectorOperand
  )
  case vectorIntegerPack(
    DoryX86VectorPackOperation,
    sourceLaneWidth: DoryX86VectorLaneWidth,
    destination: UInt8,
    source: DoryX86VectorOperand
  )
  case vectorShuffle(
    format: DoryX86VectorShuffleFormat,
    destination: UInt8,
    source: DoryX86VectorOperand,
    control: UInt8
  )
  case convertIntegerToScalarFloat(
    format: DoryX86VectorFloatingFormat,
    destination: UInt8,
    source: DoryX86Operand
  )
  case convertScalarFloatToInteger(
    format: DoryX86VectorFloatingFormat,
    destination: DoryX86Operand,
    source: DoryX86VectorOperand,
    truncate: Bool
  )
  case processorPause
  case string(DoryX86StringOperation, width: DoryX86OperandWidth)
  case input(port: DoryX86IOPort, width: DoryX86OperandWidth)
  case output(port: DoryX86IOPort, width: DoryX86OperandWidth)
  case descriptorTable(
    DoryX86DescriptorTableRegister,
    load: Bool,
    address: DoryX86MemoryOperand
  )
  case inspectSegmentDescriptor(
    accessRights: Bool,
    destination: DoryX86Operand,
    selector: DoryX86Operand
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
  case returnAndPop(UInt16)
  case jump(relative: Int64)
  case jumpIndirect(DoryX86Operand)
  case conditionalJump(DoryX86Condition, relative: Int64)
  case loop(DoryX86LoopCondition, relative: Int64, counterWidth: DoryX86OperandWidth)
  case enter(allocation: UInt16, nesting: UInt8, width: DoryX86OperandWidth)
  case translateByte(
    addressWidth: DoryX86OperandWidth,
    segment: DoryX86SegmentRegister,
    ignoresLegacySegmentBase: Bool
  )
  case cpuid
  case readControlRegister(index: UInt8, destination: DoryX86GeneralRegister)
  case writeControlRegister(index: UInt8, source: DoryX86GeneralRegister)
  case readDebugRegister(index: UInt8, destination: DoryX86GeneralRegister)
  case writeDebugRegister(index: UInt8, source: DoryX86GeneralRegister)
  case readExtendedControlRegister
  case writeExtendedControlRegister
  case invalidateCaches(writeBack: Bool)
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
  case systemEnter
  case systemExit(return64Bit: Bool)
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
