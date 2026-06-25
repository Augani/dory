import Foundation

enum KubeError: Error, Sendable, Equatable {
    case kubectlMissing
    case nonZero(Int32, String)
    case decode
}

struct KubeClient: Sendable {
    var kubectlPath: String? {
        Shell.find("kubectl", candidates: ["/usr/local/bin/kubectl", "/opt/homebrew/bin/kubectl"])
    }

    static func kubeconfig() -> String? {
        let path = KubernetesProvisioner.kubeconfigPath
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    static func args(kind: String, namespace: String?, kubeconfig: String?) -> [String] {
        var args: [String] = []
        if let kubeconfig, !kubeconfig.isEmpty { args += ["--kubeconfig", kubeconfig] }
        args += ["get", kind]
        if !isClusterScoped(kind) {
            if let namespace, !namespace.isEmpty { args += ["-n", namespace] } else { args += ["-A"] }
        }
        args += ["-o", "json"]
        return args
    }

    static func deleteArgs(kind: String, name: String, namespace: String, kubeconfig: String?) -> [String] {
        var args: [String] = []
        if let kubeconfig, !kubeconfig.isEmpty { args += ["--kubeconfig", kubeconfig] }
        args += ["delete", kind, name]
        if !isClusterScoped(kind) { args += ["-n", namespace] }
        return args
    }

    static func isClusterScoped(_ kind: String) -> Bool {
        switch kind.lowercased() {
        case "namespace", "namespaces", "ns",
             "node", "nodes", "no",
             "persistentvolume", "persistentvolumes", "pv",
             "storageclass", "storageclasses", "sc",
             "clusterrole", "clusterroles",
             "clusterrolebinding", "clusterrolebindings":
            return true
        default:
            return false
        }
    }

    func getJSON(kind: String, namespace: String?) async -> Result<Data, KubeError> {
        guard let kubectl = kubectlPath else { return .failure(.kubectlMissing) }
        let result = await Shell.runAsyncResult(kubectl, Self.args(kind: kind, namespace: namespace, kubeconfig: Self.kubeconfig()))
        guard result.exit == 0 else { return .failure(.nonZero(result.exit, result.output)) }
        guard let data = result.output.data(using: .utf8) else { return .failure(.decode) }
        return .success(data)
    }

    func delete(kind: String, name: String, namespace: String) async -> Result<Void, KubeError> {
        guard let kubectl = kubectlPath else { return .failure(.kubectlMissing) }
        let result = await Shell.runAsyncResult(kubectl, Self.deleteArgs(kind: kind, name: name, namespace: namespace, kubeconfig: Self.kubeconfig()))
        return result.exit == 0 ? .success(()) : .failure(.nonZero(result.exit, result.output))
    }

    static func scaleArgs(deployment: String, namespace: String, replicas: Int, kubeconfig: String?) -> [String] {
        var args: [String] = []
        if let kubeconfig, !kubeconfig.isEmpty { args += ["--kubeconfig", kubeconfig] }
        args += ["scale", "deployment", deployment, "-n", namespace, "--replicas=\(replicas)"]
        return args
    }

    static func rolloutRestartArgs(deployment: String, namespace: String, kubeconfig: String?) -> [String] {
        var args: [String] = []
        if let kubeconfig, !kubeconfig.isEmpty { args += ["--kubeconfig", kubeconfig] }
        args += ["rollout", "restart", "deployment", deployment, "-n", namespace]
        return args
    }

    static func logsArgs(
        pod: String,
        namespace: String,
        container: String? = nil,
        allContainers: Bool = false,
        tail: Int? = nil,
        follow: Bool = false,
        since: String? = nil,
        timestamps: Bool = true,
        kubeconfig: String?
    ) -> [String] {
        var args: [String] = []
        if let kubeconfig, !kubeconfig.isEmpty { args += ["--kubeconfig", kubeconfig] }
        args += ["logs", pod, "-n", namespace]
        if allContainers {
            args.append("--all-containers=true")
        } else if let container, !container.isEmpty {
            args += ["-c", container]
        }
        if let tail { args.append("--tail=\(tail)") }
        if follow { args.append("-f") }
        if let since, !since.isEmpty { args.append("--since=\(since)") }
        if timestamps { args.append("--timestamps") }
        return args
    }

    func scale(deployment: String, namespace: String, replicas: Int) async -> Result<Void, KubeError> {
        guard let kubectl = kubectlPath else { return .failure(.kubectlMissing) }
        let result = await Shell.runAsyncResult(kubectl, Self.scaleArgs(deployment: deployment, namespace: namespace, replicas: replicas, kubeconfig: Self.kubeconfig()))
        return result.exit == 0 ? .success(()) : .failure(.nonZero(result.exit, result.output))
    }

    func rolloutRestart(deployment: String, namespace: String) async -> Result<Void, KubeError> {
        guard let kubectl = kubectlPath else { return .failure(.kubectlMissing) }
        let result = await Shell.runAsyncResult(kubectl, Self.rolloutRestartArgs(deployment: deployment, namespace: namespace, kubeconfig: Self.kubeconfig()))
        return result.exit == 0 ? .success(()) : .failure(.nonZero(result.exit, result.output))
    }

    func logs(
        pod: String,
        namespace: String,
        container: String? = nil,
        allContainers: Bool = false,
        tail: Int = 200
    ) async -> Result<Data, KubeError> {
        guard let kubectl = kubectlPath else { return .failure(.kubectlMissing) }
        let result = await Shell.runAsyncResult(kubectl, Self.logsArgs(
            pod: pod,
            namespace: namespace,
            container: container,
            allContainers: allContainers,
            tail: tail,
            follow: false,
            since: nil,
            timestamps: true,
            kubeconfig: Self.kubeconfig()
        ))
        guard result.exit == 0 else { return .failure(.nonZero(result.exit, result.output)) }
        guard let data = result.output.data(using: .utf8) else { return .failure(.decode) }
        return .success(data)
    }
}
