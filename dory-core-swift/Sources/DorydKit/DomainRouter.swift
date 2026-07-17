import Foundation

public struct DomainRoute: Sendable, Equatable, Hashable {
    public var hostname: String
    public var address: String
    public var port: UInt16
    public var pathPrefix: String

    public init(hostname: String, address: String, port: UInt16 = 80, pathPrefix: String = "") {
        self.hostname = hostname
        self.address = address
        self.port = port
        self.pathPrefix = pathPrefix
    }
}

public struct DomainRouter: Sendable, Equatable {
    public var suffix: String

    public init(suffix: String = "dory.local") {
        self.suffix = DomainRouter.normalize(suffix).trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    public func table(from routes: [DomainRoute]) -> [String: String] {
        var table: [String: String] = [:]
        for route in routes {
            let hostname = DomainRouter.normalize(route.hostname)
            guard owns(hostname), IPv4Address(route.address) != nil else { continue }
            table[hostname] = route.address
        }
        return table
    }

    public func resolve(_ hostname: String, in routes: [DomainRoute]) -> String? {
        table(from: routes)[DomainRouter.normalize(hostname)]
    }

    public func owns(_ hostname: String) -> Bool {
        let normalized = DomainRouter.normalize(hostname)
        return normalized == suffix || normalized.hasSuffix(".\(suffix)")
    }

    public static func normalize(_ hostname: String) -> String {
        var normalized = hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while normalized.hasSuffix(".") {
            normalized.removeLast()
        }
        return normalized
    }

    public static func matches(pattern rawPattern: String, hostname rawHostname: String) -> Bool {
        matchSpecificity(pattern: rawPattern, hostname: rawHostname) != nil
    }

    public static func matchSpecificity(pattern rawPattern: String, hostname rawHostname: String) -> Int? {
        let pattern = normalize(rawPattern)
        let hostname = normalize(rawHostname)
        guard pattern.hasPrefix("*.") else { return pattern == hostname ? 2 : nil }
        let suffix = String(pattern.dropFirst(2))
        guard hostname.hasSuffix(".\(suffix)") else { return nil }
        let prefix = hostname.dropLast(suffix.count + 1)
        return !prefix.isEmpty && !prefix.contains(".") ? 1 : nil
    }

    public static func isValidHostnamePattern(_ rawValue: String, allowWildcard: Bool = true) -> Bool {
        let value = normalize(rawValue)
        guard !value.isEmpty, value.count <= 253 else { return false }
        let hostname: String
        if value.hasPrefix("*.") {
            guard allowWildcard else { return false }
            hostname = String(value.dropFirst(2))
        } else {
            guard !value.contains("*") else { return false }
            hostname = value
        }
        guard IPv4Address(hostname) == nil else { return false }
        let labels = hostname.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        return labels.allSatisfy { label in
            guard !label.isEmpty, label.count <= 63,
                  label.first != "-", label.last != "-" else {
                return false
            }
            return label.unicodeScalars.allSatisfy { scalar in
                let value = scalar.value
                return (48...57).contains(value) || (97...122).contains(value) || value == 45
            }
        }
    }
}

public struct IPv4Address: Sendable, Equatable, Hashable {
    public var bytes: [UInt8]

    public init?(_ raw: String) {
        var address = in_addr()
        guard inet_pton(AF_INET, raw, &address) == 1 else { return nil }
        self.bytes = withUnsafeBytes(of: &address) { Array($0) }
    }
}
