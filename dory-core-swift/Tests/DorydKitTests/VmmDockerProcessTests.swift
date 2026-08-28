@testable import DorydKit
import XCTest

final class VmmDockerProcessTests: XCTestCase {
    func testImmediateHelperExitUnblocksHandoffWaitAndNotifiesSupervisor() throws {
        let base = "/tmp/dory-vmm-process-exit-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let helper = base + "/exit.sh"
        try "#!/bin/sh\nexit 17\n".write(toFile: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper)
        let callback = expectation(description: "unexpected exit callback")
        let process = VmmDockerProcess(
            configuration: VmmDockerProcessConfiguration(
                executablePath: helper,
                arguments: [],
                stateDirectory: base + "/state",
                handoffSocketPath: base + "/state/handoff.sock",
                readyTimeoutSeconds: 10
            ),
            unexpectedTerminationHandler: { termination in
                XCTAssertEqual(termination.status, 17)
                callback.fulfill()
            }
        )

        let startedAt = Date()
        XCTAssertThrowsError(try process.start()) { error in
            XCTAssertTrue("\(error)".contains("did not become ready"), "\(error)")
        }

        wait(for: [callback], timeout: 1)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
        XCTAssertFalse(process.isRunning)
        XCTAssertNil(process.pid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base + "/state/handoff.sock"))
    }

    func testStopCancelsBlockedHandoffAndReapsHelper() throws {
        let base = "/tmp/dory-vmm-process-cancel-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let handoffPath = base + "/state/handoff.sock"
        let process = VmmDockerProcess(
            configuration: VmmDockerProcessConfiguration(
                executablePath: "/bin/sleep",
                arguments: ["30"],
                stateDirectory: base + "/state",
                handoffSocketPath: handoffPath,
                readyTimeoutSeconds: 30
            )
        )
        let startError = LockedVmmErrorBox()
        let startFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            do {
                try process.start()
            } catch {
                startError.set(error)
            }
            startFinished.signal()
        }

        let deadline = Date().addingTimeInterval(2)
        while process.pid == nil, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        let helperPID = try XCTUnwrap(process.pid)

        let stoppedAt = Date()
        process.stop()

        XCTAssertEqual(startFinished.wait(timeout: .now() + 1), .success)
        XCTAssertLessThan(Date().timeIntervalSince(stoppedAt), 1)
        XCTAssertTrue(startError.value.map { "\($0)".contains("start was cancelled") } ?? false)
        XCTAssertFalse(process.isRunning)
        XCTAssertNil(process.pid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: handoffPath))
        XCTAssertEqual(kill(helperPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testStopBeforeFirstStartPreventsLateSpawn() throws {
        let base = "/tmp/dory-vmm-process-prestart-cancel-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let handoffPath = base + "/state/handoff.sock"
        let process = VmmDockerProcess(
            configuration: VmmDockerProcessConfiguration(
                executablePath: "/bin/sleep",
                arguments: ["30"],
                stateDirectory: base + "/state",
                handoffSocketPath: handoffPath,
                readyTimeoutSeconds: 30
            )
        )

        process.stop()

        XCTAssertThrowsError(try process.start()) { error in
            XCTAssertTrue("\(error)".contains("start was cancelled"), "\(error)")
        }
        XCTAssertFalse(process.isRunning)
        XCTAssertNil(process.pid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: handoffPath))
    }

    func testBlockedPublishedLaunchQueuesOneBoundedStopAndReapsExactGeneration() throws {
        let base = "/tmp/dory-vmm-process-deferred-stop-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let launchPublished = DispatchSemaphore(value: 0)
        let releaseLaunch = DispatchSemaphore(value: 0)
        let startFinished = DispatchSemaphore(value: 0)
        let launchedPID = LockedVmmPIDBox()
        let startError = LockedVmmErrorBox()
        let process = VmmDockerProcess(configuration: VmmDockerProcessConfiguration(
            executablePath: "/bin/sleep",
            arguments: ["30"],
            stateDirectory: base + "/state",
            handoffSocketPath: base + "/state/handoff.sock",
            readyTimeoutSeconds: 30
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

        let stopStartedAt = ProcessInfo.processInfo.systemUptime
        XCTAssertFalse(process.stopForTesting(timeout: 0.015, forcedTimeout: 0.015))
        XCTAssertLessThan(
            ProcessInfo.processInfo.systemUptime - stopStartedAt,
            0.15,
            "a blocked spawn reservation must not escape the caller's stop budget"
        )
        let observationStartedAt = ProcessInfo.processInfo.systemUptime
        XCTAssertNil(process.lifecycleObservation(until: .now() + 0.02))
        XCTAssertLessThan(
            ProcessInfo.processInfo.systemUptime - observationStartedAt,
            0.1,
            "status observation must remain bounded while launch owns the mutex"
        )

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
        XCTAssertFalse(FileManager.default.fileExists(atPath: base + "/state/handoff.sock"))

        let pid = try XCTUnwrap(launchedPID.value)
        errno = 0
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH, "the exact late-spawned generation must be reaped")
    }

    func testDockerDiskLaunchUsesPrivateDuplicateAcrossAuthorityCloseAndFDReuse() throws {
        let base = "/tmp/dory-vmm-disk-fd-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let trustedPath = base + "/trusted.img"
        let sentinelPath = base + "/sentinel.img"
        let observedPath = base + "/observed.txt"
        let argumentsPath = base + "/arguments.txt"
        try Data("trusted-authority".utf8).write(to: URL(fileURLWithPath: trustedPath))
        try Data("reused-sentinel".utf8).write(to: URL(fileURLWithPath: sentinelPath))
        let sourceDescriptor = open(trustedPath, O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(sourceDescriptor, 0)
        let authority = HvProcessInheritedFileDescriptor(
            name: "dockerDataDisk",
            takingOwnershipOf: sourceDescriptor,
            childDescriptor: VmmDockerProcessConfiguration.dockerDataDiskChildDescriptor
        )

        let helper = base + "/inspect.sh"
        let script = """
        #!/bin/sh
        /usr/bin/head -c 17 /dev/fd/19 > \(observedPath)
        printf '%s\n' "$@" > \(argumentsPath)
        exit 0
        """
        try script.write(toFile: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper)
        let filesystemUUID = UUID(uuidString: "01234567-89ab-4cde-8f01-23456789abcd")!
        let process = VmmDockerProcess(configuration: VmmDockerProcessConfiguration(
            executablePath: helper,
            arguments: ["base-argument"],
            stateDirectory: base + "/state",
            handoffSocketPath: base + "/state/handoff.sock",
            readyTimeoutSeconds: 10,
            inheritedDockerDataDisk: authority,
            dockerDataDiskFilesystemUUID: filesystemUUID
        ))

        let reusedDescriptor = LockedVmmPIDBox()
        process.installPostDescriptorDuplicationGateForTesting {
            authority.close()
            reusedDescriptor.set(open(sentinelPath, O_RDONLY | O_CLOEXEC))
        }
        defer {
            if let descriptor = reusedDescriptor.value, descriptor >= 0 { close(descriptor) }
        }

        XCTAssertThrowsError(try process.start())
        XCTAssertEqual(
            reusedDescriptor.value,
            sourceDescriptor,
            "the test must force exact FD reuse"
        )
        XCTAssertEqual(
            try String(contentsOfFile: observedPath, encoding: .utf8),
            "trusted-authority"
        )
        XCTAssertEqual(
            try String(contentsOfFile: argumentsPath, encoding: .utf8)
                .split(separator: "\n")
                .map(String.init),
            [
                "base-argument",
                "--docker-data-disk-fd",
                "19",
                "--docker-data-disk-uuid",
                "01234567-89ab-4cde-8f01-23456789abcd",
            ]
        )
    }

    func testDockerDiskSupervisorRejectsShadowArgumentsAndIncompleteAuthority() throws {
        let base = "/tmp/dory-vmm-disk-contract-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let disk = base + "/disk.img"
        XCTAssertTrue(FileManager.default.createFile(atPath: disk, contents: nil))
        let descriptor = open(disk, O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        let authority = HvProcessInheritedFileDescriptor(
            name: "dockerDataDisk",
            takingOwnershipOf: descriptor,
            childDescriptor: VmmDockerProcessConfiguration.dockerDataDiskChildDescriptor
        )
        defer { authority.close() }

        let shadowed = VmmDockerProcess(configuration: VmmDockerProcessConfiguration(
            executablePath: "/bin/false",
            arguments: ["--docker-data-disk-fd", "7"],
            stateDirectory: base + "/shadowed",
            handoffSocketPath: base + "/shadowed/handoff.sock",
            inheritedDockerDataDisk: authority,
            dockerDataDiskFilesystemUUID: UUID()
        ))
        XCTAssertThrowsError(try shadowed.start()) { error in
            XCTAssertTrue("\(error)".contains("supervisor-owned"), "\(error)")
        }

        let missingUUID = VmmDockerProcess(configuration: VmmDockerProcessConfiguration(
            executablePath: "/bin/false",
            arguments: [],
            stateDirectory: base + "/missing-uuid",
            handoffSocketPath: base + "/missing-uuid/handoff.sock",
            inheritedDockerDataDisk: authority
        ))
        XCTAssertThrowsError(try missingUUID.start()) { error in
            XCTAssertTrue("\(error)".contains("without a filesystem UUID"), "\(error)")
        }
    }

    func testRetainedTargetRefusesToSignalAfterExactTerminalObservation() {
        let signals = LockedVmmSignalBox()
        let child = VmmSupervisedChild(pid: 41) { pid, signal in
            signals.append(pid: pid, signal: signal)
            return true
        }

        XCTAssertTrue(child.send(SIGSTOP))
        child.markTerminationObserved()

        // Even if PID 41 has since been recycled, no system signal operation is reached once the
        // retained generation has recorded terminal observation.
        XCTAssertFalse(child.send(SIGCONT))
        XCTAssertEqual(signals.value.map(\.pid), [41])
        XCTAssertEqual(signals.value.map(\.signal), [SIGSTOP])
    }

    func testTerminalObservationSerializesWithInFlightExactTargetSignal() {
        let signalEntered = DispatchSemaphore(value: 0)
        let releaseSignal = DispatchSemaphore(value: 0)
        let signalFinished = DispatchSemaphore(value: 0)
        let observationAttempting = DispatchSemaphore(value: 0)
        let observationFinished = DispatchSemaphore(value: 0)
        let signals = LockedVmmSignalBox()
        let child = VmmSupervisedChild(pid: 73) { pid, signal in
            signals.append(pid: pid, signal: signal)
            signalEntered.signal()
            releaseSignal.wait()
            return true
        }

        DispatchQueue.global(qos: .userInitiated).async {
            _ = child.send(SIGTERM)
            signalFinished.signal()
        }
        XCTAssertEqual(signalEntered.wait(timeout: .now() + 1), .success)
        DispatchQueue.global(qos: .userInitiated).async {
            observationAttempting.signal()
            child.markTerminationObserved()
            observationFinished.signal()
        }

        XCTAssertEqual(observationAttempting.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(observationFinished.wait(timeout: .now() + 0.03), .timedOut)
        releaseSignal.signal()
        XCTAssertEqual(signalFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(observationFinished.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(child.send(SIGKILL))
        XCTAssertEqual(signals.value.count, 1)
    }
}

private final class LockedVmmErrorBox: @unchecked Sendable {
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

private final class LockedVmmPIDBox: @unchecked Sendable {
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

private final class LockedVmmSignalBox: @unchecked Sendable {
    struct Observation: Equatable {
        let pid: pid_t
        let signal: Int32
    }

    private let lock = NSLock()
    private var stored: [Observation] = []

    var value: [Observation] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func append(pid: pid_t, signal: Int32) {
        lock.lock()
        stored.append(Observation(pid: pid, signal: signal))
        lock.unlock()
    }
}
