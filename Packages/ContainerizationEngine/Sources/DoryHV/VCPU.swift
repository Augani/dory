import Hypervisor

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
    case dataAbortLowerEL = 0x24

    public init?(syndrome: UInt64) {
        self.init(rawValue: syndrome >> 26)
    }
}
