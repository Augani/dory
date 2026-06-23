import Testing
@testable import Dory

struct MachineCreateIdentityTests {
    private let id = MacIdentity(username: "augustusotu", uid: 501, homePath: "/Users/augustusotu", shell: "/bin/bash", publicKeys: [])

    @Test func injectsIdentityAndHomeBind() {
        let s = AppStore.withIdentity(.default, id)
        #expect(s.identity == id)
        #expect(s.mounts.contains(MountPair(host: "/Users/augustusotu", guest: "/Users/augustusotu")))
    }

    @Test func doesNotDuplicateExistingHomeBind() {
        var base = MachineSettings.default
        base.mounts = [MountPair(host: "/Users/augustusotu", guest: "/Users/augustusotu")]
        let s = AppStore.withIdentity(base, id)
        #expect(s.mounts.filter { $0.guest == "/Users/augustusotu" }.count == 1)
    }
}
