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

    @Test func bootCommandsMountBinfmtAndRegisterIdempotently() {
        let script = BinfmtRegistration.bootCommands().joined(separator: "\n")

        #expect(script.contains("mount -t binfmt_misc"))
        #expect(script.contains("[ ! -e /proc/sys/fs/binfmt_misc/qemu-x86_64 ]"))
        #expect(script.contains("printf '%b'"))
        #expect(script.contains("/proc/sys/fs/binfmt_misc/register"))
    }

    @Test func dockerFallbackInstallsAmd64ThroughPrivilegedBinfmtImage() {
        let command = BinfmtRegistration.dockerFallbackCommand()

        #expect(command.contains("docker info"))
        #expect(command.contains("docker run --privileged --rm tonistiigi/binfmt --install amd64"))
        #expect(command.contains("/var/log/dory-binfmt.log"))
    }
}
