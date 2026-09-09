/// Straight-line integer fragments for the pinned tier-1 ABI.
///
/// Producers leave ARM NZCV live, preserve the last materialized x86 RFLAGS image in `x25`, and
/// persist a complete lazy-flags record through `x28`. A directly adjacent consumer can therefore
/// use NZCV without synthesizing x86 flags. Later consumers materialize the persisted record.
struct DoryARM64Tier1ALUEmitter: Sendable {
  enum Source: Sendable, Equatable {
    case guestRegister(Int)
    case immediate(UInt64)
  }

  struct NativeFlags: Sendable, Equatable {
    enum Origin: Sendable, Equatable {
      case binary(DoryIRBinaryOperation)
      case unary(DoryIRUnaryOperation)
    }

    fileprivate enum Domain: Sendable, Equatable {
      case addition
      case subtraction
      case logical
      case carryPreserving
    }

    let origin: Origin
    let width: DoryIRIntegerWidth
    fileprivate let domain: Domain
  }

  /// Emits ADD/SUB/CMP/AND/TEST/OR/XOR for a pinned register destination.
  ///
  /// The result, both inputs, width, and operation are checkpointed to the stable lazy-flags
  /// context words. The returned token proves which native flag domain remains in NZCV and must
  /// only be passed to an immediately following fused consumer.
  func emitBinary(
    _ operation: DoryIRBinaryOperation,
    width: DoryIRIntegerWidth,
    destinationGuestRegister: Int,
    source: Source,
    writesDestination: Bool,
    into words: inout [UInt32]
  ) -> NativeFlags? {
    guard width == .i32 || width == .i64,
      (0..<16).contains(destinationGuestRegister),
      Self.validWriteMode(operation: operation, writesDestination: writesDestination)
    else { return nil }
    if case .guestRegister(let sourceRegister) = source {
      guard (0..<16).contains(sourceRegister) else { return nil }
    }

    let lazyOperation: DoryARM64LazyFlagsState.Operation
    let domain: NativeFlags.Domain
    switch operation {
    case .add, .addWithCarry:
      lazyOperation = operation == .add ? .add : .addWithCarry
      domain = .addition
    case .subtract, .subtractWithBorrow, .compare:
      lazyOperation = operation == .subtractWithBorrow ? .subtractWithBorrow : .subtract
      domain = .subtraction
    case .and, .test, .or, .xor:
      lazyOperation = .logical
      domain = .logical
    }

    var fragment: [UInt32] = []
    let is64Bit = width == .i64
    let destination = UInt32(destinationGuestRegister)
    if operation == .addWithCarry || operation == .subtractWithBorrow {
      Self.emitCarryFromMaterializedFlags(
        inverted: operation == .subtractWithBorrow, into: &fragment)
    }
    fragment.append(Self.encodeMove(
      destination: 16, source: destination, is64Bit: is64Bit))
    fragment.append(Self.encodeStore64(
      register: 16, word: .lazyFlagsSource1))

    switch source {
    case .guestRegister(let sourceRegister):
      fragment.append(Self.encodeMove(
        destination: 17, source: UInt32(sourceRegister), is64Bit: is64Bit))
    case .immediate(let value):
      Self.emitImmediate(
        is64Bit ? value : value & 0xFFFF_FFFF, register: 17, into: &fragment)
    }
    fragment.append(Self.encodeStore64(register: 17, word: .lazyFlagsSource2))

    let resultRegister = writesDestination ? destination : 16
    switch operation {
    case .add:
      fragment.append(Self.encodeAddSubtractSetFlags(
        add: true, is64Bit: is64Bit, left: 16, right: 17, destination: resultRegister))
    case .addWithCarry:
      fragment.append(Self.encodeAddSubtractCarrySetFlags(
        add: true, is64Bit: is64Bit, left: 16, right: 17, destination: resultRegister))
    case .subtract, .compare:
      fragment.append(Self.encodeAddSubtractSetFlags(
        add: false, is64Bit: is64Bit, left: 16, right: 17, destination: resultRegister))
    case .subtractWithBorrow:
      fragment.append(Self.encodeAddSubtractCarrySetFlags(
        add: false, is64Bit: is64Bit, left: 16, right: 17, destination: resultRegister))
    case .and, .test:
      fragment.append(Self.encodeLogical(
        .andSetFlags, is64Bit: is64Bit, left: 16, right: 17,
        destination: resultRegister))
    case .or, .xor:
      fragment.append(Self.encodeLogical(
        operation == .or ? .or : .xor, is64Bit: is64Bit,
        left: 16, right: 17, destination: resultRegister))
      fragment.append(Self.encodeLogical(
        .andSetFlags, is64Bit: is64Bit, left: resultRegister, right: resultRegister,
        destination: 31))
    }

    fragment.append(Self.encodeStore64(register: resultRegister, word: .lazyFlagsResult))
    Self.emitImmediate(UInt64(width.rawValue), register: 17, into: &fragment)
    fragment.append(Self.encodeStore64(register: 17, word: .lazyFlagsWidth))
    Self.emitImmediate(lazyOperation.rawValue, register: 26, into: &fragment)
    fragment.append(Self.encodeStore64(register: 26, word: .lazyFlagsOperation))
    words.append(contentsOf: fragment)
    return .init(origin: .binary(operation), width: width, domain: domain)
  }

  /// Emits INC/DEC/NEG for a pinned register. INC and DEC consume the carry bit from the last
  /// materialized RFLAGS image and preserve it through the pending record; callers must first
  /// materialize an older pending operation.
  func emitUnary(
    _ operation: DoryIRUnaryOperation,
    width: DoryIRIntegerWidth,
    destinationGuestRegister: Int,
    into words: inout [UInt32]
  ) -> NativeFlags? {
    guard operation != .bitwiseNot, width == .i32 || width == .i64,
      (0..<16).contains(destinationGuestRegister)
    else { return nil }

    var fragment: [UInt32] = []
    let is64Bit = width == .i64
    let destination = UInt32(destinationGuestRegister)
    fragment.append(Self.encodeMove(
      destination: 16, source: destination, is64Bit: is64Bit))
    fragment.append(Self.encodeStore64(register: 16, word: .lazyFlagsSource1))
    Self.emitImmediate(operation == .negate ? 0 : 1, register: 17, into: &fragment)
    fragment.append(Self.encodeStore64(register: 17, word: .lazyFlagsSource2))

    let lazyOperation: DoryARM64LazyFlagsState.Operation
    let domain: NativeFlags.Domain
    switch operation {
    case .increment:
      lazyOperation = .increment
      domain = .carryPreserving
      fragment.append(Self.encodeAddSubtractSetFlags(
        add: true, is64Bit: is64Bit, left: 16, right: 17, destination: destination))
    case .decrement:
      lazyOperation = .decrement
      domain = .carryPreserving
      fragment.append(Self.encodeAddSubtractSetFlags(
        add: false, is64Bit: is64Bit, left: 16, right: 17, destination: destination))
    case .negate:
      lazyOperation = .negate
      domain = .subtraction
      fragment.append(Self.encodeAddSubtractSetFlags(
        add: false, is64Bit: is64Bit, left: 31, right: 16, destination: destination))
    case .bitwiseNot:
      return nil
    }

    fragment.append(Self.encodeStore64(register: destination, word: .lazyFlagsResult))
    Self.emitImmediate(UInt64(width.rawValue), register: 17, into: &fragment)
    fragment.append(Self.encodeStore64(register: 17, word: .lazyFlagsWidth))
    Self.emitImmediate(lazyOperation.rawValue, register: 26, into: &fragment)
    fragment.append(Self.encodeStore64(register: 26, word: .lazyFlagsOperation))
    words.append(contentsOf: fragment)
    return .init(origin: .unary(operation), width: width, domain: domain)
  }

  /// Writes a fused x86 condition result into the low byte of a pinned guest register.
  ///
  /// Conditions without a single native mapping return `false` without appending any words.
  /// Parity always takes the lazy materialization path. Addition's `CF || ZF` combinations also
  /// materialize because ARM's LS/HI conditions encode the subtraction interpretation of C.
  func emitFusedSetCondition(
    _ condition: DoryX86Condition,
    flags: NativeFlags,
    destinationGuestRegister: Int,
    into words: inout [UInt32]
  ) -> Bool {
    guard (0..<16).contains(destinationGuestRegister),
      let lowering = Self.lowering(condition, domain: flags.domain)
    else { return false }

    var fragment: [UInt32] = []
    switch lowering {
    case .condition(let nativeCondition):
      fragment.append(Self.encodeConditionalSet(register: 16, condition: nativeCondition))
    case .constant(let value):
      Self.emitImmediate(value ? 1 : 0, register: 16, into: &fragment)
    }
    Self.emitImmediate(~UInt64(0xFF), register: 17, into: &fragment)
    let destination = UInt32(destinationGuestRegister)
    fragment.append(Self.encodeLogical(
      .and, is64Bit: true, left: destination, right: 17, destination: destination))
    fragment.append(Self.encodeLogical(
      .or, is64Bit: true, left: destination, right: 16, destination: destination))
    words.append(contentsOf: fragment)
    return true
  }

  /// Emits a 64-bit CMOV consumer while the producer's NZCV value is still live.
  func emitFusedConditionalMove(
    _ condition: DoryX86Condition,
    flags: NativeFlags,
    destinationGuestRegister: Int,
    source: Source,
    into words: inout [UInt32]
  ) -> Bool {
    guard (0..<16).contains(destinationGuestRegister),
      let lowering = Self.lowering(condition, domain: flags.domain)
    else { return false }
    if case .guestRegister(let sourceRegister) = source {
      guard (0..<16).contains(sourceRegister) else { return false }
    }

    var fragment: [UInt32] = []
    switch lowering {
    case .constant(false):
      break
    case .constant(true):
      Self.emitSource(source, register: UInt32(destinationGuestRegister), into: &fragment)
    case .condition(let nativeCondition):
      let sourceRegister: UInt32
      switch source {
      case .guestRegister(let index):
        sourceRegister = UInt32(index)
      case .immediate:
        sourceRegister = 16
        Self.emitSource(source, register: sourceRegister, into: &fragment)
      }
      let destination = UInt32(destinationGuestRegister)
      fragment.append(Self.encodeConditionalSelect(
        destination: destination,
        trueRegister: sourceRegister,
        falseRegister: destination,
        condition: nativeCondition
      ))
    }
    words.append(contentsOf: fragment)
    return true
  }

  /// Emits a fused conditional terminator by selecting the next guest RIP in `x27`.
  func emitFusedBranch(
    _ condition: DoryX86Condition,
    flags: NativeFlags,
    taken: UInt64,
    notTaken: UInt64,
    into words: inout [UInt32]
  ) -> Bool {
    guard let lowering = Self.lowering(condition, domain: flags.domain) else { return false }
    var fragment: [UInt32] = []
    switch lowering {
    case .constant(let value):
      Self.emitImmediate(value ? taken : notTaken, register: 27, into: &fragment)
    case .condition(let nativeCondition):
      let takenBranch = fragment.count
      fragment.append(0)
      Self.emitImmediate(notTaken, register: 27, into: &fragment)
      let doneBranch = fragment.count
      fragment.append(0)
      let takenStart = fragment.count
      Self.emitImmediate(taken, register: 27, into: &fragment)
      let done = fragment.count
      fragment[takenBranch] = Self.encodeConditionalBranch(
        condition: nativeCondition, wordOffset: takenStart - takenBranch)
      fragment[doneBranch] = Self.encodeUnconditionalBranch(wordOffset: done - doneBranch)
    }
    words.append(contentsOf: fragment)
    return true
  }

  /// Materializes a pending record, evaluates any x86 condition from `x25`, and replaces only the
  /// destination's low byte. This is the fallback for parity and native-domain mismatches.
  func emitMaterializedSetCondition(
    _ condition: DoryX86Condition,
    destinationGuestRegister: Int,
    into words: inout [UInt32]
  ) -> Bool {
    guard (0..<16).contains(destinationGuestRegister) else { return false }
    var fragment: [UInt32] = []
    DoryARM64Tier1BoundaryEmitter().emitMaterializeLazyFlags(into: &fragment)
    Self.emitConditionFromMaterializedFlags(condition, into: &fragment)

    Self.emitImmediate(~UInt64(0xFF), register: 26, into: &fragment)
    let destination = UInt32(destinationGuestRegister)
    fragment.append(Self.encodeLogical(
      .and, is64Bit: true, left: destination, right: 26, destination: destination))
    fragment.append(Self.encodeLogical(
      .or, is64Bit: true, left: destination, right: 16, destination: destination))
    fragment.append(Self.encodeMove(destination: 26, source: 31, is64Bit: true))
    words.append(contentsOf: fragment)
    return true
  }

  /// Materializing fallback for a 64-bit conditional move.
  func emitMaterializedConditionalMove(
    _ condition: DoryX86Condition,
    destinationGuestRegister: Int,
    source: Source,
    into words: inout [UInt32]
  ) -> Bool {
    guard (0..<16).contains(destinationGuestRegister) else { return false }
    if case .guestRegister(let sourceRegister) = source {
      guard (0..<16).contains(sourceRegister) else { return false }
    }
    var fragment: [UInt32] = []
    DoryARM64Tier1BoundaryEmitter().emitMaterializeLazyFlags(into: &fragment)
    Self.emitConditionFromMaterializedFlags(condition, into: &fragment)
    let sourceRegister: UInt32
    switch source {
    case .guestRegister(let index):
      sourceRegister = UInt32(index)
    case .immediate:
      sourceRegister = 17
      Self.emitSource(source, register: sourceRegister, into: &fragment)
    }
    fragment.append(Self.encodeAddSubtractSetFlags(
      add: false, is64Bit: true, left: 16, right: 31, destination: 31))
    let destination = UInt32(destinationGuestRegister)
    fragment.append(Self.encodeConditionalSelect(
      destination: destination,
      trueRegister: sourceRegister,
      falseRegister: destination,
      condition: .notEqual
    ))
    fragment.append(Self.encodeMove(destination: 26, source: 31, is64Bit: true))
    words.append(contentsOf: fragment)
    return true
  }

  /// Materializing fallback for a conditional terminator.
  func emitMaterializedBranch(
    _ condition: DoryX86Condition,
    taken: UInt64,
    notTaken: UInt64,
    into words: inout [UInt32]
  ) {
    var fragment: [UInt32] = []
    DoryARM64Tier1BoundaryEmitter().emitMaterializeLazyFlags(into: &fragment)
    Self.emitConditionFromMaterializedFlags(condition, into: &fragment)
    fragment.append(Self.encodeMove(destination: 26, source: 31, is64Bit: true))
    let notTakenBranch = fragment.count
    fragment.append(0)
    Self.emitImmediate(taken, register: 27, into: &fragment)
    let doneBranch = fragment.count
    fragment.append(0)
    let notTakenStart = fragment.count
    Self.emitImmediate(notTaken, register: 27, into: &fragment)
    let done = fragment.count
    fragment[notTakenBranch] = Self.encodeCompareAndBranchZero(
      register: 16, wordOffset: notTakenStart - notTakenBranch)
    fragment[doneBranch] = Self.encodeUnconditionalBranch(wordOffset: done - doneBranch)
    words.append(contentsOf: fragment)
  }

  /// Materializes flags and applies LAHF's architectural low-byte image to AH.
  func emitLoadFlagsIntoAH(into words: inout [UInt32]) {
    var fragment: [UInt32] = []
    DoryARM64Tier1BoundaryEmitter().emitMaterializeLazyFlags(into: &fragment)
    Self.emitImmediate(0xD5, register: 16, into: &fragment)
    fragment.append(Self.encodeLogical(
      .and, is64Bit: true, left: 25, right: 16, destination: 16))
    Self.emitImmediate(DoryX86RFLAGS.reservedOne.rawValue, register: 17, into: &fragment)
    fragment.append(Self.encodeLogical(
      .or, is64Bit: true, left: 16, right: 17, destination: 16))
    Self.emitImmediate(~UInt64(0xFF00), register: 17, into: &fragment)
    fragment.append(Self.encodeLogical(
      .and, is64Bit: true, left: 0, right: 17, destination: 0))
    fragment.append(Self.encodeLogical(
      .or, is64Bit: true, left: 0, right: 16, shiftAmount: 8, destination: 0))
    words.append(contentsOf: fragment)
  }

  /// Materializes and stages the architecturally sanitized PUSHF image in a pinned register.
  /// The tier-1 memory lowering consumes this value when it emits the stack write.
  func emitPushedFlagsImage(
    destinationGuestRegister: Int,
    into words: inout [UInt32]
  ) -> Bool {
    guard (0..<16).contains(destinationGuestRegister) else { return false }
    var fragment: [UInt32] = []
    DoryARM64Tier1BoundaryEmitter().emitMaterializeLazyFlags(into: &fragment)
    Self.emitImmediate(
      ~(DoryX86RFLAGS.resume.rawValue | DoryX86RFLAGS.virtual8086.rawValue),
      register: 16,
      into: &fragment
    )
    let destination = UInt32(destinationGuestRegister)
    fragment.append(Self.encodeLogical(
      .and, is64Bit: true, left: 25, right: 16, destination: destination))
    Self.emitImmediate(DoryX86RFLAGS.reservedOne.rawValue, register: 16, into: &fragment)
    fragment.append(Self.encodeLogical(
      .or, is64Bit: true, left: destination, right: 16, destination: destination))
    words.append(contentsOf: fragment)
    return true
  }

  /// Emits the materialized x86 predicate as zero/one in x16. Uses x17 as the constant one and
  /// x26 as scratch; callers must clear x26 before returning to the pinned lazy-state convention.
  private static func emitConditionFromMaterializedFlags(
    _ condition: DoryX86Condition,
    into words: inout [UInt32]
  ) {
    emitImmediate(1, register: 17, into: &words)

    func emitFlag(_ flag: DoryX86RFLAGS, into result: UInt32) {
      words.append(encodeLogical(
        .or,
        is64Bit: true,
        left: 31,
        right: 25,
        shiftAmount: UInt32(flag.rawValue.trailingZeroBitCount),
        logicalRightShift: true,
        destination: result
      ))
      words.append(encodeLogical(
        .and, is64Bit: true, left: result, right: 17, destination: result))
    }

    func invert(_ result: UInt32) {
      words.append(encodeLogical(
        .xor, is64Bit: true, left: result, right: 17, destination: result))
    }

    switch condition {
    case .overflow, .notOverflow:
      emitFlag(.overflow, into: 16)
      if condition == .notOverflow { invert(16) }
    case .below, .aboveOrEqual:
      emitFlag(.carry, into: 16)
      if condition == .aboveOrEqual { invert(16) }
    case .equal, .notEqual:
      emitFlag(.zero, into: 16)
      if condition == .notEqual { invert(16) }
    case .belowOrEqual, .above:
      emitFlag(.carry, into: 16)
      emitFlag(.zero, into: 26)
      words.append(encodeLogical(
        .or, is64Bit: true, left: 16, right: 26, destination: 16))
      if condition == .above { invert(16) }
    case .sign, .notSign:
      emitFlag(.sign, into: 16)
      if condition == .notSign { invert(16) }
    case .parity, .notParity:
      emitFlag(.parity, into: 16)
      if condition == .notParity { invert(16) }
    case .less, .greaterOrEqual:
      emitFlag(.sign, into: 16)
      emitFlag(.overflow, into: 26)
      words.append(encodeLogical(
        .xor, is64Bit: true, left: 16, right: 26, destination: 16))
      if condition == .greaterOrEqual { invert(16) }
    case .lessOrEqual, .greater:
      emitFlag(.sign, into: 16)
      emitFlag(.overflow, into: 26)
      words.append(encodeLogical(
        .xor, is64Bit: true, left: 16, right: 26, destination: 16))
      emitFlag(.zero, into: 26)
      words.append(encodeLogical(
        .or, is64Bit: true, left: 16, right: 26, destination: 16))
      if condition == .greater { invert(16) }
    }
  }

  private static func validWriteMode(
    operation: DoryIRBinaryOperation,
    writesDestination: Bool
  ) -> Bool {
    switch operation {
    case .compare, .test: !writesDestination
    default: writesDestination
    }
  }

  private enum ConditionLowering {
    case condition(ARM64Condition)
    case constant(Bool)
  }

  private static func lowering(
    _ condition: DoryX86Condition,
    domain: NativeFlags.Domain
  ) -> ConditionLowering? {
    switch condition {
    case .overflow: return .condition(.overflowSet)
    case .notOverflow: return .condition(.overflowClear)
    case .equal: return .condition(.equal)
    case .notEqual: return .condition(.notEqual)
    case .sign: return .condition(.minus)
    case .notSign: return .condition(.plus)
    case .less: return .condition(.lessThan)
    case .greaterOrEqual: return .condition(.greaterOrEqual)
    case .lessOrEqual: return .condition(.lessOrEqual)
    case .greater: return .condition(.greaterThan)
    case .parity, .notParity:
      return nil
    case .below:
      return switch domain {
      case .addition: .condition(.carrySet)
      case .subtraction: .condition(.carryClear)
      case .logical: .constant(false)
      case .carryPreserving: nil
      }
    case .aboveOrEqual:
      return switch domain {
      case .addition: .condition(.carryClear)
      case .subtraction: .condition(.carrySet)
      case .logical: .constant(true)
      case .carryPreserving: nil
      }
    case .belowOrEqual:
      return switch domain {
      case .addition: nil
      case .subtraction: .condition(.lowerOrSame)
      case .logical: .condition(.equal)
      case .carryPreserving: nil
      }
    case .above:
      return switch domain {
      case .addition: nil
      case .subtraction: .condition(.higher)
      case .logical: .condition(.notEqual)
      case .carryPreserving: nil
      }
    }
  }

  private enum LogicalOperation {
    case and, or, xor, andSetFlags
  }

  private enum ARM64Condition: UInt32 {
    case equal = 0
    case notEqual = 1
    case carrySet = 2
    case carryClear = 3
    case minus = 4
    case plus = 5
    case overflowSet = 6
    case overflowClear = 7
    case higher = 8
    case lowerOrSame = 9
    case greaterOrEqual = 10
    case lessThan = 11
    case greaterThan = 12
    case lessOrEqual = 13
  }

  private static func emitImmediate(
    _ value: UInt64,
    register: UInt32,
    into words: inout [UInt32]
  ) {
    for halfword in 0..<4 {
      let immediate = UInt16(truncatingIfNeeded: value >> UInt64(halfword * 16))
      if halfword == 0 {
        words.append(0xD280_0000 | UInt32(immediate) << 5 | register)
      } else if immediate != 0 {
        words.append(
          0xF280_0000 | UInt32(halfword) << 21 | UInt32(immediate) << 5 | register)
      }
    }
  }

  private static func emitSource(
    _ source: Source,
    register: UInt32,
    into words: inout [UInt32]
  ) {
    switch source {
    case .guestRegister(let index):
      words.append(encodeMove(destination: register, source: UInt32(index), is64Bit: true))
    case .immediate(let value):
      emitImmediate(value, register: register, into: &words)
    }
  }

  private static func encodeMove(
    destination: UInt32,
    source: UInt32,
    is64Bit: Bool
  ) -> UInt32 {
    (is64Bit ? 0xAA00_03E0 : 0x2A00_03E0) | source << 16 | destination
  }

  private static func encodeStore64(
    register: UInt32,
    word: DoryARM64Tier1ABI.ContextWord
  ) -> UInt32 {
    0xF900_0000 | UInt32(word.rawValue) << 10
      | DoryARM64Tier1ABI.contextRegister << 5 | register
  }

  private static func encodeAddSubtractSetFlags(
    add: Bool,
    is64Bit: Bool,
    left: UInt32,
    right: UInt32,
    destination: UInt32
  ) -> UInt32 {
    let base: UInt32 = switch (add, is64Bit) {
    case (true, true): 0xAB00_0000
    case (true, false): 0x2B00_0000
    case (false, true): 0xEB00_0000
    case (false, false): 0x6B00_0000
    }
    return base | right << 16 | left << 5 | destination
  }

  private static func encodeAddSubtractCarrySetFlags(
    add: Bool,
    is64Bit: Bool,
    left: UInt32,
    right: UInt32,
    destination: UInt32
  ) -> UInt32 {
    let base: UInt32 = switch (add, is64Bit) {
    case (true, true): 0xBA00_0000
    case (true, false): 0x3A00_0000
    case (false, true): 0xFA00_0000
    case (false, false): 0x7A00_0000
    }
    return base | right << 16 | left << 5 | destination
  }

  private static func emitCarryFromMaterializedFlags(
    inverted: Bool,
    into words: inout [UInt32]
  ) {
    emitImmediate(1, register: 17, into: &words)
    words.append(encodeLogical(
      .and, is64Bit: true, left: 25, right: 17, destination: 16))
    if inverted {
      words.append(encodeLogical(
        .xor, is64Bit: true, left: 16, right: 17, destination: 16))
    }
    words.append(encodeAddSubtractSetFlags(
      add: false, is64Bit: true, left: 16, right: 17, destination: 31))
  }

  private static func encodeLogical(
    _ operation: LogicalOperation,
    is64Bit: Bool,
    left: UInt32,
    right: UInt32,
    shiftAmount: UInt32 = 0,
    logicalRightShift: Bool = false,
    destination: UInt32
  ) -> UInt32 {
    let base: UInt32 = switch (operation, is64Bit) {
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

  private static func encodeConditionalSet(
    register: UInt32,
    condition: ARM64Condition
  ) -> UInt32 {
    0x9A9F_07E0 | ((condition.rawValue ^ 1) << 12) | register
  }

  private static func encodeConditionalSelect(
    destination: UInt32,
    trueRegister: UInt32,
    falseRegister: UInt32,
    condition: ARM64Condition
  ) -> UInt32 {
    0x9A80_0000 | falseRegister << 16 | condition.rawValue << 12
      | trueRegister << 5 | destination
  }

  private static func encodeConditionalBranch(
    condition: ARM64Condition,
    wordOffset: Int
  ) -> UInt32 {
    precondition((-262_144..<262_144).contains(wordOffset))
    return 0x5400_0000
      | (UInt32(truncatingIfNeeded: wordOffset) & 0x7_FFFF) << 5
      | condition.rawValue
  }

  private static func encodeUnconditionalBranch(wordOffset: Int) -> UInt32 {
    precondition((-33_554_432..<33_554_432).contains(wordOffset))
    return 0x1400_0000 | (UInt32(truncatingIfNeeded: wordOffset) & 0x3FF_FFFF)
  }

  private static func encodeCompareAndBranchZero(
    register: UInt32,
    wordOffset: Int
  ) -> UInt32 {
    precondition((-262_144..<262_144).contains(wordOffset))
    return 0xB400_0000
      | (UInt32(truncatingIfNeeded: wordOffset) & 0x7_FFFF) << 5
      | register
  }
}
