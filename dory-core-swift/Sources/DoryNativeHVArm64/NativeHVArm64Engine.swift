#if arch(arm64)
  import Darwin
  import DoryExecutionContracts
  import Foundation
  import Hypervisor

  @available(macOS 15.0, *)
  public final class DoryNativeHVArm64Engine: DoryCPUExecutionEngine, @unchecked Sendable {
    public typealias ArchitecturalState = DoryARM64ArchitecturalState

    public let architecture = DoryExecutionArchitecture.arm64
    public let executionGeneration: UInt64

    private final class VCPURecord: @unchecked Sendable {
      let id: DoryVCPUIdentifier
      let handle: hv_vcpu_t
      let exit: UnsafeMutablePointer<hv_vcpu_exit_t>
      let ownerThread: UInt64
      var nextExitSequence: UInt64 = 1
      var pendingExit: PendingExit?
      var injectedInterrupt: DoryArchitecturalInterrupt?
      var pausedAt: DorySnapshotBarrierProgress?
      var isRunning = false
      var deadlineWatchGeneration: UInt64 = 1
      var deadlineWatchSource: DispatchSourceTimer?

      init(
        id: DoryVCPUIdentifier,
        handle: hv_vcpu_t,
        exit: UnsafeMutablePointer<hv_vcpu_exit_t>,
        ownerThread: UInt64
      ) {
        self.id = id
        self.handle = handle
        self.exit = exit
        self.ownerThread = ownerThread
      }
    }

    private enum PendingExit {
      case memory(
        token: DoryExecutionResumeToken,
        access: DoryArchitecturalMemoryAccess,
        registerIndex: Int,
        signExtend: Bool,
        sixtyFourBit: Bool
      )
      case hypercall(token: DoryExecutionResumeToken, advanceProgramCounter: Bool)

      var token: DoryExecutionResumeToken {
        switch self {
        case .memory(let token, _, _, _, _), .hypercall(let token, _): token
        }
      }
    }

    private struct MemoryRecord: @unchecked Sendable {
      let mapping: DoryGuestMemoryMapping
    }

    private let lock = NSLock()
    private let deadlineQueue = DispatchQueue(label: "dev.dory.native-hv.deadline")
    private var vcpus: [DoryVCPUIdentifier: VCPURecord] = [:]
    private var creatingVCPUs: Set<DoryVCPUIdentifier> = []
    private var mappings: [UInt32: MemoryRecord] = [:]
    private var cancellation: DoryExecutionCancellationRequest?
    private var isClosed = false
    private var deadlineCancellationGeneration: UInt64 = 1

    public init(executionGeneration: UInt64) throws {
      guard executionGeneration > 0 else {
        throw DoryNativeHVArm64Error.invalidExecutionGeneration(executionGeneration)
      }
      self.executionGeneration = executionGeneration
      try doryNativeHVCheck(hv_vm_create(nil), "hv_vm_create")
    }

    deinit {
      lock.lock()
      let canDestroy = !isClosed && vcpus.isEmpty
      lock.unlock()
      if canDestroy { _ = hv_vm_destroy() }
    }

    public func close() throws {
      lock.lock()
      defer { lock.unlock() }
      guard !isClosed else { return }
      let liveVCPUs = Set(vcpus.keys).union(creatingVCPUs).sorted()
      guard liveVCPUs.isEmpty else {
        throw DoryNativeHVArm64Error.engineStillOwnsVCPUs(liveVCPUs)
      }
      // Serialize closing with reservation, mapping and teardown. Retain only mappings
      // that still exist if an HV operation fails so a later close can safely retry.
      for (id, record) in Array(mappings) {
        let region = record.mapping.region
        let size = try hostSize(region.range.byteCount)
        try doryNativeHVCheck(hv_vm_unmap(region.range.base.rawValue, size), "hv_vm_unmap")
        mappings.removeValue(forKey: id)
      }
      try doryNativeHVCheck(hv_vm_destroy(), "hv_vm_destroy")
      isClosed = true
    }

    public func createVCPU(
      id: DoryVCPUIdentifier,
      initialState: DoryARM64ArchitecturalState
    ) throws -> DoryVCPU {
      try requireOpen()
      lock.lock()
      guard !isClosed else {
        lock.unlock()
        throw DoryNativeHVArm64Error.engineClosed
      }
      let exists = vcpus[id] != nil || creatingVCPUs.contains(id)
      if !exists { creatingVCPUs.insert(id) }
      lock.unlock()
      guard !exists else { throw DoryNativeHVArm64Error.vcpuAlreadyExists(id) }
      var creationCommitted = false
      defer {
        if !creationCommitted {
          lock.lock()
          creatingVCPUs.remove(id)
          lock.unlock()
        }
      }

      var handle: hv_vcpu_t = 0
      var exit: UnsafeMutablePointer<hv_vcpu_exit_t>?
      try doryNativeHVCheck(hv_vcpu_create(&handle, &exit, nil), "hv_vcpu_create")
      guard let exit else {
        _ = hv_vcpu_destroy(handle)
        throw DoryNativeHVArm64Error.hypervisorFailure(call: "hv_vcpu_create(exit)", code: 0)
      }
      do {
        try DoryARM64HypervisorRegisterBank.apply(initialState, to: handle)
        try sanitizeUnimplementedDebugAndPMUIdentity(handle: handle)
      } catch {
        _ = hv_vcpu_destroy(handle)
        throw error
      }
      let record = VCPURecord(
        id: id,
        handle: handle,
        exit: exit,
        ownerThread: currentThreadID()
      )
      lock.lock()
      creatingVCPUs.remove(id)
      vcpus[id] = record
      lock.unlock()
      creationCommitted = true
      return DoryVCPU(id: id, architecture: .arm64)
    }

    public func destroyVCPU(_ vcpu: DoryVCPU) throws {
      guard vcpu.architecture == .arm64 else {
        throw DoryNativeHVArm64Error.wrongVCPUArchitecture(vcpu.architecture)
      }
      try requireOpen()
      lock.lock()
      guard let record = vcpus[vcpu.id] else {
        lock.unlock()
        throw DoryNativeHVArm64Error.unknownVCPU(vcpu.id)
      }
      let actualThread = currentThreadID()
      guard actualThread == record.ownerThread else {
        lock.unlock()
        throw DoryNativeHVArm64Error.wrongOwnerThread(
          vcpu: vcpu.id,
          expected: record.ownerThread,
          actual: actualThread
        )
      }
      guard !record.isRunning else {
        lock.unlock()
        throw DoryNativeHVArm64Error.vcpuStillRunning(vcpu.id)
      }
      guard record.pendingExit == nil else {
        lock.unlock()
        throw DoryNativeHVArm64Error.pendingExitMustBeCompleted(vcpu.id)
      }
      record.deadlineWatchSource?.cancel()
      record.deadlineWatchSource = nil
      // Pin the handle table through destruction: close must still see this CPU,
      // cancellation must not target a destroyed handle, and failure must be retryable.
      defer { lock.unlock() }
      try doryNativeHVCheck(hv_vcpu_destroy(record.handle), "hv_vcpu_destroy")
      vcpus.removeValue(forKey: vcpu.id)
    }

    public func reset(_ vcpu: DoryVCPU, to state: DoryARM64ArchitecturalState) throws {
      let record = try ownedRecord(for: vcpu)
      guard record.pendingExit == nil else {
        throw DoryNativeHVArm64Error.pendingExitMustBeCompleted(vcpu.id)
      }
      try DoryARM64HypervisorRegisterBank.apply(state, to: record.handle)
      record.injectedInterrupt = nil
      record.pausedAt = nil
    }

    public func mapMemory(_ mapping: DoryGuestMemoryMapping) throws {
      try requireOpen()
      let size = try hostSize(mapping.region.range.byteCount)
      lock.lock()
      defer { lock.unlock() }
      guard !isClosed else { throw DoryNativeHVArm64Error.engineClosed }
      let duplicate = mappings[mapping.region.id] != nil
      let overlap = mappings.values.contains {
        $0.mapping.region.range.overlaps(mapping.region.range)
      }
      guard !duplicate else {
        throw DoryNativeHVArm64Error.memoryRegionAlreadyMapped(mapping.region.id)
      }
      guard !overlap else { throw DoryNativeHVArm64Error.memoryRangeOverlap(mapping.region.id) }

      try doryNativeHVCheck(
        hv_vm_map(
          mapping.hostAddress,
          mapping.region.range.base.rawValue,
          size,
          memoryFlags(mapping.region.permissions)
        ),
        "hv_vm_map"
      )
      mappings[mapping.region.id] = MemoryRecord(mapping: mapping)
    }

    public func unmapMemory(
      _ range: DoryGuestAddressRange,
      mappingGeneration: UInt64
    ) throws {
      try requireOpen()
      lock.lock()
      defer { lock.unlock() }
      guard !isClosed else { throw DoryNativeHVArm64Error.engineClosed }
      let match = mappings.first { $0.value.mapping.region.range == range }
      guard let (id, record) = match else {
        throw DoryNativeHVArm64Error.memoryMappingNotFound
      }
      guard record.mapping.region.mappingGeneration == mappingGeneration else {
        throw DoryNativeHVArm64Error.memoryGenerationMismatch(
          expected: record.mapping.region.mappingGeneration,
          actual: mappingGeneration
        )
      }
      let size = try hostSize(range.byteCount)
      try doryNativeHVCheck(hv_vm_unmap(range.base.rawValue, size), "hv_vm_unmap")
      mappings.removeValue(forKey: id)
    }

    public func inject(_ interrupt: DoryArchitecturalInterrupt, into vcpu: DoryVCPU) throws {
      guard interrupt.architecture == .arm64 else {
        throw DoryExecutionContractError.architectureMismatch(
          expected: .arm64,
          actual: interrupt.architecture
        )
      }
      let record = try ownedRecord(for: vcpu)
      try doryNativeHVCheck(
        hv_vcpu_set_pending_interrupt(record.handle, HV_INTERRUPT_TYPE_IRQ, true),
        "hv_vcpu_set_pending_interrupt(IRQ)"
      )
      record.injectedInterrupt = interrupt
    }

    public func acknowledgeInterrupt(
      on vcpu: DoryVCPU
    ) throws -> DoryInterruptAcknowledgement? {
      let record = try ownedRecord(for: vcpu)
      guard let interrupt = record.injectedInterrupt else { return nil }
      var pending = false
      try doryNativeHVCheck(
        hv_vcpu_get_pending_interrupt(record.handle, HV_INTERRUPT_TYPE_IRQ, &pending),
        "hv_vcpu_get_pending_interrupt(IRQ)"
      )
      guard !pending else { return nil }
      record.injectedInterrupt = nil
      return DoryInterruptAcknowledgement(vcpu: vcpu.id, interrupt: interrupt)
    }

    public func run(
      _ vcpu: DoryVCPU,
      until deadline: DoryVirtualDeadline?
    ) throws -> DoryCPUExit {
      let record = try ownedRecord(for: vcpu)
      guard record.pausedAt == nil else { throw DoryNativeHVArm64Error.vcpuPaused(vcpu.id) }
      guard record.pendingExit == nil else {
        throw DoryNativeHVArm64Error.pendingExitMustBeCompleted(vcpu.id)
      }

      let hostNow = DoryNativeHVArm64HostClock.nowTicks()
      if let deadline, DoryNativeHVArm64HostClock.hasExpired(deadline, at: hostNow) {
        return try deadlineExceededExit(vcpu: vcpu.id)
      }

      lock.lock()
      guard !record.isRunning else {
        lock.unlock()
        throw DoryNativeHVArm64Error.vcpuStillRunning(vcpu.id)
      }
      record.isRunning = true
      lock.unlock()
      defer {
        lock.lock()
        record.isRunning = false
        lock.unlock()
        disarmDeadlineWatch(record)
      }
      if let deadline {
        armDeadlineWatch(deadline: deadline, record: record)
      }

      while true {
        if let deadline,
          DoryNativeHVArm64HostClock.hasExpired(
            deadline,
            at: DoryNativeHVArm64HostClock.nowTicks()
          )
        {
          return try deadlineExceededExit(vcpu: vcpu.id)
        }

        try doryNativeHVCheck(hv_vcpu_run(record.handle), "hv_vcpu_run")
        let exit = record.exit.pointee
        switch exit.reason {
        case HV_EXIT_REASON_CANCELED:
          if let cancellation = cancellationRequest(),
            cancellation.applies(to: executionGeneration)
          {
            return try DoryCPUExit(
              vcpu: vcpu.id,
              retiredInstructions: 0,
              reason: .cancelled(cancellation)
            )
          }
          if let deadline,
            DoryNativeHVArm64HostClock.hasExpired(
              deadline,
              at: DoryNativeHVArm64HostClock.nowTicks()
            )
          {
            return try deadlineExceededExit(vcpu: vcpu.id)
          }
          if deadline != nil {
            // Consume an early or stale hv_vcpus_exit and keep running until a
            // real guest exit or the deadline actually expires.
            continue
          }
          return try DoryCPUExit(
            vcpu: vcpu.id,
            retiredInstructions: 0,
            reason: .waitingForInterrupt
          )
        case HV_EXIT_REASON_VTIMER_ACTIVATED:
          try doryNativeHVCheck(
            hv_vcpu_set_vtimer_mask(record.handle, false),
            "hv_vcpu_set_vtimer_mask"
          )
        case HV_EXIT_REASON_EXCEPTION:
          return try decodeException(
            syndrome: exit.exception.syndrome,
            virtualAddress: exit.exception.virtual_address,
            physicalAddress: exit.exception.physical_address,
            record: record
          )
        default:
          throw DoryNativeHVArm64Error.unexpectedExitReason(exit.reason.rawValue)
        }
      }
    }

    public func complete(
      _ token: DoryExecutionResumeToken,
      with response: DoryCPUExitResponse
    ) throws {
      let vcpu = DoryVCPU(id: token.vcpu, architecture: .arm64)
      let record = try ownedRecord(for: vcpu)
      guard let pending = record.pendingExit else {
        throw DoryNativeHVArm64Error.noPendingExit(token)
      }
      guard pending.token == token else {
        throw DoryNativeHVArm64Error.staleResumeToken(expected: pending.token, actual: token)
      }

      switch (pending, response) {
      case (.memory(_, let access, _, _, _), .completedWrite) where access.direction == .write:
        try DoryARM64HypervisorRegisterBank.advanceProgramCounter(record.handle)
      case (
        .memory(_, let access, let registerIndex, let signExtend, let sixtyFourBit),
        .readValue(let bytes)
      ) where access.direction == .read && bytes.count == Int(access.widthBytes):
        var value: UInt64 = 0
        for (index, byte) in bytes.enumerated() {
          value |= UInt64(byte) << UInt64(index * 8)
        }
        value = extendRead(
          value,
          widthBytes: access.widthBytes,
          signExtend: signExtend,
          sixtyFourBit: sixtyFourBit
        )
        if registerIndex != 31 {
          try DoryARM64HypervisorRegisterBank.writeGeneral(
            record.handle,
            index: registerIndex,
            value: value
          )
        }
        try DoryARM64HypervisorRegisterBank.advanceProgramCounter(record.handle)
      case (.hypercall(_, let advance), .hypercallResult(let values)) where values.count <= 8:
        for (index, value) in values.enumerated() {
          try DoryARM64HypervisorRegisterBank.writeGeneral(
            record.handle, index: index, value: value)
        }
        if advance { try DoryARM64HypervisorRegisterBank.advanceProgramCounter(record.handle) }
      default:
        throw DoryNativeHVArm64Error.invalidExitResponse
      }
      record.pendingExit = nil
    }

    public func pause(_ vcpu: DoryVCPU, at barrier: DorySnapshotBarrierProgress) throws {
      let record = try ownedRecord(for: vcpu)
      guard barrier.executionGeneration == executionGeneration else {
        throw DoryNativeHVArm64Error.invalidExecutionGeneration(barrier.executionGeneration)
      }
      guard record.pendingExit == nil else {
        throw DoryNativeHVArm64Error.pendingExitMustBeCompleted(vcpu.id)
      }
      if let prior = record.pausedAt,
        prior.snapshotGeneration != barrier.snapshotGeneration
      {
        throw DoryNativeHVArm64Error.snapshotGenerationMismatch(
          expected: prior.snapshotGeneration,
          actual: barrier.snapshotGeneration
        )
      }
      record.pausedAt = barrier
    }

    public func resume(_ vcpu: DoryVCPU, after barrier: DorySnapshotBarrierProgress) throws {
      let record = try ownedRecord(for: vcpu)
      guard let prior = record.pausedAt else {
        throw DoryNativeHVArm64Error.vcpuNotPaused(vcpu.id)
      }
      guard prior.snapshotGeneration == barrier.snapshotGeneration else {
        throw DoryNativeHVArm64Error.snapshotGenerationMismatch(
          expected: prior.snapshotGeneration,
          actual: barrier.snapshotGeneration
        )
      }
      guard barrier.phase == .released else {
        throw DoryExecutionContractError.invalidBarrierTransition(
          from: prior.phase,
          to: barrier.phase
        )
      }
      record.pausedAt = nil
    }

    public func cancel(_ request: DoryExecutionCancellationRequest) throws {
      guard request.executionGeneration == executionGeneration else {
        throw DoryNativeHVArm64Error.invalidExecutionGeneration(request.executionGeneration)
      }
      lock.lock()
      cancellation = request
      var handles = vcpus.values.map(\.handle)
      // Issue hv_vcpus_exit while the handle table is still pinned. destroyVCPU
      // unpublishes the handle under this lock, so a teardown cannot destroy a
      // vCPU that this stop pass still holds.
      if !handles.isEmpty {
        let status = hv_vcpus_exit(&handles, UInt32(handles.count))
        lock.unlock()
        try doryNativeHVCheck(status, "hv_vcpus_exit")
        return
      }
      lock.unlock()
    }

    public func captureState(
      of vcpu: DoryVCPU
    ) throws -> DoryVCPUArchitecturalState<DoryARM64ArchitecturalState> {
      let record = try ownedRecord(for: vcpu)
      guard let barrier = record.pausedAt else {
        throw DoryNativeHVArm64Error.vcpuNotPaused(vcpu.id)
      }
      guard barrier.phase == .memorySealed || barrier.phase == .architecturalStateCaptured else {
        throw DoryExecutionContractError.invalidBarrierTransition(
          from: barrier.phase,
          to: .architecturalStateCaptured
        )
      }
      return DoryVCPUArchitecturalState(
        vcpu: vcpu.id,
        state: try DoryARM64HypervisorRegisterBank.capture(from: record.handle)
      )
    }

    public func dirtyPages(
      in region: DoryGuestMemoryRegion,
      since epoch: UInt64
    ) throws -> DoryDirtyPageSet {
      guard let configuredEpoch = region.dirtyTracking.epoch else {
        throw DoryNativeHVArm64Error.dirtyTrackingDisabled(region.id)
      }
      guard configuredEpoch == epoch else {
        throw DoryNativeHVArm64Error.dirtyEpochMismatch(
          expected: configuredEpoch,
          actual: epoch
        )
      }
      // Hypervisor.framework exposes no dirty bitmap. Version one is deliberately conservative:
      // every mapped page is reported dirty, which preserves snapshot correctness while the machine
      // layer's write-protect tracker is completed and benchmarked.
      let pageCount = region.range.byteCount / region.pageSize
      let offsets = (0..<pageCount).map { $0 * region.pageSize }
      return try DoryDirtyPageSet(region: region, dirtyEpoch: epoch, pageOffsets: offsets)
    }

    private func decodeException(
      syndrome: UInt64,
      virtualAddress: UInt64,
      physicalAddress: UInt64,
      record: VCPURecord
    ) throws -> DoryCPUExit {
      let exceptionClass = syndrome >> 26
      switch exceptionClass {
      case 0x24:
        return try decodeDataAbort(
          syndrome: syndrome,
          physicalAddress: physicalAddress,
          record: record
        )
      case 0x20:
        return try DoryCPUExit(
          vcpu: record.id,
          retiredInstructions: 0,
          reason: .fault(
            DoryArchitecturalFault(
              kind: .instructionAbort,
              programCounter: try DoryARM64HypervisorRegisterBank.readProgramCounter(record.handle),
              address: DoryGuestPhysicalAddress(physicalAddress),
              access: .read,
              architectureCode: syndrome
            ))
        )
      case 0x16, 0x17:
        let token = try nextToken(record)
        let number = try DoryARM64HypervisorRegisterBank.readGeneral(record.handle, index: 0)
        let arguments = try (1...7).map {
          try DoryARM64HypervisorRegisterBank.readGeneral(record.handle, index: $0)
        }
        record.pendingExit = .hypercall(
          token: token,
          advanceProgramCounter: exceptionClass == 0x17
        )
        return try DoryCPUExit(
          vcpu: record.id,
          retiredInstructions: 0,
          reason: .hypercall(number: number, arguments: arguments, resume: token)
        )
      case 0x3c:
        return try DoryCPUExit(
          vcpu: record.id,
          retiredInstructions: 0,
          reason: .breakpoint(
            programCounter: try DoryARM64HypervisorRegisterBank.readProgramCounter(record.handle)
          )
        )
      default:
        return try DoryCPUExit(
          vcpu: record.id,
          retiredInstructions: 0,
          reason: .fault(
            DoryArchitecturalFault(
              kind: .undefinedInstruction,
              programCounter: try DoryARM64HypervisorRegisterBank.readProgramCounter(record.handle),
              address: virtualAddress == 0 ? nil : DoryGuestPhysicalAddress(virtualAddress),
              architectureCode: syndrome
            ))
        )
      }
    }

    private func decodeDataAbort(
      syndrome: UInt64,
      physicalAddress: UInt64,
      record: VCPURecord
    ) throws -> DoryCPUExit {
      guard syndrome & (1 << 24) != 0 else {
        throw DoryNativeHVArm64Error.invalidDataAbortSyndrome(syndrome)
      }
      let width = UInt8(1 << ((syndrome >> 22) & 0b11))
      let registerIndex = Int((syndrome >> 16) & 0x1f)
      let signExtend = syndrome & (1 << 21) != 0
      let sixtyFourBit = syndrome & (1 << 15) != 0
      let direction =
        syndrome & (1 << 6) != 0
        ? DoryArchitecturalAccessDirection.write
        : .read
      let value: [UInt8]
      if direction == .write {
        let registerValue =
          registerIndex == 31
          ? 0
          : try DoryARM64HypervisorRegisterBank.readGeneral(
            record.handle,
            index: registerIndex
          )
        value = (0..<Int(width)).map {
          UInt8(truncatingIfNeeded: registerValue >> UInt64($0 * 8))
        }
      } else {
        value = []
      }
      let access = try DoryArchitecturalMemoryAccess(
        address: DoryGuestPhysicalAddress(physicalAddress),
        widthBytes: width,
        direction: direction,
        value: value
      )
      let token = try nextToken(record)
      record.pendingExit = .memory(
        token: token,
        access: access,
        registerIndex: registerIndex,
        signExtend: signExtend,
        sixtyFourBit: sixtyFourBit
      )
      return try DoryCPUExit(
        vcpu: record.id,
        retiredInstructions: 0,
        reason: .memoryMappedIO(access, resume: token)
      )
    }

    private func nextToken(_ record: VCPURecord) throws -> DoryExecutionResumeToken {
      let token = try DoryExecutionResumeToken(
        vcpu: record.id,
        executionGeneration: executionGeneration,
        sequence: record.nextExitSequence
      )
      record.nextExitSequence &+= 1
      if record.nextExitSequence == 0 { record.nextExitSequence = 1 }
      return token
    }

    private func ownedRecord(for vcpu: DoryVCPU) throws -> VCPURecord {
      guard vcpu.architecture == .arm64 else {
        throw DoryNativeHVArm64Error.wrongVCPUArchitecture(vcpu.architecture)
      }
      try requireOpen()
      lock.lock()
      let record = vcpus[vcpu.id]
      lock.unlock()
      guard let record else { throw DoryNativeHVArm64Error.unknownVCPU(vcpu.id) }
      let actualThread = currentThreadID()
      guard actualThread == record.ownerThread else {
        throw DoryNativeHVArm64Error.wrongOwnerThread(
          vcpu: vcpu.id,
          expected: record.ownerThread,
          actual: actualThread
        )
      }
      return record
    }

    private func requireOpen() throws {
      lock.lock()
      let closed = isClosed
      lock.unlock()
      if closed { throw DoryNativeHVArm64Error.engineClosed }
    }

    /// Match DoryHV `ARMGuestDebugPMUIdentity`: do not advertise debug/trace/PMU/SPE.
    private static let dfr0UnimplementedMask: UInt64 = UInt64.max

    func debugPMUIdentity(of vcpu: DoryVCPU) throws -> (dfr0: UInt64, dfr1: UInt64) {
      let record = try ownedRecord(for: vcpu)
      var dfr0: UInt64 = 0
      var dfr1: UInt64 = 0
      try doryNativeHVCheck(
        hv_vcpu_get_sys_reg(record.handle, HV_SYS_REG_ID_AA64DFR0_EL1, &dfr0),
        "hv_vcpu_get_sys_reg(ID_AA64DFR0_EL1)"
      )
      try doryNativeHVCheck(
        hv_vcpu_get_sys_reg(record.handle, HV_SYS_REG_ID_AA64DFR1_EL1, &dfr1),
        "hv_vcpu_get_sys_reg(ID_AA64DFR1_EL1)"
      )
      return (dfr0, dfr1)
    }

    private func sanitizeUnimplementedDebugAndPMUIdentity(handle: hv_vcpu_t) throws {
      var host0: UInt64 = 0
      var host1: UInt64 = 0
      try doryNativeHVCheck(
        hv_vcpu_get_sys_reg(handle, HV_SYS_REG_ID_AA64DFR0_EL1, &host0),
        "hv_vcpu_get_sys_reg(ID_AA64DFR0_EL1)"
      )
      try doryNativeHVCheck(
        hv_vcpu_get_sys_reg(handle, HV_SYS_REG_ID_AA64DFR1_EL1, &host1),
        "hv_vcpu_get_sys_reg(ID_AA64DFR1_EL1)"
      )
      let dfr0 = host0 & ~Self.dfr0UnimplementedMask
      try doryNativeHVCheck(
        hv_vcpu_set_sys_reg(handle, HV_SYS_REG_ID_AA64DFR0_EL1, dfr0),
        "hv_vcpu_set_sys_reg(ID_AA64DFR0_EL1)"
      )
      try doryNativeHVCheck(
        hv_vcpu_set_sys_reg(handle, HV_SYS_REG_ID_AA64DFR1_EL1, 0),
        "hv_vcpu_set_sys_reg(ID_AA64DFR1_EL1)"
      )
      var observed0: UInt64 = 0
      var observed1: UInt64 = 0
      try doryNativeHVCheck(
        hv_vcpu_get_sys_reg(handle, HV_SYS_REG_ID_AA64DFR0_EL1, &observed0),
        "hv_vcpu_get_sys_reg(ID_AA64DFR0_EL1)"
      )
      try doryNativeHVCheck(
        hv_vcpu_get_sys_reg(handle, HV_SYS_REG_ID_AA64DFR1_EL1, &observed1),
        "hv_vcpu_get_sys_reg(ID_AA64DFR1_EL1)"
      )
      guard (observed0 & Self.dfr0UnimplementedMask) == 0, observed1 == 0 else {
        throw DoryNativeHVArm64Error.debugPMUIdentityRejected(dfr0: observed0, dfr1: observed1)
      }
    }

    private func cancellationRequest() -> DoryExecutionCancellationRequest? {
      lock.lock()
      defer { lock.unlock() }
      return cancellation
    }

    private func deadlineExceededExit(vcpu: DoryVCPUIdentifier) throws -> DoryCPUExit {
      let request = try DoryExecutionCancellationRequest(
        executionGeneration: executionGeneration,
        cancellationGeneration: nextDeadlineCancellationGeneration(),
        reason: .deadlineExceeded
      )
      return try DoryCPUExit(
        vcpu: vcpu,
        retiredInstructions: 0,
        reason: .cancelled(request)
      )
    }

    private func nextDeadlineCancellationGeneration() -> UInt64 {
      lock.lock()
      defer { lock.unlock() }
      let generation = deadlineCancellationGeneration
      deadlineCancellationGeneration &+= 1
      if deadlineCancellationGeneration == 0 { deadlineCancellationGeneration = 1 }
      return generation
    }

    private func armDeadlineWatch(deadline: DoryVirtualDeadline, record: VCPURecord) {
      let remaining = DoryNativeHVArm64HostClock.nanosecondsUntil(
        deadline,
        from: DoryNativeHVArm64HostClock.nowTicks()
      )
      lock.lock()
      record.deadlineWatchGeneration &+= 1
      if record.deadlineWatchGeneration == 0 { record.deadlineWatchGeneration = 1 }
      let generation = record.deadlineWatchGeneration
      record.deadlineWatchSource?.cancel()
      let source = DispatchSource.makeTimerSource(queue: deadlineQueue)
      record.deadlineWatchSource = source
      lock.unlock()

      source.setEventHandler { [weak self] in
        self?.fireDeadlineWatch(deadline: deadline, generation: generation, record: record)
      }
      // Bound the dispatch interval (including saturated deadlines) and keep watching
      // after a premature/spurious wakeup. The run loop owns the actual clock check.
      let interval = Int(min(remaining, UInt64(Int.max / 2)))
      source.schedule(
        deadline: .now() + .nanoseconds(interval),
        repeating: .milliseconds(1),
        leeway: .microseconds(50)
      )
      source.resume()
    }

    private func fireDeadlineWatch(deadline: DoryVirtualDeadline, generation: UInt64, record: VCPURecord) {
      guard DoryNativeHVArm64HostClock.hasExpired(deadline, at: DoryNativeHVArm64HostClock.nowTicks()) else { return }
      lock.lock()
      defer { lock.unlock() }
      guard record.isRunning,
        record.deadlineWatchGeneration == generation,
        record.deadlineWatchSource != nil
      else {
        return
      }
      var handles = [record.handle]
      _ = hv_vcpus_exit(&handles, 1)
    }

    private func disarmDeadlineWatch(_ record: VCPURecord) {
      lock.lock()
      record.deadlineWatchGeneration &+= 1
      if record.deadlineWatchGeneration == 0 { record.deadlineWatchGeneration = 1 }
      record.deadlineWatchSource?.cancel()
      record.deadlineWatchSource = nil
      lock.unlock()
    }

    private func hostSize(_ byteCount: UInt64) throws -> Int {
      guard byteCount <= UInt64(Int.max) else {
        throw DoryNativeHVArm64Error.memorySizeTooLarge(byteCount)
      }
      return Int(byteCount)
    }

    private func memoryFlags(
      _ permissions: [DoryGuestMemoryPermission]
    ) -> hv_memory_flags_t {
      var flags: UInt64 = 0
      for permission in permissions {
        switch permission {
        case .read: flags |= UInt64(HV_MEMORY_READ)
        case .write: flags |= UInt64(HV_MEMORY_WRITE)
        case .execute: flags |= UInt64(HV_MEMORY_EXEC)
        }
      }
      return hv_memory_flags_t(flags)
    }

    private func currentThreadID() -> UInt64 {
      var id: UInt64 = 0
      pthread_threadid_np(nil, &id)
      return id
    }

    private func extendRead(
      _ value: UInt64,
      widthBytes: UInt8,
      signExtend: Bool,
      sixtyFourBit: Bool
    ) -> UInt64 {
      let bitCount = UInt64(widthBytes) * 8
      var result = value
      if signExtend && bitCount < 64 {
        let signBit = UInt64(1) << (bitCount - 1)
        if result & signBit != 0 {
          result |= ~((UInt64(1) << bitCount) - 1)
        }
      }
      return sixtyFourBit ? result : result & 0xffff_ffff
    }
  }
#else
  import DoryExecutionContracts

  public enum DoryNativeHVArm64Engine {
    public static func unavailable() throws -> Never {
      throw DoryNativeHVArm64Error.unsupportedHostArchitecture
    }
  }
#endif
