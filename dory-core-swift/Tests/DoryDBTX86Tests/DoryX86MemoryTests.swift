import Foundation
import Testing

@testable import DoryDBTX86

@Suite struct DoryX86MemoryTests {
  private func backends(baseAddress: UInt64 = 0x1000, byteCount: Int = 32) throws
    -> [any DoryX86PhysicalRAM]
  {
    [
      try DoryX86ByteArrayMemory(baseAddress: baseAddress, validatingByteCount: byteCount),
      try DoryX86MmapMemory(baseAddress: baseAddress, validatingByteCount: byteCount),
    ]
  }

  @Test func validatedAllocationRejectsInvalidSizesAndGuestRangeOverflow() throws {
    for count in [Int.min, -1, 0] {
      #expect(throws: DoryX86MemoryAllocationError.invalidByteCount(count)) {
        try DoryX86ByteArrayMemory(validatingByteCount: count)
      }
      #expect(throws: DoryX86MemoryAllocationError.invalidByteCount(count)) {
        try DoryX86MmapMemory(validatingByteCount: count)
      }
    }
    let expected = DoryX86MemoryAllocationError.addressOverflow(baseAddress: .max, byteCount: 1)
    #expect(throws: expected) {
      try DoryX86ByteArrayMemory(baseAddress: .max, validatingByteCount: 1)
    }
    #expect(throws: expected) {
      try DoryX86MmapMemory(baseAddress: .max, validatingByteCount: 1)
    }
  }

  @Test func impossibleHostMappingReturnsAnAllocationError() throws {
    do {
      _ = try DoryX86MmapMemory(validatingByteCount: .max)
      Issue.record("A host mapping larger than the process address space unexpectedly succeeded")
    } catch let error as DoryX86MemoryAllocationError {
      guard case .mappingFailed(let count, let number) = error else {
        Issue.record("Unexpected allocation error: \(error)")
        return
      }
      #expect(count == Int.max)
      #expect(number != 0)
    }
  }

  @Test func instructionFetchClampsBeforeAddingUntrustedMaximumCount() throws {
    for memory in try backends() {
      try memory.write(at: 0x101E, bytes: [0x90, 0xF4])
      #expect(try memory.instructionBytes(at: 0x101E, maximumCount: .max) == [0x90, 0xF4])
      #expect(
        throws: DoryX86MemoryError.unmapped(
          address: 0x1020, byteCount: 1, access: .instructionFetch)
      ) { try memory.instructionBytes(at: 0x1020, maximumCount: 15) }
    }
  }

  @Test func byteArrayConstructionAndFetchRespectTheGuestAddressLimit() throws {
    #expect(throws: DoryX86MemoryAllocationError.addressOverflow(baseAddress: .max - 1, byteCount: 3)) {
      try DoryX86ByteArrayMemory(baseAddress: .max - 1, bytes: [0x90, 0xF4, 0xCC])
    }
    let memory = try DoryX86ByteArrayMemory(baseAddress: .max - 1, bytes: [0x90])
    #expect(try memory.instructionBytes(at: .max - 1, maximumCount: 3) == [0x90])
    #expect(try memory.instructionBytes(at: .max - 1, maximumCount: .max) == [0x90])
    #expect(memory.bulkCopyRAMSpan(at: .max - 1, maximumByteCount: .max) == 1)
    #expect(throws: DoryX86MemoryError.addressOverflow(address: .max - 1, byteCount: 2)) {
      try memory.read(at: .max - 1, byteCount: 2)
    }
    #expect(throws: DoryX86MemoryError.addressOverflow(address: .max, byteCount: 1)) {
      try memory.instructionBytes(at: .max, maximumCount: 1)
    }
    #expect(memory.snapshot() == [0x90])
  }

  @Test func negativeSizesFailConsistentlyWithoutMutation() throws {
    for memory in try backends() {
      let expected = DoryX86MemoryError.addressOverflow(address: 0x1000, byteCount: -1)
      #expect(throws: expected) { try memory.read(at: 0x1000, byteCount: -1) }
      #expect(throws: expected) { try memory.validateWrite(at: 0x1000, byteCount: -1) }
      #expect(throws: expected) { try memory.instructionBytes(at: 0x1000, maximumCount: -1) }
      #expect(throws: expected) { try memory.codeGeneration(at: 0x1000, byteCount: -1) }
      #expect(memory.bulkCopyRAMSpan(at: 0x1000, maximumByteCount: -1) == nil)
      #expect(
        try memory.copyForwardNonoverlapping(
          from: 0x1000, to: 0x1010, maximumByteCount: -1) == nil)
      #expect(try memory.fillRepeating(at: 0x1000, pattern: [1], maximumElementCount: -1) == nil)
      #expect(try memory.fillRepeating(at: 0x1000, pattern: [], maximumElementCount: 1) == nil)
      #expect(try memory.read(at: 0x1000, byteCount: 32) == Array(repeating: 0, count: 32))
    }
  }

  @Test func unalignedScalarAccessIsLittleEndianAndFailedStoresAreAtomic() throws {
    for memory in try backends() {
      try memory.writeScalar(at: 0x1001, value: 0x8877_6655_4433_2211, byteCount: 8)
      #expect(
        try memory.read(at: 0x1001, byteCount: 8) == [
          0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
        ])
      #expect(try memory.readScalar(at: 0x1001, byteCount: 8) == 0x8877_6655_4433_2211)
      let before = try memory.read(at: 0x1000, byteCount: 32)
      let generation = try memory.codeGeneration(at: 0x1000, byteCount: 32)
      #expect(throws: DoryX86MemoryError.unmapped(address: 0x101D, byteCount: 8, access: .write)) {
        try memory.writeScalar(at: 0x101D, value: .max, byteCount: 8)
      }
      #expect(try memory.read(at: 0x1000, byteCount: 32) == before)
      #expect(try memory.codeGeneration(at: 0x1000, byteCount: 32) == generation)
      for invalidWidth in [-1, 0, 3, 16, Int.max] {
        #expect(throws: DoryX86ScalarMemoryError.invalidByteCount(invalidWidth)) {
          try memory.writeScalar(at: 0x1000, value: 1, byteCount: invalidWidth)
        }
      }
    }
  }

  @Test func exclusionRangesAreAbsoluteAndEmptyRangesDoNotExcludeBytes() throws {
    for memory in try backends() {
      try memory.write(at: 0x1000, bytes: [1, 2, 3, 4])
      let copied = try memory.copyForwardNonoverlappingElements(
        from: 0x1000, to: 0x1010, elementByteCount: 2, maximumElementCount: 2,
        excludingDestinationRanges: [0..<4, 0x100F..<0x1010, 0x1012..<0x1012, 0x1014..<0x1020])
      #expect(copied == 2)
      #expect(try memory.read(at: 0x1010, byteCount: 4) == [1, 2, 3, 4])
      let before = try memory.read(at: 0x1000, byteCount: 32)
      #expect(
        try memory.copyForwardNonoverlappingElements(
          from: 0x1000, to: 0x1010, elementByteCount: 2, maximumElementCount: 2,
          excludingDestinationRanges: [0x1013..<0x1015]) == nil)
      #expect(try memory.read(at: 0x1000, byteCount: 32) == before)
    }
  }

  @Test func bulkOperationsCommitOnlyWholeElementsAndInvalidateTouchedPages() throws {
    for memory in try backends(byteCount: 0x2001) {
      let first = try memory.codeGeneration(at: 0x1000, byteCount: 1)
      let second = try memory.codeGeneration(at: 0x2000, byteCount: 1)
      let third = try memory.codeGeneration(at: 0x3000, byteCount: 1)
      #expect(
        try memory.fillRepeating(
          at: 0x1FFF, pattern: [0xAA, 0xBB], maximumElementCount: 1) == 1)
      #expect(try memory.codeGeneration(at: 0x1000, byteCount: 1) != first)
      #expect(try memory.codeGeneration(at: 0x2000, byteCount: 1) != second)
      #expect(try memory.codeGeneration(at: 0x3000, byteCount: 1) == third)
      #expect(
        try memory.fillRepeating(
          at: 0x2FFE, pattern: [1, 2], maximumElementCount: .max) == 1)
      #expect(try memory.read(at: 0x2FFE, byteCount: 3) == [1, 2, 0])
    }
  }

  @Test func largeVirtualReservationTracksOnlyWrittenCodePages() throws {
    let byteCount = 512 * 1024 * 1024 * 1024
    let memory = try DoryX86MmapMemory(validatingByteCount: byteCount)
    #expect(memory.trackedCodePageCount == 0)
    let lastAddress = UInt64(byteCount - 1)
    let first = try memory.codeGeneration(at: 0, byteCount: 1)
    let last = try memory.codeGeneration(at: lastAddress, byteCount: 1)
    #expect(memory.trackedCodePageCount == 0)
    try memory.writeScalar(at: lastAddress, value: 0xA5, byteCount: 1)
    #expect(memory.trackedCodePageCount == 1)
    #expect(try memory.codeGeneration(at: 0, byteCount: 1) == first)
    #expect(try memory.codeGeneration(at: lastAddress, byteCount: 1) != last)
    try memory.write(at: 4095, bytes: [0xAA, 0xBB])
    #expect(memory.trackedCodePageCount == 3)
    #expect(try memory.readScalar(at: lastAddress, byteCount: 1) == 0xA5)
  }

  @Test func boundedRangeCorpusMatchesByteArrayAndMmap() throws {
    let pair = try backends(byteCount: 65)
    var seed: UInt64 = 0xD012_0018
    func next() -> UInt64 {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1
      return seed
    }
    func captured(_ body: () throws -> [UInt8]) -> Result<[UInt8], DoryX86MemoryError> {
      do { return .success(try body()) } catch let error as DoryX86MemoryError {
        return .failure(error)
      } catch {
        Issue.record("Unexpected memory error: \(error)")
        return .success([])
      }
    }
    for _ in 0..<256 {
      let address = UInt64(0x0FFF) + next() % 69
      let count = Int(next() % 19) - 1
      let payload = (0..<max(0, count)).map { _ in UInt8(truncatingIfNeeded: next()) }
      let left = captured {
        try pair[0].write(at: address, bytes: payload)
        return []
      }
      let right = captured {
        try pair[1].write(at: address, bytes: payload)
        return []
      }
      #expect(left == right)
      #expect(
        captured { try pair[0].read(at: address, byteCount: count) }
          == captured { try pair[1].read(at: address, byteCount: count) })
      #expect(
        captured { try pair[0].instructionBytes(at: address, maximumCount: count) }
          == captured { try pair[1].instructionBytes(at: address, maximumCount: count) })
      #expect(
        try pair[0].read(at: 0x1000, byteCount: 65) == pair[1].read(at: 0x1000, byteCount: 65))
    }
  }
}
