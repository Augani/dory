import Foundation

/// Immutable firmware inputs admitted together under one signed/reproducible manifest.
///
/// Callers cannot construct a partially verified set: code, initial variables, and SBOM are
/// authenticated as one unit before any bytes become eligible for a guest mapping.
public struct DoryVerifiedFirmwareArtifacts: Sendable {
  public let manifest: DoryFirmwareArtifactManifest
  public let firmwareCode: Data
  public let variableStoreTemplate: Data
  public let initialVariableStore: DoryUEFIVariableStoreSnapshot
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
    let initialVariableStore = try DoryUEFIVariableStoreSnapshot.decodeCanonicalTemplate(
      variableStoreTemplate
    )
    guard initialVariableStore.platform == manifest.platform else {
      throw DoryVerifiedFirmwareArtifactsError.incompatibleVariableStorePlatform(
        manifest: manifest.platform,
        variableStore: initialVariableStore.platform
      )
    }
    guard initialVariableStore.generation == 1 else {
      throw DoryVerifiedFirmwareArtifactsError.invalidInitialVariableStoreGeneration(
        initialVariableStore.generation
      )
    }
    self.manifest = manifest
    self.firmwareCode = firmwareCode
    self.variableStoreTemplate = variableStoreTemplate
    self.initialVariableStore = initialVariableStore
    self.sbom = sbom
  }
}

public enum DoryVerifiedFirmwareArtifactsError: Error, Sendable, Equatable {
  case incompatibleVariableStorePlatform(
    manifest: DoryFirmwarePlatform,
    variableStore: DoryFirmwarePlatform
  )
  case invalidInitialVariableStoreGeneration(UInt64)
}
