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
final class ArchiveMigrationSourceRuntime: ContainerRuntime {
    let kind: RuntimeKind = .docker
    nonisolated var supportsImageArchiveTransfer: Bool { true }

    func snapshot() async throws -> RuntimeSnapshot {
        RuntimeSnapshot(images: [
            DockerImage(repository: "local/web", tag: "dev", imageID: "sha256:local", size: "12 MB", created: "now", usedByCount: 0),
        ])
    }

    nonisolated func saveImage(reference: String) -> AsyncStream<Data> {
        AsyncStream { continuation in
            continuation.yield(Data("tar:\(reference):".utf8))
            continuation.yield(Data("payload".utf8))
            continuation.finish()
        }
    }

    func start(containerID: String) async throws {}
    func stop(containerID: String) async throws {}
    func restart(containerID: String) async throws {}
    func remove(containerID: String) async throws {}
    func logs(containerID: String) async throws -> [LogLine] { [] }
    func env(containerID: String) async throws -> [EnvVar] { [] }
    func create(_ spec: ContainerSpec) async throws -> String { "unused" }
    func exec(containerID: String, command: [String]) async throws -> ExecResult { ExecResult(exitCode: 0, output: "") }
}

@MainActor
final class ArchiveMigrationTargetRuntime: ContainerRuntime {
    enum TestError: Error { case pullShouldNotBeUsed }

    let kind: RuntimeKind = .sharedVM
    var loadedArchives: [Data] = []
    var loadedArchiveChunks: [[String]] = []
    var pulled: [String] = []
    nonisolated var supportsImageArchiveTransfer: Bool { true }

    func snapshot() async throws -> RuntimeSnapshot { RuntimeSnapshot() }
    func start(containerID: String) async throws {}
    func stop(containerID: String) async throws {}
    func restart(containerID: String) async throws {}
    func remove(containerID: String) async throws {}
    func logs(containerID: String) async throws -> [LogLine] { [] }
    func env(containerID: String) async throws -> [EnvVar] { [] }
    func pull(image: String) async throws { pulled.append(image); throw TestError.pullShouldNotBeUsed }
    func create(_ spec: ContainerSpec) async throws -> String { "unused" }
    func exec(containerID: String, command: [String]) async throws -> ExecResult { ExecResult(exitCode: 0, output: "") }
    func loadImage(tar: Data) async throws { loadedArchives.append(tar) }
    func loadImage(stream: AsyncStream<Data>) async throws {
        var chunks: [String] = []
        for await chunk in stream {
            chunks.append(String(decoding: chunk, as: UTF8.self))
        }
        loadedArchiveChunks.append(chunks)
    }
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

    @Test func migrationParsesDockerStyleAndLegacyPortDisplays() {
        #expect(MigrationAssistant.parsePorts("8080→80, 127.0.0.1:5353->53/udp, 443/tcp") == [
            "8080:80",
            "127.0.0.1:5353:53/udp",
            "443",
        ])
    }

    @Test func copiesImageArchivesBeforeFallingBackToPull() async {
        let source = ArchiveMigrationSourceRuntime()
        let target = ArchiveMigrationTargetRuntime()

        let summary = await MigrationAssistant.migrate(from: source, to: target, recreateContainers: false)

        #expect(target.pulled.isEmpty)
        #expect(target.loadedArchives.isEmpty)
        #expect(target.loadedArchiveChunks == [["tar:local/web:dev:", "payload"]])
        #expect(summary.imagesImported == ["local/web:dev"])
        #expect(summary.failures.isEmpty)
    }
}
