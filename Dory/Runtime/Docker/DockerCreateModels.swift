import Foundation

struct DockerEmptyObject: Encodable, Sendable {}

struct DockerPortBinding: Encodable, Sendable {
    let HostPort: String
}

struct DockerRestartPolicyBody: Encodable, Sendable {
    let Name: String
}

struct DockerHostConfigBody: Encodable, Sendable {
    let PortBindings: [String: [DockerPortBinding]]
    let NetworkMode: String?
    let RestartPolicy: DockerRestartPolicyBody?
    let Binds: [String]?
}

struct DockerCreateBody: Encodable, Sendable {
    let Image: String
    let Cmd: [String]?
    let Env: [String]
    let Labels: [String: String]
    let ExposedPorts: [String: DockerEmptyObject]
    let HostConfig: DockerHostConfigBody

    init(spec: ContainerSpec) {
        Image = spec.image
        Cmd = spec.command.isEmpty ? nil : spec.command
        Env = spec.environment.map { "\($0.key)=\($0.value)" }.sorted()
        Labels = spec.labels

        var exposed: [String: DockerEmptyObject] = [:]
        var bindings: [String: [DockerPortBinding]] = [:]
        for mapping in spec.ports {
            let (key, hostPort) = Self.parsePort(mapping)
            guard let key else { continue }
            exposed[key] = DockerEmptyObject()
            if let hostPort { bindings[key] = [DockerPortBinding(HostPort: hostPort)] }
        }
        ExposedPorts = exposed
        HostConfig = DockerHostConfigBody(
            PortBindings: bindings,
            NetworkMode: spec.networks.first,
            RestartPolicy: spec.restart.map { DockerRestartPolicyBody(Name: $0) },
            Binds: spec.volumes.isEmpty ? nil : spec.volumes
        )
    }

    static func parsePort(_ mapping: String) -> (key: String?, hostPort: String?) {
        var proto = "tcp"
        var spec = mapping
        if let slash = spec.lastIndex(of: "/") {
            proto = String(spec[spec.index(after: slash)...])
            spec = String(spec[spec.startIndex..<slash])
        }
        let parts = spec.split(separator: ":").map(String.init)
        switch parts.count {
        case 1: return ("\(parts[0])/\(proto)", nil)
        case 2: return ("\(parts[1])/\(proto)", parts[0])
        case 3: return ("\(parts[2])/\(proto)", parts[1]) // ip:host:container
        default: return (nil, nil)
        }
    }
}

struct DockerCreateResult: Decodable, Sendable {
    let id: String
    enum CodingKeys: String, CodingKey { case id = "Id" }
}

struct DockerExecCreate: Encodable, Sendable {
    let AttachStdout = true
    let AttachStderr = true
    let Cmd: [String]
}

struct DockerExecResult: Decodable, Sendable {
    let id: String
    enum CodingKeys: String, CodingKey { case id = "Id" }
}

struct DockerExecStart: Encodable, Sendable {
    let Detach = false
    let Tty = false
}

struct DockerExecInspect: Decodable, Sendable {
    let exitCode: Int?
    enum CodingKeys: String, CodingKey { case exitCode = "ExitCode" }
}

struct DockerNetworkCreate: Encodable, Sendable {
    let Name: String
    let Labels: [String: String]
}

struct DockerNetworkCreateResult: Decodable, Sendable {
    let id: String?
    enum CodingKeys: String, CodingKey { case id = "Id" }
}
