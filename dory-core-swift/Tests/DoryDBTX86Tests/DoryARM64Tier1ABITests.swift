import Testing

@testable import DoryDBTX86

@Suite struct DoryARM64Tier1ABITests {
  @Test func registerConventionIsInjectiveAndReservesDarwinPlatformState() {
    #expect(DoryARM64Tier1ABI.guestRegisterMap == (0...15).map(UInt32.init))
    #expect(DoryARM64Tier1ABI.scratchRegisters == [16, 17])
    #expect(DoryARM64Tier1ABI.platformReservedRegister == 18)
    #expect(DoryARM64Tier1ABI.dispatcherRegisters == [19, 20, 21, 22, 23, 24])
    #expect(DoryARM64Tier1ABI.lazyFlagsRegisters == [25, 26])
    #expect(DoryARM64Tier1ABI.guestRIPRegister == 27)
    #expect(DoryARM64Tier1ABI.contextRegister == 28)
    #expect(DoryARM64Tier1ABI.framePointerRegister == 29)
    #expect(DoryARM64Tier1ABI.linkRegister == 30)
    #expect(DoryARM64Tier1ABI.stackPointerRegister == 31)

    let assigned = DoryARM64Tier1ABI.guestRegisterMap
      + DoryARM64Tier1ABI.scratchRegisters
      + [DoryARM64Tier1ABI.platformReservedRegister]
      + DoryARM64Tier1ABI.dispatcherRegisters
      + DoryARM64Tier1ABI.lazyFlagsRegisters
      + [
        DoryARM64Tier1ABI.guestRIPRegister,
        DoryARM64Tier1ABI.contextRegister,
        DoryARM64Tier1ABI.framePointerRegister,
        DoryARM64Tier1ABI.linkRegister,
        DoryARM64Tier1ABI.stackPointerRegister,
      ]
    #expect(Set(assigned).count == 32)
    #expect(Set(assigned) == Set((0...31).map(UInt32.init)))
  }

  @Test func helperSpillPlanContainsExactlyTheLivePinnedGuestRegisters() {
    for mask: UInt16 in [0, 1, 0x8000, 0xA55A, .max] {
      let expected = (0..<16).compactMap { index in
        mask & (UInt16(1) << UInt16(index)) == 0 ? nil : UInt32(index)
      }
      #expect(DoryARM64Tier1ABI.helperSpillRegisters(liveGuestMask: mask) == expected)
    }
  }

  @Test func stableContextLayoutMatchesTheExecutableBaselineBoundary() {
    #expect(DoryARM64Tier1ABI.ContextWord.allCases.map(\.rawValue) == Array(0..<94))
    #expect(DoryARM64Tier1ABI.contextWordCount == DoryJITExecutableRegion.contextWordCount)
    #expect(DoryARM64Tier1ABI.ContextWord.hostAddressSpaceBase.rawValue
      == DoryJITExecutableRegion.hostAddressSpaceBaseWordIndex)
    #expect(DoryARM64Tier1ABI.ContextWord.readTLBBase.rawValue
      == DoryJITExecutableRegion.readTLBBaseWordIndex)
    #expect(DoryARM64Tier1ABI.ContextWord.writeTLBBase.rawValue
      == DoryJITExecutableRegion.writeTLBBaseWordIndex)
    #expect(DoryARM64Tier1ABI.ContextWord.executeTLBBase.rawValue
      == DoryJITExecutableRegion.executeTLBBaseWordIndex)
    #expect(DoryARM64Tier1ABI.ContextWord.atomicCompareExchangePair.rawValue
      == DoryJITExecutableRegion.atomicCompareExchangePairWordIndex)
    #expect(DoryARM64Tier1ABI.ContextWord.cr3.rawValue == 50)
    #expect(DoryARM64Tier1ABI.ContextWord.kernelGSBase.rawValue == 51)
    #expect(DoryARM64Tier1ABI.ContextWord.swapGSPerformed.rawValue == 52)
    #expect(DoryARM64Tier1ABI.ContextWord.cr3WritePerformed.rawValue == 53)
    #expect(DoryARM64Tier1ABI.ContextWord.chainEnabled.rawValue == 54)
    #expect(DoryARM64Tier1ABI.ContextWord.chainRemainingInstructions.rawValue == 55)
    #expect(DoryARM64Tier1ABI.ContextWord.chainRetiredInstructions.rawValue == 56)
    #expect(DoryARM64Tier1ABI.ContextWord.chainRetiredBlocks.rawValue == 57)
    #expect(DoryARM64Tier1ABI.ContextWord.chainLastGuestRIP.rawValue == 58)
    #expect(DoryARM64Tier1ABI.ContextWord.ibtcEntriesBase.rawValue == 59)
    #expect(DoryARM64Tier1ABI.ContextWord.ibtcEntryMask.rawValue == 60)
    #expect(DoryARM64Tier1ABI.ContextWord.ibtcGeneration.rawValue == 61)
    #expect(DoryARM64Tier1ABI.ContextWord.ibtcInlineHits.rawValue == 62)
    #expect(DoryARM64Tier1ABI.ContextWord.ibtcInlineMisses.rawValue == 63)
    #expect(DoryARM64Tier1ABI.ContextWord.shadowReturnEntriesBase.rawValue == 64)
    #expect(DoryARM64Tier1ABI.ContextWord.shadowReturnEntryMask.rawValue == 65)
    #expect(DoryARM64Tier1ABI.ContextWord.shadowReturnTopAddress.rawValue == 66)
    #expect(DoryARM64Tier1ABI.ContextWord.shadowReturnGeneration.rawValue == 67)
    #expect(DoryARM64Tier1ABI.ContextWord.shadowReturnHits.rawValue == 68)
    #expect(DoryARM64Tier1ABI.ContextWord.shadowReturnMisses.rawValue == 69)
    #expect(DoryARM64Tier1ABI.ContextWord.shadowReturnPushes.rawValue == 70)
    #expect(DoryARM64Tier1ABI.ContextWord.pendingWork.rawValue == 71)
    #expect(DoryARM64Tier1ABI.ContextWord.hostFramePointer.rawValue == 72)
    #expect(DoryARM64Tier1ABI.ContextWord.hostReturnAddress.rawValue == 73)
    #expect(DoryARM64Tier1ABI.ContextWord.inlineTLBFaultHostPC.rawValue == 74)
    #expect(DoryARM64Tier1ABI.ContextWord.memoryFaultCheckpointActive.rawValue == 75)
    #expect(DoryARM64Tier1ABI.ContextWord.memoryFaultCheckpointRSP.rawValue == 82)
    #expect(DoryARM64Tier1ABI.ContextWord.memoryFaultCheckpointR15.rawValue == 93)
    for word in DoryARM64Tier1ABI.ContextWord.allCases {
      #expect(word.byteOffset == word.rawValue * MemoryLayout<UInt64>.stride)
    }
  }

  @Test func helperBoundaryRoundTripsEveryArchitecturalRegisterDuringMigration() throws {
    #if arch(arm64)
      let bytes: [UInt8] = [0x0F, 0xAE, 0xF0]  // MFENCE calls the synchronize helper.
      let memory = try DoryX86ByteArrayMemory(byteCount: 0x1000)
      var state = try DoryX86ArchitecturalState(
        registers: .init(
          rax: 0x01, rcx: 0x02, rdx: 0x03, rbx: 0x04,
          rsp: 0x05, rbp: 0x06, rsi: 0x07, rdi: 0x08,
          r8: 0x09, r9: 0x0A, r10: 0x0B, r11: 0x0C,
          r12: 0x0D, r13: 0x0E, r14: 0x0F, r15: 0x10
        ),
        rip: 0x800,
        rflags: [.reservedOne, .carry, .parity, .direction, .overflow],
        cs: .init(selector: 8, attributes: 0xA09B, limit: .max),
        ds: .init(selector: 0x10, attributes: 0x0093, limit: .max),
        es: .init(selector: 0x18, attributes: 0x0093, limit: .max),
        fs: .init(selector: 0x20, attributes: 0x0093, limit: .max, base: 0x1234),
        gs: .init(selector: 0x28, attributes: 0x0093, limit: .max, base: 0x5678),
        ss: .init(selector: 0x30, attributes: 0x0093, limit: .max),
        tsc: 0x1122_3344_5566_7788
      )
      var expected = state
      expected.rip += UInt64(bytes.count)
      let execution = try #require(DoryARM64BaselineExecutor(
        maximumCodeBytes: 4_096,
        tier1Enabled: true
      ).execute(
        bytes: bytes,
        at: state.rip,
        mode: .long64,
        addressSpaceID: 0,
        maximumInstructions: 1,
        state: &state,
        memory: memory
      ))

      #expect(execution.block.requiresMemoryCallbacks)
      #expect(execution.block.tier == .tier1)
      #expect(execution.exitCode == .dispatch)
      #expect(state == expected)
    #endif
  }

  @Test func emittedPinnedHelperShimSurvivesCallerSavedClobbersAndPublishesState() throws {
    #if arch(arm64)
      let helper: @convention(c) (UnsafeMutablePointer<UInt64>?, UInt64) -> UInt64 =
        doryTestTier1UnaryHelper
      let helperAddress = UInt64(unsafeBitCast(helper, to: UInt.self))
      let helperArgument: UInt64 = 0xFEDC_BA98_7654_3210
      let resultRegister = 10
      var words: [UInt32] = []
      let emitter = DoryARM64Tier1BoundaryEmitter()
      emitter.emitEntry(into: &words)
      emitter.emitHelperCall(.init(
        target: .tlbResolver,
        arguments: [.contextPointer, .immediate(helperArgument)],
        liveGuestMask: .max,
        resultGuestRegister: resultRegister
      ), into: &words)
      emitter.emitExit(.dispatch, into: &words)

      let block = DoryARM64CompiledBlock(
        guestStart: 0,
        guestByteCount: 1,
        guestInstructionCount: 1,
        machineWords: words,
        tier: .baseline,
        exitCode: .dispatch
      )
      let region = try DoryJITExecutableRegion(minimumCapacity: 4_096)
      try region.publish(block, at: 0)
      var context = (0..<DoryARM64Tier1ABI.contextWordCount).map {
        UInt64($0) &* 0x0101_0101_0101_0101
      }
      let initialGuestRegisters = Array(context[0..<16])
      let initialRIP = context[DoryARM64Tier1ABI.ContextWord.rip.rawValue]
      let initialRFLAGS = context[DoryARM64Tier1ABI.ContextWord.rflags.rawValue]
      let initialLazyOperation =
        context[DoryARM64Tier1ABI.ContextWord.lazyFlagsOperation.rawValue]
      context[DoryARM64Tier1ABI.ContextWord.tlbResolver.rawValue] = helperAddress

      let exit = try region.execute(at: 0, context: &context)

      #expect(exit == .dispatch)
      for register in 0..<16 where register != resultRegister {
        #expect(context[register] == initialGuestRegisters[register])
      }
      #expect(context[resultRegister] == helperArgument ^ doryTier1HelperResultMask)
      #expect(context[DoryARM64Tier1ABI.ContextWord.rip.rawValue] == initialRIP)
      #expect(context[DoryARM64Tier1ABI.ContextWord.rflags.rawValue] == initialRFLAGS)
      #expect(context[DoryARM64Tier1ABI.ContextWord.lazyFlagsOperation.rawValue]
        == initialLazyOperation)
      #expect(context[DoryARM64Tier1ABI.ContextWord.tsc.rawValue] == helperArgument)
    #endif
  }

  @Test func emittedHelperShimAddsOnlyDeclaredLiveGuestSpillsAndReloads() {
    let emitter = DoryARM64Tier1BoundaryEmitter()
    func emittedWords(mask: UInt16) -> [UInt32] {
      var words: [UInt32] = []
      emitter.emitHelperCall(.init(
        target: .tlbResolver,
        arguments: [.contextPointer],
        liveGuestMask: mask
      ), into: &words)
      return words
    }

    let emptyCount = emittedWords(mask: 0).count
    #expect(emittedWords(mask: 1 << 4).count == emptyCount + 2)
    #expect(emittedWords(mask: (1 << 2) | (1 << 13)).count == emptyCount + 4)
    #expect(emittedWords(mask: .max).count == emptyCount + 32)
  }
}

private let doryTier1HelperResultMask: UInt64 = 0xA55A_5AA5_F00D_CAFE

@_cdecl("dory_test_tier1_unary_helper")
private func doryTestTier1UnaryHelper(
  _ context: UnsafeMutablePointer<UInt64>?,
  _ value: UInt64
) -> UInt64 {
  context?[DoryARM64Tier1ABI.ContextWord.tsc.rawValue] = value
  return value ^ doryTier1HelperResultMask
}
