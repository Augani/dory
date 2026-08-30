import DoryDBTX86
import DoryMachinePC

public enum DoryPCUEFIBootDeviceKind: String, Codable, CaseIterable, Sendable, Hashable {
  case systemDisk = "system-disk"
  case removableMedia = "removable-media"
}

public struct DoryPCUEFIBootDevice: Codable, Sendable, Hashable, Comparable {
  public static let systemDiskAddress = DoryPCPCIAddress(bus: 0, device: 1, function: 0)
  public static let removableMediaAddress = DoryPCPCIAddress(bus: 0, device: 12, function: 0)

  public let logicalID: String
  public let kind: DoryPCUEFIBootDeviceKind
  public let pciAddress: DoryPCPCIAddress
  public let readOnly: Bool

  public init(
    logicalID: String,
    kind: DoryPCUEFIBootDeviceKind,
    pciAddress: DoryPCPCIAddress,
    readOnly: Bool
  ) throws {
    guard Self.isSafeLogicalID(logicalID) else {
      throw DoryPCUEFILaunchPlanError.invalidLogicalID(logicalID)
    }
    switch kind {
    case .systemDisk:
      guard pciAddress == Self.systemDiskAddress, !readOnly else {
        throw DoryPCUEFILaunchPlanError.invalidDeviceBinding(logicalID)
      }
    case .removableMedia:
      guard pciAddress == Self.removableMediaAddress, readOnly else {
        throw DoryPCUEFILaunchPlanError.invalidDeviceBinding(logicalID)
      }
    }
    self.logicalID = logicalID
    self.kind = kind
    self.pciAddress = pciAddress
    self.readOnly = readOnly
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.pciAddress != rhs.pciAddress { return lhs.pciAddress < rhs.pciAddress }
    return lhs.logicalID < rhs.logicalID
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case logicalID, kind, pciAddress, readOnly
  }

  public init(from decoder: Decoder) throws {
    try rejectUnknownFirmwareFields(
      from: decoder,
      allowed: Set(CodingKeys.allCases.map(\.rawValue)),
      type: "DoryPCUEFIBootDevice"
    )
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      logicalID: container.decode(String.self, forKey: .logicalID),
      kind: container.decode(DoryPCUEFIBootDeviceKind.self, forKey: .kind),
      pciAddress: container.decode(DoryPCPCIAddress.self, forKey: .pciAddress),
      readOnly: container.decode(Bool.self, forKey: .readOnly)
    )
  }

  private static func isSafeLogicalID(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    return (1...128).contains(bytes.count)
      && bytes.allSatisfy {
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
          || $0 == 45 || $0 == 46 || $0 == 58 || $0 == 95
      }
  }
}

public struct DoryPCUEFILaunchPlan: Codable, Sendable, Hashable {
  public static let schemaVersion: UInt32 = 1

  public let schemaVersion: UInt32
  public let machineABIIdentity: String
  public let firmwareABIIdentity: String
  public let variableStoreFormatIdentity: String
  public let firmware: DoryFirmwareArtifactManifest
  public let variableStoreGeneration: UInt64
  public let bootDevices: [DoryPCUEFIBootDevice]
  public let bootOrder: [String]
  public let initialCPUState: DoryX86ArchitecturalState

  public init(
    firmware: DoryFirmwareArtifactManifest,
    variableStoreGeneration: UInt64,
    bootDevices: [DoryPCUEFIBootDevice],
    bootOrder: [String]
  ) throws {
    try self.init(
      schemaVersion: Self.schemaVersion,
      machineABIIdentity: DoryPCV1ABI.identity,
      firmwareABIIdentity: DoryPCV1ABI.firmwareABIIdentity,
      variableStoreFormatIdentity: DoryPCV1ABI.variableStoreFormatIdentity,
      firmware: firmware,
      variableStoreGeneration: variableStoreGeneration,
      bootDevices: bootDevices,
      bootOrder: bootOrder,
      initialCPUState: .reset()
    )
  }

  private init(
    schemaVersion: UInt32,
    machineABIIdentity: String,
    firmwareABIIdentity: String,
    variableStoreFormatIdentity: String,
    firmware: DoryFirmwareArtifactManifest,
    variableStoreGeneration: UInt64,
    bootDevices: [DoryPCUEFIBootDevice],
    bootOrder: [String],
    initialCPUState: DoryX86ArchitecturalState
  ) throws {
    guard schemaVersion == Self.schemaVersion else {
      throw DoryPCUEFILaunchPlanError.unsupportedSchemaVersion(schemaVersion)
    }
    guard machineABIIdentity == DoryPCV1ABI.identity,
      firmware.machineABIIdentity == machineABIIdentity
    else { throw DoryPCUEFILaunchPlanError.incompatibleMachineABI(machineABIIdentity) }
    guard firmwareABIIdentity == DoryPCV1ABI.firmwareABIIdentity,
      firmware.firmwareABIIdentity == firmwareABIIdentity
    else { throw DoryPCUEFILaunchPlanError.incompatibleFirmwareABI(firmwareABIIdentity) }
    guard variableStoreFormatIdentity == DoryPCV1ABI.variableStoreFormatIdentity,
      firmware.variableStoreFormatIdentity == variableStoreFormatIdentity,
      firmware.platform == .pcV1
    else {
      throw DoryPCUEFILaunchPlanError.incompatibleVariableStore(variableStoreFormatIdentity)
    }
    guard variableStoreGeneration > 0 else {
      throw DoryPCUEFILaunchPlanError.invalidVariableStoreGeneration(variableStoreGeneration)
    }
    guard bootDevices == bootDevices.sorted(),
      Set(bootDevices.map(\.logicalID)).count == bootDevices.count,
      Set(bootDevices.map(\.pciAddress)).count == bootDevices.count
    else { throw DoryPCUEFILaunchPlanError.nonCanonicalBootDevices }
    guard bootDevices.filter({ $0.kind == .systemDisk }).count == 1,
      bootDevices.filter({ $0.kind == .removableMedia }).count <= 1
    else { throw DoryPCUEFILaunchPlanError.invalidBootDeviceSet }
    let deviceIDs = bootDevices.map(\.logicalID)
    guard bootOrder.count == deviceIDs.count,
      Set(bootOrder).count == bootOrder.count,
      Set(bootOrder) == Set(deviceIDs)
    else { throw DoryPCUEFILaunchPlanError.invalidBootOrder }
    let reset = DoryX86ArchitecturalState.reset()
    guard initialCPUState == reset,
      initialCPUState.cs.base + initialCPUState.rip == DoryPCV1ABI.uefiResetAddress
    else { throw DoryPCUEFILaunchPlanError.invalidInitialCPUState }

    self.schemaVersion = schemaVersion
    self.machineABIIdentity = machineABIIdentity
    self.firmwareABIIdentity = firmwareABIIdentity
    self.variableStoreFormatIdentity = variableStoreFormatIdentity
    self.firmware = firmware
    self.variableStoreGeneration = variableStoreGeneration
    self.bootDevices = bootDevices
    self.bootOrder = bootOrder
    self.initialCPUState = initialCPUState
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case schemaVersion, machineABIIdentity, firmwareABIIdentity, variableStoreFormatIdentity
    case firmware, variableStoreGeneration, bootDevices, bootOrder, initialCPUState
  }

  public init(from decoder: Decoder) throws {
    try rejectUnknownFirmwareFields(
      from: decoder,
      allowed: Set(CodingKeys.allCases.map(\.rawValue)),
      type: "DoryPCUEFILaunchPlan"
    )
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      schemaVersion: container.decode(UInt32.self, forKey: .schemaVersion),
      machineABIIdentity: container.decode(String.self, forKey: .machineABIIdentity),
      firmwareABIIdentity: container.decode(String.self, forKey: .firmwareABIIdentity),
      variableStoreFormatIdentity: container.decode(
        String.self,
        forKey: .variableStoreFormatIdentity
      ),
      firmware: container.decode(DoryFirmwareArtifactManifest.self, forKey: .firmware),
      variableStoreGeneration: container.decode(UInt64.self, forKey: .variableStoreGeneration),
      bootDevices: container.decode([DoryPCUEFIBootDevice].self, forKey: .bootDevices),
      bootOrder: container.decode([String].self, forKey: .bootOrder),
      initialCPUState: container.decode(DoryX86ArchitecturalState.self, forKey: .initialCPUState)
    )
  }
}

public enum DoryPCUEFILaunchPlanError: Error, Sendable, Equatable {
  case unsupportedSchemaVersion(UInt32)
  case incompatibleMachineABI(String)
  case incompatibleFirmwareABI(String)
  case incompatibleVariableStore(String)
  case invalidVariableStoreGeneration(UInt64)
  case invalidLogicalID(String)
  case invalidDeviceBinding(String)
  case nonCanonicalBootDevices
  case invalidBootDeviceSet
  case invalidBootOrder
  case invalidInitialCPUState
}
