import Foundation

nonisolated struct PublishedPort: Equatable, Identifiable, Sendable {
    let hostPort: Int
    let containerPort: Int
    let proto: String
    var id: String { "\(hostPort)/\(proto)" }
    var label: String { ":\(hostPort)" }
}

nonisolated struct ContainerPortMapping: Equatable, Sendable {
    var hostIP: String?
    var hostPort: Int?
    var containerPort: Int
    var proto: String

    var dockerDisplay: String {
        let target = "\(containerPort)/\(proto)"
        guard let hostPort else { return target }
        return "\((hostIP?.isEmpty == false ? hostIP : nil) ?? "0.0.0.0"):\(hostPort)->\(target)"
    }

    var containerSpec: String {
        let target = proto == "tcp" ? "\(containerPort)" : "\(containerPort)/\(proto)"
        guard let hostPort else { return target }
        if let hostIP, !hostIP.isEmpty { return "\(hostIP):\(hostPort):\(target)" }
        return "\(hostPort):\(target)"
    }
}

nonisolated enum ContainerPortDisplay {
    static func mappings(_ raw: String) -> [ContainerPortMapping] {
        guard raw != "—", !raw.isEmpty else { return [] }
        return raw.split(separator: ",").compactMap { parseOne($0.trimmingCharacters(in: .whitespaces)) }
    }

    static func dockerDisplay(hostIP: String? = nil, hostPort: Int?, containerPort: Int, proto: String? = nil) -> String {
        ContainerPortMapping(
            hostIP: hostIP,
            hostPort: hostPort,
            containerPort: containerPort,
            proto: normalizedProto(proto)
        ).dockerDisplay
    }

    private static func parseOne(_ part: String) -> ContainerPortMapping? {
        guard !part.isEmpty else { return nil }
        if let range = part.range(of: "->") ?? part.range(of: "→") {
            let left = String(part[..<range.lowerBound])
            let right = String(part[range.upperBound...])
            guard let target = targetPort(right) else { return nil }
            let host = hostEndpoint(left)
            guard let hostPort = host.port else { return nil }
            return ContainerPortMapping(
                hostIP: host.ip,
                hostPort: hostPort,
                containerPort: target.port,
                proto: target.proto
            )
        }
        guard let target = targetPort(part) else { return nil }
        return ContainerPortMapping(hostIP: nil, hostPort: nil, containerPort: target.port, proto: target.proto)
    }

    private static func hostEndpoint(_ raw: String) -> (ip: String?, port: Int?) {
        if let colon = raw.lastIndex(of: ":") {
            let ip = String(raw[..<colon])
            let port = Int(raw[raw.index(after: colon)...])
            return (ip.isEmpty ? nil : ip, port)
        }
        return (nil, Int(raw))
    }

    private static func targetPort(_ raw: String) -> (port: Int, proto: String)? {
        let parts = raw.split(separator: "/", maxSplits: 1).map(String.init)
        guard let first = parts.first, let port = Int(first) else { return nil }
        let proto = parts.count > 1 ? parts[1] : nil
        return (port, normalizedProto(proto))
    }

    private static func normalizedProto(_ raw: String?) -> String {
        let proto = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return proto.isEmpty ? "tcp" : proto
    }
}

nonisolated func parsePublishedPorts(_ raw: String) -> [PublishedPort] {
    var seen = Set<String>()
    var result: [PublishedPort] = []
    for mapping in ContainerPortDisplay.mappings(raw) {
        guard let hostPort = mapping.hostPort else { continue }
        let proto = mapping.proto
        let key = "\(hostPort)/\(proto)"
        guard !seen.contains(key) else { continue }
        seen.insert(key)
        result.append(PublishedPort(hostPort: hostPort, containerPort: mapping.containerPort, proto: proto))
    }
    return result.sorted { $0.hostPort < $1.hostPort }
}
