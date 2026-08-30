import DoryMachinePC
import DoryVirtio
import Testing

@Suite struct DoryPCVirtioBlockPCITests {
  @Test func notifiedQueueExecutesBlockWritePublishesUsedAndRaisesMSI() throws {
    let storage = DoryVirtioInMemoryBlockStorage(byteCount: 4096)
    let block = try DoryPCVirtioBlockPCIDevice(
      address: .init(bus: 0, device: 2, function: 0),
      initialBARAddress: 0xD000_0000,
      storage: storage,
      identifier: "dory-root"
    )
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      pciFunctions: [block]
    )
    try block.writeConfiguration(offset: 4, bytes: [2, 0])
    try block.writeConfiguration(offset: 0x54, bytes: littleEndian(UInt32(0xFEE0_0000)))
    try block.writeConfiguration(offset: 0x5C, bytes: [0x74, 0])
    try block.writeConfiguration(offset: 0x52, bytes: [1, 0])

    let bar: UInt64 = 0xD000_0000
    try write32(machine, bar + 0x08, 1)
    try write32(machine, bar + 0x0C, 1)
    try write8(machine, bar + 0x14, 0x0F)
    try write16(machine, bar + 0x16, 0)
    try write16(machine, bar + 0x18, 8)
    try write64(machine, bar + 0x20, 0x1000)
    try write64(machine, bar + 0x28, 0x2000)
    try write64(machine, bar + 0x30, 0x3000)
    try write16(machine, bar + 0x1C, 1)

    try writeDescriptor(machine, at: 0x1000, address: 0x4000, length: 16, flags: 1, next: 1)
    try writeDescriptor(machine, at: 0x1010, address: 0x5000, length: 512, flags: 1, next: 2)
    try writeDescriptor(machine, at: 0x1020, address: 0x6000, length: 1, flags: 2, next: 0)
    try machine.physicalMemory.write(at: 0x4000, bytes: blockHeader(type: 1, sector: 2))
    let sector = [UInt8](repeating: 0x5A, count: 512)
    try machine.physicalMemory.write(at: 0x5000, bytes: sector)
    try machine.physicalMemory.write(at: 0x2000, bytes: [0, 0, 1, 0, 0, 0])

    try write16(machine, bar + 0x100, 0)

    #expect(try storage.read(offset: 1024, byteCount: 512) == sector)
    #expect(try machine.physicalMemory.read(at: 0x6000, byteCount: 1) == [0])
    #expect(read16(try machine.physicalMemory.read(at: 0x3002, byteCount: 2)) == 1)
    #expect(read32(try machine.physicalMemory.read(at: 0x3004, byteCount: 4)) == 0)
    #expect(read32(try machine.physicalMemory.read(at: 0x3008, byteCount: 4)) == 1)
    #expect(machine.localAPIC.snapshot().interruptRequest.contains(0x74))
  }

  @Test func descriptorDMAIntoMMIOFailsClosedAndRequestsDeviceReset() throws {
    let storage = DoryVirtioInMemoryBlockStorage(byteCount: 4096)
    let block = try DoryPCVirtioBlockPCIDevice(
      address: .init(bus: 0, device: 2, function: 0),
      initialBARAddress: 0xD000_0000,
      storage: storage,
      identifier: "dory-root"
    )
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      pciFunctions: [block]
    )
    try block.writeConfiguration(offset: 4, bytes: [2, 0])
    let bar: UInt64 = 0xD000_0000
    try write32(machine, bar + 0x08, 1)
    try write32(machine, bar + 0x0C, 1)
    try write8(machine, bar + 0x14, 0x0F)
    try write16(machine, bar + 0x18, 8)
    try write64(machine, bar + 0x20, 0x1000)
    try write64(machine, bar + 0x28, 0x2000)
    try write64(machine, bar + 0x30, 0x3000)
    try write16(machine, bar + 0x1C, 1)
    try writeDescriptor(
      machine,
      at: 0x1000,
      address: 0xFEE0_0020,
      length: 16,
      flags: 0,
      next: 0
    )
    try machine.physicalMemory.write(at: 0x2000, bytes: [0, 0, 1, 0, 0, 0])

    try write16(machine, bar + 0x100, 0)

    #expect(block.transport.deviceState.snapshot().status.contains(.deviceNeedsReset))
    #expect(try storage.read(offset: 0, byteCount: 4) == [0, 0, 0, 0])
  }

  private func writeDescriptor(
    _ machine: DoryPCDirectKernelMachine,
    at tableAddress: UInt64,
    address: UInt64,
    length: UInt32,
    flags: UInt16,
    next: UInt16
  ) throws {
    try machine.physicalMemory.write(
      at: tableAddress,
      bytes: littleEndian(address) + littleEndian(length) + littleEndian(flags) + littleEndian(next)
    )
  }

  private func blockHeader(type: UInt32, sector: UInt64) -> [UInt8] {
    littleEndian(type) + [UInt8](repeating: 0, count: 4) + littleEndian(sector)
  }

  private func write8(
    _ machine: DoryPCDirectKernelMachine,
    _ address: UInt64,
    _ value: UInt8
  ) throws {
    try machine.physicalMemory.write(at: address, bytes: [value])
  }

  private func write16(
    _ machine: DoryPCDirectKernelMachine,
    _ address: UInt64,
    _ value: UInt16
  ) throws {
    try machine.physicalMemory.write(at: address, bytes: littleEndian(value))
  }

  private func write32(
    _ machine: DoryPCDirectKernelMachine,
    _ address: UInt64,
    _ value: UInt32
  ) throws {
    try machine.physicalMemory.write(at: address, bytes: littleEndian(value))
  }

  private func write64(
    _ machine: DoryPCDirectKernelMachine,
    _ address: UInt64,
    _ value: UInt64
  ) throws {
    try machine.physicalMemory.write(at: address, bytes: littleEndian(value))
  }
}

private func read16(_ bytes: [UInt8]) -> UInt16 {
  UInt16(bytes[0]) | UInt16(bytes[1]) << 8
}

private func read32(_ bytes: [UInt8]) -> UInt32 {
  bytes.enumerated().reduce(0) { $0 | UInt32($1.element) << UInt32($1.offset * 8) }
}

private func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
  (0..<MemoryLayout<T>.size).map { UInt8(truncatingIfNeeded: value >> T($0 * 8)) }
}
