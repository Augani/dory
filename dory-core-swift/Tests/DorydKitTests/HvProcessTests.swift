@testable import DorydKit
import Darwin
import DoryRendererWorkerWireContracts
import XCTest

final class HvProcessTests: XCTestCase {
    func testStartsAndStopsChildProcess() throws {
        let process = HvProcess(configuration: HvProcessConfiguration(
            executablePath: "/bin/sleep",
            arguments: ["10"]
        ))

        try process.start()
        XCTAssertTrue(process.isRunning)
        XCTAssertNotNil(process.pid)

        process.stop()
        XCTAssertFalse(process.isRunning)
        XCTAssertNil(process.pid)
    }

    func testSuspendsAndResumesChildProcess() throws {
        let process = HvProcess(configuration: HvProcessConfiguration(
            executablePath: "/bin/sleep",
            arguments: ["10"]
        ))

        try process.start()
        defer { process.stop() }
        let pid = try XCTUnwrap(process.pid)

        XCTAssertTrue(process.suspend())
        XCTAssertTrue(process.isRunning)
        XCTAssertTrue(process.isSuspended)
        XCTAssertEqual(process.pid, pid)

        XCTAssertTrue(process.resume())
        XCTAssertTrue(process.isRunning)
        XCTAssertFalse(process.isSuspended)
        XCTAssertEqual(process.pid, pid)
    }

    func testRestartsUnexpectedExitUpToLimit() throws {
        let directory = "/tmp/dory-hv-process-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let marker = directory + "/runs"
        let script = directory + "/exit-fast.sh"
        try """
        #!/bin/sh
        echo run >> "$1"
        exit 7
        """.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)

        let process = HvProcess(configuration: HvProcessConfiguration(
            executablePath: script,
            arguments: [marker],
            restartPolicy: HvRestartPolicy(maxRestarts: 1, delaySeconds: 0.01)
        ))
        try process.start()

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let runs = (try? String(contentsOfFile: marker, encoding: .utf8))?
                .split(separator: "\n")
                .count ?? 0
            if runs >= 2 { break }
            Thread.sleep(forTimeInterval: 0.02)
        }

        let runs = try String(contentsOfFile: marker, encoding: .utf8)
            .split(separator: "\n")
            .count
        XCTAssertEqual(runs, 2)
        process.stop()
    }

    func testPendingStartupRestartRemainsActiveAndCanBeDisabled() throws {
        let directory = "/tmp/dory-hv-startup-retry-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let marker = directory + "/runs"
        let script = directory + "/retry-then-hold.sh"
        try """
        #!/bin/sh
        printf 'run\n' >> "$1"
        count=$(wc -l < "$1" | tr -d ' ')
        test "$count" -ne 1 || exit 7
        exec /bin/sleep 30
        """.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)

        let process = HvProcess(configuration: HvProcessConfiguration(
            executablePath: script,
            arguments: [marker],
            restartPolicy: HvRestartPolicy(maxRestarts: 2, delaySeconds: 0.2)
        ))
        try process.start()

        let firstRunDeadline = Date().addingTimeInterval(2)
        while Date() < firstRunDeadline,
              ((try? String(contentsOfFile: marker, encoding: .utf8))?
                .split(separator: "\n").count ?? 0) < 1 {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(process.isRunningOrRestarting)

        let secondRunDeadline = Date().addingTimeInterval(2)
        while Date() < secondRunDeadline,
              ((try? String(contentsOfFile: marker, encoding: .utf8))?
                .split(separator: "\n").count ?? 0) < 2 {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let pid = try XCTUnwrap(process.pid)
        process.disableRestarts()
        XCTAssertEqual(kill(pid, SIGKILL), 0)

        let stoppedDeadline = Date().addingTimeInterval(2)
        while Date() < stoppedDeadline, process.isRunningOrRestarting {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertFalse(process.isRunningOrRestarting)
        XCTAssertEqual(try String(contentsOfFile: marker, encoding: .utf8).split(separator: "\n").count, 2)
    }

    func testUnexpectedExitNotifiesSupervisor() throws {
        let callback = expectation(description: "unexpected termination callback")
        let captured = LockedTermination()
        let process = HvProcess(
            configuration: HvProcessConfiguration(
                executablePath: "/bin/sleep",
                arguments: ["10"]
            ),
            unexpectedTerminationHandler: { termination in
                captured.set(termination)
                callback.fulfill()
            }
        )
        try process.start()
        let pid = try XCTUnwrap(process.pid)

        XCTAssertEqual(kill(pid, SIGKILL), 0)
        wait(for: [callback], timeout: 1)

        XCTAssertEqual(captured.value?.status, SIGKILL)
        XCTAssertEqual(captured.value?.wasUncaughtSignal, true)
        XCTAssertFalse(process.isRunning)
    }

    func testExplicitStopDoesNotNotifyUnexpectedTerminationHandler() throws {
        let callback = expectation(description: "no unexpected callback")
        callback.isInverted = true
        let process = HvProcess(
            configuration: HvProcessConfiguration(
                executablePath: "/bin/sleep",
                arguments: ["10"]
            ),
            unexpectedTerminationHandler: { _ in callback.fulfill() }
        )
        try process.start()

        process.stop()
        wait(for: [callback], timeout: 0.15)

        XCTAssertFalse(process.isRunning)
        XCTAssertNil(process.pid)
    }

    func testConcurrentStopsShareProcessTerminationCompletion() throws {
        let process = HvProcess(configuration: HvProcessConfiguration(
            executablePath: "/bin/sh",
            arguments: ["-c", "trap 'sleep 0.5; exit 0' TERM; while true; do sleep 0.05; done"]
        ))
        try process.start()
        Thread.sleep(forTimeInterval: 0.1)

        let callersReady = DispatchGroup()
        let callersFinished = DispatchGroup()
        let startGate = DispatchSemaphore(value: 0)
        for _ in 0..<2 {
            callersReady.enter()
            callersFinished.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                callersReady.leave()
                startGate.wait()
                process.stop(timeout: 1.5)
                callersFinished.leave()
            }
        }
        XCTAssertEqual(callersReady.wait(timeout: .now() + 1), .success)

        let startedAt = Date()
        startGate.signal()
        startGate.signal()
        XCTAssertEqual(callersFinished.wait(timeout: .now() + 1), .success)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
        XCTAssertFalse(process.isRunning)
        XCTAssertNil(process.pid)
    }

    func testStopBeforeFirstStartPreventsLateSpawn() throws {
        let process = HvProcess(configuration: HvProcessConfiguration(
            executablePath: "/bin/sleep",
            arguments: ["30"]
        ))

        process.stop()

        XCTAssertThrowsError(try process.start()) { error in
            XCTAssertTrue("\(error)".contains("start was cancelled"), "\(error)")
        }
        XCTAssertFalse(process.isRunning)
        XCTAssertNil(process.pid)
    }

    func testBlockedPublishedLaunchQueuesOneBoundedStopAndReapsExactGeneration() throws {
        let launchPublished = DispatchSemaphore(value: 0)
        let releaseLaunch = DispatchSemaphore(value: 0)
        let startFinished = DispatchSemaphore(value: 0)
        let launchedPID = LockedHvPIDBox()
        let startError = LockedHvErrorBox()
        let process = HvProcess(configuration: HvProcessConfiguration(
            executablePath: "/bin/sleep",
            arguments: ["30"]
        ))
        process.installPostPublicationLifecycleGateForTesting { pid in
            launchedPID.set(pid)
            launchPublished.signal()
            releaseLaunch.wait()
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try process.start()
            } catch {
                startError.set(error)
            }
            startFinished.signal()
        }
        XCTAssertEqual(launchPublished.wait(timeout: .now() + 1), .success)

        let stopFinished = DispatchSemaphore(value: 0)
        let stopResult = LockedHvBoolBox()
        DispatchQueue.global(qos: .userInitiated).async {
            stopResult.set(process.stopForTesting(timeout: 0.015, forcedTimeout: 0.015))
            stopFinished.signal()
        }
        XCTAssertEqual(
            stopFinished.wait(timeout: .now() + 1),
            .success,
            "a blocked launch mutex must not escape the caller's complete stop budget"
        )
        XCTAssertEqual(stopResult.value, false)

        let observationFinished = DispatchSemaphore(value: 0)
        let observationResult = LockedHvObservationBox()
        DispatchQueue.global(qos: .userInitiated).async {
            observationResult.set(process.lifecycleObservation(until: .now() + 0.02))
            observationFinished.signal()
        }
        XCTAssertEqual(
            observationFinished.wait(timeout: .now() + 1),
            .success,
            "status observation must return unknown instead of waiting behind launch"
        )
        XCTAssertNil(observationResult.value)

        releaseLaunch.signal()
        XCTAssertEqual(startFinished.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(
            startError.value.map { "\($0)".contains("start was cancelled") } ?? false,
            "\(String(describing: startError.value))"
        )
        XCTAssertTrue(process.waitForTermination(timeout: 2))
        XCTAssertEqual(
            process.lifecycleObservation(until: .now() + 0.1),
            DockerManagedProcessObservation(pid: nil, isRunning: false)
        )

        let pid = try XCTUnwrap(launchedPID.value)
        errno = 0
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH, "the exact late-spawned generation must be reaped")
    }

    func testDeferredStopCoordinatorCoalescesAndJoinsOneOperation() {
        let coordinator = DoryDeferredProcessStopCoordinator(
            label: "dev.dory.tests.deferred-stop"
        )
        let operationEntered = DispatchSemaphore(value: 0)
        let releaseOperation = DispatchSemaphore(value: 0)

        XCTAssertTrue(coordinator.schedule(
            signal: SIGTERM,
            gracefulTimeout: 0.01,
            forcedTimeout: 0.01
        ) { signal, graceful, forced in
            XCTAssertEqual(signal, SIGTERM)
            XCTAssertEqual(graceful, 0.01)
            XCTAssertEqual(forced, 0.01)
            operationEntered.signal()
            releaseOperation.wait()
        })
        XCTAssertEqual(operationEntered.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(coordinator.schedule(
            signal: SIGKILL,
            gracefulTimeout: 1,
            forcedTimeout: 1
        ) { _, _, _ in
            XCTFail("a second deferred signal operation must not be queued")
        })
        XCTAssertFalse(coordinator.wait(until: .now() + 0.02))

        releaseOperation.signal()
        XCTAssertTrue(coordinator.wait(until: .now() + 1))
        XCTAssertFalse(coordinator.isPending)
    }

    func testTerminationEscalationReturnsAfterBothBoundedWaitsExpire() {
        let waiter = DispatchGroup()
        waiter.enter()
        defer { waiter.leave() }
        var forced = false

        let started = Date()
        let terminated = HvProcess.waitForTermination(
            waiter: waiter,
            gracefulTimeout: 0.01,
            forcedTimeout: 0.01,
            sendForcedTermination: { forced = true }
        )

        XCTAssertFalse(terminated)
        XCTAssertTrue(forced)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.25)
    }

    func testAbsoluteStopBudgetBeginsBeforeLifecycleMutexAcquisition() {
        let lifecycleMutex = DoryProcessLifecycleMutex()
        lifecycleMutex.lock()
        let deadlineStartedAt = DispatchTime.now()
        let deadline = DoryProcessStopDeadline(
            gracefulTimeout: 0.04,
            forcedTimeout: 0.08,
            startedAt: deadlineStartedAt
        )
        XCTAssertEqual(
            deadline.graceful.uptimeNanoseconds,
            deadlineStartedAt.uptimeNanoseconds + 40_000_000
        )
        XCTAssertEqual(
            deadline.final.uptimeNanoseconds,
            deadlineStartedAt.uptimeNanoseconds + 120_000_000
        )
        let waiter = DispatchGroup()
        waiter.enter()
        defer { waiter.leave() }
        let mutexRelease = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.07) {
            lifecycleMutex.unlock()
            mutexRelease.signal()
        }

        XCTAssertTrue(lifecycleMutex.lock(until: deadline.final))
        lifecycleMutex.unlock()
        var forced = false
        var observedWaitDeadlines: [DispatchTime] = []
        let terminated = HvProcess.waitForTermination(
            waiter: waiter,
            deadline: deadline,
            waitUntil: { deadline in
                observedWaitDeadlines.append(deadline)
                return .timedOut
            },
            sendForcedTermination: { forced = true }
        )
        XCTAssertFalse(terminated)
        XCTAssertTrue(forced)
        XCTAssertEqual(observedWaitDeadlines, [deadline.graceful, deadline.final])
        XCTAssertEqual(mutexRelease.wait(timeout: .now() + 0.1), .success)
        // Both waits consumed the one deadline created before mutex acquisition. Inspecting those
        // exact arguments proves the forced phase was not restarted after the mutex cleared;
        // host scheduler latency is deliberately not treated as process-supervisor behavior.
    }

    func testLifecycleMutexAcquisitionCannotOutliveFinalStopDeadline() {
        let lifecycleMutex = DoryProcessLifecycleMutex()
        lifecycleMutex.lock()
        defer { lifecycleMutex.unlock() }
        let deadlineStartedAt = DispatchTime.now()
        let deadline = DoryProcessStopDeadline(
            gracefulTimeout: 0.01,
            forcedTimeout: 0.02,
            startedAt: deadlineStartedAt
        )
        XCTAssertEqual(
            deadline.final.uptimeNanoseconds,
            deadlineStartedAt.uptimeNanoseconds + 30_000_000
        )

        XCTAssertFalse(lifecycleMutex.lock(until: deadline.final))
    }

    func testExpiredAbsoluteStopBudgetCannotRestartAtEscalationPhase() {
        let waiter = DispatchGroup()
        waiter.enter()
        defer { waiter.leave() }
        let now = DispatchTime.now().uptimeNanoseconds
        let startedAt = DispatchTime(
            uptimeNanoseconds: now > 2_000_000_000 ? now - 2_000_000_000 : 0
        )
        let expiredDeadline = DoryProcessStopDeadline(
            gracefulTimeout: 0.25,
            forcedTimeout: 0.25,
            startedAt: startedAt
        )
        var forced = false

        let beganWaiting = ProcessInfo.processInfo.systemUptime
        let terminated = HvProcess.waitForTermination(
            waiter: waiter,
            deadline: expiredDeadline,
            sendForcedTermination: { forced = true }
        )

        XCTAssertFalse(terminated)
        XCTAssertTrue(forced)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - beganWaiting, 0.05)
    }

    func testNonFiniteStopDurationsAreConvertedToFiniteBudgets() {
        let startedAt = DispatchTime(uptimeNanoseconds: 1_000)
        let deadline = DoryProcessStopDeadline(
            gracefulTimeout: .infinity,
            forcedTimeout: .nan,
            startedAt: startedAt
        )

        XCTAssertEqual(deadline.graceful.uptimeNanoseconds, 5_000_001_000)
        XCTAssertEqual(deadline.final.uptimeNanoseconds, 7_000_001_000)
    }

    func testDirectChildSignalBoundsRepeatedEINTR() {
        var attempts = 0

        let error = HvProcess.signalErrorWithBoundedRetries {
            attempts += 1
            return (false, EINTR)
        }

        XCTAssertEqual(error, EINTR)
        XCTAssertEqual(attempts, 8)
    }

    func testDirectChildSignalRetriesEINTRBeforeSuccess() {
        var attempts = 0

        let error = HvProcess.signalErrorWithBoundedRetries {
            attempts += 1
            return attempts == 1 ? (false, EINTR) : (true, 0)
        }

        XCTAssertNil(error)
        XCTAssertEqual(attempts, 2)
    }

    func testUnpublishedChildObservationBoundsRepeatedEINTR() {
        var attempts = 0

        let observation = HvProcess.observeUnpublishedChild(pid: 42) {
            attempts += 1
            return (-1, EINTR)
        }

        XCTAssertEqual(observation, .failed(EINTR))
        XCTAssertEqual(attempts, HvProcess.maximumInterruptedWaitAttempts)
    }

    func testUnpublishedChildNonterminalWaitHonorsHardDeadline() {
        var observations = 0
        var clock: UInt64 = 1_000

        let reaped = HvProcess.waitForUnpublishedChildTermination(
            pid: 42,
            timeout: 0.01,
            pollInterval: 0.001,
            monotonicNow: {
                defer { clock += 20_000_000 }
                return clock
            },
            pause: { _ in },
            wait: { _ in
                observations += 1
                return .running
            }
        )

        XCTAssertFalse(reaped)
        XCTAssertEqual(observations, 1)
    }

    func testDirectChildWaitRetainsAuthorityAcrossFailureAndNonterminalObservation() {
        var observations = [
            (result: Int32(-1), error: Int32(EIO), code: Int32(0)),
            (result: Int32(0), error: Int32(0), code: Int32(CLD_STOPPED)),
            (result: Int32(0), error: Int32(0), code: Int32(CLD_EXITED)),
        ]
        var consumedNonterminal = 0
        var pauses = 0

        let terminal = HvProcess.waitForDirectChildTerminalObservation(
            waitidOperation: { observations.removeFirst() },
            consumeNonterminalObservation: { consumedNonterminal += 1 },
            pause: { _ in pauses += 1 }
        )

        XCTAssertEqual(terminal, .exited)
        XCTAssertEqual(consumedNonterminal, 1)
        XCTAssertEqual(pauses, 2)
        XCTAssertTrue(observations.isEmpty)
    }

    func testLegacyLaunchDoesNotInvokeSuspendedCodeValidator() throws {
        let validator = RecordingSuspendedChildCodeValidator(decisions: [.reject])
        let process = HvProcess(
            configuration: HvProcessConfiguration(
                executablePath: "/bin/sleep",
                arguments: ["10"]
            ),
            suspendedChildCodeValidator: validator
        )

        try process.start()
        defer { process.stop() }

        XCTAssertTrue(process.isRunning)
        XCTAssertEqual(validator.observations.count, 0)
    }

    func testRendererReleaseIdentityValidatesSuspendedChildBeforeExecution() throws {
        let directory = try makeTemporaryDirectory(prefix: "dory-hv-identity-success")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let marker = directory + "/executed"
        let script = try makeExecutableScript(
            in: directory,
            name: "mark-then-sleep.sh",
            body: """
            #!/bin/sh
            printf 'executed\\n' > "$1"
            exec /bin/sleep 30
            """
        )
        let releaseIdentity = try makeRendererReleaseIdentity()
        let validator = RecordingSuspendedChildCodeValidator(
            decisions: [.accept],
            markerPath: marker,
            observationDelay: 0.05
        )
        var configuration = HvProcessConfiguration(
            executablePath: script,
            arguments: [marker]
        )
        configuration.rendererReleaseIdentity = releaseIdentity
        let process = HvProcess(
            configuration: configuration,
            suspendedChildCodeValidator: validator
        )

        try process.start()
        defer { process.stop() }

        let observation = try XCTUnwrap(validator.observations.first)
        XCTAssertEqual(observation.pid, process.pid)
        XCTAssertEqual(
            observation.identity,
            DoryLiveRunnerCodeIdentity(
                codeDirectoryHash: releaseIdentity.runnerCodeDirectoryHash
            )
        )
        XCTAssertFalse(observation.markerExisted)
        let markerDeadline = Date().addingTimeInterval(1)
        while Date() < markerDeadline,
              !FileManager.default.fileExists(atPath: marker) {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker))
        XCTAssertTrue(process.isRunning)
    }

    func testRejectedRendererIdentityIsKilledReapedAndNeverRestarted() throws {
        let directory = try makeTemporaryDirectory(prefix: "dory-hv-identity-reject")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let marker = directory + "/runs"
        let script = try makeExecutableScript(
            in: directory,
            name: "mark-and-exit.sh",
            body: """
            #!/bin/sh
            printf 'run\\n' >> "$1"
            exit 7
            """
        )
        let validator = RecordingSuspendedChildCodeValidator(
            decisions: [.accept, .reject, .accept],
            markerPath: marker
        )
        var configuration = HvProcessConfiguration(
            executablePath: script,
            arguments: [marker],
            restartPolicy: HvRestartPolicy(
                maxRestarts: 3,
                delaySeconds: 0.01,
                maximumDelaySeconds: 0.01
            )
        )
        configuration.rendererReleaseIdentity = try makeRendererReleaseIdentity()
        let process = HvProcess(
            configuration: configuration,
            suspendedChildCodeValidator: validator
        )

        try process.start()

        let validationDeadline = Date().addingTimeInterval(2)
        while Date() < validationDeadline,
              validator.observations.count < 2 {
            Thread.sleep(forTimeInterval: 0.01)
        }
        Thread.sleep(forTimeInterval: 0.1)

        let observations = validator.observations
        XCTAssertEqual(observations.count, 2)
        XCTAssertEqual(
            (try? String(contentsOfFile: marker, encoding: .utf8))?
                .split(separator: "\n").count,
            1
        )
        XCTAssertFalse(process.isRunning)
        XCTAssertFalse(process.isRunningOrRestarting)
        XCTAssertNil(process.pid)
        XCTAssertTrue(process.launchError?.contains("identity was rejected") == true)

        let rejectedPID = try XCTUnwrap(observations.last?.pid)
        var status: Int32 = 0
        errno = 0
        XCTAssertEqual(waitpid(rejectedPID, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
    }
}

private final class LockedTermination: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: HvProcessTermination?

    var value: HvProcessTermination? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ termination: HvProcessTermination) {
        lock.lock()
        stored = termination
        lock.unlock()
    }
}

private final class LockedHvPIDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int32?

    var value: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: Int32) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}

private final class LockedHvErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?

    var value: Error? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ error: Error) {
        lock.lock()
        stored = error
        lock.unlock()
    }
}

private final class LockedHvBoolBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?

    var value: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: Bool) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}

private final class LockedHvObservationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: DockerManagedProcessObservation?

    var value: DockerManagedProcessObservation? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: DockerManagedProcessObservation?) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}

private enum SuspendedChildValidationDecision {
    case accept
    case reject
}

private struct SuspendedChildValidationObservation: Equatable {
    var pid: pid_t
    var identity: DoryLiveRunnerCodeIdentity
    var markerExisted: Bool
}

private enum FixtureSuspendedChildValidationError: Error {
    case rejected
}

private final class RecordingSuspendedChildCodeValidator:
    DoryLaunchGatedChildCodeValidating,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let decisions: [SuspendedChildValidationDecision]
    private let markerPath: String?
    private let observationDelay: TimeInterval
    private var storedObservations: [SuspendedChildValidationObservation] = []

    init(
        decisions: [SuspendedChildValidationDecision],
        markerPath: String? = nil,
        observationDelay: TimeInterval = 0
    ) {
        self.decisions = decisions
        self.markerPath = markerPath
        self.observationDelay = observationDelay
    }

    var observations: [SuspendedChildValidationObservation] {
        lock.lock()
        defer { lock.unlock() }
        return storedObservations
    }

    func validateLaunchGatedChild(
        pid: pid_t,
        expectedIdentity: DoryLiveRunnerCodeIdentity
    ) throws {
        if observationDelay > 0 {
            Thread.sleep(forTimeInterval: observationDelay)
        }
        let markerExisted = markerPath.map {
            FileManager.default.fileExists(atPath: $0)
        } ?? false
        let decision: SuspendedChildValidationDecision
        lock.lock()
        let index = storedObservations.count
        storedObservations.append(SuspendedChildValidationObservation(
            pid: pid,
            identity: expectedIdentity,
            markerExisted: markerExisted
        ))
        decision = index < decisions.count ? decisions[index] : .reject
        lock.unlock()
        if case .reject = decision {
            throw FixtureSuspendedChildValidationError.rejected
        }
    }
}

private func makeRendererReleaseIdentity() throws -> DoryRendererReleaseIdentityV1 {
    DoryRendererReleaseIdentityV1(
        runnerCodeDirectoryHash: try DoryCodeDirectoryHash(
            lowercaseHexadecimal: String(repeating: "11", count: 20)
        ),
        rendererWorkerCodeDirectoryHash: try DoryCodeDirectoryHash(
            lowercaseHexadecimal: String(repeating: "22", count: 20)
        ),
        tupleDefinitionSHA256: try DoryRendererArtifactDigest(
            lowercaseSHA256: DoryRendererSourceTuple.productionDefinitionSHA256
        )
    )
}

private func makeTemporaryDirectory(prefix: String) throws -> String {
    let directory = "/tmp/\(prefix)-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
    try FileManager.default.createDirectory(
        atPath: directory,
        withIntermediateDirectories: true
    )
    return directory
}

private func makeExecutableScript(
    in directory: String,
    name: String,
    body: String
) throws -> String {
    let path = directory + "/" + name
    try body.write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: path
    )
    return path
}
