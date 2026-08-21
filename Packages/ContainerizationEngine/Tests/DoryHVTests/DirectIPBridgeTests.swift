import DoryHV
import Foundation
import Testing

struct DirectIPBridgeTests {
    @Test func classifiesUtunFramesForRoutedContainerSubnet() throws {
        let bridge = try DirectIPPacketBridge(subnetCIDR: "192.168.215.0/24", gateway: "192.168.127.2")
        let packet = ipv4Packet(source: "10.0.0.10", destination: "192.168.215.42", protocolNumber: 1)

        let decision = bridge.classifyOutboundUtunFrame(DirectIPPacketBridge.utunIPv4Header + packet)

        #expect(decision == .injectToGvproxy(packet: packet, destination: DirectIPv4Address("192.168.215.42")!))
    }

    @Test func ignoresMalformedAndForeignUtunFrames() throws {
        let bridge = try DirectIPPacketBridge(subnetCIDR: "192.168.215.0/24", gateway: "192.168.127.2")
        let foreign = ipv4Packet(source: "10.0.0.10", destination: "10.20.30.40", protocolNumber: 6)

        #expect(bridge.classifyOutboundUtunFrame(Data([0, 0, 0, 30]) + foreign) == .ignore(reason: "not an IPv4 utun frame"))
        #expect(bridge.classifyOutboundUtunFrame(DirectIPPacketBridge.utunIPv4Header + Data([0x45, 0])) == .ignore(reason: "not an IPv4 utun frame"))
        #expect(bridge.classifyOutboundUtunFrame(DirectIPPacketBridge.utunIPv4Header + foreign) == .ignore(reason: "destination outside routed subnet"))
    }

    @Test func framesIPv4PacketsForGvproxyAndExtractsReplies() throws {
        let bridge = try DirectIPPacketBridge(subnetCIDR: "192.168.215.0/24", gateway: "192.168.127.2")
        let packet = ipv4Packet(source: "10.0.0.10", destination: "192.168.215.42", protocolNumber: 1)
        let frame = try #require(bridge.ethernetFrameForGvproxy(packet))

        #expect(Array(frame.prefix(6)) == DirectIPPacketBridge.defaultGuestMAC)
        #expect(Array(frame.dropFirst(6).prefix(6)) == DirectIPPacketBridge.bridgeMAC)
        #expect(Array(frame.dropFirst(12).prefix(2)) == [0x08, 0x00])
        #expect(bridge.ipv4PacketFromGvproxyFrame(frame) == packet)
        #expect(bridge.wrapInboundPacketForUtun(packet) == DirectIPPacketBridge.utunIPv4Header + packet)
    }

    @Test func framesIngressForThePlanOwnedGuestMAC() throws {
        let mac: [UInt8] = [0x02, 0x11, 0x22, 0x33, 0x44, 0x55]
        let bridge = try DirectIPPacketBridge(
            subnetCIDR: "192.168.215.0/24",
            gateway: "192.168.127.2",
            guestMAC: mac
        )
        let packet = ipv4Packet(
            source: "10.0.0.10",
            destination: "192.168.215.42",
            protocolNumber: 6
        )

        let frame = try #require(bridge.ethernetFrameForGvproxy(packet))
        #expect(Array(frame.prefix(6)) == mac)
    }

    @Test func validatesBridgeConfigurationInputs() throws {
        #expect(throws: DirectIPBridgeError.invalidCIDR("192.168.215.0/33")) {
            _ = try DirectIPPacketBridge(subnetCIDR: "192.168.215.0/33", gateway: "192.168.127.2")
        }
        #expect(throws: DirectIPBridgeError.invalidIPv4("192.168.127.999")) {
            _ = try DirectIPPacketBridge(subnetCIDR: "192.168.215.0/24", gateway: "192.168.127.999")
        }
        #expect(throws: DirectIPBridgeError.invalidIPv6("fd7d:6f72:7900::/129")) {
            _ = try DirectIPPacketBridge(
                subnetCIDR: "192.168.215.0/24",
                gateway: "192.168.127.2",
                ipv6SubnetCIDR: "fd7d:6f72:7900::/129",
                ipv6Gateway: "fd7d:6f72:7900::1"
            )
        }
        #expect(throws: DirectIPBridgeError.invalidIPv6("fd7d:6f72:7900::/64")) {
            _ = try DirectIPPacketBridge(
                subnetCIDR: "192.168.215.0/24",
                gateway: "192.168.127.2",
                ipv6SubnetCIDR: "fd7d:6f72:7900::/64"
            )
        }
    }

    @Test func classifiesAndFramesIPv6ForRoutedContainerSubnet() throws {
        let bridge = try DirectIPPacketBridge(
            subnetCIDR: "192.168.215.0/24",
            gateway: "192.168.127.2",
            ipv6SubnetCIDR: "fd7d:6f72:7900::/64",
            ipv6Gateway: "fd7d:6f72:7900::1"
        )
        let packet = ipv6Packet(
            source: "2001:db8::10",
            destination: "fd7d:6f72:7900::42",
            nextHeader: 6
        )
        let destination = try #require(DirectIPv6Address("fd7d:6f72:7900::42"))

        #expect(bridge.classifyOutboundUtunFrame(DirectIPPacketBridge.utunIPv6Header + packet)
            == .injectIPv6ToGvproxy(packet: packet, destination: destination))

        let frame = try #require(bridge.ethernetFrameForGvproxyIPv6(packet))
        #expect(Array(frame.prefix(6)) == DirectIPPacketBridge.defaultGuestMAC)
        #expect(Array(frame.dropFirst(6).prefix(6)) == DirectIPPacketBridge.bridgeMAC)
        #expect(Array(frame.dropFirst(12).prefix(2)) == [0x86, 0xdd])
        #expect(bridge.ipv6PacketFromGvproxyFrame(frame) == packet)
        #expect(bridge.wrapInboundIPv6PacketForUtun(packet) == DirectIPPacketBridge.utunIPv6Header + packet)
    }

    @Test func IPv6RouteUsesExactPrefixBits() throws {
        let route = try DirectIPv6Route(cidr: "fd7d:6f72:7900:ab80::/57")
        #expect(route.contains(DirectIPv6Address("fd7d:6f72:7900:abff::1")!))
        #expect(!route.contains(DirectIPv6Address("fd7d:6f72:7900:aa00::1")!))
        #expect(DirectIPv6Address("2001:0db8::1")?.description == "2001:db8::1")
    }

    private func ipv4Packet(source: String, destination: String, protocolNumber: UInt8) -> Data {
        let sourceAddress = DirectIPv4Address(source)!.rawValue
        let destinationAddress = DirectIPv4Address(destination)!.rawValue
        var packet = Data([
            0x45, 0x00,
            0x00, 0x1c,
            0x12, 0x34,
            0x00, 0x00,
            0x40, protocolNumber,
            0x00, 0x00,
        ])
        packet.append(contentsOf: bytes(sourceAddress))
        packet.append(contentsOf: bytes(destinationAddress))
        packet.append(contentsOf: [0x08, 0x00, 0x00, 0x00, 0xde, 0xad, 0xbe, 0xef])
        return packet
    }

    private func bytes(_ value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
    }

    private func ipv6Packet(source: String, destination: String, nextHeader: UInt8) -> Data {
        let sourceAddress = DirectIPv6Address(source)!.bytes
        let destinationAddress = DirectIPv6Address(destination)!.bytes
        let payload: [UInt8] = [0xde, 0xad, 0xbe, 0xef]
        var packet = Data([
            0x60, 0x00, 0x00, 0x00,
            0x00, UInt8(payload.count),
            nextHeader, 0x40,
        ])
        packet.append(contentsOf: sourceAddress)
        packet.append(contentsOf: destinationAddress)
        packet.append(contentsOf: payload)
        return packet
    }
}
