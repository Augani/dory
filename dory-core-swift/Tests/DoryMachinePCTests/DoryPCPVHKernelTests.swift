import DoryDBTX86
import Foundation
import Testing

@testable import DoryMachinePC

@Suite struct DoryPCPVHKernelTests {
  @Test func parsesLoadsAndZerosPVHKernelSegments() throws {
    let image = try DoryPCPVHKernelImage(data: makeELF(entry: 0x10_0020))
    let memory = DoryX86ByteArrayMemory(byteCount: 0x20_0000)

    try image.load(into: memory)

    #expect(image.physicalEntryPoint == 0x10_0020)
    #expect(
      image.segments == [
        .init(physicalAddress: 0x10_0000, fileOffset: 0x200, fileSize: 4, memorySize: 8)
      ])
    #expect(try memory.read(at: 0x10_0000, byteCount: 8) == [1, 2, 3, 4, 0, 0, 0, 0])
  }

  @Test func rejectsMissingEntryAndOversizedSegments() {
    #expect(throws: DoryPCPVHKernelError.missingPhysicalEntry) {
      _ = try DoryPCPVHKernelImage(data: makeELF(entry: nil))
    }
    #expect(throws: DoryPCPVHKernelError.invalidLoadSegment) {
      _ = try DoryPCPVHKernelImage(data: makeELF(entry: 1, fileSize: 9, memorySize: 8))
    }
  }

  @Test func preflightsEverySegmentBeforeWritingGuestMemory() throws {
    let image = try DoryPCPVHKernelImage(data: makeELF(entry: 0x10_0020))
    let memory = DoryX86ByteArrayMemory(byteCount: 0x1000)

    #expect(throws: DoryPCPVHKernelError.self) {
      try image.load(into: memory)
    }
    #expect(try memory.read(at: 0, byteCount: 4) == [0, 0, 0, 0])
  }

  private func makeELF(
    entry: UInt32?,
    fileSize: UInt64 = 4,
    memorySize: UInt64 = 8
  ) -> Data {
    var data = Data(repeating: 0, count: 0x240)
    data.replaceSubrange(0..<4, with: [0x7F, 0x45, 0x4C, 0x46])
    data[4] = 2
    data[5] = 1
    data[6] = 1
    write(UInt16(0x3E), to: &data, at: 18)
    write(UInt64(0x40), to: &data, at: 32)
    write(UInt16(56), to: &data, at: 54)
    write(UInt16(2), to: &data, at: 56)
    writeProgramHeader(
      to: &data,
      at: 0x40,
      type: 1,
      fileOffset: 0x200,
      physicalAddress: 0x10_0000,
      fileSize: fileSize,
      memorySize: memorySize
    )
    let noteSize: UInt64 = entry == nil ? 0 : 20
    writeProgramHeader(
      to: &data,
      at: 0x78,
      type: 4,
      fileOffset: 0x180,
      physicalAddress: 0,
      fileSize: noteSize,
      memorySize: noteSize
    )
    if let entry {
      write(UInt32(4), to: &data, at: 0x180)
      write(UInt32(4), to: &data, at: 0x184)
      write(UInt32(0x12), to: &data, at: 0x188)
      data.replaceSubrange(0x18C..<0x190, with: [0x58, 0x65, 0x6E, 0])
      write(entry, to: &data, at: 0x190)
    }
    data.replaceSubrange(0x200..<0x204, with: [1, 2, 3, 4])
    return data
  }

  private func writeProgramHeader(
    to data: inout Data,
    at offset: Int,
    type: UInt32,
    fileOffset: UInt64,
    physicalAddress: UInt64,
    fileSize: UInt64,
    memorySize: UInt64
  ) {
    write(type, to: &data, at: offset)
    write(fileOffset, to: &data, at: offset + 8)
    write(physicalAddress, to: &data, at: offset + 24)
    write(fileSize, to: &data, at: offset + 32)
    write(memorySize, to: &data, at: offset + 40)
  }

  private func write<T: FixedWidthInteger>(_ value: T, to data: inout Data, at offset: Int) {
    for index in 0..<MemoryLayout<T>.size {
      data[offset + index] = UInt8(truncatingIfNeeded: value >> T(index * 8))
    }
  }
}
