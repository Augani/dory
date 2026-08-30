import Foundation

/// Immutable firmware inputs admitted together under one signed/reproducible manifest.
///
/// Callers cannot construct a partially verified set: code, initial variables, and SBOM are
/// authenticated as one unit before any bytes become eligible for a guest mapping.
public struct DoryVerifiedFirmwareArtifacts: Sendable {
  public let manifest: DoryFirmwareArtifactManifest
  public let firmwareCode: Data
  public let variableStoreTemplate: Data
  public let sbom: Data

  public init(
    manifest: DoryFirmwareArtifactManifest,
    firmwareCode: Data,
    variableStoreTemplate: Data,
    sbom: Data
  ) throws {
    try manifest.verify(
      firmwareCode: firmwareCode,
      variableStoreTemplate: variableStoreTemplate,
      sbom: sbom
    )
    self.manifest = manifest
    self.firmwareCode = firmwareCode
    self.variableStoreTemplate = variableStoreTemplate
    self.sbom = sbom
  }
}
