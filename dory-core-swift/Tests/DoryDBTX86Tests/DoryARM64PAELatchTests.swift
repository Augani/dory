import Testing

@testable import DoryDBTX86

@Suite struct DoryARM64PAELatchTests {
  @Test func invalidPhysicalWidthFailsBeforeJITResourceAllocation() throws {
    for width: UInt8 in [0, 31, 53, 255] {
      #expect(throws: DoryX86StateError.invalidPhysicalAddressBits(width)) {
        try DoryARM64BaselineExecutor(maximumCodeBytes: 16384, physicalAddressBits: width)
      }
    }
  }

  @Test func invalidLegacyPAELatchDeclinesBeforeFetchNativeWritesOrBatchRetirement() throws {
    #if arch(arm64)
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        for latch: DoryX86PAEPDPTEs? in [nil, .init((1 << 40) | 1), .init(3)] {
          let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 16384,
            optimization: optimization)
          var state = try DoryX86ArchitecturalState(rip: 0x100)
          state.control = .init(cr0: 0x8000_0011, cr3: 0x1020, cr4: 1 << 5,
            legacyPAEPDPTEs: latch)
          let original = state
          let memory = try DoryX86ByteArrayMemory(byteCount: 0x1000)
          let originalMemory = memory.snapshot()
          var fetches = 0
          // MOV [0x200],EAX would make a guest-visible write if any path entered native code.
          let bytes: [UInt8] = [0xA3, 0x00, 0x02, 0x00, 0x00]
          #expect(try executor.execute(byteProvider: { count in
            fetches += 1
            return Array(bytes.prefix(count))
          }, at: state.rip, mode: .protected32, addressSpaceID: 0,
            maximumInstructions: 1, state: &state, memory: memory) == nil)
          #expect(try executor.executeSummary(byteProvider: { count in
            fetches += 1
            return Array(bytes.prefix(count))
          }, at: state.rip, mode: .protected32, addressSpaceID: 0,
            maximumInstructions: 1, state: &state, memory: memory) == nil)
          #expect(try executor.executeChainedSummary(byteProvider: { _, count in
            fetches += 1
            return Array(bytes.prefix(count))
          }, at: state.rip, mode: .protected32, addressSpaceID: 0,
            maximumInstructions: 32, state: &state, memory: memory) == nil)
          #expect(fetches == 0)
          #expect(state == original)
          #expect(memory.snapshot() == originalMemory)
          #expect(executor.residentBlockCount == 0)
          #expect(executor.nativeBatchExecutionCount == 0)
          #expect(executor.diagnostics.chainedRetiredInstructions == 0)
          #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .protected32)
            == .exception(.init(kind: .generalProtection, vector: 13, errorCode: 0,
              instructionPointer: original.rip)))
          #expect(state == original)
        }
      }
    #endif
  }

  @Test func validLegacyPAELatchStillPermitsNativeExecutionAtTheSelectedPhysicalWidth() throws {
    #if arch(arm64)
      for width: UInt8 in [40, 48] {
        let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 16384,
          physicalAddressBits: width)
        var state = try DoryX86ArchitecturalState(rip: 0,
          cs: .init(selector: 0, attributes: 0xC09B, limit: .max),
          control: .init(cr0: 0x8000_0011, cr4: 1 << 5,
            legacyPAEPDPTEs: .init((UInt64(1) << (width - 1)) | 1)))
        let execution = try #require(executor.execute(bytes: [0xB8, 0x78, 0x56, 0x34, 0x12],
          at: 0, mode: .protected32, addressSpaceID: 0, maximumInstructions: 1, state: &state))
        #expect(execution.exitCode == .dispatch)
        #expect(execution.block.tier == .baseline)
        #expect(state.registers.rax == 0x1234_5678)
        #expect(state.rip == 5)
      }
    #endif
  }
}
