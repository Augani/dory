@testable import DorydKit
import Foundation
import XCTest

final class CorporateConnectivityTests: XCTestCase {
    func testManualProfileSeparatesHostDockerdAndSharedWorkloadConsumers() {
        let profile = validProfile()
        let validation = CorporateConnectivityValidator.validate(
            profile,
            home: "/tmp/dory-corporate-home",
            system: emptySystem()
        )

        XCTAssertTrue(validation.valid, validation.errors.joined(separator: "; "))
        XCTAssertEqual(validation.effectiveHost.httpsProxy, "http://host.proxy.test:8080")
        XCTAssertEqual(validation.effectiveDockerd.httpsProxy, "http://pull.proxy.test:8443")
        XCTAssertEqual(validation.effectiveWorkload.httpsProxy, "http://workload.proxy.test:8080")
        XCTAssertTrue(validation.effectiveDockerd.noProxy.contains("registry.corp.test"))
    }

    func testContradictoryBuildAndContainerProxiesFailClosed() {
        var profile = validProfile()
        profile.containers = CorporateProxyLayer(
            source: .manual,
            httpsProxy: "http://other.proxy.test:8080"
        )

        let validation = CorporateConnectivityValidator.validate(
            profile,
            home: "/tmp/dory-corporate-home",
            system: emptySystem()
        )

        XCTAssertFalse(validation.valid)
        XCTAssertTrue(validation.errors.contains { $0.contains("proxies.default") })
    }

    func testProxyCredentialsAndImplicitInsecureRegistryAreRejected() {
        var profile = validProfile()
        profile.host.httpProxy = "http://alice:secret@proxy.test:8080"
        profile.registries.insecureRegistries = ["http://registry.test:5000"]

        let validation = CorporateConnectivityValidator.validate(
            profile,
            home: "/tmp/dory-corporate-home",
            system: emptySystem()
        )

        XCTAssertFalse(validation.valid)
        XCTAssertTrue(validation.errors.contains { $0.contains("credential-free") })
        XCTAssertTrue(validation.errors.contains { $0.contains("host[:port]") })
    }

    func testActiveVPNRouteCollisionBlocksBridgeSubnet() {
        let profile = validProfile()
        var system = emptySystem()
        system.bridgeSubnetCollisionRoutes = ["192.168.127.0/24 via 10.0.0.1 dev utun7"]

        let validation = CorporateConnectivityValidator.validate(
            profile,
            home: "/tmp/dory-corporate-home",
            system: system
        )

        XCTAssertFalse(validation.valid)
        XCTAssertTrue(validation.errors.contains { $0.contains("collides") && $0.contains("utun7") })
    }

    func testSystemInspectorRetainsPACScopedResolversAndTunnelProvenance() {
        let snapshot = CorporateConnectivitySystemInspector.parse(
            proxy: """
            <dictionary> {
              HTTPEnable : 1
              HTTPPort : 8080
              HTTPProxy : proxy.corp.test
              ProxyAutoConfigEnable : 1
              ProxyAutoConfigURLString : https://pac.corp.test/proxy.pac
              ExceptionsList : <array> {
                0 : localhost
                1 : *.corp.test
              }
            }
            """,
            dns: """
            DNS configuration

            resolver #1
              nameserver[0] : 10.20.0.53
              if_index : 18 (utun7)
              flags    : Scoped, Request A records
              reach    : 0x00000002 (Reachable)
              order    : 101000

            resolver #2
              domain   : corp.test
              nameserver[0] : 10.30.0.53
              order    : 100000
            """,
            route: """
               route to: default
            destination: default
                   mask: default
                gateway: 10.0.0.1
              interface: en0
            """,
            interfaces: "lo0 en0 utun7",
            routes: """
            Internet:
            Destination        Gateway            Flags               Netif Expire
            192.168.127/24     10.20.0.1          UGSc                utun7
            """,
            bridgeSubnet: "192.168.127.0/24"
        )

        XCTAssertEqual(snapshot.httpProxy, "http://proxy.corp.test:8080")
        XCTAssertEqual(snapshot.pacURL, "https://pac.corp.test/proxy.pac")
        XCTAssertEqual(snapshot.bypassDomains, ["*.corp.test", "localhost"])
        XCTAssertEqual(snapshot.defaultInterface, "en0")
        XCTAssertEqual(snapshot.tunnelInterfaces, ["utun7"])
        XCTAssertEqual(snapshot.dnsResolvers.count, 2)
        XCTAssertEqual(snapshot.dnsResolvers[0].domain, "corp.test")
        XCTAssertEqual(snapshot.dnsResolvers[1].interface, "utun7")
        XCTAssertTrue(snapshot.dnsResolvers[1].scoped)
        XCTAssertTrue(snapshot.bridgeSubnetCollisionRoutes.first?.contains("utun7") == true)
    }

    func testDockerClientMutationPreservesUnrelatedKeysAndRestoresExactPriorDefault() throws {
        let home = try temporaryHome("restore")
        defer { try? FileManager.default.removeItem(atPath: home) }
        let dockerDirectory = home + "/.docker"
        try FileManager.default.createDirectory(atPath: dockerDirectory, withIntermediateDirectories: true)
        let original: [String: Any] = [
            "auths": ["registry.test": ["auth": "opaque"]],
            "credsStore": "osxkeychain",
            "proxies": [
                "default": ["httpProxy": "http://old.proxy:3128"],
                "tcp://other:2376": ["httpsProxy": "http://other.proxy:8080"],
            ],
        ]
        try JSONSerialization.data(withJSONObject: original, options: [.prettyPrinted])
            .write(to: URL(fileURLWithPath: dockerDirectory + "/config.json"))

        let store = CorporateConnectivityStore(home: home)
        let proxy = CorporateProxyLayer(
            source: .manual,
            httpProxy: "http://new.proxy:8080",
            httpsProxy: "http://new.proxy:8080",
            noProxy: ["localhost", ".corp.test"]
        )
        _ = try store.reconcileDockerClientProxy(proxy, profileDigest: "profile-a")

        var current = try dockerConfig(home)
        XCTAssertEqual(current["credsStore"] as? String, "osxkeychain")
        XCTAssertNotNil((current["auths"] as? [String: Any])?["registry.test"])
        let proxies = try XCTUnwrap(current["proxies"] as? [String: Any])
        XCTAssertNotNil(proxies["tcp://other:2376"])
        XCTAssertEqual((proxies["default"] as? [String: Any])?["httpsProxy"] as? String, "http://new.proxy:8080")

        _ = try store.reconcileDockerClientProxy(nil, profileDigest: "profile-disabled")
        current = try dockerConfig(home)
        let restored = try XCTUnwrap(current["proxies"] as? [String: Any])
        XCTAssertEqual((restored["default"] as? [String: Any])?["httpProxy"] as? String, "http://old.proxy:3128")
        XCTAssertNotNil(restored["tcp://other:2376"])
    }

    func testDockerClientOwnershipConflictNeverOverwritesLaterUserEdit() throws {
        let home = try temporaryHome("conflict")
        defer { try? FileManager.default.removeItem(atPath: home) }
        let store = CorporateConnectivityStore(home: home)
        let proxy = CorporateProxyLayer(source: .manual, httpProxy: "http://dory.proxy:8080")
        _ = try store.reconcileDockerClientProxy(proxy, profileDigest: "profile-a")

        var current = try dockerConfig(home)
        var proxies = current["proxies"] as? [String: Any] ?? [:]
        proxies["default"] = ["httpProxy": "http://user.changed:9999"]
        current["proxies"] = proxies
        try JSONSerialization.data(withJSONObject: current, options: [.prettyPrinted])
            .write(to: URL(fileURLWithPath: home + "/.docker/config.json"))

        XCTAssertThrowsError(try store.reconcileDockerClientProxy(nil, profileDigest: "disabled")) { error in
            XCTAssertTrue("\(error)".contains("leaving it untouched"), "\(error)")
        }
        let unchanged = try dockerConfig(home)
        XCTAssertEqual(
            (((unchanged["proxies"] as? [String: Any])?["default"] as? [String: Any])?["httpProxy"] as? String),
            "http://user.changed:9999"
        )
    }

    func testDryRunReturnsCompleteNonDestructivePlanWithoutPersistingProfile() throws {
        let home = try temporaryHome("plan")
        defer { try? FileManager.default.removeItem(atPath: home) }
        let runner = FixtureCommandRunner(outputs: [
            "/usr/sbin/scutil --proxy": HealthCommandOutput(exitCode: 0, stdout: "<dictionary> {\n}", stderr: ""),
            "/usr/sbin/scutil --dns": HealthCommandOutput(exitCode: 0, stdout: "", stderr: ""),
            "/sbin/route -n get default": HealthCommandOutput(exitCode: 0, stdout: "gateway: 10.0.0.1\ninterface: en0\n", stderr: ""),
            "/sbin/ifconfig -l": HealthCommandOutput(exitCode: 0, stdout: "lo0 en0\n", stderr: ""),
            "/usr/sbin/netstat -rn -f inet": HealthCommandOutput(exitCode: 0, stdout: "", stderr: ""),
        ])
        let reconciler = CorporateConnectivityReconciler(
            home: home,
            inspector: CorporateConnectivitySystemInspector(runner: runner),
            prober: CorporateConnectivityProber(runner: runner)
        )

        let status = reconciler.plan(validProfile())

        XCTAssertTrue(status.valid, status.validationErrors.joined(separator: "; "))
        XCTAssertFalse(status.applied)
        XCTAssertNotNil(status.profile)
        XCTAssertTrue(status.plan.contains { $0.kind == .dockerClientProxy })
        XCTAssertTrue(status.plan.contains { $0.kind == .restartDockerd })
        XCTAssertTrue(status.plan.allSatisfy { !$0.destructive })
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/.dory/corporate-connectivity.json"))
    }

    func testCAReaderRejectsSymlinksAndWritableTrustRoots() throws {
        let home = try temporaryHome("ca-safety")
        defer { try? FileManager.default.removeItem(atPath: home) }
        let caDirectory = home + "/.dory/corporate-ca"
        try FileManager.default.createDirectory(atPath: caDirectory, withIntermediateDirectories: true)
        let certificate = caDirectory + "/corp.pem"
        try Data("fixture-certificate".utf8).write(to: URL(fileURLWithPath: certificate))
        XCTAssertEqual(try CorporateConnectivityValidator.safeCAData(path: certificate), Data("fixture-certificate".utf8))

        XCTAssertEqual(chmod(certificate, 0o666), 0)
        XCTAssertThrowsError(try CorporateConnectivityValidator.safeCAData(path: certificate))
        XCTAssertEqual(chmod(certificate, 0o600), 0)

        let symlink = caDirectory + "/linked.pem"
        XCTAssertEqual(Darwin.symlink(certificate, symlink), 0)
        XCTAssertThrowsError(try CorporateConnectivityValidator.safeCAData(path: symlink))
    }

    func testProfileSaveRefusesToReplaceSymlink() throws {
        let home = try temporaryHome("profile-symlink")
        defer { try? FileManager.default.removeItem(atPath: home) }
        let directory = home + "/.dory"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let outside = home + "/outside.json"
        try Data("outside".utf8).write(to: URL(fileURLWithPath: outside))
        XCTAssertEqual(Darwin.symlink(outside, directory + "/corporate-connectivity.json"), 0)

        XCTAssertThrowsError(try CorporateConnectivityStore(home: home).save(validProfile()))
        XCTAssertEqual(try String(contentsOfFile: outside, encoding: .utf8), "outside")
    }

    func testPACOnlyRegistryProbeFailsClosedInsteadOfProbingDirectly() {
        var profile = validProfile()
        profile.host = CorporateProxyLayer(source: .manual, pacURL: "https://pac.corp.test/proxy.pac")
        profile.dockerd = CorporateProxyLayer(source: .manual, httpsProxy: "http://pull.proxy.test:8443")
        profile.buildKit = CorporateProxyLayer(source: .manual, httpsProxy: "http://workload.proxy.test:8080")
        profile.containers = profile.buildKit
        let validation = CorporateConnectivityValidator.validate(profile, home: "/tmp/dory-corporate-home", system: emptySystem())
        XCTAssertTrue(validation.valid, validation.errors.joined(separator: "; "))

        let evidence = CorporateConnectivityProber(runner: FixtureCommandRunner(outputs: [:])).probe(
            profile: profile,
            validation: validation,
            system: emptySystem()
        )

        let registry = evidence.first { $0.kind == "registry" }
        XCTAssertEqual(registry?.succeeded, false)
        XCTAssertTrue(registry?.detail.contains("PAC is active") == true)
    }

    func testFailedGuestApplyRollsBackDockerClientAndDoesNotPublishProfile() throws {
        let home = try temporaryHome("transaction-rollback")
        defer { try? FileManager.default.removeItem(atPath: home) }
        let dockerDirectory = home + "/.docker"
        try FileManager.default.createDirectory(atPath: dockerDirectory, withIntermediateDirectories: true)
        let original: [String: Any] = ["proxies": ["default": ["httpProxy": "http://before.test:3128"]]]
        try JSONSerialization.data(withJSONObject: original).write(
            to: URL(fileURLWithPath: dockerDirectory + "/config.json")
        )
        let runner = FixtureCommandRunner(outputs: [
            "/usr/sbin/scutil --proxy": HealthCommandOutput(exitCode: 0, stdout: "<dictionary> {\n}", stderr: ""),
            "/usr/sbin/scutil --dns": HealthCommandOutput(exitCode: 0, stdout: "", stderr: ""),
            "/sbin/route -n get default": HealthCommandOutput(exitCode: 0, stdout: "gateway: 10.0.0.1\ninterface: en0\n", stderr: ""),
            "/sbin/ifconfig -l": HealthCommandOutput(exitCode: 0, stdout: "lo0 en0\n", stderr: ""),
            "/usr/sbin/netstat -rn -f inet": HealthCommandOutput(exitCode: 0, stdout: "", stderr: ""),
        ])
        let reconciler = CorporateConnectivityReconciler(
            home: home,
            inspector: CorporateConnectivitySystemInspector(runner: runner),
            prober: CorporateConnectivityProber(runner: runner),
            guestApply: { profile, _, _ in
                if profile.enabled { throw CorporateConnectivityError.unavailable("guest fixture failure") }
                return CorporateGuestApplyResult(state: "disabled", changed: true, dockerdRestarted: true)
            }
        )

        let status = reconciler.apply(validProfile(), runProbes: false)

        XCTAssertFalse(status.applied)
        XCTAssertFalse(status.valid)
        XCTAssertTrue(status.validationErrors.contains { $0.contains("guest fixture failure") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/.dory/corporate-connectivity.json"))
        let current = try dockerConfig(home)
        let restored = ((current["proxies"] as? [String: Any])?["default"] as? [String: Any])
        XCTAssertEqual(restored?["httpProxy"] as? String, "http://before.test:3128")
    }

    private func validProfile() -> CorporateConnectivityProfile {
        CorporateConnectivityProfile(
            enabled: true,
            host: CorporateProxyLayer(
                source: .manual,
                httpProxy: "http://host.proxy.test:8080",
                httpsProxy: "http://host.proxy.test:8080",
                noProxy: ["localhost", ".corp.test"]
            ),
            dockerd: CorporateProxyLayer(
                source: .manual,
                httpProxy: "http://pull.proxy.test:8443",
                httpsProxy: "http://pull.proxy.test:8443",
                noProxy: ["registry.corp.test"]
            ),
            buildKit: CorporateProxyLayer(
                source: .manual,
                httpProxy: "http://workload.proxy.test:8080",
                httpsProxy: "http://workload.proxy.test:8080",
                noProxy: ["localhost"]
            ),
            containers: CorporateProxyLayer(
                source: .manual,
                httpProxy: "http://workload.proxy.test:8080",
                httpsProxy: "http://workload.proxy.test:8080",
                noProxy: ["localhost"]
            ),
            registries: CorporateRegistryConfiguration(
                mirrors: ["https://registry.corp.test"],
                insecureRegistries: ["lab-registry.corp.test:5000"],
                probeRegistries: ["https://registry.corp.test/v2/"]
            ),
            splitDNS: [CorporateSplitDNSRule(
                domain: "corp.test",
                servers: ["10.20.0.53"],
                probeNames: ["registry.corp.test"]
            )]
        )
    }

    private func emptySystem() -> CorporateSystemSnapshot {
        CorporateSystemSnapshot(
            generatedAt: Date(timeIntervalSince1970: 0),
            httpProxy: nil,
            httpsProxy: nil,
            pacURL: nil,
            pacAutoDiscovery: false,
            bypassDomains: [],
            dnsResolvers: [],
            defaultGateway: "10.0.0.1",
            defaultInterface: "en0",
            interfaces: ["lo0", "en0"],
            tunnelInterfaces: [],
            bridgeSubnetCollisionRoutes: [],
            fingerprint: "fixture"
        )
    }

    private func temporaryHome(_ suffix: String) throws -> String {
        let path = "/tmp/dory-corporate-\(suffix)-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func dockerConfig(_ home: String) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: home + "/.docker/config.json"))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private final class FixtureCommandRunner: HealthCommandRunning, @unchecked Sendable {
    private let outputs: [String: HealthCommandOutput]

    init(outputs: [String: HealthCommandOutput]) {
        self.outputs = outputs
    }

    func run(
        executablePath: String,
        arguments: [String],
        environment _: [String: String],
        timeout _: TimeInterval
    ) -> HealthCommandOutput {
        outputs[([executablePath] + arguments).joined(separator: " ")]
            ?? HealthCommandOutput(exitCode: 127, stdout: "", stderr: "missing fixture")
    }
}
