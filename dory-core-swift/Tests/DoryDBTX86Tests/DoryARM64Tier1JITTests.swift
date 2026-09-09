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

  @Test func measuredDelayTSCMulLoadBlockCompilesInTier1() throws {
    let address: UInt64 = 0xFFFF_FFFF_81E2_DC36
    let bytes: [UInt8] = [
      0xF7, 0xE2,  // mul edx
      0x48, 0x8B, 0x05, 0x19, 0x2A, 0x69, 0x00,  // mov rax, [rip + 0x692a19]
      0x48, 0x8D, 0x7A, 0x01,  // lea rdi, [rdx + 1]
      0xE9, 0x38, 0xB8, 0x01, 0x00,  // jmp 0xffffffff81e4947f
    ]
    let block = try DoryX86IRTranslator().translate(bytes, at: address, mode: .long64)
    let compiled = try #require(DoryARM64Tier1Emitter().compile(block))

    #expect(compiled.tier == .tier1)
    #expect(compiled.guestByteCount == bytes.count)
    #expect(compiled.guestInstructionCount == 4)
    #expect(compiled.requiresMemoryCallbacks)
    #expect(!compiled.requiresRestartableMemoryReads)
    #expect(compiled.mayExitToInterpreter)
  }

  @Test func measuredDelayTSCMemoryCMOVBlockCompilesInTier1() throws {
    let address: UInt64 = 0xFFFF_FFFF_81E2_DC27
    let bytes: [UInt8] = [
      0x48, 0x0F, 0x44, 0x15, 0xE1, 0x43, 0xBE, 0x00,  // cmove rdx,[rip + 0xbe43e1]
      0x48, 0x69, 0xD2, 0xFA, 0x00, 0x00, 0x00,  // imul rdx,rdx,0xfa
    ]
    let block = try DoryX86IRTranslator().translate(bytes, at: address, mode: .long64)
    let compiled = try #require(DoryARM64Tier1Emitter().compile(block))

    #expect(compiled.tier == .tier1)
    #expect(compiled.guestByteCount == bytes.count)
    #expect(compiled.guestInstructionCount == 2)
    #expect(compiled.requiresMemoryCallbacks)
    #expect(!compiled.requiresRestartableMemoryReads)
    #expect(compiled.mayExitToInterpreter)
  }

  @Test func completeMeasuredDelayTSCBodyCompilesInTier1() throws {
    let address: UInt64 = 0xFFFF_FFFF_81E2_DC14
    let bytes: [UInt8] = [
      0x65, 0x48, 0x8B, 0x15, 0xB4, 0xA5, 0x48, 0x01,  // mov rdx,gs:[rip + 0x148a5b4]
      0x48, 0x8D, 0x04, 0xBD, 0, 0, 0, 0,  // lea rax,[rdi * 4]
      0x48, 0x85, 0xD2,  // test rdx,rdx
      0x48, 0x0F, 0x44, 0x15, 0xE1, 0x43, 0xBE, 0x00,  // cmove rdx,[rip + 0xbe43e1]
      0x48, 0x69, 0xD2, 0xFA, 0x00, 0x00, 0x00,  // imul rdx,rdx,0xfa
      0xF7, 0xE2,  // mul edx
      0x48, 0x8B, 0x05, 0x19, 0x2A, 0x69, 0x00,  // mov rax,[rip + 0x692a19]
      0x48, 0x8D, 0x7A, 0x01,  // lea rdi,[rdx + 1]
      0xE9, 0x38, 0xB8, 0x01, 0x00,  // jmp 0xffffffff81e49480
    ]
    let block = try DoryX86IRTranslator().translate(bytes, at: address, mode: .long64)
    let compiled = try #require(DoryARM64Tier1Emitter().compile(block))

    #expect(compiled.tier == .tier1)
    #expect(compiled.guestByteCount == bytes.count)
    #expect(compiled.guestInstructionCount == 9)
    #expect(compiled.requiresMemoryCallbacks)
    #expect(compiled.requiresRestartableMemoryReads)
    #expect(compiled.mayExitToInterpreter)
  }

  @Test func memoryCMOVMaterializesPendingTestFlagsBeforeTheMandatoryRead() throws {
    #if arch(arm64)
      let bytes: [UInt8] = [
        0x48, 0x85, 0xD2,  // test rdx,rdx
        0x48, 0x0F, 0x44, 0x08,  // cmove rcx,[rax]
      ]
      for rdx: UInt64 in [0, 1] {
        let registers = DoryX86GeneralRegisters(
          rax: 0x80,
          rcx: 0x1122_3344_5566_7788,
          rdx: rdx
        )
        let initialFlags: DoryX86RFLAGS = [.reservedOne, .carry, .direction]
        let interpretedMemory = try DoryX86ByteArrayMemory(byteCount: 0x100)
        try interpretedMemory.write(at: 0, bytes: bytes)
        try interpretedMemory.writeScalar(
          at: 0x80,
          value: 0x8877_6655_4433_2211,
          byteCount: 8
        )
        var interpreted = try DoryX86ArchitecturalState(
          registers: registers,
          rip: 0,
          rflags: initialFlags
        )
        for _ in 0..<2 {
          guard case .retired = DoryX86Interpreter().step(
            state: &interpreted,
            memory: interpretedMemory,
            mode: .long64
          ) else {
            Issue.record("reference TEST-to-memory-CMOV block unexpectedly faulted")
            return
          }
        }

        let translatedMemory = try DoryX86ByteArrayMemory(byteCount: 0x100)
        try translatedMemory.writeScalar(
          at: 0x80,
          value: 0x8877_6655_4433_2211,
          byteCount: 8
        )
        var translated = try DoryX86ArchitecturalState(
          registers: registers,
          rip: 0,
          rflags: initialFlags
        )
        let executor = try DoryARM64BaselineExecutor(
          maximumCodeBytes: 16 * 1024,
          tier1Enabled: true
        )
        let execution = try #require(executor.execute(
          bytes: bytes,
          at: 0,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 2,
          state: &translated,
          memory: translatedMemory
        ))

        #expect(execution.block.tier == .tier1)
        #expect(execution.block.requiresMemoryCallbacks)
        #expect(translated == interpreted)
        #expect(executor.diagnostics.lazyFlagMaterializations == 1)
      }
    #endif
  }

  @Test func measuredHighCanonicalMemoryCMOVExecutesLikeTheInterpreter() throws {
    #if arch(arm64)
      let address: UInt64 = 0xFFFF_FFFF_81E2_DC27
      let dataAddress: UInt64 = 0xFFFF_FFFF_82A1_2010
      let bytes: [UInt8] = [
        0x48, 0x0F, 0x44, 0x15, 0xE1, 0x43, 0xBE, 0x00,  // cmove rdx,[rip + 0xbe43e1]
        0x48, 0x69, 0xD2, 0xFA, 0x00, 0x00, 0x00,  // imul rdx,rdx,0xfa
      ]
      let memoryByteCount = Int(dataAddress - address) + 8
      for predicate in [false, true] {
        var flags: DoryX86RFLAGS = [.reservedOne, .carry, .direction]
        if predicate { flags.insert(.zero) }
        let initial = try DoryX86ArchitecturalState(
          registers: .init(rdx: 3),
          rip: address,
          rflags: flags
        )

        let interpretedMemory = try DoryX86ByteArrayMemory(
          baseAddress: address,
          byteCount: memoryByteCount
        )
        try interpretedMemory.write(at: address, bytes: bytes)
        try interpretedMemory.writeScalar(at: dataAddress, value: 4, byteCount: 8)
        var interpreted = initial
        for _ in 0..<2 {
          guard case .retired = DoryX86Interpreter().step(
            state: &interpreted,
            memory: interpretedMemory,
            mode: .long64
          ) else {
            Issue.record("reference measured memory-CMOV block unexpectedly faulted")
            return
          }
        }

        let translatedMemory = try DoryX86ByteArrayMemory(
          baseAddress: address,
          byteCount: memoryByteCount
        )
        try translatedMemory.writeScalar(at: dataAddress, value: 4, byteCount: 8)
        var translated = initial
        let execution = try #require(DoryARM64BaselineExecutor(
          maximumCodeBytes: 16 * 1024,
          tier1Enabled: true
        ).execute(
          bytes: bytes,
          at: address,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 2,
          state: &translated,
          memory: translatedMemory
        ))

        #expect(execution.block.tier == .tier1)
        #expect(translated == interpreted)
      }
    #endif
  }

  @Test func completeMeasuredDelayTSCBodyExecutesLikeTheInterpreter() throws {
    #if arch(arm64)
      let address: UInt64 = 0xFFFF_FFFF_81E2_DC14
      let perCPUDataAddress: UInt64 = 0xFFFF_FFFF_832B_81D0
      let conditionalDataAddress: UInt64 = 0xFFFF_FFFF_82A1_2010
      let clockDataAddress: UInt64 = 0xFFFF_FFFF_824C_0658
      let bytes: [UInt8] = [
        0x65, 0x48, 0x8B, 0x15, 0xB4, 0xA5, 0x48, 0x01,
        0x48, 0x8D, 0x04, 0xBD, 0, 0, 0, 0,
        0x48, 0x85, 0xD2,
        0x48, 0x0F, 0x44, 0x15, 0xE1, 0x43, 0xBE, 0x00,
        0x48, 0x69, 0xD2, 0xFA, 0x00, 0x00, 0x00,
        0xF7, 0xE2,
        0x48, 0x8B, 0x05, 0x19, 0x2A, 0x69, 0x00,
        0x48, 0x8D, 0x7A, 0x01,
        0xE9, 0x38, 0xB8, 0x01, 0x00,
      ]
      let memoryByteCount = Int(perCPUDataAddress - address) + 8
      for perCPUValue: UInt64 in [0, 2] {
        let initial = try DoryX86ArchitecturalState(
          registers: .init(rdi: 5),
          rip: address,
          rflags: [.reservedOne, .carry, .direction],
          cs: .init(attributes: 0xA09B, limit: .max),
          gs: .init(base: 0)
        )

        let interpretedMemory = try DoryX86ByteArrayMemory(
          baseAddress: address,
          byteCount: memoryByteCount
        )
        try interpretedMemory.write(at: address, bytes: bytes)
        try interpretedMemory.writeScalar(
          at: perCPUDataAddress, value: perCPUValue, byteCount: 8)
        try interpretedMemory.writeScalar(
          at: conditionalDataAddress, value: 4, byteCount: 8)
        try interpretedMemory.writeScalar(
          at: clockDataAddress, value: 0x1122_3344_5566_7788, byteCount: 8)
        var interpreted = initial
        for _ in 0..<9 {
          guard case .retired = DoryX86Interpreter().step(
            state: &interpreted,
            memory: interpretedMemory,
            mode: .long64
          ) else {
            Issue.record("reference complete delay_tsc body unexpectedly faulted")
            return
          }
        }

        let translatedMemory = try DoryX86ByteArrayMemory(
          baseAddress: address,
          byteCount: memoryByteCount
        )
        try translatedMemory.writeScalar(
          at: perCPUDataAddress, value: perCPUValue, byteCount: 8)
        try translatedMemory.writeScalar(
          at: conditionalDataAddress, value: 4, byteCount: 8)
        try translatedMemory.writeScalar(
          at: clockDataAddress, value: 0x1122_3344_5566_7788, byteCount: 8)
        var translated = initial
        let execution = try #require(DoryARM64BaselineExecutor(
          maximumCodeBytes: 32 * 1024,
          tier1Enabled: true
        ).execute(
          bytes: bytes,
          at: address,
          mode: .long64,
          addressSpaceID: 0,
          maximumInstructions: 9,
          state: &translated,
          memory: translatedMemory
        ))

        #expect(execution.block.tier == .tier1)
        #expect(execution.block.requiresRestartableMemoryReads)
        #expect(translated == interpreted)
      }
    #endif
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
      #expect(executor.diagnostics.tier1CompilationAttempts == 1)
      #expect(executor.diagnostics.tier1CompilationDeclines == 0)
      #expect(executor.diagnostics.tier1CompiledBlocks == 1)
      #expect(executor.diagnostics.lazyFlagMaterializations == 1)
    #endif
  }

  @Test func disabledTier1AndDeclinedMemoryPathsRetainTheOldBaseline() throws {
    #if arch(arm64)
      let address: UInt64 = 0x3000
      let registerBytes: [UInt8] = [0x48, 0xB8, 1, 0, 0, 0, 0, 0, 0, 0]  // mov rax, 1
      let memoryBytes: [UInt8] = [0x48, 0x89, 0x00]  // mov [rax], rax
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
        #expect(executor.diagnostics.tier1CompilationAttempts == (tier1Enabled ? 1 : 0))
        #expect(executor.diagnostics.tier1CompilationDeclines == (tier1Enabled ? 1 : 0))
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

  @Test func registerTransformsMatchTheInterpreterAcrossWidths() throws {
    #if arch(arm64)
      let cases: [([UInt8], DoryX86GeneralRegisters)] = [
        ([0x0F, 0xC8], .init(rax: 0xAABB_CCDD_1122_3344)),  // bswap eax
        ([0x48, 0x0F, 0xC8], .init(rax: 0x1122_3344_5566_7788)),  // bswap rax
        ([0x0F, 0xBE, 0xD8], .init(rax: 0x80, rbx: .max)),  // movsx ebx,al
        ([0x48, 0x0F, 0xBE, 0xD8], .init(rax: 0x80, rbx: 0)),  // movsx rbx,al
        ([0x0F, 0xBF, 0xD8], .init(rax: 0x8000, rbx: .max)),  // movsx ebx,ax
        ([0x48, 0x0F, 0xBF, 0xD8], .init(rax: 0x8000, rbx: 0)),  // movsx rbx,ax
        ([0x48, 0x63, 0xD8], .init(rax: 0x8000_0000, rbx: 0)),  // movsxd rbx,eax
        ([0x0F, 0xB6, 0xD8], .init(rax: 0x80, rbx: .max)),  // movzx ebx,al
        ([0x48, 0x0F, 0xB6, 0xD8], .init(rax: 0x80, rbx: .max)),  // movzx rbx,al
        ([0x0F, 0xB7, 0xD8], .init(rax: 0xFEDC, rbx: .max)),  // movzx ebx,ax
        ([0x48, 0x0F, 0xB7, 0xD8], .init(rax: 0xFEDC, rbx: .max)),  // movzx rbx,ax
        ([0x99], .init(rax: 0x8000_0000, rdx: 0x1234)),  // cdq
        ([0x48, 0x99], .init(rax: 0x8000_0000_0000_0000, rdx: 0x1234)),  // cqo
        ([0x48, 0x87, 0xD8], .init(rax: 0x1111, rbx: 0x2222)),  // xchg rax,rbx
      ]
      let flags: DoryX86RFLAGS = [
        .reservedOne, .carry, .parity, .auxiliaryCarry, .zero, .sign, .direction,
        .interruptEnable, .overflow,
      ]

      for (index, testCase) in cases.enumerated() {
        let address = UInt64(0x4000 + index * 0x10)
        let initial = try DoryX86ArchitecturalState(
          registers: testCase.1,
          rip: address,
          rflags: flags
        )
        var interpreted = initial
        guard case .retired = DoryX86Interpreter().step(
          state: &interpreted,
          memory: try DoryX86ByteArrayMemory(baseAddress: address, bytes: testCase.0),
          mode: .long64
        ) else {
          Issue.record("interpreter did not retire tier-1 register transform")
          return
        }

        var tier1 = initial
        let executor = try DoryARM64BaselineExecutor(
          maximumCodeBytes: 4096,
          tier1Enabled: true
        )
        let execution = try #require(executor.execute(
          bytes: testCase.0,
          at: address,
          mode: .long64,
          addressSpaceID: UInt64(index),
          maximumInstructions: 1,
          state: &tier1
        ))
        #expect(execution.block.tier == .tier1)
        #expect(tier1 == interpreted)
        #expect(tier1.rflags == flags)
      }
    #endif
  }

  @Test func registerTransformsPreserveTheNativeConditionPath() throws {
    #if arch(arm64)
      let address: UInt64 = 0x4F00
      let bytes: [UInt8] = [
        0x48, 0x39, 0xD8,  // cmp rax,rbx
        0x4D, 0x87, 0xC8,  // xchg r8,r9
        0x49, 0x0F, 0xCA,  // bswap r10
        0x4D, 0x0F, 0xBE, 0xDC,  // movsx r11,r12b
        0x45, 0x0F, 0xB7, 0xEE,  // movzx r13d,r14w
        0x48, 0x99,  // cqo
        0x75, 0x04,  // jne +4
      ]
      let initial = try DoryX86ArchitecturalState(
        registers: .init(
          rax: UInt64.max,
          rdx: 0x1234,
          rbx: 7,
          r8: 0x1111,
          r9: 0x2222,
          r10: 0x1122_3344_5566_7788,
          r11: 0,
          r12: 0x80,
          r13: .max,
          r14: 0xFEDC
        ),
        rip: address,
        rflags: [.reservedOne, .direction]
      )
      let memory = try DoryX86ByteArrayMemory(baseAddress: address, bytes: bytes)
      var interpreted = initial
      for _ in 0..<7 {
        guard case .retired = DoryX86Interpreter().step(
          state: &interpreted,
          memory: memory,
          mode: .long64
        ) else {
          Issue.record("interpreter did not retire transformed native-condition fixture")
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
        maximumInstructions: 7,
        state: &tier1
      ))
      #expect(execution.block.tier == .tier1)
      #expect(tier1 == interpreted)
      #expect(tier1.rip == address + UInt64(bytes.count) + 4)
      #expect(executor.diagnostics.lazyFlagMaterializations == 1)
    #endif
  }

  @Test func effectiveAddressesMatchTheInterpreterAcrossAddressWidthsAndAliases() throws {
    #if arch(arm64)
      let cases: [([UInt8], DoryX86GeneralRegisters)] = [
        (
          [0x4E, 0x8D, 0x54, 0xCB, 0xE0],  // lea r10,[rbx+r9*8-0x20]
          .init(rbx: 0x1000, r9: 0x21, r10: .max)
        ),
        (
          [0x67, 0x8D, 0x44, 0x88, 0x20],  // lea eax,[eax+ecx*4+0x20]
          .init(rax: 0xFFFF_FFFF_FFFF_FFF0, rcx: 8)
        ),
        (
          [0x48, 0x8D, 0x04, 0xC0],  // lea rax,[rax+rax*8]
          .init(rax: 0x1234)
        ),
        (
          [0x48, 0x8D, 0x05, 0x34, 0x12, 0, 0],  // lea rax,[rip+0x1234]
          .init(rax: .max)
        ),
      ]
      let flags: DoryX86RFLAGS = [.reservedOne, .carry, .parity, .direction, .overflow]

      for (index, testCase) in cases.enumerated() {
        let address = UInt64(0x4A00 + index * 0x20)
        let initial = try DoryX86ArchitecturalState(
          registers: testCase.1,
          rip: address,
          rflags: flags
        )
        var interpreted = initial
        guard case .retired = DoryX86Interpreter().step(
          state: &interpreted,
          memory: try DoryX86ByteArrayMemory(baseAddress: address, bytes: testCase.0),
          mode: .long64
        ) else {
          Issue.record("interpreter did not retire tier-1 LEA fixture")
          return
        }

        var tier1 = initial
        let executor = try DoryARM64BaselineExecutor(
          maximumCodeBytes: 4096,
          tier1Enabled: true
        )
        let execution = try #require(executor.execute(
          bytes: testCase.0,
          at: address,
          mode: .long64,
          addressSpaceID: UInt64(index),
          maximumInstructions: 1,
          state: &tier1
        ))
        #expect(execution.block.tier == .tier1)
        #expect(tier1 == interpreted)
        #expect(tier1.rflags == flags)
      }
    #endif
  }

  @Test func effectiveAddressPreservesTheNativeConditionPath() throws {
    #if arch(arm64)
      let address: UInt64 = 0x4E00
      let bytes: [UInt8] = [
        0x48, 0x39, 0xD8,  // cmp rax,rbx
        0x48, 0x8D, 0x4C, 0x91, 0x08,  // lea rcx,[rcx+rdx*4+8]
        0x75, 0x04,  // jne +4
      ]
      let initial = try DoryX86ArchitecturalState(
        registers: .init(rax: 7, rcx: 0x100, rdx: 3, rbx: 9),
        rip: address,
        rflags: [.reservedOne, .carry, .direction]
      )
      let memory = try DoryX86ByteArrayMemory(baseAddress: address, bytes: bytes)
      var interpreted = initial
      for _ in 0..<3 {
        guard case .retired = DoryX86Interpreter().step(
          state: &interpreted,
          memory: memory,
          mode: .long64
        ) else {
          Issue.record("interpreter did not retire tier-1 LEA condition fixture")
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
        maximumInstructions: 3,
        state: &tier1
      ))
      #expect(execution.block.tier == .tier1)
      #expect(tier1 == interpreted)
      #expect(tier1.rip == address + UInt64(bytes.count) + 4)
      #expect(executor.diagnostics.lazyFlagMaterializations == 1)
    #endif
  }

  @Test func timestampCounterReadsTheVirtualClockInTier1AndRemainsABoundary() throws {
    #if arch(arm64)
      let address: UInt64 = 0x4F80
      let bytes: [UInt8] = [
        0x0F, 0x31,  // rdtsc; the following instruction belongs to the next block
        0xB8, 0xEF, 0xBE, 0xAD, 0xDE,  // mov eax,0xdeadbeef
      ]
      let initialFlags: DoryX86RFLAGS = [
        .reservedOne, .carry, .parity, .auxiliaryCarry, .zero, .sign, .direction, .overflow,
      ]
      var state = try DoryX86ArchitecturalState(
        registers: .init(rax: .max, rdx: .max),
        rip: address,
        rflags: initialFlags,
        tsc: 0x1122_3344_5566_7788
      )
      let memory = try DoryX86ByteArrayMemory(baseAddress: address, bytes: bytes)
      let executor = try DoryARM64BaselineExecutor(
        maximumCodeBytes: 4096,
        tier1Enabled: true
      )
      let execution = try #require(executor.executeChainedSummary(
        byteProvider: { rip, count in
          try memory.instructionBytes(at: rip, maximumCount: count)
        },
        at: address,
        mode: .long64,
        addressSpaceID: 0,
        maximumInstructions: 2,
        state: &state,
        memory: memory
      ))

      #expect(execution.tier == .tier1)
      #expect(execution.guestInstructionCount == 1)
      #expect(execution.residentBlockCount == 1)
      #expect(state.rip == address + 2)
      #expect(state.registers.rax == 0x5566_7788)
      #expect(state.registers.rdx == 0x1122_3344)
      #expect(state.rflags == initialFlags)
      #expect(executor.diagnostics.tier1CompilationAttempts == 1)
      #expect(executor.diagnostics.tier1CompilationDeclines == 0)
      #expect(executor.diagnostics.tier1CompiledBlocks == 1)
    #endif
  }

  @Test func segmentReadsPreserveUpperBitsAndTheNativeConditionPath() throws {
    #if arch(arm64)
      let address: UInt64 = 0x4FC0
      let bytes: [UInt8] = [
        0x48, 0x39, 0xF7,  // cmp rdi,rsi
        0x8C, 0xC0,  // mov ax,es
        0x8C, 0xC9,  // mov cx,cs
        0x8C, 0xD2,  // mov dx,ss
        0x8C, 0xDB,  // mov bx,ds
        0x41, 0x8C, 0xE0,  // mov r8w,fs
        0x41, 0x8C, 0xE9,  // mov r9w,gs
        0x75, 0x04,  // jne +4
      ]
      let initial = try DoryX86ArchitecturalState(
        registers: .init(
          rax: 0xAAAA_AAAA_AAAA_AAAA,
          rcx: 0xBBBB_BBBB_BBBB_BBBB,
          rdx: 0xCCCC_CCCC_CCCC_CCCC,
          rbx: 0xDDDD_DDDD_DDDD_DDDD,
          rsi: 1,
          rdi: 2,
          r8: 0xEEEE_EEEE_EEEE_EEEE,
          r9: 0xFFFF_FFFF_FFFF_FFFF
        ),
        rip: address,
        rflags: [.reservedOne, .carry, .direction],
        cs: .init(selector: 0x11, attributes: 0xA09B, limit: .max),
        ds: .init(selector: 0x22),
        es: .init(selector: 0x33),
        fs: .init(selector: 0x44),
        gs: .init(selector: 0x55),
        ss: .init(selector: 0x66)
      )
      let memory = try DoryX86ByteArrayMemory(baseAddress: address, bytes: bytes)
      var interpreted = initial
      for _ in 0..<8 {
        guard case .retired = DoryX86Interpreter().step(
          state: &interpreted,
          memory: memory,
          mode: .long64
        ) else {
          Issue.record("interpreter did not retire tier-1 segment-read fixture")
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
        maximumInstructions: 8,
        state: &tier1
      ))
      #expect(execution.block.tier == .tier1)
      #expect(tier1 == interpreted)
      #expect(tier1.rip == address + UInt64(bytes.count) + 4)
      #expect(executor.diagnostics.lazyFlagMaterializations == 1)
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

  @Test func chainedExecutionMaterializesFlagsBeforeLegacyResident() throws {
    #if arch(arm64)
      let firstAddress: UInt64 = 0x5200
      let secondAddress: UInt64 = 0x5210
      let storedAddress: UInt64 = 0x5230
      let first: [UInt8] = [
        0x48, 0x01, 0xD8,  // add rax,rbx
        0xEB, 0x0B,  // jmp 0x5210
      ]
      let second: [UInt8] = [
        0x48, 0x11, 0x15, 0x19, 0x00, 0x00, 0x00,  // adc [rip+0x19],rdx
      ]
      let initial = try DoryX86ArchitecturalState(
        registers: .init(rax: .max, rdx: 7, rbx: 1),
        rip: firstAddress,
        rflags: [.reservedOne, .direction]
      )
      let memory = try DoryX86ByteArrayMemory(byteCount: 0x5300)
      try memory.write(at: firstAddress, bytes: first)
      try memory.write(at: secondAddress, bytes: second)
      try memory.writeScalar(at: storedAddress, value: 5, byteCount: 8)
      var interpreted = initial
      for _ in 0..<3 {
        guard case .retired = DoryX86Interpreter().step(
          state: &interpreted,
          memory: memory,
          mode: .long64
        ) else {
          Issue.record("interpreter did not retire mixed-tier lazy-flags fixture")
          return
        }
      }
      try memory.writeScalar(at: storedAddress, value: 5, byteCount: 8)

      var tiered = initial
      let executor = try DoryARM64BaselineExecutor(
        maximumCodeBytes: 16 * 1024,
        tier1Enabled: true
      )
      let summary = try #require(executor.executeChainedSummary(
        byteProvider: { rip, count in
          try memory.instructionBytes(at: rip, maximumCount: count)
        },
        at: firstAddress,
        mode: .long64,
        addressSpaceID: 0,
        maximumInstructions: 3,
        state: &tiered,
        memory: memory
      ))

      #expect(summary.guestInstructionCount == 3)
      #expect(summary.residentBlockCount == 2)
      #expect(tiered == interpreted)
      #expect(tiered.rip == secondAddress + UInt64(second.count))
      #expect(try memory.read(at: storedAddress, byteCount: 8) == [
        0x0D, 0, 0, 0, 0, 0, 0, 0,
      ])
      #expect(executor.diagnostics.tier1CompilationAttempts == 2)
      #expect(executor.diagnostics.tier1CompilationDeclines == 1)
      #expect(executor.diagnostics.tier1CompiledBlocks == 1)
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

  @Test func scalarFlagControlsPreserveLazyArithmeticAndMatchTheInterpreter() throws {
    #if arch(arm64)
      let address: UInt64 = 0x5B00
      let bytes: [UInt8] = [
        0x48, 0x01, 0xD8,  // add rax, rbx
        0xFD,  // std; must update the materialized base without resolving ADD
        0xFA,  // cli; likewise leaves the arithmetic record pending
        0xF9,  // stc; resolves ADD before replacing CF
        0xF5,  // cmc
        0xF8,  // clc
        0x9F,  // lahf; observes the final arithmetic status image
      ]
      let translated = try DoryX86IRTranslator().translate(
        bytes,
        at: address,
        mode: .long64
      )
      #expect(translated.statements == [
        .binary(
          .add,
          destination: .register(.init(bank: "x86.gpr", index: 0, width: .i64)),
          source: .register(.init(bank: "x86.gpr", index: 3, width: .i64)),
          writesDestination: true
        ),
        .setDirectionFlag(enabled: true),
        .clearInterruptFlag,
        .setCarryFlag(enabled: true),
        .complementCarryFlag,
        .setCarryFlag(enabled: false),
        .loadFlagsIntoAH,
      ])

      let initial = try DoryX86ArchitecturalState(
        registers: .init(rax: 1, rbx: 1),
        rip: address,
        rflags: [.reservedOne, .carry, .interruptEnable, .overflow]
      )
      let memory = try DoryX86ByteArrayMemory(byteCount: 0x6000)
      try memory.write(at: address, bytes: bytes)
      var interpreted = initial
      for _ in 0..<7 {
        guard case .retired = DoryX86Interpreter().step(
          state: &interpreted,
          memory: memory,
          mode: .long64
        ) else {
          Issue.record("interpreter did not retire scalar flag-control fixture")
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
          maximumInstructions: 7,
          state: &state
        ))

        #expect(execution.block.tier == (tier1Enabled ? .tier1 : .baseline))
        #expect(state == interpreted)
        #expect(state.rflags.contains(.direction))
        #expect(!state.rflags.contains(.interruptEnable))
        #expect(!state.rflags.contains(.carry))
        #expect(executor.diagnostics.lazyFlagMaterializations == (tier1Enabled ? 1 : 0))
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

  @Test func registerAndImmediateStackOperationsExecuteInTier1() throws {
    #if arch(arm64)
      struct StackCase {
        let bytes: [UInt8]
        let registers: DoryX86GeneralRegisters
        let stackValue: UInt64?
      }
      let cases = [
        StackCase(
          bytes: [0x41, 0x55],  // push r13
          registers: .init(rsp: 0x1000, r13: 0x1122_3344_5566_7788),
          stackValue: nil
        ),
        StackCase(
          bytes: [0x54],  // push rsp stores its pre-decrement value
          registers: .init(rsp: 0x1000),
          stackValue: nil
        ),
        StackCase(
          bytes: [0x6A, 0xFE],  // push imm8 sign-extends to qword
          registers: .init(rsp: 0x1000),
          stackValue: nil
        ),
        StackCase(
          bytes: [0x5A],  // pop rdx
          registers: .init(rdx: 0xDEAD_BEEF, rsp: 0x1000),
          stackValue: 0x8877_6655_4433_2211
        ),
        StackCase(
          bytes: [0x5C],  // pop rsp installs the loaded value
          registers: .init(rsp: 0x1000),
          stackValue: 0x1800
        ),
      ]
      let initialFlags: DoryX86RFLAGS = [
        .reservedOne, .carry, .parity, .direction, .interruptEnable, .overflow,
      ]

      for (index, testCase) in cases.enumerated() {
        let address = UInt64(0x800 + index * 0x10)
        let interpretedMemory = try DoryX86ByteArrayMemory(byteCount: 0x2000)
        let tier1Memory = try DoryX86ByteArrayMemory(byteCount: 0x2000)
        for memory in [interpretedMemory, tier1Memory] {
          try memory.write(at: address, bytes: testCase.bytes)
          if let stackValue = testCase.stackValue {
            try memory.write(
              at: 0x1000,
              bytes: (0..<8).map {
                UInt8(truncatingIfNeeded: stackValue >> UInt64($0 * 8))
              }
            )
          }
        }

        let initial = try DoryX86ArchitecturalState(
          registers: testCase.registers,
          rip: address,
          rflags: initialFlags
        )
        var interpreted = initial
        guard case .retired = DoryX86Interpreter().step(
          state: &interpreted,
          memory: interpretedMemory,
          mode: .long64
        ) else {
          Issue.record("interpreter did not retire tier-1 stack fixture")
          return
        }

        var tier1 = initial
        let executor = try DoryARM64BaselineExecutor(
          maximumCodeBytes: 16 * 1024,
          tier1Enabled: true
        )
        let execution = try #require(executor.execute(
          bytes: testCase.bytes,
          at: address,
          mode: .long64,
          addressSpaceID: UInt64(index),
          maximumInstructions: 1,
          state: &tier1,
          memory: tier1Memory
        ))

        #expect(execution.block.tier == .tier1)
        #expect(execution.block.requiresMemoryCallbacks)
        #expect(!execution.block.requiresRestartableMemoryReads)
        #expect(tier1 == interpreted)
        #expect(tier1Memory.snapshot() == interpretedMemory.snapshot())
      }
    #endif
  }

  @Test func stackCallbacksMaterializeAndRemainRestartable() throws {
    #if arch(arm64)
      let address: UInt64 = 0x900
      let bytes: [UInt8] = [
        0x48, 0x01, 0xD8,  // add rax,rbx leaves a lazy record
        0x51,  // push rcx materializes before the helper boundary
      ]
      let initial = try DoryX86ArchitecturalState(
        registers: .init(rax: 1, rcx: 0xAABB_CCDD_EEFF_0011, rbx: 2, rsp: 0x1000),
        rip: address,
        rflags: [.reservedOne, .carry, .direction]
      )
      let interpretedMemory = try DoryX86ByteArrayMemory(byteCount: 0x2000)
      let tier1Memory = try DoryX86ByteArrayMemory(byteCount: 0x2000)
      for memory in [interpretedMemory, tier1Memory] {
        try memory.write(at: address, bytes: bytes)
      }
      var interpreted = initial
      for _ in 0..<2 {
        guard case .retired = DoryX86Interpreter().step(
          state: &interpreted,
          memory: interpretedMemory,
          mode: .long64
        ) else {
          Issue.record("interpreter did not retire lazy stack fixture")
          return
        }
      }

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
      #expect(tier1 == interpreted)
      #expect(tier1Memory.snapshot() == interpretedMemory.snapshot())
      #expect(executor.diagnostics.lazyFlagMaterializations == 1)

      for (failingBytes, registers) in [
        ([UInt8(0x53)], DoryX86GeneralRegisters(rbx: 0x1234, rsp: 4)),
        ([UInt8(0x58)], DoryX86GeneralRegisters(rax: 0x5678, rsp: 0x3000)),
      ] {
        let failedInitial = try DoryX86ArchitecturalState(
          registers: registers,
          rip: 0x700,
          rflags: [.reservedOne, .carry, .direction]
        )
        var failedState = failedInitial
        let failedMemory = try DoryX86ByteArrayMemory(byteCount: 0x1000)
        let failedExecution = try #require(executor.execute(
          bytes: failingBytes,
          at: failedState.rip,
          mode: .long64,
          addressSpaceID: UInt64(failingBytes[0]),
          maximumInstructions: 1,
          state: &failedState,
          memory: failedMemory
        ))
        #expect(failedExecution.block.tier == .tier1)
        #expect(failedExecution.exitCode == .interpreter)
        #expect(failedState == failedInitial)
        #expect(failedMemory.snapshot().allSatisfy { $0 == 0 })
      }
    #endif
  }

  @Test func stackAdmissionRejectsWritesBeforeLaterCallbacks() throws {
    let register = DoryIRRegister(bank: "x86.gpr", index: 0, width: .i64)
    let twoWrites = DoryIRBasicBlock(
      guestStart: 0,
      guestByteCount: 2,
      guestInstructionCount: 2,
      statements: [
        .stackPush(source: .register(register)),
        .stackPush(source: .register(register)),
      ],
      terminator: .next(2)
    )
    #expect(DoryARM64Tier1Emitter().compile(twoWrites) == nil)

    let readThenWrite = try DoryX86IRTranslator().translate(
      [0x58, 0x53],  // pop rax; push rbx
      at: 0x100,
      mode: .long64
    )
    let compiled = try #require(DoryARM64Tier1Emitter().compile(readThenWrite))
    #expect(compiled.requiresMemoryCallbacks)
    #expect(compiled.requiresRestartableMemoryReads)
    #expect(compiled.mayExitToInterpreter)

    #if arch(arm64)
      let initial = try DoryX86ArchitecturalState(
        registers: .init(rax: 0x1111, rbx: 0xAABB_CCDD_EEFF_0011, rsp: 0x1000),
        rip: 0x100,
        rflags: [.reservedOne, .carry, .direction]
      )
      let interpretedMemory = try DoryX86ByteArrayMemory(byteCount: 0x2000)
      let tier1Memory = try DoryX86ByteArrayMemory(byteCount: 0x2000)
      let stackValue: UInt64 = 0x8877_6655_4433_2211
      for memory in [interpretedMemory, tier1Memory] {
        try memory.write(at: 0x100, bytes: [0x58, 0x53])
        try memory.write(
          at: 0x1000,
          bytes: (0..<8).map { UInt8(truncatingIfNeeded: stackValue >> ($0 * 8)) }
        )
      }
      var interpreted = initial
      for _ in 0..<2 {
        guard case .retired = DoryX86Interpreter().step(
          state: &interpreted,
          memory: interpretedMemory,
          mode: .long64
        ) else {
          Issue.record("interpreter did not retire read-then-write stack fixture")
          return
        }
      }
      var tier1 = initial
      let execution = try #require(DoryARM64BaselineExecutor(
        maximumCodeBytes: 16 * 1024,
        tier1Enabled: true
      ).execute(
        bytes: [0x58, 0x53],
        at: tier1.rip,
        mode: .long64,
        addressSpaceID: 0,
        maximumInstructions: 2,
        state: &tier1,
        memory: tier1Memory
      ))
      #expect(execution.block.tier == .tier1)
      #expect(execution.block.requiresRestartableMemoryReads)
      #expect(tier1 == interpreted)
      #expect(tier1Memory.snapshot() == interpretedMemory.snapshot())
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
