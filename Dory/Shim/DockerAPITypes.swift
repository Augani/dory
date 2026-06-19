import Foundation

struct DockerVersionOut: Encodable, Sendable {
    let Version: String, ApiVersion: String, MinAPIVersion: String
    let Os: String, Arch: String, KernelVersion: String
    let GoVersion: String, GitCommit: String, BuildTime: String
}

struct DockerInfoOut: Encodable, Sendable {
    let ID: String, Name: String
    let Containers: Int, ContainersRunning: Int, ContainersPaused: Int, ContainersStopped: Int
    let Images: Int, NCPU: Int
    let MemTotal: Int64
    let ServerVersion: String, OperatingSystem: String, OSType: String, Architecture: String, Driver: String
}

struct DockerPortOut: Encodable, Sendable {
    let PrivatePort: Int
    let PublicPort: Int?
    let portType: String
    enum CodingKeys: String, CodingKey {
        case PrivatePort, PublicPort, portType = "Type"
    }
}

struct DockerContainerOut: Encodable, Sendable {
    let Id: String
    let Names: [String]
    let Image: String, ImageID: String, Command: String
    let Created: Int
    let State: String, Status: String
    let Ports: [DockerPortOut]
    let Labels: [String: String]
}

struct DockerImageOut: Encodable, Sendable {
    let Id: String
    let RepoTags: [String]
    let Containers: Int
}

struct DockerErrorOut: Encodable, Sendable {
    let message: String
}

struct DockerNetworkOut: Encodable, Sendable {
    let Id: String
    let Name: String
    let Driver: String
    let Scope: String
}

struct DockerVolumeOut: Encodable, Sendable {
    let Name: String
    let Driver: String
    let Mountpoint: String
}

struct DockerVolumeListOut: Encodable, Sendable {
    let Volumes: [DockerVolumeOut]
}

struct DockerInspectStateOut: Encodable, Sendable {
    let Running: Bool
    let Status: String
}

struct DockerInspectConfigOut: Encodable, Sendable {
    let Image: String
    let Cmd: [String]?
}

struct DockerHostBindingOut: Encodable, Sendable {
    let HostIp: String
    let HostPort: String
}

struct DockerInspectNetOut: Encodable, Sendable {
    let IPAddress: String
    let Ports: [String: [DockerHostBindingOut]]
}

struct DockerHostConfigOut: Encodable, Sendable {
    let NetworkMode: String
}

struct DockerInspectOut: Encodable, Sendable {
    let Id: String
    let Name: String
    let Image: String
    let Created: String
    let State: DockerInspectStateOut
    let Config: DockerInspectConfigOut
    let NetworkSettings: DockerInspectNetOut
    let HostConfig: DockerHostConfigOut
}

// MARK: Incoming request bodies (docker create / network create)

struct DockerCreateRequest: Decodable, Sendable {
    var Image: String?
    var Cmd: [String]?
    var Env: [String]?
    var Labels: [String: String]?
    var HostConfig: DockerCreateHostConfig?

    func spec(name: String?) -> ContainerSpec {
        var environment: [String: String] = [:]
        for entry in Env ?? [] {
            if let eq = entry.firstIndex(of: "=") {
                environment[String(entry[entry.startIndex..<eq])] = String(entry[entry.index(after: eq)...])
            }
        }
        var ports: [String] = []
        for (key, bindings) in HostConfig?.PortBindings ?? [:] {
            let containerPort = key.split(separator: "/").first.map(String.init) ?? key
            if let binding = bindings?.first, let host = binding.HostPort, !host.isEmpty {
                ports.append("\(host):\(containerPort)")
            } else {
                ports.append(containerPort)
            }
        }
        return ContainerSpec(
            name: name?.isEmpty == false ? name! : "dory-\(UUID().uuidString.prefix(12))",
            image: Image ?? "",
            command: Cmd ?? [],
            environment: environment,
            ports: ports,
            labels: Labels ?? [:],
            restart: HostConfig?.RestartPolicy?.Name
        )
    }
}

struct DockerCreateHostConfig: Decodable, Sendable {
    var PortBindings: [String: [DockerInboundBinding]?]?
    var RestartPolicy: DockerInboundRestart?
}

struct DockerInboundBinding: Decodable, Sendable { var HostPort: String? }
struct DockerInboundRestart: Decodable, Sendable { var Name: String? }

struct DockerCreateContainerOut: Encodable, Sendable {
    let Id: String
    let Warnings: [String]
}

struct DockerNetworkCreateRequest: Decodable, Sendable {
    var Name: String
    var Labels: [String: String]?
}

struct DockerNetworkCreatedOut: Encodable, Sendable {
    let Id: String
    let Warning: String
}

struct DockerPathStat: Encodable, Sendable {
    let name: String
    let size: Int
    let mode: Int
}

struct DockerExecCreateRequest: Decodable, Sendable {
    var Cmd: [String]?
}

struct DockerExecCreatedOut: Encodable, Sendable {
    let Id: String
}

struct DockerExecInspectOut: Encodable, Sendable {
    let ExitCode: Int
    let Running: Bool
}

struct DockerEventActor: Encodable, Sendable {
    let ID: String
    let Attributes: [String: String]
}

struct DockerEventOut: Encodable, Sendable {
    let eventType: String
    let Action: String
    let Actor: DockerEventActor
    let time: Int
    let timeNano: Int64
    enum CodingKeys: String, CodingKey { case eventType = "Type", Action, Actor, time, timeNano }
}
