import Foundation
@testable import Dory

private final class RecordingLogStore: @unchecked Sendable {
    private let lock = NSLock()
    private var historical: [LogLine] = []
    private var streamed: [LogLine] = []

    var historicalLines: [LogLine] {
        get { lock.lock(); defer { lock.unlock() }; return historical }
        set { lock.lock(); historical = newValue; lock.unlock() }
    }

    var streamedLines: [LogLine] {
        get { lock.lock(); defer { lock.unlock() }; return streamed }
        set { lock.lock(); streamed = newValue; lock.unlock() }
    }
}

@MainActor
final class RecordingRuntime: ContainerRuntime {
    let kind: RuntimeKind = .mock
    var createdSpecs: [ContainerSpec] = []
    var startedIDs: [String] = []
    var execCalls: [(id: String, command: [String])] = []
    var networksCreated: [String] = []
    var networksRemoved: [String] = []
    var networksConnected: [(name: String, containerID: String)] = []
    var networksDisconnected: [(name: String, containerID: String, force: Bool)] = []
    var preexistingNetworks: Set<String> = []
    var missingNetworks: Set<String> = []
    var volumesCreated: [String] = []
    var volumeCreateRequests: [(name: String, driver: String?, labels: [String: String], driverOptions: [String: String])] = []
    var volumesRemoved: [String] = []
    var preexistingVolumes: Set<String> = []
    var imagesRemoved: [String] = []
    var volumes: [Volume] = []
    var images: [DockerImage] = [
        DockerImage(
            repository: "dory/web-api",
            tag: "latest",
            imageID: "sha256:recording-web-api",
            size: "128 MB",
            created: "now",
            usedByCount: 0,
            sizeBytes: 128 * 1024 * 1024,
            createdEpoch: 10
        ),
    ]
    var prunedNetworks = false
    var prunedVolumes = false
    var prunedImages = false
    var prunedContainers = false
    var stoppedIDs: [String] = []
    var killedContainers: [(id: String, signal: String?)] = []
    var pausedIDs: [String] = []
    var unpausedIDs: [String] = []
    var renamedContainers: [(id: String, name: String)] = []
    var updatedContainers: [(id: String, resources: ContainerResourceUpdate)] = []
    var resizedContainers: [(id: String, height: Int?, width: Int?)] = []
    var removedIDs: [String] = []
    var committedImages: [(containerID: String, repo: String, tag: String, labels: [String: String])] = []
    var taggedImages: [(source: String, repo: String, tag: String)] = []
    var pushedImages: [String] = []
    var savedImages: [String] = []
    var savedImageBatches: [[String]] = []
    var loadedImageArchives: [Data] = []
    var imageArchiveChunks: [Data] = [Data("dory-image-archive".utf8)]
    var imagePushChunks: [Data] = [Data(#"{"status":"pushed"}"#.utf8) + Data("\n".utf8)]
    var pulledImages: [String] = []
    var pullError: Error?
    var copiedOutPaths: [(containerID: String, path: String)] = []
    var copiedInArchives: [(containerID: String, path: String, archive: Data)] = []
    var copyOutArchive: Data?
    var loggedIDs: [String] = []
    var logins: [(registry: String, username: String, password: String)] = []
    private let logStore = RecordingLogStore()
    var logLines: [LogLine] {
        get { logStore.historicalLines }
        set { logStore.historicalLines = newValue }
    }
    var streamedLogLines: [LogLine] {
        get { logStore.streamedLines }
        set { logStore.streamedLines = newValue }
    }
    var execSucceeds = true
    var exitCode: Int?
    private var counter = 0
    private var liveContainers: [Container] = []

    func snapshot() async throws -> RuntimeSnapshot {
        RuntimeSnapshot(containers: liveContainers, images: images, volumes: volumes)
    }

    func create(_ spec: ContainerSpec) async throws -> String {
        createdSpecs.append(spec)
        counter += 1
        let id = "id\(counter)"
        let resolvedMounts = spec.mounts.map { mount -> ContainerMount in
            guard mount.type == "volume", mount.source == nil else { return mount }
            var mount = mount
            mount.source = "anonymous-\(counter)"
            return mount
        }
        liveContainers.append(Container(
            id: id,
            name: spec.name,
            image: spec.image,
            status: .running,
            cpuPercent: 0,
            memoryDisplay: "0 MB",
            memoryLimitDisplay: "—",
            memoryFraction: 0,
            ports: Self.displayPorts(spec.ports),
            uptime: "now",
            created: "now",
            ipAddress: "—",
            domain: "",
            command: spec.command.joined(separator: " "),
            restartPolicy: spec.restart ?? spec.resources.restartPolicy ?? "no",
            labels: spec.labels,
            volumes: spec.volumes,
            nanoCPUs: spec.nanoCPUs,
            memoryLimitBytes: spec.memoryLimitBytes,
            mounts: resolvedMounts,
            volumeTargets: spec.volumeTargets,
            networks: spec.networks,
            networkEndpointSettings: spec.networkEndpointSettings,
            commandArgs: spec.command,
            entrypoint: spec.entrypoint,
            hostname: spec.hostname,
            domainname: spec.domainname,
            user: spec.user,
            workingDir: spec.workingDir,
            shell: spec.shell,
            tty: spec.tty,
            openStdin: spec.openStdin,
            stdinOnce: spec.stdinOnce,
            stopSignal: spec.stopSignal,
            stopTimeout: spec.stopTimeout,
            networkMode: spec.networkMode,
            autoRemove: spec.autoRemove,
            privileged: spec.privileged,
            initProcessEnabled: spec.initProcessEnabled,
            capAdd: spec.capAdd,
            capDrop: spec.capDrop,
            dns: spec.dns,
            dnsOptions: spec.dnsOptions,
            dnsSearch: spec.dnsSearch,
            extraHosts: spec.extraHosts,
            groupAdd: spec.groupAdd,
            ipcMode: spec.ipcMode,
            pidMode: spec.pidMode,
            usernsMode: spec.usernsMode,
            readonlyRootfs: spec.readonlyRootfs,
            shmSize: spec.shmSize,
            tmpfs: spec.tmpfs,
            attachStdin: spec.attachStdin,
            attachStdout: spec.attachStdout,
            attachStderr: spec.attachStderr,
            healthcheck: spec.healthcheck,
            networkDisabled: spec.networkDisabled,
            containerIDFile: spec.containerIDFile,
            logConfig: spec.logConfig,
            volumeDriver: spec.volumeDriver,
            volumesFrom: spec.volumesFrom,
            consoleSize: spec.consoleSize,
            annotations: spec.annotations,
            cgroupnsMode: spec.cgroupnsMode,
            cgroup: spec.cgroup,
            links: spec.links,
            oomScoreAdj: spec.oomScoreAdj,
            publishAllPorts: spec.publishAllPorts,
            securityOpt: spec.securityOpt,
            storageOpt: spec.storageOpt,
            utsMode: spec.utsMode,
            sysctls: spec.sysctls,
            runtimeName: spec.runtimeName,
            isolation: spec.isolation,
            maskedPaths: spec.maskedPaths,
            readonlyPaths: spec.readonlyPaths,
            resources: spec.resources
        ))
        return id
    }

    private static func displayPorts(_ ports: [String]) -> String {
        let display = ports.compactMap { mapping -> String? in
            let parsed = DockerCreateBody.parsePort(mapping)
            guard let key = parsed.key else { return nil }
            let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
            guard let containerPort = parts.first.flatMap(Int.init) else { return nil }
            let proto = parts.count > 1 ? parts[1] : "tcp"
            return ContainerPortDisplay.dockerDisplay(
                hostIP: parsed.hostIP,
                hostPort: parsed.hostPort.flatMap(Int.init),
                containerPort: containerPort,
                proto: proto,
                hasHostBinding: parsed.hostPort != nil
            )
        }
        return display.isEmpty ? "—" : display.joined(separator: ",")
    }

    func start(containerID: String) async throws { startedIDs.append(containerID) }
    func stop(containerID: String) async throws { stoppedIDs.append(containerID) }
    func restart(containerID: String) async throws {}
    func kill(containerID: String, signal: String?) async throws {
        killedContainers.append((containerID, signal))
        mutate(containerID: containerID) { $0.status = .stopped }
    }
    func pause(containerID: String) async throws {
        pausedIDs.append(containerID)
        mutate(containerID: containerID) { $0.status = .paused }
    }
    func unpause(containerID: String) async throws {
        unpausedIDs.append(containerID)
        mutate(containerID: containerID) { $0.status = .running }
    }
    func rename(containerID: String, name: String) async throws {
        renamedContainers.append((containerID, name))
        mutate(containerID: containerID) { $0.name = name }
    }
    func update(containerID: String, resources: ContainerResourceUpdate) async throws {
        updatedContainers.append((containerID, resources))
        mutate(containerID: containerID) {
            if let nanoCPUs = resources.nanoCPUs { $0.nanoCPUs = nanoCPUs }
            if let memoryLimitBytes = resources.memoryLimitBytes {
                $0.memoryLimitBytes = memoryLimitBytes
                $0.memoryLimitDisplay = DockerFormat.bytes(memoryLimitBytes)
            }
            if let restartPolicy = resources.restartPolicy { $0.restartPolicy = restartPolicy }
            $0.resources = resources
        }
    }
    func resize(containerID: String, height: Int?, width: Int?) async throws {
        resizedContainers.append((containerID, height, width))
    }
    func remove(containerID: String) async throws {
        removedIDs.append(containerID)
        liveContainers.removeAll { $0.id == containerID }
    }
    func logs(containerID: String) async throws -> [LogLine] {
        loggedIDs.append(containerID)
        return logStore.historicalLines
    }
    nonisolated func streamLogs(containerID: String) -> AsyncStream<LogLine> {
        let lines = logStore.streamedLines
        return AsyncStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }
    func env(containerID: String) async throws -> [EnvVar] { [] }
    func pull(image: String, registryAuth: String?) async throws {
        pulledImages.append(image)
        if let pullError { throw pullError }
    }
    func login(registry: String, username: String, password: String) async throws {
        logins.append((registry, username, password))
    }
    func exec(containerID: String, command: [String]) async throws -> ExecResult {
        execCalls.append((containerID, command))
        return ExecResult(exitCode: execSucceeds ? 0 : 1, output: "")
    }
    func containerExitCode(_ id: String) async -> Int? { exitCode }
    func createNetwork(name: String, labels: [String: String]) async throws {
        if preexistingNetworks.contains(name) {
            throw ShellError.nonZeroExit(1, "Error: network \(name) already exists")
        }
        networksCreated.append(name)
    }
    func removeNetwork(name: String) async throws {
        if missingNetworks.contains(name) {
            throw ShellError.nonZeroExit(1, #"Error: failed to delete one or more networks: ["\#(name)"]"#)
        }
        networksRemoved.append(name)
    }
    func connectNetwork(name: String, containerID: String) async throws {
        networksConnected.append((name, containerID))
    }
    func disconnectNetwork(name: String, containerID: String, force: Bool) async throws {
        networksDisconnected.append((name, containerID, force))
    }
    func createVolume(
        name: String,
        driver: String?,
        labels: [String: String],
        driverOptions: [String: String]
    ) async throws {
        if preexistingVolumes.contains(name) {
            throw ShellError.nonZeroExit(1, "Error: volume \(name) already exists")
        }
        volumesCreated.append(name)
        volumeCreateRequests.append((name, driver, labels, driverOptions))
        if !volumes.contains(where: { $0.name == name }) {
            volumes.append(Volume(
                name: name,
                size: "0 B",
                driver: driver ?? "local",
                usedBy: "—",
                created: "now",
                labels: labels,
                options: driverOptions
            ))
        }
    }
    func removeVolume(name: String) async throws {
        volumesRemoved.append(name)
        volumes.removeAll { $0.name == name }
    }
    func removeImage(id: String) async throws {
        imagesRemoved.append(id)
        let normalized = id.replacingOccurrences(of: "sha256:", with: "")
        images.removeAll { image in
            let reference = image.tag.isEmpty ? image.repository : "\(image.repository):\(image.tag)"
            let imageID = image.imageID.replacingOccurrences(of: "sha256:", with: "")
            return reference == id
                || (image.repository == id && image.tag == "latest")
                || image.imageID == id
                || imageID == normalized
                || imageID.hasPrefix(normalized)
        }
    }
    func pruneContainers() async throws { prunedContainers = true }
    func pruneNetworks() async throws { prunedNetworks = true }
    func pruneVolumes() async throws { prunedVolumes = true }
    func pruneImages() async throws { prunedImages = true }
    func tagImage(source: String, repo: String, tag: String) async throws {
        taggedImages.append((source, repo, tag))
    }
    func pushImage(reference: String, registryAuth: String?) async throws -> AsyncStream<Data> {
        pushedImages.append(reference)
        let chunks = imagePushChunks
        return AsyncStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
    func commit(containerID: String, repo: String, tag: String, labels: [String: String]) async throws -> String {
        committedImages.append((containerID, repo, tag, labels))
        return "sha256:commit\(committedImages.count)"
    }
    nonisolated var supportsImageArchiveTransfer: Bool { true }
    func saveImage(reference: String) -> AsyncStream<Data> {
        savedImages.append(reference)
        let chunks = imageArchiveChunks
        return AsyncStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
    func saveImages(references: [String]) async throws -> AsyncStream<Data> {
        savedImageBatches.append(references)
        savedImages.append(contentsOf: references)
        let chunks = imageArchiveChunks
        return AsyncStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
    func loadImage(tar: Data) async throws { loadedImageArchives.append(tar) }
    func copyOut(containerID: String, path: String) async -> Data? {
        copiedOutPaths.append((containerID, path))
        return copyOutArchive
    }
    func copyIn(containerID: String, path: String, archive: Data) async -> Bool {
        copiedInArchives.append((containerID, path, archive))
        return true
    }

    private func mutate(containerID: String, _ mutate: (inout Container) -> Void) {
        guard let index = liveContainers.firstIndex(where: {
            $0.id == containerID || $0.name == containerID || $0.id.hasPrefix(containerID)
        }) else { return }
        mutate(&liveContainers[index])
    }
}
