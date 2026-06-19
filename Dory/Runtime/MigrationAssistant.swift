import Foundation

struct MigrationSummary: Sendable, Equatable {
    var imagesPulled: [String] = []
    var containersMigrated: [String] = []
    var failures: [String] = []

    var total: Int { imagesPulled.count + containersMigrated.count }
}

/// A read-only inventory of what a migration WOULD move. Computed without modifying the source — the
/// basis for a pre-flight "nothing will be deleted" screen (the #1 emotional blocker to switching).
struct MigrationInventory: Sendable, Equatable {
    var sourceName: String
    var images: Int
    var containers: Int
    var volumes: Int
    var volumeNames: [String]
}

/// Imports images and recreates container definitions from one engine onto another (e.g. from a
/// Docker/OrbStack engine onto Apple `container`). Images must be registry-pullable; local-only
/// images are reported as failures rather than silently skipped.
enum MigrationAssistant {
    /// Reads the source engine without modifying anything — for the pre-flight inventory screen.
    static func preflight(from source: any ContainerRuntime) async -> MigrationInventory? {
        guard let snapshot = try? await source.snapshot() else { return nil }
        let realImages = snapshot.images.filter { $0.repository != "<none>" && !$0.repository.isEmpty }
        return MigrationInventory(
            sourceName: source.kind.displayName,
            images: realImages.count,
            containers: snapshot.containers.count,
            volumes: snapshot.volumes.count,
            volumeNames: snapshot.volumes.map(\.name)
        )
    }

    static func migrate(
        from source: any ContainerRuntime,
        to target: any ContainerRuntime,
        recreateContainers: Bool = true,
        progress: (@Sendable (String) -> Void)? = nil
    ) async -> MigrationSummary {
        var summary = MigrationSummary()
        guard let snapshot = try? await source.snapshot() else {
            summary.failures.append("could not read source engine")
            return summary
        }

        for image in snapshot.images {
            guard image.repository != "<none>", !image.repository.isEmpty else { continue }
            let reference = "\(image.repository):\(image.tag)"
            progress?("Pulling \(reference)")
            do { try await target.pull(image: reference); summary.imagesPulled.append(reference) }
            catch { summary.failures.append("pull \(reference)") }
        }

        guard recreateContainers else { return summary }
        for container in snapshot.containers {
            progress?("Recreating \(container.name)")
            let env = (try? await source.env(containerID: container.id)) ?? []
            let spec = ContainerSpec(
                name: container.name,
                image: container.image,
                environment: Dictionary(env.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first }),
                ports: parsePorts(container.ports),
                labels: ["dory.migrated.from": source.kind.rawValue]
            )
            do { _ = try await target.create(spec); summary.containersMigrated.append(container.name) }
            catch { summary.failures.append("recreate \(container.name)") }
        }
        return summary
    }

    static func parsePorts(_ display: String) -> [String] {
        guard display != "—", !display.isEmpty else { return [] }
        return display.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "→", with: ":")
        }
    }
}
