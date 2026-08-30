#if arch(arm64)
  import Darwin
  import DoryExecutionContracts
  import Hypervisor

  private enum DoryNativeHVArm64MinimalHarnessError: Error {
    case unexpectedRegister(UInt64)
  }

  @available(macOS 15.0, *)
  public enum DoryNativeHVArm64MinimalHarness {
    public static let counterLoopIterations: UInt64 = 10_000_000

    /// Executes the smoke program with the same architectural reset state and Hypervisor calls as
    /// the contract engine, while deliberately omitting its validation, ownership, and locking.
    public static func run() throws -> UInt64 {
      try run(
        program: [0xd280_0540, 0xd400_0002],
        expectedHypercallNumber: 42,
        expectedArguments: Array(repeating: 0, count: 7)
      )
    }

    /// Executes 10,000,000 guest counter-loop iterations before the same hypercall exit. This is
    /// the fixed Phase 0A sustained-vCPU calibration workload, not a configurable product route.
    public static func runCounterLoop() throws -> UInt64 {
      try run(
        program: [
          0xd292_d000,  // mov x0, #0x9680
          0xf2a0_1300,  // movk x0, #0x98, lsl #16 => 10,000,000
          0xd280_0001,  // mov x1, #0
          0x9100_0421,  // add x1, x1, #1
          0xf100_0400,  // subs x0, x0, #1
          0x54ff_ffc1,  // b.ne -8
          0xaa01_03e0,  // mov x0, x1
          0xd400_0002,  // hvc #0
        ],
        expectedHypercallNumber: counterLoopIterations,
        expectedArguments: [counterLoopIterations] + Array(repeating: 0, count: 6)
      )
    }

    private static func run(
      program: [UInt32],
      expectedHypercallNumber: UInt64,
      expectedArguments: [UInt64]
    ) throws -> UInt64 {
      precondition(
        !program.isEmpty && program.count * MemoryLayout<UInt32>.size <= Int(getpagesize())
      )
      precondition(expectedArguments.count == 7)
      let pageSize = Int(getpagesize())
      let guestBase: UInt64 = 0x8000_0000
      let memory = UnsafeMutableRawPointer.allocate(byteCount: pageSize, alignment: pageSize)
      memory.initializeMemory(as: UInt8.self, repeating: 0, count: pageSize)
      for (index, instruction) in program.enumerated() {
        memory.advanced(by: index * MemoryLayout<UInt32>.size).storeBytes(
          of: instruction.littleEndian,
          as: UInt32.self
        )
      }
      defer { memory.deallocate() }

      try doryNativeHVCheck(hv_vm_create(nil), "hv_vm_create")
      var vmCreated = true
      defer { if vmCreated { _ = hv_vm_destroy() } }

      let flags = hv_memory_flags_t(HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC)
      try doryNativeHVCheck(hv_vm_map(memory, guestBase, pageSize, flags), "hv_vm_map")
      var memoryMapped = true
      defer { if memoryMapped { _ = hv_vm_unmap(guestBase, pageSize) } }

      var vcpu: hv_vcpu_t = 0
      var exitPointer: UnsafeMutablePointer<hv_vcpu_exit_t>?
      try doryNativeHVCheck(hv_vcpu_create(&vcpu, &exitPointer, nil), "hv_vcpu_create")
      var vcpuCreated = true
      defer { if vcpuCreated { _ = hv_vcpu_destroy(vcpu) } }
      guard let exitPointer else {
        throw DoryNativeHVArm64Error.hypervisorFailure(
          call: "hv_vcpu_create(exit)",
          code: 0
        )
      }

      try DoryARM64HypervisorRegisterBank.apply(
        DoryARM64ArchitecturalState.reset(programCounter: guestBase),
        to: vcpu
      )
      try doryNativeHVCheck(hv_vcpu_run(vcpu), "hv_vcpu_run")
      let exceptionClass = exitPointer.pointee.exception.syndrome >> 26
      guard
        exitPointer.pointee.reason == HV_EXIT_REASON_EXCEPTION,
        exceptionClass == 0x16 || exceptionClass == 0x17
      else {
        throw DoryNativeHVArm64Error.unexpectedExitReason(exitPointer.pointee.reason.rawValue)
      }
      let number = try DoryARM64HypervisorRegisterBank.readGeneral(vcpu, index: 0)
      guard number == expectedHypercallNumber else {
        throw DoryNativeHVArm64MinimalHarnessError.unexpectedRegister(number)
      }
      // Match the execution contract's hypercall exit materialization exactly: X0 is the call
      // number and X1...X7 are captured arguments even when this smoke workload leaves them zero.
      for index in 1...7 {
        let argument = try DoryARM64HypervisorRegisterBank.readGeneral(vcpu, index: index)
        guard argument == expectedArguments[index - 1] else {
          throw DoryNativeHVArm64MinimalHarnessError.unexpectedRegister(argument)
        }
      }
      try DoryARM64HypervisorRegisterBank.writeGeneral(vcpu, index: 0, value: UInt64.max)

      try doryNativeHVCheck(hv_vcpu_destroy(vcpu), "hv_vcpu_destroy")
      vcpuCreated = false
      try doryNativeHVCheck(hv_vm_unmap(guestBase, pageSize), "hv_vm_unmap")
      memoryMapped = false
      try doryNativeHVCheck(hv_vm_destroy(), "hv_vm_destroy")
      vmCreated = false
      return number
    }
  }
#endif
