import Foundation

/// The clean Swift facade over the UniFFI-generated bindings. Callers use
/// DoryCore, never the raw generated globals, so the FFI surface can evolve
/// without touching consumers.
public enum DoryCore {
    /// The wire protocol version doryd and the agents must agree on.
    public static func protocolVersion() -> UInt32 {
        protoVersion()
    }

    /// Start the Rust docker dataplane against a plain unix `dockerd` socket.
    public static func startDockerDataplane(
        listenFD: Int32,
        dockerdSocketPath: String,
        gpuSupported: Bool
    ) -> DoryDataplaneHandle {
        DoryDataplaneHandle(startDataplane(
            listenFd: listenFD,
            dockerdSocketPath: dockerdSocketPath,
            gpuSupported: gpuSupported
        ))
    }

    /// Start the docker-tier dataplane through dory-hv's raw vsock forward socket.
    public static func startDockerForwardDataplane(
        listenFD: Int32,
        forwardSocketPath: String,
        cid: UInt32,
        port: UInt32,
        gpuSupported: Bool
    ) -> DoryDataplaneHandle {
        DoryDataplaneHandle(startDataplaneForward(
            listenFd: listenFD,
            forwardSocketPath: forwardSocketPath,
            cid: cid,
            port: port,
            gpuSupported: gpuSupported
        ))
    }

    /// Start the docker-tier dataplane and report meaningful docker connection activity to doryd.
    public static func startDockerForwardDataplane(
        listenFD: Int32,
        forwardSocketPath: String,
        cid: UInt32,
        port: UInt32,
        gpuSupported: Bool,
        activitySocketPath: String
    ) -> DoryDataplaneHandle {
        DoryDataplaneHandle(startDataplaneForwardWithActivity(
            listenFd: listenFD,
            forwardSocketPath: forwardSocketPath,
            cid: cid,
            port: port,
            gpuSupported: gpuSupported,
            activitySocketPath: activitySocketPath
        ))
    }

    /// Connect to the guest agent control channel through dory-hv's raw vsock forward socket.
    public static func connectAgentControlOverForward(
        forwardSocketPath: String,
        cid: UInt32
    ) throws -> DoryAgentControlHandle {
        DoryAgentControlHandle(try connectAgentOverForward(
            forwardSocketPath: forwardSocketPath,
            cid: cid
        ))
    }

    /// Connect to the guest agent control channel through an already-connected stream fd.
    ///
    /// Ownership of `fd` transfers to Rust. Callers that received the descriptor from another
    /// framework object should pass a duplicated fd.
    public static func connectAgentControlOverFD(_ fd: Int32) throws -> DoryAgentControlHandle {
        DoryAgentControlHandle(try connectAgentOverFd(fd: fd))
    }

    /// Connect to a remote dory-agent over SSH using the Rust remote stack.
    public static func connectRemoteAgent(
        config: DoryRemoteConfig
    ) throws -> DoryRemoteAgentHandle {
        DoryRemoteAgentHandle(try remoteConnect(config: config.ffiConfig))
    }
}

/// A Swift-owned lifetime wrapper around the UniFFI dataplane object.
public final class DoryDataplaneHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var dataplane: DoryDataplane?

    fileprivate init(_ dataplane: DoryDataplane) {
        self.dataplane = dataplane
    }

    public func shutdown() {
        lock.lock()
        let current = dataplane
        dataplane = nil
        lock.unlock()
        current?.shutdown()
    }

    deinit {
        shutdown()
    }
}

public struct DoryAgentInfo: Sendable, Equatable {
    public var protocolVersion: UInt32
    public var kernel: String
    public var agentBuild: String
    public var uptimeSeconds: UInt64

    public init(protocolVersion: UInt32, kernel: String, agentBuild: String, uptimeSeconds: UInt64) {
        self.protocolVersion = protocolVersion
        self.kernel = kernel
        self.agentBuild = agentBuild
        self.uptimeSeconds = uptimeSeconds
    }
}

public struct DoryListenPort: Sendable, Equatable, Hashable {
    public var `protocol`: String
    public var port: UInt32

    public init(`protocol`: String, port: UInt32) {
        self.`protocol` = `protocol`
        self.port = port
    }
}

public struct DoryPortEvent: Sendable, Equatable, Hashable {
    public var action: String
    public var `protocol`: String
    public var port: UInt32

    public init(action: String, `protocol`: String, port: UInt32) {
        self.action = action
        self.`protocol` = `protocol`
        self.port = port
    }
}

public struct DoryPortsSnapshot: Sendable, Equatable {
    public var ports: [DoryListenPort]
    public var added: [DoryPortEvent]
    public var removed: [DoryPortEvent]

    public init(ports: [DoryListenPort], added: [DoryPortEvent], removed: [DoryPortEvent]) {
        self.ports = ports
        self.added = added
        self.removed = removed
    }
}

public struct DoryTelemetry: Sendable, Equatable {
    public var memTotalKB: UInt64
    public var memAvailableKB: UInt64
    public var psiSomeAvg10: Double
    public var psiFullAvg10: Double

    public init(
        memTotalKB: UInt64,
        memAvailableKB: UInt64,
        psiSomeAvg10: Double,
        psiFullAvg10: Double
    ) {
        self.memTotalKB = memTotalKB
        self.memAvailableKB = memAvailableKB
        self.psiSomeAvg10 = psiSomeAvg10
        self.psiFullAvg10 = psiFullAvg10
    }
}

public struct DoryExecEnvironment: Sendable, Equatable, Hashable {
    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }

    fileprivate var ffiValue: ExecEnvFfi {
        ExecEnvFfi(key: key, value: value)
    }
}

public struct DoryExecResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool
    public var stdoutTruncated: Bool
    public var stderrTruncated: Bool

    public init(
        exitCode: Int32,
        stdout: Data,
        stderr: Data,
        timedOut: Bool,
        stdoutTruncated: Bool,
        stderrTruncated: Bool
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
    }

    fileprivate init(_ raw: ExecResultFfi) {
        self.init(
            exitCode: raw.exitCode,
            stdout: raw.stdout,
            stderr: raw.stderr,
            timedOut: raw.timedOut,
            stdoutTruncated: raw.stdoutTruncated,
            stderrTruncated: raw.stderrTruncated
        )
    }
}

public struct DoryPushStats: Sendable, Equatable {
    public var filesSent: UInt64
    public var bytesSent: UInt64
    public var filesDeleted: UInt64

    public init(filesSent: UInt64, bytesSent: UInt64, filesDeleted: UInt64) {
        self.filesSent = filesSent
        self.bytesSent = bytesSent
        self.filesDeleted = filesDeleted
    }
}

public enum DoryRemoteHostKey: Sendable, Equatable, Hashable {
    case pinned(opensshPublicKey: String)
    case knownHosts(path: String, host: String, port: UInt16)

    fileprivate var ffiHostKey: RemoteHostKey {
        switch self {
        case let .pinned(opensshPublicKey):
            return .pinned(opensshPublicKey: opensshPublicKey)
        case let .knownHosts(path, host, port):
            return .knownHosts(path: path, host: host, port: port)
        }
    }
}

public enum DoryRemoteEndpoint: Sendable, Equatable, Hashable {
    case unixSocket(path: String)
    case tcp(host: String, port: UInt16)

    fileprivate var ffiEndpoint: RemoteEndpoint {
        switch self {
        case let .unixSocket(path):
            return .unixSocket(path: path)
        case let .tcp(host, port):
            return .tcp(host: host, port: port)
        }
    }
}

public struct DoryRemoteConfig: Sendable, Equatable, Hashable {
    public var host: String
    public var port: UInt16
    public var user: String
    public var opensshPrivateKey: String
    public var hostKey: DoryRemoteHostKey
    public var endpoint: DoryRemoteEndpoint
    public var build: String

    public init(
        host: String,
        port: UInt16,
        user: String,
        opensshPrivateKey: String,
        hostKey: DoryRemoteHostKey,
        endpoint: DoryRemoteEndpoint,
        build: String
    ) {
        self.host = host
        self.port = port
        self.user = user
        self.opensshPrivateKey = opensshPrivateKey
        self.hostKey = hostKey
        self.endpoint = endpoint
        self.build = build
    }

    fileprivate var ffiConfig: RemoteConfig {
        RemoteConfig(
            host: host,
            port: port,
            user: user,
            opensshPrivateKey: opensshPrivateKey,
            hostKey: hostKey.ffiHostKey,
            endpoint: endpoint.ffiEndpoint,
            build: build
        )
    }
}

/// A Swift-owned lifetime wrapper around the UniFFI agent-control object.
public final class DoryAgentControlHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var control: AgentControl?

    fileprivate init(_ control: AgentControl) {
        self.control = control
    }

    public func info() throws -> DoryAgentInfo {
        let raw = try withControl { try $0.info() }
        return DoryAgentInfo(
            protocolVersion: raw.protoVersion,
            kernel: raw.kernel,
            agentBuild: raw.agentBuild,
            uptimeSeconds: raw.uptimeSecs
        )
    }

    public func clockSync(hostEpochNs: Int64) throws -> Bool {
        try withControl { try $0.clockSync(hostEpochNs: hostEpochNs) }
    }

    public func portsWatch() throws -> DoryPortsSnapshot {
        let raw = try withControl { try $0.portsWatch() }
        return DoryPortsSnapshot(
            ports: raw.ports.map { DoryListenPort(protocol: $0.protocol, port: $0.port) },
            added: raw.added.map { DoryPortEvent(action: $0.action, protocol: $0.protocol, port: $0.port) },
            removed: raw.removed.map { DoryPortEvent(action: $0.action, protocol: $0.protocol, port: $0.port) }
        )
    }

    public func telemetry() throws -> DoryTelemetry {
        let raw = try withControl { try $0.telemetry() }
        return DoryTelemetry(
            memTotalKB: raw.memTotalKb,
            memAvailableKB: raw.memAvailableKb,
            psiSomeAvg10: raw.psiSomeAvg10,
            psiFullAvg10: raw.psiFullAvg10
        )
    }

    public func exec(
        argv: [String],
        cwd: String = "",
        env: [DoryExecEnvironment] = [],
        timeoutMs: UInt64 = 30_000,
        outputLimitBytes: UInt64 = 1024 * 1024
    ) throws -> DoryExecResult {
        let raw = try withControl {
            try $0.exec(
                argv: argv,
                cwd: cwd,
                env: env.map(\.ffiValue),
                timeoutMs: timeoutMs,
                outputLimitBytes: outputLimitBytes
            )
        }
        return DoryExecResult(raw)
    }

    public func close() {
        lock.lock()
        control = nil
        lock.unlock()
    }

    private func withControl<T>(_ body: (AgentControl) throws -> T) throws -> T {
        lock.lock()
        guard let control else {
            lock.unlock()
            throw DoryAgentControlError.closed
        }
        lock.unlock()
        return try body(control)
    }

    deinit {
        close()
    }
}

public enum DoryAgentControlError: Error, Sendable {
    case closed
}

/// A Swift-owned lifetime wrapper around the UniFFI remote-agent object.
public final class DoryRemoteAgentHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var remote: RemoteAgent?

    fileprivate init(_ remote: RemoteAgent) {
        self.remote = remote
    }

    public func info() throws -> DoryAgentInfo {
        let raw = try withRemote { try $0.info() }
        return DoryAgentInfo(
            protocolVersion: raw.protoVersion,
            kernel: raw.kernel,
            agentBuild: raw.agentBuild,
            uptimeSeconds: raw.uptimeSecs
        )
    }

    public func telemetry() throws -> DoryTelemetry {
        let raw = try withRemote { try $0.telemetry() }
        return DoryTelemetry(
            memTotalKB: raw.memTotalKb,
            memAvailableKB: raw.memAvailableKb,
            psiSomeAvg10: raw.psiSomeAvg10,
            psiFullAvg10: raw.psiFullAvg10
        )
    }

    public func push(localRoot: String, remoteRoot: String) throws -> DoryPushStats {
        let raw = try withRemote { try $0.push(localRoot: localRoot, remoteRoot: remoteRoot) }
        return DoryPushStats(
            filesSent: raw.filesSent,
            bytesSent: raw.bytesSent,
            filesDeleted: raw.filesDeleted
        )
    }

    public func exec(
        argv: [String],
        cwd: String = "",
        env: [DoryExecEnvironment] = [],
        timeoutMs: UInt64 = 30_000,
        outputLimitBytes: UInt64 = 1024 * 1024
    ) throws -> DoryExecResult {
        let raw = try withRemote {
            try $0.exec(
                argv: argv,
                cwd: cwd,
                env: env.map(\.ffiValue),
                timeoutMs: timeoutMs,
                outputLimitBytes: outputLimitBytes
            )
        }
        return DoryExecResult(raw)
    }

    public func close() {
        lock.lock()
        remote = nil
        lock.unlock()
    }

    private func withRemote<T>(_ body: (RemoteAgent) throws -> T) throws -> T {
        lock.lock()
        guard let remote else {
            lock.unlock()
            throw DoryRemoteAgentError.closed
        }
        lock.unlock()
        return try body(remote)
    }

    deinit {
        close()
    }
}

public enum DoryRemoteAgentError: Error, Sendable {
    case closed
}
