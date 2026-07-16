import Foundation

public enum NetworkingAuthorizationError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidSuffix(String)
    case invalidBindAddress(String)
    case invalidPort(String)
    case invalidPrivilegedForward(String)
    case invalidPath(String)

    public var description: String {
        switch self {
        case let .invalidSuffix(value):
            return "invalid domain suffix: \(value)"
        case let .invalidBindAddress(value):
            return "invalid DNS bind address: \(value)"
        case let .invalidPort(name):
            return "invalid unprivileged networking port: \(name)"
        case let .invalidPrivilegedForward(value):
            return "invalid privileged TCP forward: \(value)"
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
    private enum CodingKeys: String, CodingKey {
        case degradedMode
        case authorizedMode
        case suffix
        case dnsBindAddress
        case dnsPort
        case httpProxyPort
        case httpsProxyPort
        case privilegedTCPForwards
        case requests
    }

    public var degradedMode: String
    public var authorizedMode: String
    public var suffix: String
    public var dnsBindAddress: String
    public var dnsPort: UInt16
    public var httpProxyPort: UInt16
    public var httpsProxyPort: UInt16
    public var privilegedTCPForwards: [PrivilegedTCPForward]
    public var requests: [NetworkingAuthorizationRequest]

    public init(
        degradedMode: String = "high-port-dns-only",
        authorizedMode: String = "system-resolver-proxy-tls",
        suffix: String,
        dnsBindAddress: String,
        dnsPort: UInt16,
        httpProxyPort: UInt16,
        httpsProxyPort: UInt16,
        privilegedTCPForwards: [PrivilegedTCPForward] = [],
        requests: [NetworkingAuthorizationRequest]
    ) {
        self.degradedMode = degradedMode
        self.authorizedMode = authorizedMode
        self.suffix = suffix
        self.dnsBindAddress = dnsBindAddress
        self.dnsPort = dnsPort
        self.httpProxyPort = httpProxyPort
        self.httpsProxyPort = httpsProxyPort
        self.privilegedTCPForwards = privilegedTCPForwards
        self.requests = requests
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.degradedMode = try container.decode(String.self, forKey: .degradedMode)
        self.authorizedMode = try container.decode(String.self, forKey: .authorizedMode)
        self.suffix = try container.decode(String.self, forKey: .suffix)
        self.dnsBindAddress = try container.decode(String.self, forKey: .dnsBindAddress)
        self.dnsPort = try container.decode(UInt16.self, forKey: .dnsPort)
        self.httpProxyPort = try container.decode(UInt16.self, forKey: .httpProxyPort)
        self.httpsProxyPort = try container.decode(UInt16.self, forKey: .httpsProxyPort)
        self.privilegedTCPForwards = try container.decodeIfPresent(
            [PrivilegedTCPForward].self,
            forKey: .privilegedTCPForwards
        ) ?? []
        self.requests = try container.decode([NetworkingAuthorizationRequest].self, forKey: .requests)
    }

    public static func make(configuration: NetworkingConfiguration) throws -> NetworkingAuthorizationPlan {
        let suffix = try validatedSuffix(configuration.suffix)
        try validateResolverNameserver(configuration.dnsBindAddress, field: "dnsBindAddress")
        try validateUnprivilegedPort(configuration.dnsPort, field: "dnsPort")
        try validateUnprivilegedPort(configuration.httpProxyPort, field: "httpProxyPort")
        try validateUnprivilegedPort(configuration.httpsProxyPort, field: "httpsProxyPort")
        let privilegedTCPForwards = try validatedPrivilegedTCPForwards(configuration.privilegedTCPForwards)

        let resolverPath = "/etc/resolver/\(suffix)"
        let resolverContents = """
        # Managed by Dory. Do not edit.
        nameserver \(configuration.dnsBindAddress)
        port \(configuration.dnsPort)

        """

        let pfAnchorName = "com.apple/dev.dory"
        let pfAnchorPath = "/etc/pf.anchors/dev.dory"
        let pfAnchorContents = pfAnchorFileContents(
            httpProxyPort: configuration.httpProxyPort,
            httpsProxyPort: configuration.httpsProxyPort,
            privilegedTCPForwards: privilegedTCPForwards
        )

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
            try validateLocalCACertificatePath(caPath)
            requests.append(NetworkingAuthorizationRequest(
                id: "trust.local-ca",
                kind: .localCATrust,
                title: "Trust Dory Local CA for this account",
                reason: "Allow HTTPS certificates issued for *.\(suffix) to validate in this user's browsers and developer tools.",
                requiresAdmin: false,
                filePath: caPath,
                command: []
            ))
        }

        return NetworkingAuthorizationPlan(
            suffix: suffix,
            dnsBindAddress: configuration.dnsBindAddress,
            dnsPort: configuration.dnsPort,
            httpProxyPort: configuration.httpProxyPort,
            httpsProxyPort: configuration.httpsProxyPort,
            privilegedTCPForwards: privilegedTCPForwards,
            requests: requests
        )
    }

    private static func pfAnchorFileContents(
        httpProxyPort: UInt16,
        httpsProxyPort: UInt16,
        privilegedTCPForwards: [PrivilegedTCPForward]
    ) -> String {
        var forwards: [UInt16: UInt16] = [
            80: httpProxyPort,
            443: httpsProxyPort,
        ]
        for forward in privilegedTCPForwards {
            forwards[forward.listenPort] = forward.targetPort
        }

        let rules = forwards.keys.sorted().compactMap { listenPort -> String? in
            guard let targetPort = forwards[listenPort] else { return nil }
            return "rdr pass on lo0 inet proto tcp from any to any port \(listenPort) -> 127.0.0.1 port \(targetPort)"
        }
        return (["# Managed by Dory. Do not edit."] + rules).joined(separator: "\n") + "\n"
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
        // Restrict resolver installation to the non-public `.local` mDNS space (which
        // covers `dory.local` and its subdomains) so a tampered plan cannot capture
        // DNS for a real public domain like `mybank.com`.
        guard suffix.hasSuffix(".local") else {
            throw NetworkingAuthorizationError.invalidSuffix(value)
        }
        return suffix
    }

    private static func isValidDNSLabel(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 63 else { return false }
        guard let first = value.first, first.isLetter || first.isNumber else { return false }
        guard let last = value.last, last.isLetter || last.isNumber else { return false }
        return value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    // The bind address is written verbatim as the `nameserver` line in
    // /etc/resolver/<suffix> and installed as root. Only loopback is safe: a
    // routable address would let a tampered plan point system DNS for the suffix
    // at an attacker-controlled host.
    private static func validateResolverNameserver(_ value: String, field: String) throws {
        if let address = IPv4Address(value), address.bytes.first == 127 {
            return
        }
        if isIPv6Loopback(value) {
            return
        }
        throw NetworkingAuthorizationError.invalidBindAddress(value)
    }

    private static func isIPv6Loopback(_ value: String) -> Bool {
        var address = in6_addr()
        guard inet_pton(AF_INET6, value, &address) == 1 else { return false }
        return withUnsafeBytes(of: &address) { raw in
            raw.enumerated().allSatisfy { index, byte in
                index == raw.count - 1 ? byte == 1 : byte == 0
            }
        }
    }

    private static func validateUnprivilegedPort(_ value: UInt16, field: String) throws {
        guard value >= 1024 else {
            throw NetworkingAuthorizationError.invalidPort(field)
        }
    }

    private static func validatedPrivilegedTCPForwards(_ forwards: [PrivilegedTCPForward]) throws -> [PrivilegedTCPForward] {
        var byListenPort: [UInt16: PrivilegedTCPForward] = [:]
        for forward in forwards {
            // Reject 80/443: those belong to the proxy's own HTTP/HTTPS redirect and
            // a caller-supplied forward on them would silently divert web traffic.
            guard forward.listenPort > 0,
                  forward.listenPort < 1024,
                  forward.targetPort >= 1024,
                  !PrivilegedPortMapping.proxyReservedListenPorts.contains(forward.listenPort) else {
                throw NetworkingAuthorizationError.invalidPrivilegedForward("\(forward.listenPort):\(forward.targetPort)")
            }
            byListenPort[forward.listenPort] = forward
        }
        return byListenPort.values.sorted { $0.listenPort < $1.listenPort }
    }

    private static func validateAbsolutePath(_ value: String, field: String) throws {
        guard value.hasPrefix("/"),
              !value.contains("\0"),
              !value.contains("\n"),
              !value.contains("\r") else {
            throw NetworkingAuthorizationError.invalidPath(field)
        }
    }

    // The CA path is added to the owning user's login keychain as a trusted root, so it must be
    // the canonical `~/.dory/ca/ca.crt` (see DoryLocalCA). Constrain the trailing
    // components structurally so a tampered plan cannot promote an arbitrary
    // certificate to a trusted root. Home-relative rather than absolute because the
    // root helper validates this too and does not share doryd's home directory.
    private static func validateLocalCACertificatePath(_ value: String) throws {
        try validateAbsolutePath(value, field: "localCACertificatePath")
        let components = value.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.contains(".."),
              components.count >= 3,
              components[components.count - 1] == "ca.crt",
              components[components.count - 2] == "ca",
              components[components.count - 3] == ".dory" else {
            throw NetworkingAuthorizationError.invalidPath("localCACertificatePath")
        }
    }
}
