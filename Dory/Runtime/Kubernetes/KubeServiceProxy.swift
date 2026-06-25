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
            let host = serviceHost(name: service.name, namespace: service.namespace, suffix: suffix)
            result[host] = ProxyBackend(
                host: "127.0.0.1",
                port: proxyPort,
                pathPrefix: serviceProxyPath(name: service.name, namespace: service.namespace, port: service.port)
            )
        }
        return result
    }

    static func serviceHost(name: String, namespace: String, suffix: String) -> String {
        "\(name).\(namespace).k8s.\(suffix)".lowercased()
    }

    static func serviceProxyPath(name: String, namespace: String, port: Int) -> String {
        "/api/v1/namespaces/\(namespace)/services/\(name):\(port)/proxy"
    }

    static func firstPort(from summary: String) -> Int? {
        summary.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .first { !$0.isEmpty }
            .flatMap(Int.init)
    }

    static func browserURL(
        name: String,
        namespace: String,
        ports: String,
        suffix: String,
        domainAvailable: Bool
    ) -> URL? {
        let host = serviceHost(name: name, namespace: namespace, suffix: suffix)
        if domainAvailable { return URL(string: "http://\(host)") }
        guard let port = firstPort(from: ports) else { return URL(string: "http://\(host)") }
        return URL(string: "http://127.0.0.1:\(proxyPort)\(serviceProxyPath(name: name, namespace: namespace, port: port))/")
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
