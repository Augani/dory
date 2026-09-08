#if arch(arm64)
  import Darwin
  import DoryExecutionContracts
  import DoryPhase0AHostNativeWorkload
  import Foundation
  import Testing
  @testable import DoryNativeHVArm64

  private let nativeHVSmokeEnabled =
    ProcessInfo.processInfo.environment["DORY_RUN_NATIVE_HV_SMOKE"] == "1"

  @Suite(.serialized)
  struct NativeHVArm64EngineTests {
    @Test func hostNativeCounterLoopPreservesExactIterationCount() {
      #expect(dory_phase0a_native_counter_loop(10_000) == 10_000)
    }

    @Test(.enabled(if: nativeHVSmokeEnabled))
    func executesGuestAndCapturesArchitecturalState() throws {
      guard #available(macOS 15.0, *) else { return }
      let receipt = try DoryNativeHVArm64Smoke.run()
      #expect(receipt.hypercallNumber == 42)
      #expect(receipt.architecturalX0 == UInt64.max)
      #expect(receipt.programCounter == 0x8000_0008)
      #expect(receipt.dirtyPageCount == 1)
    }

    @Test(.enabled(if: nativeHVSmokeEnabled))
    func minimalHarnessExecutesFixedCounterLoop() throws {
      guard #available(macOS 15.0, *) else { return }
      let count = try DoryNativeHVArm64MinimalHarness.runCounterLoop()
      #expect(count == DoryNativeHVArm64MinimalHarness.counterLoopIterations)
    }

    @Test(.enabled(if: nativeHVSmokeEnabled))
    func pastDeadlineCancelsWithoutEnteringGuest() throws {
      guard #available(macOS 15.0, *) else { return }
      try NativeHVArm64EngineProgram.with(instructions: Self.spinLoop) { program in
        let now = DoryNativeHVArm64HostClock.nowTicks()
        let deadline = DoryVirtualDeadline(monotonicTicks: now == 0 ? 0 : now - 1)
        let exit = try program.engine.run(program.vcpu, until: deadline)
        guard case .cancelled(let request) = exit.reason else {
          Issue.record("expected deadline cancellation, got \(exit.reason)")
          return
        }
        #expect(request.reason == .deadlineExceeded)
        #expect(request.executionGeneration == 1)
        #expect(try program.capturedProgramCounter() == 0x8000_0000)
      }
    }

    @Test(.enabled(if: nativeHVSmokeEnabled))
    func farFutureDeadlineStillRetiresHypercall() throws {
      guard #available(macOS 15.0, *) else { return }
      try NativeHVArm64EngineProgram.with(instructions: Self.hypercallFortyTwo) { program in
        let deadline = DoryNativeHVArm64HostClock.deadline(nanosecondsFromNow: 60_000_000_000)
        let exit = try program.engine.run(program.vcpu, until: deadline)
        guard case .hypercall(let number, _, let token) = exit.reason else {
          Issue.record("expected hypercall, got \(exit.reason)")
          return
        }
        #expect(number == 42)
        try program.engine.complete(token, with: .hypercallResult([UInt64.max]))
      }
    }

    @Test(.enabled(if: nativeHVSmokeEnabled))
    func spinLoopHonorsShortHostDeadline() throws {
      guard #available(macOS 15.0, *) else { return }
      try NativeHVArm64EngineProgram.with(instructions: Self.spinLoop) { program in
        let deadline = DoryNativeHVArm64HostClock.deadline(nanosecondsFromNow: 50_000_000)
        let started = DoryNativeHVArm64HostClock.nowTicks()
        let exit = try program.engine.run(program.vcpu, until: deadline)
        let elapsed = DoryNativeHVArm64HostClock.nanosecondsUntil(
          DoryVirtualDeadline(monotonicTicks: DoryNativeHVArm64HostClock.nowTicks()), from: started)
        guard case .cancelled(let request) = exit.reason else {
          Issue.record("expected deadline cancellation, got \(exit.reason)")
          return
        }
        #expect(request.reason == .deadlineExceeded)
        #expect(elapsed < 2_000_000_000)
      }
    }

    @Test(.enabled(if: nativeHVSmokeEnabled))
    func userCancelDuringSpinBeatsUnsetDeadline() throws {
      guard #available(macOS 15.0, *) else { return }
      try NativeHVArm64EngineProgram.with(instructions: Self.spinLoop) { program in
        let request = try DoryExecutionCancellationRequest(
          executionGeneration: 1,
          cancellationGeneration: 7,
          reason: .userRequested
        )
        let engine = program.engine
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.05) {
          try? engine.cancel(request)
        }
        let safety = DoryNativeHVArm64HostClock.deadline(nanosecondsFromNow: 2_000_000_000)
        let exit = try engine.run(program.vcpu, until: safety)
        guard case .cancelled(let observed) = exit.reason else {
          Issue.record("expected user cancellation, got \(exit.reason)")
          return
        }
        #expect(observed == request)
      }
    }

    private static let hypercallFortyTwo: [UInt32] = [
      0xd280_0540,  // mov x0, #42
      0xd400_0002,  // hvc #0
    ]

    private static let spinLoop: [UInt32] = [
      0x1400_0000,  // b .
    ]
  }

  @available(macOS 15.0, *)
  private struct NativeHVArm64EngineProgram {
    let engine: DoryNativeHVArm64Engine
    let vcpu: DoryVCPU

    static func with(
      instructions: [UInt32],
      body: (NativeHVArm64EngineProgram) throws -> Void
    ) throws {
      let engine = try DoryNativeHVArm64Engine(executionGeneration: 1)
      var createdVCPU: DoryVCPU?
      let pageSize = UInt64(getpagesize())
      let memory = UnsafeMutableRawPointer.allocate(
        byteCount: Int(pageSize),
        alignment: Int(pageSize)
      )
      memory.initializeMemory(as: UInt8.self, repeating: 0, count: Int(pageSize))
      defer {
        if let createdVCPU { try? engine.destroyVCPU(createdVCPU) }
        if (try? engine.close()) != nil { memory.deallocate() }
      }

      for (index, instruction) in instructions.enumerated() {
        memory.advanced(by: index * MemoryLayout<UInt32>.size).storeBytes(
          of: instruction.littleEndian,
          as: UInt32.self
        )
      }

      let guestBase: UInt64 = 0x8000_0000
      let region = try DoryGuestMemoryRegion(
        id: 1,
        range: DoryGuestAddressRange(base: guestBase, byteCount: pageSize),
        pageSize: pageSize,
        permissions: [.read, .write, .execute],
        ownership: .executionEngine,
        mappingGeneration: 1,
        dirtyTracking: .disabled
      )
      try engine.mapMemory(
        try DoryGuestMemoryMapping(
          region: region,
          hostAddress: memory,
          hostByteCount: pageSize
        )
      )
      let vcpu = try engine.createVCPU(
        id: DoryVCPUIdentifier(0),
        initialState: DoryARM64ArchitecturalState.reset(programCounter: guestBase)
      )
      createdVCPU = vcpu
      try body(NativeHVArm64EngineProgram(engine: engine, vcpu: vcpu))
      try engine.destroyVCPU(vcpu)
      createdVCPU = nil
      try engine.close()
    }

    func capturedProgramCounter() throws -> UInt64 {
      let requested = try DorySnapshotBarrierProgress(
        snapshotGeneration: 1,
        executionGeneration: 1
      )
      let quiesced = try requested.advanced(to: .executionQuiesced)
      try engine.pause(vcpu, at: quiesced)
      let sealed = try quiesced.advanced(to: .memorySealed)
      try engine.pause(vcpu, at: sealed)
      return try engine.captureState(of: vcpu).state.programCounter
    }
  }
#endif
