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

nonisolated struct ContainerMount: Codable, Sendable, Hashable {
    var type: String
    var source: String?
    var target: String
    var readOnly: Bool = false
    var consistency: String? = nil
    var bindOptions: DockerBindOptions? = nil
    var volumeOptions: DockerVolumeOptions? = nil
    var tmpfsOptions: DockerTmpfsOptions? = nil
    var imageOptions: DockerImageOptions? = nil
}

nonisolated struct DockerBindOptions: Codable, Sendable, Hashable {
    var Propagation: String? = nil
    var NonRecursive: Bool? = nil
    var CreateMountpoint: Bool? = nil
    var ReadOnlyNonRecursive: Bool? = nil
    var ReadOnlyForceRecursive: Bool? = nil
}

nonisolated struct DockerVolumeDriverConfig: Codable, Sendable, Hashable {
    var Name: String? = nil
    var Options: [String: String]? = nil
}

nonisolated struct DockerVolumeOptions: Codable, Sendable, Hashable {
    var NoCopy: Bool? = nil
    var Labels: [String: String]? = nil
    var Subpath: String? = nil
    var DriverConfig: DockerVolumeDriverConfig? = nil
}

nonisolated struct DockerTmpfsOptions: Codable, Sendable, Hashable {
    var SizeBytes: Int64? = nil
    var Mode: Int? = nil
    var Options: [[String]]? = nil
}

nonisolated struct DockerImageOptions: Codable, Sendable, Hashable {
    var Subpath: String? = nil
}

enum RuntimeKind: String, Sendable {
    case mock
    case docker
    case sharedVM
    case disconnected

    nonisolated var displayName: String {
        switch self {
        case .mock: "Mock"
        case .docker: "Docker Engine"
        case .sharedVM: "Shared VM"
        case .disconnected: "Disconnected"
        }
    }

    /// True when the runtime fronts a real Docker socket the shim can transparently proxy to —
    /// the Docker engine and Dory's own shared VM both do.
    nonisolated var isDockerCompatible: Bool { self == .docker || self == .sharedVM }
}

struct ContainerSpec: Codable, Sendable {
    var name: String
    var image: String
    var platform: String? = nil
    var command: [String] = []
    var environment: [String: String] = [:]
    var ports: [String] = []
    var labels: [String: String] = [:]
    var networks: [String] = []
    var networkAliases: [String: [String]] = [:]
    var networkEndpointSettings: [String: DockerEndpointSettings] = [:]
    var volumes: [String] = []
    var restart: String?
    var nanoCPUs: Int64?
    var memoryLimitBytes: Int64?
    var mounts: [ContainerMount] = []
    var volumeTargets: [String] = []
    var hostname: String? = nil
    var domainname: String? = nil
    var macAddress: String? = nil
    var user: String? = nil
    var workingDir: String? = nil
    var entrypoint: [String] = []
    var shell: [String] = []
    var tty: Bool = false
    var openStdin: Bool = false
    var stdinOnce: Bool = false
    var stopSignal: String? = nil
    var stopTimeout: Int? = nil
    var networkMode: String? = nil
    var autoRemove: Bool? = nil
    var privileged: Bool? = nil
    var initProcessEnabled: Bool? = nil
    var capAdd: [String] = []
    var capDrop: [String] = []
    var dns: [String] = []
    var dnsOptions: [String] = []
    var dnsSearch: [String] = []
    var extraHosts: [String] = []
    var groupAdd: [String] = []
    var ipcMode: String? = nil
    var pidMode: String? = nil
    var usernsMode: String? = nil
    var readonlyRootfs: Bool? = nil
    var shmSize: Int64? = nil
    var tmpfs: [String: String] = [:]
    var attachStdin: Bool? = nil
    var attachStdout: Bool? = nil
    var attachStderr: Bool? = nil
    var healthcheck: DockerHealthConfig? = nil
    var networkDisabled: Bool? = nil
    var containerIDFile: String? = nil
    var logConfig: DockerLogConfig? = nil
    var volumeDriver: String? = nil
    var volumesFrom: [String] = []
    var consoleSize: [Int] = []
    var annotations: [String: String] = [:]
    var cgroupnsMode: String? = nil
    var cgroup: String? = nil
    var links: [String] = []
    var oomScoreAdj: Int? = nil
    var publishAllPorts: Bool? = nil
    var securityOpt: [String] = []
    var storageOpt: [String: String] = [:]
    var utsMode: String? = nil
    var sysctls: [String: String] = [:]
    var runtimeName: String? = nil
    var isolation: String? = nil
    var maskedPaths: [String] = []
    var readonlyPaths: [String] = []
    var resources: ContainerResourceUpdate = ContainerResourceUpdate()
}

struct ExecResult: Sendable {
    var exitCode: Int
    var output: String
    var succeeded: Bool { exitCode == 0 }
}

struct DockerBlkioWeightDevice: Codable, Sendable, Equatable, Hashable {
    var Path: String? = nil
    var Weight: Int64? = nil
}

struct DockerThrottleDevice: Codable, Sendable, Equatable, Hashable {
    var Path: String? = nil
    var Rate: Int64? = nil
}

struct DockerDeviceMapping: Codable, Sendable, Equatable, Hashable {
    var PathOnHost: String? = nil
    var PathInContainer: String? = nil
    var CgroupPermissions: String? = nil
}

struct DockerDeviceRequest: Codable, Sendable, Equatable, Hashable {
    var Driver: String? = nil
    var Count: Int? = nil
    var DeviceIDs: [String]? = nil
    var Capabilities: [[String]]? = nil
    var Options: [String: String]? = nil
}

struct DockerUlimit: Codable, Sendable, Equatable, Hashable {
    var Name: String? = nil
    var Soft: Int64? = nil
    var Hard: Int64? = nil
}

struct DockerHealthConfig: Codable, Sendable, Equatable, Hashable {
    var Test: [String]? = nil
    var Interval: Int64? = nil
    var Timeout: Int64? = nil
    var Retries: Int? = nil
    var StartPeriod: Int64? = nil
    var StartInterval: Int64? = nil
}

struct DockerLogConfig: Codable, Sendable, Equatable, Hashable {
    var `Type`: String? = nil
    var Config: [String: String]? = nil
}

struct ContainerResourceUpdate: Codable, Sendable, Equatable, Hashable {
    var nanoCPUs: Int64? = nil
    var cpuShares: Int64? = nil
    var cgroupParent: String? = nil
    var cpuPeriod: Int64? = nil
    var cpuQuota: Int64? = nil
    var cpuRealtimePeriod: Int64? = nil
    var cpuRealtimeRuntime: Int64? = nil
    var cpusetCPUs: String? = nil
    var cpusetMems: String? = nil
    var devices: [DockerDeviceMapping]? = nil
    var deviceCgroupRules: [String]? = nil
    var deviceRequests: [DockerDeviceRequest]? = nil
    var memoryLimitBytes: Int64? = nil
    var kernelMemoryTCPBytes: Int64? = nil
    var memoryReservationBytes: Int64? = nil
    var memorySwapBytes: Int64? = nil
    var memorySwappiness: Int64? = nil
    var oomKillDisable: Bool? = nil
    var initProcessEnabled: Bool? = nil
    var pidsLimit: Int64? = nil
    var blkioWeight: Int64? = nil
    var blkioWeightDevice: [DockerBlkioWeightDevice]? = nil
    var blkioDeviceReadBps: [DockerThrottleDevice]? = nil
    var blkioDeviceWriteBps: [DockerThrottleDevice]? = nil
    var blkioDeviceReadIOps: [DockerThrottleDevice]? = nil
    var blkioDeviceWriteIOps: [DockerThrottleDevice]? = nil
    var cpuCount: Int64? = nil
    var cpuPercent: Int64? = nil
    var ioMaximumIOps: Int64? = nil
    var ioMaximumBandwidth: Int64? = nil
    var restartPolicy: String? = nil
    var restartMaximumRetryCount: Int? = nil
    var ulimits: [DockerUlimit]? = nil
}

enum RuntimeFeatureError: Error, Sendable, Equatable, CustomStringConvertible {
    case unsupported(String)

    var description: String {
        switch self {
        case .unsupported(let message): message
        }
    }
}

protocol ContainerRuntime: Sendable {
    var kind: RuntimeKind { get }
    /// Stable identity for resumable migration ownership. `kind` alone is not enough because
    /// OrbStack, Docker Desktop, Colima, and arbitrary sockets are all Docker runtimes.
    var migrationSourceIdentifier: String { get }
    func snapshot() async throws -> RuntimeSnapshot
    /// Migration cannot treat a failed images/volumes/networks endpoint as an empty inventory.
    /// Interactive tables may remain partially available, but this read must be all-or-nothing.
    func migrationSnapshot() async throws -> RuntimeSnapshot
    /// Exact writable-layer bytes by container ID. Migration snapshots non-empty layers so files
    /// created outside named volumes are not silently lost. Created containers may report no size
    /// and are normalized to zero by Docker backends; every other omission fails closed.
    func migrationContainerWritableSizes() async throws -> [String: Int64]
    func start(containerID: String) async throws
    func stop(containerID: String) async throws
    func restart(containerID: String) async throws
    func kill(containerID: String, signal: String?) async throws
    func pause(containerID: String) async throws
    func unpause(containerID: String) async throws
    func rename(containerID: String, name: String) async throws
    func update(containerID: String, resources: ContainerResourceUpdate) async throws
    func resize(containerID: String, height: Int?, width: Int?) async throws
    func remove(containerID: String) async throws
    func pruneContainers() async throws
    func logs(containerID: String) async throws -> [LogLine]
    func env(containerID: String) async throws -> [EnvVar]

    func pull(image: String, registryAuth: String?) async throws
    func create(_ spec: ContainerSpec) async throws -> String
    func exec(containerID: String, command: [String]) async throws -> ExecResult
    func createNetwork(name: String, labels: [String: String]) async throws
    func removeNetwork(name: String) async throws
    func pruneNetworks() async throws
    func connectNetwork(name: String, containerID: String) async throws
    func disconnectNetwork(name: String, containerID: String, force: Bool) async throws
    func createVolume(name: String, driver: String?, labels: [String: String], driverOptions: [String: String]) async throws
    func removeVolume(name: String) async throws
    func pruneVolumes() async throws
    func removeImage(id: String) async throws
    func pruneImages() async throws
    func tagImage(source: String, repo: String, tag: String) async throws
    func pushImage(reference: String, registryAuth: String?) async throws -> AsyncStream<Data>
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
    func copyOutStream(containerID: String, path: String) -> AsyncThrowingStream<Data, Error>
    func copyIn(containerID: String, path: String, archiveStream: AsyncThrowingStream<Data, Error>) async -> Bool
    func copyInThrowing(
        containerID: String,
        path: String,
        archiveStream: AsyncThrowingStream<Data, Error>
    ) async throws
    func build(contextTar: Data, query: String, registryHeaders: [(name: String, value: String)]) -> AsyncStream<Data>
    func commit(containerID: String, repo: String, tag: String, labels: [String: String]) async throws -> String
    func commit(
        containerID: String,
        repo: String,
        tag: String,
        labels: [String: String],
        pause: Bool
    ) async throws -> String
    var supportsImageArchiveTransfer: Bool { get }
    func saveImage(reference: String) -> AsyncStream<Data>
    func saveImageThrowing(reference: String) -> AsyncThrowingStream<Data, Error>
    func saveImages(references: [String]) async throws -> AsyncStream<Data>
    func loadImage(tar: Data) async throws
    func loadImage(stream: AsyncStream<Data>) async throws
    func loadImageThrowing(stream: AsyncThrowingStream<Data, Error>) async throws

    // Raw passthrough for hijack/bidirectional endpoints (interactive exec, attach) — supported by
    // backends that front a Docker-compatible socket. Default: unsupported.
    var supportsRawProxy: Bool { get }
    func proxyRequest(method: String, path: String, headers: [(name: String, value: String)], body: Data) async -> HTTPResponse?
    nonisolated func proxyHijack(requestData: Data, clientFD: Int32)
}

extension ContainerRuntime {
    var migrationSourceIdentifier: String { kind.rawValue }
    func migrationSnapshot() async throws -> RuntimeSnapshot { try await snapshot() }
    func migrationContainerWritableSizes() async throws -> [String: Int64] {
        let snapshot = try await migrationSnapshot()
        return Dictionary(uniqueKeysWithValues: snapshot.containers.map { ($0.id, 0) })
    }
    func pull(image: String, registryAuth: String?) async throws {}
    func pull(image: String) async throws { try await pull(image: image, registryAuth: nil) }
    func kill(containerID: String, signal: String?) async throws {
        try await stop(containerID: containerID)
    }
    func pause(containerID: String) async throws {
        throw RuntimeFeatureError.unsupported("pause is not supported by \(kind.displayName)")
    }
    func unpause(containerID: String) async throws {
        throw RuntimeFeatureError.unsupported("unpause is not supported by \(kind.displayName)")
    }
    func rename(containerID: String, name: String) async throws {
        throw RuntimeFeatureError.unsupported("rename is not supported by \(kind.displayName)")
    }
    func update(containerID: String, resources: ContainerResourceUpdate) async throws {
        throw RuntimeFeatureError.unsupported("container update is not supported by \(kind.displayName)")
    }
    func resize(containerID: String, height: Int?, width: Int?) async throws {}
    func pruneContainers() async throws {}
    func createNetwork(name: String, labels: [String: String]) async throws {}
    func removeNetwork(name: String) async throws {}
    func pruneNetworks() async throws {}
    func connectNetwork(name: String, containerID: String) async throws {
        throw RuntimeFeatureError.unsupported("network connect is not supported by \(kind.displayName)")
    }
    func disconnectNetwork(name: String, containerID: String, force: Bool) async throws {
        throw RuntimeFeatureError.unsupported("network disconnect is not supported by \(kind.displayName)")
    }
    func createVolume(name: String) async throws {
        try await createVolume(name: name, driver: nil, labels: [:], driverOptions: [:])
    }
    func createVolume(name: String, driver: String?, labels: [String: String], driverOptions: [String: String]) async throws {}
    func removeVolume(name: String) async throws {}
    func pruneVolumes() async throws {}
    func removeImage(id: String) async throws {}
    func pruneImages() async throws {}
    func tagImage(source: String, repo: String, tag: String) async throws {
        throw RuntimeFeatureError.unsupported("image tag is not supported by \(kind.displayName)")
    }
    func pushImage(reference: String, registryAuth: String?) async throws -> AsyncStream<Data> {
        throw RuntimeFeatureError.unsupported("image push is not supported by \(kind.displayName)")
    }
    func pushImage(reference: String) async throws -> AsyncStream<Data> {
        try await pushImage(reference: reference, registryAuth: nil)
    }
    func login(registry: String, username: String, password: String) async throws {
        try DockerRegistry.persistDockerAuth(server: registry, username: username, password: password)
    }
    func inspectImage(id: String) async -> ImageDetail? { nil }
    func inspectNetwork(name: String) async -> NetworkDetail? { nil }
    func sampleCPU(containerID: String) async -> Double? { nil }
    func startMachine(name: String) async throws {}
    func stopMachine(name: String) async throws {}
    func streamLogs(containerID: String) -> AsyncStream<LogLine> { AsyncStream { $0.finish() } }
    func containerExitCode(_ id: String) async -> Int? { nil }
    func copyOut(containerID: String, path: String) async -> Data? { nil }
    func copyIn(containerID: String, path: String, archive: Data) async -> Bool { false }
    func copyOutStream(containerID: String, path: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            Task {
                if let data = await copyOut(containerID: containerID, path: path), !data.isEmpty {
                    continuation.yield(data)
                }
                continuation.finish()
            }
        }
    }
    func copyIn(containerID: String, path: String, archiveStream: AsyncThrowingStream<Data, Error>) async -> Bool {
        var archive = Data()
        do {
            for try await chunk in archiveStream { archive.append(chunk) }
        } catch {
            return false
        }
        return await copyIn(containerID: containerID, path: path, archive: archive)
    }
    func copyInThrowing(
        containerID: String,
        path: String,
        archiveStream: AsyncThrowingStream<Data, Error>
    ) async throws {
        guard await copyIn(containerID: containerID, path: path, archiveStream: archiveStream) else {
            throw RuntimeFeatureError.unsupported("volume archive copy failed")
        }
    }
    func build(contextTar: Data, query: String, registryHeaders: [(name: String, value: String)]) -> AsyncStream<Data> { AsyncStream { $0.finish() } }
    func build(contextTar: Data, query: String) -> AsyncStream<Data> { build(contextTar: contextTar, query: query, registryHeaders: []) }
    func commit(containerID: String, repo: String, tag: String, labels: [String: String]) async throws -> String { "" }
    func commit(
        containerID: String,
        repo: String,
        tag: String,
        labels: [String: String],
        pause: Bool
    ) async throws -> String {
        try await commit(containerID: containerID, repo: repo, tag: tag, labels: labels)
    }
    var supportsImageArchiveTransfer: Bool { false }
    func saveImage(reference: String) -> AsyncStream<Data> { AsyncStream { $0.finish() } }
    func saveImageThrowing(reference: String) -> AsyncThrowingStream<Data, Error> {
        let stream = saveImage(reference: reference)
        return AsyncThrowingStream { continuation in
            let task = Task {
                for await chunk in stream { continuation.yield(chunk) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func saveImages(references: [String]) async throws -> AsyncStream<Data> {
        guard references.count == 1, let reference = references.first else {
            throw RuntimeFeatureError.unsupported("multi-image save is not supported by \(kind.displayName)")
        }
        return saveImage(reference: reference)
    }
    func loadImage(tar: Data) async throws {}
    func loadImage(stream: AsyncStream<Data>) async throws {
        var archive = Data()
        var sawBytes = false
        for await chunk in stream {
            if !chunk.isEmpty { sawBytes = true }
            archive.append(chunk)
        }
        guard sawBytes else { throw HTTPError.connectionClosed }
        try await loadImage(tar: archive)
    }
    func loadImageThrowing(stream: AsyncThrowingStream<Data, Error>) async throws {
        var chunks: [Data] = []
        for try await chunk in stream { chunks.append(chunk) }
        let replay = AsyncStream<Data> { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
        try await loadImage(stream: replay)
    }
    var supportsRawProxy: Bool { false }
    func proxyRequest(method: String, path: String, headers: [(name: String, value: String)], body: Data) async -> HTTPResponse? { nil }
    nonisolated func proxyHijack(requestData: Data, clientFD: Int32) {}
}

/// The runtime the app holds before any real engine connects, and after the engine is found to be
/// off. It reports an empty, engine-off snapshot so the UI shows the genuine "no engine" state
/// instead of `MockRuntime`'s demo containers — which would otherwise leak into a real launch while
/// the engine is starting or when it fails to start.
struct DisconnectedRuntime: ContainerRuntime {
    var kind: RuntimeKind { .disconnected }

    func snapshot() async throws -> RuntimeSnapshot {
        RuntimeSnapshot(engineRunning: false, engineVersion: "")
    }

    private func off() -> RuntimeFeatureError { .unsupported("the engine is not running") }

    func start(containerID: String) async throws { throw off() }
    func stop(containerID: String) async throws { throw off() }
    func restart(containerID: String) async throws { throw off() }
    func remove(containerID: String) async throws { throw off() }
    func logs(containerID: String) async throws -> [LogLine] { [] }
    func env(containerID: String) async throws -> [EnvVar] { [] }
    func create(_ spec: ContainerSpec) async throws -> String { throw off() }
    func exec(containerID: String, command: [String]) async throws -> ExecResult { throw off() }
}

enum DockerImageOps {
    nonisolated static func commitPath(
        container: String,
        repo: String,
        tag: String,
        pause: Bool? = nil
    ) -> String {
        var path = "/commit?container=\(queryValue(container))&repo=\(queryValue(repo))&tag=\(queryValue(tag))"
        if let pause { path += "&pause=\(pause ? 1 : 0)" }
        return path
    }

    nonisolated static func tagPath(source: String, repo: String, tag: String) -> String {
        "/images/\(pathComponent(source))/tag?repo=\(queryValue(repo))&tag=\(queryValue(tag))"
    }

    nonisolated static func pushPath(name: String, tag: String?) -> String {
        let path = "/images/\(pathComponent(name))/push"
        guard let tag, !tag.isEmpty else { return path }
        return "\(path)?tag=\(queryValue(tag))"
    }

    nonisolated static func pathComponent(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    nonisolated static func queryValue(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
