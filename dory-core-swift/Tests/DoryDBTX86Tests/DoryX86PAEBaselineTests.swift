import Testing

@testable import DoryDBTX86

// Intel SDM 092 Vol. 3A §§5.4.1/5.4.2, 5.6, 5.7 and 5.8:
// https://cdrdv2-public.intel.com/922487/253668-092-sdm-vol-3a.pdf
// Authored legacy-PAE mechanism tests supporting the selected profile's PAE
// promotion. They are not physical-reference evidence. PAT remains separate.
@Suite struct DoryX86PAEBaselineTests {
  @Test func fourKiBAndTwoMiBPermissionsCombinePDEAndPTEWithCPLAndWP() throws {
    for large in [false, true] {
      for directoryPermission: UInt64 in [0, 2, 4, 6] {
        for leafPermission: UInt64 in large ? [6] : [0, 2, 4, 6] {
          for cpl: UInt8 in [0, 3] {
            for wp in [false, true] {
              for access: DoryX86MemoryAccessKind in [.read, .write, .instructionFetch] {
                let fixture = try fixture(large: large, directoryPermission: directoryPermission,
                  leafPermission: leafPermission)
                let context = context(fixture, cpl: cpl, wp: wp)
                let writable = directoryPermission & 2 != 0 && leafPermission & 2 != 0
                let user = directoryPermission & 4 != 0 && leafPermission & 4 != 0
                let allowed = (cpl == 0 || user) && (access != .write || writable || (cpl == 0 && !wp))
                let paging = DoryX86PagingUnit(physicalAddressBits: 40)
                if allowed {
                  let result = try paging.translate(linearAddress: 0x123, access: access,
                    context: context, physicalMemory: fixture.memory)
                  #expect(result.physicalAddress == fixture.target + 0x123)
                  #expect(result.pageSize == (large ? 0x20_0000 : 0x1000))
                  #expect(result.writable == writable && result.userAccessible == user && result.executable)
                } else {
                  let code: UInt32 = 1 | (cpl == 3 ? 4 : 0) | (access == .write ? 2 : 0)
                  #expect(throws: DoryX86MemoryError.pageFault(address: 0x123, errorCode: code)) {
                    try paging.translate(linearAddress: 0x123, access: access,
                      context: context, physicalMemory: fixture.memory)
                  }
                  #expect(paging.cachedTranslationCount == 0)
                  #expect(try fixture.memory.word(at: fixture.leafAddress) & 0x40 == 0)
                }
                #expect(try fixture.memory.read(at: 0x9000, byteCount: 32) == fixture.rootImage)
              }
            }
          }
        }
      }
    }
  }

  @Test func NXAtEitherLevelHonorsNXEAndPublishesExactFetchFaultCR2() throws {
    for large in [false, true] {
      for nxDirectory in large ? [true] : [false, true] {
        for nxe in [false, true] {
          for cpl: UInt8 in [0, 3] {
            for access: DoryX86MemoryAccessKind in [.read, .write, .instructionFetch] {
              let fixture = try fixture(large: large)
              let entryAddress = nxDirectory ? fixture.directory : fixture.leafAddress
              try fixture.memory.setWord(try fixture.memory.word(at: entryAddress) | (1 << 63), at: entryAddress)
              let context = context(fixture, cpl: cpl, nxe: nxe)
              let paging = DoryX86PagingUnit(physicalAddressBits: 40)
              if nxe && access != .instructionFetch {
                let result = try paging.translate(linearAddress: 0x123, access: access,
                  context: context, physicalMemory: fixture.memory)
                #expect(result.physicalAddress == fixture.target + 0x123 && !result.executable)
              } else {
                let code: UInt32 = 1 | (nxe ? 0 : 8) | (cpl == 3 ? 4 : 0)
                  | (access == .write ? 2 : 0) | (nxe && access == .instructionFetch ? 16 : 0)
                #expect(throws: DoryX86MemoryError.pageFault(address: 0x123, errorCode: code)) {
                  try paging.translate(linearAddress: 0x123, access: access,
                    context: context, physicalMemory: fixture.memory)
                }
                #expect(paging.cachedTranslationCount == 0)
                if access == .instructionFetch {
                  var state = try state(context: context, rip: 0x123)
                  let before = state
                  #expect(DoryX86Interpreter().step(state: &state, memory: fixture.memory,
                    mode: .protected32, pagingUnit: paging) == .exception(.init(
                      kind: .pageFault, vector: 14, errorCode: code,
                      instructionPointer: 0x123, linearAddress: 0x123)))
                  var expected = before
                  expected.control.cr2 = 0x123
                  #expect(state == expected)
                }
              }
            }
          }
        }
      }
    }
  }

  @Test func sparsePhysicalBackingPreservesAddressBitsThroughTheFortyBitCeiling() throws {
    for large in [false, true] {
      let pageSize: UInt64 = large ? 0x20_0000 : 0x1000
      for target: UInt64 in [0x1_0000_0000, (1 << 39), (1 << 40) - pageSize] {
        // The directory and page table themselves also lie above 4GiB.
        let fixture = try fixture(large: large, directory: 0x1_0000_2000,
          table: 0x1_0000_3000, target: target)
        let last = pageSize - 1
        fixture.memory.mapPage(containing: target + last)
        try fixture.memory.write(at: target + last, bytes: [0xA5])
        let paging = DoryX86PagingUnit(physicalAddressBits: 40)
        let context = context(fixture, cpl: 3)
        let read = try paging.translate(linearAddress: last, access: .read,
          context: context, physicalMemory: fixture.memory)
        #expect(read.physicalAddress == target + last && read.pageSize == pageSize)
        let translated = DoryX86TranslatedMemory(physicalMemory: fixture.memory,
          pagingUnit: paging, context: context)
        #expect(try translated.read(at: last, byteCount: 1) == [0xA5])
        try translated.validateWrite(at: last, byteCount: 1)
        try translated.write(at: last, bytes: [0x5A])
        #expect(try fixture.memory.read(at: target + last, byteCount: 1) == [0x5A])
        #expect(try fixture.memory.word(at: fixture.leafAddress) & 0x60 == 0x60)
        #expect(fixture.memory.mappedByteCount <= 5 * 4096)
        #expect(try fixture.memory.read(at: 0x9000, byteCount: 32) == fixture.rootImage)
      }
    }
  }

  @Test func warmedTLBSeparatesCPLWriteProtectAccessKindAndNXE() throws {
    for large in [false, true] {
      let fixture = try fixture(large: large, directoryPermission: 0, leafPermission: 0)
      let paging = DoryX86PagingUnit(physicalAddressBits: 40)
      // Supervisor WP=0 may write a supervisor read-only page.
      _ = try paging.translate(linearAddress: 0x123, access: .write,
        context: context(fixture, cpl: 0, wp: false), physicalMemory: fixture.memory)
      #expect(throws: DoryX86MemoryError.pageFault(address: 0x123, errorCode: 3)) {
        try paging.translate(linearAddress: 0x123, access: .write,
          context: context(fixture, cpl: 0, wp: true), physicalMemory: fixture.memory)
      }
      #expect(throws: DoryX86MemoryError.pageFault(address: 0x123, errorCode: 7)) {
        try paging.translate(linearAddress: 0x123, access: .write,
          context: context(fixture, cpl: 3, wp: false), physicalMemory: fixture.memory)
      }
      _ = try paging.translate(linearAddress: 0x123, access: .read,
        context: context(fixture, cpl: 0), physicalMemory: fixture.memory)
      #expect(throws: DoryX86MemoryError.pageFault(address: 0x123, errorCode: 5)) {
        try paging.translate(linearAddress: 0x123, access: .read,
          context: context(fixture, cpl: 3), physicalMemory: fixture.memory)
      }

      let nx = try self.fixture(large: large)
      try nx.memory.setWord(try nx.memory.word(at: nx.leafAddress) | (1 << 63), at: nx.leafAddress)
      let nxPaging = DoryX86PagingUnit(physicalAddressBits: 40)
      _ = try nxPaging.translate(linearAddress: 0x123, access: .read,
        context: context(nx, cpl: 3, nxe: true), physicalMemory: nx.memory)
      #expect(throws: DoryX86MemoryError.pageFault(address: 0x123, errorCode: 21)) {
        try nxPaging.translate(linearAddress: 0x123, access: .instructionFetch,
          context: context(nx, cpl: 3, nxe: true), physicalMemory: nx.memory)
      }
      #expect(throws: DoryX86MemoryError.pageFault(address: 0x123, errorCode: 13)) {
        try nxPaging.translate(linearAddress: 0x123, access: .read,
          context: context(nx, cpl: 3, nxe: false), physicalMemory: nx.memory)
      }
    }
  }

  @Test func accessedDirtyAndInvalidationLeaveLatchedPDPTEsIndependentOfCR3RAM() throws {
    for large in [false, true] {
      let fixture = try fixture(large: large)
      let paging = DoryX86PagingUnit(physicalAddressBits: 40)
      let context = context(fixture, cpl: 3)
      let originalLeaf = try fixture.memory.word(at: fixture.leafAddress)
      _ = try paging.translate(linearAddress: 0x123, access: .read, context: context,
        physicalMemory: fixture.memory)
      #expect(try fixture.memory.word(at: fixture.leafAddress) == originalLeaf | 0x20)
      #expect(try fixture.memory.word(at: fixture.directory) & 0x20 != 0)
      _ = try paging.translate(linearAddress: 0x123, access: .write, context: context,
        physicalMemory: fixture.memory)
      #expect(try fixture.memory.word(at: fixture.leafAddress) == originalLeaf | 0x60)
      if !large { #expect(try fixture.memory.word(at: fixture.directory) & 0x40 == 0) }

      // Even completely invalid new PDPT RAM is invisible until an architectural
      // control-register reload. INVLPG only discards the translation cache.
      try fixture.memory.write(at: 0x9000, bytes: [UInt8](repeating: 0xFF, count: 32))
      paging.invalidate(linearAddress: 0x123)
      let beforeReads = fixture.memory.readAddresses.count
      let reloaded = try paging.translate(linearAddress: 0x123, access: .read,
        context: context, physicalMemory: fixture.memory)
      #expect(reloaded.physicalAddress == fixture.target + 0x123)
      #expect(!fixture.memory.readAddresses.dropFirst(beforeReads).contains(0x9000))
      #expect(context.control.legacyPAEPDPTEs == .init(fixture.directory | 1))
    }
  }

  @Test func nonpresentAndReservedEntriesWinOverAccumulatedPermissionDenial() throws {
    for present in [false, true] {
      let fixture = try fixture(directoryPermission: 0)
      let invalid: UInt64 = present ? (1 << 40) | 1 : UInt64.max & ~UInt64(1)
      try fixture.memory.setWord(invalid, at: fixture.leafAddress)
      let paging = DoryX86PagingUnit(physicalAddressBits: 40)
      let code: UInt32 = present ? 15 : 6 // User write: reserved or nonpresent, never permission-only 7.
      #expect(throws: DoryX86MemoryError.pageFault(address: 0x123, errorCode: code)) {
        try paging.translate(linearAddress: 0x123, access: .write,
          context: context(fixture, cpl: 3), physicalMemory: fixture.memory)
      }
      #expect(try fixture.memory.word(at: fixture.leafAddress) == invalid)
      #expect(paging.cachedTranslationCount == 0)
    }
    let fixture = try fixture()
    var control = context(fixture, cpl: 3).control
    control.legacyPAEPDPTEs = .init(UInt64.max & ~UInt64(1))
    let absent = DoryX86PagingContext(control: control, rflags: .reset,
      currentPrivilegeLevel: 3, mode: .protected32)
    let beforeReads = fixture.memory.readAddresses.count
    #expect(throws: DoryX86MemoryError.pageFault(address: 0x123, errorCode: 6)) {
      try DoryX86PagingUnit().translate(linearAddress: 0x123, access: .write,
        context: absent, physicalMemory: fixture.memory)
    }
    #expect(fixture.memory.readAddresses.count == beforeReads)
  }

  private struct Fixture {
    let memory: PAESparseMemory
    let directory: UInt64
    let leafAddress: UInt64
    let target: UInt64
    let rootImage: [UInt8]
  }

  private func fixture(large: Bool = false, directoryPermission: UInt64 = 6,
    leafPermission: UInt64 = 6, directory: UInt64 = 0x2000,
    table: UInt64 = 0x3000, target: UInt64? = nil) throws -> Fixture {
    let memory = PAESparseMemory()
    let target = target ?? (large ? 0x20_0000 : 0x8000)
    for address in [UInt64(0x9000), directory, table, target] { memory.mapPage(containing: address) }
    try memory.setWord(directory | 1, at: 0x9000)
    try memory.setWord((large ? target | 0x81 : table | 1) | directoryPermission, at: directory)
    if !large { try memory.setWord(target | 1 | leafPermission, at: table) }
    return .init(memory: memory, directory: directory, leafAddress: large ? directory : table,
      target: target, rootImage: try memory.read(at: 0x9000, byteCount: 32))
  }

  private func context(_ fixture: Fixture, cpl: UInt8, wp: Bool = true, nxe: Bool = false) -> DoryX86PagingContext {
    .init(control: .init(cr0: 0x8000_0011 | (wp ? 1 << 16 : 0), cr3: 0x9000, cr4: 1 << 5,
      efer: nxe ? 1 << 11 : 0, legacyPAEPDPTEs: .init(fixture.directory | 1)),
      rflags: .reset, currentPrivilegeLevel: cpl, mode: .protected32)
  }

  private func state(context: DoryX86PagingContext, rip: UInt64) throws -> DoryX86ArchitecturalState {
    try .init(rip: rip, rflags: context.rflags,
      cs: .init(selector: 8 | UInt16(context.currentPrivilegeLevel), attributes: 0xC09B, limit: .max),
      control: context.control)
  }
}

/// Explicit page authority lets tests exercise high physical addresses with at
/// most five actual 4KiB allocations. Reads and complete writes reject holes;
/// no implicit zero-filled address space or allocation-on-write is permitted.
private final class PAESparseMemory: DoryX86Memory, @unchecked Sendable {
  private var pages: [UInt64: [UInt8]] = [:]
  private(set) var readAddresses: [UInt64] = []
  var mappedByteCount: Int { pages.count * 4096 }

  func mapPage(containing address: UInt64) {
    let base = address & ~UInt64(0xFFF)
    if pages[base] == nil { pages[base] = [UInt8](repeating: 0, count: 4096) }
  }

  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    let count = min(maximumCount, 4096 - Int(address & 0xFFF))
    return try read(at: address, byteCount: count)
  }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    try validate(address, count: byteCount, access: .read)
    readAddresses.append(address)
    return (0..<byteCount).map { index in
      let position = address + UInt64(index)
      return pages[position & ~UInt64(0xFFF)]![Int(position & 0xFFF)]
    }
  }

  func validateWrite(at address: UInt64, byteCount: Int) throws {
    try validate(address, count: byteCount, access: .write)
  }

  func write(at address: UInt64, bytes: [UInt8]) throws {
    try validateWrite(at: address, byteCount: bytes.count)
    var written = 0
    while written < bytes.count {
      let position = address + UInt64(written)
      let base = position & ~UInt64(0xFFF)
      let offset = Int(position & 0xFFF)
      let count = min(bytes.count - written, 4096 - offset)
      var page = pages[base]!
      page.replaceSubrange(offset..<offset + count, with: bytes[written..<written + count])
      pages[base] = page
      written += count
    }
  }

  func word(at address: UInt64) throws -> UInt64 {
    try read(at: address, byteCount: 8).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
  }

  func setWord(_ value: UInt64, at address: UInt64) throws {
    try write(at: address, bytes: (0..<8).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
  }

  private func validate(_ address: UInt64, count: Int, access: DoryX86MemoryAccessKind) throws {
    guard count >= 0, count == 0 || !address.addingReportingOverflow(UInt64(count - 1)).overflow else {
      throw DoryX86MemoryError.addressOverflow(address: address, byteCount: count)
    }
    for index in 0..<count where pages[(address + UInt64(index)) & ~UInt64(0xFFF)] == nil {
      throw DoryX86MemoryError.unmapped(address: address + UInt64(index), byteCount: count - index, access: access)
    }
  }
}
