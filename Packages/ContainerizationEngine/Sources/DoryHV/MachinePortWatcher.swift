import Foundation

public protocol MachinePortForwarding: Sendable {
    func exposeMachinePort(_ port: UInt16) async -> Bool
    func unexposeMachinePort(_ port: UInt16) async -> Bool
}

public final class MachinePortWatcher: @unchecked Sendable {
    private let channel: AgentChannel
    private let forwarder: any MachinePortForwarding
    private let log: @Sendable (String) -> Void

    public init(
        channel: AgentChannel,
        forwarder: any MachinePortForwarding,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.channel = channel
        self.forwarder = forwarder
        self.log = log
    }

    @discardableResult
    public func pollOnce() async throws -> AgentPortSnapshot {
        let snapshot = try await channel.watchPorts()
        for event in snapshot.added where MachinePortPolicy.isForwardable(event) {
            if await forwarder.exposeMachinePort(event.port) {
                log("machine port forward: exposed 127.0.0.1:\(event.port)")
            }
        }
        for event in snapshot.removed where MachinePortPolicy.isForwardable(event) {
            if await forwarder.unexposeMachinePort(event.port) {
                log("machine port forward: released 127.0.0.1:\(event.port)")
            }
        }
        return snapshot
    }
}

public enum MachinePortPolicy {
    /// Guest ports that must NOT be auto-forwarded to host loopback, because they are Dory's own
    /// infrastructure inside the engine VM, not user services:
    ///   2375 dockerd (unauthenticated — the shim serves the authenticated path) and 2377 the
    ///   shutdown channel; forwarding them would expose engine control on localhost.
    ///   11434/1234/18190 are the guest agent's host-AI bridge listeners; forwarding them back to
    ///   the host would shadow the real Ollama/LM Studio the bridge exists to reach.
    /// User containers publish ports through Docker's own `-p` path (the PortForwarder driven by the
    /// docker socket), not this machine-port watcher, so nothing user-facing is filtered here.
    public static let reservedGuestPorts = Set<UInt16>([2_375, 2_377] + HostAIBridge.defaultPorts)

    public static func isForwardable(_ event: AgentPortEvent) -> Bool {
        isTCP(event.protocol) && !reservedGuestPorts.contains(event.port)
    }

    public static func isForwardable(_ port: AgentListenPort) -> Bool {
        isTCP(port.protocol) && !reservedGuestPorts.contains(port.port)
    }

    private static func isTCP(_ value: String) -> Bool {
        value == "tcp" || value == "tcp6"
    }
}
