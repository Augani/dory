import Foundation

struct KubeServerVersion: Decodable, Sendable { var gitVersion: String? }

struct KubeContainerStatus: Decodable, Sendable {
    var name: String?
    var ready: Bool?
    var restartCount: Int?
    var state: KubeContainerState?
}

struct KubeContainerState: Decodable, Sendable {
    var waiting: KubeContainerWaiting?
}

struct KubeContainerWaiting: Decodable, Sendable {
    var reason: String?
}

struct KubePodStatus: Decodable, Sendable {
    var phase: String?
    var containerStatuses: [KubeContainerStatus]?
}

struct KubeContainerSpec: Decodable, Sendable {
    var name: String?
}

struct KubePodSpec: Decodable, Sendable {
    var containers: [KubeContainerSpec]?
}

struct KubeMetadata: Decodable, Sendable {
    var name: String?
    var namespace: String?
    var creationTimestamp: String?
}

struct KubePod: Decodable, Sendable {
    var metadata: KubeMetadata?
    var spec: KubePodSpec?
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

/// Surfaces an existing Kubernetes cluster via `kubectl`. Dory can bootstrap its built-in k3s
/// cluster through KubernetesProvisioner or `dory k8s enable`.
struct KubernetesProvider: Sendable {
    var kubectlPath: String? {
        HostTools.kubectl()
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
              let version = try? JSONDecoder().decode(KubeServerVersion.self, from: data),
              let gitVersion = version.gitVersion else {
            return KubernetesStatus(reachable: false, version: "", nodeCount: 0, pods: [])
        }
        let nodes = await decode(kubectl, kubeconfigArgs + ["get", "nodes", "-o", "json"], as: KubeNode.self)?.items?.count ?? 0
        let pods = await decode(kubectl, kubeconfigArgs + ["get", "pods", "-A", "-o", "json"], as: KubePodList.self).map(KubeRowMapper.pods) ?? []
        return KubernetesStatus(reachable: true, version: gitVersion, nodeCount: nodes, pods: pods)
    }

    private func decode<T: Decodable>(_ kubectl: String, _ args: [String], as type: T.Type) async -> T? {
        let result = await Shell.runAsyncResult(kubectl, args)
        guard result.exit == 0, let data = result.output.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
