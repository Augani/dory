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

    enum K8sError: Error, Sendable { case createFailed, notReady, kubeconfigFailed }

    static func enable(runtime: any ContainerRuntime, image: String = defaultImage, progress: @Sendable (String) -> Void = { _ in }) async throws {
        if await isRunning(runtime) {
            try await writeKubeconfig(runtime)
            progress("Kubernetes is running")
            return
        }

        progress("Pulling Kubernetes (k3s)…")
        try? await runtime.pull(image: image)

        progress("Starting the cluster in the shared VM…")
        await deleteExisting(runtime)
        let encodedName = DockerImageOps.queryValue(containerName)
        guard let create = await runtime.proxyRequest(method: "POST", path: "/containers/create?name=\(encodedName)",
            headers: [(name: "Content-Type", value: "application/json")], body: createBody(image: image)),
            create.statusCode == 201, let id = decodeId(create.body) else { throw K8sError.createFailed }
        let encodedID = DockerImageOps.pathComponent(id)
        guard let start = await runtime.proxyRequest(method: "POST", path: "/containers/\(encodedID)/start", headers: [], body: Data()),
            start.statusCode == 204 || start.isSuccess else { throw K8sError.createFailed }

        progress("Waiting for the node to become Ready…")
        for _ in 0..<60 {
            if let result = try? await runtime.exec(containerID: containerName, command: ["kubectl", "get", "nodes", "--no-headers"]),
               result.output.contains("Ready") {
                try await writeKubeconfig(runtime)
                progress("Kubernetes is running")
                return
            }
            try? await Task.sleep(for: .seconds(2))
        }
        throw K8sError.notReady
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
              result.output.contains("server:") else { throw K8sError.kubeconfigFailed }
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

    private static func decodeId(_ data: Data) -> String? {
        struct Out: Decodable { let Id: String }
        return (try? JSONDecoder().decode(Out.self, from: data))?.Id
    }
}
