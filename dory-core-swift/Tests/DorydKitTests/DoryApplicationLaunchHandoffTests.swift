@testable import DorydKit
import Darwin
import CryptoKit
import DoryRendererWorkerWireContracts
import Foundation
import XCTest

final class DoryApplicationLaunchHandoffTests: XCTestCase {
    func testAuthenticatedPeerReceivesDescriptorsBeforeAcknowledgingLaunch() throws {
        let server = try DoryApplicationLaunchHandoffServer()
        defer { server.cleanup() }
        let directory = try makeTemporaryDirectory(prefix: "dory-app-launch-handoff")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let firstPath = directory + "/first"
        let secondPath = directory + "/second"
        try Data("first-authority".utf8).write(to: URL(fileURLWithPath: firstPath))
        try Data("second-authority".utf8).write(to: URL(fileURLWithPath: secondPath))
        let first = open(firstPath, O_RDONLY | O_CLOEXEC)
        let second = open(secondPath, O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(first, 0)
        XCTAssertGreaterThanOrEqual(second, 0)
        defer {
            Darwin.close(first)
            Darwin.close(second)
        }

        let firstTarget: Int32 = 900
        let secondTarget: Int32 = 901
        Darwin.close(firstTarget)
        Darwin.close(secondTarget)
        defer {
            Darwin.close(firstTarget)
            Darwin.close(secondTarget)
        }
        let clientResult = LockedLaunchHandoffResult()
        let clientFinished = DispatchGroup()
        clientFinished.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { clientFinished.leave() }
            clientResult.set(Result {
                try DoryApplicationLaunchHandoffClient.receiveIfRequested(
                    arguments: [
                        "desktop",
                        "--machine-id", "fixture",
                        DoryApplicationLaunchHandoffClient.socketArgument, server.path,
                        DoryApplicationLaunchHandoffClient.tokenArgument, server.token,
                    ],
                    authenticateDaemon: { XCTAssertEqual($0, getpid()) }
                )
            })
        }

        var authenticationObserved = false
        let peerAuditToken = try server.transfer(
            toExpectedPID: getpid(),
            mappings: [
                InheritedDescriptorMapping(
                    parentDescriptor: first,
                    childDescriptor: firstTarget
                ),
                InheritedDescriptorMapping(
                    parentDescriptor: second,
                    childDescriptor: secondTarget
                ),
            ]
        ) {
            authenticationObserved = true
            errno = 0
            XCTAssertEqual(fcntl(firstTarget, F_GETFD), -1)
            XCTAssertEqual(errno, EBADF)
            errno = 0
            XCTAssertEqual(fcntl(secondTarget, F_GETFD), -1)
            XCTAssertEqual(errno, EBADF)
        }

        XCTAssertEqual(clientFinished.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(authenticationObserved)
        XCTAssertEqual(
            try clientResult.get().get(),
            ["desktop", "--machine-id", "fixture"]
        )
        XCTAssertEqual(try readAll(descriptor: firstTarget), Data("first-authority".utf8))
        XCTAssertEqual(try readAll(descriptor: secondTarget), Data("second-authority".utf8))
        XCTAssertEqual(
            DoryApplicationLaunchHandoffProtocol.signal(
                SIGCONT,
                auditToken: peerAuditToken
            ),
            .delivered
        )
    }

    func testDescriptorInstallConsumesSourcesBeforeCollidingTargetNumbers() throws {
        let directory = try makeTemporaryDirectory(prefix: "dory-app-launch-fd-collision")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let firstPath = directory + "/first"
        let secondPath = directory + "/second"
        try Data("kernel-authority".utf8).write(to: URL(fileURLWithPath: firstPath))
        try Data("rootfs-authority".utf8).write(to: URL(fileURLWithPath: secondPath))
        let first = open(firstPath, O_RDONLY | O_CLOEXEC)
        let second = open(secondPath, O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(first, 0)
        XCTAssertGreaterThanOrEqual(second, 0)

        // This is the collision a fresh runner encounters at low descriptors: SCM_RIGHTS assigns
        // a source number that is also its manifest target. `install` must transfer ownership out
        // of the caller, stage both sources, close them, and only then recreate these targets.
        var received = [first, second]
        let targets = [first, second]
        defer {
            for descriptor in received { Darwin.close(descriptor) }
            for descriptor in targets where fcntl(descriptor, F_GETFD) >= 0 {
                Darwin.close(descriptor)
            }
        }
        try DoryApplicationLaunchHandoffProtocol.install(
            receivedDescriptors: &received,
            targetDescriptors: targets
        )

        XCTAssertTrue(received.isEmpty)
        XCTAssertEqual(try readAll(descriptor: first), Data("kernel-authority".utf8))
        XCTAssertEqual(try readAll(descriptor: second), Data("rootfs-authority".utf8))
    }

    func testPeerPIDMismatchFailsBeforeAuthenticationOrDescriptorTransfer() throws {
        let server = try DoryApplicationLaunchHandoffServer()
        defer { server.cleanup() }
        let clientResult = LockedLaunchHandoffResult()
        let clientFinished = DispatchGroup()
        clientFinished.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { clientFinished.leave() }
            clientResult.set(Result {
                try DoryApplicationLaunchHandoffClient.receiveIfRequested(
                    arguments: [
                        "desktop",
                        DoryApplicationLaunchHandoffClient.socketArgument, server.path,
                        DoryApplicationLaunchHandoffClient.tokenArgument, server.token,
                    ],
                    authenticateDaemon: { XCTAssertEqual($0, getpid()) }
                )
            })
        }

        var authenticated = false
        XCTAssertThrowsError(try server.transfer(
            toExpectedPID: getpid() + 100_000,
            mappings: []
        ) {
            authenticated = true
        }) { error in
            guard case DoryApplicationLaunchHandoffError.peerIdentityMismatch = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(clientFinished.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(authenticated)
        XCTAssertThrowsError(try clientResult.get().get())
    }

    func testAuthenticatedPeerCanSupplyLaunchIdentityWhenLaunchServicesHasNoPID() throws {
        let server = try DoryApplicationLaunchHandoffServer()
        defer { server.cleanup() }
        let clientResult = LockedLaunchHandoffResult()
        let clientFinished = DispatchGroup()
        clientFinished.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { clientFinished.leave() }
            clientResult.set(Result {
                try DoryApplicationLaunchHandoffClient.receiveIfRequested(
                    arguments: [
                        "desktop",
                        DoryApplicationLaunchHandoffClient.socketArgument, server.path,
                        DoryApplicationLaunchHandoffClient.tokenArgument, server.token,
                    ],
                    authenticateDaemon: { XCTAssertEqual($0, getpid()) }
                )
            })
        }

        var authenticatedPID: pid_t?
        let peer = try server.transfer(mappings: []) { peerPID in
            authenticatedPID = peerPID
        }

        XCTAssertEqual(clientFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(try clientResult.get().get(), ["desktop"])
        XCTAssertEqual(peer.processIdentifier, getpid())
        XCTAssertEqual(authenticatedPID, getpid())
        XCTAssertEqual(
            DoryApplicationLaunchHandoffProtocol.signal(
                SIGCONT,
                auditToken: peer.auditToken
            ),
            .delivered
        )
    }

    func testRunnerRejectsUnauthenticatedDaemonBeforeSendingLaunchToken() throws {
        let server = try DoryApplicationLaunchHandoffServer()
        defer { server.cleanup() }
        let clientResult = LockedLaunchHandoffResult()
        let clientFinished = DispatchGroup()
        clientFinished.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { clientFinished.leave() }
            clientResult.set(Result {
                try DoryApplicationLaunchHandoffClient.receiveIfRequested(
                    arguments: [
                        "desktop",
                        DoryApplicationLaunchHandoffClient.socketArgument, server.path,
                        DoryApplicationLaunchHandoffClient.tokenArgument, server.token,
                    ],
                    authenticateDaemon: { _ in throw FixtureDaemonAuthenticationError.rejected }
                )
            })
        }

        var runnerAuthenticated = false
        XCTAssertThrowsError(try server.transfer(
            toExpectedPID: getpid(),
            mappings: []
        ) {
            runnerAuthenticated = true
        })
        XCTAssertEqual(clientFinished.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(runnerAuthenticated)
        XCTAssertThrowsError(try clientResult.get().get()) { error in
            XCTAssertTrue(error is FixtureDaemonAuthenticationError)
        }
    }

    func testMalformedLaunchSuffixFailsClosedWhileDirectArgumentsRemainUnchanged() throws {
        let direct = ["desktop", "--machine-id", "fixture"]
        XCTAssertEqual(
            try DoryApplicationLaunchHandoffClient.receiveIfRequested(arguments: direct),
            direct
        )
        XCTAssertThrowsError(try DoryApplicationLaunchHandoffClient.receiveIfRequested(
            arguments: direct + [DoryApplicationLaunchHandoffClient.socketArgument, "/tmp/x"]
        )) { error in
            XCTAssertEqual(
                error as? DoryApplicationLaunchHandoffError,
                .invalidInvocation
            )
        }
    }

    func testRendererGenerationHandoffTransfersFreshBootstrapDescriptor() throws {
        let directory = try makeTemporaryDirectory(prefix: "dory-renderer-generation-handoff")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let socketPath = directory + "/renderer.sock"
        let token = String(repeating: "a", count: DoryRendererGenerationHandoffRequest.tokenByteCount)
        let payload = Data(repeating: 0x5a, count: DoryRendererWorkerBootstrapCodec.fixedByteCount)
        let payloadPath = directory + "/bootstrap"
        try payload.write(to: URL(fileURLWithPath: payloadPath))
        let descriptor = open(payloadPath, O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }
        let transferredDescriptor = fcntl(descriptor, F_DUPFD_CLOEXEC, 3)
        XCTAssertGreaterThanOrEqual(transferredDescriptor, 0)
        let sha = SHA256Digest.hex(payload)
        let operationID = UUID()
        let observed = LockedRendererGenerationPeer()
        let server = DoryRendererGenerationHandoffServer(path: socketPath, token: token) { request, peer in
            observed.set(pid: peer.processIdentifier, generation: request.requestedRendererGeneration)
            return DoryRendererGenerationHandoff(
                response: DoryRendererGenerationHandoffResponse(
                    ok: true,
                    rendererGeneration: request.requestedRendererGeneration,
                    bootstrapByteCount: UInt64(payload.count),
                    bootstrapSHA256: sha,
                    descriptorCount: 1
                ),
                bootstrapDescriptor: transferredDescriptor
            )
        }
        try server.start()
        defer { server.stop() }

        let handoff = try DoryRendererGenerationHandoffClient.request(
            path: socketPath,
            request: DoryRendererGenerationHandoffRequest(
                token: token,
                machineID: "pc-fixture",
                operationID: DoryOperationIdentity.canonical(operationID),
                resolvedPlanSHA256: String(repeating: "b", count: 64),
                planRevision: 9,
                previousRendererGeneration: 9,
                requestedRendererGeneration: 10
            ),
            authenticateDaemon: { daemonPID, _ in XCTAssertEqual(daemonPID, getpid()) }
        )
        XCTAssertEqual(handoff.response.rendererGeneration, 10)
        XCTAssertEqual(handoff.response.bootstrapSHA256, sha)
        let receivedDescriptor = try XCTUnwrap(handoff.takeBootstrapDescriptor())
        XCTAssertEqual(try readExact(descriptor: receivedDescriptor, count: payload.count), payload)
        handoff.close()
        XCTAssertEqual(try readExact(descriptor: receivedDescriptor, count: payload.count), payload)
        let receivedNumber = receivedDescriptor
        Darwin.close(receivedDescriptor)
        let reusePath = directory + "/reuse"
        try Data("reuse-target".utf8).write(to: URL(fileURLWithPath: reusePath))
        let reusedDescriptor = open(reusePath, O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(reusedDescriptor, 0)
        defer { Darwin.close(reusedDescriptor) }
        if reusedDescriptor == receivedNumber {
            handoff.close()
            XCTAssertEqual(try readAll(descriptor: reusedDescriptor), Data("reuse-target".utf8))
        }
        XCTAssertEqual(observed.snapshot()?.pid, getpid())
        XCTAssertEqual(observed.snapshot()?.generation, 10)
    }

    func testRendererGenerationHandoffRejectsStaleGenerationWithoutDescriptor() throws {
        let directory = try makeTemporaryDirectory(prefix: "dory-renderer-generation-stale")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let socketPath = directory + "/renderer.sock"
        let token = String(repeating: "c", count: DoryRendererGenerationHandoffRequest.tokenByteCount)
        let handlerCalled = LockedBool()
        let server = DoryRendererGenerationHandoffServer(path: socketPath, token: token) { _, _ in
            handlerCalled.set(true)
            return DoryRendererGenerationHandoff(
                response: DoryRendererGenerationHandoffResponse(ok: false, message: "unexpected"),
                bootstrapDescriptor: nil
            )
        }
        try server.start()
        defer { server.stop() }

        XCTAssertThrowsError(try DoryRendererGenerationHandoffClient.request(
            path: socketPath,
            request: DoryRendererGenerationHandoffRequest(
                token: token,
                machineID: "pc-fixture",
                operationID: DoryOperationIdentity.canonical(UUID()),
                resolvedPlanSHA256: String(repeating: "d", count: 64),
                planRevision: 9,
                previousRendererGeneration: 9,
                requestedRendererGeneration: 9
            ),
            authenticateDaemon: { _, _ in XCTFail("daemon authentication should not run for an invalid request") }
        )) { error in
            XCTAssertEqual(
                error as? DoryRendererGenerationHandoffError,
                .invalidRequest
            )
        }
        XCTAssertFalse(handlerCalled.value)
    }


    func testRendererGenerationHandoffRejectsMismatchedResponseGenerationAndClosesDescriptor() throws {
        let directory = try makeTemporaryDirectory(prefix: "dory-renderer-generation-mismatch")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let socketPath = directory + "/renderer.sock"
        let token = String(repeating: "e", count: DoryRendererGenerationHandoffRequest.tokenByteCount)
        let payload = Data(repeating: 0x6d, count: DoryRendererWorkerBootstrapCodec.fixedByteCount)
        let payloadPath = directory + "/bootstrap"
        try payload.write(to: URL(fileURLWithPath: payloadPath))
        let descriptor = open(payloadPath, O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }
        let transferredDescriptor = fcntl(descriptor, F_DUPFD_CLOEXEC, 3)
        XCTAssertGreaterThanOrEqual(transferredDescriptor, 0)
        let server = DoryRendererGenerationHandoffServer(path: socketPath, token: token) { request, _ in
            DoryRendererGenerationHandoff(
                response: DoryRendererGenerationHandoffResponse(
                    ok: true,
                    rendererGeneration: request.requestedRendererGeneration + 1,
                    bootstrapByteCount: UInt64(payload.count),
                    bootstrapSHA256: SHA256Digest.hex(payload),
                    descriptorCount: 1
                ),
                bootstrapDescriptor: transferredDescriptor
            )
        }
        try server.start()
        defer { server.stop() }

        XCTAssertThrowsError(try DoryRendererGenerationHandoffClient.request(
            path: socketPath,
            request: DoryRendererGenerationHandoffRequest(
                token: token,
                machineID: "pc-fixture",
                operationID: DoryOperationIdentity.canonical(UUID()),
                resolvedPlanSHA256: String(repeating: "f", count: 64),
                planRevision: 9,
                previousRendererGeneration: 9,
                requestedRendererGeneration: 10
            ),
            authenticateDaemon: { daemonPID, _ in XCTAssertEqual(daemonPID, getpid()) }
        )) { error in
            XCTAssertEqual(
                (error as? DoryRendererGenerationHandoffError)?.description,
                DoryRendererGenerationHandoffError.invalidResponse.description
            )
        }

        XCTAssertTrue(waitForDescriptorClose(transferredDescriptor))
        XCTAssertEqual(try readExact(descriptor: descriptor, count: payload.count), payload)
    }


    func testRendererGenerationHandoffClosesConsumedDescriptorAfterCountMismatch() throws {
        let directory = try makeTemporaryDirectory(prefix: "dory-renderer-generation-count-mismatch")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let socketPath = directory + "/renderer.sock"
        let token = String(repeating: "1", count: DoryRendererGenerationHandoffRequest.tokenByteCount)
        let payload = Data(repeating: 0x71, count: DoryRendererWorkerBootstrapCodec.fixedByteCount)
        let payloadPath = directory + "/bootstrap"
        try payload.write(to: URL(fileURLWithPath: payloadPath))
        let descriptor = open(payloadPath, O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }
        let transferredDescriptor = fcntl(descriptor, F_DUPFD_CLOEXEC, 3)
        XCTAssertGreaterThanOrEqual(transferredDescriptor, 0)
        let server = DoryRendererGenerationHandoffServer(path: socketPath, token: token) { _, _ in
            DoryRendererGenerationHandoff(
                response: DoryRendererGenerationHandoffResponse(ok: false, message: "rejected-with-fd"),
                bootstrapDescriptor: transferredDescriptor
            )
        }
        try server.start()
        defer { server.stop() }

        XCTAssertThrowsError(try DoryRendererGenerationHandoffClient.request(
            path: socketPath,
            request: DoryRendererGenerationHandoffRequest(
                token: token,
                machineID: "pc-fixture",
                operationID: DoryOperationIdentity.canonical(UUID()),
                resolvedPlanSHA256: String(repeating: "2", count: 64),
                planRevision: 9,
                previousRendererGeneration: 9,
                requestedRendererGeneration: 10
            ),
            authenticateDaemon: { daemonPID, _ in XCTAssertEqual(daemonPID, getpid()) }
        )) { error in
            XCTAssertEqual(
                (error as? DoryRendererGenerationHandoffError)?.description,
                DoryRendererGenerationHandoffError.descriptorCountMismatch(
                    expected: 0,
                    actual: 1
                ).description
            )
        }

        XCTAssertTrue(waitForDescriptorClose(transferredDescriptor))
        XCTAssertEqual(try readExact(descriptor: descriptor, count: payload.count), payload)
    }

    func testOnlyNestedDesktopHelpersUseApplicationLaunchIdentity() {
        XCTAssertEqual(
            MachineManager.processLaunchStyle(
                executablePath: "/Applications/Dory.app/Contents/Helpers/DoryHVRunner.app/Contents/MacOS/dory-hv",
                acceleratedDesktop: true,
                requiresProtectedDeviceAttribution: true
            ),
            .applicationBundle
        )
        XCTAssertEqual(
            MachineManager.processLaunchStyle(
                executablePath: "/bin/sh",
                acceleratedDesktop: true,
                requiresProtectedDeviceAttribution: true
            ),
            .directExecutable
        )
        XCTAssertEqual(
            MachineManager.processLaunchStyle(
                executablePath: "/Applications/Dory.app/Contents/Helpers/DoryVMM.app/Contents/MacOS/dory-vmm",
                acceleratedDesktop: false,
                requiresProtectedDeviceAttribution: true
            ),
            .applicationBundle
        )
        XCTAssertEqual(
            MachineManager.processLaunchStyle(
                executablePath: "/Applications/Dory.app/Contents/Helpers/dory-vmm",
                acceleratedDesktop: false,
                requiresProtectedDeviceAttribution: true
            ),
            .directExecutable
        )
        XCTAssertEqual(
            MachineManager.processLaunchStyle(
                executablePath: "/Applications/Dory.app/Contents/Helpers/DoryHVRunner.app/Contents/MacOS/dory-hv",
                acceleratedDesktop: false,
                requiresProtectedDeviceAttribution: true
            ),
            .directExecutable
        )
        XCTAssertEqual(
            MachineManager.processLaunchStyle(
                executablePath: "/Applications/Dory.app/Contents/Helpers/DoryVMM.app/Contents/MacOS/dory-vmm",
                acceleratedDesktop: false,
                requiresProtectedDeviceAttribution: false
            ),
            .directExecutable
        )
    }

    func testCompatibilityApplicationIdentityStillPinsTeamAndBundle() {
        XCTAssertEqual(
            DoryLiveRunnerCodeIdentity.signedApplication.exactRequirement,
            DoryRendererWorkerIdentity.runnerCodeSigningRequirement
        )
        XCTAssertNil(DoryLiveRunnerCodeIdentity.signedApplication.codeDirectoryHash)
        XCTAssertEqual(
            DoryLiveRunnerCodeIdentity.signedVirtualizationApplication.exactRequirement,
            DoryDesktopApplicationCodeIdentity.vmmRequirement
        )
        XCTAssertTrue(
            DoryLiveRunnerCodeIdentity.signedVirtualizationApplication.exactRequirement
                .contains(#"identifier "dory-vmm""#)
        )
        XCTAssertNil(
            DoryLiveRunnerCodeIdentity.signedVirtualizationApplication.codeDirectoryHash
        )
    }

    func testKqueueMonitorPreservesExitStatusForSupervisedProcess() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Keep the process alive long enough to make kqueue registration deterministic on loaded
        // CI hosts; the behavior under test remains the NOTE_EXITSTATUS payload.
        process.arguments = ["-c", "sleep 0.05; exit 7"]
        try process.run()
        let monitor = try DoryApplicationProcessMonitor(pid: process.processIdentifier)

        let termination = monitor.waitForTermination()
        process.waitUntilExit()

        XCTAssertEqual(termination.status, 7)
        XCTAssertFalse(termination.wasUncaughtSignal)
    }

    func testKqueueMonitorReturnsWithoutWaitingWhenExitPrecededRegistration() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        let monitor = try DoryApplicationProcessMonitor(
            pid: process.processIdentifier,
            terminationObservedAfterRegistration: { true }
        )

        let started = Date()
        let termination = monitor.waitForTermination()

        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        XCTAssertFalse(termination.statusIsKnown)
        XCTAssertEqual(termination.description, "exited; status unavailable")
    }

    func testKqueueMonitorBoundedWaitDoesNotConsumeLaterExitEvent() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        let monitor = try DoryApplicationProcessMonitor(pid: process.processIdentifier)

        let started = Date()
        XCTAssertNil(monitor.waitForTermination(timeout: 0.05))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)

        process.terminate()
        let termination = try XCTUnwrap(monitor.waitForTermination(timeout: 2))
        XCTAssertTrue(termination.wasUncaughtSignal)
        XCTAssertEqual(termination.status, SIGTERM)
    }

    func testAuditTokenSignalRetriesEINTRAndReportsErrno() {
        var attempts = 0
        let delivered = DoryApplicationLaunchHandoffProtocol.signal(
            SIGTERM,
            auditToken: audit_token_t(),
            invoke: { _, _ in
                attempts += 1
                return attempts == 1 ? -1 : 0
            },
            currentErrno: { EINTR }
        )
        XCTAssertEqual(delivered, .delivered)
        XCTAssertEqual(attempts, 2)

        let denied = DoryApplicationLaunchHandoffProtocol.signal(
            SIGKILL,
            auditToken: audit_token_t(),
            invoke: { _, _ in -1 },
            currentErrno: { EPERM }
        )
        XCTAssertEqual(denied, .failed(EPERM))
    }

    func testAuditTokenSignalBoundsRepeatedEINTR() {
        var attempts = 0
        let result = DoryApplicationLaunchHandoffProtocol.signal(
            SIGKILL,
            auditToken: audit_token_t(),
            invoke: { _, _ in
                attempts += 1
                return -1
            },
            currentErrno: { EINTR }
        )

        XCTAssertEqual(result, .failed(EINTR))
        XCTAssertEqual(
            attempts,
            DoryApplicationLaunchHandoffProtocol.maximumInterruptedSignalAttempts
        )
    }

    func testTransportSyscallBoundsRepeatedEINTR() {
        var attempts = 0

        let outcome = DoryApplicationLaunchHandoffProtocol.boundedInterruptedSyscall {
            attempts += 1
            return (-1, EINTR)
        }

        XCTAssertEqual(outcome, .failure(EINTR))
        XCTAssertEqual(
            attempts,
            DoryApplicationLaunchHandoffProtocol.maximumInterruptedTransportAttempts
        )
    }

    func testInterruptedPollCannotResetAbsoluteTransferDeadline() {
        var clock: UInt64 = 1_000
        var pollAttempts = 0
        let deadline = DoryApplicationLaunchHandoffProtocol.TransportDeadline(
            timeout: 0.01,
            monotonicNow: clock
        )

        XCTAssertThrowsError(try DoryApplicationLaunchHandoffProtocol.waitUntilReady(
            descriptor: -1,
            events: Int16(POLLIN),
            deadline: deadline,
            operation: "fixture",
            monotonicNow: {
                defer { clock += 20_000_000 }
                return clock
            },
            pollOperation: { _ in
                pollAttempts += 1
                return (-1, EINTR)
            }
        )) { error in
            XCTAssertEqual(
                error as? DoryApplicationLaunchHandoffError,
                .timeout("fixture")
            )
        }
        XCTAssertEqual(pollAttempts, 1)
    }

    func testTerminalRetirementRetriesOffCallerUntilExactApplicationTerminates() {
        let application = FixtureApplicationTerminationController(terminateAfterAttempts: 2)

        let started = Date()
        let retirement = DoryApplicationTerminalRetirement.begin(
            application: application,
            retryDelay: 0.01
        )
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.1)

        let deadline = Date().addingTimeInterval(1)
        while !application.isTerminated, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(application.isTerminated)
        XCTAssertTrue(retirement.waitForTermination(timeout: 0.1))
        XCTAssertGreaterThanOrEqual(application.forceTerminateAttempts, 2)
    }
}

private enum FixtureDaemonAuthenticationError: Error {
    case rejected
}

private final class LockedLaunchHandoffResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<[String], Error>?

    func set(_ result: Result<[String], Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func get() throws -> Result<[String], Error> {
        lock.lock()
        defer { lock.unlock() }
        return try XCTUnwrap(result)
    }
}

private final class FixtureApplicationTerminationController:
    DoryApplicationTerminationControlling,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let terminateAfterAttempts: Int
    private var attempts = 0

    init(terminateAfterAttempts: Int) {
        self.terminateAfterAttempts = terminateAfterAttempts
    }

    var isTerminated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return attempts >= terminateAfterAttempts
    }

    var forceTerminateAttempts: Int {
        lock.lock()
        defer { lock.unlock() }
        return attempts
    }

    @discardableResult
    func forceTerminate() -> Bool {
        lock.lock()
        attempts += 1
        lock.unlock()
        return true
    }
}

private final class LockedBool: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool { lock.withLock { stored } }

    func set(_ value: Bool) {
        lock.withLock { stored = value }
    }
}

private final class LockedRendererGenerationPeer: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (pid: pid_t, generation: UInt64)?

    func set(pid: pid_t, generation: UInt64) {
        lock.withLock { value = (pid, generation) }
    }

    func snapshot() -> (pid: pid_t, generation: UInt64)? {
        lock.withLock { value }
    }
}

private enum SHA256Digest {
    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}


private func waitForDescriptorClose(_ descriptor: Int32, timeout: TimeInterval = 2) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        errno = 0
        if fcntl(descriptor, F_GETFD) < 0, errno == EBADF {
            return true
        }
        usleep(10_000)
    } while Date() < deadline
    return false
}

private func readExact(descriptor: Int32, count: Int) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    var offset = 0
    while offset < count {
        let readCount = bytes.withUnsafeMutableBytes {
            pread(descriptor, $0.baseAddress!.advanced(by: offset), count - offset, off_t(offset))
        }
        if readCount > 0 {
            offset += readCount
        } else if readCount < 0, errno == EINTR {
            continue
        } else if readCount < 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        } else {
            throw POSIXError(.EIO)
        }
    }
    return Data(bytes)
}

private func readAll(descriptor: Int32) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: 128)
    let count = bytes.withUnsafeMutableBytes {
        pread(descriptor, $0.baseAddress, $0.count, 0)
    }
    guard count >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return Data(bytes.prefix(count))
}

private func makeTemporaryDirectory(prefix: String) throws -> String {
    let directory = "/tmp/\(prefix)-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
    try FileManager.default.createDirectory(
        atPath: directory,
        withIntermediateDirectories: true
    )
    return directory
}
