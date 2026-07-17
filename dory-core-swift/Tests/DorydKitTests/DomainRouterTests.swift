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

    func testMatchesExactAndSingleLabelWildcardHosts() {
        XCTAssertTrue(DomainRouter.matches(pattern: "Admin.MyProject.Local.", hostname: "admin.myproject.local"))
        XCTAssertTrue(DomainRouter.matches(pattern: "*.myproject.local", hostname: "tenant.myproject.local"))
        XCTAssertFalse(DomainRouter.matches(pattern: "*.myproject.local", hostname: "deep.tenant.myproject.local"))
        XCTAssertFalse(DomainRouter.matches(pattern: "*.myproject.local", hostname: "myproject.local"))
        XCTAssertEqual(DomainRouter.matchSpecificity(
            pattern: "admin.myproject.local",
            hostname: "admin.myproject.local"
        ), 2)
        XCTAssertEqual(DomainRouter.matchSpecificity(
            pattern: "*.myproject.local",
            hostname: "admin.myproject.local"
        ), 1)
    }

    func testValidatesOnlyDNSHostnamesAndLeftmostWildcards() {
        XCTAssertTrue(DomainRouter.isValidHostnamePattern("admin.myproject.local"))
        XCTAssertTrue(DomainRouter.isValidHostnamePattern("*.myproject.local"))
        XCTAssertFalse(DomainRouter.isValidHostnamePattern("localhost"))
        XCTAssertFalse(DomainRouter.isValidHostnamePattern("127.0.0.1"))
        XCTAssertFalse(DomainRouter.isValidHostnamePattern("*.127.0.0.1"))
        XCTAssertFalse(DomainRouter.isValidHostnamePattern("admin.*.local"))
        XCTAssertFalse(DomainRouter.isValidHostnamePattern("-admin.myproject.local"))
    }
}
