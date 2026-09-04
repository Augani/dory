import Testing

@testable import DoryDBTX86

// Intel SDM 325462/253668-092 Vol. 3A §5.5.3 and §5.5.5:
// https://cdrdv2-public.intel.com/922487/253668-092-sdm-vol-3a.pdf
// A present PDPTE.PS is reserved if CPUID.80000001H:EDX.Page1GB is clear.
@Suite struct DoryX86PagingFeatureTests {
  @Test func absentOneGiBFeatureFaultsBeforeLeafAccessedDirtyOrTranslationPublication() throws {
    for cpl: UInt8 in [0, 3] {
      for access: DoryX86MemoryAccessKind in [.read, .write, .instructionFetch] {
        let memory = try memory()
        let paging = DoryX86PagingUnit()
        let context = context(cpl: cpl, supportsOneGiBPages: false)
        let before = memory.snapshot()
        let code: UInt32 = 9 | (cpl == 3 ? 4 : 0)
          | (access == .write ? 2 : 0) | (access == .instructionFetch ? 16 : 0)
        for _ in 0..<2 {
          #expect(throws: DoryX86MemoryError.pageFault(address: 0x8123, errorCode: code)) {
            try paging.translate(linearAddress: 0x8123, access: access,
              context: context, physicalMemory: memory)
          }
          #expect(memory.snapshot() == before)
          #expect(paging.cachedTranslationCount == 0)
        }
      }
    }
  }

  @Test func absentEntriesKeepNonpresentFaultPriorityOverTheUnsupportedPSBit() throws {
    for access: DoryX86MemoryAccessKind in [.read, .write, .instructionFetch] {
      let memory = try memory()
      // P=0, PS=1 and other reserved address bits are not inspected.
      try memory.writeScalar(at: 0x2000, value: 0x000F_FFFF_FFFF_FF86, byteCount: 8)
      let before = memory.snapshot()
      let code: UInt32 = 4 | (access == .write ? 2 : 0)
        | (access == .instructionFetch ? 16 : 0)
      #expect(throws: DoryX86MemoryError.pageFault(address: 0x8123, errorCode: code)) {
        try DoryX86PagingUnit().translate(linearAddress: 0x8123, access: access,
          context: context(cpl: 3, supportsOneGiBPages: false), physicalMemory: memory)
      }
      #expect(memory.snapshot() == before)
    }
  }

  @Test func enabledOneGiBAndProfilelessContextsRetainPATAndAccessedDirtySemantics() throws {
    for profile in [DoryX86CPUProfile.compatibleV1, .intelCompatibleV1] {
      let memory = try memory()
      try memory.writeScalar(at: 0x2000, value: 0x4000_1087, byteCount: 8)
      let state = try state()
      let context = DoryX86PagingContext(state: state, mode: .long64, profile: profile)
      #expect(context.supportsOneGiBPages)
      #expect(DoryX86PagingContext(state: state, mode: .long64).supportsOneGiBPages)
      #expect(self.context(cpl: 3).supportsOneGiBPages)
      let result = try DoryX86PagingUnit().translate(linearAddress: 0x8123,
        access: .write, context: context, physicalMemory: memory)
      #expect(result.physicalAddress == 0x4000_8123)
      #expect(result.pageSize == 1 << 30)
      #expect(try memory.readScalar(at: 0x2000, byteCount: 8) == 0x4000_10E7)
    }
  }

  @Test func maskingOneGiBDoesNotDisableTwoMiBPagesOrFourKiBPAT() throws {
    for huge in [false, true] {
      let memory = try memory()
      try memory.writeScalar(at: 0x2000, value: 0x3007, byteCount: 8)
      try memory.writeScalar(at: 0x3000, value: huge ? 0x1087 : 0x4007, byteCount: 8)
      try memory.writeScalar(at: 0x4040, value: 0x8087, byteCount: 8) // PTE.PAT=1.
      let result = try DoryX86PagingUnit().translate(linearAddress: 0x8123,
        access: .write, context: context(cpl: 3, supportsOneGiBPages: false),
        physicalMemory: memory)
      #expect(result.physicalAddress == 0x8123)
      #expect(result.pageSize == (huge ? 1 << 21 : 1 << 12))
      #expect(try memory.readScalar(at: huge ? 0x3000 : 0x4040, byteCount: 8)
        == (huge ? 0x10E7 : 0x80E7))
    }
  }

  @Test func profileMaskCannotReuseRecentOrDictionaryTLBEntries() throws {
    let memory = try memory()
    let paging = DoryX86PagingUnit()
    for access: DoryX86MemoryAccessKind in [.read, .write, .instructionFetch] {
      // Two slots exercise both the hot entry and an older dictionary entry.
      for address: UInt64 in [0x8000, 0x9000] {
        _ = try paging.translate(linearAddress: address, access: access,
          context: context(cpl: 3), physicalMemory: memory)
      }
      let before = memory.snapshot()
      for address: UInt64 in [0x9000, 0x8000] {
        let code: UInt32 = 13 | (access == .write ? 2 : 0)
          | (access == .instructionFetch ? 16 : 0)
        #expect(throws: DoryX86MemoryError.pageFault(address: address, errorCode: code)) {
          try paging.translate(linearAddress: address, access: access,
            context: context(cpl: 3, supportsOneGiBPages: false), physicalMemory: memory)
        }
        #expect(memory.snapshot() == before)
        #expect(try paging.translate(linearAddress: address, access: access,
          context: context(cpl: 3), physicalMemory: memory).physicalAddress == address)
      }
    }
    #expect(paging.cachedTranslationCount == 6)
  }

  @Test func implicitSupervisorViewsPreserveTheSelectedPagingCapability() throws {
    let physical = try memory()
    let translated = DoryX86TranslatedMemory(physicalMemory: physical,
      pagingUnit: DoryX86PagingUnit(),
      context: context(cpl: 3, supportsOneGiBPages: false))
    let before = physical.snapshot()
    #expect(throws: DoryX86MemoryError.pageFault(address: 0x8000, errorCode: 9)) {
      try translated.readImplicitSupervisor(at: 0x8000, byteCount: 8)
    }
    let supervisor = translated.implicitSupervisorMemory()
    #expect(throws: DoryX86MemoryError.pageFault(address: 0x8000, errorCode: 9)) {
      try supervisor.read(at: 0x8000, byteCount: 8)
    }
    #expect(throws: DoryX86MemoryError.pageFault(address: 0x8000, errorCode: 11)) {
      try supervisor.validateWrite(at: 0x8000, byteCount: 8)
    }
    #expect(throws: DoryX86MemoryError.pageFault(address: 0x8000, errorCode: 11)) {
      try supervisor.write(at: 0x8000, bytes: [1])
    }
    #expect(throws: DoryX86MemoryError.pageFault(address: 0x8000, errorCode: 13)) {
      try translated.read(at: 0x8000, byteCount: 8)
    }
    #expect(physical.snapshot() == before)
  }

  @Test func interpreterSuppliesItsProfileToNewAndPreviouslyWarmedTranslationContexts() throws {
    for suppliedView in [false, true] {
      let physical = try memory()
      var state = try state()
      let paging = DoryX86PagingUnit()
      let translated = DoryX86TranslatedMemory(physicalMemory: physical, pagingUnit: paging,
        context: .init(state: state, mode: .long64))
      #expect(try translated.instructionBytes(at: state.rip, maximumCount: 3) == [0x48, 0xFF, 0x03])
      let before = state
      let snapshot = physical.snapshot()
      let result = DoryX86Interpreter(profile: maskedProfile).step(state: &state,
        memory: physical, mode: .long64, pagingUnit: paging,
        translatedMemory: suppliedView ? translated : nil)
      #expect(result == fetchFault())
      var expected = before
      expected.control.cr2 = 0x8000
      #expect(state == expected)
      #expect(physical.snapshot() == snapshot)
    }
  }

  @Test func bothNativeTiersDeclineUnsupportedHugePageFetchWithoutStoresBeforePreciseFault() throws {
    #if arch(arm64)
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let physical = try memory()
        var state = try state()
        let paging = DoryX86PagingUnit()
        let translated = DoryX86TranslatedMemory(physicalMemory: physical, pagingUnit: paging,
          context: .init(state: state, mode: .long64, profile: maskedProfile))
        let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 16384, optimization: optimization)
        let before = state
        let snapshot = physical.snapshot()
        #expect(try executor.executeSummary(
          byteProvider: { try translated.instructionBytes(at: 0x8000, maximumCount: $0) },
          codeGenerationProvider: { try translated.codeGeneration(at: 0x8000, byteCount: $0) },
          at: 0x8000, mode: .long64, addressSpaceID: 0x1000, maximumInstructions: 4,
          state: &state, memory: translated) == nil)
        #expect(try executor.executeChainedSummary(
          byteProvider: { try translated.instructionBytes(at: $0, maximumCount: $1) },
          codeGenerationProvider: { try translated.codeGeneration(at: $0, byteCount: $1) },
          at: 0x8000, mode: .long64, addressSpaceID: 0x1000, maximumInstructions: 4,
          state: &state, memory: translated) == nil)
        #expect(state == before && physical.snapshot() == snapshot)
        #expect(executor.diagnostics.chainedRetiredInstructions == 0)
        #expect(executor.diagnostics.negativeEntryCount == 0)
        #expect(paging.cachedTranslationCount == 0)
        #expect(DoryX86Interpreter(profile: maskedProfile).step(state: &state,
          memory: physical, mode: .long64, translatedMemory: translated) == fetchFault())
        var expected = before
        expected.control.cr2 = 0x8000
        #expect(state == expected && physical.snapshot() == snapshot)
      }
    #endif
  }

  @Test func interruptDeliveryAndReturnPreserveTheSelectedProfileForTablesAndStacks() throws {
    let delivery = DoryX86InterruptDelivery(profile: maskedProfile)
    do {
      let physical = try memory()
      var state = try state()
      state.idtr = .init(limit: 0xFFF, base: 0x6000)
      let before = state
      let snapshot = physical.snapshot()
      #expect(throws: DoryX86MemoryError.pageFault(address: 0x6100, errorCode: 9)) {
        try delivery.deliver(vector: 16, source: .hardwareException, state: &state,
          physicalMemory: physical, pagingUnit: DoryX86PagingUnit(), mode: .long64)
      }
      #expect(state == before && physical.snapshot() == snapshot)
    }
    for isReturn in [false, true] {
      let physical = try interruptMemory()
      var state = try interruptState()
      let before = state
      let snapshot = physical.snapshot()
      let address = isReturn ? state.registers.rsp : state.registers.rsp - 8
      #expect(throws: DoryX86MemoryError.pageFault(address: address, errorCode: isReturn ? 9 : 11)) {
        if isReturn {
          try delivery.interruptReturn(state: &state, physicalMemory: physical,
            pagingUnit: DoryX86PagingUnit(), mode: .long64)
        } else {
          try delivery.deliver(vector: 16, source: .hardwareException, state: &state,
            physicalMemory: physical, pagingUnit: DoryX86PagingUnit(), mode: .long64)
        }
      }
      #expect(state == before && physical.snapshot() == snapshot)
    }
  }

  @Test func interruptInstructionsReuseTheSuppliedTranslationUnitForStackPermissions() throws {
    for isReturn in [false, true] {
      for supportsOneGiBPages in [false, true] {
        let profile = supportsOneGiBPages ? DoryX86CPUProfile.compatibleV1 : maskedProfile
        let physical = try interruptMemory()
        let code: [UInt8] = isReturn ? [0x48, 0xCF] : [0xCD, 0x10]
        try physical.write(at: 0x8000, bytes: code)
        var state = try interruptState()
        let paging = DoryX86PagingUnit()
        let translated = DoryX86TranslatedMemory(physicalMemory: physical, pagingUnit: paging,
          context: .init(state: state, mode: .long64, profile: profile))
        let before = state
        let snapshot = physical.snapshot()
        let result = DoryX86Interpreter(profile: profile).step(state: &state,
          memory: physical, mode: .long64, translatedMemory: translated)
        if supportsOneGiBPages {
          let decoded = try DoryX86Decoder().decode(code, at: before.rip, mode: .long64)
          #expect(result == .retired(decoded))
          #expect(state.rip == 0x8000)
          #expect(state.registers.rsp == (isReturn ? 0xA000 : 0x4000_8FD8))
        } else {
          // The existing INT/IRET wrapper collapses delivery failures to #GP;
          // precise delivery-fault propagation remains open in this tranche.
          #expect(result == .exception(.init(kind: .generalProtection, vector: 13,
            errorCode: 0, instructionPointer: before.rip)))
          #expect(state == before && physical.snapshot() == snapshot)
        }
      }
    }
  }

  private func interruptMemory() throws -> DoryX86ByteArrayMemory {
    let physical = try memory()
    // Low 1 GiB uses a 2 MiB leaf. The next 1 GiB uses a huge leaf aliasing
    // physical RAM: GDT/IDT/code succeed, while only the high stack is rejected.
    try physical.writeScalar(at: 0x2000, value: 0x3027, byteCount: 8)
    try physical.writeScalar(at: 0x2008, value: 0x83, byteCount: 8)
    try physical.writeScalar(at: 0x3000, value: 0xA7, byteCount: 8)
    try physical.writeScalar(at: 0x5008, value: 0x00AF_9A00_0000_FFFF, byteCount: 8)
    try physical.writeScalar(at: 0x6100, value: 0x0000_8E00_0008_8000, byteCount: 8)
    try physical.writeScalar(at: 0x6108, value: 0, byteCount: 8)
    // The positive control must translate the high stack to this valid frame.
    let frame: [UInt64] = [0x8000, 8, 2, 0xA000, 16]
    for (index, value) in frame.enumerated() {
      try physical.writeScalar(at: 0x9000 + UInt64(index * 8), value: value, byteCount: 8)
    }
    return physical
  }

  private func interruptState() throws -> DoryX86ArchitecturalState {
    try .init(registers: .init(rsp: 0x4000_9000), rip: 0x8000,
      cs: .init(selector: 8, attributes: 0xA09B, limit: .max),
      ss: .init(selector: 16, attributes: 0xC093, limit: .max),
      gdtr: .init(limit: 0x17, base: 0x5000), idtr: .init(limit: 0xFFF, base: 0x6000),
      control: .init(cr0: 0x8001_0011, cr3: 0x1000, cr4: 1 << 5,
        efer: (1 << 10) | (1 << 11)))
  }

  private var maskedProfile: DoryX86CPUProfile {
    let base = DoryX86CPUProfile.compatibleV1
    return .init(identifier: "test.no-one-gib-pages", features: base.features.subtracting([.oneGiBPages]),
      physicalAddressBits: base.physicalAddressBits, linearAddressBits: base.linearAddressBits,
      virtualTSCFrequencyHz: base.virtualTSCFrequencyHz)
  }

  private func memory() throws -> DoryX86ByteArrayMemory {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x10000)
    // Ancestor A is already set; no effect on this entry is required on a leaf fault.
    try memory.writeScalar(at: 0x1000, value: 0x2027, byteCount: 8)
    try memory.writeScalar(at: 0x2000, value: 0x87, byteCount: 8)
    try memory.write(at: 0x8000, bytes: [0x48, 0xFF, 0x03]) // INC qword [RBX].
    try memory.writeScalar(at: 0x9000, value: 41, byteCount: 8)
    return memory
  }

  private func context(cpl: UInt8, supportsOneGiBPages: Bool = true) -> DoryX86PagingContext {
    .init(control: .init(cr0: 0x8001_0011, cr3: 0x1000, cr4: 1 << 5,
      efer: (1 << 10) | (1 << 11)), rflags: [.reservedOne], currentPrivilegeLevel: cpl,
      mode: .long64, supportsOneGiBPages: supportsOneGiBPages)
  }

  private func state() throws -> DoryX86ArchitecturalState {
    try .init(registers: .init(rbx: 0x9000), rip: 0x8000,
      cs: .init(selector: 3, attributes: 0xA0FB, limit: .max),
      control: .init(cr0: 0x8001_0011, cr2: 0x1234, cr3: 0x1000, cr4: 1 << 5,
        efer: (1 << 10) | (1 << 11)))
  }

  private func fetchFault() -> DoryX86InterpreterResult {
    .exception(.init(kind: .pageFault, vector: 14, errorCode: 29,
      instructionPointer: 0x8000, linearAddress: 0x8000))
  }
}
