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
        case invalidPortConfig(path: String, line: Int, value: String)
        /// The container exists but its create-time config (ports/binds) no longer matches the
        /// requested config; only disable + enable can apply the change.
        case configDrift

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
            case .invalidPortConfig(let path, let line, let value):
                return "invalid Kubernetes port config at \(path):\(line): \(value)"
            case .configDrift:
                return "Kubernetes create-time config changed; disable and re-enable Kubernetes to apply"
            }
        }
    }

    /// An extra `HOST:CONTAINER[/tcp|udp]` publishing on the cluster container.
    struct PortPublish: Equatable, Hashable, Sendable {
        var host: Int
        var container: Int
        var proto: String

        static func parse(_ line: String) -> PortPublish? {
            let normalized = normalizedConfigText(line)
            guard !normalized.isEmpty else { return nil }
            let portsAndProto = normalized.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            let proto = portsAndProto.count == 2 ? String(portsAndProto[1]) : "tcp"
            guard proto == "tcp" || proto == "udp" else { return nil }
            let parts = portsAndProto[0].split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, let host = Int(parts[0]), let container = Int(parts[1]),
                  (1...65535).contains(host), (1...65535).contains(container) else { return nil }
            return PortPublish(host: host, container: container, proto: proto)
        }

        static func normalizedConfigText(_ line: String) -> String {
            let withoutComment = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            return withoutComment.components(separatedBy: .whitespacesAndNewlines).joined()
        }
    }

    private enum ExistingContainerState {
        case absent
        case running
        case stopped
    }

    private struct KubernetesCreateRequest: Encodable {
        let Image: String
        let Cmd: [String]
        let ExposedPorts: [String: DockerEmptyObject]
        let HostConfig: HostConfigBody

        struct HostConfigBody: Encodable {
            let Privileged: Bool
            let PortBindings: [String: [DockerPortBinding]]
            let Binds: [String]?
        }
    }

    private static let registriesBindTarget = "/etc/rancher/k3s/registries.yaml"

    static func enable(runtime: any ContainerRuntime, image: String = defaultImage, progress: @Sendable (String) -> Void = { _ in }) async throws {
        let extraPorts = try loadExtraPorts()
        switch await containerState(runtime) {
        case .running:
            if await publishedPortsCurrent(runtime, extraPorts: extraPorts) {
                try await writeKubeconfig(runtime)
                progress("Waiting for Kubernetes API access…")
                try await waitForHostAPI(runtime, progress: progress)
                progress("Kubernetes is running")
                return
            }
            throw K8sError.configDrift
        case .stopped:
            if await publishedPortsCurrent(runtime, extraPorts: extraPorts) {
                try await runtime.start(containerID: containerName)
                try await waitUntilReady(runtime: runtime, progress: progress)
                return
            }
            throw K8sError.configDrift
        case .absent:
            break
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

        try await waitUntilReady(runtime: runtime, progress: progress)
    }

    private static func waitUntilReady(runtime: any ContainerRuntime, progress: @Sendable (String) -> Void) async throws {
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
        String(decoding: createBody(image: image, extraPorts: extraPorts, registriesBind: registriesBind), as: UTF8.self)
    }

    static func loadExtraPorts(path: String? = nil) throws -> [PortPublish] {
        let file = path ?? extraPortsConfigPath
        guard let content = try? String(contentsOfFile: file, encoding: .utf8) else { return [] }
        var ports: [PortPublish] = []
        for (index, line) in content.components(separatedBy: .newlines).enumerated() {
            guard !PortPublish.normalizedConfigText(line).isEmpty else { continue }
            guard let port = PortPublish.parse(line) else {
                throw K8sError.invalidPortConfig(path: file, line: index + 1, value: line)
            }
            ports.append(port)
        }
        return ports
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
        kubeconfig.components(separatedBy: "\n").map(renameContextLine).joined(separator: "\n")
    }

    private static func createBody(image: String, extraPorts: [PortPublish], registriesBind: String?) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(createRequest(image: image, extraPorts: extraPorts, registriesBind: registriesBind))) ?? Data()
    }

    private static func createRequest(image: String, extraPorts: [PortPublish], registriesBind: String?) -> KubernetesCreateRequest {
        var exposed: [String: DockerEmptyObject] = [:]
        var bindings: [String: [DockerPortBinding]] = [:]
        addPortBinding(PortPublish(host: apiPort, container: apiPort, proto: "tcp"), exposed: &exposed, bindings: &bindings)
        for port in extraPorts {
            addPortBinding(port, exposed: &exposed, bindings: &bindings)
        }
        return KubernetesCreateRequest(
            Image: image,
            Cmd: ["server", "--disable=traefik", "--tls-san=127.0.0.1", "--tls-san=host.docker.internal"],
            ExposedPorts: exposed,
            HostConfig: .init(
                Privileged: true,
                PortBindings: bindings,
                Binds: registriesBind.map { [registriesBindValue(source: $0)] }
            )
        )
    }

    private static func addPortBinding(_ port: PortPublish, exposed: inout [String: DockerEmptyObject], bindings: inout [String: [DockerPortBinding]]) {
        let key = "\(port.container)/\(port.proto)"
        let hostPort = "\(port.host)"
        exposed[key] = DockerEmptyObject()
        var existing = bindings[key] ?? []
        if !existing.contains(where: { $0.HostPort == hostPort }) {
            existing.append(DockerPortBinding(HostPort: hostPort))
        }
        bindings[key] = existing
    }

    private static func registriesBindValue(source: String) -> String {
        "\(source):\(registriesBindTarget):ro"
    }

    private static func renameContextLine(_ line: String) -> String {
        let hasCarriageReturn = line.hasSuffix("\r")
        let body = hasCarriageReturn ? String(line.dropLast()) : line
        let replacements = ["name", "cluster", "user", "current-context"]
        for key in replacements {
            let suffix = "\(key): default"
            guard body.hasSuffix(suffix) else { continue }
            let prefix = body.dropLast(suffix.count)
            // k3s' users list nests the key in a sequence item ("- name: default"),
            // so allow one trailing sequence marker on top of the indent.
            var indent = prefix
            if indent.hasSuffix("- ") { indent = indent.dropLast(2) }
            guard indent.allSatisfy({ $0 == " " || $0 == "\t" }) else { continue }
            let renamed = "\(prefix)\(key): \(contextName)"
            return hasCarriageReturn ? "\(renamed)\r" : renamed
        }
        return line
    }

    private static func writeKubeconfig(_ runtime: any ContainerRuntime) async throws {
        guard let result = try? await runtime.exec(containerID: containerName, command: ["cat", "/etc/rancher/k3s/k3s.yaml"]),
              result.output.contains("server:") else { throw K8sError.kubeconfigFailed(await startupLogTail(runtime)) }
        // k3s.yaml already targets 127.0.0.1:6443, which the port forwarder makes host-reachable.
        let directory = (kubeconfigPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try renameContext(result.output).write(toFile: kubeconfigPath, atomically: true, encoding: .utf8)
    }

    private static func containerState(_ runtime: any ContainerRuntime) async -> ExistingContainerState {
        let encodedName = DockerImageOps.pathComponent(containerName)
        guard let response = await runtime.proxyRequest(method: "GET", path: "/containers/\(encodedName)/json", headers: [], body: Data()),
              response.isSuccess else { return .absent }
        guard let inspect = try? JSONDecoder().decode(ContainerInspect.self, from: response.body) else { return .absent }
        return inspect.State?.Running == true ? .running : .stopped
    }

    /// Whether the existing container already publishes every requested extra port and carries the
    /// registries.yaml bind when one is configured, so an enable with unchanged config can reuse it
    /// instead of recreating (both are fixed at create).
    private static func publishedPortsCurrent(_ runtime: any ContainerRuntime, extraPorts: [PortPublish]) async -> Bool {
        let registriesBind = registriesBindSource()
        let encodedName = DockerImageOps.pathComponent(containerName)
        guard let response = await runtime.proxyRequest(method: "GET", path: "/containers/\(encodedName)/json", headers: [], body: Data()),
              response.isSuccess, let json = String(data: response.body, encoding: .utf8) else { return false }
        return inspectJSONCoversConfig(json, extraPorts: extraPorts, registriesBind: registriesBind)
    }

    static func inspectJSONCoversConfig(_ json: String, extraPorts: [PortPublish], registriesBind: String?) -> Bool {
        guard let data = json.data(using: .utf8),
              let inspect = try? JSONDecoder().decode(ContainerInspect.self, from: data) else { return false }
        guard let hostConfig = inspect.HostConfig,
              let actualPorts = actualExtraPorts(from: hostConfig.PortBindings ?? [:]) else { return false }
        let desiredRegistryBinds = Set(registriesBind.map { [registriesBindValue(source: $0)] } ?? [])
        let actualRegistryBinds = Set((hostConfig.Binds ?? []).filter(isRegistriesBind))
        return actualPorts == desiredExtraPorts(extraPorts) && actualRegistryBinds == desiredRegistryBinds
    }

    private static func desiredExtraPorts(_ ports: [PortPublish]) -> Set<PortPublish> {
        Set(ports.filter { !isBuiltInAPIBinding($0) })
    }

    private static func actualExtraPorts(from bindings: [String: [ContainerInspect.PortBinding]]) -> Set<PortPublish>? {
        var ports = Set<PortPublish>()
        for (key, hostBindings) in bindings {
            let parts = key.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let container = Int(parts[0]),
                  !parts[1].isEmpty else { return nil }
            let proto = String(parts[1])
            for binding in hostBindings {
                guard let hostPort = binding.HostPort,
                      let host = Int(hostPort) else { return nil }
                let port = PortPublish(host: host, container: container, proto: proto)
                if !isBuiltInAPIBinding(port) {
                    ports.insert(port)
                }
            }
        }
        return ports
    }

    private static func isBuiltInAPIBinding(_ port: PortPublish) -> Bool {
        port.host == apiPort && port.container == apiPort && port.proto == "tcp"
    }

    private static func isRegistriesBind(_ bind: String) -> Bool {
        bind.contains(":\(registriesBindTarget):") || bind.hasSuffix(":\(registriesBindTarget)")
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

    private struct ContainerInspect: Decodable {
        let HostConfig: HostConfig?
        let State: State?

        struct HostConfig: Decodable {
            let Binds: [String]?
            let PortBindings: [String: [PortBinding]]?
        }

        struct State: Decodable {
            let Running: Bool?
        }

        struct PortBinding: Decodable {
            let HostPort: String?
        }
    }
}
