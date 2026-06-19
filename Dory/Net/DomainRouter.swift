import Foundation

/// Maps Dory's `*.dory.local` domains to container IP addresses. This is the shared routing table
/// used by both the local DNS resolver (host → IP) and the reverse proxy (host → backend). The
/// resolver/proxy listeners bind privileged ports (53/80/443) and modify system resolver config,
/// so they are activated only via explicit user consent — this router itself is pure and side
/// effect free.
struct DomainRouter: Sendable {
    var suffix: String = "dory.local"

    func routes(from containers: [Container]) -> [String: String] {
        var table: [String: String] = [:]
        for container in containers where container.status == .running {
            let host = container.domain.isEmpty ? "\(container.name).\(suffix)" : container.domain
            guard host.hasSuffix(suffix), container.ipAddress != "—", !container.ipAddress.isEmpty else { continue }
            table[host.lowercased()] = container.ipAddress
        }
        return table
    }

    func resolve(_ host: String, in containers: [Container]) -> String? {
        let normalized = host.lowercased().hasSuffix(".") ? String(host.dropLast()).lowercased() : host.lowercased()
        return routes(from: containers)[normalized]
    }

    func owns(_ host: String) -> Bool {
        host.lowercased().hasSuffix(suffix)
    }
}
