import Foundation

/// Tracks anonymous volumes created for a container so they can be removed when the container is
/// removed with `--rm`, matching Docker's behavior (the underlying engine does not do this).
@MainActor
final class AnonymousVolumeTracker {
    private var byContainer: [String: Set<String>] = [:]

    func register(container: String, volume: String) {
        byContainer[container, default: []].insert(volume)
    }

    func volumes(for container: String) -> [String] {
        Array(byContainer[container] ?? []).sorted()
    }

    /// Removes tracking for the container and returns the anonymous volumes that should be deleted.
    @discardableResult
    func reclaim(container: String) -> [String] {
        let volumes = Array(byContainer.removeValue(forKey: container) ?? []).sorted()
        return volumes
    }

    var trackedCount: Int { byContainer.values.reduce(0) { $0 + $1.count } }
}
