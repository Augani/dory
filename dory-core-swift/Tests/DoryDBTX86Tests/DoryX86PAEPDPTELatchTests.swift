import Foundation
import Testing

@testable import DoryDBTX86

// Intel SDM revision 092 Vol. 3A §5.4.1/Table 5-8 and Vol. 2B MOV to/from CR:
// https://cdrdv2-public.intel.com/922487/253668-092-sdm-vol-3a.pdf
// https://cdrdv2-public.intel.com/922481/253667-092-sdm-vol-2b.pdf
// This is a bounded legacy PAE mechanism corpus, not PAE feature qualification.
@Suite struct DoryX86PAEPDPTELatchTests {
  private let root: UInt64 = 0x1020
  private let code: UInt64 = 0x8000

  @Test func movCR3LoadsAllFourSelectorsFromEach32ByteAlignedRoot() throws {
    for root: UInt64 in [0x1020, 0x17e0, 0x1fe0] {
      for ignoredLow: UInt64 in [0, 1, 0x1f] {
        let memory = try fixture(register: 3)
        let entries = DoryX86PAEPDPTEs(0x2e19, 0x3e19, 0x4e19, 0x5e19)
        for selector in 0..<4 {
          try memory.writeScalar(at: root + UInt64(selector) * 8,
            value: entries[selector], byteCount: 8)
          try memory.writeScalar(at: 0x2000 + UInt64(selector) * 0x1000,
            value: UInt64(selector) * 0x20_0000 | 0xa3, byteCount: 8)
        }
        var state = try state(value: root | ignoredLow)
        let paging = DoryX86PagingUnit()
        try expectRetired(&state, memory: memory, paging: paging)
        #expect(state.control.cr3 == root | ignoredLow)
        #expect(state.control.legacyPAEPDPTEs == entries)
        #expect(paging.cachedTranslationCount == 0)
        for selector in 0..<4 {
          let linear = UInt64(selector) << 30 | 0x123
          let translation = try paging.translate(linearAddress: linear, access: .read,
            context: .init(state: state, mode: .protected32), physicalMemory: memory)
          #expect(translation.physicalAddress == UInt64(selector) * 0x20_0000 | 0x123)
          #expect(try memory.readScalar(at: root + UInt64(selector) * 8, byteCount: 8)
            == entries[selector])
        }
      }
    }
  }

  @Test func everyPresentReservedBitAndSelectorFaultBeforePublishingOrInvalidating() throws {
    let reservedBits = [1, 2, 5, 6, 7, 8] + Array(40...63)
    for register: UInt8 in [0, 3, 4] {
      for selector in 0..<4 {
        for bit in reservedBits {
          let memory = try fixture(register: register)
          try memory.writeScalar(at: root + UInt64(selector) * 8,
            value: 0x2001 | (UInt64(1) << bit), byteCount: 8)
          let value: UInt64 = register == 0 ? 0xc000_0011 : (register == 3 ? root : 0x30)
          var state = try state(value: value)
          // NXE never permits NX in the legacy PDPTE registers.
          state.control.efer = 1 << 11
          let paging = DoryX86PagingUnit()
          try prime(paging, state: state, memory: memory)
          let before = state
          let bytes = memory.snapshot()
          let cacheCount = paging.cachedTranslationCount
          #expect(DoryX86Interpreter().step(state: &state, memory: memory,
            mode: .protected32, pagingUnit: paging) == fault(at: code))
          #expect(state == before)
          #expect(memory.snapshot() == bytes)
          #expect(paging.cachedTranslationCount == cacheCount)
        }
      }
    }
  }

  @Test func reservedValidationUsesEachCPUPhysicalAddressWidth() throws {
    for width: UInt8 in [32, 40, 52] {
      for bit in Int(width)..<64 {
        let latch = DoryX86PAEPDPTEs(0, 0, 0, (UInt64(1) << bit) | 1)
        #expect(throws: DoryX86StateError.invalidLegacyPAEPDPTE(index: 3, value: latch[3])) {
          try latch.validate(physicalAddressBits: width)
        }
      }
      try DoryX86PAEPDPTEs((UInt64(1) << (width - 1)) | 0xe19)
        .validate(physicalAddressBits: width)
    }
  }

  @Test func invalidPhysicalWidthsThrowRatherThanTrapEvenForInactivePaging() throws {
    for width: UInt8 in [0, 31, 53, 255] {
      let error = DoryX86StateError.invalidPhysicalAddressBits(width)
      #expect(throws: error) {
        try DoryX86PAEPDPTEs().validate(physicalAddressBits: width)
      }
      #expect(throws: error) {
        try DoryX86ControlState().validateLegacyPAEPDPTEs(physicalAddressBits: width)
      }
      let active = try state(value: root)
      #expect(throws: error) {
        try active.control.validateLegacyPAEPDPTEs(physicalAddressBits: width)
      }
    }
  }

  @Test func missingPhysicalEntryLeavesAllControlsLatchAndTLBIntact() throws {
    for availableEntries in 0..<4 {
      let memory = try fixture(register: 3, byteCount: 0x9000 + availableEntries * 8)
      var state = try state(value: 0x9000)
      let paging = DoryX86PagingUnit()
      try prime(paging, state: state, memory: memory)
      let before = state
      let bytes = memory.snapshot()
      let cacheCount = paging.cachedTranslationCount
      #expect(DoryX86Interpreter().step(state: &state, memory: memory,
        mode: .protected32, pagingUnit: paging) == fault(at: code))
      #expect(state == before)
      #expect(memory.snapshot() == bytes)
      #expect(paging.cachedTranslationCount == cacheCount)
    }
  }

  @Test func nonpresentPDPTEsIgnoreAllOtherBitsAndFaultOnlyOnTranslation() throws {
    let memory = try fixture(register: 3)
    let absent = UInt64.max & ~1
    for selector in 0..<4 {
      try memory.writeScalar(at: root + UInt64(selector) * 8, value: absent, byteCount: 8)
    }
    var state = try state(value: root)
    let paging = DoryX86PagingUnit()
    try expectRetired(&state, memory: memory, paging: paging)
    #expect(state.control.legacyPAEPDPTEs == .init(absent, absent, absent, absent))
    for selector in 0..<4 {
      let linear = UInt64(selector) << 30 | 0x123
      #expect(throws: DoryX86MemoryError.pageFault(address: linear, errorCode: 0)) {
        try paging.translate(linearAddress: linear, access: .read,
          context: .init(state: state, mode: .protected32), physicalMemory: memory)
      }
    }
  }

  @Test func RAMChangesStayInvisibleAcrossInvalidationUntilSameCR3IsReloaded() throws {
    let memory = try fixture(register: 3)
    var state = try state(value: root)
    let paging = DoryX86PagingUnit()
    try expectRetired(&state, memory: memory, paging: paging)
    try memory.writeScalar(at: root, value: 0x3001, byteCount: 8)
    try memory.writeScalar(at: 0x3000, value: 0x20_00a3, byteCount: 8)
    for invalidateAll in [false, true] {
      if invalidateAll { paging.invalidateAll() } else { paging.invalidate(linearAddress: 0x123) }
      let translation = try paging.translate(linearAddress: 0x123, access: .read,
        context: .init(state: state, mode: .protected32), physicalMemory: memory)
      #expect(translation.physicalAddress == 0x123)
    }
    state.rip = code
    try expectRetired(&state, memory: memory, paging: paging)
    #expect(state.control.legacyPAEPDPTEs == .init(0x3001))
    let translation = try paging.translate(linearAddress: 0x123, access: .read,
      context: .init(state: state, mode: .protected32), physicalMemory: memory)
    #expect(translation.physicalAddress == 0x20_0123)
  }

  @Test func latchValuesParticipateInTLBIdentityEvenWithIdenticalControls() throws {
    let memory = try fixture(register: 3)
    try memory.writeScalar(at: 0x3000, value: 0x20_00a3, byteCount: 8)
    let first = try state(value: root)
    var second = first
    second.control.legacyPAEPDPTEs = .init(0x3001)
    let paging = DoryX86PagingUnit()
    for state in [first, second, first, second] {
      let translation = try paging.translate(linearAddress: 0x123, access: .read,
        context: .init(state: state, mode: .protected32), physicalMemory: memory)
      #expect(translation.physicalAddress == (state == first ? 0x123 : 0x20_0123))
    }
    #expect(paging.cachedTranslationCount == 2)
  }

  @Test func onlySpecifiedCR0AndCR4ChangesReloadWhileLegacyPAEIsActive() throws {
    let cases: [(UInt8, UInt64, UInt64, Bool)] = [
      (0, 0x8000_0011, 1 << 30, true), // CD
      (0, 0xc000_0011, 1 << 29, true), // NW, with CD already set
      (0, 0x8000_0011, 1 << 16, false), // WP
      (0, 0x8000_0011, 0, false),
      (4, 1 << 5, 1 << 4, true), // PSE
      (4, 1 << 5, 1 << 7, true), // PGE
      (4, 1 << 5, 1 << 20, true), // SMEP, explicitly listed in SDM 092
      (4, 1 << 5, 1 << 6, false), // MCE
      (4, 1 << 5, 0, false),
    ]
    for (register, original, toggle, reloads) in cases {
      let memory = try fixture(register: register)
      try memory.writeScalar(at: root, value: 0x3001, byteCount: 8)
      var state = try state(value: original ^ toggle)
      if register == 0 { state.control.cr0 = original } else { state.control.cr4 = original }
      try expectRetired(&state, memory: memory, paging: .init())
      #expect(state.control.legacyPAEPDPTEs == .init(reloads ? 0x3001 : 0x2001))
    }
  }

  @Test func enteringLegacyPAELoadsButLeavingOrInactiveWritesDoNotLoad() throws {
    for register: UInt8 in [0, 4] {
      let memory = try fixture(register: register)
      try memory.writeScalar(at: root, value: 0x3001, byteCount: 8)
      var state = try state(value: register == 0 ? 0x8000_0011 : 1 << 5)
      if register == 0 { state.control.cr0 &= ~(1 << 31) } else { state.control.cr4 = 0 }
      state.control.legacyPAEPDPTEs = nil
      // The old CR4=0 state uses legacy 32-bit paging, whose fixtures differ; use raw
      // instruction memory here so this test isolates the MOV-CR transition itself.
      try expectRetired(&state, memory: memory)
      #expect(state.control.isLegacyPAEPagingActive)
      #expect(state.control.legacyPAEPDPTEs == .init(0x3001))
    }
    for register: UInt8 in [0, 3, 4] {
      let memory = try fixture(register: register)
      var state = try state(value: register == 0 ? 0x11 : (register == 3 ? 0xFFFF_FFE0 : 0))
      if register == 3 { state.control.cr0 = 0x11 }
      state.control.cr3 = 0xFFFF_FFE0 // Not backed by this synthetic RAM.
      let latch = state.control.legacyPAEPDPTEs
      try expectRetired(&state, memory: memory)
      #expect(!state.control.isLegacyPAEPagingActive)
      #expect(state.control.legacyPAEPDPTEs == latch)
    }
  }

  @Test func loadsUseRawPhysicalMemoryAndInvalidateAnExplicitTranslatedMemoryCache() throws {
    let memory = try fixture(register: 3)
    // Only linear 0x4000 is mapped (to the instruction at physical 0x8000).
    // The physical PDPT at 0x1020 has no linear mapping.
    try memory.writeScalar(at: 0x2000, value: 0x3023, byteCount: 8)
    try memory.writeScalar(at: 0x3020, value: 0x8023, byteCount: 8)
    try memory.writeScalar(at: root, value: 0x4001, byteCount: 8)
    var state = try state(value: root)
    state.rip = 0x4000
    let paging = DoryX86PagingUnit()
    let translated = DoryX86TranslatedMemory(physicalMemory: memory, pagingUnit: paging,
      context: .init(state: state, mode: .protected32))
    #expect(try translated.instructionBytes(at: state.rip, maximumCount: 3) == [0x0F, 0x22, 0xD8])
    #expect(paging.cachedTranslationCount == 1)
    guard case .retired = DoryX86Interpreter().step(state: &state, memory: memory,
      mode: .protected32, translatedMemory: translated) else {
      Issue.record("PDPTE load incorrectly used a guest linear address")
      return
    }
    #expect(state.control.legacyPAEPDPTEs == .init(0x4001))
    #expect(paging.cachedTranslationCount == 0)
  }

  @Test func failedEntryIntoLegacyPAEPreservesThePreviousInactiveState() throws {
    for register: UInt8 in [0, 4] {
      let memory = try fixture(register: register)
      try memory.writeScalar(at: root + 24, value: (1 << 63) | 1, byteCount: 8)
      var state = try state(value: register == 0 ? 0x8000_0011 : 1 << 5)
      if register == 0 { state.control.cr0 = 0x11 } else { state.control.cr4 = 0 }
      state.control.legacyPAEPDPTEs = nil
      let before = state
      let bytes = memory.snapshot()
      #expect(DoryX86Interpreter().step(state: &state, memory: memory,
        mode: .protected32) == fault(at: code))
      #expect(state == before)
      #expect(memory.snapshot() == bytes)
    }
  }

  @Test func enteringIA32eDoesNotLoadLegacyPDPTEsAndCannotLeaveByClearingPAE() throws {
    let memory = try fixture(register: 0)
    var state = try state(value: 0x8000_0011)
    state.control.cr0 = 0x11
    state.control.cr3 = 0xFFFF_FFE0 // Deliberately absent RAM, irrelevant to legacy latch loading.
    state.control.efer = 1 << 8
    state.control.legacyPAEPDPTEs = nil
    try expectRetired(&state, memory: memory)
    #expect(state.control.efer & (1 << 10) != 0)
    #expect(state.control.legacyPAEPDPTEs == nil)
    try memory.write(at: code, bytes: [0x0F, 0x22, 0xE0])
    state.rip = code
    state.registers.rax = 0
    let before = state
    #expect(DoryX86Interpreter().step(state: &state, memory: memory,
      mode: .protected32) == fault(at: code))
    #expect(state == before)
  }

  @Test func resetSnapshotOmitsLatchAndActiveSnapshotsRequireAllFourValidEntries() throws {
    let encoded = try JSONEncoder().encode(DoryX86ArchitecturalState.reset())
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let controls = try #require(object["control"] as? [String: Any])
    #expect(controls["legacyPAEPDPTEs"] == nil)
    #expect(try JSONDecoder().decode(DoryX86ArchitecturalState.self, from: encoded) == .reset())

    let valid = try state(value: root)
    let validJSON = try JSONEncoder().encode(valid)
    #expect(try JSONDecoder().decode(DoryX86ArchitecturalState.self, from: validJSON) == valid)
    var invalid = valid
    invalid.control.legacyPAEPDPTEs = nil
    #expect(throws: DoryX86StateError.missingLegacyPAEPDPTEs) {
      try DoryX86ArchitecturalState(control: invalid.control)
    }
    #expect(throws: DoryX86StateError.missingLegacyPAEPDPTEs) {
      try JSONDecoder().decode(DoryX86ArchitecturalState.self, from: JSONEncoder().encode(invalid))
    }
    invalid.control.legacyPAEPDPTEs = .init(0x2001, 0, 0, (1 << 63) | 1)
    #expect(throws: DoryX86StateError.invalidLegacyPAEPDPTE(index: 3, value: (1 << 63) | 1)) {
      try JSONDecoder().decode(DoryX86ArchitecturalState.self, from: JSONEncoder().encode(invalid))
    }
    var truncated = try #require(JSONSerialization.jsonObject(with: validJSON) as? [String: Any])
    var truncatedControls = try #require(truncated["control"] as? [String: Any])
    truncatedControls["legacyPAEPDPTEs"] = ["pdpte0": 0x2001, "pdpte1": 0, "pdpte2": 0]
    truncated["control"] = truncatedControls
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(DoryX86ArchitecturalState.self,
        from: JSONSerialization.data(withJSONObject: truncated))
    }
  }

  @Test func mutatedMissingOrProfileInvalidLatchRejectsExecutionBeforeMemoryAccess() throws {
    let memory = try fixture(register: 3)
    for latch: DoryX86PAEPDPTEs? in [nil, .init((1 << 40) | 1)] {
      var state = try state(value: root)
      state.control.legacyPAEPDPTEs = latch
      let before = state
      let bytes = memory.snapshot()
      let paging = DoryX86PagingUnit()
      for usePaging in [false, true] {
        #expect(DoryX86Interpreter().step(state: &state, memory: memory,
          mode: .protected32, pagingUnit: usePaging ? paging : nil) == fault(at: code))
        #expect(state == before)
        #expect(memory.snapshot() == bytes)
        #expect(paging.cachedTranslationCount == 0)
      }
      #expect(throws: (any Error).self) {
        try paging.translate(linearAddress: 0x123, access: .read,
          context: .init(state: state, mode: .protected32), physicalMemory: memory)
      }
    }
  }

  private func fixture(register: UInt8, byteCount: Int = 0x10000) throws -> DoryX86ByteArrayMemory {
    let memory = DoryX86ByteArrayMemory(byteCount: byteCount)
    try memory.write(at: code, bytes: [0x0F, 0x22, 0xC0 | (register << 3)])
    try memory.writeScalar(at: root, value: 0x2001, byteCount: 8)
    try memory.writeScalar(at: 0x2000, value: 0xa3, byteCount: 8) // Supervisor 2 MiB identity mapping.
    return memory
  }

  private func state(value: UInt64) throws -> DoryX86ArchitecturalState {
    try .init(registers: .init(rax: value), rip: code,
      cs: .init(selector: 0, attributes: 0xC09B, limit: .max),
      control: .init(cr0: 0x8000_0011, cr3: root, cr4: 1 << 5,
        legacyPAEPDPTEs: .init(0x2001)))
  }

  private func prime(_ paging: DoryX86PagingUnit, state: DoryX86ArchitecturalState,
    memory: DoryX86ByteArrayMemory) throws {
    for (linear, access): (UInt64, DoryX86MemoryAccessKind) in [(code, .instructionFetch), (0x123, .read)] {
      _ = try paging.translate(linearAddress: linear, access: access,
        context: .init(state: state, mode: .protected32), physicalMemory: memory)
    }
  }

  private func expectRetired(_ state: inout DoryX86ArchitecturalState,
    memory: DoryX86ByteArrayMemory, paging: DoryX86PagingUnit? = nil) throws {
    guard case .retired = DoryX86Interpreter().step(state: &state, memory: memory,
      mode: .protected32, pagingUnit: paging) else {
      Issue.record("Valid PAE control-register load did not retire")
      return
    }
  }

  private func fault(at rip: UInt64) -> DoryX86InterpreterResult {
    .exception(.init(kind: .generalProtection, vector: 13, errorCode: 0, instructionPointer: rip))
  }
}
