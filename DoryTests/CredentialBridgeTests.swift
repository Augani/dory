import Testing
@testable import Dory

struct CredentialBridgeTests {
    @Test func usesFixedGuestLocalSSHAgentSocket() {
        #expect(DoryCredentialShim.guestSSHAuthSockPath == "/run/host-services/ssh-auth.sock")
        #expect(DoryCredentialShim.guestSSHAuthSockPath.hasPrefix("/run/"))
    }

    @Test func guestProfileExportsFixedAgentSocket() {
        let commands = DoryCredentialShim.installCommands().joined(separator: "\n")
        #expect(commands.contains("export SSH_AUTH_SOCK=/run/host-services/ssh-auth.sock"))
        #expect(!commands.contains("ssh-agent.sock"))
        #expect(!commands.contains("UNIX-LISTEN:"))
    }

    @Test func credentialProfileKeepsAskpassContract() {
        let commands = DoryCredentialShim.installCommands().joined(separator: "\n")
        #expect(commands.contains("export GIT_ASKPASS=/usr/local/bin/dory-git-askpass"))
        #expect(commands.contains("DORY_GIT_ASKPASS_SOCK=/opt/dory/bridge/credentials/git-askpass.sock"))
    }
}
