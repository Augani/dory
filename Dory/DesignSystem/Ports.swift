import Foundation

struct PublishedPort: Equatable, Identifiable, Sendable {
    let hostPort: Int
    let containerPort: Int
    let proto: String
    var id: String { "\(hostPort)/\(proto)" }
    var label: String { ":\(hostPort)" }
}

func parsePublishedPorts(_ raw: String) -> [PublishedPort] {
    var seen = Set<String>()
    var result: [PublishedPort] = []
    for entry in raw.split(separator: ",") {
        let part = entry.trimmingCharacters(in: .whitespaces)
        guard let arrow = part.range(of: "->") else { continue }
        let lhs = part[..<arrow.lowerBound]
        let rhs = part[arrow.upperBound...]
        guard let hostColon = lhs.lastIndex(of: ":"),
              let hostPort = Int(lhs[lhs.index(after: hostColon)...]) else { continue }
        let rhsParts = rhs.split(separator: "/")
        guard let containerPort = Int(rhsParts.first ?? "") else { continue }
        let proto = rhsParts.count > 1 ? String(rhsParts[1]) : "tcp"
        let key = "\(hostPort)/\(proto)"
        guard !seen.contains(key) else { continue }
        seen.insert(key)
        result.append(PublishedPort(hostPort: hostPort, containerPort: containerPort, proto: proto))
    }
    return result.sorted { $0.hostPort < $1.hostPort }
}
