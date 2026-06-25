import Foundation

struct DockerPort: Decodable, Sendable {
    var privatePort: Int?
    var publicPort: Int?
    var type: String?
    var ip: String?
    enum CodingKeys: String, CodingKey {
        case privatePort = "PrivatePort"
        case publicPort = "PublicPort"
        case type = "Type"
        case ip = "IP"
    }
}

struct DockerNetworkSettingsSummary: Decodable, Sendable {
    var networks: [String: DockerEndpointSettings]?
    enum CodingKeys: String, CodingKey { case networks = "Networks" }
}

struct DockerContainerMountSummary: Decodable, Sendable {
    var type: String?
    var name: String?
    var source: String?
    var destination: String?
    var mode: String?
    var rw: Bool?

    enum CodingKeys: String, CodingKey {
        case type = "Type", name = "Name", source = "Source", destination = "Destination"
        case mode = "Mode", rw = "RW"
    }

    var containerMount: ContainerMount? {
        guard let destination, !destination.isEmpty else { return nil }
        let rawType = type?.lowercased() ?? "volume"
        let sourceValue = rawType == "volume" ? (name ?? source) : source
        return ContainerMount(
            type: rawType,
            source: sourceValue,
            target: destination,
            readOnly: rw == false || mode?.split(separator: ",").contains("ro") == true
        )
    }
}

struct DockerContainerSummary: Decodable, Sendable {
    var id: String
    var names: [String]?
    var image: String
    var command: String?
    var created: Int?
    var state: String?
    var status: String?
    var ports: [DockerPort]?
    var networkSettings: DockerNetworkSettingsSummary?
    var labels: [String: String]?
    var mounts: [DockerContainerMountSummary]?
    enum CodingKeys: String, CodingKey {
        case id = "Id", names = "Names", image = "Image", command = "Command"
        case created = "Created", state = "State", status = "Status"
        case ports = "Ports", networkSettings = "NetworkSettings", labels = "Labels", mounts = "Mounts"
    }
}

struct DockerImageSummary: Decodable, Sendable {
    var id: String
    var repoTags: [String]?
    var size: Int64?
    var created: Int?
    var containers: Int?
    var labels: [String: String]?
    enum CodingKeys: String, CodingKey {
        case id = "Id", repoTags = "RepoTags", size = "Size", created = "Created", containers = "Containers"
        case labels = "Labels"
    }
}

nonisolated struct DockerVolumeList: Decodable, Sendable {
    var volumes: [DockerVolume]?
    enum CodingKeys: String, CodingKey { case volumes = "Volumes" }
}

struct DockerVolume: Decodable, Sendable {
    var name: String
    var driver: String?
    var createdAt: String?
    var labels: [String: String]?
    var options: [String: String]?
    enum CodingKeys: String, CodingKey {
        case name = "Name", driver = "Driver", createdAt = "CreatedAt", labels = "Labels", options = "Options"
    }
}

struct DockerIPAMConfig: Decodable, Sendable {
    var subnet: String?
    var gateway: String?
    enum CodingKeys: String, CodingKey { case subnet = "Subnet", gateway = "Gateway" }
}

struct DockerIPAM: Decodable, Sendable {
    var config: [DockerIPAMConfig]?
    enum CodingKeys: String, CodingKey { case config = "Config" }
}

struct DockerNetwork: Decodable, Sendable {
    var name: String
    var id: String?
    var driver: String?
    var scope: String?
    var ipam: DockerIPAM?
    var containers: [String: DockerNetworkContainer]?
    var created: String?
    var attachable: Bool?
    var options: [String: String]?
    var isInternal: Bool?
    var labels: [String: String]?
    enum CodingKeys: String, CodingKey {
        case name = "Name", id = "Id", driver = "Driver", scope = "Scope", ipam = "IPAM"
        case containers = "Containers", created = "Created", attachable = "Attachable"
        case options = "Options", isInternal = "Internal", labels = "Labels"
    }
}

struct DockerNetworkContainer: Decodable, Sendable {
    var name: String?
    var ipv4Address: String?
    enum CodingKeys: String, CodingKey { case name = "Name", ipv4Address = "IPv4Address" }
}

nonisolated struct DockerVersion: Decodable, Sendable {
    var version: String?
    var apiVersion: String?
    enum CodingKeys: String, CodingKey { case version = "Version", apiVersion = "ApiVersion" }
}

nonisolated struct DockerCPUUsage: Decodable, Sendable {
    var totalUsage: Int64?
    enum CodingKeys: String, CodingKey { case totalUsage = "total_usage" }
}

nonisolated struct DockerCPUStats: Decodable, Sendable {
    var cpuUsage: DockerCPUUsage?
    var systemCPUUsage: Int64?
    var onlineCPUs: Int?
    enum CodingKeys: String, CodingKey {
        case cpuUsage = "cpu_usage", systemCPUUsage = "system_cpu_usage", onlineCPUs = "online_cpus"
    }
}

nonisolated struct DockerMemoryStats: Decodable, Sendable {
    var usage: Int64?
    var limit: Int64?
    enum CodingKeys: String, CodingKey { case usage = "usage", limit = "limit" }
}

nonisolated struct DockerStats: Decodable, Sendable {
    var cpuStats: DockerCPUStats?
    var precpuStats: DockerCPUStats?
    var memoryStats: DockerMemoryStats?
    enum CodingKeys: String, CodingKey {
        case cpuStats = "cpu_stats", precpuStats = "precpu_stats", memoryStats = "memory_stats"
    }

    var cpuPercent: Double {
        guard let cpu = cpuStats?.cpuUsage?.totalUsage,
              let preCPU = precpuStats?.cpuUsage?.totalUsage,
              let system = cpuStats?.systemCPUUsage,
              let preSystem = precpuStats?.systemCPUUsage else { return 0 }
        let cpuDelta = Double(cpu - preCPU)
        let systemDelta = Double(system - preSystem)
        let cpus = Double(cpuStats?.onlineCPUs ?? 1)
        guard systemDelta > 0, cpuDelta > 0 else { return 0 }
        return (cpuDelta / systemDelta) * cpus * 100
    }
}

struct DockerInspect: Decodable, Sendable {
    var config: DockerInspectConfig?
    var state: DockerInspectState?
    enum CodingKeys: String, CodingKey {
        case config = "Config", state = "State"
    }
}

struct DockerInspectConfig: Decodable, Sendable {
    var env: [String]?
    var cmd: [String]?
    enum CodingKeys: String, CodingKey { case env = "Env", cmd = "Cmd" }
}

struct DockerInspectState: Decodable, Sendable {
    var startedAt: String?
    var running: Bool?
    var exitCode: Int?
    enum CodingKeys: String, CodingKey { case startedAt = "StartedAt", running = "Running", exitCode = "ExitCode" }
}

struct DockerEmptyValue: Decodable, Sendable {}

struct DockerImageInspectConfig: Decodable, Sendable {
    var env: [String]?
    var cmd: [String]?
    var entrypoint: [String]?
    var workingDir: String?
    var exposedPorts: [String: DockerEmptyValue]?
    var labels: [String: String]?
    enum CodingKeys: String, CodingKey {
        case env = "Env", cmd = "Cmd", entrypoint = "Entrypoint", workingDir = "WorkingDir"
        case exposedPorts = "ExposedPorts", labels = "Labels"
    }
}

struct DockerImageInspect: Decodable, Sendable {
    var id: String?
    var repoTags: [String]?
    var repoDigests: [String]?
    var created: String?
    var architecture: String?
    var os: String?
    var size: Int64?
    var config: DockerImageInspectConfig?
    enum CodingKeys: String, CodingKey {
        case id = "Id", repoTags = "RepoTags", repoDigests = "RepoDigests", created = "Created"
        case architecture = "Architecture", os = "Os", size = "Size", config = "Config"
    }
}
