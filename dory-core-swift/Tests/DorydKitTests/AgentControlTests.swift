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
            "clock-sync", "exec", "exec-stdin", "lifecycle-receipt", "ports-watch",
            "snapshot-quiesce", "sync-pull", "sync-push", "telemetry", "usb-vhci",
            "virtiofs-mount",
        ])
        XCTAssertEqual(counter.value, 1)

        XCTAssertFalse(try control.clockSync(now: Date(timeIntervalSince1970: 1.5)))
        XCTAssertEqual(fake.clockSyncInputs, [1_500_000_000])
        XCTAssertEqual(try control.portsWatch().ports.first?.port, 8080)
        XCTAssertEqual(try control.telemetry().memTotalKB, 1024)
        XCTAssertEqual(
            try control.push(localRoot: "/tmp/local", remoteRoot: "/tmp/remote"),
            DoryPushStats(filesSent: 1, bytesSent: 12, filesDeleted: 0)
        )
        XCTAssertEqual(
            try control.push(
                localRoot: "/tmp/local",
                remoteRoot: "/tmp/remote",
                control: DoryPushControl()
            ),
            DoryPushStats(filesSent: 1, bytesSent: 12, filesDeleted: 0)
        )
        XCTAssertEqual(fake.controlledPushes, 1)
        let pullLimits = DoryPullLimits(maxFiles: 7, maxDirectories: 8, maxBytes: 9)
        XCTAssertEqual(
            try control.pull(
                remoteRoot: "/guest/source",
                localRoot: "/tmp/pulled",
                limits: pullLimits
            ),
            DoryPullStats(filesReceived: 2, directoriesReceived: 1, bytesReceived: 12)
        )
        XCTAssertEqual(
            try control.pull(
                remoteRoot: "/guest/source",
                localRoot: "/tmp/pulled",
                limits: pullLimits,
                control: DoryPullControl()
            ),
            DoryPullStats(filesReceived: 2, directoriesReceived: 1, bytesReceived: 12)
        )
        XCTAssertEqual(fake.controlledPulls, 1)
        XCTAssertEqual(fake.pullLimits, [pullLimits, pullLimits])
        let receiptID = String(repeating: "a", count: 32)
        XCTAssertEqual(try control.snapshotFreeze(receiptID: receiptID), receiptID)
        try control.snapshotThaw(receiptID: receiptID)
        XCTAssertEqual(fake.snapshotFreezeReceipts, [receiptID])
        XCTAssertEqual(fake.snapshotThawReceipts, [receiptID])
        let operationID = "12345678-1234-4234-8234-123456789abc"
        XCTAssertEqual(
            try control.lifecycleReceipt(
                action: .preparePause,
                operationID: operationID
            ),
            operationID
        )
        XCTAssertEqual(
            fake.lifecycleReceipts,
            [.init(action: .preparePause, operationID: operationID)]
        )
        XCTAssertEqual(
            try control.virtioFSMount(
                tag: "workspace",
                mountPath: "/mnt/dory/workspace",
                readOnly: true
            ),
            DoryVirtioFSMountReceipt(
                tag: "workspace",
                mountPath: "/mnt/dory/workspace",
                readOnly: true,
                alreadyMounted: false,
                mountID: 73
            )
        )
        XCTAssertEqual(fake.virtioFSMountCalls, [
            .init(tag: "workspace", mountPath: "/mnt/dory/workspace", readOnly: true),
        ])
        try control.usbVhciAttach(
            busID: "255-1",
            port: 2,
            vsockPort: 1_025,
            deviceID: (255 << 16) | 1,
            speed: 3
        )
        try control.usbVhciDetach(busID: "255-1", port: 2)
        XCTAssertEqual(fake.usbVhciAttachCalls, [
            .init(busID: "255-1", port: 2, vsockPort: 1_025, deviceID: (255 << 16) | 1, speed: 3),
        ])
        XCTAssertEqual(fake.usbVhciDetachCalls, [
            .init(busID: "255-1", port: 2),
        ])
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
        XCTAssertThrowsError(try missingControl.virtioFSMount(
            tag: "workspace",
            mountPath: "/mnt/dory/workspace",
            readOnly: false
        )) { error in
            XCTAssertEqual(
                error as? AgentControlError,
                .capabilityUnavailable("virtiofs-mount")
            )
        }
        XCTAssertTrue(missing.virtioFSMountCalls.isEmpty)
        XCTAssertThrowsError(try missingControl.usbVhciAttach(
            busID: "255-1",
            port: 0,
            vsockPort: 1_025,
            deviceID: (255 << 16) | 1,
            speed: 3
        )) { error in
            XCTAssertEqual(error as? AgentControlError, .capabilityUnavailable("usb-vhci"))
        }
        XCTAssertTrue(missing.usbVhciAttachCalls.isEmpty)

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
    private var controlledPushCallCount = 0
    private var controlledPullCallCount = 0
    private var receivedPullLimits: [DoryPullLimits] = []
    private var freezeReceipts: [String] = []
    private var thawReceipts: [String] = []
    struct LifecycleReceipt: Equatable {
        var action: DoryLifecycleReceiptAction
        var operationID: String
    }
    private var receivedLifecycleReceipts: [LifecycleReceipt] = []
    struct VirtioFSMountCall: Equatable {
        var tag: String
        var mountPath: String
        var readOnly: Bool
    }
    private var receivedVirtioFSMountCalls: [VirtioFSMountCall] = []
    struct UsbVhciAttachCall: Equatable {
        var busID: String
        var port: UInt32
        var vsockPort: UInt32
        var deviceID: UInt32
        var speed: UInt32
    }
    struct UsbVhciDetachCall: Equatable {
        var busID: String
        var port: UInt32
    }
    private var receivedUsbVhciAttachCalls: [UsbVhciAttachCall] = []
    private var receivedUsbVhciDetachCalls: [UsbVhciDetachCall] = []

    init(
        protocolVersion: UInt32 = DoryCore.protocolVersion(),
        capabilities: [DoryAgentCapability] = [
            DoryAgentCapability(id: "clock-sync", version: 1),
            DoryAgentCapability(id: "exec", version: 1),
            DoryAgentCapability(id: "exec-stdin", version: 1),
            DoryAgentCapability(id: "lifecycle-receipt", version: 1),
            DoryAgentCapability(id: "ports-watch", version: 1),
            DoryAgentCapability(id: "snapshot-quiesce", version: 2),
            DoryAgentCapability(id: "sync-pull", version: 1),
            DoryAgentCapability(id: "sync-push", version: 1),
            DoryAgentCapability(id: "telemetry", version: 1),
            DoryAgentCapability(id: "usb-vhci", version: 1),
            DoryAgentCapability(id: "virtiofs-mount", version: 1),
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

    var controlledPushes: Int {
        lock.lock()
        defer { lock.unlock() }
        return controlledPushCallCount
    }

    var controlledPulls: Int {
        lock.lock()
        defer { lock.unlock() }
        return controlledPullCallCount
    }

    var pullLimits: [DoryPullLimits] {
        lock.lock()
        defer { lock.unlock() }
        return receivedPullLimits
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

    var lifecycleReceipts: [LifecycleReceipt] {
        lock.lock()
        defer { lock.unlock() }
        return receivedLifecycleReceipts
    }

    var virtioFSMountCalls: [VirtioFSMountCall] {
        lock.lock()
        defer { lock.unlock() }
        return receivedVirtioFSMountCalls
    }

    var usbVhciAttachCalls: [UsbVhciAttachCall] {
        lock.lock()
        defer { lock.unlock() }
        return receivedUsbVhciAttachCalls
    }

    var usbVhciDetachCalls: [UsbVhciDetachCall] {
        lock.lock()
        defer { lock.unlock() }
        return receivedUsbVhciDetachCalls
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

    func push(localRoot: String, remoteRoot: String) throws -> DoryPushStats {
        XCTAssertEqual(localRoot, "/tmp/local")
        XCTAssertEqual(remoteRoot, "/tmp/remote")
        return DoryPushStats(filesSent: 1, bytesSent: 12, filesDeleted: 0)
    }

    func push(
        localRoot: String,
        remoteRoot: String,
        control: DoryPushControl
    ) throws -> DoryPushStats {
        _ = control
        lock.lock()
        controlledPushCallCount += 1
        lock.unlock()
        return try push(localRoot: localRoot, remoteRoot: remoteRoot)
    }

    func pull(
        remoteRoot: String,
        localRoot: String,
        limits: DoryPullLimits
    ) throws -> DoryPullStats {
        XCTAssertEqual(remoteRoot, "/guest/source")
        XCTAssertEqual(localRoot, "/tmp/pulled")
        lock.lock()
        receivedPullLimits.append(limits)
        lock.unlock()
        return DoryPullStats(filesReceived: 2, directoriesReceived: 1, bytesReceived: 12)
    }

    func pull(
        remoteRoot: String,
        localRoot: String,
        limits: DoryPullLimits,
        control: DoryPullControl
    ) throws -> DoryPullStats {
        _ = control
        lock.lock()
        controlledPullCallCount += 1
        lock.unlock()
        return try pull(remoteRoot: remoteRoot, localRoot: localRoot, limits: limits)
    }

    func snapshotThaw(receiptID: String) throws {
        lock.lock()
        thawReceipts.append(receiptID)
        lock.unlock()
    }

    func lifecycleReceipt(
        action: DoryLifecycleReceiptAction,
        operationID: String
    ) throws -> String {
        lock.lock()
        receivedLifecycleReceipts.append(.init(
            action: action,
            operationID: operationID
        ))
        lock.unlock()
        return operationID
    }

    func virtioFSMount(
        tag: String,
        mountPath: String,
        readOnly: Bool
    ) throws -> DoryVirtioFSMountReceipt {
        lock.lock()
        receivedVirtioFSMountCalls.append(.init(
            tag: tag,
            mountPath: mountPath,
            readOnly: readOnly
        ))
        lock.unlock()
        return DoryVirtioFSMountReceipt(
            tag: tag,
            mountPath: mountPath,
            readOnly: readOnly,
            alreadyMounted: false,
            mountID: 73
        )
    }

    func usbVhciAttach(
        busID: String,
        port: UInt32,
        vsockPort: UInt32,
        deviceID: UInt32,
        speed: UInt32
    ) throws {
        lock.lock()
        receivedUsbVhciAttachCalls.append(.init(
            busID: busID,
            port: port,
            vsockPort: vsockPort,
            deviceID: deviceID,
            speed: speed
        ))
        lock.unlock()
    }

    func usbVhciDetach(busID: String, port: UInt32) throws {
        lock.lock()
        receivedUsbVhciDetachCalls.append(.init(busID: busID, port: port))
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
