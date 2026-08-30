import CryptoKit
import DoryDBTX86
import DoryFirmware
import DoryMachinePC
import Foundation
import Testing

@Suite struct DoryPCUEFILaunchPlanTests {
  @Test func installerAndDiskPlanPinsPCFirmwareAndResetState() throws {
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
    let plan = try DoryPCUEFILaunchPlan(
      firmware: manifest(),
      variableStoreGeneration: 7,
      bootDevices: [system, installer],
      bootOrder: [installer.logicalID, system.logicalID]
    )
    let encoded = try JSONEncoder().encode(plan)

    #expect(plan.firmware.platform == .pcV1)
    #expect(plan.initialCPUState == DoryX86ArchitecturalState.reset())
    #expect(plan.initialCPUState.cs.base + plan.initialCPUState.rip == 0xFFFF_FFF0)
    #expect(plan.bootOrder == ["installer-iso", "system-disk"])
    #expect(try JSONDecoder().decode(DoryPCUEFILaunchPlan.self, from: encoded) == plan)
  }

  @Test func deviceBindingsAndBootOrderFailClosed() throws {
    #expect(throws: DoryPCUEFILaunchPlanError.invalidDeviceBinding("system")) {
      _ = try DoryPCUEFIBootDevice(
        logicalID: "system",
        kind: .systemDisk,
        pciAddress: DoryPCUEFIBootDevice.removableMediaAddress,
        readOnly: false
      )
    }
    #expect(throws: DoryPCUEFILaunchPlanError.invalidDeviceBinding("iso")) {
      _ = try DoryPCUEFIBootDevice(
        logicalID: "iso",
        kind: .removableMedia,
        pciAddress: DoryPCUEFIBootDevice.removableMediaAddress,
        readOnly: false
      )
    }
    let system = try DoryPCUEFIBootDevice(
      logicalID: "system",
      kind: .systemDisk,
      pciAddress: DoryPCUEFIBootDevice.systemDiskAddress,
      readOnly: false
    )
    #expect(throws: DoryPCUEFILaunchPlanError.invalidBootOrder) {
      _ = try DoryPCUEFILaunchPlan(
        firmware: manifest(),
        variableStoreGeneration: 1,
        bootDevices: [system],
        bootOrder: ["other"]
      )
    }
  }

  @Test func armFirmwareAndUnknownFieldsAreRejected() throws {
    let system = try DoryPCUEFIBootDevice(
      logicalID: "system",
      kind: .systemDisk,
      pciAddress: DoryPCUEFIBootDevice.systemDiskAddress,
      readOnly: false
    )
    #expect(throws: DoryPCUEFILaunchPlanError.self) {
      _ = try DoryPCUEFILaunchPlan(
        firmware: manifest(platform: .armVirtV1),
        variableStoreGeneration: 1,
        bootDevices: [system],
        bootOrder: ["system"]
      )
    }
    let plan = try DoryPCUEFILaunchPlan(
      firmware: manifest(),
      variableStoreGeneration: 1,
      bootDevices: [system],
      bootOrder: ["system"]
    )
    var object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any]
    )
    object["future"] = true
    #expect(
      throws: DoryFirmwareError.unknownFields(
        type: "DoryPCUEFILaunchPlan",
        fields: ["future"]
      )
    ) {
      _ = try JSONDecoder().decode(
        DoryPCUEFILaunchPlan.self,
        from: JSONSerialization.data(withJSONObject: object)
      )
    }
  }

  private func manifest(
    platform: DoryFirmwarePlatform = .pcV1
  ) throws -> DoryFirmwareArtifactManifest {
    let firmware = Data(repeating: 0xA5, count: 4_096)
    let variables = Data("variables".utf8)
    let sbom = Data("sbom".utf8)
    return try DoryFirmwareArtifactManifest(
      platform: platform,
      buildIdentifier: "test",
      source: DoryFirmwareSourcePin(
        repository: "https://github.com/tianocore/edk2.git",
        revision: String(repeating: "a", count: 40)
      ),
      sourceDateEpoch: 1,
      platformConfigurationSHA256: digest(Data("platform".utf8)),
      toolchainSHA256: digest(Data("toolchain".utf8)),
      firmwareCodeSHA256: digest(firmware),
      firmwareCodeByteCount: UInt64(firmware.count),
      variableStoreTemplateSHA256: digest(variables),
      variableStoreTemplateByteCount: UInt64(variables.count),
      sbomSHA256: digest(sbom),
      secureBootPolicy: .disabled,
      reproducible: true
    )
  }

  private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
