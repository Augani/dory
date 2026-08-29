import Foundation
import Testing
@testable import DoryHV

@Suite(.serialized) struct GuestMemoryReclaimStateTests {
    private final class OperationsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var unmapResultStorage = true
        private var mapResultStorage = true
        private var reusableResultStorage = true
        private var inUseResultStorage = true
        private var unmapCallsStorage = 0
        private var mapCallsStorage = 0
        private var reusableCallsStorage = 0
        private var inUseCallsStorage = 0

        var unmapResult: Bool {
            get { locked { unmapResultStorage } }
            set { locked { unmapResultStorage = newValue } }
        }
        var mapResult: Bool {
            get { locked { mapResultStorage } }
            set { locked { mapResultStorage = newValue } }
        }
        var reusableResult: Bool {
            get { locked { reusableResultStorage } }
            set { locked { reusableResultStorage = newValue } }
        }
        var inUseResult: Bool {
            get { locked { inUseResultStorage } }
            set { locked { inUseResultStorage = newValue } }
        }
        var unmapCalls: Int { locked { unmapCallsStorage } }
        var mapCalls: Int { locked { mapCallsStorage } }
        var reusableCalls: Int { locked { reusableCallsStorage } }
        var inUseCalls: Int { locked { inUseCallsStorage } }

        func unmap() -> Bool {
            locked {
                unmapCallsStorage += 1
                return unmapResultStorage
            }
        }

        func map() -> Bool {
            locked {
                mapCallsStorage += 1
                return mapResultStorage
            }
        }

        func markReusable() -> Bool {
            locked {
                reusableCallsStorage += 1
                return reusableResultStorage
            }
        }

        func markInUse() -> Bool {
            locked {
                inUseCallsStorage += 1
                return inUseResultStorage
            }
        }

        private func locked<Result>(_ body: () -> Result) -> Result {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
    }

    @Test func successfulReclaimAndRestoreHaveExactAccountingAndNoOverlap() throws {
        let box = OperationsBox()
        let memory = try makeMemory(box)
        let address = memory.guestBase + HostPage.size

        #expect(memory.releaseRange(guestAddress: address, length: HostPage.size) == .reclaimed)
        #expect(memory.releaseRange(guestAddress: address, length: HostPage.size) == .rejected)
        #expect(box.unmapCalls == 1)
        #expect(box.reusableCalls == 1)
        #expect(memory.releasedBytes.load() == HostPage.size)

        #expect(memory.restorePage(guestAddress: address + 17))
        #expect(box.inUseCalls == 1)
        #expect(box.mapCalls == 1)
        #expect(memory.restoredBytes.load() == HostPage.size)

        // A duplicate fault after the state is mapped is an idempotent success.
        #expect(memory.restorePage(guestAddress: address))
        #expect(box.mapCalls == 1)
    }

    @Test func failedReusableAdviceRemainsTrackedButIsNotCountedAsReclaimed() throws {
        let box = OperationsBox()
        box.reusableResult = false
        let memory = try makeMemory(box)
        let address = memory.guestBase + 2 * HostPage.size

        #expect(
            memory.releaseRange(guestAddress: address, length: HostPage.size)
                == .unmappedNotReclaimed
        )
        #expect(memory.reclaimAdviceFailures.load() == 1)
        #expect(memory.releasedBytes.load() == 0)

        // Stage-2 was already removed, so the page is still tracked and must be remapped. Because
        // MADV_FREE_REUSABLE never succeeded, MADV_FREE_REUSE is neither needed nor counted.
        #expect(memory.restorePage(guestAddress: address))
        #expect(box.inUseCalls == 0)
        #expect(box.mapCalls == 1)
        #expect(memory.restoredBytes.load() == 0)
    }

    @Test func failedUnmapLeavesThePageMappedAndNeverAdvisesItAway() throws {
        let box = OperationsBox()
        box.unmapResult = false
        let memory = try makeMemory(box)
        let address = memory.guestBase + 3 * HostPage.size

        #expect(memory.releaseRange(guestAddress: address, length: HostPage.size) == .unmapFailed)
        #expect(memory.reclaimUnmapFailures.load() == 1)
        #expect(box.reusableCalls == 0)
        #expect(memory.restorePage(guestAddress: address))
        #expect(box.mapCalls == 0)
    }

    @Test func restoreAdviceAndMapFailuresRemainRetryableUntilThePageIsMapped() throws {
        let box = OperationsBox()
        let memory = try makeMemory(box)
        let address = memory.guestBase + 4 * HostPage.size
        #expect(memory.releaseRange(guestAddress: address, length: HostPage.size) == .reclaimed)

        box.inUseResult = false
        #expect(!memory.restorePage(guestAddress: address))
        #expect(memory.restoreAdviceFailures.load() == 1)
        #expect(box.mapCalls == 0)

        box.inUseResult = true
        box.mapResult = false
        #expect(!memory.restorePage(guestAddress: address))
        #expect(memory.restoreMapFailures.load() == 1)
        #expect(memory.restoredBytes.load() == 0)

        box.mapResult = true
        #expect(memory.restorePage(guestAddress: address))
        #expect(box.inUseCalls == 2)
        #expect(memory.restoredBytes.load() == HostPage.size)
    }

    private func makeMemory(_ box: OperationsBox) throws -> GuestMemory {
        try GuestMemory(
            guestBase: 0xD300_0000,
            size: 8 * HostPage.size,
            reclaimOperations: GuestMemoryReclaimOperations(
                unmap: { _, _ in box.unmap() },
                map: { _, _, _ in box.map() },
                markReusable: { _, _ in box.markReusable() },
                markInUse: { _, _ in box.markInUse() }
            )
        )
    }
}
