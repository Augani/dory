#if arch(arm64)
  import Darwin
  import DoryExecutionContracts
  import Foundation

  public struct DoryNativeHVArm64SmokeReceipt: Codable, Sendable, Hashable {
    public let hypercallNumber: UInt64
    public let architecturalX0: UInt64
    public let programCounter: UInt64
    public let dirtyPageCount: Int

    public init(
      hypercallNumber: UInt64,
      architecturalX0: UInt64,
      programCounter: UInt64,
      dirtyPageCount: Int
    ) {
      self.hypercallNumber = hypercallNumber
      self.architecturalX0 = architecturalX0
      self.programCounter = programCounter
      self.dirtyPageCount = dirtyPageCount
    }
  }

  public struct DoryNativeHVArm64DeadlineReceipt: Codable, Sendable, Hashable {
    public let pastDeadlineReason: String
    public let pastDeadlineProgramCounter: UInt64
    public let farFutureHypercallNumber: UInt64
    public let spinDeadlineReason: String
    public let spinDeadlineElapsedNanoseconds: UInt64

    public init(
      pastDeadlineReason: String,
      pastDeadlineProgramCounter: UInt64,
      farFutureHypercallNumber: UInt64,
      spinDeadlineReason: String,
      spinDeadlineElapsedNanoseconds: UInt64
    ) {
      self.pastDeadlineReason = pastDeadlineReason
      self.pastDeadlineProgramCounter = pastDeadlineProgramCounter
      self.farFutureHypercallNumber = farFutureHypercallNumber
      self.spinDeadlineReason = spinDeadlineReason
      self.spinDeadlineElapsedNanoseconds = spinDeadlineElapsedNanoseconds
    }
  }

  public struct DoryNativeHVArm64FeatureIdentityReceipt: Codable, Sendable, Hashable {
    public let dfr0: UInt64
    public let dfr1: UInt64
    public let hidesDebugTracePMUAndSPE: Bool

    public init(dfr0: UInt64, dfr1: UInt64, hidesDebugTracePMUAndSPE: Bool) {
      self.dfr0 = dfr0
      self.dfr1 = dfr1
      self.hidesDebugTracePMUAndSPE = hidesDebugTracePMUAndSPE
    }
  }

  public struct DoryNativeHVArm64LifecycleReceipt: Codable, Sendable, Hashable {
    public let wrongThreadDestroy: String
    public let wrongThreadRun: String
    public let closeWhileLive: String
    public let destroyWithPendingExit: String
    public let cancelThenOwnerDestroy: String

    public init(
      wrongThreadDestroy: String,
      wrongThreadRun: String,
      closeWhileLive: String,
      destroyWithPendingExit: String,
      cancelThenOwnerDestroy: String
    ) {
      self.wrongThreadDestroy = wrongThreadDestroy
      self.wrongThreadRun = wrongThreadRun
      self.closeWhileLive = closeWhileLive
      self.destroyWithPendingExit = destroyWithPendingExit
      self.cancelThenOwnerDestroy = cancelThenOwnerDestroy
    }
  }

  private enum DeadlineContractError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
      switch self {
      case .failed(let message): "deadline contract: \(message)"
      }
    }
  }

  private enum LifecycleContractError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
      switch self {
      case .failed(let message): "lifecycle contract: \(message)"
      }
    }
  }

  @available(macOS 15.0, *)
  public enum DoryNativeHVArm64Smoke {
    /// Runs `mov x0, #42; hvc #0` through the contract-backed engine, completes the exit, captures a
    /// coherent architectural state, and tears every Hypervisor.framework authority down.
    public static func run() throws -> DoryNativeHVArm64SmokeReceipt {
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
        try? engine.close()
        memory.deallocate()
      }

      let guestBase: UInt64 = 0x8000_0000
      memory.storeBytes(of: UInt32(0xd280_0540).littleEndian, as: UInt32.self)
      memory.advanced(by: 4).storeBytes(
        of: UInt32(0xd400_0002).littleEndian,
        as: UInt32.self
      )
      let region = try DoryGuestMemoryRegion(
        id: 1,
        range: DoryGuestAddressRange(base: guestBase, byteCount: pageSize),
        pageSize: pageSize,
        permissions: [.read, .write, .execute],
        ownership: .executionEngine,
        mappingGeneration: 1,
        dirtyTracking: .epoch(1)
      )
      try engine.mapMemory(
        try DoryGuestMemoryMapping(
          region: region,
          hostAddress: memory,
          hostByteCount: pageSize
        ))

      let vcpu = try engine.createVCPU(
        id: DoryVCPUIdentifier(0),
        initialState: DoryARM64ArchitecturalState.reset(programCounter: guestBase)
      )
      createdVCPU = vcpu
      let exit = try engine.run(vcpu, until: nil)
      guard case .hypercall(let number, _, let token) = exit.reason else {
        throw DoryNativeHVArm64Error.unexpectedExitReason(UInt32.max)
      }
      try engine.complete(token, with: .hypercallResult([UInt64.max]))

      let requested = try DorySnapshotBarrierProgress(
        snapshotGeneration: 1,
        executionGeneration: 1
      )
      let quiesced = try requested.advanced(to: .executionQuiesced)
      try engine.pause(vcpu, at: quiesced)
      let memorySealed = try quiesced.advanced(to: .memorySealed)
      try engine.pause(vcpu, at: memorySealed)
      let captured = try engine.captureState(of: vcpu)
      let dirty = try engine.dirtyPages(in: region, since: 1)

      let stateCaptured = try memorySealed.advanced(to: .architecturalStateCaptured)
      try engine.pause(vcpu, at: stateCaptured)
      try engine.resume(vcpu, after: stateCaptured.advanced(to: .released))
      try engine.destroyVCPU(vcpu)
      createdVCPU = nil
      try engine.unmapMemory(region.range, mappingGeneration: 1)
      try engine.close()

      return DoryNativeHVArm64SmokeReceipt(
        hypercallNumber: number,
        architecturalX0: captured.state.generalRegisters[0],
        programCounter: captured.state.programCounter,
        dirtyPageCount: dirty.pageOffsets.count
      )
    }

    /// Proves `run(until:)` honors host-monotonic deadlines on the entitled smoke path.
    /// This is not production MachineManager/DoryHV qualification.
    public static func runDeadlineContract() throws -> DoryNativeHVArm64DeadlineReceipt {
      let past = try withProgram(spinLoop) { engine, vcpu in
        let now = DoryNativeHVArm64HostClock.nowTicks()
        let deadline = DoryVirtualDeadline(monotonicTicks: now == 0 ? 0 : now - 1)
        let exit = try engine.run(vcpu, until: deadline)
        guard case .cancelled(let request) = exit.reason, request.reason == .deadlineExceeded else {
          throw DeadlineContractError.failed("past deadline: \(String(describing: exit.reason))")
        }
        let requested = try DorySnapshotBarrierProgress(
          snapshotGeneration: 1,
          executionGeneration: 1
        )
        let quiesced = try requested.advanced(to: .executionQuiesced)
        try engine.pause(vcpu, at: quiesced)
        let sealed = try quiesced.advanced(to: .memorySealed)
        try engine.pause(vcpu, at: sealed)
        let pc = try engine.captureState(of: vcpu).state.programCounter
        return (request.reason.rawValue, pc)
      }
      guard past.1 == 0x8000_0000 else {
        throw DeadlineContractError.failed(
          "past deadline moved PC to 0x\(String(past.1, radix: 16))"
        )
      }

      let futureNumber = try withProgram(hypercallFortyTwo) { engine, vcpu in
        let deadline = DoryNativeHVArm64HostClock.deadline(nanosecondsFromNow: 60_000_000_000)
        let exit = try engine.run(vcpu, until: deadline)
        guard case .hypercall(let number, _, let token) = exit.reason else {
          throw DeadlineContractError.failed("far-future hypercall: \(String(describing: exit.reason))")
        }
        try engine.complete(token, with: .hypercallResult([UInt64.max]))
        return number
      }
      guard futureNumber == 42 else {
        throw DeadlineContractError.failed("far-future hypercall number \(futureNumber)")
      }

      let spin = try withProgram(spinLoop) { engine, vcpu in
        let deadline = DoryNativeHVArm64HostClock.deadline(nanosecondsFromNow: 50_000_000)
        let started = DoryNativeHVArm64HostClock.nowTicks()
        let exit = try engine.run(vcpu, until: deadline)
        let elapsed = DoryNativeHVArm64HostClock.nanosecondsUntil(
          DoryVirtualDeadline(monotonicTicks: DoryNativeHVArm64HostClock.nowTicks()),
          from: started
        )
        guard case .cancelled(let request) = exit.reason, request.reason == .deadlineExceeded else {
          throw DeadlineContractError.failed("spin deadline: \(String(describing: exit.reason))")
        }
        return (request.reason.rawValue, elapsed)
      }
      guard spin.1 < 2_000_000_000 else {
        throw DeadlineContractError.failed("spin deadline elapsed \(spin.1) ns")
      }

      return DoryNativeHVArm64DeadlineReceipt(
        pastDeadlineReason: past.0,
        pastDeadlineProgramCounter: past.1,
        farFutureHypercallNumber: futureNumber,
        spinDeadlineReason: spin.0,
        spinDeadlineElapsedNanoseconds: spin.1
      )
    }

    public static func runFeatureIdentity() throws -> DoryNativeHVArm64FeatureIdentityReceipt {
      try withProgram(hypercallFortyTwo) { engine, vcpu in
        let id = try engine.debugPMUIdentity(of: vcpu)
        let mask: UInt64 = UInt64.max
        let hidden = (id.dfr0 & mask) == 0 && id.dfr1 == 0
        guard hidden else {
          throw LifecycleContractError.failed(
            "ID_AA64DFR0/1 advertise debug/PMU dfr0=0x\(String(id.dfr0, radix: 16)) dfr1=0x\(String(id.dfr1, radix: 16))"
          )
        }
        return DoryNativeHVArm64FeatureIdentityReceipt(
          dfr0: id.dfr0, dfr1: id.dfr1, hidesDebugTracePMUAndSPE: hidden)
      }
    }

    /// Proves Hypervisor.framework create/run/destroy stay on one owner thread, cancel can
    /// arrive from another thread, and teardown never calls hv_vcpu_destroy on a live run.
    public static func runLifecycleContract() throws -> DoryNativeHVArm64LifecycleReceipt {
      let ownership = try withProgram(hypercallFortyTwo) { engine, vcpu in
        let wrongDestroy = offOwnerError { try engine.destroyVCPU(vcpu) }
        let wrongRun = offOwnerError { _ = try engine.run(vcpu, until: nil) }
        let closeWhileLive = errorName(
          caught { try engine.close() }
            ?? LifecycleContractError.failed("close succeeded while a vCPU was live")
        )
        let exit = try engine.run(vcpu, until: nil)
        guard case .hypercall(_, _, let token) = exit.reason else {
          throw LifecycleContractError.failed("expected hypercall, got \(exit.reason)")
        }
        let pendingDestroy = errorName(
          caught { try engine.destroyVCPU(vcpu) }
            ?? LifecycleContractError.failed("destroy succeeded with a pending exit")
        )
        try engine.complete(token, with: .hypercallResult([UInt64.max]))
        return (wrongDestroy, wrongRun, closeWhileLive, pendingDestroy)
      }

      guard ownership.0 == "wrongOwnerThread", ownership.1 == "wrongOwnerThread",
        ownership.2 == "engineStillOwnsVCPUs", ownership.3 == "pendingExitMustBeCompleted"
      else {
        throw LifecycleContractError.failed("unexpected lifecycle results: \(ownership)")
      }
      let cancelledThenDestroyed = try cancelRunningVCPUThenOwnerDestroy()
      return DoryNativeHVArm64LifecycleReceipt(
        wrongThreadDestroy: ownership.0,
        wrongThreadRun: ownership.1,
        closeWhileLive: ownership.2,
        destroyWithPendingExit: ownership.3,
        cancelThenOwnerDestroy: cancelledThenDestroyed
      )
    }

    private static func cancelRunningVCPUThenOwnerDestroy() throws -> String {
      let engine = try DoryNativeHVArm64Engine(executionGeneration: 1)
      let pageSize = UInt64(getpagesize())
      let owner = DispatchQueue(label: "dev.dory.native-hv.vcpu-owner")
      let finished = DispatchSemaphore(value: 0)
      let started = DispatchSemaphore(value: 0)
      let box = LifecycleBox()
      owner.async {
        defer { finished.signal() }
        let memory = UnsafeMutableRawPointer.allocate(
          byteCount: Int(pageSize),
          alignment: Int(pageSize)
        )
        memory.initializeMemory(as: UInt8.self, repeating: 0, count: Int(pageSize))
        memory.storeBytes(of: UInt32(0x1400_0000).littleEndian, as: UInt32.self)
        defer {
          if let vcpu = box.vcpu { try? engine.destroyVCPU(vcpu) }
          if (try? engine.close()) != nil { memory.deallocate() }
        }
        do {
          let region = try DoryGuestMemoryRegion(
            id: 1,
            range: DoryGuestAddressRange(base: 0x8000_0000, byteCount: pageSize),
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
            initialState: DoryARM64ArchitecturalState.reset(programCounter: 0x8000_0000)
          )
          box.vcpu = vcpu
          started.signal()
          let safety = DoryNativeHVArm64HostClock.deadline(nanosecondsFromNow: 2_000_000_000)
          let exit = try engine.run(vcpu, until: safety)
          box.exit = exit
          try engine.destroyVCPU(vcpu)
          box.vcpu = nil
          try engine.close()
        } catch {
          box.error = error
          started.signal()
        }
      }
      started.wait()
      let request = try DoryExecutionCancellationRequest(
        executionGeneration: 1,
        cancellationGeneration: 3,
        reason: .userRequested
      )
      do { try engine.cancel(request) }
      catch {
        finished.wait() // The owner's safety deadline still bounds the guest run.
        throw error
      }
      finished.wait()
      if let error = box.error {
        throw LifecycleContractError.failed("owner teardown: \(error)")
      }
      guard case .cancelled(let observed) = box.exit?.reason, observed == request else {
        throw LifecycleContractError.failed(
          "expected user cancel then owner destroy, got \(String(describing: box.exit?.reason))"
        )
      }
      return observed.reason.rawValue
    }

    private static func offOwnerError(_ body: @escaping @Sendable () throws -> Void) -> String {
      let box = LifecycleBox()
      let done = DispatchSemaphore(value: 0)
      DispatchQueue.global(qos: .userInitiated).async {
        box.error = caught(body)
        done.signal()
      }
      done.wait()
      return errorName(box.error ?? LifecycleContractError.failed("off-owner call succeeded"))
    }

    private static func caught(_ body: () throws -> Void) -> Error? {
      do {
        try body()
        return nil
      } catch {
        return error
      }
    }

    private static func errorName(_ error: Error) -> String {
      switch error as? DoryNativeHVArm64Error {
      case .wrongOwnerThread: "wrongOwnerThread"
      case .engineStillOwnsVCPUs: "engineStillOwnsVCPUs"
      case .pendingExitMustBeCompleted: "pendingExitMustBeCompleted"
      case .vcpuStillRunning: "vcpuStillRunning"
      default: String(describing: error)
      }
    }

    private static let hypercallFortyTwo: [UInt32] = [
      0xd280_0540,
      0xd400_0002,
    ]

    // Hypervisor.framework traps WFI (EC 0x01). A self-branch stays in hv_vcpu_run
    // until the host deadline watch calls hv_vcpus_exit.
    private static let spinLoop: [UInt32] = [
      0x1400_0000,  // b .
    ]

    private static func withProgram<T>(
      _ instructions: [UInt32],
      body: (DoryNativeHVArm64Engine, DoryVCPU) throws -> T
    ) throws -> T {
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
        // Never free backing memory if HV still owns a mapping after a failed teardown.
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
      let result = try body(engine, vcpu)
      try engine.destroyVCPU(vcpu)
      createdVCPU = nil
      try engine.close()
      return result
    }
  }

  private final class LifecycleBox: @unchecked Sendable {
    var vcpu: DoryVCPU?
    var exit: DoryCPUExit?
    var error: Error?
  }
#endif
