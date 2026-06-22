import Foundation

struct RuntimeSnapshot: Sendable {
    var containers: [Container] = []
    var images: [DockerImage] = []
    var volumes: [Volume] = []
    var networks: [DoryNetwork] = []
    var pods: [Pod] = []
    var machines: [Machine] = []
    var engineRunning: Bool = true
    var engineVersion: String = "1.4.0"
}

enum RuntimeKind: String, Sendable {
    case mock
    case docker
    case appleContainer
    case sharedVM

    var displayName: String {
        switch self {
        case .mock: "Mock"
        case .docker: "Docker Engine"
        case .appleContainer: "Apple container"
        case .sharedVM: "Shared VM"
        }
    }

    /// True when the runtime fronts a real Docker socket the shim can transparently proxy to —
    /// the Docker engine and Dory's own shared VM both do.
    var isDockerCompatible: Bool { self == .docker || self == .sharedVM }
}

struct ContainerSpec: Sendable {
    var name: String
    var image: String
    var command: [String] = []
    var environment: [String: String] = [:]
    var ports: [String] = []
    var labels: [String: String] = [:]
    var networks: [String] = []
    var volumes: [String] = []
    var restart: String?
}

struct ExecResult: Sendable {
    var exitCode: Int
    var output: String
    var succeeded: Bool { exitCode == 0 }
}

protocol ContainerRuntime: Sendable {
    var kind: RuntimeKind { get }
    func snapshot() async throws -> RuntimeSnapshot
    func start(containerID: String) async throws
    func stop(containerID: String) async throws
    func restart(containerID: String) async throws
    func remove(containerID: String) async throws
    func logs(containerID: String) async throws -> [LogLine]
    func env(containerID: String) async throws -> [EnvVar]

    func pull(image: String) async throws
    func create(_ spec: ContainerSpec) async throws -> String
    func exec(containerID: String, command: [String]) async throws -> ExecResult
    func createNetwork(name: String, labels: [String: String]) async throws
    func removeNetwork(name: String) async throws
    func pruneNetworks() async throws
    func createVolume(name: String) async throws
    func removeVolume(name: String) async throws
    func pruneVolumes() async throws
    func removeImage(id: String) async throws
    func pruneImages() async throws
    func login(registry: String, username: String, password: String) async throws
    func inspectImage(id: String) async -> ImageDetail?
    func inspectNetwork(name: String) async -> NetworkDetail?

    // Declared as requirements (not extension-only) so backend overrides dispatch dynamically
    // through `any ContainerRuntime`. Defaults are provided in the extension below.
    func sampleCPU(containerID: String) async -> Double?
    func startMachine(name: String) async throws
    func stopMachine(name: String) async throws
    func streamLogs(containerID: String) -> AsyncStream<LogLine>
    func containerExitCode(_ id: String) async -> Int?
    func copyOut(containerID: String, path: String) async -> Data?
    func copyIn(containerID: String, path: String, archive: Data) async -> Bool
    func build(contextTar: Data, query: String) -> AsyncStream<Data>
    func commit(containerID: String, repo: String, tag: String, labels: [String: String]) async throws -> String
    func saveImage(reference: String) -> AsyncStream<Data>
    func loadImage(tar: Data) async throws

    // Raw passthrough for hijack/bidirectional endpoints (interactive exec, attach) — supported by
    // backends that front a Docker-compatible socket. Default: unsupported.
    var supportsRawProxy: Bool { get }
    func proxyRequest(method: String, path: String, headers: [(name: String, value: String)], body: Data) async -> HTTPResponse?
    nonisolated func proxyHijack(requestData: Data, clientFD: Int32)
}

extension ContainerRuntime {
    func pull(image: String) async throws {}
    func createNetwork(name: String, labels: [String: String]) async throws {}
    func removeNetwork(name: String) async throws {}
    func pruneNetworks() async throws {}
    func createVolume(name: String) async throws {}
    func removeVolume(name: String) async throws {}
    func pruneVolumes() async throws {}
    func removeImage(id: String) async throws {}
    func pruneImages() async throws {}
    func login(registry: String, username: String, password: String) async throws {}
    func inspectImage(id: String) async -> ImageDetail? { nil }
    func inspectNetwork(name: String) async -> NetworkDetail? { nil }
    func sampleCPU(containerID: String) async -> Double? { nil }
    func startMachine(name: String) async throws {}
    func stopMachine(name: String) async throws {}
    func streamLogs(containerID: String) -> AsyncStream<LogLine> { AsyncStream { $0.finish() } }
    func containerExitCode(_ id: String) async -> Int? { nil }
    func copyOut(containerID: String, path: String) async -> Data? { nil }
    func copyIn(containerID: String, path: String, archive: Data) async -> Bool { false }
    func build(contextTar: Data, query: String) -> AsyncStream<Data> { AsyncStream { $0.finish() } }
    func commit(containerID: String, repo: String, tag: String, labels: [String: String]) async throws -> String { "" }
    func saveImage(reference: String) -> AsyncStream<Data> { AsyncStream { $0.finish() } }
    func loadImage(tar: Data) async throws {}
    var supportsRawProxy: Bool { false }
    func proxyRequest(method: String, path: String, headers: [(name: String, value: String)], body: Data) async -> HTTPResponse? { nil }
    nonisolated func proxyHijack(requestData: Data, clientFD: Int32) {}
}

enum DockerImageOps {
    static func commitPath(container: String, repo: String, tag: String) -> String {
        "/commit?container=\(container)&repo=\(repo)&tag=\(tag)"
    }
}
