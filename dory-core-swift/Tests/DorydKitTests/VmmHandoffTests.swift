import Darwin
import DoryCore
import DoryOperations
@testable import DorydKit
import XCTest

final class VmmHandoffTests: XCTestCase {
    func testResolvedSoftwareGraphicsSelectionRoundTripsAsLiveAuthority() throws {
        let operationID = UUID()
        let planSHA256 = String(repeating: "a", count: 64)
        let selection = DoryRuntimeGraphicsSelection.resolvedSoftware(
            operationID: operationID,
            resolvedPlanSHA256: planSHA256,
            planRevision: 7
        )

        XCTAssertTrue(selection.isValid)
        XCTAssertTrue(selection.matchesResolvedRawHVLaunch(
            operationID: operationID,
            planSHA256: planSHA256,
            planRevision: 7,
            accelerationLevel: .software
        ))

        let encoded = try JSONEncoder().encode(VmmReadyMessage(
            machineID: "dev",
            operationID: operationID.uuidString.lowercased(),
            graphicsSelection: selection
        ))
        let decoded = try JSONDecoder().decode(VmmReadyMessage.self, from: encoded)
        XCTAssertEqual(decoded.graphicsSelection, selection)
    }

    func testAcceleratedGraphicsSelectionRequiresBothRendererAndGuestFenceProofs() {
        let operationID = UUID().uuidString.lowercased()
        let planSHA256 = String(repeating: "a", count: 64)
        let rendererReceipt = String(repeating: "b", count: 64)
        let guestFenceProof = String(repeating: "c", count: 64)

        let missingFence = DoryRuntimeGraphicsSelection(
            operationID: operationID,
            resolvedPlanSHA256: planSHA256,
            planRevision: 1,
            accelerationLevel: .hardwareAccelerated3D,
            backend: .virglVenus,
            rendererGeneration: 1,
            rendererWorkerReceiptSHA256: rendererReceipt
        )
        XCTAssertFalse(missingFence.isValid)

        let missingRenderer = DoryRuntimeGraphicsSelection(
            operationID: operationID,
            resolvedPlanSHA256: planSHA256,
            planRevision: 1,
            accelerationLevel: .hardwareAccelerated3D,
            backend: .virglVenus,
            rendererGeneration: 1,
            guestProducerFenceProofSHA256: guestFenceProof
        )
        XCTAssertFalse(missingRenderer.isValid)

        let complete = DoryRuntimeGraphicsSelection(
            operationID: operationID,
            resolvedPlanSHA256: planSHA256,
            planRevision: 1,
            accelerationLevel: .hardwareAccelerated3D,
            backend: .virglVenus,
            rendererGeneration: 1,
            rendererWorkerReceiptSHA256: rendererReceipt,
            guestProducerFenceProofSHA256: guestFenceProof
        )
        XCTAssertTrue(complete.isValid)
    }

    func testReceivesReadyMessageAndFileDescriptor() throws {
        let base = "/tmp/dory-vmm-handoff-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let got = DispatchSemaphore(value: 0)
        let resultBox = LockedHandoffResult()
        let server = VmmHandoffServer(path: base + "/handoff.sock") { result in
            resultBox.result = result
            got.signal()
        }
        try server.start()
        defer { server.stop() }

        let fd = open("/dev/null", O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }

        try VmmHandoffClient.send(
            path: server.path,
            ready: VmmReadyMessage(
                machineID: "dev",
                operationID: "01234567-89ab-4cde-8f01-23456789abcd",
                agentBuild: "dory-agent/test",
                agentProtocolVersion: 1,
                agentCapabilities: [DoryAgentCapability(id: "exec", version: 1)],
                agentSocketPath: "/run/agent.sock",
                dockerdSocketPath: "/run/docker.sock",
                shellSocketPath: "/run/shell.sock",
                detail: "ready"
            ),
            fileDescriptors: [fd]
        )

        XCTAssertEqual(got.wait(timeout: .now() + 2), .success)
        let handoff = try resultBox.get()
        XCTAssertEqual(handoff.ready.machineID, "dev")
        XCTAssertEqual(
            handoff.ready.operationID,
            "01234567-89ab-4cde-8f01-23456789abcd"
        )
        XCTAssertEqual(handoff.ready.agentBuild, "dory-agent/test")
        XCTAssertEqual(handoff.ready.agentProtocolVersion, 1)
        XCTAssertEqual(
            handoff.ready.agentCapabilities,
            [DoryAgentCapability(id: "exec", version: 1)]
        )
        XCTAssertEqual(handoff.ready.agentSocketPath, "/run/agent.sock")
        XCTAssertEqual(handoff.ready.shellSocketPath, "/run/shell.sock")
        XCTAssertEqual(handoff.fileDescriptors.count, 1)
        XCTAssertNotEqual(fcntl(handoff.fileDescriptors[0], F_GETFD), -1)
    }

    func testStoppingOldServerDoesNotUnlinkReplacementSocket() throws {
        let base = "/tmp/dory-vmm-handoff-replace-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let path = base + "/handoff.sock"
        let old = VmmHandoffServer(path: path) { _ in }
        let received = DispatchSemaphore(value: 0)
        let resultBox = LockedHandoffResult()
        let replacement = VmmHandoffServer(path: path) { result in
            resultBox.result = result
            received.signal()
        }

        try old.start()
        try replacement.start()
        defer { replacement.stop() }
        old.stop()

        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        try VmmHandoffClient.send(
            path: path,
            ready: VmmReadyMessage(
                machineID: "replacement",
                operationID: "01234567-89ab-4cde-8f01-23456789abcd"
            ),
            fileDescriptors: []
        )
        XCTAssertEqual(received.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(try resultBox.get().ready.machineID, "replacement")
    }

    func testReceiverRejectsReadinessWithoutOperationIdentity() throws {
        let base = "/tmp/dory-vmm-handoff-operation-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let received = DispatchSemaphore(value: 0)
        let resultBox = LockedHandoffResult()
        let server = VmmHandoffServer(path: base + "/handoff.sock") { result in
            resultBox.result = result
            received.signal()
        }
        try server.start()
        defer { server.stop() }

        try VmmHandoffClient.send(
            path: server.path,
            ready: VmmReadyMessage(machineID: "dev"),
            fileDescriptors: []
        )
        XCTAssertEqual(received.wait(timeout: .now() + 2), .success)
        XCTAssertThrowsError(try resultBox.get()) { error in
            XCTAssertEqual("\(error)", "invalid VMM readiness message")
        }
    }
}

private final class LockedHandoffResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<VmmHandoff, Error>?

    var result: Result<VmmHandoff, Error>? {
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

    func get() throws -> VmmHandoff {
        switch try XCTUnwrap(result) {
        case let .success(handoff):
            return handoff
        case let .failure(error):
            throw error
        }
    }
}

func sendVmmHandoff(
    path: String,
    ready: VmmReadyMessage,
    fileDescriptors: [Int32]
) throws {
    try VmmHandoffClient.send(path: path, ready: ready, fileDescriptors: fileDescriptors)
}
