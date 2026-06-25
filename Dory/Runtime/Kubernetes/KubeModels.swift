import Foundation

struct KubeDeploymentSpec: Decodable, Sendable { var replicas: Int? }
struct KubeDeploymentStatus: Decodable, Sendable {
    var readyReplicas: Int?
    var availableReplicas: Int?
    var updatedReplicas: Int?
}
struct KubeDeployment: Decodable, Sendable {
    var metadata: KubeMetadata?
    var spec: KubeDeploymentSpec?
    var status: KubeDeploymentStatus?
}
struct KubeDeploymentList: Decodable, Sendable { var items: [KubeDeployment]? }

struct KubeServicePort: Decodable, Sendable {
    var port: Int?
    var nodePort: Int?
    var `protocol`: String?
}
struct KubeServiceSpec: Decodable, Sendable {
    var type: String?
    var clusterIP: String?
    var ports: [KubeServicePort]?
}
struct KubeServiceItem: Decodable, Sendable {
    var metadata: KubeMetadata?
    var spec: KubeServiceSpec?
}
struct KubeServiceList: Decodable, Sendable { var items: [KubeServiceItem]? }

struct KubeNamespaceItem: Decodable, Sendable { var metadata: KubeMetadata? }
struct KubeNamespaceList: Decodable, Sendable { var items: [KubeNamespaceItem]? }

struct KubeConfigMapItem: Decodable, Sendable {
    var metadata: KubeMetadata?
    var data: [String: String]?
}
struct KubeConfigMapList: Decodable, Sendable { var items: [KubeConfigMapItem]? }

struct KubeSecretItem: Decodable, Sendable {
    var metadata: KubeMetadata?
    var type: String?
    var data: [String: String]?
}
struct KubeSecretList: Decodable, Sendable { var items: [KubeSecretItem]? }

struct KubeIngressBackendService: Decodable, Sendable {
    var name: String?
}
struct KubeIngressBackend: Decodable, Sendable {
    var service: KubeIngressBackendService?
}
struct KubeIngressPath: Decodable, Sendable {
    var path: String?
    var backend: KubeIngressBackend?
}
struct KubeIngressHTTP: Decodable, Sendable {
    var paths: [KubeIngressPath]?
}
struct KubeIngressRule: Decodable, Sendable {
    var host: String?
    var http: KubeIngressHTTP?
}
struct KubeIngressSpec: Decodable, Sendable {
    var rules: [KubeIngressRule]?
}
struct KubeIngressLoadBalancerIngress: Decodable, Sendable {
    var ip: String?
    var hostname: String?
}
struct KubeIngressLoadBalancer: Decodable, Sendable {
    var ingress: [KubeIngressLoadBalancerIngress]?
}
struct KubeIngressStatus: Decodable, Sendable {
    var loadBalancer: KubeIngressLoadBalancer?
}
struct KubeIngressItem: Decodable, Sendable {
    var metadata: KubeMetadata?
    var spec: KubeIngressSpec?
    var status: KubeIngressStatus?
}
struct KubeIngressList: Decodable, Sendable { var items: [KubeIngressItem]? }

struct KubeDeploymentRow: Identifiable, Hashable, Sendable {
    var name: String
    var namespace: String
    var ready: String
    var upToDate: Int
    var available: Int
    var age: String
    var replicas: Int
    var id: String { "\(namespace)/\(name)" }
}

struct KubeServiceRow: Identifiable, Hashable, Sendable {
    var name: String
    var namespace: String
    var type: String
    var clusterIP: String
    var ports: String
    var age: String
    var id: String { "\(namespace)/\(name)" }
    var isHeadless: Bool { clusterIP == "None" }
}

struct KubeConfigMapRow: Identifiable, Hashable, Sendable {
    var name: String
    var namespace: String
    var keys: [String]
    var data: [String: String]
    var age: String
    var id: String { "\(namespace)/\(name)" }
    var keyCount: Int { keys.count }
}

struct KubeSecretRow: Identifiable, Hashable, Sendable {
    var name: String
    var namespace: String
    var type: String
    var keys: [String]
    var data: [String: String]
    var age: String
    var id: String { "\(namespace)/\(name)" }
    var keyCount: Int { keys.count }
}

struct KubeIngressRow: Identifiable, Hashable, Sendable {
    var name: String
    var namespace: String
    var hosts: String
    var address: String
    var paths: String
    var age: String
    var id: String { "\(namespace)/\(name)" }
}

enum KubeSecretDecode {
    static func decode(_ data: [String: String]) -> [LabelPair] {
        data.keys.sorted().map { key in
            let value = data[key] ?? ""
            guard let decoded = Data(base64Encoded: value) else {
                return LabelPair(key: key, value: value)
            }
            let text = String(data: decoded, encoding: .utf8) ?? "\(decoded.count) bytes binary"
            return LabelPair(key: key, value: text)
        }
    }
}

enum KubeRowMapper {
    static func podPhase(_ phase: String?, statuses: [KubeContainerStatus]) -> PodPhase {
        if statuses.contains(where: { $0.state?.waiting?.reason == "CrashLoopBackOff" }) {
            return .crashLoopBackOff
        }
        switch phase {
        case "Running": return .running
        case "Pending": return .pending
        case "Succeeded": return .completed
        default: return .crashLoopBackOff
        }
    }

    static func pods(_ list: KubePodList) -> [Pod] {
        (list.items ?? []).compactMap { pod in
            guard let name = pod.metadata?.name else { return nil }
            let statuses = pod.status?.containerStatuses ?? []
            let ready = statuses.filter { $0.ready == true }.count
            let restarts = statuses.reduce(0) { $0 + ($1.restartCount ?? 0) }
            let specContainers = (pod.spec?.containers ?? [])
                .compactMap(\.name)
                .filter { !$0.isEmpty }
            let statusContainers = statuses
                .compactMap(\.name)
                .filter { !$0.isEmpty }
            return Pod(
                name: name, namespace: pod.metadata?.namespace ?? "default",
                phase: podPhase(pod.status?.phase, statuses: statuses),
                ready: "\(ready)/\(max(statuses.count, 1))", restarts: restarts,
                age: DockerFormat.relative(iso: pod.metadata?.creationTimestamp),
                containers: specContainers.isEmpty ? statusContainers : specContainers
            )
        }
    }

    static func deployments(_ list: KubeDeploymentList) -> [KubeDeploymentRow] {
        (list.items ?? []).compactMap { dep in
            guard let name = dep.metadata?.name else { return nil }
            let desired = dep.spec?.replicas ?? 0
            let ready = dep.status?.readyReplicas ?? 0
            return KubeDeploymentRow(
                name: name, namespace: dep.metadata?.namespace ?? "default",
                ready: "\(ready)/\(desired)", upToDate: dep.status?.updatedReplicas ?? 0,
                available: dep.status?.availableReplicas ?? 0,
                age: DockerFormat.relative(iso: dep.metadata?.creationTimestamp),
                replicas: desired
            )
        }
    }

    static func services(_ list: KubeServiceList) -> [KubeServiceRow] {
        (list.items ?? []).compactMap { svc in
            guard let name = svc.metadata?.name else { return nil }
            let clusterIP = svc.spec?.clusterIP ?? "—"
            let ports = (svc.spec?.ports ?? []).map { port in
                "\(port.port ?? 0)/\(port.protocol ?? "TCP")"
            }.joined(separator: ", ")
            return KubeServiceRow(
                name: name, namespace: svc.metadata?.namespace ?? "default",
                type: svc.spec?.type ?? "ClusterIP", clusterIP: clusterIP, ports: ports,
                age: DockerFormat.relative(iso: svc.metadata?.creationTimestamp)
            )
        }
    }

    static func namespaces(_ list: KubeNamespaceList) -> [String] {
        (list.items ?? []).compactMap { $0.metadata?.name }
    }

    static func configMaps(_ list: KubeConfigMapList) -> [KubeConfigMapRow] {
        (list.items ?? []).compactMap { item in
            guard let name = item.metadata?.name else { return nil }
            let data = item.data ?? [:]
            return KubeConfigMapRow(
                name: name, namespace: item.metadata?.namespace ?? "default",
                keys: data.keys.sorted(), data: data,
                age: DockerFormat.relative(iso: item.metadata?.creationTimestamp)
            )
        }
    }

    static func secrets(_ list: KubeSecretList) -> [KubeSecretRow] {
        (list.items ?? []).compactMap { item in
            guard let name = item.metadata?.name else { return nil }
            let data = item.data ?? [:]
            return KubeSecretRow(
                name: name, namespace: item.metadata?.namespace ?? "default",
                type: item.type ?? "Opaque", keys: data.keys.sorted(), data: data,
                age: DockerFormat.relative(iso: item.metadata?.creationTimestamp)
            )
        }
    }

    static func ingresses(_ list: KubeIngressList) -> [KubeIngressRow] {
        (list.items ?? []).compactMap { item in
            guard let name = item.metadata?.name else { return nil }
            let rules = item.spec?.rules ?? []
            let hosts = rules.compactMap(\.host).filter { !$0.isEmpty }.joined(separator: ", ")
            let paths = rules.flatMap { rule in
                (rule.http?.paths ?? []).map { path in
                    let route = path.path?.isEmpty == false ? path.path! : "/"
                    let service = path.backend?.service?.name ?? "—"
                    return "\(route) → \(service)"
                }
            }.joined(separator: ", ")
            let addresses = (item.status?.loadBalancer?.ingress ?? [])
                .compactMap { $0.ip ?? $0.hostname }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
            return KubeIngressRow(
                name: name, namespace: item.metadata?.namespace ?? "default",
                hosts: hosts.isEmpty ? "*" : hosts,
                address: addresses.isEmpty ? "—" : addresses,
                paths: paths.isEmpty ? "—" : paths,
                age: DockerFormat.relative(iso: item.metadata?.creationTimestamp)
            )
        }
    }
}
