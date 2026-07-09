import Foundation

struct MigrationSummary: Sendable, Equatable {
    var imagesImported: [String] = []
    var imagesPulled: [String] { imagesImported }
    var volumesCopied: [String] = []
    var networksCreated: [String] = []
    var containersMigrated: [String] = []
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
        if volumes > 0 {
            items.append("\(volumes) named volume\(volumes == 1 ? "" : "s") copied with data")
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
        if estimatedImageBytes > 0 {
            items.append("Plan for at least \(estimatedImageDiskDisplay) of image space, plus named volume data.")
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
        let customNetworks = snapshot.networks.filter { !defaultNetworkNames.contains($0.name) }
        return MigrationInventory(
            sourceName: sourceDisplayName(source),
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

        let customNetworks = snapshot.networks.filter { !defaultNetworkNames.contains($0.name) }
        for network in customNetworks {
            progress?("Creating network \(network.name)")
            do {
                try await target.createNetwork(name: network.name, labels: migrationLabels(source: source, existing: network.labels))
                summary.networksCreated.append(network.name)
            } catch {
                summary.failures.append("create network \(network.name)")
            }
        }

        let helperImages = helperImagesByVolume(snapshot: snapshot)
        for volume in snapshot.volumes {
            progress?("Copying volume \(volume.name)")
            do {
                try await target.createVolume(
                    name: volume.name,
                    driver: volume.driver.isEmpty ? nil : volume.driver,
                    labels: migrationLabels(source: source, existing: volume.labels),
                    driverOptions: volume.options
                )
                guard let helperImage = helperImages[volume.name] else {
                    summary.failures.append("copy volume \(volume.name) (no reusable helper image)")
                    continue
                }
                try await copyVolumeData(
                    name: volume.name,
                    helperImage: helperImage,
                    from: source,
                    to: target
                )
                summary.volumesCopied.append(volume.name)
            } catch {
                summary.failures.append("copy volume \(volume.name)")
            }
        }

        guard recreateContainers else { return summary }
        for container in snapshot.containers {
            progress?("Recreating \(container.name)")
            let env = (try? await source.env(containerID: container.id)) ?? []
            let spec = migrationSpec(for: container, env: env, source: source)
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

    private static func migrationLabels(source: any ContainerRuntime, existing: [String: String] = [:]) -> [String: String] {
        var labels = existing
        labels["dory.migrated.from"] = source.kind.rawValue
        return labels
    }

    private static func helperImagesByVolume(snapshot: RuntimeSnapshot) -> [String: String] {
        let realImageReference = snapshot.images
            .first { $0.repository != "<none>" && !$0.repository.isEmpty }
            .map { "\($0.repository):\($0.tag)" }
        var result: [String: String] = [:]
        for volume in snapshot.volumes {
            if let container = snapshot.containers.first(where: { container in
                container.mounts.contains { $0.type == "volume" && $0.source == volume.name }
            }) {
                result[volume.name] = container.image
            } else if let realImageReference {
                result[volume.name] = realImageReference
            }
        }
        return result
    }

    private static func copyVolumeData(
        name: String,
        helperImage: String,
        from source: any ContainerRuntime,
        to target: any ContainerRuntime
    ) async throws {
        let sourceHelper = try await createVolumeHelper(on: source, volume: name, image: helperImage, readOnly: true)
        let targetHelper = try await createVolumeHelper(on: target, volume: name, image: helperImage, readOnly: false)
        defer {
            Task {
                await removeVolumeHelper(sourceHelper, from: source)
                await removeVolumeHelper(targetHelper, from: target)
            }
        }
        let archive = source.copyOutStream(containerID: sourceHelper, path: "/data/.")
        let copied = await target.copyIn(containerID: targetHelper, path: "/data", archiveStream: archive)
        if !copied { throw RuntimeFeatureError.unsupported("volume archive copy failed") }
    }

    private struct VolumeHelperCreate: Encodable {
        let Image: String
        let Cmd: [String]
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
        readOnly: Bool
    ) async throws -> String {
        let body = try JSONEncoder().encode(VolumeHelperCreate(
            Image: image,
            Cmd: ["true"],
            HostConfig: VolumeHelperHostConfig(Mounts: [
                VolumeHelperMount(type: "volume", source: volume, target: "/data", readOnly: readOnly),
            ])
        ))
        guard let response = await runtime.proxyRequest(
            method: "POST",
            path: "/containers/create",
            headers: [(name: "Content-Type", value: "application/json")],
            body: body
        ), response.isSuccess,
              let created = try? JSONDecoder().decode(VolumeHelperCreateResult.self, from: response.body) else {
            throw RuntimeFeatureError.unsupported("could not create volume helper")
        }
        return created.Id
    }

    private static func removeVolumeHelper(_ id: String, from runtime: any ContainerRuntime) async {
        _ = await runtime.proxyRequest(
            method: "DELETE",
            path: "/containers/\(DockerImageOps.pathComponent(id))?force=true&v=true",
            headers: [],
            body: Data()
        )
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
