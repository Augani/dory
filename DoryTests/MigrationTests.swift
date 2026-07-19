import Testing
import Foundation
import Darwin
import DoryOperations
@testable import Dory

@MainActor
final class MigrationSourceRuntime: ContainerRuntime {
    enum FixtureError: Error { case partialInventory }
    let kind: RuntimeKind = .docker
    var includePublishedPort = true
    var failStrictInventory = false
    var includeSourceContainerIDFile = false
    func snapshot() async throws -> RuntimeSnapshot {
        return RuntimeSnapshot(
            containers: [
                Container(id: "c1", name: "web", image: "nginx:alpine", status: .running, cpuPercent: 0,
                          memoryDisplay: "0", memoryLimitDisplay: "—", memoryFraction: 0, ports: includePublishedPort ? "8080→80" : "",
                          uptime: "—", created: "now", ipAddress: "—", domain: "", command: "", restartPolicy: "no"),
            ],
            images: [
                DockerImage(repository: "nginx", tag: "alpine", imageID: "abc", size: "40 MB", created: "now", usedByCount: 1),
                DockerImage(repository: "<none>", tag: "<none>", imageID: "def", size: "1 MB", created: "now", usedByCount: 0),
            ]
        )
    }
    func migrationSnapshot() async throws -> RuntimeSnapshot {
        if failStrictInventory { throw FixtureError.partialInventory }
        return try await snapshot()
    }
    func start(containerID: String) async throws {}
    func stop(containerID: String) async throws {}
    func restart(containerID: String) async throws {}
    func remove(containerID: String) async throws {}
    func logs(containerID: String) async throws -> [LogLine] { [] }
    func env(containerID: String) async throws -> [EnvVar] { [EnvVar(key: "PORT", value: "80")] }
    func create(_ spec: ContainerSpec) async throws -> String { "x" }
    func exec(containerID: String, command: [String]) async throws -> ExecResult { ExecResult(exitCode: 0, output: "") }
    func proxyRequest(method: String, path: String, headers: [(name: String, value: String)], body: Data) async -> HTTPResponse? {
        guard method == "GET", path == "/containers/c1/json" else { return nil }
        let portBindings = includePublishedPort ? #"{"80/tcp":[{"HostPort":"8080"}]}"# : "{}"
        let containerIDFile = includeSourceContainerIDFile ? #""/tmp/source-container.cid""# : "null"
        let legacyBind = try? JSONSerialization.data(withJSONObject: ["\(NSHomeDirectory()):/workspace:rshared"])
        let legacyBinds = legacyBind.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return HTTPResponse(statusCode: 200, reason: "OK", headers: [:], body: Data(#"""
        {
          "Config": {
            "Hostname": "web-host",
            "MacAddress": "02:42:ac:11:00:0a",
            "User": "1000:1000",
            "Image": "nginx:alpine",
            "Cmd": ["nginx", "-g", "daemon off;"],
            "Entrypoint": ["/docker-entrypoint.sh"],
            "Env": ["PORT=80"],
            "Labels": {"com.example.role": "web"},
            "ExposedPorts": {"80/tcp": {}},
            "Volumes": {"/cache": {}},
            "WorkingDir": "/srv"
          },
          "HostConfig": {
            "RestartPolicy": {"Name": "unless-stopped", "MaximumRetryCount": 0},
            "PortBindings": \#(portBindings),
            "NanoCpus": 2000000000,
            "Memory": 536870912,
            "ContainerIDFile": \#(containerIDFile),
            "Binds": \#(legacyBinds),
            "Tmpfs": {"/scratch":"rw,size=64m"},
            "Mounts": [{
              "Type":"volume","Source":"","Target":"/advanced","ReadOnly":true,
              "Consistency":"delegated","VolumeOptions":{"NoCopy":true,"Subpath":"nested"}
            }]
          },
          "NetworkSettings": {"Networks": {"bridge": {"Aliases": ["web"]}}},
          "Mounts": [
            {"Type":"volume","Name":"cache-volume","Source":"/daemon/private/cache","Destination":"/advanced","RW":false},
            {"Type":"tmpfs","Source":"","Destination":"/scratch","RW":true},
            {"Type":"bind","Source":"/host_mnt\#(NSHomeDirectory())","Destination":"/workspace","RW":true,"Propagation":"rshared"}
          ]
        }
        """#.utf8))
    }
}

@MainActor
final class MigrationTargetRuntime: ContainerRuntime {
    enum FixtureError: Error { case startFailed }

    let kind: RuntimeKind = .sharedVM
    var pulled: [String] = []
    var created: [ContainerSpec] = []
    var started: [String] = []
    var removed: [String] = []
    var failOnStart = false
    var snapshotValue = RuntimeSnapshot()
    func snapshot() async throws -> RuntimeSnapshot { snapshotValue }
    func start(containerID: String) async throws {
        started.append(containerID)
        if failOnStart { throw FixtureError.startFailed }
    }
    func stop(containerID: String) async throws {}
    func restart(containerID: String) async throws {}
    func remove(containerID: String) async throws { removed.append(containerID) }
    func logs(containerID: String) async throws -> [LogLine] { [] }
    func env(containerID: String) async throws -> [EnvVar] { [] }
    func pull(image: String, registryAuth: String?) async throws { pulled.append(image) }
    func create(_ spec: ContainerSpec) async throws -> String { created.append(spec); return "new" }
    func exec(containerID: String, command: [String]) async throws -> ExecResult { ExecResult(exitCode: 0, output: "") }
}

@MainActor
final class MigrationPreflightRuntime: ContainerRuntime {
    let kind: RuntimeKind = .docker
    nonisolated let supportsRawProxy: Bool
    var snapshotValue: RuntimeSnapshot?
    var reportedVolumeName = "db-data"
    var reportedVolumeSize: Int64 = 3_000_000_000
    var invalidTargetUsage = false
    var useCurrentVolumeUsageShape = false
    var malformedCurrentVolumeUsageShape = false
    var volumeUsageRequestPaths: [String] = []
    var filteredVolumeMountRW: Bool?
    var reportedWritableSizes: [String: Int64]?

    init(supportsRawProxy: Bool = true) {
        self.supportsRawProxy = supportsRawProxy
    }

    func snapshot() async throws -> RuntimeSnapshot {
        if let snapshotValue { return snapshotValue }
        return RuntimeSnapshot(
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

    func migrationContainerWritableSizes() async throws -> [String: Int64] {
        if let reportedWritableSizes { return reportedWritableSizes }
        return Dictionary(uniqueKeysWithValues: try await snapshot().containers.map { ($0.id, 0) })
    }

    func start(containerID: String) async throws {}
    func stop(containerID: String) async throws {}
    func restart(containerID: String) async throws {}
    func remove(containerID: String) async throws {}
    func logs(containerID: String) async throws -> [LogLine] { [] }
    func env(containerID: String) async throws -> [EnvVar] { [] }
    func create(_ spec: ContainerSpec) async throws -> String { "unused" }
    func exec(containerID: String, command: [String]) async throws -> ExecResult { ExecResult(exitCode: 0, output: "") }
    func proxyRequest(method: String, path: String, headers: [(name: String, value: String)], body: Data) async -> HTTPResponse? {
        if method == "GET", path.hasPrefix("/containers/json?all=1&filters="),
           let filteredVolumeMountRW {
            let data = try? JSONSerialization.data(withJSONObject: [[
                "Id": "filtered",
                "State": "running",
                "Mounts": [[
                    "Type": "volume",
                    "Name": reportedVolumeName,
                    "RW": filteredVolumeMountRW,
                ]],
            ]])
            return HTTPResponse(statusCode: 200, reason: "OK", headers: [:], body: data ?? Data())
        }
        if method == "GET", path == "/containers/c1/json" {
            return HTTPResponse(statusCode: 200, reason: "OK", headers: [:], body: Data(#"""
            {
              "Config":{"Image":"local/web:dev","Volumes":{"/cache":{}}},
              "HostConfig":{"Mounts":[
                {"Type":"bind","Source":"/Users/me/shop","Target":"/app"},
                {"Type":"volume","Source":"db-data","Target":"/var/lib/postgresql/data"}
              ]},
              "NetworkSettings":{"Networks":{"shop_default":{}}},
              "Mounts":[
                {"Type":"bind","Source":"/Users/me/shop","Destination":"/app","RW":true},
                {"Type":"volume","Name":"db-data","Source":"/daemon/db-data","Destination":"/var/lib/postgresql/data","RW":true}
              ]
            }
            """#.utf8))
        }
        if method == "GET", path == "/containers/c2/json" {
            return HTTPResponse(statusCode: 200, reason: "OK", headers: [:], body: Data(#"""
            {
              "Config":{"Image":"postgres:16"},
              "HostConfig":{"NetworkMode":"host","Privileged":true},
              "NetworkSettings":{"Networks":{"host":{}}},
              "Mounts":[]
            }
            """#.utf8))
        }
        if method == "GET", path == "/system/df" {
            let data = invalidTargetUsage
                ? Data(#"{"LayersSize":100,"Volumes":[],"Containers":[],"BuildCache":[{}]}"#.utf8)
                : Data(#"{"ImageUsage":{"TotalSize":100},"VolumeUsage":{"TotalSize":200},"ContainerUsage":{"TotalSize":300},"BuildCacheUsage":{"TotalSize":400}}"#.utf8)
            return HTTPResponse(statusCode: 200, reason: "OK", headers: [:], body: data)
        }
        return volumeUsageResponse(method: method, path: path)
    }

    private func volumeUsageResponse(method: String, path: String) -> HTTPResponse? {
        guard method == "GET", path.hasPrefix("/system/df?type=volume") else { return nil }
        volumeUsageRequestPaths.append(path)
        if malformedCurrentVolumeUsageShape {
            guard path == "/system/df?type=volume&verbose=1" else { return nil }
            return HTTPResponse(
                statusCode: 200,
                reason: "OK",
                headers: [:],
                body: Data(#"{"VolumeUsage":{"Items":[{"Name":"db-data"}]}}"#.utf8)
            )
        }
        if useCurrentVolumeUsageShape {
            guard path == "/system/df?type=volume&verbose=1" else { return nil }
            return HTTPResponse(statusCode: 200, reason: "OK", headers: [:], body: Data(#"""
            {"VolumeUsage":{"TotalSize":\#(reportedVolumeSize),"Items":[
              {"Name":"\#(reportedVolumeName)","UsageData":{"Size":\#(reportedVolumeSize),"RefCount":1}}
            ]}}
            """#.utf8))
        }
        guard path == "/system/df?type=volume" else { return nil }
        return HTTPResponse(statusCode: 200, reason: "OK", headers: [:], body: Data(#"""
        {"Volumes":[
          {"Name":"\#(reportedVolumeName)","UsageData":{"Size":\#(reportedVolumeSize),"RefCount":1}}
        ]}
        """#.utf8))
    }
}

@MainActor
final class ArchiveMigrationSourceRuntime: ContainerRuntime {
    enum FixtureError: Error { case truncatedArchive }
    let kind: RuntimeKind = .docker
    nonisolated var supportsImageArchiveTransfer: Bool { true }
    nonisolated let failArchiveStream: Bool
    nonisolated let includeAdditionalReference: Bool
    nonisolated let imageContract: Data?
    nonisolated var supportsRawProxy: Bool { imageContract != nil }

    init(
        failArchiveStream: Bool = false,
        includeAdditionalReference: Bool = false,
        imageContract: Data? = nil
    ) {
        self.failArchiveStream = failArchiveStream
        self.includeAdditionalReference = includeAdditionalReference
        self.imageContract = imageContract
    }

    func snapshot() async throws -> RuntimeSnapshot {
        RuntimeSnapshot(images: [
            DockerImage(
                repository: "local/web",
                tag: "dev",
                imageID: "sha256:local",
                size: "12 MB",
                created: "now",
                usedByCount: 0,
                additionalReferences: includeAdditionalReference ? ["local/web:alt"] : []
            ),
        ])
    }

    nonisolated func saveImage(reference: String) -> AsyncStream<Data> {
        AsyncStream { continuation in
            continuation.yield(Data("tar:\(reference):".utf8))
            continuation.yield(Data("payload".utf8))
            continuation.finish()
        }
    }
    nonisolated func saveImageThrowing(reference: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(Data("tar:\(reference):".utf8))
            if failArchiveStream {
                continuation.finish(throwing: FixtureError.truncatedArchive)
            } else {
                continuation.yield(Data("payload".utf8))
                continuation.finish()
            }
        }
    }
    func proxyRequest(method: String, path: String, headers: [(name: String, value: String)], body: Data) async -> HTTPResponse? {
        guard method == "GET", path.hasPrefix("/images/"), path.hasSuffix("/json"),
              let imageContract else { return nil }
        return HTTPResponse(statusCode: 200, reason: "OK", headers: [:], body: imageContract)
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
    var tags: [(source: String, repo: String, tag: String)] = []
    var snapshotValue = RuntimeSnapshot()
    var allowPull = false
    nonisolated let imageContract: Data?
    nonisolated var supportsImageArchiveTransfer: Bool { true }
    nonisolated var supportsRawProxy: Bool { imageContract != nil }

    init(imageContract: Data? = nil) {
        self.imageContract = imageContract
    }

    func snapshot() async throws -> RuntimeSnapshot { snapshotValue }
    func start(containerID: String) async throws {}
    func stop(containerID: String) async throws {}
    func restart(containerID: String) async throws {}
    func remove(containerID: String) async throws {}
    func logs(containerID: String) async throws -> [LogLine] { [] }
    func env(containerID: String) async throws -> [EnvVar] { [] }
    func pull(image: String, registryAuth: String?) async throws {
        pulled.append(image)
        if !allowPull { throw TestError.pullShouldNotBeUsed }
    }
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
    func tagImage(source: String, repo: String, tag: String) async throws {
        tags.append((source, repo, tag))
    }
    func proxyRequest(method: String, path: String, headers: [(name: String, value: String)], body: Data) async -> HTTPResponse? {
        guard method == "GET", path.hasPrefix("/images/"), path.hasSuffix("/json"),
              let imageContract else { return nil }
        return HTTPResponse(statusCode: 200, reason: "OK", headers: [:], body: imageContract)
    }
}

@MainActor
final class BareContentMigrationSourceRuntime: ContainerRuntime {
    let kind: RuntimeKind = .docker
    let sourceID = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    nonisolated var supportsImageArchiveTransfer: Bool { true }

    func snapshot() async throws -> RuntimeSnapshot {
        var container = Container(
            id: "bare-content-container",
            name: "bare-content",
            image: sourceID,
            status: .stopped,
            cpuPercent: 0,
            memoryDisplay: "0",
            memoryLimitDisplay: "—",
            memoryFraction: 0,
            ports: "",
            uptime: "—",
            created: "now",
            ipAddress: "—",
            domain: "",
            command: "true",
            restartPolicy: "no"
        )
        container.sourceImageID = sourceID
        return RuntimeSnapshot(
            containers: [container],
            images: [
                DockerImage(repository: "<none>", tag: "<none>", imageID: sourceID, size: "1 MB", created: "now", usedByCount: 1),
            ]
        )
    }

    nonisolated func saveImage(reference: String) -> AsyncStream<Data> {
        AsyncStream { continuation in
            continuation.yield(Data(reference.utf8))
            continuation.finish()
        }
    }

    func proxyRequest(method: String, path: String, headers: [(name: String, value: String)], body: Data) async -> HTTPResponse? {
        guard method == "GET", path == "/containers/bare-content-container/json" else { return nil }
        return HTTPResponse(statusCode: 200, reason: "OK", headers: [:], body: Data("""
        {"Config":{"Image":"\(sourceID)","Cmd":["true"]},"HostConfig":{},"NetworkSettings":{"Networks":{}},"Mounts":[]}
        """.utf8))
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
final class BareContentMigrationTargetRuntime: ContainerRuntime {
    enum FixtureError: Error { case normalizedContentID, pullMustNotRun }

    let kind: RuntimeKind = .sharedVM
    nonisolated var supportsImageArchiveTransfer: Bool { true }
    var loaded = false
    var tags: [String] = []
    var created: [ContainerSpec] = []

    func snapshot() async throws -> RuntimeSnapshot {
        guard loaded else { return RuntimeSnapshot() }
        return RuntimeSnapshot(images: [
            DockerImage(repository: "<none>", tag: "<none>", imageID: "sha256:target-normalized", size: "1 MB", created: "now", usedByCount: 0),
        ])
    }
    func loadImage(stream: AsyncStream<Data>) async throws {
        for await _ in stream {}
        loaded = true
    }
    func tagImage(source: String, repo: String, tag: String) async throws {
        tags.append("\(source)|\(repo)|\(tag)")
        if source.hasPrefix("sha256:aaaa") { throw FixtureError.normalizedContentID }
    }
    func pull(image: String, registryAuth: String?) async throws { throw FixtureError.pullMustNotRun }
    func start(containerID: String) async throws {}
    func stop(containerID: String) async throws {}
    func restart(containerID: String) async throws {}
    func remove(containerID: String) async throws {}
    func logs(containerID: String) async throws -> [LogLine] { [] }
    func env(containerID: String) async throws -> [EnvVar] { [] }
    func create(_ spec: ContainerSpec) async throws -> String { created.append(spec); return "bare-target" }
    func exec(containerID: String, command: [String]) async throws -> ExecResult { ExecResult(exitCode: 0, output: "") }
}

@MainActor
final class DeletedBaseImageMigrationSourceRuntime: ContainerRuntime {
    let kind: RuntimeKind = .docker
    nonisolated var supportsImageArchiveTransfer: Bool { true }
    var commitCalls: [String] = []
    var deletedPaths: [String] = []
    var cleanupStatus = 200
    var includeStaleDanglingTemporaryImage = false

    func snapshot() async throws -> RuntimeSnapshot {
        var container = Container(
            id: "deleted-base-container",
            name: "recovered",
            image: "sha256:missing-source-image",
            status: .stopped,
            cpuPercent: 0,
            memoryDisplay: "0",
            memoryLimitDisplay: "—",
            memoryFraction: 0,
            ports: "",
            uptime: "—",
            created: "now",
            ipAddress: "—",
            domain: "",
            command: "true",
            restartPolicy: "no"
        )
        container.sourceImageID = "sha256:missing-source-image"
        var images = [
            DockerImage(repository: "local/recovered", tag: "dev", imageID: "", size: "1 MB", created: "now", usedByCount: 1),
        ]
        if includeStaleDanglingTemporaryImage {
            images.insert(DockerImage(
                repository: "<none>",
                tag: "<none>",
                imageID: "sha256:stale-temporary-image",
                size: "1 MB",
                created: "now",
                usedByCount: 0,
                labels: ["dory.migration.temporary": "true", "dory.migrated.source": "docker"]
            ), at: 0)
        }
        return RuntimeSnapshot(
            containers: [container],
            images: images
        )
    }

    nonisolated func saveImage(reference: String) -> AsyncStream<Data> {
        AsyncStream { continuation in
            continuation.yield(Data(reference.utf8))
            continuation.finish()
        }
    }

    func commit(containerID: String, repo: String, tag: String, labels: [String: String]) async throws -> String {
        commitCalls.append("\(containerID)|\(repo)|\(tag)|\(labels["dory.migration.temporary"] ?? "")|default")
        return "sha256:source-commit-id"
    }
    func commit(
        containerID: String,
        repo: String,
        tag: String,
        labels: [String: String],
        pause: Bool
    ) async throws -> String {
        commitCalls.append("\(containerID)|\(repo)|\(tag)|\(labels["dory.migration.temporary"] ?? "")|\(pause)")
        return "sha256:source-commit-id"
    }

    func proxyRequest(method: String, path: String, headers: [(name: String, value: String)], body: Data) async -> HTTPResponse? {
        if method == "DELETE" {
            deletedPaths.append(path)
            if path.contains("stale-temporary-image") {
                includeStaleDanglingTemporaryImage = false
            }
            return HTTPResponse(
                statusCode: cleanupStatus,
                reason: cleanupStatus == 200 ? "OK" : "Server Error",
                headers: [:],
                body: Data()
            )
        }
        guard method == "GET", path == "/containers/deleted-base-container/json" else { return nil }
        return HTTPResponse(statusCode: 200, reason: "OK", headers: [:], body: Data(#"""
        {
          "Config": {"Image":"local/recovered:dev","Cmd":["true"]},
          "HostConfig": {"RestartPolicy":{"Name":"no","MaximumRetryCount":0}},
          "NetworkSettings": {"Networks":{}},
          "Mounts": []
        }
        """#.utf8))
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
final class DeletedBaseImageMigrationTargetRuntime: ContainerRuntime {
    enum FixtureError: Error { case unavailableImage, normalizedContentID, pullMustNotRun }

    let kind: RuntimeKind = .sharedVM
    nonisolated var supportsImageArchiveTransfer: Bool { true }
    var loadAttempts = 0
    var tagAttempts: [String] = []
    var failEveryLoad = false
    var allowPull = false
    var pulled: [String] = []
    var deletedPaths: [String] = []

    func snapshot() async throws -> RuntimeSnapshot {
        guard loadAttempts >= 3 else { return RuntimeSnapshot() }
        return RuntimeSnapshot(images: [
            DockerImage(repository: "<none>", tag: "<none>", imageID: "targetloaded", size: "1 MB", created: "now", usedByCount: 0),
        ])
    }

    func loadImage(stream: AsyncStream<Data>) async throws {
        for await _ in stream {}
        loadAttempts += 1
        if failEveryLoad || loadAttempts < 3 { throw FixtureError.unavailableImage }
    }

    func tagImage(source: String, repo: String, tag: String) async throws {
        tagAttempts.append("\(source)|\(repo)|\(tag)")
        if source == "sha256:source-commit-id" { throw FixtureError.normalizedContentID }
        guard source == "targetloaded" else { throw FixtureError.unavailableImage }
    }

    func pull(image: String, registryAuth: String?) async throws {
        guard allowPull else { throw FixtureError.pullMustNotRun }
        pulled.append(image)
    }
    func proxyRequest(method: String, path: String, headers: [(name: String, value: String)], body: Data) async -> HTTPResponse? {
        guard method == "DELETE" else { return nil }
        deletedPaths.append(path)
        return HTTPResponse(statusCode: 200, reason: "OK", headers: [:], body: Data())
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
final class VolumeMigrationSourceRuntime: ContainerRuntime {
    let kind: RuntimeKind = .docker
    var helperCreated = false
    var helperRemoved = false
    var includeUnavailableHelperImage = false
    var helperImages: [String] = []
    var networkEnableIPv6 = false
    var includeStaleHelper = false
    var staleHelpersRemoved: [String] = []
    var volumeOptions: [String: String] = [:]
    var failCopyOut = false
    var changeContainerStateOnRefresh = false
    var snapshotCalls = 0
    var writableLayerBytes: Int64 = 0
    var writableSnapshotCommits: [String] = []
    var deletedImageReferences: [String] = []

    func snapshot() async throws -> RuntimeSnapshot {
        snapshotCalls += 1
        var images = [
            DockerImage(repository: "postgres", tag: "16", imageID: "sha256:db", size: "40 MB", created: "now", usedByCount: 1),
        ]
        if includeUnavailableHelperImage {
            images.insert(
                DockerImage(repository: "gone", tag: "latest", imageID: "sha256:gone", size: "1 MB", created: "now", usedByCount: 0),
                at: 0
            )
        }
        var containers = [
                Container(id: "c1", name: "db", image: "postgres:16",
                          status: changeContainerStateOnRefresh && snapshotCalls > 1 ? .running : .stopped,
                          cpuPercent: 0,
                          memoryDisplay: "0", memoryLimitDisplay: "—", memoryFraction: 0, ports: "",
                          uptime: "—", created: "now", ipAddress: "—", domain: "", command: "", restartPolicy: "unless-stopped",
                          labels: ["com.docker.compose.project": "shop"],
                          mounts: [ContainerMount(type: "volume", source: "db-data", target: "/var/lib/postgresql/data")],
                          networks: ["shop_default"]),
        ]
        if includeStaleHelper {
            containers.append(Container(
                id: "stale-source-helper",
                name: "stale-source-helper",
                image: "postgres:16",
                status: .stopped,
                cpuPercent: 0,
                memoryDisplay: "0",
                memoryLimitDisplay: "—",
                memoryFraction: 0,
                ports: "",
                uptime: "—",
                created: "now",
                ipAddress: "—",
                domain: "",
                command: "true",
                restartPolicy: "no",
                labels: ["dory.migration.temporary": "true", "dory.migrated.source": "docker"]
            ))
        }
        return RuntimeSnapshot(
            containers: containers,
            images: images,
            volumes: [
                Volume(name: "db-data", size: "—", driver: "local", usedBy: "db", created: "now", options: volumeOptions),
            ],
            networks: [
                DoryNetwork(name: "bridge", driver: "bridge", scope: "local", subnet: "", containerCount: 0),
                DoryNetwork(name: "shop_default", driver: "bridge", scope: "local", subnet: "", containerCount: 1),
            ]
        )
    }

    func migrationContainerWritableSizes() async throws -> [String: Int64] {
        ["c1": writableLayerBytes]
    }

    func commit(
        containerID: String,
        repo: String,
        tag: String,
        labels: [String: String],
        pause: Bool
    ) async throws -> String {
        writableSnapshotCommits.append(
            "\(containerID)|\(repo):\(tag)|\(labels["dory.migration.container-snapshot"] ?? "")|\(pause)"
        )
        return "sha256:writable-snapshot"
    }

    nonisolated func saveImageThrowing(reference: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(Data("snapshot:\(reference)".utf8))
            continuation.finish()
        }
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
        if method == "DELETE", path.hasPrefix("/images/") {
            deletedImageReferences.append(path)
            return HTTPResponse(statusCode: 200, reason: "OK", headers: [:], body: Data())
        }
        if method == "GET", path == "/networks/shop_default" {
            let enableIPv6 = networkEnableIPv6 ? "true" : "false"
            return HTTPResponse(statusCode: 200, reason: "OK", headers: [:], body: Data(#"""
            {
              "Name":"shop_default",
              "Driver":"bridge",
              "EnableIPv4":true,
              "EnableIPv6":\#(enableIPv6),
              "IPAM":{"Driver":"default","Config":[{"Subnet":"172.30.44.0/24","Gateway":"172.30.44.1"}]},
              "Internal":false,
              "Attachable":true,
              "Ingress":false,
              "Options":{"com.docker.network.bridge.enable_icc":"true"},
              "Labels":{"com.docker.compose.project":"shop"}
            }
            """#.utf8))
        }
        if method == "POST", path == "/containers/create",
           let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let image = root["Image"] as? String {
            helperImages.append(image)
            if image == "gone:latest" {
                return HTTPResponse(
                    statusCode: 404,
                    reason: "Not Found",
                    headers: [:],
                    body: Data(#"{"message":"No such image"}"#.utf8)
                )
            }
            helperCreated = true
            return HTTPResponse(statusCode: 201, reason: "Created", headers: [:], body: Data(#"{"Id":"source-helper"}"#.utf8))
        }
        if method == "DELETE", path.contains("/containers/source-helper") {
            helperRemoved = true
            return HTTPResponse(statusCode: 204, reason: "No Content", headers: [:], body: Data())
        }
        if method == "DELETE", path.contains("/containers/stale-source-helper") {
            staleHelpersRemoved.append("stale-source-helper")
            includeStaleHelper = false
            return HTTPResponse(statusCode: 204, reason: "No Content", headers: [:], body: Data())
        }
        return nil
    }

    func copyOutStream(containerID: String, path: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(Data("tar-header".utf8))
            if failCopyOut {
                continuation.finish(throwing: VolumeMigrationFixtureError.sourceArchiveTruncated)
                return
            }
            continuation.yield(Data("tar-body".utf8))
            continuation.finish()
        }
    }
}

private enum VolumeMigrationFixtureError: Error {
    case sourceArchiveTruncated
    case injectedSnapshotBindFailure
}

@MainActor
final class VolumeMigrationTargetRuntime: ContainerRuntime {
    let kind: RuntimeKind = .sharedVM
    nonisolated var supportsRawProxy: Bool { true }
    var pulled: [String] = []
    var volumesCreated: [String] = []
    var createdVolumeLabels: [String: [String: String]] = [:]
    var volumesRemoved: [String] = []
    var networksCreated: [String] = []
    var networksRemoved: [String] = []
    var targetVolumeSizes: [String: Int64] = [:]
    var archiveChunks: [String] = []
    var networkCreateBodies: [[String: Any]] = []
    var networkCreateFailuresRemaining = 0
    var helperCreated = false
    var helperRemoved = false
    var helperCleanupStatus = 204
    var staleHelpersRemoved: [String] = []
    var inspectedNetworkSubnet = "172.30.44.0/24"
    var inspectedNetworkEnableIPv6 = false
    var created: [ContainerSpec] = []
    var snapshotValue = RuntimeSnapshot()
    var loadedWritableSnapshots: [String] = []
    var writableSnapshotTags: [String] = []
    var deletedImagePaths: [String] = []
    var failWritableSnapshotBinding = false
    var normalizeWritableSnapshotID = false

    func snapshot() async throws -> RuntimeSnapshot { snapshotValue }
    func start(containerID: String) async throws {}
    func stop(containerID: String) async throws {}
    func restart(containerID: String) async throws {}
    func remove(containerID: String) async throws {}
    func logs(containerID: String) async throws -> [LogLine] { [] }
    func env(containerID: String) async throws -> [EnvVar] { [] }
    func pull(image: String, registryAuth: String?) async throws { pulled.append(image) }
    func loadImageThrowing(stream: AsyncThrowingStream<Data, Error>) async throws {
        var value = ""
        for try await chunk in stream { value += String(decoding: chunk, as: UTF8.self) }
        loadedWritableSnapshots.append(value)
    }
    func tagImage(source: String, repo: String, tag: String) async throws {
        writableSnapshotTags.append("\(source)|\(repo):\(tag)")
        let targetReference = "\(repo):\(tag)"
        if normalizeWritableSnapshotID, source == "sha256:writable-snapshot" {
            throw VolumeMigrationFixtureError.injectedSnapshotBindFailure
        }
        if failWritableSnapshotBinding,
           targetReference.hasPrefix("dory-migration/container-snapshot:"),
           source != "sha256:prior-writable-snapshot" {
            throw VolumeMigrationFixtureError.injectedSnapshotBindFailure
        }
    }
    func create(_ spec: ContainerSpec) async throws -> String { created.append(spec); return "new" }
    func exec(containerID: String, command: [String]) async throws -> ExecResult { ExecResult(exitCode: 0, output: "") }
    func createVolume(name: String, driver: String?, labels: [String: String], driverOptions: [String: String]) async throws {
        volumesCreated.append(name)
        createdVolumeLabels[name] = labels
    }
    func removeVolume(name: String) async throws { volumesRemoved.append(name) }
    func createNetwork(name: String, labels: [String: String]) async throws {
        networksCreated.append(name)
    }
    func removeNetwork(name: String) async throws { networksRemoved.append(name) }

    func proxyRequest(method: String, path: String, headers: [(name: String, value: String)], body: Data) async -> HTTPResponse? {
        if method == "DELETE", path.hasPrefix("/images/") {
            deletedImagePaths.append(path)
            let encoded = String(path.dropFirst("/images/".count))
            if let reference = encoded.removingPercentEncoding {
                snapshotValue.images.removeAll { image in
                    image.additionalReferences.contains(reference)
                        || (image.repository != "<none>" && !image.repository.isEmpty
                            && (image.tag == "<none>" || image.tag.isEmpty
                                ? image.repository
                                : "\(image.repository):\(image.tag)") == reference)
                }
            }
            return HTTPResponse(statusCode: 200, reason: "OK", headers: [:], body: Data())
        }
        if method == "GET", path == "/system/df?type=volume" {
            let volumes = targetVolumeSizes.keys.sorted().map { name -> [String: Any] in
                ["Name": name, "UsageData": ["Size": targetVolumeSizes[name] ?? 0]]
            }
            let data = try? JSONSerialization.data(withJSONObject: ["Volumes": volumes])
            return HTTPResponse(statusCode: 200, reason: "OK", headers: [:], body: data ?? Data())
        }
        if method == "GET", path == "/networks/shop_default" {
            return HTTPResponse(statusCode: 200, reason: "OK", headers: [:], body: Data("""
            {
              "Name":"shop_default",
              "Driver":"bridge",
              "EnableIPv4":true,
              "EnableIPv6":\(inspectedNetworkEnableIPv6),
              "IPAM":{"Driver":"default","Options":{},"Config":[{"Subnet":"\(inspectedNetworkSubnet)","Gateway":"172.30.44.1"}]},
              "Internal":false,
              "Attachable":true,
              "Ingress":false,
              "Options":{"com.docker.network.bridge.enable_icc":"true"},
              "ConfigOnly":false,
              "Labels":{"dory.migrated.from":"docker"}
            }
            """.utf8))
        }
        if method == "POST", path == "/networks/create",
           let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let name = root["Name"] as? String {
            if networkCreateFailuresRemaining > 0 {
                networkCreateFailuresRemaining -= 1
                return HTTPResponse(
                    statusCode: 500,
                    reason: "Server Error",
                    headers: [:],
                    body: Data(#"{"message":"injected network creation failure"}"#.utf8)
                )
            }
            networksCreated.append(name)
            networkCreateBodies.append(root)
            inspectedNetworkEnableIPv6 = root["EnableIPv6"] as? Bool ?? false
            return HTTPResponse(statusCode: 201, reason: "Created", headers: [:], body: Data(#"{"Id":"network-id"}"#.utf8))
        }
        if method == "POST", path == "/containers/create" {
            helperCreated = true
            return HTTPResponse(statusCode: 201, reason: "Created", headers: [:], body: Data(#"{"Id":"target-helper"}"#.utf8))
        }
        if method == "DELETE", path.contains("/containers/target-helper") {
            helperRemoved = true
            return HTTPResponse(
                statusCode: helperCleanupStatus,
                reason: helperCleanupStatus == 204 ? "No Content" : "Server Error",
                headers: [:],
                body: helperCleanupStatus == 204 ? Data() : Data(#"{"message":"cleanup failed"}"#.utf8)
            )
        }
        if method == "DELETE", path.contains("/containers/stale-target-helper") {
            staleHelpersRemoved.append("stale-target-helper")
            snapshotValue.containers.removeAll { $0.id == "stale-target-helper" }
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
final class DeletedTagVolumeMigrationSourceRuntime: ContainerRuntime {
    let kind: RuntimeKind = .docker
    nonisolated var supportsImageArchiveTransfer: Bool { true }
    var helperImages: [String] = []

    func snapshot() async throws -> RuntimeSnapshot {
        var container = Container(
            id: "orphaned-container",
            name: "orphaned",
            image: "local/orphaned:dev",
            status: .stopped,
            cpuPercent: 0,
            memoryDisplay: "0",
            memoryLimitDisplay: "—",
            memoryFraction: 0,
            ports: "",
            uptime: "—",
            created: "now",
            ipAddress: "—",
            domain: "",
            command: "true",
            restartPolicy: "no",
            mounts: [ContainerMount(type: "volume", source: "orphan-data", target: "/data")]
        )
        container.sourceImageID = "sha256:orphan-content"
        return RuntimeSnapshot(
            containers: [container],
            images: [
                DockerImage(repository: "local/orphaned", tag: "dev", imageID: "sha256:orphan-content", size: "1 MB", created: "now", usedByCount: 1),
            ],
            volumes: [
                Volume(name: "orphan-data", size: "—", driver: "local", usedBy: "orphaned", created: "now"),
            ]
        )
    }

    nonisolated func saveImage(reference: String) -> AsyncStream<Data> {
        AsyncStream { continuation in
            continuation.yield(Data(reference.utf8))
            continuation.finish()
        }
    }

    func proxyRequest(method: String, path: String, headers: [(name: String, value: String)], body: Data) async -> HTTPResponse? {
        if method == "GET", path == "/containers/orphaned-container/json" {
            return HTTPResponse(statusCode: 200, reason: "OK", headers: [:], body: Data(#"""
            {
              "Config": {"Image":"local/orphaned:dev","Cmd":["true"]},
              "HostConfig": {"Mounts": [{"Type":"volume","Source":"orphan-data","Target":"/data"}]},
              "NetworkSettings": {"Networks":{}},
              "Mounts": [{"Type":"volume","Name":"orphan-data","Source":"orphan-data","Destination":"/data","RW":true}]
            }
            """#.utf8))
        }
        if method == "POST", path == "/containers/create",
           let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let image = root["Image"] as? String {
            helperImages.append(image)
            return HTTPResponse(statusCode: 201, reason: "Created", headers: [:], body: Data(#"{"Id":"source-orphan-helper"}"#.utf8))
        }
        if method == "DELETE", path.contains("/containers/source-orphan-helper") {
            return HTTPResponse(statusCode: 204, reason: "No Content", headers: [:], body: Data())
        }
        return nil
    }

    func copyOutStream(containerID: String, path: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(Data("orphan-volume-data".utf8))
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
final class DeletedTagVolumeMigrationTargetRuntime: ContainerRuntime {
    enum FixtureError: Error { case deletedTag, normalizedContentID }

    let kind: RuntimeKind = .sharedVM
    nonisolated var supportsImageArchiveTransfer: Bool { true }
    var loadReferences: [String] = []
    var helperImages: [String] = []
    var tagged: [String] = []
    var copiedVolumeData = ""

    func snapshot() async throws -> RuntimeSnapshot {
        guard loadReferences.contains("sha256:orphan-content") else { return RuntimeSnapshot() }
        return RuntimeSnapshot(images: [
            DockerImage(repository: "<none>", tag: "<none>", imageID: "target-normalized", size: "1 MB", created: "now", usedByCount: 0),
        ])
    }
    func loadImage(stream: AsyncStream<Data>) async throws {
        var reference = ""
        for await chunk in stream { reference += String(decoding: chunk, as: UTF8.self) }
        loadReferences.append(reference)
        if reference == "local/orphaned:dev" { throw FixtureError.deletedTag }
    }
    func tagImage(source: String, repo: String, tag: String) async throws {
        tagged.append("\(source)|\(repo)|\(tag)")
        if source == "sha256:orphan-content" { throw FixtureError.normalizedContentID }
    }
    func createVolume(name: String, driver: String?, labels: [String: String], driverOptions: [String: String]) async throws {}
    func proxyRequest(method: String, path: String, headers: [(name: String, value: String)], body: Data) async -> HTTPResponse? {
        if method == "POST", path == "/containers/create",
           let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let image = root["Image"] as? String {
            helperImages.append(image)
            return HTTPResponse(statusCode: 201, reason: "Created", headers: [:], body: Data(#"{"Id":"target-orphan-helper"}"#.utf8))
        }
        if method == "DELETE", path.contains("/containers/target-orphan-helper") {
            return HTTPResponse(statusCode: 204, reason: "No Content", headers: [:], body: Data())
        }
        return nil
    }
    func copyIn(containerID: String, path: String, archiveStream: AsyncThrowingStream<Data, Error>) async -> Bool {
        do {
            for try await chunk in archiveStream { copiedVolumeData += String(decoding: chunk, as: UTF8.self) }
            return true
        } catch {
            return false
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
final class FilteredLiveMigrationSource: ContainerRuntime {
    let kind: RuntimeKind = .docker
    let base: DockerEngineRuntime
    let inventory: RuntimeSnapshot
    let fixtureOwner: String

    init(base: DockerEngineRuntime, inventory: RuntimeSnapshot, fixtureOwner: String) {
        self.base = base
        self.inventory = inventory
        self.fixtureOwner = fixtureOwner
    }

    nonisolated var supportsImageArchiveTransfer: Bool { true }
    nonisolated var supportsImageLoadReceipt: Bool { true }
    nonisolated var supportsRawProxy: Bool { true }
    func snapshot() async throws -> RuntimeSnapshot {
        var filtered = inventory
        let included = Set(inventory.images.map(\.imageID))
        let current = try await base.snapshot()
        filtered.images.append(contentsOf: current.images.filter {
            guard !included.contains($0.imageID) else { return false }
            let isOwnedWritableLayer = $0.labels["dev.dory.object.kind"] == "writableLayer"
                && $0.labels["dev.dory.operation.id"] != nil
                && $0.labels["dory.test.owner"] == fixtureOwner
            let isTransferHelper = $0.labels["dev.dory.component"] == "transfer-helper"
                && $0.labels["dev.dory.helper.sha256"] != nil
                && $0.labels["dev.dory.manifest.schema"] == "1"
            return isOwnedWritableLayer || isTransferHelper
        })
        return filtered
    }
    func migrationContainerWritableSizes() async throws -> [String: Int64] {
        let sizes = try await base.migrationContainerWritableSizes()
        let included = Set(inventory.containers.map(\.id))
        return sizes.filter { included.contains($0.key) }
    }
    func start(containerID: String) async throws { try await base.start(containerID: containerID) }
    func stop(containerID: String) async throws { try await base.stop(containerID: containerID) }
    func restart(containerID: String) async throws { try await base.restart(containerID: containerID) }
    func remove(containerID: String) async throws { try await base.remove(containerID: containerID) }
    func logs(containerID: String) async throws -> [LogLine] { try await base.logs(containerID: containerID) }
    func env(containerID: String) async throws -> [EnvVar] { try await base.env(containerID: containerID) }
    func create(_ spec: ContainerSpec) async throws -> String { try await base.create(spec) }
    func commit(containerID: String, repo: String, tag: String, labels: [String: String]) async throws -> String {
        try await base.commit(containerID: containerID, repo: repo, tag: tag, labels: labels)
    }
    func commit(
        containerID: String,
        repo: String,
        tag: String,
        labels: [String: String],
        pause: Bool
    ) async throws -> String {
        try await base.commit(
            containerID: containerID,
            repo: repo,
            tag: tag,
            labels: labels,
            pause: pause
        )
    }
    var migrationSourceIdentifier: String { base.migrationSourceIdentifier }
    func removeImage(id: String) async throws { try await base.removeImage(id: id) }
    func tagImage(source: String, repo: String, tag: String) async throws {
        try await base.tagImage(source: source, repo: repo, tag: tag)
    }
    func loadImage(tar: Data) async throws { try await base.loadImage(tar: tar) }
    func loadImage(stream: AsyncStream<Data>) async throws {
        try await base.loadImage(stream: stream)
    }
    func loadImageThrowing(stream: AsyncThrowingStream<Data, Error>) async throws {
        try await base.loadImageThrowing(stream: stream)
    }
    func loadImageThrowingWithResponse(
        stream: AsyncThrowingStream<Data, Error>
    ) async throws -> Data {
        try await base.loadImageThrowingWithResponse(stream: stream)
    }
    func exec(containerID: String, command: [String]) async throws -> ExecResult {
        try await base.exec(containerID: containerID, command: command)
    }
    nonisolated func saveImage(reference: String) -> AsyncStream<Data> {
        AsyncStream { continuation in
            Task { @MainActor in
                for await chunk in base.saveImage(reference: reference) { continuation.yield(chunk) }
                continuation.finish()
            }
        }
    }
    nonisolated func saveImageThrowing(reference: String) -> AsyncThrowingStream<Data, Error> {
        base.saveImageThrowing(reference: reference)
    }
    func copyOutStream(containerID: String, path: String) -> AsyncThrowingStream<Data, Error> {
        base.copyOutStream(containerID: containerID, path: path)
    }
    func proxyRequest(method: String, path: String, headers: [(name: String, value: String)], body: Data) async -> HTTPResponse? {
        guard path.hasPrefix("/system/df") else {
            return await base.proxyRequest(
                method: method,
                path: path,
                headers: headers,
                body: body
            )
        }
        guard let response = await base.proxyRequest(
            method: method,
            path: path,
            headers: headers,
            body: body
        ), response.isSuccess,
              var root = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            return nil
        }
        let names = Set(inventory.volumes.map(\.name))
        func owned(_ volume: [String: Any]) -> Bool {
            (volume["Name"] as? String).map(names.contains) == true
        }
        var filteredShape = false
        if let volumes = root["Volumes"] as? [[String: Any]] {
            root["Volumes"] = volumes.filter(owned)
            filteredShape = true
        }
        for key in ["VolumeUsage", "VolumesUsage"] {
            guard var usage = root[key] as? [String: Any],
                  let items = usage["Items"] as? [[String: Any]] else { continue }
            let filtered = items.filter(owned)
            let sizes = filtered.compactMap {
                (($0["UsageData"] as? [String: Any])?["Size"] as? NSNumber)?.int64Value
            }
            usage["Items"] = filtered
            usage["TotalCount"] = filtered.count
            usage["ActiveCount"] = filtered.filter {
                ((($0["UsageData"] as? [String: Any])?["RefCount"] as? NSNumber)?.intValue ?? 0) > 0
            }.count
            usage["TotalSize"] = sizes.reduce(Int64(0), +)
            root[key] = usage
            filteredShape = true
        }
        guard filteredShape else { return nil }
        guard let filtered = try? JSONSerialization.data(
            withJSONObject: root,
            options: [.sortedKeys]
        ) else { return nil }
        return HTTPResponse(
            statusCode: response.statusCode,
            reason: response.reason,
            headers: response.headers,
            body: filtered
        )
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
        #expect(inventory.estimatedVolumeBytes == 3_000_000_000)
        #expect(inventory.volumeSizePreflightAvailable)
        #expect(inventory.unknownVolumeSizes == 0)
        #expect(inventory.bindMounts == 1)
        #expect(inventory.namedVolumeMounts == 1)
        #expect(inventory.anonymousVolumeTargets == 1)
        #expect(inventory.privilegedContainers == ["db"])
        #expect(inventory.hostNetworkContainers == ["db"])
        #expect(inventory.containersWithPublishedPorts == 1)
        #expect(inventory.runningContainersWithPublishedPorts == 1)
        #expect(inventory.runningVolumeBackedContainers == ["web"])
        #expect(inventory.isPortabilityBlocked)
        #expect(inventory.portabilityBlockers.contains { $0.contains("outside Dory's shared home") })
        #expect(inventory.confidenceLabel == "Blocked")
        #expect(inventory.transferItems.contains { $0.contains("compose project") })
        #expect(inventory.transferItems.contains { $0.contains("custom network") })
        #expect(inventory.attentionItems.contains { $0.contains("Named Docker volume data") })
        #expect(inventory.attentionItems.contains { $0.contains("bind mount") })
        #expect(inventory.attentionItems.contains { $0.contains("Privileged") })
        #expect(inventory.attentionItems.contains { $0.contains("Host-network") })
        #expect(inventory.attentionItems.contains { $0.contains("consistent copy") })
        #expect(MigrationAssistant.estimatedBytes(for: "1.5 GB") == 1_500_000_000)
    }

    @Test func readOnlyVolumeMountDoesNotRequireStoppingItsRunningContainer() async throws {
        let source = MigrationPreflightRuntime(supportsRawProxy: false)
        source.snapshotValue = RuntimeSnapshot(
            containers: [
                Container(
                    id: "reader",
                    name: "reader",
                    image: "busybox",
                    status: .running,
                    cpuPercent: 0,
                    memoryDisplay: "0",
                    memoryLimitDisplay: "—",
                    memoryFraction: 0,
                    ports: "",
                    uptime: "now",
                    created: "now",
                    ipAddress: "—",
                    domain: "",
                    command: "cat",
                    restartPolicy: "no",
                    mounts: [
                        ContainerMount(type: "volume", source: "docs", target: "/docs", readOnly: true),
                    ]
                ),
            ],
            images: [
                DockerImage(repository: "busybox", tag: "latest", imageID: "sha256:busybox", size: "1 MB", created: "now", usedByCount: 1),
            ],
            volumes: [
                Volume(name: "docs", size: "0 B", driver: "local", usedBy: "reader", created: "now"),
            ]
        )

        let inventory = try #require(await MigrationAssistant.preflight(from: source))

        #expect(inventory.runningVolumeBackedContainers.isEmpty)
        #expect(!inventory.isLiveVolumeCopyUnsafe)
    }

    @Test func liveVolumeRecheckDistinguishesReadOnlyFromWritableMounts() async {
        let source = MigrationPreflightRuntime()
        source.filteredVolumeMountRW = false
        #expect(await MigrationAssistant.runningContainerUsesVolume("db-data", on: source) == false)

        source.filteredVolumeMountRW = true
        #expect(await MigrationAssistant.runningContainerUsesVolume("db-data", on: source) == true)

        source.filteredVolumeMountRW = nil
        #expect(await MigrationAssistant.runningContainerUsesVolume("db-data", on: source) == nil)
    }

    @Test func runningContainerWithWritableLayerChangesBlocksBeforeWrites() async throws {
        let source = MigrationPreflightRuntime(supportsRawProxy: false)
        source.snapshotValue = RuntimeSnapshot(containers: [
            Container(
                id: "changed",
                name: "changed",
                image: "busybox",
                status: .running,
                cpuPercent: 0,
                memoryDisplay: "0",
                memoryLimitDisplay: "—",
                memoryFraction: 0,
                ports: "",
                uptime: "now",
                created: "now",
                ipAddress: "—",
                domain: "",
                command: "sleep",
                restartPolicy: "no"
            ),
        ])
        source.reportedWritableSizes = ["changed": 8192]

        let inventory = try #require(await MigrationAssistant.preflight(from: source))

        #expect(inventory.estimatedContainerWritableBytes == 8192)
        #expect(inventory.runningWritableLayerContainers == ["changed"])
        #expect(inventory.isLiveWritableLayerSnapshotUnsafe)
        #expect(inventory.isImportBlocked)

        let target = MigrationTargetRuntime()
        let summary = await MigrationAssistant.migrate(from: source, to: target)
        #expect(summary.failures.contains { $0.contains("writable-layer changes") })
        #expect(target.pulled.isEmpty)
        #expect(target.created.isEmpty)
    }

    @Test func migrationInventoryBlocksBeforeWritesWhenHostCannotFitImagesVolumesAndHeadroom() {
        let inventory = MigrationInventory(
            sourceName: "OrbStack",
            images: 2,
            containers: 14,
            volumes: 79,
            volumeNames: [],
            estimatedImageBytes: 1_000_000_000,
            estimatedVolumeBytes: 15_000_000_000,
            volumeSizePreflightAvailable: true,
            availableHostBytes: 11_000_000_000
        )

        #expect(inventory.estimatedTransferBytes == 16_000_000_000)
        #expect(inventory.requiredHostBytes == 20_000_000_000)
        #expect(inventory.additionalHostBytesRequired == 9_000_000_000)
        #expect(inventory.isHostDiskInsufficient)
        #expect(inventory.confidenceLabel == "Blocked")
        #expect(inventory.attentionItems.contains { $0.contains("free at least 9 GB more") })
        #expect(inventory.attentionItems.contains { $0.contains("boot-time trim") })
    }

    @Test func preflightSubtractsExactImagesAlreadyPresentOnDory() async throws {
        let source = ArchiveMigrationSourceRuntime()
        let target = ArchiveMigrationTargetRuntime()
        target.snapshotValue = RuntimeSnapshot(images: [
            DockerImage(
                repository: "docker.io/local/web",
                tag: "dev",
                imageID: "sha256:local",
                size: "12 MB",
                created: "now",
                usedByCount: 0,
                sizeBytes: 12_000_000
            ),
        ])

        let inventory = try #require(await MigrationAssistant.preflight(from: source, to: target))

        #expect(inventory.images == 1)
        #expect(inventory.imagesAlreadyOnDory == 1)
        #expect(inventory.estimatedImageBytes == 0)
        #expect(inventory.transferItems.contains { $0.contains("already on Dory") })
    }

    @Test func migratedSnapshotImageWithOnlyItsFinalTagIsNotHiddenAsTemporary() async throws {
        let source = ArchiveMigrationSourceRuntime()
        let target = ArchiveMigrationTargetRuntime()
        target.snapshotValue = RuntimeSnapshot(images: [
            DockerImage(
                repository: "local/web",
                tag: "dev",
                imageID: "sha256:target-normalized-snapshot",
                size: "12 MB",
                created: "now",
                usedByCount: 0,
                labels: [
                    "dory.migration.temporary": "true",
                    "dory.migrated.source": "docker",
                ]
            ),
        ])

        let inventory = try #require(await MigrationAssistant.preflight(from: source, to: target))

        #expect(inventory.imagesAlreadyOnDory == 1)
        #expect(inventory.estimatedImageBytes == 0)
    }

    @Test func preflightCountsADanglingImageStillRequiredByAContainer() async throws {
        let source = MigrationPreflightRuntime()
        var container = Container(
            id: "uses-dangling",
            name: "worker",
            image: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            status: .stopped,
            cpuPercent: 0,
            memoryDisplay: "0",
            memoryLimitDisplay: "—",
            memoryFraction: 0,
            ports: "",
            uptime: "—",
            created: "now",
            ipAddress: "—",
            domain: "",
            command: "true",
            restartPolicy: "no"
        )
        container.sourceImageID = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        source.snapshotValue = RuntimeSnapshot(
            containers: [container],
            images: [
                DockerImage(
                    repository: "<none>",
                    tag: "<none>",
                    imageID: "aaaaaaaaaaaa",
                    size: "25 MB",
                    created: "now",
                    usedByCount: 1,
                    sizeBytes: 25_000_000
                ),
            ]
        )

        let inventory = try #require(await MigrationAssistant.preflight(from: source))

        #expect(inventory.images == 1)
        #expect(inventory.estimatedImageBytes == 25_000_000)
    }

    @Test func unknownNamedVolumeUsageBlocksBeforePartialCopy() {
        let inventory = MigrationInventory(
            sourceName: "Docker Engine",
            images: 0,
            containers: 1,
            volumes: 2,
            volumeNames: [],
            estimatedVolumeBytes: 1_000_000,
            volumeSizePreflightAvailable: true,
            unknownVolumeSizes: 1,
            availableHostBytes: 100_000_000_000
        )

        #expect(inventory.isVolumeSizeUnknown)
        #expect(inventory.isImportBlocked)
        #expect(inventory.confidenceLabel == "Blocked")
        #expect(inventory.attentionItems.contains { $0.contains("cannot prove the data will fit") })
    }

    @Test func volumeUsageMustMatchTheStrictInventoryByName() async throws {
        let source = MigrationPreflightRuntime()
        source.reportedVolumeName = "different-volume"

        let inventory = try #require(await MigrationAssistant.preflight(from: source))

        #expect(inventory.estimatedVolumeBytes == 0)
        #expect(inventory.unknownVolumeSizes == 1)
        #expect(inventory.isVolumeSizeUnknown)
        #expect(inventory.isImportBlocked)
    }

    @Test func preflightUsesVerboseCurrentVolumeUsageWithoutLegacyArray() async throws {
        let source = MigrationPreflightRuntime()
        source.useCurrentVolumeUsageShape = true

        let inventory = try #require(await MigrationAssistant.preflight(from: source))

        #expect(inventory.estimatedVolumeBytes == source.reportedVolumeSize)
        #expect(inventory.unknownVolumeSizes == 0)
        #expect(inventory.volumeSizePreflightAvailable)
        #expect(source.volumeUsageRequestPaths == ["/system/df?type=volume&verbose=1"])
    }

    @Test func successfulMalformedCurrentVolumeUsageFailsClosedWithoutLegacyFallback() async throws {
        let source = MigrationPreflightRuntime()
        source.malformedCurrentVolumeUsageShape = true

        let inventory = try #require(await MigrationAssistant.preflight(from: source))

        #expect(inventory.estimatedVolumeBytes == 0)
        #expect(!inventory.volumeSizePreflightAvailable)
        #expect(inventory.isImportBlocked)
        #expect(source.volumeUsageRequestPaths == ["/system/df?type=volume&verbose=1"])
    }

    @Test func targetUsagePrefersExactAggregateTotalsAndFailsClosedOnInvalidLegacySizes() async throws {
        let source = MigrationPreflightRuntime()
        let target = MigrationPreflightRuntime()

        let measured = try #require(await MigrationAssistant.preflight(from: source, to: target))
        #expect(measured.estimatedTargetDockerBytes == 1_000)
        #expect(measured.targetUsagePreflightAvailable)

        target.invalidTargetUsage = true
        let invalid = try #require(await MigrationAssistant.preflight(from: source, to: target))
        #expect(invalid.isTargetUsageUnknown)
        #expect(invalid.isImportBlocked)
    }

    @Test func unrelatedSameNameTargetVolumeBlocksInPreflightBeforeImagesAreCopied() async throws {
        let source = MigrationPreflightRuntime()
        let target = MigrationPreflightRuntime()
        target.snapshotValue = RuntimeSnapshot(volumes: [
            Volume(
                name: "db-data",
                size: "3 GB",
                driver: "local",
                usedBy: "—",
                created: "now"
            ),
        ])

        let inventory = try #require(await MigrationAssistant.preflight(from: source, to: target))
        #expect(inventory.isTargetCollisionBlocked)
        #expect(inventory.isImportBlocked)
        #expect(inventory.targetCollisionBlockers.contains {
            $0.contains("unrelated volume named db-data")
        })
        #expect(inventory.attentionItems.contains {
            $0.contains("same-name target conflict")
        })
    }

    @Test func emptyDetachedContractCompatibleTargetVolumeIsReplaceableInPreflight() async throws {
        let source = MigrationPreflightRuntime()
        let target = MigrationPreflightRuntime()
        target.reportedVolumeSize = 0
        target.snapshotValue = RuntimeSnapshot(volumes: [
            Volume(
                name: "db-data",
                size: "0 B",
                driver: "local",
                usedBy: "—",
                created: "now",
                labels: ["target.keep": "yes"]
            ),
        ])

        let inventory = try #require(await MigrationAssistant.preflight(from: source, to: target))
        #expect(!inventory.isTargetCollisionBlocked)
        #expect(inventory.replaceableEmptyTargetVolumes == ["db-data"])
        #expect(inventory.attentionItems.contains {
            $0.contains("empty, detached, and contract-compatible")
        })
    }

    @Test func namedVolumesWithoutAnyUsableSourceImageBlockBeforeWrites() async throws {
        let source = MigrationPreflightRuntime()
        source.snapshotValue = RuntimeSnapshot(
            volumes: [Volume(name: "orphan-data", size: "—", driver: "local", usedBy: "—", created: "now")]
        )

        let inventory = try #require(await MigrationAssistant.preflight(from: source))

        #expect(inventory.isVolumeHelperUnavailable)
        #expect(inventory.isImportBlocked)
        #expect(inventory.attentionItems.contains { $0.contains("no usable image") })
    }

    @Test func migrationWithoutAHelperImageNeverCreatesAnEmptyTargetVolume() async {
        let source = MigrationPreflightRuntime(supportsRawProxy: false)
        source.snapshotValue = RuntimeSnapshot(
            volumes: [Volume(name: "orphan-data", size: "—", driver: "local", usedBy: "—", created: "now")]
        )
        let target = VolumeMigrationTargetRuntime()

        let summary = await MigrationAssistant.migrate(from: source, to: target, recreateContainers: false)

        #expect(target.volumesCreated.isEmpty)
        #expect(target.volumesRemoved.isEmpty)
        #expect(summary.volumesCopied.isEmpty)
        #expect(summary.failures.contains { $0.contains("target volume was not created") })
    }

    @Test func runningVolumeBackedContainerBlocksMigrationBeforeAnyTargetMutation() async {
        let source = MigrationPreflightRuntime()
        source.snapshotValue = RuntimeSnapshot(
            containers: [
                Container(
                    id: "live-db",
                    name: "live-db",
                    image: "postgres:16",
                    status: .running,
                    cpuPercent: 0,
                    memoryDisplay: "0",
                    memoryLimitDisplay: "—",
                    memoryFraction: 0,
                    ports: "",
                    uptime: "now",
                    created: "now",
                    ipAddress: "—",
                    domain: "",
                    command: "postgres",
                    restartPolicy: "unless-stopped",
                    mounts: [ContainerMount(type: "volume", source: "db-data", target: "/var/lib/postgresql/data")]
                ),
            ],
            images: [
                DockerImage(repository: "postgres", tag: "16", imageID: "db", size: "1 MB", created: "now", usedByCount: 1),
            ],
            volumes: [
                Volume(name: "db-data", size: "—", driver: "local", usedBy: "live-db", created: "now"),
            ]
        )
        let target = VolumeMigrationTargetRuntime()

        let summary = await MigrationAssistant.migrate(from: source, to: target)

        #expect(summary.failures.contains { $0.contains("still live") })
        #expect(target.pulled.isEmpty)
        #expect(target.volumesCreated.isEmpty)
        #expect(target.created.isEmpty)
    }

    @Test func targetAndIncomingUsageCannotExceedSparseEngineCapacity() {
        let inventory = MigrationInventory(
            sourceName: "OrbStack",
            images: 1,
            containers: 1,
            volumes: 1,
            volumeNames: [],
            estimatedImageBytes: 30 * 1024 * 1024 * 1024,
            estimatedVolumeBytes: 50 * 1024 * 1024 * 1024,
            volumeSizePreflightAvailable: true,
            availableHostBytes: 500 * 1024 * 1024 * 1024,
            estimatedTargetDockerBytes: 50 * 1024 * 1024 * 1024
        )

        #expect(inventory.isEngineDiskInsufficient)
        #expect(inventory.isImportBlocked)
        #expect(inventory.attentionItems.contains { $0.contains("engine disk would need") })
    }

    @Test func engineAdmissionUsesGuestUsableCapacityNotSparseFileLength() {
        let inventory = MigrationInventory(
            sourceName: "OrbStack",
            images: 1,
            containers: 0,
            volumes: 0,
            volumeNames: [],
            estimatedImageBytes: 110 * 1024 * 1024 * 1024,
            availableHostBytes: 500 * 1024 * 1024 * 1024
        )

        // 110 GiB incoming plus 20% headroom is 132 GiB: the sparse file length must never be used
        // as an excuse to exceed the smaller guest-proven usable floor.
        #expect(inventory.requiredEngineBytes == 132 * 1024 * 1024 * 1024)
        #expect(inventory.isEngineDiskInsufficient)
    }

    @Test func grownEngineCapacityUpdatesAdmissionAndGrowthRecommendation() {
        var inventory = MigrationInventory(
            sourceName: "OrbStack",
            images: 1,
            containers: 0,
            volumes: 0,
            volumeNames: [],
            estimatedImageBytes: 110 * 1024 * 1024 * 1024,
            availableHostBytes: 500 * 1024 * 1024 * 1024
        )

        #expect(inventory.isEngineDiskInsufficient)
        #expect(inventory.recommendedEngineCapacityGiB == 256)

        inventory.engineDiskLogicalBytes = 256 * 1024 * 1024 * 1024
        inventory.engineDiskUsableBytes = 240 * 1024 * 1024 * 1024

        #expect(!inventory.isEngineDiskInsufficient)
        #expect(inventory.recommendedEngineCapacityGiB == nil)
    }

    @Test func unknownExistingTargetUsageBlocksTheCapacityDecision() {
        let inventory = MigrationInventory(
            sourceName: "OrbStack",
            images: 1,
            containers: 1,
            volumes: 0,
            volumeNames: [],
            estimatedImageBytes: 1_000_000,
            availableHostBytes: 100_000_000_000,
            targetUsagePreflightAvailable: false
        )

        #expect(inventory.isTargetUsageUnknown)
        #expect(inventory.isImportBlocked)
        #expect(inventory.attentionItems.contains { $0.contains("could not measure its existing Docker data usage") })
    }

    @Test func unknownHostDiskUsageBlocksBeforeImport() {
        let inventory = MigrationInventory(
            sourceName: "OrbStack",
            images: 1,
            containers: 0,
            volumes: 0,
            volumeNames: [],
            estimatedImageBytes: 1_000_000_000,
            hostDiskPreflightAvailable: false
        )

        #expect(inventory.isHostDiskUnknown)
        #expect(inventory.isImportBlocked)
        #expect(inventory.attentionItems.contains { $0.contains("did not report available host disk space") })
    }

    @Test func completelyFullHostDiskIsInsufficientRatherThanUnknown() {
        let inventory = MigrationInventory(
            sourceName: "OrbStack",
            images: 1,
            containers: 0,
            volumes: 0,
            volumeNames: [],
            estimatedImageBytes: 1_000_000_000,
            availableHostBytes: 0,
            hostDiskPreflightAvailable: true
        )

        #expect(!inventory.isHostDiskUnknown)
        #expect(inventory.isHostDiskInsufficient)
        #expect(inventory.isImportBlocked)
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
        #expect(spec?.hostname == "web-host")
        #expect(spec?.macAddress == "02:42:ac:11:00:0a")
        #expect(spec?.user == "1000:1000")
        #expect(spec?.workingDir == "/srv")
        #expect(spec?.entrypoint == ["/docker-entrypoint.sh"])
        #expect(spec?.command == ["nginx", "-g", "daemon off;"])
        #expect(spec?.restart == "unless-stopped")
        #expect(spec?.nanoCPUs == 2_000_000_000)
        #expect(spec?.memoryLimitBytes == 536_870_912)
        #expect(spec?.volumeTargets == ["/cache"])
        let advancedMount = spec?.mounts.first { $0.target == "/advanced" }
        #expect(advancedMount?.source == "cache-volume")
        #expect(advancedMount?.readOnly == true)
        #expect(advancedMount?.consistency == "delegated")
        #expect(advancedMount?.volumeOptions?.NoCopy == true)
        #expect(advancedMount?.volumeOptions?.Subpath == "nested")
        #expect(spec?.tmpfs == ["/scratch": "rw,size=64m"])
        #expect(spec?.mounts.contains { $0.target == "/scratch" } == false)
        #expect(spec?.volumes == ["\(NSHomeDirectory()):/workspace:rshared"])
        #expect(spec?.mounts.contains { $0.target == "/workspace" } == false)
        #expect(spec?.networks.isEmpty == true) // default bridge is selected by NetworkMode, not recreated
        #expect(spec?.labels["dory.migrated.from"] == "docker")
        #expect(spec?.labels["dory.migrated.source"] == "docker")
        #expect(spec?.labels["com.example.role"] == "web")
        #expect(target.started.isEmpty)
        #expect(summary.containersMigrated == ["web"])
        #expect(summary.containersAwaitingSourcePorts == ["web"])
        #expect(summary.warnings.count == 1)
    }

    @Test func strictInventoryFailureCannotBecomeAnImageOnlyImport() async {
        let source = MigrationSourceRuntime()
        source.failStrictInventory = true
        let target = MigrationTargetRuntime()

        let inventory = await MigrationAssistant.preflight(from: source, to: target)
        let summary = await MigrationAssistant.migrate(from: source, to: target)

        #expect(inventory == nil)
        #expect(target.pulled.isEmpty)
        #expect(target.created.isEmpty)
        #expect(summary.failures == ["could not read source engine"])
    }

    @Test func nonportableContainerContractFailsBeforeImagesArePulled() async {
        let source = MigrationSourceRuntime()
        source.includeSourceContainerIDFile = true
        let target = MigrationTargetRuntime()

        let summary = await MigrationAssistant.migrate(from: source, to: target)

        #expect(summary.failures.contains { $0.contains("ContainerIDFile") })
        #expect(target.pulled.isEmpty)
        #expect(target.created.isEmpty)
    }

    @Test func startsRunningContainerImmediatelyWhenNoFixedSourcePortIsOccupied() async {
        let source = MigrationSourceRuntime()
        source.includePublishedPort = false
        let target = MigrationTargetRuntime()

        let summary = await MigrationAssistant.migrate(from: source, to: target)

        #expect(summary.failures.isEmpty)
        #expect(summary.containersMigrated == ["web"])
        #expect(summary.containersAwaitingSourcePorts.isEmpty)
        #expect(target.started == ["new"])
    }

    @Test func removesPartialContainerWhenRestoringRuntimeStateFails() async {
        let source = MigrationSourceRuntime()
        source.includePublishedPort = false
        let target = MigrationTargetRuntime()
        target.failOnStart = true

        let summary = await MigrationAssistant.migrate(from: source, to: target)

        #expect(summary.containersMigrated.isEmpty)
        #expect(summary.failures.count == 1)
        #expect(summary.failures[0].contains("restore state for web"))
        #expect(target.started == ["new"])
        #expect(target.removed == ["new"])
    }

    @Test func retryReplacesOnlyAnExistingContainerOwnedByTheExactMigrationSource() async {
        let source = MigrationSourceRuntime()
        source.includePublishedPort = false
        let target = MigrationTargetRuntime()
        target.snapshotValue = RuntimeSnapshot(containers: [
            Container(
                id: "old-migrated-copy",
                name: "web",
                image: "nginx:alpine",
                status: .stopped,
                cpuPercent: 0,
                memoryDisplay: "0",
                memoryLimitDisplay: "—",
                memoryFraction: 0,
                ports: "",
                uptime: "—",
                created: "now",
                ipAddress: "—",
                domain: "",
                command: "",
                restartPolicy: "no",
                labels: ["dory.migrated.from": "docker", "dory.migrated.source": "docker"]
            ),
        ])

        let summary = await MigrationAssistant.migrate(from: source, to: target)

        #expect(summary.failures.isEmpty)
        #expect(target.removed == ["old-migrated-copy"])
        #expect(summary.containersMigrated == ["web"])
        #expect(target.started == ["new"])
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
        #expect(target.tags.map { "\($0.source)|\($0.repo)|\($0.tag)" } == ["sha256:local|local/web|dev"])
        #expect(summary.imagesImported == ["local/web:dev"])
        #expect(summary.failures.isEmpty)
    }

    @Test func truncatedImageArchiveNeverReachesTheTargetLoaderAsComplete() async {
        let source = ArchiveMigrationSourceRuntime(failArchiveStream: true)
        let target = ArchiveMigrationTargetRuntime()
        target.allowPull = true

        let summary = await MigrationAssistant.migrate(from: source, to: target, recreateContainers: false)

        #expect(target.loadedArchiveChunks.isEmpty)
        #expect(target.pulled == ["local/web:dev"])
        #expect(summary.imagesImported == ["local/web:dev"])
        #expect(summary.failures.isEmpty)
    }

    @Test func additionalTagsReuseTheAlreadyImportedImageWithoutASecondArchive() async {
        let source = ArchiveMigrationSourceRuntime(includeAdditionalReference: true)
        let target = ArchiveMigrationTargetRuntime()

        let summary = await MigrationAssistant.migrate(from: source, to: target, recreateContainers: false)

        #expect(target.loadedArchiveChunks == [["tar:local/web:dev:", "payload"]])
        #expect(target.tags.map { "\($0.source)|\($0.repo)|\($0.tag)" } == [
            "sha256:local|local/web|dev",
            "local/web:dev|local/web|alt",
        ])
        #expect(summary.imagesImported == ["local/web:dev", "local/web:alt"])
        #expect(summary.failures.isEmpty)
    }

    @Test func imageTagCollisionFailsBeforeArchiveOrTargetMutation() async {
        let source = ArchiveMigrationSourceRuntime()
        let target = ArchiveMigrationTargetRuntime()
        target.snapshotValue = RuntimeSnapshot(images: [
            DockerImage(
                repository: "local/web",
                tag: "dev",
                imageID: "sha256:different-content",
                size: "12 MB",
                created: "now",
                usedByCount: 0
            ),
        ])

        let summary = await MigrationAssistant.migrate(from: source, to: target, recreateContainers: false)

        #expect(summary.imagesImported.isEmpty)
        #expect(summary.failures.count == 1)
        #expect(summary.failures[0].contains("already exists with different or unverifiable content"))
        #expect(target.loadedArchiveChunks.isEmpty)
        #expect(target.tags.isEmpty)
        #expect(target.pulled.isEmpty)
    }

    @Test func imageTagCollisionIsVisibleInPreflight() async throws {
        let source = ArchiveMigrationSourceRuntime()
        let target = ArchiveMigrationTargetRuntime()
        target.snapshotValue = RuntimeSnapshot(images: [
            DockerImage(
                repository: "local/web",
                tag: "dev",
                imageID: "sha256:different",
                size: "12 MB",
                created: "now",
                usedByCount: 0
            ),
        ])

        let inventory = try #require(await MigrationAssistant.preflight(from: source, to: target))
        #expect(inventory.isTargetCollisionBlocked)
        #expect(inventory.targetCollisionBlockers.contains {
            $0.contains("image tag local/web:dev")
        })
    }

    @Test func exactExistingTargetImageIsReusedWithoutArchiveMutation() async {
        let source = ArchiveMigrationSourceRuntime()
        let target = ArchiveMigrationTargetRuntime()
        target.snapshotValue = RuntimeSnapshot(images: [
            DockerImage(
                repository: "local/web",
                tag: "dev",
                imageID: "sha256:local",
                size: "12 MB",
                created: "now",
                usedByCount: 0
            ),
        ])

        let summary = await MigrationAssistant.migrate(from: source, to: target, recreateContainers: false)

        #expect(summary.failures.isEmpty)
        #expect(summary.imagesImported == ["local/web:dev"])
        #expect(target.loadedArchiveChunks.isEmpty)
        #expect(target.tags.isEmpty)
        #expect(target.pulled.isEmpty)
    }

    @Test func fullyQualifiedDockerHubTargetTagCannotBypassShortNameCollisionCheck() async {
        let source = ArchiveMigrationSourceRuntime()
        let target = ArchiveMigrationTargetRuntime()
        target.snapshotValue = RuntimeSnapshot(images: [
            DockerImage(
                repository: "docker.io/local/web",
                tag: "dev",
                imageID: "sha256:local",
                size: "12 MB",
                created: "now",
                usedByCount: 0
            ),
        ])

        let summary = await MigrationAssistant.migrate(from: source, to: target, recreateContainers: false)

        #expect(summary.failures.isEmpty)
        #expect(summary.imagesImported == ["local/web:dev"])
        #expect(target.loadedArchiveChunks.isEmpty)
        #expect(target.pulled.isEmpty)
    }

    @Test func identicalPortableImageContractReusesDaemonNormalizedTag() async throws {
        let contract = Data(#"""
        {
          "Architecture":"arm64",
          "Os":"linux",
          "Config":{"Cmd":["true"],"Env":["MODE=test"],"WorkingDir":"/work"},
          "RootFS":{"Type":"layers","Layers":["sha256:layer-a","sha256:layer-b"]}
        }
        """#.utf8)
        let source = ArchiveMigrationSourceRuntime(imageContract: contract)
        let target = ArchiveMigrationTargetRuntime(imageContract: contract)
        target.snapshotValue = RuntimeSnapshot(images: [
            DockerImage(
                repository: "local/web",
                tag: "dev",
                imageID: "sha256:daemon-normalized-id",
                size: "12 MB",
                created: "now",
                usedByCount: 0
            ),
        ])

        let inventory = try #require(await MigrationAssistant.preflight(from: source, to: target))
        #expect(inventory.imagesAlreadyOnDory == 1)
        #expect(inventory.estimatedImageBytes == 0)

        let summary = await MigrationAssistant.migrate(from: source, to: target, recreateContainers: false)
        #expect(summary.failures.isEmpty)
        #expect(summary.imagesImported == ["local/web:dev"])
        #expect(target.loadedArchiveChunks.isEmpty)
        #expect(target.pulled.isEmpty)
    }

    @Test func rewritesBareContentIDWhenTargetDaemonNormalizesLoadedImage() async {
        let source = BareContentMigrationSourceRuntime()
        let target = BareContentMigrationTargetRuntime()
        let portable = "dory-migration/imported:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

        let summary = await MigrationAssistant.migrate(from: source, to: target)

        #expect(summary.failures.isEmpty)
        #expect(summary.imagesImported == [portable])
        #expect(target.tags == [
            "\(source.sourceID)|dory-migration/imported|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "sha256:target-normalized|dory-migration/imported|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        ])
        #expect(target.created.map(\.image) == [portable])
    }

    @Test func recoversContainerWhenOriginalTagAndBaseImageWereDeleted() async throws {
        let source = DeletedBaseImageMigrationSourceRuntime()
        let target = DeletedBaseImageMigrationTargetRuntime()

        let summary = await MigrationAssistant.migrate(from: source, to: target, recreateContainers: false)

        #expect(summary.imagesImported == ["local/recovered:dev"])
        #expect(summary.failures.isEmpty)
        #expect(target.loadAttempts == 3)
        #expect(source.commitCalls.count == 1)
        let commit = try #require(source.commitCalls.first)
        let commitParts = commit.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        #expect(commitParts.count == 5)
        #expect(commitParts[0] == "deleted-base-container")
        #expect(commitParts[1] == "dory-migration-temporary/snapshot")
        #expect(commitParts[2].count == 32)
        #expect(commitParts[3] == "true")
        #expect(commitParts[4] == "false")
        try #require(target.tagAttempts.count == 3)
        #expect(target.tagAttempts[0] == "sha256:source-commit-id|local/recovered|dev")
        #expect(target.tagAttempts[1].hasPrefix("dory-migration-temporary/snapshot:"))
        #expect(target.tagAttempts[1].hasSuffix("|local/recovered|dev"))
        #expect(target.tagAttempts[2] == "targetloaded|local/recovered|dev")
        #expect(source.deletedPaths.count == 1)
        #expect(source.deletedPaths.first?.hasPrefix("/images/dory-migration-temporary%2Fsnapshot:") == true)
        #expect(source.deletedPaths.first?.contains("local%2Frecovered:dev") == false)
    }

    @Test func failedSnapshotCleanupCannotBeHiddenBySuccessfulRegistryFallback() async {
        let source = DeletedBaseImageMigrationSourceRuntime()
        source.cleanupStatus = 500
        let target = DeletedBaseImageMigrationTargetRuntime()
        target.failEveryLoad = true
        target.allowPull = true

        let summary = await MigrationAssistant.migrate(from: source, to: target, recreateContainers: false)

        #expect(target.pulled == ["local/recovered:dev"])
        #expect(summary.failures.contains { $0.contains("cleanup failed source snapshot") })
        #expect(source.deletedPaths.count == 1)
    }

    @Test func staleDanglingTemporarySnapshotIsRemovedByImmutableImageID() async {
        let source = DeletedBaseImageMigrationSourceRuntime()
        source.includeStaleDanglingTemporaryImage = true
        let target = DeletedBaseImageMigrationTargetRuntime()

        let summary = await MigrationAssistant.migrate(from: source, to: target, recreateContainers: false)

        #expect(summary.failures.isEmpty)
        #expect(source.deletedPaths.contains("/images/sha256:stale-temporary-image"))
        #expect(summary.imagesImported == ["local/recovered:dev"])
    }

    @Test func copiesVolumesAndRecreatesContainersWithMountsAndNetworks() async throws {
        let source = VolumeMigrationSourceRuntime()
        let target = VolumeMigrationTargetRuntime()

        let summary = await MigrationAssistant.migrate(from: source, to: target)

        #expect(target.pulled == ["postgres:16"])
        #expect(target.networksCreated == ["shop_default"])
        let networkBody = try #require(target.networkCreateBodies.first)
        #expect(networkBody["Driver"] as? String == "bridge")
        #expect(networkBody["Attachable"] as? Bool == true)
        #expect(networkBody["EnableIPv4"] as? Bool == true)
        let ipam = try #require(networkBody["IPAM"] as? [String: Any])
        let ipamConfig = try #require(ipam["Config"] as? [[String: Any]])
        #expect(ipamConfig.first?["Subnet"] as? String == "172.30.44.0/24")
        #expect(ipamConfig.first?["Gateway"] as? String == "172.30.44.1")
        let networkLabels = try #require(networkBody["Labels"] as? [String: Any])
        #expect(networkLabels["dory.migrated.source"] as? String == "docker")
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
        #expect(source.helperRemoved)
        #expect(target.helperRemoved)
    }

    @Test func stoppedContainerWritableLayerIsSnapshottedAndUsedForRecreation() async throws {
        let source = VolumeMigrationSourceRuntime()
        source.writableLayerBytes = 4096
        let target = VolumeMigrationTargetRuntime()

        let inventory = try #require(await MigrationAssistant.preflight(from: source, to: target))
        #expect(inventory.estimatedContainerWritableBytes == 4096)
        #expect(inventory.runningWritableLayerContainers.isEmpty)

        let summary = await MigrationAssistant.migrate(from: source, to: target)

        #expect(summary.failures.isEmpty)
        #expect(source.writableSnapshotCommits.count == 1)
        #expect(source.writableSnapshotCommits.first?.hasPrefix("c1|dory-migration-temporary/snapshot:") == true)
        #expect(source.writableSnapshotCommits.first?.hasSuffix("|true|false") == true)
        #expect(target.loadedWritableSnapshots.count == 1)
        let tag = try #require(target.writableSnapshotTags.first)
        #expect(tag.hasPrefix("sha256:writable-snapshot|dory-migration/container-snapshot:"))
        #expect(target.created.first?.image == String(tag.split(separator: "|", maxSplits: 1)[1]))
        #expect(summary.containersMigrated == ["db"])
        #expect(source.deletedImageReferences.count == 1)
    }

    @Test func writableSnapshotUsesArchiveTagWhenOrbStackAndDoryImageIDsDiffer() async throws {
        let source = VolumeMigrationSourceRuntime()
        source.writableLayerBytes = 4096
        let target = VolumeMigrationTargetRuntime()
        target.normalizeWritableSnapshotID = true

        let summary = await MigrationAssistant.migrate(from: source, to: target)

        #expect(summary.failures.isEmpty)
        #expect(summary.volumesCopied == ["db-data"])
        #expect(summary.networksCreated == ["shop_default"])
        #expect(summary.containersMigrated == ["db"])
        try #require(target.writableSnapshotTags.count == 2)
        #expect(target.writableSnapshotTags[0].hasPrefix(
            "sha256:writable-snapshot|dory-migration/container-snapshot:"
        ))
        #expect(target.writableSnapshotTags[1].hasPrefix(
            "dory-migration-temporary/snapshot:"
        ))
        #expect(target.writableSnapshotTags[1].contains(
            "|dory-migration/container-snapshot:"
        ))
    }

    @Test func failedWritableSnapshotReplacementRestoresPriorOwnedReference() async throws {
        let source = VolumeMigrationSourceRuntime()
        source.writableLayerBytes = 4096
        let target = VolumeMigrationTargetRuntime()
        target.failWritableSnapshotBinding = true
        let finalReference = MigrationAssistant.containerSnapshotReference(
            sourceIdentifier: source.migrationSourceIdentifier,
            containerID: "c1"
        )
        let finalSplit = DockerRegistry.splitImageRef(finalReference)
        let priorImageID = "sha256:prior-writable-snapshot"
        target.snapshotValue = RuntimeSnapshot(images: [
            DockerImage(
                repository: finalSplit.repo,
                tag: finalSplit.tag,
                imageID: priorImageID,
                size: "4 KB",
                created: "now",
                usedByCount: 1,
                labels: [
                    "dory.migration.container-snapshot": "true",
                    "dory.migration.container-id": "c1",
                    "dory.migrated.source": source.migrationSourceIdentifier,
                ]
            ),
        ])
        let rollbackReference = finalReference.replacingOccurrences(
            of: "dory-migration/container-snapshot:",
            with: "dory-migration/container-rollback:"
        )

        let summary = await MigrationAssistant.migrate(from: source, to: target)

        #expect(summary.failures.contains { $0.contains("injectedSnapshotBindFailure") })
        #expect(summary.containersMigrated.isEmpty)
        #expect(target.created.isEmpty)
        #expect(target.volumesCreated.isEmpty)
        try #require(target.writableSnapshotTags.count == 4)
        #expect(target.writableSnapshotTags[0] == "\(priorImageID)|\(rollbackReference)")
        #expect(target.writableSnapshotTags[1] == "sha256:writable-snapshot|\(finalReference)")
        #expect(target.writableSnapshotTags[2].hasPrefix(
            "dory-migration-temporary/snapshot:"
        ))
        #expect(target.writableSnapshotTags[2].hasSuffix("|\(finalReference)"))
        #expect(target.writableSnapshotTags[3] == "\(priorImageID)|\(finalReference)")
        #expect(target.deletedImagePaths.contains(
            "/images/\(DockerImageOps.pathComponent(rollbackReference))"
        ))
    }

    @Test func reservedWritableSnapshotReferenceCollisionBlocksBeforeBaseImages() async throws {
        let source = VolumeMigrationSourceRuntime()
        source.writableLayerBytes = 4096
        let target = VolumeMigrationTargetRuntime()
        let reference = MigrationAssistant.containerSnapshotReference(
            sourceIdentifier: source.migrationSourceIdentifier,
            containerID: "c1"
        )
        let split = DockerRegistry.splitImageRef(reference)
        target.snapshotValue = RuntimeSnapshot(images: [
            DockerImage(
                repository: split.repo,
                tag: split.tag,
                imageID: "sha256:unowned",
                size: "4 KB",
                created: "now",
                usedByCount: 0
            ),
        ])

        let inventory = try #require(await MigrationAssistant.preflight(from: source, to: target))
        #expect(inventory.isTargetCollisionBlocked)
        #expect(inventory.targetCollisionBlockers.contains { $0.contains("writable-layer snapshot reference") })

        let summary = await MigrationAssistant.migrate(from: source, to: target)
        #expect(summary.failures.contains { $0.contains("not owned by this source container") })
        #expect(target.pulled.isEmpty)
        #expect(target.loadedWritableSnapshots.isEmpty)
    }

    @Test func reservedWritableRollbackReferenceCollisionBlocksBeforeBaseImages() async throws {
        let source = VolumeMigrationSourceRuntime()
        source.writableLayerBytes = 4096
        let target = VolumeMigrationTargetRuntime()
        let finalReference = MigrationAssistant.containerSnapshotReference(
            sourceIdentifier: source.migrationSourceIdentifier,
            containerID: "c1"
        )
        let rollbackReference = finalReference.replacingOccurrences(
            of: "dory-migration/container-snapshot:",
            with: "dory-migration/container-rollback:"
        )
        let rollbackSplit = DockerRegistry.splitImageRef(rollbackReference)
        target.snapshotValue = RuntimeSnapshot(images: [
            DockerImage(
                repository: rollbackSplit.repo,
                tag: rollbackSplit.tag,
                imageID: "sha256:unowned-rollback",
                size: "4 KB",
                created: "now",
                usedByCount: 0
            ),
        ])

        let inventory = try #require(await MigrationAssistant.preflight(from: source, to: target))
        #expect(inventory.isTargetCollisionBlocked)
        #expect(inventory.targetCollisionBlockers.contains { $0.contains("writable-layer rollback reference") })

        let summary = await MigrationAssistant.migrate(from: source, to: target)
        #expect(summary.failures.contains { $0.contains("reserved rollback image reference") })
        #expect(target.pulled.isEmpty)
        #expect(target.loadedWritableSnapshots.isEmpty)
    }

    @Test func contentIDImageFallbackUsesAnExistingSourceReferenceForVolumeCopy() async {
        let source = DeletedTagVolumeMigrationSourceRuntime()
        let target = DeletedTagVolumeMigrationTargetRuntime()

        let summary = await MigrationAssistant.migrate(from: source, to: target, recreateContainers: false)

        #expect(summary.failures.isEmpty)
        #expect(summary.imagesImported == ["local/orphaned:dev"])
        #expect(summary.volumesCopied == ["orphan-data"])
        #expect(target.loadReferences == ["local/orphaned:dev", "sha256:orphan-content"])
        #expect(target.tagged == [
            "sha256:orphan-content|local/orphaned|dev",
            "target-normalized|local/orphaned|dev",
        ])
        #expect(source.helperImages == ["sha256:orphan-content"])
        #expect(target.helperImages == ["local/orphaned:dev"])
        #expect(target.copiedVolumeData == "orphan-volume-data")
    }

    @Test func volumeCopyFallsThroughWhenTheFirstPulledImageTagVanishedOnTheSource() async {
        let source = VolumeMigrationSourceRuntime()
        source.includeUnavailableHelperImage = true
        let target = VolumeMigrationTargetRuntime()

        let summary = await MigrationAssistant.migrate(from: source, to: target, recreateContainers: false)

        #expect(summary.failures.isEmpty)
        #expect(summary.volumesCopied == ["db-data"])
        #expect(source.helperImages == ["gone:latest", "postgres:16"])
        #expect(source.helperCreated)
        #expect(source.helperRemoved)
        #expect(target.helperCreated)
        #expect(target.helperRemoved)
    }

    @Test func truncatedVolumeArchiveRemovesPartialTargetAndSkipsContainers() async {
        let source = VolumeMigrationSourceRuntime()
        source.failCopyOut = true
        let target = VolumeMigrationTargetRuntime()

        let summary = await MigrationAssistant.migrate(from: source, to: target)

        #expect(summary.volumesCopied.isEmpty)
        #expect(summary.containersMigrated.isEmpty)
        #expect(!summary.failures.isEmpty)
        #expect(target.volumesCreated == ["db-data"])
        #expect(target.volumesRemoved == ["db-data"])
        #expect(target.created.isEmpty)
        #expect(source.helperRemoved)
        #expect(target.helperRemoved)
    }

    @Test func sourceStateChangeAfterVolumeCopyPreventsContainerRecreation() async {
        let source = VolumeMigrationSourceRuntime()
        source.changeContainerStateOnRefresh = true
        let target = VolumeMigrationTargetRuntime()

        let summary = await MigrationAssistant.migrate(from: source, to: target)

        #expect(summary.failures.contains { $0.contains("changed during import") })
        #expect(summary.volumesCopied == ["db-data"])
        #expect(summary.containersMigrated.isEmpty)
        #expect(target.created.isEmpty)
    }

    @Test func retryCleansOnlyStaleHelpersOwnedByTheExactSource() async {
        let source = VolumeMigrationSourceRuntime()
        source.includeStaleHelper = true
        let target = VolumeMigrationTargetRuntime()
        target.snapshotValue = RuntimeSnapshot(containers: [
            Container(
                id: "stale-target-helper",
                name: "stale-target-helper",
                image: "postgres:16",
                status: .stopped,
                cpuPercent: 0,
                memoryDisplay: "0",
                memoryLimitDisplay: "—",
                memoryFraction: 0,
                ports: "",
                uptime: "—",
                created: "now",
                ipAddress: "—",
                domain: "",
                command: "true",
                restartPolicy: "no",
                labels: ["dory.migration.temporary": "true", "dory.migrated.source": "docker"]
            ),
        ])

        let summary = await MigrationAssistant.migrate(from: source, to: target, recreateContainers: false)

        #expect(summary.failures.isEmpty)
        #expect(source.staleHelpersRemoved == ["stale-source-helper"])
        #expect(target.staleHelpersRemoved == ["stale-target-helper"])
        #expect(summary.volumesCopied == ["db-data"])
    }

    @Test func resumesOnlyDoryOwnedPartialVolumeAndNetworkImports() async {
        let source = VolumeMigrationSourceRuntime()
        let target = VolumeMigrationTargetRuntime()
        target.snapshotValue = RuntimeSnapshot(
            volumes: [
                Volume(name: "db-data", size: "—", driver: "local", usedBy: "—", created: "now",
                       labels: ["dory.migrated.from": "docker", "dory.migrated.source": "docker"]),
            ],
            networks: [
                DoryNetwork(name: "shop_default", driver: "bridge", scope: "local", subnet: "", containerCount: 0,
                            labels: ["dory.migrated.from": "docker", "dory.migrated.source": "docker"]),
            ]
        )

        let summary = await MigrationAssistant.migrate(from: source, to: target)

        #expect(target.volumesRemoved == ["db-data"])
        #expect(target.volumesCreated == ["db-data"])
        #expect(target.networksCreated.isEmpty)
        #expect(summary.volumesCopied == ["db-data"])
        #expect(summary.networksCreated == ["shop_default"])
        #expect(summary.failures.isEmpty)
    }

    @Test func upgradesOnlyEmptyDetachedArtifactsFromTheLegacyMigrationLabel() async {
        let source = VolumeMigrationSourceRuntime()
        let target = VolumeMigrationTargetRuntime()
        target.targetVolumeSizes = ["db-data": 0]
        target.snapshotValue = RuntimeSnapshot(
            volumes: [
                Volume(name: "db-data", size: "0 B", driver: "local", usedBy: "—", created: "now",
                       labels: ["dory.migrated.from": "docker"]),
            ],
            networks: [
                DoryNetwork(name: "shop_default", driver: "bridge", scope: "local", subnet: "", containerCount: 0,
                            labels: ["dory.migrated.from": "docker"]),
            ]
        )

        let summary = await MigrationAssistant.migrate(from: source, to: target)

        #expect(summary.failures.isEmpty)
        #expect(summary.warnings.contains { $0.contains("empty detached volume db-data") })
        #expect(summary.warnings.contains { $0.contains("detached network shop_default") })
        #expect(target.volumesRemoved == ["db-data"])
        #expect(target.volumesCreated == ["db-data"])
        #expect(target.networksRemoved == ["shop_default"])
        #expect(summary.volumesCopied == ["db-data"])
        #expect(summary.networksCreated == ["shop_default"])
        #expect(summary.containersMigrated == ["db"])
    }

    @Test func failedLegacyNetworkReplacementRestoresOriginalContractAndLabels() async {
        let source = VolumeMigrationSourceRuntime()
        let target = VolumeMigrationTargetRuntime()
        target.networkCreateFailuresRemaining = 1
        target.snapshotValue = RuntimeSnapshot(networks: [
            DoryNetwork(
                name: "shop_default",
                driver: "bridge",
                scope: "local",
                subnet: "172.30.44.0/24",
                containerCount: 0,
                labels: ["dory.migrated.from": "docker", "target.keep": "yes"]
            ),
        ])

        let summary = await MigrationAssistant.migrate(from: source, to: target)

        #expect(summary.failures.contains { $0.contains("original detached target network was restored") })
        #expect(target.pulled.isEmpty)
        #expect(target.networksRemoved == ["shop_default", "shop_default"])
        #expect(target.networksCreated == ["shop_default"])
        let restoredLabels = target.networkCreateBodies.last?["Labels"] as? [String: String]
        #expect(restoredLabels == ["dory.migrated.from": "docker", "target.keep": "yes"])
    }

    @Test func adoptsEmptyDetachedUnownedVolumeWithoutLosingItsLabels() async {
        let source = VolumeMigrationSourceRuntime()
        let target = VolumeMigrationTargetRuntime()
        target.targetVolumeSizes = ["db-data": 0]
        target.snapshotValue = RuntimeSnapshot(volumes: [
            Volume(
                name: "db-data",
                size: "0 B",
                driver: "local",
                usedBy: "—",
                created: "now",
                labels: ["target.keep": "yes"]
            ),
        ])

        let summary = await MigrationAssistant.migrate(from: source, to: target)

        #expect(summary.failures.isEmpty)
        #expect(summary.warnings.contains { $0.contains("empty detached target volume db-data") })
        #expect(target.volumesRemoved == ["db-data"])
        #expect(target.volumesCreated == ["db-data"])
        #expect(target.createdVolumeLabels["db-data"]?["target.keep"] == "yes")
        #expect(target.createdVolumeLabels["db-data"]?["dory.migrated.from"] == "docker")
        #expect(target.createdVolumeLabels["db-data"]?["dory.migrated.source"] == "docker")
        #expect(summary.volumesCopied == ["db-data"])
        #expect(summary.containersMigrated == ["db"])
    }

    @Test func failedCopyRestoresAdoptedEmptyTargetVolumeMetadata() async {
        let source = VolumeMigrationSourceRuntime()
        source.failCopyOut = true
        let target = VolumeMigrationTargetRuntime()
        target.targetVolumeSizes = ["db-data": 0]
        target.snapshotValue = RuntimeSnapshot(volumes: [
            Volume(
                name: "db-data",
                size: "0 B",
                driver: "local",
                usedBy: "—",
                created: "now",
                labels: ["target.keep": "yes"]
            ),
        ])

        let summary = await MigrationAssistant.migrate(from: source, to: target)

        #expect(summary.volumesCopied.isEmpty)
        #expect(summary.containersMigrated.isEmpty)
        #expect(summary.failures.contains { $0.contains("original empty target volume was restored") })
        #expect(target.volumesRemoved == ["db-data", "db-data"])
        #expect(target.volumesCreated == ["db-data", "db-data"])
        #expect(target.createdVolumeLabels["db-data"] == ["target.keep": "yes"])
    }

    @Test func emptyUnownedVolumeAttachedToTargetContainerIsNeverAdopted() async {
        let source = VolumeMigrationSourceRuntime()
        let target = VolumeMigrationTargetRuntime()
        target.targetVolumeSizes = ["db-data": 0]
        target.snapshotValue = RuntimeSnapshot(
            containers: [
                Container(
                    id: "target-user",
                    name: "target-user",
                    image: "busybox",
                    status: .stopped,
                    cpuPercent: 0,
                    memoryDisplay: "0",
                    memoryLimitDisplay: "—",
                    memoryFraction: 0,
                    ports: "",
                    uptime: "—",
                    created: "now",
                    ipAddress: "—",
                    domain: "",
                    command: "true",
                    restartPolicy: "no",
                    mounts: [ContainerMount(type: "volume", source: "db-data", target: "/data")]
                ),
            ],
            volumes: [
                Volume(name: "db-data", size: "0 B", driver: "local", usedBy: "target-user", created: "now"),
            ]
        )

        let summary = await MigrationAssistant.migrate(from: source, to: target)

        #expect(summary.failures.contains { $0.contains("non-migration") })
        #expect(target.volumesRemoved.isEmpty)
        #expect(target.volumesCreated.isEmpty)
        #expect(target.pulled.isEmpty)
    }

    @Test func legacyMigrationVolumeWithDataIsNeverReplacedAutomatically() async {
        let source = VolumeMigrationSourceRuntime()
        let target = VolumeMigrationTargetRuntime()
        target.targetVolumeSizes = ["db-data": 4096]
        target.snapshotValue = RuntimeSnapshot(volumes: [
            Volume(name: "db-data", size: "4 KB", driver: "local", usedBy: "—", created: "now",
                   labels: ["dory.migrated.from": "docker"]),
        ])

        let summary = await MigrationAssistant.migrate(from: source, to: target)

        #expect(summary.failures.contains { $0.contains("contains data, is attached, or could not be measured") })
        #expect(target.volumesRemoved.isEmpty)
        #expect(target.volumesCreated.isEmpty)
        #expect(target.pulled.isEmpty)
    }

    @Test func refusesOwnedPartialNetworkWhenPreservedContractDoesNotMatch() async {
        let source = VolumeMigrationSourceRuntime()
        let target = VolumeMigrationTargetRuntime()
        target.inspectedNetworkSubnet = "172.30.99.0/24"
        target.snapshotValue = RuntimeSnapshot(networks: [
            DoryNetwork(name: "shop_default", driver: "bridge", scope: "local", subnet: "", containerCount: 0,
                        labels: ["dory.migrated.from": "docker", "dory.migrated.source": "docker"]),
        ])

        let summary = await MigrationAssistant.migrate(from: source, to: target, recreateContainers: false)

        #expect(summary.networksCreated.isEmpty)
        #expect(summary.failures.contains { $0.contains("different or unverifiable driver/IPAM/options contract") })
        #expect(target.pulled.isEmpty)
        #expect(target.volumesCreated.isEmpty)
    }

    @Test func refusesOwnedPartialVolumeWithDifferentDriverBeforeTargetMutation() async {
        let source = VolumeMigrationSourceRuntime()
        let target = VolumeMigrationTargetRuntime()
        target.snapshotValue = RuntimeSnapshot(volumes: [
            Volume(name: "db-data", size: "—", driver: "nfs", usedBy: "—", created: "now",
                   labels: ["dory.migrated.from": "docker", "dory.migrated.source": "docker"]),
        ])

        let summary = await MigrationAssistant.migrate(from: source, to: target, recreateContainers: false)

        #expect(summary.failures.contains { $0.contains("different driver/options contract") })
        #expect(target.pulled.isEmpty)
        #expect(target.archiveChunks.isEmpty)
        #expect(target.networksCreated.isEmpty)
    }

    @Test func overlappingTargetSubnetFailsBeforeImagesOrNetworksAreChanged() async {
        let source = VolumeMigrationSourceRuntime()
        let target = VolumeMigrationTargetRuntime()
        target.snapshotValue = RuntimeSnapshot(networks: [
            DoryNetwork(
                name: "existing-target-network",
                driver: "bridge",
                scope: "local",
                subnet: "172.30.44.128/25",
                containerCount: 1
            ),
        ])

        let summary = await MigrationAssistant.migrate(from: source, to: target, recreateContainers: false)

        #expect(summary.failures.contains { $0.contains("overlaps target network") })
        #expect(target.pulled.isEmpty)
        #expect(target.networksCreated.isEmpty)
        #expect(target.volumesCreated.isEmpty)
    }

    @Test func nativeIPv6NetworkContractIsPreserved() async throws {
        let source = VolumeMigrationSourceRuntime()
        source.networkEnableIPv6 = true
        let target = VolumeMigrationTargetRuntime()

        let summary = await MigrationAssistant.migrate(from: source, to: target, recreateContainers: false)

        #expect(summary.failures.isEmpty)
        #expect(summary.networksCreated == ["shop_default"])
        let body = try #require(target.networkCreateBodies.first)
        #expect(body["EnableIPv6"] as? Bool == true)
    }

    @Test func hostOrRemoteBackedLocalVolumeFailsBeforeImagesAreChanged() async {
        let source = VolumeMigrationSourceRuntime()
        source.volumeOptions = ["type": "nfs", "device": ":/database"]
        let target = VolumeMigrationTargetRuntime()

        let summary = await MigrationAssistant.migrate(from: source, to: target, recreateContainers: false)

        #expect(summary.failures.contains { $0.contains("host/remote storage") })
        #expect(target.pulled.isEmpty)
        #expect(target.volumesCreated.isEmpty)
    }

    @Test func reportsVolumeHelperCleanupFailureAfterBytesWereCopied() async {
        let source = VolumeMigrationSourceRuntime()
        let target = VolumeMigrationTargetRuntime()
        target.helperCleanupStatus = 500

        let summary = await MigrationAssistant.migrate(from: source, to: target, recreateContainers: false)

        #expect(summary.volumesCopied.isEmpty)
        #expect(summary.failures.contains { $0.contains("temporary helper cleanup failed") })
        #expect(source.helperRemoved)
        #expect(target.helperRemoved)
    }

    @Test func refusesToOverwriteUnownedTargetVolumesAndNetworks() async {
        let source = VolumeMigrationSourceRuntime()
        let target = VolumeMigrationTargetRuntime()
        target.snapshotValue = RuntimeSnapshot(
            volumes: [
                Volume(name: "db-data", size: "—", driver: "local", usedBy: "user", created: "now"),
            ],
            networks: [
                DoryNetwork(name: "shop_default", driver: "bridge", scope: "local", subnet: "", containerCount: 1),
            ]
        )

        let summary = await MigrationAssistant.migrate(from: source, to: target)

        #expect(target.volumesCreated.isEmpty)
        #expect(target.networksCreated.isEmpty)
        #expect(target.archiveChunks.isEmpty)
        #expect(summary.failures.contains { $0.contains("different-source volume") })
        #expect(summary.failures.contains { $0.contains("different-source network") })
    }

    @Test func liveOwnedOrbStackToDoryMigrationPreservesDataDefinitionAndState() async throws {
        let environment = ProcessInfo.processInfo.environment
        let defaultLiveMarker = "/private/tmp/dev.dory.live-orbstack-migration-test-\(getuid())"
        let liveMarker = environment["DORY_LIVE_ORBSTACK_MIGRATION_MARKER"]
            ?? defaultLiveMarker
        guard environment["DORY_LIVE_ORBSTACK_MIGRATION"] == "1"
                || FileManager.default.fileExists(atPath: liveMarker) else { return }
        let markerFields = (try? String(contentsOfFile: liveMarker, encoding: .utf8))?
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init) ?? []
        let baseImage = environment["DORY_LIVE_MIGRATION_BASE_IMAGE"]
            ?? (markerFields.first?.isEmpty == false ? markerFields[0] : "alpine:3.20")
        let sourceSocket = environment["DORY_LIVE_SOURCE_SOCKET"]
            ?? (markerFields.count > 1 && !markerFields[1].isEmpty
                ? markerFields[1]
                : NSHomeDirectory() + "/.orbstack/run/docker.sock")
        let targetSocket = environment["DORY_LIVE_TARGET_SOCKET"]
            ?? (markerFields.count > 2 && !markerFields[2].isEmpty
                ? markerFields[2]
                : NSHomeDirectory() + "/.dory/dory.sock")
        try #require(FileManager.default.fileExists(atPath: sourceSocket))
        try #require(FileManager.default.fileExists(atPath: targetSocket))

        let source = DockerEngineRuntime(socketPath: sourceSocket, displayName: "OrbStack live fixture")
        let target = DockerEngineRuntime(socketPath: targetSocket, displayName: "Dory live fixture")
        let sourceBefore = try await source.snapshot()
        let targetBefore = try await target.snapshot()
        let occupiedSubnets = Set((sourceBefore.networks + targetBefore.networks).map(\.subnet))
        let networkOctet = try #require((40...239).first { octet in
            !occupiedSubnets.contains("172.31.\(octet).0/24")
        })
        let networkSubnet = "172.31.\(networkOctet).0/24"
        let networkGateway = "172.31.\(networkOctet).1"
        let suffix = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(10)
        let name = "dory-migration-live-\(suffix)"
        let stoppedName = "\(name)-stopped"
        let seedName = "\(name)-seed"
        let volumeName = "\(name)-data"
        let secondaryVolumeName = "\(name)-secondary"
        let networkName = "\(name)-net"
        let imageRepository = "dory-migration-fixture"
        let imageTag = String(suffix)
        let imageReference = "\(imageRepository):\(imageTag)"
        let marker = "migration-payload-\(suffix)"
        let allocatedHostPort = AppStore.allocateFreePort()
        let fixedHostPort = try #require(allocatedHostPort > 0 ? allocatedHostPort : nil)
        var sourceContainerID: String?
        var stoppedSourceContainerID: String?
        var targetFixtureImageIDs = Set<String>()
        let targetBaselineImageIDs = Set(targetBefore.images.map(\.imageID))
        let operationHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-live-migration-operation-\(suffix)")
        try FileManager.default.createDirectory(
            at: operationHome,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: operationHome) }

        func networkContract(_ runtime: DockerEngineRuntime, name: String) async throws -> Data {
            let response = try #require(await runtime.proxyRequest(
                method: "GET",
                path: "/networks/\(DockerImageOps.pathComponent(name))",
                headers: [(name: "Accept", value: "application/json")],
                body: Data()
            ))
            let root = try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
            let keys = [
                "Driver", "Internal", "Attachable", "Ingress", "IPAM", "EnableIPv4", "EnableIPv6",
                "Options", "ConfigOnly", "ConfigFrom",
            ]
            let contract = Dictionary(uniqueKeysWithValues: keys.compactMap { key -> (String, Any)? in
                guard let value = root[key], !(value is NSNull) else { return nil }
                return (key, value)
            })
            return try JSONSerialization.data(withJSONObject: contract, options: [.sortedKeys])
        }

        func cleanup() async {
            for runtime in [target, source] {
                if let snapshot = try? await runtime.snapshot() {
                    for container in snapshot.containers where container.name == name || container.name == stoppedName || container.name == seedName {
                        try? await runtime.remove(containerID: container.id)
                    }
                }
                try? await runtime.removeVolume(name: volumeName)
                try? await runtime.removeVolume(name: secondaryVolumeName)
                try? await runtime.removeNetwork(name: networkName)
                try? await runtime.removeImage(id: imageReference)
            }
            // Containerd can reject deleting a base manifest until its writable-layer children
            // are gone. Retry this exact, operation-captured ID set; never prune unrelated images.
            for _ in 0..<3 {
                for imageID in targetFixtureImageIDs.sorted() {
                    try? await target.removeImage(id: imageID)
                }
            }
            // A failed import can load the source archive's original RepoTag before the
            // coordinator has returned its receipt. Remove it after writable-layer children,
            // and only when the image was not present in the target baseline.
            if let snapshot = try? await target.snapshot() {
                let fixtureReferences = Set([baseImage, imageReference].map {
                    MigrationOperationPlanBuilder.canonicalImageReference($0)
                })
                for image in snapshot.images where !targetBaselineImageIDs.contains(image.imageID) {
                    let references = Set(MigrationOperationPlanBuilder.imageReferences(image))
                    guard !references.isDisjoint(with: fixtureReferences) else { continue }
                    try? await target.removeImage(id: image.imageID)
                }
            }
        }

        do {
            try await source.tagImage(source: baseImage, repo: imageRepository, tag: imageTag)
            try await source.createVolume(
                name: volumeName,
                driver: "local",
                labels: ["dory.test.owner": name],
                driverOptions: [:]
            )
            try await source.createVolume(
                name: secondaryVolumeName,
                driver: "local",
                labels: ["dory.test.owner": name],
                driverOptions: [:]
            )
            let createNetworkBody = try JSONSerialization.data(withJSONObject: [
                "Name": networkName,
                "Driver": "bridge",
                "CheckDuplicate": true,
                "EnableIPv4": true,
                "EnableIPv6": false,
                "Attachable": true,
                "IPAM": [
                    "Driver": "default",
                    "Config": [["Subnet": networkSubnet, "Gateway": networkGateway]],
                ],
                "Labels": ["dory.test.owner": name],
            ])
            let createdNetwork = try #require(await source.proxyRequest(
                method: "POST",
                path: "/networks/create",
                headers: [(name: "Content-Type", value: "application/json")],
                body: createNetworkBody
            ))
            #expect(createdNetwork.isSuccess)
            let seedContainerID = try await source.create(ContainerSpec(
                name: seedName,
                image: imageReference,
                command: ["sh", "-c", "set -eu; printf '%s' '\(marker)' > /fixture/payload; chown 999:999 /fixture/payload; chmod 600 /fixture/payload; ln -s payload /fixture/payload-link; ln /fixture/payload /fixture/payload-hardlink; dd if=/dev/zero of=/fixture/large.bin bs=1048576 count=64 2>/dev/null; cd /fixture; sha256sum large.bin > large.sha256; printf '%s' 'secondary-\(marker)' > /secondary/payload"],
                labels: ["dory.test.owner": name],
                networks: [networkName],
                mounts: [
                    ContainerMount(type: "volume", source: volumeName, target: "/fixture"),
                    ContainerMount(type: "volume", source: secondaryVolumeName, target: "/secondary"),
                ]
            ))
            try await source.start(containerID: seedContainerID)
            var seedExitCode: Int?
            for _ in 0..<40 {
                let seedSnapshot = try? await source.snapshot()
                if seedSnapshot?.containers.first(where: { $0.id == seedContainerID })?.status == .stopped {
                    seedExitCode = await source.containerExitCode(seedContainerID)
                    break
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            #expect(seedExitCode == 0)
            try await source.remove(containerID: seedContainerID)

            sourceContainerID = try await source.create(ContainerSpec(
                name: name,
                image: imageReference,
                command: ["sh", "-c", "sleep 600"],
                environment: ["DORY_MIGRATION_MARKER": marker],
                ports: ["127.0.0.1:\(fixedHostPort):5432"],
                labels: ["dory.test.owner": name],
                networks: [networkName],
                restart: "unless-stopped",
                hostname: "migration-fixture",
                workingDir: "/",
                privileged: true,
                healthcheck: DockerHealthConfig(
                    Test: ["CMD", "true"],
                    Interval: 1_000_000_000,
                    Timeout: 1_000_000_000,
                    Retries: 3
                )
            ))
            try await source.start(containerID: sourceContainerID!)
            stoppedSourceContainerID = try await source.create(ContainerSpec(
                name: stoppedName,
                image: imageReference,
                command: [
                    "sh", "-c",
                    "if [ -f /writable-layer-marker ]; then exec sleep 600; else printf '%s' 'layer-\(marker)' > /writable-layer-marker; exit 42; fi",
                ],
                environment: ["DORY_MIGRATION_STATE": "stopped"],
                labels: ["dory.test.owner": name],
                networks: [networkName],
                restart: "no",
                mounts: [
                    ContainerMount(type: "volume", source: volumeName, target: "/fixture"),
                    ContainerMount(type: "volume", source: secondaryVolumeName, target: "/secondary"),
                ]
            ))
            try await source.start(containerID: stoppedSourceContainerID!)
            var writableLayerSeedExit: Int?
            for _ in 0..<40 {
                let writableSeedSnapshot = try? await source.snapshot()
                if writableSeedSnapshot?.containers.first(where: { $0.id == stoppedSourceContainerID })?.status == .stopped {
                    writableLayerSeedExit = await source.containerExitCode(stoppedSourceContainerID!)
                    break
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            #expect(writableLayerSeedExit == 42)

            // Reproduce a common long-lived Docker/OrbStack state: the container still references
            // the name it was created with, but that RepoTag has since been removed. Migration must
            // archive by the immutable ImageID and restore the original reference on Dory.
            let untag = await source.proxyRequest(
                method: "DELETE",
                path: "/images/\(DockerImageOps.pathComponent(imageReference))",
                headers: [],
                body: Data()
            )
            #expect(untag?.isSuccess == true)

            // Quiesce the owned container before reading migration inventory. Pausing retains its
            // published host port, so the fixture still proves fixed-port deferral, while matching
            // production's fail-closed rule for nonzero writable layers on running containers.
            try await source.pause(containerID: sourceContainerID!)

            let raw = try await source.snapshot()
            let sourceContainer = try #require(raw.containers.first { $0.id == sourceContainerID })
            let stoppedSourceContainer = try #require(raw.containers.first { $0.id == stoppedSourceContainerID })
            let sourceVolume = try #require(raw.volumes.first { $0.name == volumeName })
            let secondarySourceVolume = try #require(raw.volumes.first { $0.name == secondaryVolumeName })
            let sourceNetwork = try #require(raw.networks.first { $0.name == networkName })
            let sourceNetworkContract = try await networkContract(source, name: networkName)
            let sourceImageID = try #require(sourceContainer.sourceImageID)
            let sourceImage = try #require(raw.images.first {
                MigrationImageTransferExecution.canonicalImageID($0.imageID)
                    == MigrationImageTransferExecution.canonicalImageID(sourceImageID)
            })
            let filtered = FilteredLiveMigrationSource(base: source, inventory: RuntimeSnapshot(
                containers: [sourceContainer, stoppedSourceContainer],
                images: [sourceImage],
                volumes: [sourceVolume, secondarySourceVolume],
                networks: [sourceNetwork],
                engineRunning: raw.engineRunning,
                engineVersion: raw.engineVersion
            ), fixtureOwner: name)
            let helperArchive = try #require(
                environment["DORY_LIVE_MIGRATION_HELPER_ARCHIVE"]
                    ?? (markerFields.count > 3 && !markerFields[3].isEmpty
                        ? markerFields[3]
                        : nil)
            )
            let helperMetadata = try #require(
                environment["DORY_LIVE_MIGRATION_HELPER_METADATA"]
                    ?? (markerFields.count > 4 && !markerFields[4].isEmpty
                        ? markerFields[4]
                        : nil)
            )
            let helper = try MigrationTransferHelperAsset(
                archive: Data(contentsOf: URL(fileURLWithPath: helperArchive)),
                metadataData: Data(contentsOf: URL(fileURLWithPath: helperMetadata))
            )
            let availableBytes = try #require(
                (try FileManager.default.attributesOfFileSystem(
                    forPath: operationHome.path
                )[.systemFreeSize] as? NSNumber)?.int64Value
            )
            let prepared = try await MigrationStrictInventoryCollector.collect(
                from: filtered,
                to: target,
                availableHostBytes: availableBytes,
                sharedHome: operationHome.path,
                transferHelper: MigrationTransferHelperContract(metadata: helper.metadata)
            )
            let summary = try await MigrationImportCoordinator.execute(
                prepared: prepared,
                environment: MigrationImportExecutionEnvironment(
                    source: filtered,
                    target: target,
                    journalStore: try DoryOperationJournalStore(home: operationHome.path),
                    currentAvailableHostBytes: availableBytes,
                    transferHelper: MigrationTransferHelperContract(metadata: helper.metadata),
                    transfers: MigrationImportLiveAssetTransfers(helperAsset: helper),
                    sharedHome: operationHome.path,
                    hostArchitecture: "arm64"
                )
            )
            #expect(summary.failures.isEmpty)
            #expect(summary.imagesImported.count == 1)
            #expect(summary.volumesCopied == [volumeName, secondaryVolumeName])
            #expect(summary.networksCreated == [networkName])
            #expect(summary.containersMigrated == [name, stoppedName])
            #expect(summary.containersAwaitingSourcePorts == [name])
            #expect(summary.warnings.isEmpty)

            var targetSnapshot = try await target.snapshot()
            targetFixtureImageIDs.formUnion(
                targetSnapshot.images.map(\.imageID)
                    .filter { !targetBaselineImageIDs.contains($0) }
            )
            var migrated = try #require(targetSnapshot.containers.first { $0.name == name })
            let stoppedInitially = try #require(
                targetSnapshot.containers.first { $0.name == stoppedName }
            )
            targetFixtureImageIDs.formUnion(
                [migrated.sourceImageID, stoppedInitially.sourceImageID]
                    .compactMap { $0 }
                    .filter { !targetBaselineImageIDs.contains($0) }
            )
            targetFixtureImageIDs.formUnion(
                prepared.source.snapshot.images.map { $0.imageID }
                    .filter { !targetBaselineImageIDs.contains($0) }
            )
            #expect(migrated.status == .stopped)
            #expect(migrated.mounts.allSatisfy { $0.type != "volume" })
            #expect(migrated.networks.contains(networkName))
            #expect(!migrated.ports.isEmpty)
            let targetNetworkContract = try await networkContract(target, name: networkName)
            #expect(targetNetworkContract == sourceNetworkContract)

            // The source fixture must still be active and holding its fixed host port immediately
            // after import. Once only this owned fixture releases the port, the deferred Dory
            // container starts paused with the original binding and all transferred data intact.
            let sourceImmediatelyAfter = try await source.snapshot()
            #expect(sourceImmediatelyAfter.containers.first { $0.id == sourceContainerID }?.status == .paused)
            try await source.stop(containerID: sourceContainerID!)
            try await target.start(containerID: migrated.id)
            try await target.pause(containerID: migrated.id)
            targetSnapshot = try await target.snapshot()
            migrated = try #require(targetSnapshot.containers.first { $0.name == name })
            #expect(migrated.status == .paused)
            let env = try await target.env(containerID: migrated.id)
            #expect(env.contains(EnvVar(key: "DORY_MIGRATION_MARKER", value: marker)))

            var stopped = try #require(targetSnapshot.containers.first { $0.name == stoppedName })
            #expect(stopped.status == .stopped)
            #expect(stopped.mounts.contains { $0.type == "volume" && $0.source == volumeName && $0.target == "/fixture" })
            #expect(stopped.mounts.contains { $0.type == "volume" && $0.source == secondaryVolumeName && $0.target == "/secondary" })
            try await target.start(containerID: stopped.id)
            targetSnapshot = try await target.snapshot()
            stopped = try #require(targetSnapshot.containers.first { $0.name == stoppedName })
            #expect(stopped.status == .running)
            let writableLayer = try await target.exec(
                containerID: stopped.id,
                command: ["cat", "/writable-layer-marker"]
            )
            #expect(writableLayer.succeeded)
            #expect(writableLayer.output == "layer-\(marker)")
            let payload = try await target.exec(containerID: stopped.id, command: ["sh", "-c", "cat /fixture/payload"])
            #expect(payload.succeeded)
            #expect(payload.output == marker)
            let payloadMetadata = try await target.exec(
                containerID: stopped.id,
                command: ["sh", "-c", "stat -c '%u:%g:%a' /fixture/payload; readlink /fixture/payload-link; test \"$(stat -c %i /fixture/payload)\" = \"$(stat -c %i /fixture/payload-hardlink)\"; stat -c '%h' /fixture/payload"]
            )
            #expect(payloadMetadata.succeeded)
            #expect(payloadMetadata.output.trimmingCharacters(in: .newlines) == "999:999:600\npayload\n2")
            let secondaryPayload = try await target.exec(containerID: stopped.id, command: ["sh", "-c", "cat /secondary/payload"])
            #expect(secondaryPayload.succeeded)
            #expect(secondaryPayload.output == "secondary-\(marker)")
            let largePayload = try await target.exec(
                containerID: stopped.id,
                command: ["sh", "-c", "test \"$(stat -c %s /fixture/large.bin)\" = 67108864 && cd /fixture && sha256sum -c large.sha256"]
            )
            #expect(largePayload.succeeded)
            #expect(largePayload.output.trimmingCharacters(in: .newlines) == "large.bin: OK")
            let stoppedEnv = try await target.env(containerID: stopped.id)
            #expect(stoppedEnv.contains(EnvVar(key: "DORY_MIGRATION_STATE", value: "stopped")))

            let inspect = await target.proxyRequest(
                method: "GET",
                path: "/containers/\(migrated.id)/json",
                headers: [(name: "Accept", value: "application/json")],
                body: Data()
            )
            let inspectResponse = try #require(inspect)
            let inspectJSON = try #require(try JSONSerialization.jsonObject(with: inspectResponse.body) as? [String: Any])
            let hostConfig = try #require(inspectJSON["HostConfig"] as? [String: Any])
            let restartPolicy = try #require(hostConfig["RestartPolicy"] as? [String: Any])
            #expect(restartPolicy["Name"] as? String == "unless-stopped")
            #expect(hostConfig["Privileged"] as? Bool == true)
            let portBindings = try #require(hostConfig["PortBindings"] as? [String: Any])
            #expect(portBindings["5432/tcp"] != nil)
            let config = try #require(inspectJSON["Config"] as? [String: Any])
            let healthcheck = try #require(config["Healthcheck"] as? [String: Any])
            #expect(healthcheck["Test"] as? [String] == ["CMD", "true"])
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
        let sourceAfter = try await source.snapshot()
        let targetAfter = try await target.snapshot()
        #expect(Set(sourceAfter.images.map(\.imageID)) == Set(sourceBefore.images.map(\.imageID)))
        #expect(Set(targetAfter.images.map(\.imageID)) == Set(targetBefore.images.map(\.imageID)))
        #expect(Set(sourceAfter.containers.map(\.id)) == Set(sourceBefore.containers.map(\.id)))
        #expect(Set(targetAfter.containers.map(\.id)) == Set(targetBefore.containers.map(\.id)))
        #expect(Set(sourceAfter.volumes.map(\.name)) == Set(sourceBefore.volumes.map(\.name)))
        #expect(Set(targetAfter.volumes.map(\.name)) == Set(targetBefore.volumes.map(\.name)))
        #expect(Set(sourceAfter.networks.map(\.name)) == Set(sourceBefore.networks.map(\.name)))
        #expect(Set(targetAfter.networks.map(\.name)) == Set(targetBefore.networks.map(\.name)))
        try Data("passed\n".utf8).write(
            to: URL(fileURLWithPath: liveMarker + ".passed"),
            options: .atomic
        )
    }
}
