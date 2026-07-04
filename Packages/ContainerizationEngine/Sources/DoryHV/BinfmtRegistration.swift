import Foundation

public enum BinfmtRegistration {
    public static let qemuX8664Path = "/usr/bin/qemu-x86_64-static"

    private static let x8664Magic = #"\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00"#
    private static let x8664Mask = #"\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff"#

    public static var qemuX8664RegisterLine: String {
        ":qemu-x86_64:M::\(x8664Magic):\(x8664Mask):\(qemuX8664Path):F"
    }

    public static func bootCommands() -> [String] {
        [
            "mkdir -p /proc/sys/fs/binfmt_misc",
            "mountpoint -q /proc/sys/fs/binfmt_misc || mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true",
            "if [ -x \(qemuX8664Path) ] && [ -w /proc/sys/fs/binfmt_misc/register ] && [ ! -e /proc/sys/fs/binfmt_misc/qemu-x86_64 ]; then printf '%b' '\(qemuX8664RegisterLine)' > /proc/sys/fs/binfmt_misc/register || true; fi",
        ]
    }

    public static func dockerFallbackCommand(image: String = "tonistiigi/binfmt") -> String {
        "( [ ! -e /proc/sys/fs/binfmt_misc/qemu-x86_64 ] && command -v docker >/dev/null 2>&1 && for i in $(seq 1 30); do docker info >/dev/null 2>&1 && docker run --privileged --rm \(image) --install amd64 >/var/log/dory-binfmt.log 2>&1 && break; sleep 1; done ) & true"
    }
}
