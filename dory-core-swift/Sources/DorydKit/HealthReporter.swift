import Darwin
import DoryCore
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

struct DoryProcessMemoryUsage: Sendable, Equatable {
    var pid: Int32
    var residentSizeBytes: Int64
    var physicalFootprintBytes: Int64
}

struct DoryProcessMemorySnapshot: Sendable, Equatable {
    var usages: [DoryProcessMemoryUsage]
    var managedHelperTreePIDs: Set<Int32>
    var complete: Bool
    var errors: [String]
}

protocol DoryProcessMemorySampling: Sendable {
    func snapshot(daemonPID: Int32, managedHelperPID: Int32?) -> DoryProcessMemorySnapshot
}

/// Reads live memory charges from the kernel rather than a process lifetime high-water mark.
///
/// A Dory engine is a process tree: doryd owns dory-hv (or dory-vmm), which in turn owns helpers
/// such as gvproxy. Summing only doryd's `ru_maxrss` misses the VM's physical memory charge. Keep
/// the enumeration and every sample in one snapshot so callers can label a raced/partial result
/// honestly instead of presenting it as the whole engine.
struct DarwinDoryProcessMemorySampler: DoryProcessMemorySampling {
    private static let initialChildCapacity = 16
    private static let maximumChildCapacity = 4_096

    func snapshot(daemonPID: Int32, managedHelperPID: Int32?) -> DoryProcessMemorySnapshot {
        var processPIDs: Set<Int32> = [daemonPID]
        var helperTreePIDs: Set<Int32> = []
        var pending: [Int32] = [daemonPID]
        if let managedHelperPID, managedHelperPID > 0 {
            processPIDs.insert(managedHelperPID)
            helperTreePIDs.insert(managedHelperPID)
            pending.append(managedHelperPID)
        }

        var processed: Set<Int32> = []
        var errors: [String] = []
        var complete = true
        while let parentPID = pending.popLast() {
            guard processed.insert(parentPID).inserted else { continue }
            let children = directChildren(of: parentPID)
            if let error = children.error {
                complete = false
                errors.append("children of pid \(parentPID): \(error)")
            }
            if children.truncated {
                complete = false
                errors.append("children of pid \(parentPID): process list exceeded safety limit")
            }
            let parentIsInHelperTree = helperTreePIDs.contains(parentPID)
            for childPID in children.pids where childPID > 0 {
                if parentIsInHelperTree {
                    helperTreePIDs.insert(childPID)
                }
                if processPIDs.insert(childPID).inserted {
                    pending.append(childPID)
                }
            }
        }

        var usages: [DoryProcessMemoryUsage] = []
        for pid in processPIDs.sorted() {
            switch usage(of: pid) {
            case .success(let usage):
                usages.append(usage)
            case .failure(let error):
                complete = false
                errors.append("pid \(pid): \(error)")
            }
        }
        return DoryProcessMemorySnapshot(
            usages: usages,
            managedHelperTreePIDs: helperTreePIDs,
            complete: complete,
            errors: errors
        )
    }

    private func directChildren(of pid: Int32) -> (pids: [Int32], truncated: Bool, error: String?) {
        var capacity = Self.initialChildCapacity
        while true {
            var pids = [pid_t](repeating: 0, count: capacity)
            let count = pids.withUnsafeMutableBytes { buffer -> Int32 in
                proc_listchildpids(pid, buffer.baseAddress, Int32(buffer.count))
            }
            guard count >= 0 else {
                return ([], false, String(cString: strerror(errno)))
            }
            if count < capacity {
                return (Array(pids[0..<Int(count)]), false, nil)
            }
            guard capacity < Self.maximumChildCapacity else {
                return (Array(pids[0..<capacity]), true, nil)
            }
            capacity = min(capacity * 2, Self.maximumChildCapacity)
        }
    }

    private func usage(of pid: Int32) -> Result<DoryProcessMemoryUsage, ProcessMemorySampleError> {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        guard result == 0 else {
            return .failure(ProcessMemorySampleError(message: String(cString: strerror(errno))))
        }
        return .success(DoryProcessMemoryUsage(
            pid: pid,
            residentSizeBytes: Int64(clamping: info.ri_resident_size),
            physicalFootprintBytes: Int64(clamping: info.ri_phys_footprint)
        ))
    }
}

private struct ProcessMemorySampleError: Error {
    var message: String
}

extension ProcessMemorySampleError: CustomStringConvertible {
    var description: String { message }
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
    private let memorySampler: any DoryProcessMemorySampling

    public convenience init(
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
        self.init(
            socketPath: socketPath,
            dockerTier: dockerTier,
            machineManager: machineManager,
            remoteManager: remoteManager,
            dockerAPIProbe: dockerAPIProbe,
            commandRunner: commandRunner,
            registryProbe: registryProbe,
            environment: environment,
            home: home,
            fileManager: fileManager,
            memorySampler: DarwinDoryProcessMemorySampler()
        )
    }

    init(
        socketPath: String,
        dockerTier: DockerTier?,
        machineManager: MachineManager? = nil,
        remoteManager: RemoteMachineManager?,
        dockerAPIProbe: any DockerAPIProbing = UnixDockerAPIProbe(),
        commandRunner: any HealthCommandRunning = ProcessHealthCommandRunner(),
        registryProbe: any HealthRegistryProbing = URLSessionHealthRegistryProbe(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        memorySampler: any DoryProcessMemorySampling
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
        self.memorySampler = memorySampler
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
                    action: "doryd repairs Dory terminal integration automatically while it is running; restart Dory/doryd, or use `dory install` only as manual recovery."
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
                action: "doryd installs the bundled Compose plugin automatically while it is running; restart Dory/doryd, or use `dory install` only as manual recovery."
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
        let count = publishedPorts()?.count ?? 0
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
        if let ports = publishedPorts() {
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
        // A nil result means the container-list probe itself failed even though the
        // Docker API is reachable; that is a degraded state, not a genuinely empty
        // port table (which would return an empty array and pass above).
        return HealthCheck(
            id: "network.published_ports",
            status: .warn,
            code: "network.port_table_probe_failed",
            title: "Published port table could not be probed",
            detail: "The engine is reachable but did not return a container list.",
            action: "Run `dory doctor` again once the engine has settled."
        )
    }

    private func domainTableCheck(dockerReachable: Bool) -> HealthCheck {
        let ports = publishedPorts()
        guard dockerReachable || ports != nil else {
            return HealthCheck(
                id: "network.domain_table",
                status: .fail,
                code: "network.domain_table_unreadable",
                title: "Domain route table could not be read",
                detail: "Docker API is not reachable.",
                action: "The Docker API did not return the container list; run `dory doctor` again once the engine is healthy."
            )
        }
        guard let ports else {
            // Reachable engine but a nil probe result: distinguish this failed probe
            // from a genuinely empty container set (an empty array passes below).
            return HealthCheck(
                id: "network.domain_table",
                status: .warn,
                code: "network.domain_table_probe_failed",
                title: "Domain route table could not be probed",
                detail: "The engine is reachable but did not return a container list.",
                action: "Run `dory doctor` again once the engine has settled."
            )
        }
        return HealthCheck(
            id: "network.domain_table",
            status: .pass,
            code: "network.domain_table_ok",
            title: "Domain route table readable",
            detail: "\(ports.count) domain route(s) inferred from containers",
            data: ["domains": String(ports.count)]
        )
    }

    private func publishedPorts() -> [DoryListenPort]? {
        dockerTier?.currentDockerPublishedPorts() ?? dockerTier?.currentPublishedPorts()
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
        let dataDrive = doryDataDriveCheck()
        let docker: HealthCheck
        if !dockerReachable {
            docker = HealthCheck(
                id: "disk.docker",
                status: .warn,
                code: "disk.docker_df_unavailable",
                title: "Docker disk usage unavailable",
                detail: "Docker API is not reachable."
            )
        } else {
            switch dockerAPIProbe.systemDF(socketPath: socketPath) {
            case .ok:
                docker = HealthCheck(
                    id: "disk.docker",
                    status: .pass,
                    code: "disk.docker_df_ok",
                    title: "Docker disk usage readable",
                    detail: "Docker API returned its disk usage inventory.",
                    data: ["available": "true"]
                )
            case let .badResponse(statusCode, body):
                let summary = String(body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
                let missingSnapshot = dockerStorageSnapshotMissing(body)
                docker = HealthCheck(
                    id: "disk.docker",
                    status: .fail,
                    code: missingSnapshot ? "disk.docker_snapshot_missing" : "disk.docker_df_failed",
                    title: missingSnapshot ? "Docker storage metadata is inconsistent" : "Docker disk usage failed",
                    detail: "HTTP \(statusCode): \(summary)",
                    action: missingSnapshot
                        ? "Create a support bundle, then run `dory cleanup --json` to review the unusable container records before applying cleanup."
                        : "Create a support bundle and inspect the Docker daemon log before retrying.",
                    data: ["available": "false"]
                )
            case let .unreachable(detail):
                docker = HealthCheck(
                    id: "disk.docker",
                    status: .fail,
                    code: "disk.docker_df_unreachable",
                    title: "Docker disk usage probe became unreachable",
                    detail: detail,
                    action: "Retry the check; if it persists, create a support bundle and restart the engine.",
                    data: ["available": "false"]
                )
            }
        }
        let state = doryStateDiskCheck()
        let guest = HealthCheck(
            id: "disk.guest",
            status: .skip,
            code: "disk.active_probe_skipped",
            title: "Guest disk probe skipped",
            detail: "Run `dory doctor --active` to measure free space inside the engine VM."
        )
        let logs = doryLogCapCheck()
        return [host, dataDrive, docker, state, guest, logs]
    }

    private func dockerStorageSnapshotMissing(_ body: String) -> Bool {
        let lowercased = body.lowercased()
        return lowercased.contains("snapshot")
            && (lowercased.contains("not found") || lowercased.contains("missing"))
    }

    private func memoryCheck() -> HealthCheck {
        let daemonPID = getpid()
        let managedHelperPID = dockerTier?.status().hvPID
        var data: [String: String] = [
            "physical_memory_bytes": String(ProcessInfo.processInfo.physicalMemory),
            "daemon_pid": String(daemonPID),
        ]
        if let pid = managedHelperPID {
            data["engine_pid"] = String(pid)
        }

        let snapshot = memorySampler.snapshot(
            daemonPID: daemonPID,
            managedHelperPID: managedHelperPID
        )
        data["phys_footprint_source"] = "proc_pid_rusage.RUSAGE_INFO_V4"
        data["phys_footprint_aggregation"] = "sum_of_per_process_charges_may_double_count_shared_pages"
        data["process_set_complete"] = snapshot.complete ? "true" : "false"
        data["process_count"] = String(snapshot.usages.count)
        data["process_pids"] = snapshot.usages.map(\.pid).sorted().map(String.init).joined(separator: ",")
        if !snapshot.errors.isEmpty {
            data["sampling_errors"] = snapshot.errors.joined(separator: "; ")
        }

        if !snapshot.usages.isEmpty {
            let footprint = saturatingSum(snapshot.usages.map(\.physicalFootprintBytes))
            let resident = saturatingSum(snapshot.usages.map(\.residentSizeBytes))
            let daemonFootprint = snapshot.usages
                .first { $0.pid == daemonPID }?.physicalFootprintBytes ?? 0
            let helperTreeFootprint = saturatingSum(snapshot.usages.compactMap { usage in
                snapshot.managedHelperTreePIDs.contains(usage.pid) ? usage.physicalFootprintBytes : nil
            })
            let otherDescendantFootprint = saturatingSum(snapshot.usages.compactMap { usage in
                usage.pid != daemonPID && !snapshot.managedHelperTreePIDs.contains(usage.pid)
                    ? usage.physicalFootprintBytes
                    : nil
            })

            data["physical_footprint_available"] = "true"
            data["phys_footprint_bytes"] = String(footprint)
            data["phys_footprint_scope"] = snapshot.complete
                ? "dory_process_set"
                : "partial_dory_process_set"
            data["daemon_phys_footprint_bytes"] = String(daemonFootprint)
            data["managed_helper_tree_phys_footprint_bytes"] = String(helperTreeFootprint)
            data["other_descendant_phys_footprint_bytes"] = String(otherDescendantFootprint)
            // Retain the legacy key, but make its live aggregate scope and meaning explicit.
            data["rss_bytes"] = String(resident)
            data["rss_kind"] = "current_resident_size"
            data["rss_scope"] = snapshot.complete
                ? "dory_process_set"
                : "partial_dory_process_set"

            if snapshot.complete {
                return HealthCheck(
                    id: "memory.footprint",
                    status: .pass,
                    code: "memory.footprint_ok",
                    title: "Dory memory footprint",
                    detail: "summed physical footprint \(formatBytes(footprint)) across \(snapshot.usages.count) Dory process(es) (shared pages may be counted more than once); current resident set \(formatBytes(resident))",
                    data: data
                )
            }

            return HealthCheck(
                id: "memory.footprint",
                status: .warn,
                code: "memory.footprint_partial",
                title: "Dory memory footprint",
                detail: "at least \(formatBytes(footprint)) summed physical footprint across \(snapshot.usages.count) sampled Dory process(es) (shared pages may be counted more than once); process-set sampling was incomplete",
                action: "Run the health check again; if sampling remains partial, inspect whether an engine helper is repeatedly exiting.",
                data: data
            )
        }

        data["physical_footprint_available"] = "false"
        var usage = rusage()
        if getrusage(RUSAGE_SELF, &usage) == 0 {
            data["rss_bytes"] = String(Int64(usage.ru_maxrss))
            data["rss_kind"] = "peak_resident_size"
            data["rss_scope"] = "daemon_self"
            data["rss_source"] = "getrusage.RUSAGE_SELF.ru_maxrss"
        }
        let rss = data["rss_bytes"].flatMap(Int64.init).map(formatBytes) ?? "unknown"
        return HealthCheck(
            id: "memory.footprint",
            status: .warn,
            code: "memory.footprint_unavailable",
            title: "Dory memory footprint",
            detail: "physical footprint unavailable; daemon-only peak RSS fallback \(rss)",
            action: "Run the health check again; this fallback does not include the VM or its helper processes.",
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
                action: "Start the engine, or set runtime mode to always-on so doryd starts it on launch.",
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

    private func doryDataDriveCheck() -> HealthCheck {
        let configuredRoot = environment["DORYD_DATA_DRIVE"] ?? environment["DORY_DATA_DRIVE"]
        do {
            let selectionStore = try DoryDataDriveSelectionStore(home: home)
            let selectedDrive = try selectionStore.inspectSelection(
                requestedRoot: configuredRoot,
                fileManager: fileManager
            )
            let drive: DoryDataDrive
            if let selectedDrive {
                drive = selectedDrive
            } else {
                drive = try DoryDataDrive(home: home, overrideRoot: configuredRoot)
            }
            switch try drive.inspect(fileManager: fileManager) {
            case .absent:
                return HealthCheck(
                    id: "disk.dory_drive",
                    status: .warn,
                    code: "disk.dory_drive_not_initialized",
                    title: "Dory data drive is not initialized",
                    detail: drive.root,
                    action: "Start Dory once to create its managed workload drive.",
                    data: ["path": drive.root, "available": "false"]
                )
            case .ready:
                guard selectedDrive != nil else {
                    throw DoryDataDriveSelectionError.unselectedExistingDrive(drive.root)
                }
                let manifest = try drive.readManifest(fileManager: fileManager)
                let allocated = allocatedDirectoryBytes(at: drive.root)
                var diskStatus = stat()
                let hasDiskStatus = stat(drive.engineDataDiskPath, &diskStatus) == 0
                let diskLogical = hasDiskStatus ? max(0, Int64(diskStatus.st_size)) : 0
                let diskAllocated = hasDiskStatus ? max(0, Int64(diskStatus.st_blocks)) * 512 : 0
                var stats = statfs()
                let hasFilesystemStats = statfs(drive.root, &stats) == 0
                let free = hasFilesystemStats ? UInt64(stats.f_bavail) * UInt64(stats.f_bsize) : 0
                let total = hasFilesystemStats ? UInt64(stats.f_blocks) * UInt64(stats.f_bsize) : 0
                let filesystem = hasFilesystemStats
                    ? withUnsafePointer(to: &stats.f_fstypename) {
                        $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSNAMELEN)) {
                            String(cString: $0)
                        }
                    }
                    : "unknown"
                var data = [
                    "path": drive.root,
                    "drive_id": manifest.id.uuidString.lowercased(),
                    "schema_version": String(manifest.schemaVersion),
                    "created_at": manifest.createdAt,
                    "available": "true",
                    "allocated_bytes": String(allocated),
                    "engine_disk_logical_bytes": String(diskLogical),
                    "engine_disk_allocated_bytes": String(diskAllocated),
                    "free_bytes": String(free),
                    "total_bytes": String(total),
                    "filesystem": filesystem,
                    "manifest": drive.manifestPath,
                ]
                if let volume = manifest.volume {
                    data["volume_uuid"] = volume.uuid.uuidString.lowercased()
                    data["volume_name_at_creation"] = volume.nameAtCreation
                }
                return HealthCheck(
                    id: "disk.dory_drive",
                    status: .pass,
                    code: "disk.dory_drive_ok",
                    title: "Dory data drive is ready",
                    detail: "\(drive.root) — \(formatBytes(Int64(allocated))) physically allocated",
                    data: data
                )
            }
        } catch {
            if let selectionError = error as? DoryDataDriveSelectionError,
               case let .unselectedExistingDrive(path) = selectionError {
                return HealthCheck(
                    id: "disk.dory_drive",
                    status: .fail,
                    code: "disk.dory_drive_unselected",
                    title: "Dory data drive needs explicit selection",
                    detail: selectionError.description,
                    action: "After confirming this is the drive you want, run `dory data use \"\(path)\"`.",
                    data: ["path": path, "available": "false"]
                )
            }
            let rememberedRoot = try? DoryDataDriveSelectionStore(home: home)
                .selectedPath(fileManager: fileManager)
            let path = (try? DoryDataDrive(
                home: home,
                overrideRoot: configuredRoot ?? rememberedRoot
            ).root) ?? "invalid data-drive path"
            return HealthCheck(
                id: "disk.dory_drive",
                status: .fail,
                code: error is DoryDataDriveError || error is DoryDataDriveSelectionError
                    ? "disk.dory_drive_unavailable"
                    : "disk.dory_drive_failed",
                title: "Dory data drive is unavailable",
                detail: String(describing: error),
                action: "Reconnect the configured drive or restore a valid Dory.dorydrive bundle before starting the engine.",
                data: ["path": path, "available": "false"]
            )
        }
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
                var fileStatus = stat()
                let allocatedBytes = stat(path, &fileStatus) == 0
                    ? max(0, Int(fileStatus.st_blocks) * 512)
                    : bytes
                total += allocatedBytes
                let lower = relativePath.lowercased()
                if lower.hasSuffix(".log") {
                    logs += bytes
                    if bytes > largestLogBytes {
                        largestLogBytes = bytes
                        largestLogPath = path
                    }
                }
                if lower.contains("vm") || lower.hasSuffix(".img") || lower.hasSuffix(".qcow2")
                    || lower.hasSuffix(".raw") || lower.hasSuffix(".ext4") || lower.hasSuffix(".vhd")
                    || lower.hasSuffix(".vhdx") {
                    vm += allocatedBytes
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

    private func allocatedDirectoryBytes(at root: String) -> UInt64 {
        guard fileManager.fileExists(atPath: root),
              let enumerator = fileManager.enumerator(atPath: root) else {
            return 0
        }
        var total: UInt64 = 0
        for case let relativePath as String in enumerator {
            let path = URL(fileURLWithPath: root).appendingPathComponent(relativePath).path
            var fileStatus = stat()
            guard lstat(path, &fileStatus) == 0, (fileStatus.st_mode & S_IFMT) == S_IFREG else {
                continue
            }
            let blocks = max(Int64(0), Int64(fileStatus.st_blocks))
            let bytes = UInt64(blocks).multipliedReportingOverflow(by: 512)
            if bytes.overflow || UInt64.max - total < bytes.partialValue {
                return UInt64.max
            }
            total += bytes.partialValue
        }
        return total
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

private func saturatingSum(_ values: [Int64]) -> Int64 {
    values.reduce(0) { total, value in
        let (sum, overflow) = total.addingReportingOverflow(value)
        return overflow ? Int64.max : sum
    }
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
