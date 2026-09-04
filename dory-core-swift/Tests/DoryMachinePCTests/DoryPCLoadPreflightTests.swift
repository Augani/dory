import Foundation
import Testing

@testable import DoryDBTX86
@testable import DoryMachinePC

@Suite struct DoryPCLoadPreflightTests {
  @Test func rejectsInvalidMachineAllocationBeforeConstructingRAM() {
    for count in [-1, 0, 1_048_577, Int.max] {
      #expect(throws: DoryPCMachineError.invalidMemorySize(count)) {
        _ = try DoryPCDirectKernelMachine(memoryBytes: count)
      }
    }
  }

  @Test func overlapWithInitrdRejectsWithoutWritesAndAllowsCorrectedRetry() throws {
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 << 20,
      bootLayout: .init(initrd: 0x10_0000)
    )
    let image = kernel()
    #expect(throws: DoryPCMachineError.overlappingBootArtifacts) {
      try machine.load(kernel: image, initrd: [1, 2, 3], commandLine: "x")
    }
    #expect(machine.state == nil)
    #expect(try machine.memory.read(at: 0x10_0000, byteCount: 16) == .init(repeating: 0, count: 16))
    #expect(try machine.memory.read(at: DoryPCV1ABI.pvhStartInfo, byteCount: 56) == .init(repeating: 0, count: 56))
    try machine.load(kernel: image, commandLine: "x")
    #expect(machine.state?.rip == 0x10_0000)
  }

  @Test func kernelCannotOverwriteReservedHandoffOrLegacyMemory() throws {
    for address: UInt64 in [0, 0x7800, DoryPCV1ABI.pvhStartInfo, DoryPCV1ABI.acpiBase] {
      let machine = try DoryPCDirectKernelMachine(memoryBytes: 2 << 20)
      do {
        try machine.load(kernel: kernel(entry: address), commandLine: "x")
        Issue.record("reserved kernel range was accepted")
      } catch {}
      #expect(machine.state == nil)
      #expect(try machine.memory.read(at: address, byteCount: 16) == .init(repeating: 0, count: 16))
      try machine.load(kernel: kernel(), commandLine: "x")
    }
  }

  @Test func metadataCollisionRejectsBeforeWritingKernelOrTables() throws {
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 << 20,
      smbiosLayout: .init(entryPoint: DoryPCV1ABI.pvhStartInfo, structureTable: 0xF1000)
    )
    #expect(throws: DoryPCMachineError.overlappingBootArtifacts) {
      try machine.load(kernel: kernel(), commandLine: "x")
    }
    #expect(machine.state == nil)
    #expect(try machine.memory.read(at: 0x10_0000, byteCount: 16) == .init(repeating: 0, count: 16))
  }

  @Test func segmentAboveFourGiBUsesThePhysicalAddressRouter() throws {
    let high = DoryPCV1ABI.above4GRAMStart + 0x1000
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: Int(DoryPCV1ABI.mmioHoleStart) + (2 << 20)
    )
    try machine.load(kernel: kernel(extraAddress: high), commandLine: "x")
    #expect(try machine.physicalMemory.read(at: high, byteCount: 4) == [0xD0, 0x12, 0x34, 0x56])
    #expect(try machine.physicalMemory.read(at: high + 4, byteCount: 12) == .init(repeating: 0, count: 12))
    #expect(try machine.memory.read(at: DoryPCV1ABI.mmioHoleStart + 0x1000, byteCount: 4) == [0xD0, 0x12, 0x34, 0x56])
  }

  private func kernel(entry: UInt64 = 0x10_0000, extraAddress: UInt64? = nil) -> Data {
    var bytes = Data(repeating: 0, count: 0x304)
    bytes.replaceSubrange(0..<7, with: [0x7F, 0x45, 0x4C, 0x46, 2, 1, 1])
    write(UInt16(2), at: 16, to: &bytes)
    write(UInt16(0x3E), at: 18, to: &bytes)
    write(UInt32(1), at: 20, to: &bytes)
    write(entry, at: 24, to: &bytes)
    write(UInt64(0x40), at: 32, to: &bytes)
    write(UInt16(64), at: 52, to: &bytes)
    write(UInt16(56), at: 54, to: &bytes)
    write(UInt16(extraAddress == nil ? 2 : 3), at: 56, to: &bytes)
    header(at: 0x40, type: 1, file: 0x200, address: entry, size: 1, memory: 16, to: &bytes)
    header(at: 0x78, type: 4, file: 0x180, address: 0, size: 20, memory: 20, to: &bytes)
    write(UInt32(4), at: 0x180, to: &bytes)
    write(UInt32(4), at: 0x184, to: &bytes)
    write(UInt32(0x12), at: 0x188, to: &bytes)
    bytes.replaceSubrange(0x18C..<0x190, with: [0x58, 0x65, 0x6E, 0])
    write(UInt32(truncatingIfNeeded: entry), at: 0x190, to: &bytes)
    bytes[0x200] = 0xF4
    if let extraAddress {
      header(at: 0xB0, type: 1, file: 0x300, address: extraAddress, size: 4, memory: 16, to: &bytes)
      bytes.replaceSubrange(0x300..<0x304, with: [0xD0, 0x12, 0x34, 0x56])
    }
    return bytes
  }

  private func header(
    at offset: Int, type: UInt32, file: UInt64, address: UInt64,
    size: UInt64, memory: UInt64, to bytes: inout Data
  ) {
    write(type, at: offset, to: &bytes)
    write(UInt32(5), at: offset + 4, to: &bytes)
    write(file, at: offset + 8, to: &bytes)
    write(address, at: offset + 16, to: &bytes)
    write(address, at: offset + 24, to: &bytes)
    write(size, at: offset + 32, to: &bytes)
    write(memory, at: offset + 40, to: &bytes)
  }

  private func write<T: FixedWidthInteger>(_ value: T, at offset: Int, to bytes: inout Data) {
    for index in 0..<MemoryLayout<T>.size {
      bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8))
    }
  }
}
