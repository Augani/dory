#if arch(arm64)
  import Darwin
  import DoryExecutionContracts

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
  }
#endif
