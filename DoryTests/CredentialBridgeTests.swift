import Foundation
import Testing
@testable import Dory

struct CredentialBridgeTests {
    @Test func planBuildsStableGuestAndHostSocketPaths() throws {
        let root = URL(fileURLWithPath: "/Users/me/.dory/bridge")
        let plan = try CredentialBridgePlan(machine: "dev", bridgeRoot: root, hostSSHAuthSock: "/private/tmp/agent.sock")

        #expect(plan.credentialDirectory.path == "/Users/me/.dory/bridge/dev/credentials")
        #expect(plan.hostAgentProxySocket.path == "/Users/me/.dory/bridge/dev/credentials/ssh-agent.sock")
        #expect(plan.guestSSHAuthSock == "/opt/dory/bridge/credentials/ssh-agent.sock")
        #expect(plan.guestEnv["SSH_AUTH_SOCK"] == "/opt/dory/bridge/credentials/ssh-agent.sock")
        #expect(plan.guestEnv["GIT_ASKPASS"] == "/usr/local/bin/dory-git-askpass")
    }

    @Test func proxyCommandConnectsHostAgentToBridgeSocket() throws {
        let plan = try CredentialBridgePlan(
            machine: "dev",
            bridgeRoot: URL(fileURLWithPath: "/Users/me/.dory/bridge"),
            hostSSHAuthSock: "/private/tmp/com.apple.launchd/Listeners"
        )

        #expect(plan.sshAgentProxyCommand == [
            "socat",
            "UNIX-LISTEN:/Users/me/.dory/bridge/dev/credentials/ssh-agent.sock,fork,unlink-early,mode=0600",
            "UNIX-CONNECT:/private/tmp/com.apple.launchd/Listeners",
        ])
    }

    @Test func rejectsUnsafeOrRelativeInputs() {
        #expect(throws: CredentialBridgePlan.PlanError.invalidMachineName) {
            try CredentialBridgePlan(machine: "../dev", bridgeRoot: URL(fileURLWithPath: "/tmp"), hostSSHAuthSock: "/tmp/agent.sock")
        }
        #expect(throws: CredentialBridgePlan.PlanError.relativeSSHAuthSock) {
            try CredentialBridgePlan(machine: "dev", bridgeRoot: URL(fileURLWithPath: "/tmp"), hostSSHAuthSock: "agent.sock")
        }
    }

    @Test func missingAgentIsExplicitWhenValidationIsRequested() throws {
        let plan = try CredentialBridgePlan(machine: "dev", bridgeRoot: URL(fileURLWithPath: "/tmp"), hostSSHAuthSock: nil)
        #expect(plan.sshAgentProxyCommand == nil)
        #expect(throws: CredentialBridgePlan.PlanError.missingSSHAuthSock) {
            try plan.validateHostAgent()
        }
    }

    @Test func prepareCreatesCredentialsDirectoryAndRemovesStaleSocketFiles() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dory-cred-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try CredentialBridgePlan(machine: "dev", bridgeRoot: root, hostSSHAuthSock: "/tmp/agent.sock")
        try FileManager.default.createDirectory(at: plan.credentialDirectory, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: plan.hostAgentProxySocket)
        try Data("stale".utf8).write(to: plan.hostGitAskpassSocket)

        try HostCredentialBridge.prepare(plan)

        #expect(FileManager.default.fileExists(atPath: plan.credentialDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: plan.hostAgentProxySocket.path))
        #expect(!FileManager.default.fileExists(atPath: plan.hostGitAskpassSocket.path))
    }
}
