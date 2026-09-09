import Darwin
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

  @Test func cSlowPathWalksOnceThenReturnsAHostAddressHit() throws {
    let physical = try DoryX86MmapMemory(validatingByteCount: 0x10_000)
    let paging = DoryX86PagingUnit()
    let translated = DoryX86TranslatedMemory(
      physicalMemory: physical,
      pagingUnit: paging,
      context: .init(state: .reset(), mode: .real16)
    )
    let tlb = try DoryX86JITTLB(entryCount: 16)

    #expect(
      try tlb.resolve(
        linearAddress: 0x4_123,
        byteCount: 8,
        addressSpaceGeneration: 1,
        access: .read,
        memory: translated
      ) == .filled(hostAddress: physical.hostAddressSpaceBase + 0x4_123))
    #expect(paging.diagnostics.translationRequests == 1)
    #expect(
      try tlb.lookup(
        linearAddress: 0x4_123,
        addressSpaceGeneration: 1,
        access: .read
      ) == physical.hostAddressSpaceBase + 0x4_123)
    #expect(
      try tlb.resolve(
        linearAddress: 0x4_127,
        byteCount: 4,
        addressSpaceGeneration: 1,
        access: .read,
        memory: translated
      ) == .hit(hostAddress: physical.hostAddressSpaceBase + 0x4_127))
    #expect(paging.diagnostics.translationRequests == 1)
    #expect(tlb.diagnostics.hits == 1)
    #expect(tlb.diagnostics.misses == 1)
    #expect(tlb.diagnostics.fills == 1)
    #expect(tlb.diagnostics.hitRate == 0.5)
  }

  @Test func cSlowPathReturnsExactPageFaultAndRetriesAfterMappingAppears() throws {
    let physical = try DoryX86MmapMemory(validatingByteCount: 0x10_000)
    let paging = DoryX86PagingUnit()
    let translated = DoryX86TranslatedMemory(
      physicalMemory: physical,
      pagingUnit: paging,
      context: longModeContext()
    )
    let tlb = try DoryX86JITTLB(entryCount: 16)
    let linear: UInt64 = 0x0040_0123

    #expect(
      try tlb.resolve(
        linearAddress: linear,
        byteCount: 4,
        addressSpaceGeneration: 3,
        access: .read,
        memory: translated
      ) == .pageFault(address: linear, errorCode: 0x4))
    #expect(paging.diagnostics.pageWalkFailures == 1)

    try installFourLevelMapping(
      linear: linear,
      physicalPage: 0x8_000,
      flags: 0x7,
      memory: physical
    )
    #expect(
      try tlb.resolve(
        linearAddress: linear,
        byteCount: 4,
        addressSpaceGeneration: 3,
        access: .read,
        memory: translated
      ) == .filled(hostAddress: physical.hostAddressSpaceBase + 0x8_123))
    #expect(paging.diagnostics.translationRequests == 2)
    #expect(try physical.readScalar(at: 0x1_000, byteCount: 8) & (1 << 5) != 0)
    #expect(try physical.readScalar(at: 0x4_000, byteCount: 8) & (1 << 5) != 0)
    #expect(tlb.diagnostics.misses == 2)
    #expect(tlb.diagnostics.fills == 1)
    #expect(tlb.diagnostics.pageFaults == 1)
  }

  @Test func cSlowPathDeclinesCrossPageAndOutOfReservationSpansBeforeCaching() throws {
    let physical = try DoryX86MmapMemory(validatingByteCount: 0x2_000)
    let paging = DoryX86PagingUnit()
    let translated = DoryX86TranslatedMemory(
      physicalMemory: physical,
      pagingUnit: paging,
      context: .init(state: .reset(), mode: .real16)
    )
    let tlb = try DoryX86JITTLB(entryCount: 16)

    #expect(
      try tlb.resolve(
        linearAddress: 0x1_fff,
        byteCount: 2,
        addressSpaceGeneration: 1,
        access: .read,
        memory: translated
      ) == .fallback)
    #expect(paging.diagnostics.translationRequests == 0)
    #expect(
      try tlb.resolve(
        linearAddress: 0x2_000,
        byteCount: 1,
        addressSpaceGeneration: 1,
        access: .read,
        memory: translated
      ) == .fallback)
    #expect(paging.diagnostics.translationRequests == 1)
    #expect(
      try tlb.lookup(linearAddress: 0x2_000, addressSpaceGeneration: 1, access: .read) == nil)
    #expect(tlb.diagnostics.misses == 1)
    #expect(tlb.diagnostics.fallbacks == 2)
  }

  @Test func cSlowPathUsesSparseHostOffsetRatherThanCompactPhysicalOffset() throws {
    let page = Int(getpagesize())
    let physical = try DoryX86MmapMemory(
      validatingByteCount: page * 2,
      hostAddressSpaceByteCount: page * 4,
      ramMappings: [
        .init(logicalOffset: 0, hostOffset: page, byteCount: page),
        .init(logicalOffset: page, hostOffset: page * 3, byteCount: page),
      ]
    )
    let translated = DoryX86TranslatedMemory(
      physicalMemory: physical,
      pagingUnit: DoryX86PagingUnit(),
      context: .init(state: .reset(), mode: .real16)
    )
    let tlb = try DoryX86JITTLB(entryCount: 16)

    #expect(
      try tlb.resolve(
        linearAddress: UInt64(page + 0x123),
        byteCount: 8,
        addressSpaceGeneration: 1,
        access: .write,
        memory: translated
      ) == .filled(hostAddress: physical.hostAddressSpaceBase + UInt64(page * 3 + 0x123)))
  }

  private func longModeContext() -> DoryX86PagingContext {
    .init(
      control: .init(
        cr0: 0x8001_0011,
        cr3: 0x1_000,
        cr4: 1 << 5,
        efer: (1 << 10) | (1 << 11)
      ),
      rflags: .reset,
      currentPrivilegeLevel: 3,
      mode: .long64
    )
  }

  private func installFourLevelMapping(
    linear: UInt64,
    physicalPage: UInt64,
    flags: UInt64,
    memory: DoryX86MmapMemory
  ) throws {
    try memory.writeScalar(
      at: 0x1_000 + ((linear >> 39) & 0x1ff) * 8,
      value: 0x2_007,
      byteCount: 8
    )
    try memory.writeScalar(
      at: 0x2_000 + ((linear >> 30) & 0x1ff) * 8,
      value: 0x3_007,
      byteCount: 8
    )
    try memory.writeScalar(
      at: 0x3_000 + ((linear >> 21) & 0x1ff) * 8,
      value: 0x4_007,
      byteCount: 8
    )
    try memory.writeScalar(
      at: 0x4_000 + ((linear >> 12) & 0x1ff) * 8,
      value: physicalPage | flags,
      byteCount: 8
    )
  }
}
