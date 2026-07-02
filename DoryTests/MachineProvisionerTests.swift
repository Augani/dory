import Testing
@testable import Dory

struct MachineProvisionerTests {
    private func id(_ shell: String = "/bin/bash", keys: [String] = ["ssh-ed25519 AAAA me"]) -> MacIdentity {
        MacIdentity(username: "augustusotu", uid: 501, homePath: "/Users/augustusotu", shell: shell, publicKeys: keys)
    }

    @Test func createsUserWithUid501AndMirroredHome() {
        let s = MachineProvisioner.script(identity: id(), pkg: .apt, isSystemd: true, includeSSH: false)
        #expect(s.contains("useradd -u 501 -M -d '/Users/augustusotu' -s \"$SH\" 'augustusotu'"))
        #expect(s.contains("/etc/sudoers.d/dory-augustusotu"))
        #expect(s.contains("NOPASSWD:ALL"))
    }

    @Test func seedsAuthorizedKeysFileNotHome() {
        let s = MachineProvisioner.script(identity: id(), pkg: .apt, isSystemd: true, includeSSH: false)
        #expect(s.contains("/etc/dory/authorized_keys"))
        #expect(s.contains("ssh-ed25519 AAAA me"))
        #expect(!s.contains("/Users/augustusotu/.ssh/authorized_keys"))
    }

    @Test func installsNonBashShellViaPkg() {
        #expect(MachineProvisioner.script(identity: id("/bin/zsh"), pkg: .apt, isSystemd: true, includeSSH: false).contains("apt-get install -y zsh"))
        #expect(MachineProvisioner.script(identity: id("/usr/bin/fish"), pkg: .dnf, isSystemd: true, includeSSH: false).contains("dnf install -y fish"))
        #expect(MachineProvisioner.script(identity: id("/usr/bin/zsh"), pkg: .pacman, isSystemd: true, includeSSH: false).contains("pacman -Sy --noconfirm zsh"))
    }

    @Test func bashShellSkipsInstall() {
        #expect(!MachineProvisioner.script(identity: id("/bin/bash"), pkg: .apt, isSystemd: true, includeSSH: false).contains("install -y bash"))
    }

    @Test func sshOmittedWhenIncludeSSHFalse() {
        let s = MachineProvisioner.script(identity: id(), pkg: .apt, isSystemd: true, includeSSH: false)
        #expect(!s.contains("ssh-keygen -A"))
        #expect(!s.contains("AuthorizedKeysFile"))
    }

    @Test func sanitizesSudoersFilenameSlug() {
        let identity = MacIdentity(username: "a b", uid: 501, homePath: "/Users/ab", shell: "/bin/bash", publicKeys: [])
        let script = MachineProvisioner.script(identity: identity, pkg: .apt, isSystemd: true, includeSSH: false)
        #expect(script.contains("/etc/sudoers.d/dory-ab"))
    }

    @Test func installsDoryOpenShim() {
        let s = MachineProvisioner.script(identity: id(), pkg: .apt, isSystemd: true, includeSSH: false)
        #expect(s.contains("/usr/local/bin/dory-open"))
        #expect(s.contains("ln -sf /usr/local/bin/dory-open /usr/local/bin/xdg-open"))
        #expect(s.contains("/usr/local/bin/gio"))
    }

    @Test func ensuresSocatInstalled() {
        let s = MachineProvisioner.script(identity: id(), pkg: .apt, isSystemd: true, includeSSH: false)
        #expect(s.contains("socat"))
    }
}
