import Foundation

struct MigrationSummary: Sendable, Equatable {
    var imagesImported: [String] = []
    var imagesPulled: [String] { imagesImported }
    var containersMigrated: [String] = []
    var failures: [String] = []

    var total: Int { imagesImported.count + containersMigrated.count }
}

/// A read-only inventory of what a migration WOULD move. Computed without modifying the source — the
/// basis for a pre-flight "nothing will be deleted" screen (the #1 emotional blocker to switching).
struct MigrationInventory: Sendable, Equatable {
    var sourceName: String
    var images: Int
    var containers: Int
    var volumes: Int
    var volumeNames: [String]
    var networks: Int = 0
    var composeProjects: [String] = []
    var estimatedImageBytes: Int64 = 0
    var bindMounts: Int = 0
    var namedVolumeMounts: Int = 0
    var anonymousVolumeTargets: Int = 0
    var privilegedContainers: [String] = []
    var hostNetworkContainers: [String] = []
    var containersWithPublishedPorts: Int = 0

    var confidenceLabel: String {
        if !privilegedContainers.isEmpty || !hostNetworkContainers.isEmpty { return "Needs review" }
        if namedVolumeMounts > 0 || anonymousVolumeTargets > 0 || bindMounts > 0 { return "Medium confidence" }
        return "High confidence"
    }

    var estimatedImageDiskDisplay: String {
        Self.byteCountFormatter.string(fromByteCount: estimatedImageBytes)
    }

    var transferItems: [String] {
        var items = [
            "\(images) image\(images == 1 ? "" : "s") copied by archive when possible",
            "\(containers) container definition\(containers == 1 ? "" : "s") recreated on Dory",
        ]
        if !composeProjects.isEmpty {
            items.append("\(composeProjects.count) compose project\(composeProjects.count == 1 ? "" : "s") detected: \(composeProjects.prefix(4).joined(separator: ", "))")
        }
        if networks > 0 {
            items.append("\(networks) custom network\(networks == 1 ? "" : "s") detected for recreation checks")
        }
        if containersWithPublishedPorts > 0 {
            items.append("\(containersWithPublishedPorts) container\(containersWithPublishedPorts == 1 ? "" : "s") with published ports")
        }
        return items
    }

    var attentionItems: [String] {
        var items: [String] = []
        if namedVolumeMounts > 0 || anonymousVolumeTargets > 0 || volumes > 0 {
            items.append("Volume data is not copied automatically; \(volumeReferenceCount) volume reference\(volumeReferenceCount == 1 ? "" : "s") need a manual data copy or remount.")
        }
        if bindMounts > 0 {
            items.append("\(bindMounts) bind mount\(bindMounts == 1 ? "" : "s") depend on host paths still existing on this Mac.")
        }
        if !privilegedContainers.isEmpty {
            items.append("Privileged containers need review: \(privilegedContainers.prefix(4).joined(separator: ", ")).")
        }
        if !hostNetworkContainers.isEmpty {
            items.append("Host-network containers need review: \(hostNetworkContainers.prefix(4).joined(separator: ", ")).")
        }
        if estimatedImageBytes > 0 {
            items.append("Plan for at least \(estimatedImageDiskDisplay) of image space, plus any volume data you choose to copy.")
        }
        if items.isEmpty {
            items.append("No obvious blockers found. The source engine stays read-only until you start the import.")
        }
        return items
    }

    private var volumeReferenceCount: Int {
        max(volumes, namedVolumeMounts + anonymousVolumeTargets)
    }

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        return formatter
    }()
}

/// Imports images and recreates container definitions from one engine onto another. When both
/// engines can export/import Docker image archives, image bytes are copied directly so local-only
/// images migrate too. Registry pull is only the fallback for runtimes without archive transfer.
enum MigrationAssistant {
    /// Reads the source engine without modifying anything — for the pre-flight inventory screen.
    static func preflight(from source: any ContainerRuntime) async -> MigrationInventory? {
        guard let snapshot = try? await source.snapshot() else { return nil }
        let realImages = snapshot.images.filter { $0.repository != "<none>" && !$0.repository.isEmpty }
        let containers = snapshot.containers
        let composeProjects = Array(Set(containers.compactMap(\.composeProject))).sorted()
        let mounts = containers.flatMap(\.mounts)
        let namedVolumeMounts = mounts.filter { $0.type == "volume" }.count
        let bindMounts = mounts.filter { mount in
            mount.type == "bind" || (mount.source?.hasPrefix("/") ?? false)
        }.count
        let anonymousVolumeTargets = containers.map(\.volumeTargets.count).reduce(0, +)
        let privilegedContainers = containers
            .filter { $0.privileged == true }
            .map(\.name)
            .sorted()
        let hostNetworkContainers = containers
            .filter { ($0.networkMode ?? "").lowercased() == "host" }
            .map(\.name)
            .sorted()
        let customNetworks = snapshot.networks.filter { network in
            !["bridge", "host", "none"].contains(network.name)
        }
        return MigrationInventory(
            sourceName: source.kind.displayName,
            images: realImages.count,
            containers: containers.count,
            volumes: snapshot.volumes.count,
            volumeNames: snapshot.volumes.map(\.name).sorted(),
            networks: customNetworks.count,
            composeProjects: composeProjects,
            estimatedImageBytes: realImages.map(estimatedBytes).reduce(0, +),
            bindMounts: bindMounts,
            namedVolumeMounts: namedVolumeMounts,
            anonymousVolumeTargets: anonymousVolumeTargets,
            privilegedContainers: privilegedContainers,
            hostNetworkContainers: hostNetworkContainers,
            containersWithPublishedPorts: containers.filter { !$0.ports.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.ports != "—" }.count
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
            var archiveError: Error?
            if source.supportsImageArchiveTransfer && target.supportsImageArchiveTransfer {
                progress?("Copying \(reference)")
                do {
                    if try await copyImageArchive(reference: reference, from: source, to: target) {
                        summary.imagesImported.append(reference)
                        continue
                    }
                } catch {
                    archiveError = error
                }
            }
            progress?("Pulling \(reference)")
            do { try await target.pull(image: reference); summary.imagesImported.append(reference) }
            catch {
                if let archiveError {
                    summary.failures.append("import \(reference) (archive: \(archiveError); pull: \(error))")
                } else {
                    summary.failures.append("pull \(reference)")
                }
            }
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
        ContainerPortDisplay.mappings(display).map(\.containerSpec)
    }

    static func estimatedBytes(for display: String) -> Int64 {
        let trimmed = display.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
        guard !trimmed.isEmpty else { return 0 }
        let scanner = Scanner(string: trimmed)
        scanner.charactersToBeSkipped = .whitespacesAndNewlines
        guard let number = scanner.scanDouble() else { return 0 }
        let unit = String(trimmed[scanner.currentIndex...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let multiplier: Double
        if unit.hasPrefix("tb") || unit.hasPrefix("tib") {
            multiplier = 1_000_000_000_000
        } else if unit.hasPrefix("gb") || unit.hasPrefix("gib") {
            multiplier = 1_000_000_000
        } else if unit.hasPrefix("mb") || unit.hasPrefix("mib") {
            multiplier = 1_000_000
        } else if unit.hasPrefix("kb") || unit.hasPrefix("kib") {
            multiplier = 1_000
        } else if unit.hasPrefix("b") || unit.isEmpty {
            multiplier = 1
        } else {
            multiplier = 1
        }
        return max(0, Int64((number * multiplier).rounded()))
    }

    private static func copyImageArchive(reference: String, from source: any ContainerRuntime, to target: any ContainerRuntime) async throws -> Bool {
        let stream = source.saveImage(reference: reference)
        try await target.loadImage(stream: stream)
        return true
    }

    private static func estimatedBytes(_ image: DockerImage) -> Int64 {
        image.sizeBytes > 0 ? image.sizeBytes : estimatedBytes(for: image.size)
    }
}
