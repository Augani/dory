import Testing

@testable import DoryDBTX86

// Intel SDM revision 092, Vol. 3A §5.8 and the #PF architectural-state note:
// https://cdrdv2-public.intel.com/922487/253668-092-sdm-vol-3a.pdf
// Every paging-structure entry used by a translation acquires A. On a protection
// fault the page-directory A flag is architecturally set; only the final PTE's A
// behavior is model-specific. These cases therefore target large-page leaves.
@Suite struct DoryX86LargePageAccessedFaultTests {
  @Test func protectionFaultsSetLargeLeafAccessedWithoutDirtyOrCaching() throws {
    for shape in Shape.allCases {
      for fault in Fault.allCases {
        let fixture = try fixture(shape, fault: fault)
        let paging = DoryX86PagingUnit(physicalAddressBits: 40)

        #expect(throws: DoryX86MemoryError.pageFault(
          address: Self.linearAddress, errorCode: fault.errorCode
        )) {
          try paging.translate(
            linearAddress: Self.linearAddress,
            access: fault.access,
            context: fixture.context,
            physicalMemory: fixture.memory
          )
        }

        #expect(try word(fixture.memory, at: fixture.leafAddress) == fixture.leafEntry | (1 << 5))
        for (address, entry) in fixture.ancestors {
          #expect(try word(fixture.memory, at: address) == entry | (1 << 5))
        }
        #expect(try word(fixture.memory, at: fixture.leafAddress) & (1 << 6) == 0)
        #expect(paging.cachedTranslationCount == 0)
      }
    }
  }

  private static let linearAddress: UInt64 = 0x123

  private enum Shape: CaseIterable {
    case pae2M
    case ia32e2M
    case ia32e1G
  }

  private enum Fault: CaseIterable {
    case userRead
    case supervisorWriteProtect
    case executeDisable
    case supervisorExecuteUser

    var access: DoryX86MemoryAccessKind {
      switch self {
      case .userRead: .read
      case .supervisorWriteProtect: .write
      case .executeDisable, .supervisorExecuteUser: .instructionFetch
      }
    }

    var errorCode: UInt32 {
      switch self {
      case .userRead: 0x5
      case .supervisorWriteProtect: 0x3
      case .executeDisable: 0x15
      case .supervisorExecuteUser: 0x11
      }
    }

    var isUserAccess: Bool { self == .userRead || self == .executeDisable }
    var isWritable: Bool { self != .supervisorWriteProtect }
    var isUserPage: Bool { self != .userRead }
    var hasExecuteDisable: Bool { self == .executeDisable }
    var hasSMEP: Bool { self == .supervisorExecuteUser }
  }

  private struct Fixture {
    let memory: DoryX86ByteArrayMemory
    let context: DoryX86PagingContext
    let leafAddress: UInt64
    let leafEntry: UInt64
    let ancestors: [(UInt64, UInt64)]
  }

  private func fixture(_ shape: Shape, fault: Fault) throws -> Fixture {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x5000)
    let leafEntry = UInt64(1 | (1 << 7))
      | (fault.isWritable ? 1 << 1 : 0)
      | (fault.isUserPage ? 1 << 2 : 0)
      | (fault.hasExecuteDisable ? 1 << 63 : 0)
    let cr0 = UInt64((1 << 31) | 1) | (fault == .supervisorWriteProtect ? 1 << 16 : 0)
    let cpl: UInt8 = fault.isUserAccess ? 3 : 0
    let cr4 = UInt64(1 << 5) | (fault.hasSMEP ? 1 << 20 : 0)
    let nxe = fault.hasExecuteDisable ? UInt64(1 << 11) : 0

    switch shape {
    case .pae2M:
      try memory.writeScalar(at: 0x2000, value: leafEntry, byteCount: 8)
      return .init(
        memory: memory,
        context: .init(
          control: .init(
            cr0: cr0, cr3: 0x1000, cr4: cr4, efer: nxe,
            legacyPAEPDPTEs: .init(0x2001)),
          rflags: .reset, currentPrivilegeLevel: cpl, mode: .protected32),
        leafAddress: 0x2000,
        leafEntry: leafEntry,
        ancestors: []
      )
    case .ia32e2M:
      let pml4e: UInt64 = 0x2007
      let pdpte: UInt64 = 0x3007
      try memory.writeScalar(at: 0x1000, value: pml4e, byteCount: 8)
      try memory.writeScalar(at: 0x2000, value: pdpte, byteCount: 8)
      try memory.writeScalar(at: 0x3000, value: leafEntry, byteCount: 8)
      return .init(
        memory: memory,
        context: .init(
          control: .init(
            cr0: cr0, cr3: 0x1000, cr4: cr4, efer: (1 << 10) | nxe),
          rflags: .reset, currentPrivilegeLevel: cpl, mode: .long64),
        leafAddress: 0x3000,
        leafEntry: leafEntry,
        ancestors: [(UInt64(0x1000), pml4e), (UInt64(0x2000), pdpte)]
      )
    case .ia32e1G:
      let pml4e: UInt64 = 0x2007
      try memory.writeScalar(at: 0x1000, value: pml4e, byteCount: 8)
      try memory.writeScalar(at: 0x2000, value: leafEntry, byteCount: 8)
      return .init(
        memory: memory,
        context: .init(
          control: .init(
            cr0: cr0, cr3: 0x1000, cr4: cr4, efer: (1 << 10) | nxe),
          rflags: .reset, currentPrivilegeLevel: cpl, mode: .long64),
        leafAddress: 0x2000,
        leafEntry: leafEntry,
        ancestors: [(UInt64(0x1000), pml4e)]
      )
    }
  }

  private func word(_ memory: DoryX86ByteArrayMemory, at address: UInt64) throws -> UInt64 {
    try memory.readScalar(at: address, byteCount: 8)
  }
}
