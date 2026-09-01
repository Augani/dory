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
  case variableStoreRecoveryRequired
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
  public let displayDevice: DoryPCVirtioGPUPCIDevice
  public let keyboardDevice: DoryPCVirtioInputPCIDevice
  public let pointerDevice: DoryPCVirtioInputPCIDevice
  public let tabletDevice: DoryPCVirtioInputPCIDevice
  public let soundDevice: DoryPCVirtioSoundPCIDevice
  public let xhciController: DoryPCXHCIController
  public let networkDevice: DoryPCVirtioNetworkPCIDevice
  public let entropyDevice: DoryPCVirtioEntropyPCIDevice
  public let additionalPCIFunctions: [any DoryPCPCIFunction]
  public let effectiveVariableStoreGeneration: UInt64
  public let machine: DoryPCDirectKernelMachine

  public init(
    plan: DoryPCUEFILaunchPlan,
    firmware: DoryVerifiedFirmwareArtifacts,
    variableStore: DoryUEFIVariableStoreAuthority,
    bootStorage: [DoryPCUEFIBootStorage],
    memoryBytes: Int,
    processorCount: Int = 1,
    initialRTCDate: Date = Date(),
    firmwareConfigurationFlags: DoryPCFirmwareConfiguration.Flags = [],
    displaySink: (any DoryVirtioGPUDisplaySink)? = nil,
    gpuAccelerationAuthority: (any DoryVirtioGPUAccelerationAuthority)? = nil,
    soundBackend: any DoryVirtioSoundBackend = DoryVirtioInMemorySoundBackend(),
    networkBackend: any DoryVirtioNetworkBackend = DoryVirtioInMemoryNetworkBackend(),
    networkMACAddress: [UInt8] = [0x02, 0x44, 0x4F, 0x52, 0x59, 0x01],
    networkMTU: UInt16 = 1_500,
    additionalPCIFunctions: [any DoryPCPCIFunction] = [],
    interpreter: DoryX86Interpreter = .init(),
    executionTier: DoryPCExecutionTier = .interpreter,
    baselineJITMaximumCodeBytes: Int = DoryARM64BaselineExecutor.defaultMaximumCodeBytes
  ) throws {
    guard firmware.manifest.platform == .pcV1 else {
      throw DoryPCUEFIMachineError.incompatibleFirmwarePlatform(firmware.manifest.platform)
    }
    guard firmware.manifest == plan.firmware else {
      throw DoryPCUEFIMachineError.firmwareManifestMismatch
    }
    let variableLoad = try variableStore.load()
    guard variableLoad.source == .primary else {
      throw DoryPCUEFIMachineError.variableStoreRecoveryRequired
    }
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
    let displayDevice = try DoryPCVirtioGPUPCIDevice(
      address: DoryPCV1ABI.displayPCIAddress,
      initialBARAddress: DoryPCV1ABI.displayBARAddress,
      scanouts: [
        .init(id: 0, rectangle: .init(x: 0, y: 0, width: 1_280, height: 800))
      ],
      displaySink: displaySink,
      accelerationAuthority: gpuAccelerationAuthority
    )
    let keyboardDevice = try DoryPCVirtioInputPCIDevice(
      address: DoryPCV1ABI.keyboardPCIAddress,
      initialBARAddress: DoryPCV1ABI.keyboardBARAddress,
      descriptor: .keyboard()
    )
    let pointerDevice = try DoryPCVirtioInputPCIDevice(
      address: DoryPCV1ABI.pointerPCIAddress,
      initialBARAddress: DoryPCV1ABI.pointerBARAddress,
      descriptor: .relativePointer()
    )
    let tabletDevice = try DoryPCVirtioInputPCIDevice(
      address: DoryPCV1ABI.tabletPCIAddress,
      initialBARAddress: DoryPCV1ABI.tabletBARAddress,
      descriptor: .absolutePointer()
    )
    let soundDevice = try DoryPCVirtioSoundPCIDevice(
      address: DoryPCV1ABI.soundPCIAddress,
      initialBARAddress: DoryPCV1ABI.soundBARAddress,
      backend: soundBackend
    )
    let xhciController = try DoryPCXHCIController()
    let networkDevice = try DoryPCVirtioNetworkPCIDevice(
      address: DoryPCV1ABI.networkPCIAddress,
      initialBARAddress: DoryPCV1ABI.networkBARAddress,
      backend: networkBackend,
      macAddress: networkMACAddress,
      mtu: networkMTU
    )
    let entropyDevice = try DoryPCVirtioEntropyPCIDevice(
      address: DoryPCV1ABI.entropyPCIAddress,
      initialBARAddress: DoryPCV1ABI.entropyBARAddress
    )
    var pciFunctions: [any DoryPCPCIFunction] = blockDevices
    pciFunctions += [
      displayDevice,
      keyboardDevice,
      pointerDevice,
      tabletDevice,
      soundDevice,
      xhciController,
      networkDevice,
      entropyDevice,
    ]
    pciFunctions += additionalPCIFunctions
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: memoryBytes,
      processorCount: processorCount,
      initialRTCDate: initialRTCDate,
      firmwareConfigurationFlags: firmwareConfigurationFlags,
      pciFunctions: pciFunctions,
      platformMMIODevices: [firmwareFlash, variableBridge],
      interpreter: interpreter,
      executionTier: executionTier,
      baselineJITMaximumCodeBytes: baselineJITMaximumCodeBytes
    )
    try machine.loadUEFI()
    let bootVariableSnapshot = try DoryPCUEFIBootVariables.applying(
      plan: plan,
      to: variableLoad.snapshot
    )
    if bootVariableSnapshot != variableLoad.snapshot {
      try variableStore.commit(
        bootVariableSnapshot,
        expectedGeneration: variableLoad.snapshot.generation
      )
    }

    self.plan = plan
    self.firmware = firmware
    self.firmwareFlash = firmwareFlash
    self.variableBridge = variableBridge
    self.blockDevices = blockDevices
    self.displayDevice = displayDevice
    self.keyboardDevice = keyboardDevice
    self.pointerDevice = pointerDevice
    self.tabletDevice = tabletDevice
    self.soundDevice = soundDevice
    self.xhciController = xhciController
    self.networkDevice = networkDevice
    self.entropyDevice = entropyDevice
    self.additionalPCIFunctions = additionalPCIFunctions
    self.effectiveVariableStoreGeneration = bootVariableSnapshot.generation
    self.machine = machine
  }

  private static func barAddress(for kind: DoryPCUEFIBootDeviceKind) -> UInt64 {
    switch kind {
    case .systemDisk: DoryPCV1ABI.systemDiskBARAddress
    case .removableMedia: DoryPCV1ABI.removableMediaBARAddress
    }
  }
}
