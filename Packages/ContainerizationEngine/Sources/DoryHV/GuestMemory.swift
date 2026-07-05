import Darwin
import Hypervisor
import Synchronization

/// The VM's RAM: one anonymous mmap region in OUR address space, mapped into the guest at a fixed
/// physical base. Owning the pages is the entire point of dory-hv: reclaim is madvise on this
/// region, something Virtualization.framework structurally cannot offer (its guest RAM lives in
/// Apple's XPC process).
public final class GuestMemory: @unchecked Sendable {
    public let guestBase: UInt64
    public let size: UInt64
    public let hostBase: UnsafeMutableRawPointer
    public let releasedBytes = Atomic<UInt64>(0)
    public let restoredBytes = Atomic<UInt64>(0)

    static let pageSize: UInt64 = 16384
    private let releasedPages: Mutex<[Bool]>

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
        self.releasedPages = Mutex([Bool](repeating: false, count: Int(size / Self.pageSize)))
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

    /// Returns a reported-free range to macOS. Stage-2 pins guest pages while mapped, so the
    /// range is unmapped from the guest first, then marked reusable; the physical pages leave the
    /// process footprint immediately. The guest gets the range back lazily via handleRAMFault.
    @discardableResult
    public func releaseRange(guestAddress: UInt64, length: UInt64) -> Bool {
        guard contains(guestAddress, count: length), length > 0,
              guestAddress % Self.pageSize == 0, length % Self.pageSize == 0 else { return false }
        let first = Int((guestAddress - guestBase) / Self.pageSize)
        let count = Int(length / Self.pageSize)
        let host = hostBase.advanced(by: Int(guestAddress - guestBase))
        // The bitmap flip and the stage-2 unmap happen atomically under one lock, so a concurrent
        // restorePage on another vCPU can never observe an unmapped-but-unmarked page (which it
        // would misread as a genuine fault and crash).
        return releasedPages.withLock { pages -> Bool in
            guard hv_vm_unmap(guestAddress, Int(length)) == HV_SUCCESS else { return false }
            _ = madvise(host, Int(length), MADV_FREE_REUSABLE)
            for page in first..<min(first + count, pages.count) { pages[page] = true }
            releasedBytes.add(length, ordering: .relaxed)
            return true
        }
    }

    /// Remaps a single 16KiB RAM page the guest faulted on. A stage-2 fault inside the RAM window
    /// can only mean this page was unmapped by free page reporting (nothing else touches stage-2
    /// RAM mappings), so mapping it is always correct and resolves the fault — it can never loop.
    /// The released-page set is consulted only for accounting: a tracked page is charged back to
    /// the footprint, an untracked one is remapped defensively without double-counting. Returns
    /// false only for addresses outside RAM (a genuine device or bad-address fault) or a hard map
    /// failure, both of which the caller surfaces as a crash.
    public func restorePage(guestAddress: UInt64) -> Bool {
        guard contains(guestAddress, count: 1) else { return false }
        let pageStart = guestAddress & ~(Self.pageSize - 1)
        let index = Int((pageStart - guestBase) / Self.pageSize)
        let host = hostBase.advanced(by: Int(pageStart - guestBase))
        return releasedPages.withLock { pages -> Bool in
            guard index < pages.count else { return false }
            // Bit clear means a concurrent fault on the same page already remapped it (both
            // observed the fault; whoever won the lock first did the mapping). A stage-2 RAM fault
            // never occurs on a page we did not unmap, so treating this as already-mapped is safe
            // and the guest's retry resolves it.
            guard pages[index] else { return true }
            _ = madvise(host, Int(Self.pageSize), MADV_FREE_REUSE)
            guard hv_vm_map(host, pageStart, Int(Self.pageSize), hv_memory_flags_t(HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC)) == HV_SUCCESS else {
                return false
            }
            pages[index] = false
            restoredBytes.add(Self.pageSize, ordering: .relaxed)
            return true
        }
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
