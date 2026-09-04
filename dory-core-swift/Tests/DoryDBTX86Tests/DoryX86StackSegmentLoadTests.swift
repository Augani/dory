import Testing

@testable import DoryDBTX86

// Intel SDM Vol. 2B MOV and POP specify the SS-specific descriptor rules used here:
// writable data, RPL=CPL=DPL, #GP(selector) for type/privilege/table faults, and
// #SS(selector) for a not-present stack segment.
// https://cdrdv2-public.intel.com/825743/325462-sdm-vol-1-2abcd-3abcd-4.pdf
@Suite struct DoryX86StackSegmentLoadTests {
  @Test func protectedMOVSSRejectsReadableCodeAndInexactPrivilegeBeforeEffects() throws {
    let cases: [(UInt16, UInt8)] = [
      (0x08, 0x9B),  // Present, readable ring-0 code is not writable data.
      (0x0B, 0xF3),  // Present ring-3 data has RPL=DPL=3, but CPL is 0.
    ]
    for (selector, access) in cases {
      let memory = try DoryX86ByteArrayMemory(byteCount: 0x2000)
      try memory.write(at: 0x1000, bytes: [0x8E, 0xD0]) // MOV SS,AX
      try writeDescriptor(access: access, index: 1, base: 0, memory: memory)
      var state = try protectedState(rip: 0x1000, cpl: 0)
      state.registers.rax = UInt64(selector)
      let before = state

      let result = DoryX86Interpreter().step(
        state: &state, memory: memory, mode: .protected32)
      #expect(result == .exception(.init(
        kind: .generalProtection, vector: 13, errorCode: 8,
        instructionPointer: 0x1000)))
      #expect(state == before)
    }
  }

  @Test func protectedPOPSSReportsNotPresentWithSelectorAndPreservesStackState() throws {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x2000)
    try memory.write(at: 0x1000, bytes: [0x17])
    try memory.writeScalar(at: 0x1800, value: 8, byteCount: 4)
    try writeDescriptor(access: 0x13, index: 1, base: 0, memory: memory) // Not present.
    var state = try protectedState(rip: 0x1000, cpl: 0)
    state.registers.rsp = 0x1800
    let before = state
    let stackBefore = try memory.read(at: 0x1800, byteCount: 4)

    let result = DoryX86Interpreter().step(
      state: &state, memory: memory, mode: .protected32)
    #expect(result == .exception(.init(
      kind: .stackSegment, vector: 12, errorCode: 8,
      instructionPointer: 0x1000)))
    #expect(state == before)
    #expect(try memory.read(at: 0x1800, byteCount: 4) == stackBefore)
  }

  @Test func ringThreeMOVSSReadsTheDescriptorThroughImplicitSupervisorPaging() throws {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x20_000)
    try installLegacyPaging(memory, operandUserAccessible: true)
    try memory.write(at: 0x1000, bytes: [0x8E, 0xD0]) // MOV SS,AX
    try writeDescriptor(access: 0xF3, index: 4, base: 0x4000, memory: memory)
    var state = try pagedRingThreeState()
    state.registers.rax = 0x23
    let instruction = try DoryX86Decoder().decode(
      [0x8E, 0xD0], at: 0x1000, mode: .protected32)

    let result = DoryX86Interpreter().step(
      state: &state,
      memory: memory,
      mode: .protected32,
      pagingUnit: DoryX86PagingUnit()
    )
    #expect(result == .retired(instruction))
    #expect(state.ss.selector == 0x23)
    #expect(state.interruptShadow == .movSS)
    #expect(state.rip == 0x1002)
  }

  @Test func MOVSSSelectorOperandRetainsCurrentPrivilegePaging() throws {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x20_000)
    try installLegacyPaging(memory, operandUserAccessible: false)
    let bytes: [UInt8] = [0x8E, 0x15, 0, 0x50, 0, 0] // MOV SS,word ptr [0x5000]
    try memory.write(at: 0x1000, bytes: bytes)
    try memory.write(at: 0x5000, bytes: [0x23, 0])
    try writeDescriptor(access: 0xF3, index: 4, base: 0x4000, memory: memory)
    var state = try pagedRingThreeState()
    let before = state

    let result = DoryX86Interpreter().step(
      state: &state,
      memory: memory,
      mode: .protected32,
      pagingUnit: DoryX86PagingUnit()
    )
    #expect(result == .exception(.init(
      kind: .pageFault, vector: 14, errorCode: 5,
      instructionPointer: 0x1000, linearAddress: 0x5000)))
    var expected = before
    expected.control.cr2 = 0x5000
    #expect(state == expected)
  }

  private func protectedState(rip: UInt64, cpl: UInt8) throws -> DoryX86ArchitecturalState {
    var state = try DoryX86ArchitecturalState(
      rip: rip,
      cs: .init(selector: UInt16(8 | cpl), attributes: 0xC09B, limit: .max),
      ss: .init(selector: UInt16(16 | cpl), attributes: 0xC093, limit: .max),
      gdtr: .init(limit: 0x27)
    )
    state.control.cr0 |= 1
    return state
  }

  private func pagedRingThreeState() throws -> DoryX86ArchitecturalState {
    try DoryX86ArchitecturalState(
      rip: 0x1000,
      cs: .init(selector: 0x1B, attributes: 0xC0FB, limit: .max),
      ss: .init(selector: 0x23, attributes: 0xC0F3, limit: .max),
      gdtr: .init(limit: 0x27, base: 0x4000),
      control: .init(cr0: 0x8001_0011, cr3: 0x9000)
    )
  }

  private func installLegacyPaging(
    _ memory: DoryX86ByteArrayMemory,
    operandUserAccessible: Bool
  ) throws {
    try memory.writeScalar(at: 0x9000, value: 0xA007, byteCount: 4)
    try memory.writeScalar(at: 0xA004, value: 0x1007, byteCount: 4) // User code.
    try memory.writeScalar(at: 0xA010, value: 0x4003, byteCount: 4) // Supervisor GDT.
    try memory.writeScalar(
      at: 0xA014,
      value: operandUserAccessible ? 0x5007 : 0x5003,
      byteCount: 4
    )
  }

  private func writeDescriptor(
    access: UInt8,
    index: Int,
    base: UInt64,
    memory: DoryX86ByteArrayMemory
  ) throws {
    try memory.write(
      at: base + UInt64(index * 8),
      bytes: [0xFF, 0xFF, 0, 0, 0, access, 0xCF, 0]
    )
  }
}
