import Testing
@testable import Dory

struct ExposeTunnelTests {
    @Test func localPortUsesQuickTunnelURL() throws {
        let plan = try ExposeTunnelPlan(target: .localPort(3000))

        #expect(plan.url == "http://127.0.0.1:3000")
        #expect(plan.cloudflaredCommand == ["cloudflared", "tunnel", "--url", "http://127.0.0.1:3000"])
    }

    @Test func machineTargetUsesDoryLocalAndNamedHostname() throws {
        let plan = try ExposeTunnelPlan(
            target: .machine(name: "rust-dev", port: 8080),
            hostname: "preview.example.com",
            scheme: "https"
        )

        #expect(plan.url == "https://rust-dev.dory.local:8080")
        #expect(plan.cloudflaredCommand == [
            "cloudflared", "tunnel", "--hostname", "preview.example.com",
            "--url", "https://rust-dev.dory.local:8080", "run"
        ])
    }

    @Test func rejectsUnsafeInputs() {
        #expect(throws: ExposeTunnelPlan.PlanError.invalidPort) {
            try ExposeTunnelPlan(target: .localPort(0))
        }
        #expect(throws: ExposeTunnelPlan.PlanError.invalidMachineName) {
            try ExposeTunnelPlan(target: .machine(name: "../dev", port: 80))
        }
        #expect(throws: ExposeTunnelPlan.PlanError.invalidMachineName) {
            try ExposeTunnelPlan(target: .machine(name: "rust_dev", port: 80))
        }
        #expect(throws: ExposeTunnelPlan.PlanError.invalidHostname) {
            try ExposeTunnelPlan(target: .localPort(3000), hostname: "localhost")
        }
        #expect(throws: ExposeTunnelPlan.PlanError.unsupportedScheme) {
            try ExposeTunnelPlan(target: .localPort(3000), scheme: "ftp")
        }
    }
}
