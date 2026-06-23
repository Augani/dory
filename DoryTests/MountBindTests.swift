import Testing
@testable import Dory

struct MountBindTests {
    @Test func readWriteBindString() {
        #expect(MachineService.bindString(MountPair(host: "/Users/u", guest: "/Users/u")) == "/Users/u:/Users/u")
    }

    @Test func readOnlyBindString() {
        #expect(MachineService.bindString(MountPair(host: "/a", guest: "/b", readOnly: true)) == "/a:/b:ro")
    }

    @Test func parsesReadWrite() {
        #expect(MachineService.parseBind("/Users/u:/Users/u") == MountPair(host: "/Users/u", guest: "/Users/u"))
    }

    @Test func parsesReadOnly() {
        #expect(MachineService.parseBind("/a:/b:ro") == MountPair(host: "/a", guest: "/b", readOnly: true))
    }

    @Test func roundTrip() {
        let m = MountPair(host: "/x/y", guest: "/z", readOnly: true)
        #expect(MachineService.parseBind(MachineService.bindString(m)) == m)
    }
}
