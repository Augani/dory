import Foundation

/// Recognized encodings whose facilities are not implemented or advertised by
/// the candidate CPU. Recognition preserves diagnostics; execution raises #UD.
public enum DoryX86UnsupportedSystemInstruction: String, Codable, Sendable, Hashable {
  case enclv, vmLaunch, vmResume, vmxOff, pconfig, wrmsrns, pbndkb
  case monitor, mwait, clac, stac, encls
  case vmFunc, xend, xtest, enclu
  case vmRun, vmmCall, vmLoad, vmSave, stgi, clgi, skinit, invlpga
  case serialize, rdpkru, wrpkru, monitorx, mwaitx, clzero, rdpru, invlpgb, tlbsync
  case xsave, xrstor, xsaveopt
}

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

  init(w: Bool, r: Bool, x: Bool, b: Bool) {
    self.w = w
    self.r = r
    self.x = x
    self.b = b
  }
}

/// VEX prefix decoded from `C4` (3-byte) or `C5` (2-byte) in long mode. The
/// prefix encodes REX-equivalent bits, an additional operand register (`vvvv`),
/// the vector length (`L`), a mandatory-prefix selector (`pp`), and the opcode
/// map selector (`mmmmm`).
public struct DoryX86VEXPrefix: Codable, Sendable, Hashable {
  /// The additional source register encoded in inverted form in bits 6:3.
  /// `0` means no third operand (2-operand form); `1...15` is the register index.
  public let vvvv: UInt8
  /// `true` for 256-bit YMM operation, `false` for 128-bit XMM.
  public let largeVector: Bool
  /// REX-equivalent bits.
  public let r: Bool
  public let x: Bool
  public let b: Bool
  public let w: Bool
  /// Opcode map: `1` = `0F`, `2` = `0F 38`, `3` = `0F 3A`.
  public let map: UInt8
  /// Mandatory prefix encoding: `0` = none, `1` = `66`, `2` = `F3`, `3` = `F2`.
  public let pp: UInt8

  public init(vvvv: UInt8, largeVector: Bool, r: Bool, x: Bool, b: Bool, w: Bool, map: UInt8, pp: UInt8) {
    self.vvvv = vvvv
    self.largeVector = largeVector
    self.r = r
    self.x = x
    self.b = b
    self.w = w
    self.map = map
    self.pp = pp
  }
}

/// Vector length for VEX-encoded operations.
public enum DoryX86VectorLength: UInt8, Codable, Sendable, Hashable {
  /// 128-bit XMM (low half of YMM, upper half preserved).
  case xmm128 = 16
  /// 256-bit YMM (full 32 bytes).
  case ymm256 = 32
}

public struct DoryX86InstructionPrefixes: Codable, Sendable, Hashable {
  public var lock = false
  public var repeatPrefix: UInt8?
  public var segmentOverride: UInt8?
  public var operandSizeOverride = false
  public var addressSizeOverride = false
  public var rex: DoryX86REXPrefix?
  public var vex: DoryX86VEXPrefix?

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

/// SSE3 element-duplication selects for `0F 12`/`0F 16` repeat-prefixed moves.
public enum DoryX86VectorDuplicateMode: String, Codable, Sendable, Hashable {
  /// `MOVDDUP` (`F2 0F 12`): broadcast the low 64 bits of the source into both
  /// 64-bit halves of the 128-bit destination.
  case doubleLow64
  /// `MOVSLDUP` (`F3 0F 12`): duplicate the low single-precision element of each
  /// dword pair across the 128-bit destination.
  case singleLow32
  /// `MOVSHDUP` (`F3 0F 16`): duplicate the high single-precision element of each
  /// dword pair across the 128-bit destination.
  case singleHigh32
}

public enum DoryX86VectorBitwiseOperation: String, Codable, Sendable, Hashable {
  case and, andNot, or, xor
}

public enum DoryX86VectorFloatingOperation: String, Codable, Sendable, Hashable {
  case add, multiply, subtract, minimum, divide, maximum
}

/// Legacy SSE comparison predicates for `CMPPS`/`CMPPD`/`CMPSS`/`CMPSD` (`0F C2`).
public enum DoryX86ScalarComparePredicate: UInt8, Codable, Sendable, Hashable {
  case equal = 0
  case lessThan = 1
  case lessEqual = 2
  case unordered = 3
  case notEqual = 4
  case notLessThan = 5
  case notLessEqual = 6
  case ordered = 7
}

/// SSE2 scalar conversion directions for `CVTSD2SS`/`CVTSS2SD`.
public enum DoryX86ScalarConvertDirection: String, Codable, Sendable, Hashable {
  case doubleToSingle
  case singleToDouble
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

/// VEX broadcast element width selectors for `VBROADCASTSS/SD/F128/I128` and
/// `VPBROADCASTB`.
public enum DoryX86VEXBroadcastMode: String, Codable, Sendable, Hashable {
  /// `VBROADCASTSS`: broadcast a 32-bit single-precision element to all dword lanes.
  case single32
  /// `VBROADCASTSD`: broadcast a 64-bit double-precision element to all qword lanes.
  case double64
  /// `VBROADCASTF128` / `VBROADCASTI128`: broadcast 128 bits to both halves of YMM.
  case packed128
}

public enum DoryX86VectorShuffleFormat: String, Codable, Sendable, Hashable {
  case packedSingle, packedDouble, packedDoublewords
  case packedLowWords, packedHighWords
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
  /// BMI1 flagless variable shifts (`SHRX`/`SARX`/`SHLX`): shift `source` by
  /// the count in the source register, without modifying RFLAGS.
  case flaglessShift(
    _ operation: DoryX86ShiftOperation,
    destination: DoryX86Operand,
    source: DoryX86Operand,
    count: DoryX86Operand
  )
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
  /// `MOVLPS`/`MOVHLPS`/`MOVHPS`/`MOVLHPS`: move a 64-bit half between a source
  /// half and a destination half of the low 128 bits, preserving the untouched
  /// 64-bit half of the destination and the upper 128 bits of the YMM register.
  /// Memory sources always supply 8 bytes (the low half); `sourceHigh` only
  /// selects the half for register sources.
  case moveVectorQwordHalf(
    destination: DoryX86VectorOperand,
    source: DoryX86VectorOperand,
    sourceHigh: Bool,
    destinationHigh: Bool
  )
  /// `MOVDDUP`/`MOVSLDUP`/`MOVSHDUP`: broadcast source elements across the
  /// 128-bit destination, preserving the upper 128 bits of the YMM register.
  case duplicateVectorScalar(
    destination: UInt8,
    source: DoryX86VectorOperand,
    mode: DoryX86VectorDuplicateMode
  )
  /// `PSHUFB` (`66 0F 38 00`): per-byte shuffle of the destination by the source
  /// index bytes, zeroing lanes whose index high bit is set. SSSE3.
  case shufflePackedBytes(destination: UInt8, source: DoryX86VectorOperand)
  /// `PALIGNR` (`66 0F 3A 0F`): concatenate `source:destination` and extract the
  /// 16 bytes starting at `count`. SSSE3.
  case alignPackedBytes(
    destination: UInt8, source: DoryX86VectorOperand, count: UInt8
  )
  /// `PTEST` (`66 0F 38 17`): set ZF/CF from bitwise tests of destination and
  /// source without modifying the destination. SSE4.1.
  case testPackedBits(destination: UInt8, source: DoryX86VectorOperand)
  /// `PMOVZXDQ`/`PMOVSXDQ` (`66 0F 38 35` / `66 0F 38 25`): extend each of the
  /// two low doublewords of the source to a destination quadword. SSE4.1.
  case extendPackedDwordToQword(
    destination: UInt8, source: DoryX86VectorOperand, signed: Bool
  )
  /// `PMOVSXBQ`/`PMOVZXBQ` (`66 0F 38 22` / `66 0F 38 32`): extend two low
  /// bytes of the source to two destination quadwords. SSE4.1.
  case extendPackedByteToQword(
    destination: UInt8, source: DoryX86VectorOperand, signed: Bool
  )
  /// `PCMPEQQ` (`66 0F 38 29`): compare packed quadwords for equality. SSE4.1.
  case comparePackedQwords(destination: UInt8, source: DoryX86VectorOperand)
  /// `PINSRQ` (`66 48 0F 3A 22`): insert a qword from a GPR or memory into a
  /// selected lane of an XMM register. SSE4.1.
  case insertPackedQword(
    destination: UInt8, source: DoryX86Operand, index: UInt8
  )
  /// PINSRW (66 0F C4): insert a word from GPR/memory into XMM at the given index.
  case insertPackedWord(
    destination: UInt8, source: DoryX86Operand, index: UInt8, mmx: Bool
  )
  /// UNPCKLPS/LPD/HPS/HPD (0F 14/15): interleave low/high elements.
  case unpackVector(
    high: Bool,
    doublePrecision: Bool,
    destination: UInt8,
    source: DoryX86VectorOperand
  )
  /// CVTTPD2DQ/CVTPD2DQ (66/F2 0F E6): convert two packed doubles to signed dwords.
  case convertPackedDoubleToDword(
    truncated: Bool,
    destination: UInt8,
    source: DoryX86VectorOperand
  )
  /// CVTPS2DQ/CVTTPS2DQ (66/F3 0F 5B): convert four packed singles to signed dwords.
  case convertPackedSingleToDword(
    truncated: Bool,
    destination: UInt8,
    source: DoryX86VectorOperand
  )
  /// CVTDQ2PD (F3 0F E6): convert two signed dwords from XMM/m64 to doubles.
  case convertPackedDwordToDouble(destination: UInt8, source: DoryX86VectorOperand)
  /// PCMPISTRI (66 0F 3A 63): SSE4.2 packed compare implicit-length strings,
  /// producing a byte or word index in ECX. The immediate encodes data size,
  /// aggregation, polarity, and output selection.
  case packedCompareStringIndex(
    destination: UInt8,
    source: DoryX86VectorOperand,
    immediate: UInt8
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
  /// `CMPPS`/`CMPPD`/`CMPSS`/`CMPSD` (`0F C2`): packed or scalar compare with
  /// an immediate predicate. Sets selected elements to all-1s or all-0s.
  case scalarCompare(
    predicate: DoryX86ScalarComparePredicate,
    format: DoryX86VectorFloatingFormat,
    destination: UInt8,
    source: DoryX86VectorOperand
  )
  /// `CVTSD2SS`/`CVTSS2SD` (`F2/F3 0F 5A`): convert scalar double↔single.
  case scalarConvert(
    direction: DoryX86ScalarConvertDirection,
    destination: UInt8,
    source: DoryX86VectorOperand
  )
  /// `SQRTPS`/`SQRTPD`/`SQRTSS`/`SQRTSD` (`0F 51`): packed or scalar square root.
  case scalarSquareRoot(
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
  // MARK: - VEX (AVX/AVX2) operations
  /// `VZEROUPPER` (`C5 F8 77`): zero the upper 128 bits of all YMM registers.
  case vexZeroUpper
  /// VEX-encoded 128/256-bit vector move (VMOVUPS/VMOVAPS/VMOVDQA). The
  /// `requiresAlignment` flag distinguishes aligned from unaligned forms.
  case vexMoveVector(
    destination: DoryX86VectorOperand,
    source: DoryX86VectorOperand,
    length: DoryX86VectorLength,
    requiresAlignment: Bool
  )
  /// VEX-encoded 3-operand floating-point binary (VXORPS/VPOR/VPXOR etc.).
  /// `destination = firstSource OP secondSource`.
  case vexVectorBinary(
    _ operation: DoryX86VectorBitwiseOperation,
    destination: UInt8,
    firstSource: UInt8,
    secondSource: DoryX86VectorOperand,
    length: DoryX86VectorLength
  )
  /// VEX-encoded 3-operand scalar/packed floating-point binary
  /// (VADDSS/SD, VMULSS/SD, VSUBSS/SD, VMINSS/SD, VDIVSS/SD, VMAXSS/SD).
  case vexVectorFloatingBinary(
    _ operation: DoryX86VectorFloatingOperation,
    format: DoryX86VectorFloatingFormat,
    destination: UInt8,
    firstSource: UInt8,
    secondSource: DoryX86VectorOperand,
    length: DoryX86VectorLength
  )
  /// VEX-encoded VUCOMISS/COMISS/VUCOMISD/COMISD.
  case vexCompareScalar(
    ordered: Bool,
    doublePrecision: Bool,
    destination: UInt8,
    source: DoryX86VectorOperand
  )
  /// VEX-encoded packed integer comparison (VPCMPGTB/W/D, VPCMPEQB/W/D).
  case vexComparePackedIntegers(
    greaterThan: Bool,
    laneWidth: DoryX86VectorLaneWidth,
    destination: UInt8,
    firstSource: UInt8,
    secondSource: DoryX86VectorOperand,
    length: DoryX86VectorLength
  )
  /// VEX-encoded packed integer addition (VPADDB/W/D).
  case vexAddPackedIntegers(
    laneWidth: DoryX86VectorLaneWidth,
    destination: UInt8,
    firstSource: UInt8,
    secondSource: DoryX86VectorOperand,
    length: DoryX86VectorLength
  )
  /// VEX-encoded VLDMXCSR (load MXCSR from memory).
  case vexLoadMXCSR(source: DoryX86Operand)
  /// VEX-encoded VSTMXCSR (store MXCSR to memory).
  case vexStoreMXCSR(destination: DoryX86Operand)
  /// VEX-encoded KMOVD (AVX-512 mask register move). Dory models mask
  /// registers as the low 32 bits of the destination XMM register.
  case vexMaskMove(
    destination: UInt8,
    source: DoryX86Operand
  )
  /// VEX-encoded packed min/max (VPMINUB, VPMINSW, VPMAXUB, VPMAXSW).
  case vexPackedMinMax(
    signed: Bool,
    minimum: Bool,
    laneWidth: DoryX86VectorLaneWidth,
    destination: UInt8,
    firstSource: UInt8,
    secondSource: DoryX86VectorOperand,
    length: DoryX86VectorLength
  )
  /// VEX-encoded packed subtract (VPSUBB/W, VPSUBUSB/W).
  case vexSubPackedIntegers(
    laneWidth: DoryX86VectorLaneWidth,
    saturating: Bool,
    unsigned: Bool,
    destination: UInt8,
    firstSource: UInt8,
    secondSource: DoryX86VectorOperand,
    length: DoryX86VectorLength
  )
  /// VEX-encoded variable shift (VPSRLVD, VPSRAVD).
  case vexVariableShift(
    arithmetic: Bool,
    laneWidth: DoryX86VectorLaneWidth,
    destination: UInt8,
    firstSource: UInt8,
    secondSource: DoryX86VectorOperand,
    length: DoryX86VectorLength
  )
  /// VEX-encoded VCVTSD2SS / VCVTSS2SD (3-operand scalar convert).
  case vexScalarConvert(
    direction: DoryX86ScalarConvertDirection,
    destination: UInt8,
    firstSource: UInt8,
    secondSource: DoryX86VectorOperand
  )
  /// VEX-encoded VCVTTSD2SI / VCVTSD2SI (scalar float to integer).
  case vexConvertScalarToInteger(
    truncated: Bool,
    doublePrecision: Bool,
    destination: DoryX86Operand,
    source: UInt8
  )
  /// VEX-encoded VUNPCKLPS/VUNPCKLPD.
  case vexUnpackLow(
    doublePrecision: Bool,
    destination: UInt8,
    firstSource: UInt8,
    secondSource: DoryX86VectorOperand,
    length: DoryX86VectorLength
  )
  /// VEX-encoded VUNPCKHPS/VUNPCKHPD.
  case vexUnpackHigh(
    doublePrecision: Bool,
    destination: UInt8,
    firstSource: UInt8,
    secondSource: DoryX86VectorOperand,
    length: DoryX86VectorLength
  )
  /// VEX-encoded 3-operand packed-byte comparison (VPCMPEQB).
  case vexComparePackedBytes(
    destination: UInt8,
    firstSource: UInt8,
    secondSource: DoryX86VectorOperand,
    length: DoryX86VectorLength
  )
  /// VEX-encoded `VPMOVMSKB`: extract the high bit of each byte into a GPR.
  case vexMoveMaskToInteger(
    destination: DoryX86Operand,
    source: UInt8,
    length: DoryX86VectorLength
  )
  /// VEX-encoded `VMOVD`/`VMOVQ` between GPR and XMM.
  case vexMoveIntegerToVector(
    destination: UInt8, source: DoryX86Operand, quadword: Bool
  )
  case vexMoveVectorToInteger(
    destination: DoryX86Operand, source: UInt8, quadword: Bool
  )
  /// VEX-encoded 3-operand `VPSHUFB`: `destination = PSHUFB(firstSource, secondSource)`.
  case vexShufflePackedBytes(
    destination: UInt8,
    firstSource: UInt8,
    secondSource: DoryX86VectorOperand,
    length: DoryX86VectorLength
  )
  /// VEX packed shift by immediate (`VPSRLQ`/`VPSLLQ`/`VPSRAD`): shift each
  /// lane of the source register by an immediate count, storing the result
  /// in the destination. The `vvvv` field encodes the source register.
  case vexVectorShiftImmediate(
    operation: DoryX86VectorShiftOperation,
    destination: UInt8,
    source: UInt8,
    immediate: UInt8,
    laneWidth: DoryX86VectorLaneWidth,
    length: DoryX86VectorLength
  )
  /// VEX broadcast family: replicate a source element across the destination.
  case vexBroadcast(
    destination: UInt8,
    source: DoryX86VectorOperand,
    mode: DoryX86VEXBroadcastMode,
    length: DoryX86VectorLength
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
  case verifySegment(readable: Bool, selector: DoryX86Operand)
  case readSegment(DoryX86SegmentRegister, destination: DoryX86Operand)
  case writeSegment(DoryX86SegmentRegister, source: DoryX86Operand)
  case farJump(offset: UInt64, selector: UInt16)
  case farJumpIndirect(address: DoryX86MemoryOperand, width: DoryX86OperandWidth)
  case farCall(offset: UInt64, selector: UInt16, width: DoryX86OperandWidth)
  case farCallIndirect(address: DoryX86MemoryOperand, width: DoryX86OperandWidth)
  case farReturn(popBytes: UInt16, width: DoryX86OperandWidth)
  case machineStatusWord(load: Bool, operand: DoryX86Operand)
  case vmCall
  case unsupportedSystemInstruction(DoryX86UnsupportedSystemInstruction)
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
  case undefinedInstruction
  // Append new cases so incremental clients retain every existing enum discriminator.
  /// CVTPS2PD (0F 5A): convert two packed singles from XMM/m64 to two doubles.
  case convertPackedSingleToDouble(destination: UInt8, source: DoryX86VectorOperand)
  /// CVTPD2PS (66 0F 5A): convert two packed doubles from XMM/m128 to two singles.
  case convertPackedDoubleToSingle(destination: UInt8, source: DoryX86VectorOperand)
  /// CVTDQ2PS (0F 5B): convert four signed dwords from XMM/m128 to four singles.
  case convertPackedDwordToSingle(destination: UInt8, source: DoryX86VectorOperand)
  /// POP SS (17): pop a selector using the current legacy stack width.
  case popSegment(DoryX86SegmentRegister, width: DoryX86OperandWidth)
  /// `MOVQ2DQ xmm, mm`: copy the source MMX payload into the low quadword of
  /// the XMM destination, clear its next quadword, and preserve upper YMM state.
  case moveMMXToVector(destination: UInt8, source: UInt8)
  /// `MOVDQ2Q mm, xmm`: copy the low quadword of the XMM source into the MMX
  /// destination. Normal MMX retirement effects are applied after the copy.
  case moveVectorToMMX(destination: UInt8, source: UInt8)
  /// `POPCNT r16/32/64, r/m16/32/64`: count set bits in the source operand.
  case populationCount(destination: DoryX86Operand, source: DoryX86Operand)
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
