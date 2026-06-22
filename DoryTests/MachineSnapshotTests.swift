import Testing
import Foundation
@testable import Dory

struct DockerImageOpsTests {
    @Test func commitPathEncodesQuery() {
        let path = DockerImageOps.commitPath(container: "dory-machine-dev", repo: "dory-snapshot/dev", tag: "s1700000000")
        #expect(path == "/commit?container=dory-machine-dev&repo=dory-snapshot/dev&tag=s1700000000")
    }
}

struct SnapshotCodecTests {
    @Test func buildsSnapshotLabels() {
        let m = Machine(name: "dev", distro: "Ubuntu", version: "24.04 LTS", status: .running,
                        cpuPercent: 0, memoryDisplay: "—", ip: "—", letter: "U", badgeHex: 0,
                        containerID: "c1", arch: "arm64")
        let labels = SnapshotLabels.make(machine: m, note: "before upgrade", createdISO: "2026-06-22T10:00:00Z")
        #expect(labels["dory.snapshot.of"] == "dev")
        #expect(labels["dory.snapshot.note"] == "before upgrade")
        #expect(labels["dory.snapshot.created"] == "2026-06-22T10:00:00Z")
        #expect(labels["dory.machine.arch"] == "arm64")
    }

    @Test func mapsImagesJSONToSnapshots() {
        let json = """
        [{"Id":"sha256:abc","RepoTags":["dory-snapshot/dev:s17"],"Size":123456789,
          "Labels":{"dory.snapshot.of":"dev","dory.snapshot.note":"n","dory.snapshot.created":"2026-06-22T10:00:00Z",
                    "dory.machine":"ubuntu","dory.machine.version":"24.04 LTS","dory.machine.arch":"arm64"}},
         {"Id":"sha256:def","RepoTags":["redis:7"],"Size":1,"Labels":{}}]
        """.data(using: .utf8)!
        let snaps = SnapshotLabels.snapshots(fromImagesJSON: json)
        #expect(snaps.count == 1)
        #expect(snaps[0].machineName == "dev")
        #expect(snaps[0].imageRef == "dory-snapshot/dev:s17")
        #expect(snaps[0].distro == "Ubuntu")
        #expect(snaps[0].arch == "arm64")
        #expect(snaps[0].sizeBytes == 123456789)
    }
}

struct DoryMachineFileTests {
    @Test func acceptsDoryLabeledImage() {
        #expect(MachineService.isDoryMachineImage(loadedLabels: ["dory.machine": "ubuntu"]))
    }
    @Test func rejectsPlainImage() {
        #expect(!MachineService.isDoryMachineImage(loadedLabels: [:]))
        #expect(!MachineService.isDoryMachineImage(loadedLabels: ["maintainer": "x"]))
    }

    @Test func firstNewPicksTheNewlyLoadedSnapshot() {
        let old = MachineSnapshot(id: "old", imageRef: "r1", machineName: "m", note: "", createdISO: "2026-01-02", sizeBytes: 0, distro: "Ubuntu", version: "", arch: "")
        let new = MachineSnapshot(id: "new", imageRef: "r2", machineName: "m", note: "", createdISO: "2026-01-01", sizeBytes: 0, distro: "Ubuntu", version: "", arch: "")
        #expect(MachineService.firstNew(before: ["old"], after: [old, new])?.id == "new")
        #expect(MachineService.firstNew(before: ["old", "new"], after: [old, new]) == nil)
    }
}
