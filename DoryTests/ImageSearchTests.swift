import Testing
import Foundation
@testable import Dory

@MainActor
private final class SearchRuntime: ContainerRuntime {
    let kind: RuntimeKind
    let images: [DockerImage]
    init(kind: RuntimeKind, images: [DockerImage]) {
        self.kind = kind
        self.images = images
    }
    func snapshot() async throws -> RuntimeSnapshot { RuntimeSnapshot(images: images) }
    func start(containerID: String) async throws {}
    func stop(containerID: String) async throws {}
    func restart(containerID: String) async throws {}
    func remove(containerID: String) async throws {}
    func logs(containerID: String) async throws -> [LogLine] { [] }
    func env(containerID: String) async throws -> [EnvVar] { [] }
    func create(_ spec: ContainerSpec) async throws -> String { "x" }
    func exec(containerID: String, command: [String]) async throws -> ExecResult { ExecResult(exitCode: 0, output: "") }
}

private actor StubRegistrySearch: RegistryImageSearch {
    private(set) var callCount = 0
    private(set) var lastTerm: String?
    private(set) var lastLimit: Int?
    let results: [DockerImageSearchOut]
    let failure: Error?

    init(results: [DockerImageSearchOut] = [], failure: Error? = nil) {
        self.results = results
        self.failure = failure
    }

    func search(term: String, limit: Int?) async throws -> [DockerImageSearchOut] {
        callCount += 1
        lastTerm = term
        lastLimit = limit
        if let failure { throw failure }
        return results
    }
}

private struct SearchFailure: Error {}

private func localImage(_ repository: String, _ tag: String = "latest") -> DockerImage {
    DockerImage(repository: repository, tag: tag, imageID: "id-\(repository)", size: "1 MB", created: "now", usedByCount: 1)
}

private func hubResult(_ name: String, stars: Int = 0, official: Bool = false, automated: Bool = false, description: String = "") -> DockerImageSearchOut {
    DockerImageSearchOut(description: description, is_official: official, is_automated: automated, name: name, star_count: stars)
}

@MainActor
struct ImageSearchTests {
    private func socketPath(_ prefix: String) -> String { "/tmp/\(prefix)-\(UUID().uuidString).sock" }

    private func search(_ shim: DockerShim, _ query: String, prefix: String) async throws -> [DockerImageSearchOut] {
        let path = socketPath(prefix)
        let server = ShimHTTPServer(socketPath: path) { await shim.handle($0) }
        try server.start(); defer { server.stop() }
        let client = UnixSocketHTTP(path: path)
        let response = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/images/search?\(query)"))
        #expect(response.statusCode == 200)
        return try JSONDecoder().decode([DockerImageSearchOut].self, from: response.body)
    }

    @Test func mergesHubResultsWithLocalImagesAndDedupesLocalFirst() async throws {
        let runtime = SearchRuntime(kind: .appleContainer, images: [localImage("nginx")])
        let hub = StubRegistrySearch(results: [
            hubResult("nginx", stars: 18000, official: true, description: "Official build of Nginx"),
            hubResult("nginxinc/nginx-unprivileged", stars: 200),
        ])
        let shim = DockerShim(runtime: runtime, registrySearch: hub)

        let results = try await search(shim, "term=nginx", prefix: "dory-search-merge")
        let names = results.map(\.name)

        #expect(names.contains("nginx"))
        #expect(names.contains("nginxinc/nginx-unprivileged"))
        #expect(names.filter { $0 == "nginx" }.count == 1)
        #expect(results.firstIndex { $0.name == "nginx" } == 0)
        #expect(results.first { $0.name == "nginx" }?.description == "Local image nginx:latest")
    }

    @Test func mockBackendNeverQueriesTheRegistry() async throws {
        let runtime = SearchRuntime(kind: .mock, images: [localImage("nginx")])
        let hub = StubRegistrySearch(results: [hubResult("should-not-appear", stars: 9000)])
        let shim = DockerShim(runtime: runtime, registrySearch: hub)

        let results = try await search(shim, "term=nginx", prefix: "dory-search-mock")

        #expect(await hub.callCount == 0)
        #expect(results.map(\.name) == ["nginx"])
    }

    @Test func fallsBackToLocalWhenRegistryFails() async throws {
        let runtime = SearchRuntime(kind: .appleContainer, images: [localImage("nginx")])
        let hub = StubRegistrySearch(failure: SearchFailure())
        let shim = DockerShim(runtime: runtime, registrySearch: hub)

        let results = try await search(shim, "term=nginx", prefix: "dory-search-offline")

        #expect(await hub.callCount == 1)
        #expect(results.map(\.name) == ["nginx"])
    }

    @Test func appliesStarFilterToMergedResults() async throws {
        let runtime = SearchRuntime(kind: .appleContainer, images: [localImage("xenial")])
        let hub = StubRegistrySearch(results: [
            hubResult("nginx", stars: 5000),
            hubResult("lowstar", stars: 1),
        ])
        let shim = DockerShim(runtime: runtime, registrySearch: hub)

        let json = "{\"stars\":[\"3\"]}"
        let encoded = json.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? json
        let results = try await search(shim, "term=x&filters=\(encoded)", prefix: "dory-search-filter")

        #expect(results.map(\.name) == ["nginx"])
    }

    @Test func limitsMergedResultsAndPassesTermAndLimitToRegistry() async throws {
        let runtime = SearchRuntime(kind: .appleContainer, images: [localImage("nginx")])
        let hub = StubRegistrySearch(results: [hubResult("a"), hubResult("b"), hubResult("c")])
        let shim = DockerShim(runtime: runtime, registrySearch: hub)

        let results = try await search(shim, "term=nginx&limit=2", prefix: "dory-search-limit")

        #expect(results.count == 2)
        #expect(results.first?.name == "nginx")
        #expect(await hub.lastTerm == "nginx")
        #expect(await hub.lastLimit == 2)
    }

    @Test func hubSearchURLEncodesTermAndLimit() throws {
        let withLimit = HubImageSearch.searchURL(term: "ng inx", limit: 10)
        let components = try #require(URLComponents(url: withLimit, resolvingAgainstBaseURL: false))
        #expect(components.host == "index.docker.io")
        #expect(components.path == "/v1/search")
        #expect(components.queryItems?.first { $0.name == "q" }?.value == "ng inx")
        #expect(components.queryItems?.first { $0.name == "n" }?.value == "10")

        let noLimit = HubImageSearch.searchURL(term: "nginx", limit: nil)
        let bare = try #require(URLComponents(url: noLimit, resolvingAgainstBaseURL: false))
        #expect(bare.queryItems?.contains { $0.name == "n" } == false)
    }
}
