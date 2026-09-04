import Testing

@testable import DoryDBTX86

// Intel SDM: Vol. 3C CPL filtering specifies real-mode CPL 0 / v8086 CPL 3;
// Vol. 3A 2.3.1 excludes VM from IA-32e, and 5.6 defines user paging accesses;
// Vol. 2A IN/CLI and Vol. 2B MOV CR/RDTSC define the instruction-specific checks.
@Suite struct DoryX86ModePrivilegeTests {
  @Test func privilegedInstructionsDoNotUseVirtual8086SelectorBitsAsCPL() throws {
    let instructions: [[UInt8]] = [
      [0x0F, 0x20, 0xC0], [0x0F, 0x22, 0xC0], // MOV from/to CR0
      [0x0F, 0x21, 0xC0], [0x0F, 0x23, 0xC0], // MOV from/to DR0
      [0x0F, 0x06], [0x0F, 0x08], [0x0F, 0x09], // CLTS, INVD, WBINVD
      [0x0F, 0x01, 0xF0], [0x0F, 0x32], [0x0F, 0x30], // LMSW, RDMSR, WRMSR
    ]
    for mode: DoryX86ExecutionMode in [.protected16, .protected32] {
      for selector: UInt16 in [0, 1, 2, 3] {
        for bytes in instructions {
          var state = try makeState(mode: mode, selector: selector, virtual8086: true)
          let before = state
          let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: bytes)
          #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: mode)
            == generalProtection)
          #expect(state == before)
          #expect(memory.snapshot() == bytes)
        }
      }
    }
  }

  @Test func realModePrivilegedInstructionsIgnoreSelectorLowBits() throws {
    for bytes: [UInt8] in [
      [0x0F, 0x20, 0xC0], [0x0F, 0x22, 0xC0],
      [0x0F, 0x21, 0xC0], [0x0F, 0x23, 0xC0],
      [0x0F, 0x06], [0x0F, 0x08], [0x0F, 0x09],
      [0x0F, 0x01, 0xF0], [0x0F, 0x32], [0x0F, 0x30],
    ] {
      let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: bytes)
      var reference = try makeState(mode: .real16, selector: 0)
      let decoded = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: .real16)
      #expect(DoryX86Interpreter().step(state: &reference, memory: memory, mode: .real16)
        == .retired(decoded))
      for selector: UInt16 in [1, 2, 3] {
        var state = try makeState(mode: .real16, selector: selector)
        #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .real16)
          == .retired(decoded))
        reference.cs.selector = selector
        #expect(state == reference)
      }
    }
  }

  @Test func cliAndSTIUseModePrivilegeWithVirtualExtensionsDisabled() throws {
    for opcode: UInt8 in [0xFA, 0xFB] {
      let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: [opcode])
      for mode: DoryX86ExecutionMode in [.real16, .protected16, .protected32] {
        for ioPrivilege: UInt64 in [0, 3] {
          let virtual = mode != .real16
          var state = try makeState(mode: mode, selector: virtual ? 0 : 3, virtual8086: virtual)
          state.rflags = .init(rawValue: state.rflags.rawValue | (ioPrivilege << 12))
          if opcode == 0xFA { state.rflags.insert(.interruptEnable) }
          let before = state
          let result = DoryX86Interpreter().step(state: &state, memory: memory, mode: mode)
          if virtual && ioPrivilege < 3 {
            #expect(result == generalProtection)
            #expect(state == before)
          } else {
            let decoded = try DoryX86Decoder().decode([opcode], at: 0x1000, mode: mode)
            #expect(result == .retired(decoded))
            #expect(state.rflags.contains(.interruptEnable) == (opcode == 0xFB))
          }
        }
      }
    }
  }

  @Test func timestampDisableTreatsVirtual8086AsUserAndRealModeAsSupervisor() throws {
    let bytes: [UInt8] = [0x0F, 0x31]
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: bytes)
    for mode: DoryX86ExecutionMode in [.real16, .protected16, .protected32] {
      for disabled in [false, true] {
        var state = try makeState(mode: mode, selector: mode == .real16 ? 3 : 0,
          virtual8086: mode != .real16)
        state.control.cr4 = disabled ? 1 << 2 : 0
        state.tsc = 0x1234_5678_9ABC_DEF0
        let before = state
        let result = DoryX86Interpreter().step(state: &state, memory: memory, mode: mode)
        if disabled && mode != .real16 {
          #expect(result == generalProtection)
          #expect(state == before)
        } else {
          let decoded = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: mode)
          #expect(result == .retired(decoded))
          #expect(state.registers.rax == 0x9ABC_DEF0)
          #expect(state.registers.rdx == 0x1234_5678)
        }
      }
    }
  }

  @Test func virtual8086PortIOAlwaysConsultsTSSBitmapIncludingIOPLThree() throws {
    for opcode: UInt8 in [0xE4, 0xE6] { // IN AL,0x20 / OUT 0x20,AL
      for ioPrivilege: UInt64 in [0, 3] {
        for denied in [false, true] {
          let bytes: [UInt8] = [opcode, 0x20]
          let memory = try DoryX86ByteArrayMemory(byteCount: 0x4000)
          try memory.write(at: 0x1000, bytes: bytes)
          try memory.writeScalar(at: 0x2066, value: 0x68, byteCount: 2)
          try memory.writeScalar(at: 0x206C, value: denied ? 1 : 0, byteCount: 1)
          var state = try makeState(mode: .protected16, selector: 0, virtual8086: true)
          state.rflags = .init(rawValue: state.rflags.rawValue | (ioPrivilege << 12))
          state.tr = .init(selector: 8, attributes: 0x8B, limit: 0x80, base: 0x2000)
          let before = state
          let beforeMemory = memory.snapshot()
          let bus = ModePrivilegeIOBus()
          let result = DoryX86Interpreter().step(state: &state, memory: memory,
            mode: .protected16, ioBus: bus)
          if denied {
            #expect(result == generalProtection)
            #expect(state == before)
            #expect(bus.accessCount == 0)
          } else {
            let decoded = try DoryX86Decoder().decode(bytes, at: 0x1000, mode: .protected16)
            #expect(result == .retired(decoded))
            #expect(bus.accessCount == 1)
            #expect(state.registers.rax == (opcode == 0xE4 ? 0x5A : 0x10))
          }
          #expect(memory.snapshot() == beforeMemory)
        }
      }
    }
  }

  @Test func pagingContextNormalizesPrivilegeForRealVirtualAndIA32eModes() throws {
    for mode: DoryX86ExecutionMode in [.real16, .protected16, .protected32, .long64] {
      for selector: UInt16 in [0, 1, 2, 3] {
        for virtual in [false, true] {
          for ia32e in [false, true] {
            var state = try makeState(mode: mode, selector: selector, virtual8086: virtual)
            state.control.efer = ia32e ? 1 << 10 : 0
            let expected: UInt8 = mode == .real16 ? 0
              : mode != .long64 && virtual && !ia32e ? 3 : UInt8(selector)
            let derived = DoryX86PagingContext(state: state, mode: mode)
            let explicit = DoryX86PagingContext(control: state.control, rflags: state.rflags,
              currentPrivilegeLevel: UInt8(selector), mode: mode)
            #expect(derived.currentPrivilegeLevel == expected)
            #expect(explicit == derived)
          }
        }
      }
    }
  }

  @Test func virtual8086PagingCannotReuseSupervisorPermissions() throws {
    let linear: UInt64 = 0x4123
    for mode: DoryX86ExecutionMode in [.protected16, .protected32] {
      for access: DoryX86MemoryAccessKind in [.read, .write, .instructionFetch] {
        let memory = try pagingMemory(leafFlags: 3) // Present, writable, supervisor-only.
        let paging = DoryX86PagingUnit()
        var state = try makeState(mode: mode, selector: 0)
        state.control.cr0 = (1 << 31) | 1
        state.control.cr3 = 0x1000
        let supervisor = try paging.translate(linearAddress: linear, access: access,
          context: .init(state: state, mode: mode), physicalMemory: memory)
        #expect(supervisor.physicalAddress == 0x3123)
        state.rflags.insert(.virtual8086)
        let errorCode: UInt32 = access == .write ? 7 : 5 // I/D is zero for legacy paging.
        #expect(throws: DoryX86MemoryError.pageFault(address: linear, errorCode: errorCode)) {
          try paging.translate(linearAddress: linear, access: access,
            context: .init(state: state, mode: mode), physicalMemory: memory)
        }
      }
    }
  }

  @Test func virtual8086PagingUsesUserWriteProtectionAndFaultErrorBits() throws {
    let linear: UInt64 = 0x4123
    for flags: UInt64 in [0, 5, 7] { // Absent, user read-only, user read/write.
      for access: DoryX86MemoryAccessKind in [.read, .write, .instructionFetch] {
        let memory = try pagingMemory(leafFlags: flags)
        var state = try makeState(mode: .protected16, selector: 0, virtual8086: true)
        state.control.cr0 = (1 << 31) | 1 // CR0.WP = 0 must not permit user writes.
        state.control.cr3 = 0x1000
        state.control.cr4 = (1 << 20) | (1 << 21) // SMEP/SMAP do not restrict user accesses.
        let paging = DoryX86PagingUnit()
        if flags == 0 || (flags == 5 && access == .write) {
          let errorCode: UInt32 = 4 | (access == .write ? 2 : 0)
            | (flags == 0 ? 0 : 1) | (access == .instructionFetch ? 16 : 0)
          #expect(throws: DoryX86MemoryError.pageFault(address: linear, errorCode: errorCode)) {
            try paging.translate(linearAddress: linear, access: access,
              context: .init(state: state, mode: .protected16), physicalMemory: memory)
          }
        } else {
          let translated = try paging.translate(linearAddress: linear, access: access,
            context: .init(state: state, mode: .protected16), physicalMemory: memory)
          #expect(translated.physicalAddress == 0x3123)
          #expect(translated.userAccessible)
        }
      }
    }
  }

  private var generalProtection: DoryX86InterpreterResult {
    .exception(.init(kind: .generalProtection, vector: 13, errorCode: 0, instructionPointer: 0x1000))
  }

  private func makeState(mode: DoryX86ExecutionMode, selector: UInt16,
    virtual8086: Bool = false) throws -> DoryX86ArchitecturalState {
    try .init(registers: .init(rax: 0x10, rcx: 0x10), rip: 0x1000,
      rflags: virtual8086 ? [.reservedOne, .virtual8086] : [.reservedOne],
      cs: .init(selector: selector, attributes: mode == .long64 ? 0xA09B : 0x9B, limit: .max),
      control: .init(cr0: mode == .real16 ? 0x10 : 0x11))
  }

  private func pagingMemory(leafFlags: UInt64) throws -> DoryX86ByteArrayMemory {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x5000)
    try memory.writeScalar(at: 0x1000, value: 0x2007, byteCount: 4)
    try memory.writeScalar(at: 0x2010, value: 0x3000 | leafFlags, byteCount: 4)
    return memory
  }
}

private final class ModePrivilegeIOBus: DoryX86IOBus, @unchecked Sendable {
  private(set) var accessCount = 0

  func read(port: UInt16, width: DoryX86OperandWidth) throws -> UInt32 {
    accessCount += 1
    return 0x5A
  }

  func write(port: UInt16, value: UInt32, width: DoryX86OperandWidth) throws {
    accessCount += 1
  }
}
