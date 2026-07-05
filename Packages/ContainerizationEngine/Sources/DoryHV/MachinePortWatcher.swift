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
        for event in snapshot.added where event.isTCP {
            if await forwarder.exposeMachinePort(event.port) {
                log("machine port forward: exposed 127.0.0.1:\(event.port)")
            }
        }
        for event in snapshot.removed where event.isTCP {
            if await forwarder.unexposeMachinePort(event.port) {
                log("machine port forward: released 127.0.0.1:\(event.port)")
            }
        }
        return snapshot
    }
}

private extension AgentPortEvent {
    var isTCP: Bool {
        `protocol` == "tcp" || `protocol` == "tcp6"
    }
}
