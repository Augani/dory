import Foundation
import Testing

@testable import DoryDBTX86

@Suite struct DoryX86SavedControlContractTests {
  @Test(arguments: [DoryX86CPUIdentity.legacyDoryV1, .intelCompatibleV1])
  func constructorRejectsEveryUnimplementedCR4Bit(identity: DoryX86CPUIdentity) throws {
    let profile = try DoryX86ProfileRegistry.resolve(.baselineV1, identity: identity)
    let allowed = profile.cpuProfile.implementedCR4Mask
    for bit in 0..<64 where allowed & (UInt64(1) << bit) == 0 && bit != 18 {
      var state = DoryX86ArchitecturalState.reset()
      state.control.cr4 = allowed | (UInt64(1) << bit)
      #expect(throws: DoryX86SavedStateError.cr4OutsideExecutionContract(
        value: state.control.cr4, allowed: allowed)) {
        try DoryX86SavedStateEnvelope(state: state, resolvedProfile: profile)
      }
    }
  }

  @Test(arguments: [DoryX86CPUIdentity.legacyDoryV1, .intelCompatibleV1])
  func correctlyFingerprintedDecodeCannotBypassInstructionAdmission(
    identity: DoryX86CPUIdentity
  ) throws {
    let profile = try DoryX86ProfileRegistry.resolve(.baselineV1, identity: identity)
    let envelope = try DoryX86SavedStateEnvelope(state: .reset(), resolvedProfile: profile)
    let original = try #require(JSONSerialization.jsonObject(
      with: JSONEncoder().encode(envelope)) as? [String: Any])
    let allowed = profile.cpuProfile.implementedCR4Mask
    for bit in 0..<64 where allowed & (UInt64(1) << bit) == 0 && bit != 18 {
      var document = original
      var state = try #require(document["architecturalState"] as? [String: Any])
      var control = try #require(state["control"] as? [String: Any])
      let value = allowed | (UInt64(1) << bit)
      control["cr4"] = value
      state["control"] = control
      document["architecturalState"] = state
      // Keep the exact valid registry identity and fingerprint: only restored
      // architectural controls are hostile, including PCIDE and SMAP.
      #expect(document["profileFingerprint"] as? String == profile.fingerprint)
      #expect(throws: DoryX86SavedStateError.cr4OutsideExecutionContract(
        value: value, allowed: allowed)) {
        try JSONDecoder().decode(DoryX86SavedStateEnvelope.self,
          from: JSONSerialization.data(withJSONObject: document))
      }
    }
  }

  @Test func exactLegacyMigrationDoesNotEnablePCIDOrSMAP() throws {
    for identifier in [DoryX86CPUProfile.compatibleV1Identifier,
      DoryX86CPUProfile.intelCompatibleV1Identifier]
    {
      let resolved = try DoryX86ProfileRegistry.migrateLegacyCompatibilityIdentifier(identifier)
      for bit in [17, 21] {
        var state = DoryX86ArchitecturalState.reset()
        state.control.cr4 = UInt64(1) << bit
        #expect(throws: DoryX86SavedStateError.cr4OutsideExecutionContract(
          value: state.control.cr4, allowed: resolved.cpuProfile.implementedCR4Mask)) {
          try DoryX86SavedStateEnvelope.migrateLegacy(
            state: state, profileIdentifier: identifier)
        }
      }
    }
  }

  @Test(arguments: [DoryX86CPUIdentity.legacyDoryV1, .intelCompatibleV1])
  func previouslyImplementedMechanismsRoundTripWithoutChangingProfileIdentity(
    identity: DoryX86CPUIdentity
  ) throws {
    let profile = try DoryX86ProfileRegistry.resolve(.baselineV1, identity: identity)
    // The shared mask exactly preserves the prior MOV CR4 contract. In
    // particular, independently testable SMEP remains admitted here without
    // claiming CPUID qualification, and OSXSAVE/PCIDE/SMAP remain unavailable.
    let priorMask: UInt64 = (1 << 2) | (1 << 3) | (1 << 4) | (1 << 5) | (1 << 6)
      | (1 << 7) | (1 << 8) | (1 << 9) | (1 << 10) | (1 << 20)
    #expect(profile.cpuProfile.implementedCR4Mask == priorMask)
    var state = DoryX86ArchitecturalState.reset()
    state.control.cr4 = priorMask
    let envelope = try DoryX86SavedStateEnvelope(state: state, resolvedProfile: profile)
    let decoded = try JSONDecoder().decode(DoryX86SavedStateEnvelope.self,
      from: JSONEncoder().encode(envelope))
    #expect(decoded.profileFingerprint == profile.fingerprint)
    #expect(try decoded.restore(using: profile) == state)
    #expect(profile.cpuProfile.cpuid(leaf: 1).ecx & (1 << 17) == 0)
    #expect(profile.cpuProfile.cpuid(leaf: 7, subleaf: 0).ebx & (1 << 20) == 0)
  }

  @Test func existingOSXSAVERejectionKeepsItsTypedError() throws {
    let profile = try DoryX86ProfileRegistry.resolve(.baselineV1)
    var state = DoryX86ArchitecturalState.reset()
    state.control.cr4 = (1 << 18) | (1 << 21)
    #expect(throws: DoryX86SavedStateError.osxsaveEnabledOutsideProfile(
      cr4: state.control.cr4)) {
      try DoryX86SavedStateEnvelope(state: state, resolvedProfile: profile)
    }
  }

  @Test(arguments: [DoryX86CPUIdentity.legacyDoryV1, .intelCompatibleV1])
  func storedCR0RejectsReservedBitsAndImpossibleConfigurations(
    identity: DoryX86CPUIdentity
  ) throws {
    let profile = try DoryX86ProfileRegistry.resolve(.baselineV1, identity: identity)
    // Independent literal from the existing MOV CR0 stored-bit contract. Low
    // reserved inputs are ignored live; they can never appear in stored CR0.
    let storedMask: UInt64 = 0xE005_003F
    #expect(DoryX86CPUProfile.implementedCR0Mask == storedMask)
    for bit in 0..<64 where storedMask & (UInt64(1) << bit) == 0 {
      var state = DoryX86ArchitecturalState.reset()
      state.control.cr0 |= UInt64(1) << bit
      try expectRejectedAtEveryEnvelopeBoundary(state, profile: profile,
        error: DoryX86SavedStateError.cr0OutsideExecutionContract(
          value: state.control.cr0, allowed: storedMask))
    }
    // ET cleared; PG without PE; NW without CD. Each bit is individually
    // supported, but the live writer rejects/fixes these combinations.
    for value: UInt64 in [0x6000_0000, 0x8000_0010, 0x2000_0011] {
      var state = DoryX86ArchitecturalState.reset()
      state.control.cr0 = value
      try expectRejectedAtEveryEnvelopeBoundary(state, profile: profile,
        error: DoryX86SavedStateError.invalidCR0Configuration(value: value))
    }
  }

  @Test(arguments: [DoryX86CPUIdentity.legacyDoryV1, .intelCompatibleV1])
  func unsupportedEFERBitsCannotEnterThroughSaveDecodeOrMigration(
    identity: DoryX86CPUIdentity
  ) throws {
    let profile = try DoryX86ProfileRegistry.resolve(.baselineV1, identity: identity)
    let storedMask: UInt64 = 0xD01 // SCE, LME, derived LMA, NXE.
    #expect(profile.cpuProfile.implementedEFERWritableMask == 0x901)
    for bit in 0..<64 where storedMask & (UInt64(1) << bit) == 0 {
      var state = DoryX86ArchitecturalState.reset()
      state.control.efer = UInt64(1) << bit
      try expectRejectedAtEveryEnvelopeBoundary(state, profile: profile,
        error: DoryX86SavedStateError.eferOutsideExecutionContract(
          value: state.control.efer, allowed: storedMask))
    }
  }

  @Test(arguments: [DoryX86CPUIdentity.legacyDoryV1, .intelCompatibleV1])
  func derivedLongModeCannotDisagreeWithPagingLMEOrPAE(
    identity: DoryX86CPUIdentity
  ) throws {
    let profile = try DoryX86ProfileRegistry.resolve(.baselineV1, identity: identity)
    let contradictions: [(cr0: UInt64, cr4: UInt64, efer: UInt64)] = [
      (0x6000_0010, 0, 0x400), // LMA without LME or PG.
      (0x6000_0010, 0x20, 0x500), // LME+LMA without PG.
      (0x8000_0011, 0, 0x100), // PG+LME without derived LMA.
      (0x8000_0011, 0, 0x500), // Active IA-32e without PAE.
      (0x8000_0011, 0x20, 0x400), // Active IA-32e without LME.
    ]
    for controls in contradictions {
      var state = DoryX86ArchitecturalState.reset()
      state.control = .init(cr0: controls.cr0, cr4: controls.cr4, efer: controls.efer)
      try expectRejectedAtEveryEnvelopeBoundary(state, profile: profile,
        error: DoryX86SavedStateError.inconsistentLongMode(
          cr0: controls.cr0, cr4: controls.cr4, efer: controls.efer))
    }
  }

  @Test(arguments: [DoryX86CPUIdentity.legacyDoryV1, .intelCompatibleV1])
  func previouslyValidStoredModesRoundTripWithoutSilentNormalization(
    identity: DoryX86CPUIdentity
  ) throws {
    let profile = try DoryX86ProfileRegistry.resolve(.baselineV1, identity: identity)
    let controls: [DoryX86ControlState] = [
      .init(), // Reset.
      .init(cr0: 0x11, efer: 1), // Protected mode with SYSCALL selected.
      .init(cr0: 0x11, cr4: 0x20, efer: 0x901), // Preparing long mode before PG.
      .init(cr0: 0x8000_0011), // Legacy non-PAE paging.
      .init(cr0: 0x8000_0011, cr4: 0x20, efer: 0x800,
        legacyPAEPDPTEs: .init(0, 0, 0, 0)), // Latched legacy PAE + NXE.
      .init(cr0: 0x8000_0011, cr4: 0x20, efer: 0xD01), // Active IA-32e.
      .init(cr0: 0xE005_003F), // Every implemented stored CR0 bit.
    ]
    for control in controls {
      var state = DoryX86ArchitecturalState.reset()
      state.control = control
      // Preserve the existing baseline SSE XSTATE snapshot compatibility.
      state.control.xcr0 = 3
      let envelope = try DoryX86SavedStateEnvelope(state: state, resolvedProfile: profile)
      let decoded = try JSONDecoder().decode(DoryX86SavedStateEnvelope.self,
        from: JSONEncoder().encode(envelope))
      #expect(decoded.architecturalState == state)
      #expect(try decoded.restore(using: profile) == state)
      #expect(try DoryX86SavedStateEnvelope.migrateLegacy(
        state: state, profileIdentifier: profile.cpuProfile.identifier) == envelope)
      #expect(decoded.profileFingerprint == profile.fingerprint)
    }
  }

  @Test(arguments: [DoryX86CPUIdentity.legacyDoryV1, .intelCompatibleV1])
  func mutatedXCR0CannotBypassExistingShapeValidationAtSaveOrMigration(
    identity: DoryX86CPUIdentity
  ) throws {
    let profile = try DoryX86ProfileRegistry.resolve(.baselineV1, identity: identity)
    for value: UInt64 in [0, 2] {
      var state = DoryX86ArchitecturalState.reset()
      // Mutation is public: unlike architectural construction/decode, the old
      // envelope constructor only checked that these fit the profile bitmask.
      state.control.xcr0 = value
      try expectRejectedAtEveryEnvelopeBoundary(state, profile: profile,
        error: DoryX86StateError.invalidXCR0(value))
    }
  }

  @Test(arguments: [DoryX86CPUIdentity.legacyDoryV1, .intelCompatibleV1])
  func earlierProfileAndXSTATEErrorsKeepPrecedenceOverNewControlChecks(
    identity: DoryX86CPUIdentity
  ) throws {
    let profile = try DoryX86ProfileRegistry.resolve(.baselineV1, identity: identity)
    var invalid = DoryX86ArchitecturalState.reset()
    invalid.control.cr0 |= 1 << 40
    invalid.control.efer = 1 << 12
    invalid.control.cr4 = (1 << 18) | (1 << 21)
    try expectRejectedAtEveryEnvelopeBoundary(invalid, profile: profile,
      error: DoryX86SavedStateError.osxsaveEnabledOutsideProfile(cr4: invalid.control.cr4))
    invalid.control.cr4 = 1 << 21
    try expectRejectedAtEveryEnvelopeBoundary(invalid, profile: profile,
      error: DoryX86SavedStateError.cr4OutsideExecutionContract(
        value: invalid.control.cr4, allowed: profile.cpuProfile.implementedCR4Mask))
    invalid.control.cr4 = 0
    invalid.control.xcr0 = 7
    try expectRejectedAtEveryEnvelopeBoundary(invalid, profile: profile,
      error: DoryX86SavedStateError.xcr0OutsideProfile(value: 7, allowed: 3))
    invalid.control.xcr0 = 0
    try expectRejectedAtEveryEnvelopeBoundary(invalid, profile: profile,
      error: DoryX86StateError.invalidXCR0(0))

    // Envelope identity errors still win over newly rejected CR0/EFER values
    // when the generic architectural payload itself remains decodable.
    invalid.control.xcr0 = 1
    var document = try envelopeDocument(containing: invalid, profile: profile)
    document["profileFingerprint"] = "0000000000000000"
    #expect(throws: DoryX86SavedStateError.profileFingerprintMismatch(
      expected: profile.fingerprint, actual: "0000000000000000")) {
      try JSONDecoder().decode(DoryX86SavedStateEnvelope.self,
        from: JSONSerialization.data(withJSONObject: document))
    }
    document["formatVersion"] = 2
    #expect(throws: DoryX86SavedStateError.unsupportedFormatVersion(2)) {
      try JSONDecoder().decode(DoryX86SavedStateEnvelope.self,
        from: JSONSerialization.data(withJSONObject: document))
    }
  }

  private func expectRejectedAtEveryEnvelopeBoundary<E: Error & Equatable>(
    _ state: DoryX86ArchitecturalState, profile: DoryX86ResolvedCPUProfile,
    error: E
  ) throws {
    #expect(throws: error) {
      try DoryX86SavedStateEnvelope(state: state, resolvedProfile: profile)
    }
    #expect(throws: error) {
      try DoryX86SavedStateEnvelope.migrateLegacy(
        state: state, profileIdentifier: profile.cpuProfile.identifier)
    }
    let document = try envelopeDocument(containing: state, profile: profile)
    #expect(throws: error) {
      try JSONDecoder().decode(DoryX86SavedStateEnvelope.self,
        from: JSONSerialization.data(withJSONObject: document))
    }
  }

  private func envelopeDocument(
    containing state: DoryX86ArchitecturalState, profile: DoryX86ResolvedCPUProfile
  ) throws -> [String: Any] {
    let original = try DoryX86SavedStateEnvelope(state: .reset(), resolvedProfile: profile)
    var document = try #require(JSONSerialization.jsonObject(
      with: JSONEncoder().encode(original)) as? [String: Any])
    document["architecturalState"] = try JSONSerialization.jsonObject(
      with: JSONEncoder().encode(state))
    return document
  }
}
