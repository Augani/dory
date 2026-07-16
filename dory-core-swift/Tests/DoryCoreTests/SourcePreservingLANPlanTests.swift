@testable import DoryCore
import XCTest

final class SourcePreservingLANPlanTests: XCTestCase {
    func testGuestPlanPolicyRoutesOnlyMarkedPublishedPortRepliesForAnyIPv4ClientRange() {
        let commands = SourcePreservingLANPlan.guestSetupCommands
        XCTAssertTrue(commands.contains("ip address replace 192.168.215.254/32 dev eth0"))
        XCTAssertTrue(commands.contains(
            "ip neigh replace 192.168.127.253 lladdr 5a:94:ef:d0:12:01 nud permanent dev eth0"
        ))
        XCTAssertTrue(commands.contains("ip route replace default via 192.168.127.253 dev eth0 table 215"))
        XCTAssertTrue(commands.contains(
            "ip rule add priority 215 fwmark 0xd072/0xffffffff table 215"
        ))
        XCTAssertTrue(commands.contains(
            "iptables -t mangle -I PREROUTING 1 -i eth0 -d 192.168.215.254 -j CONNMARK --set-xmark 0xd072/0xffffffff"
        ))
        XCTAssertTrue(commands.contains(
            "iptables -t mangle -I PREROUTING 1 ! -i eth0 -m connmark --mark 0xd072/0xffffffff -j CONNMARK --restore-mark"
        ))
        XCTAssertTrue(commands.contains(
            "iptables -t nat -I POSTROUTING 1 -m mark --mark 0xd072/0xffffffff -j RETURN"
        ))
        XCTAssertFalse(commands.contains { $0.contains("10.0.0.0/8") })
        XCTAssertFalse(commands.contains { $0.contains("192.168.0.0/16") })
    }

    func testPFPlanUsesDestinationOnlyTranslationAndNeverWidensLoopback() {
        let bindings: Set<PublishedPortBinding> = [
            PublishedPortBinding(protocol: .tcp, port: 8080),
            PublishedPortBinding(protocol: .udp, port: 5353, hostIP: "0.0.0.0"),
            PublishedPortBinding(protocol: .tcp, port: 8443, hostIP: "192.168.1.20"),
            PublishedPortBinding(protocol: .tcp, port: 9000, hostIP: "127.0.0.1"),
            PublishedPortBinding(protocol: .tcp, port: 9001, hostIP: "::1"),
        ]

        let rules = SourcePreservingLANPlan.pfAnchorContents(bindings: bindings)
        XCTAssertTrue(rules.contains(
            "rdr pass on ! lo0 inet proto tcp from any to self port 8080 -> 192.168.215.254 port 8080"
        ))
        XCTAssertTrue(rules.contains(
            "rdr pass on ! lo0 inet proto udp from any to self port 5353 -> 192.168.215.254 port 5353"
        ))
        XCTAssertTrue(rules.contains(
            "rdr pass on ! lo0 inet proto tcp from any to 192.168.1.20 port 8443 -> 192.168.215.254 port 8443"
        ))
        XCTAssertFalse(rules.contains("9000"))
        XCTAssertFalse(rules.contains("9001"))
        XCTAssertFalse(rules.contains("route-to"), "source preservation uses stateful destination-only NAT")
    }

    func testRejectsInvalidAndIPv6SpecificHostBindingsFromIPv4LANPlan() {
        let bindings: Set<PublishedPortBinding> = [
            PublishedPortBinding(protocol: .tcp, port: 1, hostIP: "all.example"),
            PublishedPortBinding(protocol: .tcp, port: 2, hostIP: "999.1.1.1"),
            PublishedPortBinding(protocol: .tcp, port: 3, hostIP: "fd00::1"),
        ]
        XCTAssertEqual(SourcePreservingLANPlan.pfAnchorContents(bindings: bindings), "# Managed by Dory. Do not edit.\n")
        XCTAssertTrue(SourcePreservingLANPlan.lanBindings(from: bindings).isEmpty)
    }

    func testPrivilegedRequestRoundTripsWithoutLosingBindingIntent() throws {
        let request = SourcePreservingLANRequest(
            operation: .activate,
            sessionID: "session-1",
            gvproxySocketPath: "/tmp/gvproxy.sock",
            bindings: [PublishedPortBinding(protocol: .tcp, port: 8080, hostIP: "0.0.0.0")],
            mtu: 1_400,
            bridgeSubnetCIDR: "10.44.16.0/20"
        )
        let decoded = try JSONDecoder().decode(
            SourcePreservingLANRequest.self,
            from: JSONEncoder().encode(request)
        )
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.version, SourcePreservingLANRequest.schemaVersion)
        XCTAssertEqual(decoded.mtu, 1_400)
        XCTAssertEqual(decoded.bridgeSubnetCIDR, "10.44.16.0/20")
    }

    func testCustomBridgeSubnetOwnsReservedLANIngressAddresses() throws {
        let commands = try SourcePreservingLANPlan.guestSetupCommands(
            bridgeSubnetCIDR: "10.44.16.0/20"
        )
        XCTAssertTrue(commands.contains("ip address replace 10.44.31.254/32 dev eth0"))
        XCTAssertTrue(commands.contains {
            $0.contains("-i eth0 -d 10.44.31.254 -j CONNMARK")
        })

        let rules = SourcePreservingLANPlan.pfAnchorContents(
            bindings: [PublishedPortBinding(protocol: .tcp, port: 8080)],
            guestIngressIPv4: "10.44.31.254"
        )
        XCTAssertTrue(rules.contains("to self port 8080 -> 10.44.31.254 port 8080"))
    }
}
