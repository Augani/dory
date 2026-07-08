import Foundation

public enum NetworkingAuthorizationError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidSuffix(String)
    case invalidBindAddress(String)
    case invalidPort(String)
    case invalidPath(String)

    public var description: String {
        switch self {
        case let .invalidSuffix(value):
            return "invalid domain suffix: \(value)"
        case let .invalidBindAddress(value):
            return "invalid DNS bind address: \(value)"
        case let .invalidPort(name):
            return "invalid unprivileged networking port: \(name)"
        case let .invalidPath(name):
            return "invalid networking path: \(name)"
        }
    }
}

public enum NetworkingAuthorizationRequestKind: String, Sendable, Equatable, Codable {
    case resolverFile
    case pfAnchor
    case pfEnable
    case localCATrust
}

public struct NetworkingAuthorizationRequest: Sendable, Equatable, Codable {
    public var id: String
    public var kind: NetworkingAuthorizationRequestKind
    public var title: String
    public var reason: String
    public var requiresAdmin: Bool
    public var filePath: String?
    public var fileContents: String?
    public var command: [String]

    public init(
        id: String,
        kind: NetworkingAuthorizationRequestKind,
        title: String,
        reason: String,
        requiresAdmin: Bool = true,
        filePath: String? = nil,
        fileContents: String? = nil,
        command: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.reason = reason
        self.requiresAdmin = requiresAdmin
        self.filePath = filePath
        self.fileContents = fileContents
        self.command = command
    }
}

public struct NetworkingAuthorizationPlan: Sendable, Equatable, Codable {
    public var degradedMode: String
    public var authorizedMode: String
    public var suffix: String
    public var dnsBindAddress: String
    public var dnsPort: UInt16
    public var httpProxyPort: UInt16
    public var httpsProxyPort: UInt16
    public var requests: [NetworkingAuthorizationRequest]

    public init(
        degradedMode: String = "high-port-dns-only",
        authorizedMode: String = "system-resolver-proxy-tls",
        suffix: String,
        dnsBindAddress: String,
        dnsPort: UInt16,
        httpProxyPort: UInt16,
        httpsProxyPort: UInt16,
        requests: [NetworkingAuthorizationRequest]
    ) {
        self.degradedMode = degradedMode
        self.authorizedMode = authorizedMode
        self.suffix = suffix
        self.dnsBindAddress = dnsBindAddress
        self.dnsPort = dnsPort
        self.httpProxyPort = httpProxyPort
        self.httpsProxyPort = httpsProxyPort
        self.requests = requests
    }

    public static func make(configuration: NetworkingConfiguration) throws -> NetworkingAuthorizationPlan {
        let suffix = try validatedSuffix(configuration.suffix)
        try validateIPv4(configuration.dnsBindAddress, field: "dnsBindAddress")
        try validateUnprivilegedPort(configuration.dnsPort, field: "dnsPort")
        try validateUnprivilegedPort(configuration.httpProxyPort, field: "httpProxyPort")
        try validateUnprivilegedPort(configuration.httpsProxyPort, field: "httpsProxyPort")

        let resolverPath = "/etc/resolver/\(suffix)"
        let resolverContents = """
        # Managed by Dory. Do not edit.
        nameserver \(configuration.dnsBindAddress)
        port \(configuration.dnsPort)

        """

        let pfAnchorName = "com.apple/dev.dory"
        let pfAnchorPath = "/etc/pf.anchors/dev.dory"
        let pfAnchorContents = """
        # Managed by Dory. Do not edit.
        rdr pass on lo0 inet proto tcp from any to any port 80 -> 127.0.0.1 port \(configuration.httpProxyPort)
        rdr pass on lo0 inet proto tcp from any to any port 443 -> 127.0.0.1 port \(configuration.httpsProxyPort)

        """

        var requests = [
            NetworkingAuthorizationRequest(
                id: "resolver.\(suffix)",
                kind: .resolverFile,
                title: "Install \(suffix) resolver",
                reason: "Route *.\(suffix) DNS queries to doryd's local DNS listener.",
                filePath: resolverPath,
                fileContents: resolverContents,
                command: ["/usr/bin/install", "-m", "0644", "<generated>", resolverPath]
            ),
            NetworkingAuthorizationRequest(
                id: "pf.dev.dory.anchor",
                kind: .pfAnchor,
                title: "Install Dory pf anchor",
                reason: "Forward standard HTTP and HTTPS ports to doryd's unprivileged local proxy ports.",
                filePath: pfAnchorPath,
                fileContents: pfAnchorContents,
                command: ["/usr/bin/install", "-m", "0644", "<generated>", pfAnchorPath]
            ),
            NetworkingAuthorizationRequest(
                id: "pf.dev.dory.enable",
                kind: .pfEnable,
                title: "Enable Dory pf rules",
                reason: "Load the Dory anchor under macOS's built-in com.apple/* anchor point without making doryd run as root.",
                command: ["/sbin/pfctl", "-a", pfAnchorName, "-f", pfAnchorPath]
            ),
        ]

        if let caPath = configuration.localCACertificatePath {
            try validateAbsolutePath(caPath, field: "localCACertificatePath")
            requests.append(NetworkingAuthorizationRequest(
                id: "trust.local-ca",
                kind: .localCATrust,
                title: "Trust Dory Local CA",
                reason: "Allow HTTPS certificates issued for *.\(suffix) to validate in browsers and developer tools.",
                filePath: caPath,
                command: DoryLocalCA(directory: URL(fileURLWithPath: caPath).deletingLastPathComponent())
                    .systemTrustInstallCommand()
            ))
        }

        return NetworkingAuthorizationPlan(
            suffix: suffix,
            dnsBindAddress: configuration.dnsBindAddress,
            dnsPort: configuration.dnsPort,
            httpProxyPort: configuration.httpProxyPort,
            httpsProxyPort: configuration.httpsProxyPort,
            requests: requests
        )
    }

    private static func validatedSuffix(_ value: String) throws -> String {
        let suffix = DomainRouter.normalize(value)
        guard !suffix.isEmpty, suffix.utf8.count <= 253 else {
            throw NetworkingAuthorizationError.invalidSuffix(value)
        }
        let labels = suffix.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else {
            throw NetworkingAuthorizationError.invalidSuffix(value)
        }
        for label in labels {
            guard isValidDNSLabel(String(label)) else {
                throw NetworkingAuthorizationError.invalidSuffix(value)
            }
        }
        return suffix
    }

    private static func isValidDNSLabel(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 63 else { return false }
        guard let first = value.first, first.isLetter || first.isNumber else { return false }
        guard let last = value.last, last.isLetter || last.isNumber else { return false }
        return value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    private static func validateIPv4(_ value: String, field: String) throws {
        guard IPv4Address(value) != nil else {
            throw NetworkingAuthorizationError.invalidBindAddress(value)
        }
    }

    private static func validateUnprivilegedPort(_ value: UInt16, field: String) throws {
        guard value >= 1024 else {
            throw NetworkingAuthorizationError.invalidPort(field)
        }
    }

    private static func validateAbsolutePath(_ value: String, field: String) throws {
        guard value.hasPrefix("/"),
              !value.contains("\0"),
              !value.contains("\n"),
              !value.contains("\r") else {
            throw NetworkingAuthorizationError.invalidPath(field)
        }
    }
}
