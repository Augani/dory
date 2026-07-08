import Foundation

public enum PublishedPortForwardProtocol: String, Sendable, Hashable {
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

public struct PublishedPortBinding: Sendable, Hashable {
    public var `protocol`: PublishedPortForwardProtocol
    public var port: Int

    public init(`protocol`: PublishedPortForwardProtocol, port: Int) {
        self.`protocol` = `protocol`
        self.port = port
    }

    public init?(dockerType: String, publicPort: Int) {
        guard (1...65_535).contains(publicPort),
              let `protocol` = PublishedPortForwardProtocol(dockerType: dockerType) else {
            return nil
        }
        self.init(protocol: `protocol`, port: publicPort)
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
    public static func forwards(
        for bindings: Set<PublishedPortBinding>,
        publishHost: String,
        guestIP: String
    ) -> Set<PublishedPortForward> {
        Set(bindings.flatMap { binding in
            localHosts(for: publishHost).map { host in
                forward(for: binding, localHost: host, guestIP: guestIP)
            }
        })
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
        let primary = publishHost == "0.0.0.0" ? "0.0.0.0" : "127.0.0.1"
        return [primary, "[::1]"]
    }
}
