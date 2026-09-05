import Testing
@testable import DoryDBTX86

@Suite struct DoryJITHighByteAndTests {
  @Test func highByteImmediateAndPreservesSurroundingBitsAndMatchesInterpreter() throws {
    #if arch(arm64)
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 16 * 1024, optimization: optimization)
        for register in UInt8(0)..<4 {
          for mask: UInt8 in [0, 0x7F, 0x80, 0xFD, 0xFF] {
            let bytes: [UInt8] = [0x80, 0xE4 + register, mask]
            for value in UInt64(0)...255 {
              let containing = 0x1234_ABCD_9876_005A | (value << 8)
              var registers = DoryX86GeneralRegisters(
                rax: 0x1111, rcx: 0x2222, rdx: 0x3333, rbx: 0x4444,
                rsp: 0x8000, rbp: 0x9000, rsi: 0xAAAA, rdi: 0xBBBB)
              switch register {
              case 0: registers.rax = containing
              case 1: registers.rcx = containing
              case 2: registers.rdx = containing
              default: registers.rbx = containing
              }
              let flags: DoryX86RFLAGS = [.reservedOne, .carry, .parity, .auxiliaryCarry,
                .zero, .sign, .overflow, .direction, .interruptEnable]
              let initial = try DoryX86ArchitecturalState(registers: registers, rip: 0x1000, rflags: flags)
              var reference = initial
              guard case .retired = DoryX86Interpreter().step(state: &reference,
                memory: try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: bytes), mode: .long64)
              else { Issue.record("high-byte AND reference did not retire"); continue }
              var native = initial
              let result = try #require(executor.execute(bytes: bytes, at: 0x1000, mode: .long64,
                addressSpaceID: UInt64(register) * 256 + UInt64(mask), maximumInstructions: 1, state: &native))
              #expect(result.block.tier.rawValue == optimization.rawValue)
              #expect(native == reference)
              let actual: UInt64
              switch register {
              case 0: actual = native.registers.rax
              case 1: actual = native.registers.rcx
              case 2: actual = native.registers.rdx
              default: actual = native.registers.rbx
              }
              #expect(actual == ((containing & ~UInt64(0xFF00)) | ((value & UInt64(mask)) << 8)))
            }
          }
        }
      }
    #endif
  }
}
