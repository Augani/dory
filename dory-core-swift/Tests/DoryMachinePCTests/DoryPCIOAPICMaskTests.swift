import DoryDBTX86
import Testing

@testable import DoryMachinePC

@Suite struct DoryPCIOAPICMaskTests {
  @Test func remoteIRRReadbackTracksLevelDeliveryAndIgnoresGuestWrites() throws {
    let local = DoryPCLocalAPIC(apicID: 0)
    try local.configureSpuriousVector(0xFF, softwareEnabled: true)
    let io = DoryPCIOAPIC()
    try io.attach(local)
    io.seal()
    let mmio = DoryPCIOAPICMMIO(ioAPIC: io)
    try mmio.write(offset: 0, bytes: [0x10, 0, 0, 0])
    try mmio.write(offset: 0x10, bytes: [0x40, 0xC0, 0, 0])
    // Writing the read-only remote-IRR bit cannot manufacture a pending interrupt.
    #expect(try mmio.read(offset: 0x10, byteCount: 4) == [0x40, 0x80, 0, 0])
    try io.setAsserted(true, pin: 0)
    #expect(local.acknowledge(interruptsEnabled: true) == 0x40)
    #expect(try mmio.read(offset: 0x10, byteCount: 4) == [0x40, 0xC0, 0, 0])

    // Masking the route or writing zero to remote IRR does not acknowledge delivery.
    try mmio.write(offset: 0x10, bytes: [0x40, 0x80, 1, 0])
    try io.setAsserted(false, pin: 0)
    #expect(try mmio.read(offset: 0x10, byteCount: 4) == [0x40, 0xC0, 1, 0])
    #expect(local.endOfInterrupt() == 0x40)
    try io.endOfInterrupt(vector: 0x40, destinationAPICID: 0)
    #expect(try mmio.read(offset: 0x10, byteCount: 4) == [0x40, 0x80, 1, 0])

    // Edge delivery does not use remote IRR.
    try mmio.write(offset: 0x10, bytes: [0x41, 0, 0, 0])
    try io.setAsserted(true, pin: 0)
    #expect(local.acknowledge(interruptsEnabled: true) == 0x41)
    #expect(try mmio.read(offset: 0x10, byteCount: 4) == [0x41, 0, 0, 0])
  }

  @Test func freshRedirectionEntriesReadBackArchitecturalResetValues() throws {
    let ram = try DoryX86ByteArrayMemory(byteCount: 0x1000)
    let bus = try DoryPCPhysicalMemoryBus(ram: ram)
    let io = DoryPCIOAPIC()
    let mmio = DoryPCIOAPICMMIO(ioAPIC: io)
    try bus.attach(mmio)
    bus.seal()
    for pin in 0..<io.pinCount {
      let low = UInt64(0x10 + pin * 2)
      try bus.writeScalar(at: mmio.baseAddress, value: low, byteCount: 4)
      #expect(try bus.readScalar(at: mmio.baseAddress + 0x10, byteCount: 4) == 0x1_0000)
      try bus.writeScalar(at: mmio.baseAddress, value: low + 1, byteCount: 4)
      #expect(try bus.readScalar(at: mmio.baseAddress + 0x10, byteCount: 4) == 0)
      #expect(try io.route(for: pin) == .init(vector: 0, masked: true))
    }
  }

  @Test func maskedEntriesRetainReservedVectorsWithoutDeliveringInterrupts() throws {
    let local = DoryPCLocalAPIC(apicID: 0)
    try local.configureSpuriousVector(0xFF, softwareEnabled: true)
    let io = DoryPCIOAPIC()
    try io.attach(local)
    io.seal()
    for pin in 0..<io.pinCount {
      for vector: UInt8 in 0..<0x10 {
        for level in [false, true] {
          let masked = DoryPCIOAPICRoute(vector: vector, masked: true, levelTriggered: level)
          try io.configure(pin: pin, route: masked)
          try io.setAsserted(true, pin: pin)
          try io.endOfInterrupt(vector: vector, destinationAPICID: 0)
          #expect(try io.route(for: pin) == masked)
          #expect(local.acknowledge(interruptsEnabled: true) == nil)
          // The host routing API still rejects activation of an undeliverable vector,
          // preserving the prior masked route when validation fails.
          var invalid = masked
          invalid.masked = false
          #expect(throws: DoryPCAPICError.invalidVector(vector)) {
            try io.configure(pin: pin, route: invalid)
          }
          #expect(try io.route(for: pin) == masked)
          try io.setAsserted(false, pin: pin)
        }
      }
    }
    try io.configure(pin: 0, route: .init(vector: 0x40, masked: false, levelTriggered: true))
    try io.setAsserted(true, pin: 0)
    #expect(local.acknowledge(interruptsEnabled: true) == 0x40)
  }

  @Test func guestMMIOStoresReservedUnmaskedVectorWithoutInjecting() throws {
    let ram = try DoryX86ByteArrayMemory(byteCount: 0x1000)
    let bus = try DoryPCPhysicalMemoryBus(ram: ram)
    let local = DoryPCLocalAPIC(apicID: 0)
    try local.configureSpuriousVector(0xFF, softwareEnabled: true)
    let io = DoryPCIOAPIC()
    try io.attach(local)
    io.seal()
    let mmio = DoryPCIOAPICMMIO(ioAPIC: io)
    try bus.attach(mmio)
    bus.seal()

    // Linux can transiently store an unmasked zero-vector redirection entry while switching to
    // symmetric I/O mode. Cover the actual instruction shape from that path:
    // mov dword ptr [rax+0x10],esi.
    try bus.writeScalar(at: mmio.baseAddress, value: 0x14, byteCount: 4)
    try ram.write(at: 0, bytes: [0x89, 0x70, 0x10])
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: mmio.baseAddress, rsi: 0),
      rip: 0
    )
    let decoded = try DoryX86Decoder().decode([0x89, 0x70, 0x10], at: 0, mode: .long64)
    #expect(
      DoryX86Interpreter().step(state: &state, memory: bus, mode: .long64) == .retired(decoded)
    )
    #expect(try bus.readScalar(at: mmio.baseAddress + 0x10, byteCount: 4) == 0)
    try io.setAsserted(true, pin: 2)
    #expect(local.acknowledge(interruptsEnabled: true) == nil)

    try bus.writeScalar(at: mmio.baseAddress + 0x10, value: 0x31 | (1 << 15), byteCount: 4)
    #expect(local.acknowledge(interruptsEnabled: true) == 0x31)
  }

  @Test func guestMaskAndClearInstructionRetiresAndWindowReadsBackZeroVector() throws {
    let ram = try DoryX86ByteArrayMemory(byteCount: 0x1000)
    let bus = try DoryPCPhysicalMemoryBus(ram: ram)
    let io = DoryPCIOAPIC()
    let mmio = DoryPCIOAPICMMIO(ioAPIC: io)
    try bus.attach(mmio)
    bus.seal()
    // Reduced from Linux ioapic_mask_entry: mov dword ptr [rax+0x10],r8d.
    let bytes: [UInt8] = [0x44, 0x89, 0x40, 0x10]
    try ram.write(at: 0, bytes: bytes)
    for pin in 0..<io.pinCount {
      let low = UInt64(0x10 + pin * 2)
      try bus.writeScalar(at: mmio.baseAddress, value: low, byteCount: 4)
      var state = try DoryX86ArchitecturalState(
        registers: .init(rax: mmio.baseAddress, r8: 0x1_0000), rip: 0)
      let decoded = try DoryX86Decoder().decode(bytes, at: 0, mode: .long64)
      #expect(
        DoryX86Interpreter().step(state: &state, memory: bus, mode: .long64) == .retired(decoded)
      )
      #expect(state.rip == UInt64(bytes.count))
      #expect(try bus.readScalar(at: mmio.baseAddress + 0x10, byteCount: 4) == 0x1_0000)
      // The following destination write must also accept the still-masked zero vector.
      try bus.writeScalar(at: mmio.baseAddress, value: low + 1, byteCount: 4)
      try bus.writeScalar(at: mmio.baseAddress + 0x10, value: 0, byteCount: 4)
      #expect(try io.route(for: pin) == .init(vector: 0, masked: true))
    }
  }

  @Test(arguments: [false, true])
  func guestMMIOFixedDeliveryRoutesThroughLogicalDestinationMode(cluster: Bool) throws {
    let fixture = try ioAPICBusFixture(apicCount: 4)
    let logicalIDs: [UInt32] = cluster ? [0x11, 0x12, 0x14, 0x21] : [1, 2, 4, 8]
    for index in fixture.apics.indices {
      let localMMIO = DoryPCLocalAPICMMIO(apic: fixture.apics[index])
      try localMMIO.write(
        offset: 0xE0, bytes: ioAPICTestLittleEndian(cluster ? UInt32(0) : 0xFFFF_FFFF))
      try localMMIO.write(offset: 0xD0, bytes: ioAPICTestLittleEndian(logicalIDs[index] << 24))
    }
    try writeIOAPICRedirection(
      bus: fixture.bus,
      mmio: fixture.mmio,
      pin: 3,
      low: UInt32(0x44) | (1 << 11),
      high: UInt32(cluster ? 0x15 : 0x05) << 24
    )
    #expect(
      try readIOAPICRedirectionLow(bus: fixture.bus, mmio: fixture.mmio, pin: 3) == UInt32(0x44)
        | (1 << 11))

    try fixture.ioAPIC.setAsserted(true, pin: 3)

    for index in fixture.apics.indices {
      #expect(
        fixture.apics[index].acknowledge(interruptsEnabled: true)
          == ([0, 2].contains(index) ? 0x44 : nil))
      _ = fixture.apics[index].endOfInterrupt()
    }
  }

  @Test func guestMMIOLowestPrioritySelectsLowestProcessorPriorityThenAPICID() throws {
    let fixture = try ioAPICBusFixture(apicCount: 3)
    for index in fixture.apics.indices {
      let localMMIO = DoryPCLocalAPICMMIO(apic: fixture.apics[index])
      try localMMIO.write(offset: 0xE0, bytes: ioAPICTestLittleEndian(UInt32(0xFFFF_FFFF)))
      try localMMIO.write(offset: 0xD0, bytes: ioAPICTestLittleEndian(UInt32(1 << index) << 24))
    }
    fixture.apics[0].setTaskPriority(0x40)
    fixture.apics[1].setTaskPriority(0x10)
    fixture.apics[2].setTaskPriority(0x10)
    try writeIOAPICRedirection(
      bus: fixture.bus,
      mmio: fixture.mmio,
      pin: 5,
      low: UInt32(0x55) | (1 << 8) | (1 << 11),
      high: UInt32(0x07) << 24
    )

    try fixture.ioAPIC.setAsserted(true, pin: 5)
    #expect(fixture.apics[0].acknowledge(interruptsEnabled: true) == nil)
    #expect(fixture.apics[1].acknowledge(interruptsEnabled: true) == 0x55)
    #expect(fixture.apics[2].acknowledge(interruptsEnabled: true) == nil)

    try fixture.ioAPIC.setAsserted(false, pin: 5)
    try fixture.ioAPIC.setAsserted(true, pin: 5)
    #expect(fixture.apics[0].acknowledge(interruptsEnabled: true) == nil)
    #expect(fixture.apics[1].acknowledge(interruptsEnabled: true) == nil)
    #expect(fixture.apics[2].acknowledge(interruptsEnabled: true) == 0x55)
  }

  @Test func guestMMIOLogicalLevelInterruptReassertsAfterDeliveredAPICEOI() throws {
    let fixture = try ioAPICBusFixture(apicCount: 2)
    for index in fixture.apics.indices {
      let localMMIO = DoryPCLocalAPICMMIO(apic: fixture.apics[index])
      try localMMIO.write(offset: 0xE0, bytes: ioAPICTestLittleEndian(UInt32(0xFFFF_FFFF)))
      try localMMIO.write(offset: 0xD0, bytes: ioAPICTestLittleEndian(UInt32(1 << index) << 24))
    }
    try writeIOAPICRedirection(
      bus: fixture.bus,
      mmio: fixture.mmio,
      pin: 7,
      low: UInt32(0x57) | (1 << 11) | (1 << 15),
      high: UInt32(0x02) << 24
    )

    try fixture.ioAPIC.setAsserted(true, pin: 7)
    #expect(fixture.apics[1].acknowledge(interruptsEnabled: true) == 0x57)
    #expect(
      try readIOAPICRedirectionLow(bus: fixture.bus, mmio: fixture.mmio, pin: 7) == UInt32(0x57)
        | (1 << 11) | (1 << 14) | (1 << 15))
    #expect(fixture.apics[1].endOfInterrupt() == 0x57)
    try fixture.ioAPIC.endOfInterrupt(vector: 0x57, destinationAPICID: 1)
    #expect(fixture.apics[1].acknowledge(interruptsEnabled: true) == 0x57)
    try fixture.ioAPIC.setAsserted(false, pin: 7)
    #expect(fixture.apics[1].endOfInterrupt() == 0x57)
    try fixture.ioAPIC.endOfInterrupt(vector: 0x57, destinationAPICID: 1)
    #expect(
      try readIOAPICRedirectionLow(bus: fixture.bus, mmio: fixture.mmio, pin: 7) == UInt32(0x57)
        | (1 << 11) | (1 << 15))
  }

  @Test func logicalCanDeliverTracksMaskDestinationAndRemoteIRRState() throws {
    let fixture = try ioAPICBusFixture(apicCount: 2)
    for index in fixture.apics.indices {
      let localMMIO = DoryPCLocalAPICMMIO(apic: fixture.apics[index])
      try localMMIO.write(offset: 0xE0, bytes: ioAPICTestLittleEndian(UInt32(0xFFFF_FFFF)))
      try localMMIO.write(offset: 0xD0, bytes: ioAPICTestLittleEndian(UInt32(1 << index) << 24))
    }
    try writeIOAPICRedirection(
      bus: fixture.bus,
      mmio: fixture.mmio,
      pin: 6,
      low: UInt32(0x66) | (1 << 11) | (1 << 15),
      high: UInt32(0x02) << 24
    )

    #expect(try fixture.ioAPIC.canDeliver(pin: 6) { $0.apicID == 1 && $1 == 0x66 })
    try fixture.ioAPIC.setAsserted(true, pin: 6)
    #expect(!(try fixture.ioAPIC.canDeliver(pin: 6) { _, _ in true }))
    #expect(fixture.apics[1].acknowledge(interruptsEnabled: true) == 0x66)
    #expect(fixture.apics[1].endOfInterrupt() == 0x66)
    try fixture.ioAPIC.endOfInterrupt(vector: 0x66, destinationAPICID: 1)
    #expect(try fixture.ioAPIC.canDeliver(pin: 6) { $0.apicID == 1 && $1 == 0x66 } == false)
    #expect(fixture.apics[1].acknowledge(interruptsEnabled: true) == 0x66)
    #expect(fixture.apics[1].endOfInterrupt() == 0x66)
    try fixture.ioAPIC.setAsserted(false, pin: 6)
    try fixture.ioAPIC.endOfInterrupt(vector: 0x66, destinationAPICID: 1)
    #expect(try fixture.ioAPIC.canDeliver(pin: 6) { $0.apicID == 1 && $1 == 0x66 })
  }

  @Test func guestMMIOUnsupportedDeliveryModesReadBackWithoutHostExceptionOrInterrupt() throws {
    let fixture = try ioAPICBusFixture(apicCount: 1)
    for mode: UInt32 in [2, 3, 4, 5, 6, 7] {
      try fixture.ioAPIC.setAsserted(false, pin: 1)
      try writeIOAPICRedirection(
        bus: fixture.bus,
        mmio: fixture.mmio,
        pin: 1,
        low: UInt32(0x61) | (mode << 8),
        high: 0
      )
      #expect(
        try readIOAPICRedirectionLow(bus: fixture.bus, mmio: fixture.mmio, pin: 1) == UInt32(0x61)
          | (mode << 8))
      try fixture.ioAPIC.setAsserted(true, pin: 1)
      #expect(fixture.apics[0].acknowledge(interruptsEnabled: true) == nil)
    }
  }

}

private struct IOAPICBusFixture {
  let bus: DoryPCPhysicalMemoryBus
  let ioAPIC: DoryPCIOAPIC
  let mmio: DoryPCIOAPICMMIO
  let apics: [DoryPCLocalAPIC]
}

private func ioAPICBusFixture(apicCount: Int) throws -> IOAPICBusFixture {
  let ram = try DoryX86ByteArrayMemory(byteCount: 0x1000)
  let bus = try DoryPCPhysicalMemoryBus(ram: ram)
  let apics = (0..<apicCount).map { DoryPCLocalAPIC(apicID: UInt32($0)) }
  for apic in apics {
    try apic.configureSpuriousVector(0xFF, softwareEnabled: true)
  }
  let ioAPIC = DoryPCIOAPIC()
  for apic in apics { try ioAPIC.attach(apic) }
  ioAPIC.seal()
  let mmio = DoryPCIOAPICMMIO(ioAPIC: ioAPIC)
  try bus.attach(mmio)
  bus.seal()
  return IOAPICBusFixture(bus: bus, ioAPIC: ioAPIC, mmio: mmio, apics: apics)
}

private func writeIOAPICRedirection(
  bus: DoryPCPhysicalMemoryBus,
  mmio: DoryPCIOAPICMMIO,
  pin: Int,
  low: UInt32,
  high: UInt32
) throws {
  let register = UInt64(0x10 + pin * 2)
  try bus.writeScalar(at: mmio.baseAddress, value: register, byteCount: 4)
  try bus.writeScalar(at: mmio.baseAddress + 0x10, value: UInt64(low), byteCount: 4)
  try bus.writeScalar(at: mmio.baseAddress, value: register + 1, byteCount: 4)
  try bus.writeScalar(at: mmio.baseAddress + 0x10, value: UInt64(high), byteCount: 4)
}

private func readIOAPICRedirectionLow(
  bus: DoryPCPhysicalMemoryBus,
  mmio: DoryPCIOAPICMMIO,
  pin: Int
) throws -> UInt32 {
  try bus.writeScalar(at: mmio.baseAddress, value: UInt64(0x10 + pin * 2), byteCount: 4)
  return UInt32(try bus.readScalar(at: mmio.baseAddress + 0x10, byteCount: 4))
}

private func ioAPICTestLittleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
  (0..<MemoryLayout<T>.size).map { UInt8(truncatingIfNeeded: value >> T($0 * 8)) }
}
