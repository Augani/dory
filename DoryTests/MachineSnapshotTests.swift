import Testing
import Foundation
@testable import Dory

struct DockerImageOpsTests {
    @Test func commitPathEncodesQuery() {
        let path = DockerImageOps.commitPath(container: "dory-machine-dev", repo: "dory-snapshot/dev", tag: "s1700000000")
        #expect(path == "/commit?container=dory-machine-dev&repo=dory-snapshot%2Fdev&tag=s1700000000")
    }

    @Test func migrationCommitCanExplicitlyAvoidPausingSourceContainer() {
        let path = DockerImageOps.commitPath(
            container: "running-source",
            repo: "dory-migration-temporary/snapshot",
            tag: "fixture",
            pause: false
        )
        #expect(path == "/commit?container=running-source&repo=dory-migration-temporary%2Fsnapshot&tag=fixture&pause=0")
    }

    @Test func queryValueEscapesQueryDelimiters() {
        #expect(DockerImageOps.queryValue("/tmp/a&b?c=d+e") == "%2Ftmp%2Fa%26b%3Fc%3Dd%2Be")
    }

    @Test func pathComponentEscapesSlashesOnlyAsPathDelimiters() {
        #expect(DockerImageOps.pathComponent("dory/web-api:latest") == "dory%2Fweb-api:latest")
    }
}

struct SnapshotCodecTests {
    @Test func buildsSnapshotLabels() {
        let m = Machine(name: "dev", distro: "Ubuntu", version: "24.04 LTS", status: .running,
                        cpuPercent: 0, memoryDisplay: "—", ip: "—", letter: "U", badgeHex: 0,
                        containerID: "c1", arch: "arm64", recipe: "node",
                        username: "devuser", loginShell: "/bin/zsh", uid: 777, homePath: "/Volumes/DevHome/devuser")
        let labels = SnapshotLabels.make(machine: m, note: "before upgrade", createdISO: "2026-06-22T10:00:00Z")
        #expect(labels["dory.snapshot.of"] == "dev")
        #expect(labels["dory.snapshot.note"] == "before upgrade")
        #expect(labels["dory.snapshot.created"] == "2026-06-22T10:00:00Z")
        #expect(labels["dory.machine.arch"] == "arm64")
        #expect(labels["dory.machine.boot"] == "systemd")
        #expect(labels["dory.recipe"] == "node")
        #expect(labels["dory.machine.user"] == "devuser")
        #expect(labels["dory.machine.uid"] == "777")
        #expect(labels["dory.machine.home"] == "/Volumes/DevHome/devuser")
        #expect(labels["dory.machine.shell"] == "/bin/zsh")
    }

    @Test func mapsImagesJSONToSnapshots() {
        let json = """
        [{"Id":"sha256:abc","RepoTags":["dory-snapshot/dev:s17"],"Size":123456789,
          "Labels":{"dory.snapshot.of":"dev","dory.snapshot.note":"n","dory.snapshot.created":"2026-06-22T10:00:00Z",
                    "dory.machine":"ubuntu","dory.machine.version":"24.04 LTS","dory.machine.arch":"arm64",
                    "dory.machine.boot":"systemd","dory.recipe":"node","dory.machine.user":"devuser",
                    "dory.machine.uid":"777","dory.machine.home":"/Volumes/DevHome/devuser","dory.machine.shell":"/bin/zsh"}},
         {"Id":"sha256:def","RepoTags":["redis:7"],"Size":1,"Labels":{}}]
        """.data(using: .utf8)!
        let snaps = SnapshotLabels.snapshots(fromImagesJSON: json)
        #expect(snaps.count == 1)
        #expect(snaps[0].machineName == "dev")
        #expect(snaps[0].imageRef == "dory-snapshot/dev:s17")
        #expect(snaps[0].distro == "Ubuntu")
        #expect(snaps[0].arch == "arm64")
        #expect(snaps[0].sizeBytes == 123456789)
        #expect(snaps[0].boot == "systemd")
        #expect(snaps[0].recipe == "node")
        #expect(snaps[0].username == "devuser")
        #expect(snaps[0].uid == 777)
        #expect(snaps[0].homePath == "/Volumes/DevHome/devuser")
        #expect(snaps[0].loginShell == "/bin/zsh")
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
        let old = MachineSnapshot(id: "old", imageRef: "r1", machineName: "m", note: "", createdISO: "2026-01-02", sizeBytes: 0, distro: "Ubuntu", version: "", arch: "", boot: "systemd", recipe: "")
        let new = MachineSnapshot(id: "new", imageRef: "r2", machineName: "m", note: "", createdISO: "2026-01-01", sizeBytes: 0, distro: "Ubuntu", version: "", arch: "", boot: "systemd", recipe: "")
        #expect(MachineService.firstNew(before: ["old"], after: [old, new])?.id == "new")
        #expect(MachineService.firstNew(before: ["old", "new"], after: [old, new]) == nil)
    }
}

struct SnapshotScheduleTests {
    @Test func scheduleCalculatesDueAndNextRun() throws {
        let schedule = MachineSnapshotSchedule(machineName: "dev", frequency: .daily, keepLocal: 5)
        try schedule.validate()
        let last = Date(timeIntervalSince1970: 1_700_000_000)

        #expect(schedule.isDue(lastSnapshotAt: nil, now: last))
        #expect(!schedule.isDue(lastSnapshotAt: last, now: last.addingTimeInterval(23 * 60 * 60)))
        #expect(schedule.isDue(lastSnapshotAt: last, now: last.addingTimeInterval(24 * 60 * 60)))
        #expect(schedule.nextRun(after: last) == last.addingTimeInterval(24 * 60 * 60))
    }

    @Test func scheduleRejectsUnsafeValues() {
        #expect(throws: SnapshotScheduleError.invalidMachineName) {
            try MachineSnapshotSchedule(machineName: "../dev", frequency: .daily).validate()
        }
        #expect(throws: SnapshotScheduleError.invalidRetention) {
            try MachineSnapshotSchedule(machineName: "dev", frequency: .daily, keepLocal: 0).validate()
        }
        #expect(throws: SnapshotScheduleError.invalidBucket) {
            try MachineSnapshotSchedule(
                machineName: "dev",
                frequency: .daily,
                s3: S3BackupDestination(bucket: "Bad_Bucket")
            ).validate()
        }
        #expect(throws: SnapshotScheduleError.invalidPrefix) {
            try MachineSnapshotSchedule(
                machineName: "dev",
                frequency: .daily,
                s3: S3BackupDestination(bucket: "dory-backups", prefix: "../escape")
            ).validate()
        }
    }

    @Test func s3BackupDestinationBuildsStableObjectURL() throws {
        let snapshot = MachineSnapshot(
            id: "sha256:abc/123",
            imageRef: "dory-snapshot/dev:s17",
            machineName: "dev",
            note: "nightly",
            createdISO: "2026-07-04T17:00:00Z",
            sizeBytes: 42,
            distro: "Ubuntu",
            version: "24.04 LTS",
            arch: "arm64",
            boot: "systemd",
            recipe: "node"
        )
        let destination = S3BackupDestination(bucket: "dory-backups", prefix: "machines/dev", region: "us-east-1")
        try destination.validate()

        #expect(destination.objectKey(for: snapshot) == "machines/dev/dev-20260704T170000Z-sha256-abc-123.tar")
        #expect(destination.url(for: snapshot) == "s3://dory-backups/machines/dev/dev-20260704T170000Z-sha256-abc-123.tar")
    }
}

struct DevRecipeTests {
    @Test func catalogHasSevenRecipes() {
        #expect(DevRecipe.all.map(\.id) == ["node", "python", "go", "java", "ruby", "rust", "devops"])
        #expect(Set(DevRecipe.all.map(\.id)).count == DevRecipe.all.count)
    }
    @Test func rustRecipeInstallsCargoAndRustc() {
        let rust = DevRecipe.forID("rust")
        #expect(rust != nil)
        #expect(rust?.install.contains("cargo") == true)
        #expect(rust?.install.contains("rustc") == true)
    }
    @Test func devopsRecipeInstallsDockerAndKubectl() {
        let devops = DevRecipe.forID("devops")
        #expect(devops != nil)
        #expect(devops?.install.contains("kubectl") == true)
        #expect(devops?.install.contains("/usr/local/bin/docker") == true)
    }
    @Test func everyRecipeHasNonEmptyFields() {
        for recipe in DevRecipe.all {
            #expect(!recipe.install.isEmpty)
            #expect(!recipe.display.isEmpty)
            #expect(!recipe.icon.isEmpty)
        }
    }
    @Test func recipeDockerfileLayersOnBase() {
        let df = MachineImageBuilder.recipeDockerfile(baseImageTag: "dory-machine/ubuntu:24.04-arm64",
                                                      recipe: DevRecipe.forID("node")!)
        #expect(df.contains("FROM dory-machine/ubuntu:24.04-arm64"))
        #expect(df.contains("nodejs"))
        #expect(!df.contains("/sbin/init"))
    }

    @Test func schemaRecipeDockerfileInstallsPackagesBeforeCommands() throws {
        let recipe = DevRecipe(
            id: "rust-dev",
            display: "Rust Dev",
            icon: "r.circle",
            install: "",
            packages: ["build-essential", "pkg-config"],
            runcmd: ["echo ready"]
        )
        let df = MachineImageBuilder.recipeDockerfile(baseImageTag: "base", recipe: recipe, packageManager: .apt)
        #expect(df.contains("apt-get install -y --no-install-recommends 'build-essential' 'pkg-config'"))
        #expect(df.range(of: "apt-get install")!.lowerBound < df.range(of: "echo ready")!.lowerBound)
    }

    @Test func recipeProvisionScriptUsesDistroPackageManager() {
        let recipe = DevRecipe(id: "tools", display: "Tools", icon: "wrench", install: "", packages: ["git"], runcmd: [])
        #expect(recipe.provisionScript(packageManager: .dnf).contains("dnf install -y 'git'"))
        #expect(recipe.provisionScript(packageManager: .apk).contains("apk add --no-cache 'git'"))
        #expect(recipe.provisionScript(packageManager: .pacman).contains("pacman -Sy --noconfirm --needed 'git'"))
    }
}

struct MachineSettingsTests {
    @Test func encodesResourcesAndMounts() {
        let s = MachineSettings(cpus: 2, memoryMB: 2048,
                                mounts: [MountPair(host: "/Users/x/proj", guest: "/proj")],
                                ports: [PortPair(host: 8080, guest: 80)])
        let host = MachineService.hostConfig(base: [:], settings: s)
        #expect(host["NanoCpus"] as? Int64 == 2_000_000_000)
        #expect(host["Memory"] as? Int64 == Int64(2048) * 1024 * 1024)
        #expect((host["Binds"] as? [String])?.first == "/Users/x/proj:/proj")
        let pb = host["PortBindings"] as? [String: [[String: String]]]
        #expect(pb?["80/tcp"]?.first?["HostPort"] == "8080")
    }

    @Test func currentSettingsReadsModernInspectMounts() async {
        let json = """
        {
          "HostConfig": {
            "NanoCpus": 2000000000,
            "Memory": 2147483648,
            "Binds": ["/Users/me/legacy:/legacy"],
            "PortBindings": {"22/tcp": [{"HostPort": "2222"}]}
          },
          "Config": {
            "Env": ["container=docker", "FOO=bar", "EMPTY="],
            "Labels": {
              "dory.machine.user": "augustusotu",
              "dory.machine.uid": "777",
              "dory.machine.home": "/Volumes/DevHome/augustusotu",
              "dory.machine.shell": "/bin/bash"
            }
          },
          "Mounts": [
            {"Type": "bind", "Source": "/Users/me/src", "Destination": "/src", "RW": false},
            {"Type": "volume", "Name": "cache", "Destination": "/cache", "RW": true}
          ]
        }
        """.data(using: .utf8)!
        let service = MachineService(runtime: InspectOnlyRuntime(body: json))

        let settings = await service.currentSettings(name: "dev")

        #expect(settings.cpus == 2)
        #expect(settings.memoryMB == 2048)
        #expect(settings.mounts == [
            MountPair(host: "/Users/me/legacy", guest: "/legacy"),
            MountPair(host: "/Users/me/src", guest: "/src", readOnly: true),
        ])
        #expect(settings.ports == [PortPair(host: 2222, guest: 22)])
        #expect(settings.env == ["FOO": "bar", "EMPTY": ""])
        #expect(settings.identity?.username == "augustusotu")
        #expect(settings.identity?.uid == 777)
        #expect(settings.identity?.homePath == "/Volumes/DevHome/augustusotu")
        #expect(settings.identity?.shell == "/bin/bash")
    }

    @Test func editSettingsPreserveHiddenEnvAndIdentity() {
        let identity = MacIdentity(username: "augustusotu", uid: 501, homePath: "/Users/augustusotu", shell: "/bin/bash", publicKeys: [])
        var existing = MachineSettings.default
        existing.env = ["FOO": "bar"]
        existing.identity = identity
        let visible = MachineSettings(cpus: 4, memoryMB: 4096, mounts: [], ports: [])

        let merged = AppStore.preservingHiddenMachineSettings(visible, existing: existing)

        #expect(merged.cpus == 4)
        #expect(merged.memoryMB == 4096)
        #expect(merged.env == ["FOO": "bar"])
        #expect(merged.identity == identity)
    }

    @Test func editSettingsKeepExplicitHiddenValues() {
        let existingID = MacIdentity(username: "old", uid: 501, homePath: "/Users/old", shell: "/bin/bash", publicKeys: [])
        let explicitID = MacIdentity(username: "new", uid: 502, homePath: "/Users/new", shell: "/bin/zsh", publicKeys: [])
        var existing = MachineSettings.default
        existing.env = ["OLD": "value"]
        existing.identity = existingID
        var visible = MachineSettings(cpus: 4, memoryMB: 4096, mounts: [], ports: [])
        visible.env = ["NEW": "value"]
        visible.identity = explicitID

        let merged = AppStore.preservingHiddenMachineSettings(visible, existing: existing)

        #expect(merged.env == ["NEW": "value"])
        #expect(merged.identity == explicitID)
    }

    @MainActor
    @Test func cloneFromSnapshotRestoresIdentityLabelsAndHomeMount() async throws {
        let capture = CreateBodyCapture()
        let service = MachineService(runtime: CreateOnlyRuntime(capture: capture))
        let snapshot = MachineSnapshot(
            id: "sha256:abc",
            imageRef: "dory-snapshot/dev:s1",
            machineName: "dev",
            note: "",
            createdISO: "2026-06-22T10:00:00Z",
            sizeBytes: 0,
            distro: "Ubuntu",
            version: "24.04 LTS",
            arch: "arm64",
            boot: "systemd",
            recipe: "",
            username: "devuser",
            uid: 777,
            homePath: "/Volumes/DevHome/devuser",
            loginShell: "/bin/zsh"
        )

        try await service.cloneFromSnapshot(snapshot, newName: "dev-copy")

        let body = try #require(capture.json)
        let labels = try #require(body["Labels"] as? [String: String])
        let hostConfig = try #require(body["HostConfig"] as? [String: Any])
        #expect(labels[MachineService.userLabel] == "devuser")
        #expect(labels[MachineService.uidLabel] == "777")
        #expect(labels[MachineService.homeLabel] == "/Volumes/DevHome/devuser")
        #expect(labels[MachineService.shellLabel] == "/bin/zsh")
        #expect((hostConfig["Binds"] as? [String])?.contains("/Volumes/DevHome/devuser:/Volumes/DevHome/devuser") == true)
        #expect(capture.path == "/containers/create?name=dory-machine-dev-copy&platform=linux%2Farm64")
    }
}

private struct InspectOnlyRuntime: ContainerRuntime {
    let kind: RuntimeKind = .mock
    var body: Data

    func snapshot() async throws -> RuntimeSnapshot { RuntimeSnapshot() }
    func start(containerID: String) async throws {}
    func stop(containerID: String) async throws {}
    func restart(containerID: String) async throws {}
    func remove(containerID: String) async throws {}
    func logs(containerID: String) async throws -> [LogLine] { [] }
    func env(containerID: String) async throws -> [EnvVar] { [] }
    func create(_ spec: ContainerSpec) async throws -> String { spec.name }
    func exec(containerID: String, command: [String]) async throws -> ExecResult { ExecResult(exitCode: 0, output: "") }
    func proxyRequest(method: String, path: String, headers: [(name: String, value: String)], body: Data) async -> HTTPResponse? {
        HTTPResponse(statusCode: 200, reason: "OK", headers: [:], body: self.body)
    }
}

private final class CreateBodyCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var body: Data?
    private var requestPath: String?

    var json: [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        guard let body else { return nil }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    var path: String? {
        lock.lock()
        defer { lock.unlock() }
        return requestPath
    }

    func record(path: String, body: Data) {
        lock.lock()
        self.requestPath = path
        self.body = body
        lock.unlock()
    }
}

private struct CreateOnlyRuntime: ContainerRuntime {
    let kind: RuntimeKind = .mock
    let capture: CreateBodyCapture

    func snapshot() async throws -> RuntimeSnapshot { RuntimeSnapshot() }
    func start(containerID: String) async throws {}
    func stop(containerID: String) async throws {}
    func restart(containerID: String) async throws {}
    func remove(containerID: String) async throws {}
    func logs(containerID: String) async throws -> [LogLine] { [] }
    func env(containerID: String) async throws -> [EnvVar] { [] }
    func create(_ spec: ContainerSpec) async throws -> String { spec.name }
    func exec(containerID: String, command: [String]) async throws -> ExecResult { ExecResult(exitCode: 0, output: "") }
    func proxyRequest(method: String, path: String, headers: [(name: String, value: String)], body: Data) async -> HTTPResponse? {
        if method == "POST", path.hasPrefix("/containers/create") {
            capture.record(path: path, body: body)
            return HTTPResponse(statusCode: 201, reason: "Created", headers: [:], body: Data())
        }
        return HTTPResponse(statusCode: 200, reason: "OK", headers: [:], body: Data())
    }
}
