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
}
