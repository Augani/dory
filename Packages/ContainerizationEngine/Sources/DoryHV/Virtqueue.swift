import Foundation
import Synchronization

/// Transport-wide split-ring features implemented by the queue parser.
public enum VirtqueueFeature {
    /// VIRTIO_RING_F_INDIRECT_DESC, virtio 1.2 section 2.7.5.3.
    public static let indirectDescriptors: UInt64 = 1 << 28
    /// VIRTIO_F_VERSION_1. Virtio-MMIO v2 devices reject negotiation without this feature.
    public static let version1: UInt64 = 1 << 32
}

/// Opaque identity for the exact queue configuration that produced a descriptor chain.
///
/// Retaining a chain is safe only while this token is still current. Reset, QueueReady changes,
/// layout reconfiguration, and negotiated-feature changes all revoke previously issued tokens.
public struct VirtqueueLease: Equatable, Hashable, Sendable {
    fileprivate let queueIdentity: UUID
    public let generation: UInt64
}

private struct VirtqueueLeaseState: Sendable {
    var queueIdentity: UUID
    var generation: UInt64
}

private final class VirtqueueLeaseAuthority: Sendable {
    private let state = Mutex(VirtqueueLeaseState(queueIdentity: UUID(), generation: 1))

    var current: VirtqueueLease {
        state.withLock {
            VirtqueueLease(queueIdentity: $0.queueIdentity, generation: $0.generation)
        }
    }

    func invalidate() {
        state.withLock {
            if $0.generation == UInt64.max {
                $0.queueIdentity = UUID()
                $0.generation = 1
            } else {
                $0.generation += 1
            }
        }
    }

    func validates(_ lease: VirtqueueLease) -> Bool {
        state.withLock {
            $0.queueIdentity == lease.queueIdentity && $0.generation == lease.generation
        }
    }

    /// Executes synchronous guest-memory access while preventing reset/reconfiguration from
    /// revoking this lease. The body must not escape a pointer or segment beyond the call.
    func withValidLease<Result>(
        _ lease: VirtqueueLease,
        _ body: () throws -> Result
    ) rethrows -> Result? {
        try state.withLock {
            guard $0.queueIdentity == lease.queueIdentity,
                  $0.generation == lease.generation else { return nil }
            return try body()
        }
    }
}

/// One buffer segment of a descriptor chain, resolved to host memory.
public struct VirtqueueSegment {
    public let pointer: UnsafeMutableRawPointer
    public let length: Int
    public let isDeviceWritable: Bool
}

/// A synchronous, lease-held view of one descriptor chain.
///
/// Instances are created only by `VirtqueueChain.withLeaseHeld`. Raw segments must not escape the
/// callback: reset/reconfiguration is blocked only until that callback returns. The type is
/// deliberately not `Sendable`, as its storage is guest-owned mutable memory.
struct VirtqueueLeaseAccess {
    fileprivate let resolvedSegments: [VirtqueueSegment]

    /// Module-internal raw view for zero-copy device backends. Its validity is bounded by the
    /// surrounding `withLeaseHeld` callback.
    var segments: [VirtqueueSegment] { resolvedSegments }

    var readableSegments: [VirtqueueSegment] {
        resolvedSegments.filter { !$0.isDeviceWritable }
    }

    var writableSegments: [VirtqueueSegment] {
        resolvedSegments.filter(\.isDeviceWritable)
    }

    var hasWritableSegments: Bool {
        resolvedSegments.contains(where: \.isDeviceWritable)
    }

    var readableSegmentCount: Int {
        resolvedSegments.lazy.filter { !$0.isDeviceWritable }.count
    }

    var writableSegmentCount: Int {
        resolvedSegments.lazy.filter(\.isDeviceWritable).count
    }

    var readableByteCount: Int {
        byteCount(deviceWritable: false)
    }

    var writableByteCount: Int {
        byteCount(deviceWritable: true)
    }

    private func byteCount(deviceWritable: Bool) -> Int {
        var total = 0
        for segment in resolvedSegments where segment.isDeviceWritable == deviceWritable {
            let (next, overflow) = total.addingReportingOverflow(segment.length)
            guard segment.length >= 0, !overflow else { return 0 }
            total = next
        }
        return total
    }

    func readBytes(maximum: Int = Int.max) -> [UInt8] {
        copyBytes(deviceWritable: false, maximum: maximum)
    }

    /// Copies an already-encoded response while the queue lease is held. Async backends use this
    /// host-owned snapshot to roll back grants after reset without rereading a repurposed buffer.
    func copyWritableBytes(maximum: Int = Int.max) -> [UInt8] {
        copyBytes(deviceWritable: true, maximum: maximum)
    }

    private func copyBytes(deviceWritable: Bool, maximum: Int) -> [UInt8] {
        guard maximum > 0 else { return [] }
        var bytes = [UInt8]()
        var capacity = 0
        for segment in resolvedSegments where segment.isDeviceWritable == deviceWritable {
            guard segment.length >= 0, capacity <= maximum else { return [] }
            let remaining = maximum - capacity
            guard remaining > 0 else { break }
            let take = min(segment.length, remaining)
            let (nextCapacity, overflow) = capacity.addingReportingOverflow(take)
            guard !overflow else { return [] }
            capacity = nextCapacity
        }
        bytes.reserveCapacity(capacity)
        for segment in resolvedSegments where segment.isDeviceWritable == deviceWritable {
            guard segment.length >= 0, bytes.count <= maximum else { return [] }
            let take = min(segment.length, maximum - bytes.count)
            guard take > 0 else { break }
            bytes.append(contentsOf: UnsafeRawBufferPointer(start: segment.pointer, count: take))
        }
        return bytes
    }

    @discardableResult
    func writeBytes(_ bytes: [UInt8]) -> Int {
        writeBytes(bytes, atWritableOffset: 0)
    }

    @discardableResult
    func writeBytes(_ bytes: [UInt8], atWritableOffset requestedOffset: Int) -> Int {
        guard requestedOffset >= 0 else { return 0 }
        var sourceOffset = 0
        var writableOffset = 0
        for segment in resolvedSegments where segment.isDeviceWritable {
            guard segment.length >= 0 else { return sourceOffset }
            let (segmentEnd, overflow) = writableOffset.addingReportingOverflow(segment.length)
            guard !overflow else { return sourceOffset }
            if segmentEnd <= requestedOffset {
                writableOffset = segmentEnd
                continue
            }
            let destinationOffset = max(0, requestedOffset - writableOffset)
            let available = segment.length - destinationOffset
            let take = min(available, bytes.count - sourceOffset)
            guard take > 0 else { break }
            bytes[sourceOffset..<(sourceOffset + take)].withUnsafeBytes { source in
                segment.pointer.advanced(by: destinationOffset).copyMemory(
                    from: source.baseAddress!,
                    byteCount: take
                )
            }
            sourceOffset += take
            writableOffset = segmentEnd
        }
        return sourceOffset
    }
}

/// A popped descriptor chain in the exact order supplied by the guest.
///
/// Protocol backends must validate any required readable-prefix/writable-suffix layout; the
/// queue parser deliberately preserves mixed or reversed direction changes so they cannot be
/// normalized into an apparently valid request.
public struct VirtqueueChain: @unchecked Sendable {
    public let head: UInt16
    public let lease: VirtqueueLease
    /// True when the raw descriptor walk encountered a zero-length data descriptor. The queue
    /// parser preserves its historical nonzero segment view, while protocol frontends that require
    /// every descriptor to carry data can reject the original chain without guessing.
    public let containsZeroLengthDescriptor: Bool
    private let resolvedSegments: [VirtqueueSegment]
    private let leaseAuthority: VirtqueueLeaseAuthority

    fileprivate init(
        head: UInt16,
        segments: [VirtqueueSegment],
        containsZeroLengthDescriptor: Bool,
        lease: VirtqueueLease,
        leaseAuthority: VirtqueueLeaseAuthority
    ) {
        self.head = head
        self.resolvedSegments = segments
        self.containsZeroLengthDescriptor = containsZeroLengthDescriptor
        self.lease = lease
        self.leaseAuthority = leaseAuthority
    }

    public var isLeaseValid: Bool { leaseAuthority.validates(lease) }

    public var hasWritableSegments: Bool {
        withLeaseHeld(\.hasWritableSegments) ?? false
    }

    public var readableSegmentCount: Int {
        withLeaseHeld(\.readableSegmentCount) ?? 0
    }

    public var writableSegmentCount: Int {
        withLeaseHeld(\.writableSegmentCount) ?? 0
    }

    public var readableByteCount: Int {
        withLeaseHeld(\.readableByteCount) ?? 0
    }

    public var writableByteCount: Int {
        withLeaseHeld(\.writableByteCount) ?? 0
    }

    /// Runs synchronous guest-buffer work under the queue's lifecycle lease. Reset,
    /// QueueReady changes, feature renegotiation, and layout reconfiguration wait for this body to
    /// finish before revoking the chain. The body must not escape `VirtqueueLeaseAccess` or any raw
    /// segment/pointer obtained from it.
    func withLeaseHeld<Result>(
        _ body: (VirtqueueLeaseAccess) throws -> Result
    ) rethrows -> Result? {
        try leaseAuthority.withValidLease(lease) {
            try body(VirtqueueLeaseAccess(resolvedSegments: resolvedSegments))
        }
    }

    public func readBytes(maximum: Int = Int.max) -> [UInt8] {
        withLeaseHeld { $0.readBytes(maximum: maximum) } ?? []
    }

    @discardableResult
    public func writeBytes(_ bytes: [UInt8]) -> Int {
        writeBytes(bytes, atWritableOffset: 0)
    }

    /// Writes into the concatenated device-writable portion of the chain at a byte offset.
    /// Virtio protocols such as virtio-snd place a writable PCM payload before a writable status
    /// structure, so the device must address the latter without overwriting the former.
    @discardableResult
    public func writeBytes(_ bytes: [UInt8], atWritableOffset requestedOffset: Int) -> Int {
        withLeaseHeld {
            $0.writeBytes(bytes, atWritableOffset: requestedOffset)
        } ?? 0
    }
}

/// Exact result of attempting to publish a used-ring completion. A revoked chain is a lifecycle
/// outcome, not the same thing as a successfully published completion that suppressed interrupts.
public enum VirtqueuePushOutcome: Equatable, Sendable {
    case published(wantsInterrupt: Bool)
    case revoked
}

/// Host-side complexity and memory limits applied while resolving one descriptor chain.
///
/// These are deliberately independent of protocol-specific limits. A backend may impose a much
/// smaller request size after parsing, while this boundary prevents malformed guest rings from
/// creating unbounded descriptor walks, segment arrays, or host allocations first.
public struct VirtqueueLimits: Equatable, Sendable {
    public static let hardenedDefault = VirtqueueLimits()

    public var maximumDescriptorCount: UInt64
    public var maximumSegmentCount: UInt64
    public var maximumSegmentBytes: UInt64
    public var maximumTotalBytes: UInt64

    public init(
        maximumDescriptorCount: UInt64 = 512,
        maximumSegmentCount: UInt64 = 256,
        maximumSegmentBytes: UInt64 = 64 * 1_024 * 1_024,
        maximumTotalBytes: UInt64 = 64 * 1_024 * 1_024
    ) {
        self.maximumDescriptorCount = maximumDescriptorCount
        self.maximumSegmentCount = maximumSegmentCount
        self.maximumSegmentBytes = maximumSegmentBytes
        self.maximumTotalBytes = maximumTotalBytes
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
    public static let maximumSize: UInt64 = 256

    public private(set) var size: UInt16 = 0
    public private(set) var ready = false
    public private(set) var negotiatedFeatures: UInt64 = 0
    private var descriptorTable: UInt64 = 0
    private var availRing: UInt64 = 0
    private var usedRing: UInt64 = 0
    private var lastAvailIndex: UInt16 = 0
    private var usedIndex: UInt16 = 0
    private let memory: GuestMemory
    private let limits: VirtqueueLimits
    private let leaseAuthority = VirtqueueLeaseAuthority()

    private struct DescriptorFlags {
        static let next: UInt16 = 1
        static let write: UInt16 = 2
        static let indirect: UInt16 = 4
        static let known = next | write | indirect
    }

    private struct TraversalState {
        var descriptorCount: UInt64 = 0
        var segmentCount: UInt64 = 0
        var totalBytes: UInt64 = 0
        var containsZeroLengthDescriptor = false

        mutating func recordDescriptor(limits: VirtqueueLimits) throws {
            guard descriptorCount < limits.maximumDescriptorCount else {
                throw VMError.unexpectedExit("virtqueue descriptor limit exceeded")
            }
            descriptorCount += 1
        }

        mutating func recordSegment(byteCount: UInt64, limits: VirtqueueLimits) throws {
            guard segmentCount < limits.maximumSegmentCount else {
                throw VMError.unexpectedExit("virtqueue segment limit exceeded")
            }
            guard byteCount <= limits.maximumSegmentBytes else {
                throw VMError.unexpectedExit("virtqueue segment byte limit exceeded")
            }
            let (nextTotal, overflow) = totalBytes.addingReportingOverflow(byteCount)
            guard !overflow, nextTotal <= limits.maximumTotalBytes else {
                throw VMError.unexpectedExit("virtqueue total byte limit exceeded")
            }
            segmentCount += 1
            totalBytes = nextTotal
        }
    }

    public init(memory: GuestMemory, limits: VirtqueueLimits = .hardenedDefault) {
        self.memory = memory
        self.limits = limits
    }

    public var currentLease: VirtqueueLease { leaseAuthority.current }
    public var generation: UInt64 { currentLease.generation }

    public func isLeaseValid(_ lease: VirtqueueLease) -> Bool {
        leaseAuthority.validates(lease)
    }

    public func isLeaseValid(_ chain: VirtqueueChain) -> Bool {
        isLeaseValid(chain.lease)
    }

    /// Applies the transport-negotiated ring features and revokes chains parsed under an older
    /// feature contract. Unsupported backend-specific bits are harmless to this parser.
    public func setNegotiatedFeatures(_ features: UInt64) {
        guard negotiatedFeatures != features else { return }
        leaseAuthority.invalidate()
        negotiatedFeatures = features
    }

    /// Applies one complete split-ring layout. Invalid guest layouts leave the queue disabled.
    @discardableResult
    public func configure(
        untrustedSize requestedSize: UInt64,
        descriptorTable: UInt64,
        availRing: UInt64,
        usedRing: UInt64
    ) -> Bool {
        leaseAuthority.invalidate()
        guard let size = UInt16(exactly: requestedSize),
              Self.isValidSize(requestedSize),
              descriptorTable % 16 == 0,
              availRing % 2 == 0,
              usedRing % 4 == 0,
              let descriptorBytes = Self.multiplied(requestedSize, by: 16),
              let availElementsBytes = Self.multiplied(requestedSize, by: 2),
              let availBytes = Self.added(4, to: availElementsBytes),
              let usedElementsBytes = Self.multiplied(requestedSize, by: 8),
              let usedBytes = Self.added(4, to: usedElementsBytes),
              memory.contains(descriptorTable, count: descriptorBytes),
              memory.contains(availRing, count: availBytes),
              memory.contains(usedRing, count: usedBytes) else {
            invalidateConfiguration()
            return false
        }
        self.size = size
        self.descriptorTable = descriptorTable
        self.availRing = availRing
        self.usedRing = usedRing
        return true
    }

    /// Source-compatible entry point for trusted callers that already hold the transport-sized
    /// queue value. It still runs every layout and power-of-two validation above.
    @discardableResult
    public func configure(
        size: UInt16,
        descriptorTable: UInt64,
        availRing: UInt64,
        usedRing: UInt64
    ) -> Bool {
        configure(
            untrustedSize: UInt64(size),
            descriptorTable: descriptorTable,
            availRing: availRing,
            usedRing: usedRing
        )
    }

    @discardableResult
    public func setReady(_ isReady: Bool) -> Bool {
        leaseAuthority.invalidate()
        guard !isReady || Self.isValidSize(UInt64(size)) else {
            ready = false
            return false
        }
        ready = isReady
        if isReady {
            lastAvailIndex = 0
            usedIndex = 0
        }
        return true
    }

    public func reset() {
        leaseAuthority.invalidate()
        negotiatedFeatures = 0
        invalidateConfiguration()
    }

    private func invalidateConfiguration() {
        ready = false
        size = 0
        descriptorTable = 0
        availRing = 0
        usedRing = 0
        lastAvailIndex = 0
        usedIndex = 0
    }

    public var hasPending: Bool {
        ((try? pendingCount()) ?? 0) > 0
    }

    /// Returns the validated number of available entries. Unlike the compatibility `hasPending`
    /// property, this preserves malformed ring state as an error for hardened device backends.
    public func pendingCount() throws -> UInt16 {
        guard ready, size > 0 else { return 0 }
        let indexAddress = try checkedAdd(availRing, 2, "available-index address")
        let availIndex = try memory.read(UInt16.self, at: indexAddress)
        let pending = availIndex &- lastAvailIndex
        guard pending <= size else {
            throw VMError.unexpectedExit("virtqueue available ring overrun")
        }
        return pending
    }

    /// Resolves the next available descriptor without consuming it.
    ///
    /// Device backends use this to classify a request before crossing a publication boundary. The
    /// caller must serialize the peek with `pop()` and queue reconfiguration, exactly as it would
    /// any other ring access.
    public func peek() throws -> VirtqueueChain? {
        try nextChain(consume: false)
    }

    public func pop() throws -> VirtqueueChain? {
        try nextChain(consume: true)
    }

    private func nextChain(consume: Bool) throws -> VirtqueueChain? {
        guard ready, size > 0 else { return nil }
        let lease = currentLease
        let availIndexAddress = try checkedAdd(availRing, 2, "available-index address")
        let availIndex = try memory.read(UInt16.self, at: availIndexAddress)
        let pending = availIndex &- lastAvailIndex
        guard pending > 0 else { return nil }
        guard pending <= size else {
            throw VMError.unexpectedExit("virtqueue available ring overrun")
        }

        let slot = UInt64(lastAvailIndex % size)
        let slotOffset = try checkedMultiply(slot, 2, "available-ring slot offset")
        let ringOffset = try checkedAdd(4, slotOffset, "available-ring element offset")
        let headAddress = try checkedAdd(availRing, ringOffset, "available-ring element address")
        let head = try memory.read(UInt16.self, at: headAddress)
        if consume {
            lastAvailIndex &+= 1
        }

        var segments = [VirtqueueSegment]()
        var traversal = TraversalState()
        try walkChain(
            startingAt: head,
            table: descriptorTable,
            tableSize: UInt64(size),
            into: &segments,
            insideIndirectTable: false,
            traversal: &traversal
        )
        guard isLeaseValid(lease) else {
            throw VMError.unexpectedExit("virtqueue changed while resolving descriptor chain")
        }
        return VirtqueueChain(
            head: head,
            segments: segments,
            containsZeroLengthDescriptor: traversal.containsZeroLengthDescriptor,
            lease: lease,
            leaseAuthority: leaseAuthority
        )
    }

    private func walkChain(
        startingAt first: UInt16,
        table: UInt64,
        tableSize: UInt64,
        into segments: inout [VirtqueueSegment],
        insideIndirectTable: Bool,
        traversal: inout TraversalState
    ) throws {
        guard tableSize > 0 else {
            throw VMError.unexpectedExit("virtqueue descriptor table is empty")
        }
        var index = UInt64(first)
        var hops: UInt64 = 0
        while true {
            guard hops < tableSize, index < tableSize else {
                throw VMError.unexpectedExit("virtqueue descriptor chain out of bounds")
            }
            hops += 1
            try traversal.recordDescriptor(limits: limits)
            let descriptorOffset = try checkedMultiply(index, 16, "descriptor-table offset")
            let base = try checkedAdd(table, descriptorOffset, "descriptor address")
            let address = try memory.read(UInt64.self, at: base)
            let length = try memory.read(
                UInt32.self,
                at: checkedAdd(base, 8, "descriptor length address")
            )
            let flags = try memory.read(
                UInt16.self,
                at: checkedAdd(base, 12, "descriptor flags address")
            )
            let next = try memory.read(
                UInt16.self,
                at: checkedAdd(base, 14, "descriptor next address")
            )
            guard flags & ~DescriptorFlags.known == 0 else {
                throw VMError.unexpectedExit("virtqueue descriptor contains unknown flags")
            }

            if flags & DescriptorFlags.indirect != 0 {
                guard negotiatedFeatures & VirtqueueFeature.indirectDescriptors != 0 else {
                    throw VMError.unexpectedExit(
                        "virtqueue indirect descriptor feature was not negotiated"
                    )
                }
                guard !insideIndirectTable else {
                    throw VMError.unexpectedExit("virtqueue nested indirect descriptor")
                }
                guard flags & DescriptorFlags.next == 0 else {
                    throw VMError.unexpectedExit("virtqueue indirect descriptor also sets NEXT")
                }
                guard length > 0, length % 16 == 0, address % 16 == 0 else {
                    throw VMError.unexpectedExit("virtqueue indirect table has invalid layout")
                }
                let entryCount = UInt64(length) / 16
                guard entryCount <= limits.maximumDescriptorCount else {
                    throw VMError.unexpectedExit("virtqueue indirect table exceeds descriptor limit")
                }
                _ = try memory.hostPointer(at: address, count: UInt64(length))
                try walkChain(
                    startingAt: 0,
                    table: address,
                    tableSize: entryCount,
                    into: &segments,
                    insideIndirectTable: true,
                    traversal: &traversal
                )
                break
            } else {
                if length == 0 {
                    traversal.containsZeroLengthDescriptor = true
                } else {
                    let byteCount = UInt64(length)
                    try traversal.recordSegment(byteCount: byteCount, limits: limits)
                    guard let hostLength = Int(exactly: length) else {
                        throw VMError.unexpectedExit("virtqueue segment length is not host-representable")
                    }
                    let pointer = try memory.hostPointer(at: address, count: UInt64(length))
                    segments.append(VirtqueueSegment(
                        pointer: pointer,
                        length: hostLength,
                        isDeviceWritable: flags & DescriptorFlags.write != 0
                    ))
                }
            }

            guard flags & DescriptorFlags.next != 0 else { break }
            index = UInt64(next)
        }
    }

    /// Returns whether the guest asked for an interrupt for this completion.
    @discardableResult
    public func push(_ chain: VirtqueueChain, written: Int) throws -> Bool {
        switch try pushOutcome(chain, written: written) {
        case .published(let wantsInterrupt): return wantsInterrupt
        case .revoked: return false
        }
    }

    /// Publishes one used-ring completion while preserving lifecycle revocation as a typed outcome.
    /// New asynchronous backends should use this API so reset/reconfiguration is observable rather
    /// than conflated with `VRING_AVAIL_F_NO_INTERRUPT`.
    public func pushOutcome(
        _ chain: VirtqueueChain,
        written: Int
    ) throws -> VirtqueuePushOutcome {
        // A backend may finish after the guest resets or reconfigures the queue.  Preserve the
        // safe no-op completion contract while refusing to publish that obsolete chain into either
        // the replacement queue or a different queue. The typed API exposes that revocation.
        let publication = try leaseAuthority.withValidLease(chain.lease) {
            guard ready, size > 0 else { return false }
            guard let written = UInt32(exactly: written) else {
                throw VMError.unexpectedExit("virtqueue used length is not representable")
            }
            let slot = UInt64(usedIndex % size)
            let slotOffset = try checkedMultiply(slot, 8, "used-ring slot offset")
            let elementOffset = try checkedAdd(4, slotOffset, "used-ring element offset")
            let elementAddress = try checkedAdd(usedRing, elementOffset, "used-ring element address")
            try memory.write(UInt32(chain.head), at: elementAddress)
            try memory.write(written, at: checkedAdd(elementAddress, 4, "used-ring length address"))
            usedIndex &+= 1
            OSMemoryBarrier()  // used entries visible before the index publish
            try memory.write(usedIndex, at: checkedAdd(usedRing, 2, "used-index address"))
            let availFlags = try memory.read(UInt16.self, at: availRing)
            return availFlags & 1 == 0  // VRING_AVAIL_F_NO_INTERRUPT
        }
        guard let publication else { return .revoked }
        return .published(wantsInterrupt: publication)
    }

    private static func isValidSize(_ size: UInt64) -> Bool {
        size > 0 && size <= maximumSize && size & (size - 1) == 0
    }

    private static func added(_ lhs: UInt64, to rhs: UInt64) -> UInt64? {
        let (result, overflow) = rhs.addingReportingOverflow(lhs)
        return overflow ? nil : result
    }

    private static func multiplied(_ lhs: UInt64, by rhs: UInt64) -> UInt64? {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? nil : result
    }

    private func checkedAdd(_ lhs: UInt64, _ rhs: UInt64, _ context: String) throws -> UInt64 {
        guard let result = Self.added(rhs, to: lhs) else {
            throw VMError.unexpectedExit("virtqueue \(context) overflow")
        }
        return result
    }

    private func checkedMultiply(_ lhs: UInt64, _ rhs: UInt64, _ context: String) throws -> UInt64 {
        guard let result = Self.multiplied(lhs, by: rhs) else {
            throw VMError.unexpectedExit("virtqueue \(context) overflow")
        }
        return result
    }
}

extension Virtqueue: @unchecked Sendable {}
