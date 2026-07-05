import Hypervisor

#if arch(arm64)
/// Milestone 1 gate: prove the process may create a VM under its code signature, map RAM it owns,
/// and execute guest instructions. Runs a two-instruction guest (mov x0, #42; hvc #0) and checks
/// the hypercall lands back here with the expected register state.
public enum HVSmoke {
    public static func run() throws -> String {
        try hvCreateVM()
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
#else
public enum HVSmoke {
    private static let smokePort: UInt16 = 0x00F4
    private static let smokeValue: UInt8 = 0x2A
    private static let smokeAddress: UInt64 = 0x1000

    public static func run() throws -> String {
        try hvCreateVM()
        defer { hv_vm_destroy() }

        let memory = try GuestMemory(guestBase: 0, size: 1 << 20)
        try memory.mapIntoGuest()
        try memory.write([
            0xB0, smokeValue,                       // mov al, imm8
            0xE6, UInt8(truncatingIfNeeded: smokePort), // out imm8, al
            0xF4,                                   // hlt if OUT is not intercepted
        ], at: smokeAddress)

        let vcpu = try VCPU()
        try configureRealMode(vcpu, rip: smokeAddress)

        guard case .vmExit(let state) = try vcpu.run() else {
            throw VMError.unexpectedExit("x86 smoke returned without a VM exit")
        }
        guard case .pio(let exit) = X86VMExitDecoder.decode(state) else {
            throw VMError.unexpectedExit(
                "x86 smoke expected PIO exit, got reason \(state.reason) qualification 0x\(String(state.qualification, radix: 16))"
            )
        }
        guard exit.port == smokePort, exit.direction == .output, exit.width == 1 else {
            throw VMError.unexpectedExit(
                "x86 smoke unexpected PIO exit port 0x\(String(exit.port, radix: 16)) width \(exit.width) direction \(exit.direction)"
            )
        }
        let al = try vcpu.read(HV_X86_RAX) & 0xFF
        guard al == UInt64(smokeValue) else {
            throw VMError.unexpectedExit("x86 smoke AL = \(al), expected \(smokeValue)")
        }
        return "hv smoke passed: x86 guest executed OUT 0xf4 with al=42"
    }

    private static func configureRealMode(_ vcpu: VCPU, rip: UInt64) throws {
        try vcpu.write(HV_X86_RIP, rip)
        try vcpu.write(HV_X86_RFLAGS, 0x2)
        try vcpu.write(HV_X86_RAX, 0)
        try vcpu.write(HV_X86_RSP, 0x8000)
        try vcpu.write(HV_X86_CR0, 0x10)
        try vcpu.write(HV_X86_CR3, 0)
        try vcpu.write(HV_X86_CR4, 0)
        try writeControl(vcpu, field: UInt32(VMCS_CTRL_PIN_BASED), requested: 0)
        try writeControl(
            vcpu,
            field: UInt32(VMCS_CTRL_CPU_BASED),
            requested: UInt32(CPU_BASED_UNCOND_IO | CPU_BASED_HLT | CPU_BASED_SECONDARY_CTLS)
        )
        try writeControl(
            vcpu,
            field: UInt32(VMCS_CTRL_CPU_BASED2),
            requested: UInt32(CPU_BASED2_EPT | CPU_BASED2_UNRESTRICTED)
        )
        try writeControl(vcpu, field: UInt32(VMCS_CTRL_VMEXIT_CONTROLS), requested: 0)
        try writeControl(vcpu, field: UInt32(VMCS_CTRL_VMENTRY_CONTROLS), requested: 0)

        try writeRealModeSegment(
            vcpu,
            selectorField: UInt32(VMCS_GUEST_CS),
            baseField: UInt32(VMCS_GUEST_CS_BASE),
            limitField: UInt32(VMCS_GUEST_CS_LIMIT),
            accessField: UInt32(VMCS_GUEST_CS_AR),
            selector: 0,
            executable: true
        )
        for (selectorField, baseField, limitField, accessField) in [
            (VMCS_GUEST_SS, VMCS_GUEST_SS_BASE, VMCS_GUEST_SS_LIMIT, VMCS_GUEST_SS_AR),
            (VMCS_GUEST_DS, VMCS_GUEST_DS_BASE, VMCS_GUEST_DS_LIMIT, VMCS_GUEST_DS_AR),
            (VMCS_GUEST_ES, VMCS_GUEST_ES_BASE, VMCS_GUEST_ES_LIMIT, VMCS_GUEST_ES_AR),
            (VMCS_GUEST_FS, VMCS_GUEST_FS_BASE, VMCS_GUEST_FS_LIMIT, VMCS_GUEST_FS_AR),
            (VMCS_GUEST_GS, VMCS_GUEST_GS_BASE, VMCS_GUEST_GS_LIMIT, VMCS_GUEST_GS_AR),
        ] {
            try writeRealModeSegment(
                vcpu,
                selectorField: UInt32(selectorField),
                baseField: UInt32(baseField),
                limitField: UInt32(limitField),
                accessField: UInt32(accessField),
                selector: 0,
                executable: false
            )
        }
        try vcpu.writeVMCS(UInt32(VMCS_GUEST_LDTR), 0)
        try vcpu.writeVMCS(UInt32(VMCS_GUEST_LDTR_BASE), 0)
        try vcpu.writeVMCS(UInt32(VMCS_GUEST_LDTR_LIMIT), 0)
        try vcpu.writeVMCS(UInt32(VMCS_GUEST_LDTR_AR), 0x1_0000)
        try vcpu.writeVMCS(UInt32(VMCS_GUEST_TR), 0)
        try vcpu.writeVMCS(UInt32(VMCS_GUEST_TR_BASE), 0)
        try vcpu.writeVMCS(UInt32(VMCS_GUEST_TR_LIMIT), 0x67)
        try vcpu.writeVMCS(UInt32(VMCS_GUEST_TR_AR), 0x8B)
        try vcpu.writeVMCS(UInt32(VMCS_GUEST_GDTR_BASE), 0)
        try vcpu.writeVMCS(UInt32(VMCS_GUEST_GDTR_LIMIT), 0)
        try vcpu.writeVMCS(UInt32(VMCS_GUEST_IDTR_BASE), 0)
        try vcpu.writeVMCS(UInt32(VMCS_GUEST_IDTR_LIMIT), 0x3FF)
        try vcpu.writeVMCS(UInt32(VMCS_GUEST_ACTIVITY_STATE), 0)
        try vcpu.writeVMCS(UInt32(VMCS_GUEST_INTERRUPTIBILITY), 0)
    }

    private static func writeControl(_ vcpu: VCPU, field: UInt32, requested: UInt32) throws {
        var requiredOne: UInt64 = 0
        var allowedOne: UInt64 = 0
        try hvCheck(
            hv_vmx_vcpu_get_cap_write_vmcs(vcpu.handle, field, &requiredOne, &allowedOne),
            "hv_vmx_vcpu_get_cap_write_vmcs"
        )
        try vcpu.writeVMCS(field, (UInt64(requested) | requiredOne) & allowedOne)
    }

    private static func writeRealModeSegment(
        _ vcpu: VCPU,
        selectorField: UInt32,
        baseField: UInt32,
        limitField: UInt32,
        accessField: UInt32,
        selector: UInt16,
        executable: Bool
    ) throws {
        try vcpu.writeVMCS(selectorField, UInt64(selector))
        try vcpu.writeVMCS(baseField, UInt64(selector) << 4)
        try vcpu.writeVMCS(limitField, 0xFFFF)
        try vcpu.writeVMCS(accessField, executable ? 0x9B : 0x93)
    }
}
#endif
