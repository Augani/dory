import Foundation
import Testing
@testable import DoryHV

@Suite(.serialized) struct VirtioInputHardeningTests {
    private final class EventBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = [VirtioInputEvent]()

        func append(_ event: VirtioInputEvent) {
            lock.lock()
            storage.append(event)
            lock.unlock()
        }

        var values: [VirtioInputEvent] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private final class ClockBox: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [UInt64]

        init(_ values: [UInt64]) {
            self.values = values
        }

        func next() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            guard !values.isEmpty else { return 0 }
            return values.removeFirst()
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
        let device: VirtioInput
        let queues: [QueueLayout]
    }

    @Test func nonfiniteAndExtremeScrollSamplesCannotPoisonTheAccumulator() {
        var accumulator = VirtioInputScrollAccumulator()
        let horizontalOnly = accumulator.events(
            horizontalDelta: -1,
            verticalDelta: .nan,
            hasPreciseDeltas: false
        )
        #expect(horizontalOnly == [
            VirtioInputEvent(type: 2, code: 12, value: -120),
            VirtioInputEvent(type: 2, code: 6, value: -1),
        ])

        #expect(accumulator.events(
            horizontalDelta: .infinity,
            verticalDelta: -.infinity,
            hasPreciseDeltas: true
        ).isEmpty)

        let extreme = accumulator.events(
            horizontalDelta: 0,
            verticalDelta: Double.greatestFiniteMagnitude,
            hasPreciseDeltas: false
        )
        #expect(extreme.count == 2)
        #expect(extreme[0].code == 11)
        #expect(extreme[0].value == Int32.max - 120)
        #expect(extreme[1].code == 8)
    }

    @Test func eventAndStatusQueuesEnforceTheirOppositeDirectionsAndTypedStatus() throws {
        let statusEvents = EventBox()
        let harness = try makeHarness(
            profile: .keyboard,
            limits: .init(
                maximumEventsPerFrame: 8,
                maximumPendingFrames: 8,
                maximumChainsPerWorkerTurn: 8
            ),
            statusHandler: { statusEvents.append($0) }
        )
        let eventQueue = harness.queues[0]
        let statusQueue = harness.queues[1]
        let buffers = harness.guestBase + 0x30_000

        // eventq is device-to-driver and therefore accepts only writable buffers.
        try installDescriptor(
            queue: eventQueue,
            index: 0,
            address: buffers,
            length: 8,
            flags: 0,
            next: 0,
            harness: harness
        )
        try installDescriptor(
            queue: eventQueue,
            index: 1,
            address: buffers + 0x100,
            length: 8,
            flags: 1,
            next: 2,
            harness: harness
        )
        try installDescriptor(
            queue: eventQueue,
            index: 2,
            address: buffers + 0x200,
            length: 8,
            flags: 2,
            next: 0,
            harness: harness
        )
        try publish([0, 1], queue: eventQueue, startingAt: 0, harness: harness)
        harness.device.handleKick(queue: 0, transport: harness.transport)
        #expect(waitUntil { (try? usedIndex(queue: eventQueue, harness: harness)) == 2 })
        #expect(harness.device.statistics.invalidEventBuffers == 2)

        // statusq is driver-to-device. A writable buffer and an unadvertised status type are
        // completed but never cross the host callback boundary.
        try installDescriptor(
            queue: statusQueue,
            index: 0,
            address: buffers + 0x300,
            length: 8,
            flags: 2,
            next: 0,
            harness: harness
        )
        try installDescriptor(
            queue: statusQueue,
            index: 1,
            address: buffers + 0x400,
            length: 8,
            flags: 0,
            next: 0,
            harness: harness
        )
        try installDescriptor(
            queue: statusQueue,
            index: 2,
            address: buffers + 0x500,
            length: 8,
            flags: 0,
            next: 0,
            harness: harness
        )
        try harness.memory.write(eventBytes(type: 17, code: 0, value: 1), at: buffers + 0x400)
        try harness.memory.write(eventBytes(type: 2, code: 8, value: 1), at: buffers + 0x500)
        try publish([0, 1, 2], queue: statusQueue, startingAt: 0, harness: harness)
        harness.device.handleKick(queue: 1, transport: harness.transport)

        #expect(waitUntil { (try? usedIndex(queue: statusQueue, harness: harness)) == 3 })
        #expect(waitUntil { statusEvents.values.count == 1 })
        #expect(statusEvents.values == [VirtioInputEvent(type: 17, code: 0, value: 1)])
        #expect(harness.device.statistics.invalidStatusBuffers == 2)
        #expect(harness.device.statistics.statusEvents == 1)
    }

    @Test func overflowReconcilesDroppedReleaseWithoutLeavingAGuestKeyStuck() throws {
        let harness = try makeHarness(
            profile: .keyboard,
            limits: .init(
                maximumEventsPerFrame: 8,
                maximumPendingFrames: 1,
                maximumChainsPerWorkerTurn: 8
            )
        )
        let queue = harness.queues[0]
        let buffers = harness.guestBase + 0x30_000
        harness.device.deviceReady(transport: harness.transport)

        for index in UInt16(0)..<6 {
            try installDescriptor(
                queue: queue,
                index: index,
                address: buffers + UInt64(index) * 8,
                length: 8,
                flags: 2,
                next: 0,
                harness: harness
            )
        }

        try publish([0, 1], queue: queue, startingAt: 0, harness: harness)
        harness.device.send(frame: [VirtioInputEvent(type: 1, code: 30, value: 1)])
        #expect(waitUntil { (try? usedIndex(queue: queue, harness: harness)) == 2 })

        // With no guest buffers, the admitted release keeps its exact order and B's press is
        // rejected at the bounded admission edge. Desired state still causes a later B press
        // reconciliation, so saturation cannot reorder a new transition ahead of old input.
        harness.device.send(frame: [VirtioInputEvent(type: 1, code: 30, value: 0)])
        harness.device.send(frame: [VirtioInputEvent(type: 1, code: 48, value: 1)])
        #expect(harness.device.statistics.droppedFrames == 1)
        #expect(harness.device.statistics.pendingFrameSaturationEvents == 1)

        try publish([2, 3, 4, 5], queue: queue, startingAt: 2, harness: harness)
        harness.device.handleKick(queue: 0, transport: harness.transport)

        #expect(waitUntil { (try? usedIndex(queue: queue, harness: harness)) == 6 })
        #expect(try readEvent(at: buffers + 2 * 8, harness: harness)
            == VirtioInputEvent(type: 1, code: 30, value: 0))
        #expect(try readEvent(at: buffers + 3 * 8, harness: harness) == .synchronize)
        #expect(try readEvent(at: buffers + 4 * 8, harness: harness)
            == VirtioInputEvent(type: 1, code: 48, value: 1))
        #expect(try readEvent(at: buffers + 5 * 8, harness: harness) == .synchronize)
        #expect(harness.device.statistics.stateReconciliationEvents == 1)
        #expect(harness.device.statistics.publishedFrames == 3)
    }

    @Test func oversizedOrUnsupportedHostFramesAreRejectedAsWholeFrames() throws {
        let harness = try makeHarness(
            profile: .keyboard,
            limits: .init(
                maximumEventsPerFrame: 3,
                maximumPendingFrames: 2,
                maximumChainsPerWorkerTurn: 8
            )
        )
        harness.device.deviceReady(transport: harness.transport)
        harness.device.send(frame: [
            VirtioInputEvent(type: 1, code: 30, value: 1),
            VirtioInputEvent(type: 1, code: 31, value: 1),
            VirtioInputEvent(type: 1, code: 32, value: 1),
        ])
        harness.device.send(frame: [VirtioInputEvent(type: 3, code: 0, value: 100)])

        #expect(harness.device.statistics.rejectedFrames == 2)
        #expect(harness.device.statistics.submittedFrames == 0)
    }

    @Test func queueWorkIsBoundedAndMalformedDescriptorsAreObservable() throws {
        let harness = try makeHarness(
            profile: .keyboard,
            limits: .init(
                maximumEventsPerFrame: 8,
                maximumPendingFrames: 8,
                maximumChainsPerWorkerTurn: 1
            )
        )
        let queue = harness.queues[0]
        let buffers = harness.guestBase + 0x30_000
        try installDescriptor(
            queue: queue,
            index: 0,
            address: buffers,
            length: 8,
            flags: 0,
            next: 0,
            harness: harness
        )
        try installDescriptor(
            queue: queue,
            index: 1,
            address: harness.guestBase + UInt64(harness.memory.size) + 0x100,
            length: 8,
            flags: 2,
            next: 0,
            harness: harness
        )
        try publish([0, 1], queue: queue, startingAt: 0, harness: harness)

        harness.device.handleKick(queue: 0, transport: harness.transport)
        #expect(waitUntil { (try? usedIndex(queue: queue, harness: harness)) == 1 })
        #expect(waitUntil { harness.device.statistics.queueFaults == 1 })
        #expect(harness.device.statistics.boundedDrainStops == 1)
        #expect(harness.device.statistics.workerTurns == 2)
        #expect(harness.device.statistics.workerYields == 1)
        #expect(harness.device.statistics.eventQueueHighWatermark == 2)
    }

    @Test func hostSendReturnsWithoutWaitingForTheGuestRingLock() throws {
        let harness = try makeHarness(
            profile: .keyboard,
            limits: .init(
                maximumEventsPerFrame: 8,
                maximumPendingFrames: 8,
                maximumChainsPerWorkerTurn: 8
            )
        )
        let queue = harness.queues[0]
        let buffers = harness.guestBase + 0x30_000
        for index in UInt16(0)..<2 {
            try installDescriptor(
                queue: queue,
                index: index,
                address: buffers + UInt64(index) * 8,
                length: 8,
                flags: 2,
                next: 0,
                harness: harness
            )
        }
        try publish([0, 1], queue: queue, startingAt: 0, harness: harness)

        let ringLockHeld = DispatchSemaphore(value: 0)
        let releaseRingLock = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            harness.transport.withQueueLock {
                ringLockHeld.signal()
                _ = releaseRingLock.wait(timeout: .now() + 2)
            }
        }
        #expect(ringLockHeld.wait(timeout: .now() + 1) == .success)

        let sendReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            harness.device.send(frame: [
                VirtioInputEvent(type: 1, code: 30, value: 1)
            ])
            sendReturned.signal()
        }
        #expect(sendReturned.wait(timeout: .now() + 0.05) == .success)
        #expect(try usedIndex(queue: queue, harness: harness) == 0)

        releaseRingLock.signal()
        #expect(waitUntil { (try? usedIndex(queue: queue, harness: harness)) == 2 })
        #expect(harness.device.statistics.publishedFrames == 1)
    }

    @Test func keyScrollAndReleaseFramesKeepExactSubmissionOrder() throws {
        let harness = try makeHarness(
            profile: .combinedCompatibility,
            limits: .init(
                maximumEventsPerFrame: 8,
                maximumPendingFrames: 8,
                maximumChainsPerWorkerTurn: 8
            )
        )
        let queue = harness.queues[0]
        let buffers = harness.guestBase + 0x30_000
        for index in UInt16(0)..<7 {
            try installDescriptor(
                queue: queue,
                index: index,
                address: buffers + UInt64(index) * 8,
                length: 8,
                flags: 2,
                next: 0,
                harness: harness
            )
        }
        try publish(Array(UInt16(0)..<7), queue: queue, startingAt: 0, harness: harness)

        harness.device.send(frame: [VirtioInputEvent(type: 1, code: 30, value: 1)])
        harness.device.send(frame: [
            VirtioInputEvent(type: 2, code: 11, value: 120),
            VirtioInputEvent(type: 2, code: 8, value: 1),
        ])
        harness.device.send(frame: [VirtioInputEvent(type: 1, code: 30, value: 0)])

        #expect(waitUntil { (try? usedIndex(queue: queue, harness: harness)) == 7 })
        let expected = [
            VirtioInputEvent(type: 1, code: 30, value: 1),
            .synchronize,
            VirtioInputEvent(type: 2, code: 11, value: 120),
            VirtioInputEvent(type: 2, code: 8, value: 1),
            .synchronize,
            VirtioInputEvent(type: 1, code: 30, value: 0),
            .synchronize,
        ]
        let actual = try (0..<7).map {
            try readEvent(at: buffers + UInt64($0) * 8, harness: harness)
        }
        #expect(actual == expected)
        #expect(harness.device.statistics.publishedFrames == 3)
        #expect(harness.device.statistics.publishedEvents == 7)
        #expect(harness.device.statistics.droppedFrames == 0)
        #expect(harness.device.statistics.eventQueueHighWatermark == 7)
    }

    @Test func onlyAdjacentPureMotionIsReplacedWithoutCrossingScrollOrder() throws {
        let harness = try makeHarness(
            profile: .combinedCompatibility,
            limits: .init(
                maximumEventsPerFrame: 8,
                maximumPendingFrames: 8,
                maximumChainsPerWorkerTurn: 8
            )
        )
        let queue = harness.queues[0]
        let buffers = harness.guestBase + 0x30_000

        harness.device.send(frame: [
            VirtioInputEvent(type: 3, code: 0, value: 100),
            VirtioInputEvent(type: 3, code: 1, value: 200),
        ])
        harness.device.send(frame: [
            VirtioInputEvent(type: 3, code: 0, value: 300),
            VirtioInputEvent(type: 3, code: 1, value: 400),
        ])
        harness.device.send(frame: [
            VirtioInputEvent(type: 2, code: 11, value: 12)
        ])
        harness.device.send(frame: [
            VirtioInputEvent(type: 3, code: 0, value: 500),
            VirtioInputEvent(type: 3, code: 1, value: 600),
        ])
        harness.device.send(frame: [
            VirtioInputEvent(type: 3, code: 0, value: 700),
            VirtioInputEvent(type: 3, code: 1, value: 800),
        ])
        #expect(waitUntil { harness.device.statistics.pendingFrameDepth == 3 })
        #expect(harness.device.statistics.coalescedMotionFrames == 2)

        for index in UInt16(0)..<8 {
            try installDescriptor(
                queue: queue,
                index: index,
                address: buffers + UInt64(index) * 8,
                length: 8,
                flags: 2,
                next: 0,
                harness: harness
            )
        }
        try publish(Array(UInt16(0)..<8), queue: queue, startingAt: 0, harness: harness)
        harness.device.handleKick(queue: 0, transport: harness.transport)

        #expect(waitUntil { (try? usedIndex(queue: queue, harness: harness)) == 8 })
        let expected = [
            VirtioInputEvent(type: 3, code: 0, value: 300),
            VirtioInputEvent(type: 3, code: 1, value: 400),
            .synchronize,
            VirtioInputEvent(type: 2, code: 11, value: 12),
            .synchronize,
            VirtioInputEvent(type: 3, code: 0, value: 700),
            VirtioInputEvent(type: 3, code: 1, value: 800),
            .synchronize,
        ]
        let actual = try (0..<8).map {
            try readEvent(at: buffers + UInt64($0) * 8, harness: harness)
        }
        #expect(actual == expected)
        #expect(harness.device.statistics.droppedFrames == 0)
    }

    @Test func publicationLatencyAndQueueGaugesAreDeterministic() throws {
        let clock = ClockBox([100, 160])
        let harness = try makeHarness(
            profile: .keyboard,
            limits: .init(
                maximumEventsPerFrame: 8,
                maximumPendingFrames: 8,
                maximumChainsPerWorkerTurn: 8
            ),
            monotonicNanoseconds: { clock.next() }
        )
        let queue = harness.queues[0]
        let buffers = harness.guestBase + 0x30_000
        for index in UInt16(0)..<2 {
            try installDescriptor(
                queue: queue,
                index: index,
                address: buffers + UInt64(index) * 8,
                length: 8,
                flags: 2,
                next: 0,
                harness: harness
            )
        }
        try publish([0, 1], queue: queue, startingAt: 0, harness: harness)
        harness.device.send(frame: [VirtioInputEvent(type: 1, code: 30, value: 1)])

        #expect(waitUntil { (try? usedIndex(queue: queue, harness: harness)) == 2 })
        let statistics = harness.device.statistics
        #expect(statistics.publicationLatencyNanoseconds == 60)
        #expect(statistics.maximumPublicationLatencyNanoseconds == 60)
        #expect(statistics.pendingFrameDepth == 0)
        #expect(statistics.pendingFrameHighWatermark == 1)
        #expect(statistics.availableEventBufferDepth == 0)
        #expect(statistics.availableEventBufferHighWatermark == 2)
        #expect(statistics.eventQueueDepth == 0)
        #expect(statistics.eventQueueHighWatermark == 2)
    }

    @Test func resetWaitsForActivePublicationAndNoCompletionAppearsAfterReset() throws {
        let publicationEntered = DispatchSemaphore(value: 0)
        let releasePublication = DispatchSemaphore(value: 0)
        let harness = try makeHarness(
            profile: .keyboard,
            limits: .init(
                maximumEventsPerFrame: 8,
                maximumPendingFrames: 8,
                maximumChainsPerWorkerTurn: 8
            ),
            workerHooks: VirtioInputWorkerHooks(
                beforeWorkerTurn: nil,
                beforeEventPublication: {
                    publicationEntered.signal()
                    _ = releasePublication.wait(timeout: .now() + 2)
                }
            )
        )
        let queue = harness.queues[0]
        let buffers = harness.guestBase + 0x30_000
        for index in UInt16(0)..<2 {
            try installDescriptor(
                queue: queue,
                index: index,
                address: buffers + UInt64(index) * 8,
                length: 8,
                flags: 2,
                next: 0,
                harness: harness
            )
        }
        try publish([0, 1], queue: queue, startingAt: 0, harness: harness)
        harness.device.send(frame: [VirtioInputEvent(type: 1, code: 30, value: 1)])
        #expect(publicationEntered.wait(timeout: .now() + 1) == .success)

        let resetFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            harness.transport.write(offset: 0x070, value: 0, width: 4)
            resetFinished.signal()
        }
        #expect(resetFinished.wait(timeout: .now() + 0.02) == .timedOut)
        releasePublication.signal()
        #expect(resetFinished.wait(timeout: .now() + 1) == .success)
        // Reset cannot revoke a publication already inside the transport critical section. It
        // waits for that bounded publication, then revokes the generation; the used index must
        // remain frozen after reset returns rather than receiving another late completion.
        #expect(try usedIndex(queue: queue, harness: harness) == 2)
        Thread.sleep(forTimeInterval: 0.02)
        #expect(try usedIndex(queue: queue, harness: harness) == 2)
        #expect(harness.device.statistics.publishedFrames == 1)
        #expect(harness.device.statistics.pendingFrameDepth == 0)
        #expect(harness.device.statistics.availableEventBufferDepth == 0)
    }

    @Test func resetRevokesAQueuedWorkerBeforeItCanPublish() throws {
        let workerEntered = DispatchSemaphore(value: 0)
        let releaseWorker = DispatchSemaphore(value: 0)
        let harness = try makeHarness(
            profile: .keyboard,
            limits: .init(
                maximumEventsPerFrame: 8,
                maximumPendingFrames: 8,
                maximumChainsPerWorkerTurn: 8
            ),
            workerHooks: VirtioInputWorkerHooks(
                beforeWorkerTurn: {
                    workerEntered.signal()
                    _ = releaseWorker.wait(timeout: .now() + 2)
                },
                beforeEventPublication: nil
            )
        )
        let queue = harness.queues[0]
        let buffers = harness.guestBase + 0x30_000
        for index in UInt16(0)..<2 {
            try installDescriptor(
                queue: queue,
                index: index,
                address: buffers + UInt64(index) * 8,
                length: 8,
                flags: 2,
                next: 0,
                harness: harness
            )
        }
        try publish([0, 1], queue: queue, startingAt: 0, harness: harness)
        harness.device.send(frame: [VirtioInputEvent(type: 1, code: 30, value: 1)])
        #expect(workerEntered.wait(timeout: .now() + 1) == .success)

        let resetFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            harness.transport.write(offset: 0x070, value: 0, width: 4)
            resetFinished.signal()
        }
        #expect(resetFinished.wait(timeout: .now() + 0.1) == .success)
        #expect(try usedIndex(queue: queue, harness: harness) == 0)
        releaseWorker.signal()
        #expect(waitUntil { harness.device.statistics.revokedWorkerTurns == 1 })
        Thread.sleep(forTimeInterval: 0.02)
        #expect(try usedIndex(queue: queue, harness: harness) == 0)
        #expect(harness.device.statistics.publishedFrames == 0)
    }

    private func makeHarness(
        profile: VirtioInput.Profile,
        limits: VirtioInputLimits,
        statusHandler: (@Sendable (VirtioInputEvent) -> Void)? = nil,
        workerHooks: VirtioInputWorkerHooks = .none,
        monotonicNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) throws -> Harness {
        let guestBase: UInt64 = 0xD100_0000
        let memory = try GuestMemory(guestBase: guestBase, size: 1 << 20)
        let device = VirtioInput(
            profile: profile,
            limits: limits,
            statusHandler: statusHandler,
            workerHooks: workerHooks,
            monotonicNanoseconds: monotonicNanoseconds
        )
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: device,
            memory: memory
        ) {}
        let queues = (0..<2).map { index in
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
        device.deviceReady(transport: transport)
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

    private func eventBytes(type: UInt16, code: UInt16, value: Int32) -> [UInt8] {
        var bytes = [UInt8]()
        bytes.appendLE(type)
        bytes.appendLE(code)
        bytes.appendLE(UInt32(bitPattern: value))
        return bytes
    }

    private func readEvent(at address: UInt64, harness: Harness) throws -> VirtioInputEvent {
        VirtioInputEvent(
            type: try harness.memory.read(UInt16.self, at: address),
            code: try harness.memory.read(UInt16.self, at: address + 2),
            value: Int32(bitPattern: try harness.memory.read(UInt32.self, at: address + 4))
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        _ predicate: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.001)
        }
        return predicate()
    }
}
