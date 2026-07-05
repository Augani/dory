import Foundation
import Testing
@testable import Dory

struct SSHConfigWriterTests {
    @Test func forwardedPortHostBlockUsesLocalhostPort() {
        let machine = Machine(
            name: "rusty",
            distro: "Ubuntu",
            version: "24.04 LTS",
            status: .running,
            cpuPercent: 0,
            memoryDisplay: "",
            ip: "172.17.0.2",
            letter: "U",
            badgeHex: 0,
            username: "augustus",
            loginShell: "/bin/bash",
            sshPort: 32022
        )

        let block = SSHConfigWriter.hostBlock(for: machine)
        #expect(block.contains("Host rusty"))
        #expect(block.contains("  HostName 127.0.0.1"))
        #expect(block.contains("  User augustus"))
        #expect(block.contains("  Port 32022"))
        #expect(!block.contains("ProxyCommand"))
    }

    @Test func missingForwardedPortUsesDockerExecProxyCommand() {
        let machine = Machine(
            name: "Dev Box",
            distro: "Ubuntu",
            version: "24.04 LTS",
            status: .running,
            cpuPercent: 0,
            memoryDisplay: "",
            ip: "172.17.0.2",
            letter: "U",
            badgeHex: 0,
            username: "dev",
            loginShell: "/bin/zsh"
        )

        let block = SSHConfigWriter.hostBlock(for: machine)
        #expect(block.contains("Host dev-box"))
        #expect(block.contains("  User dev"))
        #expect(block.contains("ProxyCommand docker -H unix://$HOME/.dory/dory.sock exec -i 'dory-machine-Dev Box' sh -lc 'exec nc 127.0.0.1 22'"))
    }

    @Test func writeCreatesParentDirectoryAndSortedConfig() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dory-ssh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = SSHConfigWriter(configURL: root.appendingPathComponent("ssh/config"))
        let zed = Machine(name: "zed", distro: "Ubuntu", version: "", status: .running, cpuPercent: 0, memoryDisplay: "", ip: "", letter: "U", badgeHex: 0, sshPort: 2202)
        let alpha = Machine(name: "alpha", distro: "Ubuntu", version: "", status: .running, cpuPercent: 0, memoryDisplay: "", ip: "", letter: "U", badgeHex: 0, sshPort: 2201)

        try writer.write(machines: [zed, alpha])
        let text = try String(contentsOf: root.appendingPathComponent("ssh/config"), encoding: .utf8)

        #expect(text.range(of: "Host alpha")!.lowerBound < text.range(of: "Host zed")!.lowerBound)
        #expect(SSHConfigWriter.includeInstruction == "Include ~/.dory/ssh/config")
    }
}
