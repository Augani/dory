import Testing
import Foundation
@testable import Dory

struct MachineIdentityLabelTests {
    private let distro = MachineDistro.forImage("ubuntu:24.04")!

    @Test func createBodyEmitsUserShellLabelsAndEnv() {
        let id = MacIdentity(username: "augustusotu", uid: 777, homePath: "/Volumes/DevHome/augustusotu", shell: "/bin/bash", publicKeys: [])
        var s = MachineSettings.default
        s.identity = id
        s.env = ["FOO": "bar"]
        let body = MachineService.createBody(name: "m", distro: distro, arch: .arm64, imageTag: "t", keepaliveOnly: false, settings: s)
        let labels = body["Labels"] as! [String: String]
        #expect(labels[MachineService.userLabel] == "augustusotu")
        #expect(labels[MachineService.uidLabel] == "777")
        #expect(labels[MachineService.homeLabel] == "/Volumes/DevHome/augustusotu")
        #expect(labels[MachineService.shellLabel] == "/bin/bash")
        let env = body["Env"] as! [String]
        #expect(env.contains("FOO=bar"))
        #expect(env.contains("container=docker"))
    }

    @Test func machinesDecodeUserShellLabels() {
        let json = """
        [{"Id":"abc","Names":["/dory-machine-m"],"State":"running","Labels":{"dory.machine":"ubuntu","dory.machine.user":"augustusotu","dory.machine.uid":"777","dory.machine.home":"/Volumes/DevHome/augustusotu","dory.machine.shell":"/bin/bash"}}]
        """.data(using: .utf8)!
        let machines = MachineService.machines(fromContainersJSON: json)
        #expect(machines.first?.username == "augustusotu")
        #expect(machines.first?.uid == 777)
        #expect(machines.first?.homePath == "/Volumes/DevHome/augustusotu")
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
