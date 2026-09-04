import Testing

@testable import DoryDBTX86

// A speculative JIT fetch is bounded to the current page. Only the interpreter
// performs the incremental architectural fetch and decides whether a missing
// next byte is a guest page fault or part of a valid cross-page instruction.
@Suite struct DoryARM64DecodeBoundaryTests {
  @Test func incompleteFirstInstructionDeclinesWithoutStateOrStoresThenFaultsAtNextPage() throws {
    #if arch(arm64)
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        for first: UInt8 in [0x48, 0x0F, 0xB8] {
          let physical = try memory()
          try physical.write(at: 0x1FFF, bytes: [first])
          var state = try state(rip: 0x1FFF)
          let (paging, translated) = translatedMemory(physical, state: state)
          let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 16384, optimization: optimization)
          // Warm the mapped instruction byte so page-table A-bit writes are not
          // confused with guest store effects from a declined native instruction.
          #expect(try speculativeBytes(translated, at: state.rip, count: 15) == [first])
          let before = state
          let snapshot = physical.snapshot()
          #expect(try executor.executeSummary(
            byteProvider: { try speculativeBytes(translated, at: 0x1FFF, count: $0) },
            codeGenerationProvider: { try translated.codeGeneration(at: 0x1FFF, byteCount: $0) },
            at: state.rip, mode: .long64, addressSpaceID: 0x9000,
            maximumInstructions: 4, state: &state, memory: translated) == nil)
          #expect(state == before)
          #expect(physical.snapshot() == snapshot)
          #expect(try runChain(executor, state: &state, translated: translated) == nil)
          #expect(state == before)
          #expect(physical.snapshot() == snapshot)
          #expect(executor.diagnostics.negativeEntryCount == 0)
          #expect(DoryX86Interpreter().step(state: &state, memory: physical, mode: .long64,
            pagingUnit: paging, translatedMemory: translated) == fetchFault(rip: 0x1FFF))
          var expected = before
          expected.control.cr2 = 0x2000
          #expect(state == expected)
          #expect(try physical.readScalar(at: 0x8000, byteCount: 8) == 5)
        }
      }
    #endif
  }

  @Test func mappedCrossPageInstructionExecutesOnceThroughPreciseInterpreterFetch() throws {
    #if arch(arm64)
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let physical = try memory(secondPagePresent: true)
        let code: [UInt8] = [0x48, 0xFF, 0xC0] // INC RAX spans the boundary.
        try physical.write(at: 0x1FFF, bytes: code)
        var state = try state(rip: 0x1FFF)
        let (_, translated) = translatedMemory(physical, state: state)
        let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 16384, optimization: optimization)
        let before = state
        #expect(try runChain(executor, state: &state, translated: translated) == nil)
        #expect(state == before)
        #expect(executor.diagnostics.negativeEntryCount == 0)
        let decoded = try DoryX86Decoder().decode(code, at: 0x1FFF, mode: .long64)
        #expect(DoryX86Interpreter().step(state: &state, memory: physical, mode: .long64,
          translatedMemory: translated) == .retired(decoded))
        #expect(state.registers.rax == 1)
        #expect(state.rip == 0x2002)
        #expect(state.control.cr2 == before.control.cr2)
        #expect(try physical.readScalar(at: 0x8000, byteCount: 8) == 5)
      }
    #endif
  }

  @Test func completingMappingDoesNotLeaveAStaleNegativeCompilationEntry() throws {
    #if arch(arm64)
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let physical = try memory()
        try physical.write(at: 0x1FFF, bytes: [0xB8])
        var state = try state(rip: 0x1FFF)
        let (paging, translated) = translatedMemory(physical, state: state)
        let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 16384, optimization: optimization)
        let before = state
        for _ in 0..<2 {
          #expect(try runChain(executor, state: &state, translated: translated) == nil)
          #expect(state == before)
        }
        #expect(executor.diagnostics.negativeEntryCount == 0)
        // Only the second page and page table change. The first byte's code
        // generation remains unchanged, so a cached negative first-byte proof
        // would incorrectly suppress fresh compilation from the complete input.
        try physical.write(at: 0x2000, bytes: [0x78, 0x56, 0x34, 0x12])
        try physical.writeScalar(at: 0xC010, value: 0x2007, byteCount: 8)
        paging.invalidateAll()
        let summary = try #require(executor.executeSummary(
          byteProvider: { try translated.instructionBytes(at: 0x1FFF, maximumCount: $0) },
          codeGenerationProvider: { try translated.codeGeneration(at: 0x1FFF, byteCount: $0) },
          at: 0x1FFF, mode: .long64, addressSpaceID: 0x9000, maximumInstructions: 1,
          state: &state, memory: translated))
        #expect(summary.guestInstructionCount == 1)
        #expect(summary.exitCode == .dispatch)
        #expect(state.registers.rax == 0x1234_5678)
        #expect(state.rip == 0x2004)
        #expect(executor.diagnostics.negativeEntryCount == 0)
      }
    #endif
  }

  @Test func completedNativeStoreAndRegisterPrefixPublishExactlyOnceBeforeTruncatedTarget() throws {
    #if arch(arm64)
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let physical = try memory()
        // INC qword [RBX]; INC RCX; JMP 1FFF. The store forms its own native
        // block; the register/JMP block then reaches an incomplete next block.
        try physical.write(at: 0x1000,
          bytes: [0x48, 0xFF, 0x03, 0x48, 0xFF, 0xC1, 0xE9, 0xF4, 0x0F, 0, 0])
        try physical.write(at: 0x1FFF, bytes: [0x48])
        var state = try state(rip: 0x1000)
        let (paging, translated) = translatedMemory(physical, state: state)
        let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 16384, optimization: optimization)
        let execution = try runChain(executor, state: &state, translated: translated)
        let summary = try #require(execution)
        #expect(summary.guestInstructionCount == 3)
        #expect(summary.residentBlockCount == 2)
        #expect(summary.exitCode == .dispatch)
        #expect(state.rip == 0x1FFF)
        #expect(state.registers.rcx == 1)
        #expect(state.registers.rax == 0)
        #expect(try physical.readScalar(at: 0x8000, byteCount: 8) == 6)
        for _ in 0..<2 {
          let before = state
          #expect(try runChain(executor, state: &state, translated: translated) == nil)
          #expect(state == before)
          #expect(DoryX86Interpreter().step(state: &state, memory: physical, mode: .long64,
            pagingUnit: paging, translatedMemory: translated) == fetchFault(rip: 0x1FFF))
          #expect(state.rip == 0x1FFF && state.registers.rcx == 1 && state.registers.rax == 0)
          #expect(try physical.readScalar(at: 0x8000, byteCount: 8) == 6)
        }
        #expect(executor.diagnostics.chainedRetiredInstructions == 3)
        #expect(executor.diagnostics.negativeEntryCount == 0)
      }
    #endif
  }

  @Test func truncatedLaterDecodeDiscardsAnUnexecutedRegisterPrefix() throws {
    #if arch(arm64)
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let physical = try memory()
        try physical.write(at: 0x1FFC, bytes: [0x48, 0xFF, 0xC0, 0x48])
        var state = try state(rip: 0x1FFC)
        let (_, translated) = translatedMemory(physical, state: state)
        let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 16384, optimization: optimization)
        let before = state
        #expect(try runChain(executor, state: &state, translated: translated) == nil)
        #expect(state == before)
        #expect(executor.diagnostics.chainedRetiredInstructions == 0)
        let decoded = try DoryX86Decoder().decode([0x48, 0xFF, 0xC0], at: 0x1FFC, mode: .long64)
        #expect(DoryX86Interpreter().step(state: &state, memory: physical, mode: .long64,
          translatedMemory: translated) == .retired(decoded))
        #expect(state.registers.rax == 1 && state.rip == 0x1FFF)
        #expect(try runChain(executor, state: &state, translated: translated) == nil)
        #expect(DoryX86Interpreter().step(state: &state, memory: physical, mode: .long64,
          translatedMemory: translated) == fetchFault(rip: 0x1FFF))
        #expect(state.registers.rax == 1 && state.rip == 0x1FFF)
        #expect(try physical.readScalar(at: 0x8000, byteCount: 8) == 5)
      }
    #endif
  }

  @Test func throwingColdAndCachedFetchesPublishCompletedStorePrefixBeforePreciseFault() throws {
    #if arch(arm64)
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        for warmTarget in [false, true] {
          let physical = try memory(secondPagePresent: true)
          try physical.write(at: 0x1000,
            bytes: [0x48, 0xFF, 0x03, 0x48, 0xFF, 0xC1, 0xE9, 0xF5, 0x0F, 0, 0])
          try physical.write(at: 0x2000, bytes: [0x48, 0xFF, 0xC2]) // INC RDX.
          var state = try state(rip: 0x1000)
          let (paging, translated) = translatedMemory(physical, state: state)
          let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 16384, optimization: optimization)
          if warmTarget {
            var warm = try self.state(rip: 0x2000)
            // Omit generation metadata so a resident target must revalidate its
            // bytes and cannot bypass the throwing provider through a proof hit.
            let execution = try executor.executeSummary(
              byteProvider: { try speculativeBytes(translated, at: 0x2000, count: $0) },
              at: 0x2000, mode: .long64, addressSpaceID: 0x9000,
              maximumInstructions: 1, state: &warm, memory: translated)
            let warmSummary = try #require(execution)
            #expect(warmSummary.guestInstructionCount == 1)
            #expect(warm.registers.rdx == 1)
          }
          try physical.writeScalar(at: 0xC010, value: 0, byteCount: 8)
          paging.invalidateAll()
          var targetFetchCounts: [Int] = []
          let execution = try executor.executeChainedSummary(
            byteProvider: { address, count in
              if address == 0x2000 { targetFetchCounts.append(count) }
              // Deliberately propagate the translated fetch error. The public
              // executor must not depend on a machine wrapper converting it to [].
              return try speculativeBytes(translated, at: address, count: count)
            }, at: state.rip, mode: .long64, addressSpaceID: 0x9000,
            maximumInstructions: 16, state: &state, memory: translated)
          let summary = try #require(execution)
          #expect(targetFetchCounts.count == 1)
          if warmTarget {
            #expect(targetFetchCounts.first == 3) // Resident byte revalidation.
          } else {
            let coldFetchCount = try #require(targetFetchCounts.first)
            #expect(coldFetchCount > 3) // Cold compilation fetch.
          }
          #expect(summary.guestInstructionCount == 3)
          #expect(summary.residentBlockCount == 2)
          #expect(summary.exitCode == .dispatch)
          #expect(state.rip == 0x2000 && state.registers.rcx == 1 && state.registers.rdx == 0)
          #expect(state.control.cr2 == 0x1234)
          #expect(try physical.readScalar(at: 0x8000, byteCount: 8) == 6)
          for _ in 0..<2 {
            let before = state
            let snapshot = physical.snapshot()
            // The chained API also probes the bulk-copy pattern at the first
            // RIP. Its speculative fetch must decline the same typed error.
            #expect(try runChain(executor, state: &state, translated: translated) == nil)
            #expect(state == before && physical.snapshot() == snapshot)
            #expect(try executor.executeSummary(
              byteProvider: { try speculativeBytes(translated, at: 0x2000, count: $0) },
              at: 0x2000, mode: .long64, addressSpaceID: 0x9000,
              maximumInstructions: 16, state: &state, memory: translated) == nil)
            #expect(state == before && physical.snapshot() == snapshot)
            #expect(DoryX86Interpreter().step(state: &state, memory: physical, mode: .long64,
              pagingUnit: paging, translatedMemory: translated) == fetchFault(rip: 0x2000))
            var expected = before
            expected.control.cr2 = 0x2000
            #expect(state == expected)
            #expect(try physical.readScalar(at: 0x8000, byteCount: 8) == 6)
          }
          #expect(executor.diagnostics.chainedRetiredInstructions == 3)
          #expect(executor.diagnostics.negativeEntryCount == 0)
        }
      }
    #endif
  }

  private func memory(secondPagePresent: Bool = false) throws -> DoryX86ByteArrayMemory {
    let physical = try DoryX86ByteArrayMemory(byteCount: 0x10000)
    for (address, value): (UInt64, UInt64) in [
      (0x9000, 0xA007), (0xA000, 0xB007), (0xB000, 0xC007),
      (0xC008, 0x1007), (0xC010, secondPagePresent ? 0x2007 : 0), (0xC040, 0x8007),
    ] { try physical.writeScalar(at: address, value: value, byteCount: 8) }
    try physical.writeScalar(at: 0x8000, value: 5, byteCount: 8)
    return physical
  }

  private func state(rip: UInt64) throws -> DoryX86ArchitecturalState {
    try .init(registers: .init(rbx: 0x8000), rip: rip,
      cs: .init(selector: 3, attributes: 0xA0FB, limit: .max),
      control: .init(cr0: 0x8001_0011, cr2: 0x1234, cr3: 0x9000, cr4: 1 << 5,
        efer: (1 << 10) | (1 << 11)))
  }

  private func translatedMemory(_ physical: DoryX86ByteArrayMemory, state: DoryX86ArchitecturalState)
    -> (DoryX86PagingUnit, DoryX86TranslatedMemory) {
    let paging = DoryX86PagingUnit()
    return (paging, .init(physicalMemory: physical, pagingUnit: paging,
      context: .init(state: state, mode: .long64)))
  }

  private func speculativeBytes(_ translated: DoryX86TranslatedMemory,
    at address: UInt64, count: Int) throws -> [UInt8] {
    try translated.instructionBytes(at: address,
      maximumCount: min(count, Int(4096 - (address & 0xFFF))))
  }

  private func runChain(_ executor: DoryARM64BaselineExecutor,
    state: inout DoryX86ArchitecturalState, translated: DoryX86TranslatedMemory) throws
    -> DoryARM64ExecutionSummary? {
    try executor.executeChainedSummary(
      byteProvider: { try speculativeBytes(translated, at: $0, count: $1) },
      codeGenerationProvider: { try translated.codeGeneration(at: $0, byteCount: $1) },
      at: state.rip, mode: .long64, addressSpaceID: 0x9000,
      maximumInstructions: 16, state: &state, memory: translated)
  }

  private func fetchFault(rip: UInt64) -> DoryX86InterpreterResult {
    .exception(.init(kind: .pageFault, vector: 14, errorCode: 0x14,
      instructionPointer: rip, linearAddress: 0x2000))
  }
}
