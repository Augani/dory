import DoryDBTX86
import DoryMachinePC
import DoryVirtio
import Foundation

public struct DoryPCUEFIBootStorage: Sendable {
  public let logicalID: String
  public let storage: any DoryVirtioBlockStorage

  public init(logicalID: String, storage: any DoryVirtioBlockStorage) {
    self.logicalID = logicalID
    self.storage = storage
  }
}

public enum DoryPCUEFIMachineError: Error, Sendable, Equatable {
  case incompatibleFirmwarePlatform(DoryFirmwarePlatform)
  case firmwareManifestMismatch
  case incompatibleVariableStorePlatform(DoryFirmwarePlatform)
  case variableStoreGenerationMismatch(expected: UInt64, actual: UInt64)
  case nonCanonicalBootStorage
  case missingBootStorage(String)
  case unexpectedBootStorage(String)
  case bootStorageReadOnlyMismatch(logicalID: String, expected: Bool, actual: Bool)
}

/// Fully composed DoryPC-v1 UEFI machine. Construction verifies firmware, variable-store, PCI
/// storage, and reset-state authority before any guest instruction can execute.
public final class DoryPCUEFIMachine: @unchecked Sendable {
  public let plan: DoryPCUEFILaunchPlan
  public let firmware: DoryVerifiedFirmwareArtifacts
  public let firmwareFlash: DoryPCFirmwareFlash
  public let variableBridge: DoryPCUEFIVariableBridgeMMIO
  public let blockDevices: [DoryPCVirtioBlockPCIDevice]
  public let machine: DoryPCDirectKernelMachine

  public init(
    plan: DoryPCUEFILaunchPlan,
    firmware: DoryVerifiedFirmwareArtifacts,
    variableStore: DoryUEFIVariableStoreAuthority,
    bootStorage: [DoryPCUEFIBootStorage],
    memoryBytes: Int,
    processorCount: Int = 1,
    initialRTCDate: Date = Date(),
    interpreter: DoryX86Interpreter = .init()
  ) throws {
    guard firmware.manifest.platform == .pcV1 else {
      throw DoryPCUEFIMachineError.incompatibleFirmwarePlatform(firmware.manifest.platform)
    }
    guard firmware.manifest == plan.firmware else {
      throw DoryPCUEFIMachineError.firmwareManifestMismatch
    }
    let variableLoad = try variableStore.load()
    guard variableLoad.snapshot.platform == .pcV1 else {
      throw DoryPCUEFIMachineError.incompatibleVariableStorePlatform(
        variableLoad.snapshot.platform
      )
    }
    guard variableLoad.snapshot.generation == plan.variableStoreGeneration else {
      throw DoryPCUEFIMachineError.variableStoreGenerationMismatch(
        expected: plan.variableStoreGeneration,
        actual: variableLoad.snapshot.generation
      )
    }
    guard Set(bootStorage.map(\.logicalID)).count == bootStorage.count else {
      throw DoryPCUEFIMachineError.nonCanonicalBootStorage
    }
    let expectedIDs = Set(plan.bootDevices.map(\.logicalID))
    for storage in bootStorage where !expectedIDs.contains(storage.logicalID) {
      throw DoryPCUEFIMachineError.unexpectedBootStorage(storage.logicalID)
    }

    var storageByID: [String: any DoryVirtioBlockStorage] = [:]
    for storage in bootStorage { storageByID[storage.logicalID] = storage.storage }
    var blockDevices: [DoryPCVirtioBlockPCIDevice] = []
    for device in plan.bootDevices {
      guard let storage = storageByID[device.logicalID] else {
        throw DoryPCUEFIMachineError.missingBootStorage(device.logicalID)
      }
      guard storage.readOnly == device.readOnly else {
        throw DoryPCUEFIMachineError.bootStorageReadOnlyMismatch(
          logicalID: device.logicalID,
          expected: device.readOnly,
          actual: storage.readOnly
        )
      }
      blockDevices.append(
        try .init(
          address: device.pciAddress,
          initialBARAddress: Self.barAddress(for: device.kind),
          storage: storage,
          identifier: device.logicalID
        )
      )
    }

    let firmwareFlash = try DoryPCFirmwareFlash(image: firmware.firmwareCode)
    let variableBridge = try DoryPCUEFIVariableBridgeMMIO(
      service: .init(store: variableStore)
    )
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: memoryBytes,
      processorCount: processorCount,
      initialRTCDate: initialRTCDate,
      pciFunctions: blockDevices,
      platformMMIODevices: [firmwareFlash, variableBridge],
      interpreter: interpreter
    )
    try machine.loadUEFI()

    self.plan = plan
    self.firmware = firmware
    self.firmwareFlash = firmwareFlash
    self.variableBridge = variableBridge
    self.blockDevices = blockDevices
    self.machine = machine
  }

  private static func barAddress(for kind: DoryPCUEFIBootDeviceKind) -> UInt64 {
    switch kind {
    case .systemDisk: DoryPCV1ABI.systemDiskBARAddress
    case .removableMedia: DoryPCV1ABI.removableMediaBARAddress
    }
  }
}
