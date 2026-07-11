import DoryCore
import Foundation
import Testing
@testable import DoryHV

@Suite struct MachinePortWatcherTests {
    @Test func watchPortsUsesAuthoritativeTypedClient() async throws {
        let client = StubAgentControlRPC()
        let channel = AgentChannel(client: client)

        let snapshot = try await channel.watchPorts()

        #expect(snapshot == AgentPortSnapshot(ports: [], added: [], removed: []))
    }

    @Test func watcherExposesAndReleasesTCPDiffsOnly() async throws {
        let client = StubAgentControlRPC()
        client.portsResult = DoryPortsSnapshot(
            ports: [DoryListenPort(protocol: "tcp", port: 3_000)],
            added: [
                DoryPortEvent(action: "added", protocol: "tcp", port: 3_000),
                DoryPortEvent(action: "added", protocol: "udp", port: 5_353),
                DoryPortEvent(action: "added", protocol: "tcp", port: 2_375),
                DoryPortEvent(action: "added", protocol: "tcp", port: 11_434),
            ],
            removed: [
                DoryPortEvent(action: "removed", protocol: "tcp6", port: 8_080),
                DoryPortEvent(action: "removed", protocol: "udp", port: 5_353),
                DoryPortEvent(action: "removed", protocol: "tcp", port: 2_377),
            ]
        )
        let forwarder = FakeMachinePortForwarder()
        let watcher = MachinePortWatcher(channel: AgentChannel(client: client), forwarder: forwarder)

        let snapshot = try await watcher.pollOnce()

        #expect(snapshot.ports == [AgentListenPort(protocol: "tcp", port: 3_000)])
        #expect(await forwarder.exposed == [3_000])
        #expect(await forwarder.unexposed == [8_080])
    }

    private actor FakeMachinePortForwarder: MachinePortForwarding {
        private(set) var exposed: [UInt16] = []
        private(set) var unexposed: [UInt16] = []

        func exposeMachinePort(_ port: UInt16) async -> Bool {
            exposed.append(port)
            return true
        }

        func unexposeMachinePort(_ port: UInt16) async -> Bool {
            unexposed.append(port)
            return true
        }
    }
}
