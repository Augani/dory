import DoryDBTX86
import DoryMachinePC
import Foundation
import Testing

@Suite struct DoryPCPowerControllerTests {
  @Test func pendingWorkCallbackObservesLatchedActionOutsideControllerLock() throws {
    final class Observation: @unchecked Sendable {
      weak var controller: DoryPCPowerController?
      let finished = DispatchSemaphore(value: 0)
      private let lock = NSLock()
      private var actions: [DoryPCPowerAction] = []

      func observe() {
        // Both calls reacquire the controller lock; invoking us under that lock would deadlock.
        let snapshot = controller?.snapshot()
        let consumed = controller?.consumeRequestedAction()
        #expect(snapshot?.pendingAction == consumed)
        if let consumed { lock.withLock { actions.append(consumed) } }
      }

      func observed() -> [DoryPCPowerAction] { lock.withLock { actions } }
    }
    let observation = Observation()
    let controller = DoryPCPowerController(onPendingWork: { observation.observe() })
    observation.controller = controller
    let thread = Thread {
      controller.request(.powerOff)
      controller.request(.reset)
      do {
        let pm = DoryPCACPIPMControlPort(controller: controller)
        try pm.write(portOffset: 0, value: 0, width: .word)
        try pm.write(portOffset: 0,
          value: UInt32(DoryPCPowerController.softOffSleepType << 10 | 1 << 13), width: .word)
        let reset = DoryPCResetControlPort(controller: controller)
        try reset.write(portOffset: 0, value: 4, width: .byte)
        try reset.write(portOffset: 0, value: UInt32(DoryPCPowerController.resetValue), width: .byte)
      } catch { Issue.record(error) }
      observation.finished.signal()
    }
    thread.start()
    try #require(observation.finished.wait(timeout: .now() + 2) == .success)
    #expect(observation.observed() == [.powerOff, .reset, .powerOff, .reset])
    #expect(controller.consumeRequestedAction() == nil)
  }

  @Test func hostLifecycleRequestUsesTheArchitecturalActionLatch() {
    let controller = DoryPCPowerController()
    controller.request(.powerOff)
    #expect(controller.snapshot().pendingAction == .powerOff)
    #expect(controller.snapshot().lastRequestedAction == .powerOff)
    #expect(controller.snapshot().lastRequestSource == .host)
    #expect(controller.consumeRequestedAction() == .powerOff)
    #expect(controller.snapshot().lastRequestSource == .host)
    #expect(controller.consumeRequestedAction() == nil)
  }

  @Test func softOffRequiresThePublishedSleepTypeAndEnableBit() throws {
    let controller = DoryPCPowerController()
    let port = DoryPCACPIPMControlPort(controller: controller)

    try port.write(portOffset: 0, value: 4 << 10 | 1 << 13, width: .word)
    #expect(controller.consumeRequestedAction() == nil)
    try port.write(
      portOffset: 0,
      value: UInt32(DoryPCPowerController.softOffSleepType << 10 | 1 << 13),
      width: .word
    )

    #expect(controller.snapshot().lastRequestSource == .acpiPMControl)
    #expect(controller.consumeRequestedAction() == .powerOff)
    #expect(try port.read(portOffset: 0, width: .word) & (1 << 13) == 0)
  }

  @Test func resetPortAcceptsOnlyTheFADTResetValue() throws {
    let controller = DoryPCPowerController()
    let port = DoryPCResetControlPort(controller: controller)
    try port.write(portOffset: 0, value: 4, width: .byte)
    #expect(controller.consumeRequestedAction() == nil)
    try port.write(
      portOffset: 0,
      value: UInt32(DoryPCPowerController.resetValue),
      width: .byte
    )
    #expect(controller.snapshot().lastRequestSource == .resetControlPort)
    #expect(controller.consumeRequestedAction() == .reset)
  }

  @Test func machineReportsGuestPowerActionsAsTerminalStops() throws {
    let powerOff = try DoryPCDirectKernelMachine(memoryBytes: 2 * 1024 * 1024)
    try powerOff.ioBus.write(
      port: DoryPCPowerController.pm1ControlPort,
      value: UInt32(DoryPCPowerController.softOffSleepType << 10 | 1 << 13),
      width: .word
    )
    try powerOff.load(kernel: makeMinimalELF())
    #expect(try powerOff.runOnDedicatedStack(maximumInstructions: 1) == .poweredOff(instructionCount: 0))

    let reset = try DoryPCDirectKernelMachine(memoryBytes: 2 * 1024 * 1024)
    try reset.ioBus.write(
      port: DoryPCPowerController.resetPort,
      value: UInt32(DoryPCPowerController.resetValue),
      width: .byte
    )
    try reset.load(kernel: makeMinimalELF())
    #expect(try reset.runOnDedicatedStack(maximumInstructions: 1) == .reset(instructionCount: 0))
  }

  @Test func hostPowerOffInterruptsActiveExecutionWithinOneSecond() throws {
    #if arch(arm64)
      let tiers: [DoryPCExecutionTier] = [.interpreter, .baselineJIT, .optimizingJIT]
    #else
      let tiers: [DoryPCExecutionTier] = [.interpreter]
    #endif

    for tier in tiers {
      let machine = try DoryPCDirectKernelMachine(
        memoryBytes: 2 * 1024 * 1024,
        executionTier: tier,
        baselineJITMaximumCodeBytes: 64 * 1024
      )
      // jmp $ keeps the processor active until the host lifecycle latch is observed.
      try machine.load(kernel: makeMinimalELF(code: [0xEB, 0xFE]))
      let result = PowerOffRunResult()
      let started = DispatchSemaphore(value: 0)
      let finished = DispatchSemaphore(value: 0)
      let thread = Thread {
        started.signal()
        result.store(Result { try machine.run(maximumInstructions: .max) })
        finished.signal()
      }
      thread.name = "dev.dory.tests.pc-power-cancellation"
      thread.stackSize = 2 * 1024 * 1024
      thread.start()
      #expect(started.wait(timeout: .now() + 1) == .success)
      usleep(50_000)

      let requestedAt = DispatchTime.now().uptimeNanoseconds
      machine.powerController.request(.powerOff)
      let completion = finished.wait(timeout: .now() + 1)
      #expect(completion == .success, "active \(tier.rawValue) execution ignored host power-off")
      guard completion == .success else { return }
      let elapsed = DispatchTime.now().uptimeNanoseconds - requestedAt
      #expect(elapsed < 1_000_000_000)
      guard case .poweredOff(let instructionCount) = try result.get() else {
        Issue.record("\(tier.rawValue) did not report poweredOff")
        continue
      }
      #expect(instructionCount > 0, "power-off was not sampled during active execution")
    }
  }
}

private final class PowerOffRunResult: @unchecked Sendable {
  private let lock = NSLock()
  private var result: Result<DoryPCMachineStop, any Error>?

  func store(_ result: Result<DoryPCMachineStop, any Error>) {
    lock.withLock { self.result = result }
  }

  func get() throws -> DoryPCMachineStop {
    try lock.withLock { try result!.get() }
  }
}

private func makeMinimalELF(code: [UInt8] = [0xF4]) -> Data {
  let segmentOffset = 0x200
  var data = Data(repeating: 0, count: segmentOffset + code.count)
  data.replaceSubrange(0..<4, with: [0x7F, 0x45, 0x4C, 0x46])
  data[4] = 2
  data[5] = 1
  data[6] = 1
  write(UInt16(2), to: &data, at: 16)
  write(UInt16(0x3E), to: &data, at: 18)
  write(UInt32(1), to: &data, at: 20)
  write(UInt16(64), to: &data, at: 52)
  write(UInt32(5), to: &data, at: 0x44)
  write(UInt64(0x10_0000), to: &data, at: 0x50)
  write(UInt64(0x40), to: &data, at: 32)
  write(UInt16(56), to: &data, at: 54)
  write(UInt16(2), to: &data, at: 56)
  write(UInt32(1), to: &data, at: 0x40)
  write(UInt64(segmentOffset), to: &data, at: 0x48)
  write(UInt64(0x10_0000), to: &data, at: 0x58)
  write(UInt64(code.count), to: &data, at: 0x60)
  write(UInt64(code.count), to: &data, at: 0x68)
  write(UInt32(4), to: &data, at: 0x78)
  write(UInt64(0x180), to: &data, at: 0x80)
  write(UInt64(20), to: &data, at: 0x98)
  data.replaceSubrange(
    0x180..<0x194,
    with: [
      4, 0, 0, 0, 4, 0, 0, 0, 0x12, 0, 0, 0, 0x58, 0x65, 0x6E, 0,
      0, 0x00, 0x10, 0,
    ])
  data.replaceSubrange(segmentOffset..<(segmentOffset + code.count), with: code)
  return data
}

private func write<T: FixedWidthInteger>(_ value: T, to data: inout Data, at offset: Int) {
  for index in 0..<MemoryLayout<T>.size {
    data[offset + index] = UInt8(truncatingIfNeeded: value >> T(index * 8))
  }
}
