import Testing

@testable import DoryDBTX86

@Suite struct DoryARM64Tier1JITTests {
  @Test func compilerAdmitsRegisterALUAndDeclinesMemoryBlocksAtomically() throws {
    let registerBlock = try DoryX86IRTranslator().translate(
      [0x48, 0x01, 0xD8],  // add rax, rbx
      at: 0x1000,
      mode: .long64
    )
    let compiled = try #require(DoryARM64Tier1Emitter().compile(registerBlock))
    #expect(compiled.tier == .tier1)
    #expect(compiled.exitCode == .dispatch)
    #expect(compiled.guestInstructionCount == 1)
    #expect(compiled.machineWords.last == 0xD65F_03C0)

    let memoryBlock = try DoryX86IRTranslator().translate(
      [0x48, 0x01, 0x18],  // add [rax], rbx
      at: 0x2000,
      mode: .long64
    )
    #expect(DoryARM64Tier1Emitter().compile(memoryBlock) == nil)
  }

  @Test func executorRunsTier1BlockAndAggregatesOnDemandMaterialization() throws {
    #if arch(arm64)
      let address: UInt64 = 0x1000
      let bytes: [UInt8] = [
        0x48, 0x01, 0xD8,  // add rax, rbx
        0x0F, 0x9A, 0xC1,  // setp cl; parity requires lazy materialization
      ]
      let initialFlags: DoryX86RFLAGS = [.reservedOne, .carry, .direction]
      let initialRegisters = DoryX86GeneralRegisters(
        rax: 1,
        rcx: 0xA5A5_A5A5_A5A5_A5FF,
        rbx: 2
      )

      let memory = try DoryX86ByteArrayMemory(byteCount: 0x2000)
      try memory.write(at: address, bytes: bytes)
      var interpreted = try DoryX86ArchitecturalState(
        registers: initialRegisters,
        rip: address,
        rflags: initialFlags
      )
      for _ in 0..<2 {
        guard
          case .retired = DoryX86Interpreter().step(
            state: &interpreted,
            memory: memory,
            mode: .long64
          )
        else {
          Issue.record("interpreter did not retire tier-1 differential fixture")
          return
        }
      }

      var tier1 = try DoryX86ArchitecturalState(
        registers: initialRegisters,
        rip: address,
        rflags: initialFlags
      )
      let executor = try DoryARM64BaselineExecutor(
        maximumCodeBytes: 16 * 1024,
        tier1Enabled: true
      )
      let execution = try #require(
        executor.execute(
          bytes: bytes,
          at: address,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 2,
          state: &tier1
        ))

      #expect(execution.block.tier == .tier1)
      #expect(execution.exitCode == .dispatch)
      #expect(tier1.registers == interpreted.registers)
      #expect(tier1.rip == interpreted.rip)
      #expect(tier1.rflags == interpreted.rflags)
      #expect(executor.diagnostics.compiledBlocks == 1)
      #expect(executor.diagnostics.tier1CompiledBlocks == 1)
      #expect(executor.diagnostics.lazyFlagMaterializations == 1)
    #endif
  }

  @Test func disabledAndDeclinedTier1PathsRetainTheOldBaseline() throws {
    #if arch(arm64)
      let address: UInt64 = 0x3000
      let bytes: [UInt8] = [0x48, 0xB8, 1, 0, 0, 0, 0, 0, 0, 0]  // mov rax, 1
      for tier1Enabled in [false, true] {
        let executor = try DoryARM64BaselineExecutor(
          maximumCodeBytes: 4096,
          tier1Enabled: tier1Enabled
        )
        var state = try DoryX86ArchitecturalState(rip: address)
        let execution = try #require(
          executor.execute(
            bytes: bytes,
            at: address,
            mode: .long64,
            addressSpaceID: 0,
            maximumInstructions: 1,
            state: &state
          ))
        #expect(execution.block.tier == .baseline)
        #expect(state.registers.rax == 1)
        #expect(executor.diagnostics.tier1CompiledBlocks == 0)
      }
    #endif
  }

  @Test func compilerFusesCompareBranchWithoutMaterializingFlags() throws {
    #if arch(arm64)
      let address: UInt64 = 0x4000
      let bytes: [UInt8] = [
        0x48, 0x39, 0xD8,  // cmp rax, rbx
        0x75, 0x04,  // jne 0x4009
      ]
      let executor = try DoryARM64BaselineExecutor(
        maximumCodeBytes: 4096,
        tier1Enabled: true
      )
      for (rax, expectedRIP): (UInt64, UInt64) in [(7, 0x4009), (9, 0x4005)] {
        var state = try DoryX86ArchitecturalState(
          registers: .init(rax: rax, rbx: 9),
          rip: address
        )
        let execution = try #require(
          executor.execute(
            bytes: bytes,
            at: address,
            mode: .long64,
            addressSpaceID: 0,
            maximumInstructions: 2,
            state: &state
          ))
        #expect(execution.block.tier == .tier1)
        #expect(state.rip == expectedRIP)
      }
      #expect(executor.diagnostics.tier1CompiledBlocks == 1)
      #expect(executor.diagnostics.lazyFlagMaterializations == 0)
    #endif
  }

  @Test func chainedExecutionAggregatesTier1MaterializationsOnce() throws {
    #if arch(arm64)
      let first: [UInt8] = [
        0x48, 0x01, 0xD8,  // add rax, rbx
        0xEB, 0x0B,  // jmp 0x5010
      ]
      let second: [UInt8] = [
        0x48, 0x01, 0xD8,  // add rax, rbx
        0x0F, 0x9A, 0xC1,  // setp cl
      ]
      let executor = try DoryARM64BaselineExecutor(
        maximumCodeBytes: 16 * 1024,
        tier1Enabled: true
      )
      var state = try DoryX86ArchitecturalState(
        registers: .init(rax: 1, rcx: 0xFFFF, rbx: 1),
        rip: 0x5000
      )
      let summary = try #require(
        executor.executeChainedSummary(
          byteProvider: { address, count in
            let bytes = address == 0x5000 ? first : address == 0x5010 ? second : []
            return Array(bytes.prefix(count))
          },
          at: state.rip,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 4,
          state: &state
        ))

      #expect(summary.tier == .tier1)
      #expect(summary.guestInstructionCount == 4)
      #expect(summary.residentBlockCount == 2)
      #expect(state.registers.rax == 3)
      #expect(state.registers.rcx == 0xFF01)
      #expect(state.rip == 0x5016)
      #expect(executor.diagnostics.tier1CompiledBlocks == 2)
      #expect(executor.diagnostics.lazyFlagMaterializations == 1)
    #endif
  }
}
