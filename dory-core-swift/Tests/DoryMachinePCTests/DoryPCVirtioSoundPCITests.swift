import DoryMachinePC
import DoryVirtio
import Foundation
import Testing

@Suite struct DoryPCVirtioSoundPCITests {
  @Test func controlQueuePublishesPCMStreamsAndRaisesMSI() throws {
    let sound = try DoryPCVirtioSoundPCIDevice(
      address: DoryPCV1ABI.soundPCIAddress,
      initialBARAddress: DoryPCV1ABI.soundBARAddress,
      backend: DoryVirtioInMemorySoundBackend()
    )
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      pciFunctions: [sound]
    )
    #expect(try sound.readConfiguration(offset: 0, byteCount: 4) == [0xF4, 0x1A, 0x59, 0x10])
    #expect(try sound.readConfiguration(offset: 9, byteCount: 3) == [0, 1, 4])
    try sound.writeConfiguration(offset: 4, bytes: [2, 0])
    try sound.writeConfiguration(offset: 0x54, bytes: littleEndian(UInt32(0xFEE0_0000)))
    try sound.writeConfiguration(offset: 0x5C, bytes: [0x7A, 0])
    try sound.writeConfiguration(offset: 0x52, bytes: [1, 0])

    let bar = DoryPCV1ABI.soundBARAddress
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
    try writeDescriptor(machine, at: 0x1010, address: 0x5000, length: 68, flags: 2, next: 0)
    try machine.physicalMemory.write(
      at: 0x4000,
      bytes: littleEndian(UInt32(0x0100)) + littleEndian(UInt32(0))
        + littleEndian(UInt32(2)) + littleEndian(UInt32(32))
    )
    try machine.physicalMemory.write(at: 0x2000, bytes: [0, 0, 1, 0, 0, 0])

    try write16(machine, bar + 0x100, 0)

    let response = try machine.physicalMemory.read(at: 0x5000, byteCount: 68)
    #expect(read32(response) == 0x8000)
    #expect(response[28] == 0 && response[60] == 1)
    #expect(read16(try machine.physicalMemory.read(at: 0x3002, byteCount: 2)) == 1)
    #expect(read32(try machine.physicalMemory.read(at: 0x3008, byteCount: 4)) == 68)
    #expect(machine.localAPIC.snapshot().interruptRequest.contains(0x7A))
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
  private func write8(_ machine: DoryPCDirectKernelMachine, _ address: UInt64, _ value: UInt8)
    throws
  { try machine.physicalMemory.write(at: address, bytes: [value]) }
  private func write16(_ machine: DoryPCDirectKernelMachine, _ address: UInt64, _ value: UInt16)
    throws
  { try machine.physicalMemory.write(at: address, bytes: littleEndian(value)) }
  private func write32(_ machine: DoryPCDirectKernelMachine, _ address: UInt64, _ value: UInt32)
    throws
  { try machine.physicalMemory.write(at: address, bytes: littleEndian(value)) }
  private func write64(_ machine: DoryPCDirectKernelMachine, _ address: UInt64, _ value: UInt64)
    throws
  { try machine.physicalMemory.write(at: address, bytes: littleEndian(value)) }
}

private func read16(_ bytes: [UInt8]) -> UInt16 {
  UInt16(bytes[0]) | UInt16(bytes[1]) << 8
}
private func read32(_ bytes: [UInt8]) -> UInt32 {
  (0..<4).reduce(0) { $0 | UInt32(bytes[$1]) << UInt32($1 * 8) }
}
private func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
  (0..<MemoryLayout<T>.size).map { UInt8(truncatingIfNeeded: value >> T($0 * 8)) }
}
