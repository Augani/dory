import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Thread-safe engine-activity tracker shared between the shim's connection threads and the
/// MainActor idle monitor. `active` counts in-flight docker requests (so a long build/pull/exec that
/// holds one connection for minutes blocks the idle sleep), `last` is the last meaningful use (used
/// to time the idle window), and `sleeping` lets a shim thread learn the engine is asleep without a
/// MainActor hop, hopping over only to wake it.
final class ShimActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var _active = 0
    private var _last = Date()
    private var _sleeping = false
    func begin() { lock.lock(); _active += 1; lock.unlock() }
    func end() { lock.lock(); if _active > 0 { _active -= 1 }; lock.unlock() }
    func touch() { lock.lock(); _last = Date(); lock.unlock() }
    func setSleeping(_ value: Bool) { lock.lock(); _sleeping = value; lock.unlock() }
#if DEBUG
    func setLastForTests(_ date: Date) { lock.lock(); _last = date; lock.unlock() }
#endif
    var isSleeping: Bool { lock.lock(); defer { lock.unlock() }; return _sleeping }
    var snapshot: (active: Int, last: Date) { lock.lock(); defer { lock.unlock() }; return (_active, _last) }
}

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
    var registrySearch: any RegistryImageSearch = HubImageSearch()
    /// Shared activity tracker (nil for backends that never sleep / in tests). The shim records
    /// meaningful requests here and, when the engine is asleep, calls `onWake` to bring it back.
    var activity: ShimActivity?
    var onWake: (@Sendable () async -> Void)?

    static var defaultSocketPath: String { "\(NSHomeDirectory())/.dory/dory.sock" }

    private enum ContainerResolution {
        case found(Container)
        case failure(ShimResponse)
    }

    func handle(_ request: ParsedRequest) async -> ShimResponse {
        let path = Self.normalize(request.path)
        let method = request.method.uppercased()
        // `/_ping` is a pure liveness probe (the docker CLI, health checkers, and doryd idle checks
        // all poll it) and is answered by the shim without touching the engine, so it must NOT count
        // as use or wake a sleeping engine. Every other request is real use: record it, and if the
        // idle monitor slept the engine, wake it first so the request runs against a live engine.
        if path != "/_ping" {
            activity?.touch()
            if activity?.isSleeping == true { await onWake?() }
        }
        // Docker-compatible backends proxy unsupported normal endpoints at the fallback below.
        // True connection-hijack endpoints still return `ShimResponse.hijacked` from their
        // per-endpoint handlers, which keeps exec/attach/BuildKit bidirectional streams intact
        // without tunneling unrelated future requests on the same client connection.

        // Docker-backed runtimes own these complete bounded API contracts. Keep filters, options,
        // flags, payloads, and status codes byte-transparent; mock runtimes use the handlers below.
        if runtime.supportsRawProxy, Self.isBufferedDockerObjectRequest(method: method, path: path) {
            guard let response = await runtime.proxyRequest(
                method: method,
                path: request.target,
                headers: Self.proxyRequestHeaders(request),
                body: request.body
            ) else {
                return errorResponse(502, "docker engine unavailable")
            }
            return ShimResponse(
                status: response.statusCode,
                headers: Self.proxyHeaders(response),
                body: response.body
            )
        }

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
            return await containersResponse(
                request: request,
                all: request.query["all"] == "1" || request.query["all"] == "true",
                filters: DockerListFilters.parse(request.query["filters"]),
                includeSize: Self.queryBool("size", in: request.query, default: false),
                limit: request.query["limit"].flatMap(Int.init)
            )
        case ("GET", "/images/json"):
            return await imagesResponse(filters: DockerListFilters.parse(request.query["filters"]))
        case ("GET", "/images/search"):
            return await imageSearchResponse(request)
        case ("GET", "/networks"):
            return await networksResponse(filters: DockerListFilters.parse(request.query["filters"]))
        case ("GET", "/volumes"):
            return await volumesResponse(filters: DockerListFilters.parse(request.query["filters"]))
        case ("GET", "/events"):
            return eventsResponse(request)
        case ("GET", "/system/df"):
            return await systemDiskUsageResponse()
        case ("POST", "/build"):
            return buildResponse(request)
        case ("POST", "/commit"):
            return await commitContainer(request)
        case ("GET", "/images/get"):
            return await saveImagesResponse(request)
        case ("POST", "/images/load"):
            return await loadImage(request)
        case ("POST", "/auth"):
            return await auth(request)
        case ("POST", "/volumes/create"):
            return await createVolume(request)
        case ("POST", "/containers/prune"):
            return await pruneContainers()
        case ("POST", "/volumes/prune"):
            return await pruneVolumes()
        case ("POST", "/networks/prune"):
            return await pruneNetworks()
        case ("POST", "/images/prune"):
            return await pruneImages()
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

    private static func isDockerNetworkRequest(method: String, path: String) -> Bool {
        if path == "/networks" { return method == "GET" }
        if path == "/networks/create" || path == "/networks/prune" { return method == "POST" }
        return path.hasPrefix("/networks/") && (method == "GET" || method == "POST" || method == "DELETE")
    }

    private static func isDockerVolumeRequest(method: String, path: String) -> Bool {
        if path == "/volumes" { return method == "GET" }
        if path == "/volumes/create" || path == "/volumes/prune" { return method == "POST" }
        return path.hasPrefix("/volumes/") && (method == "GET" || method == "DELETE")
    }

    private static func isBufferedDockerImageRequest(method: String, path: String) -> Bool {
        if method == "POST", path == "/auth" || path == "/images/prune" { return true }
        if method == "GET", path == "/images/json" || path == "/images/search" || path == "/system/df" {
            return true
        }
        guard path.hasPrefix("/images/") else { return false }
        if method == "DELETE" { return true }
        if method == "GET", path.hasSuffix("/json") || path.hasSuffix("/history") { return true }
        return method == "POST" && path.hasSuffix("/tag")
    }

    private static func isBufferedDockerObjectRequest(method: String, path: String) -> Bool {
        isDockerNetworkRequest(method: method, path: path)
            || isBufferedDockerImageRequest(method: method, path: path)
            || isDockerVolumeRequest(method: method, path: path)
    }

    private func routeParameterized(_ request: ParsedRequest, method: String, path: String) async -> ShimResponse {
        if method == "POST", path == "/containers/create" { return await createContainer(request) }
        if method == "POST", path == "/images/create" { return await pullImage(request) }
        if method == "POST", path == "/networks/create" { return await createNetwork(request) }

        let parts = path.split(separator: "/").map(String.init)
        if parts.count == 3, parts[0] == "networks", method == "POST", parts[2] == "connect" {
            return await connectNetwork(name: parts[1], request: request)
        }
        if parts.count == 3, parts[0] == "networks", method == "POST", parts[2] == "disconnect" {
            return await disconnectNetwork(name: parts[1], request: request)
        }
        if parts.count == 3, parts[0] == "containers", method == "POST", parts[2] == "exec" {
            return await execCreate(containerID: parts[1], request: request)
        }
        if parts.count == 3, parts[0] == "containers", method == "POST", parts[2] == "attach" {
            return await attachContainer(id: parts[1], request: request)
        }
        if parts.count == 3, parts[0] == "exec", method == "POST", parts[2] == "start" {
            return execStart(execID: parts[1])
        }
        if parts.count == 3, parts[0] == "exec", method == "GET", parts[2] == "json" {
            return await execInspect(execID: parts[1], request: request)
        }
        if parts.count == 3, parts[0] == "containers", method == "GET", parts[2] == "json" {
            return await inspectResponse(
                id: parts[1],
                includeSize: Self.queryBool("size", in: request.query, default: false),
                request: request
            )
        }
        if parts.count == 3, parts[0] == "containers", method == "GET", parts[2] == "top" {
            return await topResponse(id: parts[1])
        }
        if parts.count == 3, parts[0] == "containers", method == "GET", parts[2] == "changes" {
            return await changesResponse(id: parts[1])
        }
        if method == "GET", let id = Self.imageHistoryName(in: path) {
            return await imageHistoryResponse(id: id)
        }
        if method == "GET", let id = Self.imageSaveName(in: path) {
            return saveImageResponse(reference: id)
        }
        if method == "POST", let id = Self.imagePushName(in: path) {
            return await pushImage(source: id, request: request)
        }
        if method == "POST", let id = Self.imageTagName(in: path) {
            return await tagImage(source: id, request: request)
        }
        if method == "GET", let id = Self.imageInspectName(in: path) {
            return await imageInspectResponse(id: id)
        }
        if method == "GET", let name = Self.resourceName(after: "/networks/", in: path) {
            return await networkInspectResponse(name: name)
        }
        if method == "GET", let name = Self.resourceName(after: "/volumes/", in: path) {
            return await volumeInspectResponse(name: name)
        }
        if parts.count == 3, parts[0] == "containers", method == "GET", parts[2] == "logs" {
            return await logsResponse(id: parts[1], request: request)
        }
        if parts.count == 3, parts[0] == "containers", method == "GET", parts[2] == "stats" {
            return await statsResponse(id: parts[1], stream: request.query["stream"] != "0" && request.query["stream"] != "false")
        }
        if parts.count == 3, parts[0] == "containers", parts[2] == "archive" {
            return await archive(id: parts[1], method: method, request: request)
        }
        if parts.count == 3, parts[0] == "containers", method == "GET", parts[2] == "export" {
            return await exportContainer(id: parts[1])
        }
        if parts.count == 3, parts[0] == "containers", method == "POST", parts[2] == "wait" {
            return await waitContainer(id: parts[1], request: request)
        }
        if parts.count == 3, parts[0] == "containers", method == "POST", parts[2] == "rename" {
            return await rename(id: parts[1], request: request)
        }
        if parts.count == 3, parts[0] == "containers", method == "POST", parts[2] == "update" {
            return await updateContainer(id: parts[1], request: request)
        }
        if parts.count == 3, parts[0] == "containers", method == "POST", parts[2] == "resize" {
            return await resizeContainer(id: parts[1], request: request)
        }
        if parts.count == 3, parts[0] == "containers", method == "POST" {
            return await lifecycle(id: parts[1], action: parts[2], request: request)
        }
        if parts.count == 2, parts[0] == "containers", method == "DELETE" {
            return await remove(id: parts[1])
        }
        if method == "DELETE", let name = Self.resourceName(after: "/networks/", in: path) {
            return await removeNetwork(name: name)
        }
        if method == "DELETE", let name = Self.resourceName(after: "/volumes/", in: path) {
            return await removeVolume(name: name)
        }
        if method == "DELETE", let id = Self.resourceName(after: "/images/", in: path) {
            return await removeImage(id: id)
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
        if runtime.supportsRawProxy {
            let normalized = runtime.kind == .sharedVM
                ? Self.sharedVMNormalizedCreateBody(request.body)
                : SharedVMCreateBody(body: request.body, compatibilityError: nil)
            if let message = normalized.compatibilityError {
                return errorResponse(501, message)
            }
            guard let response = await runtime.proxyRequest(
                method: request.method.uppercased(),
                path: request.target,
                headers: Self.proxyRequestHeaders(request),
                body: normalized.body
            ) else {
                return errorResponse(502, "docker engine unavailable")
            }
            return ShimResponse(status: response.statusCode, headers: Self.proxyHeaders(response), body: response.body)
        }
        guard let body = try? JSONDecoder().decode(DockerCreateRequest.self, from: request.body) else {
            return errorResponse(400, "invalid create request body")
        }
        let spec = body.spec(name: request.query["name"], platform: request.query["platform"])
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
        let runtime = self.runtime
        if runtime.supportsRawProxy {
            // Raw passthrough so the pull keeps every query parameter (`platform` above all — a
            // re-synthesized pull silently fetched the native-arch variant, so
            // `docker run --platform linux/amd64` then refused the image) and streams dockerd's real
            // layer-by-layer progress instead of synthesized lines.
            return ShimResponse.hijacked { fd, initial in runtime.proxyHijack(requestData: initial, clientFD: fd) }
        }
        let reference = PullReference.resolve(fromImage: from, tagQuery: request.query["tag"])
        let clientAuth = request.headers["x-registry-auth"]
        return ShimResponse.streaming(contentType: "application/json") { writer in
            let initial = PullProgress.lines(repository: reference.repository, tag: reference.tag, reference: reference.reference).first ?? Data()
            guard writer.write(initial) else { return }
            do {
                try await runtime.pull(image: reference.reference, registryAuth: clientAuth)
                for line in PullProgress.lines(repository: reference.repository, tag: reference.tag, reference: reference.reference).dropFirst() {
                    guard writer.write(line) else { return }
                }
            } catch {
                _ = writer.write(PullProgress.error(message: Self.runtimeErrorMessage(error)))
            }
        }
    }

    private struct SharedVMCreateBody {
        var body: Data
        var compatibilityError: String?
    }

    private static let sharedVMHostServiceGateway = "host-gateway"
    private static let sharedVMGPUUnsupportedMessage =
        "Dory's shared VM accepts Docker --gpus only when GPU acceleration is enabled in Settings > Docker Engine > GPU Acceleration (this restarts the engine). Enable it, then rerun with --gpus all on an image that ships Mesa's Venus Vulkan driver. Alternatively, run a Metal-backed host service such as Ollama, LM Studio, MLX, or llama.cpp and call it from containers at http://host.dory.internal:11434 or http://host.dory.internal:1234."

    private static func sharedVMNormalizedCreateBody(_ body: Data) -> SharedVMCreateBody {
        guard var root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return SharedVMCreateBody(body: body, compatibilityError: nil)
        }

        var hostConfig = root["HostConfig"] as? [String: Any] ?? [:]
        var changed = false
        var portBindings = hostConfig["PortBindings"] as? [String: Any] ?? [:]
        for key in portBindings.keys {
            guard var bindings = portBindings[key] as? [[String: Any]] else { continue }
            for index in bindings.indices {
                guard let hostIP = bindings[index]["HostIp"] as? String,
                      isLoopbackHostIP(hostIP) else { continue }
                bindings[index]["HostIp"] = ""
                changed = true
            }
            portBindings[key] = bindings
        }
        if normalizeSharedVMHostAliases(in: &hostConfig) {
            changed = true
        }
        if normalizeSharedVMDockerSocketMounts(in: &hostConfig) {
            changed = true
        }

        var compatibilityError: String?
        if hasGPUDeviceRequest(hostConfig) {
            if sharedVMGPUDeviceTranslationEnabled() {
                if normalizeSharedVMGPUDevices(in: &hostConfig) {
                    changed = true
                }
            } else {
                compatibilityError = sharedVMGPUUnsupportedMessage
            }
        }
        guard changed else {
            return SharedVMCreateBody(body: body, compatibilityError: compatibilityError)
        }

        if hostConfig["PortBindings"] != nil {
            hostConfig["PortBindings"] = portBindings
        }
        root["HostConfig"] = hostConfig
        return SharedVMCreateBody(
            body: (try? JSONSerialization.data(withJSONObject: root)) ?? body,
            compatibilityError: compatibilityError
        )
    }

    private static func isLoopbackHostIP(_ value: String) -> Bool {
        var host = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }
        return host == "localhost"
            || host == "::1"
            || host == "0:0:0:0:0:0:0:1"
            || host.hasPrefix("127.")
    }

    private static func isDoryProxySocketPath(_ value: String) -> Bool {
        value.hasSuffix("/.dory/dory.sock") || value.hasSuffix("/.dory/engine.sock")
    }

    private static func normalizeSharedVMDockerSocketMounts(in hostConfig: inout [String: Any]) -> Bool {
        var changed = false
        if var binds = hostConfig["Binds"] as? [Any] {
            for index in binds.indices {
                guard let raw = binds[index] as? String else { continue }
                let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 2,
                      parts[1] == "/var/run/docker.sock",
                      isDoryProxySocketPath(parts[0]) else { continue }
                let suffix = parts.count > 2 ? ":" + parts.dropFirst(2).joined(separator: ":") : ""
                binds[index] = "/var/run/docker.sock:/var/run/docker.sock\(suffix)"
                changed = true
            }
            if changed { hostConfig["Binds"] = binds }
        }

        if var mounts = hostConfig["Mounts"] as? [[String: Any]] {
            var mountsChanged = false
            for index in mounts.indices {
                let target = (mounts[index]["Target"] ?? mounts[index]["Destination"]) as? String
                guard mounts[index]["Type"] as? String == "bind",
                      target == "/var/run/docker.sock",
                      let source = mounts[index]["Source"] as? String,
                      isDoryProxySocketPath(source) else { continue }
                mounts[index]["Source"] = "/var/run/docker.sock"
                mountsChanged = true
            }
            if mountsChanged {
                hostConfig["Mounts"] = mounts
                changed = true
            }
        }
        return changed
    }

    private static func normalizeSharedVMHostAliases(in hostConfig: inout [String: Any]) -> Bool {
        var extraHosts = hostConfig["ExtraHosts"] as? [Any] ?? []
        var changed = false
        for alias in ["host.docker.internal", "host.dory.internal"] {
            let desired = "\(alias):\(sharedVMHostServiceGateway)"
            if let index = extraHosts.firstIndex(where: { entry in
                guard let string = entry as? String else { return false }
                return extraHostName(string) == alias
            }) {
                guard let current = extraHosts[index] as? String,
                      current != desired,
                      shouldRewriteSharedVMHostAlias(current) else { continue }
                extraHosts[index] = desired
                changed = true
            } else {
                extraHosts.append(desired)
                changed = true
            }
        }
        if changed {
            hostConfig["ExtraHosts"] = extraHosts
        }
        return changed
    }

    private static func extraHostName(_ value: String) -> String {
        value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
    }

    private static func shouldRewriteSharedVMHostAlias(_ value: String) -> Bool {
        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count > 1 else { return true }
        var address = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if address.hasPrefix("["), address.hasSuffix("]") {
            address.removeFirst()
            address.removeLast()
        }
        return address.isEmpty || address == "host-gateway" || address == "172.17.0.1" || address == "10.0.2.2"
    }

    private static func hasGPUDeviceRequest(_ hostConfig: [String: Any]) -> Bool {
        guard let requests = hostConfig["DeviceRequests"] as? [[String: Any]] else { return false }
        return requests.contains { request in
            if let driver = (request["Driver"] as? String)?.lowercased(),
               driver.contains("gpu") || driver.contains("nvidia") || driver.contains("cuda") {
                return true
            }
            return containsGPUCapability(request["Capabilities"] as Any)
        }
    }

    private static func sharedVMGPUDeviceTranslationEnabled() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["DORY_EXPERIMENTAL_GPU"] == "venus"
            || environment["DORY_SHARED_VM_GPU_DEVICES"] == "1"
    }

    private static func normalizeSharedVMGPUDevices(in hostConfig: inout [String: Any]) -> Bool {
        var changed = false
        if hostConfig["DeviceRequests"] != nil {
            hostConfig.removeValue(forKey: "DeviceRequests")
            changed = true
        }

        var devices = hostConfig["Devices"] as? [[String: Any]]
            ?? (hostConfig["Devices"] as? [Any])?.compactMap { $0 as? [String: Any] }
            ?? []
        for path in ["/dev/dri/renderD128", "/dev/dri/card0"] {
            let alreadyPresent = devices.contains { device in
                device["PathInContainer"] as? String == path || device["PathOnHost"] as? String == path
            }
            if !alreadyPresent {
                devices.append([
                    "PathOnHost": path,
                    "PathInContainer": path,
                    "CgroupPermissions": "rwm",
                ])
                changed = true
            }
        }
        if changed || hostConfig["Devices"] != nil {
            hostConfig["Devices"] = devices
        }

        var rules = hostConfig["DeviceCgroupRules"] as? [String]
            ?? (hostConfig["DeviceCgroupRules"] as? [Any])?.compactMap { $0 as? String }
            ?? []
        if !rules.contains("c 226:* rwm") {
            rules.append("c 226:* rwm")
            hostConfig["DeviceCgroupRules"] = rules
            changed = true
        }
        return changed
    }

    private static func containsGPUCapability(_ value: Any) -> Bool {
        if let string = value as? String {
            return string.lowercased().contains("gpu")
        }
        if let values = value as? [Any] {
            return values.contains { containsGPUCapability($0) }
        }
        return false
    }

    private func createNetwork(_ request: ParsedRequest) async -> ShimResponse {
        guard let body = try? JSONDecoder().decode(DockerNetworkCreateRequest.self, from: request.body) else {
            return errorResponse(400, "network name is required")
        }
        let name = body.Name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return errorResponse(400, "network name is required") }
        do {
            try await runtime.createNetwork(name: name, labels: body.Labels ?? [:])
            return ShimResponse.json(try JSONEncoder().encode(DockerNetworkCreatedOut(Id: name, Warning: "")), status: 201)
        } catch { return createNetworkErrorResponse(error) }
    }

    private func connectNetwork(name: String, request: ParsedRequest) async -> ShimResponse {
        guard let body = try? JSONDecoder().decode(DockerNetworkConnectRequest.self, from: request.body),
              let container = body.Container?.trimmingCharacters(in: .whitespacesAndNewlines),
              !container.isEmpty else {
            return errorResponse(400, "container is required")
        }
        do {
            try await runtime.connectNetwork(name: name, containerID: container)
            return ShimResponse.empty(status: 200)
        } catch {
            return runtimeErrorResponse(error, fallbackStatus: 500)
        }
    }

    private func disconnectNetwork(name: String, request: ParsedRequest) async -> ShimResponse {
        guard let body = try? JSONDecoder().decode(DockerNetworkDisconnectRequest.self, from: request.body),
              let container = body.Container?.trimmingCharacters(in: .whitespacesAndNewlines),
              !container.isEmpty else {
            return errorResponse(400, "container is required")
        }
        do {
            try await runtime.disconnectNetwork(name: name, containerID: container, force: body.Force ?? false)
            return ShimResponse.empty(status: 200)
        } catch {
            return runtimeErrorResponse(error, fallbackStatus: 500)
        }
    }

    private func createVolume(_ request: ParsedRequest) async -> ShimResponse {
        let body = (try? JSONDecoder().decode(DockerVolumeCreateRequest.self, from: request.body))
        let name = body?.Name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? body!.Name!.trimmingCharacters(in: .whitespacesAndNewlines)
            : "dory-\(UUID().uuidString.prefix(12))"
        let requestedDriver = body?.Driver?.trimmingCharacters(in: .whitespacesAndNewlines)
        let runtimeDriver = requestedDriver.flatMap { $0.isEmpty ? nil : $0 }
        let driver = runtimeDriver ?? "local"
        let labels = body?.Labels ?? [:]
        let driverOptions = body?.DriverOpts ?? [:]
        do {
            try await runtime.createVolume(
                name: name,
                driver: runtimeDriver,
                labels: labels,
                driverOptions: driverOptions
            )
            let out = DockerVolumeOut(
                Name: name,
                Driver: driver,
                Mountpoint: "/var/lib/dory/volumes/\(name)",
                Labels: labels,
                Options: driverOptions
            )
            return encode(out, status: 201)
        } catch { return errorResponse(500, "\(error)") }
    }

    private func removeNetwork(name: String) async -> ShimResponse {
        do { try await runtime.removeNetwork(name: name); return ShimResponse.empty(status: 204) }
        catch { return removeNetworkErrorResponse(error, name: name) }
    }

    private func removeVolume(name: String) async -> ShimResponse {
        let snapshot: RuntimeSnapshot
        do {
            snapshot = try await runtime.snapshot()
        } catch {
            return runtimeErrorResponse(error, fallbackStatus: 500)
        }
        guard snapshot.volumes.contains(where: { $0.name == name }) else {
            return errorResponse(404, "no such volume: \(name)")
        }
        do { try await runtime.removeVolume(name: name); return ShimResponse.empty(status: 204) }
        catch { return removeVolumeErrorResponse(error, name: name) }
    }

    private func removeImage(id: String) async -> ShimResponse {
        let snapshot: RuntimeSnapshot
        do {
            snapshot = try await runtime.snapshot()
        } catch {
            return runtimeErrorResponse(error, fallbackStatus: 500)
        }
        guard snapshot.images.contains(where: { Self.imageMatches($0, id: id) }) else {
            return errorResponse(404, "no such image: \(id)")
        }
        do {
            try await runtime.removeImage(id: id)
            return encode([DockerImageDeleteOut(Deleted: id, Untagged: nil)])
        } catch { return removeImageErrorResponse(error, id: id) }
    }

    private func tagImage(source: String, request: ParsedRequest) async -> ShimResponse {
        guard let repo = request.query["repo"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !repo.isEmpty else {
            return errorResponse(400, "repo is required")
        }
        let tag = request.query["tag"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? request.query["tag"]!.trimmingCharacters(in: .whitespacesAndNewlines)
            : "latest"
        do {
            try await runtime.tagImage(source: source, repo: repo, tag: tag)
            return ShimResponse.empty(status: 201)
        } catch {
            return runtimeErrorResponse(error, fallbackStatus: 500)
        }
    }

    private func pushImage(source: String, request: ParsedRequest) async -> ShimResponse {
        let reference = Self.imagePushReference(name: source, tag: request.query["tag"])
        do {
            let stream = try await runtime.pushImage(reference: reference, registryAuth: request.headers["x-registry-auth"])
            return ShimResponse.streaming(contentType: "application/json") { writer in
                for await chunk in stream {
                    guard writer.write(chunk) else { return }
                }
            }
        } catch {
            return runtimeErrorResponse(error, fallbackStatus: 500)
        }
    }

    private func commitContainer(_ request: ParsedRequest) async -> ShimResponse {
        guard let container = request.query["container"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !container.isEmpty else {
            return errorResponse(400, "container is required")
        }
        guard let repo = request.query["repo"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !repo.isEmpty else {
            return errorResponse(400, "repo is required")
        }
        let tag = request.query["tag"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? request.query["tag"]!.trimmingCharacters(in: .whitespacesAndNewlines)
            : "latest"
        let body = (try? JSONDecoder().decode(DockerCommitRequest.self, from: request.body))
        let resolved: Container
        switch await resolveContainer(id: container) {
        case .found(let container): resolved = container
        case .failure(let response): return response
        }
        do {
            let id = try await runtime.commit(containerID: resolved.id, repo: repo, tag: tag, labels: body?.labels ?? [:])
            return encode(DockerCommitOut(Id: id), status: 201)
        } catch {
            return runtimeErrorResponse(error, fallbackStatus: 500)
        }
    }

    private func saveImageResponse(reference: String) -> ShimResponse {
        imageArchiveResponse(runtime.saveImage(reference: reference))
    }

    private func imageArchiveResponse(_ stream: AsyncStream<Data>) -> ShimResponse {
        return ShimResponse.streaming(contentType: "application/x-tar") { writer in
            for await chunk in stream {
                guard writer.write(chunk) else { return }
            }
        }
    }

    private func saveImagesResponse(_ request: ParsedRequest) async -> ShimResponse {
        let references = Self.imageSaveReferences(from: request.queryValues(for: "names"))
        guard !references.isEmpty else { return errorResponse(400, "names is required") }
        do {
            return imageArchiveResponse(try await runtime.saveImages(references: references))
        } catch {
            return runtimeErrorResponse(error, fallbackStatus: 500)
        }
    }

    private func loadImage(_ request: ParsedRequest) async -> ShimResponse {
        do {
            if runtime.supportsImageLoadReceipt {
                let archive = request.body
                let stream = AsyncThrowingStream<Data, Error> { continuation in
                    continuation.yield(archive)
                    continuation.finish()
                }
                let response = try await runtime.loadImageThrowingWithResponse(stream: stream)
                guard !response.isEmpty else {
                    return errorResponse(502, "target engine returned an empty image-load response")
                }
                return ShimResponse(
                    status: 200,
                    headers: [(name: "Content-Type", value: "application/json")],
                    body: response
                )
            } else {
                try await runtime.loadImage(tar: request.body)
            }
            let line = (try? JSONEncoder().encode(DockerImageLoadOut(stream: "Loaded image\n"))) ?? Data()
            return ShimResponse(status: 200, headers: [(name: "Content-Type", value: "application/json")],
                                body: line + Data("\n".utf8))
        } catch {
            return runtimeErrorResponse(error, fallbackStatus: 500)
        }
    }

    private func auth(_ request: ParsedRequest) async -> ShimResponse {
        guard let body = try? JSONDecoder().decode(DockerAuthRequest.self, from: request.body) else {
            return errorResponse(400, "invalid auth request body")
        }
        guard let credentials = body.decodedCredentials else {
            return errorResponse(400, "username and password are required")
        }
        do {
            try await runtime.login(registry: body.registry, username: credentials.username, password: credentials.password)
            return encode(DockerAuthOut(Status: "Login Succeeded"))
        } catch {
            return runtimeErrorResponse(error, fallbackStatus: 401)
        }
    }

    private func pruneContainers() async -> ShimResponse {
        do {
            try await runtime.pruneContainers()
            return encode(DockerContainerPruneOut(ContainersDeleted: [], SpaceReclaimed: 0))
        } catch { return errorResponse(500, "\(error)") }
    }

    private func pruneNetworks() async -> ShimResponse {
        do {
            try await runtime.pruneNetworks()
            return encode(DockerNetworkPruneOut(NetworksDeleted: [], SpaceReclaimed: 0))
        } catch { return errorResponse(500, "\(error)") }
    }

    private func pruneVolumes() async -> ShimResponse {
        do {
            try await runtime.pruneVolumes()
            return encode(DockerVolumePruneOut(VolumesDeleted: [], SpaceReclaimed: 0))
        } catch { return errorResponse(500, "\(error)") }
    }

    private func pruneImages() async -> ShimResponse {
        do {
            try await runtime.pruneImages()
            return encode(DockerImagePruneOut(ImagesDeleted: [], SpaceReclaimed: 0))
        } catch { return errorResponse(500, "\(error)") }
    }

    private func networksResponse(filters: [String: [String]]) async -> ShimResponse {
        let snapshot = (try? await runtime.snapshot()) ?? RuntimeSnapshot()
        let networks = snapshot.networks
            .filter { DockerListFilters.matches($0, filters: filters) }
            .map {
                DockerNetworkOut(Id: $0.name, Name: $0.name, Driver: $0.driver, Scope: $0.scope, Labels: $0.labels)
            }
        return encode(networks)
    }

    private func volumesResponse(filters: [String: [String]]) async -> ShimResponse {
        let snapshot = (try? await runtime.snapshot()) ?? RuntimeSnapshot()
        let volumes = snapshot.volumes
            .filter { DockerListFilters.matches($0, filters: filters) }
            .map {
                DockerVolumeOut(
                    Name: $0.name,
                    Driver: $0.driver,
                    Mountpoint: "/var/lib/dory/volumes/\($0.name)",
                    Labels: $0.labels,
                    Options: $0.options
                )
            }
        return encode(DockerVolumeListOut(Volumes: volumes))
    }

    private func topResponse(id: String) async -> ShimResponse {
        let snapshot = (try? await runtime.snapshot()) ?? RuntimeSnapshot()
        guard let container = snapshot.containers.first(where: { Self.containerMatches($0, id: id) }) else {
            return errorResponse(404, "no such container: \(id)")
        }
        guard container.isRunning else {
            return errorResponse(409, "container \(id) is not running")
        }
        let command = container.command.isEmpty ? container.image : container.command
        let out = DockerContainerTopOut(
            Titles: ["UID", "PID", "PPID", "C", "STIME", "TTY", "TIME", "CMD"],
            Processes: [[
                "root",
                "1",
                "0",
                "0",
                container.createdEpoch.map(String.init) ?? "0",
                "?",
                "00:00:00",
                command,
            ]]
        )
        return encode(out)
    }

    private func changesResponse(id: String) async -> ShimResponse {
        let snapshot = (try? await runtime.snapshot()) ?? RuntimeSnapshot()
        guard snapshot.containers.contains(where: { Self.containerMatches($0, id: id) }) else {
            return errorResponse(404, "no such container: \(id)")
        }
        return encode([DockerContainerChangeOut]())
    }

    private func waitContainer(id: String, request: ParsedRequest) async -> ShimResponse {
        if runtime.supportsRawProxy {
            // Raw passthrough, NOT a buffered proxyRequest: /wait is a long-poll whose response
            // headers dockerd flushes immediately so the client knows the wait is registered before
            // it sends /start. Buffering holds those headers until the container exits — but for
            // `docker run --rm` the CLI will not start the container until it sees them, a deadlock
            // that left every foreground run stuck with no output.
            return ShimResponse.hijacked { fd, initial in runtime.proxyHijack(requestData: initial, clientFD: fd) }
        }
        while !Task.isCancelled {
            let snapshot: RuntimeSnapshot
            do {
                snapshot = try await runtime.snapshot()
            } catch {
                return runtimeErrorResponse(error, fallbackStatus: 500)
            }
            guard let container = snapshot.containers.first(where: { Self.containerMatches($0, id: id) }) else {
                return errorResponse(404, "no such container: \(id)")
            }
            if container.status == .stopped {
                var fallbackCode = await runtime.containerExitCode(container.id)
                if fallbackCode == nil {
                    fallbackCode = await runtime.containerExitCode(id)
                }
                if fallbackCode == nil {
                    fallbackCode = container.exitCode
                }
                return ShimResponse.json(Data("{\"StatusCode\":\(ContainerWait.statusCode(fallbackCode))}".utf8))
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return errorResponse(499, "wait cancelled")
    }

    private func imageInspectResponse(id: String) async -> ShimResponse {
        let snapshot = (try? await runtime.snapshot()) ?? RuntimeSnapshot()
        guard let image = snapshot.images.first(where: { Self.imageMatches($0, id: id) }) else {
            return errorResponse(404, "no such image: \(id)")
        }
        let reference = Self.imageReference(image)
        let digest = image.imageID.hasPrefix("sha256:") ? image.imageID : "sha256:\(image.imageID)"
        let out = DockerImageInspectOut(
            Id: digest,
            RepoTags: [reference],
            RepoDigests: [],
            Created: image.createdEpoch > 0 ? Self.iso8601(epoch: image.createdEpoch) : "",
            Size: image.sizeBytes,
            VirtualSize: image.sizeBytes,
            Architecture: Self.defaultDockerArchitecture(),
            Os: "linux",
            Config: DockerImageInspectConfigOut(
                Env: [],
                Cmd: nil,
                Entrypoint: nil,
                WorkingDir: "/",
                Labels: image.labels,
                ExposedPorts: [:]
            )
        )
        return encode(out)
    }

    private func imageHistoryResponse(id: String) async -> ShimResponse {
        let snapshot = (try? await runtime.snapshot()) ?? RuntimeSnapshot()
        guard let image = snapshot.images.first(where: { Self.imageMatches($0, id: id) }) else {
            return errorResponse(404, "no such image: \(id)")
        }
        let reference = Self.imageReference(image)
        let digest = image.imageID.hasPrefix("sha256:") ? image.imageID : "sha256:\(image.imageID)"
        let out = DockerImageHistoryOut(
            Id: digest,
            Created: image.createdEpoch,
            CreatedBy: "/bin/sh -c #(nop) Dory image metadata",
            Tags: [reference],
            Size: image.sizeBytes,
            Comment: ""
        )
        return encode([out])
    }

    private func networkInspectResponse(name: String) async -> ShimResponse {
        let snapshot = (try? await runtime.snapshot()) ?? RuntimeSnapshot()
        guard let network = snapshot.networks.first(where: { $0.name == name }) else {
            return errorResponse(404, "network \(name) not found")
        }
        let subnet = network.subnet == "—" ? nil : network.subnet
        let out = DockerNetworkInspectOut(
            Name: network.name,
            Id: network.name,
            Created: "",
            Scope: network.scope,
            Driver: network.driver,
            EnableIPv6: false,
            IPAM: DockerNetworkInspectIPAMOut(
                Driver: "default",
                Options: nil,
                Config: [DockerNetworkInspectIPAMConfigOut(Subnet: subnet, Gateway: nil)]
            ),
            Internal: false,
            Attachable: false,
            Ingress: false,
            ConfigFrom: DockerEmptyObject(),
            ConfigOnly: false,
            Containers: [:],
            Options: [:],
            Labels: network.labels
        )
        return encode(out)
    }

    private func volumeInspectResponse(name: String) async -> ShimResponse {
        let snapshot = (try? await runtime.snapshot()) ?? RuntimeSnapshot()
        guard let volume = snapshot.volumes.first(where: { $0.name == name }) else {
            return errorResponse(404, "no such volume: \(name)")
        }
        return encode(DockerVolumeInspectOut(
            CreatedAt: "",
            Driver: volume.driver,
            Labels: volume.labels,
            Mountpoint: "/var/lib/dory/volumes/\(volume.name)",
            Name: volume.name,
            Options: volume.options,
            Scope: "local"
        ))
    }

    private func inspectResponse(id: String, includeSize: Bool = false, request: ParsedRequest) async -> ShimResponse {
        if runtime.supportsRawProxy {
            guard let response = await runtime.proxyRequest(
                method: request.method.uppercased(),
                path: request.target,
                headers: Self.proxyRequestHeaders(request),
                body: request.body
            ) else {
                return errorResponse(502, "docker engine unavailable")
            }
            return ShimResponse(status: response.statusCode, headers: Self.proxyHeaders(response), body: response.body)
        }
        let snapshot = (try? await runtime.snapshot()) ?? RuntimeSnapshot()
        guard let container = snapshot.containers.first(where: { Self.containerMatches($0, id: id) }) else {
            return errorResponse(404, "no such container: \(id)")
        }
        let imageSizes = includeSize ? Self.imageSizeIndex(snapshot.images) : [:]
        let imageIdentity = Self.imageIdentity(for: container.image, in: snapshot.images)
        var portMap: [String: [DockerHostBindingOut]] = [:]
        for mapping in ContainerPortDisplay.mappings(container.ports) {
            let key = "\(mapping.containerPort)/\(mapping.proto)"
            if let hostPort = mapping.hostPort {
                portMap[key, default: []].append(DockerHostBindingOut(
                    HostIp: mapping.hostIP ?? "0.0.0.0",
                    HostPort: String(hostPort)
                ))
            } else if mapping.hasHostBinding {
                portMap[key, default: []].append(DockerHostBindingOut(
                    HostIp: mapping.hostIP ?? "0.0.0.0",
                    HostPort: ""
                ))
            } else if portMap[key] == nil {
                portMap[key] = []
            }
        }
        let env = ((try? await runtime.env(containerID: container.id)) ?? [])
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        let exposedPorts = Dictionary(uniqueKeysWithValues: portMap.keys.map { ($0, DockerEmptyObject()) })
        let legacyBinds = container.volumes.filter(DockerCreateBody.isLegacyBind)
        let volumeTargets = Self.unique(container.volumeTargets + container.volumes.filter { !DockerCreateBody.isLegacyBind($0) })
        let declaredVolumes = volumeTargets.isEmpty ? nil : Dictionary(uniqueKeysWithValues: volumeTargets.map { ($0, DockerEmptyObject()) })
        let inspectMounts = legacyBinds.compactMap(DockerInspectMountOut.legacyBind)
            + container.mounts.compactMap(DockerInspectMountOut.mount)
            + volumeTargets.map(DockerInspectMountOut.volumeTarget)
        let inspectNetworks = Self.inspectNetworks(container)
        let networkMode = container.networkMode ?? container.networks.first ?? "default"
        let created = container.createdEpoch.map { Self.iso8601(epoch: $0) } ?? Self.iso8601(epoch: 0)
        let out = DockerInspectOut(
            Id: container.id, Name: "/\(container.name)", Image: imageIdentity, Created: created,
            State: DockerInspectStateOut(
                Running: container.status == .running || container.status == .paused,
                Paused: container.status == .paused,
                Status: Self.containerStateStatus(container.status),
                ExitCode: await runtime.containerExitCode(container.id) ?? 0
            ),
            Config: DockerInspectConfigOut(
                Hostname: container.hostname ?? "",
                Domainname: container.domainname ?? "",
                MacAddress: container.macAddress ?? "",
                User: container.user ?? "",
                AttachStdin: container.attachStdin ?? false,
                AttachStdout: container.attachStdout ?? true,
                AttachStderr: container.attachStderr ?? true,
                Image: container.image,
                Cmd: Self.inspectCommand(container),
                Env: env,
                Entrypoint: container.entrypoint.isEmpty ? nil : container.entrypoint,
                Labels: container.labels,
                ExposedPorts: exposedPorts,
                Volumes: declaredVolumes,
                Healthcheck: container.healthcheck,
                WorkingDir: container.workingDir ?? "",
                Tty: container.tty,
                OpenStdin: container.openStdin,
                StdinOnce: container.stdinOnce,
                NetworkDisabled: container.networkDisabled,
                StopSignal: container.stopSignal,
                StopTimeout: container.stopTimeout,
                Shell: container.shell.isEmpty ? nil : container.shell
            ),
            NetworkSettings: DockerInspectNetOut(
                IPAddress: container.ipAddress == "—" ? "" : container.ipAddress,
                Ports: portMap,
                Networks: inspectNetworks
            ),
            HostConfig: DockerHostConfigOut(
                container: container,
                networkMode: networkMode,
                portBindings: portMap,
                binds: legacyBinds,
                mounts: container.mounts
            ),
            Mounts: inspectMounts,
            SizeRw: includeSize ? 0 : nil,
            SizeRootFs: includeSize ? (imageSizes[imageIdentity] ?? imageSizes[container.image] ?? 0) : nil
        )
        return encode(out)
    }

    private func logsResponse(id: String, request: ParsedRequest) async -> ShimResponse {
        let timestamps = Self.queryBool("timestamps", in: request.query, default: false)
        let container: Container
        switch await resolveContainer(id: id) {
        case .found(let resolved): container = resolved
        case .failure(let response): return response
        }
        guard Self.includesAnyLogStream(request.query) else {
            return ShimResponse(status: 200, headers: [(name: "Content-Type", value: "application/vnd.docker.raw-stream")], body: Data())
        }
        let logWindow = Self.logTimeWindow(request.query)
        let logStreams = Self.logStreams(request.query)
        let historical = Self.tail(
            Self.filterLogs(
                (try? await runtime.logs(containerID: container.id)) ?? [],
                window: logWindow,
                streams: logStreams
            ),
            request.query["tail"]
        )
        if Self.queryBool("follow", in: request.query, default: false) {
            let runtime = self.runtime
            let containerID = container.id
            return ShimResponse.streaming(contentType: "application/vnd.docker.raw-stream") { writer in
                for line in historical {
                    guard writer.write(Self.logFrame(line, timestamps: timestamps)) else { return }
                }
                for await line in runtime.streamLogs(containerID: containerID)
                    where Self.logLineMatches(line, window: logWindow, streams: logStreams) {
                    guard writer.write(Self.logFrame(line, timestamps: timestamps)) else { return }
                }
            }
        }
        var body = Data()
        for line in historical {
            body.append(Self.logFrame(line, timestamps: timestamps))
        }
        return ShimResponse(status: 200, headers: [(name: "Content-Type", value: "application/vnd.docker.raw-stream")], body: body)
    }

    private func statsResponse(id: String, stream: Bool) async -> ShimResponse {
        guard let first = await statsPayload(id: id) else { return errorResponse(404, "no such container: \(id)") }
        if !stream {
            return encode(first)
        }
        let runtime = self.runtime
        return ShimResponse.streaming(contentType: "application/json") { writer in
            var current: DockerContainerStatsOut? = first
            for _ in 0..<3600 {
                guard let payload = current,
                      let data = try? JSONEncoder().encode(payload),
                      writer.write(data + Data("\n".utf8)) else { return }
                try? await Task.sleep(for: .seconds(1))
                current = await DockerShim.statsPayload(runtime: runtime, id: id)
            }
        }
    }

    private func statsPayload(id: String) async -> DockerContainerStatsOut? {
        await Self.statsPayload(runtime: runtime, id: id)
    }

    private static func statsPayload(runtime: any ContainerRuntime, id: String) async -> DockerContainerStatsOut? {
        let snapshot = (try? await runtime.snapshot()) ?? RuntimeSnapshot()
        guard let container = snapshot.containers.first(where: { Self.containerMatches($0, id: id) }) else {
            return nil
        }
        let cpu = await runtime.sampleCPU(containerID: container.id) ?? container.cpuPercent
        let limit = parseByteDisplay(container.memoryLimitDisplay)
            ?? (container.memoryBytes > 0 && container.memoryFraction > 0 ? Int64(Double(container.memoryBytes) / container.memoryFraction) : Int64(ProcessInfo.processInfo.physicalMemory))
        return DockerContainerStatsOut.make(
            container: container,
            cpuPercent: cpu,
            memoryLimit: limit,
            read: iso8601(epoch: Int(Date().timeIntervalSince1970)),
            cpus: ProcessInfo.processInfo.processorCount
        )
    }

    private func lifecycle(id: String, action: String, request: ParsedRequest) async -> ShimResponse {
        let container: Container
        switch await resolveContainer(id: id) {
        case .found(let resolved): container = resolved
        case .failure(let response): return response
        }
        do {
            switch action {
            case "start": try await runtime.start(containerID: container.id)
            case "stop": try await runtime.stop(containerID: container.id)
            case "kill": try await runtime.kill(containerID: container.id, signal: request.query["signal"])
            case "restart": try await runtime.restart(containerID: container.id)
            case "pause": try await runtime.pause(containerID: container.id)
            case "unpause": try await runtime.unpause(containerID: container.id)
            default: return errorResponse(404, "unknown action: \(action)")
            }
            return ShimResponse.empty(status: 204)
        } catch { return runtimeErrorResponse(error) }
    }

    private func remove(id: String) async -> ShimResponse {
        let container: Container
        switch await resolveContainer(id: id) {
        case .found(let resolved): container = resolved
        case .failure(let response): return response
        }
        do { try await runtime.remove(containerID: container.id); return ShimResponse.empty(status: 204) }
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
        let container: Container
        switch await resolveContainer(id: containerID) {
        case .found(let resolved): container = resolved
        case .failure(let response): return response
        }
        let id = execStore.register(container: container.id, cmd: body.Cmd ?? [])
        let payload = (try? JSONEncoder().encode(DockerExecCreatedOut(Id: id))) ?? Data()
        return ShimResponse.json(payload, status: 201)
    }

    private func attachContainer(id: String, request: ParsedRequest) async -> ShimResponse {
        if runtime.supportsRawProxy {
            let runtime = self.runtime
            return ShimResponse.hijacked { fd, initial in runtime.proxyHijack(requestData: initial, clientFD: fd) }
        }
        let container: Container
        switch await resolveContainer(id: id) {
        case .found(let resolved): container = resolved
        case .failure(let response): return response
        }
        let includeOutput = Self.includesAnyLogStream(request.query)
        let includeHistory = includeOutput && Self.queryBool("logs", in: request.query, default: false)
        let stream = includeOutput && Self.queryBool("stream", in: request.query, default: true)
        let timestamps = Self.queryBool("timestamps", in: request.query, default: false)
        let logWindow = Self.logTimeWindow(request.query)
        let logStreams = Self.logStreams(request.query)
        let historical = includeHistory
            ? Self.tail(
                Self.filterLogs(
                    (try? await runtime.logs(containerID: container.id)) ?? [],
                    window: logWindow,
                    streams: logStreams
                ),
                request.query["tail"]
            )
            : []
        let runtime = self.runtime
        let containerID = container.id
        let liveLogs = stream ? runtime.streamLogs(containerID: containerID) : nil
        return ShimResponse.hijacked { fd, _ in
            Task.detached {
                defer {
                    shutdown(fd, SHUT_RDWR)
                    close(fd)
                }
                guard (try? UnixSocketHTTP.writeAll(fd, Self.rawStreamUpgradeHead())) != nil else { return }
                for line in historical {
                    guard (try? UnixSocketHTTP.writeAll(fd, Self.logFrame(line, timestamps: timestamps))) != nil else { return }
                }
                guard let liveLogs else { return }
                for await line in liveLogs
                    where Self.logLineMatches(line, window: logWindow, streams: logStreams) {
                    guard (try? UnixSocketHTTP.writeAll(fd, Self.logFrame(line, timestamps: timestamps))) != nil else { return }
                }
            }
        }
    }

    /// Headers for a proxied response: the body has already been de-chunked and will get a fresh
    /// Content-Length, so the upstream's transfer-encoding/content-length must not be forwarded.
    static func proxyHeaders(_ response: HTTPResponse) -> [(name: String, value: String)] {
        response.headers
            .filter { $0.key != "transfer-encoding" && $0.key != "content-length" }
            .map { (name: $0.key, value: $0.value) }
    }

    /// Headers for a proxied request whose body may have been rewritten. Hop-by-hop and body length
    /// headers are regenerated by the transport.
    private static func proxyRequestHeaders(_ request: ParsedRequest) -> [(name: String, value: String)] {
        request.headers.compactMap { key, value in
            if key == "connection" || key == "content-length" || key == "host" || key == "transfer-encoding" {
                return nil
            }
            return (name: key, value: value)
        }
    }

    private func execStart(execID: String) -> ShimResponse {
        let runtime = self.runtime
        let store = self.execStore
        if runtime.supportsRawProxy {
            return ShimResponse.hijacked { fd, initial in runtime.proxyHijack(requestData: initial, clientFD: fd) }
        }
        // docker exec hijacks the connection (Upgrade: tcp): write the raw 101 upgrade head + stdcopy
        // frames straight to the fd. Must NOT go through the chunked-transfer stream path (a 101 with
        // Transfer-Encoding: chunked corrupts the hijacked byte stream) — mirrors the attach path.
        return ShimResponse.hijacked { fd, _ in
            Task.detached {
                defer {
                    shutdown(fd, SHUT_RDWR)
                    close(fd)
                }
                guard (try? UnixSocketHTTP.writeAll(fd, Self.rawStreamUpgradeHead())) != nil else { return }
                guard let entry = store.command(for: execID) else { return }
                let result = (try? await runtime.exec(containerID: entry.container, command: entry.cmd)) ?? ExecResult(exitCode: 1, output: "")
                store.setResult(execID, exitCode: result.exitCode)
                let payload = Data(result.output.utf8)
                let frame = Self.stdcopyFrame(stream: 1, payload: payload)
                _ = try? UnixSocketHTTP.writeAll(fd, frame)
            }
        }
    }

    private func execInspect(execID: String, request: ParsedRequest) async -> ShimResponse {
        if runtime.supportsRawProxy {
            guard let response = await runtime.proxyRequest(method: "GET", path: request.target, headers: [], body: Data()) else {
                return errorResponse(500, "exec inspect proxy failed")
            }
            return ShimResponse(status: response.statusCode, headers: Self.proxyHeaders(response), body: response.body)
        }
        let completed = execStore.result(for: execID)
        if completed != nil { execStore.finish(execID) }
        let payload = (try? JSONEncoder().encode(DockerExecInspectOut(ExitCode: completed ?? 0, Running: false))) ?? Data()
        return ShimResponse.json(payload)
    }

    private func archive(id: String, method: String, request: ParsedRequest) async -> ShimResponse {
        let container: Container
        switch await resolveContainer(id: id) {
        case .found(let resolved): container = resolved
        case .failure(let response): return response
        }
        let path = request.query["path"] ?? "/"
        switch method {
        case "GET":
            guard let tar = await runtime.copyOut(containerID: container.id, path: path) else {
                return errorResponse(404, "could not read \(path)")
            }
            return ShimResponse(status: 200, headers: [
                (name: "Content-Type", value: "application/x-tar"),
                (name: "X-Docker-Container-Path-Stat", value: Self.archivePathStatHeader(path: path, size: tar.count)),
            ], body: tar)
        case "PUT":
            let ok = await runtime.copyIn(containerID: container.id, path: path, archive: request.body)
            return ok ? ShimResponse.empty(status: 200) : errorResponse(500, "could not write \(path)")
        case "HEAD":
            guard let tar = await runtime.copyOut(containerID: container.id, path: path) else {
                return errorResponse(404, "could not read \(path)")
            }
            return ShimResponse(status: 200, headers: [
                (name: "X-Docker-Container-Path-Stat", value: Self.archivePathStatHeader(path: path, size: tar.count)),
            ], body: Data())
        default:
            return errorResponse(405, "method not allowed")
        }
    }

    private func exportContainer(id: String) async -> ShimResponse {
        let container: Container
        switch await resolveContainer(id: id) {
        case .found(let resolved): container = resolved
        case .failure(let response): return response
        }
        guard let tar = await runtime.copyOut(containerID: container.id, path: "/") else {
            return errorResponse(404, "could not export container \(id)")
        }
        return ShimResponse(status: 200, headers: [(name: "Content-Type", value: "application/x-tar")], body: tar)
    }

    private func buildResponse(_ request: ParsedRequest) -> ShimResponse {
        let runtime = self.runtime
        let query = String(request.target.split(separator: "?", maxSplits: 1).dropFirst().first ?? "")
        let context = request.body
        let registryHeaders: [(name: String, value: String)] = [
            (lower: "x-registry-config", canonical: "X-Registry-Config"),
            (lower: "x-registry-auth", canonical: "X-Registry-Auth"),
        ].compactMap { pair in request.headers[pair.lower].map { (name: pair.canonical, value: $0) } }
        return ShimResponse.streaming(contentType: "application/json") { writer in
            for await chunk in runtime.build(contextTar: context, query: query, registryHeaders: registryHeaders) {
                if !writer.write(chunk) { return }
            }
        }
    }

    private func eventsResponse(_ request: ParsedRequest) -> ShimResponse {
        let runtime = self.runtime
        let filters = DockerListFilters.parse(request.query["filters"])
        let until = Self.eventDeadline(request.query["until"])
        return ShimResponse.streaming(contentType: "application/json") { writer in
            var previous = ((try? await runtime.snapshot())?.containers) ?? []
            let encoder = JSONEncoder()
            while !Task.isCancelled {
                if let until, Date() >= until { return }
                let delay = until.map { max(0, min(1, $0.timeIntervalSinceNow)) } ?? 1
                if delay > 0 {
                    try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
                }
                if let until, Date() >= until { return }
                guard let current = try? await runtime.snapshot().containers else { continue }
                let events = EventSynthesizer.diff(previous: previous, current: current)
                previous = current
                for event in events where Self.eventMatches(event, filters: filters) {
                    let now = Date().timeIntervalSince1970
                    let out = DockerEventOut(
                        eventType: "container", Action: event.action.rawValue,
                        Actor: DockerEventActor(ID: event.containerID, Attributes: event.attributes),
                        time: Int(now), timeNano: Int64(now * 1_000_000_000)
                    )
                    guard let data = try? encoder.encode(out), writer.write(data + Data("\n".utf8)) else { return }
                }
            }
        }
    }

    nonisolated static func eventMatches(_ event: DoryEvent, filters: [String: [String]]) -> Bool {
        for (key, values) in filters where !values.isEmpty {
            switch key {
            case "type":
                guard values.contains("container") else { return false }
            case "event", "action":
                guard values.contains(event.action.rawValue) else { return false }
            case "container":
                guard values.contains(where: { matchesEventContainer($0, event: event) }) else { return false }
            case "image":
                guard values.contains(where: { $0 == event.image || event.image.hasPrefix("\($0):") }) else { return false }
            case "label":
                guard values.allSatisfy({ matchesEventLabel($0, attributes: event.attributes) }) else { return false }
            default:
                continue
            }
        }
        return true
    }

    nonisolated static func eventDeadline(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let seconds = TimeInterval(raw) {
            return Date(timeIntervalSince1970: seconds)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    private nonisolated static func matchesEventContainer(_ selector: String, event: DoryEvent) -> Bool {
        guard !selector.isEmpty else { return false }
        let name = selector.hasPrefix("/") ? String(selector.dropFirst()) : selector
        return event.containerID == selector
            || event.containerID.hasPrefix(selector)
            || event.name == name
            || "/\(event.name)" == selector
    }

    private nonisolated static func matchesEventLabel(_ selector: String, attributes: [String: String]) -> Bool {
        guard let eq = selector.firstIndex(of: "=") else { return attributes[selector] != nil }
        let key = String(selector[selector.startIndex..<eq])
        let value = String(selector[selector.index(after: eq)...])
        return attributes[key] == value
    }

    private func versionResponse() async -> ShimResponse {
        let snapshot = try? await runtime.snapshot()
        let out = DockerVersionOut(
            Version: snapshot?.engineVersion ?? "dory",
            ApiVersion: apiVersion, MinAPIVersion: "1.24",
            Os: "linux", Arch: Self.hostDockerArch(), KernelVersion: "dory",
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
            OSType: "linux", Architecture: Self.hostKernelArch(), Driver: "dory"
        )
        return encode(out)
    }

    private func containersResponse(
        request: ParsedRequest,
        all: Bool,
        filters: [String: [String]],
        includeSize: Bool = false,
        limit: Int? = nil
    ) async -> ShimResponse {
        if runtime.supportsRawProxy {
            if let response = await runtime.proxyRequest(
                method: "GET",
                path: request.target,
                headers: Self.proxyRequestHeaders(request),
                body: Data()
            ) {
                return ShimResponse(status: response.statusCode, headers: Self.proxyHeaders(response), body: response.body)
            }
            return errorResponse(502, "docker engine unavailable")
        }
        let snapshot = (try? await runtime.snapshot()) ?? RuntimeSnapshot()
        let imageSizes = Self.imageSizeIndex(snapshot.images)
        let filtered = snapshot.containers
            .filter { DockerListFilters.matches($0, filters: filters, containers: snapshot.containers) }
        let limited = Self.applyContainerLimit(limit, to: filtered)
        let includeAllStates = all || (limit ?? 0) > 0
        let containers = limited
            .compactMap {
                let imageIdentity = Self.imageIdentity(for: $0.image, in: snapshot.images)
                return ShimContainerMapping.summary(
                    $0,
                    all: includeAllStates,
                    imageID: imageIdentity,
                    sizeRw: includeSize ? 0 : nil,
                    sizeRootFs: includeSize ? (imageSizes[imageIdentity] ?? imageSizes[$0.image] ?? 0) : nil
                )
            }
        return encode(containers)
    }

    private func imagesResponse(filters: [String: [String]]) async -> ShimResponse {
        let snapshot = (try? await runtime.snapshot()) ?? RuntimeSnapshot()
        let images = snapshot.images
            .filter { DockerListFilters.matches($0, filters: filters, images: snapshot.images) }
            .map { image in
                DockerImageOut(
                    Id: Self.imageDigest(image),
                    RepoTags: [Self.imageReference(image)],
                    Containers: image.usedByCount,
                    Created: image.createdEpoch,
                    Size: image.sizeBytes,
                    Labels: image.labels
                )
            }
        return encode(images)
    }

    private func imageSearchResponse(_ request: ParsedRequest) async -> ShimResponse {
        guard let rawTerm = request.query["term"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawTerm.isEmpty else {
            return errorResponse(400, "term is required")
        }
        let term = rawTerm.lowercased()
        let filters = DockerListFilters.parse(request.query["filters"])
        let limit = request.query["limit"].flatMap(Int.init)
        let snapshot = (try? await runtime.snapshot()) ?? RuntimeSnapshot()
        var seen = Set<String>()
        var matches = snapshot.images
            .filter { image in
                let reference = Self.imageReference(image).lowercased()
                return image.repository.lowercased().contains(term)
                    || image.tag.lowercased().contains(term)
                    || reference.contains(term)
            }
            .filter { seen.insert($0.repository).inserted }
            .map { image in
                DockerImageSearchOut(
                    description: "Local image \(Self.imageReference(image))",
                    is_official: !image.repository.contains("/"),
                    is_automated: false,
                    name: image.repository,
                    star_count: 0
                )
            }
            .sorted { $0.name < $1.name }
        if runtime.kind != .mock {
            let hits = (try? await registrySearch.search(term: rawTerm, limit: limit)) ?? []
            for hit in hits where seen.insert(hit.name).inserted {
                matches.append(hit)
            }
        }
        let filtered = matches.filter { Self.matchesImageSearchFilters($0, filters: filters) }
        let limited = limit.map { Array(filtered.prefix(max(0, $0))) } ?? filtered
        return encode(limited)
    }

    private func systemDiskUsageResponse() async -> ShimResponse {
        let snapshot = (try? await runtime.snapshot()) ?? RuntimeSnapshot()
        let images = snapshot.images.map { image in
            DockerSystemImageOut(
                Id: Self.imageDigest(image),
                ParentId: "",
                RepoTags: [Self.imageReference(image)],
                RepoDigests: [],
                Created: image.createdEpoch,
                Size: image.sizeBytes,
                SharedSize: 0,
                VirtualSize: image.sizeBytes,
                Labels: image.labels,
                Containers: image.usedByCount
            )
        }
        let imageSizes = Self.imageSizeIndex(snapshot.images)
        let containers = snapshot.containers.compactMap {
            let imageIdentity = Self.imageIdentity(for: $0.image, in: snapshot.images)
            return ShimContainerMapping.summary(
                $0,
                all: true,
                imageID: imageIdentity,
                sizeRw: 0,
                sizeRootFs: imageSizes[imageIdentity] ?? imageSizes[$0.image] ?? 0
            )
        }
        let volumes = snapshot.volumes.map { volume in
            let size = Self.parseByteDisplay(volume.size) ?? 0
            return DockerSystemVolumeOut(
                Name: volume.name,
                Driver: volume.driver,
                Mountpoint: "/var/lib/dory/volumes/\(volume.name)",
                CreatedAt: "",
                Labels: volume.labels,
                Scope: "local",
                Options: volume.options,
                UsageData: DockerSystemVolumeUsageOut(Size: size, RefCount: volume.usedBy == "—" ? 0 : 1)
            )
        }
        return encode(DockerSystemDiskUsageOut(
            LayersSize: images.reduce(0) { $0 + $1.Size },
            Images: images,
            Containers: containers,
            Volumes: volumes,
            BuildCache: []
        ))
    }

    private func rename(id: String, request: ParsedRequest) async -> ShimResponse {
        guard let name = request.query["name"]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return errorResponse(400, "name is required")
        }
        let container: Container
        switch await resolveContainer(id: id) {
        case .found(let resolved): container = resolved
        case .failure(let response): return response
        }
        do {
            try await runtime.rename(containerID: container.id, name: name)
            return ShimResponse.empty(status: 204)
        } catch {
            return runtimeErrorResponse(error)
        }
    }

    private func updateContainer(id: String, request: ParsedRequest) async -> ShimResponse {
        guard let body = try? JSONDecoder().decode(DockerContainerUpdateRequest.self, from: request.body) else {
            return errorResponse(400, "invalid update request body")
        }
        let container: Container
        switch await resolveContainer(id: id) {
        case .found(let resolved): container = resolved
        case .failure(let response): return response
        }
        do {
            try await runtime.update(containerID: container.id, resources: body.resources)
            return encode(DockerContainerUpdateOut(Warnings: []))
        } catch {
            return runtimeErrorResponse(error)
        }
    }

    private func resizeContainer(id: String, request: ParsedRequest) async -> ShimResponse {
        let container: Container
        switch await resolveContainer(id: id) {
        case .found(let resolved): container = resolved
        case .failure(let response): return response
        }
        do {
            try await runtime.resize(
                containerID: container.id,
                height: Self.queryInt("h", "height", in: request),
                width: Self.queryInt("w", "width", in: request)
            )
            return ShimResponse.empty(status: 200)
        } catch {
            return runtimeErrorResponse(error)
        }
    }

    private func parsePorts(_ display: String) -> [DockerPortOut] {
        ShimContainerMapping.ports(display)
    }

    private func encode<T: Encodable>(_ value: T, status: Int = 200) -> ShimResponse {
        guard let data = try? JSONEncoder().encode(value) else { return errorResponse(500, "encode failed") }
        return ShimResponse.json(data, status: status)
    }

    private func errorResponse(_ status: Int, _ message: String) -> ShimResponse {
        let data = (try? JSONEncoder().encode(DockerErrorOut(message: message))) ?? Data()
        return ShimResponse.json(data, status: status)
    }

    private func resolveContainer(id: String) async -> ContainerResolution {
        do {
            let snapshot = try await runtime.snapshot()
            guard let container = snapshot.containers.first(where: { Self.containerMatches($0, id: id) }) else {
                return .failure(errorResponse(404, "no such container: \(id)"))
            }
            return .found(container)
        } catch {
            return .failure(runtimeErrorResponse(error, fallbackStatus: 500))
        }
    }

    private func runtimeErrorResponse(_ error: Error, fallbackStatus: Int = 409) -> ShimResponse {
        if let feature = error as? RuntimeFeatureError {
            switch feature {
            case .unsupported(let message):
                return errorResponse(501, message)
            }
        }
        if let http = error as? HTTPError {
            switch http {
            case .status(let code, let message):
                return errorResponse(code, message)
            default:
                break
            }
        }
        return errorResponse(fallbackStatus, "\(error)")
    }

    private func createNetworkErrorResponse(_ error: Error) -> ShimResponse {
        let message = Self.runtimeErrorMessage(error)
        if message.localizedCaseInsensitiveContains("already exists") {
            return errorResponse(409, message)
        }
        return runtimeErrorResponse(error, fallbackStatus: 500)
    }

    private func removeNetworkErrorResponse(_ error: Error, name: String) -> ShimResponse {
        let message = Self.runtimeErrorMessage(error)
        if message.localizedCaseInsensitiveContains("not found")
            || message.localizedCaseInsensitiveContains("no such network")
            || message.localizedCaseInsensitiveContains("failed to delete one or more networks") {
            return errorResponse(404, "network \(name) not found")
        }
        return runtimeErrorResponse(error, fallbackStatus: 409)
    }

    private func removeVolumeErrorResponse(_ error: Error, name: String) -> ShimResponse {
        let message = Self.runtimeErrorMessage(error)
        if message.localizedCaseInsensitiveContains("not found")
            || message.localizedCaseInsensitiveContains("no such volume") {
            return errorResponse(404, "no such volume: \(name)")
        }
        return runtimeErrorResponse(error, fallbackStatus: 409)
    }

    private func removeImageErrorResponse(_ error: Error, id: String) -> ShimResponse {
        let message = Self.runtimeErrorMessage(error)
        if message.localizedCaseInsensitiveContains("not found")
            || message.localizedCaseInsensitiveContains("no such image") {
            return errorResponse(404, "no such image: \(id)")
        }
        return runtimeErrorResponse(error, fallbackStatus: 409)
    }

    private static func runtimeErrorMessage(_ error: Error) -> String {
        if case ShellError.nonZeroExit(_, let output) = error {
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if case HTTPError.status(_, let message) = error {
            return message.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "\(error)"
    }

    static func normalize(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count >= 2, parts[1].hasPrefix("v"), parts[1].dropFirst().first?.isNumber == true {
            return "/" + parts.dropFirst(2).joined(separator: "/")
        }
        return path
    }

    static func resourceName(after prefix: String, in path: String) -> String? {
        guard path.hasPrefix(prefix) else { return nil }
        let raw = String(path.dropFirst(prefix.count))
        guard !raw.isEmpty else { return nil }
        return raw.removingPercentEncoding ?? raw
    }

    static func imageInspectName(in path: String) -> String? {
        guard let raw = resourceName(after: "/images/", in: path), raw.hasSuffix("/json") else { return nil }
        let name = String(raw.dropLast("/json".count))
        return name.isEmpty ? nil : name
    }

    static func imageHistoryName(in path: String) -> String? {
        guard let raw = resourceName(after: "/images/", in: path), raw.hasSuffix("/history") else { return nil }
        let name = String(raw.dropLast("/history".count))
        return name.isEmpty ? nil : name
    }

    static func imageSaveName(in path: String) -> String? {
        guard let raw = resourceName(after: "/images/", in: path), raw.hasSuffix("/get") else { return nil }
        let name = String(raw.dropLast("/get".count))
        return name.isEmpty ? nil : name
    }

    static func imagePushName(in path: String) -> String? {
        guard let raw = resourceName(after: "/images/", in: path), raw.hasSuffix("/push") else { return nil }
        let name = String(raw.dropLast("/push".count))
        return name.isEmpty ? nil : name
    }

    static func imageTagName(in path: String) -> String? {
        guard let raw = resourceName(after: "/images/", in: path), raw.hasSuffix("/tag") else { return nil }
        let name = String(raw.dropLast("/tag".count))
        return name.isEmpty ? nil : name
    }

    static func imagePushReference(name: String, tag rawTag: String?) -> String {
        guard let tag = rawTag?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty else {
            return name
        }
        return "\(DockerRegistry.splitImageRef(name).repo):\(tag)"
    }

    static func imageSaveReferences(from raw: String?) -> [String] {
        imageSaveReferences(from: raw.map { [$0] } ?? [])
    }

    static func imageSaveReferences(from rawValues: [String]) -> [String] {
        rawValues.flatMap { raw -> [String] in
            guard !raw.isEmpty else { return [] }
            if let data = raw.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String].self, from: data) {
                return decoded.filter { !$0.isEmpty }
            }
            return raw.split(separator: ",").map(String.init).filter { !$0.isEmpty }
        }
    }

    private static func queryInt(_ keys: String..., in request: ParsedRequest) -> Int? {
        for key in keys {
            if let raw = request.query[key], let value = Int(raw) { return value }
        }
        return nil
    }

    private static func queryBool(_ key: String, in query: [String: String], default fallback: Bool) -> Bool {
        guard let raw = query[key]?.lowercased() else { return fallback }
        return raw == "1" || raw == "true" || raw == "yes"
    }

    private static func includesAnyLogStream(_ query: [String: String]) -> Bool {
        let streams = logStreams(query)
        return streams.stdout || streams.stderr
    }

    private static func tail(_ lines: [LogLine], _ raw: String?) -> [LogLine] {
        guard let raw, raw != "all" else { return lines }
        guard let count = Int(raw) else { return lines }
        if count <= 0 { return [] }
        return Array(lines.suffix(count))
    }

    private typealias LogTimeWindow = (since: Double?, until: Double?)
    private typealias LogStreamSelection = (stdout: Bool, stderr: Bool)

    private static func logStreams(_ query: [String: String]) -> LogStreamSelection {
        (
            stdout: queryBool("stdout", in: query, default: true),
            stderr: queryBool("stderr", in: query, default: true)
        )
    }

    nonisolated private static func logTimeWindow(_ query: [String: String]) -> LogTimeWindow {
        (
            since: query["since"].flatMap(logSecondsOfDay),
            until: query["until"].flatMap(logSecondsOfDay)
        )
    }

    nonisolated private static func filterLogs(
        _ lines: [LogLine],
        window: LogTimeWindow,
        streams: LogStreamSelection
    ) -> [LogLine] {
        guard window.since != nil || window.until != nil || !streams.stdout || !streams.stderr else {
            return lines
        }
        return lines.filter { logLineMatches($0, window: window, streams: streams) }
    }

    nonisolated private static func logLineMatches(
        _ line: LogLine,
        window: LogTimeWindow,
        streams: LogStreamSelection
    ) -> Bool {
        guard logStreamMatches(line, streams: streams) else { return false }
        guard let seconds = logSecondsOfDay(line.timestamp) else { return true }
        if let since = window.since, seconds < since { return false }
        if let until = window.until, seconds > until { return false }
        return true
    }

    nonisolated private static func logStreamMatches(_ line: LogLine, streams: LogStreamSelection) -> Bool {
        switch logStreamType(line) {
        case 1: return streams.stdout
        case 2: return streams.stderr
        default: return true
        }
    }

    nonisolated private static func logSecondsOfDay(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains(":"), let epoch = Double(trimmed) {
            return utcSecondsOfDay(from: Date(timeIntervalSince1970: epoch))
        }
        let time = isoTimeComponent(trimmed) ?? trimmed
        let parts = time.split(separator: ":", maxSplits: 2)
        guard parts.count == 3,
              let hours = Int(parts[0]),
              let minutes = Int(parts[1]),
              let seconds = Double(parts[2].replacingOccurrences(of: ",", with: ".")),
              (0..<24).contains(hours),
              (0..<60).contains(minutes),
              seconds >= 0, seconds < 60 else {
            return nil
        }
        return Double(hours * 3600 + minutes * 60) + seconds
    }

    nonisolated private static func isoTimeComponent(_ raw: String) -> String? {
        guard let tIndex = raw.firstIndex(of: "T") else { return nil }
        let afterT = Array(raw[raw.index(after: tIndex)...])
        guard afterT.count >= 8 else { return nil }
        let end = afterT.indices.first { index in
            index >= 8 && (afterT[index] == "Z" || afterT[index] == "+" || afterT[index] == "-")
        } ?? afterT.endIndex
        return String(afterT[..<end])
    }

    nonisolated private static func utcSecondsOfDay(from date: Date) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let components = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        let second = components.second ?? 0
        let nanosecond = components.nanosecond ?? 0
        let wholeSeconds = hour * 3600 + minute * 60 + second
        return Double(wholeSeconds) + Double(nanosecond) / 1_000_000_000
    }

    private static func archivePathStatHeader(path: String, size: Int) -> String {
        let name = (path as NSString).lastPathComponent
        let stat = (try? JSONEncoder().encode(DockerPathStat(name: name, size: size, mode: 0o644)))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return Data(stat.utf8).base64EncodedString()
    }

    nonisolated static func stdcopyFrame(stream: UInt8, payload: Data) -> Data {
        let length = UInt32(payload.count)
        var frame = Data([
            stream, 0, 0, 0,
            UInt8(length >> 24 & 0xff),
            UInt8(length >> 16 & 0xff),
            UInt8(length >> 8 & 0xff),
            UInt8(length & 0xff),
        ])
        frame.append(payload)
        return frame
    }

    nonisolated private static func logFrame(_ line: LogLine, timestamps: Bool) -> Data {
        let prefix = timestamps && !line.timestamp.isEmpty ? "\(line.timestamp) " : ""
        let payload = Data("\(prefix)\(line.message)\n".utf8)
        return stdcopyFrame(stream: logStreamType(line), payload: payload)
    }

    nonisolated private static func logStreamType(_ line: LogLine) -> UInt8 {
        line.level == .error ? 2 : 1
    }

    nonisolated private static func rawStreamUpgradeHead() -> Data {
        let head =
            "HTTP/1.1 101 \(HTTPCodec.reasonPhrase(101))\r\n" +
            "Content-Type: application/vnd.docker.raw-stream\r\n" +
            "Connection: Upgrade\r\n" +
            "Upgrade: tcp\r\n" +
            "\r\n"
        return Data(head.utf8)
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func imageReference(_ image: DockerImage) -> String {
        image.tag.isEmpty ? image.repository : "\(image.repository):\(image.tag)"
    }

    private static func imageDigest(_ image: DockerImage) -> String {
        image.imageID.hasPrefix("sha256:") ? image.imageID : "sha256:\(image.imageID)"
    }

    private static func imageIdentity(for reference: String, in images: [DockerImage]) -> String {
        guard !reference.isEmpty else { return reference }
        guard let image = images.first(where: { imageMatches($0, id: reference) }) else { return reference }
        return imageDigest(image)
    }

    private static func imageSizeIndex(_ images: [DockerImage]) -> [String: Int64] {
        var index: [String: Int64] = [:]
        for image in images {
            let references = [
                image.repository,
                imageReference(image),
                image.imageID,
                imageDigest(image),
            ]
            for reference in references where !reference.isEmpty {
                index[reference] = image.sizeBytes
            }
        }
        return index
    }

    private static func applyContainerLimit(_ limit: Int?, to containers: [Container]) -> [Container] {
        guard let limit, limit > 0 else { return containers }
        return Array(containers.sorted {
            ($0.createdEpoch ?? 0) > ($1.createdEpoch ?? 0)
        }.prefix(limit))
    }

    private static func inspectNetworks(_ container: Container) -> [String: DockerEndpointSettings] {
        Dictionary(uniqueKeysWithValues: container.networks.map { network in
            var endpoint = container.networkEndpointSettings[network] ?? DockerEndpointSettings()
            if endpoint.IPAddress?.isEmpty != false, container.ipAddress != "—" {
                endpoint.IPAddress = container.ipAddress
            }
            return (network, endpoint)
        })
    }

    private static func inspectCommand(_ container: Container) -> [String]? {
        if !container.commandArgs.isEmpty { return container.commandArgs }
        return container.command.isEmpty || container.command == "—" ? nil : [container.command]
    }

    private static func imageMatches(_ image: DockerImage, id: String) -> Bool {
        let normalizedID = image.imageID.replacingOccurrences(of: "sha256:", with: "")
        let normalizedQuery = id.replacingOccurrences(of: "sha256:", with: "")
        return imageReference(image) == id
            || (image.repository == id && image.tag == "latest")
            || image.imageID == id
            || normalizedID == normalizedQuery
            || normalizedID.hasPrefix(normalizedQuery)
    }

    private static func matchesImageSearchFilters(_ image: DockerImageSearchOut, filters: [String: [String]]) -> Bool {
        for (key, values) in filters where !values.isEmpty {
            switch key {
            case "is-official":
                guard values.contains(String(image.is_official)) else { return false }
            case "is-automated":
                guard values.contains(String(image.is_automated)) else { return false }
            case "stars":
                let minimum = values.compactMap(Int.init).max() ?? 0
                guard image.star_count >= minimum else { return false }
            default:
                continue
            }
        }
        return true
    }

    private static func containerMatches(_ container: Container, id: String) -> Bool {
        container.id == id || container.name == id || container.id.hasPrefix(id)
    }

    private static func containerStateStatus(_ status: RunState) -> String {
        switch status {
        case .running: "running"
        case .paused: "paused"
        case .stopped: "exited"
        }
    }

    private static func defaultDockerArchitecture() -> String {
        hostDockerArch()
    }

    static func hostDockerArch() -> String {
        #if arch(arm64)
        "arm64"
        #else
        "amd64"
        #endif
    }

    static func hostKernelArch() -> String {
        #if arch(arm64)
        "aarch64"
        #else
        "x86_64"
        #endif
    }

    static func parseByteDisplay(_ display: String) -> Int64? {
        let parts = display.split(separator: " ")
        guard parts.count == 2, let value = Double(parts[0]) else { return nil }
        let multiplier: Double
        switch parts[1].lowercased() {
        case "b": multiplier = 1
        case "kb", "kib": multiplier = 1024
        case "mb", "mib": multiplier = 1024 * 1024
        case "gb", "gib": multiplier = 1024 * 1024 * 1024
        case "tb", "tib": multiplier = 1024 * 1024 * 1024 * 1024
        default: return nil
        }
        return Int64(value * multiplier)
    }

    static func iso8601(epoch: Int) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }
}
