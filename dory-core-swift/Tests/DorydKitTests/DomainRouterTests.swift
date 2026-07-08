@testable import DorydKit
import XCTest

final class DomainRouterTests: XCTestCase {
    func testBuildsRouteTableForOwnedIPv4Domains() {
        let router = DomainRouter()
        let table = router.table(from: [
            DomainRoute(hostname: "Web.Dory.Local.", address: "192.168.127.10"),
            DomainRoute(hostname: "db.dory.local", address: "not-an-ip"),
            DomainRoute(hostname: "outside.example.com", address: "192.168.127.11"),
        ])

        XCTAssertEqual(table, ["web.dory.local": "192.168.127.10"])
    }

    func testResolvesOwnedHostsCaseInsensitively() {
        let router = DomainRouter(suffix: "dory.local")
        let routes = [DomainRoute(hostname: "api.dory.local", address: "10.0.0.5")]

        XCTAssertEqual(router.resolve("API.DORY.LOCAL.", in: routes), "10.0.0.5")
        XCTAssertNil(router.resolve("api.example.com", in: routes))
    }
}
