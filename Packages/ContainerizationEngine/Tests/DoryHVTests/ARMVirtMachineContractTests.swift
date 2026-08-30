import CryptoKit
import DoryMachineARMVirt
import DoryFirmware
import DoryVMContracts
import Foundation
import Testing

@testable import DoryHV

#if arch(arm64)
  @Suite struct ARMVirtMachineContractTests {
    @Test func liveGuestLayoutIsAnExactProjectionOfTheFrozenABI() {
        #expect(DoryARMVirtV1Topology.requiredMachineABIIdentity == DoryARMVirtV1ABI.identity)
      #expect(GuestLayout.gicDistributorBase == DoryARMVirtV1ABI.gicDistributorBase)
      #expect(GuestLayout.firmwareCodeBase == DoryARMVirtV1ABI.firmwareCodeBase)
      #expect(GuestLayout.firmwareCodeBytes == DoryARMVirtV1ABI.firmwareCodeBytes)
      #expect(GuestLayout.firmwareVariableBase == DoryARMVirtV1ABI.firmwareVariableBase)
      #expect(GuestLayout.firmwareVariableBytes == DoryARMVirtV1ABI.firmwareVariableBytes)
      #expect(GuestLayout.gicRedistributorBase == DoryARMVirtV1ABI.gicRedistributorBase)
      #expect(GuestLayout.uartBase == DoryARMVirtV1ABI.uartBase)
      #expect(GuestLayout.uartIRQ == DoryARMVirtV1ABI.uartSPI)
      #expect(GuestLayout.rtcBase == DoryARMVirtV1ABI.rtcBase)
      #expect(GuestLayout.virtioBase == DoryARMVirtV1ABI.virtioBase)
      #expect(GuestLayout.virtioSlotSize == DoryARMVirtV1ABI.virtioSlotBytes)
      #expect(GuestLayout.virtioSlotCount == DoryARMVirtV1ABI.virtioSlotCount)
      #expect(GuestLayout.virtioFirstIRQ == DoryARMVirtV1ABI.virtioFirstSPI)
      #expect(GuestLayout.ramBase == DoryARMVirtV1ABI.ramBase)
      #expect(GuestLayout.dtbOffset == DoryARMVirtV1ABI.dtbOffset)
      #expect(GuestLayout.initrdOffset == DoryARMVirtV1ABI.initrdOffset)
      #expect(GuestLayout.daxWindowBase == DoryARMVirtV1ABI.daxWindowBase)
    }

    @Test func machineConfigurationRejectsResourcesOutsideTheABI() {
      let tooLittleMemory = MachineConfiguration(
        kernelPath: "/unused",
        commandLine: "",
        memoryBytes: DoryARMVirtV1ABI.minimumMemoryBytes - 1,
        cpuCount: 1
      )
      #expect(throws: VMError.self) {
        try tooLittleMemory.validateDoryARMVirtV1()
      }

      let tooManyCPUs = MachineConfiguration(
        kernelPath: "/unused",
        commandLine: "",
        memoryBytes: DoryARMVirtV1ABI.minimumMemoryBytes,
        cpuCount: DoryARMVirtV1ABI.maximumVCPUCount + 1
      )
      #expect(throws: VMError.self) {
        try tooManyCPUs.validateDoryARMVirtV1()
      }
    }

    @Test func UEFIMachineConfigurationPinsVerifiedArtifactsAndVariableGeneration() throws {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("dory-machine-uefi-\(UUID().uuidString)", isDirectory: true).path
      defer { try? FileManager.default.removeItem(atPath: directory) }
      let store = try DoryUEFIVariableStoreFile(directory: directory)
      let initial = try DoryUEFIVariableStoreSnapshot()
      try store.initialize(initial)
      let artifacts = try firmwareArtifacts()
      let systemDisk = try DoryARMVirtUEFIBootDevice(
        logicalID: "system",
        kind: .systemDisk,
        virtioSlot: 0,
        readOnly: false
      )
      let launchPlan = try DoryARMVirtUEFILaunchPlan(
        firmware: artifacts.manifest,
        variableStoreGeneration: initial.generation,
        bootDevices: [systemDisk],
        bootOrder: [systemDisk.logicalID]
      )
      let configuration = MachineConfiguration(
        uefiLaunchPlan: launchPlan,
        artifacts: artifacts,
        variableStore: store,
        memoryBytes: DoryARMVirtV1ABI.minimumMemoryBytes,
        cpuCount: 1
      )
      try configuration.validateDoryARMVirtV1()
      guard case .uefi(let admittedPlan, let admittedArtifacts, _) = configuration.boot else {
        Issue.record("UEFI configuration became a different boot protocol")
        return
      }
      #expect(admittedPlan == launchPlan)
      #expect(admittedArtifacts.manifest == artifacts.manifest)

      let changed = try initial.setting(DoryUEFIVariable(
        key: DoryUEFIVariableKey(vendor: UUID(), name: "Changed"),
        attributes: [.nonVolatile],
        data: Data([1])
      ))
      try store.commit(changed, expectedGeneration: initial.generation)
      #expect(throws: VMError.self) { try configuration.validateDoryARMVirtV1() }
    }

    @Test func hostGICMustFitTheFrozenReservations() throws {
      try Machine.validateGICLayout(
        distributorBytes: DoryARMVirtV1ABI.gicDistributorReservedBytes,
        redistributorBytes: DoryARMVirtV1ABI.gicRedistributorReservedBytes
      )
      #expect(throws: VMError.self) {
        try Machine.validateGICLayout(
          distributorBytes: DoryARMVirtV1ABI.gicDistributorReservedBytes + 1,
          redistributorBytes: DoryARMVirtV1ABI.gicRedistributorReservedBytes
        )
      }
    }

    @Test func hostTimerInterruptsMustMatchTheFrozenABI() throws {
      try Machine.validateTimerInterrupts(
        virtual: 16 + DoryARMVirtV1ABI.virtualTimerPPI,
        physical: 16 + DoryARMVirtV1ABI.nonsecurePhysicalTimerPPI,
        hypervisor: 16 + DoryARMVirtV1ABI.hypervisorPhysicalTimerPPI
      )
      #expect(throws: VMError.self) {
        try Machine.validateTimerInterrupts(virtual: 0, physical: 0, hypervisor: 0)
      }
    }

    private func firmwareArtifacts() throws -> DoryVerifiedFirmwareArtifacts {
      let firmware = Data(repeating: 0xa5, count: 4_096)
      let variables = Data(#"{"generation":1,"variables":[]}"#.utf8)
      let sbom = Data(#"{"bomFormat":"CycloneDX","specVersion":"1.6"}"#.utf8)
      let digest: (Data) -> String = { data in
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      }
      let manifest = try DoryFirmwareArtifactManifest(
        buildIdentifier: "dory-armvirt-fw-test.1",
        source: DoryFirmwareSourcePin(
          repository: "https://github.com/tianocore/edk2.git",
          revision: String(repeating: "a", count: 40)
        ),
        sourceDateEpoch: 1_788_048_000,
        platformConfigurationSHA256: digest(Data("DoryARMVirt.dsc".utf8)),
        toolchainSHA256: digest(Data("clang-17F109".utf8)),
        firmwareCodeSHA256: digest(firmware),
        firmwareCodeByteCount: UInt64(firmware.count),
        variableStoreTemplateSHA256: digest(variables),
        variableStoreTemplateByteCount: UInt64(variables.count),
        sbomSHA256: digest(sbom),
        secureBootPolicy: .userManagedKeys,
        reproducible: true
      )
      return try DoryVerifiedFirmwareArtifacts(
        manifest: manifest,
        firmwareCode: firmware,
        variableStoreTemplate: variables,
        sbom: sbom
      )
    }
  }
#endif
