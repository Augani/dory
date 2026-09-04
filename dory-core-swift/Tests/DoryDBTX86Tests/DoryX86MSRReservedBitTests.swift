import Testing

@testable import DoryDBTX86

// Intel SDM 092 Vol. 4, IA32_SYSENTER_CS: bits 63:16 are reserved and
// WRMSR raises #GP(0) when software attempts to set them.
@Suite struct DoryX86MSRReservedBitTests {
  @Test func sysenterCSRejectsReservedHighBitsWithoutChangingState() throws {
    let memory = try DoryX86ByteArrayMemory(
      baseAddress: 0x1000,
      bytes: [0x0F, 0x30] + .init(repeating: 0, count: 16)) // WRMSR
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 8, rcx: 0x174, rdx: 1),
      rip: 0x1000,
      cs: .init(selector: 8, attributes: 0xA09B, limit: .max),
      modelSpecific: .init(systemEnterCS: 0x10))
    let before = state

    #expect(DoryX86Interpreter().step(
      state: &state, memory: memory, mode: .long64)
      == .exception(.init(kind: .generalProtection, vector: 13,
        errorCode: 0, instructionPointer: 0x1000)))
    #expect(state == before)
  }

  @Test func sysenterCSAcceptsAndReadsBackTheCompleteLowSelectorField() throws {
    let code: [UInt8] = [0x0F, 0x30, 0x0F, 0x32] // WRMSR; RDMSR
    let memory = try DoryX86ByteArrayMemory(
      baseAddress: 0x1000, bytes: code + .init(repeating: 0, count: 16))
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0xFFFF, rcx: 0x174, rdx: 0),
      rip: 0x1000,
      cs: .init(selector: 8, attributes: 0xA09B, limit: .max))
    let interpreter = DoryX86Interpreter()

    #expect(interpreter.step(state: &state, memory: memory, mode: .long64)
      == .retired(try DoryX86Decoder().decode(code, at: 0x1000, mode: .long64)))
    #expect(state.modelSpecific.systemEnterCS == 0xFFFF)
    state.registers.rax = 0
    state.registers.rdx = 0
    #expect(interpreter.step(state: &state, memory: memory, mode: .long64)
      == .retired(try DoryX86Decoder().decode(
        Array(code.dropFirst(2)), at: 0x1002, mode: .long64)))
    #expect(state.registers.rax == 0xFFFF)
    #expect(state.registers.rdx == 0)
  }
}
