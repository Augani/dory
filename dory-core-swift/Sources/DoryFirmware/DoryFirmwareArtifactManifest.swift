import CryptoKit
import DoryMachineARMVirt
import DoryMachinePC
import Foundation

public enum DoryFirmwareSecureBootPolicy: String, Codable, CaseIterable, Sendable, Hashable {
  case disabled
  case userManagedKeys = "user-managed-keys"
}

public enum DoryFirmwarePlatform: String, Codable, CaseIterable, Sendable, Hashable {
  case armVirtV1 = "dory-armvirt-v1"
  case pcV1 = "dory-pc-v1"

  public var machineABIIdentity: String {
    switch self {
    case .armVirtV1: DoryARMVirtV1ABI.identity
    case .pcV1: DoryPCV1ABI.identity
    }
  }

  public var firmwareABIIdentity: String {
    switch self {
    case .armVirtV1: DoryARMVirtV1ABI.firmwareABIIdentity
    case .pcV1: DoryPCV1ABI.firmwareABIIdentity
    }
  }

  public var variableStoreFormatIdentity: String {
    switch self {
    case .armVirtV1: DoryARMVirtV1ABI.variableStoreFormatIdentity
    case .pcV1: DoryPCV1ABI.variableStoreFormatIdentity
    }
  }

  public var variableBridgeIdentity: String {
    switch self {
    case .armVirtV1: "dory.uefi.variable-bridge.armvirt@1"
    case .pcV1: DoryPCV1ABI.variableBridgeIdentity
    }
  }

  public var maximumFirmwareCodeBytes: UInt64 {
    switch self {
    case .armVirtV1: DoryARMVirtV1ABI.firmwareCodeBytes
    case .pcV1: DoryPCV1ABI.firmwareCodeBytes
    }
  }

  public var sbomComponentName: String {
    switch self {
    case .armVirtV1: "DoryARMVirt"
    case .pcV1: "DoryPC"
    }
  }

  fileprivate static func resolve(
    firmwareABIIdentity: String,
    machineABIIdentity: String,
    variableStoreFormatIdentity: String,
    variableBridgeIdentity: String
  ) -> Self? {
    allCases.first {
      $0.firmwareABIIdentity == firmwareABIIdentity
        && $0.machineABIIdentity == machineABIIdentity
        && $0.variableStoreFormatIdentity == variableStoreFormatIdentity
        && $0.variableBridgeIdentity == variableBridgeIdentity
    }
  }
}

public struct DoryFirmwareSourcePin: Codable, Sendable, Hashable {
  public let repository: String
  public let revision: String

  public init(repository: String, revision: String) throws {
    guard let url = URL(string: repository),
      url.scheme == "https",
      url.host != nil,
      url.user == nil,
      url.password == nil,
      url.fragment == nil,
      repository.utf8.count <= 2_048
    else {
      throw DoryFirmwareManifestError.invalidSourceRepository(repository)
    }
    guard Self.isLowercaseHex(revision, count: 40) else {
      throw DoryFirmwareManifestError.invalidSourceRevision(revision)
    }
    self.repository = repository
    self.revision = revision
  }

  private enum CodingKeys: String, CodingKey { case repository, revision }

  public init(from decoder: Decoder) throws {
    try rejectUnknownFirmwareFields(
      from: decoder,
      allowed: ["repository", "revision"],
      type: "DoryFirmwareSourcePin"
    )
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      repository: container.decode(String.self, forKey: .repository),
      revision: container.decode(String.self, forKey: .revision)
    )
  }

  fileprivate static func isLowercaseHex(_ value: String, count: Int) -> Bool {
    value.utf8.count == count
      && value.utf8.allSatisfy {
        (48...57).contains($0) || (97...102).contains($0)
      }
  }
}

public struct DoryFirmwareArtifactManifest: Codable, Sendable, Hashable {
  public static let schemaVersion: UInt32 = 1

  public let schemaVersion: UInt32
  public let firmwareABIIdentity: String
  public let machineABIIdentity: String
  public let variableStoreFormatIdentity: String
  public let variableBridgeIdentity: String
  public let buildIdentifier: String
  public let source: DoryFirmwareSourcePin
  public let sourceDateEpoch: UInt64
  public let platformConfigurationSHA256: String
  public let toolchainSHA256: String
  public let firmwareCodeSHA256: String
  public let firmwareCodeByteCount: UInt64
  public let variableStoreTemplateSHA256: String
  public let variableStoreTemplateByteCount: UInt64
  public let sbomSHA256: String
  public let secureBootPolicy: DoryFirmwareSecureBootPolicy
  public let reproducible: Bool

  public init(
    platform: DoryFirmwarePlatform = .armVirtV1,
    buildIdentifier: String,
    source: DoryFirmwareSourcePin,
    sourceDateEpoch: UInt64,
    platformConfigurationSHA256: String,
    toolchainSHA256: String,
    firmwareCodeSHA256: String,
    firmwareCodeByteCount: UInt64,
    variableStoreTemplateSHA256: String,
    variableStoreTemplateByteCount: UInt64,
    sbomSHA256: String,
    secureBootPolicy: DoryFirmwareSecureBootPolicy,
    reproducible: Bool
  ) throws {
    try self.init(
      schemaVersion: Self.schemaVersion,
      firmwareABIIdentity: platform.firmwareABIIdentity,
      machineABIIdentity: platform.machineABIIdentity,
      variableStoreFormatIdentity: platform.variableStoreFormatIdentity,
      variableBridgeIdentity: platform.variableBridgeIdentity,
      buildIdentifier: buildIdentifier,
      source: source,
      sourceDateEpoch: sourceDateEpoch,
      platformConfigurationSHA256: platformConfigurationSHA256,
      toolchainSHA256: toolchainSHA256,
      firmwareCodeSHA256: firmwareCodeSHA256,
      firmwareCodeByteCount: firmwareCodeByteCount,
      variableStoreTemplateSHA256: variableStoreTemplateSHA256,
      variableStoreTemplateByteCount: variableStoreTemplateByteCount,
      sbomSHA256: sbomSHA256,
      secureBootPolicy: secureBootPolicy,
      reproducible: reproducible
    )
  }

  private init(
    schemaVersion: UInt32,
    firmwareABIIdentity: String,
    machineABIIdentity: String,
    variableStoreFormatIdentity: String,
    variableBridgeIdentity: String,
    buildIdentifier: String,
    source: DoryFirmwareSourcePin,
    sourceDateEpoch: UInt64,
    platformConfigurationSHA256: String,
    toolchainSHA256: String,
    firmwareCodeSHA256: String,
    firmwareCodeByteCount: UInt64,
    variableStoreTemplateSHA256: String,
    variableStoreTemplateByteCount: UInt64,
    sbomSHA256: String,
    secureBootPolicy: DoryFirmwareSecureBootPolicy,
    reproducible: Bool
  ) throws {
    guard schemaVersion == Self.schemaVersion else {
      throw DoryFirmwareManifestError.unsupportedSchemaVersion(schemaVersion)
    }
    guard
      let platform = DoryFirmwarePlatform.allCases.first(where: {
        $0.firmwareABIIdentity == firmwareABIIdentity
      })
    else { throw DoryFirmwareManifestError.incompatibleFirmwareABI(firmwareABIIdentity) }
    guard machineABIIdentity == platform.machineABIIdentity else {
      throw DoryFirmwareManifestError.incompatibleMachineABI(machineABIIdentity)
    }
    guard variableStoreFormatIdentity == platform.variableStoreFormatIdentity else {
      throw DoryFirmwareManifestError.incompatibleVariableStore(variableStoreFormatIdentity)
    }
    guard variableBridgeIdentity == platform.variableBridgeIdentity else {
      throw DoryFirmwareManifestError.incompatibleVariableBridge(variableBridgeIdentity)
    }
    guard Self.isSafeBuildIdentifier(buildIdentifier) else {
      throw DoryFirmwareManifestError.invalidBuildIdentifier(buildIdentifier)
    }
    guard sourceDateEpoch > 0 else {
      throw DoryFirmwareManifestError.invalidSourceDateEpoch(sourceDateEpoch)
    }
    for (name, digest) in [
      ("platformConfiguration", platformConfigurationSHA256),
      ("toolchain", toolchainSHA256),
      ("firmwareCode", firmwareCodeSHA256),
      ("variableStoreTemplate", variableStoreTemplateSHA256),
      ("sbom", sbomSHA256),
    ] where !DoryFirmwareSourcePin.isLowercaseHex(digest, count: 64) {
      throw DoryFirmwareManifestError.invalidSHA256(name: name, value: digest)
    }
    guard firmwareCodeByteCount > 0,
      firmwareCodeByteCount <= platform.maximumFirmwareCodeBytes,
      firmwareCodeByteCount % 4_096 == 0
    else {
      throw DoryFirmwareManifestError.invalidArtifactSize(
        name: "firmwareCode",
        value: firmwareCodeByteCount
      )
    }
    guard variableStoreTemplateByteCount > 0,
      variableStoreTemplateByteCount <= UInt64(DoryUEFIVariableStoreFile.maximumEncodedBytes)
    else {
      throw DoryFirmwareManifestError.invalidArtifactSize(
        name: "variableStoreTemplate",
        value: variableStoreTemplateByteCount
      )
    }
    guard reproducible else { throw DoryFirmwareManifestError.nonReproducibleBuild }
    self.schemaVersion = schemaVersion
    self.firmwareABIIdentity = firmwareABIIdentity
    self.machineABIIdentity = machineABIIdentity
    self.variableStoreFormatIdentity = variableStoreFormatIdentity
    self.variableBridgeIdentity = variableBridgeIdentity
    self.buildIdentifier = buildIdentifier
    self.source = source
    self.sourceDateEpoch = sourceDateEpoch
    self.platformConfigurationSHA256 = platformConfigurationSHA256
    self.toolchainSHA256 = toolchainSHA256
    self.firmwareCodeSHA256 = firmwareCodeSHA256
    self.firmwareCodeByteCount = firmwareCodeByteCount
    self.variableStoreTemplateSHA256 = variableStoreTemplateSHA256
    self.variableStoreTemplateByteCount = variableStoreTemplateByteCount
    self.sbomSHA256 = sbomSHA256
    self.secureBootPolicy = secureBootPolicy
    self.reproducible = reproducible
  }

  public func verify(
    firmwareCode: Data,
    variableStoreTemplate: Data,
    sbom: Data
  ) throws {
    try Self.verify(
      name: "firmwareCode",
      data: firmwareCode,
      expectedBytes: firmwareCodeByteCount,
      expectedSHA256: firmwareCodeSHA256
    )
    try Self.verify(
      name: "variableStoreTemplate",
      data: variableStoreTemplate,
      expectedBytes: variableStoreTemplateByteCount,
      expectedSHA256: variableStoreTemplateSHA256
    )
    try Self.verify(
      name: "sbom",
      data: sbom,
      expectedBytes: nil,
      expectedSHA256: sbomSHA256
    )
  }

  public var platform: DoryFirmwarePlatform {
    DoryFirmwarePlatform.resolve(
      firmwareABIIdentity: firmwareABIIdentity,
      machineABIIdentity: machineABIIdentity,
      variableStoreFormatIdentity: variableStoreFormatIdentity,
      variableBridgeIdentity: variableBridgeIdentity
    )!
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case schemaVersion, firmwareABIIdentity, machineABIIdentity
    case variableStoreFormatIdentity, variableBridgeIdentity, buildIdentifier, source
    case sourceDateEpoch, platformConfigurationSHA256, toolchainSHA256
    case firmwareCodeSHA256, firmwareCodeByteCount
    case variableStoreTemplateSHA256, variableStoreTemplateByteCount
    case sbomSHA256, secureBootPolicy, reproducible
  }

  public init(from decoder: Decoder) throws {
    try rejectUnknownFirmwareFields(
      from: decoder,
      allowed: Set(CodingKeys.allCases.map(\.rawValue)),
      type: "DoryFirmwareArtifactManifest"
    )
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      schemaVersion: container.decode(UInt32.self, forKey: .schemaVersion),
      firmwareABIIdentity: container.decode(String.self, forKey: .firmwareABIIdentity),
      machineABIIdentity: container.decode(String.self, forKey: .machineABIIdentity),
      variableStoreFormatIdentity: container.decode(
        String.self,
        forKey: .variableStoreFormatIdentity
      ),
      variableBridgeIdentity: container.decode(String.self, forKey: .variableBridgeIdentity),
      buildIdentifier: container.decode(String.self, forKey: .buildIdentifier),
      source: container.decode(DoryFirmwareSourcePin.self, forKey: .source),
      sourceDateEpoch: container.decode(UInt64.self, forKey: .sourceDateEpoch),
      platformConfigurationSHA256: container.decode(
        String.self,
        forKey: .platformConfigurationSHA256
      ),
      toolchainSHA256: container.decode(String.self, forKey: .toolchainSHA256),
      firmwareCodeSHA256: container.decode(String.self, forKey: .firmwareCodeSHA256),
      firmwareCodeByteCount: container.decode(UInt64.self, forKey: .firmwareCodeByteCount),
      variableStoreTemplateSHA256: container.decode(
        String.self,
        forKey: .variableStoreTemplateSHA256
      ),
      variableStoreTemplateByteCount: container.decode(
        UInt64.self,
        forKey: .variableStoreTemplateByteCount
      ),
      sbomSHA256: container.decode(String.self, forKey: .sbomSHA256),
      secureBootPolicy: container.decode(
        DoryFirmwareSecureBootPolicy.self, forKey: .secureBootPolicy),
      reproducible: container.decode(Bool.self, forKey: .reproducible)
    )
  }

  private static func verify(
    name: String,
    data: Data,
    expectedBytes: UInt64?,
    expectedSHA256: String
  ) throws {
    if let expectedBytes, UInt64(data.count) != expectedBytes {
      throw DoryFirmwareManifestError.artifactSizeMismatch(
        name: name,
        expected: expectedBytes,
        actual: UInt64(data.count)
      )
    }
    let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard actual == expectedSHA256 else {
      throw DoryFirmwareManifestError.artifactDigestMismatch(
        name: name,
        expected: expectedSHA256,
        actual: actual
      )
    }
  }

  private static func isSafeBuildIdentifier(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    return (1...128).contains(bytes.count)
      && bytes.allSatisfy {
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
          || $0 == 45 || $0 == 46 || $0 == 64 || $0 == 95
      }
  }
}

public enum DoryFirmwareManifestError: Error, Sendable, Equatable {
  case unsupportedSchemaVersion(UInt32)
  case incompatibleFirmwareABI(String)
  case incompatibleMachineABI(String)
  case incompatibleVariableStore(String)
  case incompatibleVariableBridge(String)
  case invalidSourceRepository(String)
  case invalidSourceRevision(String)
  case invalidSourceDateEpoch(UInt64)
  case invalidBuildIdentifier(String)
  case invalidSHA256(name: String, value: String)
  case invalidArtifactSize(name: String, value: UInt64)
  case nonReproducibleBuild
  case artifactSizeMismatch(name: String, expected: UInt64, actual: UInt64)
  case artifactDigestMismatch(name: String, expected: String, actual: String)
}
