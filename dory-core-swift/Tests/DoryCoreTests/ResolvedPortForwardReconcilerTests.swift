import Foundation
import XCTest
@testable import DoryCore

final class ResolvedPortForwardReconcilerTests: XCTestCase {
    func testRegistrySeparatesExactMissingAndConflictingForwards() throws {
        let exact = forward(hostPort: 8_080, guestPort: 80)
        let wanted = forward(hostPort: 8_443, guestPort: 443)
        let registry = try XCTUnwrap(ResolvedPortForwardRegistry.decode(Data(#"""
        [
          {"local":"127.0.0.1:8080","remote":"192.168.127.2:80","protocol":"tcp"},
          {"local":"127.0.0.1:8443","remote":"192.168.127.2:444","protocol":"tcp"},
          {"local":"/tmp/shutdown.sock","remote":"tcp://192.168.127.2:2377","protocol":"unix"}
        ]
        """#.utf8)))

        XCTAssertTrue(registry.contains(exact))
        XCTAssertTrue(registry.conflicts(with: wanted))
        let plan = ResolvedPortForwardReconciliation(
            desired: [exact, wanted],
            registry: registry
        )
        XCTAssertEqual(plan.missing, [wanted])
        XCTAssertEqual(plan.toUnexpose, [wanted])
        XCTAssertEqual(plan.toExpose, [wanted])
    }

    func testMalformedTCPRowFailsTheWholeObservation() {
        XCTAssertNil(ResolvedPortForwardRegistry.decode(Data(#"""
        [
          {"local":"not-an-endpoint","remote":"192.168.127.2:80","protocol":"tcp"}
        ]
        """#.utf8)))
        XCTAssertNil(ResolvedPortForwardRegistry.decode(Data("not-json".utf8)))
    }

    func testReconcilerRepairsAndThenProvesTheExactRegistry() {
        let desired = forward(hostPort: 8_080, guestPort: 80)
        let state = RegistryState(entries: [
            forward(hostPort: 8_080, guestPort: 81),
        ])
        let reconciler = ResolvedPortForwardReconciler(
            desired: [desired],
            registryProvider: { state.registry() },
            exposeProvider: { state.expose($0) },
            unexposeProvider: { state.unexpose($0) }
        )

        XCTAssertTrue(reconciler.reconcileNow())
        XCTAssertEqual(state.entries, [desired])
        XCTAssertEqual(state.unexposed, [forward(hostPort: 8_080, guestPort: 81)])
        XCTAssertEqual(state.exposed, [desired])
        XCTAssertEqual(reconciler.healthSnapshot(), ResolvedPortForwardHealthSnapshot(
            configuredForwards: 1,
            activeForwards: 1,
            failedReconciliations: 0,
            healthy: true
        ))
    }

    func testUnavailableRegistryNeverMutatesHostListeners() {
        let state = RegistryState(entries: [])
        let reconciler = ResolvedPortForwardReconciler(
            desired: [forward(hostPort: 8_080, guestPort: 80)],
            registryProvider: { nil },
            exposeProvider: { state.expose($0) },
            unexposeProvider: { state.unexpose($0) }
        )

        XCTAssertFalse(reconciler.reconcileNow())
        XCTAssertTrue(state.exposed.isEmpty)
        XCTAssertTrue(state.unexposed.isEmpty)
        XCTAssertEqual(reconciler.healthSnapshot(), ResolvedPortForwardHealthSnapshot(
            configuredForwards: 1,
            activeForwards: 0,
            failedReconciliations: 1,
            healthy: false
        ))
    }

    func testHealthSnapshotTracksFailureThenRecoveryWithoutFalseActiveListeners() {
        let desired = forward(hostPort: 8_080, guestPort: 80)
        let state = RegistryState(entries: [])
        let availability = LockedAvailability(false)
        let reconciler = ResolvedPortForwardReconciler(
            desired: [desired],
            registryProvider: { availability.value ? state.registry() : nil },
            exposeProvider: { state.expose($0) },
            unexposeProvider: { state.unexpose($0) }
        )

        XCTAssertFalse(reconciler.reconcileNow())
        XCTAssertFalse(reconciler.healthSnapshot().healthy)
        availability.value = true
        XCTAssertTrue(reconciler.reconcileNow())
        XCTAssertEqual(reconciler.healthSnapshot(), ResolvedPortForwardHealthSnapshot(
            configuredForwards: 1,
            activeForwards: 1,
            failedReconciliations: 1,
            healthy: true
        ))
    }

    func testStopPermanentlyRejectsManualAndTimerReactivation() {
        let desired = forward(hostPort: 8_080, guestPort: 80)
        let state = RegistryState(entries: [])
        let calls = ReconcilerCallCounter()
        let reconciler = ResolvedPortForwardReconciler(
            desired: [desired],
            registryProvider: { calls.increment(); return state.registry() },
            exposeProvider: { state.expose($0) },
            unexposeProvider: { state.unexpose($0) }
        )
        reconciler.stop()
        reconciler.start()
        XCTAssertFalse(reconciler.reconcileNow())
        reconciler.stop()
        XCTAssertEqual(calls.value, 0)
        XCTAssertTrue(state.exposed.isEmpty)
        XCTAssertTrue(state.unexposed.isEmpty)
        XCTAssertEqual(reconciler.healthSnapshot().activeForwards, 0)
        XCTAssertFalse(reconciler.healthSnapshot().healthy)
        XCTAssertEqual(reconciler.healthSnapshot().failedReconciliations, 0)
    }

    func testEveryStopCallerJoinsHeldRegistryAndCancelsFollowingMutation() {
        let desired = forward(hostPort: 8_080, guestPort: 80)
        let state = RegistryState(entries: [])
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let reconciler = ResolvedPortForwardReconciler(
            desired: [desired],
            registryProvider: {
                entered.signal()
                release.wait()
                return state.registry()
            },
            exposeProvider: { state.expose($0) },
            unexposeProvider: { state.unexpose($0) }
        )
        let reconciled = DispatchSemaphore(value: 0)
        let result = LockedAvailability(true)
        DispatchQueue.global().async {
            result.value = reconciler.reconcileNow()
            reconciled.signal()
        }
        defer { release.signal() }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        let stopped = DispatchSemaphore(value: 0)
        for _ in 0..<2 {
            DispatchQueue.global().async { reconciler.stop(); stopped.signal() }
        }
        let deadline = Date().addingTimeInterval(1)
        while !reconciler.isStopped, Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
        XCTAssertTrue(reconciler.isStopped)
        XCTAssertEqual(stopped.wait(timeout: .now() + 0.02), .timedOut)
        release.signal()
        XCTAssertEqual(reconciled.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(stopped.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(stopped.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(result.value)
        XCTAssertTrue(state.exposed.isEmpty)
        XCTAssertTrue(state.unexposed.isEmpty)
        XCTAssertFalse(reconciler.reconcileNow())
        XCTAssertEqual(reconciler.healthSnapshot().activeForwards, 0)
    }

    func testRegistryUsesCanonicalIPv6IdentityAndRejectsAmbiguousLocalOwner() throws {
        let desired = PublishedPortForward(
            protocol: .tcp, publishedPort: 8_080, localHost: "[::1]", localPort: 8_080,
            guestHost: "192.168.127.2", guestPort: 80)
        let registry = try XCTUnwrap(ResolvedPortForwardRegistry.decode(Data(#"""
        [{"local":"[0:0:0:0:0:0:0:1]:8080","remote":"192.168.127.2:80","protocol":"tcp"}]
        """#.utf8)))
        XCTAssertTrue(registry.contains(desired))
        XCTAssertFalse(registry.conflicts(with: desired))
        XCTAssertNil(ResolvedPortForwardRegistry.decode(Data(#"""
        [
          {"local":"[0:0:0:0:0:0:0:1]:8080","remote":"192.168.127.2:80","protocol":"tcp"},
          {"local":"[::1]:8080","remote":"192.168.127.2:81","protocol":"tcp"}
        ]
        """#.utf8)))
    }

    func testRegistryRejectsTruncatedScopedAndUnknownTransportObservations() throws {
        for local in [
            "127.0.0.1\0untrusted:8080", "tcp\0untrusted://127.0.0.1:8080",
            "[::1%lo0]:8080", "[[::1]]:8080", "tcp://127.0.0.1:8080",
            "udp://[::1]:8080", "::1:8080", "0:0:0:0:0:0:0:1:8080",
            "127.0.0.1:08080", "127.0.0.1:+8080", "[::1]:08080",
        ] {
            let data = try JSONSerialization.data(withJSONObject: [[
                "local": local, "remote": "192.168.127.2:80", "protocol": "tcp",
            ]])
            XCTAssertNil(ResolvedPortForwardRegistry.decode(data), String(reflecting: local))
        }
        XCTAssertNil(ResolvedPortForwardRegistry.decode(Data(#"""
        [{"local":"127.0.0.1:8080","remote":"192.168.127.2:80","protocol":"sctp"}]
        """#.utf8)))
    }

    func testRollbackRestoresOriginalExpandedIPv6MutationKey() {
        let first = PublishedPortForward(
            protocol: .tcp, publishedPort: 8_080, localHost: "[::1]", localPort: 8_080,
            guestHost: "192.168.127.2", guestPort: 80)
        let previous = PublishedPortForward(
            protocol: .tcp, publishedPort: 8_080, localHost: "[0:0:0:0:0:0:0:1]", localPort: 8_080,
            guestHost: "192.168.127.2", guestPort: 82)
        let second = PublishedPortForward(
            protocol: .tcp, publishedPort: 8_081, localHost: "[::1]", localPort: 8_081,
            guestHost: "192.168.127.2", guestPort: 81)
        let state = RegistryState(entries: [previous])
        let reconciler = ResolvedPortForwardReconciler(
            desired: [first, second], registryProvider: { state.registry() },
            exposeProvider: { $0 == second ? false : state.expose($0) },
            unexposeProvider: { state.unexpose($0) })

        XCTAssertFalse(reconciler.reconcileNow())
        XCTAssertEqual(state.entries, [previous])
        XCTAssertEqual(state.unexposed, [previous, first])
        XCTAssertEqual(state.exposed, [first, previous])
        XCTAssertEqual(state.unexposed.first?.localEndpoint, "[0:0:0:0:0:0:0:1]:8080")
        XCTAssertEqual(state.exposed.last?.localEndpoint, "[0:0:0:0:0:0:0:1]:8080")
    }

    func testPartialExposureFailureRollsBackOnlyNewExactListeners() {
        let first = forward(hostPort: 8_080, guestPort: 80)
        let second = forward(hostPort: 8_081, guestPort: 81)
        let unrelated = forward(hostPort: 9_000, guestPort: 90)
        let state = RegistryState(entries: [unrelated])
        let reconciler = ResolvedPortForwardReconciler(
            desired: [first, second], registryProvider: { state.registry() },
            exposeProvider: { $0 == second ? false : state.expose($0) },
            unexposeProvider: { state.unexpose($0) })

        XCTAssertFalse(reconciler.reconcileNow())
        XCTAssertEqual(state.entries, [unrelated])
        XCTAssertEqual(state.exposed, [first])
        XCTAssertEqual(state.unexposed, [first])
        XCTAssertEqual(reconciler.healthSnapshot().activeForwards, 0)
        XCTAssertEqual(reconciler.healthSnapshot().failedReconciliations, 1)
        XCTAssertTrue(reconciler.healthSnapshot().isValid)
    }

    func testLaterFailureRestoresPriorTargetAndNextTurnRecoversWholePlan() {
        let first = forward(hostPort: 8_080, guestPort: 80)
        let previous = forward(hostPort: 8_080, guestPort: 82)
        let second = forward(hostPort: 8_081, guestPort: 81)
        let unrelated = forward(hostPort: 9_000, guestPort: 90)
        let state = RegistryState(entries: [previous, unrelated])
        let failing = LockedAvailability(true)
        let reconciler = ResolvedPortForwardReconciler(
            desired: [first, second], registryProvider: { state.registry() },
            exposeProvider: { $0 == second && failing.value ? false : state.expose($0) },
            unexposeProvider: { state.unexpose($0) })

        XCTAssertFalse(reconciler.reconcileNow())
        XCTAssertEqual(state.entries, [previous, unrelated])
        XCTAssertEqual(state.unexposed, [previous, first])
        XCTAssertEqual(state.exposed, [first, previous])
        failing.value = false
        XCTAssertTrue(reconciler.reconcileNow())
        XCTAssertEqual(state.entries, [first, second, unrelated])
        XCTAssertEqual(reconciler.healthSnapshot().activeForwards, 2)
        XCTAssertEqual(reconciler.healthSnapshot().failedReconciliations, 1)
        XCTAssertTrue(reconciler.healthSnapshot().isValid)
    }

    func testLostExposureAcknowledgementIsObservedAndRolledBackWhenPlanIsIncomplete() {
        let first = forward(hostPort: 8_080, guestPort: 80)
        let second = forward(hostPort: 8_081, guestPort: 81)
        let state = RegistryState(entries: [])
        let reconciler = ResolvedPortForwardReconciler(
            desired: [first, second], registryProvider: { state.registry() },
            exposeProvider: { _ = state.expose($0); return false },
            unexposeProvider: { state.unexpose($0) })

        XCTAssertFalse(reconciler.reconcileNow())
        XCTAssertTrue(state.entries.isEmpty)
        XCTAssertEqual(state.exposed, [first])
        XCTAssertEqual(state.unexposed, [first])
        XCTAssertEqual(reconciler.healthSnapshot().activeForwards, 0)
    }

    func testLostFinalAcknowledgementCanCommitOnlyAfterWholeExactRegistryProof() {
        let first = forward(hostPort: 8_080, guestPort: 80)
        let second = forward(hostPort: 8_081, guestPort: 81)
        let state = RegistryState(entries: [])
        let reconciler = ResolvedPortForwardReconciler(
            desired: [first, second], registryProvider: { state.registry() },
            exposeProvider: { _ = state.expose($0); return $0 != second },
            unexposeProvider: { state.unexpose($0) })

        XCTAssertTrue(reconciler.reconcileNow())
        XCTAssertEqual(state.entries, [first, second])
        XCTAssertTrue(state.unexposed.isEmpty)
        XCTAssertEqual(reconciler.healthSnapshot().activeForwards, 2)
        XCTAssertEqual(reconciler.healthSnapshot().failedReconciliations, 0)
    }

    func testFailedRemovalAcknowledgementRestoresActuallyRemovedPriorTarget() {
        let desired = forward(hostPort: 8_080, guestPort: 80)
        let previous = forward(hostPort: 8_080, guestPort: 82)
        let state = RegistryState(entries: [previous])
        let reconciler = ResolvedPortForwardReconciler(
            desired: [desired], registryProvider: { state.registry() },
            exposeProvider: { state.expose($0) },
            unexposeProvider: { _ = state.unexpose($0); return false })

        XCTAssertFalse(reconciler.reconcileNow())
        XCTAssertEqual(state.entries, [previous])
        XCTAssertEqual(state.exposed, [previous])
        XCTAssertEqual(reconciler.healthSnapshot().activeForwards, 0)
    }

    func testRollbackNeverOverwritesAConcurrentlyChangedExactTarget() {
        let first = forward(hostPort: 8_080, guestPort: 80)
        let previous = forward(hostPort: 8_080, guestPort: 82)
        let concurrent = forward(hostPort: 8_080, guestPort: 85)
        let second = forward(hostPort: 8_081, guestPort: 81)
        let state = RegistryState(entries: [previous])
        let reconciler = ResolvedPortForwardReconciler(
            desired: [first, second], registryProvider: { state.registry() },
            exposeProvider: {
                if $0 == second {
                    _ = state.unexpose(first)
                    _ = state.expose(concurrent)
                    return false
                }
                return state.expose($0)
            },
            unexposeProvider: { state.unexpose($0) })

        XCTAssertFalse(reconciler.reconcileNow())
        XCTAssertEqual(state.entries, [concurrent])
        XCTAssertEqual(state.exposed, [first, concurrent])
        XCTAssertEqual(reconciler.healthSnapshot().activeForwards, 0)
    }

    func testFailedRollbackReportsActualPartialStateAndNextTurnCanRepairIt() {
        let first = forward(hostPort: 8_080, guestPort: 80)
        let second = forward(hostPort: 8_081, guestPort: 81)
        let state = RegistryState(entries: [])
        let failing = LockedAvailability(true)
        let reconciler = ResolvedPortForwardReconciler(
            desired: [first, second], registryProvider: { state.registry() },
            exposeProvider: { $0 == second && failing.value ? false : state.expose($0) },
            unexposeProvider: { failing.value ? false : state.unexpose($0) })

        XCTAssertFalse(reconciler.reconcileNow())
        XCTAssertEqual(state.entries, [first])
        XCTAssertEqual(reconciler.healthSnapshot().activeForwards, 1)
        XCTAssertFalse(reconciler.healthSnapshot().healthy)
        XCTAssertTrue(reconciler.healthSnapshot().isValid)
        failing.value = false
        XCTAssertTrue(reconciler.reconcileNow())
        XCTAssertEqual(state.entries, [first, second])
        XCTAssertEqual(reconciler.healthSnapshot().activeForwards, 2)
    }

    func testHelperRegistryRestartRecreatesDesiredForwardsWithoutRemovingUnrelatedRows() {
        let first = forward(hostPort: 8_080, guestPort: 80)
        let second = forward(hostPort: 8_081, guestPort: 81)
        let unrelated = forward(hostPort: 9_000, guestPort: 90)
        let state = RegistryState(entries: [first, second, unrelated])
        let reconciler = ResolvedPortForwardReconciler(
            desired: [first, second], registryProvider: { state.registry() },
            exposeProvider: { state.expose($0) },
            unexposeProvider: { state.unexpose($0) })

        XCTAssertTrue(reconciler.reconcileNow())
        XCTAssertTrue(state.exposed.isEmpty)
        state.replaceEntries([unrelated])
        XCTAssertTrue(reconciler.reconcileNow())
        XCTAssertEqual(state.entries, [first, second, unrelated])
        XCTAssertEqual(state.exposed, [first, second])
        XCTAssertTrue(state.unexposed.isEmpty)
    }

    func testAmbiguousDesiredLocalEndpointFailsBeforeRegistryOrMutationWork() {
        let state = RegistryState(entries: [])
        let calls = ReconcilerCallCounter()
        let reconciler = ResolvedPortForwardReconciler(
            desired: [forward(hostPort: 8_080, guestPort: 80), forward(hostPort: 8_080, guestPort: 81)],
            registryProvider: { calls.increment(); return state.registry() },
            exposeProvider: { state.expose($0) }, unexposeProvider: { state.unexpose($0) })

        XCTAssertFalse(reconciler.reconcileNow())
        XCTAssertEqual(calls.value, 0)
        XCTAssertTrue(state.exposed.isEmpty)
        XCTAssertTrue(state.unexposed.isEmpty)
        XCTAssertTrue(reconciler.healthSnapshot().isValid)
    }

    private func forward(hostPort: Int, guestPort: Int) -> PublishedPortForward {
        PublishedPortForward(
            protocol: .tcp,
            publishedPort: hostPort,
            localHost: "127.0.0.1",
            localPort: hostPort,
            guestHost: "192.168.127.2",
            guestPort: guestPort
        )
    }
}

private final class ReconcilerCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class LockedAvailability: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Bool

    init(_ value: Bool) {
        storedValue = value
    }

    var value: Bool {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}

private final class RegistryState: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var entries: Set<PublishedPortForward>
    private(set) var exposed: [PublishedPortForward] = []
    private(set) var unexposed: [PublishedPortForward] = []

    init(entries: Set<PublishedPortForward>) {
        self.entries = entries
    }

    func registry() -> ResolvedPortForwardRegistry? {
        lock.lock()
        defer { lock.unlock() }
        let rows = entries.map { forward in
            [
                "local": forward.localEndpoint,
                "remote": forward.remoteEndpoint,
                "protocol": forward.protocol.rawValue,
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rows) else { return nil }
        return ResolvedPortForwardRegistry.decode(data)
    }

    func replaceEntries(_ replacement: Set<PublishedPortForward>) {
        lock.withLock { entries = replacement }
    }

    func expose(_ forward: PublishedPortForward) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        exposed.append(forward)
        entries.insert(forward)
        return true
    }

    func unexpose(_ forward: PublishedPortForward) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        unexposed.append(forward)
        entries = Set(entries.filter {
            $0.protocol != forward.protocol
                || $0.localHost != forward.localHost
                || $0.localPort != forward.localPort
        })
        return true
    }
}
