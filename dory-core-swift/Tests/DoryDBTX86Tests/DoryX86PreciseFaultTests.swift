import Testing

@testable import DoryDBTX86

@Suite struct DoryX86PreciseFaultTests {
  @Test func noncanonicalIndirectCallsJumpsAndReturnsDoNotCommitStateOrStackWrites() throws {
    let target: UInt64 = 0x0000_8000_0000_0000
    for bytes: [UInt8] in [[0xFF, 0xD0], [0xFF, 0xE0], [0xC3], [0xC2, 0x10, 0x00]] {
      let memory = try DoryX86ByteArrayMemory(byteCount: 0x200)
      try memory.write(at: 0, bytes: bytes)
      try memory.writeScalar(at: 0x100, value: target, byteCount: 8)
      var state = try DoryX86ArchitecturalState(
        registers: .init(rax: target, rsp: 0x100), rip: 0,
        rflags: [.reservedOne, .carry, .overflow], control: .init(cr2: 0x1234))
      let before = state
      let memoryBefore = memory.snapshot()
      #expect(
        DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
          == .exception(
            .init(kind: .generalProtection, vector: 13, errorCode: 0, instructionPointer: 0)))
      #expect(state == before)
      #expect(memory.snapshot() == memoryBefore)
    }
  }

  @Test func noncanonicalRelativeTargetsFaultBeforeCallOrLoopSideEffects() throws {
    let cases: [(UInt64, [UInt8])] = [
      (0x0000_7FFF_FFFF_F000, [0xE8, 0, 0x10, 0, 0]),
      (0x0000_7FFF_FFFF_F000, [0xE9, 0, 0x10, 0, 0]),
      (0x0000_7FFF_FFFF_F000, [0x0F, 0x84, 0, 0x10, 0, 0]),
      (0x0000_7FFF_FFFF_FFC0, [0xE2, 0x7F]),
    ]
    for (rip, bytes) in cases {
      let memory = try DoryX86ByteArrayMemory(baseAddress: rip, byteCount: 0x200)
      try memory.write(at: rip, bytes: bytes)
      var state = try DoryX86ArchitecturalState(
        registers: .init(rcx: 2, rsp: rip + 0x100), rip: rip,
        rflags: [.reservedOne, .zero])
      let before = state
      let memoryBefore = memory.snapshot()
      #expect(
        DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
          == .exception(
            .init(
              kind: .generalProtection, vector: 13, errorCode: 0,
              instructionPointer: rip)))
      #expect(state == before)
      #expect(memory.snapshot() == memoryBefore)
    }
  }

  @Test func untakenConditionalBranchDoesNotValidateItsUnusedTarget() throws {
    let rip: UInt64 = 0x0000_7FFF_FFFF_F000
    let memory = try DoryX86ByteArrayMemory(baseAddress: rip, bytes: [0x0F, 0x84, 0, 0x10, 0, 0])
    var state = try DoryX86ArchitecturalState(rip: rip)
    guard case .retired = DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
    else {
      Issue.record("Untaken conditional branch unexpectedly faulted")
      return
    }
    #expect(state.rip == rip + 6)
  }

  @Test func noncanonicalStackRangesRaiseStackFaultBeforeMemoryAccess() throws {
    let cases: [(UInt8, UInt64)] = [
      (0x50, 0x0000_8000_0000_0008), (0x58, 0x0000_8000_0000_0000),
      (0x50, 0x0000_8000_0000_0004), (0x58, 0x0000_7FFF_FFFF_FFFC),
    ]
    for (opcode, rsp) in cases {
      let memory = try DoryX86ByteArrayMemory(bytes: [opcode])
      var state = try DoryX86ArchitecturalState(
        registers: .init(rax: 0xAA, rsp: rsp), rip: 0, control: .init(cr2: 0x1234))
      let before = state
      #expect(
        DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
          == .exception(.init(kind: .stackSegment, vector: 12, errorCode: 0, instructionPointer: 0))
      )
      #expect(state == before)
      #expect(memory.snapshot() == [opcode])
    }
  }

  @Test func repeatedComparisonFaultRestoresFlagsAndKeepsCompletedIndexProgress() throws {
    // REPE continues on equal bytes; REPNE continues on unequal bytes. The second destination
    // byte is unmapped in both cases, after the first comparison has changed arithmetic flags.
    for prefix: UInt8 in [0xF3, 0xF2] {
      for opcode: UInt8 in [0xA6, 0xAE] {
        let memory = try DoryX86ByteArrayMemory(byteCount: 0x21)
        try memory.write(at: 0, bytes: [prefix, opcode])
        try memory.write(at: 0x10, bytes: [0x41, 0x42])
        try memory.write(at: 0x20, bytes: [prefix == 0xF3 ? 0x41 : 0x40])
        let flags: DoryX86RFLAGS = [.reservedOne, .carry, .overflow, .interruptEnable]
        var state = try DoryX86ArchitecturalState(
          registers: .init(rax: 0x41, rcx: 2, rsi: 0x10, rdi: 0x20), rip: 0,
          rflags: flags)
        #expect(
          DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
            == .exception(
              .init(
                kind: .pageFault, vector: 14, errorCode: 0,
                instructionPointer: 0, linearAddress: 0x21, commitsPartialProgress: true)))
        #expect(state.rflags == flags)
        #expect(state.rip == 0)
        #expect(state.registers.rcx == 1)
        #expect(state.registers.rsi == (opcode == 0xA6 ? 0x11 : 0x10))
        #expect(state.registers.rdi == 0x21)
        #expect(state.control.cr2 == 0x21)
      }
    }
  }

  @Test func repeatedStackSegmentFaultRetainsItsOriginalExceptionVector() throws {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x40)
    try memory.write(at: 0, bytes: [0x36, 0xF3, 0xA4])  // REP MOVSB from SS:ESI to ES:EDI.
    try memory.write(at: 0x10, bytes: [0x5A, 0xA5])
    var state = try DoryX86ArchitecturalState(
      registers: .init(rcx: 2, rsi: 0x10, rdi: 0x20), rip: 0,
      cs: .init(selector: 8, attributes: 0xC09B, limit: .max),
      es: .init(selector: 0x18, attributes: 0xC093, limit: .max),
      ss: .init(selector: 0x10, attributes: 0xC093, limit: 0x10),
      control: .init(cr0: 1, cr2: 0x1234))
    #expect(
      DoryX86Interpreter().step(state: &state, memory: memory, mode: .protected32)
        == .exception(
          .init(
            kind: .stackSegment, vector: 12, errorCode: 0,
            instructionPointer: 0, commitsPartialProgress: true)))
    #expect(state.rip == 0)
    #expect(state.registers.rcx == 1)
    #expect(state.registers.rsi == 0x11)
    #expect(state.registers.rdi == 0x21)
    #expect(state.control.cr2 == 0x1234)
    #expect(try memory.read(at: 0x20, byteCount: 2) == [0x5A, 0])
  }

  @Test func divisionOverflowAndZeroDivisorsPreserveTheFullFaultingState() throws {
    let cases: [([UInt8], UInt64, UInt64, UInt64)] = [
      ([0xF6, 0xF3], 1, 0, 0), ([0xF6, 0xF3], 0x100, 0, 1),
      ([0x66, 0xF7, 0xF3], 0, 1, 1), ([0xF7, 0xF3], 0, 1, 1),
      ([0x48, 0xF7, 0xF3], 0, 1, 1),
      ([0xF6, 0xFB], 0xFF80, 0, 0xFF),
      ([0x66, 0xF7, 0xFB], 0x8000, 0xFFFF, 0xFFFF),
      ([0xF7, 0xFB], 0x8000_0000, 0xFFFF_FFFF, 0xFFFF_FFFF),
      ([0xF7, 0xFB], 0, 0x8000_0000, 0xFFFF_FFFF),
      ([0x48, 0xF7, 0xFB], 1 << 63, .max, .max),
      ([0x48, 0xF7, 0xFB], 0, 1 << 63, .max),
    ]
    for (bytes, rax, rdx, rbx) in cases {
      let memory = try DoryX86ByteArrayMemory(bytes: bytes)
      var state = try DoryX86ArchitecturalState(
        registers: .init(rax: rax, rdx: rdx, rbx: rbx), rip: 0,
        rflags: [.reservedOne, .carry, .overflow], control: .init(cr2: 0x1234))
      let before = state
      #expect(
        DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
          == .exception(.init(kind: .divideError, vector: 0, instructionPointer: 0)))
      #expect(state == before)
      #expect(memory.snapshot() == bytes)
    }
  }
}
