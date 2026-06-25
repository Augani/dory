import Foundation

enum MockData {
    static let containers: [Container] = [
        Container(id: "c1", name: "postgres-db", image: "postgres:16", status: .running, cpuPercent: 2.4, memoryDisplay: "128 MB", memoryLimitDisplay: "2 GB", memoryFraction: 0.06, ports: "5432→5432", uptime: "3h 12m", created: "3 hours ago", ipAddress: "192.168.215.4", domain: "postgres-db.dory.local", command: "postgres", restartPolicy: "unless-stopped", labels: ["com.docker.compose.project": "dory-stack", "com.docker.compose.service": "db"], memoryBytes: 134_217_728),
        Container(id: "c2", name: "redis-cache", image: "redis:7-alpine", status: .running, cpuPercent: 0.8, memoryDisplay: "24 MB", memoryLimitDisplay: "512 MB", memoryFraction: 0.05, ports: "6379→6379", uptime: "3h 12m", created: "3 hours ago", ipAddress: "192.168.215.5", domain: "redis-cache.dory.local", command: "redis-server", restartPolicy: "unless-stopped", labels: ["com.docker.compose.project": "dory-stack", "com.docker.compose.service": "cache"], memoryBytes: 25_165_824),
        Container(id: "c3", name: "web-api", image: "dory/web-api:latest", status: .running, cpuPercent: 5.1, memoryDisplay: "312 MB", memoryLimitDisplay: "1 GB", memoryFraction: 0.30, ports: "3000→3000", uptime: "42m", created: "42 minutes ago", ipAddress: "192.168.215.6", domain: "web-api.dory.local", command: "node server.js", restartPolicy: "on-failure", labels: ["com.docker.compose.project": "dory-stack", "com.docker.compose.service": "web"], memoryBytes: 327_155_712),
        Container(id: "c4", name: "nginx-proxy", image: "nginx:alpine", status: .running, cpuPercent: 0.3, memoryDisplay: "18 MB", memoryLimitDisplay: "256 MB", memoryFraction: 0.07, ports: "80,443", uptime: "3h 10m", created: "3 hours ago", ipAddress: "192.168.215.7", domain: "nginx-proxy.dory.local", command: "nginx -g 'daemon off;'", restartPolicy: "always", memoryBytes: 18_874_368),
        Container(id: "c5", name: "worker", image: "dory/worker:latest", status: .stopped, cpuPercent: 0.0, memoryDisplay: "0 MB", memoryLimitDisplay: "1 GB", memoryFraction: 0.0, ports: "—", uptime: "—", created: "2 hours ago", ipAddress: "—", domain: "worker.dory.local", command: "python worker.py", restartPolicy: "on-failure"),
        Container(id: "c6", name: "mailhog", image: "mailhog/mailhog", status: .running, cpuPercent: 0.1, memoryDisplay: "12 MB", memoryLimitDisplay: "128 MB", memoryFraction: 0.09, ports: "8025→8025", uptime: "3h 12m", created: "3 hours ago", ipAddress: "192.168.215.8", domain: "mailhog.dory.local", command: "MailHog", restartPolicy: "unless-stopped", memoryBytes: 12_582_912),
    ]

    static let images: [DockerImage] = [
        DockerImage(repository: "postgres", tag: "16", imageID: "3f1a2b9c", size: "438 MB", created: "2 weeks ago", usedByCount: 2, sizeBytes: 459_276_288, createdEpoch: 1_717_700_000),
        DockerImage(repository: "redis", tag: "7-alpine", imageID: "9c4e1f02", size: "41 MB", created: "2 weeks ago", usedByCount: 1, sizeBytes: 42_991_616, createdEpoch: 1_717_700_001),
        DockerImage(repository: "nginx", tag: "alpine", imageID: "a1b2c3d4", size: "48 MB", created: "1 month ago", usedByCount: 1, sizeBytes: 50_331_648, createdEpoch: 1_716_300_000),
        DockerImage(repository: "node", tag: "20", imageID: "77ef33aa", size: "1.1 GB", created: "3 weeks ago", usedByCount: 1, sizeBytes: 1_181_116_006, createdEpoch: 1_717_100_000),
        DockerImage(repository: "dory/web-api", tag: "latest", imageID: "b8d9e0f1", size: "256 MB", created: "42 min ago", usedByCount: 1, sizeBytes: 268_435_456, createdEpoch: 1_718_899_000),
        DockerImage(repository: "mailhog/mailhog", tag: "latest", imageID: "2cc8aa90", size: "18 MB", created: "1 month ago", usedByCount: 1, sizeBytes: 18_874_368, createdEpoch: 1_716_300_001),
        DockerImage(repository: "ubuntu", tag: "24.04", imageID: "5a6b7c8d", size: "78 MB", created: "2 months ago", usedByCount: 0, sizeBytes: 81_788_928, createdEpoch: 1_713_700_000),
    ]

    static let volumes: [Volume] = [
        Volume(name: "postgres-data", size: "412 MB", driver: "local", usedBy: "postgres-db", created: "3 hours ago"),
        Volume(name: "redis-data", size: "8 MB", driver: "local", usedBy: "redis-cache", created: "3 hours ago"),
        Volume(name: "app-uploads", size: "1.2 GB", driver: "local", usedBy: "web-api", created: "2 days ago"),
        Volume(name: "pgadmin-data", size: "24 MB", driver: "local", usedBy: "—", created: "1 week ago"),
    ]

    static let networks: [DoryNetwork] = [
        DoryNetwork(name: "dory-default", driver: "bridge", scope: "local", subnet: "192.168.215.0/24", containerCount: 5),
        DoryNetwork(name: "web-tier", driver: "bridge", scope: "local", subnet: "192.168.220.0/24", containerCount: 2),
        DoryNetwork(name: "db-tier", driver: "bridge", scope: "local", subnet: "192.168.221.0/24", containerCount: 1),
        DoryNetwork(name: "bridge", driver: "bridge", scope: "local", subnet: "172.17.0.0/16", containerCount: 0),
        DoryNetwork(name: "host", driver: "host", scope: "local", subnet: "—", containerCount: 0),
    ]

    static let pods: [Pod] = [
        Pod(name: "web-7d9f8b6c4-xk2lp", namespace: "default", phase: .running, ready: "1/1", restarts: 0, age: "42m"),
        Pod(name: "web-7d9f8b6c4-q9wmr", namespace: "default", phase: .running, ready: "1/1", restarts: 0, age: "42m"),
        Pod(name: "redis-0", namespace: "cache", phase: .running, ready: "1/1", restarts: 0, age: "2h"),
        Pod(name: "postgres-0", namespace: "data", phase: .running, ready: "1/1", restarts: 1, age: "2h"),
        Pod(name: "migrate-l8x2c", namespace: "default", phase: .completed, ready: "0/1", restarts: 0, age: "40m"),
        Pod(name: "worker-d4f9z", namespace: "jobs", phase: .pending, ready: "0/1", restarts: 0, age: "5m"),
    ]

    static let deployments: [KubeDeploymentRow] = [
        KubeDeploymentRow(name: "web", namespace: "default", ready: "2/2", upToDate: 2, available: 2, age: "42m", replicas: 2),
        KubeDeploymentRow(name: "redis", namespace: "cache", ready: "1/1", upToDate: 1, available: 1, age: "2h", replicas: 1),
        KubeDeploymentRow(name: "worker", namespace: "jobs", ready: "0/1", upToDate: 1, available: 0, age: "5m", replicas: 1),
    ]

    static let kubeServices: [KubeServiceRow] = [
        KubeServiceRow(name: "web", namespace: "default", type: "ClusterIP", clusterIP: "10.43.0.12", ports: "80/TCP", age: "42m"),
        KubeServiceRow(name: "redis", namespace: "cache", type: "ClusterIP", clusterIP: "10.43.0.40", ports: "6379/TCP", age: "2h"),
    ]

    static let configMaps: [KubeConfigMapRow] = [
        KubeConfigMapRow(name: "web-config", namespace: "default", keys: ["LOG_LEVEL", "PUBLIC_URL"],
                         data: ["LOG_LEVEL": "info", "PUBLIC_URL": "https://web.default.k8s.dory.local"], age: "42m"),
        KubeConfigMapRow(name: "worker-flags", namespace: "jobs", keys: ["QUEUE", "BATCH_SIZE"],
                         data: ["QUEUE": "emails", "BATCH_SIZE": "25"], age: "5m"),
    ]

    static let secrets: [KubeSecretRow] = [
        KubeSecretRow(name: "web-secrets", namespace: "default", type: "Opaque", keys: ["DATABASE_URL", "SESSION_KEY"],
                      data: ["DATABASE_URL": "cG9zdGdyZXM6Ly9wb3N0Z3Jlcy0wLmRhdGE6NTQzMi9hcHA=", "SESSION_KEY": "c2VjcmV0"], age: "42m"),
        KubeSecretRow(name: "registry-pull", namespace: "default", type: "kubernetes.io/dockerconfigjson", keys: [".dockerconfigjson"],
                      data: [".dockerconfigjson": "e30="], age: "2h"),
    ]

    static let ingresses: [KubeIngressRow] = [
        KubeIngressRow(name: "web", namespace: "default", hosts: "web.dory.local", address: "127.0.0.1", paths: "/ → web", age: "42m"),
        KubeIngressRow(name: "api", namespace: "default", hosts: "api.dory.local", address: "127.0.0.1", paths: "/v1 → web", age: "41m"),
    ]

    static let machines: [Machine] = [
        Machine(name: "ubuntu", distro: "Ubuntu", version: "24.04 LTS", status: .running, cpuPercent: 1.2, memoryDisplay: "420 MB", ip: "ubuntu.dory.local", letter: "U", badgeHex: 0xE95420),
        Machine(name: "debian", distro: "Debian", version: "12 Bookworm", status: .running, cpuPercent: 0.4, memoryDisplay: "180 MB", ip: "debian.dory.local", letter: "D", badgeHex: 0xA80030),
        Machine(name: "fedora", distro: "Fedora", version: "40", status: .stopped, cpuPercent: 0.0, memoryDisplay: "0 MB", ip: "fedora.dory.local", letter: "F", badgeHex: 0x3C6EB4),
        Machine(name: "arch", distro: "Arch Linux", version: "rolling", status: .running, cpuPercent: 0.2, memoryDisplay: "96 MB", ip: "arch.dory.local", letter: "A", badgeHex: 0x1793D1),
        Machine(name: "alpine", distro: "Alpine", version: "3.20", status: .running, cpuPercent: 0.1, memoryDisplay: "28 MB", ip: "alpine.dory.local", letter: "A", badgeHex: 0x0D597F),
    ]

    static let sparkHeights: [Double] = [30, 42, 38, 55, 48, 62, 44, 70, 58, 66, 52, 74, 60, 80, 68, 55, 72, 64, 78, 60, 68, 74, 82, 70]

    static func logs(for container: Container) -> [LogLine] {
        [
            LogLine(timestamp: "12:04:31.221", level: .info, message: "Server listening on \(container.ports)"),
            LogLine(timestamp: "12:04:31.244", level: .info, message: "Connected to database in 18ms"),
            LogLine(timestamp: "12:04:33.901", level: .info, message: "GET /health 200 · 2ms"),
            LogLine(timestamp: "12:05:02.118", level: .warn, message: "Slow query detected (412ms)"),
            LogLine(timestamp: "12:05:12.557", level: .info, message: "POST /api/v1/users 201 · 41ms"),
            LogLine(timestamp: "12:05:48.030", level: .error, message: "Upstream redis timeout — retrying"),
            LogLine(timestamp: "12:05:48.531", level: .info, message: "Reconnected to redis-cache"),
            LogLine(timestamp: "12:06:10.774", level: .debug, message: "Cache hit ratio 0.94 over 1m"),
        ]
    }

    static func env(for container: Container) -> [EnvVar] {
        let port = container.ports.split(separator: "→").first.map(String.init) ?? container.ports
        return [
            EnvVar(key: "NODE_ENV", value: "production"),
            EnvVar(key: "PORT", value: port),
            EnvVar(key: "DATABASE_URL", value: "postgres://postgres-db.dory.local:5432/app"),
            EnvVar(key: "REDIS_URL", value: "redis://redis-cache.dory.local:6379"),
            EnvVar(key: "LOG_LEVEL", value: "info"),
            EnvVar(key: "TZ", value: "UTC"),
        ]
    }
}

struct MockRuntime: ContainerRuntime {
    let kind: RuntimeKind = .mock

    nonisolated init() {}

    func snapshot() async throws -> RuntimeSnapshot {
        RuntimeSnapshot(containers: MockData.containers, images: MockData.images, volumes: MockData.volumes, networks: MockData.networks, pods: MockData.pods, machines: MockData.machines, engineRunning: true, engineVersion: "1.4.0")
    }

    func start(containerID: String) async throws {}
    func stop(containerID: String) async throws {}
    func restart(containerID: String) async throws {}
    func remove(containerID: String) async throws {}
    func pull(image: String) async throws {}
    func create(_ spec: ContainerSpec) async throws -> String { "mock-\(spec.name)" }
    func exec(containerID: String, command: [String]) async throws -> ExecResult { ExecResult(exitCode: 0, output: "") }
    func createNetwork(name: String, labels: [String: String]) async throws {}
    func removeNetwork(name: String) async throws {}
    func removeVolume(name: String) async throws {}
    func logs(containerID: String) async throws -> [LogLine] {
        guard let c = MockData.containers.first(where: { $0.id == containerID }) else { return [] }
        return MockData.logs(for: c)
    }
    func env(containerID: String) async throws -> [EnvVar] {
        guard let c = MockData.containers.first(where: { $0.id == containerID }) else { return [] }
        return MockData.env(for: c)
    }
}
