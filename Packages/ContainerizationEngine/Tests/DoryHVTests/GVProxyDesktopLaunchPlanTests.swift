import Testing
@testable import DoryHV

@Suite struct GVProxyDesktopLaunchPlanTests {
    @Test func desktopNetworkingUsesOnlyPerMachineSockets() {
        let arguments = GVProxyDesktopLaunchPlan.arguments(
            mtu: 1_280,
            datapathSocket: "/private/dory/machine-a/gv.sock",
            apiSocket: "/private/dory/machine-a/api.sock"
        )

        #expect(arguments == [
            "-mtu", "1280",
            "-listen-vfkit", "unixgram:///private/dory/machine-a/gv.sock",
            "-listen", "unix:///private/dory/machine-a/api.sock",
            "-ssh-port", "-1",
        ])
        #expect(!arguments.contains("2222"))
    }

    @Test func hostOnlyNetworkingUsesTheAuditedConnectivityConfiguration() {
        let arguments = GVProxyDesktopLaunchPlan.arguments(
            mtu: 1_500,
            datapathSocket: "/private/dory/machine-b/gv.sock",
            apiSocket: "/private/dory/machine-b/api.sock",
            configurationPath: "/private/dory/machine-b/network.yaml"
        )

        #expect(arguments.suffix(2) == ["-config", "/private/dory/machine-b/network.yaml"])
        #expect(GVProxyDesktopLaunchPlan.hostOnlyConfigurationYAML.contains("connectivity: host-only"))
        #expect(!GVProxyDesktopLaunchPlan.hostOnlyConfigurationYAML.contains("connectivity: nat"))
    }
}
