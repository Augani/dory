import Foundation
import Testing
@testable import DoryHV

@Suite(.serialized) struct GuestMemoryRangeLeaseTests {
    private final class Operations: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var unmaps: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
        func unmap() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            return true
        }
    }

    private final class QueueOwner: @unchecked Sendable {
        let queue: Virtqueue
        init(_ queue: Virtqueue) { self.queue = queue }
    }

    @Test func overlappingPinsProtectWholeHostGranulesAndCloseExactlyOnce() throws {
        let operations = Operations()
        let memory = try makeMemory(operations)
        let page = memory.guestBase + HostPage.size
        let first = try memory.pinRange(at: page + 1, count: 1)
        let second = try memory.pinRange(at: page + HostPage.size - 1, count: 1)
        #expect(memory.releaseRange(guestAddress: page, length: HostPage.size) == .rejected)
        #expect(operations.unmaps == 0)
        first.close()
        first.close()
        #expect(!first.isActive)
        #expect(second.isActive)
        #expect(memory.releaseRange(guestAddress: page, length: HostPage.size) == .rejected)
        // Pins are bounded to the intersecting granules, not the whole RAM allocation.
        #expect(memory.releaseRange(guestAddress: page + HostPage.size, length: HostPage.size) == .reclaimed)
        second.close()
        #expect(memory.releaseRange(guestAddress: page, length: HostPage.size) == .reclaimed)
        #expect(operations.unmaps == 2)
    }

    @Test func batchPinFailureDoesNotLeavePartialOwnership() throws {
        let memory = try makeMemory(Operations())
        let available = memory.guestBase + HostPage.size
        let released = memory.guestBase + 3 * HostPage.size
        #expect(memory.releaseRange(guestAddress: released, length: HostPage.size) == .reclaimed)
        #expect(throws: (any Error).self) {
            _ = try memory.pinRanges([(available, 4), (released, 4)])
        }
        #expect(throws: (any Error).self) {
            _ = try memory.pinRanges([(available, 4), (UInt64.max - 1, 8)])
        }
        #expect(throws: (any Error).self) { _ = try memory.pinRange(at: available, count: 0) }
        #expect(throws: (any Error).self) { _ = try memory.pinRanges([]) }
        #expect(memory.releaseRange(guestAddress: available, length: HostPage.size) == .reclaimed)
    }

    @Test func reportingExemptionIsOneExactActivePinFromTheSameMemory() throws {
        let operations = Operations()
        let memory = try makeMemory(operations)
        let page = memory.guestBase + HostPage.size
        // Overlap inside one batch is normalized to one ownership count per granule.
        let report = try memory.pinRanges([(page, HostPage.size), (page + 8, 32)])
        let foreign = try memory.pinRange(at: page + 64, count: 1)
        #expect(memory.releaseRange(guestAddress: page, length: HostPage.size, excluding: report) == .rejected)
        let otherMemory = try makeMemory(Operations())
        let otherReport = try otherMemory.pinRange(at: page, count: HostPage.size)
        #expect(memory.releaseRange(guestAddress: page, length: HostPage.size, excluding: otherReport) == .rejected)
        foreign.close()
        #expect(memory.releaseRange(guestAddress: page, length: HostPage.size, excluding: foreign) == .rejected)
        #expect(operations.unmaps == 0)
        #expect(memory.releaseRange(guestAddress: page, length: HostPage.size, excluding: report) == .reclaimed)
        report.close()
        #expect(memory.restorePage(guestAddress: page) == .restored)
    }

    @Test func invalidRamExtentsAreRejectedBeforeMappingOrPageIndexArithmetic() throws {
        #expect(throws: (any Error).self) {
            _ = try GuestMemory(guestBase: UInt64.max - HostPage.size + 1, size: HostPage.size)
        }
        #expect(throws: (any Error).self) {
            _ = try GuestMemory(guestBase: 0xD400_0001, size: HostPage.size)
        }
        #expect(throws: (any Error).self) {
            _ = try GuestMemory(guestBase: 0, size: UInt64(Int.max) + 1)
        }
    }

    @Test func completedQueueClaimReleasesPayloadButNotLiveRingMetadata() throws {
        let operations = Operations()
        let memory = try makeMemory(operations)
        let queue = try makeQueue(memory)
        let chain = try #require(try queue.pop())
        let metadata = memory.guestBase
        let payload = memory.guestBase + HostPage.size
        #expect(memory.releaseRange(guestAddress: metadata, length: HostPage.size) == .rejected)
        #expect(memory.releaseRange(guestAddress: payload, length: HostPage.size) == .rejected)
        #expect(chain.writeBytes([1, 2, 3]) == 3)
        #expect(try queue.pushOutcome(chain, written: 3) == .published(wantsInterrupt: true))
        // Keeping the public chain value must not keep a completed DMA claim alive.
        #expect(!chain.isLeaseValid)
        #expect(!queue.isLeaseValid(chain))
        #expect(chain.writeBytes([4]) == 0)
        #expect(memory.releaseRange(guestAddress: payload, length: HostPage.size) == .reclaimed)
        #expect(memory.releaseRange(guestAddress: metadata, length: HostPage.size) == .rejected)
        #expect(queue.setReady(false))
        #expect(memory.releaseRange(guestAddress: metadata, length: HostPage.size) == .reclaimed)
    }

    @Test func destroyingQueueRevokesRetainedChainAndReleasesBothClaims() throws {
        let memory = try makeMemory(Operations())
        var queue: Virtqueue? = try makeQueue(memory)
        let chain = try #require(try queue?.pop())
        queue = nil
        #expect(!chain.isLeaseValid)
        #expect(chain.writeBytes([1]) == 0)
        #expect(memory.releaseRange(guestAddress: memory.guestBase, length: HostPage.size) == .reclaimed)
        #expect(memory.releaseRange(guestAddress: memory.guestBase + HostPage.size, length: HostPage.size) == .reclaimed)
    }

    @Test func resetJoinsActiveBufferAccessBeforeReleasingItsMemoryPin() throws {
        let memory = try makeMemory(Operations())
        let queue = try makeQueue(memory)
        let owner = QueueOwner(queue)
        let chain = try #require(try queue.pop())
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let accessDone = DispatchSemaphore(value: 0)
        let resetStarted = DispatchSemaphore(value: 0)
        let resetDone = DispatchSemaphore(value: 0)
        defer { release.signal() }
        DispatchQueue.global().async {
            _ = chain.withLeaseHeld { access in
                entered.signal()
                _ = release.wait(timeout: .now() + 3)
                _ = access.writeBytes([9])
            }
            accessDone.signal()
        }
        #expect(entered.wait(timeout: .now() + 2) == .success)
        DispatchQueue.global().async {
            resetStarted.signal()
            owner.queue.reset()
            resetDone.signal()
        }
        #expect(resetStarted.wait(timeout: .now() + 2) == .success)
        #expect(resetDone.wait(timeout: .now() + 0.05) == .timedOut)
        #expect(memory.releaseRange(guestAddress: memory.guestBase + HostPage.size, length: HostPage.size) == .rejected)
        release.signal()
        #expect(accessDone.wait(timeout: .now() + 2) == .success)
        #expect(resetDone.wait(timeout: .now() + 2) == .success)
        #expect(chain.writeBytes([2]) == 0)
        #expect(memory.releaseRange(guestAddress: memory.guestBase + HostPage.size, length: HostPage.size) == .reclaimed)
    }

    @Test func leaseRetainsRamMappingUntilItsLastReferenceIsReleased() throws {
        var memory: GuestMemory? = try makeMemory(Operations())
        weak var retainedMemory = memory
        var lease: GuestMemoryRangeLease? = try memory?.pinRange(at: 0xD400_0000, count: 1)
        memory = nil
        #expect(retainedMemory != nil)
        lease?.close()
        #expect(lease?.isActive == false)
        // Closing revokes DMA authority; retaining the opaque token conservatively retains RAM.
        #expect(retainedMemory != nil)
        lease = nil
        #expect(retainedMemory == nil)
    }

    private func makeMemory(_ operations: Operations) throws -> GuestMemory {
        try GuestMemory(
            guestBase: 0xD400_0000,
            size: 8 * HostPage.size,
            reclaimOperations: GuestMemoryReclaimOperations(
                unmap: { _, _ in operations.unmap() },
                map: { _, _, _ in true },
                markReusable: { _, _ in true },
                markInUse: { _, _ in true }
            )
        )
    }

    private func makeQueue(_ memory: GuestMemory) throws -> Virtqueue {
        let queue = Virtqueue(memory: memory)
        let descriptor = memory.guestBase + 0x100
        let available = memory.guestBase + 0x200
        let used = memory.guestBase + 0x300
        #expect(queue.configure(size: 8, descriptorTable: descriptor, availRing: available, usedRing: used))
        #expect(queue.setReady(true))
        try memory.write(memory.guestBase + HostPage.size, at: descriptor)
        try memory.write(UInt32(64), at: descriptor + 8)
        try memory.write(UInt16(2), at: descriptor + 12)
        try memory.write(UInt16(0), at: descriptor + 14)
        try memory.write(UInt16(0), at: available + 4)
        try memory.write(UInt16(1), at: available + 2)
        return queue
    }
}
