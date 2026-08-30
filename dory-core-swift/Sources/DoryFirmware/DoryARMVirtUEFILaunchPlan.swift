import DoryMachineARMVirt

public enum DoryARMVirtUEFIBootDeviceKind: String, Codable, CaseIterable, Sendable, Hashable {
  case systemDisk = "system-disk"
  case removableMedia = "removable-media"
}

public struct DoryARMVirtUEFIBootDevice: Codable, Sendable, Hashable, Comparable {
  public let logicalID: String
  public let kind: DoryARMVirtUEFIBootDeviceKind
  public let virtioSlot: Int
  public let readOnly: Bool

  public init(
    logicalID: String,
    kind: DoryARMVirtUEFIBootDeviceKind,
    virtioSlot: Int,
    readOnly: Bool
  ) throws {
    guard Self.isSafeLogicalID(logicalID) else {
      throw DoryARMVirtUEFILaunchPlanError.invalidLogicalID(logicalID)
    }
    guard DoryARMVirtV1ABI.virtioSlots.indices.contains(virtioSlot) else {
      throw DoryARMVirtUEFILaunchPlanError.invalidSlot(virtioSlot)
    }
    let role = DoryARMVirtV1ABI.role(forSlot: virtioSlot)
    switch kind {
    case .systemDisk:
      guard role == .systemDisk, !readOnly else {
        throw DoryARMVirtUEFILaunchPlanError.invalidDeviceBinding(logicalID)
      }
    case .removableMedia:
      guard role == .auxiliaryStorage, readOnly else {
        throw DoryARMVirtUEFILaunchPlanError.invalidDeviceBinding(logicalID)
      }
    }
    self.logicalID = logicalID
    self.kind = kind
    self.virtioSlot = virtioSlot
    self.readOnly = readOnly
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.virtioSlot != rhs.virtioSlot { return lhs.virtioSlot < rhs.virtioSlot }
    return lhs.logicalID < rhs.logicalID
  }

  private enum CodingKeys: String, CodingKey { case logicalID, kind, virtioSlot, readOnly }

  public init(from decoder: Decoder) throws {
    try rejectUnknownFirmwareFields(
      from: decoder,
      allowed: ["logicalID", "kind", "virtioSlot", "readOnly"],
      type: "DoryARMVirtUEFIBootDevice"
    )
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      logicalID: container.decode(String.self, forKey: .logicalID),
      kind: container.decode(DoryARMVirtUEFIBootDeviceKind.self, forKey: .kind),
      virtioSlot: container.decode(Int.self, forKey: .virtioSlot),
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

public struct DoryARMVirtUEFILaunchPlan: Codable, Sendable, Hashable {
  public static let schemaVersion: UInt32 = 1

  public let schemaVersion: UInt32
  public let machineABIIdentity: String
  public let firmwareABIIdentity: String
  public let variableStoreFormatIdentity: String
  public let firmware: DoryFirmwareArtifactManifest
  public let variableStoreGeneration: UInt64
  public let bootDevices: [DoryARMVirtUEFIBootDevice]
  public let bootOrder: [String]
  public let initialCPUState: DoryARMVirtV1InitialCPUState

  public init(
    firmware: DoryFirmwareArtifactManifest,
    variableStoreGeneration: UInt64,
    bootDevices: [DoryARMVirtUEFIBootDevice],
    bootOrder: [String]
  ) throws {
    try self.init(
      schemaVersion: Self.schemaVersion,
      machineABIIdentity: DoryARMVirtV1ABI.identity,
      firmwareABIIdentity: DoryARMVirtV1ABI.firmwareABIIdentity,
      variableStoreFormatIdentity: DoryARMVirtV1ABI.variableStoreFormatIdentity,
      firmware: firmware,
      variableStoreGeneration: variableStoreGeneration,
      bootDevices: bootDevices,
      bootOrder: bootOrder,
      initialCPUState: try .uefi(
        deviceTreeAddress: DoryARMVirtV1ABI.ramBase + DoryARMVirtV1ABI.dtbOffset
      )
    )
  }

  private init(
    schemaVersion: UInt32,
    machineABIIdentity: String,
    firmwareABIIdentity: String,
    variableStoreFormatIdentity: String,
    firmware: DoryFirmwareArtifactManifest,
    variableStoreGeneration: UInt64,
    bootDevices: [DoryARMVirtUEFIBootDevice],
    bootOrder: [String],
    initialCPUState: DoryARMVirtV1InitialCPUState
  ) throws {
    guard schemaVersion == Self.schemaVersion else {
      throw DoryARMVirtUEFILaunchPlanError.unsupportedSchemaVersion(schemaVersion)
    }
    guard machineABIIdentity == DoryARMVirtV1ABI.identity,
      firmware.machineABIIdentity == machineABIIdentity
    else {
      throw DoryARMVirtUEFILaunchPlanError.incompatibleMachineABI(machineABIIdentity)
    }
    guard firmwareABIIdentity == DoryARMVirtV1ABI.firmwareABIIdentity,
      firmware.firmwareABIIdentity == firmwareABIIdentity
    else {
      throw DoryARMVirtUEFILaunchPlanError.incompatibleFirmwareABI(firmwareABIIdentity)
    }
    guard variableStoreFormatIdentity == DoryARMVirtV1ABI.variableStoreFormatIdentity,
      firmware.variableStoreFormatIdentity == variableStoreFormatIdentity
    else {
      throw DoryARMVirtUEFILaunchPlanError.incompatibleVariableStore(variableStoreFormatIdentity)
    }
    guard variableStoreGeneration > 0 else {
      throw DoryARMVirtUEFILaunchPlanError.invalidVariableStoreGeneration(variableStoreGeneration)
    }
    guard bootDevices == bootDevices.sorted(),
      Set(bootDevices.map(\.logicalID)).count == bootDevices.count,
      Set(bootDevices.map(\.virtioSlot)).count == bootDevices.count
    else {
      throw DoryARMVirtUEFILaunchPlanError.nonCanonicalBootDevices
    }
    guard bootDevices.filter({ $0.kind == .systemDisk }).count == 1,
      bootDevices.filter({ $0.kind == .removableMedia }).count <= 1
    else {
      throw DoryARMVirtUEFILaunchPlanError.invalidBootDeviceSet
    }
    let deviceIDs = bootDevices.map(\.logicalID)
    guard bootOrder.count == deviceIDs.count,
      Set(bootOrder).count == bootOrder.count,
      Set(bootOrder) == Set(deviceIDs)
    else {
      throw DoryARMVirtUEFILaunchPlanError.invalidBootOrder
    }
    guard
      initialCPUState
        == (try DoryARMVirtV1InitialCPUState.uefi(
          deviceTreeAddress: DoryARMVirtV1ABI.ramBase + DoryARMVirtV1ABI.dtbOffset
        ))
    else {
      throw DoryARMVirtUEFILaunchPlanError.invalidInitialCPUState
    }
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
      type: "DoryARMVirtUEFILaunchPlan"
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
      bootDevices: container.decode([DoryARMVirtUEFIBootDevice].self, forKey: .bootDevices),
      bootOrder: container.decode([String].self, forKey: .bootOrder),
      initialCPUState: container.decode(DoryARMVirtV1InitialCPUState.self, forKey: .initialCPUState)
    )
  }
}

public enum DoryARMVirtUEFILaunchPlanError: Error, Sendable, Equatable {
  case unsupportedSchemaVersion(UInt32)
  case incompatibleMachineABI(String)
  case incompatibleFirmwareABI(String)
  case incompatibleVariableStore(String)
  case invalidVariableStoreGeneration(UInt64)
  case invalidLogicalID(String)
  case invalidSlot(Int)
  case invalidDeviceBinding(String)
  case nonCanonicalBootDevices
  case invalidBootDeviceSet
  case invalidBootOrder
  case invalidInitialCPUState
}
