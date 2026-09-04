import Testing

@testable import DoryDBTX86

// Intel SDM092 Vol2B SLDT/STR pp4-656/679, SMSW p4-658; Vol2A LLDT/LTR.
// Width and mode checks only; descriptor-table memory semantics are separate work.
@Suite struct DoryX86SystemGroupExecutionTests {
  @Test func MOVControlAndDebugRegisterAliasesRetireWithoutReadingAnApparentMemoryOperand() throws {
    for opcode: UInt8 in [0x20, 0x21, 0x22, 0x23] {
      for mod: UInt8 in 0..<4 {
        let memory = try DoryX86ByteArrayMemory(byteCount: 0x2000)
        // REG=2 selects CR2/DR2, R/M=4 selects RSP. MOD!=3 would normally
        // require a SIB byte, but MOV CR/DR ignores MOD and reads no SIB/memory.
        try memory.write(at: 0x100, bytes: [0x0F, opcode, (mod << 6) | 0x14])
        var state = try state(mode: .long64)
        state.registers.rsp = 0xDEAD_BEEF
        state.control.cr2 = 0x1234
        state.debug.dr2 = 0x5678
        let before = state
        let bytes = memory.snapshot()
        try retire(&state, memory: memory, mode: .long64)
        switch opcode {
        case 0x20: #expect(state.registers.rsp == 0x1234)
        case 0x21: #expect(state.registers.rsp == 0x5678)
        case 0x22: #expect(state.control.cr2 == before.registers.rsp)
        default: #expect(state.debug.dr2 == before.registers.rsp)
        }
        #expect(state.rip == 0x103)
        #expect(memory.snapshot() == bytes)
      }
    }
  }

  @Test func SMSWLongModeRegisterFormsStoreCR0AtTheDecodedWidth() throws {
    let cr0: UInt64 = 0x6001_0011
    let initial: UInt64 = 0xFEDC_BA98_7654_3210
    for (prefix, expected): ([UInt8], UInt64) in [
      ([], cr0), ([0x66], (initial & ~0xffff) | (cr0 & 0xffff)), ([0x48], cr0),
    ] {
      let memory = try DoryX86ByteArrayMemory(byteCount: 0x2000)
      try memory.write(at: 0x100, bytes: prefix + [0x0F, 0x01, 0xE0])
      var state = try state(mode: .long64)
      state.registers.rax = initial
      state.control.cr0 = cr0
      let before = state
      try retire(&state, memory: memory, mode: .long64)
      #expect(state.registers.rax == expected)
      #expect(state.control == before.control)
      #expect(state.rflags == before.rflags)
    }
  }

  @Test func SMSWAndSystemSegmentStoresWriteExactlyTwoBytesToMemory() throws {
    for prefix: [UInt8] in [[], [0x66], [0x48]] {
      for (bytes, expected): ([UInt8], UInt64) in [
        ([0x0F, 0x01, 0x20], 0x11), // SMSW [RAX]
        ([0x0F, 0x00, 0x00], 0x6789), // SLDT [RAX]
        ([0x0F, 0x00, 0x08], 0xABCD), // STR [RAX]
      ] {
        let memory = try DoryX86ByteArrayMemory(byteCount: 0x2000)
        try memory.write(at: 0x100, bytes: prefix + bytes)
        try memory.write(at: 0x1000, bytes: .init(repeating: 0x5A, count: 8))
        var state = try state(mode: .long64)
        state.registers.rax = 0x1000
        state.control.cr0 = 0x6001_0011
        try retire(&state, memory: memory, mode: .long64)
        #expect(try memory.readScalar(at: 0x1000, byteCount: 2) == expected)
        #expect(try memory.read(at: 0x1002, byteCount: 6) == .init(repeating: 0x5A, count: 6))
      }
    }
  }

  @Test func SLDTAndSTRZeroExtend32And64BitRegistersAndPreserveUpper16BitDestinationBits() throws {
    let initial: UInt64 = 0xFEDC_BA98_7654_3210
    for mode: DoryX86ExecutionMode in [.protected16, .protected32, .long64] {
      for prefix: [UInt8] in [[], [0x66]] + (mode == .long64 ? [[0x48], [0x49]] : []) {
        let word = prefix.first == 0x48 || prefix.first == 0x49 ? false
          : ((mode == .protected16) != (prefix.first == 0x66))
        for (modRM, selector): (UInt8, UInt64) in [(0xC0, 0x6789), (0xC8, 0xABCD)] {
          let memory = try DoryX86ByteArrayMemory(byteCount: 0x2000)
          try memory.write(at: 0x100, bytes: prefix + [0x0F, 0x00, modRM])
          var state = try state(mode: mode)
          let destination: DoryX86GeneralRegister = prefix.first == 0x49 ? .r8 : .rax
          state.registers[destination] = initial
          try retire(&state, memory: memory, mode: mode)
          #expect(state.registers[destination] == (word ? (initial & ~0xffff) | selector : selector))
        }
      }
    }
  }

  @Test func systemSegmentInstructionsRaiseUDBeforeMemoryInRealAndVirtual8086Modes() throws {
    for mode: DoryX86ExecutionMode in [.real16, .protected16, .protected32] {
      for group: UInt8 in 0...3 {
        for registerForm in [false, true] {
          let memory = try DoryX86ByteArrayMemory(byteCount: 0x2000)
          let modRM = (registerForm ? UInt8(0xC0) : 0) | (group << 3)
          try memory.write(at: 0x100, bytes: [0x0F, 0x00, modRM])
          var state = try state(mode: mode)
          if mode != .real16 { state.rflags.insert(.virtual8086) }
          state.registers.rax = 0xFFFF_FFFF
          state.registers.rbx = 0xFFFF_FFFF
          state.registers.rsi = 0xFFFF_FFFF
          let before = state
          let bytes = memory.snapshot()
          #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: mode)
            == .exception(.init(kind: .invalidOpcode, vector: 6, instructionPointer: 0x100)))
          #expect(state == before)
          #expect(memory.snapshot() == bytes)
        }
      }
    }
  }

  @Test func privilegedSystemSegmentLoadsRejectUserModeBeforeUnmappedSourceRead() throws {
    for group: UInt8 in [2, 3] {
      let memory = try DoryX86ByteArrayMemory(byteCount: 0x2000)
      try memory.write(at: 0x100, bytes: [0x0F, 0x00, group << 3])
      var state = try state(mode: .long64)
      state.cs.selector = 3
      state.registers.rax = 0xFFFF_FFFF
      let before = state
      #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
        == .exception(.init(kind: .generalProtection, vector: 13, errorCode: 0,
          instructionPointer: 0x100)))
      #expect(state == before)
    }
  }

  @Test func REXBDoesNotReplaceRIPRelativeOrSIBNoBaseSystemMemoryFormsWithR13() throws {
    // Intel SDM092 Vol2A Table2-5: both encodings select 0x120, independently of R13.
    for (bytes, relative): ([UInt8], Bool) in [
      ([0x41, 0x0F, 0x00, 0x05, 0x18, 0, 0, 0], true),
      ([0x41, 0x0F, 0x00, 0x04, 0x25, 0x20, 0x01, 0, 0], false),
    ] {
      let decoded = try DoryX86Decoder().decode(bytes, at: 0x100, mode: .long64)
      guard case .storeSystemSegment(false, .memory(let operand)) = decoded.operation else {
        Issue.record("Expected SLDT memory form"); continue
      }
      #expect(decoded.length == bytes.count)
      #expect(operand.base == nil)
      #expect(operand.ripRelative == relative)
      let memory = try DoryX86ByteArrayMemory(byteCount: 0x2000)
      try memory.write(at: 0x100, bytes: bytes)
      try memory.writeScalar(at: 0x500, value: 0xAAAA, byteCount: 2)
      var state = try state(mode: .long64)
      state.registers.r13 = 0x500
      try retire(&state, memory: memory, mode: .long64)
      #expect(try memory.readScalar(at: 0x120, byteCount: 2) == 0x6789)
      #expect(try memory.readScalar(at: 0x500, byteCount: 2) == 0xAAAA)
      #expect(state.rip == 0x100 + UInt64(bytes.count))
    }
  }

  @Test func addressOverrideLEAUsesNextEIPWith32BitWrapInInterpreterAndNativeCode() throws {
    // 67 retains IP-relative addressing; the complete sum is truncated, including
    // a next-IP crossing 4 GiB and a negative displacement wrapping the other way.
    for (rip, displacement, expected): (UInt64, UInt32, UInt64) in [
      (0x1_FFFF_FFF0, 0x20, 0x18),
      (0x1_FFFF_FFFA, 0xFFFF_FFFC, 0xFFFF_FFFE),
    ] {
      let bytes: [UInt8] = [0x67, 0x41, 0x8D, 0x05]
        + (0..<4).map { UInt8(truncatingIfNeeded: displacement >> ($0 * 8)) }
      let memory = try DoryX86ByteArrayMemory(baseAddress: rip, byteCount: 32)
      try memory.write(at: rip, bytes: bytes)
      let initial = try DoryX86ArchitecturalState(registers: .init(r13: 0xDEAD_BEEF), rip: rip)
      var interpreted = initial
      try retire(&interpreted, memory: memory, mode: .long64)
      #expect(interpreted.registers.rax == expected)
      #expect(interpreted.rip == rip + 8)
      #if arch(arm64)
        var native = initial
        let execution = try #require(DoryARM64BaselineExecutor(maximumCodeBytes: 16384).execute(
          bytes: bytes, at: rip, mode: .long64, addressSpaceID: 0,
          maximumInstructions: 1, state: &native))
        #expect(execution.exitCode == .dispatch)
        #expect(native == interpreted)
      #endif
    }
  }

  @Test func FSAndGSBasesAreAddedAfterTheEIPRelativeOffsetWrapsTo32Bits() throws {
    for prefix: UInt8 in [0x64, 0x65] {
      let rip: UInt64 = 0x1_FFFF_FFF0
      let bytes: [UInt8] = [prefix, 0x67, 0x41, 0x8B, 0x05, 0x20, 0, 0, 0]
      // nextEIP=FFFFFFF9; +0x20 wraps to0x19, then FS/GS.base=200000080 is added.
      let memory = try DoryX86ByteArrayMemory(baseAddress: rip, byteCount: 0x200)
      try memory.write(at: rip, bytes: bytes)
      try memory.writeScalar(at: 0x2_0000_0099, value: 0x89AB_CDEF, byteCount: 4)
      var state = try DoryX86ArchitecturalState(registers: .init(r13: 0xDEAD_BEEF), rip: rip,
        fs: .init(base: prefix == 0x64 ? 0x2_0000_0080 : 0),
        gs: .init(base: prefix == 0x65 ? 0x2_0000_0080 : 0))
      try retire(&state, memory: memory, mode: .long64)
      #expect(state.registers.rax == 0x89AB_CDEF)
      #expect(state.rip == rip + 9)
    }
  }

  private func state(mode: DoryX86ExecutionMode) throws -> DoryX86ArchitecturalState {
    try .init(rip: 0x100,
      cs: .init(selector: 0, attributes: mode == .long64 ? 0xA09B : 0x009B, limit: .max),
      ds: .init(selector: 0x10, attributes: 0x0093, limit: .max),
      tr: .init(selector: 0xABCD), ldtr: .init(selector: 0x6789),
      control: .init(cr0: mode == .real16 ? 0x10 : 0x11))
  }

  private func retire(_ state: inout DoryX86ArchitecturalState,
    memory: DoryX86ByteArrayMemory, mode: DoryX86ExecutionMode) throws {
    guard case .retired = DoryX86Interpreter().step(state: &state, memory: memory, mode: mode) else {
      Issue.record("Expected valid system instruction to retire")
      return
    }
  }
}
