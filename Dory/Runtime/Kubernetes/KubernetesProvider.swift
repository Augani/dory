import Foundation

struct KubeVersion: Decodable, Sendable { var gitVersion: String? }

struct KubeContainerStatus: Decodable, Sendable {
    var ready: Bool?
    var restartCount: Int?
}

struct KubePodStatus: Decodable, Sendable {
    var phase: String?
    var containerStatuses: [KubeContainerStatus]?
}

struct KubeMetadata: Decodable, Sendable {
    var name: String?
    var namespace: String?
    var creationTimestamp: String?
}

struct KubePod: Decodable, Sendable {
    var metadata: KubeMetadata?
    var status: KubePodStatus?
}

struct KubePodList: Decodable, Sendable { var items: [KubePod]? }

struct KubeNode: Decodable, Sendable { var items: [KubeMetadata]? }

struct KubernetesStatus: Sendable {
    var reachable: Bool
    var version: String
    var nodeCount: Int
    var pods: [Pod]

    var info: String {
        guard reachable else { return "Cluster not running" }
        let namespaces = Set(pods.map(\.namespace)).count
        return "\(version) · \(nodeCount) node\(nodeCount == 1 ? "" : "s") · \(pods.count) pods · \(namespaces) namespaces"
    }
}

/// Surfaces an existing Kubernetes cluster via `kubectl`. One-click bootstrap of k3s is provided
/// separately (scripts/enable-kubernetes.sh) because it boots infrastructure.
struct KubernetesProvider: Sendable {
    var kubectlPath: String? {
        Shell.find("kubectl", candidates: ["/usr/local/bin/kubectl", "/opt/homebrew/bin/kubectl"])
    }

    /// Prefer Dory's own cluster kubeconfig when present, so the GUI reflects the cluster Dory
    /// provisioned without disturbing the user's default `~/.kube/config`.
    private var kubeconfigArgs: [String] {
        let path = KubernetesProvisioner.kubeconfigPath
        return FileManager.default.fileExists(atPath: path) ? ["--kubeconfig", path] : []
    }

    func status() async -> KubernetesStatus {
        guard let kubectl = kubectlPath else { return KubernetesStatus(reachable: false, version: "", nodeCount: 0, pods: []) }
        let versionResult = await Shell.runAsyncResult(kubectl, kubeconfigArgs + ["get", "--raw", "/version"])
        guard versionResult.exit == 0,
              let data = versionResult.output.data(using: .utf8),
              let version = try? JSONDecoder().decode(KubeVersion.self, from: data),
              let gitVersion = version.gitVersion else {
            return KubernetesStatus(reachable: false, version: "", nodeCount: 0, pods: [])
        }
        let nodes = await decode(kubectl, kubeconfigArgs + ["get", "nodes", "-o", "json"], as: KubeNode.self)?.items?.count ?? 0
        let pods = await pods(kubectl: kubectl)
        return KubernetesStatus(reachable: true, version: gitVersion, nodeCount: nodes, pods: pods)
    }

    private func pods(kubectl: String) async -> [Pod] {
        guard let list = await decode(kubectl, kubeconfigArgs + ["get", "pods", "-A", "-o", "json"], as: KubePodList.self)?.items else { return [] }
        return list.compactMap { pod in
            guard let name = pod.metadata?.name else { return nil }
            let statuses = pod.status?.containerStatuses ?? []
            let ready = statuses.filter { $0.ready == true }.count
            let restarts = statuses.reduce(0) { $0 + ($1.restartCount ?? 0) }
            return Pod(
                name: name, namespace: pod.metadata?.namespace ?? "default",
                phase: Self.phase(pod.status?.phase, statuses: statuses),
                ready: "\(ready)/\(max(statuses.count, 1))", restarts: restarts,
                age: DockerFormat.relative(iso: pod.metadata?.creationTimestamp)
            )
        }
    }

    private func decode<T: Decodable>(_ kubectl: String, _ args: [String], as type: T.Type) async -> T? {
        let result = await Shell.runAsyncResult(kubectl, args)
        guard result.exit == 0, let data = result.output.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func phase(_ phase: String?, statuses: [KubeContainerStatus]) -> PodPhase {
        switch phase {
        case "Running": return .running
        case "Pending": return .pending
        case "Succeeded": return .completed
        default: return .crashLoopBackOff
        }
    }
}
