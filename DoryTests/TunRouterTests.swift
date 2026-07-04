import Foundation
import Testing
@testable import Dory

struct TunRouterTests {
    @Test func buildsApplyAndTeardownRouteCommands() throws {
        let plan = try TunRouter.plan(subnetCIDR: "192.168.215.0/24", gateway: "10.0.2.2")

        #expect(plan.interfaceName == "utun-dory")
        #expect(plan.subnetCIDR == "192.168.215.0/24")
        #expect(plan.hostGateway == "192.168.127.1")
        #expect(plan.gateway == "10.0.2.2")
        #expect(plan.interfaceCommand == ["/sbin/ifconfig", "utun-dory", "inet", "192.168.127.1", "10.0.2.2", "up"])
        #expect(plan.routeCommand == ["/sbin/route", "-n", "add", "-net", "192.168.215.0/24", "-interface", "utun-dory"])
        #expect(plan.teardownCommand == ["/sbin/route", "-n", "delete", "-net", "192.168.215.0/24"])
        #expect(plan.enableNetworkingArguments == ["--direct-ip", "--container-subnet", "192.168.215.0/24", "--host-gateway", "192.168.127.1", "--guest-gateway", "10.0.2.2"])
        #expect(plan.disableNetworkingArguments == ["--remove", "--direct-ip", "--container-subnet", "192.168.215.0/24"])
    }

    @Test func rejectsUnsafeRouteInputs() {
        #expect(throws: TunRouter.RouterError.invalidInterface) {
            try TunRouter.plan(interfaceName: "utun0;rm", subnetCIDR: "192.168.215.0/24", gateway: "10.0.2.2")
        }
        #expect(throws: TunRouter.RouterError.invalidCIDR) {
            try TunRouter.plan(subnetCIDR: "192.168.215.0/33", gateway: "10.0.2.2")
        }
        #expect(throws: TunRouter.RouterError.invalidCIDR) {
            try TunRouter.plan(subnetCIDR: "192.168.999.0/24", gateway: "10.0.2.2")
        }
        #expect(throws: TunRouter.RouterError.invalidHostGateway) {
            try TunRouter.plan(subnetCIDR: "192.168.215.0/24", hostGateway: "192.168.127.999", gateway: "10.0.2.2")
        }
        #expect(throws: TunRouter.RouterError.invalidGateway) {
            try TunRouter.plan(subnetCIDR: "192.168.215.0/24", gateway: "10.0.2.999")
        }
    }

    @Test func packetBridgeInjectsIPv4FramesForContainerSubnet() throws {
        let bridge = try TunRouter.PacketBridge(subnetCIDR: "192.168.215.0/24", gateway: "192.168.127.2")
        let packet = ipv4Packet(source: "10.0.0.10", destination: "192.168.215.42", protocolNumber: 1)
        let decision = bridge.classifyOutboundUtunFrame(TunRouter.PacketBridge.utunIPv4Header + packet)

        #expect(decision == .injectToGuest(packet: packet, destination: TunRouter.IPv4Address("192.168.215.42")!))
    }

    @Test func packetBridgeIgnoresMalformedAndOutOfRouteFrames() throws {
        let bridge = try TunRouter.PacketBridge(subnetCIDR: "192.168.215.0/24", gateway: "192.168.127.2")
        let foreign = ipv4Packet(source: "10.0.0.10", destination: "10.20.30.40", protocolNumber: 6)

        #expect(bridge.classifyOutboundUtunFrame(Data([0, 0, 0, 30]) + foreign) == .ignore(reason: "not an IPv4 utun frame"))
        #expect(bridge.classifyOutboundUtunFrame(TunRouter.PacketBridge.utunIPv4Header + Data([0x45, 0])) == .ignore(reason: "not an IPv4 utun frame"))
        #expect(bridge.classifyOutboundUtunFrame(TunRouter.PacketBridge.utunIPv4Header + foreign) == .ignore(reason: "destination outside routed subnet"))
    }

    @Test func packetBridgeWrapsGuestIPv4PacketsForUtun() throws {
        let bridge = try TunRouter.PacketBridge(subnetCIDR: "192.168.215.0/24", gateway: "192.168.127.2")
        let packet = ipv4Packet(source: "192.168.215.42", destination: "10.0.0.10", protocolNumber: 1)

        #expect(bridge.wrapInboundPacketForUtun(packet) == TunRouter.PacketBridge.utunIPv4Header + packet)
        #expect(bridge.wrapInboundPacketForUtun(Data([1, 2, 3])) == nil)
    }

    @Test func packetBridgeFramesIPv4PacketsForGvproxyVfkitSocket() throws {
        let bridge = try TunRouter.PacketBridge(subnetCIDR: "192.168.215.0/24", gateway: "192.168.127.2")
        let packet = ipv4Packet(source: "10.0.0.10", destination: "192.168.215.42", protocolNumber: 1)
        let frame = try #require(bridge.ethernetFrameForGvproxy(packet))

        #expect(Array(frame.prefix(6)) == TunRouter.PacketBridge.guestMAC)
        #expect(Array(frame.dropFirst(6).prefix(6)) == TunRouter.PacketBridge.bridgeMAC)
        #expect(Array(frame.dropFirst(12).prefix(2)) == [0x08, 0x00])
        #expect(frame.dropFirst(14) == packet)
        #expect(bridge.ethernetFrameForGvproxy(Data([1, 2, 3])) == nil)
    }

    @Test func packetBridgeExtractsIPv4PacketsFromGvproxyFrames() throws {
        let bridge = try TunRouter.PacketBridge(subnetCIDR: "192.168.215.0/24", gateway: "192.168.127.2")
        let packet = ipv4Packet(source: "192.168.215.42", destination: "10.0.0.10", protocolNumber: 1)
        let frame = try #require(bridge.ethernetFrameForGvproxy(packet))

        #expect(bridge.ipv4PacketFromGvproxyFrame(frame) == packet)
        #expect(bridge.ipv4PacketFromGvproxyFrame(Data(TunRouter.PacketBridge.guestMAC + TunRouter.PacketBridge.bridgeMAC + [0x86, 0xdd]) + packet) == nil)
        #expect(bridge.ipv4PacketFromGvproxyFrame(Data([1, 2, 3])) == nil)
    }

    @Test func ipv4RouteUsesCIDRPrefixMask() throws {
        let route = try TunRouter.IPv4Route(cidr: "192.168.208.0/20")

        #expect(route.contains(TunRouter.IPv4Address("192.168.215.42")!))
        #expect(route.contains(TunRouter.IPv4Address("192.168.223.254")!))
        #expect(!route.contains(TunRouter.IPv4Address("192.168.224.1")!))
    }

    private func ipv4Packet(source: String, destination: String, protocolNumber: UInt8) -> Data {
        let sourceAddress = TunRouter.IPv4Address(source)!.rawValue
        let destinationAddress = TunRouter.IPv4Address(destination)!.rawValue
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
}
