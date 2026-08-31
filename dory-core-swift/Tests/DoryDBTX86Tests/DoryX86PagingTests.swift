import Testing

@testable import DoryDBTX86

@Suite struct DoryX86PagingTests {
  @Test func walksFourLevelsAndSetsAccessedAndDirtyBits() throws {
    let memory = DoryX86ByteArrayMemory(byteCount: 0x10_000)
    let linear: UInt64 = 0x0040_0123
    try installFourLevelMapping(linear: linear, physicalPage: 0x8000, flags: 0x7, memory: memory)
    let paging = DoryX86PagingUnit()
    let context = longModeContext(cpl: 3)

    let read = try paging.translate(
      linearAddress: linear, access: .read, context: context, physicalMemory: memory)
    #expect(read.physicalAddress == 0x8123)
    #expect(try read64(memory, 0x1000) & (1 << 5) != 0)
    #expect(try read64(memory, 0x2000) & (1 << 5) != 0)
    #expect(try read64(memory, 0x3000 + 2 * 8) & (1 << 5) != 0)
    #expect(try read64(memory, 0x4000) & (1 << 5) != 0)
    #expect(try read64(memory, 0x4000) & (1 << 6) == 0)

    let write = try paging.translate(
      linearAddress: linear, access: .write, context: context, physicalMemory: memory)
    #expect(write.physicalAddress == 0x8123)
    #expect(try read64(memory, 0x4000) & (1 << 6) != 0)
  }

  @Test func reportsExecuteDisableAndUserProtectionPrecisely() throws {
    let memory = DoryX86ByteArrayMemory(byteCount: 0x10_000)
    let linear: UInt64 = 0x0080_0000
    try installFourLevelMapping(
      linear: linear,
      physicalPage: 0x9000,
      flags: 0x7 | (1 << 63),
      memory: memory
    )
    let paging = DoryX86PagingUnit()
    do {
      _ = try paging.translate(
        linearAddress: linear,
        access: .instructionFetch,
        context: longModeContext(cpl: 3),
        physicalMemory: memory
      )
      Issue.record("NX fetch unexpectedly translated")
    } catch let DoryX86MemoryError.pageFault(address, errorCode) {
      #expect(address == linear)
      #expect(errorCode == 0x15)
    }
  }

  @Test func invalidationMakesChangedPageTablesVisible() throws {
    let memory = DoryX86ByteArrayMemory(byteCount: 0x10_000)
    let linear: UInt64 = 0x0040_0000
    try installFourLevelMapping(linear: linear, physicalPage: 0x8000, flags: 0x7, memory: memory)
    let paging = DoryX86PagingUnit()
    let context = longModeContext(cpl: 3)
    #expect(
      try paging.translate(
        linearAddress: linear, access: .read, context: context, physicalMemory: memory
      ).physicalAddress == 0x8000)

    try write64(memory, 0x4000, 0x9000 | 0x7)
    #expect(
      try paging.translate(
        linearAddress: linear, access: .read, context: context, physicalMemory: memory
      ).physicalAddress == 0x8000)
    paging.invalidate(linearAddress: linear)
    #expect(
      try paging.translate(
        linearAddress: linear, access: .read, context: context, physicalMemory: memory
      ).physicalAddress == 0x9000)
  }

  @Test func instructionFetchAcrossMissingPageRaisesPageFaultNotInvalidOpcode() throws {
    let memory = DoryX86ByteArrayMemory(byteCount: 0x10_000)
    let linearPage: UInt64 = 0x0040_0000
    try installFourLevelMapping(
      linear: linearPage, physicalPage: 0x8000, flags: 0x3, memory: memory)
    try memory.write(at: 0x8fff, bytes: [0x0f])
    var state = try DoryX86ArchitecturalState(
      rip: linearPage + 0xfff,
      cs: .init(selector: 0, attributes: 0xA09B, limit: .max, base: 0),
      control: longModeControl()
    )
    let result = DoryX86Interpreter().step(
      state: &state,
      memory: memory,
      mode: .long64,
      pagingUnit: .init()
    )
    #expect(
      result
        == .exception(
          .init(
            kind: .pageFault,
            vector: 14,
            errorCode: 0x10,
            instructionPointer: linearPage + 0xfff,
            linearAddress: linearPage + 0x1000
          )))
    #expect(state.rip == linearPage + 0xfff)
    #expect(state.control.cr2 == linearPage + 0x1000)
  }

  @Test func bulkCopyRejectsDistinctLinearRangesThatAliasPhysicalRAM() throws {
    let memory = DoryX86ByteArrayMemory(byteCount: 0x10_000)
    let source: UInt64 = 0x0040_0100
    let destination: UInt64 = 0x0040_1102
    try installFourLevelMapping(
      linear: source, physicalPage: 0x8000, flags: 0x7, memory: memory)
    try installFourLevelMapping(
      linear: destination, physicalPage: 0x8000, flags: 0x7, memory: memory)
    let translated = DoryX86TranslatedMemory(
      physicalMemory: memory,
      pagingUnit: DoryX86PagingUnit(),
      context: longModeContext(cpl: 3)
    )

    #expect(
      try translated.copyForwardNonoverlapping(
        from: source,
        to: destination,
        maximumByteCount: 4
      ) == nil
    )
  }

  @Test func walksPAELargePagesAndLegacyPageTables() throws {
    let paeMemory = DoryX86ByteArrayMemory(byteCount: 0x10_000)
    try write64(paeMemory, 0x1000, 0x2000 | 0x7)
    try write64(paeMemory, 0x2000 + 2 * 8, 0x87)
    let paeContext = DoryX86PagingContext(
      control: .init(cr0: 0x8000_0011, cr3: 0x1000, cr4: 1 << 5, efer: 1 << 11),
      rflags: .reset,
      currentPrivilegeLevel: 3,
      mode: .protected32
    )
    let pae = try DoryX86PagingUnit().translate(
      linearAddress: 0x0040_1234,
      access: .read,
      context: paeContext,
      physicalMemory: paeMemory
    )
    #expect(pae.physicalAddress == 0x1234)
    #expect(pae.pageSize == 1 << 21)

    let legacyMemory = DoryX86ByteArrayMemory(byteCount: 0x10_000)
    try write32(legacyMemory, 0x1000 + 4, 0x2000 | 0x7)
    try write32(legacyMemory, 0x2000 + 4, 0x8000 | 0x5)
    let legacyContext = DoryX86PagingContext(
      control: .init(cr0: 0x8001_0011, cr3: 0x1000),
      rflags: .reset,
      currentPrivilegeLevel: 3,
      mode: .protected32
    )
    let legacy = try DoryX86PagingUnit().translate(
      linearAddress: 0x0040_1234,
      access: .read,
      context: legacyContext,
      physicalMemory: legacyMemory
    )
    #expect(legacy.physicalAddress == 0x8234)
    do {
      _ = try DoryX86PagingUnit().translate(
        linearAddress: 0x0040_1234,
        access: .write,
        context: legacyContext,
        physicalMemory: legacyMemory
      )
      Issue.record("user write to a read-only legacy page unexpectedly translated")
    } catch DoryX86MemoryError.pageFault(_, let errorCode) {
      #expect(errorCode == 0x7)
    }
  }

  @Test func compatibilityModeUsesIA32ePageTablesOnceLongModeIsActive() throws {
    let memory = DoryX86ByteArrayMemory(byteCount: 0x10_000)
    let linear: UInt64 = 0x00C0_0123
    try installFourLevelMapping(linear: linear, physicalPage: 0x8000, flags: 0x3, memory: memory)
    let context = DoryX86PagingContext(
      control: .init(
        cr0: 0x8000_0011,
        cr3: 0x1000,
        cr4: 1 << 5,
        efer: 1 << 10
      ),
      rflags: .reset,
      currentPrivilegeLevel: 0,
      mode: .protected32
    )
    let translated = try DoryX86PagingUnit().translate(
      linearAddress: linear,
      access: .instructionFetch,
      context: context,
      physicalMemory: memory
    )
    #expect(translated.physicalAddress == 0x8123)
  }

  private func longModeContext(cpl: UInt8) -> DoryX86PagingContext {
    .init(control: longModeControl(), rflags: .reset, currentPrivilegeLevel: cpl, mode: .long64)
  }

  private func longModeControl() -> DoryX86ControlState {
    .init(
      cr0: 0x8001_0011,
      cr3: 0x1000,
      cr4: 1 << 5,
      efer: (1 << 10) | (1 << 11)
    )
  }

  private func installFourLevelMapping(
    linear: UInt64,
    physicalPage: UInt64,
    flags: UInt64,
    memory: DoryX86ByteArrayMemory
  ) throws {
    let pml4Index = (linear >> 39) & 0x1ff
    let pdptIndex = (linear >> 30) & 0x1ff
    let pdIndex = (linear >> 21) & 0x1ff
    let ptIndex = (linear >> 12) & 0x1ff
    try write64(memory, 0x1000 + pml4Index * 8, 0x2000 | 0x7)
    try write64(memory, 0x2000 + pdptIndex * 8, 0x3000 | 0x7)
    try write64(memory, 0x3000 + pdIndex * 8, 0x4000 | 0x7)
    try write64(memory, 0x4000 + ptIndex * 8, physicalPage | flags)
  }

  private func write64(_ memory: DoryX86ByteArrayMemory, _ address: UInt64, _ value: UInt64) throws
  {
    try memory.write(
      at: address, bytes: (0..<8).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) })
  }

  private func write32(_ memory: DoryX86ByteArrayMemory, _ address: UInt64, _ value: UInt32) throws
  {
    try memory.write(
      at: address, bytes: (0..<4).map { UInt8(truncatingIfNeeded: value >> UInt32($0 * 8)) })
  }

  private func read64(_ memory: DoryX86ByteArrayMemory, _ address: UInt64) throws -> UInt64 {
    try memory.read(at: address, byteCount: 8).enumerated().reduce(0) {
      $0 | UInt64($1.element) << UInt64($1.offset * 8)
    }
  }
}
