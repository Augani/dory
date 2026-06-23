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

    private static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
