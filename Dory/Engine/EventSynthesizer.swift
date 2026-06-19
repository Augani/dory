import Foundation

enum DoryEventAction: String, Sendable, Equatable {
    case create, start, stop, die, destroy
}

struct DoryEvent: Sendable, Equatable {
    var containerID: String
    var name: String
    var image: String
    var action: DoryEventAction
}

/// Synthesizes Docker-style lifecycle events by diffing successive container snapshots.
/// Used when the underlying engine does not expose a native event feed.
enum EventSynthesizer {
    static func diff(previous: [Container], current: [Container]) -> [DoryEvent] {
        var events: [DoryEvent] = []
        let previousByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let currentByID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        for container in current {
            if let before = previousByID[container.id] {
                if before.status != container.status {
                    if container.status == .running {
                        events.append(event(container, .start))
                    } else if before.status == .running {
                        events.append(event(container, .die))
                        events.append(event(container, .stop))
                    }
                }
            } else {
                events.append(event(container, .create))
                if container.status == .running { events.append(event(container, .start)) }
            }
        }

        for container in previous where currentByID[container.id] == nil {
            if container.status == .running { events.append(event(container, .die)) }
            events.append(event(container, .destroy))
        }

        return events
    }

    private static func event(_ container: Container, _ action: DoryEventAction) -> DoryEvent {
        DoryEvent(containerID: container.id, name: container.name, image: container.image, action: action)
    }
}

/// Live broadcast of synthesized events to any number of consumers (the GUI, the shim /events).
@MainActor
final class EventBus {
    private var continuations: [UUID: AsyncStream<DoryEvent>.Continuation] = [:]

    func stream() -> AsyncStream<DoryEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.continuations[id] = nil }
            }
        }
    }

    func publish(_ events: [DoryEvent]) {
        for continuation in continuations.values {
            for event in events { continuation.yield(event) }
        }
    }
}
