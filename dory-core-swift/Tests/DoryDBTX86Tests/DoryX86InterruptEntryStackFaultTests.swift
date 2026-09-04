import Testing

@testable import DoryDBTX86

// Intel SDM Vol. 2A, INT event-delivery pseudocode:
// - intra-privilege stack exhaustion raises #SS(EXT), with a NULL selector;
// - inter-privilege stack exhaustion raises #SS(NewSS|EXT);
// - every IA-32e stack address used by the frame must be canonical.
@Suite struct DoryX86InterruptEntryStackFaultTests {
  @Test func samePrivilegeStackExhaustionDeliversStackSegmentWithExternalBitOnly() throws {
    let memory = try protectedMemory(
      firstSelector: 0x18,
      firstGateAttributes: 0x8E
    )
    var state = try protectedState(stack: 8)

    try DoryX86InterruptDelivery().deliverEvent(
      vector: 0x30,
      source: .externalMaskable,
      state: &state,
      physicalMemory: memory,
      mode: .protected32
    )

    #expect(state.rip == 0x9100)
    #expect(state.cs.selector == 0x1B)
    #expect(state.registers.rsp == 0)
    #expect(try memory.readScalar(at: 0, byteCount: 2) == 1)
  }

  @Test func privilegeSwitchStackExhaustionKeepsNewSSSelectorInErrorCode() throws {
    let memory = try protectedMemory(
      firstSelector: 8,
      firstGateAttributes: 0x8E
    )
    // Ring-0 ESP=8 and SS=0x10. A 32-bit privilege-switch frame wraps on
    // its third slot, while the ring-3 stack remains available to enter #SS.
    try memory.writeScalar(at: 0x3004, value: 8, byteCount: 4)
    try memory.writeScalar(at: 0x3008, value: 0x10, byteCount: 2)
    var state = try protectedState(stack: 0x100)

    try DoryX86InterruptDelivery().deliverEvent(
      vector: 0x30,
      source: .externalMaskable,
      state: &state,
      physicalMemory: memory,
      mode: .protected32
    )

    #expect(state.rip == 0x9100)
    #expect(state.cs.selector == 0x1B)
    #expect(state.ss.selector == 0x23)
    #expect(state.registers.rsp == 0xF8)
    #expect(try memory.readScalar(at: 0xF8, byteCount: 2) == 0x11)
  }

  @Test func longModePreflightsEveryFrameAddressAsAStackFault() throws {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x4000)
    try memory.writeScalar(at: 0x1008, value: 0x00AF_9A00_0000_FFFF, byteCount: 8)
    try installLongGate(vector: 0x30, target: 0x3000, memory: memory)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rsp: 0xFFFF_8000_0000_0010),
      rip: 0x2800,
      rflags: [.reservedOne, .interruptEnable],
      cs: .init(selector: 8, attributes: 0xA09B, limit: .max),
      ss: .init(selector: 16, attributes: 0xC093, limit: .max),
      gdtr: .init(limit: 0x17, base: 0x1000),
      idtr: .init(limit: 0x0FFF, base: 0x2000)
    )
    let before = state

    #expect(throws: DoryX86InterruptDeliveryError.stackAddress) {
      try DoryX86InterruptDelivery().deliver(
        vector: 0x30,
        source: .hardwareException,
        state: &state,
        physicalMemory: memory,
        mode: .long64
      )
    }
    #expect(state == before)
  }

  private func protectedMemory(
    firstSelector: UInt16,
    firstGateAttributes: UInt8
  ) throws -> DoryX86ByteArrayMemory {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x4000)
    try memory.writeScalar(at: 0x1008, value: 0x00CF_9A00_0000_FFFF, byteCount: 8)
    // Ring-0 data segment: 32-bit, byte granularity, 64 KiB limit. This makes
    // the wrapped third frame slot a segment-limit failure before memory access.
    try memory.writeScalar(at: 0x1010, value: 0x0040_9200_0000_FFFF, byteCount: 8)
    try memory.writeScalar(at: 0x1018, value: 0x00CF_FA00_0000_FFFF, byteCount: 8)
    try memory.writeScalar(at: 0x1020, value: 0x00CF_F200_0000_FFFF, byteCount: 8)
    try installProtectedGate(
      vector: 0x30,
      target: 0x9000,
      selector: firstSelector,
      attributes: firstGateAttributes,
      memory: memory
    )
    // A 16-bit ring-3 #SS gate can fit its four-word frame at ESP=8 after
    // the deliberately wider first entry fails without publishing state.
    try installProtectedGate(
      vector: 12,
      target: 0x9100,
      selector: 0x18,
      attributes: 0x86,
      memory: memory
    )
    return memory
  }

  private func protectedState(stack: UInt64) throws -> DoryX86ArchitecturalState {
    var state = try DoryX86ArchitecturalState(
      registers: .init(rsp: stack),
      rip: 0x8000,
      rflags: [.reservedOne, .interruptEnable],
      cs: .init(selector: 0x1B, attributes: 0xC0FA, limit: .max),
      ss: .init(selector: 0x23, attributes: 0xC0F2, limit: 0xFFFF),
      tr: .init(selector: 0x28, attributes: 0x008B, limit: 0x67, base: 0x3000),
      gdtr: .init(limit: 0x27, base: 0x1000),
      idtr: .init(limit: 0x7FF, base: 0x2000)
    )
    state.control.cr0 |= 1
    return state
  }

  private func installProtectedGate(
    vector: UInt8,
    target: UInt32,
    selector: UInt16,
    attributes: UInt8,
    memory: DoryX86ByteArrayMemory
  ) throws {
    let raw =
      UInt64(target & 0xFFFF)
      | UInt64(selector) << 16
      | UInt64(attributes) << 40
      | UInt64(target & 0xFFFF_0000) << 32
    try memory.writeScalar(
      at: 0x2000 + UInt64(vector) * 8,
      value: raw,
      byteCount: 8
    )
  }

  private func installLongGate(
    vector: UInt8,
    target: UInt64,
    memory: DoryX86ByteArrayMemory
  ) throws {
    let low =
      (target & 0xFFFF)
      | UInt64(8) << 16
      | UInt64(0x8E) << 40
      | ((target >> 16) & 0xFFFF) << 48
    try memory.writeScalar(
      at: 0x2000 + UInt64(vector) * 16,
      value: low,
      byteCount: 8
    )
    try memory.writeScalar(
      at: 0x2008 + UInt64(vector) * 16,
      value: target >> 32,
      byteCount: 8
    )
  }
}
