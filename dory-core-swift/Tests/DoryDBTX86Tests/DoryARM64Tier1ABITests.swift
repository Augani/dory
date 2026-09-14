import Testing
import DoryJITRuntimeC

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
    #expect(DoryARM64Tier1ABI.ContextWord.allCases.map(\.rawValue) == Array(0..<95))
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
    #expect(DoryARM64Tier1ABI.ContextWord.requiresRestartableMemoryReads.rawValue == 94)
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

  @Test(arguments: [false, true])
  func directTier1EdgePreservesHostABIAndDetectsCorruption(corruptX19: Bool) throws {
    #if arch(arm64)
      // MOV RAX, 0x1122 -> MFENCE. Both blocks and the source branch slot come
      // from the real Tier1 compiler. Only a frameless observation prefix is
      // added to the target in this private executable region.
      let sourceIR = try DoryX86IRTranslator(instructionBudget: 1).translate(
        [0x48, 0xC7, 0xC0, 0x22, 0x11, 0x00, 0x00], at: 0x2800, mode: .long64)
      let targetIR = try DoryX86IRTranslator(instructionBudget: 1).translate(
        [0x0F, 0xAE, 0xF0], at: 0x2807, mode: .long64)
      let source = try #require(DoryARM64Tier1Emitter().compile(sourceIR))
      let target = try #require(DoryARM64Tier1Emitter().compile(targetIR))
      #expect(source.tier == .tier1 && target.tier == .tier1)
      let slot = try #require(source.chainSlots?.first)
      #expect(slot.kind == .direct)
      #expect(slot.targetGuestRIP == target.guestStart)
      #expect(target.requiresMemoryCallbacks)

      // Independent allocations: neither the capture address nor its contents
      // are loaded from a generated frame or a seeded callee-saved register.
      let captures = (0..<6).map { _ in
        let pointer = UnsafeMutablePointer<dory_jit_test_abi_snapshot>.allocate(capacity: 1)
        pointer.initialize(to: .init())
        return pointer
      }
      defer {
        for pointer in captures {
          pointer.deinitialize(count: 1)
          pointer.deallocate()
        }
      }
      let before = captures[0], edge = captures[1], helper = captures[2], after = captures[3]
      let outerBefore = captures[4], outerAfter = captures[5]
      let prefix = doryTier1EdgeCaptureWords(into: edge, corruptX19: corruptX19)
      let prefixOffset = source.machineByteCount
      let targetOffset = prefixOffset + prefix.words.count * 4
      var created: OpaquePointer?
      try #require(dory_jit_region_create(16_384, &created) == 0)
      let region = try #require(created)
      defer { dory_jit_region_destroy(region) }
      func publish(_ words: [UInt32], at offset: Int) throws {
        let result = words.withUnsafeBytes {
          dory_jit_region_publish(region, offset, $0.bindMemory(to: UInt8.self).baseAddress, $0.count)
        }
        try #require(result == 0)
      }
      try publish(source.machineWords, at: 0)
      try publish(prefix.words, at: prefixOffset)
      try publish(target.machineWords, at: targetOffset)
      let sourceEntry = try #require(dory_jit_region_entry(region, 0))
      let sourceAddress = UInt64(UInt(bitPattern: sourceEntry))
      let targetAddress = sourceAddress + UInt64(targetOffset)
      let publishedGeneration = dory_jit_test_region_generation(region)
      #expect(publishedGeneration == 3)

      let seeds = (19...28).map { UInt64($0) * 0x0101_0101_0101_0101 }
      let outerSeeds = seeds.map { $0 ^ 0xA55A_A55A_A55A_A55A }
      let context = UnsafeMutableBufferPointer<UInt64>.allocate(
        capacity: DoryARM64Tier1ABI.contextWordCount)
      context.initialize(repeating: 0)
      defer { context.deinitialize(); context.deallocate() }
      let contextAddress = UInt64(UInt(bitPattern: context.baseAddress!))
      let helperAddress = UInt64(UInt(bitPattern: helper))
      // Distinct, valid callback addresses expose argument swaps at target entry.
      let read: dory_jit_memory_read_function = { _, _, _ in 0 }
      let write: dory_jit_memory_write_function = { _, _, _, _ in }
      let compare: dory_jit_memory_compare_exchange_function = { _, _, _, _, _, _ in 0 }
      let synchronize: dory_jit_memory_synchronize_function = dory_jit_test_abi_synchronize
      let arguments = [contextAddress, helperAddress,
        UInt64(unsafeBitCast(read, to: UInt.self)),
        UInt64(unsafeBitCast(write, to: UInt.self)),
        UInt64(unsafeBitCast(compare, to: UInt.self)),
        UInt64(unsafeBitCast(synchronize, to: UInt.self))]
      let invokeProbe: @convention(c) (
        UInt, UnsafePointer<UInt64>?, UnsafePointer<UInt64>?,
        UnsafeMutablePointer<dory_jit_test_abi_snapshot>?,
        UnsafeMutablePointer<dory_jit_test_abi_snapshot>?
      ) -> UInt32 = dory_jit_test_abi_call
      let invokeAddress = unsafeBitCast(invokeProbe, to: UInt.self)
      func reset() {
        for index in context.indices { context[index] = 0 }
        for pointer in captures { pointer.pointee = .init() }
        for index in 0..<16 { context[index] = UInt64(index + 1) * 0x101 }
        context[16] = source.guestStart
        context[17] = DoryX86RFLAGS.reservedOne.rawValue
        context[DoryARM64Tier1ABI.ContextWord.chainEnabled.rawValue] = 1
        context[DoryARM64Tier1ABI.ContextWord.chainRemainingInstructions.rawValue] = 2
        // Direct edges do not consult predictors, but must preserve their epochs
        // and the recovery state carried by the dispatcher-owned context.
        context[DoryARM64Tier1ABI.ContextWord.ibtcGeneration.rawValue] = 0x6161
        context[DoryARM64Tier1ABI.ContextWord.shadowReturnGeneration.rawValue] = 0x6767
        context[DoryARM64Tier1ABI.ContextWord.hostFramePointer.rawValue] = 0x7272
        context[DoryARM64Tier1ABI.ContextWord.hostReturnAddress.rawValue] = 0x7373
      }
      func invoke() -> UInt32 {
        arguments.withUnsafeBufferPointer { args in
          seeds.withUnsafeBufferPointer { seedBuffer in
            // Nest the probe using its ordinary C signature. The outer capture
            // proves even the negative run restores its real caller's state.
            let outerArguments = [sourceAddress,
              UInt64(UInt(bitPattern: args.baseAddress!)),
              UInt64(UInt(bitPattern: seedBuffer.baseAddress!)),
              UInt64(UInt(bitPattern: before)), UInt64(UInt(bitPattern: after)), 0]
            return outerArguments.withUnsafeBufferPointer { outerArgs in
              outerSeeds.withUnsafeBufferPointer { outerSeedBuffer in
                dory_jit_test_abi_call(invokeAddress, outerArgs.baseAddress!,
                  outerSeedBuffer.baseAddress!, outerBefore, outerAfter)
              }
            }
          }
        }
      }

      reset()
      #expect(invoke() == DoryJITExitCode.dispatch.rawValue)
      // This run reaches the real source fallback, never the observation prefix.
      try #require(edge.pointee.pc == 0 && helper.pointee.pc == 0)
      #expect(context[16] == target.guestStart)
      #expect(context[DoryARM64Tier1ABI.ContextWord.chainRetiredBlocks.rawValue] == 1)
      #expect(doryTier1HostMismatches(after.pointee, seeds: seeds).isEmpty)
      try #require(dory_jit_region_patch_branch(region, slot.machineWordIndex * 4, prefixOffset) == 0)
      let edgeGeneration = dory_jit_test_region_generation(region)
      #expect(edgeGeneration == publishedGeneration + 1)

      reset()
      #expect(invoke() == DoryJITExitCode.dispatch.rawValue)
      // Arm the oracle with runtime evidence before trusting register assertions.
      try #require(edge.pointee.pc == sourceAddress + UInt64(prefixOffset + prefix.pcWord * 4))
      try #require(helper.pointee.pc != 0)
      try #require(context[DoryARM64Tier1ABI.ContextWord.chainRetiredBlocks.rawValue] == 2)
      #expect(context[DoryARM64Tier1ABI.ContextWord.chainRetiredInstructions.rawValue] == 2)
      #expect(context[DoryARM64Tier1ABI.ContextWord.chainRemainingInstructions.rawValue] == 0)
      #expect(context[16] == 0x280A && context[0] == 0x1122)
      #expect(dory_jit_test_region_generation(region) == edgeGeneration)

      let expectedMismatches = corruptX19 ? [19] : []
      #expect(doryTier1HostMismatches(before.pointee, seeds: seeds).isEmpty)
      #expect(doryTier1HostMismatches(edge.pointee, seeds: seeds) == expectedMismatches)
      #expect(doryTier1HostMismatches(after.pointee, seeds: seeds) == expectedMismatches)
      #expect(doryTier1HostMismatches(outerAfter.pointee, seeds: outerSeeds).isEmpty)
      let b = doryTier1SnapshotWords(before.pointee)
      let e = doryTier1SnapshotWords(edge.pointee)
      let h = doryTier1SnapshotWords(helper.pointee)
      let a = doryTier1SnapshotWords(after.pointee)
      for snapshot in [b, e, h, a] {
        #expect(snapshot[10] % 16 == 0)  // SP alignment at every observed boundary
        #expect(snapshot[11] == b[11])  // frame pointer
        #expect(snapshot[20] == b[20])  // Darwin x18 is never assigned by the probe
      }
      #expect(e[10] == b[10] && a[10] == b[10])
      #expect(h[10] == b[10] - 96)  // exactly one target Tier1 frame
      #expect(e[12] == b[12] && a[12] == b[12])
      #expect(Array(b[13..<19]) == arguments)
      #expect(Array(e[13..<19]) == arguments)
      #expect(h[13] == helperAddress)  // synchronize's actual x0 argument
      #expect(h[9] == contextAddress) // target's pinned x28 vCPU
      #expect(Array(h[0..<5]) == Array(arguments[1..<6])) // pinned callback bank
      #expect(h[5] == seeds[5]) // x24 is unused by this fixture
      #expect(h[6] == DoryX86RFLAGS.reservedOne.rawValue) // pinned materialized flags
      #expect(h[7] == 0 && h[8] == target.guestStart) // lazy descriptor and pinned RIP
      #expect(a[13] == UInt64(DoryJITExitCode.dispatch.rawValue))
      #expect(outerAfter.pointee.sp == outerBefore.pointee.sp)
      #expect(outerAfter.pointee.fp == outerBefore.pointee.fp)
      #expect(outerAfter.pointee.lr == outerBefore.pointee.lr)
      #expect(outerAfter.pointee.platform == outerBefore.pointee.platform)

      let edgeContext = Array(e[21...]), helperContext = Array(h[21...])
      var expectedGuestRegisters = (0..<16).map { UInt64($0 + 1) * 0x101 }
      expectedGuestRegisters[0] = 0x1122
      #expect(Array(edgeContext[0..<16]) == expectedGuestRegisters)
      #expect(Array(helperContext[0..<16]) == expectedGuestRegisters)
      #expect(Array(context[0..<16]) == expectedGuestRegisters)
      #expect(edgeContext[16] == target.guestStart && helperContext[16] == target.guestStart)
      #expect(edgeContext[17] == DoryX86RFLAGS.reservedOne.rawValue)
      #expect(helperContext[17] == DoryX86RFLAGS.reservedOne.rawValue)
      #expect(edgeContext[DoryARM64Tier1ABI.ContextWord.chainRetiredBlocks.rawValue] == 1)
      #expect(edgeContext[DoryARM64Tier1ABI.ContextWord.chainRemainingInstructions.rawValue] == 1)
      let stableContext: [(DoryARM64Tier1ABI.ContextWord, UInt64)] = [
        (.ibtcGeneration, 0x6161), (.shadowReturnGeneration, 0x6767),
        (.hostFramePointer, 0x7272), (.hostReturnAddress, 0x7373),
        (.inlineTLBFaultHostPC, 0), (.memoryFaultCheckpointActive, 0),
      ]
      for (word, expected) in stableContext {
        #expect(edgeContext[word.rawValue] == expected)
        #expect(helperContext[word.rawValue] == expected)
        #expect(context[word.rawValue] == expected)
      }
      // Resolve the actual generated callback return PC through the unmodified
      // target's recovery map. The observation prefix is outside its code range.
      try #require(h[12] >= targetAddress + 4)
      let callbackOffset = try #require(UInt32(exactly: h[12] - targetAddress - 4))
      try #require(Int(callbackOffset) < target.machineByteCount)
      #expect(target.machineWords[Int(callbackOffset) / 4] == 0xD63F_02E0) // blr x23
      let recovery = try #require(target.instructionMetadata(atHostOffset: callbackOffset))
      #expect(recovery.guestRIP == target.guestStart)
      #expect(recovery.guestByteCount == 3)
      #expect(recovery.flagsState == .context)
      let sourceRecovery = try #require(source.instructionMetadata(
        atHostOffset: UInt32(slot.machineWordIndex * 4)))
      #expect(sourceRecovery.guestRIP == source.guestStart)
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

#if arch(arm64)
private func doryTier1SnapshotWords(_ snapshot: dory_jit_test_abi_snapshot) -> [UInt64] {
  withUnsafeBytes(of: snapshot) { Array($0.bindMemory(to: UInt64.self)) }
}

private func doryTier1HostMismatches(
  _ snapshot: dory_jit_test_abi_snapshot, seeds: [UInt64]
) -> [Int] {
  let words = doryTier1SnapshotWords(snapshot)
  return (0..<10).filter { words[$0] != seeds[$0] }.map { $0 + 19 }
}

/// This observation prefix falls straight into the *full* generated target entry.
/// It changes only x16/x17 (Darwin scratch), does not touch SP/LR/NZCV, and uses an
/// embedded caller-owned address rather than trusting any generated-frame slot.
private func doryTier1EdgeCaptureWords(
  into capture: UnsafeMutablePointer<dory_jit_test_abi_snapshot>, corruptX19: Bool
) -> (words: [UInt32], pcWord: Int) {
  var words: [UInt32] = []
  if corruptX19 {
    words += [0xD280_0031, 0xCA11_0273] // mov x17, #1; eor x19, x19, x17
  }
  let address = UInt64(UInt(bitPattern: capture))
  for half in 0..<4 {
    words.append((half == 0 ? 0xD280_0000 : 0xF280_0000)
      | UInt32(half << 21) | UInt32((address >> (half * 16)) & 0xFFFF) << 5 | 16)
  }
  func store(_ register: UInt32, word: Int) {
    words.append(0xF900_0000 | UInt32(word) << 10 | 16 << 5 | register)
  }
  for index in 0..<10 { store(UInt32(index + 19), word: index) }
  words.append(0x9100_03F1) // mov x17, sp
  store(17, word: 10)
  store(29, word: 11)
  store(30, word: 12)
  for index in 0..<6 { store(UInt32(index), word: 13 + index) }
  let pcWord = words.count
  words.append(0x1000_0011) // adr x17, .
  store(17, word: 19)
  store(18, word: 20)
  for index in 0..<DoryARM64Tier1ABI.contextWordCount {
    words.append(0xF940_0011 | UInt32(index) << 10) // ldr x17, [x0, #index*8]
    store(17, word: 21 + index)
  }
  return (words, pcWord)
}
#endif
