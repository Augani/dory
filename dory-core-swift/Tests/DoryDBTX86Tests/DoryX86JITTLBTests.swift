import Testing

@testable import DoryDBTX86

@Suite struct DoryX86JITTLBTests {
  @Test func defaultStorageHasStableSeparateAccessArrays() throws {
    let tlb = try DoryX86JITTLB()

    #expect(tlb.entryCount == 1_024)
    #expect(tlb.allocatedByteCount == 48 * 1_024)
    let bases = DoryX86JITTLBAccess.allCases.map(tlb.entriesBaseAddress(for:))
    #expect(bases.allSatisfy { $0 != 0 })
    #expect(Set(bases).count == 3)
    #expect(bases[1] - bases[0] == 16 * 1_024)
    #expect(bases[2] - bases[1] == 16 * 1_024)
  }

  @Test func accessClassesAndAddressSpaceGenerationsNeverAlias() throws {
    let tlb = try DoryX86JITTLB(entryCount: 8)
    let linear: UInt64 = 0xffff_8000_1234_5567
    try tlb.fill(
      linearAddress: linear,
      addressSpaceGeneration: 7,
      access: .read,
      hostAddress: 0x0000_6000_1234_5567
    )

    #expect(
      try tlb.lookup(linearAddress: linear, addressSpaceGeneration: 7, access: .read)
        == 0x0000_6000_1234_5567)
    #expect(try tlb.lookup(linearAddress: linear, addressSpaceGeneration: 8, access: .read) == nil)
    #expect(try tlb.lookup(linearAddress: linear, addressSpaceGeneration: 7, access: .write) == nil)
    #expect(
      try tlb.lookup(linearAddress: linear, addressSpaceGeneration: 7, access: .execute) == nil)
  }

  @Test func directMappedCollisionReplacesOnlyOneAccessClass() throws {
    let tlb = try DoryX86JITTLB(entryCount: 4)
    let first: UInt64 = 0x1_234
    let collision = first + UInt64(tlb.entryCount << DoryX86JITTLB.pageShift)
    try tlb.fill(
      linearAddress: first,
      addressSpaceGeneration: 1,
      access: .read,
      hostAddress: 0x10_234
    )
    try tlb.fill(
      linearAddress: first,
      addressSpaceGeneration: 1,
      access: .write,
      hostAddress: 0x20_234
    )
    try tlb.fill(
      linearAddress: collision,
      addressSpaceGeneration: 1,
      access: .read,
      hostAddress: 0x30_234
    )

    #expect(try tlb.lookup(linearAddress: first, addressSpaceGeneration: 1, access: .read) == nil)
    #expect(
      try tlb.lookup(linearAddress: collision, addressSpaceGeneration: 1, access: .read)
        == 0x30_234)
    #expect(
      try tlb.lookup(linearAddress: first, addressSpaceGeneration: 1, access: .write)
        == 0x20_234)
  }

  @Test func pageAndGlobalInvalidationClearExpectedEntries() throws {
    let tlb = try DoryX86JITTLB(entryCount: 8)
    for access in DoryX86JITTLBAccess.allCases {
      try tlb.fill(
        linearAddress: 0x1_123,
        addressSpaceGeneration: 2,
        access: access,
        hostAddress: 0x10_123
      )
      try tlb.fill(
        linearAddress: 0x2_123,
        addressSpaceGeneration: 2,
        access: access,
        hostAddress: 0x20_123
      )
    }

    tlb.invalidate(linearAddress: 0x1_fff)
    for access in DoryX86JITTLBAccess.allCases {
      #expect(
        try tlb.lookup(linearAddress: 0x1_123, addressSpaceGeneration: 2, access: access) == nil)
      #expect(
        try tlb.lookup(linearAddress: 0x2_123, addressSpaceGeneration: 2, access: access)
          == 0x20_123)
    }

    tlb.invalidateAll()
    for access in DoryX86JITTLBAccess.allCases {
      #expect(
        try tlb.lookup(linearAddress: 0x2_123, addressSpaceGeneration: 2, access: access) == nil)
    }
  }

  @Test func tagsAreExactAcrossCanonicalHalvesAndRejectInvalidGenerations() throws {
    let low = try DoryX86JITTLB.tag(
      linearAddress: 0x0000_0000_1234_5000,
      addressSpaceGeneration: 1
    )
    let high = try DoryX86JITTLB.tag(
      linearAddress: 0xffff_8000_1234_5000,
      addressSpaceGeneration: 1
    )
    let next = try DoryX86JITTLB.tag(
      linearAddress: 0x0000_0000_1234_5000,
      addressSpaceGeneration: 2
    )

    #expect(low != high)
    #expect(low != next)
    #expect(throws: DoryX86JITTLBError.invalidAddressSpaceGeneration(0)) {
      try DoryX86JITTLB.tag(linearAddress: 0, addressSpaceGeneration: 0)
    }
    #expect(
      throws: DoryX86JITTLBError.invalidAddressSpaceGeneration(
        DoryX86JITTLB.maximumAddressSpaceGeneration + 1)
    ) {
      try DoryX86JITTLB.tag(
        linearAddress: 0,
        addressSpaceGeneration: DoryX86JITTLB.maximumAddressSpaceGeneration + 1
      )
    }
  }

  @Test func entryCountMustBeAPowerOfTwo() {
    #expect(throws: DoryX86JITTLBError.invalidEntryCount(0)) {
      try DoryX86JITTLB(entryCount: 0)
    }
    #expect(throws: DoryX86JITTLBError.invalidEntryCount(3)) {
      try DoryX86JITTLB(entryCount: 3)
    }
  }
}
