import DoryOperations
import Testing

struct DoryIPv4BridgeNetworkTests {
    @Test func defaultPlanSeparatesDockerAllocationsFromLANBridgeAddresses() throws {
        let plan = try DoryIPv4BridgeNetwork()

        #expect(plan.cidr == "192.168.215.0/24")
        #expect(plan.gatewayCIDR == "192.168.215.1/24")
        #expect(plan.dockerAllocationCIDR == "192.168.215.0/25")
        #expect(plan.lanHostAddress == "192.168.215.253")
        #expect(plan.lanGuestIngressCIDR == "192.168.215.254/32")
        #expect(plan.dockerDaemonArguments == "--bip=192.168.215.1/24 --fixed-cidr=192.168.215.0/25 --iptables=true")
    }

    @Test func customPrivateSubnetIsCanonicalized() throws {
        let plan = try DoryIPv4BridgeNetwork("10.44.18.99/20")

        #expect(plan.cidr == "10.44.16.0/20")
        #expect(plan.gatewayCIDR == "10.44.16.1/20")
        #expect(plan.dockerAllocationCIDR == "10.44.16.0/21")
        #expect(plan.lanHostAddress == "10.44.31.253")
        #expect(plan.lanGuestIngressAddress == "10.44.31.254")
    }

    @Test func rejectsPublicMalformedAndTinySubnets() {
        #expect(throws: DoryIPv4BridgeNetworkError.self) {
            _ = try DoryIPv4BridgeNetwork("8.8.8.0/24")
        }
        #expect(throws: DoryIPv4BridgeNetworkError.self) {
            _ = try DoryIPv4BridgeNetwork("192.168.1.0/25")
        }
        #expect(throws: DoryIPv4BridgeNetworkError.self) {
            _ = try DoryIPv4BridgeNetwork("not-a-subnet")
        }
    }
}
