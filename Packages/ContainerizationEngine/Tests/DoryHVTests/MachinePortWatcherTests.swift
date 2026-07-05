import Foundation
import Testing
@testable import DoryHV

@Suite struct MachinePortWatcherTests {
    @Test func watchPortsUsesAgentMethod() async throws {
        let transport = StubAgentTransport(responsePayload: #"{"id":1,"result":{"ports":[],"added":[],"removed":[]}}"#)
        let channel = AgentChannel(transport: transport)

        let snapshot = try await channel.watchPorts()
        let request = try transport.decodedRequest()

        #expect(snapshot == AgentPortSnapshot(ports: [], added: [], removed: []))
        #expect(request.method == "ports.watch")
    }

    @Test func watcherExposesAndReleasesTCPDiffsOnly() async throws {
        let transport = StubAgentTransport(responsePayload: """
        {"id":1,"result":{
          "ports":[{"protocol":"tcp","port":3000}],
          "added":[{"action":"add","protocol":"tcp","port":3000},{"action":"add","protocol":"udp","port":5353}],
          "removed":[{"action":"remove","protocol":"tcp6","port":8080},{"action":"remove","protocol":"udp","port":5353}]
        }}
        """)
        let forwarder = FakeMachinePortForwarder()
        let watcher = MachinePortWatcher(channel: AgentChannel(transport: transport), forwarder: forwarder)

        let snapshot = try await watcher.pollOnce()

        #expect(snapshot.ports == [AgentListenPort(protocol: "tcp", port: 3000)])
        #expect(await forwarder.exposed == [3000])
        #expect(await forwarder.unexposed == [8080])
    }

    private final class StubAgentTransport: AgentByteTransport {
        private var response: [UInt8]
        private(set) var written = [UInt8]()

        init(responsePayload: String) {
            self.response = (try? AgentFrameCodec.encode(Array(responsePayload.utf8))) ?? []
        }

        func readExact(_ count: Int) async throws -> [UInt8] {
            let bytes = Array(response.prefix(count))
            response.removeFirst(min(count, response.count))
            return bytes
        }

        func writeAll(_ bytes: [UInt8]) async throws {
            written.append(contentsOf: bytes)
        }

        func decodedRequest() throws -> CapturedRequest {
            let length = try AgentFrameCodec.decodeLength(Array(written.prefix(4)))
            let payload = Data(written.dropFirst(4).prefix(length))
            return try JSONDecoder().decode(CapturedRequest.self, from: payload)
        }
    }

    private struct CapturedRequest: Decodable {
        var method: String
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
