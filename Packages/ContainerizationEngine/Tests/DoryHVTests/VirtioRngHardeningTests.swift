import Foundation
import Testing
@testable import DoryHV

@Suite(.serialized) struct VirtioRngHardeningTests {
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

        @discardableResult
        func runAll(limit: Int = 64) -> Int {
            var count = 0
            while count < limit, runNext() {
                count += 1
            }
            return count
        }
    }

    private final class FillCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0

        func record() {
            lock.withLock { storage += 1 }
        }

        var calls: Int {
            lock.withLock { storage }
        }
    }

    private final class ManualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 100

        func read() -> UInt64 {
            lock.withLock {
                defer { value += 25 }
                return value
            }
        }
    }

    private struct QueueLayout {
        let descriptors: UInt64
        let available: UInt64
        let used: UInt64
    }

    @Test func writableRequestUsesTypedPartialCompletionWithoutGuestSizedAllocation() throws {
        let harness = try makeHarness(
            limits: .init(maximumBytesPerRequest: 4_096, maximumRequestsPerWorkerTurn: 8),
            fillEntropy: { buffer in
                buffer.initializeMemory(as: UInt8.self, repeating: 0x5a)
                return true
            }
        )
        let output = harness.guestBase + 0x20_000
        try harness.memory.write([UInt8](repeating: 0xa5, count: 8_192), at: output)
        try installDescriptor(
            index: 0,
            address: output,
            length: 8_192,
            flags: 2,
            next: 0,
            harness: harness
        )
        try publish([0], harness: harness)

        harness.device.handleKick(queue: 0, transport: harness.transport)
        #expect(harness.work.runAll() == 1)

        #expect(try usedIndex(harness) == 1)
        #expect(try usedLength(0, harness: harness) == 4_096)
        #expect(try harness.memory.read(UInt8.self, at: output) == 0x5a)
        #expect(try harness.memory.read(UInt8.self, at: output + 4_095) == 0x5a)
        #expect(try harness.memory.read(UInt8.self, at: output + 4_096) == 0xa5)
        #expect(harness.device.statistics.completedRequests == 1)
        #expect(harness.device.statistics.bytesProvided == 4_096)
    }

    @Test func readableMixedAndZeroLengthChainsAreRejectedWithoutEntropyWork() throws {
        let counter = FillCounter()
        let harness = try makeHarness(
            limits: .init(maximumBytesPerRequest: 256, maximumRequestsPerWorkerTurn: 8),
            fillEntropy: { buffer in
                counter.record()
                buffer.initializeMemory(as: UInt8.self, repeating: 0x33)
                return true
            }
        )
        let base = harness.guestBase + 0x20_000

        // A readable prefix followed by a writable tail is still invalid for virtio-entropy.
        try installDescriptor(index: 0, address: base, length: 32, flags: 1, next: 1, harness: harness)
        try installDescriptor(index: 1, address: base + 0x100, length: 32, flags: 2, next: 0, harness: harness)
        try installDescriptor(index: 2, address: base + 0x200, length: 0, flags: 2, next: 0, harness: harness)
        try installDescriptor(index: 3, address: base + 0x300, length: 64, flags: 2, next: 0, harness: harness)
        try publish([0, 2, 3], harness: harness)

        harness.device.handleKick(queue: 0, transport: harness.transport)
        #expect(harness.work.runAll() == 1)

        #expect(try usedIndex(harness) == 3)
        #expect(try usedLength(0, harness: harness) == 0)
        #expect(try usedLength(1, harness: harness) == 0)
        #expect(try usedLength(2, harness: harness) == 64)
        #expect(counter.calls == 1)
        #expect(harness.device.statistics.invalidRequests == 2)
        #expect(harness.device.statistics.completedRequests == 1)
    }

    @Test func entropyFailureCompletesZeroAndDoesNotPublishUninitializedBytes() throws {
        let harness = try makeHarness(
            limits: .init(maximumBytesPerRequest: 128, maximumRequestsPerWorkerTurn: 8),
            fillEntropy: { buffer in
                // Even a provider that dirties its host-owned destination before reporting
                // failure must not expose those bytes in the guest descriptor.
                buffer.initializeMemory(as: UInt8.self, repeating: 0x11)
                return false
            }
        )
        let output = harness.guestBase + 0x20_000
        try harness.memory.write([UInt8](repeating: 0xcc, count: 128), at: output)
        try installDescriptor(index: 0, address: output, length: 128, flags: 2, next: 0, harness: harness)
        try publish([0], harness: harness)

        harness.device.handleKick(queue: 0, transport: harness.transport)
        #expect(harness.work.runAll() == 1)

        #expect(try usedIndex(harness) == 1)
        #expect(try usedLength(0, harness: harness) == 0)
        #expect(try harness.memory.read(UInt8.self, at: output) == 0xcc)
        #expect(harness.device.statistics.entropyFailures == 1)
        #expect(harness.device.statistics.completedRequests == 0)
    }

    @Test func notifyingVCPUOnlyEnqueuesAndDuplicateKickCoalesces() throws {
        let counter = FillCounter()
        let clock = ManualClock()
        let harness = try makeHarness(
            limits: .init(maximumBytesPerRequest: 64, maximumRequestsPerWorkerTurn: 2),
            fillEntropy: { buffer in
                counter.record()
                buffer.initializeMemory(as: UInt8.self, repeating: 0x42)
                return true
            },
            monotonicNanoseconds: { clock.read() }
        )
        let output = harness.guestBase + 0x20_000
        try installDescriptor(
            index: 0,
            address: output,
            length: 64,
            flags: 2,
            next: 0,
            harness: harness
        )
        try publish([0], harness: harness)

        harness.device.handleKick(queue: 0, transport: harness.transport)
        harness.device.handleKick(queue: 0, transport: harness.transport)

        #expect(harness.device.kickSynchronization == .backendManaged)
        #expect(harness.work.pendingCount == 1)
        #expect(counter.calls == 0)
        #expect(try usedIndex(harness) == 0)
        #expect(harness.device.statistics.workerTurns == 0)
        #expect(harness.device.statistics.coalescedWorkerRequests == 1)

        #expect(harness.work.runAll() == 1)
        #expect(counter.calls == 1)
        #expect(try usedIndex(harness) == 1)
        #expect(harness.device.statistics.workerTurns == 1)
        #expect(harness.device.statistics.entropyProcessingNanoseconds == 25)
        #expect(harness.device.statistics.maximumEntropyProcessingNanoseconds == 25)
    }

    @Test func deviceResetRevokesQueuedTurnBeforeEntropyOrPublication() throws {
        let counter = FillCounter()
        let harness = try makeHarness(
            limits: .init(maximumBytesPerRequest: 64, maximumRequestsPerWorkerTurn: 2),
            fillEntropy: { buffer in
                counter.record()
                buffer.initializeMemory(as: UInt8.self, repeating: 0x51)
                return true
            }
        )
        let output = harness.guestBase + 0x20_000
        try installDescriptor(
            index: 0,
            address: output,
            length: 64,
            flags: 2,
            next: 0,
            harness: harness
        )
        try publish([0], harness: harness)
        harness.device.handleKick(queue: 0, transport: harness.transport)
        #expect(harness.work.pendingCount == 1)

        harness.transport.write(offset: 0x070, value: 0, width: 4)
        #expect(harness.work.runNext())

        #expect(counter.calls == 0)
        #expect(try usedIndex(harness) == 0)
        #expect(harness.device.statistics.completedRequests == 0)
        #expect(harness.device.statistics.revokedWorkerTurns == 1)
    }

    @Test func queueReadyChangeRevokesQueuedTurnBeforeEntropyOrPublication() throws {
        let counter = FillCounter()
        let harness = try makeHarness(
            limits: .init(maximumBytesPerRequest: 64, maximumRequestsPerWorkerTurn: 2),
            fillEntropy: { buffer in
                counter.record()
                buffer.initializeMemory(as: UInt8.self, repeating: 0x52)
                return true
            }
        )
        let output = harness.guestBase + 0x20_000
        try installDescriptor(
            index: 0,
            address: output,
            length: 64,
            flags: 2,
            next: 0,
            harness: harness
        )
        try publish([0], harness: harness)
        harness.device.handleKick(queue: 0, transport: harness.transport)

        harness.transport.write(offset: 0x030, value: 0, width: 4)
        harness.transport.write(offset: 0x044, value: 0, width: 4)
        #expect(harness.work.runNext())

        #expect(counter.calls == 0)
        #expect(try usedIndex(harness) == 0)
        #expect(harness.device.statistics.completedRequests == 0)
        #expect(harness.device.statistics.revokedWorkerTurns == 1)
    }

    @Test func resetWaitsForInFlightEntropyThenRevokesBeforeQueuePublication() throws {
        let fillEntered = DispatchSemaphore(value: 0)
        let allowFill = DispatchSemaphore(value: 0)
        let harness = try makeHarness(
            limits: .init(maximumBytesPerRequest: 64, maximumRequestsPerWorkerTurn: 1),
            fillEntropy: { buffer in
                fillEntered.signal()
                guard allowFill.wait(timeout: .now() + 2) == .success else { return false }
                buffer.initializeMemory(as: UInt8.self, repeating: 0x61)
                return true
            }
        )
        let output = harness.guestBase + 0x20_000
        try harness.memory.write([UInt8](repeating: 0xa5, count: 64), at: output)
        try installDescriptor(
            index: 0,
            address: output,
            length: 64,
            flags: 2,
            next: 0,
            harness: harness
        )
        try publish([0], harness: harness)
        harness.device.handleKick(queue: 0, transport: harness.transport)

        let workerReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            _ = harness.work.runNext()
            workerReturned.signal()
        }
        #expect(fillEntered.wait(timeout: .now() + 1) == .success)

        let resetStarted = DispatchSemaphore(value: 0)
        let resetReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            resetStarted.signal()
            harness.transport.write(offset: 0x070, value: 0, width: 4)
            resetReturned.signal()
        }
        #expect(resetStarted.wait(timeout: .now() + 1) == .success)
        #expect(resetReturned.wait(timeout: .now() + .milliseconds(100)) == .timedOut)

        allowFill.signal()
        #expect(resetReturned.wait(timeout: .now() + 1) == .success)
        #expect(workerReturned.wait(timeout: .now() + 1) == .success)

        // The bounded host fill finishes before reset returns. Reset owns the transport boundary,
        // so neither its snapshot's payload copy nor its used-ring publication can reach the guest.
        #expect(try harness.memory.read(UInt8.self, at: output) == 0xa5)
        #expect(try usedIndex(harness) == 0)
        #expect(harness.device.statistics.completedRequests == 0)
        #expect(harness.device.statistics.revokedWorkerTurns == 1)
    }

    @Test func boundedWorkerTurnsSelfRescheduleWithoutAnotherKick() throws {
        let harness = try makeHarness(
            limits: .init(maximumBytesPerRequest: 8, maximumRequestsPerWorkerTurn: 2),
            fillEntropy: { buffer in
                buffer.initializeMemory(as: UInt8.self, repeating: 0x7f)
                return true
            }
        )
        let base = harness.guestBase + 0x20_000
        for index in UInt16(0)..<3 {
            try installDescriptor(
                index: index,
                address: base + UInt64(index) * 0x100,
                length: 16,
                flags: 2,
                next: 0,
                harness: harness
            )
        }
        try publish([0, 1, 2], harness: harness)

        harness.device.handleKick(queue: 0, transport: harness.transport)
        #expect(try usedIndex(harness) == 0)
        #expect(harness.work.pendingCount == 1)
        #expect(harness.work.runNext())
        #expect(try usedIndex(harness) == 2)
        #expect(harness.device.statistics.boundedDrainStops == 1)
        #expect(harness.device.statistics.workerTurns == 1)
        #expect(harness.device.statistics.workerYields == 1)
        #expect(harness.work.pendingCount == 1)

        #expect(harness.work.runNext())
        #expect(try usedIndex(harness) == 3)
        #expect(try usedLength(2, harness: harness) == 8)
        #expect(harness.device.statistics.completedRequests == 3)
        #expect(harness.device.statistics.bytesProvided == 24)
        #expect(harness.device.statistics.workerTurns == 2)
        #expect(harness.work.pendingCount == 0)
    }

    @Test func malformedDescriptorIsAnObservableQueueFault() throws {
        let harness = try makeHarness(
            limits: .init(maximumBytesPerRequest: 64, maximumRequestsPerWorkerTurn: 8),
            fillEntropy: { _ in true }
        )
        try installDescriptor(
            index: 0,
            address: harness.guestBase + UInt64(harness.memory.size) + 0x100,
            length: 64,
            flags: 2,
            next: 0,
            harness: harness
        )
        try publish([0], harness: harness)

        harness.device.handleKick(queue: 0, transport: harness.transport)
        #expect(harness.work.runAll() == 1)

        #expect(try usedIndex(harness) == 0)
        #expect(harness.device.statistics.queueFaults == 1)
    }

    @Test(arguments: [false, true])
    func terminalStatusRejectsQueuedEntropyAndDirectResumeUntilReset(failed: Bool) throws {
        let counter = FillCounter()
        let harness = try makeHarness(
            limits: .init(maximumBytesPerRequest: 64, maximumRequestsPerWorkerTurn: 1),
            fillEntropy: { buffer in
                counter.record()
                buffer.initializeMemory(as: UInt8.self, repeating: 0x71)
                return true
            })
        let output = harness.guestBase + 0x20_000
        try harness.memory.write([UInt8](repeating: 0xa5, count: 64), at: output)
        try installDescriptor(index: 0, address: output, length: 64, flags: 2, next: 0, harness: harness)
        try publish([0], harness: harness)
        harness.transport.write(offset: 0x050, value: 0, width: 4)
        try #require(harness.work.pendingCount == 1)
        markTerminal(harness, failed: failed)
        try #require(harness.work.runNext())
        #expect(counter.calls == 0)
        #expect(try usedIndex(harness) == 0)
        #expect(try harness.memory.read(UInt8.self, at: output) == 0xa5)
        #expect(harness.transport.withQueueLock { try? harness.transport.queues[0].pendingCount() } == 1)
        harness.device.handleKick(queue: 0, transport: harness.transport)
        harness.transport.write(offset: 0x070, value: 0x0F, width: 4)
        harness.transport.write(offset: 0x050, value: 0, width: 4)
        #expect(harness.work.pendingCount == 0)
        #expect(harness.device.statistics.completedRequests == 0)
        #expect(harness.transport.read(offset: 0x070, width: 4) == (failed ? 0x8F : 0x4F))

        try resetAndConfigureQueue(harness)
        try publish([0], harness: harness)
        harness.transport.write(offset: 0x050, value: 0, width: 4)
        try #require(harness.work.runNext())
        #expect(counter.calls == 1)
        #expect(try usedIndex(harness) == 1)
        #expect(try harness.memory.read(UInt8.self, at: output) == 0x71)
        #expect(harness.work.pendingCount == 0)
    }

    @Test(arguments: [false, true])
    func terminalStatusDuringHostFillRejectsBothPayloadAndUsedRingDMA(failed: Bool) throws {
        let counter = FillCounter()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let harness = try makeHarness(
            limits: .init(maximumBytesPerRequest: 64, maximumRequestsPerWorkerTurn: 1),
            fillEntropy: { buffer in
                counter.record()
                entered.signal()
                guard release.wait(timeout: .now() + 5) == .success else { return false }
                buffer.initializeMemory(as: UInt8.self, repeating: 0x72)
                return true
            })
        defer { release.signal() }
        let output = harness.guestBase + 0x20_000
        try harness.memory.write([UInt8](repeating: 0xa5, count: 64), at: output)
        try installDescriptor(index: 0, address: output, length: 64, flags: 2, next: 0, harness: harness)
        try publish([0], harness: harness)
        harness.transport.write(offset: 0x050, value: 0, width: 4)
        let returned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = harness.work.runNext()
            returned.signal()
        }
        try #require(entered.wait(timeout: .now() + 1) == .success)
        let statusReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            if failed { harness.transport.write(offset: 0x070, value: 0x80, width: 4) }
            else { harness.transport.requestDeviceReset() }
            statusReturned.signal()
        }
        try #require(statusReturned.wait(timeout: .now() + 1) == .success)
        release.signal()
        try #require(returned.wait(timeout: .now() + 1) == .success)
        #expect(counter.calls == 1)
        #expect(try harness.memory.readBytes(at: output, count: 64) == [UInt8](repeating: 0xa5, count: 64))
        #expect(try usedIndex(harness) == 0)
        #expect(harness.device.statistics.completedRequests == 0)
        #expect(harness.work.pendingCount == 0)
        try resetAndConfigureQueue(harness)
        try publish([0], harness: harness)
        release.signal()
        harness.transport.write(offset: 0x050, value: 0, width: 4)
        try #require(harness.work.runNext())
        #expect(counter.calls == 2)
        #expect(try usedIndex(harness) == 1)
        #expect(try harness.memory.read(UInt8.self, at: output) == 0x72)
    }

    @Test(arguments: [false, true])
    func terminalResetOldQueuedTurnCannotRetireOrConsumeSuccessorWork(failed: Bool) throws {
        let counter = FillCounter()
        let harness = try makeHarness(
            limits: .init(maximumBytesPerRequest: 64, maximumRequestsPerWorkerTurn: 1),
            fillEntropy: { buffer in
                counter.record()
                buffer.initializeMemory(as: UInt8.self, repeating: 0x73)
                return true
            })
        let oldOutput = harness.guestBase + 0x20_000
        let newOutput = oldOutput + 0x100
        try harness.memory.write([UInt8](repeating: 0xa5, count: 64), at: oldOutput)
        try harness.memory.write([UInt8](repeating: 0xa5, count: 64), at: newOutput)
        try installDescriptor(index: 0, address: oldOutput, length: 64, flags: 2, next: 0, harness: harness)
        try publish([0], harness: harness)
        harness.transport.write(offset: 0x050, value: 0, width: 4)
        markTerminal(harness, failed: failed)
        try resetAndConfigureQueue(harness)
        try installDescriptor(index: 0, address: newOutput, length: 64, flags: 2, next: 0, harness: harness)
        try publish([0], harness: harness)
        harness.transport.write(offset: 0x050, value: 0, width: 4)
        try #require(harness.work.pendingCount == 2)
        try #require(harness.work.runNext())
        #expect(counter.calls == 0)
        #expect(try usedIndex(harness) == 0)
        #expect(try harness.memory.read(UInt8.self, at: newOutput) == 0xa5)
        try #require(harness.work.runNext())
        #expect(counter.calls == 1)
        #expect(try usedIndex(harness) == 1)
        #expect(try harness.memory.read(UInt8.self, at: newOutput) == 0x73)
        #expect(try harness.memory.read(UInt8.self, at: oldOutput) == 0xa5)
        #expect(harness.work.pendingCount == 0)
    }

    @Test(arguments: [false, true])
    func directLifecycleRevocationCannotReplayQueuedTurnAgainstLiveSuccessor(queueChange: Bool) throws {
        let counter = FillCounter()
        let harness = try makeHarness(
            limits: .init(maximumBytesPerRequest: 64, maximumRequestsPerWorkerTurn: 1),
            fillEntropy: { buffer in
                counter.record()
                buffer.initializeMemory(as: UInt8.self, repeating: 0x74)
                return true
            })
        let output = harness.guestBase + 0x20_000
        try harness.memory.write([UInt8](repeating: 0xa5, count: 64), at: output)
        try installDescriptor(index: 0, address: output, length: 64, flags: 2, next: 0, harness: harness)
        try publish([0], harness: harness)
        harness.device.handleKick(queue: 0, transport: harness.transport)
        if queueChange {
            harness.device.queueStateChanged(queue: 0, ready: true, transport: harness.transport)
        } else {
            harness.device.deviceReset(transport: harness.transport)
        }
        // Unlike an MMIO status-zero write, direct backend revocation leaves this ready ring live.
        // The stale closure must not acquire the fresh backend executor's admission or clear it.
        harness.device.handleKick(queue: 0, transport: harness.transport)
        try #require(harness.work.pendingCount == 2)
        try #require(harness.work.runNext())
        #expect(counter.calls == 0)
        #expect(try usedIndex(harness) == 0)
        #expect(try harness.memory.read(UInt8.self, at: output) == 0xa5)
        try #require(harness.work.runNext())
        #expect(counter.calls == 1)
        #expect(try usedIndex(harness) == 1)
        #expect(try harness.memory.read(UInt8.self, at: output) == 0x74)
        #expect(harness.work.pendingCount == 0)
    }

    private func markTerminal(_ harness: Harness, failed: Bool) {
        if failed { harness.transport.write(offset: 0x070, value: 0x80, width: 4) }
        else { harness.transport.requestDeviceReset() }
    }

    private func resetAndConfigureQueue(_ harness: Harness) throws {
        harness.transport.write(offset: 0x070, value: 0, width: 4)
        #expect(harness.transport.negotiatedFeatures == 0)
        #expect(!harness.transport.queues[0].ready)
        finishMMIOTestDriverNegotiation(harness.transport)
        harness.transport.write(offset: 0x030, value: 0, width: 4)
        harness.transport.write(offset: 0x038, value: 8, width: 4)
        harness.transport.write(offset: 0x080, value: harness.queue.descriptors, width: 4)
        harness.transport.write(offset: 0x090, value: harness.queue.available, width: 4)
        harness.transport.write(offset: 0x0A0, value: harness.queue.used, width: 4)
        harness.transport.write(offset: 0x044, value: 1, width: 4)
        try #require(harness.transport.queues[0].ready)
        try harness.memory.write(UInt16(0), at: harness.queue.available + 2)
        try harness.memory.write(UInt16(0), at: harness.queue.used + 2)
    }

    private struct Harness {
        let guestBase: UInt64
        let memory: GuestMemory
        let transport: VirtioMMIOTransport
        let device: VirtioRng
        let queue: QueueLayout
        let work: ManualWorkQueue
    }

    private func makeHarness(
        limits: VirtioRngLimits,
        fillEntropy: @escaping @Sendable (UnsafeMutableRawBufferPointer) -> Bool,
        work: ManualWorkQueue = ManualWorkQueue(),
        monotonicNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) throws -> Harness {
        let guestBase: UInt64 = 0xD000_0000
        let memory = try GuestMemory(guestBase: guestBase, size: 1 << 20)
        let device = VirtioRng(
            limits: limits,
            fillEntropy: fillEntropy,
            submitWork: { work.submit($0) },
            monotonicNanoseconds: monotonicNanoseconds
        )
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: device,
            memory: memory
        ) {}
        finishMMIOTestDriverNegotiation(transport)
        let queue = QueueLayout(
            descriptors: guestBase + 0x10_000,
            available: guestBase + 0x12_000,
            used: guestBase + 0x14_000
        )
        #expect(transport.queues[0].configure(
            size: 8,
            descriptorTable: queue.descriptors,
            availRing: queue.available,
            usedRing: queue.used
        ))
        #expect(transport.queues[0].setReady(true))
        try memory.write(UInt16(0), at: queue.available)
        try memory.write(UInt16(0), at: queue.available + 2)
        try memory.write(UInt16(0), at: queue.used + 2)
        return Harness(
            guestBase: guestBase,
            memory: memory,
            transport: transport,
            device: device,
            queue: queue,
            work: work
        )
    }

    private func installDescriptor(
        index: UInt16,
        address: UInt64,
        length: Int,
        flags: UInt16,
        next: UInt16,
        harness: Harness
    ) throws {
        let descriptor = harness.queue.descriptors + UInt64(index) * 16
        try harness.memory.write(address, at: descriptor)
        try harness.memory.write(UInt32(length), at: descriptor + 8)
        try harness.memory.write(flags, at: descriptor + 12)
        try harness.memory.write(next, at: descriptor + 14)
    }

    private func publish(_ heads: [UInt16], harness: Harness) throws {
        for (index, head) in heads.enumerated() {
            try harness.memory.write(
                head,
                at: harness.queue.available + 4 + UInt64(index) * 2
            )
        }
        try harness.memory.write(UInt16(heads.count), at: harness.queue.available + 2)
    }

    private func usedIndex(_ harness: Harness) throws -> UInt16 {
        try harness.memory.read(UInt16.self, at: harness.queue.used + 2)
    }

    private func usedLength(_ index: Int, harness: Harness) throws -> UInt32 {
        try harness.memory.read(
            UInt32.self,
            at: harness.queue.used + 8 + UInt64(index) * 8
        )
    }
}
