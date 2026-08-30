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
  case interpreterFallback
}

public struct DoryARM64CompiledBlock: Codable, Sendable, Hashable {
  public let guestStart: UInt64
  public let guestByteCount: UInt32
  public let machineWords: [UInt32]
  public let tier: DoryARM64CompilationTier
  public let exitCode: DoryJITExitCode

  public init(
    guestStart: UInt64,
    guestByteCount: UInt32,
    machineWords: [UInt32],
    tier: DoryARM64CompilationTier,
    exitCode: DoryJITExitCode
  ) {
    self.guestStart = guestStart
    self.guestByteCount = guestByteCount
    self.machineWords = machineWords
    self.tier = tier
    self.exitCode = exitCode
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

  public func compile(_ block: DoryIRBasicBlock) -> DoryARM64CompiledBlock {
    var words: [UInt32] = []
    for statement in block.statements {
      guard emit(statement, into: &words) else {
        return fallback(block)
      }
    }
    guard let exit = emit(block.terminator, into: &words) else {
      return fallback(block)
    }
    words.append(encodeMoveWideZero32(register: 0, immediate: UInt16(exit.rawValue)))
    words.append(0xD65F_03C0)
    return .init(
      guestStart: block.guestStart,
      guestByteCount: block.guestByteCount,
      machineWords: words,
      tier: .baseline,
      exitCode: exit
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
    default:
      return false
    }
  }

  private func emitCopy(
    destination: DoryIROperand,
    source: DoryIROperand,
    into words: inout [UInt32]
  ) -> Bool {
    guard
      case .register(let target) = destination,
      target.bank == "x86.gpr",
      target.index < 16,
      target.width == .i32 || target.width == .i64
    else { return false }

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
      emitImmediate(target.width == .i32 ? value & 0xffff_ffff : value, register: 9, into: &words)
    default:
      return false
    }
    words.append(
      encodeStore64(register: 9, base: 0, byteOffset: Int(target.index) * 8)
    )
    return true
  }

  private func emitBinary(
    _ operation: DoryIRBinaryOperation,
    destination: DoryIROperand,
    source: DoryIROperand,
    writesDestination: Bool,
    into words: inout [UInt32]
  ) -> Bool {
    guard
      case .register(let target) = destination,
      target.bank == "x86.gpr",
      target.index < 16,
      target.width == .i32 || target.width == .i64,
      load(target, into: 9, words: &words),
      load(source, matching: target.width, into: 10, words: &words)
    else { return false }

    let is64Bit = target.width == .i64
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

    if writesDestination {
      words.append(
        encodeStore64(register: 11, base: 0, byteOffset: Int(target.index) * 8)
      )
    }
    emitX86ArithmeticFlags(
      subtraction: operation == .subtract || operation == .subtractWithBorrow
        || operation == .compare,
      includesAuxiliaryCarry: arithmetic,
      resultRegister: 11,
      into: &words
    )
    return true
  }

  private func emitARMCarryFromX86(inverted: Bool, into words: inout [UInt32]) {
    words.append(encodeLoad64(register: 12, base: 0, byteOffset: Self.rflagsOffset))
    emitImmediate(1, register: 15, into: &words)
    emitFlag(DoryX86RFLAGS.carry, from: 12, into: 12, words: &words)
    if inverted { invertBoolean(12, words: &words) }
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: true, 12, 15, 31))
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
    default:
      return false
    }
  }

  private func emitX86ArithmeticFlags(
    subtraction: Bool,
    includesAuxiliaryCarry: Bool,
    resultRegister: UInt32,
    into words: inout [UInt32]
  ) {
    // Capture ARM NZCV before the flag-synthesis instructions. ARM C is the inverse of x86 CF
    // after subtraction, while addition uses it directly.
    words.append(
      encodeConditionalSet(register: 13, condition: subtraction ? .carryClear : .carrySet))
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
    emitImmediate(~Self.arithmeticFlagMask, register: 15, into: &words)
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

  public init(guestStart: UInt64, addressSpaceID: UInt64, codeGeneration: UInt64) {
    self.guestStart = guestStart
    self.addressSpaceID = addressSpaceID
    self.codeGeneration = codeGeneration
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

  public func execute(at offset: Int, context: inout [UInt64]) throws -> DoryJITExitCode {
    guard offset >= 0, offset.isMultiple(of: 4), offset < capacity else {
      throw DoryJITRuntimeError.invalidOffset(offset)
    }
    guard context.count == Self.contextWordCount else {
      throw DoryJITRuntimeError.invalidContextWordCount(context.count)
    }
    var rawExit: UInt32 = 0
    let result = context.withUnsafeMutableBufferPointer { buffer in
      dory_jit_region_execute(region, offset, buffer.baseAddress, &rawExit)
    }
    guard result == 0 else { throw DoryJITRuntimeError.executionFailed(result) }
    guard let exit = DoryJITExitCode(rawValue: rawExit) else {
      throw DoryJITRuntimeError.invalidExitCode(rawExit)
    }
    return exit
  }
}
