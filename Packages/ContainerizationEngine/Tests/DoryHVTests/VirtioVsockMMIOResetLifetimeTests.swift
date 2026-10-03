import Foundation
import Testing
@testable import DoryHV

@Suite struct VirtioVsockMMIOResetLifetimeTests {
    @Test(arguments: [false, true])
    func serviceRetirementJoinsTransportWorkOnlyAfterOutermostUnlock(nested: Bool) throws {
        let device = VirtioVsock(guestCID: 3)
        let harness = try ResetHarness(device: device)
        let callbackEntered = ResetObservation(false)
        let joined = ResetObservation(false)
        let observedClearedQueue = ResetObservation(false)
        let workerFinished = DispatchSemaphore(value: 0)
        let reservation = try device.reserveServiceSession(.agentRPC)
        let publishedLease = device.publishServiceSession(reservation, requestStop: {
            callbackEntered.set(true)
            Thread.detachNewThread {
                harness.transport.withQueueLock {
                    observedClearedQueue.set(!harness.transport.queues[1].ready)
                }
                workerFinished.signal()
            }
            joined.set(workerFinished.wait(timeout: .now() + 2) == .success)
        })
        let lease = try #require(publishedLease)
        defer { device.quiesce() }

        withExtendedLifetime(lease) {
            if nested {
                harness.transport.withQueueLock {
                    harness.transport.write(offset: 0x070, value: 0, width: 4)
                    #expect(!callbackEntered.value)
                    #expect(device.serviceAdmissionSnapshot.isResetting)
                }
            } else {
                harness.transport.write(offset: 0x070, value: 0, width: 4)
            }
        }
        #expect(callbackEntered.value)
        #expect(joined.value)
        #expect(observedClearedQueue.value)
        #expect(!device.serviceAdmissionSnapshot.isResetting)
    }

    @Test(arguments: ["mmio", "direct", "neutral", "quiesce"])
    func listenerReentrantResetRetiresOutsideItsOuterQueueCallback(path: String) throws {
        let device = VirtioVsock(guestCID: 3)
        let harness = try ResetHarness(device: device)
        let callbackEntered = ResetObservation(false)
        let joined = ResetObservation(false)
        let workerFinished = DispatchSemaphore(value: 0)
        let reservation = try device.reserveServiceSession(.agentRPC)
        let publishedLease = device.publishServiceSession(reservation, requestStop: {
            callbackEntered.set(true)
            Thread.detachNewThread {
                harness.transport.withQueueLock {}
                workerFinished.signal()
            }
            joined.set(workerFinished.wait(timeout: .now() + 2) == .success)
        })
        let lease = try #require(publishedLease)
        let listenerEntered = ResetObservation(false)
        let registration = try device.registerListener(port: 11_434) { _ in
            listenerEntered.set(true)
            switch path {
            case "mmio": harness.transport.write(offset: 0x070, value: 0, width: 4)
            case "direct": device.deviceReset(transport: harness.transport)
            case "neutral": device.resetTransportNeutralDevice()
            default: device.quiesce()
            }
            // The listener still holds handleKick's recursive transport entry. A stop callback
            // joining the independent transport worker here would deadlock that writer.
            #expect(!callbackEntered.value)
        }
        defer {
            registration.close()
            device.quiesce()
        }
        try harness.publishGuestRequest(port: 11_434)
        withExtendedLifetime(lease) {
            harness.transport.write(offset: 0x050, value: 1, width: 4)
        }
        #expect(listenerEntered.value)
        #expect(callbackEntered.value)
        #expect(joined.value)
        #expect(device.resourceSnapshot.connections == 0)
        #expect(device.serviceAdmissionSnapshot.isQuiesced == (path == "quiesce"))
        #expect(!device.serviceAdmissionSnapshot.isResetting)
    }

    @Test func supersededRetirementCannotRevokeReplacementServiceAdmission() throws {
        let device = VirtioVsock(guestCID: 3)
        let harness = try ResetHarness(device: device)
        let replacementLease = ResetObservation<VirtioVsockServiceLease?>(nil)
        let joined = ResetObservation(false)
        let failure = ResetObservation<String?>(nil)
        let replacementFinished = DispatchSemaphore(value: 0)
        let reservation = try device.reserveServiceSession(.agentRPC)
        let publishedLease = device.publishServiceSession(reservation, requestStop: {
            Thread.detachNewThread {
                defer { replacementFinished.signal() }
                device.resetTransportNeutralDevice()
                do {
                    let next = try device.reserveServiceSession(.docker)
                    replacementLease.set(device.publishServiceSession(next, requestStop: {}))
                } catch {
                    failure.set(String(describing: error))
                }
            }
            joined.set(replacementFinished.wait(timeout: .now() + 2) == .success)
        })
        let originalLease = try #require(publishedLease)
        defer { device.quiesce() }
        withExtendedLifetime(originalLease) {
            harness.transport.write(offset: 0x070, value: 0, width: 4)
        }
        #expect(joined.value)
        #expect(failure.value == nil)
        #expect(replacementLease.value != nil)
        #expect(device.serviceAdmissionSnapshot.activeSessionsByService[.docker] == 1)
        #expect(!device.serviceAdmissionSnapshot.isResetting)
    }

    @Test func stopActionTerminalQuiesceCannotBeUndoneByOldResetCompletion() throws {
        let device = VirtioVsock(guestCID: 3)
        let harness = try ResetHarness(device: device)
        let reservation = try device.reserveServiceSession(.agentRPC)
        let publishedLease = device.publishServiceSession(reservation, requestStop: {
            device.quiesce()
        })
        let lease = try #require(publishedLease)
        withExtendedLifetime(lease) {
            harness.transport.write(offset: 0x070, value: 0, width: 4)
        }
        #expect(device.resourceSnapshot.isQuiesced)
        #expect(device.serviceAdmissionSnapshot.isQuiesced)
        #expect(throws: VirtioVsockServiceAdmissionError.deviceQuiesced) {
            _ = try device.reserveServiceSession(.docker)
        }
    }
}

private final class ResetObservation<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value { lock.withLock { storage } }
    func set(_ value: Value) { lock.withLock { storage = value } }
}

private final class ResetHarness: @unchecked Sendable {
    private let base = GuestLayout.ramBase
    let memory: GuestMemory
    let transport: VirtioMMIOTransport

    init(device: VirtioVsock) throws {
        memory = try GuestMemory(guestBase: GuestLayout.ramBase, size: 0x20_000)
        transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase, backend: device, memory: memory) {}
        finishMMIOTestDriverNegotiation(transport)
        transport.queues[1].configure(
            size: 8, descriptorTable: base + 0x1_000,
            availRing: base + 0x2_000, usedRing: base + 0x3_000)
        transport.queues[1].setReady(true)
    }

    func publishGuestRequest(port: UInt32) throws {
        let packet = VirtioVsockHeader(
            sourceCID: 3, destinationCID: 2, sourcePort: 40_000,
            destinationPort: port, length: 0, operation: .request).encoded()
        try memory.write(packet, at: base + 0x4_000)
        try memory.write(base + 0x4_000, at: base + 0x1_000)
        try memory.write(UInt32(packet.count), at: base + 0x1_008)
        try memory.write(UInt16(0), at: base + 0x1_00C)
        try memory.write(UInt16(0), at: base + 0x1_00E)
        try memory.write(UInt16(0), at: base + 0x2_000)
        try memory.write(UInt16(1), at: base + 0x2_002)
        try memory.write(UInt16(0), at: base + 0x2_004)
    }
}
