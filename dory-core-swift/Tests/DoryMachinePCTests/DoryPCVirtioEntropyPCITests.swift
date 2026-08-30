import DoryMachinePC
import DoryVirtio
import Foundation
import Testing

@Suite struct DoryPCVirtioEntropyPCITests {
  @Test func pciNotificationFillsGuestBuffersAndRaisesMSI() throws {
    let source = RepeatingEntropySource(byte: 0xA7)
    let entropy = try DoryPCVirtioEntropyPCIDevice(
      address: .init(bus: 0, device: 3, function: 0),
      initialBARAddress: 0xD000_1000,
      source: source
    )
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      pciFunctions: [entropy]
    )
    try entropy.writeConfiguration(offset: 4, bytes: [2, 0])
    try entropy.writeConfiguration(offset: 0x54, bytes: littleEndian(UInt32(0xFEE0_0000)))
    try entropy.writeConfiguration(offset: 0x5C, bytes: [0x75, 0])
    try entropy.writeConfiguration(offset: 0x52, bytes: [1, 0])

    let bar: UInt64 = 0xD000_1000
    try write32(machine, bar + 0x08, 1)
    try write32(machine, bar + 0x0C, 1)
    try write8(machine, bar + 0x14, 0x0F)
    try write16(machine, bar + 0x18, 8)
    try write64(machine, bar + 0x20, 0x1000)
    try write64(machine, bar + 0x28, 0x2000)
    try write64(machine, bar + 0x30, 0x3000)
    try write16(machine, bar + 0x1C, 1)

    try machine.physicalMemory.write(
      at: 0x1000,
      bytes: littleEndian(UInt64(0x4000)) + littleEndian(UInt32(32))
        + littleEndian(UInt16(2)) + littleEndian(UInt16(0))
    )
    try machine.physicalMemory.write(at: 0x2000, bytes: [0, 0, 1, 0, 0, 0])

    try write16(machine, bar + 0x100, 0)

    #expect(
      try machine.physicalMemory.read(at: 0x4000, byteCount: 32)
        == [UInt8](repeating: 0xA7, count: 32))
    #expect(read16(try machine.physicalMemory.read(at: 0x3002, byteCount: 2)) == 1)
    #expect(read32(try machine.physicalMemory.read(at: 0x3008, byteCount: 4)) == 32)
    #expect(machine.localAPIC.snapshot().interruptRequest.contains(0x75))
    #expect(read16(try entropy.readConfiguration(offset: 2, byteCount: 2)) == 0x1044)
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

private struct RepeatingEntropySource: DoryVirtioEntropySource, Sendable {
  let byte: UInt8

  func randomBytes(byteCount: Int) throws -> [UInt8] {
    [UInt8](repeating: byte, count: byteCount)
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
