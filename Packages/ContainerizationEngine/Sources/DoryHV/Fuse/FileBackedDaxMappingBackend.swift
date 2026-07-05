import Darwin
import Foundation
import Hypervisor

public final class FileBackedDaxMappingBackend: DaxMappingBackend, @unchecked Sendable {
    private struct Region {
        var hostAddress: UnsafeMutableRawPointer
        var length: Int
    }

    private let lock = NSLock()
    private var regions: [Key: Region] = [:]

    public init() {}

    public func map(_ mapping: DaxMapping, fileDescriptor: Int32, guestAddress: UInt64) throws {
        let length = try intLength(mapping.length)
        let protections = protections(for: mapping.flags)
        let hostAddress = mmap(nil, length, protections, MAP_SHARED, fileDescriptor, off_t(mapping.fileOffset))
        guard let hostAddress, hostAddress != MAP_FAILED else {
            throw DaxWindowError.mappingFailed("mmap failed: errno \(errno)")
        }

        let hvFlags = hv_memory_flags_t(hvFlags(for: mapping.flags))
        let result = hv_vm_map(hostAddress, guestAddress, length, hvFlags)
        guard result == HV_SUCCESS else {
            munmap(hostAddress, length)
            throw DaxWindowError.mappingFailed("hv_vm_map(host=\(hostAddress) gpa=0x\(String(guestAddress, radix: 16)) len=0x\(String(length, radix: 16)) flags=0x\(String(hvFlags, radix: 16))) -> 0x\(String(UInt32(bitPattern: result), radix: 16))")
        }

        lock.withLock {
            regions[Key(memoryOffset: mapping.memoryOffset, length: mapping.length)] = Region(hostAddress: hostAddress, length: length)
        }
    }

    public func unmap(_ mapping: DaxMapping, guestAddress: UInt64) throws {
        let key = Key(memoryOffset: mapping.memoryOffset, length: mapping.length)
        guard let region = lock.withLock({ regions.removeValue(forKey: key) }) else {
            throw DaxWindowError.unmappingFailed("mapping not found")
        }
        let unmapResult = hv_vm_unmap(guestAddress, region.length)
        let munmapResult = munmap(region.hostAddress, region.length)
        guard unmapResult == HV_SUCCESS, munmapResult == 0 else {
            throw DaxWindowError.unmappingFailed("hv_vm_unmap \(unmapResult), munmap errno \(errno)")
        }
    }

    private func intLength(_ value: UInt64) throws -> Int {
        guard value <= UInt64(Int.max) else {
            throw DaxWindowError.mappingFailed("mapping length overflows Int")
        }
        return Int(value)
    }

    private func protections(for flags: UInt64) -> Int32 {
        // Map the host region read+write regardless of the guest's requested access. Apple's
        // hv_vm_map rejects a host region that is not writable (HV_ERROR); the guest's stage-2
        // protection below still restricts the guest to what it asked for, so a read-only DAX
        // mapping cannot be used by the guest to modify the host file.
        return PROT_READ | PROT_WRITE
    }

    private func hvFlags(for flags: UInt64) -> UInt32 {
        var hvFlags = HV_MEMORY_READ
        if flags & FuseSetupMappingFlag.write.rawValue != 0 {
            hvFlags |= HV_MEMORY_WRITE
        }
        return UInt32(hvFlags)
    }

    private struct Key: Hashable {
        var memoryOffset: UInt64
        var length: UInt64
    }
}

private extension NSLock {
    func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock()
        defer { unlock() }
        return try body()
    }
}
