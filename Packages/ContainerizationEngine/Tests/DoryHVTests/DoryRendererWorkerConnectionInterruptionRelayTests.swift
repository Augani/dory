import Foundation
import Testing
@testable import DoryHV

@Suite struct DoryRendererWorkerConnectionInterruptionRelayTests {
    @Test func actualInterruptionIsOneShotAndDeliveredToLateObservers() {
        let relay = DoryRendererWorkerConnectionInterruptionRelay()
        let calls = InterruptionCalls()
        relay.install { calls.record() }
        #expect(calls.count == 0)
        relay.connectionInterrupted()
        relay.connectionInterrupted()
        #expect(calls.count == 1)
        relay.invalidateLocally()
        relay.install { calls.record() }
        #expect(calls.count == 2)
    }

    @Test func localInvalidationSuppressesQueuedAndLateInterruptionProof() {
        let relay = DoryRendererWorkerConnectionInterruptionRelay()
        let calls = InterruptionCalls()
        relay.install { calls.record() }
        relay.invalidateLocally()
        relay.connectionInterrupted()
        relay.install { calls.record() }
        #expect(calls.count == 0)
    }
}

private final class InterruptionCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var count: Int { lock.withLock { stored } }
    func record() { lock.withLock { stored += 1 } }
}
