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
}
