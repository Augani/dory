import Testing

@testable import DoryDBTX86

@Suite struct DoryARM64BaselineJITTests {
  @Test func emitsDeterministicARM64ForRegisterImmediateMoves() throws {
    let block = try DoryX86IRTranslator().translate(
      [0x48, 0xB8, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11, 0x90],
      at: 0x1000,
      mode: .long64
    )
    let emitter = DoryARM64BaselineEmitter()
    let first = emitter.compile(block)
    let second = emitter.compile(block)

    #expect(first == second)
    #expect(first.tier == .baseline)
    #expect(first.exitCode == .dispatch)
    #expect(first.machineWords.last == 0xD65F_03C0)
    #expect(first.machineBytes.count == first.machineWords.count * 4)
  }

  @Test func unsupportedIRProducesAClosedInterpreterFallbackStub() throws {
    let block = try DoryX86IRTranslator().translate(
      [0x0F, 0xA2],
      at: 0x2000,
      mode: .long64
    )
    let compiled = DoryARM64BaselineEmitter().compile(block)

    #expect(compiled.tier == .interpreterFallback)
    #expect(compiled.exitCode == .interpreter)
    #expect(compiled.machineWords.last == 0xD65F_03C0)
  }

  @Test func executorLoadsAndStoresGuestMemoryThroughBoundedCallbacks() throws {
    #if arch(arm64)
      let memory = DoryX86ByteArrayMemory(byteCount: 0x100)
      try memory.write(at: 0x80, bytes: [0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11])
      let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096)
      var state = try DoryX86ArchitecturalState(registers: .init(rax: 0x80), rip: 0x1000)

      let load = try #require(
        executor.execute(
          bytes: [0x48, 0x8B, 0x18],
          at: state.rip,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 1,
          state: &state,
          memory: memory
        )
      )
      #expect(load.block.requiresMemoryCallbacks)
      #expect(load.exitCode == .dispatch)
      #expect(state.registers.rbx == 0x1122_3344_5566_7788)

      state.rip = 0x2000
      state.registers.rax = 0x88
      let store = try #require(
        executor.execute(
          bytes: [0x48, 0x89, 0x18],
          at: state.rip,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 1,
          state: &state,
          memory: memory
        )
      )
      #expect(store.exitCode == .dispatch)
      #expect(
        try memory.read(at: 0x88, byteCount: 8) == [0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11])
    #endif
  }

  @Test func failedNativeMemoryAccessLeavesTheInstructionRestartable() throws {
    #if arch(arm64)
      let memory = DoryX86ByteArrayMemory(byteCount: 0x100)
      let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096)
      let initial = try DoryX86ArchitecturalState(
        registers: .init(rax: 0x1000, rbx: 0xCAFE), rip: 0x3000)
      var state = initial

      let execution = try #require(
        executor.execute(
          bytes: [0x48, 0x8B, 0x18],
          at: state.rip,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 1,
          state: &state,
          memory: memory
        )
      )
      #expect(execution.exitCode == .interpreter)
      #expect(state == initial)
    #endif
  }

  @Test func executorPerformsNativeMemoryALUAndReadModifyWrite() throws {
    #if arch(arm64)
      let memory = DoryX86ByteArrayMemory(byteCount: 0x100)
      try memory.write(at: 0x80, bytes: [5, 0, 0, 0, 0, 0, 0, 0])
      let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096)
      var state = try DoryX86ArchitecturalState(
        registers: .init(rax: 0x80, rbx: 3), rip: 0x4000)

      let source = try #require(
        executor.execute(
          bytes: [0x48, 0x03, 0x18],
          at: state.rip,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 1,
          state: &state,
          memory: memory
        )
      )
      #expect(source.exitCode == .dispatch)
      #expect(state.registers.rbx == 8)

      state.rip = 0x5000
      state.registers.rbx = 3
      let destination = try #require(
        executor.execute(
          bytes: [0x48, 0x01, 0x18],
          at: state.rip,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 1,
          state: &state,
          memory: memory
        )
      )
      #expect(destination.exitCode == .dispatch)
      #expect(try memory.read(at: 0x80, byteCount: 8) == [8, 0, 0, 0, 0, 0, 0, 0])
      #expect(!state.rflags.contains(.zero))
    #endif
  }

  @Test func executorPerformsNativeUnaryMemoryUpdates() throws {
    #if arch(arm64)
      let memory = DoryX86ByteArrayMemory(byteCount: 0x100)
      try memory.write(at: 0x80, bytes: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F])
      let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096)
      var state = try DoryX86ArchitecturalState(
        registers: .init(rax: 0x80),
        rip: 0x6000,
        rflags: [.reservedOne, .carry]
      )

      let execution = try #require(
        executor.execute(
          bytes: [0x48, 0xFF, 0x00],
          at: state.rip,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 1,
          state: &state,
          memory: memory
        )
      )
      #expect(execution.exitCode == .dispatch)
      #expect(try memory.read(at: 0x80, byteCount: 8) == [0, 0, 0, 0, 0, 0, 0, 0x80])
      #expect(state.rflags.contains(.overflow))
      #expect(state.rflags.contains(.carry))
    #endif
  }

  @Test func boundedCacheEvictsAndInvalidatesDeterministically() throws {
    let emitter = DoryARM64BaselineEmitter()
    let translator = DoryX86IRTranslator()
    let first = emitter.compile(try translator.translate([0x90], at: 0x1000, mode: .long64))
    let second = emitter.compile(try translator.translate([0x90], at: 0x2000, mode: .long64))
    let capacity = first.machineBytes.count + second.machineBytes.count - 1
    let cache = DoryJITCodeCache(maximumBytes: capacity)
    let firstKey = DoryJITBlockKey(guestStart: 0x1000, addressSpaceID: 7, codeGeneration: 1)
    let secondKey = DoryJITBlockKey(guestStart: 0x2000, addressSpaceID: 7, codeGeneration: 1)

    cache.insert(first, for: firstKey)
    cache.insert(second, for: secondKey)
    #expect(cache.block(for: firstKey) == nil)
    #expect(cache.block(for: secondKey) == second)
    cache.invalidate(addressSpaceID: 7, guestRange: 0x1fff..<0x2001)
    #expect(cache.residentBlockCount == 0)
    #expect(cache.residentByteCount == 0)
  }

  @Test func blockIdentityIncludesEveryArchitecturalTranslationContext() {
    let base = DoryJITBlockKey(
      guestStart: 0x1000,
      addressSpaceID: 7,
      codeGeneration: 3,
      cpuProfileIdentifier: "profile-a",
      executionMode: .long64,
      privilegeLevel: 0,
      pagingEnabled: true
    )
    #expect(
      base
        != .init(
          guestStart: 0x1000,
          addressSpaceID: 7,
          codeGeneration: 3,
          cpuProfileIdentifier: "profile-b",
          executionMode: .long64,
          privilegeLevel: 0,
          pagingEnabled: true
        ))
    #expect(
      base
        != .init(
          guestStart: 0x1000,
          addressSpaceID: 7,
          codeGeneration: 3,
          cpuProfileIdentifier: "profile-a",
          executionMode: .protected32,
          privilegeLevel: 0,
          pagingEnabled: true
        ))
    #expect(
      base
        != .init(
          guestStart: 0x1000,
          addressSpaceID: 7,
          codeGeneration: 3,
          cpuProfileIdentifier: "profile-a",
          executionMode: .long64,
          privilegeLevel: 3,
          pagingEnabled: true
        ))
    #expect(
      base
        != .init(
          guestStart: 0x1000,
          addressSpaceID: 7,
          codeGeneration: 3,
          cpuProfileIdentifier: "profile-a",
          executionMode: .long64,
          privilegeLevel: 0,
          pagingEnabled: false
        ))
  }

  @Test func executorInvalidatesOnlyOverlappingAddressSpaceBlocks() throws {
    #if arch(arm64)
      let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096)
      var state = try DoryX86ArchitecturalState(rip: 0x9000)
      _ = try #require(
        executor.execute(
          bytes: [0x90],
          at: 0x9000,
          mode: .long64,
          addressSpaceID: 1,
          maximumInstructions: 1,
          state: &state
        ))
      state.rip = 0xA000
      _ = try #require(
        executor.execute(
          bytes: [0x90],
          at: 0xA000,
          mode: .long64,
          addressSpaceID: 1,
          maximumInstructions: 1,
          state: &state
        ))
      state.rip = 0x9000
      _ = try #require(
        executor.execute(
          bytes: [0x90],
          at: 0x9000,
          mode: .long64,
          addressSpaceID: 2,
          maximumInstructions: 1,
          state: &state
        ))
      #expect(executor.residentBlockCount == 3)

      executor.invalidate(addressSpaceID: 1, guestRange: 0x8FFF..<0x9001)
      #expect(executor.residentBlockCount == 2)

      state.rip = 0x9000
      _ = try #require(
        executor.execute(
          bytes: [0x90],
          at: 0x9000,
          mode: .long64,
          addressSpaceID: 1,
          maximumInstructions: 1,
          state: &state
        ))
      #expect(executor.residentBlockCount == 3)
    #endif
  }

  @Test func publishesAndExecutesThroughTheGuardedMAPJITRegion() throws {
    #if arch(arm64)
      let block = try DoryX86IRTranslator().translate(
        [0x48, 0xB8, 0x78, 0x56, 0x34, 0x12, 0, 0, 0, 0],
        at: 0x4000,
        mode: .long64
      )
      let compiled = DoryARM64BaselineEmitter().compile(block)
      let region = try DoryJITExecutableRegion(minimumCapacity: 4096)
      try region.publish(compiled, at: 0)
      var context = [UInt64](repeating: 0, count: DoryJITExecutableRegion.contextWordCount)

      let exit = try region.execute(at: 0, context: &context)
      #expect(exit == .dispatch)
      #expect(context[0] == 0x1234_5678)
      #expect(context[16] == 0x400A)
    #endif
  }

  @Test func boundedExecutorRecompilesChangedGuestCode() throws {
    #if arch(arm64)
      let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096)
      var state = try DoryX86ArchitecturalState(rip: 0x5000)
      let first = try #require(
        executor.execute(
          bytes: [0x48, 0xB8, 1, 0, 0, 0, 0, 0, 0, 0],
          at: state.rip,
          mode: .long64,
          addressSpaceID: 7,
          maximumInstructions: 1,
          state: &state
        )
      )
      #expect(first.block.guestInstructionCount == 1)
      #expect(state.registers.rax == 1)
      #expect(state.rip == 0x500A)

      state.rip = 0x5000
      let second = try #require(
        executor.execute(
          bytes: [0x48, 0xB8, 2, 0, 0, 0, 0, 0, 0, 0],
          at: state.rip,
          mode: .long64,
          addressSpaceID: 7,
          maximumInstructions: 1,
          state: &state
        )
      )
      #expect(second.block.guestInstructionCount == 1)
      #expect(state.registers.rax == 2)
      #expect(executor.residentBlockCount == 2)
    #endif
  }

  @Test func optimizingTierPropagatesConstantsAndEliminatesExactSelfCopies() throws {
    let translated = try DoryX86IRTranslator().translate(
      [
        0x48, 0xB8, 1, 0, 0, 0, 0, 0, 0, 0,  // mov rax,1
        0x48, 0x89, 0xC3,  // mov rbx,rax
        0x48, 0x89, 0xC9,  // mov rcx,rcx
        0xF4,
      ],
      at: 0x6000,
      mode: .long64
    )
    let result = DoryIROptimizer().optimize(translated)

    #expect(result.metrics.propagatedConstants == 1)
    #expect(result.metrics.eliminatedStatements == 1)
    #expect(result.block.guestInstructionCount == translated.guestInstructionCount)
    #expect(result.block.guestByteCount == translated.guestByteCount)
    #expect(result.block.statements.count == 2)
    guard case .copy(_, .immediate(let value, width: .i64)) = result.block.statements[1]
    else {
      Issue.record("expected propagated immediate")
      return
    }
    #expect(value == 1)
    #expect(DoryARM64BaselineEmitter().compile(result.block, tier: .optimizing).tier == .optimizing)
  }

  @Test func optimizingExecutorPublishesAnOptimizingBlock() throws {
    #if arch(arm64)
      let executor = try DoryARM64BaselineExecutor(
        maximumCodeBytes: 4096,
        optimization: .optimizing
      )
      var state = try DoryX86ArchitecturalState(rip: 0x7000)
      let execution = try #require(
        executor.execute(
          bytes: [0xB8, 1, 0, 0, 0, 0x83, 0xC0, 2, 0xF4],
          at: state.rip,
          mode: .long64,
          addressSpaceID: 9,
          maximumInstructions: 3,
          state: &state
        )
      )
      #expect(execution.block.tier == .optimizing)
      #expect(execution.exitCode == .halt)
      #expect(state.registers.rax == 3)
    #endif
  }

  @Test func optimizingAndBaselineTiersHaveExactArchitecturalParity() throws {
    #if arch(arm64)
      let bytes: [UInt8] = [
        0x48, 0xB8, 1, 0, 0, 0, 0, 0, 0, 0,  // mov rax,1
        0x48, 0x89, 0xC3,  // mov rbx,rax
        0x48, 0x83, 0xC3, 2,  // add rbx,2
        0x48, 0x89, 0xC9,  // mov rcx,rcx
        0xF4,
      ]
      let baseline = try DoryARM64BaselineExecutor(
        maximumCodeBytes: 4096,
        optimization: .baseline
      )
      let optimizing = try DoryARM64BaselineExecutor(
        maximumCodeBytes: 4096,
        optimization: .optimizing
      )
      var baselineState = try DoryX86ArchitecturalState(rip: 0x8000)
      baselineState.registers.rcx = 0xfeed_face
      var optimizingState = baselineState

      let baselineExecution = try #require(
        baseline.execute(
          bytes: bytes,
          at: 0x8000,
          mode: .long64,
          addressSpaceID: 11,
          maximumInstructions: 5,
          state: &baselineState
        )
      )
      let optimizingExecution = try #require(
        optimizing.execute(
          bytes: bytes,
          at: 0x8000,
          mode: .long64,
          addressSpaceID: 11,
          maximumInstructions: 5,
          state: &optimizingState
        )
      )

      #expect(baselineExecution.exitCode == optimizingExecution.exitCode)
      #expect(baselineExecution.block.guestInstructionCount == 5)
      #expect(optimizingExecution.block.guestInstructionCount == 5)
      #expect(baselineState == optimizingState)
    #endif
  }
}
