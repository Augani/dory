import Foundation
import Testing
@testable import DoryHV

@Suite struct VirtioSoundHardeningTests {
    @Test func rejectsWrongDirectionOrderAndZeroLengthOnEveryQueue() throws {
        let host = HardenedSoundHost()
        let scheduler = ManualSoundScheduler()
        let sound = makeSound(host: host, scheduler: scheduler)
        #expect(status(sound, setParameters(streamID: 0)) == 0x8000)
        #expect(status(sound, lifecycle(0x0102, streamID: 0)) == 0x8000)
        #expect(status(sound, setParameters(streamID: 1)) == 0x8000)
        #expect(status(sound, lifecycle(0x0102, streamID: 1)) == 0x8000)

        let control = try SoundTestRing(sound: sound, queueIndex: 0)
        _ = try control.submit(
            head: 0,
            slot: 0,
            segments: [
                .readable(setParameters(streamID: 0)),
                .writable(length: 0),
            ]
        )
        sound.handleKick(queue: 0, transport: control.transport)
        #expect(try control.usedIndex() == 1)
        #expect(try control.usedLength(slot: 0) == 0)

        let event = try SoundTestRing(sound: sound, queueIndex: 1)
        _ = try event.submit(
            head: 0,
            slot: 0,
            segments: [.readable([UInt8](repeating: 0, count: 8))]
        )
        sound.handleKick(queue: 1, transport: event.transport)
        #expect(try event.usedIndex() == 1)
        #expect(try event.usedLength(slot: 0) == 0)

        var playbackRequest = [UInt8]()
        playbackRequest.appendLE(UInt32(0))
        playbackRequest.append(contentsOf: repeatElement(0x44, count: 16))
        let playback = try SoundTestRing(sound: sound, queueIndex: 2)
        _ = try playback.submit(
            head: 0,
            slot: 0,
            segments: [
                .writable(length: 8),
                .readable(playbackRequest),
            ]
        )
        sound.handleKick(queue: 2, transport: playback.transport)
        #expect(try playback.usedIndex() == 1)
        #expect(try playback.usedLength(slot: 0) == 0)
        #expect(host.playbackCallCount == 0)

        var captureHeader = [UInt8]()
        captureHeader.appendLE(UInt32(1))
        let capture = try SoundTestRing(sound: sound, queueIndex: 3)
        _ = try capture.submit(
            head: 0,
            slot: 0,
            segments: [
                .writable(length: 24),
                .readable(captureHeader),
            ]
        )
        sound.handleKick(queue: 3, transport: capture.transport)
        #expect(try capture.usedIndex() == 1)
        #expect(try capture.usedLength(slot: 0) == 0)
        #expect(host.captureCallCount == 0)

        let metrics = sound.statistics
        #expect(metrics.invalidControlChains == 1)
        #expect(metrics.invalidEventChains == 1)
        #expect(metrics.invalidPlaybackChains == 1)
        #expect(metrics.invalidCaptureChains == 1)
    }

    @Test func preflightsCompleteControlResponseBeforeHostMutation() {
        let host = HardenedSoundHost()
        let sound = makeSound(host: host, scheduler: ManualSoundScheduler())

        #expect(sound.controlResponseForTesting(
            setParameters(streamID: 0),
            responseCapacity: 3
        ).isEmpty)
        #expect(host.configureCallCount == 0)

        #expect(status(sound, setParameters(streamID: 0)) == 0x8000)
        #expect(host.configureCallCount == 1)
        #expect(sound.controlResponseForTesting(
            lifecycle(0x0102, streamID: 0),
            responseCapacity: 3
        ).isEmpty)
        #expect(host.prepareCallCount == 0)
        #expect(status(sound, lifecycle(0x0102, streamID: 0)) == 0x8000)
        #expect(host.prepareCallCount == 1)

        var info = [UInt8]()
        info.appendLE(UInt32(0x0100))
        info.appendLE(UInt32(0))
        info.appendLE(UInt32(2))
        info.appendLE(UInt32(32))
        #expect(sound.controlResponseForTesting(info, responseCapacity: 67).leUInt32(at: 0) == 0x8001)
    }

    @Test func rejectsOversizeParametersAndPCMBeforeHostAdmission() throws {
        let host = HardenedSoundHost()
        let scheduler = ManualSoundScheduler()
        let limits = testLimits(maximumPeriods: 4)
        let sound = makeSound(host: host, scheduler: scheduler, limits: limits)

        #expect(status(sound, setParameters(
            streamID: 0,
            bufferBytes: 68,
            periodBytes: 4
        )) == 0x8002)
        #expect(host.configureCallCount == 0)
        #expect(status(sound, setParameters(
            streamID: 0,
            bufferBytes: 64,
            periodBytes: 16
        )) == 0x8000)
        #expect(status(sound, lifecycle(0x0102, streamID: 0)) == 0x8000)

        var request = [UInt8]()
        request.appendLE(UInt32(0))
        request.append(contentsOf: repeatElement(0x61, count: 20))
        let ring = try SoundTestRing(sound: sound, queueIndex: 2)
        _ = try ring.submit(
            head: 0,
            slot: 0,
            segments: [.readable(request), .writable(length: 8)]
        )
        sound.handleKick(queue: 2, transport: ring.transport)

        #expect(host.playbackCallCount == 0)
        #expect(try ring.usedIndex() == 1)
        #expect(try ring.usedLength(slot: 0) == 0)
        #expect(sound.statistics.invalidPlaybackChains == 1)
    }

    @Test func appliesBackpressureWithoutPoppingBeyondTheInflightPeriodCap() throws {
        let host = HardenedSoundHost()
        host.acceptPlayback = true
        let scheduler = ManualSoundScheduler()
        let sound = makeSound(
            host: host,
            scheduler: scheduler,
            limits: testLimits(maximumPeriods: 1)
        )
        #expect(status(sound, setParameters(
            streamID: 0,
            bufferBytes: 16,
            periodBytes: 16
        )) == 0x8000)
        #expect(status(sound, lifecycle(0x0102, streamID: 0)) == 0x8000)

        let ring = try SoundTestRing(sound: sound, queueIndex: 2)
        var first = [UInt8]()
        first.appendLE(UInt32(0))
        first.append(contentsOf: repeatElement(0x11, count: 16))
        var second = [UInt8]()
        second.appendLE(UInt32(0))
        second.append(contentsOf: repeatElement(0x22, count: 16))
        _ = try ring.submit(
            head: 0,
            slot: 0,
            segments: [.readable(first), .writable(length: 8)]
        )
        _ = try ring.submit(
            head: 2,
            slot: 1,
            segments: [.readable(second), .writable(length: 8)]
        )

        sound.handleKick(queue: 2, transport: ring.transport)
        #expect(host.playbackCallCount == 1)
        #expect(ring.queue.hasPending)
        #expect(try ring.usedIndex() == 0)
        #expect(sound.statistics.backpressuredPeriods == 1)

        host.finishPlayback(at: 0, success: true, latency: 0)
        #expect(try ring.usedIndex() == 1)
        sound.handleKick(queue: 2, transport: ring.transport)
        #expect(host.playbackCallCount == 2)
        #expect(!ring.queue.hasPending)
    }

    @Test func resetRevokesPendingCompletionAndCancelsItsWatchdog() throws {
        let host = HardenedSoundHost()
        host.acceptPlayback = true
        let scheduler = ManualSoundScheduler()
        let sound = makeSound(host: host, scheduler: scheduler)
        #expect(status(sound, setParameters(streamID: 0)) == 0x8000)
        #expect(status(sound, lifecycle(0x0102, streamID: 0)) == 0x8000)

        let ring = try playbackRing(sound: sound)
        sound.handleKick(queue: 2, transport: ring.transport)
        #expect(host.playbackCallCount == 1)
        #expect(scheduler.activeCount == 1)

        ring.transport.write(offset: 0x070, value: 0, width: 4)
        #expect(host.resetCallCount == 1)
        #expect(scheduler.activeCount == 0)
        host.finishPlayback(at: 0, success: true, latency: 99)

        #expect(try ring.usedIndex() == 0)
        #expect(sound.statistics.lateHostCompletions == 1)
    }

    @Test func watchdogCompletesWithIOErrorAndLateHostCallbackCannotRepublish() throws {
        let host = HardenedSoundHost()
        host.acceptPlayback = true
        let scheduler = ManualSoundScheduler()
        let sound = makeSound(host: host, scheduler: scheduler)
        #expect(status(sound, setParameters(streamID: 0)) == 0x8000)
        #expect(status(sound, lifecycle(0x0102, streamID: 0)) == 0x8000)

        let ring = try playbackRing(sound: sound)
        let responseAddress = try #require(ring.lastSubmissionAddresses.last)
        sound.handleKick(queue: 2, transport: ring.transport)
        #expect(try ring.usedIndex() == 0)

        scheduler.fireAll()
        #expect(try ring.usedIndex() == 1)
        #expect(try ring.usedLength(slot: 0) == 8)
        #expect(try ring.memory.read(UInt32.self, at: responseAddress) == 0x8003)
        #expect(sound.statistics.timedOutPeriods == 1)

        host.finishPlayback(at: 0, success: true, latency: 123)
        #expect(try ring.usedIndex() == 1)
        #expect(sound.statistics.lateHostCompletions == 1)
    }

    @Test func malformedRingFaultIsTerminalAndObservableUntilQueueReconfiguration() throws {
        let host = HardenedSoundHost()
        let sound = makeSound(host: host, scheduler: ManualSoundScheduler())
        let ring = try SoundTestRing(sound: sound, queueIndex: 2)
        try ring.memory.write(UInt16(99), at: ring.availableRing + 4)
        try ring.memory.write(UInt16(1), at: ring.availableRing + 2)

        sound.handleKick(queue: 2, transport: ring.transport)
        #expect(sound.statistics.queueFaults == 1)
        sound.handleKick(queue: 2, transport: ring.transport)
        #expect(sound.statistics.queueFaults == 1)

        ring.queue.setReady(true)
        sound.queueStateChanged(queue: 2, ready: true, transport: ring.transport)
        sound.handleKick(queue: 2, transport: ring.transport)
        #expect(sound.statistics.queueFaults == 2)
    }

    private func makeSound(
        host: HardenedSoundHost,
        scheduler: ManualSoundScheduler,
        limits: VirtioSoundLimits? = nil
    ) -> VirtioSound {
        VirtioSound(
            host: host,
            limits: limits ?? testLimits(maximumPeriods: 4),
            completionScheduler: scheduler
        )
    }

    private func testLimits(maximumPeriods: Int) -> VirtioSoundLimits {
        VirtioSoundLimits(
            maximumBufferBytes: 64,
            maximumPeriodBytes: 16,
            maximumPeriodsPerStream: maximumPeriods,
            maximumChainsPerKick: 8,
            maximumBytesPerKick: 64,
            maximumRetainedEventBuffers: 8,
            completionTimeout: .seconds(1)
        )
    }

    private func playbackRing(sound: VirtioSound) throws -> SoundTestRing {
        let ring = try SoundTestRing(sound: sound, queueIndex: 2)
        var request = [UInt8]()
        request.appendLE(UInt32(0))
        request.append(contentsOf: repeatElement(0x40, count: 16))
        _ = try ring.submit(
            head: 0,
            slot: 0,
            segments: [.readable(request), .writable(length: 8)]
        )
        return ring
    }

    private func status(_ sound: VirtioSound, _ request: [UInt8]) -> UInt32 {
        sound.controlResponseForTesting(request).leUInt32(at: 0)
    }

    private func lifecycle(_ code: UInt32, streamID: UInt32) -> [UInt8] {
        var request = [UInt8]()
        request.appendLE(code)
        request.appendLE(streamID)
        return request
    }

    private func setParameters(
        streamID: UInt32,
        bufferBytes: UInt32 = 64,
        periodBytes: UInt32 = 16
    ) -> [UInt8] {
        var request = [UInt8]()
        request.appendLE(UInt32(0x0101))
        request.appendLE(streamID)
        request.appendLE(bufferBytes)
        request.appendLE(periodBytes)
        request.appendLE(UInt32(0))
        request.append(2)
        request.append(5)
        request.append(7)
        request.append(0)
        return request
    }
}

private struct SoundTestSegment {
    var bytes: [UInt8]
    var length: UInt32
    var writable: Bool

    static func readable(_ bytes: [UInt8]) -> SoundTestSegment {
        SoundTestSegment(bytes: bytes, length: UInt32(bytes.count), writable: false)
    }

    static func writable(length: UInt32) -> SoundTestSegment {
        SoundTestSegment(bytes: [], length: length, writable: true)
    }
}

private final class SoundTestRing {
    let memory: GuestMemory
    let transport: VirtioMMIOTransport
    let queue: Virtqueue
    let descriptorTable: UInt64
    let availableRing: UInt64
    let usedRing: UInt64
    private let bufferBase: UInt64
    private(set) var lastSubmissionAddresses = [UInt64]()

    init(sound: VirtioSound, queueIndex: Int) throws {
        let base = GuestLayout.ramBase
        descriptorTable = base + 0x1000
        availableRing = base + 0x2000
        usedRing = base + 0x3000
        bufferBase = base + 0x4000
        memory = try GuestMemory(guestBase: base, size: 32 * HostPage.size)
        transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: sound,
            memory: memory
        ) {}
        queue = transport.queues[queueIndex]
        queue.configure(
            size: 8,
            descriptorTable: descriptorTable,
            availRing: availableRing,
            usedRing: usedRing
        )
        queue.setReady(true)
        try memory.write(UInt16(0), at: availableRing)
        try memory.write(UInt16(0), at: availableRing + 2)
        try memory.write(UInt16(0), at: usedRing + 2)
    }

    @discardableResult
    func submit(
        head: UInt16,
        slot: UInt16,
        segments: [SoundTestSegment]
    ) throws -> [UInt64] {
        var addresses = [UInt64]()
        for (offset, segment) in segments.enumerated() {
            let index = UInt16(Int(head) + offset)
            let address = bufferBase + UInt64(index) * 0x1000
            addresses.append(address)
            if !segment.bytes.isEmpty {
                try memory.write(segment.bytes, at: address)
            }
            let hasNext = offset + 1 < segments.count
            let flags: UInt16 = (hasNext ? 1 : 0) | (segment.writable ? 2 : 0)
            try writeDescriptor(
                index: index,
                address: address,
                length: segment.length,
                flags: flags,
                next: hasNext ? index + 1 : 0
            )
        }
        try memory.write(head, at: availableRing + 4 + UInt64(slot) * 2)
        try memory.write(slot + 1, at: availableRing + 2)
        lastSubmissionAddresses = addresses
        return addresses
    }

    func usedIndex() throws -> UInt16 {
        try memory.read(UInt16.self, at: usedRing + 2)
    }

    func usedLength(slot: UInt16) throws -> UInt32 {
        try memory.read(UInt32.self, at: usedRing + 8 + UInt64(slot) * 8)
    }

    private func writeDescriptor(
        index: UInt16,
        address: UInt64,
        length: UInt32,
        flags: UInt16,
        next: UInt16
    ) throws {
        let descriptor = descriptorTable + UInt64(index) * 16
        try memory.write(address, at: descriptor)
        try memory.write(length, at: descriptor + 8)
        try memory.write(flags, at: descriptor + 12)
        try memory.write(next, at: descriptor + 14)
    }
}

private final class ManualSoundScheduledOperation:
    VirtioSoundScheduledOperation,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var operation: (@Sendable () -> Void)?

    init(operation: @escaping @Sendable () -> Void) {
        self.operation = operation
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return operation != nil
    }

    func cancel() {
        lock.lock()
        operation = nil
        lock.unlock()
    }

    func fire() {
        lock.lock()
        let value = operation
        operation = nil
        lock.unlock()
        value?()
    }
}

private final class ManualSoundScheduler: VirtioSoundCompletionScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var operations = [ManualSoundScheduledOperation]()

    func schedule(
        after delay: Duration,
        operation: @escaping @Sendable () -> Void
    ) -> any VirtioSoundScheduledOperation {
        let scheduled = ManualSoundScheduledOperation(operation: operation)
        lock.lock()
        operations.append(scheduled)
        lock.unlock()
        return scheduled
    }

    var activeCount: Int {
        lock.lock()
        let values = operations
        lock.unlock()
        return values.lazy.filter(\.isActive).count
    }

    func fireAll() {
        lock.lock()
        let values = operations
        lock.unlock()
        values.forEach { $0.fire() }
    }
}

private final class HardenedSoundHost: VirtioSoundHost, @unchecked Sendable {
    private let lock = NSLock()
    var acceptPlayback = false
    var acceptCapture = false
    private var configureCalls = 0
    private var prepareCalls = 0
    private var resetCalls = 0
    private var playbackCompletions = [@Sendable (Bool, UInt32) -> Void]()
    private var captureCompletions = [@Sendable (Data?, UInt32) -> Void]()

    var configureCallCount: Int { withLock { configureCalls } }
    var prepareCallCount: Int { withLock { prepareCalls } }
    var resetCallCount: Int { withLock { resetCalls } }
    var playbackCallCount: Int { withLock { playbackCompletions.count } }
    var captureCallCount: Int { withLock { captureCompletions.count } }

    func configure(
        streamID: Int,
        direction: VirtioSoundDirection,
        parameters: VirtioSoundPCMParameters
    ) -> Bool {
        withLock { configureCalls += 1 }
        return true
    }

    func prepare(streamID: Int, direction: VirtioSoundDirection) -> Bool {
        withLock { prepareCalls += 1 }
        return true
    }

    func start(streamID: Int, direction: VirtioSoundDirection) -> Bool { true }
    func stop(streamID: Int, direction: VirtioSoundDirection) -> Bool { true }
    func release(streamID: Int, direction: VirtioSoundDirection) {}

    func enqueuePlayback(
        _ data: Data,
        parameters: VirtioSoundPCMParameters,
        completion: @escaping @Sendable (Bool, UInt32) -> Void
    ) -> Bool {
        guard acceptPlayback else { return false }
        withLock { playbackCompletions.append(completion) }
        return true
    }

    func requestCapture(
        byteCount: Int,
        parameters: VirtioSoundPCMParameters,
        completion: @escaping @Sendable (Data?, UInt32) -> Void
    ) -> Bool {
        guard acceptCapture else { return false }
        withLock { captureCompletions.append(completion) }
        return true
    }

    func reset() {
        withLock { resetCalls += 1 }
    }

    func finishPlayback(at index: Int, success: Bool, latency: UInt32) {
        let completion: (@Sendable (Bool, UInt32) -> Void)? = withLock {
            playbackCompletions.indices.contains(index) ? playbackCompletions[index] : nil
        }
        completion?(success, latency)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
