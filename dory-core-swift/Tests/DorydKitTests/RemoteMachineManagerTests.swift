import DoryCore
@testable import DorydKit
import XCTest

final class RemoteMachineManagerTests: XCTestCase {
    func testConnectPushTelemetryAndDisconnectRemoteMachine() throws {
        let keyStore = FakeSSHKeyStore(keys: ["primary": "OPENSSH-PRIVATE-KEY"])
        let fake = FakeRemoteAgentClient()
        let captured = LockedRemoteConfig()
        let manager = RemoteMachineManager(keyStore: keyStore) { config in
            captured.value = config
            return fake
        }
        let machine = RemoteMachineConfiguration(
            id: "prod",
            host: "vps.example.com",
            port: 2222,
            user: "dory",
            privateKeyID: "primary",
            hostKey: .pinned(opensshPublicKey: "ssh-ed25519 AAAA fake"),
            endpoint: .unixSocket(path: "/run/dory/agent.sock"),
            remoteRoot: "/srv/app",
            build: "doryd-test"
        )

        let info = try manager.connect(machine)
        XCTAssertEqual(info.agentBuild, "remote-agent")
        XCTAssertEqual(captured.value?.opensshPrivateKey, "OPENSSH-PRIVATE-KEY")
        XCTAssertEqual(captured.value?.host, "vps.example.com")
        XCTAssertEqual(manager.status(id: "prod")?.state, .connected)

        let stats = try manager.push(id: "prod", localRoot: "/tmp/local")
        XCTAssertEqual(stats.filesSent, 2)
        XCTAssertEqual(fake.pushes, [FakeRemoteAgentClient.Push(localRoot: "/tmp/local", remoteRoot: "/srv/app")])

        let telemetry = try manager.telemetry(id: "prod")
        XCTAssertEqual(telemetry.memTotalKB, 2048)
        XCTAssertEqual(manager.status(id: "prod")?.telemetry, telemetry)

        let exec = try manager.exec(id: "prod", argv: ["/bin/true"])
        XCTAssertEqual(exec.exitCode, 0)
        XCTAssertEqual(String(data: exec.stdout, encoding: .utf8), "remote-exec-ok\n")

        manager.disconnect(id: "prod")
        XCTAssertEqual(manager.status(id: "prod")?.state, .disconnected)
        XCTAssertEqual(fake.closeCount, 1)
    }

    func testConnectClosesLiveAgentWhenInfoFails() {
        let keyStore = FakeSSHKeyStore(keys: ["primary": "OPENSSH-PRIVATE-KEY"])
        let fake = FakeRemoteAgentClient(infoError: FakeConnectError.boom)
        let manager = RemoteMachineManager(keyStore: keyStore) { _ in fake }
        let machine = RemoteMachineConfiguration(
            id: "prod",
            host: "vps.example.com",
            user: "dory",
            privateKeyID: "primary",
            hostKey: .pinned(opensshPublicKey: "ssh-ed25519 AAAA fake"),
            endpoint: .unixSocket(path: "/run/dory/agent.sock"),
            remoteRoot: "/srv/app"
        )

        XCTAssertThrowsError(try manager.connect(machine))
        XCTAssertEqual(fake.closeCount, 1)
        XCTAssertEqual(manager.status(id: "prod")?.state, .failed)
    }

    func testUnknownRemoteMachineCannotPush() {
        let manager = RemoteMachineManager(keyStore: FakeSSHKeyStore(keys: [:])) { _ in
            FakeRemoteAgentClient()
        }

        XCTAssertThrowsError(try manager.push(id: "missing", localRoot: "/tmp/local")) { error in
            XCTAssertEqual(error as? RemoteMachineError, .unknownMachine("missing"))
        }
    }

    func testRemoteOperationsRequireAdvertisedCapabilitiesBeforeCallingAgent() throws {
        let fake = FakeRemoteAgentClient(capabilities: [
            DoryAgentCapability(id: "exec", version: 1),
        ])
        let manager = RemoteMachineManager(
            keyStore: FakeSSHKeyStore(keys: ["primary": "OPENSSH-PRIVATE-KEY"]),
            connector: { _ in fake }
        )
        _ = try manager.connect(testConfiguration())

        XCTAssertThrowsError(try manager.push(id: "prod", localRoot: "/tmp/local")) { error in
            XCTAssertEqual(
                error as? RemoteMachineError,
                .capabilityUnavailable("prod", "sync-push")
            )
        }
        XCTAssertThrowsError(try manager.telemetry(id: "prod")) { error in
            XCTAssertEqual(
                error as? RemoteMachineError,
                .capabilityUnavailable("prod", "telemetry")
            )
        }
        XCTAssertTrue(fake.pushes.isEmpty)
        XCTAssertEqual(fake.telemetryCalls, 0)
    }

    func testRemoteConnectRejectsInvalidOrIncompatibleHandshakeAndClosesAgent() {
        for fixture in [
            FakeRemoteAgentClient(
                capabilities: [
                    DoryAgentCapability(id: "exec", version: 1),
                    DoryAgentCapability(id: "exec", version: 1),
                ]
            ),
            FakeRemoteAgentClient(protocolVersion: DoryCore.protocolVersion() + 1),
        ] {
            let manager = RemoteMachineManager(
                keyStore: FakeSSHKeyStore(keys: ["primary": "OPENSSH-PRIVATE-KEY"]),
                connector: { _ in fixture }
            )
            XCTAssertThrowsError(try manager.connect(testConfiguration()))
            XCTAssertEqual(fixture.closeCount, 1)
            XCTAssertEqual(manager.status(id: "prod")?.state, .failed)
        }
    }

    private func testConfiguration() -> RemoteMachineConfiguration {
        RemoteMachineConfiguration(
            id: "prod",
            host: "vps.example.com",
            user: "dory",
            privateKeyID: "primary",
            hostKey: .pinned(opensshPublicKey: "ssh-ed25519 AAAA fake"),
            endpoint: .unixSocket(path: "/run/dory/agent.sock"),
            remoteRoot: "/srv/app"
        )
    }
}

private enum FakeConnectError: Error {
    case boom
}

private final class FakeSSHKeyStore: SSHKeyStore, @unchecked Sendable {
    private let keys: [String: String]

    init(keys: [String: String]) {
        self.keys = keys
    }

    func privateKey(for identifier: String) throws -> String {
        guard let key = keys[identifier] else {
            throw SSHKeyStoreError.notFound(identifier)
        }
        return key
    }
}

private final class FakeRemoteAgentClient: RemoteAgentClient, @unchecked Sendable {
    struct Push: Equatable {
        var localRoot: String
        var remoteRoot: String
    }

    private let lock = NSLock()
    private var storedPushes: [Push] = []
    private var closes = 0
    private var storedTelemetryCalls = 0
    private let infoError: Error?
    private let protocolVersion: UInt32
    private let capabilities: [DoryAgentCapability]

    init(
        infoError: Error? = nil,
        protocolVersion: UInt32 = DoryCore.protocolVersion(),
        capabilities: [DoryAgentCapability] = [
            DoryAgentCapability(id: "exec", version: 1),
            DoryAgentCapability(id: "sync-push", version: 1),
            DoryAgentCapability(id: "telemetry", version: 1),
        ]
    ) {
        self.infoError = infoError
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
    }

    var pushes: [Push] {
        lock.lock()
        defer { lock.unlock() }
        return storedPushes
    }

    var closeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return closes
    }

    var telemetryCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedTelemetryCalls
    }

    func info() throws -> DoryAgentInfo {
        if let infoError {
            throw infoError
        }
        return DoryAgentInfo(
            protocolVersion: protocolVersion,
            kernel: "Linux remote",
            agentBuild: "remote-agent",
            uptimeSeconds: 99,
            capabilities: capabilities
        )
    }

    func telemetry() throws -> DoryTelemetry {
        lock.lock()
        storedTelemetryCalls += 1
        lock.unlock()
        return DoryTelemetry(
            memTotalKB: 2048,
            memAvailableKB: 1024,
            psiSomeAvg10: 0.5,
            psiFullAvg10: 0
        )
    }

    func push(localRoot: String, remoteRoot: String) throws -> DoryPushStats {
        lock.lock()
        storedPushes.append(Push(localRoot: localRoot, remoteRoot: remoteRoot))
        lock.unlock()
        return DoryPushStats(filesSent: 2, bytesSent: 12, filesDeleted: 1)
    }

    func exec(
        argv: [String],
        cwd: String,
        env: [DoryExecEnvironment],
        timeoutMs: UInt64,
        outputLimitBytes: UInt64
    ) throws -> DoryExecResult {
        DoryExecResult(
            exitCode: 0,
            stdout: Data("remote-exec-ok\n".utf8),
            stderr: Data(),
            timedOut: false,
            stdoutTruncated: false,
            stderrTruncated: false
        )
    }

    func close() {
        lock.lock()
        closes += 1
        lock.unlock()
    }
}

private final class LockedRemoteConfig: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: DoryRemoteConfig?

    var value: DoryRemoteConfig? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}
