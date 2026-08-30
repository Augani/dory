import DoryMachinePC
import DoryVirtio
import Foundation
import Testing

@Suite struct DoryPCVirtioNetworkPCITests {
  @Test func hostFrameWakesPostedReceiveQueueAndRaisesMSI() throws {
    let backend = DoryVirtioInMemoryNetworkBackend()
    let network = try DoryPCVirtioNetworkPCIDevice(
      address: .init(bus: 0, device: 4, function: 0),
      initialBARAddress: 0xD000_2000,
      backend: backend,
      macAddress: [0x02, 0xD0, 0x52, 0, 0, 1]
    )
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      pciFunctions: [network]
    )
    try network.writeConfiguration(offset: 4, bytes: [2, 0])
    try network.writeConfiguration(offset: 0x54, bytes: littleEndian(UInt32(0xFEE0_0000)))
    try network.writeConfiguration(offset: 0x5C, bytes: [0x76, 0])
    try network.writeConfiguration(offset: 0x52, bytes: [1, 0])

    let bar: UInt64 = 0xD000_2000
    try write32(machine, bar + 0x08, 1)
    try write32(machine, bar + 0x0C, 1)
    try write8(machine, bar + 0x14, 0x0F)
    try write16(machine, bar + 0x16, 0)
    try write16(machine, bar + 0x18, 8)
    try write64(machine, bar + 0x20, 0x1000)
    try write64(machine, bar + 0x28, 0x2000)
    try write64(machine, bar + 0x30, 0x3000)
    try write16(machine, bar + 0x1C, 1)

    try machine.physicalMemory.write(
      at: 0x1000,
      bytes: littleEndian(UInt64(0x4000)) + littleEndian(UInt32(2048))
        + littleEndian(UInt16(2)) + littleEndian(UInt16(0))
    )
    try machine.physicalMemory.write(at: 0x2000, bytes: [0, 0, 1, 0, 0, 0])

    try write16(machine, bar + 0x100, 0)
    #expect(read16(try machine.physicalMemory.read(at: 0x3002, byteCount: 2)) == 0)

    let frame = ethernetFrame(count: 64)
    backend.injectReceivedFrame(frame)

    #expect(
      try machine.physicalMemory.read(at: 0x4000, byteCount: 10) == [UInt8](repeating: 0, count: 10)
    )
    #expect(try machine.physicalMemory.read(at: 0x400A, byteCount: frame.count) == frame)
    #expect(read16(try machine.physicalMemory.read(at: 0x3002, byteCount: 2)) == 1)
    #expect(read32(try machine.physicalMemory.read(at: 0x3008, byteCount: 4)) == 74)
    #expect(machine.localAPIC.snapshot().interruptRequest.contains(0x76))
    #expect(read16(try network.readConfiguration(offset: 2, byteCount: 2)) == 0x1041)

    let generation = try machine.physicalMemory.read(at: bar + 0x15, byteCount: 1)[0]
    #expect(network.setLinkUp(false))
    #expect(try machine.physicalMemory.read(at: bar + 0x306, byteCount: 2) == [0, 0])
    #expect(try machine.physicalMemory.read(at: bar + 0x15, byteCount: 1)[0] == generation &+ 1)
    #expect(try machine.physicalMemory.read(at: bar + 0x200, byteCount: 1)[0] & 2 == 2)
  }

  private func ethernetFrame(count: Int) -> [UInt8] {
    [
      0x02, 0xD0, 0x52, 0, 0, 1,
      0x02, 0xD0, 0x52, 0, 0, 2,
      0x08, 0x00,
    ] + [UInt8](repeating: 0xCC, count: count - 14)
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
