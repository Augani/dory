import Foundation
import Synchronization
import Testing
@testable import DoryHV

@Suite struct VirtioMMIOInterruptTests {
    private final class SignalCounter: Sendable {
        private let value = Atomic<Int>(0)

        func increment() {
            value.wrappingAdd(1, ordering: .relaxed)
        }

        var count: Int {
            value.load(ordering: .relaxed)
        }
    }

    private final class Backend: VirtioDeviceBackend {
        let deviceID: UInt32 = 1
        let deviceFeatures: UInt64 = 0
        let queueCount = 1
        let configSpace: [UInt8] = []

        func handleKick(queue: Int, transport: VirtioMMIOTransport) {}
    }

    private func makeTransport(
        signals: SignalCounter
    ) throws -> VirtioMMIOTransport {
        let memory = try GuestMemory(guestBase: GuestLayout.ramBase, size: 0x20_000)
        return VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: Backend(),
            memory: memory
        ) {
            signals.increment()
        }
    }

    @Test func repeatedUsedNotificationsCoalesceUntilAcknowledged() throws {
        let signals = SignalCounter()
        let transport = try makeTransport(signals: signals)

        transport.notifyUsed()
        transport.notifyUsed()
        transport.notifyUsed()

        #expect(transport.read(offset: 0x060, width: 4) == 1)
        #expect(signals.count == 1)
        #expect(transport.statistics.usedInterrupts == 3)
        #expect(transport.statistics.emittedInterruptSignals == 1)

        transport.write(offset: 0x064, value: 1, width: 4)
        #expect(transport.read(offset: 0x060, width: 4) == 0)
        transport.notifyUsed()

        #expect(transport.read(offset: 0x060, width: 4) == 1)
        #expect(signals.count == 2)
        #expect(transport.statistics.usedInterrupts == 4)
        #expect(transport.statistics.emittedInterruptSignals == 2)
    }

    @Test func distinctPendingBitsSignalIndependentlyAndAcknowledgeExactly() throws {
        let signals = SignalCounter()
        let transport = try makeTransport(signals: signals)

        transport.notifyUsed()
        transport.notifyConfigChange()
        transport.notifyConfigChange()

        #expect(transport.read(offset: 0x060, width: 4) == 3)
        #expect(transport.read(offset: 0x0FC, width: 4) == 2)
        #expect(signals.count == 2)
        #expect(transport.statistics.configurationInterrupts == 2)
        #expect(transport.statistics.emittedInterruptSignals == 2)

        transport.write(offset: 0x064, value: 1, width: 4)
        #expect(transport.read(offset: 0x060, width: 4) == 2)
        transport.notifyUsed()

        #expect(transport.read(offset: 0x060, width: 4) == 3)
        #expect(signals.count == 3)
        #expect(transport.statistics.emittedInterruptSignals == 3)
    }

    @Test func concurrentSameBitNotificationsEmitOnceAndResetClearsPendingState() throws {
        let signals = SignalCounter()
        let transport = try makeTransport(signals: signals)
        let completion = DispatchGroup()
        let notificationCount = 32

        for _ in 0..<notificationCount {
            completion.enter()
            Thread.detachNewThread {
                transport.notifyUsed()
                completion.leave()
            }
        }

        #expect(completion.wait(timeout: .now() + 2) == .success)
        #expect(transport.read(offset: 0x060, width: 4) == 1)
        #expect(signals.count == 1)
        #expect(transport.statistics.usedInterrupts == notificationCount)
        #expect(transport.statistics.emittedInterruptSignals == 1)

        transport.write(offset: 0x070, value: 0, width: 4)
        #expect(transport.read(offset: 0x060, width: 4) == 0)
        transport.notifyUsed()

        #expect(transport.read(offset: 0x060, width: 4) == 1)
        #expect(signals.count == 2)
        #expect(transport.statistics.deviceResets == 1)
        #expect(transport.statistics.emittedInterruptSignals == 2)
    }
}
