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

    func testUnknownRemoteMachineCannotPush() {
        let manager = RemoteMachineManager(keyStore: FakeSSHKeyStore(keys: [:])) { _ in
            FakeRemoteAgentClient()
        }

        XCTAssertThrowsError(try manager.push(id: "missing", localRoot: "/tmp/local")) { error in
            XCTAssertEqual(error as? RemoteMachineError, .unknownMachine("missing"))
        }
    }
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

    func info() throws -> DoryAgentInfo {
        DoryAgentInfo(
            protocolVersion: 1,
            kernel: "Linux remote",
            agentBuild: "remote-agent",
            uptimeSeconds: 99
        )
    }

    func telemetry() throws -> DoryTelemetry {
        DoryTelemetry(
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
