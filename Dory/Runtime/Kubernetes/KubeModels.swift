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

struct KubeDeploymentRow: Identifiable, Hashable, Sendable {
    var name: String
    var namespace: String
    var ready: String
    var upToDate: Int
    var available: Int
    var age: String
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
}

enum KubeRowMapper {
    static func podPhase(_ phase: String?, statuses: [KubeContainerStatus]) -> PodPhase {
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
            return Pod(
                name: name, namespace: pod.metadata?.namespace ?? "default",
                phase: podPhase(pod.status?.phase, statuses: statuses),
                ready: "\(ready)/\(max(statuses.count, 1))", restarts: restarts,
                age: DockerFormat.relative(iso: pod.metadata?.creationTimestamp)
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
                age: DockerFormat.relative(iso: dep.metadata?.creationTimestamp)
            )
        }
    }

    static func services(_ list: KubeServiceList) -> [KubeServiceRow] {
        (list.items ?? []).compactMap { svc in
            guard let name = svc.metadata?.name else { return nil }
            let clusterIP = svc.spec?.clusterIP ?? ""
            guard clusterIP != "None" else { return nil }
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
}
