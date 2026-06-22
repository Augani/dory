import Foundation

struct MachineDistro: Sendable, Identifiable, Hashable {
    enum Boot: String, Sendable {
        case systemd
        case shell
    }

    let id: String
    let display: String
    let version: String
    let baseImage: String
    let boot: Boot
    let letter: String
    let badgeHex: UInt32
    let logo: String

    var machineImageTag: String { "dory-machine/\(baseImage)" }

    static let all: [MachineDistro] = [
        MachineDistro(id: "ubuntu", display: "Ubuntu", version: "24.04 LTS", baseImage: "ubuntu:24.04",
                      boot: .systemd, letter: "U", badgeHex: 0xE95420, logo: "logo-ubuntu"),
        MachineDistro(id: "debian", display: "Debian", version: "12", baseImage: "debian:12",
                      boot: .systemd, letter: "D", badgeHex: 0xA80030, logo: "logo-debian"),
        MachineDistro(id: "fedora", display: "Fedora", version: "40", baseImage: "fedora:40",
                      boot: .systemd, letter: "F", badgeHex: 0x51A2DA, logo: "logo-fedora"),
        MachineDistro(id: "alpine", display: "Alpine", version: "3.20", baseImage: "alpine:3.20",
                      boot: .shell, letter: "A", badgeHex: 0x0D597F, logo: "logo-alpine"),
    ]

    static func forImage(_ image: String) -> MachineDistro? {
        all.first { $0.baseImage == image }
    }

    static func forID(_ id: String) -> MachineDistro? {
        all.first { $0.id == id }
    }
}
