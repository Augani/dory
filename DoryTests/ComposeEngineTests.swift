import Testing
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
        liveContainers.append(Container(id: id, name: spec.name, image: spec.image, status: .running,
            cpuPercent: 0, memoryDisplay: "0 MB", memoryLimitDisplay: "—", memoryFraction: 0,
            ports: Self.displayPorts(spec.ports),
            uptime: "now", created: "now", ipAddress: "—", domain: "", command: spec.command.joined(separator: " "),
            restartPolicy: spec.restart ?? spec.resources.restartPolicy ?? "no",
            labels: spec.labels,
            volumes: spec.volumes,
            nanoCPUs: spec.nanoCPUs,
            memoryLimitBytes: spec.memoryLimitBytes,
            mounts: spec.mounts,
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
            resources: spec.resources))
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
                proto: proto
            )
        }
        return display.isEmpty ? "—" : display.joined(separator: ",")
    }

    func start(containerID: String) async throws { startedIDs.append(containerID) }
    func stop(containerID: String) async throws { stoppedIDs.append(containerID) }
    func restart(containerID: String) async throws {}
    func kill(containerID: String, signal: String?) async throws {
        killedContainers.append((containerID, signal))
        update(containerID: containerID) { $0.status = .stopped }
    }
    func pause(containerID: String) async throws {
        pausedIDs.append(containerID)
        update(containerID: containerID) { $0.status = .paused }
    }
    func unpause(containerID: String) async throws {
        unpausedIDs.append(containerID)
        update(containerID: containerID) { $0.status = .running }
    }
    func rename(containerID: String, name: String) async throws {
        renamedContainers.append((containerID, name))
        update(containerID: containerID) { $0.name = name }
    }
    func update(containerID: String, resources: ContainerResourceUpdate) async throws {
        updatedContainers.append((containerID, resources))
        update(containerID: containerID) {
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
    func remove(containerID: String) async throws { removedIDs.append(containerID); liveContainers.removeAll { $0.id == containerID } }
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
    func pull(image: String) async throws {
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
    func pushImage(reference: String) async throws -> AsyncStream<Data> {
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
    var supportsImageArchiveTransfer: Bool { true }
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

    private func update(containerID: String, _ mutate: (inout Container) -> Void) {
        guard let index = liveContainers.firstIndex(where: { $0.id == containerID || $0.name == containerID || $0.id.hasPrefix(containerID) }) else { return }
        mutate(&liveContainers[index])
    }
}

@MainActor
struct ComposeEngineTests {
    let yaml = """
    services:
      web:
        image: nginx:alpine
        depends_on:
          api:
            condition: service_started
          db:
            condition: service_healthy
      api:
        image: dory/api:latest
        depends_on: [db, cache]
      db:
        image: postgres:16
        healthcheck:
          test: ["CMD", "pg_isready"]
          interval: 1s
          retries: 3
      cache:
        image: redis:7-alpine
    """

    private func service(_ name: String) -> (ContainerSpec) -> Bool { { $0.name.hasSuffix("-\(name)-1") } }

    @Test func upCreatesInDependencyOrderWaitingForHealth() async throws {
        let project = try ComposeParser.parse(yaml, projectName: "demo")
        let runtime = RecordingRuntime()
        let engine = ComposeEngine(runtime: runtime, healthPollCap: 0.02, maxHealthAttempts: 5)

        let ids = try await engine.up(project)

        #expect(ids.count == 4)
        #expect(runtime.networksCreated == ["demo_default"])

        let names = runtime.createdSpecs.map(\.name)
        func position(_ service: String) -> Int { names.firstIndex(of: "demo-\(service)-1")! }
        #expect(position("db") < position("api"))
        #expect(position("cache") < position("api"))
        #expect(position("api") < position("web"))
        #expect(position("db") < position("web"))

        // db's healthcheck was probed because web depends on it being healthy.
        #expect(runtime.execCalls.contains { $0.command == ["pg_isready"] })
        // every created container was also started and joined the project network.
        #expect(runtime.startedIDs.count == 4)
        #expect(runtime.createdSpecs.allSatisfy { $0.networks.contains("demo_default") })
        #expect(runtime.createdSpecs.first { $0.name == "demo-web-1" }?.labels["com.docker.compose.service"] == "web")
    }

    @Test func unhealthyDependencyFailsUp() async throws {
        let project = try ComposeParser.parse(yaml, projectName: "demo")
        let runtime = RecordingRuntime()
        runtime.execSucceeds = false
        let engine = ComposeEngine(runtime: runtime, healthPollCap: 0.01, maxHealthAttempts: 5)
        await #expect(throws: ComposeError.self) { try await engine.up(project) }
    }

    @Test func upContinuesWhenProjectNetworkAlreadyExists() async throws {
        let project = try ComposeParser.parse("""
        services:
          web:
            image: nginx:alpine
        """, projectName: "demo")
        let runtime = RecordingRuntime()
        runtime.preexistingNetworks = ["demo_default"]
        let engine = ComposeEngine(runtime: runtime)

        let ids = try await engine.up(project)

        #expect(ids["web"] == "id1")
        #expect(runtime.networksCreated.isEmpty)
        #expect(runtime.createdSpecs.first?.networks == ["demo_default"])
        #expect(runtime.startedIDs == ["id1"])
    }

    @Test func downStopsAndRemovesProjectContainers() async throws {
        let project = try ComposeParser.parse(yaml, projectName: "demo")
        let runtime = RecordingRuntime()
        let engine = ComposeEngine(runtime: runtime, healthPollCap: 0.02, maxHealthAttempts: 5)
        _ = try await engine.up(project)

        try await engine.down(project)
        #expect(runtime.removedIDs.count == 4)
        #expect(runtime.stoppedIDs.count == 4)
        let idByService = Dictionary(uniqueKeysWithValues: runtime.createdSpecs.enumerated().compactMap { offset, spec in
            spec.labels["com.docker.compose.service"].map { ($0, "id\(offset + 1)") }
        })
        let expected = try project.startOrder().reversed().compactMap { idByService[$0] }
        #expect(runtime.stoppedIDs == expected)
        #expect(runtime.removedIDs == expected)
    }

    @Test func teardownOrderRemovesDependentsFirst() throws {
        let project = try ComposeParser.parse(yaml, projectName: "demo")
        let containers = ["db", "cache", "api", "web"].map { service in
            Container(id: service, name: "demo-\(service)-1", image: service, status: .running,
                      cpuPercent: 0, memoryDisplay: "0", memoryLimitDisplay: "—", memoryFraction: 0,
                      ports: "—", uptime: "now", created: "now", ipAddress: "—", domain: "",
                      command: "", restartPolicy: "no", labels: ["com.docker.compose.service": service])
        }
        #expect(ComposeEngine.teardownOrder(containers: containers, startOrder: try project.startOrder()).map(\.id).first == "web")
    }

    @Test func upCreatesOnlyServiceNetworksAndSkipsNetworkModeServices() async throws {
        let yaml = """
        services:
          web:
            image: nginx:alpine
            networks: [front]
          api:
            image: dory/api:latest
            networks:
              back: {}
              front: {}
          isolated:
            image: busybox:latest
            network_mode: none
        networks:
          front: {}
          back: {}
        """
        let project = try ComposeParser.parse(yaml, projectName: "demo")
        let runtime = RecordingRuntime()
        let engine = ComposeEngine(runtime: runtime)

        _ = try await engine.up(project)

        #expect(runtime.networksCreated == ["demo_back", "demo_front"])
        #expect(runtime.createdSpecs.first { $0.name == "demo-web-1" }?.networks == ["demo_front"])
        #expect(runtime.createdSpecs.first { $0.name == "demo-api-1" }?.networks == ["demo_back", "demo_front"])
        let isolated = try #require(runtime.createdSpecs.first { $0.name == "demo-isolated-1" })
        #expect(isolated.networks.isEmpty)
        #expect(isolated.networkMode == "none")
        #expect(isolated.networkDisabled == true)

        try await engine.down(project)
        #expect(runtime.networksRemoved == ["demo_front", "demo_back"])
    }

    @Test func upSkipsInactiveProfiledServices() async throws {
        let yaml = """
        services:
          web:
            image: nginx:alpine
          debug:
            image: busybox:latest
            profiles: [debug]
            networks: [tools]
        networks:
          tools: {}
        """

        let defaultProject = try ComposeParser.parse(yaml, projectName: "demo")
        let defaultRuntime = RecordingRuntime()
        let defaultEngine = ComposeEngine(runtime: defaultRuntime)

        _ = try await defaultEngine.up(defaultProject)

        #expect(defaultRuntime.createdSpecs.map(\.name) == ["demo-web-1"])
        #expect(defaultRuntime.startedIDs == ["id1"])
        #expect(defaultRuntime.networksCreated == ["demo_default"])

        let debugProject = try ComposeParser.parse(yaml, projectName: "demo", activeProfiles: ["debug"])
        let debugRuntime = RecordingRuntime()
        let debugEngine = ComposeEngine(runtime: debugRuntime)

        _ = try await debugEngine.up(debugProject)

        #expect(debugRuntime.createdSpecs.map(\.name) == ["demo-debug-1", "demo-web-1"])
        #expect(debugRuntime.networksCreated == ["demo_default", "demo_tools"])
        #expect(debugRuntime.createdSpecs.first { $0.name == "demo-debug-1" }?.networks == ["demo_tools"])
    }

    @Test func specPreservesCommonServiceCreateOptions() throws {
        let yaml = """
        services:
          dev:
            image: dory/dev:latest
            command: ["sleep", "infinity"]
            entrypoint: ["/usr/bin/env"]
            environment:
              APP_ENV: dev
            ports: ["127.0.0.1:8080:80"]
            volumes: ["/Users/me/app:/workspace:ro"]
            hostname: devbox
            domainname: local.test
            user: "1000:1000"
            working_dir: /workspace
            tty: true
            stdin_open: true
            init: true
            read_only: true
            privileged: true
            cap_add: [NET_ADMIN]
            cap_drop: [MKNOD]
            dns: ["1.1.1.1"]
            dns_opt: ["ndots:0"]
            dns_search: [dory.local]
            extra_hosts: ["host.docker.internal:host-gateway"]
            group_add: ["staff"]
            network_mode: none
            tmpfs: ["/tmp:rw,noexec"]
            sysctls:
              net.ipv4.ip_forward: "1"
            security_opt: ["no-new-privileges:true"]
            storage_opt:
              size: 20G
            logging:
              driver: json-file
              options:
                max-size: 10m
            ulimits:
              nofile:
                soft: 1024
                hard: 2048
            healthcheck:
              test: ["CMD-SHELL", "curl -f http://localhost/health || exit 1"]
              interval: 2s
              timeout: 1s
              retries: 4
              start_period: 10s
              start_interval: 1s
            stop_signal: SIGTERM
            stop_grace_period: 15s
            shm_size: 64m
            mem_limit: 512m
            mem_reservation: 256m
            memswap_limit: 1g
            mem_swappiness: 10
            oom_kill_disable: true
            oom_score_adj: 200
            pids_limit: 128
            ipc: host
            pid: host
            userns_mode: host
            uts: host
            runtime: runc
            isolation: default
            links: ["redis:redis"]
            volumes_from: ["parent:ro"]
        """
        let project = try ComposeParser.parse(yaml, projectName: "demo")
        let service = try #require(project.service(named: "dev"))
        let spec = ComposeEngine(runtime: RecordingRuntime()).spec(for: service, in: project)

        #expect(spec.name == "demo-dev-1")
        #expect(spec.image == "dory/dev:latest")
        #expect(spec.command == ["sleep", "infinity"])
        #expect(spec.entrypoint == ["/usr/bin/env"])
        #expect(spec.environment["APP_ENV"] == "dev")
        #expect(spec.ports == ["127.0.0.1:8080:80"])
        #expect(spec.volumes == ["/Users/me/app:/workspace:ro"])
        #expect(spec.hostname == "devbox")
        #expect(spec.domainname == "local.test")
        #expect(spec.user == "1000:1000")
        #expect(spec.workingDir == "/workspace")
        #expect(spec.tty)
        #expect(spec.openStdin)
        #expect(spec.attachStdin == true)
        #expect(spec.stopSignal == "SIGTERM")
        #expect(spec.stopTimeout == 15)
        #expect(spec.networkMode == "none")
        #expect(spec.networkDisabled == true)
        #expect(spec.privileged == true)
        #expect(spec.initProcessEnabled == true)
        #expect(spec.readonlyRootfs == true)
        #expect(spec.capAdd == ["NET_ADMIN"])
        #expect(spec.capDrop == ["MKNOD"])
        #expect(spec.dns == ["1.1.1.1"])
        #expect(spec.dnsOptions == ["ndots:0"])
        #expect(spec.dnsSearch == ["dory.local"])
        #expect(spec.extraHosts == ["host.docker.internal:host-gateway"])
        #expect(spec.groupAdd == ["staff"])
        #expect(spec.ipcMode == "host")
        #expect(spec.pidMode == "host")
        #expect(spec.usernsMode == "host")
        #expect(spec.shmSize == 67_108_864)
        #expect(spec.tmpfs["/tmp"] == "rw,noexec")
        #expect(spec.logConfig == DockerLogConfig(Type: "json-file", Config: ["max-size": "10m"]))
        #expect(spec.healthcheck == DockerHealthConfig(
            Test: ["CMD-SHELL", "curl -f http://localhost/health || exit 1"],
            Interval: 2_000_000_000,
            Timeout: 1_000_000_000,
            Retries: 4,
            StartPeriod: 10_000_000_000,
            StartInterval: 1_000_000_000
        ))
        #expect(spec.memoryLimitBytes == 536_870_912)
        #expect(spec.resources.memoryReservationBytes == 268_435_456)
        #expect(spec.resources.memorySwapBytes == 1_073_741_824)
        #expect(spec.resources.memorySwappiness == 10)
        #expect(spec.resources.oomKillDisable == true)
        #expect(spec.resources.pidsLimit == 128)
        #expect(spec.resources.ulimits == [DockerUlimit(Name: "nofile", Soft: 1024, Hard: 2048)])
        #expect(spec.volumesFrom == ["parent:ro"])
        #expect(spec.links == ["redis:redis"])
        #expect(spec.oomScoreAdj == 200)
        #expect(spec.securityOpt == ["no-new-privileges:true"])
        #expect(spec.storageOpt["size"] == "20G")
        #expect(spec.utsMode == "host")
        #expect(spec.sysctls["net.ipv4.ip_forward"] == "1")
        #expect(spec.runtimeName == "runc")
        #expect(spec.isolation == "default")
    }
}
