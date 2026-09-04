import Testing

@testable import DoryDBTX86

// Intel SDM Vol. 3A §7.2.2: an IDT-reference error code contains the vector
// index and IDT bit. Software INT faults leave EXT clear, so INT 80h reports
// 80h*8 | IDT = 0x402. A not-present gate raises #NP with that same code.
// https://cdrdv2-public.intel.com/825758/253668-sdm-vol-3a.pdf
@Suite struct DoryX86SoftwareInterruptFaultTests {
  @Test func int80InvalidIDTLimitReportsItsIDTSelectorCode() throws {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x3000)
    try memory.write(at: 0x1000, bytes: [0xCD, 0x80])
    var state = try protectedState(idtLimit: 0)
    let before = state

    let result = DoryX86Interpreter().step(
      state: &state, memory: memory, mode: .protected32)
    #expect(result == .exception(.init(
      kind: .generalProtection,
      vector: 13,
      errorCode: 0x402,
      instructionPointer: 0x1000
    )))
    #expect(state == before)
  }

  @Test func int80NotPresentGateReportsSegmentNotPresentWithIDTSelectorCode() throws {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x3000)
    try memory.write(at: 0x1000, bytes: [0xCD, 0x80])
    // 32-bit interrupt gate at IDT[0x80], with P=0.
    try memory.write(
      at: 0x2400,
      bytes: [0x00, 0x01, 0x08, 0x00, 0x00, 0x0E, 0x00, 0x00]
    )
    var state = try protectedState(idtLimit: 0x407)
    let before = state

    let result = DoryX86Interpreter().step(
      state: &state, memory: memory, mode: .protected32)
    #expect(result == .exception(.init(
      kind: .segmentNotPresent,
      vector: 11,
      errorCode: 0x402,
      instructionPointer: 0x1000
    )))
    #expect(state == before)
  }

  private func protectedState(idtLimit: UInt16) throws -> DoryX86ArchitecturalState {
    try DoryX86ArchitecturalState(
      rip: 0x1000,
      cs: .init(selector: 8, attributes: 0xC09B, limit: .max),
      ss: .init(selector: 0x10, attributes: 0xC093, limit: .max),
      idtr: .init(limit: idtLimit, base: 0x2000),
      control: .init(cr0: 0x11)
    )
  }
}
