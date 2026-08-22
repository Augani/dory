import Darwin
import DoryOperations
import Foundation

public enum PublishedPortForwardProtocol: String, Sendable, Hashable, Codable {
    case tcp
    case udp

    public init?(dockerType: String) {
        switch dockerType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "tcp", "tcp6":
            self = .tcp
        case "udp", "udp6":
            self = .udp
        default:
            return nil
        }
    }
}

public struct PublishedPortBinding: Sendable, Hashable, Codable {
    public var `protocol`: PublishedPortForwardProtocol
    public var port: Int
    /// Docker's requested host address. The engine-wide LAN setting is a maximum exposure policy,
    /// not permission to widen an explicit per-container loopback or interface-specific binding.
    public var hostIP: String?

    public init(`protocol`: PublishedPortForwardProtocol, port: Int, hostIP: String? = nil) {
        self.`protocol` = `protocol`
        self.port = port
        self.hostIP = Self.normalizedHostIP(hostIP)
    }

    public init?(dockerType: String, publicPort: Int, hostIP: String? = nil) {
        guard (1...65_535).contains(publicPort),
              let `protocol` = PublishedPortForwardProtocol(dockerType: dockerType) else {
            return nil
        }
        self.init(protocol: `protocol`, port: publicPort, hostIP: hostIP)
    }

    private static func normalizedHostIP(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct PublishedPortForward: Sendable, Hashable {
    public var `protocol`: PublishedPortForwardProtocol
    public var publishedPort: Int
    public var localHost: String
    public var localPort: Int
    public var guestHost: String
    public var guestPort: Int

    public init(
        `protocol`: PublishedPortForwardProtocol,
        publishedPort: Int,
        localHost: String,
        localPort: Int,
        guestHost: String,
        guestPort: Int
    ) {
        self.`protocol` = `protocol`
        self.publishedPort = publishedPort
        self.localHost = localHost
        self.localPort = localPort
        self.guestHost = guestHost
        self.guestPort = guestPort
    }

    public var localEndpoint: String { "\(localHost):\(localPort)" }
    public var remoteEndpoint: String { "\(guestHost):\(guestPort)" }
}

public enum PublishedPortForwardPlan {
    public static let loopbackPortIntentLabel = "dev.dory.internal.loopback-port-intent"

    /// Parse the trusted label injected by Dory's create-request dataplane. Values outside the
    /// closed vocabulary are ignored so malformed daemon state can never widen exposure.
    public static func loopbackIntents(fromLabel label: String?) -> [String: [String: String]] {
        guard let label,
              let data = label.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var result: [String: [String: String]] = [:]
        for (key, rawValue) in object {
            let pieces = key.split(separator: "/", omittingEmptySubsequences: false)
            guard pieces.count == 2,
                  Int(pieces[0]).map({ (1...65_535).contains($0) }) == true,
                  PublishedPortForwardProtocol(dockerType: String(pieces[1])) != nil else {
                continue
            }
            // Accept the first development label format as an empty/dynamic-port intent so a
            // runtime upgrade does not briefly widen already-created containers.
            let values: [String: String]
            if let legacy = rawValue as? String {
                values = ["": legacy]
            } else if let map = rawValue as? [String: String] {
                values = map
            } else {
                continue
            }
            let valid = values.filter { hostPort, value in
                let portIsValid = hostPort.isEmpty
                    || Int(hostPort).map({ (1...65_535).contains($0) }) == true
                return portIsValid && (value == "ipv4" || value == "ipv6" || value == "localhost")
            }
            if !valid.isEmpty { result[key] = valid }
        }
        return result
    }

    public static func requestedHost(
        dockerHost: String?,
        containerPort: Int?,
        publicPort: Int?,
        dockerType: String,
        loopbackIntents: [String: [String: String]]
    ) -> String? {
        guard let containerPort,
              let intents = loopbackIntents["\(containerPort)/\(dockerType.lowercased())"] else {
            return dockerHost
        }
        let intent = publicPort.flatMap { intents[String($0)] } ?? intents[""]
        guard let intent else { return dockerHost }
        switch intent {
        case "ipv4": return "127.0.0.1"
        case "ipv6": return "::1"
        case "localhost": return "localhost"
        default: return dockerHost
        }
    }

    public static func forwards(
        for bindings: Set<PublishedPortBinding>,
        publishHost: String,
        guestIP: String
    ) -> Set<PublishedPortForward> {
        Set(bindings.flatMap { binding in
            localHosts(for: publishHost, requestedHost: binding.hostIP).map { host in
                forward(for: binding, localHost: host, guestIP: guestIP)
            }
        })
    }

    /// Maps a daemon-validated workspace contract to exact gvproxy endpoints. This performs the
    /// same closed structural checks again at the helper boundary because command-line input is
    /// untrusted. Privileged host ports are intentionally unavailable until a dedicated
    /// authorization path exists; Dory never remaps an explicitly requested host port.
    public static func resolvedForwards(
        _ intents: [DoryVMPortForward],
        guestIP: String
    ) -> Set<PublishedPortForward>? {
        guard intents.count <= DoryVMPortForward.maximumCount else { return nil }
        var identifiers: Set<String> = []
        var bindings: Set<String> = []
        var result: Set<PublishedPortForward> = []
        for intent in intents {
            let bytes = Array(intent.id.utf8)
            guard (1...63).contains(bytes.count),
                  bytes.first.map(isASCIIAlphaNumeric) == true,
                  bytes.dropFirst().allSatisfy({
                      isASCIIAlphaNumeric($0) || $0 == 95 || $0 == 46 || $0 == 45
                  }),
                  identifiers.insert(intent.id).inserted,
                  intent.hostPort >= 1_024,
                  intent.guestPort > 0,
                  bindings.insert("\(intent.transport.rawValue):\(intent.hostPort)").inserted
            else { return nil }
            let transport: PublishedPortForwardProtocol = intent.transport == .tcp ? .tcp : .udp
            result.insert(PublishedPortForward(
                protocol: transport,
                publishedPort: Int(intent.hostPort),
                localHost: intent.exposure == .loopback ? "127.0.0.1" : "0.0.0.0",
                localPort: Int(intent.hostPort),
                guestHost: guestIP,
                guestPort: Int(intent.guestPort)
            ))
        }
        return result
    }

    public static func forward(
        for binding: PublishedPortBinding,
        localHost: String,
        guestIP: String
    ) -> PublishedPortForward {
        PublishedPortForward(
            protocol: binding.protocol,
            publishedPort: binding.port,
            localHost: localHost,
            localPort: localPort(forPublishedPort: binding.port),
            guestHost: guestIP,
            guestPort: binding.port
        )
    }

    public static func localPort(forPublishedPort port: Int) -> Int {
        guard port > 0, port < 1024 else { return port }
        return 60_000 + port
    }

    public static func localHosts(for publishHost: String) -> [String] {
        localHosts(for: publishHost, requestedHost: nil)
    }

    public static func localHosts(for publishHost: String, requestedHost: String?) -> [String] {
        let requested = requestedHost?.trimmingCharacters(in: .whitespacesAndNewlines)
        let lanEnabled = publishHost == "0.0.0.0"

        switch requested {
        case "127.0.0.1":
            return ["127.0.0.1"]
        case "::1", "[::1]":
            return ["[::1]"]
        case nil, "", "0.0.0.0", "::", "[::]":
            return lanEnabled ? ["0.0.0.0", "[::1]"] : ["127.0.0.1", "[::1]"]
        case let value?:
            // Interface-specific addresses are honored only after the user has opted into LAN
            // visibility. In localhost-only mode the global policy clamps every Docker request.
            guard lanEnabled, isIPAddress(value) else { return ["127.0.0.1", "[::1]"] }
            if value.contains(":") {
                return ["[\(value.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))]"]
            }
            return [value]
        }
    }

    private static func isIPAddress(_ value: String) -> Bool {
        let unbracketed = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if unbracketed.contains(":") {
            let pieces = unbracketed.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
            guard !pieces[0].isEmpty,
                  pieces.count == 1 || (!pieces[1].isEmpty && pieces[1].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })) else {
                return false
            }
            var address = in6_addr()
            return String(pieces[0]).withCString { inet_pton(AF_INET6, $0, &address) } == 1
        }
        var address = in_addr()
        return unbracketed.withCString { inet_pton(AF_INET, $0, &address) } == 1
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57)
            || (byte >= 65 && byte <= 90)
            || (byte >= 97 && byte <= 122)
    }
}
