import Testing
@testable import DoryDBTX86

@Suite struct DoryJITWordMemoryCompareTests {
  @Test func gsRelativeWordCompareMatchesInterpreterAndPreservesMemory() throws {
    #if arch(arm64)
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 16 * 1024, optimization: optimization)
        for immediate: UInt8 in [0, 1, 0x7F, 0x80, 0xFF] {
          // cmp word ptr gs:[rip+55],sign-extended imm8; operand is at GS.base+64.
          let code: [UInt8] = [0x65, 0x66, 0x83, 0x3D, 55, 0, 0, 0, immediate]
          for value: UInt16 in [0, 1, 0xF, 0x10, 0x7F, 0x80, 0xFF, 0x100, 0x7FFF, 0x8000, 0xFF80, 0xFFFF] {
            let memory = try DoryX86ByteArrayMemory(byteCount: 512)
            try memory.write(at: 0, bytes: code)
            try memory.write(at: 320, bytes: [UInt8(truncatingIfNeeded: value), UInt8(value >> 8)])
            let beforeBytes = try memory.read(at: 0, byteCount: 512)
            var initial = try DoryX86ArchitecturalState(registers: .init(rax: 0x1234, rdx: 0xABCD),
              rip: 0, rflags: [.reservedOne, .carry, .parity, .auxiliaryCarry, .zero, .sign,
                .overflow, .direction, .interruptEnable])
            initial.gs.base = 256
            var reference = initial
            guard case .retired = DoryX86Interpreter().step(state: &reference, memory: memory, mode: .long64)
            else { Issue.record("word compare reference did not retire"); continue }
            var native = initial
            let result = try #require(executor.execute(bytes: code, at: 0, mode: .long64,
              addressSpaceID: UInt64(immediate), maximumInstructions: 1, state: &native, memory: memory))
            #expect(result.block.tier.rawValue == optimization.rawValue)
            #expect(native == reference)
            #expect(try memory.read(at: 0, byteCount: 512) == beforeBytes)
          }
        }
      }
    #endif
  }

  @Test func wordCompareFaultKeepsPriorRegistersFlagsAndInstructionPointer() throws {
    #if arch(arm64)
      let code: [UInt8] = [0x65, 0x66, 0x83, 0x3D, 55, 0, 0, 0, 0]
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let memory = try DoryX86ByteArrayMemory(byteCount: 321)
        try memory.write(at: 0, bytes: code)
        try memory.write(at: 320, bytes: [0xAA])
        var initial = try DoryX86ArchitecturalState(registers: .init(rax: 0x1234), rip: 0,
          rflags: [.reservedOne, .carry, .overflow, .direction])
        initial.gs.base = 256
        var state = initial
        let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 4096, optimization: optimization)
        let result = try #require(executor.execute(bytes: code, at: 0, mode: .long64,
          addressSpaceID: 0, maximumInstructions: 1, state: &state, memory: memory))
        #expect(result.exitCode == .interpreter)
        #expect(state == initial)
        #expect(try memory.read(at: 320, byteCount: 1) == [0xAA])
      }
    #endif
  }
}
