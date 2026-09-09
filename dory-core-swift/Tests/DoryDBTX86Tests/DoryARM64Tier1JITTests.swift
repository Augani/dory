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

  @Test func disabledTier1AndDeclinedMemoryPathsRetainTheOldBaseline() throws {
    #if arch(arm64)
      let address: UInt64 = 0x3000
      let registerBytes: [UInt8] = [0x48, 0xB8, 1, 0, 0, 0, 0, 0, 0, 0]  // mov rax, 1
      let memoryBytes: [UInt8] = [0x48, 0x8B, 0x00]  // mov rax, [rax]
      for (tier1Enabled, bytes) in [(false, registerBytes), (true, memoryBytes)] {
        let memory = try DoryX86ByteArrayMemory(byteCount: 0x4000)
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
            state: &state,
            memory: memory
          ))
        #expect(execution.block.tier == .baseline)
        #expect(state.registers.rax == (tier1Enabled ? 0 : 1))
        #expect(executor.diagnostics.tier1CompiledBlocks == 0)
      }
    #endif
  }

  @Test func registerMovesAndNotPreservePartialRegistersAndFuseFollowingBranch() throws {
    #if arch(arm64)
      let address: UInt64 = 0x3800
      let bytes: [UInt8] = [
        0x48, 0x39, 0xD8,  // cmp rax, rbx
        0x88, 0xD1,  // mov cl, dl
        0x66, 0xF7, 0xD1,  // not cx
        0x75, 0x04,  // jne 0x380e
      ]
      let initial = try DoryX86ArchitecturalState(
        registers: .init(
          rax: 7,
          rcx: 0xA5A5_A5A5_A5A5_A5FF,
          rdx: 0x12,
          rbx: 9
        ),
        rip: address,
        rflags: [.reservedOne, .carry, .direction]
      )
      let memory = try DoryX86ByteArrayMemory(byteCount: 0x5000)
      try memory.write(at: address, bytes: bytes)
      var interpreted = initial
      for _ in 0..<4 {
        guard case .retired = DoryX86Interpreter().step(
          state: &interpreted,
          memory: memory,
          mode: .long64
        ) else {
          Issue.record("interpreter did not retire tier-1 MOV/NOT fixture")
          return
        }
      }

      var tier1 = initial
      let executor = try DoryARM64BaselineExecutor(
        maximumCodeBytes: 4096,
        tier1Enabled: true
      )
      let execution = try #require(executor.execute(
        bytes: bytes,
        at: address,
        mode: .long64,
        addressSpaceID: 0,
        maximumInstructions: 4,
        state: &tier1
      ))

      #expect(execution.block.tier == .tier1)
      #expect(tier1.registers == interpreted.registers)
      #expect(tier1.rip == interpreted.rip)
      #expect(tier1.rflags == interpreted.rflags)
      #expect(tier1.registers.rcx == 0xA5A5_A5A5_A5A5_5AED)
      // MOV/NOT and Jcc preserve/consume the native NZCV image. The sole materialization is the
      // required architectural publication before Swift can inspect state or deliver an interrupt.
      #expect(executor.diagnostics.lazyFlagMaterializations == 1)
    #endif
  }

  @Test func wordAndDwordRegisterMovesApplyTheirArchitecturalWriteWidths() throws {
    #if arch(arm64)
      let executor = try DoryARM64BaselineExecutor(
        maximumCodeBytes: 4096,
        tier1Enabled: true
      )
      for (bytes, expectedRAX): ([UInt8], UInt64) in [
        ([0x66, 0x89, 0xD8], 0xFFFF_FFFF_FFFF_4567),  // mov ax, bx
        ([0x89, 0xD8], 0x8123_4567),  // mov eax, ebx
      ] {
        var state = try DoryX86ArchitecturalState(
          registers: .init(rax: .max, rbx: 0xFFFF_FFFF_8123_4567),
          rip: 0x3900
        )
        let execution = try #require(executor.execute(
          bytes: bytes,
          at: state.rip,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 1,
          state: &state
        ))

        #expect(execution.block.tier == .tier1)
        #expect(state.registers.rax == expectedRAX)
        #expect(state.rip == 0x3900 + UInt64(bytes.count))
      }
    #endif
  }

  @Test func wordNotPreservesUpperBitsAndFlagsAcrossBaselineAndTier1() throws {
    #if arch(arm64)
      let bytes: [UInt8] = [0x66, 0xF7, 0xD1]  // not cx
      for tier1Enabled in [false, true] {
        let executor = try DoryARM64BaselineExecutor(
          maximumCodeBytes: 4096,
          tier1Enabled: tier1Enabled
        )
        let initialFlags: DoryX86RFLAGS = [.reservedOne, .carry, .parity, .direction]
        var state = try DoryX86ArchitecturalState(
          registers: .init(rcx: 0xA5A5_A5A5_A5A5_1234),
          rip: 0x3980,
          rflags: initialFlags
        )
        let execution = try #require(executor.execute(
          bytes: bytes,
          at: state.rip,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 1,
          state: &state
        ))

        #expect(execution.block.tier == (tier1Enabled ? .tier1 : .baseline))
        #expect(state.registers.rcx == 0xA5A5_A5A5_A5A5_EDCB)
        #expect(state.rflags == initialFlags)
      }
    #endif
  }

  @Test func compilerFusesCompareBranchUntilTheArchitecturalExitBoundary() throws {
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
      // Neither branch materializes in generated code; each returned state is materialized once at
      // the dispatcher boundary before any external consumer (including interrupt delivery).
      #expect(executor.diagnostics.lazyFlagMaterializations == 2)
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

  @Test func loadFlagsIntoAHMaterializesThePendingTier1Producer() throws {
    #if arch(arm64)
      let address: UInt64 = 0x5800
      let bytes: [UInt8] = [
        0x48, 0x01, 0xD8,  // add rax, rbx
        0x9F,  // lahf
      ]
      let translated = try DoryX86IRTranslator().translate(bytes, at: address, mode: .long64)
      #expect(translated.statements.last == .loadFlagsIntoAH)

      let initial = try DoryX86ArchitecturalState(
        registers: .init(rax: 0x0100, rbx: UInt64.max),
        rip: address,
        rflags: [.reservedOne, .direction]
      )
      let memory = try DoryX86ByteArrayMemory(byteCount: 0x6000)
      try memory.write(at: address, bytes: bytes)
      var interpreted = initial
      for _ in 0..<2 {
        guard case .retired = DoryX86Interpreter().step(
          state: &interpreted,
          memory: memory,
          mode: .long64
        ) else {
          Issue.record("interpreter did not retire tier-1 LAHF fixture")
          return
        }
      }

      var tier1 = initial
      let executor = try DoryARM64BaselineExecutor(
        maximumCodeBytes: 4096,
        tier1Enabled: true
      )
      let execution = try #require(executor.execute(
        bytes: bytes,
        at: address,
        mode: .long64,
        addressSpaceID: 0,
        maximumInstructions: 2,
        state: &tier1
      ))

      #expect(execution.block.tier == .tier1)
      #expect(tier1 == interpreted)
      #expect(executor.diagnostics.lazyFlagMaterializations == 1)
    #endif
  }

  @Test func SAHFAndLAHFRoundTripAcrossLegacyBaselineAndTier1() throws {
    #if arch(arm64)
      let bytes: [UInt8] = [0x9E, 0x9F]
      let initial = try DoryX86ArchitecturalState(
        registers: .init(rax: 0xA5A5_A5A5_A5A5_D500),
        rip: 0x5900,
        rflags: [.reservedOne, .overflow, .direction]
      )
      let memory = try DoryX86ByteArrayMemory(byteCount: 0x6000)
      try memory.write(at: initial.rip, bytes: bytes)
      var interpreted = initial
      for _ in 0..<2 {
        guard case .retired = DoryX86Interpreter().step(
          state: &interpreted,
          memory: memory,
          mode: .long64
        ) else {
          Issue.record("interpreter did not retire SAHF/LAHF fixture")
          return
        }
      }

      for tier1Enabled in [false, true] {
        var state = initial
        let executor = try DoryARM64BaselineExecutor(
          maximumCodeBytes: 4096,
          tier1Enabled: tier1Enabled
        )
        let execution = try #require(executor.execute(
          bytes: bytes,
          at: state.rip,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 2,
          state: &state
        ))

        #expect(execution.block.tier == (tier1Enabled ? .tier1 : .baseline))
        #expect(state == interpreted)
      }
    #endif
  }

  @Test func longModeFlagByteInstructionsHonorTheAdvertisedFeatureGate() throws {
    #if arch(arm64)
      let base = DoryX86CPUProfile.compatibleV1
      let profile = DoryX86CPUProfile(
        identifier: "test.tier1.no-lahf64",
        features: base.features.subtracting([.lahf64]),
        physicalAddressBits: base.physicalAddressBits,
        linearAddressBits: base.linearAddressBits,
        virtualTSCFrequencyHz: base.virtualTSCFrequencyHz
      )
      let executor = try DoryARM64BaselineExecutor(
        maximumCodeBytes: 4096,
        cpuProfileIdentifier: profile.identifier,
        physicalAddressBits: profile.physicalAddressBits,
        profile: profile,
        tier1Enabled: true
      )
      var state = try DoryX86ArchitecturalState(rip: 0x5A00)

      #expect(try executor.execute(
        bytes: [0x9F],
        at: state.rip,
        mode: .long64,
        addressSpaceID: 0,
        maximumInstructions: 1,
        state: &state
      ) == nil)
      #expect(state.rip == 0x5A00)
    #endif
  }

  @Test func pushFlagsMaterializesWritesAndPublishesStackPointerAtomically() throws {
    #if arch(arm64)
      let address: UInt64 = 0x600
      let bytes: [UInt8] = [
        0x48, 0x01, 0xD8,  // add rax, rbx
        0x9C,  // pushfq
      ]
      let initial = try DoryX86ArchitecturalState(
        registers: .init(rax: 1, rbx: 2, rsp: 0x1800),
        rip: address,
        rflags: [.reservedOne, .carry, .direction]
      )
      let interpretedMemory = try DoryX86ByteArrayMemory(byteCount: 0x2000)
      try interpretedMemory.write(at: address, bytes: bytes)
      var interpreted = initial
      for _ in 0..<2 {
        guard case .retired = DoryX86Interpreter().step(
          state: &interpreted,
          memory: interpretedMemory,
          mode: .long64
        ) else {
          Issue.record("interpreter did not retire PUSHFQ fixture")
          return
        }
      }

      let tier1Memory = try DoryX86ByteArrayMemory(byteCount: 0x2000)
      var tier1 = initial
      let executor = try DoryARM64BaselineExecutor(
        maximumCodeBytes: 16 * 1024,
        tier1Enabled: true
      )
      let execution = try #require(executor.execute(
        bytes: bytes,
        at: address,
        mode: .long64,
        addressSpaceID: 0,
        maximumInstructions: 2,
        state: &tier1,
        memory: tier1Memory
      ))

      #expect(execution.block.tier == .tier1)
      #expect(execution.block.requiresMemoryCallbacks)
      #expect(execution.block.mayExitToInterpreter)
      #expect(execution.exitCode == .dispatch)
      #expect(tier1.registers == interpreted.registers)
      #expect(tier1.rip == interpreted.rip)
      #expect(tier1.rflags == interpreted.rflags)
      #expect(try tier1Memory.read(at: tier1.registers.rsp, byteCount: 8)
        == interpretedMemory.read(at: interpreted.registers.rsp, byteCount: 8))
      #expect(executor.diagnostics.lazyFlagMaterializations == 1)
    #endif
  }

  @Test func failedPushFlagsWriteLeavesArchitecturalStateRestartable() throws {
    #if arch(arm64)
      let bytes: [UInt8] = [0x9C]
      let initial = try DoryX86ArchitecturalState(
        registers: .init(rsp: 4),
        rip: 0x700,
        rflags: [.reservedOne, .direction]
      )
      var state = initial
      let memory = try DoryX86ByteArrayMemory(byteCount: 0x1000)
      let executor = try DoryARM64BaselineExecutor(
        maximumCodeBytes: 4096,
        tier1Enabled: true
      )
      let execution = try #require(executor.execute(
        bytes: bytes,
        at: state.rip,
        mode: .long64,
        addressSpaceID: 0,
        maximumInstructions: 1,
        state: &state,
        memory: memory
      ))

      #expect(execution.block.tier == .tier1)
      #expect(execution.exitCode == .interpreter)
      #expect(state == initial)
      #expect(memory.snapshot().allSatisfy { $0 == 0 })
    #endif
  }
}
