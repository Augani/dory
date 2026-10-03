import DoryHostDeviceBroker
import DoryHV
import DoryMachinePC
import DoryVMContracts
import Foundation
import Testing
@testable import dory_hv

struct DoryPCUSBControlLifetimeTests {
    @Test func stoppedHandlerCannotDiscoverCaptureOrReplaceItsController() async throws {
        let calls = Counter()
        let fixture = try Fixture()
        let handler = fixture.handler(lookup: { busID in
            calls.increment()
            return fixture.candidate(busID: busID)
        })
        handler.stop()
        await #expect(throws: UsbControlError.managerStoppedDuringTransition("3-2")) {
            try await handler.attach(busID: "3-2", expectedIdentity: fixture.token, mode: .userAuthorized)
        }
        #expect(throws: UsbControlError.managerStoppedDuringTransition("controller-reset")) {
            try handler.replaceController(DoryPCXHCIController())
        }
        #expect(calls.count == 0)
        #expect(fixture.capability.closeCount == 0)
    }

    @Test func stopDuringDiscoveryRejectsBeforeOpeningAHostLease() async throws {
        let fixture = try Fixture()
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let opens = Counter()
        let handler = fixture.handler(lookup: { busID in
            entered.signal()
            _ = resume.wait(timeout: .now() + 2)
            return fixture.candidate(busID: busID)
        }, opener: { _, identity in
            opens.increment()
            return try fixture.acquire(identity)
        })
        let attaching = Task.detached {
            try await handler.attach(busID: "3-2", expectedIdentity: fixture.token, mode: .userAuthorized)
        }
        #expect(await waitForSignal(entered))
        let started = ContinuousClock.now
        handler.stop()
        #expect(started.duration(to: .now) < .milliseconds(500))
        resume.signal()
        await #expect(throws: UsbControlError.managerStoppedDuringTransition("3-2")) {
            try await attaching.value
        }
        #expect(opens.count == 0)
        #expect(fixture.broker.activeLeaseCount(machineID: "machine-a") == 0)
    }

    @Test func stopDuringCaptureRetiresTheLateLeaseWithoutPublishingAPort() async throws {
        let fixture = try Fixture()
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let handler = fixture.handler(opener: { _, identity in
            let lease = try fixture.acquire(identity)
            entered.signal()
            _ = resume.wait(timeout: .now() + 2)
            return lease
        })
        let attaching = Task.detached {
            try await handler.attach(busID: "3-2", expectedIdentity: fixture.token, mode: .userAuthorized)
        }
        #expect(await waitForSignal(entered))
        handler.stop()
        resume.signal()
        await #expect(throws: UsbControlError.managerStoppedDuringTransition("3-2")) {
            try await attaching.value
        }
        #expect(try !fixture.controller.portState(2).connected)
        #expect(fixture.capability.closeCount == 1)
        #expect(fixture.broker.activeLeaseCount(machineID: "machine-a") == 0)
    }

    @Test func pendingCaptureReservesItsPortAndRejectsADuplicateBus() async throws {
        let fixture = try Fixture()
        let second = try Fixture(character: "b")
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let handler = fixture.handler(lookup: { busID in
            busID == "3-2" ? fixture.candidate(busID: busID) : second.candidate(busID: busID)
        }, opener: { candidate, identity in
            if candidate.descriptor.busID == "3-2" {
                let lease = try fixture.acquire(identity)
                entered.signal()
                _ = resume.wait(timeout: .now() + 2)
                return lease
            }
            return try second.acquire(identity)
        })
        let first = Task.detached {
            try await handler.attach(busID: "3-2", expectedIdentity: fixture.token, mode: .userAuthorized)
        }
        #expect(await waitForSignal(entered))
        await #expect(throws: UsbControlError.transitionInProgress(busID: "3-2", operation: "attaching")) {
            try await handler.attach(busID: "3-2", expectedIdentity: fixture.token, mode: .userAuthorized)
        }
        let other = try await handler.attach(busID: "3-3", expectedIdentity: second.token, mode: .userAuthorized)
        #expect(other.port == 3)
        resume.signal()
        #expect(try await first.value.port == 2)
        #expect(try fixture.controller.portState(2).connected)
        #expect(try fixture.controller.portState(3).connected)
        handler.stop()
        #expect(fixture.capability.closeCount == 1)
        #expect(second.capability.closeCount == 1)
    }

    @Test func aRetiringPortCannotBeReusedBeforeItsDisconnectReturns() async throws {
        let fixture = try Fixture()
        fixture.capability.blockFirstCancel = true
        let second = try Fixture(character: "c")
        let handler = fixture.handler(lookup: { busID in
            busID == "3-2" ? fixture.candidate(busID: busID) : second.candidate(busID: busID)
        }, opener: { candidate, identity in
            try candidate.descriptor.busID == "3-2" ? fixture.acquire(identity) : second.acquire(identity)
        })
        _ = try await handler.attach(busID: "3-2", expectedIdentity: fixture.token, mode: .userAuthorized)
        let detaching = Task.detached { try await handler.detach(busID: "3-2") }
        #expect(await waitForSignal(fixture.capability.cancelEntered))
        let other = try await handler.attach(busID: "3-3", expectedIdentity: second.token, mode: .userAuthorized)
        #expect(other.port == 3)
        fixture.capability.resumeCancel.signal()
        try await detaching.value
        #expect(try !fixture.controller.portState(2).connected)
        #expect(try fixture.controller.portState(3).connected)
        #expect(second.capability.closeCount == 0)
        handler.stop()
    }

    private func waitForSignal(_ semaphore: DispatchSemaphore) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + 1) == .success)
            }
        }
    }

    private final class Fixture: @unchecked Sendable {
        let token: DoryUSBPhysicalIdentityToken
        let capability: Capability
        let broker = DoryHostUSBLeaseBroker()
        let controller: DoryPCXHCIController

        init(character: String = "a") throws {
            token = .init(rawValue: String(repeating: character, count: 64))!
            capability = Capability(identityToken: token)
            controller = try .init()
        }
        func candidate(busID: String) -> HostUsbDeviceCandidate {
            .init(descriptor: .init(
                path: "mock-only", busID: busID, busNumber: 3, deviceNumber: 2, speed: 3,
                vendorID: 0x1234, productID: 0x5678, bcdDevice: 0x0100,
                deviceClass: 0x02, deviceSubClass: 0, deviceProtocol: 0,
                configurationValue: 1, configurationCount: 1, interfaceCount: 1
            ), interfaces: [.init(number: 0, interfaceClass: 0x02,
                                  interfaceSubClass: 0x02, interfaceProtocol: 0x01)],
               identityToken: token, captureDecision: .allowed)
        }
        func acquire(_ identity: DoryUSBPhysicalIdentityToken) throws -> DoryHostUSBLeaseDevice {
            try broker.acquire(machineID: "machine-a", identityToken: identity, family: .serialAdapter,
                               admission: .init(userSelected: true), capability: capability)
        }
        func handler(lookup: DoryPCUSBControlHandler.CandidateLookup? = nil,
                     opener: DoryPCUSBControlHandler.LeaseOpener? = nil) -> DoryPCUSBControlHandler {
            .init(controller: controller, machineID: "machine-a", broker: broker,
                  lookupCandidate: lookup ?? { [self] in candidate(busID: $0) },
                  openLease: opener ?? { [self] _, identity in try acquire(identity) })
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func increment() { lock.withLock { value += 1 } }
    }

    private final class Capability: DoryHostUSBTransferCapability, @unchecked Sendable {
        let identityToken: DoryUSBPhysicalIdentityToken
        let speed: DoryPCXHCIPortSpeed = .high
        let cancelEntered = DispatchSemaphore(value: 0)
        let resumeCancel = DispatchSemaphore(value: 0)
        var blockFirstCancel = false
        private let lock = NSLock()
        private var closes = 0
        private var cancels = 0
        var closeCount: Int { lock.withLock { closes } }
        init(identityToken: DoryUSBPhysicalIdentityToken) { self.identityToken = identityToken }
        func perform(_ transfer: DoryPCUSBTransfer, deadline: ContinuousClock.Instant) -> DoryPCUSBTransferResult {
            try! .init(status: .success)
        }
        func reset(deadline: ContinuousClock.Instant) -> Bool { true }
        func cancelAll() {
            let first = lock.withLock { cancels += 1; return cancels == 1 }
            if first && blockFirstCancel {
                cancelEntered.signal()
                _ = resumeCancel.wait(timeout: .now() + 2)
            }
        }
        func close() { lock.withLock { closes += 1 } }
    }
}
