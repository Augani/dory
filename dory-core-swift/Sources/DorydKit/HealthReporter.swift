import Darwin
import Foundation

public enum HealthCheckStatus: String, Sendable, Codable {
    case pass
    case warn
    case fail
    case skip
}

public struct HealthCheck: Sendable, Equatable, Codable {
    public var id: String
    public var status: HealthCheckStatus
    public var code: String
    public var title: String
    public var detail: String
    public var action: String?
    public var data: [String: String]

    public init(
        id: String,
        status: HealthCheckStatus,
        code: String,
        title: String,
        detail: String,
        action: String? = nil,
        data: [String: String] = [:]
    ) {
        self.id = id
        self.status = status
        self.code = code
        self.title = title
        self.detail = detail
        self.action = action
        self.data = data
    }

    public var xpcDictionary: NSDictionary {
        var dictionary: [String: Any] = [
            "id": id,
            "status": status.rawValue,
            "code": code,
            "title": title,
            "detail": detail,
        ]
        if let action, !action.isEmpty {
            dictionary["action"] = action
        }
        if !data.isEmpty {
            dictionary["data"] = data
        }
        return dictionary as NSDictionary
    }
}

public struct DoctorReport: Sendable, Equatable {
    public var generatedAt: Date
    public var results: [HealthCheck]

    public init(generatedAt: Date = Date(), results: [HealthCheck]) {
        self.generatedAt = generatedAt
        self.results = results
    }

    public var xpcDictionary: NSDictionary {
        [
            "generated_at": iso8601String(generatedAt),
            "results": results.map(\.xpcDictionary),
        ]
    }

    public func jsonData() throws -> Data {
        try JSONSerialization.data(withJSONObject: xpcDictionary, options: [.prettyPrinted, .sortedKeys])
    }

    public func jsonString() throws -> String {
        String(data: try jsonData(), encoding: .utf8) ?? "{}"
    }
}

private func iso8601String(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

public final class HealthReporter: @unchecked Sendable {
    private let dockerTier: DockerTier?
    private let machineManager: MachineManager?
    private let remoteManager: RemoteMachineManager?
    private let socketPath: String
    private let home: String
    private let environment: [String: String]
    private let fileManager: FileManager
    private let dockerAPIProbe: any DockerAPIProbing
    private let commandRunner: any HealthCommandRunning
    private let registryProbe: any HealthRegistryProbing

    public init(
        socketPath: String,
        dockerTier: DockerTier?,
        machineManager: MachineManager? = nil,
        remoteManager: RemoteMachineManager?,
        dockerAPIProbe: any DockerAPIProbing = UnixDockerAPIProbe(),
        commandRunner: any HealthCommandRunning = ProcessHealthCommandRunner(),
        registryProbe: any HealthRegistryProbing = URLSessionHealthRegistryProbe(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) {
        self.socketPath = socketPath
        self.dockerTier = dockerTier
        self.machineManager = machineManager
        self.remoteManager = remoteManager
        self.home = home
        self.environment = environment
        self.dockerAPIProbe = dockerAPIProbe
        self.commandRunner = commandRunner
        self.registryProbe = registryProbe
        self.fileManager = fileManager
    }

    public func report(now: Date = Date()) -> DoctorReport {
        var checks = compatibilityChecks()
        checks.append(engineCheck())
        checks.append(contentsOf: machineChecks())
        checks.append(contentsOf: remoteChecks())
        return DoctorReport(generatedAt: now, results: checks)
    }

    public func doctorReport(now: Date = Date()) -> DoctorReport {
        DoctorReport(generatedAt: now, results: compatibilityChecks())
    }

    private func compatibilityChecks() -> [HealthCheck] {
        var checks: [HealthCheck] = []
        let dockerTierSleeping = dockerTier?.status().state == .sleeping
        checks.append(socketCheck())
        let ping = socketPingCheck()
        checks.append(ping)
        let dockerReachable = ping.code == "socket.ping_ok"
        checks.append(contentsOf: dockerCLIChecks(skipServerProbe: dockerTierSleeping))
        checks.append(contentsOf: dockerContextChecks())
        checks.append(contentsOf: registryChecks())
        checks.append(proxyCheck())
        checks.append(lanExposureCheck())
        checks.append(containerDNSSkipCheck())
        checks.append(publishedPortsCheck(dockerReachable: dockerReachable))
        checks.append(domainTableCheck(dockerReachable: dockerReachable))
        checks.append(mountBasicSkipCheck())
        checks.append(mountLockSkipCheck())
        checks.append(mountWatchSkipCheck())
        checks.append(vmClockSkipCheck())
        checks.append(contentsOf: diskChecks(dockerReachable: dockerReachable))
        checks.append(memoryCheck())
        checks.append(helperResolverCheck())
        return checks
    }

    private func socketCheck() -> HealthCheck {
        guard fileManager.fileExists(atPath: socketPath) else {
            return HealthCheck(
                id: "socket.exists",
                status: .fail,
                code: "socket.missing",
                title: "Docker socket missing",
                detail: "\(socketPath) does not exist",
                action: "Start doryd or run engineStart over XPC."
            )
        }

        var statBuffer = stat()
        guard lstat(socketPath, &statBuffer) == 0 else {
            return HealthCheck(
                id: "socket.exists",
                status: .fail,
                code: "socket.stat_failed",
                title: "Docker socket could not be inspected",
                detail: "\(socketPath): \(String(cString: strerror(errno)))"
            )
        }

        guard (statBuffer.st_mode & S_IFMT) == S_IFSOCK else {
            return HealthCheck(
                id: "socket.exists",
                status: .fail,
                code: "socket.not_socket",
                title: "Docker socket path is not a socket",
                detail: "\(socketPath) exists but is not a unix socket",
                action: "Move the stale path aside and restart doryd."
            )
        }

        return HealthCheck(
            id: "socket.exists",
            status: .pass,
            code: "socket.ok",
            title: "Docker socket exists",
            detail: socketPath
        )
    }

    private func socketPingCheck() -> HealthCheck {
        switch dockerAPIProbe.ping(socketPath: socketPath) {
        case .ok:
            return HealthCheck(
                id: "socket.ping",
                status: .pass,
                code: "socket.ping_ok",
                title: "Docker API ping passed",
                detail: "Docker API returned OK"
            )
        case let .badPing(statusCode, body):
            return HealthCheck(
                id: "socket.ping",
                status: .fail,
                code: "socket.bad_ping",
                title: "Docker API ping failed",
                detail: "HTTP \(statusCode): \(String(body.prefix(120)))"
            )
        case let .unreachable(detail):
            return HealthCheck(
                id: "socket.ping",
                status: .fail,
                code: "socket.unreachable",
                title: "Docker API is not reachable",
                detail: detail,
                action: "Start Dory or run `dory repair socket` if the socket path is stale."
            )
        }
    }

    private func dockerCLIChecks(skipServerProbe: Bool) -> [HealthCheck] {
        guard let binary = dockerBinary() else {
            return [
                HealthCheck(
                    id: "docker.cli",
                    status: .fail,
                    code: "docker.cli_missing",
                    title: "Docker CLI missing",
                    detail: "No docker executable found in PATH or DORY_DOCKER_BIN.",
                    action: "Install Dory shell integration or set DORY_DOCKER_BIN."
                ),
            ]
        }

        var checks = [
            HealthCheck(
                id: "docker.cli",
                status: .pass,
                code: "docker.cli_found",
                title: "Docker CLI found",
                detail: binary
            ),
        ]

        if skipServerProbe {
            checks.append(HealthCheck(
                id: "docker.version",
                status: .skip,
                code: "docker.version_sleeping",
                title: "Docker CLI server probe skipped",
                detail: "Docker tier is idle-sleeping; run `dory doctor --active` or any Docker command to wake it."
            ))
        } else {
            var dockerEnvironment = environment
            dockerEnvironment["DOCKER_HOST"] = "unix://\(socketPath)"
            let version = commandRunner.run(
                executablePath: binary,
                arguments: ["version", "--format", "{{json .Server}}"],
                environment: dockerEnvironment,
                timeout: 12
            )
            if let launchError = version.launchError {
                checks.append(HealthCheck(
                    id: "docker.version",
                    status: .fail,
                    code: "docker.version_exception",
                    title: "Docker CLI version failed",
                    detail: launchError
                ))
            } else if version.exitCode == 0 {
                checks.append(HealthCheck(
                    id: "docker.version",
                    status: .pass,
                    code: "docker.version_ok",
                    title: "Docker CLI can reach Dory",
                    detail: String(version.stdout.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
                ))
            } else {
                checks.append(HealthCheck(
                    id: "docker.version",
                    status: .fail,
                    code: "docker.version_failed",
                    title: "Docker CLI cannot reach Dory",
                    detail: compact(version.stderr.isEmpty ? version.stdout : version.stderr),
                    action: "Check DOCKER_HOST and the Dory Docker context."
                ))
            }
        }

        let compose = commandRunner.run(
            executablePath: binary,
            arguments: ["compose", "version"],
            environment: environment,
            timeout: 12
        )
        if compose.exitCode == 0 {
            checks.append(HealthCheck(
                id: "docker.compose",
                status: .pass,
                code: "docker.compose_ok",
                title: "Docker Compose plugin works",
                detail: compose.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        } else {
            checks.append(HealthCheck(
                id: "docker.compose",
                status: .warn,
                code: "docker.compose_missing",
                title: "Docker Compose plugin not available",
                detail: compact(compose.stderr.isEmpty ? compose.stdout : compose.stderr),
                action: "Install Dory shell integration so the bundled Compose plugin is on PATH."
            ))
        }

        return checks
    }

    private func dockerContextChecks() -> [HealthCheck] {
        guard let binary = dockerBinary() else {
            return [
                HealthCheck(
                    id: "docker.context",
                    status: .skip,
                    code: "docker.cli_missing",
                    title: "Docker context skipped",
                    detail: "Docker CLI is missing."
                ),
            ]
        }

        var checks: [HealthCheck] = []
        let expected = "unix://\(socketPath)"
        let dockerHost = environment["DOCKER_HOST"] ?? ""
        if !dockerHost.isEmpty, dockerHost != expected {
            checks.append(HealthCheck(
                id: "docker.host_env",
                status: .warn,
                code: "socket.docker_host_conflict",
                title: "DOCKER_HOST points away from Dory",
                detail: "DOCKER_HOST=\(dockerHost)",
                action: "Unset DOCKER_HOST or set it to \(expected)."
            ))
        } else if dockerHost == expected {
            checks.append(HealthCheck(
                id: "docker.host_env",
                status: .pass,
                code: "socket.docker_host_ok",
                title: "DOCKER_HOST points at Dory",
                detail: dockerHost
            ))
        } else {
            checks.append(HealthCheck(
                id: "docker.host_env",
                status: .pass,
                code: "socket.docker_host_unset",
                title: "DOCKER_HOST is not overriding context",
                detail: "unset"
            ))
        }

        let current = commandRunner.run(
            executablePath: binary,
            arguments: ["context", "show"],
            environment: environment,
            timeout: 8
        )
        if current.exitCode == 0 {
            let name = current.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let isDory = name == "dory"
            checks.append(HealthCheck(
                id: "docker.context.current",
                status: isDory ? .pass : .warn,
                code: isDory ? "context.active" : "context.not_active",
                title: "Active Docker context",
                detail: name.isEmpty ? "unknown" : name,
                action: isDory ? nil : "Run `dory repair context` to create and activate the Dory context."
            ))
        } else {
            checks.append(HealthCheck(
                id: "docker.context.current",
                status: .warn,
                code: "context.show_failed",
                title: "Could not read Docker context",
                detail: compact(current.stderr)
            ))
        }

        let inspect = commandRunner.run(
            executablePath: binary,
            arguments: ["context", "inspect", "dory", "--format", "{{json .Endpoints.docker.Host}}"],
            environment: environment,
            timeout: 8
        )
        if inspect.exitCode != 0 {
            checks.append(HealthCheck(
                id: "docker.context.dory",
                status: .warn,
                code: "context.missing",
                title: "Dory Docker context missing",
                detail: compact(inspect.stderr.isEmpty ? inspect.stdout : inspect.stderr),
                action: "Run `dory repair context`."
            ))
            return checks
        }

        let host = inspect.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        if host == expected {
            checks.append(HealthCheck(
                id: "docker.context.dory",
                status: .pass,
                code: "context.dory_ok",
                title: "Dory context targets this socket",
                detail: host
            ))
        } else {
            checks.append(HealthCheck(
                id: "docker.context.dory",
                status: .warn,
                code: "context.wrong_socket",
                title: "Dory context targets another socket",
                detail: host,
                action: "Run `dory repair context` to update it."
            ))
        }
        return checks
    }

    private func proxyCheck() -> HealthCheck {
        let hostProxyKeys = ["HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "https_proxy", "http_proxy", "all_proxy"]
        let hostHasProxy = hostProxyKeys.contains { !(environment[$0] ?? "").isEmpty }
        let containerHasProxy = dockerConfigProxyConfigured()
        let detail: String
        if hostHasProxy || containerHasProxy {
            var layers: [String] = []
            if hostHasProxy { layers.append("host env") }
            if containerHasProxy { layers.append("containers") }
            detail = "proxy set at: \(layers.joined(separator: ", "))"
        } else {
            detail = "no proxy configured at any layer"
        }

        if hostHasProxy && !containerHasProxy {
            return HealthCheck(
                id: "network.proxy",
                status: .warn,
                code: "network.proxy_not_propagated",
                title: "Host is behind a proxy that containers do not use",
                detail: detail + " - image pulls and container internet can fail with EOF/timeout behind a corporate proxy",
                action: "Add a proxies.default block (httpProxy/httpsProxy/noProxy) to ~/.docker/config.json so Docker injects the proxy into builds and containers."
            )
        }

        return HealthCheck(
            id: "network.proxy",
            status: .pass,
            code: "network.proxy_ok",
            title: "Proxy configuration consistent",
            detail: detail
        )
    }

    private func lanExposureCheck() -> HealthCheck {
        let lanVisible = configBool(path: ["network", "lanVisible"]) == true
        let count = dockerTier?.currentPublishedPorts()?.count ?? 0
        if lanVisible {
            return HealthCheck(
                id: "network.lan_exposure",
                status: .warn,
                code: "network.lan_exposed",
                title: "Published ports are LAN-visible",
                detail: "LAN visibility is ON - \(count) published port(s) reachable from your local network, not just this Mac",
                action: "Run `dory network --lan-visible off` (or Settings -> Network) to restrict published ports to localhost.",
                data: ["lan_visible": "true", "published_ports": String(count)]
            )
        }
        return HealthCheck(
            id: "network.lan_exposure",
            status: .pass,
            code: "network.lan_localhost_only",
            title: "Published ports are localhost-only",
            detail: "localhost-only - \(count) published port(s) reachable only from this Mac",
            data: ["lan_visible": "false", "published_ports": String(count)]
        )
    }

    private func registryChecks() -> [HealthCheck] {
        registryProbe.checks(host: "registry-1.docker.io", port: 443, name: "docker-hub", defaultProbe: true)
    }

    private func containerDNSSkipCheck() -> HealthCheck {
        HealthCheck(
            id: "network.container_dns",
            status: .skip,
            code: "network.active_probe_skipped",
            title: "Container DNS comparison skipped",
            detail: "Run `dory doctor --active` to compare host DNS with container DNS."
        )
    }

    private func publishedPortsCheck(dockerReachable: Bool) -> HealthCheck {
        if let ports = dockerTier?.currentPublishedPorts() {
            return HealthCheck(
                id: "network.published_ports",
                status: .pass,
                code: "network.port_table_ok",
                title: "Published port table readable",
                detail: "\(ports.count) published port route(s) found",
                data: ["ports": String(ports.count)]
            )
        }
        guard dockerReachable else {
            return HealthCheck(
                id: "network.published_ports",
                status: .fail,
                code: "network.port_table_unreadable",
                title: "Published port table could not be read",
                detail: "Docker API is not reachable.",
                action: "The Docker API did not return the container list; run `dory doctor` again once the engine is healthy."
            )
        }
        return HealthCheck(
            id: "network.published_ports",
            status: .pass,
            code: "network.port_table_ok",
            title: "Published port table readable",
            detail: "0 published port route(s) found",
            data: ["ports": "0"]
        )
    }

    private func domainTableCheck(dockerReachable: Bool) -> HealthCheck {
        let domainCount = dockerTier?.currentPublishedPorts()?.count ?? 0
        guard dockerReachable || dockerTier?.currentPublishedPorts() != nil else {
            return HealthCheck(
                id: "network.domain_table",
                status: .fail,
                code: "network.domain_table_unreadable",
                title: "Domain route table could not be read",
                detail: "Docker API is not reachable.",
                action: "The Docker API did not return the container list; run `dory doctor` again once the engine is healthy."
            )
        }
        return HealthCheck(
            id: "network.domain_table",
            status: .pass,
            code: "network.domain_table_ok",
            title: "Domain route table readable",
            detail: "\(domainCount) domain route(s) inferred from containers",
            data: ["domains": String(domainCount)]
        )
    }

    private func mountBasicSkipCheck() -> HealthCheck {
        HealthCheck(
            id: "mount.basic",
            status: .skip,
            code: "mount.active_probe_skipped",
            title: "Bind mount probe skipped",
            detail: "Run `dory doctor --active` to validate bind mount read/write/path-with-spaces behavior."
        )
    }

    private func mountLockSkipCheck() -> HealthCheck {
        HealthCheck(
            id: "mount.lock",
            status: .skip,
            code: "mount.active_probe_skipped",
            title: "File-lock probe skipped",
            detail: "Run `dory doctor --active` to verify exclusive lock behavior across processes."
        )
    }

    private func mountWatchSkipCheck() -> HealthCheck {
        HealthCheck(
            id: "mount.watch",
            status: .skip,
            code: "mount.active_probe_skipped",
            title: "Watch visibility probe skipped",
            detail: "Run `dory doctor --active` to validate host edits becoming visible inside a mounted container."
        )
    }

    private func vmClockSkipCheck() -> HealthCheck {
        HealthCheck(
            id: "vm.clock",
            status: .skip,
            code: "vm.active_probe_skipped",
            title: "VM clock probe skipped",
            detail: "Run `dory doctor --active` to compare guest and host clocks."
        )
    }

    private func diskChecks(dockerReachable: Bool) -> [HealthCheck] {
        let host = hostDiskCheck()
        let docker = dockerReachable
            ? HealthCheck(
                id: "disk.docker",
                status: .pass,
                code: "disk.docker_df_ok",
                title: "Docker disk usage readable",
                detail: "Docker API reachable",
                data: ["available": "true"]
            )
            : HealthCheck(
                id: "disk.docker",
                status: .warn,
                code: "disk.docker_df_unavailable",
                title: "Docker disk usage unavailable",
                detail: "Docker API is not reachable."
            )
        let state = doryStateDiskCheck()
        let guest = HealthCheck(
            id: "disk.guest",
            status: .skip,
            code: "disk.active_probe_skipped",
            title: "Guest disk probe skipped",
            detail: "Run `dory doctor --active` to measure free space inside the engine VM."
        )
        let logs = doryLogCapCheck()
        return [host, docker, state, guest, logs]
    }

    private func memoryCheck() -> HealthCheck {
        var data: [String: String] = [
            "physical_memory_bytes": String(ProcessInfo.processInfo.physicalMemory),
        ]
        if let pid = dockerTier?.status().hvPID {
            data["engine_pid"] = String(pid)
        }
        var usage = rusage()
        if getrusage(RUSAGE_SELF, &usage) == 0 {
            data["rss_bytes"] = String(Int64(usage.ru_maxrss) * 1024)
        }
        let rss = data["rss_bytes"].flatMap(Int64.init).map(formatBytes) ?? "unknown"
        return HealthCheck(
            id: "memory.footprint",
            status: .pass,
            code: "memory.footprint_ok",
            title: "Dory memory footprint",
            detail: "host RSS \(rss)",
            data: data
        )
    }

    private func helperResolverCheck() -> HealthCheck {
        let suffix = environment["DORY_DOMAIN_SUFFIX"] ?? environment["DORYD_DOMAIN_SUFFIX"] ?? "dory.local"
        let resolver = "/etc/resolver/\(suffix)"
        let exists = fileManager.fileExists(atPath: resolver)
        if exists {
            return HealthCheck(
                id: "helpers.resolver",
                status: .pass,
                code: "helpers.resolver_ok",
                title: "Local domain resolver file exists",
                detail: resolver,
                data: ["resolver": resolver, "resolver_exists": "true"]
            )
        }
        return HealthCheck(
            id: "helpers.resolver",
            status: .warn,
            code: "helpers.resolver_missing",
            title: "Local domain resolver file missing",
            detail: resolver,
            action: "Run `scripts/enable-networking.sh` if you want system-wide *.dory.local resolution.",
            data: ["resolver": resolver, "resolver_exists": "false"]
        )
    }

    private func engineCheck() -> HealthCheck {
        guard let dockerTier else {
            return HealthCheck(
                id: "engine.status",
                status: .skip,
                code: "engine.unconfigured",
                title: "Docker tier is not configured",
                detail: "doryd has no docker tier configuration"
            )
        }
        let status = dockerTier.status()
        switch status.state {
        case .running:
            return HealthCheck(
                id: "engine.status",
                status: .pass,
                code: "engine.running",
                title: "Docker tier is running",
                detail: "serving \(status.socketPath)",
                data: engineData(status)
            )
        case .sleeping:
            return HealthCheck(
                id: "engine.status",
                status: .pass,
                code: "engine.sleeping",
                title: "Docker tier is idle-sleeping",
                detail: "dory.sock remains bound and will wake the helper",
                data: engineData(status)
            )
        case .starting:
            return HealthCheck(
                id: "engine.status",
                status: .warn,
                code: "engine.starting",
                title: "Docker tier is starting",
                detail: "helper startup is in progress",
                data: engineData(status)
            )
        case .stopped:
            return HealthCheck(
                id: "engine.status",
                status: .warn,
                code: "engine.stopped",
                title: "Docker tier is stopped",
                detail: "engineStart is required before docker traffic can be served",
                action: "Call engineStart over XPC or set DORYD_AUTOSTART_DOCKER_TIER=1.",
                data: engineData(status)
            )
        case .failed:
            return HealthCheck(
                id: "engine.status",
                status: .fail,
                code: "engine.failed",
                title: "Docker tier failed",
                detail: status.lastError ?? "unknown docker-tier failure",
                action: "Inspect the dory-hv log and restart the engine.",
                data: engineData(status)
            )
        }
    }

    private func remoteChecks() -> [HealthCheck] {
        guard let remoteManager else { return [] }
        let statuses = remoteManager.list()
        if statuses.isEmpty {
            return [
                HealthCheck(
                    id: "remote.machines",
                    status: .skip,
                    code: "remote.none",
                    title: "No remote machines configured",
                    detail: "remoteConnect has not registered any remote machine"
                ),
            ]
        }
        return statuses.map { status in
            switch status.state {
            case .connected:
                return HealthCheck(
                    id: "remote.machine.\(status.id)",
                    status: .pass,
                    code: "remote.connected",
                    title: "Remote machine connected",
                    detail: status.info?.agentBuild ?? status.id
                )
            case .disconnected:
                return HealthCheck(
                    id: "remote.machine.\(status.id)",
                    status: .warn,
                    code: "remote.disconnected",
                    title: "Remote machine disconnected",
                    detail: status.id,
                    action: "Reconnect the remote machine before push or telemetry operations."
                )
            case .failed:
                return HealthCheck(
                    id: "remote.machine.\(status.id)",
                    status: .fail,
                    code: "remote.failed",
                    title: "Remote machine failed",
                    detail: status.lastError ?? status.id,
                    action: "Check SSH credentials, host-key policy, and the remote dory-agent."
                )
            }
        }
    }

    private func machineChecks() -> [HealthCheck] {
        guard let machineManager else { return [] }
        let statuses = machineManager.list()
        if statuses.isEmpty {
            return [
                HealthCheck(
                    id: "machine.local",
                    status: .skip,
                    code: "machine.none",
                    title: "No local machines configured",
                    detail: "No dory-vmm machines have been created"
                ),
            ]
        }

        let failed = statuses.filter { $0.state == .failed }
        let starting = statuses.filter { $0.state == .starting }
        let running = statuses.filter { $0.state == .running }
        let stopped = statuses.filter { $0.state == .stopped || $0.state == .created }
        let data = [
            "total": String(statuses.count),
            "running": String(running.count),
            "starting": String(starting.count),
            "stopped": String(stopped.count),
            "failed": String(failed.count),
        ]

        if !failed.isEmpty {
            return [
                HealthCheck(
                    id: "machine.local",
                    status: .fail,
                    code: "machine.failed",
                    title: "Local machine failed",
                    detail: failed.map { "\($0.id): \($0.lastError ?? "unknown failure")" }.joined(separator: "; "),
                    action: "Inspect the dory-vmm log for the failed machine.",
                    data: data
                ),
            ]
        }

        if !starting.isEmpty {
            return [
                HealthCheck(
                    id: "machine.local",
                    status: .warn,
                    code: "machine.starting",
                    title: "Local machine starting",
                    detail: starting.map(\.id).joined(separator: ", "),
                    data: data
                ),
            ]
        }

        return [
            HealthCheck(
                id: "machine.local",
                status: .pass,
                code: running.isEmpty ? "machine.configured" : "machine.running",
                title: running.isEmpty ? "Local machines configured" : "Local machine running",
                detail: statuses.map { "\($0.id)=\($0.state.rawValue)" }.joined(separator: ", "),
                data: data
            ),
        ]
    }

    private func engineData(_ status: DockerTierStatus) -> [String: String] {
        var data = [
            "state": status.state.rawValue,
            "socket": status.socketPath,
        ]
        if let hvPID = status.hvPID {
            data["hv_pid"] = String(hvPID)
        }
        return data
    }

    private func dockerBinary() -> String? {
        for candidate in dockerBinaryCandidates() where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    private func dockerBinaryCandidates() -> [String] {
        var candidates: [String] = []
        if let configured = environment["DORY_DOCKER_BIN"], !configured.isEmpty {
            candidates.append(configured)
        }
        candidates.append(URL(fileURLWithPath: home).appendingPathComponent(".dory/bin/docker").path)
        if let sibling = executableSibling(named: "docker") {
            candidates.append(sibling)
        }

        let searchPath = environment["PATH"] ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        for directory in searchPath.split(separator: ":").map(String.init) where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("docker").path
            candidates.append(candidate)
        }
        return candidates
    }

    private func executableSibling(named name: String) -> String? {
        guard let executable = CommandLine.arguments.first, !executable.isEmpty else {
            return nil
        }
        let executableURL = URL(fileURLWithPath: executable)
        guard executableURL.isFileURL else { return nil }
        return executableURL.deletingLastPathComponent().appendingPathComponent(name).path
    }

    private func dockerConfigProxyConfigured() -> Bool {
        let config = URL(fileURLWithPath: home).appendingPathComponent(".docker/config.json").path
        guard let dictionary = jsonDictionary(atPath: config),
              let proxies = dictionary["proxies"] as? [String: Any],
              let defaults = proxies["default"] as? [String: Any] else {
            return false
        }
        let keys = ["httpProxy", "httpsProxy", "noProxy"]
        return keys.contains { key in
            guard let value = defaults[key] as? String else { return false }
            return !value.isEmpty
        }
    }

    private func configBool(path: [String]) -> Bool? {
        let configPath = environment["DORY_CONFIG"] ?? "\(home)/.dory/config.json"
        guard let root = jsonDictionary(atPath: configPath) else { return nil }
        var current: Any = root
        for component in path {
            guard let dictionary = current as? [String: Any], let next = dictionary[component] else {
                return nil
            }
            current = next
        }
        return current as? Bool
    }

    private func jsonDictionary(atPath path: String) -> [String: Any]? {
        guard let data = fileManager.contents(atPath: path),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return value
    }

    private func hostDiskCheck() -> HealthCheck {
        let path = fileManager.fileExists(atPath: home) ? home : NSHomeDirectory()
        var stats = statfs()
        guard statfs(path, &stats) == 0 else {
            return HealthCheck(
                id: "disk.host",
                status: .warn,
                code: "disk.host_low",
                title: "Host disk space",
                detail: "could not inspect \(path): \(String(cString: strerror(errno)))",
                action: "Check host disk space before pulling or building images."
            )
        }
        let blockSize = UInt64(stats.f_bsize)
        let free = UInt64(stats.f_bavail) * blockSize
        let total = UInt64(stats.f_blocks) * blockSize
        let pctFree = total == 0 ? 0 : Double(free) / Double(total) * 100
        let status: HealthCheckStatus
        let code: String
        let action: String?
        if total > 0, pctFree < 5 {
            status = .fail
            code = "disk.host_critical"
            action = "Free host disk space before pulling or building images."
        } else if total > 0, pctFree < 15 {
            status = .warn
            code = "disk.host_low"
            action = "Consider pruning images/build cache or freeing host disk space."
        } else {
            status = .pass
            code = "disk.host_ok"
            action = nil
        }
        return HealthCheck(
            id: "disk.host",
            status: status,
            code: code,
            title: "Host disk space",
            detail: "\(formatBytes(Int64(free))) free of \(formatBytes(Int64(total)))",
            action: action,
            data: [
                "free_bytes": String(free),
                "total_bytes": String(total),
            ]
        )
    }

    private func doryStateDiskCheck() -> HealthCheck {
        let usage = doryStateUsage()
        let status: HealthCheckStatus = usage.logBytes > 100_000_000 ? .warn : .pass
        let code = status == .warn ? "disk.dory_logs_large" : "disk.dory_state_ok"
        return HealthCheck(
            id: "disk.dory_state",
            status: status,
            code: code,
            title: "Dory state disk usage estimated",
            detail: "state=\(formatBytes(Int64(usage.totalBytes))) logs=\(formatBytes(Int64(usage.logBytes))) vm=\(formatBytes(Int64(usage.vmDiskBytes)))",
            action: status == .warn ? "Run `dory cleanup --logs --apply` to trim old log data while preserving recent tails." : nil,
            data: [
                "total_bytes": String(usage.totalBytes),
                "log_bytes": String(usage.logBytes),
                "vm_disk_bytes": String(usage.vmDiskBytes),
            ]
        )
    }

    private func doryLogCapCheck() -> HealthCheck {
        let usage = doryStateUsage()
        let cap = Int64(environment["DORY_LOG_HARD_MAX_BYTES"] ?? "").flatMap(Int.init) ?? 64 * 1024 * 1024
        if usage.largestLogBytes > cap {
            return HealthCheck(
                id: "disk.dory_logs",
                status: .warn,
                code: "disk.dory_log_uncapped",
                title: "A Dory log exceeds the size cap",
                detail: "\(usage.largestLogPath ?? "a log") is \(formatBytes(Int64(usage.largestLogBytes))) (cap \(formatBytes(Int64(cap))))",
                action: "Run `dory cleanup --logs --apply`; automatic caps apply on the next engine start or while Auto-Idle runs.",
                data: [
                    "largest_log_path": usage.largestLogPath ?? "",
                    "largest_log_bytes": String(usage.largestLogBytes),
                ]
            )
        }
        return HealthCheck(
            id: "disk.dory_logs",
            status: .pass,
            code: "disk.dory_logs_capped",
            title: "Dory logs are within the size cap",
            detail: "largest \(formatBytes(Int64(usage.largestLogBytes))) of \(formatBytes(Int64(cap))) cap",
            data: [
                "largest_log_path": usage.largestLogPath ?? "",
                "largest_log_bytes": String(usage.largestLogBytes),
            ]
        )
    }

    private struct DoryStateUsage {
        var totalBytes: Int
        var logBytes: Int
        var vmDiskBytes: Int
        var largestLogPath: String?
        var largestLogBytes: Int
    }

    private func doryStateUsage() -> DoryStateUsage {
        let roots = [
            environment["DORYD_STATE_DIR"],
            "\(home)/.dory",
        ].compactMap { $0 }
        var seen = Set<String>()
        var total = 0
        var logs = 0
        var vm = 0
        var largestLogPath: String?
        var largestLogBytes = 0

        for root in roots where !seen.contains(root) {
            seen.insert(root)
            guard fileManager.fileExists(atPath: root),
                  let enumerator = fileManager.enumerator(atPath: root) else {
                continue
            }
            for case let relativePath as String in enumerator {
                let path = URL(fileURLWithPath: root).appendingPathComponent(relativePath).path
                guard let attrs = try? fileManager.attributesOfItem(atPath: path),
                      attrs[.type] as? FileAttributeType == .typeRegular,
                      let size = attrs[.size] as? NSNumber else {
                    continue
                }
                let bytes = size.intValue
                total += bytes
                let lower = relativePath.lowercased()
                if lower.hasSuffix(".log") {
                    logs += bytes
                    if bytes > largestLogBytes {
                        largestLogBytes = bytes
                        largestLogPath = path
                    }
                }
                if lower.contains("vm") || lower.hasSuffix(".img") || lower.hasSuffix(".qcow2") || lower.hasSuffix(".raw") {
                    vm += bytes
                }
            }
        }
        return DoryStateUsage(
            totalBytes: total,
            logBytes: logs,
            vmDiskBytes: vm,
            largestLogPath: largestLogPath,
            largestLogBytes: largestLogBytes
        )
    }
}

private func compact(_ value: String, limit: Int = 300) -> String {
    let normalized = value
        .replacingOccurrences(of: "\r", with: "\n")
        .split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    if normalized.count <= limit {
        return normalized
    }
    return String(normalized.prefix(limit))
}

private func formatBytes(_ bytes: Int64) -> String {
    let units = ["B", "KiB", "MiB", "GiB", "TiB"]
    var value = Double(max(0, bytes))
    var unit = 0
    while value >= 1024, unit < units.count - 1 {
        value /= 1024
        unit += 1
    }
    if unit == 0 {
        return "\(Int(value)) \(units[unit])"
    }
    return String(format: "%.1f %@", value, units[unit])
}
