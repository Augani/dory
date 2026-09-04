import Testing

@testable import DoryDBTX86

// Intel SDM revision 092, Vol. 3A §§5.3, 5.4.2, 5.7:
// https://cdrdv2-public.intel.com/922487/253668-092-sdm-vol-3a.pdf
// These tests qualify entry checks only, not PAE PDPTE latching or feature advertisement.
@Suite struct DoryX86PagingReservedBitsTests {
  @Test func paeDirectoryAndTableEntriesReserveEveryBitAbovePhysicalWidthBelowNX() throws {
    for width: UInt8 in [32, 40, 52] {
      for level in [1, 2] {
        for huge in level == 1 ? [false, true] : [false] {
          for bit in Int(width)..<63 {
            for nxe in [false, true] {
              for cpl: UInt8 in [0, 3] {
                for access: DoryX86MemoryAccessKind in [.read, .write, .instructionFetch] {
                  let memory = try paeMemory(huge: huge)
                  let address: UInt64 = level == 1 ? 0x2000 : 0x3000
                  let original = try memory.readScalar(at: address, byteCount: 8) | (1 << bit)
                  try memory.writeScalar(at: address, value: original, byteCount: 8)
                  let paging = DoryX86PagingUnit(physicalAddressBits: width)
                  let context = paeContext(cpl: cpl, nxe: nxe)
                  let errorCode: UInt32 = 9 | (cpl == 3 ? 4 : 0)
                    | (access == .write ? 2 : 0) | (access == .instructionFetch && nxe ? 16 : 0)
                  #expect(throws: DoryX86MemoryError.pageFault(address: 0x123, errorCode: errorCode)) {
                    try paging.translate(linearAddress: 0x123, access: access,
                      context: context, physicalMemory: memory)
                  }
                  // An invalid entry must not acquire A/D bits. A valid ancestor may acquire A.
                  #expect(try memory.readScalar(at: address, byteCount: 8) == original)
                  #expect(try memory.readScalar(at: 0x1000, byteCount: 8) == 0x2001)
                  #expect(paging.cachedTranslationCount == 0)
                }
              }
            }
          }
        }
      }
    }
  }

  @Test func nonpresentPAEEntriesIgnoreReservedAndNXBits() throws {
    for level in [1, 2] {
      for access: DoryX86MemoryAccessKind in [.read, .write, .instructionFetch] {
        let memory = try paeMemory()
        let address: UInt64 = level == 1 ? 0x2000 : 0x3000
        let original: UInt64 = 0xFFFF_FFFF_FFFF_FF9E // P/A/D clear, otherwise arbitrary.
        try memory.writeScalar(at: address, value: original, byteCount: 8)
        let paging = DoryX86PagingUnit()
        let errorCode: UInt32 = access == .write ? 6 : 4
        #expect(throws: DoryX86MemoryError.pageFault(address: 0x123, errorCode: errorCode)) {
          try paging.translate(linearAddress: 0x123, access: access,
            context: paeContext(cpl: 3, nxe: false), physicalMemory: memory)
        }
        #expect(try memory.readScalar(at: address, byteCount: 8) == original)
        #expect(paging.cachedTranslationCount == 0)
      }
    }
  }

  @Test func ia32eDoesNotTreatIgnoredHighBitsAsLegacyPAEReservedBits() throws {
    for width: UInt8 in [32, 40, 52] {
      for access: DoryX86MemoryAccessKind in [.read, .write, .instructionFetch] {
        let memory = try DoryX86ByteArrayMemory(byteCount: 0x6000)
        for (entryAddress, nextPage): (UInt64, UInt64) in [
          (0x1000, 0x2000), (0x2000, 0x3000), (0x3000, 0x4000), (0x4000, 0x5000),
        ] {
          try memory.writeScalar(at: entryAddress,
            value: nextPage | 0x7FF0_0000_0000_0007, byteCount: 8)
        }
        let context = DoryX86PagingContext(
          control: .init(cr0: (1 << 31) | 1, cr3: 0x1000, cr4: 1 << 5, efer: 1 << 10),
          rflags: [.reservedOne], currentPrivilegeLevel: 3, mode: .long64)
        let translation = try DoryX86PagingUnit(physicalAddressBits: width).translate(
          linearAddress: 0x123, access: access, context: context, physicalMemory: memory)
        #expect(translation.physicalAddress == 0x5123)
        #expect(translation.pageSize == 0x1000)
        #expect(translation.executable)
      }
    }
  }

  @Test func legacyFourMiBPagesRejectUnmodeledPSE36BitsBeforeAccessedOrDirtyUpdates() throws {
    for width: UInt8 in [32, 40, 52] {
      for bit in 13...21 {
        for cpl: UInt8 in [0, 3] {
          for access: DoryX86MemoryAccessKind in [.read, .write, .instructionFetch] {
            let memory = try DoryX86ByteArrayMemory(byteCount: 0x2000)
            let original: UInt64 = 0x0040_0087 | (1 << bit)
            try memory.writeScalar(at: 0x1000, value: original, byteCount: 4)
            let before = memory.snapshot()
            let paging = DoryX86PagingUnit(physicalAddressBits: width)
            let errorCode: UInt32 = 9 | (cpl == 3 ? 4 : 0) | (access == .write ? 2 : 0)
            #expect(throws: DoryX86MemoryError.pageFault(address: 0x123, errorCode: errorCode)) {
              try paging.translate(linearAddress: 0x123, access: access,
                context: legacyContext(cpl: cpl, pse: true), physicalMemory: memory)
            }
            #expect(memory.snapshot() == before)
            #expect(paging.cachedTranslationCount == 0)
          }
        }
      }
    }
  }

  @Test func legacyPageTableAddressesKeepBitsThatAreReservedOnlyForFourMiBPages() throws {
    for (pse, ps) in [(false, false), (false, true), (true, false)] {
      for bit in 13...21 {
        let table: UInt64 = 1 << bit
        let memory = try DoryX86ByteArrayMemory(byteCount: Int(table + 0x1000))
        try memory.writeScalar(at: 0x1000, value: table | 7 | (ps ? 0x80 : 0), byteCount: 4)
        try memory.writeScalar(at: table, value: 0x5007, byteCount: 4)
        let translation = try DoryX86PagingUnit().translate(
          linearAddress: 0x123, access: .write,
          context: legacyContext(cpl: 3, pse: pse), physicalMemory: memory)
        #expect(translation.physicalAddress == 0x5123)
        #expect(translation.pageSize == 0x1000)
      }
    }
  }

  @Test func validAndNonpresentLegacyLargePagesRetainTheirExistingSemantics() throws {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x2000)
    try memory.writeScalar(at: 0x1000, value: 0x0040_0087, byteCount: 4)
    let valid = try DoryX86PagingUnit().translate(linearAddress: 0x123, access: .write,
      context: legacyContext(cpl: 3, pse: true), physicalMemory: memory)
    #expect(valid.physicalAddress == 0x0040_0123)
    #expect(valid.pageSize == 1 << 22)
    #expect(try memory.readScalar(at: 0x1000, byteCount: 4) == 0x0040_00E7)
    let absent: UInt64 = 0x003F_E086 // P clear, PS and bits21:13 set.
    try memory.writeScalar(at: 0x1000, value: absent, byteCount: 4)
    for access: DoryX86MemoryAccessKind in [.read, .write, .instructionFetch] {
      let errorCode: UInt32 = access == .write ? 6 : 4
      #expect(throws: DoryX86MemoryError.pageFault(address: 0x123, errorCode: errorCode)) {
        try DoryX86PagingUnit().translate(linearAddress: 0x123, access: access,
          context: legacyContext(cpl: 3, pse: true), physicalMemory: memory)
      }
      #expect(try memory.readScalar(at: 0x1000, byteCount: 4) == absent)
    }
  }

  private func paeMemory(huge: Bool = false) throws -> DoryX86ByteArrayMemory {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x5000)
    try memory.writeScalar(at: 0x1000, value: 0x2001, byteCount: 8)
    try memory.writeScalar(at: 0x2000, value: huge ? 0x87 : 0x3007, byteCount: 8)
    try memory.writeScalar(at: 0x3000, value: 0x4007, byteCount: 8)
    return memory
  }

  private func paeContext(cpl: UInt8, nxe: Bool) -> DoryX86PagingContext {
    .init(control: .init(cr0: (1 << 31) | 1, cr3: 0x1000, cr4: 1 << 5,
      efer: nxe ? 1 << 11 : 0, legacyPAEPDPTEs: .init(0x2001)),
      rflags: [.reservedOne], currentPrivilegeLevel: cpl, mode: .protected32)
  }

  private func legacyContext(cpl: UInt8, pse: Bool) -> DoryX86PagingContext {
    .init(control: .init(cr0: (1 << 31) | 1, cr3: 0x1000, cr4: pse ? 1 << 4 : 0),
      rflags: [.reservedOne], currentPrivilegeLevel: cpl, mode: .protected32)
  }
}
