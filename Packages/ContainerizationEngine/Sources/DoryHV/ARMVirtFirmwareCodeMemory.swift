#if arch(arm64)
import Darwin
import DoryFirmware
import DoryMachineARMVirt
import Foundation
import Hypervisor

/// Injectable host/stage-2 primitives keep the exact mapping policy independently testable.
struct ARMVirtFirmwareCodeMemoryOperations: @unchecked Sendable {
    static let production = Self(
        allocate: { byteCount in
            let mapping = mmap(
                nil,
                byteCount,
                PROT_READ | PROT_WRITE,
                MAP_ANON | MAP_PRIVATE,
                -1,
                0
            )
            guard mapping != MAP_FAILED else { return nil }
            return mapping
        },
        protectReadOnly: { pointer, byteCount in
            mprotect(pointer, byteCount, PROT_READ) == 0
        },
        mapReadExecute: { pointer, guestAddress, byteCount in
            hv_vm_map(
                pointer,
                guestAddress,
                byteCount,
                hv_memory_flags_t(HV_MEMORY_READ | HV_MEMORY_EXEC)
            ) == HV_SUCCESS
        },
        unmap: { guestAddress, byteCount in
            hv_vm_unmap(guestAddress, byteCount) == HV_SUCCESS
        },
        deallocate: { pointer, byteCount in
            munmap(pointer, byteCount)
        }
    )

    let allocate: (Int) -> UnsafeMutableRawPointer?
    let protectReadOnly: (UnsafeMutableRawPointer, Int) -> Bool
    let mapReadExecute: (UnsafeMutableRawPointer, UInt64, Int) -> Bool
    let unmap: (UInt64, Int) -> Bool
    let deallocate: (UnsafeMutableRawPointer, Int) -> Void
}

/// Owns the immutable `dory.armvirt@1` firmware code window.
///
/// The authenticated image is padded with erased-flash bytes to the ABI's complete 64 MiB
/// reservation. The host mapping becomes read-only before it can be installed into stage 2, and
/// the guest receives read/execute permissions only.
final class ARMVirtFirmwareCodeMemory: @unchecked Sendable {
    static let guestBase = DoryARMVirtV1ABI.firmwareCodeBase
    static let byteCount = DoryARMVirtV1ABI.firmwareCodeBytes
    static let erasedByte: UInt8 = 0xff

    private let hostBase: UnsafeMutableRawPointer
    private let mappedByteCount: Int
    private let operations: ARMVirtFirmwareCodeMemoryOperations
    private var isMappedIntoGuest = false

    convenience init(artifacts: DoryVerifiedFirmwareArtifacts) throws {
        try self.init(artifacts: artifacts, operations: .production)
    }

    init(
        artifacts: DoryVerifiedFirmwareArtifacts,
        operations: ARMVirtFirmwareCodeMemoryOperations
    ) throws {
        guard artifacts.manifest.firmwareABIIdentity == DoryARMVirtV1ABI.firmwareABIIdentity,
              artifacts.manifest.machineABIIdentity == DoryARMVirtV1ABI.identity else {
            throw VMError.invalidConfiguration("firmware is incompatible with \(DoryARMVirtV1ABI.identity)")
        }
        guard let mappedByteCount = Int(exactly: Self.byteCount) else {
            throw VMError.invalidConfiguration("firmware code window cannot be represented on this host")
        }
        guard artifacts.firmwareCode.count <= mappedByteCount else {
            throw VMError.invalidConfiguration("firmware code exceeds the frozen code window")
        }
        guard let hostBase = operations.allocate(mappedByteCount) else {
            throw VMError.outOfMemory("cannot allocate the ARMVirt firmware code window")
        }

        memset(hostBase, Int32(Self.erasedByte), mappedByteCount)
        artifacts.firmwareCode.withUnsafeBytes { source in
            guard let sourceBase = source.baseAddress else { return }
            hostBase.copyMemory(from: sourceBase, byteCount: source.count)
        }
        guard operations.protectReadOnly(hostBase, mappedByteCount) else {
            operations.deallocate(hostBase, mappedByteCount)
            throw VMError.bootFailure("cannot make the ARMVirt firmware code window immutable")
        }

        self.hostBase = hostBase
        self.mappedByteCount = mappedByteCount
        self.operations = operations
    }

    deinit {
        if isMappedIntoGuest {
            _ = operations.unmap(Self.guestBase, mappedByteCount)
        }
        operations.deallocate(hostBase, mappedByteCount)
    }

    func mapIntoGuest() throws {
        guard !isMappedIntoGuest else {
            throw VMError.invalidConfiguration("firmware code is already mapped into the guest")
        }
        guard operations.mapReadExecute(hostBase, Self.guestBase, mappedByteCount) else {
            throw VMError.bootFailure("cannot map the ARMVirt firmware code window read/execute")
        }
        isMappedIntoGuest = true
    }

    func unmapFromGuest() throws {
        guard isMappedIntoGuest else { return }
        guard operations.unmap(Self.guestBase, mappedByteCount) else {
            throw VMError.bootFailure("cannot unmap the ARMVirt firmware code window")
        }
        isMappedIntoGuest = false
    }

    func readBytes(at offset: Int, count: Int) throws -> [UInt8] {
        guard offset >= 0, count >= 0, offset <= mappedByteCount,
              count <= mappedByteCount - offset else {
            throw VMError.invalidConfiguration("firmware code read is outside the frozen window")
        }
        return [UInt8](
            UnsafeRawBufferPointer(start: hostBase.advanced(by: offset), count: count)
        )
    }
}
#endif
