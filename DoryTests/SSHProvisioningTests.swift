import Testing
@testable import Dory

struct SSHProvisioningTests {
    private let id = MacIdentity(username: "augustusotu", uid: 501, homePath: "/Users/augustusotu", shell: "/bin/bash", publicKeys: ["ssh-ed25519 AAAA me"])

    @Test func systemdScriptEnablesSshAndAuthorizedKeysFile() {
        let s = MachineProvisioner.script(identity: id, pkg: .apt, isSystemd: true, includeSSH: true)
        #expect(s.contains("AuthorizedKeysFile /etc/dory/authorized_keys"))
        #expect(s.contains("PasswordAuthentication no"))
        #expect(s.contains("ssh-keygen -A"))
        #expect(s.contains("systemctl enable --now ssh"))
    }

    @Test func alpineScriptLaunchesSshdDirectly() {
        let s = MachineProvisioner.script(identity: id, pkg: .apk, isSystemd: false, includeSSH: true)
        #expect(s.contains("ssh-keygen -A"))
        #expect(s.contains("/usr/sbin/sshd"))
        #expect(!s.contains("systemctl enable"))
    }
}
