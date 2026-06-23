import Testing
import Foundation
@testable import Dory

struct MachineDistroTests {
    @Test func catalogHasManyFamilies() {
        let ids = MachineDistro.families.map(\.id)
        #expect(ids.contains("ubuntu"))
        #expect(ids.contains("rocky"))
        #expect(ids.contains("opensuse"))
        #expect(ids.contains("alpine"))
        #expect(MachineDistro.families.count >= 10)
    }

    @Test func eachFamilyHasVersions() {
        for family in MachineDistro.families {
            #expect(!family.versions.isEmpty)
            #expect(family.defaultVersion.baseImage == family.versions[0].baseImage)
        }
    }

    @Test func mapsImageToDistro() {
        #expect(MachineDistro.forImage("ubuntu:22.04")?.family == "ubuntu")
        #expect(MachineDistro.forImage("ubuntu:22.04")?.version == "22.04 LTS")
        #expect(MachineDistro.forImage("alpine:3.20")?.boot == .shell)
        #expect(MachineDistro.forImage("rockylinux:9")?.pkg == .dnf)
        #expect(MachineDistro.forImage("opensuse/leap:15.6")?.pkg == .zypper)
        #expect(MachineDistro.forImage("nope:1") == nil)
    }

    @Test func mapsFamilyToMetadata() {
        #expect(MachineDistro.forFamily("ubuntu")?.letter == "U")
        #expect(MachineDistro.forFamily("rocky")?.display == "Rocky Linux")
    }

    @Test func derivesMachineImageTag() {
        #expect(MachineDistro.forImage("ubuntu:24.04")?.machineImageTag(for: .arm64) == "dory-machine/ubuntu:24.04-arm64-v2")
        #expect(MachineDistro.forImage("ubuntu:24.04")?.machineImageTag(for: .amd64) == "dory-machine/ubuntu:24.04-amd64-v2")
    }

    @Test func archCatalogRules() {
        #expect(MachineDistro.forFamily("arch")?.arches == [.amd64])
        #expect(MachineDistro.forFamily("arch")?.pkg == .pacman)
        #expect(MachineDistro.forImage("archlinux:latest")?.defaultArch() == .amd64)
        #expect(MachineDistro.forFamily("ubuntu")?.arches.contains(.arm64) == true)
        #expect(MachineDistro.forFamily("ubuntu")?.arches.contains(.amd64) == true)
    }
}

struct MachineImageBuilderTests {
    @Test func aptDockerfileInstallsSystemd() {
        let df = MachineImageBuilder.dockerfile(for: MachineDistro.forImage("ubuntu:24.04")!)
        #expect(df.contains("FROM ubuntu:24.04"))
        #expect(df.contains("systemd-sysv"))
        #expect(df.contains("STOPSIGNAL SIGRTMIN+3"))
        #expect(df.contains("CMD [\"/sbin/init\"]"))
    }

    @Test func dnfDockerfileUsesDnf() {
        let df = MachineImageBuilder.dockerfile(for: MachineDistro.forImage("rockylinux:9")!)
        #expect(df.contains("FROM rockylinux:9"))
        #expect(df.contains("dnf -y install"))
        #expect(df.contains("CMD [\"/sbin/init\"]"))
    }

    @Test func zypperDockerfileRefreshesFirst() {
        let df = MachineImageBuilder.dockerfile(for: MachineDistro.forImage("opensuse/leap:15.6")!)
        #expect(df.contains("zypper"))
        #expect(df.contains("--gpg-auto-import-keys refresh"))
        #expect(df.contains("CMD [\"/sbin/init\"]"))
    }

    @Test func apkDockerfileIsShellKeepalive() {
        let df = MachineImageBuilder.dockerfile(for: MachineDistro.forImage("alpine:3.20")!)
        #expect(df.contains("FROM alpine:3.20"))
        #expect(df.contains("apk add"))
        #expect(df.contains("CMD [\"tail\", \"-f\", \"/dev/null\"]"))
        #expect(!df.contains("/sbin/init"))
    }

    @Test func pacmanDockerfileDisablesSandbox() {
        let df = MachineImageBuilder.dockerfile(for: MachineDistro.forImage("archlinux:latest")!)
        #expect(df.contains("FROM archlinux:latest"))
        #expect(df.contains("pacman -Sy"))
        #expect(df.contains("--disable-sandbox"))
        #expect(df.contains("CMD [\"/sbin/init\"]"))
    }
}

struct MachineServiceHelperTests {
    @Test func createBodyForSystemdSetsInitAndPrivileged() {
        let body = MachineService.createBody(name: "dev", distro: MachineDistro.forImage("ubuntu:24.04")!,
                                             arch: .amd64, imageTag: "dory-machine/ubuntu:24.04-amd64", keepaliveOnly: false)
        #expect(body["Image"] as? String == "dory-machine/ubuntu:24.04-amd64")
        #expect(body["Hostname"] as? String == "dev")
        #expect(body["Cmd"] as? [String] == ["/sbin/init"])
        #expect(body["StopSignal"] as? String == "SIGRTMIN+3")
        let labels = body["Labels"] as? [String: String]
        #expect(labels?["dory.machine"] == "ubuntu")
        #expect(labels?["dory.machine.version"] == "24.04 LTS")
        #expect(labels?["dory.machine.arch"] == "amd64")
        let host = body["HostConfig"] as? [String: Any]
        #expect(host?["Privileged"] as? Bool == true)
        #expect(host?["CgroupnsMode"] as? String == "host")
        #expect((host?["Tmpfs"] as? [String: String])?["/run"] == "")
    }

    @Test func createBodyKeepaliveOverridesInit() {
        let body = MachineService.createBody(name: "a", distro: MachineDistro.forImage("alpine:3.20")!,
                                             arch: .arm64, imageTag: "dory-machine/alpine:3.20-arm64", keepaliveOnly: true)
        #expect(body["Cmd"] as? [String] == ["tail", "-f", "/dev/null"])
    }

    @Test func shellDistroUsesKeepaliveEvenWhenNotForced() {
        let body = MachineService.createBody(name: "a", distro: MachineDistro.forImage("alpine:3.20")!,
                                             arch: .arm64, imageTag: "dory-machine/alpine:3.20-arm64", keepaliveOnly: false)
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
