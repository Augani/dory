import Foundation

enum DoryEventAction: String, Sendable, Equatable {
    case create, start, stop, die, destroy
    case healthStatusHealthy = "health_status: healthy"
    case healthStatusUnhealthy = "health_status: unhealthy"
}

struct DoryEvent: Sendable, Equatable {
    var containerID: String
    var name: String
    var image: String
    var action: DoryEventAction
    var attributes: [String: String]
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
                if before.health != container.health {
                    if container.health == .healthy {
                        events.append(event(container, .healthStatusHealthy))
                    } else if container.health == .unhealthy {
                        events.append(event(container, .healthStatusUnhealthy))
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
        var attributes = ["name": container.name, "image": container.image]
        for (key, value) in container.labels {
            attributes[key] = value
        }
        return DoryEvent(containerID: container.id, name: container.name, image: container.image, action: action, attributes: attributes)
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
                guard let self else { return }
                Task { @MainActor [self] in self.continuations[id] = nil }
            }
        }
    }

    func publish(_ events: [DoryEvent]) {
        for continuation in continuations.values {
            for event in events { continuation.yield(event) }
        }
    }
}
