import DoryMachinePC
import DoryVirtio
import Foundation
import Testing

@Suite struct DoryPCVirtioInputPCITests {
  @Test func selectsConfigurationAndHostEventWakesPostedQueue() throws {
    let input = try DoryPCVirtioInputPCIDevice(
      address: DoryPCV1ABI.keyboardPCIAddress,
      initialBARAddress: DoryPCV1ABI.keyboardBARAddress,
      descriptor: .keyboard()
    )
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      pciFunctions: [input]
    )
    #expect(try input.readConfiguration(offset: 0, byteCount: 4) == [0xF4, 0x1A, 0x52, 0x10])
    #expect(try input.readConfiguration(offset: 9, byteCount: 3) == [0, 0x80, 9])
    try input.writeConfiguration(offset: 4, bytes: [2, 0])
    try input.writeConfiguration(offset: 0x54, bytes: littleEndian(UInt32(0xFEE0_0000)))
    try input.writeConfiguration(offset: 0x5C, bytes: [0x79, 0])
    try input.writeConfiguration(offset: 0x52, bytes: [1, 0])

    let bar = DoryPCV1ABI.keyboardBARAddress
    try write8(machine, bar + 0x300, 1)
    let size = try machine.physicalMemory.read(at: bar + 0x302, byteCount: 1)[0]
    let name = try machine.physicalMemory.read(at: bar + 0x308, byteCount: Int(size))
    #expect(String(decoding: name, as: UTF8.self) == "Dory Virtual Keyboard")

    try write32(machine, bar + 0x08, 1)
    try write32(machine, bar + 0x0C, 1)
    try write8(machine, bar + 0x14, 0x0F)
    try write16(machine, bar + 0x16, 0)
    try write16(machine, bar + 0x18, 8)
    try write64(machine, bar + 0x20, 0x1000)
    try write64(machine, bar + 0x28, 0x2000)
    try write64(machine, bar + 0x30, 0x3000)
    try write16(machine, bar + 0x1C, 1)
    try writeDescriptor(machine, at: 0x1000, address: 0x4000, length: 8, flags: 2, next: 0)
    try machine.physicalMemory.write(at: 0x2000, bytes: [0, 0, 1, 0, 0, 0])

    try write16(machine, bar + 0x100, 0)
    #expect(read16(try machine.physicalMemory.read(at: 0x3002, byteCount: 2)) == 0)
    #expect(input.enqueueSynchronized([.init(type: 1, code: 30, value: 1)]))

    #expect(
      try machine.physicalMemory.read(at: 0x4000, byteCount: 8)
        == littleEndian(UInt16(1)) + littleEndian(UInt16(30)) + littleEndian(UInt32(1))
    )
    #expect(read16(try machine.physicalMemory.read(at: 0x3002, byteCount: 2)) == 1)
    #expect(read32(try machine.physicalMemory.read(at: 0x3008, byteCount: 4)) == 8)
    #expect(machine.localAPIC.snapshot().interruptRequest.contains(0x79))
    #expect(input.inputDevice.pendingEventCount == 1)
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
  {
    try machine.physicalMemory.write(at: address, bytes: [value])
  }

  private func write16(_ machine: DoryPCDirectKernelMachine, _ address: UInt64, _ value: UInt16)
    throws
  {
    try machine.physicalMemory.write(at: address, bytes: littleEndian(value))
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
