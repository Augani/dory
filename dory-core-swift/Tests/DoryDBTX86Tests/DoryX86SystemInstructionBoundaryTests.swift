import Testing

@testable import DoryDBTX86

// Intel SDM 092: Vol. 2A LFENCE p.3-552, INCSSP pp.3-459–460, INVLPG pp.3-485–486;
// Vol. 2B MFENCE p.4-15, SFENCE p.4-627, SMSW p.4-659, WAITPKG pp.4-728–742.
// https://cdrdv2-public.intel.com/922480/253666-092-sdm-vol-2a.pdf
// https://cdrdv2-public.intel.com/922481/253667-092-sdm-vol-2b.pdf
@Suite struct DoryX86SystemInstructionBoundaryTests {
  private let modes: [DoryX86ExecutionMode] = [.real16, .protected16, .protected32, .long64]

  @Test func unprefixedFencesIgnoreEveryRMValueAndHarmlessAddressOrSegmentPrefixes() throws {
    for mode in modes {
      let prefixes: [[UInt8]] = [[], [0x67], [0x64], [0x2E, 0x67]]
        + (mode == .long64 ? [[0x41], [0x4F]] : [])
      for prefix in prefixes {
        for (group, fence): (UInt8, DoryX86MemoryFence) in [(5, .load), (6, .full), (7, .store)] {
          for rm: UInt8 in 0..<8 {
            let bytes = prefix + [0x0F, 0xAE, 0xC0 | (group << 3) | rm]
            let decoded = try DoryX86Decoder().decode(bytes + [0x90], at: 0x1000, mode: mode)
            #expect(decoded.length == bytes.count)
            #expect(decoded.operation == .memoryFence(fence))
            let memory = DoryX86ByteArrayMemory(byteCount: 0x2000)
            try memory.write(at: 0x1000, bytes: bytes)
            var state = try makeState(mode: mode, cpl: 3)
            let before = state
            #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: mode) == .retired(decoded))
            #expect(state.rip == 0x1000 + UInt64(bytes.count))
            #expect(state.registers == before.registers)
            #expect(state.rflags == before.rflags)
          }
        }
      }
    }
  }

  @Test func CETAndWAITPKGRefinementsCannotExecuteAsFences() throws {
    // F3 /5 is INCSSPD/Q; 66/F2/F3 /6 are TPAUSE/UMWAIT/UMONITOR.
    // None is exposed by the selected profile. NP fences accept none of these
    // effective mandatory prefixes, including mixed/repeated prefix sequences.
    for mode in modes {
      for prefix: [UInt8] in [[0x66], [0xF2], [0xF3], [0xF3, 0xF2], [0xF2, 0xF3],
        [0x66, 0xF3], [0xF3, 0x66]] {
        for group: UInt8 in [5, 6, 7] {
          for rm: UInt8 in 0..<8 {
            let bytes = prefix + (mode == .long64 ? [0x49] : [])
              + [0x0F, 0xAE, 0xC0 | (group << 3) | rm]
            #expect(throws: DoryX86DecodeError.self) {
              try DoryX86Decoder().decode(bytes, at: 0x1000, mode: mode)
            }
            for cpl: UInt16 in [0, 3] {
              let memory = DoryX86ByteArrayMemory(byteCount: 0x2000)
              try memory.write(at: 0x1000, bytes: bytes)
              var state = try makeState(mode: mode, cpl: cpl)
              let before = state
              #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: mode)
                == .exception(.init(kind: .invalidOpcode, vector: 6, instructionPointer: 0x1000)))
              #expect(state == before)
            }
          }
        }
      }
    }
  }

  @Test func SMSWAppliesUMIPBeforeRegisterOrMemoryDestinationEffects() throws {
    for mode in modes {
      for virtual in [false, true] where !virtual || mode == .protected16 {
        for cpl: UInt16 in [0, 3] {
          for umip in [false, true] {
            for register in [false, true] {
              let prefix: [UInt8] = mode == .real16 || mode == .protected16 ? [0x67] : []
              let bytes = prefix + [0x0F, 0x01, register ? 0xE0 : 0x20]
              let memory = DoryX86ByteArrayMemory(byteCount: 0x3000)
              try memory.write(at: 0x1000, bytes: bytes)
              var state = try makeState(mode: mode, cpl: cpl)
              if virtual { state.rflags.insert(.virtual8086) }
              if umip { state.control.cr4 |= 1 << 11 }
              let denied = umip && mode != .real16 && (virtual || cpl != 0)
              state.registers.rax = denied ? 0xFFFF_FF00 : 0x2000
              let before = state
              let snapshot = memory.snapshot()
              let result = DoryX86Interpreter().step(state: &state, memory: memory, mode: mode)
              if denied {
                #expect(result == generalProtection())
                #expect(state == before)
                #expect(memory.snapshot() == snapshot)
              } else {
                let decoded = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: mode)
                #expect(result == .retired(decoded))
                if register { #expect(state.registers.rax == before.control.cr0) }
                else { #expect(try memory.readScalar(at: 0x2000, byteCount: 2) == before.control.cr0) }
                #expect(state.control == before.control)
              }
            }
          }
        }
      }
    }
  }

  @Test func INVLPGInvalidatesTheOnlySuppliedTranslatedMemoryBeforeNextRead() throws {
    var state = try makeState()
    let (memory, paging, translated) = try pagedFixture(code: [0x0F, 0x01, 0x3F], state: &state)
    state.registers.rdi = 0x6000
    try memory.writeScalar(at: 0x5030, value: 0x7003, byteCount: 8)
    #expect(try translated.read(at: 0x6000, byteCount: 1) == [0xA6]) // Cached old translation.
    let decoded = try DoryX86Decoder().decode([0x0F, 0x01, 0x3F], at: 0x1000, mode: .long64)
    #expect(DoryX86Interpreter().step(state: &state, memory: memory,
      mode: .long64, translatedMemory: translated) == .retired(decoded))
    #expect(paging.cachedTranslationCount == 1) // Instruction page survives; target page does not.
    #expect(try translated.read(at: 0x6000, byteCount: 1) == [0xB7])
  }

  @Test func LMSWInvalidationReachesTheOnlySuppliedTranslatedMemoryAndPreservesPE() throws {
    for requested: UInt64 in [0, 0xE] {
      var state = try makeState()
      let (memory, paging, translated) = try pagedFixture(code: [0x0F, 0x01, 0xF0], state: &state)
      state.registers.rax = requested
      let before = state.control.cr0
      let decoded = try DoryX86Decoder().decode([0x0F, 0x01, 0xF0], at: 0x1000, mode: .long64)
      #expect(DoryX86Interpreter().step(state: &state, memory: memory,
        mode: .long64, translatedMemory: translated) == .retired(decoded))
      #expect(state.control.cr0 == (before & ~UInt64(0xE)) | requested)
      #expect(state.control.cr0 & 1 == 1)
      #expect(paging.cachedTranslationCount == 0)
    }
  }

  @Test func deniedUserInvalidationAndLMSWLeaveStateAndCacheUnchanged() throws {
    for code: [UInt8] in [[0x0F, 0x01, 0x3F], [0x0F, 0x01, 0xF0]] {
      var state = try makeState(cpl: 3)
      let (memory, paging, translated) = try pagedFixture(code: code, state: &state)
      state.registers.rdi = 0x6000
      state.registers.rax = 0
      let before = state
      let snapshot = memory.snapshot()
      #expect(DoryX86Interpreter().step(state: &state, memory: memory,
        mode: .long64, translatedMemory: translated) == generalProtection())
      #expect(state == before)
      #expect(memory.snapshot() == snapshot)
      #expect(paging.cachedTranslationCount == 2)
    }
  }

  @Test func faultingLMSWMemoryReadPreservesControlAndCacheWithPreciseCR2() throws {
    var state = try makeState()
    let (memory, paging, translated) = try pagedFixture(code: [0x0F, 0x01, 0x30], state: &state)
    state.registers.rax = 0x9000
    var expected = state
    expected.control.cr2 = 0x9000
    let snapshot = memory.snapshot()
    #expect(DoryX86Interpreter().step(state: &state, memory: memory,
      mode: .long64, translatedMemory: translated)
      == .exception(.init(kind: .pageFault, vector: 14, errorCode: 0,
        instructionPointer: 0x1000, linearAddress: 0x9000)))
    #expect(state == expected)
    #expect(memory.snapshot() == snapshot)
    #expect(paging.cachedTranslationCount == 2)
  }

  private func makeState(mode: DoryX86ExecutionMode = .long64,
    cpl: UInt16 = 0) throws -> DoryX86ArchitecturalState {
    try .init(rip: 0x1000,
      cs: .init(selector: cpl, attributes: mode == .long64 ? 0xA09B : 0x009B, limit: .max),
      ds: .init(selector: 0x10, attributes: 0x0093, limit: .max),
      control: .init(cr0: 0x11))
  }

  private func pagedFixture(code: [UInt8], state: inout DoryX86ArchitecturalState) throws
    -> (DoryX86ByteArrayMemory, DoryX86PagingUnit, DoryX86TranslatedMemory) {
    let memory = DoryX86ByteArrayMemory(byteCount: 0x10000)
    try memory.write(at: 0x1000, bytes: code)
    let flags: UInt64 = state.cs.selector & 3 == 3 ? 7 : 3
    try memory.writeScalar(at: 0x2000, value: 0x3000 | flags, byteCount: 8)
    try memory.writeScalar(at: 0x3000, value: 0x4000 | flags, byteCount: 8)
    try memory.writeScalar(at: 0x4000, value: 0x5000 | flags, byteCount: 8)
    for page in 0..<8 {
      try memory.writeScalar(at: 0x5000 + UInt64(page * 8),
        value: UInt64(page * 0x1000) | flags, byteCount: 8)
    }
    try memory.write(at: 0x6000, bytes: [0xA6])
    try memory.write(at: 0x7000, bytes: [0xB7])
    state.control = .init(cr0: 0x8000_0011, cr3: 0x2000, cr4: 1 << 5, efer: 0x500)
    let paging = DoryX86PagingUnit()
    let translated = DoryX86TranslatedMemory(physicalMemory: memory, pagingUnit: paging,
      context: .init(state: state, mode: .long64))
    _ = try translated.instructionBytes(at: state.rip, maximumCount: code.count)
    #expect(try translated.read(at: 0x6000, byteCount: 1) == [0xA6])
    #expect(paging.cachedTranslationCount == 2)
    return (memory, paging, translated)
  }

  private func generalProtection() -> DoryX86InterpreterResult {
    .exception(.init(kind: .generalProtection, vector: 13, errorCode: 0, instructionPointer: 0x1000))
  }
}
