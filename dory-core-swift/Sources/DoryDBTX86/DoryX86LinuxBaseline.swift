/// Linux x86-64 ISA levels as defined by the x86-64 psABI.
///
/// This contract describes feature advertisement only. It does not turn a set of
/// CPUID bits into semantic qualification; qualification remains a separate,
/// evidence-bound decision.
public enum DoryX86LinuxISALevel: String, Codable, CaseIterable, Sendable, Hashable {
  case baseline = "x86-64-baseline"
  case v2 = "x86-64-v2"
}

/// The CPUID register containing a Linux ISA-level feature bit.
public enum DoryX86LinuxCPUIDRegister: String, Codable, Sendable, Hashable {
  case eax
  case ebx
  case ecx
  case edx
}

/// One profile feature and its architectural CPUID location.
public struct DoryX86LinuxCPUIDRequirement: Codable, Sendable, Hashable {
  public let feature: DoryX86Feature
  public let leaf: UInt32
  public let subleaf: UInt32
  public let register: DoryX86LinuxCPUIDRegister
  public let bit: UInt8

  public init(
    feature: DoryX86Feature,
    leaf: UInt32,
    subleaf: UInt32 = 0,
    register: DoryX86LinuxCPUIDRegister,
    bit: UInt8
  ) {
    self.feature = feature
    self.leaf = leaf
    self.subleaf = subleaf
    self.register = register
    self.bit = bit
  }

  public func isAdvertised(by profile: DoryX86CPUProfile) -> Bool {
    guard bit < 32, profile.supports(feature) else { return false }
    let result = profile.cpuid(leaf: leaf, subleaf: subleaf)
    let value: UInt32 =
      switch register {
      case .eax: result.eax
      case .ebx: result.ebx
      case .ecx: result.ecx
      case .edx: result.edx
      }
    return value & (UInt32(1) << bit) != 0
  }
}

/// A guest-controlled architectural gate required by the psABI baseline.
///
/// OSFXSR and SCE are control bits rather than ISA-level CPUID bits. The
/// `profileFeatures` records the Dory capabilities that permit the guest to use
/// the corresponding control.
public struct DoryX86LinuxGuestControlRequirement: Codable, Sendable, Hashable {
  public enum Register: String, Codable, Sendable, Hashable {
    case cr4 = "CR4"
    case ia32EFER = "IA32_EFER"
  }

  public let name: String
  public let register: Register
  public let bit: UInt8
  public let profileFeatures: Set<DoryX86Feature>

  public init(
    name: String,
    register: Register,
    bit: UInt8,
    profileFeatures: Set<DoryX86Feature>
  ) {
    self.name = name
    self.register = register
    self.bit = bit
    self.profileFeatures = profileFeatures
  }
}

/// Exact x86-64 psABI requirements for an ISA level.
public struct DoryX86LinuxBaselineRequirements: Codable, Sendable, Hashable {
  public let level: DoryX86LinuxISALevel
  public let cpuid: Set<DoryX86LinuxCPUIDRequirement>
  public let guestControls: Set<DoryX86LinuxGuestControlRequirement>

  public init(
    level: DoryX86LinuxISALevel,
    cpuid: Set<DoryX86LinuxCPUIDRequirement>,
    guestControls: Set<DoryX86LinuxGuestControlRequirement>
  ) {
    self.level = level
    self.cpuid = cpuid
    self.guestControls = guestControls
  }

  /// x86-64 psABI baseline: CMOV, CX8, FPU, FXSR, MMX, OSFXSR, SCE, SSE, SSE2.
  public static let baseline = Self(
    level: .baseline,
    cpuid: [
      .init(feature: .cmov, leaf: 1, register: .edx, bit: 15),
      .init(feature: .cmpxchg8b, leaf: 1, register: .edx, bit: 8),
      .init(feature: .x87, leaf: 1, register: .edx, bit: 0),
      .init(feature: .fxsave, leaf: 1, register: .edx, bit: 24),
      .init(feature: .mmx, leaf: 1, register: .edx, bit: 23),
      .init(feature: .sse, leaf: 1, register: .edx, bit: 25),
      .init(feature: .sse2, leaf: 1, register: .edx, bit: 26),
    ],
    guestControls: [
      .init(name: "OSFXSR", register: .cr4, bit: 9, profileFeatures: [.fxsave, .sse]),
      .init(name: "SCE", register: .ia32EFER, bit: 0, profileFeatures: [.syscall]),
    ]
  )

  /// x86-64-v2 inherits the baseline and adds CX16, LAHF/SAHF, POPCNT,
  /// SSE3, SSSE3, SSE4.1, and SSE4.2.
  public static let v2 = Self(
    level: .v2,
    cpuid: baseline.cpuid.union([
      .init(feature: .cmpxchg16b, leaf: 1, register: .ecx, bit: 13),
      .init(feature: .lahf64, leaf: 0x8000_0001, register: .ecx, bit: 0),
      .init(feature: .popcnt, leaf: 1, register: .ecx, bit: 23),
      .init(feature: .sse3, leaf: 1, register: .ecx, bit: 0),
      .init(feature: .ssse3, leaf: 1, register: .ecx, bit: 9),
      .init(feature: .sse41, leaf: 1, register: .ecx, bit: 19),
      .init(feature: .sse42, leaf: 1, register: .ecx, bit: 20),
    ]),
    guestControls: baseline.guestControls
  )

  public static func requirements(for level: DoryX86LinuxISALevel) -> Self {
    switch level {
    case .baseline: baseline
    case .v2: v2
    }
  }
}

/// Profile advertisement findings. This deliberately says nothing about the
/// correctness or qualification of the advertised instruction semantics.
public struct DoryX86LinuxBaselineAdvertisement: Codable, Sendable, Hashable {
  public let missingProfileFeatures: Set<DoryX86Feature>
  public let unavailableGuestControls: Set<DoryX86LinuxGuestControlRequirement>

  public var satisfiesRequirements: Bool {
    missingProfileFeatures.isEmpty && unavailableGuestControls.isEmpty
  }
}

/// Semantic qualification is evidence-bound and independent of advertisement.
public enum DoryX86LinuxBaselineSemanticQualification: Codable, Sendable, Hashable {
  case unqualified
  case qualified(evidenceIdentifier: String)
}

/// The supported Linux CPU contract for Dory's versioned x86 profiles.
///
/// Qualification is deliberately narrower than feature advertisement. Only an
/// exact selected profile value can carry the retained Linux-guest evidence;
/// copying its identifier onto a different feature or identity envelope does
/// not qualify that profile. Higher ISA levels remain unqualified until their
/// complete requirements and semantic gates have separate evidence.
public enum DoryX86LinuxBaselinePolicy {
  public static let firstSupportedLevel: DoryX86LinuxISALevel = .baseline
  public static let qualificationEvidenceIdentifier =
    "p02-linux-cpu-baseline-selected-profiles-2026-09-04"

  fileprivate static func semanticQualification(
    for profile: DoryX86CPUProfile,
    level: DoryX86LinuxISALevel
  ) -> DoryX86LinuxBaselineSemanticQualification {
    guard level == firstSupportedLevel,
      profile == .compatibleV1 || profile == .intelCompatibleV1
    else { return .unqualified }
    return .qualified(evidenceIdentifier: qualificationEvidenceIdentifier)
  }
}

public struct DoryX86LinuxBaselineAssessment: Codable, Sendable, Hashable {
  public let requirements: DoryX86LinuxBaselineRequirements
  public let advertisement: DoryX86LinuxBaselineAdvertisement
  public let semanticQualification: DoryX86LinuxBaselineSemanticQualification

  public var isQualified: Bool {
    guard advertisement.satisfiesRequirements else { return false }
    if case .qualified = semanticQualification { return true }
    return false
  }

  fileprivate init(
    requirements: DoryX86LinuxBaselineRequirements,
    advertisement: DoryX86LinuxBaselineAdvertisement,
    semanticQualification: DoryX86LinuxBaselineSemanticQualification
  ) {
    self.requirements = requirements
    self.advertisement = advertisement
    self.semanticQualification = semanticQualification
  }
}

extension DoryX86CPUProfile {
  /// Audits this profile's advertised requirements for a Linux ISA level.
  ///
  /// Advertisement is calculated for every profile. Semantic qualification is
  /// independently attached only by the evidence-bound selected-profile policy.
  public func linuxBaselineAssessment(
    for level: DoryX86LinuxISALevel
  ) -> DoryX86LinuxBaselineAssessment {
    let requirements = DoryX86LinuxBaselineRequirements.requirements(for: level)
    let missingProfileFeatures = Set(
      requirements.cpuid.lazy.filter { !$0.isAdvertised(by: self) }.map(\.feature)
    )
    let unavailableGuestControls = Set(
      requirements.guestControls.filter { requirement in
        !requirement.profileFeatures.allSatisfy(supports)
      }
    )
    return .init(
      requirements: requirements,
      advertisement: .init(
        missingProfileFeatures: missingProfileFeatures,
        unavailableGuestControls: unavailableGuestControls
      ),
      semanticQualification: DoryX86LinuxBaselinePolicy.semanticQualification(
        for: self, level: level)
    )
  }
}
