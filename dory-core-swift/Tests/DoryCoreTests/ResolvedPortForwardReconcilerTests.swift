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
          {"local":"127.0.0.1:8443","remote":"192.168.127.2:443","protocol":"tcp"},
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
        XCTAssertTrue(plan.missing.isEmpty)
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
        XCTAssertEqual(state.unexposed, [desired])
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
