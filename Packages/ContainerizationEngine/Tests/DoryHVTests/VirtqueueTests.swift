import Foundation
import Testing
@testable import DoryHV

/// Exercises the split-virtqueue descriptor walk and used-ring publish directly against a
/// GuestMemory mmap. No hypervisor is involved: GuestMemory is a plain anonymous region and the
/// Virtqueue only reads/writes guest addresses, so this runs anywhere.
@Suite struct VirtqueueTests {
    private let base: UInt64 = 0x8000_0000
    private let descTable: UInt64 = 0x8000_1000
    private let availRing: UInt64 = 0x8000_2000
    private let usedRing: UInt64 = 0x8000_3000
    private let dataOut: UInt64 = 0x8000_4000
    private let dataIn: UInt64 = 0x8000_5000

    private func makeMemory() throws -> GuestMemory {
        try GuestMemory(guestBase: base, size: 64 * HostPage.size)
    }

    private func writeDescriptor(_ memory: GuestMemory, index: UInt64, addr: UInt64, len: UInt32, flags: UInt16, next: UInt16) throws {
        let d = descTable + index * 16
        try memory.write(addr, at: d)
        try memory.write(len, at: d + 8)
        try memory.write(flags, at: d + 12)
        try memory.write(next, at: d + 14)
    }

    @Test func popResolvesAChainAndPushPublishesUsed() throws {
        let memory = try makeMemory()
        let queue = Virtqueue(memory: memory)
        queue.configure(size: 8, descriptorTable: descTable, availRing: availRing, usedRing: usedRing)
        queue.setReady(true)

        // One readable descriptor (device reads it) chained to one writable descriptor.
        try writeDescriptor(memory, index: 0, addr: dataOut, len: 4, flags: 0x1, next: 1)  // NEXT
        try writeDescriptor(memory, index: 1, addr: dataIn, len: 8, flags: 0x2, next: 0)   // WRITE
        try memory.write([0xDE, 0xAD, 0xBE, 0xEF], at: dataOut)

        // avail ring: flags(2) idx(2) then ring[]; publish head 0 at slot 0, idx=1.
        try memory.write(UInt16(0), at: availRing)       // flags
        try memory.write(UInt16(0), at: availRing + 4)   // ring[0] = descriptor head 0
        try memory.write(UInt16(1), at: availRing + 2)   // idx = 1

        #expect(queue.hasPending)
        let chain = try #require(try queue.pop())
        #expect(chain.head == 0)
        #expect(chain.readableSegments.count == 1)
        #expect(chain.writableSegments.count == 1)
        #expect(chain.readBytes() == [0xDE, 0xAD, 0xBE, 0xEF])

        let wrote = chain.writeBytes([1, 2, 3, 4, 5])
        #expect(wrote == 5)
        #expect(try memory.readBytes(at: dataIn, count: 5) == [1, 2, 3, 4, 5])

        // Publishing marks the used ring: idx advances and the element records head 0 + written.
        try queue.push(chain, written: 5)
        #expect(try memory.read(UInt16.self, at: usedRing + 2) == 1)     // used idx
        #expect(try memory.read(UInt32.self, at: usedRing + 4) == 0)     // used elem id = head
        #expect(try memory.read(UInt32.self, at: usedRing + 8) == 5)     // used elem len
        #expect(try queue.pop() == nil)                                  // ring drained
    }

    @Test func pushIsSafeAfterResetToZeroSize() throws {
        let memory = try makeMemory()
        let queue = Virtqueue(memory: memory)
        queue.configure(size: 8, descriptorTable: descTable, availRing: availRing, usedRing: usedRing)
        queue.setReady(true)
        try writeDescriptor(memory, index: 0, addr: dataIn, len: 8, flags: 0x2, next: 0)
        try memory.write(UInt16(0), at: availRing)
        try memory.write(UInt16(0), at: availRing + 4)
        try memory.write(UInt16(1), at: availRing + 2)
        let chain = try #require(try queue.pop())

        queue.reset()  // guest resets the ring mid-flight (size -> 0)
        // push must not divide by zero; it returns false rather than trapping.
        #expect(try queue.push(chain, written: 0) == false)
    }

    @Test func rejectsOutOfBoundsDescriptorChain() throws {
        let memory = try makeMemory()
        let queue = Virtqueue(memory: memory)
        queue.configure(size: 4, descriptorTable: descTable, availRing: availRing, usedRing: usedRing)
        queue.setReady(true)
        // head points past the table size.
        try memory.write(UInt16(0), at: availRing)
        try memory.write(UInt16(99), at: availRing + 4)
        try memory.write(UInt16(1), at: availRing + 2)
        #expect(throws: (any Error).self) { _ = try queue.pop() }
    }
}

@Suite struct GuestMemoryReclaimGuardTests {
    @Test func releaseRangeRejectsUnalignedAndOutOfBounds() throws {
        let memory = try GuestMemory(guestBase: 0x8000_0000, size: 64 * HostPage.size)
        // Unaligned start.
        #expect(!memory.releaseRange(guestAddress: 0x8000_0001, length: HostPage.size))
        // Unaligned length.
        #expect(!memory.releaseRange(guestAddress: 0x8000_0000, length: HostPage.size / 2))
        // Out of bounds.
        #expect(!memory.releaseRange(guestAddress: 0x9000_0000, length: HostPage.size))
    }

    @Test func restorePageNeverDoubleCountsOrTouchesOutOfRange() throws {
        let memory = try GuestMemory(guestBase: 0x8000_0000, size: 64 * HostPage.size)
        // Outside RAM is a genuine fault the caller must surface: false, no counters moved.
        #expect(!memory.restorePage(guestAddress: 0x7000_0000))
        // An in-RAM page whose released-bit is clear was never unmapped (the releaseRange lock
        // makes "unmapped implies bit set" an invariant), so this is a benign no-op: it reports
        // success (the guest retry resolves) but must NOT charge a restore.
        #expect(memory.restorePage(guestAddress: 0x8000_0000 + HostPage.size))
        #expect(memory.releasedBytes.load(ordering: .relaxed) == 0)
        #expect(memory.restoredBytes.load(ordering: .relaxed) == 0)
    }
}
