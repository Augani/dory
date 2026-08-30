import Testing

@testable import DoryDBTX86

@Suite struct DoryX86InterpreterTests {
  private let interpreter = DoryX86Interpreter()

  @Test func executesIntegerControlFlowWithoutHostAssumptions() throws {
    // mov rax,5; mov rcx,3; add rax,rcx; mov rdx,8; cmp rax,rdx;
    // jne +10; mov rbx,42; hlt
    let program: [UInt8] = [
      0x48, 0xB8, 5, 0, 0, 0, 0, 0, 0, 0,
      0x48, 0xB9, 3, 0, 0, 0, 0, 0, 0, 0,
      0x48, 0x01, 0xC8,
      0x48, 0xBA, 8, 0, 0, 0, 0, 0, 0, 0,
      0x48, 0x39, 0xD0,
      0x75, 10,
      0x48, 0xBB, 42, 0, 0, 0, 0, 0, 0, 0,
      0xF4,
    ]
    let memory = DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: program + .init(repeating: 0, count: 64))
    var state = try DoryX86ArchitecturalState(rip: 0x1000)
    var result: DoryX86InterpreterResult = .exception(.init(kind: .invalidOpcode, vector: 6, instructionPointer: 0))
    for _ in 0..<8 {
      result = interpreter.step(state: &state, memory: memory, mode: .long64)
      if case .halted = result { break }
    }
    guard case .halted = result else {
      Issue.record("program did not halt: \(result)")
      return
    }
    #expect(state.registers.rax == 8)
    #expect(state.registers.rbx == 42)
    #expect(state.rflags.contains(.zero))
  }

  @Test func callAndReturnPreserveTheArchitecturalStack() throws {
    // call +1; hlt; mov rax,9; ret
    let program: [UInt8] = [
      0xE8, 1, 0, 0, 0,
      0xF4,
      0x48, 0xB8, 9, 0, 0, 0, 0, 0, 0, 0,
      0xC3,
    ]
    let memory = DoryX86ByteArrayMemory(baseAddress: 0x2000, bytes: program + .init(repeating: 0, count: 0x100))
    var registers = DoryX86GeneralRegisters()
    registers.rsp = 0x2100
    var state = try DoryX86ArchitecturalState(registers: registers, rip: 0x2000)
    for _ in 0..<4 { _ = interpreter.step(state: &state, memory: memory, mode: .long64) }
    #expect(state.registers.rax == 9)
    #expect(state.registers.rsp == 0x2100)
    #expect(state.rip == 0x2006)
  }

  @Test func cpuidCannotAdvertiseUnimplementedAVX() throws {
    let memory = DoryX86ByteArrayMemory(baseAddress: 0x3000, bytes: [0x0F, 0xA2] + .init(repeating: 0, count: 16))
    let registers = DoryX86GeneralRegisters(rax: 1)
    var state = try DoryX86ArchitecturalState(registers: registers, rip: 0x3000)
    _ = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(state.registers.rcx & (1 << 28) == 0)
  }

  @Test func memoryFaultIsPreciseAndLeavesInstructionRestartable() throws {
    let memory = DoryX86ByteArrayMemory(baseAddress: 0x4000, bytes: [0x48, 0x8B, 0x00] + .init(repeating: 0, count: 16))
    let registers = DoryX86GeneralRegisters(rax: 0xDEAD_0000)
    var state = try DoryX86ArchitecturalState(registers: registers, rip: 0x4000)
    let result = interpreter.step(state: &state, memory: memory, mode: .long64)
    #expect(result == .exception(.init(
      kind: .pageFault,
      vector: 14,
      errorCode: 0,
      instructionPointer: 0x4000,
      linearAddress: 0xDEAD_0000
    )))
    #expect(state.rip == 0x4000)
    #expect(state.control.cr2 == 0xDEAD_0000)
  }
}
