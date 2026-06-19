import Foundation

struct KubeService: Sendable {
    var name: String
    var namespace: String
    var port: Int
}

/// Routes `<svc>.<ns>.k8s.dory.local` to in-cluster Services — OrbStack's `*.k8s.orb.local`. Runs a
/// local `kubectl proxy` (which handles API-server auth) and exposes each Service through the API's
/// `/api/v1/namespaces/<ns>/services/<svc>:<port>/proxy` endpoint, which Dory's reverse proxy
/// rewrites requests to. No NodePort/LoadBalancer plumbing required.
enum KubeServiceProxy {
    static let proxyPort = 18001

    static var kubeconfig: String { KubernetesProvisioner.kubeconfigPath }

    static func kubectl() -> String? {
        Shell.find("kubectl", candidates: ["/usr/local/bin/kubectl", "/opt/homebrew/bin/kubectl"])
    }

    static func startProxy() -> Process? {
        guard let kubectl = kubectl(), FileManager.default.fileExists(atPath: kubeconfig) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: kubectl)
        // Bound to loopback only, so accepting any Host header is safe — it lets Dory's reverse
        // proxy forward `*.k8s.dory.local` requests through without a 403.
        process.arguments = ["--kubeconfig", kubeconfig, "proxy", "--port=\(proxyPort)",
                             "--address=127.0.0.1", "--accept-hosts=.*"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        return process
    }

    static func backends(suffix: String) async -> [String: ProxyBackend] {
        var result: [String: ProxyBackend] = [:]
        for service in await services() {
            let host = "\(service.name).\(service.namespace).k8s.\(suffix)".lowercased()
            let prefix = "/api/v1/namespaces/\(service.namespace)/services/\(service.name):\(service.port)/proxy"
            result[host] = ProxyBackend(host: "127.0.0.1", port: proxyPort, pathPrefix: prefix)
        }
        return result
    }

    static func services() async -> [KubeService] {
        guard let kubectl = kubectl(), FileManager.default.fileExists(atPath: kubeconfig) else { return [] }
        let result = await Shell.runAsyncResult(kubectl, ["--kubeconfig", kubeconfig, "get", "svc", "-A", "-o", "json"])
        guard result.exit == 0, let data = result.output.data(using: .utf8) else { return [] }
        struct List: Decodable { let items: [Item]? }
        struct Item: Decodable { let metadata: Meta?; let spec: Spec? }
        struct Meta: Decodable { let name: String?; let namespace: String? }
        struct Spec: Decodable { let ports: [Port]?; let clusterIP: String? }
        struct Port: Decodable { let port: Int? }
        guard let list = try? JSONDecoder().decode(List.self, from: data) else { return [] }
        return (list.items ?? []).compactMap { item in
            guard let name = item.metadata?.name, let namespace = item.metadata?.namespace,
                  let port = item.spec?.ports?.first?.port,
                  item.spec?.clusterIP != "None" else { return nil }   // skip headless services
            return KubeService(name: name, namespace: namespace, port: port)
        }
    }
}
