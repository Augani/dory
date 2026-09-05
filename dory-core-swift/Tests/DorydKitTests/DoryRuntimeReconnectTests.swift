import Darwin
import DoryCore
import DoryOperations
@testable import DorydKit
import Foundation
import XCTest

final class DoryRuntimeReconnectTests: XCTestCase {
    func testPrivateDescriptorRoundTripsAndChallengeBindsWholeGeneration() throws {
        let identity = makeIdentity()
        let authority = try makeRuntimeReconnectIdentityDescriptor(identity)
        defer { authority.close() }
        let decoded = try authority.withBorrowedDescriptor {
            try DoryRuntimeReconnectLaunchIdentity.decode(fileDescriptor: $0)
        }
        XCTAssertEqual(decoded, identity)

        let process = try DoryHostProcessIdentity.capture()
        let challenge = String(repeating: "c", count: 64)
        let response = try DoryRuntimeReconnectResponse(
            launchIdentity: identity,
            challenge: challenge,
            processIdentity: process
        )
        XCTAssertTrue(response.matches(identity, challenge: challenge))
        XCTAssertFalse(response.matches(identity, challenge: String(repeating: "d", count: 64)))
        var otherGeneration = identity
        otherGeneration.planRevision += 1
        XCTAssertFalse(response.matches(otherGeneration, challenge: challenge))
        var substitutedState = response
        substitutedState.runtimeState = .paused
        XCTAssertFalse(substitutedState.matches(identity, challenge: challenge))
        let paused = try DoryRuntimeReconnectResponse(
            launchIdentity: identity,
            challenge: challenge,
            processIdentity: process,
            runtimeState: .paused
        )
        XCTAssertTrue(paused.matches(identity, challenge: challenge))
    }

    func testControlSocketAuthenticatesExactPrivateLaunchIdentity() throws {
        let socket = "/tmp/dory-rc-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: socket) }
        let identity = makeIdentity()
        let state = ReconnectFixtureExecutionState()
        let server = VmmLifecycleReceiptServer(
            socketPath: socket,
            reconnectIdentity: identity,
            executionStateProvider: { state.current },
            executionLifecycleHandler: { state.apply($0) }
        )
        try server.start()
        defer { server.stop() }

        let response = try VmmControlClient.authenticateRuntime(
            socketPath: socket,
            launchIdentity: identity
        )
        XCTAssertEqual(response.identity.processIdentifier, getpid())
        let operationID = UUID()
        let pauseReceipt = try VmmControlClient.send(
            socketPath: socket, request: .pauseMachine(operationID: operationID)
        )
        XCTAssertTrue(pauseReceipt.ok)
        let paused = try VmmControlClient.authenticateRuntime(socketPath: socket, launchIdentity: identity)
        XCTAssertEqual(paused.runtimeState, .paused)
        XCTAssertEqual(paused.identity, response.identity)
        let resumeReceipt = try VmmControlClient.send(
            socketPath: socket, request: .resumeMachine(operationID: UUID())
        )
        XCTAssertTrue(resumeReceipt.ok)
        XCTAssertEqual(try VmmControlClient.authenticateRuntime(
            socketPath: socket, launchIdentity: identity
        ).runtimeState, .running)

        var substituted = identity
        substituted.secret = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try VmmControlClient.authenticateRuntime(
            socketPath: socket,
            launchIdentity: substituted
        ))
    }

    func testStorePublishesPendingThenExactLiveRecordAndRemovesOnce() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let identity = makeIdentity()
        let store = DoryRuntimeReconnectRecordStore(root: root)
        try store.publishPending(
            identity: identity,
            backend: .doryHypervisor,
            executablePath: "/bin/sleep"
        )
        XCTAssertEqual(try store.read(machineID: identity.machineID).state, .pending)

        let ready = VmmReadyMessage(
            machineID: identity.machineID,
            operationID: identity.operationID,
            controlSocketPath: root + "/control.sock",
            guestBooted: true,
            workloadReady: true
        )
        let operationID = try XCTUnwrap(UUID(uuidString: identity.operationID))
        let live = try store.publishLive(
            machineID: identity.machineID,
            operationID: operationID,
            processIdentifier: getpid(),
            readiness: ready
        )
        XCTAssertEqual(live.state, .live)
        XCTAssertEqual(try store.liveRecords(), [live])

        let path = root + "/.runtime-reconnect/" + identity.machineID + ".json"
        var status = stat()
        XCTAssertEqual(lstat(path, &status), 0)
        XCTAssertEqual(status.st_mode & 0o077, 0)
        try store.remove(machineID: identity.machineID, operationID: operationID)
        try store.remove(machineID: identity.machineID, operationID: operationID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testRendererRenewalPersistsOnlyForExactLiveRuntimeAndPreservesEndpoints() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let identity = makeIdentity()
        let store = DoryRuntimeReconnectRecordStore(root: root)
        let process = try DoryHostProcessIdentity.capture()
        var ready = VmmReadyMessage(
            machineID: identity.machineID, operationID: identity.operationID,
            agentSocketPath: root + "/agent.sock", controlSocketPath: root + "/control.sock",
            graphicsSelection: DoryRuntimeGraphicsSelection(
                operationID: identity.operationID, resolvedPlanSHA256: identity.resolvedPlanSHA256,
                planRevision: identity.planRevision, accelerationLevel: .hardwareAccelerated3D,
                backend: .virgl, rendererGeneration: 1,
                rendererWorkerReceiptSHA256: String(repeating: "a", count: 64),
                guestProducerFenceProofSHA256: String(repeating: "b", count: 64)))
        try store.publishPending(identity: identity, backend: .doryHypervisor, executablePath: "/bin/sleep")
        XCTAssertThrowsError(try store.renewLiveReadiness(
            machineID: identity.machineID, launchIdentity: identity,
            processIdentity: process, readiness: ready))
        let original = try store.publishLive(
            machineID: identity.machineID, operationID: XCTUnwrap(UUID(uuidString: identity.operationID)),
            processIdentifier: process.processIdentifier, readiness: ready)
        ready.graphicsSelection?.rendererGeneration = 2
        ready.graphicsSelection?.rendererWorkerReceiptSHA256 = String(repeating: "c", count: 64)
        let renewed = try store.renewLiveReadiness(
            machineID: identity.machineID, launchIdentity: identity,
            processIdentity: process, readiness: ready)
        XCTAssertEqual(renewed.launchIdentity, original.launchIdentity)
        XCTAssertEqual(renewed.processIdentity, original.processIdentity)
        XCTAssertEqual(renewed.backend, original.backend)
        XCTAssertEqual(renewed.executablePath, original.executablePath)
        XCTAssertEqual(renewed.readiness, ready)
        XCTAssertEqual(try DoryRuntimeReconnectRecordStore(root: root).read(machineID: identity.machineID), renewed)

        var candidate = ready
        candidate.graphicsSelection?.rendererGeneration = 3
        var wrongLaunch = identity
        wrongLaunch.secret = String(repeating: "0", count: 64)
        var wrongProcess = process
        wrongProcess.startTimeMicroseconds &+= 1
        for (launch, peer) in [(wrongLaunch, process), (identity, wrongProcess)] {
            XCTAssertThrowsError(try store.renewLiveReadiness(
                machineID: identity.machineID, launchIdentity: launch,
                processIdentity: peer, readiness: candidate))
        }
        var wrongEndpoint = candidate
        wrongEndpoint.controlSocketPath = root + "/substituted.sock"
        var wrongPlan = candidate
        wrongPlan.graphicsSelection?.planRevision &+= 1
        var wrongBackend = candidate
        wrongBackend.graphicsSelection?.backend = .virglVenus
        var wrongObservation = candidate
        wrongObservation.workloadReady = true
        for rejected in [try XCTUnwrap(original.readiness), ready, wrongEndpoint, wrongPlan,
                         wrongBackend, wrongObservation] {
            XCTAssertThrowsError(try store.renewLiveReadiness(
                machineID: identity.machineID, launchIdentity: identity,
                processIdentity: process, readiness: rejected))
            XCTAssertEqual(try store.read(machineID: identity.machineID), renewed)
        }
    }

    func testAdoptionRejectsStaleProcessGenerationBeforeInstallingSupervisor() throws {
        let current = try DoryHostProcessIdentity.capture()
        XCTAssertThrowsError(try HvProcess.adopting(
            configuration: HvProcessConfiguration(executablePath: "/bin/sleep"),
            processIdentity: current,
            processGenerationIsCurrent: { false }
        ))
    }

    func testAuthenticatedSurvivingNonchildIsAdoptedAndStoppedAsExactGeneration() throws {
        let socket = "/tmp/dory-rc-\(UUID().uuidString.prefix(8)).sock"
        let identity = makeIdentity()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = [
            "xctest",
            "-XCTest",
            "DorydKitTests.DoryRuntimeReconnectTests/testReconnectSubprocessServer",
            Bundle(for: DoryRuntimeReconnectTests.self).bundlePath,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["DORY_RECONNECT_TEST_SOCKET"] = socket
        environment["DORY_RECONNECT_TEST_IDENTITY"] = try identity.encodedData().base64EncodedString()
        child.environment = environment
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer {
            if child.isRunning {
                _ = kill(child.processIdentifier, SIGKILL)
            }
            child.waitUntilExit()
            try? FileManager.default.removeItem(atPath: socket)
        }

        let deadline = Date().addingTimeInterval(3)
        var authenticated: DoryRuntimeReconnectResponse?
        while Date() < deadline, authenticated == nil {
            authenticated = try? VmmControlClient.authenticateRuntime(
                socketPath: socket,
                launchIdentity: identity
            )
            if authenticated == nil { usleep(10_000) }
        }
        let response = try XCTUnwrap(authenticated)
        XCTAssertEqual(response.identity.processIdentifier, child.processIdentifier)
        let adopted = try HvProcess.adopting(
            configuration: HvProcessConfiguration(
                executablePath: CommandLine.arguments[0],
                restartPolicy: .none
            ),
            processIdentity: response.identity,
            processGenerationIsCurrent: response.identity.matchesCurrentProcess
        )
        XCTAssertEqual(adopted.pid, child.processIdentifier)
        XCTAssertTrue(adopted.stop(timeout: 1))
        child.waitUntilExit()
        XCTAssertFalse(response.identity.matchesCurrentProcess())
    }

    func testReconnectSubprocessServer() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let socket = environment["DORY_RECONNECT_TEST_SOCKET"] else { return }
        let identity: DoryRuntimeReconnectLaunchIdentity
        if let descriptor = environment["DORY_RECONNECT_TEST_FD"].flatMap(Int32.init) {
            identity = try DoryRuntimeReconnectLaunchIdentity.decode(fileDescriptor: descriptor)
        } else {
            let encoded = try XCTUnwrap(environment["DORY_RECONNECT_TEST_IDENTITY"])
            let data = try XCTUnwrap(Data(base64Encoded: encoded))
            identity = try JSONDecoder().decode(DoryRuntimeReconnectLaunchIdentity.self, from: data)
        }
        let state = ReconnectFixtureExecutionState()
        let server = VmmLifecycleReceiptServer(
            socketPath: socket,
            reconnectIdentity: identity,
            executionStateProvider: { state.current },
            executionLifecycleHandler: { state.apply($0) }
        )
        try server.start()
        defer { server.stop() }
        _ = signal(SIGTERM, SIG_DFL)
        if let retirePath = environment["DORY_RECONNECT_TEST_RETIRE_ON_FILE"] {
            while !FileManager.default.fileExists(atPath: retirePath) {
                Thread.sleep(forTimeInterval: 0.01)
            }
            return
        }
        while true { pause() }
    }

    func testDaemonSubprocessOwner() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let state = environment["DORY_RECONNECT_DAEMON_ROOT"] else { return }
        try MachineManagerResolvedPlanIntegrationTests().runDaemonReconnectFixture(
            state: state,
            paused: environment["DORY_RECONNECT_DAEMON_PAUSED"] == "1",
            restartBoundary: environment["DORY_RECONNECT_RESTART_BOUNDARY"]
        )
    }

    private func makeIdentity() -> DoryRuntimeReconnectLaunchIdentity {
        DoryRuntimeReconnectLaunchIdentity(
            machineID: "reconnect-machine",
            operationID: UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!,
            resolvedPlanSHA256: String(repeating: "a", count: 64),
            planRevision: 7,
            secret: String(repeating: "b", count: 64)
        )
    }

    private func temporaryDirectory() -> String {
        let path = NSTemporaryDirectory() + "/dory-runtime-reconnect-tests-"
            + UUID().uuidString.lowercased()
        try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }
}

private final class ReconnectFixtureExecutionState: @unchecked Sendable {
    private let lock = NSLock()
    private var state: DoryVirtualMachineState = .running
    var current: DoryVirtualMachineState { lock.withLock { state } }
    func apply(_ action: DoryLifecycleReceiptAction) {
        lock.withLock { state = action == .preparePause ? .paused : .running }
    }
}
