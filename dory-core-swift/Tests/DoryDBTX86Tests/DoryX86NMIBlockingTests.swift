import Testing

@testable import DoryDBTX86

@Suite struct DoryX86NMIBlockingTests {
  @Test func acceptedNMIBlocksNestedDeliveryUntilSuccessfulIRET() throws {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x800)
    // Real-mode vector 2 -> 0000:0200; the handler is IRET.
    try memory.write(at: 8, bytes: [0, 2, 0, 0])
    try memory.write(at: 0x200, bytes: [0xCF])
    var state = try DoryX86ArchitecturalState(
      registers: .init(rsp: 0x100),
      rip: 0x123,
      rflags: [.reservedOne, .interruptEnable],
      cs: .init(selector: 0, attributes: 0x9B, limit: 0xFFFF),
      ss: .init(selector: 0x40, attributes: 0x93, limit: 0xFFFF, base: 0x400),
      idtr: .init(limit: 0x3FF)
    )
    let delivery = DoryX86InterruptDelivery()

    try delivery.deliver(
      vector: 2, source: .nonMaskable, state: &state, physicalMemory: memory, mode: .real16)
    #expect(state.nmiBlocked)
    #expect(state.rip == 0x200)
    #expect(state.registers.rsp == 0xFA)

    let once = state
    let memoryOnce = try memory.read(at: 0, byteCount: 0x600)
    try delivery.deliver(
      vector: 2, source: .nonMaskable, state: &state, physicalMemory: memory, mode: .real16)
    #expect(state == once)
    #expect(try memory.read(at: 0, byteCount: 0x600) == memoryOnce)

    let result = DoryX86Interpreter().step(state: &state, memory: memory, mode: .real16)
    guard case .retired = result else {
      Issue.record("IRET did not retire: \(result)")
      return
    }
    #expect(!state.nmiBlocked)
    #expect(state.rip == 0x123)
    #expect(state.registers.rsp == 0x100)
    #expect(state.rflags.contains(.interruptEnable))
  }

  @Test func failedNMIDeliveryStillEstablishesBlockingBeforeGateAccess() throws {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x400)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0xABCD, rsp: 0x100),
      rip: 0x123,
      idtr: .init(limit: 7)
    )
    let original = state

    #expect(throws: DoryX86InterruptDeliveryError.invalidIDTLimit(vector: 2)) {
      try DoryX86InterruptDelivery().deliver(
        vector: 2,
        source: .nonMaskable,
        state: &state,
        physicalMemory: memory,
        mode: .real16
      )
    }
    var expected = original
    expected.nmiBlocked = true
    #expect(state == expected)
  }

  @Test func faultingIRETUnblocksWithoutPublishingAnyOtherCandidateState() throws {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x400)
    try memory.write(at: 0x100, bytes: [0xCF])
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0xABCD, rsp: 0xFFFC),
      rip: 0x100,
      cs: .init(selector: 0, attributes: 0x9B, limit: 0xFFFF),
      ss: .init(selector: 0, attributes: 0x93, limit: 0xFFFF),
      nmiBlocked: true
    )
    let original = state
    let result = DoryX86Interpreter().step(state: &state, memory: memory, mode: .real16)

    #expect(
      result == .exception(
        .init(
          kind: .stackSegment,
          vector: 12,
          errorCode: 0,
          instructionPointer: 0x100
        )))
    var expected = original
    expected.nmiBlocked = false
    #expect(state == expected)
  }

  @Test func pageFaultingProtectedIRETUnblocksAndPublishesOnlyCR2() throws {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x40000)
    try memory.write(at: 0x1000, bytes: [0xCF])
    // Legacy paging maps the IRET instruction and only the first stack page.
    // The frame starts at its last byte so the implicit stack read faults at
    // linear 0x9000 before any candidate IRET state can be published.
    try memory.writeScalar(at: 0x9000, value: 0xA007, byteCount: 4)
    try memory.writeScalar(at: 0xA004, value: 0x1007, byteCount: 4)
    try memory.writeScalar(at: 0xA020, value: 0x18003, byteCount: 4)
    try memory.write(at: 0x18FFF, bytes: [0x34])

    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: 0xABCD, rsp: 0x8FFF),
      rip: 0x1000,
      rflags: [.reservedOne, .carry, .interruptEnable],
      cs: .init(selector: 8, attributes: 0xC09B, limit: .max),
      ss: .init(selector: 16, attributes: 0xC093, limit: .max),
      gdtr: .init(limit: 0x2F, base: 0x2000),
      control: .init(cr0: 0x8001_0011, cr2: 0xDEAD, cr3: 0x9000),
      nmiBlocked: true
    )
    let original = state
    let translated = DoryX86TranslatedMemory(
      physicalMemory: memory,
      pagingUnit: DoryX86PagingUnit(),
      context: .init(state: state, mode: .protected32)
    )

    let result = DoryX86Interpreter().step(
      state: &state,
      memory: memory,
      mode: .protected32,
      translatedMemory: translated
    )
    #expect(
      result == .exception(
        .init(
          kind: .pageFault,
          vector: 14,
          errorCode: 0,
          instructionPointer: 0x1000,
          linearAddress: 0x9000
        )))
    var expected = original
    expected.nmiBlocked = false
    expected.control.cr2 = 0x9000
    #expect(state == expected)
  }
}
