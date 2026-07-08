import Testing
@testable import Dory

struct NewMachineSettingsTests {
    @Test func collectsResourcesRegardlessOfDisclosure() {
        let s = NewMachineSheet.buildSettings(cpus: 4, memoryGB: 8,
            mounts: [MountPair(host: "/Users/u/p", guest: "/Users/u/p")],
            address: "dev.dory.local")
        #expect(s.cpus == 4)
        #expect(s.memoryMB == 8 * 1024)
        #expect(s.mounts.count == 1)
        #expect(s.address == "dev.dory.local")
        #expect(s.ports.isEmpty)
        #expect(s.env.isEmpty)
    }
}
