import Foundation
import Testing

@testable import DoryExecutionContracts

@Suite struct GuestMemoryContractTests {
  @Test func checkedRangesRejectEmptyAndOverflowAndUseHalfOpenOverlap() throws {
    #expect(throws: DoryExecutionContractError.emptyRange) {
      try DoryGuestAddressRange(base: 0, byteCount: 0)
    }
    #expect(throws: DoryExecutionContractError.addressOverflow(base: .max, byteCount: 1)) {
      try DoryGuestAddressRange(base: .max, byteCount: 1)
    }

    let first = try DoryGuestAddressRange(base: 0x1_000, byteCount: 0x1_000)
    let adjacent = try DoryGuestAddressRange(base: 0x2_000, byteCount: 0x1_000)
    let overlapping = try DoryGuestAddressRange(base: 0x1fff, byteCount: 2)
    #expect(!first.overlaps(adjacent))
    #expect(first.overlaps(overlapping))
    #expect(first.contains(DoryGuestPhysicalAddress(0x1fff)))
    #expect(!first.contains(DoryGuestPhysicalAddress(0x2_000)))
  }

  @Test func regionsRequirePageAlignmentCanonicalPermissionsAndGenerations() throws {
    let range = try DoryGuestAddressRange(base: 0x4_000, byteCount: 0x2_000)
    let region = try DoryGuestMemoryRegion(
      id: 7,
      range: range,
      pageSize: 0x1_000,
      permissions: [.write, .read, .execute],
      ownership: .executionEngine,
      mappingGeneration: 3,
      dirtyTracking: .epoch(4)
    )
    #expect(region.permissions == [.execute, .read, .write])

    #expect(throws: DoryExecutionContractError.invalidPageSize(3)) {
      try DoryGuestMemoryRegion(
        id: 7,
        range: range,
        pageSize: 3,
        permissions: [.read],
        ownership: .executionEngine,
        mappingGeneration: 3,
        dirtyTracking: .disabled
      )
    }
    #expect(throws: DoryExecutionContractError.duplicatePermission(.read)) {
      try DoryGuestMemoryRegion(
        id: 7,
        range: range,
        pageSize: 0x1_000,
        permissions: [.read, .read],
        ownership: .executionEngine,
        mappingGeneration: 3,
        dirtyTracking: .disabled
      )
    }
  }

  @Test func memoryLayoutAndDirtyPagesRejectAmbiguousState() throws {
    let first = try region(id: 1, base: 0, byteCount: 0x4_000)
    let second = try region(id: 2, base: 0x4_000, byteCount: 0x2_000)
    try DoryGuestMemoryLayout.validateNonoverlapping([second, first])

    let overlap = try region(id: 3, base: 0x3_000, byteCount: 0x2_000)
    #expect(
      throws: DoryExecutionContractError.nonCanonicalCollection(
        type: "guest memory layout"
      )
    ) {
      try DoryGuestMemoryLayout.validateNonoverlapping([first, overlap])
    }

    let dirty = try DoryDirtyPageSet(
      region: first,
      dirtyEpoch: 2,
      pageOffsets: [0, 0x1_000, 0x3_000]
    )
    #expect(dirty.pageOffsets == [0, 0x1_000, 0x3_000])
    #expect(throws: DoryExecutionContractError.nonCanonicalDirtyPageOffsets) {
      try DoryDirtyPageSet(
        region: first,
        dirtyEpoch: 2,
        pageOffsets: [0x1_000, 0]
      )
    }
    #expect(throws: DoryExecutionContractError.dirtyPageOffsetOutOfRange(0x4_000)) {
      try DoryDirtyPageSet(
        region: first,
        dirtyEpoch: 2,
        pageOffsets: [0x4_000]
      )
    }
  }

  @Test func decodingCannotBypassRangeOrRegionValidation() throws {
    let invalidRange = Data(#"{"base":18446744073709551615,"byteCount":1}"#.utf8)
    #expect(throws: DoryExecutionContractError.self) {
      try JSONDecoder().decode(DoryGuestAddressRange.self, from: invalidRange)
    }

    let invalidRegion = Data(
      #"{"dirtyTracking":{"disabled":{}},"id":1,"mappingGeneration":1,"ownership":"executionEngine","pageSize":3,"permissions":["read"],"range":{"base":0,"byteCount":4096}}"#
        .utf8)
    #expect(throws: DoryExecutionContractError.invalidPageSize(3)) {
      try JSONDecoder().decode(DoryGuestMemoryRegion.self, from: invalidRegion)
    }
  }

  @Test func processLocalBackingChecksBoundsAndAlignment() throws {
    let memory = UnsafeMutableRawPointer.allocate(byteCount: 0x2_000, alignment: 0x1_000)
    defer { memory.deallocate() }
    let mappedRegion = try region(id: 8, base: 0x8_000, byteCount: 0x2_000)
    let mapping = try DoryGuestMemoryMapping(
      region: mappedRegion,
      hostAddress: memory,
      hostByteCount: 0x2_000
    )
    #expect(mapping.region == mappedRegion)

    #expect(
      throws: DoryExecutionContractError.backingTooSmall(
        required: 0x2_000,
        actual: 0x1_000
      )
    ) {
      try DoryGuestMemoryMapping(
        region: mappedRegion,
        hostAddress: memory,
        hostByteCount: 0x1_000
      )
    }
    #expect(
      throws: DoryExecutionContractError.unalignedHostAddress(
        address: UInt(bitPattern: memory + 1),
        pageSize: 0x1_000
      )
    ) {
      try DoryGuestMemoryMapping(
        region: mappedRegion,
        hostAddress: memory + 1,
        hostByteCount: 0x2_000
      )
    }
  }

  private func region(id: UInt32, base: UInt64, byteCount: UInt64) throws -> DoryGuestMemoryRegion {
    try DoryGuestMemoryRegion(
      id: id,
      range: DoryGuestAddressRange(base: base, byteCount: byteCount),
      pageSize: 0x1_000,
      permissions: [.read, .write],
      ownership: .executionEngine,
      mappingGeneration: 1,
      dirtyTracking: .epoch(1)
    )
  }
}
