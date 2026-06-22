import Testing
import Foundation
@testable import Dory

struct MachineDistroTests {
    @Test func catalogHasFourDistros() {
        #expect(MachineDistro.all.count == 4)
        #expect(MachineDistro.all.map(\.id) == ["ubuntu", "debian", "fedora", "alpine"])
    }

    @Test func mapsImageToDistro() {
        #expect(MachineDistro.forImage("ubuntu:24.04")?.display == "Ubuntu")
        #expect(MachineDistro.forImage("alpine:3.20")?.boot == .shell)
        #expect(MachineDistro.forImage("debian:12")?.boot == .systemd)
        #expect(MachineDistro.forImage("nope:1")  == nil)
    }

    @Test func mapsIDToDistro() {
        #expect(MachineDistro.forID("fedora")?.baseImage == "fedora:40")
        #expect(MachineDistro.forID("ubuntu")?.letter == "U")
    }

    @Test func derivesMachineImageTag() {
        #expect(MachineDistro.forImage("ubuntu:24.04")?.machineImageTag == "dory-machine/ubuntu:24.04")
    }
}

struct MachineImageBuilderTests {
    @Test func systemdDockerfileInstallsSystemd() {
        let df = MachineImageBuilder.dockerfile(for: MachineDistro.forID("ubuntu")!)
        #expect(df.contains("FROM ubuntu:24.04"))
        #expect(df.contains("systemd-sysv"))
        #expect(df.contains("STOPSIGNAL SIGRTMIN+3"))
        #expect(df.contains("CMD [\"/sbin/init\"]"))
    }

    @Test func fedoraDockerfileUsesDnf() {
        let df = MachineImageBuilder.dockerfile(for: MachineDistro.forID("fedora")!)
        #expect(df.contains("FROM fedora:40"))
        #expect(df.contains("dnf -y install"))
        #expect(df.contains("CMD [\"/sbin/init\"]"))
    }

    @Test func alpineDockerfileIsShellKeepalive() {
        let df = MachineImageBuilder.dockerfile(for: MachineDistro.forID("alpine")!)
        #expect(df.contains("FROM alpine:3.20"))
        #expect(df.contains("apk add"))
        #expect(df.contains("CMD [\"tail\", \"-f\", \"/dev/null\"]"))
        #expect(!df.contains("/sbin/init"))
    }
}

struct MachineServiceHelperTests {
    @Test func createBodyForSystemdSetsInitAndPrivileged() {
        let body = MachineService.createBody(name: "dev", distro: MachineDistro.forID("ubuntu")!,
                                             imageTag: "dory-machine/ubuntu:24.04", keepaliveOnly: false)
        #expect(body["Image"] as? String == "dory-machine/ubuntu:24.04")
        #expect(body["Hostname"] as? String == "dev")
        #expect(body["Cmd"] as? [String] == ["/sbin/init"])
        #expect(body["StopSignal"] as? String == "SIGRTMIN+3")
        let labels = body["Labels"] as? [String: String]
        #expect(labels?["dory.machine"] == "ubuntu")
        #expect(labels?["dory.machine.version"] == "24.04 LTS")
        let host = body["HostConfig"] as? [String: Any]
        #expect(host?["Privileged"] as? Bool == true)
        #expect(host?["CgroupnsMode"] as? String == "host")
        #expect((host?["Tmpfs"] as? [String: String])?["/run"] == "")
    }

    @Test func createBodyKeepaliveOverridesInit() {
        let body = MachineService.createBody(name: "a", distro: MachineDistro.forID("alpine")!,
                                             imageTag: "dory-machine/alpine:3.20", keepaliveOnly: true)
        #expect(body["Cmd"] as? [String] == ["tail", "-f", "/dev/null"])
    }

    @Test func shellDistroUsesKeepaliveEvenWhenNotForced() {
        let body = MachineService.createBody(name: "a", distro: MachineDistro.forID("alpine")!,
                                             imageTag: "dory-machine/alpine:3.20", keepaliveOnly: false)
        #expect(body["Cmd"] as? [String] == ["tail", "-f", "/dev/null"])
    }

    @Test func stripsContainerNamePrefix() {
        #expect(MachineService.displayName(fromContainerName: "/dory-machine-dev") == "dev")
        #expect(MachineService.displayName(fromContainerName: "dory-machine-dev") == "dev")
        #expect(MachineService.displayName(fromContainerName: "/some-other") == nil)
    }

    @Test func mapsContainersJSONToMachines() {
        let json = """
        [{"Id":"abc123","Names":["/dory-machine-dev"],"Image":"dory-machine/ubuntu:24.04",
          "State":"running","Labels":{"dory.machine":"ubuntu","dory.machine.version":"24.04 LTS"},
          "NetworkSettings":{"Networks":{"bridge":{"IPAddress":"172.17.0.5"}}}},
         {"Id":"def","Names":["/not-a-machine"],"Image":"redis","State":"running","Labels":{}}]
        """.data(using: .utf8)!
        let machines = MachineService.machines(fromContainersJSON: json)
        #expect(machines.count == 1)
        #expect(machines[0].name == "dev")
        #expect(machines[0].containerID == "abc123")
        #expect(machines[0].distro == "Ubuntu")
        #expect(machines[0].status == .running)
        #expect(machines[0].ip == "172.17.0.5")
        #expect(machines[0].letter == "U")
    }
}
