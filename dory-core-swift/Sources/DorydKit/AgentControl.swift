import Darwin
import DoryCore
import Foundation

public struct AgentControlConfiguration: Sendable, Equatable {
    public var forwardSocketPath: String?
    public var directSocketPath: String?
    public var cid: UInt32

    public init(forwardSocketPath: String, cid: UInt32 = 3) {
        self.forwardSocketPath = forwardSocketPath
        self.directSocketPath = nil
        self.cid = cid
    }

    public init(directSocketPath: String) {
        self.forwardSocketPath = nil
        self.directSocketPath = directSocketPath
        self.cid = 3
    }
}

public protocol AgentControlClient: Sendable {
    func info() throws -> DoryAgentInfo
    func clockSync(hostEpochNs: Int64) throws -> Bool
    func portsWatch() throws -> DoryPortsSnapshot
    func telemetry() throws -> DoryTelemetry
    func push(localRoot: String, remoteRoot: String) throws -> DoryPushStats
    func push(
        localRoot: String,
        remoteRoot: String,
        control: DoryPushControl
    ) throws -> DoryPushStats
    func pull(
        remoteRoot: String,
        localRoot: String,
        limits: DoryPullLimits
    ) throws -> DoryPullStats
    func pull(
        remoteRoot: String,
        localRoot: String,
        limits: DoryPullLimits,
        control: DoryPullControl
    ) throws -> DoryPullStats
    func snapshotFreeze(receiptID: String) throws -> String
    func snapshotThaw(receiptID: String) throws
    func lifecycleReceipt(
        action: DoryLifecycleReceiptAction,
        operationID: String
    ) throws -> String
    func virtioFSMount(
        tag: String,
        mountPath: String,
        readOnly: Bool
    ) throws -> DoryVirtioFSMountReceipt
    func usbVhciAttach(
        busID: String,
        port: UInt32,
        vsockPort: UInt32,
        deviceID: UInt32,
        speed: UInt32
    ) throws
    func usbVhciDetach(busID: String, port: UInt32) throws
    func exec(
        argv: [String],
        cwd: String,
        env: [DoryExecEnvironment],
        timeoutMs: UInt64,
        outputLimitBytes: UInt64
    ) throws -> DoryExecResult
    func execWithInput(
        argv: [String],
        stdin: Data,
        cwd: String,
        env: [DoryExecEnvironment],
        timeoutMs: UInt64,
        outputLimitBytes: UInt64
    ) throws -> DoryExecResult
    func close()
}

public extension AgentControlClient {
    func usbVhciAttach(
        busID: String,
        port: UInt32,
        vsockPort: UInt32,
        deviceID: UInt32,
        speed: UInt32
    ) throws {
        _ = busID
        _ = port
        _ = vsockPort
        _ = deviceID
        _ = speed
        throw AgentControlError.capabilityUnavailable("usb-vhci")
    }

    func usbVhciDetach(busID: String, port: UInt32) throws {
        _ = busID
        _ = port
        throw AgentControlError.capabilityUnavailable("usb-vhci")
    }

    func virtioFSMount(
        tag: String,
        mountPath: String,
        readOnly: Bool
    ) throws -> DoryVirtioFSMountReceipt {
        _ = tag
        _ = mountPath
        _ = readOnly
        throw AgentControlError.capabilityUnavailable("virtiofs-mount")
    }

    func lifecycleReceipt(
        action: DoryLifecycleReceiptAction,
        operationID: String
    ) throws -> String {
        _ = action
        _ = operationID
        throw AgentControlError.capabilityUnavailable("lifecycle-receipt")
    }

    func snapshotFreeze(receiptID: String) throws -> String {
        _ = receiptID
        throw AgentControlError.capabilityUnavailable("snapshot-quiesce")
    }

    func push(localRoot: String, remoteRoot: String) throws -> DoryPushStats {
        _ = localRoot
        _ = remoteRoot
        throw AgentControlError.capabilityUnavailable("sync-push")
    }

    func push(
        localRoot: String,
        remoteRoot: String,
        control: DoryPushControl
    ) throws -> DoryPushStats {
        _ = localRoot
        _ = remoteRoot
        _ = control
        throw AgentControlError.capabilityUnavailable("sync-push-control")
    }

    func pull(
        remoteRoot: String,
        localRoot: String,
        limits: DoryPullLimits
    ) throws -> DoryPullStats {
        _ = remoteRoot
        _ = localRoot
        _ = limits
        throw AgentControlError.capabilityUnavailable("sync-pull")
    }

    func pull(
        remoteRoot: String,
        localRoot: String,
        limits: DoryPullLimits,
        control: DoryPullControl
    ) throws -> DoryPullStats {
        _ = remoteRoot
        _ = localRoot
        _ = limits
        _ = control
        throw AgentControlError.capabilityUnavailable("sync-pull-control")
    }

    func snapshotThaw(receiptID: String) throws {
        _ = receiptID
        throw AgentControlError.capabilityUnavailable("snapshot-quiesce")
    }

    func execWithInput(
        argv: [String],
        stdin: Data,
        cwd: String,
        env: [DoryExecEnvironment],
        timeoutMs: UInt64,
        outputLimitBytes: UInt64
    ) throws -> DoryExecResult {
        guard stdin.isEmpty else { throw AgentControlError.standardInputUnsupported }
        return try exec(
            argv: argv,
            cwd: cwd,
            env: env,
            timeoutMs: timeoutMs,
            outputLimitBytes: outputLimitBytes
        )
    }
}

extension DoryAgentControlHandle: AgentControlClient {}

public final class AgentControl: @unchecked Sendable {
    public typealias Connector = @Sendable (AgentControlConfiguration) throws -> any AgentControlClient

    private let configuration: AgentControlConfiguration
    private let connector: Connector
    private let lock = NSLock()
    private var client: (any AgentControlClient)?
    private var negotiatedInfo: DoryAgentInfo?

    public init(
        configuration: AgentControlConfiguration,
        connector: @escaping Connector = { configuration in
            if let directSocketPath = configuration.directSocketPath {
                return try LocalAgentControl.connect(socketPath: directSocketPath)
            }
            guard let forwardSocketPath = configuration.forwardSocketPath else {
                throw LocalAgentControlError.missingEndpoint
            }
            return try DoryCore.connectAgentControlOverForward(
                forwardSocketPath: forwardSocketPath,
                cid: configuration.cid
            )
        }
    ) {
        self.configuration = configuration
        self.connector = connector
    }

    public func connect() throws {
        _ = try connectedClient()
    }

    public func info() throws -> DoryAgentInfo {
        let client = try connectedClient()
        return try cachedInfo(from: client)
    }

    public func clockSync(now: Date = Date()) throws -> Bool {
        try clockSync(hostEpochNs: hostEpochNanoseconds(now))
    }

    public func clockSync(hostEpochNs: Int64) throws -> Bool {
        let client = try client(requiring: "clock-sync")
        return try client.clockSync(hostEpochNs: hostEpochNs)
    }

    public func portsWatch() throws -> DoryPortsSnapshot {
        try client(requiring: "ports-watch").portsWatch()
    }

    public func telemetry() throws -> DoryTelemetry {
        try client(requiring: "telemetry").telemetry()
    }

    public func push(localRoot: String, remoteRoot: String) throws -> DoryPushStats {
        try client(requiring: "sync-push").push(
            localRoot: localRoot,
            remoteRoot: remoteRoot
        )
    }

    public func push(
        localRoot: String,
        remoteRoot: String,
        control: DoryPushControl
    ) throws -> DoryPushStats {
        try client(requiring: "sync-push").push(
            localRoot: localRoot,
            remoteRoot: remoteRoot,
            control: control
        )
    }

    public func pull(
        remoteRoot: String,
        localRoot: String,
        limits: DoryPullLimits = DoryPullLimits()
    ) throws -> DoryPullStats {
        try client(requiring: "sync-pull").pull(
            remoteRoot: remoteRoot,
            localRoot: localRoot,
            limits: limits
        )
    }

    public func pull(
        remoteRoot: String,
        localRoot: String,
        limits: DoryPullLimits = DoryPullLimits(),
        control: DoryPullControl
    ) throws -> DoryPullStats {
        try client(requiring: "sync-pull").pull(
            remoteRoot: remoteRoot,
            localRoot: localRoot,
            limits: limits,
            control: control
        )
    }

    public func snapshotFreeze(receiptID: String) throws -> String {
        try client(requiring: "snapshot-quiesce", minimumVersion: 2)
            .snapshotFreeze(receiptID: receiptID)
    }

    public func snapshotThaw(receiptID: String) throws {
        try client(requiring: "snapshot-quiesce", minimumVersion: 2)
            .snapshotThaw(receiptID: receiptID)
    }

    public func lifecycleReceipt(
        action: DoryLifecycleReceiptAction,
        operationID: String
    ) throws -> String {
        try client(requiring: "lifecycle-receipt").lifecycleReceipt(
            action: action,
            operationID: operationID
        )
    }

    /// Mount a host-published virtio-fs device only after the negotiated Dory Tools inventory
    /// advertises `virtiofs-mount@1`. The returned receipt is based on the guest kernel's mountinfo
    /// observation, so callers never treat RPC delivery alone as mount completion.
    public func virtioFSMount(
        tag: String,
        mountPath: String,
        readOnly: Bool
    ) throws -> DoryVirtioFSMountReceipt {
        try client(requiring: "virtiofs-mount").virtioFSMount(
            tag: tag,
            mountPath: mountPath,
            readOnly: readOnly
        )
    }

    /// Attach one host-authorized USB/IP export through the same bounded agent endpoint used by
    /// every other desktop lifecycle RPC. This avoids a second in-process vsock control spine and
    /// requires the guest's negotiated `usb-vhci@1` capability before mutation.
    public func usbVhciAttach(
        busID: String,
        port: UInt32,
        vsockPort: UInt32,
        deviceID: UInt32,
        speed: UInt32
    ) throws {
        try client(requiring: "usb-vhci").usbVhciAttach(
            busID: busID,
            port: port,
            vsockPort: vsockPort,
            deviceID: deviceID,
            speed: speed
        )
    }

    public func usbVhciDetach(busID: String, port: UInt32) throws {
        try client(requiring: "usb-vhci").usbVhciDetach(busID: busID, port: port)
    }

    public func exec(
        argv: [String],
        cwd: String = "",
        env: [DoryExecEnvironment] = [],
        timeoutMs: UInt64 = 30_000,
        outputLimitBytes: UInt64 = 1024 * 1024
    ) throws -> DoryExecResult {
        try client(requiring: "exec").exec(
            argv: argv,
            cwd: cwd,
            env: env,
            timeoutMs: timeoutMs,
            outputLimitBytes: outputLimitBytes
        )
    }

    public func execWithInput(
        argv: [String],
        stdin: Data,
        cwd: String = "",
        env: [DoryExecEnvironment] = [],
        timeoutMs: UInt64 = 30_000,
        outputLimitBytes: UInt64 = 1024 * 1024
    ) throws -> DoryExecResult {
        let client = try client(requiring: "exec")
        try requireCapability("exec-stdin", from: client)
        return try client.execWithInput(
            argv: argv,
            stdin: stdin,
            cwd: cwd,
            env: env,
            timeoutMs: timeoutMs,
            outputLimitBytes: outputLimitBytes
        )
    }

    public func disconnect() {
        lock.lock()
        let current = client
        client = nil
        negotiatedInfo = nil
        lock.unlock()
        current?.close()
    }

    private func connectedClient() throws -> any AgentControlClient {
        lock.lock()
        if let client {
            lock.unlock()
            return client
        }
        lock.unlock()

        let fresh = try connector(configuration)
        lock.lock()
        if client == nil {
            client = fresh
            lock.unlock()
            return fresh
        }
        let existing = client!
        lock.unlock()
        fresh.close()
        return existing
    }

    private func client(
        requiring capability: String,
        minimumVersion: UInt32 = 1
    ) throws -> any AgentControlClient {
        let client = try connectedClient()
        try requireCapability(capability, minimumVersion: minimumVersion, from: client)
        return client
    }

    private func requireCapability(
        _ capability: String,
        minimumVersion: UInt32 = 1,
        from client: any AgentControlClient
    ) throws {
        let info = try cachedInfo(from: client)
        guard info.protocolVersion == DoryCore.protocolVersion() else {
            throw AgentControlError.incompatibleProtocol(
                expected: DoryCore.protocolVersion(),
                actual: info.protocolVersion
            )
        }
        guard info.capabilitiesAreCanonical else {
            throw AgentControlError.invalidCapabilities
        }
        guard info.supports(capability, minimumVersion: minimumVersion) else {
            throw AgentControlError.capabilityUnavailable(capability)
        }
    }

    private func cachedInfo(from client: any AgentControlClient) throws -> DoryAgentInfo {
        lock.lock()
        if let negotiatedInfo {
            lock.unlock()
            return negotiatedInfo
        }
        lock.unlock()

        let fresh = try client.info()
        lock.lock()
        if negotiatedInfo == nil {
            negotiatedInfo = fresh
        }
        let selected = negotiatedInfo!
        lock.unlock()
        return selected
    }

    deinit {
        disconnect()
    }
}

public enum AgentControlError: Error, Sendable, Equatable {
    case standardInputUnsupported
    case incompatibleProtocol(expected: UInt32, actual: UInt32)
    case invalidCapabilities
    case capabilityUnavailable(String)
}

public enum LocalAgentControlError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingEndpoint
    case pathTooLong(String)
    case syscall(String, Int32)

    public var description: String {
        switch self {
        case .missingEndpoint:
            return "agent control endpoint is missing"
        case let .pathTooLong(path):
            return "agent socket path is too long: \(path)"
        case let .syscall(name, code):
            return "\(name): \(String(cString: strerror(code)))"
        }
    }
}

public enum LocalAgentControl {
    public static func connect(socketPath: String) throws -> DoryAgentControlHandle {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LocalAgentControlError.syscall("socket", errno) }

        var shouldClose = true
        defer {
            if shouldClose {
                close(fd)
            }
        }

        var address = try unixAddress(path: socketPath)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                Darwin.connect(fd, raw, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            throw LocalAgentControlError.syscall("connect", errno)
        }

        let handle = try DoryCore.connectAgentControlOverFD(fd)
        shouldClose = false
        return handle
    }

    private static func unixAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw LocalAgentControlError.pathTooLong(path)
        }
        // An empty path yields a nil source base address; guard the copy so a malformed path
        // fails cleanly at connect rather than trapping on a force-unwrap.
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { source in
                guard let destinationBase = destination.baseAddress,
                      let sourceBase = source.baseAddress else { return }
                destinationBase.copyMemory(from: sourceBase, byteCount: bytes.count)
            }
        }
        return address
    }
}

private func hostEpochNanoseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1_000_000_000).rounded())
}
