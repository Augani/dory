import Darwin
import DoryCore
import DoryOperations
@testable import DorydKit
import Foundation
import XCTest

struct RendererGenerationRenewalFixtureInstruction: Codable {
    var generationHandoffPath: String
    var generationHandoffToken: String
    var readinessHandoffPath: String
    var machineID: String
    var operationID: String
    var resolvedPlanSHA256: String
    var planRevision: UInt64
    var previousRendererGeneration: UInt64
    var requestedRendererGeneration: UInt64
    var guestProducerFenceProofSHA256: String
    var readyTemplate: VmmReadyMessage
    var outcomePath: String?
    var detail: String? = nil
    var provisionalAckPath: String? = nil
}

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

    func testCameraGrantBindsSelectedDeviceAndResolvedPlan() throws {
        let identity = makeIdentity()
        let proof = try identity.cameraGrantProof(deviceUniqueID: "selected-host-camera")
        XCTAssertTrue(identity.verifiesCameraGrant(proof, deviceUniqueID: "selected-host-camera"))
        XCTAssertFalse(identity.verifiesCameraGrant(proof, deviceUniqueID: "other-host-camera"))
        var differentPlan = identity
        differentPlan.resolvedPlanSHA256 = String(repeating: "c", count: 64)
        XCTAssertFalse(differentPlan.verifiesCameraGrant(
            proof, deviceUniqueID: "selected-host-camera"
        ))
        var differentOperation = identity
        differentOperation.operationID = "11111111-2222-4333-8444-555555555555"
        XCTAssertFalse(differentOperation.verifiesCameraGrant(
            proof, deviceUniqueID: "selected-host-camera"
        ))
    }

    func testControlSocketAuthenticatesExactPrivateLaunchIdentity() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let socket = root + "/control.sock"
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
                guestProducerFenceProofSHA256: String(repeating: "b", count: 64),
                firstShaderCompletedAtUnixMilliseconds: 10,
                firstPresentationCompletedAtUnixMilliseconds: 11))
        try store.publishPending(identity: identity, backend: .doryHypervisor, executablePath: "/bin/sleep")
        XCTAssertThrowsError(try store.renewLiveReadiness(
            machineID: identity.machineID, launchIdentity: identity,
            processIdentity: process, readiness: ready))
        let original = try store.publishLive(
            machineID: identity.machineID, operationID: XCTUnwrap(UUID(uuidString: identity.operationID)),
            processIdentifier: process.processIdentifier, readiness: ready)
        ready.graphicsSelection?.rendererGeneration = 2
        ready.graphicsSelection?.rendererWorkerReceiptSHA256 = String(repeating: "c", count: 64)
        ready.graphicsSelection?.verificationState = .provisional
        ready.graphicsSelection?.guestProducerFenceProofSHA256 = nil
        ready.graphicsSelection?.firstShaderCompletedAtUnixMilliseconds = nil
        ready.graphicsSelection?.firstPresentationCompletedAtUnixMilliseconds = nil
        ready.detail = "replacement renderer ready"
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

    func testAuthenticatedDiagnosticRenewalPreservesRuntimeAuthority() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let identity = makeIdentity()
        let store = DoryRuntimeReconnectRecordStore(root: root)
        let process = try DoryHostProcessIdentity.capture()
        let operationID = try XCTUnwrap(UUID(uuidString: identity.operationID))
        let ready = VmmReadyMessage(
            machineID: identity.machineID,
            operationID: identity.operationID,
            controlSocketPath: root + "/control.sock",
            graphicsSelection: .resolvedSoftware(
                operationID: operationID,
                resolvedPlanSHA256: identity.resolvedPlanSHA256,
                planRevision: identity.planRevision
            ),
            detail: "Firmware is running"
        )
        try store.publishPending(
            identity: identity,
            backend: .doryHypervisor,
            executablePath: "/bin/sleep"
        )
        _ = try store.publishLive(
            machineID: identity.machineID,
            operationID: operationID,
            processIdentifier: process.processIdentifier,
            readiness: ready
        )

        var diagnostic = ready
        diagnostic.detail = "Graphics renderer stopped; VM is still running"
        let renewed = try store.renewLiveReadiness(
            machineID: identity.machineID,
            launchIdentity: identity,
            processIdentity: process,
            readiness: diagnostic
        )
        XCTAssertEqual(renewed.readiness, diagnostic)
        XCTAssertEqual(renewed.launchIdentity, identity)
        XCTAssertEqual(renewed.processIdentity, process)
        XCTAssertThrowsError(try store.renewLiveReadiness(
            machineID: identity.machineID,
            launchIdentity: identity,
            processIdentity: process,
            readiness: diagnostic
        ))

        var wrongEndpoint = diagnostic
        wrongEndpoint.controlSocketPath = root + "/replacement.sock"
        wrongEndpoint.detail = "Another update"
        var oversized = diagnostic
        oversized.detail = String(repeating: "x", count: 2_049)
        for rejected in [wrongEndpoint, oversized] {
            XCTAssertThrowsError(try store.renewLiveReadiness(
                machineID: identity.machineID,
                launchIdentity: identity,
                processIdentity: process,
                readiness: rejected
            ))
        }
        XCTAssertEqual(try store.read(machineID: identity.machineID), renewed)
    }

    func testGuestRebootRevokesLiveStatusAndReadmitsFreshBoot() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let identity = makeIdentity()
        let store = DoryRuntimeReconnectRecordStore(root: root)
        let process = try DoryHostProcessIdentity.capture()
        let operationID = try XCTUnwrap(UUID(uuidString: identity.operationID))
        var graphics = DoryRuntimeGraphicsSelection.resolvedSoftware(
            operationID: operationID,
            resolvedPlanSHA256: identity.resolvedPlanSHA256,
            planRevision: identity.planRevision
        )
        graphics.firstPresentationCompletedAtUnixMilliseconds = 10
        let ready = VmmReadyMessage(
            machineID: identity.machineID,
            operationID: identity.operationID,
            agentBuild: "old-agent",
            controlSocketPath: root + "/control.sock",
            graphicsSelection: graphics,
            guestBooted: true,
            toolsConnected: true,
            desktopVisible: true,
            workloadReady: true,
            detail: "first boot ready"
        )
        try store.publishPending(
            identity: identity, backend: .doryHypervisor, executablePath: "/bin/sleep"
        )
        _ = try store.publishLive(
            machineID: identity.machineID,
            operationID: operationID,
            processIdentifier: process.processIdentifier,
            readiness: ready
        )

        var rebooting = ready
        rebooting.graphicsSelection?.firstPresentationCompletedAtUnixMilliseconds = nil
        rebooting.guestBooted = false
        rebooting.toolsConnected = false
        rebooting.desktopVisible = false
        rebooting.workloadReady = false
        rebooting.detail = "Guest rebooting; waiting for a new desktop presentation."
        XCTAssertEqual(try store.renewLiveReadiness(
            machineID: identity.machineID,
            launchIdentity: identity,
            processIdentity: process,
            readiness: rebooting
        ).readiness, rebooting)

        var secondBoot = rebooting
        secondBoot.graphicsSelection?.firstPresentationCompletedAtUnixMilliseconds = 20
        secondBoot.agentBuild = "updated-agent"
        secondBoot.guestBooted = true
        secondBoot.toolsConnected = true
        secondBoot.desktopVisible = true
        secondBoot.workloadReady = true
        secondBoot.detail = "second boot ready"
        XCTAssertEqual(try store.renewLiveReadiness(
            machineID: identity.machineID,
            launchIdentity: identity,
            processIdentity: process,
            readiness: secondBoot
        ).readiness, secondBoot)

        var tampered = secondBoot
        tampered.controlSocketPath = root + "/different.sock"
        XCTAssertThrowsError(try store.renewLiveReadiness(
            machineID: identity.machineID,
            launchIdentity: identity,
            processIdentity: process,
            readiness: tampered
        ))
    }

    func testRendererRenewalAcceptsOnlyMonotonicStockObservationTransitions() {
        var provisional = DoryRuntimeGraphicsSelection(
            operationID: UUID().uuidString.lowercased(),
            resolvedPlanSHA256: String(repeating: "a", count: 64),
            planRevision: 1,
            accelerationLevel: .hardwareAccelerated3D,
            backend: .virglVenus,
            rendererGeneration: 9,
            rendererWorkerReceiptSHA256: String(repeating: "b", count: 64),
            requestedGraphics: .hardwareAccelerated3D,
            admittedGraphics: .hardwareAccelerated3D,
            verificationState: .provisional,
            guestDriver: .venus
        )
        var observed = provisional
        observed.firstShaderCompletedAtUnixMilliseconds = 10
        XCTAssertTrue(DoryRuntimeReconnectRecordStore.acceptsGraphicsRenewal(
            previous: provisional,
            replacement: observed
        ))

        var verified = observed
        verified.verificationState = .verified
        verified.guestProducerFenceProofSHA256 = String(repeating: "c", count: 64)
        XCTAssertTrue(DoryRuntimeReconnectRecordStore.acceptsGraphicsRenewal(
            previous: observed,
            replacement: verified
        ))

        var downgraded = provisional
        downgraded.accelerationLevel = .software
        downgraded.backend = .software
        downgraded.rendererGeneration = nil
        downgraded.rendererWorkerReceiptSHA256 = nil
        downgraded.verificationState = .downgraded(.guestKernelLacksPrepareFB)
        downgraded.guestDriver = .software
        XCTAssertTrue(DoryRuntimeReconnectRecordStore.acceptsGraphicsRenewal(
            previous: provisional,
            replacement: downgraded
        ))

        provisional.firstShaderCompletedAtUnixMilliseconds = 11
        XCTAssertFalse(DoryRuntimeReconnectRecordStore.acceptsGraphicsRenewal(
            previous: provisional,
            replacement: provisional
        ))
        XCTAssertFalse(DoryRuntimeReconnectRecordStore.acceptsGraphicsRenewal(
            previous: verified,
            replacement: downgraded
        ))
    }

    func testRendererReplacementRequiresFreshProvisionalGenerationAndObservations() {
        var verified = DoryRuntimeGraphicsSelection(
            operationID: UUID().uuidString.lowercased(),
            resolvedPlanSHA256: String(repeating: "a", count: 64),
            planRevision: 1,
            accelerationLevel: .hardwareAccelerated3D,
            backend: .virglVenus,
            rendererGeneration: 9,
            rendererWorkerReceiptSHA256: String(repeating: "b", count: 64),
            guestProducerFenceProofSHA256: String(repeating: "c", count: 64),
            firstShaderCompletedAtUnixMilliseconds: 10,
            firstPresentationCompletedAtUnixMilliseconds: 11
        )
        XCTAssertTrue(verified.isValid)

        var replacement = verified
        replacement.rendererGeneration = 10
        replacement.rendererWorkerReceiptSHA256 = String(repeating: "d", count: 64)
        replacement.verificationState = .provisional
        replacement.guestProducerFenceProofSHA256 = nil
        replacement.firstShaderCompletedAtUnixMilliseconds = nil
        replacement.firstPresentationCompletedAtUnixMilliseconds = nil
        XCTAssertTrue(replacement.isValid)
        XCTAssertTrue(DoryRuntimeReconnectRecordStore.acceptsGraphicsRenewal(
            previous: verified, replacement: replacement))

        var staleProof = replacement
        staleProof.verificationState = .verified
        staleProof.guestProducerFenceProofSHA256 = verified.guestProducerFenceProofSHA256
        XCTAssertFalse(DoryRuntimeReconnectRecordStore.acceptsGraphicsRenewal(
            previous: verified, replacement: staleProof))
        var staleFrame = replacement
        staleFrame.firstPresentationCompletedAtUnixMilliseconds = 11
        XCTAssertFalse(DoryRuntimeReconnectRecordStore.acceptsGraphicsRenewal(
            previous: verified, replacement: staleFrame))
        var changedBackend = replacement
        changedBackend.backend = .virgl
        changedBackend.guestDriver = .virgl
        XCTAssertFalse(DoryRuntimeReconnectRecordStore.acceptsGraphicsRenewal(
            previous: verified, replacement: changedBackend))
        verified.rendererGeneration = 10
        XCTAssertFalse(DoryRuntimeReconnectRecordStore.acceptsGraphicsRenewal(
            previous: verified, replacement: replacement))
    }

    func testGuestMachineResetMayRevokeOnlyObservedGraphicsInSameGeneration() {
        let verified = DoryRuntimeGraphicsSelection(
            operationID: UUID().uuidString.lowercased(),
            resolvedPlanSHA256: String(repeating: "a", count: 64),
            planRevision: 1,
            accelerationLevel: .hardwareAccelerated3D,
            backend: .virglVenus,
            rendererGeneration: 9,
            rendererWorkerReceiptSHA256: String(repeating: "b", count: 64),
            guestProducerFenceProofSHA256: String(repeating: "c", count: 64),
            firstShaderCompletedAtUnixMilliseconds: 10,
            firstPresentationCompletedAtUnixMilliseconds: 11
        )
        var reset = verified
        reset.verificationState = .provisional
        reset.guestProducerFenceProofSHA256 = nil
        reset.firstShaderCompletedAtUnixMilliseconds = nil
        reset.firstPresentationCompletedAtUnixMilliseconds = nil
        XCTAssertTrue(reset.isValid)
        XCTAssertTrue(DoryRuntimeReconnectRecordStore.acceptsGraphicsRenewal(
            previous: verified, replacement: reset
        ))

        var changedReceipt = reset
        changedReceipt.rendererWorkerReceiptSHA256 = String(repeating: "d", count: 64)
        XCTAssertFalse(DoryRuntimeReconnectRecordStore.acceptsGraphicsRenewal(
            previous: verified, replacement: changedReceipt
        ))
        var retainedFrame = reset
        retainedFrame.firstPresentationCompletedAtUnixMilliseconds = 11
        XCTAssertFalse(DoryRuntimeReconnectRecordStore.acceptsGraphicsRenewal(
            previous: verified, replacement: retainedFrame
        ))
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
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let socket = root + "/control.sock"
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
        if let renewalPath = environment["DORY_RECONNECT_TEST_RENDERER_RENEWAL_FILE"] {
            Thread.detachNewThread {
                var outcomePath: String?
                func writeOutcome(_ value: String) {
                    guard let outcomePath else { return }
                    try? Data(value.utf8).write(to: URL(fileURLWithPath: outcomePath), options: .atomic)
                }
                do {
                    let deadline = Date().addingTimeInterval(5)
                    while !FileManager.default.fileExists(atPath: renewalPath), Date() < deadline {
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                    let instruction = try JSONDecoder().decode(
                        RendererGenerationRenewalFixtureInstruction.self,
                        from: Data(contentsOf: URL(fileURLWithPath: renewalPath))
                    )
                    outcomePath = instruction.outcomePath
                    writeOutcome("instruction-loaded")
                    let handoff = try DoryRendererGenerationHandoffClient.request(
                        path: instruction.generationHandoffPath,
                        request: DoryRendererGenerationHandoffRequest(
                            token: instruction.generationHandoffToken,
                            machineID: instruction.machineID,
                            operationID: instruction.operationID,
                            resolvedPlanSHA256: instruction.resolvedPlanSHA256,
                            planRevision: instruction.planRevision,
                            previousRendererGeneration: instruction.previousRendererGeneration,
                            requestedRendererGeneration: instruction.requestedRendererGeneration
                        ),
                        authenticateDaemon: { _, _ in }
                    )
                    defer { handoff.close() }
                    guard handoff.response.ok,
                          handoff.response.rendererGeneration == instruction.requestedRendererGeneration,
                          let rendererReceipt = handoff.response.bootstrapSHA256 else {
                        let message = "renderer generation handoff did not return a valid fixture response"
                        writeOutcome(message)
                        fputs("\(message)\n", stderr)
                        return
                    }
                    writeOutcome("generation-handoff-ok")
                    guard instruction.readyTemplate.machineID == instruction.machineID,
                          instruction.readyTemplate.operationID == instruction.operationID,
                          instruction.readyTemplate.controlSocketPath == socket else {
                        throw DoryRuntimeReconnectError.invalidIdentity
                    }
                    var selection = DoryRuntimeGraphicsSelection(
                        operationID: instruction.operationID,
                        resolvedPlanSHA256: instruction.resolvedPlanSHA256,
                        planRevision: instruction.planRevision,
                        accelerationLevel: .hardwareAccelerated3D,
                        backend: .virgl,
                        rendererGeneration: instruction.requestedRendererGeneration,
                        rendererWorkerReceiptSHA256: rendererReceipt,
                        requestedGraphics: .hardwareAccelerated3D,
                        admittedGraphics: .hardwareAccelerated3D,
                        verificationState: .provisional
                    )
                    var renewedReady = instruction.readyTemplate
                    renewedReady.graphicsSelection = selection
                    renewedReady.detail = "replacement renderer admitted"
                    try VmmHandoffClient.send(
                        path: instruction.readinessHandoffPath,
                        ready: renewedReady,
                        fileDescriptors: []
                    )
                    writeOutcome("provisional-handoff-ok")
                    if let ackPath = instruction.provisionalAckPath {
                        let deadline = Date().addingTimeInterval(5)
                        while !FileManager.default.fileExists(atPath: ackPath),
                              Date() < deadline {
                            Thread.sleep(forTimeInterval: 0.01)
                        }
                        guard FileManager.default.fileExists(atPath: ackPath) else {
                            throw DoryRuntimeReconnectError.invalidIdentity
                        }
                    }
                    selection.verificationState = .verified
                    selection.guestProducerFenceProofSHA256 =
                        instruction.guestProducerFenceProofSHA256
                    renewedReady.graphicsSelection = selection
                    renewedReady.detail = instruction.detail
                    try VmmHandoffClient.send(
                        path: instruction.readinessHandoffPath,
                        ready: renewedReady,
                        fileDescriptors: []
                    )
                    writeOutcome("readiness-handoff-ok")
                } catch {
                    writeOutcome("renderer generation renewal fixture failed: \(error)")
                    fputs("renderer generation renewal fixture failed: \(error)\n", stderr)
                }
            }
        }
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
        // Keep the control endpoint below sockaddr_un's short pathname limit while making the
        // immediate parent private. `/tmp` itself is intentionally rejected by the listener.
        let path = "/tmp/drc-" + UUID().uuidString.prefix(12).lowercased()
        try! FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
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
