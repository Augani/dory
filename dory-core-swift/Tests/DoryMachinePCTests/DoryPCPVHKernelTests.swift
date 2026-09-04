import DoryDBTX86
import Foundation
import Testing

@testable import DoryMachinePC

@Suite struct DoryPCPVHKernelTests {
  @Test func parsesLoadsAndZerosPVHKernelSegments() throws {
    let image = try DoryPCPVHKernelImage(data: makeELF())
    let memory = DoryX86ByteArrayMemory(byteCount: 0x20_0000)
    try memory.write(at: 0x10_0000, bytes: [UInt8](repeating: 0xFF, count: 8))

    try image.load(into: memory)

    #expect(image.physicalEntryPoint == 0x10_0000)
    #expect(image.physicalRanges == [0x10_0000..<0x10_0008])
    #expect(
      image.segments == [
        .init(physicalAddress: 0x10_0000, fileOffset: 0x200, fileSize: 4, memorySize: 8)
      ])
    #expect(try memory.read(at: 0x10_0000, byteCount: 8) == [1, 2, 3, 4, 0, 0, 0, 0])
  }

  @Test func preservesELF64NumericNotesAndLinuxInitTextInRWLoadSegment() throws {
    var data = makeELF(entry: 0x10_0003, descriptorSize: 8)
    write(UInt32(6), to: &data, at: 0x44)  // Linux puts .init.text in the data PHDR.
    write(UInt64(0xFFFF_FFFF_8100_0000), to: &data, at: 0x50)
    write(UInt64(0x200), to: &data, at: 0x70)
    let image = try DoryPCPVHKernelImage(data: data)
    #expect(image.physicalEntryPoint == 0x10_0003)
    #expect(image.segments[0].physicalAddress == 0x10_0000)
  }

  @Test func rebasesSlicedDataOffsets() throws {
    var wrapped = Data([0xAA, 0xBB])
    wrapped.append(makeELF())
    let image = try DoryPCPVHKernelImage(data: wrapped.dropFirst(2))
    #expect(image.physicalEntryPoint == 0x10_0000)
  }

  @Test func rejectsUnsupportedELFHeaderForms() {
    for offset in [4, 5, 6, 16, 18, 20, 52] {
      var data = makeELF()
      data[offset] = 0
      #expect(throws: DoryPCPVHKernelError.unsupportedELF) {
        _ = try DoryPCPVHKernelImage(data: data)
      }
    }
    var dynamic = makeELF()
    write(UInt16(3), to: &dynamic, at: 16)
    #expect(throws: DoryPCPVHKernelError.unsupportedELF) {
      _ = try DoryPCPVHKernelImage(data: dynamic)
    }
    #expect(throws: DoryPCPVHKernelError.truncatedELF) {
      _ = try DoryPCPVHKernelImage(data: Data(repeating: 0, count: 63))
    }
  }

  @Test func rejectsMalformedProgramHeaderTableBeforeReadingIt() {
    for headerOffset: UInt64 in [0, 63, 0x3F0, .max] {
      var data = makeELF()
      write(headerOffset, to: &data, at: 32)
      #expect(throws: DoryPCPVHKernelError.invalidProgramHeaders) {
        _ = try DoryPCPVHKernelImage(data: data)
      }
    }
    for count: UInt16 in [0, 0xFFFF] {
      var data = makeELF()
      write(count, to: &data, at: 56)
      #expect(throws: DoryPCPVHKernelError.invalidProgramHeaders) {
        _ = try DoryPCPVHKernelImage(data: data)
      }
    }
    for size: UInt16 in [0, 55, 57] {
      var data = makeELF()
      write(size, to: &data, at: 54)
      #expect(throws: DoryPCPVHKernelError.invalidProgramHeaders) {
        _ = try DoryPCPVHKernelImage(data: data)
      }
    }
  }

  @Test func rejectsMissingEntryAndOutOfSegmentEntry() {
    #expect(throws: DoryPCPVHKernelError.missingPhysicalEntry) {
      _ = try DoryPCPVHKernelImage(data: makeELF(entry: nil))
    }
    for entry: UInt64 in [0, 0xF_FFFF, 0x10_0004, 0x10_0008, 0x10_0020, 0x1_0010_0000] {
      #expect(throws: DoryPCPVHKernelError.invalidPhysicalEntry) {
        _ = try DoryPCPVHKernelImage(data: makeELF(entry: entry, descriptorSize: 8))
      }
    }
  }

  @Test func rejectsMalformedNotesEvenAfterTheEntryWasFound() {
    for noteSize: UInt64 in [1, 19, 21, .max] {
      var data = makeELF()
      write(noteSize, to: &data, at: 0x98)
      #expect(throws: DoryPCPVHKernelError.invalidNotes) {
        _ = try DoryPCPVHKernelImage(data: data)
      }
    }
    for descriptorSize: UInt32 in [0, 3, 5, 12, .max] {
      var data = makeELF()
      write(descriptorSize, to: &data, at: 0x184)
      #expect(throws: DoryPCPVHKernelError.invalidNotes) {
        _ = try DoryPCPVHKernelImage(data: data)
      }
    }
    var badName = makeELF()
    badName[0x18F] = 0x41
    #expect(throws: DoryPCPVHKernelError.invalidNotes) {
      _ = try DoryPCPVHKernelImage(data: badName)
    }
    var hugeName = makeELF()
    write(UInt32.max, to: &hugeName, at: 0x180)
    #expect(throws: DoryPCPVHKernelError.invalidNotes) {
      _ = try DoryPCPVHKernelImage(data: hugeName)
    }
    var badOffset = makeELF()
    write(UInt64.max, to: &badOffset, at: 0x80)
    #expect(throws: DoryPCPVHKernelError.invalidNotes) {
      _ = try DoryPCPVHKernelImage(data: badOffset)
    }
  }

  @Test func rejectsDuplicateEntryNotesAcrossAndWithinNoteSegments() {
    var sameSegment = makeELF()
    sameSegment.replaceSubrange(0x194..<0x1A8, with: Array(sameSegment[0x180..<0x194]))
    write(UInt64(40), to: &sameSegment, at: 0x98)
    #expect(throws: DoryPCPVHKernelError.duplicatePhysicalEntry) {
      _ = try DoryPCPVHKernelImage(data: sameSegment)
    }
    var otherSegment = makeELF()
    write(UInt16(3), to: &otherSegment, at: 56)
    writeProgramHeader(
      to: &otherSegment, at: 0xB0, type: 4, fileOffset: 0x180,
      physicalAddress: 0, fileSize: 20, memorySize: 20
    )
    #expect(throws: DoryPCPVHKernelError.duplicatePhysicalEntry) {
      _ = try DoryPCPVHKernelImage(data: otherSegment)
    }
    // A valid first note must not conceal malformed later PT_NOTE records.
    write(UInt64(19), to: &otherSegment, at: 0xD0)
    #expect(throws: DoryPCPVHKernelError.invalidNotes) {
      _ = try DoryPCPVHKernelImage(data: otherSegment)
    }
  }

  @Test func skipsOtherVendorsWithFourBytePadding() throws {
    var data = makeELF()
    let entryNote = Array(data[0x180..<0x194])
    data.replaceSubrange(0x180..<0x1AC, with: [UInt8](repeating: 0, count: 44))
    write(UInt32(6), to: &data, at: 0x180)
    write(UInt32(1), to: &data, at: 0x184)
    write(UInt32(0x100), to: &data, at: 0x188)
    data.replaceSubrange(0x18C..<0x192, with: Array("Linux\0".utf8))
    data[0x194] = 1
    data.replaceSubrange(0x198..<0x1AC, with: entryNote)
    write(UInt64(44), to: &data, at: 0x98)
    #expect(try DoryPCPVHKernelImage(data: data).physicalEntryPoint == 0x10_0000)
  }

  @Test func rejectsOversizedOverflowingAndMisalignedLoadSegments() {
    #expect(throws: DoryPCPVHKernelError.invalidLoadSegment) {
      _ = try DoryPCPVHKernelImage(data: makeELF(fileSize: 9, memorySize: 8))
    }
    for field in [0x48, 0x50, 0x58, 0x68] {
      var data = makeELF()
      write(UInt64.max, to: &data, at: field)
      #expect(throws: DoryPCPVHKernelError.invalidLoadSegment) {
        _ = try DoryPCPVHKernelImage(data: data)
      }
    }
    for alignment: UInt64 in [3, 0x1000] {
      var data = makeELF()
      write(alignment, to: &data, at: 0x70)
      #expect(throws: DoryPCPVHKernelError.invalidLoadSegment) {
        _ = try DoryPCPVHKernelImage(data: data)
      }
    }
  }

  @Test func supportsPureBSSAndIgnoresEmptySegments() throws {
    var data = makeELF()
    write(UInt16(4), to: &data, at: 56)
    writeProgramHeader(
      to: &data, at: 0xB0, type: 1, fileOffset: .max,
      physicalAddress: 0x11_0000, fileSize: 0, memorySize: 0x10002
    )
    writeProgramHeader(
      to: &data, at: 0xE8, type: 1, fileOffset: 0,
      physicalAddress: 0x10_0001, fileSize: 0, memorySize: 0
    )
    let image = try DoryPCPVHKernelImage(data: data)
    let memory = DoryX86ByteArrayMemory(byteCount: 0x20_0000)
    try memory.write(at: 0x11_0000, bytes: [UInt8](repeating: 0xAA, count: 0x10002))
    try image.load(into: memory)
    #expect(image.segments.count == 2)
    #expect(try memory.read(at: 0x11_0000, byteCount: 0x10002).allSatisfy { $0 == 0 })
  }

  @Test func rejectsBSSOverlapWithLaterSegment() {
    var data = makeELF()
    write(UInt16(3), to: &data, at: 56)
    writeProgramHeader(
      to: &data, at: 0xB0, type: 1, fileOffset: 0x200,
      physicalAddress: 0x10_0006, fileSize: 4, memorySize: 4
    )
    #expect(throws: DoryPCPVHKernelError.overlappingLoadSegments) {
      _ = try DoryPCPVHKernelImage(data: data)
    }
  }

  @Test func preflightsAllSegmentsAndNeverMasksHighPhysicalAddresses() throws {
    var data = makeELF()
    write(UInt16(3), to: &data, at: 56)
    let highAddress: UInt64 = 0xFFFF_FFFF_8110_0000
    writeProgramHeader(
      to: &data, at: 0xB0, type: 1, fileOffset: 0x200,
      physicalAddress: highAddress, fileSize: 4, memorySize: 4
    )
    let image = try DoryPCPVHKernelImage(data: data)
    let memory = DoryX86ByteArrayMemory(byteCount: 0x20_0000)
    try memory.write(at: 0x10_0000, bytes: [9, 9, 9, 9])
    #expect(image.segments[1].physicalAddress == highAddress)
    #expect(throws: DoryPCPVHKernelError.self) { try image.load(into: memory) }
    #expect(try memory.read(at: 0x10_0000, byteCount: 4) == [9, 9, 9, 9])
    #expect(try memory.read(at: 0x11_0000, byteCount: 4) == [0, 0, 0, 0])
  }

  @Test func ignoresAllocatedSectionsAndDoesNotLoadStandaloneNotes() throws {
    var data = makeELF()
    write(UInt64(0x3000), to: &data, at: 0x90)  // PT_NOTE p_paddr, not a PT_LOAD.
    write(UInt64(0x280), to: &data, at: 40)
    write(UInt16(64), to: &data, at: 58)
    write(UInt16(1), to: &data, at: 60)
    write(UInt32(1), to: &data, at: 0x284)
    write(UInt64(2), to: &data, at: 0x288)  // SHF_ALLOC outside any load segment.
    write(UInt64(0x2000), to: &data, at: 0x290)
    write(UInt64(0x240), to: &data, at: 0x298)
    write(UInt64(4), to: &data, at: 0x2A0)
    data.replaceSubrange(0x240..<0x244, with: [5, 6, 7, 8])
    let image = try DoryPCPVHKernelImage(data: data)
    let memory = DoryX86ByteArrayMemory(byteCount: 0x20_0000)
    try memory.write(at: 0x2000, bytes: [9, 9, 9, 9])
    try image.load(into: memory)
    #expect(try memory.read(at: 0x2000, byteCount: 4) == [9, 9, 9, 9])
    #expect(try memory.read(at: 0x3000, byteCount: 4) == [0, 0, 0, 0])
  }

  private func makeELF(
    entry: UInt64? = 0x10_0000,
    fileSize: UInt64 = 4,
    memorySize: UInt64 = 8,
    descriptorSize: UInt64 = 4
  ) -> Data {
    var data = Data(repeating: 0, count: 0x400)
    data.replaceSubrange(0..<4, with: [0x7F, 0x45, 0x4C, 0x46])
    data[4] = 2
    data[5] = 1
    data[6] = 1
    write(UInt16(2), to: &data, at: 16)
    write(UInt16(0x3E), to: &data, at: 18)
    write(UInt32(1), to: &data, at: 20)
    write(UInt64(0x40), to: &data, at: 32)
    write(UInt16(64), to: &data, at: 52)
    write(UInt16(56), to: &data, at: 54)
    write(UInt16(2), to: &data, at: 56)
    writeProgramHeader(
      to: &data, at: 0x40, type: 1, fileOffset: 0x200,
      physicalAddress: 0x10_0000, fileSize: fileSize, memorySize: memorySize
    )
    let noteSize = entry == nil ? 0 : 16 + descriptorSize
    writeProgramHeader(
      to: &data, at: 0x78, type: 4, fileOffset: 0x180,
      physicalAddress: 0, fileSize: noteSize, memorySize: noteSize
    )
    if let entry {
      write(UInt32(4), to: &data, at: 0x180)
      write(UInt32(descriptorSize), to: &data, at: 0x184)
      write(UInt32(0x12), to: &data, at: 0x188)
      data.replaceSubrange(0x18C..<0x190, with: [0x58, 0x65, 0x6E, 0])
      write(entry, to: &data, at: 0x190)
    }
    data.replaceSubrange(0x200..<0x204, with: [1, 2, 3, 4])
    return data
  }

  private func writeProgramHeader(
    to data: inout Data, at offset: Int, type: UInt32,
    fileOffset: UInt64, physicalAddress: UInt64, fileSize: UInt64, memorySize: UInt64
  ) {
    write(type, to: &data, at: offset)
    write(UInt32(type == 1 ? 5 : 0), to: &data, at: offset + 4)
    write(fileOffset, to: &data, at: offset + 8)
    write(physicalAddress, to: &data, at: offset + 16)
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
