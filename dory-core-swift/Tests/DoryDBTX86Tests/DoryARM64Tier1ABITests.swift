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
    #expect(DoryARM64Tier1ABI.ContextWord.allCases.map(\.rawValue) == Array(0..<43))
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
        maximumCodeBytes: 4_096
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
      #expect(execution.exitCode == .dispatch)
      #expect(state == expected)
    #endif
  }
}
