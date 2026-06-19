import Foundation

final class ExecStore: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [String: (container: String, cmd: [String])] = [:]
    private var results: [String: Int] = [:]
    func register(container: String, cmd: [String]) -> String {
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        lock.lock(); commands[id] = (container, cmd); lock.unlock()
        return id
    }
    func command(for id: String) -> (container: String, cmd: [String])? {
        lock.lock(); defer { lock.unlock() }; return commands[id]
    }
    func setResult(_ id: String, exitCode: Int) { lock.lock(); results[id] = exitCode; lock.unlock() }
    func result(for id: String) -> Int? { lock.lock(); defer { lock.unlock() }; return results[id] }
    func finish(_ id: String) { lock.lock(); commands.removeValue(forKey: id); results.removeValue(forKey: id); lock.unlock() }
}

struct DockerShim: Sendable {
    let runtime: any ContainerRuntime
    var apiVersion: String = "1.47"
    let execStore = ExecStore()

    static var defaultSocketPath: String { "\(NSHomeDirectory())/.dory/dory.sock" }

    func handle(_ request: ParsedRequest) async -> ShimResponse {
        // Backends fronting a real Docker socket are a full transparent proxy: every request is
        // forwarded verbatim and the response streamed back unchanged. This is uniformly correct
        // for normal, streaming (stats/logs --follow/events), and hijacked (exec/attach/BuildKit)
        // endpoints, and preserves all request headers (registry auth, etc.). The per-endpoint
        // translation below serves only the non-proxy backends (Apple `container`, mock).
        if runtime.supportsRawProxy {
            let runtime = self.runtime
            return ShimResponse.hijacked { fd, initial in runtime.proxyHijack(requestData: initial, clientFD: fd) }
        }

        let path = Self.normalize(request.path)
        let method = request.method.uppercased()

        switch (method, path) {
        case ("GET", "/_ping"), ("HEAD", "/_ping"):
            return ShimResponse(status: 200, headers: [
                (name: "Api-Version", value: apiVersion),
                (name: "Builder-Version", value: runtime.supportsRawProxy ? "2" : "1"),
                (name: "Docker-Experimental", value: "false"),
                (name: "Cache-Control", value: "no-cache"),
            ], body: Data("OK".utf8))
        case ("GET", "/version"):
            return await versionResponse()
        case ("GET", "/info"):
            return await infoResponse()
        case ("GET", "/containers/json"):
            return await containersResponse(all: request.query["all"] == "1" || request.query["all"] == "true")
        case ("GET", "/images/json"):
            return await imagesResponse()
        case ("GET", "/networks"):
            return await networksResponse()
        case ("GET", "/volumes"):
            return await volumesResponse()
        case ("GET", "/events"):
            return eventsResponse()
        case ("POST", "/build"):
            return buildResponse(request)
        case ("POST", "/session"):
            guard runtime.supportsRawProxy else { return errorResponse(501, "session not supported") }
            let runtime = self.runtime
            return ShimResponse.hijacked { fd, initial in runtime.proxyHijack(requestData: initial, clientFD: fd) }
        case ("POST", "/grpc"):
            guard runtime.supportsRawProxy else { return errorResponse(501, "grpc not supported") }
            let runtime = self.runtime
            return ShimResponse.hijacked { fd, initial in runtime.proxyHijack(requestData: initial, clientFD: fd) }
        default:
            return await routeParameterized(request, method: method, path: path)
        }
    }

    private func routeParameterized(_ request: ParsedRequest, method: String, path: String) async -> ShimResponse {
        if method == "POST", path == "/containers/create" { return await createContainer(request) }
        if method == "POST", path == "/images/create" { return await pullImage(request) }
        if method == "POST", path == "/networks/create" { return await createNetwork(request) }

        let parts = path.split(separator: "/").map(String.init)
        if parts.count == 3, parts[0] == "containers", method == "POST", parts[2] == "exec" {
            return await execCreate(containerID: parts[1], request: request)
        }
        if parts.count == 3, parts[0] == "containers", method == "POST", parts[2] == "attach" {
            guard runtime.supportsRawProxy else { return errorResponse(501, "attach not supported on this backend") }
            let runtime = self.runtime
            return ShimResponse.hijacked { fd, initial in runtime.proxyHijack(requestData: initial, clientFD: fd) }
        }
        if parts.count == 3, parts[0] == "exec", method == "POST", parts[2] == "start" {
            return execStart(execID: parts[1])
        }
        if parts.count == 3, parts[0] == "exec", method == "GET", parts[2] == "json" {
            return await execInspect(execID: parts[1], request: request)
        }
        if parts.count == 3, parts[0] == "containers", method == "GET", parts[2] == "json" {
            return await inspectResponse(id: parts[1])
        }
        if parts.count == 3, parts[0] == "containers", method == "GET", parts[2] == "logs" {
            return await logsResponse(id: parts[1])
        }
        if parts.count == 3, parts[0] == "containers", parts[2] == "archive" {
            return await archive(id: parts[1], method: method, request: request)
        }
        if parts.count == 3, parts[0] == "containers", method == "POST", parts[2] == "wait" {
            return ShimResponse.json(Data("{\"StatusCode\":0}".utf8))
        }
        if parts.count == 3, parts[0] == "containers", method == "POST" {
            return await lifecycle(id: parts[1], action: parts[2])
        }
        if parts.count == 2, parts[0] == "containers", method == "DELETE" {
            return await remove(id: parts[1])
        }
        // Transparent fallback for Docker-backed engines: anything not explicitly translated is
        // proxied to the real engine, so the full Docker API (BuildKit sessions, distribution,
        // swarm, plugins, …) works. Hijack endpoints are detected by the Upgrade header.
        if runtime.supportsRawProxy {
            if request.headers["upgrade"] != nil || request.headers["connection"]?.lowercased().contains("upgrade") == true {
                let runtime = self.runtime
                return ShimResponse.hijacked { fd, initial in runtime.proxyHijack(requestData: initial, clientFD: fd) }
            }
            let headers = request.headers["content-type"].map { [(name: "Content-Type", value: $0)] } ?? []
            if let response = await runtime.proxyRequest(method: method, path: request.target, headers: headers, body: request.body) {
                return ShimResponse(status: response.statusCode, headers: Self.proxyHeaders(response), body: response.body)
            }
        }
        return errorResponse(404, "page not found")
    }

    private func createContainer(_ request: ParsedRequest) async -> ShimResponse {
        guard let body = try? JSONDecoder().decode(DockerCreateRequest.self, from: request.body) else {
            return errorResponse(400, "invalid create request body")
        }
        let spec = body.spec(name: request.query["name"])
        guard !spec.image.isEmpty else { return errorResponse(400, "image is required") }
        guard !spec.image.hasPrefix("-") else { return errorResponse(400, "invalid image reference") }
        do {
            let id = try await runtime.create(spec)
            let payload = try JSONEncoder().encode(DockerCreateContainerOut(Id: id, Warnings: []))
            return ShimResponse.json(payload, status: 201)
        } catch { return errorResponse(500, "\(error)") }
    }

    private func pullImage(_ request: ParsedRequest) async -> ShimResponse {
        let from = request.query["fromImage"] ?? ""
        guard !from.isEmpty else { return errorResponse(400, "fromImage is required") }
        let tag = request.query["tag"].flatMap { $0.isEmpty ? nil : $0 } ?? "latest"
        do { try await runtime.pull(image: "\(from):\(tag)"); return ShimResponse.json(Data("{\"status\":\"Pulled \(from):\(tag)\"}\n".utf8)) }
        catch { return errorResponse(500, "\(error)") }
    }

    private func createNetwork(_ request: ParsedRequest) async -> ShimResponse {
        guard let body = try? JSONDecoder().decode(DockerNetworkCreateRequest.self, from: request.body), !body.Name.isEmpty else {
            return errorResponse(400, "network name is required")
        }
        do {
            try await runtime.createNetwork(name: body.Name, labels: body.Labels ?? [:])
            return ShimResponse.json(try JSONEncoder().encode(DockerNetworkCreatedOut(Id: body.Name, Warning: "")), status: 201)
        } catch { return errorResponse(500, "\(error)") }
    }

    private func networksResponse() async -> ShimResponse {
        let snapshot = (try? await runtime.snapshot()) ?? RuntimeSnapshot()
        let networks = snapshot.networks.map {
            DockerNetworkOut(Id: $0.name, Name: $0.name, Driver: $0.driver, Scope: $0.scope)
        }
        return encode(networks)
    }

    private func volumesResponse() async -> ShimResponse {
        let snapshot = (try? await runtime.snapshot()) ?? RuntimeSnapshot()
        let volumes = snapshot.volumes.map { DockerVolumeOut(Name: $0.name, Driver: $0.driver, Mountpoint: "/var/lib/dory/volumes/\($0.name)") }
        return encode(DockerVolumeListOut(Volumes: volumes))
    }

    private func inspectResponse(id: String) async -> ShimResponse {
        let snapshot = (try? await runtime.snapshot()) ?? RuntimeSnapshot()
        guard let container = snapshot.containers.first(where: { $0.id == id || $0.name == id || $0.id.hasPrefix(id) }) else {
            return errorResponse(404, "no such container: \(id)")
        }
        var portMap: [String: [DockerHostBindingOut]] = [:]
        for port in parsePorts(container.ports) {
            let key = "\(port.PrivatePort)/\(port.portType)"
            portMap[key] = port.PublicPort.map { [DockerHostBindingOut(HostIp: "0.0.0.0", HostPort: String($0))] } ?? []
        }
        let created = container.createdEpoch.map { Self.iso8601(epoch: $0) } ?? Self.iso8601(epoch: 0)
        let out = DockerInspectOut(
            Id: container.id, Name: "/\(container.name)", Image: container.image, Created: created,
            State: DockerInspectStateOut(Running: container.isRunning, Status: container.isRunning ? "running" : "exited"),
            Config: DockerInspectConfigOut(Image: container.image, Cmd: container.command.isEmpty ? nil : [container.command]),
            NetworkSettings: DockerInspectNetOut(IPAddress: container.ipAddress == "—" ? "" : container.ipAddress, Ports: portMap),
            HostConfig: DockerHostConfigOut(NetworkMode: "default")
        )
        return encode(out)
    }

    private func logsResponse(id: String) async -> ShimResponse {
        let lines = (try? await runtime.logs(containerID: id)) ?? []
        var body = Data()
        for line in lines {
            let prefix = line.timestamp.isEmpty ? "" : "\(line.timestamp) "
            let payload = Data("\(prefix)\(line.message)\n".utf8)
            var header = Data([1, 0, 0, 0])
            let length = UInt32(payload.count)
            header.append(contentsOf: [UInt8(length >> 24 & 0xff), UInt8(length >> 16 & 0xff), UInt8(length >> 8 & 0xff), UInt8(length & 0xff)])
            body.append(header)
            body.append(payload)
        }
        return ShimResponse(status: 200, headers: [(name: "Content-Type", value: "application/vnd.docker.raw-stream")], body: body)
    }

    private func lifecycle(id: String, action: String) async -> ShimResponse {
        do {
            switch action {
            case "start": try await runtime.start(containerID: id)
            case "stop", "kill": try await runtime.stop(containerID: id)
            case "restart": try await runtime.restart(containerID: id)
            default: return errorResponse(404, "unknown action: \(action)")
            }
            return ShimResponse.empty(status: 204)
        } catch { return errorResponse(409, "\(error)") }
    }

    private func remove(id: String) async -> ShimResponse {
        do { try await runtime.remove(containerID: id); return ShimResponse.empty(status: 204) }
        catch { return errorResponse(409, "\(error)") }
    }

    private func execCreate(containerID: String, request: ParsedRequest) async -> ShimResponse {
        // Backends fronting a Docker socket proxy exec to the real engine so interactive (`-i`/`-t`)
        // sessions work; others fall back to a one-shot exec via the in-process registry.
        if runtime.supportsRawProxy {
            let headers = request.headers.contains(where: { $0.key == "content-type" })
                ? [(name: "Content-Type", value: request.headers["content-type"] ?? "application/json")]
                : [(name: "Content-Type", value: "application/json")]
            if let response = await runtime.proxyRequest(method: request.method, path: request.target, headers: headers, body: request.body) {
                return ShimResponse(status: response.statusCode, headers: Self.proxyHeaders(response), body: response.body)
            }
            return errorResponse(500, "exec create proxy failed")
        }
        guard let body = try? JSONDecoder().decode(DockerExecCreateRequest.self, from: request.body) else {
            return errorResponse(400, "invalid exec body")
        }
        let id = execStore.register(container: containerID, cmd: body.Cmd ?? [])
        let payload = (try? JSONEncoder().encode(DockerExecCreatedOut(Id: id))) ?? Data()
        return ShimResponse.json(payload, status: 201)
    }

    /// Headers for a proxied response: the body has already been de-chunked and will get a fresh
    /// Content-Length, so the upstream's transfer-encoding/content-length must not be forwarded.
    static func proxyHeaders(_ response: HTTPResponse) -> [(name: String, value: String)] {
        response.headers
            .filter { $0.key != "transfer-encoding" && $0.key != "content-length" }
            .map { (name: $0.key, value: $0.value) }
    }

    private func execStart(execID: String) -> ShimResponse {
        let runtime = self.runtime
        let store = self.execStore
        if runtime.supportsRawProxy {
            return ShimResponse.hijacked { fd, initial in runtime.proxyHijack(requestData: initial, clientFD: fd) }
        }
        // docker exec hijacks the connection (Upgrade: tcp), expecting 101 then a raw stream.
        return ShimResponse(status: 101, headers: [
            (name: "Content-Type", value: "application/vnd.docker.raw-stream"),
            (name: "Connection", value: "Upgrade"),
            (name: "Upgrade", value: "tcp"),
        ], body: Data(), stream: { writer in
            guard let entry = store.command(for: execID) else { return }
            let result = (try? await runtime.exec(containerID: entry.container, command: entry.cmd)) ?? ExecResult(exitCode: 1, output: "")
            store.setResult(execID, exitCode: result.exitCode)
            let payload = Data(result.output.utf8)
            var frame = Data([1, 0, 0, 0])
            let length = UInt32(payload.count)
            frame.append(contentsOf: [UInt8(length >> 24 & 0xff), UInt8(length >> 16 & 0xff), UInt8(length >> 8 & 0xff), UInt8(length & 0xff)])
            frame.append(payload)
            _ = writer.write(frame)
        })
    }

    private func execInspect(execID: String, request: ParsedRequest) async -> ShimResponse {
        if runtime.supportsRawProxy {
            if let response = await runtime.proxyRequest(method: "GET", path: request.target, headers: [], body: Data()) {
                return ShimResponse(status: response.statusCode, headers: Self.proxyHeaders(response), body: response.body)
            }
        }
        let completed = execStore.result(for: execID)
        if completed != nil { execStore.finish(execID) }
        let payload = (try? JSONEncoder().encode(DockerExecInspectOut(ExitCode: completed ?? 0, Running: false))) ?? Data()
        return ShimResponse.json(payload)
    }

    private func archive(id: String, method: String, request: ParsedRequest) async -> ShimResponse {
        let path = request.query["path"] ?? "/"
        switch method {
        case "GET":
            guard let tar = await runtime.copyOut(containerID: id, path: path) else {
                return errorResponse(404, "could not read \(path)")
            }
            let stat = (try? JSONEncoder().encode(DockerPathStat(name: (path as NSString).lastPathComponent, size: tar.count, mode: 0o644)))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let header = Data(stat.utf8).base64EncodedString()
            return ShimResponse(status: 200, headers: [
                (name: "Content-Type", value: "application/x-tar"),
                (name: "X-Docker-Container-Path-Stat", value: header),
            ], body: tar)
        case "PUT":
            let ok = await runtime.copyIn(containerID: id, path: path, archive: request.body)
            return ok ? ShimResponse.empty(status: 200) : errorResponse(500, "could not write \(path)")
        case "HEAD":
            return ShimResponse.empty(status: 200)
        default:
            return errorResponse(405, "method not allowed")
        }
    }

    private func buildResponse(_ request: ParsedRequest) -> ShimResponse {
        let runtime = self.runtime
        let query = String(request.target.split(separator: "?", maxSplits: 1).dropFirst().first ?? "")
        let context = request.body
        return ShimResponse.streaming(contentType: "application/json") { writer in
            for await chunk in runtime.build(contextTar: context, query: query) {
                if !writer.write(chunk) { return }
            }
        }
    }

    private func eventsResponse() -> ShimResponse {
        let runtime = self.runtime
        return ShimResponse.streaming(contentType: "application/json") { writer in
            var previous = ((try? await runtime.snapshot())?.containers) ?? []
            let encoder = JSONEncoder()
            for _ in 0..<3600 {
                try? await Task.sleep(for: .seconds(1))
                guard let current = try? await runtime.snapshot().containers else { continue }
                let events = EventSynthesizer.diff(previous: previous, current: current)
                previous = current
                for event in events {
                    let now = Date().timeIntervalSince1970
                    let out = DockerEventOut(
                        eventType: "container", Action: event.action.rawValue,
                        Actor: DockerEventActor(ID: event.containerID, Attributes: ["name": event.name, "image": event.image]),
                        time: Int(now), timeNano: Int64(now * 1_000_000_000)
                    )
                    guard let data = try? encoder.encode(out), writer.write(data + Data("\n".utf8)) else { return }
                }
            }
        }
    }

    private func versionResponse() async -> ShimResponse {
        let snapshot = try? await runtime.snapshot()
        let out = DockerVersionOut(
            Version: snapshot?.engineVersion ?? "dory",
            ApiVersion: apiVersion, MinAPIVersion: "1.24",
            Os: "linux", Arch: "arm64", KernelVersion: "dory",
            GoVersion: "swift", GitCommit: "dory", BuildTime: ""
        )
        return encode(out)
    }

    private func infoResponse() async -> ShimResponse {
        let snapshot = (try? await runtime.snapshot()) ?? RuntimeSnapshot()
        let running = snapshot.containers.filter { $0.status == .running }.count
        let out = DockerInfoOut(
            ID: "DORY", Name: "dory",
            Containers: snapshot.containers.count, ContainersRunning: running,
            ContainersPaused: snapshot.containers.filter { $0.status == .paused }.count,
            ContainersStopped: snapshot.containers.filter { $0.status == .stopped }.count,
            Images: snapshot.images.count, NCPU: ProcessInfo.processInfo.processorCount,
            MemTotal: Int64(ProcessInfo.processInfo.physicalMemory),
            ServerVersion: snapshot.engineVersion, OperatingSystem: "Dory",
            OSType: "linux", Architecture: "aarch64", Driver: "dory"
        )
        return encode(out)
    }

    private func containersResponse(all: Bool) async -> ShimResponse {
        let snapshot = (try? await runtime.snapshot()) ?? RuntimeSnapshot()
        let containers = snapshot.containers
            .filter { all || $0.status == .running }
            .map { container -> DockerContainerOut in
                let state = container.status == .running ? "running" : (container.status == .paused ? "paused" : "exited")
                let status = container.status == .running ? "Up \(container.uptime)" : "Exited"
                return DockerContainerOut(
                    Id: container.id, Names: ["/\(container.name)"],
                    Image: container.image, ImageID: container.image,
                    Command: container.command, Created: container.createdEpoch ?? 0,
                    State: state, Status: status, Ports: parsePorts(container.ports), Labels: [:]
                )
            }
        return encode(containers)
    }

    private func imagesResponse() async -> ShimResponse {
        let snapshot = (try? await runtime.snapshot()) ?? RuntimeSnapshot()
        let images = snapshot.images.map { image in
            DockerImageOut(Id: image.imageID, RepoTags: ["\(image.repository):\(image.tag)"], Containers: image.usedByCount)
        }
        return encode(images)
    }

    private func parsePorts(_ display: String) -> [DockerPortOut] {
        guard display != "—" else { return [] }
        return display.split(separator: ",").compactMap { piece -> DockerPortOut? in
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            if let arrow = trimmed.range(of: "→") {
                let pub = Int(trimmed[trimmed.startIndex..<arrow.lowerBound])
                let priv = Int(trimmed[arrow.upperBound...])
                guard let priv else { return nil }
                return DockerPortOut(PrivatePort: priv, PublicPort: pub, portType: "tcp")
            }
            guard let priv = Int(trimmed) else { return nil }
            return DockerPortOut(PrivatePort: priv, PublicPort: nil, portType: "tcp")
        }
    }

    private func encode<T: Encodable>(_ value: T) -> ShimResponse {
        guard let data = try? JSONEncoder().encode(value) else { return errorResponse(500, "encode failed") }
        return ShimResponse.json(data)
    }

    private func errorResponse(_ status: Int, _ message: String) -> ShimResponse {
        let data = (try? JSONEncoder().encode(DockerErrorOut(message: message))) ?? Data()
        return ShimResponse.json(data, status: status)
    }

    static func normalize(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count >= 2, parts[1].hasPrefix("v"), parts[1].dropFirst().first?.isNumber == true {
            return "/" + parts.dropFirst(2).joined(separator: "/")
        }
        return path
    }

    static func iso8601(epoch: Int) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }
}
