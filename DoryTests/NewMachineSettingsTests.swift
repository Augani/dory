import Testing
@testable import Dory

struct NewMachineSettingsTests {
    @Test func collectsResourcesRegardlessOfDisclosure() {
        let s = NewMachineSheet.buildSettings(cpus: 4, memoryGB: 8,
            mounts: [MountPair(host: "/Users/u/p", guest: "/Users/u/p")],
            ports: [PortPair(host: 8080, guest: 80)], env: ["K": "V"])
        #expect(s.cpus == 4)
        #expect(s.memoryMB == 8 * 1024)
        #expect(s.mounts.count == 1)
        #expect(s.ports == [PortPair(host: 8080, guest: 80)])
        #expect(s.env == ["K": "V"])
    }
}
