import Testing
@testable import DoryHV

struct BinfmtRegistrationTests {
    @Test func qemuX8664RegistrationUsesFixBinaryFlagAndStaticInterpreter() {
        let line = BinfmtRegistration.qemuX8664RegisterLine

        #expect(line.hasPrefix(":qemu-x86_64:M::"))
        #expect(line.contains(#"\x7fELF\x02\x01\x01"#))
        #expect(line.contains(#"\x02\x00\x3e\x00"#))
        #expect(line.contains(":/usr/bin/qemu-x86_64-static:F"))
    }

    @Test func qemuAarch64RegistrationUsesArm64ElfMachineAndStaticInterpreter() {
        let line = BinfmtRegistration.registerLine(for: .arm64)

        #expect(line.hasPrefix(":qemu-aarch64:M::"))
        #expect(line.contains(#"\x7fELF\x02\x01\x01"#))
        #expect(line.contains(#"\x02\x00\xb7\x00"#))
        #expect(line.contains(":/usr/bin/qemu-aarch64-static:F"))
    }

    @Test func bootCommandsMountBinfmtAndRegisterRequestedArchitectureIdempotently() {
        let amd64Script = BinfmtRegistration.bootCommands(for: .amd64).joined(separator: "\n")
        let arm64Script = BinfmtRegistration.bootCommands(for: .arm64).joined(separator: "\n")

        #expect(amd64Script.contains("mount -t binfmt_misc"))
        #expect(amd64Script.contains("[ ! -e /proc/sys/fs/binfmt_misc/qemu-x86_64 ]"))
        #expect(amd64Script.contains("/usr/bin/qemu-x86_64-static"))
        #expect(amd64Script.contains("printf '%b'"))
        #expect(amd64Script.contains("/proc/sys/fs/binfmt_misc/register"))

        #expect(arm64Script.contains("[ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]"))
        #expect(arm64Script.contains("/usr/bin/qemu-aarch64-static"))
    }

    @Test func dockerFallbackInstallsRequestedArchitectureThroughPrivilegedBinfmtImage() {
        let amd64Command = BinfmtRegistration.dockerFallbackCommand(for: .amd64)
        let arm64Command = BinfmtRegistration.dockerFallbackCommand(for: .arm64)

        #expect(amd64Command.contains("docker info"))
        #expect(amd64Command.contains("docker run --privileged --rm tonistiigi/binfmt --install amd64"))
        #expect(amd64Command.contains("/var/log/dory-binfmt.log"))

        #expect(arm64Command.contains("docker run --privileged --rm tonistiigi/binfmt --install arm64"))
        #expect(arm64Command.contains("[ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]"))
    }

    @Test func defaultRegistrationTargetsNonNativeHostArchitecture() {
        #if arch(arm64)
        #expect(BinfmtRegistration.hostNativeArchitecture == .arm64)
        #expect(BinfmtRegistration.nonNativeHostArchitecture == .amd64)
        #else
        #expect(BinfmtRegistration.hostNativeArchitecture == .amd64)
        #expect(BinfmtRegistration.nonNativeHostArchitecture == .arm64)
        #endif
    }
}
