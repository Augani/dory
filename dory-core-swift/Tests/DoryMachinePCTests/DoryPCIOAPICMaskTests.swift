import DoryDBTX86
import Testing

@testable import DoryMachinePC

@Suite struct DoryPCIOAPICMaskTests {
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
}
