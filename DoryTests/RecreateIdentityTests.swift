import Testing
@testable import Dory

struct RecreateIdentityTests {
    @Test func carriesIdentityForNonRootMachine() {
        let s = MachineService.carryIdentity(.default, username: "augustusotu", loginShell: "/bin/bash")
        #expect(s.identity?.username == "augustusotu")
        #expect(s.identity?.shell == "/bin/bash")
        #expect(s.identity?.uid == 501)
    }
    @Test func leavesRootMachineUnchanged() {
        #expect(MachineService.carryIdentity(.default, username: "root", loginShell: "/bin/sh").identity == nil)
    }
    @Test func doesNotOverrideExistingIdentity() {
        var base = MachineSettings.default
        base.identity = MacIdentity(username: "real", uid: 501, homePath: "/Users/real", shell: "/bin/zsh", publicKeys: [])
        let s = MachineService.carryIdentity(base, username: "other", loginShell: "/bin/bash")
        #expect(s.identity?.username == "real")
    }
}
