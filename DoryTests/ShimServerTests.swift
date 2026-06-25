import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#endif
@testable import Dory

struct ShimServerTests {
    @MainActor
    @Test func servesDockerAPIOverUnixSocket() async throws {
        let path = shortSocketPath("dory-shim")
        let shim = DockerShim(runtime: MockRuntime())
        let server = ShimHTTPServer(socketPath: path) { request in await shim.handle(request) }
        try server.start()
        defer { server.stop() }

        let client = UnixSocketHTTP(path: path)

        let ping = try await client.send(HTTPRequest(method: "GET", path: "/_ping"))
        #expect(ping.statusCode == 200)
        #expect(String(data: ping.body, encoding: .utf8) == "OK")

        let version = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/version"))
        #expect(version.statusCode == 200)
        let decodedVersion = try JSONDecoder().decode(DockerVersion.self, from: version.body)
        #expect(decodedVersion.apiVersion == "1.47")

        let containers = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/json?all=1&size=1"))
        #expect(containers.statusCode == 200)
        let list = try JSONDecoder().decode([DockerContainerSummary].self, from: containers.body)
        #expect(list.count == MockData.containers.count)
        let names = list.flatMap { $0.names ?? [] }
        #expect(names.contains("/postgres-db"))
        let rawList = try #require(try JSONSerialization.jsonObject(with: containers.body) as? [[String: Any]])
        let postgres = try #require(rawList.first { ($0["Names"] as? [String])?.contains("/postgres-db") == true })
        #expect(postgres["Image"] as? String == "postgres:16")
        #expect(postgres["ImageID"] as? String == "sha256:3f1a2b9c")
        #expect(postgres["SizeRootFs"] as? Int == 459_276_288)

        let notFound = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/nonexistent"))
        #expect(notFound.statusCode == 404)
    }

    @MainActor
    @Test func containersJsonHonorsLabelFilters() async throws {
        let path = shortSocketPath("dory-filter")
        let shim = DockerShim(runtime: MockRuntime())
        let server = ShimHTTPServer(socketPath: path) { request in await shim.handle(request) }
        try server.start()
        defer { server.stop() }
        let client = UnixSocketHTTP(path: path)
        let filters = #"{"label":["com.docker.compose.project=dory-stack","com.docker.compose.service=web"]}"#
        let encoded = filters.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filters

        let response = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/json?all=1&filters=\(encoded)"))

        #expect(response.statusCode == 200)
        let list = try JSONDecoder().decode([DockerContainerSummary].self, from: response.body)
        #expect(list.map(\.names?.first).contains("/web-api"))
        #expect(list.count == 1)
        #expect(list.first?.labels?["com.docker.compose.service"] == "web")
    }

    @MainActor
    @Test func containersJsonHonorsDockerContainerFilters() async throws {
        let path = shortSocketPath("dory-container-filters")
        let runtime = ContainerFilterRuntime(containers: [
            filterContainer(
                id: "aaa111",
                name: "db",
                image: "postgres:16",
                status: .running,
                createdEpoch: 10,
                labels: ["tier": "data", "dory.health": "healthy"],
                ports: "5432/tcp",
                mounts: [ContainerMount(type: "volume", source: "db-data", target: "/var/lib/postgresql/data")],
                networks: ["back-tier"]
            ),
            filterContainer(
                id: "bbb222",
                name: "api",
                image: "local/api:dev",
                status: .running,
                createdEpoch: 20,
                labels: ["tier": "app"],
                ports: "127.0.0.1:8080->80/tcp, 9000/tcp",
                volumes: ["/Users/me/api:/app:ro"],
                networks: ["front-tier"]
            ),
            filterContainer(
                id: "ccc333",
                name: "worker",
                image: "local/worker:dev",
                status: .stopped,
                createdEpoch: 30,
                labels: ["tier": "app"],
                networks: ["back-tier"],
                exitCode: 137
            ),
        ])
        let shim = DockerShim(runtime: runtime)
        let server = ShimHTTPServer(socketPath: path) { request in await shim.handle(request) }
        try server.start()
        defer { server.stop() }
        let client = UnixSocketHTTP(path: path)

        let since = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/json?all=1&filters=\(encodedFilters(#"{"since":["db"]}"#))"))
        #expect(since.statusCode == 200)
        #expect(try containerNames(since.body) == ["/api", "/worker"])

        let before = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/json?all=1&filters=\(encodedFilters(#"{"before":["worker"]}"#))"))
        #expect(before.statusCode == 200)
        #expect(try containerNames(before.body) == ["/db", "/api"])

        let unknown = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/json?all=1&filters=\(encodedFilters(#"{"since":["missing"]}"#))"))
        #expect(unknown.statusCode == 200)
        #expect(try containerNames(unknown.body).isEmpty)

        let health = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/json?all=1&filters=\(encodedFilters(#"{"health":["healthy"]}"#))"))
        #expect(health.statusCode == 200)
        #expect(try containerNames(health.body) == ["/db"])

        let volume = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/json?all=1&filters=\(encodedFilters(#"{"volume":["/app"]}"#))"))
        #expect(volume.statusCode == 200)
        #expect(try containerNames(volume.body) == ["/api"])

        let namedVolume = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/json?all=1&filters=\(encodedFilters(#"{"volume":["db-data"]}"#))"))
        #expect(namedVolume.statusCode == 200)
        #expect(try containerNames(namedVolume.body) == ["/db"])

        let network = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/json?all=1&filters=\(encodedFilters(#"{"network":["front"]}"#))"))
        #expect(network.statusCode == 200)
        #expect(try containerNames(network.body) == ["/api"])

        let published = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/json?all=1&filters=\(encodedFilters(#"{"publish":["80"]}"#))"))
        #expect(published.statusCode == 200)
        #expect(try containerNames(published.body) == ["/api"])

        let exposed = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/json?all=1&filters=\(encodedFilters(#"{"expose":["5400-5500/tcp"]}"#))"))
        #expect(exposed.statusCode == 200)
        #expect(try containerNames(exposed.body) == ["/db"])

        let exited = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/json?all=1&filters=\(encodedFilters(#"{"exited":["137"]}"#))"))
        #expect(exited.statusCode == 200)
        #expect(try containerNames(exited.body) == ["/worker"])

        let latest = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/json?limit=2"))
        #expect(latest.statusCode == 200)
        #expect(try containerNames(latest.body) == ["/worker", "/api"])

        let unlimited = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/json?limit=0"))
        #expect(unlimited.statusCode == 200)
        #expect(try containerNames(unlimited.body) == ["/db", "/api"])
    }

    @MainActor
    @Test func imagesJsonHonorsDockerImageFilters() async throws {
        let path = shortSocketPath("dory-image-filters")
        let runtime = ImageFilterRuntime(images: [
            DockerImage(repository: "local/web", tag: "dev", imageID: "abc123", size: "10 MB", created: "now", usedByCount: 1, sizeBytes: 10, createdEpoch: 10, labels: ["stage": "dev"]),
            DockerImage(repository: "local/api", tag: "prod", imageID: "def456", size: "12 MB", created: "now", usedByCount: 0, sizeBytes: 12, createdEpoch: 12, labels: ["stage": "prod"]),
            DockerImage(repository: "<none>", tag: "<none>", imageID: "dangling", size: "1 MB", created: "now", usedByCount: 0, sizeBytes: 1, createdEpoch: 1),
        ])
        let shim = DockerShim(runtime: runtime)
        let server = ShimHTTPServer(socketPath: path) { request in await shim.handle(request) }
        try server.start()
        defer { server.stop() }
        let client = UnixSocketHTTP(path: path)

        let label = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/images/json?filters=\(encodedFilters(#"{"label":["stage=dev"]}"#))"))
        #expect(label.statusCode == 200)
        let labelImages = try imageList(label.body)
        #expect(labelImages.first?.id == "sha256:abc123")
        #expect(labelImages.map(\.repoTag) == ["local/web:dev"])
        #expect(labelImages.first?.labels["stage"] == "dev")

        let inspect = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/images/local%2Fweb:dev/json"))
        #expect(inspect.statusCode == 200)
        let inspectJSON = try #require(try JSONSerialization.jsonObject(with: inspect.body) as? [String: Any])
        let config = try #require(inspectJSON["Config"] as? [String: Any])
        #expect((config["Labels"] as? [String: String])?["stage"] == "dev")

        let reference = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/images/json?filters=\(encodedFilters(#"{"reference":["local/*:prod"]}"#))"))
        #expect(reference.statusCode == 200)
        #expect(try imageList(reference.body).map(\.repoTag) == ["local/api:prod"])

        let dangling = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/images/json?filters=\(encodedFilters(#"{"dangling":["true"]}"#))"))
        #expect(dangling.statusCode == 200)
        #expect(try imageList(dangling.body).map(\.repoTag) == ["<none>:<none>"])

        let since = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/images/json?filters=\(encodedFilters(#"{"since":["local/web:dev"]}"#))"))
        #expect(since.statusCode == 200)
        #expect(try imageList(since.body).map(\.repoTag) == ["local/api:prod"])

        let before = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/images/json?filters=\(encodedFilters(#"{"before":["local/web:dev"]}"#))"))
        #expect(before.statusCode == 200)
        #expect(try imageList(before.body).map(\.repoTag) == ["<none>:<none>"])
    }

    @MainActor
    @Test func servesNetworksVolumesAndInspect() async throws {
        let path = shortSocketPath("dory-shim2")
        let shim = DockerShim(runtime: MockRuntime())
        let server = ShimHTTPServer(socketPath: path) { request in await shim.handle(request) }
        try server.start()
        defer { server.stop() }
        let client = UnixSocketHTTP(path: path)

        let networks = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/networks"))
        #expect(networks.statusCode == 200)
        let networkList = try JSONDecoder().decode([DockerNetwork].self, from: networks.body)
        #expect(networkList.count == MockData.networks.count)
        #expect(networkList.contains { $0.name == "dory-default" })

        let volumes = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/volumes"))
        let volumeList = try JSONDecoder().decode(DockerVolumeList.self, from: volumes.body)
        #expect(volumeList.volumes?.count == MockData.volumes.count)

        let inspect = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/c1/json"))
        #expect(inspect.statusCode == 200)
        let inspected = try JSONDecoder().decode(DockerInspect.self, from: inspect.body)
        #expect(inspected.config?.cmd != nil)

        let logs = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/c1/logs"))
        #expect(logs.statusCode == 200)
        #expect(!logs.body.isEmpty)
    }

    @MainActor
    @Test func networksAndVolumesHonorDockerFilters() async throws {
        let path = shortSocketPath("dory-network-volume-filters")
        let runtime = NetworkVolumeFilterRuntime(
            volumes: [
                Volume(name: "db-data", size: "1 GB", driver: "local", usedBy: "db", created: "now", labels: ["tier": "data"]),
                Volume(name: "cache", size: "10 MB", driver: "nfs", usedBy: "—", created: "now", labels: ["stale": "true"]),
            ],
            networks: [
                DoryNetwork(name: "web-tier", driver: "bridge", scope: "local", subnet: "10.0.0.0/24", containerCount: 2, labels: ["tier": "web"]),
                DoryNetwork(name: "host", driver: "host", scope: "local", subnet: "—", containerCount: 0),
                DoryNetwork(name: "ingress", driver: "overlay", scope: "swarm", subnet: "10.1.0.0/24", containerCount: 1, labels: ["tier": "edge"]),
            ]
        )
        let shim = DockerShim(runtime: runtime)
        let server = ShimHTTPServer(socketPath: path) { request in await shim.handle(request) }
        try server.start()
        defer { server.stop() }
        let client = UnixSocketHTTP(path: path)

        let networkLabel = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/networks?filters=\(encodedFilters(#"{"label":["tier=web"]}"#))"))
        #expect(networkLabel.statusCode == 200)
        #expect(try networkNames(networkLabel.body) == ["web-tier"])

        let networkType = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/networks?filters=\(encodedFilters(#"{"type":["builtin"]}"#))"))
        #expect(networkType.statusCode == 200)
        #expect(try networkNames(networkType.body) == ["host"])

        let volumeDangling = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/volumes?filters=\(encodedFilters(#"{"dangling":["true"]}"#))"))
        #expect(volumeDangling.statusCode == 200)
        #expect(try volumeNames(volumeDangling.body) == ["cache"])

        let volumeLabel = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/volumes?filters=\(encodedFilters(#"{"label":["tier=data"]}"#))"))
        #expect(volumeLabel.statusCode == 200)
        #expect(try volumeNames(volumeLabel.body) == ["db-data"])
        #expect(try volumeLabels(volumeLabel.body, name: "db-data")["tier"] == "data")
    }

    @MainActor
    @Test func servesTranslatedInspectEndpointsForImagesNetworksAndVolumes() async throws {
        let path = shortSocketPath("dory-inspect-api")
        let shim = DockerShim(runtime: MockRuntime())
        let server = ShimHTTPServer(socketPath: path) { request in await shim.handle(request) }
        try server.start()
        defer { server.stop() }
        let client = UnixSocketHTTP(path: path)

        let image = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/images/postgres:16/json"))
        #expect(image.statusCode == 200)
        let imageJSON = try #require(try JSONSerialization.jsonObject(with: image.body) as? [String: Any])
        #expect((imageJSON["RepoTags"] as? [String])?.contains("postgres:16") == true)
        #expect((imageJSON["Size"] as? NSNumber)?.int64Value == 459_276_288)
        #expect((imageJSON["Id"] as? String)?.hasPrefix("sha256:") == true)

        let encodedImage = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/images/dory%2Fweb-api:latest/json"))
        #expect(encodedImage.statusCode == 200)
        let encodedImageJSON = try #require(try JSONSerialization.jsonObject(with: encodedImage.body) as? [String: Any])
        #expect((encodedImageJSON["RepoTags"] as? [String])?.contains("dory/web-api:latest") == true)

        let network = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/networks/dory-default"))
        #expect(network.statusCode == 200)
        let networkJSON = try #require(try JSONSerialization.jsonObject(with: network.body) as? [String: Any])
        let ipam = try #require(networkJSON["IPAM"] as? [String: Any])
        let config = try #require(ipam["Config"] as? [[String: Any]])
        #expect(networkJSON["Name"] as? String == "dory-default")
        #expect(networkJSON["Driver"] as? String == "bridge")
        #expect(config.first?["Subnet"] as? String == "192.168.215.0/24")

        let volume = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/volumes/postgres-data"))
        #expect(volume.statusCode == 200)
        let volumeJSON = try #require(try JSONSerialization.jsonObject(with: volume.body) as? [String: Any])
        #expect(volumeJSON["Name"] as? String == "postgres-data")
        #expect(volumeJSON["Driver"] as? String == "local")
        #expect(volumeJSON["Mountpoint"] as? String == "/var/lib/dory/volumes/postgres-data")

        let missing = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/images/missing:latest/json"))
        #expect(missing.statusCode == 404)
    }

    @MainActor
    @Test func servesTranslatedTopChangesAndImageHistoryEndpoints() async throws {
        let path = shortSocketPath("dory-readonly-api")
        let shim = DockerShim(runtime: MockRuntime())
        let server = ShimHTTPServer(socketPath: path) { request in await shim.handle(request) }
        try server.start()
        defer { server.stop() }
        let client = UnixSocketHTTP(path: path)

        let top = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/c1/top"))
        #expect(top.statusCode == 200)
        let topJSON = try #require(try JSONSerialization.jsonObject(with: top.body) as? [String: Any])
        #expect((topJSON["Titles"] as? [String])?.contains("PID") == true)
        let processes = try #require(topJSON["Processes"] as? [[String]])
        #expect(processes.first?.last == "postgres")

        let stoppedTop = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/c5/top"))
        #expect(stoppedTop.statusCode == 409)

        let changes = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/postgres-db/changes"))
        #expect(changes.statusCode == 200)
        let changesJSON = try #require(try JSONSerialization.jsonObject(with: changes.body) as? [[String: Any]])
        #expect(changesJSON.isEmpty)

        let history = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/images/postgres:16/history"))
        #expect(history.statusCode == 200)
        let historyJSON = try #require(try JSONSerialization.jsonObject(with: history.body) as? [[String: Any]])
        #expect((historyJSON.first?["Tags"] as? [String])?.contains("postgres:16") == true)
        #expect((historyJSON.first?["Size"] as? NSNumber)?.int64Value == 459_276_288)

        let encodedHistory = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/images/dory%2Fweb-api:latest/history"))
        #expect(encodedHistory.statusCode == 200)
        let encodedHistoryJSON = try #require(try JSONSerialization.jsonObject(with: encodedHistory.body) as? [[String: Any]])
        #expect((encodedHistoryJSON.first?["Tags"] as? [String])?.contains("dory/web-api:latest") == true)

        let missing = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/images/missing:latest/history"))
        #expect(missing.statusCode == 404)
    }

    @Test func normalizesVersionedPaths() {
        #expect(DockerShim.normalize("/v1.47/containers/json") == "/containers/json")
        #expect(DockerShim.normalize("/containers/json") == "/containers/json")
        #expect(DockerShim.normalize("/_ping") == "/_ping")
        #expect(DockerShim.normalize("/v1.43/version") == "/version")
    }

    @MainActor
    @Test func rawProxyOwnsConnectionAndPreservesLargeRequest() async throws {
        let path = shortSocketPath("dory-raw-proxy")
        let capture = RawProxyCapture(expectedBodyBytes: 200_000)
        let server = ShimHTTPServer(socketPath: path, rawProxy: { fd, initial in
            capture.proxy(fd: fd, initial: initial)
        }) { _ in
            capture.markHandlerCalled()
            return ShimResponse.text("handler should not run", status: 500)
        }
        try server.start()
        defer { server.stop() }

        let body = Data((0..<200_000).map { UInt8($0 % 251) })
        let request = HTTPRequest(
            method: "POST",
            path: "/v1.47/build?dockerfile=Dockerfile",
            headers: [
                (name: "Content-Type", value: "application/x-tar"),
                (name: "X-Registry-Auth", value: "opaque-auth-header"),
            ],
            body: body
        )
        let expectedWireBytes = HTTPCodec.serialize(request)
        let response = try await UnixSocketHTTP(path: path).send(request)

        #expect(response.statusCode == 299)
        #expect(String(data: response.body, encoding: .utf8) == "raw proxy")
        #expect(!capture.handlerCalled)
        #expect(capture.initialCount < expectedWireBytes.count)
        #expect(capture.wireBytes == expectedWireBytes)
    }

    @MainActor
    @Test func streamingResponsesUseChunkedTransferFraming() async throws {
        let path = shortSocketPath("dory-streaming")
        let server = ShimHTTPServer(socketPath: path) { _ in
            ShimResponse.streaming(contentType: "text/plain") { writer in
                guard writer.write(Data("hello".utf8)) else { return }
                guard writer.write(Data()) else { return }
                _ = writer.write(Data(" world".utf8))
            }
        }
        try server.start()
        defer { server.stop() }

        let raw = try await rawHTTPResponse(
            path: path,
            request: HTTPRequest(method: "GET", path: "/stream")
        )
        let text = String(decoding: raw, as: UTF8.self)
        let response = try #require(try HTTPCodec.parseResponse(raw))

        #expect(response.statusCode == 200)
        #expect(response.header("transfer-encoding") == "chunked")
        #expect(response.header("content-length") == nil)
        #expect(response.header("content-type") == "text/plain")
        #expect(String(data: response.body, encoding: .utf8) == "hello world")
        #expect(text.contains("\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"))
    }

    private func shortSocketPath(_ prefix: String) -> String {
        "/tmp/\(prefix)-\(UUID().uuidString).sock"
    }

    private func encodedFilters(_ filters: String) -> String {
        filters.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filters
    }

    private func imageList(_ data: Data) throws -> [(id: String, repoTag: String, labels: [String: String])] {
        let raw = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        return raw.map { item in
            let id = item["Id"] as? String ?? ""
            let tags = item["RepoTags"] as? [String] ?? []
            let labels = item["Labels"] as? [String: String] ?? [:]
            return (id, tags.first ?? "", labels)
        }
    }

    private func containerNames(_ data: Data) throws -> [String] {
        let list = try JSONDecoder().decode([DockerContainerSummary].self, from: data)
        return list.compactMap { $0.names?.first }
    }

    private func networkNames(_ data: Data) throws -> [String] {
        try JSONDecoder().decode([DockerNetwork].self, from: data).map(\.name)
    }

    private func volumeNames(_ data: Data) throws -> [String] {
        try JSONDecoder().decode(DockerVolumeList.self, from: data).volumes?.map(\.name) ?? []
    }

    private func volumeLabels(_ data: Data, name: String) throws -> [String: String] {
        let raw = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let volumes = try #require(raw["Volumes"] as? [[String: Any]])
        let volume = try #require(volumes.first { $0["Name"] as? String == name })
        return volume["Labels"] as? [String: String] ?? [:]
    }

    private func filterContainer(
        id: String,
        name: String,
        image: String,
        status: RunState,
        createdEpoch: Int,
        labels: [String: String],
        ports: String = "—",
        volumes: [String] = [],
        mounts: [ContainerMount] = [],
        networks: [String] = [],
        exitCode: Int? = nil
    ) -> Container {
        Container(
            id: id,
            name: name,
            image: image,
            status: status,
            cpuPercent: 0,
            memoryDisplay: "0 B",
            memoryLimitDisplay: "—",
            memoryFraction: 0,
            ports: ports,
            uptime: "1s",
            created: "now",
            ipAddress: "—",
            domain: "",
            command: "true",
            restartPolicy: "no",
            createdEpoch: createdEpoch,
            labels: labels,
            volumes: volumes,
            mounts: mounts,
            networks: networks,
            exitCode: exitCode
        )
    }

    private func rawHTTPResponse(path: String, request: HTTPRequest) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let fd = try UnixSocketHTTP.connectSocket(path)
            defer { Darwin.close(fd) }
            try UnixSocketHTTP.writeAll(fd, HTTPCodec.serialize(request))
            var data = Data()
            var scratch = [UInt8](repeating: 0, count: 4096)
            while true {
                let capacity = scratch.count
                let count = scratch.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, capacity) }
                if count < 0 { throw HTTPError.socket(UnixSocketHTTP.errnoMessage("read")) }
                if count == 0 { break }
                data.append(contentsOf: scratch[0..<count])
            }
            return data
        }.value
    }
}

private struct NetworkVolumeFilterRuntime: ContainerRuntime {
    let kind: RuntimeKind = .mock
    var volumes: [Volume]
    var networks: [DoryNetwork]

    func snapshot() async throws -> RuntimeSnapshot {
        RuntimeSnapshot(volumes: volumes, networks: networks)
    }

    func start(containerID: String) async throws {}
    func stop(containerID: String) async throws {}
    func restart(containerID: String) async throws {}
    func remove(containerID: String) async throws {}
    func logs(containerID: String) async throws -> [LogLine] { [] }
    func env(containerID: String) async throws -> [EnvVar] { [] }
    func create(_ spec: ContainerSpec) async throws -> String { "created" }
    func exec(containerID: String, command: [String]) async throws -> ExecResult { ExecResult(exitCode: 0, output: "") }
}

private struct ContainerFilterRuntime: ContainerRuntime {
    let kind: RuntimeKind = .mock
    var containers: [Container]

    func snapshot() async throws -> RuntimeSnapshot {
        RuntimeSnapshot(containers: containers)
    }

    func start(containerID: String) async throws {}
    func stop(containerID: String) async throws {}
    func restart(containerID: String) async throws {}
    func remove(containerID: String) async throws {}
    func logs(containerID: String) async throws -> [LogLine] { [] }
    func env(containerID: String) async throws -> [EnvVar] { [] }
    func create(_ spec: ContainerSpec) async throws -> String { "created" }
    func exec(containerID: String, command: [String]) async throws -> ExecResult { ExecResult(exitCode: 0, output: "") }
}

private struct ImageFilterRuntime: ContainerRuntime {
    let kind: RuntimeKind = .mock
    var images: [DockerImage]

    func snapshot() async throws -> RuntimeSnapshot {
        RuntimeSnapshot(images: images)
    }

    func start(containerID: String) async throws {}
    func stop(containerID: String) async throws {}
    func restart(containerID: String) async throws {}
    func remove(containerID: String) async throws {}
    func logs(containerID: String) async throws -> [LogLine] { [] }
    func env(containerID: String) async throws -> [EnvVar] { [] }
    func create(_ spec: ContainerSpec) async throws -> String { "created" }
    func exec(containerID: String, command: [String]) async throws -> ExecResult { ExecResult(exitCode: 0, output: "") }
}

private final class RawProxyCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let expectedBodyBytes: Int
    private var _wireBytes = Data()
    private var _initialCount = 0
    private var _handlerCalled = false

    init(expectedBodyBytes: Int) {
        self.expectedBodyBytes = expectedBodyBytes
    }

    var wireBytes: Data {
        lock.lock(); defer { lock.unlock() }
        return _wireBytes
    }

    var initialCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _initialCount
    }

    var handlerCalled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _handlerCalled
    }

    func markHandlerCalled() {
        lock.lock(); _handlerCalled = true; lock.unlock()
    }

    func proxy(fd: Int32, initial: Data) {
        var bytes = initial
        var scratch = [UInt8](repeating: 0, count: 64 * 1024)
        while Self.bodyByteCount(in: bytes) < expectedBodyBytes {
            let capacity = scratch.count
            let readCount = scratch.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, capacity) }
            if readCount <= 0 { break }
            bytes.append(contentsOf: scratch[0..<readCount])
        }

        lock.lock()
        _initialCount = initial.count
        _wireBytes = bytes
        lock.unlock()

        let response = HTTPCodec.serializeResponse(
            status: 299,
            headers: [(name: "Content-Type", value: "text/plain")],
            body: Data("raw proxy".utf8)
        )
        try? UnixSocketHTTP.writeAll(fd, response)
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }

    private static func bodyByteCount(in data: Data) -> Int {
        guard let range = HTTPCodec.range(of: HTTPCodec.headerTerminator, in: data) else { return 0 }
        return data.distance(from: range.upperBound, to: data.endIndex)
    }
}
