import Foundation

public enum DoryIPv4BridgeNetworkError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidCIDR(String)
    case unsupportedPrefix(Int)
    case publicSubnet(String)

    public var description: String {
        switch self {
        case .invalidCIDR(let value):
            "Enter an IPv4 subnet in CIDR form, such as 192.168.215.0/24 (received \(value))."
        case .unsupportedPrefix(let prefix):
            "Dory bridge subnets must use a prefix from /16 through /24 (received /\(prefix))."
        case .publicSubnet(let value):
            "Dory bridge subnets must stay entirely inside 10.0.0.0/8, 172.16.0.0/12, or 192.168.0.0/16 (received \(value))."
        }
    }
}

/// One IPv4 contract for Docker's default bridge, direct container routing, and source-preserving
/// LAN ingress. Docker allocates from the lower half; the final two usable addresses remain owned
/// by Dory's packet bridge and can never be handed to a container.
public struct DoryIPv4BridgeNetwork: Sendable, Equatable {
    public static let defaultCIDR = "192.168.215.0/24"

    public let cidr: String
    public let prefixLength: Int
    public let networkAddress: String
    public let gatewayAddress: String
    public let dockerAllocationCIDR: String
    public let lanHostAddress: String
    public let lanGuestIngressAddress: String

    public init(_ rawValue: String = Self.defaultCIDR) throws {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2,
              let address = Self.parseIPv4(String(components[0])),
              let prefix = Int(components[1]),
              (1...32).contains(prefix) else {
            throw DoryIPv4BridgeNetworkError.invalidCIDR(value)
        }
        guard (16...24).contains(prefix) else {
            throw DoryIPv4BridgeNetworkError.unsupportedPrefix(prefix)
        }

        let mask = UInt32.max << UInt32(32 - prefix)
        let network = address & mask
        let broadcast = network | ~mask
        guard Self.isPrivate(network), Self.isPrivate(broadcast) else {
            throw DoryIPv4BridgeNetworkError.publicSubnet(value)
        }

        let networkString = Self.formatIPv4(network)
        self.cidr = "\(networkString)/\(prefix)"
        self.prefixLength = prefix
        self.networkAddress = networkString
        self.gatewayAddress = Self.formatIPv4(network + 1)
        self.dockerAllocationCIDR = "\(networkString)/\(prefix + 1)"
        self.lanHostAddress = Self.formatIPv4(broadcast - 2)
        self.lanGuestIngressAddress = Self.formatIPv4(broadcast - 1)
    }

    public var gatewayCIDR: String { "\(gatewayAddress)/\(prefixLength)" }
    public var lanGuestIngressCIDR: String { "\(lanGuestIngressAddress)/32" }

    public var dockerDaemonArguments: String {
        "--bip=\(gatewayCIDR) --fixed-cidr=\(dockerAllocationCIDR) --iptables=true"
    }

    private static func parseIPv4(_ value: String) -> UInt32? {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return nil }
        var result: UInt32 = 0
        for component in components {
            guard !component.isEmpty,
                  let octet = UInt8(component),
                  String(octet) == component || component == "0" else {
                return nil
            }
            result = result << 8 | UInt32(octet)
        }
        return result
    }

    private static func formatIPv4(_ value: UInt32) -> String {
        [24, 16, 8, 0].map { String(UInt8((value >> UInt32($0)) & 0xff)) }
            .joined(separator: ".")
    }

    private static func isPrivate(_ value: UInt32) -> Bool {
        value & 0xff00_0000 == 0x0a00_0000
            || value & 0xfff0_0000 == 0xac10_0000
            || value & 0xffff_0000 == 0xc0a8_0000
    }
}
