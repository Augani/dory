import Foundation

/// Errors from resolving a persisted x86 CPU profile. These errors deliberately
/// distinguish an unknown raw identifier from a known-but-unimplemented level.
public enum DoryX86ProfileRegistryError: Error, Sendable, Equatable, CustomStringConvertible {
  case unknownProfileIdentifier(String)
  case unimplementedProfile(DoryX86ProfileRegistry.Identifier)
  case unsupportedLegacyProfileIdentifier(String)

  public var description: String {
    switch self {
    case .unknownProfileIdentifier(let identifier):
      "Unknown x86 CPU profile identifier: \(identifier)"
    case .unimplementedProfile(let identifier):
      "x86 CPU profile is recognized but not implemented: \(identifier.rawValue)"
    case .unsupportedLegacyProfileIdentifier(let identifier):
      "x86 CPU profile is not an exact supported legacy compatibility identifier: \(identifier)"
    }
  }
}

/// A resolved CPU contract. Its identifier is a registry identity; `cpuProfile`
/// remains the guest CPUID identity used by the execution engine.
public struct DoryX86ResolvedCPUProfile: Sendable, Hashable {
  public let identifier: DoryX86ProfileRegistry.Identifier
  public let cpuProfile: DoryX86CPUProfile
  public let fingerprint: String

  fileprivate init(identifier: DoryX86ProfileRegistry.Identifier, cpuProfile: DoryX86CPUProfile) {
    self.identifier = identifier
    self.cpuProfile = cpuProfile
    self.fingerprint = DoryX86ProfileRegistry.fingerprint(
      identifier: identifier, cpuProfile: cpuProfile)
  }
}

/// Closed, versioned registry of persisted x86 CPU contracts.
///
/// A string is accepted only at decoding and explicit legacy-migration
/// boundaries. It cannot admit a new CPU profile or mutate the descriptor.
public enum DoryX86ProfileRegistry {
  /// Version increments describe a changed CPU contract, not new evidence.
  public enum Identifier: String, Codable, CaseIterable, Sendable, Hashable {
    case baselineV1 = "dory.x86_64.baseline@1"
    case v2V1 = "dory.x86_64.v2@1"
    case v3V1 = "dory.x86_64.v3@1"

    public var isaLevel: DoryX86LinuxISALevel {
      switch self {
      case .baselineV1: .baseline
      case .v2V1: .v2
      case .v3V1: .v3
      }
    }
  }

  /// The one implemented persisted profile. v2/v3 names remain typed so they
  /// can be rejected as unimplemented instead of being treated as arbitrary IDs.
  public static let implementedIdentifiers: Set<Identifier> = [.baselineV1]

  public static func resolve(_ identifier: Identifier) throws -> DoryX86ResolvedCPUProfile {
    try resolve(identifier, identity: .legacyDoryV1)
  }

  /// Resolves the frozen guest identity for a registered profile. The baseline
  /// contract permits both historical identities, whose CPUID vendor/signature
  /// behavior remains distinct and fingerprinted.
  public static func resolve(
    _ identifier: Identifier,
    identity: DoryX86CPUIdentity
  ) throws -> DoryX86ResolvedCPUProfile {
    guard implementedIdentifiers.contains(identifier) else {
      throw DoryX86ProfileRegistryError.unimplementedProfile(identifier)
    }
    let cpuProfile: DoryX86CPUProfile =
      switch identity {
      case .legacyDoryV1: .compatibleV1
      case .intelCompatibleV1: .intelCompatibleV1
      }
    return .init(identifier: identifier, cpuProfile: cpuProfile)
  }

  /// Resolves a closed registry identifier received from persistence.
  public static func resolvePersistedIdentifier(
    _ rawIdentifier: String,
    identity: DoryX86CPUIdentity
  ) throws -> DoryX86ResolvedCPUProfile {
    guard let identifier = Identifier(rawValue: rawIdentifier) else {
      throw DoryX86ProfileRegistryError.unknownProfileIdentifier(rawIdentifier)
    }
    return try resolve(identifier, identity: identity)
  }

  /// Maps only the two historical persisted compatibility identifiers. This is
  /// intentionally not a general `DoryX86CPUProfile.identifier` admission API.
  public static func migrateLegacyCompatibilityIdentifier(
    _ rawIdentifier: String
  ) throws -> DoryX86ResolvedCPUProfile {
    switch rawIdentifier {
    case DoryX86CPUProfile.compatibleV1Identifier:
      return try resolve(.baselineV1, identity: .legacyDoryV1)
    case DoryX86CPUProfile.intelCompatibleV1Identifier:
      return try resolve(.baselineV1, identity: .intelCompatibleV1)
    default:
      throw DoryX86ProfileRegistryError.unsupportedLegacyProfileIdentifier(rawIdentifier)
    }
  }

  fileprivate static func fingerprint(
    identifier: Identifier,
    cpuProfile: DoryX86CPUProfile
  ) -> String {
    let facts = [
      identifier.rawValue,
      cpuProfile.identity.rawValue,
      cpuProfile.identifier,
      cpuProfile.features.map(\.rawValue).sorted().joined(separator: ","),
      String(cpuProfile.physicalAddressBits),
      String(cpuProfile.linearAddressBits),
      String(cpuProfile.virtualTSCFrequencyHz),
    ].joined(separator: "\\u{1F}")
    var value: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in facts.utf8 {
      value ^= UInt64(byte)
      value &*= 0x0000_0100_0000_01b3
    }
    return String(format: "%016llx", value)
  }
}

/// Validation errors for the production x86 architectural saved-state envelope.
public enum DoryX86SavedStateError: Error, Sendable, Equatable, CustomStringConvertible {
  case unsupportedFormatVersion(UInt16)
  case profileFingerprintMismatch(expected: String, actual: String)
  case profileMismatch(expected: DoryX86ProfileRegistry.Identifier, actual: DoryX86ProfileRegistry.Identifier)
  case cpuIdentityMismatch(expected: DoryX86CPUIdentity, actual: DoryX86CPUIdentity)
  case xcr0OutsideProfile(value: UInt64, allowed: UInt64)
  case osxsaveEnabledOutsideProfile(cr4: UInt64)
  case cr4OutsideExecutionContract(value: UInt64, allowed: UInt64)
  case cr0OutsideExecutionContract(value: UInt64, allowed: UInt64)
  case invalidCR0Configuration(value: UInt64)
  case eferOutsideExecutionContract(value: UInt64, allowed: UInt64)
  case inconsistentLongMode(cr0: UInt64, cr4: UInt64, efer: UInt64)

  public var description: String {
    switch self {
    case .unsupportedFormatVersion(let version):
      "Unsupported x86 saved-state format version: \(version)"
    case .profileFingerprintMismatch(let expected, let actual):
      "x86 saved-state profile fingerprint mismatch (expected \(expected), got \(actual))"
    case .profileMismatch(let expected, let actual):
      "x86 saved-state profile mismatch (expected \(expected.rawValue), got \(actual.rawValue))"
    case .cpuIdentityMismatch(let expected, let actual):
      "x86 saved-state CPU identity mismatch (expected \(expected.rawValue), got \(actual.rawValue))"
    case .xcr0OutsideProfile(let value, let allowed):
      "x86 saved-state XCR0 0x\(String(value, radix: 16)) exceeds profile mask 0x\(String(allowed, radix: 16))"
    case .osxsaveEnabledOutsideProfile(let cr4):
      "x86 saved-state CR4.OSXSAVE is enabled outside the resolved profile (CR4 0x\(String(cr4, radix: 16)))"
    case .cr4OutsideExecutionContract(let value, let allowed):
      "x86 saved-state CR4 0x\(String(value, radix: 16)) exceeds execution mask 0x\(String(allowed, radix: 16))"
    case .cr0OutsideExecutionContract(let value, let allowed):
      "x86 saved-state CR0 0x\(String(value, radix: 16)) exceeds stored execution mask 0x\(String(allowed, radix: 16))"
    case .invalidCR0Configuration(let value):
      "x86 saved-state CR0 0x\(String(value, radix: 16)) violates the fixed ET, PG/PE, or NW/CD contract"
    case .eferOutsideExecutionContract(let value, let allowed):
      "x86 saved-state EFER 0x\(String(value, radix: 16)) exceeds execution mask 0x\(String(allowed, radix: 16))"
    case .inconsistentLongMode(let cr0, let cr4, let efer):
      "x86 saved-state IA-32e controls disagree (CR0 0x\(String(cr0, radix: 16)), CR4 0x\(String(cr4, radix: 16)), EFER 0x\(String(efer, radix: 16)))"
    }
  }
}

/// Versioned production persistence contract for x86 architectural state.
/// Bare `DoryX86ArchitecturalState` Codable remains supported for old callers;
/// new saved state must use this envelope and pass its registry validation.
public struct DoryX86SavedStateEnvelope: Codable, Sendable, Hashable {
  public static let currentFormatVersion: UInt16 = 1

  public let formatVersion: UInt16
  public let resolvedProfileID: DoryX86ProfileRegistry.Identifier
  public let cpuIdentity: DoryX86CPUIdentity
  public let profileFingerprint: String
  public let architecturalState: DoryX86ArchitecturalState

  public init(
    state: DoryX86ArchitecturalState,
    resolvedProfile: DoryX86ResolvedCPUProfile
  ) throws {
    self.formatVersion = Self.currentFormatVersion
    self.resolvedProfileID = resolvedProfile.identifier
    self.cpuIdentity = resolvedProfile.cpuProfile.identity
    self.profileFingerprint = resolvedProfile.fingerprint
    self.architecturalState = state
    try validate()
  }

  /// Exact migration for historical named compatibility identifiers only.
  public static func migrateLegacy(
    state: DoryX86ArchitecturalState,
    profileIdentifier: String
  ) throws -> Self {
    try .init(
      state: state,
      resolvedProfile: DoryX86ProfileRegistry.migrateLegacyCompatibilityIdentifier(profileIdentifier))
  }

  /// Returns validated state only when it matches the exact resolved CPU
  /// contract selected by the restoring machine.
  public func restore(using profile: DoryX86ResolvedCPUProfile) throws -> DoryX86ArchitecturalState {
    try validate()
    guard resolvedProfileID == profile.identifier else {
      throw DoryX86SavedStateError.profileMismatch(
        expected: profile.identifier, actual: resolvedProfileID)
    }
    guard cpuIdentity == profile.cpuProfile.identity else {
      throw DoryX86SavedStateError.cpuIdentityMismatch(
        expected: profile.cpuProfile.identity, actual: cpuIdentity)
    }
    guard profileFingerprint == profile.fingerprint else {
      throw DoryX86SavedStateError.profileFingerprintMismatch(
        expected: profile.fingerprint, actual: profileFingerprint)
    }
    return architecturalState
  }

  private enum CodingKeys: String, CodingKey {
    case formatVersion, resolvedProfileID, cpuIdentity, profileFingerprint, architecturalState
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let formatVersion = try values.decode(UInt16.self, forKey: .formatVersion)
    guard formatVersion == Self.currentFormatVersion else {
      throw DoryX86SavedStateError.unsupportedFormatVersion(formatVersion)
    }
    let rawIdentifier = try values.decode(String.self, forKey: .resolvedProfileID)
    let identity = try values.decode(DoryX86CPUIdentity.self, forKey: .cpuIdentity)
    let resolved = try DoryX86ProfileRegistry.resolvePersistedIdentifier(
      rawIdentifier, identity: identity)
    let fingerprint = try values.decode(String.self, forKey: .profileFingerprint)
    let state = try values.decode(DoryX86ArchitecturalState.self, forKey: .architecturalState)
    self.formatVersion = formatVersion
    self.resolvedProfileID = resolved.identifier
    self.cpuIdentity = identity
    self.profileFingerprint = fingerprint
    self.architecturalState = state
    try validate()
  }

  private func validate() throws {
    guard formatVersion == Self.currentFormatVersion else {
      throw DoryX86SavedStateError.unsupportedFormatVersion(formatVersion)
    }
    let resolved = try DoryX86ProfileRegistry.resolve(resolvedProfileID, identity: cpuIdentity)
    guard profileFingerprint == resolved.fingerprint else {
      throw DoryX86SavedStateError.profileFingerprintMismatch(
        expected: resolved.fingerprint, actual: profileFingerprint)
    }
    let cr4 = architecturalState.control.cr4
    guard cr4 & (1 << 18) == 0 || resolved.cpuProfile.supports(.xsave) else {
      throw DoryX86SavedStateError.osxsaveEnabledOutsideProfile(cr4: cr4)
    }
    let allowedCR4 = resolved.cpuProfile.implementedCR4Mask
    guard cr4 & ~allowedCR4 == 0 else {
      throw DoryX86SavedStateError.cr4OutsideExecutionContract(value: cr4, allowed: allowedCR4)
    }
    let allowedXCR0 = Self.allowedXCR0(for: resolved.cpuProfile)
    let xcr0 = architecturalState.control.xcr0
    guard xcr0 & ~allowedXCR0 == 0 else {
      throw DoryX86SavedStateError.xcr0OutsideProfile(value: xcr0, allowed: allowedXCR0)
    }
    // Public architectural controls are mutable after their constructor has
    // validated XSTATE. Save/migration must not bypass that existing shape gate.
    // Keep profile-mask error precedence above, and generic decode's error type.
    guard xcr0 & 1 == 1, xcr0 & 4 == 0 || xcr0 & 2 != 0 else {
      throw DoryX86StateError.invalidXCR0(xcr0)
    }

    // These are stored control facts, not new CPUID/feature qualifications.
    // Preserve earlier format/profile/CR4/XCR0 errors before the new checks.
    let cr0 = architecturalState.control.cr0
    let allowedCR0 = DoryX86CPUProfile.implementedCR0Mask
    guard cr0 & ~allowedCR0 == 0 else {
      throw DoryX86SavedStateError.cr0OutsideExecutionContract(value: cr0, allowed: allowedCR0)
    }
    let paging = cr0 & (1 << 31) != 0
    guard cr0 & (1 << 4) != 0,
      !paging || cr0 & 1 != 0,
      cr0 & (1 << 29) == 0 || cr0 & (1 << 30) != 0
    else { throw DoryX86SavedStateError.invalidCR0Configuration(value: cr0) }

    let efer = architecturalState.control.efer
    let allowedEFER = resolved.cpuProfile.implementedEFERWritableMask | (1 << 10)
    guard efer & ~allowedEFER == 0 else {
      throw DoryX86SavedStateError.eferOutsideExecutionContract(value: efer, allowed: allowedEFER)
    }
    let longModeEnabled = efer & (1 << 8) != 0
    let longModeActive = efer & (1 << 10) != 0
    // MOV CR0 sets LMA exactly when PG enters with LME; WRMSR cannot change
    // LME under paging or independently write LMA, and active IA-32e keeps PAE.
    guard longModeActive == (paging && longModeEnabled),
      !longModeActive || cr4 & (1 << 5) != 0
    else {
      throw DoryX86SavedStateError.inconsistentLongMode(cr0: cr0, cr4: cr4, efer: efer)
    }
  }

  private static func allowedXCR0(for profile: DoryX86CPUProfile) -> UInt64 {
    var mask: UInt64 = 1
    if profile.supports(.sse) { mask |= 1 << 1 }
    if profile.supports(.avx) { mask |= 1 << 2 }
    return mask
  }
}
