import DoryDBTX86
import Foundation
import Testing

@testable import DoryMachinePC

@Suite struct DoryPCPMTimerCoherenceTests {
  @Test func timerWidthMatchesFADTAndWrapsAt24Bits() throws {
    let fadt = try DoryPCACPIBuilder.build().fadt
    let flags = (0..<4).reduce(UInt32(0)) { $0 | UInt32(fadt[112 + $1]) << ($1 * 8) }
    #expect(flags & (1 << 8) == 0)  // TMR_VAL_EXT: zero means 24 counter bits.
    #expect(fadt[91] == 4)          // PM_TMR_LEN remains a 32-bit register access.
    let controller = DoryPCPowerController()
    let port = DoryPCACPMPMTimerPort(controller: controller)
    #expect(DoryPCPowerController.pmTimerFrequencyHz == 3_579_545)
    #expect(try port.read(portOffset: 0, width: .doubleword) == 0)
    controller.advancePMTimer(by: 0x00FF_FFFF)
    #expect(try port.read(portOffset: 0, width: .doubleword) == 0x00FF_FFFF)
    controller.advancePMTimer(by: 1)
    #expect(try port.read(portOffset: 0, width: .doubleword) == 0)
    controller.advancePMTimer(by: (1 << 32) + 7)
    #expect(try port.read(portOffset: 0, width: .doubleword) == 7)
    controller.advancePMTimer(by: .max)
    #expect(try port.read(portOffset: 0, width: .doubleword) == 6)
    controller.advancePMTimer(by: 0)
    #expect(try port.read(portOffset: 0, width: .doubleword) == 6)
  }

  @Test func deterministicSlicesRetainFractionalPMTimerTicksAcrossExecutionTiers() throws {
    for tier in executionTiers {
      let machine = try makeMachine(tier: tier)
      var elapsedTicks: UInt64 = 0
      for budget: UInt64 in [1, 1, 1, 7, 17, 973] {
        #expect(try machine.run(maximumInstructions: budget) == .instructionBudget(budget))
        elapsedTicks += budget
        try expectCoherentClocks(machine, elapsedMachineTicks: elapsedTicks)
      }
      #expect(try readPMTimer(machine) == 357)
    }
  }

  @Test func hostClockPreservesSubTickTimeAndCoherentCalibrationThroughPMTimerWrap() throws {
    for tier in executionTiers {
      let clock = ManualClock()
      let machine = try makeMachine(tier: tier, clockSource: clock.source)
      #expect(try machine.run(maximumInstructions: 1) == .instructionBudget(1))
      var elapsedNanoseconds: UInt64 = 0
      // At 100 ms the PM timer reads 357954, while HPET reads 1000000. The final
      // five-second sample crosses the advertised 24-bit PM timer wrap.
      for increment: UInt64 in [99, 1, 99, 1, 100, 999_700, 99_000_000, 4_900_000_000] {
        clock.advance(nanoseconds: increment)
        elapsedNanoseconds += increment
        #expect(try machine.run(maximumInstructions: 1) == .instructionBudget(1))
        try expectCoherentClocks(machine, elapsedMachineTicks: elapsedNanoseconds / 100)
      }
      #expect(elapsedNanoseconds == 5_000_000_000)
      #expect(try readPMTimer(machine) == 1_120_509)
      // Extra retirement at an unchanged host sample advances none of the devices.
      #expect(try machine.run(maximumInstructions: 32) == .instructionBudget(32))
      try expectCoherentClocks(machine, elapsedMachineTicks: 50_000_000)
    }
  }

  @Test func hostResumeDropsSuspendedTimeWithoutDiscardingPMOscillatorFraction() throws {
    let clock = ManualClock()
    let machine = try makeMachine(clockSource: clock.source)
    _ = try machine.run(maximumInstructions: 1)
    clock.advance(nanoseconds: 200)
    _ = try machine.run(maximumInstructions: 1)
    try expectCoherentClocks(machine, elapsedMachineTicks: 2)
    #expect(try readPMTimer(machine) == 0)

    clock.suspendAndResume(after: 30_000_000_000)
    _ = try machine.run(maximumInstructions: 1)
    try expectCoherentClocks(machine, elapsedMachineTicks: 2)
    clock.advance(nanoseconds: 100)
    _ = try machine.run(maximumInstructions: 1)
    try expectCoherentClocks(machine, elapsedMachineTicks: 3)
    #expect(try readPMTimer(machine) == 1)
  }

  @Test func selectedTSCRateRetainsFractionsAcrossTiersWithoutChangingOtherOscillators() throws {
    for tier in executionTiers {
      for frequency: UInt64 in [1, 3_579_545, 1_000_000_003, .max] {
        let machine = try makeMachine(tier: tier, tscFrequencyHz: frequency)
        var elapsedTicks: UInt64 = 0
        for budget: UInt64 in [1, 1, 1, 7, 17, 973] {
          #expect(try machine.run(maximumInstructions: budget) == .instructionBudget(budget))
          elapsedTicks += budget
          // Independent 128-bit arithmetic gives the exact mathematical result here.
          let expected = UInt64(10_000_000).dividingFullWidth(
            elapsedTicks.multipliedFullWidth(by: frequency)
          ).quotient
          #expect(machine.state?.tsc == expected)
          #expect(machine.hpet.snapshot().mainCounter == elapsedTicks)
          #expect(try readPMTimer(machine) == UInt32(elapsedTicks * 3_579_545 / 10_000_000))
        }
      }
    }
  }

  @Test func hostTSCRateWrapsOnlyTheCounterAndExcludesSuspendedTime() throws {
    let clock = ManualClock()
    let machine = try makeMachine(clockSource: clock.source, tscFrequencyHz: .max)
    _ = try machine.run(maximumInstructions: 1)
    clock.advance(nanoseconds: 1_000_000_000)
    _ = try machine.run(maximumInstructions: 1)
    #expect(machine.state?.tsc == UInt64.max)
    clock.suspendAndResume(after: 30_000_000_000)
    _ = try machine.run(maximumInstructions: 1)
    #expect(machine.state?.tsc == UInt64.max)
    clock.advance(nanoseconds: 1_000_000_000)
    _ = try machine.run(maximumInstructions: 1)
    #expect(machine.state?.tsc == UInt64.max - 1)
    #expect(machine.hpet.snapshot().mainCounter == 20_000_000)
    #expect(try readPMTimer(machine) == 7_159_090)
  }

  @Test func zeroTSCRateRejectsBeforeMachineAllocationAcrossTiers() throws {
    for tier in executionTiers {
      #expect(throws: DoryPCMachineError.invalidTSCFrequency(0)) {
        try makeMachine(tier: tier, tscFrequencyHz: 0)
      }
    }
  }

  private func expectCoherentClocks(
    _ machine: DoryPCDirectKernelMachine,
    elapsedMachineTicks: UInt64
  ) throws {
    let pmTicks = elapsedMachineTicks * 3_579_545 / 10_000_000
    #expect(try readPMTimer(machine) == UInt32(pmTicks & 0x00FF_FFFF))
    #expect(machine.hpet.snapshot().mainCounter == elapsedMachineTicks)
    #expect(machine.state?.tsc == elapsedMachineTicks * 100)
    let pitTicks = elapsedMachineTicks * 1_193_182 / 10_000_000
    #expect(machine.legacyPIT.snapshot().current == 65_536 - UInt32(pitTicks % 65_536))
    let apicTicks = min(elapsedMachineTicks * 100, UInt64(UInt32.max))
    #expect(machine.localAPIC.snapshot().timer.currentCount == UInt32.max - UInt32(apicTicks))
  }

  private func readPMTimer(_ machine: DoryPCDirectKernelMachine) throws -> UInt32 {
    try machine.ioBus.read(port: DoryPCPowerController.pmTimerPort, width: .doubleword)
  }

  private var executionTiers: [DoryPCExecutionTier] {
    #if arch(arm64)
      [.interpreter, .baselineJIT, .optimizingJIT]
    #else
      [.interpreter]
    #endif
  }

  private func makeMachine(
    tier: DoryPCExecutionTier = .interpreter,
    clockSource: DoryPCClockSource = .deterministic,
    tscFrequencyHz: UInt64 = 1_000_000_000
  ) throws -> DoryPCDirectKernelMachine {
    let baseline = DoryX86CPUProfile.compatibleV1
    let profile = DoryX86CPUProfile(
      identifier: "pm-timer-tsc-\(tscFrequencyHz)-mechanism-test",
      features: baseline.features,
      physicalAddressBits: baseline.physicalAddressBits,
      linearAddressBits: baseline.linearAddressBits,
      virtualTSCFrequencyHz: tscFrequencyHz
    )
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      interpreter: .init(profile: profile),
      executionTier: tier,
      baselineJITMaximumCodeBytes: 64 * 1024,
      optimizingJITWarmupDispatches: 0,
      clockSource: clockSource
    )
    try machine.load(kernel: makeLoopELF(), commandLine: "x")
    try machine.physicalMemory.writeScalar(
      at: DoryPCV1ABI.hpetBase + 0x10, value: UInt64(1), byteCount: 8
    )
    // Rate-generator channel 0 counts at the board's PIT oscillator; IF remains clear.
    try machine.ioBus.write(port: 0x43, value: 0x34, width: .byte)
    try machine.ioBus.write(port: 0x40, value: 0, width: .byte)
    try machine.ioBus.write(port: 0x40, value: 0, width: .byte)
    try machine.physicalMemory.writeScalar(
      at: DoryPCV1ABI.localAPICBase + 0x3E0, value: UInt64(0xB), byteCount: 4
    )
    try machine.physicalMemory.writeScalar(
      at: DoryPCV1ABI.localAPICBase + 0x320, value: UInt64(0x0001_0040), byteCount: 4
    )
    try machine.physicalMemory.writeScalar(
      at: DoryPCV1ABI.localAPICBase + 0x380, value: UInt64(UInt32.max), byteCount: 4
    )
    return machine
  }

  private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var nanoseconds: UInt64 = 0
    private var generation: UInt32 = 0

    var source: DoryPCClockSource {
      .hostMonotonic(
        { self.lock.withLock { self.nanoseconds } },
        discontinuityGeneration: { self.lock.withLock { self.generation } }
      )
    }

    func advance(nanoseconds: UInt64) {
      lock.withLock { self.nanoseconds += nanoseconds }
    }

    func suspendAndResume(after nanoseconds: UInt64) {
      lock.withLock {
        self.nanoseconds += nanoseconds
        generation &+= 1
      }
    }
  }

  private func makeLoopELF() -> Data {
    var data = Data(repeating: 0, count: 0x202)
    data.replaceSubrange(0..<7, with: [0x7F, 0x45, 0x4C, 0x46, 2, 1, 1])
    write(UInt16(2), to: &data, at: 16)
    write(UInt16(0x3E), to: &data, at: 18)
    write(UInt32(1), to: &data, at: 20)
    write(UInt64(0x40), to: &data, at: 32)
    write(UInt16(64), to: &data, at: 52)
    write(UInt16(56), to: &data, at: 54)
    write(UInt16(2), to: &data, at: 56)
    write(UInt32(1), to: &data, at: 0x40)
    write(UInt32(5), to: &data, at: 0x44)
    write(UInt64(0x200), to: &data, at: 0x48)
    write(UInt64(0x10_0000), to: &data, at: 0x50)
    write(UInt64(0x10_0000), to: &data, at: 0x58)
    write(UInt64(2), to: &data, at: 0x60)
    write(UInt64(2), to: &data, at: 0x68)
    write(UInt32(4), to: &data, at: 0x78)
    write(UInt64(0x180), to: &data, at: 0x80)
    write(UInt64(20), to: &data, at: 0x98)
    write(UInt64(20), to: &data, at: 0xA0)
    write(UInt32(4), to: &data, at: 0x180)
    write(UInt32(4), to: &data, at: 0x184)
    write(UInt32(0x12), to: &data, at: 0x188)
    data.replaceSubrange(0x18C..<0x190, with: [0x58, 0x65, 0x6E, 0])
    write(UInt32(0x10_0000), to: &data, at: 0x190)
    data.replaceSubrange(0x200..<0x202, with: [0xEB, 0xFE])
    return data
  }

  private func write<T: FixedWidthInteger>(_ value: T, to data: inout Data, at offset: Int) {
    for index in 0..<MemoryLayout<T>.size {
      data[offset + index] = UInt8(truncatingIfNeeded: value >> T(index * 8))
    }
  }
}
