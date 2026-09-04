import Testing

@testable import DoryDBTX86

// Intel SDM 092 Vol. 2B SYSENTER and SYSRET. SYSENTER itself clears VM and IF;
// the normal instruction boundary clears RF before execution. SYSRET restores
// RFLAGS with the exact mask 3C7FD7H, keeping RF and VM clear.
// https://cdrdv2-public.intel.com/922481/253667-092-sdm-vol-2b.pdf
@Suite struct DoryX86FastSystemTransitionFlagTests {
  @Test func sysenterClearsVMAndIFWhileTheInstructionBoundaryClearsRF() throws {
    let bytes: [UInt8] = [0x0F, 0x34]
    for mode: DoryX86ExecutionMode in [.protected32, .long64] {
      let memory = try codeMemory(bytes)
      let longMode = mode == .long64
      var state = try DoryX86ArchitecturalState(
        rip: 0x1000,
        rflags: [.reservedOne, .carry, .interruptEnable, .resume, .virtual8086],
        cs: .init(
          selector: 0x23, attributes: longMode ? 0xA0FB : 0xC0FB,
          limit: .max),
        control: .init(
          cr0: longMode ? 0x8000_0011 : 0x11,
          cr4: longMode ? 1 << 5 : 0,
          efer: longMode ? 0x500 : 0),
        modelSpecific: .init(
          systemEnterCS: 8,
          systemEnterStackPointer: 0x3000,
          systemEnterInstructionPointer: 0x2000))

      let decoded = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: mode)
      #expect(
        DoryX86Interpreter().step(state: &state, memory: memory, mode: mode)
          == .retired(decoded))
      #expect(state.rflags == [.reservedOne, .carry])
      #expect(state.rip == 0x2000)
      #expect(state.registers.rsp == 0x3000)
    }
  }

  @Test func sysretUsesTheFixedRFLAGSRestoreMaskForBothOperandSizes() throws {
    for bytes: [UInt8] in [[0x0F, 0x07], [0x48, 0x0F, 0x07]] {
      let memory = try codeMemory(bytes)
      var state = try DoryX86ArchitecturalState(
        registers: .init(rcx: 0x1234, r11: .max),
        rip: 0x1000,
        cs: .init(selector: 8, attributes: 0xA09B, limit: .max),
        control: .init(cr0: 0x8000_0011, cr4: 1 << 5, efer: 0x501),
        modelSpecific: .init(star: UInt64(0x20) << 48))

      let decoded = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: .long64)
      #expect(
        DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
          == .retired(decoded))
      #expect(state.rflags.rawValue == 0x003C_7FD7)
      #expect(!state.rflags.contains(.resume))
      #expect(!state.rflags.contains(.virtual8086))
      #expect(state.registers.r11 == .max)
    }
  }

  private func codeMemory(_ bytes: [UInt8]) throws -> DoryX86ByteArrayMemory {
    try .init(baseAddress: 0x1000, bytes: bytes + .init(repeating: 0, count: 16))
  }
}
