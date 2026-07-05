import Foundation

/// One-click Kubernetes: runs a k3s server as a container inside Dory's shared VM (the k3d pattern),
/// publishes the API on :6443 (auto-forwarded to `localhost` by the port forwarder), and writes a
/// kubeconfig the host `kubectl` picks up — mirroring OrbStack's built-in cluster. NOTE: k3s brings
/// its own embedded containerd image store, SEPARATE from the shared engine's dockerd store. A
/// locally-built Docker image is therefore NOT automatically visible to Pods — push it to a registry
/// the cluster can reach, or import it into k3s's containerd (`k8s.io` namespace). Auto image-sync is
/// a tracked follow-up.
enum KubernetesProvisioner {
    static let containerName = "dory-k8s"
    nonisolated static let defaultImage = KubeVersionCatalog.latest.image
    static let apiPort = 6443
    static var kubeconfigPath: String { "\(NSHomeDirectory())/.kube/dory-config" }

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

    static func enable(runtime: any ContainerRuntime, image: String = defaultImage, progress: @Sendable (String) -> Void = { _ in }) async throws {
        if await isRunning(runtime) {
            try await writeKubeconfig(runtime)
            progress("Waiting for Kubernetes API access…")
            try await waitForHostAPI(runtime, progress: progress)
            progress("Kubernetes is running")
            return
        }

        progress("Pulling Kubernetes (k3s)…")
        try? await runtime.pull(image: image)

        progress("Starting the cluster in the shared VM…")
        await deleteExisting(runtime)
        let encodedName = DockerImageOps.queryValue(containerName)
        guard let create = await runtime.proxyRequest(method: "POST", path: "/containers/create?name=\(encodedName)",
            headers: [(name: "Content-Type", value: "application/json")], body: createBody(image: image)) else {
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

    static func createJSON(image: String) -> String {
        """
        {"Image":"\(image)",\
        "Cmd":["server","--disable=traefik","--tls-san=127.0.0.1","--tls-san=host.docker.internal"],\
        "ExposedPorts":{"\(apiPort)/tcp":{}},\
        "HostConfig":{"Privileged":true,"PortBindings":{"\(apiPort)/tcp":[{"HostPort":"\(apiPort)"}]}}}
        """
    }

    private static func createBody(image: String) -> Data {
        Data(createJSON(image: image).utf8)
    }

    private static func writeKubeconfig(_ runtime: any ContainerRuntime) async throws {
        guard let result = try? await runtime.exec(containerID: containerName, command: ["cat", "/etc/rancher/k3s/k3s.yaml"]),
              result.output.contains("server:") else { throw K8sError.kubeconfigFailed(await startupLogTail(runtime)) }
        // k3s.yaml already targets 127.0.0.1:6443, which the port forwarder makes host-reachable.
        let directory = (kubeconfigPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try result.output.write(toFile: kubeconfigPath, atomically: true, encoding: .utf8)
    }

    private static func isRunning(_ runtime: any ContainerRuntime) async -> Bool {
        let encodedName = DockerImageOps.pathComponent(containerName)
        guard let response = await runtime.proxyRequest(method: "GET", path: "/containers/\(encodedName)/json", headers: [], body: Data()),
              response.isSuccess else { return false }
        return String(data: response.body, encoding: .utf8)?.contains("\"Running\":true") ?? false
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
