import Testing
import Foundation
@testable import Dory

struct ShimServerTests {
    @MainActor
    @Test func servesDockerAPIOverUnixSocket() async throws {
        let path = NSTemporaryDirectory() + "dory-shim-\(UUID().uuidString).sock"
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

        let containers = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/json?all=1"))
        #expect(containers.statusCode == 200)
        let list = try JSONDecoder().decode([DockerContainerSummary].self, from: containers.body)
        #expect(list.count == MockData.containers.count)
        let names = list.flatMap { $0.names ?? [] }
        #expect(names.contains("/postgres-db"))

        let notFound = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/nonexistent"))
        #expect(notFound.statusCode == 404)
    }

    @MainActor
    @Test func servesNetworksVolumesAndInspect() async throws {
        let path = NSTemporaryDirectory() + "dory-shim2-\(UUID().uuidString).sock"
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

    @Test func normalizesVersionedPaths() {
        #expect(DockerShim.normalize("/v1.47/containers/json") == "/containers/json")
        #expect(DockerShim.normalize("/containers/json") == "/containers/json")
        #expect(DockerShim.normalize("/_ping") == "/_ping")
        #expect(DockerShim.normalize("/v1.43/version") == "/version")
    }
}
