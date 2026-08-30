import CryptoKit
import Foundation

public enum DoryFirmwareBundleLayout {
  public static let manifestFileName = "manifest.json"
  public static let firmwareCodeFileName = "firmware-code.fd"
  public static let variableStoreTemplateFileName = "variable-store-template.json"
  public static let sbomFileName = "sbom.json"
}

public struct DoryFirmwareBundleBuildInput: Sendable {
  public let platform: DoryFirmwarePlatform
  public let buildIdentifier: String
  public let source: DoryFirmwareSourcePin
  public let sourceDateEpoch: UInt64
  public let platformConfiguration: Data
  public let toolchainDescriptor: Data
  public let firmwareCode: Data
  public let secureBootPolicy: DoryFirmwareSecureBootPolicy

  public init(
    platform: DoryFirmwarePlatform = .armVirtV1,
    buildIdentifier: String,
    source: DoryFirmwareSourcePin,
    sourceDateEpoch: UInt64,
    platformConfiguration: Data,
    toolchainDescriptor: Data,
    firmwareCode: Data,
    secureBootPolicy: DoryFirmwareSecureBootPolicy
  ) {
    self.platform = platform
    self.buildIdentifier = buildIdentifier
    self.source = source
    self.sourceDateEpoch = sourceDateEpoch
    self.platformConfiguration = platformConfiguration
    self.toolchainDescriptor = toolchainDescriptor
    self.firmwareCode = firmwareCode
    self.secureBootPolicy = secureBootPolicy
  }
}

public struct DoryFirmwareBundle: Sendable {
  public let manifest: DoryFirmwareArtifactManifest
  public let manifestData: Data
  public let firmwareCode: Data
  public let variableStoreTemplate: Data
  public let sbom: Data

  public func write(to directory: URL) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o755]
    )
    try Self.publish(
      manifestData,
      to: directory.appendingPathComponent(DoryFirmwareBundleLayout.manifestFileName)
    )
    try Self.publish(
      firmwareCode,
      to: directory.appendingPathComponent(DoryFirmwareBundleLayout.firmwareCodeFileName)
    )
    try Self.publish(
      variableStoreTemplate,
      to: directory.appendingPathComponent(
        DoryFirmwareBundleLayout.variableStoreTemplateFileName
      )
    )
    try Self.publish(
      sbom,
      to: directory.appendingPathComponent(DoryFirmwareBundleLayout.sbomFileName)
    )
  }

  private static func publish(_ data: Data, to destination: URL) throws {
    let temporary = destination.deletingLastPathComponent().appendingPathComponent(
      ".\(destination.lastPathComponent).\(UUID().uuidString.lowercased()).partial"
    )
    do {
      try data.write(to: temporary, options: [.atomic])
      if FileManager.default.fileExists(atPath: destination.path) {
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
      } else {
        try FileManager.default.moveItem(at: temporary, to: destination)
      }
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
  }
}

public enum DoryFirmwareBundleBuilder {
  public static func build(_ input: DoryFirmwareBundleBuildInput) throws -> DoryFirmwareBundle {
    let variables = try DoryUEFIVariableStoreSnapshot().canonicalData()
    let platformDigest = digest(input.platformConfiguration)
    let toolchainDigest = digest(input.toolchainDescriptor)
    let firmwareDigest = digest(input.firmwareCode)
    let variableDigest = digest(variables)
    let sbom = try canonicalJSON(
      CycloneDXSBOM(
        sourceDateEpoch: input.sourceDateEpoch,
        buildIdentifier: input.buildIdentifier,
        source: input.source,
        platform: input.platform,
        platformConfigurationSHA256: platformDigest,
        toolchainSHA256: toolchainDigest,
        firmwareCodeSHA256: firmwareDigest
      )
    )
    let manifest = try DoryFirmwareArtifactManifest(
      platform: input.platform,
      buildIdentifier: input.buildIdentifier,
      source: input.source,
      sourceDateEpoch: input.sourceDateEpoch,
      platformConfigurationSHA256: platformDigest,
      toolchainSHA256: toolchainDigest,
      firmwareCodeSHA256: firmwareDigest,
      firmwareCodeByteCount: UInt64(input.firmwareCode.count),
      variableStoreTemplateSHA256: variableDigest,
      variableStoreTemplateByteCount: UInt64(variables.count),
      sbomSHA256: digest(sbom),
      secureBootPolicy: input.secureBootPolicy,
      reproducible: true
    )
    let manifestData = try canonicalJSON(manifest)
    return DoryFirmwareBundle(
      manifest: manifest,
      manifestData: manifestData,
      firmwareCode: input.firmwareCode,
      variableStoreTemplate: variables,
      sbom: sbom
    )
  }

  private static func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value) + Data("\n".utf8)
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

private struct CycloneDXSBOM: Encodable {
  let bomFormat = "CycloneDX"
  let specVersion = "1.6"
  let version = 1
  let metadata: Metadata
  let components: [Component]

  init(
    sourceDateEpoch: UInt64,
    buildIdentifier: String,
    source: DoryFirmwareSourcePin,
    platform: DoryFirmwarePlatform,
    platformConfigurationSHA256: String,
    toolchainSHA256: String,
    firmwareCodeSHA256: String
  ) {
    metadata = Metadata(
      timestamp: ISO8601DateFormatter().string(
        from: Date(timeIntervalSince1970: TimeInterval(sourceDateEpoch))
      ),
      component: Component(
        type: "firmware",
        name: platform.sbomComponentName,
        version: buildIdentifier,
        hashes: [.init(alg: "SHA-256", content: firmwareCodeSHA256)],
        externalReferences: nil,
        properties: [
          .init(name: "dory:firmware-abi", value: platform.firmwareABIIdentity),
          .init(name: "dory:machine-abi", value: platform.machineABIIdentity),
        ]
      )
    )
    components = [
      Component(
        type: "library",
        name: "EDK II",
        version: source.revision,
        hashes: nil,
        externalReferences: [
          .init(type: "vcs", url: "\(source.repository)#\(source.revision)")
        ],
        properties: nil
      ),
      Component(
        type: "data",
        name: "\(platform.sbomComponentName) platform configuration",
        version: "1",
        hashes: [.init(alg: "SHA-256", content: platformConfigurationSHA256)],
        externalReferences: nil,
        properties: nil
      ),
      Component(
        type: "application",
        name: "Dory firmware toolchain",
        version: "1",
        hashes: [.init(alg: "SHA-256", content: toolchainSHA256)],
        externalReferences: nil,
        properties: nil
      ),
    ]
  }

  struct Metadata: Encodable {
    let timestamp: String
    let component: Component
  }

  struct Component: Encodable {
    let type: String
    let name: String
    let version: String
    let hashes: [Hash]?
    let externalReferences: [ExternalReference]?
    let properties: [Property]?
  }

  struct Hash: Encodable {
    let alg: String
    let content: String
  }

  struct ExternalReference: Encodable {
    let type: String
    let url: String
  }

  struct Property: Encodable {
    let name: String
    let value: String
  }
}
