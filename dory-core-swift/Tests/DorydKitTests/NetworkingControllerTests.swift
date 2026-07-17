@testable import DorydKit
import XCTest

final class NetworkingControllerTests: XCTestCase {
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
