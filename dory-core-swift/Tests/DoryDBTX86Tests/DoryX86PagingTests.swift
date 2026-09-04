import Foundation
import Testing

@testable import DoryDBTX86

@Suite struct DoryX86PagingTests {
  @Test func scalarMemoryUsesLittleEndianValuesWithoutWeakeningBounds() throws {
    let memory = DoryX86ByteArrayMemory(baseAddress: 0x1000, byteCount: 16)
    try memory.writeScalar(at: 0x1004, value: 0x8877_6655_4433_2211, byteCount: 8)
    #expect(try memory.readScalar(at: 0x1004, byteCount: 8) == 0x8877_6655_4433_2211)
    #expect(try memory.read(at: 0x1004, byteCount: 8) == [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88])
    #expect(throws: DoryX86MemoryError.self) {
      try memory.writeScalar(at: 0x100F, value: 1, byteCount: 2)
    }
    #expect(throws: DoryX86ScalarMemoryError.invalidByteCount(3)) {
      try memory.readScalar(at: 0x1000, byteCount: 3)
    }
  }

  @Test func memoryAccessKindsKeepStableWireValuesWithDistinctHotPathHashes() throws {
    let kinds: [DoryX86MemoryAccessKind] = [.instructionFetch, .read, .write]
    #expect(Set(kinds).count == 3)
    #expect(String(decoding: try JSONEncoder().encode(kinds), as: UTF8.self)
      == #"["instructionFetch","read","write"]"#)
  }

  @Test func codeGenerationsTrackOnlyTheTouchedBackingPages() throws {
    let memory = DoryX86ByteArrayMemory(baseAddress: 0x1000, byteCount: 0x3000)
    let first = try #require(try memory.codeGeneration(at: 0x1800, byteCount: 16))
    try memory.writeScalar(at: 0x3000, value: 1, byteCount: 1)
    #expect(try memory.codeGeneration(at: 0x1800, byteCount: 16) == first)
    try memory.writeScalar(at: 0x180F, value: 2, byteCount: 1)
    #expect(try memory.codeGeneration(at: 0x1800, byteCount: 16) != first)
  }

  @Test func translatedCodeGenerationsFollowPhysicalRemapsAndWrites() throws {
    let memory = DoryX86ByteArrayMemory(byteCount: 0x10_000)
    let linear: UInt64 = 0x0040_0000
    try installFourLevelMapping(
      linear: linear,
      physicalPage: 0x8000,
      flags: 0x7,
      memory: memory
    )
    let paging = DoryX86PagingUnit()
    let translated = DoryX86TranslatedMemory(
      physicalMemory: memory,
      pagingUnit: paging,
      context: longModeContext(cpl: 3)
    )
    let original = try #require(try translated.codeGeneration(at: linear, byteCount: 16))
    try memory.writeScalar(at: 0x9000, value: 1, byteCount: 1)
    #expect(try translated.codeGeneration(at: linear, byteCount: 16) == original)
    try memory.writeScalar(at: 0x8000, value: 2, byteCount: 1)
    #expect(try translated.codeGeneration(at: linear, byteCount: 16) != original)

    try write64(memory, 0x4000 + ((linear >> 12) & 0x1ff) * 8, 0x9000 | 0x7)
    paging.invalidate(linearAddress: linear)
    let remapped = try #require(try translated.codeGeneration(at: linear, byteCount: 16))
    #expect(remapped != original)
  }

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

  @Test func walksOneGiBPagesAdvertisedByTheCompatibleCPUProfile() throws {
    let memory = DoryX86ByteArrayMemory(byteCount: 0x10_000)
    let linear: UInt64 = 0x5234_5678
    try write64(memory, 0x1000, 0x2000 | 0x7)
    try write64(memory, 0x2000 + 8, 0x4000_0000 | 0x87)

    let translation = try DoryX86PagingUnit().translate(
      linearAddress: linear,
      access: .read,
      context: longModeContext(cpl: 3),
      physicalMemory: memory
    )

    #expect(DoryX86CPUProfile.compatibleV1.supports(.oneGiBPages))
    #expect(translation.physicalAddress == linear)
    #expect(translation.pageSize == 1 << 30)
    #expect(try read64(memory, 0x1000) & (1 << 5) != 0)
    #expect(try read64(memory, 0x2000 + 8) & (1 << 5) != 0)
  }

  @Test func fourKiBPATBitDoesNotSelectALargePage() throws {
    let memory = DoryX86ByteArrayMemory(byteCount: 0x10_000)
    let linear: UInt64 = 0x0040_0123
    try installFourLevelMapping(linear: linear, physicalPage: 0x98000, flags: 0x87, memory: memory)
    let translation = try DoryX86PagingUnit().translate(
      linearAddress: linear, access: .write, context: longModeContext(cpl: 3),
      physicalMemory: memory)

    #expect(translation.physicalAddress == 0x98123)
    #expect(translation.pageSize == 4096)
    #expect(try read64(memory, 0x4000) == 0x980e7)
  }

  @Test func largePagePATBitDoesNotContributeToThePhysicalAddress() throws {
    for pageSize: UInt64 in [1 << 21, 1 << 30] {
      let memory = DoryX86ByteArrayMemory(byteCount: 0x10_000)
      let linear = pageSize + 0x3123
      let physicalBase = pageSize * 2
      try installIA32eLargePage(
        linear: linear, physicalBase: physicalBase, pageSize: pageSize,
        flags: 0x1087, memory: memory)
      let translation = try DoryX86PagingUnit().translate(
        linearAddress: linear, access: .read, context: longModeContext(cpl: 3),
        physicalMemory: memory)
      #expect(translation.pageSize == pageSize)
      #expect(translation.physicalAddress == physicalBase + 0x3123)
    }
  }

  @Test func reservedPML4AndMisalignedLargePagesStillFault() throws {
    for reservedAtPML4 in [true, false] {
      let memory = DoryX86ByteArrayMemory(byteCount: 0x10_000)
      let linear: UInt64 = 0x0040_0123
      try installIA32eLargePage(
        linear: linear, physicalBase: 0, pageSize: 1 << 21, flags: 0x87, memory: memory)
      if reservedAtPML4 {
        try write64(memory, 0x1000, 0x2087)
      } else {
        try write64(memory, 0x3010, 0x2087) // Bit 13 is reserved in a 2 MiB PDE.
      }
      #expect(throws: DoryX86MemoryError.pageFault(address: linear, errorCode: 0xD)) {
        try DoryX86PagingUnit().translate(
          linearAddress: linear, access: .read, context: longModeContext(cpl: 3),
          physicalMemory: memory)
      }
    }
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

  @Test func pageFaultInstructionBitRequiresSMEPOrPAEWithNXE() throws {
    let memory = DoryX86ByteArrayMemory(byteCount: 0x2000)
    for pae in [false, true] {
      for nxe in [false, true] {
        for smep in [false, true] {
          for cpl: UInt8 in [0, 3] {
            let context = DoryX86PagingContext(
              control: .init(
                cr0: 0x8000_0011, cr3: 0x1000,
                cr4: (pae ? 1 << 5 : 0) | (smep ? 1 << 20 : 0),
                efer: nxe ? 1 << 11 : 0),
              rflags: .reset, currentPrivilegeLevel: cpl, mode: .protected32)
            for access: DoryX86MemoryAccessKind in [.read, .write, .instructionFetch] {
              var expected: UInt32 = cpl == 3 ? 4 : 0
              if access == .write { expected |= 2 }
              if access == .instructionFetch, smep || (pae && nxe) { expected |= 16 }
              #expect(throws: DoryX86MemoryError.pageFault(address: 0, errorCode: expected)) {
                try DoryX86PagingUnit().translate(
                  linearAddress: 0, access: access, context: context, physicalMemory: memory)
              }
            }
          }
        }
      }
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

  @Test func invalidationEvictsEveryCachedSliceOfALargePage() throws {
    for pageSize: UInt64 in [1 << 21, 1 << 30] {
      for global in [false, true] {
        let memory = DoryX86ByteArrayMemory(byteCount: 0x10_000)
        let linearBase = pageSize * 2
        let flags: UInt64 = global ? 0x187 : 0x87
        try installIA32eLargePage(
          linear: linearBase, physicalBase: 0, pageSize: pageSize, flags: flags, memory: memory)
        var control = longModeControl()
        control.cr4 |= 1 << 7
        let context = DoryX86PagingContext(
          control: control, rflags: .reset, currentPrivilegeLevel: 3, mode: .long64)
        let paging = DoryX86PagingUnit()
        let offsets: [UInt64] = [0x123, 0x3123, 0x7123]
        let accesses: [DoryX86MemoryAccessKind] = [.read, .write, .instructionFetch]
        for offset in offsets {
          for access in accesses {
            #expect(try paging.translate(
              linearAddress: linearBase + offset, access: access, context: context,
              physicalMemory: memory).physicalAddress == offset)
          }
        }
        #expect(paging.cachedTranslationCount == offsets.count * accesses.count)
        let physicalBase = pageSize * 3
        try installIA32eLargePage(
          linear: linearBase, physicalBase: physicalBase, pageSize: pageSize,
          flags: flags, memory: memory)

        // The addressed 4 KiB slice was never cached; sibling slices still belong
        // to the same architectural large-page translation and must be evicted.
        paging.invalidate(linearAddress: linearBase + 0x9123)
        #expect(paging.cachedTranslationCount == 0)
        // Check the last-used slices first to exercise the three hot lookup slots.
        for offset in offsets.reversed() {
          for access in accesses {
            #expect(try paging.translate(
              linearAddress: linearBase + offset, access: access, context: context,
              physicalMemory: memory).physicalAddress == physicalBase + offset)
          }
        }
      }
    }
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

  @Test func bulkFillStopsAtLinearPageBoundariesWithCompleteElements() throws {
    let memory = DoryX86ByteArrayMemory(byteCount: 0x10_000)
    let linear: UInt64 = 0x0040_0000
    try installFourLevelMapping(
      linear: linear, physicalPage: 0x8000, flags: 0x7, memory: memory)
    try installFourLevelMapping(
      linear: linear + 0x1000, physicalPage: 0x9000, flags: 0x7, memory: memory)
    let translated = DoryX86TranslatedMemory(
      physicalMemory: memory,
      pagingUnit: DoryX86PagingUnit(),
      context: longModeContext(cpl: 3)
    )
    let pattern: [UInt8] = [0x11, 0x22, 0x33, 0x44]

    #expect(
      try translated.fillRepeating(
        at: linear + 0xff8,
        pattern: pattern,
        maximumElementCount: 4
      ) == 2
    )
    #expect(try memory.read(at: 0x8ff8, byteCount: 8) == pattern + pattern)
    #expect(try memory.read(at: 0x9000, byteCount: 8) == [UInt8](repeating: 0, count: 8))

    #expect(
      try translated.fillRepeating(
        at: linear + 0x1000,
        pattern: pattern,
        maximumElementCount: 2
      ) == 2
    )
    #expect(try memory.read(at: 0x9000, byteCount: 8) == pattern + pattern)
  }

  @Test func translatedScalarAccessesCrossPagesPrecisely() throws {
    let memory = DoryX86ByteArrayMemory(byteCount: 0x10_000)
    let linear: UInt64 = 0x0040_0000
    try installFourLevelMapping(
      linear: linear, physicalPage: 0x8000, flags: 0x7, memory: memory)
    try installFourLevelMapping(
      linear: linear + 0x1000, physicalPage: 0x9000, flags: 0x7, memory: memory)
    let paging = DoryX86PagingUnit()
    let translated = DoryX86TranslatedMemory(
      physicalMemory: memory,
      pagingUnit: paging,
      context: longModeContext(cpl: 3)
    )

    try translated.writeScalar(
      at: linear + 0xFFC,
      value: 0x1122_3344_5566_7788,
      byteCount: 8
    )
    #expect(
      try translated.readScalar(at: linear + 0xFFC, byteCount: 8)
        == 0x1122_3344_5566_7788
    )
    #expect(try memory.read(at: 0x8FFC, byteCount: 4) == [0x88, 0x77, 0x66, 0x55])
    #expect(try memory.read(at: 0x9000, byteCount: 4) == [0x44, 0x33, 0x22, 0x11])

    try write64(memory, 0x4008, 0)
    paging.invalidate(linearAddress: linear + 0x1000)
    #expect(throws: DoryX86MemoryError.self) {
      try translated.writeScalar(
        at: linear + 0xFFC,
        value: 0xFFFF_EEEE_DDDD_CCCC,
        byteCount: 8
      )
    }
    #expect(try memory.read(at: 0x8FFC, byteCount: 4) == [0x88, 0x77, 0x66, 0x55])
  }

  @Test func walksPAELargePagesAndLegacyPageTables() throws {
    let paeMemory = DoryX86ByteArrayMemory(byteCount: 0x10_000)
    try write64(paeMemory, 0x1000, 0x2000 | 0x1)
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

  @Test func legacyPAEUsesAllCR3RootAddressBitsWithoutChangingPDPTEs() throws {
    for root: UInt64 in [0x1020, 0x17e0, 0x1fe0] {
      for quadrant: UInt64 in 0..<4 {
        let memory = DoryX86ByteArrayMemory(byteCount: 0x10_000)
        let linear = (quadrant << 30) | 0x0020_3123
        let pdpteAddress = root + quadrant * 8
        let pdpte: UInt64 = 0x2000 | 0xe19 // Present, PWT/PCD, ignored bits 11:9.
        try write64(memory, pdpteAddress, pdpte)
        try write64(memory, 0x2008, 0x3007)
        try write64(memory, 0x3018, 0x9087) // A 4 KiB PTE may also set PAT.
        let context = DoryX86PagingContext(
          control: .init(
            cr0: 0x8001_0011, cr3: (1 << 40) | root | 0x1f,
            cr4: 1 << 5, efer: 1 << 11),
          rflags: .reset, currentPrivilegeLevel: 3, mode: .protected32)
        let translation = try DoryX86PagingUnit().translate(
          linearAddress: linear, access: .write, context: context, physicalMemory: memory)

        #expect(translation.physicalAddress == 0x9123)
        #expect(translation.pageSize == 4096)
        #expect(translation.userAccessible && translation.writable && translation.executable)
        #expect(try read64(memory, pdpteAddress) == pdpte)
        #expect(try read64(memory, 0x2008) == 0x3027)
        #expect(try read64(memory, 0x3018) == 0x90e7)
      }
    }
  }

  @Test func legacyPAEPermissionsComeFromTheDirectoryAndLeaf() throws {
    let linear: UInt64 = 0x123
    for restrictedEntry: UInt64 in [0x2000, 0x3000] {
      for deniedFlag: UInt64 in [1 << 1, 1 << 2] {
        let memory = DoryX86ByteArrayMemory(byteCount: 0x10_000)
        try write64(memory, 0x1020, 0x2001)
        try write64(memory, 0x2000, 0x3007)
        try write64(memory, 0x3000, 0x9007)
        try write64(memory, restrictedEntry, try read64(memory, restrictedEntry) & ~deniedFlag)
        let context = DoryX86PagingContext(
          control: .init(cr0: 0x8001_0011, cr3: 0x1020, cr4: 1 << 5),
          rflags: .reset, currentPrivilegeLevel: 3, mode: .protected32)
        #expect(throws: DoryX86MemoryError.pageFault(address: linear, errorCode: 7)) {
          try DoryX86PagingUnit().translate(
            linearAddress: linear, access: .write, context: context, physicalMemory: memory)
        }
        #expect(try read64(memory, 0x1020) == 0x2001)
      }
    }
  }

  @Test func movCR3PreservesLegacyPAE32ByteRootAlignment() throws {
    let memory = DoryX86ByteArrayMemory(bytes: [0x0F, 0x22, 0xD8]) // MOV CR3,EAX
    for root: UInt64 in [0x1020, 0x17e0, 0x1fe0] {
      for ignoredBits: UInt64 in [0, 1, 0x1f] {
        let value = root | ignoredBits
        var state = try DoryX86ArchitecturalState(
          registers: .init(rax: value), rip: 0,
          cs: .init(selector: 0, attributes: 0xC09B, limit: .max),
          control: .init(cr0: 0x11, cr3: 0x8000, cr4: 1 << 5))
        guard case .retired = DoryX86Interpreter().step(
          state: &state, memory: memory, mode: .protected32)
        else {
          Issue.record("MOV CR3 rejected a valid legacy PAE root")
          continue
        }
        #expect(state.control.cr3 == value)
        #expect(state.rip == 3)
      }
    }
  }

  @Test func movCR3AcceptsIgnoredLowBitsWithoutChangingFourKiBRoots() throws {
    let instructionMemory = DoryX86ByteArrayMemory(bytes: [0x0F, 0x22, 0xD8])
    let linear: UInt64 = 0x0040_1123
    for mode: DoryX86ExecutionMode in [.protected32, .long64] {
      for ignoredBits: UInt64 in [0x21, 0x7ff] {
        let memory = DoryX86ByteArrayMemory(byteCount: 0x10_000)
        let control: DoryX86ControlState
        if mode == .long64 {
          try installFourLevelMapping(linear: linear, physicalPage: 0x8000, flags: 7, memory: memory)
          control = longModeControl()
        } else {
          try write32(memory, 0x1004, 0x2007)
          try write32(memory, 0x2004, 0x8007)
          control = .init(cr0: 0x8001_0011, cr3: 0x1000)
        }
        var state = try DoryX86ArchitecturalState(
          registers: .init(rax: 0x1000 | ignoredBits), rip: 0,
          cs: .init(selector: 0, attributes: mode == .long64 ? 0xA09B : 0xC09B, limit: .max),
          control: control)
        guard case .retired = DoryX86Interpreter().step(
          state: &state, memory: instructionMemory, mode: mode)
        else {
          Issue.record("MOV CR3 rejected ignored low bits")
          continue
        }
        let translation = try DoryX86PagingUnit().translate(
          linearAddress: linear, access: .read, context: .init(state: state, mode: mode),
          physicalMemory: memory)
        #expect(translation.pageSize == 4096)
        #expect(translation.physicalAddress == 0x8123)
      }
    }
  }

  @Test func movCR3RejectsReservedHighBitsAndNoFlushWithoutPCID() throws {
    let memory = DoryX86ByteArrayMemory(bytes: [0x0F, 0x22, 0xD8])
    for value: UInt64 in [1 << DoryX86CPUProfile.compatibleV1.physicalAddressBits, 1 << 63] {
      var state = try DoryX86ArchitecturalState(
        registers: .init(rax: value), rip: 0,
        cs: .init(selector: 0, attributes: 0xA09B, limit: .max), control: longModeControl())
      let before = state
      #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
        == .exception(.init(kind: .generalProtection, vector: 13, errorCode: 0, instructionPointer: 0)))
      #expect(state == before)
    }
  }

  @Test func legacyPDEPageSizeBitIsIgnoredWhenPSEIsClear() throws {
    for pse in [false, true] {
      let memory = DoryX86ByteArrayMemory(byteCount: 0x10_000)
      try write32(memory, 0x1004, pse ? 0x87 : 0x2087)
      try write32(memory, 0x2004, 0x9007)
      let context = DoryX86PagingContext(
        control: .init(cr0: 0x8001_0011, cr3: 0x1000, cr4: pse ? 1 << 4 : 0),
        rflags: .reset, currentPrivilegeLevel: 3, mode: .protected32)
      let translation = try DoryX86PagingUnit().translate(
        linearAddress: 0x0040_1234, access: .write, context: context, physicalMemory: memory)
      #expect(translation.pageSize == (pse ? 1 << 22 : 1 << 12))
      #expect(translation.physicalAddress == (pse ? 0x1234 : 0x9234))
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

  @Test func elementBulkCopyStopsBeforeAPageBoundaryWithoutPartialQwords() throws {
    let memory = DoryX86ByteArrayMemory(byteCount: 0x20_000)
    let source: UInt64 = 0x0040_0000
    let destination: UInt64 = 0x0050_0000
    try installFourLevelMapping(
      linear: source, physicalPage: 0x8000, flags: 0x7, memory: memory)
    try installFourLevelMapping(
      linear: destination, physicalPage: 0x9000, flags: 0x7, memory: memory)
    let translated = DoryX86TranslatedMemory(
      physicalMemory: memory,
      pagingUnit: DoryX86PagingUnit(),
      context: longModeContext(cpl: 3)
    )
    let payload = (0..<32).map(UInt8.init)
    try memory.write(at: 0x8ff0, bytes: payload)

    #expect(
      try translated.copyForwardNonoverlappingElements(
        from: source + 0xff0,
        to: destination + 0xff0,
        elementByteCount: 8,
        maximumElementCount: 4,
        excludingDestinationRanges: []
      ) == 2)
    #expect(try memory.read(at: 0x9ff0, byteCount: 16) == Array(payload.prefix(16)))

    let before = try memory.read(at: 0x9000, byteCount: 16)
    #expect(
      try translated.copyForwardNonoverlappingElements(
        from: source + 0xff9,
        to: destination,
        elementByteCount: 8,
        maximumElementCount: 1,
        excludingDestinationRanges: []
      ) == nil)
    #expect(try memory.read(at: 0x9000, byteCount: 16) == before)
  }

  @Test func elementBulkCopyRejectsPhysicalCodeAliasesBeforeMutation() throws {
    let memory = DoryX86ByteArrayMemory(byteCount: 0x20_000)
    let source: UInt64 = 0x0040_0000
    let destination: UInt64 = 0x0050_0000
    let codeAlias: UInt64 = 0x0060_0000
    try installFourLevelMapping(
      linear: source, physicalPage: 0x8000, flags: 0x7, memory: memory)
    try installFourLevelMapping(
      linear: destination, physicalPage: 0x9000, flags: 0x7, memory: memory)
    try installFourLevelMapping(
      linear: codeAlias, physicalPage: 0x9000, flags: 0x7, memory: memory)
    let translated = DoryX86TranslatedMemory(
      physicalMemory: memory,
      pagingUnit: DoryX86PagingUnit(),
      context: longModeContext(cpl: 3)
    )
    try memory.write(at: 0x8100, bytes: Array(0..<24))
    let before = try memory.read(at: 0x9100, byteCount: 24)

    #expect(
      try translated.copyForwardNonoverlappingElements(
        from: source + 0x100,
        to: destination + 0x100,
        elementByteCount: 8,
        maximumElementCount: 3,
        excludingDestinationRanges: [(codeAlias + 0x100)..<(codeAlias + 0x118)]
      ) == nil)
    #expect(try memory.read(at: 0x9100, byteCount: 24) == before)
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

  private func installIA32eLargePage(
    linear: UInt64,
    physicalBase: UInt64,
    pageSize: UInt64,
    flags: UInt64,
    memory: DoryX86ByteArrayMemory
  ) throws {
    try write64(memory, 0x1000 + ((linear >> 39) & 0x1ff) * 8, 0x2007)
    let pdpteAddress = 0x2000 + ((linear >> 30) & 0x1ff) * 8
    if pageSize == 1 << 30 {
      try write64(memory, pdpteAddress, physicalBase | flags)
    } else {
      try write64(memory, pdpteAddress, 0x3007)
      try write64(memory, 0x3000 + ((linear >> 21) & 0x1ff) * 8, physicalBase | flags)
    }
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
