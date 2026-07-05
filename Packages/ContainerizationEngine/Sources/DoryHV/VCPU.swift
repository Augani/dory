import Hypervisor

#if arch(arm64)
/// One guest CPU. Hypervisor.framework requires that a vcpu is created, run, and destroyed on the
/// SAME thread, so instances are confined to their owning thread by construction and never shared.
public final class VCPU {
    public let handle: hv_vcpu_t
    private let exitInfo: UnsafeMutablePointer<hv_vcpu_exit_t>

    public init() throws {
        var vcpu: hv_vcpu_t = 0
        var exitPointer: UnsafeMutablePointer<hv_vcpu_exit_t>?
        try hvCheck(hv_vcpu_create(&vcpu, &exitPointer, nil), "hv_vcpu_create")
        guard let exitPointer else {
            throw VMError.bootFailure("hv_vcpu_create returned no exit buffer")
        }
        self.handle = vcpu
        self.exitInfo = exitPointer
    }

    deinit {
        hv_vcpu_destroy(handle)
    }

    public func read(_ register: hv_reg_t) throws -> UInt64 {
        var value: UInt64 = 0
        try hvCheck(hv_vcpu_get_reg(handle, register, &value), "hv_vcpu_get_reg")
        return value
    }

    public func write(_ register: hv_reg_t, _ value: UInt64) throws {
        try hvCheck(hv_vcpu_set_reg(handle, register, value), "hv_vcpu_set_reg")
    }

    public func readSystem(_ register: hv_sys_reg_t) throws -> UInt64 {
        var value: UInt64 = 0
        try hvCheck(hv_vcpu_get_sys_reg(handle, register, &value), "hv_vcpu_get_sys_reg")
        return value
    }

    public func writeSystem(_ register: hv_sys_reg_t, _ value: UInt64) throws {
        try hvCheck(hv_vcpu_set_sys_reg(handle, register, value), "hv_vcpu_set_sys_reg")
    }

    public func setVTimerMask(_ masked: Bool) throws {
        try hvCheck(hv_vcpu_set_vtimer_mask(handle, masked), "hv_vcpu_set_vtimer_mask")
    }

    @discardableResult
    public func run() throws -> ExitEvent {
        try hvCheck(hv_vcpu_run(handle), "hv_vcpu_run")
        let exit = exitInfo.pointee
        switch exit.reason {
        case HV_EXIT_REASON_CANCELED:
            return .canceled
        case HV_EXIT_REASON_VTIMER_ACTIVATED:
            return .vtimerActivated
        case HV_EXIT_REASON_EXCEPTION:
            return .exception(
                syndrome: exit.exception.syndrome,
                virtualAddress: exit.exception.virtual_address,
                physicalAddress: exit.exception.physical_address
            )
        default:
            return .unknown(rawReason: exit.reason.rawValue)
        }
    }

    public enum ExitEvent {
        case canceled
        case vtimerActivated
        case exception(syndrome: UInt64, virtualAddress: UInt64, physicalAddress: UInt64)
        case unknown(rawReason: UInt32)
    }
}

public enum ExceptionClass: UInt64 {
    case hvc64 = 0x16
    case smc64 = 0x17
    case systemRegisterTrap = 0x18
    case instructionAbortLowerEL = 0x20
    case dataAbortLowerEL = 0x24

    public init?(syndrome: UInt64) {
        self.init(rawValue: syndrome >> 26)
    }
}
#else
/// One x86 guest CPU. Hypervisor.framework requires create/run/destroy on the owning thread.
public final class VCPU {
    public let handle: hv_vcpuid_t

    public init() throws {
        var vcpu: hv_vcpuid_t = 0
        try hvCheck(hv_vcpu_create(&vcpu, 0), "hv_vcpu_create")
        self.handle = vcpu
    }

    deinit {
        hv_vcpu_destroy(handle)
    }

    public func read(_ register: hv_x86_reg_t) throws -> UInt64 {
        var value: UInt64 = 0
        try hvCheck(hv_vcpu_read_register(handle, register, &value), "hv_vcpu_read_register")
        return value
    }

    public func write(_ register: hv_x86_reg_t, _ value: UInt64) throws {
        try hvCheck(hv_vcpu_write_register(handle, register, value), "hv_vcpu_write_register")
    }

    public func readVMCS(_ field: UInt32) throws -> UInt64 {
        var value: UInt64 = 0
        try hvCheck(hv_vmx_vcpu_read_vmcs(handle, field, &value), "hv_vmx_vcpu_read_vmcs")
        return value
    }

    public func writeVMCS(_ field: UInt32, _ value: UInt64) throws {
        try hvCheck(hv_vmx_vcpu_write_vmcs(handle, field, value), "hv_vmx_vcpu_write_vmcs")
    }

    public func readMSR(_ msr: UInt32) throws -> UInt64 {
        var value: UInt64 = 0
        try hvCheck(hv_vcpu_read_msr(handle, msr, &value), "hv_vcpu_read_msr")
        return value
    }

    public func writeMSR(_ msr: UInt32, _ value: UInt64) throws {
        try hvCheck(hv_vcpu_write_msr(handle, msr, value), "hv_vcpu_write_msr")
    }

    public func enableNativeMSR(_ msr: UInt32, enabled: Bool = true) throws {
        try hvCheck(hv_vcpu_enable_native_msr(handle, msr, enabled), "hv_vcpu_enable_native_msr")
    }

    public func invalidateTLB() throws {
        try hvCheck(hv_vcpu_invalidate_tlb(handle), "hv_vcpu_invalidate_tlb")
    }

    @discardableResult
    public func run() throws -> ExitEvent {
        try hvCheck(hv_vcpu_run_until(handle, UInt64(HV_DEADLINE_FOREVER)), "hv_vcpu_run_until")
        let reason = try readVMCS(UInt32(VMCS_RO_EXIT_REASON))
        let instructionError = try readVMCS(UInt32(VMCS_RO_INSTR_ERROR))
        let qualification = try readVMCS(UInt32(VMCS_RO_EXIT_QUALIFIC))
        let instructionLength = try readVMCS(UInt32(VMCS_RO_VMEXIT_INSTR_LEN))
        let vmxInstructionInfo = try readVMCS(UInt32(VMCS_RO_VMX_INSTR_INFO))
        let guestPhysicalAddress = try readVMCS(UInt32(VMCS_GUEST_PHYSICAL_ADDRESS))
        let guestLinearAddress = try readVMCS(UInt32(VMCS_RO_GUEST_LIN_ADDR))
        let interruptionInfo = try readVMCS(UInt32(VMCS_RO_VMEXIT_IRQ_INFO))
        let interruptionErrorCode = try readVMCS(UInt32(VMCS_RO_VMEXIT_IRQ_ERROR))
        return .vmExit(X86VMExitState(
            reason: UInt32(truncatingIfNeeded: reason),
            qualification: qualification,
            instructionLength: UInt32(truncatingIfNeeded: instructionLength),
            guestPhysicalAddress: guestPhysicalAddress,
            guestLinearAddress: guestLinearAddress,
            interruptionInfo: UInt32(truncatingIfNeeded: interruptionInfo),
            interruptionErrorCode: UInt32(truncatingIfNeeded: interruptionErrorCode),
            instructionError: UInt32(truncatingIfNeeded: instructionError),
            vmxInstructionInfo: UInt32(truncatingIfNeeded: vmxInstructionInfo)
        ))
    }

    public enum ExitEvent {
        case vmExit(X86VMExitState)
    }
}

public extension VCPU {
    func configurePVHEntry(entryPoint: UInt64, startInfoAddress: UInt64) throws {
        try configureNativeTime()
        try write(HV_X86_RIP, entryPoint)
        try write(HV_X86_RFLAGS, 0x2)
        try write(HV_X86_RAX, 0)
        try write(HV_X86_RBX, startInfoAddress)
        try write(HV_X86_RCX, 0)
        try write(HV_X86_RDX, 0)
        try write(HV_X86_RSP, 0x8000)
        try write(HV_X86_CR0, 0x21)  // PE | NE, paging off.
        try write(HV_X86_CR3, 0)
        try write(HV_X86_CR4, 0)

        try writeControl(field: UInt32(VMCS_CTRL_PIN_BASED), requested: 0)
        try writeControl(
            field: UInt32(VMCS_CTRL_CPU_BASED),
            requested: UInt32(CPU_BASED_UNCOND_IO | CPU_BASED_HLT | CPU_BASED_SECONDARY_CTLS)
        )
        try writeControl(
            field: UInt32(VMCS_CTRL_CPU_BASED2),
            requested: UInt32(CPU_BASED2_EPT | CPU_BASED2_UNRESTRICTED)
        )
        try writeControl(
            field: UInt32(VMCS_CTRL_VMEXIT_CONTROLS),
            requested: UInt32(VMEXIT_SAVE_IA32_PAT | VMEXIT_LOAD_IA32_PAT | VMEXIT_SAVE_EFER | VMEXIT_LOAD_EFER)
        )
        try writeControl(
            field: UInt32(VMCS_CTRL_VMENTRY_CONTROLS),
            requested: UInt32(VMENTRY_LOAD_IA32_PAT | VMENTRY_LOAD_EFER)
        )
        try configureInitialGuestMSRs()

        try writeFlatSegment(
            selectorField: UInt32(VMCS_GUEST_CS),
            baseField: UInt32(VMCS_GUEST_CS_BASE),
            limitField: UInt32(VMCS_GUEST_CS_LIMIT),
            accessField: UInt32(VMCS_GUEST_CS_AR),
            selector: 0x08,
            accessRights: 0xC09B
        )
        for (selectorField, baseField, limitField, accessField) in [
            (VMCS_GUEST_SS, VMCS_GUEST_SS_BASE, VMCS_GUEST_SS_LIMIT, VMCS_GUEST_SS_AR),
            (VMCS_GUEST_DS, VMCS_GUEST_DS_BASE, VMCS_GUEST_DS_LIMIT, VMCS_GUEST_DS_AR),
            (VMCS_GUEST_ES, VMCS_GUEST_ES_BASE, VMCS_GUEST_ES_LIMIT, VMCS_GUEST_ES_AR),
            (VMCS_GUEST_FS, VMCS_GUEST_FS_BASE, VMCS_GUEST_FS_LIMIT, VMCS_GUEST_FS_AR),
            (VMCS_GUEST_GS, VMCS_GUEST_GS_BASE, VMCS_GUEST_GS_LIMIT, VMCS_GUEST_GS_AR),
        ] {
            try writeFlatSegment(
                selectorField: UInt32(selectorField),
                baseField: UInt32(baseField),
                limitField: UInt32(limitField),
                accessField: UInt32(accessField),
                selector: 0x10,
                accessRights: 0xC093
            )
        }
        try writeVMCS(UInt32(VMCS_GUEST_LDTR), 0)
        try writeVMCS(UInt32(VMCS_GUEST_LDTR_BASE), 0)
        try writeVMCS(UInt32(VMCS_GUEST_LDTR_LIMIT), 0)
        try writeVMCS(UInt32(VMCS_GUEST_LDTR_AR), 0x1_0000)
        try writeVMCS(UInt32(VMCS_GUEST_TR), 0x18)
        try writeVMCS(UInt32(VMCS_GUEST_TR_BASE), 0)
        try writeVMCS(UInt32(VMCS_GUEST_TR_LIMIT), 0x67)
        try writeVMCS(UInt32(VMCS_GUEST_TR_AR), 0x8B)
        try writeVMCS(UInt32(VMCS_GUEST_GDTR_BASE), 0)
        try writeVMCS(UInt32(VMCS_GUEST_GDTR_LIMIT), 0)
        try writeVMCS(UInt32(VMCS_GUEST_IDTR_BASE), 0)
        try writeVMCS(UInt32(VMCS_GUEST_IDTR_LIMIT), 0x3FF)
        try writeVMCS(UInt32(VMCS_GUEST_ACTIVITY_STATE), 0)
        try writeVMCS(UInt32(VMCS_GUEST_INTERRUPTIBILITY), 0)
    }

    func configureNativeTime() throws {
        try hvCheck(hv_vcpu_set_tsc_relative(handle, 0), "hv_vcpu_set_tsc_relative")
        try enableNativeMSR(X86MSRPolicy.ia32TSC)
    }

    func configureInitialGuestMSRs() throws {
        let policy = X86MSRPolicy()
        if case .value(let efer) = policy.read(X86MSRPolicy.ia32EFER) {
            try writeVMCS(UInt32(VMCS_GUEST_IA32_EFER), efer)
        }
        if case .value(let pat) = policy.read(X86MSRPolicy.ia32PAT) {
            try writeVMCS(UInt32(VMCS_GUEST_IA32_PAT), pat)
        }
    }

    func applyGuestMSRWrite(_ write: X86MSRWrite) throws {
        switch write.msr {
        case X86MSRPolicy.ia32EFER:
            try writeVMCS(UInt32(VMCS_GUEST_IA32_EFER), write.value)
        case X86MSRPolicy.ia32PAT:
            try writeVMCS(UInt32(VMCS_GUEST_IA32_PAT), write.value)
        default:
            break
        }
        try writeMSR(write.msr, write.value)
    }

    func snapshotGeneralRegisters() throws -> X86RegisterState {
        var state = X86RegisterState()
        for (index, register) in Self.generalRegisterMap.enumerated() {
            state.write(index, value: try read(register), width: 8)
        }
        return state
    }

    func applyGeneralRegisters(_ state: X86RegisterState) throws {
        for (index, register) in Self.generalRegisterMap.enumerated() {
            try write(register, state.read(index))
        }
    }

    func advanceRIP(by length: UInt32) throws {
        try write(HV_X86_RIP, try read(HV_X86_RIP) + UInt64(length))
    }

    private func writeControl(field: UInt32, requested: UInt32) throws {
        var requiredOne: UInt64 = 0
        var allowedOne: UInt64 = 0
        try hvCheck(
            hv_vmx_vcpu_get_cap_write_vmcs(handle, field, &requiredOne, &allowedOne),
            "hv_vmx_vcpu_get_cap_write_vmcs"
        )
        try writeVMCS(field, (UInt64(requested) | requiredOne) & allowedOne)
    }

    private func writeFlatSegment(
        selectorField: UInt32,
        baseField: UInt32,
        limitField: UInt32,
        accessField: UInt32,
        selector: UInt16,
        accessRights: UInt64
    ) throws {
        try writeVMCS(selectorField, UInt64(selector))
        try writeVMCS(baseField, 0)
        try writeVMCS(limitField, 0xFFFF_FFFF)
        try writeVMCS(accessField, accessRights)
    }

    private static let generalRegisterMap: [hv_x86_reg_t] = [
        HV_X86_RAX, HV_X86_RCX, HV_X86_RDX, HV_X86_RBX,
        HV_X86_RSP, HV_X86_RBP, HV_X86_RSI, HV_X86_RDI,
        HV_X86_R8, HV_X86_R9, HV_X86_R10, HV_X86_R11,
        HV_X86_R12, HV_X86_R13, HV_X86_R14, HV_X86_R15,
    ]
}
#endif
