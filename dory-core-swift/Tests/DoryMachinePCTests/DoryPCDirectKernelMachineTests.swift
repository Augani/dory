import Foundation
import Testing

@testable import DoryMachinePC

@Suite struct DoryPCDirectKernelMachineTests {
  @Test func diagnosticInstructionBytesFollowTheLoadedProcessor() throws {
    let machine = try DoryPCDirectKernelMachine(memoryBytes: 2 * 1024 * 1024)
    try machine.load(kernel: makeELF(code: [0x90, 0xF4]), commandLine: "x")

    #expect(try machine.instructionBytes(maximumCount: 2) == [0x90, 0xF4])
    let entry = try #require(machine.state?.rip)
    #expect(try machine.memoryBytes(atLinearAddress: entry, maximumCount: 2) == [0x90, 0xF4])
    #expect(try machine.memoryBytes(atLinearAddress: entry, maximumCount: 0) == [])
    #expect(try machine.memoryBytes(forProcessor: 1, atLinearAddress: entry, maximumCount: 1) == nil)
    #expect(try machine.run(maximumInstructions: 1) == .instructionBudget(1))
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
    let stop = try machine.run(maximumInstructions: 16)

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

    #expect(try machine.run(maximumInstructions: 16) == .halted(instructionCount: 5))
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
    #expect(try budgeted.run(maximumInstructions: 5) == .instructionBudget(5))

    let faulting = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      bootLayout: layout
    )
    try faulting.load(kernel: makeELF(code: [0x0F, 0x0B]), commandLine: "x")
    guard case .exception(let exception, let count) = try faulting.run(maximumInstructions: 1)
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

      #expect(try machine.run(maximumInstructions: 8) == .halted(instructionCount: 3))
      #expect(machine.state?.registers.rax == 3)
      #expect(machine.executionStatistics.baselineJITInstructions == 3)
      #expect(machine.executionStatistics.baselineJITBlocks == 1)
      #expect(machine.executionStatistics.interpreterInstructions == 0)
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
          try machine.run(maximumInstructions: UInt64(budget))
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
      // CPUID declines native emission; the backward jump keeps revisiting the same exact site
      // while the resident resolver's 64-instruction budget remains stable.
      try machine.load(kernel: makeELF(code: [0x0F, 0xA2, 0xEB, 0xFC]), commandLine: "x")

      #expect(try machine.run(maximumInstructions: 130) == .instructionBudget(130))
      let diagnostics = try #require(machine.baselineJITDiagnostics)
      let hotSite = try #require(diagnostics.negativeCacheHotSites.first)
      #expect(hotSite.guestRIP == 0x10_0000)
      #expect(hotSite.executionMode == .protected32)
      #expect(hotSite.instructionBudget == 64)
      #expect(hotSite.addressSpaceID == 0)
      #expect(hotSite.privilegeLevel == 0)
      #expect(hotSite.pagingEnabled == false)
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

      #expect(try machine.run(maximumInstructions: 130) == .instructionBudget(130))
      let diagnostics = try #require(machine.baselineJITDiagnostics)
      #expect(diagnostics.chainedExecutionCalls == 2)
      #expect(diagnostics.chainedRequestedInstructions == 128)
      #expect(diagnostics.chainedRetiredInstructions == 128)
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
      // STI retires through the precise path, then the hot loop receives only the three machine
      // ticks remaining before this accepted local-APIC deadline.
      try machine.load(kernel: makeELF(code: [0xFB, 0xEB, 0xFE]), commandLine: "x")
      try machine.localAPIC.configureSpuriousVector(0xFF, softwareEnabled: true)
      try machine.localAPIC.configureTimer(
        vector: 0x30,
        masked: false,
        mode: .oneShot,
        initialCount: 250
      )

      #expect(try machine.run(maximumInstructions: 4) == .instructionBudget(4))
      let diagnostics = try #require(machine.baselineJITDiagnostics)
      // The first four-instruction request declines STI to the interpreter. The second request is
      // capped to the three ticks remaining until the now-accepted timer deadline.
      #expect(diagnostics.chainedExecutionCalls == 2)
      #expect(diagnostics.chainedRequestedInstructions == 7)
      #expect(diagnostics.chainedRetiredInstructions == 3)
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

      #expect(try machine.run(maximumInstructions: 8) == .halted(instructionCount: 4))
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

      #expect(try machine.run(maximumInstructions: 16) == .halted(instructionCount: 5))
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

      #expect(try machine.run(maximumInstructions: 1) == .instructionBudget(1))
      #expect(try machine.run(maximumInstructions: 1) == .instructionBudget(1))
      #expect(machine.executionStatistics.baselineJITInstructions == 2)
      #expect(machine.executionStatistics.optimizingJITInstructions == 0)

      #expect(try machine.run(maximumInstructions: 1) == .instructionBudget(1))
      #expect(machine.executionStatistics.baselineJITInstructions == 2)
      #expect(machine.executionStatistics.optimizingJITInstructions == 1)
      #expect(machine.executionStatistics.interpreterInstructions == 0)
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

      #expect(try machine.run(maximumInstructions: 16) == .halted(instructionCount: 7))
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

      #expect(try machine.run(maximumInstructions: 1) == .instructionBudget(1))
      return machine.localAPIC.snapshot().timer.currentCount
    }

    #expect(try currentCount(divideConfiguration: 0xB) == 900)
    #expect(try currentCount(divideConfiguration: 0x3) == 994)
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

    #expect(try machine.run(maximumInstructions: 1) == .instructionBudget(1))
    #expect(machine.state?.tsc == 0)

    clock.advance(nanoseconds: 1_000_000)
    #expect(try machine.run(maximumInstructions: 1) == .instructionBudget(1))
    #expect(machine.state?.tsc == 1_000_000)
    #expect(machine.hpet.snapshot().mainCounter == 10_000)

    // Sub-tick samples retain their remainder rather than losing virtual time.
    clock.advance(nanoseconds: 99)
    _ = try machine.run(maximumInstructions: 1)
    #expect(machine.state?.tsc == 1_000_000)
    clock.advance(nanoseconds: 1)
    _ = try machine.run(maximumInstructions: 1)
    #expect(machine.state?.tsc == 1_000_100)

    clock.suspendAndResume(after: 30_000_000_000)
    _ = try machine.run(maximumInstructions: 1)
    #expect(machine.state?.tsc == 1_000_100)
    clock.advance(nanoseconds: 100)
    _ = try machine.run(maximumInstructions: 1)
    #expect(machine.state?.tsc == 1_000_200)
  }

  @Test func initAndStartupPreserveTheCoherentMachineTSC() throws {
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      processorCount: 2
    )
    try machine.load(kernel: makeELF(code: [0xEB, 0xFE]), commandLine: "x")
    _ = try machine.run(maximumInstructions: 8)

    try machine.multiprocessorController.handleInterruptCommand(
      sourceAPICID: 0,
      high: 1 << 24,
      low: UInt32(5 << 8) | UInt32(1 << 14)
    )
    _ = try machine.run(maximumInstructions: 1)
    var snapshots = machine.processorExecutionSnapshots
    #expect(snapshots[0].state?.tsc == snapshots[1].state?.tsc)

    try machine.multiprocessorController.handleInterruptCommand(
      sourceAPICID: 0,
      high: 1 << 24,
      low: UInt32(6 << 8) | 8
    )
    _ = try machine.run(maximumInstructions: 1)
    snapshots = machine.processorExecutionSnapshots
    #expect(snapshots[0].state?.tsc == snapshots[1].state?.tsc)
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

      #expect(try machine.run(maximumInstructions: 100) == .instructionBudget(100))
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

        #expect(try machine.run(maximumInstructions: 4) == .halted(instructionCount: 2))
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

      #expect(try machine.run(maximumInstructions: 32) == .halted(instructionCount: 13))
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

      #expect(try machine.run(maximumInstructions: 16) == .halted(instructionCount: 6))
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

        guard case .exception(let exception, _) = try machine.run(maximumInstructions: 16) else {
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
    #expect(try machine.run(maximumInstructions: 4) == .halted(instructionCount: 2))
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

    let stop = try machine.run(maximumInstructions: 16, exceptionPolicy: .deliver)

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

    let stop = try machine.run(maximumInstructions: 16, exceptionPolicy: .deliver)

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

    let stop = try machine.run(maximumInstructions: 16, exceptionPolicy: .deliver)

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

    let stop = try machine.run(maximumInstructions: 16, exceptionPolicy: .deliver)

    #expect(stop == .halted(instructionCount: 2))
    #expect(machine.localAPIC.snapshot().timer.currentCount == 1)
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
    write(UInt16(0x3E), to: &data, at: 18)
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
