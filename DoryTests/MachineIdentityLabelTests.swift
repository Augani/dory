import Testing
import Foundation
@testable import Dory

struct MachineIdentityLabelTests {
    private let distro = MachineDistro.forImage("ubuntu:24.04")!

    @Test func createBodyEmitsUserShellLabelsAndEnv() {
        let id = MacIdentity(username: "augustusotu", uid: 501, homePath: "/Users/augustusotu", shell: "/bin/bash", publicKeys: [])
        var s = MachineSettings.default
        s.identity = id
        s.env = ["FOO": "bar"]
        let body = MachineService.createBody(name: "m", distro: distro, arch: .arm64, imageTag: "t", keepaliveOnly: false, settings: s)
        let labels = body["Labels"] as! [String: String]
        #expect(labels[MachineService.userLabel] == "augustusotu")
        #expect(labels[MachineService.shellLabel] == "/bin/bash")
        let env = body["Env"] as! [String]
        #expect(env.contains("FOO=bar"))
        #expect(env.contains("container=docker"))
    }

    @Test func machinesDecodeUserShellLabels() {
        let json = """
        [{"Id":"abc","Names":["/dory-machine-m"],"State":"running","Labels":{"dory.machine":"ubuntu","dory.machine.user":"augustusotu","dory.machine.shell":"/bin/bash"}}]
        """.data(using: .utf8)!
        let machines = MachineService.machines(fromContainersJSON: json)
        #expect(machines.first?.username == "augustusotu")
        #expect(machines.first?.loginShell == "/bin/bash")
    }

    @Test func legacyMachineDefaultsToRoot() {
        let json = """
        [{"Id":"abc","Names":["/dory-machine-m"],"State":"running","Labels":{"dory.machine":"ubuntu"}}]
        """.data(using: .utf8)!
        let machines = MachineService.machines(fromContainersJSON: json)
        #expect(machines.first?.username == "root")
        #expect(machines.first?.loginShell == "/bin/sh")
    }
}
