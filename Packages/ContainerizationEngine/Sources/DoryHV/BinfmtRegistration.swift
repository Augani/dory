import Foundation

public enum BinfmtRegistration {
    public enum Architecture: String, Sendable {
        case arm64
        case amd64

        var handlerName: String {
            switch self {
            case .arm64: "qemu-aarch64"
            case .amd64: "qemu-x86_64"
            }
        }

        var interpreterPath: String {
            "/usr/bin/\(handlerName)-static"
        }

        var elfMachine: String {
            switch self {
            case .arm64: #"\xb7\x00"#
            case .amd64: #"\x3e\x00"#
            }
        }
    }

    public static let qemuX8664Path = "/usr/bin/qemu-x86_64-static"

    private static let elf64ExecutablePrefix = #"\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00"#
    private static let elf64ExecutableMask = #"\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff"#

    public static var hostNativeArchitecture: Architecture {
        #if arch(arm64)
        .arm64
        #else
        .amd64
        #endif
    }

    public static var nonNativeHostArchitecture: Architecture {
        hostNativeArchitecture == .arm64 ? .amd64 : .arm64
    }

    public static var qemuX8664RegisterLine: String {
        registerLine(for: .amd64)
    }

    public static func registerLine(for architecture: Architecture) -> String {
        ":\(architecture.handlerName):M::\(elf64ExecutablePrefix)\(architecture.elfMachine):\(elf64ExecutableMask):\(architecture.interpreterPath):F"
    }

    public static func bootCommands(for architecture: Architecture = nonNativeHostArchitecture) -> [String] {
        let registerLine = registerLine(for: architecture)
        return [
            "mkdir -p /proc/sys/fs/binfmt_misc",
            "mountpoint -q /proc/sys/fs/binfmt_misc || mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true",
            "if [ -x \(architecture.interpreterPath) ] && [ -w /proc/sys/fs/binfmt_misc/register ] && [ ! -e /proc/sys/fs/binfmt_misc/\(architecture.handlerName) ]; then printf '%b' '\(registerLine)' > /proc/sys/fs/binfmt_misc/register || true; fi",
        ]
    }

    public static func dockerFallbackCommand(
        for architecture: Architecture = nonNativeHostArchitecture,
        image: String = "tonistiigi/binfmt"
    ) -> String {
        "( [ ! -e /proc/sys/fs/binfmt_misc/\(architecture.handlerName) ] && command -v docker >/dev/null 2>&1 && for i in $(seq 1 30); do docker info >/dev/null 2>&1 && docker run --privileged --rm \(image) --install \(architecture.rawValue) >/var/log/dory-binfmt.log 2>&1 && break; sleep 1; done ) & true"
    }
}
