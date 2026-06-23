import Testing
import Foundation
@testable import Dory

@MainActor
struct TerminalSessionTests {
    @Test func containerSessionIsRootShell() {
        let store = AppStore()
        let c = Container(id: "c1", name: "web", image: "nginx:latest", status: .running, cpuPercent: 0,
                          memoryDisplay: "0", memoryLimitDisplay: "0", memoryFraction: 0, ports: "", uptime: "",
                          created: "", ipAddress: "", domain: "", command: "", restartPolicy: "")
        let s = store.terminalSession(for: c)
        #expect(s.id == "container:c1")
        #expect(s.containerID == "c1")
        #expect(s.user == "root")
        #expect(s.home == "/root")
        #expect(s.title == "web")
    }

    @Test func machineSessionUsesIdentity() {
        let store = AppStore()
        var m = Machine(name: "ubuntu", distro: "Ubuntu", version: "24.04 LTS", status: .running, cpuPercent: 0,
                        memoryDisplay: "0", ip: "1.2.3.4", letter: "U", badgeHex: 0, containerID: "abc")
        m.username = "augustusotu"; m.loginShell = "/bin/bash"
        let s = store.terminalSession(for: m)
        #expect(s.id == "machine:abc")
        #expect(s.user == "augustusotu")
        #expect(s.shell == "/bin/bash")
        #expect(s.home == "/Users/augustusotu")
        #expect(s.containerID == "abc")
    }

    @Test func rootMachineUsesRootHome() {
        let store = AppStore()
        let m = Machine(name: "legacy", distro: "Ubuntu", version: "24.04", status: .running, cpuPercent: 0,
                        memoryDisplay: "0", ip: "-", letter: "U", badgeHex: 0, containerID: "x")
        #expect(store.terminalSession(for: m).home == "/root")
    }

    @Test func sessionCodableRoundTrips() throws {
        let s = TerminalSession(id: "container:c1", title: "web", subtitle: "nginx", logo: nil,
                                socketPath: "/tmp/x.sock", containerID: "c1", user: "root", shell: "/bin/sh", home: "/root")
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(TerminalSession.self, from: data) == s)
    }
}
