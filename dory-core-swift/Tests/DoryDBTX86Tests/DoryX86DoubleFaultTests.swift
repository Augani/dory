import Testing

@testable import DoryDBTX86

// Intel SDM Vol. 3A §7.14, Events 8 and 14, Tables 7-4 and 7-5.
// https://cdrdv2-public.intel.com/922487/253668-092-sdm-vol-3a.pdf
@Suite struct DoryX86DoubleFaultTests {
  @Test func exceptionPairClassifierMatchesTheIntelTable() {
    let benign: UInt8 = 6
    let contributory: UInt8 = 13
    let pageFault: UInt8 = 14
    let doubleFault: UInt8 = 8

    for first in [benign, contributory, pageFault, doubleFault] {
      for second in [benign, contributory, pageFault] {
        let expected: DoryX86ExceptionDeliveryAction =
          switch (first, second) {
          case (contributory, contributory),
            (pageFault, contributory),
            (pageFault, pageFault):
            .doubleFault
          case (doubleFault, contributory), (doubleFault, pageFault):
            .processorShutdown
          default:
            .serial
          }
        #expect(
          DoryX86InterruptDelivery.exceptionDeliveryAction(
            firstVector: first,
            secondVector: second
          ) == expected)
      }
    }
  }

  @Test func benignExceptionWithInvalidGateDeliversGeneralProtectionSerially() throws {
    let memory = try makeMemory()
    try installGate(vector: 13, target: 0x9000, memory: memory)
    var state = try makeState()

    try DoryX86InterruptDelivery().deliverException(
      .init(kind: .invalidOpcode, vector: 6, instructionPointer: state.rip),
      state: &state,
      physicalMemory: memory,
      mode: .long64
    )

    #expect(state.rip == 0x9000)
    #expect(state.registers.rsp == 0x7FD0)
    // Vector 6's IDT selector, with IDT and EXT set because #GP arose while
    // delivering an earlier exception.
    #expect(try memory.readScalar(at: 0x7FD0, byteCount: 8) == 0x33)
  }

  @Test func benignExceptionWithNotPresentGateDeliversSegmentNotPresentSerially() throws {
    let memory = try makeMemory()
    try installGate(vector: 6, target: 0x8800, attributes: 0x0E, memory: memory)
    try installGate(vector: 11, target: 0x9100, memory: memory)
    var state = try makeState()

    try DoryX86InterruptDelivery().deliverException(
      .init(kind: .invalidOpcode, vector: 6, instructionPointer: state.rip),
      state: &state,
      physicalMemory: memory,
      mode: .long64
    )

    #expect(state.rip == 0x9100)
    #expect(state.registers.rsp == 0x7FD0)
    #expect(try memory.readScalar(at: 0x7FD0, byteCount: 8) == 0x33)
  }

  @Test func contributoryThenPageFaultIsSerialAndPublishesSecondCR2() throws {
    let backing = try makeMemory()
    try installGate(vector: 14, target: 0x9200, memory: backing)
    let fault = DoryX86MemoryError.pageFault(address: 0xDEAD_1000, errorCode: 2)
    let memory = DeliveryReadFaultMemory(
      backing: backing,
      faultAddress: 0x2000 + UInt64(13) * 16,
      fault: fault
    )
    var state = try makeState()

    try DoryX86InterruptDelivery().deliverException(
      .init(kind: .generalProtection, vector: 13, errorCode: 0,
        instructionPointer: state.rip),
      state: &state,
      physicalMemory: memory,
      mode: .long64
    )

    #expect(state.rip == 0x9200)
    #expect(state.control.cr2 == 0xDEAD_1000)
    #expect(try backing.readScalar(at: 0x7FD0, byteCount: 8) == 2)
  }

  @Test func pageFaultThenPageFaultDeliversDoubleFaultAndOverwritesCR2() throws {
    let backing = try makeMemory()
    try installGate(vector: 8, target: 0x9300, memory: backing)
    let memory = DeliveryReadFaultMemory(
      backing: backing,
      faultAddress: 0x2000 + UInt64(14) * 16,
      fault: .pageFault(address: 0xBEEF_2000, errorCode: 0)
    )
    var state = try makeState()

    try DoryX86InterruptDelivery().deliverException(
      .init(kind: .pageFault, vector: 14, errorCode: 4,
        instructionPointer: state.rip, linearAddress: 0xAAAA_0000),
      state: &state,
      physicalMemory: memory,
      mode: .long64
    )

    #expect(state.rip == 0x9300)
    #expect(state.control.cr2 == 0xBEEF_2000)
    #expect(state.registers.rsp == 0x7FD0)
    #expect(try backing.readScalar(at: 0x7FD0, byteCount: 8) == 0)
  }

  @Test func contributoryThenContributoryDeliversDoubleFault() throws {
    let memory = try makeMemory()
    try installGate(vector: 8, target: 0x9380, memory: memory)
    var state = try makeState()

    try DoryX86InterruptDelivery().deliverException(
      .init(kind: .generalProtection, vector: 13, errorCode: 0,
        instructionPointer: state.rip),
      state: &state,
      physicalMemory: memory,
      mode: .long64
    )

    #expect(state.rip == 0x9380)
    #expect(state.registers.rsp == 0x7FD0)
    #expect(try memory.readScalar(at: 0x7FD0, byteCount: 8) == 0)
  }

  @Test func contributoryFaultDuringDoubleFaultEntryEntersProcessorShutdown() throws {
    let memory = try makeMemory()
    var state = try makeState()

    #expect(throws: DoryX86InterruptDeliveryError.processorShutdown) {
      try DoryX86InterruptDelivery().deliverException(
        .init(kind: .doubleFault, vector: 8, errorCode: 0,
          instructionPointer: state.rip),
        state: &state,
        physicalMemory: memory,
        mode: .long64
      )
    }
  }

  @Test func hostBackingFailureIsNotReclassifiedAsProcessorShutdown() throws {
    let backing = try makeMemory()
    let failure = DoryX86MemoryError.unmapped(
      address: 0x2060,
      byteCount: 16,
      access: .read
    )
    let memory = DeliveryReadFaultMemory(
      backing: backing,
      faultAddress: 0x2060,
      fault: failure
    )
    var state = try makeState()

    #expect(throws: failure) {
      try DoryX86InterruptDelivery().deliverException(
        .init(kind: .invalidOpcode, vector: 6, instructionPointer: state.rip),
        state: &state,
        physicalMemory: memory,
        mode: .long64
      )
    }
  }

  private func makeMemory() throws -> DoryX86ByteArrayMemory {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x10_000)
    try memory.writeScalar(at: 0x1008, value: 0x00AF_9A00_0000_FFFF, byteCount: 8)
    return memory
  }

  private func makeState() throws -> DoryX86ArchitecturalState {
    try .init(
      registers: .init(rsp: 0x8000),
      rip: 0x8123,
      rflags: [.reservedOne, .interruptEnable],
      cs: .init(selector: 8, attributes: 0xA09B, limit: .max),
      ss: .init(selector: 16, attributes: 0xC093, limit: .max),
      gdtr: .init(limit: 0x17, base: 0x1000),
      idtr: .init(limit: 0x0FFF, base: 0x2000)
    )
  }

  private func installGate(
    vector: UInt8,
    target: UInt64,
    attributes: UInt8 = 0x8E,
    memory: DoryX86ByteArrayMemory
  ) throws {
    let low =
      (target & 0xFFFF)
      | UInt64(8) << 16
      | UInt64(attributes) << 40
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

private final class DeliveryReadFaultMemory: DoryX86Memory, @unchecked Sendable {
  let backing: DoryX86ByteArrayMemory
  let faultAddress: UInt64
  let fault: DoryX86MemoryError

  init(
    backing: DoryX86ByteArrayMemory,
    faultAddress: UInt64,
    fault: DoryX86MemoryError
  ) {
    self.backing = backing
    self.faultAddress = faultAddress
    self.fault = fault
  }

  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    try backing.instructionBytes(at: address, maximumCount: maximumCount)
  }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    if address == faultAddress { throw fault }
    return try backing.read(at: address, byteCount: byteCount)
  }

  func validateWrite(at address: UInt64, byteCount: Int) throws {
    try backing.validateWrite(at: address, byteCount: byteCount)
  }

  func write(at address: UInt64, bytes: [UInt8]) throws {
    try backing.write(at: address, bytes: bytes)
  }
}
