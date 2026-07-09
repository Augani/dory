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
    let kind: RuntimeKind = .sharedVM
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
final class VolumeMigrationSourceRuntime: ContainerRuntime {
    let kind: RuntimeKind = .docker
    var helperCreated = false
    var helperRemoved = false

    func snapshot() async throws -> RuntimeSnapshot {
        RuntimeSnapshot(
            containers: [
                Container(id: "c1", name: "db", image: "postgres:16", status: .stopped, cpuPercent: 0,
                          memoryDisplay: "0", memoryLimitDisplay: "—", memoryFraction: 0, ports: "",
                          uptime: "—", created: "now", ipAddress: "—", domain: "", command: "", restartPolicy: "unless-stopped",
                          labels: ["com.docker.compose.project": "shop"],
                          mounts: [ContainerMount(type: "volume", source: "db-data", target: "/var/lib/postgresql/data")],
                          networks: ["shop_default"]),
            ],
            images: [
                DockerImage(repository: "postgres", tag: "16", imageID: "sha256:db", size: "40 MB", created: "now", usedByCount: 1),
            ],
            volumes: [
                Volume(name: "db-data", size: "—", driver: "local", usedBy: "db", created: "now"),
            ],
            networks: [
                DoryNetwork(name: "bridge", driver: "bridge", scope: "local", subnet: "", containerCount: 0),
                DoryNetwork(name: "shop_default", driver: "bridge", scope: "local", subnet: "", containerCount: 1),
            ]
        )
    }

    func start(containerID: String) async throws {}
    func stop(containerID: String) async throws {}
    func restart(containerID: String) async throws {}
    func remove(containerID: String) async throws {}
    func logs(containerID: String) async throws -> [LogLine] { [] }
    func env(containerID: String) async throws -> [EnvVar] { [EnvVar(key: "POSTGRES_PASSWORD", value: "secret")] }
    func create(_ spec: ContainerSpec) async throws -> String { "unused" }
    func exec(containerID: String, command: [String]) async throws -> ExecResult { ExecResult(exitCode: 0, output: "") }

    func proxyRequest(method: String, path: String, headers: [(name: String, value: String)], body: Data) async -> HTTPResponse? {
        if method == "POST", path == "/containers/create" {
            helperCreated = true
            return HTTPResponse(statusCode: 201, reason: "Created", headers: [:], body: Data(#"{"Id":"source-helper"}"#.utf8))
        }
        if method == "DELETE", path.contains("/containers/source-helper") {
            helperRemoved = true
            return HTTPResponse(statusCode: 204, reason: "No Content", headers: [:], body: Data())
        }
        return nil
    }

    func copyOutStream(containerID: String, path: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(Data("tar-header".utf8))
            continuation.yield(Data("tar-body".utf8))
            continuation.finish()
        }
    }
}

@MainActor
final class VolumeMigrationTargetRuntime: ContainerRuntime {
    let kind: RuntimeKind = .sharedVM
    var pulled: [String] = []
    var volumesCreated: [String] = []
    var networksCreated: [String] = []
    var archiveChunks: [String] = []
    var helperCreated = false
    var helperRemoved = false
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
    func createVolume(name: String, driver: String?, labels: [String: String], driverOptions: [String: String]) async throws {
        volumesCreated.append(name)
    }
    func createNetwork(name: String, labels: [String: String]) async throws {
        networksCreated.append(name)
    }

    func proxyRequest(method: String, path: String, headers: [(name: String, value: String)], body: Data) async -> HTTPResponse? {
        if method == "POST", path == "/containers/create" {
            helperCreated = true
            return HTTPResponse(statusCode: 201, reason: "Created", headers: [:], body: Data(#"{"Id":"target-helper"}"#.utf8))
        }
        if method == "DELETE", path.contains("/containers/target-helper") {
            helperRemoved = true
            return HTTPResponse(statusCode: 204, reason: "No Content", headers: [:], body: Data())
        }
        return nil
    }

    func copyIn(containerID: String, path: String, archiveStream: AsyncThrowingStream<Data, Error>) async -> Bool {
        do {
            for try await chunk in archiveStream {
                archiveChunks.append(String(decoding: chunk, as: UTF8.self))
            }
            return containerID == "target-helper" && path == "/data"
        } catch {
            return false
        }
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
        #expect(inventory.attentionItems.contains { $0.contains("Named Docker volume data") })
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

    @Test func copiesVolumesAndRecreatesContainersWithMountsAndNetworks() async {
        let source = VolumeMigrationSourceRuntime()
        let target = VolumeMigrationTargetRuntime()

        let summary = await MigrationAssistant.migrate(from: source, to: target)

        #expect(target.pulled == ["postgres:16"])
        #expect(target.networksCreated == ["shop_default"])
        #expect(target.volumesCreated == ["db-data"])
        #expect(target.archiveChunks == ["tar-header", "tar-body"])
        #expect(summary.networksCreated == ["shop_default"])
        #expect(summary.volumesCopied == ["db-data"])
        #expect(summary.containersMigrated == ["db"])
        #expect(summary.failures.isEmpty)
        #expect(target.created.first?.mounts == [ContainerMount(type: "volume", source: "db-data", target: "/var/lib/postgresql/data")])
        #expect(target.created.first?.networks == ["shop_default"])
        #expect(target.created.first?.restart == "unless-stopped")
        #expect(target.created.first?.environment["POSTGRES_PASSWORD"] == "secret")
        #expect(source.helperCreated)
        #expect(target.helperCreated)
    }
}
