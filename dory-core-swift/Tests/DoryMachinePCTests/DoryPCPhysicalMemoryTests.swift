import DoryDBTX86
import Testing

@testable import DoryMachinePC

@Suite struct DoryPCPhysicalMemoryTests {
  @Test func sealedBusRoutesRAMAndStandardAPICWindows() throws {
    let ram = DoryX86ByteArrayMemory(byteCount: 0x1000)
    let bus = DoryPCPhysicalMemoryBus(ram: ram)
    let local = DoryPCLocalAPIC(apicID: 2)
    let io = DoryPCIOAPIC()
    try io.attach(local)
    io.seal()
    try bus.attach(DoryPCLocalAPICMMIO(apic: local))
    try bus.attach(DoryPCIOAPICMMIO(ioAPIC: io))
    bus.seal()

    try bus.write(at: 0x100, bytes: [1, 2, 3, 4])
    #expect(try bus.read(at: 0x100, byteCount: 4) == [1, 2, 3, 4])
    #expect(try bus.read(at: 0xFEE0_0020, byteCount: 4) == [0, 0, 0, 2])
    #expect(throws: DoryPCPhysicalMemoryError.sealed) {
      try bus.attach(DoryPCLocalAPICMMIO(apic: local, baseAddress: 0xFED0_0000))
    }
  }

  @Test func routingRemainsExactAcrossSealedTablePublication() throws {
    let ram = DoryX86ByteArrayMemory(byteCount: 0x4000)
    let bus = DoryPCPhysicalMemoryBus(ram: ram)
    let first = TestMMIODevice(baseAddress: 0x1000, byteCount: 0x100)
    let second = TestMMIODevice(baseAddress: 0x3000, byteCount: 0x100)
    try bus.attach(first)
    try bus.attach(second)

    try bus.writeScalar(at: 0x0800, value: 0x4433_2211, byteCount: 4)
    try bus.write(at: 0x1010, bytes: [1, 2, 3, 4])
    #expect(try bus.readScalar(at: 0x0800, byteCount: 4) == 0x4433_2211)
    #expect(try bus.read(at: 0x1010, byteCount: 4) == [1, 2, 3, 4])

    bus.seal()
    try bus.writeScalar(at: 0x2000, value: 0x8877_6655_4433_2211, byteCount: 8)
    try bus.write(at: 0x3020, bytes: [5, 6, 7, 8])
    #expect(try bus.readScalar(at: 0x2000, byteCount: 8) == 0x8877_6655_4433_2211)
    #expect(try bus.read(at: 0x3020, byteCount: 4) == [5, 6, 7, 8])
    #expect(throws: DoryX86MemoryError.self) {
      try bus.read(at: 0x0FFF, byteCount: 2)
    }
    #expect(throws: DoryX86MemoryError.self) {
      try bus.read(at: 0x30FF, byteCount: 2)
    }
  }

  @Test func localAPICMMIOProgramsPrioritySpuriousVectorAndTimer() throws {
    let local = DoryPCLocalAPIC(apicID: 0)
    let mmio = DoryPCLocalAPICMMIO(apic: local)

    try mmio.write(offset: 0x80, bytes: [0x30, 0, 0, 0])
    try mmio.write(offset: 0xF0, bytes: [0x0F, 1, 0, 0])
    try mmio.write(offset: 0x320, bytes: [0x05, 0, 2, 0])
    #expect(try mmio.read(offset: 0x320, byteCount: 4) == [0x05, 0, 2, 0])
    try mmio.write(offset: 0x320, bytes: [0x52, 0, 2, 0])
    try mmio.write(offset: 0x380, bytes: [10, 0, 0, 0])
    local.advanceTimer(by: 10)

    let snapshot = local.snapshot()
    #expect(snapshot.softwareEnabled)
    #expect(snapshot.spuriousVector == 0x0F)
    #expect(snapshot.taskPriority == 0x30)
    #expect(snapshot.timer.mode == .periodic)
    #expect(snapshot.interruptRequest == [0x52])
    #expect(try mmio.read(offset: 0x200 + 0x20, byteCount: 4) == [0, 0, 4, 0])
  }

  @Test func ioAPICWindowProgramsRedirectionEntries() throws {
    let local = DoryPCLocalAPIC(apicID: 3)
    try local.configureSpuriousVector(0xFF, softwareEnabled: true)
    let io = DoryPCIOAPIC()
    try io.attach(local)
    io.seal()
    let mmio = DoryPCIOAPICMMIO(ioAPIC: io)

    // Redirection entry 5 low: vector 0x45, active low, level triggered, unmasked.
    try mmio.write(offset: 0, bytes: [0x1A, 0, 0, 0])
    try mmio.write(offset: 0x10, bytes: [0x45, 0xA0, 0, 0])
    try mmio.write(offset: 0, bytes: [0x1B, 0, 0, 0])
    try mmio.write(offset: 0x10, bytes: [0, 0, 0, 3])
    try io.setAsserted(true, pin: 5)

    let route = try io.route(for: 5)
    #expect(route.vector == 0x45)
    #expect(route.activeLow)
    #expect(route.levelTriggered)
    #expect(route.destinationAPICID == 3)
    #expect(local.acknowledge(interruptsEnabled: true) == 0x45)
  }

  @Test func busRejectsOverlapCrossBoundaryAndMMIOInstructionFetch() throws {
    let ram = DoryX86ByteArrayMemory(byteCount: 0x1000)
    let bus = DoryPCPhysicalMemoryBus(ram: ram)
    let local = DoryPCLocalAPIC(apicID: 0)
    try bus.attach(DoryPCLocalAPICMMIO(apic: local))
    #expect(
      throws: DoryPCPhysicalMemoryError.overlappingRange(
        base: 0xFEE0_0000, byteCount: 0x1000)
    ) {
      try bus.attach(DoryPCLocalAPICMMIO(apic: local))
    }
    bus.seal()
    #expect(throws: DoryX86MemoryError.self) {
      try bus.instructionBytes(at: 0xFEE0_0000, maximumCount: 15)
    }
    #expect(throws: DoryPCPhysicalMemoryError.self) {
      try bus.read(at: 0xFEE0_0001, byteCount: 4)
    }
  }

  @Test func bulkStringCopiesStayInsideOrdinaryRAM() throws {
    let ram = DoryX86ByteArrayMemory(byteCount: 0x1000)
    let bus = DoryPCPhysicalMemoryBus(ram: ram)
    let local = DoryPCLocalAPIC(apicID: 0)
    try bus.attach(DoryPCLocalAPICMMIO(apic: local))
    bus.seal()
    try ram.write(at: 0x100, bytes: [1, 2, 3, 4])

    #expect(
      try bus.copyForwardNonoverlapping(
        from: 0x100, to: 0x200, maximumByteCount: 4) == 4
    )
    #expect(try ram.read(at: 0x200, byteCount: 4) == [1, 2, 3, 4])
    #expect(
      try bus.copyForwardNonoverlapping(
        from: 0xFEE0_0000, to: 0x200, maximumByteCount: 4) == nil
    )
    #expect(
      try bus.copyForwardNonoverlapping(
        from: 0x100, to: 0x102, maximumByteCount: 4) == nil
    )
  }

  @Test func remapsCompactRAMAboveTheGuestMMIOHole() throws {
    let ram = DoryX86ByteArrayMemory(byteCount: 0x1200)
    let bus = DoryPCPhysicalMemoryBus(
      ram: ram,
      mmioHoleStart: 0x1000,
      above4GRAMStart: 0x2000
    )
    bus.seal()

    try bus.write(at: 0x0FFE, bytes: [1, 2])
    try bus.write(at: 0x2000, bytes: [3, 4, 5, 6])

    #expect(try ram.read(at: 0x0FFE, byteCount: 2) == [1, 2])
    #expect(try ram.read(at: 0x1000, byteCount: 4) == [3, 4, 5, 6])
    #expect(try bus.read(at: 0x2000, byteCount: 4) == [3, 4, 5, 6])
    #expect(bus.bulkCopyRAMSpan(at: 0x2000, maximumByteCount: 0x400) == 0x200)
    #expect(throws: DoryX86MemoryError.self) {
      try bus.read(at: 0x1000, byteCount: 1)
    }
    #expect(throws: DoryX86MemoryError.self) {
      try bus.read(at: 0x0FFF, byteCount: 2)
    }
    #expect(throws: DoryX86MemoryError.self) {
      try bus.read(at: 0x2200, byteCount: 1)
    }

    try bus.writeScalar(at: 0x2008, value: 0x8877_6655_4433_2211, byteCount: 8)
    #expect(try bus.readScalar(at: 0x2008, byteCount: 8) == 0x8877_6655_4433_2211)
    #expect(try ram.read(at: 0x1008, byteCount: 8) == [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88])
  }

  @Test func highRAMDMAAndBulkCopiesUseTheCompactBackingRange() throws {
    let ram = DoryX86ByteArrayMemory(byteCount: 0x1200)
    let bus = DoryPCPhysicalMemoryBus(
      ram: ram,
      mmioHoleStart: 0x1000,
      above4GRAMStart: 0x2000
    )
    try bus.attach(
      DoryPCLocalAPICMMIO(apic: .init(apicID: 0), baseAddress: 0x800)
    )
    bus.seal()
    try ram.write(at: 0x1000, bytes: [9, 8, 7, 6])

    try bus.validateDMA(at: 0x2000, byteCount: 4, deviceWillWrite: false)
    #expect(
      try bus.copyForwardNonoverlapping(
        from: 0x2000, to: 0x100, maximumByteCount: 4) == 4
    )
    #expect(try ram.read(at: 0x100, byteCount: 4) == [9, 8, 7, 6])
    #expect(bus.bulkCopyRAMSpan(at: 0x7FF, maximumByteCount: 4) == 1)
    #expect(bus.bulkCopyRAMSpan(at: 0x800, maximumByteCount: 4) == nil)
    #expect(throws: DoryX86MemoryError.self) {
      try bus.validateDMA(at: 0x1000, byteCount: 1, deviceWillWrite: true)
    }
  }
}

private final class TestMMIODevice: DoryPCMMIODevice, @unchecked Sendable {
  let baseAddress: UInt64
  let byteCount: UInt64
  private var storage: [UInt8]

  init(baseAddress: UInt64, byteCount: UInt64) {
    self.baseAddress = baseAddress
    self.byteCount = byteCount
    storage = Array(repeating: 0, count: Int(byteCount))
  }

  func read(offset: UInt64, byteCount: Int) throws -> [UInt8] {
    let lower = Int(offset)
    return Array(storage[lower..<(lower + byteCount)])
  }

  func write(offset: UInt64, bytes: [UInt8]) throws {
    let lower = Int(offset)
    storage.replaceSubrange(lower..<(lower + bytes.count), with: bytes)
  }
}
