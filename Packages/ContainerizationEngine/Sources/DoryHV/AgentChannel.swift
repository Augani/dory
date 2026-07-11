import Darwin
import DoryCore
import Foundation

/// The typed guest-control surface consumed by the raw Hypervisor.framework engine.
///
/// The implementation is deliberately supplied by `DoryCore`: that module embeds the Rust
/// `AgentClient`, which is the authoritative implementation of the versioned Hello handshake,
/// little-endian framing, request/response mux, deadlines, and protobuf messages. Keeping those
/// details out of this target prevents raw `dory-hv` from drifting away from doryd/dory-vmm again.
protocol AgentControlRPC: AnyObject, Sendable {
    func info() throws -> DoryAgentInfo
    func clockSync(hostEpochNs: Int64) throws -> Bool
    func portsWatch() throws -> DoryPortsSnapshot
    func close()
}

extension DoryAgentControlHandle: AgentControlRPC {}

public enum AgentProtocolError: Error, Equatable, Sendable {
    case connectionAlreadyConsumed
    case invalidGuestPort(UInt32)
    case socketPair(Int32)
}

/// A typed control channel over one connected guest vsock stream.
///
/// `VirtioVsock` is an in-process device rather than an OS file descriptor, while the shared Rust
/// client intentionally accepts a normal byte-stream fd. A private unix socketpair bridges those
/// two representations; `VsockUnixRelay` moves bytes unchanged, so all application-protocol work
/// remains in Rust.
public final class AgentChannel: @unchecked Sendable {
    typealias ClientConnector = @Sendable (Int32) throws -> any AgentControlRPC

    private final class ConnectionBox: @unchecked Sendable {
        let connection: VsockConnection

        init(_ connection: VsockConnection) {
            self.connection = connection
        }
    }

    private let lock = NSLock()
    private let connector: ClientConnector
    private var connection: VsockConnection?
    private var relayConnection: VsockConnection?
    private var client: (any AgentControlRPC)?

    public init(connection: VsockConnection) {
        self.connector = { try DoryCore.connectAgentControlOverFD($0) }
        self.connection = connection
    }

    init(connection: VsockConnection, connector: @escaping ClientConnector) {
        self.connector = connector
        self.connection = connection
    }

    /// Test seam for checking the Swift-facing typed surface without duplicating the wire codec in
    /// Swift tests. Rust's own client/agent integration tests cover the complete wire spine.
    init(client: any AgentControlRPC) {
        self.connector = { _ in throw AgentProtocolError.connectionAlreadyConsumed }
        self.client = client
    }

    public func info() async throws -> AgentInfo {
        let raw = try await perform { try $0.info() }
        return AgentInfo(
            protocolVersion: raw.protocolVersion,
            kernel: raw.kernel,
            agentBuild: raw.agentBuild,
            uptimeSeconds: raw.uptimeSeconds
        )
    }

    public func syncClock(hostEpochNanoseconds: Int64) async throws -> ClockSyncResult {
        let synced = try await perform { try $0.clockSync(hostEpochNs: hostEpochNanoseconds) }
        return ClockSyncResult(synced: synced)
    }

    public func watchPorts() async throws -> AgentPortSnapshot {
        let raw = try await perform { try $0.portsWatch() }
        return AgentPortSnapshot(
            ports: try raw.ports.map {
                AgentListenPort(protocol: $0.protocol, port: try checkedPort($0.port))
            },
            added: try raw.added.map {
                AgentPortEvent(action: $0.action, protocol: $0.protocol, port: try checkedPort($0.port))
            },
            removed: try raw.removed.map {
                AgentPortEvent(action: $0.action, protocol: $0.protocol, port: try checkedPort($0.port))
            }
        )
    }

    private func perform<Result: Sendable>(
        _ operation: @escaping @Sendable (any AgentControlRPC) throws -> Result
    ) async throws -> Result {
        // UniFFI's AgentControl is intentionally blocking over its private Tokio runtime. Keep the
        // cooperative Swift executor free while a handshake or RPC waits on guest I/O.
        try await Task.detached { [self] in
            try operation(connectedClient())
        }.value
    }

    private func connectedClient() throws -> any AgentControlRPC {
        lock.lock()
        if let client {
            lock.unlock()
            return client
        }
        guard let connection else {
            lock.unlock()
            throw AgentProtocolError.connectionAlreadyConsumed
        }
        // A vsock stream cannot be replayed after a failed handshake. Consume it exactly once while
        // holding the lock so concurrent first calls cannot start two relays on the same stream.
        self.connection = nil
        relayConnection = connection

        var descriptors = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            let code = errno
            lock.unlock()
            connection.close()
            throw AgentProtocolError.socketPair(code)
        }
        let rustDescriptor = descriptors[0]
        let relayDescriptor = descriptors[1]
        let connectionBox = ConnectionBox(connection)
        Thread.detachNewThread {
            VsockUnixRelay.serve(client: relayDescriptor, connection: connectionBox.connection)
        }

        do {
            // Ownership of rustDescriptor transfers to DoryCore even when the handshake fails.
            let fresh = try connector(rustDescriptor)
            client = fresh
            lock.unlock()
            return fresh
        } catch {
            lock.unlock()
            // Rust owns/closes its socketpair fd on every return path, but a read EOF is only a
            // half-close to the generic stream relay. Explicitly reset the vsock side so its other
            // pump cannot wait forever on a silent guest after handshake timeout/failure.
            connection.close()
            throw error
        }
    }

    deinit {
        lock.lock()
        let unclaimedConnection = connection
        let activeRelayConnection = relayConnection
        let activeClient = client
        connection = nil
        relayConnection = nil
        client = nil
        lock.unlock()
        // Closing the Rust endpoint first lets a healthy guest observe EOF; resetting the in-process
        // vsock immediately afterwards deterministically wakes both detached relay pumps even if the
        // guest never acknowledges shutdown.
        activeClient?.close()
        activeRelayConnection?.close()
        unclaimedConnection?.close()
    }
}

private func checkedPort(_ value: UInt32) throws -> UInt16 {
    guard let port = UInt16(exactly: value) else {
        throw AgentProtocolError.invalidGuestPort(value)
    }
    return port
}

public struct AgentInfo: Codable, Equatable, Sendable {
    public var protocolVersion: UInt32
    public var kernel: String
    public var agentBuild: String
    public var uptimeSeconds: UInt64

    public init(protocolVersion: UInt32, kernel: String, agentBuild: String, uptimeSeconds: UInt64) {
        self.protocolVersion = protocolVersion
        self.kernel = kernel
        self.agentBuild = agentBuild
        self.uptimeSeconds = uptimeSeconds
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case kernel
        case agentBuild = "agent_build"
        case uptimeSeconds = "uptime_seconds"
    }
}

public struct ClockSyncResult: Equatable, Sendable {
    public var synced: Bool

    public init(synced: Bool) {
        self.synced = synced
    }
}

public struct AgentListenPort: Equatable, Sendable {
    public var `protocol`: String
    public var port: UInt16

    public init(protocol: String, port: UInt16) {
        self.protocol = `protocol`
        self.port = port
    }
}

public struct AgentPortEvent: Equatable, Sendable {
    public var action: String
    public var `protocol`: String
    public var port: UInt16

    public init(action: String, protocol: String, port: UInt16) {
        self.action = action
        self.protocol = `protocol`
        self.port = port
    }
}

public struct AgentPortSnapshot: Equatable, Sendable {
    public var ports: [AgentListenPort]
    public var added: [AgentPortEvent]
    public var removed: [AgentPortEvent]

    public init(ports: [AgentListenPort], added: [AgentPortEvent], removed: [AgentPortEvent]) {
        self.ports = ports
        self.added = added
        self.removed = removed
    }
}
