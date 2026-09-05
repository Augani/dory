import Darwin
import DoryCore
import DoryOperations
@testable import DorydKit
import XCTest

final class VmmHandoffTests: XCTestCase {
    func testReadinessRefreshRetainsIndependentDescriptorOwnership() throws {
        let originalFD = open("/dev/null", O_RDONLY)
        XCTAssertGreaterThanOrEqual(originalFD, 0)
        var original: VmmHandoff? = VmmHandoff(
            ready: VmmReadyMessage(machineID: "dev"), fileDescriptors: [originalFD]
        )
        var ready = try XCTUnwrap(original).ready
        ready.guestBooted = true
        ready.toolsConnected = true
        var refreshed: VmmHandoff? = try XCTUnwrap(original).replacingReady(ready)
        let copiedFD = try XCTUnwrap(refreshed?.fileDescriptors.first)
        XCTAssertNotEqual(copiedFD, originalFD)
        XCTAssertNotEqual(fcntl(copiedFD, F_GETFD) & FD_CLOEXEC, 0)
        XCTAssertFalse(try XCTUnwrap(original).ready.toolsConnected)
        XCTAssertTrue(try XCTUnwrap(refreshed).ready.toolsConnected)
        original = nil
        XCTAssertEqual(fcntl(originalFD, F_GETFD), -1)
        XCTAssertGreaterThanOrEqual(fcntl(copiedFD, F_GETFD), 0)
        refreshed = nil
        XCTAssertEqual(fcntl(copiedFD, F_GETFD), -1)
    }

    func testReadinessObservationsRoundTripIndependentlyAndRejectImpossibleOrdering() throws {
        let operationID = UUID().uuidString.lowercased()
        let ready = VmmReadyMessage(
            machineID: "dev",
            operationID: operationID,
            guestBooted: true,
            toolsConnected: false,
            desktopVisible: true,
            workloadReady: false
        )

        let decoded = try JSONDecoder().decode(
            VmmReadyMessage.self,
            from: JSONEncoder().encode(ready)
        )
        XCTAssertEqual(decoded, ready)
        XCTAssertTrue(decoded.guestBooted)
        XCTAssertFalse(decoded.toolsConnected)
        XCTAssertTrue(decoded.desktopVisible)
        XCTAssertFalse(decoded.workloadReady)
        XCTAssertTrue(decoded.hasValidOperationIdentity)

        XCTAssertFalse(VmmReadyMessage(
            machineID: "dev",
            operationID: operationID,
            guestBooted: false,
            workloadReady: true
        ).hasValidOperationIdentity)

        let historical = Data(
            #"{"machineID":"dev","operationID":"01234567-89ab-4cde-8f01-23456789abcd"}"#.utf8
        )
        let historicalDecoded = try JSONDecoder().decode(VmmReadyMessage.self, from: historical)
        XCTAssertFalse(historicalDecoded.guestBooted)
        XCTAssertFalse(historicalDecoded.toolsConnected)
        XCTAssertFalse(historicalDecoded.desktopVisible)
        XCTAssertFalse(historicalDecoded.workloadReady)
    }

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

        let pcVirGL2 = DoryRuntimeGraphicsSelection(
            operationID: operationID,
            resolvedPlanSHA256: planSHA256,
            planRevision: 1,
            accelerationLevel: .hardwareAccelerated3D,
            backend: .virgl,
            rendererGeneration: 1,
            rendererWorkerReceiptSHA256: rendererReceipt,
            guestProducerFenceProofSHA256: guestFenceProof
        )
        XCTAssertTrue(pcVirGL2.isValid)
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


    func testServerAcceptsReadinessRenewalAfterInitialMessage() throws {
        let base = "/tmp/dory-vmm-handoff-renew-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let received = DispatchSemaphore(value: 0)
        let resultBox = LockedHandoffResults()
        let server = VmmHandoffServer(path: base + "/handoff.sock") { result in
            resultBox.append(result)
            received.signal()
        }
        try server.start()
        defer { server.stop() }

        let operationID = "01234567-89ab-4cde-8f01-23456789abcd"
        try VmmHandoffClient.send(
            path: server.path,
            ready: VmmReadyMessage(machineID: "dev", operationID: operationID),
            fileDescriptors: []
        )
        XCTAssertEqual(received.wait(timeout: .now() + 2), .success)

        try VmmHandoffClient.send(
            path: server.path,
            ready: VmmReadyMessage(
                machineID: "dev",
                operationID: operationID,
                guestBooted: true,
                desktopVisible: true
            ),
            fileDescriptors: []
        )
        XCTAssertEqual(received.wait(timeout: .now() + 2), .success)

        let handoffs = try resultBox.get(count: 2)
        XCTAssertEqual(handoffs[0].ready.machineID, "dev")
        XCTAssertFalse(handoffs[0].ready.desktopVisible)
        XCTAssertEqual(handoffs[1].ready.machineID, "dev")
        XCTAssertTrue(handoffs[1].ready.desktopVisible)
        XCTAssertNotNil(handoffs[0].peerIdentity)
        XCTAssertNotNil(handoffs[1].peerIdentity)
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

        XCTAssertThrowsError(try VmmHandoffClient.send(
            path: server.path,
            ready: VmmReadyMessage(machineID: "dev"),
            fileDescriptors: []
        )) { error in
            XCTAssertEqual("\(error)", "empty VMM handoff message")
        }
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


private final class LockedHandoffResults: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Result<VmmHandoff, Error>] = []

    func append(_ result: Result<VmmHandoff, Error>) {
        lock.lock()
        stored.append(result)
        lock.unlock()
    }

    func get(count: Int) throws -> [VmmHandoff] {
        lock.lock()
        let snapshot = stored
        lock.unlock()
        XCTAssertEqual(snapshot.count, count)
        return try snapshot.map { result in
            switch result {
            case let .success(handoff): return handoff
            case let .failure(error): throw error
            }
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
