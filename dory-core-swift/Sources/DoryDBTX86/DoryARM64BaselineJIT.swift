import DoryJITRuntimeC
import Foundation

public enum DoryJITExitCode: UInt32, Codable, Sendable, Hashable {
  case dispatch = 0
  case interpreter = 1
  case halt = 2
  case system = 3
  case portIO = 4
}

public enum DoryARM64CompilationTier: String, Codable, Sendable, Hashable {
  case baseline
  case optimizing
  case interpreterFallback
}

public enum DoryARM64JITOptimization: String, Codable, Sendable, Hashable {
  case baseline
  case optimizing
}

public struct DoryARM64CompiledBlock: Codable, Sendable, Hashable {
  public let guestStart: UInt64
  public let guestByteCount: UInt32
  public let guestInstructionCount: UInt32
  public let machineWords: [UInt32]
  public let tier: DoryARM64CompilationTier
  public let exitCode: DoryJITExitCode
  public let requiresMemoryCallbacks: Bool
  public let requiresRestartableMemoryReads: Bool
  /// A runtime address guard can return without retiring this block. Its temporary register
  /// context must be discarded, and it cannot participate in unchecked native batch replay.
  public let mayExitToInterpreter: Bool

  public init(
    guestStart: UInt64,
    guestByteCount: UInt32,
    guestInstructionCount: UInt32,
    machineWords: [UInt32],
    tier: DoryARM64CompilationTier,
    exitCode: DoryJITExitCode,
    requiresMemoryCallbacks: Bool = false,
    requiresRestartableMemoryReads: Bool = false,
    mayExitToInterpreter: Bool = false
  ) {
    self.guestStart = guestStart
    self.guestByteCount = guestByteCount
    self.guestInstructionCount = guestInstructionCount
    self.machineWords = machineWords
    self.tier = tier
    self.exitCode = exitCode
    self.requiresMemoryCallbacks = requiresMemoryCallbacks
    self.requiresRestartableMemoryReads = requiresRestartableMemoryReads
    self.mayExitToInterpreter = mayExitToInterpreter
  }

  public var machineBytes: [UInt8] {
    machineWords.flatMap { word in
      (0..<4).map { UInt8(truncatingIfNeeded: word >> UInt32($0 * 8)) }
    }
  }
}

/// Baseline ABI: x0 points to 16 UInt64 GPR slots followed by RIP and RFLAGS. Generated code
/// returns a DoryJITExitCode in w0. The layout is intentionally independent of Swift struct ABI.
public struct DoryARM64BaselineEmitter: Sendable {
  private static let ripOffset = 16 * 8
  private static let rflagsOffset = 17 * 8
  private static let fsBaseOffset = 18 * 8
  private static let gsBaseOffset = 19 * 8
  private static let tscOffset = 20 * 8
  private static let rspOffset = 4 * 8
  private static let pushedRFLAGSImageMask =
    ~(DoryX86RFLAGS.resume.rawValue | DoryX86RFLAGS.virtual8086.rawValue)
  private static let arithmeticFlagMask: UInt64 =
    DoryX86RFLAGS.carry.rawValue
    | DoryX86RFLAGS.parity.rawValue
    | DoryX86RFLAGS.auxiliaryCarry.rawValue
    | DoryX86RFLAGS.zero.rawValue
    | DoryX86RFLAGS.sign.rawValue
    | DoryX86RFLAGS.overflow.rawValue

  public init() {}

  public func compile(
    _ block: DoryIRBasicBlock,
    tier: DoryARM64CompilationTier = .baseline,
    executionMode: DoryX86ExecutionMode? = nil
  ) -> DoryARM64CompiledBlock {
    precondition(tier != .interpreterFallback)
    if containsFSOrGSMemoryAddress(block) {
      guard executionMode == .long64 else { return fallback(block) }
    }
    // A synchronization callback cannot be rolled back. Accept only the isolated shape
    // produced by the translator, including when callers supply hand-crafted IR.
    if block.statements.contains(where: { if case .memoryFence = $0 { true } else { false } }) {
      guard block.statements.count == 1, block.guestInstructionCount == 1,
        case .next = block.terminator
      else { return fallback(block) }
    }
    var words: [UInt32] = []
    let memoryCallbackCount =
      block.statements.reduce(0) { $0 + self.memoryCallbackCount($1) }
      + memoryCallbackCount(block.terminator)
    let usesMemory = memoryCallbackCount > 0
    let guardsTerminator = requiresRuntimeAddressGuard(block.terminator)
    let guardsStack = block.statements.contains {
      switch $0 { case .stackPush, .stackPushFlags, .stackPop: true; default: false }
    }
    let guardsInterpreterExit = block.statements.contains {
      if case .unsignedAccumulatorDivide = $0 { return true }
      return false
    }
    // Translated writes end a block. Also reject hand-crafted IR that would reach a new
    // address guard after a successful write, since register checkpoints cannot undo RAM/I/O.
    var wroteMemory = false
    for statement in block.statements {
      if wroteMemory {
        switch statement {
        case .stackPush, .stackPushFlags, .stackPop: return fallback(block)
        default: break
        }
      }
      wroteMemory = wroteMemory || writesMemory(statement)
    }
    if wroteMemory && guardsTerminator { return fallback(block) }
    if usesMemory { emitMemoryPrologue(into: &words) }
    for statement in block.statements {
      guard emit(statement, into: &words) else {
        return fallback(block)
      }
    }
    guard let exit = emit(block.terminator, usesMemory: usesMemory, into: &words) else {
      return fallback(block)
    }
    if usesMemory { emitMemoryEpilogue(into: &words) }
    words.append(encodeMoveWideZero32(register: 0, immediate: UInt16(exit.rawValue)))
    words.append(0xD65F_03C0)
    return .init(
      guestStart: block.guestStart,
      guestByteCount: block.guestByteCount,
      guestInstructionCount: block.guestInstructionCount,
      machineWords: words,
      tier: tier,
      exitCode: exit,
      requiresMemoryCallbacks: usesMemory,
      // RET and memory-indirect JMP can now decline after their read. Such reads must
      // be proven ordinary RAM, just like a read followed by a potentially failing write.
      requiresRestartableMemoryReads: memoryCallbackCount > 1 || (guardsTerminator && usesMemory),
      mayExitToInterpreter: guardsTerminator || guardsStack || guardsInterpreterExit
    )
  }

  private func requiresRuntimeAddressGuard(_ terminator: DoryIRTerminator) -> Bool {
    switch terminator {
    case .call, .indirectCall, .indirect, .returnFromCall: true
    case .conditional(_, let taken, let notTaken):
      !DoryX86ArchitecturalState.isCanonical(taken) || !DoryX86ArchitecturalState.isCanonical(notTaken)
    default: false
    }
  }

  private func containsFSOrGSMemoryAddress(_ block: DoryIRBasicBlock) -> Bool {
    func isFSOrGS(_ operand: DoryIROperand) -> Bool {
      guard case .memory(let address, _) = operand else { return false }
      return address.segment == "fs" || address.segment == "gs"
    }
    return block.statements.contains { statement in
      switch statement {
      case .copy(let destination, let source):
        return isFSOrGS(destination) || isFSOrGS(source)
      case .binary(_, let destination, let source, _):
        return isFSOrGS(destination) || isFSOrGS(source)
      case .unary(_, let operand), .shift(_, let operand, _), .byteSwap(let operand),
        .stackPush(let operand), .stackPop(let operand):
        return isFSOrGS(operand)
      case .conditionalMove(_, let destination, let source):
        return isFSOrGS(destination) || isFSOrGS(source)
      case .setCondition(_, let destination):
        return isFSOrGS(destination)
      case .bitTestMemoryImmediate(_, let base, _):
        return isFSOrGS(base)
      case .bitTestRegister:
        return false
      case .bitScan(_, let destination, let source), .extendMove(let destination, let source, _):
        return isFSOrGS(destination) || isFSOrGS(source)
      case .signedMultiply(let destination, let lhs, let rhs):
        return isFSOrGS(destination) || isFSOrGS(lhs) || isFSOrGS(rhs)
      case .unsignedAccumulatorMultiply(let source), .unsignedAccumulatorDivide(let source):
        return isFSOrGS(source)
      case .doubleShiftRightCL(let destination, let source),
        .doubleShiftRightImmediate(let destination, let source, _):
        return isFSOrGS(destination) || isFSOrGS(source)
      case .compareExchange(let destination, let source):
        return isFSOrGS(destination) || isFSOrGS(source)
      case .effectiveAddress:
        return false
      case .stackPushFlags, .clearInterruptFlag, .setDirectionFlag, .readTimestampCounter, .memoryFence, .helper:
        return false
      }
    }
  }

  private func writesMemory(_ statement: DoryIRStatement) -> Bool {
    switch statement {
    case .copy(.memory, _), .binary(_, .memory, _, true), .unary(_, .memory),
      .shift(_, .memory, _), .stackPush, .stackPushFlags, .compareExchange(.memory, _): true
    case .bitTestMemoryImmediate(let operation, .memory, _): operation != .test
    default: false
    }
  }

  private func fallback(_ block: DoryIRBasicBlock) -> DoryARM64CompiledBlock {
    var words: [UInt32] = []
    emitImmediate(block.guestStart, register: 9, into: &words)
    words.append(encodeStore64(register: 9, base: 0, byteOffset: Self.ripOffset))
    words.append(
      encodeMoveWideZero32(register: 0, immediate: UInt16(DoryJITExitCode.interpreter.rawValue)))
    words.append(0xD65F_03C0)
    return .init(
      guestStart: block.guestStart,
      guestByteCount: block.guestByteCount,
      guestInstructionCount: block.guestInstructionCount,
      machineWords: words,
      tier: .interpreterFallback,
      exitCode: .interpreter
    )
  }

  private func emit(_ statement: DoryIRStatement, into words: inout [UInt32]) -> Bool {
    switch statement {
    case .memoryFence:
      words.append(encodeLogical(.or, left: 31, right: 20, destination: 0))
      words.append(0xD63F_0000 | 24 << 5)  // blr x24 (memory owner's synchronize callback)
      // Use a full completion barrier for all fence kinds. ISB also prevents following
      // native instructions from executing ahead of LFENCE's completion boundary.
      words.append(0xD503_3F9F)  // dsb sy
      words.append(0xD503_3FDF)  // isb
      words.append(encodeLogical(.or, left: 31, right: 19, destination: 0))
      return true
    case .copy(let destination, let source):
      return emitCopy(destination: destination, source: source, into: &words)
    case .binary(let operation, let destination, let source, let writesDestination):
      return emitBinary(
        operation,
        destination: destination,
        source: source,
        writesDestination: writesDestination,
        into: &words
      )
    case .unary(let operation, let operand):
      return emitUnary(operation, operand: operand, into: &words)
    case .shift(let operation, let destination, let count):
      return emitShift(operation, destination: destination, count: count, into: &words)
    case .conditionalMove(let condition, let destination, let source):
      return emitConditionalMove(
        condition, destination: destination, source: source, into: &words)
    case .setCondition(let condition, let destination):
      return emitSetCondition(condition, destination: destination, into: &words)
    case .bitTestRegister(let operation, let base, let index):
      return emitBitTest(operation: operation, base: base, index: index, into: &words)
    case .bitTestMemoryImmediate(let operation, let base, let index):
      return emitBitTest(
        operation: operation, base: base, index: .immediate(UInt64(index), width: .i8), into: &words)
    case .bitScan(let reverse, let destination, let source):
      return emitBitScan(
        reverse: reverse,
        destination: destination,
        source: source,
        into: &words
      )
    case .byteSwap(let operand):
      return emitByteSwap(operand, into: &words)
    case .stackPush(let source):
      return emitStackPush(source: source, into: &words)
    case .stackPushFlags:
      return emitStackPushFlags(into: &words)
    case .stackPop(let destination):
      return emitStackPop(destination: destination, into: &words)
    case .clearInterruptFlag:
      return emitClearInterruptFlag(into: &words)
    case .setDirectionFlag(let enabled):
      return emitSetDirectionFlag(enabled: enabled, into: &words)
    case .readTimestampCounter:
      return emitReadTimestampCounter(into: &words)
    case .unsignedAccumulatorMultiply(let source):
      return emitUnsignedAccumulatorMultiply(source: source, into: &words)
    case .unsignedAccumulatorDivide(let source):
      return emitUnsignedAccumulatorDivide(source: source, into: &words)
    case .doubleShiftRightCL(let destination, let source):
      return emitDoubleShiftRight(destination: destination, source: source, into: &words)
    case .doubleShiftRightImmediate(let destination, let source, let count):
      return emitDoubleShiftRight(
        destination: destination, source: source, immediateCount: count, into: &words)
    case .compareExchange(let destination, let source):
      return emitCompareExchange(destination: destination, source: source, into: &words)
    case .signedMultiply(let destination, let lhs, let rhs):
      return emitSignedMultiply(destination: destination, lhs: lhs, rhs: rhs, into: &words)
    case .extendMove(let destination, let source, let signed):
      return emitExtendMove(
        destination: destination, source: source, signed: signed, into: &words)
    case .effectiveAddress(let destination, let address):
      return emitEffectiveAddress(destination: destination, address: address, into: &words)
    default:
      return false
    }
  }

  private func emitSetCondition(
    _ condition: DoryX86Condition,
    destination: DoryIROperand,
    into words: inout [UInt32]
  ) -> Bool {
    guard case .register(let target) = destination,
      isLowByteRegister(target),
      emitX86Condition(condition, into: 10, words: &words)
    else { return false }

    words.append(encodeLoad64(register: 9, base: 0, byteOffset: Int(target.index) * 8))
    emitImmediate(~UInt64(0xFF), register: 11, into: &words)
    words.append(encodeLogical(.and, left: 9, right: 11, destination: 9))
    words.append(encodeLogical(.or, left: 9, right: 10, destination: 9))
    words.append(encodeStore64(register: 9, base: 0, byteOffset: Int(target.index) * 8))
    return true
  }

  private func emitStackPush(
    source: DoryIROperand,
    into words: inout [UInt32]
  ) -> Bool {
    switch source {
    case .register(let register)
    where register.bank == "x86.gpr" && register.index < 16 && register.width == .i64:
      break
    case .immediate(_, width: .i64):
      break
    default:
      return false
    }
    guard load(source, matching: .i64, into: 10, words: &words) else { return false }

    // Read the source before changing the temporary RSP so `push rsp` stores the old value.
    return emitStackPushLoadedValue(register: 10, into: &words)
  }

  private func emitStackPushFlags(into words: inout [UInt32]) -> Bool {
    words.append(encodeLoad64(register: 10, base: 0, byteOffset: Self.rflagsOffset))
    emitImmediate(Self.pushedRFLAGSImageMask, register: 11, into: &words)
    words.append(encodeLogical(.and, left: 10, right: 11, destination: 10))
    emitImmediate(DoryX86RFLAGS.reservedOne.rawValue, register: 11, into: &words)
    words.append(encodeLogical(.or, left: 10, right: 11, destination: 10))
    return emitStackPushLoadedValue(register: 10, into: &words)
  }

  private func emitStackPushLoadedValue(
    register valueRegister: UInt32,
    into words: inout [UInt32]
  ) -> Bool {
    words.append(encodeLoad64(register: 9, base: 0, byteOffset: Self.rspOffset))
    emitImmediate(UInt64(bitPattern: -8), register: 11, into: &words)
    words.append(encodeAdd(is64Bit: true, left: 9, right: 11, destination: 12))
    emitCanonicalStackSpanGuard(addressRegister: 12, into: &words)
    words.append(encodeStore64(register: 12, base: 0, byteOffset: Self.rspOffset))
    emitMemoryWrite(addressRegister: 12, valueRegister: valueRegister, width: .i64, words: &words)
    return true
  }

  private func emitClearInterruptFlag(into words: inout [UInt32]) -> Bool {
    words.append(encodeLoad64(register: 9, base: 0, byteOffset: Self.rflagsOffset))
    emitImmediate(~DoryX86RFLAGS.interruptEnable.rawValue, register: 10, into: &words)
    words.append(encodeLogical(.and, left: 9, right: 10, destination: 9))
    emitImmediate(DoryX86RFLAGS.reservedOne.rawValue, register: 10, into: &words)
    words.append(encodeLogical(.or, left: 9, right: 10, destination: 9))
    words.append(encodeStore64(register: 9, base: 0, byteOffset: Self.rflagsOffset))
    return true
  }

  private func emitSetDirectionFlag(enabled: Bool, into words: inout [UInt32]) -> Bool {
    words.append(encodeLoad64(register: 9, base: 0, byteOffset: Self.rflagsOffset))
    if enabled {
      emitImmediate(DoryX86RFLAGS.direction.rawValue, register: 10, into: &words)
      words.append(encodeLogical(.or, left: 9, right: 10, destination: 9))
    } else {
      emitImmediate(~DoryX86RFLAGS.direction.rawValue, register: 10, into: &words)
      words.append(encodeLogical(.and, left: 9, right: 10, destination: 9))
    }
    emitImmediate(DoryX86RFLAGS.reservedOne.rawValue, register: 10, into: &words)
    words.append(encodeLogical(.or, left: 9, right: 10, destination: 9))
    words.append(encodeStore64(register: 9, base: 0, byteOffset: Self.rflagsOffset))
    return true
  }

  private func emitReadTimestampCounter(into words: inout [UInt32]) -> Bool {
    words.append(encodeLoad64(register: 9, base: 0, byteOffset: Self.tscOffset))
    words.append(encodeLogical(.or, left: 31, right: 9, shiftAmount: 32, logicalRightShift: true, destination: 10))
    words.append(encodeLogical(.or, is64Bit: false, left: 31, right: 9, destination: 9))
    words.append(encodeLogical(.or, is64Bit: false, left: 31, right: 10, destination: 10))
    words.append(encodeStore64(register: 9, base: 0, byteOffset: 0))
    words.append(encodeStore64(register: 10, base: 0, byteOffset: 2 * 8))
    return true
  }

  private func emitByteSwap(
    _ operand: DoryIROperand,
    into words: inout [UInt32]
  ) -> Bool {
    guard case .register(let register) = operand,
      register.bank == "x86.gpr", register.index < 16,
      register.width == .i32 || register.width == .i64,
      load(register, into: 9, words: &words)
    else { return false }
    words.append(
      encodeReverseBytes(
        is64Bit: register.width == .i64,
        source: 9,
        destination: 9
      )
    )
    words.append(encodeStore64(register: 9, base: 0, byteOffset: Int(register.index) * 8))
    return true
  }

  private func emitStackPop(
    destination: DoryIROperand,
    into words: inout [UInt32]
  ) -> Bool {
    guard case .register(let register) = destination,
      register.bank == "x86.gpr", register.index < 16, register.index != 4,
      register.width == .i64
    else { return false }

    words.append(encodeLoad64(register: 9, base: 0, byteOffset: Self.rspOffset))
    emitCanonicalStackSpanGuard(addressRegister: 9, into: &words)
    emitMemoryRead(addressRegister: 9, width: .i64, resultRegister: 10, words: &words)
    words.append(encodeLoad64(register: 9, base: 0, byteOffset: Self.rspOffset))
    emitImmediate(8, register: 11, into: &words)
    words.append(encodeAdd(is64Bit: true, left: 9, right: 11, destination: 9))
    words.append(encodeStore64(register: 9, base: 0, byteOffset: Self.rspOffset))
    words.append(encodeStore64(register: 10, base: 0, byteOffset: Int(register.index) * 8))
    return true
  }

  private func emitBitScan(
    reverse: Bool,
    destination: DoryIROperand,
    source: DoryIROperand,
    into words: inout [UInt32]
  ) -> Bool {
    guard case .register(let target) = destination,
      case .register(let origin) = source,
      target.bank == "x86.gpr", target.index < 16,
      target.width == .i32 || target.width == .i64,
      origin.bank == "x86.gpr", origin.index < 16, origin.width == target.width
    else { return false }

    let is64Bit = target.width == .i64
    words.append(is64Bit
      ? encodeLoad64(register: 9, base: 0, byteOffset: Int(origin.index) * 8)
      : encodeLoad32(register: 9, base: 0, byteOffset: Int(origin.index) * 8))
    words.append(encodeLoad64(register: 10, base: 0, byteOffset: Int(target.index) * 8))
    if reverse {
      words.append(encodeCountLeadingZeros(is64Bit: is64Bit, source: 9, destination: 11))
      emitImmediate(is64Bit ? 63 : 31, register: 12, into: &words)
      words.append(encodeLogical(.xor, is64Bit: is64Bit, 12, 11, 11))
    } else {
      words.append(encodeReverseBits(is64Bit: is64Bit, source: 9, destination: 11))
      words.append(encodeCountLeadingZeros(is64Bit: is64Bit, source: 11, destination: 11))
    }
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: is64Bit, 9, 31, 31))
    words.append(
      encodeConditionalSelect(
        destination: 11,
        trueRegister: 11,
        falseRegister: 10,
        condition: .notEqual
      ))
    words.append(encodeConditionalSet(register: 13, condition: .equal))

    words.append(encodeLoad64(register: 12, base: 0, byteOffset: Self.rflagsOffset))
    emitImmediate(~DoryX86RFLAGS.zero.rawValue, register: 15, into: &words)
    words.append(encodeLogical(.and, left: 12, right: 15, destination: 12))
    words.append(encodeLogical(.or, left: 12, right: 13, shiftAmount: 6, destination: 12))
    emitImmediate(DoryX86RFLAGS.reservedOne.rawValue, register: 15, into: &words)
    words.append(encodeLogical(.or, left: 12, right: 15, destination: 12))
    words.append(encodeStore64(register: 12, base: 0, byteOffset: Self.rflagsOffset))
    words.append(encodeStore64(register: 11, base: 0, byteOffset: Int(target.index) * 8))
    return true
  }


  private func emitBitTest(
    operation: DoryX86BitOperation,
    base: DoryIROperand,
    index: DoryIROperand,
    into words: inout [UInt32]
  ) -> Bool {
    let width: DoryIRIntegerWidth
    switch base {
    case .register(let register):
      guard register.bank == "x86.gpr", register.index < 16,
        register.width == .i32 || register.width == .i64,
        load(register, into: 9, words: &words)
      else { return false }
      width = register.width
    case .memory(let address, let memoryWidth):
      guard memoryWidth == .i32 || memoryWidth == .i64,
        case .immediate(_, .i8) = index,
        emitMemoryAddress(address, into: 12, words: &words)
      else { return false }
      emitMemoryRead(addressRegister: 12, width: memoryWidth, resultRegister: 9, words: &words)
      width = memoryWidth
    case .immediate:
      return false
    }
    let is64Bit = width == .i64
    let bitMask = UInt64(width.rawValue - 1)
    switch index {
    case .register(let indexRegister):
      guard indexRegister.bank == "x86.gpr", indexRegister.index < 16,
        indexRegister.width == width,
        load(indexRegister, into: 10, words: &words)
      else { return false }
      emitImmediate(bitMask, register: 11, into: &words)
      words.append(encodeLogical(.and, left: 10, right: 11, destination: 10))
      emitImmediate(1, register: 11, into: &words)
      words.append(
        encodeVariableShift(
          .left, is64Bit: is64Bit, value: 11, count: 10, destination: 11
        ))
    case .immediate(let rawIndex, .i8):
      emitImmediate(1 << (rawIndex & bitMask), register: 11, into: &words)
    default:
      return false
    }

    words.append(encodeLogical(.andSetFlags, is64Bit: is64Bit, 9, 11, 12))
    words.append(encodeConditionalSet(register: 13, condition: .notEqual))

    if operation != .test {
      switch operation {
      case .test:
        break
      case .set:
        words.append(encodeLogical(.or, is64Bit: is64Bit, 9, 11, 12))
      case .reset:
        emitImmediate(is64Bit ? UInt64.max : UInt64(UInt32.max), register: 12, into: &words)
        words.append(encodeLogical(.xor, is64Bit: is64Bit, 11, 12, 12))
        words.append(encodeLogical(.and, is64Bit: is64Bit, 9, 12, 12))
      case .complement:
        words.append(encodeLogical(.xor, is64Bit: is64Bit, 9, 11, 12))
      }
      if case .register(let register) = base {
        words.append(encodeStore64(register: 12, base: 0, byteOffset: Int(register.index) * 8))
      }
    }

    words.append(encodeLoad64(register: 14, base: 0, byteOffset: Self.rflagsOffset))
    emitImmediate(~DoryX86RFLAGS.carry.rawValue, register: 15, into: &words)
    words.append(encodeLogical(.and, left: 14, right: 15, destination: 14))
    words.append(encodeLogical(.or, left: 14, right: 13, destination: 14))
    emitImmediate(DoryX86RFLAGS.reservedOne.rawValue, register: 15, into: &words)
    words.append(encodeLogical(.or, left: 14, right: 15, destination: 14))
    words.append(encodeStore64(register: 14, base: 0, byteOffset: Self.rflagsOffset))
    if operation != .test, case .memory(let address, _) = base {
      // Publish CF before the host callback clobbers caller-saved registers. The executor's
      // checkpoint restores architectural state if the restartable RMW faults.
      guard emitMemoryAddress(address, into: 9, words: &words) else { return false }
      emitMemoryWrite(addressRegister: 9, valueRegister: 12, width: width, words: &words)
    }
    return true
  }

  private func emitConditionalMove(
    _ condition: DoryX86Condition,
    destination: DoryIROperand,
    source: DoryIROperand,
    into words: inout [UInt32]
  ) -> Bool {
    guard case .register(let target) = destination,
      case .register(let origin) = source,
      target.bank == "x86.gpr", target.index < 16,
      origin.bank == "x86.gpr", origin.index < 16,
      target.width == origin.width,
      target.width == .i32 || target.width == .i64,
      emitX86Condition(condition, into: 10, words: &words)
    else { return false }

    words.append(
      target.width == .i64
        ? encodeLoad64(register: 11, base: 0, byteOffset: Int(origin.index) * 8)
        : encodeLoad32(register: 11, base: 0, byteOffset: Int(origin.index) * 8)
    )
    words.append(
      target.width == .i64
        ? encodeLoad64(register: 12, base: 0, byteOffset: Int(target.index) * 8)
        : encodeLoad32(register: 12, base: 0, byteOffset: Int(target.index) * 8)
    )
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: true, 10, 31, 31))
    words.append(
      encodeConditionalSelect(
        destination: 9,
        trueRegister: 11,
        falseRegister: 12,
        condition: .notEqual
      ))
    words.append(encodeStore64(register: 9, base: 0, byteOffset: Int(target.index) * 8))
    return true
  }

  private func emitCopy(
    destination: DoryIROperand,
    source: DoryIROperand,
    into words: inout [UInt32]
  ) -> Bool {
    switch destination {
    case .register(let target) where isLowByteRegister(target):
      switch source {
      case .register, .immediate:
        guard loadLowByteOperand(source, into: 10, words: &words) else { return false }
      case .memory(let address, width: .i8):
        guard emitMemoryAddress(address, into: 9, words: &words) else { return false }
        emitMemoryRead(addressRegister: 9, width: .i8, resultRegister: 10, words: &words)
      default:
        return false
      }
      emitImmediate(0xFF, register: 11, into: &words)
      words.append(encodeLogical(.and, left: 10, right: 11, destination: 10))
      words.append(encodeLoad64(register: 9, base: 0, byteOffset: Int(target.index) * 8))
      emitImmediate(~UInt64(0xFF), register: 11, into: &words)
      words.append(encodeLogical(.and, left: 9, right: 11, destination: 9))
      words.append(encodeLogical(.or, left: 9, right: 10, destination: 9))
      words.append(encodeStore64(register: 9, base: 0, byteOffset: Int(target.index) * 8))
      return true
    case .register(let target)
    where target.bank == "x86.gpr" && target.index < 16
      && (target.width == .i32 || target.width == .i64):
      switch source {
      case .register(let sourceRegister)
      where sourceRegister.bank == "x86.gpr"
        && sourceRegister.index < 16
        && sourceRegister.width == target.width:
        let sourceOffset = Int(sourceRegister.index) * 8
        words.append(
          target.width == .i64
            ? encodeLoad64(register: 9, base: 0, byteOffset: sourceOffset)
            : encodeLoad32(register: 9, base: 0, byteOffset: sourceOffset)
        )
      case .immediate(let value, let width) where width == target.width:
        emitImmediate(
          target.width == .i32 ? value & 0xffff_ffff : value, register: 9, into: &words)
      case .memory(let address, let width) where width == target.width:
        guard emitMemoryAddress(address, into: 9, words: &words) else { return false }
        emitMemoryRead(addressRegister: 9, width: width, resultRegister: 9, words: &words)
      default:
        return false
      }
      words.append(
        encodeStore64(register: 9, base: 0, byteOffset: Int(target.index) * 8)
      )
      return true
    case .memory(let address, let width)
    where width == .i8 || width == .i16 || width == .i32 || width == .i64:
      guard emitMemoryAddress(address, into: 9, words: &words) else { return false }
      if width == .i8 || width == .i16 {
        switch source {
        case .register(let register)
        where register.bank == "x86.gpr" && register.index < 16 && register.width == width:
          words.append(
            encodeLoad64(register: 10, base: 0, byteOffset: Int(register.index) * 8))
        case .immediate(let value, let immediateWidth) where immediateWidth == width:
          emitImmediate(value & (width == .i8 ? 0xFF : 0xFFFF), register: 10, into: &words)
        default:
          return false
        }
        emitImmediate(width == .i8 ? 0xFF : 0xFFFF, register: 11, into: &words)
        words.append(encodeLogical(.and, left: 10, right: 11, destination: 10))
      } else {
        guard load(source, matching: width, into: 10, words: &words) else { return false }
      }
      emitMemoryWrite(addressRegister: 9, valueRegister: 10, width: width, words: &words)
      return true
    default:
      return false
    }
  }

  private func memoryCallbackCount(_ statement: DoryIRStatement) -> Int {
    switch statement {
    case .copy(let destination, let source):
      if case .memory = destination { return 1 }
      if case .memory = source { return 1 }
      return 0
    case .binary(_, let destination, let source, let writesDestination):
      if case .memory = destination { return writesDestination ? 2 : 1 }
      if case .memory = source { return 1 }
      return 0
    case .unary(let operation, let operand):
      _ = operation
      if case .memory = operand { return 2 }
      return 0
    case .shift(_, let destination, _):
      if case .memory = destination { return 2 }
      return 0
    case .bitTestMemoryImmediate(let operation, _, _):
      return operation == .test ? 1 : 2
    case .conditionalMove, .setCondition, .bitTestRegister:
      return 0
    case .bitScan(_, let destination, let source):
      if case .memory = destination { return 1 }
      if case .memory = source { return 1 }
      return 0
    case .stackPush, .stackPushFlags, .stackPop:
      return 1
    case .byteSwap:
      return 0
    case .signedMultiply(let destination, let lhs, let rhs):
      if case .memory = destination { return 1 }
      if case .memory = lhs { return 1 }
      if case .memory = rhs { return 1 }
      return 0
    case .unsignedAccumulatorMultiply(let source), .unsignedAccumulatorDivide(let source):
      if case .memory = source { return 1 }
      return 0
    case .doubleShiftRightCL(let destination, let source),
        .doubleShiftRightImmediate(let destination, let source, _):
      if case .memory = destination { return 1 }
      if case .memory = source { return 1 }
      return 0
    case .extendMove(_, let source, _):
      if case .memory = source { return 1 }
      return 0
    case .compareExchange, .memoryFence:
      return 1
    case .effectiveAddress, .clearInterruptFlag, .setDirectionFlag, .readTimestampCounter, .helper:
      return 0
    }
  }

  private func memoryCallbackCount(_ terminator: DoryIRTerminator) -> Int {
    switch terminator {
    case .call, .returnFromCall:
      1
    case .indirectCall(let target, _):
      if case .memory = target { 2 } else { 1 }
    case .indirect(let target):
      if case .memory = target { 1 } else { 0 }
    case .next, .branch, .conditional, .exit:
      0
    }
  }

  private func emitSignedMultiply(
    destination: DoryIROperand,
    lhs: DoryIROperand,
    rhs: DoryIROperand,
    into words: inout [UInt32]
  ) -> Bool {
    guard case .register(let target) = destination,
      target.bank == "x86.gpr", target.index < 16,
      target.width == .i32 || target.width == .i64,
      case .register(let left) = lhs, left.width == target.width
    else { return false }
    switch rhs {
    case .register(let right)
    where right.bank == "x86.gpr" && right.index < 16 && right.width == target.width:
      break
    case .immediate(_, let width) where width == target.width:
      break
    default:
      return false
    }
    guard load(left, into: 9, words: &words),
      load(rhs, matching: target.width, into: 10, words: &words)
    else { return false }

    let is64Bit = target.width == .i64
    if is64Bit {
      words.append(encodeMultiply64(left: 9, right: 10, destination: 11))
      words.append(encodeSignedMultiplyHigh64(left: 9, right: 10, destination: 12))
      emitImmediate(63, register: 13, into: &words)
      words.append(
        encodeVariableShift(
          .arithmeticRight,
          is64Bit: true,
          value: 11,
          count: 13,
          destination: 13
        ))
    } else {
      words.append(encodeSignedMultiplyLong32(left: 9, right: 10, destination: 11))
      words.append(encodeSignExtend32To64(source: 11, destination: 12))
    }
    words.append(
      encodeAddSubtractSetFlags(
        add: false,
        is64Bit: true,
        is64Bit ? 12 : 11,
        is64Bit ? 13 : 12,
        31
      ))
    words.append(encodeConditionalSet(register: 13, condition: .notEqual))
    words.append(encodeLoad64(register: 14, base: 0, byteOffset: Self.rflagsOffset))
    let overflowMask = DoryX86RFLAGS.carry.rawValue | DoryX86RFLAGS.overflow.rawValue
    emitImmediate(~overflowMask, register: 15, into: &words)
    words.append(encodeLogical(.and, left: 14, right: 15, destination: 14))
    words.append(encodeLogical(.or, left: 14, right: 13, destination: 14))
    words.append(encodeLogical(.or, left: 14, right: 13, shiftAmount: 11, destination: 14))
    words.append(encodeStore64(register: 14, base: 0, byteOffset: Self.rflagsOffset))
    if is64Bit {
      words.append(encodeStore64(register: 11, base: 0, byteOffset: Int(target.index) * 8))
    } else {
      words.append(encodeLogical(.or, is64Bit: false, 31, 11, 12))
      words.append(encodeStore64(register: 12, base: 0, byteOffset: Int(target.index) * 8))
    }
    return true
  }

  private func emitUnsignedAccumulatorMultiply(
    source: DoryIROperand,
    into words: inout [UInt32]
  ) -> Bool {
    guard case .register(let sourceRegister) = source,
      sourceRegister.bank == "x86.gpr", sourceRegister.index < 16, sourceRegister.width == .i64
    else { return false }
    words.append(encodeLoad64(register: 9, base: 0, byteOffset: 0))
    words.append(encodeLoad64(register: 10, base: 0, byteOffset: Int(sourceRegister.index) * 8))
    words.append(encodeMultiply64(left: 9, right: 10, destination: 11))
    words.append(encodeUnsignedMultiplyHigh64(left: 9, right: 10, destination: 12))
    words.append(encodeStore64(register: 11, base: 0, byteOffset: 0))
    words.append(encodeStore64(register: 12, base: 0, byteOffset: 16))

    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: true, 12, 31, 31))
    words.append(encodeConditionalSet(register: 13, condition: .notEqual))
    words.append(encodeLoad64(register: 14, base: 0, byteOffset: Self.rflagsOffset))
    let overflowMask = DoryX86RFLAGS.carry.rawValue | DoryX86RFLAGS.overflow.rawValue
    emitImmediate(~overflowMask, register: 15, into: &words)
    words.append(encodeLogical(.and, left: 14, right: 15, destination: 14))
    words.append(encodeLogical(.or, left: 14, right: 13, destination: 14))
    words.append(encodeLogical(.or, left: 14, right: 13, shiftAmount: 11, destination: 14))
    emitImmediate(DoryX86RFLAGS.reservedOne.rawValue, register: 15, into: &words)
    words.append(encodeLogical(.or, left: 14, right: 15, destination: 14))
    words.append(encodeStore64(register: 14, base: 0, byteOffset: Self.rflagsOffset))
    return true
  }

  private func emitUnsignedAccumulatorDivide(
    source: DoryIROperand,
    into words: inout [UInt32]
  ) -> Bool {
    guard case .register(let sourceRegister) = source,
      sourceRegister.bank == "x86.gpr", sourceRegister.index < 16,
      sourceRegister.width == .i32 || sourceRegister.width == .i64
    else { return false }

    let is64Bit = sourceRegister.width == .i64
    words.append(
      is64Bit
        ? encodeLoad64(register: 10, base: 0, byteOffset: Int(sourceRegister.index) * 8)
        : encodeLoad32(register: 10, base: 0, byteOffset: Int(sourceRegister.index) * 8)
    )
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: true, 10, 31, 31))
    emitInterpreterUnless(condition: .notEqual, usesMemory: false, into: &words)

    words.append(
      is64Bit
        ? encodeLoad64(register: 11, base: 0, byteOffset: 16)
        : encodeLoad32(register: 11, base: 0, byteOffset: 16)
    )
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: true, 11, 31, 31))
    emitInterpreterUnless(condition: .equal, usesMemory: false, into: &words)

    words.append(
      is64Bit
        ? encodeLoad64(register: 9, base: 0, byteOffset: 0)
        : encodeLoad32(register: 9, base: 0, byteOffset: 0)
    )
    words.append(encodeUnsignedDivide(is64Bit: is64Bit, dividend: 9, divisor: 10, quotient: 12))
    words.append(
      encodeMultiplySubtract(
        is64Bit: is64Bit,
        left: 12,
        right: 10,
        minuend: 9,
        destination: 13
      ))
    words.append(encodeStore64(register: 12, base: 0, byteOffset: 0))
    words.append(encodeStore64(register: 13, base: 0, byteOffset: 16))
    return true
  }

  private func emitDoubleShiftRight(
    destination: DoryIROperand,
    source: DoryIROperand,
    immediateCount: UInt8? = nil,
    into words: inout [UInt32]
  ) -> Bool {
    guard case .register(let target) = destination,
      target.bank == "x86.gpr", target.index < 16, target.width == .i64,
      case .register(let sourceRegister) = source,
      sourceRegister.bank == "x86.gpr", sourceRegister.index < 16, sourceRegister.width == .i64
    else { return false }

    words.append(encodeLoad64(register: 9, base: 0, byteOffset: Int(target.index) * 8))
    words.append(encodeLoad64(register: 10, base: 0, byteOffset: Int(sourceRegister.index) * 8))
    if let immediateCount {
      emitImmediate(UInt64(immediateCount), register: 11, into: &words)
    } else {
      words.append(encodeLoad64(register: 11, base: 0, byteOffset: 8))
    }
    emitImmediate(0x3f, register: 15, into: &words)
    words.append(encodeLogical(.and, left: 11, right: 15, destination: 11))
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: true, 11, 31, 31))
    let zeroCountBranch = words.count
    words.append(0)

    words.append(
      encodeVariableShift(
        .logicalRight,
        is64Bit: true,
        value: 9,
        count: 11,
        destination: 12
      ))
    emitImmediate(64, register: 16, into: &words)
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: true, 16, 11, 16))
    words.append(
      encodeVariableShift(
        .left,
        is64Bit: true,
        value: 10,
        count: 16,
        destination: 16
      ))
    words.append(encodeLogical(.or, left: 12, right: 16, destination: 12))

    emitImmediate(1, register: 15, into: &words)
    emitImmediate(1, register: 16, into: &words)
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: true, 11, 16, 16))
    words.append(
      encodeVariableShift(
        .logicalRight,
        is64Bit: true,
        value: 9,
        count: 16,
        destination: 13
      ))
    words.append(encodeLogical(.and, left: 13, right: 15, destination: 13))

    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: true, 12, 31, 31))
    words.append(encodeConditionalSet(register: 16, condition: .equal))
    words.append(encodeLogical(.or, left: 13, right: 16, shiftAmount: 6, destination: 13))
    words.append(
      encodeLogical(
        .or,
        left: 31,
        right: 12,
        shiftAmount: 63,
        logicalRightShift: true,
        destination: 16
      ))
    words.append(encodeLogical(.and, left: 16, right: 15, destination: 16))
    words.append(encodeLogical(.or, left: 13, right: 16, shiftAmount: 7, destination: 13))

    words.append(
      encodeLogical(
        .xor,
        left: 12,
        right: 12,
        shiftAmount: 4,
        logicalRightShift: true,
        destination: 16
      ))
    words.append(
      encodeLogical(
        .xor, left: 16, right: 16, shiftAmount: 2, logicalRightShift: true, destination: 16
      ))
    words.append(
      encodeLogical(
        .xor, left: 16, right: 16, shiftAmount: 1, logicalRightShift: true, destination: 16
      ))
    words.append(encodeLogical(.and, left: 16, right: 15, destination: 16))
    words.append(encodeLogical(.xor, left: 16, right: 15, destination: 16))
    words.append(encodeLogical(.or, left: 13, right: 16, shiftAmount: 2, destination: 13))

    words.append(encodeLoad64(register: 14, base: 0, byteOffset: Self.rflagsOffset))
    let resultFlagMask =
      DoryX86RFLAGS.carry.rawValue
      | DoryX86RFLAGS.parity.rawValue
      | DoryX86RFLAGS.auxiliaryCarry.rawValue
      | DoryX86RFLAGS.zero.rawValue
      | DoryX86RFLAGS.sign.rawValue
    emitImmediate(~resultFlagMask, register: 15, into: &words)
    words.append(encodeLogical(.and, left: 14, right: 15, destination: 14))
    words.append(encodeLogical(.or, left: 14, right: 13, destination: 14))

    emitImmediate(1, register: 15, into: &words)
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: true, 11, 15, 31))
    let nonUnitCountBranch = words.count
    words.append(0)
    words.append(
      encodeLogical(
        .or,
        left: 31,
        right: 9,
        shiftAmount: 63,
        logicalRightShift: true,
        destination: 16
      ))
    words.append(
      encodeLogical(
        .or,
        left: 31,
        right: 12,
        shiftAmount: 63,
        logicalRightShift: true,
        destination: 15
      ))
    words.append(encodeLogical(.xor, left: 16, right: 15, destination: 16))
    emitImmediate(1, register: 15, into: &words)
    words.append(encodeLogical(.and, left: 16, right: 15, destination: 16))
    emitImmediate(~DoryX86RFLAGS.overflow.rawValue, register: 15, into: &words)
    words.append(encodeLogical(.and, left: 14, right: 15, destination: 14))
    words.append(encodeLogical(.or, left: 14, right: 16, shiftAmount: 11, destination: 14))
    words[nonUnitCountBranch] = encodeConditionalBranch(
      condition: .notEqual,
      wordOffset: words.count - nonUnitCountBranch
    )

    emitImmediate(DoryX86RFLAGS.reservedOne.rawValue, register: 15, into: &words)
    words.append(encodeLogical(.or, left: 14, right: 15, destination: 14))
    words.append(encodeStore64(register: 14, base: 0, byteOffset: Self.rflagsOffset))
    words.append(encodeStore64(register: 12, base: 0, byteOffset: Int(target.index) * 8))
    words[zeroCountBranch] = encodeConditionalBranch(
      condition: .equal,
      wordOffset: words.count - zeroCountBranch
    )
    return true
  }

  private func emitExtendMove(
    destination: DoryIROperand,
    source: DoryIROperand,
    signed: Bool,
    into words: inout [UInt32]
  ) -> Bool {
    guard case .register(let target) = destination,
      target.bank == "x86.gpr", target.index < 16,
      target.width == .i32 || target.width == .i64
    else { return false }
    let sourceWidth: DoryIRIntegerWidth
    switch source {
    case .register(let register)
    where register.bank == "x86.gpr" && register.index < 16
      && (register.width == .i8 || register.width == .i16
        || (signed && register.width == .i32 && target.width == .i64)):
      sourceWidth = register.width
      words.append(encodeLoad64(register: 9, base: 0, byteOffset: Int(register.index) * 8))
    case .memory(let address, let width) where width == .i8 || width == .i16
      || (signed && width == .i32 && target.width == .i64):
      guard emitMemoryAddress(address, into: 12, words: &words) else { return false }
      sourceWidth = width
      emitMemoryRead(addressRegister: 12, width: width, resultRegister: 9, words: &words)
    default:
      return false
    }
    if signed {
      // SBFM with a W destination also clears the upper half of the x86 register.
      let opcode: UInt32 = target.width == .i64 ? 0x9340_0000 : 0x1300_0000
      let signBit = UInt32(sourceWidth.rawValue) - 1
      words.append(opcode | signBit << 10 | 9 << 5 | 9)
    } else {
      emitImmediate(sourceWidth == .i8 ? 0xFF : 0xFFFF, register: 10, into: &words)
      words.append(encodeLogical(.and, left: 9, right: 10, destination: 9))
    }
    words.append(encodeStore64(register: 9, base: 0, byteOffset: Int(target.index) * 8))
    return true
  }

  private func emitShift(
    _ operation: DoryIRShiftOperation,
    destination: DoryIROperand,
    count countSource: DoryIRShiftCount,
    into words: inout [UInt32]
  ) -> Bool {
    guard case .register(let target) = destination,
      target.bank == "x86.gpr", target.index < 16,
      target.width == .i32 || target.width == .i64,
      load(target, into: 9, words: &words)
    else { return false }
    let is64Bit = target.width == .i64
    let bitCount: UInt32 = is64Bit ? 64 : 32
    if operation == .rotateLeft {
      guard is64Bit else { return false }
      guard case .immediate(let rawCount) = countSource else { return false }
      let count = UInt32(rawCount) & 0x3f
      guard count != 0 else { return true }
      words.append(
        encodeRotateRightImmediate64(
          value: 9,
          amount: bitCount - count,
          destination: 11
        ))
      emitRotateFlags(
        bitCount: bitCount,
        count: count,
        result: 11,
        words: &words
      )
      words.append(encodeStore64(register: 11, base: 0, byteOffset: Int(target.index) * 8))
      return true
    }
    switch countSource {
    case .immediate(let rawCount):
      let count = UInt32(rawCount) & (is64Bit ? 0x3f : 0x1f)
      guard count != 0 else { return true }
      emitImmediate(UInt64(count), register: 10, into: &words)
      words.append(
        encodeVariableShift(
          operation,
          is64Bit: is64Bit,
          value: 9,
          count: 10,
          destination: 11
        ))
      emitShiftFlags(
        operation,
        is64Bit: is64Bit,
        bitCount: bitCount,
        count: count,
        original: 9,
        result: 11,
        words: &words
      )
      words.append(encodeStore64(register: 11, base: 0, byteOffset: Int(target.index) * 8))
    case .cl:
      emitCLShift(
        operation,
        is64Bit: is64Bit,
        bitCount: bitCount,
        target: target,
        words: &words
      )
    }
    return true
  }

  private func emitRotateFlags(
    bitCount: UInt32,
    count: UInt32,
    result: UInt32,
    words: inout [UInt32]
  ) {
    words.append(
      encodeLogical(
        .or,
        is64Bit: true,
        left: 31,
        right: result,
        shiftAmount: 0,
        logicalRightShift: true,
        destination: 13
      ))
    emitImmediate(1, register: 15, into: &words)
    words.append(encodeLogical(.and, left: 13, right: 15, destination: 13))

    words.append(encodeLoad64(register: 12, base: 0, byteOffset: Self.rflagsOffset))
    var replacedFlags = DoryX86RFLAGS.carry.rawValue
    if count == 1 {
      replacedFlags |= DoryX86RFLAGS.overflow.rawValue
      words.append(
        encodeLogical(
          .or,
          is64Bit: true,
          left: 31,
          right: result,
          shiftAmount: bitCount - 1,
          logicalRightShift: true,
          destination: 14
        ))
      words.append(encodeLogical(.xor, left: 14, right: 13, destination: 14))
      words.append(encodeLogical(.and, left: 14, right: 15, destination: 14))
      words.append(encodeLogical(.or, left: 13, right: 14, shiftAmount: 11, destination: 13))
    }
    emitImmediate(~replacedFlags, register: 15, into: &words)
    words.append(encodeLogical(.and, left: 12, right: 15, destination: 12))
    words.append(encodeLogical(.or, left: 12, right: 13, destination: 12))
    emitImmediate(DoryX86RFLAGS.reservedOne.rawValue, register: 15, into: &words)
    words.append(encodeLogical(.or, left: 12, right: 15, destination: 12))
    words.append(encodeStore64(register: 12, base: 0, byteOffset: Self.rflagsOffset))
  }

  private func emitCLShift(
    _ operation: DoryIRShiftOperation,
    is64Bit: Bool,
    bitCount: UInt32,
    target: DoryIRRegister,
    words: inout [UInt32]
  ) {
    // A 32-bit destination write zero-extends its architectural register even when the masked
    // count is zero. Commit that width effect before the flag-preserving zero-count branch.
    if !is64Bit {
      words.append(encodeStore64(register: 9, base: 0, byteOffset: Int(target.index) * 8))
    }
    words.append(encodeLoad64(register: 10, base: 0, byteOffset: 8))
    emitImmediate(is64Bit ? 0x3f : 0x1f, register: 15, into: &words)
    words.append(encodeLogical(.and, left: 10, right: 15, destination: 10))
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: true, 10, 31, 31))
    let zeroCountBranch = words.count
    words.append(0)

    words.append(
      encodeVariableShift(
        operation,
        is64Bit: is64Bit,
        value: 9,
        count: 10,
        destination: 11
      ))

    if operation == .left {
      emitImmediate(UInt64(bitCount), register: 12, into: &words)
      words.append(encodeAddSubtractSetFlags(add: false, is64Bit: true, 12, 10, 12))
    } else {
      emitImmediate(1, register: 12, into: &words)
      words.append(encodeAddSubtractSetFlags(add: false, is64Bit: true, 10, 12, 12))
    }
    words.append(
      encodeVariableShift(
        .logicalRight,
        is64Bit: is64Bit,
        value: 9,
        count: 12,
        destination: 13
      ))
    emitImmediate(1, register: 15, into: &words)
    words.append(encodeLogical(.and, left: 13, right: 15, destination: 13))

    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: is64Bit, 11, 31, 31))
    words.append(encodeConditionalSet(register: 14, condition: .equal))
    words.append(encodeLogical(.or, left: 13, right: 14, shiftAmount: 6, destination: 13))
    words.append(
      encodeLogical(
        .or,
        is64Bit: is64Bit,
        left: 31,
        right: 11,
        shiftAmount: bitCount - 1,
        logicalRightShift: true,
        destination: 14
      ))
    words.append(encodeLogical(.and, left: 14, right: 15, destination: 14))
    words.append(encodeLogical(.or, left: 13, right: 14, shiftAmount: 7, destination: 13))

    words.append(
      encodeLogical(
        .xor,
        is64Bit: is64Bit,
        left: 11,
        right: 11,
        shiftAmount: 4,
        logicalRightShift: true,
        destination: 14
      ))
    words.append(
      encodeLogical(
        .xor, left: 14, right: 14, shiftAmount: 2, logicalRightShift: true, destination: 14
      ))
    words.append(
      encodeLogical(
        .xor, left: 14, right: 14, shiftAmount: 1, logicalRightShift: true, destination: 14
      ))
    words.append(encodeLogical(.and, left: 14, right: 15, destination: 14))
    words.append(encodeLogical(.xor, left: 14, right: 15, destination: 14))
    words.append(encodeLogical(.or, left: 13, right: 14, shiftAmount: 2, destination: 13))

    words.append(encodeLoad64(register: 12, base: 0, byteOffset: Self.rflagsOffset))
    let resultFlagMask =
      DoryX86RFLAGS.carry.rawValue
      | DoryX86RFLAGS.parity.rawValue
      | DoryX86RFLAGS.auxiliaryCarry.rawValue
      | DoryX86RFLAGS.zero.rawValue
      | DoryX86RFLAGS.sign.rawValue
    emitImmediate(~resultFlagMask, register: 15, into: &words)
    words.append(encodeLogical(.and, left: 12, right: 15, destination: 12))
    words.append(encodeLogical(.or, left: 12, right: 13, destination: 12))

    emitImmediate(1, register: 15, into: &words)
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: true, 10, 15, 31))
    let nonUnitCountBranch = words.count
    words.append(0)
    switch operation {
    case .left:
      words.append(
        encodeLogical(
          .or,
          is64Bit: is64Bit,
          left: 31,
          right: 11,
          shiftAmount: bitCount - 1,
          logicalRightShift: true,
          destination: 14
        ))
      words.append(encodeLogical(.xor, left: 14, right: 13, destination: 14))
      words.append(encodeLogical(.and, left: 14, right: 15, destination: 14))
    case .logicalRight:
      words.append(
        encodeLogical(
          .or,
          is64Bit: is64Bit,
          left: 31,
          right: 9,
          shiftAmount: bitCount - 1,
          logicalRightShift: true,
          destination: 14
        ))
      words.append(encodeLogical(.and, left: 14, right: 15, destination: 14))
    case .arithmeticRight:
      emitImmediate(0, register: 14, into: &words)
    case .rotateLeft:
      preconditionFailure("rotate-left uses dedicated flag lowering")
    }
    emitImmediate(~DoryX86RFLAGS.overflow.rawValue, register: 15, into: &words)
    words.append(encodeLogical(.and, left: 12, right: 15, destination: 12))
    words.append(encodeLogical(.or, left: 12, right: 14, shiftAmount: 11, destination: 12))
    words[nonUnitCountBranch] = encodeConditionalBranch(
      condition: .notEqual,
      wordOffset: words.count - nonUnitCountBranch
    )

    emitImmediate(DoryX86RFLAGS.reservedOne.rawValue, register: 15, into: &words)
    words.append(encodeLogical(.or, left: 12, right: 15, destination: 12))
    words.append(encodeStore64(register: 12, base: 0, byteOffset: Self.rflagsOffset))
    words.append(encodeStore64(register: 11, base: 0, byteOffset: Int(target.index) * 8))
    words[zeroCountBranch] = encodeConditionalBranch(
      condition: .equal,
      wordOffset: words.count - zeroCountBranch
    )
  }

  private func emitShiftFlags(
    _ operation: DoryIRShiftOperation,
    is64Bit: Bool,
    bitCount: UInt32,
    count: UInt32,
    original: UInt32,
    result: UInt32,
    words: inout [UInt32]
  ) {
    let carryShift = operation == .left ? bitCount - count : count - 1
    words.append(
      encodeLogical(
        .or,
        is64Bit: is64Bit,
        left: 31,
        right: original,
        shiftAmount: carryShift,
        logicalRightShift: true,
        destination: 13
      ))
    emitImmediate(1, register: 15, into: &words)
    words.append(encodeLogical(.and, left: 13, right: 15, destination: 13))

    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: is64Bit, result, 31, 31))
    words.append(encodeConditionalSet(register: 14, condition: .equal))
    words.append(encodeLogical(.or, left: 13, right: 14, shiftAmount: 6, destination: 13))
    words.append(
      encodeLogical(
        .or,
        is64Bit: is64Bit,
        left: 31,
        right: result,
        shiftAmount: bitCount - 1,
        logicalRightShift: true,
        destination: 14
      ))
    words.append(encodeLogical(.and, left: 14, right: 15, destination: 14))
    words.append(encodeLogical(.or, left: 13, right: 14, shiftAmount: 7, destination: 13))

    words.append(
      encodeLogical(
        .xor,
        is64Bit: is64Bit,
        left: result,
        right: result,
        shiftAmount: 4,
        logicalRightShift: true,
        destination: 14
      ))
    words.append(
      encodeLogical(
        .xor, left: 14, right: 14, shiftAmount: 2, logicalRightShift: true, destination: 14))
    words.append(
      encodeLogical(
        .xor, left: 14, right: 14, shiftAmount: 1, logicalRightShift: true, destination: 14))
    words.append(encodeLogical(.and, left: 14, right: 15, destination: 14))
    words.append(encodeLogical(.xor, left: 14, right: 15, destination: 14))
    words.append(encodeLogical(.or, left: 13, right: 14, shiftAmount: 2, destination: 13))

    if count == 1 {
      switch operation {
      case .left:
        words.append(
          encodeLogical(
            .or,
            is64Bit: is64Bit,
            left: 31,
            right: result,
            shiftAmount: bitCount - 1,
            logicalRightShift: true,
            destination: 14
          ))
        words.append(encodeLogical(.xor, left: 14, right: 13, destination: 14))
        words.append(encodeLogical(.and, left: 14, right: 15, destination: 14))
      case .logicalRight:
        words.append(
          encodeLogical(
            .or,
            is64Bit: is64Bit,
            left: 31,
            right: original,
            shiftAmount: bitCount - 1,
            logicalRightShift: true,
            destination: 14
          ))
      case .arithmeticRight:
        emitImmediate(0, register: 14, into: &words)
      case .rotateLeft:
        preconditionFailure("rotate-left uses dedicated flag lowering")
      }
      words.append(encodeLogical(.or, left: 13, right: 14, shiftAmount: 11, destination: 13))
    }

    words.append(encodeLoad64(register: 12, base: 0, byteOffset: Self.rflagsOffset))
    var mask =
      DoryX86RFLAGS.carry.rawValue
      | DoryX86RFLAGS.parity.rawValue
      | DoryX86RFLAGS.auxiliaryCarry.rawValue
      | DoryX86RFLAGS.zero.rawValue
      | DoryX86RFLAGS.sign.rawValue
    if count == 1 { mask |= DoryX86RFLAGS.overflow.rawValue }
    emitImmediate(~mask, register: 15, into: &words)
    words.append(encodeLogical(.and, left: 12, right: 15, destination: 12))
    words.append(encodeLogical(.or, left: 12, right: 13, destination: 12))
    emitImmediate(DoryX86RFLAGS.reservedOne.rawValue, register: 15, into: &words)
    words.append(encodeLogical(.or, left: 12, right: 15, destination: 12))
    words.append(encodeStore64(register: 12, base: 0, byteOffset: Self.rflagsOffset))
  }

  private func emitMemoryPrologue(into words: inout [UInt32]) {
    words += [
      0xA9BA_7BFD,  // stp x29,x30,[sp,#-96]!
      0x9100_03FD,  // mov x29,sp
      0xA901_53F3,  // stp x19,x20,[sp,#16]
      0xA902_5BF5,  // stp x21,x22,[sp,#32]
      0xA903_63F7,  // stp x23,x24,[sp,#48]
      0xAA00_03F3,  // mov x19,x0 (architectural context)
      0xAA01_03F4,  // mov x20,x1 (memory context)
      0xAA02_03F5,  // mov x21,x2 (read callback)
      0xAA03_03F6,  // mov x22,x3 (write callback)
      0xAA04_03F7,  // mov x23,x4 (atomic compare-exchange callback)
      0xAA05_03F8,  // mov x24,x5 (synchronize callback)
    ]
  }

  private func emitMemoryEpilogue(into words: inout [UInt32]) {
    words += [
      0xA943_63F7,  // ldp x23,x24,[sp,#48]
      0xA942_5BF5,  // ldp x21,x22,[sp,#32]
      0xA941_53F3,  // ldp x19,x20,[sp,#16]
      0xA8C6_7BFD,  // ldp x29,x30,[sp],#96
    ]
  }

  private func emitMemoryRead(
    addressRegister: UInt32,
    width: DoryIRIntegerWidth,
    resultRegister: UInt32,
    words: inout [UInt32]
  ) {
    words.append(encodeLogical(.or, left: 31, right: 20, destination: 0))
    words.append(encodeLogical(.or, left: 31, right: addressRegister, destination: 1))
    words.append(encodeMoveWideZero32(register: 2, immediate: UInt16(width.rawValue / 8)))
    words.append(0xD63F_0000 | 21 << 5)  // blr x21
    words.append(encodeLogical(.or, left: 31, right: 0, destination: resultRegister))
    words.append(encodeLogical(.or, left: 31, right: 19, destination: 0))
  }

  private func emitMemoryWrite(
    addressRegister: UInt32,
    valueRegister: UInt32,
    width: DoryIRIntegerWidth,
    words: inout [UInt32]
  ) {
    words.append(encodeLogical(.or, left: 31, right: 20, destination: 0))
    words.append(encodeLogical(.or, left: 31, right: addressRegister, destination: 1))
    words.append(encodeLogical(.or, left: 31, right: valueRegister, destination: 2))
    words.append(encodeMoveWideZero32(register: 3, immediate: UInt16(width.rawValue / 8)))
    words.append(0xD63F_0000 | 22 << 5)  // blr x22
    words.append(encodeLogical(.or, left: 31, right: 19, destination: 0))
  }

  private func emitMemoryCompareExchange(
    addressRegister: UInt32,
    expectedRegister: UInt32,
    desiredRegister: UInt32,
    width: DoryIRIntegerWidth,
    observedRegister: UInt32,
    words: inout [UInt32]
  ) {
    words.append(encodeStore64(register: expectedRegister, base: 31, byteOffset: 64))
    words.append(encodeLogical(.or, left: 31, right: 20, destination: 0))
    words.append(encodeLogical(.or, left: 31, right: addressRegister, destination: 1))
    words.append(encodeLogical(.or, left: 31, right: expectedRegister, destination: 2))
    words.append(encodeLogical(.or, left: 31, right: desiredRegister, destination: 3))
    words.append(encodeMoveWideZero32(register: 4, immediate: UInt16(width.rawValue / 8)))
    words.append(encodeAddImmediate64(left: 31, immediate: 80, destination: 5))
    words.append(0xD63F_0000 | 23 << 5)  // blr x23
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: false, 0, 31, 31))
    emitInterpreterUnless(condition: .notEqual, usesMemory: true, into: &words)
    words.append(encodeLoad64(register: expectedRegister, base: 31, byteOffset: 64))
    words.append(encodeLoad64(register: observedRegister, base: 31, byteOffset: 80))
    words.append(encodeLogical(.or, left: 31, right: 19, destination: 0))
  }

  private func emitCompareExchange(
    destination: DoryIROperand,
    source: DoryIROperand,
    into words: inout [UInt32]
  ) -> Bool {
    guard case .memory(let address, let width) = destination,
      width == .i32 || width == .i64,
      case .register(let sourceRegister) = source,
      sourceRegister.bank == "x86.gpr", sourceRegister.index < 16, sourceRegister.width == width,
      emitMemoryAddress(address, into: 12, words: &words),
      load(sourceRegister, into: 10, words: &words)
    else { return false }
    let is64Bit = width == .i64
    words.append(
      is64Bit
        ? encodeLoad64(register: 9, base: 0, byteOffset: 0)
        : encodeLoad32(register: 9, base: 0, byteOffset: 0)
    )
    emitMemoryCompareExchange(
      addressRegister: 12,
      expectedRegister: 9,
      desiredRegister: 10,
      width: width,
      observedRegister: 10,
      words: &words
    )
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: is64Bit, 9, 10, 11))
    emitX86ArithmeticFlags(
      subtraction: true,
      includesAuxiliaryCarry: true,
      resultRegister: 11,
      into: &words
    )
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: is64Bit, 9, 10, 31))
    words.append(encodeLoad64(register: 13, base: 0, byteOffset: 0))
    words.append(
      encodeConditionalSelect(
        destination: 11,
        trueRegister: 13,
        falseRegister: 10,
        condition: .equal
      ))
    words.append(encodeStore64(register: 11, base: 0, byteOffset: 0))
    return true
  }

  private func emitBinary(
    _ operation: DoryIRBinaryOperation,
    destination: DoryIROperand,
    source: DoryIROperand,
    writesDestination: Bool,
    into words: inout [UInt32]
  ) -> Bool {
    if case .register(let target) = destination,
      target.bank == "x86.high8", target.index < 4, target.width == .i8,
      operation == .and, writesDestination,
      case .immediate(let immediate, width: .i8) = source
    {
      words.append(encodeLoad64(register: 9, base: 0, byteOffset: Int(target.index) * 8))
      words.append(encodeLogical(.or, left: 31, right: 9, shiftAmount: 8,
        logicalRightShift: true, destination: 9))
      emitImmediate(0xFF, register: 15, into: &words)
      words.append(encodeLogical(.and, left: 9, right: 15, destination: 9))
      emitImmediate(immediate & 0xFF, register: 10, into: &words)
      guard emitLowByteBinaryFlags(.and, writesDestination: true, into: &words) else {
        return false
      }
      // AH/CH/DH/BH replace only bits 8...15 of the containing GPR.
      words.append(encodeLoad64(register: 9, base: 0, byteOffset: Int(target.index) * 8))
      emitImmediate(~UInt64(0xFF00), register: 10, into: &words)
      words.append(encodeLogical(.and, left: 9, right: 10, destination: 9))
      words.append(encodeLogical(.or, left: 9, right: 11, shiftAmount: 8, destination: 9))
      words.append(encodeStore64(register: 9, base: 0, byteOffset: Int(target.index) * 8))
      return true
    }
    if case .register(let target) = destination, isLowByteRegister(target),
      (!writesDestination && (operation == .compare || operation == .test))
        || (writesDestination && operation == .and)
    {
      return emitLowByteBinary(
        operation,
        destination: target,
        source: source,
        writesDestination: writesDestination,
        into: &words
      )
    }
    if case .memory(let address, width: .i8) = destination,
      writesDestination,
      operation == .and
    {
      return emitLowByteMemoryAnd(
        address: address,
        source: source,
        into: &words
      )
    }
    if case .memory(let address, width: .i8) = destination,
      !writesDestination,
      operation == .compare || operation == .test
    {
      return emitLowByteMemoryFlagsBinary(
        operation,
        address: address,
        source: source,
        into: &words
      )
    }

    let width: DoryIRIntegerWidth
    let registerTarget: DoryIRRegister?
    switch destination {
    case .register(let target)
    where target.bank == "x86.gpr" && target.index < 16
      && (target.width == .i32 || target.width == .i64):
      width = target.width
      registerTarget = target
    case .memory(let address, let memoryWidth) where memoryWidth == .i32 || memoryWidth == .i64:
      guard emitMemoryAddress(address, into: 12, words: &words) else { return false }
      emitMemoryRead(addressRegister: 12, width: memoryWidth, resultRegister: 9, words: &words)
      width = memoryWidth
      registerTarget = nil
    default:
      return false
    }
    guard load(source, matching: width, into: 10, words: &words) else { return false }
    if let registerTarget, !load(registerTarget, into: 9, words: &words) { return false }

    let is64Bit = width == .i64
    let arithmetic: Bool
    switch operation {
    case .add:
      words.append(encodeAddSubtractSetFlags(add: true, is64Bit: is64Bit, 9, 10, 11))
      arithmetic = true
    case .addWithCarry:
      emitARMCarryFromX86(inverted: false, into: &words)
      words.append(encodeAddSubtractCarrySetFlags(add: true, is64Bit: is64Bit, 9, 10, 11))
      arithmetic = true
    case .subtract, .compare:
      words.append(encodeAddSubtractSetFlags(add: false, is64Bit: is64Bit, 9, 10, 11))
      arithmetic = true
    case .subtractWithBorrow:
      emitARMCarryFromX86(inverted: true, into: &words)
      words.append(encodeAddSubtractCarrySetFlags(add: false, is64Bit: is64Bit, 9, 10, 11))
      arithmetic = true
    case .and, .test:
      words.append(encodeLogical(.andSetFlags, is64Bit: is64Bit, 9, 10, 11))
      arithmetic = false
    case .or:
      words.append(encodeLogical(.or, is64Bit: is64Bit, 9, 10, 11))
      words.append(encodeLogical(.andSetFlags, is64Bit: is64Bit, 11, 11, 31))
      arithmetic = false
    case .xor:
      words.append(encodeLogical(.xor, is64Bit: is64Bit, 9, 10, 11))
      words.append(encodeLogical(.andSetFlags, is64Bit: is64Bit, 11, 11, 31))
      arithmetic = false
    }

    emitX86ArithmeticFlags(
      subtraction: operation == .subtract || operation == .subtractWithBorrow
        || operation == .compare,
      includesAuxiliaryCarry: arithmetic,
      resultRegister: 11,
      into: &words
    )
    if writesDestination {
      switch destination {
      case .register(let target):
        words.append(
          encodeStore64(register: 11, base: 0, byteOffset: Int(target.index) * 8)
        )
      case .memory(let address, _):
        guard emitMemoryAddress(address, into: 12, words: &words) else { return false }
        emitMemoryWrite(addressRegister: 12, valueRegister: 11, width: width, words: &words)
      default:
        return false
      }
    }
    return true
  }

  private func emitLowByteBinary(
    _ operation: DoryIRBinaryOperation,
    destination: DoryIRRegister,
    source: DoryIROperand,
    writesDestination: Bool,
    into words: inout [UInt32]
  ) -> Bool {
    guard isLowByteRegister(destination) else { return false }
    if case .memory(let address, width: .i8) = source {
      guard !writesDestination, operation == .compare || operation == .test,
        emitMemoryAddress(address, into: 12, words: &words)
      else { return false }
      emitMemoryRead(addressRegister: 12, width: .i8, resultRegister: 10, words: &words)
      guard loadLowByteRegister(destination, into: 9, words: &words) else { return false }
    } else {
      guard loadLowByteRegister(destination, into: 9, words: &words),
        loadLowByteOperand(source, into: 10, words: &words)
      else { return false }
    }

    guard emitLowByteBinaryFlags(
      operation,
      writesDestination: writesDestination,
      into: &words
    ) else { return false }
    if writesDestination {
      words.append(encodeLoad64(register: 9, base: 0, byteOffset: Int(destination.index) * 8))
      emitImmediate(~UInt64(0xFF), register: 10, into: &words)
      words.append(encodeLogical(.and, left: 9, right: 10, destination: 9))
      words.append(encodeLogical(.or, left: 9, right: 11, destination: 9))
      words.append(
        encodeStore64(register: 9, base: 0, byteOffset: Int(destination.index) * 8)
      )
    }
    return true
  }

  private func emitLowByteMemoryAnd(
    address: DoryIRMemoryAddress,
    source: DoryIROperand,
    into words: inout [UInt32]
  ) -> Bool {
    guard emitMemoryAddress(address, into: 12, words: &words) else { return false }
    emitMemoryRead(addressRegister: 12, width: .i8, resultRegister: 9, words: &words)
    guard loadLowByteOperand(source, into: 10, words: &words),
      emitLowByteBinaryFlags(
        .and,
        writesDestination: true,
        into: &words
      ),
      emitMemoryAddress(address, into: 12, words: &words)
    else { return false }
    emitMemoryWrite(addressRegister: 12, valueRegister: 11, width: .i8, words: &words)
    return true
  }

  private func emitLowByteMemoryFlagsBinary(
    _ operation: DoryIRBinaryOperation,
    address: DoryIRMemoryAddress,
    source: DoryIROperand,
    into words: inout [UInt32]
  ) -> Bool {
    guard emitMemoryAddress(address, into: 12, words: &words) else { return false }
    emitMemoryRead(addressRegister: 12, width: .i8, resultRegister: 9, words: &words)
    guard loadLowByteOperand(source, into: 10, words: &words) else { return false }
    return emitLowByteBinaryFlags(
      operation,
      writesDestination: false,
      into: &words
    )
  }

  private func emitLowByteBinaryFlags(
    _ operation: DoryIRBinaryOperation,
    writesDestination: Bool,
    into words: inout [UInt32]
  ) -> Bool {
    // Put the x86 sign bit at the ARM32 sign position before setting NZCV. This makes C, Z, N,
    // and V describe an exact eight-bit operation. The unshifted operands and result remain in
    // x9, x10, and x11 so the shared x86 auxiliary-carry and parity synthesis stays exact.
    words.append(
      encodeLogical(
        .or,
        is64Bit: false,
        left: 31,
        right: 9,
        shiftAmount: 24,
        destination: 12
      ))
    words.append(
      encodeLogical(
        .or,
        is64Bit: false,
        left: 31,
        right: 10,
        shiftAmount: 24,
        destination: 13
      ))
    switch operation {
    case .compare:
      guard !writesDestination else { return false }
      words.append(encodeAddSubtractSetFlags(add: false, is64Bit: false, 12, 13, 11))
    case .and, .test:
      guard writesDestination == (operation == .and) else { return false }
      words.append(encodeLogical(.andSetFlags, is64Bit: false, 12, 13, 11))
    default:
      return false
    }
    words.append(
      encodeLogical(
        .or,
        is64Bit: false,
        left: 31,
        right: 11,
        shiftAmount: 24,
        logicalRightShift: true,
        destination: 11
      ))
    emitX86ArithmeticFlags(
      subtraction: operation == .compare,
      includesAuxiliaryCarry: operation == .compare,
      resultRegister: 11,
      into: &words
    )
    return true
  }

  private func isLowByteRegister(_ register: DoryIRRegister) -> Bool {
    register.bank == "x86.gpr" && register.index < 16 && register.width == .i8
  }

  private func loadLowByteRegister(
    _ register: DoryIRRegister,
    into hostRegister: UInt32,
    words: inout [UInt32]
  ) -> Bool {
    guard isLowByteRegister(register) else { return false }
    words.append(
      encodeLoad64(register: hostRegister, base: 0, byteOffset: Int(register.index) * 8))
    emitImmediate(0xFF, register: 15, into: &words)
    words.append(encodeLogical(.and, left: hostRegister, right: 15, destination: hostRegister))
    return true
  }

  private func loadLowByteOperand(
    _ operand: DoryIROperand,
    into hostRegister: UInt32,
    words: inout [UInt32]
  ) -> Bool {
    switch operand {
    case .register(let register):
      return loadLowByteRegister(register, into: hostRegister, words: &words)
    case .immediate(let value, width: .i8):
      emitImmediate(value & 0xFF, register: hostRegister, into: &words)
      return true
    default:
      return false
    }
  }

  private func emitARMCarryFromX86(inverted: Bool, into words: inout [UInt32]) {
    words.append(encodeLoad64(register: 12, base: 0, byteOffset: Self.rflagsOffset))
    emitImmediate(1, register: 15, into: &words)
    emitFlag(DoryX86RFLAGS.carry, from: 12, into: 12, words: &words)
    if inverted { invertBoolean(12, words: &words) }
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: true, 12, 15, 31))
  }

  private func emitUnary(
    _ operation: DoryIRUnaryOperation,
    operand: DoryIROperand,
    into words: inout [UInt32]
  ) -> Bool {
    let width: DoryIRIntegerWidth
    switch operand {
    case .register(let target)
    where target.bank == "x86.gpr" && target.index < 16
      && (target.width == .i32 || target.width == .i64):
      guard load(target, into: 9, words: &words) else { return false }
      width = target.width
    case .memory(let address, let memoryWidth) where memoryWidth == .i32 || memoryWidth == .i64:
      guard emitMemoryAddress(address, into: 12, words: &words) else { return false }
      emitMemoryRead(addressRegister: 12, width: memoryWidth, resultRegister: 9, words: &words)
      width = memoryWidth
    default:
      return false
    }
    let is64Bit = width == .i64

    switch operation {
    case .increment, .decrement:
      emitImmediate(1, register: 10, into: &words)
      words.append(
        encodeAddSubtractSetFlags(
          add: operation == .increment,
          is64Bit: is64Bit,
          9,
          10,
          11
        ))
      emitX86ArithmeticFlags(
        subtraction: operation == .decrement,
        includesAuxiliaryCarry: true,
        updatesCarry: false,
        resultRegister: 11,
        into: &words
      )
    case .bitwiseNot:
      emitImmediate(is64Bit ? UInt64.max : UInt64(UInt32.max), register: 10, into: &words)
      words.append(encodeLogical(.xor, is64Bit: is64Bit, 9, 10, 11))
    case .negate:
      words.append(encodeLogical(.or, left: 31, right: 9, destination: 10))
      emitImmediate(0, register: 9, into: &words)
      words.append(encodeAddSubtractSetFlags(add: false, is64Bit: is64Bit, 9, 10, 11))
      emitX86ArithmeticFlags(
        subtraction: true,
        includesAuxiliaryCarry: true,
        resultRegister: 11,
        into: &words
      )
    }
    switch operand {
    case .register(let target):
      words.append(encodeStore64(register: 11, base: 0, byteOffset: Int(target.index) * 8))
    case .memory(let address, _):
      guard emitMemoryAddress(address, into: 12, words: &words) else { return false }
      emitMemoryWrite(addressRegister: 12, valueRegister: 11, width: width, words: &words)
    default:
      return false
    }
    return true
  }

  private func emitEffectiveAddress(
    destination: DoryIROperand,
    address: DoryIRMemoryAddress,
    into words: inout [UInt32]
  ) -> Bool {
    guard
      case .register(let target) = destination,
      target.bank == "x86.gpr",
      target.index < 16,
      target.width == .i32 || target.width == .i64,
      emitMemoryAddress(address, into: 9, includeSegmentBase: false, words: &words)
    else { return false }
    let addressIs64Bit = address.addressWidth == .i64
    if target.width == .i32, addressIs64Bit {
      words.append(encodeLogical(.or, is64Bit: false, 31, 9, 9))
    }
    words.append(encodeStore64(register: 9, base: 0, byteOffset: Int(target.index) * 8))
    return true
  }

  private func emitMemoryAddress(
    _ address: DoryIRMemoryAddress,
    into resultRegister: UInt32,
    includeSegmentBase: Bool = true,
    words: inout [UInt32]
  ) -> Bool {
    guard address.segment == nil || address.segment == "fs" || address.segment == "gs",
      address.addressWidth == .i32 || address.addressWidth == .i64,
      address.scale == 1 || address.scale == 2 || address.scale == 4 || address.scale == 8
    else { return false }
    let addressIs64Bit = address.addressWidth == .i64
    let displacement = UInt64(bitPattern: address.displacement)
    emitImmediate(
      addressIs64Bit ? displacement : displacement & 0xFFFF_FFFF,
      register: resultRegister,
      into: &words
    )
    if let relativeBase = address.instructionRelativeBase {
      emitImmediate(relativeBase, register: 10, into: &words)
      words.append(
        encodeAdd(
          is64Bit: addressIs64Bit,
          left: resultRegister,
          right: 10,
          destination: resultRegister
        ))
    }
    if let base = address.base {
      guard base.width == address.addressWidth, load(base, into: 10, words: &words) else {
        return false
      }
      words.append(
        encodeAdd(
          is64Bit: addressIs64Bit,
          left: resultRegister,
          right: 10,
          destination: resultRegister
        ))
    }
    if let index = address.index {
      guard index.width == address.addressWidth, load(index, into: 10, words: &words) else {
        return false
      }
      words.append(
        encodeAdd(
          is64Bit: addressIs64Bit,
          left: resultRegister,
          right: 10,
          leftShift: UInt32(address.scale.trailingZeroBitCount),
          destination: resultRegister
        ))
    }
    if includeSegmentBase, let segment = address.segment {
      let offset = segment == "fs" ? Self.fsBaseOffset : Self.gsBaseOffset
      words.append(encodeLoad64(register: 10, base: 0, byteOffset: offset))
      words.append(
        encodeAdd(
          is64Bit: true,
          left: resultRegister,
          right: 10,
          destination: resultRegister
        ))
    }
    return true
  }

  private func load(
    _ register: DoryIRRegister,
    into hostRegister: UInt32,
    words: inout [UInt32]
  ) -> Bool {
    guard register.bank == "x86.gpr", register.index < 16,
      register.width == .i32 || register.width == .i64
    else { return false }
    words.append(
      register.width == .i64
        ? encodeLoad64(register: hostRegister, base: 0, byteOffset: Int(register.index) * 8)
        : encodeLoad32(register: hostRegister, base: 0, byteOffset: Int(register.index) * 8)
    )
    return true
  }

  private func load(
    _ operand: DoryIROperand,
    matching width: DoryIRIntegerWidth,
    into hostRegister: UInt32,
    words: inout [UInt32]
  ) -> Bool {
    switch operand {
    case .register(let register) where register.width == width:
      return load(register, into: hostRegister, words: &words)
    case .immediate(let value, let immediateWidth) where immediateWidth == width:
      emitImmediate(
        width == .i32 ? value & 0xFFFF_FFFF : value, register: hostRegister, into: &words)
      return true
    case .memory(let address, let memoryWidth) where memoryWidth == width:
      guard emitMemoryAddress(address, into: 12, words: &words) else { return false }
      emitMemoryRead(
        addressRegister: 12,
        width: memoryWidth,
        resultRegister: hostRegister,
        words: &words
      )
      return true
    default:
      return false
    }
  }

  private func emitX86ArithmeticFlags(
    subtraction: Bool,
    includesAuxiliaryCarry: Bool,
    updatesCarry: Bool = true,
    resultRegister: UInt32,
    into words: inout [UInt32]
  ) {
    // Capture ARM NZCV before the flag-synthesis instructions. ARM C is the inverse of x86 CF
    // after subtraction, while addition uses it directly.
    if updatesCarry {
      words.append(
        encodeConditionalSet(register: 13, condition: subtraction ? .carryClear : .carrySet))
    } else {
      emitImmediate(0, register: 13, into: &words)
    }
    words.append(encodeConditionalSet(register: 14, condition: .equal))
    words.append(encodeLogical(.or, left: 13, right: 14, shiftAmount: 6, destination: 13))
    words.append(encodeConditionalSet(register: 14, condition: .minus))
    words.append(encodeLogical(.or, left: 13, right: 14, shiftAmount: 7, destination: 13))
    words.append(encodeConditionalSet(register: 14, condition: .overflowSet))
    words.append(encodeLogical(.or, left: 13, right: 14, shiftAmount: 11, destination: 13))

    if includesAuxiliaryCarry {
      words.append(encodeLogical(.xor, left: 9, right: 10, destination: 14))
      words.append(encodeLogical(.xor, left: 14, right: resultRegister, destination: 14))
      emitImmediate(DoryX86RFLAGS.auxiliaryCarry.rawValue, register: 15, into: &words)
      words.append(encodeLogical(.and, left: 14, right: 15, destination: 14))
      words.append(encodeLogical(.or, left: 13, right: 14, destination: 13))
    }

    // Fold the low byte to one parity bit. x86 PF is one for even parity.
    words.append(
      encodeLogical(
        .xor,
        left: resultRegister,
        right: resultRegister,
        shiftAmount: 4,
        logicalRightShift: true,
        destination: 14
      ))
    words.append(
      encodeLogical(
        .xor,
        left: 14,
        right: 14,
        shiftAmount: 2,
        logicalRightShift: true,
        destination: 14
      ))
    words.append(
      encodeLogical(
        .xor,
        left: 14,
        right: 14,
        shiftAmount: 1,
        logicalRightShift: true,
        destination: 14
      ))
    emitImmediate(1, register: 15, into: &words)
    words.append(encodeLogical(.and, left: 14, right: 15, destination: 14))
    words.append(encodeLogical(.xor, left: 14, right: 15, destination: 14))
    words.append(encodeLogical(.or, left: 13, right: 14, shiftAmount: 2, destination: 13))

    words.append(encodeLoad64(register: 12, base: 0, byteOffset: Self.rflagsOffset))
    let updatedFlagMask =
      updatesCarry
      ? Self.arithmeticFlagMask
      : Self.arithmeticFlagMask & ~DoryX86RFLAGS.carry.rawValue
    emitImmediate(~updatedFlagMask, register: 15, into: &words)
    words.append(encodeLogical(.and, left: 12, right: 15, destination: 12))
    words.append(encodeLogical(.or, left: 12, right: 13, destination: 12))
    emitImmediate(DoryX86RFLAGS.reservedOne.rawValue, register: 15, into: &words)
    words.append(encodeLogical(.or, left: 12, right: 15, destination: 12))
    words.append(encodeStore64(register: 12, base: 0, byteOffset: Self.rflagsOffset))
  }

  private func emit(
    _ terminator: DoryIRTerminator,
    usesMemory: Bool,
    into words: inout [UInt32]
  ) -> DoryJITExitCode? {
    let target: UInt64
    let exit: DoryJITExitCode
    switch terminator {
    case .next(let address), .branch(let address):
      target = address
      exit = .dispatch
    case .call(let address, let returnAddress):
      guard DoryX86ArchitecturalState.isCanonical(address) else { return nil }
      words.append(encodeLoad64(register: 9, base: 0, byteOffset: Self.rspOffset))
      emitImmediate(UInt64(bitPattern: -8), register: 10, into: &words)
      words.append(
        encodeAdd(is64Bit: true, left: 9, right: 10, destination: 11)
      )
      emitCanonicalStackSpanGuard(addressRegister: 11, into: &words)
      words.append(encodeStore64(register: 11, base: 0, byteOffset: Self.rspOffset))
      emitImmediate(returnAddress, register: 10, into: &words)
      emitMemoryWrite(addressRegister: 11, valueRegister: 10, width: .i64, words: &words)
      target = address
      exit = .dispatch
    case .indirectCall(let operand, let returnAddress):
      guard load(operand, matching: .i64, into: 9, words: &words) else { return nil }
      emitCanonicalAddressGuard(register: 9, usesMemory: usesMemory, into: &words)
      // Preserve the evaluated target in the restartable native context. A failed stack write
      // returns through the interpreter path without committing this temporary RIP.
      words.append(encodeStore64(register: 9, base: 0, byteOffset: Self.ripOffset))
      words.append(encodeLoad64(register: 9, base: 0, byteOffset: Self.rspOffset))
      emitImmediate(UInt64(bitPattern: -8), register: 10, into: &words)
      words.append(
        encodeAdd(is64Bit: true, left: 9, right: 10, destination: 11)
      )
      emitCanonicalStackSpanGuard(addressRegister: 11, into: &words)
      words.append(encodeStore64(register: 11, base: 0, byteOffset: Self.rspOffset))
      emitImmediate(returnAddress, register: 10, into: &words)
      emitMemoryWrite(addressRegister: 11, valueRegister: 10, width: .i64, words: &words)
      return .dispatch
    case .indirect(let operand):
      guard load(operand, matching: .i64, into: 9, words: &words) else { return nil }
      emitCanonicalAddressGuard(register: 9, usesMemory: usesMemory, into: &words)
      words.append(encodeStore64(register: 9, base: 0, byteOffset: Self.ripOffset))
      return .dispatch
    case .returnFromCall(let popBytes):
      words.append(encodeLoad64(register: 9, base: 0, byteOffset: Self.rspOffset))
      emitCanonicalStackSpanGuard(addressRegister: 9, into: &words)
      emitMemoryRead(addressRegister: 9, width: .i64, resultRegister: 10, words: &words)
      emitCanonicalAddressGuard(register: 10, usesMemory: usesMemory, into: &words)
      words.append(encodeLoad64(register: 9, base: 0, byteOffset: Self.rspOffset))
      emitImmediate(UInt64(8) &+ UInt64(popBytes), register: 11, into: &words)
      words.append(
        encodeAdd(is64Bit: true, left: 9, right: 11, destination: 9)
      )
      words.append(encodeStore64(register: 9, base: 0, byteOffset: Self.rspOffset))
      words.append(encodeStore64(register: 10, base: 0, byteOffset: Self.ripOffset))
      return .dispatch
    case .exit(let reason, let resumeAt):
      target = resumeAt
      exit =
        switch reason {
        case .halt: .halt
        case .instructionBudget: .dispatch
        case .system: .system
        case .portIO: .portIO
        case .interpreter, .indirectControl: .interpreter
        }
    case .conditional(let condition, let taken, let notTaken):
      guard emitX86Condition(condition, into: 10, words: &words) else { return nil }
      emitImmediate(taken, register: 11, into: &words)
      emitImmediate(notTaken, register: 12, into: &words)
      words.append(encodeAddSubtractSetFlags(add: false, is64Bit: true, 10, 31, 31))
      words.append(
        encodeConditionalSelect(
          destination: 9,
          trueRegister: 11,
          falseRegister: 12,
          condition: .notEqual
        ))
      if requiresRuntimeAddressGuard(terminator) {
        emitCanonicalAddressGuard(register: 9, usesMemory: usesMemory, into: &words)
      }
      words.append(encodeStore64(register: 9, base: 0, byteOffset: Self.ripOffset))
      return .dispatch
    }
    guard DoryX86ArchitecturalState.isCanonical(target) else { return nil }
    emitImmediate(target, register: 9, into: &words)
    words.append(encodeStore64(register: 9, base: 0, byteOffset: Self.ripOffset))
    return exit
  }

  /// Sign-extend bit 47 and compare all 64 bits. Checking only bits 63:48 would
  /// incorrectly accept 0x0000800000000000. Scratch registers x13...x15 are temporary.
  private func emitCanonicalAddressGuard(
    register: UInt32, usesMemory: Bool, into words: inout [UInt32]
  ) {
    words.append(0x9340_0000 | (47 << 10) | (register << 5) | 15)  // sbfx x15,xN,#0,#48
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: true, register, 15, 31))
    emitInterpreterUnless(condition: .equal, usesMemory: usesMemory, into: &words)
  }

  private func emitCanonicalStackSpanGuard(addressRegister: UInt32, into words: inout [UInt32]) {
    emitCanonicalAddressGuard(register: addressRegister, usesMemory: true, into: &words)
    emitImmediate(7, register: 14, into: &words)
    words.append(encodeAddSubtractSetFlags(add: true, is64Bit: true, addressRegister, 14, 13))
    emitInterpreterUnless(condition: .carryClear, usesMemory: true, into: &words)
    emitCanonicalAddressGuard(register: 13, usesMemory: true, into: &words)
  }

  private func emitInterpreterUnless(
    condition: ARM64Condition, usesMemory: Bool, into words: inout [UInt32]
  ) {
    let accepted = words.count
    words.append(0)
    if usesMemory { emitMemoryEpilogue(into: &words) }
    words.append(encodeMoveWideZero32(register: 0, immediate: UInt16(DoryJITExitCode.interpreter.rawValue)))
    words.append(0xD65F_03C0)
    words[accepted] = encodeConditionalBranch(condition: condition, wordOffset: words.count - accepted)
  }

  private func emitX86Condition(
    _ name: String,
    into result: UInt32,
    words: inout [UInt32]
  ) -> Bool {
    let prefix = "x86.condition."
    guard name.hasPrefix(prefix),
      let rawValue = UInt8(name.dropFirst(prefix.count)),
      let condition = DoryX86Condition(rawValue: rawValue)
    else { return false }

    return emitX86Condition(condition, into: result, words: &words)
  }

  private func emitX86Condition(
    _ condition: DoryX86Condition,
    into result: UInt32,
    words: inout [UInt32]
  ) -> Bool {
    words.append(encodeLoad64(register: 9, base: 0, byteOffset: Self.rflagsOffset))
    emitImmediate(1, register: 15, into: &words)
    switch condition {
    case .overflow:
      emitFlag(DoryX86RFLAGS.overflow, from: 9, into: result, words: &words)
    case .notOverflow:
      emitFlag(DoryX86RFLAGS.overflow, from: 9, into: result, words: &words)
      invertBoolean(result, words: &words)
    case .below:
      emitFlag(DoryX86RFLAGS.carry, from: 9, into: result, words: &words)
    case .aboveOrEqual:
      emitFlag(DoryX86RFLAGS.carry, from: 9, into: result, words: &words)
      invertBoolean(result, words: &words)
    case .equal:
      emitFlag(DoryX86RFLAGS.zero, from: 9, into: result, words: &words)
    case .notEqual:
      emitFlag(DoryX86RFLAGS.zero, from: 9, into: result, words: &words)
      invertBoolean(result, words: &words)
    case .belowOrEqual, .above:
      emitFlag(DoryX86RFLAGS.carry, from: 9, into: result, words: &words)
      emitFlag(DoryX86RFLAGS.zero, from: 9, into: 11, words: &words)
      words.append(encodeLogical(.or, left: result, right: 11, destination: result))
      if condition == .above { invertBoolean(result, words: &words) }
    case .sign:
      emitFlag(DoryX86RFLAGS.sign, from: 9, into: result, words: &words)
    case .notSign:
      emitFlag(DoryX86RFLAGS.sign, from: 9, into: result, words: &words)
      invertBoolean(result, words: &words)
    case .parity:
      emitFlag(DoryX86RFLAGS.parity, from: 9, into: result, words: &words)
    case .notParity:
      emitFlag(DoryX86RFLAGS.parity, from: 9, into: result, words: &words)
      invertBoolean(result, words: &words)
    case .less, .greaterOrEqual:
      emitFlag(DoryX86RFLAGS.sign, from: 9, into: result, words: &words)
      emitFlag(DoryX86RFLAGS.overflow, from: 9, into: 11, words: &words)
      words.append(encodeLogical(.xor, left: result, right: 11, destination: result))
      if condition == .greaterOrEqual { invertBoolean(result, words: &words) }
    case .lessOrEqual, .greater:
      emitFlag(DoryX86RFLAGS.zero, from: 9, into: result, words: &words)
      emitFlag(DoryX86RFLAGS.sign, from: 9, into: 11, words: &words)
      emitFlag(DoryX86RFLAGS.overflow, from: 9, into: 12, words: &words)
      words.append(encodeLogical(.xor, left: 11, right: 12, destination: 11))
      words.append(encodeLogical(.or, left: result, right: 11, destination: result))
      if condition == .greater { invertBoolean(result, words: &words) }
    }
    return true
  }

  private func emitFlag(
    _ flag: DoryX86RFLAGS,
    from flagsRegister: UInt32,
    into result: UInt32,
    words: inout [UInt32]
  ) {
    words.append(
      encodeLogical(
        .or,
        left: 31,
        right: flagsRegister,
        shiftAmount: UInt32(flag.rawValue.trailingZeroBitCount),
        logicalRightShift: true,
        destination: result
      ))
    words.append(encodeLogical(.and, left: result, right: 15, destination: result))
  }

  private func invertBoolean(_ register: UInt32, words: inout [UInt32]) {
    words.append(encodeLogical(.xor, left: register, right: 15, destination: register))
  }

  private func emitImmediate(
    _ value: UInt64,
    register: UInt32,
    into words: inout [UInt32]
  ) {
    var emitted = false
    for halfword in 0..<4 {
      let immediate = UInt16(truncatingIfNeeded: value >> UInt64(halfword * 16))
      if !emitted {
        words.append(
          encodeMoveWideZero64(
            register: register,
            immediate: immediate,
            halfword: UInt32(halfword)
          ))
        emitted = true
      } else if immediate != 0 {
        words.append(
          encodeMoveWideKeep64(
            register: register,
            immediate: immediate,
            halfword: UInt32(halfword)
          ))
      }
    }
  }

  private func encodeLoad64(register: UInt32, base: UInt32, byteOffset: Int) -> UInt32 {
    0xF940_0000 | UInt32(byteOffset / 8) << 10 | base << 5 | register
  }

  private func encodeLoad32(register: UInt32, base: UInt32, byteOffset: Int) -> UInt32 {
    0xB940_0000 | UInt32(byteOffset / 4) << 10 | base << 5 | register
  }

  private func encodeStore64(register: UInt32, base: UInt32, byteOffset: Int) -> UInt32 {
    0xF900_0000 | UInt32(byteOffset / 8) << 10 | base << 5 | register
  }

  private func encodeVariableShift(
    _ operation: DoryIRShiftOperation,
    is64Bit: Bool,
    value: UInt32,
    count: UInt32,
    destination: UInt32
  ) -> UInt32 {
    let base: UInt32 =
      switch (operation, is64Bit) {
      case (.left, false): 0x1AC0_2000
      case (.left, true): 0x9AC0_2000
      case (.logicalRight, false): 0x1AC0_2400
      case (.logicalRight, true): 0x9AC0_2400
      case (.arithmeticRight, false): 0x1AC0_2800
      case (.arithmeticRight, true): 0x9AC0_2800
      case (.rotateLeft, _): preconditionFailure("rotate-left count must be normalized")
      }
    return base | count << 16 | value << 5 | destination
  }

  private func encodeSignedMultiplyLong32(
    left: UInt32,
    right: UInt32,
    destination: UInt32
  ) -> UInt32 {
    0x9B20_7C00 | right << 16 | left << 5 | destination
  }

  private func encodeCountLeadingZeros(is64Bit: Bool, source: UInt32, destination: UInt32) -> UInt32 {
    (is64Bit ? 0xDAC0_1000 : 0x5AC0_1000) | source << 5 | destination
  }

  private func encodeReverseBits(is64Bit: Bool, source: UInt32, destination: UInt32) -> UInt32 {
    (is64Bit ? 0xDAC0_0000 : 0x5AC0_0000) | source << 5 | destination
  }

  private func encodeReverseBytes(
    is64Bit: Bool,
    source: UInt32,
    destination: UInt32
  ) -> UInt32 {
    (is64Bit ? 0xDAC0_0C00 : 0x5AC0_0800) | source << 5 | destination
  }

  private func encodeMultiply64(left: UInt32, right: UInt32, destination: UInt32) -> UInt32 {
    0x9B00_7C00 | right << 16 | left << 5 | destination
  }

  private func encodeSignedMultiplyHigh64(
    left: UInt32,
    right: UInt32,
    destination: UInt32
  ) -> UInt32 {
    0x9B40_7C00 | right << 16 | left << 5 | destination
  }

  private func encodeUnsignedMultiplyHigh64(
    left: UInt32,
    right: UInt32,
    destination: UInt32
  ) -> UInt32 {
    0x9BC0_7C00 | right << 16 | left << 5 | destination
  }

  private func encodeUnsignedDivide(
    is64Bit: Bool,
    dividend: UInt32,
    divisor: UInt32,
    quotient: UInt32
  ) -> UInt32 {
    (is64Bit ? 0x9AC0_0800 : 0x1AC0_0800) | divisor << 16 | dividend << 5 | quotient
  }

  private func encodeMultiplySubtract(
    is64Bit: Bool,
    left: UInt32,
    right: UInt32,
    minuend: UInt32,
    destination: UInt32
  ) -> UInt32 {
    (is64Bit ? 0x9B00_8000 : 0x1B00_8000) | right << 16 | minuend << 10 | left << 5 | destination
  }

  private func encodeRotateRightImmediate64(
    value: UInt32,
    amount: UInt32,
    destination: UInt32
  ) -> UInt32 {
    0x93C0_0000 | value << 16 | amount << 10 | value << 5 | destination
  }

  private func encodeSignExtend32To64(source: UInt32, destination: UInt32) -> UInt32 {
    0x9340_7C00 | source << 5 | destination
  }

  private func encodeMoveWideZero64(
    register: UInt32,
    immediate: UInt16,
    halfword: UInt32
  ) -> UInt32 {
    0xD280_0000 | halfword << 21 | UInt32(immediate) << 5 | register
  }

  private func encodeMoveWideKeep64(
    register: UInt32,
    immediate: UInt16,
    halfword: UInt32
  ) -> UInt32 {
    0xF280_0000 | halfword << 21 | UInt32(immediate) << 5 | register
  }

  private func encodeMoveWideZero32(register: UInt32, immediate: UInt16) -> UInt32 {
    0x5280_0000 | UInt32(immediate) << 5 | register
  }

  private enum LogicalOperation {
    case and, or, xor, andSetFlags
  }

  private func encodeLogical(
    _ operation: LogicalOperation,
    is64Bit: Bool = true,
    left: UInt32,
    right: UInt32,
    shiftAmount: UInt32 = 0,
    logicalRightShift: Bool = false,
    destination: UInt32
  ) -> UInt32 {
    let base: UInt32 =
      switch (operation, is64Bit) {
      case (.and, true): 0x8A00_0000
      case (.and, false): 0x0A00_0000
      case (.or, true): 0xAA00_0000
      case (.or, false): 0x2A00_0000
      case (.xor, true): 0xCA00_0000
      case (.xor, false): 0x4A00_0000
      case (.andSetFlags, true): 0xEA00_0000
      case (.andSetFlags, false): 0x6A00_0000
      }
    let shift = logicalRightShift ? UInt32(1) << 22 : 0
    return base | shift | shiftAmount << 10 | right << 16 | left << 5 | destination
  }

  private func encodeLogical(
    _ operation: LogicalOperation,
    is64Bit: Bool,
    _ left: UInt32,
    _ right: UInt32,
    _ destination: UInt32
  ) -> UInt32 {
    encodeLogical(
      operation,
      is64Bit: is64Bit,
      left: left,
      right: right,
      destination: destination
    )
  }

  private func encodeAddSubtractSetFlags(
    add: Bool,
    is64Bit: Bool,
    _ left: UInt32,
    _ right: UInt32,
    _ destination: UInt32
  ) -> UInt32 {
    let base: UInt32 =
      switch (add, is64Bit) {
      case (true, true): 0xAB00_0000
      case (true, false): 0x2B00_0000
      case (false, true): 0xEB00_0000
      case (false, false): 0x6B00_0000
      }
    return base | right << 16 | left << 5 | destination
  }

  private func encodeAddSubtractCarrySetFlags(
    add: Bool,
    is64Bit: Bool,
    _ left: UInt32,
    _ right: UInt32,
    _ destination: UInt32
  ) -> UInt32 {
    let base: UInt32 =
      switch (add, is64Bit) {
      case (true, true): 0xBA00_0000
      case (true, false): 0x3A00_0000
      case (false, true): 0xFA00_0000
      case (false, false): 0x7A00_0000
      }
    return base | right << 16 | left << 5 | destination
  }

  private func encodeAdd(
    is64Bit: Bool,
    left: UInt32,
    right: UInt32,
    leftShift: UInt32 = 0,
    destination: UInt32
  ) -> UInt32 {
    let base: UInt32 = is64Bit ? 0x8B00_0000 : 0x0B00_0000
    return base | right << 16 | leftShift << 10 | left << 5 | destination
  }

  private func encodeAddImmediate64(
    left: UInt32,
    immediate: UInt32,
    destination: UInt32
  ) -> UInt32 {
    precondition(immediate < 4096)
    return 0x9100_0000 | immediate << 10 | left << 5 | destination
  }

  private enum ARM64Condition: UInt32 {
    case equal = 0
    case notEqual = 1
    case carrySet = 2
    case carryClear = 3
    case minus = 4
    case overflowSet = 6
  }

  private func encodeConditionalSet(register: UInt32, condition: ARM64Condition) -> UInt32 {
    0x9A9F_07E0 | ((condition.rawValue ^ 1) << 12) | register
  }

  private func encodeConditionalSelect(
    destination: UInt32,
    trueRegister: UInt32,
    falseRegister: UInt32,
    condition: ARM64Condition
  ) -> UInt32 {
    0x9A80_0000 | falseRegister << 16 | condition.rawValue << 12 | trueRegister << 5
      | destination
  }

  private func encodeConditionalBranch(
    condition: ARM64Condition,
    wordOffset: Int
  ) -> UInt32 {
    precondition((-262_144..<262_144).contains(wordOffset))
    let immediate = UInt32(truncatingIfNeeded: wordOffset) & 0x7_ffff
    return 0x5400_0000 | immediate << 5 | condition.rawValue
  }
}

public struct DoryJITBlockKey: Codable, Sendable, Hashable {
  public let guestStart: UInt64
  public let addressSpaceID: UInt64
  public let codeGeneration: UInt64
  public let cpuProfileIdentifier: String
  public let executionMode: DoryX86ExecutionMode
  public let privilegeLevel: UInt8
  public let pagingEnabled: Bool

  public init(
    guestStart: UInt64,
    addressSpaceID: UInt64,
    codeGeneration: UInt64,
    cpuProfileIdentifier: String = DoryX86CPUProfile.compatibleV1Identifier,
    executionMode: DoryX86ExecutionMode = .long64,
    privilegeLevel: UInt8 = 0,
    pagingEnabled: Bool = false
  ) {
    self.guestStart = guestStart
    self.addressSpaceID = addressSpaceID
    self.codeGeneration = codeGeneration
    self.cpuProfileIdentifier = cpuProfileIdentifier
    self.executionMode = executionMode
    self.privilegeLevel = privilegeLevel & 3
    self.pagingEnabled = pagingEnabled
  }
}

public final class DoryJITCodeCache: @unchecked Sendable {
  private struct Entry {
    let block: DoryARM64CompiledBlock
    var lastUse: UInt64
  }

  public let maximumBytes: Int
  private let lock = NSLock()
  private var entries: [DoryJITBlockKey: Entry] = [:]
  private var byteCount = 0
  private var clock: UInt64 = 0

  public init(maximumBytes: Int) {
    self.maximumBytes = max(0, maximumBytes)
  }

  public var residentByteCount: Int { lock.withLock { byteCount } }
  public var residentBlockCount: Int { lock.withLock { entries.count } }

  public func block(for key: DoryJITBlockKey) -> DoryARM64CompiledBlock? {
    lock.withLock {
      guard var entry = entries[key] else { return nil }
      clock &+= 1
      entry.lastUse = clock
      entries[key] = entry
      return entry.block
    }
  }

  public func insert(_ block: DoryARM64CompiledBlock, for key: DoryJITBlockKey) {
    lock.withLock {
      if let previous = entries.removeValue(forKey: key) {
        byteCount -= previous.block.machineBytes.count
      }
      let size = block.machineBytes.count
      guard size <= maximumBytes else { return }
      while byteCount + size > maximumBytes, let victim = leastRecentlyUsedKey() {
        if let removed = entries.removeValue(forKey: victim) {
          byteCount -= removed.block.machineBytes.count
        }
      }
      clock &+= 1
      entries[key] = .init(block: block, lastUse: clock)
      byteCount += size
    }
  }

  public func invalidate(addressSpaceID: UInt64, guestRange: Range<UInt64>) {
    lock.withLock {
      let victims = entries.filter { key, entry in
        guard key.addressSpaceID == addressSpaceID else { return false }
        let blockRange = key.guestStart..<(key.guestStart &+ UInt64(entry.block.guestByteCount))
        return blockRange.overlaps(guestRange)
      }.map(\.key)
      for key in victims {
        if let removed = entries.removeValue(forKey: key) {
          byteCount -= removed.block.machineBytes.count
        }
      }
    }
  }

  public func invalidateAll() {
    lock.withLock {
      entries.removeAll(keepingCapacity: true)
      byteCount = 0
    }
  }

  private func leastRecentlyUsedKey() -> DoryJITBlockKey? {
    entries.min { lhs, rhs in
      if lhs.value.lastUse != rhs.value.lastUse {
        return lhs.value.lastUse < rhs.value.lastUse
      }
      return lhs.key.guestStart < rhs.key.guestStart
    }?.key
  }
}

public enum DoryJITRuntimeError: Error, Sendable, Equatable {
  case unavailable(Int32)
  case publicationFailed(Int32)
  case invalidOffset(Int)
  case invalidContextWordCount(Int)
  case executionFailed(Int32)
  case invalidExitCode(UInt32)
}

fileprivate struct DoryJITMemoryCapabilities {
  let memory: any DoryX86Memory
  let scalarMemory: (any DoryX86ScalarMemory)?
  let restartableScalarMemory: (any DoryX86RestartableScalarMemory)?
  let atomicScalarMemory: (any DoryX86AtomicScalarMemory)?

  init(memory: any DoryX86Memory) {
    self.memory = memory
    scalarMemory = memory as? any DoryX86ScalarMemory
    restartableScalarMemory = memory as? any DoryX86RestartableScalarMemory
    atomicScalarMemory = memory as? any DoryX86AtomicScalarMemory
  }
}

private struct DoryJITMemoryCallbackContext {
  let capabilities: DoryJITMemoryCapabilities
  let requiresRestartableReads: Bool
  var failed = false
}

private let doryJITMemorySynchronize: dory_jit_memory_synchronize_function = { opaque in
  guard let opaque else { return }
  let context = opaque.assumingMemoryBound(to: DoryJITMemoryCallbackContext.self)
  guard !context.pointee.failed else { return }
  context.pointee.capabilities.memory.synchronize()
}

private let doryJITMemoryRead: dory_jit_memory_read_function = { opaque, address, byteCount in
  guard let opaque, [1, 2, 4, 8].contains(byteCount) else { return 0 }
  let context = opaque.assumingMemoryBound(to: DoryJITMemoryCallbackContext.self)
  guard !context.pointee.failed else { return 0 }
  do {
    if context.pointee.requiresRestartableReads {
      guard let restartableScalarMemory = context.pointee.capabilities.restartableScalarMemory,
        let value = try restartableScalarMemory.readRestartableScalar(
          at: address,
          byteCount: Int(byteCount)
        )
      else {
        context.pointee.failed = true
        return 0
      }
      return value
    }
    if let scalarMemory = context.pointee.capabilities.scalarMemory {
      return try scalarMemory.readScalar(at: address, byteCount: Int(byteCount))
    }
    return try context.pointee.capabilities.memory.read(
      at: address,
      byteCount: Int(byteCount)
    ).enumerated().reduce(0) {
      $0 | UInt64($1.element) << UInt64($1.offset * 8)
    }
  } catch {
    context.pointee.failed = true
    return 0
  }
}

private let doryJITMemoryWrite: dory_jit_memory_write_function = {
  opaque, address, value, byteCount in
  guard let opaque, [1, 2, 4, 8].contains(byteCount) else { return }
  let context = opaque.assumingMemoryBound(to: DoryJITMemoryCallbackContext.self)
  guard !context.pointee.failed else { return }
  do {
    if let scalarMemory = context.pointee.capabilities.scalarMemory {
      try scalarMemory.writeScalar(at: address, value: value, byteCount: Int(byteCount))
      return
    }
    let bytes = (0..<Int(byteCount)).map {
      UInt8(truncatingIfNeeded: value >> UInt64($0 * 8))
    }
    try context.pointee.capabilities.memory.validateWrite(at: address, byteCount: bytes.count)
    try context.pointee.capabilities.memory.write(at: address, bytes: bytes)
  } catch {
    context.pointee.failed = true
  }
}

private let doryJITMemoryCompareExchange: dory_jit_memory_compare_exchange_function = {
  opaque, address, expected, desired, byteCount, observedOut in
  guard let opaque, let observedOut, [1, 2, 4, 8].contains(byteCount) else { return 0 }
  let context = opaque.assumingMemoryBound(to: DoryJITMemoryCallbackContext.self)
  guard !context.pointee.failed, let atomicMemory = context.pointee.capabilities.atomicScalarMemory else {
    context.pointee.failed = true
    return 0
  }
  do {
    guard let observed = try DoryX86AtomicGate.shared.withLock({
      try atomicMemory.compareExchangeScalar(
        at: address,
        expected: expected,
        desired: desired,
        byteCount: Int(byteCount)
      )
    }) else {
      context.pointee.failed = true
      return 0
    }
    observedOut.pointee = observed
    return 1
  } catch {
    context.pointee.failed = true
    return 0
  }
}

public final class DoryJITExecutableRegion: @unchecked Sendable {
  public static let contextWordCount = 21

  private let lock = NSLock()
  private let region: OpaquePointer
  public let capacity: Int

  public init(minimumCapacity: Int) throws {
    guard minimumCapacity > 0 else { throw DoryJITRuntimeError.unavailable(22) }
    var created: OpaquePointer?
    let result = dory_jit_region_create(minimumCapacity, &created)
    guard result == 0, let created else {
      throw DoryJITRuntimeError.unavailable(result)
    }
    region = created
    capacity = dory_jit_region_capacity(created)
  }

  deinit {
    dory_jit_region_destroy(region)
  }

  public func publish(_ block: DoryARM64CompiledBlock, at offset: Int) throws {
    let bytes = block.machineBytes
    guard offset >= 0, offset.isMultiple(of: 4), offset <= capacity,
      bytes.count <= capacity - offset
    else {
      throw DoryJITRuntimeError.invalidOffset(offset)
    }
    let result = lock.withLock {
      bytes.withUnsafeBytes { buffer in
        dory_jit_region_publish(
          region,
          offset,
          buffer.bindMemory(to: UInt8.self).baseAddress,
          bytes.count
        )
      }
    }
    guard result == 0 else { throw DoryJITRuntimeError.publicationFailed(result) }
  }

  public func execute(
    at offset: Int,
    context: inout [UInt64],
    memory: (any DoryX86Memory)? = nil,
    requiresRestartableReads: Bool = false
  ) throws -> DoryJITExitCode {
    try context.withUnsafeMutableBufferPointer { buffer in
      try execute(
        at: offset,
        context: buffer,
        memory: memory,
        requiresRestartableReads: requiresRestartableReads
      )
    }
  }

  func execute(
    at offset: Int,
    context: UnsafeMutableBufferPointer<UInt64>,
    memory: (any DoryX86Memory)? = nil,
    requiresRestartableReads: Bool = false
  ) throws -> DoryJITExitCode {
    try executePrepared(
      at: offset,
      context: context,
      memoryCapabilities: memory.map { DoryJITMemoryCapabilities(memory: $0) },
      requiresRestartableReads: requiresRestartableReads
    )
  }

  fileprivate func executePrepared(
    at offset: Int,
    context: UnsafeMutableBufferPointer<UInt64>,
    memoryCapabilities: DoryJITMemoryCapabilities?,
    requiresRestartableReads: Bool
  ) throws -> DoryJITExitCode {
    guard offset >= 0, offset.isMultiple(of: 4), offset < capacity else {
      throw DoryJITRuntimeError.invalidOffset(offset)
    }
    guard context.count == Self.contextWordCount else {
      throw DoryJITRuntimeError.invalidContextWordCount(context.count)
    }
    var rawExit: UInt32 = 0
    let result: Int32
    var memoryFailed = false
    if let memoryCapabilities {
      var memoryContext = DoryJITMemoryCallbackContext(
        capabilities: memoryCapabilities,
        requiresRestartableReads: requiresRestartableReads
      )
      result = withUnsafeMutablePointer(to: &memoryContext) { memoryContext in
        dory_jit_region_execute(
          region,
          offset,
          context.baseAddress,
          UnsafeMutableRawPointer(memoryContext),
          doryJITMemoryRead,
          doryJITMemoryWrite,
          doryJITMemoryCompareExchange,
          doryJITMemorySynchronize,
          &rawExit
        )
      }
      memoryFailed = memoryContext.failed
    } else {
      result = dory_jit_region_execute(
        region,
        offset,
        context.baseAddress,
        nil,
        doryJITMemoryRead,
        doryJITMemoryWrite,
        doryJITMemoryCompareExchange,
        doryJITMemorySynchronize,
        &rawExit
      )
    }
    guard result == 0 else { throw DoryJITRuntimeError.executionFailed(result) }
    if memoryFailed { return .interpreter }
    guard let exit = DoryJITExitCode(rawValue: rawExit) else {
      throw DoryJITRuntimeError.invalidExitCode(rawExit)
    }
    return exit
  }

  /// Replays an already validated sequence of callback-free resident blocks without crossing the
  /// Swift/C boundary between each block. Expected RIP guards stop safely when a conditional path
  /// diverges from the recorded trace.
  func executeBatch(
    offsets: [Int],
    expectedGuestRIPs: [UInt64],
    guestInstructionCounts: [UInt32],
    context: UnsafeMutableBufferPointer<UInt64>
  ) throws -> DoryARM64NativeBatchExecution {
    guard !offsets.isEmpty, offsets.count == expectedGuestRIPs.count,
      offsets.count == guestInstructionCounts.count
    else { throw DoryJITRuntimeError.executionFailed(EINVAL) }
    guard context.count == Self.contextWordCount else {
      throw DoryJITRuntimeError.invalidContextWordCount(context.count)
    }
    for offset in offsets {
      guard offset >= 0, offset.isMultiple(of: 4), offset < capacity else {
        throw DoryJITRuntimeError.invalidOffset(offset)
      }
    }
    var rawExit: UInt32 = 0
    var executedBlocks: UInt32 = 0
    var executedInstructions: UInt32 = 0
    let result = offsets.withUnsafeBufferPointer { offsets in
      expectedGuestRIPs.withUnsafeBufferPointer { expectedGuestRIPs in
        guestInstructionCounts.withUnsafeBufferPointer { guestInstructionCounts in
          dory_jit_region_execute_batch(
            region,
            offsets.baseAddress,
            expectedGuestRIPs.baseAddress,
            guestInstructionCounts.baseAddress,
            offsets.count,
            context.baseAddress,
            &rawExit,
            &executedBlocks,
            &executedInstructions
          )
        }
      }
    }
    guard result == 0 else { throw DoryJITRuntimeError.executionFailed(result) }
    guard let exit = DoryJITExitCode(rawValue: rawExit) else {
      throw DoryJITRuntimeError.invalidExitCode(rawExit)
    }
    return .init(
      guestInstructionCount: executedInstructions,
      residentBlockCount: executedBlocks,
      exitCode: exit
    )
  }
}

public struct DoryARM64BaselineExecution: Sendable, Hashable {
  public let block: DoryARM64CompiledBlock
  public let exitCode: DoryJITExitCode

  public init(block: DoryARM64CompiledBlock, exitCode: DoryJITExitCode) {
    self.block = block
    self.exitCode = exitCode
  }
}

/// Allocation-free dispatch metadata for machine loops that do not need to retain compiled code.
public struct DoryARM64ExecutionSummary: Sendable, Hashable {
  public let guestInstructionCount: UInt32
  public let residentBlockCount: UInt32
  public let tier: DoryARM64CompilationTier
  public let exitCode: DoryJITExitCode

  public init(
    guestInstructionCount: UInt32,
    residentBlockCount: UInt32 = 1,
    tier: DoryARM64CompilationTier,
    exitCode: DoryJITExitCode
  ) {
    self.guestInstructionCount = guestInstructionCount
    self.residentBlockCount = residentBlockCount
    self.tier = tier
    self.exitCode = exitCode
  }
}

/// The stage that rejected a translated guest block before it could enter executable memory.
public enum DoryARM64CompilationDeclineReason: String, Sendable, Hashable {
  case interpreterHelper
  case nativeEmitter
}

/// One exact, currently live negative-cache identity and its saturating validated-hit count.
public struct DoryARM64NegativeCacheHotSite: Sendable, Hashable {
  public let guestRIP: UInt64
  public let executionMode: DoryX86ExecutionMode
  public let instructionBudget: Int
  public let addressSpaceID: UInt64
  public let privilegeLevel: UInt8
  public let pagingEnabled: Bool
  public let guestByteCount: Int
  public let instructionBytes: [UInt8]
  public let declineReason: DoryARM64CompilationDeclineReason
  public let hitCount: UInt64
}

/// Cumulative cache-path evidence for one JIT executor. This remains process-local rather than
/// part of the daemon wire contract so a runner can diagnose throughput without coupling older
/// daemons to a newer helper's telemetry schema.
public struct DoryARM64BaselineExecutorDiagnostics: Sendable, Hashable {
  public let recentLookupHits: UInt64
  public let dictionaryLookupHits: UInt64
  public let lookupMisses: UInt64
  public let memoryGenerationHits: UInt64
  public let byteValidationHits: UInt64
  public let sharedCodeHits: UInt64
  public let compiledBlocks: UInt64
  public let declinedCompilations: UInt64
  public let negativeCacheHits: UInt64
  public let negativeCacheMisses: UInt64
  public let negativeGenerationMismatches: UInt64
  public let negativeEntryCount: UInt64
  /// Exact hit counts for the 16 hottest currently live negative entries. Replacing or removing an
  /// entry through collision, invalidation, generation mismatch, or cache reset discards its count.
  public let negativeCacheHotSites: [DoryARM64NegativeCacheHotSite]
  public let codeCacheWraps: UInt64
  public let nativeTraceAttempts: UInt64
  public let nativeTraceReplays: UInt64
  public let codeGenerationChecks: UInt64
  public let codeGenerationMismatches: UInt64
  public let chainedExecutionCalls: UInt64
  public let chainedRequestedInstructions: UInt64
  public let chainedRetiredInstructions: UInt64
}

struct DoryARM64NativeBatchExecution: Sendable, Hashable {
  let guestInstructionCount: UInt32
  let residentBlockCount: UInt32
  let exitCode: DoryJITExitCode
}

/// Owns one bounded MAP_JIT region and dispatches exact, helper-free baseline blocks through it.
/// Unsupported blocks never enter executable memory and return `nil` so the caller can execute
/// the instruction at the unchanged guest RIP with the interpreter.
public final class DoryARM64BaselineExecutor: @unchecked Sendable {
  /// Full-system firmware, bootloaders, kernels, and initramfs helpers touch substantially more
  /// translated code than an application-process DBT. Keep the executable region bounded, but
  /// large enough that a normal installer boot does not continuously discard and recompile its
  /// cold-start working set.
  public static let defaultMaximumCodeBytes = 128 * 1024 * 1024
  static let maximumResidentInstructionBudget = 64
  static let maximumRecordedNativeTraceBlocks = 256

  private struct LookupKey: Hashable {
    let guestStart: UInt64
    let addressSpaceID: UInt64
    let executionMode: DoryX86ExecutionMode
    let privilegeLevel: UInt8
    let pagingEnabled: Bool
  }

  /// Emitted host code depends on the virtual RIP and architectural execution context, but not on
  /// the guest page-table root. Per-address-space entries still own byte-generation validation;
  /// this key only lets an exact byte match reuse already-published ARM64 code after a CR3 change.
  private struct SharedCodeKey: Hashable {
    let guestStart: UInt64
    let executionMode: DoryX86ExecutionMode
    let privilegeLevel: UInt8
    let pagingEnabled: Bool
  }

  private final class ResidentBlock {
    let block: DoryARM64CompiledBlock
    let offset: Int
    let codeGeneration: UInt64
    let memoryCodeGeneration: UInt64?
    let endsTimeBoundary: Bool

    init(
      block: DoryARM64CompiledBlock,
      offset: Int,
      codeGeneration: UInt64,
      memoryCodeGeneration: UInt64?,
      endsTimeBoundary: Bool
    ) {
      self.block = block
      self.offset = offset
      self.codeGeneration = codeGeneration
      self.memoryCodeGeneration = memoryCodeGeneration
      self.endsTimeBoundary = endsTimeBoundary
    }
  }

  private struct RecentResidentBlock {
    let key: LookupKey
    let resident: ResidentBlock
  }

  private struct NegativeLookupKey: Hashable {
    let lookupKey: LookupKey
    let instructionBudget: Int
  }

  private struct NegativeEntry {
    let key: NegativeLookupKey
    let guestByteCount: Int
    let instructionBytes: [UInt8]
    let declineReason: DoryARM64CompilationDeclineReason
    let memoryCodeGeneration: UInt64
    let codeCacheEpoch: UInt64
    var hitCount: UInt64
  }

  private struct ResidentCompilation {
    let resident: ResidentBlock?
    let emitterDeclineByteCount: Int?
    let declineReason: DoryARM64CompilationDeclineReason?
  }

  private struct NativeTraceEntry {
    let guestStart: UInt64
    let resident: ResidentBlock
    let codeCacheEpoch: UInt64
  }

  private struct NativeTraceValidation: Hashable {
    let guestStart: UInt64
    let guestByteCount: Int
    let memoryCodeGeneration: UInt64
  }

  private struct NativeTrace {
    let key: LookupKey
    let codeCacheEpoch: UInt64
    let offsets: [Int]
    let expectedGuestRIPs: [UInt64]
    let guestInstructionCounts: [UInt32]
    let totalGuestInstructionCount: Int
    let validations: [NativeTraceValidation]
  }

  private enum NativeTraceReplayResult {
    case executed(NativeReplay)
    case invalid
    case unavailable
  }

  private struct NativeReplay {
    let guestInstructionCount: Int
    let residentBlockCount: Int
    let exitCode: DoryJITExitCode
  }

  private enum QwordCopyLoopAttempt {
    case unavailable
    case requiresInterpreter
    case executed(DoryARM64ExecutionSummary)
  }

  private static let qwordCopyLoopBytes: [UInt8] = [
    0x48, 0x8b, 0x0c, 0x06, 0x48, 0x89, 0x0c, 0x07,
    0x48, 0x83, 0xc0, 0x08, 0x48, 0x89, 0xd1, 0x48,
    0x29, 0xc1, 0x48, 0x83, 0xf9, 0x07, 0x77, 0xe8,
  ]

  private static let arithmeticFlagMask: UInt64 =
    DoryX86RFLAGS.carry.rawValue
    | DoryX86RFLAGS.parity.rawValue
    | DoryX86RFLAGS.auxiliaryCarry.rawValue
    | DoryX86RFLAGS.zero.rawValue
    | DoryX86RFLAGS.sign.rawValue
    | DoryX86RFLAGS.overflow.rawValue

  private struct ResidentExecution {
    let resident: ResidentBlock
    let exitCode: DoryJITExitCode
  }

  public let maximumCodeBytes: Int
  private let lock = NSLock()
  private let decoder: DoryX86Decoder
  private let cpuProfileIdentifier: String
  private let physicalAddressBits: UInt8
  private let profile: DoryX86CPUProfile
  private let emitter: DoryARM64BaselineEmitter
  private let optimization: DoryARM64JITOptimization
  private let optimizer: DoryIROptimizer
  private let region: DoryJITExecutableRegion
  private var entries: [LookupKey: ResidentBlock] = [:]
  private var sharedCodeEntries: [SharedCodeKey: ResidentBlock] = [:]
  private var recentEntries: [RecentResidentBlock?] = .init(repeating: nil, count: 256)
  private var nativeTraces: [NativeTrace?] = .init(repeating: nil, count: 4_096)
  private var negativeEntries: [NegativeEntry?] = .init(repeating: nil, count: 4_096)
  private var nativeBatchExecutionCountValue: UInt64 = 0
  private var recentLookupHitCount: UInt64 = 0
  private var dictionaryLookupHitCount: UInt64 = 0
  private var lookupMissCount: UInt64 = 0
  private var memoryGenerationHitCount: UInt64 = 0
  private var byteValidationHitCount: UInt64 = 0
  private var sharedCodeHitCount: UInt64 = 0
  private var compiledBlockCount: UInt64 = 0
  private var declinedCompilationCount: UInt64 = 0
  private var negativeCacheHitCount: UInt64 = 0
  private var negativeCacheMissCount: UInt64 = 0
  private var negativeGenerationMismatchCount: UInt64 = 0
  private var codeCacheWrapCount: UInt64 = 0
  private var nativeTraceAttemptCount: UInt64 = 0
  private var nativeTraceReplayCount: UInt64 = 0
  private var codeGenerationCheckCount: UInt64 = 0
  private var codeGenerationMismatchCount: UInt64 = 0
  private var chainedExecutionCallCount: UInt64 = 0
  private var chainedRequestedInstructionCount: UInt64 = 0
  private var chainedRetiredInstructionCount: UInt64 = 0
  private var codeCacheEpoch: UInt64 = 0
  private var nextOffset = 0

  public init(
    maximumCodeBytes: Int = DoryARM64BaselineExecutor.defaultMaximumCodeBytes,
    decoder: DoryX86Decoder = .init(),
    cpuProfileIdentifier: String = DoryX86CPUProfile.compatibleV1Identifier,
    physicalAddressBits: UInt8 = DoryX86CPUProfile.compatibleV1.physicalAddressBits,
    profile: DoryX86CPUProfile = .compatibleV1,
    emitter: DoryARM64BaselineEmitter = .init(),
    optimization: DoryARM64JITOptimization = .baseline,
    optimizer: DoryIROptimizer = .init()
  ) throws {
    guard (32...52).contains(physicalAddressBits) else {
      throw DoryX86StateError.invalidPhysicalAddressBits(physicalAddressBits)
    }
    self.maximumCodeBytes = max(4_096, maximumCodeBytes)
    self.decoder = decoder
    self.cpuProfileIdentifier = cpuProfileIdentifier
    self.physicalAddressBits = physicalAddressBits
    self.profile = profile
    self.emitter = emitter
    self.optimization = optimization
    self.optimizer = optimizer
    region = try DoryJITExecutableRegion(minimumCapacity: self.maximumCodeBytes)
  }

  public var residentBlockCount: Int { lock.withLock { entries.count } }
  public var residentByteCount: Int { lock.withLock { nextOffset } }
  public var nativeBatchExecutionCount: UInt64 {
    lock.withLock { nativeBatchExecutionCountValue }
  }
  public var diagnostics: DoryARM64BaselineExecutorDiagnostics {
    lock.withLock {
      let negativeCacheHotSites = negativeEntries.compactMap { entry in
        guard let entry, entry.hitCount > 0 else { return nil }
        let lookup = entry.key.lookupKey
        return DoryARM64NegativeCacheHotSite(
          guestRIP: lookup.guestStart,
          executionMode: lookup.executionMode,
          instructionBudget: entry.key.instructionBudget,
          addressSpaceID: lookup.addressSpaceID,
          privilegeLevel: lookup.privilegeLevel,
          pagingEnabled: lookup.pagingEnabled,
          guestByteCount: entry.guestByteCount,
          instructionBytes: entry.instructionBytes,
          declineReason: entry.declineReason,
          hitCount: entry.hitCount
        )
      }.sorted(by: Self.negativeHotSitePrecedes)
      return .init(
        recentLookupHits: recentLookupHitCount,
        dictionaryLookupHits: dictionaryLookupHitCount,
        lookupMisses: lookupMissCount,
        memoryGenerationHits: memoryGenerationHitCount,
        byteValidationHits: byteValidationHitCount,
        sharedCodeHits: sharedCodeHitCount,
        compiledBlocks: compiledBlockCount,
        declinedCompilations: declinedCompilationCount,
        negativeCacheHits: negativeCacheHitCount,
        negativeCacheMisses: negativeCacheMissCount,
        negativeGenerationMismatches: negativeGenerationMismatchCount,
        negativeEntryCount: UInt64(negativeEntries.lazy.compactMap { $0 }.count),
        negativeCacheHotSites: Array(negativeCacheHotSites.prefix(16)),
        codeCacheWraps: codeCacheWrapCount,
        nativeTraceAttempts: nativeTraceAttemptCount,
        nativeTraceReplays: nativeTraceReplayCount,
        codeGenerationChecks: codeGenerationCheckCount,
        codeGenerationMismatches: codeGenerationMismatchCount,
        chainedExecutionCalls: chainedExecutionCallCount,
        chainedRequestedInstructions: chainedRequestedInstructionCount,
        chainedRetiredInstructions: chainedRetiredInstructionCount
      )
    }
  }

  public func invalidateAll() {
    lock.withLock {
      entries.removeAll(keepingCapacity: true)
      sharedCodeEntries.removeAll(keepingCapacity: true)
      recentEntries = .init(repeating: nil, count: recentEntries.count)
      nativeTraces = .init(repeating: nil, count: nativeTraces.count)
      negativeEntries = .init(repeating: nil, count: negativeEntries.count)
      codeCacheEpoch &+= 1
      nextOffset = 0
    }
  }

  /// Removes lookup visibility while holding the same lock used for native execution. Retired
  /// slots are not reused individually; a whole-region wrap happens only under this lock, after
  /// every execution using the prior generation has quiesced.
  public func invalidate(addressSpaceID: UInt64, guestRange: Range<UInt64>) {
    lock.withLock {
      let victims = entries.filter { key, resident in
        guard key.addressSpaceID == addressSpaceID else { return false }
        let blockRange = key.guestStart..<(key.guestStart &+ UInt64(resident.block.guestByteCount))
        return blockRange.overlaps(guestRange)
      }.map(\.key)
      for key in victims { entries.removeValue(forKey: key) }
      recentEntries = .init(repeating: nil, count: recentEntries.count)
      nativeTraces = .init(repeating: nil, count: nativeTraces.count)
      for index in negativeEntries.indices {
        guard let negative = negativeEntries[index],
          negative.key.lookupKey.addressSpaceID == addressSpaceID
        else { continue }
        let start = negative.key.lookupKey.guestStart
        let end = start.addingReportingOverflow(UInt64(negative.guestByteCount))
        if end.overflow
          || (start < guestRange.upperBound && guestRange.lowerBound < end.partialValue)
        {
          negativeEntries[index] = nil
        }
      }
    }
  }

  public func execute(
    bytes: [UInt8],
    at guestStart: UInt64,
    mode: DoryX86ExecutionMode,
    addressSpaceID: UInt64,
    maximumInstructions: Int,
    state: inout DoryX86ArchitecturalState,
    memory: (any DoryX86Memory)? = nil
  ) throws -> DoryARM64BaselineExecution? {
    try execute(
      byteProvider: { count in Array(bytes.prefix(count)) },
      at: guestStart,
      mode: mode,
      addressSpaceID: addressSpaceID,
      maximumInstructions: maximumInstructions,
      state: &state,
      memory: memory
    )
  }

  /// Fetches only the exact resident guest bytes on a cache hit. Callers backed by translated
  /// memory avoid re-reading and hashing the full worst-case 15 bytes per instruction on every
  /// dispatch while still detecting self-modifying code before native execution.
  public func execute(
    byteProvider: (_ maximumCount: Int) throws -> [UInt8],
    codeGenerationProvider: ((_ byteCount: Int) throws -> UInt64?)? = nil,
    at guestStart: UInt64,
    mode: DoryX86ExecutionMode,
    addressSpaceID: UInt64,
    maximumInstructions: Int,
    state: inout DoryX86ArchitecturalState,
    memory: (any DoryX86Memory)? = nil
  ) throws -> DoryARM64BaselineExecution? {
    guard
      let execution = try executeResident(
        byteProvider: byteProvider,
        codeGenerationProvider: codeGenerationProvider,
        at: guestStart,
        mode: mode,
        addressSpaceID: addressSpaceID,
        maximumInstructions: maximumInstructions,
        state: &state,
        memory: memory
      )
    else { return nil }
    return .init(block: execution.resident.block, exitCode: execution.exitCode)
  }

  /// Executes through the same validated resident-block path while returning only the fields a
  /// machine dispatcher consumes. This avoids retaining and releasing compiled code arrays for
  /// every guest block.
  public func executeSummary(
    byteProvider: (_ maximumCount: Int) throws -> [UInt8],
    codeGenerationProvider: ((_ byteCount: Int) throws -> UInt64?)? = nil,
    at guestStart: UInt64,
    mode: DoryX86ExecutionMode,
    addressSpaceID: UInt64,
    maximumInstructions: Int,
    state: inout DoryX86ArchitecturalState,
    memory: (any DoryX86Memory)? = nil
  ) throws -> DoryARM64ExecutionSummary? {
    guard
      let execution = try executeResident(
        byteProvider: byteProvider,
        codeGenerationProvider: codeGenerationProvider,
        at: guestStart,
        mode: mode,
        addressSpaceID: addressSpaceID,
        maximumInstructions: maximumInstructions,
        state: &state,
        memory: memory
      )
    else { return nil }
    return .init(
      guestInstructionCount: execution.resident.block.guestInstructionCount,
      residentBlockCount: 1,
      tier: execution.resident.block.tier,
      exitCode: execution.exitCode
    )
  }

  /// Runs consecutive resident basic blocks while the machine's interrupt deadline permits it.
  /// The execution context crosses block boundaries without round-tripping all architectural
  /// registers through Swift. System, port-I/O, halt, and restartable-memory exits still return at
  /// their exact boundary, and a block that cannot enter native code remains an interpreter step.
  public func executeChainedSummary(
    byteProvider: (_ guestStart: UInt64, _ maximumCount: Int) throws -> [UInt8],
    codeGenerationProvider: ((_ guestStart: UInt64, _ byteCount: Int) throws -> UInt64?)? = nil,
    at guestStart: UInt64,
    mode: DoryX86ExecutionMode,
    addressSpaceID: UInt64,
    maximumInstructions: Int,
    state: inout DoryX86ArchitecturalState,
    memory: (any DoryX86Memory)? = nil
  ) throws -> DoryARM64ExecutionSummary? {
    guard maximumInstructions > 0, state.interruptShadow == nil,
      !state.rflags.contains(.virtual8086),
      !state.rflags.contains(.resume),
      !DoryX86AlignmentPolicy.isEnabled(state: state),
      mode == .long64 || (mode == .protected32 && state.cs.base == 0 && state.cs.limit == .max)
    else { return nil }
    // Fall back before fetch, optimized copies or native state publication. The interpreter
    // reports the precise fault for a malformed/missing legacy PAE latch.
    do { try state.control.validateLegacyPAEPDPTEs(physicalAddressBits: physicalAddressBits) }
    catch { return nil }
    return try lock.withLock {
      chainedExecutionCallCount &+= 1
      chainedRequestedInstructionCount &+= UInt64(maximumInstructions)
      switch try executeQwordCopyLoop(
        byteProvider: byteProvider,
        guestStart: guestStart,
        mode: mode,
        maximumInstructions: maximumInstructions,
        state: &state,
        memory: memory
      ) {
      case .executed(let accelerated):
        chainedRetiredInstructionCount &+= UInt64(accelerated.guestInstructionCount)
        return accelerated
      case .requiresInterpreter:
        return nil
      case .unavailable:
        break
      }
      // Capability conformance is fixed for this memory object. Resolve it lazily once per
      // chain; callback failure and restartable-read policy still belong to each block.
      var memoryCapabilities: DoryJITMemoryCapabilities?
      return try withUnsafeTemporaryAllocation(
        of: UInt64.self,
        capacity: DoryJITExecutableRegion.contextWordCount
      ) { context in
        try withUnsafeTemporaryAllocation(
          of: UInt64.self,
          capacity: DoryJITExecutableRegion.contextWordCount
        ) { checkpoint in
          Self.populateExecutionContext(context, from: state)
          var completed = 0
          var blockCount = 0
          let traceKey = makeLookupKey(
            guestStart: guestStart,
            addressSpaceID: addressSpaceID,
            mode: mode,
            state: state
          )
          let traceIndex = nativeTraceIndex(for: traceKey)
          var recordedTrace = nativeTraces[traceIndex].flatMap {
            $0.key == traceKey ? $0 : nil
          }
          if recordedTrace != nil { nativeTraceAttemptCount &+= 1 }
          if let trace = recordedTrace {
            switch try replayNativeTrace(
              trace,
              codeGenerationProvider: codeGenerationProvider,
              maximumInstructions: maximumInstructions,
              context: context
            ) {
            case .executed(let replay):
              nativeTraceReplayCount &+= 1
              completed = replay.guestInstructionCount
              blockCount = replay.residentBlockCount
              if replay.exitCode != .dispatch || completed >= maximumInstructions {
                chainedRetiredInstructionCount &+= UInt64(completed)
                Self.apply(context: context, to: &state)
                return DoryARM64ExecutionSummary(
                  guestInstructionCount: UInt32(completed),
                  residentBlockCount: UInt32(blockCount),
                  tier: optimization == .optimizing ? .optimizing : .baseline,
                  exitCode: replay.exitCode
                )
              }
            case .invalid:
              nativeTraces[traceIndex] = nil
              recordedTrace = nil
            case .unavailable:
              break
            }
          }
          var newTrace: [NativeTraceEntry] = []
          var recordsTrace = recordedTrace == nil && completed == 0
          while completed < maximumInstructions {
            let currentRIP = context[16]
            let remaining = maximumInstructions - completed
            let residentInstructionBudget = min(
              remaining, Self.maximumResidentInstructionBudget)
            guard
              let resident = try resolveResident(
                byteProvider: { try byteProvider(currentRIP, $0) },
                codeGenerationProvider: codeGenerationProvider.map { provider in
                  { try provider(currentRIP, $0) }
                },
                at: currentRIP,
                mode: mode,
                addressSpaceID: addressSpaceID,
                maximumInstructions: residentInstructionBudget,
                state: state,
                memory: memory
              )
            else {
              publishNativeTrace(newTrace, for: traceKey, if: recordsTrace)
              guard completed > 0 else { return nil }
              chainedRetiredInstructionCount &+= UInt64(completed)
              Self.apply(context: context, to: &state)
              return DoryARM64ExecutionSummary(
                guestInstructionCount: UInt32(completed),
                residentBlockCount: UInt32(blockCount),
                tier: optimization == .optimizing ? .optimizing : .baseline,
                exitCode: .dispatch
              )
            }

            if recordsTrace {
              if resident.block.requiresMemoryCallbacks || resident.block.mayExitToInterpreter
                || resident.endsTimeBoundary
              {
                publishNativeTrace(newTrace, for: traceKey, if: true)
                recordsTrace = false
              } else {
                newTrace.append(.init(
                  guestStart: currentRIP,
                  resident: resident,
                  codeCacheEpoch: codeCacheEpoch
                ))
                if newTrace.count == Self.maximumRecordedNativeTraceBlocks {
                  publishNativeTrace(newTrace, for: traceKey, if: true)
                  recordsTrace = false
                }
              }
            }

            if resident.endsTimeBoundary, completed > 0 {
              publishNativeTrace(newTrace, for: traceKey, if: recordsTrace)
              chainedRetiredInstructionCount &+= UInt64(completed)
              Self.apply(context: context, to: &state)
              return DoryARM64ExecutionSummary(
                guestInstructionCount: UInt32(completed),
                residentBlockCount: UInt32(blockCount),
                tier: resident.block.tier,
                exitCode: .dispatch
              )
            }

            let hasCheckpoint = resident.block.requiresMemoryCallbacks || resident.block.mayExitToInterpreter
            if hasCheckpoint {
              for index in context.indices { checkpoint[index] = context[index] }
            }
            if resident.block.requiresMemoryCallbacks, memoryCapabilities == nil {
              memoryCapabilities = memory.map { DoryJITMemoryCapabilities(memory: $0) }
            }
            let exit = try region.executePrepared(
              at: resident.offset,
              context: context,
              memoryCapabilities: resident.block.requiresMemoryCallbacks ? memoryCapabilities : nil,
              requiresRestartableReads: resident.block.requiresRestartableMemoryReads
            )
            if exit == .interpreter, hasCheckpoint {
              publishNativeTrace(newTrace, for: traceKey, if: recordsTrace)
              for index in context.indices { context[index] = checkpoint[index] }
              guard completed > 0 else { return nil }
              chainedRetiredInstructionCount &+= UInt64(completed)
              Self.apply(context: context, to: &state)
              return DoryARM64ExecutionSummary(
                guestInstructionCount: UInt32(completed),
                residentBlockCount: UInt32(blockCount),
                tier: resident.block.tier,
                exitCode: .dispatch
              )
            }

            completed += Int(resident.block.guestInstructionCount)
            blockCount += 1
            guard exit == .dispatch, completed < maximumInstructions, !resident.endsTimeBoundary else {
              publishNativeTrace(newTrace, for: traceKey, if: recordsTrace)
              chainedRetiredInstructionCount &+= UInt64(completed)
              Self.apply(context: context, to: &state)
              return DoryARM64ExecutionSummary(
                guestInstructionCount: UInt32(completed),
                residentBlockCount: UInt32(blockCount),
                tier: resident.block.tier,
                exitCode: exit
              )
            }
          }
          preconditionFailure("positive chained execution must return from its bounded loop")
        }
      }
    }
  }

  private func executeQwordCopyLoop(
    byteProvider: (_ guestStart: UInt64, _ maximumCount: Int) throws -> [UInt8],
    guestStart: UInt64,
    mode: DoryX86ExecutionMode,
    maximumInstructions: Int,
    state: inout DoryX86ArchitecturalState,
    memory: (any DoryX86Memory)?
  ) throws -> QwordCopyLoopAttempt {
    guard mode == .long64, maximumInstructions >= 7,
      let bulkMemory = memory as? any DoryX86BulkMemory,
      state.rip == guestStart
    else { return .unavailable }
    let bytes = try speculativeInstructionBytes(
      using: { try byteProvider(guestStart, $0) },
      maximumCount: Self.qwordCopyLoopBytes.count
    )
    guard bytes == Self.qwordCopyLoopBytes,
      recognizesQwordCopyLoop(bytes, at: guestStart)
    else { return .unavailable }

    let offset = state.registers.rax
    guard offset <= UInt64.max - 8, state.registers.rdx >= offset + 8 else {
      return .unavailable
    }
    let remainingByteCount = state.registers.rdx - offset
    let requestedElementCount = min(
      Int(remainingByteCount / 8), maximumInstructions / 7, Int(UInt32.max / 7))
    guard requestedElementCount > 0 else { return .unavailable }
    // Keep wrapped effective-address cases on the architectural path, and
    // validate the complete accelerated span before a permissive bulk backend
    // can observe it. The interpreter must handle non-canonical elements.
    let (sourceAddress, sourceOverflow) = state.registers.rsi.addingReportingOverflow(offset)
    let (destinationAddress, destinationOverflow) =
      state.registers.rdi.addingReportingOverflow(offset)
    guard !sourceOverflow, !destinationOverflow else { return .requiresInterpreter }
    let requestedByteCount = UInt64(requestedElementCount) * 8
    guard
      Self.isCanonicalSpan(start: sourceAddress, byteCount: requestedByteCount),
      Self.isCanonicalSpan(start: destinationAddress, byteCount: requestedByteCount)
    else { return .requiresInterpreter }
    let (loopEnd, loopEndOverflow) = guestStart.addingReportingOverflow(
      UInt64(Self.qwordCopyLoopBytes.count))
    guard !loopEndOverflow else { return .unavailable }

    let copied: Int?
    do {
      copied = try bulkMemory.copyForwardNonoverlappingElements(
        from: sourceAddress,
        to: destinationAddress,
        elementByteCount: 8,
        maximumElementCount: requestedElementCount,
        excludingDestinationRanges: [guestStart..<loopEnd]
      )
    } catch {
      return .unavailable
    }
    guard let copiedElementCount = copied, copiedElementCount > 0,
      copiedElementCount <= requestedElementCount
    else { return .unavailable }

    let copiedByteCount = UInt64(copiedElementCount) * 8
    let nextOffset = offset + copiedByteCount
    let comparisonLeft = state.registers.rdx - nextOffset
    state.registers.rax = nextOffset
    state.registers.rcx = comparisonLeft
    state.rflags = Self.flagsAfterQuadwordSubtract(
      comparisonLeft,
      7,
      preserving: state.rflags
    )
    state.rip = comparisonLeft > 7 ? guestStart : loopEnd
    return .executed(
      .init(
        guestInstructionCount: UInt32(copiedElementCount * 7),
        residentBlockCount: UInt32(copiedElementCount * 2),
        tier: optimization == .optimizing ? .optimizing : .baseline,
        exitCode: .dispatch
      )
    )
  }

  private static func isCanonicalSpan(start: UInt64, byteCount: UInt64) -> Bool {
    guard byteCount > 0 else { return false }
    let last = start.addingReportingOverflow(byteCount - 1)
    return !last.overflow && DoryX86ArchitecturalState.isCanonical(start)
      && DoryX86ArchitecturalState.isCanonical(last.partialValue)
      && (start ^ last.partialValue) & (1 << 47) == 0
  }

  private func recognizesQwordCopyLoop(_ bytes: [UInt8], at guestStart: UInt64) -> Bool {
    let sourceMemory = DoryX86MemoryOperand(
      base: .rsi, index: .rax, width: .quadword)
    let destinationMemory = DoryX86MemoryOperand(
      base: .rdi, index: .rax, width: .quadword)
    let expected: [DoryX86InstructionOperation] = [
      .move(
        destination: .register(.rcx, width: .quadword),
        source: .memory(sourceMemory)
      ),
      .move(
        destination: .memory(destinationMemory),
        source: .register(.rcx, width: .quadword)
      ),
      .alu(
        .add,
        destination: .register(.rax, width: .quadword),
        source: .immediate(8, width: .quadword)
      ),
      .move(
        destination: .register(.rcx, width: .quadword),
        source: .register(.rdx, width: .quadword)
      ),
      .alu(
        .subtract,
        destination: .register(.rcx, width: .quadword),
        source: .register(.rax, width: .quadword)
      ),
      .alu(
        .compare,
        destination: .register(.rcx, width: .quadword),
        source: .immediate(7, width: .quadword)
      ),
      .conditionalJump(.above, relative: -24),
    ]
    var offset = 0
    for operation in expected {
      guard offset < bytes.count else { return false }
      let address = guestStart &+ UInt64(offset)
      guard
        let instruction = try? decoder.decode(
          Array(bytes[offset...]), at: address, mode: .long64),
        instruction.operation == operation
      else { return false }
      offset += Int(instruction.length)
    }
    return offset == bytes.count
  }

  private static func flagsAfterQuadwordSubtract(
    _ lhs: UInt64,
    _ rhs: UInt64,
    preserving flags: DoryX86RFLAGS
  ) -> DoryX86RFLAGS {
    let result = lhs &- rhs
    var raw = flags.rawValue & ~arithmeticFlagMask
    if lhs < rhs { raw |= DoryX86RFLAGS.carry.rawValue }
    if ((lhs ^ rhs) & (lhs ^ result) & (1 << 63)) != 0 {
      raw |= DoryX86RFLAGS.overflow.rawValue
    }
    if ((lhs ^ rhs ^ result) & 0x10) != 0 {
      raw |= DoryX86RFLAGS.auxiliaryCarry.rawValue
    }
    if result == 0 { raw |= DoryX86RFLAGS.zero.rawValue }
    if result & (1 << 63) != 0 { raw |= DoryX86RFLAGS.sign.rawValue }
    if (result & 0xff).nonzeroBitCount.isMultiple(of: 2) {
      raw |= DoryX86RFLAGS.parity.rawValue
    }
    raw |= DoryX86RFLAGS.reservedOne.rawValue
    return DoryX86RFLAGS(rawValue: raw)
  }

  private func executeResident(
    byteProvider: (_ maximumCount: Int) throws -> [UInt8],
    codeGenerationProvider: ((_ byteCount: Int) throws -> UInt64?)?,
    at guestStart: UInt64,
    mode: DoryX86ExecutionMode,
    addressSpaceID: UInt64,
    maximumInstructions: Int,
    state: inout DoryX86ArchitecturalState,
    memory: (any DoryX86Memory)?
  ) throws -> ResidentExecution? {
    guard maximumInstructions > 0, state.interruptShadow == nil,
      !state.rflags.contains(.virtual8086),
      !state.rflags.contains(.resume),
      !DoryX86AlignmentPolicy.isEnabled(state: state),
      mode == .long64 || (mode == .protected32 && state.cs.base == 0 && state.cs.limit == .max)
    else { return nil }
    do { try state.control.validateLegacyPAEPDPTEs(physicalAddressBits: physicalAddressBits) }
    catch { return nil }
    return try lock.withLock { () -> ResidentExecution? in
      guard
        let resident = try resolveResident(
          byteProvider: byteProvider,
          codeGenerationProvider: codeGenerationProvider,
          at: guestStart,
          mode: mode,
          addressSpaceID: addressSpaceID,
          maximumInstructions: maximumInstructions,
          state: state,
          memory: memory
        )
      else { return nil }

      return try withUnsafeTemporaryAllocation(
        of: UInt64.self,
        capacity: DoryJITExecutableRegion.contextWordCount
      ) { context in
        Self.populateExecutionContext(context, from: state)
        let exit = try region.execute(
          at: resident.offset,
          context: context,
          memory: memory,
          requiresRestartableReads: resident.block.requiresRestartableMemoryReads
        )
        if exit == .interpreter,
          resident.block.requiresMemoryCallbacks || resident.block.mayExitToInterpreter
        {
          return ResidentExecution(resident: resident, exitCode: exit)
        }
        Self.apply(context: context, to: &state)
        return ResidentExecution(resident: resident, exitCode: exit)
      }
    }
  }

  /// Resolves a block while the executor lock is held. Callers must not retain the returned region
  /// authority past that lock because a later compilation may wrap the bounded code cache.
  private func resolveResident(
    byteProvider: (_ maximumCount: Int) throws -> [UInt8],
    codeGenerationProvider: ((_ byteCount: Int) throws -> UInt64?)?,
    at guestStart: UInt64,
    mode: DoryX86ExecutionMode,
    addressSpaceID: UInt64,
    maximumInstructions: Int,
    state: DoryX86ArchitecturalState,
    memory: (any DoryX86Memory)?
  ) throws -> ResidentBlock? {
    let key = makeLookupKey(
      guestStart: guestStart,
      addressSpaceID: addressSpaceID,
      mode: mode,
      state: state
    )
    let negativeKey = NegativeLookupKey(
      lookupKey: key,
      instructionBudget: maximumInstructions
    )
    if let cached = lookupResident(for: key) {
      // The interrupt deadline is an execution constraint, not part of guest code identity. A
      // previously compiled shorter block is safe to reuse under a larger budget. If the resident
      // block is longer than this dispatch may retire, take one precise interpreter step instead
      // of compiling and replacing the same RIP for every transient deadline.
      guard cached.block.guestInstructionCount <= maximumInstructions else { return nil }
      let byteCount = Int(cached.block.guestByteCount)
      let memoryGeneration = readCodeGeneration(
        using: codeGenerationProvider,
        byteCount: byteCount
      )
      if let cachedMemoryGeneration = cached.memoryCodeGeneration,
        cachedMemoryGeneration == memoryGeneration
      {
        memoryGenerationHitCount &+= 1
        return cached
      }
      if cached.memoryCodeGeneration != nil { codeGenerationMismatchCount &+= 1 }
      let currentBytes = try speculativeInstructionBytes(using: byteProvider, maximumCount: byteCount)
      let generation = Self.fingerprint(bytes: currentBytes, mode: mode)
      // A replacement can be shorter than the cached block, including at a fetch
      // boundary. Invalidate and decode the available bytes before declining it.
      if currentBytes.count == byteCount, generation == cached.codeGeneration {
        byteValidationHitCount &+= 1
        let resident = ResidentBlock(
          block: cached.block,
          offset: cached.offset,
          codeGeneration: cached.codeGeneration,
          memoryCodeGeneration: memoryGeneration,
          endsTimeBoundary: cached.endsTimeBoundary
        )
        publish(resident, for: key)
        return resident
      }
      removeResident(for: key)
    }
    if negativeCacheHit(
      for: negativeKey,
      codeGenerationProvider: codeGenerationProvider
    ) {
      return nil
    }
    let bytes = try speculativeInstructionBytes(
      using: byteProvider, maximumCount: maximumInstructions * 15)
    if let shared = sharedCodeEntries[makeSharedCodeKey(from: key)],
      shared.block.guestInstructionCount <= maximumInstructions,
      !shared.block.requiresMemoryCallbacks || memory != nil
    {
      let byteCount = Int(shared.block.guestByteCount)
      if bytes.count >= byteCount {
        let guestBytes = Array(bytes.prefix(byteCount))
        let generation = Self.fingerprint(bytes: guestBytes, mode: mode)
        if generation == shared.codeGeneration {
          sharedCodeHitCount &+= 1
          let resident = ResidentBlock(
            block: shared.block,
            offset: shared.offset,
            codeGeneration: shared.codeGeneration,
            memoryCodeGeneration: readCodeGeneration(
              using: codeGenerationProvider,
              byteCount: byteCount
            ),
            endsTimeBoundary: shared.endsTimeBoundary
          )
          publish(resident, for: key)
          return resident
        }
      }
    }
    let compilation = try compileResident(
      key: key,
      bytes: bytes,
      codeGenerationProvider: codeGenerationProvider,
      guestStart: guestStart,
      mode: mode,
      maximumInstructions: maximumInstructions,
      memory: memory
    )
    if let resident = compilation.resident {
      removeNegativeEntry(for: negativeKey)
      return resident
    }
    declinedCompilationCount &+= 1
    if let guestByteCount = compilation.emitterDeclineByteCount,
      let declineReason = compilation.declineReason
    {
      publishNegativeEntry(
        for: negativeKey,
        guestByteCount: guestByteCount,
        declineReason: declineReason,
        originalBytes: bytes,
        byteProvider: byteProvider,
        codeGenerationProvider: codeGenerationProvider
      )
    }
    return nil
  }

  private func speculativeInstructionBytes(
    using provider: (Int) throws -> [UInt8],
    maximumCount: Int
  ) throws -> [UInt8] {
    do { return try provider(maximumCount) }
    catch is DoryX86MemoryError {
      // Guest fetch failures decline native execution, including when a preceding
      // block in the chain already committed stores. The caller publishes that
      // prefix before the interpreter retries the fetch at the faulting RIP.
      return []
    }
  }

  private func compileResident(
    key: LookupKey,
    bytes: [UInt8],
    codeGenerationProvider: ((_ byteCount: Int) throws -> UInt64?)?,
    guestStart: UInt64,
    mode: DoryX86ExecutionMode,
    maximumInstructions: Int,
    memory: (any DoryX86Memory)?
  ) throws -> ResidentCompilation {
    guard !bytes.isEmpty else {
      return .init(resident: nil, emitterDeclineByteCount: nil, declineReason: nil)
    }
    let translated: DoryIRBasicBlock
    do {
      translated = try DoryX86IRTranslator(
        decoder: decoder,
        instructionBudget: maximumInstructions
      ).translate(bytes, at: guestStart, mode: mode)
    } catch is DoryX86DecodeError {
      // Speculative bytes may stop inside the first instruction at a page boundary.
      // Decline this block without caching that incomplete view. The chain caller
      // publishes completed prefixes before the interpreter performs its precise
      // fetch, distinguishing a missing page from an invalid instruction.
      return .init(resident: nil, emitterDeclineByteCount: nil, declineReason: nil)
    }
    // CMOV is the feature-dependent integer operation currently emitted natively.
    // Reject before optimization can erase it and before any block prefix executes.
    // The immutable profile applies to every resident/shared/trace cache in this
    // executor, so a masked profile cannot reuse code compiled with CMOV enabled.
    if !profile.supports(.cmov), translated.statements.contains(where: {
      if case .conditionalMove = $0 { return true }
      return false
    }) {
      return .init(resident: nil, emitterDeclineByteCount: nil, declineReason: nil)
    }
    if translated.statements.contains(where: {
      guard case .memoryFence(let kind) = $0 else { return false }
      return !profile.supports(kind == .store ? .sse : .sse2)
    }) {
      return .init(resident: nil, emitterDeclineByteCount: nil, declineReason: nil)
    }
    let containsTimestampCounter = translated.statements.contains {
      if case .readTimestampCounter = $0 { return true }
      return false
    }
    if containsTimestampCounter {
      guard profile.supports(.tsc), mode == .long64, key.privilegeLevel == 0 else {
        return .init(resident: nil, emitterDeclineByteCount: nil, declineReason: nil)
      }
    }
    let block = optimization == .optimizing ? optimizer.optimize(translated).block : translated
    // The native context carries GPRs/RIP/flags, but cannot raise a privileged
    // instruction fault. Let the interpreter deliver #GP at the original HLT.
    // Both resident and shared-code lookup keys include this privilege level.
    if key.privilegeLevel != 0, mode != .real16,
      case .exit(.halt, _) = block.terminator
    {
      return .init(resident: nil, emitterDeclineByteCount: nil, declineReason: nil)
    }
    if key.privilegeLevel != 0,
      block.statements.contains(where: {
        if case .clearInterruptFlag = $0 { return true }
        return false
      })
    {
      return .init(resident: nil, emitterDeclineByteCount: nil, declineReason: nil)
    }
    if key.privilegeLevel != 0,
      block.statements.contains(where: {
        if case .compareExchange = $0 { return true }
        return false
      })
    {
      return .init(resident: nil, emitterDeclineByteCount: nil, declineReason: nil)
    }
    if key.privilegeLevel != 0,
      block.statements.contains(where: {
        switch $0 {
        case .unsignedAccumulatorMultiply, .unsignedAccumulatorDivide, .doubleShiftRightCL,
          .doubleShiftRightImmediate, .bitTestMemoryImmediate:
          return true
        default:
          return false
        }
      })
    {
      return .init(resident: nil, emitterDeclineByteCount: nil, declineReason: nil)
    }
    let compiled = emitter.compile(
      block,
      tier: optimization == .optimizing ? .optimizing : .baseline,
      executionMode: mode
    )
    if compiled.tier == .interpreterFallback {
      let declineReason = Self.compilationDeclineReason(for: block)
      return .init(
        resident: nil,
        emitterDeclineByteCount: Int(compiled.guestByteCount),
        declineReason: declineReason
      )
    }
    guard compiled.guestInstructionCount > 0,
      compiled.guestInstructionCount <= maximumInstructions,
      !compiled.requiresMemoryCallbacks || memory != nil
    else { return .init(resident: nil, emitterDeclineByteCount: nil, declineReason: nil) }
    let byteCount = compiled.machineBytes.count
    guard byteCount <= region.capacity else {
      return .init(resident: nil, emitterDeclineByteCount: nil, declineReason: nil)
    }
    if nextOffset > region.capacity - byteCount {
      entries.removeAll(keepingCapacity: true)
      sharedCodeEntries.removeAll(keepingCapacity: true)
      recentEntries = .init(repeating: nil, count: recentEntries.count)
      nativeTraces = .init(repeating: nil, count: nativeTraces.count)
      negativeEntries = .init(repeating: nil, count: negativeEntries.count)
      codeCacheEpoch &+= 1
      nextOffset = 0
      codeCacheWrapCount &+= 1
    }
    let offset = nextOffset
    try region.publish(compiled, at: offset)
    nextOffset += byteCount
    let guestBytes = Array(bytes.prefix(Int(compiled.guestByteCount)))
    let memoryCodeGeneration = readCodeGeneration(
      using: codeGenerationProvider,
      byteCount: guestBytes.count
    )
    let resident = ResidentBlock(
      block: compiled,
      offset: offset,
      codeGeneration: Self.fingerprint(bytes: guestBytes, mode: mode),
      memoryCodeGeneration: memoryCodeGeneration,
      endsTimeBoundary: Self.endsTimeBoundary(block)
    )
    publish(resident, for: key)
    compiledBlockCount &+= 1
    return .init(resident: resident, emitterDeclineByteCount: nil, declineReason: nil)
  }

  private static func endsTimeBoundary(_ block: DoryIRBasicBlock) -> Bool {
    block.statements.contains {
      if case .readTimestampCounter = $0 { return true }
      return false
    }
  }

  static func compilationDeclineReason(
    for block: DoryIRBasicBlock
  ) -> DoryARM64CompilationDeclineReason {
    block.statements.contains {
      if case .helper = $0 { return true }
      return false
    } ? .interpreterHelper : .nativeEmitter
  }

  private func makeLookupKey(
    guestStart: UInt64,
    addressSpaceID: UInt64,
    mode: DoryX86ExecutionMode,
    state: DoryX86ArchitecturalState
  ) -> LookupKey {
    LookupKey(
      guestStart: guestStart,
      addressSpaceID: addressSpaceID,
      executionMode: mode,
      privilegeLevel: UInt8(state.cs.selector & 3),
      pagingEnabled: state.control.cr0 & (1 << 31) != 0
    )
  }

  private func makeSharedCodeKey(from key: LookupKey) -> SharedCodeKey {
    SharedCodeKey(
      guestStart: key.guestStart,
      executionMode: key.executionMode,
      privilegeLevel: key.privilegeLevel,
      pagingEnabled: key.pagingEnabled
    )
  }

  /// A negative entry only suppresses native compilation; the caller still executes the exact
  /// instruction through the interpreter. Entries therefore remain a performance hint, and any
  /// missing or uncertain validation authority fails open to the normal compilation path.
  private func negativeCacheHit(
    for key: NegativeLookupKey,
    codeGenerationProvider: ((_ byteCount: Int) throws -> UInt64?)?
  ) -> Bool {
    let index = negativeIndex(for: key)
    guard let entry = negativeEntries[index], entry.key == key,
      entry.codeCacheEpoch == codeCacheEpoch,
      let codeGenerationProvider
    else {
      negativeCacheMissCount &+= 1
      return false
    }
    do {
      codeGenerationCheckCount &+= 1
      guard try codeGenerationProvider(entry.guestByteCount) == entry.memoryCodeGeneration else {
        codeGenerationMismatchCount &+= 1
        negativeGenerationMismatchCount &+= 1
        negativeCacheMissCount &+= 1
        negativeEntries[index] = nil
        return false
      }
      negativeCacheHitCount &+= 1
      var updatedEntry = entry
      if updatedEntry.hitCount < UInt64.max {
        updatedEntry.hitCount += 1
      }
      negativeEntries[index] = updatedEntry
      return true
    } catch {
      negativeCacheMissCount &+= 1
      return false
    }
  }

  private func publishNegativeEntry(
    for key: NegativeLookupKey,
    guestByteCount: Int,
    declineReason: DoryARM64CompilationDeclineReason,
    originalBytes: [UInt8],
    byteProvider: (_ maximumCount: Int) throws -> [UInt8],
    codeGenerationProvider: ((_ byteCount: Int) throws -> UInt64?)?
  ) {
    guard guestByteCount > 0, originalBytes.count >= guestByteCount,
      let codeGenerationProvider
    else { return }
    do {
      codeGenerationCheckCount &+= 1
      guard let generationBefore = try codeGenerationProvider(guestByteCount) else { return }
      let confirmedBytes = try byteProvider(guestByteCount)
      guard confirmedBytes.count == guestByteCount,
        confirmedBytes.elementsEqual(originalBytes.prefix(guestByteCount))
      else { return }
      let instruction = try decoder.decode(
        originalBytes.prefix(15),
        at: key.lookupKey.guestStart,
        mode: key.lookupKey.executionMode
      )
      codeGenerationCheckCount &+= 1
      guard try codeGenerationProvider(guestByteCount) == generationBefore else { return }
      negativeEntries[negativeIndex(for: key)] = .init(
        key: key,
        guestByteCount: guestByteCount,
        instructionBytes: instruction.bytes,
        declineReason: declineReason,
        memoryCodeGeneration: generationBefore,
        codeCacheEpoch: codeCacheEpoch,
        hitCount: 0
      )
    } catch {
      // This validation is an optional optimization. The pre-cache behavior for a declined
      // compilation is an interpreter fallback, so speculative validation failures must not turn
      // into machine failures.
    }
  }

  private func removeNegativeEntry(for key: NegativeLookupKey) {
    let index = negativeIndex(for: key)
    if negativeEntries[index]?.key == key { negativeEntries[index] = nil }
  }

  private func negativeIndex(for key: NegativeLookupKey) -> Int {
    let lookup = key.lookupKey
    var value = lookup.guestStart
    value ^= lookup.addressSpaceID &* 0xa076_1d64_78bd_642f
    value ^= UInt64(lookup.privilegeLevel) << 11
    value ^= lookup.pagingEnabled ? 1 << 17 : 0
    switch lookup.executionMode {
    case .real16: value ^= 0x11
    case .protected16: value ^= 0x22
    case .protected32: value ^= 0x33
    case .long64: value ^= 0x44
    }
    value ^= UInt64(truncatingIfNeeded: key.instructionBudget) &* 0xe703_7ed1_a0b4_28db
    value ^= value >> 32
    return Int(value & UInt64(negativeEntries.count - 1))
  }

  private static func negativeHotSitePrecedes(
    _ lhs: DoryARM64NegativeCacheHotSite,
    _ rhs: DoryARM64NegativeCacheHotSite
  ) -> Bool {
    if lhs.hitCount != rhs.hitCount { return lhs.hitCount > rhs.hitCount }
    if lhs.guestRIP != rhs.guestRIP { return lhs.guestRIP < rhs.guestRIP }
    if lhs.executionMode.rawValue != rhs.executionMode.rawValue {
      return lhs.executionMode.rawValue < rhs.executionMode.rawValue
    }
    if lhs.instructionBudget != rhs.instructionBudget {
      return lhs.instructionBudget < rhs.instructionBudget
    }
    if lhs.addressSpaceID != rhs.addressSpaceID { return lhs.addressSpaceID < rhs.addressSpaceID }
    if lhs.privilegeLevel != rhs.privilegeLevel { return lhs.privilegeLevel < rhs.privilegeLevel }
    return !lhs.pagingEnabled && rhs.pagingEnabled
  }

  private func replayNativeTrace(
    _ trace: NativeTrace,
    codeGenerationProvider: ((_ guestStart: UInt64, _ byteCount: Int) throws -> UInt64?)?,
    maximumInstructions: Int,
    context: UnsafeMutableBufferPointer<UInt64>
  ) throws -> NativeTraceReplayResult {
    guard trace.codeCacheEpoch == codeCacheEpoch else { return .invalid }
    guard trace.totalGuestInstructionCount <= maximumInstructions else { return .unavailable }
    guard let codeGenerationProvider else { return .invalid }
    for validation in trace.validations {
      codeGenerationCheckCount &+= 1
      guard (try? codeGenerationProvider(validation.guestStart, validation.guestByteCount))
        == validation.memoryCodeGeneration
      else {
        codeGenerationMismatchCount &+= 1
        return .invalid
      }
    }
    let execution = try region.executeBatch(
      offsets: trace.offsets,
      expectedGuestRIPs: trace.expectedGuestRIPs,
      guestInstructionCounts: trace.guestInstructionCounts,
      context: context
    )
    guard execution.residentBlockCount > 0 else { return .unavailable }
    nativeBatchExecutionCountValue &+= 1
    return .executed(NativeReplay(
      guestInstructionCount: Int(execution.guestInstructionCount),
      residentBlockCount: Int(execution.residentBlockCount),
      exitCode: execution.exitCode
    ))
  }

  private func readCodeGeneration(
    using provider: ((_ byteCount: Int) throws -> UInt64?)?,
    byteCount: Int
  ) -> UInt64? {
    guard let provider else { return nil }
    codeGenerationCheckCount &+= 1
    // A generation token is optional proof of cache validity. Losing that proof must use
    // byte validation, not unwind a chain that may already have committed guest stores.
    // Architectural instruction/data faults still follow their normal execution paths.
    return try? provider(byteCount)
  }

  private func publishNativeTrace(
    _ entries: [NativeTraceEntry],
    for key: LookupKey,
    if shouldPublish: Bool
  ) {
    guard shouldPublish, entries.count >= 2,
      entries.count <= Self.maximumRecordedNativeTraceBlocks,
      entries.allSatisfy({ $0.codeCacheEpoch == codeCacheEpoch })
    else { return }
    var validations: [NativeTraceValidation] = []
    var seenValidations = Set<NativeTraceValidation>()
    var totalGuestInstructionCount = 0
    for entry in entries {
      guard let generation = entry.resident.memoryCodeGeneration else { return }
      totalGuestInstructionCount += Int(entry.resident.block.guestInstructionCount)
      let validation = NativeTraceValidation(
        guestStart: entry.guestStart,
        guestByteCount: Int(entry.resident.block.guestByteCount),
        memoryCodeGeneration: generation
      )
      if seenValidations.insert(validation).inserted { validations.append(validation) }
    }
    nativeTraces[nativeTraceIndex(for: key)] = NativeTrace(
      key: key,
      codeCacheEpoch: codeCacheEpoch,
      offsets: entries.map(\.resident.offset),
      expectedGuestRIPs: entries.map(\.guestStart),
      guestInstructionCounts: entries.map(\.resident.block.guestInstructionCount),
      totalGuestInstructionCount: totalGuestInstructionCount,
      validations: validations
    )
  }

  private func nativeTraceIndex(for key: LookupKey) -> Int {
    var value = key.guestStart
    value ^= key.addressSpaceID &* 0xd6e8_feb8_6659_fd93
    value ^= UInt64(key.privilegeLevel) << 7
    value ^= key.pagingEnabled ? 1 << 13 : 0
    value ^= value >> 32
    return Int(value & UInt64(nativeTraces.count - 1))
  }

  private func lookupResident(for key: LookupKey) -> ResidentBlock? {
    let index = recentIndex(for: key)
    if let recent = recentEntries[index], recent.key == key {
      recentLookupHitCount &+= 1
      return recent.resident
    }
    guard let resident = entries[key] else {
      lookupMissCount &+= 1
      return nil
    }
    dictionaryLookupHitCount &+= 1
    recentEntries[index] = .init(key: key, resident: resident)
    return resident
  }

  private func publish(_ resident: ResidentBlock, for key: LookupKey) {
    entries[key] = resident
    sharedCodeEntries[makeSharedCodeKey(from: key)] = resident
    recentEntries[recentIndex(for: key)] = .init(key: key, resident: resident)
  }

  private func removeResident(for key: LookupKey) {
    entries.removeValue(forKey: key)
    let index = recentIndex(for: key)
    if recentEntries[index]?.key == key { recentEntries[index] = nil }
  }

  private func recentIndex(for key: LookupKey) -> Int {
    var value = key.guestStart
    value ^= key.addressSpaceID &* 0x9e37_79b9_7f4a_7c15
    value ^= UInt64(key.privilegeLevel) << 5
    value ^= key.pagingEnabled ? 1 << 9 : 0
    switch key.executionMode {
    case .real16: value ^= 0x11
    case .protected16: value ^= 0x22
    case .protected32: value ^= 0x33
    case .long64: value ^= 0x44
    }
    value ^= value >> 33
    return Int(value & UInt64(recentEntries.count - 1))
  }

  private static func populateExecutionContext(
    _ context: UnsafeMutableBufferPointer<UInt64>,
    from state: DoryX86ArchitecturalState
  ) {
    precondition(context.count == DoryJITExecutableRegion.contextWordCount)
    context[0] = state.registers.rax
    context[1] = state.registers.rcx
    context[2] = state.registers.rdx
    context[3] = state.registers.rbx
    context[4] = state.registers.rsp
    context[5] = state.registers.rbp
    context[6] = state.registers.rsi
    context[7] = state.registers.rdi
    context[8] = state.registers.r8
    context[9] = state.registers.r9
    context[10] = state.registers.r10
    context[11] = state.registers.r11
    context[12] = state.registers.r12
    context[13] = state.registers.r13
    context[14] = state.registers.r14
    context[15] = state.registers.r15
    context[16] = state.rip
    context[17] = state.rflags.rawValue
    context[18] = state.fs.base
    context[19] = state.gs.base
    context[20] = state.tsc
  }

  private static func apply(
    context: UnsafeMutableBufferPointer<UInt64>,
    to state: inout DoryX86ArchitecturalState
  ) {
    precondition(context.count == DoryJITExecutableRegion.contextWordCount)
    state.registers.rax = context[0]
    state.registers.rcx = context[1]
    state.registers.rdx = context[2]
    state.registers.rbx = context[3]
    state.registers.rsp = context[4]
    state.registers.rbp = context[5]
    state.registers.rsi = context[6]
    state.registers.rdi = context[7]
    state.registers.r8 = context[8]
    state.registers.r9 = context[9]
    state.registers.r10 = context[10]
    state.registers.r11 = context[11]
    state.registers.r12 = context[12]
    state.registers.r13 = context[13]
    state.registers.r14 = context[14]
    state.registers.r15 = context[15]
    state.rip = context[16]
    state.rflags = DoryX86RFLAGS(rawValue: context[17])
  }

  private static func fingerprint(bytes: [UInt8], mode: DoryX86ExecutionMode) -> UInt64 {
    var value: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in bytes + Array(mode.rawValue.utf8) {
      value ^= UInt64(byte)
      value &*= 0x0000_0100_0000_01b3
    }
    return value
  }
}
