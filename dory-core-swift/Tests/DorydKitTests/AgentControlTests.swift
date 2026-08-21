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
        XCTAssertEqual(info.capabilities.map(\.id), [
            "clock-sync", "exec", "exec-stdin", "ports-watch", "snapshot-quiesce", "telemetry",
        ])
        XCTAssertEqual(counter.value, 1)

        XCTAssertFalse(try control.clockSync(now: Date(timeIntervalSince1970: 1.5)))
        XCTAssertEqual(fake.clockSyncInputs, [1_500_000_000])
        XCTAssertEqual(try control.portsWatch().ports.first?.port, 8080)
        XCTAssertEqual(try control.telemetry().memTotalKB, 1024)
        let receiptID = String(repeating: "a", count: 32)
        XCTAssertEqual(try control.snapshotFreeze(receiptID: receiptID), receiptID)
        try control.snapshotThaw(receiptID: receiptID)
        XCTAssertEqual(fake.snapshotFreezeReceipts, [receiptID])
        XCTAssertEqual(fake.snapshotThawReceipts, [receiptID])
        let exec = try control.exec(argv: ["/bin/echo", "ok"], cwd: "/tmp")
        XCTAssertEqual(exec.exitCode, 0)
        XCTAssertEqual(String(data: exec.stdout, encoding: .utf8), "ok\n")
        XCTAssertThrowsError(try control.execWithInput(
            argv: ["/bin/cat"],
            stdin: Data("payload".utf8)
        ))
        XCTAssertEqual(counter.value, 1)

        control.disconnect()
        XCTAssertEqual(fake.closeCount, 1)
    }

    func testAgentControlRejectsMissingInvalidAndIncompatibleCapabilitiesBeforeCallingOperation() throws {
        let missing = FakeAgentControlClient(
            capabilities: [DoryAgentCapability(id: "exec", version: 1)]
        )
        let missingControl = AgentControl(
            configuration: AgentControlConfiguration(directSocketPath: "/tmp/missing.sock"),
            connector: { _ in missing }
        )
        XCTAssertThrowsError(try missingControl.telemetry()) { error in
            XCTAssertEqual(error as? AgentControlError, .capabilityUnavailable("telemetry"))
        }
        XCTAssertEqual(missing.telemetryCalls, 0)

        let oldSnapshotCapability = FakeAgentControlClient(capabilities: [
            DoryAgentCapability(id: "snapshot-quiesce", version: 1),
        ])
        let oldSnapshotControl = AgentControl(
            configuration: AgentControlConfiguration(directSocketPath: "/tmp/old-snapshot.sock"),
            connector: { _ in oldSnapshotCapability }
        )
        XCTAssertThrowsError(try oldSnapshotControl.snapshotFreeze(
            receiptID: String(repeating: "b", count: 32)
        )) { error in
            XCTAssertEqual(
                error as? AgentControlError,
                .capabilityUnavailable("snapshot-quiesce")
            )
        }
        XCTAssertTrue(oldSnapshotCapability.snapshotFreezeReceipts.isEmpty)

        let invalid = FakeAgentControlClient(capabilities: [
            DoryAgentCapability(id: "exec", version: 1),
            DoryAgentCapability(id: "exec", version: 1),
        ])
        let invalidControl = AgentControl(
            configuration: AgentControlConfiguration(directSocketPath: "/tmp/invalid.sock"),
            connector: { _ in invalid }
        )
        XCTAssertThrowsError(try invalidControl.exec(argv: ["/bin/true"])) { error in
            XCTAssertEqual(error as? AgentControlError, .invalidCapabilities)
        }

        let incompatible = FakeAgentControlClient(
            protocolVersion: DoryCore.protocolVersion() + 1
        )
        let incompatibleControl = AgentControl(
            configuration: AgentControlConfiguration(directSocketPath: "/tmp/incompatible.sock"),
            connector: { _ in incompatible }
        )
        XCTAssertThrowsError(try incompatibleControl.clockSync()) { error in
            XCTAssertEqual(
                error as? AgentControlError,
                .incompatibleProtocol(
                    expected: DoryCore.protocolVersion(),
                    actual: DoryCore.protocolVersion() + 1
                )
            )
        }
        XCTAssertTrue(incompatible.clockSyncInputs.isEmpty)
    }
}

private final class FakeAgentControlClient: AgentControlClient, @unchecked Sendable {
    private let lock = NSLock()
    private let protocolVersion: UInt32
    private let capabilities: [DoryAgentCapability]
    private var inputs: [Int64] = []
    private var closes = 0
    private var telemetryCallCount = 0
    private var freezeReceipts: [String] = []
    private var thawReceipts: [String] = []

    init(
        protocolVersion: UInt32 = DoryCore.protocolVersion(),
        capabilities: [DoryAgentCapability] = [
            DoryAgentCapability(id: "clock-sync", version: 1),
            DoryAgentCapability(id: "exec", version: 1),
            DoryAgentCapability(id: "exec-stdin", version: 1),
            DoryAgentCapability(id: "ports-watch", version: 1),
            DoryAgentCapability(id: "snapshot-quiesce", version: 2),
            DoryAgentCapability(id: "telemetry", version: 1),
        ]
    ) {
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
    }

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

    var telemetryCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return telemetryCallCount
    }

    var snapshotFreezeReceipts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return freezeReceipts
    }

    var snapshotThawReceipts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return thawReceipts
    }

    func info() throws -> DoryAgentInfo {
        DoryAgentInfo(
            protocolVersion: protocolVersion,
            kernel: "Linux fake",
            agentBuild: "fake-agent",
            uptimeSeconds: 42,
            capabilities: capabilities
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
        lock.lock()
        telemetryCallCount += 1
        lock.unlock()
        return DoryTelemetry(
            memTotalKB: 1024,
            memAvailableKB: 512,
            psiSomeAvg10: 0,
            psiFullAvg10: 0
        )
    }

    func snapshotFreeze(receiptID: String) throws -> String {
        lock.lock()
        freezeReceipts.append(receiptID)
        lock.unlock()
        return receiptID
    }

    func snapshotThaw(receiptID: String) throws {
        lock.lock()
        thawReceipts.append(receiptID)
        lock.unlock()
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
