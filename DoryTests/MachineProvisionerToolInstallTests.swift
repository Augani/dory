import Testing
@testable import Dory

struct MachineProvisionerToolInstallTests {
    @Test func aptAddsGitHubRepoAndInstallsGh() {
        let command = MachineProvisioner.ghInstall(pkg: .apt)
        #expect(command.contains("cli.github.com/packages"))
        #expect(command.contains("apt-get install -y gh"))
    }

    @Test func dnfInstallsGh() {
        #expect(MachineProvisioner.ghInstall(pkg: .dnf).contains("dnf install -y gh"))
    }

    @Test func apkInstallsGithubCli() {
        #expect(MachineProvisioner.ghInstall(pkg: .apk).contains("apk add github-cli"))
    }

    @Test func zypperInstallsGh() {
        #expect(MachineProvisioner.ghInstall(pkg: .zypper).contains("zypper -n install gh"))
    }

    @Test func pacmanInstallsGithubCli() {
        #expect(MachineProvisioner.ghInstall(pkg: .pacman).contains("pacman -Sy --noconfirm github-cli"))
    }

    @Test func everyPackageManagerHasNonEmptyGhInstall() {
        for pkg in [MachineDistro.PackageManager.apt, .dnf, .zypper, .apk, .pacman] {
            #expect(!MachineProvisioner.ghInstall(pkg: pkg).isEmpty)
        }
    }

    @Test func scriptSkipsAlreadyPresentTools() {
        let script = MachineProvisioner.toolInstallScript(pkg: .apt, hasNode: false)
        #expect(script.contains("command -v gh >/dev/null 2>&1 ||"))
        #expect(script.contains("command -v claude >/dev/null 2>&1 ||"))
        #expect(script.contains("command -v socat >/dev/null 2>&1 ||"))
    }

    @Test func scriptIsBestEffortAndNeverAborts() {
        let script = MachineProvisioner.toolInstallScript(pkg: .dnf, hasNode: false)
        #expect(!script.contains("set -e"))
        #expect(script.contains("|| true"))
    }

    @Test func claudeUsesOfficialInstallerWithNpmFallbackWhenNode() {
        let withNode = MachineProvisioner.toolInstallScript(pkg: .apt, hasNode: true)
        #expect(withNode.contains("claude.ai/install.sh"))
        #expect(withNode.contains("npm i -g @anthropic-ai/claude-code"))
        let withoutNode = MachineProvisioner.toolInstallScript(pkg: .apt, hasNode: false)
        #expect(withoutNode.contains("claude.ai/install.sh"))
        #expect(!withoutNode.contains("npm i -g @anthropic-ai/claude-code"))
    }

    @Test func socatInstalledViaPackageManager() {
        #expect(MachineProvisioner.toolInstallScript(pkg: .apk, hasNode: false).contains("apk add socat"))
        #expect(MachineProvisioner.toolInstallScript(pkg: .apt, hasNode: false).contains("apt-get install -y socat"))
    }
}
