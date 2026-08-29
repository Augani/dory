import Darwin
import DoryGuestMemoryShim
import Foundation
import Hypervisor
import Synchronization

public final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64

    public init(_ value: UInt64 = 0) {
        self.value = value
    }

    public func add(_ amount: UInt64) {
        lock.lock()
        value &+= amount
        lock.unlock()
    }

    public func load() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Raw host pointers never escape these synchronous callbacks. GuestMemory invokes them only while
/// holding its page-state mutex; unchecked Sendable documents that external serialization seam.
struct GuestMemoryReclaimOperations: @unchecked Sendable {
    static let production = GuestMemoryReclaimOperations(
        unmap: { guestAddress, length in
            hv_vm_unmap(guestAddress, length) == HV_SUCCESS
        },
        map: { hostAddress, guestAddress, length in
            hv_vm_map(
                hostAddress,
                guestAddress,
                length,
                hv_memory_flags_t(HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC)
            ) == HV_SUCCESS
        },
        markReusable: { hostAddress, length in
            madvise(hostAddress, length, MADV_FREE_REUSABLE) == 0
        },
        markInUse: { hostAddress, length in
            madvise(hostAddress, length, MADV_FREE_REUSE) == 0
        }
    )

    let unmap: (UInt64, Int) -> Bool
    let map: (UnsafeMutableRawPointer, UInt64, Int) -> Bool
    let markReusable: (UnsafeMutableRawPointer, Int) -> Bool
    let markInUse: (UnsafeMutableRawPointer, Int) -> Bool
}

/// Exact outcome of a free-page-reporting reclaim attempt. In particular, `unmappedNotReclaimed`
/// is not a rejection: stage-2 ownership was removed and is tracked for fault-time restoration,
/// but macOS did not accept the reusable-memory advice so the bytes must not be counted reclaimed.
public enum GuestMemoryReleaseResult: Equatable, Sendable {
    case reclaimed
    case unmappedNotReclaimed
    case rejected
    case unmapFailed

    public var guestMappingWasReleased: Bool {
        switch self {
        case .reclaimed, .unmappedNotReclaimed: true
        case .rejected, .unmapFailed: false
        }
    }

    public var hostMemoryWasReclaimed: Bool { self == .reclaimed }
}

/// One owned, bounded view of the VMM's unlinked guest-RAM backing object. The descriptor is an
/// independently closeable authority suitable for transfer to a signed worker.
struct GuestMemorySharedRegion: @unchecked Sendable {
    let descriptor: FileHandle
    let offset: UInt64
    let length: UInt64
    let declaredFileSize: UInt64
}

/// The VM's RAM: one unlinked shared mapping in OUR address space, mapped into the guest at a fixed
/// physical base. The shareable backing lets isolated device workers map only explicitly granted
/// slices while dory-hv retains reclaim and stage-2 ownership.
public final class GuestMemory: @unchecked Sendable {
    private enum PageMappingState: Equatable {
        case mapped
        case released(reclaimed: Bool, requiresMarkInUse: Bool)
    }

    public let guestBase: UInt64
    public let size: UInt64
    public let hostBase: UnsafeMutableRawPointer
    /// Unlinked, process-private shared-memory authority. Renderer workers receive only bounded
    /// CLOEXEC duplicates of this descriptor, never a host pointer or a filesystem path.
    private let backingDescriptor: Int32
    private let backingDeclaredFileSize: UInt64
    private let backingIdentity: DoryGuestMemoryBackingIdentity
    public let releasedBytes = ByteCounter()
    public let restoredBytes = ByteCounter()
    public let reclaimUnmapFailures = ByteCounter()
    public let reclaimAdviceFailures = ByteCounter()
    public let restoreAdviceFailures = ByteCounter()
    public let restoreMapFailures = ByteCounter()

    static let pageSize: UInt64 = HostPage.size
    private let pageStates: Mutex<[PageMappingState]>
    private let reclaimOperations: GuestMemoryReclaimOperations

    public convenience init(guestBase: UInt64, size: UInt64) throws {
        try self.init(
            guestBase: guestBase,
            size: size,
            reclaimOperations: .production
        )
    }

    init(
        guestBase: UInt64,
        size: UInt64,
        reclaimOperations: GuestMemoryReclaimOperations
    ) throws {
        guard size > 0, size % Self.pageSize == 0 else {
            throw VMError.invalidConfiguration("RAM size must be a positive multiple of the host page size")
        }
        guard DoryGuestMemoryBackingDataOffset() == Self.pageSize else {
            throw VMError.invalidConfiguration("guest RAM authority page size does not match the host")
        }
        var identity = DoryGuestMemoryBackingIdentity()
        var declaredFileSize: UInt64 = 0
        let descriptor = DoryCreateGuestMemoryBacking(
            size,
            &identity,
            &declaredFileSize
        )
        guard descriptor >= 0 else {
            throw VMError.outOfMemory(
                "cannot create guest RAM shared-memory authority: errno \(errno)"
            )
        }
        var descriptorIsOwned = true
        defer {
            if descriptorIsOwned { close(descriptor) }
        }
        guard DoryGuestMemoryBackingMatches(
            descriptor,
            declaredFileSize,
            &identity
        ) == 1 else {
            throw VMError.outOfMemory("guest RAM authority failed identity validation")
        }
        guard let region = mmap(
            nil,
            Int(size),
            PROT_READ | PROT_WRITE,
            MAP_SHARED,
            descriptor,
            off_t(DoryGuestMemoryBackingDataOffset())
        ), region != MAP_FAILED else {
            throw VMError.outOfMemory("mmap of \(size) bytes failed: errno \(errno)")
        }
        self.guestBase = guestBase
        self.size = size
        self.hostBase = region
        self.backingDescriptor = descriptor
        self.backingDeclaredFileSize = declaredFileSize
        self.backingIdentity = identity
        self.pageStates = Mutex(
            [PageMappingState](repeating: .mapped, count: Int(size / Self.pageSize))
        )
        self.reclaimOperations = reclaimOperations
        descriptorIsOwned = false
    }

    deinit {
        munmap(hostBase, Int(size))
        close(backingDescriptor)
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
    public func releaseRange(guestAddress: UInt64, length: UInt64) -> GuestMemoryReleaseResult {
        guard contains(guestAddress, count: length), length > 0,
              guestAddress % Self.pageSize == 0, length % Self.pageSize == 0 else { return .rejected }
        let first = Int((guestAddress - guestBase) / Self.pageSize)
        let count = Int(length / Self.pageSize)
        let host = hostBase.advanced(by: Int(guestAddress - guestBase))
        // State transition and stage-2 mutation share one lock, so a concurrent RAM fault cannot
        // observe an unmapped-but-untracked page. Reject overlap instead of issuing an ambiguous
        // unmap across a mixture of mapped and already-released pages.
        return pageStates.withLock { states -> GuestMemoryReleaseResult in
            let end = min(first + count, states.count)
            guard first < end,
                  states[first..<end].allSatisfy({ $0 == .mapped }) else { return .rejected }
            guard reclaimOperations.unmap(guestAddress, Int(length)) else {
                reclaimUnmapFailures.add(1)
                return .unmapFailed
            }

            // The VirtIO reporting contract permits the device to modify reported pages before
            // acknowledgement. If advice fails, keep the exact unmapped state so a later guest
            // fault can restore it, but do not claim those bytes as host-reclaimed.
            let reclaimed = reclaimOperations.markReusable(host, Int(length))
            for page in first..<end {
                states[page] = .released(
                    reclaimed: reclaimed,
                    requiresMarkInUse: reclaimed
                )
            }
            if reclaimed {
                releasedBytes.add(length)
            } else {
                reclaimAdviceFailures.add(1)
            }
            return reclaimed ? .reclaimed : .unmappedNotReclaimed
        }
    }

    /// Remaps a single host RAM page the guest faulted on. A stage-2 fault inside the RAM window
    /// can only mean this page was unmapped by free page reporting (nothing else touches stage-2
    /// RAM mappings), so restoring a tracked page resolves the fault. A successfully reclaimed
    /// page must first leave MADV_FREE_REUSABLE state; an advice or map failure remains tracked and
    /// returns false for the run loop to surface rather than mapping memory macOS may still reuse.
    public func restorePage(guestAddress: UInt64) -> Bool {
        guard contains(guestAddress, count: 1) else { return false }
        let pageStart = guestAddress & ~(Self.pageSize - 1)
        let index = Int((pageStart - guestBase) / Self.pageSize)
        let host = hostBase.advanced(by: Int(pageStart - guestBase))
        return pageStates.withLock { states -> Bool in
            guard index < states.count else { return false }
            // Mapped means a concurrent fault on this page already won the lock and restored it.
            // The guest retry can proceed without another stage-2 map or accounting change.
            guard case .released(let reclaimed, let requiresMarkInUse) = states[index] else {
                return true
            }
            if requiresMarkInUse {
                guard reclaimOperations.markInUse(host, Int(Self.pageSize)) else {
                    restoreAdviceFailures.add(1)
                    return false
                }
                // MADV_FREE_REUSE succeeded even if the following stage-2 map does not. Persist
                // that sub-state so a retry never repeats a one-way host advice transition.
                states[index] = .released(reclaimed: reclaimed, requiresMarkInUse: false)
            }
            guard reclaimOperations.map(host, pageStart, Int(Self.pageSize)) else {
                restoreMapFailures.add(1)
                return false
            }
            states[index] = .mapped
            if reclaimed { restoredBytes.add(Self.pageSize) }
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

    /// Produces one bounded descriptor slice over guest RAM for an isolated device worker. The
    /// file was unlinked before this object became visible, so the returned authority is path-free
    /// and disappears when the last duplicate closes.
    func duplicateSharedRegion(
        at guestAddress: UInt64,
        count: UInt64
    ) throws -> GuestMemorySharedRegion {
        let bounds = try sharedRegionBounds(at: guestAddress, count: count)
        let descriptor = try duplicateSharedBackingDescriptor()
        return GuestMemorySharedRegion(
            descriptor: descriptor,
            offset: bounds.offset,
            length: bounds.length,
            declaredFileSize: bounds.declaredFileSize
        )
    }

    func sharedRegionBounds(
        at guestAddress: UInt64,
        count: UInt64
    ) throws -> (offset: UInt64, length: UInt64, declaredFileSize: UInt64) {
        guard count > 0, contains(guestAddress, count: count) else {
            throw VMError.guestMemoryFault(address: guestAddress, count: count)
        }
        return (
            DoryGuestMemoryBackingDataOffset() + guestAddress - guestBase,
            count,
            backingDeclaredFileSize
        )
    }

    func duplicateSharedBackingDescriptor() throws -> FileHandle {
        let duplicate = fcntl(backingDescriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else {
            throw VMError.outOfMemory("cannot duplicate guest RAM authority: errno \(errno)")
        }
        guard sharedBackingDescriptorMatches(duplicate) else {
            close(duplicate)
            throw VMError.invalidConfiguration("guest RAM authority identity changed")
        }
        return FileHandle(fileDescriptor: duplicate, closeOnDealloc: true)
    }

    /// Tests and cold-path authority handoff use the same exact descriptor identity check. It
    /// rejects regular files, stale descriptors, resized objects, and another VM's same-sized RAM.
    func sharedBackingDescriptorMatches(_ descriptor: Int32) -> Bool {
        var identity = backingIdentity
        return DoryGuestMemoryBackingMatches(
            descriptor,
            backingDeclaredFileSize,
            &identity
        ) == 1
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
