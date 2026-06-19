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

    func networkName(_ project: ComposeProject) -> String { "\(project.name)_default" }
    func containerName(_ project: ComposeProject, _ service: String) -> String { "\(project.name)-\(service)-1" }

    @discardableResult
    func up(_ project: ComposeProject, pullImages: Bool = false, progress: (@MainActor (ComposeProgress) -> Void)? = nil) async throws -> [String: String] {
        try await runtime.createNetwork(name: networkName(project), labels: projectLabels(project))

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

    func down(_ project: ComposeProject) async throws {
        let snapshot = try await runtime.snapshot()
        let prefix = "\(project.name)-"
        let projectContainers = snapshot.containers.filter { $0.name.hasPrefix(prefix) }
        // Tear down in reverse start order so a service is removed only after everything that
        // depends on it — the inverse of `up`. Unranked containers fall to the end.
        let order = (try? project.startOrder()) ?? []
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = projectContainers.sorted {
            ($0.composeService.flatMap { rank[$0] } ?? -1) > ($1.composeService.flatMap { rank[$0] } ?? -1)
        }
        for container in ordered {
            try? await runtime.stop(containerID: container.id)
            try? await runtime.remove(containerID: container.id)
        }
        try? await runtime.removeNetwork(name: networkName(project))
    }

    func spec(for service: ComposeService, in project: ComposeProject) -> ContainerSpec {
        ContainerSpec(
            name: containerName(project, service.name),
            image: service.image ?? "",
            command: service.command,
            environment: service.environment,
            ports: service.ports,
            labels: projectLabels(project).merging([
                "com.docker.compose.service": service.name,
                "com.docker.compose.container-number": "1",
            ], uniquingKeysWith: { _, new in new }),
            networks: [networkName(project)] + service.networks,
            volumes: service.volumes,
            restart: service.restart
        )
    }

    private func projectLabels(_ project: ComposeProject) -> [String: String] {
        ["com.docker.compose.project": project.name]
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
