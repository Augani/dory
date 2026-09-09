/// Machine-code fragments for crossing between the Darwin C ABI and the pinned tier-1 ABI.
///
/// Tier-1 blocks can concatenate `emitEntry`, translated body words, helper shims, and `emitExit`.
/// The fragments deliberately have no Swift-ABI dependency; every architectural access uses the
/// stable context-word indices in `DoryARM64Tier1ABI`.
struct DoryARM64Tier1BoundaryEmitter: Sendable {
  enum HelperArgument: Sendable, Equatable {
    case contextPointer
    case guestRegister(Int)
    case immediate(UInt64)
    case contextWordValue(DoryARM64Tier1ABI.ContextWord)
    case contextWordAddress(DoryARM64Tier1ABI.ContextWord)
  }

  struct HelperCall: Sendable, Equatable {
    let target: DoryARM64Tier1ABI.ContextWord
    let arguments: [HelperArgument]
    let liveGuestMask: UInt16
    let resultGuestRegister: Int?

    init(
      target: DoryARM64Tier1ABI.ContextWord,
      arguments: [HelperArgument],
      liveGuestMask: UInt16,
      resultGuestRegister: Int? = nil
    ) {
      precondition(arguments.count <= 8, "Darwin register helper ABI has eight arguments")
      if let resultGuestRegister {
        precondition((0..<16).contains(resultGuestRegister))
      }
      for argument in arguments {
        if case .guestRegister(let index) = argument {
          precondition((0..<16).contains(index))
          precondition(
            liveGuestMask & (UInt16(1) << UInt16(index)) != 0,
            "a guest helper argument must be checkpointed before argument marshalling"
          )
        }
      }
      self.target = target
      self.arguments = arguments
      self.liveGuestMask = liveGuestMask
      self.resultGuestRegister = resultGuestRegister
    }
  }

  private static let hostFrameByteCount = 12 * MemoryLayout<UInt64>.stride

  /// Saves the Darwin callee-saved register set owned by tier-1, installs x28, and loads every
  /// architectural GPR plus RIP and the currently materialized RFLAGS image.
  func emitEntry(into words: inout [UInt32]) {
    words.append(Self.encodeSubtractImmediate(left: 31, immediate: Self.hostFrameByteCount,
      destination: 31))
    for (pairIndex, first) in stride(from: 19, through: 29, by: 2).enumerated() {
      words.append(Self.encodeStorePair(
        first: UInt32(first), second: UInt32(first + 1), base: 31,
        byteOffset: pairIndex * 16))
    }
    words.append(Self.encodeMove(destination: 28, source: 0))
    for (index, register) in DoryARM64Tier1ABI.guestRegisterMap.enumerated() {
      words.append(Self.encodeLoad64(
        register: register, base: 28,
        byteOffset: DoryARM64Tier1ABI.ContextWord(rawValue: index)!.byteOffset))
    }
    words.append(Self.encodeLoad64(
      register: DoryARM64Tier1ABI.guestRIPRegister, base: 28,
      byteOffset: DoryARM64Tier1ABI.ContextWord.rip.byteOffset))
    words.append(Self.encodeLoad64(
      register: DoryARM64Tier1ABI.lazyFlagsRegisters[0], base: 28,
      byteOffset: DoryARM64Tier1ABI.ContextWord.rflags.byteOffset))
    words.append(Self.encodeMove(
      destination: DoryARM64Tier1ABI.lazyFlagsRegisters[1], source: 31))
  }

  /// Emits one conservative helper boundary. Only the live pinned guest subset is checkpointed
  /// and restored; RIP and materialized flags are always published because a helper may fault,
  /// interrupt, or request interpreter fallback.
  func emitHelperCall(_ call: HelperCall, into words: inout [UInt32]) {
    for register in DoryARM64Tier1ABI.helperSpillRegisters(
      liveGuestMask: call.liveGuestMask
    ) {
      words.append(Self.encodeStore64(
        register: register, base: DoryARM64Tier1ABI.contextRegister,
        byteOffset: DoryARM64Tier1ABI.ContextWord(rawValue: Int(register))!.byteOffset))
    }
    words.append(Self.encodeStore64(
      register: DoryARM64Tier1ABI.guestRIPRegister,
      base: DoryARM64Tier1ABI.contextRegister,
      byteOffset: DoryARM64Tier1ABI.ContextWord.rip.byteOffset))
    words.append(Self.encodeStore64(
      register: DoryARM64Tier1ABI.lazyFlagsRegisters[0],
      base: DoryARM64Tier1ABI.contextRegister,
      byteOffset: DoryARM64Tier1ABI.ContextWord.rflags.byteOffset))
    words.append(Self.encodeLoad64(
      register: DoryARM64Tier1ABI.scratchRegisters[0],
      base: DoryARM64Tier1ABI.contextRegister,
      byteOffset: call.target.byteOffset))

    for (argumentRegister, argument) in call.arguments.enumerated() {
      let destination = UInt32(argumentRegister)
      switch argument {
      case .contextPointer:
        words.append(Self.encodeMove(
          destination: destination, source: DoryARM64Tier1ABI.contextRegister))
      case .guestRegister(let index):
        words.append(Self.encodeLoad64(
          register: destination, base: DoryARM64Tier1ABI.contextRegister,
          byteOffset: DoryARM64Tier1ABI.ContextWord(rawValue: index)!.byteOffset))
      case .immediate(let value):
        Self.emitImmediate(value, register: destination, into: &words)
      case .contextWordValue(let word):
        words.append(Self.encodeLoad64(
          register: destination, base: DoryARM64Tier1ABI.contextRegister,
          byteOffset: word.byteOffset))
      case .contextWordAddress(let word):
        words.append(Self.encodeAddImmediate(
          left: DoryARM64Tier1ABI.contextRegister,
          immediate: word.byteOffset,
          destination: destination))
      }
    }
    words.append(Self.encodeBranchWithLink(register: DoryARM64Tier1ABI.scratchRegisters[0]))

    if call.resultGuestRegister != nil {
      words.append(Self.encodeMove(
        destination: DoryARM64Tier1ABI.scratchRegisters[1], source: 0))
    }
    for register in DoryARM64Tier1ABI.helperSpillRegisters(
      liveGuestMask: call.liveGuestMask
    ) where Int(register) != call.resultGuestRegister {
      words.append(Self.encodeLoad64(
        register: register, base: DoryARM64Tier1ABI.contextRegister,
        byteOffset: DoryARM64Tier1ABI.ContextWord(rawValue: Int(register))!.byteOffset))
    }
    if let resultGuestRegister = call.resultGuestRegister {
      words.append(Self.encodeMove(
        destination: UInt32(resultGuestRegister),
        source: DoryARM64Tier1ABI.scratchRegisters[1]))
    }
  }

  /// Publishes pinned architectural state, restores the host ABI, and returns the dispatcher code.
  func emitExit(_ exitCode: DoryJITExitCode, into words: inout [UInt32]) {
    for (index, register) in DoryARM64Tier1ABI.guestRegisterMap.enumerated() {
      words.append(Self.encodeStore64(
        register: register, base: DoryARM64Tier1ABI.contextRegister,
        byteOffset: DoryARM64Tier1ABI.ContextWord(rawValue: index)!.byteOffset))
    }
    words.append(Self.encodeStore64(
      register: DoryARM64Tier1ABI.guestRIPRegister,
      base: DoryARM64Tier1ABI.contextRegister,
      byteOffset: DoryARM64Tier1ABI.ContextWord.rip.byteOffset))
    words.append(Self.encodeStore64(
      register: DoryARM64Tier1ABI.lazyFlagsRegisters[0],
      base: DoryARM64Tier1ABI.contextRegister,
      byteOffset: DoryARM64Tier1ABI.ContextWord.rflags.byteOffset))
    words.append(Self.encodeMoveWideZero32(
      register: 0, immediate: UInt16(exitCode.rawValue)))
    for (pairIndex, first) in stride(from: 19, through: 29, by: 2).enumerated() {
      words.append(Self.encodeLoadPair(
        first: UInt32(first), second: UInt32(first + 1), base: 31,
        byteOffset: pairIndex * 16))
    }
    words.append(Self.encodeAddImmediate(
      left: 31, immediate: Self.hostFrameByteCount, destination: 31))
    words.append(0xD65F_03C0)  // ret
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

  private static func encodeMove(destination: UInt32, source: UInt32) -> UInt32 {
    0xAA00_03E0 | source << 16 | destination
  }

  private static func encodeLoad64(register: UInt32, base: UInt32, byteOffset: Int) -> UInt32 {
    precondition(byteOffset >= 0 && byteOffset.isMultiple(of: 8) && byteOffset / 8 < 4_096)
    return 0xF940_0000 | UInt32(byteOffset / 8) << 10 | base << 5 | register
  }

  private static func encodeStore64(register: UInt32, base: UInt32, byteOffset: Int) -> UInt32 {
    precondition(byteOffset >= 0 && byteOffset.isMultiple(of: 8) && byteOffset / 8 < 4_096)
    return 0xF900_0000 | UInt32(byteOffset / 8) << 10 | base << 5 | register
  }

  private static func encodeStorePair(
    first: UInt32,
    second: UInt32,
    base: UInt32,
    byteOffset: Int
  ) -> UInt32 {
    precondition(byteOffset >= 0 && byteOffset.isMultiple(of: 8) && byteOffset / 8 < 64)
    return 0xA900_0000 | UInt32(byteOffset / 8) << 15 | second << 10 | base << 5 | first
  }

  private static func encodeLoadPair(
    first: UInt32,
    second: UInt32,
    base: UInt32,
    byteOffset: Int
  ) -> UInt32 {
    precondition(byteOffset >= 0 && byteOffset.isMultiple(of: 8) && byteOffset / 8 < 64)
    return 0xA940_0000 | UInt32(byteOffset / 8) << 15 | second << 10 | base << 5 | first
  }

  private static func encodeAddImmediate(
    left: UInt32,
    immediate: Int,
    destination: UInt32
  ) -> UInt32 {
    precondition((0..<4_096).contains(immediate))
    return 0x9100_0000 | UInt32(immediate) << 10 | left << 5 | destination
  }

  private static func encodeSubtractImmediate(
    left: UInt32,
    immediate: Int,
    destination: UInt32
  ) -> UInt32 {
    precondition((0..<4_096).contains(immediate))
    return 0xD100_0000 | UInt32(immediate) << 10 | left << 5 | destination
  }

  private static func encodeMoveWideZero32(register: UInt32, immediate: UInt16) -> UInt32 {
    0x5280_0000 | UInt32(immediate) << 5 | register
  }

  private static func encodeBranchWithLink(register: UInt32) -> UInt32 {
    0xD63F_0000 | register << 5
  }
}
