import DoryCore
@testable import DorydKit
import XCTest

final class DorydServiceTests: XCTestCase {
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
        try """
        {"at":"2026-07-07T00:00:00Z","state":"sleeping","detail":"idle"}
        """.write(
            to: doryDir.appendingPathComponent("idle-history.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let store = IdlePolicyStore(home: home.path, environment: [:], dockerContainers: {
            .ok([
                try! JSONDecoder().decode(DockerContainerSummary.self, from: Data(
                    """
                    {"Id":"abc123456789","Names":["/web"],"State":"running","Ports":[{"PrivatePort":80,"PublicPort":8080,"Type":"tcp"}],"Labels":{"io.dory.keep-awake":"true"}}
                    """.utf8
                ))
            ])
        })
        let service = DorydService(socketPath: "/tmp/doryd-test.sock", idlePolicyStore: store)
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
        XCTAssertEqual(status["auto_idle_enabled"] as? Bool, false)
        XCTAssertEqual(status["sleep_after_minutes"] as? Int, 15)
        XCTAssertEqual((status["blockers"] as? [NSDictionary])?.count, 2)

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
    }

    func testEngineStartAndStopOverXPCDriveDockerTier() throws {
        let home = "/tmp/doryd-service-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tier = DockerTier(configuration: DockerTierConfiguration(
            home: home,
            forwardSocketPath: home + "/forward.sock"
        ))
        let service = DorydService(socketPath: tier.socketPath, dockerTier: tier)
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
            kernelPath: "/tmp/kernel",
            rootfsPath: "/tmp/rootfs",
            memoryMB: 2048,
            cpuCount: 2
        ))
        let starting = try manager.start(id: "dev")
        try sendVmmHandoff(
            path: try XCTUnwrap(starting.handoffSocketPath),
            ready: VmmReadyMessage(
                machineID: "dev",
                agentBuild: "dory-agent/test",
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
            kernelPath: "/tmp/kernel",
            rootfsPath: "/tmp/rootfs",
            memoryMB: 2048,
            cpuCount: 2
        ))
        let starting = try manager.start(id: "dev")
        try sendVmmHandoff(
            path: try XCTUnwrap(starting.handoffSocketPath),
            ready: VmmReadyMessage(
                machineID: "dev",
                agentBuild: "dory-agent/test",
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
            XCTAssertTrue(message.contains("Docker API remains unreachable"))
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
            "kernelPath": "/tmp/kernel",
            "rootfsPath": "/tmp/rootfs",
            "memoryMB": 1024,
            "cpuCount": 2,
            "address": "192.168.215.40",
            "env": [
                [
                    "key": "APP_ENV",
                    "value": "dev",
                ] as NSDictionary,
            ],
        ]) { ok, body, message in
            XCTAssertTrue(ok, message)
            XCTAssertEqual(body["state"] as? String, "created")
            XCTAssertEqual(body["address"] as? String, "192.168.215.40")
            let env = body["env"] as? [NSDictionary]
            XCTAssertEqual(env?.first?["key"] as? String, "APP_ENV")
            XCTAssertEqual(env?.first?["value"] as? String, "dev")
            create.fulfill()
        }
        wait(for: [create], timeout: 5)

        let start = expectation(description: "machineStart reply")
        proxy.machineStart("dev") { ok, body, message in
            XCTAssertTrue(ok, message)
            XCTAssertEqual(body["state"] as? String, "running")
            XCTAssertNotNil(body["pid"])
            start.fulfill()
        }
        wait(for: [start], timeout: 5)

        let list = expectation(description: "machineList reply")
        proxy.machineList { body, message in
            XCTAssertEqual(message, "")
            let statuses = body as? [NSDictionary]
            XCTAssertEqual(statuses?.first?["id"] as? String, "dev")
            XCTAssertEqual(statuses?.first?["address"] as? String, "192.168.215.40")
            let env = statuses?.first?["env"] as? [NSDictionary]
            XCTAssertEqual(env?.first?["value"] as? String, "dev")
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
            "env": [
                [
                    "key": "NODE_ENV",
                    "value": "production",
                ] as NSDictionary,
            ],
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
            let env = body["env"] as? [NSDictionary]
            XCTAssertEqual(env?.first?["key"] as? String, "NODE_ENV")
            XCTAssertEqual(env?.first?["value"] as? String, "production")
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
            "kernelPath": "/tmp/kernel",
            "rootfsPath": "/tmp/rootfs",
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
            "kernelPath": "/tmp/kernel",
            "rootfsPath": "/tmp/rootfs",
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
            "kernelPath": "/tmp/kernel",
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
            snapshotReply.fulfill()
        }
        wait(for: [snapshotReply], timeout: 5)

        let listReply = expectation(description: "machineSnapshots reply")
        proxy.machineSnapshots("dev") { rows, message in
            XCTAssertEqual(message, "")
            XCTAssertEqual((rows as? [NSDictionary])?.first?["id"] as? String, "s1")
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
            protocolVersion: 1,
            kernel: "Linux docker",
            agentBuild: "docker-agent",
            uptimeSeconds: 9
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

    func exec(
        argv: [String],
        cwd: String,
        env: [DoryExecEnvironment],
        timeoutMs: UInt64,
        outputLimitBytes: UInt64
    ) throws -> DoryExecResult {
        let command = argv.joined(separator: " ")
        let output: String
        if command.contains("apk add --no-cache cargo rust") {
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
            protocolVersion: 1,
            kernel: "Linux remote",
            agentBuild: "remote-agent",
            uptimeSeconds: 7
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
