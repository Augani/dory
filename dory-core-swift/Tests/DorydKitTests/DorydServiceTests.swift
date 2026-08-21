import DoryCore
@testable import DorydKit
import CryptoKit
import DoryOperations
import XCTest

final class DorydServiceTests: XCTestCase {
    func testPublishedPortRepairDetailUsesValidatedGvproxyReceiptCounts() {
        let startedAt = Date()
        let receipt = PublishedPortReconcileReceipt(
            requestID: "repair-1",
            enginePID: 42,
            startedAt: startedAt,
            finishedAt: startedAt.addingTimeInterval(0.1),
            publishedPortCount: 3,
            desiredForwardCount: 5,
            observedForwardCount: 5,
            addedForwardCount: 1,
            removedForwardCount: 2,
            missingForwardCount: 0,
            unexpectedForwardCount: 0
        )

        let detail = DorydService.publishedPortRepairDetail(receipt)

        XCTAssertEqual(
            detail,
            "completed and validated gvproxy reconciliation for 3 published port(s) across 5 forward(s), added 1, removed 2"
        )
        XCTAssertFalse(detail.contains("requested"))
    }

    func testProtocolVersionOverXPCReturnsRustVersion() throws {
        let service = DorydService(socketPath: "/tmp/doryd-test.sock")
        let listener = makeAnonymousListener(service: service)
        listener.resume()
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: DorydControl.self)
        connection.resume()
        defer { connection.invalidate() }

        guard let proxy = connection.remoteObjectProxy as? DorydControl else {
            return XCTFail("no proxy")
        }

        let got = expectation(description: "protocolVersion reply")
        var version: UInt32 = 0
        proxy.protocolVersion { value in
            version = value
            got.fulfill()
        }
        wait(for: [got], timeout: 5)

        XCTAssertEqual(version, DoryCore.protocolVersion())
        XCTAssertEqual(version, 1)
    }

    func testSocketPathOverXPC() throws {
        let service = DorydService(socketPath: "/tmp/doryd-test.sock")
        let listener = makeAnonymousListener(service: service)
        listener.resume()
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: DorydControl.self)
        connection.resume()
        defer { connection.invalidate() }

        let proxy = try XCTUnwrap(connection.remoteObjectProxy as? DorydControl)
        let got = expectation(description: "path reply")
        var path = ""
        proxy.dorySocketPath { value in
            path = value
            got.fulfill()
        }
        wait(for: [got], timeout: 5)
        XCTAssertEqual(path, "/tmp/doryd-test.sock")
    }

    func testIdlePolicyOverXPCReadsWritesAndReturnsHistory() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("doryd-idle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let doryDir = home.appendingPathComponent(".dory", isDirectory: true)
        try FileManager.default.createDirectory(at: doryDir, withIntermediateDirectories: true)
        let incidentWriter = IncidentWriter(path: doryDir.appendingPathComponent("incidents.jsonl").path)
        incidentWriter.record(
            type: "engine.lifecycle",
            detail: "sleeping",
            at: Date(timeIntervalSince1970: 1)
        )
        incidentWriter.record(type: "network.routes", detail: "unrelated", at: Date(timeIntervalSince1970: 2))

        let store = IdlePolicyStore(home: home.path, environment: [:], dockerContainers: {
            .ok([
                try! JSONDecoder().decode(DockerContainerSummary.self, from: Data(
                    """
                    {"Id":"abc123456789","Names":["/web"],"State":"running","Ports":[{"PrivatePort":80,"PublicPort":8080,"Type":"tcp"}],"Labels":{"io.dory.keep-awake":"true"}}
                    """.utf8
                ))
            ])
        })
        let service = DorydService(
            socketPath: "/tmp/doryd-test.sock",
            idlePolicyStore: store,
            incidentWriter: incidentWriter
        )
        let listener = makeAnonymousListener(service: service)
        listener.resume()
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: DorydControl.self)
        connection.resume()
        defer { connection.invalidate() }

        let proxy = try XCTUnwrap(connection.remoteObjectProxy as? DorydControl)

        let statusReply = expectation(description: "idle status")
        var status: NSDictionary = [:]
        proxy.idleStatus { body, message in
            XCTAssertEqual(message, "")
            status = body
            statusReply.fulfill()
        }
        wait(for: [statusReply], timeout: 5)
        XCTAssertEqual(status["mode"] as? String, "always-on")
        XCTAssertEqual(status["engine_desired_state"] as? String, "running")
        XCTAssertEqual(status["auto_idle_enabled"] as? Bool, false)
        XCTAssertEqual(status["sleep_after_minutes"] as? Int, 15)
        XCTAssertEqual((status["blockers"] as? [NSDictionary])?.count, 2)
        let engineState = try XCTUnwrap(status["engine_state"] as? NSDictionary)
        XCTAssertEqual(engineState["owner"] as? String, "doryd")
        XCTAssertEqual(engineState["state"] as? String, "unconfigured")

        let setReply = expectation(description: "set idle policy")
        var updated: NSDictionary = [:]
        proxy.idleSetPolicy("sleepAfterMinutes", value: "30") { ok, body, message in
            XCTAssertTrue(ok, message)
            updated = body
            setReply.fulfill()
        }
        wait(for: [setReply], timeout: 5)
        XCTAssertEqual(updated["sleep_after_minutes"] as? Int, 30)

        let modeReply = expectation(description: "set idle mode")
        proxy.idleSetMode("auto-idle") { ok, body, message in
            XCTAssertTrue(ok, message)
            XCTAssertEqual(body["mode"] as? String, "auto-idle")
            modeReply.fulfill()
        }
        wait(for: [modeReply], timeout: 5)

        let historyReply = expectation(description: "idle history")
        var history: NSArray = []
        proxy.idleHistory(40) { rows, message in
            XCTAssertEqual(message, "")
            history = rows
            historyReply.fulfill()
        }
        wait(for: [historyReply], timeout: 5)
        XCTAssertEqual((history.firstObject as? NSDictionary)?["state"] as? String, "sleeping")

        let persisted = try Data(contentsOf: doryDir.appendingPathComponent("config.json"))
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: persisted) as? [String: Any])
        XCTAssertEqual(config["runtimeMode"] as? String, "auto-idle")
        XCTAssertEqual((config["idle"] as? [String: Any])?["sleepAfterMinutes"] as? Int, 30)
    }

    func testEngineStatusOverXPCReportsUnconfiguredWhenNoDockerTierIsInstalled() throws {
        let service = DorydService(socketPath: "/tmp/doryd-test.sock")
        let listener = makeAnonymousListener(service: service)
        listener.resume()
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: DorydControl.self)
        connection.resume()
        defer { connection.invalidate() }

        let proxy = try XCTUnwrap(connection.remoteObjectProxy as? DorydControl)
        let got = expectation(description: "engineStatus reply")
        var state = ""
        var message = ""
        proxy.engineStatus { value, detail in
            state = value
            message = detail
            got.fulfill()
        }
        wait(for: [got], timeout: 5)
        XCTAssertEqual(state, "unconfigured")
        XCTAssertTrue(message.contains("not configured"))

        let stopped = expectation(description: "engineStop unconfigured reply")
        proxy.engineStop { ok, detail in
            XCTAssertFalse(ok)
            XCTAssertTrue(detail.contains("not configured"))
            stopped.fulfill()
        }
        wait(for: [stopped], timeout: 5)
    }

    func testEngineStartAndStopOverXPCDriveDockerTier() throws {
        let home = "/tmp/doryd-service-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tier = DockerTier(configuration: DockerTierConfiguration(
            home: home,
            forwardSocketPath: home + "/forward.sock"
        ))
        let idlePolicyStore = IdlePolicyStore(home: home, environment: [:])
        let service = DorydService(
            socketPath: tier.socketPath,
            dockerTier: tier,
            idlePolicyStore: idlePolicyStore
        )
        let listener = makeAnonymousListener(service: service)
        listener.resume()
        defer {
            listener.invalidate()
            tier.stop()
        }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: DorydControl.self)
        connection.resume()
        defer { connection.invalidate() }

        let proxy = try XCTUnwrap(connection.remoteObjectProxy as? DorydControl)

        let start = expectation(description: "engineStart reply")
        var startOK = false
        var startMessage = ""
        proxy.engineStart { ok, message in
            startOK = ok
            startMessage = message
            start.fulfill()
        }
        wait(for: [start], timeout: 5)
        XCTAssertTrue(startOK, startMessage)
        XCTAssertEqual(idlePolicyStore.currentEngineDesiredState(), "running")

        let status = expectation(description: "engineStatus reply")
        var state = ""
        proxy.engineStatus { value, _ in
            state = value
            status.fulfill()
        }
        wait(for: [status], timeout: 5)
        XCTAssertEqual(state, "running")

        let stop = expectation(description: "engineStop reply")
        var stopOK = false
        proxy.engineStop { ok, _ in
            stopOK = ok
            stop.fulfill()
        }
        wait(for: [stop], timeout: 5)
        XCTAssertTrue(stopOK)
        XCTAssertEqual(tier.status().state, .stopped)
        XCTAssertEqual(idlePolicyStore.currentEngineDesiredState(), "sleeping")

        let wake = expectation(description: "engineWake after stop reply")
        var wakeOK = false
        var wakeMessage = ""
        proxy.engineWake { ok, message in
            wakeOK = ok
            wakeMessage = message
            wake.fulfill()
        }
        wait(for: [wake], timeout: 5)
        XCTAssertTrue(wakeOK, wakeMessage)
        XCTAssertEqual(tier.status().state, .running)
        XCTAssertEqual(idlePolicyStore.currentEngineDesiredState(), "running")
    }

    func testKeepAwakeModePromotesSleepingEngineBeforeReportingApplied() throws {
        let home = "/tmp/doryd-mode-promote-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        defer { try? FileManager.default.removeItem(atPath: home) }
        let store = IdlePolicyStore(home: home, environment: [:])
        _ = try store.setRuntimeMode("auto-idle")
        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: home,
                forwardSocketPath: home + "/forward.sock",
                activitySocketPath: home + "/activity.sock",
                hvProcess: HvProcessConfiguration(executablePath: "/bin/sleep", arguments: ["30"])
            ),
            idleController: IdleController(),
            dockerReadyWaiter: { _, _, _ in true }
        )
        try tier.armSleeping()
        defer { tier.stop() }
        let service = DorydService(
            socketPath: tier.socketPath,
            dockerTier: tier,
            idlePolicyStore: store
        )

        var applied = false
        var returnedMode = ""
        service.idleSetMode("manual") { ok, status, message in
            applied = ok
            returnedMode = status["mode"] as? String ?? ""
            XCTAssertEqual(message, "")
        }

        XCTAssertTrue(applied)
        XCTAssertEqual(returnedMode, "manual")
        XCTAssertEqual(store.currentRuntimeMode(), "manual")
        XCTAssertEqual(tier.status().state, .running)
    }

    func testKeepAwakeModeRollsBackWhenEngineCannotStart() throws {
        let home = "/tmp/doryd-mode-rollback-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        defer { try? FileManager.default.removeItem(atPath: home) }
        let store = IdlePolicyStore(home: home, environment: [:])
        _ = try store.setRuntimeMode("auto-idle")
        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: home,
                forwardSocketPath: home + "/forward.sock",
                activitySocketPath: home + "/activity.sock",
                hvProcess: HvProcessConfiguration(executablePath: home + "/missing-dory-hv")
            ),
            idleController: IdleController(),
            dockerReadyWaiter: { _, _, _ in false }
        )
        try tier.armSleeping()
        defer { tier.stop() }
        let service = DorydService(
            socketPath: tier.socketPath,
            dockerTier: tier,
            idlePolicyStore: store
        )

        var applied = true
        var returnedMode = ""
        var failure = ""
        service.idleSetMode("always-on") { ok, status, message in
            applied = ok
            returnedMode = status["mode"] as? String ?? ""
            failure = message
        }

        XCTAssertFalse(applied)
        XCTAssertEqual(returnedMode, "auto-idle")
        XCTAssertEqual(store.currentRuntimeMode(), "auto-idle")
        XCTAssertTrue(failure.contains("missing"), failure)
    }

    func testEngineSleepOverXPCStopsEmptyHelperAndIsIdempotent() throws {
        let home = "/tmp/doryd-service-sleep-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        defer { try? FileManager.default.removeItem(atPath: home) }
        let idle = IdleController(now: Date(timeIntervalSince1970: 0))
        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: home,
                forwardSocketPath: home + "/forward.sock",
                activitySocketPath: home + "/activity.sock",
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
        XCTAssertEqual(tier.status().state, .running)
        XCTAssertNotNil(tier.status().hvPID)

        let service = DorydService(socketPath: tier.socketPath, dockerTier: tier)
        let listener = makeAnonymousListener(service: service)
        listener.resume()
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: DorydControl.self)
        connection.resume()
        defer { connection.invalidate() }

        let proxy = try XCTUnwrap(connection.remoteObjectProxy as? DorydControl)

        let sleep = expectation(description: "engineSleep reply")
        var sleepOK = false
        var sleepMessage = ""
        proxy.engineSleep { ok, message in
            sleepOK = ok
            sleepMessage = message
            sleep.fulfill()
        }
        wait(for: [sleep], timeout: 5)
        XCTAssertTrue(sleepOK, sleepMessage)
        XCTAssertEqual(sleepMessage, "")
        XCTAssertEqual(tier.status().state, .sleeping)
        XCTAssertNil(tier.status().hvPID)
        XCTAssertTrue(idle.snapshot.sleeping)

        let secondSleep = expectation(description: "second engineSleep reply")
        var secondOK = false
        var secondMessage = ""
        proxy.engineSleep { ok, message in
            secondOK = ok
            secondMessage = message
            secondSleep.fulfill()
        }
        wait(for: [secondSleep], timeout: 5)
        XCTAssertTrue(secondOK, secondMessage)
        XCTAssertEqual(secondMessage, "docker tier is already sleeping")
        XCTAssertEqual(tier.status().state, .sleeping)
    }

    func testDockerAgentInfoPortsAndTelemetryOverXPC() throws {
        let home = "/tmp/doryd-service-agent-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        defer { try? FileManager.default.removeItem(atPath: home) }
        let agent = AgentControl(configuration: AgentControlConfiguration(forwardSocketPath: home + "/agent.sock")) { _ in
            ServiceFakeAgentControlClient()
        }
        let tier = DockerTier(
            configuration: DockerTierConfiguration(home: home, forwardSocketPath: home + "/forward.sock"),
            agentControl: agent
        )
        try tier.start()
        defer { tier.stop() }

        let service = DorydService(socketPath: tier.socketPath, dockerTier: tier)
        let listener = makeAnonymousListener(service: service)
        listener.resume()
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: DorydControl.self)
        connection.resume()
        defer { connection.invalidate() }

        let proxy = try XCTUnwrap(connection.remoteObjectProxy as? DorydControl)

        let infoReply = expectation(description: "dockerAgentInfo reply")
        proxy.dockerAgentInfo { body, message in
            XCTAssertEqual(message, "")
            XCTAssertEqual(body["agentBuild"] as? String, "docker-agent")
            XCTAssertEqual(body["protocolVersion"] as? UInt32, 1)
            XCTAssertEqual(
                (body["capabilities"] as? [NSDictionary])?.compactMap { $0["id"] as? String },
                ["clock-sync", "exec", "exec-stdin", "ports-watch", "telemetry"]
            )
            infoReply.fulfill()
        }
        wait(for: [infoReply], timeout: 5)

        let portsReply = expectation(description: "dockerAgentPorts reply")
        proxy.dockerAgentPorts { body, message in
            XCTAssertEqual(message, "")
            let ports = body["ports"] as? [NSDictionary]
            let added = body["added"] as? [NSDictionary]
            XCTAssertEqual(ports?.first?["protocol"] as? String, "tcp")
            XCTAssertEqual(ports?.first?["port"] as? UInt32, 8080)
            XCTAssertEqual(added?.first?["port"] as? UInt32, 8080)
            portsReply.fulfill()
        }
        wait(for: [portsReply], timeout: 5)

        let telemetryReply = expectation(description: "dockerAgentTelemetry reply")
        proxy.dockerAgentTelemetry { body, message in
            XCTAssertEqual(message, "")
            XCTAssertEqual(body["memTotalKB"] as? UInt64, 2048)
            XCTAssertEqual(body["memAvailableKB"] as? UInt64, 1024)
            telemetryReply.fulfill()
        }
        wait(for: [telemetryReply], timeout: 5)

        let clockReply = expectation(description: "dockerAgentClockSync reply")
        proxy.dockerAgentClockSync { body, message in
            XCTAssertEqual(message, "")
            XCTAssertEqual(body["name"] as? String, "docker")
            XCTAssertEqual(body["attempted"] as? Bool, true)
            XCTAssertEqual(body["synced"] as? Bool, true)
            XCTAssertEqual(body["error"] as? String, "")
            clockReply.fulfill()
        }
        wait(for: [clockReply], timeout: 5)

        tier.stop()
        let stoppedClockReply = expectation(description: "stopped dockerAgentClockSync reply")
        proxy.dockerAgentClockSync { body, message in
            XCTAssertEqual(body["attempted"] as? Bool, false)
            XCTAssertEqual(body["synced"] as? Bool, false)
            XCTAssertTrue(message.contains("not available"), message)
            stoppedClockReply.fulfill()
        }
        wait(for: [stoppedClockReply], timeout: 5)
    }

    func testRemoteConnectPushAndStatusOverXPC() throws {
        let fake = ServiceFakeRemoteAgentClient()
        let captured = ServiceLockedRemoteConfig()
        let manager = RemoteMachineManager(keyStore: ServiceFakeSSHKeyStore(keys: ["primary": "PRIVATE"])) { config in
            captured.value = config
            return fake
        }
        let service = DorydService(
            socketPath: "/tmp/doryd-test.sock",
            remoteManager: manager
        )
        let listener = makeAnonymousListener(service: service)
        listener.resume()
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: DorydControl.self)
        connection.resume()
        defer { connection.invalidate() }

        let proxy = try XCTUnwrap(connection.remoteObjectProxy as? DorydControl)
        let connect = expectation(description: "remoteConnect reply")
        var connectOK = false
        var info: NSDictionary = [:]
        var connectMessage = ""
        proxy.remoteConnect([
            "id": "vps",
            "host": "vps.example.com",
            "port": 2222,
            "user": "dory",
            "privateKeyID": "primary",
            "hostKeyType": "pinned",
            "hostKey": "ssh-ed25519 AAAA fake",
            "endpointType": "unix",
            "endpointPath": "/run/dory/agent.sock",
            "remoteRoot": "/srv/app",
            "build": "doryd-xpc-test",
        ]) { ok, body, message in
            connectOK = ok
            info = body
            connectMessage = message
            connect.fulfill()
        }
        wait(for: [connect], timeout: 5)
        XCTAssertTrue(connectOK, connectMessage)
        XCTAssertEqual(info["agentBuild"] as? String, "remote-agent")
        XCTAssertEqual(
            (info["capabilities"] as? [NSDictionary])?.compactMap { $0["id"] as? String },
            ["exec", "sync-push", "telemetry"]
        )
        XCTAssertEqual(captured.value?.opensshPrivateKey, "PRIVATE")

        let push = expectation(description: "remotePush reply")
        var pushOK = false
        var stats: NSDictionary = [:]
        proxy.remotePush("vps", localRoot: "/tmp/local", remoteRoot: "") { ok, body, _ in
            pushOK = ok
            stats = body
            push.fulfill()
        }
        wait(for: [push], timeout: 5)
        XCTAssertTrue(pushOK)
        XCTAssertEqual(stats["filesSent"] as? UInt64, 1)
        XCTAssertEqual(fake.pushes, [ServiceFakeRemoteAgentClient.Push(localRoot: "/tmp/local", remoteRoot: "/srv/app")])

        _ = try manager.telemetry(id: "vps")
        let statusReply = expectation(description: "remoteStatus reply")
        var status: NSDictionary = [:]
        var statusMessage = ""
        proxy.remoteStatus("vps") { body, message in
            status = body
            statusMessage = message
            statusReply.fulfill()
        }
        wait(for: [statusReply], timeout: 5)
        XCTAssertEqual(statusMessage, "")
        XCTAssertEqual(status["state"] as? String, "connected")
        XCTAssertNotNil(status["telemetry"] as? NSDictionary)
    }

    func testHealthDoctorJSONAndIncidentsOverXPC() throws {
        let base = "/tmp/doryd-service-health-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let writer = IncidentWriter(path: base + "/incidents.jsonl")
        writer.record(type: "test", detail: "seed", at: Date(timeIntervalSince1970: 1))
        let healthReporter = HealthReporter(
            socketPath: base + "/missing.sock",
            dockerTier: nil,
            remoteManager: nil,
            dockerAPIProbe: ServiceFakeDockerAPIProbe(result: .unreachable("missing")),
            commandRunner: ServiceFakeHealthCommandRunner(),
            registryProbe: ServiceFakeHealthRegistryProbe(),
            environment: ["PATH": base + "/bin", "DORY_CONFIG": base + "/config.json"],
            home: base
        )
        let service = DorydService(
            socketPath: base + "/missing.sock",
            healthReporter: healthReporter,
            incidentWriter: writer
        )
        let listener = makeAnonymousListener(service: service)
        listener.resume()
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: DorydControl.self)
        connection.resume()
        defer { connection.invalidate() }

        let proxy = try XCTUnwrap(connection.remoteObjectProxy as? DorydControl)
        let healthReply = expectation(description: "health reply")
        var health: NSDictionary = [:]
        proxy.health { body, message in
            XCTAssertEqual(message, "")
            health = body
            healthReply.fulfill()
        }
        wait(for: [healthReply], timeout: 5)
        let results = try XCTUnwrap(health["results"] as? [NSDictionary])
        XCTAssertTrue(results.contains { $0["code"] as? String == "socket.missing" })

        let jsonReply = expectation(description: "doctorJSON reply")
        var json = ""
        proxy.doctorJSON { body, message in
            XCTAssertEqual(message, "")
            json = body
            jsonReply.fulfill()
        }
        wait(for: [jsonReply], timeout: 5)
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        XCTAssertNotNil(decoded?["generated_at"] as? String)
        let doctorResults = try XCTUnwrap(decoded?["results"] as? [[String: Any]])
        XCTAssertTrue(doctorResults.contains { $0["code"] as? String == "socket.missing" })
        XCTAssertFalse(doctorResults.contains { $0["id"] as? String == "engine.status" })

        let incidentsReply = expectation(description: "incidents reply")
        var incidents: NSArray = []
        proxy.incidents(10) { body, message in
            XCTAssertEqual(message, "")
            incidents = body
            incidentsReply.fulfill()
        }
        wait(for: [incidentsReply], timeout: 5)
        let first = try XCTUnwrap(incidents.firstObject as? NSDictionary)
        XCTAssertEqual(first["type"] as? String, "test")
        XCTAssertEqual(first["detail"] as? String, "seed")
    }

    func testBalloonStatusOverXPCReportsHostAndRemoteTelemetryPlan() throws {
        let fake = ServiceFakeRemoteAgentClient()
        let manager = RemoteMachineManager(keyStore: ServiceFakeSSHKeyStore(keys: ["primary": "PRIVATE"])) { _ in
            fake
        }
        _ = try manager.connect(RemoteMachineConfiguration(
            id: "vps",
            host: "vps.example.com",
            user: "dory",
            privateKeyID: "primary",
            hostKey: .pinned(opensshPublicKey: "ssh-ed25519 AAAA fake"),
            endpoint: .unixSocket(path: "/run/dory/agent.sock"),
            remoteRoot: "/srv/app"
        ))
        _ = try manager.telemetry(id: "vps")

        let service = DorydService(
            socketPath: "/tmp/doryd-test.sock",
            remoteManager: manager,
            balloonController: BalloonController(hostProbe: ServiceFixedHostMemoryProbe(snapshot: HostMemorySnapshot(
                totalBytes: 16 * 1024 * 1024 * 1024,
                availableBytes: 512 * 1024 * 1024,
                freeBytes: 256 * 1024 * 1024,
                pressure: .critical
            )))
        )
        let listener = makeAnonymousListener(service: service)
        listener.resume()
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: DorydControl.self)
        connection.resume()
        defer { connection.invalidate() }

        let proxy = try XCTUnwrap(connection.remoteObjectProxy as? DorydControl)
        let statusReply = expectation(description: "balloonStatus reply")
        var status: NSDictionary = [:]
        var message = ""
        proxy.balloonStatus { body, replyMessage in
            status = body
            message = replyMessage
            statusReply.fulfill()
        }
        wait(for: [statusReply], timeout: 5)

        XCTAssertEqual(message, "")
        let host = try XCTUnwrap(status["host"] as? NSDictionary)
        XCTAssertEqual(host["pressure"] as? String, "critical")
        let targets = try XCTUnwrap(status["targets"] as? [NSDictionary])
        let target = try XCTUnwrap(targets.first)
        XCTAssertEqual(target["id"] as? String, "remote.vps")
        XCTAssertEqual(target["kind"] as? String, "remote")
        XCTAssertEqual(target["canApply"] as? Bool, false)
        XCTAssertEqual(target["reason"] as? String, "notBalloonable")
    }

    func testBalloonStatusOverXPCIncludesRunningLocalMachines() throws {
        let base = "/tmp/doryd-service-balloon-machine-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let manager = MachineManager(
            configuration: MachineManagerConfiguration(
                vmmExecutablePath: "/bin/sleep",
                stateDirectory: base,
                baseArguments: ["30"],
                passMachineArguments: false,
                requiresReadyHandoff: true
            ),
            agentConnector: { _ in ServiceFakeAgentControlClient() }
        )
        defer {
            try? manager.delete(id: "dev")
            try? FileManager.default.removeItem(atPath: base)
        }
        _ = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath,
            memoryMB: 2048,
            cpuCount: 2
        ))
        let starting = try manager.start(id: "dev")
        try sendVmmHandoff(
            path: try XCTUnwrap(starting.handoffSocketPath),
            ready: VmmReadyMessage(
                machineID: "dev",
                agentBuild: "dory-agent/test",
                agentProtocolVersion: DoryCore.protocolVersion(),
                agentCapabilities: [
                    DoryAgentCapability(id: "exec", version: 1),
                    DoryAgentCapability(id: "telemetry", version: 1),
                ],
                agentSocketPath: "/run/agent.sock",
                dockerdSocketPath: "/run/docker.sock",
                controlSocketPath: "/run/control.sock"
            ),
            fileDescriptors: []
        )
        _ = try waitForServiceMachineState(manager, id: "dev", state: .running)

        let service = DorydService(
            socketPath: "/tmp/doryd-test.sock",
            machineManager: manager,
            balloonController: BalloonController(hostProbe: ServiceFixedHostMemoryProbe(snapshot: HostMemorySnapshot(
                totalBytes: 16 * 1024 * 1024 * 1024,
                availableBytes: 512 * 1024 * 1024,
                freeBytes: 256 * 1024 * 1024,
                pressure: .critical
            )))
        )
        let machineStatus = expectation(description: "versioned machine tools status")
        service.machineList { rows, message in
            XCTAssertEqual(message, "")
            let status = (rows as? [NSDictionary])?.first
            XCTAssertEqual(
                (status?["agentProtocolVersion"] as? NSNumber)?.uint32Value,
                DoryCore.protocolVersion()
            )
            let capabilities = status?["agentCapabilities"] as? [NSDictionary]
            XCTAssertEqual(capabilities?.first?["id"] as? String, "exec")
            XCTAssertEqual((capabilities?.first?["version"] as? NSNumber)?.uint32Value, 1)
            machineStatus.fulfill()
        }
        wait(for: [machineStatus], timeout: 5)
        let listener = makeAnonymousListener(service: service)
        listener.resume()
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: DorydControl.self)
        connection.resume()
        defer { connection.invalidate() }

        let proxy = try XCTUnwrap(connection.remoteObjectProxy as? DorydControl)
        let statusReply = expectation(description: "balloonStatus reply")
        var targets: [NSDictionary] = []
        proxy.balloonStatus { body, message in
            XCTAssertEqual(message, "")
            targets = body["targets"] as? [NSDictionary] ?? []
            statusReply.fulfill()
        }
        wait(for: [statusReply], timeout: 5)

        let target = try XCTUnwrap(targets.first { $0["id"] as? String == "machine.dev" })
        XCTAssertEqual(target["kind"] as? String, "virtualMachine")
        XCTAssertEqual((target["currentTargetMB"] as? NSNumber)?.uint64Value, 2048)
        XCTAssertEqual(target["canApply"] as? Bool, true)
    }

    func testBalloonReconcileOverXPCAppliesRunningLocalMachineTargets() throws {
        let base = "/tmp/doryd-service-balloon-reconcile-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let balloon = ServiceRecordingMachineBalloonController()
        let manager = MachineManager(
            configuration: MachineManagerConfiguration(
                vmmExecutablePath: "/bin/sleep",
                stateDirectory: base,
                baseArguments: ["30"],
                passMachineArguments: false,
                requiresReadyHandoff: true
            ),
            balloonController: balloon,
            agentConnector: { _ in ServiceFakeAgentControlClient() }
        )
        defer {
            try? manager.delete(id: "dev")
            try? FileManager.default.removeItem(atPath: base)
        }
        _ = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath,
            memoryMB: 2048,
            cpuCount: 2
        ))
        let starting = try manager.start(id: "dev")
        try sendVmmHandoff(
            path: try XCTUnwrap(starting.handoffSocketPath),
            ready: VmmReadyMessage(
                machineID: "dev",
                agentBuild: "dory-agent/test",
                agentProtocolVersion: DoryCore.protocolVersion(),
                agentCapabilities: [
                    DoryAgentCapability(id: "exec", version: 1),
                    DoryAgentCapability(id: "telemetry", version: 1),
                ],
                agentSocketPath: "/run/agent.sock",
                dockerdSocketPath: "/run/docker.sock",
                controlSocketPath: "/run/control.sock"
            ),
            fileDescriptors: []
        )
        _ = try waitForServiceMachineState(manager, id: "dev", state: .running)

        let service = DorydService(
            socketPath: "/tmp/doryd-test.sock",
            machineManager: manager,
            balloonController: BalloonController(hostProbe: ServiceFixedHostMemoryProbe(snapshot: HostMemorySnapshot(
                totalBytes: 16 * 1024 * 1024 * 1024,
                availableBytes: 512 * 1024 * 1024,
                freeBytes: 256 * 1024 * 1024,
                pressure: .critical
            )), actuator: DorydServiceTestBalloonActuator(manager: manager))
        )
        let listener = makeAnonymousListener(service: service)
        listener.resume()
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: DorydControl.self)
        connection.resume()
        defer { connection.invalidate() }

        let proxy = try XCTUnwrap(connection.remoteObjectProxy as? DorydControl)
        let reconcileReply = expectation(description: "balloonReconcile reply")
        var plan: NSDictionary = [:]
        proxy.balloonReconcile { body, message in
            XCTAssertEqual(message, "")
            plan = body
            reconcileReply.fulfill()
        }
        wait(for: [reconcileReply], timeout: 5)

        XCTAssertEqual(balloon.applied, [
            ServiceRecordingMachineBalloonController.Apply(socketPath: "/run/control.sock", targetMB: 1536),
        ])
        let targets = try XCTUnwrap(plan["targets"] as? [NSDictionary])
        let target = try XCTUnwrap(targets.first { $0["id"] as? String == "machine.dev" })
        XCTAssertEqual((target["targetMB"] as? NSNumber)?.uint64Value, 1536)
        XCTAssertEqual(manager.memorySnapshots().first?.currentTargetMB, 1536)
    }

    func testNetworkRoutesAndStatusOverXPC() throws {
        let networking = NetworkingController(configuration: NetworkingConfiguration(
            dnsPort: 0,
            httpProxyPort: 0,
            privilegedTCPForwards: [PrivilegedTCPForward(listenPort: 25, targetPort: 1025)]
        ))
        try networking.start()
        defer { networking.stop() }
        let home = "/tmp/doryd-service-network-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        defer { try? FileManager.default.removeItem(atPath: home) }
        let agent = AgentControl(configuration: AgentControlConfiguration(forwardSocketPath: home + "/agent.sock")) { _ in
            ServiceFakeAgentControlClient(ports: [
                DoryListenPort(protocol: "tcp", port: 25),
                DoryListenPort(protocol: "tcp", port: 80),
                DoryListenPort(protocol: "udp", port: 53),
                DoryListenPort(protocol: "tcp", port: 8080),
            ])
        }
        let tier = DockerTier(
            configuration: DockerTierConfiguration(home: home, forwardSocketPath: home + "/forward.sock"),
            agentControl: agent
        )
        try tier.start()
        defer { tier.stop() }
        let routeRepair = ServiceRepairCounter()
        let service = DorydService(
            socketPath: "/tmp/doryd-test.sock",
            dockerTier: tier,
            networkingController: networking,
            networkRouteRepair: {
                routeRepair.increment()
                return 1
            }
        )
        let listener = makeAnonymousListener(service: service)
        listener.resume()
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: DorydControl.self)
        connection.resume()
        defer { connection.invalidate() }

        let proxy = try XCTUnwrap(connection.remoteObjectProxy as? DorydControl)
        let replace = expectation(description: "networkReplaceRoutes reply")
        var replaceOK = false
        proxy.networkReplaceRoutes([
            ["hostname": "web.dory.local", "address": "127.0.0.42", "port": 8080],
        ]) { ok, message in
            XCTAssertEqual(message, "")
            replaceOK = ok
            replace.fulfill()
        }
        wait(for: [replace], timeout: 5)
        XCTAssertTrue(replaceOK)

        let statusReply = expectation(description: "networkStatus reply")
        var status: NSDictionary = [:]
        proxy.networkStatus { body, message in
            XCTAssertEqual(message, "")
            status = body
            statusReply.fulfill()
        }
        wait(for: [statusReply], timeout: 5)

        XCTAssertEqual(status["mode"] as? String, "high-port-dns-http-proxy")
        XCTAssertEqual(status["dnsRunning"] as? Bool, true)
        XCTAssertEqual(status["httpProxyRunning"] as? Bool, true)
        XCTAssertEqual(status["httpsProxyPort"] as? UInt16, 8443)
        XCTAssertEqual(status["httpsProxyRunning"] as? Bool, false)
        let routes = try XCTUnwrap(status["routes"] as? [NSDictionary])
        XCTAssertEqual(routes.first?["hostname"] as? String, "web.dory.local")
        XCTAssertEqual(routes.first?["address"] as? String, "127.0.0.42")
        XCTAssertEqual(routes.first?["port"] as? UInt16, 8080)

        let authorizationReply = expectation(description: "networkAuthorizationPlan reply")
        var authorization: NSDictionary = [:]
        proxy.networkAuthorizationPlan { body, message in
            XCTAssertEqual(message, "")
            authorization = body
            authorizationReply.fulfill()
        }
        wait(for: [authorizationReply], timeout: 5)

        XCTAssertEqual(authorization["degradedMode"] as? String, "high-port-dns-only")
        XCTAssertEqual(authorization["authorizedMode"] as? String, "system-resolver-proxy-tls")
        XCTAssertEqual(authorization["suffix"] as? String, "dory.local")
        let forwards = try XCTUnwrap(authorization["privilegedTCPForwards"] as? [NSDictionary])
        XCTAssertEqual(forwards.first?["listenPort"] as? UInt16, 25)
        XCTAssertEqual(forwards.first?["targetPort"] as? UInt16, 60_025)
        XCTAssertFalse(forwards.contains { $0["listenPort"] as? UInt16 == 80 })
        XCTAssertFalse(forwards.contains { $0["listenPort"] as? UInt16 == 53 })
        let requests = try XCTUnwrap(authorization["requests"] as? [NSDictionary])
        XCTAssertTrue(requests.contains { $0["kind"] as? String == "resolverFile" })
        XCTAssertTrue(requests.contains { $0["kind"] as? String == "pfAnchor" })

        for target in ["dns", "domains", "routes", "guest-agent"] {
            let repairReply = expectation(description: "repair \(target) reply")
            proxy.repairSubsystem(target) { ok, message in
                XCTAssertTrue(ok, message)
                XCTAssertFalse(message.isEmpty)
                repairReply.fulfill()
            }
            wait(for: [repairReply], timeout: 5)
        }
        XCTAssertEqual(routeRepair.value, 3)

        let unavailableDockerReply = expectation(description: "unavailable Docker API repair reply")
        proxy.repairSubsystem("dockerd") { ok, message in
            XCTAssertFalse(ok)
            XCTAssertTrue(message.contains("VM helper is not running"), message)
            unavailableDockerReply.fulfill()
        }
        wait(for: [unavailableDockerReply], timeout: 5)

        let repairedStatusReply = expectation(description: "repaired network status reply")
        proxy.networkStatus { body, message in
            XCTAssertEqual(message, "")
            XCTAssertEqual(body["dnsRunning"] as? Bool, true)
            XCTAssertEqual(body["httpProxyRunning"] as? Bool, true)
            repairedStatusReply.fulfill()
        }
        wait(for: [repairedStatusReply], timeout: 5)

        let invalidRepairReply = expectation(description: "invalid repair reply")
        proxy.repairSubsystem("erase-everything") { ok, message in
            XCTAssertFalse(ok)
            XCTAssertTrue(message.contains("unsupported repair target"))
            invalidRepairReply.fulfill()
        }
        wait(for: [invalidRepairReply], timeout: 5)
    }

    func testCustomDomainRoutesPersistAndReconcileAsPublishedPorts() throws {
        let home = NSTemporaryDirectory() + "doryd-custom-route-service-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: home) }
        let routeStore = CustomDomainRouteStore(environment: [
            "DORY_CUSTOM_DOMAIN_ROUTES": home + "/custom-domains.json",
        ])
        let networking = NetworkingController(configuration: NetworkingConfiguration(
            suffix: "dory.local",
            dnsPort: 0,
            httpProxyPort: 0,
            httpsProxyPort: 0
        ))
        try networking.start()
        defer { networking.stop() }
        let service = DorydService(
            socketPath: "/tmp/doryd-custom-route-test.sock",
            networkingController: networking,
            networkRouteRepair: {
                let routes = (try? routeStore.configuredRoutes())?.map {
                    DomainRoute(
                        hostname: $0.hostname,
                        address: "127.0.0.1",
                        port: PrivilegedPortMapping.effectiveBackendPort(forPublishedPort: $0.publishedPort)
                    )
                } ?? []
                networking.replaceRoutes(routes)
                return routes.count
            },
            customDomainRouteStore: routeStore
        )
        let listener = makeAnonymousListener(service: service)
        listener.resume()
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: DorydControl.self)
        connection.resume()
        defer { connection.invalidate() }
        let proxy = try XCTUnwrap(connection.remoteObjectProxy as? DorydControl)

        let replace = expectation(description: "custom route saved")
        proxy.networkReplaceRoutes([
            ["hostname": "Admin.MyProject.Local.", "address": "127.0.0.1", "port": 80],
        ]) { ok, message in
            XCTAssertTrue(ok)
            XCTAssertEqual(message, "")
            replace.fulfill()
        }
        wait(for: [replace], timeout: 5)

        let statusReply = expectation(description: "custom route status")
        proxy.networkStatus { body, message in
            XCTAssertEqual(message, "")
            let configured = body["customRoutes"] as? [NSDictionary]
            XCTAssertEqual(configured?.first?["hostname"] as? String, "admin.myproject.local")
            XCTAssertEqual(configured?.first?["port"] as? UInt16, 80)
            let active = body["routes"] as? [NSDictionary]
            XCTAssertEqual(active?.first?["hostname"] as? String, "admin.myproject.local")
            XCTAssertEqual(active?.first?["port"] as? UInt16, 60_080)
            statusReply.fulfill()
        }
        wait(for: [statusReply], timeout: 5)
    }

    func testMachineLifecycleOverXPC() throws {
        let base = "/tmp/doryd-service-machine-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let share = "\(base)-share"
        try FileManager.default.createDirectory(atPath: share, withIntermediateDirectories: true)
        let manager = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: base,
            baseArguments: ["30"],
            passMachineArguments: false,
            requiresReadyHandoff: false
        ))
        defer {
            try? manager.delete(id: "dev")
            try? FileManager.default.removeItem(atPath: base)
            try? FileManager.default.removeItem(atPath: share)
        }
        let service = DorydService(
            socketPath: "/tmp/doryd-test.sock",
            machineManager: manager
        )
        let listener = makeAnonymousListener(service: service)
        listener.resume()
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: DorydControl.self)
        connection.resume()
        defer { connection.invalidate() }

        let proxy = try XCTUnwrap(connection.remoteObjectProxy as? DorydControl)
        let create = expectation(description: "machineCreate reply")
        proxy.machineCreate([
            "id": "dev",
            "kernelPath": doryTestKernelPath,
            "rootfsPath": doryTestRootfsPath,
            "memoryMB": 1024,
            "cpuCount": 2,
            "address": "192.168.215.40",
            "guestIdentityIntent": [
                "account": [
                    "username": "developer",
                    "numericUserID": UInt32(1_000),
                ] as NSDictionary,
            ] as NSDictionary,
            "clipboardPolicy": [
                "text": "off",
                "image": "off",
                "files": "off",
            ] as NSDictionary,
        ]) { ok, body, message in
            XCTAssertTrue(ok, message)
            XCTAssertEqual(body["state"] as? String, "created")
            XCTAssertEqual(body["address"] as? String, "192.168.215.40")
            XCTAssertNil(body["env"])
            let typed = body["typedSettings"] as? NSDictionary
            let identity = typed?["guestIdentityIntent"] as? NSDictionary
            let account = identity?["account"] as? NSDictionary
            XCTAssertEqual(account?["username"] as? String, "developer")
            XCTAssertEqual((account?["numericUserID"] as? NSNumber)?.uint32Value, 1_000)
            XCTAssertNil(typed?["clipboardPolicy"])
            create.fulfill()
        }
        wait(for: [create], timeout: 5)

        let start = expectation(description: "machineStart reply")
        proxy.machineStart("dev") { ok, body, message in
            XCTAssertTrue(ok, message)
            XCTAssertEqual(body["state"] as? String, "running")
            XCTAssertNotNil(body["pid"])
            let runtime = body["runtimeIdentity"] as? NSDictionary
            XCTAssertEqual(runtime?["mode"] as? String, "legacy-compatibility")
            XCTAssertEqual((runtime?["virtualHardwareABIVersion"] as? NSNumber)?.uint16Value, 1)
            XCTAssertNil(runtime?["resolvedPlan"])
            start.fulfill()
        }
        wait(for: [start], timeout: 5)

        let pause = expectation(description: "machinePause reply")
        proxy.machinePause("dev") { ok, body, message in
            XCTAssertTrue(ok, message)
            XCTAssertEqual(body["state"] as? String, "paused")
            XCTAssertNotNil(body["pid"])
            pause.fulfill()
        }
        wait(for: [pause], timeout: 5)

        let resume = expectation(description: "machineResume reply")
        proxy.machineResume("dev") { ok, body, message in
            XCTAssertTrue(ok, message)
            XCTAssertEqual(body["state"] as? String, "running")
            XCTAssertNotNil(body["pid"])
            resume.fulfill()
        }
        wait(for: [resume], timeout: 5)

        let restart = expectation(description: "machineRestart reply")
        proxy.machineRestart("dev") { ok, body, message in
            XCTAssertTrue(ok, message)
            XCTAssertEqual(body["state"] as? String, "running")
            XCTAssertNotNil(body["pid"])
            restart.fulfill()
        }
        wait(for: [restart], timeout: 5)

        let list = expectation(description: "machineList reply")
        proxy.machineList { body, message in
            XCTAssertEqual(message, "")
            let statuses = body as? [NSDictionary]
            XCTAssertEqual(statuses?.first?["id"] as? String, "dev")
            XCTAssertEqual(statuses?.first?["address"] as? String, "192.168.215.40")
            XCTAssertNil(statuses?.first?["env"])
            let typed = statuses?.first?["typedSettings"] as? NSDictionary
            let identity = typed?["guestIdentityIntent"] as? NSDictionary
            let account = identity?["account"] as? NSDictionary
            XCTAssertEqual(account?["username"] as? String, "developer")
            list.fulfill()
        }
        wait(for: [list], timeout: 5)

        let stop = expectation(description: "machineStop reply")
        proxy.machineStop("dev") { ok, body, message in
            XCTAssertTrue(ok, message)
            XCTAssertEqual(body["state"] as? String, "stopped")
            stop.fulfill()
        }
        wait(for: [stop], timeout: 5)

        let update = expectation(description: "machineUpdate reply")
        proxy.machineUpdate("dev", config: [
            "memoryMB": UInt64(4096),
            "cpuCount": 4,
            "address": "192.168.215.41",
            "shares": [
                [
                    "tag": "src",
                    "hostPath": share,
                    "guestPath": "/workspace/src",
                    "readOnly": true,
                ] as NSDictionary,
            ],
            "guestIdentityIntent": [
                "account": [
                    "username": "builder",
                ] as NSDictionary,
            ] as NSDictionary,
        ]) { ok, body, message in
            XCTAssertTrue(ok, message)
            XCTAssertEqual(body["state"] as? String, "stopped")
            XCTAssertEqual((body["memoryMB"] as? NSNumber)?.uint64Value, 4096)
            XCTAssertEqual((body["cpuCount"] as? NSNumber)?.intValue, 4)
            XCTAssertEqual(body["address"] as? String, "192.168.215.41")
            let shares = body["shares"] as? [NSDictionary]
            XCTAssertEqual(shares?.first?["hostPath"] as? String, share)
            XCTAssertEqual(shares?.first?["guestPath"] as? String, "/workspace/src")
            XCTAssertEqual(shares?.first?["readOnly"] as? Bool, true)
            XCTAssertNil(body["env"])
            let typed = body["typedSettings"] as? NSDictionary
            let identity = typed?["guestIdentityIntent"] as? NSDictionary
            let account = identity?["account"] as? NSDictionary
            XCTAssertEqual(account?["username"] as? String, "builder")
            XCTAssertEqual((account?["numericUserID"] as? NSNumber)?.uint32Value, 1_000)
            update.fulfill()
        }
        wait(for: [update], timeout: 5)

        let clearAddress = expectation(description: "machineUpdate clear address reply")
        proxy.machineUpdate("dev", config: [
            "address": "",
        ]) { ok, body, message in
            XCTAssertTrue(ok, message)
            XCTAssertNil(body["address"])
            clearAddress.fulfill()
        }
        wait(for: [clearAddress], timeout: 5)

        let delete = expectation(description: "machineDelete reply")
        proxy.machineDelete("dev") { ok, message in
            XCTAssertTrue(ok, message)
            XCTAssertEqual(message, "")
            delete.fulfill()
        }
        wait(for: [delete], timeout: 5)
    }

    func testMachineStatusAndSnapshotExposeOnlySafeTypedDesktopPayloadReceipt() throws {
        let base = "/tmp/doryd-service-desktop-receipt-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let manager = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: base,
            baseArguments: ["30"],
            passMachineArguments: false,
            requiresReadyHandoff: false
        ))
        defer {
            try? manager.delete(id: "dev")
            try? FileManager.default.removeItem(atPath: base)
        }
        let kernelData = try Data(contentsOf: URL(fileURLWithPath: doryTestKernelPath))
        let kernelSHA256 = SHA256.hash(data: kernelData)
            .map { String(format: "%02x", $0) }.joined()
        let receipt = DoryInstalledDesktopPayloadReceipt.verifiedUpdate(
            distributionIdentifier: "ubuntu",
            releaseVersion: "24.04+runtime.7",
            inputSHA256: String(repeating: "a", count: 64),
            bundleSHA256: String(repeating: "b", count: 64),
            distributionComponentIdentifier: "desktop-ubuntu",
            distributionInstallationName: "ubuntu-installation",
            distributionCatalogSHA256: String(repeating: "c", count: 64),
            bundleAssetIdentifier: "dory-desktop-ubuntu-update-arm64.tar",
            runtimeComponentIdentifier: "linux-desktop",
            runtimeInstallationName: "runtime-installation",
            runtimeCatalogSHA256: String(repeating: "d", count: 64),
            kernelAssetIdentifier: "dory-desktop-kernel-arm64.lzfse",
            kernelSHA256: kernelSHA256
        )
        _ = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath,
            displayMode: .desktop,
            environment: ["OPAQUE_SECRET": "must-not-enter-diagnostics"],
            installedDesktopPayloadReceipt: receipt
        ))
        let service = DorydService(socketPath: "/tmp/doryd-test.sock", machineManager: manager)
        let listener = makeAnonymousListener(service: service)
        listener.resume()
        defer { listener.invalidate() }
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: DorydControl.self)
        connection.resume()
        defer { connection.invalidate() }
        let proxy = try XCTUnwrap(connection.remoteObjectProxy as? DorydControl)

        let list = expectation(description: "typed desktop receipt list")
        proxy.machineList { rows, message in
            XCTAssertEqual(message, "")
            let body = (rows as? [NSDictionary])?.first
            let encoded = body?["installedDesktopPayloadReceipt"] as? NSDictionary
            XCTAssertEqual((encoded?["schemaVersion"] as? NSNumber)?.uint16Value, 1)
            XCTAssertEqual(encoded?["provenance"] as? String, "verified-update-bundle")
            XCTAssertEqual(encoded?["distributionIdentifier"] as? String, "ubuntu")
            XCTAssertEqual(encoded?["releaseVersion"] as? String, "24.04+runtime.7")
            XCTAssertEqual(encoded?["inputSHA256"] as? String, String(repeating: "a", count: 64))
            XCTAssertEqual(encoded?["bundleSHA256"] as? String, String(repeating: "b", count: 64))
            let safe = body.map(DoryMachineDiagnosticsProjection.supportSafeMachineStatus)
            XCTAssertNil(safe?["env"])
            XCTAssertNotNil(safe?["installedDesktopPayloadReceipt"])
            XCTAssertFalse(String(describing: safe).contains("must-not-enter-diagnostics"))
            list.fulfill()
        }
        wait(for: [list], timeout: 5)

        let snapshot = expectation(description: "typed desktop receipt snapshot")
        proxy.machineSnapshot("dev", request: ["snapshotID": "s1"]) { ok, body, message in
            XCTAssertTrue(ok, message)
            let encoded = body["installedDesktopPayloadReceipt"] as? NSDictionary
            XCTAssertEqual(encoded?["releaseVersion"] as? String, "24.04+runtime.7")
            XCTAssertEqual(encoded?["bundleSHA256"] as? String, String(repeating: "b", count: 64))
            snapshot.fulfill()
        }
        wait(for: [snapshot], timeout: 5)
    }

    func testDesktopUpdateRejectsCallerPathsAndRequiresStableComponentGenerations() throws {
        let base = "/tmp/doryd-service-desktop-authority-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let manager = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: base,
            baseArguments: ["30"],
            passMachineArguments: false,
            requiresReadyHandoff: false
        ))
        defer { try? FileManager.default.removeItem(atPath: base) }
        let service = DorydService(socketPath: "/tmp/doryd-test.sock", machineManager: manager)

        let oldPaths = expectation(description: "caller paths rejected")
        service.machineDesktopUpdate("dev", request: [
            "distro": "ubuntu",
            "version": "24.04+runtime.7",
            "bundlePath": "/tmp/caller-controlled.tar",
            "kernelPath": "/tmp/caller-controlled-kernel",
        ]) { ok, _, message in
            XCTAssertFalse(ok)
            XCTAssertTrue(message.contains("desktopUpdateAuthority"))
            oldPaths.fulfill()
        }
        wait(for: [oldPaths], timeout: 2)

        let mixed = expectation(description: "mixed authority rejected")
        service.machineDesktopUpdate("dev", request: [
            "distro": "ubuntu",
            "version": "24.04+runtime.7",
            "distributionInstallationName": "ubuntu-installation",
            "runtimeInstallationName": "runtime-installation",
            "bundlePath": "/tmp/caller-controlled.tar",
        ]) { ok, _, message in
            XCTAssertFalse(ok)
            XCTAssertTrue(message.contains("desktopUpdateAuthority"))
            mixed.fulfill()
        }
        wait(for: [mixed], timeout: 2)
    }

    func testMachineWritesRequireTypedIntentAndPreserveLegacyEnvironmentFieldLocally() throws {
        let base = "/tmp/doryd-service-typed-write-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let manager = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: base,
            baseArguments: ["30"],
            passMachineArguments: false,
            requiresReadyHandoff: false
        ))
        defer {
            try? manager.delete(id: "legacy")
            try? manager.delete(id: "typed")
            try? FileManager.default.removeItem(atPath: base)
        }
        _ = try manager.create(DoryMachineConfiguration(
            id: "legacy",
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath,
            displayMode: .desktop,
            environment: [
                "DORY_GUEST_USER": "../../unsafe-old-user",
                "DORY_GUEST_UID": "not-a-uid",
                "PRIVATE_TOKEN": "opaque-legacy-value",
            ]
        ))
        let service = DorydService(socketPath: "/tmp/doryd-test.sock", machineManager: manager)
        let listener = makeAnonymousListener(service: service)
        listener.resume()
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: DorydControl.self)
        connection.resume()
        defer { connection.invalidate() }
        let proxy = try XCTUnwrap(connection.remoteObjectProxy as? DorydControl)

        let rawCreate = expectation(description: "raw environment create rejected")
        proxy.machineCreate([
            "id": "typed",
            "kernelPath": doryTestKernelPath,
            "rootfsPath": doryTestRootfsPath,
            "env": [] as [NSDictionary],
        ]) { ok, _, message in
            XCTAssertFalse(ok)
            XCTAssertTrue(message.contains("raw machine environment input is not accepted"))
            rawCreate.fulfill()
        }
        wait(for: [rawCreate], timeout: 5)
        XCTAssertNil(manager.status(id: "typed"))

        let typedCreate = expectation(description: "typed intent create accepted")
        proxy.machineCreate([
            "id": "typed",
            "kernelPath": doryTestKernelPath,
            "rootfsPath": doryTestRootfsPath,
            "displayMode": "desktop",
            "guestIdentityIntent": [
                "account": [
                    "username": "developer",
                    "numericUserID": UInt32(1_000),
                ] as NSDictionary,
                "desktop": [
                    "distributionIdentifier": "ubuntu",
                    "displayName": "Ubuntu",
                    "version": "24.04",
                    "desktopEnvironment": "GNOME",
                ] as NSDictionary,
            ] as NSDictionary,
            "clipboardPolicy": [
                "text": "bidirectional",
                "image": "bidirectional",
                "files": "off",
            ] as NSDictionary,
            "desktopRuntimePreference": "accelerated",
            "desktopGraphicsPreference": "virgl-venus",
        ]) { ok, body, message in
            XCTAssertTrue(ok, message)
            XCTAssertNil(body["env"])
            let typed = body["typedSettings"] as? NSDictionary
            let identity = typed?["guestIdentityIntent"] as? NSDictionary
            let account = identity?["account"] as? NSDictionary
            let desktop = identity?["desktop"] as? NSDictionary
            XCTAssertEqual(account?["username"] as? String, "developer")
            XCTAssertEqual((account?["numericUserID"] as? NSNumber)?.uint32Value, 1_000)
            XCTAssertEqual(desktop?["distributionIdentifier"] as? String, "ubuntu")
            XCTAssertEqual(desktop?["displayName"] as? String, "Ubuntu")
            XCTAssertEqual(typed?["desktopRuntimePreference"] as? String, "accelerated")
            XCTAssertEqual(typed?["desktopGraphicsPreference"] as? String, "virgl-venus")
            typedCreate.fulfill()
        }
        wait(for: [typedCreate], timeout: 5)

        let typedUpdate = expectation(description: "typed update is field local")
        proxy.machineUpdate("legacy", config: [
            "guestIdentityIntent": [
                "desktop": [
                    "displayName": "Ubuntu Legacy",
                ] as NSDictionary,
            ] as NSDictionary,
            "desktopRuntimePreference": "compatible",
            "desktopGraphicsPreference": "software",
        ]) { ok, body, message in
            XCTAssertTrue(ok, message)
            XCTAssertNil(body["env"])
            XCTAssertFalse(body.description.contains("opaque-legacy-value"))
            let typed = body["typedSettings"] as? NSDictionary
            let identity = typed?["guestIdentityIntent"] as? NSDictionary
            let account = identity?["account"] as? NSDictionary
            let desktop = identity?["desktop"] as? NSDictionary
            XCTAssertNil(account?["username"])
            XCTAssertNil(account?["numericUserID"])
            XCTAssertEqual(desktop?["displayName"] as? String, "Ubuntu Legacy")
            XCTAssertEqual(typed?["desktopRuntimePreference"] as? String, "compatible")
            XCTAssertEqual(typed?["desktopGraphicsPreference"] as? String, "software")
            typedUpdate.fulfill()
        }
        wait(for: [typedUpdate], timeout: 5)

        let rawUpdate = expectation(description: "raw environment update rejected")
        proxy.machineUpdate("legacy", config: [
            "env": [["key": "PRIVATE_TOKEN", "value": "replacement"] as NSDictionary],
        ]) { ok, _, message in
            XCTAssertFalse(ok)
            XCTAssertTrue(message.contains("raw machine environment input is not accepted"))
            rawUpdate.fulfill()
        }
        wait(for: [rawUpdate], timeout: 5)
        XCTAssertEqual(manager.status(id: "legacy")?.environment["PRIVATE_TOKEN"], "opaque-legacy-value")
    }

    func testPerWorkspaceCreateInvokesProductionPlanningAndFailsClosed() throws {
        let base = "/tmp/doryd-service-production-plan-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let manager = MachineManager(
            configuration: MachineManagerConfiguration(
                vmmExecutablePath: "/bin/sleep",
                stateDirectory: base,
                baseArguments: ["30"],
                passMachineArguments: false,
                requiresReadyHandoff: false
            ),
            launchPolicy: .perWorkspaceAuthority
        )
        let controller = ServiceRejectingProductionPlanningController()
        let service = DorydService(
            socketPath: "/tmp/doryd-test.sock",
            machineManager: manager,
            productionPlanningController: controller
        )
        defer { try? FileManager.default.removeItem(atPath: base) }

        let reply = expectation(description: "production planning rejection")
        service.machineCreate([
            "id": "planned",
            "kernelPath": doryTestKernelPath,
            "rootfsPath": doryTestRootfsPath,
            "guestIdentityIntent": [
                "account": ["username": "developer"] as NSDictionary,
            ] as NSDictionary,
        ]) { ok, _, message in
            XCTAssertFalse(ok)
            XCTAssertTrue(message.contains("production planning failed closed"), message)
            reply.fulfill()
        }
        wait(for: [reply], timeout: 5)

        let captured = try XCTUnwrap(controller.captured)
        XCTAssertEqual(captured.request.planning.machine.id, "planned")
        XCTAssertEqual(captured.request.planning.machine.environment["DORY_GUEST_USER"], "developer")
        XCTAssertEqual(captured.request.planning.definition.identity.id, "planned")
        XCTAssertEqual(
            captured.request.planning.definition.guestIdentityIntent.account?.username,
            "developer"
        )
        XCTAssertEqual(captured.request.workspacePublication, .retainExistingExact)
        XCTAssertEqual(captured.artifacts.count, 2)
        XCTAssertTrue(captured.artifacts.allSatisfy { $0.path.hasPrefix(base + "/planned/") })
        XCTAssertEqual(manager.status(id: "planned")?.runtimeIdentity.mode, .requiresReplanning)
        XCTAssertEqual(
            manager.status(id: "planned")?.typedSettings?
                .guestIdentityIntent.account?.username,
            "developer"
        )
        XCTAssertTrue(manager.status(id: "planned")?.environment.isEmpty == true)
        let persisted = try JSONDecoder().decode(
            DoryMachineConfiguration.self,
            from: Data(contentsOf: URL(fileURLWithPath: base + "/planned/machine.json"))
        )
        XCTAssertTrue(persisted.environment.isEmpty)
        let listReply = expectation(description: "native typed status projection")
        service.machineList { rows, message in
            XCTAssertEqual(message, "")
            let row = (rows as? [NSDictionary])?.first { $0["id"] as? String == "planned" }
            XCTAssertNil(row?["env"])
            let typed = row?["typedSettings"] as? NSDictionary
            let identity = typed?["guestIdentityIntent"] as? NSDictionary
            let account = identity?["account"] as? NSDictionary
            XCTAssertEqual(account?["username"] as? String, "developer")
            listReply.fulfill()
        }
        wait(for: [listReply], timeout: 5)
        XCTAssertThrowsError(try manager.start(id: "planned"))

        let updateReply = expectation(description: "production update planning rejection")
        service.machineUpdate("planned", config: ["memoryMB": UInt64(4_096)]) {
            ok, _, message in
            XCTAssertFalse(ok)
            XCTAssertTrue(message.contains("production planning failed closed"), message)
            updateReply.fulfill()
        }
        wait(for: [updateReply], timeout: 5)
        XCTAssertEqual(controller.captures.count, 2)
        XCTAssertEqual(
            controller.captures.last?.request.planning.definition.resources.memoryBytes,
            UInt64(4_096 * 1_024 * 1_024)
        )
        XCTAssertEqual(manager.status(id: "planned")?.runtimeIdentity.mode, .requiresReplanning)
    }

    func testMachineExecOverXPCUsesMachineAgent() throws {
        let base = "/tmp/doryd-service-machine-exec-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let manager = MachineManager(
            configuration: MachineManagerConfiguration(
                vmmExecutablePath: "/bin/sleep",
                stateDirectory: base,
                baseArguments: ["30"],
                passMachineArguments: false,
                requiresReadyHandoff: true
            ),
            agentConnector: { _ in ServiceFakeAgentControlClient() }
        )
        defer {
            try? manager.delete(id: "dev")
            try? FileManager.default.removeItem(atPath: base)
        }
        let service = DorydService(socketPath: "/tmp/doryd-test.sock", machineManager: manager)
        let listener = makeAnonymousListener(service: service)
        listener.resume()
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: DorydControl.self)
        connection.resume()
        defer { connection.invalidate() }

        let proxy = try XCTUnwrap(connection.remoteObjectProxy as? DorydControl)
        let create = expectation(description: "machineCreate reply")
        proxy.machineCreate([
            "id": "dev",
            "kernelPath": doryTestKernelPath,
            "rootfsPath": doryTestRootfsPath,
        ]) { ok, _, message in
            XCTAssertTrue(ok, message)
            create.fulfill()
        }
        wait(for: [create], timeout: 5)

        let start = expectation(description: "machineStart reply")
        var handoffPath = ""
        proxy.machineStart("dev") { ok, body, message in
            XCTAssertTrue(ok, message)
            handoffPath = body["handoffSocketPath"] as? String ?? ""
            start.fulfill()
        }
        wait(for: [start], timeout: 5)
        try sendVmmHandoff(
            path: try XCTUnwrap(handoffPath.isEmpty ? nil : handoffPath),
            ready: VmmReadyMessage(
                machineID: "dev",
                agentBuild: "dory-agent/test",
                agentProtocolVersion: DoryCore.protocolVersion(),
                agentCapabilities: [DoryAgentCapability(id: "exec", version: 1)],
                agentSocketPath: "/run/agent.sock",
                dockerdSocketPath: "/run/docker.sock",
                shellSocketPath: "/run/shell.sock"
            ),
            fileDescriptors: []
        )
        _ = try waitForServiceMachineState(manager, id: "dev", state: .running)

        let exec = expectation(description: "machineExec reply")
        proxy.machineExec("dev", request: [
            "argv": ["/bin/sh", "-lc", "echo ok"],
            "cwd": "/tmp",
            "env": [["key": "A", "value": "B"] as NSDictionary],
            "timeoutMs": UInt64(1_000),
            "outputLimitBytes": UInt64(1024),
        ]) { ok, body, message in
            XCTAssertTrue(ok, message)
            XCTAssertEqual(body["exitCode"] as? Int32, 0)
            XCTAssertEqual(String(data: body["stdout"] as? Data ?? Data(), encoding: .utf8), "docker-exec-ok\n")
            XCTAssertEqual(body["timedOut"] as? Bool, false)
            exec.fulfill()
        }
        wait(for: [exec], timeout: 5)
    }

    func testMachineTransferOverXPCUsesExactShapeAndOmitsHostPath() throws {
        let suffix = "\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let base = "/tmp/doryd-service-machine-transfer-\(suffix)"
        let staging = "/tmp/doryd-service-machine-transfer-stage-\(suffix)"
        try FileManager.default.createDirectory(
            atPath: staging,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("payload".utf8).write(
            to: URL(fileURLWithPath: staging + "/payload.txt")
        )
        let manager = MachineManager(
            configuration: MachineManagerConfiguration(
                vmmExecutablePath: "/bin/sleep",
                stateDirectory: base,
                baseArguments: ["30"],
                passMachineArguments: false,
                requiresReadyHandoff: true
            ),
            agentConnector: { _ in ServiceFakeAgentControlClient() }
        )
        defer {
            try? manager.delete(id: "dev")
            try? FileManager.default.removeItem(atPath: base)
            try? FileManager.default.removeItem(atPath: staging)
        }
        let service = DorydService(socketPath: "/tmp/doryd-test.sock", machineManager: manager)
        let listener = makeAnonymousListener(service: service)
        listener.resume()
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: DorydControl.self)
        connection.resume()
        defer { connection.invalidate() }
        let proxy = try XCTUnwrap(connection.remoteObjectProxy as? DorydControl)

        let create = expectation(description: "machineCreate reply")
        proxy.machineCreate([
            "id": "dev",
            "kernelPath": doryTestKernelPath,
            "rootfsPath": doryTestRootfsPath,
            "displayMode": "desktop",
            "guestIdentityIntent": [
                "account": [
                    "username": "developer",
                    "numericUserID": UInt32(1_000),
                ] as NSDictionary,
            ] as NSDictionary,
        ]) { ok, _, message in
            XCTAssertTrue(ok, message)
            create.fulfill()
        }
        wait(for: [create], timeout: 5)

        let start = expectation(description: "machineStart reply")
        var handoffPath = ""
        proxy.machineStart("dev") { ok, body, message in
            XCTAssertTrue(ok, message)
            handoffPath = body["handoffSocketPath"] as? String ?? ""
            start.fulfill()
        }
        wait(for: [start], timeout: 5)
        try sendVmmHandoff(
            path: try XCTUnwrap(handoffPath.isEmpty ? nil : handoffPath),
            ready: VmmReadyMessage(
                machineID: "dev",
                agentBuild: "dory-agent/test",
                agentProtocolVersion: DoryCore.protocolVersion(),
                agentCapabilities: [
                    DoryAgentCapability(id: "exec", version: 1),
                    DoryAgentCapability(id: "sync-push", version: 1),
                ],
                agentSocketPath: "/run/agent.sock"
            ),
            fileDescriptors: []
        )
        _ = try waitForServiceMachineState(manager, id: "dev", state: .running)

        for malformed in [
            ["schema": UInt16(2), "privateStagingRoot": staging] as NSDictionary,
            [
                "schema": UInt16(1),
                "privateStagingRoot": staging,
                "unexpected": true,
            ] as NSDictionary,
        ] {
            let rejected = expectation(description: "malformed transfer rejected")
            proxy.machineTransfer("dev", request: malformed) { ok, body, message in
                XCTAssertFalse(ok)
                XCTAssertTrue(body.isEqual(to: [:]))
                XCTAssertTrue(message.contains("machineTransfer"), message)
                rejected.fulfill()
            }
            wait(for: [rejected], timeout: 5)
        }

        let transfer = expectation(description: "machineTransfer reply")
        proxy.machineTransfer("dev", request: [
            "schema": UInt16(1),
            "privateStagingRoot": staging,
        ]) { ok, body, message in
            XCTAssertTrue(ok, message)
            XCTAssertEqual(
                Set(body.allKeys.compactMap { $0 as? String }),
                ["schema", "transferID", "guestDestination", "filesSent", "bytesSent"]
            )
            XCTAssertEqual((body["schema"] as? NSNumber)?.uint16Value, 1)
            XCTAssertEqual(body["filesSent"] as? UInt64, 2)
            XCTAssertEqual(body["bytesSent"] as? UInt64, 7)
            XCTAssertTrue(
                (body["guestDestination"] as? String)?
                    .hasPrefix("/home/developer/Downloads/Dory Transfer ") == true
            )
            XCTAssertFalse(body.description.contains(staging))
            transfer.fulfill()
        }
        wait(for: [transfer], timeout: 5)

        let malformedStart = expectation(description: "malformed machineTransferStart rejected")
        proxy.machineTransferStart("dev", request: [
            "schema": UInt16(1),
            "privateStagingRoot": staging,
        ]) { ok, body, message in
            XCTAssertFalse(ok)
            XCTAssertTrue(body.isEqual(to: [:]))
            XCTAssertTrue(message.contains("machineTransfer"), message)
            malformedStart.fulfill()
        }
        wait(for: [malformedStart], timeout: 5)

        let asyncStart = expectation(description: "machineTransferStart reply")
        var operationID = ""
        proxy.machineTransferStart("dev", request: [
            "schema": UInt16(2),
            "privateStagingRoot": staging,
        ]) { ok, body, message in
            XCTAssertTrue(ok, message)
            operationID = body["operationID"] as? String ?? ""
            XCTAssertEqual(operationID.utf8.count, 32)
            XCTAssertEqual(body["machineID"] as? String, "dev")
            XCTAssertEqual((body["schema"] as? NSNumber)?.uint16Value, 1)
            XCTAssertFalse(body.description.contains(staging))
            asyncStart.fulfill()
        }
        wait(for: [asyncStart], timeout: 5)

        var terminalBody: NSDictionary?
        let deadline = Date().addingTimeInterval(5)
        while terminalBody == nil, Date() < deadline {
            let statusReply = expectation(description: "machineTransferStatus reply")
            proxy.machineTransferStatus("dev", operationID: operationID) { ok, body, message in
                XCTAssertTrue(ok, message)
                if let phase = body["phase"] as? String,
                   ["completed", "cancelled", "failed"].contains(phase) {
                    terminalBody = body
                }
                statusReply.fulfill()
            }
            wait(for: [statusReply], timeout: 5)
            if terminalBody == nil {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        let completedBody = try XCTUnwrap(terminalBody)
        XCTAssertEqual(completedBody["phase"] as? String, "completed")
        XCTAssertEqual(
            Set(completedBody.allKeys.compactMap { $0 as? String }),
            [
                "schema", "operationID", "machineID", "phase", "filesTotal",
                "filesCompleted", "bytesTotal", "bytesCompleted", "guestDestination",
                "result",
            ]
        )
        XCTAssertEqual(completedBody["filesTotal"] as? UInt64, 2)
        XCTAssertEqual(completedBody["filesCompleted"] as? UInt64, 2)
        XCTAssertEqual(completedBody["bytesTotal"] as? UInt64, 7)
        XCTAssertEqual(completedBody["bytesCompleted"] as? UInt64, 7)
        let asyncResult = try XCTUnwrap(completedBody["result"] as? NSDictionary)
        XCTAssertEqual(asyncResult["transferID"] as? String, operationID)
        XCTAssertEqual(asyncResult["filesSent"] as? UInt64, 2)
        XCTAssertEqual(asyncResult["bytesSent"] as? UInt64, 7)
        XCTAssertFalse(completedBody.description.contains(staging))

        let cancelCompleted = expectation(description: "machineTransferCancel terminal reply")
        proxy.machineTransferCancel("dev", operationID: operationID) { ok, body, message in
            XCTAssertTrue(ok, message)
            XCTAssertEqual(body["phase"] as? String, "completed")
            cancelCompleted.fulfill()
        }
        wait(for: [cancelCompleted], timeout: 5)

        let invalidStatus = expectation(description: "invalid transfer status rejected")
        proxy.machineTransferStatus("dev", operationID: "NOT-AN-OPERATION") { ok, body, message in
            XCTAssertFalse(ok)
            XCTAssertTrue(body.isEqual(to: [:]))
            XCTAssertEqual(message, "invalid machine transfer operation identifier")
            invalidStatus.fulfill()
        }
        wait(for: [invalidStatus], timeout: 5)
    }

    func testMachineProvisionOverXPCInstallsRecipeThroughMachineAgent() throws {
        let base = "/tmp/doryd-service-machine-provision-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let manager = MachineManager(
            configuration: MachineManagerConfiguration(
                vmmExecutablePath: "/bin/sleep",
                stateDirectory: base,
                baseArguments: ["30"],
                passMachineArguments: false,
                requiresReadyHandoff: true
            ),
            agentConnector: { _ in ServiceFakeAgentControlClient() }
        )
        defer {
            try? manager.delete(id: "dev")
            try? FileManager.default.removeItem(atPath: base)
        }
        let service = DorydService(socketPath: "/tmp/doryd-test.sock", machineManager: manager)
        let listener = makeAnonymousListener(service: service)
        listener.resume()
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: DorydControl.self)
        connection.resume()
        defer { connection.invalidate() }

        let proxy = try XCTUnwrap(connection.remoteObjectProxy as? DorydControl)
        let create = expectation(description: "machineCreate reply")
        proxy.machineCreate([
            "id": "dev",
            "kernelPath": doryTestKernelPath,
            "rootfsPath": doryTestRootfsPath,
        ]) { ok, _, message in
            XCTAssertTrue(ok, message)
            create.fulfill()
        }
        wait(for: [create], timeout: 5)

        let start = expectation(description: "machineStart reply")
        var handoffPath = ""
        proxy.machineStart("dev") { ok, body, message in
            XCTAssertTrue(ok, message)
            handoffPath = body["handoffSocketPath"] as? String ?? ""
            start.fulfill()
        }
        wait(for: [start], timeout: 5)
        try sendVmmHandoff(
            path: try XCTUnwrap(handoffPath.isEmpty ? nil : handoffPath),
            ready: VmmReadyMessage(
                machineID: "dev",
                agentBuild: "dory-agent/test",
                agentProtocolVersion: DoryCore.protocolVersion(),
                agentCapabilities: [DoryAgentCapability(id: "exec", version: 1)],
                agentSocketPath: "/run/agent.sock",
                dockerdSocketPath: "/run/docker.sock"
            ),
            fileDescriptors: []
        )
        _ = try waitForServiceMachineState(manager, id: "dev", state: .running)

        let provision = expectation(description: "machineProvision reply")
        proxy.machineProvision("dev", request: ["recipe": "rust"]) { ok, body, message in
            XCTAssertTrue(ok, message)
            XCTAssertEqual(body["recipe"] as? String, "rust")
            let install = body["install"] as? NSDictionary
            let verify = body["verify"] as? NSDictionary
            XCTAssertEqual(install?["exitCode"] as? Int32, 0)
            XCTAssertEqual(verify?["stdout"] as? String, "cargo 1.0\n")
            provision.fulfill()
        }
        wait(for: [provision], timeout: 5)
    }

    func testMachineSnapshotsOverXPCUseDiskBackedVMState() throws {
        let base = "/tmp/doryd-service-machine-snapshot-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let rootfs = "\(base)/rootfs.ext4"
        try Data("rootfs-v1".utf8).write(to: URL(fileURLWithPath: rootfs))
        let manager = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: "\(base)/machines",
            baseArguments: ["30"],
            passMachineArguments: false,
            requiresReadyHandoff: false
        ))
        defer {
            try? manager.delete(id: "dev")
            try? manager.delete(id: "dev-copy")
        }
        let service = DorydService(socketPath: "/tmp/doryd-test.sock", machineManager: manager)
        let listener = makeAnonymousListener(service: service)
        listener.resume()
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: DorydControl.self)
        connection.resume()
        defer { connection.invalidate() }

        let proxy = try XCTUnwrap(connection.remoteObjectProxy as? DorydControl)

        let create = expectation(description: "machineCreate reply")
        proxy.machineCreate([
            "id": "dev",
            "kernelPath": doryTestKernelPath,
            "rootfsPath": rootfs,
        ]) { ok, _, message in
            XCTAssertTrue(ok, message)
            create.fulfill()
        }
        wait(for: [create], timeout: 5)
        try Data("rootfs-snapshot".utf8).write(to: URL(fileURLWithPath: "\(base)/machines/dev/rootfs.ext4"))

        let snapshotReply = expectation(description: "machineSnapshot reply")
        proxy.machineSnapshot("dev", request: [
            "note": "before",
            "createdISO": "2026-07-07T00:00:00Z",
            "snapshotID": "s1",
        ]) { ok, body, message in
            XCTAssertTrue(ok, message)
            XCTAssertEqual(body["id"] as? String, "s1")
            XCTAssertEqual(body["machineID"] as? String, "dev")
            XCTAssertEqual(body["note"] as? String, "before")
            XCTAssertEqual(body["architecture"] as? String, doryTestGuestArchitecture)
            let runtime = body["runtimeIdentity"] as? NSDictionary
            XCTAssertEqual(runtime?["mode"] as? String, "legacy-compatibility")
            XCTAssertEqual((runtime?["virtualHardwareABIVersion"] as? NSNumber)?.uint16Value, 1)
            XCTAssertEqual(body["consistency"] as? String, "cold-stopped")
            XCTAssertNil(body["guestQuiesceReceipt"])
            let artifacts = body["artifactEvidence"] as? NSDictionary
            XCTAssertEqual(
                ((artifacts?["rootfs"] as? NSDictionary)?["sha256"] as? String)?.count,
                64
            )
            snapshotReply.fulfill()
        }
        wait(for: [snapshotReply], timeout: 5)

        let listReply = expectation(description: "machineSnapshots reply")
        proxy.machineSnapshots("dev") { rows, message in
            XCTAssertEqual(message, "")
            XCTAssertEqual((rows as? [NSDictionary])?.first?["id"] as? String, "s1")
            XCTAssertEqual(
                (rows as? [NSDictionary])?.first?["consistency"] as? String,
                "cold-stopped"
            )
            listReply.fulfill()
        }
        wait(for: [listReply], timeout: 5)

        let cloneReply = expectation(description: "machineCloneSnapshot reply")
        proxy.machineCloneSnapshot("dev", snapshotID: "s1", newID: "dev-copy") { ok, body, message in
            XCTAssertTrue(ok, message)
            XCTAssertEqual(body["id"] as? String, "dev-copy")
            XCTAssertEqual(body["state"] as? String, "running")
            cloneReply.fulfill()
        }
        wait(for: [cloneReply], timeout: 5)

        try Data("rootfs-mutated".utf8).write(to: URL(fileURLWithPath: "\(base)/machines/dev/rootfs.ext4"))
        let restoreReply = expectation(description: "machineRestoreSnapshot reply")
        proxy.machineRestoreSnapshot("dev", snapshotID: "s1") { ok, body, message in
            XCTAssertTrue(ok, message)
            XCTAssertEqual(body["id"] as? String, "dev")
            restoreReply.fulfill()
        }
        wait(for: [restoreReply], timeout: 5)
        XCTAssertEqual(
            String(data: try Data(contentsOf: URL(fileURLWithPath: "\(base)/machines/dev/rootfs.ext4")), encoding: .utf8),
            "rootfs-snapshot"
        )

        let bundle = "\(base)/dev.dorymachine"
        let exportReply = expectation(description: "machineExportSnapshot reply")
        proxy.machineExportSnapshot("dev", snapshotID: "s1", path: bundle) { ok, message in
            XCTAssertTrue(ok, message)
            exportReply.fulfill()
        }
        wait(for: [exportReply], timeout: 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle))

        let deleteReply = expectation(description: "machineDeleteSnapshot reply")
        proxy.machineDeleteSnapshot("dev", snapshotID: "s1") { ok, message in
            XCTAssertTrue(ok, message)
            deleteReply.fulfill()
        }
        wait(for: [deleteReply], timeout: 5)

        let importReply = expectation(description: "machineImportSnapshot reply")
        proxy.machineImportSnapshot(bundle) { ok, body, message in
            XCTAssertTrue(ok, message)
            XCTAssertEqual(body["id"] as? String, "s1")
            XCTAssertEqual(body["machineID"] as? String, "dev")
            importReply.fulfill()
        }
        wait(for: [importReply], timeout: 5)
    }
}

private func waitForServiceMachineState(
    _ manager: MachineManager,
    id: String,
    state: DoryMachineState,
    timeout: TimeInterval = 2
) throws -> DoryMachineStatus {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let status = manager.status(id: id), status.state == state {
            return status
        }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return try XCTUnwrap(manager.status(id: id))
}

private final class ServiceFakeSSHKeyStore: SSHKeyStore, @unchecked Sendable {
    private let keys: [String: String]

    init(keys: [String: String]) {
        self.keys = keys
    }

    func privateKey(for identifier: String) throws -> String {
        guard let key = keys[identifier] else {
            throw SSHKeyStoreError.notFound(identifier)
        }
        return key
    }
}

private struct ServiceFakeDockerAPIProbe: DockerAPIProbing {
    var result: DockerAPIPingResult

    func ping(socketPath: String) -> DockerAPIPingResult {
        result
    }

    func systemDF(socketPath: String) -> DockerAPISystemDFResult {
        .ok
    }
}

private final class ServiceFakeHealthCommandRunner: HealthCommandRunning, @unchecked Sendable {
    func run(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) -> HealthCommandOutput {
        HealthCommandOutput(exitCode: 1, stdout: "", stderr: "not configured")
    }
}

private struct ServiceFakeHealthRegistryProbe: HealthRegistryProbing {
    func checks(host: String, port: Int, name: String, defaultProbe: Bool) -> [HealthCheck] {
        [
            HealthCheck(
                id: "network.registry_dns",
                status: .pass,
                code: "network.registry_dns_ok",
                title: "Host resolves network probe",
                detail: "\(host):\(port)"
            ),
            HealthCheck(
                id: "network.registry_https",
                status: .pass,
                code: "network.registry_https_ok",
                title: "Network probe HTTPS path works",
                detail: "HTTP 401; auth challenge is expected for Docker Hub"
            ),
        ]
    }
}

private final class ServiceFakeAgentControlClient: AgentControlClient, @unchecked Sendable {
    private let watchedPorts: [DoryListenPort]

    init(ports: [DoryListenPort] = [DoryListenPort(protocol: "tcp", port: 8080)]) {
        self.watchedPorts = ports
    }

    func info() throws -> DoryAgentInfo {
        DoryAgentInfo(
            protocolVersion: DoryCore.protocolVersion(),
            kernel: "Linux docker",
            agentBuild: "docker-agent",
            uptimeSeconds: 9,
            capabilities: [
                DoryAgentCapability(id: "clock-sync", version: 1),
                DoryAgentCapability(id: "exec", version: 1),
                DoryAgentCapability(id: "exec-stdin", version: 1),
                DoryAgentCapability(id: "ports-watch", version: 1),
                DoryAgentCapability(id: "telemetry", version: 1),
            ]
        )
    }

    func clockSync(hostEpochNs: Int64) throws -> Bool {
        true
    }

    func portsWatch() throws -> DoryPortsSnapshot {
        DoryPortsSnapshot(
            ports: watchedPorts,
            added: [],
            removed: []
        )
    }

    func telemetry() throws -> DoryTelemetry {
        DoryTelemetry(
            memTotalKB: 2048,
            memAvailableKB: 1024,
            psiSomeAvg10: 0.1,
            psiFullAvg10: 0.0
        )
    }

    func push(localRoot: String, remoteRoot: String) throws -> DoryPushStats {
        _ = localRoot
        _ = remoteRoot
        return DoryPushStats(filesSent: 2, bytesSent: 7, filesDeleted: 0)
    }

    func push(
        localRoot: String,
        remoteRoot: String,
        control: DoryPushControl
    ) throws -> DoryPushStats {
        _ = control
        return try push(localRoot: localRoot, remoteRoot: remoteRoot)
    }

    func exec(
        argv: [String],
        cwd: String,
        env: [DoryExecEnvironment],
        timeoutMs: UInt64,
        outputLimitBytes: UInt64
    ) throws -> DoryExecResult {
        let command = argv.joined(separator: " ")
        let output: String
        if argv.prefix(2) == ["/usr/bin/id", "-u"]
            || argv.prefix(2) == ["/usr/bin/id", "-g"] {
            output = "1000\n"
        } else if command.contains("apk add --no-cache cargo rust") {
            output = "installed rust\n"
        } else if command.contains("cargo --version") {
            output = "cargo 1.0\n"
        } else {
            output = "docker-exec-ok\n"
        }
        return DoryExecResult(
            exitCode: 0,
            stdout: Data(output.utf8),
            stderr: Data(),
            timedOut: false,
            stdoutTruncated: false,
            stderrTruncated: false
        )
    }

    func close() {}
}

private final class ServiceFakeRemoteAgentClient: RemoteAgentClient, @unchecked Sendable {
    struct Push: Equatable {
        var localRoot: String
        var remoteRoot: String
    }

    private let lock = NSLock()
    private var storedPushes: [Push] = []

    var pushes: [Push] {
        lock.lock()
        defer { lock.unlock() }
        return storedPushes
    }

    func info() throws -> DoryAgentInfo {
        DoryAgentInfo(
            protocolVersion: DoryCore.protocolVersion(),
            kernel: "Linux remote",
            agentBuild: "remote-agent",
            uptimeSeconds: 7,
            capabilities: [
                DoryAgentCapability(id: "exec", version: 1),
                DoryAgentCapability(id: "sync-push", version: 1),
                DoryAgentCapability(id: "telemetry", version: 1),
            ]
        )
    }

    func telemetry() throws -> DoryTelemetry {
        DoryTelemetry(
            memTotalKB: 100,
            memAvailableKB: 50,
            psiSomeAvg10: 0,
            psiFullAvg10: 0
        )
    }

    func push(localRoot: String, remoteRoot: String) throws -> DoryPushStats {
        lock.lock()
        storedPushes.append(Push(localRoot: localRoot, remoteRoot: remoteRoot))
        lock.unlock()
        return DoryPushStats(filesSent: 1, bytesSent: 2, filesDeleted: 3)
    }

    func exec(
        argv: [String],
        cwd: String,
        env: [DoryExecEnvironment],
        timeoutMs: UInt64,
        outputLimitBytes: UInt64
    ) throws -> DoryExecResult {
        DoryExecResult(
            exitCode: 0,
            stdout: Data("remote-exec-ok\n".utf8),
            stderr: Data(),
            timedOut: false,
            stdoutTruncated: false,
            stderrTruncated: false
        )
    }

    func close() {}
}

private final class ServiceLockedRemoteConfig: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: DoryRemoteConfig?

    var value: DoryRemoteConfig? {
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
}

private final class ServiceFixedHostMemoryProbe: HostMemoryProbing, @unchecked Sendable {
    let snapshotValue: HostMemorySnapshot

    init(snapshot: HostMemorySnapshot) {
        self.snapshotValue = snapshot
    }

    func snapshot() throws -> HostMemorySnapshot {
        snapshotValue
    }
}

private final class DorydServiceTestBalloonActuator: BalloonActuator, @unchecked Sendable {
    private let manager: MachineManager

    init(manager: MachineManager) {
        self.manager = manager
    }

    func apply(targets: [BalloonTarget]) throws {
        try manager.applyBalloonTargets(targets)
    }
}

private final class ServiceRecordingMachineBalloonController: MachineBalloonControlling, @unchecked Sendable {
    struct Apply: Equatable {
        var socketPath: String
        var targetMB: UInt64
    }

    private let lock = NSLock()
    private var applies: [Apply] = []

    var applied: [Apply] {
        lock.lock()
        defer { lock.unlock() }
        return applies
    }

    func setBalloonTarget(socketPath: String, targetMB: UInt64) throws {
        lock.lock()
        applies.append(Apply(socketPath: socketPath, targetMB: targetMB))
        lock.unlock()
    }
}

private final class ServiceRepairCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private final class ServiceRejectingProductionPlanningController:
    DoryDaemonVirtualMachineProductionPlanningControlling, @unchecked Sendable
{
    struct Capture: Sendable {
        var request: DoryDaemonVirtualMachinePlanningTransactionRequest
        var artifacts: [DoryDaemonVirtualMachinePlanningArtifactPublication]
    }

    private let lock = NSLock()
    private var stored: [Capture] = []

    var captured: Capture? {
        lock.lock()
        defer { lock.unlock() }
        return stored.last
    }

    var captures: [Capture] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func authorityRevision(for reference: DoryVMResolverReference) throws -> UInt64? {
        _ = reference
        return nil
    }

    func publishResolvedPlan(
        _ request: DoryDaemonVirtualMachinePlanningTransactionRequest,
        artifacts: [DoryDaemonVirtualMachinePlanningArtifactPublication]
    ) throws {
        lock.lock()
        stored.append(Capture(request: request, artifacts: artifacts))
        lock.unlock()
        throw ServiceProductionPlanningTestError.rejected
    }
}

private enum ServiceProductionPlanningTestError: Error { case rejected }
