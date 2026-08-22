import DoryCore
import Foundation
import Testing
@testable import DoryHV

@Suite struct AgentProtocolTests {
    @Test func channelUsesSharedRustClientForInfoAndClockSync() async throws {
        let client = StubAgentControlRPC()
        client.infoResult = DoryAgentInfo(
            protocolVersion: DoryCore.protocolVersion(),
            kernel: "Linux 6.12.30-dory",
            agentBuild: "dory-agent/0.1.0",
            uptimeSeconds: 42,
            capabilities: [DoryAgentCapability(id: "usb-vhci", version: 1)]
        )
        client.clockSyncResult = true
        let channel = AgentChannel(client: client)

        let info = try await channel.info()
        let clock = try await channel.syncClock(hostEpochNanoseconds: 1_725_000_000_123_456_789)

        #expect(info == AgentInfo(
            protocolVersion: 1,
            kernel: "Linux 6.12.30-dory",
            agentBuild: "dory-agent/0.1.0",
            uptimeSeconds: 42,
            capabilities: [AgentCapability(id: "usb-vhci", version: 1)]
        ))
        #expect(clock.synced)
        #expect(client.clockSyncInputs == [1_725_000_000_123_456_789])
    }

    @Test func channelMapsTypedPortSnapshot() async throws {
        let client = StubAgentControlRPC()
        client.portsResult = DoryPortsSnapshot(
            ports: [DoryListenPort(protocol: "tcp", port: 3_000)],
            added: [DoryPortEvent(action: "added", protocol: "tcp6", port: 8_080)],
            removed: [DoryPortEvent(action: "removed", protocol: "udp", port: 5_353)]
        )
        let channel = AgentChannel(client: client)

        let snapshot = try await channel.watchPorts()

        #expect(snapshot == AgentPortSnapshot(
            ports: [AgentListenPort(protocol: "tcp", port: 3_000)],
            added: [AgentPortEvent(action: "added", protocol: "tcp6", port: 8_080)],
            removed: [AgentPortEvent(action: "removed", protocol: "udp", port: 5_353)]
        ))
    }

    @Test func channelRejectsOutOfRangeGuestPort() async throws {
        let client = StubAgentControlRPC()
        client.portsResult = DoryPortsSnapshot(
            ports: [DoryListenPort(protocol: "tcp", port: 65_536)],
            added: [],
            removed: []
        )
        let channel = AgentChannel(client: client)

        await #expect(throws: AgentProtocolError.invalidGuestPort(65_536)) {
            _ = try await channel.watchPorts()
        }
    }

    @Test func channelRequiresAndForwardsExactUsbVhciAuthority() async throws {
        let client = StubAgentControlRPC()
        client.infoResult = DoryAgentInfo(
            protocolVersion: 1,
            kernel: "Linux test",
            agentBuild: "dory-agent/test",
            uptimeSeconds: 1,
            capabilities: [DoryAgentCapability(id: "usb-vhci", version: 1)]
        )
        let channel = AgentChannel(client: client)
        let attach = UsbAgentAttachRequest(
            busid: "3-2",
            port: 4,
            vsock_port: VsockPorts.usbip,
            device_id: (3 << 16) | 2,
            speed: 3
        )

        try await channel.requireCapability("usb-vhci", version: 1)
        try await channel.usbVhciAttach(attach)
        try await channel.usbVhciDetach(UsbAgentDetachRequest(busid: "3-2", port: 4))

        #expect(client.usbAttachCalls == [attach])
        #expect(client.usbDetachCalls == [UsbAgentDetachRequest(busid: "3-2", port: 4)])
    }

    @Test func channelRejectsMissingUsbCapabilityAndInvalidPort() async throws {
        let channel = AgentChannel(client: StubAgentControlRPC())
        await #expect(throws: AgentProtocolError.capabilityUnavailable("usb-vhci", 1)) {
            try await channel.requireCapability("usb-vhci", version: 1)
        }
        await #expect(throws: AgentProtocolError.invalidVhciPort(-1)) {
            try await channel.usbVhciAttach(UsbAgentAttachRequest(
                busid: "3-2",
                port: -1,
                vsock_port: VsockPorts.usbip,
                device_id: (3 << 16) | 2,
                speed: 3
            ))
        }
    }

    @Test func channelRejectsNoncanonicalCapabilityInventory() async {
        let client = StubAgentControlRPC()
        client.infoResult = DoryAgentInfo(
            protocolVersion: 1,
            kernel: "Linux test",
            agentBuild: "dory-agent/test",
            uptimeSeconds: 1,
            capabilities: [
                DoryAgentCapability(id: "usb-vhci", version: 1),
                DoryAgentCapability(id: "clock-sync", version: 1),
            ]
        )

        await #expect(throws: AgentProtocolError.invalidCapabilityInventory) {
            _ = try await AgentChannel(client: client).info()
        }
    }

    @Test func infoJSONUsesCurrentProtobufSurfaceNames() throws {
        let info = AgentInfo(
            protocolVersion: 1,
            kernel: "Linux 6.12.30-dory",
            agentBuild: "dory-agent/0.1.0",
            uptimeSeconds: 42
        )

        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(info)) as? [String: Any])
        #expect(json["protocol_version"] as? Int == 1)
        #expect(json["agent_build"] as? String == "dory-agent/0.1.0")
        #expect(json["uptime_seconds"] as? Int == 42)
        #expect(json["memory_total"] == nil)
        #expect(json["memory_free"] == nil)
    }

    @Test func failedConnectClosesUnderlyingVsockToStopBothRelayPumps() async throws {
        let connection = FailedConnectVsockConnection()
        let channel = AgentChannel(connection: connection) { descriptor in
            close(descriptor) // The real DoryCore connector also takes ownership on failure.
            throw ConnectFailure.expected
        }

        await #expect(throws: ConnectFailure.expected) {
            _ = try await channel.info()
        }
        #expect(connection.closed)
    }

    @Test func successfulChannelDeinitDeterministicallyClosesRelayVsock() async throws {
        let connection = FailedConnectVsockConnection()
        let client = StubAgentControlRPC()
        var channel: AgentChannel? = AgentChannel(connection: connection) { descriptor in
            close(descriptor)
            return client
        }

        _ = try await channel?.info()
        #expect(!connection.closed)
        channel = nil
        #expect(connection.closed)
    }
}

private enum ConnectFailure: Error, Equatable {
    case expected
}

private final class FailedConnectVsockConnection: VsockConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var isClosed = false

    var closed: Bool { lock.withLock { isClosed } }
    var isPeerClosed: Bool { closed }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int { 0 }
    func write(_ bytes: [UInt8]) throws {}
    func close() { lock.withLock { isClosed = true } }
    func shutdownSend() {}
}

final class StubAgentControlRPC: AgentControlRPC, @unchecked Sendable {
    private let lock = NSLock()
    var infoResult = DoryAgentInfo(protocolVersion: 1, kernel: "", agentBuild: "", uptimeSeconds: 0)
    var clockSyncResult = false
    var portsResult = DoryPortsSnapshot(ports: [], added: [], removed: [])
    private var storedClockSyncInputs: [Int64] = []
    private var storedUsbAttachCalls: [UsbAgentAttachRequest] = []
    private var storedUsbDetachCalls: [UsbAgentDetachRequest] = []

    var clockSyncInputs: [Int64] {
        lock.withLock { storedClockSyncInputs }
    }

    var usbAttachCalls: [UsbAgentAttachRequest] {
        lock.withLock { storedUsbAttachCalls }
    }

    var usbDetachCalls: [UsbAgentDetachRequest] {
        lock.withLock { storedUsbDetachCalls }
    }

    func info() throws -> DoryAgentInfo { infoResult }

    func clockSync(hostEpochNs: Int64) throws -> Bool {
        lock.withLock { storedClockSyncInputs.append(hostEpochNs) }
        return clockSyncResult
    }

    func portsWatch() throws -> DoryPortsSnapshot { portsResult }

    func usbVhciAttach(busID: String, port: UInt32, vsockPort: UInt32, deviceID: UInt32, speed: UInt32) throws {
        lock.withLock {
            storedUsbAttachCalls.append(UsbAgentAttachRequest(
                busid: busID,
                port: Int(port),
                vsock_port: vsockPort,
                device_id: deviceID,
                speed: speed
            ))
        }
    }

    func usbVhciDetach(busID: String, port: UInt32) throws {
        lock.withLock {
            storedUsbDetachCalls.append(UsbAgentDetachRequest(busid: busID, port: Int(port)))
        }
    }

    func close() {}
}

private extension NSLock {
    func withLock<Result>(_ body: () -> Result) -> Result {
        lock()
        defer { unlock() }
        return body()
    }
}
