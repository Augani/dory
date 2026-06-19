import Testing
import Foundation
@testable import Dory

@MainActor
struct DomainRouterTests {
    private func container(_ name: String, ip: String, status: RunState) -> Container {
        Container(id: name, name: name, image: "img", status: status, cpuPercent: 0,
                  memoryDisplay: "0", memoryLimitDisplay: "—", memoryFraction: 0, ports: "—",
                  uptime: "—", created: "now", ipAddress: ip, domain: "\(name).dory.local",
                  command: "x", restartPolicy: "no")
    }

    @Test func buildsRoutesForRunningContainers() {
        let router = DomainRouter()
        let containers = [
            container("web", ip: "192.168.215.6", status: .running),
            container("db", ip: "192.168.215.4", status: .running),
            container("worker", ip: "—", status: .stopped),
        ]
        let routes = router.routes(from: containers)
        #expect(routes["web.dory.local"] == "192.168.215.6")
        #expect(routes["db.dory.local"] == "192.168.215.4")
        #expect(routes["worker.dory.local"] == nil) // stopped, no IP
    }

    @Test func resolvesHostIgnoringTrailingDot() {
        let router = DomainRouter()
        let containers = [container("api", ip: "10.0.0.5", status: .running)]
        #expect(router.resolve("api.dory.local", in: containers) == "10.0.0.5")
        #expect(router.resolve("API.dory.local.", in: containers) == "10.0.0.5")
        #expect(router.resolve("unknown.dory.local", in: containers) == nil)
    }

    @Test func ownsDoryDomainsOnly() {
        let router = DomainRouter()
        #expect(router.owns("web.dory.local"))
        #expect(!router.owns("example.com"))
    }
}
