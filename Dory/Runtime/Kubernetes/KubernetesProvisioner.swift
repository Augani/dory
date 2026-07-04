import Foundation

/// One-click Kubernetes: runs a k3s server as a container inside Dory's shared VM (the k3d pattern),
/// publishes the API on :6443 (auto-forwarded to `localhost` by the port forwarder), and writes a
/// kubeconfig the host `kubectl` picks up — mirroring OrbStack's built-in cluster. NOTE: k3s brings
/// its own embedded containerd image store, SEPARATE from the shared engine's dockerd store. A
/// locally-built Docker image is therefore NOT automatically visible to Pods — push it to a registry
/// the cluster can reach, or import it into k3s's containerd (`k8s.io` namespace). Auto image-sync is
/// a tracked follow-up.
///
/// Two optional host-side config files extend the cluster without GUI plumbing (and are shared
/// with the `dory k8s` CLI):
///   • `~/.dory/k8s/ports` — extra port publishings, one `HOST:CONTAINER[/proto]` per line.
///     Published ports are auto-forwarded to `localhost` like any container's, so k3s NodePorts
///     become host-reachable (e.g. `30500:30500` for a local registry).
///   • `~/.dory/k8s/registries.yaml` — bind-mounted read-only to `/etc/rancher/k3s/registries.yaml`,
///     k3s' native registry mirror/trust config. Living on the host, it survives the cluster
///     container being recreated (k3s reads it at boot).
enum KubernetesProvisioner {
    static let containerName = "dory-k8s"
    nonisolated static let defaultImage = KubeVersionCatalog.latest.image
    static let apiPort = 6443
    /// Name used for the cluster/user/context in the exported kubeconfig, replacing k3s' generic
    /// `default` so tools can target the cluster with `--context dory`.
    static let contextName = "dory"
    static var kubeconfigPath: String { "\(NSHomeDirectory())/.kube/dory-config" }
    static var configDirectory: String { "\(NSHomeDirectory())/.dory/k8s" }
    static var extraPortsConfigPath: String { "\(configDirectory)/ports" }
    static var registriesConfigPath: String { "\(configDirectory)/registries.yaml" }

    enum K8sError: Error, Sendable, CustomStringConvertible {
        case createFailed(String)
        case notReady(String)
        case kubeconfigFailed(String)
        case kubectlMissing
        case apiUnreachable(String)
        case containerExited(String)

        var description: String {
            switch self {
            case .createFailed(let detail):
                return detail.isEmpty ? "could not create the k3s container" : "could not create the k3s container: \(detail)"
            case .notReady(let detail):
                return detail.isEmpty ? "k3s did not become Ready before the timeout" : "k3s did not become Ready: \(detail)"
            case .kubeconfigFailed(let detail):
                return detail.isEmpty ? "could not read the k3s kubeconfig" : "could not read the k3s kubeconfig: \(detail)"
            case .kubectlMissing:
                return "kubectl is missing"
            case .apiUnreachable(let detail):
                return detail.isEmpty ? "the Kubernetes API is not reachable from macOS" : "the Kubernetes API is not reachable from macOS: \(detail)"
            case .containerExited(let detail):
                return detail.isEmpty ? "the k3s container exited during startup" : "the k3s container exited during startup: \(detail)"
            }
        }
    }

    /// An extra `HOST:CONTAINER[/tcp|udp]` publishing on the cluster container.
    struct PortPublish: Equatable, Sendable {
        var host: Int
        var container: Int
        var proto: String

        static func parse(_ line: String) -> PortPublish? {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            let portsAndProto = trimmed.split(separator: "/", maxSplits: 1)
            let proto = portsAndProto.count == 2 ? String(portsAndProto[1]) : "tcp"
            guard proto == "tcp" || proto == "udp" else { return nil }
            let parts = portsAndProto[0].split(separator: ":")
            guard parts.count == 2, let host = Int(parts[0]), let container = Int(parts[1]),
                  (1...65535).contains(host), (1...65535).contains(container) else { return nil }
            return PortPublish(host: host, container: container, proto: proto)
        }
    }

    static func enable(runtime: any ContainerRuntime, image: String = defaultImage, progress: @Sendable (String) -> Void = { _ in }) async throws {
        let extraPorts = loadExtraPorts()
        if await isRunning(runtime) {
            if await publishedPortsCurrent(runtime, extraPorts: extraPorts) {
                try await writeKubeconfig(runtime)
                progress("Waiting for Kubernetes API access…")
                try await waitForHostAPI(runtime, progress: progress)
                progress("Kubernetes is running")
                return
            }
            progress("Port publishing changed — recreating the cluster…")
        }

        progress("Pulling Kubernetes (k3s)…")
        try? await runtime.pull(image: image)

        progress("Starting the cluster in the shared VM…")
        await deleteExisting(runtime)
        let encodedName = DockerImageOps.queryValue(containerName)
        guard let create = await runtime.proxyRequest(method: "POST", path: "/containers/create?name=\(encodedName)",
            headers: [(name: "Content-Type", value: "application/json")],
            body: createBody(image: image, extraPorts: extraPorts, registriesBind: registriesBindSource())) else {
            throw K8sError.createFailed("")
        }
        guard create.statusCode == 201, let id = decodeId(create.body) else {
            throw K8sError.createFailed(createFailureDetail(create.body))
        }
        let encodedID = DockerImageOps.pathComponent(id)
        guard let start = await runtime.proxyRequest(method: "POST", path: "/containers/\(encodedID)/start", headers: [], body: Data()) else {
            throw K8sError.createFailed("")
        }
        guard start.statusCode == 204 || start.isSuccess else {
            throw K8sError.createFailed(createFailureDetail(start.body))
        }

        progress("Waiting for the node to become Ready…")
        var lastProbe = ""
        for attempt in 0..<90 {
            if let state = await containerState(runtime), !state.running {
                throw K8sError.containerExited(await startupLogTail(runtime))
            }
            if let result = try? await runtime.exec(containerID: containerName, command: ["kubectl", "get", "nodes", "--no-headers"]) {
                lastProbe = result.output
                if result.output.contains("Ready") {
                    try await writeKubeconfig(runtime)
                    progress("Waiting for Kubernetes API access…")
                    try await waitForHostAPI(runtime, progress: progress)
                    progress("Kubernetes is running")
                    return
                }
            }
            if attempt == 20 || attempt == 45 || attempt == 70 {
                progress("Still waiting for k3s networking and the API server…")
            }
            try? await Task.sleep(for: .seconds(2))
        }
        throw K8sError.notReady(lastProbe.isEmpty ? await startupLogTail(runtime) : lastProbe)
    }

    static func disable(runtime: any ContainerRuntime) async {
        await deleteExisting(runtime)
        try? FileManager.default.removeItem(atPath: kubeconfigPath)
    }

    static func createJSON(image: String, extraPorts: [PortPublish] = [], registriesBind: String? = nil) -> String {
        var exposed = ["\"\(apiPort)/tcp\":{}"]
        var bindings = ["\"\(apiPort)/tcp\":[{\"HostPort\":\"\(apiPort)\"}]"]
        for port in extraPorts where !(port.container == apiPort && port.proto == "tcp") {
            exposed.append("\"\(port.container)/\(port.proto)\":{}")
            bindings.append("\"\(port.container)/\(port.proto)\":[{\"HostPort\":\"\(port.host)\"}]")
        }
        let binds = registriesBind.map { ",\"Binds\":[\"\($0):/etc/rancher/k3s/registries.yaml:ro\"]" } ?? ""
        return """
        {"Image":"\(image)",\
        "Cmd":["server","--disable=traefik","--tls-san=127.0.0.1","--tls-san=host.docker.internal"],\
        "ExposedPorts":{\(exposed.joined(separator: ","))},\
        "HostConfig":{"Privileged":true,"PortBindings":{\(bindings.joined(separator: ","))}\(binds)}}
        """
    }

    static func loadExtraPorts(path: String? = nil) -> [PortPublish] {
        let file = path ?? extraPortsConfigPath
        guard let content = try? String(contentsOfFile: file, encoding: .utf8) else { return [] }
        return content.split(separator: "\n").compactMap { PortPublish.parse(String($0)) }
    }

    /// The host registries.yaml to bind into the node, when the user has created one. The home
    /// directory is shared into the VM at the same path (SharedVMProvisioner), so the host path is
    /// directly bind-mountable by the VM's dockerd.
    static func registriesBindSource() -> String? {
        FileManager.default.fileExists(atPath: registriesConfigPath) ? registriesConfigPath : nil
    }

    /// Rename k3s' generic `default` cluster/user/context to `dory`. k3s.yaml is single-entry with
    /// a stable shape, so targeted textual rewrites are sufficient and dependency-free.
    static func renameContext(_ kubeconfig: String) -> String {
        kubeconfig
            .replacingOccurrences(of: "name: default", with: "name: \(contextName)")
            .replacingOccurrences(of: "cluster: default", with: "cluster: \(contextName)")
            .replacingOccurrences(of: "user: default", with: "user: \(contextName)")
            .replacingOccurrences(of: "current-context: default", with: "current-context: \(contextName)")
    }

    private static func createBody(image: String, extraPorts: [PortPublish], registriesBind: String?) -> Data {
        Data(createJSON(image: image, extraPorts: extraPorts, registriesBind: registriesBind).utf8)
    }

    private static func writeKubeconfig(_ runtime: any ContainerRuntime) async throws {
        guard let result = try? await runtime.exec(containerID: containerName, command: ["cat", "/etc/rancher/k3s/k3s.yaml"]),
              result.output.contains("server:") else { throw K8sError.kubeconfigFailed(await startupLogTail(runtime)) }
        // k3s.yaml already targets 127.0.0.1:6443, which the port forwarder makes host-reachable.
        let directory = (kubeconfigPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try renameContext(result.output).write(toFile: kubeconfigPath, atomically: true, encoding: .utf8)
    }

    private static func isRunning(_ runtime: any ContainerRuntime) async -> Bool {
        let encodedName = DockerImageOps.pathComponent(containerName)
        guard let response = await runtime.proxyRequest(method: "GET", path: "/containers/\(encodedName)/json", headers: [], body: Data()),
              response.isSuccess else { return false }
        return String(data: response.body, encoding: .utf8)?.contains("\"Running\":true") ?? false
    }

    /// Whether the existing container already publishes every requested extra port and carries the
    /// registries.yaml bind when one is configured, so an enable with unchanged config can reuse it
    /// instead of recreating (both are fixed at create).
    private static func publishedPortsCurrent(_ runtime: any ContainerRuntime, extraPorts: [PortPublish]) async -> Bool {
        guard !extraPorts.isEmpty || registriesBindSource() != nil else { return true }
        let encodedName = DockerImageOps.pathComponent(containerName)
        guard let response = await runtime.proxyRequest(method: "GET", path: "/containers/\(encodedName)/json", headers: [], body: Data()),
              response.isSuccess, let json = String(data: response.body, encoding: .utf8) else { return false }
        if registriesBindSource() != nil && !json.contains("registries.yaml") { return false }
        return extraPorts.allSatisfy {
            json.contains("\"\($0.container)/\($0.proto)\"") && json.contains("\"HostPort\":\"\($0.host)\"")
        }
    }

    private static func deleteExisting(_ runtime: any ContainerRuntime) async {
        let encodedName = DockerImageOps.pathComponent(containerName)
        _ = await runtime.proxyRequest(method: "DELETE", path: "/containers/\(encodedName)?force=true", headers: [], body: Data())
    }

    private static func waitForHostAPI(_ runtime: any ContainerRuntime, progress: @Sendable (String) -> Void) async throws {
        guard let kubectl = HostTools.kubectl() else { throw K8sError.kubectlMissing }
        var lastOutput = ""
        for attempt in 0..<60 {
            if let state = await containerState(runtime), !state.running {
                throw K8sError.containerExited(await startupLogTail(runtime))
            }
            let result = await Shell.runAsyncResult(kubectl, ["--kubeconfig", kubeconfigPath, "get", "--raw", "/version"])
            if result.exit == 0, result.output.contains("gitVersion") {
                return
            }
            lastOutput = result.output
            if attempt == 15 || attempt == 35 {
                progress("Waiting for localhost:\(apiPort) to answer…")
            }
            try? await Task.sleep(for: .seconds(2))
        }
        throw K8sError.apiUnreachable(lastOutput)
    }

    private struct ContainerState: Decodable, Sendable {
        let running: Bool
        let status: String
        let exitCode: Int?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case running = "Running"
            case status = "Status"
            case exitCode = "ExitCode"
            case error = "Error"
        }
    }

    private struct ContainerInspect: Decodable, Sendable { let State: ContainerState? }

    private static func containerState(_ runtime: any ContainerRuntime) async -> ContainerState? {
        let encodedName = DockerImageOps.pathComponent(containerName)
        guard let response = await runtime.proxyRequest(method: "GET", path: "/containers/\(encodedName)/json", headers: [], body: Data()),
              response.isSuccess else { return nil }
        return try? JSONDecoder().decode(ContainerInspect.self, from: response.body).State
    }

    private static func startupLogTail(_ runtime: any ContainerRuntime) async -> String {
        guard let lines = try? await runtime.logs(containerID: containerName) else { return "" }
        return lines.suffix(20).map(\.message).joined(separator: "\n")
    }

    private static func createFailureDetail(_ body: Data?) -> String {
        guard let body, !body.isEmpty else { return "" }
        return String(decoding: body, as: UTF8.self)
    }

    private static func decodeId(_ data: Data) -> String? {
        struct Out: Decodable { let Id: String }
        return (try? JSONDecoder().decode(Out.self, from: data))?.Id
    }
}
