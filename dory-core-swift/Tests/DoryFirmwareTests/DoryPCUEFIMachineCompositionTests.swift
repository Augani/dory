import DoryFirmware
import DoryMachinePC
import DoryVirtio
import Foundation
import Testing

@Suite struct DoryPCUEFIMachineCompositionTests {
  @Test func composesVerifiedFirmwareVariablesAndInstallerStorageIntoOneMachine() throws {
    let fixture = try PCUEFIMachineFixture()
    defer { fixture.remove() }
    let systemStorage = DoryVirtioInMemoryBlockStorage(byteCount: 1 << 20)
    let installerStorage = DoryVirtioInMemoryBlockStorage(
      byteCount: 1 << 20,
      readOnly: true,
      initialBytes: Array("installer".utf8)
    )
    let composed = try DoryPCUEFIMachine(
      plan: fixture.plan,
      firmware: fixture.firmware,
      variableStore: .init(file: fixture.store),
      bootStorage: [
        .init(logicalID: "system-disk", storage: systemStorage),
        .init(logicalID: "installer-iso", storage: installerStorage),
      ],
      memoryBytes: 2 * 1024 * 1024,
      processorCount: 2
    )

    #expect(composed.machine.state == fixture.plan.initialCPUState)
    #expect(composed.variableBridge.baseAddress == DoryPCV1ABI.firmwareVariableBase)
    #expect(composed.firmwareFlash.baseAddress == DoryPCV1ABI.firmwareCodeBase)
    #expect(composed.blockDevices.map(\.pciAddress) == fixture.plan.bootDevices.map(\.pciAddress))
    #expect(composed.blockDevices.map(\.blockDevice.storage.readOnly) == [false, true])
    #expect(try barAddress(composed.blockDevices[0]) == DoryPCV1ABI.systemDiskBARAddress)
    #expect(try barAddress(composed.blockDevices[1]) == DoryPCV1ABI.removableMediaBARAddress)
    #expect(composed.displayDevice.pciAddress == DoryPCV1ABI.displayPCIAddress)
    #expect(composed.keyboardDevice.pciAddress == DoryPCV1ABI.keyboardPCIAddress)
    #expect(composed.soundDevice.pciAddress == DoryPCV1ABI.soundPCIAddress)
    #expect(composed.xhciController.pciAddress == DoryPCV1ABI.xhciPCIAddress)
    #expect(composed.networkDevice.pciAddress == DoryPCV1ABI.networkPCIAddress)
    #expect(composed.entropyDevice.pciAddress == DoryPCV1ABI.entropyPCIAddress)
    #expect(try composed.machine.run(maximumInstructions: 1) == .instructionBudget(1))
  }

  @Test func rejectsMissingStorageReadOnlyMismatchAndGenerationDrift() throws {
    let fixture = try PCUEFIMachineFixture()
    defer { fixture.remove() }
    let system = DoryVirtioInMemoryBlockStorage(byteCount: 512)
    let installer = DoryVirtioInMemoryBlockStorage(byteCount: 512, readOnly: true)

    #expect(throws: DoryPCUEFIMachineError.missingBootStorage("installer-iso")) {
      _ = try fixture.compose([
        .init(logicalID: "system-disk", storage: system)
      ])
    }
    #expect(
      throws: DoryPCUEFIMachineError.bootStorageReadOnlyMismatch(
        logicalID: "installer-iso",
        expected: true,
        actual: false
      )
    ) {
      _ = try fixture.compose([
        .init(logicalID: "system-disk", storage: system),
        .init(
          logicalID: "installer-iso",
          storage: DoryVirtioInMemoryBlockStorage(byteCount: 512)
        ),
      ])
    }

    let driftedPlan = try DoryPCUEFILaunchPlan(
      firmware: fixture.firmware.manifest,
      variableStoreGeneration: 2,
      bootDevices: fixture.plan.bootDevices,
      bootOrder: fixture.plan.bootOrder
    )
    #expect(
      throws: DoryPCUEFIMachineError.variableStoreGenerationMismatch(expected: 2, actual: 1)
    ) {
      _ = try DoryPCUEFIMachine(
        plan: driftedPlan,
        firmware: fixture.firmware,
        variableStore: .init(file: fixture.store),
        bootStorage: [
          .init(logicalID: "system-disk", storage: system),
          .init(logicalID: "installer-iso", storage: installer),
        ],
        memoryBytes: 2 * 1024 * 1024
      )
    }
  }

  private func barAddress(_ device: DoryPCVirtioBlockPCIDevice) throws -> UInt64 {
    let bytes = try device.readConfiguration(offset: 0x10, byteCount: 4)
    return UInt64(
      bytes.enumerated().reduce(into: UInt32(0)) {
        $0 |= UInt32($1.element) << UInt32($1.offset * 8)
      } & 0xffff_fff0
    )
  }
}

private final class PCUEFIMachineFixture {
  let directory: String
  let store: DoryUEFIVariableStoreFile
  let firmware: DoryVerifiedFirmwareArtifacts
  let plan: DoryPCUEFILaunchPlan

  init() throws {
    var code = Data(repeating: 0xf4, count: 4_096)
    code[code.count - 16] = 0x90
    let bundle = try DoryFirmwareBundleBuilder.build(
      .init(
        platform: .pcV1,
        buildIdentifier: "dory-pc-machine-test",
        source: DoryFirmwareSourcePin(
          repository: "https://github.com/tianocore/edk2.git",
          revision: String(repeating: "a", count: 40)
        ),
        sourceDateEpoch: 1,
        platformConfiguration: Data("DoryPC.dsc".utf8),
        toolchainDescriptor: Data("clang".utf8),
        firmwareCode: code,
        secureBootPolicy: .disabled
      )
    )
    firmware = try DoryVerifiedFirmwareArtifacts(
      manifest: bundle.manifest,
      firmwareCode: bundle.firmwareCode,
      variableStoreTemplate: bundle.variableStoreTemplate,
      sbom: bundle.sbom
    )
    directory =
      FileManager.default.temporaryDirectory
      .appendingPathComponent("dory-pc-uefi-machine-\(UUID().uuidString)", isDirectory: true).path
    store = try DoryUEFIVariableStoreFile(directory: directory)
    try store.initialize(firmware.initialVariableStore)
    let system = try DoryPCUEFIBootDevice(
      logicalID: "system-disk",
      kind: .systemDisk,
      pciAddress: DoryPCUEFIBootDevice.systemDiskAddress,
      readOnly: false
    )
    let installer = try DoryPCUEFIBootDevice(
      logicalID: "installer-iso",
      kind: .removableMedia,
      pciAddress: DoryPCUEFIBootDevice.removableMediaAddress,
      readOnly: true
    )
    plan = try DoryPCUEFILaunchPlan(
      firmware: firmware.manifest,
      variableStoreGeneration: 1,
      bootDevices: [system, installer],
      bootOrder: [installer.logicalID, system.logicalID]
    )
  }

  func compose(_ storage: [DoryPCUEFIBootStorage]) throws -> DoryPCUEFIMachine {
    try DoryPCUEFIMachine(
      plan: plan,
      firmware: firmware,
      variableStore: .init(file: store),
      bootStorage: storage,
      memoryBytes: 2 * 1024 * 1024
    )
  }

  func remove() { try? FileManager.default.removeItem(atPath: directory) }
}
