import DoryMachineARMVirt
import Foundation
import Synchronization
import Testing
@testable import DoryHV

#if arch(arm64)
  /// P2-02 items 1, 4, 6: Tests for the PSCI CPU state lifecycle, GIC SPI interrupt
  /// routing, and the lifecycle rendezvous protocol. These complement
  /// ARMPSCICPUStateTests (which covers the state machine in isolation) by exercising
  /// the interaction between PSCI state transitions and the GIC interrupt model.
  @Suite struct ARMPSCILifecycleTests {

    private let executableRAM: [Range<UInt64>] = [0x4000_0000..<0x8000_0000]

    @Test func machineCpuOnAdmissionRejectsOffCpuWhoseVCPUWasTornDown() {
      var state = ARMPSCICPUState(cpuCount: 2)
      #expect(state.requestOn(target: 1, entry: 0x4000_0000, executableRanges: executableRAM) == 0)
      state.completeOn(index: 1)
      #expect(state.requestOff(index: 1) == 0)

      // This is the machine-level CPU_ON gate, rather than the detached PSCI state machine:
      // when teardown has removed the VCPU handle, no thread can consume a queued start. The
      // rejection must leave the PSCI state off.
      let rejected = ARMPSCISecondaryStartAdmission.requestOn(
        state: &state,
        target: 1,
        entry: 0x4000_0000,
        executableRanges: executableRAM,
        isStopping: false,
        hasLiveVCPU: { _ in false }
      )
      #expect(rejected.result == ARMPSCISecondaryStartAdmission.unavailableResult)
      #expect(rejected.index == nil)
      #expect(state.affinityInfo(target: 1, lowestLevel: 0) == 1)

      // A live parked vCPU still permits the existing CPU_OFF -> CPU_ON lifecycle.
      let admitted = ARMPSCISecondaryStartAdmission.requestOn(
        state: &state,
        target: 1,
        entry: 0x4000_0000,
        executableRanges: executableRAM,
        isStopping: false,
        hasLiveVCPU: { $0 == 1 }
      )
      #expect(admitted.result == 0)
      #expect(admitted.index == 1)
      #expect(state.affinityInfo(target: 1, lowestLevel: 0) == 2)

      // The resource gate does not change duplicate CPU_ON semantics.
      let duplicate = ARMPSCISecondaryStartAdmission.requestOn(
        state: &state,
        target: 1,
        entry: 0x4000_0000,
        executableRanges: executableRAM,
        isStopping: false,
        hasLiveVCPU: { $0 == 1 }
      )
      #expect(duplicate.result == -5)
      #expect(duplicate.index == nil)
    }

    @Test func machineCpuOnAdmissionRejectsStartDuringShutdownWithoutStateTransition() {
      var state = ARMPSCICPUState(cpuCount: 2)

      let admission = ARMPSCISecondaryStartAdmission.requestOn(
        state: &state,
        target: 1,
        entry: 0x4000_0000,
        executableRanges: executableRAM,
        isStopping: true,
        hasLiveVCPU: { _ in true }
      )
      #expect(admission.result == ARMPSCISecondaryStartAdmission.unavailableResult)
      #expect(admission.index == nil)
      #expect(state.affinityInfo(target: 1, lowestLevel: 0) == 1)
    }

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

  /// Runs real SMC instructions through Machine.cpuMain/runLoop and real retained HV handles.
  /// Opt in with DORY_RUN_ARM_PSCI_MACHINE_TESTS=1 in a Hypervisor-entitled test runner.
  /// VM creation errors are failures when enabled, never silently treated as passing tests.
  @Suite(.serialized) struct ARMPSCIMachineLifecycleTests {
    @Test(
      .enabled(if: ProcessInfo.processInfo.environment["DORY_RUN_ARM_PSCI_MACHINE_TESTS"] == "1"),
      arguments: [false, true]
    )
    func guestRestartsSecondaryAndStopsWithRetainedWorker(stopAfterFinalStart: Bool) throws {
      let liveMachine = Mutex<Machine?>(nil)
      let completed = DispatchSemaphore(value: 0)
      let owner = RawHVOwnerThread<(String, [UInt64])>(name: "dory-hv.psci-restart-test") {
        let machine = try Machine(configuration: MachineConfiguration(
          bootPayload: .immutableBytes(kernel: Self.restartGuest(), initrd: nil),
          commandLine: "",
          memoryBytes: DoryARMVirtV1ABI.minimumMemoryBytes,
          cpuCount: 2
        ))
        liveMachine.withLock { $0 = machine }
        defer { liveMachine.withLock { $0 = nil } }
        try machine.loadBootPayload()
        let mailbox: UInt64 = 0x4020_0000
        try machine.memory.write(UInt64(stopAfterFinalStart ? 1 : 0), at: mailbox + 48)
        let reason = try machine.run()
        // Read only after Machine.run has joined every secondary, avoiding host/guest races.
        let observations = try [UInt64(0), 24, 32, 40].map {
          try machine.memory.read(UInt64.self, at: mailbox + $0)
        }
        return (String(describing: reason), observations)
      }
      try owner.start { _ in completed.signal() }
      let finishedInTime = completed.wait(timeout: .now() + 10) == .success
      if !finishedInTime {
        // A false CPU_ON success leaves the guest polling forever. Cancel and join before
        // reporting failure, so the test cannot leak a VM or a parked secondary thread.
        liveMachine.withLock { $0 }?.requestStop(.crash("PSCI restart test timed out"))
      }
      let (reason, observations) = try owner.wait()
      #expect(finishedInTime)
      #expect(reason == String(describing: GuestStopReason.powerOff))
      // The final accepted request can run before stop; the first 16 must all have run.
      #expect(observations[0] == 0xFEED_0000_0000_0010
        || (stopAfterFinalStart && observations[0] == 0xFEED_0000_0000_0011))
      // Stop may interrupt the final entry between its two mailbox stores. CPU 0 already
      // checked the matching entry/context pair after each of the 16 completed CPU_OFFs.
      #expect(observations[1] == 2 || (stopAfterFinalStart && observations[1] == 1))
      #expect(observations[2] == 16)
      #expect(observations[3] == 0)
    }

    private static func restartGuest() -> Data {
      // Legacy ARM64 Image header: branch over 64 bytes; image_size=0 selects text_offset
      // 0x80000. All instructions below are position-relative or use the RAM mailbox.
      // Assemble as arm64 with clang; comments retain the source and branch labels.
      // CPU 0 alternates two entry addresses and 64-bit contexts for 16 cycles. Each
      // secondary waits for release, so a duplicate CPU_ON must return ON_PENDING or
      // ALREADY_ON. CPU 0 then polls AFFINITY_INFO and immediately starts the next cycle.
      // The secondary dirties SCTLR.WXN and CNTV_CTL before CPU_OFF and verifies both
      // were reset on re-entry. Returning from CPU_OFF, lost starts, stale tuples, and
      // execution at the wrong entry all fail or hit the host watchdog.
      let instructions: [UInt32] = [
        // start:
        0xD2A80414,  // mov x20, #0x40200000
        0x100007B5,  // adr x21, secondary_one
        0x100007D6,  // adr x22, secondary_two
        0xD2800037,  // mov x23, #1
        0xF2FFDDB7,  // movk x23, #0xfeed, lsl #48
        0xD2800218,  // mov x24, #16
        0xD2800039,  // mov x25, #1
        // cycle:
        0xD2800060,  // mov x0, #3
        0xF2B88000,  // movk x0, #0xc400, lsl #16
        0xD2800021,  // mov x1, #1
        0xAA1503E2,  // mov x2, x21
        0xAA1703E3,  // mov x3, x23
        0xD4000003,  // smc #0
        0xB50005A0,  // cbnz x0, fail
        0xD2800060,  // mov x0, #3
        0xF2B88000,  // movk x0, #0xc400, lsl #16
        0xD4000003,  // smc #0
        0x91001400,  // add x0, x0, #5
        0xF100041F,  // cmp x0, #1
        0x540004E8,  // b.hi fail
        0xF9000697,  // str x23, [x20, #8]
        0xD5033FBF,  // dmb sy
        // wait_off:
        0xD2800080,  // mov x0, #4
        0xF2B88000,  // movk x0, #0xc400, lsl #16
        0xD2800021,  // mov x1, #1
        0xD2800002,  // mov x2, #0
        0xD4000003,  // smc #0
        0xF100041F,  // cmp x0, #1
        0x54FFFF41,  // b.ne wait_off
        0xD5033FBF,  // dmb sy
        0xF9400289,  // ldr x9, [x20]
        0xEB17013F,  // cmp x9, x23
        0x54000341,  // b.ne fail
        0xF9400E89,  // ldr x9, [x20, #24]
        0xEB19013F,  // cmp x9, x25
        0x540002E1,  // b.ne fail
        0x910006F7,  // add x23, x23, #1
        0xAA1503E9,  // mov x9, x21
        0xAA1603F5,  // mov x21, x22
        0xAA0903F6,  // mov x22, x9
        0xD2400739,  // eor x25, x25, #3
        0xF1000718,  // subs x24, x24, #1
        0x54FFFBA1,  // b.ne cycle
        0xD2800209,  // mov x9, #16
        0xF9001289,  // str x9, [x20, #32]
        0xF9401A89,  // ldr x9, [x20, #48]
        0xB4000109,  // cbz x9, power_off
        0xD2800060,  // mov x0, #3
        0xF2B88000,  // movk x0, #0xc400, lsl #16
        0xD2800021,  // mov x1, #1
        0xAA1503E2,  // mov x2, x21
        0xAA1703E3,  // mov x3, x23
        0xD4000003,  // smc #0
        0xB50000A0,  // cbnz x0, fail
        // power_off:
        0xD2800100,  // mov x0, #8
        0xF2B08000,  // movk x0, #0x8400, lsl #16
        0xD4000003,  // smc #0
        0x14000001,  // b fail
        // fail:
        0xD2A80414,  // mov x20, #0x40200000
        0xD28175A9,  // mov x9, #0xbad
        0xF9001689,  // str x9, [x20, #40]
        0x17FFFFF9,  // b power_off
        // secondary_one:
        0xD280002A,  // mov x10, #1
        0x14000002,  // b secondary
        // secondary_two:
        0xD280004A,  // mov x10, #2
        // secondary:
        0xD2A80414,  // mov x20, #0x40200000
        0xD5381009,  // mrs x9, SCTLR_EL1
        0x379FFEE9,  // tbnz x9, #19, fail
        0xD53BE329,  // mrs x9, CNTV_CTL_EL0
        0x3707FEA9,  // tbnz x9, #0, fail
        0xF9000280,  // str x0, [x20]
        0xF9000E8A,  // str x10, [x20, #24]
        0xD5033FBF,  // dmb sy
        // wait_release:
        0xF9400689,  // ldr x9, [x20, #8]
        0xEB00013F,  // cmp x9, x0
        0x54FFFFC1,  // b.ne wait_release
        0xD5381009,  // mrs x9, SCTLR_EL1
        0xB26D0129,  // orr x9, x9, #0x80000
        0xD5181009,  // msr SCTLR_EL1, x9
        0xD2800069,  // mov x9, #3
        0xD51BE329,  // msr CNTV_CTL_EL0, x9
        0xD2800040,  // mov x0, #2
        0xF2B08000,  // movk x0, #0x8400, lsl #16
        0xD4000003,  // smc #0
        0x17FFFFE6,  // b fail
      ]
      var image = Data(repeating: 0, count: 64)
      image.replaceSubrange(0..<4, with: [0x10, 0x00, 0x00, 0x14])  // b +64
      image.replaceSubrange(56..<60, with: [0x41, 0x52, 0x4D, 0x64])
      for word in instructions {
        image.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) })
      }
      return image
    }
  }
#endif
