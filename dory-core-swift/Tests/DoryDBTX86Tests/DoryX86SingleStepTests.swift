import Testing

@testable import DoryDBTX86

// Intel SDM revision 090, Vol. 3B §§18.2.3, 18.3.1.1, and 18.3.1.4:
// https://cdrdv2-public.intel.com/774491/253669-sdm-vol-3b.pdf
@Suite struct DoryX86SingleStepTests {
  @Test func trapCommitsTheInstructionAndRFDoesNotSuppressIt() throws {
    for mode: DoryX86ExecutionMode in [.protected32, .long64] {
      let memory = try memory([0xFF, 0xC3]) // INC EBX
      let beforeMemory = memory.snapshot()
      var state = try state(mode, flags: [.reservedOne, .trap, .resume])
      state.registers.rbx = 41
      state.debug.dr6 = 5

      #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: mode)
        == .exception(.init(kind: .debug, vector: 1, instructionPointer: 0x102)))
      #expect(state.registers.rbx == 42)
      #expect(state.rip == 0x102)
      #expect(state.rflags == [.reservedOne, .trap])
      #expect(state.debug.dr6 == 0x1_4005)
      #expect(memory.snapshot() == beforeMemory)
    }
  }

  @Test func instructionFaultWinsWithoutPublishingRFOrDebugChanges() throws {
    let memory = try memory([0x0F, 0x0B]) // UD2
    var state = try state(.long64, flags: [.reservedOne, .trap, .resume])
    state.debug.dr6 = 5
    let before = state

    #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
      == .exception(.init(kind: .invalidOpcode, vector: 6, instructionPointer: 0x100)))
    #expect(state == before)
  }

  @Test func popFlagsChangesTakeEffectStartingAtTheFollowingInstruction() throws {
    let settingMemory = try memory([0x9D, 0x90]) // POPFD; NOP
    try settingMemory.writeScalar(
      at: 0x200,
      value: DoryX86RFLAGS.reservedOne.rawValue | DoryX86RFLAGS.trap.rawValue,
      byteCount: 4
    )
    var setting = try state(.protected32, stackPointer: 0x200)

    guard case .retired = DoryX86Interpreter().step(
      state: &setting, memory: settingMemory, mode: .protected32)
    else {
      Issue.record("POPF setting TF must retire without a same-instruction trap")
      return
    }
    #expect(setting.rip == 0x101)
    #expect(setting.registers.rsp == 0x204)
    #expect(setting.rflags == [.reservedOne, .trap])
    #expect(DoryX86Interpreter().step(
      state: &setting, memory: settingMemory, mode: .protected32)
      == .exception(.init(kind: .debug, vector: 1, instructionPointer: 0x102)))

    let clearingMemory = try memory([0x9D])
    try clearingMemory.writeScalar(
      at: 0x200, value: DoryX86RFLAGS.reservedOne.rawValue, byteCount: 4)
    var clearing = try state(
      .protected32, flags: [.reservedOne, .trap, .resume], stackPointer: 0x200)
    guard case .retired = DoryX86Interpreter().step(
      state: &clearing, memory: clearingMemory, mode: .protected32)
    else {
      Issue.record("POPF clearing TF must retire without a single-step trap")
      return
    }
    #expect(clearing.rip == 0x101)
    #expect(clearing.rflags == [.reservedOne])
  }

  @Test func movSSSuppressesItsBoundaryButTheFollowingInstructionTraps() throws {
    let memory = try memory([0x8E, 0xD0, 0x90]) // MOV SS,AX; NOP
    var state = try state(.real16, flags: [.reservedOne, .trap, .resume])
    state.registers.rax = 0x20
    state.debug.dr6 = 5

    guard case .retired = DoryX86Interpreter().step(
      state: &state, memory: memory, mode: .real16)
    else {
      Issue.record("MOV SS must suppress the single-step trap on its own boundary")
      return
    }
    #expect(state.rip == 0x102)
    #expect(state.ss.selector == 0x20)
    #expect(state.interruptShadow == .movSS)
    #expect(state.rflags == [.reservedOne, .trap])
    #expect(state.debug.dr6 == 5)

    #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .real16)
      == .exception(.init(kind: .debug, vector: 1, instructionPointer: 0x103)))
    #expect(state.rip == 0x103)
    #expect(state.interruptShadow == nil)
    #expect(state.debug.dr6 == 0x1_4005)
  }

  @Test func popSSSuppressesItsBoundaryButTheFollowingInstructionTraps() throws {
    let memory = try memory([0x17, 0x90]) // POP SS; NOP
    try memory.writeScalar(at: 0x200, value: 0x20, byteCount: 2)
    var state = try state(
      .real16, flags: [.reservedOne, .trap, .resume], stackPointer: 0x200)
    state.debug.dr6 = 5

    guard case .retired = DoryX86Interpreter().step(
      state: &state, memory: memory, mode: .real16)
    else {
      Issue.record("POP SS must suppress the single-step trap on its own boundary")
      return
    }
    #expect(state.rip == 0x101)
    #expect(state.registers.rsp == 0x202)
    #expect(state.ss.selector == 0x20)
    #expect(state.interruptShadow == .movSS)
    #expect(state.rflags == [.reservedOne, .trap])
    #expect(state.debug.dr6 == 5)

    #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .real16)
      == .exception(.init(kind: .debug, vector: 1, instructionPointer: 0x102)))
    #expect(state.rip == 0x102)
    #expect(state.interruptShadow == nil)
    #expect(state.debug.dr6 == 0x1_4005)
  }

  @Test func repeatedStringTrapsAfterOneRestartableIteration() throws {
    let memory = try memory([0xF3, 0xA4]) // REP MOVSB
    try memory.write(at: 0x200, bytes: [0xA1, 0xB2, 0xC3])
    try memory.write(at: 0x300, bytes: [0, 0, 0])
    var state = try state(.long64, flags: [.reservedOne, .trap, .resume])
    state.registers.rcx = 3
    state.registers.rsi = 0x200
    state.registers.rdi = 0x300
    state.debug.dr6 = 5

    #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
      == .exception(.init(kind: .debug, vector: 1, instructionPointer: 0x100)))
    #expect(state.rip == 0x100)
    #expect(state.registers.rcx == 2)
    #expect(state.registers.rsi == 0x201)
    #expect(state.registers.rdi == 0x301)
    #expect(try memory.read(at: 0x300, byteCount: 3) == [0xA1, 0, 0])
    #expect(state.rflags == [.reservedOne, .trap])
    #expect(state.debug.dr6 == 0x1_4005)
  }

  @Test func haltedInstructionSingleStepsInsteadOfLeavingTheProcessorHalted() throws {
    let memory = try memory([0xF4]) // HLT
    var state = try state(.real16, flags: [.reservedOne, .trap, .resume])
    state.debug.dr6 = 5

    #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .real16)
      == .exception(.init(kind: .debug, vector: 1, instructionPointer: 0x101)))
    #expect(state.rip == 0x101)
    #expect(state.rflags == [.reservedOne, .trap])
    #expect(state.debug.dr6 == 0x1_4005)
  }

  private func memory(_ bytes: [UInt8]) throws -> DoryX86ByteArrayMemory {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x1000)
    try memory.write(at: 0x100, bytes: bytes)
    return memory
  }

  private func state(
    _ mode: DoryX86ExecutionMode,
    flags: DoryX86RFLAGS = .reset,
    stackPointer: UInt64 = 0x800
  ) throws -> DoryX86ArchitecturalState {
    try .init(
      registers: .init(rsp: stackPointer),
      rip: 0x100,
      rflags: flags,
      cs: .init(
        attributes: mode == .long64 ? 0xA09B : (mode == .protected32 ? 0xC09B : 0x009B),
        limit: .max
      ),
      ss: .init(attributes: mode == .protected32 ? 0xC093 : 0x0093, limit: .max),
      control: .init(
        cr0: mode == .real16 ? 0x10 : 0x11,
        efer: mode == .long64 ? 1 << 10 : 0
      )
    )
  }
}
