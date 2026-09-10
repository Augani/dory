import DoryJITRuntimeC
import Foundation

public enum DoryJITExitCode: UInt32, Codable, Sendable, Hashable {
  case dispatch = 0
  case interpreter = 1
  case halt = 2
  case system = 3
  case portIO = 4
  case pendingWork = 5
}

public enum DoryARM64CompilationTier: String, Codable, Sendable, Hashable {
  case baseline
  case tier1
  case optimizing
  case interpreterFallback
}

public enum DoryARM64JITOptimization: String, Codable, Sendable, Hashable {
  case baseline
  case optimizing
}

public enum DoryARM64ChainSlotKind: String, Codable, Sendable, Hashable {
  case direct
  case conditionalTaken
  case conditionalNotTaken
}

/// One executable branch word that initially targets its block-local dispatcher fallback. The
/// runtime may retarget it to another resident block and can always restore `fallbackWordIndex`
/// when that target loses lookup visibility.
public struct DoryARM64ChainSlot: Codable, Sendable, Hashable {
  public let kind: DoryARM64ChainSlotKind
  public let targetGuestRIP: UInt64
  public let machineWordIndex: Int
  public let fallbackWordIndex: Int

  public init(
    kind: DoryARM64ChainSlotKind,
    targetGuestRIP: UInt64,
    machineWordIndex: Int,
    fallbackWordIndex: Int
  ) {
    self.kind = kind
    self.targetGuestRIP = targetGuestRIP
    self.machineWordIndex = machineWordIndex
    self.fallbackWordIndex = fallbackWordIndex
  }
}

public enum DoryARM64InstructionFlagsState: String, Codable, Sendable, Hashable {
  /// Architectural flags are recoverable from the context's materialized or lazy record.
  case context
  /// Tier 1 also has a valid native NZCV image for the immediately preceding producer.
  case nativeNZCV
}

/// Recovery metadata for one guest instruction. `hostOffsetStart` is byte-relative to the
/// beginning of the executable block and is intentionally kept outside generated code.
public struct DoryARM64InstructionMetadata: Codable, Sendable, Hashable {
  public let hostOffsetStart: UInt32
  public let guestRIP: UInt64
  public let guestByteCount: UInt8
  public let flagsState: DoryARM64InstructionFlagsState
  public let liveInRegisterMask: UInt16
  public let dirtyRegisterMask: UInt16

  public init(
    hostOffsetStart: UInt32,
    guestRIP: UInt64,
    guestByteCount: UInt8,
    flagsState: DoryARM64InstructionFlagsState,
    liveInRegisterMask: UInt16,
    dirtyRegisterMask: UInt16
  ) {
    self.hostOffsetStart = hostOffsetStart
    self.guestRIP = guestRIP
    self.guestByteCount = guestByteCount
    self.flagsState = flagsState
    self.liveInRegisterMask = liveInRegisterMask
    self.dirtyRegisterMask = dirtyRegisterMask
  }
}

public struct DoryARM64CompiledBlock: Codable, Sendable, Hashable {
  private static let directChainMetadataMagic: UInt32 = 0xD05C_A051
  private static let conditionalChainMetadataMagic: UInt32 = 0xD05C_A052
  private static let indirectChainMetadataMagic: UInt32 = 0xD05C_A053

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
  public let instructionMetadata: [DoryARM64InstructionMetadata]

  private enum CodingKeys: String, CodingKey {
    case guestStart
    case guestByteCount
    case guestInstructionCount
    case machineWords
    case tier
    case exitCode
    case requiresMemoryCallbacks
    case requiresRestartableMemoryReads
    case mayExitToInterpreter
    case instructionMetadata
  }

  public init(
    guestStart: UInt64,
    guestByteCount: UInt32,
    guestInstructionCount: UInt32,
    machineWords: [UInt32],
    tier: DoryARM64CompilationTier,
    exitCode: DoryJITExitCode,
    requiresMemoryCallbacks: Bool = false,
    requiresRestartableMemoryReads: Bool = false,
    mayExitToInterpreter: Bool = false,
    instructionMetadata: [DoryARM64InstructionMetadata] = []
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
    self.instructionMetadata = instructionMetadata
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guestStart = try container.decode(UInt64.self, forKey: .guestStart)
    guestByteCount = try container.decode(UInt32.self, forKey: .guestByteCount)
    guestInstructionCount = try container.decode(UInt32.self, forKey: .guestInstructionCount)
    machineWords = try container.decode([UInt32].self, forKey: .machineWords)
    tier = try container.decode(DoryARM64CompilationTier.self, forKey: .tier)
    exitCode = try container.decode(DoryJITExitCode.self, forKey: .exitCode)
    requiresMemoryCallbacks =
      try container.decodeIfPresent(Bool.self, forKey: .requiresMemoryCallbacks) ?? false
    requiresRestartableMemoryReads =
      try container.decodeIfPresent(Bool.self, forKey: .requiresRestartableMemoryReads) ?? false
    mayExitToInterpreter =
      try container.decodeIfPresent(Bool.self, forKey: .mayExitToInterpreter) ?? false
    instructionMetadata =
      try container.decodeIfPresent(
        [DoryARM64InstructionMetadata].self,
        forKey: .instructionMetadata
      ) ?? []
  }

  public var machineBytes: [UInt8] {
    machineWords.flatMap { word in
      (0..<4).map { UInt8(truncatingIfNeeded: word >> UInt32($0 * 8)) }
    }
  }

  /// Returns the last instruction boundary at or before a host byte offset. Duplicate offsets
  /// are expected when a zero-code instruction precedes emitted work; the later guest boundary
  /// owns that host instruction.
  public func instructionMetadata(atHostOffset hostOffset: UInt32)
    -> DoryARM64InstructionMetadata?
  {
    var lowerBound = 0
    var upperBound = instructionMetadata.count
    while lowerBound < upperBound {
      let midpoint = lowerBound + (upperBound - lowerBound) / 2
      if instructionMetadata[midpoint].hostOffsetStart <= hostOffset {
        lowerBound = midpoint + 1
      } else {
        upperBound = midpoint
      }
    }
    return lowerBound == 0 ? nil : instructionMetadata[lowerBound - 1]
  }

  static func makeInstructionMetadata(
    for block: DoryIRBasicBlock,
    statementWordOffsets: [Int],
    statementFlagsStates: [DoryARM64InstructionFlagsState],
    leadingWordCount: Int,
    liveInRegisterMasks: [UInt16],
    dirtyRegisterMasks: [UInt16]
  ) -> [DoryARM64InstructionMetadata] {
    guard statementWordOffsets.count == block.statements.count + 1,
      statementFlagsStates.count == statementWordOffsets.count,
      liveInRegisterMasks.count == block.instructionBoundaries.count,
      dirtyRegisterMasks.count == block.instructionBoundaries.count
    else { return [] }
    return block.instructionBoundaries.enumerated().compactMap { boundaryIndex, boundary in
      let statementIndex = Int(boundary.statementStartIndex)
      guard statementIndex <= block.statements.count else { return nil }
      let wordOffset = leadingWordCount + statementWordOffsets[statementIndex]
      guard wordOffset <= Int(UInt32.max) / MemoryLayout<UInt32>.stride else { return nil }
      return .init(
        hostOffsetStart: UInt32(wordOffset * MemoryLayout<UInt32>.stride),
        guestRIP: boundary.guestRIP,
        guestByteCount: boundary.guestByteCount,
        flagsState: statementFlagsStates[statementIndex],
        liveInRegisterMask: liveInRegisterMasks[boundaryIndex],
        dirtyRegisterMask: dirtyRegisterMasks[boundaryIndex]
      )
    }
  }

  /// Patch descriptors live in a branch-skipped prefix inside the existing machine-word storage.
  /// This preserves both the compiled block's established value ABI and its terminal `RET` while
  /// allowing cache residents to recover exact slot offsets.
  public var chainSlots: [DoryARM64ChainSlot]? {
    guard machineWords.count >= 2 else { return nil }
    let magic = machineWords[1]
    switch magic {
    case Self.directChainMetadataMagic:
      guard machineWords.count >= 7, machineWords[0] == 0x1400_0004 else { return nil }
      let target = UInt64(machineWords[2]) | UInt64(machineWords[3]) << 32
      let codeEnd = machineWords.count
      return [
        .init(
          kind: .direct,
          targetGuestRIP: target,
          machineWordIndex: codeEnd - 3,
          fallbackWordIndex: codeEnd - 2
        )
      ]
    case Self.conditionalChainMetadataMagic:
      guard machineWords.count >= 11, machineWords[0] == 0x1400_0006 else { return nil }
      let taken = UInt64(machineWords[2]) | UInt64(machineWords[3]) << 32
      let notTaken = UInt64(machineWords[4]) | UInt64(machineWords[5]) << 32
      let codeEnd = machineWords.count
      return [
        .init(
          kind: .conditionalTaken,
          targetGuestRIP: taken,
          machineWordIndex: codeEnd - 3,
          fallbackWordIndex: codeEnd - 2
        ),
        .init(
          kind: .conditionalNotTaken,
          targetGuestRIP: notTaken,
          machineWordIndex: codeEnd - 4,
          fallbackWordIndex: codeEnd - 2
        ),
      ]
    case Self.indirectChainMetadataMagic:
      guard machineWords[0] == 0x1400_0002 else { return nil }
      return []
    default:
      return nil
    }
  }

  static func installChainMetadata(
    _ slots: [DoryARM64ChainSlot],
    in words: inout [UInt32]
  ) {
    switch slots.map(\.kind) {
    case [.direct]:
      let target = slots[0].targetGuestRIP
      words.insert(
        contentsOf: [
          0x1400_0004,  // b +4 words, over the descriptor
          directChainMetadataMagic,
          UInt32(truncatingIfNeeded: target),
          UInt32(truncatingIfNeeded: target >> 32),
        ],
        at: 0
      )
    case [.conditionalTaken, .conditionalNotTaken]:
      let taken = slots[0].targetGuestRIP
      let notTaken = slots[1].targetGuestRIP
      words.insert(
        contentsOf: [
          0x1400_0006,  // b +6 words, over the descriptor
          conditionalChainMetadataMagic,
          UInt32(truncatingIfNeeded: taken),
          UInt32(truncatingIfNeeded: taken >> 32),
          UInt32(truncatingIfNeeded: notTaken),
          UInt32(truncatingIfNeeded: notTaken >> 32),
        ],
        at: 0
      )
    default:
      precondition(slots.isEmpty, "unsupported chain-slot metadata shape")
    }
  }

  static func installIndirectChainMetadata(in words: inout [UInt32]) {
    words.insert(contentsOf: [0x1400_0002, indirectChainMetadataMagic], at: 0)
  }
}

/// Baseline ABI: x0 points to 16 UInt64 GPR slots, RIP/RFLAGS, FS/GS bases, TSC,
/// then the six visible segment selectors. Generated code returns a DoryJITExitCode in w0.
/// The layout is intentionally independent of Swift struct ABI.
public struct DoryARM64BaselineEmitter: Sendable {
  private static let ripOffset = DoryARM64Tier1ABI.ContextWord.rip.byteOffset
  private static let rflagsOffset = DoryARM64Tier1ABI.ContextWord.rflags.byteOffset
  private static let fsBaseOffset = DoryARM64Tier1ABI.ContextWord.fsBase.byteOffset
  private static let gsBaseOffset = DoryARM64Tier1ABI.ContextWord.gsBase.byteOffset
  private static let tscOffset = DoryARM64Tier1ABI.ContextWord.tsc.byteOffset
  private static let csSelectorOffset = DoryARM64Tier1ABI.ContextWord.csSelector.byteOffset
  private static let dsSelectorOffset = DoryARM64Tier1ABI.ContextWord.dsSelector.byteOffset
  private static let esSelectorOffset = DoryARM64Tier1ABI.ContextWord.esSelector.byteOffset
  private static let fsSelectorOffset = DoryARM64Tier1ABI.ContextWord.fsSelector.byteOffset
  private static let gsSelectorOffset = DoryARM64Tier1ABI.ContextWord.gsSelector.byteOffset
  private static let ssSelectorOffset = DoryARM64Tier1ABI.ContextWord.ssSelector.byteOffset
  private static let readTLBBaseOffset = DoryARM64Tier1ABI.ContextWord.readTLBBase.byteOffset
  private static let writeTLBBaseOffset = DoryARM64Tier1ABI.ContextWord.writeTLBBase.byteOffset
  private static let tlbEntryMaskOffset = DoryARM64Tier1ABI.ContextWord.tlbEntryMask.byteOffset
  private static let tlbAddressSpaceGenerationOffset =
    DoryARM64Tier1ABI.ContextWord.tlbAddressSpaceGeneration.byteOffset
  private static let tlbResolverOffset = DoryARM64Tier1ABI.ContextWord.tlbResolver.byteOffset
  private static let readTLBHitCounterOffset =
    DoryARM64Tier1ABI.ContextWord.readTLBHitCounter.byteOffset
  private static let writeTLBHitCounterOffset =
    DoryARM64Tier1ABI.ContextWord.writeTLBHitCounter.byteOffset
  private static let atomicCompareExchangeOffset =
    DoryARM64Tier1ABI.ContextWord.atomicCompareExchange.byteOffset
  private static let atomicExchangeOffset = DoryARM64Tier1ABI.ContextWord.atomicExchange.byteOffset
  private static let atomicFetchAddOffset = DoryARM64Tier1ABI.ContextWord.atomicFetchAdd.byteOffset
  private static let atomicRMWOffset = DoryARM64Tier1ABI.ContextWord.atomicRMW.byteOffset
  private static let atomicCompareExchangePairOffset =
    DoryARM64Tier1ABI.ContextWord.atomicCompareExchangePair.byteOffset
  private static let rspOffset = DoryARM64Tier1ABI.ContextWord.rsp.byteOffset
  private static let cr3Offset = DoryARM64Tier1ABI.ContextWord.cr3.byteOffset
  private static let kernelGSBaseOffset = DoryARM64Tier1ABI.ContextWord.kernelGSBase.byteOffset
  private static let swapGSPerformedOffset =
    DoryARM64Tier1ABI.ContextWord.swapGSPerformed.byteOffset
  private static let chainEnabledOffset = DoryARM64Tier1ABI.ContextWord.chainEnabled.byteOffset
  private static let chainRemainingInstructionsOffset =
    DoryARM64Tier1ABI.ContextWord.chainRemainingInstructions.byteOffset
  private static let chainRetiredInstructionsOffset =
    DoryARM64Tier1ABI.ContextWord.chainRetiredInstructions.byteOffset
  private static let chainRetiredBlocksOffset =
    DoryARM64Tier1ABI.ContextWord.chainRetiredBlocks.byteOffset
  private static let chainLastGuestRIPOffset =
    DoryARM64Tier1ABI.ContextWord.chainLastGuestRIP.byteOffset
  private static let ibtcEntriesBaseOffset = DoryARM64Tier1ABI.ContextWord.ibtcEntriesBase.byteOffset
  private static let ibtcEntryMaskOffset = DoryARM64Tier1ABI.ContextWord.ibtcEntryMask.byteOffset
  private static let ibtcGenerationOffset = DoryARM64Tier1ABI.ContextWord.ibtcGeneration.byteOffset
  private static let ibtcInlineHitsOffset = DoryARM64Tier1ABI.ContextWord.ibtcInlineHits.byteOffset
  private static let ibtcInlineMissesOffset =
    DoryARM64Tier1ABI.ContextWord.ibtcInlineMisses.byteOffset
  private static let shadowReturnEntriesBaseOffset =
    DoryARM64Tier1ABI.ContextWord.shadowReturnEntriesBase.byteOffset
  private static let shadowReturnEntryMaskOffset =
    DoryARM64Tier1ABI.ContextWord.shadowReturnEntryMask.byteOffset
  private static let shadowReturnTopAddressOffset =
    DoryARM64Tier1ABI.ContextWord.shadowReturnTopAddress.byteOffset
  private static let shadowReturnGenerationOffset =
    DoryARM64Tier1ABI.ContextWord.shadowReturnGeneration.byteOffset
  private static let shadowReturnHitsOffset =
    DoryARM64Tier1ABI.ContextWord.shadowReturnHits.byteOffset
  private static let shadowReturnMissesOffset =
    DoryARM64Tier1ABI.ContextWord.shadowReturnMisses.byteOffset
  private static let shadowReturnPushesOffset =
    DoryARM64Tier1ABI.ContextWord.shadowReturnPushes.byteOffset
  private static let pendingWorkOffset = DoryARM64Tier1ABI.ContextWord.pendingWork.byteOffset
  private static let hostFramePointerOffset =
    DoryARM64Tier1ABI.ContextWord.hostFramePointer.byteOffset
  private static let hostReturnAddressOffset =
    DoryARM64Tier1ABI.ContextWord.hostReturnAddress.byteOffset
  private static let inlineTLBFaultHostPCOffset =
    DoryARM64Tier1ABI.ContextWord.inlineTLBFaultHostPC.byteOffset
  private static let memoryFaultCheckpointActiveOffset =
    DoryARM64Tier1ABI.ContextWord.memoryFaultCheckpointActive.byteOffset
  private static let memoryFaultCheckpointRegisterMaskOffset =
    DoryARM64Tier1ABI.ContextWord.memoryFaultCheckpointRegisterMask.byteOffset
  private static let memoryFaultCheckpointRFlagsOffset =
    DoryARM64Tier1ABI.ContextWord.memoryFaultCheckpointRFlags.byteOffset
  private static let memoryFaultCheckpointRAXOffset =
    DoryARM64Tier1ABI.ContextWord.memoryFaultCheckpointRAX.byteOffset
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
    // Fences cannot be rolled back, and division guards return without unwinding a
    // memory-callback prologue. Require the translator's isolated shape even for
    // caller-supplied IR so neither can follow a memory access or architectural write.
    if block.statements.contains(where: {
      switch $0 {
      case .memoryFence, .unsignedAccumulatorDivide, .signedAccumulatorDivide: true
      default: false
      }
    }) {
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
      switch $0 {
      case .stackPush, .stackPushFlags, .stackPop: true
      default: false
      }
    }
    let guardsInterpreterExit = block.statements.contains {
      if case .unsignedAccumulatorDivide = $0 { return true }
      if case .signedAccumulatorDivide = $0 { return true }
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
    let registerMasks = DoryARM64Tier1Emitter.instructionRegisterMasks(for: block)
    var writeCheckpointMasksByStatement: [Int: UInt16] = [:]
    for (boundaryIndex, boundary) in block.instructionBoundaries.enumerated() {
      let start = Int(boundary.statementStartIndex)
      let end = start + Int(boundary.statementCount)
      guard start < end, end <= block.statements.count,
        block.statements[start..<end].contains(where: writesMemory)
      else { continue }
      writeCheckpointMasksByStatement[start] = registerMasks.writes[boundaryIndex]
    }
    var statementWordOffsets: [Int] = []
    statementWordOffsets.reserveCapacity(block.statements.count + 1)
    for (statementIndex, statement) in block.statements.enumerated() {
      statementWordOffsets.append(words.count)
      if let registerMask = writeCheckpointMasksByStatement[statementIndex] {
        emitMemoryFaultCheckpoint(registerMask: registerMask, into: &words)
      }
      guard emit(statement, into: &words) else {
        return fallback(block)
      }
    }
    statementWordOffsets.append(words.count)
    if terminatorWritesMemory(block.terminator) {
      emitMemoryFaultCheckpoint(registerMask: UInt16(1) << 4, into: &words)
    }
    guard let exit = emit(block.terminator, usesMemory: usesMemory, into: &words) else {
      return fallback(block)
    }
    if !writeCheckpointMasksByStatement.isEmpty || terminatorWritesMemory(block.terminator) {
      // A successful final write must not leave its checkpoint active across a native chain.
      words.append(encodeMoveWideZero32(register: 16, immediate: 0))
      words.append(
        encodeStore64(register: 16, base: 19, byteOffset: Self.memoryFaultCheckpointActiveOffset))
    }
    let hasChainSlots = exit == .dispatch && supportsChainSlots(for: block.terminator)
    let hasIndirectChain =
      exit == .dispatch && supportsIndirectBranchTargetCache(for: block.terminator)
    let hasGeneratedChain = hasChainSlots || hasIndirectChain
    if hasGeneratedChain {
      emitChainAccounting(
        contextRegister: usesMemory ? 19 : 0,
        guestInstructionCount: block.guestInstructionCount,
        guestStart: block.guestStart,
        into: &words
      )
    }
    if usesMemory {
      if hasGeneratedChain {
        emitMemoryChainEpilogue(into: &words)
      } else {
        emitMemoryEpilogue(into: &words)
      }
    }
    let chainSlots = hasChainSlots
      ? emitChainSlots(for: block.terminator, into: &words)
      : []
    if case .returnFromCall(let popBytes) = block.terminator, hasIndirectChain {
      emitShadowReturnStackLookup(popBytes: popBytes, into: &words)
    }
    if hasIndirectChain { emitIndirectBranchTargetCacheLookup(into: &words) }
    words.append(encodeMoveWideZero32(register: 0, immediate: UInt16(exit.rawValue)))
    words.append(0xD65F_03C0)
    let wordCountBeforeChainBudgetGuard = words.count
    if hasGeneratedChain {
      installChainBudgetGuard(
        guestInstructionCount: block.guestInstructionCount,
        in: &words
      )
    }
    let chainBudgetGuardWordCount = words.count - wordCountBeforeChainBudgetGuard
    let wordCountBeforeChainMetadata = words.count
    if hasIndirectChain {
      DoryARM64CompiledBlock.installIndirectChainMetadata(in: &words)
    } else {
      DoryARM64CompiledBlock.installChainMetadata(chainSlots, in: &words)
    }
    let leadingWordCount =
      chainBudgetGuardWordCount + words.count - wordCountBeforeChainMetadata
    let instructionMetadata = DoryARM64CompiledBlock.makeInstructionMetadata(
      for: block,
      statementWordOffsets: statementWordOffsets,
      statementFlagsStates: Array(repeating: .context, count: statementWordOffsets.count),
      leadingWordCount: leadingWordCount,
      liveInRegisterMasks: Array(repeating: 0, count: block.instructionBoundaries.count),
      dirtyRegisterMasks: Array(repeating: 0, count: block.instructionBoundaries.count)
    )
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
      mayExitToInterpreter: guardsTerminator || guardsStack || guardsInterpreterExit,
      instructionMetadata: instructionMetadata
    )
  }

  private func emitMemoryFaultCheckpoint(registerMask: UInt16, into words: inout [UInt32]) {
    for registerIndex in 0..<16 where registerMask & (UInt16(1) << registerIndex) != 0 {
      words.append(encodeLoad64(register: 16, base: 19, byteOffset: registerIndex * 8))
      words.append(
        encodeStore64(
          register: 16,
          base: 19,
          byteOffset: Self.memoryFaultCheckpointRAXOffset + registerIndex * 8
        ))
    }
    words.append(encodeLoad64(register: 16, base: 19, byteOffset: Self.rflagsOffset))
    words.append(
      encodeStore64(register: 16, base: 19, byteOffset: Self.memoryFaultCheckpointRFlagsOffset))
    emitImmediate(UInt64(registerMask), register: 16, into: &words)
    words.append(
      encodeStore64(
        register: 16,
        base: 19,
        byteOffset: Self.memoryFaultCheckpointRegisterMaskOffset
      ))
    words.append(encodeMoveWideZero32(register: 16, immediate: 1))
    words.append(
      encodeStore64(register: 16, base: 19, byteOffset: Self.memoryFaultCheckpointActiveOffset))
  }

  private func terminatorWritesMemory(_ terminator: DoryIRTerminator) -> Bool {
    switch terminator {
    case .call, .indirectCall: true
    default: false
    }
  }

  private func emitChainSlots(
    for terminator: DoryIRTerminator,
    into words: inout [UInt32]
  ) -> [DoryARM64ChainSlot] {
    switch terminator {
    case .next(let target), .branch(let target), .call(let target, _):
      guard DoryX86ArchitecturalState.isCanonical(target) else { return [] }
      words.append(encodeLoad64(register: 9, base: 0, byteOffset: Self.chainEnabledOffset))
      let disabledBranch = words.count
      words.append(0)
      let slot = words.count
      words.append(0)
      let fallback = words.count
      words[disabledBranch] = encodeCompareBranchZero64(
        register: 9,
        wordOffset: fallback - disabledBranch
      )
      words[slot] = encodeUnconditionalBranch(wordOffset: fallback - slot)
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
      words.append(encodeLoad64(register: 9, base: 0, byteOffset: Self.chainEnabledOffset))
      let disabledBranch = words.count
      words.append(0)
      words.append(encodeLoad64(register: 9, base: 0, byteOffset: Self.ripOffset))
      emitImmediate(taken, register: 10, into: &words)
      words.append(encodeAddSubtractSetFlags(add: false, is64Bit: true, 9, 10, 31))
      let selectTaken = words.count
      words.append(0)
      let notTakenSlot = words.count
      words.append(0)
      let takenSlot = words.count
      words.append(0)
      let fallback = words.count
      words[disabledBranch] = encodeCompareBranchZero64(
        register: 9,
        wordOffset: fallback - disabledBranch
      )
      words[selectTaken] = encodeConditionalBranch(
        condition: .equal,
        wordOffset: takenSlot - selectTaken
      )
      words[notTakenSlot] = encodeUnconditionalBranch(wordOffset: fallback - notTakenSlot)
      words[takenSlot] = encodeUnconditionalBranch(wordOffset: fallback - takenSlot)
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

  private func installChainBudgetGuard(
    guestInstructionCount: UInt32,
    in words: inout [UInt32]
  ) {
    precondition(guestInstructionCount > 0)
    var guardWords = [
      encodeLoad8(register: 9, base: 0, byteOffset: Self.pendingWorkOffset),
      UInt32(0),
      encodeLoad64(register: 9, base: 0, byteOffset: Self.chainEnabledOffset),
      UInt32(0),
      encodeLoad64(
        register: 9,
        base: 0,
        byteOffset: Self.chainRemainingInstructionsOffset
      ),
    ]
    emitImmediate(UInt64(guestInstructionCount), register: 10, into: &guardWords)
    guardWords.append(
      encodeAddSubtractSetFlags(add: false, is64Bit: true, 9, 10, 31))
    let enoughBudgetBranch = guardWords.count
    guardWords.append(0)
    guardWords.append(
      encodeMoveWideZero32(register: 0, immediate: UInt16(DoryJITExitCode.dispatch.rawValue)))
    guardWords.append(0xD65F_03C0)
    let pendingWorkExit = guardWords.count
    guardWords.append(
      encodeMoveWideZero32(register: 0, immediate: UInt16(DoryJITExitCode.pendingWork.rawValue)))
    guardWords.append(0xD65F_03C0)
    let bodyStart = guardWords.count
    guardWords[1] = encodeCompareBranchNonZero32(
      register: 9,
      wordOffset: pendingWorkExit - 1
    )
    guardWords[3] = encodeCompareBranchZero64(register: 9, wordOffset: bodyStart - 3)
    guardWords[enoughBudgetBranch] = encodeConditionalBranch(
      condition: .carrySet,
      wordOffset: bodyStart - enoughBudgetBranch
    )
    words.insert(contentsOf: guardWords, at: 0)
  }

  private func emitChainAccounting(
    contextRegister: UInt32,
    guestInstructionCount: UInt32,
    guestStart: UInt64,
    into words: inout [UInt32]
  ) {
    words.append(
      encodeLoad64(register: 9, base: contextRegister, byteOffset: Self.chainEnabledOffset))
    let disabledBranch = words.count
    words.append(0)
    emitImmediate(UInt64(guestInstructionCount), register: 10, into: &words)
    words.append(
      encodeLoad64(
        register: 11,
        base: contextRegister,
        byteOffset: Self.chainRemainingInstructionsOffset
      ))
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: true, 11, 10, 11))
    words.append(
      encodeStore64(
        register: 11,
        base: contextRegister,
        byteOffset: Self.chainRemainingInstructionsOffset
      ))
    words.append(
      encodeLoad64(
        register: 11,
        base: contextRegister,
        byteOffset: Self.chainRetiredInstructionsOffset
      ))
    words.append(encodeAdd(is64Bit: true, left: 11, right: 10, destination: 11))
    words.append(
      encodeStore64(
        register: 11,
        base: contextRegister,
        byteOffset: Self.chainRetiredInstructionsOffset
      ))
    words.append(
      encodeLoad64(
        register: 11,
        base: contextRegister,
        byteOffset: Self.chainRetiredBlocksOffset
      ))
    words.append(encodeAddImmediate64(left: 11, immediate: 1, destination: 11))
    words.append(
      encodeStore64(
        register: 11,
        base: contextRegister,
        byteOffset: Self.chainRetiredBlocksOffset
      ))
    emitImmediate(guestStart, register: 10, into: &words)
    words.append(
      encodeStore64(
        register: 10,
        base: contextRegister,
        byteOffset: Self.chainLastGuestRIPOffset
      ))
    let done = words.count
    words[disabledBranch] = encodeCompareBranchZero64(
      register: 9,
      wordOffset: done - disabledBranch
    )
  }

  private func supportsChainSlots(for terminator: DoryIRTerminator) -> Bool {
    switch terminator {
    case .next(let target), .branch(let target), .call(let target, _):
      return DoryX86ArchitecturalState.isCanonical(target)
    case .conditional(_, let taken, let notTaken):
      return DoryX86ArchitecturalState.isCanonical(taken)
        && DoryX86ArchitecturalState.isCanonical(notTaken)
    default:
      return false
    }
  }

  private func supportsIndirectBranchTargetCache(for terminator: DoryIRTerminator) -> Bool {
    switch terminator {
    case .indirect, .indirectCall, .returnFromCall:
      return true
    default:
      return false
    }
  }

  /// Pushes the architectural CALL pair and, when already resident, its predicted host return
  /// target. A zero host address is a valid cold prediction and makes the later RET fall through
  /// to the IBTC/dispatcher path without compromising architectural state.
  private func emitShadowReturnStackPush(returnAddress: UInt64, into words: inout [UInt32]) {
    words.append(encodeLoad64(register: 9, base: 0, byteOffset: Self.chainEnabledOffset))
    let disabledBranch = words.count
    words.append(0)
    words.append(
      encodeLoad64(register: 10, base: 0, byteOffset: Self.shadowReturnEntriesBaseOffset))
    let missingEntriesBranch = words.count
    words.append(0)
    words.append(
      encodeLoad64(register: 11, base: 0, byteOffset: Self.shadowReturnTopAddressOffset))
    let missingTopBranch = words.count
    words.append(0)
    words.append(encodeLoad64(register: 12, base: 11, byteOffset: 0))
    words.append(
      encodeLoad64(register: 13, base: 0, byteOffset: Self.shadowReturnEntryMaskOffset))
    words.append(encodeLogical(.and, left: 13, right: 12, destination: 13))
    words.append(encodeAdd(is64Bit: true, left: 10, right: 13, leftShift: 5, destination: 10))
    words.append(encodeLoad64(register: 13, base: 0, byteOffset: Self.rspOffset))
    words.append(encodeStore64(register: 13, base: 10, byteOffset: 0))
    emitImmediate(returnAddress, register: 15, into: &words)
    words.append(encodeStore64(register: 15, base: 10, byteOffset: 8))
    words.append(encodeStore64(register: 31, base: 10, byteOffset: 16))
    words.append(
      encodeLoad64(register: 13, base: 0, byteOffset: Self.shadowReturnGenerationOffset))
    words.append(encodeStore64(register: 13, base: 10, byteOffset: 24))

    // Reuse a warm IBTC target for the return continuation without counting this predictor fill
    // as an executed indirect branch lookup.
    words.append(encodeLoad64(register: 14, base: 0, byteOffset: Self.ibtcEntriesBaseOffset))
    let missingIBTCBranch = words.count
    words.append(0)
    words.append(encodeLoad64(register: 16, base: 0, byteOffset: Self.ibtcEntryMaskOffset))
    words.append(
      encodeLogical(
        .and,
        left: 16,
        right: 15,
        shiftAmount: 2,
        logicalRightShift: true,
        destination: 16
      ))
    words.append(encodeAdd(is64Bit: true, left: 14, right: 16, leftShift: 5, destination: 14))
    words.append(encodeLoad64(register: 16, base: 14, byteOffset: 0))
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: true, 16, 15, 31))
    let tagMismatchBranch = words.count
    words.append(0)
    words.append(encodeLoad64(register: 16, base: 14, byteOffset: 16))
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: true, 16, 13, 31))
    let generationMismatchBranch = words.count
    words.append(0)
    words.append(encodeLoad64(register: 16, base: 14, byteOffset: 8))
    let missingHostBranch = words.count
    words.append(0)
    words.append(encodeStore64(register: 16, base: 10, byteOffset: 16))

    let finishPush = words.count
    words.append(encodeAddImmediate64(left: 12, immediate: 1, destination: 12))
    words.append(encodeStore64(register: 12, base: 11, byteOffset: 0))
    emitIncrementContextWord(byteOffset: Self.shadowReturnPushesOffset, into: &words)
    let done = words.count
    words[disabledBranch] = encodeCompareBranchZero64(
      register: 9, wordOffset: done - disabledBranch)
    words[missingEntriesBranch] = encodeCompareBranchZero64(
      register: 10, wordOffset: done - missingEntriesBranch)
    words[missingTopBranch] = encodeCompareBranchZero64(
      register: 11, wordOffset: done - missingTopBranch)
    words[missingIBTCBranch] = encodeCompareBranchZero64(
      register: 14, wordOffset: finishPush - missingIBTCBranch)
    words[tagMismatchBranch] = encodeConditionalBranch(
      condition: .notEqual, wordOffset: finishPush - tagMismatchBranch)
    words[generationMismatchBranch] = encodeConditionalBranch(
      condition: .notEqual, wordOffset: finishPush - generationMismatchBranch)
    words[missingHostBranch] = encodeCompareBranchZero64(
      register: 16, wordOffset: finishPush - missingHostBranch)
  }

  /// Pops and validates `{guest RSP, guest RIP, generation, host address}` after the architectural
  /// RET read and stack update have succeeded. Any mismatch falls through to the ordinary IBTC.
  private func emitShadowReturnStackLookup(popBytes: UInt16, into words: inout [UInt32]) {
    words.append(encodeLoad64(register: 9, base: 0, byteOffset: Self.chainEnabledOffset))
    let disabledBranch = words.count
    words.append(0)
    words.append(
      encodeLoad64(register: 10, base: 0, byteOffset: Self.shadowReturnEntriesBaseOffset))
    let missingEntriesBranch = words.count
    words.append(0)
    words.append(
      encodeLoad64(register: 11, base: 0, byteOffset: Self.shadowReturnTopAddressOffset))
    let missingTopBranch = words.count
    words.append(0)
    words.append(encodeLoad64(register: 12, base: 11, byteOffset: 0))
    let emptyBranch = words.count
    words.append(0)
    words.append(encodeSubtractImmediate64(left: 12, immediate: 1, destination: 12))
    words.append(encodeStore64(register: 12, base: 11, byteOffset: 0))
    words.append(
      encodeLoad64(register: 13, base: 0, byteOffset: Self.shadowReturnEntryMaskOffset))
    words.append(encodeLogical(.and, left: 13, right: 12, destination: 13))
    words.append(encodeAdd(is64Bit: true, left: 10, right: 13, leftShift: 5, destination: 10))

    words.append(encodeLoad64(register: 13, base: 0, byteOffset: Self.rspOffset))
    emitImmediate(UInt64(8) &+ UInt64(popBytes), register: 14, into: &words)
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: true, 13, 14, 13))
    words.append(encodeLoad64(register: 14, base: 10, byteOffset: 0))
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: true, 14, 13, 31))
    let stackMismatchBranch = words.count
    words.append(0)
    words.append(encodeLoad64(register: 13, base: 0, byteOffset: Self.ripOffset))
    words.append(encodeLoad64(register: 14, base: 10, byteOffset: 8))
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: true, 14, 13, 31))
    let targetMismatchBranch = words.count
    words.append(0)
    words.append(encodeLoad64(register: 13, base: 0, byteOffset: Self.shadowReturnGenerationOffset))
    words.append(encodeLoad64(register: 14, base: 10, byteOffset: 24))
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: true, 14, 13, 31))
    let generationMismatchBranch = words.count
    words.append(0)
    words.append(encodeLoad64(register: 16, base: 10, byteOffset: 16))
    let missingHostBranch = words.count
    words.append(0)
    emitIncrementContextWord(byteOffset: Self.shadowReturnHitsOffset, into: &words)
    words.append(encodeBranch(register: 16))
    let miss = words.count
    emitIncrementContextWord(byteOffset: Self.shadowReturnMissesOffset, into: &words)
    let done = words.count
    words[disabledBranch] = encodeCompareBranchZero64(
      register: 9, wordOffset: done - disabledBranch)
    words[missingEntriesBranch] = encodeCompareBranchZero64(
      register: 10, wordOffset: done - missingEntriesBranch)
    words[missingTopBranch] = encodeCompareBranchZero64(
      register: 11, wordOffset: done - missingTopBranch)
    words[emptyBranch] = encodeCompareBranchZero64(
      register: 12, wordOffset: miss - emptyBranch)
    words[stackMismatchBranch] = encodeConditionalBranch(
      condition: .notEqual, wordOffset: miss - stackMismatchBranch)
    words[targetMismatchBranch] = encodeConditionalBranch(
      condition: .notEqual, wordOffset: miss - targetMismatchBranch)
    words[generationMismatchBranch] = encodeConditionalBranch(
      condition: .notEqual, wordOffset: miss - generationMismatchBranch)
    words[missingHostBranch] = encodeCompareBranchZero64(
      register: 16, wordOffset: miss - missingHostBranch)
  }

  /// Probes `{guest RIP, host address, generation, reserved}` directly from the per-vCPU C table.
  /// The evaluated target already lives in the context RIP word. Every miss reaches the following
  /// block-local dispatcher return; a hit tail-branches only while chain mode is explicitly active.
  private func emitIndirectBranchTargetCacheLookup(into words: inout [UInt32]) {
    words.append(encodeLoad64(register: 9, base: 0, byteOffset: Self.chainEnabledOffset))
    let disabledBranch = words.count
    words.append(0)
    words.append(encodeLoad64(register: 10, base: 0, byteOffset: Self.ibtcEntriesBaseOffset))
    let missingBaseBranch = words.count
    words.append(0)
    words.append(encodeLoad64(register: 9, base: 0, byteOffset: Self.ripOffset))
    words.append(encodeLoad64(register: 11, base: 0, byteOffset: Self.ibtcEntryMaskOffset))
    words.append(
      encodeLogical(
        .and,
        left: 11,
        right: 9,
        shiftAmount: 2,
        logicalRightShift: true,
        destination: 11
      ))
    words.append(encodeAdd(is64Bit: true, left: 10, right: 11, leftShift: 5, destination: 10))
    words.append(encodeLoad64(register: 11, base: 10, byteOffset: 0))
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: true, 11, 9, 31))
    let tagMismatchBranch = words.count
    words.append(0)
    words.append(encodeLoad64(register: 11, base: 10, byteOffset: 16))
    words.append(encodeLoad64(register: 12, base: 0, byteOffset: Self.ibtcGenerationOffset))
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: true, 11, 12, 31))
    let generationMismatchBranch = words.count
    words.append(0)
    words.append(encodeLoad64(register: 16, base: 10, byteOffset: 8))
    let missingTargetBranch = words.count
    words.append(0)
    emitIncrementContextWord(byteOffset: Self.ibtcInlineHitsOffset, into: &words)
    words.append(encodeBranch(register: 16))
    let miss = words.count
    emitIncrementContextWord(byteOffset: Self.ibtcInlineMissesOffset, into: &words)
    let fallback = words.count
    words[disabledBranch] = encodeCompareBranchZero64(
      register: 9,
      wordOffset: fallback - disabledBranch
    )
    words[missingBaseBranch] = encodeCompareBranchZero64(
      register: 10,
      wordOffset: miss - missingBaseBranch
    )
    words[tagMismatchBranch] = encodeConditionalBranch(
      condition: .notEqual,
      wordOffset: miss - tagMismatchBranch
    )
    words[generationMismatchBranch] = encodeConditionalBranch(
      condition: .notEqual,
      wordOffset: miss - generationMismatchBranch
    )
    words[missingTargetBranch] = encodeCompareBranchZero64(
      register: 16,
      wordOffset: miss - missingTargetBranch
    )
  }

  private func emitIncrementContextWord(byteOffset: Int, into words: inout [UInt32]) {
    words.append(encodeLoad64(register: 11, base: 0, byteOffset: byteOffset))
    words.append(encodeAddImmediate64(left: 11, immediate: 1, destination: 11))
    words.append(encodeStore64(register: 11, base: 0, byteOffset: byteOffset))
  }

  private func requiresRuntimeAddressGuard(_ terminator: DoryIRTerminator) -> Bool {
    switch terminator {
    case .call, .indirectCall, .indirect, .returnFromCall: true
    case .conditional(_, let taken, let notTaken):
      !DoryX86ArchitecturalState.isCanonical(taken)
        || !DoryX86ArchitecturalState.isCanonical(notTaken)
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
      case .atomicBinary(_, let destination, let source):
        return isFSOrGS(destination) || isFSOrGS(source)
      case .unary(_, let operand), .shift(_, let operand, _), .byteSwap(let operand),
        .stackPush(let operand), .stackPop(let operand):
        return isFSOrGS(operand)
      case .atomicUnary(_, let operand):
        return isFSOrGS(operand)
      case .conditionalMove(_, let destination, let source):
        return isFSOrGS(destination) || isFSOrGS(source)
      case .setCondition(_, let destination):
        return isFSOrGS(destination)
      case .bitTestMemoryImmediate(_, let base, _):
        return isFSOrGS(base)
      case .bitTestMemoryRegister(_, let base, _):
        return isFSOrGS(base)
      case .atomicBitTestMemory(_, let base, _):
        return isFSOrGS(base)
      case .bitTestRegister:
        return false
      case .bitScan(_, let destination, let source), .extendMove(let destination, let source, _):
        return isFSOrGS(destination) || isFSOrGS(source)
      case .exchangeRegisters:
        return false
      case .signedMultiply(let destination, let lhs, let rhs):
        return isFSOrGS(destination) || isFSOrGS(lhs) || isFSOrGS(rhs)
      case .unsignedAccumulatorMultiply(let source), .unsignedAccumulatorDivide(let source),
        .signedAccumulatorDivide(let source):
        return isFSOrGS(source)
      case .doubleShiftRightCL(let destination, let source),
        .doubleShiftRightImmediate(let destination, let source, _):
        return isFSOrGS(destination) || isFSOrGS(source)
      case .compareExchange(let destination, let source):
        return isFSOrGS(destination) || isFSOrGS(source)
      case .compareExchangePair(let destination, _):
        return isFSOrGS(destination)
      case .exchangeMemory(let destination, _):
        return isFSOrGS(destination)
      case .exchangeAddMemory(let destination, _):
        return isFSOrGS(destination)
      case .readSegment(_, let destination):
        return isFSOrGS(destination)
      case .effectiveAddress:
        return false
      case .stackPushFlags, .loadFlagsIntoAH, .storeAHIntoFlags, .setCarryFlag,
        .complementCarryFlag, .clearInterruptFlag, .setDirectionFlag, .readTimestampCounter,
        .signExtendAccumulatorHigh, .readControlRegister, .writeControlRegister, .swapGS,
        .memoryFence, .helper:
        return false
      }
    }
  }

  private func writesMemory(_ statement: DoryIRStatement) -> Bool {
    switch statement {
    case .copy(.memory, _), .binary(_, .memory, _, true), .atomicBinary(_, .memory, _),
      .unary(_, .memory),
      .atomicUnary(_, .memory),
      .shift(_, .memory, _), .stackPush, .stackPushFlags, .compareExchange(.memory, _),
      .compareExchangePair(.memory, _),
      .exchangeMemory(.memory, _), .exchangeAddMemory(.memory, _),
      .atomicBitTestMemory(_, .memory, _):
      true
    case .bitTestMemoryImmediate(let operation, .memory, _): operation != .test
    case .bitTestMemoryRegister(let operation, .memory, _): operation != .test
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
    case .readSegment(let segment, let destination):
      return emitReadSegment(segment, destination: destination, into: &words)
    case .readControlRegister(let index, let destination):
      return emitReadControlRegister(index, destination: destination, into: &words)
    case .writeControlRegister:
      return false
    case .swapGS:
      return emitSwapGS(into: &words)
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
    case .atomicBinary(let operation, let destination, let source):
      return emitAtomicBinary(
        operation,
        destination: destination,
        source: source,
        into: &words
      )
    case .unary(let operation, let operand):
      return emitUnary(operation, operand: operand, into: &words)
    case .atomicUnary(let operation, let operand):
      return emitAtomicUnary(operation, operand: operand, into: &words)
    case .shift(let operation, let destination, let count):
      return emitShift(operation, destination: destination, count: count, into: &words)
    case .conditionalMove(let condition, let destination, let source):
      return emitConditionalMove(
        condition, destination: destination, source: source, into: &words)
    case .setCondition(let condition, let destination):
      return emitSetCondition(condition, destination: destination, into: &words)
    case .bitTestRegister(let operation, let base, let index):
      return emitBitTest(operation: operation, base: base, index: index, into: &words)
    case .bitTestMemoryRegister:
      return false
    case .bitTestMemoryImmediate(let operation, let base, let index):
      return emitBitTest(
        operation: operation, base: base, index: .immediate(UInt64(index), width: .i8), into: &words
      )
    case .atomicBitTestMemory(let operation, let base, let index):
      return emitAtomicBitTestMemory(
        operation: operation, base: base, index: index, into: &words)
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
    case .loadFlagsIntoAH:
      return emitLoadFlagsIntoAH(into: &words)
    case .storeAHIntoFlags:
      return emitStoreAHIntoFlags(into: &words)
    case .setCarryFlag(let enabled):
      return emitSetCarryFlag(enabled: enabled, into: &words)
    case .complementCarryFlag:
      return emitComplementCarryFlag(into: &words)
    case .clearInterruptFlag:
      return emitClearInterruptFlag(into: &words)
    case .setDirectionFlag(let enabled):
      return emitSetDirectionFlag(enabled: enabled, into: &words)
    case .readTimestampCounter:
      return emitReadTimestampCounter(into: &words)
    case .exchangeRegisters(let lhs, let rhs):
      return emitExchangeRegisters(lhs: lhs, rhs: rhs, into: &words)
    case .signExtendAccumulatorHigh(let width):
      return emitSignExtendAccumulatorHigh(width: width, into: &words)
    case .unsignedAccumulatorMultiply(let source):
      return emitUnsignedAccumulatorMultiply(source: source, into: &words)
    case .unsignedAccumulatorDivide(let source):
      return emitAccumulatorDivide(source: source, signed: false, into: &words)
    case .signedAccumulatorDivide(let source):
      return emitAccumulatorDivide(source: source, signed: true, into: &words)
    case .doubleShiftRightCL(let destination, let source):
      return emitDoubleShiftRight(destination: destination, source: source, into: &words)
    case .doubleShiftRightImmediate(let destination, let source, let count):
      return emitDoubleShiftRight(
        destination: destination, source: source, immediateCount: count, into: &words)
    case .compareExchange(let destination, let source):
      return emitCompareExchange(destination: destination, source: source, into: &words)
    case .compareExchangePair(let destination, let doubleQuadword):
      return emitCompareExchangePair(
        destination: destination,
        doubleQuadword: doubleQuadword,
        into: &words
      )
    case .exchangeMemory(let destination, let source):
      return emitExchangeMemory(destination: destination, source: source, into: &words)
    case .exchangeAddMemory(let destination, let source):
      return emitExchangeAddMemory(destination: destination, source: source, into: &words)
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

  private func emitSwapGS(into words: inout [UInt32]) -> Bool {
    words.append(encodeLoad64(register: 9, base: 0, byteOffset: Self.gsBaseOffset))
    words.append(encodeLoad64(register: 10, base: 0, byteOffset: Self.kernelGSBaseOffset))
    words.append(encodeStore64(register: 10, base: 0, byteOffset: Self.gsBaseOffset))
    words.append(encodeStore64(register: 9, base: 0, byteOffset: Self.kernelGSBaseOffset))
    emitImmediate(1, register: 9, into: &words)
    words.append(encodeStore64(register: 9, base: 0, byteOffset: Self.swapGSPerformedOffset))
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

  private func emitLoadFlagsIntoAH(into words: inout [UInt32]) -> Bool {
    words.append(encodeLoad64(register: 9, base: 0, byteOffset: Self.rflagsOffset))
    emitImmediate(0xD5, register: 10, into: &words)
    words.append(encodeLogical(.and, left: 9, right: 10, destination: 10))
    emitImmediate(DoryX86RFLAGS.reservedOne.rawValue, register: 11, into: &words)
    words.append(encodeLogical(.or, left: 10, right: 11, destination: 10))
    words.append(encodeLoad64(register: 9, base: 0, byteOffset: 0))
    emitImmediate(~UInt64(0xFF00), register: 11, into: &words)
    words.append(encodeLogical(.and, left: 9, right: 11, destination: 9))
    words.append(encodeLogical(.or, left: 9, right: 10, shiftAmount: 8, destination: 9))
    words.append(encodeStore64(register: 9, base: 0, byteOffset: 0))
    return true
  }

  private func emitStoreAHIntoFlags(into words: inout [UInt32]) -> Bool {
    words.append(encodeLoad64(register: 9, base: 0, byteOffset: 0))
    words.append(
      encodeLogical(
        .or, left: 31, right: 9,
        shiftAmount: 8, logicalRightShift: true, destination: 10))
    emitImmediate(0xD5, register: 11, into: &words)
    words.append(encodeLogical(.and, left: 10, right: 11, destination: 10))
    words.append(encodeLoad64(register: 9, base: 0, byteOffset: Self.rflagsOffset))
    emitImmediate(~UInt64(0xD5), register: 11, into: &words)
    words.append(encodeLogical(.and, left: 9, right: 11, destination: 9))
    words.append(encodeLogical(.or, left: 9, right: 10, destination: 9))
    emitImmediate(DoryX86RFLAGS.reservedOne.rawValue, register: 10, into: &words)
    words.append(encodeLogical(.or, left: 9, right: 10, destination: 9))
    words.append(encodeStore64(register: 9, base: 0, byteOffset: Self.rflagsOffset))
    return true
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

  private func emitSetCarryFlag(enabled: Bool, into words: inout [UInt32]) -> Bool {
    words.append(encodeLoad64(register: 9, base: 0, byteOffset: Self.rflagsOffset))
    if enabled {
      emitImmediate(DoryX86RFLAGS.carry.rawValue, register: 10, into: &words)
      words.append(encodeLogical(.or, left: 9, right: 10, destination: 9))
    } else {
      emitImmediate(~DoryX86RFLAGS.carry.rawValue, register: 10, into: &words)
      words.append(encodeLogical(.and, left: 9, right: 10, destination: 9))
    }
    emitImmediate(DoryX86RFLAGS.reservedOne.rawValue, register: 10, into: &words)
    words.append(encodeLogical(.or, left: 9, right: 10, destination: 9))
    words.append(encodeStore64(register: 9, base: 0, byteOffset: Self.rflagsOffset))
    return true
  }

  private func emitComplementCarryFlag(into words: inout [UInt32]) -> Bool {
    words.append(encodeLoad64(register: 9, base: 0, byteOffset: Self.rflagsOffset))
    emitImmediate(DoryX86RFLAGS.carry.rawValue, register: 10, into: &words)
    words.append(encodeLogical(.xor, left: 9, right: 10, destination: 9))
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
    words.append(
      encodeLogical(
        .or, left: 31, right: 9, shiftAmount: 32, logicalRightShift: true, destination: 10))
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
      register.bank == "x86.gpr", register.index < 16,
      register.width == .i64
    else { return false }

    words.append(encodeLoad64(register: 9, base: 0, byteOffset: Self.rspOffset))
    emitCanonicalStackSpanGuard(addressRegister: 9, into: &words)
    emitMemoryRead(addressRegister: 9, width: .i64, resultRegister: 10, words: &words)
    // POP RSP replaces the incremented pointer with the loaded value. Only other
    // destinations retain the old stack pointer plus eight.
    if register.index != 4 {
      words.append(encodeLoad64(register: 9, base: 0, byteOffset: Self.rspOffset))
      emitImmediate(8, register: 11, into: &words)
      words.append(encodeAdd(is64Bit: true, left: 9, right: 11, destination: 9))
      words.append(encodeStore64(register: 9, base: 0, byteOffset: Self.rspOffset))
    }
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
      target.bank == "x86.gpr", target.index < 16,
      target.width == .i32 || target.width == .i64
    else { return false }

    let is64Bit = target.width == .i64
    guard load(source, matching: target.width, into: 9, words: &words) else { return false }
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

  private func emitAtomicBitTestMemory(
    operation: DoryX86BitOperation,
    base: DoryIROperand,
    index: DoryIROperand,
    into words: inout [UInt32]
  ) -> Bool {
    let operationCode: UInt16
    switch operation {
    case .set: operationCode = 3
    case .reset: operationCode = 2
    case .complement: operationCode = 4
    case .test: return false
    }
    guard case .memory(let address, let width) = base,
      width == .i32 || width == .i64
    else { return false }

    switch index {
    case .register(let register):
      guard register.bank == "x86.gpr", register.index < 16, register.width == width,
        emitMemoryAddress(address, into: 12, includeSegmentBase: false, words: &words),
        load(register, into: 10, words: &words)
      else { return false }
      if width == .i32, address.addressWidth == .i64 {
        // Register bit indices are signed at the operand width before they select a
        // surrounding memory element. Extend ECX-like inputs before 64-bit address math.
        words.append(0x9340_0000 | 31 << 10 | 10 << 5 | 10)  // sxtw x10, w10
      }
      emitImmediate(width == .i64 ? 6 : 5, register: 11, into: &words)
      words.append(
        encodeVariableShift(
          .arithmeticRight,
          is64Bit: width == .i64 || address.addressWidth == .i64,
          value: 10,
          count: 11,
          destination: 10
        ))
      words.append(
        encodeAdd(
          is64Bit: address.addressWidth == .i64,
          left: 12,
          right: 10,
          leftShift: width == .i64 ? 3 : 2,
          destination: 12
        ))
      if let segment = address.segment {
        let offset = segment == "fs" ? Self.fsBaseOffset : Self.gsBaseOffset
        words.append(encodeLoad64(register: 10, base: 0, byteOffset: offset))
        words.append(encodeAdd(is64Bit: true, left: 12, right: 10, destination: 12))
      }
      guard load(register, into: 10, words: &words) else { return false }
      emitImmediate(UInt64(width.rawValue - 1), register: 11, into: &words)
      words.append(encodeLogical(.and, left: 10, right: 11, destination: 10))
      emitImmediate(1, register: 11, into: &words)
      words.append(
        encodeVariableShift(
          .left,
          is64Bit: width == .i64,
          value: 11,
          count: 10,
          destination: 10
        ))
    case .immediate(let rawIndex, .i8):
      guard emitMemoryAddress(address, into: 12, words: &words) else { return false }
      emitImmediate(
        1 << (rawIndex & UInt64(width.rawValue - 1)),
        register: 10,
        into: &words
      )
    default:
      return false
    }

    if operation == .reset {
      emitImmediate(width == .i64 ? UInt64.max : UInt64(UInt32.max), register: 11, into: &words)
      words.append(encodeLogical(.xor, is64Bit: width == .i64, 10, 11, 10))
    }
    words.append(encodeStore64(register: 10, base: 31, byteOffset: 64))
    words.append(encodeStore64(register: 12, base: 31, byteOffset: 88))
    words.append(encodeLoad64(register: 16, base: 19, byteOffset: Self.atomicRMWOffset))
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: true, 16, 31, 31))
    emitInterpreterUnless(condition: .notEqual, usesMemory: true, into: &words)
    words.append(encodeLogical(.or, left: 31, right: 19, destination: 0))
    words.append(encodeLogical(.or, left: 31, right: 20, destination: 1))
    words.append(encodeLoad64(register: 2, base: 31, byteOffset: 88))
    words.append(encodeLoad64(register: 3, base: 31, byteOffset: 64))
    words.append(encodeMoveWideZero32(register: 4, immediate: UInt16(width.rawValue / 8)))
    words.append(encodeMoveWideZero32(register: 5, immediate: operationCode))
    words.append(encodeAddImmediate64(left: 31, immediate: 80, destination: 6))
    words.append(0xD63F_0000 | 16 << 5)  // blr x16 (C translated atomic RMW)
    emitAtomicResolutionUnlessSuccess(into: &words)

    words.append(encodeLogical(.or, left: 31, right: 19, destination: 0))
    words.append(encodeLoad64(register: 9, base: 31, byteOffset: 80))
    words.append(encodeLoad64(register: 10, base: 31, byteOffset: 64))
    if operation == .reset {
      emitImmediate(width == .i64 ? UInt64.max : UInt64(UInt32.max), register: 11, into: &words)
      words.append(encodeLogical(.xor, is64Bit: width == .i64, 10, 11, 10))
    }
    words.append(encodeLogical(.andSetFlags, is64Bit: width == .i64, 9, 10, 11))
    words.append(encodeConditionalSet(register: 13, condition: .notEqual))
    words.append(encodeLoad64(register: 14, base: 0, byteOffset: Self.rflagsOffset))
    emitImmediate(~DoryX86RFLAGS.carry.rawValue, register: 15, into: &words)
    words.append(encodeLogical(.and, left: 14, right: 15, destination: 14))
    words.append(encodeLogical(.or, left: 14, right: 13, destination: 14))
    emitImmediate(DoryX86RFLAGS.reservedOne.rawValue, register: 15, into: &words)
    words.append(encodeLogical(.or, left: 14, right: 15, destination: 14))
    words.append(encodeStore64(register: 14, base: 0, byteOffset: Self.rflagsOffset))
    return true
  }

  private func emitConditionalMove(
    _ condition: DoryX86Condition,
    destination: DoryIROperand,
    source: DoryIROperand,
    into words: inout [UInt32]
  ) -> Bool {
    guard case .register(let target) = destination,
      target.bank == "x86.gpr", target.index < 16,
      target.width == .i32 || target.width == .i64,
      load(source, matching: target.width, into: 13, words: &words),
      emitX86Condition(condition, into: 10, words: &words)
    else { return false }

    words.append(
      target.width == .i64
        ? encodeLoad64(register: 12, base: 0, byteOffset: Int(target.index) * 8)
        : encodeLoad32(register: 12, base: 0, byteOffset: Int(target.index) * 8)
    )
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: true, 10, 31, 31))
    words.append(
      encodeConditionalSelect(
        destination: 9,
        trueRegister: 13,
        falseRegister: 12,
        condition: .notEqual
      ))
    words.append(encodeStore64(register: 9, base: 0, byteOffset: Int(target.index) * 8))
    return true
  }

  private func emitReadSegment(
    _ segment: DoryX86SegmentRegister,
    destination: DoryIROperand,
    into words: inout [UInt32]
  ) -> Bool {
    switch destination {
    case .register(let target)
    where target.bank == "x86.gpr" && target.index < 16 && target.width == .i16:
      words.append(encodeLoad64(register: 9, base: 0, byteOffset: Int(target.index) * 8))
      words.append(
        encodeLoad64(register: 10, base: 0, byteOffset: Self.segmentSelectorOffset(segment)))
      emitImmediate(~UInt64(0xFFFF), register: 11, into: &words)
      words.append(encodeLogical(.and, left: 9, right: 11, destination: 9))
      emitImmediate(0xFFFF, register: 11, into: &words)
      words.append(encodeLogical(.and, left: 10, right: 11, destination: 10))
      words.append(encodeLogical(.or, left: 9, right: 10, destination: 9))
      words.append(encodeStore64(register: 9, base: 0, byteOffset: Int(target.index) * 8))
      return true
    case .memory(let address, width: .i16):
      guard emitMemoryAddress(address, into: 9, words: &words) else { return false }
      words.append(
        encodeLoad64(register: 10, base: 0, byteOffset: Self.segmentSelectorOffset(segment)))
      emitImmediate(0xFFFF, register: 11, into: &words)
      words.append(encodeLogical(.and, left: 10, right: 11, destination: 10))
      emitMemoryWrite(addressRegister: 9, valueRegister: 10, width: .i16, words: &words)
      return true
    default:
      return false
    }
  }

  private func emitReadControlRegister(
    _ index: UInt8,
    destination: DoryIRRegister,
    into words: inout [UInt32]
  ) -> Bool {
    guard index == 3, destination.bank == "x86.gpr", destination.index < 16,
      destination.width == .i64
    else { return false }
    words.append(encodeLoad64(register: 9, base: 0, byteOffset: Self.cr3Offset))
    words.append(encodeStore64(register: 9, base: 0, byteOffset: Int(destination.index) * 8))
    return true
  }

  private static func segmentSelectorOffset(_ segment: DoryX86SegmentRegister) -> Int {
    switch segment {
    case .cs: csSelectorOffset
    case .ds: dsSelectorOffset
    case .es: esSelectorOffset
    case .fs: fsSelectorOffset
    case .gs: gsSelectorOffset
    case .ss: ssSelectorOffset
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
      && (target.width == .i8 || target.width == .i16):
      switch source {
      case .register(let register)
      where register.bank == "x86.gpr" && register.index < 16
        && register.width == target.width:
        words.append(
          encodeLoad64(register: 10, base: 0, byteOffset: Int(register.index) * 8))
      case .immediate(let value, let width) where width == target.width:
        emitImmediate(value, register: 10, into: &words)
      case .memory(let address, let width) where width == target.width:
        guard emitMemoryAddress(address, into: 9, words: &words) else { return false }
        emitMemoryRead(addressRegister: 9, width: width, resultRegister: 10, words: &words)
      default:
        return false
      }
      let mask: UInt64 = target.width == .i8 ? 0xFF : 0xFFFF
      emitImmediate(mask, register: 11, into: &words)
      words.append(encodeLogical(.and, left: 10, right: 11, destination: 10))
      words.append(encodeLoad64(register: 9, base: 0, byteOffset: Int(target.index) * 8))
      emitImmediate(~mask, register: 11, into: &words)
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
    case .atomicBinary:
      return 1
    case .unary(let operation, let operand):
      _ = operation
      if case .memory = operand { return 2 }
      return 0
    case .atomicUnary:
      return 1
    case .shift(_, let destination, _):
      if case .memory = destination { return 2 }
      return 0
    case .bitTestMemoryImmediate(let operation, _, _):
      return operation == .test ? 1 : 2
    case .bitTestMemoryRegister(let operation, _, _):
      return operation == .test ? 1 : 2
    case .atomicBitTestMemory:
      return 1
    case .conditionalMove(_, _, let source):
      if case .memory = source { return 1 }
      return 0
    case .setCondition, .bitTestRegister, .exchangeRegisters:
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
    case .unsignedAccumulatorMultiply(let source), .unsignedAccumulatorDivide(let source),
      .signedAccumulatorDivide(let source):
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
    case .compareExchange, .compareExchangePair, .exchangeMemory, .exchangeAddMemory,
      .memoryFence:
      return 1
    case .readSegment(_, let destination):
      if case .memory = destination { return 1 }
      return 0
    case .effectiveAddress, .readControlRegister, .writeControlRegister, .swapGS,
      .loadFlagsIntoAH, .storeAHIntoFlags,
      .setCarryFlag,
      .complementCarryFlag, .clearInterruptFlag, .setDirectionFlag, .readTimestampCounter,
      .signExtendAccumulatorHigh, .helper:
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
      target.width == .i32 || target.width == .i64
    else { return false }
    func isMemoryOperand(_ operand: DoryIROperand) -> Bool {
      if case .memory = operand { return true }
      return false
    }
    let lhsIsMemory = isMemoryOperand(lhs)
    let rhsIsMemory = isMemoryOperand(rhs)
    let memoryOperandCount = (lhsIsMemory ? 1 : 0) + (rhsIsMemory ? 1 : 0)
    guard memoryOperandCount <= 1 else { return false }
    switch lhs {
    case .register(let left)
    where left.bank == "x86.gpr" && left.index < 16 && left.width == target.width:
      break
    case .memory(_, let width) where width == target.width:
      break
    default:
      return false
    }
    switch rhs {
    case .register(let right)
    where right.bank == "x86.gpr" && right.index < 16 && right.width == target.width:
      break
    case .immediate(_, let width) where width == target.width:
      break
    case .memory(_, let width) where width == target.width:
      break
    default:
      return false
    }

    if rhsIsMemory {
      guard load(rhs, matching: target.width, into: 10, words: &words),
        load(lhs, matching: target.width, into: 9, words: &words)
      else { return false }
    } else {
      guard load(lhs, matching: target.width, into: 9, words: &words),
        load(rhs, matching: target.width, into: 10, words: &words)
      else { return false }
    }

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
      sourceRegister.bank == "x86.gpr", sourceRegister.index < 16,
      sourceRegister.width == .i32 || sourceRegister.width == .i64
    else { return false }
    let is64Bit = sourceRegister.width == .i64
    words.append(
      is64Bit
        ? encodeLoad64(register: 9, base: 0, byteOffset: 0)
        : encodeLoad32(register: 9, base: 0, byteOffset: 0))
    words.append(
      is64Bit
        ? encodeLoad64(register: 10, base: 0, byteOffset: Int(sourceRegister.index) * 8)
        : encodeLoad32(register: 10, base: 0, byteOffset: Int(sourceRegister.index) * 8))
    words.append(encodeMultiply64(left: 9, right: 10, destination: 11))
    if is64Bit {
      words.append(encodeUnsignedMultiplyHigh64(left: 9, right: 10, destination: 12))
    } else {
      words.append(
        encodeLogical(
          .or,
          is64Bit: true,
          left: 31,
          right: 11,
          shiftAmount: 32,
          logicalRightShift: true,
          destination: 12
        ))
      words.append(encodeLogical(.or, is64Bit: false, 31, 11, 11))
    }
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

  private func emitSignExtendAccumulatorHigh(
    width: DoryIRIntegerWidth,
    into words: inout [UInt32]
  ) -> Bool {
    let count: UInt64
    let is64Bit: Bool
    switch width {
    case .i32:
      words.append(encodeLoad32(register: 9, base: 0, byteOffset: 0))
      count = 31
      is64Bit = false
    case .i64:
      words.append(encodeLoad64(register: 9, base: 0, byteOffset: 0))
      count = 63
      is64Bit = true
    default:
      return false
    }
    emitImmediate(count, register: 10, into: &words)
    words.append(
      encodeVariableShift(
        .arithmeticRight,
        is64Bit: is64Bit,
        value: 9,
        count: 10,
        destination: 9
      ))
    words.append(encodeStore64(register: 9, base: 0, byteOffset: 2 * 8))
    return true
  }

  private func emitAccumulatorDivide(
    source: DoryIROperand,
    signed: Bool,
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
    words.append(
      is64Bit
        ? encodeLoad64(register: 9, base: 0, byteOffset: 0)
        : encodeLoad32(register: 9, base: 0, byteOffset: 0)
    )
    if signed {
      // Native SDIV takes one signed word. Other RDX:RAX values still need the
      // interpreter's double-width division, before any architectural write.
      emitImmediate(is64Bit ? 63 : 31, register: 12, into: &words)
      words.append(
        encodeVariableShift(
          .arithmeticRight, is64Bit: is64Bit,
          value: 9, count: 12, destination: 12))
      words.append(encodeAddSubtractSetFlags(add: false, is64Bit: is64Bit, 11, 12, 31))
      emitInterpreterUnless(condition: .equal, usesMemory: false, into: &words)

      // ARM wraps MIN / -1; x86 must raise #DE with the original state intact.
      emitImmediate(is64Bit ? 0x8000_0000_0000_0000 : 0x8000_0000, register: 12, into: &words)
      words.append(encodeAddSubtractSetFlags(add: false, is64Bit: is64Bit, 9, 12, 31))
      let nonMinimum = words.count
      words.append(0)
      emitImmediate(.max, register: 12, into: &words)
      words.append(encodeAddSubtractSetFlags(add: false, is64Bit: is64Bit, 10, 12, 31))
      emitInterpreterUnless(condition: .notEqual, usesMemory: false, into: &words)
      words[nonMinimum] = encodeConditionalBranch(
        condition: .notEqual, wordOffset: words.count - nonMinimum)
    } else {
      words.append(encodeAddSubtractSetFlags(add: false, is64Bit: true, 11, 31, 31))
      emitInterpreterUnless(condition: .equal, usesMemory: false, into: &words)
    }
    words.append(
      encodeAccumulatorDivide(
        signed: signed, is64Bit: is64Bit,
        dividend: 9, divisor: 10, quotient: 12))
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
    case .memory(let address, let width)
    where width == .i8 || width == .i16
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
    if operation == .rotateLeft || operation == .rotateRight {
      guard is64Bit else { return false }
      guard case .immediate(let rawCount) = countSource else { return false }
      let count = UInt32(rawCount) & 0x3f
      guard count != 0 else { return true }
      words.append(
        encodeRotateRightImmediate64(
          value: 9,
          amount: operation == .rotateLeft ? bitCount - count : count,
          destination: 11
        ))
      emitRotateFlags(
        operation,
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
    _ operation: DoryIRShiftOperation,
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
        shiftAmount: operation == .rotateLeft ? 0 : bitCount - 1,
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
          shiftAmount: operation == .rotateLeft ? bitCount - 1 : bitCount - 2,
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
    case .rotateLeft, .rotateRight:
      preconditionFailure("rotate uses dedicated flag lowering")
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
      case .rotateLeft, .rotateRight:
        preconditionFailure("rotate uses dedicated flag lowering")
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
      encodeSubtractImmediate64(left: 31, immediate: 112, destination: 31),
      0xA901_53F3,  // stp x19,x20,[sp,#16]
      0xA902_5BF5,  // stp x21,x22,[sp,#32]
      0xA903_63F7,  // stp x23,x24,[sp,#48]
      0xAA00_03F3,  // mov x19,x0 (architectural context)
      // Keep host control state in the context, not beside generated memory temporaries.
      // This makes a corrupted generated frame incapable of supplying FP/LR at RET.
      encodeStore64(register: 29, base: 19, byteOffset: Self.hostFramePointerOffset),
      encodeStore64(register: 30, base: 19, byteOffset: Self.hostReturnAddressOffset),
      0x9100_03FD,  // mov x29,sp
      0xAA01_03F4,  // mov x20,x1 (memory context)
      0xAA02_03F5,  // mov x21,x2 (read callback)
      0xAA03_03F6,  // mov x22,x3 (write callback)
      0xAA04_03F7,  // mov x23,x4 (atomic compare-exchange callback)
      0xAA05_03F8,  // mov x24,x5 (synchronize callback)
    ]
  }

  private func emitMemoryEpilogue(into words: inout [UInt32]) {
    words += [
      // Load the trusted values before restoring x19, which owns the context pointer.
      encodeLoad64(register: 16, base: 19, byteOffset: Self.hostFramePointerOffset),
      encodeLoad64(register: 17, base: 19, byteOffset: Self.hostReturnAddressOffset),
      0xA943_63F7,  // ldp x23,x24,[sp,#48]
      0xA942_5BF5,  // ldp x21,x22,[sp,#32]
      0xA941_53F3,  // ldp x19,x20,[sp,#16]
      encodeAddImmediate64(left: 31, immediate: 112, destination: 31),
      encodeLogical(.or, left: 31, right: 16, destination: 29),  // mov x29,x16
      encodeLogical(.or, left: 31, right: 17, destination: 30),  // mov x30,x17
    ]
  }

  private func emitMemoryChainEpilogue(into words: inout [UInt32]) {
    words += [
      0xAA13_03E0,  // mov x0,x19 (architectural context)
      0xAA14_03E1,  // mov x1,x20 (memory context)
      0xAA15_03E2,  // mov x2,x21 (read callback)
      0xAA16_03E3,  // mov x3,x22 (write callback)
      0xAA17_03E4,  // mov x4,x23 (atomic compare-exchange callback)
      0xAA18_03E5,  // mov x5,x24 (synchronize callback)
    ]
    emitMemoryEpilogue(into: &words)
  }

  private func emitMemoryRead(
    addressRegister: UInt32,
    width: DoryIRIntegerWidth,
    resultRegister: UInt32,
    words: inout [UInt32]
  ) {
    let byteCount = UInt32(width.rawValue / 8)
    words.append(encodeStore64(register: addressRegister, base: 31, byteOffset: 88))
    // A scalar spanning two linear pages cannot use one direct-mapped entry. Preserve the
    // callback path before consulting the table.
    emitImmediate(0xfff, register: 13, into: &words)
    words.append(encodeLogical(.and, left: addressRegister, right: 13, destination: 13))
    emitImmediate(UInt64(4_097 - byteCount), register: 14, into: &words)
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: true, 13, 14, 31))
    let crossPageBranch = words.count
    words.append(0)

    // Build the exact {canonical VPN, address-space generation} tag and direct-map index.
    words.append(
      encodeLogical(
        .or,
        left: 31,
        right: addressRegister,
        shiftAmount: 12,
        logicalRightShift: true,
        destination: 14
      ))
    words.append(
      encodeLogical(.or, left: 31, right: 14, shiftAmount: 28, destination: 14))
    words.append(
      encodeLoad64(
        register: 15,
        base: 19,
        byteOffset: Self.tlbAddressSpaceGenerationOffset
      ))
    words.append(encodeLogical(.or, left: 14, right: 15, destination: 14))
    words.append(
      encodeLogical(
        .or,
        left: 31,
        right: addressRegister,
        shiftAmount: 12,
        logicalRightShift: true,
        destination: 13
      ))
    words.append(
      encodeLoad64(register: 15, base: 19, byteOffset: Self.tlbEntryMaskOffset))
    words.append(encodeLogical(.and, left: 13, right: 15, destination: 13))
    words.append(encodeLoad64(register: 15, base: 19, byteOffset: Self.readTLBBaseOffset))
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: true, 15, 31, 31))
    let missingTLBBranch = words.count
    words.append(0)
    words.append(encodeAdd(is64Bit: true, left: 15, right: 13, leftShift: 4, destination: 15))
    words.append(encodeLoad64(register: 16, base: 15, byteOffset: 0))
    words.append(encodeLoad64(register: 17, base: 15, byteOffset: 8))
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: true, 16, 14, 31))
    let missBranch = words.count
    words.append(0)

    words.append(
      encodeLoad64(register: 16, base: 19, byteOffset: Self.readTLBHitCounterOffset))
    words.append(encodeLoad64(register: 14, base: 16, byteOffset: 0))
    words.append(encodeAddImmediate64(left: 14, immediate: 1, destination: 14))
    words.append(encodeStore64(register: 14, base: 16, byteOffset: 0))
    words.append(encodeAdd(is64Bit: true, left: addressRegister, right: 17, destination: 13))
    words.append(encodeDirectLoad(width: width, register: resultRegister, base: 13))
    let hitDoneBranch = words.count
    words.append(0)

    let missStart = words.count
    words[missBranch] = encodeConditionalBranch(
      condition: .notEqual,
      wordOffset: missStart - missBranch
    )
    words.append(encodeLogical(.or, left: 31, right: 19, destination: 0))
    words.append(encodeLogical(.or, left: 31, right: 20, destination: 1))
    words.append(encodeMoveWideZero32(register: 2, immediate: 0))
    words.append(encodeLoad64(register: 3, base: 31, byteOffset: 88))
    words.append(encodeMoveWideZero32(register: 4, immediate: UInt16(byteCount)))
    words.append(encodeAddImmediate64(left: 31, immediate: 64, destination: 5))
    words.append(encodeLoad64(register: 16, base: 19, byteOffset: Self.tlbResolverOffset))
    words.append(0xD63F_0000 | 16 << 5)  // blr x16 (C TLB miss resolver)
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: false, 0, 31, 31))
    let resolverErrorBranch = words.count
    words.append(0)
    words.append(encodeLoad32(register: 13, base: 31, byteOffset: 84))
    words.append(encodeMoveWideZero32(register: 14, immediate: 2))
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: false, 13, 14, 31))
    let pageFaultBranch = words.count
    words.append(0)
    words.append(encodeMoveWideZero32(register: 14, immediate: 3))
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: false, 13, 14, 31))
    let resolverFallbackBranch = words.count
    words.append(0)
    words.append(encodeLoad64(register: 13, base: 31, byteOffset: 64))
    words.append(encodeLogical(.or, left: 31, right: 19, destination: 0))
    words.append(encodeDirectLoad(width: width, register: resultRegister, base: 13))
    let filledDoneBranch = words.count
    words.append(0)

    let pageFaultStart = words.count
    words[pageFaultBranch] = encodeConditionalBranch(
      condition: .equal,
      wordOffset: pageFaultStart - pageFaultBranch
    )
    // x30 is the exact generated return PC from the resolver BLR. Capture it only after
    // the C/Swift translation walk has returned and published the architectural fault.
    words.append(
      encodeStore64(register: 30, base: 19, byteOffset: Self.inlineTLBFaultHostPCOffset))
    emitMemoryEpilogue(into: &words)
    words.append(
      encodeMoveWideZero32(
        register: 0,
        immediate: UInt16(DoryJITExitCode.interpreter.rawValue)
      ))
    words.append(0xD65F_03C0)

    let callbackStart = words.count
    words[crossPageBranch] = encodeConditionalBranch(
      condition: .carrySet,
      wordOffset: callbackStart - crossPageBranch
    )
    words[missingTLBBranch] = encodeConditionalBranch(
      condition: .equal,
      wordOffset: callbackStart - missingTLBBranch
    )
    words[resolverErrorBranch] = encodeConditionalBranch(
      condition: .notEqual,
      wordOffset: callbackStart - resolverErrorBranch
    )
    words[resolverFallbackBranch] = encodeConditionalBranch(
      condition: .equal,
      wordOffset: callbackStart - resolverFallbackBranch
    )
    words.append(encodeLogical(.or, left: 31, right: 20, destination: 0))
    words.append(encodeLoad64(register: 1, base: 31, byteOffset: 88))
    words.append(encodeMoveWideZero32(register: 2, immediate: UInt16(byteCount)))
    words.append(0xD63F_0000 | 21 << 5)  // blr x21
    words.append(encodeLogical(.or, left: 31, right: 0, destination: resultRegister))
    words.append(encodeLogical(.or, left: 31, right: 19, destination: 0))

    let done = words.count
    words[hitDoneBranch] = encodeUnconditionalBranch(wordOffset: done - hitDoneBranch)
    words[filledDoneBranch] = encodeUnconditionalBranch(wordOffset: done - filledDoneBranch)
  }

  private func emitMemoryWrite(
    addressRegister: UInt32,
    valueRegister: UInt32,
    width: DoryIRIntegerWidth,
    words: inout [UInt32]
  ) {
    let byteCount = UInt32(width.rawValue / 8)
    words.append(encodeStore64(register: addressRegister, base: 31, byteOffset: 88))
    words.append(encodeStore64(register: valueRegister, base: 31, byteOffset: 96))
    // A scalar spanning two linear pages cannot use one direct-mapped entry.
    emitImmediate(0xfff, register: 13, into: &words)
    words.append(encodeLogical(.and, left: addressRegister, right: 13, destination: 13))
    emitImmediate(UInt64(4_097 - byteCount), register: 14, into: &words)
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: true, 13, 14, 31))
    let crossPageBranch = words.count
    words.append(0)

    // Build the same exact {canonical VPN, address-space generation} tag as the C resolver.
    words.append(
      encodeLogical(
        .or,
        left: 31,
        right: addressRegister,
        shiftAmount: 12,
        logicalRightShift: true,
        destination: 14
      ))
    words.append(
      encodeLogical(.or, left: 31, right: 14, shiftAmount: 28, destination: 14))
    words.append(
      encodeLoad64(
        register: 15,
        base: 19,
        byteOffset: Self.tlbAddressSpaceGenerationOffset
      ))
    words.append(encodeLogical(.or, left: 14, right: 15, destination: 14))
    words.append(
      encodeLogical(
        .or,
        left: 31,
        right: addressRegister,
        shiftAmount: 12,
        logicalRightShift: true,
        destination: 13
      ))
    words.append(
      encodeLoad64(register: 15, base: 19, byteOffset: Self.tlbEntryMaskOffset))
    words.append(encodeLogical(.and, left: 13, right: 15, destination: 13))
    words.append(encodeLoad64(register: 15, base: 19, byteOffset: Self.writeTLBBaseOffset))
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: true, 15, 31, 31))
    let missingTLBBranch = words.count
    words.append(0)
    words.append(encodeAdd(is64Bit: true, left: 15, right: 13, leftShift: 4, destination: 15))
    words.append(encodeLoad64(register: 16, base: 15, byteOffset: 0))
    words.append(encodeLoad64(register: 17, base: 15, byteOffset: 8))
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: true, 16, 14, 31))
    let missBranch = words.count
    words.append(0)

    words.append(
      encodeLoad64(register: 16, base: 19, byteOffset: Self.writeTLBHitCounterOffset))
    words.append(encodeLoad64(register: 14, base: 16, byteOffset: 0))
    words.append(encodeAddImmediate64(left: 14, immediate: 1, destination: 14))
    words.append(encodeStore64(register: 14, base: 16, byteOffset: 0))
    words.append(encodeAdd(is64Bit: true, left: addressRegister, right: 17, destination: 13))
    words.append(encodeLoad64(register: 14, base: 31, byteOffset: 96))
    words.append(encodeDirectStore(width: width, register: 14, base: 13))
    let hitDoneBranch = words.count
    words.append(0)

    let missStart = words.count
    words[missBranch] = encodeConditionalBranch(
      condition: .notEqual,
      wordOffset: missStart - missBranch
    )
    words.append(encodeLogical(.or, left: 31, right: 19, destination: 0))
    words.append(encodeLogical(.or, left: 31, right: 20, destination: 1))
    words.append(encodeMoveWideZero32(register: 2, immediate: 1))
    words.append(encodeLoad64(register: 3, base: 31, byteOffset: 88))
    words.append(encodeMoveWideZero32(register: 4, immediate: UInt16(byteCount)))
    words.append(encodeAddImmediate64(left: 31, immediate: 64, destination: 5))
    words.append(encodeLoad64(register: 16, base: 19, byteOffset: Self.tlbResolverOffset))
    words.append(0xD63F_0000 | 16 << 5)  // blr x16 (C TLB miss resolver)
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: false, 0, 31, 31))
    let resolverErrorBranch = words.count
    words.append(0)
    words.append(encodeLoad32(register: 13, base: 31, byteOffset: 84))
    words.append(encodeMoveWideZero32(register: 14, immediate: 2))
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: false, 13, 14, 31))
    let pageFaultBranch = words.count
    words.append(0)
    words.append(encodeMoveWideZero32(register: 14, immediate: 3))
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: false, 13, 14, 31))
    let resolverFallbackBranch = words.count
    words.append(0)
    words.append(encodeLoad64(register: 13, base: 31, byteOffset: 64))
    words.append(encodeLoad64(register: 14, base: 31, byteOffset: 96))
    words.append(encodeDirectStore(width: width, register: 14, base: 13))
    words.append(encodeLogical(.or, left: 31, right: 19, destination: 0))
    let filledDoneBranch = words.count
    words.append(0)

    let pageFaultStart = words.count
    words[pageFaultBranch] = encodeConditionalBranch(
      condition: .equal,
      wordOffset: pageFaultStart - pageFaultBranch
    )
    words.append(
      encodeStore64(register: 30, base: 19, byteOffset: Self.inlineTLBFaultHostPCOffset))
    emitMemoryEpilogue(into: &words)
    words.append(
      encodeMoveWideZero32(
        register: 0,
        immediate: UInt16(DoryJITExitCode.interpreter.rawValue)
      ))
    words.append(0xD65F_03C0)

    let callbackStart = words.count
    words[crossPageBranch] = encodeConditionalBranch(
      condition: .carrySet,
      wordOffset: callbackStart - crossPageBranch
    )
    words[missingTLBBranch] = encodeConditionalBranch(
      condition: .equal,
      wordOffset: callbackStart - missingTLBBranch
    )
    words[resolverErrorBranch] = encodeConditionalBranch(
      condition: .notEqual,
      wordOffset: callbackStart - resolverErrorBranch
    )
    words[resolverFallbackBranch] = encodeConditionalBranch(
      condition: .equal,
      wordOffset: callbackStart - resolverFallbackBranch
    )
    words.append(encodeLogical(.or, left: 31, right: 20, destination: 0))
    words.append(encodeLoad64(register: 1, base: 31, byteOffset: 88))
    words.append(encodeLoad64(register: 2, base: 31, byteOffset: 96))
    words.append(encodeMoveWideZero32(register: 3, immediate: UInt16(byteCount)))
    words.append(0xD63F_0000 | 22 << 5)  // blr x22
    words.append(encodeLogical(.or, left: 31, right: 19, destination: 0))

    let done = words.count
    words[hitDoneBranch] = encodeUnconditionalBranch(wordOffset: done - hitDoneBranch)
    words[filledDoneBranch] = encodeUnconditionalBranch(wordOffset: done - filledDoneBranch)
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
    words.append(encodeStore64(register: desiredRegister, base: 31, byteOffset: 72))
    words.append(encodeStore64(register: addressRegister, base: 31, byteOffset: 88))
    words.append(
      encodeLoad64(register: 16, base: 19, byteOffset: Self.atomicCompareExchangeOffset))
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: true, 16, 31, 31))
    let missingDirectHelperBranch = words.count
    words.append(0)
    words.append(encodeLogical(.or, left: 31, right: 19, destination: 0))
    words.append(encodeLogical(.or, left: 31, right: 20, destination: 1))
    words.append(encodeLoad64(register: 2, base: 31, byteOffset: 88))
    words.append(encodeLoad64(register: 3, base: 31, byteOffset: 64))
    words.append(encodeLoad64(register: 4, base: 31, byteOffset: 72))
    words.append(encodeMoveWideZero32(register: 5, immediate: UInt16(width.rawValue / 8)))
    words.append(encodeAddImmediate64(left: 31, immediate: 80, destination: 6))
    words.append(0xD63F_0000 | 16 << 5)  // blr x16 (C translated atomic helper)
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: false, 0, 31, 31))
    let directSuccessBranch = words.count
    words.append(0)
    words.append(encodeMoveWideZero32(register: 13, immediate: 1))
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: false, 0, 13, 31))
    let directPageFaultBranch = words.count
    words.append(0)

    let callbackStart = words.count
    words[missingDirectHelperBranch] = encodeConditionalBranch(
      condition: .equal,
      wordOffset: callbackStart - missingDirectHelperBranch
    )
    words.append(encodeLogical(.or, left: 31, right: 20, destination: 0))
    words.append(encodeLoad64(register: 1, base: 31, byteOffset: 88))
    words.append(encodeLoad64(register: 2, base: 31, byteOffset: 64))
    words.append(encodeLoad64(register: 3, base: 31, byteOffset: 72))
    words.append(encodeMoveWideZero32(register: 4, immediate: UInt16(width.rawValue / 8)))
    words.append(encodeAddImmediate64(left: 31, immediate: 80, destination: 5))
    words.append(0xD63F_0000 | 23 << 5)  // blr x23
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: false, 0, 31, 31))
    emitInterpreterUnless(condition: .notEqual, usesMemory: true, into: &words)

    let successStart = words.count
    words[directSuccessBranch] = encodeConditionalBranch(
      condition: .equal,
      wordOffset: successStart - directSuccessBranch
    )
    words.append(encodeLoad64(register: expectedRegister, base: 31, byteOffset: 64))
    words.append(encodeLoad64(register: observedRegister, base: 31, byteOffset: 80))
    words.append(encodeLogical(.or, left: 31, right: 19, destination: 0))
    let successDoneBranch = words.count
    words.append(0)

    let pageFaultStart = words.count
    words[directPageFaultBranch] = encodeConditionalBranch(
      condition: .equal,
      wordOffset: pageFaultStart - directPageFaultBranch
    )
    // The direct helper has classified this return as an architectural #PF. x30 is the
    // generated BLR continuation, so the side table can restore this atomic instruction's
    // entry checkpoint without treating fallback/error returns as recoverable faults.
    words.append(
      encodeStore64(register: 30, base: 19, byteOffset: Self.inlineTLBFaultHostPCOffset))
    emitMemoryEpilogue(into: &words)
    words.append(
      encodeMoveWideZero32(
        register: 0,
        immediate: UInt16(DoryJITExitCode.interpreter.rawValue)
      ))
    words.append(0xD65F_03C0)

    words[successDoneBranch] = encodeUnconditionalBranch(
      wordOffset: words.count - successDoneBranch)
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

  private func emitCompareExchangePair(
    destination: DoryIROperand,
    doubleQuadword: Bool,
    into words: inout [UInt32]
  ) -> Bool {
    guard case .memory(let address, let width) = destination,
      width == (doubleQuadword ? .i64 : .i32),
      emitMemoryAddress(address, into: 13, words: &words)
    else { return false }
    words.append(
      doubleQuadword
        ? encodeLoad64(register: 9, base: 0, byteOffset: 0)
        : encodeLoad32(register: 9, base: 0, byteOffset: 0))  // RAX/EAX: expected low
    words.append(
      doubleQuadword
        ? encodeLoad64(register: 10, base: 0, byteOffset: 16)
        : encodeLoad32(register: 10, base: 0, byteOffset: 16))  // RDX/EDX: expected high
    words.append(
      doubleQuadword
        ? encodeLoad64(register: 11, base: 0, byteOffset: 24)
        : encodeLoad32(register: 11, base: 0, byteOffset: 24))  // RBX/EBX: desired low
    words.append(
      doubleQuadword
        ? encodeLoad64(register: 12, base: 0, byteOffset: 8)
        : encodeLoad32(register: 12, base: 0, byteOffset: 8))  // RCX/ECX: desired high
    words.append(encodeStore64(register: 9, base: 31, byteOffset: 64))
    words.append(encodeStore64(register: 10, base: 31, byteOffset: 72))
    words.append(encodeStore64(register: 11, base: 31, byteOffset: 80))
    words.append(encodeStore64(register: 12, base: 31, byteOffset: 88))

    words.append(
      encodeLoad64(register: 16, base: 19, byteOffset: Self.atomicCompareExchangePairOffset))
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: true, 16, 31, 31))
    emitInterpreterUnless(condition: .notEqual, usesMemory: true, into: &words)
    words.append(encodeLogical(.or, left: 31, right: 19, destination: 0))
    words.append(encodeLogical(.or, left: 31, right: 20, destination: 1))
    words.append(encodeLogical(.or, left: 31, right: 13, destination: 2))
    words.append(encodeMoveWideZero32(register: 3, immediate: doubleQuadword ? 16 : 8))
    words.append(encodeAddImmediate64(left: 31, immediate: 64, destination: 4))
    words.append(0xD63F_0000 | 16 << 5)  // blr x16 (C translated pair compare-exchange)
    emitAtomicResolutionUnlessSuccess(into: &words)

    words.append(encodeLogical(.or, left: 31, right: 19, destination: 0))
    words.append(encodeLoad64(register: 9, base: 31, byteOffset: 64))
    words.append(encodeLoad64(register: 10, base: 31, byteOffset: 72))
    words.append(encodeLoad64(register: 11, base: 31, byteOffset: 96))
    words.append(encodeLoad64(register: 12, base: 31, byteOffset: 104))
    words.append(encodeLogical(.xor, left: 9, right: 11, destination: 13))
    words.append(encodeLogical(.xor, left: 10, right: 12, destination: 14))
    words.append(encodeLogical(.or, left: 13, right: 14, destination: 13))
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: true, 13, 31, 31))

    words.append(encodeLoad64(register: 14, base: 0, byteOffset: 0))
    words.append(
      encodeConditionalSelect(
        destination: 9,
        trueRegister: 14,
        falseRegister: 11,
        condition: .equal
      ))
    words.append(encodeStore64(register: 9, base: 0, byteOffset: 0))
    words.append(encodeLoad64(register: 14, base: 0, byteOffset: 16))
    words.append(
      encodeConditionalSelect(
        destination: 10,
        trueRegister: 14,
        falseRegister: 12,
        condition: .equal
      ))
    words.append(encodeStore64(register: 10, base: 0, byteOffset: 16))

    words.append(encodeConditionalSet(register: 13, condition: .equal))
    words.append(encodeLoad64(register: 14, base: 0, byteOffset: Self.rflagsOffset))
    emitImmediate(~DoryX86RFLAGS.zero.rawValue, register: 15, into: &words)
    words.append(encodeLogical(.and, left: 14, right: 15, destination: 14))
    words.append(encodeLogical(.or, left: 14, right: 13, shiftAmount: 6, destination: 14))
    emitImmediate(DoryX86RFLAGS.reservedOne.rawValue, register: 15, into: &words)
    words.append(encodeLogical(.or, left: 14, right: 15, destination: 14))
    words.append(encodeStore64(register: 14, base: 0, byteOffset: Self.rflagsOffset))
    return true
  }

  private func emitExchangeMemory(
    destination: DoryIROperand,
    source: DoryIRRegister,
    into words: inout [UInt32]
  ) -> Bool {
    guard case .memory(let address, let width) = destination,
      width == .i32 || width == .i64,
      source.bank == "x86.gpr", source.index < 16, source.width == width,
      emitMemoryAddress(address, into: 12, words: &words),
      load(source, into: 10, words: &words)
    else { return false }

    words.append(encodeStore64(register: 10, base: 31, byteOffset: 64))
    words.append(encodeStore64(register: 12, base: 31, byteOffset: 88))
    words.append(encodeLoad64(register: 16, base: 19, byteOffset: Self.atomicExchangeOffset))
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: true, 16, 31, 31))
    emitInterpreterUnless(condition: .notEqual, usesMemory: true, into: &words)
    words.append(encodeLogical(.or, left: 31, right: 19, destination: 0))
    words.append(encodeLogical(.or, left: 31, right: 20, destination: 1))
    words.append(encodeLoad64(register: 2, base: 31, byteOffset: 88))
    words.append(encodeLoad64(register: 3, base: 31, byteOffset: 64))
    words.append(encodeMoveWideZero32(register: 4, immediate: UInt16(width.rawValue / 8)))
    words.append(encodeAddImmediate64(left: 31, immediate: 80, destination: 5))
    words.append(0xD63F_0000 | 16 << 5)  // blr x16 (C translated atomic exchange)
    emitAtomicResolutionUnlessSuccess(into: &words)
    words.append(encodeLoad64(register: 10, base: 31, byteOffset: 80))
    words.append(encodeStore64(register: 10, base: 19, byteOffset: Int(source.index) * 8))
    words.append(encodeLogical(.or, left: 31, right: 19, destination: 0))
    return true
  }

  private func emitExchangeAddMemory(
    destination: DoryIROperand,
    source: DoryIRRegister,
    into words: inout [UInt32]
  ) -> Bool {
    guard case .memory(let address, let width) = destination,
      width == .i32 || width == .i64,
      source.bank == "x86.gpr", source.index < 16, source.width == width,
      emitMemoryAddress(address, into: 12, words: &words),
      load(source, into: 10, words: &words)
    else { return false }

    words.append(encodeStore64(register: 10, base: 31, byteOffset: 64))
    words.append(encodeStore64(register: 12, base: 31, byteOffset: 88))
    words.append(encodeLoad64(register: 16, base: 19, byteOffset: Self.atomicFetchAddOffset))
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: true, 16, 31, 31))
    emitInterpreterUnless(condition: .notEqual, usesMemory: true, into: &words)
    words.append(encodeLogical(.or, left: 31, right: 19, destination: 0))
    words.append(encodeLogical(.or, left: 31, right: 20, destination: 1))
    words.append(encodeLoad64(register: 2, base: 31, byteOffset: 88))
    words.append(encodeLoad64(register: 3, base: 31, byteOffset: 64))
    words.append(encodeMoveWideZero32(register: 4, immediate: UInt16(width.rawValue / 8)))
    words.append(encodeAddImmediate64(left: 31, immediate: 80, destination: 5))
    words.append(0xD63F_0000 | 16 << 5)  // blr x16 (C translated atomic fetch-add)
    emitAtomicResolutionUnlessSuccess(into: &words)

    words.append(encodeLogical(.or, left: 31, right: 19, destination: 0))
    words.append(encodeLoad64(register: 9, base: 31, byteOffset: 80))
    words.append(encodeLoad64(register: 10, base: 31, byteOffset: 64))
    words.append(
      encodeAddSubtractSetFlags(
        add: true,
        is64Bit: width == .i64,
        9,
        10,
        11
      ))
    emitX86ArithmeticFlags(
      subtraction: false,
      includesAuxiliaryCarry: true,
      resultRegister: 11,
      into: &words
    )
    words.append(encodeStore64(register: 9, base: 19, byteOffset: Int(source.index) * 8))
    return true
  }

  private func emitAtomicBinary(
    _ operation: DoryIRBinaryOperation,
    destination: DoryIROperand,
    source: DoryIROperand,
    into words: inout [UInt32]
  ) -> Bool {
    let operationCode: UInt16
    switch operation {
    case .add, .addWithCarry: operationCode = 0
    case .subtract, .subtractWithBorrow: operationCode = 1
    case .and: operationCode = 2
    case .or: operationCode = 3
    case .xor: operationCode = 4
    default: return false
    }
    guard case .memory(let address, let width) = destination,
      width == .i32 || width == .i64,
      emitMemoryAddress(address, into: 12, words: &words),
      load(source, matching: width, into: 10, words: &words)
    else { return false }

    words.append(encodeStore64(register: 10, base: 31, byteOffset: 64))
    let usesCarryInput = operation == .addWithCarry || operation == .subtractWithBorrow
    let atomicValueOffset: Int
    if usesCarryInput {
      words.append(encodeLoad64(register: 11, base: 0, byteOffset: Self.rflagsOffset))
      emitImmediate(1, register: 15, into: &words)
      words.append(encodeLogical(.and, left: 11, right: 15, destination: 11))
      words.append(
        encodeAdd(
          is64Bit: width == .i64,
          left: 10,
          right: 11,
          destination: 11
        ))
      words.append(encodeStore64(register: 11, base: 31, byteOffset: 72))
      atomicValueOffset = 72
    } else {
      atomicValueOffset = 64
    }
    words.append(encodeStore64(register: 12, base: 31, byteOffset: 88))
    words.append(encodeLoad64(register: 16, base: 19, byteOffset: Self.atomicRMWOffset))
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: true, 16, 31, 31))
    emitInterpreterUnless(condition: .notEqual, usesMemory: true, into: &words)
    words.append(encodeLogical(.or, left: 31, right: 19, destination: 0))
    words.append(encodeLogical(.or, left: 31, right: 20, destination: 1))
    words.append(encodeLoad64(register: 2, base: 31, byteOffset: 88))
    words.append(encodeLoad64(register: 3, base: 31, byteOffset: atomicValueOffset))
    words.append(encodeMoveWideZero32(register: 4, immediate: UInt16(width.rawValue / 8)))
    words.append(encodeMoveWideZero32(register: 5, immediate: operationCode))
    words.append(encodeAddImmediate64(left: 31, immediate: 80, destination: 6))
    words.append(0xD63F_0000 | 16 << 5)  // blr x16 (C translated atomic RMW)
    emitAtomicResolutionUnlessSuccess(into: &words)

    words.append(encodeLogical(.or, left: 31, right: 19, destination: 0))
    words.append(encodeLoad64(register: 9, base: 31, byteOffset: 80))
    words.append(encodeLoad64(register: 10, base: 31, byteOffset: 64))
    let is64Bit = width == .i64
    switch operation {
    case .add:
      words.append(encodeAddSubtractSetFlags(add: true, is64Bit: is64Bit, 9, 10, 11))
    case .addWithCarry:
      emitARMCarryFromX86(inverted: false, into: &words)
      words.append(
        encodeAddSubtractCarrySetFlags(
          add: true,
          is64Bit: is64Bit,
          9,
          10,
          11
        ))
    case .subtract:
      words.append(encodeAddSubtractSetFlags(add: false, is64Bit: is64Bit, 9, 10, 11))
    case .subtractWithBorrow:
      emitARMCarryFromX86(inverted: true, into: &words)
      words.append(
        encodeAddSubtractCarrySetFlags(
          add: false,
          is64Bit: is64Bit,
          9,
          10,
          11
        ))
    case .and:
      words.append(encodeLogical(.andSetFlags, is64Bit: is64Bit, 9, 10, 11))
    case .or, .xor:
      words.append(
        encodeLogical(
          operation == .or ? .or : .xor,
          is64Bit: is64Bit,
          9,
          10,
          11
        ))
      words.append(encodeLogical(.andSetFlags, is64Bit: is64Bit, 11, 11, 31))
    default:
      return false
    }
    emitX86ArithmeticFlags(
      subtraction: operation == .subtract || operation == .subtractWithBorrow,
      includesAuxiliaryCarry: operation == .add || operation == .addWithCarry
        || operation == .subtract || operation == .subtractWithBorrow,
      resultRegister: 11,
      into: &words
    )
    return true
  }

  private func emitAtomicUnary(
    _ operation: DoryIRUnaryOperation,
    operand: DoryIROperand,
    into words: inout [UInt32]
  ) -> Bool {
    let operationCode: UInt16
    let value: UInt64
    switch operation {
    case .increment:
      operationCode = 0
      value = 1
    case .decrement:
      operationCode = 1
      value = 1
    case .bitwiseNot:
      operationCode = 4
      guard case .memory(_, let width) = operand else { return false }
      value = width == .i32 ? 0xFFFF_FFFF : UInt64.max
    case .negate:
      operationCode = 5
      value = 0
    }
    guard case .memory(let address, let width) = operand,
      width == .i32 || width == .i64,
      emitMemoryAddress(address, into: 12, words: &words)
    else { return false }

    emitImmediate(value, register: 10, into: &words)
    words.append(encodeStore64(register: 10, base: 31, byteOffset: 64))
    words.append(encodeStore64(register: 12, base: 31, byteOffset: 88))
    words.append(encodeLoad64(register: 16, base: 19, byteOffset: Self.atomicRMWOffset))
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: true, 16, 31, 31))
    emitInterpreterUnless(condition: .notEqual, usesMemory: true, into: &words)
    words.append(encodeLogical(.or, left: 31, right: 19, destination: 0))
    words.append(encodeLogical(.or, left: 31, right: 20, destination: 1))
    words.append(encodeLoad64(register: 2, base: 31, byteOffset: 88))
    words.append(encodeLoad64(register: 3, base: 31, byteOffset: 64))
    words.append(encodeMoveWideZero32(register: 4, immediate: UInt16(width.rawValue / 8)))
    words.append(encodeMoveWideZero32(register: 5, immediate: operationCode))
    words.append(encodeAddImmediate64(left: 31, immediate: 80, destination: 6))
    words.append(0xD63F_0000 | 16 << 5)  // blr x16 (C translated atomic RMW)
    emitAtomicResolutionUnlessSuccess(into: &words)
    words.append(encodeLogical(.or, left: 31, right: 19, destination: 0))

    if operation == .bitwiseNot { return true }
    words.append(encodeLoad64(register: 9, base: 31, byteOffset: 80))
    let is64Bit = width == .i64
    if operation == .negate {
      words.append(encodeLogical(.or, left: 31, right: 9, destination: 10))
      emitImmediate(0, register: 9, into: &words)
      words.append(encodeAddSubtractSetFlags(add: false, is64Bit: is64Bit, 9, 10, 11))
    } else {
      emitImmediate(1, register: 10, into: &words)
      words.append(
        encodeAddSubtractSetFlags(
          add: operation == .increment,
          is64Bit: is64Bit,
          9,
          10,
          11
        ))
    }
    emitX86ArithmeticFlags(
      subtraction: operation != .increment,
      includesAuxiliaryCarry: true,
      updatesCarry: operation == .negate,
      resultRegister: 11,
      into: &words
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
    if case .register(let target) = destination,
      target.bank == "x86.high8", target.index < 4, target.width == .i8,
      ((operation == .and || operation == .or) && writesDestination)
        || (operation == .test && !writesDestination),
      case .immediate(let immediate, width: .i8) = source
    {
      words.append(encodeLoad64(register: 9, base: 0, byteOffset: Int(target.index) * 8))
      words.append(
        encodeLogical(
          .or, left: 31, right: 9, shiftAmount: 8,
          logicalRightShift: true, destination: 9))
      emitImmediate(0xFF, register: 15, into: &words)
      words.append(encodeLogical(.and, left: 9, right: 15, destination: 9))
      emitImmediate(immediate & 0xFF, register: 10, into: &words)
      guard emitNarrowBinaryFlags(operation, writesDestination: writesDestination, into: &words)
      else {
        return false
      }
      if !writesDestination { return true }
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
        || (writesDestination && (operation == .and || operation == .or))
    {
      return emitLowByteBinary(
        operation,
        destination: target,
        source: source,
        writesDestination: writesDestination,
        into: &words
      )
    }
    if case .register(let target) = destination,
      target.bank == "x86.gpr", target.index < 16, target.width == .i16,
      operation == .compare, !writesDestination
    {
      switch source {
      case .register(let register)
      where register.bank == "x86.gpr" && register.index < 16 && register.width == .i16:
        words.append(encodeLoad64(register: 10, base: 0, byteOffset: Int(register.index) * 8))
      case .immediate(let immediate, width: .i16):
        emitImmediate(immediate & 0xFFFF, register: 10, into: &words)
      case .memory(let address, width: .i16):
        guard emitMemoryAddress(address, into: 12, words: &words) else { return false }
        emitMemoryRead(addressRegister: 12, width: .i16, resultRegister: 10, words: &words)
      default:
        return false
      }
      words.append(encodeLoad64(register: 9, base: 0, byteOffset: Int(target.index) * 8))
      emitImmediate(0xFFFF, register: 15, into: &words)
      words.append(encodeLogical(.and, left: 9, right: 15, destination: 9))
      words.append(encodeLogical(.and, left: 10, right: 15, destination: 10))
      return emitNarrowBinaryFlags(.compare, writesDestination: false, width: .i16, into: &words)
    }
    if case .memory(let address, width: .i16) = destination,
      (!writesDestination && operation == .compare)
        || (writesDestination && (operation == .add || operation == .subtract))
    {
      guard emitMemoryAddress(address, into: 12, words: &words) else { return false }
      emitMemoryRead(addressRegister: 12, width: .i16, resultRegister: 9, words: &words)
      switch source {
      case .immediate(let immediate, width: .i16):
        emitImmediate(immediate & 0xFFFF, register: 10, into: &words)
      case .register(let register)
      where register.bank == "x86.gpr" && register.index < 16 && register.width == .i16:
        words.append(encodeLoad64(register: 10, base: 0, byteOffset: Int(register.index) * 8))
        emitImmediate(0xFFFF, register: 15, into: &words)
        words.append(encodeLogical(.and, left: 10, right: 15, destination: 10))
      default:
        return false
      }
      guard
        emitNarrowBinaryFlags(
          operation, writesDestination: writesDestination,
          width: .i16, into: &words)
      else { return false }
      if writesDestination {
        guard emitMemoryAddress(address, into: 12, words: &words) else { return false }
        emitMemoryWrite(addressRegister: 12, valueRegister: 11, width: .i16, words: &words)
      }
      return true
    }
    if case .register(let target) = destination,
      target.bank == "x86.gpr", target.index < 16, target.width == .i16,
      operation == .or || operation == .and, writesDestination
    {
      return emitWordRegisterLogical(operation, destination: target, source: source, into: &words)
    }
    if case .memory(let address, width: .i8) = destination,
      writesDestination,
      operation == .and || operation == .or
    {
      return emitLowByteMemoryLogical(
        operation,
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

  private func emitWordRegisterLogical(
    _ operation: DoryIRBinaryOperation,
    destination: DoryIRRegister,
    source: DoryIROperand,
    into words: inout [UInt32]
  ) -> Bool {
    guard destination.bank == "x86.gpr", destination.index < 16, destination.width == .i16
    else { return false }
    switch source {
    case .memory(let address, width: .i16):
      guard emitMemoryAddress(address, into: 12, words: &words) else { return false }
      emitMemoryRead(addressRegister: 12, width: .i16, resultRegister: 10, words: &words)
    case .immediate(let value, width: .i16):
      emitImmediate(value & 0xFFFF, register: 10, into: &words)
    default:
      return false
    }
    words.append(encodeLoad64(register: 9, base: 0, byteOffset: Int(destination.index) * 8))
    emitImmediate(0xFFFF, register: 15, into: &words)
    words.append(encodeLogical(.and, left: 9, right: 15, destination: 9))
    guard emitNarrowBinaryFlags(operation, writesDestination: true, width: .i16, into: &words)
    else {
      return false
    }
    words.append(encodeLoad64(register: 9, base: 0, byteOffset: Int(destination.index) * 8))
    emitImmediate(~UInt64(0xFFFF), register: 10, into: &words)
    words.append(encodeLogical(.and, left: 9, right: 10, destination: 9))
    words.append(encodeLogical(.or, left: 9, right: 11, destination: 9))
    words.append(encodeStore64(register: 9, base: 0, byteOffset: Int(destination.index) * 8))
    return true
  }

  private func emitExchangeRegisters(
    lhs: DoryIRRegister,
    rhs: DoryIRRegister,
    into words: inout [UInt32]
  ) -> Bool {
    guard lhs.bank == "x86.gpr", rhs.bank == "x86.gpr",
      lhs.index < 16, rhs.index < 16, lhs.width == rhs.width,
      lhs.width == .i32 || lhs.width == .i64
    else { return false }
    let is64Bit = lhs.width == .i64
    words.append(
      is64Bit
        ? encodeLoad64(register: 9, base: 0, byteOffset: Int(lhs.index) * 8)
        : encodeLoad32(register: 9, base: 0, byteOffset: Int(lhs.index) * 8))
    words.append(
      is64Bit
        ? encodeLoad64(register: 10, base: 0, byteOffset: Int(rhs.index) * 8)
        : encodeLoad32(register: 10, base: 0, byteOffset: Int(rhs.index) * 8))
    words.append(encodeStore64(register: 10, base: 0, byteOffset: Int(lhs.index) * 8))
    words.append(encodeStore64(register: 9, base: 0, byteOffset: Int(rhs.index) * 8))
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
      guard
        (!writesDestination && (operation == .compare || operation == .test))
          || (writesDestination && operation == .and),
        emitMemoryAddress(address, into: 12, words: &words)
      else { return false }
      emitMemoryRead(addressRegister: 12, width: .i8, resultRegister: 10, words: &words)
      guard loadLowByteRegister(destination, into: 9, words: &words) else { return false }
    } else {
      guard loadLowByteRegister(destination, into: 9, words: &words),
        loadLowByteOperand(source, into: 10, words: &words)
      else { return false }
    }

    guard
      emitNarrowBinaryFlags(
        operation,
        writesDestination: writesDestination,
        into: &words
      )
    else { return false }
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

  private func emitLowByteMemoryLogical(
    _ operation: DoryIRBinaryOperation,
    address: DoryIRMemoryAddress,
    source: DoryIROperand,
    into words: inout [UInt32]
  ) -> Bool {
    guard emitMemoryAddress(address, into: 12, words: &words) else { return false }
    emitMemoryRead(addressRegister: 12, width: .i8, resultRegister: 9, words: &words)
    guard loadLowByteOperand(source, into: 10, words: &words),
      emitNarrowBinaryFlags(
        operation,
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
    return emitNarrowBinaryFlags(
      operation,
      writesDestination: false,
      into: &words
    )
  }

  private func emitNarrowBinaryFlags(
    _ operation: DoryIRBinaryOperation,
    writesDestination: Bool,
    width: DoryIRIntegerWidth = .i8,
    into words: inout [UInt32]
  ) -> Bool {
    guard width == .i8 || width == .i16 else { return false }
    let signShift: UInt32 = width == .i8 ? 24 : 16
    // Put the x86 sign bit at the ARM32 sign position before setting NZCV. This makes C, Z, N,
    // and V describe an exact eight- or sixteen-bit operation. The unshifted operands and result remain in
    // x9, x10, and x11 so the shared x86 auxiliary-carry and parity synthesis stays exact.
    words.append(
      encodeLogical(
        .or,
        is64Bit: false,
        left: 31,
        right: 9,
        shiftAmount: signShift,
        destination: 12
      ))
    words.append(
      encodeLogical(
        .or,
        is64Bit: false,
        left: 31,
        right: 10,
        shiftAmount: signShift,
        destination: 13
      ))
    switch operation {
    case .compare, .subtract:
      guard writesDestination == (operation == .subtract) else { return false }
      words.append(encodeAddSubtractSetFlags(add: false, is64Bit: false, 12, 13, 11))
    case .add:
      guard writesDestination else { return false }
      words.append(encodeAddSubtractSetFlags(add: true, is64Bit: false, 12, 13, 11))
    case .and, .test:
      guard writesDestination == (operation == .and) else { return false }
      words.append(encodeLogical(.andSetFlags, is64Bit: false, 12, 13, 11))
    case .or:
      guard writesDestination else { return false }
      words.append(encodeLogical(.or, is64Bit: false, 12, 13, 11))
      words.append(encodeLogical(.andSetFlags, is64Bit: false, 11, 11, 31))
    default:
      return false
    }
    words.append(
      encodeLogical(
        .or,
        is64Bit: false,
        left: 31,
        right: 11,
        shiftAmount: signShift,
        logicalRightShift: true,
        destination: 11
      ))
    emitX86ArithmeticFlags(
      subtraction: operation == .compare || operation == .subtract,
      includesAuxiliaryCarry: operation == .compare || operation == .subtract || operation == .add,
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

  private func emitNarrowBitwiseNot(_ target: DoryIRRegister, into words: inout [UInt32]) -> Bool {
    guard target.bank == "x86.gpr", target.index < 16,
      target.width == .i8 || target.width == .i16
    else { return false }
    let mask: UInt64 = target.width == .i8 ? 0xFF : 0xFFFF
    words.append(encodeLoad64(register: 9, base: 0, byteOffset: Int(target.index) * 8))
    emitImmediate(mask, register: 10, into: &words)
    words.append(encodeLogical(.xor, left: 9, right: 10, destination: 11))
    words.append(encodeLoad64(register: 9, base: 0, byteOffset: Int(target.index) * 8))
    emitImmediate(~mask, register: 10, into: &words)
    words.append(encodeLogical(.and, left: 9, right: 10, destination: 9))
    words.append(encodeLogical(.or, left: 9, right: 11, destination: 9))
    words.append(encodeStore64(register: 9, base: 0, byteOffset: Int(target.index) * 8))
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
    if case .register(let target) = operand, operation == .bitwiseNot,
      target.bank == "x86.gpr", target.index < 16,
      target.width == .i8 || target.width == .i16
    {
      return emitNarrowBitwiseNot(target, into: &words)
    }
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
      emitShadowReturnStackPush(returnAddress: returnAddress, into: &words)
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
      emitShadowReturnStackPush(returnAddress: returnAddress, into: &words)
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
    words.append(
      encodeMoveWideZero32(register: 0, immediate: UInt16(DoryJITExitCode.interpreter.rawValue)))
    words.append(0xD65F_03C0)
    words[accepted] = encodeConditionalBranch(
      condition: condition, wordOffset: words.count - accepted)
  }

  /// Direct atomic helpers return a typed status. Only an architectural page fault owns a
  /// recoverable generated PC; fallback and internal error exits must not enter the side table.
  private func emitAtomicResolutionUnlessSuccess(into words: inout [UInt32]) {
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: false, 0, 31, 31))
    let successBranch = words.count
    words.append(0)
    words.append(encodeMoveWideZero32(register: 13, immediate: 1))
    words.append(encodeAddSubtractSetFlags(add: false, is64Bit: false, 0, 13, 31))
    let pageFaultBranch = words.count
    words.append(0)

    emitMemoryEpilogue(into: &words)
    words.append(
      encodeMoveWideZero32(register: 0, immediate: UInt16(DoryJITExitCode.interpreter.rawValue)))
    words.append(0xD65F_03C0)

    let pageFaultStart = words.count
    words.append(
      encodeStore64(register: 30, base: 19, byteOffset: Self.inlineTLBFaultHostPCOffset))
    emitMemoryEpilogue(into: &words)
    words.append(
      encodeMoveWideZero32(register: 0, immediate: UInt16(DoryJITExitCode.interpreter.rawValue)))
    words.append(0xD65F_03C0)

    let successStart = words.count
    words[successBranch] = encodeConditionalBranch(
      condition: .equal, wordOffset: successStart - successBranch)
    words[pageFaultBranch] = encodeConditionalBranch(
      condition: .equal, wordOffset: pageFaultStart - pageFaultBranch)
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

  private func encodeLoad8(register: UInt32, base: UInt32, byteOffset: Int) -> UInt32 {
    0x3940_0000 | UInt32(byteOffset) << 10 | base << 5 | register
  }

  private func encodeLoad32(register: UInt32, base: UInt32, byteOffset: Int) -> UInt32 {
    0xB940_0000 | UInt32(byteOffset / 4) << 10 | base << 5 | register
  }

  private func encodeStore64(register: UInt32, base: UInt32, byteOffset: Int) -> UInt32 {
    0xF900_0000 | UInt32(byteOffset / 8) << 10 | base << 5 | register
  }

  private func encodeDirectLoad(
    width: DoryIRIntegerWidth,
    register: UInt32,
    base: UInt32
  ) -> UInt32 {
    let opcode: UInt32 =
      switch width {
      case .i8: 0x3940_0000
      case .i16: 0x7940_0000
      case .i32: 0xB940_0000
      case .i64: 0xF940_0000
      }
    return opcode | base << 5 | register
  }

  private func encodeDirectStore(
    width: DoryIRIntegerWidth,
    register: UInt32,
    base: UInt32
  ) -> UInt32 {
    let opcode: UInt32 =
      switch width {
      case .i8: 0x3900_0000
      case .i16: 0x7900_0000
      case .i32: 0xB900_0000
      case .i64: 0xF900_0000
      }
    return opcode | base << 5 | register
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
      case (.rotateLeft, _), (.rotateRight, _):
        preconditionFailure("rotate uses immediate lowering")
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

  private func encodeCountLeadingZeros(is64Bit: Bool, source: UInt32, destination: UInt32) -> UInt32
  {
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

  private func encodeAccumulatorDivide(
    signed: Bool,
    is64Bit: Bool,
    dividend: UInt32,
    divisor: UInt32,
    quotient: UInt32
  ) -> UInt32 {
    (is64Bit ? 0x9AC0_0800 : 0x1AC0_0800) | (signed ? 0x400 : 0)
      | divisor << 16 | dividend << 5 | quotient
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

  private func encodeSubtractImmediate64(
    left: UInt32,
    immediate: UInt32,
    destination: UInt32
  ) -> UInt32 {
    precondition(immediate < 4096)
    return 0xD100_0000 | immediate << 10 | left << 5 | destination
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

  private func encodeCompareBranchZero64(register: UInt32, wordOffset: Int) -> UInt32 {
    precondition((-262_144..<262_144).contains(wordOffset))
    return 0xB400_0000 | (UInt32(truncatingIfNeeded: wordOffset) & 0x7_FFFF) << 5 | register
  }

  private func encodeCompareBranchNonZero32(register: UInt32, wordOffset: Int) -> UInt32 {
    precondition((-262_144..<262_144).contains(wordOffset))
    return 0x3500_0000 | (UInt32(truncatingIfNeeded: wordOffset) & 0x7_FFFF) << 5 | register
  }

  private func encodeUnconditionalBranch(wordOffset: Int) -> UInt32 {
    precondition((-33_554_432..<33_554_432).contains(wordOffset))
    return 0x1400_0000 | (UInt32(truncatingIfNeeded: wordOffset) & 0x03ff_ffff)
  }

  private func encodeBranch(register: UInt32) -> UInt32 {
    precondition(register < 32)
    return 0xD61F_0000 | register << 5
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
  case branchPatchFailed(Int32)
  case invalidOffset(Int)
  case invalidContextWordCount(Int)
  case executionFailed(Int32)
  case invalidExitCode(UInt32)
}

struct DoryJITMemoryCapabilities {
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

struct DoryJITMemoryCallbackContext {
  let capabilities: DoryJITMemoryCapabilities
  let requiresRestartableReads: Bool
  var executionContext: UnsafeMutableBufferPointer<UInt64>? = nil
  var translationTLB: DoryX86JITTLB?
  var failed = false
  var failedCallbackHostPC: UInt64?
  var failedExecutionContext: [UInt64]?
  var pageTableWriteObserved = false
}

private func doryJITRecordMemoryFailure(
  _ context: UnsafeMutablePointer<DoryJITMemoryCallbackContext>
) {
  guard !context.pointee.failed else { return }
  context.pointee.failed = true
  let returnPC = dory_jit_current_memory_callback_return_pc()
  context.pointee.failedCallbackHostPC = returnPC == 0 ? nil : UInt64(returnPC)
  context.pointee.failedExecutionContext = context.pointee.executionContext.map(Array.init)
}

private func doryJITInvalidatePageTableWrite(
  _ context: UnsafeMutablePointer<DoryJITMemoryCallbackContext>
) {
  guard !context.pointee.pageTableWriteObserved,
    let translatedMemory = context.pointee.capabilities.memory as? DoryX86TranslatedMemory,
    translatedMemory.hasPendingPageTableWrite
  else { return }
  translatedMemory.translationUnit.invalidateAll()
  context.pointee.translationTLB?.invalidateAll()
  context.pointee.pageTableWriteObserved = true
}

/// C-callable architectural translation boundary used only by the JIT TLB miss resolver.
/// Returning `FILLED` means the physical address was permission checked and may be cached;
/// page faults retain their exact linear address and error code for the native exit path.
@_cdecl("dory_x86_jit_translate")
func doryX86JITTranslate(
  _ opaque: UnsafeMutableRawPointer?,
  _ linearAddress: UInt64,
  _ rawAccess: UInt32,
  _ rawByteCount: UInt32,
  _ hostAddressSpaceOffsetOut: UnsafeMutablePointer<UInt64>?,
  _ faultAddressOut: UnsafeMutablePointer<UInt64>?,
  _ faultErrorCodeOut: UnsafeMutablePointer<UInt32>?
) -> Int32 {
  guard let opaque, rawByteCount > 0, let hostAddressSpaceOffsetOut, let faultAddressOut,
    let faultErrorCodeOut
  else {
    return Int32(DORY_JIT_TLB_RESOLUTION_FALLBACK.rawValue)
  }
  let access: DoryX86MemoryAccessKind
  switch rawAccess {
  case UInt32(DORY_JIT_TLB_ACCESS_READ.rawValue): access = .read
  case UInt32(DORY_JIT_TLB_ACCESS_WRITE.rawValue): access = .write
  case UInt32(DORY_JIT_TLB_ACCESS_EXECUTE.rawValue): access = .instructionFetch
  default: return Int32(DORY_JIT_TLB_RESOLUTION_FALLBACK.rawValue)
  }
  let callback = opaque.assumingMemoryBound(to: DoryJITMemoryCallbackContext.self)
  guard !callback.pointee.failed else {
    return Int32(DORY_JIT_TLB_RESOLUTION_FALLBACK.rawValue)
  }
  guard let translatedMemory = callback.pointee.capabilities.memory as? DoryX86TranslatedMemory
  else {
    return Int32(DORY_JIT_TLB_RESOLUTION_FALLBACK.rawValue)
  }
  do {
    guard
      let hostAddressSpaceOffset = try translatedMemory.hostAddressSpaceOffsetForJIT(
        linearAddress: linearAddress,
        byteCount: Int(rawByteCount),
        access: access
      )
    else {
      return Int32(DORY_JIT_TLB_RESOLUTION_FALLBACK.rawValue)
    }
    hostAddressSpaceOffsetOut.pointee = hostAddressSpaceOffset
    return Int32(DORY_JIT_TLB_RESOLUTION_FILLED.rawValue)
  } catch DoryX86MemoryError.pageFault(let address, let errorCode) {
    faultAddressOut.pointee = address
    faultErrorCodeOut.pointee = errorCode
    return Int32(DORY_JIT_TLB_RESOLUTION_PAGE_FAULT.rawValue)
  } catch {
    return Int32(DORY_JIT_TLB_RESOLUTION_FALLBACK.rawValue)
  }
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
        doryJITRecordMemoryFailure(context)
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
    doryJITRecordMemoryFailure(context)
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
      doryJITInvalidatePageTableWrite(context)
      return
    }
    let bytes = (0..<Int(byteCount)).map {
      UInt8(truncatingIfNeeded: value >> UInt64($0 * 8))
    }
    try context.pointee.capabilities.memory.validateWrite(at: address, byteCount: bytes.count)
    try context.pointee.capabilities.memory.write(at: address, bytes: bytes)
    doryJITInvalidatePageTableWrite(context)
  } catch {
    doryJITRecordMemoryFailure(context)
  }
}

private let doryJITMemoryCompareExchange: dory_jit_memory_compare_exchange_function = {
  opaque, address, expected, desired, byteCount, observedOut in
  guard let opaque, let observedOut, [1, 2, 4, 8].contains(byteCount) else { return 0 }
  let context = opaque.assumingMemoryBound(to: DoryJITMemoryCallbackContext.self)
  guard !context.pointee.failed, let atomicMemory = context.pointee.capabilities.atomicScalarMemory
  else {
    doryJITRecordMemoryFailure(context)
    return 0
  }
  do {
    guard
      let observed = try DoryX86AtomicGate.shared.withLock({
        try atomicMemory.compareExchangeScalar(
          at: address,
          expected: expected,
          desired: desired,
          byteCount: Int(byteCount)
        )
      })
    else {
      doryJITRecordMemoryFailure(context)
      return 0
    }
    observedOut.pointee = observed
    doryJITInvalidatePageTableWrite(context)
    return 1
  } catch {
    doryJITRecordMemoryFailure(context)
    return 0
  }
}

struct DoryJITPreparedExecution: Sendable, Hashable {
  let exitCode: DoryJITExitCode
  let failedCallbackHostPC: UInt64?
  let failedExecutionContext: [UInt64]?
}

public final class DoryJITExecutableRegion: @unchecked Sendable {
  public static let hostAddressSpaceBaseWordIndex =
    DoryARM64Tier1ABI.ContextWord.hostAddressSpaceBase.rawValue
  public static let readTLBBaseWordIndex = DoryARM64Tier1ABI.ContextWord.readTLBBase.rawValue
  public static let writeTLBBaseWordIndex = DoryARM64Tier1ABI.ContextWord.writeTLBBase.rawValue
  public static let executeTLBBaseWordIndex = DoryARM64Tier1ABI.ContextWord.executeTLBBase.rawValue
  public static let tlbEntryMaskWordIndex = DoryARM64Tier1ABI.ContextWord.tlbEntryMask.rawValue
  public static let tlbAddressSpaceGenerationWordIndex =
    DoryARM64Tier1ABI.ContextWord.tlbAddressSpaceGeneration.rawValue
  public static let hostAddressSpaceByteCountWordIndex =
    DoryARM64Tier1ABI.ContextWord.hostAddressSpaceByteCount.rawValue
  public static let tlbStorageWordIndex = DoryARM64Tier1ABI.ContextWord.tlbStorage.rawValue
  public static let tlbResolverWordIndex = DoryARM64Tier1ABI.ContextWord.tlbResolver.rawValue
  public static let readTLBHitCounterWordIndex =
    DoryARM64Tier1ABI.ContextWord.readTLBHitCounter.rawValue
  public static let writeTLBHitCounterWordIndex =
    DoryARM64Tier1ABI.ContextWord.writeTLBHitCounter.rawValue
  public static let atomicCompareExchangeWordIndex =
    DoryARM64Tier1ABI.ContextWord.atomicCompareExchange.rawValue
  public static let atomicExchangeWordIndex = DoryARM64Tier1ABI.ContextWord.atomicExchange.rawValue
  public static let atomicFetchAddWordIndex = DoryARM64Tier1ABI.ContextWord.atomicFetchAdd.rawValue
  public static let atomicRMWWordIndex = DoryARM64Tier1ABI.ContextWord.atomicRMW.rawValue
  public static let atomicCompareExchangePairWordIndex =
    DoryARM64Tier1ABI.ContextWord.atomicCompareExchangePair.rawValue
  public static let ibtcEntriesBaseWordIndex =
    DoryARM64Tier1ABI.ContextWord.ibtcEntriesBase.rawValue
  public static let ibtcEntryMaskWordIndex = DoryARM64Tier1ABI.ContextWord.ibtcEntryMask.rawValue
  public static let ibtcGenerationWordIndex = DoryARM64Tier1ABI.ContextWord.ibtcGeneration.rawValue
  public static let shadowReturnEntriesBaseWordIndex =
    DoryARM64Tier1ABI.ContextWord.shadowReturnEntriesBase.rawValue
  public static let shadowReturnEntryMaskWordIndex =
    DoryARM64Tier1ABI.ContextWord.shadowReturnEntryMask.rawValue
  public static let shadowReturnTopAddressWordIndex =
    DoryARM64Tier1ABI.ContextWord.shadowReturnTopAddress.rawValue
  public static let shadowReturnGenerationWordIndex =
    DoryARM64Tier1ABI.ContextWord.shadowReturnGeneration.rawValue
  public static let contextWordCount = DoryARM64Tier1ABI.contextWordCount

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

  /// Atomically replaces one aligned ARM64 direct-branch slot under the C runtime's MAP_JIT
  /// publication lock and invalidates the instruction cache for the patched word.
  public func patchDirectBranch(at slotOffset: Int, to targetOffset: Int) throws {
    guard slotOffset >= 0, targetOffset >= 0 else {
      throw DoryJITRuntimeError.invalidOffset(min(slotOffset, targetOffset))
    }
    let result = dory_jit_region_patch_branch(region, slotOffset, targetOffset)
    guard result == 0 else { throw DoryJITRuntimeError.branchPatchFailed(result) }
  }

  func entryAddress(at offset: Int) -> UInt64? {
    guard offset >= 0, let entry = dory_jit_region_entry(region, offset) else { return nil }
    return UInt64(UInt(bitPattern: entry))
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
    requiresRestartableReads: Bool,
    translationTLB: DoryX86JITTLB? = nil
  ) throws -> DoryJITExitCode {
    try executePreparedWithRecovery(
      at: offset,
      context: context,
      memoryCapabilities: memoryCapabilities,
      requiresRestartableReads: requiresRestartableReads,
      translationTLB: translationTLB
    ).exitCode
  }

  func executePreparedWithRecovery(
    at offset: Int,
    context: UnsafeMutableBufferPointer<UInt64>,
    memoryCapabilities: DoryJITMemoryCapabilities?,
    requiresRestartableReads: Bool,
    translationTLB: DoryX86JITTLB? = nil
  ) throws -> DoryJITPreparedExecution {
    guard offset >= 0, offset.isMultiple(of: 4), offset < capacity else {
      throw DoryJITRuntimeError.invalidOffset(offset)
    }
    guard context.count == Self.contextWordCount else {
      throw DoryJITRuntimeError.invalidContextWordCount(context.count)
    }
    var rawExit: UInt32 = 0
    let result: Int32
    var memoryFailed = false
    var failedCallbackHostPC: UInt64?
    var failedExecutionContext: [UInt64]?
    let inlineTLBFaultHostPCIndex = DoryARM64Tier1ABI.ContextWord.inlineTLBFaultHostPC.rawValue
    context[inlineTLBFaultHostPCIndex] = 0
    context[DoryARM64Tier1ABI.ContextWord.memoryFaultCheckpointActive.rawValue] = 0
    context[DoryARM64Tier1ABI.ContextWord.memoryFaultCheckpointRegisterMask.rawValue] = 0
    if let memoryCapabilities {
      var memoryContext = DoryJITMemoryCallbackContext(
        capabilities: memoryCapabilities,
        requiresRestartableReads: requiresRestartableReads,
        executionContext: context,
        translationTLB: translationTLB
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
      failedCallbackHostPC = memoryContext.failedCallbackHostPC
      failedExecutionContext = memoryContext.failedExecutionContext
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
    if memoryFailed {
      return .init(
        exitCode: .interpreter,
        failedCallbackHostPC: failedCallbackHostPC,
        failedExecutionContext: failedExecutionContext
      )
    }
    if context[inlineTLBFaultHostPCIndex] != 0 {
      return .init(
        exitCode: .interpreter,
        failedCallbackHostPC: context[inlineTLBFaultHostPCIndex],
        failedExecutionContext: Array(context)
      )
    }
    guard let exit = DoryJITExitCode(rawValue: rawExit) else {
      throw DoryJITRuntimeError.invalidExitCode(rawExit)
    }
    return .init(exitCode: exit, failedCallbackHostPC: nil, failedExecutionContext: nil)
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
  public let guestInstructionCount: UInt32
  public let exitCode: DoryJITExitCode

  public init(
    block: DoryARM64CompiledBlock,
    guestInstructionCount: UInt32? = nil,
    exitCode: DoryJITExitCode
  ) {
    self.block = block
    self.guestInstructionCount = guestInstructionCount ?? block.guestInstructionCount
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
  public let blockCacheLookupHits: UInt64
  /// Compatibility field retained for existing diagnostic consumers. Production resident lookup
  /// no longer uses a Swift dictionary, so new records report zero here.
  public let dictionaryLookupHits: UInt64
  public let lookupMisses: UInt64
  public let memoryGenerationHits: UInt64
  public let byteValidationHits: UInt64
  public let sharedCodeHits: UInt64
  public let compiledBlocks: UInt64
  /// Blocks submitted to the tier-one emitter after architectural preflight succeeds.
  public let tier1CompilationAttempts: UInt64
  /// Tier-one attempts that declined and continued through the legacy baseline emitter.
  public let tier1CompilationDeclines: UInt64
  public let tier1CompiledBlocks: UInt64
  public let lazyFlagMaterializations: UInt64
  public let declinedCompilations: UInt64
  public let negativeCacheHits: UInt64
  public let negativeCacheMisses: UInt64
  public let negativeGenerationMismatches: UInt64
  public let negativeEntryCount: UInt64
  /// Exact hit counts for the 16 hottest currently live negative entries. Replacing or removing an
  /// entry through collision, invalidation, generation mismatch, or cache reset discards its count.
  public let negativeCacheHotSites: [DoryARM64NegativeCacheHotSite]
  public let codeCacheWraps: UInt64
  public let codeCacheEvictedBlocks: UInt64
  public let nativeTraceAttempts: UInt64
  public let nativeTraceReplays: UInt64
  public let codeGenerationChecks: UInt64
  public let codeGenerationMismatches: UInt64
  public let chainedExecutionCalls: UInt64
  public let chainedRequestedInstructions: UInt64
  public let chainedRetiredInstructions: UInt64
  /// Native chain entries that observed the executor's pending-work byte.
  public let pendingWorkExits: UInt64
  /// Largest conservative in-entry retirement count observed before a pending-work exit. Work may
  /// have retired before the request was published, so this is an upper bound rather than a clock.
  public let pendingWorkMaximumRetiredInstructions: UInt64
  /// Host-to-generated-code entries made by the chained dispatcher. One entry may now retire
  /// several resident blocks after direct links have warmed.
  public let nativeDispatcherEntries: UInt64
  public let directChainPatches: UInt64
  public let directChainUnlinks: UInt64
  /// Resident transitions completed through patched generated branches, excluding the entry
  /// block selected by Swift.
  public let directlyChainedBlocks: UInt64
  public let indirectBranchTargetCacheHits: UInt64
  public let indirectBranchTargetCacheMisses: UInt64
  public let indirectBranchTargetCacheFills: UInt64
  public let indirectBranchTargetCacheHitRate: Double?
  public let shadowReturnStackHits: UInt64
  public let shadowReturnStackMisses: UInt64
  public let shadowReturnStackPushes: UInt64
  public let shadowReturnStackHitRate: Double?
  public let translationCacheEntryCount: UInt64
  public let translationCacheAllocatedBytes: UInt64
  public let translationCacheAddressSpaceGeneration: UInt64
  public let translationCacheInvalidations: UInt64
  public let translationCacheHits: UInt64
  public let translationCacheMisses: UInt64
  public let translationCacheFills: UInt64
  public let translationCachePageFaults: UInt64
  public let translationCacheFallbacks: UInt64
  public let translationCacheHitRate: Double
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
  /// A resident block normally ends at an architectural control, write, helper, or instruction
  /// page boundary. This is only a pathological straight-line safety ceiling; the 4 KiB fetch
  /// bound below is the effective limit for ordinary one-byte instructions.
  static let maximumResidentInstructionBudget = 4_096
  static let instructionPageByteCount = 4_096
  static let maximumRecordedNativeTraceBlocks = 256
  static let codeCacheGenerationCount = 2

  /// One executor has one serialized native entry, so its context can remain at a stable address.
  /// The final byte is the only field written concurrently by device/coordination threads.
  private final class ExecutionContextStorage: @unchecked Sendable {
    private let words: UnsafeMutablePointer<UInt64>

    init() {
      words = .allocate(capacity: DoryJITExecutableRegion.contextWordCount)
      words.initialize(repeating: 0, count: DoryJITExecutableRegion.contextWordCount)
    }

    deinit {
      words.deinitialize(count: DoryJITExecutableRegion.contextWordCount)
      words.deallocate()
    }

    func withBuffer<Result>(
      _ body: (UnsafeMutableBufferPointer<UInt64>) throws -> Result
    ) rethrows -> Result {
      try body(
        UnsafeMutableBufferPointer(
          start: words,
          count: DoryJITExecutableRegion.contextWordCount
        ))
    }

    var pendingWorkPointer: UnsafeMutablePointer<UInt8> {
      UnsafeMutableRawPointer(words)
        .advanced(by: DoryARM64Tier1ABI.ContextWord.pendingWork.byteOffset)
        .assumingMemoryBound(to: UInt8.self)
    }
  }

  private struct LookupKey: Hashable {
    let guestStart: UInt64
    let physicalStart: UInt64
    let addressSpaceID: UInt64
    let executionMode: DoryX86ExecutionMode
    let privilegeLevel: UInt8
    let pagingEnabled: Bool
  }

  private final class ResidentBlock {
    let key: LookupKey
    let block: DoryARM64CompiledBlock
    let offset: Int
    let codeGeneration: UInt64
    var memoryCodeGeneration: UInt64?
    let endsTimeBoundary: Bool
    let cr3WriteSourceRegister: Int?
    var incomingLinks: [ChainLink] = []
    var outgoingLinks: [Int: ChainLink] = [:]

    init(
      key: LookupKey,
      block: DoryARM64CompiledBlock,
      offset: Int,
      codeGeneration: UInt64,
      memoryCodeGeneration: UInt64?,
      endsTimeBoundary: Bool,
      cr3WriteSourceRegister: Int?
    ) {
      self.key = key
      self.block = block
      self.offset = offset
      self.codeGeneration = codeGeneration
      self.memoryCodeGeneration = memoryCodeGeneration
      self.endsTimeBoundary = endsTimeBoundary
      self.cr3WriteSourceRegister = cr3WriteSourceRegister
    }
  }

  private final class ChainLink {
    weak var source: ResidentBlock?
    weak var target: ResidentBlock?
    let slot: DoryARM64ChainSlot

    init(source: ResidentBlock, target: ResidentBlock, slot: DoryARM64ChainSlot) {
      self.source = source
      self.target = target
      self.slot = slot
    }
  }

  private struct RecentResidentBlock {
    let key: LookupKey
    let resident: ResidentBlock
  }

  private struct ResidentSlot {
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
    let guestInstructionCount: UInt32
    let exitCode: DoryJITExitCode
  }

  private struct RecoveredExecutionPrefix {
    let guestInstructionCount: Int
    let residentBlockCount: Int
    let directlyChainedBlockCount: UInt64
  }

  public let maximumCodeBytes: Int
  private let lock = NSLock()
  private let decoder: DoryX86Decoder
  private let cpuProfileIdentifier: String
  private let physicalAddressBits: UInt8
  private let profile: DoryX86CPUProfile
  private let emitter: DoryARM64BaselineEmitter
  private let tier1Emitter: DoryARM64Tier1Emitter
  private let tier1Enabled: Bool
  private let optimization: DoryARM64JITOptimization
  private let optimizer: DoryIROptimizer
  private let region: DoryJITExecutableRegion
  private let translationTLB: DoryX86JITTLB
  private let blockCache: DoryJITBlockCache
  private let indirectBranchTargetCache: DoryJITIndirectBranchTargetCache
  private let shadowReturnStack: DoryJITShadowReturnStack
  private let executionContextStorage: ExecutionContextStorage
  private var residentSlots: [ResidentSlot?] = []
  private var freeResidentSlotIndices: [Int] = []
  private var recentEntries: [RecentResidentBlock?] = .init(repeating: nil, count: 256)
  private var nativeTraces: [NativeTrace?] = .init(repeating: nil, count: 4_096)
  private var negativeEntries: [NegativeEntry?] = .init(repeating: nil, count: 4_096)
  private var nativeBatchExecutionCountValue: UInt64 = 0
  private var recentLookupHitCount: UInt64 = 0
  private var blockCacheLookupHitCount: UInt64 = 0
  private var lookupMissCount: UInt64 = 0
  private var memoryGenerationHitCount: UInt64 = 0
  private var byteValidationHitCount: UInt64 = 0
  private var sharedCodeHitCount: UInt64 = 0
  private var compiledBlockCount: UInt64 = 0
  private var tier1CompilationAttemptCount: UInt64 = 0
  private var tier1CompilationDeclineCount: UInt64 = 0
  private var tier1CompiledBlockCount: UInt64 = 0
  private var lazyFlagMaterializationCount: UInt64 = 0
  private var declinedCompilationCount: UInt64 = 0
  private var negativeCacheHitCount: UInt64 = 0
  private var negativeCacheMissCount: UInt64 = 0
  private var negativeGenerationMismatchCount: UInt64 = 0
  private var codeCacheWrapCount: UInt64 = 0
  private var codeCacheEvictedBlockCount: UInt64 = 0
  private var nativeTraceAttemptCount: UInt64 = 0
  private var nativeTraceReplayCount: UInt64 = 0
  private var codeGenerationCheckCount: UInt64 = 0
  private var codeGenerationMismatchCount: UInt64 = 0
  private var chainedExecutionCallCount: UInt64 = 0
  private var chainedRequestedInstructionCount: UInt64 = 0
  private var chainedRetiredInstructionCount: UInt64 = 0
  private var pendingWorkExitCount: UInt64 = 0
  private var pendingWorkMaximumRetiredInstructionCount: UInt64 = 0
  private var nativeDispatcherEntryCount: UInt64 = 0
  private var directChainPatchCount: UInt64 = 0
  private var directChainUnlinkCount: UInt64 = 0
  private var directlyChainedBlockCount: UInt64 = 0
  private var indirectBranchTargetCacheHitCount: UInt64 = 0
  private var indirectBranchTargetCacheMissCount: UInt64 = 0
  private var shadowReturnStackHitCount: UInt64 = 0
  private var shadowReturnStackMissCount: UInt64 = 0
  private var shadowReturnStackPushCount: UInt64 = 0
  private var codeCacheEpoch: UInt64 = 0
  private var activeCodeCacheGeneration = 0
  private var codeCacheGenerationNextOffsets: [Int] = []
  private var currentTLBAddressSpaceID: UInt64?
  private var translationTLBGeneration: UInt64 = 1
  private var translationTLBInvalidationCount: UInt64 = 0
  private var pagingInvalidationSequences: [ObjectIdentifier: UInt64] = [:]
  private var codeProtectionGenerations: [ObjectIdentifier: UInt64] = [:]

  public init(
    maximumCodeBytes: Int = DoryARM64BaselineExecutor.defaultMaximumCodeBytes,
    decoder: DoryX86Decoder = .init(),
    cpuProfileIdentifier: String = DoryX86CPUProfile.compatibleV1Identifier,
    physicalAddressBits: UInt8 = DoryX86CPUProfile.compatibleV1.physicalAddressBits,
    profile: DoryX86CPUProfile = .compatibleV1,
    emitter: DoryARM64BaselineEmitter = .init(),
    tier1Enabled: Bool = false,
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
    self.tier1Emitter = .init()
    self.tier1Enabled = tier1Enabled
    self.optimization = optimization
    self.optimizer = optimizer
    executionContextStorage = .init()
    let executableRegion = try DoryJITExecutableRegion(minimumCapacity: self.maximumCodeBytes)
    region = executableRegion
    codeCacheGenerationNextOffsets = [
      0,
      (executableRegion.capacity / Self.codeCacheGenerationCount) & ~3,
    ]
    translationTLB = try DoryX86JITTLB()
    blockCache = try DoryJITBlockCache()
    indirectBranchTargetCache = try DoryJITIndirectBranchTargetCache()
    shadowReturnStack = try DoryJITShadowReturnStack()
  }

  public var residentBlockCount: Int { lock.withLock { blockCache.count } }
  public var residentByteCount: Int {
    lock.withLock {
      codeCacheGenerationNextOffsets.enumerated().reduce(0) { total, item in
        total + item.element - codeCacheGenerationRange(item.offset).lowerBound
      }
    }
  }
  public var nativeBatchExecutionCount: UInt64 {
    lock.withLock { nativeBatchExecutionCountValue }
  }

  /// Requests a bounded native exit. The release store is observed by the generated byte poll at
  /// the next block entry, including entries reached through a patched direct chain.
  public func requestPendingWork() {
    dory_jit_pending_work_store_release(executionContextStorage.pendingWorkPointer, 1)
  }

  /// Clears a request after the dispatcher has consumed interrupts, cancellation, or tier work.
  public func clearPendingWork() {
    dory_jit_pending_work_store_release(executionContextStorage.pendingWorkPointer, 0)
  }

  public var hasPendingWork: Bool {
    dory_jit_pending_work_load_acquire(executionContextStorage.pendingWorkPointer) != 0
  }
  public var diagnostics: DoryARM64BaselineExecutorDiagnostics {
    lock.withLock {
      let tlbDiagnostics = translationTLB.diagnostics
      let ibtcDiagnostics = indirectBranchTargetCache.diagnostics
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
        blockCacheLookupHits: blockCacheLookupHitCount,
        dictionaryLookupHits: 0,
        lookupMisses: lookupMissCount,
        memoryGenerationHits: memoryGenerationHitCount,
        byteValidationHits: byteValidationHitCount,
        sharedCodeHits: sharedCodeHitCount,
        compiledBlocks: compiledBlockCount,
        tier1CompilationAttempts: tier1CompilationAttemptCount,
        tier1CompilationDeclines: tier1CompilationDeclineCount,
        tier1CompiledBlocks: tier1CompiledBlockCount,
        lazyFlagMaterializations: lazyFlagMaterializationCount,
        declinedCompilations: declinedCompilationCount,
        negativeCacheHits: negativeCacheHitCount,
        negativeCacheMisses: negativeCacheMissCount,
        negativeGenerationMismatches: negativeGenerationMismatchCount,
        negativeEntryCount: UInt64(negativeEntries.lazy.compactMap { $0 }.count),
        negativeCacheHotSites: Array(negativeCacheHotSites.prefix(16)),
        codeCacheWraps: codeCacheWrapCount,
        codeCacheEvictedBlocks: codeCacheEvictedBlockCount,
        nativeTraceAttempts: nativeTraceAttemptCount,
        nativeTraceReplays: nativeTraceReplayCount,
        codeGenerationChecks: codeGenerationCheckCount,
        codeGenerationMismatches: codeGenerationMismatchCount,
        chainedExecutionCalls: chainedExecutionCallCount,
        chainedRequestedInstructions: chainedRequestedInstructionCount,
        chainedRetiredInstructions: chainedRetiredInstructionCount,
        pendingWorkExits: pendingWorkExitCount,
        pendingWorkMaximumRetiredInstructions: pendingWorkMaximumRetiredInstructionCount,
        nativeDispatcherEntries: nativeDispatcherEntryCount,
        directChainPatches: directChainPatchCount,
        directChainUnlinks: directChainUnlinkCount,
        directlyChainedBlocks: directlyChainedBlockCount,
        indirectBranchTargetCacheHits: indirectBranchTargetCacheHitCount,
        indirectBranchTargetCacheMisses: indirectBranchTargetCacheMissCount,
        indirectBranchTargetCacheFills: ibtcDiagnostics.fills,
        indirectBranchTargetCacheHitRate: {
          let lookups = indirectBranchTargetCacheHitCount + indirectBranchTargetCacheMissCount
          return lookups == 0
            ? nil : Double(indirectBranchTargetCacheHitCount) / Double(lookups)
        }(),
        shadowReturnStackHits: shadowReturnStackHitCount,
        shadowReturnStackMisses: shadowReturnStackMissCount,
        shadowReturnStackPushes: shadowReturnStackPushCount,
        shadowReturnStackHitRate: {
          let lookups = shadowReturnStackHitCount + shadowReturnStackMissCount
          return lookups == 0 ? nil : Double(shadowReturnStackHitCount) / Double(lookups)
        }(),
        translationCacheEntryCount: UInt64(translationTLB.entryCount),
        translationCacheAllocatedBytes: UInt64(translationTLB.allocatedByteCount),
        translationCacheAddressSpaceGeneration: translationTLBGeneration,
        translationCacheInvalidations: translationTLBInvalidationCount,
        translationCacheHits: tlbDiagnostics.hits,
        translationCacheMisses: tlbDiagnostics.misses,
        translationCacheFills: tlbDiagnostics.fills,
        translationCachePageFaults: tlbDiagnostics.pageFaults,
        translationCacheFallbacks: tlbDiagnostics.fallbacks,
        translationCacheHitRate: tlbDiagnostics.hitRate
      )
    }
  }

  public func invalidateAll() {
    lock.withLock {
      blockCache.removeAll()
      residentSlots.removeAll(keepingCapacity: true)
      freeResidentSlotIndices.removeAll(keepingCapacity: true)
      recentEntries = .init(repeating: nil, count: recentEntries.count)
      nativeTraces = .init(repeating: nil, count: nativeTraces.count)
      negativeEntries = .init(repeating: nil, count: negativeEntries.count)
      indirectBranchTargetCache.removeAll()
      shadowReturnStack.removeAll()
      codeCacheEpoch &+= 1
      activeCodeCacheGeneration = 0
      codeCacheGenerationNextOffsets = [0, codeCacheGenerationRange(1).lowerBound]
      invalidateAllTranslations()
    }
  }

  /// Imports invalidations issued by the architectural paging unit between native dispatches.
  /// One observed INVLPG can evict its direct-mapped slot; a missed, global, or wrapped event
  /// advances the generation and flushes the complete native table.
  public func synchronizeTranslationCache(with pagingUnit: DoryX86PagingUnit) {
    let snapshot = pagingUnit.invalidationSnapshot
    let identity = ObjectIdentifier(pagingUnit)
    lock.withLock {
      guard pagingInvalidationSequences[identity] != snapshot.sequence else { return }
      defer { pagingInvalidationSequences[identity] = snapshot.sequence }
      guard let previous = pagingInvalidationSequences[identity] else {
        if snapshot.sequence != 0 { invalidateAllTranslations() }
        return
      }
      let next = previous.addingReportingOverflow(1)
      if !next.overflow, next.partialValue == snapshot.sequence,
        let linearAddress = snapshot.linearAddress
      {
        translationTLB.invalidate(linearAddress: linearAddress)
        translationTLBInvalidationCount &+= 1
      } else {
        invalidateAllTranslations()
      }
    }
  }

  /// Removes lookup visibility while holding the same lock used for native execution. Retired
  /// slots are not reused individually; a whole-region wrap happens only under this lock, after
  /// every execution using the prior generation has quiesced.
  public func invalidate(addressSpaceID: UInt64, guestRange: Range<UInt64>) {
    lock.withLock {
      let victims = residentSlots.compactMap { slot -> LookupKey? in
        guard let slot, slot.key.addressSpaceID == addressSpaceID else { return nil }
        let blockRange = slot.key.guestStart..<(
          slot.key.guestStart &+ UInt64(slot.resident.block.guestByteCount))
        return blockRange.overlaps(guestRange) ? slot.key : nil
      }
      for key in victims { removeResident(for: key) }
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
      if currentTLBAddressSpaceID == addressSpaceID {
        invalidateTranslations(in: guestRange)
      }
    }
  }

  /// Selects one exact address-space generation for the context about to enter generated code.
  /// A vCPU-local table can retain stale entries across CR3 switches because the generation is
  /// part of every tag. The only wrap point performs a full flush before generation one is reused.
  private func selectTLBAddressSpace(_ addressSpaceID: UInt64) -> UInt64 {
    guard currentTLBAddressSpaceID != addressSpaceID else { return translationTLBGeneration }
    if currentTLBAddressSpaceID != nil {
      if translationTLBGeneration == DoryX86JITTLB.maximumAddressSpaceGeneration {
        translationTLB.invalidateAll()
        translationTLBGeneration = 1
        translationTLBInvalidationCount &+= 1
      } else {
        translationTLBGeneration += 1
      }
    }
    currentTLBAddressSpaceID = addressSpaceID
    return translationTLBGeneration
  }

  private func invalidateTranslations(in guestRange: Range<UInt64>) {
    guard !guestRange.isEmpty else { return }
    let pageMask = UInt64((1 << DoryX86JITTLB.pageShift) - 1)
    var page = guestRange.lowerBound & ~pageMask
    let lastPage = (guestRange.upperBound - 1) & ~pageMask
    while true {
      translationTLB.invalidate(linearAddress: page)
      if page == lastPage { break }
      page &+= pageMask + 1
    }
    translationTLBInvalidationCount &+= 1
  }

  private func invalidateAllTranslations() {
    translationTLB.invalidateAll()
    translationTLBInvalidationCount &+= 1
    translationTLBGeneration =
      translationTLBGeneration == DoryX86JITTLB.maximumAddressSpaceGeneration
      ? 1 : translationTLBGeneration + 1
    currentTLBAddressSpaceID = nil
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
    physicalRIPProvider: ((_ guestStart: UInt64) throws -> UInt64?)? = nil,
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
        physicalRIPProvider: physicalRIPProvider,
        at: guestStart,
        mode: mode,
        addressSpaceID: addressSpaceID,
        maximumInstructions: maximumInstructions,
        state: &state,
        memory: memory
      )
    else { return nil }
    return .init(
      block: execution.resident.block,
      guestInstructionCount: execution.guestInstructionCount,
      exitCode: execution.exitCode
    )
  }

  /// Executes through the same validated resident-block path while returning only the fields a
  /// machine dispatcher consumes. This avoids retaining and releasing compiled code arrays for
  /// every guest block.
  public func executeSummary(
    byteProvider: (_ maximumCount: Int) throws -> [UInt8],
    codeGenerationProvider: ((_ byteCount: Int) throws -> UInt64?)? = nil,
    physicalRIPProvider: ((_ guestStart: UInt64) throws -> UInt64?)? = nil,
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
        physicalRIPProvider: physicalRIPProvider,
        at: guestStart,
        mode: mode,
        addressSpaceID: addressSpaceID,
        maximumInstructions: maximumInstructions,
        state: &state,
        memory: memory
      )
    else { return nil }
    return .init(
      guestInstructionCount: execution.guestInstructionCount,
      residentBlockCount: 1,
      tier: execution.resident.block.tier,
      exitCode: execution.exitCode
    )
  }

  /// Restores the architectural prefix published immediately before a failed memory operation.
  /// Tier 1 writes its complete lazy-flags descriptor to the context alongside native NZCV, so
  /// both metadata flag states are recoverable from the captured context image. Inline-TLB faults
  /// capture their generated BLR return PC after the architectural resolver has returned.
  private func restoreFailedMemoryCallbackPrefix(
    _ execution: DoryJITPreparedExecution,
    entryResident: ResidentBlock,
    context: UnsafeMutableBufferPointer<UInt64>
  ) -> RecoveredExecutionPrefix? {
    guard execution.exitCode == .interpreter,
      let callbackHostPC = execution.failedCallbackHostPC,
      let failedContext = execution.failedExecutionContext,
      failedContext.count == context.count
    else { return nil }
    let faultResident: ResidentBlock?
    if resident(entryResident, containsHostPC: callbackHostPC) {
      faultResident = entryResident
    } else {
      faultResident = residentSlots.lazy.compactMap(\.?.resident).first(where: {
        resident($0, containsHostPC: callbackHostPC)
      })
    }
    guard let faultResident, let entryAddress = region.entryAddress(at: faultResident.offset) else {
      return nil
    }
    let relativeHostPC = callbackHostPC - entryAddress
    guard relativeHostPC < UInt64(faultResident.block.machineBytes.count),
      let hostOffset = UInt32(exactly: relativeHostPC),
      let metadataIndex = faultResident.block.instructionMetadata.lastIndex(where: {
        $0.hostOffsetStart <= hostOffset
      })
    else { return nil }
    let metadata = faultResident.block.instructionMetadata[metadataIndex]
    var recoveredContext = failedContext
    if failedContext[DoryARM64Tier1ABI.ContextWord.memoryFaultCheckpointActive.rawValue] != 0 {
      recoveredContext[DoryARM64Tier1ABI.ContextWord.rflags.rawValue] =
        failedContext[DoryARM64Tier1ABI.ContextWord.memoryFaultCheckpointRFlags.rawValue]
      let registerMask = UInt16(truncatingIfNeeded:
        failedContext[DoryARM64Tier1ABI.ContextWord.memoryFaultCheckpointRegisterMask.rawValue])
      let checkpointBase = DoryARM64Tier1ABI.ContextWord.memoryFaultCheckpointRAX.rawValue
      for registerIndex in 0..<16 where registerMask & (UInt16(1) << registerIndex) != 0 {
        recoveredContext[registerIndex] = failedContext[checkpointBase + registerIndex]
      }
    }
    guard
      let chainInstructionCount = Int(exactly:
        failedContext[DoryARM64Tier1ABI.ContextWord.chainRetiredInstructions.rawValue]),
      let chainBlockCount = Int(exactly:
        failedContext[DoryARM64Tier1ABI.ContextWord.chainRetiredBlocks.rawValue])
    else { return nil }
    for index in context.indices
    where index != DoryARM64Tier1ABI.ContextWord.pendingWork.rawValue
    {
      context[index] = recoveredContext[index]
    }
    context[DoryARM64Tier1ABI.ContextWord.rip.rawValue] = metadata.guestRIP
    context[DoryARM64Tier1ABI.ContextWord.chainEnabled.rawValue] = 0
    return RecoveredExecutionPrefix(
      guestInstructionCount: chainInstructionCount + metadataIndex,
      residentBlockCount: chainBlockCount + (metadataIndex > 0 ? 1 : 0),
      directlyChainedBlockCount: UInt64(chainBlockCount)
    )
  }

  private func resident(_ resident: ResidentBlock, containsHostPC hostPC: UInt64) -> Bool {
    guard let entryAddress = region.entryAddress(at: resident.offset), hostPC >= entryAddress else {
      return false
    }
    return hostPC - entryAddress < UInt64(resident.block.machineBytes.count)
  }

  /// Runs consecutive resident basic blocks while the machine's interrupt deadline permits it.
  /// The execution context crosses block boundaries without round-tripping all architectural
  /// registers through Swift. System, port-I/O, halt, and restartable-memory exits still return at
  /// their exact boundary, and a block that cannot enter native code remains an interpreter step.
  public func executeChainedSummary(
    byteProvider: (_ guestStart: UInt64, _ maximumCount: Int) throws -> [UInt8],
    codeGenerationProvider: ((_ guestStart: UInt64, _ byteCount: Int) throws -> UInt64?)? = nil,
    physicalRIPProvider: ((_ guestStart: UInt64) throws -> UInt64?)? = nil,
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
    do { try state.control.validateLegacyPAEPDPTEs(physicalAddressBits: physicalAddressBits) } catch
    { return nil }
    return try lock.withLock { () -> DoryARM64ExecutionSummary? in
      synchronizeCodeProtection(for: memory)
      chainedExecutionCallCount &+= 1
      chainedRequestedInstructionCount &+= UInt64(maximumInstructions)
      guard !hasPendingWork else { return nil }
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
      // A raw link can enter a memory-bearing target even when the dispatcher entry block has no
      // callbacks. Keep one callback authority alive for the complete native chain so such a
      // target can report and recover its exact faulting instruction.
      let memoryCapabilities = memory.map { DoryJITMemoryCapabilities(memory: $0) }
      return try executionContextStorage.withBuffer { context in
        try withUnsafeTemporaryAllocation(
          of: UInt64.self,
          capacity: DoryJITExecutableRegion.contextWordCount
        ) { checkpoint in
          let translationGeneration = selectTLBAddressSpace(addressSpaceID)
          Self.populateExecutionContext(
            context,
            from: state,
            memory: memory,
            translationTLB: translationTLB,
            addressSpaceGeneration: translationGeneration,
            indirectBranchTargetCache: indirectBranchTargetCache,
            shadowReturnStack: shadowReturnStack,
            codeCacheGeneration: codeCacheEpoch &+ 1,
            preservePendingWork: true
          )
          var completed = 0
          var blockCount = 0
          guard let tracePhysicalStart = resolvePhysicalStart(
            at: guestStart,
            using: physicalRIPProvider
          ) else { return nil }
          let traceKey = makeLookupKey(
            guestStart: guestStart,
            physicalStart: tracePhysicalStart,
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
            let replayResult = try replayNativeTrace(
              trace,
              codeGenerationProvider: codeGenerationProvider,
              maximumInstructions: maximumInstructions,
              context: context
            )
            recordLazyFlagMaterializations(in: context)
            switch replayResult {
            case .executed(let replay):
              nativeTraceReplayCount &+= 1
              completed = replay.guestInstructionCount
              blockCount = replay.residentBlockCount
              if replay.exitCode != .dispatch || completed >= maximumInstructions {
                chainedRetiredInstructionCount &+= UInt64(completed)
                publishExecutionContext(context, to: &state, memory: memory)
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
          var pendingLink:
            (source: ResidentBlock, destinationGuestRIP: UInt64, usesIndirectCache: Bool)?
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
                physicalRIPProvider: physicalRIPProvider,
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
              publishExecutionContext(context, to: &state, memory: memory)
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
              } else if let recordedTier = newTrace.first?.resident.block.tier,
                resident.block.tier != recordedTier
              {
                // A batch replay has no Swift boundary between entries. Keep traces within one
                // compiler ABI so a tier-one lazy-flags producer cannot flow directly into legacy
                // code that only reads the materialized RFLAGS word.
                publishNativeTrace(newTrace, for: traceKey, if: true)
                recordsTrace = false
              } else {
                newTrace.append(
                  .init(
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
              publishExecutionContext(context, to: &state, memory: memory)
              return DoryARM64ExecutionSummary(
                guestInstructionCount: UInt32(completed),
                residentBlockCount: UInt32(blockCount),
                tier: resident.block.tier,
                exitCode: .dispatch
              )
            }

            guard canExecute(resident, context: context) else {
              publishNativeTrace(newTrace, for: traceKey, if: recordsTrace)
              guard completed > 0 else { return nil }
              chainedRetiredInstructionCount &+= UInt64(completed)
              publishExecutionContext(context, to: &state, memory: memory)
              return DoryARM64ExecutionSummary(
                guestInstructionCount: UInt32(completed),
                residentBlockCount: UInt32(blockCount),
                tier: resident.block.tier,
                exitCode: .dispatch
              )
            }

            if let pendingLink {
              if pendingLink.usesIndirectCache {
                fillIndirectBranchTargetCache(
                  from: pendingLink.source,
                  to: resident,
                  destinationGuestRIP: pendingLink.destinationGuestRIP,
                  memoryCallbacksAvailable: memoryCapabilities != nil
                )
              } else {
                installDirectChain(
                  from: pendingLink.source,
                  to: resident,
                  destinationGuestRIP: pendingLink.destinationGuestRIP,
                  memoryCallbacksAvailable: memoryCapabilities != nil
                )
              }
            }
            pendingLink = nil
            // Protected production memory advances one global generation whenever a code-bearing
            // page becomes writable. synchronizeCodeProtection has already unlinked every raw
            // generated target on that transition, so walking the complete reachable graph here
            // would add O(graph) work to every dispatcher entry. Provider-only test memories lack
            // that boundary and retain the conservative recursive validation path.
            if codeProtectionState(for: memory) == nil {
              validateDirectChainTargets(
                reachableFrom: resident,
                byteProvider: byteProvider,
                codeGenerationProvider: codeGenerationProvider,
                mode: mode,
                memory: memory
              )
            }

            // Tier-one blocks retain a deferred arithmetic-flags descriptor across native block
            // boundaries. Legacy baseline and optimizing blocks know only context word 17, so
            // resolve that descriptor before they can consume or preserve architectural flags.
            // The materializer increments the per-dispatch counter collected after execution.
            if resident.block.tier != .tier1,
              context[DoryARM64Tier1ABI.ContextWord.lazyFlagsOperation.rawValue] & 0xFF
                != DoryARM64LazyFlagsState.Operation.materialized.rawValue
            {
              doryARM64MaterializeLazyFlagsContext(context)
              // Checkpointed legacy blocks may roll their context back. Collect the transition
              // now so the counter itself is not restored and counted a second time.
              recordLazyFlagMaterializations(in: context)
            }

            let hasCheckpoint =
              resident.block.requiresMemoryCallbacks || resident.block.mayExitToInterpreter
            if hasCheckpoint {
              for index in context.indices { checkpoint[index] = context[index] }
            }
            let usesGeneratedChainAccounting = canInitiateRuntimeChain(resident)
            context[DoryARM64Tier1ABI.ContextWord.chainEnabled.rawValue] =
              usesGeneratedChainAccounting ? 1 : 0
            context[DoryARM64Tier1ABI.ContextWord.chainRemainingInstructions.rawValue] =
              UInt64(remaining)
            context[DoryARM64Tier1ABI.ContextWord.chainRetiredInstructions.rawValue] = 0
            context[DoryARM64Tier1ABI.ContextWord.chainRetiredBlocks.rawValue] = 0
            context[DoryARM64Tier1ABI.ContextWord.chainLastGuestRIP.rawValue] = 0
            nativeDispatcherEntryCount &+= 1
            let execution = try region.executePreparedWithRecovery(
              at: resident.offset,
              context: context,
              memoryCapabilities: memoryCapabilities,
              requiresRestartableReads: resident.block.requiresRestartableMemoryReads,
              translationTLB: translationTLB
            )
            let exit = execution.exitCode
            recordLazyFlagMaterializations(in: context)
            recordIndirectBranchTargetCacheLookups(in: context)
            recordShadowReturnStackActivity(in: context)
            if exit == .interpreter,
              hasCheckpoint || execution.failedCallbackHostPC != nil
            {
              publishNativeTrace(newTrace, for: traceKey, if: recordsTrace)
              if let recoveredPrefix = restoreFailedMemoryCallbackPrefix(
                execution,
                entryResident: resident,
                context: context
              ) {
                if recoveredPrefix.guestInstructionCount == 0 {
                  // The captured callback image may contain speculative state produced inside the
                  // first instruction (for example flags computed before a rejected RMW store).
                  // Its exact entry state is the dispatcher checkpoint.
                  for index in context.indices
                  where index != DoryARM64Tier1ABI.ContextWord.pendingWork.rawValue
                  {
                    context[index] = checkpoint[index]
                  }
                }
                completed += recoveredPrefix.guestInstructionCount
                blockCount += recoveredPrefix.residentBlockCount
                directlyChainedBlockCount &+= recoveredPrefix.directlyChainedBlockCount
                guard completed > 0 else { return nil }
                chainedRetiredInstructionCount &+= UInt64(completed)
                publishExecutionContext(context, to: &state, memory: memory)
                return DoryARM64ExecutionSummary(
                  guestInstructionCount: UInt32(completed),
                  residentBlockCount: UInt32(blockCount),
                  tier: resident.block.tier,
                  exitCode: .interpreter
                )
              }
              for index in context.indices
              where index != DoryARM64Tier1ABI.ContextWord.pendingWork.rawValue
              {
                context[index] = checkpoint[index]
              }
              guard completed > 0 else { return nil }
              chainedRetiredInstructionCount &+= UInt64(completed)
              publishExecutionContext(context, to: &state, memory: memory)
              return DoryARM64ExecutionSummary(
                guestInstructionCount: UInt32(completed),
                residentBlockCount: UInt32(blockCount),
                tier: resident.block.tier,
                exitCode: .dispatch
              )
            }

            let generatedInstructionCount =
              usesGeneratedChainAccounting
              ? context[DoryARM64Tier1ABI.ContextWord.chainRetiredInstructions.rawValue] : 0
            let generatedBlockCount =
              usesGeneratedChainAccounting
              ? context[DoryARM64Tier1ABI.ContextWord.chainRetiredBlocks.rawValue] : 0
            context[DoryARM64Tier1ABI.ContextWord.chainEnabled.rawValue] = 0
            if usesGeneratedChainAccounting, exit == .pendingWork {
              pendingWorkExitCount &+= 1
              pendingWorkMaximumRetiredInstructionCount = max(
                pendingWorkMaximumRetiredInstructionCount,
                generatedInstructionCount
              )
            }
            if usesGeneratedChainAccounting, generatedBlockCount == 0, exit == .pendingWork {
              publishNativeTrace(newTrace, for: traceKey, if: recordsTrace)
              guard completed > 0 else { return nil }
              chainedRetiredInstructionCount &+= UInt64(completed)
              publishExecutionContext(context, to: &state, memory: memory)
              return DoryARM64ExecutionSummary(
                guestInstructionCount: UInt32(completed),
                residentBlockCount: UInt32(blockCount),
                tier: resident.block.tier,
                exitCode: .dispatch
              )
            }
            if generatedBlockCount > 0 {
              precondition(
                generatedInstructionCount <= UInt64(remaining)
                  && generatedBlockCount <= UInt64(UInt32.max),
                "generated chain exceeded its dispatcher budget"
              )
              completed += Int(generatedInstructionCount)
              blockCount += Int(generatedBlockCount)
              if generatedBlockCount > 1 {
                directlyChainedBlockCount &+= generatedBlockCount - 1
              }
            } else {
              completed += Int(resident.block.guestInstructionCount)
              blockCount += 1
            }
            if exit == .dispatch, completed < maximumInstructions,
              usesGeneratedChainAccounting,
              let source = residentForExecutedChainSource(
                guestRIP: context[DoryARM64Tier1ABI.ContextWord.chainLastGuestRIP.rawValue],
                entryResident: resident,
                physicalRIPProvider: physicalRIPProvider,
                addressSpaceID: addressSpaceID,
                mode: mode,
                state: state
              )
            {
              pendingLink = (
                source,
                context[DoryARM64Tier1ABI.ContextWord.rip.rawValue],
                source.block.chainSlots?.isEmpty == true
              )
            }
            guard exit == .dispatch, completed < maximumInstructions, !resident.endsTimeBoundary
            else {
              publishNativeTrace(newTrace, for: traceKey, if: recordsTrace)
              chainedRetiredInstructionCount &+= UInt64(completed)
              publishExecutionContext(context, to: &state, memory: memory)
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
    physicalRIPProvider: ((_ guestStart: UInt64) throws -> UInt64?)?,
    at guestStart: UInt64,
    mode: DoryX86ExecutionMode,
    addressSpaceID: UInt64,
    maximumInstructions: Int,
    state: inout DoryX86ArchitecturalState,
    memory: (any DoryX86Memory)?
  ) throws -> ResidentExecution? {
    guard maximumInstructions > 0, !hasPendingWork, state.interruptShadow == nil,
      !state.rflags.contains(.virtual8086),
      !state.rflags.contains(.resume),
      !DoryX86AlignmentPolicy.isEnabled(state: state),
      mode == .long64 || (mode == .protected32 && state.cs.base == 0 && state.cs.limit == .max)
    else { return nil }
    do { try state.control.validateLegacyPAEPDPTEs(physicalAddressBits: physicalAddressBits) } catch
    { return nil }
    return try lock.withLock { () -> ResidentExecution? in
      synchronizeCodeProtection(for: memory)
      guard
        let resident = try resolveResident(
          byteProvider: byteProvider,
          codeGenerationProvider: codeGenerationProvider,
          physicalRIPProvider: physicalRIPProvider,
          at: guestStart,
          mode: mode,
          addressSpaceID: addressSpaceID,
          maximumInstructions: maximumInstructions,
          state: state,
          memory: memory
        )
      else { return nil }

      return try executionContextStorage.withBuffer { context in
        let translationGeneration = selectTLBAddressSpace(addressSpaceID)
        Self.populateExecutionContext(
          context,
          from: state,
          memory: memory,
          translationTLB: translationTLB,
          addressSpaceGeneration: translationGeneration,
          indirectBranchTargetCache: indirectBranchTargetCache,
          codeCacheGeneration: codeCacheEpoch &+ 1,
          preservePendingWork: true
        )
        guard canExecute(resident, context: context) else { return nil }
        let execution = try region.executePreparedWithRecovery(
          at: resident.offset,
          context: context,
          memoryCapabilities: memory.map { DoryJITMemoryCapabilities(memory: $0) },
          requiresRestartableReads: resident.block.requiresRestartableMemoryReads,
          translationTLB: translationTLB
        )
        let exit = execution.exitCode
        recordLazyFlagMaterializations(in: context)
        if exit == .interpreter,
          resident.block.requiresMemoryCallbacks || resident.block.mayExitToInterpreter
        {
          if let recoveredPrefix = restoreFailedMemoryCallbackPrefix(
            execution,
            entryResident: resident,
            context: context
          ) {
            if recoveredPrefix.guestInstructionCount > 0 {
              publishExecutionContext(context, to: &state, memory: memory)
            }
            return ResidentExecution(
              resident: resident,
              guestInstructionCount: UInt32(recoveredPrefix.guestInstructionCount),
              exitCode: exit
            )
          }
          // A generated guard without a callback recovery image is an all-or-nothing block exit.
          return ResidentExecution(resident: resident, guestInstructionCount: 0, exitCode: exit)
        }
        publishExecutionContext(context, to: &state, memory: memory)
        return ResidentExecution(
          resident: resident,
          guestInstructionCount: resident.block.guestInstructionCount,
          exitCode: exit
        )
      }
    }
  }

  /// Resolves a block while the executor lock is held. Callers must not retain the returned region
  /// authority past that lock because a later compilation may wrap the bounded code cache.
  private func resolveResident(
    byteProvider: (_ maximumCount: Int) throws -> [UInt8],
    codeGenerationProvider: ((_ byteCount: Int) throws -> UInt64?)?,
    physicalRIPProvider: ((_ guestStart: UInt64) throws -> UInt64?)?,
    at guestStart: UInt64,
    mode: DoryX86ExecutionMode,
    addressSpaceID: UInt64,
    maximumInstructions: Int,
    state: DoryX86ArchitecturalState,
    memory: (any DoryX86Memory)?
  ) throws -> ResidentBlock? {
    let compilationInstructionBudget = min(
      maximumInstructions, Self.maximumResidentInstructionBudget)
    guard let physicalStart = resolvePhysicalStart(
      at: guestStart,
      using: physicalRIPProvider
    ) else { return nil }
    let key = makeLookupKey(
      guestStart: guestStart,
      physicalStart: physicalStart,
      addressSpaceID: addressSpaceID,
      mode: mode,
      state: state
    )
    let negativeKey = NegativeLookupKey(
      lookupKey: key,
      instructionBudget: compilationInstructionBudget
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
      let currentBytes = try speculativeInstructionBytes(
        using: byteProvider, maximumCount: byteCount)
      let generation = Self.fingerprint(bytes: currentBytes, mode: mode)
      // A replacement can be shorter than the cached block, including at a fetch
      // boundary. Invalidate and decode the available bytes before declining it.
      if currentBytes.count == byteCount, generation == cached.codeGeneration {
        byteValidationHitCount &+= 1
        try protectValidatedGuestCode(
          at: guestStart,
          byteCount: byteCount,
          memoryCodeGeneration: memoryGeneration,
          memory: memory
        )
        if cached.key == key {
          cached.memoryCodeGeneration = memoryGeneration
          return cached
        }
        // Physical-code sharing may return a block owned by another address-space lookup key.
        // Preserve the established replacement semantics while retaining links only for an
        // in-place generation refresh of the exact same resident.
        let resident = ResidentBlock(
          key: key,
          block: cached.block,
          offset: cached.offset,
          codeGeneration: cached.codeGeneration,
          memoryCodeGeneration: memoryGeneration,
          endsTimeBoundary: cached.endsTimeBoundary,
          cr3WriteSourceRegister: cached.cr3WriteSourceRegister
        )
        try publish(resident, for: key)
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
    let pageBoundedFetch = physicalRIPProvider != nil || memory is DoryX86TranslatedMemory
    let bytes = try speculativeInstructionBytes(
      using: byteProvider,
      maximumCount: pageBoundedFetch
        ? Self.maximumResidentFetchByteCount(
          at: guestStart,
          instructionBudget: compilationInstructionBudget
        )
        : compilationInstructionBudget * 15
    )
    let compilation = try compileResident(
      key: key,
      bytes: bytes,
      codeGenerationProvider: codeGenerationProvider,
      guestStart: guestStart,
      mode: mode,
      maximumInstructions: compilationInstructionBudget,
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
    do { return try provider(maximumCount) } catch is DoryX86MemoryError {
      // Guest fetch failures decline native execution, including when a preceding
      // block in the chain already committed stores. The caller publishes that
      // prefix before the interpreter retries the fetch at the faulting RIP.
      return []
    }
  }

  static func maximumResidentFetchByteCount(
    at guestStart: UInt64,
    instructionBudget: Int
  ) -> Int {
    precondition(instructionBudget > 0)
    let pageOffset = Int(guestStart & UInt64(instructionPageByteCount - 1))
    let bytesUntilPageBoundary = instructionPageByteCount - pageOffset
    return min(instructionBudget * 15, bytesUntilPageBoundary)
  }

  private func codeCacheGenerationRange(_ generation: Int) -> Range<Int> {
    precondition((0..<Self.codeCacheGenerationCount).contains(generation))
    let boundary = (region.capacity / Self.codeCacheGenerationCount) & ~3
    return generation == 0 ? 0..<boundary : boundary..<region.capacity
  }

  /// Switches to the other half of the bounded executable region and retires only blocks whose
  /// machine code will be overwritten. Retained-generation links remain live; links crossing into
  /// the recycled range are restored by normal resident retirement before publication resumes.
  private func rotateCodeCacheGeneration() {
    let nextGeneration = (activeCodeCacheGeneration + 1) % Self.codeCacheGenerationCount
    let recycledRange = codeCacheGenerationRange(nextGeneration)
    let recycledKeys = residentSlots.compactMap { slot -> LookupKey? in
      guard let slot, recycledRange.contains(slot.resident.offset) else { return nil }
      return slot.key
    }
    for key in recycledKeys { removeResident(for: key) }
    codeCacheEvictedBlockCount &+= UInt64(recycledKeys.count)
    codeCacheGenerationNextOffsets[nextGeneration] = recycledRange.lowerBound
    activeCodeCacheGeneration = nextGeneration
    // Raw predictor targets and recorded trace offsets are generation-wide derived state. Clear
    // them on every rotation while preserving resident blocks in the newer half.
    nativeTraces = .init(repeating: nil, count: nativeTraces.count)
    negativeEntries = .init(repeating: nil, count: negativeEntries.count)
    indirectBranchTargetCache.removeAll()
    shadowReturnStack.removeAll()
    codeCacheEpoch &+= 1
    codeCacheWrapCount &+= 1
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
    // Reject feature-dependent integer operations before optimization can erase them
    // and before any block prefix executes. The immutable profile applies to every
    // resident/shared/trace cache in this executor, so a masked profile cannot reuse
    // code compiled with the corresponding feature enabled.
    if !profile.supports(.cmov),
      translated.statements.contains(where: {
        if case .conditionalMove = $0 { return true }
        return false
      })
    {
      return .init(resident: nil, emitterDeclineByteCount: nil, declineReason: nil)
    }
    if translated.statements.contains(where: {
      guard case .compareExchangePair(_, let doubleQuadword) = $0 else { return false }
      return !profile.supports(doubleQuadword ? .cmpxchg16b : .cmpxchg8b)
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
    if mode == .long64,
      block.statements.contains(where: {
        switch $0 {
        case .loadFlagsIntoAH, .storeAHIntoFlags: true
        default: false
        }
      }),
      !profile.supports(.lahf64)
    {
      // The interpreter owns the precise #UD path when LAHF/SAHF is not advertised in long mode.
      return .init(resident: nil, emitterDeclineByteCount: nil, declineReason: nil)
    }
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
    if mode != .long64 || key.privilegeLevel != 0,
      block.statements.contains(where: {
        switch $0 {
        case .readControlRegister, .writeControlRegister, .swapGS: return true
        default: return false
        }
      })
    {
      return .init(resident: nil, emitterDeclineByteCount: nil, declineReason: nil)
    }
    if key.privilegeLevel != 0,
      block.statements.contains(where: {
        switch $0 {
        case .compareExchange, .compareExchangePair: return true
        default: return false
        }
      })
    {
      return .init(resident: nil, emitterDeclineByteCount: nil, declineReason: nil)
    }
    if key.privilegeLevel != 0,
      block.statements.contains(where: {
        switch $0 {
        case .unsignedAccumulatorMultiply, .unsignedAccumulatorDivide, .signedAccumulatorDivide,
          .doubleShiftRightCL,
          .doubleShiftRightImmediate, .bitTestMemoryRegister, .bitTestMemoryImmediate,
          .atomicBitTestMemory:
          return true
        default:
          return false
        }
      })
    {
      return .init(resident: nil, emitterDeclineByteCount: nil, declineReason: nil)
    }
    let tier1Compiled: DoryARM64CompiledBlock?
    if tier1Enabled {
      tier1CompilationAttemptCount &+= 1
      tier1Compiled = tier1Emitter.compile(block)
      if tier1Compiled == nil { tier1CompilationDeclineCount &+= 1 }
    } else {
      tier1Compiled = nil
    }
    let compiled = tier1Compiled
      ?? emitter.compile(
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
    guard byteCount <= codeCacheGenerationRange(activeCodeCacheGeneration).count else {
      return .init(resident: nil, emitterDeclineByteCount: nil, declineReason: nil)
    }
    let activeRange = codeCacheGenerationRange(activeCodeCacheGeneration)
    if codeCacheGenerationNextOffsets[activeCodeCacheGeneration] > activeRange.upperBound - byteCount {
      rotateCodeCacheGeneration()
    }
    let offset = codeCacheGenerationNextOffsets[activeCodeCacheGeneration]
    try region.publish(compiled, at: offset)
    codeCacheGenerationNextOffsets[activeCodeCacheGeneration] += byteCount
    let guestBytes = Array(bytes.prefix(Int(compiled.guestByteCount)))
    let memoryCodeGeneration = readCodeGeneration(
      using: codeGenerationProvider,
      byteCount: guestBytes.count
    )
    try protectValidatedGuestCode(
      at: guestStart,
      byteCount: guestBytes.count,
      memoryCodeGeneration: memoryCodeGeneration,
      memory: memory
    )
    let resident = ResidentBlock(
      key: key,
      block: compiled,
      offset: offset,
      codeGeneration: Self.fingerprint(bytes: guestBytes, mode: mode),
      memoryCodeGeneration: memoryCodeGeneration,
      endsTimeBoundary: Self.endsTimeBoundary(block),
      cr3WriteSourceRegister: Self.cr3WriteSourceRegister(block)
    )
    try publish(resident, for: key)
    compiledBlockCount &+= 1
    if compiled.tier == .tier1 { tier1CompiledBlockCount &+= 1 }
    return .init(resident: resident, emitterDeclineByteCount: nil, declineReason: nil)
  }

  /// Restores write protection whenever native code becomes lookup-visible after compilation or
  /// byte revalidation. A generation mismatch can be caused by a write elsewhere in the same
  /// host allocation granule; if the block's bytes are unchanged, republishing it without this
  /// boundary leaves the page writable. A previously filled write-TLB entry could then mutate the
  /// block without advancing its generation, allowing stale native code to execute.
  private func protectValidatedGuestCode(
    at guestStart: UInt64,
    byteCount: Int,
    memoryCodeGeneration: UInt64?,
    memory: (any DoryX86Memory)?
  ) throws {
    guard memoryCodeGeneration != nil else { return }
    let changedCodeProtection: Bool
    if let translatedMemory = memory as? DoryX86TranslatedMemory {
      changedCodeProtection = try translatedMemory.protectTranslatedCode(
        at: guestStart,
        byteCount: byteCount
      )
    } else if let protector = memory as? any DoryX86TranslatedCodeProtectionMemory {
      changedCodeProtection = try protector.protectTranslatedCode(
        at: guestStart,
        byteCount: byteCount
      )
    } else {
      changedCodeProtection = false
    }
    if changedCodeProtection {
      // A write entry may have been filled while this host page was writable. Revoke it before
      // any generated store can encounter the newly read-only host allocation granule.
      invalidateAllTranslations()
      recordCodeProtectionGeneration(for: memory)
    }
  }

  private func codeProtectionState(
    for memory: (any DoryX86Memory)?
  ) -> (identity: ObjectIdentifier, generation: UInt64)? {
    guard let memory else { return nil }
    if let translatedMemory = memory as? DoryX86TranslatedMemory {
      guard translatedMemory.hasTranslatedCodeProtection else { return nil }
      return (
        ObjectIdentifier(translatedMemory), translatedMemory.translatedCodeProtectionGeneration
      )
    }
    guard let protector = memory as? any DoryX86TranslatedCodeProtectionMemory else { return nil }
    return (ObjectIdentifier(protector), protector.translatedCodeProtectionGeneration)
  }

  private func synchronizeCodeProtection(for memory: (any DoryX86Memory)?) {
    guard let state = codeProtectionState(for: memory) else { return }
    if let previous = codeProtectionGenerations[state.identity], previous != state.generation {
      invalidateAllTranslations()
      invalidateGeneratedTargetPredictions()
    }
    codeProtectionGenerations[state.identity] = state.generation
  }

  private func recordCodeProtectionGeneration(for memory: (any DoryX86Memory)?) {
    guard let state = codeProtectionState(for: memory) else { return }
    codeProtectionGenerations[state.identity] = state.generation
  }

  private static func endsTimeBoundary(_ block: DoryIRBasicBlock) -> Bool {
    block.statements.contains {
      switch $0 {
      case .readTimestampCounter, .writeControlRegister: true
      default: false
      }
    }
  }

  private static func cr3WriteSourceRegister(_ block: DoryIRBasicBlock) -> Int? {
    guard block.statements.count == 1,
      case .writeControlRegister(3, let source) = block.statements[0],
      source.bank == "x86.gpr", source.width == .i64, source.index < 16
    else { return nil }
    return Int(source.index)
  }

  private func canExecute(
    _ resident: ResidentBlock,
    context: UnsafeMutableBufferPointer<UInt64>
  ) -> Bool {
    guard let source = resident.cr3WriteSourceRegister else { return true }
    let value = context[source]
    // The measured native path intentionally excludes PCID's no-flush form. The interpreter
    // remains the authority for that path and for its feature-dependent validation.
    guard value & (UInt64(1) << 63) == 0 else { return false }
    let addressMask = ((UInt64(1) << physicalAddressBits) - 1) & ~UInt64(0xfff)
    return value & ~addressMask & ~UInt64(0xfff) == 0
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
    physicalStart: UInt64,
    addressSpaceID: UInt64,
    mode: DoryX86ExecutionMode,
    state: DoryX86ArchitecturalState
  ) -> LookupKey {
    LookupKey(
      guestStart: guestStart,
      physicalStart: physicalStart,
      addressSpaceID: addressSpaceID,
      executionMode: mode,
      privilegeLevel: UInt8(state.cs.selector & 3),
      pagingEnabled: state.control.cr0 & (1 << 31) != 0
    )
  }

  private func resolvePhysicalStart(
    at guestStart: UInt64,
    using provider: ((_ guestStart: UInt64) throws -> UInt64?)?
  ) -> UInt64? {
    guard let provider else { return guestStart }
    do { return try provider(guestStart) } catch { return nil }
  }

  private func blockCacheKey(from key: LookupKey) -> DoryJITBlockCacheKey {
    .init(
      physicalRIP: key.physicalStart,
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
      guard
        (try? codeGenerationProvider(validation.guestStart, validation.guestByteCount))
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
    return .executed(
      NativeReplay(
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
      let tier = entries.first?.resident.block.tier,
      entries.allSatisfy({
        $0.codeCacheEpoch == codeCacheEpoch && $0.resident.block.tier == tier
      })
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
    let slotValue: UInt64?
    do {
      slotValue = try blockCache.lookup(blockCacheKey(from: key))
    } catch {
      lookupMissCount &+= 1
      return nil
    }
    guard let slotValue, slotValue <= UInt64(residentSlots.count),
      let slot = residentSlots[Int(slotValue - 1)],
      // Existing emitters still encode virtual RIP-relative semantics. Physical identity permits
      // CR3 reuse for the same virtual mapping; a differently based alias must be recompiled until
      // A05.4 side tables make emitted blocks fully relocatable.
      slot.resident.block.guestStart == key.guestStart
    else {
      lookupMissCount &+= 1
      return nil
    }
    blockCacheLookupHitCount &+= 1
    recentEntries[index] = .init(key: key, resident: slot.resident)
    return slot.resident
  }

  private func canInitiateRuntimeChain(_ resident: ResidentBlock) -> Bool {
    resident.block.chainSlots != nil
      && !resident.endsTimeBoundary
  }

  private func canBeRuntimeChainTarget(
    _ resident: ResidentBlock,
    memoryCallbacksAvailable: Bool
  ) -> Bool {
    canInitiateRuntimeChain(resident)
      // Multi-access blocks still need a block-local restartable-read policy. Single-access
      // callback targets share the chain's recovery context and are safe after A05.4.
      && !resident.block.requiresRestartableMemoryReads
      && (!resident.block.requiresMemoryCallbacks || memoryCallbacksAvailable)
      && (!resident.block.mayExitToInterpreter || resident.block.tier == .tier1)
  }

  private func residentForExecutedChainSource(
    guestRIP: UInt64,
    entryResident: ResidentBlock,
    physicalRIPProvider: ((_ guestStart: UInt64) throws -> UInt64?)?,
    addressSpaceID: UInt64,
    mode: DoryX86ExecutionMode,
    state: DoryX86ArchitecturalState
  ) -> ResidentBlock? {
    if entryResident.block.guestStart == guestRIP { return entryResident }
    guard let physicalStart = resolvePhysicalStart(at: guestRIP, using: physicalRIPProvider) else {
      return nil
    }
    return lookupResident(
      for: makeLookupKey(
        guestStart: guestRIP,
        physicalStart: physicalStart,
        addressSpaceID: addressSpaceID,
        mode: mode,
        state: state
      ))
  }

  private func installDirectChain(
    from source: ResidentBlock,
    to target: ResidentBlock,
    destinationGuestRIP: UInt64,
    memoryCallbacksAvailable: Bool
  ) {
    guard canInitiateRuntimeChain(source),
      canBeRuntimeChainTarget(target, memoryCallbacksAvailable: memoryCallbacksAvailable),
      source.block.tier == target.block.tier,
      let slot = source.block.chainSlots?.first(where: {
        $0.targetGuestRIP == destinationGuestRIP
      })
    else { return }
    if let existing = source.outgoingLinks[slot.machineWordIndex] {
      if existing.target === target { return }
      unlinkDirectChain(existing)
    }
    let slotOffset = source.offset + slot.machineWordIndex * MemoryLayout<UInt32>.size
    guard (try? region.patchDirectBranch(at: slotOffset, to: target.offset)) != nil else { return }
    let link = ChainLink(source: source, target: target, slot: slot)
    source.outgoingLinks[slot.machineWordIndex] = link
    target.incomingLinks.append(link)
    directChainPatchCount &+= 1
  }

  private func fillIndirectBranchTargetCache(
    from source: ResidentBlock,
    to target: ResidentBlock,
    destinationGuestRIP: UInt64,
    memoryCallbacksAvailable: Bool
  ) {
    guard source.block.chainSlots?.isEmpty == true,
      canBeRuntimeChainTarget(target, memoryCallbacksAvailable: memoryCallbacksAvailable),
      source.block.tier == target.block.tier,
      target.block.guestStart == destinationGuestRIP,
      let hostAddress = region.entryAddress(at: target.offset)
    else { return }
    try? indirectBranchTargetCache.fill(
      guestRIP: destinationGuestRIP,
      generation: codeCacheEpoch &+ 1,
      hostAddress: hostAddress
    )
  }

  /// Validates every already-linked target before the entry block can reach it without another
  /// Swift boundary. Explicit invalidation normally removes stale targets eagerly; this check
  /// preserves the older generation/byte-provider contract for callers that mutate code between
  /// dispatches and report that change only through their providers.
  private func validateDirectChainTargets(
    reachableFrom entry: ResidentBlock,
    byteProvider: (_ guestStart: UInt64, _ maximumCount: Int) throws -> [UInt8],
    codeGenerationProvider: ((_ guestStart: UInt64, _ byteCount: Int) throws -> UInt64?)?,
    mode: DoryX86ExecutionMode,
    memory: (any DoryX86Memory)?
  ) {
    var pending = [entry]
    var visited = Set<ObjectIdentifier>()
    while let source = pending.popLast() {
      guard visited.insert(ObjectIdentifier(source)).inserted else { continue }
      for link in Array(source.outgoingLinks.values) {
        guard let target = link.target else {
          unlinkDirectChain(link)
          continue
        }
        let key = target.key
        let byteCount = Int(target.block.guestByteCount)
        let currentGeneration = readCodeGeneration(
          using: codeGenerationProvider.map { provider in
            { try provider(target.block.guestStart, $0) }
          },
          byteCount: byteCount
        )
        if let residentGeneration = target.memoryCodeGeneration,
          residentGeneration == currentGeneration
        {
          pending.append(target)
          continue
        }
        guard
          let currentBytes = try? byteProvider(target.block.guestStart, byteCount),
          currentBytes.count == byteCount,
          Self.fingerprint(bytes: currentBytes, mode: mode) == target.codeGeneration
        else {
          removeResident(for: key)
          continue
        }
        do {
          try protectValidatedGuestCode(
            at: target.block.guestStart,
            byteCount: byteCount,
            memoryCodeGeneration: currentGeneration,
            memory: memory
          )
          target.memoryCodeGeneration = currentGeneration
          pending.append(target)
        } catch {
          removeResident(for: key)
        }
      }
    }
  }

  private func unlinkDirectChain(_ link: ChainLink) {
    guard let source = link.source else {
      link.target?.incomingLinks.removeAll { $0 === link }
      return
    }
    let fallbackOffset =
      source.offset + link.slot.fallbackWordIndex * MemoryLayout<UInt32>.size
    let slotOffset = source.offset + link.slot.machineWordIndex * MemoryLayout<UInt32>.size
    do {
      try region.patchDirectBranch(at: slotOffset, to: fallbackOffset)
    } catch {
      preconditionFailure("resident chain slot could not be restored: \(error)")
    }
    source.outgoingLinks[link.slot.machineWordIndex] = nil
    link.target?.incomingLinks.removeAll { $0 === link }
    directChainUnlinkCount &+= 1
  }

  /// Drops generated raw-code targets after protected guest code becomes writable. Resident
  /// blocks remain cached and are revalidated lazily at their next dispatcher lookup.
  private func invalidateGeneratedTargetPredictions() {
    for slot in residentSlots {
      guard let resident = slot?.resident else { continue }
      for link in Array(resident.outgoingLinks.values) { unlinkDirectChain(link) }
    }
    indirectBranchTargetCache.removeAll()
    shadowReturnStack.removeAll()
  }

  private func retireResident(_ resident: ResidentBlock) {
    for link in Array(resident.incomingLinks) { unlinkDirectChain(link) }
    for link in Array(resident.outgoingLinks.values) { unlinkDirectChain(link) }
    resident.incomingLinks.removeAll(keepingCapacity: false)
    resident.outgoingLinks.removeAll(keepingCapacity: false)
    // Indirect entries contain raw host addresses rather than resident ownership links. Clearing
    // the small per-vCPU table makes every possible reference to retired code miss immediately.
    indirectBranchTargetCache.removeAll()
    shadowReturnStack.removeAll()
  }

  private func publish(_ resident: ResidentBlock, for key: LookupKey) throws {
    let slot = ResidentSlot(key: key, resident: resident)
    let slotIndex: Int
    let appended: Bool
    if let recycled = freeResidentSlotIndices.popLast() {
      precondition(residentSlots[recycled] == nil)
      residentSlots[recycled] = slot
      slotIndex = recycled
      appended = false
    } else {
      slotIndex = residentSlots.count
      residentSlots.append(slot)
      appended = true
    }
    let slotValue = UInt64(slotIndex + 1)
    do {
      if let replaced = try blockCache.insert(blockCacheKey(from: key), value: slotValue),
        replaced <= UInt64(residentSlots.count)
      {
        let replacedIndex = Int(replaced - 1)
        if replacedIndex != slotIndex {
          if let replacedSlot = residentSlots[replacedIndex] {
            let recent = recentIndex(for: replacedSlot.key)
            if recentEntries[recent]?.key == replacedSlot.key { recentEntries[recent] = nil }
            let replacedResident = replacedSlot.resident
            retireResident(replacedResident)
          }
          residentSlots[replacedIndex] = nil
          freeResidentSlotIndices.append(replacedIndex)
        }
      }
    } catch {
      if appended {
        residentSlots.removeLast()
      } else {
        residentSlots[slotIndex] = nil
        freeResidentSlotIndices.append(slotIndex)
      }
      throw error
    }
    recentEntries[recentIndex(for: key)] = .init(key: key, resident: resident)
  }

  private func removeResident(for key: LookupKey) {
    if let removed = try? blockCache.remove(blockCacheKey(from: key)),
      removed <= UInt64(residentSlots.count)
    {
      let removedIndex = Int(removed - 1)
      if let removedResident = residentSlots[removedIndex]?.resident {
        retireResident(removedResident)
      }
      residentSlots[removedIndex] = nil
      freeResidentSlotIndices.append(removedIndex)
    }
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

  static func populateExecutionContext(
    _ context: UnsafeMutableBufferPointer<UInt64>,
    from state: DoryX86ArchitecturalState,
    memory: (any DoryX86Memory)?,
    translationTLB: DoryX86JITTLB? = nil,
    addressSpaceGeneration: UInt64 = 0,
    indirectBranchTargetCache: DoryJITIndirectBranchTargetCache? = nil,
    shadowReturnStack: DoryJITShadowReturnStack? = nil,
    codeCacheGeneration: UInt64 = 0,
    preservePendingWork: Bool = false
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
    context[21] = UInt64(state.cs.selector)
    context[22] = UInt64(state.ds.selector)
    context[23] = UInt64(state.es.selector)
    context[24] = UInt64(state.fs.selector)
    context[25] = UInt64(state.gs.selector)
    context[26] = UInt64(state.ss.selector)
    context[DoryJITExecutableRegion.hostAddressSpaceBaseWordIndex] =
      (memory as? any DoryX86HostAddressSpaceMemory)?.hostAddressSpaceBase ?? 0
    context[DoryJITExecutableRegion.readTLBBaseWordIndex] =
      translationTLB?.entriesBaseAddress(for: .read) ?? 0
    context[DoryJITExecutableRegion.writeTLBBaseWordIndex] =
      translationTLB?.entriesBaseAddress(for: .write) ?? 0
    context[DoryJITExecutableRegion.executeTLBBaseWordIndex] =
      translationTLB?.entriesBaseAddress(for: .execute) ?? 0
    context[DoryJITExecutableRegion.tlbEntryMaskWordIndex] =
      translationTLB.map { UInt64($0.entryCount - 1) } ?? 0
    context[DoryJITExecutableRegion.tlbAddressSpaceGenerationWordIndex] =
      translationTLB == nil ? 0 : addressSpaceGeneration
    context[DoryJITExecutableRegion.hostAddressSpaceByteCountWordIndex] =
      UInt64((memory as? any DoryX86HostAddressSpaceMemory)?.hostAddressSpaceByteCount ?? 0)
    context[DoryJITExecutableRegion.tlbStorageWordIndex] = translationTLB?.storageAddress ?? 0
    context[DoryJITExecutableRegion.tlbResolverWordIndex] =
      translationTLB == nil ? 0 : UInt64(dory_jit_tlb_resolve_from_context_address())
    context[DoryJITExecutableRegion.readTLBHitCounterWordIndex] =
      translationTLB?.inlineHitCounterAddress(for: .read) ?? 0
    context[DoryJITExecutableRegion.writeTLBHitCounterWordIndex] =
      translationTLB?.inlineHitCounterAddress(for: .write) ?? 0
    context[DoryJITExecutableRegion.atomicCompareExchangeWordIndex] =
      translationTLB == nil
      ? 0 : UInt64(dory_jit_atomic_compare_exchange_from_context_address())
    context[DoryJITExecutableRegion.atomicExchangeWordIndex] =
      translationTLB == nil ? 0 : UInt64(dory_jit_atomic_exchange_from_context_address())
    context[DoryJITExecutableRegion.atomicFetchAddWordIndex] =
      translationTLB == nil ? 0 : UInt64(dory_jit_atomic_fetch_add_from_context_address())
    context[DoryJITExecutableRegion.atomicRMWWordIndex] =
      translationTLB == nil ? 0 : UInt64(dory_jit_atomic_rmw_from_context_address())
    context[DoryJITExecutableRegion.atomicCompareExchangePairWordIndex] =
      translationTLB == nil
      ? 0 : UInt64(dory_jit_atomic_compare_exchange_pair_from_context_address())
    context[DoryARM64Tier1ABI.ContextWord.lazyFlagsOperation.rawValue] =
      DoryARM64LazyFlagsState.Operation.materialized.rawValue
    context[DoryARM64Tier1ABI.ContextWord.lazyFlagsWidth.rawValue] =
      UInt64(DoryIRIntegerWidth.i64.rawValue)
    context[DoryARM64Tier1ABI.ContextWord.lazyFlagsResult.rawValue] = 0
    context[DoryARM64Tier1ABI.ContextWord.lazyFlagsSource1.rawValue] = 0
    context[DoryARM64Tier1ABI.ContextWord.lazyFlagsSource2.rawValue] = 0
    context[DoryARM64Tier1ABI.ContextWord.lazyFlagsMaterializer.rawValue] =
      doryARM64LazyFlagsMaterializerAddress()
    context[DoryARM64Tier1ABI.ContextWord.lazyFlagsMaterializationCount.rawValue] = 0
    context[DoryARM64Tier1ABI.ContextWord.cr3.rawValue] = state.control.cr3
    context[DoryARM64Tier1ABI.ContextWord.kernelGSBase.rawValue] =
      state.modelSpecific.kernelGSBase
    context[DoryARM64Tier1ABI.ContextWord.swapGSPerformed.rawValue] = 0
    context[DoryARM64Tier1ABI.ContextWord.cr3WritePerformed.rawValue] = 0
    context[DoryARM64Tier1ABI.ContextWord.chainEnabled.rawValue] = 0
    context[DoryARM64Tier1ABI.ContextWord.chainRemainingInstructions.rawValue] = 0
    context[DoryARM64Tier1ABI.ContextWord.chainRetiredInstructions.rawValue] = 0
    context[DoryARM64Tier1ABI.ContextWord.chainRetiredBlocks.rawValue] = 0
    context[DoryARM64Tier1ABI.ContextWord.chainLastGuestRIP.rawValue] = 0
    context[DoryJITExecutableRegion.ibtcEntriesBaseWordIndex] =
      indirectBranchTargetCache?.entriesBaseAddress ?? 0
    context[DoryJITExecutableRegion.ibtcEntryMaskWordIndex] =
      indirectBranchTargetCache?.entryMask ?? 0
    context[DoryJITExecutableRegion.ibtcGenerationWordIndex] =
      indirectBranchTargetCache == nil ? 0 : codeCacheGeneration
    context[DoryARM64Tier1ABI.ContextWord.ibtcInlineHits.rawValue] = 0
    context[DoryARM64Tier1ABI.ContextWord.ibtcInlineMisses.rawValue] = 0
    context[DoryJITExecutableRegion.shadowReturnEntriesBaseWordIndex] =
      shadowReturnStack?.entriesBaseAddress ?? 0
    context[DoryJITExecutableRegion.shadowReturnEntryMaskWordIndex] =
      shadowReturnStack?.entryMask ?? 0
    context[DoryJITExecutableRegion.shadowReturnTopAddressWordIndex] =
      shadowReturnStack?.topAddress ?? 0
    context[DoryJITExecutableRegion.shadowReturnGenerationWordIndex] =
      shadowReturnStack == nil ? 0 : codeCacheGeneration
    context[DoryARM64Tier1ABI.ContextWord.shadowReturnHits.rawValue] = 0
    context[DoryARM64Tier1ABI.ContextWord.shadowReturnMisses.rawValue] = 0
    context[DoryARM64Tier1ABI.ContextWord.shadowReturnPushes.rawValue] = 0
    if !preservePendingWork {
      context[DoryARM64Tier1ABI.ContextWord.pendingWork.rawValue] = 0
    }
    context[DoryARM64Tier1ABI.ContextWord.hostFramePointer.rawValue] = 0
    context[DoryARM64Tier1ABI.ContextWord.hostReturnAddress.rawValue] = 0
    context[DoryARM64Tier1ABI.ContextWord.inlineTLBFaultHostPC.rawValue] = 0
    context[DoryARM64Tier1ABI.ContextWord.memoryFaultCheckpointActive.rawValue] = 0
    context[DoryARM64Tier1ABI.ContextWord.memoryFaultCheckpointRegisterMask.rawValue] = 0
  }

  private func recordLazyFlagMaterializations(
    in context: UnsafeMutableBufferPointer<UInt64>
  ) {
    let index = DoryARM64Tier1ABI.ContextWord.lazyFlagsMaterializationCount.rawValue
    lazyFlagMaterializationCount &+= context[index]
    context[index] = 0
  }

  private func recordIndirectBranchTargetCacheLookups(
    in context: UnsafeMutableBufferPointer<UInt64>
  ) {
    let hitIndex = DoryARM64Tier1ABI.ContextWord.ibtcInlineHits.rawValue
    let missIndex = DoryARM64Tier1ABI.ContextWord.ibtcInlineMisses.rawValue
    indirectBranchTargetCacheHitCount &+= context[hitIndex]
    indirectBranchTargetCacheMissCount &+= context[missIndex]
    context[hitIndex] = 0
    context[missIndex] = 0
  }

  private func recordShadowReturnStackActivity(
    in context: UnsafeMutableBufferPointer<UInt64>
  ) {
    let hitIndex = DoryARM64Tier1ABI.ContextWord.shadowReturnHits.rawValue
    let missIndex = DoryARM64Tier1ABI.ContextWord.shadowReturnMisses.rawValue
    let pushIndex = DoryARM64Tier1ABI.ContextWord.shadowReturnPushes.rawValue
    shadowReturnStackHitCount &+= context[hitIndex]
    shadowReturnStackMissCount &+= context[missIndex]
    shadowReturnStackPushCount &+= context[pushIndex]
    context[hitIndex] = 0
    context[missIndex] = 0
    context[pushIndex] = 0
  }

  /// Publishes a fully materialized architectural state at every Swift/dispatcher boundary. The
  /// PC run loop checks and delivers interrupts only after such a return, so an interrupt consumer
  /// can never observe the tier-1-private lazy descriptor. Count this final materialization along
  /// with in-code materializer calls so the diagnostic is a complete rate rather than a helper-only
  /// subset.
  private func publishExecutionContext(
    _ context: UnsafeMutableBufferPointer<UInt64>,
    to state: inout DoryX86ArchitecturalState,
    memory: (any DoryX86Memory)?
  ) {
    recordLazyFlagMaterializations(in: context)
    if let lazyFlags = DoryARM64LazyFlagsState(context: context),
      lazyFlags.operation != .materialized
    {
      lazyFlagMaterializationCount &+= 1
    }
    let wroteCR3 = Self.apply(context: context, to: &state)
    if wroteCR3 {
      (memory as? DoryX86TranslatedMemory)?.translationUnit.invalidateAll()
      invalidateAllTranslations()
    }
  }

  @discardableResult private static func apply(
    context: UnsafeMutableBufferPointer<UInt64>,
    to state: inout DoryX86ArchitecturalState
  ) -> Bool {
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
    state.rflags =
      DoryARM64LazyFlagsState(context: context)?.materialize()
      ?? DoryX86RFLAGS(rawValue: context[17])
    if context[DoryARM64Tier1ABI.ContextWord.swapGSPerformed.rawValue] != 0 {
      state.gs.base = context[DoryARM64Tier1ABI.ContextWord.gsBase.rawValue]
      state.modelSpecific.gsBase = state.gs.base
      state.modelSpecific.kernelGSBase =
        context[DoryARM64Tier1ABI.ContextWord.kernelGSBase.rawValue]
    }
    let wroteCR3 = context[DoryARM64Tier1ABI.ContextWord.cr3WritePerformed.rawValue] != 0
    if wroteCR3 {
      state.control.cr3 = context[DoryARM64Tier1ABI.ContextWord.cr3.rawValue]
    }
    return wroteCR3
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
