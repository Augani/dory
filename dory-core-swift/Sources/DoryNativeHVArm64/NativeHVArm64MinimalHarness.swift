#if arch(arm64)
  import Darwin
  import DoryExecutionContracts
  import Hypervisor

  private enum DoryNativeHVArm64MinimalHarnessError: Error {
    case unexpectedRegister(UInt64)
  }

  @available(macOS 15.0, *)
  public enum DoryNativeHVArm64MinimalHarness {
    /// Executes the smoke program with the same architectural reset state and Hypervisor calls as
    /// the contract engine, while deliberately omitting its validation, ownership, and locking.
    public static func run() throws -> UInt64 {
      let pageSize = Int(getpagesize())
      let guestBase: UInt64 = 0x8000_0000
      let memory = UnsafeMutableRawPointer.allocate(byteCount: pageSize, alignment: pageSize)
      memory.initializeMemory(as: UInt8.self, repeating: 0, count: pageSize)
      memory.storeBytes(of: UInt32(0xd280_0540).littleEndian, as: UInt32.self)
      memory.advanced(by: 4).storeBytes(
        of: UInt32(0xd400_0002).littleEndian,
        as: UInt32.self
      )
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
      guard number == 42 else {
        throw DoryNativeHVArm64MinimalHarnessError.unexpectedRegister(number)
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
