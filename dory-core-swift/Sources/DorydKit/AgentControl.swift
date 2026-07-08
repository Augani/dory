import Darwin
import DoryCore
import Foundation

public struct AgentControlConfiguration: Sendable, Equatable {
    public var forwardSocketPath: String
    public var cid: UInt32

    public init(forwardSocketPath: String, cid: UInt32 = 3) {
        self.forwardSocketPath = forwardSocketPath
        self.cid = cid
    }
}

public protocol AgentControlClient: Sendable {
    func info() throws -> DoryAgentInfo
    func clockSync(hostEpochNs: Int64) throws -> Bool
    func portsWatch() throws -> DoryPortsSnapshot
    func telemetry() throws -> DoryTelemetry
    func exec(
        argv: [String],
        cwd: String,
        env: [DoryExecEnvironment],
        timeoutMs: UInt64,
        outputLimitBytes: UInt64
    ) throws -> DoryExecResult
    func close()
}

extension DoryAgentControlHandle: AgentControlClient {}

public final class AgentControl: @unchecked Sendable {
    public typealias Connector = @Sendable (AgentControlConfiguration) throws -> any AgentControlClient

    private let configuration: AgentControlConfiguration
    private let connector: Connector
    private let lock = NSLock()
    private var client: (any AgentControlClient)?

    public init(
        configuration: AgentControlConfiguration,
        connector: @escaping Connector = { configuration in
            try DoryCore.connectAgentControlOverForward(
                forwardSocketPath: configuration.forwardSocketPath,
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
        try connectedClient().info()
    }

    public func clockSync(now: Date = Date()) throws -> Bool {
        try clockSync(hostEpochNs: hostEpochNanoseconds(now))
    }

    public func clockSync(hostEpochNs: Int64) throws -> Bool {
        try connectedClient().clockSync(hostEpochNs: hostEpochNs)
    }

    public func portsWatch() throws -> DoryPortsSnapshot {
        try connectedClient().portsWatch()
    }

    public func telemetry() throws -> DoryTelemetry {
        try connectedClient().telemetry()
    }

    public func exec(
        argv: [String],
        cwd: String = "",
        env: [DoryExecEnvironment] = [],
        timeoutMs: UInt64 = 30_000,
        outputLimitBytes: UInt64 = 1024 * 1024
    ) throws -> DoryExecResult {
        try connectedClient().exec(
            argv: argv,
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

    deinit {
        disconnect()
    }
}

public enum LocalAgentControlError: Error, Sendable, Equatable, CustomStringConvertible {
    case pathTooLong(String)
    case syscall(String, Int32)

    public var description: String {
        switch self {
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
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { source in
                destination.baseAddress!.copyMemory(from: source.baseAddress!, byteCount: bytes.count)
            }
        }
        return address
    }
}

private func hostEpochNanoseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1_000_000_000).rounded())
}
