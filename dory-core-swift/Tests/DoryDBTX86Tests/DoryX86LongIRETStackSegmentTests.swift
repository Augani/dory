import Testing

@testable import DoryDBTX86

// Intel SDM 092 Vol. 2A IRET/IRETD/IRETQ, pp. 3-493 and 3-497--498.
// IRETQ validates the popped SS descriptor before publishing any return state:
// invalid type/privilege is #GP(selector), while a non-present stack is #SS(0).
@Suite struct DoryX86LongIRETStackSegmentTests {
  @Test func outerReturnLoadsTheValidatedStackDescriptor() throws {
    let memory = try fixtureMemory(stackDescriptor: dataDescriptor(dpl: 3, present: true))
    var state = try kernelState()
    let decoded = try DoryX86Decoder().decode([0x48, 0xCF], at: 0x1000, mode: .long64)

    #expect(
      DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
        == .retired(decoded)
    )
    #expect(state.rip == 0x4000)
    #expect(state.registers.rsp == 0x3000)
    #expect(state.cs.selector == 0x1B)
    #expect(
      state.ss
        == .init(selector: 0x23, attributes: 0xC0F3, limit: .max, base: 0)
    )
  }

  @Test func nonWritableReturnStackRaisesSelectorGPWithoutPublishingFrame() throws {
    let memory = try fixtureMemory(stackDescriptor: codeDescriptor(dpl: 3))
    var state = try kernelState()
    let before = state

    #expect(
      DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
        == .exception(
          .init(
            kind: .generalProtection,
            vector: 13,
            errorCode: 0x20,
            instructionPointer: 0x1000
          ))
    )
    #expect(state == before)
  }

  @Test func mismatchedStackRPLRaisesSelectorGPWithoutPublishingFrame() throws {
    let memory = try fixtureMemory(
      stackDescriptor: dataDescriptor(dpl: 3, present: true),
      stackSelector: 0x20
    )
    var state = try kernelState()
    let before = state

    #expect(
      DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
        == .exception(
          .init(
            kind: .generalProtection,
            vector: 13,
            errorCode: 0x20,
            instructionPointer: 0x1000
          ))
    )
    #expect(state == before)
  }

  @Test func nonPresentReturnStackRaisesSSZeroAndOnlyUnblocksNMI() throws {
    let memory = try fixtureMemory(stackDescriptor: dataDescriptor(dpl: 3, present: false))
    var state = try kernelState()
    state.nmiBlocked = true
    var expected = state
    expected.nmiBlocked = false

    #expect(
      DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
        == .exception(
          .init(
            kind: .stackSegment,
            vector: 12,
            errorCode: 0,
            instructionPointer: 0x1000
          ))
    )
    #expect(state == expected)
  }

  @Test func nullStackIsAcceptedOnlyForMatchingNonUserReturnPrivilege() throws {
    let memory = try fixtureMemory(
      stackDescriptor: 0,
      codeSelector: 8,
      stackSelector: 0
    )
    var kernel = try kernelState()
    let decoded = try DoryX86Decoder().decode([0x48, 0xCF], at: 0x1000, mode: .long64)

    #expect(
      DoryX86Interpreter().step(state: &kernel, memory: memory, mode: .long64)
        == .retired(decoded)
    )
    #expect(kernel.rip == 0x4000)
    #expect(kernel.ss == .init(selector: 0))

    let userMemory = try fixtureMemory(stackDescriptor: 0, stackSelector: 3)
    var user = try kernelState()
    let before = user
    #expect(
      DoryX86Interpreter().step(state: &user, memory: userMemory, mode: .long64)
        == .exception(
          .init(
            kind: .generalProtection,
            vector: 13,
            errorCode: 0,
            instructionPointer: 0x1000
          ))
    )
    #expect(user == before)
  }

  private func kernelState() throws -> DoryX86ArchitecturalState {
    try .init(
      registers: .init(rsp: 0x2000),
      rip: 0x1000,
      rflags: [.reservedOne, .interruptEnable],
      cs: .init(selector: 8, attributes: 0xA09B, limit: .max),
      ss: .init(selector: 16, attributes: 0xC093, limit: .max),
      gdtr: .init(limit: 0x27, base: 0x5000)
    )
  }

  private func fixtureMemory(
    stackDescriptor: UInt64,
    codeSelector: UInt16 = 0x1B,
    stackSelector: UInt16 = 0x23
  ) throws -> DoryX86ByteArrayMemory {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x6000)
    try memory.write(at: 0x1000, bytes: [0x48, 0xCF])
    try write64(memory, at: 0x2000, value: 0x4000)
    try write64(memory, at: 0x2008, value: UInt64(codeSelector))
    try write64(memory, at: 0x2010, value: DoryX86RFLAGS.reservedOne.rawValue)
    try write64(memory, at: 0x2018, value: 0x3000)
    try write64(memory, at: 0x2020, value: UInt64(stackSelector))
    try write64(
      memory,
      at: 0x5000 + UInt64(codeSelector & 0xFFF8),
      value: codeDescriptor(dpl: UInt8(codeSelector & 3))
    )
    try write64(memory, at: 0x5020, value: stackDescriptor)
    return memory
  }

  private func codeDescriptor(dpl: UInt8) -> UInt64 {
    0x00AF_9B00_0000_FFFF | UInt64(dpl & 3) << 45
  }

  private func dataDescriptor(dpl: UInt8, present: Bool) -> UInt64 {
    let access = UInt64(0x13 | (dpl & 3) << 5 | (present ? 0x80 : 0))
    return 0x00CF_0000_0000_FFFF | access << 40
  }

  private func write64(
    _ memory: DoryX86ByteArrayMemory,
    at address: UInt64,
    value: UInt64
  ) throws {
    try memory.write(
      at: address,
      bytes: (0..<8).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
    )
  }
}
