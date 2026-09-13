import Foundation
import Testing

@testable import DoryDBTX86

@Suite struct DoryX86ProfileRegistryTests {
  @Test func baselineEnvelopeRoundTripsExtendedArchitecturalState() throws {
    let profile = try DoryX86ProfileRegistry.resolve(.baselineV1)
    var state = DoryX86ArchitecturalState.reset()
    state.control.xcr0 = 3
    state.floatingPoint.x87[0] = try .init(bytes: Array(0..<10), expectedByteCount: 10)
    state.floatingPoint.ymm[15] = try .init(bytes: Array(repeating: 0xa5, count: 32), expectedByteCount: 32)
    state.floatingPoint.mxcsr = 0x9fc0
    let envelope = try DoryX86SavedStateEnvelope(state: state, resolvedProfile: profile)
    let restored = try JSONDecoder().decode(
      DoryX86SavedStateEnvelope.self, from: JSONEncoder().encode(envelope))

    #expect(restored.resolvedProfileID == .baselineV1)
    #expect(try restored.restore(using: profile) == state)
    #expect(restored.architecturalState.floatingPoint.x87[0] == state.floatingPoint.x87[0])
    #expect(restored.architecturalState.floatingPoint.ymm[15] == state.floatingPoint.ymm[15])
    #expect(restored.architecturalState.floatingPoint.mxcsr == 0x9fc0)
  }

  @Test func exactLegacyMigrationPreservesDistinctCPUIdentities() throws {
    let state = DoryX86ArchitecturalState.reset()
    let dory = try DoryX86SavedStateEnvelope.migrateLegacy(
      state: state, profileIdentifier: DoryX86CPUProfile.compatibleV1Identifier)
    let intel = try DoryX86SavedStateEnvelope.migrateLegacy(
      state: state, profileIdentifier: DoryX86CPUProfile.intelCompatibleV1Identifier)

    #expect(dory.resolvedProfileID == .baselineV1)
    #expect(intel.resolvedProfileID == .baselineV1)
    #expect(dory.cpuIdentity == .legacyDoryV1)
    #expect(intel.cpuIdentity == .intelCompatibleV1)
    #expect(dory.profileFingerprint != intel.profileFingerprint)
    #expect(throws: DoryX86ProfileRegistryError.unsupportedLegacyProfileIdentifier("custom")) {
      try DoryX86SavedStateEnvelope.migrateLegacy(state: state, profileIdentifier: "custom")
    }
  }

  @Test func registryRejectsUnknownAndUnimplementedProfiles() {
    #expect(throws: DoryX86ProfileRegistryError.unknownProfileIdentifier("custom")) {
      try DoryX86ProfileRegistry.resolvePersistedIdentifier("custom", identity: .legacyDoryV1)
    }
    #expect(throws: DoryX86ProfileRegistryError.unimplementedProfile(.v2V1)) {
      try DoryX86ProfileRegistry.resolve(.v2V1)
    }
    #expect(throws: DoryX86ProfileRegistryError.unimplementedProfile(.v3V1)) {
      try DoryX86ProfileRegistry.resolve(.v3V1)
    }
  }

  @Test func decodeRejectsFutureFormatAndMutatedProfileFacts() throws {
    let profile = try DoryX86ProfileRegistry.resolve(.baselineV1)
    let envelope = try DoryX86SavedStateEnvelope(
      state: .reset(), resolvedProfile: profile)
    let encoded = try JSONEncoder().encode(envelope)
    let original = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

    var future = original
    future["formatVersion"] = 2
    #expect(throws: DoryX86SavedStateError.unsupportedFormatVersion(2)) {
      try JSONDecoder().decode(DoryX86SavedStateEnvelope.self,
        from: JSONSerialization.data(withJSONObject: future))
    }

    var badFingerprint = original
    badFingerprint["profileFingerprint"] = "0000000000000000"
    #expect(throws: DoryX86SavedStateError.profileFingerprintMismatch(
      expected: profile.fingerprint, actual: "0000000000000000")) {
      try JSONDecoder().decode(DoryX86SavedStateEnvelope.self,
        from: JSONSerialization.data(withJSONObject: badFingerprint))
    }

    var changedIdentity = original
    changedIdentity["cpuIdentity"] = DoryX86CPUIdentity.intelCompatibleV1.rawValue
    #expect(throws: DoryX86SavedStateError.profileFingerprintMismatch(
      expected: try DoryX86ProfileRegistry.resolve(.baselineV1, identity: .intelCompatibleV1).fingerprint,
      actual: profile.fingerprint)) {
      try JSONDecoder().decode(DoryX86SavedStateEnvelope.self,
        from: JSONSerialization.data(withJSONObject: changedIdentity))
    }

    var unknown = original
    unknown["resolvedProfileID"] = "dory.x86_64.custom@1"
    #expect(throws: DoryX86ProfileRegistryError.unknownProfileIdentifier("dory.x86_64.custom@1")) {
      try JSONDecoder().decode(DoryX86SavedStateEnvelope.self,
        from: JSONSerialization.data(withJSONObject: unknown))
    }
  }

  @Test func envelopeRejectsXCR0OutsideResolvedProfile() throws {
    let profile = try DoryX86ProfileRegistry.resolve(.baselineV1)
    var state = DoryX86ArchitecturalState.reset()
    state.control.xcr0 = 7
    #expect(throws: DoryX86SavedStateError.xcr0OutsideProfile(value: 7, allowed: 3)) {
      try DoryX86SavedStateEnvelope(state: state, resolvedProfile: profile)
    }
  }

  @Test func restoreRejectsDifferentFrozenCPUIdentity() throws {
    let dory = try DoryX86ProfileRegistry.resolve(.baselineV1, identity: .legacyDoryV1)
    let intel = try DoryX86ProfileRegistry.resolve(.baselineV1, identity: .intelCompatibleV1)
    let envelope = try DoryX86SavedStateEnvelope(state: .reset(), resolvedProfile: dory)
    #expect(throws: DoryX86SavedStateError.cpuIdentityMismatch(
      expected: .intelCompatibleV1, actual: .legacyDoryV1)) {
      try envelope.restore(using: intel)
    }
  }
}
