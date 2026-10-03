import Foundation
import Testing
@testable import DoryHV

@Suite(.serialized) struct VirtqueuePreviewPinTests {
    private final class QueueOwner: @unchecked Sendable {
        let queue: Virtqueue
        init(_ queue: Virtqueue) { self.queue = queue }
    }

    private final class PopResult: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: VirtqueueChain?
        func record(_ chain: VirtqueueChain?) {
            lock.lock()
            stored = chain
            lock.unlock()
        }
        var chain: VirtqueueChain? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    private func makeMemory() throws -> GuestMemory {
        try GuestMemory(
            guestBase: 0xD500_0000,
            size: 4 * HostPage.size,
            reclaimOperations: GuestMemoryReclaimOperations(
                unmap: { _, _ in true }, map: { _, _, _ in true },
                markReusable: { _, _ in true }, markInUse: { _, _ in true }
            )
        )
    }

    private func makeQueue(_ memory: GuestMemory) throws -> Virtqueue {
        let queue = Virtqueue(memory: memory)
        let base = memory.guestBase
        #expect(queue.configure(
            size: 8, descriptorTable: base, availRing: base + 0x100, usedRing: base + 0x200
        ))
        #expect(queue.setReady(true))
        try memory.write(base + HostPage.size, at: base)
        try memory.write(UInt32(8), at: base + 8)
        try memory.write(UInt16(2), at: base + 12)
        try memory.write(UInt16(0), at: base + 14)
        try memory.write(UInt16(0), at: base + 0x104)
        try memory.write(UInt16(1), at: base + 0x102)
        return queue
    }

    @Test(arguments: ["reset", "not-ready", "features", "configure"])
    func lifecycleChangeRetiresRetainedPreviewPins(change: String) throws {
        let memory = try makeMemory()
        let queue = try makeQueue(memory)
        defer { queue.reset() }
        let preview = try #require(try queue.peek())
        let payload = memory.guestBase + HostPage.size
        #expect(memory.releaseRange(guestAddress: payload, length: HostPage.size) == .rejected)
        switch change {
        case "reset": queue.reset()
        case "not-ready": #expect(queue.setReady(false))
        case "features": queue.setNegotiatedFeatures(VirtqueueFeature.indirectDescriptors)
        case "configure":
            #expect(queue.configure(
                size: 8, descriptorTable: memory.guestBase,
                availRing: memory.guestBase + 0x100, usedRing: memory.guestBase + 0x200
            ))
        default: Issue.record("unknown preview lifecycle fixture \(change)")
        }
        #expect(!preview.isLeaseValid)
        #expect(preview.writeBytes([1]) == 0)
        #expect(memory.releaseRange(guestAddress: payload, length: HostPage.size) == .reclaimed)
    }

    @Test func destroyingQueueRetiresRetainedPreviewPin() throws {
        let memory = try makeMemory()
        var queue: Virtqueue? = try makeQueue(memory)
        weak var retiredQueue = queue
        let preview = try #require(try queue?.peek())
        queue = nil
        #expect(retiredQueue == nil)
        #expect(!preview.isLeaseValid)
        #expect(preview.writeBytes([1]) == 0)
        #expect(memory.releaseRange(
            guestAddress: memory.guestBase + HostPage.size, length: HostPage.size
        ) == .reclaimed)
        #expect(memory.releaseRange(
            guestAddress: memory.guestBase, length: HostPage.size
        ) == .reclaimed)
    }

    @Test func repeatedLivePeeksRemainUsableUntilPopRetiresEveryPreview() throws {
        let memory = try makeMemory()
        let queue = try makeQueue(memory)
        defer { queue.reset() }
        let first = try #require(try queue.peek())
        let second = try #require(try queue.peek())
        #expect(first.writeBytes([1]) == 1)
        #expect(second.writeBytes([2]) == 1)
        #expect(first.isLeaseValid && second.isLeaseValid)
        let popped = try #require(try queue.pop())
        #expect(!first.isLeaseValid && !second.isLeaseValid)
        #expect(first.writeBytes([3]) == 0)
        #expect(second.writeBytes([4]) == 0)
        #expect(popped.writeBytes([5]) == 1)
        #expect(memory.releaseRange(
            guestAddress: memory.guestBase + HostPage.size, length: HostPage.size
        ) == .rejected)
        _ = try queue.pushOutcome(popped, written: 1)
        #expect(memory.releaseRange(
            guestAddress: memory.guestBase + HostPage.size, length: HostPage.size
        ) == .reclaimed)
    }

    @Test func popJoinsActivePreviewAccessBeforeRetiringItsPin() throws {
        let memory = try makeMemory()
        let queue = try makeQueue(memory)
        let owner = QueueOwner(queue)
        defer { queue.reset() }
        let preview = try #require(try queue.peek())
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let accessDone = DispatchSemaphore(value: 0)
        let popStarted = DispatchSemaphore(value: 0)
        let popDone = DispatchSemaphore(value: 0)
        let result = PopResult()
        defer { release.signal() }
        DispatchQueue.global().async {
            _ = preview.withLeaseHeld { access in
                entered.signal()
                _ = release.wait(timeout: .now() + 3)
                _ = access.writeBytes([9])
            }
            accessDone.signal()
        }
        try #require(entered.wait(timeout: .now() + 2) == .success)
        DispatchQueue.global().async {
            popStarted.signal()
            do { result.record(try owner.queue.pop()) }
            catch { Issue.record("preview retirement pop failed: \(error)") }
            popDone.signal()
        }
        try #require(popStarted.wait(timeout: .now() + 2) == .success)
        #expect(popDone.wait(timeout: .now() + 0.05) == .timedOut)
        #expect(memory.releaseRange(
            guestAddress: memory.guestBase + HostPage.size, length: HostPage.size
        ) == .rejected)
        release.signal()
        try #require(accessDone.wait(timeout: .now() + 2) == .success)
        try #require(popDone.wait(timeout: .now() + 2) == .success)
        #expect(!preview.isLeaseValid)
        let popped = try #require(result.chain)
        #expect(popped.writeBytes([7]) == 1)
        _ = try queue.pushOutcome(popped, written: 1)
    }

    @Test func livePreviewQuotaIsBoundedAndResetRetiresEveryRetainedPin() throws {
        let memory = try makeMemory()
        let queue = try makeQueue(memory)
        var previews: [VirtqueueChain] = []
        for _ in 0..<Virtqueue.maximumLivePreviewLeases {
            previews.append(try #require(try queue.peek()))
        }
        let allActive = previews.allSatisfy { $0.isLeaseValid }
        #expect(allActive)
        #expect(throws: VMError.self) { _ = try queue.peek() }
        queue.reset()
        #expect(previews.allSatisfy { !$0.isLeaseValid })
        #expect(memory.releaseRange(
            guestAddress: memory.guestBase + HostPage.size, length: HostPage.size
        ) == .reclaimed)
    }

    @Test func weakPreviewRegistryDoesNotRetainOtherwiseDroppedPinsOrExhaustQuota() throws {
        let memory = try makeMemory()
        let queue = try makeQueue(memory)
        defer { queue.reset() }
        var preview: VirtqueueChain?
        for _ in 0..<(Virtqueue.maximumLivePreviewLeases + 32) {
            preview = try queue.peek()
            #expect(preview?.isLeaseValid == true)
            preview = nil
        }
        #expect(preview == nil)
        #expect(memory.releaseRange(
            guestAddress: memory.guestBase + HostPage.size, length: HostPage.size
        ) == .reclaimed)
    }
}
