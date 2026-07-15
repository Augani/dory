@testable import DorydKit
import XCTest

final class NetworkRouteReconcilerTests: XCTestCase {
    func testBuildsContainerRoutesFromRunningPublishedTCPPorts() throws {
        let routes = NetworkRouteReconciler.routes(
            containers: .ok(try containers("""
            [
              {
                "Id": "abc",
                "Names": ["/web", "/project_web_1"],
                "State": "running",
                "Ports": [{"PublicPort": 8080, "Type": "tcp"}],
                "Labels": {}
              },
              {
                "Id": "def",
                "Names": ["/db"],
                "State": "exited",
                "Ports": [{"PublicPort": 5432, "Type": "tcp"}],
                "Labels": {}
              }
            ]
            """)),
            machines: [],
            suffix: "Dory.Local."
        )

        XCTAssertEqual(routes, [
            DomainRoute(hostname: "project_web_1.dory.local", address: "127.0.0.1", port: 8080),
            DomainRoute(hostname: "web.dory.local", address: "127.0.0.1", port: 8080),
        ])
    }

    func testComposeOneOffCannotStealLongRunningServiceRoute() throws {
        let routes = NetworkRouteReconciler.routes(
            containers: .ok(try containers("""
            [
              {
                "Id": "service",
                "Names": ["/example-app-1"],
                "State": "running",
                "Ports": [{"PublicPort": 8080, "Type": "tcp"}],
                "Labels": {
                  "com.docker.compose.oneoff": "False",
                  "dev.orbstack.domains": "app.example.local"
                }
              },
              {
                "Id": "one-off",
                "Names": ["/example-app-run-a1b2c3"],
                "State": "running",
                "Ports": [{"PublicPort": 9090, "Type": "tcp"}],
                "Labels": {
                  "com.docker.compose.oneoff": "True",
                  "dev.orbstack.domains": "app.example.local"
                }
              }
            ]
            """)),
            machines: [],
            suffix: "dory.local"
        )

        XCTAssertEqual(routes, [
            DomainRoute(hostname: "example-app-1.dory.local", address: "127.0.0.1", port: 8080),
            DomainRoute(hostname: "example-app-run-a1b2c3.dory.local", address: "127.0.0.1", port: 9090),
        ])
        XCTAssertFalse(routes.contains { $0.hostname == "app.example.local" })
    }

    func testLowContainerPortsUsePrivilegedBackendAndLoopbackHosts() throws {
        let routes = NetworkRouteReconciler.routes(
            containers: .ok(try containers("""
            [
              {
                "Id": "abc",
                "Names": ["/web"],
                "State": "running",
                "Ports": [
                  {"PublicPort": 80, "Type": "tcp"},
                  {"PublicPort": 53, "Type": "udp"}
                ],
                "Labels": {}
              }
            ]
            """)),
            machines: [],
            suffix: "dory.local"
        )

        XCTAssertEqual(routes, [
            DomainRoute(hostname: "127.0.0.1", address: "127.0.0.1", port: 60_080),
            DomainRoute(hostname: "localhost", address: "127.0.0.1", port: 60_080),
            DomainRoute(hostname: "web.dory.local", address: "127.0.0.1", port: 60_080),
        ])
    }

    func testBuildsMachineRoutesOnlyForRunningIPv4Addresses() {
        let routes = NetworkRouteReconciler.routes(
            containers: .ok([]),
            machines: [
                DoryMachineStatus(id: "dev", state: .running, address: "192.168.64.10"),
                DoryMachineStatus(id: "friendly", state: .running, address: "friendly.dory.local"),
                DoryMachineStatus(id: "stopped", state: .stopped, address: "192.168.64.11"),
            ],
            suffix: "dory.local"
        )

        XCTAssertEqual(routes, [
            DomainRoute(hostname: "dev.dory.local", address: "192.168.64.10", port: 80),
        ])
    }

    func testMachineRoutesOverrideCollidingContainerNames() throws {
        let routes = NetworkRouteReconciler.routes(
            containers: .ok(try containers("""
            [
              {
                "Id": "abc",
                "Names": ["/dev"],
                "State": "running",
                "Ports": [{"PublicPort": 8080, "Type": "tcp"}],
                "Labels": {}
              }
            ]
            """)),
            machines: [
                DoryMachineStatus(id: "dev", state: .running, address: "192.168.64.10"),
            ],
            suffix: "dory.local"
        )

        XCTAssertEqual(routes, [
            DomainRoute(hostname: "dev.dory.local", address: "192.168.64.10", port: 80),
        ])
    }

    func testUnavailableContainersStillPublishMachineRoutes() {
        let routes = NetworkRouteReconciler.routes(
            containers: .unavailable("engine sleeping"),
            machines: [
                DoryMachineStatus(id: "dev", state: .running, address: "192.168.64.10"),
            ],
            suffix: "dory.local"
        )

        XCTAssertEqual(routes, [
            DomainRoute(hostname: "dev.dory.local", address: "192.168.64.10", port: 80),
        ])
    }

    func testIncludesAdditionalRoutesWithPathPrefixes() {
        let routes = NetworkRouteReconciler.routes(
            containers: .ok([]),
            machines: [],
            suffix: "dory.local",
            additionalRoutes: [
                DomainRoute(
                    hostname: "web.default.k8s.dory.local",
                    address: "127.0.0.1",
                    port: 18_001,
                    pathPrefix: "/api/v1/namespaces/default/services/web:80/proxy"
                ),
            ]
        )

        XCTAssertEqual(routes, [
            DomainRoute(
                hostname: "web.default.k8s.dory.local",
                address: "127.0.0.1",
                port: 18_001,
                pathPrefix: "/api/v1/namespaces/default/services/web:80/proxy"
            ),
        ])
    }

    private func containers(_ json: String) throws -> [DockerContainerSummary] {
        try JSONDecoder().decode([DockerContainerSummary].self, from: Data(json.utf8))
    }
}
