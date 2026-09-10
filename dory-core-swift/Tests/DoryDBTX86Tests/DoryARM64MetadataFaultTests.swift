import Testing

@testable import DoryDBTX86

@Suite struct DoryARM64MetadataFaultTests {
  @Test func baselineSideTableMapsEmittedOffsetsToExactGuestBoundaries() throws {
    let block = try DoryX86IRTranslator().translate(
      [
        0x90,  // nop
        0x48, 0xB8, 1, 0, 0, 0, 0, 0, 0, 0,  // mov rax,1
        0x48, 0x83, 0xC0, 2,  // add rax,2
      ],
      at: 0x4000,
      mode: .long64
    )
    let compiled = DoryARM64BaselineEmitter().compile(block)

    #expect(compiled.instructionMetadata.count == 3)
    #expect(compiled.instructionMetadata.map(\.guestRIP) == [0x4000, 0x4001, 0x400B])
    #expect(compiled.instructionMetadata[0].hostOffsetStart
      == compiled.instructionMetadata[1].hostOffsetStart)
    #expect(compiled.instructionMetadata.allSatisfy { $0.flagsState == .context })
    #expect(compiled.instructionMetadata.allSatisfy {
      $0.liveInRegisterMask == 0 && $0.dirtyRegisterMask == 0
    })
    #expect(
      compiled.instructionMetadata(
        atHostOffset: compiled.instructionMetadata[0].hostOffsetStart
      )?.guestRIP == 0x4001
    )
  }

  @Test func tier1SideTableRecordsLiveNativeFlagsAtFollowingInstruction() throws {
    let block = try DoryX86IRTranslator().translate(
      [
        0x90,  // nop
        0x48, 0xB8, 1, 0, 0, 0, 0, 0, 0, 0,  // mov rax,1
        0x48, 0x83, 0xC0, 2,  // add rax,2
        0x48, 0x89, 0xC3,  // mov rbx,rax
      ],
      at: 0x5000,
      mode: .long64
    )
    let compiled = try #require(DoryARM64Tier1Emitter().compile(block))

    #expect(compiled.instructionMetadata.count == 4)
    #expect(compiled.instructionMetadata.map(\.guestRIP) == [0x5000, 0x5001, 0x500B, 0x500F])
    #expect(compiled.instructionMetadata.map(\.flagsState)
      == [.context, .context, .context, .nativeNZCV])
    #expect(compiled.instructionMetadata.map(\.liveInRegisterMask) == [0, 0, 1, 1])
    #expect(compiled.instructionMetadata.map(\.dirtyRegisterMask) == [0, 0, 1, 1])
  }

  @Test func tier1SideTableTracksAddressAndPartialRegisterDependencies() throws {
    let block = try DoryX86IRTranslator().translate(
      [
        0x48, 0xB8, 1, 0, 0, 0, 0, 0, 0, 0,  // mov rax,1
        0x88, 0xC8,  // mov al,cl
        0x48, 0x8D, 0x14, 0x8B,  // lea rdx,[rbx+rcx*4]
      ],
      at: 0x5800,
      mode: .long64
    )
    let compiled = try #require(DoryARM64Tier1Emitter().compile(block))

    #expect(compiled.instructionMetadata.map(\.guestRIP) == [0x5800, 0x580A, 0x580C])
    let expectedLiveIn: [UInt16] = [
      0,
      (1 << 0) | (1 << 1),
      (1 << 1) | (1 << 3),
    ]
    #expect(compiled.instructionMetadata.map(\.liveInRegisterMask) == expectedLiveIn)
    #expect(compiled.instructionMetadata.map(\.dirtyRegisterMask) == [0, 1, 1])
  }

  @Test func failedMemoryCallbackHostPCSelectsTheFaultingGuestInstruction() throws {
    #if arch(arm64)
      let block = try DoryX86IRTranslator().translate(
        [
          0x48, 0xB9, 1, 0, 0, 0, 0, 0, 0, 0,  // mov rcx,1
          0x48, 0x8B, 0x03,  // mov rax,[rbx]
        ],
        at: 0x6000,
        mode: .long64
      )
      let compiled = DoryARM64BaselineEmitter().compile(block)
      let region = try DoryJITExecutableRegion(minimumCapacity: 4096)
      try region.publish(compiled, at: 0)
      let memory = try DoryX86ByteArrayMemory(byteCount: 0x80)
      var context = Array(
        repeating: UInt64(0),
        count: DoryJITExecutableRegion.contextWordCount
      )
      context[3] = 0x100
      context[16] = 0x6000

      let execution = try context.withUnsafeMutableBufferPointer { buffer in
        try region.executePreparedWithRecovery(
          at: 0,
          context: buffer,
          memoryCapabilities: .init(memory: memory),
          requiresRestartableReads: false
        )
      }
      let entryAddress = try #require(region.entryAddress(at: 0))
      let callbackHostPC = try #require(execution.failedCallbackHostPC)
      let failedContext = try #require(execution.failedExecutionContext)
      #expect(execution.exitCode == .interpreter)
      #expect(failedContext[1] == 1)
      #expect(failedContext[16] == 0x6000)
      #expect(callbackHostPC >= entryAddress)
      let hostOffset = try #require(UInt32(exactly: callbackHostPC - entryAddress))
      #expect(compiled.instructionMetadata(atHostOffset: hostOffset)?.guestRIP == 0x600A)
    #endif
  }

  @Test func failedCallbackPublishesCompletedInstructionPrefixAndRetriesAtFaultingRIP() throws {
    #if arch(arm64)
      let bytes: [UInt8] = [
        0x48, 0xB9, 1, 0, 0, 0, 0, 0, 0, 0,  // mov rcx,1
        0x48, 0x8B, 0x03,  // mov rax,[rbx]
      ]
      for (tier1Enabled, optimization) in [
        (false, DoryARM64JITOptimization.baseline),
        (true, DoryARM64JITOptimization.optimizing),
      ] {
        let executor = try DoryARM64BaselineExecutor(
          maximumCodeBytes: 16 * 1024,
          tier1Enabled: tier1Enabled,
          optimization: optimization
        )
        let memory = try DoryX86ByteArrayMemory(baseAddress: 0x6000, bytes: bytes)
        var state = try DoryX86ArchitecturalState(
          registers: .init(rax: 0xAAAA, rcx: 0, rbx: 0x7000),
          rip: 0x6000,
          cs: .init(selector: 0, attributes: 0xA09B, limit: .max)
        )

        let prefix = try #require(executor.executeChainedSummary(
          byteProvider: { address, maximumCount in
            (try? memory.instructionBytes(at: address, maximumCount: maximumCount)) ?? []
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
        #expect(prefix.exitCode == .dispatch)
        #expect(state.rip == 0x600A)
        #expect(state.registers.rcx == 1)
        #expect(state.registers.rax == 0xAAAA)

        let beforeRetry = state
        #expect(try executor.executeChainedSummary(
          byteProvider: { address, maximumCount in
            (try? memory.instructionBytes(at: address, maximumCount: maximumCount)) ?? []
          },
          at: state.rip,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 1,
          state: &state,
          memory: memory
        ) == nil)
        #expect(state == beforeRetry)
      }
    #endif
  }

  @Test func directChainedTargetCallbackFaultPublishesBothCompletedPrefixes() throws {
    #if arch(arm64)
      let source: [UInt8] = [
        0x48, 0xFF, 0xC1,  // inc rcx
        0xE9, 0xF8, 0x0F, 0, 0,  // jmp 0x2000
      ]
      let target: [UInt8] = [
        0x48, 0xFF, 0xC2,  // inc rdx
        0x48, 0x8B, 0x03,  // mov rax,[rbx]
        0xE9, 0xF5, 0x0F, 0, 0,  // jmp 0x3000
      ]
      let halt: [UInt8] = [0xF4]
      for (tier1Enabled, optimization) in [
        (false, DoryARM64JITOptimization.baseline),
        (true, DoryARM64JITOptimization.optimizing),
      ] {
        let executor = try DoryARM64BaselineExecutor(
          maximumCodeBytes: 16 * 1024,
          tier1Enabled: tier1Enabled,
          optimization: optimization
        )
        let memory = try ToggleReadFaultMemory(byteCount: 0x100)
        try memory.writeScalar(at: 0, value: 0x1234, byteCount: 8)
        func bytes(at address: UInt64, maximumCount: Int) -> [UInt8] {
          let block: [UInt8]
          switch address {
          case 0x1000: block = source
          case 0x2000: block = target
          case 0x3000: block = halt
          default: return []
          }
          return Array(block.prefix(maximumCount))
        }

        var cold = try DoryX86ArchitecturalState(
          registers: .init(rbx: 0),
          rip: 0x1000,
          cs: .init(selector: 0, attributes: 0xA09B, limit: .max)
        )
        let coldSummary = try #require(executor.executeChainedSummary(
          byteProvider: bytes,
          at: cold.rip,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 8,
          state: &cold,
          memory: memory
        ))
        #expect(coldSummary.guestInstructionCount == 6)
        #expect(cold.rip == 0x3001)
        #expect(cold.registers.rax == 0x1234)

        let directBefore = executor.diagnostics.directlyChainedBlocks
        memory.rejectReads = true
        var state = try DoryX86ArchitecturalState(
          registers: .init(rax: 0xAAAA, rbx: 0x1000),
          rip: 0x1000,
          cs: .init(selector: 0, attributes: 0xA09B, limit: .max)
        )
        let summary = try #require(executor.executeChainedSummary(
          byteProvider: bytes,
          at: state.rip,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 8,
          state: &state,
          memory: memory
        ))

        #expect(summary.guestInstructionCount == 3)
        #expect(summary.residentBlockCount == 2)
        #expect(summary.exitCode == .dispatch)
        #expect(state.rip == 0x2003)
        #expect(state.registers.rcx == 1)
        #expect(state.registers.rdx == 1)
        #expect(state.registers.rax == 0xAAAA)
        #expect(executor.diagnostics.directlyChainedBlocks > directBefore)
      }
    #endif
  }

  @Test func nonChainedExecutionReportsAndPublishesOnlyTheCompletedPrefix() throws {
    #if arch(arm64)
      let bytes: [UInt8] = [
        0x48, 0xB9, 1, 0, 0, 0, 0, 0, 0, 0,  // mov rcx,1
        0x48, 0x8B, 0x03,  // mov rax,[rbx]
      ]
      for (tier1Enabled, optimization) in [
        (false, DoryARM64JITOptimization.baseline),
        (true, DoryARM64JITOptimization.optimizing),
      ] {
        let executor = try DoryARM64BaselineExecutor(
          maximumCodeBytes: 16 * 1024,
          tier1Enabled: tier1Enabled,
          optimization: optimization
        )
        let memory = try DoryX86ByteArrayMemory(baseAddress: 0x6000, bytes: bytes)
        var state = try DoryX86ArchitecturalState(
          registers: .init(rax: 0xAAAA, rcx: 0, rbx: 0x7000),
          rip: 0x6000,
          cs: .init(selector: 0, attributes: 0xA09B, limit: .max)
        )

        let prefix = try #require(executor.executeSummary(
          byteProvider: { Array(bytes.prefix($0)) },
          at: state.rip,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 2,
          state: &state,
          memory: memory
        ))
        #expect(prefix.guestInstructionCount == 1)
        #expect(prefix.residentBlockCount == 1)
        #expect(prefix.exitCode == .interpreter)
        #expect(state.rip == 0x600A)
        #expect(state.registers.rcx == 1)
        #expect(state.registers.rax == 0xAAAA)

        let beforeRetry = state
        let retry = try #require(executor.executeSummary(
          byteProvider: { maximumCount in
            Array(bytes.dropFirst(10).prefix(maximumCount))
          },
          at: state.rip,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 1,
          state: &state,
          memory: memory
        ))
        #expect(retry.guestInstructionCount == 0)
        #expect(retry.exitCode == .interpreter)
        #expect(state == beforeRetry)
      }
    #endif
  }

  @Test func tier1NativeFlagsBoundaryRecoversThroughTheLazyContextRecord() throws {
    #if arch(arm64)
      let bytes: [UInt8] = [
        0x48, 0x83, 0xC1, 1,  // add rcx,1
        0x48, 0x8B, 0x03,  // mov rax,[rbx]
      ]
      let executor = try DoryARM64BaselineExecutor(
        maximumCodeBytes: 16 * 1024,
        tier1Enabled: true,
        optimization: .optimizing
      )
      let memory = try DoryX86ByteArrayMemory(baseAddress: 0x6000, bytes: bytes)
      var state = try DoryX86ArchitecturalState(
        registers: .init(rax: 0xAAAA, rcx: .max, rbx: 0x7000),
        rip: 0x6000,
        rflags: [.reservedOne, .interruptEnable],
        cs: .init(selector: 0, attributes: 0xA09B, limit: .max)
      )

      let summary = try #require(executor.executeChainedSummary(
        byteProvider: { address, maximumCount in
          (try? memory.instructionBytes(at: address, maximumCount: maximumCount)) ?? []
        },
        at: state.rip,
        mode: .long64,
        addressSpaceID: 0,
        maximumInstructions: 2,
        state: &state,
        memory: memory
      ))
      #expect(summary.guestInstructionCount == 1)
      #expect(summary.tier == .tier1)
      #expect(summary.exitCode == .dispatch)
      #expect(state.rip == 0x6004)
      #expect(state.registers.rcx == 0)
      #expect(state.registers.rax == 0xAAAA)
      #expect(state.rflags == [
        .reservedOne, .carry, .parity, .auxiliaryCarry, .zero, .interruptEnable,
      ])
    #endif
  }

  @Test func inlineTLBPageFaultPublishesTheCompletedInstructionPrefix() throws {
    #if arch(arm64)
      for (tier1Enabled, optimization) in [
        (false, DoryARM64JITOptimization.baseline),
        (true, DoryARM64JITOptimization.optimizing),
      ] {
        let physical = try mmapMemory()
        // INC RCX; MOV RAX,[RBX]. Page 0x7000 is deliberately absent.
        try physical.write(at: 0x1000, bytes: [0x48, 0xFF, 0xC1, 0x48, 0x8B, 0x03])
        var initial = try state(rip: 0x1000)
        initial.registers.rbx = 0x7000
        initial.registers.rax = 0xAAAA
        let paging = DoryX86PagingUnit()
        let translated = DoryX86TranslatedMemory(
          physicalMemory: physical,
          pagingUnit: paging,
          context: .init(state: initial, mode: .long64)
        )
        let executor = try DoryARM64BaselineExecutor(
          maximumCodeBytes: 16 * 1024,
          tier1Enabled: tier1Enabled,
          optimization: optimization
        )
        var state = initial

        let summary = try #require(executor.executeChainedSummary(
          byteProvider: { address, maximumCount in
            (try? translated.instructionBytes(at: address, maximumCount: maximumCount)) ?? []
          },
          codeGenerationProvider: {
            try translated.codeGeneration(at: $0, byteCount: $1)
          },
          at: state.rip,
          mode: .long64,
          addressSpaceID: 0x9000,
          maximumInstructions: 2,
          state: &state,
          memory: translated
        ))
        #expect(summary.guestInstructionCount == 1)
        #expect(summary.exitCode == .dispatch)
        #expect(state.rip == 0x1003)
        #expect(state.registers.rcx == 1)
        #expect(state.registers.rax == 0xAAAA)
        if !tier1Enabled {
          // The baseline body uses the inline TLB. This counter distinguishes its C miss resolver
          // from the tier-one MOV helper callback while both recovery paths share the assertions.
          #expect(executor.diagnostics.translationCachePageFaults == 1)
        }

        #expect(DoryX86Interpreter().step(
          state: &state,
          memory: physical,
          mode: .long64,
          pagingUnit: paging,
          translatedMemory: translated
        ) == .exception(.init(
          kind: .pageFault,
          vector: 14,
          errorCode: 0x4,
          instructionPointer: 0x1003,
          linearAddress: 0x7000
        )))
        #expect(state.rip == 0x1003)
        #expect(state.registers.rcx == 1)
        #expect(state.registers.rax == 0xAAAA)
      }
    #endif
  }

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
    let physical = try DoryX86ByteArrayMemory(byteCount: 0x10000)
    for (address, value): (UInt64, UInt64) in [
      (0x9000, 0xA007), (0xA000, 0xB007), (0xB000, 0xC007),
      (0xC008, 0x1007), (0xC010, 0x2007), (0xC040, 0x8007),
    ] { try physical.writeScalar(at: address, value: value, byteCount: 8) }
    return physical
  }

  private func mmapMemory() throws -> DoryX86MmapMemory {
    let physical = try DoryX86MmapMemory(validatingByteCount: 0x10_000)
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

private final class ToggleReadFaultMemory: DoryX86ScalarMemory,
  DoryX86RestartableScalarMemory, @unchecked Sendable
{
  let backing: DoryX86ByteArrayMemory
  var rejectReads = false

  init(byteCount: Int) throws {
    backing = try DoryX86ByteArrayMemory(byteCount: byteCount)
  }

  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    try backing.instructionBytes(at: address, maximumCount: maximumCount)
  }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    if rejectReads { throw DoryX86MemoryError.pageFault(address: address, errorCode: 0) }
    return try backing.read(at: address, byteCount: byteCount)
  }

  func validateRead(at address: UInt64, byteCount: Int) throws {
    if rejectReads { throw DoryX86MemoryError.pageFault(address: address, errorCode: 0) }
    try backing.validateRead(at: address, byteCount: byteCount)
  }

  func write(at address: UInt64, bytes: [UInt8]) throws {
    try backing.write(at: address, bytes: bytes)
  }

  func validateWrite(at address: UInt64, byteCount: Int) throws {
    try backing.validateWrite(at: address, byteCount: byteCount)
  }

  func synchronize() {
    backing.synchronize()
  }

  func readScalar(at address: UInt64, byteCount: Int) throws -> UInt64 {
    if rejectReads { throw DoryX86MemoryError.pageFault(address: address, errorCode: 0) }
    return try backing.readScalar(at: address, byteCount: byteCount)
  }

  func readRestartableScalar(at address: UInt64, byteCount: Int) throws -> UInt64? {
    try readScalar(at: address, byteCount: byteCount)
  }

  func writeScalar(at address: UInt64, value: UInt64, byteCount: Int) throws {
    try backing.writeScalar(at: address, value: value, byteCount: byteCount)
  }
}
