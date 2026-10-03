import CryptoKit
import Darwin
import Foundation
import Virtualization

private struct DoryVZMacSystemDiskResizeJournal: Codable {
  let previousBytes: UInt64
  let requestedBytes: UInt64
}

private struct DoryVZMacDataDiskResizeJournal: Codable {
  let index: Int
  let fileName: String
  let previousBytes: UInt64
  let requestedBytes: UInt64
}

public struct DoryVZMacDisplayRepairReceipt: Codable, Sendable, Equatable {
  public static let schema = "dory.vzmac-display-repair@1"

  public let schema: String
  public let repairedAt: String
  public let originalDisplayCount: Int
  public let selectedDisplayIndex: Int
  public let selectedDisplay: DoryVZMacDisplay
  public let previousInstallationState: DoryVZMacMachineInstallationState
  public let repairedInstallationState: DoryVZMacMachineInstallationState
  public let originalManifestSHA256: String
  public let repairedManifestSHA256: String
  public let originalManifestBackupName: String
  public let preservedSavedStateName: String?
  public let preservedManagedSavedStateName: String?
  public let preservedSavedStateIdentity: String?
  public let preservedManagedSavedStateIdentity: String?
}

/// Read-only recovery input, not permission to launch or resume this incompatible bundle.
public struct DoryVZMacDisplayRepairAssessment: Sendable, Equatable {
  public let originalManifestSHA256: String
  public let displays: [DoryVZMacDisplay]
  public let pendingSelectedDisplayIndex: Int?
  public let preservesSavedState: Bool
  public let bundleRepairCompleted: Bool
  public let candidateManifest: DoryVZMacMachineManifest
}

public enum DoryVZMacMachineBundleError: Error, Sendable, Equatable, CustomStringConvertible {
  case destinationExists(String)
  case invalidRestoreImage(String)
  case unsupportedRestoreImage(String)
  case missingSupportedConfiguration
  case cloneRequiresStoppedMachine
  case diskResizeRequiresStoppedMachine(DoryVZMacMachineInstallationState)
  case restoreImageProvenanceMismatch(String)
  case invalidBundle(String)
  case invalidNetworkAddress(String)
  case invalidIdentity(String)
  case filesystem(String, Int32)

  public var description: String {
    switch self {
    case .destinationExists(let path): "VZMac machine destination already exists: \(path)"
    case .invalidRestoreImage(let detail): "invalid macOS restore image: \(detail)"
    case .unsupportedRestoreImage(let build):
      "macOS restore image \(build) is not supported on this host"
    case .missingSupportedConfiguration:
      "the macOS restore image has no configuration supported by this host"
    case .cloneRequiresStoppedMachine:
      "VZMac cold clone requires an installed, stopped source machine"
    case .diskResizeRequiresStoppedMachine(let state):
      "VZMac disk resize requires a prepared or stopped machine, not \(state.rawValue)"
    case .restoreImageProvenanceMismatch(let detail):
      "macOS restore image provenance mismatch: \(detail)"
    case .invalidBundle(let detail): "invalid VZMac machine bundle: \(detail)"
    case .invalidNetworkAddress(let address):
      "macOS virtual machine network address is not a locally administered unicast MAC: \(address)"
    case .invalidIdentity(let detail): "invalid VZMac platform identity: \(detail)"
    case .filesystem(let operation, let code): "\(operation) failed with errno \(code)"
    }
  }
}

public enum DoryVZMacMachineInstallationState: String, Codable, Sendable, Equatable {
  case prepared
  case installing
  case installFailed = "install-failed"
  case stopped
  case suspending
  case suspended
  case restoring
}

public enum DoryVZMacMachineOrigin: String, Codable, Sendable, Equatable {
  case created
  case cloned
}

public struct DoryVZMacMachineManifest: Codable, Sendable, Equatable {
  public static let schema = "dory.vzmac-machine@3"

  public let schema: String
  public let createdAt: String
  public let installationState: DoryVZMacMachineInstallationState
  public let origin: DoryVZMacMachineOrigin
  public let parentMachineIdentifierSHA256: String?
  public let restoreImageBuild: String
  public let restoreImageVersion: String
  public let restoreImageSourceURL: String
  public let restoreImageBytes: UInt64
  public let restoreImageSHA256: String
  public let hardwareModelSHA256: String
  public let machineIdentifierSHA256: String
  public let macAddress: String
  public let resources: DoryVZMacResourcePlan

  func replacingInstallationState(_ state: DoryVZMacMachineInstallationState) -> Self {
    Self(
      createdAt: createdAt, installationState: state, origin: origin,
      parentMachineIdentifierSHA256: parentMachineIdentifierSHA256,
      restoreImageBuild: restoreImageBuild, restoreImageVersion: restoreImageVersion,
      restoreImageSourceURL: restoreImageSourceURL, restoreImageBytes: restoreImageBytes,
      restoreImageSHA256: restoreImageSHA256, hardwareModelSHA256: hardwareModelSHA256,
      machineIdentifierSHA256: machineIdentifierSHA256, macAddress: macAddress, resources: resources
    )
  }

  public init(
    schema: String = Self.schema,
    createdAt: String,
    installationState: DoryVZMacMachineInstallationState,
    origin: DoryVZMacMachineOrigin,
    parentMachineIdentifierSHA256: String?,
    restoreImageBuild: String,
    restoreImageVersion: String,
    restoreImageSourceURL: String,
    restoreImageBytes: UInt64,
    restoreImageSHA256: String,
    hardwareModelSHA256: String,
    machineIdentifierSHA256: String,
    macAddress: String,
    resources: DoryVZMacResourcePlan
  ) {
    self.schema = schema
    self.createdAt = createdAt
    self.installationState = installationState
    self.origin = origin
    self.parentMachineIdentifierSHA256 = parentMachineIdentifierSHA256
    self.restoreImageBuild = restoreImageBuild
    self.restoreImageVersion = restoreImageVersion
    self.restoreImageSourceURL = restoreImageSourceURL
    self.restoreImageBytes = restoreImageBytes
    self.restoreImageSHA256 = restoreImageSHA256
    self.hardwareModelSHA256 = hardwareModelSHA256
    self.machineIdentifierSHA256 = machineIdentifierSHA256
    self.macAddress = macAddress
    self.resources = resources
  }

  public func validate() throws {
    guard schema == Self.schema else {
      throw DoryVZMacMachineBundleError.invalidBundle("unsupported manifest schema")
    }
    guard ISO8601DateFormatter().date(from: createdAt) != nil else {
      throw DoryVZMacMachineBundleError.invalidBundle("createdAt is not canonical ISO-8601")
    }
    guard !restoreImageBuild.isEmpty, !restoreImageVersion.isEmpty else {
      throw DoryVZMacMachineBundleError.invalidBundle("restore image identity is incomplete")
    }
    switch (origin, parentMachineIdentifierSHA256) {
    case (.created, nil):
      break
    case (.cloned, .some(let digest)) where isCanonicalSHA256(digest):
      break
    default:
      throw DoryVZMacMachineBundleError.invalidBundle("machine lineage is invalid")
    }
    guard let sourceURL = URL(string: restoreImageSourceURL),
      sourceURL.scheme == "https" || sourceURL.isFileURL,
      restoreImageBytes > 0
    else {
      throw DoryVZMacMachineBundleError.invalidBundle(
        "restore image source or byte count is invalid"
      )
    }
    for digest in [restoreImageSHA256, hardwareModelSHA256, machineIdentifierSHA256] {
      guard isCanonicalSHA256(digest) else {
        throw DoryVZMacMachineBundleError.invalidBundle("SHA-256 digest is not canonical")
      }
    }
    guard let address = VZMACAddress(string: macAddress),
      address.isUnicastAddress,
      address.isLocallyAdministeredAddress
    else {
      throw DoryVZMacMachineBundleError.invalidBundle(
        "network address is not a locally administered unicast MAC"
      )
    }
  }
}

public struct DoryVZMacMachineBundle: Sendable {
  public static let manifestName = "machine.json"
  public static let diskName = "disk.img"
  public static let dataDisksDirectoryName = "data-disks"
  public static let auxiliaryStorageName = "auxiliary-storage"
  public static let hardwareModelName = "hardware-model.bin"
  public static let machineIdentifierName = "machine-identifier.bin"
  public static let installJournalName = "install-operation.json"
  private static let diskResizeJournalName = "system-disk-resize.json"
  public static let suspendedStateDirectoryName = "suspended-state"
  public static let displayRepairReceiptName = "display-topology-repair.json"
  public static let displayRepairJournalName = "display-topology-repair.pending.json"
  public static let preDisplayRepairManifestName = "machine.before-display-topology-repair.json"
  public static let incompatibleSavedStateName = "suspended-state.incompatible-display-topology"
  public static let managedSavedStateName = "saved-state"
  public static let incompatibleManagedSavedStateName = "saved-state.incompatible-display-topology"
  public static let maximumManifestBytes = 1_048_576

  public let rootURL: URL
  public let manifest: DoryVZMacMachineManifest

  public var diskURL: URL { rootURL.appendingPathComponent(Self.diskName) }
  public var dataDisksDirectoryURL: URL {
    rootURL.appendingPathComponent(Self.dataDisksDirectoryName, isDirectory: true)
  }
  public var dataDiskURLs: [URL] {
    manifest.resources.dataDisks.map {
      dataDisksDirectoryURL.appendingPathComponent($0.fileName, isDirectory: false)
    }
  }
  public var auxiliaryStorageURL: URL {
    rootURL.appendingPathComponent(Self.auxiliaryStorageName)
  }
  public var hardwareModelURL: URL {
    rootURL.appendingPathComponent(Self.hardwareModelName)
  }
  public var machineIdentifierURL: URL {
    rootURL.appendingPathComponent(Self.machineIdentifierName)
  }
  public var manifestURL: URL { rootURL.appendingPathComponent(Self.manifestName) }
  public var installJournalURL: URL { rootURL.appendingPathComponent(Self.installJournalName) }
  private var diskResizeJournalURL: URL {
    rootURL.appendingPathComponent(Self.diskResizeJournalName)
  }
  private func dataDiskResizeJournalURL(index: Int) -> URL {
    rootURL.appendingPathComponent("data-disk-\(index + 1)-resize.json")
  }
  public var suspendedStateURL: URL {
    rootURL.appendingPathComponent(Self.suspendedStateDirectoryName, isDirectory: true)
  }

  /// Read-only admission before a daemon creation journal or sparse disk is allocated.
  /// `prepare` repeats these checks against the IPSW it actually consumes, so a replaced
  /// image cannot inherit an earlier preflight result.
  public static func preflightRestoreImage(
    at restoreImageURL: URL,
    requestedCPUCount: Int? = nil,
    requestedMemoryBytes: UInt64? = nil,
    diskBytes: UInt64 = 80 * DoryVZMacResourcePlan.gibibyte,
    dataDiskBytes: [UInt64] = []
  ) async throws -> DoryVZMacResourcePlan {
    guard restoreImageURL.isFileURL else {
      throw DoryVZMacMachineBundleError.invalidRestoreImage("URL is not a local file")
    }
    try requireRegularFile(restoreImageURL, label: "restore image")
    let restoreImage = try await VZMacOSRestoreImage.image(from: restoreImageURL)
    guard restoreImage.isSupported else {
      throw DoryVZMacMachineBundleError.unsupportedRestoreImage(restoreImage.buildVersion)
    }
    guard let requirements = restoreImage.mostFeaturefulSupportedConfiguration else {
      throw DoryVZMacMachineBundleError.missingSupportedConfiguration
    }
    let baseResources = try DoryVZMacResourcePlan(
      requestedCPUCount: requestedCPUCount,
      requestedMemoryBytes: requestedMemoryBytes,
      requestedDiskBytes: diskBytes,
      requirements: requirements
    )
    return try DoryVZMacResourcePlan(
      requestedCPUCount: baseResources.cpuCount,
      requestedMemoryBytes: baseResources.memoryBytes,
      requestedDiskBytes: baseResources.diskBytes,
      requestedDisplays: baseResources.displays,
      requestedDataDiskBytes: dataDiskBytes,
      minimumCPUCount: baseResources.cpuCount,
      minimumMemoryBytes: baseResources.memoryBytes,
      maximumCPUCount: baseResources.cpuCount,
      maximumMemoryBytes: baseResources.memoryBytes
    )
  }

  public static func prepare(
    at destination: URL,
    restoreImageURL: URL,
    restoreImageSourceURL: URL? = nil,
    requestedCPUCount: Int? = nil,
    requestedMemoryBytes: UInt64? = nil,
    diskBytes: UInt64 = 80 * DoryVZMacResourcePlan.gibibyte,
    dataDiskBytes: [UInt64] = [],
    macAddress: String? = nil
  ) async throws -> Self {
    guard restoreImageURL.isFileURL else {
      throw DoryVZMacMachineBundleError.invalidRestoreImage("URL is not a local file")
    }
    try requireRegularFile(restoreImageURL, label: "restore image")
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      throw DoryVZMacMachineBundleError.destinationExists(destination.path)
    }
    let selectedMACAddress = try Self.selectedMACAddress(macAddress)
    let restoreImage = try await VZMacOSRestoreImage.image(from: restoreImageURL)
    guard restoreImage.isSupported else {
      throw DoryVZMacMachineBundleError.unsupportedRestoreImage(restoreImage.buildVersion)
    }
    guard let requirements = restoreImage.mostFeaturefulSupportedConfiguration else {
      throw DoryVZMacMachineBundleError.missingSupportedConfiguration
    }
    let baseResources = try DoryVZMacResourcePlan(
      requestedCPUCount: requestedCPUCount,
      requestedMemoryBytes: requestedMemoryBytes,
      requestedDiskBytes: diskBytes,
      requirements: requirements
    )
    let resources = try DoryVZMacResourcePlan(
      requestedCPUCount: baseResources.cpuCount,
      requestedMemoryBytes: baseResources.memoryBytes,
      requestedDiskBytes: baseResources.diskBytes,
      requestedDisplays: baseResources.displays,
      requestedDataDiskBytes: dataDiskBytes,
      minimumCPUCount: baseResources.cpuCount,
      minimumMemoryBytes: baseResources.memoryBytes,
      maximumCPUCount: baseResources.cpuCount,
      maximumMemoryBytes: baseResources.memoryBytes
    )
    let parent = destination.deletingLastPathComponent()
    try requireDirectory(parent, label: "machine parent")
    let staging = parent.appendingPathComponent(
      ".\(destination.lastPathComponent).creating-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
    )
    var committed = false
    defer {
      if !committed { try? FileManager.default.removeItem(at: staging) }
    }

    let hardwareModelData = requirements.hardwareModel.dataRepresentation
    let machineIdentifierData = VZMacMachineIdentifier().dataRepresentation
    let hardwareURL = staging.appendingPathComponent(Self.hardwareModelName)
    let identifierURL = staging.appendingPathComponent(Self.machineIdentifierName)
    try DoryVZMacMetadataFile.write(hardwareModelData, to: hardwareURL)
    try DoryVZMacMetadataFile.write(machineIdentifierData, to: identifierURL)
    _ = try VZMacAuxiliaryStorage(
      creatingStorageAt: staging.appendingPathComponent(Self.auxiliaryStorageName),
      hardwareModel: requirements.hardwareModel,
      options: []
    )
    try createSparseFile(
      at: staging.appendingPathComponent(Self.diskName),
      size: resources.diskBytes
    )
    if !resources.dataDisks.isEmpty {
      let dataDisksDirectory = staging.appendingPathComponent(
        Self.dataDisksDirectoryName,
        isDirectory: true
      )
      try FileManager.default.createDirectory(
        at: dataDisksDirectory,
        withIntermediateDirectories: false
      )
      for disk in resources.dataDisks {
        try createSparseFile(
          at: dataDisksDirectory.appendingPathComponent(disk.fileName),
          size: disk.byteCount
        )
      }
    }
    let version = restoreImage.operatingSystemVersion
    let restoreAttributes = try FileManager.default.attributesOfItem(
      atPath: restoreImageURL.path
    )
    guard let restoreByteCount = restoreAttributes[.size] as? NSNumber,
      restoreByteCount.uint64Value > 0
    else {
      throw DoryVZMacMachineBundleError.invalidRestoreImage("file size is invalid")
    }
    let manifest = DoryVZMacMachineManifest(
      createdAt: ISO8601DateFormatter().string(from: Date()),
      installationState: .prepared,
      origin: .created,
      parentMachineIdentifierSHA256: nil,
      restoreImageBuild: restoreImage.buildVersion,
      restoreImageVersion:
        "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
      restoreImageSourceURL: (restoreImageSourceURL ?? restoreImageURL).absoluteString,
      restoreImageBytes: restoreByteCount.uint64Value,
      restoreImageSHA256: try sha256(of: restoreImageURL),
      hardwareModelSHA256: sha256(of: hardwareModelData),
      machineIdentifierSHA256: sha256(of: machineIdentifierData),
      macAddress: selectedMACAddress,
      resources: resources
    )
    try manifest.validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try DoryVZMacMetadataFile.write(
      encoder.encode(manifest), to: staging.appendingPathComponent(Self.manifestName)
    )
    try DoryVZMacBundlePublication.publish(
      staging: staging, to: destination, relativeFiles: Self.artifactPaths(for: resources)
    )
    committed = true
    return try load(from: destination)
  }

  public static func load(from rootURL: URL) throws -> Self {
    try requireDirectory(rootURL, label: "machine root")
    // Even an unreadable or linked intent is deny-only. Only the explicit repair path
    // may reconcile it; ordinary load must never silently change display/RAM compatibility.
    guard try !DoryVZMacMetadataFile.entryExists(
      at: rootURL.appendingPathComponent(Self.displayRepairJournalName, isDirectory: false)
    ) else {
      throw DoryVZMacMachineBundleError.invalidBundle(
        "display-topology repair is unfinished; rerun the explicit repair with the same display choice"
      )
    }
    let manifestURL = rootURL.appendingPathComponent(Self.manifestName)
    let manifest: DoryVZMacMachineManifest
    do {
      manifest = try JSONDecoder().decode(
        DoryVZMacMachineManifest.self,
        from: DoryVZMacMetadataFile.read(
          from: manifestURL, maximumBytes: Self.maximumManifestBytes
        )
      )
    } catch {
      throw DoryVZMacMachineBundleError.invalidBundle("manifest cannot be safely read or decoded")
    }
    try manifest.validate()
    var recoveredManifest = try recoverPendingSystemDiskResize(
      at: rootURL,
      manifest: manifest
    )
    for index in recoveredManifest.resources.dataDisks.indices {
      recoveredManifest = try recoverPendingDataDiskResize(
        at: rootURL,
        manifest: recoveredManifest,
        index: index
      )
    }
    let bundle = Self(rootURL: rootURL, manifest: recoveredManifest)
    try validateArtifacts(in: bundle)
    return bundle
  }

  static func validateArtifacts(in bundle: Self) throws {
    let manifest = bundle.manifest
    for (url, name) in [
      (bundle.diskURL, Self.diskName),
      (bundle.auxiliaryStorageURL, Self.auxiliaryStorageName),
      (bundle.hardwareModelURL, Self.hardwareModelName),
      (bundle.machineIdentifierURL, Self.machineIdentifierName),
    ] {
      try requireRegularFile(url, label: name)
    }
    let diskAttributes = try FileManager.default.attributesOfItem(atPath: bundle.diskURL.path)
    guard let diskSize = diskAttributes[.size] as? NSNumber,
      diskSize.uint64Value == manifest.resources.diskBytes
    else {
      throw DoryVZMacMachineBundleError.invalidBundle("disk size does not match manifest")
    }
    if !manifest.resources.dataDisks.isEmpty {
      try requireDirectory(bundle.dataDisksDirectoryURL, label: Self.dataDisksDirectoryName)
      for (disk, url) in zip(manifest.resources.dataDisks, bundle.dataDiskURLs) {
        try requireRegularFile(url, label: "data disk \(disk.fileName)")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber,
          size.uint64Value == disk.byteCount
        else {
          throw DoryVZMacMachineBundleError.invalidBundle(
            "data disk \(disk.fileName) size does not match manifest"
          )
        }
      }
    }
    let hardwareData = try DoryVZMacMetadataFile.read(from: bundle.hardwareModelURL)
    let identifierData = try DoryVZMacMetadataFile.read(from: bundle.machineIdentifierURL)
    guard sha256(of: hardwareData) == manifest.hardwareModelSHA256,
      VZMacHardwareModel(dataRepresentation: hardwareData) != nil
    else {
      throw DoryVZMacMachineBundleError.invalidIdentity("hardware model mismatch")
    }
    guard sha256(of: identifierData) == manifest.machineIdentifierSHA256,
      VZMacMachineIdentifier(dataRepresentation: identifierData) != nil
    else {
      throw DoryVZMacMachineBundleError.invalidIdentity("machine identifier mismatch")
    }
    _ = VZMacAuxiliaryStorage(contentsOf: bundle.auxiliaryStorageURL)
  }

  public static func assessPersistedDisplayTopologyRepair(
    at rootURL: URL, preserveManagedSavedState: Bool = false
  ) throws -> DoryVZMacDisplayRepairAssessment? {
    guard let assessment = try DoryVZMacDisplayRepair.inspect(
      at: rootURL, preserveManagedSavedState: preserveManagedSavedState
    ) else { return nil }
    try validateArtifacts(in: Self(rootURL: rootURL, manifest: assessment.candidateManifest))
    return assessment
  }

  /// Explicitly repairs a persisted pre-one-display manifest for a cold boot. The original
  /// manifest is retained byte-for-byte and an incompatible suspended-state directory is moved
  /// aside rather than deleted. A failed/interrupted attempt resumes only through this
  /// explicit entry point. It never runs during ordinary load/import/configuration building.
  public static func repairPersistedDisplayTopologyForColdBoot(
    at rootURL: URL,
    keepingDisplayAt selectedDisplayIndex: Int = 0,
    preserveManagedSavedState: Bool = false,
    expectedOriginalManifestSHA256: String? = nil
  ) throws -> DoryVZMacDisplayRepairReceipt {
    try DoryVZMacDisplayRepair.perform(at: rootURL, keepingDisplayAt: selectedDisplayIndex,
      preserveManagedSavedState: preserveManagedSavedState,
      expectedOriginalManifestSHA256: expectedOriginalManifestSHA256)
  }

  /// Product lifecycle owners retain this exact lease through workspace publication.
  public static func repairPersistedDisplayTopologyForColdBoot(
    at rootURL: URL, holding lease: DoryVZMacMachineLease, keepingDisplayAt selectedDisplayIndex: Int,
    preserveManagedSavedState: Bool, expectedOriginalManifestSHA256: String
  ) throws -> DoryVZMacDisplayRepairReceipt {
    try DoryVZMacDisplayRepair.perform(at: rootURL, keepingDisplayAt: selectedDisplayIndex,
      preserveManagedSavedState: preserveManagedSavedState,
      expectedOriginalManifestSHA256: expectedOriginalManifestSHA256, holdingLease: lease)
  }

  public func hardwareModel() throws -> VZMacHardwareModel {
    let data = try DoryVZMacMetadataFile.read(from: hardwareModelURL)
    guard let model = VZMacHardwareModel(dataRepresentation: data) else {
      throw DoryVZMacMachineBundleError.invalidIdentity("hardware model cannot be restored")
    }
    return model
  }

  public func machineIdentifier() throws -> VZMacMachineIdentifier {
    let data = try DoryVZMacMetadataFile.read(from: machineIdentifierURL)
    guard let identifier = VZMacMachineIdentifier(dataRepresentation: data) else {
      throw DoryVZMacMachineBundleError.invalidIdentity(
        "machine identifier cannot be restored"
      )
    }
    return identifier
  }

  public func validateRestoreImage(at restoreImageURL: URL) async throws {
    guard restoreImageURL.isFileURL else {
      throw DoryVZMacMachineBundleError.restoreImageProvenanceMismatch(
        "candidate URL is not a local file"
      )
    }
    try requireRegularFile(restoreImageURL, label: "restore image")
    let attributes = try FileManager.default.attributesOfItem(atPath: restoreImageURL.path)
    guard let byteCount = attributes[.size] as? NSNumber,
      byteCount.uint64Value == manifest.restoreImageBytes
    else {
      throw DoryVZMacMachineBundleError.restoreImageProvenanceMismatch(
        "byte count differs from the prepared machine manifest"
      )
    }
    guard try sha256(of: restoreImageURL) == manifest.restoreImageSHA256 else {
      throw DoryVZMacMachineBundleError.restoreImageProvenanceMismatch(
        "SHA-256 differs from the prepared machine manifest"
      )
    }
    let restoreImage = try await VZMacOSRestoreImage.image(from: restoreImageURL)
    let version = restoreImage.operatingSystemVersion
    let versionString = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    guard restoreImage.buildVersion == manifest.restoreImageBuild,
      versionString == manifest.restoreImageVersion
    else {
      throw DoryVZMacMachineBundleError.restoreImageProvenanceMismatch(
        "build identity differs from the prepared machine manifest"
      )
    }
    guard restoreImage.isSupported else {
      throw DoryVZMacMachineBundleError.unsupportedRestoreImage(restoreImage.buildVersion)
    }
  }

  public func clone(to destination: URL, macAddress: String? = nil) throws -> Self {
    guard manifest.installationState == .stopped else {
      throw DoryVZMacMachineBundleError.cloneRequiresStoppedMachine
    }
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      throw DoryVZMacMachineBundleError.destinationExists(destination.path)
    }
    let selectedMACAddress = try Self.selectedMACAddress(macAddress)
    let sourceLease = try DoryVZMacMachineLease(rootURL: rootURL)
    defer { withExtendedLifetime(sourceLease) {} }
    // Recheck persisted state after acquiring the source lease, not a potentially stale
    // bundle value captured before another operation changed its installation state.
    let source = try Self.load(from: rootURL)
    let manifest = source.manifest
    guard manifest.installationState == .stopped else {
      throw DoryVZMacMachineBundleError.cloneRequiresStoppedMachine
    }
    let parent = destination.deletingLastPathComponent()
    try requireDirectory(parent, label: "clone parent")
    let staging = parent.appendingPathComponent(
      ".\(destination.lastPathComponent).cloning-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
    )
    var committed = false
    defer {
      if !committed { try? FileManager.default.removeItem(at: staging) }
    }
    for (source, name) in [
      (diskURL, Self.diskName),
      (auxiliaryStorageURL, Self.auxiliaryStorageName),
      (hardwareModelURL, Self.hardwareModelName),
    ] {
      try requireRegularFile(source, label: name)
      try cloneFile(
        from: source,
        to: staging.appendingPathComponent(name)
      )
    }
    if !manifest.resources.dataDisks.isEmpty {
      let destinationDataDisks = staging.appendingPathComponent(
        Self.dataDisksDirectoryName,
        isDirectory: true
      )
      try FileManager.default.createDirectory(
        at: destinationDataDisks,
        withIntermediateDirectories: false
      )
      for (disk, source) in zip(manifest.resources.dataDisks, source.dataDiskURLs) {
        try requireRegularFile(source, label: "data disk \(disk.fileName)")
        try cloneFile(
          from: source,
          to: destinationDataDisks.appendingPathComponent(disk.fileName)
        )
      }
    }
    let machineIdentifierData = VZMacMachineIdentifier().dataRepresentation
    try DoryVZMacMetadataFile.write(
      machineIdentifierData, to: staging.appendingPathComponent(Self.machineIdentifierName)
    )
    let clonedManifest = DoryVZMacMachineManifest(
      createdAt: ISO8601DateFormatter().string(from: Date()),
      installationState: .stopped,
      origin: .cloned,
      parentMachineIdentifierSHA256: manifest.machineIdentifierSHA256,
      restoreImageBuild: manifest.restoreImageBuild,
      restoreImageVersion: manifest.restoreImageVersion,
      restoreImageSourceURL: manifest.restoreImageSourceURL,
      restoreImageBytes: manifest.restoreImageBytes,
      restoreImageSHA256: manifest.restoreImageSHA256,
      hardwareModelSHA256: manifest.hardwareModelSHA256,
      machineIdentifierSHA256: sha256(of: machineIdentifierData),
      macAddress: selectedMACAddress,
      resources: manifest.resources
    )
    try clonedManifest.validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try DoryVZMacMetadataFile.write(
      encoder.encode(clonedManifest), to: staging.appendingPathComponent(Self.manifestName)
    )
    try DoryVZMacBundlePublication.publish(
      staging: staging, to: destination, relativeFiles: Self.artifactPaths(for: manifest.resources)
    )
    committed = true
    return try Self.load(from: destination)
  }

  static func artifactPaths(for resources: DoryVZMacResourcePlan) -> [String] {
    [manifestName, diskName, auxiliaryStorageName, hardwareModelName, machineIdentifierName]
      + resources.dataDisks.map { "\(dataDisksDirectoryName)/\($0.fileName)" }
  }

  /// Enlarges the managed APFS backing image while no VZ instance can have the disk open.
  /// Shrink is deliberately unsupported: it would require guest filesystem coordination and
  /// could truncate live APFS container blocks. The manifest is committed only after the image
  /// has been durably extended, so a caller never advertises capacity that the host file lacks.
  public func growSystemDisk(to requestedDiskBytes: UInt64) throws -> Self {
    guard manifest.installationState == .prepared || manifest.installationState == .stopped else {
      throw DoryVZMacMachineBundleError.diskResizeRequiresStoppedMachine(
        manifest.installationState
      )
    }
    let resizedResources = try manifest.resources.growingSystemDisk(
      to: requestedDiskBytes
    )
    let lease = try DoryVZMacMachineLease(rootURL: rootURL)
    defer { withExtendedLifetime(lease) {} }
    try requireRegularFile(diskURL, label: Self.diskName)
    let descriptor = open(diskURL.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw DoryVZMacMachineBundleError.filesystem("open system disk for resize", errno)
    }
    defer { close(descriptor) }
    var information = stat()
    guard fstat(descriptor, &information) == 0 else {
      throw DoryVZMacMachineBundleError.filesystem("inspect system disk for resize", errno)
    }
    guard (information.st_mode & S_IFMT) == S_IFREG,
      information.st_size >= 0,
      UInt64(information.st_size) == manifest.resources.diskBytes,
      requestedDiskBytes <= UInt64(Int64.max)
    else {
      throw DoryVZMacMachineBundleError.invalidBundle(
        "system disk changed before resize"
      )
    }
    try Self.writeSystemDiskResizeJournal(
      DoryVZMacSystemDiskResizeJournal(
        previousBytes: manifest.resources.diskBytes,
        requestedBytes: requestedDiskBytes
      ),
      to: diskResizeJournalURL
    )
    guard ftruncate(descriptor, off_t(requestedDiskBytes)) == 0 else {
      throw DoryVZMacMachineBundleError.filesystem("grow system disk", errno)
    }
    try DoryVZMacMetadataFile.synchronizeFileDescriptor(descriptor)
    let updated = manifestReplacingResources(resizedResources)
    try updated.validate()
    try writeManifest(updated, to: manifestURL)
    try DoryVZMacMetadataFile.remove(at: diskResizeJournalURL)
    return try Self.load(from: rootURL)
  }

  /// Enlarges one bundle-owned virtio data image while the VM is stopped. Its journal is
  /// committed before truncation and replayed by `load(from:)`, so a crash cannot publish a
  /// manifest capacity that is absent from the backing image (or lose a completed resize).
  public func growDataDisk(at index: Int, to requestedDiskBytes: UInt64) throws -> Self {
    guard manifest.installationState == .prepared || manifest.installationState == .stopped else {
      throw DoryVZMacMachineBundleError.diskResizeRequiresStoppedMachine(
        manifest.installationState
      )
    }
    let resizedResources = try manifest.resources.growingDataDisk(
      at: index,
      to: requestedDiskBytes
    )
    let existing = manifest.resources.dataDisks[index]
    let diskURL = dataDisksDirectoryURL.appendingPathComponent(existing.fileName)
    let lease = try DoryVZMacMachineLease(rootURL: rootURL)
    defer { withExtendedLifetime(lease) {} }
    try requireRegularFile(diskURL, label: existing.fileName)
    let descriptor = open(diskURL.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw DoryVZMacMachineBundleError.filesystem("open data disk for resize", errno)
    }
    defer { close(descriptor) }
    var information = stat()
    guard fstat(descriptor, &information) == 0 else {
      throw DoryVZMacMachineBundleError.filesystem("inspect data disk for resize", errno)
    }
    guard (information.st_mode & S_IFMT) == S_IFREG,
      information.st_size >= 0,
      UInt64(information.st_size) == existing.byteCount,
      requestedDiskBytes <= UInt64(Int64.max)
    else {
      throw DoryVZMacMachineBundleError.invalidBundle("data disk changed before resize")
    }
    let journalURL = dataDiskResizeJournalURL(index: index)
    try Self.writeDataDiskResizeJournal(
      DoryVZMacDataDiskResizeJournal(
        index: index,
        fileName: existing.fileName,
        previousBytes: existing.byteCount,
        requestedBytes: requestedDiskBytes
      ),
      to: journalURL
    )
    guard ftruncate(descriptor, off_t(requestedDiskBytes)) == 0 else {
      throw DoryVZMacMachineBundleError.filesystem("grow data disk", errno)
    }
    try DoryVZMacMetadataFile.synchronizeFileDescriptor(descriptor)
    let updated = manifestReplacingResources(resizedResources)
    try updated.validate()
    try writeManifest(updated, to: manifestURL)
    try DoryVZMacMetadataFile.remove(at: journalURL)
    return try Self.load(from: rootURL)
  }

  /// Returns either the daemon-bound address or a fresh local identity for standalone tools.
  /// Validate before touching the destination so an invalid launch identity cannot leave a
  /// partially prepared bundle behind.
  static func selectedMACAddress(_ requestedAddress: String?) throws -> String {
    let address = requestedAddress ?? VZMACAddress.randomLocallyAdministered().string
    guard let parsed = VZMACAddress(string: address),
      parsed.isUnicastAddress,
      parsed.isLocallyAdministeredAddress
    else {
      throw DoryVZMacMachineBundleError.invalidNetworkAddress(address)
    }
    return parsed.string.lowercased()
  }

  public func updatingInstallationState(
    _ installationState: DoryVZMacMachineInstallationState
  ) throws -> Self {
    let updated = manifest.replacingInstallationState(installationState)
    try updated.validate()
    try writeManifest(updated, to: manifestURL)
    return try Self.load(from: rootURL)
  }

  private func manifestReplacingResources(
    _ resources: DoryVZMacResourcePlan
  ) -> DoryVZMacMachineManifest {
    DoryVZMacMachineManifest(
      createdAt: manifest.createdAt,
      installationState: manifest.installationState,
      origin: manifest.origin,
      parentMachineIdentifierSHA256: manifest.parentMachineIdentifierSHA256,
      restoreImageBuild: manifest.restoreImageBuild,
      restoreImageVersion: manifest.restoreImageVersion,
      restoreImageSourceURL: manifest.restoreImageSourceURL,
      restoreImageBytes: manifest.restoreImageBytes,
      restoreImageSHA256: manifest.restoreImageSHA256,
      hardwareModelSHA256: manifest.hardwareModelSHA256,
      machineIdentifierSHA256: manifest.machineIdentifierSHA256,
      macAddress: manifest.macAddress,
      resources: resources
    )
  }

  private func writeManifest(
    _ manifest: DoryVZMacMachineManifest,
    to destination: URL
  ) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try DoryVZMacMetadataFile.write(encoder.encode(manifest), to: destination)
  }

  private static func writeSystemDiskResizeJournal(
    _ journal: DoryVZMacSystemDiskResizeJournal,
    to destination: URL
  ) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    try DoryVZMacMetadataFile.write(encoder.encode(journal), to: destination)
  }

  private static func writeDataDiskResizeJournal(
    _ journal: DoryVZMacDataDiskResizeJournal,
    to destination: URL
  ) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    try DoryVZMacMetadataFile.write(encoder.encode(journal), to: destination)
  }

  static func recoverPendingSystemDiskResize(
    at rootURL: URL,
    manifest: DoryVZMacMachineManifest
  ) throws -> DoryVZMacMachineManifest {
    let journalURL = rootURL.appendingPathComponent(diskResizeJournalName)
    guard let journalData = try DoryVZMacMetadataFile.readIfPresent(from: journalURL) else {
      return manifest
    }
    let journal: DoryVZMacSystemDiskResizeJournal
    do {
      journal = try JSONDecoder().decode(
        DoryVZMacSystemDiskResizeJournal.self,
        from: journalData
      )
    } catch {
      throw DoryVZMacMachineBundleError.invalidBundle("system-disk resize journal is invalid")
    }
    guard journal.previousBytes >= DoryVZMacResourcePlan.minimumDiskBytes,
      journal.requestedBytes > journal.previousBytes
    else {
      throw DoryVZMacMachineBundleError.invalidBundle("system-disk resize journal is inconsistent")
    }
    let diskURL = rootURL.appendingPathComponent(diskName)
    let diskBytes = try synchronizeResizeRecoveryDisk(at: diskURL)
    switch (manifest.resources.diskBytes, diskBytes) {
    case (journal.previousBytes, journal.previousBytes):
      try DoryVZMacMetadataFile.remove(at: journalURL)
      return manifest
    case (journal.previousBytes, journal.requestedBytes):
      let resources = try manifest.resources.growingSystemDisk(to: journal.requestedBytes)
      let updated = DoryVZMacMachineManifest(
        createdAt: manifest.createdAt,
        installationState: manifest.installationState,
        origin: manifest.origin,
        parentMachineIdentifierSHA256: manifest.parentMachineIdentifierSHA256,
        restoreImageBuild: manifest.restoreImageBuild,
        restoreImageVersion: manifest.restoreImageVersion,
        restoreImageSourceURL: manifest.restoreImageSourceURL,
        restoreImageBytes: manifest.restoreImageBytes,
        restoreImageSHA256: manifest.restoreImageSHA256,
        hardwareModelSHA256: manifest.hardwareModelSHA256,
        machineIdentifierSHA256: manifest.machineIdentifierSHA256,
        macAddress: manifest.macAddress,
        resources: resources
      )
      try updated.validate()
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      try DoryVZMacMetadataFile.write(
        encoder.encode(updated), to: rootURL.appendingPathComponent(manifestName)
      )
      try DoryVZMacMetadataFile.remove(at: journalURL)
      return updated
    case (journal.requestedBytes, journal.requestedBytes):
      try DoryVZMacMetadataFile.remove(at: journalURL)
      return manifest
    default:
      throw DoryVZMacMachineBundleError.invalidBundle(
        "system-disk resize recovery found inconsistent capacity"
      )
    }
  }

  static func recoverPendingDataDiskResize(
    at rootURL: URL,
    manifest: DoryVZMacMachineManifest,
    index: Int
  ) throws -> DoryVZMacMachineManifest {
    guard manifest.resources.dataDisks.indices.contains(index) else {
      throw DoryVZMacMachineBundleError.invalidBundle(
        "data-disk resize journal has no matching disk")
    }
    let journalURL = rootURL.appendingPathComponent("data-disk-\(index + 1)-resize.json")
    guard let journalData = try DoryVZMacMetadataFile.readIfPresent(from: journalURL) else {
      return manifest
    }
    let journal: DoryVZMacDataDiskResizeJournal
    do {
      journal = try JSONDecoder().decode(
        DoryVZMacDataDiskResizeJournal.self,
        from: journalData
      )
    } catch {
      throw DoryVZMacMachineBundleError.invalidBundle("data-disk resize journal is invalid")
    }
    let disk = manifest.resources.dataDisks[index]
    guard journal.index == index,
      journal.fileName == disk.fileName,
      journal.previousBytes >= DoryVZMacResourcePlan.minimumDataDiskBytes,
      journal.requestedBytes > journal.previousBytes,
      journal.requestedBytes.isMultiple(of: 512)
    else {
      throw DoryVZMacMachineBundleError.invalidBundle("data-disk resize journal is inconsistent")
    }
    let diskURL =
      rootURL
      .appendingPathComponent(dataDisksDirectoryName, isDirectory: true)
      .appendingPathComponent(disk.fileName)
    let diskBytes = try synchronizeResizeRecoveryDisk(at: diskURL)
    switch (disk.byteCount, diskBytes) {
    case (journal.previousBytes, journal.previousBytes):
      try DoryVZMacMetadataFile.remove(at: journalURL)
      return manifest
    case (journal.previousBytes, journal.requestedBytes):
      let resources = try manifest.resources.growingDataDisk(
        at: index,
        to: journal.requestedBytes
      )
      let updated = DoryVZMacMachineManifest(
        createdAt: manifest.createdAt,
        installationState: manifest.installationState,
        origin: manifest.origin,
        parentMachineIdentifierSHA256: manifest.parentMachineIdentifierSHA256,
        restoreImageBuild: manifest.restoreImageBuild,
        restoreImageVersion: manifest.restoreImageVersion,
        restoreImageSourceURL: manifest.restoreImageSourceURL,
        restoreImageBytes: manifest.restoreImageBytes,
        restoreImageSHA256: manifest.restoreImageSHA256,
        hardwareModelSHA256: manifest.hardwareModelSHA256,
        machineIdentifierSHA256: manifest.machineIdentifierSHA256,
        macAddress: manifest.macAddress,
        resources: resources
      )
      try updated.validate()
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      try DoryVZMacMetadataFile.write(
        encoder.encode(updated), to: rootURL.appendingPathComponent(manifestName)
      )
      try DoryVZMacMetadataFile.remove(at: journalURL)
      return updated
    case (journal.requestedBytes, journal.requestedBytes):
      try DoryVZMacMetadataFile.remove(at: journalURL)
      return manifest
    default:
      throw DoryVZMacMachineBundleError.invalidBundle(
        "data-disk resize recovery found inconsistent capacity"
      )
    }
  }

  private static func synchronizeResizeRecoveryDisk(at url: URL) throws -> UInt64 {
    let descriptor = open(url.path, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw DoryVZMacMachineBundleError.filesystem("open resize recovery disk", errno)
    }
    defer { close(descriptor) }
    var information = stat()
    guard fstat(descriptor, &information) == 0 else {
      throw DoryVZMacMachineBundleError.filesystem("inspect resize recovery disk", errno)
    }
    guard information.st_mode & S_IFMT == S_IFREG, information.st_uid == geteuid(),
      information.st_nlink == 1, information.st_mode & 0o022 == 0, information.st_size >= 0
    else { throw DoryVZMacMachineBundleError.invalidBundle("resize recovery disk is not owned") }
    // Recovery may follow a crash after ftruncate but before the original disk flush. Size
    // alone is not a durable commit; flush this exact inode before advertising its capacity.
    try DoryVZMacMetadataFile.synchronizeFileDescriptor(descriptor)
    return UInt64(information.st_size)
  }
}

private func isCanonicalSHA256(_ digest: String) -> Bool {
  digest.count == 64 && digest.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
}

private func sha256(of data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func sha256(of url: URL) throws -> String {
  let handle = try FileHandle(forReadingFrom: url)
  defer { try? handle.close() }
  var hasher = SHA256()
  while true {
    let readChunk = try autoreleasepool {
      guard let data = try handle.read(upToCount: 4 * 1_024 * 1_024), !data.isEmpty else {
        return false
      }
      hasher.update(data: data)
      return true
    }
    if !readChunk { break }
  }
  return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

private func createSparseFile(at url: URL, size: UInt64) throws {
  let descriptor = open(url.path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
  guard descriptor >= 0 else {
    throw DoryVZMacMachineBundleError.filesystem("create sparse disk", errno)
  }
  defer { close(descriptor) }
  guard size <= UInt64(Int64.max), ftruncate(descriptor, off_t(size)) == 0 else {
    throw DoryVZMacMachineBundleError.filesystem("size sparse disk", errno)
  }
  guard fsync(descriptor) == 0 else {
    throw DoryVZMacMachineBundleError.filesystem("sync sparse disk", errno)
  }
}

private func cloneFile(from source: URL, to destination: URL) throws {
  guard copyfile(source.path, destination.path, nil, copyfile_flags_t(COPYFILE_CLONE)) == 0 else {
    throw DoryVZMacMachineBundleError.filesystem("clone \(source.lastPathComponent)", errno)
  }
}

private func requireDirectory(_ url: URL, label: String) throws {
  var status = stat()
  guard lstat(url.path, &status) == 0,
    (status.st_mode & S_IFMT) == S_IFDIR
  else {
    throw DoryVZMacMachineBundleError.invalidBundle("\(label) is not a direct directory")
  }
}

private func requireRegularFile(_ url: URL, label: String) throws {
  var status = stat()
  guard lstat(url.path, &status) == 0,
    (status.st_mode & S_IFMT) == S_IFREG
  else {
    throw DoryVZMacMachineBundleError.invalidBundle("\(label) is not a direct regular file")
  }
}
