import Foundation
import Testing
@testable import DoryHV

@Suite struct VirtioMMIOAdmissionTests {
    @Test(arguments: [VirtioKickSynchronization.transportLocked, .backendManaged])
    func readyRingCannotPerformDMABeforeDriverOK(mode: VirtioKickSynchronization) throws {
        let backend = AdmissionRingBackend(mode: mode)
        let harness = try AdmissionRingHarness(backend: backend)
        try harness.configureQueue()
        try harness.publish()
        for status in [UInt64(0), 4, 1, 3] {
            if status != 0 { harness.transport.write(offset: 0x070, value: status, width: 4) }
            harness.kick()
            #expect(backend.kicks == 0)
            #expect(try harness.usedIndex() == 0)
            #expect(try harness.bytes() == [0xA5, 0xA5, 0xA5, 0xA5])
        }
        harness.writeFeatures(VirtqueueFeature.version1)
        harness.transport.write(offset: 0x070, value: 0x0B, width: 4)
        harness.kick()
        #expect(backend.kicks == 0)
        #expect(try harness.usedIndex() == 0)
        harness.transport.write(offset: 0x070, value: 0x0F, width: 4)
        harness.kick()
        #expect(backend.failure == nil)
        #expect(backend.kicks == 1 && backend.readyCalls == 1)
        #expect(try harness.usedIndex() == 1)
        #expect(try harness.bytes() == AdmissionRingBackend.response)
    }

    @Test(arguments: [VirtioKickSynchronization.transportLocked, .backendManaged], [false, true])
    func terminalStatusRejectsNewDoorbellDMATillReset(
        mode: VirtioKickSynchronization, failed: Bool
    ) throws {
        let backend = AdmissionRingBackend(mode: mode)
        let harness = try AdmissionRingHarness(backend: backend)
        harness.negotiate(VirtqueueFeature.version1)
        try harness.configureQueue()
        try harness.publish()
        if failed {
            harness.transport.write(offset: 0x070, value: 0x80, width: 4)
        } else {
            harness.transport.requestDeviceReset()
        }
        harness.transport.write(offset: 0x070, value: 0x0F, width: 4)
        harness.kick()
        #expect(backend.kicks == 0)
        #expect(backend.readyCalls == 1)
        #expect(try harness.usedIndex() == 0)
        #expect(try harness.bytes() == [0xA5, 0xA5, 0xA5, 0xA5])
        #expect(harness.transport.read(offset: 0x070, width: 4) == (failed ? 0x8F : 0x4F))
        harness.transport.write(offset: 0x070, value: 0, width: 4)
        #expect(harness.transport.read(offset: 0x070, width: 4) == 0)
        #expect(harness.transport.negotiatedFeatures == 0)
        #expect(!harness.transport.queues[0].ready)
        harness.negotiate(VirtqueueFeature.version1)
        try harness.configureQueue()
        try harness.publish()
        harness.kick()
        #expect(backend.failure == nil)
        #expect(backend.kicks == 1 && backend.readyCalls == 2)
        #expect(try harness.usedIndex() == 1)
    }

    @Test func acceptedFeaturesCannotChangeLiveIndirectOrEventInterpretation() throws {
        let backend = AdmissionRingBackend(mode: .transportLocked)
        let harness = try AdmissionRingHarness(backend: backend)
        let accepted = VirtqueueFeature.version1 | VirtqueueFeature.indirectDescriptors
        harness.negotiate(accepted)
        try harness.configureQueue()
        try harness.publish(indirect: true)
        let availableEvent = harness.used + 4 + 8 * 8
        let usedEvent = harness.available + 4 + 8 * 2
        try harness.memory.write(UInt16(0xA55A), at: availableEvent)
        try harness.memory.write(UInt16(0x5AA5), at: usedEvent)
        // Both driver words are now immutable. Neither enabling EVENT_IDX/removing INDIRECT nor
        // removing VERSION_1 may alter the already configured ring's DMA interpretation.
        harness.writeFeatures(VirtqueueFeature.eventIndex)
        harness.transport.write(offset: 0x070, value: 0x0F, width: 4)
        harness.transport.write(offset: 0x070, value: 1, width: 4)
        #expect(harness.transport.read(offset: 0x070, width: 4) == 0x0F)
        #expect(harness.transport.negotiatedFeatures == accepted)
        #expect(harness.transport.queues[0].negotiatedFeatures == accepted)
        #expect(backend.readyCalls == 1)
        harness.kick()
        #expect(backend.failure == nil)
        #expect(try harness.bytes() == AdmissionRingBackend.response)
        #expect(try harness.usedIndex() == 1)
        #expect(try harness.memory.read(UInt16.self, at: availableEvent) == 0xA55A)
        #expect(try harness.memory.read(UInt16.self, at: usedEvent) == 0x5AA5)
    }

    @Test(arguments: [UInt64(2), 4, 8, 14])
    func missingStatusPrerequisitesCannotAdmitDMA(status: UInt64) throws {
        let backend = AdmissionRingBackend(mode: .transportLocked)
        let harness = try AdmissionRingHarness(backend: backend)
        harness.writeFeatures(VirtqueueFeature.version1)
        try harness.configureQueue()
        try harness.publish()
        harness.transport.write(offset: 0x070, value: status, width: 4)
        harness.kick()
        #expect(harness.transport.read(offset: 0x070, width: 4) == 0)
        #expect(harness.transport.negotiatedFeatures == 0)
        #expect(backend.kicks == 0 && backend.readyCalls == 0)
        #expect(try harness.usedIndex() == 0)
        #expect(try harness.bytes() == [0xA5, 0xA5, 0xA5, 0xA5])
    }

    @Test func rejectedFeaturesCanBeCorrectedBeforeAcceptanceButResetIsRequiredAfterward() throws {
        let backend = AdmissionRingBackend(mode: .backendManaged)
        let harness = try AdmissionRingHarness(backend: backend)
        try harness.configureQueue()
        try harness.publish()
        harness.negotiate(VirtqueueFeature.version1 | (1 << 27))
        harness.kick()
        #expect(harness.transport.read(offset: 0x070, width: 4) == 3)
        #expect(backend.kicks == 0 && backend.readyCalls == 0)
        harness.negotiate(VirtqueueFeature.version1)
        harness.kick()
        #expect(backend.failure == nil)
        #expect(try harness.usedIndex() == 1)
        let oldLease = harness.transport.queues[0].currentLease
        harness.transport.write(offset: 0x070, value: 0, width: 4)
        #expect(!harness.transport.queues[0].isLeaseValid(oldLease))
        #expect(harness.transport.queues[0].negotiatedFeatures == 0)
        harness.negotiate(VirtqueueFeature.version1 | VirtqueueFeature.eventIndex)
        #expect(harness.transport.negotiatedFeatures == (VirtqueueFeature.version1 | VirtqueueFeature.eventIndex))
    }

    @Test func resetRejectsAnOldQueuedEntropyWorkerBeforeSuccessorDMA() throws {
        let work = AdmissionManualWork()
        let fills = AdmissionCounter()
        let backend = VirtioRng(
            limits: .init(maximumBytesPerRequest: 4, maximumRequestsPerWorkerTurn: 1),
            fillEntropy: { buffer in
                fills.increment()
                buffer.initializeMemory(as: UInt8.self, repeating: 0x3C)
                return true
            }, submitWork: { work.submit($0) }
        )
        let harness = try AdmissionRingHarness(backend: backend)
        harness.negotiate(VirtqueueFeature.version1)
        try harness.configureQueue()
        try harness.publish()
        harness.kick()
        #expect(work.count == 1)
        let oldLease = harness.transport.queues[0].currentLease
        harness.transport.write(offset: 0x070, value: 0, width: 4)
        #expect(harness.transport.negotiatedFeatures == 0)
        #expect(!harness.transport.queues[0].isLeaseValid(oldLease))
        harness.negotiate(VirtqueueFeature.version1 | VirtqueueFeature.eventIndex)
        try harness.configureQueue()
        let successorData = harness.data + 0x1_000
        try harness.publish(data: successorData)
        try #require(work.runNext())
        #expect(fills.count == 0)
        #expect(try harness.usedIndex() == 0)
        #expect(try harness.bytes(at: successorData) == [0xA5, 0xA5, 0xA5, 0xA5])
        harness.kick()
        try #require(work.runNext())
        #expect(fills.count == 1)
        #expect(try harness.usedIndex() == 1)
        #expect(try harness.bytes(at: successorData) == [0x3C, 0x3C, 0x3C, 0x3C])
        #expect(try harness.bytes() == [0xA5, 0xA5, 0xA5, 0xA5])
    }
}

private final class AdmissionRingBackend: VirtioDeviceBackend, @unchecked Sendable {
    static let response: [UInt8] = [0x11, 0x22, 0x33, 0x44]
    let deviceID: UInt32 = 4
    let deviceFeatures: UInt64 = 0
    let queueCount = 1
    let configSpace: [UInt8] = []
    let kickSynchronization: VirtioKickSynchronization
    private(set) var kicks = 0
    private(set) var readyCalls = 0
    private(set) var failure: String?

    init(mode: VirtioKickSynchronization) { kickSynchronization = mode }

    func deviceReady(transport: VirtioMMIOTransport) { readyCalls += 1 }

    func handleKick(queue: Int, transport: VirtioMMIOTransport) {
        kicks += 1
        transport.withQueueLock {
            do {
                let ring = transport.queues[queue]
                guard let chain = try ring.pop() else { return }
                guard let written = chain.withLeaseHeld({ $0.writeBytes(Self.response) }) else { return }
                if try ring.push(chain, written: written) { transport.notifyUsed() }
            } catch { failure = String(describing: error) }
        }
    }
}

private struct AdmissionRingHarness {
    let memory: GuestMemory
    let transport: VirtioMMIOTransport
    let descriptor = GuestLayout.ramBase + 0x1_000
    let available = GuestLayout.ramBase + 0x4_000
    let used = GuestLayout.ramBase + 0x6_000
    let data = GuestLayout.ramBase + 0x8_000
    let indirectTable = GuestLayout.ramBase + 0xA_000

    init(backend: VirtioDeviceBackend) throws {
        memory = try GuestMemory(guestBase: GuestLayout.ramBase, size: 0x20_000)
        transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase, backend: backend, memory: memory) {}
    }

    func writeFeatures(_ features: UInt64) {
        transport.write(offset: 0x024, value: 0, width: 4)
        transport.write(offset: 0x020, value: features & 0xFFFF_FFFF, width: 4)
        transport.write(offset: 0x024, value: 1, width: 4)
        transport.write(offset: 0x020, value: features >> 32, width: 4)
    }

    func negotiate(_ features: UInt64) {
        transport.write(offset: 0x070, value: 1, width: 4)
        transport.write(offset: 0x070, value: 3, width: 4)
        writeFeatures(features)
        transport.write(offset: 0x070, value: 0x0B, width: 4)
        transport.write(offset: 0x070, value: 0x0F, width: 4)
    }

    func configureQueue() throws {
        transport.write(offset: 0x030, value: 0, width: 4)
        transport.write(offset: 0x038, value: 8, width: 4)
        for (offset, address) in [(UInt64(0x080), descriptor), (0x090, available), (0x0A0, used)] {
            transport.write(offset: offset, value: address & 0xFFFF_FFFF, width: 4)
            transport.write(offset: offset + 4, value: address >> 32, width: 4)
        }
        transport.write(offset: 0x044, value: 1, width: 4)
        try #require(transport.read(offset: 0x044, width: 4) == 1)
        try memory.write(UInt16(0), at: available)
        try memory.write(UInt16(0), at: available + 2)
        try memory.write(UInt16(0), at: used + 2)
    }

    func publish(data target: UInt64? = nil, indirect: Bool = false) throws {
        let destination = target ?? data
        try memory.write([UInt8](repeating: 0xA5, count: 4), at: destination)
        let table = indirect ? indirectTable : descriptor
        try memory.write(destination, at: table)
        try memory.write(UInt32(4), at: table + 8)
        try memory.write(UInt16(2), at: table + 12)
        try memory.write(UInt16(0), at: table + 14)
        if indirect {
            try memory.write(indirectTable, at: descriptor)
            try memory.write(UInt32(16), at: descriptor + 8)
            try memory.write(UInt16(4), at: descriptor + 12)
            try memory.write(UInt16(0), at: descriptor + 14)
        }
        try memory.write(UInt16(0), at: available + 4)
        try memory.write(UInt16(1), at: available + 2)
    }

    func kick() { transport.write(offset: 0x050, value: 0, width: 4) }
    func usedIndex() throws -> UInt16 { try memory.read(UInt16.self, at: used + 2) }
    func bytes(at address: UInt64? = nil) throws -> [UInt8] {
        try memory.readBytes(at: address ?? data, count: 4)
    }
}

private final class AdmissionManualWork: @unchecked Sendable {
    private let lock = NSLock()
    private var operations = [@Sendable () -> Void]()
    var count: Int { lock.withLock { operations.count } }
    func submit(_ operation: @escaping @Sendable () -> Void) { lock.withLock { operations.append(operation) } }
    func runNext() -> Bool {
        let operation = lock.withLock { operations.isEmpty ? nil : operations.removeFirst() }
        guard let operation else { return false }
        operation()
        return true
    }
}

private final class AdmissionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

/// Fixtures that ring MMIO doorbells must cross the same actual negotiation boundary as a guest.
/// Backend-unit fixtures calling handleKick directly remain independent of transport admission.
func finishMMIOTestDriverNegotiation(
    _ transport: VirtioMMIOTransport, features: UInt64 = VirtqueueFeature.version1
) {
    transport.write(offset: 0x070, value: 1, width: 4)
    transport.write(offset: 0x070, value: 3, width: 4)
    transport.write(offset: 0x024, value: 0, width: 4)
    transport.write(offset: 0x020, value: features & 0xFFFF_FFFF, width: 4)
    transport.write(offset: 0x024, value: 1, width: 4)
    transport.write(offset: 0x020, value: features >> 32, width: 4)
    transport.write(offset: 0x070, value: 0x0B, width: 4)
    transport.write(offset: 0x070, value: 0x0F, width: 4)
}
