import Foundation
import Testing
@testable import Dory

@Suite(.serialized)
struct DorydClientTests {
    @MainActor
    @Test func dorydIsTheOnlyProductionOwnerForDorysLocalEngine() {
        #expect(AppStore.dorydEngineEnabled(environment: [:]))
        #expect(AppStore.dorydEngineEnabled(environment: ["DORY_APP_USE_DORYD": "1"]))
        #expect(AppStore.dorydEngineEnabled(environment: ["DORY_APP_USE_DORYD": "0"]))
        #expect(AppStore.dorydEngineEnabled(environment: ["DORY_APP_DISABLE_DORYD": "1"]))
    }

    @Test func customDomainPatternsAcceptExactAndLeftmostWildcardOnly() {
        #expect(AppStore.normalizedCustomDomainPattern(" Admin.MyProject.Local. ") == "admin.myproject.local")
        #expect(AppStore.normalizedCustomDomainPattern("*.Tenant.Test") == "*.tenant.test")
        #expect(AppStore.normalizedCustomDomainPattern("localhost") == nil)
        #expect(AppStore.normalizedCustomDomainPattern("admin.*.local") == nil)
        #expect(AppStore.normalizedCustomDomainPattern("-admin.myproject.local") == nil)
    }

    @Test func doryCLIResolverPrefersBundledHelperOverAuxiliaryExecutable() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DoryCLI-\(UUID().uuidString).app", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let helpers = root.appendingPathComponent("Contents/Helpers", isDirectory: true)
        let macOS = root.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)

        let helper = helpers.appendingPathComponent("dory")
        let appExecutable = macOS.appendingPathComponent("Dory")
        _ = FileManager.default.createFile(atPath: helper.path, contents: Data("#!/bin/sh\n".utf8))
        _ = FileManager.default.createFile(atPath: appExecutable.path, contents: Data())

        let resolved = DoryCLI.bundledPath(
            named: "dory",
            bundleURL: root,
            auxiliaryPath: appExecutable.path,
            isExecutable: { $0 == helper.path || $0 == appExecutable.path }
        )

        #expect(resolved == helper.path)
    }

    @Test func healthDiagnosticsUsesDorydHealthAndIdleWithoutLegacyCLIs() async throws {
        let recorder = HealthDiagnosticsCLIRunRecorder()
        let healthJSON = """
        {
          "results": [
            {"id":"socket.exists","status":"pass","code":"socket.ok","title":"Socket","detail":"ok"},
            {"id":"compat.docker","status":"pass","code":"compat.ok","title":"Compatibility","detail":"ok"}
          ]
        }
        """
        let idleStatus = try JSONDecoder().decode(IdleStatus.self, from: Data(
            """
            {"mode":"auto-idle","auto_idle_enabled":true,"can_sleep":true,"sleep_after_minutes":15,"blockers":[],"policy":{"sleepAfterMinutes":15,"keepPublishedPortsAwake":true,"keepKubernetesAwake":true,"keepPinnedProjectsAwake":true,"showWakeNotifications":true}}
            """.utf8
        ))

        let snapshot = await HealthDiagnostics.load(
            active: false,
            cli: URL(fileURLWithPath: "/tmp/dory"),
            daemonHealthJSON: { _ in healthJSON },
            daemonIncidents: { _ in
                [Incident(at: "2026-07-07T00:00:00Z", type: "engine.start", detail: "started")]
            },
            daemonIdleStatus: { idleStatus },
            daemonIdleHistory: { _ in
                [IdleHistoryEntry(at: "2026-07-07T00:00:00Z", state: "sleeping", detail: "idle")]
            },
            runCLI: { _, arguments, _ in
                recorder.record(arguments)
                return (false, "", "unexpected CLI command: \(arguments.joined(separator: " "))")
            }
        )

        #expect(snapshot.checks.map(\.id) == ["socket.exists", "compat.docker"])
        #expect(snapshot.idle?.mode == "auto-idle")
        #expect(snapshot.history.map(\.state) == ["sleeping"])
        #expect(snapshot.incidents.map(\.type) == ["engine.start"])
        #expect(recorder.commands.isEmpty)
    }

    @Test func engineStopAndSleepOutliveTheDefaultControlTimeout() async throws {
        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(engineShutdownReplyDelay: 0.05)
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let client = DorydClient(endpoint: listener.endpoint, timeout: 0.01)
        #expect(try await client.engineStop() == DorydCommandResult(ok: true, message: ""))
        #expect(try await client.engineSleep() == DorydCommandResult(ok: true, message: ""))
    }

    @MainActor
    @Test func readsDoctorJSONAndIncidentsOverXPC() async throws {
        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService()
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let client = DorydClient(endpoint: listener.endpoint)
        let version = try await client.protocolVersion()
        let socketPath = try await client.dorySocketPath()
        let engineStatus = try await client.engineStatus()
        let started = try await client.engineStart()
        let slept = try await client.engineSleep()
        let woke = try await client.engineWake()
        let dockerAgentInfo = try await client.dockerAgentInfo()
        let dockerAgentPorts = try await client.dockerAgentPorts()
        let dockerAgentTelemetry = try await client.dockerAgentTelemetry()
        let stopped = try await client.engineStop()
        let createdMachine = try await client.machineCreate(DorydMachineConfiguration(
            id: "dev",
            kernelPath: "/tmp/kernel",
            rootfsPath: "/tmp/rootfs",
            memoryMB: 2048,
            cpuCount: 2,
            address: "192.168.215.40",
            displayMode: .desktop,
            shares: [
                DorydMachineShareConfiguration(tag: "src", hostPath: "/Users/me/src", guestPath: "/workspace/src", readOnly: true),
            ],
            environment: ["FOO": "bar"]
        ))
        let startedMachine = try await client.machineStart("dev")
        let machineStats = try await client.machineStats("dev")
        let execResult = try await client.machineExec("dev", argv: ["/bin/sh", "-lc", "cargo --version"])
        let provisionedMachine = try await client.machineProvision("dev", recipe: "rust")
        let snapshot = try await client.machineSnapshot(
            "dev",
            note: "before",
            createdISO: "2026-07-07T00:00:00Z",
            snapshotID: "s1"
        )
        let snapshots = try await client.machineSnapshots(machineID: "dev")
        let clonedSnapshot = try await client.machineCloneSnapshot(machineID: "dev", snapshotID: "s1", newID: "dev-copy")
        let restoredSnapshot = try await client.machineRestoreSnapshot(machineID: "dev", snapshotID: "s1")
        let exportedSnapshot = try await client.machineExportSnapshot(machineID: "dev", snapshotID: "s1", to: "/tmp/dev.dorymachine")
        let importedSnapshot = try await client.machineImportSnapshot(from: "/tmp/dev.dorymachine")
        let savedBackup = try await client.machineBackupSet(DorydMachineBackupSchedule(
            machineID: "dev",
            enabled: true,
            frequency: .daily,
            keepLocal: 5,
            verifyEveryRuns: 3
        ))
        let backupSchedules = try await client.machineBackupSchedules()
        let completedBackup = try await client.machineBackupRun(machineID: "dev")
        let removedBackup = try await client.machineBackupRemove(machineID: "dev")
        let deletedSnapshot = try await client.machineDeleteSnapshot(machineID: "dev", snapshotID: "s1")
        let stoppedMachine = try await client.machineStop("dev")
        let updatedMachine = try await client.machineUpdate(
            "dev",
            memoryMB: 4096,
            cpuCount: 4,
            address: "192.168.215.41",
            environment: ["BAR": "baz"]
        )
        let machines = try await client.machineList()
        let deletedMachine = try await client.machineDelete("dev")
        let remoteInfo = try await client.remoteConnect(DorydRemoteMachineConfiguration(
            id: "vps",
            host: "vps.example.com",
            port: 22,
            user: "dory",
            privateKeyID: "primary",
            hostKeyType: "pinned",
            hostKey: "ssh-ed25519 AAAA fake",
            knownHostsPath: nil,
            knownHostsHost: nil,
            knownHostsPort: nil,
            endpointType: "unix",
            endpointPath: "/run/dory/agent.sock",
            endpointHost: nil,
            endpointPort: nil,
            remoteRoot: "/srv/app",
            build: "test"
        ))
        let pushStats = try await client.remotePush(machineID: "vps", localRoot: "/tmp/local")
        let remoteStatus = try await client.remoteStatus(machineID: "vps")
        let replacedRoutes = try await client.networkReplaceRoutes([
            DorydDomainRoute(
                hostname: "web.default.k8s.dory.local",
                address: "127.0.0.1",
                port: 18_001,
                pathPrefix: "/api/v1/namespaces/default/services/web:80/proxy"
            ),
        ])
        let networkStatus = try await client.networkStatus()
        let networkPlan = try await client.networkAuthorizationPlan()
        let repairedNetwork = try await client.repairSubsystem("dns")
        let balloonPlan = try await client.balloonStatus()
        let reconciledBalloonPlan = try await client.balloonReconcile()
        let idleStatus = try await client.idleStatus()
        let idleHistory = try await client.idleHistory(limit: 40)
        let updatedIdlePolicy = try await client.idleSetPolicy(key: "sleepAfterMinutes", value: "30")
        let updatedIdleMode = try await client.idleSetMode("manual")
        let healthJSON = try await client.healthJSON()
        let health = try JSONDecoder().decode(DoctorReport.self, from: Data(healthJSON.utf8))
        let doctorJSON = try await client.doctorJSON()
        let report = try JSONDecoder().decode(DoctorReport.self, from: Data(doctorJSON.utf8))
        let incidents = try await client.incidents(limit: 40)

        #expect(version == 1)
        #expect(socketPath == service.socketPath)
        #expect(engineStatus == DorydEngineStatus(state: "running", detail: "ok"))
        #expect(started == DorydCommandResult(ok: true, message: ""))
        #expect(slept == DorydCommandResult(ok: true, message: ""))
        #expect(woke == DorydCommandResult(ok: true, message: ""))
        #expect(dockerAgentInfo.agentBuild == "docker-agent")
        #expect(dockerAgentPorts.ports == [DorydListenPort(protocol: "tcp", port: 8080)])
        #expect(dockerAgentPorts.added == [DorydListenPort(protocol: "tcp", port: 8080)])
        #expect(dockerAgentTelemetry.memTotalKB == 2048)
        #expect(stopped == DorydCommandResult(ok: true, message: ""))
        #expect(createdMachine.state == "created")
        #expect(createdMachine.displayMode == .desktop)
        #expect(startedMachine.pid == 1234)
        #expect(startedMachine.agentBuild == "agent-test")
        #expect(startedMachine.agentSocketPath == "/tmp/agent.sock")
        #expect(startedMachine.address == "192.168.215.40")
        #expect(startedMachine.configuredAddress == "192.168.215.40")
        #expect(startedMachine.shares == [
            DorydMachineShareConfiguration(tag: "src", hostPath: "/Users/me/src", guestPath: "/workspace/src", readOnly: true),
        ])
        #expect(startedMachine.environment == ["FOO": "bar"])
        #expect(startedMachine.displayMode == .desktop)
        #expect(execResult.stdout == "cargo 1.0\n")
        #expect(execResult.exitCode == 0)
        #expect(machineStats.cpuPercent == 12.5)
        #expect(machineStats.memoryUsedBytes == 1_073_741_824)
        #expect(machineStats.memoryTotalBytes == 2_147_483_648)
        #expect(machineStats.processCount == 12)
        #expect(provisionedMachine.recipeID == "rust")
        #expect(provisionedMachine.verify.stdout == "cargo 1.0\n")
        #expect(snapshot.id == "s1")
        #expect(snapshot.machineID == "dev")
        #expect(snapshots.map(\.id).contains("s1"))
        #expect(clonedSnapshot.id == "dev-copy")
        #expect(restoredSnapshot.id == "dev")
        #expect(exportedSnapshot == DorydCommandResult(ok: true, message: ""))
        #expect(importedSnapshot.machineID == "dev")
        #expect(savedBackup.schedule.keepLocal == 5)
        #expect(savedBackup.schedule.verifyEveryRuns == 3)
        #expect(backupSchedules.map(\.schedule.machineID) == ["dev"])
        #expect(completedBackup.successfulRuns == 1)
        #expect(completedBackup.lastBootVerificationISO == "2026-07-07T00:00:00Z")
        #expect(removedBackup == DorydCommandResult(ok: true, message: ""))
        #expect(deletedSnapshot == DorydCommandResult(ok: true, message: ""))
        #expect(stoppedMachine.state == "stopped")
        #expect(updatedMachine.memoryMB == 4096)
        #expect(updatedMachine.cpuCount == 4)
        #expect(updatedMachine.address == "192.168.215.41")
        #expect(updatedMachine.environment == ["BAR": "baz"])
        #expect(machines.map(\.id) == ["dev", "dev-copy"])
        #expect(deletedMachine == DorydCommandResult(ok: true, message: ""))
        #expect(remoteInfo.agentBuild == "remote-agent")
        #expect(pushStats == DorydPushStats(filesSent: 2, bytesSent: 30, filesDeleted: 1))
        #expect(remoteStatus.telemetry?.memAvailableKB == 512)
        #expect(replacedRoutes == DorydCommandResult(ok: true, message: ""))
        #expect(networkStatus.mode == "high-port-dns-http-https-proxy")
        #expect(networkStatus.httpProxyPort == 18080)
        #expect(networkStatus.httpProxyRunning)
        #expect(networkStatus.httpsProxyPort == 18443)
        #expect(networkStatus.httpsProxyRunning)
        #expect(networkStatus.routes == [
            DorydDomainRoute(
                hostname: "web.default.k8s.dory.local",
                address: "127.0.0.1",
                port: 18_001,
                pathPrefix: "/api/v1/namespaces/default/services/web:80/proxy"
            ),
        ])
        #expect(networkStatus.customRoutes == networkStatus.routes)
        #expect(networkPlan.suffix == "dory.local")
        #expect(networkPlan.dnsBindAddress == "127.0.0.1")
        #expect(networkPlan.dnsPort == 15353)
        #expect(networkPlan.httpProxyPort == 18080)
        #expect(networkPlan.httpsProxyPort == 18443)
        #expect(networkPlan.privilegedTCPForwards == [
            DorydPrivilegedTCPForward(listenPort: 25, targetPort: 1025),
        ])
        #expect(networkPlan.requests.map(\.kind) == ["resolverFile"])
        #expect(repairedNetwork == DorydCommandResult(ok: true, message: "repaired dns"))
        #expect(balloonPlan.host.pressure == "warning")
        #expect(balloonPlan.applicableTargets.map(\.id) == ["docker"])
        #expect(reconciledBalloonPlan.host.pressure == "warning")
        #expect(reconciledBalloonPlan.applicableTargets.map(\.id) == ["docker"])
        #expect(idleStatus.mode == "always-on")
        #expect(idleHistory.map(\.state) == ["sleeping"])
        #expect(updatedIdlePolicy.policy?.sleepAfterMinutes == 30)
        #expect(updatedIdleMode.mode == "manual")
        #expect(health.results.map(\.id) == ["socket.exists", "machine.local"])
        #expect(report.results.map(\.id) == ["socket.exists"])
        #expect(report.results.first?.status == "pass")
        #expect(incidents == [
            Incident(at: "2026-07-07T00:00:00Z", type: "engine.start", detail: "started")
        ])
    }

    @MainActor
    @Test func healthRecoveryUsesDaemonOwnedSubsystemRepair() async {
        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService()
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let store = AppStore(dorydClient: DorydClient(endpoint: listener.endpoint))
        await store.runRepairTarget("dns")

        #expect(service.repairTargets == ["dns"])
        #expect(store.healthActionError == nil)
        #expect(!store.healthActionInFlight)
    }

    @MainActor
    @Test func automationDoesNotContactDefaultPreferredDorydWithoutExplicitOptIn() async throws {
        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService()
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let store = AppStore(dorydClient: DorydClient(endpoint: listener.endpoint))
        await store.connectBackend()

        #expect(service.engineStartCount == 0)
        #expect(store.loadState == .engineOff)
    }

    @MainActor
    @Test func appStoreUsesDorydEngineSocketWithoutStartingLegacyShim() async throws {
        let base = "/tmp/dac-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let socketPath = base + "/doryd.sock"
        defer { try? FileManager.default.removeItem(atPath: base) }

        let shim = DockerShim(runtime: MockRuntime())
        let dockerServer = ShimHTTPServer(socketPath: socketPath) { request in
            await shim.handle(request)
        }
        try dockerServer.start()
        defer { dockerServer.stop() }

        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(socketPath: socketPath)
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true
        )
        store.routeDockerCLI = false

        await store.connectBackend()

        #expect(service.engineStartCount == 0)
        #expect(store.runtimeKind == .sharedVM)
        #expect(store.shimSocketPath == socketPath)
        #expect(!store.shimRunning)
        #expect(!store.localNetworkingActiveForTests)
        #expect(store.loadState == .ready)
        #expect(!store.containers.isEmpty)
        #expect(service.latestNetworkRoutes.isEmpty)
    }

    @MainActor
    @Test func appStoreKeepsDoryPreferenceOnDorydStartFailure() async throws {
        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService()
        service.setEngineStatus("stopped", detail: "stopped")
        service.setEngineStartResult(ok: false, message: "doryd test failure")
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            environment: [:]
        )
        store.routeDockerCLI = false
        store.enginePreference = .dory

        await store.connectBackend()

        #expect(service.engineStartCount == 1)
        #expect(store.loadState == .engineOff)
        #expect(store.sharedVMStatus == "doryd test failure")
        #expect(store.runtimeKind == .disconnected)
        #expect(!store.shimRunning)
    }

    @MainActor
    @Test func appStoreRoutesMachineLifecycleToDorydVMs() async throws {
        let base = "/tmp/dam-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let socketPath = base + "/doryd.sock"
        defer { try? FileManager.default.removeItem(atPath: base) }

        let shim = DockerShim(runtime: MockRuntime())
        let dockerServer = ShimHTTPServer(socketPath: socketPath) { request in
            await shim.handle(request)
        }
        try dockerServer.start()
        defer { dockerServer.stop() }

        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(socketPath: socketPath)
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true
        )
        store.routeDockerCLI = false

        await store.connectBackend()
        store.loadMachines()
        try await waitUntil {
            store.machines.contains {
                $0.name == "dev" && $0.cpuPercent == 12.5 && $0.memoryDisplay == "1 GB / 2 GB"
            }
        }

        var machine = try #require(store.machines.first { $0.name == "dev" })
        #expect(machine.distro == "Debian")
        #expect(machine.version == "13 · Xfce")
        #expect(machine.username == "dory")
        #expect(machine.loginShell == "/bin/bash")
        #expect(machine.status == .running)
        #expect(machine.cpuPercent == 12.5)
        #expect(machine.memoryDisplay == "1 GB / 2 GB")
        #expect(machine.ip == "192.168.215.40")
        #expect(machine.displayMode == .desktop)
        #expect(machine.mounts == [MountPair(host: "/Users/me/src", guest: "/workspace/src", readOnly: true)])
        #expect(machine.containerID.isEmpty)
        #expect(store.machineTerminalCommand(machine) == "dory machine shell dev")
        #expect(store.canUseMachineArtifacts(machine))

        let currentSettings = await store.machineSettings(machine.name)
        #expect(currentSettings.cpus == 2)
        #expect(currentSettings.memoryMB == 2048)
        #expect(currentSettings.address == "192.168.215.40")
        #expect(currentSettings.displayMode == .desktop)
        #expect(currentSettings.mounts == [MountPair(host: "/Users/me/src", guest: "/workspace/src", readOnly: true)])
        #expect(currentSettings.env == ["ANTHROPIC_API_KEY": "test-token"])

        store.toggleMachine(machine)
        try await waitUntil {
            store.machines.first { $0.name == "dev" }?.status == .stopped
        }
        #expect(service.machineStopCount == 1)

        machine = try #require(store.machines.first { $0.name == "dev" })
        store.toggleMachine(machine)
        try await waitUntil {
            store.machines.first { $0.name == "dev" }?.status == .running
        }
        #expect(service.machineStartCount == 1)

        machine = try #require(store.machines.first { $0.name == "dev" })
        let editResult = await store.editMachine(
            machine,
            settings: MachineSettings(
                cpus: 4,
                memoryMB: 4096,
                mounts: [MountPair(host: "/Users/me/app", guest: "/workspace/app")],
                address: "192.168.215.41"
            )
        )
        #expect(editResult == nil)
        try await waitUntil {
            service.machineUpdateCount == 1
                && store.machines.first { $0.name == "dev" }?.memoryDisplay == "2 GB / 4 GB"
        }
        #expect((service.latestMachineUpdateConfig?["memoryMB"] as? NSNumber)?.uint64Value == 4096)
        #expect((service.latestMachineUpdateConfig?["cpuCount"] as? NSNumber)?.intValue == 4)
        #expect(service.latestMachineUpdateConfig?["address"] as? String == "192.168.215.41")
        let updateShares = try #require(service.latestMachineUpdateConfig?["shares"] as? [NSDictionary])
        #expect(updateShares.first?["hostPath"] as? String == "/Users/me/app")
        #expect(updateShares.first?["guestPath"] as? String == "/workspace/app")
        #expect(updateShares.first?["readOnly"] as? Bool == false)
        let updateEnv = try #require(service.latestMachineUpdateConfig?["env"] as? [NSDictionary])
        #expect(updateEnv.first?["key"] as? String == "ANTHROPIC_API_KEY")
        #expect(updateEnv.first?["value"] as? String == "test-token")

        machine = try #require(store.machines.first { $0.name == "dev" })
        let clearAddressResult = await store.editMachine(
            machine,
            settings: MachineSettings(
                cpus: 4,
                memoryMB: 4096,
                mounts: [MountPair(host: "/Users/me/app", guest: "/workspace/app")],
                address: ""
            )
        )
        #expect(clearAddressResult == nil)
        #expect(service.machineUpdateCount == 2)
        #expect(service.latestMachineUpdateConfig?["address"] as? String == "")
        let clearedSettings = await store.machineSettings("dev")
        #expect(clearedSettings.address == nil)

        machine = try #require(store.machines.first { $0.name == "dev" })
        service.setMachineDeleteResult(ok: false, message: "fixture disk is busy")
        store.deleteMachine(machine)
        try await waitUntil {
            service.machineDeleteCount == 1 && !store.isMachineBusy("dev")
        }
        #expect(store.machines.contains { $0.name == "dev" })
        #expect(store.actionError?.contains("fixture disk is busy") == true)

        service.setMachineDeleteResult(ok: true)
        store.deleteMachine(machine)
        try await waitUntil {
            service.machineDeleteCount == 2 && !store.machines.contains { $0.name == "dev" }
        }
        #expect(service.machineDeleteCount == 2)
    }

    @MainActor
    @Test func appStoreRoutesMachineSnapshotsToDorydVMs() async throws {
        let base = "/tmp/das-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let socketPath = base + "/doryd.sock"
        defer { try? FileManager.default.removeItem(atPath: base) }

        let shim = DockerShim(runtime: MockRuntime())
        let dockerServer = ShimHTTPServer(socketPath: socketPath) { request in
            await shim.handle(request)
        }
        try dockerServer.start()
        defer { dockerServer.stop() }

        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(socketPath: socketPath)
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true
        )
        store.routeDockerCLI = false

        await store.connectBackend()
        store.loadMachines()
        try await waitUntil {
            store.machines.contains { $0.name == "dev" }
        }
        let machine = try #require(store.machines.first { $0.name == "dev" })

        store.openSnapshots(machine)
        store.takeSnapshot(machine, note: "before upgrade")
        try await waitUntil {
            service.machineSnapshotCount == 1 && store.machineSnapshots.contains { $0.machineName == "dev" }
        }
        let snapshot = try #require(store.machineSnapshots.first)
        #expect(snapshot.note == "before upgrade")
        #expect(snapshot.imageRef.hasPrefix("doryd://dev/"))

        service.setMachineCloneSnapshotDuplicateFailures(1)
        store.cloneSnapshot(snapshot)
        try await waitUntil {
            service.machineCloneSnapshotCount == 2 && store.machines.contains { $0.name.hasPrefix("dev-copy-") }
        }
        let clonedName = try #require(store.machines.first { $0.name.hasPrefix("dev-copy-") }?.name)
        let generatedToken = try #require(clonedName.split(separator: "-").last)
        #expect(generatedToken.count == 12)
        #expect(generatedToken.allSatisfy { $0.isHexDigit })
        #expect(store.machineCreationLog.contains("already exists. Choosing another name"))

        store.restoreSnapshot(snapshot)
        try await waitUntil {
            service.machineRestoreSnapshotCount == 1
        }

        store.deleteSnapshot(snapshot)
        try await waitUntil {
            service.machineDeleteSnapshotCount == 1 && !store.machineSnapshots.contains { $0.id == snapshot.id }
        }

        store.cloneMachine(machine)
        try await waitUntil {
            service.machineCloneSnapshotCount == 3
                && service.machineSnapshotCount == 2
                && service.machineDeleteSnapshotCount == 2
                && !store.isMachineBusy("dev")
        }
        #expect(store.machineCreationLog.contains("Clone dev-copy-"))
    }

    @MainActor
    @Test func appStoreImportsPortableMachineAsVisibleRunningCloneAndCleansSnapshot() async throws {
        let bounded = AppStore.derivedMachineID(
            base: String(repeating: "a", count: 63),
            operation: "import",
            token: "ABCDEF123456"
        )
        #expect(bounded.count == 63)
        #expect(bounded.hasSuffix("-import-abcdef123456"))

        let base = "/tmp/dami-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let socketPath = base + "/doryd.sock"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let shim = DockerShim(runtime: MockRuntime())
        let dockerServer = ShimHTTPServer(socketPath: socketPath) { request in
            await shim.handle(request)
        }
        try dockerServer.start()
        defer { dockerServer.stop() }
        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(socketPath: socketPath)
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true
        )
        store.routeDockerCLI = false
        await store.connectBackend()

        store.importMachine(from: URL(fileURLWithPath: "/tmp/dev.dorymachine"))
        try await waitUntil {
            service.machineCloneSnapshotCount == 1
                && service.machineDeleteSnapshotCount == 1
                && store.machines.contains { $0.name.hasPrefix("dev-import-") }
                && !store.isMachineBusy(AppStore.importBusyKey)
        }
        #expect(store.machineCreationLog.contains("Imported machine dev-import-"))
        #expect(!store.machineCreationLog.contains("Use Clone or Restore"))

        service.setMachineCloneSnapshotResult(ok: false, message: "fixture clone failed")
        store.importMachine(from: URL(fileURLWithPath: "/tmp/broken.dorymachine"))
        try await waitUntil {
            service.machineCloneSnapshotCount == 2
                && service.machineDeleteSnapshotCount == 2
                && !store.isMachineBusy(AppStore.importBusyKey)
        }
        #expect(store.machineCreationError?.contains("fixture clone failed") == true)
        #expect(store.machineCreationLog.contains("Error:"))
    }

    @MainActor
    @Test func appStoreCreatesDorydMachineFromKernelRootfsEnvironment() async throws {
        let base = "/tmp/damc-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let socketPath = base + "/doryd.sock"
        defer { try? FileManager.default.removeItem(atPath: base) }

        let shim = DockerShim(runtime: MockRuntime())
        let dockerServer = ShimHTTPServer(socketPath: socketPath) { request in
            await shim.handle(request)
        }
        try dockerServer.start()
        defer { dockerServer.stop() }

        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(socketPath: socketPath)
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true,
            environment: [
                "DORYD_MACHINE_KERNEL": "/vm/Image",
                "DORYD_MACHINE_ROOTFS": "/vm/rootfs.raw",
            ],
            desktopMachineAssetPreparer: { _, _, _ in
                DesktopMachineAssets(kernelPath: "/vm/Image", rootfsPath: "/vm/rootfs.raw")
            }
        )
        store.routeDockerCLI = false

        await store.connectBackend()
        let result = await store.createMachine(
            name: "vmdev",
            recipe: DevRecipe.forID("rust"),
            settings: MachineSettings(
                cpus: 3,
                memoryMB: 3072,
                mounts: [MountPair(host: "/Users/me/project", guest: "/workspace/project")],
                env: ["APP_ENV": "dev"],
                displayMode: .desktop
            )
        )

        #expect(result == nil)
        #expect(service.machineCreateCount == 1)
        #expect(service.machineStartCount == 1)
        #expect(service.machineProvisionCount == 1)
        #expect(service.latestMachineProvisionRecipe == "rust")
        let config = try #require(service.latestMachineCreateConfig)
        #expect(config["id"] as? String == "vmdev")
        #expect(config["kernelPath"] as? String == "/vm/Image")
        #expect(config["rootfsPath"] as? String == "/vm/rootfs.raw")
        #expect((config["memoryMB"] as? NSNumber)?.uint64Value == 3072)
        #expect((config["cpuCount"] as? NSNumber)?.intValue == 3)
        #expect(config["displayMode"] as? String == "desktop")
        #expect(config["address"] == nil)
        let createShares = try #require(config["shares"] as? [NSDictionary])
        #expect(createShares.first?["hostPath"] as? String == "/Users/me/project")
        #expect(createShares.first?["guestPath"] as? String == "/workspace/project")
        let createEnv = try #require(config["env"] as? [NSDictionary])
        #expect(createEnv.first?["key"] as? String == "APP_ENV")
        #expect(createEnv.first?["value"] as? String == "dev")

        try await waitUntil {
            store.machines.first { $0.name == "vmdev" }?.status == .running
        }
        #expect(store.machineCreated?.name == "vmdev")
        #expect(store.machineCreationLog.contains("Provisioning Rust"))
        #expect(store.machineCreationLog.contains("cargo 1.0"))
    }

    @MainActor
    @Test func failedRequiredMachineProvisioningRollsBackNewDefinition() async throws {
        let base = "/tmp/damc-provision-failure-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let socketPath = base + "/doryd.sock"
        defer { try? FileManager.default.removeItem(atPath: base) }

        let shim = DockerShim(runtime: MockRuntime())
        let dockerServer = ShimHTTPServer(socketPath: socketPath) { request in
            await shim.handle(request)
        }
        try dockerServer.start()
        defer { dockerServer.stop() }

        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(socketPath: socketPath)
        service.setMachineProvisionResult(ok: false, message: "fixture install failed")
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true,
            environment: [
                "DORYD_MACHINE_KERNEL": "/vm/Image",
                "DORYD_MACHINE_ROOTFS": "/vm/rootfs.raw",
            ]
        )
        store.routeDockerCLI = false

        await store.connectBackend()
        let result = await store.createMachine(
            name: "vmfailed",
            recipe: DevRecipe.forID("rust")
        )

        #expect(result?.contains("fixture install failed") == true)
        #expect(service.machineCreateCount == 1)
        #expect(service.machineStartCount == 1)
        #expect(service.machineProvisionCount == 1)
        #expect(service.machineDeleteCount == 1)
        #expect(store.machineCreated == nil)
        #expect(store.machineCreationLog.contains("Setup failed. Removing the incomplete machine"))
        #expect(store.machineCreationLog.contains("Incomplete machine removed"))
        #expect(!store.machineCreationLog.contains("Machine created and started"))
        #expect(!store.machines.contains { $0.name == "vmfailed" })
    }

    @MainActor
    @Test func appStoreCopiesAllowedHostEnvWhenCreatingDorydMachine() async throws {
        let base = "/tmp/damc-env-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let socketPath = base + "/doryd.sock"
        defer { try? FileManager.default.removeItem(atPath: base) }

        let shim = DockerShim(runtime: MockRuntime())
        let dockerServer = ShimHTTPServer(socketPath: socketPath) { request in
            await shim.handle(request)
        }
        try dockerServer.start()
        defer { dockerServer.stop() }

        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(socketPath: socketPath)
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true,
            environment: [
                "DORYD_MACHINE_KERNEL": "/vm/Image",
                "DORYD_MACHINE_ROOTFS": "/vm/rootfs.raw",
            ],
            machineEnvResolver: { _ in
                [
                    "ANTHROPIC_API_KEY": "sk-ant-host",
                    "GH_TOKEN": "gh-host",
                    "EMPTY_TOKEN": "",
                ]
            }
        )
        store.routeDockerCLI = false
        store.setMachineEnvAllowList(["ANTHROPIC_API_KEY", "GH_TOKEN", "EMPTY_TOKEN"])

        await store.connectBackend()
        let result = await store.createMachine(
            name: "envdev",
            settings: MachineSettings(cpus: nil, memoryMB: nil, env: ["GH_TOKEN": "gh-explicit"])
        )

        #expect(result == nil)
        let config = try #require(service.latestMachineCreateConfig)
        let envRows = try #require(config["env"] as? [NSDictionary])
        let env = Dictionary(uniqueKeysWithValues: envRows.compactMap { row -> (String, String)? in
            guard let key = row["key"] as? String, let value = row["value"] as? String else { return nil }
            return (key, value)
        })
        #expect(env["ANTHROPIC_API_KEY"] == "sk-ant-host")
        #expect(env["GH_TOKEN"] == "gh-explicit")
        #expect(env["EMPTY_TOKEN"] == nil)
    }

    @MainActor
    @Test func dorydMachineConfigurationRequiresKernelAndRootfsAndUsesSettingsDefaults() {
        #expect(AppStore.dorydMachineConfiguration(
            name: "vmdev",
            settings: .default,
            environment: ["DORYD_DISABLE_BUNDLED_MACHINE_ASSETS": "1"]
        ) == nil)

        let config = AppStore.dorydMachineConfiguration(
            name: "vmdev",
            settings: MachineSettings(cpus: 3, memoryMB: 3072, env: ["APP_ENV": "dev"]),
            environment: [
                "DORYD_GUEST_KERNEL": "/vm/Image",
                "DORYD_GUEST_ROOTFS": "/vm/rootfs.raw",
            ]
        )

        #expect(config == DorydMachineConfiguration(
            id: "vmdev",
            kernelPath: "/vm/Image",
            rootfsPath: "/vm/rootfs.raw",
            memoryMB: 3072,
            cpuCount: 3,
            environment: ["APP_ENV": "dev"]
        ))

        let invalidResources = AppStore.dorydMachineConfiguration(
            name: "vmdev",
            settings: .default,
            environment: [
                "DORYD_GUEST_KERNEL": "/vm/Image",
                "DORYD_GUEST_ROOTFS": "/vm/rootfs.raw",
                "DORYD_MACHINE_MEMORY_MB": "0",
                "DORYD_MACHINE_CPUS": "0",
            ]
        )
        #expect(invalidResources?.memoryMB == 0)
        #expect(invalidResources?.cpuCount == 0)

        let malformedResources = AppStore.dorydMachineConfiguration(
            name: "vmdev",
            settings: .default,
            environment: [
                "DORYD_GUEST_KERNEL": "/vm/Image",
                "DORYD_GUEST_ROOTFS": "/vm/rootfs.raw",
                "DORYD_MACHINE_MEMORY_MB": "invalid",
                "DORYD_MACHINE_CPUS": "invalid",
            ]
        )
        #expect(malformedResources?.memoryMB == 0)
        #expect(malformedResources?.cpuCount == 0)
    }

    @MainActor
    @Test func dorydRecipeMappingCoversBuiltInRecipesAndRejectsCustomRecipes() {
        #expect(AppStore.dorydRecipeID(for: DevRecipe.forID("node")!) == "node")
        #expect(AppStore.dorydRecipeID(for: DevRecipe.forID("python")!) == "python-ml")
        #expect(AppStore.dorydRecipeID(for: DevRecipe.forID("go")!) == "go")
        #expect(AppStore.dorydRecipeID(for: DevRecipe.forID("java")!) == "java")
        #expect(AppStore.dorydRecipeID(for: DevRecipe.forID("ruby")!) == "ruby")
        #expect(AppStore.dorydRecipeID(for: DevRecipe.forID("rust")!) == "rust")
        #expect(AppStore.dorydRecipeID(for: DevRecipe.forID("devops")!) == "devops")
        #expect(AppStore.dorydRecipeID(for: DevRecipe(id: "custom-abc", display: "Custom", icon: "wrench", install: "true")) == nil)
    }

    @MainActor
    @Test func appStoreAutoRefreshDoesNotWakeDorydIdleSleep() async throws {
        let base = "/tmp/daslp-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let socketPath = base + "/doryd.sock"
        defer { try? FileManager.default.removeItem(atPath: base) }

        let shim = DockerShim(runtime: MockRuntime())
        let dockerServer = ShimHTTPServer(socketPath: socketPath) { request in
            await shim.handle(request)
        }
        try dockerServer.start()
        defer { dockerServer.stop() }

        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(socketPath: socketPath)
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true
        )
        store.routeDockerCLI = false

        await store.connectBackend()
        #expect(!store.containers.isEmpty)

        store.containers = []
        service.setEngineStatus("sleeping", detail: "idle")

        await store.refreshIfIdle()

        #expect(store.engineSleeping)
        #expect(!store.engineRunning)
        #expect(store.containers.isEmpty)
        #expect(service.engineWakeCount == 0)
    }

    @MainActor
    @Test func appStoreMenuBarRefreshDoesNotWakeDorydIdleSleep() async throws {
        let base = "/tmp/dmbr-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let socketPath = base + "/doryd.sock"
        defer { try? FileManager.default.removeItem(atPath: base) }

        let shim = DockerShim(runtime: MockRuntime())
        let dockerServer = ShimHTTPServer(socketPath: socketPath) { request in
            await shim.handle(request)
        }
        try dockerServer.start()
        defer { dockerServer.stop() }

        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(socketPath: socketPath)
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true
        )
        store.routeDockerCLI = false

        await store.connectBackend()
        #expect(!store.containers.isEmpty)

        store.containers = []
        service.setEngineStatus("sleeping", detail: "idle")

        await store.refreshMenuBar()

        #expect(store.engineSleeping)
        #expect(!store.engineRunning)
        #expect(store.containers.isEmpty)
        #expect(service.engineWakeCount == 0)
    }

    @MainActor
    @Test func appStoreStartsStoppedDorydOnAttach() async throws {
        let base = "/tmp/doryd-start-stopped-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let socketPath = base + "/doryd.sock"
        defer { try? FileManager.default.removeItem(atPath: base) }

        let shim = DockerShim(runtime: MockRuntime())
        let dockerServer = ShimHTTPServer(socketPath: socketPath) { request in
            await shim.handle(request)
        }
        try dockerServer.start()
        defer { dockerServer.stop() }

        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(socketPath: socketPath)
        service.setEngineStatus("stopped", detail: "stopped")
        service.setIdleMode("manual")
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true
        )
        store.routeDockerCLI = false

        await store.connectBackend()

        #expect(service.engineStartCount == 1)
        #expect(service.engineWakeCount == 0)
        #expect(store.runtimeMode == "manual")
        #expect(store.loadState == .ready)
        #expect(!store.engineSleeping)
        #expect(store.engineRunning)
    }

    @MainActor
    @Test func appStoreStartsSleepingDorydOnAttach() async throws {
        let base = "/tmp/doryd-start-sleeping-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let socketPath = base + "/doryd.sock"
        defer { try? FileManager.default.removeItem(atPath: base) }

        let shim = DockerShim(runtime: MockRuntime())
        let dockerServer = ShimHTTPServer(socketPath: socketPath) { request in
            await shim.handle(request)
        }
        try dockerServer.start()
        defer { dockerServer.stop() }

        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(socketPath: socketPath)
        service.setEngineStatus("sleeping", detail: "armed")
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true
        )
        store.routeDockerCLI = false

        await store.connectBackend()

        #expect(service.engineStartCount == 1)
        #expect(service.engineWakeCount == 0)
        #expect(store.runtimeKind == .sharedVM)
        #expect(store.loadState == .ready)
        #expect(!store.engineSleeping)
        #expect(store.engineRunning)
        #expect(!store.containers.isEmpty)
    }

    @MainActor
    @Test func daemonOwnedAMD64SettingRestartsAndReconnectsWithExplicitLaunchAgentChoice() async throws {
        guard MacHostPlatform.current().isAppleSilicon else { return }
        let key = SharedVMProvisioner.Config.rosettaX86Key
        let previousDefault = UserDefaults.standard.object(forKey: key)
        defer {
            if let previousDefault { UserDefaults.standard.set(previousDefault, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(false, forKey: key)

        let base = "/tmp/doryd-setting-success-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let socketPath = base + "/doryd.sock"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let workloadRecorder = WorkloadStartRecorder()
        let shim = DockerShim(runtime: RecordingWorkloadRuntime(recorder: workloadRecorder))
        let dockerServer = ShimHTTPServer(socketPath: socketPath) { request in await shim.handle(request) }
        try dockerServer.start()
        defer { dockerServer.stop() }

        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(socketPath: socketPath)
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let launchAgent = LaunchAgentConfigurationRecorder()

        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true,
            dorydLaunchAgentEnsurer: { configuration in launchAgent.ensure(configuration) }
        )
        store.routeDockerCLI = false
        await store.connectBackend()
        await store.setRosettaX86(true)

        #expect(service.engineStopCount == 1)
        #expect(service.engineStartCount == 1)
        #expect(launchAgent.configurations.last?.amd64EmulationEnabled == true)
        #expect(launchAgent.configurations.last?.gpuVenusEnabled == false)
        #expect(store.rosettaX86Enabled)
        #expect(UserDefaults.standard.bool(forKey: key))
        #expect(store.loadState == .ready)
        #expect(store.dorydRuntimeActive)
        #expect(store.settingsNotice?.kind == .success)
        #expect(store.settingsNotice?.message == "x86/amd64 emulation enabled.")
        let restarted = await workloadRecorder.startedIDs
        #expect(Set(restarted) == Set(MockData.containers.filter(\.isRunning).map(\.id)))
        #expect(!restarted.contains("c5"))
    }

    @MainActor
    @Test func manualDaemonRestartRestoresOnlyPreviouslyRunningWorkloads() async throws {
        let base = "/tmp/doryd-manual-restart-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let socketPath = base + "/doryd.sock"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let workloadRecorder = WorkloadStartRecorder()
        let shim = DockerShim(runtime: RecordingWorkloadRuntime(recorder: workloadRecorder))
        let dockerServer = ShimHTTPServer(socketPath: socketPath) { request in await shim.handle(request) }
        try dockerServer.start()
        defer { dockerServer.stop() }

        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(socketPath: socketPath)
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let launchAgent = LaunchAgentConfigurationRecorder()

        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true,
            dorydLaunchAgentEnsurer: { configuration in launchAgent.ensure(configuration) }
        )
        store.routeDockerCLI = false
        await store.connectBackend()
        await store.restartEngine()

        #expect(service.engineStopCount == 1)
        #expect(service.engineStartCount == 1)
        #expect(store.loadState == .ready)
        #expect(store.dorydRuntimeActive)
        #expect(store.settingsNotice?.kind == .success)
        let restarted = await workloadRecorder.startedIDs
        #expect(Set(restarted) == Set(MockData.containers.filter(\.isRunning).map(\.id)))
        #expect(!restarted.contains("c5"))
    }

    @MainActor
    @Test func dataDriveMaintenanceRestoresRunningContainersAndLinuxMachines() async throws {
        let base = "/tmp/doryd-data-drive-maintenance-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let socketPath = base + "/doryd.sock"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let workloadRecorder = WorkloadStartRecorder()
        let shim = DockerShim(runtime: RecordingWorkloadRuntime(recorder: workloadRecorder))
        let dockerServer = ShimHTTPServer(socketPath: socketPath) { request in await shim.handle(request) }
        try dockerServer.start()
        defer { dockerServer.stop() }

        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(socketPath: socketPath)
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let launchAgent = LaunchAgentConfigurationRecorder()

        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true,
            dorydLaunchAgentEnsurer: { configuration in launchAgent.ensure(configuration) },
            dorydLaunchAgentBootout: { true }
        )
        store.routeDockerCLI = false
        await store.connectBackend()

        let captured = try await store.quiesceDorydForDataDriveOperation()
        #expect(captured.machineIDs == ["dev"])
        #expect(Set(captured.containers.map(\.id)) == Set(MockData.containers.filter(\.isRunning).map(\.id)))

        let recovery = await store.reconnectAfterDataDriveOperation(workloads: captured)

        #expect(recovery == nil)
        #expect(service.machineStartCount == 1)
        let restarted = await workloadRecorder.startedIDs
        #expect(Set(restarted) == Set(MockData.containers.filter(\.isRunning).map(\.id)))
        #expect(!restarted.contains("c5"))
    }

    @MainActor
    @Test func daemonEngineResourcesPersistRestartAndRestoreRunningWorkloads() async throws {
        let keys = [AppStore.engineCPUCountKey, AppStore.engineMemoryMBKey]
        let previousDefaults = Dictionary(uniqueKeysWithValues: keys.map {
            ($0, UserDefaults.standard.object(forKey: $0))
        })
        defer {
            for key in keys {
                if let value = previousDefaults[key] as? Int {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }

        let base = "/tmp/doryd-resource-setting-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let socketPath = base + "/doryd.sock"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let workloadRecorder = WorkloadStartRecorder()
        let shim = DockerShim(runtime: RecordingWorkloadRuntime(recorder: workloadRecorder))
        let dockerServer = ShimHTTPServer(socketPath: socketPath) { request in await shim.handle(request) }
        try dockerServer.start()
        defer { dockerServer.stop() }

        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(socketPath: socketPath)
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let launchAgent = LaunchAgentConfigurationRecorder()

        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true,
            dorydLaunchAgentEnsurer: { configuration in launchAgent.ensure(configuration) },
            environment: ["XCTestConfigurationFilePath": "DoryTests.xctest"]
        )
        store.routeDockerCLI = false
        await store.connectBackend()
        let limits = AppStore.engineResourceLimits()
        guard limits.maximumCPUCount > 1 else { return }
        let targetCPU = store.engineCPUCount == 1 ? 2 : 1
        let targetMemoryMB = store.engineMemoryMB

        await store.setEngineResources(cpuCount: targetCPU, memoryMB: targetMemoryMB)

        #expect(service.engineStopCount == 1)
        #expect(service.engineStartCount == 1)
        #expect(launchAgent.configurations.last?.cpuCount == UInt16(targetCPU))
        #expect(launchAgent.configurations.last?.memoryMB == UInt32(targetMemoryMB))
        #expect(store.engineCPUCount == targetCPU)
        #expect(store.engineMemoryMB == targetMemoryMB)
        #expect(UserDefaults.standard.integer(forKey: AppStore.engineCPUCountKey) == targetCPU)
        #expect(UserDefaults.standard.integer(forKey: AppStore.engineMemoryMBKey) == targetMemoryMB)
        #expect(store.settingsNotice?.kind == .success)
        #expect(store.settingsNotice?.message == "Engine resources set to \(targetCPU) cores and \(targetMemoryMB / 1024) GB.")
        let restarted = await workloadRecorder.startedIDs
        #expect(Set(restarted) == Set(MockData.containers.filter(\.isRunning).map(\.id)))
        #expect(!restarted.contains("c5"))
    }

    @MainActor
    @Test func dockerBridgeSubnetPersistsRestartsAndRestoresRunningWorkloads() async throws {
        let key = AppStore.defaultBridgeSubnetKey
        let previousDefault = UserDefaults.standard.object(forKey: key)
        defer {
            if let previousDefault { UserDefaults.standard.set(previousDefault, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)

        let base = "/tmp/doryd-bridge-setting-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let socketPath = base + "/doryd.sock"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let workloadRecorder = WorkloadStartRecorder()
        let shim = DockerShim(runtime: RecordingWorkloadRuntime(recorder: workloadRecorder))
        let dockerServer = ShimHTTPServer(socketPath: socketPath) { request in await shim.handle(request) }
        try dockerServer.start()
        defer { dockerServer.stop() }

        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(socketPath: socketPath)
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let launchAgent = LaunchAgentConfigurationRecorder()

        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true,
            dorydLaunchAgentEnsurer: { configuration in launchAgent.ensure(configuration) },
            environment: ["XCTestConfigurationFilePath": "DoryTests.xctest"]
        )
        store.routeDockerCLI = false
        await store.connectBackend()
        await store.setDefaultBridgeSubnet("10.44.19.8/20")

        #expect(service.engineStopCount == 1)
        #expect(service.engineStartCount == 1)
        #expect(launchAgent.configurations.last?.bridgeSubnetCIDR == "10.44.16.0/20")
        #expect(store.defaultBridgeSubnet == "10.44.16.0/20")
        #expect(UserDefaults.standard.string(forKey: key) == "10.44.16.0/20")
        #expect(store.settingsNotice?.kind == .success)
        #expect(
            store.settingsNotice?.message
                == "Docker bridge subnet changed to 10.44.16.0/20. Existing data was preserved."
        )
        let restarted = await workloadRecorder.startedIDs
        #expect(Set(restarted) == Set(MockData.containers.filter(\.isRunning).map(\.id)))
        #expect(!restarted.contains("c5"))
    }

    @MainActor
    @Test func daemonOwnedSettingRollsBackWhenLaunchAgentRejectsNewConfiguration() async throws {
        guard MacHostPlatform.current().isAppleSilicon else { return }
        let key = SharedVMProvisioner.Config.rosettaX86Key
        let previousDefault = UserDefaults.standard.object(forKey: key)
        defer {
            if let previousDefault { UserDefaults.standard.set(previousDefault, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(false, forKey: key)

        let base = "/tmp/doryd-setting-rollback-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let socketPath = base + "/doryd.sock"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let workloadRecorder = WorkloadStartRecorder(failingIDs: ["c3"])
        let shim = DockerShim(runtime: RecordingWorkloadRuntime(recorder: workloadRecorder))
        let dockerServer = ShimHTTPServer(socketPath: socketPath) { request in await shim.handle(request) }
        try dockerServer.start()
        defer { dockerServer.stop() }

        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(socketPath: socketPath)
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let launchAgent = LaunchAgentConfigurationRecorder(rejectAMD64: true)

        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true,
            dorydLaunchAgentEnsurer: { configuration in launchAgent.ensure(configuration) }
        )
        store.routeDockerCLI = false
        await store.connectBackend()
        await store.setRosettaX86(true)

        #expect(service.engineStopCount == 1)
        #expect(service.engineStartCount == 1)
        #expect(launchAgent.configurations.map(\.amd64EmulationEnabled) == [false, true, false])
        #expect(!store.rosettaX86Enabled)
        #expect(!UserDefaults.standard.bool(forKey: key))
        #expect(store.loadState == .ready)
        #expect(store.dorydRuntimeActive)
        #expect(store.settingsNotice?.kind == .failure)
        #expect(store.settingsNotice?.message.contains("previous setting was restored") == true)
        #expect(store.settingsNotice?.message.contains("web-api") == true)
        let rollbackRestarted = await workloadRecorder.startedIDs
        #expect(Set(rollbackRestarted) == Set(MockData.containers.filter(\.isRunning).map(\.id)))
    }

    @MainActor
    @Test func idleSettingsDoNotPublishRejectedDorydState() async throws {
        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService()
        service.setIdleAvailable(false)
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true
        )
        store.runtimeMode = "manual"
        store.idlePolicy = IdlePolicy(sleepAfterMinutes: 15)

        await store.setRuntimeMode("auto-idle")

        #expect(store.runtimeMode == "manual")
        #expect(store.settingsNotice?.kind == .failure)
        #expect(store.settingsNotice?.message == "doryd did not apply the idle mode: idle unavailable")

        await store.setIdleSleepAfter(5)

        #expect(store.runtimeMode == "manual")
        #expect(store.idlePolicy.sleepAfterMinutes == 15)
        #expect(store.actionError == nil)
        #expect(store.settingsNotice?.kind == .failure)
        #expect(store.settingsNotice?.message == "doryd did not apply the idle policy: idle unavailable")
    }

    @MainActor
    @Test func disablingDomainsRemovesAuthorizationBeforeStoppingDaemonListeners() async throws {
        let key = AppStore.domainsEnabledKey
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let removal = AuthorizedNetworkingRemovalRecorder()
        let trust = LocalCATrustRemovalRecorder()
        let launchAgent = LaunchAgentConfigurationRecorder()
        let store = AppStore(
            dorydLaunchAgentEnsurer: { configuration in launchAgent.ensure(configuration) },
            authorizedNetworkingRemover: { try removal.remove() },
            localCATrustManager: trust
        )

        store.applyNetworkingSettings(domainsEnabled: false)
        try await waitUntil { !store.networkingAuthorizationInFlight }

        #expect(removal.callCount == 1)
        #expect(trust.removeCallCount == 1)
        #expect(launchAgent.configurations.map(\.domainsEnabled) == [false])
        #expect(!store.domainsEnabled)
        #expect(UserDefaults.standard.object(forKey: key) as? Bool == false)
        #expect(store.networkingAuthorizationMessage == "Local domains and their system routing are disabled.")
    }

    @MainActor
    @Test func failedDomainAuthorizationRemovalKeepsDaemonNetworkingEnabled() async throws {
        let key = AppStore.domainsEnabledKey
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let removal = AuthorizedNetworkingRemovalRecorder(fails: true)
        let trust = LocalCATrustRemovalRecorder()
        let launchAgent = LaunchAgentConfigurationRecorder()
        let store = AppStore(
            dorydLaunchAgentEnsurer: { configuration in launchAgent.ensure(configuration) },
            authorizedNetworkingRemover: { try removal.remove() },
            localCATrustManager: trust
        )

        store.applyNetworkingSettings(domainsEnabled: false)
        try await waitUntil { !store.networkingAuthorizationInFlight }

        #expect(removal.callCount == 1)
        #expect(trust.removeCallCount == 0)
        #expect(launchAgent.configurations.map(\.domainsEnabled) == [true])
        #expect(store.domainsEnabled)
        #expect(UserDefaults.standard.object(forKey: key) as? Bool == true)
        #expect(store.networkingAuthorizationMessage?.contains("stayed enabled") == true)
    }

    @MainActor
    @Test func failedLocalCATrustCleanupStillLeavesDomainsSafelyDisabled() async throws {
        let key = AppStore.domainsEnabledKey
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let removal = AuthorizedNetworkingRemovalRecorder()
        let trust = LocalCATrustRemovalRecorder(fails: true)
        let launchAgent = LaunchAgentConfigurationRecorder()
        let store = AppStore(
            dorydLaunchAgentEnsurer: { configuration in launchAgent.ensure(configuration) },
            authorizedNetworkingRemover: { try removal.remove() },
            localCATrustManager: trust
        )

        store.applyNetworkingSettings(domainsEnabled: false)
        try await waitUntil { !store.networkingAuthorizationInFlight }

        #expect(removal.callCount == 1)
        #expect(trust.removeCallCount == 1)
        #expect(!store.domainsEnabled)
        #expect(store.networkingAuthorizationMessage?.contains("login keychain") == true)
        #expect(store.settingsNotice?.kind == .failure)
    }

    @MainActor
    @Test func rejectedDomainDisableRestoresEnabledDaemonConfiguration() async throws {
        let key = AppStore.domainsEnabledKey
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let removal = AuthorizedNetworkingRemovalRecorder()
        let trust = LocalCATrustRemovalRecorder()
        let launchAgent = LaunchAgentConfigurationRecorder(rejectDisabledDomains: true)
        let store = AppStore(
            dorydLaunchAgentEnsurer: { configuration in launchAgent.ensure(configuration) },
            authorizedNetworkingRemover: { try removal.remove() },
            localCATrustManager: trust
        )

        store.applyNetworkingSettings(domainsEnabled: false)
        try await waitUntil { !store.networkingAuthorizationInFlight }

        #expect(removal.callCount == 1)
        #expect(trust.removeCallCount == 1)
        #expect(launchAgent.configurations.map(\.domainsEnabled) == [false, true])
        #expect(store.domainsEnabled)
        #expect(store.networkingAuthorizationMessage?.contains("Reauthorize") == true)
    }

    @MainActor
    @Test func idleSettingsShowInAppNoticeOnSuccess() async throws {
        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService()
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true
        )
        store.runtimeMode = "manual"

        await store.setRuntimeMode("auto-idle")

        #expect(store.runtimeMode == "auto-idle")
        #expect(store.settingsNotice?.kind == .success)
        #expect(store.settingsNotice?.message == "Auto-Idle applied.")
    }

#if DEBUG
    @MainActor
    @Test func appStoreDoesNotMakeIdleSleepDecisionForDorydEngine() async throws {
        let base = "/tmp/dasid-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let socketPath = base + "/doryd.sock"
        defer { try? FileManager.default.removeItem(atPath: base) }

        let shim = DockerShim(runtime: MockRuntime())
        let dockerServer = ShimHTTPServer(socketPath: socketPath) { request in
            await shim.handle(request)
        }
        try dockerServer.start()
        defer { dockerServer.stop() }

        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(socketPath: socketPath)
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true
        )
        store.routeDockerCLI = false

        await store.connectBackend()
        store.containers = []
        store.runtimeMode = "auto-idle"
        store.idlePolicy = IdlePolicy(sleepAfterMinutes: 1)
        store.engineSleeping = false
        store.engineRunning = true
        store.loadState = .ready
        store.engineActivity.setLastForTests(Date(timeIntervalSinceNow: -120))

        await store.evaluateIdleSleepForTests()

        #expect(service.engineSleepCount == 0)
        #expect(!store.engineSleeping)
    }
#endif
}

private enum WorkloadStartFixtureError: LocalizedError {
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .rejected(let id): "fixture rejected start for \(id)"
        }
    }
}

private actor WorkloadStartRecorder {
    private(set) var startedIDs: [String] = []
    private let failingIDs: Set<String>

    init(failingIDs: Set<String> = []) {
        self.failingIDs = failingIDs
    }

    func recordStart(_ id: String) throws {
        startedIDs.append(id)
        if failingIDs.contains(id) {
            throw WorkloadStartFixtureError.rejected(id)
        }
    }
}

private struct RecordingWorkloadRuntime: ContainerRuntime {
    let kind: RuntimeKind = .mock
    let recorder: WorkloadStartRecorder

    func snapshot() async throws -> RuntimeSnapshot { try await MockRuntime().snapshot() }
    func start(containerID: String) async throws { try await recorder.recordStart(containerID) }
    func stop(containerID: String) async throws {}
    func restart(containerID: String) async throws {}
    func remove(containerID: String) async throws {}
    func pull(image: String, registryAuth: String?) async throws {}
    func create(_ spec: ContainerSpec) async throws -> String { "recording-\(spec.name)" }
    func exec(containerID: String, command: [String]) async throws -> ExecResult {
        ExecResult(exitCode: 0, output: "")
    }
    func createNetwork(name: String, labels: [String: String]) async throws {}
    func removeNetwork(name: String) async throws {}
    func removeVolume(name: String) async throws {}
    func logs(containerID: String) async throws -> [LogLine] { [] }
    func env(containerID: String) async throws -> [EnvVar] { [] }
}

private final class LaunchAgentConfigurationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let rejectAMD64: Bool
    private let rejectDisabledDomains: Bool
    private var recorded: [DorydLaunchAgent.Configuration] = []

    init(rejectAMD64: Bool = false, rejectDisabledDomains: Bool = false) {
        self.rejectAMD64 = rejectAMD64
        self.rejectDisabledDomains = rejectDisabledDomains
    }

    var configurations: [DorydLaunchAgent.Configuration] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func ensure(_ configuration: DorydLaunchAgent.Configuration) -> Bool {
        lock.lock()
        recorded.append(configuration)
        lock.unlock()
        return !(rejectAMD64 && configuration.amd64EmulationEnabled)
            && !(rejectDisabledDomains && !configuration.domainsEnabled)
    }
}

private final class AuthorizedNetworkingRemovalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let fails: Bool
    private var calls = 0

    init(fails: Bool = false) {
        self.fails = fails
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func remove() throws {
        lock.lock()
        calls += 1
        lock.unlock()
        if fails { throw AuthorizedNetworkingRemovalError.injectedFailure }
    }
}

private final class LocalCATrustRemovalRecorder: LocalCATrustManaging, @unchecked Sendable {
    private let lock = NSLock()
    private let fails: Bool
    private var removeCalls = 0

    init(fails: Bool = false) {
        self.fails = fails
    }

    var removeCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return removeCalls
    }

    func install(certificateAt path: String) throws -> Bool { false }

    func remove(certificateAt path: String) throws -> Bool {
        lock.lock()
        removeCalls += 1
        lock.unlock()
        if fails { throw LocalCATrustRemovalError.injectedFailure }
        return true
    }
}

private enum LocalCATrustRemovalError: Error {
    case injectedFailure
}

private enum AuthorizedNetworkingRemovalError: Error {
    case injectedFailure
}

private final class FakeDorydService: NSObject, DorydControlXPC {
    let socketPath: String
    let engineShutdownReplyDelay: TimeInterval
    private let lock = NSLock()
    private var _engineStartCount = 0
    private var _engineStopCount = 0
    private var _engineWakeCount = 0
    private var _engineSleepCount = 0
    private var _engineState = "running"
    private var _engineDetail = "ok"
    private var _engineStartOK = true
    private var _engineStartMessage = ""
    private var _idleAvailable = true
    private var idleMode = "always-on"
    private var idlePolicy: [String: Any] = [
        "sleepAfterMinutes": 15,
        "keepPublishedPortsAwake": true,
        "keepKubernetesAwake": true,
        "keepPinnedProjectsAwake": true,
        "showWakeNotifications": true,
    ]
    private var networkRouteBatches: [[DorydDomainRoute]] = []
    private var _repairTargets: [String] = []
    private var machines: [String: NSDictionary] = [
        "dev": FakeDorydService.machineRow(
            id: "dev",
            state: "running",
            pid: 1234,
            agentBuild: "agent-test",
            handoffFDCount: 2,
            address: "192.168.215.40",
            displayMode: "desktop",
            shares: [
                [
                    "tag": "src",
                    "hostPath": "/Users/me/src",
                    "guestPath": "/workspace/src",
                    "readOnly": true,
                ] as NSDictionary,
            ],
            environment: [
                [
                    "key": "ANTHROPIC_API_KEY",
                    "value": "test-token",
                ] as NSDictionary,
            ]
        )
    ]
    private var _machineStartCount = 0
    private var _machineStopCount = 0
    private var _machineDeleteCount = 0
    private var _machineDeleteOK = true
    private var _machineDeleteMessage = ""
    private var _machineCreateCount = 0
    private var _machineUpdateCount = 0
    private var _machineProvisionCount = 0
    private var _machineProvisionOK = true
    private var _machineProvisionMessage = ""
    private var _machineSnapshotCount = 0
    private var _machineCloneSnapshotCount = 0
    private var _machineCloneSnapshotOK = true
    private var _machineCloneSnapshotMessage = ""
    private var _machineCloneSnapshotDuplicateFailures = 0
    private var _machineRestoreSnapshotCount = 0
    private var _machineDeleteSnapshotCount = 0
    private var _latestMachineCreateConfig: NSDictionary?
    private var _latestMachineUpdateConfig: NSDictionary?
    private var _latestMachineProvisionRecipe: String?
    private var snapshots: [String: [NSDictionary]] = [:]
    private var backupStatuses: [String: NSDictionary] = [:]
    var engineStartCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _engineStartCount
    }
    var engineStopCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _engineStopCount
    }
    var engineWakeCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _engineWakeCount
    }
    var engineSleepCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _engineSleepCount
    }
    var machineStartCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _machineStartCount
    }
    var machineStopCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _machineStopCount
    }
    var machineDeleteCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _machineDeleteCount
    }
    var machineCreateCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _machineCreateCount
    }
    var machineUpdateCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _machineUpdateCount
    }
    var machineProvisionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _machineProvisionCount
    }
    var machineSnapshotCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _machineSnapshotCount
    }
    var machineCloneSnapshotCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _machineCloneSnapshotCount
    }
    var machineRestoreSnapshotCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _machineRestoreSnapshotCount
    }
    var machineDeleteSnapshotCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _machineDeleteSnapshotCount
    }
    var latestMachineCreateConfig: NSDictionary? {
        lock.lock(); defer { lock.unlock() }
        return _latestMachineCreateConfig
    }
    var latestMachineUpdateConfig: NSDictionary? {
        lock.lock(); defer { lock.unlock() }
        return _latestMachineUpdateConfig
    }
    var latestMachineProvisionRecipe: String? {
        lock.lock(); defer { lock.unlock() }
        return _latestMachineProvisionRecipe
    }
    var repairTargets: [String] {
        lock.lock(); defer { lock.unlock() }
        return _repairTargets
    }
    var latestNetworkRoutes: [DorydDomainRoute] {
        lock.lock(); defer { lock.unlock() }
        return networkRouteBatches.last ?? []
    }

    init(
        socketPath: String = "/tmp/doryd-test.sock",
        engineShutdownReplyDelay: TimeInterval = 0
    ) {
        self.socketPath = socketPath
        self.engineShutdownReplyDelay = engineShutdownReplyDelay
    }

    func setEngineStatus(_ state: String, detail: String = "ok") {
        lock.lock()
        _engineState = state
        _engineDetail = detail
        lock.unlock()
    }

    func setEngineStartResult(ok: Bool, message: String = "") {
        lock.lock()
        _engineStartOK = ok
        _engineStartMessage = message
        lock.unlock()
    }

    func setMachineProvisionResult(ok: Bool, message: String = "") {
        lock.lock()
        _machineProvisionOK = ok
        _machineProvisionMessage = message
        lock.unlock()
    }

    func setMachineDeleteResult(ok: Bool, message: String = "") {
        lock.lock()
        _machineDeleteOK = ok
        _machineDeleteMessage = message
        lock.unlock()
    }

    func setMachineCloneSnapshotResult(ok: Bool, message: String = "") {
        lock.lock()
        _machineCloneSnapshotOK = ok
        _machineCloneSnapshotMessage = message
        lock.unlock()
    }

    func setMachineCloneSnapshotDuplicateFailures(_ count: Int) {
        lock.lock()
        _machineCloneSnapshotDuplicateFailures = max(0, count)
        lock.unlock()
    }

    func setIdleAvailable(_ available: Bool) {
        lock.lock()
        _idleAvailable = available
        lock.unlock()
    }

    func setIdleMode(_ mode: String) {
        lock.lock()
        idleMode = mode
        lock.unlock()
    }

    func protocolVersion(reply: @escaping (UInt32) -> Void) {
        reply(1)
    }

    func dorySocketPath(reply: @escaping (String) -> Void) {
        reply(socketPath)
    }

    func engineStatus(reply: @escaping (String, String) -> Void) {
        lock.lock()
        let state = _engineState
        let detail = _engineDetail
        lock.unlock()
        reply(state, detail)
    }

    func engineStart(reply: @escaping (Bool, String) -> Void) {
        lock.lock()
        _engineStartCount += 1
        let ok = _engineStartOK
        let message = _engineStartMessage
        if ok {
            _engineState = "running"
            _engineDetail = "ok"
        }
        lock.unlock()
        reply(ok, message)
    }

    func engineStop(reply: @escaping (Bool, String) -> Void) {
        if engineShutdownReplyDelay > 0 {
            Thread.sleep(forTimeInterval: engineShutdownReplyDelay)
        }
        lock.lock()
        _engineStopCount += 1
        _engineState = "stopped"
        _engineDetail = "stopped"
        lock.unlock()
        reply(true, "")
    }

    func engineSleep(reply: @escaping (Bool, String) -> Void) {
        if engineShutdownReplyDelay > 0 {
            Thread.sleep(forTimeInterval: engineShutdownReplyDelay)
        }
        lock.lock(); _engineSleepCount += 1; lock.unlock()
        reply(true, "")
    }

    func engineWake(reply: @escaping (Bool, String) -> Void) {
        lock.lock(); _engineWakeCount += 1; lock.unlock()
        reply(true, "")
    }

    func dockerAgentInfo(reply: @escaping (NSDictionary, String) -> Void) {
        reply(dockerAgentInfo(), "")
    }

    func dockerAgentPorts(reply: @escaping (NSDictionary, String) -> Void) {
        let port: NSDictionary = ["protocol": "tcp", "port": 8080]
        reply([
            "ports": [port],
            "added": [port],
            "removed": [],
        ] as NSDictionary, "")
    }

    func dockerAgentTelemetry(reply: @escaping (NSDictionary, String) -> Void) {
        reply(dockerTelemetry(), "")
    }

    func machineCreate(_ config: NSDictionary, reply: @escaping (Bool, NSDictionary, String) -> Void) {
        let id = config["id"] as? String ?? ""
        let row = Self.machineRow(
            id: id,
            state: "created",
            memoryMB: Self.uint64(config["memoryMB"]) ?? 2048,
            cpuCount: Self.int(config["cpuCount"]) ?? 2,
            address: config["address"] as? String,
            displayMode: config["displayMode"] as? String ?? "headless",
            shares: Self.shareRows(config["shares"]),
            environment: Self.environmentRows(config["env"])
        )
        lock.lock()
        _machineCreateCount += 1
        _latestMachineCreateConfig = config
        machines[id] = row
        lock.unlock()
        reply(true, row, "")
    }

    func machineStart(_ machineID: String, reply: @escaping (Bool, NSDictionary, String) -> Void) {
        lock.lock()
        let current = machines[machineID]
        let row = Self.machineRow(
            id: machineID,
            state: "running",
            pid: 1234,
            agentBuild: "agent-test",
            handoffFDCount: 2,
            memoryMB: Self.uint64(current?["memoryMB"]) ?? 2048,
            cpuCount: Self.int(current?["cpuCount"]) ?? 2,
            address: current?["address"] as? String,
            displayMode: current?["displayMode"] as? String ?? "headless",
            shares: Self.shareRows(current?["shares"]),
            environment: Self.environmentRows(current?["env"])
        )
        _machineStartCount += 1
        machines[machineID] = row
        lock.unlock()
        reply(true, row, "")
    }

    func machineStop(_ machineID: String, reply: @escaping (Bool, NSDictionary, String) -> Void) {
        lock.lock()
        let current = machines[machineID]
        let row = Self.machineRow(
            id: machineID,
            state: "stopped",
            memoryMB: Self.uint64(current?["memoryMB"]) ?? 2048,
            cpuCount: Self.int(current?["cpuCount"]) ?? 2,
            address: current?["address"] as? String,
            displayMode: current?["displayMode"] as? String ?? "headless",
            shares: Self.shareRows(current?["shares"]),
            environment: Self.environmentRows(current?["env"])
        )
        _machineStopCount += 1
        machines[machineID] = row
        lock.unlock()
        reply(true, row, "")
    }

    func machineUpdate(_ machineID: String, config: NSDictionary, reply: @escaping (Bool, NSDictionary, String) -> Void) {
        lock.lock()
        _machineUpdateCount += 1
        _latestMachineUpdateConfig = config
        let current = machines[machineID] ?? Self.machineRow(id: machineID, state: "stopped")
        let memoryMB = (config["memoryMB"] as? NSNumber)?.uint64Value
            ?? config["memoryMB"] as? UInt64
            ?? (current["memoryMB"] as? NSNumber)?.uint64Value
            ?? current["memoryMB"] as? UInt64
            ?? 2048
        let cpuCount = (config["cpuCount"] as? NSNumber)?.intValue
            ?? config["cpuCount"] as? Int
            ?? (current["cpuCount"] as? NSNumber)?.intValue
            ?? current["cpuCount"] as? Int
            ?? 2
        let address = config["address"] == nil ? current["address"] as? String : config["address"] as? String
        let shares = config["shares"] == nil ? Self.shareRows(current["shares"]) : Self.shareRows(config["shares"])
        let environment = config["env"] == nil ? Self.environmentRows(current["env"]) : Self.environmentRows(config["env"])
        let state = current["state"] as? String ?? "stopped"
        let row = Self.machineRow(
            id: machineID,
            state: state,
            pid: current["pid"] as? Int32,
            agentBuild: current["agentBuild"] as? String,
            handoffFDCount: (current["handoffFDCount"] as? Int) ?? 0,
            memoryMB: memoryMB,
            cpuCount: cpuCount,
            address: address,
            displayMode: current["displayMode"] as? String ?? "headless",
            shares: shares,
            environment: environment
        )
        machines[machineID] = row
        lock.unlock()
        reply(true, row, "")
    }

    func machineDelete(_ machineID: String, reply: @escaping (Bool, String) -> Void) {
        lock.lock()
        _machineDeleteCount += 1
        let ok = _machineDeleteOK
        let message = _machineDeleteMessage
        if ok {
            machines.removeValue(forKey: machineID)
        }
        lock.unlock()
        reply(ok, message)
    }

    func machineList(reply: @escaping (NSArray, String) -> Void) {
        lock.lock()
        let rows = machines.keys.sorted().compactMap { machines[$0] }
        lock.unlock()
        reply(rows as NSArray, "")
    }

    func machineStats(_ machineID: String, reply: @escaping (Bool, NSDictionary, String) -> Void) {
        lock.lock()
        let total = (Self.uint64(machines[machineID]?["memoryMB"]) ?? 2048) * 1_048_576
        lock.unlock()
        reply(true, [
            "schema": "dev.dory.machine.stats",
            "version": 1,
            "cpuPercent": 12.5,
            "memoryUsedBytes": total / 2,
            "memoryTotalBytes": total,
            "networkReceiveBytes": UInt64(100),
            "networkTransmitBytes": UInt64(200),
            "blockReadBytes": UInt64(300),
            "blockWriteBytes": UInt64(400),
            "processCount": UInt64(12),
            "uptimeSeconds": 98.765,
        ] as NSDictionary, "")
    }

    func machineExec(_ machineID: String, request: NSDictionary, reply: @escaping (Bool, NSDictionary, String) -> Void) {
        reply(true, Self.execRow(stdout: "cargo 1.0\n"), "")
    }

    func machineProvision(_ machineID: String, request: NSDictionary, reply: @escaping (Bool, NSDictionary, String) -> Void) {
        let recipe = request["recipe"] as? String ?? "rust"
        lock.lock()
        _machineProvisionCount += 1
        _latestMachineProvisionRecipe = recipe
        let ok = _machineProvisionOK
        let message = _machineProvisionMessage
        lock.unlock()
        guard ok else {
            reply(false, [:], message)
            return
        }
        reply(true, [
            "recipeID": recipe,
            "install": Self.execRow(stdout: "installed \(recipe)\n"),
            "verify": Self.execRow(stdout: "cargo 1.0\n"),
        ] as NSDictionary, "")
    }

    func machineSnapshot(_ machineID: String, request: NSDictionary, reply: @escaping (Bool, NSDictionary, String) -> Void) {
        let id = request["snapshotID"] as? String ?? "s\(UUID().uuidString.prefix(8).lowercased())"
        let row = Self.snapshotRow(
            id: id,
            machineID: machineID,
            note: request["note"] as? String ?? "",
            createdISO: request["createdISO"] as? String ?? "2026-07-07T00:00:00Z"
        )
        lock.lock()
        _machineSnapshotCount += 1
        snapshots[machineID, default: []].insert(row, at: 0)
        lock.unlock()
        reply(true, row, "")
    }

    func machineSnapshots(_ machineID: String, reply: @escaping (NSArray, String) -> Void) {
        lock.lock()
        let rows: [NSDictionary]
        if machineID.isEmpty {
            rows = snapshots.keys.sorted().flatMap { snapshots[$0] ?? [] }
        } else {
            rows = snapshots[machineID] ?? []
        }
        lock.unlock()
        reply(rows as NSArray, "")
    }

    func machineCloneSnapshot(
        _ machineID: String,
        snapshotID: String,
        newID: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        let row = Self.machineRow(id: newID, state: "running", pid: 1234, agentBuild: "agent-test", handoffFDCount: 2)
        lock.lock()
        _machineCloneSnapshotCount += 1
        if _machineCloneSnapshotDuplicateFailures > 0 {
            _machineCloneSnapshotDuplicateFailures -= 1
            lock.unlock()
            reply(false, [:], "machine already exists: \(newID)")
            return
        }
        let ok = _machineCloneSnapshotOK
        let message = _machineCloneSnapshotMessage
        if ok {
            machines[newID] = row
        }
        lock.unlock()
        reply(ok, ok ? row : [:], message)
    }

    func machineRestoreSnapshot(_ machineID: String, snapshotID: String, reply: @escaping (Bool, NSDictionary, String) -> Void) {
        let row = Self.machineRow(id: machineID, state: "running", pid: 1234, agentBuild: "agent-test", handoffFDCount: 2)
        lock.lock()
        _machineRestoreSnapshotCount += 1
        machines[machineID] = row
        lock.unlock()
        reply(true, row, "")
    }

    func machineDeleteSnapshot(_ machineID: String, snapshotID: String, reply: @escaping (Bool, String) -> Void) {
        lock.lock()
        _machineDeleteSnapshotCount += 1
        snapshots[machineID, default: []].removeAll { $0["id"] as? String == snapshotID }
        lock.unlock()
        reply(true, "")
    }

    func machineExportSnapshot(_ machineID: String, snapshotID: String, path: String, reply: @escaping (Bool, String) -> Void) {
        reply(true, "")
    }

    func machineImportSnapshot(_ path: String, reply: @escaping (Bool, NSDictionary, String) -> Void) {
        let row = Self.snapshotRow(
            id: "imported",
            machineID: "dev",
            note: "imported",
            createdISO: "2026-07-07T00:00:00Z"
        )
        lock.lock()
        snapshots["dev", default: []].insert(row, at: 0)
        lock.unlock()
        reply(true, row, "")
    }

    func machineBackupSchedules(reply: @escaping (NSArray, String) -> Void) {
        lock.lock()
        let rows = backupStatuses.keys.sorted().compactMap { backupStatuses[$0] }
        lock.unlock()
        reply(rows as NSArray, "")
    }

    func machineBackupSet(_ schedule: NSDictionary, reply: @escaping (Bool, NSDictionary, String) -> Void) {
        guard let machineID = schedule["machineID"] as? String,
              let frequency = schedule["frequency"] as? String else {
            reply(false, [:], "invalid backup schedule")
            return
        }
        let row = Self.backupStatusRow(
            machineID: machineID,
            frequency: frequency,
            keepLocal: Self.int(schedule["keepLocal"]) ?? 7,
            verifyEveryRuns: Self.int(schedule["verifyEveryRuns"]) ?? 7
        )
        lock.lock()
        backupStatuses[machineID] = row
        lock.unlock()
        reply(true, row, "")
    }

    func machineBackupRemove(_ machineID: String, reply: @escaping (Bool, String) -> Void) {
        lock.lock()
        backupStatuses.removeValue(forKey: machineID)
        lock.unlock()
        reply(true, "")
    }

    func machineBackupRun(_ machineID: String, reply: @escaping (Bool, NSDictionary, String) -> Void) {
        lock.lock()
        let current = backupStatuses[machineID]
        let row = Self.backupStatusRow(
            machineID: machineID,
            frequency: current?["frequency"] as? String ?? "daily",
            keepLocal: Self.int(current?["keepLocal"]) ?? 7,
            verifyEveryRuns: Self.int(current?["verifyEveryRuns"]) ?? 7,
            successfulRuns: (Self.int(current?["successfulRuns"]) ?? 0) + 1,
            verified: true
        )
        backupStatuses[machineID] = row
        lock.unlock()
        reply(true, row, "")
    }

    func remoteConnect(_ config: NSDictionary, reply: @escaping (Bool, NSDictionary, String) -> Void) {
        reply(true, agentInfo(), "")
    }

    func remotePush(_ machineID: String, localRoot: String, remoteRoot: String, reply: @escaping (Bool, NSDictionary, String) -> Void) {
        reply(true, [
            "filesSent": 2,
            "bytesSent": 30,
            "filesDeleted": 1,
        ], "")
    }

    func remoteStatus(_ machineID: String, reply: @escaping (NSDictionary, String) -> Void) {
        reply([
            "id": machineID,
            "state": "connected",
            "lastError": "",
            "info": agentInfo(),
            "telemetry": telemetry(),
        ], "")
    }

    func networkReplaceRoutes(_ routes: NSArray, reply: @escaping (Bool, String) -> Void) {
        let decoded = routes.compactMap(Self.domainRoute)
        guard decoded.count == routes.count else {
            reply(false, "invalid routes")
            return
        }
        lock.lock(); networkRouteBatches.append(decoded); lock.unlock()
        reply(true, "")
    }

    func networkStatus(reply: @escaping (NSDictionary, String) -> Void) {
        let customRoutes = latestNetworkRoutes
        let routes = customRoutes.isEmpty
            ? [DorydDomainRoute(hostname: "web.dory.local", address: "127.0.0.42", port: 8080)]
            : customRoutes
        reply([
            "mode": "high-port-dns-http-https-proxy",
            "suffix": "dory.local",
            "dnsBindAddress": "127.0.0.1",
            "dnsPort": 15353,
            "dnsRunning": true,
            "httpProxyPort": 18080,
            "httpProxyRunning": true,
            "httpsProxyPort": 18443,
            "httpsProxyRunning": true,
            "routes": routes.map(Self.dictionary),
            "customRoutes": customRoutes.map(Self.dictionary),
        ] as NSDictionary, "")
    }

    func networkAuthorizationPlan(reply: @escaping (NSDictionary, String) -> Void) {
        reply([
            "degradedMode": "high-port-dns-only",
            "authorizedMode": "system-resolver-proxy-tls",
            "suffix": "dory.local",
            "dnsBindAddress": "127.0.0.1",
            "dnsPort": 15353,
            "httpProxyPort": 18080,
            "httpsProxyPort": 18443,
            "privilegedTCPForwards": [
                [
                    "listenPort": 25,
                    "targetPort": 1025,
                ],
            ],
            "requests": [
                [
                    "id": "resolver.dory.local",
                    "kind": "resolverFile",
                    "title": "Install dory.local resolver",
                    "reason": "Route local domains to doryd.",
                    "requiresAdmin": true,
                    "filePath": "/etc/resolver/dory.local",
                    "fileContents": "nameserver 127.0.0.1\nport 15353\n",
                    "command": ["/usr/bin/install", "-m", "0644", "<generated>", "/etc/resolver/dory.local"],
                ],
            ],
        ] as NSDictionary, "")
    }

    func corporateConnectivityStatus(
        _ runProbes: Bool,
        reply: @escaping (String, String) -> Void
    ) {
        reply(
            """
            {"schemaVersion":1,"enabled":false,"profile":null,"proxyReachable":null,"registryReachable":null,"certificateInstalled":false,"lastCheckedAt":null,"diagnostics":[]}
            """,
            ""
        )
    }

    func corporateConnectivityApply(
        _ profileJSON: String,
        dryRun: Bool,
        reply: @escaping (String, String) -> Void
    ) {
        reply(profileJSON, "")
    }

    func corporateConnectivityDisable(reply: @escaping (String, String) -> Void) {
        corporateConnectivityStatus(false, reply: reply)
    }

    func repairSubsystem(_ target: String, reply: @escaping (Bool, String) -> Void) {
        lock.lock(); _repairTargets.append(target); lock.unlock()
        reply(true, "repaired \(target)")
    }

    func balloonStatus(reply: @escaping (NSDictionary, String) -> Void) {
        let target: NSDictionary = [
            "id": "docker",
            "kind": "docker",
            "currentTargetMB": 2048,
            "targetMB": 1536,
            "reason": "hostWarning",
            "canApply": true,
        ]
        reply([
            "host": [
                "totalBytes": 16_000_000_000,
                "availableBytes": 1_000_000_000,
                "freeBytes": 500_000_000,
                "availableRatio": 0.0625,
                "pressure": "warning",
            ],
            "targets": [target],
            "applicableTargets": [target],
        ] as NSDictionary, "")
    }

    func balloonReconcile(reply: @escaping (NSDictionary, String) -> Void) {
        balloonStatus(reply: reply)
    }

    func idleStatus(reply: @escaping (NSDictionary, String) -> Void) {
        guard idleAvailable else {
            reply([:], "idle unavailable")
            return
        }
        reply(idleStatusDictionary(), "")
    }

    func idleHistory(_ limit: Int, reply: @escaping (NSArray, String) -> Void) {
        let rows: [NSDictionary] = [
            [
                "at": "2026-07-07T00:00:00Z",
                "state": "sleeping",
                "detail": "idle",
            ] as NSDictionary
        ]
        reply(Array(rows.suffix(max(0, limit))) as NSArray, "")
    }

    func idleSetMode(_ mode: String, reply: @escaping (Bool, NSDictionary, String) -> Void) {
        guard idleAvailable else {
            reply(false, [:], "idle unavailable")
            return
        }
        lock.lock()
        idleMode = mode
        lock.unlock()
        reply(true, idleStatusDictionary(), "")
    }

    func idleSetPolicy(_ key: String, value: String, reply: @escaping (Bool, NSDictionary, String) -> Void) {
        guard idleAvailable else {
            reply(false, [:], "idle unavailable")
            return
        }
        lock.lock()
        switch key {
        case "sleepAfterMinutes":
            idlePolicy[key] = Int(value) ?? 15
        default:
            idlePolicy[key] = ["1", "true", "yes", "on"].contains(value.lowercased())
        }
        lock.unlock()
        reply(true, idleStatusDictionary(), "")
    }

    func health(reply: @escaping (NSDictionary, String) -> Void) {
        reply([
            "results": [
                [
                    "id": "socket.exists",
                    "status": "pass",
                    "code": "SOCKET_OK",
                    "title": "Socket",
                    "detail": "ok",
                ],
                [
                    "id": "machine.local",
                    "status": "pass",
                    "code": "machine.running",
                    "title": "Local machine running",
                    "detail": "dev=running",
                ],
            ],
        ] as NSDictionary, "")
    }

    func doctorJSON(reply: @escaping (String, String) -> Void) {
        reply(
            """
            {"results":[{"id":"socket.exists","status":"pass","code":"SOCKET_OK","title":"Socket","detail":"ok","action":null}]}
            """,
            ""
        )
    }

    func incidents(_ limit: Int, reply: @escaping (NSArray, String) -> Void) {
        reply([
            [
                "at": "2026-07-07T00:00:00Z",
                "type": "engine.start",
                "detail": "started",
            ]
        ] as NSArray, "")
    }

    private func idleStatusDictionary() -> NSDictionary {
        lock.lock()
        let mode = idleMode
        let policy = idlePolicy
        lock.unlock()
        return [
            "generated_at": "2026-07-07T00:00:00Z",
            "mode": mode,
            "auto_idle_enabled": mode == "auto-idle" || mode == "battery-saver",
            "sleep_after_minutes": policy["sleepAfterMinutes"] ?? 15,
            "can_sleep": true,
            "blockers": [],
            "engine_state": [
                "available": true,
                "owner": "doryd",
                "state": "running",
            ],
            "policy": policy,
        ] as NSDictionary
    }

    private var idleAvailable: Bool {
        lock.lock(); defer { lock.unlock() }
        return _idleAvailable
    }

    private func dockerAgentInfo() -> NSDictionary {
        [
            "protocolVersion": 1,
            "kernel": "Linux docker",
            "agentBuild": "docker-agent",
            "uptimeSeconds": 11,
        ]
    }

    private func dockerTelemetry() -> NSDictionary {
        [
            "memTotalKB": 2048,
            "memAvailableKB": 1024,
            "psiSomeAvg10": 0.2,
            "psiFullAvg10": 0.0,
        ]
    }

    private func agentInfo() -> NSDictionary {
        [
            "protocolVersion": 1,
            "kernel": "Linux test",
            "agentBuild": "remote-agent",
            "uptimeSeconds": 9,
        ]
    }

    private func telemetry() -> NSDictionary {
        [
            "memTotalKB": 1024,
            "memAvailableKB": 512,
            "psiSomeAvg10": 0.1,
            "psiFullAvg10": 0.0,
        ]
    }

    private static func machineRow(
        id: String,
        state: String,
        pid: Int32? = nil,
        agentBuild: String? = nil,
        handoffFDCount: Int = 0,
        memoryMB: UInt64 = 2048,
        cpuCount: Int = 2,
        address: String? = nil,
        displayMode: String = "headless",
        shares: [NSDictionary] = [],
        environment: [NSDictionary] = []
    ) -> NSDictionary {
        var row: [String: Any] = [
            "id": id,
            "state": state,
            "lastError": "",
            "handoffFDCount": handoffFDCount,
            "memoryMB": memoryMB,
            "cpuCount": cpuCount,
            "displayMode": displayMode,
        ]
        if let pid { row["pid"] = pid }
        if let agentBuild {
            row["agentBuild"] = agentBuild
            row["handoffSocketPath"] = "/tmp/handoff.sock"
            row["agentSocketPath"] = "/tmp/agent.sock"
            row["dockerdSocketPath"] = "/tmp/dockerd.sock"
            row["shellSocketPath"] = "/tmp/shell.sock"
        }
        if let address {
            row["address"] = address
            row["configuredAddress"] = address
        }
        row["shares"] = shares
        row["env"] = environment
        return row as NSDictionary
    }

    private static func shareRows(_ value: Any?) -> [NSDictionary] {
        if let rows = value as? [NSDictionary] {
            return rows
        }
        if let rows = value as? NSArray {
            return rows.compactMap { $0 as? NSDictionary }
        }
        return []
    }

    private static func environmentRows(_ value: Any?) -> [NSDictionary] {
        if let rows = value as? [NSDictionary] {
            return rows
        }
        if let rows = value as? NSArray {
            return rows.compactMap { $0 as? NSDictionary }
        }
        return []
    }

    private static func uint64(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber { return number.uint64Value }
        return value as? UInt64
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        return value as? Int
    }

    private static func execRow(stdout: String = "", stderr: String = "", exitCode: Int32 = 0) -> NSDictionary {
        [
            "exitCode": exitCode,
            "stdout": stdout,
            "stderr": stderr,
            "timedOut": false,
            "stdoutTruncated": false,
            "stderrTruncated": false,
        ] as NSDictionary
    }

    private static func snapshotRow(id: String, machineID: String, note: String, createdISO: String) -> NSDictionary {
        [
            "id": id,
            "machineID": machineID,
            "note": note,
            "createdISO": createdISO,
            "rootfsPath": "/tmp/\(machineID)-\(id).ext4",
            "sizeBytes": 1024,
            "kernelPath": "/tmp/kernel",
            "architecture": "arm64",
            "memoryMB": 2048,
            "cpuCount": 2,
        ] as NSDictionary
    }

    private static func backupStatusRow(
        machineID: String,
        frequency: String,
        keepLocal: Int,
        verifyEveryRuns: Int,
        successfulRuns: Int = 0,
        verified: Bool = false
    ) -> NSDictionary {
        var row: [String: Any] = [
            "machineID": machineID,
            "enabled": true,
            "frequency": frequency,
            "keepLocal": keepLocal,
            "verifyEveryRuns": verifyEveryRuns,
            "inProgress": false,
            "successfulRuns": successfulRuns,
            "consecutiveFailures": 0,
            "retainedSnapshots": successfulRuns,
            "retainedArchives": successfulRuns,
            "nextRunISO": "2026-07-08T00:00:00Z",
        ]
        if verified {
            row["lastAttemptISO"] = "2026-07-07T00:00:00Z"
            row["lastSuccessISO"] = "2026-07-07T00:00:00Z"
            row["lastVerificationISO"] = "2026-07-07T00:00:00Z"
            row["lastBootVerificationISO"] = "2026-07-07T00:00:00Z"
            row["lastSnapshotID"] = "scheduled-1"
            row["lastArchivePath"] = "/tmp/dev.dorymachine"
        }
        return row as NSDictionary
    }

    private static func domainRoute(_ value: Any) -> DorydDomainRoute? {
        guard let dictionary = value as? NSDictionary,
              let hostname = dictionary["hostname"] as? String,
              let address = dictionary["address"] as? String else {
            return nil
        }
        let port: UInt16
        if let number = dictionary["port"] as? NSNumber {
            port = number.uint16Value
        } else if let raw = dictionary["port"] as? UInt16 {
            port = raw
        } else {
            port = 80
        }
        let pathPrefix = dictionary["pathPrefix"] as? String ?? ""
        return DorydDomainRoute(hostname: hostname, address: address, port: port, pathPrefix: pathPrefix)
    }

    private static func dictionary(_ route: DorydDomainRoute) -> NSDictionary {
        var dictionary: [String: Any] = [
            "hostname": route.hostname,
            "address": route.address,
            "port": route.port,
        ]
        if !route.pathPrefix.isEmpty {
            dictionary["pathPrefix"] = route.pathPrefix
        }
        return dictionary as NSDictionary
    }
}

@MainActor
private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
    for _ in 0..<80 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(condition())
}

private final class FakeDorydListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service: FakeDorydService

    init(service: FakeDorydService) {
        self.service = service
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: DorydControlXPC.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

private final class HealthDiagnosticsCLIRunRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCommands: [[String]] = []

    var commands: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return recordedCommands
    }

    func record(_ command: [String]) {
        lock.lock()
        recordedCommands.append(command)
        lock.unlock()
    }
}
