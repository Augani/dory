import Foundation
import Testing
@testable import DoryHV

/// Indirect descriptor metadata lives outside the pinned split rings. These fixtures use only
/// mocked reclaim operations, never Hypervisor mappings or a running guest.
@Suite struct VirtqueueIndirectMetadataPinTests {
    private struct Fixture {
        let memory: GuestMemory
        let queue: Virtqueue
        let descriptorTable: UInt64
        let indirectTable: UInt64
        let readablePayload: UInt64
        let writablePayload: UInt64
        let unmaps: ByteCounter
        let reusableAdvice: ByteCounter
    }

    private final class ReclaimObservation: @unchecked Sendable {
        private let lock = NSLock()
        private var storedResult: GuestMemoryReleaseResult?

        func record(_ result: GuestMemoryReleaseResult) {
            lock.lock()
            storedResult = result
            lock.unlock()
        }

        var result: GuestMemoryReleaseResult? {
            lock.lock()
            defer { lock.unlock() }
            return storedResult
        }
    }

    private func writeDescriptor(
        _ memory: GuestMemory,
        at descriptor: UInt64,
        address: UInt64,
        length: UInt32,
        flags: UInt16,
        next: UInt16 = 0
    ) throws {
        try memory.write(address, at: descriptor)
        try memory.write(length, at: descriptor + 8)
        try memory.write(flags, at: descriptor + 12)
        try memory.write(next, at: descriptor + 14)
    }

    private func makeFixture() throws -> Fixture {
        let base: UInt64 = 0x8000_0000
        let unmaps = ByteCounter()
        let advice = ByteCounter()
        let memory = try GuestMemory(
            guestBase: base,
            size: 4 * HostPage.size,
            reclaimOperations: GuestMemoryReclaimOperations(
                unmap: { _, _ in unmaps.add(1); return true },
                map: { _, _, _ in true },
                markReusable: { _, _ in advice.add(1); return true },
                markInUse: { _, _ in true }
            )
        )
        let table = base + HostPage.size
        let readable = base + 2 * HostPage.size
        let writable = base + 3 * HostPage.size
        let queue = Virtqueue(memory: memory)
        queue.setNegotiatedFeatures(VirtqueueFeature.indirectDescriptors)
        #expect(queue.configure(
            size: 8,
            descriptorTable: base,
            availRing: base + 0x100,
            usedRing: base + 0x200
        ))
        #expect(queue.setReady(true))
        try writeDescriptor(memory, at: base, address: table, length: 32, flags: 4)
        try writeDescriptor(
            memory, at: table, address: readable, length: 4, flags: 1, next: 1
        )
        try writeDescriptor(memory, at: table + 16, address: writable, length: 8, flags: 2)
        try memory.write([0x44, 0x4F, 0x52, 0x59], at: readable)
        try memory.write(UInt16(0), at: base + 0x104)
        try memory.write(UInt16(1), at: base + 0x102)
        return Fixture(
            memory: memory, queue: queue, descriptorTable: base, indirectTable: table,
            readablePayload: readable, writablePayload: writable,
            unmaps: unmaps, reusableAdvice: advice
        )
    }

    @Test func indirectTableRemainsPinnedDuringConcurrentReclaimAndReleasesAfterTraversal() throws {
        let fixture = try makeFixture()
        defer { fixture.queue.reset() }
        let memory = fixture.memory
        let table = fixture.indirectTable
        let observation = ReclaimObservation()
        fixture.queue.beforeIndirectTableTraversalTestHook = {
            let completed = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                observation.record(memory.releaseRange(
                    guestAddress: table, length: HostPage.size
                ))
                completed.signal()
            }
            guard completed.wait(timeout: .now() + 2) == .success else {
                throw VMError.unexpectedExit("indirect-table reclaim fixture timed out")
            }
        }

        let chain = try #require(try fixture.queue.pop())
        #expect(observation.result == .rejected)
        #expect(fixture.unmaps.load() == 0)
        #expect(fixture.reusableAdvice.load() == 0)
        #expect(chain.readBytes() == [0x44, 0x4F, 0x52, 0x59])
        #expect(chain.writeBytes([1, 2, 3, 4, 5, 6, 7, 8]) == 8)

        // The metadata lease is transient, not coupled to the outstanding payload lease.
        #expect(memory.releaseRange(guestAddress: table, length: HostPage.size) == .reclaimed)
        #expect(fixture.unmaps.load() == 1)
        #expect(fixture.reusableAdvice.load() == 1)
        #expect(chain.readBytes() == [0x44, 0x4F, 0x52, 0x59])
        #expect(try memory.readBytes(at: fixture.writablePayload, count: 8) == [
            1, 2, 3, 4, 5, 6, 7, 8,
        ])
        _ = try fixture.queue.pushOutcome(chain, written: 8)
    }

    @Test(arguments: [
        "released", "out-of-bounds", "overflow", "misaligned", "invalid-length",
        "descriptor-limit",
    ])
    func invalidIndirectMetadataNeverReachesTraversalHook(invalidCase: String) throws {
        let fixture = try makeFixture()
        defer { fixture.queue.reset() }
        var address = fixture.indirectTable
        var length: UInt32 = 32
        switch invalidCase {
        case "released":
            #expect(fixture.memory.releaseRange(
                guestAddress: address, length: HostPage.size
            ) == .reclaimed)
        case "out-of-bounds":
            address = fixture.memory.guestBase + fixture.memory.size
        case "overflow":
            address = UInt64.max & ~UInt64(15)
        case "misaligned":
            address += 1
        case "invalid-length":
            length = 17
        case "descriptor-limit":
            length = UInt32((VirtqueueLimits.hardenedDefault.maximumDescriptorCount + 1) * 16)
        default:
            Issue.record("unknown indirect-table fixture \(invalidCase)")
        }
        try writeDescriptor(
            fixture.memory, at: fixture.descriptorTable, address: address, length: length,
            flags: 4
        )
        let traversals = ByteCounter()
        fixture.queue.beforeIndirectTableTraversalTestHook = { traversals.add(1) }
        #expect(throws: VMError.self) { _ = try fixture.queue.pop() }
        #expect(traversals.load() == 0)
        #expect(fixture.unmaps.load() == (invalidCase == "released" ? 1 : 0))
    }

    @Test func indirectMetadataPinIsReleasedWhenNestedTraversalThrows() throws {
        let fixture = try makeFixture()
        defer { fixture.queue.reset() }
        try writeDescriptor(
            fixture.memory, at: fixture.indirectTable,
            address: fixture.indirectTable + 16, length: 16, flags: 4
        )
        let traversals = ByteCounter()
        fixture.queue.beforeIndirectTableTraversalTestHook = { traversals.add(1) }
        #expect(throws: VMError.self) { _ = try fixture.queue.pop() }
        #expect(traversals.load() == 1)
        #expect(fixture.memory.releaseRange(
            guestAddress: fixture.indirectTable, length: HostPage.size
        ) == .reclaimed)
        #expect(fixture.unmaps.load() == 1)
    }
}
