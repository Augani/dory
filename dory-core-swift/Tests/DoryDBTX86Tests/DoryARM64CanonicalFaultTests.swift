import Testing

@testable import DoryDBTX86

@Suite struct DoryARM64CanonicalFaultTests {
  private let noncanonical: UInt64 = 0x0000_8000_0000_0000

  @Test func indirectCallsJumpsAndReturnsFallBackBeforeStateOrStackMutation() throws {
    #if arch(arm64)
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        for bytes: [UInt8] in [[0xFF, 0xD0], [0xFF, 0xE0], [0xC3], [0xC2, 0x10, 0x00]] {
          let memory = DoryX86ByteArrayMemory(byteCount: 0x200)
          try memory.write(at: 0, bytes: bytes)
          try memory.writeScalar(at: 0x100, value: noncanonical, byteCount: 8)
          var state = try DoryX86ArchitecturalState(
            registers: .init(rax: noncanonical, rsp: 0x100), rip: 0,
            rflags: [.reservedOne, .carry, .overflow], control: .init(cr2: 0x1234))
          let original = state
          let originalMemory = memory.snapshot()
          let execution = try #require(DoryARM64BaselineExecutor(
            maximumCodeBytes: 16384, optimization: optimization
          ).execute(bytes: bytes, at: 0, mode: .long64, addressSpaceID: 0,
            maximumInstructions: 1, state: &state, memory: memory))
          #expect(execution.block.mayExitToInterpreter)
          #expect(execution.exitCode == .interpreter)
          #expect(state == original)
          #expect(memory.snapshot() == originalMemory)
          #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
            == .exception(.init(kind: .generalProtection, vector: 13, errorCode: 0, instructionPointer: 0)))
          #expect(state == original)
          #expect(memory.snapshot() == originalMemory)
        }
      }
    #endif
  }

  @Test func indirectMemoryCallChecksTargetBeforePushingReturnAddress() throws {
    #if arch(arm64)
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let memory = DoryX86ByteArrayMemory(byteCount: 0x200)
        try memory.writeScalar(at: 0x80, value: noncanonical, byteCount: 8)
        var state = try DoryX86ArchitecturalState(registers: .init(rax: 0x80, rsp: 0x100), rip: 0)
        let original = state
        let before = memory.snapshot()
        let result = try #require(DoryARM64BaselineExecutor(
          maximumCodeBytes: 16384, optimization: optimization
        ).execute(bytes: [0xFF, 0x10], at: 0, mode: .long64, addressSpaceID: 0,
          maximumInstructions: 1, state: &state, memory: memory))
        #expect(result.exitCode == .interpreter)
        #expect(state == original)
        #expect(memory.snapshot() == before)
      }
    #endif
  }

  @Test func stackAddressChecksCoverBothEndsBeforeAccessibleNoncanonicalRAM() throws {
    #if arch(arm64)
      let base = noncanonical - 0x100
      let cases: [([UInt8], UInt64)] = [
        ([0x50], noncanonical + 8), ([0x58], noncanonical),
        ([0x50], noncanonical + 4), ([0x58], noncanonical - 4),
        ([0xC3], noncanonical - 4), ([0xE8, 0, 0, 0, 0], noncanonical + 4),
      ]
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        for (bytes, rsp) in cases {
          // The backing memory deliberately accepts these addresses. Only the CPU guard
          // can prevent the write or noncanonical stack read from appearing successful.
          let memory = DoryX86ByteArrayMemory(baseAddress: base, byteCount: 0x200)
          try memory.write(at: base, bytes: bytes)
          var state = try DoryX86ArchitecturalState(
            registers: .init(rax: 0xAA, rsp: rsp), rip: base, control: .init(cr2: 0x1234))
          let original = state
          let before = memory.snapshot()
          let result = try #require(DoryARM64BaselineExecutor(
            maximumCodeBytes: 16384, optimization: optimization
          ).execute(bytes: bytes, at: base, mode: .long64, addressSpaceID: 0,
            maximumInstructions: 1, state: &state, memory: memory))
          #expect(result.exitCode == .interpreter)
          #expect(state == original)
          #expect(memory.snapshot() == before)
          #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
            == .exception(.init(kind: .stackSegment, vector: 12, errorCode: 0, instructionPointer: base)))
          #expect(state == original)
          #expect(memory.snapshot() == before)
        }
      }
    #endif
  }

  @Test func overflowingStackSpanFallsBackToStackFault() throws {
    #if arch(arm64)
      let memory = DoryX86ByteArrayMemory(bytes: [0x50])
      var state = try DoryX86ArchitecturalState(registers: .init(rsp: 4), rip: 0)
      let before = state
      let result = try #require(DoryARM64BaselineExecutor(maximumCodeBytes: 4096).execute(
        bytes: [0x50], at: 0, mode: .long64, addressSpaceID: 0,
        maximumInstructions: 1, state: &state, memory: memory))
      #expect(result.exitCode == .interpreter)
      #expect(state == before)
      #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
        == .exception(.init(kind: .stackSegment, vector: 12, errorCode: 0, instructionPointer: 0)))
      #expect(state == before)
    #endif
  }

  @Test func registerOnlyPrefixIsDiscardedAndOnlySelectedConditionalTargetIsChecked() throws {
    #if arch(arm64)
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 16384, optimization: optimization)
        let bytes: [UInt8] = [0x48, 0x83, 0xC3, 1, 0xFF, 0xE0]  // add rbx,1; jmp rax
        var state = try DoryX86ArchitecturalState(registers: .init(rax: noncanonical, rbx: 9), rip: 0)
        let before = state
        let guarded = try #require(executor.execute(bytes: bytes, at: 0, mode: .long64,
          addressSpaceID: 0, maximumInstructions: 2, state: &state))
        #expect(!guarded.block.requiresMemoryCallbacks)
        #expect(guarded.block.mayExitToInterpreter)
        #expect(guarded.exitCode == .interpreter)
        #expect(state == before)
        let rip = noncanonical - 0x1000
        let branch: [UInt8] = [0x0F, 0x84, 0, 0x10, 0, 0]
        state = try .init(rip: rip, rflags: [.reservedOne, .zero])
        let takenBefore = state
        let taken = try #require(executor.execute(bytes: branch, at: rip, mode: .long64,
          addressSpaceID: 0, maximumInstructions: 1, state: &state))
        #expect(taken.exitCode == .interpreter)
        #expect(state == takenBefore)
        state = try .init(rip: rip)
        let notTaken = try #require(executor.execute(bytes: branch, at: rip, mode: .long64,
          addressSpaceID: 0, maximumInstructions: 1, state: &state))
        #expect(notTaken.exitCode == .dispatch)
        #expect(state.rip == rip + UInt64(branch.count))
      }
    #endif
  }

  @Test func staticBadTargetsDeclineAndValidLowAndHighTargetsRemainNative() throws {
    for bytes: [UInt8] in [[0xE8, 0, 0x10, 0, 0], [0xE9, 0, 0x10, 0, 0]] {
      let block = try DoryX86IRTranslator().translate(bytes, at: noncanonical - 0x1000, mode: .long64)
      #expect(DoryARM64BaselineEmitter().compile(block).tier == .interpreterFallback)
    }
    #if arch(arm64)
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        for target: UInt64 in [0x1234_5678, 0xFFFF_8000_0000_0000] {
          for bytes: [UInt8] in [[0xFF, 0xD0], [0xFF, 0xE0], [0xC3]] {
            let memory = DoryX86ByteArrayMemory(byteCount: 0x200)
            try memory.writeScalar(at: 0x100, value: target, byteCount: 8)
            var state = try DoryX86ArchitecturalState(registers: .init(rax: target, rsp: 0x100), rip: 0)
            let result = try #require(DoryARM64BaselineExecutor(
              maximumCodeBytes: 16384, optimization: optimization
            ).execute(bytes: bytes, at: 0, mode: .long64, addressSpaceID: 0,
              maximumInstructions: 1, state: &state, memory: memory))
            #expect(result.block.tier.rawValue == optimization.rawValue)
            #expect(result.exitCode == .dispatch)
            #expect(state.rip == target)
          }
        }
      }
    #endif
  }

  @Test func guardedReadsDeclineBeforeAccessingNonReplayableMemory() throws {
    #if arch(arm64)
      for bytes: [UInt8] in [[0xC3], [0xFF, 0x20]] {
        let memory = NonReplayableControlMemory()
        var state = try DoryX86ArchitecturalState(registers: .init(rax: 0x80, rsp: 0x80), rip: 0)
        let before = state
        let result = try #require(DoryARM64BaselineExecutor(maximumCodeBytes: 4096).execute(
          bytes: bytes, at: 0, mode: .long64, addressSpaceID: 0,
          maximumInstructions: 1, state: &state, memory: memory))
        #expect(result.block.requiresRestartableMemoryReads)
        #expect(result.exitCode == .interpreter)
        #expect(memory.readCount == 0)
        #expect(state == before)
      }
    #endif
  }

  @Test func nativeBatchRetiresOnlyCompletedPrefixBeforeRegisterTargetFault() throws {
    #if arch(arm64)
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let blocks: [UInt64: [UInt8]] = [
          0x100: [0x48, 0xFF, 0xC3, 0xE9, 0xF8, 0, 0, 0],
          0x200: [0x48, 0xFF, 0xC3, 0xE9, 0xF8, 0, 0, 0],
          0x300: [0xFF, 0xE0],
        ]
        let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 16384, optimization: optimization)
        func execute(_ state: inout DoryX86ArchitecturalState) throws -> DoryARM64ExecutionSummary? {
          try executor.executeChainedSummary(
            byteProvider: { address, count in Array((blocks[address] ?? []).prefix(count)) },
            codeGenerationProvider: { _, _ in 1 }, at: 0x100, mode: .long64,
            addressSpaceID: 0, maximumInstructions: 5, state: &state)
        }
        var warm = try DoryX86ArchitecturalState(registers: .init(rax: 0x400), rip: 0x100)
        #expect(try execute(&warm)?.guestInstructionCount == 5)
        var faulting = try DoryX86ArchitecturalState(registers: .init(rax: noncanonical), rip: 0x100)
        let faultExecution = try execute(&faulting)
        let result = try #require(faultExecution)
        #expect(result.guestInstructionCount == 4)
        #expect(result.residentBlockCount == 2)
        #expect(faulting.registers.rbx == 2)
        #expect(faulting.registers.rax == noncanonical)
        #expect(faulting.rip == 0x300)
        #expect(executor.nativeBatchExecutionCount > 0)
      }
    #endif
  }

  @Test func craftedIRCannotReachAddressGuardAfterCommittingMemory() {
    let register = DoryIRRegister(bank: "x86.gpr", index: 0, width: .i64)
    let memory = DoryIRMemoryAddress(displacement: 0x100, addressWidth: .i64)
    let write = DoryIRStatement.copy(destination: .memory(memory, width: .i64), source: .register(register))
    for block in [
      DoryIRBasicBlock(guestStart: 0, guestByteCount: 2, guestInstructionCount: 2,
        statements: [write], terminator: .indirect(.register(register))),
      DoryIRBasicBlock(guestStart: 0, guestByteCount: 2, guestInstructionCount: 2,
        statements: [write, .stackPush(source: .register(register))], terminator: .next(2)),
    ] {
      #expect(DoryARM64BaselineEmitter().compile(block).tier == .interpreterFallback)
    }
  }
}

private final class NonReplayableControlMemory: DoryX86Memory, @unchecked Sendable {
  private(set) var readCount = 0
  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] { [] }
  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    readCount += 1
    return [UInt8](repeating: 0, count: byteCount)
  }
  func write(at address: UInt64, bytes: [UInt8]) throws {}
  func validateWrite(at address: UInt64, byteCount: Int) throws {}
  func synchronize() {}
}
