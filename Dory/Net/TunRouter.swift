import Foundation

/// Pure planning for Dory's direct-IP routing. The privileged helper owns applying the plan
/// (utun creation, route changes, and packet bridge startup); this type keeps validation and
/// command construction deterministic and testable in the app target.
struct TunRouter: Sendable {
    struct Plan: Sendable, Equatable {
        let interfaceName: String
        let subnetCIDR: String
        let hostGateway: String
        let gateway: String
        let interfaceCommand: [String]
        let routeCommand: [String]
        let teardownCommand: [String]
        let enableNetworkingArguments: [String]
        let disableNetworkingArguments: [String]
    }

    enum RouterError: Error, Equatable {
        case invalidInterface
        case invalidCIDR
        case invalidHostGateway
        case invalidGateway
        case unsupportedCIDR
    }

    static func plan(interfaceName: String = "utun-dory", subnetCIDR: String, hostGateway: String = "192.168.127.1", gateway: String) throws -> Plan {
        guard isValidInterfaceName(interfaceName) else { throw RouterError.invalidInterface }
        guard isValidIPv4CIDR(subnetCIDR) else { throw RouterError.invalidCIDR }
        guard isValidIPv4(hostGateway) else { throw RouterError.invalidHostGateway }
        guard isValidIPv4(gateway) else { throw RouterError.invalidGateway }

        return Plan(
            interfaceName: interfaceName,
            subnetCIDR: subnetCIDR,
            hostGateway: hostGateway,
            gateway: gateway,
            interfaceCommand: ["/sbin/ifconfig", interfaceName, "inet", hostGateway, gateway, "up"],
            routeCommand: ["/sbin/route", "-n", "add", "-net", subnetCIDR, "-interface", interfaceName],
            teardownCommand: ["/sbin/route", "-n", "delete", "-net", subnetCIDR],
            enableNetworkingArguments: ["--direct-ip", "--container-subnet", subnetCIDR, "--host-gateway", hostGateway, "--guest-gateway", gateway],
            disableNetworkingArguments: ["--remove", "--direct-ip", "--container-subnet", subnetCIDR]
        )
    }

    static func isValidInterfaceName(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 15 else { return false }
        return value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    static func isValidIPv4CIDR(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = Int(parts[1]), (0...32).contains(prefix) else { return false }
        return isValidIPv4(String(parts[0]))
    }

    static func isValidIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, let octet = Int(part), (0...255).contains(octet) else { return false }
            return String(octet) == part || part == "0"
        }
    }

    struct IPv4Route: Sendable, Equatable {
        let network: UInt32
        let prefixLength: Int

        init(cidr: String) throws {
            let parts = cidr.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let prefix = Int(parts[1]),
                  (1...32).contains(prefix),
                  let address = IPv4Address(String(parts[0])) else {
                throw RouterError.invalidCIDR
            }
            self.prefixLength = prefix
            self.network = address.rawValue & Self.mask(for: prefix)
        }

        func contains(_ address: IPv4Address) -> Bool {
            (address.rawValue & Self.mask(for: prefixLength)) == network
        }

        private static func mask(for prefix: Int) -> UInt32 {
            UInt32.max << UInt32(32 - prefix)
        }
    }

    struct IPv4Address: Sendable, Equatable, Hashable, CustomStringConvertible {
        let rawValue: UInt32

        init?(_ value: String) {
            guard TunRouter.isValidIPv4(value) else { return nil }
            let octets = value.split(separator: ".").compactMap { UInt8($0) }
            guard octets.count == 4 else { return nil }
            rawValue = UInt32(octets[0]) << 24 | UInt32(octets[1]) << 16 | UInt32(octets[2]) << 8 | UInt32(octets[3])
        }

        init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        var description: String {
            [
                UInt8((rawValue >> 24) & 0xff),
                UInt8((rawValue >> 16) & 0xff),
                UInt8((rawValue >> 8) & 0xff),
                UInt8(rawValue & 0xff),
            ].map(String.init).joined(separator: ".")
        }
    }

    struct IPv4Packet: Sendable, Equatable {
        let source: IPv4Address
        let destination: IPv4Address
        let protocolNumber: UInt8
        let bytes: Data

        init?(bytes: Data) {
            guard bytes.count >= 20 else { return nil }
            let versionAndIHL = bytes[bytes.startIndex]
            guard versionAndIHL >> 4 == 4 else { return nil }
            let headerLength = Int(versionAndIHL & 0x0f) * 4
            guard headerLength >= 20, bytes.count >= headerLength else { return nil }
            let totalLength = Int(UInt16(bytes[bytes.startIndex + 2]) << 8 | UInt16(bytes[bytes.startIndex + 3]))
            guard totalLength >= headerLength, bytes.count >= totalLength else { return nil }
            self.protocolNumber = bytes[bytes.startIndex + 9]
            self.source = IPv4Address(rawValue: Self.readUInt32(bytes, offset: 12))
            self.destination = IPv4Address(rawValue: Self.readUInt32(bytes, offset: 16))
            self.bytes = bytes.prefix(totalLength)
        }

        private static func readUInt32(_ data: Data, offset: Int) -> UInt32 {
            let start = data.startIndex + offset
            return UInt32(data[start]) << 24
                | UInt32(data[start + 1]) << 16
                | UInt32(data[start + 2]) << 8
                | UInt32(data[start + 3])
        }
    }

    enum PacketBridgeDecision: Sendable, Equatable {
        case injectToGuest(packet: Data, destination: IPv4Address)
        case ignore(reason: String)
    }

    struct PacketBridge: Sendable {
        static let utunIPv4Header = Data([0, 0, 0, 2])
        static let bridgeMAC: [UInt8] = [0x5a, 0x94, 0xef, 0xd0, 0x12, 0x01]
        static let guestMAC: [UInt8] = [0x5a, 0x94, 0xef, 0xe4, 0x0c, 0xee]

        let route: IPv4Route
        let gateway: IPv4Address

        init(subnetCIDR: String, gateway: String) throws {
            self.route = try IPv4Route(cidr: subnetCIDR)
            guard let gatewayAddress = IPv4Address(gateway) else { throw RouterError.invalidGateway }
            self.gateway = gatewayAddress
        }

        func classifyOutboundUtunFrame(_ frame: Data) -> PacketBridgeDecision {
            guard let packet = Self.ipv4Packet(fromUtunFrame: frame) else {
                return .ignore(reason: "not an IPv4 utun frame")
            }
            guard route.contains(packet.destination) else {
                return .ignore(reason: "destination outside routed subnet")
            }
            guard packet.destination != gateway else {
                return .ignore(reason: "destination is direct-IP gateway")
            }
            return .injectToGuest(packet: packet.bytes, destination: packet.destination)
        }

        func wrapInboundPacketForUtun(_ packet: Data) -> Data? {
            guard IPv4Packet(bytes: packet) != nil else { return nil }
            return Self.utunIPv4Header + packet
        }

        func ethernetFrameForGvproxy(_ packet: Data) -> Data? {
            guard IPv4Packet(bytes: packet) != nil else { return nil }
            var frame = Data()
            frame.append(contentsOf: Self.guestMAC)
            frame.append(contentsOf: Self.bridgeMAC)
            frame.append(contentsOf: [0x08, 0x00])
            frame.append(packet)
            return frame
        }

        func ipv4PacketFromGvproxyFrame(_ frame: Data) -> Data? {
            guard frame.count >= 34 else { return nil }
            let etherTypeOffset = frame.startIndex + 12
            guard frame[etherTypeOffset] == 0x08, frame[etherTypeOffset + 1] == 0x00 else { return nil }
            let packet = frame.dropFirst(14)
            guard let parsed = IPv4Packet(bytes: packet) else { return nil }
            return parsed.bytes
        }

        private static func ipv4Packet(fromUtunFrame frame: Data) -> IPv4Packet? {
            guard frame.count >= utunIPv4Header.count + 20,
                  frame.prefix(utunIPv4Header.count) == utunIPv4Header else {
                return nil
            }
            return IPv4Packet(bytes: frame.dropFirst(utunIPv4Header.count))
        }
    }
}
