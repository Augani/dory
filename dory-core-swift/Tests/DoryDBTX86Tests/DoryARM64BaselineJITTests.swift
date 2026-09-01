import Testing

@testable import DoryDBTX86

@Suite struct DoryARM64BaselineJITTests {
  @Test func fullSystemDefaultCodeCacheRetainsLargeBootWorkingSet() throws {
    let executor = try DoryARM64BaselineExecutor()

    #expect(executor.maximumCodeBytes == 128 * 1024 * 1024)
    #expect(executor.maximumCodeBytes == DoryARM64BaselineExecutor.defaultMaximumCodeBytes)
  }

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

  @Test func chainedExecutionKeepsArchitecturalContextAcrossTakenBranches() throws {
    #if arch(arm64)
      let base: UInt64 = 0x1000
      // mov ecx,3; dec ecx; jne -4; hlt
      let bytes: [UInt8] = [0xB9, 3, 0, 0, 0, 0xFF, 0xC9, 0x75, 0xFC, 0xF4]
      let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096)
      var state = try DoryX86ArchitecturalState(rip: base)
      let summary = try #require(
        executor.executeChainedSummary(
          byteProvider: { address, maximumCount in
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
        )
      )

      #expect(summary.exitCode == .halt)
      #expect(summary.guestInstructionCount == 8)
      #expect(summary.residentBlockCount == 4)
      #expect(state.registers.rcx == 0)
      #expect(state.rip == base + UInt64(bytes.count))

      state = try DoryX86ArchitecturalState(rip: base)
      let replay = try #require(
        executor.executeChainedSummary(
          byteProvider: { address, maximumCount in
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
        )
      )
      #expect(replay == summary)
      #expect(executor.nativeBatchExecutionCount == 1)
      #expect(state.registers.rcx == 0)
      #expect(state.rip == base + UInt64(bytes.count))
    #endif
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

  @Test func executorUsesAllocationFreeScalarMemoryCallbacksWhenAvailable() throws {
    #if arch(arm64)
      let memory = ScalarTrackingMemory(byteCount: 0x100)
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
      let memory = DoryX86ByteArrayMemory(byteCount: 0x100)
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
      let memory = ScalarTrackingMemory(byteCount: 0x100)
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
      let memory = SelectiveRestartableMemory(byteCount: 0x100, declinedAddress: 0x88)
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
      let memory = DoryX86ByteArrayMemory(byteCount: 0x200)
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

  @Test func returnAndPopAndIndirectJumpStayNativeInLongMode() throws {
    #if arch(arm64)
      let memory = DoryX86ByteArrayMemory(byteCount: 0x200)
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
      let memory = DoryX86ByteArrayMemory(byteCount: 0x200)
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
      let memory = DoryX86ByteArrayMemory(byteCount: 0x100)
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
      let memory = DoryX86ByteArrayMemory(byteCount: 0x100)
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
        let memory = DoryX86ByteArrayMemory(bytes: bytes)
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

  @Test func signedMultiply32MatchesInterpreterLowResultAndOverflowFlags() throws {
    #if arch(arm64)
      for (left, right) in [(UInt64(2), UInt64(3)), (0x7FFF_FFFF, 2), (0xFFFF_FFFF, 2)] {
        let bytes: [UInt8] = [0x0F, 0xAF, 0xD8]  // imul ebx,eax
        let initialFlags = DoryX86RFLAGS(
          rawValue: DoryX86RFLAGS.reservedOne.rawValue
            | DoryX86RFLAGS.carry.rawValue
            | DoryX86RFLAGS.zero.rawValue
            | DoryX86RFLAGS.overflow.rawValue
        )
        var interpreted = try DoryX86ArchitecturalState(
          registers: .init(rax: right, rbx: left), rip: 0, rflags: initialFlags)
        _ = DoryX86Interpreter().step(
          state: &interpreted,
          memory: DoryX86ByteArrayMemory(bytes: bytes),
          mode: .long64
        )

        var translated = try DoryX86ArchitecturalState(
          registers: .init(rax: right, rbx: left), rip: 0, rflags: initialFlags)
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
        #expect(translated.registers.rbx == interpreted.registers.rbx)
        #expect(translated.rip == interpreted.rip)
        #expect(translated.rflags == interpreted.rflags)
      }
    #endif
  }

  @Test func zeroExtendWordMemoryMatchesTheFirmwareHotInstruction() throws {
    #if arch(arm64)
      let bytes: [UInt8] = [0x46, 0x0F, 0xB7, 0x0C, 0x40]  // movzx r9d,[rax+r8*2]
      let memory = DoryX86ByteArrayMemory(byteCount: 0x100)
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
      let interpretedMemory = DoryX86ByteArrayMemory(byteCount: 0x100)
      try interpretedMemory.write(at: 0, bytes: bytes)
      let initial = try DoryX86ArchitecturalState(
        registers: .init(rsi: 0x80, r8: 0x1234_5678_9ABC_DEFF), rip: 0)
      var interpreted = initial
      _ = DoryX86Interpreter().step(
        state: &interpreted, memory: interpretedMemory, mode: .long64)

      let translatedMemory = DoryX86ByteArrayMemory(byteCount: 0x100)
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

private final class ScalarTrackingMemory: DoryX86ScalarMemory, @unchecked Sendable {
  let backing: DoryX86ByteArrayMemory
  private(set) var scalarReads = 0
  private(set) var scalarWrites = 0
  private(set) var arrayReads = 0
  private(set) var arrayWrites = 0

  init(byteCount: Int) {
    backing = DoryX86ByteArrayMemory(byteCount: byteCount)
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
  private(set) var restartableReads = 0
  private(set) var scalarWrites = 0

  init(byteCount: Int, declinedAddress: UInt64) {
    backing = DoryX86ByteArrayMemory(byteCount: byteCount)
    self.declinedAddress = declinedAddress
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
    try backing.writeScalar(at: address, value: value, byteCount: byteCount)
  }
}
