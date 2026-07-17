import Darwin
@testable import DorydKit
import XCTest

final class CustomDomainRouteStoreTests: XCTestCase {
    func testPersistsNormalizedExactAndWildcardMappings() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let saved = try fixture.store.replace([
            DomainRoute(hostname: "Admin.MyProject.Local.", address: "127.0.0.1", port: 80),
            DomainRoute(hostname: "*.Tenant.Test", address: "127.0.0.1", port: 8080),
        ], automaticSuffix: "dory.local")

        XCTAssertEqual(saved, [
            CustomDomainRouteConfiguration(hostname: "*.tenant.test", publishedPort: 8080),
            CustomDomainRouteConfiguration(hostname: "admin.myproject.local", publishedPort: 80),
        ])
        XCTAssertEqual(try CustomDomainRouteStore(
            environment: ["DORY_CUSTOM_DOMAIN_ROUTES": fixture.path]
        ).configuredRoutes(), saved)
    }

    func testActivatesOnlyRunningPublishedTCPPortsAndUsesPrivilegedBackend() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.store.replace([
            DomainRoute(hostname: "admin.myproject.local", address: "127.0.0.1", port: 80),
            DomainRoute(hostname: "missing.myproject.local", address: "127.0.0.1", port: 443),
        ], automaticSuffix: "dory.local")

        let rows = try JSONDecoder().decode([DockerContainerSummary].self, from: Data("""
        [{
          "Id":"web",
          "Names":["/web"],
          "State":"running",
          "Ports":[{"PublicPort":80,"PrivatePort":8080,"Type":"tcp"}],
          "Labels":{}
        }]
        """.utf8))

        XCTAssertEqual(fixture.store.activeRoutes(
            containers: .ok(rows),
            automaticSuffix: "dory.local"
        ), [
            DomainRoute(hostname: "admin.myproject.local", address: "127.0.0.1", port: 60_080),
        ])
    }

    func testRejectsUnsafeTargetsAutomaticDomainsDuplicatesAndInvalidWildcards() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        XCTAssertThrowsError(try fixture.store.replace([
            DomainRoute(hostname: "admin.myproject.local", address: "192.168.1.2", port: 80),
        ], automaticSuffix: "dory.local"))
        XCTAssertThrowsError(try fixture.store.replace([
            DomainRoute(hostname: "web.dory.local", address: "127.0.0.1", port: 80),
        ], automaticSuffix: "dory.local"))
        XCTAssertThrowsError(try fixture.store.replace([
            DomainRoute(hostname: "a.*.local", address: "127.0.0.1", port: 80),
        ], automaticSuffix: "dory.local"))
        XCTAssertThrowsError(try fixture.store.replace([
            DomainRoute(hostname: "admin.myproject.local", address: "127.0.0.1", port: 80),
            DomainRoute(hostname: "ADMIN.MYPROJECT.LOCAL", address: "127.0.0.1", port: 8080),
        ], automaticSuffix: "dory.local"))
    }

    func testRefusesSymlinkedConfigurationFile() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let target = fixture.root + "/target.json"
        try Data("{}".utf8).write(to: URL(fileURLWithPath: target))
        try FileManager.default.createSymbolicLink(atPath: fixture.path, withDestinationPath: target)

        XCTAssertThrowsError(try fixture.store.configuredRoutes())
        XCTAssertThrowsError(try fixture.store.replace([], automaticSuffix: "dory.local"))
    }

    func testRefusesHardLinkedPublicAndOversizedConfigurationFiles() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.store.replace([], automaticSuffix: "dory.local")

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.path)
        XCTAssertThrowsError(try fixture.store.configuredRoutes())

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.path)
        let hardLink = fixture.root + "/hard-link.json"
        XCTAssertEqual(link(fixture.path, hardLink), 0)
        XCTAssertThrowsError(try fixture.store.configuredRoutes())
        try FileManager.default.removeItem(atPath: hardLink)

        let oversized = Data(repeating: 0x20, count: 256 * 1024 + 1)
        try oversized.write(to: URL(fileURLWithPath: fixture.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.path)
        XCTAssertThrowsError(try fixture.store.configuredRoutes())
    }

    private struct Fixture {
        let root: String
        let path: String
        let store: CustomDomainRouteStore

        init() throws {
            root = NSTemporaryDirectory() + "dory-custom-domains-\(UUID().uuidString)"
            path = root + "/custom-domains.json"
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            store = CustomDomainRouteStore(environment: ["DORY_CUSTOM_DOMAIN_ROUTES": path])
        }

        func remove() {
            try? FileManager.default.removeItem(atPath: root)
        }
    }
}
