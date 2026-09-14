import Foundation
import Testing
import DoryDBTX86

@testable import DoryMachinePC

@Suite struct DoryPCDirectKernelMachineTests {
  @Test(arguments: [UInt64(2), 3, 5])
  func hostWorkersOverlapOnFrozenRegistersAndJoinAtGlobalBudget(budget: UInt64) throws {
    let machine = try workerMachine(clock: .hostMonotonic { 0 })
    let probe = HostWorkerProbe()
    machine.observeWorkers { probe.observe($0) }
    #expect(try machine.run(maximumInstructions: budget) == .instructionBudget(budget))
    let result = probe.snapshot()
    #expect(result.distinctThreads == 2)
    #expect(result.maximumActive == 2)
    #expect(!result.timedOut)
    #expect(result.active == 0)
    #expect(result.stopped == Set([0, 1]))
    #expect(result.executions == Int(budget))
    #expect(machine.state(forProcessor: 0)?.registers.rax == 1)
    #expect(machine.state(forProcessor: 1)?.registers.rax == 2)
    #expect(machine.executionStatistics.interpreterInstructions == budget)
  }

  @Test func deterministicWorkersKeepSerialOrderAndSingleBudget() throws {
    let machine = try workerMachine(clock: .deterministic)
    let probe = HostWorkerProbe()
    machine.observeWorkers { probe.observe($0) }
    #expect(try machine.run(maximumInstructions: 3) == .instructionBudget(3))
    #expect(probe.snapshot().order == [0, 1, 0])
    #expect(probe.snapshot().maximumActive == 1)
    #expect(probe.snapshot().distinctThreads == 2)
    #expect(probe.snapshot().stopped == Set([0, 1]))
    #expect(machine.state(forProcessor: 0)?.tsc == 300)
    #expect(machine.state(forProcessor: 1)?.tsc == 300)
    #expect(try machine.run(maximumInstructions: 1) == .instructionBudget(1))
    #expect(machine.executionStatistics.interpreterInstructions == 4)
  }

  @Test(arguments: [DoryPCPowerAction.powerOff, .reset])
  func powerStopsOverlappingWorkersAndFrozenFetchSurvivesRAMChange(action: DoryPCPowerAction) throws {
    let machine = try workerMachine(clock: .hostMonotonic { 0 })
    let probe = HostWorkerProbe(hold: true)
    machine.observeWorkers { probe.observe($0) }
    let run = HaltedMachineRun(machine: machine, maximumInstructions: 20)
    defer { probe.release(); machine.powerController.request(.powerOff) }
    try #require(probe.arrived.wait(timeout: .now() + 2) == .success)
    // Both vCPUs have fetched and parked inside their concurrent execution boundaries.
    // Their memory adapters are frozen, so these writes cannot change either admitted MOV.
    try machine.memory.write(at: 0x10_0000, bytes: [0x0F, 0x0B])
    try machine.memory.write(at: 0x8000, bytes: [0x0F, 0x0B])
    machine.powerController.request(action)
    probe.release()
    #expect(try run.finish() == (action == .reset
      ? .reset(instructionCount: 2) : .poweredOff(instructionCount: 2)))
    #expect(machine.state(forProcessor: 0)?.registers.rax == 1)
    #expect(machine.state(forProcessor: 1)?.registers.rax == 2)
    #expect(probe.snapshot().active == 0)
    #expect(probe.snapshot().stopped == Set([0, 1]))
    #expect(!probe.snapshot().timedOut)
  }

  @Test func targetedStartupDuringOverlapWaitsForItsOwningWorker() throws {
    let machine = try workerMachine(clock: .hostMonotonic { 0 })
    try machine.memory.write(at: 0x9000, bytes: [0xB8, 3, 0])
    let probe = HostWorkerProbe(hold: true)
    machine.observeWorkers { probe.observe($0) }
    let run = HaltedMachineRun(machine: machine, maximumInstructions: 4)
    defer { probe.release(); machine.powerController.request(.powerOff) }
    try #require(probe.arrived.wait(timeout: .now() + 2) == .success)
    try machine.multiprocessorController.handleInterruptCommand(
      sourceAPICID: 0, high: 1 << 24, low: 5 << 8)
    try machine.multiprocessorController.handleInterruptCommand(
      sourceAPICID: 0, high: 1 << 24, low: 6 << 8 | 9)
    #expect(machine.multiprocessorController.drainEvents(forAPICID: 0).isEmpty)
    #expect(machine.multiprocessorController.snapshot().pendingEvents == [
      .initialize(apicID: 1), .startup(apicID: 1, vector: 9),
    ])
    probe.release()
    #expect(try run.finish() == .instructionBudget(4))
    #expect(machine.state(forProcessor: 0)?.registers.rax == 1)
    #expect(machine.state(forProcessor: 1)?.registers.rax == 3)
    #expect(machine.state(forProcessor: 1)?.cs.base == 0x9000)
    #expect(machine.multiprocessorController.snapshot().pendingEvents.isEmpty)
    #expect(probe.snapshot().stopped == Set([0, 1]))
  }

  @Test func parallelWorkersAdvanceOneHostEpochAtRendezvous() throws {
    let clock = WorkerSampleClock()
    let machine = try workerMachine(clock: .hostMonotonic { clock.sample() })
    try machine.physicalMemory.writeScalar(at: 0xFED0_0010, value: 1, byteCount: 8)
    #expect(try machine.run(maximumInstructions: 2) == .instructionBudget(2))
    #expect(clock.samples == 2)
    #expect(machine.hpet.snapshot().mainCounter == 1)
    #expect(machine.state(forProcessor: 0)?.tsc == 100)
    #expect(machine.state(forProcessor: 1)?.tsc == 100)
  }

  @Test func sensitiveInstructionAndExceptionStaySerializedAndJoin() throws {
    let machine = try workerMachine(clock: .hostMonotonic { 0 })
    // UD2 must stop before AP execution; speculative admission cannot retire later work.
    try machine.memory.write(at: 0x10_0000, bytes: [0x0F, 0x0B])
    let probe = HostWorkerProbe()
    machine.observeWorkers { probe.observe($0) }
    let stop = try machine.run(maximumInstructions: 4)
    guard case .exception(_, let count) = stop else {
      Issue.record("Expected invalid opcode, got \(stop)")
      return
    }
    #expect(count == 0)
    #expect(probe.snapshot().order == [0])
    #expect(probe.snapshot().stopped == Set([0, 1]))
    #expect(machine.state(forProcessor: 1)?.rip == 0)
  }

  @Test(arguments: [false, true], [false, true])
  func parallelAdmissionDeclinesInvalidProtectedFetch(is32Bit: Bool, isMove: Bool) throws {
    let machine = try workerMachine(clock: .hostMonotonic { 0 })
    let mode: DoryX86ExecutionMode = is32Bit ? .protected32 : .protected16
    let code: [UInt8] = isMove ? (is32Bit ? [0xB8, 1, 2, 3, 4] : [0xB8, 1, 2]) : [0x90]
    var initial = try #require(machine.state)
    initial.rip = 0x10100 // Protected16 also uses the interpreter's 32-bit fetch offset mask.
    initial.registers.rax = 0x1234
    initial.cs.base = 0x17_0000
    initial.cs.attributes = is32Bit ? 0xC09B : 0x009B
    initial.cs.limit = UInt32(initial.rip) + UInt32(code.count) - 1
    try machine.memory.write(at: initial.cs.base + initial.rip, bytes: code)
    #expect(initial.control.cr0 & (1 << 31) == 0)
    #expect(initial.control.cr0 & 1 != 0)

    // The exact same candidate is valid when its final byte lies on CS.limit.
    let admitted = try #require(machine.frozenParallelInstruction(state: initial, processor: 0))
    #expect(admitted.bytes == code)
    var valid = initial
    guard case .retired = DoryX86Interpreter().step(state: &valid, memory: admitted, mode: mode)
    else {
      Issue.record("Expected valid boundary instruction to retire")
      return
    }
    #expect(valid.rip == initial.rip + UInt64(code.count))

    for invalidity in ["notPresent", "systemSegment", "notExecutable", "offsetBeyondLimit", "spanBeyondLimit"] {
      var invalid = initial
      switch invalidity {
      case "notPresent": invalid.cs.attributes &= ~UInt16(0x80)
      case "systemSegment": invalid.cs.attributes &= ~UInt16(0x10)
      case "notExecutable": invalid.cs.attributes &= ~UInt16(8)
      case "offsetBeyondLimit": invalid.cs.limit = UInt32(invalid.rip) - 1
      default: invalid.cs.limit -= 1
      }
      #expect(machine.frozenParallelInstruction(state: invalid, processor: 0) == nil)
      // A declined candidate stays with the serial interpreter's architectural fault path.
      let original = invalid
      let result = DoryX86Interpreter().step(
        state: &invalid, memory: machine.physicalMemory, mode: mode)
      guard case .exception(let exception) = result else {
        Issue.record("Expected fetch fault for \(invalidity), got \(result)")
        continue
      }
      #expect(exception.kind == .generalProtection)
      #expect(exception.vector == 13)
      #expect(exception.errorCode == 0)
      #expect(exception.instructionPointer == original.rip)
      #expect(invalid.rip == original.rip)
      #expect(invalid.registers == original.registers)
    }
  }

  @Test(arguments: [false, true])
  func protectedFetchLimitFaultStaysSerialAndJoins(isMove: Bool) throws {
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024, processorCount: 2,
      clockSource: .hostMonotonic { 0 })
    // Load a byte-granular code descriptor, then jump to its base at 0x180000.
    try machine.load(kernel: makeELF(code: [
      0x0F, 0x01, 0x15, 0x00, 0x00, 0x08, 0x00, // lgdt [0x80000]
      0xEA, 0, 0, 0, 0, 8, 0, // jmp 8:0
    ]), commandLine: "x")
    try machine.memory.write(at: 0x80000, bytes: [0x0F, 0, 0, 0x20, 8, 0])
    try machine.memory.write(at: 0x82000, bytes: [
      0, 0, 0, 0, 0, 0, 0, 0,
      isMove ? 1 : 0, 0, 0, 0, 0x18, 0x9B, 0x40, 0,
    ])
    try machine.memory.write(at: 0x180000,
      bytes: isMove ? [0xB8, 1, 2, 3, 4] : [0x90, 0x90])
    // For NOP, retire the byte at the limit so the next fetch starts beyond it.
    let setupBudget: UInt64 = isMove ? 2 : 3
    #expect(try machine.run(maximumInstructions: setupBudget) == .instructionBudget(setupBudget))
    let before = try #require(machine.state)
    #expect(before.cs.base == 0x180000)
    #expect(before.cs.limit == (isMove ? 1 : 0))
    #expect(before.rip == (isMove ? 0 : 1))
    try machine.memory.write(at: 0x8000, bytes: [0x90, 0xB8, 2, 0])
    try machine.multiprocessorController.handleInterruptCommand(
      sourceAPICID: 0, high: 1 << 24, low: 6 << 8 | 8)
    // Consume the AP's next round-robin slot, leaving BSP first and AP's MOV still pending.
    #expect(try machine.run(maximumInstructions: 1) == .instructionBudget(1))
    #expect(machine.state(forProcessor: 1)?.rip == 1)
    let probe = HostWorkerProbe()
    machine.observeWorkers { probe.observe($0) }
    let stop = try machine.run(maximumInstructions: 2)
    guard case .exception(let exception, let count) = stop else {
      Issue.record("Expected serial fetch fault, got \(stop)")
      return
    }
    #expect(exception.kind == .generalProtection)
    #expect(exception.errorCode == 0)
    #expect(exception.instructionPointer == before.rip)
    #expect(count == 0)
    #expect(machine.state?.rip == before.rip)
    #expect(machine.state?.registers == before.registers)
    #expect(machine.state(forProcessor: 1)?.rip == 1)
    #expect(probe.snapshot().order == [0])
    #expect(probe.snapshot().maximumActive == 1)
    #expect(probe.snapshot().active == 0)
    #expect(probe.snapshot().stopped == Set([0, 1]))
    #expect(!probe.snapshot().timedOut)
  }

  @Test(arguments: [DoryPCExecutionTier.baselineJIT, .optimizingJIT])
  func nativeTiersKeepRealModeApplicationProcessorSerial(tier: DoryPCExecutionTier) throws {
    #if arch(arm64)
      let machine = try workerMachine(clock: .hostMonotonic { 0 }, tier: tier)
      let probe = HostWorkerProbe()
      machine.observeWorkers { probe.observe($0) }
      #expect(try machine.run(maximumInstructions: 2) == .instructionBudget(2))
      #expect(probe.snapshot().maximumActive == 1)
      #expect(probe.snapshot().stopped == Set([0, 1]))
    #endif
  }

  @Test(arguments: [DoryPCExecutionTier.baselineJIT, .optimizingJIT], [UInt64(2), 3, 5])
  func nativeWorkersOverlapFrozenRegistersAndJoin(tier: DoryPCExecutionTier, budget: UInt64) throws {
    #if arch(arm64)
      let machine = try nativeWorkerMachine(tier: tier)
      let before = machine.executionStatistics
      let probe = HostWorkerProbe()
      machine.observeWorkers { probe.observe($0) }
      #expect(try machine.run(maximumInstructions: budget) == .instructionBudget(budget))
      let result = probe.snapshot()
      #expect(result.distinctThreads == 2)
      #expect(result.maximumActive == 2)
      #expect(!result.timedOut)
      #expect(result.active == 0)
      #expect(result.stopped == Set([0, 1]))
      #expect(result.nativeRetirements[0]?.first == 1)
      #expect(result.nativeRetirements[1]?.first == 1)
      #expect(machine.state(forProcessor: 0)?.registers.rax == 1)
      #expect(machine.state(forProcessor: 1)?.registers.rax == 2)
      let after = machine.executionStatistics
      #expect(after.interpreterInstructions == before.interpreterInstructions)
      #expect(after.baselineJITInstructions + after.optimizingJITInstructions
        - before.baselineJITInstructions - before.optimizingJITInstructions == budget)
      if tier == .optimizingJIT {
        #expect(after.optimizingJITInstructions - before.optimizingJITInstructions == budget)
      }
    #endif
  }

  @Test(arguments: [DoryPCExecutionTier.baselineJIT, .optimizingJIT])
  func nativeWorkersShareHostEpochAtRendezvous(tier: DoryPCExecutionTier) throws {
    #if arch(arm64)
      let clock = WorkerSampleClock()
      let machine = try nativeWorkerMachine(tier: tier, clock: .hostMonotonic { clock.sample() })
      try machine.physicalMemory.writeScalar(at: 0xFED0_0010, value: 1, byteCount: 8)
      let samples = clock.samples
      let counter = machine.hpet.snapshot().mainCounter
      let tsc = try #require(machine.state?.tsc)
      #expect(try machine.run(maximumInstructions: 2) == .instructionBudget(2))
      #expect(clock.samples - samples == 2)
      #expect(machine.hpet.snapshot().mainCounter - counter == 2)
      #expect(machine.state(forProcessor: 0)?.tsc == tsc + 200)
      #expect(machine.state(forProcessor: 1)?.tsc == tsc + 200)
    #endif
  }

  @Test(arguments: [DoryPCExecutionTier.baselineJIT, .optimizingJIT], ["pending", "timer", "ipi", "startup"])
  func nativeOverlapExitsForTargetedWorkAndResumes(tier: DoryPCExecutionTier, source: String) throws {
    #if arch(arm64)
      let machine = try nativeWorkerMachine(tier: tier)
      let entries = (machine.baselineJITDiagnostics?.nativeDispatcherEntries ?? 0)
        + (machine.optimizingJITDiagnostics?.nativeDispatcherEntries ?? 0)
      try machine.memory.write(at: 0xA000, bytes: [0xB8, 3, 0])
      let probe = HostWorkerProbe(hold: true)
      machine.observeWorkers { probe.observe($0) }
      try machine.localAPICs[1].configureSpuriousVector(0xFF, softwareEnabled: true)
      let run = HaltedMachineRun(machine: machine, maximumInstructions: 2)
      defer { probe.release(); machine.powerController.request(.powerOff) }
      try #require(probe.arrived.wait(timeout: .now() + 2) == .success)
      // Both owning executors have passed their Swift pending check and are fetching frozen
      // bytes. Publish to AP's atomic pending byte before its generated entry poll executes.
      switch source {
      case "pending": try machine.localAPICs[1].inject(vector: 0x30)
      case "timer":
        try machine.localAPICs[1].configureTimer(
          vector: 0x30, masked: false, mode: .oneShot, initialCount: 1)
        machine.localAPICs[1].advanceTimer(by: 1)
      case "startup":
        try machine.multiprocessorController.handleInterruptCommand(
          sourceAPICID: 0, high: 1 << 24, low: 5 << 8)
        try machine.multiprocessorController.handleInterruptCommand(
          sourceAPICID: 0, high: 1 << 24, low: 6 << 8 | 0xA)
      default:
        try machine.multiprocessorController.handleInterruptCommand(
          sourceAPICID: 0, high: 1 << 24, low: 0x30)
      }
      probe.release()
      #expect(try run.finish() == .instructionBudget(2))
      let result = probe.snapshot()
      #expect(result.maximumActive == 2)
      #expect(result.nativeRetirements[0]?.first == 1)
      #expect(result.nativeRetirements[1]?.first == 0)
      #expect(result.active == 0)
      #expect(result.stopped == Set([0, 1]))
      #expect(!result.timedOut)
      // IF is clear: the request remains pending, and BSP consumes the remaining budget.
      if source == "startup" {
        #expect(machine.state(forProcessor: 1)?.cs.base == 0xA000)
        #expect(machine.state(forProcessor: 1)?.rip == 0)
      } else {
        #expect(machine.state(forProcessor: 1)?.rip == 0x9000)
        #expect(machine.localAPICs[1].snapshot().interruptRequest.contains(0x30))
      }
      let finalEntries = (machine.baselineJITDiagnostics?.nativeDispatcherEntries ?? 0)
        + (machine.optimizingJITDiagnostics?.nativeDispatcherEntries ?? 0)
      // Two native entries for the overlapping pair, then one serial BSP instruction.
      #expect(finalEntries - entries == 3)
      #expect(machine.multiprocessorController.snapshot().pendingEvents.isEmpty)
      if source == "timer" { #expect(machine.timerInterruptDiagnostics.localAPICRequests[1] == 1) }
      // A new run must reacquire ownership and retire the interrupted AP instruction.
      #expect(try machine.run(maximumInstructions: 1) == .instructionBudget(1))
      #expect(machine.state(forProcessor: 1)?.registers.rax == (source == "startup" ? 3 : 2))
    #endif
  }

  @Test(arguments: [DoryPCExecutionTier.baselineJIT, .optimizingJIT])
  func nativeOverlapUsesFrozenBytesDuringRAMMutation(tier: DoryPCExecutionTier) throws {
    #if arch(arm64)
      let machine = try nativeWorkerMachine(tier: tier)
      let probe = HostWorkerProbe(hold: true)
      machine.observeWorkers { probe.observe($0) }
      let run = HaltedMachineRun(machine: machine, maximumInstructions: 2)
      defer { probe.release(); machine.powerController.request(.powerOff) }
      try #require(probe.arrived.wait(timeout: .now() + 2) == .success)
      try machine.memory.write(at: 0x10_0000, bytes: [0x0F, 0x0B])
      try machine.memory.write(at: 0x9000, bytes: [0x0F, 0x0B])
      probe.release()
      #expect(try run.finish() == .instructionBudget(2))
      #expect(machine.state(forProcessor: 0)?.registers.rax == 1)
      #expect(machine.state(forProcessor: 1)?.registers.rax == 2)
      #expect(probe.snapshot().nativeRetirements[0] == [1])
      #expect(probe.snapshot().nativeRetirements[1] == [1])
      #expect(probe.snapshot().stopped == Set([0, 1]))
      #expect(!probe.snapshot().timedOut)
    #endif
  }

  @Test(arguments: [DoryPCExecutionTier.baselineJIT, .optimizingJIT],
    [DoryPCPowerAction.powerOff, .reset])
  func nativeOverlapPowerExitJoinsWithoutRetiringFrozenWork(
    tier: DoryPCExecutionTier, action: DoryPCPowerAction
  ) throws {
    #if arch(arm64)
      for _ in 0..<3 {
        let machine = try nativeWorkerMachine(tier: tier)
        let before = machine.executionStatistics
        let probe = HostWorkerProbe(hold: true)
        machine.observeWorkers { probe.observe($0) }
        let run = HaltedMachineRun(machine: machine, maximumInstructions: 20)
        defer { probe.release(); machine.powerController.request(.powerOff) }
        try #require(probe.arrived.wait(timeout: .now() + 2) == .success)
        machine.powerController.request(action)
        probe.release()
        #expect(try run.finish() == (action == .reset
          ? .reset(instructionCount: 0) : .poweredOff(instructionCount: 0)))
        let result = probe.snapshot()
        #expect(result.nativeRetirements[0] == [0])
        #expect(result.nativeRetirements[1] == [0])
        #expect(result.maximumActive == 2)
        #expect(result.active == 0)
        #expect(result.stopped == Set([0, 1]))
        #expect(!result.timedOut)
        #expect(machine.state(forProcessor: 0)?.rip == 0x10_0000)
        #expect(machine.state(forProcessor: 1)?.rip == 0x9000)
        #expect(machine.executionStatistics == before)
      }
    #endif
  }

  @Test(arguments: [DoryPCExecutionTier.baselineJIT, .optimizingJIT],
    ["memory", "branch", "exception", "deterministic"])
  func nativeDangerousShapesStaySerial(tier: DoryPCExecutionTier, shape: String) throws {
    #if arch(arm64)
      let machine = try nativeWorkerMachine(tier: tier,
        clock: shape == "deterministic" ? .deterministic : .hostMonotonic { 0 })
      switch shape {
      case "memory": try machine.memory.write(at: 0x10_0000, bytes: [0xA1, 1, 0x90, 0, 0])
      case "branch": try machine.memory.write(at: 0x10_0000, bytes: [0xEB, 0xFE])
      case "exception": try machine.memory.write(at: 0x10_0000, bytes: [0x0F, 0x0B])
      default: break
      }
      let probe = HostWorkerProbe()
      machine.observeWorkers { probe.observe($0) }
      let stop = try machine.run(maximumInstructions: 2)
      if shape == "exception" {
        guard case .exception(_, let count) = stop else {
          Issue.record("Expected serial invalid opcode, got \(stop)")
          return
        }
        #expect(count == 0)
        #expect(machine.state(forProcessor: 1)?.rip == 0x9000)
      } else { #expect(stop == .instructionBudget(2)) }
      #expect(probe.snapshot().maximumActive == 1)
      #expect(probe.snapshot().nativeRetirements.isEmpty)
      #expect(probe.snapshot().active == 0)
      #expect(probe.snapshot().stopped == Set([0, 1]))
    #endif
  }

  private func nativeWorkerMachine(
    tier: DoryPCExecutionTier, clock: DoryPCClockSource = .hostMonotonic { 0 }
  ) throws -> DoryPCDirectKernelMachine {
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024, processorCount: 2, executionTier: tier,
      baselineJITMaximumCodeBytes: 16 * 1024, optimizingJITWarmupDispatches: 0,
      clockSource: clock, instrumentationEnabled: true)
    try machine.load(kernel: makeELF(code: [0xEB, 0xFE]), commandLine: "x")
    try machine.memory.write(at: 0x6006, bytes: [0x0F, 0, 0, 0x62, 0, 0])
    try machine.memory.write(at: 0x6200, bytes: [
      0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 0, 0, 0, 0x9B, 0xCF, 0,
    ])
    try machine.memory.write(at: 0x8000, bytes: [
      0x66, 0x0F, 0x01, 0x16, 6, 0x60, // lgdt [0x6006]
      0x66, 0x0F, 0x20, 0xC0, // mov eax,cr0
      0x66, 0x83, 0xC8, 1, // or eax,1
      0x66, 0x0F, 0x22, 0xC0, // mov cr0,eax
      0x66, 0xEA, 0, 0x90, 0, 0, 8, 0, // jmp 8:0x9000 (flat protected32)
    ])
    try machine.multiprocessorController.handleInterruptCommand(
      sourceAPICID: 0, high: 1 << 24, low: 6 << 8 | 8)
    for step in 0..<10 {
      let stop = try machine.run(maximumInstructions: 1)
      try #require(stop == .instructionBudget(1), "AP setup step \(step)")
    }
    try #require(machine.state(forProcessor: 1)?.rip == 0x9000)
    try #require(machine.state(forProcessor: 1)?.cs.base == 0)
    try #require(machine.state(forProcessor: 1)?.cs.limit == .max)
    try machine.memory.write(at: 0x10_0000, bytes: [0xB8, 1, 0, 0, 0, 0x90, 0x90, 0x90])
    try machine.memory.write(at: 0x9000, bytes: [0xB8, 2, 0, 0, 0, 0x90, 0x90, 0x90])
    return machine
  }

  @Test func memoryOperandRetiresSeriallyBeforeTheNextProcessor() throws {
    let machine = try workerMachine(clock: .hostMonotonic { 0 })
    // mov eax,[0x8001] is deliberately outside the register-only admission boundary.
    try machine.memory.write(at: 0x10_0000, bytes: [0xA1, 1, 0x80, 0, 0])
    let probe = HostWorkerProbe()
    machine.observeWorkers { probe.observe($0) }
    #expect(try machine.run(maximumInstructions: 2) == .instructionBudget(2))
    #expect(probe.snapshot().order == [0, 1])
    #expect(probe.snapshot().maximumActive == 1)
    #expect(machine.state(forProcessor: 0)?.registers.rax == 0x9090_0002)
    #expect(machine.state(forProcessor: 1)?.registers.rax == 2)
  }

  @Test func physicalDiagnosticsPublishDuringConcurrentReads() throws {
    let machine = try workerMachine(clock: .deterministic)
    let bus = machine.physicalMemory
    bus.publishDiagnostics()
    let initial = bus.diagnostics.readHelperCalls
    DispatchQueue.concurrentPerform(iterations: 4) { _ in
      for _ in 0..<100 {
        _ = try? bus.read(at: 0x8000, byteCount: 1)
        bus.publishDiagnostics()
        _ = bus.diagnostics
      }
    }
    bus.publishDiagnostics()
    #expect(bus.diagnostics.readHelperCalls == initial + 400)
  }

  @Test func workerFailureStillCompletesAndJoins() throws {
    enum Failure: Error { case expected }
    let probe = HostWorkerProbe()
    let worker = DoryPCHostWorker(processor: 0) { probe.observe(.stopped(0)) }
    defer { worker.stopAndJoin() }
    do {
      try worker.perform { () throws -> Void in throw Failure.expected }
      Issue.record("Expected worker failure")
    } catch Failure.expected {}
    worker.stopAndJoin()
    #expect(probe.snapshot().stopped == Set([0]))
    // Joining is idempotent, including the already-exited path.
    worker.stopAndJoin()
  }

  private func workerMachine(
    clock: DoryPCClockSource, tier: DoryPCExecutionTier = .interpreter
  ) throws -> DoryPCDirectKernelMachine {
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024, processorCount: 2,
      executionTier: tier, baselineJITMaximumCodeBytes: 16 * 1024,
      clockSource: clock, instrumentationEnabled: true)
    try machine.load(kernel: makeELF(code: [0xB8, 1, 0, 0, 0, 0x90, 0x90, 0x90]), commandLine: "x")
    try machine.memory.write(at: 0x8000, bytes: [0xB8, 2, 0, 0x90, 0x90, 0x90])
    try machine.multiprocessorController.handleInterruptCommand(
      sourceAPICID: 0, high: 1 << 24, low: 6 << 8 | 8)
    return machine
  }

  @Test(arguments: ["hostPowerOff", "hostReset", "pmPowerOff", "resetPort"])
  func hostClockHaltWakesForAsynchronousPowerWithoutTimer(source: String) throws {
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024, clockSource: .hostMonotonic)
    try machine.load(kernel: makeELF(code: [0xF4]), commandLine: "x")
    let run = HaltedMachineRun(machine: machine, maximumInstructions: 8)
    defer { machine.powerController.request(.powerOff) }
    try #require(machine.waitUntilIdle(until: Date(timeIntervalSinceNow: 2)))
    switch source {
    case "hostPowerOff": machine.powerController.request(.powerOff)
    case "hostReset": machine.powerController.request(.reset)
    case "pmPowerOff":
      try machine.ioBus.write(port: DoryPCPowerController.pm1ControlPort,
        value: UInt32(DoryPCPowerController.softOffSleepType << 10 | 1 << 13), width: .word)
    default:
      try machine.ioBus.write(port: DoryPCPowerController.resetPort,
        value: UInt32(DoryPCPowerController.resetValue), width: .byte)
    }
    let expected: DoryPCMachineStop = source == "hostReset" || source == "resetPort"
      ? .reset(instructionCount: 1) : .poweredOff(instructionCount: 1)
    #expect(try run.finish() == expected)
  }

  @Test(arguments: ["apic", "pic", "nmi"])
  func hostClockHaltDeliversAsynchronousInterruptWithoutTimer(source: String) throws {
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024, clockSource: .hostMonotonic)
    var code = [UInt8](repeating: 0x90, count: 0x109)
    // lidt [0x80000]; lgdt [0x80006]; sti; hlt
    code.replaceSubrange(0..<16, with: [
      0x0F, 0x01, 0x1D, 0, 0, 8, 0, 0x0F, 0x01, 0x15, 6, 0, 8, 0, 0xFB, 0xF4,
    ])
    code.replaceSubrange(0x100..<0x109,
      with: [0xB0, UInt8(ascii: "W"), 0xBA, 0xF8, 0x03, 0, 0, 0xEE, 0xF4])
    try machine.load(kernel: makeELF(code: code), commandLine: "x")
    try installProtectedTables(machine: machine, vector: source == "nmi" ? 2 : 0x30)
    try machine.localAPIC.configureSpuriousVector(0xFF, softwareEnabled: true)
    if source == "pic" {
      try machine.ioBus.write(port: 0x20, value: 0x11, width: .byte)
      try machine.ioBus.write(port: 0x21, value: 0x30, width: .byte)
      try machine.ioBus.write(port: 0x21, value: 0x04, width: .byte)
      try machine.ioBus.write(port: 0x21, value: 0x01, width: .byte)
      try machine.ioBus.write(port: 0x21, value: 0xFE, width: .byte)
    }
    let run = HaltedMachineRun(machine: machine, maximumInstructions: 8)
    defer { machine.powerController.request(.powerOff) }
    try #require(machine.waitUntilIdle(until: Date(timeIntervalSinceNow: 2)))
    switch source {
    case "apic": try machine.localAPIC.inject(vector: 0x30)
    case "pic": try machine.legacyPIC.raise(irq: 0)
    default:
      try machine.multiprocessorController.handleInterruptCommand(
        sourceAPICID: 0, high: 0, low: 4 << 8)
    }
    #expect(try run.finish() == .instructionBudget(8))
    #expect(machine.serial.drainTransmittedBytes() == [UInt8(ascii: "W")])
    #expect(machine.executionStatistics.deliveredMaskableInterrupts == (source == "nmi" ? 0 : 1))
    #expect(machine.executionStatistics.deliveredNonMaskableInterrupts == (source == "nmi" ? 1 : 0))
  }

  @Test(arguments: [false, true])
  func hostClockHaltProcessesStartupBeforeOrDuringWait(signalBeforeWait: Bool) throws {
    let clock = HaltedMachineClockGate()
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024, processorCount: 2,
      clockSource: signalBeforeWait ? .hostMonotonic { clock.sample() } : .hostMonotonic)
    try machine.load(kernel: makeELF(code: [0xF4]), commandLine: "x")
    try machine.memory.write(at: 0x8000,
      bytes: [0xB0, UInt8(ascii: "A"), 0xBA, 0xF8, 0x03, 0xEE, 0xF4])
    let run = HaltedMachineRun(machine: machine, maximumInstructions: 5)
    defer {
      clock.proceed.signal()
      machine.powerController.request(.powerOff)
    }
    if signalBeforeWait {
      // The third host sample is in the all-halted pass, after mailbox draining but before
      // waiting. The publisher completes its notification before allowing that pass to proceed.
      try #require(clock.reached.wait(timeout: .now() + 2) == .success)
    } else {
      try #require(machine.waitUntilIdle(until: Date(timeIntervalSinceNow: 2)))
    }
    try machine.multiprocessorController.handleInterruptCommand(
      sourceAPICID: 0, high: 1 << 24, low: 5 << 8)
    try machine.multiprocessorController.handleInterruptCommand(
      sourceAPICID: 0, high: 1 << 24, low: 6 << 8 | 8)
    clock.proceed.signal()
    #expect(try run.finish() == .instructionBudget(5))
    #expect(machine.serial.drainTransmittedBytes() == [UInt8(ascii: "A")])
    #expect(machine.state(forProcessor: 1)?.cs.base == 0x8000)
  }

  @Test func deterministicHaltWithMaskedPendingPICDoesNotSpinOrInventTicks() throws {
    let machine = try DoryPCDirectKernelMachine(memoryBytes: 2 * 1024 * 1024)
    try machine.load(kernel: makeELF(code: [0xFB, 0xF4]), commandLine: "x")
    try machine.legacyPIC.raise(irq: 0) // reset mask keeps this pending but undeliverable
    #expect(try machine.runOnDedicatedStack(maximumInstructions: 8) == .halted(instructionCount: 2))
    #expect(machine.state?.tsc == 200)
    #expect(machine.legacyPIC.snapshot().masterRequest == 1)
  }

  @Test func guestPortOutputProducesBootTimelineBeforeConsoleDrain() throws {
    let machine = try DoryPCDirectKernelMachine(memoryBytes: 2 * 1024 * 1024)
    let timeline = DoryPCBootTimeline()
    machine.serial.observeBoot(with: timeline)
    var code: [UInt8] = [0xBA, 0xF8, 0x03, 0, 0] // mov edx, 0x3f8
    for byte in "Linux version ".utf8 { code += [0xB0, byte, 0xEE] } // mov al; out dx, al
    code.append(0xF4)
    try machine.load(kernel: makeELF(code: code), commandLine: "x")
    _ = try machine.runOnDedicatedStack(maximumInstructions: 100)
    #expect(timeline.snapshot().events.last?.milestone == .kernel)
    #expect(String(decoding: machine.serial.drainTransmittedBytes(), as: UTF8.self) == "Linux version ")
  }

  @Test func diagnosticInstructionBytesFollowTheLoadedProcessor() throws {
    let machine = try DoryPCDirectKernelMachine(memoryBytes: 2 * 1024 * 1024)
    try machine.load(kernel: makeELF(code: [0x90, 0xF4]), commandLine: "x")

    #expect(try machine.instructionBytes(maximumCount: 2) == [0x90, 0xF4])
    let entry = try #require(machine.state?.rip)
    #expect(try machine.memoryBytes(atLinearAddress: entry, maximumCount: 2) == [0x90, 0xF4])
    #expect(try machine.memoryBytes(atLinearAddress: entry, maximumCount: 0) == [])
    #expect(try machine.memoryBytes(forProcessor: 1, atLinearAddress: entry, maximumCount: 1) == nil)
    #expect(try machine.runOnDedicatedStack(maximumInstructions: 1) == .instructionBudget(1))
    #expect(try machine.instructionBytes(maximumCount: 1) == [0xF4])
    #expect(try machine.instructionBytes(maximumCount: 0) == [])
    #expect(try machine.instructionBytes(forProcessor: 1) == nil)
  }

  @Test func entersPVHCodeWritesSerialAndHalts() throws {
    let layout = DoryPCPVHBootLayout(
      startInfo: 0x90000,
      commandLine: 0x91000,
      modules: 0x92000,
      memoryMap: 0x93000,
      initrd: 0x180000
    )
    let machine = try DoryPCDirectKernelMachine(memoryBytes: 2 * 1024 * 1024, bootLayout: layout)
    let code: [UInt8] = [
      0xB0, UInt8(ascii: "D"),
      0xBA, 0xF8, 0x03, 0x00, 0x00,
      0xEE,
      0xF4,
    ]

    try machine.load(kernel: makeELF(code: code), commandLine: "console=ttyS0")
    let stop = try machine.runOnDedicatedStack(maximumInstructions: 16)

    #expect(stop == .halted(instructionCount: 4))
    #expect(machine.serial.drainTransmittedBytes() == [UInt8(ascii: "D")])
    #expect(machine.state?.registers.rbx == layout.startInfo)
  }

  @Test func startupIPIExecutesApplicationProcessorFromItsRealModeVector() throws {
    let layout = DoryPCPVHBootLayout(
      startInfo: 0x90000,
      commandLine: 0x91000,
      modules: 0x92000,
      memoryMap: 0x93000,
      initrd: 0x180000
    )
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      processorCount: 2,
      bootLayout: layout
    )
    try machine.load(kernel: makeELF(code: [0xF4]), commandLine: "x")

    // AP startup vector 8 targets physical address 0x8000 in real mode:
    // mov al,'A'; mov dx,0x3f8; out dx,al; hlt
    try machine.memory.write(
      at: 0x8000,
      bytes: [0xB0, UInt8(ascii: "A"), 0xBA, 0xF8, 0x03, 0xEE, 0xF4]
    )
    try machine.physicalMemory.write(at: 0xFEE0_0310, bytes: [0, 0, 0, 1])
    try machine.physicalMemory.write(at: 0xFEE0_0300, bytes: [8, 6, 0, 0])

    #expect(try machine.runOnDedicatedStack(maximumInstructions: 16) == .halted(instructionCount: 5))
    #expect(machine.serial.drainTransmittedBytes() == [UInt8(ascii: "A")])
    #expect(machine.state(forProcessor: 1)?.cs.base == 0x8000)
    let snapshots = machine.processorExecutionSnapshots
    #expect(snapshots.count == 2)
    #expect(snapshots[0].lifecycle == .running)
    #expect(snapshots[0].isHalted)
    #expect(snapshots[1].lifecycle == .running)
    #expect(snapshots[1].isHalted)
    #expect(snapshots[1].state?.cs.base == 0x8000)
    #expect(try machine.physicalMemories[0].read(at: 0xFEE0_0020, byteCount: 4) == [0, 0, 0, 0])
    #expect(try machine.physicalMemories[1].read(at: 0xFEE0_0020, byteCount: 4) == [0, 0, 0, 1])
  }

  @Test func stopsOnBudgetAndReportsPreciseExceptions() throws {
    let layout = DoryPCPVHBootLayout(
      startInfo: 0x90000,
      commandLine: 0x91000,
      modules: 0x92000,
      memoryMap: 0x93000,
      initrd: 0x180000
    )
    let budgeted = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      bootLayout: layout
    )
    try budgeted.load(kernel: makeELF(code: [0x90, 0xEB, 0xFD]), commandLine: "x")
    #expect(try budgeted.runOnDedicatedStack(maximumInstructions: 5) == .instructionBudget(5))

    let faulting = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      bootLayout: layout
    )
    try faulting.load(kernel: makeELF(code: [0x0F, 0x0B]), commandLine: "x")
    guard case .exception(let exception, let count) = try faulting.runOnDedicatedStack(maximumInstructions: 1)
    else {
      Issue.record("expected invalid opcode")
      return
    }
    #expect(exception.kind == .invalidOpcode)
    #expect(count == 0)
  }

  @Test func tripleFaultPreservesTheOriginalProcessorStateAndOpcodeBytes() throws {
    let layout = DoryPCPVHBootLayout(
      startInfo: 0x90000,
      commandLine: 0x91000,
      modules: 0x92000,
      memoryMap: 0x93000,
      initrd: 0x180000
    )
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      processorCount: 2,
      bootLayout: layout
    )
    try machine.load(kernel: makeELF(code: [0xF4]), commandLine: "x")
    try machine.memory.write(
      at: 0x8000,
      bytes: [
        0x66, 0x0F, 0x20, 0xC0,  // mov eax,cr0
        0x66, 0x83, 0xC8, 0x01,  // or eax,1
        0x66, 0x0F, 0x22, 0xC0,  // mov cr0,eax
        0x0F, 0x0B, 0xF4,        // ud2; hlt
      ]
    )
    try machine.physicalMemory.write(at: 0xFEE0_0310, bytes: [0, 0, 0, 1])
    try machine.physicalMemory.write(at: 0xFEE0_0300, bytes: [8, 6, 0, 0])

    let stop = try machine.run(
      maximumInstructions: 16,
      exceptionPolicy: .deliver
    )
    guard case .tripleFault(let source, let count) = stop,
      case .exception(let evidence) = source
    else {
      Issue.record("expected exception delivery to triple fault, got \(stop)")
      return
    }

    #expect(count == 4)
    #expect(evidence.exception.kind == .invalidOpcode)
    #expect(evidence.processor == 1)
    #expect(evidence.executionMode == .protected16)
    #expect(evidence.state.cs.base == 0x8000)
    #expect(evidence.state.rip == 12)
    #expect(evidence.instructionBytes.starts(with: [0x0F, 0x0B, 0xF4]))
  }

  @Test func baselineJITExecutesDirectKernelBlocksWithPreciseAccounting() throws {
    #if arch(arm64)
      let layout = DoryPCPVHBootLayout(
        startInfo: 0x90000,
        commandLine: 0x91000,
        modules: 0x92000,
        memoryMap: 0x93000,
        initrd: 0x180000
      )
      let machine = try DoryPCDirectKernelMachine(
        memoryBytes: 2 * 1024 * 1024,
        bootLayout: layout,
        executionTier: .baselineJIT,
        baselineJITMaximumCodeBytes: 4096
      )
      // mov eax,1; add eax,2; hlt
      try machine.load(
        kernel: makeELF(code: [0xB8, 1, 0, 0, 0, 0x83, 0xC0, 2, 0xF4]),
        commandLine: "x"
      )

      #expect(try machine.runOnDedicatedStack(maximumInstructions: 8) == .halted(instructionCount: 3))
      #expect(machine.state?.registers.rax == 3)
      #expect(machine.executionStatistics.baselineJITInstructions == 3)
      #expect(machine.executionStatistics.baselineJITBlocks == 1)
      #expect(machine.executionStatistics.interpreterInstructions == 0)
    #endif
  }

  @Test func baselineMachineAdmitsTier1AndRetainsLegacyFallback() throws {
    #if arch(arm64)
      let machine = try DoryPCDirectKernelMachine(
        memoryBytes: 2 * 1024 * 1024,
        executionTier: .baselineJIT,
        baselineJITMaximumCodeBytes: 16 * 1024
      )
      // mov eax,1; add eax,2; jmp $
      try machine.load(
        kernel: makeELF(code: [0xB8, 1, 0, 0, 0, 0x83, 0xC0, 2, 0xEB, 0xFE]),
        commandLine: "x"
      )

      #expect(try machine.runOnDedicatedStack(maximumInstructions: 6) == .instructionBudget(6))
      #expect(machine.state?.registers.rax == 3)
      #expect(machine.executionStatistics.baselineJITInstructions == 6)
      let diagnostics = try #require(machine.baselineJITDiagnostics)
      #expect(diagnostics.tier1CompilationAttempts == 2)
      #expect(diagnostics.tier1CompilationDeclines == 0)
      #expect(diagnostics.tier1CompiledBlocks == 2)
      #expect(diagnostics.compiledBlocks == 2)

      // CPUID is still outside tier-1 and legacy native emission, so its exact site remains an
      // interpreter fallback rather than making production admission optimistic.
      try machine.memory.write(at: machine.state!.rip, bytes: [0x0F, 0xA2])
      let priorInterpreterInstructions = machine.executionStatistics.interpreterInstructions
      #expect(try machine.runOnDedicatedStack(maximumInstructions: 1) == .instructionBudget(1))
      #expect(
        machine.executionStatistics.interpreterInstructions
          == priorInterpreterInstructions + 1)
    #endif
  }

  @Test func baselineMachineCanDisableTier1ForMatchedMeasurement() throws {
    #if arch(arm64)
      let machine = try DoryPCDirectKernelMachine(
        memoryBytes: 2 * 1024 * 1024,
        executionTier: .baselineJIT,
        baselineJITMaximumCodeBytes: 16 * 1024,
        baselineJITTier1Enabled: false
      )
      // mov eax,1; add eax,2; jmp $
      try machine.load(
        kernel: makeELF(code: [0xB8, 1, 0, 0, 0, 0x83, 0xC0, 2, 0xEB, 0xFE]),
        commandLine: "x"
      )

      #expect(try machine.runOnDedicatedStack(maximumInstructions: 6) == .instructionBudget(6))
      #expect(machine.state?.registers.rax == 3)
      let diagnostics = try #require(machine.baselineJITDiagnostics)
      #expect(diagnostics.compiledBlocks == 2)
      #expect(diagnostics.tier1CompilationAttempts == 0)
      #expect(diagnostics.tier1CompilationDeclines == 0)
      #expect(diagnostics.tier1CompiledBlocks == 0)
    #endif
  }

  @Test func soleRunnableJITProcessorUsesTheAdaptive4096InstructionQuantum() throws {
    #if arch(arm64)
      for (budget, expectedCalls) in [(4_095, UInt64(1)), (4_096, 1), (4_097, 2)] {
        let machine = try DoryPCDirectKernelMachine(
          memoryBytes: 2 * 1024 * 1024,
          processorCount: 4,
          executionTier: .baselineJIT,
          baselineJITMaximumCodeBytes: 16 * 1024
        )
        try machine.load(kernel: makeELF(code: [0xEB, 0xFE]), commandLine: "x")

        #expect(
          try machine.runOnDedicatedStack(maximumInstructions: UInt64(budget))
            == .instructionBudget(UInt64(budget)))
        let diagnostics = try #require(machine.baselineJITDiagnostics)
        #expect(diagnostics.chainedExecutionCalls == expectedCalls)
        #expect(diagnostics.chainedRequestedInstructions == UInt64(budget))
        #expect(diagnostics.chainedRetiredInstructions == UInt64(budget))
      }
    #endif
  }

  @Test func baselineJITDiagnosticsProjectLiveNegativeCacheHotSites() throws {
    #if arch(arm64)
      let machine = try DoryPCDirectKernelMachine(
        memoryBytes: 2 * 1024 * 1024,
        executionTier: .baselineJIT,
        baselineJITMaximumCodeBytes: 16 * 1024
      )
      // CPUID declines native emission; the backward jump keeps revisiting the same exact site.
      // The terminal hot-site sample retains the exact final short-budget identity.
      try machine.load(kernel: makeELF(code: [0x0F, 0xA2, 0xEB, 0xFC]), commandLine: "x")

      #expect(try machine.runOnDedicatedStack(maximumInstructions: 130) == .instructionBudget(130))
      let diagnostics = try #require(machine.baselineJITDiagnostics)
      let hotSite = try #require(diagnostics.negativeCacheHotSites.first)
      #expect(hotSite.guestRIP == 0x10_0000)
      #expect(hotSite.executionMode == .protected32)
      #expect(hotSite.instructionBudget == 2)
      #expect(hotSite.addressSpaceID == 0)
      #expect(hotSite.privilegeLevel == 0)
      #expect(hotSite.pagingEnabled == false)
      #expect(hotSite.guestByteCount == 2)
      #expect(hotSite.instructionBytes == [0x0F, 0xA2])
      #expect(hotSite.declineReason == .interpreterHelper)
      #expect(hotSite.hitCount > 0)
    #endif
  }

  @Test func twoRunnableProcessorsRetainThe64InstructionFairnessQuantum() throws {
    #if arch(arm64)
      let machine = try DoryPCDirectKernelMachine(
        memoryBytes: 2 * 1024 * 1024,
        processorCount: 2,
        executionTier: .baselineJIT,
        baselineJITMaximumCodeBytes: 16 * 1024
      )
      try machine.load(kernel: makeELF(code: [0xEB, 0xFE]), commandLine: "x")
      try machine.memory.write(at: 0x8000, bytes: [0xEB, 0xFE])
      try machine.physicalMemory.write(at: 0xFEE0_0310, bytes: [0, 0, 0, 1])
      try machine.physicalMemory.write(at: 0xFEE0_0300, bytes: [8, 6, 0, 0])

      #expect(try machine.runOnDedicatedStack(maximumInstructions: 130) == .instructionBudget(130))
      let diagnostics = try #require(machine.baselineJITDiagnostics)
      #expect(diagnostics.chainedExecutionCalls == 2)
      #expect(diagnostics.chainedRequestedInstructions == 128)
      #expect(diagnostics.chainedRetiredInstructions == 128)
      #expect(diagnostics.translationCacheEntryCount == 2 * 1_024)
      #expect(diagnostics.translationCacheAllocatedBytes == 2 * 48 * 1_024)
      #expect(machine.executionStatistics.interpreterInstructions == 2)
      #expect(machine.processorExecutionSnapshots[1].lifecycle == .running)
    #endif
  }

  @Test func adaptiveJITQuantumStillStopsAtTheAcceptedAPICTimerDeadline() throws {
    #if arch(arm64)
      let machine = try DoryPCDirectKernelMachine(
        memoryBytes: 2 * 1024 * 1024,
        executionTier: .baselineJIT,
        baselineJITMaximumCodeBytes: 16 * 1024
      )
      // STI and its protected following instruction retire through the precise path. The hot loop
      // then receives only the two machine ticks remaining before the accepted local-APIC deadline.
      try machine.load(kernel: makeELF(code: [0xFB, 0xEB, 0xFE]), commandLine: "x")
      try machine.localAPIC.configureSpuriousVector(0xFF, softwareEnabled: true)
      try machine.localAPIC.configureTimer(
        vector: 0x30,
        masked: false,
        mode: .oneShot,
        initialCount: 250
      )

      #expect(try machine.runOnDedicatedStack(maximumInstructions: 4) == .instructionBudget(4))
      let diagnostics = try #require(machine.baselineJITDiagnostics)
      // The first four-instruction request declines STI to the interpreter. The shadow forces the
      // following jump through the interpreter, then the second request is capped to two ticks.
      #expect(diagnostics.chainedExecutionCalls == 2)
      #expect(diagnostics.chainedRequestedInstructions == 6)
      #expect(diagnostics.chainedRetiredInstructions == 2)
    #endif
  }

  @Test func optimizingJITWarmsAColdDirectKernelBlockWithBaselineCode() throws {
    #if arch(arm64)
      let layout = DoryPCPVHBootLayout(
        startInfo: 0x90000,
        commandLine: 0x91000,
        modules: 0x92000,
        memoryMap: 0x93000,
        initrd: 0x180000
      )
      let machine = try DoryPCDirectKernelMachine(
        memoryBytes: 2 * 1024 * 1024,
        bootLayout: layout,
        executionTier: .optimizingJIT,
        baselineJITMaximumCodeBytes: 4096
      )
      // mov eax,1; mov ebx,eax; add ebx,2; hlt
      try machine.load(
        kernel: makeELF(code: [0xB8, 1, 0, 0, 0, 0x89, 0xC3, 0x83, 0xC3, 2, 0xF4]),
        commandLine: "x"
      )

      #expect(try machine.runOnDedicatedStack(maximumInstructions: 8) == .halted(instructionCount: 4))
      #expect(machine.state?.registers.rax == 1)
      #expect(machine.state?.registers.rbx == 3)
      #expect(machine.executionStatistics.optimizingJITInstructions == 0)
      #expect(machine.executionStatistics.baselineJITInstructions == 4)
      #expect(machine.executionStatistics.baselineJITBlocks == 1)
      #expect(machine.executionStatistics.interpreterInstructions == 0)
    #endif
  }

  @Test func multiprocessorOptimizingJITUsesABoundedBaselineWarmupBatch() throws {
    #if arch(arm64)
      let machine = try DoryPCDirectKernelMachine(
        memoryBytes: 2 * 1024 * 1024,
        processorCount: 4,
        executionTier: .optimizingJIT,
        baselineJITMaximumCodeBytes: 4096
      )
      // mov eax,1; mov ebx,eax; add ebx,2; nop; hlt
      try machine.load(
        kernel: makeELF(code: [
          0xB8, 1, 0, 0, 0,
          0x89, 0xC3,
          0x83, 0xC3, 2,
          0x90,
          0xF4,
        ]),
        commandLine: "x"
      )

      #expect(try machine.runOnDedicatedStack(maximumInstructions: 16) == .halted(instructionCount: 5))
      #expect(machine.state?.registers.rbx == 3)
      #expect(machine.executionStatistics.baselineJITInstructions == 5)
      #expect(machine.executionStatistics.baselineJITBlocks == 1)
      #expect(machine.executionStatistics.interpreterInstructions == 0)
      #expect(machine.processorExecutionSnapshots.dropFirst().allSatisfy {
        $0.lifecycle == .waitingForStartup
      })
    #endif
  }

  @Test func optimizingJITPromotesRepeatedDispatchesAfterBoundedWarmup() throws {
    #if arch(arm64)
      let machine = try DoryPCDirectKernelMachine(
        memoryBytes: 2 * 1024 * 1024,
        executionTier: .optimizingJIT,
        baselineJITMaximumCodeBytes: 16 * 1024,
        optimizingJITWarmupDispatches: 3
      )
      // jmp $ keeps every bounded run at the same guest RIP, modelling a hot dispatch head.
      try machine.load(kernel: makeELF(code: [0xEB, 0xFE]), commandLine: "x")

      #expect(try machine.runOnDedicatedStack(maximumInstructions: 1) == .instructionBudget(1))
      #expect(try machine.runOnDedicatedStack(maximumInstructions: 1) == .instructionBudget(1))
      #expect(machine.executionStatistics.baselineJITInstructions == 2)
      #expect(machine.executionStatistics.optimizingJITInstructions == 0)

      #expect(try machine.runOnDedicatedStack(maximumInstructions: 1) == .instructionBudget(1))
      #expect(machine.executionStatistics.baselineJITInstructions == 2)
      #expect(machine.executionStatistics.optimizingJITInstructions == 1)
      #expect(machine.executionStatistics.interpreterInstructions == 0)
      let diagnostics = try #require(machine.optimizingJITDiagnostics)
      #expect(diagnostics.optimizingCompilationAttempts == 1)
      #expect(diagnostics.lookupVisibleOptimizedBlocks == 1)
      #expect(diagnostics.lookupVisibleChangedOptimizedBlocks == 0)
      #expect(diagnostics.publishedPropagatedConstants == 0)
      #expect(diagnostics.publishedEliminatedStatements == 0)
    #endif
  }

  @Test func guestTSCAdvancesIdenticallyAcrossExecutionTiers() throws {
    #if arch(arm64)
      let tiers: [DoryPCExecutionTier] = [.interpreter, .baselineJIT, .optimizingJIT]
    #else
      let tiers: [DoryPCExecutionTier] = [.interpreter]
    #endif

    for tier in tiers {
      let machine = try DoryPCDirectKernelMachine(
        memoryBytes: 2 * 1024 * 1024,
        executionTier: tier,
        baselineJITMaximumCodeBytes: 4096
      )
      // rdtsc; mov ebx,eax; nop; nop; rdtsc; sub eax,ebx; hlt
      try machine.load(
        kernel: makeELF(code: [0x0F, 0x31, 0x89, 0xC3, 0x90, 0x90, 0x0F, 0x31, 0x29, 0xD8, 0xF4]),
        commandLine: "x"
      )

      #expect(try machine.runOnDedicatedStack(maximumInstructions: 16) == .halted(instructionCount: 7))
      #expect(machine.state?.registers.rax == 400)
      #expect(machine.state?.tsc == 700)
    }
  }

  @Test func machineClockAdvancesLocalAPICTimerAtItsOneGigahertzBusFrequency() throws {
    func currentCount(divideConfiguration: UInt32) throws -> UInt32 {
      let machine = try DoryPCDirectKernelMachine(memoryBytes: 2 * 1024 * 1024)
      try machine.load(kernel: makeELF(code: [0xEB, 0xFE]), commandLine: "x")
      try machine.physicalMemory.writeScalar(
        at: DoryPCV1ABI.localAPICBase + 0x3E0,
        value: UInt64(divideConfiguration),
        byteCount: 4
      )
      try machine.physicalMemory.writeScalar(
        at: DoryPCV1ABI.localAPICBase + 0x320,
        value: UInt64(0x0001_0040),
        byteCount: 4
      )
      try machine.physicalMemory.writeScalar(
        at: DoryPCV1ABI.localAPICBase + 0x380,
        value: UInt64(1_000),
        byteCount: 4
      )

      #expect(try machine.runOnDedicatedStack(maximumInstructions: 1) == .instructionBudget(1))
      return machine.localAPIC.snapshot().timer.currentCount
    }

    #expect(try currentCount(divideConfiguration: 0xB) == 900)
    #expect(try currentCount(divideConfiguration: 0x3) == 994)
  }

  @Test func timerDiagnosticsCountRequestsAtTheirDeviceSource() throws {
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      instrumentationEnabled: true
    )
    try machine.load(kernel: makeELF(code: [0xEB, 0xFE]), commandLine: "x")
    try machine.localAPIC.configureSpuriousVector(0xFF, softwareEnabled: true)
    try machine.localAPIC.configureTimer(
      vector: 0x30,
      masked: false,
      mode: .oneShot,
      initialCount: 1
    )

    #expect(try machine.runOnDedicatedStack(maximumInstructions: 1) == .instructionBudget(1))
    let diagnostics = machine.timerInterruptDiagnostics
    #expect(diagnostics.localAPICRequests == [1])
    #expect(diagnostics.pitRequests == 0)
    #expect(diagnostics.rtcRequests == 0)
    #expect(diagnostics.hpetRequests == [0, 0, 0])
    #expect(diagnostics.totalRequests == 1)
  }

  @Test func hostTimingInstrumentationIsOptInAndSeparatesWallFromThreadCPU() throws {
    let disabled = try DoryPCDirectKernelMachine(memoryBytes: 2 * 1024 * 1024)
    try disabled.load(kernel: makeELF(code: [0xEB, 0xFE]), commandLine: "x")
    _ = try disabled.runOnDedicatedStack(maximumInstructions: 1)
    #expect(!disabled.hostExecutionDiagnostics.enabled)
    #expect(disabled.hostExecutionDiagnostics.runCalls == 0)
    #expect(disabled.physicalMemory.diagnostics.totalMemoryHelperCalls == 0)
    #expect(disabled.physicalMemory.diagnostics.totalMMIOExits == 0)
    #expect(disabled.timerInterruptDiagnostics.totalRequests == 0)
    #expect(
      disabled.pagingDiagnostics.allSatisfy {
        $0.translationRequests == 0 && $0.linearInvalidations == 0
          && $0.globalInvalidations == 0
      }
    )

    let enabled = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      instrumentationEnabled: true
    )
    try enabled.load(kernel: makeELF(code: [0xEB, 0xFE]), commandLine: "x")
    _ = try enabled.runOnDedicatedStack(maximumInstructions: 16)

    let diagnostics = enabled.hostExecutionDiagnostics
    #expect(diagnostics.enabled)
    #expect(diagnostics.runCalls == 1)
    #expect(diagnostics.wall.totalNanoseconds > 0)
    #expect(diagnostics.wall.processorExecutionNanoseconds > 0)
    #expect(diagnostics.wall.attributedBasisPoints <= 10_000)
    #expect(diagnostics.threadCPU.totalNanoseconds > 0)
    #expect(diagnostics.threadCPU.processorExecutionNanoseconds > 0)
    #expect(diagnostics.threadCPU.attributedBasisPoints <= 10_000)
    #expect(enabled.physicalMemory.diagnostics.totalMemoryHelperCalls > 0)
    #expect(enabled.pagingDiagnostics.contains { $0.translationRequests > 0 })
  }

  @Test func productionClockAdvancesTSCAndDevicesFromHostMonotonicTime() throws {
    final class ManualClock: @unchecked Sendable {
      private let lock = NSLock()
      private var value: UInt64 = 0
      private var generation: UInt32 = 0

      func sample() -> UInt64 { lock.withLock { value } }
      func discontinuity() -> UInt32 { lock.withLock { generation } }
      func advance(nanoseconds: UInt64) { lock.withLock { value &+= nanoseconds } }
      func suspendAndResume(after nanoseconds: UInt64) {
        lock.withLock {
          value &+= nanoseconds
          generation &+= 1
        }
      }
    }

    let clock = ManualClock()
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      clockSource: .hostMonotonic(
        { clock.sample() },
        discontinuityGeneration: { clock.discontinuity() }
      )
    )
    // A hot loop makes instruction retirement independent from the injected host clock.
    try machine.load(kernel: makeELF(code: [0xEB, 0xFE]), commandLine: "x")
    try machine.physicalMemory.write(
      at: DoryPCV1ABI.hpetBase + 0x10,
      bytes: [1, 0, 0, 0, 0, 0, 0, 0]
    )

    #expect(try machine.runOnDedicatedStack(maximumInstructions: 1) == .instructionBudget(1))
    #expect(machine.state?.tsc == 0)

    clock.advance(nanoseconds: 1_000_000)
    #expect(try machine.runOnDedicatedStack(maximumInstructions: 1) == .instructionBudget(1))
    #expect(machine.state?.tsc == 1_000_000)
    #expect(machine.hpet.snapshot().mainCounter == 10_000)

    // Sub-tick samples retain their remainder rather than losing virtual time.
    clock.advance(nanoseconds: 99)
    _ = try machine.runOnDedicatedStack(maximumInstructions: 1)
    #expect(machine.state?.tsc == 1_000_000)
    clock.advance(nanoseconds: 1)
    _ = try machine.runOnDedicatedStack(maximumInstructions: 1)
    #expect(machine.state?.tsc == 1_000_100)

    clock.suspendAndResume(after: 30_000_000_000)
    _ = try machine.runOnDedicatedStack(maximumInstructions: 1)
    #expect(machine.state?.tsc == 1_000_100)
    clock.advance(nanoseconds: 100)
    _ = try machine.runOnDedicatedStack(maximumInstructions: 1)
    #expect(machine.state?.tsc == 1_000_200)
  }

  @Test func initAndStartupPreserveTheCoherentMachineTSC() throws {
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      processorCount: 2
    )
    try machine.load(kernel: makeELF(code: [0xEB, 0xFE]), commandLine: "x")
    _ = try machine.runOnDedicatedStack(maximumInstructions: 8)

    try machine.multiprocessorController.handleInterruptCommand(
      sourceAPICID: 0,
      high: 1 << 24,
      low: UInt32(5 << 8) | UInt32(1 << 14)
    )
    _ = try machine.runOnDedicatedStack(maximumInstructions: 1)
    var snapshots = machine.processorExecutionSnapshots
    #expect(snapshots[0].state?.tsc == snapshots[1].state?.tsc)

    try machine.multiprocessorController.handleInterruptCommand(
      sourceAPICID: 0,
      high: 1 << 24,
      low: UInt32(6 << 8) | 8
    )
    _ = try machine.runOnDedicatedStack(maximumInstructions: 1)
    snapshots = machine.processorExecutionSnapshots
    #expect(snapshots[0].state?.tsc == snapshots[1].state?.tsc)
  }

  @Test func servicingOneProcessorMailboxDoesNotApplyAnotherProcessorsStartup() throws {
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      processorCount: 3
    )
    try machine.load(kernel: makeELF(code: [0xF4]), commandLine: "x")

    for (apicID, vector) in [(UInt32(1), UInt32(8)), (UInt32(2), UInt32(9))] {
      try machine.multiprocessorController.handleInterruptCommand(
        sourceAPICID: 0,
        high: apicID << 24,
        low: 6 << 8 | vector
      )
    }

    machine.applyProcessorEvents(forProcessor: 1)

    let snapshots = machine.processorExecutionSnapshots
    #expect(snapshots[1].lifecycle == .running)
    #expect(snapshots[1].state?.cs.base == 0x8000)
    #expect(snapshots[2].lifecycle == .waitingForStartup)
    // An AP waiting for its own STARTUP remains in the architectural reset
    // state; servicing APIC 1's mailbox must not alter it to APIC 2's vector.
    #expect(snapshots[2].state?.cs.base == 0xFFFF_0000)
    #expect(machine.multiprocessorController.drainEvents(forAPICID: 2) == [
      .startup(apicID: 2, vector: 9)
    ])
  }

  @Test func pitClockScalesIdenticallyAcrossExecutionTiers() throws {
    #if arch(arm64)
      let tiers: [DoryPCExecutionTier] = [.interpreter, .baselineJIT, .optimizingJIT]
    #else
      let tiers: [DoryPCExecutionTier] = [.interpreter]
    #endif

    for tier in tiers {
      let machine = try DoryPCDirectKernelMachine(
        memoryBytes: 2 * 1024 * 1024,
        executionTier: tier,
        baselineJITMaximumCodeBytes: 4096
      )
      try machine.load(
        kernel: makeELF(code: [UInt8](repeating: 0x90, count: 128) + [0xF4]),
        commandLine: "x"
      )
      // Channel 0, low/high byte, one-shot, count 1000.
      try machine.ioBus.write(port: 0x43, value: 0x30, width: .byte)
      try machine.ioBus.write(port: 0x40, value: 0xE8, width: .byte)
      try machine.ioBus.write(port: 0x40, value: 0x03, width: .byte)

      #expect(try machine.runOnDedicatedStack(maximumInstructions: 100) == .instructionBudget(100))
      #expect(machine.legacyPIT.snapshot().current == 989)
    }
  }

  @Test func jitTiersFallBackToTheInterpreterForUnsupportedBlocks() throws {
    #if arch(arm64)
      for tier in [DoryPCExecutionTier.baselineJIT, .optimizingJIT] {
        let machine = try DoryPCDirectKernelMachine(
          memoryBytes: 2 * 1024 * 1024,
          executionTier: tier,
          baselineJITMaximumCodeBytes: 4096
        )
        // mov dword ptr [0x100],1; hlt. Memory IR deliberately remains interpreter-backed.
        try machine.load(
          kernel: makeELF(code: [0xC7, 0x04, 0x25, 0, 1, 0, 0, 1, 0, 0, 0, 0xF4]),
          commandLine: "x"
        )

        #expect(try machine.runOnDedicatedStack(maximumInstructions: 4) == .halted(instructionCount: 2))
        #expect(try machine.memory.read(at: 0x100, byteCount: 4) == [1, 0, 0, 0])
        #expect(machine.executionStatistics.interpreterInstructions == 1)
      }
    #endif
  }

  @Test func installerPITCalibrationPortSequenceRetiresAcrossExecutionTiers() throws {
    #if arch(arm64)
      let tiers: [DoryPCExecutionTier] = [.interpreter, .baselineJIT, .optimizingJIT]
    #else
      let tiers: [DoryPCExecutionTier] = [.interpreter]
    #endif

    for tier in tiers {
      let machine = try DoryPCDirectKernelMachine(
        memoryBytes: 2 * 1024 * 1024,
        executionTier: tier,
        baselineJITMaximumCodeBytes: 4096
      )
      // in al,0x61; and eax,-4; out 0x61,al; program PIT channel 2; enable its gate; hlt
      let code: [UInt8] = [
        0xE4, 0x61,
        0x83, 0xE0, 0xFC,
        0xE6, 0x61,
        0xB0, 0xB0,
        0xE6, 0x43,
        0xB0, 0x03,
        0xE6, 0x42,
        0x30, 0xC0,
        0xE6, 0x42,
        0xE4, 0x61,
        0x0C, 0x01,
        0xE6, 0x61,
        0xF4,
      ]
      try machine.load(kernel: makeELF(code: code), commandLine: "x")

      #expect(try machine.runOnDedicatedStack(maximumInstructions: 32) == .halted(instructionCount: 13))
      #expect(try machine.ioBus.read(port: 0x61, width: .byte) & 0x01 == 1)
    }
  }

  @Test func optionalLegacySerialProbeObservesAnOpenBusAcrossExecutionTiers() throws {
    #if arch(arm64)
      let tiers: [DoryPCExecutionTier] = [.interpreter, .baselineJIT, .optimizingJIT]
    #else
      let tiers: [DoryPCExecutionTier] = [.interpreter]
    #endif

    for tier in tiers {
      let machine = try DoryPCDirectKernelMachine(
        memoryBytes: 2 * 1024 * 1024,
        executionTier: tier,
        baselineJITMaximumCodeBytes: 4096
      )
      // Probe the absent COM2 scratch register exactly as the installer loader does.
      let code: [UInt8] = [
        0xBA, 0xFF, 0x02, 0x00, 0x00,
        0xB0, 0x5A,
        0xEE,
        0xEC,
        0x3C, 0x5A,
        0xF4,
      ]
      try machine.load(kernel: makeELF(code: code), commandLine: "x")

      #expect(try machine.runOnDedicatedStack(maximumInstructions: 16) == .halted(instructionCount: 6))
      let state = try #require(machine.state)
      #expect(state.registers.rax & 0xFF == 0xFF)
      #expect(!state.rflags.contains(.zero))
    }
  }

  @Test func jitUnmappedBlockFetchFallsBackToPreciseInterpreterPageFault() throws {
    #if arch(arm64)
      for tier in [DoryPCExecutionTier.baselineJIT, .optimizingJIT] {
        let machine = try DoryPCDirectKernelMachine(
          memoryBytes: 2 * 1024 * 1024,
          executionTier: tier,
          baselineJITMaximumCodeBytes: 4096
        )
        // Enable 32-bit paging with a single identity-mapped 4 MiB page, then jump to the
        // deliberately unmapped next page. The JIT's speculative block fetch must decline and
        // allow the interpreter to produce the architectural page fault.
        let code: [UInt8] = [
          0xB8, 0x10, 0x00, 0x00, 0x00,  // mov eax,CR4.PSE
          0x0F, 0x22, 0xE0,  // mov cr4,eax
          0xB8, 0x00, 0x00, 0x08, 0x00,  // mov eax,0x80000
          0x0F, 0x22, 0xD8,  // mov cr3,eax
          0x0F, 0x20, 0xC0,  // mov eax,cr0
          0x0D, 0x00, 0x00, 0x00, 0x80,  // or eax,CR0.PG
          0x0F, 0x22, 0xC0,  // mov cr0,eax
          0xB8, 0x00, 0x00, 0x40, 0x00,  // mov eax,0x400000
          0xFF, 0xE0,  // jmp eax
        ]
        try machine.load(
          kernel: makeELF(code: code),
          commandLine: "x"
        )
        try machine.memory.write(at: 0x80000, bytes: [0x83, 0x00, 0x00, 0x00])

        guard case .exception(let exception, _) = try machine.runOnDedicatedStack(maximumInstructions: 16) else {
          Issue.record("expected page fault")
          continue
        }
        #expect(exception.kind == .pageFault)
        #expect(exception.linearAddress == 0x400000)
      }
    #endif
  }

  @Test func directKernelCanProgramTheStandardLocalAPICWindow() throws {
    let layout = DoryPCPVHBootLayout(
      startInfo: 0x90000,
      commandLine: 0x91000,
      modules: 0x92000,
      memoryMap: 0x93000,
      initrd: 0x180000
    )
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      bootLayout: layout
    )
    // mov dword ptr [0xfee000f0],0x1ff; hlt
    let code: [UInt8] = [
      0xC7, 0x04, 0x25, 0xF0, 0x00, 0xE0, 0xFE, 0xFF, 0x01, 0x00, 0x00,
      0xF4,
    ]

    try machine.load(kernel: makeELF(code: code), commandLine: "x")
    #expect(try machine.runOnDedicatedStack(maximumInstructions: 4) == .halted(instructionCount: 2))
    #expect(machine.localAPIC.snapshot().softwareEnabled)
    #expect(try machine.physicalMemory.read(at: 0xFEE0_0020, byteCount: 4) == [0, 0, 0, 0])
  }

  @Test func productLoopDeliversCPUExceptionsThroughTheGuestIDT() throws {
    let layout = DoryPCPVHBootLayout(
      startInfo: 0x90000,
      commandLine: 0x91000,
      modules: 0x92000,
      memoryMap: 0x93000,
      initrd: 0x180000
    )
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      bootLayout: layout
    )
    var code = [UInt8](repeating: 0x90, count: 0x108)
    // lidt [0x80000]; lgdt [0x80006]; ud2
    code.replaceSubrange(
      0..<16,
      with: [
        0x0F, 0x01, 0x1D, 0, 0, 8, 0,
        0x0F, 0x01, 0x15, 6, 0, 8, 0,
        0x0F, 0x0B,
      ]
    )
    // Exception handler at 0x100100: mov al,'E'; mov edx,0x3f8; out dx,al; hlt
    code.replaceSubrange(
      0x100..<0x108,
      with: [0xB0, UInt8(ascii: "E"), 0xBA, 0xF8, 0x03, 0, 0, 0xEE, 0xF4]
    )
    try machine.load(kernel: makeELF(code: code), commandLine: "x")

    // IDTR descriptor and vector-6 32-bit interrupt gate.
    try machine.memory.write(at: 0x80000, bytes: [0xFF, 0x07, 0x00, 0x10, 0x08, 0x00])
    try machine.memory.write(at: 0x80006, bytes: [0x17, 0x00, 0x00, 0x20, 0x08, 0x00])
    try machine.memory.write(
      at: 0x81000 + 6 * 8,
      bytes: [0x00, 0x01, 0x08, 0x00, 0x00, 0x8E, 0x10, 0x00]
    )
    try machine.memory.write(
      at: 0x82000,
      bytes: [
        0, 0, 0, 0, 0, 0, 0, 0,
        0xFF, 0xFF, 0, 0, 0, 0x9B, 0xCF, 0,
        0xFF, 0xFF, 0, 0, 0, 0x93, 0xCF, 0,
      ]
    )

    let stop = try machine.runOnDedicatedStack(maximumInstructions: 16, exceptionPolicy: .deliver)

    #expect(stop == .halted(instructionCount: 7))
    #expect(machine.serial.drainTransmittedBytes() == [UInt8(ascii: "E")])
  }

  @Test func haltedCPUWakesForTheLocalAPICTimer() throws {
    let layout = DoryPCPVHBootLayout(
      startInfo: 0x90000,
      commandLine: 0x91000,
      modules: 0x92000,
      memoryMap: 0x93000,
      initrd: 0x180000
    )
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      bootLayout: layout
    )
    var code = [UInt8](repeating: 0x90, count: 0x109)
    // lidt [0x80000]; lgdt [0x80006]; sti; hlt
    code.replaceSubrange(
      0..<16,
      with: [
        0x0F, 0x01, 0x1D, 0, 0, 8, 0,
        0x0F, 0x01, 0x15, 6, 0, 8, 0,
        0xFB, 0xF4,
      ]
    )
    code.replaceSubrange(
      0x100..<0x109,
      with: [0xB0, UInt8(ascii: "T"), 0xBA, 0xF8, 0x03, 0, 0, 0xEE, 0xF4]
    )
    try machine.load(kernel: makeELF(code: code), commandLine: "x")
    try installProtectedTables(machine: machine, vector: 0x30)
    try machine.localAPIC.configureSpuriousVector(0xFF, softwareEnabled: true)
    try machine.localAPIC.configureTimer(
      vector: 0x30,
      masked: false,
      mode: .oneShot,
      // The reset divide-by-two setting yields 50 LAPIC counts per 100 ns machine tick. Keep the
      // expiry after STI;HLT so this test exercises the halted-vCPU wake path.
      initialCount: 250
    )

    let stop = try machine.runOnDedicatedStack(maximumInstructions: 16, exceptionPolicy: .deliver)

    #expect(stop == .halted(instructionCount: 8))
    #expect(machine.serial.drainTransmittedBytes() == [UInt8(ascii: "T")])
  }

  @Test func haltedCPUWakesForTheLegacyPITAndPIC() throws {
    let layout = DoryPCPVHBootLayout(
      startInfo: 0x90000,
      commandLine: 0x91000,
      modules: 0x92000,
      memoryMap: 0x93000,
      initrd: 0x180000
    )
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      bootLayout: layout
    )
    var code = [UInt8](repeating: 0x90, count: 0x109)
    code.replaceSubrange(
      0..<16,
      with: [
        0x0F, 0x01, 0x1D, 0, 0, 8, 0,
        0x0F, 0x01, 0x15, 6, 0, 8, 0,
        0xFB, 0xF4,
      ]
    )
    code.replaceSubrange(
      0x100..<0x109,
      with: [0xB0, UInt8(ascii: "P"), 0xBA, 0xF8, 0x03, 0, 0, 0xEE, 0xF4]
    )
    try machine.load(kernel: makeELF(code: code), commandLine: "x")
    try installProtectedTables(machine: machine, vector: 0x20)

    // Remap the master PIC to 0x20, preserve its cascade wiring, and unmask only IRQ0.
    try machine.ioBus.write(port: 0x20, value: 0x11, width: .byte)
    try machine.ioBus.write(port: 0x21, value: 0x20, width: .byte)
    try machine.ioBus.write(port: 0x21, value: 0x04, width: .byte)
    try machine.ioBus.write(port: 0x21, value: 0x01, width: .byte)
    try machine.ioBus.write(port: 0x21, value: 0xFE, width: .byte)
    // Channel 0, low/high byte, one-shot, count 5.
    try machine.ioBus.write(port: 0x43, value: 0x30, width: .byte)
    try machine.ioBus.write(port: 0x40, value: 5, width: .byte)
    try machine.ioBus.write(port: 0x40, value: 0, width: .byte)

    let stop = try machine.runOnDedicatedStack(maximumInstructions: 16, exceptionPolicy: .deliver)

    #expect(stop == .halted(instructionCount: 8))
    #expect(machine.serial.drainTransmittedBytes() == [UInt8(ascii: "P")])
  }

  @Test func haltedCPUStopsWhenPeriodicAPICTimerCannotBeDelivered() throws {
    let machine = try DoryPCDirectKernelMachine(memoryBytes: 2 * 1024 * 1024)
    try machine.load(kernel: makeELF(code: [0xFB, 0xF4]), commandLine: "x")
    try machine.localAPIC.configureTimer(
      vector: 0x30,
      masked: false,
      mode: .periodic,
      initialCount: 1
    )

    let stop = try machine.runOnDedicatedStack(maximumInstructions: 16, exceptionPolicy: .deliver)

    #expect(stop == .halted(instructionCount: 2))
    #expect(machine.localAPIC.snapshot().timer.currentCount == 1)
  }

  @Test func haltedCPUWakesForHPETLegacyAndOrdinaryRoutesWithPICMasked() throws {
    for (timer, legacy, pin) in [(0, true, 2), (1, true, 8), (0, false, 0)] {
      let machine = try DoryPCDirectKernelMachine(memoryBytes: 2 * 1024 * 1024)
      var code = [UInt8](repeating: 0x90, count: 0x109)
      code.replaceSubrange(0..<16, with: [
        0x0F, 0x01, 0x1D, 0, 0, 8, 0, // LIDT [0x80000]
        0x0F, 0x01, 0x15, 6, 0, 8, 0, // LGDT [0x80006]
        0xFB, 0xF4, // STI; HLT
      ])
      code.replaceSubrange(0x100..<0x109, with: [
        0xB0, UInt8(ascii: "H"), 0xBA, 0xF8, 0x03, 0, 0, 0xEE, 0xF4,
      ])
      try machine.load(kernel: makeELF(code: code), commandLine: "x")
      try installProtectedTables(machine: machine, vector: 0x30)
      try machine.localAPIC.configureSpuriousVector(0xFF, softwareEnabled: true)
      try machine.ioAPIC.configure(pin: pin,
        route: .init(vector: 0x30, destinationAPICID: 0, masked: false))
      #expect(machine.legacyPIC.snapshot().masterMask == 0xFF)
      #expect(machine.legacyPIC.snapshot().slaveMask == 0xFF)
      try machine.physicalMemory.writeScalar(at: 0xFED0_0100 + UInt64(timer * 0x20),
        value: (1 << 2), byteCount: 8)
      try machine.physicalMemory.writeScalar(at: 0xFED0_0108 + UInt64(timer * 0x20),
        value: 10, byteCount: 8)
      try machine.physicalMemory.writeScalar(at: 0xFED0_0010, value: legacy ? 3 : 1, byteCount: 8)
      #expect(try machine.runOnDedicatedStack(maximumInstructions: 16, exceptionPolicy: .deliver)
        == .halted(instructionCount: 8))
      #expect(machine.serial.drainTransmittedBytes() == [UInt8(ascii: "H")])
      #expect(machine.executionStatistics.deliveredMaskableInterrupts == 1)
      #expect(machine.executionStatistics.deliveredNonMaskableInterrupts == 0)
      #expect(machine.executionStatistics.retiredInterruptReturns == 0)
      #expect(
        machine.executionStatistics.deliveredInterruptVectors
          == [.init(vector: 0x30, deliveries: 1)])
    }
  }

  @Test func nativeQuantumStopsAtHPETLegacyDeadlineWhenOnlyGSI2CanDeliver() throws {
    #if arch(arm64)
      for tier: DoryPCExecutionTier in [.baselineJIT, .optimizingJIT] {
        let machine = try DoryPCDirectKernelMachine(memoryBytes: 2 * 1024 * 1024,
          executionTier: tier, baselineJITMaximumCodeBytes: 16 * 1024)
        try machine.load(kernel: makeELF(code: [0xFB, 0xEB, 0xFE]), commandLine: "x")
        try machine.localAPIC.configureSpuriousVector(0xFF, softwareEnabled: true)
        try machine.ioAPIC.configure(pin: 2,
          route: .init(vector: 0x30, destinationAPICID: 0, masked: false))
        try machine.physicalMemory.writeScalar(at: 0xFED0_0100, value: 1 << 2, byteCount: 8)
        try machine.physicalMemory.writeScalar(at: 0xFED0_0108, value: 5, byteCount: 8)
        try machine.physicalMemory.writeScalar(at: 0xFED0_0010, value: 3, byteCount: 8)
        // Deliberately omit an IDT: observing delivery before the 20-instruction budget proves
        // that batching stopped at the accepted timer deadline instead of overrunning it.
        let stop = try machine.runOnDedicatedStack(maximumInstructions: 20)
        guard case .tripleFault(let source, let count) = stop,
          case .interrupt(let vector, _, let processor) = source
        else {
          Issue.record("Expected the HPET interrupt at its deadline, got \(stop)")
          continue
        }
        #expect(vector == 0x30)
        #expect(processor == 0)
        #expect(count == 4)
        #expect(machine.hpet.snapshot().mainCounter == 5)
      }
    #endif
  }

  private func installProtectedTables(
    machine: DoryPCDirectKernelMachine,
    vector: UInt8
  ) throws {
    try machine.memory.write(at: 0x80000, bytes: [0xFF, 0x07, 0x00, 0x10, 0x08, 0x00])
    try machine.memory.write(at: 0x80006, bytes: [0x17, 0x00, 0x00, 0x20, 0x08, 0x00])
    try machine.memory.write(
      at: 0x81000 + UInt64(vector) * 8,
      bytes: [0x00, 0x01, 0x08, 0x00, 0x00, 0x8E, 0x10, 0x00]
    )
    try machine.memory.write(
      at: 0x82000,
      bytes: [
        0, 0, 0, 0, 0, 0, 0, 0,
        0xFF, 0xFF, 0, 0, 0, 0x9B, 0xCF, 0,
        0xFF, 0xFF, 0, 0, 0, 0x93, 0xCF, 0,
      ]
    )
  }

  private func makeELF(code: [UInt8]) -> Data {
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
    writeHeader(
      to: &data,
      at: 0x40,
      type: 1,
      fileOffset: UInt64(segmentOffset),
      physicalAddress: 0x10_0000,
      size: UInt64(code.count)
    )
    writeHeader(
      to: &data,
      at: 0x78,
      type: 4,
      fileOffset: 0x180,
      physicalAddress: 0,
      size: 20
    )
    write(UInt32(4), to: &data, at: 0x180)
    write(UInt32(4), to: &data, at: 0x184)
    write(UInt32(0x12), to: &data, at: 0x188)
    data.replaceSubrange(0x18C..<0x190, with: [0x58, 0x65, 0x6E, 0])
    write(UInt32(0x10_0000), to: &data, at: 0x190)
    data.replaceSubrange(segmentOffset..<(segmentOffset + code.count), with: code)
    return data
  }

  private func writeHeader(
    to data: inout Data,
    at offset: Int,
    type: UInt32,
    fileOffset: UInt64,
    physicalAddress: UInt64,
    size: UInt64
  ) {
    write(type, to: &data, at: offset)
    write(fileOffset, to: &data, at: offset + 8)
    write(physicalAddress, to: &data, at: offset + 24)
    write(size, to: &data, at: offset + 32)
    write(size, to: &data, at: offset + 40)
  }

  private func write<T: FixedWidthInteger>(_ value: T, to data: inout Data, at offset: Int) {
    for index in 0..<MemoryLayout<T>.size {
      data[offset + index] = UInt8(truncatingIfNeeded: value >> T(index * 8))
    }
  }
}

private final class HaltedMachineRun: @unchecked Sendable {
  private let lock = NSLock()
  private let finished = DispatchSemaphore(value: 0)
  private var result: Result<DoryPCMachineStop, any Error>?

  init(machine: DoryPCDirectKernelMachine, maximumInstructions: UInt64) {
    let thread = Thread { [self] in
      let outcome = Result {
        try machine.run(maximumInstructions: maximumInstructions, exceptionPolicy: .deliver)
      }
      lock.withLock { result = outcome }
      finished.signal()
    }
    thread.name = "dev.dory.tests.pc-halted-wake"
    thread.stackSize = 2 * 1024 * 1024
    thread.start()
  }

  func finish() throws -> DoryPCMachineStop {
    try #require(finished.wait(timeout: .now() + 2) == .success)
    return try lock.withLock { try #require(result).get() }
  }
}

private final class HaltedMachineClockGate: @unchecked Sendable {
  let reached = DispatchSemaphore(value: 0)
  let proceed = DispatchSemaphore(value: 0)
  // sample() is called only by the dedicated serialized run thread.
  private var samples = 0

  func sample() -> UInt64 {
    samples += 1
    if samples == 3 {
      reached.signal()
      _ = proceed.wait(timeout: .now() + 2)
    }
    return 0
  }
}

private final class HostWorkerProbe: @unchecked Sendable {
  struct Snapshot {
    let distinctThreads: Int
    let maximumActive: Int
    let active: Int
    let stopped: Set<Int>
    let executions: Int
    let order: [Int]
    let timedOut: Bool
    let nativeRetirements: [Int: [UInt64]]
  }

  let arrived = DispatchSemaphore(value: 0)
  private let condition = NSCondition()
  private let hold: Bool
  private var released = false
  private var threads: [Int: ObjectIdentifier] = [:]
  private var active = 0
  private var maximumActive = 0
  private var parallelEntries = 0
  private var stopped: Set<Int> = []
  private var order: [Int] = []
  private var timedOut = false
  private var nativeRetirements: [Int: [UInt64]] = [:]

  init(hold: Bool = false) { self.hold = hold }

  func observe(_ event: DoryPCDirectKernelMachine.WorkerEvent) {
    condition.lock()
    defer { condition.unlock() }
    switch event {
    case .executing(let processor, _):
      threads[processor] = ObjectIdentifier(Thread.current)
      order.append(processor)
      active += 1
      maximumActive = max(maximumActive, active)
    case .frozenInstructionFetch, .nativeInstructionFetch:
      parallelEntries += 1
      if parallelEntries == 2 { arrived.signal(); condition.broadcast() }
      let deadline = Date(timeIntervalSinceNow: 2)
      while parallelEntries < 2 || (hold && !released) {
        if !condition.wait(until: deadline) { timedOut = true; break }
      }
    case .nativeInstructionExit(let processor, let retired):
      nativeRetirements[processor, default: []].append(retired)
    case .executed:
      active -= 1
    case .stopped(let processor):
      stopped.insert(processor)
    }
  }

  func release() {
    condition.lock()
    released = true
    condition.broadcast()
    condition.unlock()
  }

  func snapshot() -> Snapshot {
    condition.lock()
    defer { condition.unlock() }
    return .init(distinctThreads: Set(threads.values).count, maximumActive: maximumActive,
      active: active, stopped: stopped, executions: order.count, order: order, timedOut: timedOut,
      nativeRetirements: nativeRetirements)
  }
}

private final class WorkerSampleClock: @unchecked Sendable {
  private let lock = NSLock()
  private var count: UInt64 = 0
  var samples: UInt64 { lock.withLock { count } }

  func sample() -> UInt64 {
    lock.withLock {
      count += 1
      return count * 100
    }
  }
}
