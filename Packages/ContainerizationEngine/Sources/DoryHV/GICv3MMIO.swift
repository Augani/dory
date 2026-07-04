import Foundation
import Hypervisor

/// Bridges guest MMIO in the GIC distributor and redistributor windows to the in-kernel GIC's
/// register API. The interrupt machinery itself (prioritization, CPU interface, timer PPIs) runs
/// inside Hypervisor.framework; only the memory-mapped configuration surface passes through here.
/// Offsets the framework does not model read as zero and ignore writes, which matches RAZ/WI
/// behavior for optional GICv3 registers (WAKER, CTLR sleep bits, LPI tables).
public final class GICDistributorMMIO: MMIODevice {
    public let baseAddress: UInt64
    public let size: UInt64

    public init(baseAddress: UInt64, size: UInt64) {
        self.baseAddress = baseAddress
        self.size = size
    }

    public func read(offset: UInt64, width: Int) -> UInt64 {
        var value: UInt64 = 0
        if hv_gic_get_distributor_reg(hv_gic_distributor_reg_t(UInt16(truncatingIfNeeded: offset)), &value) == HV_SUCCESS {
            return value
        }
        if offset & 0x4 != 0 {
            var aligned: UInt64 = 0
            if hv_gic_get_distributor_reg(hv_gic_distributor_reg_t(UInt16(truncatingIfNeeded: offset - 4)), &aligned) == HV_SUCCESS {
                return aligned >> 32
            }
        }
        return 0
    }

    public func write(offset: UInt64, value: UInt64, width: Int) {
        let register = hv_gic_distributor_reg_t(UInt16(truncatingIfNeeded: offset))
        if hv_gic_set_distributor_reg(register, value) == HV_SUCCESS { return }
        if offset & 0x4 != 0, width == 4 {
            let alignedRegister = hv_gic_distributor_reg_t(UInt16(truncatingIfNeeded: offset - 4))
            var current: UInt64 = 0
            if hv_gic_get_distributor_reg(alignedRegister, &current) == HV_SUCCESS {
                let merged = (current & 0xFFFF_FFFF) | (value << 32)
                _ = hv_gic_set_distributor_reg(alignedRegister, merged)
            }
        }
    }
}

public final class GICRedistributorMMIO: MMIODevice {
    public let baseAddress: UInt64
    public let size: UInt64
    public let stride: UInt64
    public var vcpuHandles: [hv_vcpu_t] = []

    public init(baseAddress: UInt64, size: UInt64, stride: UInt64) {
        self.baseAddress = baseAddress
        self.size = size
        self.stride = stride
    }

    public func read(offset: UInt64, width: Int) -> UInt64 {
        guard let (vcpu, registerOffset) = resolve(offset) else { return 0 }
        var value: UInt64 = 0
        if hv_gic_get_redistributor_reg(vcpu, hv_gic_redistributor_reg_t(UInt32(registerOffset)), &value) == HV_SUCCESS {
            return value
        }
        if registerOffset & 0x4 != 0 {
            var aligned: UInt64 = 0
            if hv_gic_get_redistributor_reg(vcpu, hv_gic_redistributor_reg_t(UInt32(registerOffset - 4)), &aligned) == HV_SUCCESS {
                return aligned >> 32
            }
        }
        return 0
    }

    public func write(offset: UInt64, value: UInt64, width: Int) {
        guard let (vcpu, registerOffset) = resolve(offset) else { return }
        let register = hv_gic_redistributor_reg_t(UInt32(registerOffset))
        if hv_gic_set_redistributor_reg(vcpu, register, value) == HV_SUCCESS { return }
        if registerOffset & 0x4 != 0, width == 4 {
            let alignedRegister = hv_gic_redistributor_reg_t(UInt32(registerOffset - 4))
            var current: UInt64 = 0
            if hv_gic_get_redistributor_reg(vcpu, alignedRegister, &current) == HV_SUCCESS {
                let merged = (current & 0xFFFF_FFFF) | (value << 32)
                _ = hv_gic_set_redistributor_reg(vcpu, alignedRegister, merged)
            }
        }
    }

    private func resolve(_ offset: UInt64) -> (hv_vcpu_t, UInt64)? {
        let index = Int(offset / stride)
        guard index < vcpuHandles.count else { return nil }
        return (vcpuHandles[index], offset % stride)
    }
}
