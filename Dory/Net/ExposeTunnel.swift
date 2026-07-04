import Foundation

struct ExposeTunnelPlan: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        case localPort(UInt16)
        case machine(name: String, port: UInt16)
    }

    enum PlanError: Error, Equatable {
        case invalidPort
        case invalidMachineName
        case invalidHostname
        case unsupportedScheme
    }

    let target: Target
    let hostname: String?
    let scheme: String

    init(target: Target, hostname: String? = nil, scheme: String = "http") throws {
        guard scheme == "http" || scheme == "https" else { throw PlanError.unsupportedScheme }
        if let hostname {
            guard Self.isValidHostname(hostname) else { throw PlanError.invalidHostname }
        }
        switch target {
        case .localPort(let port):
            guard port > 0 else { throw PlanError.invalidPort }
        case .machine(let name, let port):
            guard Self.isValidMachineName(name) else { throw PlanError.invalidMachineName }
            guard port > 0 else { throw PlanError.invalidPort }
        }
        self.target = target
        self.hostname = hostname
        self.scheme = scheme
    }

    var url: String {
        switch target {
        case .localPort(let port):
            return "\(scheme)://127.0.0.1:\(port)"
        case .machine(let name, let port):
            return "\(scheme)://\(name).dory.local:\(port)"
        }
    }

    var cloudflaredCommand: [String] {
        if let hostname {
            return ["cloudflared", "tunnel", "--hostname", hostname, "--url", url, "run"]
        }
        return ["cloudflared", "tunnel", "--url", url]
    }

    static func isValidMachineName(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 63 else { return false }
        guard value.first?.isLetter == true || value.first?.isNumber == true,
              value.last?.isLetter == true || value.last?.isNumber == true else {
            return false
        }
        return value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    static func isValidHostname(_ value: String) -> Bool {
        guard value.count <= 253, !value.hasPrefix("."), !value.hasSuffix(".") else { return false }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        return labels.allSatisfy { label in
            guard (1...63).contains(label.count),
                  label.first?.isLetter == true || label.first?.isNumber == true,
                  label.last?.isLetter == true || label.last?.isNumber == true else {
                return false
            }
            return label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }
}
