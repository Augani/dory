import Foundation

enum MachineProvisioner {
    static func script(identity: MacIdentity, pkg: MachineDistro.PackageManager, isSystemd: Bool, includeSSH: Bool) -> String {
        let user = shellQuote(identity.username)
        let home = shellQuote(identity.homePath)
        let shellPath = identity.shell
        let keys = identity.publicKeys.joined(separator: "\n")
        var lines: [String] = ["set -e"]
        if let install = shellInstall(shellPath, pkg: pkg) { lines.append(install) }
        lines.append("SH=\(shellQuote(shellPath)); command -v \"$SH\" >/dev/null 2>&1 || SH=/bin/bash; command -v \"$SH\" >/dev/null 2>&1 || SH=/bin/sh")
        lines.append("id -u \(user) >/dev/null 2>&1 || useradd -u \(identity.uid) -M -d \(home) -s \"$SH\" \(user)")
        lines.append("usermod -d \(home) -s \"$SH\" \(user) 2>/dev/null || true")
        let slug = identity.username.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" }
        lines.append("printf '%s ALL=(ALL) NOPASSWD:ALL\\n' \(user) > /etc/sudoers.d/dory-\(slug); chmod 440 /etc/sudoers.d/dory-\(slug)")
        lines.append("install -d -m755 /etc/dory")
        lines.append("printf '%s\\n' \(shellQuote(keys)) > /etc/dory/authorized_keys; chmod 644 /etc/dory/authorized_keys")
        if includeSSH {
            lines.append("mkdir -p /etc/ssh")
            lines.append("grep -q '^AuthorizedKeysFile /etc/dory/authorized_keys' /etc/ssh/sshd_config 2>/dev/null || printf '\\nAuthorizedKeysFile /etc/dory/authorized_keys\\nPasswordAuthentication no\\n' >> /etc/ssh/sshd_config")
            lines.append("ssh-keygen -A")
            if isSystemd {
                lines.append("systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd 2>/dev/null || /usr/sbin/sshd")
            } else {
                lines.append("/usr/sbin/sshd")
            }
        }
        let shim = (["set +e"] + DoryOpenShim.installCommands()).joined(separator: "\n")
        lines.append("(\n\(shim)\n) || true")
        return lines.joined(separator: "\n")
    }

    private static func shellInstall(_ shell: String, pkg: MachineDistro.PackageManager) -> String? {
        let name = (shell as NSString).lastPathComponent
        guard name != "bash", name != "sh" else { return nil }
        switch pkg {
        case .apt: return "apt-get update -qq && apt-get install -y \(name)"
        case .dnf: return "dnf install -y \(name)"
        case .zypper: return "zypper -n install \(name)"
        case .apk: return "apk add \(name)"
        case .pacman: return "pacman -Sy --noconfirm \(name)"
        }
    }

    static func ghInstall(pkg: MachineDistro.PackageManager) -> String {
        switch pkg {
        case .apt:
            return [
                "apt-get update -qq",
                "apt-get install -y curl ca-certificates",
                "install -d -m 0755 /etc/apt/keyrings",
                "curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg",
                "chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg",
                "printf 'deb [arch=%s signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\\n' \"$(dpkg --print-architecture)\" > /etc/apt/sources.list.d/github-cli.list",
                "apt-get update -qq",
                "apt-get install -y gh",
            ].joined(separator: " && ")
        case .dnf:
            return "dnf install -y 'dnf-command(config-manager)' && dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo && dnf install -y gh"
        case .zypper:
            return "zypper -n install gh || (zypper -n addrepo https://cli.github.com/packages/rpm/gh-cli.repo && zypper -n --gpg-auto-import-keys install gh)"
        case .apk:
            return "\(apkEnableCommunityAndUpdate) && apk add github-cli"
        case .pacman:
            return "pacman -Sy --noconfirm github-cli"
        }
    }

    static func toolInstallScript(pkg: MachineDistro.PackageManager, hasNode: Bool) -> String {
        var lines: [String] = []
        lines.append("(command -v gh >/dev/null 2>&1 || (\(ghInstall(pkg: pkg)))) || true")
        lines.append("(command -v claude >/dev/null 2>&1 || (\(claudeInstall(hasNode: hasNode)))) || true")
        lines.append("(command -v socat >/dev/null 2>&1 || (\(socatInstall(pkg: pkg)))) || true")
        return lines.joined(separator: "\n")
    }

    private static func claudeInstall(hasNode: Bool) -> String {
        let official = "curl -fsSL https://claude.ai/install.sh | sh"
        guard hasNode else { return official }
        return "\(official) || npm i -g @anthropic-ai/claude-code"
    }

    private static func socatInstall(pkg: MachineDistro.PackageManager) -> String {
        switch pkg {
        case .apt: return "apt-get update -qq && apt-get install -y socat"
        case .dnf: return "dnf install -y socat"
        case .zypper: return "zypper -n install socat"
        case .apk: return "\(apkEnableCommunityAndUpdate) && apk add socat"
        case .pacman: return "pacman -Sy --noconfirm socat"
        }
    }

    private static let apkEnableCommunityAndUpdate =
        "sed -i 's|^#\\(.*community\\)|\\1|' /etc/apk/repositories 2>/dev/null || true; apk update"

    private static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
