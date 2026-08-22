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

    /// Start the plain unix docker dataplane and report meaningful docker connection activity to doryd.
    public static func startDockerDataplane(
        listenFD: Int32,
        dockerdSocketPath: String,
        gpuSupported: Bool,
        activitySocketPath: String
    ) -> DoryDataplaneHandle {
        DoryDataplaneHandle(startDataplaneWithActivity(
            listenFd: listenFD,
            dockerdSocketPath: dockerdSocketPath,
            gpuSupported: gpuSupported,
            activitySocketPath: activitySocketPath
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

public struct DoryAgentCapability: Sendable, Equatable, Hashable, Codable {
    public var id: String
    public var version: UInt32

    public init(id: String, version: UInt32) {
        self.id = id
        self.version = version
    }

    public var isValid: Bool {
        version > 0 && id.utf8.count <= 63
            && id.wholeMatch(of: /[a-z][a-z0-9]*(?:-[a-z0-9]+)*/) != nil
    }
}

public struct DoryAgentInfo: Sendable, Equatable {
    public var protocolVersion: UInt32
    public var kernel: String
    public var agentBuild: String
    public var uptimeSeconds: UInt64
    public var capabilities: [DoryAgentCapability]

    public init(
        protocolVersion: UInt32,
        kernel: String,
        agentBuild: String,
        uptimeSeconds: UInt64,
        capabilities: [DoryAgentCapability] = []
    ) {
        self.protocolVersion = protocolVersion
        self.kernel = kernel
        self.agentBuild = agentBuild
        self.uptimeSeconds = uptimeSeconds
        self.capabilities = capabilities
    }

    public var capabilitiesAreCanonical: Bool {
        capabilities.allSatisfy(\.isValid)
            && capabilities == capabilities.sorted { $0.id < $1.id }
            && Set(capabilities.map(\.id)).count == capabilities.count
    }

    public func supports(_ id: String, minimumVersion: UInt32 = 1) -> Bool {
        capabilities.contains { $0.id == id && $0.version >= minimumVersion }
    }
}

public enum DoryLifecycleReceiptAction: String, Sendable, Equatable, Hashable, Codable {
    case preparePause = "prepare-pause"
    case resumed
    case prepareStop = "prepare-stop"

    fileprivate var ffiValue: LifecycleReceiptActionFfi {
        switch self {
        case .preparePause: .preparePause
        case .resumed: .resumed
        case .prepareStop: .prepareStop
        }
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

public enum DoryPushPhase: String, Sendable, Equatable, Hashable {
    case preparing
    case transferring
    case finalizing
    case completed
    case cancelled
    case failed

    public var isTerminal: Bool {
        switch self {
        case .completed, .cancelled, .failed:
            true
        case .preparing, .transferring, .finalizing:
            false
        }
    }
}

public struct DoryPushProgress: Sendable, Equatable, Hashable {
    public var phase: DoryPushPhase
    public var filesTotal: UInt64
    public var filesCompleted: UInt64
    public var bytesTotal: UInt64
    public var bytesCompleted: UInt64
    public var currentPath: String?

    public init(
        phase: DoryPushPhase,
        filesTotal: UInt64,
        filesCompleted: UInt64,
        bytesTotal: UInt64,
        bytesCompleted: UInt64,
        currentPath: String?
    ) {
        self.phase = phase
        self.filesTotal = filesTotal
        self.filesCompleted = filesCompleted
        self.bytesTotal = bytesTotal
        self.bytesCompleted = bytesCompleted
        self.currentPath = currentPath
    }

    /// A bounded best-effort fraction for display. Byte progress wins when content has a
    /// measurable size; zero-byte transfers fall back to file progress.
    public var fractionCompleted: Double {
        if phase == .completed {
            return 1
        }
        if bytesTotal > 0 {
            return min(1, Double(bytesCompleted) / Double(bytesTotal))
        }
        if filesTotal > 0 {
            return min(1, Double(filesCompleted) / Double(filesTotal))
        }
        return 0
    }

    fileprivate init(_ raw: PushProgressFfi) {
        self.init(
            phase: DoryPushPhase(raw.phase),
            filesTotal: raw.filesTotal,
            filesCompleted: raw.filesCompleted,
            bytesTotal: raw.bytesTotal,
            bytesCompleted: raw.bytesCompleted,
            currentPath: raw.currentPath
        )
    }
}

/// Single-use control for one push. The same instance may be polled or cancelled from a thread
/// other than the thread executing the push.
public final class DoryPushControl: @unchecked Sendable {
    fileprivate let raw: PushControl

    public init() {
        raw = newPushControl()
    }

    public func cancel() {
        raw.cancel()
    }

    public func progress() -> DoryPushProgress {
        DoryPushProgress(raw.progress())
    }
}

private extension DoryPushPhase {
    init(_ raw: PushPhaseFfi) {
        switch raw {
        case .preparing:
            self = .preparing
        case .transferring:
            self = .transferring
        case .finalizing:
            self = .finalizing
        case .completed:
            self = .completed
        case .cancelled:
            self = .cancelled
        case .failed:
            self = .failed
        }
    }
}

public struct DoryPullLimits: Sendable, Equatable, Hashable {
    public var maxFiles: UInt64
    public var maxDirectories: UInt64
    public var maxBytes: UInt64

    public init(
        maxFiles: UInt64 = 100_000,
        maxDirectories: UInt64 = 100_000,
        maxBytes: UInt64 = 32 * 1024 * 1024 * 1024
    ) {
        self.maxFiles = maxFiles
        self.maxDirectories = maxDirectories
        self.maxBytes = maxBytes
    }
}

public struct DoryPullStats: Sendable, Equatable {
    public var filesReceived: UInt64
    public var directoriesReceived: UInt64
    public var bytesReceived: UInt64

    public init(filesReceived: UInt64, directoriesReceived: UInt64, bytesReceived: UInt64) {
        self.filesReceived = filesReceived
        self.directoriesReceived = directoriesReceived
        self.bytesReceived = bytesReceived
    }

    fileprivate init(_ raw: PullStatsFfi) {
        self.init(
            filesReceived: raw.filesReceived,
            directoriesReceived: raw.directoriesReceived,
            bytesReceived: raw.bytesReceived
        )
    }
}

public enum DoryPullPhase: String, Sendable, Equatable, Hashable {
    case preparing
    case transferring
    case finalizing
    case completed
    case cancelled
    case failed

    public var isTerminal: Bool {
        switch self {
        case .completed, .cancelled, .failed:
            true
        case .preparing, .transferring, .finalizing:
            false
        }
    }
}

public struct DoryPullProgress: Sendable, Equatable, Hashable {
    public var phase: DoryPullPhase
    public var filesTotal: UInt64
    public var filesCompleted: UInt64
    public var bytesTotal: UInt64
    public var bytesCompleted: UInt64
    public var currentPath: String?

    public init(
        phase: DoryPullPhase,
        filesTotal: UInt64,
        filesCompleted: UInt64,
        bytesTotal: UInt64,
        bytesCompleted: UInt64,
        currentPath: String?
    ) {
        self.phase = phase
        self.filesTotal = filesTotal
        self.filesCompleted = filesCompleted
        self.bytesTotal = bytesTotal
        self.bytesCompleted = bytesCompleted
        self.currentPath = currentPath
    }

    public var fractionCompleted: Double {
        if phase == .completed { return 1 }
        if bytesTotal > 0 {
            return min(1, Double(bytesCompleted) / Double(bytesTotal))
        }
        if filesTotal > 0 {
            return min(1, Double(filesCompleted) / Double(filesTotal))
        }
        return 0
    }

    fileprivate init(_ raw: PullProgressFfi) {
        self.init(
            phase: DoryPullPhase(raw.phase),
            filesTotal: raw.filesTotal,
            filesCompleted: raw.filesCompleted,
            bytesTotal: raw.bytesTotal,
            bytesCompleted: raw.bytesCompleted,
            currentPath: raw.currentPath
        )
    }
}

/// Single-use cancellation/progress authority for one guest-to-host transfer.
public final class DoryPullControl: @unchecked Sendable {
    fileprivate let raw: PullControl

    public init() {
        raw = newPullControl()
    }

    public func cancel() {
        raw.cancel()
    }

    public func progress() -> DoryPullProgress {
        DoryPullProgress(raw.progress())
    }
}

private extension DoryPullPhase {
    init(_ raw: PullPhaseFfi) {
        switch raw {
        case .preparing: self = .preparing
        case .transferring: self = .transferring
        case .finalizing: self = .finalizing
        case .completed: self = .completed
        case .cancelled: self = .cancelled
        case .failed: self = .failed
        }
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
            uptimeSeconds: raw.uptimeSecs,
            capabilities: raw.capabilities.map {
                DoryAgentCapability(id: $0.id, version: $0.version)
            }
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

    public func push(localRoot: String, remoteRoot: String) throws -> DoryPushStats {
        let raw = try withControl {
            try $0.push(localRoot: localRoot, remoteRoot: remoteRoot)
        }
        return DoryPushStats(
            filesSent: raw.filesSent,
            bytesSent: raw.bytesSent,
            filesDeleted: raw.filesDeleted
        )
    }

    public func push(
        localRoot: String,
        remoteRoot: String,
        control: DoryPushControl
    ) throws -> DoryPushStats {
        let raw = try withControl {
            try $0.pushControlled(
                localRoot: localRoot,
                remoteRoot: remoteRoot,
                control: control.raw
            )
        }
        return DoryPushStats(
            filesSent: raw.filesSent,
            bytesSent: raw.bytesSent,
            filesDeleted: raw.filesDeleted
        )
    }

    public func pull(
        remoteRoot: String,
        localRoot: String,
        limits: DoryPullLimits = DoryPullLimits()
    ) throws -> DoryPullStats {
        let raw = try withControl {
            try $0.pull(
                remoteRoot: remoteRoot,
                localRoot: localRoot,
                maxFiles: limits.maxFiles,
                maxDirectories: limits.maxDirectories,
                maxBytes: limits.maxBytes
            )
        }
        return DoryPullStats(raw)
    }

    public func pull(
        remoteRoot: String,
        localRoot: String,
        limits: DoryPullLimits = DoryPullLimits(),
        control: DoryPullControl
    ) throws -> DoryPullStats {
        let raw = try withControl {
            try $0.pullControlled(
                remoteRoot: remoteRoot,
                localRoot: localRoot,
                maxFiles: limits.maxFiles,
                maxDirectories: limits.maxDirectories,
                maxBytes: limits.maxBytes,
                control: control.raw
            )
        }
        return DoryPullStats(raw)
    }

    public func snapshotFreeze(receiptID: String) throws -> String {
        try withControl { try $0.snapshotFreeze(receiptId: receiptID) }
    }

    public func snapshotThaw(receiptID: String) throws {
        try withControl { try $0.snapshotThaw(receiptId: receiptID) }
    }

    public func lifecycleReceipt(
        action: DoryLifecycleReceiptAction,
        operationID: String
    ) throws -> String {
        try withControl {
            try $0.lifecycleReceipt(
                action: action.ffiValue,
                operationId: operationID
            )
        }
    }

    public func usbVhciAttach(
        busID: String,
        port: UInt32,
        vsockPort: UInt32,
        deviceID: UInt32,
        speed: UInt32
    ) throws {
        try withControl {
            try $0.usbVhciAttach(
                busId: busID,
                port: port,
                vsockPort: vsockPort,
                deviceId: deviceID,
                speed: speed
            )
        }
    }

    public func usbVhciDetach(busID: String, port: UInt32) throws {
        try withControl { try $0.usbVhciDetach(busId: busID, port: port) }
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

    public func execWithInput(
        argv: [String],
        stdin: Data,
        cwd: String = "",
        env: [DoryExecEnvironment] = [],
        timeoutMs: UInt64 = 30_000,
        outputLimitBytes: UInt64 = 1024 * 1024
    ) throws -> DoryExecResult {
        let raw = try withControl {
            try $0.execWithInput(
                argv: argv,
                cwd: cwd,
                env: env.map(\.ffiValue),
                timeoutMs: timeoutMs,
                outputLimitBytes: outputLimitBytes,
                stdin: stdin
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
            uptimeSeconds: raw.uptimeSecs,
            capabilities: raw.capabilities.map {
                DoryAgentCapability(id: $0.id, version: $0.version)
            }
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

    public func push(
        localRoot: String,
        remoteRoot: String,
        control: DoryPushControl
    ) throws -> DoryPushStats {
        let raw = try withRemote {
            try $0.pushControlled(
                localRoot: localRoot,
                remoteRoot: remoteRoot,
                control: control.raw
            )
        }
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

    public func execWithInput(
        argv: [String],
        stdin: Data,
        cwd: String = "",
        env: [DoryExecEnvironment] = [],
        timeoutMs: UInt64 = 30_000,
        outputLimitBytes: UInt64 = 1024 * 1024
    ) throws -> DoryExecResult {
        let raw = try withRemote {
            try $0.execWithInput(
                argv: argv,
                cwd: cwd,
                env: env.map(\.ffiValue),
                timeoutMs: timeoutMs,
                outputLimitBytes: outputLimitBytes,
                stdin: stdin
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
