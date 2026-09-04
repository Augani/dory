import Testing

@testable import DoryDBTX86

// Intel SDM092 Vol. 2B MOV DR pp. 4-35/36; Vol. 3A 2.8.5;
// Vol. 3B 20.2.2-4 and 20.3.1.3. These cover register access, not breakpoints.
@Suite struct DoryX86DebugRegisterTests {
  @Test func transfersUse64BitsOnlyIn64BitModeAndIgnoreOperandSizePrefixes() throws {
    for mode: DoryX86ExecutionMode in [.real16, .protected16, .protected32, .long64] {
      for compatibility in [false, true] where !compatibility || mode == .protected16 || mode == .protected32 {
        for prefix: [UInt8] in [[], [0x66]] + (mode == .long64 ? [[0x48], [0x49], [0x66, 0x49]] : []) {
          for index: UInt8 in 0...3 {
            for write in [false, true] {
              let bytes = prefix + [0x0F, write ? 0x23 : 0x21, 0xC0 | (index << 3)]
              let memory = try memory(bytes)
              let beforeMemory = memory.snapshot()
              var state = try state(mode, compatibility: compatibility)
              let operand: DoryX86GeneralRegister = prefix.contains(0x49) ? .r8 : .rax
              // Noncanonical addresses are legal debug-register values. MOV DR
              // does not perform a memory access or an address-canonicality check.
              let value: UInt64 = 0x9876_5432_89AB_CDEF
              state.registers[operand] = value
              setDebug(index, value: write ? 0 : value, in: &state)
              let before = state
              var expected = before
              let transferred = mode == .long64 ? value : value & 0xffff_ffff
              if write { setDebug(index, value: transferred, in: &expected) }
              else { expected.registers[operand] = transferred }
              expected.rip += UInt64(bytes.count)
              try retire(&state, memory: memory, mode: mode)
              // Arithmetic flags are undefined on a successful MOV DR. This
              // invariant deliberately does not constrain those flag values.
              expected.rflags = state.rflags
              #expect(state == expected)
              #expect(memory.snapshot() == beforeMemory)
            }
          }
        }
      }
    }
  }

  @Test func DR4AndDR5AliasDR6AndDR7WithDEClear() throws {
    for mode: DoryX86ExecutionMode in [.real16, .protected16, .protected32, .long64] {
      for (alias, direct): (UInt8, UInt8) in [(4, 6), (5, 7)] {
        for write in [false, true] {
          var aliasState = try state(mode)
          // Upper bits are ignored before reserved-bit validation outside64.
          aliasState.registers.rax = mode == .long64 ? 0x00AA_0005 : 0xFEDC_BA98_00AA_0005
          var directState = aliasState
          let aliasMemory = try memory([0x66, 0x0F, write ? 0x23 : 0x21, 0xC0 | (alias << 3)])
          let directMemory = try memory([0x66, 0x0F, write ? 0x23 : 0x21, 0xC0 | (direct << 3)])
          try retire(&aliasState, memory: aliasMemory, mode: mode)
          try retire(&directState, memory: directMemory, mode: mode)
          #expect(aliasState == directState)
          if write {
            #expect((direct == 6 ? aliasState.debug.dr6 : aliasState.debug.dr7)
              == (direct == 6 ? 0x00AA_0005 : 0x00AA_0405))
          } else {
            #expect(aliasState.registers.rax == (direct == 6 ? 0xFFFF_0FF0 : 0x400))
          }
        }
      }
    }
  }

  @Test func reservedHighBitsRejectDR6DR7AndTheirAliasesWithoutMutation() throws {
    for index: UInt8 in [4, 5, 6, 7] {
      for highBit: UInt64 in [1 << 32, 1 << 47, 1 << 63] {
        let memory = try memory([0x0F, 0x23, 0xC0 | (index << 3)])
        var state = try state(.long64)
        state.registers.rax = highBit | 0x405
        try expectFault(.generalProtection, vector: 13, errorCode: 0,
          state: &state, memory: memory, mode: .long64)
      }
    }
  }

  @Test func invalidAliasesAndEncodingsTakePriorityOverGeneralDetectAndPrivilege() throws {
    for mode: DoryX86ExecutionMode in [.real16, .protected16, .protected32, .long64] {
      for cpl: UInt16 in [0, 3] {
        for write in [false, true] {
          for index: UInt8 in [4, 5] {
            let memory = try memory([0x0F, write ? 0x23 : 0x21, 0xC0 | (index << 3)])
            var state = try state(mode, cpl: cpl)
            state.control.cr4 |= 1 << 3
            state.debug.dr7 |= 1 << 13
            try expectFault(.invalidOpcode, vector: 6, state: &state, memory: memory, mode: mode)
          }
        }
      }
    }
    for prefix: UInt8 in [0xF0, 0x44, 0x4C] {
      for write in [false, true] {
        var state = try state(.long64, cpl: 3)
        state.debug.dr7 |= 1 << 13
        let memory = try memory([prefix, 0x0F, write ? 0x23 : 0x21, 0xC0])
        try expectFault(.invalidOpcode, vector: 6, state: &state, memory: memory, mode: .long64)
      }
    }
  }

  @Test func privilegeAndVirtual8086RejectOtherwiseValidAccesses() throws {
    for mode: DoryX86ExecutionMode in [.protected16, .protected32, .long64] {
      for index: UInt8 in 0...7 {
        for write in [false, true] {
          let memory = try memory([0x0F, write ? 0x23 : 0x21, 0xC0 | (index << 3)])
          var state = try state(mode, cpl: 3)
          try expectFault(.generalProtection, vector: 13, errorCode: 0,
            state: &state, memory: memory, mode: mode)
          if mode != .long64 {
            state.cs.selector = 0 // VM86 CPL is not obtained from CS selector bits.
            state.rflags.insert(.virtual8086)
            try expectFault(.generalProtection, vector: 13, errorCode: 0,
              state: &state, memory: memory, mode: mode)
          }
        }
      }
    }
  }

  @Test func generalDetectPublishesOnlyDebugStatusAndPreservesFaultingOperands() throws {
    // GD ahead of an illegal DR6/7 write is also reported empirically, for Intel
    // and AMD: https://lore.kernel.org/all/20260612230113.684301-3-seanjc@google.com/
    for mode: DoryX86ExecutionMode in [.real16, .protected16, .protected32, .long64] {
      for index: UInt8 in 0...7 {
        for write in [false, true] {
          let memory = try memory([0x0F, write ? 0x23 : 0x21, 0xC0 | (index << 3)])
          var state = try state(mode)
          state.registers.rax = 0xDEAD_BEEF_1234_5678
          state.rflags.insert([.carry, .zero, .resume, .trap])
          // Inject prior status to verify the fault does not erase other debug
          // status. No instruction/data-breakpoint execution is claimed here.
          state.debug.dr6 = 0xFFFE_CFF5
          state.debug.dr7 |= 1 << 13
          try expectGeneralDetect(state: &state, memory: memory, mode: mode)
          // A rejected high-half write is still rejected after GD has cleared.
          if write, mode == .long64, index >= 4 {
            try expectFault(.generalProtection, vector: 13, errorCode: 0,
              state: &state, memory: memory, mode: mode)
          } else {
            try retire(&state, memory: memory, mode: mode)
            #expect(state.rip == 0x103)
          }
        }
      }
    }
  }

  @Test func DoryMOVDRPolicyUsesReportedIntelGeneralDetectPriorityOverCPL() throws {
    // External empirical scope: Christopherson, Skylake/Icelake/Emerald Rapids;
    // AMD CPL #GP ordering differs. Neither ordering is prescribed by the SDM.
    // https://lore.kernel.org/all/20260612230113.684301-6-seanjc@google.com/
    // This is Dory's bounded compatibility choice, not a physical-reference receipt.
    for mode: DoryX86ExecutionMode in [.protected16, .protected32, .long64] {
      for write in [false, true] {
        let memory = try memory([0x0F, write ? 0x23 : 0x21, 0xF8]) // DR7, RAX
        var state = try state(mode, cpl: 3)
        state.registers.rax = .max
        state.debug.dr7 |= 1 << 13
        try expectGeneralDetect(state: &state, memory: memory, mode: mode)
        try expectFault(.generalProtection, vector: 13, errorCode: 0,
          state: &state, memory: memory, mode: mode)
      }
    }
  }

  @Test func settingGeneralDetectRetiresThenNextDebugAccessFaultsAndCanRetry() throws {
    let memory = try memory([0x0F, 0x23, 0xF8, 0x0F, 0x21, 0xF0]) // MOV DR7,RAX; MOV RAX,DR6
    var state = try state(.long64)
    state.registers.rax = 0x2400
    try retire(&state, memory: memory, mode: .long64)
    #expect(state.rip == 0x103)
    #expect(state.debug.dr7 == 0x2400)
    try expectGeneralDetect(state: &state, memory: memory, mode: .long64)
    try retire(&state, memory: memory, mode: .long64)
    #expect(state.rip == 0x106)
    #expect(state.registers.rax == 0xFFFF_2FF0)
  }

  private func expectGeneralDetect(state: inout DoryX86ArchitecturalState,
    memory: DoryX86ByteArrayMemory, mode: DoryX86ExecutionMode) throws {
    var expected = state
    expected.debug.dr6 |= (1 << 13) | (1 << 16)
    expected.debug.dr7 &= ~UInt64(1 << 13)
    let beforeMemory = memory.snapshot()
    #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: mode)
      == .exception(.init(kind: .debug, vector: 1, instructionPointer: expected.rip)))
    #expect(state == expected)
    #expect(memory.snapshot() == beforeMemory)
  }

  private func expectFault(_ kind: DoryX86Exception.Kind, vector: UInt8, errorCode: UInt32? = nil,
    state: inout DoryX86ArchitecturalState, memory: DoryX86ByteArrayMemory,
    mode: DoryX86ExecutionMode) throws {
    let before = state
    let beforeMemory = memory.snapshot()
    #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: mode)
      == .exception(.init(kind: kind, vector: vector, errorCode: errorCode, instructionPointer: before.rip)))
    #expect(state == before)
    #expect(memory.snapshot() == beforeMemory)
  }

  private func retire(_ state: inout DoryX86ArchitecturalState,
    memory: DoryX86ByteArrayMemory, mode: DoryX86ExecutionMode) throws {
    guard case .retired = DoryX86Interpreter().step(state: &state, memory: memory, mode: mode) else {
      Issue.record("Expected MOV DR to retire")
      return
    }
  }

  private func memory(_ bytes: [UInt8]) throws -> DoryX86ByteArrayMemory {
    let memory = DoryX86ByteArrayMemory(byteCount: 0x2000)
    try memory.write(at: 0x100, bytes: bytes)
    return memory
  }

  private func state(_ mode: DoryX86ExecutionMode, cpl: UInt16 = 0,
    compatibility: Bool = false) throws -> DoryX86ArchitecturalState {
    try .init(registers: .init(rax: 0xA5A5_A5A5_A5A5_A5A5, rbx: 0x6789), rip: 0x100,
      cs: .init(selector: cpl, attributes: mode == .long64 ? 0xA09B : 0x009B, limit: .max),
      control: .init(cr0: mode == .real16 ? 0x10 : 0x11, efer: compatibility ? 1 << 10 : 0))
  }

  private func setDebug(_ index: UInt8, value: UInt64, in state: inout DoryX86ArchitecturalState) {
    switch index {
    case 0: state.debug.dr0 = value
    case 1: state.debug.dr1 = value
    case 2: state.debug.dr2 = value
    default: state.debug.dr3 = value
    }
  }
}
