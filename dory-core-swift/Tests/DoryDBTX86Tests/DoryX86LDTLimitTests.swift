import Testing

@testable import DoryDBTX86

// The cached LDT limit is a segment limit, not the16-bit GDTR limit.
// Intel SDM Vol. 3A §§3.4.5/3.5.1: descriptor granularity and selector bounds.
@Suite struct DoryX86LDTLimitTests {
  @Test func loadingSegmentsFromWideLDTLimitsDoesNotNarrowOrTrap() throws {
    for mode: DoryX86ExecutionMode in [.protected16, .protected32, .long64] {
      for limit: UInt32 in [0x27, 0xFFFF, 0x1_0000, 0x1_0001, .max] {
        let (memory, initial) = try fixture(code: [0x8E, 0xD8], limit: limit, mode: mode)
        var state = initial
        guard case .retired = DoryX86Interpreter().step(state: &state, memory: memory, mode: mode) else {
          Issue.record("Valid LDT data descriptor was rejected")
          continue
        }
        #expect(state.ds.selector == 0x24)
        #expect(state.ds.base == 0x1234_0000)
        #expect(state.ds.limit == 0xFFFF)
        #expect(state.ldtr == initial.ldtr)
        #expect(state.rflags == initial.rflags)
      }
    }
  }

  @Test func descriptorInspectionUsesTheFullCachedLDTLimit() throws {
    // LAR EAX,ECX; LSL EAX,ECX; VERR CX; VERW CX.
    for code: [UInt8] in [[0x0F, 0x02, 0xC1], [0x0F, 0x03, 0xC1],
                          [0x0F, 0x00, 0xE1], [0x0F, 0x00, 0xE9]] {
      for limit: UInt32 in [0x27, 0x1_0000, 0x1_0001, .max] {
        let (memory, initial) = try fixture(code: code, limit: limit, mode: .protected32)
        var state = initial
        guard case .retired = DoryX86Interpreter().step(state: &state, memory: memory, mode: .protected32) else {
          Issue.record("LDT inspection did not retire")
          continue
        }
        #expect(state.rflags.contains(.zero))
        if code[1] == 0x03 { #expect(state.registers.rax == 0xFFFF) }
        if code[1] == 0x02 { #expect(state.registers.rax == 0x0040_9300) }
        #expect(state.ldtr == initial.ldtr)
      }
    }
  }

  @Test func descriptorPastActualLimitStillRejects() throws {
    for limit: UInt32 in [0, 0x20, 0x26] {
      let (memory, initial) = try fixture(code: [0x0F, 0x03, 0xC1], limit: limit, mode: .protected32)
      var state = initial
      state.rflags.insert(.zero)
      guard case .retired = DoryX86Interpreter().step(state: &state, memory: memory, mode: .protected32) else {
        Issue.record("Invalid LSL should retire with ZF clear")
        continue
      }
      #expect(!state.rflags.contains(.zero))
      #expect(state.registers.rax == initial.registers.rax)
    }
  }

  private func fixture(code: [UInt8], limit: UInt32, mode: DoryX86ExecutionMode)
    throws -> (DoryX86ByteArrayMemory, DoryX86ArchitecturalState) {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x3000)
    try memory.write(at: 0x1000, bytes: code)
    try memory.writeScalar(at: 0x2020, value: 0x1240_9334_0000_FFFF, byteCount: 8)
    let state = try DoryX86ArchitecturalState(registers: .init(rax: 0x24, rcx: 0x24), rip: 0x1000,
      cs: .init(selector: 8, attributes: mode == .long64 ? 0xA09B : 0xC09B, limit: .max),
      ds: .init(selector: 0x10, attributes: 0xC093, limit: .max),
      ldtr: .init(selector: 0x28, attributes: 0x82, limit: limit, base: 0x2000),
      control: .init(cr0: 0x11, cr4: mode == .long64 ? 1 << 5 : 0,
        efer: mode == .long64 ? 0x500 : 0))
    return (memory, state)
  }
}
