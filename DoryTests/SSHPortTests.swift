import Testing
import Foundation
@testable import Dory

struct SSHPortTests {
    @Test func allocatesUsablePort() {
        let p = AppStore.allocateFreePort()
        #expect(p > 1024 && p <= 65535)
    }

    @Test func createBodyEmitsSshPortLabelWhenPort22Published() {
        let distro = MachineDistro.forImage("ubuntu:24.04")!
        var s = MachineSettings.default
        s.identity = MacIdentity(username: "u", uid: 501, homePath: "/Users/u", shell: "/bin/bash", publicKeys: [])
        s.ports = [PortPair(host: 32005, guest: 22)]
        let body = MachineService.createBody(name: "m", distro: distro, arch: .arm64, imageTag: "t", keepaliveOnly: false, settings: s)
        let labels = body["Labels"] as! [String: String]
        #expect(labels[MachineService.sshPortLabel] == "32005")
    }

    @Test func machinesDecodeSshPort() {
        let json = """
        [{"Id":"a","Names":["/dory-machine-m"],"State":"running","Labels":{"dory.machine":"ubuntu","dory.machine.sshPort":"32005"}}]
        """.data(using: .utf8)!
        #expect(MachineService.machines(fromContainersJSON: json).first?.sshPort == 32005)
    }

    @Test func legacyMachineHasNilSshPort() {
        let json = """
        [{"Id":"a","Names":["/dory-machine-m"],"State":"running","Labels":{"dory.machine":"ubuntu"}}]
        """.data(using: .utf8)!
        #expect(MachineService.machines(fromContainersJSON: json).first?.sshPort == nil)
    }
}
