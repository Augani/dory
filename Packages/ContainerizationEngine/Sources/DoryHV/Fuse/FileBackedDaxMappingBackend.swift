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
            throw DaxWindowError.mappingFailed("hv_vm_map failed: \(result)")
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
        var protections = PROT_READ
        if flags & FuseSetupMappingFlag.write.rawValue != 0 {
            protections |= PROT_WRITE
        }
        return protections
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
