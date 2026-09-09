/// Straight-line integer fragments for the pinned tier-1 ABI.
///
/// Producers leave ARM NZCV live, preserve the last materialized x86 RFLAGS image in `x25`, and
/// persist a complete lazy-flags record through `x28`. A directly adjacent consumer can therefore
/// use NZCV without synthesizing x86 flags. Later consumers materialize the persisted record.
struct DoryARM64Tier1ALUEmitter: Sendable {
  enum CarryRotateOperation: Sendable, Equatable {
    case left, right
  }

  enum DoubleShiftOperation: Sendable, Equatable {
    case left, right
  }

  enum Source: Sendable, Equatable {
    case guestRegister(Int)
    case immediate(UInt64)
  }

  enum HighByteSource: Sendable, Equatable {
    case guestHighByte(Int)
    case immediate(UInt8)
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
      case materializedOnly
    }

    let origin: Origin
    let width: DoryIRIntegerWidth
    fileprivate let domain: Domain
  }

  /// Copies a register or immediate into a pinned low-byte/word/dword/qword destination without
  /// changing NZCV or the pending lazy-flags record. Narrow writes preserve the surrounding guest
  /// register bits; a dword write uses a W-register move and therefore zero-extends architecturally.
  func emitCopy(
    width: DoryIRIntegerWidth,
    destinationGuestRegister: Int,
    source: Source,
    into words: inout [UInt32]
  ) -> Bool {
    guard (0..<16).contains(destinationGuestRegister) else { return false }
    if case .guestRegister(let sourceRegister) = source {
      guard (0..<16).contains(sourceRegister) else { return false }
    }

    let destination = UInt32(destinationGuestRegister)
    let mask = Self.mask(for: width)
    switch width {
    case .i32, .i64:
      switch source {
      case .guestRegister(let sourceRegister):
        words.append(
          Self.encodeMove(
            destination: destination,
            source: UInt32(sourceRegister),
            is64Bit: width == .i64))
      case .immediate(let value):
        Self.emitImmediate(value & mask, register: destination, into: &words)
      }
    case .i8, .i16:
      switch source {
      case .guestRegister(let sourceRegister):
        words.append(
          Self.encodeMove(destination: 16, source: UInt32(sourceRegister), is64Bit: true))
      case .immediate(let value):
        Self.emitImmediate(value & mask, register: 16, into: &words)
      }
      Self.emitImmediate(mask, register: 17, into: &words)
      words.append(
        Self.encodeLogical(.and, is64Bit: true, left: 16, right: 17, destination: 16))
      Self.emitImmediate(~mask, register: 17, into: &words)
      words.append(
        Self.encodeLogical(
          .and, is64Bit: true, left: destination, right: 17, destination: destination))
      words.append(
        Self.encodeLogical(
          .or, is64Bit: true, left: destination, right: 16, destination: destination))
    }
    return true
  }

  /// Forms a 32- or 64-bit x86 effective address entirely in tier-1 scratch registers. LEA
  /// ignores the segment base, preserves NZCV and lazy flags, and computes the complete address
  /// before publishing the destination so base/index aliases remain correct.
  func emitEffectiveAddress(
    destinationWidth: DoryIRIntegerWidth,
    destinationGuestRegister: Int,
    address: DoryIRMemoryAddress,
    into words: inout [UInt32]
  ) -> Bool {
    guard (0..<16).contains(destinationGuestRegister),
      destinationWidth == .i32 || destinationWidth == .i64,
      address.addressWidth == .i32 || address.addressWidth == .i64,
      address.segment == nil || address.segment == "fs" || address.segment == "gs",
      address.scale == 1 || address.scale == 2 || address.scale == 4 || address.scale == 8
    else { return false }
    for register in [address.base, address.index].compactMap({ $0 }) {
      guard register.bank == "x86.gpr", register.index < 16,
        register.width == address.addressWidth
      else { return false }
    }

    let addressIs64Bit = address.addressWidth == .i64
    let displacement = UInt64(bitPattern: address.displacement)
    Self.emitImmediate(
      addressIs64Bit ? displacement : displacement & UInt64(UInt32.max),
      register: 16,
      into: &words
    )
    if let relativeBase = address.instructionRelativeBase {
      Self.emitImmediate(relativeBase, register: 17, into: &words)
      words.append(
        Self.encodeAddSubtract(
          add: true,
          is64Bit: addressIs64Bit,
          left: 16,
          right: 17,
          destination: 16
        ))
    }
    if let base = address.base {
      words.append(
        Self.encodeAddSubtract(
          add: true,
          is64Bit: addressIs64Bit,
          left: 16,
          right: UInt32(base.index),
          destination: 16
        ))
    }
    if let index = address.index {
      words.append(
        Self.encodeAddSubtract(
          add: true,
          is64Bit: addressIs64Bit,
          left: 16,
          right: UInt32(index.index),
          leftShift: UInt32(address.scale.trailingZeroBitCount),
          destination: 16
        ))
    }
    words.append(
      Self.encodeMove(
        destination: UInt32(destinationGuestRegister),
        source: 16,
        is64Bit: destinationWidth == .i64
      ))
    return true
  }

  /// Publishes the dispatcher-sampled virtual TSC through EDX:EAX without changing flags. The
  /// translator makes RDTSC a dispatch boundary, so the machine clock is refreshed before this
  /// fragment executes and again before any following guest instruction is compiled.
  func emitReadTimestampCounter(into words: inout [UInt32]) {
    words.append(Self.encodeLoad64(register: 16, word: .tsc))
    words.append(
      Self.encodeLogical(
        .or,
        is64Bit: true,
        left: 31,
        right: 16,
        shiftAmount: 32,
        logicalRightShift: true,
        destination: 17
      ))
    words.append(Self.encodeMove(destination: 0, source: 16, is64Bit: false))
    words.append(Self.encodeMove(destination: 2, source: 17, is64Bit: false))
  }

  /// Calls the memory owner's ordering boundary and then applies the conservative completion
  /// barrier used by the legacy emitter. The Darwin call can clobber every pinned caller-saved
  /// GPR and NZCV, so all guest GPRs are checkpointed while the callee-saved lazy record survives.
  func emitMemoryFence(_ kind: DoryX86MemoryFence, into words: inout [UInt32]) {
    _ = kind
    for (index, register) in DoryARM64Tier1ABI.guestRegisterMap.enumerated() {
      words.append(
        Self.encodeStore64(
          register: register,
          word: DoryARM64Tier1ABI.ContextWord(rawValue: index)!))
    }
    words.append(Self.encodeMove(destination: 0, source: 19, is64Bit: true))
    words.append(Self.encodeBranchWithLink(register: 23))
    words.append(0xD503_3F9F)  // dsb sy
    words.append(0xD503_3FDF)  // isb
    for (index, register) in DoryARM64Tier1ABI.guestRegisterMap.enumerated() {
      words.append(
        Self.encodeLoad64(
          register: register,
          word: DoryARM64Tier1ABI.ContextWord(rawValue: index)!))
    }
  }

  /// Copies a selector from the stable context into a word-sized pinned GPR destination. Selector
  /// context words are canonical UInt16 values, so only the destination's low word is replaced.
  func emitReadSegment(
    _ segment: DoryX86SegmentRegister,
    destinationGuestRegister: Int,
    into words: inout [UInt32]
  ) -> Bool {
    guard (0..<16).contains(destinationGuestRegister) else { return false }
    let selectorWord: DoryARM64Tier1ABI.ContextWord =
      switch segment {
      case .cs: .csSelector
      case .ds: .dsSelector
      case .es: .esSelector
      case .fs: .fsSelector
      case .gs: .gsSelector
      case .ss: .ssSelector
      }
    let destination = UInt32(destinationGuestRegister)
    words.append(Self.encodeLoad64(register: 16, word: selectorWord))
    Self.emitImmediate(~UInt64(0xFFFF), register: 17, into: &words)
    words.append(
      Self.encodeLogical(
        .and,
        is64Bit: true,
        left: destination,
        right: 17,
        destination: destination
      ))
    words.append(
      Self.encodeLogical(
        .or,
        is64Bit: true,
        left: destination,
        right: 16,
        destination: destination
      ))
    return true
  }

  /// Emits register-source BSF/BSR. The legacy deterministic policy preserves all undefined
  /// status bits and leaves the entire destination unchanged for a zero source, including the
  /// upper half of a dword destination. A prior lazy producer is therefore materialized first.
  func emitBitScan(
    reverse: Bool,
    width: DoryIRIntegerWidth,
    destinationGuestRegister: Int,
    sourceGuestRegister: Int,
    into words: inout [UInt32]
  ) -> Bool {
    guard width == .i32 || width == .i64,
      (0..<16).contains(destinationGuestRegister),
      (0..<16).contains(sourceGuestRegister)
    else { return false }

    var fragment: [UInt32] = []
    DoryARM64Tier1BoundaryEmitter().emitMaterializeLazyFlags(into: &fragment)
    let is64Bit = width == .i64
    let source = UInt32(sourceGuestRegister)
    if reverse {
      fragment.append(
        Self.encodeCountLeadingZeros(is64Bit: is64Bit, source: source, destination: 16))
      Self.emitImmediate(is64Bit ? 63 : 31, register: 17, into: &fragment)
      fragment.append(
        Self.encodeLogical(
          .xor, is64Bit: is64Bit, left: 17, right: 16, destination: 16))
    } else {
      fragment.append(
        Self.encodeReverseBits(is64Bit: is64Bit, source: source, destination: 16))
      fragment.append(
        Self.encodeCountLeadingZeros(is64Bit: is64Bit, source: 16, destination: 16))
    }
    fragment.append(
      Self.encodeAddSubtractSetFlags(
        add: false, is64Bit: is64Bit, left: source, right: 31, destination: 31))
    fragment.append(Self.encodeConditionalSet(register: 17, condition: .equal))
    Self.emitImmediate(~DoryX86RFLAGS.zero.rawValue, register: 26, into: &fragment)
    fragment.append(
      Self.encodeLogical(.and, is64Bit: true, left: 25, right: 26, destination: 25))
    fragment.append(
      Self.encodeLogical(
        .or, is64Bit: true, left: 25, right: 17, shiftAmount: 6, destination: 25))
    fragment.append(Self.encodeMove(destination: 26, source: 31, is64Bit: true))
    let zeroBranch = fragment.count
    fragment.append(0)
    fragment.append(
      Self.encodeMove(
        destination: UInt32(destinationGuestRegister),
        source: 16,
        is64Bit: is64Bit
      ))
    fragment[zeroBranch] = Self.encodeConditionalBranch(
      condition: .equal,
      wordOffset: fragment.count - zeroBranch
    )
    words.append(contentsOf: fragment)
    return true
  }

  /// Emits register-base BT/BTC/BTR/BTS. The index is reduced and staged before the base can be
  /// changed, preserving base/index aliases. Only CF changes under the engine's deterministic
  /// policy; an older lazy producer is materialized before that carry bit is replaced.
  func emitBitTest(
    _ operation: DoryX86BitOperation,
    width: DoryIRIntegerWidth,
    baseGuestRegister: Int,
    index: Source,
    into words: inout [UInt32]
  ) -> Bool {
    guard width == .i32 || width == .i64,
      (0..<16).contains(baseGuestRegister)
    else { return false }
    if case .guestRegister(let indexRegister) = index {
      guard (0..<16).contains(indexRegister) else { return false }
    }

    var fragment: [UInt32] = []
    DoryARM64Tier1BoundaryEmitter().emitMaterializeLazyFlags(into: &fragment)
    let is64Bit = width == .i64
    let bitIndexMask = UInt64(width.rawValue - 1)
    switch index {
    case .guestRegister(let indexRegister):
      Self.emitImmediate(bitIndexMask, register: 17, into: &fragment)
      fragment.append(
        Self.encodeLogical(
          .and,
          is64Bit: is64Bit,
          left: UInt32(indexRegister),
          right: 17,
          destination: 16
        ))
      Self.emitImmediate(1, register: 17, into: &fragment)
      fragment.append(
        Self.encodeVariableShift(
          .left,
          is64Bit: is64Bit,
          value: 17,
          count: 16,
          destination: 16
        ))
    case .immediate(let rawIndex):
      Self.emitImmediate(1 << (rawIndex & bitIndexMask), register: 16, into: &fragment)
    }

    let base = UInt32(baseGuestRegister)
    fragment.append(
      Self.encodeLogical(
        .andSetFlags,
        is64Bit: is64Bit,
        left: base,
        right: 16,
        destination: 17
      ))
    fragment.append(Self.encodeConditionalSet(register: 17, condition: .notEqual))
    Self.emitImmediate(~DoryX86RFLAGS.carry.rawValue, register: 26, into: &fragment)
    fragment.append(
      Self.encodeLogical(.and, is64Bit: true, left: 25, right: 26, destination: 25))
    fragment.append(
      Self.encodeLogical(.or, is64Bit: true, left: 25, right: 17, destination: 25))
    fragment.append(Self.encodeMove(destination: 26, source: 31, is64Bit: true))

    switch operation {
    case .test:
      break
    case .set:
      fragment.append(
        Self.encodeLogical(
          .or, is64Bit: is64Bit, left: base, right: 16, destination: base))
    case .complement:
      fragment.append(
        Self.encodeLogical(
          .xor, is64Bit: is64Bit, left: base, right: 16, destination: base))
    case .reset:
      Self.emitImmediate(is64Bit ? .max : UInt64(UInt32.max), register: 17, into: &fragment)
      fragment.append(
        Self.encodeLogical(
          .xor, is64Bit: is64Bit, left: 16, right: 17, destination: 17))
      fragment.append(
        Self.encodeLogical(
          .and, is64Bit: is64Bit, left: base, right: 17, destination: base))
    }
    words.append(contentsOf: fragment)
    return true
  }

  /// Emits the two- and three-operand signed IMUL forms for pinned registers. Only CF/OF are
  /// defined; both become one when the full signed product is not the sign extension of the
  /// truncated result. Other flags follow the engine's deterministic preserve policy.
  func emitSignedMultiply(
    width: DoryIRIntegerWidth,
    destinationGuestRegister: Int,
    lhsGuestRegister: Int,
    rhs: Source,
    into words: inout [UInt32]
  ) -> Bool {
    guard width == .i32 || width == .i64,
      (0..<16).contains(destinationGuestRegister),
      (0..<16).contains(lhsGuestRegister)
    else { return false }
    if case .guestRegister(let rhsRegister) = rhs {
      guard (0..<16).contains(rhsRegister) else { return false }
    }

    var fragment: [UInt32] = []
    DoryARM64Tier1BoundaryEmitter().emitMaterializeLazyFlags(into: &fragment)
    let rightRegister: UInt32
    switch rhs {
    case .guestRegister(let register):
      rightRegister = UInt32(register)
    case .immediate(let value):
      rightRegister = 17
      Self.emitImmediate(value, register: rightRegister, into: &fragment)
    }
    let leftRegister = UInt32(lhsGuestRegister)
    if width == .i64 {
      fragment.append(
        Self.encodeMultiply64(left: leftRegister, right: rightRegister, destination: 16))
      fragment.append(
        Self.encodeSignedMultiplyHigh64(
          left: leftRegister,
          right: rightRegister,
          destination: 17
        ))
      Self.emitImmediate(63, register: 26, into: &fragment)
      fragment.append(
        Self.encodeVariableShift(
          .arithmeticRight,
          is64Bit: true,
          value: 16,
          count: 26,
          destination: 26
        ))
      fragment.append(
        Self.encodeAddSubtractSetFlags(
          add: false, is64Bit: true, left: 17, right: 26, destination: 31))
    } else {
      fragment.append(
        Self.encodeSignedMultiplyLong32(
          left: leftRegister,
          right: rightRegister,
          destination: 16
        ))
      fragment.append(Self.encodeSignExtend32To64(source: 16, destination: 17))
      fragment.append(
        Self.encodeAddSubtractSetFlags(
          add: false, is64Bit: true, left: 16, right: 17, destination: 31))
    }

    fragment.append(Self.encodeConditionalSet(register: 17, condition: .notEqual))
    let overflowMask = DoryX86RFLAGS.carry.rawValue | DoryX86RFLAGS.overflow.rawValue
    Self.emitImmediate(~overflowMask, register: 26, into: &fragment)
    fragment.append(
      Self.encodeLogical(.and, is64Bit: true, left: 25, right: 26, destination: 25))
    fragment.append(
      Self.encodeLogical(.or, is64Bit: true, left: 25, right: 17, destination: 25))
    fragment.append(
      Self.encodeLogical(
        .or, is64Bit: true, left: 25, right: 17, shiftAmount: 11, destination: 25))
    fragment.append(Self.encodeMove(destination: 26, source: 31, is64Bit: true))
    fragment.append(
      Self.encodeMove(
        destination: UInt32(destinationGuestRegister),
        source: 16,
        is64Bit: width == .i64
      ))
    words.append(contentsOf: fragment)
    return true
  }

  /// Exchanges two pinned qword registers without changing NZCV or lazy flags.
  func emitExchangeRegisters(
    lhsGuestRegister: Int,
    rhsGuestRegister: Int,
    into words: inout [UInt32]
  ) -> Bool {
    guard (0..<16).contains(lhsGuestRegister), (0..<16).contains(rhsGuestRegister) else {
      return false
    }
    guard lhsGuestRegister != rhsGuestRegister else { return true }
    let lhs = UInt32(lhsGuestRegister)
    let rhs = UInt32(rhsGuestRegister)
    words.append(Self.encodeMove(destination: 16, source: lhs, is64Bit: true))
    words.append(Self.encodeMove(destination: lhs, source: rhs, is64Bit: true))
    words.append(Self.encodeMove(destination: rhs, source: 16, is64Bit: true))
    return true
  }

  /// Reverses bytes in a pinned dword or qword. A dword destination zero-extends naturally.
  func emitByteSwap(
    width: DoryIRIntegerWidth,
    guestRegister: Int,
    into words: inout [UInt32]
  ) -> Bool {
    guard (0..<16).contains(guestRegister), width == .i32 || width == .i64 else {
      return false
    }
    let register = UInt32(guestRegister)
    words.append(
      Self.encodeReverseBytes(
        is64Bit: width == .i64,
        source: register,
        destination: register
      ))
    return true
  }

  /// Extends a pinned byte/word (or signed dword) into a dword/qword destination.
  func emitExtendMove(
    destinationWidth: DoryIRIntegerWidth,
    destinationGuestRegister: Int,
    sourceWidth: DoryIRIntegerWidth,
    sourceGuestRegister: Int,
    signed: Bool,
    into words: inout [UInt32]
  ) -> Bool {
    guard (0..<16).contains(destinationGuestRegister),
      (0..<16).contains(sourceGuestRegister),
      destinationWidth == .i32 || destinationWidth == .i64,
      sourceWidth == .i8 || sourceWidth == .i16
        || (signed && sourceWidth == .i32 && destinationWidth == .i64)
    else { return false }

    let destination = UInt32(destinationGuestRegister)
    let source = UInt32(sourceGuestRegister)
    if signed {
      let opcode: UInt32 = destinationWidth == .i64 ? 0x9340_0000 : 0x1300_0000
      let signBit = UInt32(sourceWidth.rawValue) - 1
      words.append(opcode | signBit << 10 | source << 5 | destination)
    } else {
      Self.emitImmediate(sourceWidth == .i8 ? 0xFF : 0xFFFF, register: 16, into: &words)
      words.append(
        Self.encodeLogical(
          .and,
          is64Bit: true,
          left: source,
          right: 16,
          destination: destination
        ))
    }
    return true
  }

  /// Implements CDQ/CQO from pinned RAX into RDX without changing flags.
  func emitSignExtendAccumulatorHigh(
    width: DoryIRIntegerWidth,
    into words: inout [UInt32]
  ) -> Bool {
    guard width == .i32 || width == .i64 else { return false }
    let is64Bit = width == .i64
    Self.emitImmediate(is64Bit ? 63 : 31, register: 16, into: &words)
    words.append(
      Self.encodeVariableShift(
        .arithmeticRight,
        is64Bit: is64Bit,
        value: 0,
        count: 16,
        destination: 2
      ))
    return true
  }

  /// Inverts a pinned register operand without changing NZCV or lazy flags.
  func emitBitwiseNot(
    width: DoryIRIntegerWidth,
    destinationGuestRegister: Int,
    into words: inout [UInt32]
  ) -> Bool {
    guard (0..<16).contains(destinationGuestRegister) else { return false }
    let destination = UInt32(destinationGuestRegister)
    Self.emitImmediate(Self.mask(for: width), register: 16, into: &words)
    words.append(
      Self.encodeLogical(
        .xor, is64Bit: width != .i32,
        left: destination, right: 16, destination: destination))
    return true
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
    guard (0..<16).contains(destinationGuestRegister),
      Self.validWriteMode(operation: operation, writesDestination: writesDestination)
    else { return nil }
    if case .guestRegister(let sourceRegister) = source {
      guard (0..<16).contains(sourceRegister) else { return nil }
    }

    let isNarrow = width == .i8 || width == .i16
    let alignsNarrowFlags =
      isNarrow
      && operation != .addWithCarry && operation != .subtractWithBorrow
    let lazyOperation: DoryARM64LazyFlagsState.Operation
    let domain: NativeFlags.Domain
    switch operation {
    case .add, .addWithCarry:
      lazyOperation = operation == .add ? .add : .addWithCarry
      domain = isNarrow && operation == .addWithCarry ? .materializedOnly : .addition
    case .subtract, .subtractWithBorrow, .compare:
      lazyOperation = operation == .subtractWithBorrow ? .subtractWithBorrow : .subtract
      domain =
        isNarrow && operation == .subtractWithBorrow
        ? .materializedOnly : .subtraction
    case .and, .test, .or, .xor:
      lazyOperation = .logical
      domain = .logical
    }

    var fragment: [UInt32] = []
    let is64Bit = width == .i64
    let narrowShift = isNarrow ? UInt32(32 - Int(width.rawValue)) : 0
    let mask = Self.mask(for: width)
    let destination = UInt32(destinationGuestRegister)
    if operation == .addWithCarry || operation == .subtractWithBorrow {
      Self.emitCarryFromMaterializedFlags(
        inverted: operation == .subtractWithBorrow, into: &fragment)
    }
    fragment.append(
      Self.encodeMove(
        destination: 16, source: destination, is64Bit: isNarrow || is64Bit))
    if isNarrow {
      Self.emitImmediate(mask, register: 17, into: &fragment)
      fragment.append(
        Self.encodeLogical(
          .and, is64Bit: true, left: 16, right: 17, destination: 16))
    }
    fragment.append(
      Self.encodeStore64(
        register: 16, word: .lazyFlagsSource1))

    switch source {
    case .guestRegister(let sourceRegister):
      fragment.append(
        Self.encodeMove(
          destination: 17, source: UInt32(sourceRegister), is64Bit: isNarrow || is64Bit))
      if isNarrow {
        Self.emitImmediate(mask, register: 26, into: &fragment)
        fragment.append(
          Self.encodeLogical(
            .and, is64Bit: true, left: 17, right: 26, destination: 17))
      }
    case .immediate(let value):
      Self.emitImmediate(value & mask, register: 17, into: &fragment)
    }
    fragment.append(Self.encodeStore64(register: 17, word: .lazyFlagsSource2))

    if alignsNarrowFlags {
      fragment.append(
        Self.encodeLogical(
          .or, is64Bit: false, left: 31, right: 16,
          shiftAmount: narrowShift, destination: 16))
      fragment.append(
        Self.encodeLogical(
          .or, is64Bit: false, left: 31, right: 17,
          shiftAmount: narrowShift, destination: 17))
    }

    let resultRegister = writesDestination && !isNarrow ? destination : 16
    switch operation {
    case .add:
      fragment.append(
        Self.encodeAddSubtractSetFlags(
          add: true, is64Bit: is64Bit, left: 16, right: 17, destination: resultRegister))
    case .addWithCarry:
      fragment.append(
        Self.encodeAddSubtractCarrySetFlags(
          add: true, is64Bit: is64Bit, left: 16, right: 17, destination: resultRegister))
    case .subtract, .compare:
      fragment.append(
        Self.encodeAddSubtractSetFlags(
          add: false, is64Bit: is64Bit, left: 16, right: 17, destination: resultRegister))
    case .subtractWithBorrow:
      fragment.append(
        Self.encodeAddSubtractCarrySetFlags(
          add: false, is64Bit: is64Bit, left: 16, right: 17, destination: resultRegister))
    case .and, .test:
      fragment.append(
        Self.encodeLogical(
          .andSetFlags, is64Bit: is64Bit, left: 16, right: 17,
          destination: resultRegister))
    case .or, .xor:
      fragment.append(
        Self.encodeLogical(
          operation == .or ? .or : .xor, is64Bit: is64Bit,
          left: 16, right: 17, destination: resultRegister))
      fragment.append(
        Self.encodeLogical(
          .andSetFlags, is64Bit: is64Bit, left: resultRegister, right: resultRegister,
          destination: 31))
    }

    if alignsNarrowFlags {
      fragment.append(
        Self.encodeLogical(
          .or, is64Bit: false, left: 31, right: resultRegister,
          shiftAmount: narrowShift, logicalRightShift: true, destination: 16))
    } else if isNarrow {
      Self.emitImmediate(mask, register: 17, into: &fragment)
      fragment.append(
        Self.encodeLogical(
          .and, is64Bit: true, left: resultRegister, right: 17, destination: 16))
    }
    let normalizedResult = isNarrow ? UInt32(16) : resultRegister
    fragment.append(Self.encodeStore64(register: normalizedResult, word: .lazyFlagsResult))
    if writesDestination && isNarrow {
      Self.emitImmediate(~mask, register: 17, into: &fragment)
      fragment.append(
        Self.encodeLogical(
          .and, is64Bit: true, left: destination, right: 17, destination: destination))
      fragment.append(
        Self.encodeLogical(
          .or, is64Bit: true, left: destination, right: 16, destination: destination))
    }
    Self.emitImmediate(UInt64(width.rawValue), register: 17, into: &fragment)
    fragment.append(Self.encodeStore64(register: 17, word: .lazyFlagsWidth))
    Self.emitImmediate(lazyOperation.rawValue, register: 26, into: &fragment)
    fragment.append(Self.encodeStore64(register: 26, word: .lazyFlagsOperation))
    words.append(contentsOf: fragment)
    return .init(origin: .binary(operation), width: width, domain: domain)
  }

  /// Emits an 8-bit binary producer targeting AH/CH/DH/BH without touching surrounding bits.
  func emitHighByteBinary(
    _ operation: DoryIRBinaryOperation,
    destinationLegacyRegister: Int,
    source: HighByteSource,
    writesDestination: Bool,
    into words: inout [UInt32]
  ) -> NativeFlags? {
    guard (0..<4).contains(destinationLegacyRegister),
      Self.validWriteMode(operation: operation, writesDestination: writesDestination)
    else { return nil }
    if case .guestHighByte(let sourceRegister) = source {
      guard (0..<4).contains(sourceRegister) else { return nil }
    }

    let lazyOperation: DoryARM64LazyFlagsState.Operation
    let domain: NativeFlags.Domain
    switch operation {
    case .add:
      lazyOperation = .add
      domain = .addition
    case .addWithCarry:
      lazyOperation = .addWithCarry
      domain = .materializedOnly
    case .subtract, .compare:
      lazyOperation = .subtract
      domain = .subtraction
    case .subtractWithBorrow:
      lazyOperation = .subtractWithBorrow
      domain = .materializedOnly
    case .and, .test, .or, .xor:
      lazyOperation = .logical
      domain = .logical
    }

    var fragment: [UInt32] = []
    let destination = UInt32(destinationLegacyRegister)
    if operation == .addWithCarry || operation == .subtractWithBorrow {
      Self.emitCarryFromMaterializedFlags(
        inverted: operation == .subtractWithBorrow, into: &fragment)
    }
    fragment.append(
      Self.encodeLogical(
        .or, is64Bit: true, left: 31, right: destination,
        shiftAmount: 8, logicalRightShift: true, destination: 16))
    Self.emitImmediate(0xFF, register: 17, into: &fragment)
    fragment.append(
      Self.encodeLogical(
        .and, is64Bit: true, left: 16, right: 17, destination: 16))
    fragment.append(Self.encodeStore64(register: 16, word: .lazyFlagsSource1))

    switch source {
    case .guestHighByte(let sourceRegister):
      fragment.append(
        Self.encodeLogical(
          .or, is64Bit: true, left: 31, right: UInt32(sourceRegister),
          shiftAmount: 8, logicalRightShift: true, destination: 17))
      Self.emitImmediate(0xFF, register: 26, into: &fragment)
      fragment.append(
        Self.encodeLogical(
          .and, is64Bit: true, left: 17, right: 26, destination: 17))
    case .immediate(let value):
      Self.emitImmediate(UInt64(value), register: 17, into: &fragment)
    }
    fragment.append(Self.encodeStore64(register: 17, word: .lazyFlagsSource2))
    let alignsFlags = operation != .addWithCarry && operation != .subtractWithBorrow
    if alignsFlags {
      fragment.append(
        Self.encodeLogical(
          .or, is64Bit: false, left: 31, right: 16, shiftAmount: 24, destination: 16))
      fragment.append(
        Self.encodeLogical(
          .or, is64Bit: false, left: 31, right: 17, shiftAmount: 24, destination: 17))
    }

    switch operation {
    case .add:
      fragment.append(
        Self.encodeAddSubtractSetFlags(
          add: true, is64Bit: false, left: 16, right: 17, destination: 16))
    case .addWithCarry:
      fragment.append(
        Self.encodeAddSubtractCarrySetFlags(
          add: true, is64Bit: false, left: 16, right: 17, destination: 16))
    case .subtract, .compare:
      fragment.append(
        Self.encodeAddSubtractSetFlags(
          add: false, is64Bit: false, left: 16, right: 17, destination: 16))
    case .subtractWithBorrow:
      fragment.append(
        Self.encodeAddSubtractCarrySetFlags(
          add: false, is64Bit: false, left: 16, right: 17, destination: 16))
    case .and, .test:
      fragment.append(
        Self.encodeLogical(
          .andSetFlags, is64Bit: false, left: 16, right: 17, destination: 16))
    case .or, .xor:
      fragment.append(
        Self.encodeLogical(
          operation == .or ? .or : .xor, is64Bit: false,
          left: 16, right: 17, destination: 16))
      fragment.append(
        Self.encodeLogical(
          .andSetFlags, is64Bit: false, left: 16, right: 16, destination: 31))
    }

    if alignsFlags {
      fragment.append(
        Self.encodeLogical(
          .or, is64Bit: false, left: 31, right: 16,
          shiftAmount: 24, logicalRightShift: true, destination: 16))
    } else {
      Self.emitImmediate(0xFF, register: 17, into: &fragment)
      fragment.append(
        Self.encodeLogical(
          .and, is64Bit: true, left: 16, right: 17, destination: 16))
    }
    fragment.append(Self.encodeStore64(register: 16, word: .lazyFlagsResult))
    if writesDestination {
      Self.emitImmediate(~UInt64(0xFF00), register: 17, into: &fragment)
      fragment.append(
        Self.encodeLogical(
          .and, is64Bit: true, left: destination, right: 17, destination: destination))
      fragment.append(
        Self.encodeLogical(
          .or, is64Bit: true, left: destination, right: 16,
          shiftAmount: 8, destination: destination))
    }
    Self.emitImmediate(UInt64(DoryIRIntegerWidth.i8.rawValue), register: 17, into: &fragment)
    fragment.append(Self.encodeStore64(register: 17, word: .lazyFlagsWidth))
    Self.emitImmediate(lazyOperation.rawValue, register: 26, into: &fragment)
    fragment.append(Self.encodeStore64(register: 26, word: .lazyFlagsOperation))
    words.append(contentsOf: fragment)
    return .init(origin: .binary(operation), width: .i8, domain: domain)
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
    guard operation != .bitwiseNot, (0..<16).contains(destinationGuestRegister)
    else { return nil }

    var fragment: [UInt32] = []
    let is64Bit = width == .i64
    let isNarrow = width == .i8 || width == .i16
    let narrowShift = isNarrow ? UInt32(32 - Int(width.rawValue)) : 0
    let mask = Self.mask(for: width)
    let destination = UInt32(destinationGuestRegister)
    fragment.append(
      Self.encodeMove(
        destination: 16, source: destination, is64Bit: isNarrow || is64Bit))
    if isNarrow {
      Self.emitImmediate(mask, register: 17, into: &fragment)
      fragment.append(
        Self.encodeLogical(
          .and, is64Bit: true, left: 16, right: 17, destination: 16))
    }
    fragment.append(Self.encodeStore64(register: 16, word: .lazyFlagsSource1))
    Self.emitImmediate(operation == .negate ? 0 : 1, register: 17, into: &fragment)
    fragment.append(Self.encodeStore64(register: 17, word: .lazyFlagsSource2))
    if isNarrow {
      fragment.append(
        Self.encodeLogical(
          .or, is64Bit: false, left: 31, right: 16,
          shiftAmount: narrowShift, destination: 16))
      fragment.append(
        Self.encodeLogical(
          .or, is64Bit: false, left: 31, right: 17,
          shiftAmount: narrowShift, destination: 17))
    }

    let lazyOperation: DoryARM64LazyFlagsState.Operation
    let domain: NativeFlags.Domain
    switch operation {
    case .increment:
      lazyOperation = .increment
      domain = .carryPreserving
      fragment.append(
        Self.encodeAddSubtractSetFlags(
          add: true, is64Bit: is64Bit, left: 16, right: 17,
          destination: isNarrow ? 16 : destination))
    case .decrement:
      lazyOperation = .decrement
      domain = .carryPreserving
      fragment.append(
        Self.encodeAddSubtractSetFlags(
          add: false, is64Bit: is64Bit, left: 16, right: 17,
          destination: isNarrow ? 16 : destination))
    case .negate:
      lazyOperation = .negate
      domain = .subtraction
      fragment.append(
        Self.encodeAddSubtractSetFlags(
          add: false, is64Bit: is64Bit, left: 31, right: 16,
          destination: isNarrow ? 16 : destination))
    case .bitwiseNot:
      return nil
    }

    if isNarrow {
      fragment.append(
        Self.encodeLogical(
          .or, is64Bit: false, left: 31, right: 16,
          shiftAmount: narrowShift, logicalRightShift: true, destination: 16))
      fragment.append(Self.encodeStore64(register: 16, word: .lazyFlagsResult))
      Self.emitImmediate(~mask, register: 17, into: &fragment)
      fragment.append(
        Self.encodeLogical(
          .and, is64Bit: true, left: destination, right: 17, destination: destination))
      fragment.append(
        Self.encodeLogical(
          .or, is64Bit: true, left: destination, right: 16, destination: destination))
    } else {
      fragment.append(Self.encodeStore64(register: destination, word: .lazyFlagsResult))
    }
    Self.emitImmediate(UInt64(width.rawValue), register: 17, into: &fragment)
    fragment.append(Self.encodeStore64(register: 17, word: .lazyFlagsWidth))
    Self.emitImmediate(lazyOperation.rawValue, register: 26, into: &fragment)
    fragment.append(Self.encodeStore64(register: 26, word: .lazyFlagsOperation))
    words.append(contentsOf: fragment)
    return .init(origin: .unary(operation), width: width, domain: domain)
  }

  /// Emits INC/DEC/NEG against AH/CH/DH/BH while preserving all non-target bits.
  func emitHighByteUnary(
    _ operation: DoryIRUnaryOperation,
    destinationLegacyRegister: Int,
    into words: inout [UInt32]
  ) -> NativeFlags? {
    guard operation != .bitwiseNot, (0..<4).contains(destinationLegacyRegister)
    else { return nil }
    var fragment: [UInt32] = []
    let destination = UInt32(destinationLegacyRegister)
    fragment.append(
      Self.encodeLogical(
        .or, is64Bit: true, left: 31, right: destination,
        shiftAmount: 8, logicalRightShift: true, destination: 16))
    Self.emitImmediate(0xFF, register: 17, into: &fragment)
    fragment.append(
      Self.encodeLogical(
        .and, is64Bit: true, left: 16, right: 17, destination: 16))
    fragment.append(Self.encodeStore64(register: 16, word: .lazyFlagsSource1))
    Self.emitImmediate(operation == .negate ? 0 : 1, register: 17, into: &fragment)
    fragment.append(Self.encodeStore64(register: 17, word: .lazyFlagsSource2))
    fragment.append(
      Self.encodeLogical(
        .or, is64Bit: false, left: 31, right: 16, shiftAmount: 24, destination: 16))
    fragment.append(
      Self.encodeLogical(
        .or, is64Bit: false, left: 31, right: 17, shiftAmount: 24, destination: 17))

    let lazyOperation: DoryARM64LazyFlagsState.Operation
    let domain: NativeFlags.Domain
    switch operation {
    case .increment:
      lazyOperation = .increment
      domain = .carryPreserving
      fragment.append(
        Self.encodeAddSubtractSetFlags(
          add: true, is64Bit: false, left: 16, right: 17, destination: 16))
    case .decrement:
      lazyOperation = .decrement
      domain = .carryPreserving
      fragment.append(
        Self.encodeAddSubtractSetFlags(
          add: false, is64Bit: false, left: 16, right: 17, destination: 16))
    case .negate:
      lazyOperation = .negate
      domain = .subtraction
      fragment.append(
        Self.encodeAddSubtractSetFlags(
          add: false, is64Bit: false, left: 31, right: 16, destination: 16))
    case .bitwiseNot:
      return nil
    }
    fragment.append(
      Self.encodeLogical(
        .or, is64Bit: false, left: 31, right: 16,
        shiftAmount: 24, logicalRightShift: true, destination: 16))
    fragment.append(Self.encodeStore64(register: 16, word: .lazyFlagsResult))
    Self.emitImmediate(~UInt64(0xFF00), register: 17, into: &fragment)
    fragment.append(
      Self.encodeLogical(
        .and, is64Bit: true, left: destination, right: 17, destination: destination))
    fragment.append(
      Self.encodeLogical(
        .or, is64Bit: true, left: destination, right: 16,
        shiftAmount: 8, destination: destination))
    Self.emitImmediate(UInt64(DoryIRIntegerWidth.i8.rawValue), register: 17, into: &fragment)
    fragment.append(Self.encodeStore64(register: 17, word: .lazyFlagsWidth))
    Self.emitImmediate(lazyOperation.rawValue, register: 26, into: &fragment)
    fragment.append(Self.encodeStore64(register: 26, word: .lazyFlagsOperation))
    words.append(contentsOf: fragment)
    return .init(origin: .unary(operation), width: .i8, domain: domain)
  }

  /// Emits SHL/SHR/SAR/ROL/ROR with either an immediate or pinned CL count.
  ///
  /// Shift flags retain undefined or unchanged bits from the prior image, so a nonzero operation
  /// first resolves any older lazy record. CL is masked before execution; its zero path publishes
  /// a materialized descriptor and therefore preserves the resolved flags. These producers do not
  /// return a `NativeFlags` token: condition consumers use the dedicated lazy materializer.
  func emitShift(
    _ operation: DoryIRShiftOperation,
    width: DoryIRIntegerWidth,
    destinationGuestRegister: Int,
    count: DoryIRShiftCount,
    into words: inout [UInt32]
  ) -> Bool {
    guard (0..<16).contains(destinationGuestRegister) else { return false }
    let countMask: UInt64 = width == .i64 ? 0x3F : 0x1F
    if case .immediate(let rawCount) = count,
      UInt64(rawCount) & countMask == 0
    {
      if width == .i32 {
        let destination = UInt32(destinationGuestRegister)
        words.append(
          Self.encodeMove(
            destination: destination, source: destination, is64Bit: false))
      }
      return true
    }

    var fragment: [UInt32] = []
    DoryARM64Tier1BoundaryEmitter().emitMaterializeLazyFlags(into: &fragment)

    switch count {
    case .immediate(let rawCount):
      Self.emitImmediate(UInt64(rawCount) & countMask, register: 17, into: &fragment)
    case .cl:
      Self.emitImmediate(countMask, register: 26, into: &fragment)
      fragment.append(
        Self.encodeLogical(
          .and, is64Bit: true, left: 1, right: 26, destination: 17))
    }

    let destination = UInt32(destinationGuestRegister)
    let is64Bit = width == .i64
    let isNarrow = width == .i8 || width == .i16
    let narrowShift = isNarrow ? UInt32(32 - Int(width.rawValue)) : 0
    let mask = Self.mask(for: width)
    fragment.append(
      Self.encodeMove(
        destination: 16, source: destination, is64Bit: isNarrow || is64Bit))
    if isNarrow {
      Self.emitImmediate(mask, register: 26, into: &fragment)
      fragment.append(
        Self.encodeLogical(
          .and, is64Bit: true, left: 16, right: 26, destination: 16))
    }
    fragment.append(Self.encodeStore64(register: 16, word: .lazyFlagsSource1))
    fragment.append(Self.encodeStore64(register: 31, word: .lazyFlagsSource2))

    switch operation {
    case .left, .logicalRight, .arithmeticRight:
      if isNarrow {
        fragment.append(
          Self.encodeLogical(
            .or, is64Bit: false, left: 31, right: 16,
            shiftAmount: narrowShift, destination: 16))
      }
      let nativeOperation: VariableShiftOperation =
        switch operation {
        case .left: .left
        case .logicalRight: .logicalRight
        case .arithmeticRight: .arithmeticRight
        case .rotateLeft, .rotateRight: preconditionFailure("rotate reached shift lowering")
        }
      fragment.append(
        Self.encodeVariableShift(
          nativeOperation, is64Bit: is64Bit, value: 16, count: 17, destination: 16))
      if isNarrow {
        fragment.append(
          Self.encodeLogical(
            .or, is64Bit: false, left: 31, right: 16,
            shiftAmount: narrowShift, logicalRightShift: true, destination: 16))
      }
    case .rotateLeft, .rotateRight:
      if isNarrow {
        let replicationShift = UInt32(width.rawValue)
        fragment.append(
          Self.encodeLogical(
            .or, is64Bit: false, left: 16, right: 16,
            shiftAmount: replicationShift, destination: 16))
        if width == .i8 {
          fragment.append(
            Self.encodeLogical(
              .or, is64Bit: false, left: 16, right: 16,
              shiftAmount: 16, destination: 16))
        }
      }
      let rotateCount: UInt32
      if operation == .rotateLeft {
        fragment.append(
          Self.encodeAddSubtract(
            add: false, is64Bit: is64Bit, left: 31, right: 17, destination: 26))
        rotateCount = 26
      } else {
        rotateCount = 17
      }
      fragment.append(
        Self.encodeVariableShift(
          .rotateRight, is64Bit: is64Bit, value: 16,
          count: rotateCount, destination: 16))
      if isNarrow {
        Self.emitImmediate(mask, register: 26, into: &fragment)
        fragment.append(
          Self.encodeLogical(
            .and, is64Bit: true, left: 16, right: 26, destination: 16))
      }
    }

    fragment.append(Self.encodeStore64(register: 16, word: .lazyFlagsResult))
    if isNarrow {
      Self.emitImmediate(~mask, register: 26, into: &fragment)
      fragment.append(
        Self.encodeLogical(
          .and, is64Bit: true, left: destination, right: 26, destination: destination))
      fragment.append(
        Self.encodeLogical(
          .or, is64Bit: true, left: destination, right: 16, destination: destination))
    } else if width == .i32 {
      fragment.append(Self.encodeMove(destination: destination, source: 16, is64Bit: false))
    } else {
      fragment.append(Self.encodeMove(destination: destination, source: 16, is64Bit: true))
    }

    Self.emitImmediate(UInt64(width.rawValue), register: 26, into: &fragment)
    fragment.append(Self.encodeStore64(register: 26, word: .lazyFlagsWidth))
    let lazyOperation: DoryARM64LazyFlagsState.Operation =
      switch operation {
      case .left: .shiftLeft
      case .logicalRight: .logicalShiftRight
      case .arithmeticRight: .arithmeticShiftRight
      case .rotateLeft: .rotateLeft
      case .rotateRight: .rotateRight
      }
    Self.emitImmediate(lazyOperation.rawValue, register: 26, into: &fragment)
    fragment.append(
      Self.encodeLogical(
        .or, is64Bit: true, left: 26, right: 17, shiftAmount: 8, destination: 26))
    if case .cl = count {
      fragment.append(
        Self.encodeAddSubtractSetFlags(
          add: false, is64Bit: true, left: 17, right: 31, destination: 31))
      fragment.append(
        Self.encodeConditionalSelect(
          destination: 26,
          trueRegister: 26,
          falseRegister: 31,
          condition: .notEqual
        ))
    }
    fragment.append(Self.encodeStore64(register: 26, word: .lazyFlagsOperation))
    words.append(contentsOf: fragment)
    return true
  }

  /// Emits RCL/RCR as a bounded native bit loop after resolving the incoming carry flag.
  func emitRotateThroughCarry(
    _ operation: CarryRotateOperation,
    width: DoryIRIntegerWidth,
    destinationGuestRegister: Int,
    count: DoryIRShiftCount,
    into words: inout [UInt32]
  ) -> Bool {
    guard (0..<16).contains(destinationGuestRegister) else { return false }
    let countMask: UInt64 = width == .i64 ? 0x3F : 0x1F
    if case .immediate(let rawCount) = count,
      UInt64(rawCount) & countMask == 0
    {
      if width == .i32 {
        let destination = UInt32(destinationGuestRegister)
        words.append(
          Self.encodeMove(
            destination: destination, source: destination, is64Bit: false))
      }
      return true
    }

    var fragment: [UInt32] = []
    DoryARM64Tier1BoundaryEmitter().emitMaterializeLazyFlags(into: &fragment)
    switch count {
    case .immediate(let rawCount):
      Self.emitImmediate(UInt64(rawCount) & countMask, register: 17, into: &fragment)
    case .cl:
      Self.emitImmediate(countMask, register: 26, into: &fragment)
      fragment.append(
        Self.encodeLogical(
          .and, is64Bit: true, left: 1, right: 26, destination: 17))
    }
    fragment.append(Self.encodeStore64(register: 17, word: .lazyFlagsOperation))
    fragment.append(Self.encodeMove(destination: 26, source: 17, is64Bit: true))

    if width == .i8 || width == .i16 {
      Self.emitImmediate(UInt64(width.rawValue) + 1, register: 16, into: &fragment)
      let moduloStart = fragment.count
      fragment.append(
        Self.encodeAddSubtractSetFlags(
          add: false, is64Bit: true, left: 26, right: 16, destination: 31))
      let moduloDoneBranch = fragment.count
      fragment.append(0)
      fragment.append(
        Self.encodeAddSubtract(
          add: false, is64Bit: true, left: 26, right: 16, destination: 26))
      fragment.append(
        Self.encodeUnconditionalBranch(
          wordOffset: moduloStart - (fragment.count)))
      let moduloDone = fragment.count
      fragment[moduloDoneBranch] = Self.encodeConditionalBranch(
        condition: .carryClear, wordOffset: moduloDone - moduloDoneBranch)
    }

    let destination = UInt32(destinationGuestRegister)
    let is64Bit = width == .i64
    let isNarrow = width == .i8 || width == .i16
    let mask = Self.mask(for: width)
    fragment.append(
      Self.encodeMove(
        destination: 16, source: destination, is64Bit: isNarrow || is64Bit))
    if isNarrow {
      Self.emitImmediate(mask, register: 17, into: &fragment)
      fragment.append(
        Self.encodeLogical(
          .and, is64Bit: true, left: 16, right: 17, destination: 16))
    }
    fragment.append(Self.encodeStore64(register: 16, word: .lazyFlagsSource1))
    fragment.append(Self.encodeStore64(register: 31, word: .lazyFlagsSource2))

    Self.emitImmediate(1, register: 17, into: &fragment)
    fragment.append(
      Self.encodeLogical(
        .and, is64Bit: true, left: 25, right: 17, destination: 17))
    let loopStart = fragment.count
    let doneBranch = fragment.count
    fragment.append(0)
    let outgoingZeroBranch = fragment.count
    fragment.append(0)
    Self.emitCarryRotateStep(
      operation, width: width, outgoingCarry: 1, into: &fragment)
    let afterStepBranch = fragment.count
    fragment.append(0)
    let outgoingZero = fragment.count
    Self.emitCarryRotateStep(
      operation, width: width, outgoingCarry: 0, into: &fragment)
    let afterStep = fragment.count
    fragment.append(
      Self.encodeAddSubtractImmediate(
        add: false, is64Bit: true, left: 26, immediate: 1, destination: 26))
    fragment.append(
      Self.encodeCompareAndBranchNonzero(
        register: 26, wordOffset: loopStart - fragment.count))
    let done = fragment.count
    fragment[doneBranch] = Self.encodeCompareAndBranchZero(
      register: 26, wordOffset: done - doneBranch)
    fragment[outgoingZeroBranch] = Self.encodeTestBitAndBranchZero(
      register: 16,
      bit: operation == .left ? UInt32(width.rawValue - 1) : 0,
      wordOffset: outgoingZero - outgoingZeroBranch
    )
    fragment[afterStepBranch] = Self.encodeUnconditionalBranch(
      wordOffset: afterStep - afterStepBranch)

    if isNarrow {
      Self.emitImmediate(mask, register: 17, into: &fragment)
      fragment.append(
        Self.encodeLogical(
          .and, is64Bit: true, left: 16, right: 17, destination: 16))
    }
    fragment.append(Self.encodeStore64(register: 16, word: .lazyFlagsResult))
    if isNarrow {
      Self.emitImmediate(~mask, register: 17, into: &fragment)
      fragment.append(
        Self.encodeLogical(
          .and, is64Bit: true, left: destination, right: 17, destination: destination))
      fragment.append(
        Self.encodeLogical(
          .or, is64Bit: true, left: destination, right: 16, destination: destination))
    } else if width == .i32 {
      fragment.append(Self.encodeMove(destination: destination, source: 16, is64Bit: false))
    } else {
      fragment.append(Self.encodeMove(destination: destination, source: 16, is64Bit: true))
    }

    Self.emitImmediate(UInt64(width.rawValue), register: 17, into: &fragment)
    fragment.append(Self.encodeStore64(register: 17, word: .lazyFlagsWidth))
    fragment.append(Self.encodeLoad64(register: 17, word: .lazyFlagsOperation))
    let lazyOperation: DoryARM64LazyFlagsState.Operation =
      operation == .left ? .rotateCarryLeft : .rotateCarryRight
    Self.emitImmediate(lazyOperation.rawValue, register: 26, into: &fragment)
    fragment.append(
      Self.encodeLogical(
        .or, is64Bit: true, left: 26, right: 17, shiftAmount: 8, destination: 26))
    fragment.append(
      Self.encodeAddSubtractSetFlags(
        add: false, is64Bit: true, left: 17, right: 31, destination: 31))
    fragment.append(
      Self.encodeConditionalSelect(
        destination: 26,
        trueRegister: 26,
        falseRegister: 31,
        condition: .notEqual
      ))
    fragment.append(Self.encodeStore64(register: 26, word: .lazyFlagsOperation))
    words.append(contentsOf: fragment)
    return true
  }

  private static func emitCarryRotateStep(
    _ operation: CarryRotateOperation,
    width: DoryIRIntegerWidth,
    outgoingCarry: UInt64,
    into words: inout [UInt32]
  ) {
    let is64Bit = width == .i64
    if operation == .left {
      words.append(
        encodeLogical(
          .or, is64Bit: is64Bit, left: 31, right: 16,
          shiftAmount: 1, destination: 16))
      words.append(
        encodeLogical(
          .or, is64Bit: is64Bit, left: 16, right: 17, destination: 16))
    } else {
      words.append(
        encodeLogical(
          .or, is64Bit: is64Bit, left: 31, right: 16,
          shiftAmount: 1, logicalRightShift: true, destination: 16))
      words.append(
        encodeLogical(
          .or, is64Bit: is64Bit, left: 16, right: 17,
          shiftAmount: UInt32(width.rawValue - 1), destination: 16))
    }
    emitImmediate(outgoingCarry, register: 17, into: &words)
  }

  /// Emits register SHLD/SHRD for the architectural 16-, 32-, and 64-bit forms.
  func emitDoubleShift(
    _ operation: DoubleShiftOperation,
    width: DoryIRIntegerWidth,
    destinationGuestRegister: Int,
    sourceGuestRegister: Int,
    count: DoryIRShiftCount,
    into words: inout [UInt32]
  ) -> Bool {
    guard width != .i8,
      (0..<16).contains(destinationGuestRegister),
      (0..<16).contains(sourceGuestRegister)
    else { return false }
    let countMask: UInt64 = width == .i64 ? 0x3F : 0x1F
    if case .immediate(let rawCount) = count,
      UInt64(rawCount) & countMask == 0
    {
      if width == .i32 {
        let destination = UInt32(destinationGuestRegister)
        words.append(
          Self.encodeMove(
            destination: destination, source: destination, is64Bit: false))
      }
      return true
    }

    var fragment: [UInt32] = []
    DoryARM64Tier1BoundaryEmitter().emitMaterializeLazyFlags(into: &fragment)
    let destination = UInt32(destinationGuestRegister)
    let source = UInt32(sourceGuestRegister)
    let is64Bit = width == .i64
    let isNarrow = width == .i16
    let mask = Self.mask(for: width)
    fragment.append(
      Self.encodeMove(
        destination: 16, source: destination, is64Bit: isNarrow || is64Bit))
    fragment.append(
      Self.encodeMove(
        destination: 17, source: source, is64Bit: isNarrow || is64Bit))
    if isNarrow {
      Self.emitImmediate(mask, register: 26, into: &fragment)
      fragment.append(
        Self.encodeLogical(
          .and, is64Bit: true, left: 16, right: 26, destination: 16))
      fragment.append(
        Self.encodeLogical(
          .and, is64Bit: true, left: 17, right: 26, destination: 17))
    }
    fragment.append(Self.encodeStore64(register: 16, word: .lazyFlagsSource1))
    fragment.append(Self.encodeStore64(register: 17, word: .lazyFlagsSource2))

    switch count {
    case .immediate(let rawCount):
      Self.emitImmediate(UInt64(rawCount) & countMask, register: 26, into: &fragment)
    case .cl:
      Self.emitImmediate(countMask, register: 26, into: &fragment)
      fragment.append(
        Self.encodeLogical(
          .and, is64Bit: true, left: 1, right: 26, destination: 26))
    }
    fragment.append(Self.encodeStore64(register: 26, word: .lazyFlagsOperation))

    let zeroCountBranch = fragment.count
    fragment.append(0)
    var oversizedBranch: Int?
    if width == .i16 {
      fragment.append(
        Self.encodeAddSubtractImmediateSetFlags(
          add: false, is64Bit: true, left: 26, immediate: 16, destination: 31))
      oversizedBranch = fragment.count
      fragment.append(0)
    }

    let firstShift: VariableShiftOperation = operation == .left ? .left : .logicalRight
    fragment.append(
      Self.encodeVariableShift(
        firstShift, is64Bit: is64Bit, value: 16, count: 26, destination: 16))
    fragment.append(
      Self.encodeAddSubtract(
        add: false, is64Bit: is64Bit, left: 31, right: 26, destination: 26))
    if width == .i16 {
      fragment.append(
        Self.encodeAddSubtractImmediate(
          add: true, is64Bit: false, left: 26, immediate: 16, destination: 26))
    }
    let secondShift: VariableShiftOperation = operation == .left ? .logicalRight : .left
    fragment.append(
      Self.encodeVariableShift(
        secondShift, is64Bit: is64Bit, value: 17, count: 26, destination: 17))
    fragment.append(
      Self.encodeLogical(
        .or, is64Bit: is64Bit, left: 16, right: 17, destination: 16))
    let calculatedDoneBranch = fragment.count
    fragment.append(0)
    let oversizedStart = fragment.count
    if let oversizedBranch {
      Self.emitImmediate(0, register: 16, into: &fragment)
      fragment[oversizedBranch] = Self.encodeConditionalBranch(
        condition: .higher, wordOffset: oversizedStart - oversizedBranch)
    }
    let calculationDone = fragment.count
    fragment[zeroCountBranch] = Self.encodeCompareAndBranchZero(
      register: 26, wordOffset: calculationDone - zeroCountBranch)
    fragment[calculatedDoneBranch] = Self.encodeUnconditionalBranch(
      wordOffset: calculationDone - calculatedDoneBranch)

    if isNarrow {
      Self.emitImmediate(mask, register: 17, into: &fragment)
      fragment.append(
        Self.encodeLogical(
          .and, is64Bit: true, left: 16, right: 17, destination: 16))
    }
    fragment.append(Self.encodeStore64(register: 16, word: .lazyFlagsResult))
    if isNarrow {
      Self.emitImmediate(~mask, register: 17, into: &fragment)
      fragment.append(
        Self.encodeLogical(
          .and, is64Bit: true, left: destination, right: 17, destination: destination))
      fragment.append(
        Self.encodeLogical(
          .or, is64Bit: true, left: destination, right: 16, destination: destination))
    } else if width == .i32 {
      fragment.append(Self.encodeMove(destination: destination, source: 16, is64Bit: false))
    } else {
      fragment.append(Self.encodeMove(destination: destination, source: 16, is64Bit: true))
    }

    Self.emitImmediate(UInt64(width.rawValue), register: 17, into: &fragment)
    fragment.append(Self.encodeStore64(register: 17, word: .lazyFlagsWidth))
    fragment.append(Self.encodeLoad64(register: 17, word: .lazyFlagsOperation))
    let lazyOperation: DoryARM64LazyFlagsState.Operation =
      operation == .left ? .doubleShiftLeft : .doubleShiftRight
    Self.emitImmediate(lazyOperation.rawValue, register: 26, into: &fragment)
    fragment.append(
      Self.encodeLogical(
        .or, is64Bit: true, left: 26, right: 17, shiftAmount: 8, destination: 26))
    fragment.append(
      Self.encodeAddSubtractSetFlags(
        add: false, is64Bit: true, left: 17, right: 31, destination: 31))
    fragment.append(
      Self.encodeConditionalSelect(
        destination: 26,
        trueRegister: 26,
        falseRegister: 31,
        condition: .notEqual
      ))
    fragment.append(Self.encodeStore64(register: 26, word: .lazyFlagsOperation))
    words.append(contentsOf: fragment)
    return true
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
    fragment.append(
      Self.encodeLogical(
        .and, is64Bit: true, left: destination, right: 17, destination: destination))
    fragment.append(
      Self.encodeLogical(
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
      fragment.append(
        Self.encodeConditionalSelect(
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
    fragment.append(
      Self.encodeLogical(
        .and, is64Bit: true, left: destination, right: 26, destination: destination))
    fragment.append(
      Self.encodeLogical(
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
    fragment.append(
      Self.encodeAddSubtractSetFlags(
        add: false, is64Bit: true, left: 16, right: 31, destination: 31))
    let destination = UInt32(destinationGuestRegister)
    fragment.append(
      Self.encodeConditionalSelect(
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
    fragment.append(
      Self.encodeLogical(
        .and, is64Bit: true, left: 25, right: 16, destination: 16))
    Self.emitImmediate(DoryX86RFLAGS.reservedOne.rawValue, register: 17, into: &fragment)
    fragment.append(
      Self.encodeLogical(
        .or, is64Bit: true, left: 16, right: 17, destination: 16))
    Self.emitImmediate(~UInt64(0xFF00), register: 17, into: &fragment)
    fragment.append(
      Self.encodeLogical(
        .and, is64Bit: true, left: 0, right: 17, destination: 0))
    fragment.append(
      Self.encodeLogical(
        .or, is64Bit: true, left: 0, right: 16, shiftAmount: 8, destination: 0))
    words.append(contentsOf: fragment)
  }

  /// Materializes an older record and applies SAHF's AH image to the five writable status flags.
  func emitStoreAHIntoFlags(into words: inout [UInt32]) {
    var fragment: [UInt32] = []
    DoryARM64Tier1BoundaryEmitter().emitMaterializeLazyFlags(into: &fragment)
    fragment.append(
      Self.encodeLogical(
        .or, is64Bit: true, left: 31, right: 0,
        shiftAmount: 8, logicalRightShift: true, destination: 16))
    Self.emitImmediate(0xD5, register: 17, into: &fragment)
    fragment.append(
      Self.encodeLogical(
        .and, is64Bit: true, left: 16, right: 17, destination: 16))
    Self.emitImmediate(~UInt64(0xD5), register: 17, into: &fragment)
    fragment.append(
      Self.encodeLogical(
        .and, is64Bit: true, left: 25, right: 17, destination: 25))
    fragment.append(
      Self.encodeLogical(
        .or, is64Bit: true, left: 25, right: 16, destination: 25))
    Self.emitImmediate(DoryX86RFLAGS.reservedOne.rawValue, register: 17, into: &fragment)
    fragment.append(
      Self.encodeLogical(
        .or, is64Bit: true, left: 25, right: 17, destination: 25))
    words.append(contentsOf: fragment)
  }

  /// Resolves an older producer before replacing CF with the requested architectural value.
  func emitSetCarryFlag(enabled: Bool, into words: inout [UInt32]) {
    var fragment: [UInt32] = []
    DoryARM64Tier1BoundaryEmitter().emitMaterializeLazyFlags(into: &fragment)
    Self.emitImmediate(
      enabled ? DoryX86RFLAGS.carry.rawValue : ~DoryX86RFLAGS.carry.rawValue,
      register: 16,
      into: &fragment
    )
    fragment.append(
      Self.encodeLogical(
        enabled ? .or : .and,
        is64Bit: true,
        left: 25,
        right: 16,
        destination: 25
      ))
    words.append(contentsOf: fragment)
  }

  /// Resolves an older producer before toggling its materialized CF image.
  func emitComplementCarryFlag(into words: inout [UInt32]) {
    var fragment: [UInt32] = []
    DoryARM64Tier1BoundaryEmitter().emitMaterializeLazyFlags(into: &fragment)
    Self.emitImmediate(DoryX86RFLAGS.carry.rawValue, register: 16, into: &fragment)
    fragment.append(
      Self.encodeLogical(
        .xor, is64Bit: true, left: 25, right: 16, destination: 25))
    words.append(contentsOf: fragment)
  }

  /// Updates a non-arithmetic flag without forcing a pending arithmetic record.
  func emitSetNonArithmeticFlag(
    _ flag: DoryX86RFLAGS,
    enabled: Bool,
    into words: inout [UInt32]
  ) {
    Self.emitImmediate(enabled ? flag.rawValue : ~flag.rawValue, register: 16, into: &words)
    words.append(
      Self.encodeLogical(
        enabled ? .or : .and,
        is64Bit: true,
        left: 25,
        right: 16,
        destination: 25
      ))
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
    fragment.append(
      Self.encodeLogical(
        .and, is64Bit: true, left: 25, right: 16, destination: destination))
    Self.emitImmediate(DoryX86RFLAGS.reservedOne.rawValue, register: 16, into: &fragment)
    fragment.append(
      Self.encodeLogical(
        .or, is64Bit: true, left: destination, right: 16, destination: destination))
    words.append(contentsOf: fragment)
    return true
  }

  /// Resolves lazy flags and performs one restartable PUSHQ through the preserved write callback.
  /// The source is staged before RSP changes, preserving PUSH RSP semantics.
  func emitStackPush(source: Source, into words: inout [UInt32]) -> Bool {
    if case .guestRegister(let sourceRegister) = source {
      guard (0..<16).contains(sourceRegister) else { return false }
    }
    var fragment: [UInt32] = []
    DoryARM64Tier1BoundaryEmitter().emitMaterializeLazyFlags(into: &fragment)

    fragment.append(
      Self.encodeAddSubtractImmediate(
        add: false, is64Bit: true, left: 4, immediate: 8, destination: 16))
    fragment.append(Self.encodeStore64(register: 16, word: .lazyFlagsSource1))
    switch source {
    case .guestRegister(let sourceRegister):
      fragment.append(
        Self.encodeStore64(register: UInt32(sourceRegister), word: .lazyFlagsSource2))
    case .immediate(let value):
      Self.emitImmediate(value, register: 17, into: &fragment)
      fragment.append(Self.encodeStore64(register: 17, word: .lazyFlagsSource2))
    }

    for (index, register) in DoryARM64Tier1ABI.guestRegisterMap.enumerated() {
      fragment.append(
        Self.encodeStore64(
          register: register,
          word: DoryARM64Tier1ABI.ContextWord(rawValue: index)!))
    }
    fragment.append(Self.encodeMove(destination: 0, source: 19, is64Bit: true))
    fragment.append(Self.encodeLoad64(register: 1, word: .lazyFlagsSource1))
    fragment.append(Self.encodeLoad64(register: 2, word: .lazyFlagsSource2))
    Self.emitImmediate(8, register: 3, into: &fragment)
    fragment.append(Self.encodeBranchWithLink(register: 21))
    for (index, register) in DoryARM64Tier1ABI.guestRegisterMap.enumerated() {
      fragment.append(
        Self.encodeLoad64(
          register: register,
          word: DoryARM64Tier1ABI.ContextWord(rawValue: index)!))
    }
    fragment.append(Self.encodeLoad64(register: 4, word: .lazyFlagsSource1))
    words.append(contentsOf: fragment)
    return true
  }

  /// Resolves lazy flags and performs one restartable POPQ through the preserved read callback.
  /// POP RSP installs the loaded value; every other destination observes old RSP plus eight.
  func emitStackPop(destinationGuestRegister: Int, into words: inout [UInt32]) -> Bool {
    guard (0..<16).contains(destinationGuestRegister) else { return false }
    var fragment: [UInt32] = []
    DoryARM64Tier1BoundaryEmitter().emitMaterializeLazyFlags(into: &fragment)

    fragment.append(Self.encodeStore64(register: 4, word: .lazyFlagsSource1))
    for (index, register) in DoryARM64Tier1ABI.guestRegisterMap.enumerated() {
      fragment.append(
        Self.encodeStore64(
          register: register,
          word: DoryARM64Tier1ABI.ContextWord(rawValue: index)!))
    }
    fragment.append(Self.encodeMove(destination: 0, source: 19, is64Bit: true))
    fragment.append(Self.encodeLoad64(register: 1, word: .lazyFlagsSource1))
    Self.emitImmediate(8, register: 2, into: &fragment)
    fragment.append(Self.encodeBranchWithLink(register: 20))
    fragment.append(Self.encodeStore64(register: 0, word: .lazyFlagsSource2))
    for (index, register) in DoryARM64Tier1ABI.guestRegisterMap.enumerated() {
      fragment.append(
        Self.encodeLoad64(
          register: register,
          word: DoryARM64Tier1ABI.ContextWord(rawValue: index)!))
    }
    let destination = UInt32(destinationGuestRegister)
    fragment.append(Self.encodeLoad64(register: destination, word: .lazyFlagsSource2))
    if destinationGuestRegister != 4 {
      fragment.append(
        Self.encodeAddSubtractImmediate(
          add: true, is64Bit: true, left: 4, immediate: 8, destination: 4))
    }
    words.append(contentsOf: fragment)
    return true
  }

  /// Materializes flags and performs one restartable PUSHFQ through the generated-function
  /// memory callback. The executor discards the temporary context when that callback reports a
  /// fault, so RSP is published only together with a successful eight-byte stack write.
  func emitPushFlags(into words: inout [UInt32]) {
    var fragment: [UInt32] = []
    DoryARM64Tier1BoundaryEmitter().emitMaterializeLazyFlags(into: &fragment)

    fragment.append(
      Self.encodeAddSubtractImmediate(
        add: false, is64Bit: true, left: 4, immediate: 8, destination: 16))
    fragment.append(Self.encodeStore64(register: 16, word: .lazyFlagsSource1))

    Self.emitImmediate(
      ~(DoryX86RFLAGS.resume.rawValue | DoryX86RFLAGS.virtual8086.rawValue),
      register: 16,
      into: &fragment
    )
    fragment.append(
      Self.encodeLogical(
        .and, is64Bit: true, left: 25, right: 16, destination: 17))
    Self.emitImmediate(DoryX86RFLAGS.reservedOne.rawValue, register: 16, into: &fragment)
    fragment.append(
      Self.encodeLogical(
        .or, is64Bit: true, left: 17, right: 16, destination: 17))
    fragment.append(Self.encodeStore64(register: 17, word: .lazyFlagsSource2))

    for (index, register) in DoryARM64Tier1ABI.guestRegisterMap.enumerated() {
      fragment.append(
        Self.encodeStore64(
          register: register,
          word: DoryARM64Tier1ABI.ContextWord(rawValue: index)!))
    }
    fragment.append(Self.encodeMove(destination: 0, source: 19, is64Bit: true))
    fragment.append(Self.encodeLoad64(register: 1, word: .lazyFlagsSource1))
    fragment.append(Self.encodeLoad64(register: 2, word: .lazyFlagsSource2))
    Self.emitImmediate(8, register: 3, into: &fragment)
    fragment.append(Self.encodeBranchWithLink(register: 21))
    for (index, register) in DoryARM64Tier1ABI.guestRegisterMap.enumerated() {
      fragment.append(
        Self.encodeLoad64(
          register: register,
          word: DoryARM64Tier1ABI.ContextWord(rawValue: index)!))
    }
    fragment.append(Self.encodeLoad64(register: 4, word: .lazyFlagsSource1))
    words.append(contentsOf: fragment)
  }

  /// Emits the materialized x86 predicate as zero/one in x16. Uses x17 as the constant one and
  /// x26 as scratch; callers must clear x26 before returning to the pinned lazy-state convention.
  private static func emitConditionFromMaterializedFlags(
    _ condition: DoryX86Condition,
    into words: inout [UInt32]
  ) {
    emitImmediate(1, register: 17, into: &words)

    func emitFlag(_ flag: DoryX86RFLAGS, into result: UInt32) {
      words.append(
        encodeLogical(
          .or,
          is64Bit: true,
          left: 31,
          right: 25,
          shiftAmount: UInt32(flag.rawValue.trailingZeroBitCount),
          logicalRightShift: true,
          destination: result
        ))
      words.append(
        encodeLogical(
          .and, is64Bit: true, left: result, right: 17, destination: result))
    }

    func invert(_ result: UInt32) {
      words.append(
        encodeLogical(
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
      words.append(
        encodeLogical(
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
      words.append(
        encodeLogical(
          .xor, is64Bit: true, left: 16, right: 26, destination: 16))
      if condition == .greaterOrEqual { invert(16) }
    case .lessOrEqual, .greater:
      emitFlag(.sign, into: 16)
      emitFlag(.overflow, into: 26)
      words.append(
        encodeLogical(
          .xor, is64Bit: true, left: 16, right: 26, destination: 16))
      emitFlag(.zero, into: 26)
      words.append(
        encodeLogical(
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

  private static func mask(for width: DoryIRIntegerWidth) -> UInt64 {
    width == .i64 ? .max : (UInt64(1) << width.rawValue) - 1
  }

  private enum ConditionLowering {
    case condition(ARM64Condition)
    case constant(Bool)
  }

  private static func lowering(
    _ condition: DoryX86Condition,
    domain: NativeFlags.Domain
  ) -> ConditionLowering? {
    guard domain != .materializedOnly else { return nil }
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
      case .materializedOnly: nil
      }
    case .aboveOrEqual:
      return switch domain {
      case .addition: .condition(.carryClear)
      case .subtraction: .condition(.carrySet)
      case .logical: .constant(true)
      case .carryPreserving: nil
      case .materializedOnly: nil
      }
    case .belowOrEqual:
      return switch domain {
      case .addition: nil
      case .subtraction: .condition(.lowerOrSame)
      case .logical: .condition(.equal)
      case .carryPreserving: nil
      case .materializedOnly: nil
      }
    case .above:
      return switch domain {
      case .addition: nil
      case .subtraction: .condition(.higher)
      case .logical: .condition(.notEqual)
      case .carryPreserving: nil
      case .materializedOnly: nil
      }
    }
  }

  private enum LogicalOperation {
    case and, or, xor, andSetFlags
  }

  private enum VariableShiftOperation {
    case left, logicalRight, arithmeticRight, rotateRight
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

  private static func encodeReverseBytes(
    is64Bit: Bool,
    source: UInt32,
    destination: UInt32
  ) -> UInt32 {
    (is64Bit ? 0xDAC0_0C00 : 0x5AC0_0800) | source << 5 | destination
  }

  private static func encodeReverseBits(
    is64Bit: Bool,
    source: UInt32,
    destination: UInt32
  ) -> UInt32 {
    (is64Bit ? 0xDAC0_0000 : 0x5AC0_0000) | source << 5 | destination
  }

  private static func encodeCountLeadingZeros(
    is64Bit: Bool,
    source: UInt32,
    destination: UInt32
  ) -> UInt32 {
    (is64Bit ? 0xDAC0_1000 : 0x5AC0_1000) | source << 5 | destination
  }

  private static func encodeMultiply64(
    left: UInt32,
    right: UInt32,
    destination: UInt32
  ) -> UInt32 {
    0x9B00_7C00 | right << 16 | left << 5 | destination
  }

  private static func encodeSignedMultiplyHigh64(
    left: UInt32,
    right: UInt32,
    destination: UInt32
  ) -> UInt32 {
    0x9B40_7C00 | right << 16 | left << 5 | destination
  }

  private static func encodeSignedMultiplyLong32(
    left: UInt32,
    right: UInt32,
    destination: UInt32
  ) -> UInt32 {
    0x9B20_7C00 | right << 16 | left << 5 | destination
  }

  private static func encodeSignExtend32To64(
    source: UInt32,
    destination: UInt32
  ) -> UInt32 {
    0x9340_7C00 | source << 5 | destination
  }

  private static func encodeStore64(
    register: UInt32,
    word: DoryARM64Tier1ABI.ContextWord
  ) -> UInt32 {
    0xF900_0000 | UInt32(word.rawValue) << 10
      | DoryARM64Tier1ABI.contextRegister << 5 | register
  }

  private static func encodeLoad64(
    register: UInt32,
    word: DoryARM64Tier1ABI.ContextWord
  ) -> UInt32 {
    0xF940_0000 | UInt32(word.rawValue) << 10
      | DoryARM64Tier1ABI.contextRegister << 5 | register
  }

  private static func encodeBranchWithLink(register: UInt32) -> UInt32 {
    0xD63F_0000 | register << 5
  }

  private static func encodeAddSubtractSetFlags(
    add: Bool,
    is64Bit: Bool,
    left: UInt32,
    right: UInt32,
    destination: UInt32
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

  private static func encodeAddSubtract(
    add: Bool,
    is64Bit: Bool,
    left: UInt32,
    right: UInt32,
    leftShift: UInt32 = 0,
    destination: UInt32
  ) -> UInt32 {
    precondition(leftShift < (is64Bit ? 64 : 32))
    let base: UInt32 =
      switch (add, is64Bit) {
      case (true, true): 0x8B00_0000
      case (true, false): 0x0B00_0000
      case (false, true): 0xCB00_0000
      case (false, false): 0x4B00_0000
      }
    return base | right << 16 | leftShift << 10 | left << 5 | destination
  }

  private static func encodeAddSubtractImmediate(
    add: Bool,
    is64Bit: Bool,
    left: UInt32,
    immediate: UInt32,
    destination: UInt32
  ) -> UInt32 {
    precondition(immediate < 4096)
    let base: UInt32 =
      switch (add, is64Bit) {
      case (true, true): 0x9100_0000
      case (true, false): 0x1100_0000
      case (false, true): 0xD100_0000
      case (false, false): 0x5100_0000
      }
    return base | immediate << 10 | left << 5 | destination
  }

  private static func encodeAddSubtractImmediateSetFlags(
    add: Bool,
    is64Bit: Bool,
    left: UInt32,
    immediate: UInt32,
    destination: UInt32
  ) -> UInt32 {
    precondition(immediate < 4096)
    let base: UInt32 =
      switch (add, is64Bit) {
      case (true, true): 0xB100_0000
      case (true, false): 0x3100_0000
      case (false, true): 0xF100_0000
      case (false, false): 0x7100_0000
      }
    return base | immediate << 10 | left << 5 | destination
  }

  private static func encodeAddSubtractCarrySetFlags(
    add: Bool,
    is64Bit: Bool,
    left: UInt32,
    right: UInt32,
    destination: UInt32
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

  private static func emitCarryFromMaterializedFlags(
    inverted: Bool,
    into words: inout [UInt32]
  ) {
    emitImmediate(1, register: 17, into: &words)
    words.append(
      encodeLogical(
        .and, is64Bit: true, left: 25, right: 17, destination: 16))
    if inverted {
      words.append(
        encodeLogical(
          .xor, is64Bit: true, left: 16, right: 17, destination: 16))
    }
    words.append(
      encodeAddSubtractSetFlags(
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

  private static func encodeVariableShift(
    _ operation: VariableShiftOperation,
    is64Bit: Bool,
    value: UInt32,
    count: UInt32,
    destination: UInt32
  ) -> UInt32 {
    let base: UInt32 =
      switch (operation, is64Bit) {
      case (.left, true): 0x9AC0_2000
      case (.left, false): 0x1AC0_2000
      case (.logicalRight, true): 0x9AC0_2400
      case (.logicalRight, false): 0x1AC0_2400
      case (.arithmeticRight, true): 0x9AC0_2800
      case (.arithmeticRight, false): 0x1AC0_2800
      case (.rotateRight, true): 0x9AC0_2C00
      case (.rotateRight, false): 0x1AC0_2C00
      }
    return base | count << 16 | value << 5 | destination
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

  private static func encodeCompareAndBranchNonzero(
    register: UInt32,
    wordOffset: Int
  ) -> UInt32 {
    precondition((-262_144..<262_144).contains(wordOffset))
    return 0xB500_0000
      | (UInt32(truncatingIfNeeded: wordOffset) & 0x7_FFFF) << 5
      | register
  }

  private static func encodeTestBitAndBranchZero(
    register: UInt32,
    bit: UInt32,
    wordOffset: Int
  ) -> UInt32 {
    precondition(bit < 64)
    precondition((-8192..<8192).contains(wordOffset))
    return 0x3600_0000
      | (bit & 0x20) << 26
      | (bit & 0x1F) << 19
      | (UInt32(truncatingIfNeeded: wordOffset) & 0x3FFF) << 5
      | register
  }
}
