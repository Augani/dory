@testable import DorydKit
import DoryCore
import XCTest

final class AuthorizedNetworkingReconcilerTests: XCTestCase {
    func testReconcilesLiveLowPortsOnlyAfterAuthorizationAndSuppressesUnchangedPlans() throws {
        let controller = NetworkingController(configuration: NetworkingConfiguration(
            dnsPort: 15353,
            localCACertificatePath: nil
        ))
        let ports = PublishedPortsBox([
            DoryListenPort(protocol: "tcp", port: 25),
            DoryListenPort(protocol: "udp", port: 53),
            DoryListenPort(protocol: "tcp", port: 8080),
        ])
        let applier = FakeAuthorizedNetworkingApplier()
        let reconciler = AuthorizedNetworkingReconciler(
            networkingController: controller,
            publishedPorts: { ports.value },
            applier: applier
        )

        XCTAssertFalse(try reconciler.reconcileNow())
        XCTAssertEqual(applier.plans.count, 1)
        applier.authorized = true
        XCTAssertTrue(try reconciler.reconcileNow())
        XCTAssertEqual(applier.plans.count, 2)
        XCTAssertEqual(applier.plans.last?.privilegedTCPForwards, [
            PrivilegedTCPForward(listenPort: 25, targetPort: 60_025),
        ])

        XCTAssertTrue(try reconciler.reconcileNow())
        XCTAssertEqual(applier.plans.count, 2)

        ports.value = [DoryListenPort(protocol: "tcp", port: 110)]
        XCTAssertTrue(try reconciler.reconcileNow())
        XCTAssertEqual(applier.plans.count, 3)
        XCTAssertEqual(applier.plans.last?.privilegedTCPForwards, [
            PrivilegedTCPForward(listenPort: 110, targetPort: 60_110),
        ])
    }
}

private final class FakeAuthorizedNetworkingApplier: AuthorizedNetworkingApplying, @unchecked Sendable {
    private let lock = NSLock()
    var authorized = false
    private var storage: [NetworkingAuthorizationPlan] = []

    var plans: [NetworkingAuthorizationPlan] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func reconcile(_ plan: NetworkingAuthorizationPlan) throws -> Bool {
        lock.lock()
        storage.append(plan)
        let authorized = self.authorized
        lock.unlock()
        return authorized
    }
}

private final class PublishedPortsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [DoryListenPort]

    init(_ value: [DoryListenPort]) {
        storage = value
    }

    var value: [DoryListenPort] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}
