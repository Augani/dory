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

  public init(
    guestStart: UInt64,
    guestByteCount: UInt32,
    guestInstructionCount: UInt32,
    machineWords: [UInt32],
    tier: DoryARM64CompilationTier,
    exitCode: DoryJITExitCode,
    requiresMemoryCallbacks: Bool = false
  ) {
    self.guestStart = guestStart
    self.guestByteCount = guestByteCount
    self.guestInstructionCount = guestInstructionCount
    self.machineWords = machineWords
    self.tier = tier
    self.exitCode = exitCode
    self.requiresMemoryCallbacks = requiresMemoryCallbacks
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
    tier: DoryARM64CompilationTier = .baseline
  ) -> DoryARM64CompiledBlock {
    precondition(tier != .interpreterFallback)
    var words: [UInt32] = []
    let usesMemory = block.statements.contains(where: requiresMemoryCallbacks)
    if usesMemory { emitMemoryPrologue(into: &words) }
    for statement in block.statements {
      guard emit(statement, into: &words) else {
        return fallback(block)
      }
    }
    guard let exit = emit(block.terminator, into: &words) else {
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
      requiresMemoryCallbacks: usesMemory
    )
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

  private func emitCopy(
    destination: DoryIROperand,
    source: DoryIROperand,
    into words: inout [UInt32]
  ) -> Bool {
    switch destination {
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
        guard case .register(let register) = source,
          register.bank == "x86.gpr", register.index < 16, register.width == width
        else { return false }
        words.append(
          encodeLoad64(register: 10, base: 0, byteOffset: Int(register.index) * 8))
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

  private func requiresMemoryCallbacks(_ statement: DoryIRStatement) -> Bool {
    switch statement {
    case .copy(let destination, let source),
      .binary(_, let destination, let source, _):
      if case .memory = destination { return true }
      if case .memory = source { return true }
      return false
    case .unary(let operation, let operand):
      _ = operation
      if case .memory = operand { return true }
      return false
    case .shift(_, let destination, _):
      if case .memory = destination { return true }
      return false
    case .signedMultiply(let destination, let lhs, let rhs):
      if case .memory = destination { return true }
      if case .memory = lhs { return true }
      if case .memory = rhs { return true }
      return false
    case .extendMove(_, let source, _):
      if case .memory = source { return true }
      return false
    case .effectiveAddress, .helper:
      return false
    }
  }

  private func emitSignedMultiply(
    destination: DoryIROperand,
    lhs: DoryIROperand,
    rhs: DoryIROperand,
    into words: inout [UInt32]
  ) -> Bool {
    guard case .register(let target) = destination, target.width == .i32,
      case .register(let left) = lhs, left.width == .i32,
      case .register(let right) = rhs, right.width == .i32,
      load(left, into: 9, words: &words),
      load(right, into: 10, words: &words)
    else { return false }

    words.append(encodeSignedMultiplyLong32(left: 9, right: 10, destination: 11))
    words.append(encodeSignExtend32To64(source: 11, destination: 12))
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: true, 11, 12, 31))
    words.append(encodeConditionalSet(register: 13, condition: .notEqual))
    words.append(encodeLoad64(register: 14, base: 0, byteOffset: Self.rflagsOffset))
    let overflowMask = DoryX86RFLAGS.carry.rawValue | DoryX86RFLAGS.overflow.rawValue
    emitImmediate(~overflowMask, register: 15, into: &words)
    words.append(encodeLogical(.and, left: 14, right: 15, destination: 14))
    words.append(encodeLogical(.or, left: 14, right: 13, destination: 14))
    words.append(encodeLogical(.or, left: 14, right: 13, shiftAmount: 11, destination: 14))
    words.append(encodeStore64(register: 14, base: 0, byteOffset: Self.rflagsOffset))
    words.append(encodeLogical(.or, is64Bit: false, 31, 11, 12))
    words.append(encodeStore64(register: 12, base: 0, byteOffset: Int(target.index) * 8))
    return true
  }

  private func emitExtendMove(
    destination: DoryIROperand,
    source: DoryIROperand,
    signed: Bool,
    into words: inout [UInt32]
  ) -> Bool {
    guard !signed, case .register(let target) = destination,
      target.bank == "x86.gpr", target.index < 16,
      target.width == .i32 || target.width == .i64
    else { return false }
    let sourceWidth: DoryIRIntegerWidth
    switch source {
    case .register(let register)
    where register.bank == "x86.gpr" && register.index < 16
      && (register.width == .i8 || register.width == .i16):
      sourceWidth = register.width
      words.append(encodeLoad64(register: 9, base: 0, byteOffset: Int(register.index) * 8))
    case .memory(let address, let width) where width == .i8 || width == .i16:
      guard emitMemoryAddress(address, into: 12, words: &words) else { return false }
      sourceWidth = width
      emitMemoryRead(addressRegister: 12, width: width, resultRegister: 9, words: &words)
    default:
      return false
    }
    emitImmediate(sourceWidth == .i8 ? 0xFF : 0xFFFF, register: 10, into: &words)
    words.append(encodeLogical(.and, left: 9, right: 10, destination: 9))
    words.append(encodeStore64(register: 9, base: 0, byteOffset: Int(target.index) * 8))
    return true
  }

  private func emitShift(
    _ operation: DoryIRShiftOperation,
    destination: DoryIROperand,
    count rawCount: UInt8,
    into words: inout [UInt32]
  ) -> Bool {
    guard case .register(let target) = destination,
      target.bank == "x86.gpr", target.index < 16,
      target.width == .i32 || target.width == .i64,
      load(target, into: 9, words: &words)
    else { return false }
    let is64Bit = target.width == .i64
    let bitCount: UInt32 = is64Bit ? 64 : 32
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
    return true
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
      0xA9BD_7BFD,  // stp x29,x30,[sp,#-48]!
      0x9100_03FD,  // mov x29,sp
      0xA901_53F3,  // stp x19,x20,[sp,#16]
      0xA902_5BF5,  // stp x21,x22,[sp,#32]
      0xAA00_03F3,  // mov x19,x0 (architectural context)
      0xAA01_03F4,  // mov x20,x1 (memory context)
      0xAA02_03F5,  // mov x21,x2 (read callback)
      0xAA03_03F6,  // mov x22,x3 (write callback)
    ]
  }

  private func emitMemoryEpilogue(into words: inout [UInt32]) {
    words += [
      0xA942_5BF5,  // ldp x21,x22,[sp,#32]
      0xA941_53F3,  // ldp x19,x20,[sp,#16]
      0xA8C3_7BFD,  // ldp x29,x30,[sp],#48
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

  private func emitBinary(
    _ operation: DoryIRBinaryOperation,
    destination: DoryIROperand,
    source: DoryIROperand,
    writesDestination: Bool,
    into words: inout [UInt32]
  ) -> Bool {
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
      emitMemoryAddress(address, into: 9, words: &words)
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
    words: inout [UInt32]
  ) -> Bool {
    guard address.segment == nil,
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
    into words: inout [UInt32]
  ) -> DoryJITExitCode? {
    let target: UInt64
    let exit: DoryJITExitCode
    switch terminator {
    case .next(let address), .branch(let address):
      target = address
      exit = .dispatch
    case .exit(let reason, let resumeAt):
      target = resumeAt
      exit =
        switch reason {
        case .halt: .halt
        case .system: .system
        case .portIO: .portIO
        case .interpreter, .indirectControl, .instructionBudget: .interpreter
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
      words.append(encodeStore64(register: 9, base: 0, byteOffset: Self.ripOffset))
      return .dispatch
    }
    emitImmediate(target, register: 9, into: &words)
    words.append(encodeStore64(register: 9, base: 0, byteOffset: Self.ripOffset))
    return exit
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

private final class DoryJITMemoryCallbackContext {
  let memory: any DoryX86Memory
  var failed = false

  init(memory: any DoryX86Memory) { self.memory = memory }
}

private let doryJITMemoryRead: dory_jit_memory_read_function = { opaque, address, byteCount in
  guard let opaque, [1, 2, 4, 8].contains(byteCount) else { return 0 }
  let context = Unmanaged<DoryJITMemoryCallbackContext>.fromOpaque(opaque).takeUnretainedValue()
  do {
    return try context.memory.read(at: address, byteCount: Int(byteCount)).enumerated().reduce(0) {
      $0 | UInt64($1.element) << UInt64($1.offset * 8)
    }
  } catch {
    context.failed = true
    return 0
  }
}

private let doryJITMemoryWrite: dory_jit_memory_write_function = {
  opaque, address, value, byteCount in
  guard let opaque, [1, 2, 4, 8].contains(byteCount) else { return }
  let context = Unmanaged<DoryJITMemoryCallbackContext>.fromOpaque(opaque).takeUnretainedValue()
  let bytes = (0..<Int(byteCount)).map {
    UInt8(truncatingIfNeeded: value >> UInt64($0 * 8))
  }
  do {
    try context.memory.validateWrite(at: address, byteCount: bytes.count)
    try context.memory.write(at: address, bytes: bytes)
  } catch {
    context.failed = true
  }
}

public final class DoryJITExecutableRegion: @unchecked Sendable {
  public static let contextWordCount = 18

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
    memory: (any DoryX86Memory)? = nil
  ) throws -> DoryJITExitCode {
    guard offset >= 0, offset.isMultiple(of: 4), offset < capacity else {
      throw DoryJITRuntimeError.invalidOffset(offset)
    }
    guard context.count == Self.contextWordCount else {
      throw DoryJITRuntimeError.invalidContextWordCount(context.count)
    }
    var rawExit: UInt32 = 0
    let memoryContext = memory.map(DoryJITMemoryCallbackContext.init)
    let result = context.withUnsafeMutableBufferPointer { buffer in
      dory_jit_region_execute(
        region,
        offset,
        buffer.baseAddress,
        memoryContext.map { Unmanaged.passUnretained($0).toOpaque() },
        doryJITMemoryRead,
        doryJITMemoryWrite,
        &rawExit
      )
    }
    guard result == 0 else { throw DoryJITRuntimeError.executionFailed(result) }
    if memoryContext?.failed == true { return .interpreter }
    guard let exit = DoryJITExitCode(rawValue: rawExit) else {
      throw DoryJITRuntimeError.invalidExitCode(rawExit)
    }
    return exit
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

/// Owns one bounded MAP_JIT region and dispatches exact, helper-free baseline blocks through it.
/// Unsupported blocks never enter executable memory and return `nil` so the caller can execute
/// the instruction at the unchanged guest RIP with the interpreter.
public final class DoryARM64BaselineExecutor: @unchecked Sendable {
  private struct ResidentBlock {
    let block: DoryARM64CompiledBlock
    let offset: Int
  }

  public let maximumCodeBytes: Int
  private let lock = NSLock()
  private let decoder: DoryX86Decoder
  private let cpuProfileIdentifier: String
  private let emitter: DoryARM64BaselineEmitter
  private let optimization: DoryARM64JITOptimization
  private let optimizer: DoryIROptimizer
  private let region: DoryJITExecutableRegion
  private var entries: [DoryJITBlockKey: ResidentBlock] = [:]
  private var nextOffset = 0

  public init(
    maximumCodeBytes: Int = 16 * 1024 * 1024,
    decoder: DoryX86Decoder = .init(),
    cpuProfileIdentifier: String = DoryX86CPUProfile.compatibleV1Identifier,
    emitter: DoryARM64BaselineEmitter = .init(),
    optimization: DoryARM64JITOptimization = .baseline,
    optimizer: DoryIROptimizer = .init()
  ) throws {
    self.maximumCodeBytes = max(4_096, maximumCodeBytes)
    self.decoder = decoder
    self.cpuProfileIdentifier = cpuProfileIdentifier
    self.emitter = emitter
    self.optimization = optimization
    self.optimizer = optimizer
    region = try DoryJITExecutableRegion(minimumCapacity: self.maximumCodeBytes)
  }

  public var residentBlockCount: Int { lock.withLock { entries.count } }
  public var residentByteCount: Int { lock.withLock { nextOffset } }

  public func invalidateAll() {
    lock.withLock {
      entries.removeAll(keepingCapacity: true)
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
    guard !bytes.isEmpty, maximumInstructions > 0 else { return nil }
    return try lock.withLock {
      let generation = Self.fingerprint(
        bytes: bytes,
        mode: mode,
        maximumInstructions: maximumInstructions
      )
      let key = DoryJITBlockKey(
        guestStart: guestStart,
        addressSpaceID: addressSpaceID,
        codeGeneration: generation,
        cpuProfileIdentifier: cpuProfileIdentifier,
        executionMode: mode,
        privilegeLevel: UInt8(state.cs.selector & 3),
        pagingEnabled: state.control.cr0 & (1 << 31) != 0
      )
      let resident: ResidentBlock
      if let cached = entries[key], cached.block.guestInstructionCount <= maximumInstructions {
        resident = cached
      } else {
        let translated = try DoryX86IRTranslator(
          decoder: decoder,
          instructionBudget: maximumInstructions
        ).translate(bytes, at: guestStart, mode: mode)
        let block =
          optimization == .optimizing ? optimizer.optimize(translated).block : translated
        let compiled = emitter.compile(
          block,
          tier: optimization == .optimizing ? .optimizing : .baseline
        )
        guard compiled.tier != .interpreterFallback,
          compiled.guestInstructionCount > 0,
          compiled.guestInstructionCount <= maximumInstructions,
          !compiled.requiresMemoryCallbacks || memory != nil
        else { return nil }
        let byteCount = compiled.machineBytes.count
        guard byteCount <= region.capacity else { return nil }
        if nextOffset > region.capacity - byteCount {
          entries.removeAll(keepingCapacity: true)
          nextOffset = 0
        }
        let offset = nextOffset
        try region.publish(compiled, at: offset)
        nextOffset += byteCount
        resident = .init(block: compiled, offset: offset)
        entries[key] = resident
      }

      var context = Self.executionContext(from: state)
      let exit = try region.execute(at: resident.offset, context: &context, memory: memory)
      if exit == .interpreter, resident.block.requiresMemoryCallbacks {
        return .init(block: resident.block, exitCode: exit)
      }
      Self.apply(context: context, to: &state)
      return .init(block: resident.block, exitCode: exit)
    }
  }

  private static func executionContext(from state: DoryX86ArchitecturalState) -> [UInt64] {
    var context = DoryX86GeneralRegister.allCases.map { state.registers[$0] }
    context.append(state.rip)
    context.append(state.rflags.rawValue)
    return context
  }

  private static func apply(context: [UInt64], to state: inout DoryX86ArchitecturalState) {
    precondition(context.count == DoryJITExecutableRegion.contextWordCount)
    for (index, register) in DoryX86GeneralRegister.allCases.enumerated() {
      state.registers[register] = context[index]
    }
    state.rip = context[16]
    state.rflags = DoryX86RFLAGS(rawValue: context[17])
  }

  private static func fingerprint(
    bytes: [UInt8],
    mode: DoryX86ExecutionMode,
    maximumInstructions: Int
  ) -> UInt64 {
    var value: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in bytes + Array(mode.rawValue.utf8) {
      value ^= UInt64(byte)
      value &*= 0x0000_0100_0000_01b3
    }
    var budget = UInt64(maximumInstructions)
    for _ in 0..<8 {
      value ^= UInt64(UInt8(truncatingIfNeeded: budget))
      value &*= 0x0000_0100_0000_01b3
      budget >>= 8
    }
    return value
  }
}
