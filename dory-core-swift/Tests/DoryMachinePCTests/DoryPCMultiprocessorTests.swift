import DoryMachinePC
import Testing

@Suite struct DoryPCMultiprocessorTests {
  @Test(arguments: [false, true])
  func logicalICRRoutesThroughGuestProgrammedDestinationRegisters(cluster: Bool) throws {
    let apics = (0..<4).map { DoryPCLocalAPIC(apicID: UInt32($0)) }
    let controller = try DoryPCMultiprocessorController(localAPICs: apics)
    let registers = apics.map { apic in
      DoryPCLocalAPICMMIO(apic: apic, onInterruptCommand: { high, low in
        try controller.handleInterruptCommand(sourceAPICID: apic.apicID, high: high, low: low)
      })
    }
    let logicalIDs: [UInt32] = cluster ? [0x11, 0x12, 0x14, 0x21] : [1, 2, 4, 8]
    for index in apics.indices {
      #expect(read32(try registers[index].read(offset: 0xE0, byteCount: 4)) == 0xFFFF_FFFF)
      #expect(read32(try registers[index].read(offset: 0xD0, byteCount: 4)) == 0)
      try registers[index].write(offset: 0xE0, bytes: littleEndian(cluster ? UInt32(0) : 0xFFFF_FFFF))
      try registers[index].write(offset: 0xD0, bytes: littleEndian(logicalIDs[index] << 24 | 0x00FF_FFFF))
      #expect(read32(try registers[index].read(offset: 0xD0, byteCount: 4)) == logicalIDs[index] << 24)
      #expect(read32(try registers[index].read(offset: 0xE0, byteCount: 4)) == (cluster ? 0x0FFF_FFFF : 0xFFFF_FFFF))
      try apics[index].configureSpuriousVector(0xFF, softwareEnabled: true)
    }
    // Select processors 0 and 2; the same low mask in another cluster must not match.
    try registers[0].write(offset: 0x310, bytes: littleEndian(UInt32(cluster ? 0x15 : 5) << 24))
    try registers[0].write(offset: 0x300, bytes: littleEndian(UInt32(0x51 | 1 << 11)))
    for index in apics.indices {
      #expect(apics[index].acknowledge(interruptsEnabled: true) == ([0, 2].contains(index) ? 0x51 : nil))
      _ = apics[index].endOfInterrupt()
    }
    // The all-ones destination broadcasts in physical and logical mode, across clusters.
    for destinationMode: UInt32 in [0, 1 << 11] {
      try registers[0].write(offset: 0x310, bytes: littleEndian(UInt32(0xFF00_0000)))
      try registers[0].write(offset: 0x300, bytes: littleEndian(0x52 | destinationMode))
      for apic in apics {
        #expect(apic.acknowledge(interruptsEnabled: true) == 0x52)
        _ = apic.endOfInterrupt()
      }
    }
  }

  @Test(arguments: [UInt32(1), 2, 3])
  func shorthandICRIgnoresLogicalDestinationMode(shorthand: UInt32) throws {
    let apics = (0..<3).map { DoryPCLocalAPIC(apicID: UInt32($0)) }
    for apic in apics { try apic.configureSpuriousVector(0xFF, softwareEnabled: true) }
    let controller = try DoryPCMultiprocessorController(localAPICs: apics)
    try controller.handleInterruptCommand(sourceAPICID: 1, high: 0xFE00_0000,
      low: 0x53 | 1 << 11 | shorthand << 18)
    for index in apics.indices {
      let selected = shorthand == 2 || (shorthand == 1 ? index == 1 : index != 1)
      #expect(apics[index].acknowledge(interruptsEnabled: true) == (selected ? 0x53 : nil))
    }
  }

  @Test func initAndStartupSequenceTransitionsOnlyTargetedApplicationProcessor() throws {
    let apics = (0..<4).map { DoryPCLocalAPIC(apicID: UInt32($0)) }
    let controller = try DoryPCMultiprocessorController(localAPICs: apics)

    try controller.handleInterruptCommand(
      sourceAPICID: 0,
      high: 2 << 24,
      low: 5 << 8 | 1 << 14 | 1 << 15
    )
    try controller.handleInterruptCommand(
      sourceAPICID: 0,
      high: 2 << 24,
      low: 6 << 8 | 0x09
    )
    // A second SIPI after the AP is running is ignored.
    try controller.handleInterruptCommand(
      sourceAPICID: 0,
      high: 2 << 24,
      low: 6 << 8 | 0x0A
    )

    #expect(
      controller.drainEvents() == [
        .initialize(apicID: 2),
        .startup(apicID: 2, vector: 9),
      ])
    #expect(controller.snapshot().lifecycles[2] == .running)
    #expect(controller.snapshot().lifecycles[1] == .waitingForStartup)
  }

  @Test func fixedLowestAndShorthandIPIsReachTheExpectedAPICs() throws {
    let apics = (0..<3).map { DoryPCLocalAPIC(apicID: UInt32($0)) }
    for apic in apics { try apic.configureSpuriousVector(0xFF, softwareEnabled: true) }
    let controller = try DoryPCMultiprocessorController(localAPICs: apics)

    try controller.handleInterruptCommand(
      sourceAPICID: 0,
      high: 1 << 24,
      low: 0x51
    )
    #expect(apics[1].acknowledge(interruptsEnabled: true) == 0x51)
    _ = apics[1].endOfInterrupt()

    try controller.handleInterruptCommand(
      sourceAPICID: 0,
      high: 0,
      low: 0x52 | 3 << 18
    )
    #expect(apics[0].acknowledge(interruptsEnabled: true) == nil)
    #expect(apics[1].acknowledge(interruptsEnabled: true) == 0x52)
    #expect(apics[2].acknowledge(interruptsEnabled: true) == 0x52)
  }

  @Test func lowestPriorityICRUsesArbitrationPriorityBeforeAPICIDTieBreak() throws {
    let apics = (0..<4).map { DoryPCLocalAPIC(apicID: UInt32($0)) }
    for apic in apics { try apic.configureSpuriousVector(0xFF, softwareEnabled: true) }
    let controller = try DoryPCMultiprocessorController(localAPICs: apics)
    apics[1].setTaskPriority(0x50)
    apics[2].setTaskPriority(0x10)
    apics[3].setTaskPriority(0x10)
    try apics[2].inject(vector: 0x70)

    try controller.handleInterruptCommand(
      sourceAPICID: 0,
      high: 0,
      low: UInt32(0x63) | UInt32(1 << 8) | UInt32(3 << 18)
    )

    #expect(apics[1].acknowledge(interruptsEnabled: true) == nil)
    #expect(apics[2].acknowledge(interruptsEnabled: true) == 0x70)
    #expect(apics[2].acknowledge(interruptsEnabled: true) == nil)
    #expect(apics[3].acknowledge(interruptsEnabled: true) == 0x63)
  }

  @Test func localAPICMMIOPublishesAndExecutesICRRegisters() throws {
    let apics = [DoryPCLocalAPIC(apicID: 0), DoryPCLocalAPIC(apicID: 1)]
    let controller = try DoryPCMultiprocessorController(localAPICs: apics)
    let mmio = DoryPCLocalAPICMMIO(
      apic: apics[0],
      onInterruptCommand: { high, low in
        try controller.handleInterruptCommand(sourceAPICID: 0, high: high, low: low)
      }
    )

    try mmio.write(offset: 0x310, bytes: littleEndian(UInt32(1 << 24)))
    try mmio.write(offset: 0x300, bytes: littleEndian(UInt32(6 << 8 | 8)))

    #expect(read32(try mmio.read(offset: 0x310, byteCount: 4)) == 1 << 24)
    #expect(read32(try mmio.read(offset: 0x300, byteCount: 4)) == 6 << 8 | 8)
    #expect(controller.drainEvents() == [.startup(apicID: 1, vector: 8)])
  }
}

private func read32(_ bytes: [UInt8]) -> UInt32 {
  bytes.enumerated().reduce(0) { $0 | UInt32($1.element) << UInt32($1.offset * 8) }
}

private func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
  (0..<MemoryLayout<T>.size).map { UInt8(truncatingIfNeeded: value >> T($0 * 8)) }
}
