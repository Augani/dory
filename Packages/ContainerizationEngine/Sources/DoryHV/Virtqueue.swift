import Foundation
import Synchronization

/// One buffer segment of a descriptor chain, resolved to host memory.
public struct VirtqueueSegment {
    public let pointer: UnsafeMutableRawPointer
    public let length: Int
    public let isDeviceWritable: Bool
}

/// A popped descriptor chain: read segments first, then device-writable ones.
public struct VirtqueueChain {
    public let head: UInt16
    public let segments: [VirtqueueSegment]

    public var readableSegments: [VirtqueueSegment] { segments.filter { !$0.isDeviceWritable } }
    public var writableSegments: [VirtqueueSegment] { segments.filter { $0.isDeviceWritable } }
    public var hasWritableSegments: Bool { segments.contains { $0.isDeviceWritable } }

    public func readBytes(maximum: Int = Int.max) -> [UInt8] {
        var bytes = [UInt8]()
        var capacity = 0
        for segment in segments where !segment.isDeviceWritable {
            let remaining = maximum - capacity
            guard remaining > 0 else { break }
            capacity += min(segment.length, remaining)
        }
        bytes.reserveCapacity(capacity)
        for segment in segments where !segment.isDeviceWritable {
            let take = min(segment.length, maximum - bytes.count)
            guard take > 0 else { break }
            bytes.append(contentsOf: UnsafeRawBufferPointer(start: segment.pointer, count: take))
        }
        return bytes
    }

    @discardableResult
    public func writeBytes(_ bytes: [UInt8]) -> Int {
        var offset = 0
        for segment in segments where segment.isDeviceWritable {
            let take = min(segment.length, bytes.count - offset)
            guard take > 0 else { break }
            bytes[offset..<(offset + take)].withUnsafeBytes { source in
                segment.pointer.copyMemory(from: source.baseAddress!, byteCount: take)
            }
            offset += take
        }
        return offset
    }
}

/// Split virtqueue (virtio 1.x basic layout). Descriptor chains are resolved against guest RAM
/// with bounds checks on every dereference; a malformed address from the guest fails the pop
/// rather than touching host memory outside the RAM window.
///
/// Chain processing runs synchronously on the vCPU thread that kicked the queue, so guest and
/// device never race on ring indices in the single-CPU configuration; SMP adds explicit fences
/// at the used-index publish below.
public final class Virtqueue {
    public private(set) var size: UInt16 = 0
    public private(set) var ready = false
    private var descriptorTable: UInt64 = 0
    private var availRing: UInt64 = 0
    private var usedRing: UInt64 = 0
    private var lastAvailIndex: UInt16 = 0
    private var usedIndex: UInt16 = 0
    private let memory: GuestMemory

    private struct DescriptorFlags {
        static let next: UInt16 = 1
        static let write: UInt16 = 2
        static let indirect: UInt16 = 4
    }

    public init(memory: GuestMemory) {
        self.memory = memory
    }

    public func configure(size: UInt16, descriptorTable: UInt64, availRing: UInt64, usedRing: UInt64) {
        self.size = size
        self.descriptorTable = descriptorTable
        self.availRing = availRing
        self.usedRing = usedRing
    }

    public func setReady(_ isReady: Bool) {
        ready = isReady
        if isReady {
            lastAvailIndex = 0
            usedIndex = 0
        }
    }

    public func reset() {
        ready = false
        size = 0
        descriptorTable = 0
        availRing = 0
        usedRing = 0
        lastAvailIndex = 0
        usedIndex = 0
    }

    public var hasPending: Bool {
        guard ready, size > 0 else { return false }
        let availIndex = (try? memory.read(UInt16.self, at: availRing + 2)) ?? lastAvailIndex
        return availIndex != lastAvailIndex
    }

    public func pop() throws -> VirtqueueChain? {
        guard ready, size > 0 else { return nil }
        let availIndex = try memory.read(UInt16.self, at: availRing + 2)
        guard availIndex != lastAvailIndex else { return nil }

        let slot = UInt64(lastAvailIndex % size)
        let head = try memory.read(UInt16.self, at: availRing + 4 + slot * 2)
        lastAvailIndex &+= 1

        var segments = [VirtqueueSegment]()
        try walkChain(startingAt: head, table: descriptorTable, tableSize: size, into: &segments, depth: 0)
        return VirtqueueChain(head: head, segments: segments)
    }

    private func walkChain(
        startingAt first: UInt16,
        table: UInt64,
        tableSize: UInt16,
        into segments: inout [VirtqueueSegment],
        depth: Int
    ) throws {
        guard depth < 4 else {
            throw VMError.unexpectedExit("virtqueue indirect descriptor nesting too deep")
        }
        var index = first
        var hops = 0
        while true {
            guard hops <= Int(tableSize), index < tableSize else {
                throw VMError.unexpectedExit("virtqueue descriptor chain out of bounds")
            }
            hops += 1
            let base = table + UInt64(index) * 16
            let address = try memory.read(UInt64.self, at: base)
            let length = try memory.read(UInt32.self, at: base + 8)
            let flags = try memory.read(UInt16.self, at: base + 12)
            let next = try memory.read(UInt16.self, at: base + 14)

            if flags & DescriptorFlags.indirect != 0 {
                let entries = UInt16(length / 16)
                try walkChain(startingAt: 0, table: address, tableSize: entries, into: &segments, depth: depth + 1)
            } else if length > 0 {
                let pointer = try memory.hostPointer(at: address, count: UInt64(length))
                segments.append(VirtqueueSegment(
                    pointer: pointer,
                    length: Int(length),
                    isDeviceWritable: flags & DescriptorFlags.write != 0
                ))
            }

            if flags & DescriptorFlags.indirect != 0 || flags & DescriptorFlags.next == 0 { break }
            index = next
        }
    }

    /// Returns whether the guest asked for an interrupt for this completion.
    @discardableResult
    public func push(_ chain: VirtqueueChain, written: Int) throws -> Bool {
        guard ready, size > 0 else { return false }
        let slot = UInt64(usedIndex % size)
        try memory.write(UInt32(chain.head), at: usedRing + 4 + slot * 8)
        try memory.write(UInt32(written), at: usedRing + 8 + slot * 8)
        usedIndex &+= 1
        OSMemoryBarrier()  // used entries visible before the index publish
        try memory.write(usedIndex, at: usedRing + 2)
        let availFlags = try memory.read(UInt16.self, at: availRing)
        return availFlags & 1 == 0  // VRING_AVAIL_F_NO_INTERRUPT
    }
}

extension VirtqueueSegment: @unchecked Sendable {}
extension VirtqueueChain: @unchecked Sendable {}
extension Virtqueue: @unchecked Sendable {}
