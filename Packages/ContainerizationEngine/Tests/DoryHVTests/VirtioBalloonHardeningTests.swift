import Foundation
import Testing
@testable import DoryHV

@Suite(.serialized) struct VirtioBalloonHardeningTests {
    private final class ManualWorkQueue: @unchecked Sendable {
        private let lock = NSLock()
        private var operations = [@Sendable () -> Void]()

        func submit(_ operation: @escaping @Sendable () -> Void) {
            lock.withLock { operations.append(operation) }
        }

        var pendingCount: Int {
            lock.withLock { operations.count }
        }

        @discardableResult
        func runNext() -> Bool {
            let operation = lock.withLock { () -> (@Sendable () -> Void)? in
                guard !operations.isEmpty else { return nil }
                return operations.removeFirst()
            }
            guard let operation else { return false }
            operation()
            return true
        }
    }

    private final class ReleaseBox: @unchecked Sendable {
        struct Call: Equatable, Sendable {
            let address: UInt64
            let length: UInt64
        }

        private let lock = NSLock()
        private var storage = [Call]()
        var result: @Sendable (Call) -> GuestMemoryReleaseResult = { _ in .reclaimed }

        func release(address: UInt64, length: UInt64) -> GuestMemoryReleaseResult {
            let call = Call(address: address, length: length)
            lock.lock()
            storage.append(call)
            let outcome = result(call)
            lock.unlock()
            return outcome
        }

        var calls: [Call] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private struct QueueLayout {
        let descriptors: UInt64
        let available: UInt64
        let used: UInt64
    }

    private struct Harness {
        let guestBase: UInt64
        let memory: GuestMemory
        let transport: VirtioMMIOTransport
        let device: VirtioBalloon
        let queues: [QueueLayout]
    }

    @Test func completeWritableReportIsPrevalidatedMergedAndReclaimedBeforeAck() throws {
        let releases = ReleaseBox()
        let harness = try makeHarness(
            limits: .init(
                maximumReportRanges: 4,
                maximumReportBytes: 4 * Int(HostPage.size),
                maximumChainsPerWorkerTurn: 8
            ),
            releases: releases
        )
        let queue = harness.queues[2]
        let buffer = harness.guestBase + 0x40_000
        try installDescriptor(
            queue: queue,
            index: 0,
            address: buffer,
            length: Int(HostPage.size),
            flags: 3,
            next: 1,
            harness: harness
        )
        try installDescriptor(
            queue: queue,
            index: 1,
            address: buffer + HostPage.size,
            length: Int(HostPage.size),
            flags: 2,
            next: 0,
            harness: harness
        )
        try publish([0], queue: queue, startingAt: 0, harness: harness)

        harness.device.handleKick(queue: 2, transport: harness.transport)

        #expect(releases.calls == [ReleaseBox.Call(
            address: buffer,
            length: 2 * HostPage.size
        )])
        #expect(try usedIndex(queue: queue, harness: harness) == 1)
        #expect(try usedLength(queue: queue, at: 0, harness: harness) == 0)
        #expect(harness.device.statistics.reportRequests == 1)
        #expect(harness.device.statistics.reportBytes == 2 * HostPage.size)
        #expect(harness.device.statistics.reclaimedBytes == 2 * HostPage.size)
    }

    @Test func kickOnlyEnqueuesReclaimAndResetRevokesQueuedHostMutation() throws {
        let releases = ReleaseBox()
        let work = ManualWorkQueue()
        let harness = try makeHarness(
            limits: .init(
                maximumReportRanges: 4,
                maximumReportBytes: 4 * Int(HostPage.size),
                maximumChainsPerWorkerTurn: 1
            ),
            releases: releases,
            submitWork: { work.submit($0) }
        )
        let queue = harness.queues[2]
        let first = harness.guestBase + 0x40_000
        try installDescriptor(
            queue: queue,
            index: 0,
            address: first,
            length: Int(HostPage.size),
            flags: 2,
            next: 0,
            harness: harness
        )
        try publish([0], queue: queue, startingAt: 0, harness: harness)

        harness.device.handleKick(queue: 2, transport: harness.transport)

        // The notifying vCPU boundary did not enter GuestMemory.releaseRange or consume the ring.
        #expect(work.pendingCount == 1)
        #expect(releases.calls.isEmpty)
        #expect(try usedIndex(queue: queue, harness: harness) == 0)
        #expect(harness.device.statistics.workerTurns == 0)

        #expect(work.runNext())
        #expect(releases.calls == [ReleaseBox.Call(
            address: first,
            length: HostPage.size
        )])
        #expect(try usedIndex(queue: queue, harness: harness) == 1)
        #expect(harness.device.statistics.workerTurns == 1)

        let second = first + 2 * HostPage.size
        try installDescriptor(
            queue: queue,
            index: 1,
            address: second,
            length: Int(HostPage.size),
            flags: 2,
            next: 0,
            harness: harness
        )
        try publish([1], queue: queue, startingAt: 1, harness: harness)
        harness.device.handleKick(queue: 2, transport: harness.transport)
        #expect(work.pendingCount == 1)

        // Transport reset revokes the scheduled generation before it clears the queue. Executing
        // the already-enqueued closure afterwards cannot reclaim guest memory or publish used.
        harness.transport.write(offset: 0x070, value: 0, width: 4)
        #expect(work.runNext())
        #expect(releases.calls.count == 1)
        #expect(try usedIndex(queue: queue, harness: harness) == 1)
        #expect(harness.device.statistics.revokedWorkerTurns == 1)
    }

    @Test func resetFencesAnInFlightReleaseBeforeQueueRevocation() throws {
        let releases = ReleaseBox()
        let releaseEntered = DispatchSemaphore(value: 0)
        let allowRelease = DispatchSemaphore(value: 0)
        releases.result = { _ in
            releaseEntered.signal()
            return allowRelease.wait(timeout: .now() + 2) == .success
                ? .reclaimed : .unmappedNotReclaimed
        }
        let worker = DispatchQueue(label: "dev.dory.tests.balloon-worker")
        let harness = try makeHarness(
            limits: .init(
                maximumReportRanges: 4,
                maximumReportBytes: 4 * Int(HostPage.size),
                maximumChainsPerWorkerTurn: 1
            ),
            releases: releases,
            submitWork: { worker.async(execute: $0) }
        )
        let queue = harness.queues[2]
        let buffer = harness.guestBase + 0x40_000
        try installDescriptor(
            queue: queue,
            index: 0,
            address: buffer,
            length: Int(HostPage.size),
            flags: 2,
            next: 0,
            harness: harness
        )
        try publish([0], queue: queue, startingAt: 0, harness: harness)
        harness.device.handleKick(queue: 2, transport: harness.transport)
        #expect(releaseEntered.wait(timeout: .now() + 1) == .success)

        let resetStarted = DispatchSemaphore(value: 0)
        let resetReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            resetStarted.signal()
            harness.transport.write(offset: 0x070, value: 0, width: 4)
            resetReturned.signal()
        }
        #expect(resetStarted.wait(timeout: .now() + 1) == .success)
        #expect(resetReturned.wait(timeout: .now() + .milliseconds(100)) == .timedOut)

        allowRelease.signal()
        #expect(resetReturned.wait(timeout: .now() + 1) == .success)
        worker.sync {}

        // The already-started bounded host release completes, then reset advances the generation
        // before the worker can publish the descriptor into the now-cleared queue.
        #expect(releases.calls == [ReleaseBox.Call(
            address: buffer,
            length: HostPage.size
        )])
        #expect(try usedIndex(queue: queue, harness: harness) == 0)
        #expect(harness.device.statistics.revokedWorkerTurns == 1)
    }

    @Test func mixedZeroLengthAndOversizedReportsNeverCrossTheReleaseBoundary() throws {
        let releases = ReleaseBox()
        let harness = try makeHarness(
            limits: .init(
                maximumReportRanges: 4,
                maximumReportBytes: Int(HostPage.size),
                maximumChainsPerWorkerTurn: 8
            ),
            releases: releases
        )
        let queue = harness.queues[2]
        let buffer = harness.guestBase + 0x40_000

        // Valid-looking writable prefix followed by a readable segment: no prefix may be released.
        try installDescriptor(
            queue: queue,
            index: 0,
            address: buffer,
            length: Int(HostPage.size),
            flags: 3,
            next: 1,
            harness: harness
        )
        try installDescriptor(
            queue: queue,
            index: 1,
            address: buffer + HostPage.size,
            length: Int(HostPage.size),
            flags: 0,
            next: 0,
            harness: harness
        )
        try installDescriptor(
            queue: queue,
            index: 2,
            address: buffer + 2 * HostPage.size,
            length: 0,
            flags: 2,
            next: 0,
            harness: harness
        )
        try installDescriptor(
            queue: queue,
            index: 3,
            address: buffer + 3 * HostPage.size,
            length: 2 * Int(HostPage.size),
            flags: 2,
            next: 0,
            harness: harness
        )
        try publish([0, 2, 3], queue: queue, startingAt: 0, harness: harness)

        harness.device.handleKick(queue: 2, transport: harness.transport)

        #expect(releases.calls.isEmpty)
        #expect(try usedIndex(queue: queue, harness: harness) == 3)
        #expect(harness.device.statistics.reportRejected == 3)
        #expect(harness.device.statistics.reportRequests == 0)
    }

    @Test func hostReleaseFailureIsObservableButDoesNotWithholdGuestAcknowledgement() throws {
        let releases = ReleaseBox()
        let harness = try makeHarness(
            limits: .init(
                maximumReportRanges: 4,
                maximumReportBytes: 4 * Int(HostPage.size),
                maximumChainsPerWorkerTurn: 8
            ),
            releases: releases
        )
        let queue = harness.queues[2]
        let first = harness.guestBase + 0x40_000
        let second = first + 3 * HostPage.size
        releases.result = { $0.address == first ? .reclaimed : .unmappedNotReclaimed }
        try installDescriptor(
            queue: queue,
            index: 0,
            address: first,
            length: Int(HostPage.size),
            flags: 3,
            next: 1,
            harness: harness
        )
        try installDescriptor(
            queue: queue,
            index: 1,
            address: second,
            length: Int(HostPage.size),
            flags: 2,
            next: 0,
            harness: harness
        )
        try publish([0], queue: queue, startingAt: 0, harness: harness)

        harness.device.handleKick(queue: 2, transport: harness.transport)

        #expect(releases.calls.count == 2)
        #expect(try usedIndex(queue: queue, harness: harness) == 1)
        #expect(harness.device.statistics.releaseFailures == 1)
        #expect(harness.device.statistics.reclaimedBytes == HostPage.size)
    }

    @Test func parkedClassicQueuesAcceptOnlyBoundedReadablePFNArrays() throws {
        let releases = ReleaseBox()
        let harness = try makeHarness(
            limits: .init(
                maximumReportRanges: 4,
                maximumReportBytes: 4 * Int(HostPage.size),
                maximumChainsPerWorkerTurn: 8
            ),
            releases: releases
        )
        let queue = harness.queues[0]
        let buffer = harness.guestBase + 0x40_000
        try installDescriptor(
            queue: queue,
            index: 0,
            address: buffer,
            length: 8,
            flags: 0,
            next: 0,
            harness: harness
        )
        try installDescriptor(
            queue: queue,
            index: 1,
            address: buffer + 0x100,
            length: 8,
            flags: 2,
            next: 0,
            harness: harness
        )
        try installDescriptor(
            queue: queue,
            index: 2,
            address: buffer + 0x200,
            length: 3,
            flags: 0,
            next: 0,
            harness: harness
        )
        try publish([0, 1, 2], queue: queue, startingAt: 0, harness: harness)

        harness.device.handleKick(queue: 0, transport: harness.transport)

        #expect(try usedIndex(queue: queue, harness: harness) == 3)
        #expect(harness.device.statistics.classicRequests == 3)
        #expect(harness.device.statistics.invalidClassicRequests == 2)
        #expect(releases.calls.isEmpty)
    }

    @Test func workerTurnCeilingYieldsBeforeMalformedDescriptorFault() throws {
        let releases = ReleaseBox()
        let work = ManualWorkQueue()
        let harness = try makeHarness(
            limits: .init(
                maximumReportRanges: 4,
                maximumReportBytes: 4 * Int(HostPage.size),
                maximumChainsPerWorkerTurn: 1
            ),
            releases: releases,
            submitWork: { work.submit($0) }
        )
        let queue = harness.queues[2]
        let buffer = harness.guestBase + 0x40_000
        try installDescriptor(
            queue: queue,
            index: 0,
            address: buffer,
            length: Int(HostPage.size),
            flags: 2,
            next: 0,
            harness: harness
        )
        try installDescriptor(
            queue: queue,
            index: 1,
            address: harness.guestBase + harness.memory.size + 0x100,
            length: Int(HostPage.size),
            flags: 2,
            next: 0,
            harness: harness
        )
        try publish([0, 1], queue: queue, startingAt: 0, harness: harness)

        harness.device.handleKick(queue: 2, transport: harness.transport)
        #expect(work.pendingCount == 1)
        #expect(work.runNext())
        #expect(try usedIndex(queue: queue, harness: harness) == 1)
        #expect(harness.device.statistics.boundedDrainStops == 1)
        #expect(harness.device.statistics.workerYields == 1)
        #expect(harness.device.statistics.queueFaults == 0)
        #expect(work.pendingCount == 1)

        // Fair self-rescheduling gives the executor a boundary between chains. The next bounded
        // turn observes the malformed descriptor explicitly instead of stranding it until a new
        // guest notification happens to arrive.
        #expect(work.runNext())
        #expect(harness.device.statistics.queueFaults == 1)
        #expect(work.pendingCount == 0)
    }

    private func makeHarness(
        limits: VirtioBalloonLimits,
        releases: ReleaseBox,
        submitWork: @escaping (@escaping @Sendable () -> Void) -> Void = { operation in
            operation()
        }
    ) throws -> Harness {
        let guestBase: UInt64 = 0xD200_0000
        let memory = try GuestMemory(guestBase: guestBase, size: 1 << 20)
        let device = VirtioBalloon(
            memory: memory,
            limits: limits,
            releaseRange: { address, length in
                releases.release(address: address, length: length)
            },
            submitWork: submitWork
        )
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: device,
            memory: memory
        ) {}
        let queues = (0..<3).map { index in
            QueueLayout(
                descriptors: guestBase + 0x10_000 + UInt64(index) * 0x6_000,
                available: guestBase + 0x12_000 + UInt64(index) * 0x6_000,
                used: guestBase + 0x14_000 + UInt64(index) * 0x6_000
            )
        }
        for (index, queue) in queues.enumerated() {
            #expect(transport.queues[index].configure(
                size: 8,
                descriptorTable: queue.descriptors,
                availRing: queue.available,
                usedRing: queue.used
            ))
            #expect(transport.queues[index].setReady(true))
            try memory.write(UInt16(0), at: queue.available)
            try memory.write(UInt16(0), at: queue.available + 2)
            try memory.write(UInt16(0), at: queue.used + 2)
        }
        return Harness(
            guestBase: guestBase,
            memory: memory,
            transport: transport,
            device: device,
            queues: queues
        )
    }

    private func installDescriptor(
        queue: QueueLayout,
        index: UInt16,
        address: UInt64,
        length: Int,
        flags: UInt16,
        next: UInt16,
        harness: Harness
    ) throws {
        let descriptor = queue.descriptors + UInt64(index) * 16
        try harness.memory.write(address, at: descriptor)
        try harness.memory.write(UInt32(length), at: descriptor + 8)
        try harness.memory.write(flags, at: descriptor + 12)
        try harness.memory.write(next, at: descriptor + 14)
    }

    private func publish(
        _ heads: [UInt16],
        queue: QueueLayout,
        startingAt start: UInt16,
        harness: Harness
    ) throws {
        for (offset, head) in heads.enumerated() {
            let index = start &+ UInt16(offset)
            try harness.memory.write(
                head,
                at: queue.available + 4 + UInt64(index % 8) * 2
            )
        }
        try harness.memory.write(start &+ UInt16(heads.count), at: queue.available + 2)
    }

    private func usedIndex(queue: QueueLayout, harness: Harness) throws -> UInt16 {
        try harness.memory.read(UInt16.self, at: queue.used + 2)
    }

    private func usedLength(
        queue: QueueLayout,
        at index: Int,
        harness: Harness
    ) throws -> UInt32 {
        try harness.memory.read(UInt32.self, at: queue.used + 8 + UInt64(index) * 8)
    }
}
