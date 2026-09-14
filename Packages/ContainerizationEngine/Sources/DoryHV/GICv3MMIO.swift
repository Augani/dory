import Foundation
import Hypervisor

#if arch(arm64)
/// Bridges guest MMIO in the GIC distributor and redistributor windows to the in-kernel GIC's
/// register API. The interrupt machinery itself (prioritization, CPU interface, timer PPIs) runs
/// inside Hypervisor.framework; only the memory-mapped configuration surface passes through here.
/// Offsets the framework does not model read as zero and ignore writes, which matches RAZ/WI
/// behavior for optional GICv3 registers (WAKER, CTLR sleep bits, LPI tables).
///
/// GIC state coverage (P2-02 item 4):
/// The in-kernel GIC owns all interrupt state transitions: pending/active, edge/level trigger
/// type, SGI generation, PPI delivery (including the architectural timer PPIs), priority drop,
/// and EOI. DoryHV only bridges the MMIO configuration surface and asserts SPIs via
/// `hv_gic_set_spi`. The distributor and redistributor layouts are validated against the frozen
/// `dory.armvirt@1` ABI in `ARMVirtMachineContractTests`. SPI INTID derivation (32 + GSI) is
/// tested in `ARMPSCILifecycleTests`. Full distributor/redistributor state transition tests
/// require a live Hypervisor.framework VM and are covered by integration qualification, not
/// unit tests, because the in-kernel GIC state is not directly observable from userspace.
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
    // This lock leases the mapped handle for the entire MMIO operation, including fallback
    // read-modify-write. Removal acquires it to drain access before the owner destroys its VCPU.
    private let accessLock = NSLock()
    private var vcpuHandles: [hv_vcpu_t?] = []
    private let registerAccess: RegisterAccess

    /// Internal, redistributor-only seam for testing without creating a Hypervisor VM.
    /// Callbacks run under accessLock and must not reenter this device or acquire teamCondition.
    struct RegisterAccess: Sendable {
        let read: @Sendable (hv_vcpu_t, hv_gic_redistributor_reg_t, inout UInt64) -> hv_return_t
        let write: @Sendable (hv_vcpu_t, hv_gic_redistributor_reg_t, UInt64) -> hv_return_t
        let removalLockAcquired: @Sendable () -> Void

        fileprivate static let hypervisor = RegisterAccess(
            read: { hv_gic_get_redistributor_reg($0, $1, &$2) },
            write: { hv_gic_set_redistributor_reg($0, $1, $2) },
            removalLockAcquired: {}
        )
    }

    public convenience init(baseAddress: UInt64, size: UInt64, stride: UInt64) {
        self.init(baseAddress: baseAddress, size: size, stride: stride, registerAccess: .hypervisor)
    }

    init(baseAddress: UInt64, size: UInt64, stride: UInt64, registerAccess: RegisterAccess) {
        self.baseAddress = baseAddress
        self.size = size
        self.stride = stride
        self.registerAccess = registerAccess
    }

    public func setHandle(_ handle: hv_vcpu_t, at frameIndex: Int) {
        accessLock.lock()
        defer { accessLock.unlock() }
        while vcpuHandles.count <= frameIndex { vcpuHandles.append(nil) }
        vcpuHandles[frameIndex] = handle
    }

    /// Drains in-flight MMIO and retires only this lifetime's registration at its assigned frame.
    /// The caller must keep the owning VCPU alive until this returns.
    func removeHandle(_ expectedHandle: hv_vcpu_t, at frameIndex: Int) {
        accessLock.lock()
        defer { accessLock.unlock() }
        registerAccess.removalLockAcquired()
        guard vcpuHandles.indices.contains(frameIndex),
              vcpuHandles[frameIndex] == expectedHandle else { return }
        vcpuHandles[frameIndex] = nil
    }

    public func read(offset: UInt64, width: Int) -> UInt64 {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard let (vcpu, registerOffset) = resolve(offset) else { return 0 }
        var value: UInt64 = 0
        if registerAccess.read(vcpu, hv_gic_redistributor_reg_t(UInt32(registerOffset)), &value) == HV_SUCCESS {
            return value
        }
        if registerOffset & 0x4 != 0 {
            var aligned: UInt64 = 0
            if registerAccess.read(vcpu, hv_gic_redistributor_reg_t(UInt32(registerOffset - 4)), &aligned) == HV_SUCCESS {
                return aligned >> 32
            }
        }
        return 0
    }

    public func write(offset: UInt64, value: UInt64, width: Int) {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard let (vcpu, registerOffset) = resolve(offset) else { return }
        let register = hv_gic_redistributor_reg_t(UInt32(registerOffset))
        if registerAccess.write(vcpu, register, value) == HV_SUCCESS { return }
        if registerOffset & 0x4 != 0, width == 4 {
            let alignedRegister = hv_gic_redistributor_reg_t(UInt32(registerOffset - 4))
            var current: UInt64 = 0
            if registerAccess.read(vcpu, alignedRegister, &current) == HV_SUCCESS {
                let merged = (current & 0xFFFF_FFFF) | (value << 32)
                _ = registerAccess.write(vcpu, alignedRegister, merged)
            }
        }
    }

    /// Requires accessLock; the resolved handle must never outlive that critical section.
    private func resolve(_ offset: UInt64) -> (hv_vcpu_t, UInt64)? {
        let index = Int(offset / stride)
        guard index < vcpuHandles.count, let handle = vcpuHandles[index] else { return nil }
        return (handle, offset % stride)
    }
}
#endif
