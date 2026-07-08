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
    func pull(image: String, registryAuth: String?) async throws { pulled.append(image) }
    func create(_ spec: ContainerSpec) async throws -> String { created.append(spec); return "new" }
    func exec(containerID: String, command: [String]) async throws -> ExecResult { ExecResult(exitCode: 0, output: "") }
}

@MainActor
final class MigrationPreflightRuntime: ContainerRuntime {
    let kind: RuntimeKind = .docker

    func snapshot() async throws -> RuntimeSnapshot {
        RuntimeSnapshot(
            containers: [
                Container(id: "c1", name: "web", image: "local/web:dev", status: .running, cpuPercent: 0,
                          memoryDisplay: "0", memoryLimitDisplay: "—", memoryFraction: 0, ports: "8080→80",
                          uptime: "—", created: "now", ipAddress: "—", domain: "", command: "", restartPolicy: "no",
                          labels: ["com.docker.compose.project": "shop"],
                          mounts: [
                            ContainerMount(type: "bind", source: "/Users/me/shop", target: "/app"),
                            ContainerMount(type: "volume", source: "db-data", target: "/var/lib/postgresql/data"),
                          ],
                          volumeTargets: ["/cache"]),
                Container(id: "c2", name: "db", image: "postgres:16", status: .running, cpuPercent: 0,
                          memoryDisplay: "0", memoryLimitDisplay: "—", memoryFraction: 0, ports: "",
                          uptime: "—", created: "now", ipAddress: "—", domain: "", command: "", restartPolicy: "no",
                          networkMode: "host", privileged: true),
            ],
            images: [
                DockerImage(repository: "local/web", tag: "dev", imageID: "sha256:web", size: "120 MB", created: "now", usedByCount: 1, sizeBytes: 123_000_000),
                DockerImage(repository: "postgres", tag: "16", imageID: "sha256:db", size: "40 MB", created: "now", usedByCount: 1),
                DockerImage(repository: "<none>", tag: "<none>", imageID: "sha256:dangling", size: "1 MB", created: "now", usedByCount: 0),
            ],
            volumes: [
                Volume(name: "db-data", size: "—", driver: "local", usedBy: "db", created: "now"),
            ],
            networks: [
                DoryNetwork(name: "bridge", driver: "bridge", scope: "local", subnet: "", containerCount: 0),
                DoryNetwork(name: "shop_default", driver: "bridge", scope: "local", subnet: "172.20.0.0/16", containerCount: 2),
            ]
        )
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
    func pull(image: String, registryAuth: String?) async throws { pulled.append(image); throw TestError.pullShouldNotBeUsed }
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
    @Test func preflightBuildsConfidenceReportBeforeImport() async throws {
        let inventory = try #require(await MigrationAssistant.preflight(from: MigrationPreflightRuntime()))

        #expect(inventory.images == 2)
        #expect(inventory.containers == 2)
        #expect(inventory.volumes == 1)
        #expect(inventory.volumeNames == ["db-data"])
        #expect(inventory.networks == 1)
        #expect(inventory.composeProjects == ["shop"])
        #expect(inventory.estimatedImageBytes == 163_000_000)
        #expect(inventory.bindMounts == 1)
        #expect(inventory.namedVolumeMounts == 1)
        #expect(inventory.anonymousVolumeTargets == 1)
        #expect(inventory.privilegedContainers == ["db"])
        #expect(inventory.hostNetworkContainers == ["db"])
        #expect(inventory.containersWithPublishedPorts == 1)
        #expect(inventory.confidenceLabel == "Needs review")
        #expect(inventory.transferItems.contains { $0.contains("compose project") })
        #expect(inventory.transferItems.contains { $0.contains("custom network") })
        #expect(inventory.attentionItems.contains { $0.contains("Volume data") })
        #expect(inventory.attentionItems.contains { $0.contains("bind mount") })
        #expect(inventory.attentionItems.contains { $0.contains("Privileged") })
        #expect(inventory.attentionItems.contains { $0.contains("Host-network") })
        #expect(MigrationAssistant.estimatedBytes(for: "1.5 GB") == 1_500_000_000)
    }

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
