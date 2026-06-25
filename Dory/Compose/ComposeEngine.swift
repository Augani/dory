import Foundation

enum ComposeError: Error, Sendable, Equatable {
    case missingImage(service: String)
    case dependencyUnhealthy(service: String)
    case dependencyTimeout(service: String)
    case dependencyFailed(service: String)
}

struct ComposeProgress: Sendable {
    var service: String
    var message: String
}

@MainActor
final class ComposeEngine {
    private let runtime: any ContainerRuntime
    private let healthPollCap: TimeInterval
    private let maxHealthAttempts: Int

    init(runtime: any ContainerRuntime, healthPollCap: TimeInterval = 2, maxHealthAttempts: Int = 30) {
        self.runtime = runtime
        self.healthPollCap = healthPollCap
        self.maxHealthAttempts = maxHealthAttempts
    }

    func networkName(_ project: ComposeProject) -> String { networkName(project, "default") }
    func networkName(_ project: ComposeProject, _ network: String) -> String { "\(project.name)_\(network)" }
    func containerName(_ project: ComposeProject, _ service: String) -> String { "\(project.name)-\(service)-1" }
    func volumeName(_ project: ComposeProject, _ volume: String) -> String { "\(project.name)_\(volume)" }

    @discardableResult
    func up(_ project: ComposeProject, pullImages: Bool = false, progress: (@MainActor (ComposeProgress) -> Void)? = nil) async throws -> [String: String] {
        for network in projectNetworkKeys(project) {
            try await ensureProjectNetwork(name: networkName(project, network), labels: networkLabels(project, network: network))
        }
        for volume in project.volumes {
            try await ensureProjectVolume(name: volumeName(project, volume), labels: volumeLabels(project, volume: volume))
        }

        var idByService: [String: String] = [:]
        let order = try project.startOrder()
        for serviceName in order {
            guard let service = project.service(named: serviceName) else { continue }

            for dependency in service.dependsOn {
                try await waitForCondition(dependency, project: project, ids: idByService)
            }

            guard let image = service.image else { throw ComposeError.missingImage(service: serviceName) }
            if pullImages {
                progress?(ComposeProgress(service: serviceName, message: "Pulling \(image)"))
                try await runtime.pull(image: image)
            }

            progress?(ComposeProgress(service: serviceName, message: "Creating"))
            let id = try await runtime.create(spec(for: service, in: project))
            progress?(ComposeProgress(service: serviceName, message: "Starting"))
            try await runtime.start(containerID: id)
            idByService[serviceName] = id
        }
        return idByService
    }

    private func ensureProjectNetwork(name: String, labels: [String: String]) async throws {
        do {
            try await runtime.createNetwork(name: name, labels: labels)
        } catch {
            guard Self.isAlreadyExists(error) else { throw error }
        }
    }

    private func ensureProjectVolume(name: String, labels: [String: String]) async throws {
        do {
            try await runtime.createVolume(name: name, driver: nil, labels: labels, driverOptions: [:])
        } catch {
            guard Self.isAlreadyExists(error) else { throw error }
        }
    }

    private static func isAlreadyExists(_ error: Error) -> Bool {
        if case ShellError.nonZeroExit(_, let output) = error {
            return output.localizedCaseInsensitiveContains("already exists")
        }
        if case HTTPError.status(let code, let message) = error {
            if message.localizedCaseInsensitiveContains("already exists") { return true }
            return code == 409 && message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return String(describing: error).localizedCaseInsensitiveContains("already exists")
    }

    func down(_ project: ComposeProject, removeVolumes: Bool = false) async throws {
        let snapshot = try await runtime.snapshot()
        let prefix = "\(project.name)-"
        let projectContainers = snapshot.containers.filter { $0.name.hasPrefix(prefix) }
        let order = (try? project.startOrder()) ?? []
        let ordered = Self.teardownOrder(containers: projectContainers, startOrder: order)
        for container in ordered {
            try? await runtime.stop(containerID: container.id)
            try? await runtime.remove(containerID: container.id)
        }
        for network in projectNetworkKeys(project).reversed() {
            try? await runtime.removeNetwork(name: networkName(project, network))
        }
        if removeVolumes {
            for volume in project.volumes {
                try? await runtime.removeVolume(name: volumeName(project, volume))
            }
        }
    }

    func spec(for service: ComposeService, in project: ComposeProject) -> ContainerSpec {
        let networkDisabled = service.networkMode == "none" ? true : nil
        let stopTimeout = service.stopGracePeriod.map { Int($0.rounded(.up)) }
        let resources = ContainerResourceUpdate(
            memoryReservationBytes: service.memoryReservationBytes,
            memorySwapBytes: service.memorySwapBytes,
            memorySwappiness: service.memorySwappiness,
            oomKillDisable: service.oomKillDisable,
            pidsLimit: service.pidsLimit,
            ulimits: service.ulimits.isEmpty ? nil : service.ulimits
        )
        var spec = ContainerSpec(name: containerName(project, service.name), image: service.image ?? "")
        spec.command = service.command
        spec.entrypoint = service.entrypoint
        spec.environment = service.environment
        spec.ports = service.ports
        spec.labels = projectLabels(project).merging([
            "com.docker.compose.service": service.name,
            "com.docker.compose.container-number": "1",
        ], uniquingKeysWith: { _, new in new })
        spec.networks = serviceNetworkKeys(service).map { networkName(project, $0) }
        spec.volumes = service.volumes.map { rewriteVolumeReference($0, in: project) }
        spec.restart = service.restart
        spec.memoryLimitBytes = service.memoryLimitBytes
        spec.hostname = service.hostname
        spec.domainname = service.domainname
        spec.user = service.user
        spec.workingDir = service.workingDir
        spec.tty = service.tty
        spec.openStdin = service.stdinOpen
        spec.stopSignal = service.stopSignal
        spec.stopTimeout = stopTimeout
        spec.networkMode = service.networkMode
        spec.privileged = service.privileged
        spec.initProcessEnabled = service.initProcessEnabled
        spec.capAdd = service.capAdd
        spec.capDrop = service.capDrop
        spec.dns = service.dns
        spec.dnsOptions = service.dnsOptions
        spec.dnsSearch = service.dnsSearch
        spec.extraHosts = service.extraHosts
        spec.groupAdd = service.groupAdd
        spec.ipcMode = service.ipcMode
        spec.pidMode = service.pidMode
        spec.usernsMode = service.usernsMode
        spec.readonlyRootfs = service.readOnly
        spec.shmSize = service.shmSize
        spec.tmpfs = service.tmpfs
        spec.attachStdin = service.stdinOpen ? true : nil
        spec.healthcheck = service.healthcheck?.dockerConfig
        spec.networkDisabled = networkDisabled
        spec.logConfig = service.logging?.dockerConfig
        spec.volumesFrom = service.volumesFrom
        spec.links = service.links
        spec.oomScoreAdj = service.oomScoreAdj
        spec.securityOpt = service.securityOpt
        spec.storageOpt = service.storageOpt
        spec.utsMode = service.utsMode
        spec.sysctls = service.sysctls
        spec.runtimeName = service.runtimeName
        spec.isolation = service.isolation
        spec.resources = resources
        return spec
    }

    private func projectLabels(_ project: ComposeProject) -> [String: String] {
        ["com.docker.compose.project": project.name]
    }

    private func networkLabels(_ project: ComposeProject, network: String) -> [String: String] {
        projectLabels(project).merging(["com.docker.compose.network": network], uniquingKeysWith: { _, new in new })
    }
    private func volumeLabels(_ project: ComposeProject, volume: String) -> [String: String] {
        projectLabels(project).merging(["com.docker.compose.volume": volume], uniquingKeysWith: { _, new in new })
    }

    private func rewriteVolumeReference(_ reference: String, in project: ComposeProject) -> String {
        guard let separator = reference.firstIndex(of: ":") else { return reference }
        let source = String(reference[..<separator])
        guard project.volumes.contains(source) else { return reference }
        return volumeName(project, source) + reference[separator...]
    }

    private func projectNetworkKeys(_ project: ComposeProject) -> [String] {
        let keys = Set(project.services.flatMap(serviceNetworkKeys))
        return keys.sorted {
            if $0 == "default" { return true }
            if $1 == "default" { return false }
            return $0 < $1
        }
    }

    private func serviceNetworkKeys(_ service: ComposeService) -> [String] {
        if service.networkMode != nil { return [] }
        return service.networks.isEmpty ? ["default"] : service.networks
    }

    private func waitForCondition(_ dependency: ComposeDependency, project: ComposeProject, ids: [String: String]) async throws {
        guard let id = ids[dependency.service] else { return }
        switch dependency.condition {
        case .started:
            return
        case .healthy:
            guard let service = project.service(named: dependency.service) else { return }
            try await waitForHealthy(service, containerID: id)
        case .completedSuccessfully:
            try await waitForCompletion(service: dependency.service, containerID: id)
        }
    }

    private func waitForHealthy(_ service: ComposeService, containerID: String) async throws {
        guard let healthcheck = service.healthcheck, let command = Self.probeCommand(healthcheck.test) else { return }
        var monitor = HealthMonitor(config: healthcheck.config)
        let start = Date()
        let pollInterval = min(max(0.05, healthcheck.interval), healthPollCap)
        // The budget must cover the start period plus the retry window, or a slow-starting service
        // would time out before it ever has a chance to report healthy.
        let budget = healthcheck.startPeriod + Double(max(1, healthcheck.retries)) * healthcheck.interval + pollInterval
        let attempts = max(maxHealthAttempts, Int(budget / pollInterval) + 2)
        for _ in 0..<attempts {
            let result = (try? await runtime.exec(containerID: containerID, command: command)) ?? ExecResult(exitCode: 1, output: "")
            monitor.record(success: result.succeeded, elapsed: Date().timeIntervalSince(start))
            if monitor.state == .healthy { return }
            if monitor.state == .unhealthy { throw ComposeError.dependencyUnhealthy(service: service.name) }
            try await Task.sleep(for: .seconds(pollInterval))
        }
        throw ComposeError.dependencyTimeout(service: service.name)
    }

    private func waitForCompletion(service: String, containerID: String) async throws {
        let pollInterval = min(1.0, healthPollCap)
        let attempts = max(maxHealthAttempts, Int(120.0 / pollInterval))
        for _ in 0..<attempts {
            let snapshot = try await runtime.snapshot()
            if let container = snapshot.containers.first(where: { $0.id == containerID }), container.status != .running {
                // "completed_successfully" requires a zero exit; a failed dependency must fail the up.
                if let code = await runtime.containerExitCode(containerID), code != 0 {
                    throw ComposeError.dependencyFailed(service: service)
                }
                return
            }
            try await Task.sleep(for: .seconds(pollInterval))
        }
        throw ComposeError.dependencyTimeout(service: service)
    }

    /// Tear down in reverse start order so dependents are removed before dependencies.
    static func teardownOrder(containers: [Container], startOrder: [String]) -> [Container] {
        let rank = Dictionary(startOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return containers.sorted {
            ($0.composeService.flatMap { rank[$0] } ?? -1) > ($1.composeService.flatMap { rank[$0] } ?? -1)
        }
    }

    static func probeCommand(_ test: [String]) -> [String]? {
        guard let first = test.first else { return nil }
        switch first {
        case "NONE": return nil
        case "CMD": return Array(test.dropFirst())
        case "CMD-SHELL": return ["sh", "-c", test.dropFirst().joined(separator: " ")]
        default: return test
        }
    }
}
