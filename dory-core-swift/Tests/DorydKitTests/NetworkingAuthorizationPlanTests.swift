@testable import DorydKit
import XCTest

final class NetworkingAuthorizationPlanTests: XCTestCase {
    func testBuildsResolverPfAndTrustRequests() throws {
        let plan = try NetworkingAuthorizationPlan.make(configuration: NetworkingConfiguration(
            suffix: "Dory.Local.",
            dnsBindAddress: "127.0.0.1",
            dnsPort: 15353,
            httpProxyPort: 18080,
            httpsProxyPort: 18443,
            privilegedTCPForwards: [
                PrivilegedTCPForward(listenPort: 25, targetPort: 1025),
                PrivilegedTCPForward(listenPort: 110, targetPort: 1110),
            ],
            localCACertificatePath: "/Users/test/.dory/ca/ca.crt"
        ))

        XCTAssertEqual(plan.degradedMode, "high-port-dns-only")
        XCTAssertEqual(plan.authorizedMode, "system-resolver-proxy-tls")
        XCTAssertEqual(plan.suffix, "dory.local")
        XCTAssertEqual(plan.dnsPort, 15353)
        XCTAssertEqual(plan.privilegedTCPForwards, [
            PrivilegedTCPForward(listenPort: 25, targetPort: 1025),
            PrivilegedTCPForward(listenPort: 110, targetPort: 1110),
        ])
        XCTAssertEqual(plan.requests.map(\.kind), [.resolverFile, .pfAnchor, .pfEnable, .localCATrust])

        let resolver = try XCTUnwrap(plan.requests.first { $0.kind == .resolverFile })
        XCTAssertEqual(resolver.filePath, "/etc/resolver/dory.local")
        XCTAssertEqual(resolver.command, ["/usr/bin/install", "-m", "0644", "<generated>", "/etc/resolver/dory.local"])
        XCTAssertEqual(resolver.fileContents, """
        # Managed by Dory. Do not edit.
        nameserver 127.0.0.1
        port 15353

        """)

        let pf = try XCTUnwrap(plan.requests.first { $0.kind == .pfAnchor })
        XCTAssertEqual(pf.filePath, "/etc/pf.anchors/dev.dory")
        XCTAssertTrue(pf.fileContents?.contains("port 25 -> 127.0.0.1 port 1025") == true)
        XCTAssertTrue(pf.fileContents?.contains("port 80 -> 127.0.0.1 port 18080") == true)
        XCTAssertTrue(pf.fileContents?.contains("port 110 -> 127.0.0.1 port 1110") == true)
        XCTAssertTrue(pf.fileContents?.contains("port 443 -> 127.0.0.1 port 18443") == true)

        let enable = try XCTUnwrap(plan.requests.first { $0.kind == .pfEnable })
        XCTAssertEqual(enable.command, ["/sbin/pfctl", "-a", "com.apple/dev.dory", "-f", "/etc/pf.anchors/dev.dory"])

        let trust = try XCTUnwrap(plan.requests.first { $0.kind == .localCATrust })
        XCTAssertEqual(trust.command, [
            "/usr/bin/security", "add-trusted-cert", "-d", "-r", "trustRoot",
            "-k", "/Library/Keychains/System.keychain", "/Users/test/.dory/ca/ca.crt",
        ])
    }

    func testRejectsUnsafeSuffixesAndPaths() {
        XCTAssertThrowsError(try NetworkingAuthorizationPlan.make(configuration: NetworkingConfiguration(
            suffix: "dory/local",
            dnsPort: 15353,
            localCACertificatePath: "/tmp/ca.crt"
        ))) { error in
            XCTAssertEqual(error as? NetworkingAuthorizationError, .invalidSuffix("dory/local"))
        }

        XCTAssertThrowsError(try NetworkingAuthorizationPlan.make(configuration: NetworkingConfiguration(
            dnsPort: 15353,
            localCACertificatePath: "relative/ca.crt"
        ))) { error in
            XCTAssertEqual(error as? NetworkingAuthorizationError, .invalidPath("localCACertificatePath"))
        }
    }

    func testDecodesLegacyPlanWithoutPrivilegedForwards() throws {
        let json = Data("""
        {
          "degradedMode": "high-port-dns-only",
          "authorizedMode": "system-resolver-proxy-tls",
          "suffix": "dory.local",
          "dnsBindAddress": "127.0.0.1",
          "dnsPort": 15353,
          "httpProxyPort": 8080,
          "httpsProxyPort": 8443,
          "requests": []
        }
        """.utf8)

        let plan = try JSONDecoder().decode(NetworkingAuthorizationPlan.self, from: json)

        XCTAssertEqual(plan.privilegedTCPForwards, [])
    }

    func testRejectsPrivilegedOrInvalidDaemonPorts() {
        XCTAssertThrowsError(try NetworkingAuthorizationPlan.make(configuration: NetworkingConfiguration(
            dnsPort: 53
        ))) { error in
            XCTAssertEqual(error as? NetworkingAuthorizationError, .invalidPort("dnsPort"))
        }

        XCTAssertThrowsError(try NetworkingAuthorizationPlan.make(configuration: NetworkingConfiguration(
            dnsBindAddress: "127.0.0.999",
            dnsPort: 15353
        ))) { error in
            XCTAssertEqual(error as? NetworkingAuthorizationError, .invalidBindAddress("127.0.0.999"))
        }

        XCTAssertThrowsError(try NetworkingAuthorizationPlan.make(configuration: NetworkingConfiguration(
            dnsPort: 15353,
            privilegedTCPForwards: [PrivilegedTCPForward(listenPort: 25, targetPort: 25)]
        ))) { error in
            XCTAssertEqual(error as? NetworkingAuthorizationError, .invalidPrivilegedForward("25:25"))
        }

        XCTAssertThrowsError(try NetworkingAuthorizationPlan.make(configuration: NetworkingConfiguration(
            dnsPort: 15353,
            privilegedTCPForwards: [PrivilegedTCPForward(listenPort: 1024, targetPort: 2024)]
        ))) { error in
            XCTAssertEqual(error as? NetworkingAuthorizationError, .invalidPrivilegedForward("1024:2024"))
        }
    }
}
