import Darwin
import Testing
@testable import Dory

struct NewMachineSettingsTests {
    @Test func collectsResourcesRegardlessOfDisclosure() {
        let s = NewMachineSheet.buildSettings(cpus: 4, memoryGB: 8,
            mounts: [MountPair(host: "/Users/u/p", guest: "/Users/u/p")],
            address: "192.168.215.40")
        #expect(s.cpus == 4)
        #expect(s.memoryMB == 8 * 1024)
        #expect(s.mounts.count == 1)
        #expect(s.address == "192.168.215.40")
        #expect(s.displayMode == .desktop)
        #expect(s.env["DORY_GUEST_USER"] == "dory")
        #expect(s.env["DORY_GUEST_UID"] == String(getuid()))
        #expect(s.ports.isEmpty)
    }
}
