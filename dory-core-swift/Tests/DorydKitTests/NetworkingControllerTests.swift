@testable import DorydKit
import XCTest

final class NetworkingControllerTests: XCTestCase {
    func testOfflineRouteRefreshDoesNotCreateTLSIdentityOrStartListeners() throws {
        let base = NSTemporaryDirectory() + "dory-network-offline-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let controller = NetworkingController(configuration: NetworkingConfiguration(
            dnsPort: 0, httpProxyPort: 0, httpsProxyPort: 0,
            localCACertificatePath: base + "/ca/ca.crt"
        ))
        controller.replaceRoutes([
            DomainRoute(hostname: "offline.example.local", address: "127.0.0.1", port: 60_080),
        ])
        XCTAssertFalse(controller.status().dnsRunning)
        XCTAssertFalse(controller.status().httpProxyRunning)
        XCTAssertFalse(controller.status().httpsProxyRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base))
        XCTAssertThrowsError(try controller.repair(.routes))
        XCTAssertThrowsError(try controller.repair(.domains))
        XCTAssertThrowsError(try controller.repair(.dns))
    }

    func testStartIsIdempotentAndLateRouteRefreshCannotUndoStop() throws {
        let base = NSTemporaryDirectory() + "dory-network-restart-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let controller = NetworkingController(configuration: NetworkingConfiguration(
            dnsPort: 0, httpProxyPort: 0, httpsProxyPort: 0,
            localCACertificatePath: base + "/ca/ca.crt"
        ))
        try controller.start()
        defer { controller.stop() }
        let first = controller.status()
        try controller.start()
        let second = controller.status()
        XCTAssertEqual(second.dnsPort, first.dnsPort)
        XCTAssertEqual(second.httpProxyPort, first.httpProxyPort)
        XCTAssertEqual(second.httpsProxyPort, first.httpsProxyPort)
        XCTAssertTrue(second.dnsRunning && second.httpProxyRunning && second.httpsProxyRunning)
        controller.stop()
        controller.replaceRoutes([
            DomainRoute(hostname: "late.example.local", address: "127.0.0.1", port: 60_080),
        ])
        let stopped = controller.status()
        XCTAssertFalse(stopped.dnsRunning || stopped.httpProxyRunning || stopped.httpsProxyRunning)
        XCTAssertEqual(controller.tlsRouteNames, [])
        XCTAssertThrowsError(try controller.repair(.domains))
        XCTAssertFalse(controller.status().httpProxyRunning)
    }

    func testCustomDomainRefreshesTLSIdentityWithoutStoppingProxy() throws {
        let base = NSTemporaryDirectory() + "dory-network-controller-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let controller = NetworkingController(configuration: NetworkingConfiguration(
            suffix: "dory.local",
            dnsPort: 0,
            httpProxyPort: 0,
            httpsProxyPort: 0,
            localCACertificatePath: base + "/ca/ca.crt"
        ))
        try controller.start()
        defer { controller.stop() }

        controller.replaceRoutes([
            DomainRoute(hostname: "admin.myproject.local", address: "127.0.0.1", port: 60_080),
        ])

        XCTAssertTrue(controller.status().httpsProxyRunning)
        XCTAssertTrue(controller.tlsRouteNames.contains("admin.myproject.local"))
        XCTAssertEqual(controller.status().routes.first?.hostname, "admin.myproject.local")
    }
}
