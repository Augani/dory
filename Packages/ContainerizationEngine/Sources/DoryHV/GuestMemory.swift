import Darwin
import Hypervisor

/// The VM's RAM: one anonymous mmap region in OUR address space, mapped into the guest at a fixed
/// physical base. Owning the pages is the entire point of dory-hv: reclaim is madvise on this
/// region, something Virtualization.framework structurally cannot offer (its guest RAM lives in
/// Apple's XPC process).
public final class GuestMemory: @unchecked Sendable {
    public let guestBase: UInt64
    public let size: UInt64
    public let hostBase: UnsafeMutableRawPointer

    public init(guestBase: UInt64, size: UInt64) throws {
        guard size > 0, size % 16384 == 0 else {
            throw VMError.invalidConfiguration("RAM size must be a positive multiple of 16KiB")
        }
        guard let region = mmap(nil, Int(size), PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0),
              region != MAP_FAILED else {
            throw VMError.outOfMemory("mmap of \(size) bytes failed: errno \(errno)")
        }
        self.guestBase = guestBase
        self.size = size
        self.hostBase = region
    }

    deinit {
        munmap(hostBase, Int(size))
    }

    public func mapIntoGuest() throws {
        try hvCheck(
            hv_vm_map(hostBase, guestBase, Int(size), hv_memory_flags_t(HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC)),
            "hv_vm_map"
        )
    }

    public func contains(_ address: UInt64, count: UInt64) -> Bool {
        guard address >= guestBase else { return false }
        let offset = address - guestBase
        return offset <= size && count <= size - offset
    }

    public func hostPointer(at guestAddress: UInt64, count: UInt64) throws -> UnsafeMutableRawPointer {
        guard contains(guestAddress, count: count) else {
            throw VMError.guestMemoryFault(address: guestAddress, count: count)
        }
        return hostBase.advanced(by: Int(guestAddress - guestBase))
    }

    public func read<T: FixedWidthInteger>(_ type: T.Type, at guestAddress: UInt64) throws -> T {
        let pointer = try hostPointer(at: guestAddress, count: UInt64(MemoryLayout<T>.size))
        var value = T.zero
        withUnsafeMutableBytes(of: &value) { destination in
            destination.copyMemory(from: UnsafeRawBufferPointer(start: pointer, count: MemoryLayout<T>.size))
        }
        return T(littleEndian: value)
    }

    public func write<T: FixedWidthInteger>(_ value: T, at guestAddress: UInt64) throws {
        let pointer = try hostPointer(at: guestAddress, count: UInt64(MemoryLayout<T>.size))
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { source in
            pointer.copyMemory(from: source.baseAddress!, byteCount: MemoryLayout<T>.size)
        }
    }

    public func write(_ data: [UInt8], at guestAddress: UInt64) throws {
        guard !data.isEmpty else { return }
        let pointer = try hostPointer(at: guestAddress, count: UInt64(data.count))
        data.withUnsafeBytes { source in
            pointer.copyMemory(from: source.baseAddress!, byteCount: data.count)
        }
    }

    public func readBytes(at guestAddress: UInt64, count: Int) throws -> [UInt8] {
        guard count > 0 else { return [] }
        let pointer = try hostPointer(at: guestAddress, count: UInt64(count))
        return [UInt8](UnsafeRawBufferPointer(start: pointer, count: count))
    }
}

public enum VMError: Error, CustomStringConvertible {
    case invalidConfiguration(String)
    case outOfMemory(String)
    case guestMemoryFault(address: UInt64, count: UInt64)
    case bootFailure(String)
    case unexpectedExit(String)

    public var description: String {
        switch self {
        case .invalidConfiguration(let message): return "invalid configuration: \(message)"
        case .outOfMemory(let message): return "out of memory: \(message)"
        case .guestMemoryFault(let address, let count):
            return "guest memory fault: 0x\(String(address, radix: 16)) +\(count)"
        case .bootFailure(let message): return "boot failure: \(message)"
        case .unexpectedExit(let message): return "unexpected exit: \(message)"
        }
    }
}
