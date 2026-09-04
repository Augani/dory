import Testing

@testable import DoryDBTX86

// Intel SDM 092 Vol. 3A §4.5.3: CPU-canonical bases on LLDT/LTR.
// https://cdrdv2-public.intel.com/922487/253668-092-sdm-vol-3a.pdf
// The selected Dory profiles support 48 linear-address bits.
@Suite struct DoryX86SystemDescriptorCanonicalTests {
  private let modes: [DoryX86ExecutionMode] = [.protected16, .protected32, .long64]

  @Test func noncanonicalLoadedBasesFaultBeforeRegisterAndBusyChanges() throws {
    for mode in modes {
      for task in [false, true] {
        for base: UInt64 in [0x0000_8000_0000_0000, 0xFFFF_7FFF_FFFF_FFFF,
                             0x0100_0000_0000_0000, 0xFF00_0000_0000_0000] {
          let (memory, initial) = try fixture(task: task, base: base, mode: mode)
          var state = initial
          let bytes = memory.snapshot()
          let result = DoryX86Interpreter().step(state: &state, memory: memory, mode: mode)
          #expect(result == .exception(.init(kind: .generalProtection, vector: 13,
            errorCode: 0x20, instructionPointer: initial.rip)))
          #expect(state == initial)
          #expect(memory.snapshot() == bytes)
        }
      }
    }
  }

  @Test func bothCanonicalBoundaryBasesLoadWithoutDereferencingTheTarget() throws {
    for mode in modes {
      for task in [false, true] {
        for base: UInt64 in [0, 0x0000_7FFF_FFFF_FFFF, 0xFFFF_8000_0000_0000, .max] {
          let (memory, initial) = try fixture(task: task, base: base, mode: mode)
          var state = initial
          guard case .retired = DoryX86Interpreter().step(state: &state, memory: memory, mode: mode) else {
            Issue.record("Canonical system descriptor did not load")
            continue
          }
          #expect((task ? state.tr : state.ldtr).base == base)
          #expect((task ? state.tr : state.ldtr).selector == 0x23)
          #expect(try memory.read(at: 0x2025, byteCount: 1) == [task ? 0x8B : 0x82])
        }
      }
    }
  }

  @Test func legacyLoadsIgnoreTheIA32eUpperSlot() throws {
    for mode: DoryX86ExecutionMode in [.protected16, .protected32] {
      for task in [false, true] {
        let (memory, initial) = try fixture(task: task, base: 0x0000_8000_1234_5678,
          mode: mode, ia32e: false)
        var state = initial
        guard case .retired = DoryX86Interpreter().step(state: &state, memory: memory, mode: mode) else {
          Issue.record("Legacy system descriptor did not load")
          continue
        }
        #expect((task ? state.tr : state.ldtr).base == 0x1234_5678)
      }
    }
  }

  private func fixture(task: Bool, base: UInt64, mode: DoryX86ExecutionMode, ia32e: Bool = true)
    throws -> (DoryX86ByteArrayMemory, DoryX86ArchitecturalState) {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x3000)
    try memory.write(at: 0x1000, bytes: [0x0F, 0x00, task ? 0xD8 : 0xD0])
    let access: UInt64 = task ? 0x89 : 0x82
    let low = UInt64(0x67) | ((base & 0xFFFF) << 16) | (((base >> 16) & 0xFF) << 32)
      | (access << 40) | (((base >> 24) & 0xFF) << 56)
    let descriptor = (0..<8).map { UInt8(truncatingIfNeeded: low >> ($0 * 8)) }
      + (0..<4).map { UInt8(truncatingIfNeeded: base >> (32 + $0 * 8)) } + [0, 0, 0, 0]
    try memory.write(at: 0x2020, bytes: descriptor)
    let state = try DoryX86ArchitecturalState(registers: .init(rax: 0x23), rip: 0x1000,
      cs: .init(selector: 0, attributes: mode == .long64 ? 0xA09B : 0xC09B, limit: .max),
      tr: .init(selector: 0x40, attributes: 0x8B, limit: 0x67, base: 0x4000),
      ldtr: .init(selector: 0x50, attributes: 0x82, limit: 0x7F, base: 0x5000),
      gdtr: .init(limit: ia32e ? 0x2F : 0x27, base: 0x2000),
      control: .init(cr0: 0x11, cr4: ia32e ? 1 << 5 : 0, efer: ia32e ? 0x500 : 0))
    return (memory, state)
  }
}
