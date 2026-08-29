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

    @Test func resolvedNICPinsTheExactDHCPLease() {
        let shared = GVProxyDesktopLaunchPlan.configurationYAML(
            hostOnly: false,
            guestMAC: "02:11:22:33:44:55"
        )
        #expect(shared.contains("dhcpStaticLeases:"))
        #expect(shared.contains("192.168.127.2: 02:11:22:33:44:55"))
        #expect(!shared.contains("connectivity: host-only"))

        let hostOnly = GVProxyDesktopLaunchPlan.configurationYAML(
            hostOnly: true,
            guestMAC: "02:aa:bb:cc:dd:ee"
        )
        #expect(hostOnly.contains("connectivity: host-only"))
        #expect(hostOnly.contains("192.168.127.2: 02:aa:bb:cc:dd:ee"))
    }
}
