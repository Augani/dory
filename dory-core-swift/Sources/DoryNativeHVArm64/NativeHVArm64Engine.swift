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
    private var vcpus: [DoryVCPUIdentifier: VCPURecord] = [:]
    private var creatingVCPUs: Set<DoryVCPUIdentifier> = []
    private var mappings: [UInt32: MemoryRecord] = [:]
    private var cancellation: DoryExecutionCancellationRequest?
    private var isClosed = false

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
      guard !isClosed else {
        lock.unlock()
        return
      }
      let liveVCPUs = Set(vcpus.keys).union(creatingVCPUs).sorted()
      guard liveVCPUs.isEmpty else {
        lock.unlock()
        throw DoryNativeHVArm64Error.engineStillOwnsVCPUs(liveVCPUs)
      }
      let mapped = mappings.values.map(\.mapping.region)
      lock.unlock()

      for region in mapped {
        let size = try hostSize(region.range.byteCount)
        try doryNativeHVCheck(
          hv_vm_unmap(region.range.base.rawValue, size),
          "hv_vm_unmap"
        )
      }
      try doryNativeHVCheck(hv_vm_destroy(), "hv_vm_destroy")
      lock.lock()
      mappings.removeAll()
      isClosed = true
      lock.unlock()
    }

    public func createVCPU(
      id: DoryVCPUIdentifier,
      initialState: DoryARM64ArchitecturalState
    ) throws -> DoryVCPU {
      try requireOpen()
      lock.lock()
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
      let record = try ownedRecord(for: vcpu)
      guard record.pendingExit == nil else {
        throw DoryNativeHVArm64Error.pendingExitMustBeCompleted(vcpu.id)
      }
      try doryNativeHVCheck(hv_vcpu_destroy(record.handle), "hv_vcpu_destroy")
      lock.lock()
      vcpus.removeValue(forKey: vcpu.id)
      lock.unlock()
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
      let duplicate = mappings[mapping.region.id] != nil
      let overlap = mappings.values.contains {
        $0.mapping.region.range.overlaps(mapping.region.range)
      }
      lock.unlock()
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
      lock.lock()
      mappings[mapping.region.id] = MemoryRecord(mapping: mapping)
      lock.unlock()
    }

    public func unmapMemory(
      _ range: DoryGuestAddressRange,
      mappingGeneration: UInt64
    ) throws {
      try requireOpen()
      lock.lock()
      let match = mappings.first { $0.value.mapping.region.range == range }
      lock.unlock()
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
      lock.lock()
      mappings.removeValue(forKey: id)
      lock.unlock()
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
      guard deadline == nil else { throw DoryNativeHVArm64Error.deadlineNotImplemented }
      let record = try ownedRecord(for: vcpu)
      guard record.pausedAt == nil else { throw DoryNativeHVArm64Error.vcpuPaused(vcpu.id) }
      guard record.pendingExit == nil else {
        throw DoryNativeHVArm64Error.pendingExitMustBeCompleted(vcpu.id)
      }

      while true {
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
      lock.unlock()
      guard !handles.isEmpty else { return }
      try doryNativeHVCheck(
        hv_vcpus_exit(&handles, UInt32(handles.count)),
        "hv_vcpus_exit"
      )
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

    private func cancellationRequest() -> DoryExecutionCancellationRequest? {
      lock.lock()
      defer { lock.unlock() }
      return cancellation
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
