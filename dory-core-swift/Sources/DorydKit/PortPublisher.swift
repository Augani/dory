import DoryCore
import Foundation

public struct PortPublishDiff: Sendable, Equatable {
    public var added: [DoryListenPort]
    public var removed: [DoryListenPort]

    public init(added: [DoryListenPort], removed: [DoryListenPort]) {
        self.added = added
        self.removed = removed
    }
}

public final class PortPublisher: @unchecked Sendable {
    private let lock = NSLock()
    private var published = Set<DoryListenPort>()

    public init() {}

    public func reconcile(_ snapshot: DoryPortsSnapshot) -> PortPublishDiff {
        let next = Set(snapshot.ports)
        lock.lock()
        let added = next.subtracting(published)
        let removed = published.subtracting(next)
        published = next
        lock.unlock()

        return PortPublishDiff(
            added: added.sortedForPublish(),
            removed: removed.sortedForPublish()
        )
    }

    public func refresh(from agent: AgentControl) throws -> PortPublishDiff {
        try reconcile(agent.portsWatch())
    }

    public var current: [DoryListenPort] {
        lock.lock()
        let ports = published.sortedForPublish()
        lock.unlock()
        return ports
    }
}

private extension Set where Element == DoryListenPort {
    func sortedForPublish() -> [DoryListenPort] {
        sorted { lhs, rhs in
            if lhs.port != rhs.port {
                return lhs.port < rhs.port
            }
            return lhs.protocol < rhs.protocol
        }
    }
}
