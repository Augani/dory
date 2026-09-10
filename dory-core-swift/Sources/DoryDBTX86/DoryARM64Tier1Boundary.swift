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
    let requiresMaterializedFlags: Bool

    init(
      target: DoryARM64Tier1ABI.ContextWord,
      arguments: [HelperArgument],
      liveGuestMask: UInt16,
      resultGuestRegister: Int? = nil,
      requiresMaterializedFlags: Bool = false
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
      self.requiresMaterializedFlags = requiresMaterializedFlags
    }
  }

  private static let hostFrameByteCount = 12 * MemoryLayout<UInt64>.stride

  /// Saves the Darwin callee-saved register set outside generated stack memory, installs x28, and
  /// loads every architectural GPR plus RIP, the currently materialized RFLAGS image, and the
  /// pending lazy operation descriptor.
  func emitEntry(into words: inout [UInt32]) {
    words.append(
      Self.encodeSubtractImmediate(
        left: 31, immediate: Self.hostFrameByteCount,
        destination: 31))
    for saved in DoryARM64Tier1ABI.hostCalleeSavedRegisterWords {
      words.append(
        Self.encodeStore64(
          register: saved.register, base: 0, byteOffset: saved.word.byteOffset))
    }
    words.append(Self.encodeMove(destination: 28, source: 0))
    // Preserve the remaining generated-function ABI arguments in the dispatcher-owned
    // callee-saved bank before x1...x15 become pinned guest registers.
    for (destination, source) in zip(19...23, 1...5) {
      words.append(Self.encodeMove(destination: UInt32(destination), source: UInt32(source)))
    }
    for (index, register) in DoryARM64Tier1ABI.guestRegisterMap.enumerated() {
      words.append(
        Self.encodeLoad64(
          register: register, base: 28,
          byteOffset: DoryARM64Tier1ABI.ContextWord(rawValue: index)!.byteOffset))
    }
    words.append(
      Self.encodeLoad64(
        register: DoryARM64Tier1ABI.guestRIPRegister, base: 28,
        byteOffset: DoryARM64Tier1ABI.ContextWord.rip.byteOffset))
    words.append(
      Self.encodeLoad64(
        register: DoryARM64Tier1ABI.lazyFlagsRegisters[0], base: 28,
        byteOffset: DoryARM64Tier1ABI.ContextWord.rflags.byteOffset))
    words.append(
      Self.encodeLoad64(
        register: DoryARM64Tier1ABI.lazyFlagsRegisters[1], base: 28,
        byteOffset: DoryARM64Tier1ABI.ContextWord.lazyFlagsOperation.byteOffset))
  }

  /// Publishes the block-local replay policy before its first memory callback. A raw predecessor
  /// therefore cannot make a multi-access read-only target inherit a weaker entry policy.
  func emitRestartableMemoryReadPolicy(_ required: Bool, into words: inout [UInt32]) {
    words.append(
      Self.encodeMoveWideZero32(
        register: DoryARM64Tier1ABI.scratchRegisters[0],
        immediate: required ? 1 : 0
      ))
    words.append(
      Self.encodeStore64(
        register: DoryARM64Tier1ABI.scratchRegisters[0],
        base: DoryARM64Tier1ABI.contextRegister,
        byteOffset: DoryARM64Tier1ABI.ContextWord.requiresRestartableMemoryReads.byteOffset
      ))
  }

  /// Materializes a pending record through the stable context helper. The zero-descriptor path is
  /// one CBZ. A real call spills every pinned caller-saved guest register because the Darwin C ABI
  /// permits the materializer to clobber x0...x18; its returned RFLAGS image becomes the new x25.
  func emitMaterializeLazyFlags(into words: inout [UInt32]) {
    let materializedBranch = words.count
    words.append(0)
    for (index, register) in DoryARM64Tier1ABI.guestRegisterMap.enumerated() {
      words.append(
        Self.encodeStore64(
          register: register, base: DoryARM64Tier1ABI.contextRegister,
          byteOffset: DoryARM64Tier1ABI.ContextWord(rawValue: index)!.byteOffset))
    }
    words.append(
      Self.encodeStore64(
        register: DoryARM64Tier1ABI.lazyFlagsRegisters[0],
        base: DoryARM64Tier1ABI.contextRegister,
        byteOffset: DoryARM64Tier1ABI.ContextWord.rflags.byteOffset))
    words.append(
      Self.encodeStore64(
        register: DoryARM64Tier1ABI.lazyFlagsRegisters[1],
        base: DoryARM64Tier1ABI.contextRegister,
        byteOffset: DoryARM64Tier1ABI.ContextWord.lazyFlagsOperation.byteOffset))
    words.append(
      Self.encodeLoad64(
        register: DoryARM64Tier1ABI.scratchRegisters[0],
        base: DoryARM64Tier1ABI.contextRegister,
        byteOffset: DoryARM64Tier1ABI.ContextWord.lazyFlagsMaterializer.byteOffset))
    words.append(Self.encodeMove(destination: 0, source: DoryARM64Tier1ABI.contextRegister))
    words.append(Self.encodeBranchWithLink(register: DoryARM64Tier1ABI.scratchRegisters[0]))
    words.append(
      Self.encodeMove(
        destination: DoryARM64Tier1ABI.lazyFlagsRegisters[0], source: 0))
    words.append(
      Self.encodeMove(
        destination: DoryARM64Tier1ABI.lazyFlagsRegisters[1], source: 31))
    for (index, register) in DoryARM64Tier1ABI.guestRegisterMap.enumerated() {
      words.append(
        Self.encodeLoad64(
          register: register, base: DoryARM64Tier1ABI.contextRegister,
          byteOffset: DoryARM64Tier1ABI.ContextWord(rawValue: index)!.byteOffset))
    }
    words[materializedBranch] = Self.encodeCompareAndBranchZero(
      register: DoryARM64Tier1ABI.lazyFlagsRegisters[1],
      wordOffset: words.count - materializedBranch)
  }

  /// Checkpoints the pinned materialized-flags base before an unavoidable C callback. Pending
  /// lazy descriptors already live in the context when they are created, while x26 is also used
  /// as local scratch by some callback emitters, so only the authoritative x25 base is written.
  func emitRecoveryFlagsCheckpoint(into words: inout [UInt32]) {
    words.append(
      Self.encodeStore64(
        register: DoryARM64Tier1ABI.lazyFlagsRegisters[0],
        base: DoryARM64Tier1ABI.contextRegister,
        byteOffset: DoryARM64Tier1ABI.ContextWord.rflags.byteOffset))
  }

  /// Replaces the pinned guest RIP with one statically validated direct target.
  func emitGuestRIP(_ address: UInt64, into words: inout [UInt32]) {
    Self.emitImmediate(address, register: DoryARM64Tier1ABI.guestRIPRegister, into: &words)
  }

  /// Emits one conservative helper boundary. Only the live pinned guest subset is checkpointed
  /// and restored; RIP and materialized flags are always published because a helper may fault,
  /// interrupt, or request interpreter fallback.
  func emitHelperCall(_ call: HelperCall, into words: inout [UInt32]) {
    if call.requiresMaterializedFlags {
      emitMaterializeLazyFlags(into: &words)
    }
    for register in DoryARM64Tier1ABI.helperSpillRegisters(
      liveGuestMask: call.liveGuestMask
    ) {
      words.append(
        Self.encodeStore64(
          register: register, base: DoryARM64Tier1ABI.contextRegister,
          byteOffset: DoryARM64Tier1ABI.ContextWord(rawValue: Int(register))!.byteOffset))
    }
    words.append(
      Self.encodeStore64(
        register: DoryARM64Tier1ABI.guestRIPRegister,
        base: DoryARM64Tier1ABI.contextRegister,
        byteOffset: DoryARM64Tier1ABI.ContextWord.rip.byteOffset))
    words.append(
      Self.encodeStore64(
        register: DoryARM64Tier1ABI.lazyFlagsRegisters[0],
        base: DoryARM64Tier1ABI.contextRegister,
        byteOffset: DoryARM64Tier1ABI.ContextWord.rflags.byteOffset))
    words.append(
      Self.encodeStore64(
        register: DoryARM64Tier1ABI.lazyFlagsRegisters[1],
        base: DoryARM64Tier1ABI.contextRegister,
        byteOffset: DoryARM64Tier1ABI.ContextWord.lazyFlagsOperation.byteOffset))
    words.append(
      Self.encodeLoad64(
        register: DoryARM64Tier1ABI.scratchRegisters[0],
        base: DoryARM64Tier1ABI.contextRegister,
        byteOffset: call.target.byteOffset))

    for (argumentRegister, argument) in call.arguments.enumerated() {
      let destination = UInt32(argumentRegister)
      switch argument {
      case .contextPointer:
        words.append(
          Self.encodeMove(
            destination: destination, source: DoryARM64Tier1ABI.contextRegister))
      case .guestRegister(let index):
        words.append(
          Self.encodeLoad64(
            register: destination, base: DoryARM64Tier1ABI.contextRegister,
            byteOffset: DoryARM64Tier1ABI.ContextWord(rawValue: index)!.byteOffset))
      case .immediate(let value):
        Self.emitImmediate(value, register: destination, into: &words)
      case .contextWordValue(let word):
        words.append(
          Self.encodeLoad64(
            register: destination, base: DoryARM64Tier1ABI.contextRegister,
            byteOffset: word.byteOffset))
      case .contextWordAddress(let word):
        words.append(
          Self.encodeAddImmediate(
            left: DoryARM64Tier1ABI.contextRegister,
            immediate: word.byteOffset,
            destination: destination))
      }
    }
    words.append(Self.encodeBranchWithLink(register: DoryARM64Tier1ABI.scratchRegisters[0]))

    if call.resultGuestRegister != nil {
      words.append(
        Self.encodeMove(
          destination: DoryARM64Tier1ABI.scratchRegisters[1], source: 0))
    }
    for register in DoryARM64Tier1ABI.helperSpillRegisters(
      liveGuestMask: call.liveGuestMask
    ) where Int(register) != call.resultGuestRegister {
      words.append(
        Self.encodeLoad64(
          register: register, base: DoryARM64Tier1ABI.contextRegister,
          byteOffset: DoryARM64Tier1ABI.ContextWord(rawValue: Int(register))!.byteOffset))
    }
    if let resultGuestRegister = call.resultGuestRegister {
      words.append(
        Self.encodeMove(
          destination: UInt32(resultGuestRegister),
          source: DoryARM64Tier1ABI.scratchRegisters[1]))
    }
  }

  /// Publishes pinned architectural state, restores the host ABI, and returns the dispatcher code.
  func emitExit(
    _ exitCode: DoryJITExitCode,
    chainGuestInstructionCount: UInt32 = 0,
    chainGuestStart: UInt64 = 0,
    into words: inout [UInt32]
  ) {
    emitPublishedState(into: &words)
    if chainGuestInstructionCount > 0 {
      emitChainAccounting(
        guestInstructionCount: chainGuestInstructionCount,
        guestStart: chainGuestStart,
        into: &words
      )
    }
    words.append(
      Self.encodeMoveWideZero32(
        register: 0, immediate: UInt16(exitCode.rawValue)))
    emitHostFrameRestore(into: &words)
    words.append(0xD65F_03C0)  // ret
  }

  /// Publishes state and restores the generated-function ABI while keeping x0 as the context
  /// pointer. A following chain slot can tail-branch into any full baseline or tier-1 entry; its
  /// block-local fallback replaces x0 with the dispatcher exit code before returning.
  func emitChainExitPrelude(
    guestInstructionCount: UInt32,
    guestStart: UInt64,
    into words: inout [UInt32]
  ) {
    emitPublishedState(into: &words)
    emitChainAccounting(
      guestInstructionCount: guestInstructionCount,
      guestStart: guestStart,
      into: &words
    )
    words.append(Self.encodeMove(destination: 0, source: DoryARM64Tier1ABI.contextRegister))
    for (destination, source) in zip(1...5, 19...23) {
      words.append(Self.encodeMove(destination: UInt32(destination), source: UInt32(source)))
    }
    emitHostFrameRestore(into: &words)
  }

  /// Appends executable branch slots after `emitChainExitPrelude`. Both conditional directions
  /// get independent words so profiling can patch the taken and not-taken destinations without
  /// rewriting the condition calculation.
  func emitChainSlots(
    for terminator: DoryIRTerminator,
    into words: inout [UInt32]
  ) -> [DoryARM64ChainSlot] {
    switch terminator {
    case .next(let target), .branch(let target):
      guard DoryX86ArchitecturalState.isCanonical(target) else { return [] }
      words.append(
        Self.encodeLoad64(
          register: 9,
          base: 0,
          byteOffset: DoryARM64Tier1ABI.ContextWord.chainEnabled.byteOffset
        ))
      let disabledBranch = words.count
      words.append(0)
      let slot = words.count
      words.append(0)
      let fallback = words.count
      words[disabledBranch] = Self.encodeCompareAndBranchZero(
        register: 9,
        wordOffset: fallback - disabledBranch
      )
      words[slot] = Self.encodeUnconditionalBranch(wordOffset: fallback - slot)
      return [
        .init(
          kind: .direct,
          targetGuestRIP: target,
          machineWordIndex: slot,
          fallbackWordIndex: fallback
        )
      ]
    case .conditional(_, let taken, let notTaken):
      guard DoryX86ArchitecturalState.isCanonical(taken),
        DoryX86ArchitecturalState.isCanonical(notTaken)
      else { return [] }
      words.append(
        Self.encodeLoad64(
          register: 9,
          base: 0,
          byteOffset: DoryARM64Tier1ABI.ContextWord.chainEnabled.byteOffset
        ))
      let disabledBranch = words.count
      words.append(0)
      words.append(
        Self.encodeLoad64(
          register: 9,
          base: 0,
          byteOffset: DoryARM64Tier1ABI.ContextWord.rip.byteOffset
        ))
      Self.emitImmediate(taken, register: 10, into: &words)
      words.append(Self.encodeCompare64(left: 9, right: 10))
      let selectTaken = words.count
      words.append(0)
      let notTakenSlot = words.count
      words.append(0)
      let takenSlot = words.count
      words.append(0)
      let fallback = words.count
      words[disabledBranch] = Self.encodeCompareAndBranchZero(
        register: 9,
        wordOffset: fallback - disabledBranch
      )
      words[selectTaken] = Self.encodeConditionalBranchEqual(
        wordOffset: takenSlot - selectTaken)
      words[notTakenSlot] = Self.encodeUnconditionalBranch(
        wordOffset: fallback - notTakenSlot)
      words[takenSlot] = Self.encodeUnconditionalBranch(wordOffset: fallback - takenSlot)
      return [
        .init(
          kind: .conditionalTaken,
          targetGuestRIP: taken,
          machineWordIndex: takenSlot,
          fallbackWordIndex: fallback
        ),
        .init(
          kind: .conditionalNotTaken,
          targetGuestRIP: notTaken,
          machineWordIndex: notTakenSlot,
          fallbackWordIndex: fallback
        ),
      ]
    default:
      return []
    }
  }

  func supportsChainSlots(for terminator: DoryIRTerminator) -> Bool {
    switch terminator {
    case .next(let target), .branch(let target):
      return DoryX86ArchitecturalState.isCanonical(target)
    case .conditional(_, let taken, let notTaken):
      return DoryX86ArchitecturalState.isCanonical(taken)
        && DoryX86ArchitecturalState.isCanonical(notTaken)
    default:
      return false
    }
  }

  func installChainBudgetGuard(
    guestInstructionCount: UInt32,
    in words: inout [UInt32]
  ) {
    precondition(guestInstructionCount > 0)
    var guardWords = [
      Self.encodeLoad8(
        register: 9,
        base: 0,
        byteOffset: DoryARM64Tier1ABI.ContextWord.pendingWork.byteOffset
      ),
      UInt32(0),
      Self.encodeLoad64(
        register: 9,
        base: 0,
        byteOffset: DoryARM64Tier1ABI.ContextWord.chainEnabled.byteOffset
      ),
      UInt32(0),
      Self.encodeLoad64(
        register: 9,
        base: 0,
        byteOffset: DoryARM64Tier1ABI.ContextWord.chainRemainingInstructions.byteOffset
      ),
    ]
    Self.emitImmediate(UInt64(guestInstructionCount), register: 10, into: &guardWords)
    guardWords.append(Self.encodeCompare64(left: 9, right: 10))
    let enoughBudgetBranch = guardWords.count
    guardWords.append(0)
    guardWords.append(
      Self.encodeMoveWideZero32(
        register: 0,
        immediate: UInt16(DoryJITExitCode.dispatch.rawValue)
      ))
    guardWords.append(0xD65F_03C0)
    let pendingWorkExit = guardWords.count
    guardWords.append(
      Self.encodeMoveWideZero32(
        register: 0,
        immediate: UInt16(DoryJITExitCode.pendingWork.rawValue)
      ))
    guardWords.append(0xD65F_03C0)
    let bodyStart = guardWords.count
    guardWords[1] = Self.encodeCompareAndBranchNonZero32(
      register: 9,
      wordOffset: pendingWorkExit - 1
    )
    guardWords[3] = Self.encodeCompareAndBranchZero(
      register: 9,
      wordOffset: bodyStart - 3
    )
    guardWords[enoughBudgetBranch] = Self.encodeConditionalBranchCarrySet(
      wordOffset: bodyStart - enoughBudgetBranch)
    words.insert(contentsOf: guardWords, at: 0)
  }

  func emitChainExitFallback(
    _ exitCode: DoryJITExitCode,
    into words: inout [UInt32]
  ) {
    words.append(
      Self.encodeMoveWideZero32(
        register: 0, immediate: UInt16(exitCode.rawValue)))
    words.append(0xD65F_03C0)
  }

  private func emitPublishedState(into words: inout [UInt32]) {
    for (index, register) in DoryARM64Tier1ABI.guestRegisterMap.enumerated() {
      words.append(
        Self.encodeStore64(
          register: register, base: DoryARM64Tier1ABI.contextRegister,
          byteOffset: DoryARM64Tier1ABI.ContextWord(rawValue: index)!.byteOffset))
    }
    words.append(
      Self.encodeStore64(
        register: DoryARM64Tier1ABI.guestRIPRegister,
        base: DoryARM64Tier1ABI.contextRegister,
        byteOffset: DoryARM64Tier1ABI.ContextWord.rip.byteOffset))
    words.append(
      Self.encodeStore64(
        register: DoryARM64Tier1ABI.lazyFlagsRegisters[0],
        base: DoryARM64Tier1ABI.contextRegister,
        byteOffset: DoryARM64Tier1ABI.ContextWord.rflags.byteOffset))
    words.append(
      Self.encodeStore64(
        register: DoryARM64Tier1ABI.lazyFlagsRegisters[1],
        base: DoryARM64Tier1ABI.contextRegister,
        byteOffset: DoryARM64Tier1ABI.ContextWord.lazyFlagsOperation.byteOffset))
  }

  private func emitChainAccounting(
    guestInstructionCount: UInt32,
    guestStart: UInt64,
    into words: inout [UInt32]
  ) {
    let context = DoryARM64Tier1ABI.contextRegister
    words.append(
      Self.encodeLoad64(
        register: 9,
        base: context,
        byteOffset: DoryARM64Tier1ABI.ContextWord.chainEnabled.byteOffset
      ))
    let disabledBranch = words.count
    words.append(0)
    Self.emitImmediate(UInt64(guestInstructionCount), register: 10, into: &words)
    words.append(
      Self.encodeLoad64(
        register: 11,
        base: context,
        byteOffset: DoryARM64Tier1ABI.ContextWord.chainRemainingInstructions.byteOffset
      ))
    words.append(Self.encodeSubtract64(left: 11, right: 10, destination: 11))
    words.append(
      Self.encodeStore64(
        register: 11,
        base: context,
        byteOffset: DoryARM64Tier1ABI.ContextWord.chainRemainingInstructions.byteOffset
      ))
    words.append(
      Self.encodeLoad64(
        register: 11,
        base: context,
        byteOffset: DoryARM64Tier1ABI.ContextWord.chainRetiredInstructions.byteOffset
      ))
    words.append(Self.encodeAdd64(left: 11, right: 10, destination: 11))
    words.append(
      Self.encodeStore64(
        register: 11,
        base: context,
        byteOffset: DoryARM64Tier1ABI.ContextWord.chainRetiredInstructions.byteOffset
      ))
    words.append(
      Self.encodeLoad64(
        register: 11,
        base: context,
        byteOffset: DoryARM64Tier1ABI.ContextWord.chainRetiredBlocks.byteOffset
      ))
    words.append(Self.encodeAddImmediate(left: 11, immediate: 1, destination: 11))
    words.append(
      Self.encodeStore64(
        register: 11,
        base: context,
        byteOffset: DoryARM64Tier1ABI.ContextWord.chainRetiredBlocks.byteOffset
      ))
    Self.emitImmediate(guestStart, register: 10, into: &words)
    words.append(
      Self.encodeStore64(
        register: 10,
        base: context,
        byteOffset: DoryARM64Tier1ABI.ContextWord.chainLastGuestRIP.byteOffset
      ))
    let done = words.count
    words[disabledBranch] = Self.encodeCompareAndBranchZero(
      register: 9,
      wordOffset: done - disabledBranch
    )
  }

  private func emitHostFrameRestore(into words: inout [UInt32]) {
    for saved in DoryARM64Tier1ABI.hostCalleeSavedRegisterWords where saved.register != 28 {
      words.append(
        Self.encodeLoad64(
          register: saved.register, base: DoryARM64Tier1ABI.contextRegister,
          byteOffset: saved.word.byteOffset))
    }
    words.append(
      Self.encodeLoad64(
        register: DoryARM64Tier1ABI.contextRegister,
        base: DoryARM64Tier1ABI.contextRegister,
        byteOffset: DoryARM64Tier1ABI.ContextWord.hostRegister28.byteOffset))
    words.append(
      Self.encodeAddImmediate(
        left: 31, immediate: Self.hostFrameByteCount, destination: 31))
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

  private static func encodeLoad8(register: UInt32, base: UInt32, byteOffset: Int) -> UInt32 {
    precondition((0..<4_096).contains(byteOffset))
    return 0x3940_0000 | UInt32(byteOffset) << 10 | base << 5 | register
  }

  private static func encodeStore64(register: UInt32, base: UInt32, byteOffset: Int) -> UInt32 {
    precondition(byteOffset >= 0 && byteOffset.isMultiple(of: 8) && byteOffset / 8 < 4_096)
    return 0xF900_0000 | UInt32(byteOffset / 8) << 10 | base << 5 | register
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

  private static func encodeAdd64(left: UInt32, right: UInt32, destination: UInt32) -> UInt32 {
    0x8B00_0000 | right << 16 | left << 5 | destination
  }

  private static func encodeSubtract64(
    left: UInt32,
    right: UInt32,
    destination: UInt32
  ) -> UInt32 {
    0xCB00_0000 | right << 16 | left << 5 | destination
  }

  private static func encodeMoveWideZero32(register: UInt32, immediate: UInt16) -> UInt32 {
    0x5280_0000 | UInt32(immediate) << 5 | register
  }

  private static func encodeBranchWithLink(register: UInt32) -> UInt32 {
    0xD63F_0000 | register << 5
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

  private static func encodeCompareAndBranchNonZero32(
    register: UInt32,
    wordOffset: Int
  ) -> UInt32 {
    precondition((-262_144..<262_144).contains(wordOffset))
    return 0x3500_0000
      | (UInt32(truncatingIfNeeded: wordOffset) & 0x7_FFFF) << 5
      | register
  }

  private static func encodeCompare64(left: UInt32, right: UInt32) -> UInt32 {
    0xEB00_001F | right << 16 | left << 5
  }

  private static func encodeConditionalBranchEqual(wordOffset: Int) -> UInt32 {
    precondition((-262_144..<262_144).contains(wordOffset))
    return 0x5400_0000 | (UInt32(truncatingIfNeeded: wordOffset) & 0x7_FFFF) << 5
  }

  private static func encodeConditionalBranchCarrySet(wordOffset: Int) -> UInt32 {
    precondition((-262_144..<262_144).contains(wordOffset))
    return 0x5400_0002 | (UInt32(truncatingIfNeeded: wordOffset) & 0x7_FFFF) << 5
  }

  private static func encodeUnconditionalBranch(wordOffset: Int) -> UInt32 {
    precondition((-33_554_432..<33_554_432).contains(wordOffset))
    return 0x1400_0000 | (UInt32(truncatingIfNeeded: wordOffset) & 0x03FF_FFFF)
  }
}
