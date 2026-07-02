import Foundation

enum DockerFormat {
    nonisolated static func bytes(_ value: Int64?) -> String {
        guard let value, value > 0 else { return "0 MB" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var size = Double(value)
        var unit = 0
        while size >= 1024 && unit < units.count - 1 { size /= 1024; unit += 1 }
        if unit >= 2 { return String(format: size >= 100 ? "%.0f %@" : "%.1f %@", size, units[unit]) }
        return String(format: "%.0f %@", size, units[unit])
    }

    nonisolated static func relative(unix seconds: Int?) -> String {
        guard let seconds, seconds > 0 else { return "—" }
        return relative(interval: Date().timeIntervalSince1970 - Double(seconds))
    }

    nonisolated static func relative(iso: String?) -> String {
        guard let iso, let date = iso8601(iso) else { return "—" }
        return relative(interval: Date().timeIntervalSince(date))
    }

    nonisolated static func relative(interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        switch seconds {
        case 0..<60: return "just now"
        case 60..<3600: return "\(seconds / 60) minute\(seconds / 60 == 1 ? "" : "s") ago"
        case 3600..<86400: return "\(seconds / 3600) hour\(seconds / 3600 == 1 ? "" : "s") ago"
        default: return "\(seconds / 86400) day\(seconds / 86400 == 1 ? "" : "s") ago"
        }
    }

    nonisolated static func uptime(iso: String?) -> String {
        guard let iso, let date = iso8601(iso) else { return "—" }
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60
        if hours > 24 { return "\(hours / 24)d \(hours % 24)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(seconds)s"
    }

    nonisolated static func ports(_ ports: [DockerPort]?) -> String {
        guard let ports, !ports.isEmpty else { return "—" }
        var seen = Set<String>()
        var result: [String] = []
        for port in ports {
            guard let priv = port.privatePort else { continue }
            let text = ContainerPortDisplay.dockerDisplay(
                hostIP: port.ip,
                hostPort: port.publicPort,
                containerPort: priv,
                proto: port.type
            )
            if seen.insert(text).inserted { result.append(text) }
        }
        return result.isEmpty ? "—" : result.joined(separator: ", ")
    }

    nonisolated static func exitCode(from status: String?) -> Int? {
        guard let status,
              let start = status.range(of: "Exited (")?.upperBound,
              let end = status[start...].firstIndex(of: ")") else { return nil }
        return Int(status[start..<end])
    }

    private nonisolated static func iso8601(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

enum DockerEngineSocketDiscovery {
    private nonisolated struct DockerConfig: Decodable {
        var currentContext: String?
    }

    private nonisolated struct ContextMeta: Decodable {
        var name: String?
        var endpoints: [String: ContextEndpoint]?

        enum CodingKeys: String, CodingKey {
            case name = "Name"
            case endpoints = "Endpoints"
        }
    }

    private nonisolated struct ContextEndpoint: Decodable {
        var host: String?

        enum CodingKeys: String, CodingKey {
            case host = "Host"
        }
    }

    nonisolated static func candidates(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        excluding excludedPaths: [String] = []
    ) -> [String] {
        var paths: [String] = []
        let exclusions = Set(excludedPaths + [doryShimSocket(home: home)])

        if let path = unixPath(from: environment["DOCKER_HOST"]) {
            paths.append(path)
        }

        let contexts = contextSockets(home: home, fileManager: fileManager)
        if let namedContext = environment["DOCKER_CONTEXT"], !namedContext.isEmpty {
            paths += contexts.filter { $0.name == namedContext }.map(\.path)
        } else if let current = currentDockerContext(home: home, fileManager: fileManager), !current.isEmpty, current != "default" {
            paths += contexts.filter { $0.name == current }.map(\.path)
        }
        paths += contexts.map(\.path)

        paths += commonSockets(home: home)
        return uniqued(paths).filter { !exclusions.contains($0) }
    }

    private nonisolated static func doryShimSocket(home: String) -> String {
        "\(home)/.dory/dory.sock"
    }

    private nonisolated static func commonSockets(home: String) -> [String] {
        [
            "/var/run/docker.sock",
            "\(home)/.orbstack/run/docker.sock",
            "\(home)/.docker/run/docker.sock",
            "\(home)/.colima/default/docker.sock",
            "\(home)/.rd/docker.sock",
            "\(home)/.local/share/containers/podman/machine/podman-machine-default/podman.sock",
            "\(home)/.local/share/containers/podman/machine/default/podman.sock",
        ]
    }

    private nonisolated static func currentDockerContext(home: String, fileManager: FileManager) -> String? {
        let url = URL(fileURLWithPath: home).appendingPathComponent(".docker/config.json")
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(DockerConfig.self, from: data) else { return nil }
        return config.currentContext
    }

    private nonisolated static func contextSockets(home: String, fileManager: FileManager) -> [(name: String, path: String)] {
        let root = URL(fileURLWithPath: home).appendingPathComponent(".docker/contexts/meta")
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { entry -> (name: String, path: String)? in
                let url = entry.appendingPathComponent("meta.json")
                guard fileManager.fileExists(atPath: url.path),
                      let data = try? Data(contentsOf: url),
                      let meta = try? JSONDecoder().decode(ContextMeta.self, from: data),
                      let name = meta.name,
                      let path = unixPath(from: meta.endpoints?["docker"]?.host) else { return nil }
                return (name, path)
            }
    }

    private nonisolated static func unixPath(from host: String?) -> String? {
        guard let host, host.hasPrefix("unix://") else { return nil }
        let raw = String(host.dropFirst("unix://".count))
        let path = raw.removingPercentEncoding ?? raw
        return path.isEmpty ? nil : path
    }

    private nonisolated static func uniqued(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }
}

struct DockerEngineRuntime: ContainerRuntime {
    let kind: RuntimeKind
    let socketPath: String

    nonisolated init(socketPath: String, kind: RuntimeKind = .docker) {
        self.socketPath = socketPath
        self.kind = kind
    }

    private var http: UnixSocketHTTP { UnixSocketHTTP(path: socketPath) }
    private var decoder: JSONDecoder { JSONDecoder() }
    private static let detectionProbeTimeout: TimeInterval = 0.75
    private nonisolated static let statsProbeTimeout: TimeInterval = 0.75
    nonisolated static let maxConcurrentStatsRequests = 8

    static func detect() async -> DockerEngineRuntime? {
        await detect(candidates: DockerEngineSocketDiscovery.candidates())
    }

    static func detect(candidates: [String], fileManager: FileManager = .default, probeTimeout: TimeInterval = detectionProbeTimeout) async -> DockerEngineRuntime? {
        let existing = candidates.enumerated().filter { fileManager.fileExists(atPath: $0.element) }
        guard !existing.isEmpty else { return nil }

        return await withTaskGroup(of: (Int, DockerEngineRuntime?).self) { group in
            for (index, path) in existing {
                group.addTask {
                    let runtime = DockerEngineRuntime(socketPath: path)
                    let version = try? await runtime.get("/version", as: DockerVersion.self, ioTimeout: probeTimeout)
                    return (index, version == nil ? nil : runtime)
                }
            }

            let orderedIndices = existing.map(\.offset)
            var completed = Set<Int>()
            var successes: [Int: DockerEngineRuntime] = [:]

            while let (index, runtime) = await group.next() {
                completed.insert(index)
                if let runtime { successes[index] = runtime }
                if let winner = Self.highestPriorityReadySuccess(
                    orderedIndices: orderedIndices,
                    completed: completed,
                    successes: successes
                ) {
                    group.cancelAll()
                    return winner
                }
            }
            return nil
        }
    }

    private nonisolated static func highestPriorityReadySuccess(
        orderedIndices: [Int],
        completed: Set<Int>,
        successes: [Int: DockerEngineRuntime]
    ) -> DockerEngineRuntime? {
        for index in orderedIndices {
            if let success = successes[index] { return success }
            if !completed.contains(index) { return nil }
        }
        return nil
    }

    private func get<T: Decodable>(_ path: String, as type: T.Type, ioTimeout: TimeInterval? = nil) async throws -> T {
        let client = UnixSocketHTTP(path: socketPath, ioTimeout: ioTimeout)
        let response = try await client.send(HTTPRequest(method: "GET", path: path, headers: [(name: "Accept", value: "application/json")]))
        guard response.isSuccess else {
            throw HTTPError.status(code: response.statusCode, message: String(data: response.body, encoding: .utf8) ?? "")
        }
        return try decoder.decode(T.self, from: response.body)
    }

    private func post(_ path: String, acceptable: Set<Int> = [200, 201, 204, 304]) async throws {
        let response = try await http.send(HTTPRequest(method: "POST", path: path))
        guard acceptable.contains(response.statusCode) || response.isSuccess else {
            throw HTTPError.status(code: response.statusCode, message: String(data: response.body, encoding: .utf8) ?? "")
        }
    }

    func snapshot() async throws -> RuntimeSnapshot {
        async let containersRaw = get("/containers/json?all=1", as: [DockerContainerSummary].self)
        async let imagesRaw = try? get("/images/json", as: [DockerImageSummary].self)
        async let volumesRaw = try? get("/volumes", as: DockerVolumeList.self)
        async let networksRaw = try? get("/networks", as: [DockerNetwork].self)
        async let versionRaw = try? get("/version", as: DockerVersion.self)

        let summaries = try await containersRaw
        let stats = await statsByID(for: summaries.filter { $0.state == "running" })
        let containers = summaries.map { map($0, stats: stats[$0.id]) }

        let images = (await imagesRaw)?.compactMap(mapImage) ?? []
        let volumes = (await volumesRaw)?.volumes?.map(mapVolume) ?? []
        let networks = (await networksRaw)?.map(mapNetwork) ?? []
        let version = await versionRaw

        return RuntimeSnapshot(
            containers: containers, images: images, volumes: volumes, networks: networks,
            pods: [], machines: [],
            engineRunning: true, engineVersion: version?.version ?? "docker"
        )
    }

    func sampleCPU(containerID: String) async -> Double? {
        let path = "/containers/\(DockerImageOps.pathComponent(containerID))/stats?stream=false"
        guard let first = try? await get(path, as: DockerStats.self) else { return nil }
        try? await Task.sleep(for: .milliseconds(800))
        guard let second = try? await get(path, as: DockerStats.self) else { return first.cpuPercent }
        let cpuDelta = Double((second.cpuStats?.cpuUsage?.totalUsage ?? 0) - (first.cpuStats?.cpuUsage?.totalUsage ?? 0))
        let systemDelta = Double((second.cpuStats?.systemCPUUsage ?? 0) - (first.cpuStats?.systemCPUUsage ?? 0))
        let cpus = Double(second.cpuStats?.onlineCPUs ?? 1)
        guard systemDelta > 0, cpuDelta > 0 else { return 0 }
        return (cpuDelta / systemDelta) * cpus * 100
    }

    private func statsByID(for running: [DockerContainerSummary]) async -> [String: DockerStats] {
        await Self.boundedStatsByID(for: running) { container in
            let encoded = DockerImageOps.pathComponent(container.id)
            return try? await self.get(
                "/containers/\(encoded)/stats?stream=false&one-shot=false",
                as: DockerStats.self,
                ioTimeout: Self.statsProbeTimeout
            )
        }
    }

    static func boundedStatsByID(
        for running: [DockerContainerSummary],
        limit: Int = maxConcurrentStatsRequests,
        fetch: @escaping @Sendable (DockerContainerSummary) async -> DockerStats?
    ) async -> [String: DockerStats] {
        guard !running.isEmpty else { return [:] }
        let limit = max(1, limit)
        return await withTaskGroup(of: (String, DockerStats?).self) { group in
            let initialCount = min(limit, running.count)
            for index in 0..<initialCount {
                let container = running[index]
                group.addTask { (container.id, await fetch(container)) }
            }

            var nextIndex = initialCount
            var inFlight = initialCount
            var result: [String: DockerStats] = [:]

            while inFlight > 0 {
                guard let (id, stats) = await group.next() else { break }
                inFlight -= 1
                if let stats { result[id] = stats }

                if nextIndex < running.count {
                    let container = running[nextIndex]
                    nextIndex += 1
                    inFlight += 1
                    group.addTask { (container.id, await fetch(container)) }
                }
            }

            return result
        }
    }

    private func map(_ summary: DockerContainerSummary, stats: DockerStats?) -> Container {
        let name = summary.names?.first.map { String($0.drop(while: { $0 == "/" })) } ?? summary.id.prefix(12).description
        let status: RunState = summary.state == "running" ? .running : (summary.state == "paused" ? .paused : .stopped)
        let endpointSettings = summary.networkSettings?.networks ?? [:]
        let ip = endpointSettings.values.compactMap(\.IPAddress).first(where: { !$0.isEmpty }) ?? "—"
        let networks = summary.networkSettings?.networks?.keys.sorted() ?? []
        let mounts = summary.mounts?.compactMap(\.containerMount) ?? []
        let volumeTargets = mounts.map(\.target)
        let memUsage = stats?.memoryStats?.usage
        let memLimit = stats?.memoryStats?.limit
        let fraction = (memUsage.flatMap { u in memLimit.map { l in l > 0 ? Double(u) / Double(l) : 0 } }) ?? 0
        let uptime = status == .running ? (summary.status.map { $0.replacingOccurrences(of: "Up ", with: "") } ?? "—") : "—"
        return Container(
            id: summary.id,
            name: name,
            image: summary.image,
            status: status,
            cpuPercent: stats?.cpuPercent ?? 0,
            memoryDisplay: status == .running ? DockerFormat.bytes(memUsage) : "0 MB",
            memoryLimitDisplay: memLimit.map(DockerFormat.bytes) ?? "—",
            memoryFraction: fraction,
            ports: DockerFormat.ports(summary.ports),
            uptime: uptime,
            created: DockerFormat.relative(unix: summary.created),
            ipAddress: ip,
            domain: "\(name).dory.local",
            command: summary.command ?? "—",
            restartPolicy: "—",
            createdEpoch: summary.created,
            labels: summary.labels ?? [:],
            memoryBytes: status == .running ? (memUsage ?? 0) : 0,
            mounts: mounts,
            volumeTargets: volumeTargets,
            networks: networks,
            networkEndpointSettings: endpointSettings,
            exitCode: DockerFormat.exitCode(from: summary.status)
        )
    }

    private func mapImage(_ summary: DockerImageSummary) -> DockerImage? {
        let tag = summary.repoTags?.first(where: { $0 != "<none>:<none>" })
        let repository: String
        let tagValue: String
        if let tag, let colon = tag.lastIndex(of: ":") {
            repository = String(tag[tag.startIndex..<colon])
            tagValue = String(tag[tag.index(after: colon)...])
        } else {
            repository = tag ?? "<none>"
            tagValue = "<none>"
        }
        let id = summary.id.replacingOccurrences(of: "sha256:", with: "").prefix(12)
        return DockerImage(repository: repository, tag: tagValue, imageID: String(id),
                           size: DockerFormat.bytes(summary.size), created: DockerFormat.relative(unix: summary.created),
                           usedByCount: summary.containers.flatMap { $0 > 0 ? $0 : 0 } ?? 0,
                           sizeBytes: summary.size ?? 0, createdEpoch: summary.created ?? 0,
                           labels: summary.labels ?? [:])
    }

    private func mapVolume(_ volume: DockerVolume) -> Volume {
        Volume(name: volume.name, size: "—", driver: volume.driver ?? "local",
               usedBy: "—", created: DockerFormat.relative(iso: volume.createdAt),
               labels: volume.labels ?? [:],
               options: volume.options ?? [:])
    }

    private func mapNetwork(_ network: DockerNetwork) -> DoryNetwork {
        DoryNetwork(name: network.name, driver: network.driver ?? "—", scope: network.scope ?? "—",
                    subnet: network.ipam?.config?.first?.subnet ?? "—",
                    containerCount: network.containers?.count ?? 0,
                    labels: network.labels ?? [:])
    }

    private func postJSON<Body: Encodable, Out: Decodable>(_ path: String, body: Body, as type: Out.Type, acceptable: Set<Int> = [200, 201]) async throws -> Out {
        let data = try JSONEncoder().encode(body)
        let response = try await http.send(HTTPRequest(method: "POST", path: path,
            headers: [(name: "Content-Type", value: "application/json")], body: data))
        guard acceptable.contains(response.statusCode) || response.isSuccess else {
            throw HTTPError.status(code: response.statusCode, message: String(data: response.body, encoding: .utf8) ?? "")
        }
        return try decoder.decode(Out.self, from: response.body)
    }

    func pull(image: String) async throws {
        let (repo, tag) = DockerRegistry.splitImageRef(image)
        let encoded = DockerImageOps.queryValue(repo)
        let encodedTag = DockerImageOps.queryValue(tag)
        var headers: [(name: String, value: String)] = []
        if let auth = DockerRegistry.registryAuthHeader(for: repo) { headers.append((name: "X-Registry-Auth", value: auth)) }
        let response = try await http.send(HTTPRequest(method: "POST", path: "/images/create?fromImage=\(encoded)&tag=\(encodedTag)", headers: headers))
        guard response.isSuccess else {
            throw HTTPError.status(code: response.statusCode, message: String(data: response.body, encoding: .utf8) ?? "")
        }
    }

    func login(registry: String, username: String, password: String) async throws {
        let server = DockerRegistry.normalizeRegistry(registry)
        let body = try JSONSerialization.data(withJSONObject: ["username": username, "password": password, "serveraddress": server])
        let response = try await http.send(HTTPRequest(method: "POST", path: "/auth",
            headers: [(name: "Content-Type", value: "application/json")], body: body))
        guard response.isSuccess else {
            throw HTTPError.status(code: response.statusCode, message: "Login failed — check the registry, username and password")
        }
        DockerRegistry.persistDockerAuth(server: server, username: username, password: password)
    }

    func create(_ spec: ContainerSpec) async throws -> String {
        let body = DockerCreateBody(spec: spec)
        let name = DockerImageOps.queryValue(spec.name)
        var path = "/containers/create?name=\(name)"
        if let platform = spec.platform?.trimmingCharacters(in: .whitespacesAndNewlines), !platform.isEmpty {
            path += "&platform=\(DockerImageOps.queryValue(platform))"
        }
        let result = try await postJSON(path, body: body, as: DockerCreateResult.self)
        return result.id
    }

    func exec(containerID: String, command: [String]) async throws -> ExecResult {
        let create = try await postJSON("/containers/\(DockerImageOps.pathComponent(containerID))/exec",
            body: DockerExecCreate(Cmd: command), as: DockerExecResult.self)
        let startBody = try JSONEncoder().encode(DockerExecStart())
        let startResponse = try await http.send(HTTPRequest(method: "POST", path: "/exec/\(DockerImageOps.pathComponent(create.id))/start",
            headers: [(name: "Content-Type", value: "application/json")], body: startBody))
        let output = DockerLogFrames.plainText(startResponse.body)
        let inspect = try await get("/exec/\(DockerImageOps.pathComponent(create.id))/json", as: DockerExecInspect.self)
        return ExecResult(exitCode: inspect.exitCode ?? 0, output: output)
    }

    func createNetwork(name: String, labels: [String: String]) async throws {
        _ = try await postJSON("/networks/create", body: DockerNetworkCreate(Name: name, Labels: labels),
                               as: DockerNetworkCreateResult.self, acceptable: [200, 201])
    }

    func connectNetwork(name: String, containerID: String) async throws {
        let body = try JSONEncoder().encode(DockerNetworkConnectRequest(Container: containerID))
        let response = try await http.send(HTTPRequest(
            method: "POST",
            path: "/networks/\(DockerImageOps.pathComponent(name))/connect",
            headers: [(name: "Content-Type", value: "application/json")],
            body: body
        ))
        guard response.isSuccess else {
            throw HTTPError.status(code: response.statusCode, message: String(data: response.body, encoding: .utf8) ?? "")
        }
    }

    func disconnectNetwork(name: String, containerID: String, force: Bool) async throws {
        let body = try JSONEncoder().encode(DockerNetworkDisconnectRequest(Container: containerID, Force: force))
        let response = try await http.send(HTTPRequest(
            method: "POST",
            path: "/networks/\(DockerImageOps.pathComponent(name))/disconnect",
            headers: [(name: "Content-Type", value: "application/json")],
            body: body
        ))
        guard response.isSuccess else {
            throw HTTPError.status(code: response.statusCode, message: String(data: response.body, encoding: .utf8) ?? "")
        }
    }

    func removeNetwork(name: String) async throws {
        let response = try await http.send(HTTPRequest(method: "DELETE", path: "/networks/\(DockerImageOps.pathComponent(name))"))
        guard response.isSuccess || response.statusCode == 404 else {
            throw HTTPError.status(code: response.statusCode, message: String(data: response.body, encoding: .utf8) ?? "")
        }
    }

    func removeVolume(name: String) async throws {
        let response = try await http.send(HTTPRequest(method: "DELETE", path: "/volumes/\(DockerImageOps.pathComponent(name))?force=true"))
        guard response.isSuccess || response.statusCode == 404 else {
            throw HTTPError.status(code: response.statusCode, message: String(data: response.body, encoding: .utf8) ?? "")
        }
    }

    func createVolume(
        name: String,
        driver: String?,
        labels: [String: String],
        driverOptions: [String: String]
    ) async throws {
        let body = try JSONEncoder().encode(DockerVolumeCreate(
            name: name,
            driver: driver,
            labels: labels,
            driverOptions: driverOptions
        ))
        let response = try await http.send(HTTPRequest(method: "POST", path: "/volumes/create",
            headers: [(name: "Content-Type", value: "application/json")], body: body))
        guard response.isSuccess else {
            throw HTTPError.status(code: response.statusCode, message: String(data: response.body, encoding: .utf8) ?? "")
        }
    }

    func pruneVolumes() async throws { try await prune("/volumes/prune") }
    func pruneNetworks() async throws { try await prune("/networks/prune") }
    func pruneImages() async throws { try await prune("/images/prune?filters=%7B%22dangling%22%3A%5B%22false%22%5D%7D") }
    func pruneContainers() async throws { try await prune("/containers/prune") }

    func removeImage(id: String) async throws {
        let response = try await http.send(HTTPRequest(method: "DELETE", path: "/images/\(DockerImageOps.pathComponent(id))?force=true"))
        guard response.isSuccess || response.statusCode == 404 else {
            throw HTTPError.status(code: response.statusCode, message: String(data: response.body, encoding: .utf8) ?? "")
        }
    }

    func tagImage(source: String, repo: String, tag: String) async throws {
        let response = try await http.send(HTTPRequest(method: "POST", path: DockerImageOps.tagPath(source: source, repo: repo, tag: tag)))
        guard response.isSuccess else {
            throw HTTPError.status(code: response.statusCode, message: String(data: response.body, encoding: .utf8) ?? "")
        }
    }

    func pushImage(reference: String) async throws -> AsyncStream<Data> {
        let split = DockerRegistry.splitImageRef(reference)
        let auth = DockerRegistry.registryAuthHeader(for: split.repo) ?? Data("{}".utf8).base64EncodedString()
        let request = HTTPRequest(
            method: "POST",
            path: DockerImageOps.pushPath(name: split.repo, tag: split.tag),
            headers: [(name: "X-Registry-Auth", value: auth)]
        )
        let client = http
        return AsyncStream { continuation in
            let handle = client.stream(request, onChunk: { continuation.yield($0) }, onComplete: { continuation.finish() })
            continuation.onTermination = { _ in handle.close() }
        }
    }

    private func prune(_ path: String) async throws {
        let response = try await http.send(HTTPRequest(method: "POST", path: path))
        guard response.isSuccess else {
            throw HTTPError.status(code: response.statusCode, message: String(data: response.body, encoding: .utf8) ?? "")
        }
    }

    func commit(containerID: String, repo: String, tag: String, labels: [String: String]) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["Labels": labels])
        let path = DockerImageOps.commitPath(container: containerID, repo: repo, tag: tag)
        let response = try await http.send(HTTPRequest(method: "POST", path: path,
            headers: [(name: "Content-Type", value: "application/json")], body: body))
        guard response.isSuccess else {
            throw HTTPError.status(code: response.statusCode, message: String(decoding: response.body, as: UTF8.self))
        }
        struct Out: Decodable { let Id: String }
        return (try? JSONDecoder().decode(Out.self, from: response.body))?.Id ?? "\(repo):\(tag)"
    }

    var supportsImageArchiveTransfer: Bool { true }

    func saveImage(reference: String) -> AsyncStream<Data> {
        let encoded = DockerImageOps.pathComponent(reference)
        let request = HTTPRequest(method: "GET", path: "/images/\(encoded)/get")
        let client = http
        return AsyncStream { continuation in
            let handle = client.stream(request, onChunk: { continuation.yield($0) }, onComplete: { continuation.finish() })
            continuation.onTermination = { _ in handle.close() }
        }
    }

    func saveImages(references: [String]) async throws -> AsyncStream<Data> {
        guard !references.isEmpty else {
            throw RuntimeFeatureError.unsupported("at least one image name is required")
        }
        let query = references
            .map { "names=\(DockerImageOps.queryValue($0))" }
            .joined(separator: "&")
        let request = HTTPRequest(method: "GET", path: "/images/get?\(query)")
        let client = http
        return AsyncStream { continuation in
            let handle = client.stream(request, onChunk: { continuation.yield($0) }, onComplete: { continuation.finish() })
            continuation.onTermination = { _ in handle.close() }
        }
    }

    func loadImage(tar: Data) async throws {
        let response = try await http.send(HTTPRequest(method: "POST", path: "/images/load",
            headers: [(name: "Content-Type", value: "application/x-tar")], body: tar))
        guard response.isSuccess else {
            throw HTTPError.status(code: response.statusCode, message: String(decoding: response.body, as: UTF8.self))
        }
    }

    func loadImage(stream: AsyncStream<Data>) async throws {
        let response = try await http.sendChunked(HTTPRequest(method: "POST", path: "/images/load",
            headers: [(name: "Content-Type", value: "application/x-tar")]), body: stream)
        guard response.isSuccess else {
            throw HTTPError.status(code: response.statusCode, message: String(decoding: response.body, as: UTF8.self))
        }
    }

    func start(containerID: String) async throws { try await post("/containers/\(DockerImageOps.pathComponent(containerID))/start") }
    func stop(containerID: String) async throws { try await post("/containers/\(DockerImageOps.pathComponent(containerID))/stop") }
    func restart(containerID: String) async throws { try await post("/containers/\(DockerImageOps.pathComponent(containerID))/restart") }
    func kill(containerID: String, signal: String?) async throws {
        let query = signal
            .map(DockerImageOps.queryValue)
            .map { "?signal=\($0)" } ?? ""
        try await post("/containers/\(DockerImageOps.pathComponent(containerID))/kill\(query)")
    }
    func pause(containerID: String) async throws { try await post("/containers/\(DockerImageOps.pathComponent(containerID))/pause") }
    func unpause(containerID: String) async throws { try await post("/containers/\(DockerImageOps.pathComponent(containerID))/unpause") }
    func rename(containerID: String, name: String) async throws {
        let encoded = DockerImageOps.queryValue(name)
        try await post("/containers/\(DockerImageOps.pathComponent(containerID))/rename?name=\(encoded)")
    }
    func update(containerID: String, resources: ContainerResourceUpdate) async throws {
        let body = try JSONEncoder().encode(DockerContainerUpdateBody(resources: resources))
        let response = try await http.send(HTTPRequest(
            method: "POST",
            path: "/containers/\(DockerImageOps.pathComponent(containerID))/update",
            headers: [(name: "Content-Type", value: "application/json")],
            body: body
        ))
        guard response.isSuccess else {
            throw HTTPError.status(code: response.statusCode, message: String(data: response.body, encoding: .utf8) ?? "")
        }
    }
    func resize(containerID: String, height: Int?, width: Int?) async throws {
        var items: [String] = []
        if let height { items.append("h=\(height)") }
        if let width { items.append("w=\(width)") }
        let query = items.isEmpty ? "" : "?\(items.joined(separator: "&"))"
        try await post("/containers/\(DockerImageOps.pathComponent(containerID))/resize\(query)")
    }
    func remove(containerID: String) async throws {
        let response = try await http.send(HTTPRequest(method: "DELETE", path: "/containers/\(DockerImageOps.pathComponent(containerID))?force=true"))
        guard response.isSuccess || response.statusCode == 404 else {
            throw HTTPError.status(code: response.statusCode, message: String(data: response.body, encoding: .utf8) ?? "")
        }
    }

    var supportsRawProxy: Bool { true }

    func proxyRequest(method: String, path: String, headers: [(name: String, value: String)], body: Data) async -> HTTPResponse? {
        try? await http.send(HTTPRequest(method: method, path: path, headers: headers, body: body.isEmpty ? nil : body))
    }

    nonisolated func proxyHijack(requestData: Data, clientFD: Int32) {
        let badGateway = Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        guard let dockerFD = try? UnixSocketHTTP.connectSocket(socketPath) else {
            try? UnixSocketHTTP.writeAll(clientFD, badGateway)
            shutdown(clientFD, SHUT_RDWR); Darwin.close(clientFD)
            return
        }
        guard (try? UnixSocketHTTP.writeAll(dockerFD, requestData)) != nil else {
            shutdown(dockerFD, SHUT_RDWR); Darwin.close(dockerFD)
            try? UnixSocketHTTP.writeAll(clientFD, badGateway)
            shutdown(clientFD, SHUT_RDWR); Darwin.close(clientFD)
            return
        }
        UnixSocketHTTP.bidirectionalCopy(client: clientFD, upstream: dockerFD)
    }

    func build(contextTar: Data, query: String) -> AsyncStream<Data> {
        let request = HTTPRequest(method: "POST", path: query.isEmpty ? "/build" : "/build?\(query)",
            headers: [(name: "Content-Type", value: "application/x-tar")], body: contextTar)
        let client = http
        return AsyncStream { continuation in
            let handle = client.stream(request, onChunk: { continuation.yield($0) }, onComplete: { continuation.finish() })
            continuation.onTermination = { _ in handle.close() }
        }
    }

    func copyOut(containerID: String, path: String) async -> Data? {
        let encoded = DockerImageOps.queryValue(path)
        let response = try? await http.send(HTTPRequest(method: "GET", path: "/containers/\(DockerImageOps.pathComponent(containerID))/archive?path=\(encoded)"))
        guard let response, response.isSuccess else { return nil }
        return response.body
    }

    func copyIn(containerID: String, path: String, archive: Data) async -> Bool {
        let encoded = DockerImageOps.queryValue(path)
        let response = try? await http.send(HTTPRequest(method: "PUT", path: "/containers/\(DockerImageOps.pathComponent(containerID))/archive?path=\(encoded)",
            headers: [(name: "Content-Type", value: "application/x-tar")], body: archive))
        return response?.isSuccess ?? false
    }

    func containerExitCode(_ id: String) async -> Int? {
        let inspect = try? await get("/containers/\(DockerImageOps.pathComponent(id))/json", as: DockerInspect.self)
        return inspect?.state?.exitCode
    }

    func inspectImage(id: String) async -> ImageDetail? {
        guard let raw = try? await get("/images/\(DockerImageOps.pathComponent(id))/json", as: DockerImageInspect.self) else { return nil }
        let config = raw.config
        let env = (config?.env ?? []).map { entry -> EnvVar in
            if let eq = entry.firstIndex(of: "=") {
                return EnvVar(key: String(entry[entry.startIndex..<eq]), value: String(entry[entry.index(after: eq)...]))
            }
            return EnvVar(key: entry, value: "")
        }
        let labels = (config?.labels ?? [:]).sorted { $0.key < $1.key }.map { LabelPair(key: $0.key, value: $0.value) }
        let ports = (config?.exposedPorts?.keys).map { Array($0).sorted() } ?? []
        let shortID = (raw.id ?? id).replacingOccurrences(of: "sha256:", with: "")
        let workingDir = (config?.workingDir).flatMap { $0.isEmpty ? nil : $0 } ?? "/"
        return ImageDetail(
            reference: raw.repoTags?.first(where: { $0 != "<none>:<none>" }) ?? "<none>",
            id: String(shortID.prefix(12)),
            tags: raw.repoTags ?? [],
            digest: raw.repoDigests?.first,
            created: DockerFormat.relative(iso: raw.created),
            architecture: raw.architecture ?? "—",
            os: raw.os ?? "—",
            size: DockerFormat.bytes(raw.size),
            entrypoint: (config?.entrypoint ?? []).joined(separator: " "),
            command: (config?.cmd ?? []).joined(separator: " "),
            workingDir: workingDir,
            exposedPorts: ports,
            env: env,
            labels: labels
        )
    }

    func inspectNetwork(name: String) async -> NetworkDetail? {
        guard let raw = try? await get("/networks/\(DockerImageOps.pathComponent(name))", as: DockerNetwork.self) else { return nil }
        let options = (raw.options ?? [:]).sorted { $0.key < $1.key }.map { LabelPair(key: $0.key, value: $0.value) }
        let members = (raw.containers ?? [:]).values.map { container in
            NetworkMember(name: container.name ?? "—",
                          ipv4: (container.ipv4Address).flatMap { $0.isEmpty ? nil : $0 } ?? "—")
        }.sorted { $0.name < $1.name }
        let config = raw.ipam?.config?.first
        return NetworkDetail(
            name: raw.name,
            id: String((raw.id ?? "").prefix(12)),
            driver: raw.driver ?? "—",
            scope: raw.scope ?? "—",
            subnet: config?.subnet ?? "—",
            gateway: config?.gateway ?? "—",
            isInternal: raw.isInternal ?? false,
            attachable: raw.attachable ?? false,
            options: options,
            containers: members
        )
    }

    func env(containerID: String) async throws -> [EnvVar] {
        let inspect = try await get("/containers/\(DockerImageOps.pathComponent(containerID))/json", as: DockerInspect.self)
        return (inspect.config?.env ?? []).map { entry in
            if let eq = entry.firstIndex(of: "=") {
                return EnvVar(key: String(entry[entry.startIndex..<eq]), value: String(entry[entry.index(after: eq)...]))
            }
            return EnvVar(key: entry, value: "")
        }
    }

    func streamLogs(containerID: String) -> AsyncStream<LogLine> {
        let request = HTTPRequest(
            method: "GET",
            path: "/containers/\(DockerImageOps.pathComponent(containerID))/logs?follow=1&stdout=1&stderr=1&tail=80&timestamps=1",
            headers: [(name: "Accept", value: "application/vnd.docker.raw-stream")]
        )
        let client = http
        return AsyncStream { continuation in
            let decoder = LogStreamDecoder()
            let handle = client.stream(request, onChunk: { data in
                for line in decoder.feed(data) { continuation.yield(line) }
            }, onComplete: {
                continuation.finish()
            })
            continuation.onTermination = { _ in handle.close() }
        }
    }

    func logs(containerID: String) async throws -> [LogLine] {
        let response = try await http.send(HTTPRequest(
            method: "GET",
            path: "/containers/\(DockerImageOps.pathComponent(containerID))/logs?stdout=1&stderr=1&tail=100&timestamps=1",
            headers: [(name: "Accept", value: "application/vnd.docker.raw-stream")]
        ))
        guard response.isSuccess else { return [] }
        return DockerLogFrames.parse(response.body)
    }
}

final class LogStreamDecoder: @unchecked Sendable {
    private var buffer = [UInt8]()

    func feed(_ data: Data) -> [LogLine] {
        buffer.append(contentsOf: data)
        var lines: [LogLine] = []
        while true {
            if buffer.count >= 8, buffer[0] <= 2, buffer[1] == 0, buffer[2] == 0, buffer[3] == 0 {
                let size = Int(buffer[4]) << 24 | Int(buffer[5]) << 16 | Int(buffer[6]) << 8 | Int(buffer[7])
                if size < 0 || buffer.count < 8 + size { break }
                let payload = Array(buffer[8..<8 + size])
                buffer.removeFirst(8 + size)
                if let text = String(bytes: payload, encoding: .utf8) {
                    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                        lines.append(DockerLogFrames.makeLine(String(line)))
                    }
                }
            } else if let newline = buffer.firstIndex(of: 0x0A) {
                let lineBytes = Array(buffer[0..<newline])
                buffer.removeFirst(newline + 1)
                if let text = String(bytes: lineBytes, encoding: .utf8), !text.isEmpty {
                    lines.append(DockerLogFrames.makeLine(text))
                }
            } else {
                break
            }
        }
        // Guard against unbounded growth on non-framed input with no newline (flush as one line).
        if buffer.count > 1_048_576 {
            if let text = String(bytes: buffer, encoding: .utf8), !text.isEmpty {
                lines.append(DockerLogFrames.makeLine(text))
            }
            buffer.removeAll(keepingCapacity: false)
        }
        return lines
    }
}

enum DockerLogFrames {
    static func plainText(_ data: Data) -> String {
        let framed = deframe(data)
        if !framed.isEmpty { return framed }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func parse(_ data: Data) -> [LogLine] {
        var text = deframe(data)
        if text.isEmpty, let raw = String(data: data, encoding: .utf8) { text = raw }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map { makeLine(String($0)) }
    }

    static func makeLine(_ line: String) -> LogLine {
        let parts = line.split(separator: " ", maxSplits: 1)
        var timestamp = ""
        var message = line
        if parts.count == 2, parts[0].contains("T"), parts[0].contains(":") {
            timestamp = shortTime(String(parts[0]))
            message = String(parts[1])
        }
        return LogLine(timestamp: timestamp, level: level(for: message), message: message)
    }

    private static func deframe(_ data: Data) -> String {
        var output = Data()
        let bytes = [UInt8](data)
        var i = 0
        var framed = false
        while i + 8 <= bytes.count {
            let streamType = bytes[i]
            guard streamType <= 2, bytes[i + 1] == 0, bytes[i + 2] == 0, bytes[i + 3] == 0 else { break }
            let size = (Int(bytes[i + 4]) << 24) | (Int(bytes[i + 5]) << 16) | (Int(bytes[i + 6]) << 8) | Int(bytes[i + 7])
            guard size >= 0, i + 8 + size <= bytes.count else { break }
            output.append(contentsOf: bytes[(i + 8)..<(i + 8 + size)])
            i += 8 + size
            framed = true
        }
        return framed ? (String(data: output, encoding: .utf8) ?? "") : ""
    }

    private static func shortTime(_ iso: String) -> String {
        guard let tIndex = iso.firstIndex(of: "T") else { return iso }
        let after = iso[iso.index(after: tIndex)...]
        return String(after.prefix(12))
    }

    private static func level(for message: String) -> LogLevel {
        let upper = message.uppercased()
        if upper.contains("ERROR") || upper.contains("FATAL") { return .error }
        if upper.contains("WARN") { return .warn }
        if upper.contains("DEBUG") { return .debug }
        return .info
    }
}
