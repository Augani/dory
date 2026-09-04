import Testing

@testable import DoryDBTX86

@Suite struct DoryARM64MetadataFaultTests {
  @Test func revokedCachedTargetPublishesCompletedStorePrefixBeforePrecisePageFault() throws {
    #if arch(arm64)
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let physical = try memory()
        // INC qword [RBX]; INC RCX; JMP 0x2000. The first store must commit once.
        try physical.write(at: 0x1000,
          bytes: [0x48, 0xFF, 0x03, 0x48, 0xFF, 0xC1, 0xE9, 0xF5, 0x0F, 0, 0])
        try physical.write(at: 0x2000, bytes: [0x48, 0xFF, 0xC2]) // INC RDX, previously executable.
        try physical.writeScalar(at: 0x8000, value: 5, byteCount: 8)
        let initial = try state(rip: 0x1000)
        let paging = DoryX86PagingUnit()
        let translated = DoryX86TranslatedMemory(physicalMemory: physical, pagingUnit: paging,
          context: .init(state: initial, mode: .long64))
        let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 16384, optimization: optimization)
        var warm = try state(rip: 0x2000)
        _ = try #require(executor.executeSummary(
          byteProvider: { try translated.instructionBytes(at: 0x2000, maximumCount: $0) },
          codeGenerationProvider: { try translated.codeGeneration(at: 0x2000, byteCount: $0) },
          at: 0x2000, mode: .long64, addressSpaceID: 0x9000, maximumInstructions: 1,
          state: &warm, memory: translated))
        try physical.writeScalar(at: 0xC010, value: 0, byteCount: 8)
        paging.invalidateAll()
        var state = initial
        var metadataFaults = 0
        let summary = try #require(executor.executeChainedSummary(
          byteProvider: { (try? translated.instructionBytes(at: $0, maximumCount: $1)) ?? [] },
          codeGenerationProvider: { address, count in
            do { return try translated.codeGeneration(at: address, byteCount: count) }
            catch { metadataFaults += 1; throw error }
          }, at: state.rip, mode: .long64, addressSpaceID: 0x9000,
          maximumInstructions: 16, state: &state, memory: translated))
        #expect(metadataFaults > 0)
        #expect(summary.exitCode == .dispatch)
        #expect(summary.guestInstructionCount == 3)
        #expect(summary.residentBlockCount > 0)
        #expect(state.rip == 0x2000)
        #expect(state.registers.rcx == 1)
        #expect(state.registers.rdx == 0)
        #expect(try physical.readScalar(at: 0x8000, byteCount: 8) == 6)
        for _ in 0..<2 {
          let before = state
          #expect(try executor.executeChainedSummary(
            byteProvider: { (try? translated.instructionBytes(at: $0, maximumCount: $1)) ?? [] },
            codeGenerationProvider: { try translated.codeGeneration(at: $0, byteCount: $1) },
            at: state.rip, mode: .long64, addressSpaceID: 0x9000,
            maximumInstructions: 16, state: &state, memory: translated) == nil)
          #expect(state == before)
          #expect(DoryX86Interpreter().step(state: &state, memory: physical, mode: .long64,
            pagingUnit: paging, translatedMemory: translated)
            == .exception(.init(kind: .pageFault, vector: 14, errorCode: 0x14,
              instructionPointer: 0x2000, linearAddress: 0x2000)))
          #expect(state.rip == 0x2000 && state.registers.rcx == 1 && state.registers.rdx == 0)
          #expect(try physical.readScalar(at: 0x8000, byteCount: 8) == 6)
        }
      }
    #endif
  }

  @Test func traceMetadataFaultInvalidatesProofBeforeBatchAndPreservesValidPrefix() throws {
    #if arch(arm64)
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let physical = try memory()
        try physical.write(at: 0x1000, bytes: [0x48, 0xFF, 0xC1, 0xE9, 0xF8, 0x0F, 0, 0])
        try physical.write(at: 0x2000, bytes: [0x48, 0xFF, 0xC2, 0xE9, 0xF8, 0xEF, 0xFF, 0xFF])
        let initial = try state(rip: 0x1000)
        let paging = DoryX86PagingUnit()
        let translated = DoryX86TranslatedMemory(physicalMemory: physical, pagingUnit: paging,
          context: .init(state: initial, mode: .long64))
        let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 16384, optimization: optimization)
        func run(_ state: inout DoryX86ArchitecturalState) throws -> DoryARM64ExecutionSummary? {
          try executor.executeChainedSummary(
            byteProvider: { (try? translated.instructionBytes(at: $0, maximumCount: $1)) ?? [] },
            codeGenerationProvider: { try translated.codeGeneration(at: $0, byteCount: $1) },
            at: state.rip, mode: .long64, addressSpaceID: 0x9000,
            maximumInstructions: 4, state: &state, memory: translated)
        }
        var warm = initial
        #expect(try #require(try run(&warm)).guestInstructionCount == 4)
        #expect(warm.rip == 0x1000)
        try physical.writeScalar(at: 0xC010, value: 0, byteCount: 8)
        paging.invalidateAll()
        var state = initial
        let summary = try #require(try run(&state))
        #expect(summary.guestInstructionCount == 2)
        #expect(summary.exitCode == .dispatch)
        #expect(state.rip == 0x2000)
        #expect(state.registers.rcx == 1 && state.registers.rdx == 0)
        #expect(executor.diagnostics.nativeTraceAttempts == 1)
        #expect(executor.nativeBatchExecutionCount == 0)
      }
    #endif
  }

  @Test func unavailableMetadataStillValidatesChangedBytesAndAllowsFreshCompilation() throws {
    #if arch(arm64)
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 16384, optimization: optimization)
        for (value, generationThrows): (UInt8, Bool) in [(1, false), (2, true), (3, true)] {
          let bytes: [UInt8] = [0xB8, value, 0, 0, 0]
          var state = try DoryX86ArchitecturalState(rip: 0x1000)
          let result = try #require(executor.executeSummary(byteProvider: { Array(bytes.prefix($0)) },
            codeGenerationProvider: { _ in
              if generationThrows { throw DoryX86MemoryError.pageFault(address: 0x1000, errorCode: 0x14) }
              return 1
            }, at: state.rip, mode: .long64, addressSpaceID: 0,
            maximumInstructions: 1, state: &state))
          #expect(result.guestInstructionCount == 1)
          #expect(state.registers.rax == UInt64(value))
        }
      }
    #endif
  }

  private func memory() throws -> DoryX86ByteArrayMemory {
    let physical = DoryX86ByteArrayMemory(byteCount: 0x10000)
    for (address, value): (UInt64, UInt64) in [
      (0x9000, 0xA007), (0xA000, 0xB007), (0xB000, 0xC007),
      (0xC008, 0x1007), (0xC010, 0x2007), (0xC040, 0x8007),
    ] { try physical.writeScalar(at: address, value: value, byteCount: 8) }
    return physical
  }

  private func state(rip: UInt64) throws -> DoryX86ArchitecturalState {
    try .init(registers: .init(rbx: 0x8000), rip: rip,
      cs: .init(selector: 3, attributes: 0xA0FB, limit: .max),
      control: .init(cr0: 0x8001_0011, cr3: 0x9000, cr4: 1 << 5,
        efer: (1 << 10) | (1 << 11)))
  }
}
