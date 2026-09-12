import Foundation
import Testing

@testable import DoryDBTX86

// A03.5: Freeze profile promotion rules. The versioned identifiers
// `dory.x86_64.baseline@1`, `dory.x86_64.v2@1`, `dory.x86_64.v3@1` are reserved
// registry names, not implemented persisted-profile migrations. Admission at a higher
// level requires every mandatory row qualified with evidence. A profile whose
// semantic qualification is `.unqualified` cannot be promoted regardless of
// advertised features. Old persisted profiles retain their meaning.
@Suite struct DoryX86ProfilePromotionTests {
  @Test func frozenIdentifiersMapToCorrectISALevels() {
    #expect(DoryX86LinuxBaselinePolicy.ProfileIdentifier.baselineV1.isaLevel == .baseline)
    #expect(DoryX86LinuxBaselinePolicy.ProfileIdentifier.v2V1.isaLevel == .v2)
    #expect(DoryX86LinuxBaselinePolicy.ProfileIdentifier.v3V1.isaLevel == .v3)
  }

  @Test func frozenIdentifiersAreStableStrings() {
    #expect(DoryX86LinuxBaselinePolicy.ProfileIdentifier.baselineV1.rawValue == "dory.x86_64.baseline@1")
    #expect(DoryX86LinuxBaselinePolicy.ProfileIdentifier.v2V1.rawValue == "dory.x86_64.v2@1")
    #expect(DoryX86LinuxBaselinePolicy.ProfileIdentifier.v3V1.rawValue == "dory.x86_64.v3@1")
  }

  @Test func compatibleV1PromotesToBaselineWithEvidence() {
    let result = DoryX86LinuxBaselinePolicy.promote(
      profile: .compatibleV1, to: .baseline)
    guard case .admitted(let level, let evidence) = result else {
      Issue.record("expected admission to baseline, got \(result)")
      return
    }
    #expect(level == .baseline)
    #expect(!evidence.isEmpty)
  }

  @Test func intelCompatibleV1PromotesToBaselineWithEvidence() {
    let result = DoryX86LinuxBaselinePolicy.promote(
      profile: .intelCompatibleV1, to: .baseline)
    guard case .admitted(let level, _) = result else {
      Issue.record("expected admission to baseline, got \(result)")
      return
    }
    #expect(level == .baseline)
  }

  @Test func baselineProfileIsRejectedForV2DueToMissingFeatures() {
    let result = DoryX86LinuxBaselinePolicy.promote(
      profile: .compatibleV1, to: .v2)
    // The public profile filters unqualified SIMD features, so v2 requirements
    // (SSE3, SSSE3, SSE4.1, SSE4.2, CX16, POPCNT, LAHF/SAHF) are missing.
    guard case .rejected(let level, let missing) = result else {
      Issue.record("expected rejection for v2, got \(result)")
      return
    }
    #expect(level == .v2)
    #expect(!missing.isEmpty)
    #expect(missing.contains(.sse3))
    #expect(missing.contains(.ssse3))
    #expect(missing.contains(.sse41))
    #expect(missing.contains(.sse42))
  }

  @Test func baselineProfileIsRejectedForV3DueToMissingFeatures() {
    let result = DoryX86LinuxBaselinePolicy.promote(
      profile: .compatibleV1, to: .v3)
    guard case .rejected(let level, let missing) = result else {
      Issue.record("expected rejection for v3, got \(result)")
      return
    }
    #expect(level == .v3)
    #expect(!missing.isEmpty)
    #expect(missing.contains(.avx))
    #expect(missing.contains(.avx2))
    #expect(missing.contains(.xsave))
  }

  @Test func syntheticV3ProfileIsRejectedAsUnqualifiedEvenWithAllFeatures() {
    // A synthetic profile that advertises all v3 features through the internal
    // init still cannot be promoted because semantic qualification is
    // evidence-bound, not advertisement-bound.
    let synthetic = DoryX86CPUProfile(
      identifier: "test.v3.synthetic",
      features: DoryX86CPUProfile.compatibleV1.features.union([
        .sse3, .ssse3, .sse41, .sse42, .xsave, .osxsave, .avx, .avx2,
        .f16c, .fma, .bmi1, .bmi2, .lzcnt, .movbe, .cmpxchg16b, .lahf64, .popcnt,
      ]),
      physicalAddressBits: 40,
      linearAddressBits: 48,
      virtualTSCFrequencyHz: 1_000_000_000,
      allowingUnqualifiedSIMDAndExtendedState: true)
    let result = DoryX86LinuxBaselinePolicy.promote(
      profile: synthetic, to: .v3)
    guard case .rejectedUnqualified(let level) = result else {
      Issue.record("expected unqualified rejection for v3, got \(result)")
      return
    }
    #expect(level == .v3)
  }

  @Test func oldPersistedProfileRetainsBaselineMeaning() throws {
    let original = DoryX86CPUProfile.compatibleV1
    let encoded = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(DoryX86CPUProfile.self, from: encoded)
    #expect(decoded == original)
    let result = DoryX86LinuxBaselinePolicy.promote(profile: decoded, to: .baseline)
    guard case .admitted = result else {
      Issue.record("decoded baseline profile should promote, got \(result)")
      return
    }
  }

  @Test func oldPersistedV3RequestDecodesToBaselineAdvertisedProfile() throws {
    // A persisted profile that requested v3 features decodes through the public
    // init, which filters unqualified features. The decoded profile therefore
    // advertises only baseline features and cannot be promoted to v3.
    let requested = DoryX86CPUProfile.compatibleV1.features.union([
      .sse3, .ssse3, .sse41, .sse42, .xsave, .osxsave, .avx, .avx2,
      .f16c, .fma, .bmi1, .bmi2, .lzcnt, .movbe,
    ])
    let internalProfile = DoryX86CPUProfile(
      identifier: "test.persisted.v3",
      features: requested,
      physicalAddressBits: 40,
      linearAddressBits: 48,
      virtualTSCFrequencyHz: 1_000_000_000,
      allowingUnqualifiedSIMDAndExtendedState: true)
    let encoded = try JSONEncoder().encode(internalProfile)
    let decoded = try JSONDecoder().decode(DoryX86CPUProfile.self, from: encoded)
    let result = DoryX86LinuxBaselinePolicy.promote(profile: decoded, to: .v3)
    guard case .rejected(let level, let missing) = result else {
      Issue.record("expected rejection for decoded v3, got \(result)")
      return
    }
    #expect(level == .v3)
    #expect(!missing.isEmpty)
  }
}
