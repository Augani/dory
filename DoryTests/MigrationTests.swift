import Testing
import Foundation
@testable import Dory

@MainActor
final class MigrationSourceRuntime: ContainerRuntime {
    let kind: RuntimeKind = .docker
    func snapshot() async throws -> RuntimeSnapshot {
        RuntimeSnapshot(
            containers: [
                Container(id: "c1", name: "web", image: "nginx:alpine", status: .running, cpuPercent: 0,
                          memoryDisplay: "0", memoryLimitDisplay: "—", memoryFraction: 0, ports: "8080→80",
                          uptime: "—", created: "now", ipAddress: "—", domain: "", command: "", restartPolicy: "no"),
            ],
            images: [
                DockerImage(repository: "nginx", tag: "alpine", imageID: "abc", size: "40 MB", created: "now", usedByCount: 1),
                DockerImage(repository: "<none>", tag: "<none>", imageID: "def", size: "1 MB", created: "now", usedByCount: 0),
            ]
        )
    }
    func start(containerID: String) async throws {}
    func stop(containerID: String) async throws {}
    func restart(containerID: String) async throws {}
    func remove(containerID: String) async throws {}
    func logs(containerID: String) async throws -> [LogLine] { [] }
    func env(containerID: String) async throws -> [EnvVar] { [EnvVar(key: "PORT", value: "80")] }
    func create(_ spec: ContainerSpec) async throws -> String { "x" }
    func exec(containerID: String, command: [String]) async throws -> ExecResult { ExecResult(exitCode: 0, output: "") }
}

@MainActor
final class MigrationTargetRuntime: ContainerRuntime {
    let kind: RuntimeKind = .appleContainer
    var pulled: [String] = []
    var created: [ContainerSpec] = []
    func snapshot() async throws -> RuntimeSnapshot { RuntimeSnapshot() }
    func start(containerID: String) async throws {}
    func stop(containerID: String) async throws {}
    func restart(containerID: String) async throws {}
    func remove(containerID: String) async throws {}
    func logs(containerID: String) async throws -> [LogLine] { [] }
    func env(containerID: String) async throws -> [EnvVar] { [] }
    func pull(image: String) async throws { pulled.append(image) }
    func create(_ spec: ContainerSpec) async throws -> String { created.append(spec); return "new" }
    func exec(containerID: String, command: [String]) async throws -> ExecResult { ExecResult(exitCode: 0, output: "") }
}

@MainActor
struct MigrationTests {
    @Test func migratesImagesAndRecreatesContainers() async {
        let source = MigrationSourceRuntime()
        let target = MigrationTargetRuntime()
        let summary = await MigrationAssistant.migrate(from: source, to: target)

        #expect(target.pulled == ["nginx:alpine"]) // <none> image skipped
        #expect(summary.imagesPulled == ["nginx:alpine"])
        #expect(target.created.count == 1)
        let spec = target.created.first
        #expect(spec?.name == "web")
        #expect(spec?.image == "nginx:alpine")
        #expect(spec?.ports == ["8080:80"]) // → rewritten to :
        #expect(spec?.environment["PORT"] == "80")
        #expect(spec?.labels["dory.migrated.from"] == "docker")
        #expect(summary.containersMigrated == ["web"])
    }
}
