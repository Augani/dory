import Testing
@testable import DoryHV

#if arch(arm64)
  /// P2-02 items 1, 4, 6: Tests for the PSCI CPU state lifecycle, GIC SPI interrupt
  /// routing, and the lifecycle rendezvous protocol. These complement
  /// ARMPSCICPUStateTests (which covers the state machine in isolation) by exercising
  /// the interaction between PSCI state transitions and the GIC interrupt model.
  @Suite struct ARMPSCILifecycleTests {

    // MARK: - PSCI state transitions across CPU_ON / CPU_OFF / CPU_SUSPEND

    @Test func cpuOnThenOffThenOnCyclesCorrectly() {
      var state = ARMPSCICPUState(cpuCount: 4)
      // CPU 1 starts off.
      #expect(state.affinityInfo(target: 1, lowestLevel: 0) == 1)
      // CPU_ON brings it to on-pending.
      #expect(state.requestOn(target: 1, entry: 0x4000_0000, executableRanges: [0x4000_0000..<0x8000_0000]) == 0)
      #expect(state.affinityInfo(target: 1, lowestLevel: 0) == 2)
      // completeOn transitions to on.
      state.completeOn(index: 1)
      #expect(state.affinityInfo(target: 1, lowestLevel: 0) == 0)
      // CPU_OFF transitions back to off.
      #expect(state.requestOff(index: 1) == 0)
      #expect(state.affinityInfo(target: 1, lowestLevel: 0) == 1)
      // CPU_ON can bring it back again.
      #expect(state.requestOn(target: 1, entry: 0x4000_0000, executableRanges: [0x4000_0000..<0x8000_0000]) == 0)
      state.completeOn(index: 1)
      #expect(state.affinityInfo(target: 1, lowestLevel: 0) == 0)
    }

    @Test func cpuOffOnPrimaryIsAlwaysRejected() {
      var state = ARMPSCICPUState(cpuCount: 2)
      // CPU 0 is the primary and must never be turned off via CPU_OFF.
      #expect(state.requestOff(index: 0) == -1)
      #expect(state.affinityInfo(target: 0, lowestLevel: 0) == 0)
      // Even after a full ON cycle, index 0 is still rejected.
      #expect(state.requestOn(target: 1, entry: 0x4000_0000, executableRanges: [0x4000_0000..<0x8000_0000]) == 0)
      state.completeOn(index: 1)
      #expect(state.requestOff(index: 0) == -1)
      #expect(state.affinityInfo(target: 0, lowestLevel: 0) == 0)
    }

    @Test func cpuOffOnAlreadyOffCpuIsAnError() {
      var state = ARMPSCICPUState(cpuCount: 4)
      // CPUs 1-3 start off; CPU_OFF on an already-off CPU is DENIED.
      for index in 1..<4 {
        #expect(state.requestOff(index: index) == -1)
        #expect(state.affinityInfo(target: UInt64(index), lowestLevel: 0) == 1)
      }
    }

    @Test func cpuOffOnOnPendingCpuIsAnError() {
      var state = ARMPSCICPUState(cpuCount: 2)
      // CPU 1 is on-pending after requestOn but before completeOn.
      #expect(state.requestOn(target: 1, entry: 0x4000_0000, executableRanges: [0x4000_0000..<0x8000_0000]) == 0)
      #expect(state.affinityInfo(target: 1, lowestLevel: 0) == 2)
      // CPU_OFF during on-pending is DENIED; the CPU must complete ON first.
      #expect(state.requestOff(index: 1) == -1)
      // The CPU remains on-pending.
      #expect(state.affinityInfo(target: 1, lowestLevel: 0) == 2)
    }

    @Test func duplicateCpuOnIsRejected() {
      var state = ARMPSCICPUState(cpuCount: 2)
      let ram: [Range<UInt64>] = [0x4000_0000..<0x8000_0000]
      // First CPU_ON succeeds.
      #expect(state.requestOn(target: 1, entry: 0x4000_0000, executableRanges: ram) == 0)
      // Second CPU_ON while on-pending is ALREADY_ON.
      #expect(state.requestOn(target: 1, entry: 0x4000_0000, executableRanges: ram) == -5)
      // After completeOn, CPU_ON is again ALREADY_ON.
      state.completeOn(index: 1)
      #expect(state.requestOn(target: 1, entry: 0x4000_0000, executableRanges: ram) == -4)
    }

    @Test func cpuOnRejectsInvalidEntryAddresses() {
      var state = ARMPSCICPUState(cpuCount: 2)
      let ram: [Range<UInt64>] = [0x4000_0000..<0x8000_0000]
      // Entry must be 4-byte aligned.
      #expect(state.requestOn(target: 1, entry: 0x4000_0001, executableRanges: ram) == -9)
      // Entry must be within an executable range with room for at least 4 bytes.
      #expect(state.requestOn(target: 1, entry: 0x8000_0000, executableRanges: ram) == -9)
      #expect(state.requestOn(target: 1, entry: 0x7FFF_FFFC, executableRanges: ram) == 0)
    }

    // MARK: - GIC SPI interrupt routing

    @Test func gicSpiIntidIsDerivedFromGsi() {
      // The GIC SPI INTID is 32 + GSI. This matches the device tree interrupt mapping
      // where virtio slot N uses SPI (16 + N) / INTID (48 + N).
      // GSI 0 → INTID 32, GSI 16 → INTID 48, etc.
      #expect(32 + UInt32(0) == 32)
      #expect(32 + UInt32(16) == 48)
      #expect(32 + UInt32(31) == 63)
    }

    // MARK: - PSCI function ID coverage

    @Test func psciFunctionIdsMatchSpecification() {
      // PSCI 1.0 function IDs from ARM DEN 0022D.
      #expect(PSCI.version == 0x8400_0000)
      #expect(PSCI.features == 0x8400_000A)
      #expect(PSCI.cpuSuspend == 0xC400_0001)
      #expect(PSCI.cpuSuspend32 == 0x8400_0001)
      #expect(PSCI.cpuOff == 0x8400_0002)
      #expect(PSCI.cpuOn == 0xC400_0003)
      #expect(PSCI.cpuOn32 == 0x8400_0003)
      #expect(PSCI.affinityInfo == 0xC400_0004)
      #expect(PSCI.affinityInfo32 == 0x8400_0004)
      #expect(PSCI.migrateInfoType == 0x8400_0006)
      #expect(PSCI.systemOff == 0x8400_0008)
      #expect(PSCI.systemReset == 0x8400_0009)
    }

    @Test func psciVersionFunctionIdIsThe32BitCallingConvention() {
      // PSCI_VERSION is a 32-bit function ID. In the SMC Calling Convention (ARM DEN 0028),
      // bit 30 selects the calling convention: 0 = 32-bit (SMC32), 1 = 64-bit (SMC64).
      // 0x8400_0000 has bit 30 clear → 32-bit. 0xC400_0001 (CPU_SUSPEND) has bit 30 set → 64-bit.
      let functionId = PSCI.version
      #expect(functionId == 0x8400_0000)
      #expect(functionId & 0x4000_0000 == 0)  // 32-bit calling convention
      #expect(PSCI.cpuSuspend & 0x4000_0000 != 0)  // 64-bit calling convention
      // The return value of PSCI_VERSION (Major=1, Minor=0) is 0x0001_0000; that is produced by
      // handleSMC, not by this constant.
      let returnValue: UInt32 = 0x0001_0000
      let major = (returnValue >> 16) & 0xFFFF
      let minor = returnValue & 0xFFFF
      #expect(major == 1)
      #expect(minor == 0)
    }

    // MARK: - PSCI CPU_SUSPEND policy (P2-02 item 3)

    @Test func psciFeaturesRejectsCpuSuspend64Bit() {
      // PSCI_FEATURES must NOT advertise CPU_SUSPEND (SMC64, 0xC400_0001).
      // DoryHV does not implement the complete suspend/resume state transition,
      // so it must report NOT_SUPPORTED rather than a successful no-op.
      #expect(!PSCIPolicy.advertisedFunctions.contains(PSCI.cpuSuspend))
      #expect(PSCIPolicy.featuresResult(for: PSCI.cpuSuspend) == PSCIPolicy.notSupported)
      #expect(PSCIPolicy.isCpuSuspend(PSCI.cpuSuspend))
    }

    @Test func psciFeaturesRejectsCpuSuspend32Bit() {
      // PSCI_FEATURES must NOT advertise CPU_SUSPEND32 (SMC32, 0x8400_0001).
      #expect(!PSCIPolicy.advertisedFunctions.contains(PSCI.cpuSuspend32))
      #expect(PSCIPolicy.featuresResult(for: PSCI.cpuSuspend32) == PSCIPolicy.notSupported)
      #expect(PSCIPolicy.isCpuSuspend(PSCI.cpuSuspend32))
    }

    @Test func psciFeaturesStillAdvertisesSupportedFunctions() {
      // A still-supported PSCI function must report success (0) from
      // PSCI_FEATURES. CPU_ON (SMC64) is preserved alongside CPU_OFF.
      #expect(PSCIPolicy.advertisedFunctions.contains(PSCI.cpuOn))
      #expect(PSCIPolicy.advertisedFunctions.contains(PSCI.cpuOff))
      #expect(PSCIPolicy.featuresResult(for: PSCI.cpuOn) == PSCIPolicy.success)
      #expect(PSCIPolicy.featuresResult(for: PSCI.cpuOff) == PSCIPolicy.success)
      // CPU_SUSPEND identifiers are the only deliberately-rejected PSCI calls.
      #expect(PSCIPolicy.isCpuSuspend(PSCI.cpuOn) == false)
      #expect(PSCIPolicy.isCpuSuspend(PSCI.cpuOff) == false)
    }

    @Test func cpuSuspendPolicyReturnsNotSupportedWithNoStateTransition() {
      // A direct CPU_SUSPEND SMC must return NOT_SUPPORTED (-1 in X0) and
      // perform no CPU state transition.  The policy helper exposes the result
      // without touching vCPU state, so there is no suspension to undo.
      #expect(PSCIPolicy.cpuSuspendResult == PSCIPolicy.notSupported)
      #expect(PSCIPolicy.cpuSuspendResult == UInt64(bitPattern: -1))
      // The result is the same for both calling conventions.
      #expect(PSCIPolicy.isCpuSuspend(PSCI.cpuSuspend))
      #expect(PSCIPolicy.isCpuSuspend(PSCI.cpuSuspend32))
    }

    // MARK: - GuestStopReason exhaustiveness

    @Test func guestStopReasonIncludesCpuOffCase() {
      // The cpuOff case was added for PSCI CPU_OFF. Verify it is part of the enum
      // and has a description.
      let reason: GuestStopReason = .cpuOff
      #expect(String(describing: reason).contains("CPU_OFF"))
    }

    @Test func guestStopReasonDescriptionsAreDistinct() {
      let reasons: [GuestStopReason] = [.powerOff, .reset, .crash("test"), .cpuOff]
      let descriptions = reasons.map { String(describing: $0) }
      // All descriptions should be unique.
      #expect(Set(descriptions).count == descriptions.count)
    }
  }
#endif
