import Foundation

public struct DomainRoute: Sendable, Equatable, Hashable {
    public var hostname: String
    public var address: String
    public var port: UInt16

    public init(hostname: String, address: String, port: UInt16 = 80) {
        self.hostname = hostname
        self.address = address
        self.port = port
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
}

public struct IPv4Address: Sendable, Equatable, Hashable {
    public var bytes: [UInt8]

    public init?(_ raw: String) {
        var address = in_addr()
        guard inet_pton(AF_INET, raw, &address) == 1 else { return nil }
        self.bytes = withUnsafeBytes(of: &address) { Array($0) }
    }
}
