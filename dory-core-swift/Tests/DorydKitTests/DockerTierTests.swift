import Darwin
import DoryCore
@testable import DorydKit
import Foundation
import XCTest

final class DockerTierTests: XCTestCase {
    func testStartServesDockerSocketThroughForwardDataplane() throws {
        let base = "/tmp/dory-tier-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let forwardPath = base + "/forward.sock"
        let listener = try bindUnixListener(path: forwardPath)
        defer { close(listener) }

        let capture = Capture()
        let serverDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let accepted = accept(listener, nil, nil)
            guard accepted >= 0 else {
                capture.setError("accept failed: \(errno)")
                serverDone.signal()
                return
            }
            defer {
                close(accepted)
                serverDone.signal()
            }

            guard let lengthBytes = readExactly(4, from: accepted) else {
                capture.setError("missing preamble length")
                return
            }
            let length = le32(lengthBytes)
            guard let preamble = readExactly(Int(length), from: accepted) else {
                capture.setError("missing preamble body")
                return
            }
            capture.setPreamble(preamble)

            guard let request = readUntilHeaderEnd(from: accepted), request.contains("GET /version") else {
                capture.setError("missing docker request")
                return
            }
            writeAll("HTTP/1.1 200 OK\r\nContent-Length: 11\r\nConnection: close\r\n\r\nhello dory\n", to: accepted)
            shutdown(accepted, SHUT_WR)
        }

        let tier = DockerTier(configuration: DockerTierConfiguration(
            home: base + "/home",
            forwardSocketPath: forwardPath,
            cid: 3,
            dockerPort: 1026,
            gpuSupported: false
        ))
        try tier.start()
        defer { tier.stop() }

        XCTAssertEqual(tier.status().state, .running)

        let client = try connectUnix(path: tier.socketPath)
        defer { close(client) }
        writeAll("GET /version HTTP/1.1\r\nHost: docker\r\nConnection: close\r\n\r\n", to: client)
        shutdown(client, SHUT_WR)

        let response = readAvailableString(from: client)
        XCTAssertTrue(response.contains("hello dory"), response)
        XCTAssertEqual(serverDone.wait(timeout: .now() + 2), .success)
        XCTAssertNil(capture.error)
        XCTAssertEqual(capture.preamble, [1, 3, 0, 0, 0, 2, 4, 0, 0])
    }

    func testCurrentDockerPublishedPortsUsesRunningContainerPortBindings() throws {
        let base = "/tmp/dory-tier-ports-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let forwardPath = base + "/forward.sock"
        let listener = try bindUnixListener(path: forwardPath)
        defer { close(listener) }

        let capture = Capture()
        let serverDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let accepted = accept(listener, nil, nil)
            guard accepted >= 0 else {
                capture.setError("accept failed: \(errno)")
                serverDone.signal()
                return
            }
            defer {
                close(accepted)
                serverDone.signal()
            }

            guard let lengthBytes = readExactly(4, from: accepted) else {
                capture.setError("missing preamble length")
                return
            }
            let length = le32(lengthBytes)
            guard let preamble = readExactly(Int(length), from: accepted) else {
                capture.setError("missing preamble body")
                return
            }
            capture.setPreamble(preamble)

            guard let request = readUntilHeaderEnd(from: accepted) else {
                capture.setError("missing docker request")
                return
            }
            capture.setRequest(request)

            let body = """
            [
              {"Id":"run","Names":["/web"],"State":"running","Ports":[
                {"PrivatePort":80,"PublicPort":25,"Type":"tcp"},
                {"PrivatePort":443,"PublicPort":443,"Type":"tcp6"},
                {"PrivatePort":53,"PublicPort":5353,"Type":"udp6"}
              ],"Labels":{}},
              {"Id":"off","Names":["/off"],"State":"exited","Ports":[
                {"PrivatePort":110,"PublicPort":110,"Type":"tcp"}
              ],"Labels":{}},
              {"Id":"bad","Names":["/bad"],"State":"running","Ports":[
                {"PrivatePort":80,"PublicPort":70000,"Type":"tcp"},
                {"PrivatePort":80,"PublicPort":8080,"Type":"sctp"},
                {"PrivatePort":80,"Type":"tcp"}
              ],"Labels":{}}
            ]
            """
            writeAll("HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)", to: accepted)
            shutdown(accepted, SHUT_WR)
        }

        let tier = DockerTier(configuration: DockerTierConfiguration(
            home: base + "/home",
            forwardSocketPath: forwardPath,
            cid: 3,
            dockerPort: 1026,
            gpuSupported: false
        ))
        try tier.start()
        defer { tier.stop() }

        XCTAssertEqual(tier.currentDockerPublishedPorts(), [
            DoryListenPort(protocol: "tcp", port: 25),
            DoryListenPort(protocol: "tcp", port: 443),
            DoryListenPort(protocol: "udp", port: 5353),
        ])
        XCTAssertEqual(serverDone.wait(timeout: .now() + 2), .success)
        XCTAssertNil(capture.error)
        XCTAssertEqual(capture.preamble, [1, 3, 0, 0, 0, 2, 4, 0, 0])
        XCTAssertTrue(capture.request?.contains("GET /containers/json?all=1") == true)
    }

    func testArmSleepingPublishesSocketWithoutStartingHelperUntilWake() throws {
        let base = "/tmp/dory-tier-armed-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let idle = IdleController(now: Date(timeIntervalSince1970: 0))
        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: base + "/forward.sock",
                activitySocketPath: base + "/activity.sock",
                hvProcess: HvProcessConfiguration(
                    executablePath: "/bin/sleep",
                    arguments: ["30"]
                )
            ),
            idleController: idle,
            dockerReadyWaiter: { _, _, _ in true }
        )

        try tier.armSleeping()
        defer { tier.stop() }

        XCTAssertEqual(tier.status().state, .sleeping)
        XCTAssertNil(tier.status().hvPID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tier.socketPath))
        XCTAssertTrue(idle.snapshot.sleeping)

        try tier.start()
        XCTAssertEqual(tier.status().state, .running)
        XCTAssertNotNil(tier.status().hvPID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tier.socketPath))
        XCTAssertFalse(idle.snapshot.sleeping)
    }

    func testLifecycleObserverTracksSleepAndColdWake() async throws {
        let base = "/tmp/dory-tier-intent-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let states = LockedTierStates()
        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: base + "/forward.sock",
                activitySocketPath: base + "/activity.sock",
                hvProcess: HvProcessConfiguration(executablePath: "/bin/sleep", arguments: ["30"])
            ),
            idleController: IdleController(),
            containerActivityProbe: { _ in .empty },
            dockerReadyWaiter: { _, _, _ in true }
        )
        tier.setLifecycleStateObserver { states.append($0) }
        defer { tier.shutdown() }

        try tier.start()
        XCTAssertTrue(tier.sleepForIdle(idleAfter: 0))
        await tier.ensureAwake()

        XCTAssertTrue(waitUntil(timeout: 1) {
            states.value == [.running, .sleeping, .running]
        })
        XCTAssertEqual(tier.status().state, .running)
    }

    func testTerminalDaemonShutdownDoesNotReplaceRunningIntentWithStopped() throws {
        let base = "/tmp/dory-tier-shutdown-intent-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let states = LockedTierStates()
        let tier = DockerTier(configuration: DockerTierConfiguration(
            home: base + "/home",
            forwardSocketPath: base + "/forward.sock"
        ))
        tier.setLifecycleStateObserver { states.append($0) }

        try tier.start()
        tier.shutdown()

        XCTAssertTrue(waitUntil(timeout: 1) { states.value == [.running] })
        XCTAssertEqual(tier.status().state, .stopped)
    }

    func testStartFromSleepingThrowsWhenWakeDoesNotReachDocker() throws {
        let base = "/tmp/dory-tier-wake-fails-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let idle = IdleController(now: Date(timeIntervalSince1970: 0))
        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: base + "/forward.sock",
                activitySocketPath: base + "/activity.sock",
                hvProcess: HvProcessConfiguration(
                    executablePath: "/bin/sleep",
                    arguments: ["30"]
                )
            ),
            idleController: idle,
            dockerReadyWaiter: { _, _, _ in false }
        )

        try tier.armSleeping()
        defer { tier.stop() }

        XCTAssertThrowsError(try tier.start()) { error in
            XCTAssertTrue("\(error)".contains("did not become ready"), "\(error)")
        }
        XCTAssertEqual(tier.status().state, .sleeping)
        XCTAssertEqual(tier.status().lastError, "docker tier did not become ready after wake")
        XCTAssertNil(tier.status().hvPID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tier.socketPath), "failed wake keeps the sleeping dataplane armed")
        XCTAssertTrue(idle.snapshot.sleeping)
    }

    func testSleepingFreshWakeDoesNotBlockStatusWhileWaitingForDocker() throws {
        let base = "/tmp/dory-tier-wake-status-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let readyWaitEntered = DispatchSemaphore(value: 0)
        let finishReadyWait = DispatchSemaphore(value: 0)
        let startFinished = DispatchSemaphore(value: 0)
        let idle = IdleController(now: Date(timeIntervalSince1970: 0))
        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: base + "/forward.sock",
                activitySocketPath: base + "/activity.sock",
                hvProcess: HvProcessConfiguration(
                    executablePath: "/bin/sleep",
                    arguments: ["30"]
                )
            ),
            idleController: idle,
            dockerReadyWaiter: { _, _, _ in
                readyWaitEntered.signal()
                return finishReadyWait.wait(timeout: .now() + 2) == .success
            }
        )

        try tier.armSleeping()
        defer { tier.stop() }

        let startError = LockedErrorBox()
        DispatchQueue.global().async {
            do {
                try tier.start()
            } catch {
                startError.set(error)
            }
            startFinished.signal()
        }

        XCTAssertEqual(readyWaitEntered.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(tier.status().state, .starting)

        finishReadyWait.signal()
        XCTAssertEqual(startFinished.wait(timeout: .now() + 2), .success)
        XCTAssertNil(startError.value)
        XCTAssertEqual(tier.status().state, .running)
    }

    func testManagedFreshStartThrowsWhenDockerNeverBecomesReady() throws {
        let base = "/tmp/dory-tier-start-fails-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let idle = IdleController(now: Date(timeIntervalSince1970: 0))
        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: base + "/forward.sock",
                activitySocketPath: base + "/activity.sock",
                hvProcess: HvProcessConfiguration(
                    executablePath: "/bin/sleep",
                    arguments: ["30"]
                )
            ),
            idleController: idle,
            dockerReadyWaiter: { _, _, _ in false }
        )
        defer { tier.stop() }

        XCTAssertThrowsError(try tier.start()) { error in
            XCTAssertTrue("\(error)".contains("did not become ready"), "\(error)")
        }
        XCTAssertEqual(tier.status().state, .failed)
        XCTAssertEqual(tier.status().lastError, "docker tier did not become ready after wake")
        XCTAssertNil(tier.status().hvPID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tier.socketPath))
    }

    func testStopCancelsBlockedFreshStartAndReapsInFlightHelper() throws {
        let base = "/tmp/dory-tier-start-cancel-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let readyWaitEntered = DispatchSemaphore(value: 0)
        let startFinished = DispatchSemaphore(value: 0)
        let startError = LockedErrorBox()
        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: base + "/forward.sock",
                activitySocketPath: base + "/activity.sock",
                hvProcess: HvProcessConfiguration(
                    executablePath: "/bin/sleep",
                    arguments: ["30"]
                )
            ),
            idleController: IdleController(),
            dockerReadyWaiter: { _, timeout, shouldContinue in
                readyWaitEntered.signal()
                let deadline = Date().addingTimeInterval(min(timeout, 2))
                while Date() < deadline, shouldContinue() {
                    Thread.sleep(forTimeInterval: 0.005)
                }
                return false
            }
        )

        DispatchQueue.global().async {
            do {
                try tier.start()
            } catch {
                startError.set(error)
            }
            startFinished.signal()
        }

        XCTAssertEqual(readyWaitEntered.wait(timeout: .now() + 2), .success)
        let helperPID = try XCTUnwrap(tier.status().hvPID)

        let stoppedAt = Date()
        tier.stop()

        XCTAssertEqual(startFinished.wait(timeout: .now() + 1), .success)
        XCTAssertLessThan(Date().timeIntervalSince(stoppedAt), 1)
        XCTAssertTrue(startError.value.map { "\($0)".contains("start was cancelled") } ?? false)
        XCTAssertEqual(tier.status().state, .stopped)
        XCTAssertNil(tier.status().hvPID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tier.socketPath))
        XCTAssertEqual(kill(helperPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testLateCancelledStartReadinessCannotOverwriteStoppedCycle() throws {
        let base = "/tmp/dory-tier-readiness-cycle-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let readyWaitEntered = DispatchSemaphore(value: 0)
        let releaseReadyWait = DispatchSemaphore(value: 0)
        let startFinished = DispatchSemaphore(value: 0)
        let startError = LockedErrorBox()
        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: base + "/forward.sock",
                activitySocketPath: base + "/activity.sock",
                hvProcess: HvProcessConfiguration(
                    executablePath: "/bin/sleep",
                    arguments: ["30"]
                )
            ),
            idleController: IdleController(),
            dockerReadyWaiter: { _, _, _ in
                readyWaitEntered.signal()
                _ = releaseReadyWait.wait(timeout: .now() + 5)
                return true
            }
        )
        defer {
            releaseReadyWait.signal()
            _ = tier.stop()
        }

        DispatchQueue.global().async {
            do {
                try tier.start()
            } catch {
                startError.set(error)
            }
            startFinished.signal()
        }

        XCTAssertEqual(readyWaitEntered.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(tier.stop())
        let stopped = tier.readinessSnapshot()
        XCTAssertEqual(stopped.trigger, "stopped")
        XCTAssertTrue(stopped.stages.allSatisfy {
            $0.state == .inactive && $0.reasonCode == "engine.stopped"
        })

        releaseReadyWait.signal()
        XCTAssertEqual(startFinished.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(startError.value.map { "\($0)".contains("start was cancelled") } ?? false)

        let afterLateCompletion = tier.readinessSnapshot()
        XCTAssertEqual(afterLateCompletion.cycleID, stopped.cycleID)
        XCTAssertEqual(afterLateCompletion.trigger, "stopped")
        XCTAssertTrue(afterLateCompletion.stages.allSatisfy {
            $0.state == .inactive && $0.reasonCode == "engine.stopped"
        })
    }

    func testOrdinaryStopAllowsRestartButDaemonShutdownPermanentlyRejectsStart() throws {
        let base = "/tmp/dory-tier-terminal-latch-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: base + "/forward.sock",
                activitySocketPath: base + "/activity.sock",
                hvProcess: HvProcessConfiguration(
                    executablePath: "/bin/sleep",
                    arguments: ["30"]
                )
            ),
            idleController: IdleController(),
            dockerReadyWaiter: { _, _, _ in true }
        )

        try tier.start()
        let firstPID = try XCTUnwrap(tier.status().hvPID)
        tier.stop()
        XCTAssertEqual(kill(firstPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)

        try tier.start()
        let secondPID = try XCTUnwrap(tier.status().hvPID)
        tier.shutdown()
        XCTAssertEqual(kill(secondPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        XCTAssertEqual(tier.status().state, .stopped)

        XCTAssertThrowsError(try tier.start()) { error in
            XCTAssertTrue("\(error)".contains("doryd is shutting down"), "\(error)")
        }
        XCTAssertThrowsError(try tier.armSleeping()) { error in
            XCTAssertTrue("\(error)".contains("doryd is shutting down"), "\(error)")
        }
        XCTAssertNil(tier.status().hvPID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tier.socketPath))
    }

    func testConcurrentRestartIsRejectedPromptlyUntilOrdinaryStopCommits() throws {
        let base = "/tmp/dory-tier-stop-start-barrier-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let readyMarker = base + "/ready"
        let stopMarker = base + "/stopping"
        let helperProgram = """
        import os, signal, time
        def stop(_signal, _frame):
            open(os.environ["DORY_STOP_MARKER"], "w").close()
            time.sleep(0.5)
            raise SystemExit(0)
        signal.signal(signal.SIGTERM, stop)
        open(os.environ["DORY_READY_MARKER"], "w").close()
        while True:
            time.sleep(0.02)
        """

        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: base + "/forward.sock",
                hvProcess: HvProcessConfiguration(
                    executablePath: "/usr/bin/python3",
                    arguments: ["-c", helperProgram],
                    environment: [
                        "DORY_READY_MARKER": readyMarker,
                        "DORY_STOP_MARKER": stopMarker,
                    ]
                )
            ),
            dockerReadyWaiter: { _, _, shouldContinue in
                waitUntil(timeout: 10) {
                    shouldContinue() && FileManager.default.fileExists(atPath: readyMarker)
                }
            }
        )
        defer { tier.stop() }

        try tier.start()
        let originalPID = try XCTUnwrap(tier.status().hvPID)
        let stopFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            tier.stop()
            stopFinished.signal()
        }
        XCTAssertTrue(waitUntil(timeout: 2) {
            FileManager.default.fileExists(atPath: stopMarker)
        })

        let rejectedAt = Date()
        XCTAssertThrowsError(try tier.start()) { error in
            XCTAssertEqual("\(error)", DockerTier.TierError.helperTerminationPending.description)
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(rejectedAt),
            0.15,
            "a replacement lifecycle must fail promptly instead of waiting behind external cleanup"
        )
        XCTAssertTrue(tier.status().isStopping)
        XCTAssertEqual(stopFinished.wait(timeout: .now() + 10), .success)

        try tier.start()
        XCTAssertEqual(tier.status().state, .running)
        XCTAssertNotEqual(tier.status().hvPID, originalPID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tier.socketPath))
    }

    func testBlockedHelperCleanupLeavesStatusResponsiveAndStartExcluded() throws {
        let base = "/tmp/dory-tier-responsive-stop-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let helper = BlockingStopDockerProcess(pid: 43_001)
        let tier = makeTier(base: base, helper: helper)
        try tier.start()

        let stopResult = LockedBoolBox()
        let stopFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            stopResult.set(tier.stop())
            stopFinished.signal()
        }
        XCTAssertEqual(helper.stopEntered.wait(timeout: .now() + 1), .success)

        let statusStartedAt = Date()
        let stoppingStatus = tier.status()
        XCTAssertLessThan(Date().timeIntervalSince(statusStartedAt), 0.1)
        XCTAssertTrue(stoppingStatus.isStopping)
        XCTAssertEqual(stoppingStatus.state, .failed)
        XCTAssertEqual(stoppingStatus.hvPID, 43_001)

        let startStartedAt = Date()
        XCTAssertThrowsError(try tier.start()) { error in
            XCTAssertEqual("\(error)", DockerTier.TierError.helperTerminationPending.description)
        }
        XCTAssertLessThan(Date().timeIntervalSince(startStartedAt), 0.1)

        let wakeFinished = DispatchSemaphore(value: 0)
        Task {
            await tier.ensureAwake()
            wakeFinished.signal()
        }
        XCTAssertEqual(wakeFinished.wait(timeout: .now() + 0.1), .success)
        XCTAssertEqual(helper.startCallCount, 1, "wake must not launch during teardown")

        helper.releaseStop.signal()
        XCTAssertEqual(stopFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(stopResult.value, true)
        XCTAssertFalse(tier.status().isStopping)
        XCTAssertEqual(tier.status().state, .stopped)
    }

    func testStatusBudgetIsBoundedWhileManagedHelperLaunchOwnsLifecycleReservation() throws {
        let base = "/tmp/dory-tier-blocked-launch-status-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let launchPublished = DispatchSemaphore(value: 0)
        let releaseLaunch = DispatchSemaphore(value: 0)
        let startFinished = DispatchSemaphore(value: 0)
        let startError = LockedErrorBox()
        let helper = HvProcess(configuration: HvProcessConfiguration(
            executablePath: "/bin/sleep",
            arguments: ["30"]
        ))
        helper.installPostPublicationLifecycleGateForTesting { _ in
            launchPublished.signal()
            releaseLaunch.wait()
        }
        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: base + "/forward.sock",
                hvProcess: HvProcessConfiguration(
                    executablePath: "/bin/false",
                    arguments: []
                )
            ),
            dockerReadyWaiter: { _, _, _ in true }
        )
        tier.installManagedProcessFactory { _, _ in helper }
        defer {
            releaseLaunch.signal()
            _ = tier.stop()
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try tier.start()
            } catch {
                startError.set(error)
            }
            startFinished.signal()
        }
        XCTAssertEqual(launchPublished.wait(timeout: .now() + 1), .success)

        let statusStartedAt = ProcessInfo.processInfo.systemUptime
        let status = tier.status()
        let elapsed = ProcessInfo.processInfo.systemUptime - statusStartedAt
        XCTAssertLessThan(elapsed, 0.1)
        XCTAssertEqual(status.state, .starting)
        XCTAssertNil(status.hvPID, "contended exact observation must fail closed, never guess a PID")

        releaseLaunch.signal()
        XCTAssertEqual(startFinished.wait(timeout: .now() + 2), .success)
        XCTAssertNil(startError.value)
        XCTAssertEqual(tier.status().state, .running)
    }

    func testConcurrentStopsJoinOneCleanupAndOneLifecycleCommit() throws {
        let base = "/tmp/dory-tier-joined-stop-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let helper = BlockingStopDockerProcess(pid: 43_002)
        let tier = makeTier(base: base, helper: helper)
        let states = LockedTierStates()
        tier.setLifecycleStateObserver { states.append($0) }
        try tier.start()
        XCTAssertTrue(waitUntil(timeout: 1) { states.value == [.running] })

        let firstResult = LockedBoolBox()
        let secondResult = LockedBoolBox()
        let firstFinished = DispatchSemaphore(value: 0)
        let secondFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            firstResult.set(tier.stop())
            firstFinished.signal()
        }
        XCTAssertEqual(helper.stopEntered.wait(timeout: .now() + 1), .success)
        DispatchQueue.global().async {
            secondResult.set(tier.stop())
            secondFinished.signal()
        }

        XCTAssertEqual(secondFinished.wait(timeout: .now() + 0.1), .timedOut)
        XCTAssertEqual(helper.stopCallCount, 1)
        helper.releaseStop.signal()
        XCTAssertEqual(firstFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(secondFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(firstResult.value, true)
        XCTAssertEqual(secondResult.value, true)
        XCTAssertEqual(helper.stopCallCount, 1)
        XCTAssertTrue(waitUntil(timeout: 1) { states.value == [.running, .stopped] })
    }

    func testFalseStopResultDoesNotRetainHelperAfterExactTerminalObservation() throws {
        let base = "/tmp/dory-tier-stale-false-stop-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let helper = StaleFalseStopDockerProcess(pid: 43_003)
        let tier = makeTier(base: base, helper: helper)
        try tier.start()

        XCTAssertTrue(tier.stop(), "a stale false stop result must be revalidated")
        XCTAssertEqual(helper.stopCallCount, 1)
        XCTAssertEqual(tier.status().state, .stopped)
        XCTAssertNil(tier.status().hvPID)
        XCTAssertNoThrow(try tier.start(), "terminal old authority must not block replacement")
        XCTAssertTrue(tier.stop())
    }

    func testLifecycleObserverCanReenterAndStillReceivesCommitOrder() throws {
        let base = "/tmp/dory-tier-observer-reentry-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let tier = DockerTier(configuration: DockerTierConfiguration(
            home: base + "/home",
            forwardSocketPath: base + "/forward.sock"
        ))
        let states = LockedTierStates()
        let callbackFinished = DispatchSemaphore(value: 0)
        tier.setLifecycleStateObserver { [weak tier] state in
            _ = tier?.status()
            states.append(state)
            callbackFinished.signal()
        }

        try tier.start()
        XCTAssertEqual(callbackFinished.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(tier.stop())
        XCTAssertEqual(callbackFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(states.value, [.running, .stopped])
    }

    func testDaemonShutdownCancelsAcceptedStartAndLatchesAgainstRetry() throws {
        let base = "/tmp/dory-tier-terminal-start-race-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let readyWaitEntered = DispatchSemaphore(value: 0)
        let startFinished = DispatchSemaphore(value: 0)
        let startError = LockedErrorBox()
        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: base + "/forward.sock",
                activitySocketPath: base + "/activity.sock",
                hvProcess: HvProcessConfiguration(
                    executablePath: "/bin/sleep",
                    arguments: ["30"]
                )
            ),
            idleController: IdleController(),
            dockerReadyWaiter: { _, timeout, shouldContinue in
                readyWaitEntered.signal()
                let deadline = Date().addingTimeInterval(min(timeout, 2))
                while Date() < deadline, shouldContinue() {
                    Thread.sleep(forTimeInterval: 0.005)
                }
                return false
            }
        )

        DispatchQueue.global().async {
            do {
                try tier.start()
            } catch {
                startError.set(error)
            }
            startFinished.signal()
        }

        XCTAssertEqual(readyWaitEntered.wait(timeout: .now() + 2), .success)
        let helperPID = try XCTUnwrap(tier.status().hvPID)
        tier.shutdown()

        XCTAssertEqual(startFinished.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(startError.value.map { "\($0)".contains("start was cancelled") } ?? false)
        XCTAssertEqual(kill(helperPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        XCTAssertThrowsError(try tier.start()) { error in
            XCTAssertTrue("\(error)".contains("doryd is shutting down"), "\(error)")
        }
        XCTAssertEqual(tier.status().state, .stopped)
        XCTAssertNil(tier.status().hvPID)
    }

    func testTerminalShutdownRemovesDataplaneBoundAfterTearDown() throws {
        let base = "/tmp/dory-tier-terminal-dataplane-race-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let dataplaneStartEntered = DispatchSemaphore(value: 0)
        let releaseDataplaneStart = DispatchSemaphore(value: 0)
        let startFinished = DispatchSemaphore(value: 0)
        let startError = LockedErrorBox()
        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: base + "/forward.sock"
            ),
            beforeDataplaneStart: {
                dataplaneStartEntered.signal()
                _ = releaseDataplaneStart.wait(timeout: .now() + 2)
            }
        )

        DispatchQueue.global().async {
            do {
                try tier.start()
            } catch {
                startError.set(error)
            }
            startFinished.signal()
        }

        XCTAssertEqual(dataplaneStartEntered.wait(timeout: .now() + 2), .success)
        tier.shutdown()
        releaseDataplaneStart.signal()

        XCTAssertEqual(startFinished.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(startError.value.map { "\($0)".contains("start was cancelled") } ?? false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tier.socketPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: base + "/forward.sock"))
        XCTAssertEqual(tier.status().state, .stopped)
    }

    func testTerminalShutdownRemovesSleepingDataplaneBoundAfterTearDown() throws {
        let base = "/tmp/dory-tier-terminal-arm-race-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let activityPath = base + "/activity.sock"
        let dataplaneStartEntered = DispatchSemaphore(value: 0)
        let releaseDataplaneStart = DispatchSemaphore(value: 0)
        let armFinished = DispatchSemaphore(value: 0)
        let armError = LockedErrorBox()
        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: base + "/forward.sock",
                activitySocketPath: activityPath,
                hvProcess: HvProcessConfiguration(
                    executablePath: "/bin/sleep",
                    arguments: ["30"]
                )
            ),
            idleController: IdleController(),
            beforeDataplaneStart: {
                dataplaneStartEntered.signal()
                _ = releaseDataplaneStart.wait(timeout: .now() + 2)
            }
        )

        DispatchQueue.global().async {
            do {
                try tier.armSleeping()
            } catch {
                armError.set(error)
            }
            armFinished.signal()
        }

        XCTAssertEqual(dataplaneStartEntered.wait(timeout: .now() + 2), .success)
        tier.shutdown()
        releaseDataplaneStart.signal()

        XCTAssertEqual(armFinished.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(armError.value.map { "\($0)".contains("start was cancelled") } ?? false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tier.socketPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: activityPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: base + "/forward.sock"))
        XCTAssertEqual(tier.status().state, .stopped)
    }

    func testCancelledSleepingDataplaneLaunchRetiresItsSocketsBeforeReplacementCanBind() throws {
        let base = "/tmp/dory-tier-arm-cleanup-authority-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let firstDataplaneStartEntered = DispatchSemaphore(value: 0)
        let releaseFirstDataplaneStart = DispatchSemaphore(value: 0)
        let armFinished = DispatchSemaphore(value: 0)
        let armError = LockedErrorBox()
        let dataplaneStarts = LockedInt()
        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: base + "/forward.sock",
                activitySocketPath: base + "/activity.sock",
                hvProcess: HvProcessConfiguration(executablePath: "/bin/sleep", arguments: ["30"])
            ),
            idleController: IdleController(),
            dockerReadyWaiter: { _, _, _ in true },
            beforeDataplaneStart: {
                if dataplaneStarts.increment() == 1 {
                    firstDataplaneStartEntered.signal()
                    _ = releaseFirstDataplaneStart.wait(timeout: .now() + 2)
                }
            }
        )

        DispatchQueue.global().async {
            do {
                try tier.armSleeping()
            } catch {
                armError.set(error)
            }
            armFinished.signal()
        }

        XCTAssertEqual(firstDataplaneStartEntered.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(tier.stop())
        XCTAssertThrowsError(try tier.start()) { error in
            XCTAssertEqual("\(error)", DockerTier.TierError.helperTerminationPending.description)
        }

        releaseFirstDataplaneStart.signal()
        XCTAssertEqual(armFinished.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(armError.value.map { "\($0)".contains("start was cancelled") } ?? false)

        try tier.start()
        XCTAssertEqual(tier.status().state, .running)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tier.socketPath))
        XCTAssertEqual(dataplaneStarts.value, 2)
        XCTAssertTrue(tier.stop())
    }

    func testStopSupersedesSocketRepairWithoutLockingOrLateEndpointCleanup() throws {
        let base = "/tmp/dory-tier-repair-stop-race-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let repairDataplaneStartEntered = DispatchSemaphore(value: 0)
        let releaseRepairDataplaneStart = DispatchSemaphore(value: 0)
        let repairFinished = DispatchSemaphore(value: 0)
        let repairError = LockedErrorBox()
        let dataplaneStarts = LockedInt()
        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: base + "/forward.sock",
                activitySocketPath: base + "/activity.sock",
                hvProcess: HvProcessConfiguration(executablePath: "/bin/sleep", arguments: ["30"])
            ),
            idleController: IdleController(),
            dockerReadyWaiter: { _, _, _ in true },
            beforeDataplaneStart: {
                if dataplaneStarts.increment() == 2 {
                    repairDataplaneStartEntered.signal()
                    _ = releaseRepairDataplaneStart.wait(timeout: .now() + 3)
                }
            }
        )
        try tier.start()

        unlink(tier.socketPath)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try tier.repairSocketForwarder()
            } catch {
                repairError.set(error)
            }
            repairFinished.signal()
        }

        XCTAssertEqual(repairDataplaneStartEntered.wait(timeout: .now() + 3), .success)
        XCTAssertTrue(tier.stop(), "stop must not wait for the repair's external dataplane start")
        XCTAssertThrowsError(try tier.start()) { error in
            XCTAssertEqual("\(error)", DockerTier.TierError.helperTerminationPending.description)
        }

        releaseRepairDataplaneStart.signal()
        XCTAssertEqual(repairFinished.wait(timeout: .now() + 3), .success)
        XCTAssertTrue(
            repairError.value.map { "\($0)".contains("superseded") } ?? false,
            "\(String(describing: repairError.value))"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: tier.socketPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: base + "/activity.sock"))

        try tier.start()
        XCTAssertEqual(tier.status().state, .running)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tier.socketPath))
        XCTAssertEqual(dataplaneStarts.value, 3)
        XCTAssertTrue(tier.stop())
    }

    func testDaemonShutdownCancelsAcceptedWakeAndPreventsFutureWake() async throws {
        let base = "/tmp/dory-tier-terminal-wake-race-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let readyWaitEntered = DispatchSemaphore(value: 0)
        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: base + "/forward.sock",
                activitySocketPath: base + "/activity.sock",
                hvProcess: HvProcessConfiguration(
                    executablePath: "/bin/sleep",
                    arguments: ["30"]
                )
            ),
            idleController: IdleController(),
            dockerReadyWaiter: { _, timeout, shouldContinue in
                readyWaitEntered.signal()
                let deadline = Date().addingTimeInterval(min(timeout, 2))
                while Date() < deadline, shouldContinue() {
                    Thread.sleep(forTimeInterval: 0.005)
                }
                return false
            }
        )

        try tier.armSleeping()
        let wake = Task { await tier.ensureAwake() }
        XCTAssertEqual(readyWaitEntered.wait(timeout: .now() + 2), .success)
        let helperPID = try XCTUnwrap(tier.status().hvPID)

        tier.shutdown()
        await wake.value
        await tier.ensureAwake()

        XCTAssertEqual(kill(helperPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        XCTAssertEqual(tier.status().state, .stopped)
        XCTAssertNil(tier.status().hvPID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tier.socketPath))
    }

    func testClientArrivingDuringColdWakeWaitsForSamePromotion() async throws {
        let base = "/tmp/dory-tier-late-wake-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let readyWaitEntered = DispatchSemaphore(value: 0)
        let releaseReadyWait = DispatchSemaphore(value: 0)
        let lateWakeFinished = DispatchSemaphore(value: 0)
        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: base + "/forward.sock",
                activitySocketPath: base + "/activity.sock",
                hvProcess: HvProcessConfiguration(
                    executablePath: "/bin/sleep",
                    arguments: ["30"]
                )
            ),
            idleController: IdleController(),
            dockerReadyWaiter: { _, _, shouldContinue in
                readyWaitEntered.signal()
                _ = releaseReadyWait.wait(timeout: .now() + 2)
                return shouldContinue()
            }
        )
        try tier.armSleeping()
        defer { tier.stop() }

        let firstWake = Task { await tier.ensureAwake() }
        XCTAssertEqual(readyWaitEntered.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(tier.status().state, .starting)

        let lateWake = Task {
            await tier.ensureAwake()
            lateWakeFinished.signal()
        }
        XCTAssertEqual(lateWakeFinished.wait(timeout: .now() + 0.1), .timedOut)

        releaseReadyWait.signal()
        await firstWake.value
        await lateWake.value
        XCTAssertEqual(tier.status().state, .running)
    }

    func testClientArrivingDuringExplicitStartWaitsForSamePromotion() async throws {
        let base = "/tmp/dory-tier-late-start-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let readyWaitEntered = DispatchSemaphore(value: 0)
        let releaseReadyWait = DispatchSemaphore(value: 0)
        let startFinished = DispatchSemaphore(value: 0)
        let requestFinished = DispatchSemaphore(value: 0)
        let startError = Capture()
        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: base + "/forward.sock",
                activitySocketPath: base + "/activity.sock",
                hvProcess: HvProcessConfiguration(
                    executablePath: "/bin/sleep",
                    arguments: ["30"]
                )
            ),
            idleController: IdleController(),
            dockerReadyWaiter: { _, _, shouldContinue in
                readyWaitEntered.signal()
                _ = releaseReadyWait.wait(timeout: .now() + 2)
                return shouldContinue()
            }
        )
        try tier.armSleeping()
        defer { tier.stop() }

        DispatchQueue.global().async {
            do {
                try tier.start()
            } catch {
                startError.setError("\(error)")
            }
            startFinished.signal()
        }
        XCTAssertEqual(readyWaitEntered.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(tier.status().state, .starting)

        let request = Task {
            await tier.ensureAwake()
            requestFinished.signal()
        }
        XCTAssertEqual(requestFinished.wait(timeout: .now() + 0.1), .timedOut)

        releaseReadyWait.signal()
        XCTAssertEqual(startFinished.wait(timeout: .now() + 2), .success)
        await request.value
        XCTAssertNil(startError.error)
        XCTAssertEqual(tier.status().state, .running)
    }

    func testPromotionRestartsExplicitlyStoppedTier() throws {
        let base = "/tmp/dory-tier-promote-stopped-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: base + "/forward.sock",
                activitySocketPath: base + "/activity.sock",
                hvProcess: HvProcessConfiguration(
                    executablePath: "/bin/sleep",
                    arguments: ["30"]
                )
            ),
            idleController: IdleController(),
            dockerReadyWaiter: { _, _, _ in true }
        )
        defer { tier.stop() }

        try tier.start()
        tier.stop()
        XCTAssertEqual(tier.status().state, .stopped)

        try tier.promoteToRunning(timeout: 2)
        XCTAssertEqual(tier.status().state, .running)
        XCTAssertNotNil(tier.status().hvPID)
    }

    func testIdleSleepSuspendsHelperAndWakeResumesSameProcess() async throws {
        let base = "/tmp/dory-tier-sleep-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let idle = IdleController(now: Date(timeIntervalSince1970: 0))
        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: base + "/forward.sock",
                activitySocketPath: base + "/activity.sock",
                hvProcess: HvProcessConfiguration(
                    executablePath: "/bin/sleep",
                    arguments: ["30"]
                )
            ),
            idleController: idle,
            containerActivityProbe: { _ in .active(1) },
            dockerReadyWaiter: { _, _, _ in true }
        )

        try tier.start()
        defer { tier.stop() }
        XCTAssertEqual(tier.status().state, .running)
        let originalPID = try XCTUnwrap(tier.status().hvPID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tier.socketPath))

        XCTAssertTrue(tier.sleepForIdle(idleAfter: 1, now: Date().addingTimeInterval(10)))
        XCTAssertEqual(tier.status().state, .sleeping)
        XCTAssertEqual(tier.status().hvPID, originalPID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tier.socketPath), "dataplane listener stays up for wake")

        await tier.ensureAwake()
        XCTAssertEqual(tier.status().state, .running)
        XCTAssertEqual(tier.status().hvPID, originalPID)
        XCTAssertFalse(idle.snapshot.sleeping)
    }

    func testIdleSleepStopsEmptyHelperAndWakeStartsFreshProcess() async throws {
        let base = "/tmp/dory-tier-empty-sleep-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let idle = IdleController(now: Date(timeIntervalSince1970: 0))
        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: base + "/forward.sock",
                activitySocketPath: base + "/activity.sock",
                hvProcess: HvProcessConfiguration(
                    executablePath: "/bin/sleep",
                    arguments: ["30"]
                )
            ),
            idleController: idle,
            containerActivityProbe: { _ in .empty },
            dockerReadyWaiter: { _, _, _ in true }
        )

        try tier.start()
        defer { tier.stop() }
        let originalPID = try XCTUnwrap(tier.status().hvPID)

        XCTAssertTrue(tier.sleepForIdle(idleAfter: 1, now: Date().addingTimeInterval(10)))
        XCTAssertEqual(tier.status().state, .sleeping)
        XCTAssertNil(tier.status().hvPID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tier.socketPath), "dataplane listener stays up for wake")

        await tier.ensureAwake()
        let freshPID = try XCTUnwrap(tier.status().hvPID)
        XCTAssertEqual(tier.status().state, .running)
        XCTAssertNotEqual(freshPID, originalPID)
        XCTAssertFalse(idle.snapshot.sleeping)
    }

    func testIdleSleepStopsEmptyHelperEvenWithStaleRequestCount() throws {
        let base = "/tmp/dory-tier-stale-empty-sleep-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let idle = IdleController(now: Date(timeIntervalSince1970: 0))
        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: base + "/forward.sock",
                activitySocketPath: base + "/activity.sock",
                hvProcess: HvProcessConfiguration(
                    executablePath: "/bin/sleep",
                    arguments: ["30"]
                )
            ),
            idleController: idle,
            containerActivityProbe: { _ in .empty },
            dockerReadyWaiter: { _, _, _ in true }
        )

        try tier.start()
        defer { tier.stop() }
        _ = idle.beginRequest(path: "/events", now: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(idle.snapshot.activeRequests, 1)

        XCTAssertTrue(tier.sleepForIdle(idleAfter: 1, now: Date(timeIntervalSince1970: 10)))
        XCTAssertEqual(tier.status().state, .sleeping)
        XCTAssertNil(tier.status().hvPID)
    }

    func testHostSleepStopsEmptyHelper() throws {
        let base = "/tmp/dory-tier-host-sleep-empty-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let idle = IdleController(now: Date(timeIntervalSince1970: 0))
        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: base + "/forward.sock",
                activitySocketPath: base + "/activity.sock",
                hvProcess: HvProcessConfiguration(
                    executablePath: "/bin/sleep",
                    arguments: ["30"]
                )
            ),
            idleController: idle,
            containerActivityProbe: { _ in .empty },
            dockerReadyWaiter: { _, _, _ in true }
        )

        try tier.start()
        defer { tier.stop() }
        XCTAssertNotNil(tier.status().hvPID)

        let result = tier.prepareForHostSleep(now: idle.snapshot.lastActivity.addingTimeInterval(1))

        XCTAssertTrue(result.attempted)
        XCTAssertTrue(result.slept)
        XCTAssertEqual(tier.status().state, .sleeping)
        XCTAssertNil(tier.status().hvPID)
    }

    func testHostSleepLeavesActiveContainersRunning() throws {
        let base = "/tmp/dory-tier-host-sleep-active-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let idle = IdleController(now: Date(timeIntervalSince1970: 0))
        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: base + "/forward.sock",
                activitySocketPath: base + "/activity.sock",
                hvProcess: HvProcessConfiguration(
                    executablePath: "/bin/sleep",
                    arguments: ["30"]
                )
            ),
            idleController: idle,
            containerActivityProbe: { _ in .active(2) },
            dockerReadyWaiter: { _, _, _ in true }
        )

        try tier.start()
        defer { tier.stop() }
        let originalPID = try XCTUnwrap(tier.status().hvPID)

        let result = tier.prepareForHostSleep(now: idle.snapshot.lastActivity.addingTimeInterval(1))

        XCTAssertFalse(result.attempted)
        XCTAssertFalse(result.slept)
        XCTAssertEqual(tier.status().state, .running)
        XCTAssertEqual(tier.status().hvPID, originalPID)
        XCTAssertFalse(idle.snapshot.sleeping)
    }

    func testUnexpectedHelperExitClearsStaleEndpointsAndRestartsAfterBackoff() throws {
        let base = "/tmp/dory-tier-supervisor-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let forwardPath = base + "/forward.sock"
        let activityPath = base + "/activity.sock"
        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: forwardPath,
                activitySocketPath: activityPath,
                hvProcess: HvProcessConfiguration(
                    executablePath: "/bin/sleep",
                    arguments: ["30"],
                    restartPolicy: HvRestartPolicy(
                        maxRestarts: 2,
                        delaySeconds: 0.25,
                        maximumDelaySeconds: 0.25,
                        stableRunSeconds: 60
                    )
                )
            ),
            idleController: IdleController(),
            dockerReadyWaiter: { _, _, _ in true }
        )
        try tier.start()
        defer { tier.stop() }

        let originalPID = try XCTUnwrap(tier.status().hvPID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tier.socketPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: activityPath))
        XCTAssertTrue(FileManager.default.createFile(atPath: forwardPath, contents: Data("stale".utf8)))

        let killedAt = Date()
        XCTAssertEqual(kill(originalPID, SIGKILL), 0)
        XCTAssertTrue(waitUntil(timeout: 1) {
            let status = tier.status()
            return status.state == .starting && status.hvPID == nil
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: tier.socketPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: activityPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: forwardPath))

        XCTAssertTrue(waitUntil(timeout: 2) {
            let status = tier.status()
            return status.state == .running && status.hvPID != nil && status.hvPID != originalPID
        })
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(killedAt), 0.20)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tier.socketPath))
    }

    func testRetainedUnexpectedHelperTerminalObservationContinuesRecoveryWithoutControlRequest() throws {
        let base = "/tmp/dory-tier-retained-recovery-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let retained = UnconfirmedStopDockerProcess(pid: 42_500)
        let replacement = ReadyDockerManagedProcess(pid: 42_501)
        let factoryCalls = LockedInt()
        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: base + "/forward.sock",
                activitySocketPath: base + "/activity.sock",
                hvProcess: HvProcessConfiguration(
                    executablePath: "/bin/false",
                    restartPolicy: HvRestartPolicy(
                        maxRestarts: 1,
                        delaySeconds: 0,
                        maximumDelaySeconds: 0
                    )
                )
            ),
            idleController: IdleController(),
            dockerReadyWaiter: { _, _, _ in true }
        )
        tier.installManagedProcessFactory { _, terminationHandler in
            if factoryCalls.increment() == 1 {
                retained.setUnexpectedTerminationHandler(terminationHandler)
                return retained
            }
            return replacement
        }
        defer { _ = tier.stop() }

        try tier.start()
        retained.reportUnexpectedTermination()
        XCTAssertEqual(retained.terminationWaitEntered.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(tier.status().state, .failed)
        XCTAssertEqual(tier.status().hvPID, 42_500)

        retained.confirmExit()
        XCTAssertEqual(
            replacement.startEntered.wait(timeout: .now() + 1),
            .success,
            "terminal observation must schedule the retained recovery without start/status/stop"
        )
        XCTAssertTrue(waitUntil(timeout: 1) {
            let status = tier.status()
            return status.state == .running && status.hvPID == 42_501
        })
        XCTAssertEqual(factoryCalls.value, 2)
    }

    func testExplicitStopNeverTriggersSupervisorRestart() throws {
        let base = "/tmp/dory-tier-explicit-stop-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: base + "/forward.sock",
                activitySocketPath: base + "/activity.sock",
                hvProcess: HvProcessConfiguration(
                    executablePath: "/bin/sleep",
                    arguments: ["30"],
                    restartPolicy: HvRestartPolicy(maxRestarts: 3, delaySeconds: 0.02)
                )
            ),
            idleController: IdleController(),
            dockerReadyWaiter: { _, _, _ in true }
        )
        try tier.start()
        let originalPID = try XCTUnwrap(tier.status().hvPID)

        tier.stop()
        Thread.sleep(forTimeInterval: 0.15)

        XCTAssertEqual(tier.status().state, .stopped)
        XCTAssertNil(tier.status().hvPID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tier.socketPath))
        XCTAssertEqual(kill(originalPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testExplicitSleepCancelsQueuedSupervisorRestart() throws {
        let base = "/tmp/dory-tier-explicit-sleep-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let idle = IdleController()
        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: base + "/forward.sock",
                activitySocketPath: base + "/activity.sock",
                hvProcess: HvProcessConfiguration(
                    executablePath: "/bin/sleep",
                    arguments: ["30"],
                    restartPolicy: HvRestartPolicy(
                        maxRestarts: 3,
                        delaySeconds: 0.30,
                        maximumDelaySeconds: 0.30
                    )
                )
            ),
            idleController: idle,
            containerActivityProbe: { _ in .empty },
            dockerReadyWaiter: { _, _, _ in true }
        )
        try tier.start()
        defer { tier.stop() }
        let originalPID = try XCTUnwrap(tier.status().hvPID)

        XCTAssertEqual(kill(originalPID, SIGKILL), 0)
        XCTAssertTrue(waitUntil(timeout: 1) {
            let status = tier.status()
            return status.state == .starting && status.hvPID == nil
        })
        XCTAssertTrue(tier.sleepForIdle(idleAfter: 0))
        XCTAssertEqual(tier.status().state, .sleeping)
        XCTAssertNil(tier.status().hvPID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tier.socketPath))

        Thread.sleep(forTimeInterval: 0.40)
        XCTAssertEqual(tier.status().state, .sleeping)
        XCTAssertNil(tier.status().hvPID, "cancelled restart must not resurrect a sleeping tier")
    }

    func testQueuedRecoverySleepKeepsOneSocketAuthorityAcrossCleanupAndArm() throws {
        let base = "/tmp/dory-tier-recovery-sleep-authority-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let sleepingDataplaneStartEntered = DispatchSemaphore(value: 0)
        let releaseSleepingDataplaneStart = DispatchSemaphore(value: 0)
        let sleepFinished = DispatchSemaphore(value: 0)
        let sleepResult = LockedBoolBox()
        let dataplaneStarts = LockedInt()
        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: base + "/forward.sock",
                activitySocketPath: base + "/activity.sock",
                hvProcess: HvProcessConfiguration(
                    executablePath: "/bin/sleep",
                    arguments: ["30"],
                    restartPolicy: HvRestartPolicy(
                        maxRestarts: 3,
                        delaySeconds: 0.30,
                        maximumDelaySeconds: 0.30
                    )
                )
            ),
            idleController: IdleController(),
            containerActivityProbe: { _ in .empty },
            dockerReadyWaiter: { _, _, _ in true },
            beforeDataplaneStart: {
                if dataplaneStarts.increment() == 2 {
                    sleepingDataplaneStartEntered.signal()
                    _ = releaseSleepingDataplaneStart.wait(timeout: .now() + 3)
                }
            }
        )
        try tier.start()
        defer { tier.stop() }
        let originalPID = try XCTUnwrap(tier.status().hvPID)
        XCTAssertEqual(kill(originalPID, SIGKILL), 0)
        XCTAssertTrue(waitUntil(timeout: 1) {
            let status = tier.status()
            return status.state == .starting && status.hvPID == nil
        })

        DispatchQueue.global(qos: .userInitiated).async {
            sleepResult.set(tier.sleepForIdle(idleAfter: 0))
            sleepFinished.signal()
        }
        XCTAssertEqual(sleepingDataplaneStartEntered.wait(timeout: .now() + 3), .success)
        XCTAssertThrowsError(try tier.start()) { error in
            XCTAssertEqual("\(error)", DockerTier.TierError.helperTerminationPending.description)
        }

        releaseSleepingDataplaneStart.signal()
        XCTAssertEqual(sleepFinished.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(sleepResult.value, true)
        XCTAssertEqual(tier.status().state, .sleeping)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tier.socketPath))
        Thread.sleep(forTimeInterval: 0.40)
        XCTAssertEqual(tier.status().state, .sleeping)
        XCTAssertEqual(dataplaneStarts.value, 2)
    }

    func testSupervisorStopsAtLimitAndManualStartResetsBudget() throws {
        let base = "/tmp/dory-tier-restart-limit-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: base + "/forward.sock",
                activitySocketPath: base + "/activity.sock",
                hvProcess: HvProcessConfiguration(
                    executablePath: "/bin/sleep",
                    arguments: ["30"],
                    restartPolicy: HvRestartPolicy(
                        maxRestarts: 1,
                        delaySeconds: 0.02,
                        maximumDelaySeconds: 0.02,
                        stableRunSeconds: 60
                    )
                )
            ),
            idleController: IdleController(),
            dockerReadyWaiter: { _, _, _ in true }
        )
        defer { tier.stop() }
        try tier.start()
        let firstPID = try XCTUnwrap(tier.status().hvPID)

        XCTAssertEqual(kill(firstPID, SIGKILL), 0)
        XCTAssertTrue(waitUntil(timeout: 1) {
            let status = tier.status()
            return status.state == .running && status.hvPID != nil && status.hvPID != firstPID
        })
        let secondPID = try XCTUnwrap(tier.status().hvPID)
        XCTAssertEqual(kill(secondPID, SIGKILL), 0)

        XCTAssertTrue(waitUntil(timeout: 1) { tier.status().state == .failed })
        XCTAssertNil(tier.status().hvPID)
        XCTAssertTrue(tier.status().lastError?.contains("restart limit") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tier.socketPath))
        Thread.sleep(forTimeInterval: 0.10)
        XCTAssertEqual(tier.status().state, .failed, "no queued restart may resurrect the tier")

        try tier.start()
        XCTAssertEqual(tier.status().state, .running)
        XCTAssertNotNil(tier.status().hvPID)
    }

    func testHelperExitDuringRecoveryReadinessCancelsPromptlyAndConsumesBudget() throws {
        let base = "/tmp/dory-tier-startup-exit-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let marker = base + "/runs"
        let helper = base + "/helper.sh"
        try """
        #!/bin/sh
        runs=0
        if [ -f "$1" ]; then runs=$(wc -l < "$1"); fi
        echo run >> "$1"
        if [ "$runs" -eq 0 ]; then exec /bin/sleep 30; fi
        exit 17
        """.write(toFile: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper)

        let readyCalls = LockedInt()
        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: base + "/forward.sock",
                activitySocketPath: base + "/activity.sock",
                hvProcess: HvProcessConfiguration(
                    executablePath: helper,
                    arguments: [marker],
                    restartPolicy: HvRestartPolicy(
                        maxRestarts: 2,
                        delaySeconds: 0.01,
                        maximumDelaySeconds: 0.02,
                        stableRunSeconds: 60
                    )
                )
            ),
            idleController: IdleController(),
            dockerReadyWaiter: { _, timeout, shouldContinue in
                if readyCalls.increment() == 1 { return true }
                let deadline = Date().addingTimeInterval(min(timeout, 2))
                while Date() < deadline, shouldContinue() {
                    Thread.sleep(forTimeInterval: 0.005)
                }
                return false
            }
        )
        defer { tier.stop() }
        try tier.start()
        let firstPID = try XCTUnwrap(tier.status().hvPID)
        // Process.run() reports the child before a heavily loaded host necessarily schedules the
        // script body. Give that scheduling boundary room; the latency assertion below starts only
        // after this marker and still proves recovery does not consume the 180-second ready wait.
        let firstRunRecorded = waitUntil(timeout: 5) {
            ((try? String(contentsOfFile: marker, encoding: .utf8)) ?? "")
                .split(separator: "\n").count == 1
        }
        XCTAssertTrue(
            firstRunRecorded,
            "marker=\((try? String(contentsOfFile: marker, encoding: .utf8)) ?? "<missing>") status=\(tier.status())"
        )
        guard firstRunRecorded else { return }

        let killedAt = Date()
        XCTAssertEqual(kill(firstPID, SIGKILL), 0)
        XCTAssertTrue(waitUntil(timeout: 2) { tier.status().state == .failed })

        XCTAssertLessThan(Date().timeIntervalSince(killedAt), 1.5, "startup exit must not wait the 180-second readiness window")
        XCTAssertEqual(readyCalls.value, 3)
        XCTAssertEqual(
            (try String(contentsOfFile: marker, encoding: .utf8)).split(separator: "\n").count,
            3
        )
        XCTAssertTrue(tier.status().lastError?.contains("restart limit") == true)
        XCTAssertNil(tier.status().hvPID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tier.socketPath))
    }

    func testUnconfirmedHelperStopFailsClosedAndBlocksReplacementGeneration() throws {
        let base = "/tmp/dory-tier-unconfirmed-stop-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let helper = UnconfirmedStopDockerProcess(pid: 42_424)
        let states = LockedTierStates()
        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: base + "/forward.sock",
                activitySocketPath: base + "/activity.sock",
                hvProcess: HvProcessConfiguration(
                    executablePath: "/bin/false",
                    arguments: []
                )
            ),
            idleController: IdleController(),
            dockerReadyWaiter: { _, _, _ in true }
        )
        tier.installManagedProcessFactory { _, _ in helper }
        tier.setLifecycleStateObserver { states.append($0) }

        try tier.start()
        XCTAssertEqual(tier.status().state, .running)
        XCTAssertEqual(tier.status().hvPID, 42_424)

        XCTAssertFalse(tier.stop())
        XCTAssertEqual(tier.status().state, .failed)
        XCTAssertEqual(tier.status().hvPID, 42_424)
        XCTAssertTrue(tier.status().lastError?.contains("termination is still being verified") == true)
        XCTAssertFalse(states.value.contains(.stopped))
        XCTAssertThrowsError(try tier.start()) { error in
            XCTAssertEqual("\(error)", DockerTier.TierError.helperTerminationPending.description)
        }

        helper.confirmExit()
        XCTAssertTrue(tier.stop())
        XCTAssertEqual(tier.status().state, .stopped)
        XCTAssertNil(tier.status().hvPID)
        XCTAssertTrue(waitUntil(timeout: 1) { states.value.last == .stopped })
    }

    func testTerminalRetirementWaitUsesExactHelperCompletionWithoutPolling() throws {
        let base = "/tmp/dory-tier-terminal-wait-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let helper = UnconfirmedStopDockerProcess(pid: 43_004)
        let tier = makeTier(base: base, helper: helper)
        try tier.start()
        XCTAssertFalse(tier.shutdown())

        let waitResult = LockedBoolBox()
        let waitFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            waitResult.set(tier.waitForTerminalRetirement(timeout: 1))
            waitFinished.signal()
        }
        XCTAssertEqual(helper.terminationWaitEntered.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(waitFinished.wait(timeout: .now() + 0.05), .timedOut)

        helper.confirmExit()
        XCTAssertEqual(waitFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(waitResult.value, true)
        XCTAssertEqual(tier.status().state, .stopped)
        XCTAssertNil(tier.status().hvPID)
        XCTAssertFalse(tier.status().isStopping)
    }

    func testTerminalRetirementCannotMistakeCurrentHelperForRetiredBeforeTeardownClaim() throws {
        let base = "/tmp/dory-tier-current-terminal-wait-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let helper = UnconfirmedStopDockerProcess(pid: 43_005)
        let tier = makeTier(base: base, helper: helper)
        try tier.start()
        defer { _ = tier.shutdown() }

        tier.latchTerminalShutdown()
        XCTAssertFalse(
            tier.waitForTerminalRetirement(timeout: 0.02),
            "a live current helper is terminal authority even before a shutdown worker claims it"
        )
        XCTAssertEqual(tier.status().hvPID, 43_005)

        helper.confirmExit()
        XCTAssertTrue(tier.waitForTerminalRetirement(timeout: 1))
        XCTAssertEqual(tier.status().state, .stopped)
        XCTAssertNil(tier.status().hvPID)
    }

    func testFileServiceSnapshotRequiresFreshExactBoundedSchema() throws {
        let base = "/tmp/dory-tier-file-service-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let state = base + "/state"
        try FileManager.default.createDirectory(atPath: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let tier = DockerTier(configuration: DockerTierConfiguration(
            home: base + "/home",
            forwardSocketPath: base + "/forward.sock",
            hvProcess: HvProcessConfiguration(
                executablePath: "/bin/true",
                arguments: ["--state-dir", state]
            )
        ))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let path = state + "/file-service-resources.json"
        var record = fileServiceResourceRecord(generatedAt: now)

        try writeFileServiceResourceRecord(record, to: path)
        let decoded = try XCTUnwrap(tier.fileServiceResourceSnapshot(now: now))
        XCTAssertTrue(decoded.running)
        XCTAssertEqual(decoded.cacheMode, "zero-validity")
        XCTAssertEqual(decoded.configuredShareCount, 1)
        XCTAssertEqual(decoded.watcherNudgeShareCount, 1)
        XCTAssertEqual(decoded.requiredObservationShareCount, 1)
        XCTAssertEqual(decoded.observedRequiredShareCount, 1)

        record["hostPath"] = "/Users/private/project"
        try writeFileServiceResourceRecord(record, to: path)
        XCTAssertNil(
            tier.fileServiceResourceSnapshot(now: now),
            "unknown keys, including host paths, are outside the exact telemetry contract"
        )

        record.removeValue(forKey: "hostPath")
        record["watcherNudgeShareCount"] = 0
        try writeFileServiceResourceRecord(record, to: path)
        XCTAssertNil(
            tier.fileServiceResourceSnapshot(now: now),
            "policy counts cannot contradict the configured capability count"
        )

        record = fileServiceResourceRecord(generatedAt: now.addingTimeInterval(-16))
        try writeFileServiceResourceRecord(record, to: path)
        XCTAssertNil(tier.fileServiceResourceSnapshot(now: now))
    }

    func testDeprecatedHostShareSnapshotStillDecodesItsLegacyFile() throws {
        let base = "/tmp/dory-tier-host-share-compat-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let state = base + "/state"
        try FileManager.default.createDirectory(atPath: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let tier = DockerTier(configuration: DockerTierConfiguration(
            home: base + "/home",
            forwardSocketPath: base + "/forward.sock",
            hvProcess: HvProcessConfiguration(
                executablePath: "/bin/true",
                arguments: ["--state-dir", state]
            )
        ))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let record: [String: Any] = [
            "schema": "dev.dory.host-share.resources",
            "version": 1,
            "generatedAt": ISO8601DateFormatter().string(from: now),
            "configuredRoots": ["/workspace"],
            "observationRoots": ["/workspace"],
            "running": true,
            "flushScheduled": false,
            "consecutiveFailures": 0,
            "batcher": [
                "pendingCount": 1,
                "pendingLimit": 4_096,
                "pendingRequiresRescan": false,
                "receivedEventCount": 8,
                "deliveredBatchCount": 7,
                "failedBatchCount": 0,
                "rescanCollapseCount": 0,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: state + "/host-share-resources.json"))

        let snapshot = try XCTUnwrap(tier.hostShareResourceSnapshot(now: now))
        XCTAssertTrue(snapshot.running)
        XCTAssertEqual(snapshot.configuredRoots, ["/workspace"])
        XCTAssertEqual(snapshot.batcher.pendingCount, 1)
        XCTAssertEqual(snapshot.batcher.receivedEventCount, 8)
    }

    func testGuestResourceSnapshotRequiresExactVersionedCompleteRecord() throws {
        let valid = guestResourceRecord()
        let authority = guestDataDiskAuthority()
        let snapshot = try DockerTier.decodeGuestResourceSnapshot(
            valid,
            authority: authority
        )
        XCTAssertEqual(snapshot.selectedDataDriveID, authority.dataDriveID)
        XCTAssertEqual(snapshot.dataDiskFilesystemUUID, authority.filesystemUUID)
        XCTAssertEqual(snapshot.dataDiskMountSource, "/dev/vdb")
        XCTAssertEqual(snapshot.dataDiskFilesystemType, "ext4")
        XCTAssertEqual(snapshot.dataDiskDeviceMajorMinor, "254:16")
        XCTAssertEqual(snapshot.memoryCeilingBytes, 2_048 * 1_024)
        XCTAssertEqual(snapshot.memoryUsedBytes, 1_024 * 1_024)
        XCTAssertEqual(snapshot.memoryCacheBytes, 416 * 1_024)
        XCTAssertEqual(snapshot.memoryAvailableBytes, 1_024 * 1_024)
        XCTAssertEqual(snapshot.memoryReclaimableBytes, 512 * 1_024)
        XCTAssertEqual(snapshot.dataDiskTotalBytes, 137_438_953_472)

        var compatibilityMutation = snapshot
        compatibilityMutation.memoryReclaimableBytes = 256 * 1_024
        XCTAssertEqual(compatibilityMutation.memoryAvailableBytes, 768 * 1_024)
        XCTAssertEqual(compatibilityMutation.memoryUsedBytes, 1_280 * 1_024)

        let freeExceedsAvailable = String(decoding: valid, as: UTF8.self)
            .replacingOccurrences(of: "mem_free_kb=512", with: "mem_free_kb=1536")
        let freeExceedsAvailableSnapshot = try DockerTier.decodeGuestResourceSnapshot(
            Data(freeExceedsAvailable.utf8),
            authority: authority
        )
        XCTAssertEqual(freeExceedsAvailableSnapshot.memoryFreeBytes, 1_536 * 1_024)
        XCTAssertEqual(freeExceedsAvailableSnapshot.memoryAvailableBytes, 1_024 * 1_024)

        let text = String(decoding: valid, as: UTF8.self)
        let invalidRecords: [Data] = [
            Data(text.replacingOccurrences(
                of: "shmem_kb=32",
                with: "mem_total_kb=2048"
            ).utf8),
            Data(text.replacingOccurrences(
                of: "shmem_kb=32",
                with: "host_path=/private/project"
            ).utf8),
            Data(text.replacingOccurrences(
                of: "cached_kb=256",
                with: "cached_kb=invalid"
            ).utf8),
            Data(text.replacingOccurrences(
                of: "shmem_kb=32\n",
                with: ""
            ).utf8),
            Data(String(decoding: valid.dropLast(), as: UTF8.self).utf8),
            Data(text.replacingOccurrences(
                of: "mem_available_kb=1024",
                with: "mem_available_kb=2049"
            ).utf8),
            Data(text.replacingOccurrences(
                of: "mem_free_kb=512",
                with: "mem_free_kb=2049"
            ).utf8),
        ]
        for record in invalidRecords {
            XCTAssertThrowsError(try DockerTier.decodeGuestResourceSnapshot(
                record,
                authority: authority
            ))
        }
    }

    func testProductionGuestMountInfoAWKExecutesAgainstExactFixtures() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dory-guest-mount-awk-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let syntaxOutput = Pipe()
        let syntaxCheck = Process()
        syntaxCheck.executableURL = URL(fileURLWithPath: "/bin/sh")
        syntaxCheck.arguments = ["-n", "-c", DockerTier.guestResourceProbeScript]
        syntaxCheck.standardError = syntaxOutput
        try syntaxCheck.run()
        syntaxCheck.waitUntilExit()
        XCTAssertEqual(
            syntaxCheck.terminationStatus,
            0,
            String(decoding: syntaxOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
        XCTAssertEqual(
            DockerTier.guestResourceProbeScript.components(
                separatedBy: DockerTier.guestResourceMountInfoAWK
            ).count - 1,
            2,
            "the syntax-tested production probe must use the exact fixture-tested parser both times"
        )

        func execute(_ fixture: String, name: String) throws -> (Int32, String, String) {
            let fixtureURL = root.appendingPathComponent(name)
            try Data(fixture.utf8).write(to: fixtureURL, options: .atomic)
            let standardOutput = Pipe()
            let standardError = Pipe()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/awk")
            process.arguments = [DockerTier.guestResourceMountInfoAWK, fixtureURL.path]
            process.standardOutput = standardOutput
            process.standardError = standardError
            try process.run()
            process.waitUntilExit()
            return (
                process.terminationStatus,
                String(decoding: standardOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                String(decoding: standardError.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            )
        }

        let valid = try execute(
            """
            29 24 0:25 / / rw,relatime - tmpfs tmpfs rw
            36 25 254:16 / /var/lib/docker rw,relatime shared:9 - ext4 /dev/vdb rw

            """,
            name: "valid.mountinfo"
        )
        XCTAssertEqual(valid.0, 0, valid.2)
        XCTAssertEqual(valid.1, "36 254:16\n")

        let duplicate = try execute(
            """
            36 25 254:16 / /var/lib/docker rw,relatime - ext4 /dev/vdb rw
            37 25 254:16 / /var/lib/docker rw,relatime - ext4 /dev/vdb rw

            """,
            name: "duplicate.mountinfo"
        )
        XCTAssertNotEqual(duplicate.0, 0, "duplicate exact mounts must fail closed")

        let invalidMounts: [(name: String, fixture: String)] = [
            (
                "bind-subdirectory.mountinfo",
                "36 25 254:16 /docker-subdirectory /var/lib/docker rw,relatime - ext4 /dev/vdb rw\n"
            ),
            (
                "readonly-mount.mountinfo",
                "36 25 254:16 / /var/lib/docker ro,relatime - ext4 /dev/vdb rw\n"
            ),
            (
                "readonly-superblock.mountinfo",
                "36 25 254:16 / /var/lib/docker rw,relatime - ext4 /dev/vdb ro\n"
            ),
        ]
        for invalid in invalidMounts {
            let result = try execute(invalid.fixture, name: invalid.name)
            XCTAssertNotEqual(result.0, 0, "\(invalid.name) must fail closed")
            XCTAssertEqual(result.1, "")
        }
    }

    func testGuestResourceRecordRejectsWrongSourceRootfsFallbackAndChangedFilesystem() {
        let authority = guestDataDiskAuthority()
        let valid = String(decoding: guestResourceRecord(), as: UTF8.self)
        let invalidRecords = [
            valid.replacingOccurrences(
                of: "disk_mount_source=/dev/vdb",
                with: "disk_mount_source=/dev/vda"
            ),
            valid.replacingOccurrences(
                of: "disk_mount_source=/dev/vdb\ndisk_filesystem_type=ext4",
                with: "disk_mount_source=overlay\ndisk_filesystem_type=overlay"
            ),
            valid.replacingOccurrences(
                of: "disk_mount_source=/dev/vdb\n",
                with: ""
            ),
            valid.replacingOccurrences(
                of: "disk_device_major_minor=254:16",
                with: "disk_device_major_minor=0254:16"
            ),
            valid.replacingOccurrences(
                of: "disk_filesystem_uuid=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
                with: "disk_filesystem_uuid=11111111-2222-4333-8444-555555555555"
            ),
        ]

        for record in invalidRecords {
            XCTAssertThrowsError(try DockerTier.decodeGuestResourceSnapshot(
                Data(record.utf8),
                authority: authority
            ))
        }
    }

    func testManagedGuestReadinessAndCapacityUseTheSameExactDiskIdentity() throws {
        let base = "/tmp/dory-tier-guest-identity-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let client = GuestResourceProbeAgentClient(records: [
            .success(guestResourceRecord()),
            .success(guestResourceRecord()),
        ])
        let agent = AgentControl(
            configuration: AgentControlConfiguration(forwardSocketPath: base + "/agent.sock")
        ) { _ in client }
        let helper = ReadyDockerManagedProcess(pid: 44_001)
        let dataDriveRoot = base + "/selected.dorydrive"
        let authority = guestDataDiskAuthority(
            diskImagePath: dataDriveRoot + "/engine/docker-data.ext4"
        )
        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: base + "/forward.sock",
                hvProcess: HvProcessConfiguration(
                    executablePath: "/bin/false",
                    arguments: ["--data-drive", dataDriveRoot]
                )
            ),
            agentControl: agent,
            dockerReadyWaiter: { _, _, _ in true },
            guestDataDiskAuthorityProvider: { _ in authority }
        )
        tier.installManagedProcessFactory { _, _ in helper }

        try tier.start()
        XCTAssertEqual(tier.status().state, .running)
        XCTAssertEqual(client.resourceProbeCount, 1)
        let snapshot = try XCTUnwrap(tier.guestResourceSnapshot())
        XCTAssertEqual(snapshot.selectedDataDriveID, authority.dataDriveID)
        XCTAssertEqual(snapshot.dataDiskFilesystemUUID, authority.filesystemUUID)
        XCTAssertEqual(client.resourceProbeCount, 2)
        XCTAssertTrue(tier.stop())
    }

    func testManagedGuestRejectsAClonedUUIDFromTheWrongConfiguredHostDrive() throws {
        let base = "/tmp/dory-tier-cloned-uuid-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let selectedRoot = base + "/selected.dorydrive"
        let cloneRoot = base + "/clone.dorydrive"
        let selectedImage = selectedRoot + "/engine/docker-data.ext4"
        let cloneImage = cloneRoot + "/engine/docker-data.ext4"
        try FileManager.default.createDirectory(
            atPath: selectedRoot + "/engine",
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            atPath: cloneRoot + "/engine",
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: base) }
        try writeMinimalExt4Image(
            to: selectedImage,
            filesystemUUID: UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
        )
        try FileManager.default.copyItem(atPath: selectedImage, toPath: cloneImage)
        XCTAssertEqual(chmod(cloneImage, 0o600), 0)

        let dataDriveID = UUID(uuidString: "01234567-89ab-4cde-8f01-23456789abcd")!
        let selectedAuthority = try DockerTier.inspectGuestDataDiskAuthority(
            dataDriveID: dataDriveID,
            at: selectedImage
        )
        let clonedAuthority = try DockerTier.inspectGuestDataDiskAuthority(
            dataDriveID: dataDriveID,
            at: cloneImage
        )
        XCTAssertEqual(selectedAuthority.filesystemUUID, clonedAuthority.filesystemUUID)
        XCTAssertNotEqual(selectedAuthority.diskImageInode, clonedAuthority.diskImageInode)

        let client = GuestResourceProbeAgentClient(records: [.success(guestResourceRecord())])
        let agent = AgentControl(
            configuration: AgentControlConfiguration(forwardSocketPath: base + "/agent.sock")
        ) { _ in client }
        let helper = ReadyDockerManagedProcess(pid: 44_004)
        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: base + "/forward.sock",
                hvProcess: HvProcessConfiguration(
                    executablePath: "/bin/false",
                    arguments: ["--data-drive", selectedRoot]
                )
            ),
            agentControl: agent,
            dockerReadyWaiter: { _, _, _ in true },
            guestDataDiskAuthorityProvider: { _ in clonedAuthority }
        )
        tier.installManagedProcessFactory { _, _ in helper }

        XCTAssertThrowsError(try tier.start()) { error in
            XCTAssertTrue("\(error)".contains("exact image configured"), "\(error)")
        }
        XCTAssertEqual(client.resourceProbeCount, 0)
        XCTAssertEqual(tier.status().state, .failed)
        XCTAssertNil(tier.status().hvPID)
    }

    func testGuestDeviceBindingIsStrictWithinGenerationButRebindsOnNewBoot() throws {
        let base = "/tmp/dory-tier-guest-dev-binding-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let dataDriveRoot = base + "/selected.dorydrive"
        let authority = guestDataDiskAuthority(
            diskImagePath: dataDriveRoot + "/engine/docker-data.ext4"
        )
        let secondDeviceRecord = Data(
            String(decoding: guestResourceRecord(), as: UTF8.self)
                .replacingOccurrences(
                    of: "disk_device_major_minor=254:16",
                    with: "disk_device_major_minor=254:17"
                ).utf8
        )
        let client = GuestResourceProbeAgentClient(records: [
            .success(guestResourceRecord()),
            .success(secondDeviceRecord),
            .success(secondDeviceRecord),
            .success(secondDeviceRecord),
        ])
        let agent = AgentControl(
            configuration: AgentControlConfiguration(forwardSocketPath: base + "/agent.sock")
        ) { _ in client }
        let helper = ReadyDockerManagedProcess(pid: 44_005)
        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: base + "/forward.sock",
                hvProcess: HvProcessConfiguration(
                    executablePath: "/bin/false",
                    arguments: ["--data-drive", dataDriveRoot]
                )
            ),
            agentControl: agent,
            dockerReadyWaiter: { _, _, _ in true },
            guestDataDiskAuthorityProvider: { _ in authority }
        )
        tier.installManagedProcessFactory { _, _ in helper }

        try tier.start()
        XCTAssertThrowsError(try tier.guestResourceSnapshot()) { error in
            XCTAssertTrue("\(error)".contains("within one helper generation"), "\(error)")
        }
        XCTAssertTrue(tier.stop())

        try tier.start()
        XCTAssertEqual(tier.status().state, .running)
        XCTAssertEqual(
            try XCTUnwrap(tier.guestResourceSnapshot()).dataDiskDeviceMajorMinor,
            "254:17"
        )
        XCTAssertTrue(tier.stop())
    }

    func testManagedGuestReadinessRejectsRootfsFallbackBeforePublishingTheEngine() throws {
        let base = "/tmp/dory-tier-guest-rootfs-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let rootfsRecord = String(decoding: guestResourceRecord(), as: UTF8.self)
            .replacingOccurrences(
                of: "disk_mount_source=/dev/vdb\ndisk_filesystem_type=ext4",
                with: "disk_mount_source=/dev/vda\ndisk_filesystem_type=ext4"
            )
        let client = GuestResourceProbeAgentClient(records: [
            .success(Data(rootfsRecord.utf8)),
        ])
        let agent = AgentControl(
            configuration: AgentControlConfiguration(forwardSocketPath: base + "/agent.sock")
        ) { _ in client }
        let helper = ReadyDockerManagedProcess(pid: 44_002)
        let dataDriveRoot = base + "/selected.dorydrive"
        let authority = guestDataDiskAuthority(
            diskImagePath: dataDriveRoot + "/engine/docker-data.ext4"
        )
        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: base + "/forward.sock",
                hvProcess: HvProcessConfiguration(
                    executablePath: "/bin/false",
                    arguments: ["--data-drive", dataDriveRoot]
                )
            ),
            agentControl: agent,
            dockerReadyWaiter: { _, _, _ in true },
            guestDataDiskAuthorityProvider: { _ in authority }
        )
        tier.installManagedProcessFactory { _, _ in helper }

        XCTAssertThrowsError(try tier.start()) { error in
            XCTAssertTrue("\(error)".contains("Mounts and data disk readiness failed"), "\(error)")
        }
        XCTAssertEqual(tier.status().state, .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tier.socketPath))
    }

    func testGuestResourceProbeRejectsTimeoutAndUnparseableOutput() throws {
        let authority = guestDataDiskAuthority()
        let cases: [GuestResourceProbeAgentClient.ResourceResult] = [
            .timeout(guestResourceRecord()),
            .success(Data("not-a-versioned-record\n".utf8)),
        ]
        for (index, result) in cases.enumerated() {
            let base = "/tmp/dory-tier-guest-invalid-\(getpid())-\(index)-\(UInt32.random(in: 0..<UInt32.max))"
            defer { try? FileManager.default.removeItem(atPath: base) }
            let client = GuestResourceProbeAgentClient(records: [result])
            let agent = AgentControl(
                configuration: AgentControlConfiguration(forwardSocketPath: base + "/agent.sock")
            ) { _ in client }
            let tier = DockerTier(
                configuration: DockerTierConfiguration(
                    home: base + "/home",
                    forwardSocketPath: base + "/forward.sock"
                ),
                agentControl: agent,
                guestDataDiskAuthorityProvider: { _ in authority }
            )
            try tier.start()
            XCTAssertThrowsError(try tier.guestResourceSnapshot())
            XCTAssertTrue(tier.stop())
        }
    }

    func testGuestFilesystemIdentityCannotChangeAfterTheFirstVerifiedProbe() throws {
        let base = "/tmp/dory-tier-guest-replaced-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let firstAuthority = guestDataDiskAuthority()
        let secondFilesystemUUID = try XCTUnwrap(UUID(
            uuidString: "11111111-2222-4333-8444-555555555555"
        ))
        let secondAuthority = guestDataDiskAuthority(filesystemUUID: secondFilesystemUUID)
        let secondRecord = String(decoding: guestResourceRecord(), as: UTF8.self)
            .replacingOccurrences(
                of: firstAuthority.filesystemUUID.uuidString.lowercased(),
                with: secondFilesystemUUID.uuidString.lowercased()
            )
        let authorities = GuestDataDiskAuthoritySequence([
            firstAuthority,
            secondAuthority,
        ])
        let client = GuestResourceProbeAgentClient(records: [
            .success(guestResourceRecord()),
            .success(Data(secondRecord.utf8)),
        ])
        let agent = AgentControl(
            configuration: AgentControlConfiguration(forwardSocketPath: base + "/agent.sock")
        ) { _ in client }
        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: base + "/forward.sock"
            ),
            agentControl: agent,
            guestDataDiskAuthorityProvider: { _ in authorities.next() }
        )
        try tier.start()

        _ = try XCTUnwrap(tier.guestResourceSnapshot())
        XCTAssertThrowsError(try tier.guestResourceSnapshot()) { error in
            XCTAssertTrue("\(error)".contains("identity changed within one helper generation"), "\(error)")
        }
        XCTAssertTrue(tier.stop())
    }

    func testGuestResourceProbeRejectsAStopAcrossTheExactExecGeneration() throws {
        let base = "/tmp/dory-tier-guest-stop-race-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let client = GuestResourceProbeAgentClient(
            records: [
                .success(guestResourceRecord()),
                .success(guestResourceRecord()),
            ],
            blockOnProbeNumber: 2
        )
        let agent = AgentControl(
            configuration: AgentControlConfiguration(forwardSocketPath: base + "/agent.sock")
        ) { _ in client }
        let helper = ReadyDockerManagedProcess(pid: 44_003)
        let dataDriveRoot = base + "/selected.dorydrive"
        let authority = guestDataDiskAuthority(
            diskImagePath: dataDriveRoot + "/engine/docker-data.ext4"
        )
        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: base + "/forward.sock",
                hvProcess: HvProcessConfiguration(
                    executablePath: "/bin/false",
                    arguments: ["--data-drive", dataDriveRoot]
                )
            ),
            agentControl: agent,
            dockerReadyWaiter: { _, _, _ in true },
            guestDataDiskAuthorityProvider: { _ in authority }
        )
        tier.installManagedProcessFactory { _, _ in helper }
        try tier.start()

        let outcome = Capture()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try tier.guestResourceSnapshot()
            } catch {
                outcome.setError("\(error)")
            }
            finished.signal()
        }
        XCTAssertTrue(client.waitUntilBlocked(timeout: 2))
        XCTAssertTrue(tier.stop())
        client.releaseBlockedProbe()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(
            outcome.error?.contains("boundary") == true,
            outcome.error ?? "late stopped-generation snapshot was accepted"
        )
    }

    private func makeTier(
        base: String,
        helper: any DockerManagedProcess
    ) -> DockerTier {
        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: base + "/forward.sock",
                activitySocketPath: base + "/activity.sock",
                hvProcess: HvProcessConfiguration(
                    executablePath: "/bin/false",
                    arguments: []
                )
            ),
            idleController: IdleController(),
            dockerReadyWaiter: { _, _, _ in true }
        )
        tier.installManagedProcessFactory { _, _ in helper }
        return tier
    }
}

private func guestResourceRecord() -> Data {
    Data("""
    schema=dev.dory.guest-resources
    version=2
    mem_total_kb=2048
    mem_available_kb=1024
    mem_free_kb=512
    buffers_kb=128
    cached_kb=256
    sreclaimable_kb=64
    shmem_kb=32
    disk_mount_source=/dev/vdb
    disk_filesystem_type=ext4
    disk_device_major_minor=254:16
    disk_filesystem_uuid=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
    disk_total_bytes=137438953472
    disk_used_bytes=8589934592
    disk_available_bytes=128849018880

    """.utf8)
}

private func writeMinimalExt4Image(to path: String, filesystemUUID: UUID) throws {
    var image = Data(repeating: 0, count: 2_048)
    let superblock = 1_024
    // Two 1 KiB blocks: enough real geometry for the production no-follow inspector.
    image[superblock + 0x04] = 2
    image[superblock + 0x38] = 0x53
    image[superblock + 0x39] = 0xef
    var rawUUID = filesystemUUID.uuid
    let uuidBytes = withUnsafeBytes(of: &rawUUID) { Array($0) }
    image.replaceSubrange(
        (superblock + 0x68)..<(superblock + 0x68 + uuidBytes.count),
        with: uuidBytes
    )
    try image.write(to: URL(fileURLWithPath: path), options: .atomic)
    guard chmod(path, 0o600) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

private func guestDataDiskAuthority(
    dataDriveID: UUID = UUID(uuidString: "01234567-89ab-4cde-8f01-23456789abcd")!,
    filesystemUUID: UUID = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!,
    diskImagePath: String = "/test/selected.dorydrive/engine/docker-data.ext4"
) -> DockerGuestDataDiskAuthority {
    DockerGuestDataDiskAuthority(
        dataDriveID: dataDriveID,
        filesystemUUID: filesystemUUID,
        diskImagePath: diskImagePath,
        diskImageDevice: 1,
        diskImageInode: 1
    )
}

private func fileServiceResourceRecord(generatedAt: Date) -> [String: Any] {
    [
        "schema": "dev.dory.file-service.resources",
        "version": 1,
        "generatedAt": ISO8601DateFormatter().string(from: generatedAt),
        "running": true,
        "cacheMode": "zero-validity",
        "maximumCacheValiditySeconds": 0,
        "configuredShareCount": 1,
        "invalidationOnlyShareCount": 0,
        "watcherNudgeShareCount": 1,
        "frontendCount": 3,
        "requestQueueCount": 3,
        "observationRequired": true,
        "observationActive": true,
        "requiredObservationShareCount": 1,
        "observedRequiredShareCount": 1,
        "observationStreamCount": 1,
        "pendingEventCount": 0,
        "pendingEventLimit": 65_536,
        "receivedEventCount": 4,
        "deliveredBatchCount": 4,
        "failedBatchCount": 0,
        "eventLossCount": 0,
        "invalidationCount": 4,
        "invalidationFailureCount": 0,
        "invalidationFailureLatched": false,
        "rejectedRequestCount": 0,
        "executedRequestCount": 10,
        "terminalQueueFaultCount": 0,
        "completedRequestCount": 10,
        "failedRequestCount": 0,
        "inFlightRequestCount": 0,
        "peakInFlightRequestCount": 1,
        "requestPayloadBytes": 1_024,
        "workerResponsePayloadBytes": 2_048,
        "guestPublishedResponseBytes": 2_048,
        "totalRequestLatencyNanoseconds": 10_000,
        "maximumRequestLatencyNanoseconds": 2_000,
        "coherenceReceivedBatchCount": 4,
        "coherenceReplayedBatchCount": 0,
        "coherenceInFlightBatchCount": 0,
        "coherenceFailedBatchCount": 0,
        "coherenceTotalLatencyNanoseconds": 4_000,
        "coherenceMaximumLatencyNanoseconds": 1_000,
        "coherenceRequestBytes": 400,
        "coherenceAcknowledgementBytes": 192,
        "coherenceTerminalFailureLatched": false,
    ]
}

private func writeFileServiceResourceRecord(
    _ record: [String: Any],
    to path: String
) throws {
    let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
}

private final class GuestResourceProbeAgentClient: AgentControlClient, @unchecked Sendable {
    enum ResourceResult {
        case success(Data)
        case timeout(Data)
    }

    private let lock = NSLock()
    private var records: [ResourceResult]
    private var storedResourceProbeCount = 0
    private let blockOnProbeNumber: Int?
    private let blockedProbeEntered = DispatchSemaphore(value: 0)
    private let blockedProbeRelease = DispatchSemaphore(value: 0)

    init(records: [ResourceResult], blockOnProbeNumber: Int? = nil) {
        self.records = records
        self.blockOnProbeNumber = blockOnProbeNumber
    }

    var resourceProbeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedResourceProbeCount
    }

    func info() throws -> DoryAgentInfo {
        DoryAgentInfo(
            protocolVersion: DoryCore.protocolVersion(),
            kernel: "Linux identity-test",
            agentBuild: "identity-test-agent",
            uptimeSeconds: 1,
            capabilities: [DoryAgentCapability(id: "exec", version: 1)]
        )
    }

    func clockSync(hostEpochNs: Int64) throws -> Bool {
        _ = hostEpochNs
        return true
    }

    func portsWatch() throws -> DoryPortsSnapshot {
        DoryPortsSnapshot(ports: [], added: [], removed: [])
    }

    func telemetry() throws -> DoryTelemetry {
        DoryTelemetry(
            memTotalKB: 2_048,
            memAvailableKB: 1_024,
            psiSomeAvg10: 0,
            psiFullAvg10: 0
        )
    }

    func exec(
        argv: [String],
        cwd: String,
        env: [DoryExecEnvironment],
        timeoutMs: UInt64,
        outputLimitBytes: UInt64
    ) throws -> DoryExecResult {
        _ = cwd
        _ = env
        _ = timeoutMs
        _ = outputLimitBytes
        let command = argv.joined(separator: " ")
        guard command.contains("/proc/self/mountinfo") else {
            return DoryExecResult(
                exitCode: 0,
                stdout: Data(),
                stderr: Data(),
                timedOut: false,
                stdoutTruncated: false,
                stderrTruncated: false
            )
        }
        lock.lock()
        storedResourceProbeCount += 1
        let probeNumber = storedResourceProbeCount
        let result = records.isEmpty ? nil : records.removeFirst()
        lock.unlock()
        if probeNumber == blockOnProbeNumber {
            blockedProbeEntered.signal()
            _ = blockedProbeRelease.wait(timeout: .now() + 5)
        }
        guard let result else {
            return DoryExecResult(
                exitCode: 79,
                stdout: Data(),
                stderr: Data("missing test resource record\n".utf8),
                timedOut: false,
                stdoutTruncated: false,
                stderrTruncated: false
            )
        }
        switch result {
        case .success(let data):
            return DoryExecResult(
                exitCode: 0,
                stdout: data,
                stderr: Data(),
                timedOut: false,
                stdoutTruncated: false,
                stderrTruncated: false
            )
        case .timeout(let data):
            return DoryExecResult(
                exitCode: 0,
                stdout: data,
                stderr: Data(),
                timedOut: true,
                stdoutTruncated: false,
                stderrTruncated: false
            )
        }
    }

    func waitUntilBlocked(timeout: TimeInterval) -> Bool {
        blockedProbeEntered.wait(timeout: .now() + max(0, timeout)) == .success
    }

    func releaseBlockedProbe() {
        blockedProbeRelease.signal()
    }

    func close() {}
}

private final class GuestDataDiskAuthoritySequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [DockerGuestDataDiskAuthority]

    init(_ values: [DockerGuestDataDiskAuthority]) {
        precondition(!values.isEmpty)
        self.values = values
    }

    func next() -> DockerGuestDataDiskAuthority {
        lock.lock()
        defer { lock.unlock() }
        if values.count == 1 { return values[0] }
        return values.removeFirst()
    }
}

private final class ReadyDockerManagedProcess: DockerManagedProcess, @unchecked Sendable {
    let startEntered = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let processID: Int32
    private var running = false

    init(pid: Int32) {
        processID = pid
    }

    func start() throws {
        lock.lock()
        running = true
        lock.unlock()
        startEntered.signal()
    }

    func suspend() -> Bool { true }
    func resume() -> Bool { true }

    func stop() -> Bool {
        lock.lock()
        running = false
        lock.unlock()
        return true
    }

    func waitForTermination(timeout: TimeInterval) -> Bool {
        _ = timeout
        lock.lock()
        defer { lock.unlock() }
        return !running
    }

    func lifecycleObservation(
        until deadline: DispatchTime
    ) -> DockerManagedProcessObservation? {
        _ = deadline
        lock.lock()
        defer { lock.unlock() }
        return DockerManagedProcessObservation(
            pid: running ? processID : nil,
            isRunning: running
        )
    }
}

final class UnconfirmedStopDockerProcess: DockerManagedProcess, @unchecked Sendable {
    private let lock = NSLock()
    private let terminationWaiter = DispatchGroup()
    let terminationWaitEntered = DispatchSemaphore(value: 0)
    private let processID: Int32
    private var running = false
    private var terminationOutstanding = false
    private var unexpectedTerminationHandler: HvProcessUnexpectedTerminationHandler?

    init(pid: Int32) {
        processID = pid
    }

    var pid: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return running ? processID : nil
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    func start() throws {
        lock.lock()
        if !terminationOutstanding {
            terminationWaiter.enter()
            terminationOutstanding = true
        }
        running = true
        lock.unlock()
    }

    func suspend() -> Bool { true }
    func resume() -> Bool { true }
    func stop() -> Bool { false }

    func waitForTermination(timeout: TimeInterval) -> Bool {
        terminationWaitEntered.signal()
        return terminationWaiter.wait(timeout: .now() + max(0, timeout)) == .success
    }

    func lifecycleObservation(
        until deadline: DispatchTime
    ) -> DockerManagedProcessObservation? {
        lock.lock()
        defer { lock.unlock() }
        return DockerManagedProcessObservation(
            pid: running ? processID : nil,
            isRunning: running
        )
    }

    func confirmExit() {
        lock.lock()
        running = false
        let shouldSignal = terminationOutstanding
        terminationOutstanding = false
        lock.unlock()
        if shouldSignal { terminationWaiter.leave() }
    }

    func setUnexpectedTerminationHandler(
        _ handler: HvProcessUnexpectedTerminationHandler?
    ) {
        lock.lock()
        unexpectedTerminationHandler = handler
        lock.unlock()
    }

    func reportUnexpectedTermination() {
        lock.lock()
        let handler = unexpectedTerminationHandler
        lock.unlock()
        handler?(HvProcessTermination(status: SIGKILL, wasUncaughtSignal: true))
    }
}

private final class BlockingStopDockerProcess: DockerManagedProcess, @unchecked Sendable {
    let stopEntered = DispatchSemaphore(value: 0)
    let releaseStop = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private let terminationWaiter = DispatchGroup()
    private let processID: Int32
    private var running = false
    private var terminationOutstanding = false
    private var storedStartCallCount = 0
    private var storedStopCallCount = 0

    init(pid: Int32) {
        processID = pid
    }

    var pid: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return running ? processID : nil
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    var stopCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedStopCallCount
    }

    var startCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedStartCallCount
    }

    func start() throws {
        lock.lock()
        storedStartCallCount += 1
        if !terminationOutstanding {
            terminationWaiter.enter()
            terminationOutstanding = true
        }
        running = true
        lock.unlock()
    }

    func suspend() -> Bool { true }
    func resume() -> Bool { true }

    func stop() -> Bool {
        lock.lock()
        storedStopCallCount += 1
        lock.unlock()
        stopEntered.signal()
        _ = releaseStop.wait(timeout: .now() + 2)

        lock.lock()
        running = false
        let shouldSignal = terminationOutstanding
        terminationOutstanding = false
        lock.unlock()
        if shouldSignal { terminationWaiter.leave() }
        return true
    }

    func waitForTermination(timeout: TimeInterval) -> Bool {
        terminationWaiter.wait(timeout: .now() + max(0, timeout)) == .success
    }

    func lifecycleObservation(
        until deadline: DispatchTime
    ) -> DockerManagedProcessObservation? {
        lock.lock()
        defer { lock.unlock() }
        return DockerManagedProcessObservation(
            pid: running ? processID : nil,
            isRunning: running
        )
    }
}

private final class StaleFalseStopDockerProcess: DockerManagedProcess, @unchecked Sendable {
    private let lock = NSLock()
    private let terminationWaiter = DispatchGroup()
    private let processID: Int32
    private var running = false
    private var terminationOutstanding = false
    private var storedStopCallCount = 0

    init(pid: Int32) {
        processID = pid
    }

    var pid: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return running ? processID : nil
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    var stopCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedStopCallCount
    }

    func start() throws {
        lock.lock()
        if !terminationOutstanding {
            terminationWaiter.enter()
            terminationOutstanding = true
        }
        running = true
        lock.unlock()
    }

    func suspend() -> Bool { true }
    func resume() -> Bool { true }

    func stop() -> Bool {
        lock.lock()
        storedStopCallCount += 1
        running = false
        let shouldSignal = terminationOutstanding
        terminationOutstanding = false
        lock.unlock()
        if shouldSignal { terminationWaiter.leave() }
        return false
    }

    func waitForTermination(timeout: TimeInterval) -> Bool {
        terminationWaiter.wait(timeout: .now() + max(0, timeout)) == .success
    }

    func lifecycleObservation(
        until deadline: DispatchTime
    ) -> DockerManagedProcessObservation? {
        lock.lock()
        defer { lock.unlock() }
        return DockerManagedProcessObservation(
            pid: running ? processID : nil,
            isRunning: running
        )
    }
}

private final class Capture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPreamble: [UInt8]?
    private var storedRequest: String?
    private var storedError: String?

    var preamble: [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        return storedPreamble
    }

    var request: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedRequest
    }

    var error: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    func setPreamble(_ preamble: [UInt8]) {
        lock.lock()
        storedPreamble = preamble
        lock.unlock()
    }

    func setRequest(_ request: String) {
        lock.lock()
        storedRequest = request
        lock.unlock()
    }

    func setError(_ error: String) {
        lock.lock()
        storedError = error
        lock.unlock()
    }
}

private enum SocketTestError: Error {
    case pathTooLong
    case syscall(String, Int32)
    case connectTimedOut(String)
}

private func bindUnixListener(path: String) throws -> Int32 {
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw SocketTestError.syscall("socket", errno) }

    var address = try unixAddress(path: path)
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
            Darwin.bind(fd, raw, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else {
        let error = errno
        close(fd)
        throw SocketTestError.syscall("bind", error)
    }
    guard listen(fd, 8) == 0 else {
        let error = errno
        close(fd)
        throw SocketTestError.syscall("listen", error)
    }
    return fd
}

private func connectUnix(path: String) throws -> Int32 {
    var lastErrno: Int32 = 0
    for _ in 0..<100 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketTestError.syscall("socket", errno) }
        var address = try unixAddress(path: path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                connect(fd, raw, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 {
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            return fd
        }
        lastErrno = errno
        close(fd)
        usleep(20_000)
    }
    throw SocketTestError.connectTimedOut("\(path): \(lastErrno)")
}

private func unixAddress(path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        throw SocketTestError.pathTooLong
    }
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        bytes.withUnsafeBytes { source in
            destination.baseAddress!.copyMemory(from: source.baseAddress!, byteCount: bytes.count)
        }
    }
    return address
}

private func readExactly(_ count: Int, from fd: Int32) -> [UInt8]? {
    var bytes = [UInt8](repeating: 0, count: count)
    var offset = 0
    while offset < count {
        let got = bytes.withUnsafeMutableBytes { raw in
            Darwin.read(fd, raw.baseAddress!.advanced(by: offset), count - offset)
        }
        if got == 0 { return nil }
        if got < 0 {
            if errno == EINTR { continue }
            return nil
        }
        offset += got
    }
    return bytes
}

private func readUntilHeaderEnd(from fd: Int32) -> String? {
    var bytes: [UInt8] = []
    var byte = UInt8(0)
    while bytes.count < 8192 {
        let got = Darwin.read(fd, &byte, 1)
        if got == 1 {
            bytes.append(byte)
            if bytes.suffix(4) == [13, 10, 13, 10] {
                return String(decoding: bytes, as: UTF8.self)
            }
            continue
        }
        if got < 0 && errno == EINTR { continue }
        return nil
    }
    return nil
}

private func readAvailableString(from fd: Int32) -> String {
    var output = [UInt8]()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let capacity = buffer.count
        let got = buffer.withUnsafeMutableBytes { raw in
            Darwin.read(fd, raw.baseAddress!, capacity)
        }
        if got > 0 {
            output.append(contentsOf: buffer.prefix(got))
            continue
        }
        if got < 0 && errno == EINTR { continue }
        break
    }
    return String(decoding: output, as: UTF8.self)
}

@discardableResult
private func writeAll(_ string: String, to fd: Int32) -> Bool {
    writeAll(Array(string.utf8), to: fd)
}

@discardableResult
private func writeAll(_ bytes: [UInt8], to fd: Int32) -> Bool {
    var offset = 0
    while offset < bytes.count {
        let written = bytes.withUnsafeBytes { raw in
            Darwin.write(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
        }
        if written < 0 {
            if errno == EINTR { continue }
            return false
        }
        offset += written
    }
    return true
}

private func le32(_ bytes: [UInt8]) -> UInt32 {
    UInt32(bytes[0])
        | UInt32(bytes[1]) << 8
        | UInt32(bytes[2]) << 16
        | UInt32(bytes[3]) << 24
}

private final class LockedErrorBox: @unchecked Sendable {
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

private final class LockedBoolBox: @unchecked Sendable {
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

private final class LockedInt: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    @discardableResult
    func increment() -> Int {
        lock.lock()
        stored += 1
        let value = stored
        lock.unlock()
        return value
    }
}

private final class LockedTierStates: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [DockerTierState] = []

    var value: [DockerTierState] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func append(_ state: DockerTierState) {
        lock.lock()
        stored.append(state)
        lock.unlock()
    }
}

private func waitUntil(
    timeout: TimeInterval,
    pollInterval: TimeInterval = 0.005,
    _ condition: () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: pollInterval)
    }
    return condition()
}
