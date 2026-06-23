import Testing
import Foundation
@testable import Dory

struct PortReachabilityTests {
    @Test func machinePortBindingHasNoHostIp() {
        let s = MachineSettings(cpus: nil, memoryMB: nil, mounts: [], ports: [PortPair(host: 32001, guest: 22)])
        let host = MachineService.hostConfig(base: [:], settings: s)
        let bindings = host["PortBindings"] as! [String: [[String: String]]]
        let entry = bindings["22/tcp"]!.first!
        #expect(entry["HostPort"] == "32001")
        #expect(entry["HostIp"] == nil)
    }

    @Test func publicPortsDecodesEveryPort() {
        let json = """
        [{"Ports":[{"PublicPort":32001},{"PublicPort":8080}]},{"Ports":[{"PublicPort":5432}]},{"Ports":[]}]
        """.data(using: .utf8)!
        #expect(AppStore.publicPorts(fromContainersJSON: json) == [32001, 8080, 5432])
    }
}
