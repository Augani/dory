import CryptoKit
import DoryFirmware
import DoryMachineARMVirt
import Foundation
import Testing

@Suite struct DoryARMVirtUEFILaunchPlanTests {
  @Test func installerAndDiskPlanIsCanonicalAndPinsResetState() throws {
    let firmware = try manifest()
    let system = try DoryARMVirtUEFIBootDevice(
      logicalID: "system-disk",
      kind: .systemDisk,
      virtioSlot: 0,
      readOnly: false
    )
    let installer = try DoryARMVirtUEFIBootDevice(
      logicalID: "installer-iso",
      kind: .removableMedia,
      virtioSlot: 12,
      readOnly: true
    )
    let plan = try DoryARMVirtUEFILaunchPlan(
      firmware: firmware,
      variableStoreGeneration: 7,
      bootDevices: [system, installer],
      bootOrder: [installer.logicalID, system.logicalID]
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let encoded = try encoder.encode(plan)

    #expect(
      plan.initialCPUState
        == (try DoryARMVirtV1InitialCPUState.uefi(
          deviceTreeAddress: DoryARMVirtV1ABI.ramBase + DoryARMVirtV1ABI.dtbOffset
        ))
    )
    #expect(plan.bootDevices.map(\.virtioSlot) == [0, 12])
    #expect(plan.bootOrder == ["installer-iso", "system-disk"])
    #expect(try JSONDecoder().decode(DoryARMVirtUEFILaunchPlan.self, from: encoded) == plan)
  }

  @Test func deviceBindingsAndBootOrderFailClosed() throws {
    let firmware = try manifest()
    #expect(throws: DoryARMVirtUEFILaunchPlanError.invalidDeviceBinding("system")) {
      _ = try DoryARMVirtUEFIBootDevice(
        logicalID: "system",
        kind: .systemDisk,
        virtioSlot: 12,
        readOnly: false
      )
    }
    #expect(throws: DoryARMVirtUEFILaunchPlanError.invalidDeviceBinding("iso")) {
      _ = try DoryARMVirtUEFIBootDevice(
        logicalID: "iso",
        kind: .removableMedia,
        virtioSlot: 12,
        readOnly: false
      )
    }
    let system = try DoryARMVirtUEFIBootDevice(
      logicalID: "system",
      kind: .systemDisk,
      virtioSlot: 0,
      readOnly: false
    )
    #expect(throws: DoryARMVirtUEFILaunchPlanError.invalidBootOrder) {
      _ = try DoryARMVirtUEFILaunchPlan(
        firmware: firmware,
        variableStoreGeneration: 1,
        bootDevices: [system],
        bootOrder: ["other"]
      )
    }
  }

  @Test func noncanonicalDevicesAndUnknownFieldsAreRejected() throws {
    let firmware = try manifest()
    let system = try DoryARMVirtUEFIBootDevice(
      logicalID: "system",
      kind: .systemDisk,
      virtioSlot: 0,
      readOnly: false
    )
    let installer = try DoryARMVirtUEFIBootDevice(
      logicalID: "iso",
      kind: .removableMedia,
      virtioSlot: 12,
      readOnly: true
    )
    #expect(throws: DoryARMVirtUEFILaunchPlanError.nonCanonicalBootDevices) {
      _ = try DoryARMVirtUEFILaunchPlan(
        firmware: firmware,
        variableStoreGeneration: 1,
        bootDevices: [installer, system],
        bootOrder: ["iso", "system"]
      )
    }

    let plan = try DoryARMVirtUEFILaunchPlan(
      firmware: firmware,
      variableStoreGeneration: 1,
      bootDevices: [system],
      bootOrder: ["system"]
    )
    let data = try JSONEncoder().encode(plan)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["future"] = true
    #expect(
      throws: DoryFirmwareError.unknownFields(
        type: "DoryARMVirtUEFILaunchPlan",
        fields: ["future"]
      )
    ) {
      _ = try JSONDecoder().decode(
        DoryARMVirtUEFILaunchPlan.self,
        from: JSONSerialization.data(withJSONObject: object)
      )
    }
  }

  private func manifest() throws -> DoryFirmwareArtifactManifest {
    let firmware = Data(repeating: 0xa5, count: 4_096)
    let variables = Data("variables".utf8)
    let sbom = Data("sbom".utf8)
    return try DoryFirmwareArtifactManifest(
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
