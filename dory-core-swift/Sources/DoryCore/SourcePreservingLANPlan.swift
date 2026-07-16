import Darwin
import Foundation

/// Packet-level LAN ingress contract. PF changes only the destination; the remote source address is
/// carried through the UTUN/gvproxy Ethernet bridge and therefore reaches dockerd unchanged.
public enum SourcePreservingLANPlan {
    private static let defaultBridgeNetwork = try! DoryIPv4BridgeNetwork()
    public static let guestIngressIPv4 = defaultBridgeNetwork.lanGuestIngressAddress
    public static let guestIngressCIDR = defaultBridgeNetwork.lanGuestIngressCIDR
    public static let hostBridgeIPv4 = defaultBridgeNetwork.lanHostAddress
    public static let guestReturnGatewayIPv4 = "192.168.127.253"
    public static let bridgeMAC = "5a:94:ef:d0:12:01"
    public static let connectionMark = "0xd072"
    public static let policyRoutingTable = 215
    public static let policyRoutingPriority = 215

    /// Mark only conntrack flows that entered through Dory's /32 published-port address. Replies
    /// restore that mark before route lookup, so a dedicated default route wins even when the real
    /// client address overlaps Docker, gvproxy, a VPN, or another connected subnet. Unrelated guest
    /// traffic keeps the ordinary gvproxy route. The mark also exempts the reply from masquerade;
    /// PF then reverses its destination-only translation on the Mac.
    public static var guestSetupCommands: [String] {
        try! guestSetupCommands(bridgeSubnetCIDR: DoryIPv4BridgeNetwork.defaultCIDR)
    }

    public static func guestSetupCommands(bridgeSubnetCIDR: String) throws -> [String] {
        guestSetupCommands(bridgeNetwork: try DoryIPv4BridgeNetwork(bridgeSubnetCIDR))
    }

    public static func guestSetupCommands(bridgeNetwork network: DoryIPv4BridgeNetwork) -> [String] {
        let guestIngressIPv4 = network.lanGuestIngressAddress
        return [
            "ip address replace \(network.lanGuestIngressCIDR) dev eth0",
            "ip neigh replace \(guestReturnGatewayIPv4) lladdr \(bridgeMAC) nud permanent dev eth0",
            "sysctl -w net.ipv4.ip_forward=1 >/dev/null",
            "ip route replace default via \(guestReturnGatewayIPv4) dev eth0 table \(policyRoutingTable)",
            "ip rule del priority \(policyRoutingPriority) fwmark \(connectionMark)/0xffffffff table \(policyRoutingTable) 2>/dev/null || true",
            "ip rule add priority \(policyRoutingPriority) fwmark \(connectionMark)/0xffffffff table \(policyRoutingTable)",
            "iptables -t mangle -D PREROUTING -i eth0 -d \(guestIngressIPv4) -j CONNMARK --set-xmark \(connectionMark)/0xffffffff 2>/dev/null || true",
            "iptables -t mangle -I PREROUTING 1 -i eth0 -d \(guestIngressIPv4) -j CONNMARK --set-xmark \(connectionMark)/0xffffffff",
            "iptables -t mangle -D PREROUTING ! -i eth0 -m connmark --mark \(connectionMark)/0xffffffff -j CONNMARK --restore-mark 2>/dev/null || true",
            "iptables -t mangle -I PREROUTING 1 ! -i eth0 -m connmark --mark \(connectionMark)/0xffffffff -j CONNMARK --restore-mark",
            "iptables -t mangle -D OUTPUT -m connmark --mark \(connectionMark)/0xffffffff -j CONNMARK --restore-mark 2>/dev/null || true",
            "iptables -t mangle -I OUTPUT 1 -m connmark --mark \(connectionMark)/0xffffffff -j CONNMARK --restore-mark",
            "iptables -t nat -D POSTROUTING -m mark --mark \(connectionMark)/0xffffffff -j RETURN 2>/dev/null || true",
            "iptables -t nat -I POSTROUTING 1 -m mark --mark \(connectionMark)/0xffffffff -j RETURN",
        ]
    }

    /// Build the complete, deterministic Dory anchor for Docker-published LAN ports. Explicit
    /// loopback requests are never included. Interface-specific IPv4 requests stay constrained to
    /// that address; wildcard requests match only addresses owned by this Mac (`self`) off loopback.
    public static func pfAnchorContents(
        bindings: Set<PublishedPortBinding>,
        guestIngressIPv4: String = SourcePreservingLANPlan.guestIngressIPv4
    ) -> String {
        let rules = bindings.compactMap { rule($0, guestIngressIPv4: guestIngressIPv4) }.sorted()
        return (["# Managed by Dory. Do not edit."] + rules).joined(separator: "\n") + "\n"
    }

    public static func lanBindings(from bindings: Set<PublishedPortBinding>) -> Set<PublishedPortBinding> {
        Set(bindings.filter { rule($0) != nil })
    }

    private static func rule(
        _ binding: PublishedPortBinding,
        guestIngressIPv4: String = SourcePreservingLANPlan.guestIngressIPv4
    ) -> String? {
        guard (1...65_535).contains(binding.port) else { return nil }
        let destination: String
        switch normalizedHost(binding.hostIP) {
        case nil, "0.0.0.0":
            destination = "self"
        case "127.0.0.1", "localhost", "::1", "::", "[::1]", "[::]":
            return nil
        case let host?:
            guard isIPv4(host), !host.hasPrefix("127.") else { return nil }
            destination = host
        }
        return "rdr pass on ! lo0 inet proto \(binding.protocol.rawValue) from any to \(destination) port \(binding.port) -> \(guestIngressIPv4) port \(binding.port)"
    }

    private static func normalizedHost(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }

    private static func isIPv4(_ value: String) -> Bool {
        var address = in_addr()
        return value.withCString { inet_pton(AF_INET, $0, &address) } == 1
    }
}

public enum SourcePreservingLANOperation: String, Sendable, Codable {
    case activate
    case refresh
    case deactivate
}

public struct SourcePreservingLANRequest: Sendable, Equatable, Codable {
    public static let schemaVersion = 3

    public var version: Int
    public var operation: SourcePreservingLANOperation
    public var sessionID: String
    public var gvproxySocketPath: String?
    public var bindings: Set<PublishedPortBinding>
    public var mtu: Int
    public var bridgeSubnetCIDR: String

    public init(
        operation: SourcePreservingLANOperation,
        sessionID: String,
        gvproxySocketPath: String? = nil,
        bindings: Set<PublishedPortBinding> = [],
        mtu: Int = DoryNetworkMTU.resolved(),
        bridgeSubnetCIDR: String = DoryIPv4BridgeNetwork.defaultCIDR
    ) {
        self.version = Self.schemaVersion
        self.operation = operation
        self.sessionID = sessionID
        self.gvproxySocketPath = gvproxySocketPath
        self.bindings = bindings
        self.mtu = mtu
        self.bridgeSubnetCIDR = bridgeSubnetCIDR
    }
}

public struct SourcePreservingLANResponse: Sendable, Equatable, Codable {
    public var status: String
    public var sessionID: String
    public var interfaceName: String?
    public var lanBindingCount: Int

    public init(status: String, sessionID: String, interfaceName: String?, lanBindingCount: Int) {
        self.status = status
        self.sessionID = sessionID
        self.interfaceName = interfaceName
        self.lanBindingCount = lanBindingCount
    }
}
