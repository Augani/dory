@preconcurrency import Foundation

@objc(DorydHealthControl)
nonisolated protocol DorydControlXPC {
    func protocolVersion(reply: @escaping (UInt32) -> Void)
    func dorySocketPath(reply: @escaping (String) -> Void)
    func engineStatus(reply: @escaping (String, String) -> Void)
    func engineStart(reply: @escaping (Bool, String) -> Void)
    func engineStop(reply: @escaping (Bool, String) -> Void)
    func engineSleep(reply: @escaping (Bool, String) -> Void)
    func engineWake(reply: @escaping (Bool, String) -> Void)
    func dockerAgentInfo(reply: @escaping (NSDictionary, String) -> Void)
    func dockerAgentPorts(reply: @escaping (NSDictionary, String) -> Void)
    func dockerAgentTelemetry(reply: @escaping (NSDictionary, String) -> Void)
    func machineCreate(_ config: NSDictionary, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineStart(_ machineID: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineStop(_ machineID: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineUpdate(_ machineID: String, config: NSDictionary, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineDelete(_ machineID: String, reply: @escaping (Bool, String) -> Void)
    func machineList(reply: @escaping (NSArray, String) -> Void)
    func machineStats(_ machineID: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineExec(_ machineID: String, request: NSDictionary, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineProvision(_ machineID: String, request: NSDictionary, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineSnapshot(_ machineID: String, request: NSDictionary, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineSnapshots(_ machineID: String, reply: @escaping (NSArray, String) -> Void)
    func machineCloneSnapshot(_ machineID: String, snapshotID: String, newID: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineRestoreSnapshot(_ machineID: String, snapshotID: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineDeleteSnapshot(_ machineID: String, snapshotID: String, reply: @escaping (Bool, String) -> Void)
    func machineExportSnapshot(_ machineID: String, snapshotID: String, path: String, reply: @escaping (Bool, String) -> Void)
    func machineImportSnapshot(_ path: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func remoteConnect(_ config: NSDictionary, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func remotePush(_ machineID: String, localRoot: String, remoteRoot: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func remoteStatus(_ machineID: String, reply: @escaping (NSDictionary, String) -> Void)
    func networkReplaceRoutes(_ routes: NSArray, reply: @escaping (Bool, String) -> Void)
    func networkStatus(reply: @escaping (NSDictionary, String) -> Void)
    func networkAuthorizationPlan(reply: @escaping (NSDictionary, String) -> Void)
    func repairSubsystem(_ target: String, reply: @escaping (Bool, String) -> Void)
    func balloonStatus(reply: @escaping (NSDictionary, String) -> Void)
    func balloonReconcile(reply: @escaping (NSDictionary, String) -> Void)
    func idleStatus(reply: @escaping (NSDictionary, String) -> Void)
    func idleHistory(_ limit: Int, reply: @escaping (NSArray, String) -> Void)
    func idleSetMode(_ mode: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func idleSetPolicy(_ key: String, value: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func health(reply: @escaping (NSDictionary, String) -> Void)
    func doctorJSON(reply: @escaping (String, String) -> Void)
    func incidents(_ limit: Int, reply: @escaping (NSArray, String) -> Void)
}

nonisolated struct DorydEngineStatus: Sendable, Equatable {
    var state: String
    var detail: String

    var isRunning: Bool { state == "running" }
}

nonisolated struct DorydCommandResult: Sendable, Equatable {
    var ok: Bool
    var message: String
}

nonisolated struct DorydMachineShareConfiguration: Sendable, Equatable {
    var tag: String
    var hostPath: String
    var guestPath: String
    var readOnly: Bool

    var xpcDictionary: NSDictionary {
        [
            "tag": tag,
            "hostPath": hostPath,
            "guestPath": guestPath,
            "readOnly": readOnly,
        ]
    }
}

nonisolated struct DorydMachineConfiguration: Sendable, Equatable {
    var id: String
    var kernelPath: String
    var rootfsPath: String
    var memoryMB: UInt64
    var cpuCount: Int
    var address: String? = nil
    var displayMode: MachineDisplayMode = .headless
    var shares: [DorydMachineShareConfiguration] = []
    var environment: [String: String] = [:]

    var xpcDictionary: NSDictionary {
        var dictionary: [String: Any] = [
            "id": id,
            "kernelPath": kernelPath,
            "rootfsPath": rootfsPath,
            "memoryMB": memoryMB,
            "cpuCount": cpuCount,
            "displayMode": displayMode.rawValue,
        ]
        if let address {
            dictionary["address"] = address
        }
        if !shares.isEmpty {
            dictionary["shares"] = shares.map(\.xpcDictionary)
        }
        if !environment.isEmpty {
            dictionary["env"] = environment.sorted(by: { $0.key < $1.key }).map { key, value in
                [
                    "key": key,
                    "value": value,
                ] as NSDictionary
            }
        }
        return dictionary as NSDictionary
    }
}

nonisolated struct DorydMachineStatus: Sendable, Equatable {
    var id: String
    var state: String
    var pid: Int32?
    var lastError: String?
    var handoffSocketPath: String?
    var agentBuild: String?
    var agentSocketPath: String?
    var dockerdSocketPath: String?
    var shellSocketPath: String?
    var controlSocketPath: String? = nil
    var address: String? = nil
    var configuredAddress: String? = nil
    var runtimeAddress: String? = nil
    var handoffFDCount: Int
    var memoryMB: UInt64?
    var currentBalloonTargetMB: UInt64? = nil
    var cpuCount: Int?
    var displayMode: MachineDisplayMode = .headless
    var shares: [DorydMachineShareConfiguration] = []
    var environment: [String: String] = [:]
}

nonisolated struct DorydMachineExecResult: Sendable, Equatable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
    var timedOut: Bool
    var stdoutTruncated: Bool
    var stderrTruncated: Bool
}

nonisolated struct DorydMachineStats: Sendable, Equatable {
    var cpuPercent: Double
    var memoryUsedBytes: UInt64
    var memoryTotalBytes: UInt64
    var networkReceiveBytes: UInt64
    var networkTransmitBytes: UInt64
    var blockReadBytes: UInt64
    var blockWriteBytes: UInt64
    var processCount: UInt64
    var uptimeSeconds: Double
}

nonisolated struct DorydMachineProvisionResult: Sendable, Equatable {
    var recipeID: String
    var install: DorydMachineExecResult
    var verify: DorydMachineExecResult
}

nonisolated struct DorydMachineSnapshot: Sendable, Equatable {
    var id: String
    var machineID: String
    var note: String
    var createdISO: String
    var rootfsPath: String
    var sizeBytes: Int64
    var kernelPath: String
    var architecture: String
    var memoryMB: UInt64
    var cpuCount: Int
}

nonisolated struct DorydRemoteMachineConfiguration: Sendable, Equatable {
    var id: String
    var host: String
    var port: UInt16
    var user: String
    var privateKeyID: String
    var hostKeyType: String
    var hostKey: String?
    var knownHostsPath: String?
    var knownHostsHost: String?
    var knownHostsPort: UInt16?
    var endpointType: String
    var endpointPath: String?
    var endpointHost: String?
    var endpointPort: UInt16?
    var remoteRoot: String
    var build: String

    var xpcDictionary: NSDictionary {
        var dictionary: [String: Any] = [
            "id": id,
            "host": host,
            "port": port,
            "user": user,
            "privateKeyID": privateKeyID,
            "hostKeyType": hostKeyType,
            "endpointType": endpointType,
            "remoteRoot": remoteRoot,
            "build": build,
        ]
        if let hostKey { dictionary["hostKey"] = hostKey }
        if let knownHostsPath { dictionary["knownHostsPath"] = knownHostsPath }
        if let knownHostsHost { dictionary["knownHostsHost"] = knownHostsHost }
        if let knownHostsPort { dictionary["knownHostsPort"] = knownHostsPort }
        if let endpointPath { dictionary["endpointPath"] = endpointPath }
        if let endpointHost { dictionary["endpointHost"] = endpointHost }
        if let endpointPort { dictionary["endpointPort"] = endpointPort }
        return dictionary as NSDictionary
    }
}

nonisolated struct DorydAgentInfo: Sendable, Equatable {
    var protocolVersion: UInt32
    var kernel: String
    var agentBuild: String
    var uptimeSeconds: UInt64
}

nonisolated struct DorydTelemetry: Sendable, Equatable {
    var memTotalKB: UInt64
    var memAvailableKB: UInt64
    var psiSomeAvg10: Double
    var psiFullAvg10: Double
}

nonisolated struct DorydListenPort: Sendable, Equatable, Hashable {
    var `protocol`: String
    var port: UInt32
}

nonisolated struct DorydDockerAgentPorts: Sendable, Equatable {
    var ports: [DorydListenPort]
    var added: [DorydListenPort]
    var removed: [DorydListenPort]
}

nonisolated struct DorydPushStats: Sendable, Equatable {
    var filesSent: UInt64
    var bytesSent: UInt64
    var filesDeleted: UInt64
}

nonisolated struct DorydRemoteMachineStatus: Sendable, Equatable {
    var id: String
    var state: String
    var lastError: String?
    var info: DorydAgentInfo?
    var telemetry: DorydTelemetry?
}

nonisolated struct DorydDomainRoute: Sendable, Equatable {
    var hostname: String
    var address: String
    var port: UInt16 = 80
    var pathPrefix: String = ""

    var xpcDictionary: NSDictionary {
        var dictionary: [String: Any] = [
            "hostname": hostname,
            "address": address,
            "port": port,
        ]
        if !pathPrefix.isEmpty {
            dictionary["pathPrefix"] = pathPrefix
        }
        return dictionary as NSDictionary
    }
}

nonisolated struct DorydNetworkingStatus: Sendable, Equatable {
    var mode: String
    var suffix: String
    var dnsBindAddress: String
    var dnsPort: UInt16
    var dnsRunning: Bool
    var httpProxyPort: UInt16?
    var httpProxyRunning: Bool
    var httpsProxyPort: UInt16?
    var httpsProxyRunning: Bool
    var routes: [DorydDomainRoute]
}

nonisolated struct DorydNetworkingAuthorizationRequest: Sendable, Equatable, Codable {
    var id: String
    var kind: String
    var title: String
    var reason: String
    var requiresAdmin: Bool
    var filePath: String?
    var fileContents: String?
    var command: [String]
}

nonisolated struct DorydPrivilegedTCPForward: Sendable, Equatable, Codable {
    var listenPort: UInt16
    var targetPort: UInt16
}

nonisolated struct DorydNetworkingAuthorizationPlan: Sendable, Equatable, Codable {
    private enum CodingKeys: String, CodingKey {
        case degradedMode
        case authorizedMode
        case suffix
        case dnsBindAddress
        case dnsPort
        case httpProxyPort
        case httpsProxyPort
        case privilegedTCPForwards
        case requests
    }

    var degradedMode: String
    var authorizedMode: String
    var suffix: String
    var dnsBindAddress: String
    var dnsPort: UInt16
    var httpProxyPort: UInt16
    var httpsProxyPort: UInt16
    var privilegedTCPForwards: [DorydPrivilegedTCPForward] = []
    var requests: [DorydNetworkingAuthorizationRequest]

    init(
        degradedMode: String,
        authorizedMode: String,
        suffix: String,
        dnsBindAddress: String,
        dnsPort: UInt16,
        httpProxyPort: UInt16,
        httpsProxyPort: UInt16,
        privilegedTCPForwards: [DorydPrivilegedTCPForward] = [],
        requests: [DorydNetworkingAuthorizationRequest]
    ) {
        self.degradedMode = degradedMode
        self.authorizedMode = authorizedMode
        self.suffix = suffix
        self.dnsBindAddress = dnsBindAddress
        self.dnsPort = dnsPort
        self.httpProxyPort = httpProxyPort
        self.httpsProxyPort = httpsProxyPort
        self.privilegedTCPForwards = privilegedTCPForwards
        self.requests = requests
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.degradedMode = try container.decode(String.self, forKey: .degradedMode)
        self.authorizedMode = try container.decode(String.self, forKey: .authorizedMode)
        self.suffix = try container.decode(String.self, forKey: .suffix)
        self.dnsBindAddress = try container.decode(String.self, forKey: .dnsBindAddress)
        self.dnsPort = try container.decode(UInt16.self, forKey: .dnsPort)
        self.httpProxyPort = try container.decode(UInt16.self, forKey: .httpProxyPort)
        self.httpsProxyPort = try container.decode(UInt16.self, forKey: .httpsProxyPort)
        self.privilegedTCPForwards = try container.decodeIfPresent(
            [DorydPrivilegedTCPForward].self,
            forKey: .privilegedTCPForwards
        ) ?? []
        self.requests = try container.decode([DorydNetworkingAuthorizationRequest].self, forKey: .requests)
    }
}

nonisolated struct DorydHostMemorySnapshot: Sendable, Equatable {
    var totalBytes: UInt64
    var availableBytes: UInt64
    var freeBytes: UInt64
    var availableRatio: Double
    var pressure: String
}

nonisolated struct DorydBalloonTarget: Sendable, Equatable {
    var id: String
    var kind: String
    var currentTargetMB: UInt64
    var targetMB: UInt64
    var reason: String
    var canApply: Bool
}

nonisolated struct DorydBalloonPlan: Sendable, Equatable {
    var host: DorydHostMemorySnapshot
    var targets: [DorydBalloonTarget]
    var applicableTargets: [DorydBalloonTarget]
}

enum DorydClientError: Error, Sendable, CustomStringConvertible {
    case connectionUnavailable
    case invalidProxy
    case daemon(String)
    case timedOut

    var description: String {
        switch self {
        case .connectionUnavailable:
            return "doryd connection is unavailable"
        case .invalidProxy:
            return "doryd XPC proxy has an unexpected type"
        case let .daemon(message):
            return message.isEmpty ? "doryd returned an error" : message
        case .timedOut:
            return "doryd request timed out"
        }
    }
}

nonisolated final class DorydClient: @unchecked Sendable {
    // The daemon owns a 240-second promotion deadline. Leave enough client-side margin for the
    // daemon to return its exact outcome instead of replacing it with a simultaneous UI timeout.
    private static let engineColdStartTimeout: TimeInterval = 250
    // doryd gives dockerd and dory-hv up to 30 seconds to quiesce before its final fallback.
    // Keep the UI connection alive past that bound so a safe stop is not reported as a timeout.
    private static let engineShutdownTimeout: TimeInterval = 45

    private enum Target {
        case machService(String)
        case endpoint(NSXPCListenerEndpoint)
    }

    private let target: Target
    private let timeout: TimeInterval

    init(
        machServiceName: String = ProcessInfo.processInfo.environment["DORYD_MACH_SERVICE"] ?? "dev.dory.doryd",
        timeout: TimeInterval = 2
    ) {
        self.target = .machService(machServiceName)
        self.timeout = timeout
    }

    init(endpoint: NSXPCListenerEndpoint, timeout: TimeInterval = 2) {
        self.target = .endpoint(endpoint)
        self.timeout = timeout
    }

    var usesMachService: Bool {
        if case .machService = target { return true }
        return false
    }

    private func withTimeout(atLeast minimumTimeout: TimeInterval) -> DorydClient {
        let effectiveTimeout = max(timeout, minimumTimeout)
        switch target {
        case let .machService(name):
            return DorydClient(machServiceName: name, timeout: effectiveTimeout)
        case let .endpoint(endpoint):
            return DorydClient(endpoint: endpoint, timeout: effectiveTimeout)
        }
    }

    func doctorJSON() async throws -> String {
        try await call { proxy, finish in
            proxy.doctorJSON { json, error in
                if error.isEmpty {
                    finish(.success(json))
                } else {
                    finish(.failure(DorydClientError.daemon(error)))
                }
            }
        }
    }

    func healthJSON() async throws -> String {
        try await call { proxy, finish in
            proxy.health { body, error in
                if !error.isEmpty {
                    finish(.failure(DorydClientError.daemon(error)))
                    return
                }
                do {
                    let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
                    finish(.success(String(decoding: data, as: UTF8.self)))
                } catch {
                    finish(.failure(error))
                }
            }
        }
    }

    func protocolVersion() async throws -> UInt32 {
        try await call { proxy, finish in
            proxy.protocolVersion { version in
                finish(.success(version))
            }
        }
    }

    func dorySocketPath() async throws -> String {
        try await call { proxy, finish in
            proxy.dorySocketPath { path in
                finish(.success(path))
            }
        }
    }

    func engineStatus() async throws -> DorydEngineStatus {
        try await call { proxy, finish in
            proxy.engineStatus { state, detail in
                finish(.success(DorydEngineStatus(state: state, detail: detail)))
            }
        }
    }

    func engineStart() async throws -> DorydCommandResult {
        try await withTimeout(atLeast: Self.engineColdStartTimeout).command { proxy, reply in
            proxy.engineStart(reply: reply)
        }
    }

    func engineStop() async throws -> DorydCommandResult {
        try await withTimeout(atLeast: Self.engineShutdownTimeout).command { proxy, reply in
            proxy.engineStop(reply: reply)
        }
    }

    func engineSleep() async throws -> DorydCommandResult {
        try await withTimeout(atLeast: Self.engineShutdownTimeout).command { proxy, reply in
            proxy.engineSleep(reply: reply)
        }
    }

    func engineWake() async throws -> DorydCommandResult {
        try await withTimeout(atLeast: Self.engineColdStartTimeout).command { proxy, reply in
            proxy.engineWake(reply: reply)
        }
    }

    func dockerAgentInfo() async throws -> DorydAgentInfo {
        try await dictionaryCall { proxy, reply in
            proxy.dockerAgentInfo(reply: reply)
        } decode: {
            Self.agentInfo(from: $0)
        }
    }

    func dockerAgentPorts() async throws -> DorydDockerAgentPorts {
        try await dictionaryCall { proxy, reply in
            proxy.dockerAgentPorts(reply: reply)
        } decode: {
            Self.dockerAgentPorts(from: $0)
        }
    }

    func dockerAgentTelemetry() async throws -> DorydTelemetry {
        try await dictionaryCall { proxy, reply in
            proxy.dockerAgentTelemetry(reply: reply)
        } decode: {
            Self.telemetry(from: $0)
        }
    }

    func machineCreate(_ config: DorydMachineConfiguration) async throws -> DorydMachineStatus {
        try await withTimeout(atLeast: 60).statusCommand { proxy, reply in
            proxy.machineCreate(config.xpcDictionary, reply: reply)
        } decode: {
            Self.machineStatus(from: $0)
        }
    }

    func machineStart(_ machineID: String) async throws -> DorydMachineStatus {
        try await withTimeout(atLeast: 120).statusCommand { proxy, reply in
            proxy.machineStart(machineID, reply: reply)
        } decode: {
            Self.machineStatus(from: $0)
        }
    }

    func machineStop(_ machineID: String) async throws -> DorydMachineStatus {
        try await withTimeout(atLeast: 30).statusCommand { proxy, reply in
            proxy.machineStop(machineID, reply: reply)
        } decode: {
            Self.machineStatus(from: $0)
        }
    }

    func machineUpdate(
        _ machineID: String,
        memoryMB: UInt64? = nil,
        cpuCount: Int? = nil,
        address: String? = nil,
        updatesAddress: Bool = false,
        shares: [DorydMachineShareConfiguration]? = nil,
        environment: [String: String]? = nil
    ) async throws -> DorydMachineStatus {
        var config: [String: Any] = [:]
        if let memoryMB {
            config["memoryMB"] = memoryMB
        }
        if let cpuCount {
            config["cpuCount"] = cpuCount
        }
        if updatesAddress {
            config["address"] = address ?? ""
        } else if let address {
            config["address"] = address
        }
        if let shares {
            config["shares"] = shares.map(\.xpcDictionary)
        }
        if let environment {
            config["env"] = environment.sorted(by: { $0.key < $1.key }).map { key, value in
                [
                    "key": key,
                    "value": value,
                ] as NSDictionary
            }
        }
        return try await withTimeout(atLeast: 120).statusCommand { proxy, reply in
            proxy.machineUpdate(machineID, config: config as NSDictionary, reply: reply)
        } decode: {
            Self.machineStatus(from: $0)
        }
    }

    func machineDelete(_ machineID: String) async throws -> DorydCommandResult {
        try await command { proxy, reply in
            proxy.machineDelete(machineID, reply: reply)
        }
    }

    func machineExec(
        _ machineID: String,
        argv: [String],
        cwd: String = "",
        env: [String: String] = [:],
        timeoutMs: UInt64 = 30_000,
        outputLimitBytes: UInt64 = 1024 * 1024
    ) async throws -> DorydMachineExecResult {
        let request: NSDictionary = [
            "argv": argv,
            "cwd": cwd,
            "env": env.map { ["key": $0.key, "value": $0.value] as NSDictionary },
            "timeoutMs": timeoutMs,
            "outputLimitBytes": outputLimitBytes,
        ]
        return try await withTimeout(atLeast: Self.machineExecControlTimeout(timeoutMs: timeoutMs)).statusCommand { proxy, reply in
            proxy.machineExec(machineID, request: request, reply: reply)
        } decode: {
            Self.machineExecResult(from: $0)
        }
    }

    func machineStats(_ machineID: String) async throws -> DorydMachineStats {
        try await withTimeout(atLeast: 10).statusCommand { proxy, reply in
            proxy.machineStats(machineID, reply: reply)
        } decode: {
            Self.machineStats(from: $0)
        }
    }

    func machineProvision(_ machineID: String, recipe: String) async throws -> DorydMachineProvisionResult {
        try await withTimeout(atLeast: Self.machineProvisionControlTimeout).statusCommand { proxy, reply in
            proxy.machineProvision(machineID, request: ["recipe": recipe] as NSDictionary, reply: reply)
        } decode: {
            Self.machineProvisionResult(from: $0)
        }
    }

    func machineSnapshot(
        _ machineID: String,
        note: String = "",
        createdISO: String,
        snapshotID: String? = nil
    ) async throws -> DorydMachineSnapshot {
        var request: [String: Any] = [
            "note": note,
            "createdISO": createdISO,
        ]
        if let snapshotID {
            request["snapshotID"] = snapshotID
        }
        return try await withTimeout(atLeast: 60).statusCommand { proxy, reply in
            proxy.machineSnapshot(machineID, request: request as NSDictionary, reply: reply)
        } decode: {
            Self.machineSnapshot(from: $0)
        }
    }

    func machineSnapshots(machineID: String? = nil) async throws -> [DorydMachineSnapshot] {
        try await call { proxy, finish in
            proxy.machineSnapshots(machineID ?? "") { rows, error in
                if !error.isEmpty {
                    finish(.failure(DorydClientError.daemon(error)))
                    return
                }
                guard let snapshots = Self.machineSnapshots(from: rows) else {
                    finish(.failure(DorydClientError.daemon("invalid machine snapshot list")))
                    return
                }
                finish(.success(snapshots))
            }
        }
    }

    func machineCloneSnapshot(machineID: String, snapshotID: String, newID: String) async throws -> DorydMachineStatus {
        try await withTimeout(atLeast: 120).statusCommand { proxy, reply in
            proxy.machineCloneSnapshot(machineID, snapshotID: snapshotID, newID: newID, reply: reply)
        } decode: {
            Self.machineStatus(from: $0)
        }
    }

    func machineRestoreSnapshot(machineID: String, snapshotID: String) async throws -> DorydMachineStatus {
        try await withTimeout(atLeast: 120).statusCommand { proxy, reply in
            proxy.machineRestoreSnapshot(machineID, snapshotID: snapshotID, reply: reply)
        } decode: {
            Self.machineStatus(from: $0)
        }
    }

    func machineDeleteSnapshot(machineID: String, snapshotID: String) async throws -> DorydCommandResult {
        try await command { proxy, reply in
            proxy.machineDeleteSnapshot(machineID, snapshotID: snapshotID, reply: reply)
        }
    }

    func machineExportSnapshot(machineID: String, snapshotID: String, to path: String) async throws -> DorydCommandResult {
        try await withTimeout(atLeast: 120).command { proxy, reply in
            proxy.machineExportSnapshot(machineID, snapshotID: snapshotID, path: path, reply: reply)
        }
    }

    func machineImportSnapshot(from path: String) async throws -> DorydMachineSnapshot {
        try await withTimeout(atLeast: 120).statusCommand { proxy, reply in
            proxy.machineImportSnapshot(path, reply: reply)
        } decode: {
            Self.machineSnapshot(from: $0)
        }
    }

    func machineList() async throws -> [DorydMachineStatus] {
        try await call { proxy, finish in
            proxy.machineList { rows, error in
                if !error.isEmpty {
                    finish(.failure(DorydClientError.daemon(error)))
                    return
                }
                guard let statuses = Self.machineStatuses(from: rows) else {
                    finish(.failure(DorydClientError.daemon("invalid machine list")))
                    return
                }
                finish(.success(statuses))
            }
        }
    }

    func remoteConnect(_ config: DorydRemoteMachineConfiguration) async throws -> DorydAgentInfo {
        try await statusCommand { proxy, reply in
            proxy.remoteConnect(config.xpcDictionary, reply: reply)
        } decode: {
            Self.agentInfo(from: $0)
        }
    }

    func remotePush(machineID: String, localRoot: String, remoteRoot: String? = nil) async throws -> DorydPushStats {
        try await statusCommand { proxy, reply in
            proxy.remotePush(machineID, localRoot: localRoot, remoteRoot: remoteRoot ?? "", reply: reply)
        } decode: {
            Self.pushStats(from: $0)
        }
    }

    func remoteStatus(machineID: String) async throws -> DorydRemoteMachineStatus {
        try await call { proxy, finish in
            proxy.remoteStatus(machineID) { body, error in
                if !error.isEmpty {
                    finish(.failure(DorydClientError.daemon(error)))
                    return
                }
                guard let status = Self.remoteStatus(from: body) else {
                    finish(.failure(DorydClientError.daemon("invalid remote status")))
                    return
                }
                finish(.success(status))
            }
        }
    }

    func networkReplaceRoutes(_ routes: [DorydDomainRoute]) async throws -> DorydCommandResult {
        try await command { proxy, reply in
            proxy.networkReplaceRoutes(routes.map(\.xpcDictionary) as NSArray, reply: reply)
        }
    }

    func networkStatus() async throws -> DorydNetworkingStatus {
        try await call { proxy, finish in
            proxy.networkStatus { body, error in
                if !error.isEmpty {
                    finish(.failure(DorydClientError.daemon(error)))
                    return
                }
                guard let status = Self.networkStatus(from: body) else {
                    finish(.failure(DorydClientError.daemon("invalid network status")))
                    return
                }
                finish(.success(status))
            }
        }
    }

    func networkAuthorizationPlan() async throws -> DorydNetworkingAuthorizationPlan {
        try await call { proxy, finish in
            proxy.networkAuthorizationPlan { body, error in
                if error.isEmpty, let plan = Self.networkAuthorizationPlan(from: body) {
                    finish(.success(plan))
                } else {
                    finish(.failure(DorydClientError.daemon(error.isEmpty ? "invalid networking authorization plan" : error)))
                }
            }
        }
    }

    func repairSubsystem(_ target: String) async throws -> DorydCommandResult {
        try await command { proxy, reply in
            proxy.repairSubsystem(target, reply: reply)
        }
    }

    func balloonStatus() async throws -> DorydBalloonPlan {
        try await call { proxy, finish in
            proxy.balloonStatus { body, error in
                if !error.isEmpty {
                    finish(.failure(DorydClientError.daemon(error)))
                    return
                }
                guard let plan = Self.balloonPlan(from: body) else {
                    finish(.failure(DorydClientError.daemon("invalid balloon plan")))
                    return
                }
                finish(.success(plan))
            }
        }
    }

    func balloonReconcile() async throws -> DorydBalloonPlan {
        try await call { proxy, finish in
            proxy.balloonReconcile { body, error in
                if !error.isEmpty {
                    finish(.failure(DorydClientError.daemon(error)))
                    return
                }
                guard let plan = Self.balloonPlan(from: body) else {
                    finish(.failure(DorydClientError.daemon("invalid balloon plan")))
                    return
                }
                finish(.success(plan))
            }
        }
    }

    func idleStatus() async throws -> IdleStatus {
        try await dictionaryCall { proxy, reply in
            proxy.idleStatus(reply: reply)
        } decode: {
            Self.decoded(IdleStatus.self, from: $0)
        }
    }

    func idleHistory(limit: Int) async throws -> [IdleHistoryEntry] {
        try await call { proxy, finish in
            proxy.idleHistory(limit) { rows, error in
                if !error.isEmpty {
                    finish(.failure(DorydClientError.daemon(error)))
                    return
                }
                guard let history = Self.decoded([FailableDecodable<IdleHistoryEntry>].self, from: rows) else {
                    finish(.failure(DorydClientError.daemon("invalid idle history")))
                    return
                }
                finish(.success(history.compactMap(\.value)))
            }
        }
    }

    func idleSetMode(_ mode: String) async throws -> IdleStatus {
        try await withTimeout(atLeast: Self.engineColdStartTimeout).statusCommand { proxy, reply in
            proxy.idleSetMode(mode, reply: reply)
        } decode: {
            Self.decoded(IdleStatus.self, from: $0)
        }
    }

    func idleSetPolicy(key: String, value: String) async throws -> IdleStatus {
        try await statusCommand { proxy, reply in
            proxy.idleSetPolicy(key, value: value, reply: reply)
        } decode: {
            Self.decoded(IdleStatus.self, from: $0)
        }
    }

    func incidents(limit: Int) async throws -> [Incident] {
        try await call { proxy, finish in
            proxy.incidents(limit) { rows, error in
                if !error.isEmpty {
                    finish(.failure(DorydClientError.daemon(error)))
                    return
                }
                finish(.success(rows.compactMap(Self.incident(from:))))
            }
        }
    }

    private func command(
        _ body: @escaping (DorydControlXPC, @escaping (Bool, String) -> Void) -> Void
    ) async throws -> DorydCommandResult {
        try await call { proxy, finish in
            body(proxy) { ok, message in
                finish(.success(DorydCommandResult(ok: ok, message: message)))
            }
        }
    }

    private func statusCommand<T>(
        _ body: @escaping (DorydControlXPC, @escaping (Bool, NSDictionary, String) -> Void) -> Void,
        decode: @escaping (NSDictionary) -> T?
    ) async throws -> T {
        try await call { proxy, finish in
            body(proxy) { ok, response, message in
                if !ok {
                    finish(.failure(DorydClientError.daemon(message)))
                    return
                }
                guard let decoded = decode(response) else {
                    finish(.failure(DorydClientError.daemon(message.isEmpty ? "invalid doryd response" : message)))
                    return
                }
                finish(.success(decoded))
            }
        }
    }

    private func dictionaryCall<T>(
        _ body: @escaping (DorydControlXPC, @escaping (NSDictionary, String) -> Void) -> Void,
        decode: @escaping (NSDictionary) -> T?
    ) async throws -> T {
        try await call { proxy, finish in
            body(proxy) { response, message in
                if !message.isEmpty {
                    finish(.failure(DorydClientError.daemon(message)))
                    return
                }
                guard let decoded = decode(response) else {
                    finish(.failure(DorydClientError.daemon("invalid doryd response")))
                    return
                }
                finish(.success(decoded))
            }
        }
    }

    private func call<T>(
        _ body: @escaping (DorydControlXPC, @escaping @Sendable (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let connection = makeConnection()
            let box = DorydContinuationBox(continuation: continuation, connection: connection)
            connection.remoteObjectInterface = NSXPCInterface(with: DorydControlXPC.self)
            connection.invalidationHandler = {
                box.resume(.failure(DorydClientError.connectionUnavailable))
            }
            connection.interruptionHandler = {
                box.resume(.failure(DorydClientError.connectionUnavailable))
            }
            connection.resume()

            let timeout = DispatchWorkItem {
                box.resume(.failure(DorydClientError.timedOut))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + self.timeout, execute: timeout)

            let remote = connection.remoteObjectProxyWithErrorHandler { error in
                timeout.cancel()
                box.resume(.failure(error))
            }
            guard let proxy = remote as? DorydControlXPC else {
                timeout.cancel()
                box.resume(.failure(DorydClientError.invalidProxy))
                return
            }
            body(proxy) { result in
                timeout.cancel()
                box.resume(result)
            }
        }
    }

    private func makeConnection() -> NSXPCConnection {
        switch target {
        case let .machService(name):
            return NSXPCConnection(machServiceName: name, options: [])
        case let .endpoint(endpoint):
            return NSXPCConnection(listenerEndpoint: endpoint)
        }
    }

    nonisolated private static func incident(from row: Any) -> Incident? {
        guard let dictionary = row as? NSDictionary,
              let at = dictionary["at"] as? String,
              let type = dictionary["type"] as? String else {
            return nil
        }
        return Incident(at: at, type: type, detail: dictionary["detail"] as? String)
    }

    nonisolated private static func decoded<T: Decodable>(_ type: T.Type, from object: Any) -> T? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: []) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    nonisolated private static func machineStatus(from dictionary: NSDictionary) -> DorydMachineStatus? {
        guard let id = dictionary["id"] as? String,
              let state = dictionary["state"] as? String else {
            return nil
        }
        return DorydMachineStatus(
            id: id,
            state: state,
            pid: int32(dictionary["pid"]),
            lastError: nonEmptyString(dictionary["lastError"]),
            handoffSocketPath: nonEmptyString(dictionary["handoffSocketPath"]),
            agentBuild: nonEmptyString(dictionary["agentBuild"]),
            agentSocketPath: nonEmptyString(dictionary["agentSocketPath"]),
            dockerdSocketPath: nonEmptyString(dictionary["dockerdSocketPath"]),
            shellSocketPath: nonEmptyString(dictionary["shellSocketPath"]),
            controlSocketPath: nonEmptyString(dictionary["controlSocketPath"]),
            address: nonEmptyString(dictionary["address"]),
            configuredAddress: nonEmptyString(dictionary["configuredAddress"]),
            runtimeAddress: nonEmptyString(dictionary["runtimeAddress"]),
            handoffFDCount: int(dictionary["handoffFDCount"]) ?? 0,
            memoryMB: uint64(dictionary["memoryMB"]),
            currentBalloonTargetMB: uint64(dictionary["currentBalloonTargetMB"]),
            cpuCount: int(dictionary["cpuCount"]),
            displayMode: (dictionary["displayMode"] as? String).flatMap(MachineDisplayMode.init(rawValue:)) ?? .headless,
            shares: machineShares(from: dictionary["shares"]),
            environment: machineEnvironment(from: dictionary["env"])
        )
    }

    nonisolated private static func machineShares(from value: Any?) -> [DorydMachineShareConfiguration] {
        let rows: [NSDictionary]
        if let swiftRows = value as? [NSDictionary] {
            rows = swiftRows
        } else if let nsRows = value as? NSArray {
            rows = nsRows.compactMap { $0 as? NSDictionary }
        } else {
            return []
        }
        return rows.compactMap { row in
            guard let tag = row["tag"] as? String,
                  let hostPath = row["hostPath"] as? String,
                  let guestPath = row["guestPath"] as? String else {
                return nil
            }
            let readOnly = (row["readOnly"] as? Bool)
                ?? (row["readOnly"] as? NSNumber)?.boolValue
                ?? ((row["mode"] as? String) == "ro")
            return DorydMachineShareConfiguration(
                tag: tag,
                hostPath: hostPath,
                guestPath: guestPath,
                readOnly: readOnly
            )
        }
    }

    nonisolated private static func machineEnvironment(from value: Any?) -> [String: String] {
        let rows: [NSDictionary]
        if let swiftRows = value as? [NSDictionary] {
            rows = swiftRows
        } else if let nsRows = value as? NSArray {
            rows = nsRows.compactMap { $0 as? NSDictionary }
        } else {
            return [:]
        }
        var result: [String: String] = [:]
        for row in rows {
            guard let key = row["key"] as? String,
                  key.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_]*/) != nil else {
                continue
            }
            result[key] = (row["value"] as? String) ?? ""
        }
        return result
    }

    nonisolated private static func machineStatuses(from rows: NSArray) -> [DorydMachineStatus]? {
        let dictionaries = rows.compactMap { $0 as? NSDictionary }
        guard dictionaries.count == rows.count else { return nil }
        let statuses = dictionaries.compactMap(machineStatus(from:))
        guard statuses.count == dictionaries.count else { return nil }
        return statuses
    }

    nonisolated private static func machineExecResult(from dictionary: NSDictionary) -> DorydMachineExecResult? {
        guard let exitCode = int32(dictionary["exitCode"]),
              let stdout = outputString(dictionary["stdout"]),
              let stderr = outputString(dictionary["stderr"]) else {
            return nil
        }
        return DorydMachineExecResult(
            exitCode: exitCode,
            stdout: stdout,
            stderr: stderr,
            timedOut: (dictionary["timedOut"] as? Bool) ?? false,
            stdoutTruncated: (dictionary["stdoutTruncated"] as? Bool) ?? false,
            stderrTruncated: (dictionary["stderrTruncated"] as? Bool) ?? false
        )
    }

    nonisolated private static func machineStats(from dictionary: NSDictionary) -> DorydMachineStats? {
        guard dictionary["schema"] as? String == "dev.dory.machine.stats",
              int(dictionary["version"]) == 1,
              let cpuPercent = double(dictionary["cpuPercent"]),
              let memoryUsedBytes = uint64(dictionary["memoryUsedBytes"]),
              let memoryTotalBytes = uint64(dictionary["memoryTotalBytes"]),
              let networkReceiveBytes = uint64(dictionary["networkReceiveBytes"]),
              let networkTransmitBytes = uint64(dictionary["networkTransmitBytes"]),
              let blockReadBytes = uint64(dictionary["blockReadBytes"]),
              let blockWriteBytes = uint64(dictionary["blockWriteBytes"]),
              let processCount = uint64(dictionary["processCount"]),
              let uptimeSeconds = double(dictionary["uptimeSeconds"]),
              cpuPercent >= 0, cpuPercent <= 100, memoryUsedBytes <= memoryTotalBytes else {
            return nil
        }
        return DorydMachineStats(
            cpuPercent: cpuPercent,
            memoryUsedBytes: memoryUsedBytes,
            memoryTotalBytes: memoryTotalBytes,
            networkReceiveBytes: networkReceiveBytes,
            networkTransmitBytes: networkTransmitBytes,
            blockReadBytes: blockReadBytes,
            blockWriteBytes: blockWriteBytes,
            processCount: processCount,
            uptimeSeconds: uptimeSeconds
        )
    }

    nonisolated private static func machineProvisionResult(from dictionary: NSDictionary) -> DorydMachineProvisionResult? {
        let decodedRecipeID = (dictionary["recipeID"] as? String) ?? (dictionary["recipe"] as? String)
        guard let recipeID = decodedRecipeID,
              let installDictionary = dictionary["install"] as? NSDictionary,
              let verifyDictionary = dictionary["verify"] as? NSDictionary,
              let install = machineExecResult(from: installDictionary),
              let verify = machineExecResult(from: verifyDictionary) else {
            return nil
        }
        return DorydMachineProvisionResult(recipeID: recipeID, install: install, verify: verify)
    }

    nonisolated private static func machineSnapshot(from dictionary: NSDictionary) -> DorydMachineSnapshot? {
        guard let id = dictionary["id"] as? String,
              let machineID = dictionary["machineID"] as? String,
              let note = dictionary["note"] as? String,
              let createdISO = dictionary["createdISO"] as? String,
              let rootfsPath = dictionary["rootfsPath"] as? String,
              let sizeBytes = int64(dictionary["sizeBytes"]),
              let kernelPath = dictionary["kernelPath"] as? String,
              let architecture = dictionary["architecture"] as? String,
              let memoryMB = uint64(dictionary["memoryMB"]),
              let cpuCount = int(dictionary["cpuCount"]) else {
            return nil
        }
        return DorydMachineSnapshot(
            id: id,
            machineID: machineID,
            note: note,
            createdISO: createdISO,
            rootfsPath: rootfsPath,
            sizeBytes: sizeBytes,
            kernelPath: kernelPath,
            architecture: architecture,
            memoryMB: memoryMB,
            cpuCount: cpuCount
        )
    }

    nonisolated private static func machineSnapshots(from rows: NSArray) -> [DorydMachineSnapshot]? {
        let dictionaries = rows.compactMap { $0 as? NSDictionary }
        guard dictionaries.count == rows.count else { return nil }
        let snapshots = dictionaries.compactMap(machineSnapshot(from:))
        guard snapshots.count == dictionaries.count else { return nil }
        return snapshots
    }

    nonisolated private static func agentInfo(from dictionary: NSDictionary) -> DorydAgentInfo? {
        guard let protocolVersion = uint32(dictionary["protocolVersion"]),
              let kernel = dictionary["kernel"] as? String,
              let agentBuild = dictionary["agentBuild"] as? String,
              let uptimeSeconds = uint64(dictionary["uptimeSeconds"]) else {
            return nil
        }
        return DorydAgentInfo(
            protocolVersion: protocolVersion,
            kernel: kernel,
            agentBuild: agentBuild,
            uptimeSeconds: uptimeSeconds
        )
    }

    nonisolated private static func telemetry(from dictionary: NSDictionary) -> DorydTelemetry? {
        guard let memTotalKB = uint64(dictionary["memTotalKB"]),
              let memAvailableKB = uint64(dictionary["memAvailableKB"]),
              let psiSomeAvg10 = double(dictionary["psiSomeAvg10"]),
              let psiFullAvg10 = double(dictionary["psiFullAvg10"]) else {
            return nil
        }
        return DorydTelemetry(
            memTotalKB: memTotalKB,
            memAvailableKB: memAvailableKB,
            psiSomeAvg10: psiSomeAvg10,
            psiFullAvg10: psiFullAvg10
        )
    }

    nonisolated private static func listenPort(from dictionary: NSDictionary) -> DorydListenPort? {
        guard let proto = dictionary["protocol"] as? String,
              let port = uint32(dictionary["port"]) else {
            return nil
        }
        return DorydListenPort(protocol: proto, port: port)
    }

    nonisolated private static func dockerAgentPorts(from dictionary: NSDictionary) -> DorydDockerAgentPorts? {
        guard let rawPorts = dictionary["ports"] as? [NSDictionary],
              let rawAdded = dictionary["added"] as? [NSDictionary],
              let rawRemoved = dictionary["removed"] as? [NSDictionary] else {
            return nil
        }
        let ports = rawPorts.compactMap(listenPort(from:))
        let added = rawAdded.compactMap(listenPort(from:))
        let removed = rawRemoved.compactMap(listenPort(from:))
        guard ports.count == rawPorts.count,
              added.count == rawAdded.count,
              removed.count == rawRemoved.count else {
            return nil
        }
        return DorydDockerAgentPorts(ports: ports, added: added, removed: removed)
    }

    nonisolated private static func pushStats(from dictionary: NSDictionary) -> DorydPushStats? {
        guard let filesSent = uint64(dictionary["filesSent"]),
              let bytesSent = uint64(dictionary["bytesSent"]),
              let filesDeleted = uint64(dictionary["filesDeleted"]) else {
            return nil
        }
        return DorydPushStats(filesSent: filesSent, bytesSent: bytesSent, filesDeleted: filesDeleted)
    }

    nonisolated private static func remoteStatus(from dictionary: NSDictionary) -> DorydRemoteMachineStatus? {
        guard let id = dictionary["id"] as? String,
              let state = dictionary["state"] as? String else {
            return nil
        }
        return DorydRemoteMachineStatus(
            id: id,
            state: state,
            lastError: nonEmptyString(dictionary["lastError"]),
            info: (dictionary["info"] as? NSDictionary).flatMap(agentInfo(from:)),
            telemetry: (dictionary["telemetry"] as? NSDictionary).flatMap(telemetry(from:))
        )
    }

    nonisolated private static func domainRoute(from dictionary: NSDictionary) -> DorydDomainRoute? {
        guard let hostname = dictionary["hostname"] as? String,
              let address = dictionary["address"] as? String else {
            return nil
        }
        return DorydDomainRoute(
            hostname: hostname,
            address: address,
            port: uint16(dictionary["port"]) ?? 80,
            pathPrefix: nonEmptyString(dictionary["pathPrefix"]) ?? ""
        )
    }

    nonisolated private static func networkStatus(from dictionary: NSDictionary) -> DorydNetworkingStatus? {
        guard let mode = dictionary["mode"] as? String,
              let suffix = dictionary["suffix"] as? String,
              let dnsBindAddress = dictionary["dnsBindAddress"] as? String,
              let dnsPort = uint16(dictionary["dnsPort"]),
              let dnsRunning = dictionary["dnsRunning"] as? Bool,
              let rawRoutes = dictionary["routes"] as? [NSDictionary] else {
            return nil
        }
        let routes = rawRoutes.compactMap(domainRoute(from:))
        guard routes.count == rawRoutes.count else { return nil }
        return DorydNetworkingStatus(
            mode: mode,
            suffix: suffix,
            dnsBindAddress: dnsBindAddress,
            dnsPort: dnsPort,
            dnsRunning: dnsRunning,
            httpProxyPort: uint16(dictionary["httpProxyPort"]),
            httpProxyRunning: (dictionary["httpProxyRunning"] as? Bool) ?? false,
            httpsProxyPort: uint16(dictionary["httpsProxyPort"]),
            httpsProxyRunning: (dictionary["httpsProxyRunning"] as? Bool) ?? false,
            routes: routes
        )
    }

    nonisolated private static func networkAuthorizationPlan(from dictionary: NSDictionary) -> DorydNetworkingAuthorizationPlan? {
        guard let degradedMode = dictionary["degradedMode"] as? String,
              let authorizedMode = dictionary["authorizedMode"] as? String,
              let suffix = dictionary["suffix"] as? String,
              let dnsBindAddress = dictionary["dnsBindAddress"] as? String,
              let dnsPort = uint16(dictionary["dnsPort"]),
              let httpProxyPort = uint16(dictionary["httpProxyPort"]),
              let httpsProxyPort = uint16(dictionary["httpsProxyPort"]),
              let rawRequests = dictionary["requests"] as? [NSDictionary] else {
            return nil
        }
        let requests = rawRequests.compactMap(networkAuthorizationRequest(from:))
        guard requests.count == rawRequests.count else { return nil }
        let rawForwards = dictionary["privilegedTCPForwards"] as? [NSDictionary] ?? []
        let privilegedTCPForwards = rawForwards.compactMap(privilegedTCPForward(from:))
        guard privilegedTCPForwards.count == rawForwards.count else { return nil }
        return DorydNetworkingAuthorizationPlan(
            degradedMode: degradedMode,
            authorizedMode: authorizedMode,
            suffix: suffix,
            dnsBindAddress: dnsBindAddress,
            dnsPort: dnsPort,
            httpProxyPort: httpProxyPort,
            httpsProxyPort: httpsProxyPort,
            privilegedTCPForwards: privilegedTCPForwards,
            requests: requests
        )
    }

    nonisolated private static func privilegedTCPForward(from dictionary: NSDictionary) -> DorydPrivilegedTCPForward? {
        guard let listenPort = uint16(dictionary["listenPort"]),
              let targetPort = uint16(dictionary["targetPort"]) else {
            return nil
        }
        return DorydPrivilegedTCPForward(listenPort: listenPort, targetPort: targetPort)
    }

    nonisolated private static func networkAuthorizationRequest(from dictionary: NSDictionary) -> DorydNetworkingAuthorizationRequest? {
        guard let id = dictionary["id"] as? String,
              let kind = dictionary["kind"] as? String,
              let title = dictionary["title"] as? String,
              let reason = dictionary["reason"] as? String,
              let requiresAdmin = dictionary["requiresAdmin"] as? Bool,
              let command = dictionary["command"] as? [String] else {
            return nil
        }
        return DorydNetworkingAuthorizationRequest(
            id: id,
            kind: kind,
            title: title,
            reason: reason,
            requiresAdmin: requiresAdmin,
            filePath: dictionary["filePath"] as? String,
            fileContents: dictionary["fileContents"] as? String,
            command: command
        )
    }

    nonisolated private static func hostMemorySnapshot(from dictionary: NSDictionary) -> DorydHostMemorySnapshot? {
        guard let totalBytes = uint64(dictionary["totalBytes"]),
              let availableBytes = uint64(dictionary["availableBytes"]),
              let freeBytes = uint64(dictionary["freeBytes"]),
              let availableRatio = double(dictionary["availableRatio"]),
              let pressure = dictionary["pressure"] as? String else {
            return nil
        }
        return DorydHostMemorySnapshot(
            totalBytes: totalBytes,
            availableBytes: availableBytes,
            freeBytes: freeBytes,
            availableRatio: availableRatio,
            pressure: pressure
        )
    }

    nonisolated private static func balloonTarget(from dictionary: NSDictionary) -> DorydBalloonTarget? {
        guard let id = dictionary["id"] as? String,
              let kind = dictionary["kind"] as? String,
              let currentTargetMB = uint64(dictionary["currentTargetMB"]),
              let targetMB = uint64(dictionary["targetMB"]),
              let reason = dictionary["reason"] as? String,
              let canApply = dictionary["canApply"] as? Bool else {
            return nil
        }
        return DorydBalloonTarget(
            id: id,
            kind: kind,
            currentTargetMB: currentTargetMB,
            targetMB: targetMB,
            reason: reason,
            canApply: canApply
        )
    }

    nonisolated private static func balloonPlan(from dictionary: NSDictionary) -> DorydBalloonPlan? {
        guard let hostDictionary = dictionary["host"] as? NSDictionary,
              let host = hostMemorySnapshot(from: hostDictionary),
              let rawTargets = dictionary["targets"] as? [NSDictionary],
              let rawApplicable = dictionary["applicableTargets"] as? [NSDictionary] else {
            return nil
        }
        let targets = rawTargets.compactMap(balloonTarget(from:))
        let applicableTargets = rawApplicable.compactMap(balloonTarget(from:))
        guard targets.count == rawTargets.count, applicableTargets.count == rawApplicable.count else {
            return nil
        }
        return DorydBalloonPlan(host: host, targets: targets, applicableTargets: applicableTargets)
    }

    nonisolated private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    nonisolated private static func outputString(_ value: Any?) -> String? {
        if let data = value as? Data {
            return String(decoding: data, as: UTF8.self)
        }
        return value as? String
    }

    nonisolated private static var machineProvisionControlTimeout: TimeInterval {
        machineExecControlTimeout(timeoutMs: 600_000) * 2
    }

    nonisolated private static func machineExecControlTimeout(timeoutMs: UInt64) -> TimeInterval {
        let effectiveTimeoutMs: UInt64 = timeoutMs == 0 ? 30_000 : min(timeoutMs, 600_000)
        return TimeInterval(effectiveTimeoutMs) / 1000 + 10
    }

    nonisolated private static func uint64(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber {
            return number.uint64Value
        }
        if let string = value as? String {
            return UInt64(string)
        }
        return value as? UInt64
    }

    nonisolated private static func uint32(_ value: Any?) -> UInt32? {
        if let number = value as? NSNumber {
            return number.uint32Value
        }
        if let string = value as? String {
            return UInt32(string)
        }
        return value as? UInt32
    }

    nonisolated private static func uint16(_ value: Any?) -> UInt16? {
        if let number = value as? NSNumber {
            let int = number.intValue
            guard int >= 0, int <= Int(UInt16.max) else { return nil }
            return UInt16(int)
        }
        if let string = value as? String {
            return UInt16(string)
        }
        return value as? UInt16
    }

    nonisolated private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return value as? Int
    }

    nonisolated private static func int32(_ value: Any?) -> Int32? {
        if let number = value as? NSNumber {
            return number.int32Value
        }
        if let string = value as? String {
            return Int32(string)
        }
        return value as? Int32
    }

    nonisolated private static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber {
            return number.int64Value
        }
        if let string = value as? String {
            return Int64(string)
        }
        return value as? Int64
    }

    nonisolated private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string)
        }
        return value as? Double
    }
}

nonisolated private final class DorydContinuationBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private let connection: NSXPCConnection

    init(continuation: CheckedContinuation<T, Error>, connection: NSXPCConnection) {
        self.continuation = continuation
        self.connection = connection
    }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        connection.invalidate()
        continuation.resume(with: result)
    }
}
