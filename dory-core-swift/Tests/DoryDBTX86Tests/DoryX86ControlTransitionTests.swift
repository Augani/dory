import Testing

@testable import DoryDBTX86

// Intel SDM 092 Vol. 2B MOV CR (4-32–34), Vol. 3A §§5.1.2, 5.1.4, 5.10.1:
// https://cdrdv2-public.intel.com/922481/253667-092-sdm-vol-2b.pdf
// https://cdrdv2-public.intel.com/922487/253668-092-sdm-vol-3a.pdf
// These cases qualify bounded transitions, not the complete CR4 feature set.
@Suite struct DoryX86ControlTransitionTests {
  @Test func cr0LowReservedBitsAreIgnoredAndETIsFixedWhileHighBitsFault() throws {
    let defined: UInt64 = 0xE005_003F
    for bit in 0..<32 where defined & (UInt64(1) << bit) == 0 {
      var state = try makeState()
      try writeControl(0, value: 1 | (UInt64(1) << bit), state: &state)
      #expect(state.control.cr0 == 0x11)
    }
    var allDefined = try makeState()
    try writeControl(0, value: defined, state: &allDefined)
    #expect(allDefined.control.cr0 == defined)
    for bit in [32, 40, 63] {
      var state = try makeState(activeLong: true, mode: .long64)
      try rejectControl(0, value: state.control.cr0 | (UInt64(1) << bit),
        state: &state, mode: .long64)
    }
    // Outside 64-bit mode MOV CR always takes a 32-bit source, including with 66.
    for mode: DoryX86ExecutionMode in [.real16, .protected16, .protected32] {
      var state = try makeState(mode: mode)
      try writeControl(0, value: (1 << 40) | 1, state: &state, mode: mode, prefix: [0x66])
      #expect(state.control.cr0 == 0x11)
    }
  }

  @Test func cr0InvalidPEPagingAndCacheCombinationsDoNotPublishOrInvalidate() throws {
    for value: UInt64 in [0x8000_0010, 0x2000_0011] {
      var state = try makeState()
      try rejectControl(0, value: value, state: &state)
    }
  }

  @Test func enablingPCIDERequiresActiveIA32eAndZeroLowCR3Bits() throws {
    for controls: DoryX86ControlState in [
      .init(cr0: 0x11, cr3: 0x4000),
      .init(cr0: 0x8000_0011, cr3: 0x4000),
      .init(cr0: 0x11, cr3: 0x2000, cr4: 1 << 5, efer: 1 << 8),
    ] {
      var state = try makeState()
      state.control = controls
      try rejectControl(4, value: controls.cr4 | (1 << 17), state: &state)
    }
    for mode: DoryX86ExecutionMode in [.protected32, .long64] {
      for low: UInt64 in [1, 8, 16, 0xFFF] {
        var state = try makeState(activeLong: true, mode: mode)
        state.control.cr3 |= low
        try rejectControl(4, value: state.control.cr4 | (1 << 17), state: &state, mode: mode)
      }
    }
  }

  @Test func existingPCIDCanBeRewrittenAndNoFlushCR3DoesNotStoreBit63() throws {
    for mode: DoryX86ExecutionMode in [.protected32, .long64] {
      var state = try makeState(activeLong: true, mode: mode)
      try writeControl(4, value: state.control.cr4 | (1 << 17), state: &state, mode: mode)
      #expect(state.control.cr4 & (1 << 17) != 0)
      state.rip = 0x1000
      state.control.cr3 |= 0xABC
      try writeControl(4, value: state.control.cr4, state: &state, mode: mode)
      #expect(state.control.cr3 == 0x2ABC)
      state.rip = 0x1000
      try writeControl(4, value: state.control.cr4 & ~(1 << 17), state: &state, mode: mode)
      #expect(state.control.cr3 == 0x2ABC)
    }
    var state = try makeState(activeLong: true, mode: .long64)
    state.control.cr4 |= 1 << 17
    try writeControl(3, value: (1 << 63) | 0x2123, state: &state,
      mode: .long64, expectInvalidation: false)
    #expect(state.control.cr3 == 0x2123)
    state.rip = 0x1000
    try writeControl(3, value: 0x2456, state: &state, mode: .long64)
    #expect(state.control.cr3 == 0x2456)
    state.rip = 0x1000
    state.control.cr4 &= ~(1 << 17)
    try rejectControl(3, value: (1 << 63) | 0x2000, state: &state, mode: .long64)
  }

  @Test func leavingIA32eRequiresCompatibilityCodeAndDisabledPCID() throws {
    var long = try makeState(activeLong: true, mode: .long64)
    try rejectControl(0, value: 0x11, state: &long, mode: .long64)
    var compatibilityPCID = try makeState(activeLong: true)
    compatibilityPCID.control.cr4 |= 1 << 17
    try rejectControl(0, value: 0x11, state: &compatibilityPCID)
    var compatibility = try makeState(activeLong: true)
    try writeControl(0, value: 0x11, state: &compatibility)
    #expect(compatibility.control.cr0 == 0x11)
    #expect(compatibility.control.efer == 1 << 8)
    #expect(compatibility.control.cr4 == 1 << 5)
    for mode: DoryX86ExecutionMode in [.protected32, .long64] {
      var state = try makeState(activeLong: true, mode: mode)
      try rejectControl(4, value: 0, state: &state, mode: mode)
    }
  }

  @Test func enteringIA32eChecksPAECodeSegmentAndTaskTypeBeforePublishing() throws {
    for invalidField in 0..<4 {
      var state = try makeState()
      state.control.cr3 = 0x2000
      state.control.cr4 = 1 << 5
      state.control.efer = 1 << 8
      switch invalidField {
      case 0: state.control.cr4 = 0
      case 1: state.cs.attributes |= 1 << 13
      case 2: state.tr.attributes = 0x81
      default: state.tr.attributes = 0x83
      }
      try rejectControl(0, value: 0x8000_0011, state: &state)
    }
    var unsupported = try makeState()
    unsupported.control.cr3 = 0x2000
    unsupported.control.cr4 = 1 << 5
    unsupported.control.efer = 1 << 8
    try rejectControl(0, value: 0x8000_0011, state: &unsupported,
      profile: profile(removing: .longMode))
  }

  @Test func protectedBootPreparationUsesTheQualifiedPagingFeatureSet() throws {
    // A normal protected-mode boot preparation sequence: install the long-mode
    // root, select PAE and kernel control mechanisms, set EFER, then enable PG.
    var state = try makeState()
    state.control.cr3 = 0x2000
    let bootCR4: UInt64 = (1 << 4) | (1 << 5) | (1 << 7) | (1 << 9) | (1 << 10)
    try writeControl(4, value: bootCR4, state: &state)
    state.rip = 0x1000
    try writeEFER(0x901, state: &state)
    state.rip = 0x1000
    try writeControl(0, value: 0x8000_0011, state: &state)
    #expect(state.control.efer == 0xD01)
    #expect(state.control.cr4 == bootCR4)
    #expect(state.control.legacyPAEPDPTEs == nil)
    let leaf = DoryX86CPUProfile.compatibleV1.cpuid(leaf: 1)
    #expect(leaf.edx & ((1 << 3) | (1 << 6) | (1 << 13))
      == (1 << 3) | (1 << 6) | (1 << 13)) // PSE, PAE, PGE.
    #expect(leaf.edx & (1 << 16) == 0) // PAT remains unadvertised.
    #expect(leaf.ecx & (1 << 17) == 0) // PCID remains unadvertised.
  }

  @Test func eferWritableFeaturesFollowTheSelectedProfile() throws {
    for (feature, bit): (DoryX86Feature, Int) in [
      (.syscall, 0), (.longMode, 8), (.executeDisable, 11),
    ] {
      let profile = profile(removing: feature)
      var state = try makeState()
      try rejectEFER(UInt64(1) << bit, state: &state, profile: profile)
      try writeEFER(0, state: &state, profile: profile)
      #expect(state.control.efer == 0)
      var enabled = try makeState()
      try writeEFER(UInt64(1) << bit, state: &enabled)
      #expect(enabled.control.efer == UInt64(1) << bit)
    }
  }

  @Test func cr4ReservedBitsAndOSXSAVEPolicyFaultBeforePublishing() throws {
    let mechanisms: UInt64 = (1 << 2) | (1 << 3) | (1 << 4) | (1 << 5) | (1 << 6)
      | (1 << 7) | (1 << 8) | (1 << 9) | (1 << 10) | (1 << 17) | (1 << 20) | (1 << 21)
    for bit in 0..<64 where mechanisms & (UInt64(1) << bit) == 0 {
      var state = try makeState(activeLong: true, mode: .long64)
      try rejectControl(4, value: state.control.cr4 | (UInt64(1) << bit),
        state: &state, mode: .long64)
    }
    let baseline = DoryX86CPUProfile.compatibleV1
    let publicRequest = DoryX86CPUProfile(identifier: "control-transition-public-xsave-request",
      features: baseline.features.union([.xsave, .osxsave, .avx]),
      physicalAddressBits: baseline.physicalAddressBits,
      linearAddressBits: baseline.linearAddressBits,
      virtualTSCFrequencyHz: baseline.virtualTSCFrequencyHz)
    var publicState = try makeState(activeLong: true, mode: .long64)
    try rejectControl(4, value: publicState.control.cr4 | (1 << 18), state: &publicState,
      mode: .long64, profile: publicRequest)

    let xsave = DoryX86CPUProfile(identifier: "control-transition-xsave",
      features: baseline.features.union([.xsave]), physicalAddressBits: baseline.physicalAddressBits,
      linearAddressBits: baseline.linearAddressBits, virtualTSCFrequencyHz: baseline.virtualTSCFrequencyHz,
      allowingUnqualifiedSIMDAndExtendedState: true)
    var state = try makeState(activeLong: true, mode: .long64)
    try writeControl(4, value: state.control.cr4 | (1 << 18), state: &state,
      mode: .long64, profile: xsave)
    #expect(state.control.cr4 & (1 << 18) != 0)
  }

  @Test func eferRejectsReservedBitsAndPagingLMEChangesWithoutInvalidation() throws {
    for bit in 0..<64 where ![0, 8, 10, 11].contains(bit) {
      var state = try makeState()
      try rejectEFER(UInt64(1) << bit, state: &state)
    }
    var legacy = try makeState()
    legacy.control.cr0 |= 1 << 31
    try rejectEFER(1 << 8, state: &legacy)
    var active = try makeState(activeLong: true)
    try rejectEFER(1 << 10, state: &active)
    // Preserve the existing Dory LMA write policy pending a separate vendor contract.
    try rejectEFER(1 << 8, state: &active)
    var inactive = try makeState()
    try rejectEFER(1 << 10, state: &inactive)
  }

  @Test func eferInvalidationReachesAnOnlySuppliedTranslatedMemory() throws {
    var state = try makeState(activeLong: true, mode: .long64)
    for value: UInt64 in [0xD00, 0x500] {
      state.rip = 0x1000
      try writeEFER(value, state: &state, mode: .long64, translatedOnly: true)
      #expect(state.control.efer == value)
    }
    state.rip = 0x1000
    try rejectEFER(state.control.efer | (1 << 12), state: &state,
      mode: .long64, translatedOnly: true)
  }

  private func makeState(activeLong: Bool = false,
    mode: DoryX86ExecutionMode = .protected32) throws -> DoryX86ArchitecturalState {
    try .init(rip: 0x1000,
      cs: .init(selector: 0, attributes: mode == .long64 ? 0xA09B : 0xC09B, limit: .max),
      tr: .init(attributes: 0x8B),
      control: .init(cr0: activeLong ? 0x8000_0011 : 0x11,
        cr3: activeLong ? 0x2000 : 0x4000, cr4: activeLong ? 1 << 5 : 0,
        efer: activeLong ? 0x500 : 0))
  }

  private func profile(removing feature: DoryX86Feature) -> DoryX86CPUProfile {
    let baseline = DoryX86CPUProfile.compatibleV1
    return .init(identifier: "control-transition-test", features: baseline.features.subtracting([feature]),
      physicalAddressBits: baseline.physicalAddressBits, linearAddressBits: baseline.linearAddressBits,
      virtualTSCFrequencyHz: baseline.virtualTSCFrequencyHz)
  }

  private func writeControl(_ index: UInt8, value: UInt64,
    state: inout DoryX86ArchitecturalState, mode: DoryX86ExecutionMode = .protected32,
    profile: DoryX86CPUProfile = .compatibleV1,
    prefix: [UInt8] = [], expectInvalidation: Bool = true) throws {
    state.registers.rax = value
    try execute(prefix + [0x0F, 0x22, 0xC0 | (index << 3)], state: &state, mode: mode,
      profile: profile, success: true, expectInvalidation: expectInvalidation)
  }

  private func rejectControl(_ index: UInt8, value: UInt64,
    state: inout DoryX86ArchitecturalState, mode: DoryX86ExecutionMode = .protected32,
    profile: DoryX86CPUProfile = .compatibleV1) throws {
    state.registers.rax = value
    try execute([0x0F, 0x22, 0xC0 | (index << 3)], state: &state, mode: mode,
      profile: profile, success: false)
  }

  private func writeEFER(_ value: UInt64, state: inout DoryX86ArchitecturalState,
    mode: DoryX86ExecutionMode = .protected32, profile: DoryX86CPUProfile = .compatibleV1,
    translatedOnly: Bool = false) throws {
    try accessEFER(value, state: &state, mode: mode, profile: profile,
      translatedOnly: translatedOnly, success: true)
  }

  private func rejectEFER(_ value: UInt64, state: inout DoryX86ArchitecturalState,
    mode: DoryX86ExecutionMode = .protected32, profile: DoryX86CPUProfile = .compatibleV1,
    translatedOnly: Bool = false) throws {
    try accessEFER(value, state: &state, mode: mode, profile: profile,
      translatedOnly: translatedOnly, success: false)
  }

  private func accessEFER(_ value: UInt64, state: inout DoryX86ArchitecturalState,
    mode: DoryX86ExecutionMode, profile: DoryX86CPUProfile, translatedOnly: Bool,
    success: Bool) throws {
    state.registers.rcx = 0xC000_0080
    state.registers.rax = value & 0xFFFF_FFFF
    state.registers.rdx = value >> 32
    try execute([0x0F, 0x30], state: &state, mode: mode, profile: profile,
      translatedOnly: translatedOnly, success: success)
  }

  private func execute(_ code: [UInt8], state: inout DoryX86ArchitecturalState,
    mode: DoryX86ExecutionMode, profile: DoryX86CPUProfile = .compatibleV1,
    translatedOnly: Bool = false, success: Bool, expectInvalidation: Bool = true) throws {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x10000)
    try memory.write(at: 0x1000, bytes: code)
    let wide = state.control.efer & 0x500 != 0 || state.control.cr4 & (1 << 5) != 0
    try memory.writeScalar(at: 0x2000, value: 0x3003, byteCount: 8)
    try memory.writeScalar(at: 0x3000, value: 0x4003, byteCount: 8)
    try memory.writeScalar(at: 0x4000, value: 0x5003, byteCount: wide ? 8 : 4)
    for page in 0..<16 {
      try memory.writeScalar(at: 0x5000 + UInt64(page * (wide ? 8 : 4)),
        value: UInt64(page * 0x1000) | 3, byteCount: wide ? 8 : 4)
    }
    let paging = DoryX86PagingUnit(physicalAddressBits: profile.physicalAddressBits)
    // For an unpaged instruction, warm an unrelated valid paging context so a
    // failed control write must still preserve an observable preexisting cache.
    var primeState = state
    if state.control.cr0 & (1 << 31) == 0 {
      primeState.control = .init(cr0: 0x8000_0011, cr3: wide ? 0x2000 : 0x4000,
        cr4: wide ? 1 << 5 : 0, efer: wide ? 0x500 : 0)
    }
    for (address, access): (UInt64, DoryX86MemoryAccessKind) in [
      (0x1000, .instructionFetch), (0x6000, .read),
    ] {
      _ = try paging.translate(linearAddress: address, access: access,
        context: .init(state: primeState, mode: mode), physicalMemory: memory)
    }
    let cacheCount = paging.cachedTranslationCount
    #expect(cacheCount == 2)
    let before = state
    let bytes = memory.snapshot()
    let translated = translatedOnly ? DoryX86TranslatedMemory(physicalMemory: memory,
      pagingUnit: paging, context: .init(state: state, mode: mode)) : nil
    let result = DoryX86Interpreter(profile: profile).step(state: &state, memory: memory,
      mode: mode, pagingUnit: translatedOnly ? nil : paging, translatedMemory: translated)
    if success {
      let decoded = try DoryX86Decoder().decode(code, at: before.rip, mode: mode)
      #expect(result == .retired(decoded))
      #expect(paging.cachedTranslationCount == (expectInvalidation ? 0 : cacheCount))
    } else {
      #expect(result == .exception(.init(kind: .generalProtection, vector: 13,
        errorCode: 0, instructionPointer: before.rip)))
      #expect(state == before)
      #expect(memory.snapshot() == bytes)
      #expect(paging.cachedTranslationCount == cacheCount)
    }
  }
}
