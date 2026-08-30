import DoryMachinePC
import Testing

@Suite struct DoryPCXHCITests {
  @Test func publishesXHCI12PCIAndProtocolCapabilities() throws {
    let xhci = try DoryPCXHCIController()
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      pciFunctions: [xhci]
    )
    try xhci.writeConfiguration(offset: 4, bytes: [2, 0])

    #expect(try xhci.readConfiguration(offset: 0, byteCount: 4) == [0xF4, 0x1A, 0, 0x11])
    #expect(try xhci.readConfiguration(offset: 9, byteCount: 3) == [0x30, 0x03, 0x0C])
    #expect(try read8(machine, DoryPCV1ABI.xhciBARAddress) == 0x40)
    #expect(try read16(machine, DoryPCV1ABI.xhciBARAddress + 2) == 0x0120)
    #expect(try read32(machine, DoryPCV1ABI.xhciBARAddress + 0x14) == 0x2000)
    #expect(try read32(machine, DoryPCV1ABI.xhciBARAddress + 0x18) == 0x1000)
    #expect(try read32(machine, DoryPCV1ABI.xhciBARAddress + 0x104) == 0x2042_5355)
    #expect(try read32(machine, DoryPCV1ABI.xhciBARAddress + 0x114) == 0x2042_5355)
  }

  @Test func portConnectResetAndDisconnectProduceEventsAndMSI() throws {
    let xhci = try DoryPCXHCIController()
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      pciFunctions: [xhci]
    )
    let bar = DoryPCV1ABI.xhciBARAddress

    try xhci.writeConfiguration(offset: 4, bytes: [2, 0])
    try xhci.writeConfiguration(offset: 0x54, bytes: littleEndian(UInt32(0xFEE0_0000)))
    try xhci.writeConfiguration(offset: 0x5C, bytes: [0x76, 0])
    try xhci.writeConfiguration(offset: 0x52, bytes: [1, 0])

    try machine.physicalMemory.write(
      at: 0x1000,
      bytes: littleEndian(UInt64(0x2000)) + littleEndian(UInt32(16)) + [0, 0, 0, 0]
    )
    try write32(machine, bar + 0x1028, 1)
    try write64(machine, bar + 0x1030, 0x1000)
    try write64(machine, bar + 0x1038, 0x2000)
    try write32(machine, bar + 0x1020, 2)
    try write32(machine, bar + 0x40, 5)

    try xhci.connect(port: 1, speed: .high)
    let connected = try read32(machine, bar + 0x440)
    #expect(connected & 1 != 0)
    #expect((connected >> 10) & 0xF == 3)
    #expect(connected & (1 << 17) != 0)
    #expect(try read32(machine, 0x2000) == 1 << 24)
    #expect(try read32(machine, 0x2008) == 1 << 24)
    #expect((try read32(machine, 0x200C) >> 10) & 0x3F == 34)
    #expect(machine.localAPIC.snapshot().interruptRequest.contains(0x76))

    try write32(machine, bar + 0x440, 1 << 4)
    let reset = try read32(machine, bar + 0x440)
    #expect(reset & (1 << 1) != 0)
    #expect(reset & (1 << 4) == 0)
    #expect(reset & (1 << 21) != 0)

    try xhci.disconnect(port: 1)
    let disconnected = try xhci.portState(1)
    #expect(!disconnected.connected)
    #expect(!disconnected.enabled)
    #expect(disconnected.statusChangePending)
  }

  @Test func hostControllerResetPreservesAttachmentButClearsRuntimeState() throws {
    let xhci = try DoryPCXHCIController()
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      pciFunctions: [xhci]
    )
    let bar = DoryPCV1ABI.xhciBARAddress
    try xhci.writeConfiguration(offset: 4, bytes: [2, 0])
    try xhci.connect(port: 5, speed: .superSpeed)
    try write32(machine, bar + 0x78, 12)
    try write32(machine, bar + 0x40, 1 << 1)

    #expect(try read32(machine, bar + 0x40) == 0)
    #expect(try read32(machine, bar + 0x44) & 1 != 0)
    #expect(try read32(machine, bar + 0x78) == 0)
    #expect(try xhci.portState(5).connected)
  }

  @Test func commandRingEnablesAndDisablesDeviceSlots() throws {
    let xhci = try DoryPCXHCIController()
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      pciFunctions: [xhci]
    )
    let bar = DoryPCV1ABI.xhciBARAddress
    try xhci.writeConfiguration(offset: 4, bytes: [2, 0])
    try machine.physicalMemory.write(
      at: 0x1000,
      bytes: littleEndian(UInt64(0x2000)) + littleEndian(UInt32(16)) + [0, 0, 0, 0]
    )
    try machine.physicalMemory.write(
      at: 0x3000,
      bytes: [UInt8](repeating: 0, count: 12) + littleEndian(UInt32(9 << 10 | 1))
    )
    try machine.physicalMemory.write(
      at: 0x3010,
      bytes: [UInt8](repeating: 0, count: 12) + littleEndian(UInt32(1 << 24 | 10 << 10))
    )
    try write32(machine, bar + 0x1028, 1)
    try write64(machine, bar + 0x1030, 0x1000)
    try write64(machine, bar + 0x1038, 0x2000)
    try write64(machine, bar + 0x58, 0x3001)
    try write32(machine, bar + 0x78, 8)
    try write32(machine, bar + 0x40, 1)

    try write32(machine, bar + 0x2000, 0)
    #expect(xhci.slotStates == [.init(slotID: 1, addressed: false)])
    #expect(try read64(machine, 0x2000) == 0x3000)
    #expect(try read32(machine, 0x2008) >> 24 == 1)
    #expect(try read32(machine, 0x200C) >> 24 == 1)
    #expect((try read32(machine, 0x200C) >> 10) & 0x3F == 33)

    try write32(machine, 0x301C, 1 << 24 | 10 << 10 | 1)
    try write32(machine, bar + 0x2000, 0)
    #expect(xhci.slotStates.isEmpty)
    #expect(try read64(machine, 0x2010) == 0x3010)
    #expect(try read32(machine, 0x2018) >> 24 == 1)
  }

  @Test func addressDeviceConsumesInputContextAndPublishesOutputContext() throws {
    let xhci = try DoryPCXHCIController()
    let usbDevice = DoryPCUSBRecordingDevice(
      speed: .high,
      queuedResults: [try .init(status: .success, payload: [0xAA, 0xBB, 0xCC])]
    )
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      pciFunctions: [xhci]
    )
    let bar = DoryPCV1ABI.xhciBARAddress
    try xhci.writeConfiguration(offset: 4, bytes: [2, 0])
    try xhci.connect(port: 1, device: usbDevice)
    try machine.physicalMemory.write(
      at: 0x1000,
      bytes: littleEndian(UInt64(0x2000)) + littleEndian(UInt32(16)) + [0, 0, 0, 0]
    )
    try machine.physicalMemory.write(at: 0x4008, bytes: littleEndian(UInt64(0x6000)))
    var input = [UInt8](repeating: 0, count: 96)
    input.replaceSubrange(4..<8, with: littleEndian(UInt32(3)))
    input.replaceSubrange(32..<36, with: littleEndian(UInt32(1 << 27 | 3 << 20)))
    input.replaceSubrange(36..<40, with: littleEndian(UInt32(1 << 16)))
    input.replaceSubrange(68..<72, with: littleEndian(UInt32(64 << 16 | 4 << 3)))
    input.replaceSubrange(72..<80, with: littleEndian(UInt64(0x7001)))
    try machine.physicalMemory.write(at: 0x5000, bytes: input)
    let enable = [UInt8](repeating: 0, count: 12) + littleEndian(UInt32(9 << 10 | 1))
    let address =
      littleEndian(UInt64(0x5000)) + [UInt8](repeating: 0, count: 4)
      + littleEndian(UInt32(1 << 24 | 11 << 10 | 1))
    try machine.physicalMemory.write(at: 0x3000, bytes: enable + address)
    try write32(machine, bar + 0x1028, 1)
    try write64(machine, bar + 0x1030, 0x1000)
    try write64(machine, bar + 0x1038, 0x2000)
    try write64(machine, bar + 0x58, 0x3001)
    try write64(machine, bar + 0x70, 0x4000)
    try write32(machine, bar + 0x78, 8)
    try write32(machine, bar + 0x40, 1)

    try write32(machine, bar + 0x2000, 0)
    #expect(xhci.slotStates == [.init(slotID: 1, addressed: true)])
    #expect(try read32(machine, 0x2028) >> 24 == 1)
    #expect(try read32(machine, 0x202C) >> 24 == 1)
    #expect(try read32(machine, 0x600C) & 0xFF == 1)
    #expect(try read32(machine, 0x600C) >> 27 == 2)
    #expect(try read32(machine, 0x6020) & 0x7 == 1)

    var configureInput = [UInt8](repeating: 0, count: 1_056)
    configureInput.replaceSubrange(4..<8, with: littleEndian(UInt32(1 << 3)))
    configureInput.replaceSubrange(132..<136, with: littleEndian(UInt32(512 << 16 | 6 << 3)))
    configureInput.replaceSubrange(136..<144, with: littleEndian(UInt64(0x9001)))
    try machine.physicalMemory.write(at: 0x8000, bytes: configureInput)
    try machine.physicalMemory.write(
      at: 0x3020,
      bytes: littleEndian(UInt64(0x8000)) + [UInt8](repeating: 0, count: 4)
        + littleEndian(UInt32(1 << 24 | 12 << 10 | 1))
    )
    try write32(machine, bar + 0x2000, 0)
    #expect(try read32(machine, 0x2038) >> 24 == 1)
    #expect(try read32(machine, 0x203C) >> 24 == 1)
    #expect(try read32(machine, 0x6060) & 0x7 == 1)

    try machine.physicalMemory.write(
      at: 0x9000,
      bytes: littleEndian(UInt64(0xA000)) + littleEndian(UInt32(4))
        + littleEndian(UInt32(1 << 5 | 1 << 10 | 1))
    )
    try write32(machine, bar + 0x2004, 3)
    #expect(try machine.physicalMemory.read(at: 0xA000, byteCount: 4) == [0xAA, 0xBB, 0xCC, 0])
    #expect(usbDevice.transfers.count == 1)
    #expect(usbDevice.transfers[0].type == .bulk)
    #expect(usbDevice.transfers[0].direction == .in)
    #expect(usbDevice.transfers[0].maximumResponseBytes == 4)
    #expect(try read64(machine, 0x2040) == 0x9000)
    #expect(try read32(machine, 0x2048) & 0xFF_FFFF == 1)
    #expect(try read32(machine, 0x2048) >> 24 == 13)
    #expect((try read32(machine, 0x204C) >> 10) & 0x3F == 32)
    #expect((try read32(machine, 0x204C) >> 16) & 0x1F == 3)

    usbDevice.enqueue(try .init(status: .success, payload: [1, 2, 3, 4]))
    let setup = UInt64(0x80) | UInt64(6) << 8 | UInt64(1) << 24 | UInt64(4) << 48
    try machine.physicalMemory.write(
      at: 0x7000,
      bytes: littleEndian(setup) + littleEndian(UInt32(8))
        + littleEndian(UInt32(3 << 16 | 2 << 10 | 1 << 6 | 1))
    )
    try machine.physicalMemory.write(
      at: 0x7010,
      bytes: littleEndian(UInt64(0xB000)) + littleEndian(UInt32(4))
        + littleEndian(UInt32(1 << 16 | 3 << 10 | 1))
    )
    try machine.physicalMemory.write(
      at: 0x7020,
      bytes: [UInt8](repeating: 0, count: 12)
        + littleEndian(UInt32(1 << 5 | 4 << 10 | 1))
    )
    try write32(machine, bar + 0x2004, 1)
    #expect(try machine.physicalMemory.read(at: 0xB000, byteCount: 4) == [1, 2, 3, 4])
    #expect(usbDevice.transfers.count == 2)
    #expect(usbDevice.transfers[1].type == .control)
    #expect(usbDevice.transfers[1].setup?.request == 6)
    #expect(try read64(machine, 0x2050) == 0x7020)
    #expect(try read32(machine, 0x2058) >> 24 == 1)

    usbDevice.enqueue(try .init(status: .success, payload: [1, 2, 3, 4, 5, 6]))
    try machine.physicalMemory.write(
      at: 0x9010,
      bytes: littleEndian(UInt64(0xA100)) + littleEndian(UInt32(4))
        + littleEndian(UInt32(1 << 4 | 1 << 10 | 1))
    )
    try machine.physicalMemory.write(
      at: 0x9020,
      bytes: littleEndian(UInt64(0xA200)) + littleEndian(UInt32(4))
        + littleEndian(UInt32(1 << 4 | 1 << 10 | 1))
    )
    try machine.physicalMemory.write(
      at: 0x9030,
      bytes: littleEndian(UInt64(0xDEAD_BEEF)) + [UInt8](repeating: 0, count: 4)
        + littleEndian(UInt32(1 << 5 | 7 << 10 | 1))
    )
    try write32(machine, bar + 0x2004, 3)
    #expect(try machine.physicalMemory.read(at: 0xA100, byteCount: 4) == [1, 2, 3, 4])
    #expect(try machine.physicalMemory.read(at: 0xA200, byteCount: 4) == [5, 6, 0, 0])
    #expect(usbDevice.transfers[2].maximumResponseBytes == 8)
    #expect(try read64(machine, 0x2060) == 0xDEAD_BEEF)
    #expect(try read32(machine, 0x2068) & 0xFF_FFFF == 6)
    #expect(try read32(machine, 0x2068) >> 24 == 13)
    #expect(try read32(machine, 0x206C) & (1 << 2) != 0)

    usbDevice.enqueue(try .init(status: .stalled))
    try machine.physicalMemory.write(
      at: 0x9040,
      bytes: littleEndian(UInt64(0xA300)) + littleEndian(UInt32(8))
        + littleEndian(UInt32(1 << 10 | 1))
    )
    try write32(machine, bar + 0x2004, 3)
    #expect(try read32(machine, 0x6060) & 0x7 == 2)
    #expect(try read32(machine, 0x2078) >> 24 == 6)

    try machine.physicalMemory.write(
      at: 0x3030,
      bytes: [UInt8](repeating: 0, count: 12)
        + littleEndian(UInt32(1 << 24 | 3 << 16 | 14 << 10 | 1))
    )
    try write32(machine, bar + 0x2000, 0)
    #expect(try read32(machine, 0x6060) & 0x7 == 3)
    #expect(try read32(machine, 0x2088) >> 24 == 1)

    try machine.physicalMemory.write(
      at: 0x3040,
      bytes: littleEndian(UInt64(0x9101)) + [UInt8](repeating: 0, count: 4)
        + littleEndian(UInt32(1 << 24 | 3 << 16 | 16 << 10 | 1))
    )
    try write32(machine, bar + 0x2000, 0)
    #expect(try read64(machine, 0x6068) == 0x9101)
    #expect(try read32(machine, 0x2098) >> 24 == 1)

    try write32(machine, bar + 0x2004, 3)
    #expect(try read32(machine, 0x6060) & 0x7 == 1)
    try machine.physicalMemory.write(
      at: 0x3050,
      bytes: [UInt8](repeating: 0, count: 12)
        + littleEndian(UInt32(1 << 24 | 3 << 16 | 15 << 10 | 1))
    )
    try write32(machine, bar + 0x2000, 0)
    #expect(try read32(machine, 0x6060) & 0x7 == 3)
    #expect(try read32(machine, 0x20A8) >> 24 == 1)

    var evaluateInput = [UInt8](repeating: 0, count: 1_056)
    evaluateInput.replaceSubrange(4..<8, with: littleEndian(UInt32(1 << 3)))
    evaluateInput.replaceSubrange(
      128..<160,
      with: try machine.physicalMemory.read(
        at: 0x6060,
        byteCount: 32
      ))
    evaluateInput.replaceSubrange(148..<152, with: littleEndian(UInt32(4_096)))
    try machine.physicalMemory.write(at: 0xC000, bytes: evaluateInput)
    try machine.physicalMemory.write(
      at: 0x3060,
      bytes: littleEndian(UInt64(0xC000)) + [UInt8](repeating: 0, count: 4)
        + littleEndian(UInt32(1 << 24 | 13 << 10 | 1))
    )
    try write32(machine, bar + 0x2000, 0)
    #expect(try read32(machine, 0x6074) == 4_096)
    #expect(try read32(machine, 0x6060) & 0x7 == 3)
    #expect(try read32(machine, 0x20B8) >> 24 == 1)

    try machine.physicalMemory.write(
      at: 0x3070,
      bytes: [UInt8](repeating: 0, count: 12)
        + littleEndian(UInt32(1 << 24 | 17 << 10 | 1))
    )
    try write32(machine, bar + 0x2000, 0)
    #expect(xhci.slotStates == [.init(slotID: 1, addressed: false)])
    #expect(try read32(machine, 0x600C) >> 27 == 1)
    #expect(try read32(machine, 0x6060) == 0)
    #expect(try read32(machine, 0x20C8) >> 24 == 1)
  }

  @Test func authorizedDeviceCapabilityFollowsPortResetDetachAndControllerReset() throws {
    let xhci = try DoryPCXHCIController()
    let device = DoryPCUSBRecordingDevice(speed: .high)
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      pciFunctions: [xhci]
    )
    let bar = DoryPCV1ABI.xhciBARAddress
    try xhci.writeConfiguration(offset: 4, bytes: [2, 0])
    try xhci.connect(port: 2, device: device)
    try write32(machine, bar + 0x450, 1 << 4)
    #expect(device.resetCount == 1)
    try write32(machine, bar + 0x40, 1 << 1)
    #expect(device.cancellationCount == 1)
    try xhci.disconnect(port: 2)
    #expect(device.cancellationCount == 2)
  }
}

private func read8(_ machine: DoryPCDirectKernelMachine, _ address: UInt64) throws -> UInt8 {
  try machine.physicalMemory.read(at: address, byteCount: 1)[0]
}

private func read16(_ machine: DoryPCDirectKernelMachine, _ address: UInt64) throws -> UInt16 {
  let bytes = try machine.physicalMemory.read(at: address, byteCount: 2)
  return UInt16(bytes[0]) | UInt16(bytes[1]) << 8
}

private func read32(_ machine: DoryPCDirectKernelMachine, _ address: UInt64) throws -> UInt32 {
  let bytes = try machine.physicalMemory.read(at: address, byteCount: 4)
  return bytes.enumerated().reduce(0) { $0 | UInt32($1.element) << UInt32($1.offset * 8) }
}

private func read64(_ machine: DoryPCDirectKernelMachine, _ address: UInt64) throws -> UInt64 {
  let bytes = try machine.physicalMemory.read(at: address, byteCount: 8)
  return bytes.enumerated().reduce(0) { $0 | UInt64($1.element) << UInt64($1.offset * 8) }
}

private func write32(_ machine: DoryPCDirectKernelMachine, _ address: UInt64, _ value: UInt32)
  throws
{
  try machine.physicalMemory.write(at: address, bytes: littleEndian(value))
}

private func write64(_ machine: DoryPCDirectKernelMachine, _ address: UInt64, _ value: UInt64)
  throws
{
  try machine.physicalMemory.write(at: address, bytes: littleEndian(value))
}

private func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
  (0..<MemoryLayout<T>.size).map { UInt8(truncatingIfNeeded: value >> T($0 * 8)) }
}
