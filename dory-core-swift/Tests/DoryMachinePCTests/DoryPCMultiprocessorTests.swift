import DoryMachinePC
import Testing

@Suite struct DoryPCMultiprocessorTests {
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
