import Testing

@testable import DoryDBTX86

@Suite struct DoryX86HypervisorBoundaryTests {
  @Test func cpuidUsesGuestExtendedStateControls() throws {
    let interpreter = DoryX86Interpreter(profile: .init(
      identifier: "test.xstate-query",
      features: [.x87, .fxsave, .sse, .sse2, .xsave, .avx],
      physicalAddressBits: 40, linearAddressBits: 48, virtualTSCFrequencyHz: 1_000_000_000
    ))
    for (leaf, xcr0, expected): (UInt64, UInt64, UInt64) in [(1, 1, 1 << 27), (13, 1, 576), (13, 7, 832)] {
      let memory = DoryX86ByteArrayMemory(bytes: [0x0F, 0xA2])
      var state = try DoryX86ArchitecturalState(
        registers: .init(rax: leaf), rip: 0, control: .init(cr4: 1 << 18, xcr0: xcr0)
      )
      guard case .retired = interpreter.step(state: &state, memory: memory, mode: .long64) else {
        Issue.record("CPUID query faulted")
        continue
      }
      if leaf == 1 {
        #expect(state.registers.rcx & (1 << 27) == expected)
      } else {
        #expect(state.registers.rbx == expected)
      }
    }
  }

  @Test func hiddenTimestampInstructionsFaultBeforePrivilegeChecks() throws {
    for auxiliary in [false, true] {
      for privilege: UInt16 in [0, 3] {
        let baseline = DoryX86CPUProfile.compatibleV1
        let features = auxiliary ? baseline.features : baseline.features.subtracting([.tsc])
        let interpreter = DoryX86Interpreter(profile: .init(
          identifier: "test.hidden-tsc",
          features: features,
          physicalAddressBits: baseline.physicalAddressBits,
          linearAddressBits: baseline.linearAddressBits,
          virtualTSCFrequencyHz: baseline.virtualTSCFrequencyHz
        ))
        let memory = DoryX86ByteArrayMemory(bytes: auxiliary ? [0x0F, 0x01, 0xF9] : [0x0F, 0x31])
        var state = try DoryX86ArchitecturalState(
          registers: .init(rax: 11, rcx: 12, rdx: 13),
          rip: 0,
          cs: .init(selector: privilege, attributes: privilege == 0 ? 0xA09B : 0xA0FB, limit: .max),
          control: .init(cr4: 1 << 2),
          tsc: 0x1122_3344_5566_7788
        )
        let before = state
        #expect(interpreter.step(state: &state, memory: memory, mode: .long64)
          == .exception(.init(kind: .invalidOpcode, vector: 6, instructionPointer: 0)))
        #expect(state == before)
      }
    }
  }

  @Test func unsupportedVirtualizationCallsFaultWithoutGuestEffects() throws {
    for opcode: UInt8 in [0xC1, 0xD9] {  // VMCALL and VMMCALL
      for privilege: UInt16 in [0, 3] {
        for call: UInt64 in [7, 12, 17, 18, 35, .max] {
          let bytes: [UInt8] = [0x0F, 0x01, opcode] + .init(repeating: 0xA5, count: 61)
          let memory = DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: bytes)
          var state = try DoryX86ArchitecturalState(
            registers: .init(rax: call, rdx: 8, rsi: 0x1020, rdi: 0),
            rip: 0x1000,
            cs: .init(selector: privilege, attributes: privilege == 0 ? 0xA09B : 0xA0FB, limit: .max)
          )
          let before = state
          let result = DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)

          #expect(result == .exception(.init(kind: .invalidOpcode, vector: 6, instructionPointer: 0x1000)))
          #expect(state == before)
          #expect(try memory.read(at: 0x1000, byteCount: bytes.count) == bytes)
        }
      }
    }
  }
}
