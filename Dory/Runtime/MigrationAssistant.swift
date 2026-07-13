import CryptoKit
import Foundation

struct MigrationSummary: Sendable, Equatable {
    var imagesImported: [String] = []
    var imagesPulled: [String] { imagesImported }
    var volumesCopied: [String] = []
    var networksCreated: [String] = []
    var containersMigrated: [String] = []
    /// Running/paused source containers whose fixed host ports are still owned by the source
    /// engine. Their definitions are complete on Dory, but starting them is deliberately deferred
    /// until the user stops the source engine rather than disrupting or mutating it.
    var containersAwaitingSourcePorts: [String] = []
    var warnings: [String] = []
    var failures: [String] = []

    var total: Int { imagesImported.count + volumesCopied.count + networksCreated.count + containersMigrated.count }
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
    var imagesAlreadyOnDory: Int = 0
    var estimatedVolumeBytes: Int64 = 0
    var volumeSizePreflightAvailable: Bool = false
    var unknownVolumeSizes: Int = 0
    var estimatedContainerWritableBytes: Int64 = 0
    var containerWritableSizePreflightAvailable: Bool = true
    var unknownContainerWritableSizes: Int = 0
    var availableHostBytes: Int64 = 0
    var hostDiskPreflightAvailable: Bool = true
    var estimatedTargetDockerBytes: Int64 = 0
    var targetUsagePreflightAvailable: Bool = true
    /// Docker's archive API needs a temporary container on both engines to expose a named volume.
    /// At least one source image/container image must therefore be available before any target
    /// volume can be created.
    var volumeHelperImageAvailable: Bool = true
    var bindMounts: Int = 0
    var namedVolumeMounts: Int = 0
    var anonymousVolumeTargets: Int = 0
    var privilegedContainers: [String] = []
    var hostNetworkContainers: [String] = []
    var runningVolumeBackedContainers: [String] = []
    var runningWritableLayerContainers: [String] = []
    var portabilityBlockers: [String] = []
    var targetCollisionBlockers: [String] = []
    var replaceableEmptyTargetVolumes: [String] = []
    var containersWithPublishedPorts: Int = 0
    var runningContainersWithPublishedPorts: Int = 0

    var confidenceLabel: String {
        if isImportBlocked { return "Blocked" }
        if !privilegedContainers.isEmpty || !hostNetworkContainers.isEmpty { return "Needs review" }
        if namedVolumeMounts > 0 || anonymousVolumeTargets > 0 || bindMounts > 0 { return "Medium confidence" }
        return "High confidence"
    }

    var estimatedImageDiskDisplay: String {
        Self.byteCountFormatter.string(fromByteCount: estimatedImageBytes)
    }

    var estimatedVolumeDiskDisplay: String {
        Self.byteCountFormatter.string(fromByteCount: estimatedVolumeBytes)
    }

    var estimatedTransferBytes: Int64 {
        estimatedImageBytes + estimatedVolumeBytes + estimatedContainerWritableBytes
    }
    var requiredHostBytes: Int64 {
        guard estimatedTransferBytes > 0 else { return 0 }
        let twentyPercent = estimatedTransferBytes / 5
        return estimatedTransferBytes + max(4_000_000_000, twentyPercent)
    }
    var requiredHostDiskDisplay: String { Self.byteCountFormatter.string(fromByteCount: requiredHostBytes) }
    var availableHostDiskDisplay: String { Self.byteCountFormatter.string(fromByteCount: availableHostBytes) }
    var additionalHostBytesRequired: Int64 {
        guard hostDiskPreflightAvailable else { return 0 }
        return max(0, requiredHostBytes - availableHostBytes)
    }
    var additionalHostDiskDisplay: String {
        Self.byteCountFormatter.string(fromByteCount: additionalHostBytesRequired)
    }
    var isHostDiskInsufficient: Bool {
        hostDiskPreflightAvailable && availableHostBytes < requiredHostBytes
    }
    var isHostDiskUnknown: Bool { !hostDiskPreflightAvailable }
    private static let engineDiskLogicalBytes: Int64 = 128 * 1024 * 1024 * 1024
    /// The growth gate requires at least this much guest-visible ext4 capacity. Admission uses the
    /// proven usable floor, not the sparse file's larger logical length, so ext4 metadata/reserved
    /// blocks cannot turn a nominally fitting migration into ENOSPC.
    private static let engineDiskUsableBytes: Int64 = 120 * 1024 * 1024 * 1024
    var requiredEngineBytes: Int64 {
        let usedAndIncoming = estimatedTargetDockerBytes + estimatedTransferBytes
        guard usedAndIncoming > 0 else { return 0 }
        return usedAndIncoming + max(4_000_000_000, usedAndIncoming / 5)
    }
    var requiredEngineDiskDisplay: String { Self.byteCountFormatter.string(fromByteCount: requiredEngineBytes) }
    var engineDiskCapacityDisplay: String { Self.byteCountFormatter.string(fromByteCount: Self.engineDiskLogicalBytes) }
    var isEngineDiskInsufficient: Bool { requiredEngineBytes > Self.engineDiskUsableBytes }
    var isVolumeSizeUnknown: Bool {
        volumes > 0 && (!volumeSizePreflightAvailable || unknownVolumeSizes > 0)
    }
    var isContainerWritableSizeUnknown: Bool {
        containers > 0 && (!containerWritableSizePreflightAvailable || unknownContainerWritableSizes > 0)
    }
    var isVolumeHelperUnavailable: Bool { volumes > 0 && !volumeHelperImageAvailable }
    var isTargetUsageUnknown: Bool { !targetUsagePreflightAvailable }
    var isLiveVolumeCopyUnsafe: Bool { !runningVolumeBackedContainers.isEmpty }
    var isLiveWritableLayerSnapshotUnsafe: Bool { !runningWritableLayerContainers.isEmpty }
    var isPortabilityBlocked: Bool { !portabilityBlockers.isEmpty }
    var isTargetCollisionBlocked: Bool { !targetCollisionBlockers.isEmpty }
    var isImportBlocked: Bool {
        isHostDiskUnknown || isHostDiskInsufficient || isEngineDiskInsufficient || isVolumeSizeUnknown
            || isContainerWritableSizeUnknown || isLiveWritableLayerSnapshotUnsafe
            || isVolumeHelperUnavailable || isTargetUsageUnknown || isLiveVolumeCopyUnsafe
            || isPortabilityBlocked || isTargetCollisionBlocked
    }

    var transferItems: [String] {
        var items = [
            "\(images) image\(images == 1 ? "" : "s") copied by archive when possible"
                + (imagesAlreadyOnDory > 0 ? "; \(imagesAlreadyOnDory) exact image\(imagesAlreadyOnDory == 1 ? " is" : "s are") already on Dory" : ""),
            "\(containers) container definition\(containers == 1 ? "" : "s") recreated on Dory",
        ]
        if volumes > 0 {
            let size = estimatedVolumeBytes > 0 ? " (\(estimatedVolumeDiskDisplay))" : ""
            items.append("\(volumes) named volume\(volumes == 1 ? "" : "s") copied with data\(size)")
        }
        if estimatedContainerWritableBytes > 0 {
            items.append(
                "Container writable-layer changes copied with data (\(Self.byteCountFormatter.string(fromByteCount: estimatedContainerWritableBytes)))"
            )
        }
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
            items.append("Named Docker volume data is copied through temporary helper containers; source volumes are mounted read-only.")
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
        if isLiveVolumeCopyUnsafe {
            items.append(
                "Import is blocked before writes because named-volume data is still being written by: \(runningVolumeBackedContainers.prefix(4).joined(separator: ", ")). Stop or pause those source containers, refresh, and import again for a consistent copy."
            )
        }
        if isLiveWritableLayerSnapshotUnsafe {
            items.append(
                "Import is blocked before writes because running containers have writable-layer changes: \(runningWritableLayerContainers.prefix(4).joined(separator: ", ")). Stop or pause them, refresh, and import again for a consistent filesystem snapshot."
            )
        }
        if isPortabilityBlocked {
            items.append(contentsOf: portabilityBlockers.prefix(6).map { "Import is blocked before writes: \($0)" })
        }
        if isTargetCollisionBlocked {
            items.append(
                "Import is blocked before writes by \(targetCollisionBlockers.count) same-name target conflict\(targetCollisionBlockers.count == 1 ? "" : "s"); resolve every listed target conflict or use a clean Dory engine."
            )
        }
        if !replaceableEmptyTargetVolumes.isEmpty {
            items.append(
                "\(replaceableEmptyTargetVolumes.count) same-name Dory volume\(replaceableEmptyTargetVolumes.count == 1 ? " is" : "s are") empty, detached, and contract-compatible; import can safely replace \(replaceableEmptyTargetVolumes.count == 1 ? "it" : "them") while preserving labels."
            )
        }
        if runningContainersWithPublishedPorts > 0 {
            items.append(
                "\(runningContainersWithPublishedPorts) running container\(runningContainersWithPublishedPorts == 1 ? "" : "s") with fixed host ports will be imported stopped until the source engine releases those ports."
            )
        }
        if estimatedImageBytes > 0 {
            items.append("Images currently use about \(estimatedImageDiskDisplay) on the source engine.")
        }
        if isHostDiskUnknown {
            items.append(
                "Import is blocked before writes because macOS did not report available host disk space."
            )
        } else if availableHostBytes >= 0 {
            if isHostDiskInsufficient {
                items.append(
                    "Not enough free disk: free at least \(additionalHostDiskDisplay) more. Dory requires about \(requiredHostDiskDisplay), including safety headroom, but this Mac has \(availableHostDiskDisplay) available. If Dory data was recently pruned, restart Dory's engine first so its boot-time trim can return deleted blocks to macOS."
                )
            } else if requiredHostBytes > 0 {
                items.append(
                    "Disk preflight: about \(requiredHostDiskDisplay) required including safety headroom; \(availableHostDiskDisplay) available."
                )
            }
        }
        if isVolumeSizeUnknown {
            let detail = unknownVolumeSizes > 0
                ? "\(unknownVolumeSizes) named volume size\(unknownVolumeSizes == 1 ? " is" : "s are") unknown"
                : "the source engine did not return named-volume disk usage"
            items.append("Import is blocked before writes because \(detail); Dory cannot prove the data will fit safely.")
        }
        if isContainerWritableSizeUnknown {
            let detail = unknownContainerWritableSizes > 0
                ? "\(unknownContainerWritableSizes) container writable-layer size\(unknownContainerWritableSizes == 1 ? " is" : "s are") unknown"
                : "the source engine did not return container writable-layer usage"
            items.append("Import is blocked before writes because \(detail); Dory cannot prove or preserve all container filesystem changes safely.")
        }
        if isVolumeHelperUnavailable {
            items.append(
                "Import is blocked before writes because the source has named volumes but no usable image for the temporary read-only volume helper."
            )
        }
        if isTargetUsageUnknown {
            items.append(
                "Import is blocked before writes because Dory could not measure its existing Docker data usage for the engine-capacity check."
            )
        }
        if isEngineDiskInsufficient {
            items.append(
                "Import is blocked before writes because Dory's sparse \(engineDiskCapacityDisplay) engine disk would need about \(requiredEngineDiskDisplay), including existing target data and safety headroom."
            )
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
    private static let defaultNetworkNames: Set<String> = ["bridge", "host", "none"]

    /// Reads the source engine without modifying anything — for the pre-flight inventory screen.
    static func preflight(
        from source: any ContainerRuntime,
        to target: (any ContainerRuntime)? = nil
    ) async -> MigrationInventory? {
        guard var snapshot = try? await source.migrationSnapshot() else { return nil }
        let sourceIdentifier = source.migrationSourceIdentifier
        snapshot.containers.removeAll {
            isTemporaryMigrationHelper($0.labels, sourceIdentifier: sourceIdentifier)
        }
        snapshot.images.removeAll {
            isTemporaryMigrationImage($0, sourceIdentifier: sourceIdentifier)
        }
        let writableSizes = try? await source.migrationContainerWritableSizes()
        let containerImageIDs = snapshot.containers.compactMap(\.sourceImageID)
        // A container can outlive deletion of its image tag. Count and capacity-plan that dangling
        // image even though it is not a user-visible image-list row; migration can recover it by
        // immutable content ID or a non-pausing temporary snapshot.
        let migrationImages = snapshot.images.filter { image in
            image.repository != "<none>" && !image.repository.isEmpty
                || containerImageIDs.contains { imageIDsMatch($0, image.imageID) }
        }
        let targetSnapshot: RuntimeSnapshot?
        if let target {
            targetSnapshot = try? await target.migrationSnapshot()
        } else {
            targetSnapshot = nil
        }
        if target != nil, targetSnapshot == nil { return nil }
        let filteredTargetSnapshot = targetSnapshot.map { value -> RuntimeSnapshot in
            var value = value
            value.containers.removeAll {
                isTemporaryMigrationHelper($0.labels, sourceIdentifier: sourceIdentifier)
            }
            value.images.removeAll {
                isTemporaryMigrationImage($0, sourceIdentifier: sourceIdentifier)
            }
            return value
        }
        let targetImages = imageReferenceIndex(filteredTargetSnapshot?.images ?? [])
        var reusableImages: [DockerImage] = []
        var targetCollisionBlockers: [String] = []
        var replaceableEmptyTargetVolumes: [String] = []
        for image in migrationImages {
            var reusable = filteredTargetSnapshot?.images.contains {
                imageIDsMatch(image.imageID, $0.imageID)
            } ?? false
            for reference in imageReferences(for: image) {
                guard let existing = targetImages[canonicalImageReference(reference)] else { continue }
                let reusableWithoutInspection = reference.contains("@sha256:")
                    || imageIDsMatch(image.imageID, existing.imageID)
                    || isFinalMigrationSnapshotImage(existing, sourceIdentifier: sourceIdentifier)
                let reusableByContract = reusableWithoutInspection ? false : await imageContractsMatch(
                        sourceReference: reference,
                        targetReference: portableTargetReference(for: reference),
                        source: source,
                        target: target
                    )
                if reusableWithoutInspection || reusableByContract {
                    reusable = true
                } else {
                    targetCollisionBlockers.append(
                        "Dory already has image tag \(portableTargetReference(for: reference)) with different or unverifiable content"
                    )
                }
            }
            if reusable { reusableImages.append(image) }
        }
        for container in snapshot.containers where (writableSizes?[container.id] ?? 0) > 0 {
            let finalReference = containerSnapshotReference(
                sourceIdentifier: sourceIdentifier,
                containerID: container.id
            )
            let reservedReferences = [
                (kind: "snapshot", reference: finalReference),
                (kind: "rollback", reference: containerSnapshotRollbackReference(
                    sourceIdentifier: sourceIdentifier,
                    containerID: container.id
                )),
            ]
            for reserved in reservedReferences {
                guard let existing = targetImages[canonicalImageReference(reserved.reference)] else { continue }
                if !isContainerSnapshotImage(
                    existing,
                    sourceIdentifier: sourceIdentifier,
                    containerID: container.id
                ) {
                    targetCollisionBlockers.append(
                        "Dory already has the reserved writable-layer \(reserved.kind) reference for container \(container.name), but it is not owned by this source container"
                    )
                }
            }
        }
        let reusableImageIDs = Set(reusableImages.map(\.id))
        let remainingImages = migrationImages.filter { !reusableImageIDs.contains($0.id) }
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
        let runningVolumeBackedContainers = containers
            .filter { container in
                container.status == .running && container.mounts.contains {
                    $0.type == "volume" && !$0.readOnly
                }
            }
            .map(\.name)
            .sorted()
        let unknownContainerWritableSizes = containers.filter {
            writableSizes?[$0.id] == nil || (writableSizes?[$0.id] ?? -1) < 0
        }.count
        let estimatedContainerWritableBytes = containers.reduce(Int64(0)) {
            $0 + max(0, writableSizes?[$1.id] ?? 0)
        }
        let runningWritableLayerContainers = containers.filter {
            $0.status == .running && (writableSizes?[$0.id] ?? 0) > 0
        }.map(\.name).sorted()
        var portabilityBlockers: [String] = []
        if source.supportsRawProxy {
            for container in containers {
                if let spec = await inspectedMigrationSpec(for: container, source: source) {
                    portabilityBlockers.append(contentsOf: portabilityFailures(for: spec, containerName: container.name))
                } else {
                    portabilityBlockers.append(
                        "inspect \(container.name) did not return a complete portable container definition"
                    )
                }
            }
        }
        let customNetworks = snapshot.networks.filter { !defaultNetworkNames.contains($0.name) }
        for network in customNetworks {
            let driver = network.driver.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !driver.isEmpty, driver != "—", driver != "bridge" {
                portabilityBlockers.append(
                    "network \(network.name) uses nonportable driver \(network.driver)"
                )
            }
            if source.supportsRawProxy {
                guard let object = await inspectedNetworkObject(name: network.name, on: source) else {
                    portabilityBlockers.append(
                        "network \(network.name) did not return a complete driver/IPAM/options contract"
                    )
                    continue
                }
                _ = networkSubnets(in: object, fallback: network.subnet)
            }
        }
        for volume in snapshot.volumes {
            if normalizedVolumeDriver(volume.driver) != "local" {
                portabilityBlockers.append(
                    "volume \(volume.name) requires external driver \(volume.driver)"
                )
            } else if !volume.options.isEmpty {
                portabilityBlockers.append(
                    "volume \(volume.name) has local-driver options that may reference host or remote storage"
                )
            }
        }
        if let targetSnapshot = filteredTargetSnapshot, let target {
            let sourceMarker = source.kind.rawValue
            let targetVolumes = Dictionary(
                targetSnapshot.volumes.map { ($0.name, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let targetVolumeSizes = await namedVolumeSizes(on: target)
            for volume in snapshot.volumes {
                guard let existing = targetVolumes[volume.name] else { continue }
                if isMigrationOwned(
                    existing.labels,
                    sourceMarker: sourceMarker,
                    sourceIdentifier: sourceIdentifier
                ) {
                    if normalizedVolumeDriver(existing.driver) != normalizedVolumeDriver(volume.driver)
                        || existing.options != volume.options {
                        targetCollisionBlockers.append(
                            "Dory's prior imported volume \(volume.name) has a different driver/options contract"
                        )
                    }
                    continue
                }
                if isLegacyMigrationOwned(existing.labels, sourceMarker: sourceMarker) {
                    let attached = targetSnapshot.containers.contains { container in
                        container.mounts.contains {
                            $0.type == "volume" && $0.source == volume.name
                        }
                    }
                    if !attached, targetVolumeSizes?[volume.name] == 0 { continue }
                    targetCollisionBlockers.append(
                        "Dory's earlier imported volume \(volume.name) contains data, is attached, or could not be measured"
                    )
                    continue
                }
                let attached = targetSnapshot.containers.contains { container in
                    container.mounts.contains {
                        $0.type == "volume" && $0.source == volume.name
                    }
                }
                let contractMatches = normalizedVolumeDriver(existing.driver)
                    == normalizedVolumeDriver(volume.driver)
                    && existing.options == volume.options
                if !attached, contractMatches, targetVolumeSizes?[volume.name] == 0 {
                    replaceableEmptyTargetVolumes.append(volume.name)
                    continue
                }
                targetCollisionBlockers.append(
                    "Dory already has an unrelated volume named \(volume.name); back it up and resolve the conflict, or use a clean Dory engine"
                )
            }

            let targetNetworks = Dictionary(
                targetSnapshot.networks.map { ($0.name, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for network in customNetworks {
                guard let existing = targetNetworks[network.name] else { continue }
                if isMigrationOwned(
                    existing.labels,
                    sourceMarker: sourceMarker,
                    sourceIdentifier: sourceIdentifier
                ) { continue }
                if isLegacyMigrationOwned(existing.labels, sourceMarker: sourceMarker) {
                    let attached = targetSnapshot.containers.contains { container in
                        container.networks.contains(network.name)
                            || container.networkEndpointSettings[network.name] != nil
                    }
                    if !attached { continue }
                }
                targetCollisionBlockers.append(
                    "Dory already has an unrelated or attached network named \(network.name); resolve the conflict or use a clean Dory engine"
                )
            }

            let targetContainers = Dictionary(
                targetSnapshot.containers.map { ($0.name, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for container in containers {
                guard let existing = targetContainers[container.name] else { continue }
                if isMigrationOwned(
                    existing.labels,
                    sourceMarker: sourceMarker,
                    sourceIdentifier: sourceIdentifier
                ) {
                    if let priorContainerID = existing.labels["dory.migrated.container-id"],
                       !priorContainerID.isEmpty,
                       priorContainerID != container.id {
                        targetCollisionBlockers.append(
                            "Dory's prior imported container \(container.name) came from a different source container ID"
                        )
                    }
                    continue
                }
                targetCollisionBlockers.append(
                    "Dory already has an unrelated container named \(container.name); resolve the conflict or use a clean Dory engine"
                )
            }
        }
        let volumeUsage = await volumeUsage(
            from: source,
            expectedNames: snapshot.volumes.map(\.name)
        )
        let targetDockerUsage = await dockerUsage(on: target)
        let volumeHelperImageAvailable = !migrationImages.isEmpty || containers.contains { container in
            !container.image.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !(container.sourceImageID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
        let publishedPortContainers = containers.filter {
            !$0.ports.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.ports != "—"
        }
        return MigrationInventory(
            sourceName: sourceDisplayName(source),
            images: migrationImages.count,
            containers: containers.count,
            volumes: snapshot.volumes.count,
            volumeNames: snapshot.volumes.map(\.name).sorted(),
            networks: customNetworks.count,
            composeProjects: composeProjects,
            estimatedImageBytes: remainingImages.map(estimatedBytes).reduce(0, +),
            imagesAlreadyOnDory: reusableImages.count,
            estimatedVolumeBytes: volumeUsage.bytes,
            volumeSizePreflightAvailable: volumeUsage.available,
            unknownVolumeSizes: volumeUsage.unknown,
            estimatedContainerWritableBytes: estimatedContainerWritableBytes,
            containerWritableSizePreflightAvailable: writableSizes != nil,
            unknownContainerWritableSizes: unknownContainerWritableSizes,
            hostDiskPreflightAvailable: false,
            estimatedTargetDockerBytes: targetDockerUsage ?? 0,
            targetUsagePreflightAvailable: target == nil || targetDockerUsage != nil,
            volumeHelperImageAvailable: volumeHelperImageAvailable,
            bindMounts: bindMounts,
            namedVolumeMounts: namedVolumeMounts,
            anonymousVolumeTargets: anonymousVolumeTargets,
            privilegedContainers: privilegedContainers,
            hostNetworkContainers: hostNetworkContainers,
            runningVolumeBackedContainers: runningVolumeBackedContainers,
            runningWritableLayerContainers: runningWritableLayerContainers,
            portabilityBlockers: portabilityBlockers,
            targetCollisionBlockers: Array(Set(targetCollisionBlockers)).sorted(),
            replaceableEmptyTargetVolumes: Array(Set(replaceableEmptyTargetVolumes)).sorted(),
            containersWithPublishedPorts: publishedPortContainers.count,
            runningContainersWithPublishedPorts: publishedPortContainers.filter {
                $0.status == .running || $0.status == .paused
            }.count
        )
    }

    private static func imageReferences(for image: DockerImage) -> [String] {
        var references = image.additionalReferences
        if image.repository != "<none>", !image.repository.isEmpty {
            references.insert(
                image.tag == "<none>" || image.tag.isEmpty
                    ? image.repository
                    : "\(image.repository):\(image.tag)",
                at: 0
            )
        }
        return references
    }

    private struct VolumeUsageSummary {
        var bytes: Int64 = 0
        var unknown: Int = 0
        var available = false
    }

    private static func volumeUsage(
        from source: any ContainerRuntime,
        expectedNames: [String]
    ) async -> VolumeUsageSummary {
        guard let byName = await namedVolumeSizes(on: source) else { return VolumeUsageSummary() }
        var summary = VolumeUsageSummary(available: true)
        for name in expectedNames {
            guard let size = byName[name] else {
                summary.unknown += 1
                continue
            }
            summary.bytes += size
        }
        return summary
    }

    private static func namedVolumeSizes(on runtime: any ContainerRuntime) async -> [String: Int64]? {
        guard runtime.supportsRawProxy,
              let response = await runtime.proxyRequest(
                  method: "GET",
                  path: "/system/df?type=volume",
                  headers: [(name: "Accept", value: "application/json")],
                  body: Data()
              ), response.isSuccess,
              let root = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let volumes = root["Volumes"] as? [[String: Any]] else { return nil }
        var sizes: [String: Int64] = [:]
        for volume in volumes {
            guard let name = volume["Name"] as? String, !name.isEmpty,
                  sizes[name] == nil,
                  let usage = volume["UsageData"] as? [String: Any],
                  let number = usage["Size"] as? NSNumber,
                  number.int64Value >= 0 else { return nil }
            sizes[name] = number.int64Value
        }
        return sizes
    }

    private static func dockerUsage(on runtime: (any ContainerRuntime)?) async -> Int64? {
        guard let runtime else { return nil }
        guard runtime.supportsRawProxy,
              let response = await runtime.proxyRequest(
                  method: "GET",
                  path: "/system/df",
                  headers: [(name: "Accept", value: "application/json")],
                  body: Data()
              ), response.isSuccess,
              let root = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else { return nil }
        func nonnegative(_ value: Any?) -> Int64? {
            guard let number = value as? NSNumber, number.int64Value >= 0 else { return nil }
            return number.int64Value
        }
        let aggregateKeys = ["ImageUsage", "VolumeUsage", "ContainerUsage", "BuildCacheUsage"]
        let aggregate = aggregateKeys.compactMap { key in
            nonnegative((root[key] as? [String: Any])?["TotalSize"])
        }
        if aggregate.count == aggregateKeys.count { return aggregate.reduce(0, +) }

        // Older daemons expose only the legacy arrays. Fail closed on absent/invalid size fields,
        // except never-started `created` containers: Docker legitimately omits SizeRw and their
        // writable layer is still zero.
        func objects(_ key: String) -> [[String: Any]]? {
            if let values = root[key] as? [[String: Any]] { return values }
            return root[key] is NSNull ? [] : nil
        }
        guard let layers = nonnegative(root["LayersSize"]),
              let volumeObjects = objects("Volumes"),
              let containerObjects = objects("Containers"),
              let buildObjects = objects("BuildCache") else { return nil }
        var volumes: Int64 = 0
        for volume in volumeObjects {
            guard let size = nonnegative((volume["UsageData"] as? [String: Any])?["Size"]) else { return nil }
            volumes += size
        }
        var containers: Int64 = 0
        for container in containerObjects {
            if let size = nonnegative(container["SizeRw"]) {
                containers += size
            } else if ((container["State"] as? String) ?? "").lowercased() != "created" {
                return nil
            }
        }
        var buildCache: Int64 = 0
        for item in buildObjects {
            guard let size = nonnegative(item["Size"]) else { return nil }
            buildCache += size
        }
        return layers + volumes + containers + buildCache
    }

    private static func sourceDisplayName(_ source: any ContainerRuntime) -> String {
        if let docker = source as? DockerEngineRuntime {
            return docker.displayName
        }
        return source.kind.displayName
    }

    static func migrate(
        from source: any ContainerRuntime,
        to target: any ContainerRuntime,
        recreateContainers: Bool = true,
        progress: (@Sendable (String) -> Void)? = nil
    ) async -> MigrationSummary {
        var summary = MigrationSummary()
        guard var snapshot = try? await source.migrationSnapshot() else {
            summary.failures.append("could not read source engine")
            return summary
        }
        let sourceIdentifier = source.migrationSourceIdentifier
        let userContainers = snapshot.containers.filter {
            !isTemporaryMigrationHelper($0.labels, sourceIdentifier: sourceIdentifier)
        }
        guard let initialContainerWritableSizes = try? await source.migrationContainerWritableSizes() else {
            summary.failures.append("could not measure source container writable layers; migration stopped before writes")
            return summary
        }
        let missingWritableSizes = userContainers.filter {
            initialContainerWritableSizes[$0.id] == nil || (initialContainerWritableSizes[$0.id] ?? -1) < 0
        }.map(\.name).sorted()
        guard missingWritableSizes.isEmpty else {
            summary.failures.append(
                "migration stopped before writes because writable-layer sizes are unavailable for: \(missingWritableSizes.joined(separator: ", "))"
            )
            return summary
        }
        let runningVolumeBackedContainers = userContainers
            .filter { container in
                container.status == .running && container.mounts.contains {
                    $0.type == "volume" && !$0.readOnly
                }
            }
            .map(\.name)
            .sorted()
        guard runningVolumeBackedContainers.isEmpty else {
            summary.failures.append(
                "migration stopped before writes because named-volume data is still live in: \(runningVolumeBackedContainers.joined(separator: ", ")); stop or pause those source containers and retry for a consistent copy"
            )
            return summary
        }
        let runningWritableLayerContainers = userContainers.filter {
            $0.status == .running && (initialContainerWritableSizes[$0.id] ?? 0) > 0
        }.map(\.name).sorted()
        guard runningWritableLayerContainers.isEmpty else {
            summary.failures.append(
                "migration stopped before writes because running containers have writable-layer changes: \(runningWritableLayerContainers.joined(separator: ", ")); stop or pause them and retry for a consistent filesystem snapshot"
            )
            return summary
        }
        guard var targetSnapshot = try? await target.migrationSnapshot() else {
            summary.failures.append("could not read Dory target engine; migration stopped before making changes")
            return summary
        }
        let staleSourceHelpers = snapshot.containers.filter {
            isTemporaryMigrationHelper($0.labels, sourceIdentifier: sourceIdentifier)
        }
        let staleTargetHelpers = targetSnapshot.containers.filter {
            isTemporaryMigrationHelper($0.labels, sourceIdentifier: sourceIdentifier)
        }
        let staleSourceImages = snapshot.images.filter {
            isTemporaryMigrationImage($0, sourceIdentifier: sourceIdentifier)
        }
        let staleTargetImages = targetSnapshot.images.filter {
            isTemporaryMigrationImage($0, sourceIdentifier: sourceIdentifier)
        }
        for helper in staleSourceHelpers {
            do { try await removeVolumeHelper(helper.id, from: source) }
            catch { summary.failures.append("cleanup stale source migration helper \(helper.id): \(error)") }
        }
        for helper in staleTargetHelpers {
            do { try await removeVolumeHelper(helper.id, from: target) }
            catch { summary.failures.append("cleanup stale target migration helper \(helper.id): \(error)") }
        }
        for image in staleSourceImages {
            let temporaryReferences = imageReferences(for: image).filter {
                $0.hasPrefix("dory-migration-temporary/snapshot:")
            }
            let references = temporaryReferences.isEmpty ? [image.imageID] : temporaryReferences
            for reference in references {
                do { try await removeTemporaryImageReferenceStrict(reference, from: source) }
                catch { summary.failures.append("cleanup stale source migration image \(reference): \(error)") }
            }
        }
        for image in staleTargetImages {
            let temporaryReferences = imageReferences(for: image).filter {
                $0.hasPrefix("dory-migration-temporary/snapshot:")
            }
            let references = temporaryReferences.isEmpty ? [image.imageID] : temporaryReferences
            for reference in references {
                do { try await removeTemporaryImageReferenceStrict(reference, from: target) }
                catch { summary.failures.append("cleanup stale target migration image \(reference): \(error)") }
            }
        }
        guard summary.failures.isEmpty else { return summary }
        let staleSourceIDs = Set(staleSourceHelpers.map(\.id))
        let staleTargetIDs = Set(staleTargetHelpers.map(\.id))
        snapshot.containers.removeAll { staleSourceIDs.contains($0.id) }
        targetSnapshot.containers.removeAll { staleTargetIDs.contains($0.id) }
        let staleSourceImageIDs = Set(staleSourceImages.map(\.id))
        snapshot.images.removeAll { staleSourceImageIDs.contains($0.id) }
        let staleTargetImageIDs = Set(staleTargetImages.map(\.id))
        targetSnapshot.images.removeAll { staleTargetImageIDs.contains($0.id) }
        if !staleSourceHelpers.isEmpty || !staleTargetHelpers.isEmpty
            || !staleSourceImages.isEmpty || !staleTargetImages.isEmpty {
            guard let refreshedSource = try? await source.migrationSnapshot(),
                  let refreshedTarget = try? await target.migrationSnapshot() else {
                summary.failures.append("could not verify migration cleanup with a fresh engine inventory")
                return summary
            }
            snapshot = refreshedSource
            targetSnapshot = refreshedTarget
            let cleanupStillPresent = snapshot.containers.contains {
                isTemporaryMigrationHelper($0.labels, sourceIdentifier: sourceIdentifier)
            } || targetSnapshot.containers.contains {
                isTemporaryMigrationHelper($0.labels, sourceIdentifier: sourceIdentifier)
            } || snapshot.images.contains {
                isTemporaryMigrationImage($0, sourceIdentifier: sourceIdentifier)
            } || targetSnapshot.images.contains {
                isTemporaryMigrationImage($0, sourceIdentifier: sourceIdentifier)
            }
            guard !cleanupStillPresent else {
                summary.failures.append("migration cleanup was not reflected by the source or target engine")
                return summary
            }
            let liveAfterCleanup = snapshot.containers
                .filter { container in
                    container.status == .running && container.mounts.contains {
                        $0.type == "volume" && !$0.readOnly
                    }
                }
                .map(\.name)
                .sorted()
            guard liveAfterCleanup.isEmpty else {
                summary.failures.append(
                    "migration stopped before writes because named-volume data became live during cleanup: \(liveAfterCleanup.joined(separator: ", "))"
                )
                return summary
            }
        }

        let sourceMarker = source.kind.rawValue
        let targetVolumes = Dictionary(targetSnapshot.volumes.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let targetNetworks = Dictionary(targetSnapshot.networks.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let targetContainers = Dictionary(targetSnapshot.containers.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let customNetworks = snapshot.networks.filter { !defaultNetworkNames.contains($0.name) }
        let sourceVolumeNames = Set(snapshot.volumes.map(\.name))
        let collidingTargetVolumes = targetSnapshot.volumes.filter {
            sourceVolumeNames.contains($0.name)
        }
        let targetVolumeSizes: [String: Int64]?
        if collidingTargetVolumes.isEmpty {
            targetVolumeSizes = [:]
        } else {
            targetVolumeSizes = await namedVolumeSizes(on: target)
        }
        var replaceableTargetContainerIDs: [String] = []
        var replaceableLegacyVolumeNames = Set<String>()
        var replaceableEmptyTargetVolumeNames = Set<String>()
        var replaceableLegacyNetworkNames = Set<String>()
        var precreatedLegacyNetworkNames = Set<String>()
        var temporarySourceImageReferences: [String] = []
        var portableVolumeHelperImages: [(source: String, target: String)] = []
        var migratedTargetImageReferences: [String: String] = [:]
        var migratedTargetImageBySourceID: [String: String] = [:]
        var migratedContainerSnapshotReferences: [String: String] = [:]
        var replaceableContainerSnapshotImageIDs: [String: String] = [:]
        var containerSnapshotRollbackReferences: [String] = []
        var inspectedSpecs: [String: ContainerSpec] = [:]
        var sourceNetworkObjects: [String: [String: Any]] = [:]
        var targetNetworkObjects: [String: [String: Any]] = [:]
        func rememberVolumeHelper(source: String, target: String) {
            guard !portableVolumeHelperImages.contains(where: { $0.source == source && $0.target == target }) else { return }
            portableVolumeHelperImages.append((source: source, target: target))
        }
        for container in snapshot.containers {
            if let spec = await inspectedMigrationSpec(for: container, source: source) {
                inspectedSpecs[container.id] = spec
                summary.failures.append(contentsOf: portabilityFailures(for: spec, containerName: container.name))
            } else if source.supportsRawProxy {
                summary.failures.append(
                    "inspect \(container.name): source Docker API did not return a complete portable container definition"
                )
            }
        }
        // Fetch every network contract before importing the first image. Otherwise a source
        // inspect failure discovered later would strand an image-only partial migration, and a
        // secondary IPAM subnet omitted by Docker's list endpoint could evade overlap checks.
        for network in customNetworks {
            if let object = await inspectedNetworkObject(name: network.name, on: source) {
                sourceNetworkObjects[network.name] = object
            } else if source.supportsRawProxy {
                summary.failures.append(
                    "inspect network \(network.name): source Docker API did not return its driver/IPAM/options contract"
                )
            }
        }
        for network in targetSnapshot.networks {
            if let object = await inspectedNetworkObject(name: network.name, on: target) {
                targetNetworkObjects[network.name] = object
            } else if target.supportsRawProxy {
                summary.failures.append(
                    "inspect target network \(network.name): Dory Docker API did not return its subnet contract"
                )
            }
        }

        if Task.isCancelled {
            summary.failures.append("migration cancelled before any target objects were changed")
            return summary
        }

        // Resolve every collision before importing the first byte. A same-name target image is as
        // destructive as a volume/network collision because `docker load` can move an existing
        // tag to different content. Exact IDs (including short/full forms) and digest-pinned refs
        // are safe to reuse; every ambiguous tag fails closed.
        let migrationImageReferences = imageReferences(snapshot, inspectedSpecs: inspectedSpecs)
        let targetImagesByReference = imageReferenceIndex(targetSnapshot.images)
        var reusableTargetReferences = Set<String>()
        for item in migrationImageReferences {
            let targetReference = portableTargetReference(for: item.reference)
            guard let existing = targetImagesByReference[canonicalImageReference(targetReference)] else { continue }
            let reusableWithoutInspection = targetReference.contains("@sha256:")
                || imageIDsMatch(item.fallbackID, existing.imageID)
                || isFinalMigrationSnapshotImage(existing, sourceIdentifier: sourceIdentifier)
            let reusableByContract = reusableWithoutInspection ? false : await imageContractsMatch(
                    sourceReference: item.reference,
                    targetReference: targetReference,
                    source: source,
                    target: target
                )
            if reusableWithoutInspection || reusableByContract {
                reusableTargetReferences.insert(item.reference)
            } else {
                summary.failures.append(
                    "import \(item.reference): target image tag \(targetReference) already exists with different or unverifiable content"
                )
            }
        }
        for container in snapshot.containers where (initialContainerWritableSizes[container.id] ?? 0) > 0 {
            let finalReference = containerSnapshotReference(
                sourceIdentifier: sourceIdentifier,
                containerID: container.id
            )
            let reservedReferences = [
                (kind: "snapshot", reference: finalReference),
                (kind: "rollback", reference: containerSnapshotRollbackReference(
                    sourceIdentifier: sourceIdentifier,
                    containerID: container.id
                )),
            ]
            for reserved in reservedReferences {
                guard let existing = targetImagesByReference[canonicalImageReference(reserved.reference)] else { continue }
                if isContainerSnapshotImage(
                    existing,
                    sourceIdentifier: sourceIdentifier,
                    containerID: container.id
                ) {
                    if reserved.reference == finalReference {
                        replaceableContainerSnapshotImageIDs[container.id] = existing.imageID
                    }
                } else {
                    summary.failures.append(
                        "snapshot \(container.name): target reserved \(reserved.kind) image reference \(reserved.reference) is not owned by this source container"
                    )
                }
            }
        }
        for volume in snapshot.volumes {
            if normalizedVolumeDriver(volume.driver) != "local" {
                summary.failures.append(
                    "copy volume \(volume.name): external volume driver \(volume.driver) is not portable without the same target plugin"
                )
            } else if !volume.options.isEmpty {
                summary.failures.append(
                    "copy volume \(volume.name): local-driver options may reference host/remote storage and cannot be copied safely"
                )
            }
            if let existing = targetVolumes[volume.name] {
                if !isMigrationOwned(
                    existing.labels,
                    sourceMarker: sourceMarker,
                    sourceIdentifier: sourceIdentifier
                ) {
                    if isLegacyMigrationOwned(existing.labels, sourceMarker: sourceMarker) {
                        let attached = targetSnapshot.containers.contains { container in
                            container.mounts.contains {
                                $0.type == "volume" && $0.source == volume.name
                            }
                        }
                        if !attached, targetVolumeSizes?[volume.name] == 0 {
                            replaceableLegacyVolumeNames.insert(volume.name)
                            summary.warnings.append(
                                "Replacing empty detached volume \(volume.name) left by an earlier Dory migration"
                            )
                        } else {
                            summary.failures.append(
                                "copy volume \(volume.name): an earlier Dory migration volume contains data, is attached, or could not be measured; it was not replaced automatically"
                            )
                        }
                    } else {
                        let attached = targetSnapshot.containers.contains { container in
                            container.mounts.contains {
                                $0.type == "volume" && $0.source == volume.name
                            }
                        }
                        let contractMatches = normalizedVolumeDriver(existing.driver)
                            == normalizedVolumeDriver(volume.driver)
                            && existing.options == volume.options
                        if !attached, contractMatches, targetVolumeSizes?[volume.name] == 0 {
                            replaceableEmptyTargetVolumeNames.insert(volume.name)
                            summary.warnings.append(
                                "Replacing empty detached target volume \(volume.name) while preserving its labels"
                            )
                        } else {
                            summary.failures.append(
                                "copy volume \(volume.name): a non-migration or different-source volume with that name already exists on Dory"
                            )
                        }
                    }
                } else if normalizedVolumeDriver(existing.driver) != normalizedVolumeDriver(volume.driver)
                    || existing.options != volume.options {
                    summary.failures.append(
                        "copy volume \(volume.name): existing migration volume has a different driver/options contract"
                    )
                }
            }
        }
        for network in customNetworks {
            let driver = network.driver.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !driver.isEmpty, driver != "—", driver != "bridge" {
                summary.failures.append(
                    "create network \(network.name): driver \(network.driver) depends on host/cluster state that Dory cannot reproduce safely"
                )
            }
            let sourceNetworkObject = sourceNetworkObjects[network.name]
            let sourceSubnets = networkSubnets(
                in: sourceNetworkObject,
                fallback: network.subnet
            )
            if let existing = targetNetworks[network.name] {
                if !isMigrationOwned(
                    existing.labels,
                    sourceMarker: sourceMarker,
                    sourceIdentifier: sourceIdentifier
                ) {
                    if isLegacyMigrationOwned(existing.labels, sourceMarker: sourceMarker) {
                        let attached = targetSnapshot.containers.contains { container in
                            container.networks.contains(network.name)
                                || container.networkEndpointSettings[network.name] != nil
                        }
                        if !attached {
                            replaceableLegacyNetworkNames.insert(network.name)
                            summary.warnings.append(
                                "Replacing detached network \(network.name) left by an earlier Dory migration"
                            )
                        } else {
                            summary.failures.append(
                                "create network \(network.name): an earlier Dory migration network is still attached to a target container"
                            )
                        }
                    } else {
                        summary.failures.append(
                            "create network \(network.name): a non-migration or different-source network with that name already exists on Dory"
                        )
                    }
                } else if !networkContractsMatch(
                    sourceObject: sourceNetworkObjects[network.name],
                    targetObject: targetNetworkObjects[network.name]
                ) {
                    summary.failures.append(
                        "create network \(network.name): existing migration network has a different or unverifiable driver/IPAM/options contract"
                    )
                }
            }
            if targetNetworks[network.name] == nil {
                for targetNetwork in targetSnapshot.networks where targetNetwork.name != network.name {
                    let targetSubnets = networkSubnets(
                        in: targetNetworkObjects[targetNetwork.name],
                        fallback: targetNetwork.subnet
                    )
                    for sourceSubnet in sourceSubnets {
                        for targetSubnet in targetSubnets where networkSubnetsOverlap(sourceSubnet, targetSubnet) {
                            summary.failures.append(
                                "create network \(network.name): source subnet \(sourceSubnet) overlaps target network \(targetNetwork.name) subnet \(targetSubnet)"
                            )
                        }
                    }
                }
            }
        }
        if recreateContainers {
            for container in snapshot.containers {
                guard let existing = targetContainers[container.name] else { continue }
                if isMigrationOwned(
                    existing.labels,
                    sourceMarker: sourceMarker,
                    sourceIdentifier: sourceIdentifier
                ) {
                    if let priorContainerID = existing.labels["dory.migrated.container-id"],
                       !priorContainerID.isEmpty,
                       priorContainerID != container.id {
                        summary.failures.append(
                            "recreate \(container.name): prior imported target came from a different source container ID"
                        )
                    } else {
                        replaceableTargetContainerIDs.append(existing.id)
                    }
                } else {
                    summary.failures.append(
                        "recreate \(container.name): a non-migration or different-source container with that name already exists on Dory"
                    )
                }
            }
        }
        guard summary.failures.isEmpty else { return summary }

        // Public 0.2 migration artifacts carried only `dory.migrated.from=docker`. Upgrade them
        // only when they are provably disposable: zero-byte detached volumes and detached
        // networks. Recreate the network contract before copying the first image, so a legacy
        // collision cannot turn into another image-only partial import.
        for network in customNetworks where replaceableLegacyNetworkNames.contains(network.name) {
            var removedOriginalNetwork = false
            do {
                try await target.removeNetwork(name: network.name)
                removedOriginalNetwork = true
                try await createNetworkPreservingContract(
                    network,
                    labels: migrationLabels(source: source, existing: network.labels),
                    sourceObject: sourceNetworkObjects[network.name],
                    sourceSupportsRawProxy: source.supportsRawProxy,
                    on: target
                )
                if target.supportsRawProxy {
                    let createdObject = await inspectedNetworkObject(name: network.name, on: target)
                    guard networkContractsMatch(
                        sourceObject: sourceNetworkObjects[network.name],
                        targetObject: createdObject
                    ) else {
                        try? await target.removeNetwork(name: network.name)
                        throw RuntimeFeatureError.unsupported(
                            "replacement network contract did not match the source"
                        )
                    }
                }
                precreatedLegacyNetworkNames.insert(network.name)
            } catch {
                var failure = "replace legacy network \(network.name): \(error)"
                // A detached legacy migration network is safe to replace only transactionally.
                // If the new source contract cannot be created or verified, put the exact prior
                // target contract and labels back instead of turning a failed import into metadata
                // loss on Dory.
                if removedOriginalNetwork,
                   let original = targetNetworks[network.name],
                   let originalObject = targetNetworkObjects[network.name] {
                    try? await target.removeNetwork(name: network.name)
                    do {
                        try await createNetworkPreservingContract(
                            original,
                            labels: original.labels,
                            sourceObject: originalObject,
                            sourceSupportsRawProxy: target.supportsRawProxy,
                            on: target
                        )
                        let restoredObject = await inspectedNetworkObject(name: network.name, on: target)
                        guard networkContractsMatch(
                            sourceObject: originalObject,
                            targetObject: restoredObject
                        ) else {
                            throw RuntimeFeatureError.unsupported("restored network contract did not match the original")
                        }
                        failure += "; original detached target network was restored"
                    } catch {
                        failure += "; restore of original detached target network failed: \(error)"
                    }
                }
                summary.failures.append(failure)
            }
        }
        guard summary.failures.isEmpty else { return summary }

        for imageReference in migrationImageReferences {
            if Task.isCancelled {
                summary.failures.append("migration cancelled; source objects were preserved")
                summary.failures.append(contentsOf: await cleanupTemporaryImageReferences(temporarySourceImageReferences, from: source))
                return summary
            }
            let reference = imageReference.reference
            let targetReference = portableTargetReference(for: reference)
            if reusableTargetReferences.contains(reference) {
                progress?("Using existing verified image \(targetReference)")
                summary.imagesImported.append(targetReference)
                migratedTargetImageReferences[reference] = targetReference
                if let key = normalizedImageID(imageReference.fallbackID) {
                    migratedTargetImageBySourceID[key] = targetReference
                }
                rememberVolumeHelper(source: reference, target: targetReference)
                continue
            }
            if !targetReference.contains("@"),
               let key = normalizedImageID(imageReference.fallbackID),
               let existingTargetReference = migratedTargetImageBySourceID[key] {
                let split = DockerRegistry.splitImageRef(targetReference)
                do {
                    try await target.tagImage(
                        source: existingTargetReference,
                        repo: split.repo,
                        tag: split.tag
                    )
                    summary.imagesImported.append(targetReference)
                    migratedTargetImageReferences[reference] = targetReference
                    migratedTargetImageBySourceID[key] = targetReference
                    rememberVolumeHelper(source: reference, target: targetReference)
                    continue
                } catch {
                    // Fall through to the normal archive/pull path. A target that cannot resolve
                    // the earlier imported tag may still accept this source reference directly.
                }
            }
            var archiveError: Error?
            if source.supportsImageArchiveTransfer && target.supportsImageArchiveTransfer {
                progress?("Copying \(reference)")
                do {
                    let targetImageIDsBefore = Set(
                        (try? await target.snapshot().images.map(\.imageID)) ?? []
                    )
                    if try await copyImageArchive(reference: reference, from: source, to: target) {
                        if let fallbackID = imageReference.fallbackID,
                           !targetReference.contains("@") {
                            try await bindLoadedImage(
                                reference: targetReference,
                                directSource: fallbackID,
                                target: target,
                                excluding: targetImageIDsBefore,
                                failureContext: "could not bind loaded image archive to \(targetReference)"
                            )
                        }
                        summary.imagesImported.append(targetReference)
                        migratedTargetImageReferences[reference] = targetReference
                        if let key = normalizedImageID(imageReference.fallbackID) {
                            migratedTargetImageBySourceID[key] = targetReference
                        }
                        rememberVolumeHelper(source: reference, target: targetReference)
                        continue
                    }
                } catch {
                    archiveError = error
                }
                if Task.isCancelled {
                    appendCancellation(to: &summary)
                    summary.failures.append(contentsOf: await cleanupTemporaryImageReferences(temporarySourceImageReferences, from: source))
                    return summary
                }
                if let fallbackID = imageReference.fallbackID,
                   fallbackID != reference,
                   !reference.contains("@") {
                    do {
                        let targetImageIDsBefore = Set(
                            (try? await target.snapshot().images.map(\.imageID)) ?? []
                        )
                        _ = try await copyImageArchive(reference: fallbackID, from: source, to: target)
                        try await bindLoadedImage(
                            reference: targetReference,
                            directSource: fallbackID,
                            target: target,
                            excluding: targetImageIDsBefore,
                            failureContext: "could not bind loaded content-ID fallback to \(targetReference)"
                        )
                        summary.imagesImported.append(targetReference)
                        migratedTargetImageReferences[reference] = targetReference
                        if let key = normalizedImageID(imageReference.fallbackID) {
                            migratedTargetImageBySourceID[key] = targetReference
                        }
                        // The original name can be absent on the source even though its immutable
                        // content ID still exports. Keep the two helper references independent so
                        // named-volume transfer does not regress after a successful image import.
                        rememberVolumeHelper(source: fallbackID, target: targetReference)
                        continue
                    } catch {
                        let primary = archiveError.map { "\($0); " } ?? ""
                        archiveError = RuntimeFeatureError.unsupported(
                            "\(primary)content-ID fallback \(fallbackID): \(error)"
                        )
                    }
                    if Task.isCancelled {
                        appendCancellation(to: &summary)
                        summary.failures.append(contentsOf: await cleanupTemporaryImageReferences(temporarySourceImageReferences, from: source))
                        return summary
                    }
                }
                if let containerID = imageReference.sourceContainerID,
                   !targetReference.contains("@") {
                    let temporaryReference = temporarySnapshotReference()
                    let temporarySplit = DockerRegistry.splitImageRef(temporaryReference)
                    do {
                        let committedID = try await source.commit(
                            containerID: containerID,
                            repo: temporarySplit.repo,
                            tag: temporarySplit.tag,
                            labels: [
                                "dory.migration.temporary": "true",
                                "dory.migrated.source": sourceIdentifier,
                            ],
                            pause: false
                        )
                        let targetImageIDsBefore = Set(
                            (try? await target.snapshot().images.map(\.imageID)) ?? []
                        )
                        _ = try await copyImageArchive(reference: temporaryReference, from: source, to: target)
                        // Docker-compatible loaders do not all preserve RepoTags for archives made
                        // from a freshly committed running container. Prefer the source content ID;
                        // if the target normalizes it, bind the one newly loaded dangling image.
                        try await bindLoadedImage(
                            reference: targetReference,
                            directSource: committedID,
                            loadedReference: temporaryReference,
                            target: target,
                            excluding: targetImageIDsBefore,
                            failureContext: "could not bind loaded container snapshot to \(targetReference)"
                        )
                        do {
                            try await removeTemporaryImageReferenceStrict(temporaryReference, from: target)
                        } catch {
                            summary.failures.append(
                                "cleanup temporary target snapshot \(temporaryReference): \(error)"
                            )
                        }
                        // Keep only Dory's unique source tag until volume helpers finish. Never
                        // move or delete the user's original source tag, even when its archive
                        // failed for a transient reason rather than because it was absent.
                        temporarySourceImageReferences.append(temporaryReference)
                        summary.imagesImported.append(targetReference)
                        migratedTargetImageReferences[reference] = targetReference
                        if let key = normalizedImageID(imageReference.fallbackID) {
                            migratedTargetImageBySourceID[key] = targetReference
                        }
                        rememberVolumeHelper(source: temporaryReference, target: targetReference)
                        continue
                    } catch {
                        do {
                            try await removeTemporaryImageReferenceStrict(temporaryReference, from: source)
                        } catch {
                            summary.failures.append(
                                "cleanup failed source snapshot \(temporaryReference): \(error)"
                            )
                        }
                        let prior = archiveError.map { "\($0); " } ?? ""
                        archiveError = RuntimeFeatureError.unsupported(
                            "\(prior)container snapshot fallback \(containerID): \(error)"
                        )
                    }
                    if Task.isCancelled {
                        appendCancellation(to: &summary)
                        summary.failures.append(contentsOf: await cleanupTemporaryImageReferences(temporarySourceImageReferences, from: source))
                        return summary
                    }
                }
            }
            progress?("Pulling \(reference)")
            do {
                try await target.pull(image: targetReference)
                summary.imagesImported.append(targetReference)
                migratedTargetImageReferences[reference] = targetReference
                if let key = normalizedImageID(imageReference.fallbackID) {
                    migratedTargetImageBySourceID[key] = targetReference
                }
                // A registry pull proves only the target reference. Keep it as a lower-priority
                // candidate: helper creation will verify that the source still resolves the tag,
                // and can fall through to a content-ID or snapshot candidate if it does not.
                rememberVolumeHelper(source: reference, target: targetReference)
            }
            catch {
                if let archiveError {
                    summary.failures.append("import \(reference) (archive: \(archiveError); pull: \(error))")
                } else {
                    summary.failures.append("pull \(reference): \(error)")
                }
            }
            if Task.isCancelled {
                appendCancellation(to: &summary)
                summary.failures.append(contentsOf: await cleanupTemporaryImageReferences(temporarySourceImageReferences, from: source))
                return summary
            }
        }

        guard summary.failures.isEmpty else {
            summary.failures.append(contentsOf: await cleanupTemporaryImageReferences(temporarySourceImageReferences, from: source))
            return summary
        }

        // Preserve files written into ordinary container layers, not only named volumes and image
        // definitions. Running changed containers were blocked above; stopped/paused snapshots use
        // pause=false so Dory never changes source execution state implicitly.
        for container in snapshot.containers where (initialContainerWritableSizes[container.id] ?? 0) > 0 {
            if Task.isCancelled {
                appendCancellation(to: &summary)
                summary.failures.append(contentsOf: await cleanupTemporaryImageReferences(temporarySourceImageReferences, from: source))
                return summary
            }
            progress?("Snapshotting container filesystem \(container.name)")
            do {
                let copied = try await copyContainerWritableLayerSnapshot(
                    container: container,
                    sourceIdentifier: sourceIdentifier,
                    existingTargetImageID: replaceableContainerSnapshotImageIDs[container.id],
                    from: source,
                    to: target
                )
                migratedContainerSnapshotReferences[container.id] = copied.reference
                if let rollbackReference = copied.rollbackReference {
                    containerSnapshotRollbackReferences.append(rollbackReference)
                }
            } catch {
                if Task.isCancelled {
                    appendCancellation(to: &summary)
                } else {
                    summary.failures.append("snapshot container filesystem \(container.name): \(error)")
                }
                break
            }
        }
        guard summary.failures.isEmpty else {
            summary.failures.append(contentsOf: await cleanupTemporaryImageReferences(temporarySourceImageReferences, from: source))
            return summary
        }

        for network in customNetworks {
            if Task.isCancelled {
                summary.failures.append("migration cancelled; source objects were preserved")
                summary.failures.append(contentsOf: await cleanupTemporaryImageReferences(temporarySourceImageReferences, from: source))
                return summary
            }
            progress?("Creating network \(network.name)")
            if precreatedLegacyNetworkNames.contains(network.name) {
                summary.networksCreated.append(network.name)
                continue
            }
            if let existing = targetNetworks[network.name] {
                if isMigrationOwned(
                    existing.labels,
                    sourceMarker: sourceMarker,
                    sourceIdentifier: sourceIdentifier
                ) {
                    summary.networksCreated.append(network.name)
                } else {
                    summary.failures.append("create network \(network.name): existing migration network ownership changed after preflight")
                }
                continue
            }
            do {
                try await createNetworkPreservingContract(
                    network,
                    labels: migrationLabels(source: source, existing: network.labels),
                    sourceObject: sourceNetworkObjects[network.name],
                    sourceSupportsRawProxy: source.supportsRawProxy,
                    on: target
                )
                if target.supportsRawProxy {
                    let createdObject = await inspectedNetworkObject(name: network.name, on: target)
                    guard networkContractsMatch(
                        sourceObject: sourceNetworkObjects[network.name],
                        targetObject: createdObject
                    ) else {
                        do { try await target.removeNetwork(name: network.name) }
                        catch {
                            throw RuntimeFeatureError.unsupported(
                                "created network contract did not match the source and cleanup failed: \(error)"
                            )
                        }
                        throw RuntimeFeatureError.unsupported(
                            "created network contract did not match the source; the partial network was removed"
                        )
                    }
                }
                summary.networksCreated.append(network.name)
            } catch {
                summary.failures.append("create network \(network.name): \(error)")
            }
        }
        guard summary.failures.isEmpty else {
            summary.failures.append(contentsOf: await cleanupTemporaryImageReferences(temporarySourceImageReferences, from: source))
            return summary
        }

        // A prior same-source attempt may have reached container creation before it was cancelled
        // or failed. Remove only those exactly owned copies before replacing their named volumes;
        // the source containers remain untouched and are still the migration source of truth.
        for containerID in replaceableTargetContainerIDs {
            do {
                try await target.remove(containerID: containerID)
            } catch {
                summary.failures.append("prepare container retry \(containerID): \(error)")
            }
        }
        for reference in containerSnapshotRollbackReferences {
            do {
                try await removeTemporaryImageReferenceStrict(reference, from: target)
            } catch {
                summary.failures.append("cleanup prior container snapshot \(reference): \(error)")
            }
        }
        guard summary.failures.isEmpty else {
            summary.failures.append(contentsOf: await cleanupTemporaryImageReferences(temporarySourceImageReferences, from: source))
            return summary
        }

        for volume in snapshot.volumes {
            if Task.isCancelled {
                summary.failures.append("migration cancelled; source objects were preserved")
                summary.failures.append(contentsOf: await cleanupTemporaryImageReferences(temporarySourceImageReferences, from: source))
                return summary
            }
            progress?("Copying volume \(volume.name)")
            if source.supportsRawProxy {
                switch await runningContainerUsesVolume(volume.name, on: source) {
                case true:
                    summary.failures.append(
                        "copy volume \(volume.name): a source container started using this volume after preflight; stop or pause it and retry for a consistent copy"
                    )
                    continue
                case nil:
                    summary.failures.append(
                        "copy volume \(volume.name): source usage could not be rechecked safely before copying"
                    )
                    continue
                case false:
                    break
                }
            }
            let existingTarget = targetVolumes[volume.name]
            guard !portableVolumeHelperImages.isEmpty else {
                summary.failures.append(
                    "copy volume \(volume.name): no image was successfully copied to Dory for the temporary volume helper; target volume was not created"
                )
                continue
            }
            var createdTargetVolume = false
            var removedRestorableTargetVolume = false
            do {
                // A prior interrupted archive extraction may have left files that no longer exist
                // on the source. Docker's archive PUT overlays data and does not delete those stale
                // paths. Exact-source retry volumes, proven empty legacy partials, and proven
                // empty/detached/contract-compatible target volumes are the only replaceable
                // cases. Recreate them before extraction to guarantee an exact source tree.
                if let existingTarget {
                    let exactlyOwned = isMigrationOwned(
                        existingTarget.labels,
                        sourceMarker: sourceMarker,
                        sourceIdentifier: sourceIdentifier
                    )
                    if !exactlyOwned {
                        if isLegacyMigrationOwned(existingTarget.labels, sourceMarker: sourceMarker) {
                            guard replaceableLegacyVolumeNames.contains(volume.name) else {
                                throw RuntimeFeatureError.unsupported(
                                    "legacy migration volume was not authorized for safe replacement"
                                )
                            }
                            removedRestorableTargetVolume = true
                        } else {
                            guard replaceableEmptyTargetVolumeNames.contains(volume.name) else {
                                throw RuntimeFeatureError.unsupported(
                                    "unowned target volume was not authorized for safe empty-volume replacement"
                                )
                            }
                            removedRestorableTargetVolume = true
                        }
                    }
                    try await target.removeVolume(name: volume.name)
                }
                var preservedLabels = volume.labels
                if let existingTarget,
                   replaceableEmptyTargetVolumeNames.contains(volume.name) {
                    preservedLabels = existingTarget.labels.merging(volume.labels) { _, sourceValue in
                        sourceValue
                    }
                }
                try await target.createVolume(
                    name: volume.name,
                    driver: volume.driver.isEmpty ? nil : volume.driver,
                    labels: migrationLabels(source: source, existing: preservedLabels),
                    driverOptions: volume.options
                )
                createdTargetVolume = true
                let verifiedHelper = try await copyVolumeData(
                    name: volume.name,
                    helperImages: portableVolumeHelperImages,
                    sourceIdentifier: sourceIdentifier,
                    from: source,
                    to: target
                )
                if source.supportsRawProxy {
                    switch await runningContainerUsesVolume(volume.name, on: source) {
                    case true:
                        throw RuntimeFeatureError.unsupported(
                            "a source container began using the volume during transfer"
                        )
                    case nil:
                        throw RuntimeFeatureError.unsupported(
                            "source usage could not be verified after transfer"
                        )
                    case false:
                        break
                    }
                }
                portableVolumeHelperImages.removeAll {
                    $0.source == verifiedHelper.source && $0.target == verifiedHelper.target
                }
                portableVolumeHelperImages.insert(verifiedHelper, at: 0)
                summary.volumesCopied.append(volume.name)
            } catch {
                var failure = "copy volume \(volume.name): \(error)"
                // Do not leave a newly created or partially extracted volume behind. If a helper
                // cleanup problem still holds the volume open, report that second failure rather
                // than pretending the retry is safe.
                var partialCleanupSucceeded = true
                if createdTargetVolume {
                    do { try await target.removeVolume(name: volume.name) }
                    catch {
                        partialCleanupSucceeded = false
                        failure += "; cleanup of partial volume failed: \(error)"
                    }
                }
                // Adoption is allowed only for a measured-zero, detached target volume. If the
                // transfer fails after removing it, restore that exact empty object contract so a
                // failed import cannot erase user labels/options even though there were no bytes.
                if removedRestorableTargetVolume, partialCleanupSucceeded, let existingTarget {
                    do {
                        try await target.createVolume(
                            name: existingTarget.name,
                            driver: existingTarget.driver.isEmpty ? nil : existingTarget.driver,
                            labels: existingTarget.labels,
                            driverOptions: existingTarget.options
                        )
                        failure += "; original empty target volume was restored"
                    } catch {
                        failure += "; restore of original empty target volume failed: \(error)"
                    }
                }
                summary.failures.append(failure)
            }
        }

        // Never create containers against missing or partially copied storage. Images and exact
        // networks are resumable; target volumes created by a failed copy were removed above.
        guard summary.failures.isEmpty else {
            summary.failures.append(contentsOf: await cleanupTemporaryImageReferences(temporarySourceImageReferences, from: source))
            return summary
        }

        if Task.isCancelled {
            appendCancellation(to: &summary)
            summary.failures.append(contentsOf: await cleanupTemporaryImageReferences(temporarySourceImageReferences, from: source))
            return summary
        }
        guard recreateContainers else {
            summary.failures.append(contentsOf: await cleanupTemporaryImageReferences(temporarySourceImageReferences, from: source))
            return summary
        }
        guard var refreshedSource = try? await source.migrationSnapshot() else {
            if Task.isCancelled {
                appendCancellation(to: &summary)
            } else {
                summary.failures.append("source inventory could not be verified before container recreation")
            }
            summary.failures.append(contentsOf: await cleanupTemporaryImageReferences(temporarySourceImageReferences, from: source))
            return summary
        }
        refreshedSource.containers.removeAll {
            isTemporaryMigrationHelper($0.labels, sourceIdentifier: sourceIdentifier)
        }
        refreshedSource.images.removeAll {
            isTemporaryMigrationImage($0, sourceIdentifier: sourceIdentifier)
        }
        let initialContainerStates = Dictionary(
            uniqueKeysWithValues: snapshot.containers.map { ($0.id, $0.status) }
        )
        let refreshedContainerStates = Dictionary(
            uniqueKeysWithValues: refreshedSource.containers.map { ($0.id, $0.status) }
        )
        guard let refreshedContainerWritableSizes = try? await source.migrationContainerWritableSizes() else {
            summary.failures.append("source writable-layer sizes could not be verified before container recreation")
            summary.failures.append(contentsOf: await cleanupTemporaryImageReferences(temporarySourceImageReferences, from: source))
            return summary
        }
        let initialUserWritableSizes = Dictionary(uniqueKeysWithValues: snapshot.containers.map {
            ($0.id, initialContainerWritableSizes[$0.id] ?? -1)
        })
        let refreshedUserWritableSizes = Dictionary(uniqueKeysWithValues: refreshedSource.containers.map {
            ($0.id, refreshedContainerWritableSizes[$0.id] ?? -1)
        })
        let initialVolumeContracts = Set(snapshot.volumes.map {
            "\($0.name)\u{0}\(normalizedVolumeDriver($0.driver))\u{0}\($0.options.sorted { $0.key < $1.key })"
        })
        let refreshedVolumeContracts = Set(refreshedSource.volumes.map {
            "\($0.name)\u{0}\(normalizedVolumeDriver($0.driver))\u{0}\($0.options.sorted { $0.key < $1.key })"
        })
        var sourceNetworkContractsStable = true
        if source.supportsRawProxy {
            for network in customNetworks {
                let refreshedObject = await inspectedNetworkObject(name: network.name, on: source)
                if !networkContractsMatch(
                    sourceObject: sourceNetworkObjects[network.name],
                    targetObject: refreshedObject
                ) || !networkContractsMatch(
                    sourceObject: refreshedObject,
                    targetObject: sourceNetworkObjects[network.name]
                ) {
                    sourceNetworkContractsStable = false
                    break
                }
            }
        }
        guard initialContainerStates == refreshedContainerStates,
              initialUserWritableSizes == refreshedUserWritableSizes,
              initialVolumeContracts == refreshedVolumeContracts,
              Set(snapshot.networks.map(\.name)) == Set(refreshedSource.networks.map(\.name)),
              sourceNetworkContractsStable else {
            summary.failures.append(
                "source container state/filesystems, volumes, or networks changed during import; target containers were not created"
            )
            summary.failures.append(contentsOf: await cleanupTemporaryImageReferences(temporarySourceImageReferences, from: source))
            return summary
        }
        var createdContainers: [(container: Container, id: String, spec: ContainerSpec)] = []
        for container in snapshot.containers {
            if Task.isCancelled {
                appendCancellation(to: &summary)
                break
            }
            progress?("Recreating \(container.name)")
            let env = (try? await source.env(containerID: container.id)) ?? []
            var spec = inspectedSpecs[container.id]
                ?? migrationSpec(for: container, env: env, source: source)
            spec.labels["dory.migrated.container-id"] = container.id
            if let snapshotImage = migratedContainerSnapshotReferences[container.id] {
                spec.image = snapshotImage
            } else if let targetImage = migratedTargetImageReferences[spec.image] {
                spec.image = targetImage
            }
            do {
                let id = try await target.create(spec)
                createdContainers.append((container: container, id: id, spec: spec))
            } catch {
                summary.failures.append("recreate \(container.name): \(error)")
                break
            }
        }

        if summary.failures.isEmpty {
            for created in createdContainers {
                if Task.isCancelled {
                    appendCancellation(to: &summary)
                    break
                }
                do {
                    switch created.container.status {
                case .running:
                    if hasFixedHostPort(created.spec) {
                        summary.containersAwaitingSourcePorts.append(created.container.name)
                        summary.warnings.append(
                            "\(created.container.name) was imported stopped because its host port is still owned by the source engine; stop the source engine, then start it in Dory"
                        )
                    } else {
                        try await target.start(containerID: created.id)
                    }
                case .paused:
                    if hasFixedHostPort(created.spec) {
                        summary.containersAwaitingSourcePorts.append(created.container.name)
                        summary.warnings.append(
                            "\(created.container.name) was imported stopped because its host port is still owned by the source engine; stop the source engine, then start and pause it in Dory"
                        )
                    } else {
                        try await target.start(containerID: created.id)
                        try await target.pause(containerID: created.id)
                    }
                case .stopped:
                    break
                    }
                } catch {
                    summary.failures.append("restore state for \(created.container.name): \(error)")
                    break
                }
            }
        }

        if summary.failures.isEmpty {
            summary.containersMigrated = createdContainers.map(\.container.name)
        } else {
            summary.containersAwaitingSourcePorts.removeAll()
            summary.warnings.removeAll { $0.contains("host port is still owned") }
            for created in createdContainers.reversed() {
                do { try await target.remove(containerID: created.id) }
                catch {
                    summary.failures.append(
                        "cleanup of partial container \(created.container.name) (\(created.id)) failed: \(error)"
                    )
                }
            }
        }
        summary.failures.append(contentsOf: await cleanupTemporaryImageReferences(
            temporarySourceImageReferences,
            from: source
        ))
        return summary
    }

    private static func appendCancellation(to summary: inout MigrationSummary) {
        guard !summary.failures.contains(where: { $0.contains("migration cancelled") }) else { return }
        summary.failures.append("migration cancelled; source objects were preserved")
    }

    private static func hasFixedHostPort(_ spec: ContainerSpec) -> Bool {
        spec.ports.contains { DockerCreateBody.parsePort($0).hostPort?.isEmpty == false }
    }

    private static func portabilityFailures(
        for spec: ContainerSpec,
        containerName: String
    ) -> [String] {
        var failures: [String] = []
        let namespaceModes = [spec.networkMode, spec.ipcMode, spec.pidMode]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        if namespaceModes.contains(where: { $0.hasPrefix("container:") }) {
            failures.append(
                "inspect \(containerName): cross-container network/IPC/PID namespace references require dependency-aware recreation"
            )
        }
        let endpointLinks = spec.networkEndpointSettings.values.flatMap { $0.Links ?? [] }
        if !spec.volumesFrom.isEmpty || !spec.links.isEmpty || !endpointLinks.isEmpty {
            failures.append(
                "inspect \(containerName): legacy volumes-from/links dependencies require dependency-aware recreation"
            )
        }
        if let containerIDFile = spec.containerIDFile, !containerIDFile.isEmpty {
            failures.append(
                "inspect \(containerName): ContainerIDFile \(containerIDFile) is source-daemon state and cannot be overwritten safely"
            )
        }
        if !(spec.resources.devices ?? []).isEmpty
            || !(spec.resources.deviceRequests ?? []).isEmpty
            || !(spec.resources.deviceCgroupRules ?? []).isEmpty {
            failures.append(
                "inspect \(containerName): host device mappings are not portable into Dory's Linux VM"
            )
        }
        if let runtime = spec.runtimeName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !runtime.isEmpty,
           !["runc", "crun"].contains(runtime) {
            failures.append(
                "inspect \(containerName): container runtime \(runtime) is not bundled by Dory"
            )
        }

        let fileManager = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.resolvingSymlinksInPath().path
        for mount in spec.mounts where mount.type.lowercased() == "bind" {
            guard let source = mount.source, !source.isEmpty else {
                failures.append("inspect \(containerName): bind mount at \(mount.target) has no source path")
                continue
            }
            failures.append(contentsOf: bindSourceFailures(
                source: source,
                target: mount.target,
                containerName: containerName,
                fileManager: fileManager,
                home: home
            ))
        }
        for bind in spec.volumes where DockerCreateBody.isLegacyBind(bind) {
            guard let source = legacyBindSource(bind) else {
                failures.append("inspect \(containerName): legacy bind declaration is invalid: \(bind)")
                continue
            }
            failures.append(contentsOf: bindSourceFailures(
                source: source,
                target: legacyBindTarget(bind) ?? "?",
                containerName: containerName,
                fileManager: fileManager,
                home: home
            ))
        }
        return failures
    }

    private static func bindSourceFailures(
        source: String,
        target: String,
        containerName: String,
        fileManager: FileManager,
        home: String
    ) -> [String] {
        let sourceURL = URL(fileURLWithPath: source).standardizedFileURL
        let resolved = sourceURL.resolvingSymlinksInPath().path
        let isShared = resolved == home || resolved.hasPrefix(home + "/")
        if !isShared {
            return ["inspect \(containerName): bind source \(source) for \(target) is outside Dory's shared home directory \(home)"]
        }
        if !fileManager.fileExists(atPath: sourceURL.path) {
            return ["inspect \(containerName): bind source \(source) for \(target) does not exist on this Mac"]
        }
        return []
    }

    private static func legacyBindTarget(_ bind: String) -> String? {
        let pieces = bind.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard pieces.count >= 2 else { return nil }
        let modes: Set<String> = [
            "ro", "rw", "z", "Z", "cached", "delegated", "consistent", "nocopy",
            "private", "rprivate", "shared", "rshared", "slave", "rslave", "bind", "volume",
        ]
        let options = Set(pieces.last?.split(separator: ",").map(String.init) ?? [])
        return pieces.count >= 3 && !options.isDisjoint(with: modes)
            ? pieces[pieces.count - 2]
            : pieces.last
    }

    private static func legacyBindSource(_ bind: String) -> String? {
        let pieces = bind.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard pieces.count >= 2 else { return nil }
        let modes: Set<String> = [
            "ro", "rw", "z", "Z", "cached", "delegated", "consistent", "nocopy",
            "private", "rprivate", "shared", "rshared", "slave", "rslave", "bind", "volume",
        ]
        let options = Set(pieces.last?.split(separator: ",").map(String.init) ?? [])
        let targetIndex = pieces.count >= 3 && !options.isDisjoint(with: modes)
            ? pieces.count - 2
            : pieces.count - 1
        guard targetIndex > 0 else { return nil }
        return pieces[..<targetIndex].joined(separator: ":")
    }

    /// Include references used by containers even when Docker's image-list row exposes a
    /// different first tag (or no RepoTags at all). This prevents a successfully copied image set
    /// from still leaving recreated containers with "No such image".
    private struct MigrationImageReference {
        var reference: String
        var fallbackID: String?
        var sourceContainerID: String?
    }

    private static func imageReferences(
        _ snapshot: RuntimeSnapshot,
        inspectedSpecs: [String: ContainerSpec]
    ) -> [MigrationImageReference] {
        var indices: [String: Int] = [:]
        var references: [MigrationImageReference] = []
        func append(_ reference: String, fallbackID: String?, sourceContainerID: String? = nil) {
            if let index = indices[reference] {
                if let fallbackID, references[index].fallbackID?.hasPrefix("sha256:") != true {
                    references[index].fallbackID = fallbackID
                }
                if references[index].sourceContainerID == nil {
                    references[index].sourceContainerID = sourceContainerID
                }
                return
            }
            indices[reference] = references.count
            references.append(MigrationImageReference(
                reference: reference,
                fallbackID: fallbackID,
                sourceContainerID: sourceContainerID
            ))
        }
        for image in snapshot.images where image.repository != "<none>" && !image.repository.isEmpty {
            let reference = image.tag == "<none>" || image.tag.isEmpty
                ? image.repository
                : "\(image.repository):\(image.tag)"
            append(reference, fallbackID: image.imageID)
            for additional in image.additionalReferences { append(additional, fallbackID: image.imageID) }
        }
        for container in snapshot.containers {
            if let inspectedImage = inspectedSpecs[container.id]?.image.trimmingCharacters(in: .whitespacesAndNewlines),
               !inspectedImage.isEmpty,
               inspectedImage != "<none>" {
                append(inspectedImage, fallbackID: container.sourceImageID, sourceContainerID: container.id)
            }
            let reference = container.image.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reference.isEmpty, reference != "<none>" else { continue }
            append(reference, fallbackID: container.sourceImageID, sourceContainerID: container.id)
        }
        // Docker may expose an untagged container's image twice: its original create-time name in
        // inspect and its immutable sha256 ID in the list row. Once the named reference can fall
        // back to that ID, importing the raw ID again is redundant and would pick a non-portable
        // helper image. Keep a bare content ID only when it is the sole usable reference.
        let contentFallbacks = Set(references.compactMap { item -> String? in
            guard !item.reference.hasPrefix("sha256:") else { return nil }
            return item.fallbackID?.hasPrefix("sha256:") == true ? item.fallbackID : nil
        })
        return references.filter { !($0.reference.hasPrefix("sha256:") && contentFallbacks.contains($0.reference)) }
    }

    private static func imageReferenceIndex(_ images: [DockerImage]) -> [String: DockerImage] {
        var result: [String: DockerImage] = [:]
        for image in images {
            if image.repository != "<none>", !image.repository.isEmpty {
                let primary = image.tag == "<none>" || image.tag.isEmpty
                    ? image.repository
                    : "\(image.repository):\(image.tag)"
                let key = canonicalImageReference(primary)
                result[key] = result[key] ?? image
            }
            for reference in image.additionalReferences {
                let key = canonicalImageReference(reference)
                result[key] = result[key] ?? image
            }
        }
        return result
    }

    private static func imageContractsMatch(
        sourceReference: String,
        targetReference: String,
        source: any ContainerRuntime,
        target: (any ContainerRuntime)?
    ) async -> Bool {
        guard source.supportsRawProxy, let target, target.supportsRawProxy,
              let sourceObject = await inspectedImageObject(reference: sourceReference, on: source),
              let targetObject = await inspectedImageObject(reference: targetReference, on: target),
              let sourceContract = portableImageContract(sourceObject),
              let targetContract = portableImageContract(targetObject) else { return false }
        return jsonContains(expected: sourceContract, actual: targetContract)
            && jsonContains(expected: targetContract, actual: sourceContract)
    }

    private static func inspectedImageObject(
        reference: String,
        on runtime: any ContainerRuntime
    ) async -> [String: Any]? {
        guard let response = await runtime.proxyRequest(
            method: "GET",
            path: "/images/\(DockerImageOps.pathComponent(reference))/json",
            headers: [(name: "Accept", value: "application/json")],
            body: Data()
        ), response.isSuccess else { return nil }
        return try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
    }

    private static func portableImageContract(_ object: [String: Any]) -> [String: Any]? {
        guard let config = object["Config"] as? [String: Any],
              let rootFS = object["RootFS"] as? [String: Any] else { return nil }
        var contract: [String: Any] = ["Config": config, "RootFS": rootFS]
        for key in ["Architecture", "Os", "Variant"] {
            if let value = object[key] { contract[key] = value }
        }
        return JSONSerialization.isValidJSONObject(contract) ? contract : nil
    }

    /// Docker Hub's short, fully-qualified, and historical host aliases identify the same tag.
    /// Canonicalizing only for collision lookup prevents a short source tag from bypassing a
    /// pre-existing fully-qualified target tag; the user's original spelling is still preserved.
    private static func canonicalImageReference(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("sha256:") { return trimmed }

        let suffix: String
        let repository: String
        if let at = trimmed.firstIndex(of: "@") {
            repository = String(trimmed[..<at])
            suffix = String(trimmed[at...])
        } else if let colon = trimmed.lastIndex(of: ":"),
                  trimmed.lastIndex(of: "/").map({ colon > $0 }) ?? true {
            repository = String(trimmed[..<colon])
            suffix = String(trimmed[colon...])
        } else {
            repository = trimmed
            suffix = ":latest"
        }

        var components = repository.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return trimmed }
        let first = components[0]
        let hasRegistry = first.contains(".") || first.contains(":") || first == "localhost"
        if hasRegistry {
            if ["index.docker.io", "registry-1.docker.io"].contains(first) {
                components[0] = "docker.io"
            }
        } else {
            components.insert("docker.io", at: 0)
        }
        if components.first == "docker.io", components.count == 2 {
            components.insert("library", at: 1)
        }
        return components.joined(separator: "/") + suffix
    }

    private static func imageIDsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        let left = lhs.lowercased().replacingOccurrences(of: "sha256:", with: "")
        let right = rhs.lowercased().replacingOccurrences(of: "sha256:", with: "")
        if left == right, !left.isEmpty { return true }
        guard left.count >= 12, right.count >= 12 else { return false }
        return left.hasPrefix(right) || right.hasPrefix(left)
    }

    private static func normalizedImageID(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.lowercased().replacingOccurrences(of: "sha256:", with: "")
        return normalized.isEmpty ? nil : normalized
    }

    private static func temporarySnapshotReference() -> String {
        "dory-migration-temporary/snapshot:\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
    }

    static func containerSnapshotReference(
        sourceIdentifier: String,
        containerID: String
    ) -> String {
        let digest = SHA256.hash(data: Data("\(sourceIdentifier)\u{0}\(containerID)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "dory-migration/container-snapshot:\(digest)"
    }

    private static func containerSnapshotRollbackReference(
        sourceIdentifier: String,
        containerID: String
    ) -> String {
        containerSnapshotReference(sourceIdentifier: sourceIdentifier, containerID: containerID)
            .replacingOccurrences(
                of: "dory-migration/container-snapshot:",
                with: "dory-migration/container-rollback:"
            )
    }

    private static func isContainerSnapshotImage(
        _ image: DockerImage,
        sourceIdentifier: String,
        containerID: String
    ) -> Bool {
        image.labels["dory.migration.container-snapshot"] == "true"
            && image.labels["dory.migrated.source"] == sourceIdentifier
            && image.labels["dory.migration.container-id"] == containerID
    }

    private static func copyContainerWritableLayerSnapshot(
        container: Container,
        sourceIdentifier: String,
        existingTargetImageID: String?,
        from source: any ContainerRuntime,
        to target: any ContainerRuntime
    ) async throws -> (reference: String, rollbackReference: String?) {
        let temporaryReference = temporarySnapshotReference()
        let temporarySplit = DockerRegistry.splitImageRef(temporaryReference)
        let finalReference = containerSnapshotReference(
            sourceIdentifier: sourceIdentifier,
            containerID: container.id
        )
        let rollbackReference = existingTargetImageID == nil ? nil : containerSnapshotRollbackReference(
            sourceIdentifier: sourceIdentifier,
            containerID: container.id
        )
        let labels = [
            "dory.migration.temporary": "true",
            "dory.migration.container-snapshot": "true",
            "dory.migration.container-id": container.id,
            "dory.migrated.source": sourceIdentifier,
        ]
        var sourceTemporaryCreated = false
        var targetArchiveLoaded = false
        var removedExistingFinal = false
        var boundFinal = false
        do {
            let committedID = try await source.commit(
                containerID: container.id,
                repo: temporarySplit.repo,
                tag: temporarySplit.tag,
                labels: labels,
                pause: false
            )
            sourceTemporaryCreated = true
            let targetImageIDsBefore = Set((try? await target.snapshot().images.map(\.imageID)) ?? [])
            _ = try await copyImageArchive(reference: temporaryReference, from: source, to: target)
            targetArchiveLoaded = true
            if let existingTargetImageID, let rollbackReference {
                let rollbackSplit = DockerRegistry.splitImageRef(rollbackReference)
                try await target.tagImage(
                    source: existingTargetImageID,
                    repo: rollbackSplit.repo,
                    tag: rollbackSplit.tag
                )
                try await removeTemporaryImageReferenceStrict(finalReference, from: target)
                removedExistingFinal = true
            }
            try await bindLoadedImage(
                reference: finalReference,
                directSource: committedID,
                loadedReference: temporaryReference,
                target: target,
                excluding: targetImageIDsBefore,
                failureContext: "could not bind container writable-layer snapshot"
            )
            boundFinal = true
            try await removeTemporaryImageReferenceStrict(temporaryReference, from: target)
            try await removeTemporaryImageReferenceStrict(temporaryReference, from: source)
            return (finalReference, rollbackReference)
        } catch {
            let primaryError = error
            var cleanupFailures: [String] = []
            if targetArchiveLoaded {
                do { try await removeTemporaryImageReferenceStrict(temporaryReference, from: target) }
                catch { cleanupFailures.append("target temporary snapshot: \(error)") }
            }
            if sourceTemporaryCreated {
                do { try await removeTemporaryImageReferenceStrict(temporaryReference, from: source) }
                catch { cleanupFailures.append("source temporary snapshot: \(error)") }
            }
            if removedExistingFinal, !boundFinal, let existingTargetImageID {
                let split = DockerRegistry.splitImageRef(finalReference)
                do {
                    try await target.tagImage(
                        source: existingTargetImageID,
                        repo: split.repo,
                        tag: split.tag
                    )
                    if let rollbackReference {
                        try await removeTemporaryImageReferenceStrict(rollbackReference, from: target)
                    }
                } catch {
                    cleanupFailures.append("restore prior target snapshot reference: \(error)")
                }
            }
            let cleanup = cleanupFailures.isEmpty
                ? ""
                : "; cleanup/rollback failed: \(cleanupFailures.joined(separator: "; "))"
            throw RuntimeFeatureError.unsupported("\(primaryError)\(cleanup)")
        }
    }

    /// A source daemon's bare content ID is not portable when the receiving daemon normalizes the
    /// image and computes a different ID. Docker also rejects tags whose repository is literally
    /// `sha256`, so give that content a deterministic ordinary reference and rewrite recreated
    /// containers to use it. Named and digest-pinned references pass through unchanged.
    private static func portableTargetReference(for sourceReference: String) -> String {
        let prefix = "sha256:"
        guard sourceReference.hasPrefix(prefix) else { return sourceReference }
        let digest = sourceReference.dropFirst(prefix.count)
        guard digest.count == 64,
              digest.allSatisfy({ $0.isHexDigit }) else { return sourceReference }
        return "dory-migration/imported:\(digest.lowercased())"
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
        let stream = source.saveImageThrowing(reference: reference)
        try await target.loadImageThrowing(stream: stream)
        return true
    }

    /// Docker engines can recompute an image's content ID while loading an archive produced by a
    /// different daemon version. Prefer a RepoTag that the loader already restored, then the source
    /// ID, and finally only a newly loaded dangling image. Failed rebinding removes only those new
    /// dangling candidates so a fallback attempt cannot silently consume hundreds of megabytes.
    private static func bindLoadedImage(
        reference: String,
        directSource: String,
        loadedReference: String? = nil,
        target: any ContainerRuntime,
        excluding preexistingImageIDs: Set<String>,
        failureContext: String
    ) async throws {
        let images = (try? await target.snapshot().images) ?? []
        let alreadyBound = images.contains { image in
            if image.additionalReferences.contains(reference) { return true }
            guard image.repository != "<none>", !image.repository.isEmpty else { return false }
            let candidate = image.tag == "<none>" || image.tag.isEmpty
                ? image.repository
                : "\(image.repository):\(image.tag)"
            return candidate == reference
        }
        if alreadyBound { return }

        let split = DockerRegistry.splitImageRef(reference)
        do {
            try await target.tagImage(source: directSource, repo: split.repo, tag: split.tag)
            return
        } catch let directTagError {
            // Image IDs are daemon-local. OrbStack can return one ID from commit while Dory's
            // dockerd computes a different ID for the exact archive. A Docker archive made from
            // our unique temporary tag preserves that tag, so use it as the authoritative bridge
            // before considering an untagged newly loaded image.
            if let loadedReference,
               loadedReference != directSource,
               (try? await target.tagImage(
                   source: loadedReference,
                   repo: split.repo,
                   tag: split.tag
               )) != nil {
                return
            }
            let candidates = images
                .filter { image in
                    !preexistingImageIDs.contains(image.imageID)
                        && (image.repository == "<none>" || image.repository.isEmpty)
                }
                .map(\.imageID)
            for candidate in candidates {
                if (try? await target.tagImage(source: candidate, repo: split.repo, tag: split.tag)) != nil {
                    return
                }
            }
            for candidate in candidates {
                try? await target.removeImage(id: candidate)
            }
            throw RuntimeFeatureError.unsupported("\(failureContext): \(directTagError)")
        }
    }

    private static func isMigrationOwned(
        _ labels: [String: String],
        sourceMarker: String,
        sourceIdentifier: String
    ) -> Bool {
        labels["dory.migrated.from"] == sourceMarker
            && labels["dory.migrated.source"] == sourceIdentifier
    }

    private static func isLegacyMigrationOwned(
        _ labels: [String: String],
        sourceMarker: String
    ) -> Bool {
        guard labels["dory.migrated.from"] == sourceMarker else { return false }
        let owner = labels["dory.migrated.source"]
        return owner == nil || owner?.isEmpty == true || owner == sourceMarker
    }

    private static func isTemporaryMigrationHelper(
        _ labels: [String: String],
        sourceIdentifier: String
    ) -> Bool {
        labels["dory.migration.temporary"] == "true"
            && labels["dory.migrated.source"] == sourceIdentifier
    }

    private static func isTemporaryMigrationImage(
        _ image: DockerImage,
        sourceIdentifier: String
    ) -> Bool {
        guard image.labels["dory.migration.temporary"] == "true",
              image.labels["dory.migrated.source"] == sourceIdentifier else { return false }
        let references = imageReferences(for: image)
        return references.isEmpty
            || references.contains(where: { $0.hasPrefix("dory-migration-temporary/snapshot:") })
            || image.repository == "<none>"
    }

    private static func isFinalMigrationSnapshotImage(
        _ image: DockerImage,
        sourceIdentifier: String
    ) -> Bool {
        guard image.labels["dory.migration.temporary"] == "true",
              image.labels["dory.migrated.source"] == sourceIdentifier,
              image.repository != "<none>" else { return false }
        return !imageReferences(for: image).contains {
            $0.hasPrefix("dory-migration-temporary/snapshot:")
        }
    }

    private static func normalizedVolumeDriver(_ driver: String) -> String {
        let trimmed = driver.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? "local" : trimmed
    }

    private static func networkSubnetsOverlap(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = ipv4Range(lhs), let right = ipv4Range(rhs) else {
            let a = lhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let b = rhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !a.isEmpty && a != "—" && a == b
        }
        return left.lower <= right.upper && right.lower <= left.upper
    }

    static func runningContainerUsesVolume(
        _ name: String,
        on runtime: any ContainerRuntime
    ) async -> Bool? {
        let filters = try? JSONSerialization.data(withJSONObject: ["volume": [name]], options: [.sortedKeys])
        guard let filters,
              let filterJSON = String(data: filters, encoding: .utf8),
              let response = await runtime.proxyRequest(
                  method: "GET",
                  path: "/containers/json?all=1&filters=\(DockerImageOps.queryValue(filterJSON))",
                  headers: [(name: "Accept", value: "application/json")],
                  body: Data()
              ), response.isSuccess,
              let containers = try? JSONSerialization.jsonObject(with: response.body) as? [[String: Any]] else {
            return nil
        }
        for container in containers where ["running", "restarting"].contains(
            ((container["State"] as? String) ?? "").lowercased()
        ) {
            guard let mounts = container["Mounts"] as? [[String: Any]] else { return nil }
            var matched = false
            for mount in mounts where ((mount["Type"] as? String) ?? "").lowercased() == "volume" {
                let source = (mount["Name"] as? String) ?? (mount["Source"] as? String) ?? ""
                guard source == name else { continue }
                matched = true
                guard let writable = mount["RW"] as? Bool else { return nil }
                if writable { return true }
            }
            // Docker's volume filter selected this running container but its list payload did not
            // expose the matching mount. Treat that as unknown instead of assuming read-only.
            if !matched { return nil }
        }
        return false
    }

    private static func networkSubnets(in object: [String: Any]?, fallback: String) -> [String] {
        let configured = ((object?["IPAM"] as? [String: Any])?["Config"] as? [[String: Any]] ?? [])
            .compactMap { ($0["Subnet"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !configured.isEmpty { return configured }
        let fallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty || fallback == "—" ? [] : [fallback]
    }

    private static func ipv4Range(_ cidr: String) -> (lower: UInt32, upper: UInt32)? {
        let parts = cidr.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/")
        guard parts.count == 2, let prefix = Int(parts[1]), (0...32).contains(prefix) else { return nil }
        let octets = parts[0].split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return nil }
        let address = octets.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let mask: UInt32 = prefix == 0 ? 0 : UInt32.max << UInt32(32 - prefix)
        let lower = address & mask
        return (lower, lower | ~mask)
    }

    private static func migrationLabels(source: any ContainerRuntime, existing: [String: String] = [:]) -> [String: String] {
        var labels = existing
        labels["dory.migrated.from"] = source.kind.rawValue
        labels["dory.migrated.source"] = source.migrationSourceIdentifier
        return labels
    }

    private static let portableNetworkCreateKeys = [
        "Driver", "Internal", "Attachable", "Ingress", "IPAM", "EnableIPv4", "EnableIPv6",
        "Options", "ConfigOnly", "ConfigFrom",
    ]

    private static func inspectedNetworkObject(
        name: String,
        on runtime: any ContainerRuntime
    ) async -> [String: Any]? {
        guard let response = await runtime.proxyRequest(
            method: "GET",
            path: "/networks/\(DockerImageOps.pathComponent(name))",
            headers: [(name: "Accept", value: "application/json")],
            body: Data()
        ), response.isSuccess else { return nil }
        return try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
    }

    private static func portableNetworkContract(_ object: [String: Any]) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: portableNetworkCreateKeys.compactMap { key in
            guard let value = object[key], !(value is NSNull) else { return nil }
            return (key, value)
        })
    }

    private static func networkContractsMatch(
        sourceObject: [String: Any]?,
        targetObject: [String: Any]?
    ) -> Bool {
        guard let sourceObject, let targetObject else { return false }
        return jsonContains(
            expected: portableNetworkContract(sourceObject),
            actual: portableNetworkContract(targetObject)
        )
    }

    /// Docker daemons may add defaults to inspect output that were absent from the create request
    /// (for example empty IPAM options). Require every source field recursively while allowing only
    /// such extra target fields, so resumability is strict without becoming daemon-version brittle.
    private static func jsonContains(expected: Any, actual: Any) -> Bool {
        if expected is NSNull { return actual is NSNull }
        if let expected = expected as? [String: Any] {
            guard let actual = actual as? [String: Any] else { return false }
            return expected.allSatisfy { key, value in
                guard let actualValue = actual[key] else { return false }
                return jsonContains(expected: value, actual: actualValue)
            }
        }
        if let expected = expected as? [Any] {
            guard let actual = actual as? [Any], expected.count == actual.count else { return false }
            return zip(expected, actual).allSatisfy { jsonContains(expected: $0.0, actual: $0.1) }
        }
        guard let expected = expected as? NSObject, let actual = actual as? NSObject else {
            return false
        }
        return expected.isEqual(actual)
    }

    private static func createNetworkPreservingContract(
        _ network: DoryNetwork,
        labels: [String: String],
        sourceObject: [String: Any]?,
        sourceSupportsRawProxy: Bool,
        on target: any ContainerRuntime
    ) async throws {
        guard let sourceObject else {
            if sourceSupportsRawProxy {
                throw RuntimeFeatureError.unsupported(
                    "source Docker API did not return the network's driver/IPAM/options contract"
                )
            }
            try await target.createNetwork(name: network.name, labels: labels)
            return
        }
        var createObject = portableNetworkContract(sourceObject)
        createObject["Name"] = network.name
        createObject["CheckDuplicate"] = true
        createObject["Labels"] = labels
        guard JSONSerialization.isValidJSONObject(createObject) else {
            throw RuntimeFeatureError.unsupported("source network inspect returned a non-portable contract")
        }
        let body = try JSONSerialization.data(withJSONObject: createObject, options: [.sortedKeys])
        guard let response = await target.proxyRequest(
            method: "POST",
            path: "/networks/create",
            headers: [(name: "Content-Type", value: "application/json")],
            body: body
        ) else {
            if target.supportsRawProxy {
                throw RuntimeFeatureError.unsupported(
                    "Dory Docker API was unavailable while creating the preserved network contract"
                )
            }
            try await target.createNetwork(name: network.name, labels: labels)
            return
        }
        guard response.isSuccess else {
            let detail = String(data: response.body, encoding: .utf8) ?? response.reason
            throw RuntimeFeatureError.unsupported(
                "Docker API rejected preserved network contract (HTTP \(response.statusCode): \(detail))"
            )
        }
    }

    private static func copyVolumeData(
        name: String,
        helperImages: [(source: String, target: String)],
        sourceIdentifier: String,
        from source: any ContainerRuntime,
        to target: any ContainerRuntime
    ) async throws -> (source: String, target: String) {
        var sourceHelper: String?
        var targetHelper: String?
        var selectedImages: (source: String, target: String)?
        var candidateFailures: [String] = []
        for candidate in helperImages {
            do {
                sourceHelper = try await createVolumeHelper(
                    on: source,
                    volume: name,
                    image: candidate.source,
                    readOnly: true,
                    sourceIdentifier: sourceIdentifier
                )
            } catch {
                candidateFailures.append("source image \(candidate.source): \(error)")
                sourceHelper = nil
                continue
            }
            do {
                targetHelper = try await createVolumeHelper(
                    on: target,
                    volume: name,
                    image: candidate.target,
                    readOnly: false,
                    sourceIdentifier: sourceIdentifier
                )
                selectedImages = candidate
                break
            } catch {
                let creationError = error
                if let sourceHelper {
                    do { try await removeVolumeHelper(sourceHelper, from: source) }
                    catch {
                        throw RuntimeFeatureError.unsupported(
                            "target image \(candidate.target) was unusable (\(creationError)); source helper cleanup also failed: \(error)"
                        )
                    }
                }
                sourceHelper = nil
                targetHelper = nil
                candidateFailures.append("target image \(candidate.target): \(creationError)")
            }
        }
        guard sourceHelper != nil, targetHelper != nil else {
            let detail = candidateFailures.isEmpty
                ? "no source/target helper image pairs were available"
                : candidateFailures.joined(separator: "; ")
            throw RuntimeFeatureError.unsupported("could not create a safe volume helper pair: \(detail)")
        }
        do {
            let archive = source.copyOutStream(containerID: sourceHelper!, path: "/data/.")
            try await target.copyInThrowing(
                containerID: targetHelper!,
                path: "/data",
                archiveStream: archive
            )
        } catch {
            var cleanupFailures: [String] = []
            if let sourceHelper {
                do { try await removeVolumeHelper(sourceHelper, from: source) }
                catch { cleanupFailures.append("source helper \(sourceHelper): \(error)") }
            }
            if let targetHelper {
                do { try await removeVolumeHelper(targetHelper, from: target) }
                catch { cleanupFailures.append("target helper \(targetHelper): \(error)") }
            }
            guard !cleanupFailures.isEmpty else { throw error }
            throw RuntimeFeatureError.unsupported(
                "volume copy failed: \(error); temporary helper cleanup also failed: \(cleanupFailures.joined(separator: "; "))"
            )
        }
        var cleanupFailures: [String] = []
        if let sourceHelper {
            do { try await removeVolumeHelper(sourceHelper, from: source) }
            catch { cleanupFailures.append("source helper \(sourceHelper): \(error)") }
        }
        if let targetHelper {
            do { try await removeVolumeHelper(targetHelper, from: target) }
            catch { cleanupFailures.append("target helper \(targetHelper): \(error)") }
        }
        if !cleanupFailures.isEmpty {
            throw RuntimeFeatureError.unsupported(
                "volume bytes copied but temporary helper cleanup failed: \(cleanupFailures.joined(separator: "; "))"
            )
        }
        guard let selectedImages else {
            throw RuntimeFeatureError.unsupported("volume helper selection was lost after a successful copy")
        }
        return selectedImages
    }

    private struct VolumeHelperCreate: Encodable {
        let Image: String
        let Cmd: [String]
        let Labels: [String: String]
        let HostConfig: VolumeHelperHostConfig
    }

    private struct VolumeHelperHostConfig: Encodable {
        let Mounts: [VolumeHelperMount]
    }

    private struct VolumeHelperMount: Encodable {
        let type: String
        let source: String
        let target: String
        let readOnly: Bool

        enum CodingKeys: String, CodingKey {
            case type = "Type", source = "Source", target = "Target", readOnly = "ReadOnly"
        }
    }

    private struct VolumeHelperCreateResult: Decodable {
        let Id: String
    }

    private static func createVolumeHelper(
        on runtime: any ContainerRuntime,
        volume: String,
        image: String,
        readOnly: Bool,
        sourceIdentifier: String
    ) async throws -> String {
        let body = try JSONEncoder().encode(VolumeHelperCreate(
            Image: image,
            Cmd: ["true"],
            Labels: [
                "dory.migration.temporary": "true",
                "dory.migrated.source": sourceIdentifier,
            ],
            HostConfig: VolumeHelperHostConfig(Mounts: [
                VolumeHelperMount(type: "volume", source: volume, target: "/data", readOnly: readOnly),
            ])
        ))
        guard let response = await runtime.proxyRequest(
            method: "POST",
            path: "/containers/create",
            headers: [(name: "Content-Type", value: "application/json")],
            body: body
        ) else {
            throw RuntimeFeatureError.unsupported("could not reach Docker API to create volume helper")
        }
        guard response.isSuccess else {
            let detail = String(data: response.body, encoding: .utf8) ?? response.reason
            throw RuntimeFeatureError.unsupported("could not create volume helper (HTTP \(response.statusCode): \(detail))")
        }
        guard let created = try? JSONDecoder().decode(VolumeHelperCreateResult.self, from: response.body) else {
            throw RuntimeFeatureError.unsupported("Docker API returned an invalid volume-helper response")
        }
        return created.Id
    }

    /// Docker's list endpoint omits most create-time settings. Rebuild a create request from the
    /// read-only inspect response so entrypoint, command, restart policy, resources, ports, mounts,
    /// and network aliases survive migration. Non-Docker test/runtime implementations fall back to
    /// the inventory model below.
    private static func inspectedMigrationSpec(
        for container: Container,
        source: any ContainerRuntime
    ) async -> ContainerSpec? {
        guard let response = await source.proxyRequest(
            method: "GET",
            path: "/containers/\(DockerImageOps.pathComponent(container.id))/json",
            headers: [(name: "Accept", value: "application/json")],
            body: Data()
        ), response.isSuccess,
              let root = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              var config = root["Config"] as? [String: Any] else { return nil }

        var hostConfig = root["HostConfig"] as? [String: Any] ?? [:]
        if let mounts = root["Mounts"] as? [[String: Any]], !mounts.isEmpty {
            let configured = hostConfig["Mounts"] as? [[String: Any]] ?? []
            let resolvedByTarget = Dictionary(uniqueKeysWithValues: mounts.compactMap { mount -> (String, [String: Any])? in
                guard let target = (mount["Target"] ?? mount["Destination"]) as? String else { return nil }
                return (target, mount)
            })
            let resolvedConfigured = configured.map { configuredMount -> [String: Any] in
                var result = configuredMount
                guard (result["Type"] as? String)?.lowercased() == "volume",
                      ((result["Source"] as? String) ?? "").isEmpty,
                      let target = (result["Target"] ?? result["Destination"]) as? String,
                      let resolved = resolvedByTarget[target],
                      let source = (resolved["Name"] ?? resolved["Source"]) as? String,
                      !source.isEmpty else { return result }
                result["Source"] = source
                return result
            }
            let configuredTargets = Set(configured.compactMap { mount in
                (mount["Target"] ?? mount["Destination"]) as? String
            })
            let legacyTmpfsTargets = Set((hostConfig["Tmpfs"] as? [String: Any] ?? [:]).keys)
            let legacyBindTargets = Set((hostConfig["Binds"] as? [String] ?? []).compactMap(legacyBindTarget))
            // HostConfig.Mounts retains create-time BindOptions/VolumeOptions/TmpfsOptions, while
            // root Mounts resolves anonymous/named volume identities. Prefer the rich configured
            // entry per target and append only resolved mounts that it did not already describe.
            hostConfig["Mounts"] = resolvedConfigured + mounts.filter { mount in
                guard let target = (mount["Target"] ?? mount["Destination"]) as? String else { return true }
                return !configuredTargets.contains(target)
                    && !legacyTmpfsTargets.contains(target)
                    && !legacyBindTargets.contains(target)
            }
        }
        config["HostConfig"] = hostConfig
        if let networkSettings = root["NetworkSettings"] as? [String: Any],
           let networks = networkSettings["Networks"] as? [String: Any] {
            config["NetworkingConfig"] = ["EndpointsConfig": networks]
        }
        guard JSONSerialization.isValidJSONObject(config),
              let requestData = try? JSONSerialization.data(withJSONObject: config),
              let request = try? JSONDecoder().decode(DockerCreateRequest.self, from: requestData) else {
            return nil
        }
        var spec = request.spec(name: container.name)
        spec.labels = migrationLabels(source: source, existing: spec.labels)
        spec.networks.removeAll { defaultNetworkNames.contains($0) }
        spec.networkEndpointSettings = Dictionary(uniqueKeysWithValues: spec.networkEndpointSettings.compactMap { name, endpoint in
            guard !defaultNetworkNames.contains(name) else { return nil }
            // Inspect reports daemon-local network/endpoint IDs and dynamically allocated
            // addresses. Those cannot exist on Dory after recreation. `IPAMConfig`, however, is
            // the user's portable static-address intent and remains valid because the network's
            // subnet/gateway contract is now recreated exactly.
            return (name, DockerEndpointSettings(
                IPAMConfig: endpoint.IPAMConfig,
                Links: endpoint.Links,
                Aliases: endpoint.Aliases,
                DriverOpts: endpoint.DriverOpts
            ))
        })
        return spec
    }

    private static func removeVolumeHelper(_ id: String, from runtime: any ContainerRuntime) async throws {
        guard let response = await runtime.proxyRequest(
            method: "DELETE",
            path: "/containers/\(DockerImageOps.pathComponent(id))?force=true&v=true",
            headers: [],
            body: Data()
        ) else {
            throw RuntimeFeatureError.unsupported("Docker API unavailable during helper cleanup")
        }
        guard response.isSuccess || response.statusCode == 404 else {
            let detail = String(data: response.body, encoding: .utf8) ?? response.reason
            throw RuntimeFeatureError.unsupported(
                "helper cleanup failed (HTTP \(response.statusCode): \(detail))"
            )
        }
    }

    private static func removeTemporaryImageReferenceStrict(
        _ reference: String,
        from runtime: any ContainerRuntime
    ) async throws {
        guard let response = await runtime.proxyRequest(
            method: "DELETE",
            path: "/images/\(DockerImageOps.pathComponent(reference))",
            headers: [],
            body: Data()
        ) else {
            throw RuntimeFeatureError.unsupported("Docker API unavailable during temporary image cleanup")
        }
        guard response.isSuccess || response.statusCode == 404 else {
            let detail = String(data: response.body, encoding: .utf8) ?? response.reason
            throw RuntimeFeatureError.unsupported(
                "temporary image cleanup failed (HTTP \(response.statusCode): \(detail))"
            )
        }
    }

    @discardableResult
    private static func cleanupTemporaryImageReferences(
        _ references: [String],
        from runtime: any ContainerRuntime
    ) async -> [String] {
        var failures: [String] = []
        for reference in references {
            do { try await removeTemporaryImageReferenceStrict(reference, from: runtime) }
            catch { failures.append("cleanup temporary source image \(reference): \(error)") }
        }
        return failures
    }

    private static func migrationSpec(for container: Container, env: [EnvVar], source: any ContainerRuntime) -> ContainerSpec {
        ContainerSpec(
            name: container.name,
            image: container.image,
            command: container.commandArgs,
            environment: Dictionary(env.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first }),
            ports: parsePorts(container.ports),
            labels: migrationLabels(source: source, existing: container.labels),
            networks: container.networks.filter { !defaultNetworkNames.contains($0) },
            volumes: container.volumes,
            restart: container.restartPolicy == "—" ? nil : container.restartPolicy,
            nanoCPUs: container.nanoCPUs,
            memoryLimitBytes: container.memoryLimitBytes,
            mounts: container.mounts,
            volumeTargets: container.volumeTargets,
            hostname: container.hostname,
            domainname: container.domainname,
            macAddress: container.macAddress,
            user: container.user,
            workingDir: container.workingDir,
            entrypoint: container.entrypoint,
            shell: container.shell,
            tty: container.tty,
            openStdin: container.openStdin,
            stdinOnce: container.stdinOnce,
            stopSignal: container.stopSignal,
            stopTimeout: container.stopTimeout,
            networkMode: container.networkMode,
            autoRemove: container.autoRemove,
            privileged: container.privileged,
            initProcessEnabled: container.initProcessEnabled,
            capAdd: container.capAdd,
            capDrop: container.capDrop,
            dns: container.dns,
            dnsOptions: container.dnsOptions,
            dnsSearch: container.dnsSearch,
            extraHosts: container.extraHosts,
            groupAdd: container.groupAdd,
            ipcMode: container.ipcMode,
            pidMode: container.pidMode,
            usernsMode: container.usernsMode,
            readonlyRootfs: container.readonlyRootfs,
            shmSize: container.shmSize,
            tmpfs: container.tmpfs,
            attachStdin: container.attachStdin,
            attachStdout: container.attachStdout,
            attachStderr: container.attachStderr,
            healthcheck: container.healthcheck,
            networkDisabled: container.networkDisabled,
            containerIDFile: container.containerIDFile,
            logConfig: container.logConfig,
            volumeDriver: container.volumeDriver,
            volumesFrom: container.volumesFrom,
            consoleSize: container.consoleSize,
            annotations: container.annotations,
            cgroupnsMode: container.cgroupnsMode,
            cgroup: container.cgroup,
            links: container.links,
            oomScoreAdj: container.oomScoreAdj,
            publishAllPorts: container.publishAllPorts,
            securityOpt: container.securityOpt,
            storageOpt: container.storageOpt,
            utsMode: container.utsMode,
            sysctls: container.sysctls,
            runtimeName: container.runtimeName,
            isolation: container.isolation,
            maskedPaths: container.maskedPaths,
            readonlyPaths: container.readonlyPaths,
            resources: container.resources
        )
    }

    private static func estimatedBytes(_ image: DockerImage) -> Int64 {
        image.sizeBytes > 0 ? image.sizeBytes : estimatedBytes(for: image.size)
    }
}
