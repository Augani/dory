import Hypervisor

/// Milestone 1 gate: prove the process may create a VM under its code signature, map RAM it owns,
/// and execute guest instructions. Runs a two-instruction guest (mov x0, #42; hvc #0) and checks
/// the hypercall lands back here with the expected register state.
public enum HVSmoke {
    public static func run() throws -> String {
        try hvCheck(hv_vm_create(nil), "hv_vm_create")
        defer { hv_vm_destroy() }

        let ramBase: UInt64 = 0x8000_0000
        let memory = try GuestMemory(guestBase: ramBase, size: 1 << 20)
        try memory.mapIntoGuest()

        try memory.write(UInt32(0xD280_0540), at: ramBase)      // mov x0, #42
        try memory.write(UInt32(0xD400_0002), at: ramBase + 4)  // hvc #0

        let vcpu = try VCPU()
        try vcpu.write(HV_REG_CPSR, 0x3C5)                      // EL1h, DAIF masked
        try vcpu.write(HV_REG_PC, ramBase)

        let event = try vcpu.run()
        guard case .exception(let syndrome, _, _) = event else {
            throw VMError.unexpectedExit("expected exception exit, got \(event)")
        }
        guard ExceptionClass(syndrome: syndrome) == .hvc64 else {
            throw VMError.unexpectedExit("expected HVC trap, syndrome 0x\(String(syndrome, radix: 16))")
        }
        let x0 = try vcpu.read(HV_REG_X0)
        guard x0 == 42 else {
            throw VMError.unexpectedExit("guest x0 = \(x0), expected 42")
        }
        return "hv smoke passed: guest executed 2 instructions, hvc trapped, x0=42"
    }
}
