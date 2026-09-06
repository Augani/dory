import Testing
@testable import DoryDBTX86

@Suite struct DoryWordRegisterCompareTests {
  @Test func nativeWordCompareMatchesInterpreterAcrossTiers() throws {
    #if arch(arm64)
    let encodings: [[UInt8]] = [
      [0x66, 0x83, 0xFA, 0x03], // measured cmp dx,3
      [0x66, 0x39, 0xC8],       // measured cmp ax,cx
      [0x66, 0x83, 0xFA, 0xFF], // sign-extended immediate
      [0x66, 0x45, 0x39, 0xC8], // cmp r8w,r9w
      [0x66, 0x39, 0xC0],       // self comparison
    ]
    let values: [UInt64] = [0, 1, 3, 0x7FFF, 0x8000, 0xFFFF]
    for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
      let executor = try DoryARM64BaselineExecutor(
        maximumCodeBytes: 64 * 1024, optimization: optimization)
      for bytes in encodings {
        for lhs in values {
          for rhs in values {
            let memory = try DoryX86ByteArrayMemory(byteCount: 64)
            try memory.write(at: 0, bytes: bytes)
            let registers = DoryX86GeneralRegisters(
              rax: 0x1234_5678_ABCD_0000 | lhs,
              rcx: 0xFEDC_BA98_7654_0000 | rhs,
              rdx: 0x8877_6655_4433_0000 | lhs,
              r8: 0x1122_3344_5566_0000 | lhs,
              r9: 0x9988_7766_5544_0000 | rhs)
            var interpreted = try DoryX86ArchitecturalState(
              registers: registers, rip: 0,
              rflags: [.reservedOne, .carry, .parity, .auxiliaryCarry, .zero,
                       .sign, .overflow, .interruptEnable, .direction, .identification])
            var translated = interpreted
            let decoded = try DoryX86Decoder().decode(bytes, at: 0, mode: .long64)
            #expect(DoryX86Interpreter().step(state: &interpreted, memory: memory, mode: .long64)
              == .retired(decoded))
            let execution = try #require(executor.execute(
              bytes: bytes, at: 0, mode: .long64, addressSpaceID: 0,
              maximumInstructions: 1, state: &translated, memory: memory))
            #expect(execution.exitCode == .dispatch)
            #expect(execution.block.tier.rawValue == optimization.rawValue)
            #expect(translated == interpreted)
            #expect(translated.registers == registers)
          }
        }
      }
    }
    #endif
  }
  @Test func wordMemoryCompareMatchesInterpreterAndReadFaultsAreRestartable() throws {
    #if arch(arm64)
    let encodings: [[UInt8]] = [
      [0x66, 0x39, 0x50, 0x02], // measured cmp word ptr [rax+2],dx
      [0x66, 0x3B, 0x50, 0x02], // cmp dx,word ptr [rax+2]
      [0x66, 0x45, 0x3B, 0x08], // cmp r9w,word ptr [r8]
      [0x66, 0x3B, 0x00],       // AX also supplies the effective address
    ]
    let values: [UInt64] = [0, 1, 3, 0x7FFF, 0x8000, 0xFFFF]
    for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
      let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 64 * 1024,
        optimization: optimization)
      for bytes in encodings {
        for lhs in values {
          for rhs in values {
            let memory = try DoryX86ByteArrayMemory(byteCount: 512)
            try memory.write(at: 0, bytes: bytes)
            let word = [UInt8(truncatingIfNeeded: rhs), UInt8(truncatingIfNeeded: rhs >> 8)]
            try memory.write(at: 256, bytes: word + word)
            let before = try memory.read(at: 0, byteCount: 512)
            var interpreted = try DoryX86ArchitecturalState(
              registers: .init(rax: 256, rdx: 0xAABB_CCDD_EEFF_0000 | lhs,
                r8: 258, r9: 0x9988_7766_5544_0000 | lhs), rip: 0,
              rflags: [.reservedOne, .carry, .parity, .auxiliaryCarry, .zero, .sign,
                       .overflow, .interruptEnable, .direction])
            var native = interpreted
            let decoded = try DoryX86Decoder().decode(bytes, at: 0, mode: .long64)
            #expect(DoryX86Interpreter().step(state: &interpreted, memory: memory, mode: .long64)
              == .retired(decoded))
            let execution = try #require(executor.execute(bytes: bytes, at: 0, mode: .long64,
              addressSpaceID: 0, maximumInstructions: 1, state: &native, memory: memory))
            #expect(execution.exitCode == .dispatch)
            #expect(execution.block.tier.rawValue == optimization.rawValue)
            #expect(native == interpreted)
            #expect(try memory.read(at: 0, byteCount: 512) == before)
          }
        }
        let memory = try DoryX86ByteArrayMemory(byteCount: 64)
        try memory.write(at: 0, bytes: bytes)
        let initial = try DoryX86ArchitecturalState(
          registers: .init(rax: 256, rdx: 123, r8: 258, r9: 456), rip: 0,
          rflags: [.reservedOne, .carry, .overflow, .direction])
        var state = initial
        let execution = try #require(executor.execute(bytes: bytes, at: 0, mode: .long64,
          addressSpaceID: 0, maximumInstructions: 1, state: &state, memory: memory))
        #expect(execution.block.tier.rawValue == optimization.rawValue)
        #expect(execution.exitCode == .interpreter)
        #expect(state == initial)
      }
    }
    #endif
  }

}
