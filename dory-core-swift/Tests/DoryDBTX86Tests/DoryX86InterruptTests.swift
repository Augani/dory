import Testing

@testable import DoryDBTX86

@Suite struct DoryX86InterruptTests {
  @Test func realModeInterruptAndIRETRoundTripSegmentedFrames() throws {
    let memory = DoryX86ByteArrayMemory(byteCount: 0x500)
    try memory.write(at: 0x40, bytes: [0, 2, 0, 0])
    try memory.write(at: 0x100, bytes: [0xCD, 0x10])
    try memory.write(at: 0x200, bytes: [0xCF])
    var state = try DoryX86ArchitecturalState(
      registers: .init(rsp: 0xCAFE_0080),
      rip: 0x100,
      rflags: [.reservedOne, .interruptEnable],
      cs: .init(selector: 0, attributes: 0x9B, limit: 0xffff),
      ss: .init(selector: 0x30, attributes: 0x93, limit: 0xffff, base: 0x300),
      idtr: .init(limit: 0x3ff)
    )
    let interpreter = DoryX86Interpreter()

    _ = interpreter.step(state: &state, memory: memory, mode: .real16)
    #expect(state.rip == 0x200)
    #expect(state.cs.selector == 0)
    #expect(state.registers.rsp == 0xCAFE_007A)
    #expect(!state.rflags.contains(.interruptEnable))
    #expect(try memory.read(at: 0x37A, byteCount: 6) == [2, 1, 0, 0, 2, 2])

    _ = interpreter.step(state: &state, memory: memory, mode: .real16)
    #expect(state.rip == 0x102)
    #expect(state.registers.rsp == 0xCAFE_0080)
    #expect(state.rflags.contains(.interruptEnable))
  }

  @Test func softwareInterruptSwitchesPrivilegeStacksAndIRETRestoresUserState() throws {
    let memory = DoryX86ByteArrayMemory(byteCount: 0x10_000)
    try installSegments(memory)
    try installGate(
      vector: 0x80,
      target: 0x8000,
      selector: 0x8,
      attributes: 0xEE,
      memory: memory
    )
    try write64(memory, 0x3004, 0x5000)
    try memory.write(at: 0x7000, bytes: [0xCD, 0x80])
    try memory.write(at: 0x8000, bytes: [0xCF])

    var registers = DoryX86GeneralRegisters()
    registers.rsp = 0x6000
    var state = try DoryX86ArchitecturalState(
      registers: registers,
      rip: 0x7000,
      rflags: [.reservedOne, .interruptEnable],
      cs: .init(selector: 0x1B, attributes: 0xA0FB, limit: .max),
      ss: .init(selector: 0x23, attributes: 0xC0F3, limit: .max),
      tr: .init(selector: 0x28, attributes: 0x008B, limit: 0x67, base: 0x3000),
      gdtr: .init(limit: 0x1F, base: 0x1000),
      idtr: .init(limit: 0x0FFF, base: 0x2000)
    )
    let interpreter = DoryX86Interpreter()
    let entered = interpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = entered else {
      Issue.record("INT did not retire: \(entered)")
      return
    }
    #expect(state.rip == 0x8000)
    #expect(state.registers.rsp == 0x4FD8)
    #expect(state.cs.selector == 0x8)
    #expect(!state.rflags.contains(.interruptEnable))
    #expect(try read64(memory, 0x4FD8) == 0x7002)
    #expect(try read64(memory, 0x4FE0) == 0x1B)
    #expect(try read64(memory, 0x4FE8) == 0x202)
    #expect(try read64(memory, 0x4FF0) == 0x6000)
    #expect(try read64(memory, 0x4FF8) == 0x23)

    let returned = interpreter.step(state: &state, memory: memory, mode: .long64)
    guard case .retired = returned else {
      Issue.record("IRETQ did not retire: \(returned)")
      return
    }
    #expect(state.rip == 0x7002)
    #expect(state.registers.rsp == 0x6000)
    #expect(state.cs.selector == 0x1B)
    #expect(state.ss.selector == 0x23)
    #expect(state.rflags.contains(.interruptEnable))
  }

  @Test func softwareInterruptHonorsGatePrivilegeAndLeavesStateRestartable() throws {
    let memory = DoryX86ByteArrayMemory(byteCount: 0x10_000)
    try installSegments(memory)
    try installGate(
      vector: 0x80,
      target: 0x8000,
      selector: 0x8,
      attributes: 0x8E,
      memory: memory
    )
    try memory.write(at: 0x7000, bytes: [0xCD, 0x80])
    var registers = DoryX86GeneralRegisters()
    registers.rsp = 0x6000
    var state = try DoryX86ArchitecturalState(
      registers: registers,
      rip: 0x7000,
      cs: .init(selector: 0x1B, attributes: 0xA0FB, limit: .max),
      ss: .init(selector: 0x23, attributes: 0xC0F3, limit: .max),
      gdtr: .init(limit: 0x1F, base: 0x1000),
      idtr: .init(limit: 0x0FFF, base: 0x2000)
    )
    let result = DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
    #expect(
      result
        == .exception(
          .init(
            kind: .generalProtection,
            vector: 13,
            errorCode: 0,
            instructionPointer: 0x7000
          )))
    #expect(state.rip == 0x7000)
    #expect(state.registers.rsp == 0x6000)
  }

  @Test func exceptionEntryPushesArchitecturalErrorCode() throws {
    let memory = DoryX86ByteArrayMemory(byteCount: 0x10_000)
    try installSegments(memory)
    try installGate(
      vector: 14,
      target: 0x9000,
      selector: 0x8,
      attributes: 0x8E,
      memory: memory
    )
    var registers = DoryX86GeneralRegisters()
    registers.rsp = 0x5000
    var state = try DoryX86ArchitecturalState(
      registers: registers,
      rip: 0x8123,
      rflags: [.reservedOne, .interruptEnable],
      cs: .init(selector: 0x8, attributes: 0xA09B, limit: .max),
      ss: .init(selector: 0x10, attributes: 0xC093, limit: .max),
      gdtr: .init(limit: 0x1F, base: 0x1000),
      idtr: .init(limit: 0x0FFF, base: 0x2000)
    )
    try DoryX86InterruptDelivery().deliverException(
      .init(
        kind: .pageFault,
        vector: 14,
        errorCode: 5,
        instructionPointer: 0x8123,
        linearAddress: 0xDEAD_0000
      ),
      state: &state,
      physicalMemory: memory,
      mode: .long64
    )
    #expect(state.rip == 0x9000)
    #expect(state.registers.rsp == 0x4FD0)
    #expect(try read64(memory, 0x4FD0) == 5)
    #expect(try read64(memory, 0x4FD8) == 0x8123)
    #expect(try read64(memory, 0x4FE0) == 0x8)
    #expect(try read64(memory, 0x4FE8) == 0x202)
    #expect(try read64(memory, 0x4FF0) == 0x5000)
    #expect(try read64(memory, 0x4FF8) == 0x10)
  }

  private func installSegments(_ memory: DoryX86ByteArrayMemory) throws {
    try write64(memory, 0x1008, 0x00AF_9A00_0000_FFFF)
    try write64(memory, 0x1018, 0x00AF_FA00_0000_FFFF)
  }

  private func installGate(
    vector: UInt8,
    target: UInt64,
    selector: UInt16,
    attributes: UInt8,
    memory: DoryX86ByteArrayMemory
  ) throws {
    let low =
      (target & 0xFFFF)
      | UInt64(selector) << 16
      | UInt64(attributes) << 40
      | ((target >> 16) & 0xFFFF) << 48
    let high = target >> 32
    let address = 0x2000 + UInt64(vector) * 16
    try write64(memory, address, low)
    try write64(memory, address + 8, high)
  }

  private func write64(_ memory: DoryX86ByteArrayMemory, _ address: UInt64, _ value: UInt64) throws
  {
    try memory.write(
      at: address,
      bytes: (0..<8).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
    )
  }

  private func read64(_ memory: DoryX86ByteArrayMemory, _ address: UInt64) throws -> UInt64 {
    try memory.read(at: address, byteCount: 8).enumerated().reduce(0) {
      $0 | UInt64($1.element) << UInt64($1.offset * 8)
    }
  }
}
