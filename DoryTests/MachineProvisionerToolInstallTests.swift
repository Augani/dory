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
}
