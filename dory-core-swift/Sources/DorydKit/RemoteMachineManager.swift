import DoryCore
import Foundation
import Security

public protocol SSHKeyStore: Sendable {
    func privateKey(for identifier: String) throws -> String
}

public enum SSHKeyStoreError: Error, Sendable, Equatable {
    case notFound(String)
    case invalidData(String)
    case keychainStatus(OSStatus)
}

public final class KeychainSSHKeyStore: SSHKeyStore, @unchecked Sendable {
    private let service: String

    public init(service: String = "dev.dory.ssh") {
        self.service = service
    }

    public func privateKey(for identifier: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identifier,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else {
            throw SSHKeyStoreError.notFound(identifier)
        }
        guard status == errSecSuccess else {
            throw SSHKeyStoreError.keychainStatus(status)
        }
        guard let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else {
            throw SSHKeyStoreError.invalidData(identifier)
        }
        return key
    }
}

public protocol RemoteAgentClient: Sendable {
    func info() throws -> DoryAgentInfo
    func telemetry() throws -> DoryTelemetry
    func push(localRoot: String, remoteRoot: String) throws -> DoryPushStats
    func exec(
        argv: [String],
        cwd: String,
        env: [DoryExecEnvironment],
        timeoutMs: UInt64,
        outputLimitBytes: UInt64
    ) throws -> DoryExecResult
    func close()
}

extension DoryRemoteAgentHandle: RemoteAgentClient {}

public struct RemoteMachineConfiguration: Sendable, Equatable, Hashable {
    public var id: String
    public var host: String
    public var port: UInt16
    public var user: String
    public var privateKeyID: String
    public var hostKey: DoryRemoteHostKey
    public var endpoint: DoryRemoteEndpoint
    public var remoteRoot: String
    public var build: String

    public init(
        id: String,
        host: String,
        port: UInt16 = 22,
        user: String,
        privateKeyID: String,
        hostKey: DoryRemoteHostKey,
        endpoint: DoryRemoteEndpoint,
        remoteRoot: String,
        build: String = "doryd"
    ) {
        self.id = id
        self.host = host
        self.port = port
        self.user = user
        self.privateKeyID = privateKeyID
        self.hostKey = hostKey
        self.endpoint = endpoint
        self.remoteRoot = remoteRoot
        self.build = build
    }
}

public enum RemoteMachineState: String, Sendable {
    case disconnected
    case connected
    case failed
}

public struct RemoteMachineStatus: Sendable, Equatable {
    public var id: String
    public var state: RemoteMachineState
    public var lastError: String?
    public var info: DoryAgentInfo?
    public var telemetry: DoryTelemetry?
}

public enum RemoteMachineError: Error, Sendable, Equatable {
    case unknownMachine(String)
    case notConnected(String)
}

public final class RemoteMachineManager: @unchecked Sendable {
    public typealias Connector = @Sendable (DoryRemoteConfig) throws -> any RemoteAgentClient

    private let keyStore: SSHKeyStore
    private let connector: Connector
    private let lock = NSLock()
    private var machines: [String: RemoteMachineEntry] = [:]

    public init(
        keyStore: SSHKeyStore = KeychainSSHKeyStore(),
        connector: @escaping Connector = { config in
            try DoryCore.connectRemoteAgent(config: config)
        }
    ) {
        self.keyStore = keyStore
        self.connector = connector
    }

    @discardableResult
    public func connect(_ configuration: RemoteMachineConfiguration) throws -> DoryAgentInfo {
        let privateKey = try keyStore.privateKey(for: configuration.privateKeyID)
        let remoteConfig = DoryRemoteConfig(
            host: configuration.host,
            port: configuration.port,
            user: configuration.user,
            opensshPrivateKey: privateKey,
            hostKey: configuration.hostKey,
            endpoint: configuration.endpoint,
            build: configuration.build
        )

        do {
            let agent = try connector(remoteConfig)
            let info = try agent.info()
            lock.lock()
            machines[configuration.id]?.agent?.close()
            machines[configuration.id] = RemoteMachineEntry(
                configuration: configuration,
                state: .connected,
                agent: agent,
                lastError: nil,
                info: info,
                telemetry: nil
            )
            lock.unlock()
            return info
        } catch {
            lock.lock()
            machines[configuration.id] = RemoteMachineEntry(
                configuration: configuration,
                state: .failed,
                agent: nil,
                lastError: "\(error)",
                info: nil,
                telemetry: nil
            )
            lock.unlock()
            throw error
        }
    }

    public func push(
        id: String,
        localRoot: String,
        remoteRoot: String? = nil
    ) throws -> DoryPushStats {
        let (agent, root) = try connectedAgent(id: id, remoteRoot: remoteRoot)
        return try agent.push(localRoot: localRoot, remoteRoot: root)
    }

    public func telemetry(id: String) throws -> DoryTelemetry {
        let (agent, _) = try connectedAgent(id: id, remoteRoot: nil)
        let telemetry = try agent.telemetry()
        lock.lock()
        machines[id]?.telemetry = telemetry
        lock.unlock()
        return telemetry
    }

    public func exec(
        id: String,
        argv: [String],
        cwd: String = "",
        env: [DoryExecEnvironment] = [],
        timeoutMs: UInt64 = 30_000,
        outputLimitBytes: UInt64 = 1024 * 1024
    ) throws -> DoryExecResult {
        let (agent, _) = try connectedAgent(id: id, remoteRoot: nil)
        return try agent.exec(
            argv: argv,
            cwd: cwd,
            env: env,
            timeoutMs: timeoutMs,
            outputLimitBytes: outputLimitBytes
        )
    }

    public func disconnect(id: String) {
        lock.lock()
        guard var entry = machines[id] else {
            lock.unlock()
            return
        }
        let agent = entry.agent
        entry.agent = nil
        entry.state = .disconnected
        machines[id] = entry
        lock.unlock()
        agent?.close()
    }

    public func disconnectAll() {
        lock.lock()
        let agents = machines.values.compactMap(\.agent)
        for id in machines.keys {
            machines[id]?.agent = nil
            machines[id]?.state = .disconnected
        }
        lock.unlock()

        for agent in agents {
            agent.close()
        }
    }

    public func status(id: String) -> RemoteMachineStatus? {
        lock.lock()
        defer { lock.unlock() }
        return machines[id]?.status(id: id)
    }

    public func list() -> [RemoteMachineStatus] {
        lock.lock()
        let statuses = machines.keys.sorted().compactMap { id in machines[id]?.status(id: id) }
        lock.unlock()
        return statuses
    }

    private func connectedAgent(
        id: String,
        remoteRoot: String?
    ) throws -> (any RemoteAgentClient, String) {
        lock.lock()
        guard let entry = machines[id] else {
            lock.unlock()
            throw RemoteMachineError.unknownMachine(id)
        }
        guard let agent = entry.agent, entry.state == .connected else {
            lock.unlock()
            throw RemoteMachineError.notConnected(id)
        }
        let root = remoteRoot ?? entry.configuration.remoteRoot
        lock.unlock()
        return (agent, root)
    }
}

private struct RemoteMachineEntry {
    var configuration: RemoteMachineConfiguration
    var state: RemoteMachineState
    var agent: (any RemoteAgentClient)?
    var lastError: String?
    var info: DoryAgentInfo?
    var telemetry: DoryTelemetry?

    func status(id: String) -> RemoteMachineStatus {
        RemoteMachineStatus(
            id: id,
            state: state,
            lastError: lastError,
            info: info,
            telemetry: telemetry
        )
    }
}
