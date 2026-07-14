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

        XCTAssertEqual(states.value, [.running, .sleeping, .running])
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

        XCTAssertEqual(states.value, [.running])
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

    func testConcurrentRestartWaitsForOrdinaryStopEndpointTeardown() throws {
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
                waitUntil(timeout: 2) {
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

        let restartFinished = DispatchSemaphore(value: 0)
        let restartError = LockedErrorBox()
        DispatchQueue.global().async {
            do {
                try tier.start()
            } catch {
                restartError.set(error)
            }
            restartFinished.signal()
        }

        XCTAssertEqual(
            restartFinished.wait(timeout: .now() + 0.15),
            .timedOut,
            "a replacement lifecycle must not bind while the older stop still owns teardown"
        )
        XCTAssertEqual(stopFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(restartFinished.wait(timeout: .now() + 2), .success)
        XCTAssertNil(restartError.value)
        XCTAssertEqual(tier.status().state, .running)
        XCTAssertNotEqual(tier.status().hvPID, originalPID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tier.socketPath))
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
