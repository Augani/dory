import Foundation

struct MachineDistro: Sendable, Identifiable, Hashable {
    enum Boot: String, Sendable { case systemd, shell }
    enum PackageManager: String, Sendable { case apt, dnf, zypper, apk, pacman }

    let family: String
    let display: String
    let version: String
    let baseImage: String
    let boot: Boot
    let pkg: PackageManager
    let letter: String
    let badgeHex: UInt32
    let logo: String
    let arches: [MachineArch]

    var id: String { baseImage }

    func machineImageTag(for arch: MachineArch) -> String { "dory-machine/\(baseImage)-\(arch.rawValue)-v2" }

    func defaultArch() -> MachineArch { arches.contains(.host) ? .host : arches[0] }

    static var all: [MachineDistro] { MachineCatalog.all }
    static var families: [MachineFamily] { MachineCatalog.families }
    static func forImage(_ image: String) -> MachineDistro? { all.first { $0.baseImage == image } }
    static func forFamily(_ family: String) -> MachineDistro? { all.first { $0.family == family } }

    static let logoFamilies: Set<String> = [
        "ubuntu", "debian", "fedora", "alpine", "rocky", "alma",
        "opensuse", "oracle", "amazon", "kali", "centos", "arch",
    ]

    static func logoAsset(family: String) -> String? {
        logoFamilies.contains(family) ? "logo-\(family)" : nil
    }
}

struct MachineFamily: Identifiable, Hashable, Sendable {
    let id: String
    let display: String
    let logo: String
    let letter: String
    let badgeHex: UInt32
    let arches: [MachineArch]
    let versions: [MachineDistro]
    var defaultVersion: MachineDistro { versions[0] }
}

enum MachineCatalog {
    static let families: [MachineFamily] = [
        make("ubuntu", "Ubuntu", "logo-ubuntu", "U", 0xE95420, .apt, .systemd,
             [("24.04 LTS", "ubuntu:24.04"), ("22.04 LTS", "ubuntu:22.04"), ("20.04 LTS", "ubuntu:20.04")]),
        make("debian", "Debian", "logo-debian", "D", 0xA80030, .apt, .systemd,
             [("12", "debian:12"), ("11", "debian:11")]),
        make("fedora", "Fedora", "logo-fedora", "F", 0x51A2DA, .dnf, .systemd,
             [("41", "fedora:41"), ("40", "fedora:40")]),
        make("rocky", "Rocky Linux", "logo-rocky", "R", 0x10B981, .dnf, .systemd,
             [("9", "rockylinux:9"), ("8", "rockylinux:8")]),
        make("alma", "AlmaLinux", "logo-alma", "L", 0x0078D4, .dnf, .systemd,
             [("9", "almalinux:9"), ("8", "almalinux:8")]),
        make("opensuse", "openSUSE", "logo-opensuse", "S", 0x73BA25, .zypper, .systemd,
             [("Leap 15.6", "opensuse/leap:15.6"), ("Tumbleweed", "opensuse/tumbleweed")]),
        make("oracle", "Oracle Linux", "logo-oracle", "O", 0xC74634, .dnf, .systemd,
             [("9", "oraclelinux:9"), ("8", "oraclelinux:8")]),
        make("amazon", "Amazon Linux", "logo-amazon", "Z", 0xFF9900, .dnf, .systemd,
             [("2023", "amazonlinux:2023")]),
        make("arch", "Arch Linux", "logo-arch", "A", 0x1793D1, .pacman, .systemd,
             [("Rolling", "archlinux:latest")], arches: [.amd64]),
        make("kali", "Kali Linux", "logo-kali", "K", 0x367BF0, .apt, .systemd,
             [("Rolling", "kalilinux/kali-rolling")]),
        make("centos", "CentOS Stream", "logo-centos", "C", 0x9B59B6, .dnf, .systemd,
             [("9", "quay.io/centos/centos:stream9")]),
        make("alpine", "Alpine", "logo-alpine", "A", 0x0D597F, .apk, .shell,
             [("3.21", "alpine:3.21"), ("3.20", "alpine:3.20"), ("3.19", "alpine:3.19")]),
    ]

    static let all: [MachineDistro] = families.flatMap(\.versions)

    private static func make(_ id: String, _ display: String, _ logo: String, _ letter: String,
                             _ hex: UInt32, _ pkg: MachineDistro.PackageManager, _ boot: MachineDistro.Boot,
                             _ versions: [(String, String)],
                             arches: [MachineArch] = [.arm64, .amd64]) -> MachineFamily {
        let distros = versions.map {
            MachineDistro(family: id, display: display, version: $0.0, baseImage: $0.1,
                          boot: boot, pkg: pkg, letter: letter, badgeHex: hex, logo: logo, arches: arches)
        }
        return MachineFamily(id: id, display: display, logo: logo, letter: letter, badgeHex: hex, arches: arches, versions: distros)
    }
}
