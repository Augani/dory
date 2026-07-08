import DoryCore
@testable import DorydKit
import Foundation
import XCTest

final class AgentControlTests: XCTestCase {
    func testAgentControlConnectsLazilyAndReusesClient() throws {
        let fake = FakeAgentControlClient()
        let counter = LockedCounter()
        let expected = AgentControlConfiguration(forwardSocketPath: "/tmp/forward.sock", cid: 7)
        let control = AgentControl(configuration: expected) { configuration in
            XCTAssertEqual(configuration, expected)
            counter.increment()
            return fake
        }

        XCTAssertEqual(counter.value, 0)
        let info = try control.info()
        XCTAssertEqual(info.agentBuild, "fake-agent")
        XCTAssertEqual(counter.value, 1)

        XCTAssertFalse(try control.clockSync(now: Date(timeIntervalSince1970: 1.5)))
        XCTAssertEqual(fake.clockSyncInputs, [1_500_000_000])
        XCTAssertEqual(try control.telemetry().memTotalKB, 1024)
        let exec = try control.exec(argv: ["/bin/echo", "ok"], cwd: "/tmp")
        XCTAssertEqual(exec.exitCode, 0)
        XCTAssertEqual(String(data: exec.stdout, encoding: .utf8), "ok\n")
        XCTAssertEqual(counter.value, 1)

        control.disconnect()
        XCTAssertEqual(fake.closeCount, 1)
    }
}

private final class FakeAgentControlClient: AgentControlClient, @unchecked Sendable {
    private let lock = NSLock()
    private var inputs: [Int64] = []
    private var closes = 0

    var clockSyncInputs: [Int64] {
        lock.lock()
        defer { lock.unlock() }
        return inputs
    }

    var closeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return closes
    }

    func info() throws -> DoryAgentInfo {
        DoryAgentInfo(
            protocolVersion: 1,
            kernel: "Linux fake",
            agentBuild: "fake-agent",
            uptimeSeconds: 42
        )
    }

    func clockSync(hostEpochNs: Int64) throws -> Bool {
        lock.lock()
        inputs.append(hostEpochNs)
        lock.unlock()
        return false
    }

    func portsWatch() throws -> DoryPortsSnapshot {
        DoryPortsSnapshot(
            ports: [DoryListenPort(protocol: "tcp", port: 8080)],
            added: [],
            removed: []
        )
    }

    func telemetry() throws -> DoryTelemetry {
        DoryTelemetry(
            memTotalKB: 1024,
            memAvailableKB: 512,
            psiSomeAvg10: 0,
            psiFullAvg10: 0
        )
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
            stdout: Data("ok\n".utf8),
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

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func increment() {
        lock.lock()
        stored += 1
        lock.unlock()
    }
}
