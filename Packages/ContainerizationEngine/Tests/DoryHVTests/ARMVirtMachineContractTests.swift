import DoryMachineARMVirt
import Testing

@testable import DoryHV

#if arch(arm64)
  @Suite struct ARMVirtMachineContractTests {
    @Test func liveGuestLayoutIsAnExactProjectionOfTheFrozenABI() {
      #expect(GuestLayout.gicDistributorBase == DoryARMVirtV1ABI.gicDistributorBase)
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
  }
#endif
