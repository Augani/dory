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
    DorySuspendedChildCodeValidating,
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

    func validateSuspendedChild(
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
