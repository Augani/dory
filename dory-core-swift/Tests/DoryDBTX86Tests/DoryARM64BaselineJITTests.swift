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

  @Test func generationValidatedNegativeCacheSkipsRepeatedEmitterDeclines() throws {
    #if arch(arm64)
      let bytes: [UInt8] = [0x0F, 0xA2]  // cpuid lowers to a precise interpreter helper.
      let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096)
      var requestedByteCounts: [Int] = []
      func run() throws -> DoryARM64BaselineExecution? {
        var state = try DoryX86ArchitecturalState(rip: 0x2000)
        return try executor.execute(
          byteProvider: { count in
            requestedByteCounts.append(count)
            return Array(bytes.prefix(count))
          },
          codeGenerationProvider: { _ in 7 },
          at: state.rip,
          mode: .long64,
          addressSpaceID: 3,
          maximumInstructions: 1,
          state: &state
        )
      }

      #expect(try run() == nil)
      #expect(requestedByteCounts == [15, 2])
      #expect(try run() == nil)
      #expect(requestedByteCounts == [15, 2])
      let diagnostics = executor.diagnostics
      #expect(diagnostics.declinedCompilations == 1)
      #expect(diagnostics.negativeCacheHits == 1)
      #expect(diagnostics.negativeCacheMisses == 1)
      #expect(diagnostics.negativeGenerationMismatches == 0)
      #expect(diagnostics.negativeEntryCount == 1)
      let hotSite = try #require(diagnostics.negativeCacheHotSites.first)
      #expect(diagnostics.negativeCacheHotSites.count == 1)
      #expect(hotSite.guestRIP == 0x2000)
      #expect(hotSite.executionMode == .long64)
      #expect(hotSite.instructionBudget == 1)
      #expect(hotSite.addressSpaceID == 3)
      #expect(hotSite.privilegeLevel == 0)
      #expect(hotSite.pagingEnabled == false)
      #expect(hotSite.guestByteCount == bytes.count)
      #expect(hotSite.instructionBytes == bytes)
      #expect(hotSite.declineReason == .interpreterHelper)
      #expect(hotSite.hitCount == 1)
    #endif
  }

  @Test func declineDiagnosticsDistinguishHelpersFromNativeEmitterRefusals() {
    let helper = DoryIRBasicBlock(
      guestStart: 0,
      guestByteCount: 2,
      guestInstructionCount: 1,
      statements: [.helper(identifier: "x86.interpret.one", payload: [0x0F, 0xA2])],
      terminator: .exit(.interpreter, resumeAt: 0)
    )
    let invalidRegister = DoryIRRegister(bank: "not.x86.gpr", index: 0, width: .i64)
    let emitterRefusal = DoryIRBasicBlock(
      guestStart: 0,
      guestByteCount: 1,
      guestInstructionCount: 1,
      statements: [
        .copy(
          destination: .register(invalidRegister),
          source: .immediate(1, width: .i64)
        )
      ],
      terminator: .next(1)
    )

    #expect(
      DoryARM64BaselineExecutor.compilationDeclineReason(for: helper) == .interpreterHelper)
    #expect(
      DoryARM64BaselineExecutor.compilationDeclineReason(for: emitterRefusal) == .nativeEmitter)
  }

  @Test func negativeCacheFailsOpenWithoutGenerationAuthority() throws {
    #if arch(arm64)
      let bytes: [UInt8] = [0x0F, 0xA2]
      let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096)
      var byteFetchCount = 0
      func run() throws -> DoryARM64BaselineExecution? {
        var state = try DoryX86ArchitecturalState(rip: 0x2100)
        return try executor.execute(
          byteProvider: { count in
            byteFetchCount += 1
            return Array(bytes.prefix(count))
          },
          at: state.rip,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 1,
          state: &state
        )
      }

      #expect(try run() == nil)
      #expect(try run() == nil)
      #expect(byteFetchCount == 2)
      #expect(executor.diagnostics.declinedCompilations == 2)
      #expect(executor.diagnostics.negativeCacheHits == 0)
      #expect(executor.diagnostics.negativeEntryCount == 0)
      #expect(executor.diagnostics.negativeCacheHotSites.isEmpty)
    #endif
  }

  @Test func negativeCacheGenerationMismatchCompilesChangedGuestCode() throws {
    #if arch(arm64)
      var bytes: [UInt8] = [0x0F, 0xA2]
      var generation: UInt64 = 1
      let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096)
      func run() throws -> DoryARM64BaselineExecution? {
        var state = try DoryX86ArchitecturalState(rip: 0x2200)
        return try executor.execute(
          byteProvider: { count in Array(bytes.prefix(count)) },
          codeGenerationProvider: { _ in generation },
          at: state.rip,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 1,
          state: &state
        )
      }

      #expect(try run() == nil)
      #expect(try run() == nil)
      #expect(executor.diagnostics.negativeCacheHotSites.first?.hitCount == 1)
      bytes = [0x90, 0x90]
      generation = 2
      let execution = try #require(try run())
      #expect(execution.block.guestInstructionCount == 1)
      let diagnostics = executor.diagnostics
      #expect(diagnostics.compiledBlocks == 1)
      #expect(diagnostics.declinedCompilations == 1)
      #expect(diagnostics.negativeGenerationMismatches == 1)
      #expect(diagnostics.negativeEntryCount == 0)
      #expect(diagnostics.negativeCacheHotSites.isEmpty)
    #endif
  }

  @Test func negativeCacheIdentityIncludesTheExactInstructionBudget() throws {
    #if arch(arm64)
      let bytes: [UInt8] = [0x0F, 0xA2]
      let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096)
      func run(budget: Int) throws -> DoryARM64BaselineExecution? {
        var state = try DoryX86ArchitecturalState(rip: 0x2300)
        return try executor.execute(
          byteProvider: { count in Array(bytes.prefix(count)) },
          codeGenerationProvider: { _ in 1 },
          at: state.rip,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: budget,
          state: &state
        )
      }

      #expect(try run(budget: 1) == nil)
      #expect(try run(budget: 2) == nil)
      #expect(executor.diagnostics.declinedCompilations == 2)
      #expect(try run(budget: 1) == nil)
      #expect(try run(budget: 2) == nil)
      #expect(executor.diagnostics.declinedCompilations == 2)
      #expect(executor.diagnostics.negativeCacheHits == 2)
      #expect(executor.diagnostics.negativeEntryCount == 2)
      #expect(executor.diagnostics.negativeCacheHotSites.map(\.instructionBudget) == [1, 2])
      #expect(executor.diagnostics.negativeCacheHotSites.map(\.hitCount) == [1, 1])
    #endif
  }

  @Test func negativeCacheHonorsTargetedAndFullInvalidation() throws {
    #if arch(arm64)
      let bytes: [UInt8] = [0x0F, 0xA2]
      let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096)
      func run(addressSpaceID: UInt64) throws -> DoryARM64BaselineExecution? {
        var state = try DoryX86ArchitecturalState(rip: 0x2400)
        return try executor.execute(
          byteProvider: { count in Array(bytes.prefix(count)) },
          codeGenerationProvider: { _ in 1 },
          at: state.rip,
          mode: .long64,
          addressSpaceID: addressSpaceID,
          maximumInstructions: 1,
          state: &state
        )
      }

      #expect(try run(addressSpaceID: 1) == nil)
      #expect(try run(addressSpaceID: 2) == nil)
      #expect(try run(addressSpaceID: 1) == nil)
      #expect(try run(addressSpaceID: 2) == nil)
      #expect(executor.diagnostics.negativeEntryCount == 2)
      #expect(executor.diagnostics.negativeCacheHotSites.map(\.addressSpaceID) == [1, 2])
      executor.invalidate(addressSpaceID: 1, guestRange: 0x2400..<0x2402)
      #expect(executor.diagnostics.negativeEntryCount == 1)
      #expect(executor.diagnostics.negativeCacheHotSites.map(\.addressSpaceID) == [2])
      #expect(try run(addressSpaceID: 1) == nil)
      #expect(try run(addressSpaceID: 2) == nil)
      #expect(executor.diagnostics.declinedCompilations == 3)
      #expect(executor.diagnostics.negativeCacheHits == 3)
      executor.invalidateAll()
      #expect(executor.diagnostics.negativeEntryCount == 0)
      #expect(executor.diagnostics.negativeCacheHotSites.isEmpty)
    #endif
  }

  @Test func codeCacheWrapClearsNegativeEntries() throws {
    #if arch(arm64)
      let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096)
      var declinedState = try DoryX86ArchitecturalState(rip: 0x2500)
      #expect(try executor.execute(
        byteProvider: { count in Array([0x0F, 0xA2].prefix(count)) },
        codeGenerationProvider: { _ in 1 },
        at: declinedState.rip,
        mode: .long64,
        addressSpaceID: 0,
        maximumInstructions: 1,
        state: &declinedState
      ) == nil)
      declinedState.rip = 0x2500
      #expect(
        try executor.execute(
          byteProvider: { count in Array([0x0F, 0xA2].prefix(count)) },
          codeGenerationProvider: { _ in 1 },
          at: declinedState.rip,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 1,
          state: &declinedState
        ) == nil
      )
      #expect(executor.diagnostics.negativeEntryCount == 1)
      #expect(executor.diagnostics.negativeCacheHotSites.first?.hitCount == 1)

      for value in 0..<1_024 {
        let address = UInt64(0x10_000 + value * 0x20)
        let bytes: [UInt8] = [
          0xB8,
          UInt8(truncatingIfNeeded: value),
          UInt8(truncatingIfNeeded: value >> 8),
          0,
          0,
          0xF4,
        ]
        var state = try DoryX86ArchitecturalState(rip: address)
        _ = try #require(executor.execute(
          byteProvider: { count in Array(bytes.prefix(count)) },
          codeGenerationProvider: { _ in 1 },
          at: address,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 2,
          state: &state
        ))
        if executor.diagnostics.codeCacheWraps > 0 { break }
      }

      #expect(executor.diagnostics.codeCacheWraps > 0)
      #expect(executor.diagnostics.negativeEntryCount == 0)
      #expect(executor.diagnostics.negativeCacheHotSites.isEmpty)
      declinedState.rip = 0x2500
      #expect(try executor.execute(
        byteProvider: { count in Array([0x0F, 0xA2].prefix(count)) },
        codeGenerationProvider: { _ in 1 },
        at: declinedState.rip,
        mode: .long64,
        addressSpaceID: 0,
        maximumInstructions: 1,
        state: &declinedState
      ) == nil)
      #expect(executor.diagnostics.declinedCompilations == 2)
    #endif
  }

  @Test func negativeCacheCollisionReplacementDiscardsTheReplacedHitCount() throws {
    #if arch(arm64)
      let bytes: [UInt8] = [0x0F, 0xA2]
      let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096)
      func run(at guestRIP: UInt64) throws -> DoryARM64BaselineExecution? {
        var state = try DoryX86ArchitecturalState(rip: guestRIP)
        return try executor.execute(
          byteProvider: { count in Array(bytes.prefix(count)) },
          codeGenerationProvider: { _ in 1 },
          at: guestRIP,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 1,
          state: &state
        )
      }

      // These identities differ only in bit 12 and therefore select the same 4,096-entry slot.
      #expect(try run(at: 0x1000) == nil)
      #expect(try run(at: 0x1000) == nil)
      #expect(try run(at: 0x1000) == nil)
      #expect(executor.diagnostics.negativeCacheHotSites.first?.hitCount == 2)

      #expect(try run(at: 0x2000) == nil)
      #expect(executor.diagnostics.negativeCacheHotSites.isEmpty)
      #expect(try run(at: 0x2000) == nil)
      let hotSite = try #require(executor.diagnostics.negativeCacheHotSites.first)
      #expect(hotSite.guestRIP == 0x2000)
      #expect(hotSite.hitCount == 1)
    #endif
  }

  @Test func negativeCacheHotSitesAreCappedAndDeterministicallySorted() throws {
    #if arch(arm64)
      let bytes: [UInt8] = [0x0F, 0xA2]
      let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096)
      let addresses = (0..<18).map { UInt64(0x5000 + $0 * 4) }
      func run(at guestRIP: UInt64) throws {
        var state = try DoryX86ArchitecturalState(rip: guestRIP)
        #expect(
          try executor.execute(
            byteProvider: { count in Array(bytes.prefix(count)) },
            codeGenerationProvider: { _ in 1 },
            at: guestRIP,
            mode: .long64,
            addressSpaceID: 0,
            maximumInstructions: 1,
            state: &state
          ) == nil
        )
      }

      for address in addresses {
        try run(at: address)
        try run(at: address)
      }
      try run(at: addresses[16])
      try run(at: addresses[17])
      try run(at: addresses[17])

      let hotSites = executor.diagnostics.negativeCacheHotSites
      #expect(hotSites.count == 16)
      #expect(hotSites[0].guestRIP == addresses[17])
      #expect(hotSites[0].hitCount == 3)
      #expect(hotSites[1].guestRIP == addresses[16])
      #expect(hotSites[1].hitCount == 2)
      #expect(hotSites.dropFirst(2).map(\.guestRIP) == Array(addresses.prefix(14)))
      #expect(hotSites.dropFirst(2).allSatisfy { $0.hitCount == 1 })
    #endif
  }

  @Test func chainedExecutionKeepsArchitecturalContextAcrossTakenBranches() throws {
    #if arch(arm64)
      let base: UInt64 = 0x1000
      // mov ecx,3; dec ecx; jne -4; hlt
      let bytes: [UInt8] = [0xB9, 3, 0, 0, 0, 0xFF, 0xC9, 0x75, 0xFC, 0xF4]
      let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096)
      var byteFetchCount = 0
      var state = try DoryX86ArchitecturalState(rip: base)
      let summary = try #require(
        executor.executeChainedSummary(
          byteProvider: { address, maximumCount in
            byteFetchCount += 1
            guard address >= base else { return [] }
            let offset = Int(address - base)
            guard bytes.indices.contains(offset) else { return [] }
            return Array(bytes[offset..<min(bytes.count, offset + maximumCount)])
          },
          codeGenerationProvider: { _, _ in 1 },
          at: base,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 16,
          state: &state
        )
      )

      #expect(summary.exitCode == .halt)
      #expect(summary.guestInstructionCount == 8)
      #expect(summary.residentBlockCount == 4)
      #expect(state.registers.rcx == 0)
      #expect(state.rip == base + UInt64(bytes.count))

      state = try DoryX86ArchitecturalState(rip: base)
      byteFetchCount = 0
      let replay = try #require(
        executor.executeChainedSummary(
          byteProvider: { address, maximumCount in
            byteFetchCount += 1
            guard address >= base else { return [] }
            let offset = Int(address - base)
            guard bytes.indices.contains(offset) else { return [] }
            return Array(bytes[offset..<min(bytes.count, offset + maximumCount)])
          },
          codeGenerationProvider: { _, _ in 1 },
          at: base,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 16,
          state: &state
        )
      )
      #expect(replay == summary)
      #expect(executor.nativeBatchExecutionCount == 1)
      #expect(executor.diagnostics.nativeTraceAttempts == 1)
      #expect(executor.diagnostics.nativeTraceReplays == 1)
      #expect(executor.diagnostics.chainedExecutionCalls == 2)
      #expect(executor.diagnostics.chainedRequestedInstructions == 32)
      #expect(executor.diagnostics.chainedRetiredInstructions == 16)
      #expect(byteFetchCount == 0)
      #expect(state.registers.rcx == 0)
      #expect(state.rip == base + UInt64(bytes.count))
    #endif
  }

  @Test func nativeTraceGenerationMismatchRebuildsBeforeExecutingChangedCode() throws {
    #if arch(arm64)
      let base: UInt64 = 0x1800
      var bytes: [UInt8] = [0xB8, 1, 0, 0, 0, 0xEB, 0, 0xF4]
      var generation: UInt64 = 1
      var byteFetchCount = 0
      let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096)
      func run() throws -> DoryARM64ExecutionSummary? {
        var state = try DoryX86ArchitecturalState(rip: base)
        let summary = try executor.executeChainedSummary(
          byteProvider: { address, maximumCount in
            byteFetchCount += 1
            guard address >= base else { return [] }
            let offset = Int(address - base)
            guard bytes.indices.contains(offset) else { return [] }
            return Array(bytes[offset..<min(bytes.count, offset + maximumCount)])
          },
          codeGenerationProvider: { _, _ in generation },
          at: base,
          mode: .long64,
          addressSpaceID: 7,
          maximumInstructions: 16,
          state: &state
        )
        #expect(state.registers.rax == UInt64(bytes[1]))
        return summary
      }

      _ = try #require(try run())
      byteFetchCount = 0
      _ = try #require(try run())
      #expect(byteFetchCount == 0)

      bytes[1] = 2
      generation = 2
      byteFetchCount = 0
      _ = try #require(try run())
      #expect(byteFetchCount > 0)

      byteFetchCount = 0
      _ = try #require(try run())
      #expect(byteFetchCount == 0)
      #expect(executor.diagnostics.nativeTraceReplays == 2)
      #expect(executor.diagnostics.codeGenerationMismatches >= 1)
    #endif
  }

  @Test func nativeTraceWithoutGenerationProofUsesValidatedResidentFallback() throws {
    #if arch(arm64)
      let base: UInt64 = 0x1a00
      let bytes: [UInt8] = [0xB8, 7, 0, 0, 0, 0xEB, 0, 0xF4]
      var byteFetchCount = 0
      let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096)
      func run() throws {
        var state = try DoryX86ArchitecturalState(rip: base)
        _ = try #require(executor.executeChainedSummary(
          byteProvider: { address, maximumCount in
            byteFetchCount += 1
            guard address >= base else { return [] }
            let offset = Int(address - base)
            guard bytes.indices.contains(offset) else { return [] }
            return Array(bytes[offset..<min(bytes.count, offset + maximumCount)])
          },
          at: base,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 16,
          state: &state
        ))
        #expect(state.registers.rax == 7)
      }

      try run()
      byteFetchCount = 0
      try run()
      #expect(byteFetchCount > 0)
      #expect(executor.diagnostics.nativeTraceAttempts == 0)
      #expect(executor.diagnostics.nativeTraceReplays == 0)
    #endif
  }

  @Test func nativeTraceRefusesOffsetsRecordedAcrossACodeCacheWrap() throws {
    #if arch(arm64)
      let base: UInt64 = 0x20_000
      var bytes: [UInt8] = []
      for value in 0..<1_024 {
        bytes += [
          0xB8,
          UInt8(truncatingIfNeeded: value),
          UInt8(truncatingIfNeeded: value >> 8),
          0,
          0,
          0xEB,
          0,
        ]
      }
      bytes.append(0xF4)
      let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096)
      func run() throws {
        var state = try DoryX86ArchitecturalState(rip: base)
        let summary = try #require(executor.executeChainedSummary(
          byteProvider: { address, maximumCount in
            guard address >= base else { return [] }
            let offset = Int(address - base)
            guard bytes.indices.contains(offset) else { return [] }
            return Array(bytes[offset..<min(bytes.count, offset + maximumCount)])
          },
          codeGenerationProvider: { _, _ in 1 },
          at: base,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 4_096,
          state: &state
        ))
        #expect(summary.exitCode == .halt)
        #expect(state.registers.rax == 1_023)
      }

      try run()
      #expect(executor.diagnostics.codeCacheWraps > 0)
      try run()
      #expect(executor.diagnostics.nativeTraceAttempts == 0)
      #expect(executor.diagnostics.nativeTraceReplays == 0)
    #endif
  }

  @Test func executorLoadsAndStoresGuestMemoryThroughBoundedCallbacks() throws {
    #if arch(arm64)
      let memory = try DoryX86ByteArrayMemory(byteCount: 0x100)
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

  @Test func executorUsesAllocationFreeScalarMemoryCallbacksWhenAvailable() throws {
    #if arch(arm64)
      let memory = try ScalarTrackingMemory(byteCount: 0x100)
      try memory.backing.writeScalar(
        at: 0x80, value: 0x1122_3344_5566_7788, byteCount: 8)
      let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096)
      var state = try DoryX86ArchitecturalState(registers: .init(rax: 0x80), rip: 0x3000)

      _ = try #require(
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
      state.rip = 0x3010
      state.registers.rax = 0x88
      _ = try #require(
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

      #expect(memory.scalarReads == 1)
      #expect(memory.scalarWrites == 1)
      #expect(memory.arrayReads == 0)
      #expect(memory.arrayWrites == 0)
      #expect(try memory.backing.readScalar(at: 0x88, byteCount: 8) == 0x1122_3344_5566_7788)
    #endif
  }

  @Test func executorRunsMultipleOrdinaryRAMReadsAsOneRestartableBlock() throws {
    #if arch(arm64)
      let memory = try DoryX86ByteArrayMemory(byteCount: 0x100)
      try memory.writeScalar(at: 0x80, value: 11, byteCount: 8)
      try memory.writeScalar(at: 0x88, value: 31, byteCount: 8)
      let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096)
      var state = try DoryX86ArchitecturalState(registers: .init(rax: 0x80), rip: 0x3500)

      let execution = try #require(
        executor.execute(
          bytes: [
            0x48, 0x8B, 0x08,  // mov rcx,[rax]
            0x48, 0x8B, 0x58, 0x08,  // mov rbx,[rax+8]
            0x48, 0x01, 0xD9,  // add rcx,rbx
            0xF4,
          ],
          at: state.rip,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 4,
          state: &state,
          memory: memory
        )
      )

      #expect(execution.block.guestInstructionCount == 4)
      #expect(execution.block.requiresRestartableMemoryReads)
      #expect(execution.exitCode == .halt)
      #expect(state.registers.rcx == 42)
      #expect(state.rip == 0x350B)
    #endif
  }

  @Test func multiAccessBlockDeclinesBeforeNonrestartableReadsOrWrites() throws {
    #if arch(arm64)
      let memory = try ScalarTrackingMemory(byteCount: 0x100)
      try memory.backing.writeScalar(at: 0x80, value: 0xA5, byteCount: 8)
      let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096)
      let initial = try DoryX86ArchitecturalState(
        registers: .init(rax: 0x80, rcx: 0x55),
        rip: 0x3600
      )
      var state = initial

      let execution = try #require(
        executor.execute(
          bytes: [
            0x48, 0x8B, 0x08,  // mov rcx,[rax]
            0x48, 0x89, 0x48, 0x08,  // mov [rax+8],rcx
          ],
          at: state.rip,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 2,
          state: &state,
          memory: memory
        )
      )

      #expect(execution.block.requiresRestartableMemoryReads)
      #expect(execution.exitCode == .interpreter)
      #expect(state == initial)
      #expect(memory.scalarReads == 0)
      #expect(memory.scalarWrites == 0)
    #endif
  }

  @Test func failedLaterRestartableReadSuppressesTheRemainingNativeWrite() throws {
    #if arch(arm64)
      let memory = try SelectiveRestartableMemory(byteCount: 0x100, declinedAddress: 0x88)
      try memory.backing.writeScalar(at: 0x80, value: 0xA5, byteCount: 8)
      let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096)
      let initial = try DoryX86ArchitecturalState(registers: .init(rax: 0x80), rip: 0x3700)
      var state = initial

      let execution = try #require(
        executor.execute(
          bytes: [
            0x48, 0x8B, 0x08,  // mov rcx,[rax]
            0x48, 0x8B, 0x58, 0x08,  // mov rbx,[rax+8]
            0x48, 0x89, 0x48, 0x10,  // mov [rax+16],rcx
          ],
          at: state.rip,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 3,
          state: &state,
          memory: memory
        )
      )

      #expect(execution.exitCode == .interpreter)
      #expect(state == initial)
      #expect(memory.restartableReads == 2)
      #expect(memory.scalarWrites == 0)
      #expect(try memory.backing.readScalar(at: 0x90, byteCount: 8) == 0)
    #endif
  }

  @Test func directCallAndReturnStayNativeAndMatchLongModeStackSemantics() throws {
    #if arch(arm64)
      let memory = try DoryX86ByteArrayMemory(byteCount: 0x200)
      let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096)
      var state = try DoryX86ArchitecturalState(registers: .init(rsp: 0x100), rip: 0x4000)

      let call = try #require(
        executor.execute(
          bytes: [0xE8, 0x10, 0, 0, 0],
          at: state.rip,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 1,
          state: &state,
          memory: memory
        )
      )
      #expect(call.block.tier == .baseline)
      #expect(call.block.requiresMemoryCallbacks)
      #expect(call.exitCode == .dispatch)
      #expect(state.rip == 0x4015)
      #expect(state.registers.rsp == 0xF8)
      #expect(try memory.read(at: 0xF8, byteCount: 8) == [0x05, 0x40, 0, 0, 0, 0, 0, 0])

      let returned = try #require(
        executor.execute(
          bytes: [0xC3],
          at: state.rip,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 1,
          state: &state,
          memory: memory
        )
      )
      #expect(returned.block.tier == .baseline)
      #expect(returned.block.requiresMemoryCallbacks)
      #expect(returned.exitCode == .dispatch)
      #expect(state.rip == 0x4005)
      #expect(state.registers.rsp == 0x100)
    #endif
  }


  @Test func immediateByteAndWordStoresToMemoryExecuteNatively() throws {
    #if arch(arm64)
      struct StoreCase {
        let bytes: [UInt8]
        let expectedBytes: [UInt8]
      }
      let cases = [
        StoreCase(bytes: [0xC6, 0x07, 0x00], expectedBytes: [0x00]),
        StoreCase(bytes: [0x66, 0xC7, 0x07, 0x34, 0x12], expectedBytes: [0x34, 0x12]),
      ]
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        for testCase in cases {
          let executor = try DoryARM64BaselineExecutor(
            maximumCodeBytes: 16 * 1024,
            optimization: optimization
          )
          let interpretedMemory = try DoryX86ByteArrayMemory(byteCount: 0x200)
          let translatedMemory = try DoryX86ByteArrayMemory(byteCount: 0x200)
          try interpretedMemory.write(at: 0, bytes: testCase.bytes)
          try translatedMemory.write(at: 0, bytes: testCase.bytes)
          try interpretedMemory.write(at: 0x80, bytes: [0xAA, 0xBB])
          try translatedMemory.write(at: 0x80, bytes: [0xAA, 0xBB])

          var interpreted = try DoryX86ArchitecturalState(
            registers: .init(rdi: 0x80),
            rip: 0,
            rflags: [.reservedOne, .carry, .overflow]
          )
          _ = DoryX86Interpreter().step(
            state: &interpreted,
            memory: interpretedMemory,
            mode: .long64
          )

          var translated = try DoryX86ArchitecturalState(
            registers: .init(rdi: 0x80),
            rip: 0,
            rflags: [.reservedOne, .carry, .overflow]
          )
          let execution = try #require(
            executor.execute(
              bytes: testCase.bytes,
              at: translated.rip,
              mode: .long64,
              addressSpaceID: 0,
              maximumInstructions: 1,
              state: &translated,
              memory: translatedMemory
            )
          )

          #expect(execution.block.tier.rawValue == optimization.rawValue)
          #expect(execution.block.requiresMemoryCallbacks)
          #expect(translated == interpreted)
          let translatedStoredBytes = try translatedMemory.read(at: 0x80, byteCount: 2)
          let interpretedStoredBytes = try interpretedMemory.read(at: 0x80, byteCount: 2)
          #expect(translatedStoredBytes == interpretedStoredBytes)
          #expect(try translatedMemory.read(at: 0x80, byteCount: testCase.expectedBytes.count)
            == testCase.expectedBytes)
        }
      }
    #endif
  }

  @Test func byteMemoryCompareAndTestMatchInterpreterAcrossTiers() throws {
    #if arch(arm64)
      struct ByteFlagsCase {
        let bytes: [UInt8]
        let registers: DoryX86GeneralRegisters
        let memoryAddress: UInt64
        let memoryByte: UInt8
        let sourceRegisterByte: UInt8?
      }
      let cases = [
        ByteFlagsCase(
          bytes: [0x80, 0x38, 0x00],  // cmp byte ptr [rax],0
          registers: .init(rax: 0x80),
          memoryAddress: 0x80,
          memoryByte: 0,
          sourceRegisterByte: nil
        ),
        ByteFlagsCase(
          bytes: [0x80, 0x38, 0x7F],  // cmp byte ptr [rax],0x7f
          registers: .init(rax: 0x80),
          memoryAddress: 0x80,
          memoryByte: 0x80,
          sourceRegisterByte: nil
        ),
        ByteFlagsCase(
          bytes: [0x38, 0x18],  // cmp byte ptr [rax],bl
          registers: .init(rax: 0x80, rbx: 0x34),
          memoryAddress: 0x80,
          memoryByte: 0x34,
          sourceRegisterByte: 0x34
        ),
        ByteFlagsCase(
          bytes: [0x3A, 0x0C, 0x06],  // cmp cl,byte ptr [rsi+rax]
          registers: .init(rax: 3, rcx: 0x8A, rsi: 0x80),
          memoryAddress: 0x83,
          memoryByte: 0x8A,
          sourceRegisterByte: nil
        ),
        ByteFlagsCase(
          bytes: [0x3A, 0x00],  // cmp al,[rax]: address/source alias and signed overflow
          registers: .init(rax: 0x80),
          memoryAddress: 0x80,
          memoryByte: 0x7F,
          sourceRegisterByte: nil
        ),
        ByteFlagsCase(
          bytes: [0x84, 0x08],  // test byte ptr [rax],cl remains memory-destination
          registers: .init(rax: 0x80, rcx: 0x81),
          memoryAddress: 0x80,
          memoryByte: 0x80,
          sourceRegisterByte: nil
        ),
        ByteFlagsCase(
          bytes: [0xF6, 0x00, 0x81],  // test byte ptr [rax],0x81
          registers: .init(rax: 0x80),
          memoryAddress: 0x80,
          memoryByte: 0x80,
          sourceRegisterByte: nil
        ),
      ]
      let initialFlags: DoryX86RFLAGS = [
        .reservedOne, .carry, .auxiliaryCarry, .direction, .interruptEnable, .overflow,
      ]
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        for testCase in cases {
          let interpretedMemory = try DoryX86ByteArrayMemory(byteCount: 0x100)
          let translatedMemory = try DoryX86ByteArrayMemory(byteCount: 0x100)
          for memory in [interpretedMemory, translatedMemory] {
            try memory.write(at: 0, bytes: testCase.bytes)
            try memory.write(at: testCase.memoryAddress, bytes: [testCase.memoryByte])
          }

          var interpreted = try DoryX86ArchitecturalState(
            registers: testCase.registers,
            rip: 0,
            rflags: initialFlags
          )
          let decoded = try DoryX86Decoder().decode(testCase.bytes, at: 0, mode: .long64)
          #expect(DoryX86Interpreter().step(state: &interpreted, memory: interpretedMemory,
            mode: .long64) == .retired(decoded))

          var translated = try DoryX86ArchitecturalState(
            registers: testCase.registers,
            rip: 0,
            rflags: initialFlags
          )
          let execution = try #require(DoryARM64BaselineExecutor(
            maximumCodeBytes: 16 * 1024, optimization: optimization
          ).execute(bytes: testCase.bytes, at: 0, mode: .long64, addressSpaceID: 0,
            maximumInstructions: 1, state: &translated, memory: translatedMemory))

          #expect(execution.block.tier.rawValue == optimization.rawValue)
          #expect(execution.block.requiresMemoryCallbacks)
          #expect(!execution.block.requiresRestartableMemoryReads)
          #expect(translated == interpreted)
          #expect(try translatedMemory.read(at: 0, byteCount: 0x100)
            == interpretedMemory.read(at: 0, byteCount: 0x100))
          if let sourceRegisterByte = testCase.sourceRegisterByte {
            #expect(UInt8(truncatingIfNeeded: translated.registers.rbx) == sourceRegisterByte)
          }
        }
      }
    #endif
  }

  @Test func byteMemoryCompareFaultLeavesArchitecturalStateRestartable() throws {
    #if arch(arm64)
      let cases: [([UInt8], DoryX86GeneralRegisters)] = [
        ([0x80, 0x38, 0x00], .init(rax: 0x80)),  // cmp byte ptr [rax],0
        ([0x3A, 0x08], .init(rax: 0x80, rcx: 0x55)),  // cmp cl,byte ptr [rax]
      ]
      for (bytes, registers) in cases {
        for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
          let memory = try DoryX86ByteArrayMemory(byteCount: 0x40)
          try memory.write(at: 0, bytes: bytes)
          let initial = try DoryX86ArchitecturalState(
            registers: registers,
            rip: 0,
            rflags: [.reservedOne, .carry, .direction, .overflow]
          )
          var state = initial
          let execution = try #require(DoryARM64BaselineExecutor(
            maximumCodeBytes: 16 * 1024, optimization: optimization
          ).execute(bytes: bytes, at: 0, mode: .long64, addressSpaceID: 0,
            maximumInstructions: 1, state: &state, memory: memory))

          #expect(execution.block.tier.rawValue == optimization.rawValue)
          #expect(execution.block.requiresMemoryCallbacks)
          #expect(execution.exitCode == .interpreter)
          #expect(state == initial)
        }
      }
    #endif
  }

  @Test func lowByteMemoryDestinationAndMatchesInterpreterAcrossTiers() throws {
    #if arch(arm64)
      struct Case {
        let bytes: [UInt8]
        let registers: DoryX86GeneralRegisters
        let address: UInt64
        let initialByte: UInt8
      }
      let cases: [Case] = [
        .init(
          bytes: [0x41, 0x80, 0x66, 0x10, 0xFD],  // and byte ptr [r14+0x10],0xfd
          registers: .init(r14: 0x80),
          address: 0x90,
          initialByte: 0xFF
        ),
        .init(
          bytes: [0x20, 0x00],  // and byte ptr [rax],al: address/source register alias
          registers: .init(rax: 0x88),
          address: 0x88,
          initialByte: 0xFF
        ),
        .init(
          bytes: [0x20, 0x18],  // and byte ptr [rax],bl
          registers: .init(rax: 0x88, rbx: 0x8877_6655_4433_227E),
          address: 0x88,
          initialByte: 0x81
        ),
      ]
      let initialFlags: DoryX86RFLAGS = [
        .reservedOne, .carry, .parity, .auxiliaryCarry, .direction, .interruptEnable, .overflow,
      ]

      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        for testCase in cases {
          let interpretedMemory = try DoryX86ByteArrayMemory(byteCount: 0x100)
          let translatedMemory = try DoryX86ByteArrayMemory(byteCount: 0x100)
          for memory in [interpretedMemory, translatedMemory] {
            try memory.write(at: 0, bytes: testCase.bytes)
            try memory.write(at: testCase.address, bytes: [testCase.initialByte])
          }

          var interpreted = try DoryX86ArchitecturalState(
            registers: testCase.registers,
            rip: 0,
            rflags: initialFlags
          )
          _ = DoryX86Interpreter().step(
            state: &interpreted,
            memory: interpretedMemory,
            mode: .long64
          )
          var translated = try DoryX86ArchitecturalState(
            registers: testCase.registers,
            rip: 0,
            rflags: initialFlags
          )
          let execution = try #require(
            DoryARM64BaselineExecutor(
              maximumCodeBytes: 16 * 1024,
              optimization: optimization
            ).execute(
              bytes: testCase.bytes,
              at: translated.rip,
              mode: .long64,
              addressSpaceID: 0,
              maximumInstructions: 1,
              state: &translated,
              memory: translatedMemory
            )
          )

          #expect(execution.block.tier.rawValue == optimization.rawValue)
          #expect(execution.block.requiresMemoryCallbacks)
          #expect(translated == interpreted)
          #expect(
            try translatedMemory.read(at: 0, byteCount: 0x100)
              == interpretedMemory.read(at: 0, byteCount: 0x100))
        }
      }
    #endif
  }

  @Test func lowByteMemoryDestinationAndFaultLeavesStateAndMemoryRestartable() throws {
    #if arch(arm64)
      let bytes: [UInt8] = [0x41, 0x80, 0x66, 0x10, 0xFD]
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        for rejectWrite in [false, true] {
          let memory = try SelectiveRestartableMemory(
            byteCount: 0x100, declinedAddress: rejectWrite ? .max : 0x90,
            rejectedWriteAddress: rejectWrite ? 0x90 : nil)
          try memory.backing.write(at: 0, bytes: bytes)
          try memory.backing.write(at: 0x90, bytes: [0xFF])
          let initialBytes = try memory.backing.read(at: 0, byteCount: 0x100)
          let initial = try DoryX86ArchitecturalState(
            registers: .init(r14: 0x80), rip: 0,
            rflags: [.reservedOne, .carry, .direction, .overflow])
          var state = initial
          let execution = try #require(DoryARM64BaselineExecutor(
            maximumCodeBytes: 16 * 1024, optimization: optimization
          ).execute(
            bytes: bytes, at: 0, mode: .long64, addressSpaceID: 0,
            maximumInstructions: 1, state: &state, memory: memory))

          #expect(execution.block.tier.rawValue == optimization.rawValue)
          #expect(execution.block.requiresMemoryCallbacks)
          #expect(execution.exitCode == .interpreter)
          #expect(state == initial)
          #expect(memory.restartableReads == 1)
          #expect(memory.scalarWrites == (rejectWrite ? 1 : 0))
          #expect(try memory.backing.read(at: 0, byteCount: 0x100) == initialBytes)
        }
      }
    #endif
  }

  @Test func lockPrefixedNonAtomicMemoryOperationsDeclineBeforeMemorySideEffects() throws {
    #if arch(arm64)
      let cases: [[UInt8]] = [
        [0xF0, 0x80, 0x20, 0xFD],  // lock and byte ptr [rax],0xfd
        [0xF0, 0x01, 0x08],  // lock add dword ptr [rax],ecx
        [0xF0, 0x48, 0xFF, 0x00],  // lock inc qword ptr [rax]
      ]
      let initial = try DoryX86ArchitecturalState(
        registers: .init(rax: 0x80, rcx: 0x1122_3344),
        rip: 0,
        rflags: [.reservedOne, .carry, .direction, .overflow]
      )
      for bytes in cases {
        let block = try DoryX86IRTranslator().translate(bytes, at: 0, mode: .long64)
        #expect(DoryARM64BaselineEmitter().compile(block).tier == .interpreterFallback)

        for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
          let memory = try ScalarTrackingMemory(byteCount: 0x100)
          try memory.backing.write(at: 0, bytes: bytes)
          try memory.backing.writeScalar(at: 0x80, value: 0x8877_6655_4433_2211, byteCount: 8)
          var state = initial
          let execution = try DoryARM64BaselineExecutor(
            maximumCodeBytes: 16 * 1024,
            optimization: optimization
          ).execute(
            bytes: bytes,
            at: 0,
            mode: .long64,
            addressSpaceID: UInt64(bytes.count),
            maximumInstructions: 1,
            state: &state,
            memory: memory
          )

          #expect(execution == nil)
          #expect(state == initial)
          #expect(memory.scalarReads == 0)
          #expect(memory.scalarWrites == 0)
          #expect(try memory.backing.readScalar(at: 0x80, byteCount: 8) == 0x8877_6655_4433_2211)
        }
      }
    #endif
  }

  @Test func registerPushAndPopMatchInterpreterAcrossTiers() throws {
    #if arch(arm64)
      struct StackCase {
        let bytes: [UInt8]
        let registers: DoryX86GeneralRegisters
        let stackValue: UInt64?
      }
      let cases = [
        StackCase(
          bytes: [0x41, 0x55],  // push r13
          registers: .init(rsp: 0x100, r13: 0x1122_3344_5566_7788),
          stackValue: nil
        ),
        StackCase(
          bytes: [0x54],  // push rsp must store the pre-decrement value
          registers: .init(rsp: 0x100),
          stackValue: nil
        ),
        StackCase(
          bytes: [0x6A, 0xFE],  // push imm8 sign-extends to qword in long mode
          registers: .init(rsp: 0x100),
          stackValue: nil
        ),
        StackCase(
          bytes: [0x5A],  // pop rdx
          registers: .init(rdx: 0xDEAD_BEEF, rsp: 0x100),
          stackValue: 0x8877_6655_4433_2211
        ),
      ]
      let flags: DoryX86RFLAGS = [
        .reservedOne, .carry, .parity, .direction, .interruptEnable, .overflow,
      ]

      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        for testCase in cases {
          let executor = try DoryARM64BaselineExecutor(
            maximumCodeBytes: 16 * 1024,
            optimization: optimization
          )
          let interpretedMemory = try DoryX86ByteArrayMemory(byteCount: 0x200)
          let translatedMemory = try DoryX86ByteArrayMemory(byteCount: 0x200)
          try interpretedMemory.write(at: 0x20, bytes: testCase.bytes)
          try translatedMemory.write(at: 0x20, bytes: testCase.bytes)
          if let stackValue = testCase.stackValue {
            let stackBytes = (0..<8).map { UInt8(truncatingIfNeeded: stackValue >> ($0 * 8)) }
            try interpretedMemory.write(at: 0x100, bytes: stackBytes)
            try translatedMemory.write(at: 0x100, bytes: stackBytes)
          }

          var interpreted = try DoryX86ArchitecturalState(
            registers: testCase.registers,
            rip: 0x20,
            rflags: flags
          )
          _ = DoryX86Interpreter().step(
            state: &interpreted,
            memory: interpretedMemory,
            mode: .long64
          )

          var translated = try DoryX86ArchitecturalState(
            registers: testCase.registers,
            rip: 0x20,
            rflags: flags
          )
          let execution = try #require(
            executor.execute(
              bytes: testCase.bytes,
              at: translated.rip,
              mode: .long64,
              addressSpaceID: 0,
              maximumInstructions: 1,
              state: &translated,
              memory: translatedMemory
            )
          )

          #expect(execution.block.tier.rawValue == optimization.rawValue)
          #expect(execution.block.requiresMemoryCallbacks)
          #expect(translated == interpreted)
          #expect(
            try translatedMemory.read(at: 0, byteCount: 0x200)
              == interpretedMemory.read(at: 0, byteCount: 0x200))
        }
      }
    #endif
  }

  @Test func byteSwapMatchesInterpreterAcrossWidthsRegistersAndTiers() throws {
    #if arch(arm64)
      let cases: [([UInt8], DoryX86GeneralRegisters)] = [
        ([0x0F, 0xC8], .init(rax: 0xAABB_CCDD_1122_3344)),
        ([0x48, 0x0F, 0xC8], .init(rax: 0x1122_3344_5566_7788)),
        ([0x41, 0x0F, 0xC9], .init(r9: 0xAABB_CCDD_89AB_CDEF)),
      ]
      let flags: DoryX86RFLAGS = [
        .reservedOne, .carry, .parity, .auxiliaryCarry, .zero, .sign, .direction,
        .interruptEnable, .overflow,
      ]
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        for (bytes, registers) in cases {
          let executor = try DoryARM64BaselineExecutor(
            maximumCodeBytes: 16 * 1024,
            optimization: optimization
          )
          var interpreted = try DoryX86ArchitecturalState(
            registers: registers,
            rip: 0,
            rflags: flags
          )
          _ = DoryX86Interpreter().step(
            state: &interpreted,
            memory: try DoryX86ByteArrayMemory(bytes: bytes),
            mode: .long64
          )
          var translated = try DoryX86ArchitecturalState(
            registers: registers,
            rip: 0,
            rflags: flags
          )
          let execution = try #require(
            executor.execute(
              bytes: bytes,
              at: 0,
              mode: .long64,
              addressSpaceID: 0,
              maximumInstructions: 1,
              state: &translated
            )
          )
          #expect(execution.block.tier.rawValue == optimization.rawValue)
          #expect(translated == interpreted)
        }
      }
    #endif
  }

  @Test func measuredByteSwapSitesCompileNativelyAndInvalidateOptimizerState() throws {
    let measured: [([UInt8], UInt64)] = [
      ([0x0F, 0xC8], 0x1BE8_9456),
      ([0x41, 0x0F, 0xC9], 0x1BE8_949C),
    ]
    for (bytes, address) in measured {
      let block = try DoryX86IRTranslator().translate(bytes, at: address, mode: .long64)
      for tier in [DoryARM64CompilationTier.baseline, .optimizing] {
        let candidate = tier == .optimizing ? DoryIROptimizer().optimize(block).block : block
        #expect(DoryARM64BaselineEmitter().compile(candidate, tier: tier).tier == tier)
      }
    }

    let flow = try DoryX86IRTranslator().translate(
      [
        0xB8, 0x44, 0x33, 0x22, 0x11,  // mov eax,0x11223344
        0x0F, 0xC8,  // bswap eax
        0x89, 0xC3,  // mov ebx,eax
      ],
      at: 0,
      mode: .long64
    )
    let optimized = DoryIROptimizer().optimize(flow).block
    guard case .copy(destination: _, source: .register(let source)) = optimized.statements.last
    else {
      Issue.record("byte swap must invalidate the optimizer's pre-swap register constant")
      return
    }
    #expect(source.index == 0)

    let invalid = DoryIRBasicBlock(
      guestStart: 0,
      guestByteCount: 1,
      guestInstructionCount: 1,
      statements: [
        .byteSwap(.register(.init(bank: "not.x86.gpr", index: 0, width: .i32)))
      ],
      terminator: .next(1)
    )
    #expect(DoryARM64BaselineEmitter().compile(invalid).tier == .interpreterFallback)
  }

  @Test func registerStackMemoryFailuresLeaveArchitecturalStateRestartable() throws {
    #if arch(arm64)
      let cases: [([UInt8], DoryX86GeneralRegisters)] = [
        ([0x41, 0x55], .init(rsp: 4, r13: 0x1122_3344_5566_7788)),
        ([0x6A, 0xFE], .init(rsp: 4)),
        ([0x9C], .init(rsp: 4)),
        ([0x5A], .init(rdx: 0xDEAD_BEEF, rsp: 0x100)),
      ]

      for (bytes, registers) in cases {
        let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 16 * 1024)
        let memory = try DoryX86ByteArrayMemory(byteCount: 0x100)
        let initial = try DoryX86ArchitecturalState(registers: registers, rip: 0x7000)
        var state = initial
        let execution = try #require(
          executor.execute(
            bytes: bytes,
            at: state.rip,
            mode: .long64,
            addressSpaceID: 0,
            maximumInstructions: 1,
            state: &state,
            memory: memory
          )
        )

        #expect(execution.block.tier == .baseline)
        #expect(execution.exitCode == .interpreter)
        #expect(state == initial)
      }
    #endif
  }

  @Test func lowByteMemoryMovesMatchInterpreterAcrossTiersAndPreserveUpperBits() throws {
    #if arch(arm64)
      let cases: [([UInt8], DoryX86GeneralRegisters, UInt64)] = [
        ([0x8A, 0x0C, 0x06], .init(rax: 0x10, rcx: 0x1122_3344_5566_7788, rsi: 0x80), 0x90),
        (
          [0x44, 0x8A, 0x04, 0x06],
          .init(rax: 0x18, rsi: 0x80, r8: 0x8877_6655_4433_2211),
          0x98
        ),
      ]
      let flags: DoryX86RFLAGS = [
        .reservedOne, .carry, .parity, .direction, .interruptEnable, .overflow,
      ]

      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        for (bytes, registers, sourceAddress) in cases {
          let executor = try DoryARM64BaselineExecutor(
            maximumCodeBytes: 16 * 1024,
            optimization: optimization
          )
          let interpretedMemory = try DoryX86ByteArrayMemory(byteCount: 0x200)
          let translatedMemory = try DoryX86ByteArrayMemory(byteCount: 0x200)
          try interpretedMemory.write(at: 0x20, bytes: bytes)
          try translatedMemory.write(at: 0x20, bytes: bytes)
          try interpretedMemory.write(at: sourceAddress, bytes: [0xA5])
          try translatedMemory.write(at: sourceAddress, bytes: [0xA5])

          var interpreted = try DoryX86ArchitecturalState(
            registers: registers,
            rip: 0x20,
            rflags: flags
          )
          _ = DoryX86Interpreter().step(
            state: &interpreted,
            memory: interpretedMemory,
            mode: .long64
          )

          var translated = try DoryX86ArchitecturalState(
            registers: registers,
            rip: 0x20,
            rflags: flags
          )
          let execution = try #require(
            executor.execute(
              bytes: bytes,
              at: translated.rip,
              mode: .long64,
              addressSpaceID: 0,
              maximumInstructions: 1,
              state: &translated,
              memory: translatedMemory
            )
          )

          #expect(execution.block.tier.rawValue == optimization.rawValue)
          #expect(execution.block.requiresMemoryCallbacks)
          #expect(translated == interpreted)
          #expect(
            try translatedMemory.read(at: 0, byteCount: 0x200)
              == interpretedMemory.read(at: 0, byteCount: 0x200))
        }
      }
    #endif
  }

  @Test func lowByteMemoryMoveFaultLeavesArchitecturalStateRestartable() throws {
    #if arch(arm64)
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let executor = try DoryARM64BaselineExecutor(
          maximumCodeBytes: 16 * 1024,
          optimization: optimization
        )
        let memory = try DoryX86ByteArrayMemory(byteCount: 0x100)
        let initial = try DoryX86ArchitecturalState(
          registers: .init(rax: 0x100, rcx: 0x1122_3344_5566_7788, rsi: 0),
          rip: 0x7000,
          rflags: [.reservedOne, .carry, .interruptEnable]
        )
        var state = initial
        let execution = try #require(
          executor.execute(
            bytes: [0x8A, 0x0C, 0x06],
            at: state.rip,
            mode: .long64,
            addressSpaceID: 0,
            maximumInstructions: 1,
            state: &state,
            memory: memory
          )
        )

        #expect(execution.block.tier.rawValue == optimization.rawValue)
        #expect(execution.exitCode == .interpreter)
        #expect(state == initial)
      }
    #endif
  }

  @Test func measuredLowByteMemoryMovesCompileNativelyWhileHighByteFormStaysBounded() throws {
    let measured: [([UInt8], UInt64)] = [
      ([0x8A, 0x0C, 0x06], 0x1DCE_9DB9),
      ([0x44, 0x8A, 0x04, 0x06], 0x12E4_D1DD8),
    ]
    for (bytes, address) in measured {
      let block = try DoryX86IRTranslator().translate(bytes, at: address, mode: .long64)
      for tier in [DoryARM64CompilationTier.baseline, .optimizing] {
        let candidate = tier == .optimizing ? DoryIROptimizer().optimize(block).block : block
        let compiled = DoryARM64BaselineEmitter().compile(candidate, tier: tier)
        #expect(compiled.tier == tier)
        #expect(compiled.requiresMemoryCallbacks)
      }
    }

    let highByte = try DoryX86IRTranslator().translate([0x8A, 0x20], at: 0, mode: .long64)
    #expect(DoryARM64BaselineEmitter().compile(highByte).tier == .interpreterFallback)

    let invalid = DoryIRRegister(bank: "not.x86.gpr", index: 0, width: .i8)
    let block = DoryIRBasicBlock(
      guestStart: 0,
      guestByteCount: 1,
      guestInstructionCount: 1,
      statements: [
        .copy(
          destination: .register(invalid),
          source: .memory(.init(addressWidth: .i64), width: .i8)
        )
      ],
      terminator: .next(1)
    )
    #expect(DoryARM64BaselineEmitter().compile(block).tier == .interpreterFallback)
  }

  @Test func lowByteAndMatchesInterpreterResultsAndFlagsAcrossTiers() throws {
    #if arch(arm64)
      let values: [(UInt8, UInt8)] = [
        (0x00, 0x00), (0xFF, 0x80), (0x7F, 0x81), (0x55, 0xAA), (0xF3, 0x3F),
      ]
      let initialFlags: DoryX86RFLAGS = [
        .reservedOne, .carry, .parity, .auxiliaryCarry, .direction, .interruptEnable, .overflow,
      ]

      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        for (cl, al) in values {
          let executor = try DoryARM64BaselineExecutor(
            maximumCodeBytes: 16 * 1024,
            optimization: optimization
          )
          let registers = DoryX86GeneralRegisters(
            rax: 0x8877_6655_4433_2200 | UInt64(al),
            rcx: 0x1122_3344_5566_7700 | UInt64(cl)
          )
          let interpretedMemory = try DoryX86ByteArrayMemory(byteCount: 0x100)
          let translatedMemory = try DoryX86ByteArrayMemory(byteCount: 0x100)
          try interpretedMemory.write(at: 0x20, bytes: [0x20, 0xC1])
          try translatedMemory.write(at: 0x20, bytes: [0x20, 0xC1])
          var interpreted = try DoryX86ArchitecturalState(
            registers: registers,
            rip: 0x20,
            rflags: initialFlags
          )
          _ = DoryX86Interpreter().step(
            state: &interpreted,
            memory: interpretedMemory,
            mode: .long64
          )
          var translated = try DoryX86ArchitecturalState(
            registers: registers,
            rip: 0x20,
            rflags: initialFlags
          )
          let execution = try #require(
            executor.execute(
              bytes: [0x20, 0xC1],
              at: translated.rip,
              mode: .long64,
              addressSpaceID: 0,
              maximumInstructions: 1,
              state: &translated,
              memory: translatedMemory
            )
          )

          #expect(execution.block.tier.rawValue == optimization.rawValue)
          #expect(translated == interpreted)
        }
      }
    #endif
  }

  @Test func lowByteOrMatchesInterpreterResultsAndFlagsAcrossTiers() throws {
    #if arch(arm64)
      struct OrCase {
        let bytes: [UInt8]
        let registers: DoryX86GeneralRegisters
        let comment: String
      }
      let valuePairs: [(UInt8, UInt8)] = [
        (0x00, 0x00), (0x00, 0x80), (0x7F, 0x01), (0x55, 0xAA), (0xF0, 0x0F),
      ]
      let initialFlags: [DoryX86RFLAGS] = [
        .reservedOne,
        [
          .reservedOne, .carry, .parity, .auxiliaryCarry, .zero, .sign, .overflow,
          .interruptEnable, .direction, .identification,
        ],
      ]

      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        for (pairIndex, pair) in valuePairs.enumerated() {
          let cases = [
            OrCase(
              bytes: [0x08, 0xC2],  // or dl,al: measured post-init hot site
              registers: .init(
                rax: 0x1100_0000_0000_0000 | UInt64(pair.1),
                rdx: 0x3300_0000_0000_0000 | UInt64(pair.0)
              ),
              comment: "register source"
            ),
            OrCase(
              bytes: [0x80, 0xCA, UInt8(pair.1)],  // or dl,imm8
              registers: .init(rdx: 0x3300_0000_0000_0000 | UInt64(pair.0)),
              comment: "immediate source"
            ),
          ]
          for (caseIndex, testCase) in cases.enumerated() {
            for (flagIndex, flags) in initialFlags.enumerated() {
              var interpreted = try DoryX86ArchitecturalState(
                registers: testCase.registers,
                rip: 0,
                rflags: flags
              )
              let decoded = try DoryX86Decoder().decode(testCase.bytes, at: 0, mode: .long64)
              #expect(DoryX86Interpreter().step(
                state: &interpreted,
                memory: try DoryX86ByteArrayMemory(bytes: testCase.bytes),
                mode: .long64
              ) == .retired(decoded))

              var translated = try DoryX86ArchitecturalState(
                registers: testCase.registers,
                rip: 0,
                rflags: flags
              )
              let execution = try #require(
                DoryARM64BaselineExecutor(
                  maximumCodeBytes: 16 * 1024,
                  optimization: optimization
                ).execute(
                  bytes: testCase.bytes,
                  at: translated.rip,
                  mode: .long64,
                  addressSpaceID: UInt64(0x2500 + pairIndex * 8 + caseIndex * 2 + flagIndex),
                  maximumInstructions: 1,
                  state: &translated
                )
              )

              #expect(execution.block.tier.rawValue == optimization.rawValue)
              #expect(!execution.block.requiresMemoryCallbacks)
              #expect(translated == interpreted)
            }
          }
        }
      }
    #endif
  }

  @Test func lowByteMemorySourceAndMatchesInterpreterAcrossTiers() throws {
    #if arch(arm64)
      struct Case {
        let bytes: [UInt8]
        let rip: UInt64
        let registers: DoryX86GeneralRegisters
        let address: UInt64
        let memoryByte: UInt8
      }
      let cases: [Case] = [
        .init(
          bytes: [0x22, 0x15, 0x3A, 0x00, 0x00, 0x00],  // and dl,byte ptr [rip+0x3a]
          rip: 0x80,
          registers: .init(rdx: 0x8877_6655_4433_22F0),
          address: 0xC0,
          memoryByte: 0x0F
        ),
        .init(
          bytes: [0x22, 0x00],  // and al,byte ptr [rax]: address/destination alias
          rip: 0,
          registers: .init(rax: 0x88),
          address: 0x88,
          memoryByte: 0xF0
        ),
        .init(
          bytes: [0x44, 0x22, 0x04, 0x06],  // and r8b,byte ptr [rsi+rax]
          rip: 0x20,
          registers: .init(rax: 0x08, rsi: 0x80, r8: 0xAABB_CCDD_EEFF_0033),
          address: 0x88,
          memoryByte: 0x55
        ),
      ]
      let initialFlags: DoryX86RFLAGS = [
        .reservedOne, .carry, .parity, .auxiliaryCarry, .direction, .interruptEnable, .overflow,
      ]

      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        for (index, testCase) in cases.enumerated() {
          let interpretedMemory = try DoryX86ByteArrayMemory(byteCount: 0x200)
          let translatedMemory = try DoryX86ByteArrayMemory(byteCount: 0x200)
          for memory in [interpretedMemory, translatedMemory] {
            try memory.write(at: testCase.rip, bytes: testCase.bytes)
            try memory.write(at: testCase.address, bytes: [testCase.memoryByte])
          }

          var interpreted = try DoryX86ArchitecturalState(
            registers: testCase.registers,
            rip: testCase.rip,
            rflags: initialFlags
          )
          let decoded = try DoryX86Decoder().decode(testCase.bytes, at: testCase.rip, mode: .long64)
          #expect(DoryX86Interpreter().step(
            state: &interpreted,
            memory: interpretedMemory,
            mode: .long64
          ) == .retired(decoded))

          var translated = try DoryX86ArchitecturalState(
            registers: testCase.registers,
            rip: testCase.rip,
            rflags: initialFlags
          )
          let execution = try #require(
            DoryARM64BaselineExecutor(
              maximumCodeBytes: 16 * 1024,
              optimization: optimization
            ).execute(
              bytes: testCase.bytes,
              at: translated.rip,
              mode: .long64,
              addressSpaceID: UInt64(0x2200 + index),
              maximumInstructions: 1,
              state: &translated,
              memory: translatedMemory
            )
          )

          #expect(execution.block.tier.rawValue == optimization.rawValue)
          #expect(execution.block.requiresMemoryCallbacks)
          #expect(translated == interpreted)
          #expect(
            try translatedMemory.read(at: 0, byteCount: 0x200)
              == interpretedMemory.read(at: 0, byteCount: 0x200))
        }
      }
    #endif
  }

  @Test func wordMemorySourceOrMatchesInterpreterAcrossTiers() throws {
    #if arch(arm64)
      struct Case {
        let bytes: [UInt8]
        let rip: UInt64
        let registers: DoryX86GeneralRegisters
        let address: UInt64
        let memoryWord: UInt16
        let comment: String
      }
      let cases: [Case] = [
        .init(
          bytes: [0x66, 0x0B, 0x8D, 0xA0, 0x0B, 0x00, 0x00],
          rip: 0x40,
          registers: .init(rcx: 0x8877_6655_4433_00F0, rbp: 0x1000),
          address: 0x1BA0,
          memoryWord: 0x0F0F,
          comment: "measured or cx,word ptr [rbp+0xba0] hot site"
        ),
        .init(
          bytes: [0x66, 0x0B, 0x00],
          rip: 0,
          registers: .init(rax: 0x0120),
          address: 0x0120,
          memoryWord: 0x00F0,
          comment: "RAX is both original effective address and AX destination"
        ),
        .init(
          bytes: [0x66, 0x44, 0x0B, 0x84, 0x4E, 0x20, 0x00, 0x00, 0x00],
          rip: 0x20,
          registers: .init(rcx: 0x10, rsi: 0x80, r8: 0xAABB_CCDD_EEFF_8001),
          address: 0xC0,
          memoryWord: 0x7FFE,
          comment: "base+index*scale+disp memory source into extended word register"
        ),
        .init(
          bytes: [0x66, 0x0B, 0x8D, 0xA0, 0x0B, 0x00, 0x00],
          rip: 0x40,
          registers: .init(rcx: 0x8877_6655_4433_0000, rbp: 0x1000),
          address: 0x1BA0,
          memoryWord: 0x0000,
          comment: "measured shape with zero result for ZF/parity"
        ),
      ]
      let initialFlags: [DoryX86RFLAGS] = [
        .reservedOne,
        [
          .reservedOne, .carry, .parity, .auxiliaryCarry, .zero, .sign, .overflow,
          .interruptEnable, .direction, .identification,
        ],
      ]

      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        for (caseIndex, testCase) in cases.enumerated() {
          for (flagIndex, flags) in initialFlags.enumerated() {
            let interpretedMemory = try DoryX86ByteArrayMemory(byteCount: 0x3000)
            let translatedMemory = try DoryX86ByteArrayMemory(byteCount: 0x3000)
            let wordBytes = [UInt8(truncatingIfNeeded: testCase.memoryWord), UInt8(testCase.memoryWord >> 8)]
            for memory in [interpretedMemory, translatedMemory] {
              try memory.write(at: testCase.rip, bytes: testCase.bytes)
              try memory.write(at: testCase.address, bytes: wordBytes)
            }

            var interpreted = try DoryX86ArchitecturalState(
              registers: testCase.registers,
              rip: testCase.rip,
              rflags: flags
            )
            let decoded = try DoryX86Decoder().decode(testCase.bytes, at: testCase.rip, mode: .long64)
            #expect(DoryX86Interpreter().step(
              state: &interpreted,
              memory: interpretedMemory,
              mode: .long64
            ) == .retired(decoded))

            var translated = try DoryX86ArchitecturalState(
              registers: testCase.registers,
              rip: testCase.rip,
              rflags: flags
            )
            let execution = try #require(
              DoryARM64BaselineExecutor(
                maximumCodeBytes: 16 * 1024,
                optimization: optimization
              ).execute(
                bytes: testCase.bytes,
                at: translated.rip,
                mode: .long64,
                addressSpaceID: UInt64(0x2A00 + caseIndex * 8 + flagIndex),
                maximumInstructions: 1,
                state: &translated,
                memory: translatedMemory
              )
            )

            #expect(execution.block.tier.rawValue == optimization.rawValue)
            #expect(execution.exitCode == .dispatch)
            #expect(execution.block.requiresMemoryCallbacks)
            #expect(translated == interpreted)
            #expect(
              try translatedMemory.read(at: 0, byteCount: 0x3000)
                == interpretedMemory.read(at: 0, byteCount: 0x3000))
            switch caseIndex {
            case 0:
              #expect(translated.registers.rcx & 0xFFFF == 0x0FFF)
              #expect(translated.registers.rcx >> 16 == testCase.registers.rcx >> 16)
            case 1:
              #expect(translated.registers.rax == 0x01F0)
            case 2:
              #expect(translated.registers.r8 & 0xFFFF == 0xFFFF)
              #expect(translated.registers.r8 >> 16 == testCase.registers.r8 >> 16)
            case 3:
              #expect(translated.registers.rcx & 0xFFFF == 0)
              #expect(translated.registers.rcx >> 16 == testCase.registers.rcx >> 16)
              #expect(translated.rflags.contains(.zero))
              #expect(translated.rflags.contains(.parity))
              #expect(!translated.rflags.contains(.carry))
              #expect(!translated.rflags.contains(.overflow))
            default:
              break
            }
          }
        }
      }
    #endif
  }

  @Test func wordMemorySourceOrFaultLeavesArchitecturalStateRestartable() throws {
    #if arch(arm64)
      let bytes: [UInt8] = [0x66, 0x0B, 0x00]  // or ax,word ptr [rax]
      for (index, optimization) in [DoryARM64JITOptimization.baseline, .optimizing].enumerated() {
        let memory = try DoryX86ByteArrayMemory(byteCount: 0x40)
        try memory.write(at: 0, bytes: bytes)
        let initial = try DoryX86ArchitecturalState(
          registers: .init(rax: 0x80, rcx: 0x1122_3344_5566_7788),
          rip: 0,
          rflags: [.reservedOne, .carry, .parity, .direction, .overflow]
        )
        var state = initial
        let execution = try #require(DoryARM64BaselineExecutor(
          maximumCodeBytes: 16 * 1024,
          optimization: optimization
        ).execute(
          bytes: bytes,
          at: 0,
          mode: .long64,
          addressSpaceID: UInt64(0x2B00 + index),
          maximumInstructions: 1,
          state: &state,
          memory: memory
        ))

        #expect(execution.block.tier.rawValue == optimization.rawValue)
        #expect(execution.block.requiresMemoryCallbacks)
        #expect(execution.exitCode == .interpreter)
        #expect(state == initial)
      }
    #endif
  }

  @Test func lowByteMemorySourceAndFaultLeavesArchitecturalStateRestartable() throws {
    #if arch(arm64)
      let bytes: [UInt8] = [0x22, 0x00]  // and al,byte ptr [rax]
      for (index, optimization) in [DoryARM64JITOptimization.baseline, .optimizing].enumerated() {
        let memory = try DoryX86ByteArrayMemory(byteCount: 0x40)
        try memory.write(at: 0, bytes: bytes)
        let initial = try DoryX86ArchitecturalState(
          registers: .init(rax: 0x80, rdx: 0x1122_3344_5566_7788),
          rip: 0,
          rflags: [.reservedOne, .carry, .direction, .overflow]
        )
        var state = initial
        let execution = try #require(DoryARM64BaselineExecutor(
          maximumCodeBytes: 16 * 1024,
          optimization: optimization
        ).execute(
          bytes: bytes,
          at: 0,
          mode: .long64,
          addressSpaceID: UInt64(0x2300 + index),
          maximumInstructions: 1,
          state: &state,
          memory: memory
        ))

        #expect(execution.block.tier.rawValue == optimization.rawValue)
        #expect(execution.block.requiresMemoryCallbacks)
        #expect(execution.exitCode == .interpreter)
        #expect(state == initial)
      }
    #endif
  }

  @Test func lowByteRegisterWritesInvalidateOptimizerFullRegisterConstants() throws {
    #if arch(arm64)
      let bytes: [UInt8] = [
        0x48, 0xB8, 0x88, 0x11, 0x00, 0x00, 0, 0, 0, 0,  // mov rax,0x1188
        0x22, 0x00,  // and al,byte ptr [rax]
        0x48, 0x89, 0xC3,  // mov rbx,rax
      ]
      let interpretedMemory = try DoryX86ByteArrayMemory(byteCount: 0x1200)
      let translatedMemory = try DoryX86ByteArrayMemory(byteCount: 0x1200)
      for memory in [interpretedMemory, translatedMemory] {
        try memory.write(at: 0, bytes: bytes)
        try memory.write(at: 0x1188, bytes: [0xF0])
      }
      let initialFlags: DoryX86RFLAGS = [.reservedOne, .carry, .parity, .overflow]
      var interpreted = try DoryX86ArchitecturalState(rip: 0, rflags: initialFlags)
      for _ in 0..<3 {
        guard case .retired = DoryX86Interpreter().step(
          state: &interpreted,
          memory: interpretedMemory,
          mode: .long64
        ) else { Issue.record("interpreter did not retire optimizer regression flow"); return }
      }

      var translated = try DoryX86ArchitecturalState(rip: 0, rflags: initialFlags)
      let execution = try #require(DoryARM64BaselineExecutor(
        maximumCodeBytes: 16 * 1024,
        optimization: .optimizing
      ).execute(
        bytes: bytes,
        at: 0,
        mode: .long64,
        addressSpaceID: 0x2400,
        maximumInstructions: 3,
        state: &translated,
        memory: translatedMemory
      ))

      #expect(execution.block.tier == .optimizing)
      #expect(execution.block.guestInstructionCount == 3)
      #expect(translated == interpreted)
      #expect(translated.registers.rax == 0x1180)
      #expect(translated.registers.rbx == 0x1180)
    #endif
  }

  @Test func wordMemoryArithmeticMatchesInterpreterAndPreservesFaultState() throws {
    #if arch(arm64)
    let encodings: [[UInt8]] = [
      [0x66, 0x83, 0x44, 0x7C, 0x58, 0x01], // measured add [rsp+rdi*2+0x58],1
      [0x66, 0x83, 0x6C, 0x74, 0x58, 0x01], // measured sub [rsp+rsi*2+0x58],1
      [0x66, 0x83, 0x02, 0xFF],             // add word [rdx],-1
      [0x66, 0x83, 0x2A, 0xFF],             // sub word [rdx],-1
      [0x66, 0x01, 0x1A],                   // add word [rdx],bx
      [0x66, 0x44, 0x29, 0x0A],             // sub word [rdx],r9w
    ]
    let values: [UInt64] = [0, 1, 0xF, 0x10, 0x7FFF, 0x8000, 0xFFFF]
    for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
      let executor = try DoryARM64BaselineExecutor(
        maximumCodeBytes: 64 * 1024, optimization: optimization)
      for (index, bytes) in encodings.enumerated() {
        for value in values {
          for source in index < 4 ? [UInt64(0)] : values {
            let reference = try DoryX86ByteArrayMemory(byteCount: 512)
            let native = try DoryX86ByteArrayMemory(byteCount: 512)
            for memory in [reference, native] {
              try memory.write(at: 0, bytes: bytes)
              try memory.write(at: 255, bytes: [0xAA, 0, 0, 0x55])
              try memory.writeScalar(at: 256, value: value, byteCount: 2)
            }
            var interpreted = try DoryX86ArchitecturalState(
              registers: .init(rdx: 256, rbx: 0xABCD_0000 | source,
                rsp: 160, rsi: 4, rdi: 4, r9: 0xDCBA_0000 | source), rip: 0,
              rflags: [.reservedOne, .carry, .overflow, .zero, .sign, .parity,
                       .auxiliaryCarry, .interruptEnable, .direction])
            var translated = interpreted
            let decoded = try DoryX86Decoder().decode(bytes, at: 0, mode: .long64)
            #expect(DoryX86Interpreter().step(state: &interpreted, memory: reference, mode: .long64)
              == .retired(decoded))
            let execution = try #require(executor.execute(bytes: bytes, at: 0, mode: .long64,
              addressSpaceID: 0, maximumInstructions: 1, state: &translated, memory: native))
            #expect(execution.exitCode == .dispatch)
            #expect(execution.block.tier.rawValue == optimization.rawValue)
            #expect(translated == interpreted)
            #expect(try native.read(at: 0, byteCount: 512) == reference.read(at: 0, byteCount: 512))
          }
        }
        for failure in 0..<3 {
          // Read decline, write rejection, and a word crossing the mapped boundary.
          let memory = try SelectiveRestartableMemory(
            byteCount: failure == 2 ? 257 : 512,
            declinedAddress: failure == 0 ? 256 : .max,
            rejectedWriteAddress: failure == 1 ? 256 : nil)
          try memory.backing.write(at: 0, bytes: bytes)
          try memory.backing.write(at: 255, bytes: [0xAA, 0xFF])
          let before = try memory.backing.read(at: 0, byteCount: failure == 2 ? 257 : 512)
          let initial = try DoryX86ArchitecturalState(
            registers: .init(rdx: 256, rbx: 1, rsp: 160, rsi: 4, rdi: 4, r9: 1), rip: 0,
            rflags: [.reservedOne, .carry, .overflow, .direction])
          var state = initial
          let execution = try #require(executor.execute(bytes: bytes, at: 0, mode: .long64,
            addressSpaceID: 0, maximumInstructions: 1, state: &state, memory: memory))
          #expect(execution.block.tier.rawValue == optimization.rawValue)
          #expect(execution.exitCode == .interpreter)
          #expect(state == initial)
          #expect(memory.restartableReads == 1)
          #expect(memory.scalarWrites == (failure == 1 ? 1 : 0))
          #expect(try memory.backing.read(at: 0, byteCount: before.count) == before)
        }
      }
    }
    #endif
  }

  @Test func byteMemoryOrMatchesInterpreterAndPreservesFaultState() throws {
    #if arch(arm64)
    let encodings: [[UInt8]] = [
      [0x3E, 0x80, 0x0A, 0x08], // measured or byte ptr [rdx],8
      [0x08, 0x1A],             // or byte ptr [rdx],bl
      [0x44, 0x08, 0x0A],       // or byte ptr [rdx],r9b
    ]
    for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
      for bytes in encodings {
        for value: UInt8 in [0, 8, 0x7F, 0x80, 0xFF] {
          let reference = try DoryX86ByteArrayMemory(byteCount: 512)
          let native = try DoryX86ByteArrayMemory(byteCount: 512)
          for memory in [reference, native] {
            try memory.write(at: 0, bytes: bytes)
            try memory.write(at: 255, bytes: [0xAA, value, 0x55])
          }
          var interpreted = try DoryX86ArchitecturalState(
            registers: .init(rdx: 256, rbx: 0x1234_0080, r9: 0xABCD_0008), rip: 0,
            rflags: [.reservedOne, .carry, .overflow, .zero, .auxiliaryCarry, .direction])
          var translated = interpreted
          let decoded = try DoryX86Decoder().decode(bytes, at: 0, mode: .long64)
          #expect(DoryX86Interpreter().step(state: &interpreted, memory: reference, mode: .long64)
            == .retired(decoded))
          let execution = try #require(DoryARM64BaselineExecutor(
            maximumCodeBytes: 16 * 1024, optimization: optimization).execute(
              bytes: bytes, at: 0, mode: .long64, addressSpaceID: 0,
              maximumInstructions: 1, state: &translated, memory: native))
          #expect(execution.exitCode == .dispatch)
          #expect(execution.block.tier.rawValue == optimization.rawValue)
          #expect(translated == interpreted)
          #expect(try native.read(at: 0, byteCount: 512) == reference.read(at: 0, byteCount: 512))
        }
      }
      for declineRead in [false, true] {
        let bytes = encodings[0]
        let memory = try SelectiveRestartableMemory(
          byteCount: 512, declinedAddress: declineRead ? 256 : 400,
          rejectedWriteAddress: declineRead ? nil : 256)
        try memory.backing.write(at: 0, bytes: bytes)
        try memory.backing.write(at: 256, bytes: [0x40])
        let initial = try DoryX86ArchitecturalState(registers: .init(rdx: 256), rip: 0,
          rflags: [.reservedOne, .carry, .overflow, .direction])
        var state = initial
        let execution = try #require(DoryARM64BaselineExecutor(
          maximumCodeBytes: 16 * 1024, optimization: optimization).execute(
            bytes: bytes, at: 0, mode: .long64, addressSpaceID: 0,
            maximumInstructions: 1, state: &state, memory: memory))
        #expect(execution.block.tier.rawValue == optimization.rawValue)
        #expect(execution.exitCode == .interpreter)
        #expect(state == initial)
        #expect(try memory.backing.read(at: 256, byteCount: 1) == [0x40])
      }
    }
    #endif
  }

  @Test func measuredLowByteAndCompilesNativelyWhileOtherWritesStayBounded() throws {
    let measured: [([UInt8], UInt64, Bool)] = [
      ([0x20, 0xC1], 0x1FDC_191F, false),
      ([0x41, 0x80, 0x66, 0x10, 0xFD], 0x95D5_049D, true),
      ([0x22, 0x15, 0x8E, 0xBE, 0x09, 0x02], 0xFFFF_FFFF_9E6B_AF6C, true),
      ([0x22, 0x00], 0x1FDC_1921, true),
    ]
    for (bytes, address, requiresMemoryCallbacks) in measured {
      let block = try DoryX86IRTranslator().translate(bytes, at: address, mode: .long64)
      for tier in [DoryARM64CompilationTier.baseline, .optimizing] {
        let candidate = tier == .optimizing ? DoryIROptimizer().optimize(block).block : block
        let compiled = DoryARM64BaselineEmitter().compile(candidate, tier: tier)
        #expect(compiled.tier == tier)
        #expect(compiled.requiresMemoryCallbacks == requiresMemoryCallbacks)
      }
    }

    let excludedWrites: [[UInt8]] = [
      [0x00, 0xC1], [0x28, 0xC1], [0x30, 0xC1],
      [0x30, 0x18],
    ]
    for bytes in excludedWrites {
      let excluded = try DoryX86IRTranslator().translate(bytes, at: 0, mode: .long64)
      #expect(DoryARM64BaselineEmitter().compile(excluded).tier == .interpreterFallback)
    }
    let highByte = try DoryX86IRTranslator().translate([0x20, 0xE0], at: 0, mode: .long64)
    #expect(DoryARM64BaselineEmitter().compile(highByte).tier == .interpreterFallback)
  }

  @Test func measuredRegisterStackSitesCompileNativelyWhileComplexFormsStayBounded() throws {
    let measured: [([UInt8], UInt64)] = [
      ([0x41, 0x55], 0x12E4_D060A),  // push r13
      ([0x5A], 0x12E4_D06C9),  // pop rdx
      ([0x6A, 0xFE], 0x1FDC_1959),  // push -2
      ([0x9C], 0x910F_3033),  // pushfq in the Linux timer-accounting spinlock path
    ]
    for (bytes, address) in measured {
      let block = try DoryX86IRTranslator().translate(bytes, at: address, mode: .long64)
      for tier in [DoryARM64CompilationTier.baseline, .optimizing] {
        let candidate = tier == .optimizing ? DoryIROptimizer().optimize(block).block : block
        let compiled = DoryARM64BaselineEmitter().compile(candidate, tier: tier)
        #expect(compiled.tier == tier)
        #expect(compiled.requiresMemoryCallbacks)
      }
    }

    let stackPointerFlow = try DoryX86IRTranslator().translate(
      [
        0x48, 0xBC, 0x00, 0x01, 0, 0, 0, 0, 0, 0,  // mov rsp,0x100
        0x58,  // pop rax
        0x48, 0x89, 0xE3,  // mov rbx,rsp
      ],
      at: 0,
      mode: .long64
    )
    let optimizedFlow = DoryIROptimizer().optimize(stackPointerFlow).block
    guard case .copy(
      destination: .register(let target),
      source: .register(let source)
    ) = optimizedFlow.statements.last
    else {
      Issue.record("stack pop must invalidate the optimizer's pre-pop RSP constant")
      return
    }
    #expect(target.index == 3)
    #expect(source.index == 4)

    let excluded: [([UInt8], DoryX86ExecutionMode)] = [
      ([0x5C], .long64),  // pop rsp has special final-pointer semantics
      ([0xFF, 0x30], .long64),  // push qword ptr [rax]
      ([0x8F, 0x00], .long64),  // pop qword ptr [rax]
      ([0x66, 0x50], .long64),  // push ax
      ([0x66, 0x6A, 0xFE], .long64),  // push imm8 as a word
      ([0x66, 0x9C], .long64),  // pushfw keeps distinct low-word semantics
      ([0x66, 0x58], .long64),  // pop ax
      ([0x50], .protected32),
    ]
    for (bytes, mode) in excluded {
      let block = try DoryX86IRTranslator().translate(bytes, at: 0, mode: mode)
      #expect(
        DoryARM64BaselineEmitter().compile(block).tier == .interpreterFallback,
        "excluded stack form unexpectedly compiled: \(bytes) in \(mode)"
      )
    }

    let invalid = DoryIRRegister(bank: "not.x86.gpr", index: 0, width: .i64)
    for statement in [
      DoryIRStatement.stackPush(source: .register(invalid)),
      .stackPop(destination: .register(invalid)),
    ] {
      let block = DoryIRBasicBlock(
        guestStart: 0,
        guestByteCount: 1,
        guestInstructionCount: 1,
        statements: [statement],
        terminator: .next(1)
      )
      #expect(DoryARM64BaselineEmitter().compile(block).tier == .interpreterFallback)
    }
  }

  @Test func measuredInterruptFlagSitesCompileWithBoundedPrivilegeScope() throws {
    let cli = try DoryX86IRTranslator().translate(
      [0xFA],
      at: 0x910F_3034,
      mode: .long64
    )
    #expect(cli.statements == [.clearInterruptFlag])
    #expect(DoryARM64BaselineEmitter().compile(cli).tier == .baseline)
    #expect(!DoryARM64BaselineEmitter().compile(cli).requiresMemoryCallbacks)

    let sti = try DoryX86IRTranslator().translate([0xFB], at: 0, mode: .long64)
    #expect(DoryARM64BaselineEmitter().compile(sti).tier == .interpreterFallback)

    let protected = try DoryX86IRTranslator().translate([0xFA], at: 0, mode: .protected32)
    #expect(DoryARM64BaselineEmitter().compile(protected).tier == .interpreterFallback)
  }

  @Test func directionFlagWritesMatchInterpreterAcrossTiers() throws {
    #if arch(arm64)
      struct Case {
        let bytes: [UInt8]
        let setsDirection: Bool
      }
      struct PrivilegeCase {
        let selector: UInt16
        let attributes: UInt16
      }
      let cases = [
        Case(bytes: [0xFC], setsDirection: false),  // CLD
        Case(bytes: [0xFD], setsDirection: true),  // STD
      ]
      let privilegeCases = [
        PrivilegeCase(selector: 8, attributes: 0xA09B),
        PrivilegeCase(selector: 3, attributes: 0xA0FB),
      ]
      for testCase in cases {
        for startsWithDirection in [false, true] {
          for privilegeCase in privilegeCases {
            let address: UInt64 = 0x1FDC_191F
            let decoded = try DoryX86Decoder().decode(testCase.bytes, at: address, mode: .long64)
            let translated = try DoryX86IRTranslator().translate(
              testCase.bytes, at: address, mode: .long64)
            #expect(
              translated.statements == [
                DoryIRStatement.setDirectionFlag(enabled: testCase.setsDirection)
              ]
            )
            let initialFlags: DoryX86RFLAGS = startsWithDirection
              ? [.reservedOne, .carry, .parity, .direction, .interruptEnable, .overflow]
              : [.reservedOne, .carry, .parity, .interruptEnable, .overflow]
            let expectedFlags: DoryX86RFLAGS = testCase.setsDirection
              ? [.reservedOne, .carry, .parity, .direction, .interruptEnable, .overflow]
              : [.reservedOne, .carry, .parity, .interruptEnable, .overflow]

            for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
              var interpreted = try DoryX86ArchitecturalState(
                rip: address,
                rflags: initialFlags,
                cs: .init(
                  selector: privilegeCase.selector,
                  attributes: privilegeCase.attributes,
                  limit: .max
                )
              )
              #expect(DoryX86Interpreter().step(
                state: &interpreted,
                memory: try DoryX86ByteArrayMemory(baseAddress: address, bytes: testCase.bytes),
                mode: .long64) == .retired(decoded))

              var native = try DoryX86ArchitecturalState(
                rip: address,
                rflags: initialFlags,
                cs: .init(
                  selector: privilegeCase.selector,
                  attributes: privilegeCase.attributes,
                  limit: .max
                )
              )
              let execution = try #require(
                DoryARM64BaselineExecutor(
                  maximumCodeBytes: 4096,
                  optimization: optimization
                ).execute(
                  bytes: testCase.bytes,
                  at: native.rip,
                  mode: .long64,
                  addressSpaceID: UInt64(privilegeCase.selector),
                  maximumInstructions: 1,
                  state: &native
                )
              )
              #expect(execution.block.tier.rawValue == optimization.rawValue)
              #expect(!execution.block.requiresMemoryCallbacks)
              #expect(native == interpreted)
              #expect(native.rflags == expectedFlags)
            }
          }
        }
      }

      let protected = try DoryX86IRTranslator().translate([0xFC], at: 0, mode: .protected32)
      #expect(DoryARM64BaselineEmitter().compile(protected).tier == .interpreterFallback)
    #endif
  }

  @Test func registerBitTestsMatchInterpreterAcrossTiers() throws {
    #if arch(arm64)
      struct Case {
        let name: String
        let bytes: [UInt8]
        let rax: UInt64
        let rcx: UInt64
        let expectedRAX: UInt64
        let expectedCarry: Bool
      }
      let cases = [
        Case(
          name: "bt eax, ecx preserves high rax and clears incoming CF",
          bytes: [0x0F, 0xA3, 0xC8],
          rax: 0xDEAD_BEEF_0000_0000,
          rcx: 4,
          expectedRAX: 0xDEAD_BEEF_0000_0000,
          expectedCarry: false
        ),
        Case(
          name: "bt rax, negative rcx masks to bit 63",
          bytes: [0x48, 0x0F, 0xA3, 0xC8],
          rax: 1 << 63,
          rcx: UInt64.max,
          expectedRAX: 1 << 63,
          expectedCarry: true
        ),
        Case(
          name: "bts eax, wrapped imm8 writes low dword and clears incoming CF",
          bytes: [0x0F, 0xBA, 0xE8, 0x24],
          rax: 0xCAFE_BABE_0000_0000,
          rcx: 0,
          expectedRAX: 0x0000_0000_0000_0010,
          expectedCarry: false
        ),
        Case(
          name: "btr rax, imm8 clears a high qword bit",
          bytes: [0x48, 0x0F, 0xBA, 0xF0, 0x3F],
          rax: 0x8000_0000_0000_0001,
          rcx: 0,
          expectedRAX: 0x0000_0000_0000_0001,
          expectedCarry: true
        ),
        Case(
          name: "btc rax, rax reads old rax as the index before writing the base",
          bytes: [0x48, 0x0F, 0xBB, 0xC0],
          rax: (1 << 10) | 10,
          rcx: 0,
          expectedRAX: 10,
          expectedCarry: true
        ),
        Case(
          name: "btr eax, ecx zero-extends the written dword",
          bytes: [0x0F, 0xB3, 0xC8],
          rax: 0xFFFF_0000_0000_0001,
          rcx: 0,
          expectedRAX: 0,
          expectedCarry: true
        ),
      ]
      for testCase in cases {
        let address: UInt64 = 0xB17_7000
        let decoded = try DoryX86Decoder().decode(testCase.bytes, at: address, mode: .long64)
        let translated = try DoryX86IRTranslator().translate(
          testCase.bytes, at: address, mode: .long64)
        #expect(translated.statements.count == 1)
        if case .bitTestRegister = translated.statements.first {
          // Expected native lowering for register-base bit tests.
        } else {
          Issue.record("\(testCase.name) did not lower to register bit-test IR")
        }

        for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
          let initial = try DoryX86ArchitecturalState(
            registers: .init(rax: testCase.rax, rcx: testCase.rcx),
            rip: address,
            rflags: [.reservedOne, .carry, .parity, .sign, .overflow],
            cs: .init(selector: 8, attributes: 0xA09B, limit: .max)
          )
          var interpreted = initial
          #expect(DoryX86Interpreter().step(
            state: &interpreted,
            memory: try DoryX86ByteArrayMemory(baseAddress: address, bytes: testCase.bytes),
            mode: .long64) == .retired(decoded))

          var native = initial
          let execution = try #require(
            DoryARM64BaselineExecutor(
              maximumCodeBytes: 4096,
              optimization: optimization
            ).execute(
              bytes: testCase.bytes,
              at: native.rip,
              mode: .long64,
              addressSpaceID: 0,
              maximumInstructions: 1,
              state: &native
            )
          )
          #expect(execution.block.tier.rawValue == optimization.rawValue)
          #expect(!execution.block.requiresMemoryCallbacks)
          #expect(native == interpreted)
          #expect(native.registers.rax == testCase.expectedRAX)
          #expect(native.rflags.contains(.carry) == testCase.expectedCarry)
        }
      }

      let memoryBTS = try DoryX86IRTranslator().translate(
        [0xF0, 0x0F, 0xBA, 0x28, 0x04], at: 0, mode: .long64)
      #expect(DoryARM64BaselineEmitter().compile(memoryBTS).tier == .interpreterFallback)

      let memoryRegisterBT = try DoryX86IRTranslator().translate(
        [0x48, 0x0F, 0xA3, 0x0F], at: 0, mode: .long64)
      #expect(DoryARM64BaselineEmitter().compile(memoryRegisterBT).tier == .interpreterFallback)
      var userState = try DoryX86ArchitecturalState(
        registers: .init(rdi: 0x80), rip: 0,
        cs: .init(selector: 0x1B, attributes: 0xA0FB, limit: .max))
      #expect(try DoryARM64BaselineExecutor(maximumCodeBytes: 4096).execute(
        bytes: [0x48, 0x0F, 0xBA, 0x37, 13], at: 0, mode: .long64, addressSpaceID: 0,
        maximumInstructions: 1, state: &userState,
        memory: DoryX86ByteArrayMemory(byteCount: 0x100)) == nil)

      let protectedBTS = try DoryX86IRTranslator().translate(
        [0x0F, 0xBA, 0xE8, 0x04], at: 0, mode: .protected32)
      #expect(DoryARM64BaselineEmitter().compile(protectedBTS).tier == .interpreterFallback)
    #endif
  }

  @Test func immediateMemoryBitTestsMatchInterpreterAcrossTiers() throws {
    #if arch(arm64)
      for byteCount in [4, 8] {
        for operation: UInt8 in 4...7 {
          for bit: UInt8 in [0, 13, 31, 32, 63, 64, 255] {
            for relative in [false, true] {
              let prefixes: [UInt8] = byteCount == 8 ? [0x48] : []
              var bytes = prefixes + [0x0F, 0xBA, operation << 3 | (relative ? 5 : 7)]
              if relative {
                let displacement = UInt32(0x80 - (0x10 + bytes.count + 5))
                bytes += (0..<4).map { UInt8(truncatingIfNeeded: displacement >> ($0 * 8)) }
              }
              bytes.append(bit)
              for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
                for initialValue in [UInt64(0), UInt64.max] {
                  let interpretedMemory = try DoryX86ByteArrayMemory(byteCount: 0x80 + byteCount)
                  let nativeMemory = try DoryX86ByteArrayMemory(byteCount: 0x80 + byteCount)
                  for memory in [interpretedMemory, nativeMemory] {
                    try memory.write(at: 0x10, bytes: bytes)
                    try memory.writeScalar(at: 0x80, value: initialValue, byteCount: byteCount)
                  }
                  let initial = try DoryX86ArchitecturalState(
                    registers: .init(rax: .max, rdi: 0x80), rip: 0x10,
                    rflags: [.reservedOne, .carry, .parity, .zero, .sign, .overflow],
                    cs: .init(selector: 8, attributes: 0xA09B, limit: .max))
                  var interpreted = initial
                  let decoded = try DoryX86Decoder().decode(bytes, at: 0x10, mode: .long64)
                  #expect(DoryX86Interpreter().step(
                    state: &interpreted, memory: interpretedMemory, mode: .long64) == .retired(decoded))
                  var native = initial
                  let result = try #require(DoryARM64BaselineExecutor(
                    maximumCodeBytes: 4096, optimization: optimization
                  ).execute(bytes: bytes, at: 0x10, mode: .long64, addressSpaceID: 0,
                    maximumInstructions: 1, state: &native, memory: nativeMemory))
                  #expect(result.block.tier.rawValue == optimization.rawValue)
                  #expect(result.block.requiresMemoryCallbacks)
                  #expect(result.block.requiresRestartableMemoryReads == (operation != 4))
                  #expect(native == interpreted)
                  #expect(try nativeMemory.read(at: 0, byteCount: 0x80 + byteCount)
                    == interpretedMemory.read(at: 0, byteCount: 0x80 + byteCount))
                }
              }
            }
          }
        }
      }
    #endif
  }

  @Test func immediateMemoryBitResetDeclinesWithoutCommittingStateOrMMIO() throws {
    #if arch(arm64)
      let bytes: [UInt8] = [0x48, 0x0F, 0xBA, 0x37, 13]
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        for address: UInt64 in [0x80, 0x88, 0xFE] {
          let memory = try SelectiveRestartableMemory(
            byteCount: 0x100, declinedAddress: 0x80, rejectedWriteAddress: 0x88)
          try memory.backing.writeScalar(at: 0x80, value: .max, byteCount: 8)
          try memory.backing.writeScalar(at: 0x88, value: .max, byteCount: 8)
          let initial = try DoryX86ArchitecturalState(
            registers: .init(rdi: address), rip: 0x10, rflags: [.reservedOne, .carry, .overflow],
            cs: .init(selector: 8, attributes: 0xA09B, limit: .max))
          var state = initial
          let result = try #require(DoryARM64BaselineExecutor(
            maximumCodeBytes: 4096, optimization: optimization
          ).execute(bytes: bytes, at: state.rip, mode: .long64, addressSpaceID: 0,
            maximumInstructions: 1, state: &state, memory: memory))
          #expect(result.exitCode == .interpreter)
          #expect(state == initial)
          #expect(memory.restartableReads == 1)
          #expect(memory.scalarWrites == (address == 0x88 ? 1 : 0))
          #expect(try memory.backing.readScalar(at: 0x80, byteCount: 8) == .max)
          #expect(try memory.backing.readScalar(at: 0x88, byteCount: 8) == .max)
        }
      }
    #endif
  }

  @Test func memoryCompareExchangeMatchesInterpreterAccumulatorAndFlags() throws {
    #if arch(arm64)
      struct Case {
        let bytes: [UInt8]
        let destination: UInt64
        let rax: UInt64
        let rdx: UInt64
        let expectedRAX: UInt64
        let expectedDestination: UInt64
        let expectedZero: Bool
      }
      let cases = [
        Case(
          bytes: [0xF0, 0x0F, 0xB1, 0x17],
          destination: 0x1122_3344,
          rax: 0xCAFE_BABE_1122_3344,
          rdx: 0x5566_7788,
          expectedRAX: 0xCAFE_BABE_1122_3344,
          expectedDestination: 0x5566_7788,
          expectedZero: true
        ),
        Case(
          bytes: [0x0F, 0xB1, 0x17],
          destination: 0x1122_3344,
          rax: 0xCAFE_BABE_1122_3344,
          rdx: 0x5566_7788,
          expectedRAX: 0xCAFE_BABE_1122_3344,
          expectedDestination: 0x5566_7788,
          expectedZero: true
        ),
        Case(
          bytes: [0xF0, 0x0F, 0xB1, 0x17],
          destination: 0x8877_6655,
          rax: 0xCAFE_BABE_1122_3344,
          rdx: 0x5566_7788,
          expectedRAX: 0x8877_6655,
          expectedDestination: 0x8877_6655,
          expectedZero: false
        ),
        Case(
          bytes: [0x3E, 0x0F, 0xB1, 0x17],
          destination: 0x8877_6655,
          rax: 0xCAFE_BABE_1122_3344,
          rdx: 0x5566_7788,
          expectedRAX: 0x8877_6655,
          expectedDestination: 0x8877_6655,
          expectedZero: false
        ),
        Case(
          bytes: [0x3E, 0x0F, 0xB1, 0x17],
          destination: 0x1122_3344,
          rax: 0xCAFE_BABE_1122_3344,
          rdx: 0x5566_7788,
          expectedRAX: 0xCAFE_BABE_1122_3344,
          expectedDestination: 0x5566_7788,
          expectedZero: true
        ),
        Case(
          bytes: [0xF0, 0x48, 0x0F, 0xB1, 0x17],
          destination: 0x1122_3344_5566_7788,
          rax: 0x1122_3344_5566_7788,
          rdx: 0xAABB_CCDD_EEFF_0011,
          expectedRAX: 0x1122_3344_5566_7788,
          expectedDestination: 0xAABB_CCDD_EEFF_0011,
          expectedZero: true
        ),
        Case(
          bytes: [0x48, 0x0F, 0xB1, 0x17],
          destination: 0x1122_3344_5566_7788,
          rax: 0x1122_3344_5566_7788,
          rdx: 0xAABB_CCDD_EEFF_0011,
          expectedRAX: 0x1122_3344_5566_7788,
          expectedDestination: 0xAABB_CCDD_EEFF_0011,
          expectedZero: true
        ),
        Case(
          bytes: [0xF0, 0x48, 0x0F, 0xB1, 0x17],
          destination: 0x8877_6655_4433_2211,
          rax: 0x1122_3344_5566_7788,
          rdx: 0xAABB_CCDD_EEFF_0011,
          expectedRAX: 0x8877_6655_4433_2211,
          expectedDestination: 0x8877_6655_4433_2211,
          expectedZero: false
        ),
        Case(
          bytes: [0x3E, 0x48, 0x0F, 0xB1, 0x17],
          destination: 0x8877_6655_4433_2211,
          rax: 0x1122_3344_5566_7788,
          rdx: 0xAABB_CCDD_EEFF_0011,
          expectedRAX: 0x8877_6655_4433_2211,
          expectedDestination: 0x8877_6655_4433_2211,
          expectedZero: false
        ),
        Case(
          bytes: [0x3E, 0x48, 0x0F, 0xB1, 0x17],
          destination: 0x1122_3344_5566_7788,
          rax: 0x1122_3344_5566_7788,
          rdx: 0xAABB_CCDD_EEFF_0011,
          expectedRAX: 0x1122_3344_5566_7788,
          expectedDestination: 0xAABB_CCDD_EEFF_0011,
          expectedZero: true
        ),
      ]

      for testCase in cases {
        for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
          let byteCount = testCase.bytes.contains(0x48) ? 8 : 4
          let interpretedMemory = try DoryX86ByteArrayMemory(byteCount: 0x100)
          let nativeMemory = try DoryX86ByteArrayMemory(byteCount: 0x100)
          try interpretedMemory.write(at: 0, bytes: testCase.bytes)
          try nativeMemory.write(at: 0, bytes: testCase.bytes)
          try interpretedMemory.writeScalar(at: 0x80, value: testCase.destination, byteCount: byteCount)
          try nativeMemory.writeScalar(at: 0x80, value: testCase.destination, byteCount: byteCount)
          let initial = try DoryX86ArchitecturalState(
            registers: .init(rax: testCase.rax, rdx: testCase.rdx, rdi: 0x80),
            rip: 0,
            rflags: [.reservedOne, .carry, .sign],
            cs: .init(selector: 8, attributes: 0xA09B, limit: .max)
          )
          var interpreted = initial
          let decoded = try DoryX86Decoder().decode(testCase.bytes, at: 0, mode: .long64)
          #expect(DoryX86Interpreter().step(
            state: &interpreted, memory: interpretedMemory, mode: .long64) == .retired(decoded))

          var native = initial
          let execution = try #require(
            DoryARM64BaselineExecutor(
              maximumCodeBytes: 16 * 1024,
              optimization: optimization
            ).execute(
              bytes: testCase.bytes,
              at: 0,
              mode: .long64,
              addressSpaceID: 0,
              maximumInstructions: 1,
              state: &native,
              memory: nativeMemory
            )
          )

          #expect(execution.block.tier.rawValue == optimization.rawValue)
          #expect(execution.block.requiresMemoryCallbacks)
          #expect(native == interpreted)
          #expect(native.registers.rax == testCase.expectedRAX)
          #expect(native.rflags.contains(.zero) == testCase.expectedZero)
          #expect(try nativeMemory.readScalar(at: 0x80, byteCount: byteCount) == testCase.expectedDestination)
          #expect(try nativeMemory.read(at: 0x80, byteCount: byteCount)
            == interpretedMemory.read(at: 0x80, byteCount: byteCount))
        }
      }
    #endif
  }

  @Test func memoryCompareExchangeHandlesPatchedLockAliasAndFaultRollback() throws {
    #if arch(arm64)
      for bytes in [[UInt8(0x3E), 0x0F, 0xB1, 0x12], [0x3E, 0x48, 0x0F, 0xB1, 0x12]] {
        for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
          let byteCount = bytes.contains(0x48) ? 8 : 4
          let interpretedMemory = try DoryX86ByteArrayMemory(byteCount: 0x100)
          let nativeMemory = try DoryX86ByteArrayMemory(byteCount: 0x100)
          try interpretedMemory.write(at: 0, bytes: bytes)
          try nativeMemory.write(at: 0, bytes: bytes)
          try interpretedMemory.writeScalar(at: 0x80, value: 0x80, byteCount: byteCount)
          try nativeMemory.writeScalar(at: 0x80, value: 0x80, byteCount: byteCount)
          let initial = try DoryX86ArchitecturalState(
            registers: .init(rax: 0xAAAA_BBBB_0000_0080, rdx: 0x80),
            rip: 0,
            rflags: [.reservedOne, .carry, .sign],
            cs: .init(selector: 8, attributes: 0xA09B, limit: .max)
          )
          var interpreted = initial
          let decoded = try DoryX86Decoder().decode(bytes, at: 0, mode: .long64)
          #expect(DoryX86Interpreter().step(
            state: &interpreted, memory: interpretedMemory, mode: .long64) == .retired(decoded))

          var native = initial
          let execution = try #require(DoryARM64BaselineExecutor(
            maximumCodeBytes: 16 * 1024,
            optimization: optimization
          ).execute(
            bytes: bytes,
            at: 0,
            mode: .long64,
            addressSpaceID: 0,
            maximumInstructions: 1,
            state: &native,
            memory: nativeMemory
          ))
          #expect(execution.block.tier.rawValue == optimization.rawValue)
          #expect(native == interpreted)
          #expect(native.registers.rdx == 0x80)
          #expect(try nativeMemory.readScalar(at: 0x80, byteCount: byteCount) == 0x80)
        }
      }

      for bytes in [[UInt8(0x3E), 0x0F, 0xB1, 0x10], [0x3E, 0x48, 0x0F, 0xB1, 0x10]] {
        for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
          let byteCount = bytes.contains(0x48) ? 8 : 4
          let interpretedMemory = try DoryX86ByteArrayMemory(byteCount: 0x100)
          let nativeMemory = try DoryX86ByteArrayMemory(byteCount: 0x100)
          try interpretedMemory.write(at: 0, bytes: bytes)
          try nativeMemory.write(at: 0, bytes: bytes)
          let destination: UInt64 = byteCount == 8 ? 0x1122_3344_5566_7788 : 0x5566_7788
          let source: UInt64 = byteCount == 8 ? 0xAABB_CCDD_EEFF_0011 : 0x1122_3344
          try interpretedMemory.writeScalar(at: 0x80, value: destination, byteCount: byteCount)
          try nativeMemory.writeScalar(at: 0x80, value: destination, byteCount: byteCount)
          let initial = try DoryX86ArchitecturalState(
            registers: .init(rax: 0x80, rdx: source),
            rip: 0,
            rflags: [.reservedOne, .carry, .sign],
            cs: .init(selector: 8, attributes: 0xA09B, limit: .max)
          )
          var interpreted = initial
          let decoded = try DoryX86Decoder().decode(bytes, at: 0, mode: .long64)
          #expect(DoryX86Interpreter().step(
            state: &interpreted, memory: interpretedMemory, mode: .long64) == .retired(decoded))

          var native = initial
          let execution = try #require(DoryARM64BaselineExecutor(
            maximumCodeBytes: 16 * 1024,
            optimization: optimization
          ).execute(
            bytes: bytes,
            at: 0,
            mode: .long64,
            addressSpaceID: 2 + UInt64(byteCount),
            maximumInstructions: 1,
            state: &native,
            memory: nativeMemory
          ))
          #expect(execution.block.tier.rawValue == optimization.rawValue)
          #expect(native == interpreted)
          #expect(native.registers.rax == destination)
          #expect(native.registers.rdx == source)
          #expect(try nativeMemory.readScalar(at: 0x80, byteCount: byteCount) == destination)
        }
      }

      let faultBytes: [UInt8] = [0x3E, 0x0F, 0xB1, 0x17]
      let initial = try DoryX86ArchitecturalState(
        registers: .init(rax: 0x1111_2222, rdx: 0x3333_4444, rdi: 0x80),
        rip: 0,
        rflags: [.reservedOne, .carry, .sign],
        cs: .init(selector: 8, attributes: 0xA09B, limit: .max)
      )
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let faulting = try DoryX86ByteArrayMemory(byteCount: 0x40)
        var faultState = initial
        let faultExecution = try #require(DoryARM64BaselineExecutor(
          maximumCodeBytes: 4096,
          optimization: optimization
        ).execute(
          bytes: faultBytes,
          at: 0,
          mode: .long64,
          addressSpaceID: optimization == .baseline ? 10 : 11,
          maximumInstructions: 1,
          state: &faultState,
          memory: faulting
        ))
        #expect(faultExecution.exitCode == .interpreter)
        #expect(faultState == initial)
      }
    #endif
  }

  @Test func lockedCompareExchangeDeclinesBeforeUnsupportedMemoryOrPrivilegeSideEffects() throws {
    #if arch(arm64)
      let bytes: [UInt8] = [0xF0, 0x0F, 0xB1, 0x17]
      let initial = try DoryX86ArchitecturalState(
        registers: .init(rax: 0x1111_2222, rdx: 0x3333_4444, rdi: 0x80),
        rip: 0,
        rflags: [.reservedOne, .carry, .sign],
        cs: .init(selector: 8, attributes: 0xA09B, limit: .max)
      )

      let nonAtomic = try ScalarTrackingMemory(byteCount: 0x100)
      try nonAtomic.backing.writeScalar(at: 0x80, value: 0x1111_2222, byteCount: 4)
      var nonAtomicState = initial
      let nonAtomicExecution = try #require(
        DoryARM64BaselineExecutor(maximumCodeBytes: 4096).execute(
          bytes: bytes,
          at: 0,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 1,
          state: &nonAtomicState,
          memory: nonAtomic
        )
      )
      #expect(nonAtomicExecution.exitCode == .interpreter)
      #expect(nonAtomicState == initial)
      #expect(nonAtomic.scalarReads == 0)
      #expect(nonAtomic.scalarWrites == 0)
      #expect(try nonAtomic.backing.readScalar(at: 0x80, byteCount: 4) == 0x1111_2222)

      let faulting = try DoryX86ByteArrayMemory(byteCount: 0x40)
      var faultState = initial
      let faultExecution = try #require(
        DoryARM64BaselineExecutor(maximumCodeBytes: 4096).execute(
          bytes: bytes,
          at: 0,
          mode: .long64,
          addressSpaceID: 1,
          maximumInstructions: 1,
          state: &faultState,
          memory: faulting
        )
      )
      #expect(faultExecution.exitCode == .interpreter)
      #expect(faultState == initial)

      var userState = try DoryX86ArchitecturalState(
        registers: initial.registers,
        rip: initial.rip,
        rflags: initial.rflags,
        cs: .init(selector: 3, attributes: 0xA0FB, limit: .max)
      )
      let userMemory = try DoryX86ByteArrayMemory(byteCount: 0x100)
      try userMemory.writeScalar(at: 0x80, value: 0x1111_2222, byteCount: 4)
      #expect(try DoryARM64BaselineExecutor(maximumCodeBytes: 4096).execute(
        bytes: bytes,
        at: 0,
        mode: .long64,
        addressSpaceID: 2,
        maximumInstructions: 1,
        state: &userState,
        memory: userMemory
      ) == nil)
      #expect(userState.registers == initial.registers)
      #expect(userState.rip == initial.rip)
      #expect(userState.rflags == initial.rflags)
      #expect(try userMemory.readScalar(at: 0x80, byteCount: 4) == 0x1111_2222)
    #endif
  }

  @Test func timestampCounterUsesVirtualTSCAndStopsNativeChainAtClockBoundary() throws {
    #if arch(arm64)
      // rdtsc; mov eax,0xdeadbeef. RDTSC is a virtual-clock boundary, so the
      // chained executor must return after publishing only EDX:EAX from state.tsc.
      let bytes: [UInt8] = [0x0F, 0x31, 0xB8, 0xEF, 0xBE, 0xAD, 0xDE]
      let decoded = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: .long64)
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let executor = try DoryARM64BaselineExecutor(
          maximumCodeBytes: 16 * 1024,
          optimization: optimization
        )
        let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: bytes)
        var native = try DoryX86ArchitecturalState(
          registers: .init(rax: 0xAAAA_AAAA_AAAA_AAAA, rdx: 0xBBBB_BBBB_BBBB_BBBB),
          rip: 0x1000,
          rflags: [.reservedOne, .carry],
          cs: .init(selector: 0, attributes: 0xA09B, limit: .max),
          tsc: 0x1122_3344_5566_7788
        )
        var interpreted = native
        #expect(DoryX86Interpreter().step(state: &interpreted, memory: memory, mode: .long64)
          == .retired(decoded))

        let summary = try #require(executor.executeChainedSummary(
          byteProvider: { address, maximumCount in
            try memory.instructionBytes(at: address, maximumCount: maximumCount)
          },
          at: native.rip,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 2,
          state: &native,
          memory: memory
        ))

        #expect(summary.guestInstructionCount == 1)
        #expect(summary.residentBlockCount == 1)
        #expect(summary.exitCode == .dispatch)
        #expect(summary.tier.rawValue == optimization.rawValue)
        #expect(native == interpreted)
        #expect(native.rip == 0x1002)
        #expect(native.registers.rax == 0x5566_7788)
        #expect(native.registers.rdx == 0x1122_3344)
      }
    #endif
  }

  @Test func timestampCounterAfterNativePrefixWaitsForClockResampleBeforeRead() throws {
    #if arch(arm64)
      // mov eax,1; rdtsc. The first dispatch may retire the ordinary prefix, then it must
      // return before RDTSC so the machine clock source can refresh state.tsc on reentry.
      let bytes: [UInt8] = [0xB8, 1, 0, 0, 0, 0x0F, 0x31]
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let executor = try DoryARM64BaselineExecutor(
          maximumCodeBytes: 16 * 1024,
          optimization: optimization
        )
        let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: bytes)
        var state = try DoryX86ArchitecturalState(
          registers: .init(rax: 0xAAAA, rdx: 0xBBBB),
          rip: 0x1000,
          rflags: [.reservedOne],
          cs: .init(selector: 0, attributes: 0xA09B, limit: .max),
          tsc: 0x10
        )

        let prefix = try #require(executor.executeChainedSummary(
          byteProvider: { address, maximumCount in
            try memory.instructionBytes(at: address, maximumCount: maximumCount)
          },
          at: state.rip,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 2,
          state: &state,
          memory: memory
        ))
        #expect(prefix.guestInstructionCount == 1)
        #expect(prefix.residentBlockCount == 1)
        #expect(state.rip == 0x1005)
        #expect(state.registers.rax == 1)
        #expect(state.registers.rdx == 0xBBBB)

        state.tsc = 0x1122_3344_5566_7788
        let timestamp = try #require(executor.executeChainedSummary(
          byteProvider: { address, maximumCount in
            try memory.instructionBytes(at: address, maximumCount: maximumCount)
          },
          at: state.rip,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 1,
          state: &state,
          memory: memory
        ))
        #expect(timestamp.guestInstructionCount == 1)
        #expect(timestamp.residentBlockCount == 1)
        #expect(state.rip == 0x1007)
        #expect(state.registers.rax == 0x5566_7788)
        #expect(state.registers.rdx == 0x1122_3344)
      }
    #endif
  }

  @Test func timestampCounterNativeFastPathKeepsUnsupportedAndUserGatesOnInterpreterPath() throws {
    #if arch(arm64)
      let bytes: [UInt8] = [0x0F, 0x31]
      let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: bytes)
      let baseline = DoryX86CPUProfile.compatibleV1
      let hiddenTSC = DoryX86CPUProfile(
        identifier: "test.hidden-native-tsc",
        features: baseline.features.subtracting([.tsc]),
        physicalAddressBits: baseline.physicalAddressBits,
        linearAddressBits: baseline.linearAddressBits,
        virtualTSCFrequencyHz: baseline.virtualTSCFrequencyHz
      )
      let cases: [(String, DoryX86CPUProfile, UInt16, UInt64)] = [
        ("hidden TSC", hiddenTSC, 0, 0),
        ("user CPL", baseline, 3, 0),
        ("user CPL with CR4.TSD", baseline, 3, 1 << 2),
      ]
      for (name, profile, selector, cr4) in cases {
        let executor = try DoryARM64BaselineExecutor(
          maximumCodeBytes: 16 * 1024,
          profile: profile
        )
        var state = try DoryX86ArchitecturalState(
          registers: .init(rax: 1, rdx: 2),
          rip: 0x1000,
          rflags: [.reservedOne],
          cs: .init(selector: selector, attributes: selector == 0 ? 0xA09B : 0xA0FB, limit: .max),
          control: .init(cr4: cr4),
          tsc: 0x1122_3344_5566_7788
        )
        let original = state
        let summary = try executor.executeChainedSummary(
          byteProvider: { address, maximumCount in
            try memory.instructionBytes(at: address, maximumCount: maximumCount)
          },
          at: state.rip,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 1,
          state: &state,
          memory: memory
        )
        #expect(summary == nil, "unexpected native RDTSC execution for \(name)")
        #expect(state == original, "native RDTSC fallback changed state for \(name)")
      }
    #endif
  }

  @Test func nativeFencesPreserveMemorySynchronizationAndFaultBoundaries() throws {
    #if arch(arm64)
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        for opcode: UInt8 in [0xE8, 0xF0, 0xF8] { // LFENCE, MFENCE, SFENCE
          let memory = try SelectiveRestartableMemory(byteCount: 0x100, declinedAddress: .max)
          let executor = try DoryARM64BaselineExecutor(
            maximumCodeBytes: 16 * 1024, optimization: optimization)
          // Store; fence; faulting load. A later fault must neither undo the store nor
          // replay synchronization, and a prior fault must never reach synchronization.
          let bytes: [UInt8] = [0x48, 0x89, 0x08, 0x0F, 0xAE, opcode, 0x48, 0x8B, 0x1A]
          var state = try DoryX86ArchitecturalState(
            registers: .init(rax: 0x80, rcx: 0x1234, rdx: 0x100), rip: 0x1000,
            rflags: [.reservedOne, .carry, .overflow, .direction])
          let initial = state
          let summary = try #require(executor.executeChainedSummary(
            byteProvider: { address, count in
              let offset = Int(address - 0x1000)
              return Array(bytes.dropFirst(offset).prefix(count))
            }, at: state.rip, mode: .long64, addressSpaceID: 0,
            maximumInstructions: 3, state: &state, memory: memory))
          #expect(summary.guestInstructionCount == 2)
          #expect(state.rip == 0x1006)
          #expect(state.registers == initial.registers)
          #expect(state.rflags == initial.rflags)
          #expect(memory.synchronizationWriteCounts == [1])
          #expect(try memory.backing.readScalar(at: 0x80, byteCount: 8) == 0x1234)

          let faultBefore: [UInt8] = [0x48, 0x8B, 0x1A, 0x0F, 0xAE, opcode]
          state.rip = 0x2000
          let before = state
          _ = try executor.executeChainedSummary(
            byteProvider: { address, count in
              Array(faultBefore.dropFirst(Int(address - 0x2000)).prefix(count))
            }, at: state.rip, mode: .long64, addressSpaceID: 0,
            maximumInstructions: 2, state: &state, memory: memory)
          #expect(state == before)
          #expect(memory.synchronizationWriteCounts == [1])
        }
      }
    #endif
  }

  @Test func nativeFencesRespectFeatureProfilesAndRequireMemoryAuthority() throws {
    #if arch(arm64)
      let baseline = DoryX86CPUProfile.compatibleV1
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        for hidden: Set<DoryX86Feature> in [[.sse, .sse2], [.sse2]] {
          let profile = DoryX86CPUProfile(
            identifier: "test.native-fence-gate", features: baseline.features.subtracting(hidden),
            physicalAddressBits: baseline.physicalAddressBits,
            linearAddressBits: baseline.linearAddressBits,
            virtualTSCFrequencyHz: baseline.virtualTSCFrequencyHz)
          let executor = try DoryARM64BaselineExecutor(
            maximumCodeBytes: 16 * 1024, profile: profile, optimization: optimization)
          for opcode: UInt8 in [0xE8, 0xF0, 0xF8] {
            let memory = try SelectiveRestartableMemory(byteCount: 0x100, declinedAddress: .max)
            var state = try DoryX86ArchitecturalState(rip: 0x1000 + UInt64(opcode) * 16)
            let initial = state
            let execution = try executor.execute(
              bytes: [0x0F, 0xAE, opcode], at: state.rip, mode: .long64,
              addressSpaceID: 0, maximumInstructions: 1, state: &state, memory: memory)
            let allowed = opcode == 0xF8 && !hidden.contains(.sse)
            #expect((execution != nil) == allowed)
            #expect(memory.synchronizationWriteCounts.count == (allowed ? 1 : 0))
            var expected = initial
            if allowed { expected.rip += 3 }
            #expect(state == expected)
          }
        }
        let executor = try DoryARM64BaselineExecutor(
          maximumCodeBytes: 4096, optimization: optimization)
        var state = try DoryX86ArchitecturalState(rip: 0x3000)
        let original = state
        #expect(try executor.execute(
          bytes: [0x0F, 0xAE, 0xE8], at: state.rip, mode: .long64,
          addressSpaceID: 0, maximumInstructions: 1, state: &state) == nil)
        #expect(state == original)
      }
    #endif
  }

  @Test func nativeFenceRejectsIRThatCouldReplaySynchronization() throws {
    let fence = DoryIRStatement.memoryFence(.load)
    let emitter = DoryARM64BaselineEmitter()
    for block in [
      DoryIRBasicBlock(guestStart: 0, guestByteCount: 6, guestInstructionCount: 2,
        statements: [fence, fence], terminator: .next(6)),
      DoryIRBasicBlock(guestStart: 0, guestByteCount: 4, guestInstructionCount: 1,
        statements: [fence], terminator: .returnFromCall(popBytes: 0)),
    ] {
      #expect(emitter.compile(block).tier == .interpreterFallback)
    }
  }

  @Test func pushFlagsAndCliExecuteNativeLongModeKernelFastPath() throws {
    #if arch(arm64)
      let flags: DoryX86RFLAGS = [
        .reservedOne, .carry, .parity, .auxiliaryCarry, .zero, .sign, .trap,
        .interruptEnable, .direction, .overflow, .nestedTask,
        .virtualInterrupt, .virtualInterruptPending, .identification,
      ]

      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let executor = try DoryARM64BaselineExecutor(
          maximumCodeBytes: 16 * 1024,
          optimization: optimization
        )
        let memory = try DoryX86ByteArrayMemory(byteCount: 0x200)
        var pushed = try DoryX86ArchitecturalState(
          registers: .init(rsp: 0x100),
          rip: 0x910F_3033,
          rflags: flags
        )

        let pushExecution = try #require(
          executor.execute(
            bytes: [0x9C],
            at: pushed.rip,
            mode: .long64,
            addressSpaceID: 0,
            maximumInstructions: 1,
            state: &pushed,
            memory: memory
          )
        )
        let expectedFlagsImage =
          (flags.rawValue
            & ~(DoryX86RFLAGS.resume.rawValue | DoryX86RFLAGS.virtual8086.rawValue))
          | DoryX86RFLAGS.reservedOne.rawValue
        let expectedBytes = (0..<8).map {
          UInt8(truncatingIfNeeded: expectedFlagsImage >> UInt64($0 * 8))
        }
        #expect(pushExecution.block.tier.rawValue == optimization.rawValue)
        #expect(pushExecution.block.requiresMemoryCallbacks)
        #expect(pushed.registers.rsp == 0xF8)
        #expect(pushed.rip == 0x910F_3034)
        #expect(pushed.rflags == flags)
        #expect(try memory.read(at: 0xF8, byteCount: 8) == expectedBytes)

        var cleared = pushed
        let cliExecution = try #require(
          executor.execute(
            bytes: [0xFA],
            at: cleared.rip,
            mode: .long64,
            addressSpaceID: 0,
            maximumInstructions: 1,
            state: &cleared,
            memory: memory
          )
        )
        #expect(cliExecution.block.tier.rawValue == optimization.rawValue)
        #expect(!cliExecution.block.requiresMemoryCallbacks)
        #expect(!cleared.rflags.contains(.interruptEnable))
        #expect(cleared.rflags.contains(.reservedOne))
        #expect(cleared.rflags.rawValue == flags.rawValue & ~DoryX86RFLAGS.interruptEnable.rawValue)
        #expect(cleared.rip == 0x910F_3035)
        #expect(cleared.interruptShadow == nil)
      }
    #endif
  }

  @Test func cliFallsBackBeforeUserPrivilegeGeneralProtection() throws {
    #if arch(arm64)
      let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096)
      let initial = try DoryX86ArchitecturalState(
        rip: 0,
        rflags: [.reservedOne, .interruptEnable],
        cs: .init(selector: 3, attributes: 0xA0FB, limit: .max)
      )
      var state = initial

      #expect(
        try executor.execute(
          bytes: [0xFA],
          at: state.rip,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 1,
          state: &state
        ) == nil
      )
      #expect(state == initial)

      var interpreted = initial
      guard
        case .exception(let exception) = DoryX86Interpreter().step(
          state: &interpreted,
          memory: try DoryX86ByteArrayMemory(bytes: [0xFA]),
          mode: .long64)
      else {
        Issue.record("user CLI did not fault through the interpreter fallback")
        return
      }
      #expect(exception.kind == .generalProtection)
      #expect(exception.instructionPointer == initial.rip)
      #expect(interpreted == initial)
    #endif
  }

  @Test func resumeFlagDeclinesNativeExecutionBeforePushFlagsSideEffects() throws {
    #if arch(arm64)
      let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096)
      let memory = try DoryX86ByteArrayMemory(byteCount: 0x200)
      try memory.write(at: 0, bytes: [0x9C])
      let initial = try DoryX86ArchitecturalState(
        registers: .init(rsp: 0x100),
        rip: 0,
        rflags: [.reservedOne, .resume, .interruptEnable]
      )
      var state = initial

      #expect(
        try executor.execute(
          bytes: [0x9C],
          at: state.rip,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 1,
          state: &state,
          memory: memory
        ) == nil
      )
      #expect(state == initial)

      var interpreted = initial
      guard
        case .retired = DoryX86Interpreter().step(
          state: &interpreted,
          memory: memory,
          mode: .long64)
      else {
        Issue.record("PUSHFQ with RF active did not retire through the interpreter fallback")
        return
      }
      #expect(!interpreted.rflags.contains(.resume))
      #expect(interpreted.rflags.contains(.interruptEnable))
      #expect(interpreted.registers.rsp == 0xF8)
      #expect(try memory.read(at: 0xF8, byteCount: 8) == [0x02, 0x02, 0, 0, 0, 0, 0, 0])
    #endif
  }

  @Test func returnAndPopAndIndirectJumpStayNativeInLongMode() throws {
    #if arch(arm64)
      let memory = try DoryX86ByteArrayMemory(byteCount: 0x200)
      try memory.write(at: 0x80, bytes: [0x78, 0x56, 0x34, 0x12, 0, 0, 0, 0])
      let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096)
      var state = try DoryX86ArchitecturalState(
        registers: .init(rax: 0xCAFE_BABE, rsp: 0x80), rip: 0x5000)

      let returned = try #require(
        executor.execute(
          bytes: [0xC2, 0x10, 0x00],
          at: state.rip,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 1,
          state: &state,
          memory: memory
        )
      )
      #expect(returned.block.tier == .baseline)
      #expect(state.rip == 0x1234_5678)
      #expect(state.registers.rsp == 0x98)

      state.rip = 0x6000
      let jumped = try #require(
        executor.execute(
          bytes: [0xFF, 0xE0],
          at: state.rip,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 1,
          state: &state
        )
      )
      #expect(jumped.block.tier == .baseline)
      #expect(!jumped.block.requiresMemoryCallbacks)
      #expect(state.rip == 0xCAFE_BABE)
    #endif
  }

  @Test func memoryIndirectCallEvaluatesItsTargetBeforeTheNativeStackPush() throws {
    #if arch(arm64)
      let memory = try DoryX86ByteArrayMemory(byteCount: 0x200)
      try memory.write(at: 0x88, bytes: [0x78, 0x56, 0x34, 0x12, 0, 0, 0, 0])
      let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096)
      var state = try DoryX86ArchitecturalState(
        registers: .init(rax: 0x80, rsp: 0x100), rip: 0x6100)

      let execution = try #require(
        executor.execute(
          bytes: [0xFF, 0x50, 0x08],
          at: state.rip,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 1,
          state: &state,
          memory: memory
        )
      )
      #expect(execution.block.tier == .baseline)
      #expect(execution.block.requiresMemoryCallbacks)
      #expect(execution.exitCode == .dispatch)
      #expect(state.rip == 0x1234_5678)
      #expect(state.registers.rsp == 0xF8)
      #expect(try memory.read(at: 0xF8, byteCount: 8) == [0x03, 0x61, 0, 0, 0, 0, 0, 0])
    #endif
  }

  @Test func failedNativeCallPushLeavesArchitecturalStateRestartable() throws {
    #if arch(arm64)
      let memory = try DoryX86ByteArrayMemory(byteCount: 0x100)
      let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096)
      let initial = try DoryX86ArchitecturalState(registers: .init(rsp: 4), rip: 0x7000)
      var state = initial

      let execution = try #require(
        executor.execute(
          bytes: [0xE8, 0, 0, 0, 0],
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

  @Test func failedPackedNativeReadLeavesTheWholeBlockRestartable() throws {
    #if arch(arm64)
      let memory = try DoryX86ByteArrayMemory(byteCount: 0x100)
      let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096)
      let initial = try DoryX86ArchitecturalState(
        registers: .init(rax: 0x1000, rbx: 0xCAFE), rip: 0x3000)
      var state = initial

      let execution = try #require(
        executor.execute(
          bytes: [
            0x48, 0x83, 0xC3, 0x01,  // add rbx,1
            0x48, 0x8B, 0x18,  // mov rbx,[rax] -- faults
            0x48, 0x83, 0xC1, 0x01,  // add rcx,1
          ],
          at: state.rip,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 3,
          state: &state,
          memory: memory
        )
      )
      #expect(execution.block.guestInstructionCount == 3)
      #expect(execution.exitCode == .interpreter)
      #expect(state == initial)
    #endif
  }

  @Test func immediateShiftsMatchInterpreterResultsAndFlags() throws {
    #if arch(arm64)
      let cases: [([UInt8], UInt64)] = [
        ([0xC1, 0xE0, 0x01], 0x8000_0001),
        ([0xC1, 0xE8, 0x05], 0xF123_4567),
        ([0xC1, 0xF8, 0x1F], 0x8000_0001),
        ([0x48, 0xC1, 0xE0, 0x01], 0x8000_0000_0000_0001),
        ([0x48, 0xC1, 0xE8, 0x11], 0xF123_4567_89AB_CDEF),
        ([0x48, 0xC1, 0xF8, 0x3F], 0x8000_0000_0000_0001),
      ]
      for (bytes, value) in cases {
        let initialFlags = DoryX86RFLAGS(
          rawValue: DoryX86RFLAGS.reservedOne.rawValue
            | DoryX86RFLAGS.carry.rawValue
            | DoryX86RFLAGS.auxiliaryCarry.rawValue
            | DoryX86RFLAGS.overflow.rawValue
        )
        var interpreted = try DoryX86ArchitecturalState(
          registers: .init(rax: value), rip: 0, rflags: initialFlags)
        let memory = try DoryX86ByteArrayMemory(bytes: bytes)
        _ = DoryX86Interpreter().step(state: &interpreted, memory: memory, mode: .long64)

        var translated = try DoryX86ArchitecturalState(
          registers: .init(rax: value), rip: 0, rflags: initialFlags)
        let execution = try #require(
          DoryARM64BaselineExecutor(maximumCodeBytes: 4096).execute(
            bytes: bytes,
            at: 0,
            mode: .long64,
            addressSpaceID: 0,
            maximumInstructions: 1,
            state: &translated
          )
        )

        #expect(execution.block.tier == .baseline)
        #expect(translated.registers.rax == interpreted.registers.rax)
        #expect(translated.rip == interpreted.rip)
        #expect(translated.rflags == interpreted.rflags)
      }
    #endif
  }

  @Test func kernelHashMultiplyAndRotateMatchInterpreterAcrossTiers() throws {
    #if arch(arm64)
      let initialFlags = DoryX86RFLAGS(
        rawValue: DoryX86RFLAGS.reservedOne.rawValue
          | DoryX86RFLAGS.carry.rawValue
          | DoryX86RFLAGS.parity.rawValue
          | DoryX86RFLAGS.auxiliaryCarry.rawValue
          | DoryX86RFLAGS.zero.rawValue
          | DoryX86RFLAGS.sign.rawValue
          | DoryX86RFLAGS.direction.rawValue
          | DoryX86RFLAGS.interruptEnable.rawValue
          | DoryX86RFLAGS.overflow.rawValue
      )
      let multiplyCases: [([UInt8], DoryX86GeneralRegisters)] = [
        ([0x48, 0x0F, 0xAF, 0xD6], .init(rdx: 0, rsi: 0)),
        ([0x48, 0x0F, 0xAF, 0xD6], .init(rdx: 1, rsi: UInt64.max)),
        ([0x48, 0x0F, 0xAF, 0xD6], .init(rdx: UInt64.max, rsi: 2)),
        ([0x48, 0x0F, 0xAF, 0xD6], .init(rdx: 0x8000_0000_0000_0000, rsi: UInt64.max)),
        ([0x48, 0x0F, 0xAF, 0xD6], .init(rdx: 0x7FFF_FFFF_FFFF_FFFF, rsi: 2)),
        ([0x48, 0x0F, 0xAF, 0xD6], .init(rdx: 0x8000_0000_0000_0000, rsi: 1)),
        ([0x48, 0x0F, 0xAF, 0xD6], .init(rdx: UInt64(bitPattern: -3), rsi: 7)),
        ([0x48, 0x0F, 0xAF, 0xD2], .init(rdx: 0x7FFF_FFFF_FFFF_FFFF)),
        ([0x48, 0x6B, 0xC9, 0x18], .init(rcx: 0)),
        ([0x48, 0x6B, 0xC9, 0x18], .init(rcx: UInt64(bitPattern: -3))),
        ([0x48, 0x6B, 0xC9, 0x18], .init(rcx: 0x7FFF_FFFF_FFFF_FFFF)),
        ([0x48, 0x6B, 0xC9, 0xFE], .init(rcx: 7)),
        ([0x48, 0x6B, 0xC9, 0xFE], .init(rcx: 0x7FFF_FFFF_FFFF_FFFF)),
        ([0x6B, 0xC9, 0xFE], .init(rcx: 0xAABB_CCDD_0000_0007)),
        ([0x6B, 0xC9, 0xFE], .init(rcx: 0xAABB_CCDD_7FFF_FFFF)),
        (
          [0x48, 0x69, 0xC9, 0x00, 0x00, 0x00, 0x80],
          .init(rcx: 2)
        ),
        (
          [0x69, 0xC9, 0x00, 0x00, 0x00, 0x80],
          .init(rcx: 0xAABB_CCDD_0000_0001)
        ),
      ]
      let rotateValues: [UInt64] = [
        0,
        1,
        0x8000_0000_0000_0001,
        0xF123_4567_89AB_CDEF,
      ]

      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let executor = try DoryARM64BaselineExecutor(
          maximumCodeBytes: 16 * 1024,
          optimization: optimization
        )
        for (bytes, registers) in multiplyCases {
          let multiplyExecutor = try DoryARM64BaselineExecutor(
            maximumCodeBytes: 16 * 1024,
            optimization: optimization
          )
          var interpreted = try DoryX86ArchitecturalState(
            registers: registers,
            rip: 0,
            rflags: initialFlags
          )
          _ = DoryX86Interpreter().step(
            state: &interpreted,
            memory: try DoryX86ByteArrayMemory(bytes: bytes),
            mode: .long64
          )

          var translated = try DoryX86ArchitecturalState(
            registers: registers,
            rip: 0,
            rflags: initialFlags
          )
          let execution = try #require(
            multiplyExecutor.execute(
              bytes: bytes,
              at: 0,
              mode: .long64,
              addressSpaceID: 0,
              maximumInstructions: 1,
              state: &translated
            )
          )

          #expect(execution.block.tier.rawValue == optimization.rawValue)
          #expect(translated == interpreted)
        }

        for count in [UInt8(0), 1, 2, 31, 63, 64, 65, 255] {
          for value in rotateValues {
            let bytes: [UInt8] = [0x48, 0xC1, 0xC2, count]  // rol rdx,imm8
            var interpreted = try DoryX86ArchitecturalState(
              registers: .init(rdx: value),
              rip: 0,
              rflags: initialFlags
            )
            _ = DoryX86Interpreter().step(
              state: &interpreted,
              memory: try DoryX86ByteArrayMemory(bytes: bytes),
              mode: .long64
            )

            var translated = try DoryX86ArchitecturalState(
              registers: .init(rdx: value),
              rip: 0,
              rflags: initialFlags
            )
            let execution = try #require(
              executor.execute(
                bytes: bytes,
                at: 0,
                mode: .long64,
                addressSpaceID: 0,
                maximumInstructions: 1,
                state: &translated
              )
            )

            #expect(execution.block.tier.rawValue == optimization.rawValue)
            #expect(translated == interpreted)
          }
        }
      }
    #endif
  }

  @Test func kernelHashArithmeticSetsCarryAndOverflowFromClearState() throws {
    #if arch(arm64)
      let preservedFlags: DoryX86RFLAGS = [
        .reservedOne, .parity, .auxiliaryCarry, .zero, .sign, .direction, .interruptEnable,
      ]
      let cases: [([UInt8], DoryX86GeneralRegisters)] = [
        (
          [0x48, 0x0F, 0xAF, 0xD6],  // imul rdx,rsi
          .init(rdx: 0x7FFF_FFFF_FFFF_FFFF, rsi: 2)
        ),
        (
          [0x48, 0xC1, 0xC2, 0x01],  // rol rdx,1
          .init(rdx: 0x8000_0000_0000_0000)
        ),
      ]

      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let executor = try DoryARM64BaselineExecutor(
          maximumCodeBytes: 4096,
          optimization: optimization
        )
        for (bytes, registers) in cases {
          var interpreted = try DoryX86ArchitecturalState(
            registers: registers,
            rip: 0,
            rflags: preservedFlags
          )
          _ = DoryX86Interpreter().step(
            state: &interpreted,
            memory: try DoryX86ByteArrayMemory(bytes: bytes),
            mode: .long64
          )

          var translated = try DoryX86ArchitecturalState(
            registers: registers,
            rip: 0,
            rflags: preservedFlags
          )
          let execution = try #require(
            executor.execute(
              bytes: bytes,
              at: 0,
              mode: .long64,
              addressSpaceID: 0,
              maximumInstructions: 1,
              state: &translated
            )
          )

          #expect(execution.block.tier.rawValue == optimization.rawValue)
          #expect(translated == interpreted)
          #expect(translated.rflags.contains(.carry))
          #expect(translated.rflags.contains(.overflow))
          #expect(translated.rflags.isSuperset(of: preservedFlags))
        }
      }
    #endif
  }

  @Test func nativeSchedClockRegisterArithmeticMatchesInterpreterAtCPL0() throws {
    #if arch(arm64)
      let initialFlags = DoryX86RFLAGS(
        rawValue: DoryX86RFLAGS.reservedOne.rawValue
          | DoryX86RFLAGS.carry.rawValue
          | DoryX86RFLAGS.parity.rawValue
          | DoryX86RFLAGS.auxiliaryCarry.rawValue
          | DoryX86RFLAGS.zero.rawValue
          | DoryX86RFLAGS.sign.rawValue
          | DoryX86RFLAGS.direction.rawValue
          | DoryX86RFLAGS.interruptEnable.rawValue
          | DoryX86RFLAGS.overflow.rawValue
      )
      let multiplyCases: [DoryX86GeneralRegisters] = [
        .init(rax: 0, rdx: 0x1234),
        .init(rax: 1, rdx: UInt64.max),
        .init(rax: UInt64.max, rdx: 2),
        .init(rax: 0x8000_0000_0000_0000, rdx: 2),
        .init(rax: 0x0123_4567_89AB_CDEF, rdx: 0xFEDC_BA98_7654_3210),
      ]
      let shiftCases: [(registers: DoryX86GeneralRegisters, flags: DoryX86RFLAGS)] = [
        (.init(rax: 0x0123_4567_89AB_CDEF, rcx: 0, rdx: 0xFEDC_BA98_7654_3210), initialFlags),
        (
          .init(rax: 0x8123_4567_89AB_CDEF, rcx: 1, rdx: 0x7EDC_BA98_7654_3210),
          [.reservedOne, .interruptEnable]
        ),
        (
          .init(rax: 0x0123_4567_89AB_CDEF, rcx: 13, rdx: 0xFEDC_BA98_7654_3210),
          initialFlags
        ),
        (
          .init(rax: 0x8000_0000_0000_0001, rcx: 63, rdx: 0x0000_0000_0000_0001),
          [.reservedOne, .carry, .overflow]
        ),
        (
          .init(rax: 0xA5A5_A5A5_A5A5_A5A5, rcx: 65, rdx: 0x5A5A_5A5A_5A5A_5A5A),
          [.reservedOne, .overflow, .zero]
        ),
      ]

      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let executor = try DoryARM64BaselineExecutor(
          maximumCodeBytes: 16 * 1024,
          optimization: optimization
        )
        for registers in multiplyCases {
          try assertNativeArithmeticParity(
            bytes: [0x48, 0xF7, 0xE2],
            registers: registers,
            flags: initialFlags,
            executor: executor,
            optimization: optimization
          )
        }
        for (registers, flags) in shiftCases {
          try assertNativeArithmeticParity(
            bytes: [0x48, 0x0F, 0xAD, 0xD0],
            registers: registers,
            flags: flags,
            executor: executor,
            optimization: optimization
          )
        }
        try assertNativeArithmeticParity(
          bytes: [0x48, 0x0F, 0xAD, 0xC0],
          registers: .init(rax: 0x0123_4567_89AB_CDEF, rcx: 17),
          flags: initialFlags,
          executor: executor,
          optimization: optimization
        )
        try assertNativeArithmeticParity(
          bytes: [0x48, 0x0F, 0xAD, 0xC8],
          registers: .init(
            rax: 0x0123_4567_89AB_CDEF,
            rcx: 0x0000_0000_0000_0011
          ),
          flags: initialFlags,
          executor: executor,
          optimization: optimization
        )
        try assertNativeArithmeticParity(
          bytes: [0x48, 0x0F, 0xAD, 0xD1],
          registers: .init(
            rcx: 0xA5A5_A5A5_A5A5_A511,
            rdx: 0x5A5A_5A5A_5A5A_5A5A
          ),
          flags: initialFlags,
          executor: executor,
          optimization: optimization
        )
        try assertNativeArithmeticSequenceParity(
          bytes: [0x48, 0xF7, 0xE2, 0x48, 0x0F, 0xAD, 0xD0],
          registers: .init(
            rax: 0x0123_4567_89AB_CDEF,
            rcx: 17,
            rdx: 0xFEDC_BA98_7654_3210
          ),
          flags: initialFlags,
          executor: executor,
          optimization: optimization
        )
      }
    #endif
  }

  @Test func immediateDoubleShiftMatchesInterpreterAcrossCountsAndAliases() throws {
    #if arch(arm64)
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let executor = try DoryARM64BaselineExecutor(
          maximumCodeBytes: 256 * 1024, optimization: optimization
        )
        for count in [UInt8(0), 1, 2, 31, 32, 63, 64, 65, 255] {
          for modRM in [UInt8(0xD0), 0xC0, 0xC8, 0xD1] {
            for flags: DoryX86RFLAGS in [
              [.reservedOne],
              [.reservedOne, .carry, .parity, .auxiliaryCarry, .zero, .sign, .overflow, .direction],
            ] {
              try assertNativeArithmeticParity(
                bytes: [0x48, 0x0F, 0xAC, modRM, count],
                registers: .init(
                  rax: 0x8123_4567_89AB_CDEF,
                  rcx: 0x0123_4567_89AB_CD17,
                  rdx: 0x7EDC_BA98_7654_3210
                ),
                flags: flags,
                executor: executor,
                optimization: optimization
              )
            }
          }
        }
      }
    #endif
  }

  @Test func unsignedAccumulatorDivideMatchesInterpreterForZeroHighDividend() throws {
    #if arch(arm64)
      struct Case {
        let bytes: [UInt8]
        let registers: DoryX86GeneralRegisters
      }
      let cases = [
        Case(
          bytes: [0x48, 0xF7, 0xF1],
          registers: .init(rax: 100, rcx: 7, rdx: 0)
        ),
        Case(
          bytes: [0xF7, 0xF1],
          registers: .init(
            rax: 0xAAAA_BBBB_0000_0064,
            rcx: 7,
            rdx: 0xCCCC_DDDD_0000_0000
          )
        ),
        Case(
          bytes: [0x48, 0xF7, 0xF0],
          registers: .init(rax: 0x100, rdx: 0)
        ),
        Case(
          bytes: [0xF7, 0xF1],
          registers: .init(
            rax: 0xAAAA_BBBB_0000_1000,
            rcx: 0xFFFF_FFFF_0000_0031,
            rdx: 0xCCCC_DDDD_0000_0000
          )
        ),
      ]
      let initialFlags = DoryX86RFLAGS(
        rawValue: DoryX86RFLAGS.reservedOne.rawValue
          | DoryX86RFLAGS.carry.rawValue
          | DoryX86RFLAGS.parity.rawValue
          | DoryX86RFLAGS.direction.rawValue
          | DoryX86RFLAGS.overflow.rawValue
      )

      for testCase in cases {
        for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
          var interpreted = try DoryX86ArchitecturalState(
            registers: testCase.registers,
            rip: 0,
            rflags: initialFlags
          )
          let decoded = try DoryX86Decoder().decode(testCase.bytes, at: 0, mode: .long64)
          #expect(DoryX86Interpreter().step(
            state: &interpreted,
            memory: try DoryX86ByteArrayMemory(bytes: testCase.bytes),
            mode: .long64
          ) == .retired(decoded))

          var translated = try DoryX86ArchitecturalState(
            registers: testCase.registers,
            rip: 0,
            rflags: initialFlags
          )
          let execution = try #require(DoryARM64BaselineExecutor(
            maximumCodeBytes: 16 * 1024,
            optimization: optimization
          ).execute(
            bytes: testCase.bytes,
            at: 0,
            mode: .long64,
            addressSpaceID: 0,
            maximumInstructions: 1,
            state: &translated
          ))
          #expect(execution.block.tier.rawValue == optimization.rawValue)
          #expect(translated == interpreted)
          #expect(translated.rflags == initialFlags)
        }
      }
    #endif
  }

  @Test func unsignedAccumulatorDivideFallsBackBeforeUnsupportedWideDividendOrDivideError() throws {
    #if arch(arm64)
      let cases: [([UInt8], DoryX86GeneralRegisters)] = [
        ([0x48, 0xF7, 0xF1], .init(rax: 5, rcx: 0, rdx: 0)),
        ([0x48, 0xF7, 0xF1], .init(rax: 0, rcx: 2, rdx: 1)),
        ([0x48, 0xF7, 0xF1], .init(rax: 0, rcx: 7, rdx: 7)),
        ([0xF7, 0xF1], .init(rax: 0x100, rcx: 2, rdx: 1)),
      ]
      for (bytes, registers) in cases {
        for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
          let initial = try DoryX86ArchitecturalState(
            registers: registers,
            rip: 0,
            rflags: [.reservedOne, .carry, .sign]
          )
          var translated = initial
          let execution = try #require(DoryARM64BaselineExecutor(
            maximumCodeBytes: 16 * 1024,
            optimization: optimization
          ).execute(
            bytes: bytes,
            at: 0,
            mode: .long64,
            addressSpaceID: 1,
            maximumInstructions: 1,
            state: &translated
          ))
          #expect(execution.block.tier.rawValue == optimization.rawValue)
          #expect(execution.exitCode == .interpreter)
          #expect(translated == initial)
        }
      }
    #endif
  }

  @Test func nativeSchedClockArithmeticCoverageRemainsKernelRegisterOnly() throws {
    #if arch(arm64)
      let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096)
      let kernelCS = DoryX86SegmentState(selector: 8, attributes: 0xA09B, limit: .max)
      let userCS = DoryX86SegmentState(selector: 3, attributes: 0xA0FB, limit: .max)

      for bytes in [
        [UInt8]([0x48, 0xF7, 0x20]),  // mul qword ptr [rax]
        [UInt8]([0x48, 0xF7, 0x30]),  // div qword ptr [rax]
        [UInt8]([0x48, 0x0F, 0xAD, 0x10]),  // shrd qword ptr [rax],rdx,cl
        [UInt8]([0x48, 0x0F, 0xAC, 0x10, 32]),  // shrd qword ptr [rax],rdx,32
      ] {
        let translated = try DoryX86IRTranslator().translate(bytes, at: 0, mode: .long64)
        #expect(DoryARM64BaselineEmitter().compile(translated).tier == .interpreterFallback)
      }

      var kernelState = try DoryX86ArchitecturalState(
        registers: .init(rax: 3, rdx: 7),
        rip: 0,
        rflags: [.reservedOne],
        cs: kernelCS
      )
      #expect(try executor.execute(
        bytes: [0x48, 0xF7, 0xE2],
        at: 0,
        mode: .long64,
        addressSpaceID: 0,
        maximumInstructions: 1,
        state: &kernelState
      ) != nil)

      var kernelDivideState = try DoryX86ArchitecturalState(
        registers: .init(rax: 100, rcx: 7, rdx: 0),
        rip: 0,
        rflags: [.reservedOne],
        cs: kernelCS
      )
      #expect(try executor.execute(
        bytes: [0x48, 0xF7, 0xF1],
        at: 0,
        mode: .long64,
        addressSpaceID: 0,
        maximumInstructions: 1,
        state: &kernelDivideState
      ) != nil)

      var userState = try DoryX86ArchitecturalState(
        registers: .init(rax: 3, rcx: 1, rdx: 7),
        rip: 0,
        rflags: [.reservedOne],
        cs: userCS
      )
      #expect(try executor.execute(
        bytes: [0x48, 0xF7, 0xE2],
        at: 0,
        mode: .long64,
        addressSpaceID: 0,
        maximumInstructions: 1,
        state: &userState
      ) == nil)
      #expect(try executor.execute(
        bytes: [0x48, 0x0F, 0xAD, 0xD0],
        at: 0,
        mode: .long64,
        addressSpaceID: 0,
        maximumInstructions: 1,
        state: &userState
      ) == nil)
      #expect(try executor.execute(
        bytes: [0x48, 0xF7, 0xF1],
        at: 0,
        mode: .long64,
        addressSpaceID: 0,
        maximumInstructions: 1,
        state: &userState
      ) == nil)
      #expect(try executor.execute(
        bytes: [0x48, 0x0F, 0xAC, 0xD0, 32],
        at: 0,
        mode: .long64,
        addressSpaceID: 0,
        maximumInstructions: 1,
        state: &userState
      ) == nil)
    #endif
  }

  @Test func nativeTranslationSpansMeasuredKernelHashLoop() throws {
    let bytes: [UInt8] = [
      0x48, 0x8B, 0x10, 0x48, 0x83, 0xC0, 0x20, 0x48, 0x0F, 0xAF, 0xD6,
      0x4C, 0x01, 0xDA, 0x48, 0xC1, 0xC2, 0x1F, 0x48, 0x0F, 0xAF, 0xD1,
      0x49, 0x89, 0xD3, 0x48, 0x8B, 0x50, 0xE8, 0x48, 0x0F, 0xAF, 0xD6,
      0x48, 0x01, 0xFA, 0x48, 0xC1, 0xC2, 0x1F, 0x48, 0x89, 0xD7,
      0x48, 0x8B, 0x50, 0xF0, 0x48, 0x0F, 0xAF, 0xF9, 0x48, 0x0F, 0xAF, 0xD6,
      0x4C, 0x01, 0xEA, 0x48, 0xC1, 0xC2, 0x1F, 0x48, 0x0F, 0xAF, 0xD1,
      0x49, 0x89, 0xD5, 0x48, 0x8B, 0x50, 0xF8, 0x48, 0x0F, 0xAF, 0xD6,
      0x4C, 0x01, 0xE2, 0x48, 0xC1, 0xC2, 0x1F, 0x48, 0x0F, 0xAF, 0xD1,
      0x49, 0x89, 0xD4, 0x48, 0x39, 0xC3, 0x73, 0xA0,
    ]
    let block = try DoryX86IRTranslator().translate(
      bytes,
      at: 0x12E4_35EB0,
      mode: .long64
    )

    #expect(bytes.count == 96)
    #expect(block.guestInstructionCount == 27)
    #expect(block.guestByteCount == bytes.count)
    #expect(
      block.terminator == .conditional(
        condition: "x86.condition.3",
        taken: 0x12E4_35EB0,
        notTaken: 0x12E4_35F10
      ))
    #expect(block.statements.count == 26)
    #expect(
      block.statements.filter {
        if case .signedMultiply = $0 { return true }
        return false
      }.count == 8)
    #expect(
      block.statements.filter {
        if case .shift(.rotateLeft, _, .immediate(31)) = $0 { return true }
        return false
      }.count == 4)
    for tier in [DoryARM64CompilationTier.baseline, .optimizing] {
      let candidate =
        tier == .optimizing
        ? DoryIROptimizer().optimize(block).block
        : block
      let compiled = DoryARM64BaselineEmitter().compile(candidate, tier: tier)
      #expect(candidate.guestInstructionCount == 27)
      #expect(candidate.statements.count == 26)
      #expect(compiled.tier == tier)
      #expect(compiled.requiresRestartableMemoryReads)
    }
  }

  @Test func kernelHashArithmeticCoverageRemainsNarrowAndFailClosed() throws {
    let excluded: [[UInt8]] = [
      [0x66, 0x6B, 0xD6, 0x03],  // imul dx,si,3
      [0xC1, 0xC0, 0x1F],  // rol eax,31
      [0x48, 0xC1, 0x00, 0x1F],  // rol qword ptr [rax],31
      [0x48, 0xD3, 0xC2],  // rol rdx,cl
      [0x48, 0xC1, 0xCA, 0x1F],  // ror rdx,31
    ]

    for bytes in excluded {
      let block = try DoryX86IRTranslator().translate(bytes, at: 0, mode: .long64)
      #expect(DoryARM64BaselineEmitter().compile(block).tier == .interpreterFallback)
    }

    let invalidDestination = DoryIRRegister(bank: "not.x86.gpr", index: 0, width: .i64)
    let validSource = DoryIRRegister(bank: "x86.gpr", index: 0, width: .i64)
    let crafted = DoryIRBasicBlock(
      guestStart: 0,
      guestByteCount: 1,
      guestInstructionCount: 1,
      statements: [
        .signedMultiply(
          destination: .register(invalidDestination),
          lhs: .register(validSource),
          rhs: .register(validSource)
        )
      ],
      terminator: .next(1)
    )
    #expect(DoryARM64BaselineEmitter().compile(crafted).tier == .interpreterFallback)
  }

  @Test func lowByteSetConditionsMatchInterpreterAcrossAllConditionsAndTiers() throws {
    #if arch(arm64)
      let preservedFlags: UInt64 =
        DoryX86RFLAGS.reservedOne.rawValue
        | DoryX86RFLAGS.auxiliaryCarry.rawValue
        | DoryX86RFLAGS.direction.rawValue
        | DoryX86RFLAGS.interruptEnable.rawValue
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let executor = try DoryARM64BaselineExecutor(
          maximumCodeBytes: 16 * 1024,
          optimization: optimization
        )
        for rawCondition in UInt8(0)..<UInt8(16) {
          for flagBits in UInt64(0)..<UInt64(32) {
            var rawFlags = preservedFlags
            if flagBits & 0x01 != 0 { rawFlags |= DoryX86RFLAGS.carry.rawValue }
            if flagBits & 0x02 != 0 { rawFlags |= DoryX86RFLAGS.parity.rawValue }
            if flagBits & 0x04 != 0 { rawFlags |= DoryX86RFLAGS.zero.rawValue }
            if flagBits & 0x08 != 0 { rawFlags |= DoryX86RFLAGS.sign.rawValue }
            if flagBits & 0x10 != 0 { rawFlags |= DoryX86RFLAGS.overflow.rawValue }
            let initialFlags = DoryX86RFLAGS(rawValue: rawFlags)
            let bytes: [UInt8] = [0x41, 0x0F, 0x90 | rawCondition, 0xC1]
            let registers = DoryX86GeneralRegisters(r9: 0x1122_3344_5566_77AA)

            var interpreted = try DoryX86ArchitecturalState(
              registers: registers,
              rip: 0,
              rflags: initialFlags
            )
            _ = DoryX86Interpreter().step(
              state: &interpreted,
              memory: try DoryX86ByteArrayMemory(bytes: bytes),
              mode: .long64
            )

            var translated = try DoryX86ArchitecturalState(
              registers: registers,
              rip: 0,
              rflags: initialFlags
            )
            let execution = try #require(
              executor.execute(
                bytes: bytes,
                at: 0,
                mode: .long64,
                addressSpaceID: 0,
                maximumInstructions: 1,
                state: &translated
              )
            )

            #expect(execution.block.tier.rawValue == optimization.rawValue)
            #expect(translated == interpreted)
            #expect(translated.rflags == initialFlags)
            #expect(translated.registers.r9 & ~UInt64(0xFF) == 0x1122_3344_5566_7700)
          }
        }
      }
    #endif
  }

  @Test func nativeTranslationSpansMeasuredKernelSetConditionSlice() throws {
    let bytes: [UInt8] = [
      0x45, 0x31, 0xC9,  // xor r9d,r9d
      0x85, 0xF6,  // test esi,esi
      0x41, 0x0F, 0x94, 0xC1,  // sete r9b
      0x3C, 0x01,  // cmp al,1
      0x0F, 0x84, 0x00, 0x0C, 0x00, 0x00,  // je 0x12e43c5b1
    ]
    let block = try DoryX86IRTranslator().translate(
      bytes,
      at: 0x12E4_3B9A0,
      mode: .long64
    )

    #expect(block.guestInstructionCount == 5)
    #expect(block.guestByteCount == bytes.count)
    #expect(block.statements.count == 4)
    #expect(
      block.statements.contains {
        if case .setCondition(.equal, _) = $0 { return true }
        return false
      })
    for tier in [DoryARM64CompilationTier.baseline, .optimizing] {
      let candidate =
        tier == .optimizing
        ? DoryIROptimizer().optimize(block).block
        : block
      #expect(DoryARM64BaselineEmitter().compile(candidate, tier: tier).tier == tier)
    }
  }

  @Test func setConditionCoverageExcludesHighByteMemoryAndInvalidIRDestinations() throws {
    let excluded: [[UInt8]] = [
      [0x0F, 0x94, 0xC4],  // sete ah
      [0x0F, 0x94, 0x00],  // sete byte ptr [rax]
    ]
    for bytes in excluded {
      let block = try DoryX86IRTranslator().translate(bytes, at: 0, mode: .long64)
      #expect(DoryARM64BaselineEmitter().compile(block).tier == .interpreterFallback)
    }

    let crafted = DoryIRBasicBlock(
      guestStart: 0,
      guestByteCount: 1,
      guestInstructionCount: 1,
      statements: [
        .setCondition(
          .equal,
          destination: .register(.init(bank: "not.x86.gpr", index: 0, width: .i8))
        )
      ],
      terminator: .next(1)
    )
    #expect(DoryARM64BaselineEmitter().compile(crafted).tier == .interpreterFallback)
  }

  @Test func reverseBitScan32MatchesInterpreterAcrossZeroWidthAndAliasCases() throws {
    #if arch(arm64)
      let preservedFlags: DoryX86RFLAGS = [
        .reservedOne, .carry, .parity, .auxiliaryCarry, .sign, .direction, .interruptEnable,
        .overflow,
      ]
      let initialFlagCases = [preservedFlags, preservedFlags.union(.zero)]
      let values: [UInt64] = [0, 1, 2, 0x00F0_0000, 0x8000_0000, 0xFFFF_FFFF]

      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let executor = try DoryARM64BaselineExecutor(
          maximumCodeBytes: 16 * 1024,
          optimization: optimization
        )
        for flags in initialFlagCases {
          for value in values {
            let bytes: [UInt8] = [0x0F, 0xBD, 0xC8]  // bsr ecx,eax
            let registers = DoryX86GeneralRegisters(
              rax: value,
              rcx: 0xAABB_CCDD_EEFF_0011
            )
            var interpreted = try DoryX86ArchitecturalState(
              registers: registers,
              rip: 0,
              rflags: flags
            )
            _ = DoryX86Interpreter().step(
              state: &interpreted,
              memory: try DoryX86ByteArrayMemory(bytes: bytes),
              mode: .long64
            )

            var translated = try DoryX86ArchitecturalState(
              registers: registers,
              rip: 0,
              rflags: flags
            )
            let execution = try #require(
              executor.execute(
                bytes: bytes,
                at: 0,
                mode: .long64,
                addressSpaceID: 0,
                maximumInstructions: 1,
                state: &translated
              )
            )

            #expect(execution.block.tier.rawValue == optimization.rawValue)
            #expect(translated == interpreted)
            #expect(translated.rflags.subtracting(.zero) == preservedFlags)
            if value == 0 {
              #expect(translated.registers.rcx == registers.rcx)
              #expect(translated.rflags.contains(.zero))
            } else {
              #expect(translated.registers.rcx <= 31)
              #expect(!translated.rflags.contains(.zero))
            }
          }

          for value in [UInt64(0), 1, 0x8000_0000] {
            let bytes: [UInt8] = [0x0F, 0xBD, 0xC0]  // bsr eax,eax
            let registers = DoryX86GeneralRegisters(rax: 0xAABB_CCDD_0000_0000 | value)
            var interpreted = try DoryX86ArchitecturalState(
              registers: registers,
              rip: 0,
              rflags: flags
            )
            _ = DoryX86Interpreter().step(
              state: &interpreted,
              memory: try DoryX86ByteArrayMemory(bytes: bytes),
              mode: .long64
            )

            var translated = try DoryX86ArchitecturalState(
              registers: registers,
              rip: 0,
              rflags: flags
            )
            let execution = try #require(
              executor.execute(
                bytes: bytes,
                at: 0,
                mode: .long64,
                addressSpaceID: 0,
                maximumInstructions: 1,
                state: &translated
              )
            )
            #expect(execution.block.tier.rawValue == optimization.rawValue)
            #expect(translated == interpreted)
          }
        }
      }
    #endif
  }

  @Test func forwardBitScanRegistersMatchInterpreterForMeasuredPrefixAndAliases() throws {
    #if arch(arm64)
      struct Case {
        let bytes: [UInt8]
        let registerValues: DoryX86GeneralRegisters
      }
      let values = [UInt64(0), UInt64.max] + (0..<64).map { UInt64(1) << $0 }
      let flags: DoryX86RFLAGS = [.reservedOne, .zero, .carry, .parity, .auxiliaryCarry,
        .sign, .overflow, .direction, .interruptEnable]
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let executor = try DoryARM64BaselineExecutor(
          maximumCodeBytes: 16 * 1024, optimization: optimization)
        var addressSpaceID = UInt64(optimization == .baseline ? 0x1_0000 : 0x2_0000)
        for value in values {
          let cases: [Case] = [
            .init(
              bytes: [0xF3, 0x48, 0x0F, 0xBC, 0xDB],  // rep bsf rbx,rbx: measured kernel bytes under compat-v1
              registerValues: .init(rbx: value)
            ),
            .init(
              bytes: [0x48, 0x0F, 0xBC, 0xD2],  // bsf rdx,rdx
              registerValues: .init(rdx: value)
            ),
            .init(
              bytes: [0x48, 0x0F, 0xBC, 0xC0],  // bsf rax,rax
              registerValues: .init(rax: value)
            ),
            .init(
              bytes: [0x49, 0x0F, 0xBC, 0xCC],  // bsf rcx,r12
              registerValues: .init(rcx: 0xABCD_EF00_1234_5678, r12: value)
            ),
            .init(
              bytes: [0x0F, 0xBC, 0xCB],  // bsf ecx,ebx zero-extends on nonzero and preserves full RCX on zero
              registerValues: .init(rcx: 0xABCD_EF00_1234_5678, rbx: value)
            ),
          ]
          for testCase in cases {
            let initial = try DoryX86ArchitecturalState(
              registers: testCase.registerValues, rip: 0, rflags: flags)
            var interpreted = initial
            guard case .retired = DoryX86Interpreter().step(
              state: &interpreted, memory: try DoryX86ByteArrayMemory(bytes: testCase.bytes),
              mode: .long64)
            else {
              Issue.record("BSF reference execution did not retire")
              continue
            }
            var translated = initial
            addressSpaceID &+= 1
            let execution = try #require(try executor.execute(
              bytes: testCase.bytes, at: 0, mode: .long64, addressSpaceID: addressSpaceID,
              maximumInstructions: 1, state: &translated))
            #expect(execution.block.tier.rawValue == optimization.rawValue)
            #expect(translated == interpreted)
          }
        }
      }
    #endif
  }

  @Test func reverseBitScan64MatchesInterpreterForEveryBitAndAliasedRegisters() throws {
    #if arch(arm64)
      let values = [UInt64(0), UInt64.max] + (0..<64).map { UInt64(1) << $0 }
      let flags: DoryX86RFLAGS = [.reservedOne, .zero, .carry, .parity, .auxiliaryCarry,
        .sign, .overflow, .direction, .interruptEnable]
      let encodings: [[UInt8]] = [
        [0x48, 0x0F, 0xBD, 0xC8], // bsr rcx,rax
        [0x48, 0x0F, 0xBD, 0xC0], // bsr rax,rax
        [0x49, 0x0F, 0xBD, 0xDC], // bsr rbx,r12: measured kernel instruction
      ]
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let executor = try DoryARM64BaselineExecutor(
          maximumCodeBytes: 16 * 1024, optimization: optimization)
        for bytes in encodings {
          for value in values {
            let initial = try DoryX86ArchitecturalState(
              registers: .init(rax: value, rcx: 0xFFFF_1234_5678_0000,
                rbx: 0xABCD_EF00_1234_5678, r12: value),
              rip: 0, rflags: flags)
            var interpreted = initial
            guard case .retired = DoryX86Interpreter().step(
              state: &interpreted, memory: try DoryX86ByteArrayMemory(bytes: bytes), mode: .long64)
            else {
              Issue.record("BSR64 reference execution did not retire")
              continue
            }
            var translated = initial
            let execution = try #require(executor.execute(
              bytes: bytes, at: 0, mode: .long64, addressSpaceID: 0,
              maximumInstructions: 1, state: &translated))
            #expect(execution.block.tier.rawValue == optimization.rawValue)
            #expect(translated == interpreted)
          }
        }
      }
    #endif
  }

  @Test func bitScanMemorySourcesMatchInterpreterAcrossTiers() throws {
    #if arch(arm64)
      struct Case {
        let bytes: [UInt8]
        let rip: UInt64
        let registers: DoryX86GeneralRegisters
        let address: UInt64
        let byteCount: Int
      }
      let cases: [Case] = [
        .init(
          bytes: [0x4C, 0x0F, 0xBD, 0x35, 0x78, 0x00, 0x00, 0x00],
          rip: 0x1000,
          registers: .init(r14: 0xFACE_B00C_1234_5678),
          address: 0x1080,
          byteCount: 8
        ),
        .init(
          bytes: [0x0F, 0xBC, 0x08],  // bsf ecx,dword ptr [rax]
          rip: 0,
          registers: .init(rax: 0x80, rcx: 0xABCD_EF00_1234_5678),
          address: 0x80,
          byteCount: 4
        ),
        .init(
          bytes: [0x48, 0x0F, 0xBD, 0x00],  // bsr rax,qword ptr [rax]: address/destination alias
          rip: 0,
          registers: .init(rax: 0x88),
          address: 0x88,
          byteCount: 8
        ),
      ]
      let values = [UInt64(0), 1, 2, 0x8000_0000, 0x8000_0000_0000_0000, UInt64.max]
      let flags: DoryX86RFLAGS = [
        .reservedOne, .carry, .parity, .auxiliaryCarry, .sign, .direction, .interruptEnable,
        .overflow,
      ]
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let executor = try DoryARM64BaselineExecutor(
          maximumCodeBytes: 16 * 1024,
          optimization: optimization
        )
        var addressSpaceID = UInt64(optimization == .baseline ? 0x5000 : 0x6000)
        for testCase in cases {
          for value in values {
            let maskedValue = testCase.byteCount == 4 ? value & 0xFFFF_FFFF : value
            let interpretedMemory = try DoryX86ByteArrayMemory(byteCount: 0x1200)
            let translatedMemory = try DoryX86ByteArrayMemory(byteCount: 0x1200)
            for memory in [interpretedMemory, translatedMemory] {
              try memory.write(at: testCase.rip, bytes: testCase.bytes)
              try memory.writeScalar(at: testCase.address, value: maskedValue, byteCount: testCase.byteCount)
            }
            let initial = try DoryX86ArchitecturalState(
              registers: testCase.registers,
              rip: testCase.rip,
              rflags: flags
            )
            var interpreted = initial
            let decoded = try DoryX86Decoder().decode(
              testCase.bytes, at: testCase.rip, mode: .long64)
            #expect(DoryX86Interpreter().step(
              state: &interpreted,
              memory: interpretedMemory,
              mode: .long64
            ) == .retired(decoded))

            var translated = initial
            addressSpaceID &+= 1
            let execution = try #require(executor.execute(
              bytes: testCase.bytes,
              at: testCase.rip,
              mode: .long64,
              addressSpaceID: addressSpaceID,
              maximumInstructions: 1,
              state: &translated,
              memory: translatedMemory
            ))
            #expect(execution.block.tier.rawValue == optimization.rawValue)
            #expect(execution.block.requiresMemoryCallbacks)
            #expect(translated == interpreted)
            #expect(try translatedMemory.read(at: 0, byteCount: 0x1200)
              == interpretedMemory.read(at: 0, byteCount: 0x1200))
          }
        }
      }
    #endif
  }

  @Test func bitScanMemorySourceFaultLeavesArchitecturalStateRestartable() throws {
    #if arch(arm64)
      let bytes: [UInt8] = [0x48, 0x0F, 0xBD, 0x00]  // bsr rax,qword ptr [rax]
      let initial = try DoryX86ArchitecturalState(
        registers: .init(rax: 0x80, r14: 0x1234_5678_9ABC_DEF0),
        rip: 0,
        rflags: [.reservedOne, .carry, .direction, .overflow]
      )
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let memory = try DoryX86ByteArrayMemory(byteCount: 0x40)
        try memory.write(at: 0, bytes: bytes)
        var state = initial
        let execution = try #require(DoryARM64BaselineExecutor(
          maximumCodeBytes: 4096,
          optimization: optimization
        ).execute(
          bytes: bytes,
          at: 0,
          mode: .long64,
          addressSpaceID: UInt64(0x7000 + (optimization == .baseline ? 0 : 1)),
          maximumInstructions: 1,
          state: &state,
          memory: memory
        ))
        #expect(execution.block.tier.rawValue == optimization.rawValue)
        #expect(execution.block.requiresMemoryCallbacks)
        #expect(execution.exitCode == .interpreter)
        #expect(state == initial)
      }
    #endif
  }

  @Test func nativeTranslationSpansMeasuredKernelReverseBitScanSlice() throws {
    let bytes: [UInt8] = [
      0x8B, 0x7E, 0x04,  // mov edi,[rsi+4]
      0x41, 0x0F, 0xB7, 0x04, 0x79,  // movzx eax,word ptr [r9+rdi*2]
      0x0F, 0xBD, 0xC8,  // bsr ecx,eax
      0x44, 0x8D, 0x58, 0x01,  // lea r11d,[rax+1]
      0x48, 0x83, 0xC6, 0x08,  // add rsi,8
      0x83, 0xF1, 0x1F,  // xor ecx,31
      0x66, 0x45, 0x89, 0x1C, 0x79,  // mov word ptr [r9+rdi*2],r11w
    ]
    let block = try DoryX86IRTranslator().translate(
      bytes,
      at: 0x12E4_23200,
      mode: .long64
    )

    #expect(block.guestInstructionCount == 7)
    #expect(block.guestByteCount == bytes.count)
    #expect(block.terminator == .next(0x12E4_2321B))
    #expect(
      block.statements.contains {
        if case .bitScan(reverse: true, _, _) = $0 { return true }
        return false
      })
    for tier in [DoryARM64CompilationTier.baseline, .optimizing] {
      let candidate =
        tier == .optimizing
        ? DoryIROptimizer().optimize(block).block
        : block
      let compiled = DoryARM64BaselineEmitter().compile(candidate, tier: tier)
      #expect(compiled.tier == tier)
      #expect(compiled.requiresRestartableMemoryReads)
    }
  }

  @Test func bitScanCoverageExcludes16BitFormsAndInvalidRegisters() throws {
    let excluded: [[UInt8]] = [
      [0x66, 0x0F, 0xBC, 0xC8],  // bsf cx,ax
      [0x66, 0x0F, 0xBD, 0xC8],  // bsr cx,ax
    ]
    for bytes in excluded {
      let block = try DoryX86IRTranslator().translate(bytes, at: 0, mode: .long64)
      #expect(DoryARM64BaselineEmitter().compile(block).tier == .interpreterFallback)
    }

    let valid = DoryIRRegister(bank: "x86.gpr", index: 0, width: .i32)
    let invalid = DoryIRRegister(bank: "not.x86.gpr", index: 0, width: .i32)
    let crafted = DoryIRBasicBlock(
      guestStart: 0,
      guestByteCount: 1,
      guestInstructionCount: 1,
      statements: [
        .bitScan(
          reverse: true,
          destination: .register(invalid),
          source: .register(valid)
        )
      ],
      terminator: .next(1)
    )
    #expect(DoryARM64BaselineEmitter().compile(crafted).tier == .interpreterFallback)
  }

  @Test func clShiftsMatchInterpreterResultsAndFlags() throws {
    #if arch(arm64)
      let instructions: [([UInt8], DoryX86GeneralRegister)] = [
        ([0x49, 0xD3, 0xE1], .r9),  // shl r9,cl
        ([0x49, 0xD3, 0xE9], .r9),  // shr r9,cl
        ([0x48, 0xD3, 0xF8], .rax),  // sar rax,cl
        ([0xD3, 0xE0], .rax),  // shl eax,cl
        ([0xD3, 0xE8], .rax),  // shr eax,cl
        ([0xD3, 0xF8], .rax),  // sar eax,cl
      ]
      let counts: [UInt64] = [0, 1, 31, 32, 63, 64, 255]
      let values: [UInt64] = [
        0,
        1,
        0x8000_0000_0000_0001,
        0xF123_4567_89AB_CDEF,
      ]
      let initialFlags = [
        DoryX86RFLAGS.reservedOne,
        DoryX86RFLAGS(
          rawValue: DoryX86RFLAGS.reservedOne.rawValue
            | DoryX86RFLAGS.carry.rawValue
            | DoryX86RFLAGS.auxiliaryCarry.rawValue
            | DoryX86RFLAGS.overflow.rawValue
        ),
        DoryX86RFLAGS(
          rawValue: DoryX86RFLAGS.reservedOne.rawValue
            | DoryX86RFLAGS.parity.rawValue
            | DoryX86RFLAGS.zero.rawValue
            | DoryX86RFLAGS.sign.rawValue
        ),
      ]

      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        for (bytes, target) in instructions {
          let executor = try DoryARM64BaselineExecutor(
            maximumCodeBytes: 4096,
            optimization: optimization
          )
          for count in counts {
            for value in values {
              for flags in initialFlags {
                var registers = DoryX86GeneralRegisters(rcx: count)
                registers[target] = value
                var interpreted = try DoryX86ArchitecturalState(
                  registers: registers,
                  rip: 0,
                  rflags: flags
                )
                let memory = try DoryX86ByteArrayMemory(bytes: bytes)
                _ = DoryX86Interpreter().step(
                  state: &interpreted,
                  memory: memory,
                  mode: .long64
                )

                var translated = try DoryX86ArchitecturalState(
                  registers: registers,
                  rip: 0,
                  rflags: flags
                )
                let execution = try #require(
                  executor.execute(
                    bytes: bytes,
                    at: 0,
                    mode: .long64,
                    addressSpaceID: 0,
                    maximumInstructions: 1,
                    state: &translated
                  )
                )

                #expect(execution.block.tier.rawValue == optimization.rawValue)
                #expect(execution.block.guestInstructionCount == 1)
                #expect(translated == interpreted)
              }
            }
          }
        }
      }
    #endif
  }

  @Test func nativeTranslationSpansTheKernelCLShiftPair() throws {
    let bytes: [UInt8] = [
      0x49, 0xC7, 0xC7, 0xFF, 0xFF, 0xFF, 0xFF,  // mov r15,-1
      0x89, 0xF9,  // mov ecx,edi
      0x49, 0x89, 0xD1,  // mov r9,rdx
      0x01, 0xF8,  // add eax,edi
      0x48, 0x89, 0xD7,  // mov rdi,rdx
      0xF7, 0xD9,  // neg ecx
      0x49, 0xD3, 0xE9,  // shr r9,cl
      0x44, 0x89, 0xF1,  // mov ecx,r14d
      0x49, 0xD3, 0xE7,  // shl r15,cl
      0x4C, 0x89, 0xF9,  // mov rcx,r15
      0x49, 0xC7, 0xC7, 0xFF, 0xFF, 0xFF, 0xFF,  // mov r15,-1
      0x48, 0xF7, 0xD1,  // not rcx
      0x4C, 0x21, 0xC9,  // and rcx,r9
      0x4C, 0x01, 0xD1,  // add rcx,r10
      0x48, 0x89, 0x8C, 0x24, 0xF8, 0x00, 0x00, 0x00,  // mov [rsp+0xf8],rcx
    ]
    let block = try DoryX86IRTranslator().translate(bytes, at: 0x12E4_3B45C, mode: .long64)
    let compiled = DoryARM64BaselineEmitter().compile(block)

    #expect(block.guestInstructionCount == 15)
    #expect(block.guestByteCount == bytes.count)
    #expect(compiled.tier == .baseline)
  }

  @Test func lowByteFlagsOnlyHotInstructionsMatchInterpreterAcrossTiers() throws {
    #if arch(arm64)
      let instructions: [([UInt8], DoryX86GeneralRegister)] = [
        ([0x3C, 0x01], .rax),  // cmp al,1
        ([0x40, 0x84, 0xFF], .rdi),  // test dil,dil
        ([0x41, 0x80, 0xF8, 0x1E], .r8),  // cmp r8b,0x1e
        ([0x84, 0xD2], .rdx),  // test dl,dl
      ]
      let values: [UInt64] = [0, 1, 3, 0x0F, 0x10, 0x1E, 0x7F, 0x80, 0xFF]
      let initialFlags: [DoryX86RFLAGS] = [
        .reservedOne,
        [
          .reservedOne, .carry, .parity, .auxiliaryCarry, .zero, .sign, .overflow,
          .interruptEnable, .direction, .identification,
        ],
      ]
      let arithmeticFlags: DoryX86RFLAGS = [
        .carry, .parity, .auxiliaryCarry, .zero, .sign, .overflow,
      ]
      var observedArithmeticFlags: DoryX86RFLAGS = []

      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        for (bytes, target) in instructions {
          let executor = try DoryARM64BaselineExecutor(
            maximumCodeBytes: 4096,
            optimization: optimization
          )
          for value in values {
            for flags in initialFlags {
              var registers = DoryX86GeneralRegisters(
                rax: 0x1100_0000_0000_0000,
                rcx: 0x2200_0000_0000_0002,
                rdx: 0x3300_0000_0000_0003,
                rbx: 0x4400_0000_0000_0004,
                rsp: 0x0000_0000_0000_1000,
                rbp: 0x6600_0000_0000_0006,
                rsi: 0x7700_0000_0000_0007,
                rdi: 0x0800_0000_0000_0008,
                r8: 0x0900_0000_0000_0009,
                r9: 0x0A00_0000_0000_000A,
                r10: 0x0B00_0000_0000_000B,
                r11: 0x0C00_0000_0000_000C,
                r12: 0x0D00_0000_0000_000D,
                r13: 0x0E00_0000_0000_000E,
                r14: 0x0F00_0000_0000_000F,
                r15: 0x1000_0000_0000_0010
              )
              registers[target] = registers[target] & ~UInt64(0xFF) | value
              var interpreted = try DoryX86ArchitecturalState(
                registers: registers,
                rip: 0,
                rflags: flags
              )
              _ = DoryX86Interpreter().step(
                state: &interpreted,
                memory: try DoryX86ByteArrayMemory(bytes: bytes),
                mode: .long64
              )

              var translated = try DoryX86ArchitecturalState(
                registers: registers,
                rip: 0,
                rflags: flags
              )
              let execution = try #require(
                executor.execute(
                  bytes: bytes,
                  at: 0,
                  mode: .long64,
                  addressSpaceID: 0,
                  maximumInstructions: 1,
                  state: &translated
                )
              )

              #expect(execution.block.tier.rawValue == optimization.rawValue)
              #expect(execution.block.guestInstructionCount == 1)
              #expect(translated.registers == registers)
              #expect(translated == interpreted)
              observedArithmeticFlags.formUnion(interpreted.rflags.intersection(arithmeticFlags))
            }
          }
          #expect(executor.diagnostics.declinedCompilations == 0)
          #expect(executor.diagnostics.negativeCacheHits == 0)
        }
      }
      #expect(observedArithmeticFlags == arithmeticFlags)
    #endif
  }

  @Test func lowByteCompareAndFollowingBranchExecuteNativelyTakenAndNotTaken() throws {
    #if arch(arm64)
      let bytes: [UInt8] = [0x3C, 0x01, 0x76, 0x02, 0x90, 0x90]  // cmp al,1; jbe +2
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let executor = try DoryARM64BaselineExecutor(
          maximumCodeBytes: 4096,
          optimization: optimization
        )
        for value in [UInt64(0), 2] {
          let registers = DoryX86GeneralRegisters(
            rax: 0xCAFE_BABE_0000_0000 | value,
            rcx: 0x1111,
            rdx: 0x2222,
            rbx: 0x3333,
            rsp: 0x1000,
            rbp: 0x4444,
            rsi: 0x5555,
            rdi: 0x6666,
            r8: 0x7777,
            r9: 0x8888,
            r10: 0x9999,
            r11: 0xAAAA,
            r12: 0xBBBB,
            r13: 0xCCCC,
            r14: 0xDDDD,
            r15: 0xEEEE
          )
          var interpreted = try DoryX86ArchitecturalState(
            registers: registers,
            rip: 0,
            rflags: [.reservedOne, .interruptEnable, .direction]
          )
          let memory = try DoryX86ByteArrayMemory(bytes: bytes)
          _ = DoryX86Interpreter().step(state: &interpreted, memory: memory, mode: .long64)
          _ = DoryX86Interpreter().step(state: &interpreted, memory: memory, mode: .long64)

          var translated = try DoryX86ArchitecturalState(
            registers: registers,
            rip: 0,
            rflags: [.reservedOne, .interruptEnable, .direction]
          )
          let execution = try #require(
            executor.execute(
              bytes: bytes,
              at: 0,
              mode: .long64,
              addressSpaceID: 0,
              maximumInstructions: 2,
              state: &translated
            )
          )

          #expect(execution.block.tier.rawValue == optimization.rawValue)
          #expect(execution.block.guestInstructionCount == 2)
          #expect(translated.registers == registers)
          #expect(translated == interpreted)
          #expect(translated.rip == (value == 0 ? 6 : 4))
        }
        #expect(executor.diagnostics.declinedCompilations == 0)
      }
    #endif
  }

  @Test func nativeConditionalMovesHonorEveryConditionAndPreserveFlagsAcrossTiers() throws {
    #if arch(arm64)
      let conditionFlags: [(DoryX86RFLAGS, DoryX86RFLAGS)] = [
        ([.overflow], []),
        ([], [.overflow]),
        ([.carry], []),
        ([], [.carry]),
        ([.zero], []),
        ([], [.zero]),
        ([.carry], []),
        ([], [.carry]),
        ([.sign], []),
        ([], [.sign]),
        ([.parity], []),
        ([], [.parity]),
        ([.sign], []),
        ([], [.sign]),
        ([.zero], []),
        ([], [.zero]),
      ]
      // TF is handled by the interpreter at the machine boundary, outside native execution.
      let preservedFlags: DoryX86RFLAGS = [
        .reservedOne, .interruptEnable, .direction, .identification,
      ]

      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        for rawCondition in UInt8(0)..<UInt8(16) {
          for (isTrue, conditionFlags) in [
            (true, conditionFlags[Int(rawCondition)].0),
            (false, conditionFlags[Int(rawCondition)].1),
          ] {
            let bytes: [UInt8] = [0x48, 0x0F, 0x40 | rawCondition, 0xC3]
            let initialFlags = preservedFlags.union(conditionFlags)
            let registers = DoryX86GeneralRegisters(
              rax: 0x1111_2222_3333_4444,
              rcx: 0x5555_6666_7777_8888,
              rdx: 0x9999_AAAA_BBBB_CCCC,
              rbx: 0xDEAD_BEEF_CAFE_BABE,
              rsp: 0x1000,
              rbp: 0x1010,
              rsi: 0x2020,
              rdi: 0x3030,
              r8: 0x4040,
              r9: 0x5050,
              r10: 0x6060,
              r11: 0x7070,
              r12: 0x8080,
              r13: 0x9090,
              r14: 0xA0A0,
              r15: 0xB0B0
            )
            var interpreted = try DoryX86ArchitecturalState(
              registers: registers, rip: 0, rflags: initialFlags)
            guard
              case .retired = DoryX86Interpreter().step(
                state: &interpreted,
                memory: try DoryX86ByteArrayMemory(bytes: bytes),
                mode: .long64
              )
            else {
              Issue.record("reference CMOV unexpectedly faulted")
              return
            }
            var state = try DoryX86ArchitecturalState(
              registers: registers, rip: 0, rflags: initialFlags)
            let executor = try DoryARM64BaselineExecutor(
              maximumCodeBytes: 4096, optimization: optimization)

            let execution = try #require(
              executor.execute(
                bytes: bytes,
                at: 0,
                mode: .long64,
                addressSpaceID: UInt64(rawCondition),
                maximumInstructions: 1,
                state: &state
              ))

            #expect(execution.block.tier.rawValue == optimization.rawValue)
            #expect(state.registers.rax == (isTrue ? registers.rbx : registers.rax))
            #expect(state.registers == interpreted.registers)
            #expect(state.rflags == initialFlags)
            #expect(state == interpreted)
            #expect(executor.diagnostics.declinedCompilations == 0)
          }
        }
      }
    #endif
  }

  @Test func hotConditionalMovePairExecutesNativelyWithExactRegisterWidths() throws {
    #if arch(arm64)
      let bytes: [UInt8] = [
        0x41, 0x0F, 0x42, 0xF9,  // cmovb edi,r9d
        0x48, 0x0F, 0x42, 0xCA,  // cmovb rcx,rdx
      ]
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        for carry in [false, true] {
          let registers = DoryX86GeneralRegisters(
            rcx: 0x1111_2222_3333_4444,
            rdx: 0x5555_6666_7777_8888,
            rdi: 0xFFFF_FFFF_1234_5678,
            r9: 0xAAAA_AAAA_DEAD_BEEF
          )
          var flags: DoryX86RFLAGS = [.reservedOne, .interruptEnable, .direction]
          if carry { flags.insert(.carry) }
          var interpreted = try DoryX86ArchitecturalState(
            registers: registers, rip: 0, rflags: flags)
          let referenceMemory = try DoryX86ByteArrayMemory(bytes: bytes)
          for _ in 0..<2 {
            guard
              case .retired = DoryX86Interpreter().step(
                state: &interpreted, memory: referenceMemory, mode: .long64)
            else {
              Issue.record("reference CMOV pair unexpectedly faulted")
              return
            }
          }
          var state = try DoryX86ArchitecturalState(
            registers: registers, rip: 0, rflags: flags)
          let executor = try DoryARM64BaselineExecutor(
            maximumCodeBytes: 4096, optimization: optimization)

          let execution = try #require(
            executor.execute(
              bytes: bytes,
              at: 0,
              mode: .long64,
              addressSpaceID: 0,
              maximumInstructions: 2,
              state: &state
            ))

          #expect(execution.block.tier.rawValue == optimization.rawValue)
          #expect(execution.block.guestInstructionCount == 2)
          #expect(state.registers.rdi == (carry ? 0xDEAD_BEEF : 0x1234_5678))
          #expect(state.registers.rcx == (carry ? registers.rdx : registers.rcx))
          #expect(state.registers == interpreted.registers)
          #expect(state.rflags == flags)
          #expect(state == interpreted)
          #expect(executor.diagnostics.declinedCompilations == 0)
        }
      }
    #endif
  }

  @Test func falseDoublewordSelfConditionalMoveStillZeroExtendsNatively() throws {
    #if arch(arm64)
      let bytes: [UInt8] = [0x0F, 0x42, 0xFF]  // cmovb edi,edi
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        var state = try DoryX86ArchitecturalState(
          registers: .init(rdi: 0xFFFF_FFFF_1234_5678),
          rip: 0,
          rflags: [.reservedOne, .interruptEnable]
        )
        let executor = try DoryARM64BaselineExecutor(
          maximumCodeBytes: 4096, optimization: optimization)

        let execution = try #require(
          executor.execute(
            bytes: bytes,
            at: 0,
            mode: .long64,
            addressSpaceID: 0,
            maximumInstructions: 1,
            state: &state
          ))

        #expect(execution.block.tier.rawValue == optimization.rawValue)
        #expect(state.registers.rdi == 0x1234_5678)
        #expect(state.rflags == [.reservedOne, .interruptEnable])
      }
    #endif
  }

  @Test func optimizerRetainsConditionalMoveAndInvalidatesItsDestination() throws {
    let bytes: [UInt8] = [
      0xBF, 0x01, 0x00, 0x00, 0x00,  // mov edi,1
      0x41, 0xB9, 0x02, 0x00, 0x00, 0x00,  // mov r9d,2
      0x41, 0x0F, 0x42, 0xF9,  // cmovb edi,r9d
      0x89, 0xF8,  // mov eax,edi
    ]
    let block = try DoryX86IRTranslator().translate(bytes, at: 0x4000, mode: .long64)
    let optimized = DoryIROptimizer().optimize(block).block

    guard
      case .conditionalMove(_, _, .register(let conditionalSource)) =
        optimized.statements[2],
      case .copy(_, .register(let consumerSource)) = optimized.statements[3]
    else {
      Issue.record("optimizer rewrote CMOV operands as unconditional constants")
      return
    }
    #expect(conditionalSource.index == 9)
    #expect(consumerSource.index == 7)
    #expect(DoryARM64BaselineEmitter().compile(optimized, tier: .optimizing).tier == .optimizing)
  }

  @Test func unsupportedByteOperandFormsRetainInterpreterFallback() throws {
    let excluded: [[UInt8]] = [
      [0x84, 0xE4],  // test ah,ah
      [0x00, 0xC0],  // add al,al
    ]
    for bytes in excluded {
      let block = try DoryX86IRTranslator().translate(bytes, at: 0, mode: .long64)
      #expect(DoryARM64BaselineEmitter().compile(block).tier == .interpreterFallback)
    }
  }

  @Test func measuredRegisterOnlyFirmwareSitesMatchInterpreterAcrossTiers() throws {
    #if arch(arm64)
      struct Case {
        let bytes: [UInt8]
        let registers: DoryX86GeneralRegisters
        let comment: String
        let check: (DoryX86ArchitecturalState) -> Void
      }
      let cases: [Case] = [
        .init(
          bytes: [0x48, 0x87, 0xCA],
          registers: .init(rcx: 0x1111_2222_3333_4444, rdx: 0xAAAA_BBBB_CCCC_DDDD),
          comment: "measured xchg rdx,rcx firmware hot site",
          check: { state in
            #expect(state.registers.rcx == 0xAAAA_BBBB_CCCC_DDDD)
            #expect(state.registers.rdx == 0x1111_2222_3333_4444)
          }
        ),
        .init(
          bytes: [0x49, 0x90],
          registers: .init(rax: 0x0102_0304_0506_0708, r8: 0x8877_6655_4433_2211),
          comment: "xchg rax,r8 short opcode with REX.B",
          check: { state in
            #expect(state.registers.rax == 0x8877_6655_4433_2211)
            #expect(state.registers.r8 == 0x0102_0304_0506_0708)
          }
        ),
        .init(
          bytes: [0x48, 0x87, 0xC0],
          registers: .init(rax: 0xCAFE_BABE_DEAD_BEEF),
          comment: "same-register xchg leaves state unchanged",
          check: { state in
            #expect(state.registers.rax == 0xCAFE_BABE_DEAD_BEEF)
          }
        ),
        .init(
          bytes: [0x48, 0x94],
          registers: .init(rax: 0x0102_0304_0506_0708, rsp: 0x8000),
          comment: "xchg rax,rsp updates RSP without stack memory access",
          check: { state in
            #expect(state.registers.rax == 0x8000)
            #expect(state.registers.rsp == 0x0102_0304_0506_0708)
          }
        ),
        .init(
          bytes: [0x48, 0x98],
          registers: .init(rax: 0x7777_7777_8000_0001, rdx: 0x1122_3344_5566_7788),
          comment: "measured cdqe firmware hot site sign-extends EAX into RAX",
          check: { state in
            #expect(state.registers.rax == 0xFFFF_FFFF_8000_0001)
            #expect(state.registers.rdx == 0x1122_3344_5566_7788)
          }
        ),
        .init(
          bytes: [0x48, 0x98],
          registers: .init(rax: 0xFFFF_FFFF_7FFF_FFFE),
          comment: "cdqe clears high half when EAX sign bit is clear",
          check: { state in
            #expect(state.registers.rax == 0x0000_0000_7FFF_FFFE)
          }
        ),
        .init(
          bytes: [0xF6, 0xD2],
          registers: .init(rdx: 0x1122_3344_5566_7780),
          comment: "measured not dl firmware hot site",
          check: { state in
            #expect(state.registers.rdx == 0x1122_3344_5566_777F)
          }
        ),
        .init(
          bytes: [0x41, 0xF6, 0xD0],
          registers: .init(r8: 0xAABB_CCDD_EEFF_000F),
          comment: "not r8b preserves upper bits",
          check: { state in
            #expect(state.registers.r8 == 0xAABB_CCDD_EEFF_00F0)
          }
        ),
      ]
      let initialFlags: [DoryX86RFLAGS] = [
        .reservedOne,
        [
          .reservedOne, .carry, .parity, .auxiliaryCarry, .zero, .sign, .overflow,
          .interruptEnable, .direction, .identification,
        ],
      ]

      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        for (caseIndex, testCase) in cases.enumerated() {
          for (flagIndex, flags) in initialFlags.enumerated() {
            var interpreted = try DoryX86ArchitecturalState(
              registers: testCase.registers,
              rip: 0,
              rflags: flags
            )
            let decoded = try DoryX86Decoder().decode(testCase.bytes, at: 0, mode: .long64)
            #expect(DoryX86Interpreter().step(
              state: &interpreted,
              memory: try DoryX86ByteArrayMemory(bytes: testCase.bytes),
              mode: .long64
            ) == .retired(decoded))

            var translated = try DoryX86ArchitecturalState(
              registers: testCase.registers,
              rip: 0,
              rflags: flags
            )
            let execution = try #require(
              DoryARM64BaselineExecutor(
                maximumCodeBytes: 16 * 1024,
                optimization: optimization
              ).execute(
                bytes: testCase.bytes,
                at: translated.rip,
                mode: .long64,
                addressSpaceID: UInt64(0x2C00 + caseIndex * 4 + flagIndex),
                maximumInstructions: 1,
                state: &translated
              )
            )

            #expect(execution.block.tier.rawValue == optimization.rawValue)
            #expect(execution.exitCode == .dispatch)
            #expect(!execution.block.requiresMemoryCallbacks)
            #expect(translated == interpreted)
            #expect(translated.rflags == flags)
            testCase.check(translated)
          }
        }
      }
    #endif
  }

  @Test func registerExchangeInvalidatesOptimizedConstantsForBothOutputs() throws {
    #if arch(arm64)
      let bytes: [UInt8] = [
        0x48, 0xB9, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11,  // mov rcx,0x1111...
        0x48, 0xBA, 0xDD, 0xDD, 0xCC, 0xCC, 0xBB, 0xBB, 0xAA, 0xAA,  // mov rdx,0xaaaabbbbccccdddd
        0x48, 0x87, 0xCA,  // xchg rdx,rcx
        0x48, 0x89, 0xC8,  // mov rax,rcx
        0x48, 0x89, 0xD3,  // mov rbx,rdx
      ]
      var interpreted = try DoryX86ArchitecturalState(rip: 0)
      let interpretedMemory = try DoryX86ByteArrayMemory(bytes: bytes)
      for _ in 0..<5 {
        guard case .retired = DoryX86Interpreter().step(
          state: &interpreted,
          memory: interpretedMemory,
          mode: .long64
        ) else { Issue.record("interpreter did not retire xchg optimizer regression flow"); return }
      }

      var translated = try DoryX86ArchitecturalState(rip: 0)
      let execution = try #require(DoryARM64BaselineExecutor(
        maximumCodeBytes: 16 * 1024,
        optimization: .optimizing
      ).execute(
        bytes: bytes,
        at: 0,
        mode: .long64,
        addressSpaceID: 0x2D80,
        maximumInstructions: 5,
        state: &translated
      ))

      #expect(execution.block.tier == .optimizing)
      #expect(execution.exitCode == .dispatch)
      #expect(translated == interpreted)
      #expect(translated.registers.rax == 0xAAAA_BBBB_CCCC_DDDD)
      #expect(translated.registers.rbx == 0x1111_1111_1111_1111)
    #endif
  }

  @Test func measuredRegisterOnlyFirmwareSitesKeepUnsupportedFormsBounded() throws {
    let unsupported: [[UInt8]] = [
      [0x48, 0x87, 0x08],  // xchg qword ptr [rax],rcx is implicitly locked memory exchange
      [0x87, 0xCA],  // 32-bit register exchange remains interpreter until explicitly qualified
      [0x98],  // cwde is distinct from measured REX.W cdqe
      [0xF6, 0x10],  // not byte ptr [rax] is a memory write
      [0xF6, 0xD4],  // not ah is a legacy high-byte write
    ]
    for (index, bytes) in unsupported.enumerated() {
      let block = try DoryX86IRTranslator().translate(bytes, at: UInt64(0x2D00 + index), mode: .long64)
      #expect(DoryARM64BaselineEmitter().compile(block).tier == .interpreterFallback)
    }
  }

  @Test func signExtendAccumulatorHighMatchesInterpreterAcrossTiers() throws {
    #if arch(arm64)
      struct SignExtendCase {
        let bytes: [UInt8]
        let raxValues: [UInt64]
      }
      let cases = [
        SignExtendCase(
          bytes: [0x99],  // cdq
          raxValues: [
            0, 1, 0x7fff_ffff, 0x8000_0000, 0xffff_ffff,
            0x8000_0000_0000_0000, 0xffff_ffff_8000_0000,
          ]
        ),
        SignExtendCase(
          bytes: [0x48, 0x99],  // cqo: measured post-init hot site
          raxValues: [0, 1, 0x7fff_ffff_ffff_ffff, 0x8000_0000_0000_0000, UInt64.max]
        ),
      ]
      let initialFlags: [DoryX86RFLAGS] = [
        .reservedOne,
        [.reservedOne, .carry, .parity, .auxiliaryCarry, .zero, .sign, .overflow, .direction],
      ]
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        for (caseIndex, testCase) in cases.enumerated() {
          for (valueIndex, rax) in testCase.raxValues.enumerated() {
            for (flagIndex, flags) in initialFlags.enumerated() {
              let registers = DoryX86GeneralRegisters(
                rax: rax,
                rdx: 0x1122_3344_5566_7788
              )
              var interpreted = try DoryX86ArchitecturalState(
                registers: registers,
                rip: 0,
                rflags: flags
              )
              let decoded = try DoryX86Decoder().decode(testCase.bytes, at: 0, mode: .long64)
              #expect(DoryX86Interpreter().step(
                state: &interpreted,
                memory: try DoryX86ByteArrayMemory(bytes: testCase.bytes),
                mode: .long64
              ) == .retired(decoded))

              var translated = try DoryX86ArchitecturalState(
                registers: registers,
                rip: 0,
                rflags: flags
              )
              let execution = try #require(
                DoryARM64BaselineExecutor(
                  maximumCodeBytes: 16 * 1024,
                  optimization: optimization
                ).execute(
                  bytes: testCase.bytes,
                  at: translated.rip,
                  mode: .long64,
                  addressSpaceID: UInt64(0x3400 + caseIndex * 0x100 + valueIndex * 4 + flagIndex),
                  maximumInstructions: 1,
                  state: &translated
                )
              )

              #expect(execution.block.tier.rawValue == optimization.rawValue)
              #expect(!execution.block.requiresMemoryCallbacks)
              #expect(translated == interpreted)
            }
          }
        }
      }

      let wordForm = try DoryX86IRTranslator().translate([0x66, 0x99], at: 0, mode: .long64)
      #expect(DoryARM64BaselineEmitter().compile(wordForm).tier == .interpreterFallback)

      let invalidWidth = DoryIRBasicBlock(
        guestStart: 0,
        guestByteCount: 1,
        guestInstructionCount: 1,
        statements: [.signExtendAccumulatorHigh(width: .i16)],
        terminator: .exit(.interpreter, resumeAt: 0)
      )
      #expect(DoryARM64BaselineEmitter().compile(invalidWidth).tier == .interpreterFallback)

      let optimizerFixtures: [([UInt8], UInt64)] = [
        (
          [
            0xBA, 0x88, 0x77, 0x66, 0x55,  // mov edx,0x55667788
            0xB8, 0x00, 0x00, 0x00, 0x80,  // mov eax,0x80000000
            0x99,  // cdq
            0x48, 0x89, 0xD0,  // mov rax,rdx
          ],
          0x0000_0000_ffff_ffff
        ),
        (
          [
            0x48, 0xBA, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11,  // mov rdx,0x1122...
            0x48, 0xB8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80,  // mov rax,Int64.min
            0x48, 0x99,  // cqo
            0x48, 0x89, 0xD0,  // mov rax,rdx
          ],
          UInt64.max
        ),
      ]
      for (fixtureIndex, fixture) in optimizerFixtures.enumerated() {
        var interpreted = try DoryX86ArchitecturalState(rip: 0)
        var translated = interpreted
        let memory = try DoryX86ByteArrayMemory(bytes: fixture.0)
        for _ in 0..<4 {
          guard case .retired = DoryX86Interpreter().step(
            state: &interpreted,
            memory: memory,
            mode: .long64
          ) else {
            Issue.record("interpreter failed optimized CDQ/CQO invalidation fixture")
            return
          }
        }
        let execution = try #require(
          DoryARM64BaselineExecutor(maximumCodeBytes: 16 * 1024, optimization: .optimizing).execute(
            bytes: fixture.0,
            at: translated.rip,
            mode: .long64,
            addressSpaceID: UInt64(0x3500 + fixtureIndex),
            maximumInstructions: 4,
            state: &translated
          )
        )
        #expect(execution.block.tier == .optimizing)
        #expect(execution.block.guestInstructionCount == 4)
        #expect(translated == interpreted)
        #expect(translated.registers.rax == fixture.1)
      }
    #endif
  }

  @Test func signedMultiplyRegisterAndMemorySourcesMatchInterpreterAcrossTiers() throws {
    #if arch(arm64)
      struct MultiplyCase {
        let bytes: [UInt8]
        let registers: DoryX86GeneralRegisters
        let memoryAddress: UInt64?
        let memoryValue: UInt64
        let memoryWidth: Int
        let comment: String
      }

      let cases = [
        MultiplyCase(
          bytes: [0x0F, 0xAF, 0xD8],  // imul ebx,eax
          registers: .init(rax: 3, rbx: 2),
          memoryAddress: nil,
          memoryValue: 0,
          memoryWidth: 0,
          comment: "existing register dword form"
        ),
        MultiplyCase(
          bytes: [0x0F, 0xAF, 0xD8],  // imul ebx,eax overflows signed 32-bit
          registers: .init(rax: 2, rbx: 0x7FFF_FFFF),
          memoryAddress: nil,
          memoryValue: 0,
          memoryWidth: 0,
          comment: "existing register dword overflow"
        ),
        MultiplyCase(
          bytes: [0x0F, 0xAF, 0xD8],  // imul ebx,eax with -1 * 2
          registers: .init(rax: 2, rbx: 0xFFFF_FFFF),
          memoryAddress: nil,
          memoryValue: 0,
          memoryWidth: 0,
          comment: "existing register dword sign extension"
        ),
        MultiplyCase(
          bytes: [0x48, 0x0F, 0xAF, 0x10],  // imul rdx,[rax]
          registers: .init(rax: 0x80, rdx: 7),
          memoryAddress: 0x80,
          memoryValue: 6,
          memoryWidth: 8,
          comment: "measured two-operand memory source"
        ),
        MultiplyCase(
          bytes: [0x48, 0x0F, 0xAF, 0x00],  // imul rax,[rax]
          registers: .init(rax: 0x80),
          memoryAddress: 0x80,
          memoryValue: UInt64(bitPattern: Int64(-3)),
          memoryWidth: 8,
          comment: "destination also supplies original effective address"
        ),
        MultiplyCase(
          bytes: [0x0F, 0xAF, 0x18],  // imul ebx,[rax]
          registers: .init(rax: 0x80, rbx: 0xFFFF_FFFE),
          memoryAddress: 0x80,
          memoryValue: 3,
          memoryWidth: 4,
          comment: "memory dword source zero-extends destination in long mode"
        ),
        MultiplyCase(
          bytes: [0x48, 0x0F, 0xAF, 0x10],  // imul rdx,[rax] overflows signed 64-bit
          registers: .init(rax: 0x80, rdx: 0x8000_0000_0000_0000),
          memoryAddress: 0x80,
          memoryValue: UInt64.max,
          memoryWidth: 8,
          comment: "memory qword source signed overflow"
        ),
        MultiplyCase(
          bytes: [0x48, 0x6B, 0x10, 0xFF],  // imul rdx,[rax],-1
          registers: .init(rax: 0x80, rdx: 0x1234),
          memoryAddress: 0x80,
          memoryValue: 9,
          memoryWidth: 8,
          comment: "negative imm8 memory form"
        ),
        MultiplyCase(
          bytes: [0x48, 0x69, 0x10, 0xFF, 0xFF, 0xFF, 0xFF],  // imul rdx,[rax],-1
          registers: .init(rax: 0x80, rdx: 0x1234),
          memoryAddress: 0x80,
          memoryValue: 9,
          memoryWidth: 8,
          comment: "negative imm32 memory form"
        ),
        MultiplyCase(
          bytes: [0x48, 0x69, 0x83, 0xC0, 0x00, 0x00, 0x00, 0x00, 0xCA, 0x9A, 0x3B],
          registers: .init(rbx: 0x80),
          memoryAddress: 0x140,
          memoryValue: UInt64(bitPattern: Int64(-37)),
          memoryWidth: 8,
          comment: "exact measured immediate memory form with signed imm32"
        ),
      ]

      let initialFlags = DoryX86RFLAGS(
        rawValue: DoryX86RFLAGS.reservedOne.rawValue
          | DoryX86RFLAGS.carry.rawValue
          | DoryX86RFLAGS.zero.rawValue
          | DoryX86RFLAGS.overflow.rawValue
          | DoryX86RFLAGS.direction.rawValue
      )
      for (optimizationIndex, optimization) in [DoryARM64JITOptimization.baseline, .optimizing].enumerated() {
        for (caseIndex, testCase) in cases.enumerated() {
          let interpretedMemory = try DoryX86ByteArrayMemory(byteCount: 0x200)
          let translatedMemory = try DoryX86ByteArrayMemory(byteCount: 0x200)
          for memory in [interpretedMemory, translatedMemory] {
            try memory.write(at: 0, bytes: testCase.bytes)
            if let address = testCase.memoryAddress {
              try memory.write(at: address, bytes: (0..<testCase.memoryWidth).map {
                UInt8(truncatingIfNeeded: testCase.memoryValue >> ($0 * 8))
              })
            }
          }

          var interpreted = try DoryX86ArchitecturalState(
            registers: testCase.registers, rip: 0, rflags: initialFlags)
          let decoded = try DoryX86Decoder().decode(testCase.bytes, at: 0, mode: .long64)
          #expect(DoryX86Interpreter().step(
            state: &interpreted, memory: interpretedMemory, mode: .long64) == .retired(decoded)
          )

          var translated = try DoryX86ArchitecturalState(
            registers: testCase.registers, rip: 0, rflags: initialFlags)
          let execution = try #require(
            DoryARM64BaselineExecutor(maximumCodeBytes: 16 * 1024, optimization: optimization).execute(
              bytes: testCase.bytes,
              at: 0,
              mode: .long64,
              addressSpaceID: UInt64(caseIndex) + (UInt64(optimizationIndex) << 32),
              maximumInstructions: 1,
              state: &translated,
              memory: translatedMemory
            )
          )

          #expect(execution.block.tier.rawValue == optimization.rawValue)
          #expect(execution.block.requiresMemoryCallbacks == (testCase.memoryAddress != nil))
          #expect(!execution.block.requiresRestartableMemoryReads)
          #expect(translated == interpreted)
          #expect(try translatedMemory.read(at: 0, byteCount: 0x200)
            == interpretedMemory.read(at: 0, byteCount: 0x200))
        }
      }
    #endif
  }

  @Test func signedMultiplyMemorySourceReadFaultLeavesStateRestartable() throws {
    #if arch(arm64)
      let cases: [[UInt8]] = [
        [0x48, 0x0F, 0xAF, 0x10],  // imul rdx,[rax]
        [0x48, 0x69, 0x83, 0xC0, 0x00, 0x00, 0x00, 0xCA, 0x9A, 0x3B, 0x00],
      ]
      for (optimizationIndex, optimization) in [DoryARM64JITOptimization.baseline, .optimizing].enumerated() {
        for (caseIndex, bytes) in cases.enumerated() {
          let memory = try DoryX86ByteArrayMemory(byteCount: 0x40)
          try memory.write(at: 0, bytes: bytes)
          let initial = try DoryX86ArchitecturalState(
            registers: .init(rax: 0x80, rdx: 0x1234, rbx: 0x80),
            rip: 0,
            rflags: [.reservedOne, .carry, .direction, .overflow]
          )
          var state = initial
          let execution = try #require(
            DoryARM64BaselineExecutor(maximumCodeBytes: 16 * 1024, optimization: optimization).execute(
              bytes: bytes,
              at: 0,
              mode: .long64,
              addressSpaceID: UInt64(caseIndex) + (UInt64(optimizationIndex) << 32),
              maximumInstructions: 1,
              state: &state,
              memory: memory
            ))

          #expect(execution.block.tier.rawValue == optimization.rawValue)
          #expect(execution.block.requiresMemoryCallbacks)
          #expect(!execution.block.requiresRestartableMemoryReads)
          #expect(execution.exitCode == .interpreter)
          #expect(state == initial)
        }
      }
    #endif
  }

  @Test func signedExtendMovesMatchInterpreterAtSignBoundaries() throws {
    #if arch(arm64)
      let cases: [([UInt8], UInt64)] = [
        ([0x0F, 0xBE, 0xD8], 0x80),  // movsx ebx,al
        ([0x0F, 0xBE, 0xD8], 0x7F),
        ([0x48, 0x0F, 0xBE, 0xD8], 0x80),  // movsx rbx,al
        ([0x0F, 0xBF, 0xD8], 0x8000),  // movsx ebx,ax
        ([0x48, 0x0F, 0xBF, 0xD8], 0x8000),
        ([0x48, 0x63, 0xFF], 0x8000_0000),  // movsxd rdi,edi; observed Linux hot site
        ([0x48, 0x63, 0xFF], 0x7FFF_FFFF),
        ([0x0F, 0xBE, 0x18], 0x80),  // movsx ebx,byte [rax]
        ([0x48, 0x0F, 0xBE, 0x18], 0x80),
        ([0x0F, 0xBF, 0x18], 0x8000),
        ([0x48, 0x0F, 0xBF, 0x18], 0x8000),
        ([0x48, 0x63, 0x18], 0x8000_0000),
      ]
      for (bytes, value) in cases {
        let fromMemory = bytes.last == 0x18
        let memory = try DoryX86ByteArrayMemory(byteCount: 0x100)
        try memory.write(at: 0, bytes: bytes)
        try memory.write(at: 0x80, bytes: (0..<8).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        let initial = try DoryX86ArchitecturalState(
          registers: .init(rax: fromMemory ? 0x80 : value, rbx: .max, rdi: value),
          rip: 0,
          rflags: .init(rawValue: 0xAD7)
        )
        var interpreted = initial
        _ = DoryX86Interpreter().step(state: &interpreted, memory: memory, mode: .long64)
        var translated = initial
        let execution = try #require(
          DoryARM64BaselineExecutor(maximumCodeBytes: 4096).execute(
            bytes: bytes, at: 0, mode: .long64, addressSpaceID: 0,
            maximumInstructions: 1, state: &translated, memory: memory
          )
        )
        #expect(execution.block.tier == .baseline)
        #expect(translated == interpreted)
      }
    #endif
  }

  @Test func signedExtendMemoryFaultLeavesStateRestartable() throws {
    #if arch(arm64)
      let initial = try DoryX86ArchitecturalState(
        registers: .init(rax: 0x1000, rbx: 0xCAFE), rip: 0x3000)
      var state = initial
      let execution = try #require(
        DoryARM64BaselineExecutor(maximumCodeBytes: 4096).execute(
          bytes: [0x48, 0x0F, 0xBE, 0x18], at: state.rip,
          mode: .long64, addressSpaceID: 0, maximumInstructions: 1,
          state: &state, memory: DoryX86ByteArrayMemory(byteCount: 0x100)
        )
      )
      #expect(execution.block.tier == .baseline)
      #expect(execution.exitCode == .interpreter)
      #expect(state == initial)
    #endif
  }

  @Test func zeroExtendWordMemoryMatchesTheFirmwareHotInstruction() throws {
    #if arch(arm64)
      let bytes: [UInt8] = [0x46, 0x0F, 0xB7, 0x0C, 0x40]  // movzx r9d,[rax+r8*2]
      let memory = try DoryX86ByteArrayMemory(byteCount: 0x100)
      try memory.write(at: 0, bytes: bytes)
      try memory.write(at: 0x26, bytes: [0xCD, 0xAB])
      let initial = try DoryX86ArchitecturalState(
        registers: .init(rax: 0x20, r8: 3, r9: .max),
        rip: 0,
        rflags: .init(
          rawValue: DoryX86RFLAGS.reservedOne.rawValue | DoryX86RFLAGS.carry.rawValue)
      )
      var interpreted = initial
      _ = DoryX86Interpreter().step(state: &interpreted, memory: memory, mode: .long64)

      var translated = initial
      let execution = try #require(
        DoryARM64BaselineExecutor(maximumCodeBytes: 4096).execute(
          bytes: bytes,
          at: 0,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 1,
          state: &translated,
          memory: memory
        )
      )

      #expect(execution.block.tier == .baseline)
      #expect(execution.block.requiresMemoryCallbacks)
      #expect(translated.registers.r9 == interpreted.registers.r9)
      #expect(translated.rip == interpreted.rip)
      #expect(translated.rflags == interpreted.rflags)
    #endif
  }

  @Test func narrowStoreMatchesTheFirmwareDictionaryCopyInstruction() throws {
    #if arch(arm64)
      let bytes: [UInt8] = [0x44, 0x88, 0x06]  // mov [rsi],r8b
      let interpretedMemory = try DoryX86ByteArrayMemory(byteCount: 0x100)
      try interpretedMemory.write(at: 0, bytes: bytes)
      let initial = try DoryX86ArchitecturalState(
        registers: .init(rsi: 0x80, r8: 0x1234_5678_9ABC_DEFF), rip: 0)
      var interpreted = initial
      _ = DoryX86Interpreter().step(
        state: &interpreted, memory: interpretedMemory, mode: .long64)

      let translatedMemory = try DoryX86ByteArrayMemory(byteCount: 0x100)
      var translated = initial
      let execution = try #require(
        DoryARM64BaselineExecutor(maximumCodeBytes: 4096).execute(
          bytes: bytes,
          at: 0,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 1,
          state: &translated,
          memory: translatedMemory
        )
      )

      #expect(execution.block.tier == .baseline)
      #expect(try translatedMemory.read(at: 0x80, byteCount: 1) == [0xFF])
      #expect(
        try translatedMemory.read(at: 0x80, byteCount: 1)
          == interpretedMemory.read(at: 0x80, byteCount: 1))
      #expect(translated.rip == interpreted.rip)
      #expect(translated.rflags == interpreted.rflags)
    #endif
  }

  @Test func executorPerformsNativeMemoryALUAndReadModifyWrite() throws {
    #if arch(arm64)
      let memory = try DoryX86ByteArrayMemory(byteCount: 0x100)
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
      let memory = try DoryX86ByteArrayMemory(byteCount: 0x100)
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

  @Test func identicalCodeReusesPublishedHostBlockAcrossAddressSpaces() throws {
    #if arch(arm64)
      let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096)
      let program: [UInt8] = [0x48, 0xB8, 1, 0, 0, 0, 0, 0, 0, 0]
      var state = try DoryX86ArchitecturalState(rip: 0x9800)
      _ = try #require(
        executor.execute(
          bytes: program,
          at: 0x9800,
          mode: .long64,
          addressSpaceID: 1,
          maximumInstructions: 1,
          state: &state
        ))
      let publishedBytes = executor.residentByteCount

      state.rip = 0x9800
      _ = try #require(
        executor.execute(
          bytes: program,
          at: 0x9800,
          mode: .long64,
          addressSpaceID: 2,
          maximumInstructions: 1,
          state: &state
        ))

      #expect(executor.residentBlockCount == 2)
      #expect(executor.residentByteCount == publishedBytes)
      #expect(state.registers.rax == 1)
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

  @Test func nativeBatchReplaysGuardedCallbackFreeBlocksUntilTerminalExit() throws {
    #if arch(arm64)
      let emitter = DoryARM64BaselineEmitter()
      let first = emitter.compile(
        try DoryX86IRTranslator().translate(
          [0xB8, 1, 0, 0, 0, 0xEB, 0],
          at: 0x5000,
          mode: .long64
        ))
      let second = emitter.compile(
        try DoryX86IRTranslator().translate(
          [0xBB, 2, 0, 0, 0, 0xF4],
          at: 0x5007,
          mode: .long64
        ))
      #expect(!first.requiresMemoryCallbacks)
      #expect(!second.requiresMemoryCallbacks)
      let secondOffset = first.machineBytes.count
      let region = try DoryJITExecutableRegion(minimumCapacity: 4096)
      try region.publish(first, at: 0)
      try region.publish(second, at: secondOffset)
      var words = [UInt64](repeating: 0, count: DoryJITExecutableRegion.contextWordCount)
      words[16] = 0x5000

      let batch = try words.withUnsafeMutableBufferPointer { context in
        try region.executeBatch(
          offsets: [0, secondOffset],
          expectedGuestRIPs: [0x5000, 0x5007],
          guestInstructionCounts: [first.guestInstructionCount, second.guestInstructionCount],
          context: context
        )
      }

      #expect(batch.exitCode == .halt)
      #expect(batch.residentBlockCount == 2)
      #expect(batch.guestInstructionCount == 4)
      #expect(words[0] == 1)
      #expect(words[3] == 2)
      #expect(words[16] == 0x500D)

      words = [UInt64](repeating: 0, count: DoryJITExecutableRegion.contextWordCount)
      words[16] = 0x6000
      let divergent = try words.withUnsafeMutableBufferPointer { context in
        try region.executeBatch(
          offsets: [0, secondOffset],
          expectedGuestRIPs: [0x5000, 0x5007],
          guestInstructionCounts: [first.guestInstructionCount, second.guestInstructionCount],
          context: context
        )
      }
      #expect(divergent.exitCode == .dispatch)
      #expect(divergent.residentBlockCount == 0)
      #expect(divergent.guestInstructionCount == 0)
      #expect(words[16] == 0x6000)
    #endif
  }

  @Test func boundedExecutorReplacesChangedGuestCode() throws {
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
      #expect(executor.residentBlockCount == 1)
    #endif
  }

  @Test func cachedExecutionFetchesOnlyTheResidentGuestBytes() throws {
    #if arch(arm64)
      let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096)
      let program: [UInt8] = [0x48, 0xB8, 1, 0, 0, 0, 0, 0, 0, 0]
      var requestedCounts: [Int] = []
      var state = try DoryX86ArchitecturalState(rip: 0x6000)
      func execute() throws -> DoryARM64BaselineExecution? {
        try executor.execute(
          byteProvider: { count in
            requestedCounts.append(count)
            return Array(program.prefix(count))
          },
          at: 0x6000,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 1,
          state: &state
        )
      }

      _ = try #require(try execute())
      state.rip = 0x6000
      _ = try #require(try execute())

      #expect(requestedCounts == [15, program.count])
      #expect(executor.residentBlockCount == 1)
    #endif
  }

  @Test func residentCacheIdentityIgnoresTransientInstructionBudgets() throws {
    #if arch(arm64)
      let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096)
      let program: [UInt8] = [0x90, 0x90, 0x90, 0xF4]
      var state = try DoryX86ArchitecturalState(rip: 0x6800)

      let first = try #require(
        executor.execute(
          bytes: program,
          at: 0x6800,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 2,
          state: &state
        )
      )
      #expect(first.block.guestInstructionCount == 2)
      #expect(executor.residentBlockCount == 1)

      state.rip = 0x6800
      let reused = try #require(
        executor.execute(
          bytes: program,
          at: 0x6800,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 4,
          state: &state
        )
      )
      #expect(reused.block.guestInstructionCount == 2)
      #expect(state.rip == 0x6802)
      #expect(executor.residentBlockCount == 1)
    #endif
  }

  @Test func unchangedMemoryGenerationSkipsResidentCodeCopies() throws {
    #if arch(arm64)
      let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096)
      var program: [UInt8] = [0x48, 0xB8, 1, 0, 0, 0, 0, 0, 0, 0]
      var generation: UInt64 = 1
      var requestedCounts: [Int] = []
      var state = try DoryX86ArchitecturalState(rip: 0x7000)
      func execute() throws -> DoryARM64BaselineExecution? {
        try executor.execute(
          byteProvider: { count in
            requestedCounts.append(count)
            return Array(program.prefix(count))
          },
          codeGenerationProvider: { _ in generation },
          at: 0x7000,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 1,
          state: &state
        )
      }

      _ = try #require(try execute())
      state.rip = 0x7000
      _ = try #require(try execute())
      #expect(requestedCounts == [15])
      #expect(state.registers.rax == 1)

      program[2] = 2
      generation = 2
      state.rip = 0x7000
      _ = try #require(try execute())
      #expect(requestedCounts == [15, program.count, 15])
      #expect(state.registers.rax == 2)

      state.rip = 0x7000
      _ = try #require(try execute())
      #expect(requestedCounts == [15, program.count, 15])
      let diagnostics = executor.diagnostics
      #expect(diagnostics.recentLookupHits == 3)
      #expect(diagnostics.dictionaryLookupHits == 0)
      #expect(diagnostics.lookupMisses == 1)
      #expect(diagnostics.memoryGenerationHits == 2)
      #expect(diagnostics.byteValidationHits == 0)
      #expect(diagnostics.sharedCodeHits == 0)
      #expect(diagnostics.compiledBlocks == 2)
      #expect(diagnostics.declinedCompilations == 0)
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
  @Test func qwordCopyLoopUsesTheBoundedQuantumWithExactArchitecturalProgress() throws {
    #if arch(arm64)
      let base: UInt64 = 0x1000
      let source: UInt64 = 0x3000
      let destination: UInt64 = 0x5000
      let loop: [UInt8] = [
        0x48, 0x8b, 0x0c, 0x06, 0x48, 0x89, 0x0c, 0x07,
        0x48, 0x83, 0xc0, 0x08, 0x48, 0x89, 0xd1, 0x48,
        0x29, 0xc1, 0x48, 0x83, 0xf9, 0x07, 0x77, 0xe8,
      ]
      let payload = (0..<128).map(UInt8.init)
      let memory = try DoryX86ByteArrayMemory(byteCount: 0x8000)
      try memory.write(at: base, bytes: loop)
      try memory.write(at: source, bytes: payload)
      let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096)
      var state = try DoryX86ArchitecturalState(
        registers: .init(rax: 0, rcx: 0xffff, rdx: 128, rsi: source, rdi: destination),
        rip: base,
        rflags: [.reservedOne, .carry, .zero, .interruptEnable, .identification]
      )

      let summary = try #require(
        executor.executeChainedSummary(
          byteProvider: { address, count in
            try memory.instructionBytes(at: address, maximumCount: count)
          },
          at: base,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 64,
          state: &state,
          memory: memory
        ))

      #expect(summary.guestInstructionCount == 63)
      #expect(summary.residentBlockCount == 18)
      #expect(summary.exitCode == .dispatch)
      #expect(state.registers.rax == 72)
      #expect(state.registers.rcx == 56)
      #expect(state.registers.rdx == 128)
      #expect(state.registers.rsi == source)
      #expect(state.registers.rdi == destination)
      #expect(state.rip == base)
      #expect(state.rflags == [.reservedOne, .interruptEnable, .identification])
      #expect(try memory.read(at: destination, byteCount: 72) == Array(payload.prefix(72)))
      #expect(
        try memory.read(at: destination + 72, byteCount: 8)
          == [UInt8](repeating: 0, count: 8))
      #expect(executor.diagnostics.chainedRequestedInstructions == 64)
      #expect(executor.diagnostics.chainedRetiredInstructions == 63)
    #endif
  }

  @Test func qwordCopyLoopFallsThroughWithExactFinalCompareFlags() throws {
    #if arch(arm64)
      let base: UInt64 = 0x1800
      let source: UInt64 = 0x3000
      let destination: UInt64 = 0x4000
      let loop: [UInt8] = [
        0x48, 0x8b, 0x0c, 0x06, 0x48, 0x89, 0x0c, 0x07,
        0x48, 0x83, 0xc0, 0x08, 0x48, 0x89, 0xd1, 0x48,
        0x29, 0xc1, 0x48, 0x83, 0xf9, 0x07, 0x77, 0xe8,
      ]
      let memory = try DoryX86ByteArrayMemory(byteCount: 0x8000)
      try memory.write(at: base, bytes: loop)
      try memory.write(at: source, bytes: Array(0..<24))
      let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096)
      var state = try DoryX86ArchitecturalState(
        registers: .init(rax: 0, rdx: 24, rsi: source, rdi: destination),
        rip: base,
        rflags: [.reservedOne, .overflow, .zero, .interruptEnable]
      )

      let summary = try #require(
        executor.executeChainedSummary(
          byteProvider: { address, count in
            try memory.instructionBytes(at: address, maximumCount: count)
          },
          at: base,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 64,
          state: &state,
          memory: memory
        ))

      #expect(summary.guestInstructionCount == 21)
      #expect(state.registers.rax == 24)
      #expect(state.registers.rcx == 0)
      #expect(state.rip == base + UInt64(loop.count))
      #expect(
        state.rflags == [
          .reservedOne, .carry, .parity, .auxiliaryCarry, .sign, .interruptEnable,
        ])
      #expect(try memory.read(at: destination, byteCount: 24) == Array(0..<24))
    #endif
  }

  @Test func qwordCopyLoopDoesNotBulkCopyBelowOneIterationBudget() throws {
    #if arch(arm64)
      let base: UInt64 = 0x2000
      let source: UInt64 = 0x3000
      let destination: UInt64 = 0x4000
      let loop: [UInt8] = [
        0x48, 0x8b, 0x0c, 0x06, 0x48, 0x89, 0x0c, 0x07,
        0x48, 0x83, 0xc0, 0x08, 0x48, 0x89, 0xd1, 0x48,
        0x29, 0xc1, 0x48, 0x83, 0xf9, 0x07, 0x77, 0xe8,
      ]
      let memory = try DoryX86ByteArrayMemory(byteCount: 0x8000)
      try memory.write(at: base, bytes: loop)
      try memory.write(at: source, bytes: Array(0..<32))
      let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096)
      var state = try DoryX86ArchitecturalState(
        registers: .init(rax: 0, rdx: 32, rsi: source, rdi: destination), rip: base)

      let summary = try #require(
        executor.executeChainedSummary(
          byteProvider: { address, count in
            try memory.instructionBytes(at: address, maximumCount: count)
          },
          at: base,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 6,
          state: &state,
          memory: memory
        ))

      #expect(summary.guestInstructionCount == 6)
      #expect(state.registers.rax == 8)
      #expect(state.rip == base + 22)
      #expect(try memory.read(at: destination, byteCount: 8) == Array(0..<8))
      #expect(
        try memory.read(at: destination + 8, byteCount: 8)
          == [UInt8](repeating: 0, count: 8))
    #endif
  }

  @Test func qwordCopyLoopBulkFaultFallsBackWithStateAndMemoryRestartable() throws {
    #if arch(arm64)
      let base: UInt64 = 0x2000
      let source: UInt64 = 0x3000
      let destination: UInt64 = 0x4000
      let loop: [UInt8] = [
        0x48, 0x8b, 0x0c, 0x06, 0x48, 0x89, 0x0c, 0x07,
        0x48, 0x83, 0xc0, 0x08, 0x48, 0x89, 0xd1, 0x48,
        0x29, 0xc1, 0x48, 0x83, 0xf9, 0x07, 0x77, 0xe8,
      ]
      let memory = try FaultingBulkMemory(byteCount: 0x8000, faultingReadAddress: source)
      try memory.backing.write(at: base, bytes: loop)
      let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096)
      let initial = try DoryX86ArchitecturalState(
        registers: .init(rax: 0, rcx: 0x55, rdx: 32, rsi: source, rdi: destination),
        rip: base,
        rflags: [.reservedOne, .carry, .interruptEnable]
      )
      var state = initial
      let summary = try executor.executeChainedSummary(
        byteProvider: { address, count in
          try memory.instructionBytes(at: address, maximumCount: count)
        },
        at: base,
        mode: .long64,
        addressSpaceID: 0,
        maximumInstructions: 64,
        state: &state,
        memory: memory
      )

      #expect(summary == nil)
      #expect(memory.bulkCopyAttempts == 1)
      #expect(state == initial)
      #expect(
        try memory.backing.read(at: destination, byteCount: 32)
          == [UInt8](repeating: 0, count: 32))
    #endif
  }

  @Test func largeQwordCopyBudgetKeepsExactAccountingAndFinalFlags() throws {
    #if arch(arm64)
      let base: UInt64 = 0x1000
      let source: UInt64 = 0x4000
      let destination: UInt64 = 0x10_000
      let loop: [UInt8] = [
        0x48, 0x8b, 0x0c, 0x06, 0x48, 0x89, 0x0c, 0x07,
        0x48, 0x83, 0xc0, 0x08, 0x48, 0x89, 0xd1, 0x48,
        0x29, 0xc1, 0x48, 0x83, 0xf9, 0x07, 0x77, 0xe8,
      ]
      let payload = (0..<4_680).map { UInt8(truncatingIfNeeded: $0) }

      for budget in [4_095, 4_096, 4_097] {
        let memory = try DoryX86ByteArrayMemory(byteCount: 0x20_000)
        try memory.write(at: base, bytes: loop)
        try memory.write(at: source, bytes: payload)
        let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096)
        var state = try DoryX86ArchitecturalState(
          registers: .init(rax: 0, rdx: 4_680, rsi: source, rdi: destination),
          rip: base,
          rflags: [.reservedOne, .overflow, .zero, .interruptEnable]
        )

        let summary = try #require(
          executor.executeChainedSummary(
            byteProvider: { address, count in
              try memory.instructionBytes(at: address, maximumCount: count)
            },
            at: base,
            mode: .long64,
            addressSpaceID: 0,
            maximumInstructions: budget,
            state: &state,
            memory: memory
          ))

        #expect(summary.guestInstructionCount == 4_095)
        #expect(summary.residentBlockCount == 1_170)
        #expect(state.registers.rax == 4_680)
        #expect(state.registers.rcx == 0)
        #expect(state.rip == base + UInt64(loop.count))
        #expect(
          state.rflags == [
            .reservedOne, .carry, .parity, .auxiliaryCarry, .sign, .interruptEnable,
          ])
        #expect(try memory.read(at: destination, byteCount: payload.count) == payload)
      }
    #endif
  }

  @Test func largeChainKeepsResidentCompilationFetchesAtOrBelow960Bytes() throws {
    #if arch(arm64)
      let base: UInt64 = 0x3000
      let bytes = [UInt8](repeating: 0x90, count: 100) + [0xF4]
      let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 16 * 1024)
      var requestedCounts: [Int] = []
      var state = try DoryX86ArchitecturalState(rip: base)

      let summary = try #require(
        executor.executeChainedSummary(
          byteProvider: { address, count in
            requestedCounts.append(count)
            guard address >= base else { return [] }
            let offset = Int(address - base)
            guard bytes.indices.contains(offset) else { return [] }
            return Array(bytes[offset..<min(bytes.count, offset + count)])
          },
          codeGenerationProvider: { _, _ in 1 },
          at: base,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 4_096,
          state: &state
        ))

      #expect(summary.exitCode == .halt)
      #expect(summary.guestInstructionCount == 101)
      #expect(requestedCounts.max() == 960)
      #expect(requestedCounts.allSatisfy { $0 <= 960 })
    #endif
  }

  @Test func largeChainPublishesAndReplaysABounded256BlockNativeTrace() throws {
    #if arch(arm64)
      let base: UInt64 = 0x5000
      let jump: [UInt8] = [0xEB, 0]
      let bytes: [UInt8] = Array(repeating: jump, count: 300).flatMap { $0 } + [0xF4]
      let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 256 * 1024)
      func run() throws -> DoryARM64ExecutionSummary {
        var state = try DoryX86ArchitecturalState(rip: base)
        return try #require(
          executor.executeChainedSummary(
            byteProvider: { address, count in
              guard address >= base else { return [] }
              let offset = Int(address - base)
              guard bytes.indices.contains(offset) else { return [] }
              return Array(bytes[offset..<min(bytes.count, offset + count)])
            },
            codeGenerationProvider: { _, _ in 1 },
            at: base,
            mode: .long64,
            addressSpaceID: 0,
            maximumInstructions: 4_096,
            state: &state
          ))
      }

      #expect(DoryARM64BaselineExecutor.maximumRecordedNativeTraceBlocks == 256)
      #expect(try run().guestInstructionCount == 301)
      #expect(executor.diagnostics.nativeTraceReplays == 0)
      #expect(try run().guestInstructionCount == 301)
      #expect(executor.diagnostics.nativeTraceAttempts == 1)
      #expect(executor.diagnostics.nativeTraceReplays == 1)
      #expect(executor.nativeBatchExecutionCount == 1)
    #endif
  }

  private func assertNativeArithmeticParity(
    bytes: [UInt8],
    registers: DoryX86GeneralRegisters,
    flags: DoryX86RFLAGS,
    executor: DoryARM64BaselineExecutor,
    optimization: DoryARM64JITOptimization
  ) throws {
    let kernelCS = DoryX86SegmentState(selector: 8, attributes: 0xA09B, limit: .max)
    var interpreted = try DoryX86ArchitecturalState(
      registers: registers,
      rip: 0,
      rflags: flags,
      cs: kernelCS
    )
    _ = DoryX86Interpreter().step(
      state: &interpreted,
      memory: try DoryX86ByteArrayMemory(bytes: bytes),
      mode: .long64
    )

    var translated = try DoryX86ArchitecturalState(
      registers: registers,
      rip: 0,
      rflags: flags,
      cs: kernelCS
    )
    let execution = try #require(
      executor.execute(
        bytes: bytes,
        at: 0,
        mode: .long64,
        addressSpaceID: 0,
        maximumInstructions: 1,
        state: &translated
      )
    )

    #expect(execution.block.tier.rawValue == optimization.rawValue)
    #expect(translated == interpreted)
  }

  private func assertNativeArithmeticSequenceParity(
    bytes: [UInt8],
    registers: DoryX86GeneralRegisters,
    flags: DoryX86RFLAGS,
    executor: DoryARM64BaselineExecutor,
    optimization: DoryARM64JITOptimization
  ) throws {
    let kernelCS = DoryX86SegmentState(selector: 8, attributes: 0xA09B, limit: .max)
    let memory = try DoryX86ByteArrayMemory(bytes: bytes)
    var interpreted = try DoryX86ArchitecturalState(
      registers: registers,
      rip: 0,
      rflags: flags,
      cs: kernelCS
    )
    while interpreted.rip < UInt64(bytes.count) {
      let decoded = try DoryX86Decoder().decode(
        try memory.instructionBytes(at: interpreted.rip, maximumCount: 15),
        at: interpreted.rip,
        mode: .long64
      )
      #expect(DoryX86Interpreter().step(
        state: &interpreted,
        memory: memory,
        mode: .long64
      ) == .retired(decoded))
    }

    var translated = try DoryX86ArchitecturalState(
      registers: registers,
      rip: 0,
      rflags: flags,
      cs: kernelCS
    )
    let execution = try #require(
      executor.execute(
        bytes: bytes,
        at: 0,
        mode: .long64,
        addressSpaceID: 0,
        maximumInstructions: 2,
        state: &translated
      )
    )

    #expect(execution.block.tier.rawValue == optimization.rawValue)
    #expect(execution.block.guestInstructionCount == 2)
    #expect(translated == interpreted)
  }
}

private final class FaultingBulkMemory: DoryX86BulkMemory, @unchecked Sendable {
  let backing: DoryX86ByteArrayMemory
  let faultingReadAddress: UInt64
  private(set) var bulkCopyAttempts = 0

  init(byteCount: Int, faultingReadAddress: UInt64) throws {
    backing = try DoryX86ByteArrayMemory(byteCount: byteCount)
    self.faultingReadAddress = faultingReadAddress
  }

  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    try backing.instructionBytes(at: address, maximumCount: maximumCount)
  }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    if address == faultingReadAddress {
      throw DoryX86MemoryError.unmapped(address: address, byteCount: byteCount, access: .read)
    }
    return try backing.read(at: address, byteCount: byteCount)
  }

  func write(at address: UInt64, bytes: [UInt8]) throws {
    try backing.write(at: address, bytes: bytes)
  }

  func bulkCopyRAMSpan(at address: UInt64, maximumByteCount: Int) -> Int? {
    backing.bulkCopyRAMSpan(at: address, maximumByteCount: maximumByteCount)
  }

  func copyForwardNonoverlapping(
    from sourceAddress: UInt64,
    to destinationAddress: UInt64,
    maximumByteCount: Int
  ) throws -> Int? {
    throw DoryX86MemoryError.unmapped(
      address: sourceAddress, byteCount: maximumByteCount, access: .read)
  }

  func copyForwardNonoverlappingElements(
    from sourceAddress: UInt64,
    to destinationAddress: UInt64,
    elementByteCount: Int,
    maximumElementCount: Int,
    excludingDestinationRanges: [Range<UInt64>]
  ) throws -> Int? {
    bulkCopyAttempts += 1
    throw DoryX86MemoryError.unmapped(
      address: sourceAddress,
      byteCount: elementByteCount * maximumElementCount,
      access: .read
    )
  }
}

private final class ScalarTrackingMemory: DoryX86ScalarMemory, @unchecked Sendable {
  let backing: DoryX86ByteArrayMemory
  private(set) var scalarReads = 0
  private(set) var scalarWrites = 0
  private(set) var arrayReads = 0
  private(set) var arrayWrites = 0

  init(byteCount: Int) throws {
    backing = try DoryX86ByteArrayMemory(byteCount: byteCount)
  }

  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    try backing.instructionBytes(at: address, maximumCount: maximumCount)
  }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    arrayReads += 1
    return try backing.read(at: address, byteCount: byteCount)
  }

  func write(at address: UInt64, bytes: [UInt8]) throws {
    arrayWrites += 1
    try backing.write(at: address, bytes: bytes)
  }

  func validateWrite(at address: UInt64, byteCount: Int) throws {
    try backing.validateWrite(at: address, byteCount: byteCount)
  }

  func synchronize() {
    backing.synchronize()
  }

  func readScalar(at address: UInt64, byteCount: Int) throws -> UInt64 {
    scalarReads += 1
    return try backing.readScalar(at: address, byteCount: byteCount)
  }

  func writeScalar(at address: UInt64, value: UInt64, byteCount: Int) throws {
    scalarWrites += 1
    try backing.writeScalar(at: address, value: value, byteCount: byteCount)
  }
}

private final class SelectiveRestartableMemory: DoryX86ScalarMemory,
  DoryX86RestartableScalarMemory, @unchecked Sendable
{
  let backing: DoryX86ByteArrayMemory
  let declinedAddress: UInt64
  let rejectedWriteAddress: UInt64?
  private(set) var restartableReads = 0
  private(set) var scalarWrites = 0
  private(set) var synchronizationWriteCounts: [Int] = []

  init(byteCount: Int, declinedAddress: UInt64, rejectedWriteAddress: UInt64? = nil) throws {
    backing = try DoryX86ByteArrayMemory(byteCount: byteCount)
    self.declinedAddress = declinedAddress
    self.rejectedWriteAddress = rejectedWriteAddress
  }

  func synchronize() {
    synchronizationWriteCounts.append(scalarWrites)
    backing.synchronize()
  }

  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    try backing.instructionBytes(at: address, maximumCount: maximumCount)
  }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    try backing.read(at: address, byteCount: byteCount)
  }

  func write(at address: UInt64, bytes: [UInt8]) throws {
    try backing.write(at: address, bytes: bytes)
  }

  func readScalar(at address: UInt64, byteCount: Int) throws -> UInt64 {
    try backing.readScalar(at: address, byteCount: byteCount)
  }

  func readRestartableScalar(at address: UInt64, byteCount: Int) throws -> UInt64? {
    restartableReads += 1
    guard address != declinedAddress else { return nil }
    return try backing.readScalar(at: address, byteCount: byteCount)
  }

  func writeScalar(at address: UInt64, value: UInt64, byteCount: Int) throws {
    scalarWrites += 1
    if address == rejectedWriteAddress {
      throw DoryX86MemoryError.pageFault(address: address, errorCode: 3)
    }
    try backing.writeScalar(at: address, value: value, byteCount: byteCount)
  }
}
