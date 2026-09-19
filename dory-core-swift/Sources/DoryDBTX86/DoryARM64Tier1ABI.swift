/// Normative register and context convention for the ARM64 tier-1 DBT.
///
/// The current baseline emitter still enters through the C ABI and treats the
/// architectural context as memory. Tier-1 uses this convention internally;
/// `ABI.md` defines its entry, exit, and helper-boundary rules.
enum DoryARM64Tier1ABI {
  typealias HostRegister = UInt32

  /// Architectural RAX, RCX, RDX, RBX, RSP, RBP, RSI, RDI, R8...R15.
  static let guestRegisterMap: [HostRegister] = (0...15).map(HostRegister.init)
  static let scratchRegisters: [HostRegister] = [16, 17]
  static let platformReservedRegister: HostRegister = 18
  static let dispatcherRegisters: [HostRegister] = [19, 20, 21, 22, 23, 24]
  static let lazyFlagsRegisters: [HostRegister] = [25, 26]
  static let guestRIPRegister: HostRegister = 27
  static let contextRegister: HostRegister = 28
  static let framePointerRegister: HostRegister = 29
  static let linkRegister: HostRegister = 30
  static let stackPointerRegister: HostRegister = 31

  /// C helper calls may overwrite x0...x18. Because every pinned guest GPR is
  /// in that range, a shim spills precisely the live guest subset before BLR.
  static func helperSpillRegisters(liveGuestMask: UInt16) -> [HostRegister] {
    guestRegisterMap.enumerated().compactMap { index, register in
      liveGuestMask & (UInt16(1) << UInt16(index)) == 0 ? nil : register
    }
  }

  enum ContextWord: Int, CaseIterable {
    case rax = 0
    case rcx
    case rdx
    case rbx
    case rsp
    case rbp
    case rsi
    case rdi
    case r8
    case r9
    case r10
    case r11
    case r12
    case r13
    case r14
    case r15
    case rip
    case rflags
    case fsBase
    case gsBase
    case tsc
    case csSelector
    case dsSelector
    case esSelector
    case fsSelector
    case gsSelector
    case ssSelector
    case hostAddressSpaceBase
    case readTLBBase
    case writeTLBBase
    case executeTLBBase
    case tlbEntryMask
    case tlbAddressSpaceGeneration
    case hostAddressSpaceByteCount
    case tlbStorage
    case tlbResolver
    case readTLBHitCounter
    case writeTLBHitCounter
    case atomicCompareExchange
    case atomicExchange
    case atomicFetchAdd
    case atomicRMW
    case atomicCompareExchangePair
    case lazyFlagsOperation
    case lazyFlagsWidth
    case lazyFlagsResult
    case lazyFlagsSource1
    case lazyFlagsSource2
    case lazyFlagsMaterializer
    case lazyFlagsMaterializationCount
    case cr3
    case kernelGSBase
    case swapGSPerformed
    case cr3WritePerformed
    case chainEnabled
    case chainRemainingInstructions
    case chainRetiredInstructions
    case chainRetiredBlocks
    case chainLastGuestRIP
    case ibtcEntriesBase
    case ibtcEntryMask
    case ibtcGeneration
    case ibtcInlineHits
    case ibtcInlineMisses
    case shadowReturnEntriesBase
    case shadowReturnEntryMask
    case shadowReturnTopAddress
    case shadowReturnGeneration
    case shadowReturnHits
    case shadowReturnMisses
    case shadowReturnPushes
    case pendingWork
    /// Original host control state for memory-capable generated blocks. These words are
    /// refreshed on every entry and deliberately live outside the generated stack frame.
    case hostFramePointer
    case hostReturnAddress
    /// Generated BLR return PC for an architectural inline-TLB page-fault exit.
    case inlineTLBFaultHostPC
    /// A memory-writing instruction checkpoints only the architectural fields it may change
    /// before its final transactional store. This includes write-bearing terminators such as
    /// CALL, whose stack-pointer update precedes the return-address write.
    case memoryFaultCheckpointActive
    case memoryFaultCheckpointRegisterMask
    case memoryFaultCheckpointRFlags
    case memoryFaultCheckpointRAX
    case memoryFaultCheckpointRCX
    case memoryFaultCheckpointRDX
    case memoryFaultCheckpointRBX
    case memoryFaultCheckpointRSP
    case memoryFaultCheckpointRBP
    case memoryFaultCheckpointRSI
    case memoryFaultCheckpointRDI
    case memoryFaultCheckpointR8
    case memoryFaultCheckpointR9
    case memoryFaultCheckpointR10
    case memoryFaultCheckpointR11
    case memoryFaultCheckpointR12
    case memoryFaultCheckpointR13
    case memoryFaultCheckpointR14
    case memoryFaultCheckpointR15
    /// Selected by each generated memory-bearing block on entry so a raw chain target does not
    /// inherit the dispatcher entry block's replay policy.
    case requiresRestartableMemoryReads
    /// Unretained `DoryX86AtomicCoordinator` reference, installed only for the duration of a
    /// memory-capable native dispatch. This is append-only so every prior ABI word stays stable.
    case atomicCoordinator

    var byteOffset: Int { rawValue * MemoryLayout<UInt64>.stride }
  }

  static let contextWordCount = ContextWord.allCases.count
}
