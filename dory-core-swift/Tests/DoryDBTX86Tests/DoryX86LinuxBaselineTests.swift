import Testing

@testable import DoryDBTX86

// x86-64 psABI, "Micro-Architecture Levels":
// https://gitlab.com/x86-psABIs/x86-64-ABI/blob/master/x86-64-ABI/low-level-sys-info.tex
@Suite struct DoryX86LinuxBaselineTests {
  @Test func contractMatchesTheExactBaselineAndV2Requirements() {
    let baseline = DoryX86LinuxBaselineRequirements.baseline
    #expect(baseline.level == .baseline)
    #expect(baseline.cpuid == Set([
      requirement(.cmov, 1, .edx, 15),
      requirement(.cmpxchg8b, 1, .edx, 8),
      requirement(.x87, 1, .edx, 0),
      requirement(.fxsave, 1, .edx, 24),
      requirement(.mmx, 1, .edx, 23),
      requirement(.sse, 1, .edx, 25),
      requirement(.sse2, 1, .edx, 26),
    ]))
    #expect(baseline.guestControls == Set([
      control("OSFXSR", .cr4, 9, [.fxsave, .sse]),
      control("SCE", .ia32EFER, 0, [.syscall]),
    ]))

    let v2 = DoryX86LinuxBaselineRequirements.v2
    #expect(v2.level == .v2)
    #expect(v2.guestControls == baseline.guestControls)
    #expect(v2.cpuid.subtracting(baseline.cpuid) == Set([
      requirement(.cmpxchg16b, 1, .ecx, 13),
      requirement(.lahf64, 0x8000_0001, .ecx, 0),
      requirement(.popcnt, 1, .ecx, 23),
      requirement(.sse3, 1, .ecx, 0),
      requirement(.ssse3, 1, .ecx, 9),
      requirement(.sse41, 1, .ecx, 19),
      requirement(.sse42, 1, .ecx, 20),
    ]))
  }

  @Test func selectedProfilesAdvertiseBaselineAndExposeTheExactV2Gap() {
    let v2Gap: Set<DoryX86Feature> = [.popcnt, .sse3, .ssse3, .sse41, .sse42]
    for profile in [DoryX86CPUProfile.compatibleV1, .intelCompatibleV1] {
      let baseline = profile.linuxBaselineAssessment(for: .baseline)
      #expect(baseline.advertisement.satisfiesRequirements)
      #expect(baseline.advertisement.missingProfileFeatures.isEmpty)
      #expect(baseline.advertisement.unavailableGuestControls.isEmpty)
      #expect(baseline.semanticQualification == .unqualified)
      #expect(!baseline.isQualified)

      let v2 = profile.linuxBaselineAssessment(for: .v2)
      #expect(v2.advertisement.missingProfileFeatures == v2Gap)
      #expect(v2.advertisement.unavailableGuestControls.isEmpty)
      #expect(!v2.advertisement.satisfiesRequirements)
      #expect(v2.semanticQualification == .unqualified)
      #expect(!v2.isQualified)
    }
  }

  @Test func everyAdvertisedBitStillCannotClaimSemanticQualification() {
    let synthetic = DoryX86CPUProfile(
      identifier: "test-only.all-advertised-linux-v2",
      features: Set(DoryX86Feature.allCases),
      physicalAddressBits: 40,
      linearAddressBits: 48,
      virtualTSCFrequencyHz: 1_000_000_000
    )
    let assessment = synthetic.linuxBaselineAssessment(for: .v2)
    #expect(assessment.advertisement.satisfiesRequirements)
    #expect(assessment.advertisement.missingProfileFeatures.isEmpty)
    #expect(assessment.advertisement.unavailableGuestControls.isEmpty)
    #expect(assessment.semanticQualification == .unqualified)
    #expect(!assessment.isQualified)
  }

  @Test func controlCapabilitiesAreAuditedSeparatelyFromCPUIDRequirements() {
    let missingSCE = profile(removing: [.syscall])
      .linuxBaselineAssessment(for: .baseline)
    #expect(missingSCE.advertisement.missingProfileFeatures.isEmpty)
    #expect(missingSCE.advertisement.unavailableGuestControls == Set([
      control("SCE", .ia32EFER, 0, [.syscall]),
    ]))

    let missingOSFXSR = profile(removing: [.sse, .sse2])
      .linuxBaselineAssessment(for: .baseline)
    #expect(missingOSFXSR.advertisement.missingProfileFeatures == [.sse, .sse2])
    #expect(missingOSFXSR.advertisement.unavailableGuestControls == Set([
      control("OSFXSR", .cr4, 9, [.fxsave, .sse]),
    ]))
  }

  private func requirement(
    _ feature: DoryX86Feature,
    _ leaf: UInt32,
    _ register: DoryX86LinuxCPUIDRegister,
    _ bit: UInt8
  ) -> DoryX86LinuxCPUIDRequirement {
    .init(feature: feature, leaf: leaf, register: register, bit: bit)
  }

  private func control(
    _ name: String,
    _ register: DoryX86LinuxGuestControlRequirement.Register,
    _ bit: UInt8,
    _ features: Set<DoryX86Feature>
  ) -> DoryX86LinuxGuestControlRequirement {
    .init(name: name, register: register, bit: bit, profileFeatures: features)
  }

  private func profile(removing features: Set<DoryX86Feature>) -> DoryX86CPUProfile {
    let base = DoryX86CPUProfile.compatibleV1
    return .init(
      identifier: "test-only.baseline-controls",
      features: base.features.subtracting(features),
      physicalAddressBits: base.physicalAddressBits,
      linearAddressBits: base.linearAddressBits,
      virtualTSCFrequencyHz: base.virtualTSCFrequencyHz
    )
  }
}
