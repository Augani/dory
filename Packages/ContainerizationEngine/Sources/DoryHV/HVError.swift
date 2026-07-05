import Hypervisor

public struct HVError: Error, CustomStringConvertible {
    public let call: String
    public let code: hv_return_t

    public var description: String {
        "\(call) failed: \(Self.name(for: code)) (0x\(String(UInt32(bitPattern: code), radix: 16)))"
    }

    private static func name(for code: hv_return_t) -> String {
        switch Int(code) {
        case HV_ERROR: return "HV_ERROR"
        case HV_BUSY: return "HV_BUSY"
        case HV_BAD_ARGUMENT: return "HV_BAD_ARGUMENT"
        #if arch(arm64)
        case HV_ILLEGAL_GUEST_STATE: return "HV_ILLEGAL_GUEST_STATE"
        #endif
        case HV_NO_RESOURCES: return "HV_NO_RESOURCES"
        case HV_NO_DEVICE: return "HV_NO_DEVICE"
        case HV_DENIED: return "HV_DENIED"
        case HV_UNSUPPORTED: return "HV_UNSUPPORTED"
        default: return "unknown"
        }
    }
}

@inline(__always)
public func hvCheck(_ call: @autoclosure () -> hv_return_t, _ name: String) throws {
    let code = call()
    guard code == HV_SUCCESS else { throw HVError(call: name, code: code) }
}

public func hvCreateVM() throws {
    #if arch(arm64)
    try hvCheck(hv_vm_create(nil), "hv_vm_create")
    #else
    try hvCheck(hv_vm_create(hv_vm_options_t(HV_VM_ACCEL_APIC)), "hv_vm_create")
    #endif
}
