import Darwin
import DoryCore
import DoryOperations
import DoryVMContracts
@testable import DorydKit
import Foundation
import XCTest

final class HealthReporterTests: XCTestCase {
    func testGuestMemoryHealthKeepsLegacyReclaimableKeyDerivedFromMemAvailable() {
        let snapshot = DoryGuestResourceSnapshot(
            selectedDataDriveID: UUID(),
            dataDiskFilesystemUUID: UUID(),
            dataDiskMountSource: "/dev/vdb",
            dataDiskFilesystemType: "ext4",
            dataDiskDeviceMajorMinor: "254:16",
            memoryCeilingBytes: 2_048,
            memoryUsedBytes: 1_024,
            memoryCacheBytes: 416,
            memoryAvailableBytes: 1_024,
            memoryFreeBytes: 512,
            dataDiskTotalBytes: 4_096,
            dataDiskUsedBytes: 1_024,
            dataDiskAvailableBytes: 3_072
        )

        let check = HealthReporter.guestResourceCheck(
            snapshot: snapshot,
            engineRunning: true
        )

        XCTAssertEqual(check.data["memory_available_bytes"], "1024")
        XCTAssertEqual(check.data["memory_reclaimable_bytes"], "512")
    }

    func testFileServiceHealthDistinguishesInactiveBackpressureAndFailStop() {
        XCTAssertEqual(
            HealthReporter.fileServiceResourceCheck(snapshot: nil, engineRunning: false).status,
            .skip
        )
        XCTAssertEqual(
            HealthReporter.fileServiceResourceCheck(snapshot: nil, engineRunning: true).code,
            "resources.file_service_snapshot_unavailable"
        )

        let healthy = healthFileServiceSnapshot()
        let healthyCheck = HealthReporter.fileServiceResourceCheck(
            snapshot: healthy,
            engineRunning: true
        )
        XCTAssertEqual(healthyCheck.status, .pass)
        XCTAssertEqual(healthyCheck.code, "resources.file_service_ok")

        var backpressured = healthy
        backpressured.pendingEventCount = backpressured.pendingEventLimit * 3 / 4
        let backpressureCheck = HealthReporter.fileServiceResourceCheck(
            snapshot: backpressured,
            engineRunning: true
        )
        XCTAssertEqual(backpressureCheck.status, .warn)
        XCTAssertEqual(backpressureCheck.code, "resources.file_service_backpressure")

        var failedClosed = healthy
        failedClosed.eventLossCount = 1
        failedClosed.coherenceTerminalFailureLatched = true
        let failureCheck = HealthReporter.fileServiceResourceCheck(
            snapshot: failedClosed,
            engineRunning: true
        )
        XCTAssertEqual(failureCheck.status, .fail)
        XCTAssertEqual(failureCheck.code, "resources.file_service_failed")
        XCTAssertTrue(failureCheck.action?.contains("failed closed") == true)
    }

    func testPublishedPortHealthRequiresRealTCPListeners() {
        let ports = [
            DoryListenPort(protocol: "tcp", port: 3_809),
            DoryListenPort(protocol: "tcp", port: 8_080),
        ]
        let check = HealthReporter.publishedPortsCheck(
            ports: ports,
            dockerReachable: true,
            tcpListenerProbe: { $0 == 3_809 }
        )

        XCTAssertEqual(check.status, .fail)
        XCTAssertEqual(check.code, "network.port_listener_missing")
        XCTAssertEqual(check.data["tcp_ports"], "2")
        XCTAssertEqual(check.data["missing_tcp_listeners"], "8080")
        XCTAssertTrue(check.action?.contains("dory repair ports --apply") == true)
    }

    func testPublishedPortHealthPassesOnlyAfterEveryTCPListenerAccepts() {
        let check = HealthReporter.publishedPortsCheck(
            ports: [DoryListenPort(protocol: "tcp", port: 3_809)],
            dockerReachable: true,
            tcpListenerProbe: { $0 == 3_809 }
        )

        XCTAssertEqual(check.status, .pass)
        XCTAssertEqual(check.code, "network.port_listeners_ready")
        XCTAssertEqual(check.data["missing_tcp_listeners"], "")
    }

    func testPublishedPortHealthDoesNotCallAnUnverifiedUDPRouteReachable() {
        let check = HealthReporter.publishedPortsCheck(
            ports: [DoryListenPort(protocol: "udp", port: 5_353)],
            dockerReachable: true,
            tcpListenerProbe: { _ in XCTFail("UDP route must not use a TCP probe"); return true }
        )

        XCTAssertEqual(check.status, .warn)
        XCTAssertEqual(check.code, "network.port_listener_unverified")
    }

    func testMachinePortForwardHealthReportsReadyRecoveringAndContractMismatch() throws {
        let ready = HealthReporter.machinePortForwardCheck(
            machineID: "dev",
            state: .running,
            configuredForwards: 2,
            telemetry: { portForwardTelemetry(configured: 2, active: 2, failures: 1) }
        )
        XCTAssertEqual(ready?.status, .pass)
        XCTAssertEqual(ready?.code, "machine.port_forwards.ready")
        XCTAssertEqual(ready?.data["active"], "2")
        XCTAssertEqual(ready?.data["failed_reconciliations"], "1")

        let recovering = HealthReporter.machinePortForwardCheck(
            machineID: "dev",
            state: .paused,
            configuredForwards: 2,
            telemetry: {
                portForwardTelemetry(configured: 2, active: 1, failures: 3)
            }
        )
        XCTAssertEqual(recovering?.status, .warn)
        XCTAssertEqual(recovering?.code, "machine.port_forwards.recovering")
        XCTAssertEqual(recovering?.data["active"], "1")

        let mismatch = HealthReporter.machinePortForwardCheck(
            machineID: "dev",
            state: .running,
            configuredForwards: 2,
            telemetry: { portForwardTelemetry(configured: 1, active: 1, failures: 0) }
        )
        XCTAssertEqual(mismatch?.status, .fail)
        XCTAssertEqual(mismatch?.code, "machine.port_forwards.contract_mismatch")
    }

    func testMachinePortForwardHealthSkipsStoppedAndFailsClosedOnMissingTelemetry() {
        let stopped = HealthReporter.machinePortForwardCheck(
            machineID: "dev",
            state: .stopped,
            configuredForwards: 1,
            telemetry: { throw HealthTestError.unavailable }
        )
        XCTAssertEqual(stopped?.status, .skip)
        XCTAssertEqual(stopped?.code, "machine.port_forwards.inactive")

        let missing = HealthReporter.machinePortForwardCheck(
            machineID: "dev",
            state: .running,
            configuredForwards: 1,
            telemetry: { throw HealthTestError.unavailable }
        )
        XCTAssertEqual(missing?.status, .warn)
        XCTAssertEqual(missing?.code, "machine.port_forwards.telemetry_unavailable")

        XCTAssertNil(HealthReporter.machinePortForwardCheck(
            machineID: "dev",
            state: .running,
            configuredForwards: 0,
            telemetry: { throw HealthTestError.unavailable }
        ))
    }

    func testMachineFlightRecorderHealthPublishesOnlyAvailabilityAndCursor() {
        let ready = HealthReporter.machineFlightRecorderCheck(DoryMachineStatus(
            id: "dev",
            state: .running,
            flightRecorderHeadSequence: 42,
            flightRecorderAvailable: true
        ))
        XCTAssertEqual(ready.status, .pass)
        XCTAssertEqual(ready.code, "machine.flight_recorder.ready")
        XCTAssertEqual(ready.data, ["available": "true", "head_sequence": "42"])

        let unavailable = HealthReporter.machineFlightRecorderCheck(DoryMachineStatus(
            id: "dev",
            state: .failed,
            flightRecorderHeadSequence: 41,
            flightRecorderAvailable: false
        ))
        XCTAssertEqual(unavailable.status, .warn)
        XCTAssertEqual(unavailable.code, "machine.flight_recorder.unavailable")
        XCTAssertFalse(unavailable.detail.contains("/"))
    }

    func testHostDiskRequiresLowPercentageAndLowAbsoluteFreeSpaceToFail() {
        let gib: UInt64 = 1024 * 1024 * 1024
        let total = 1_000 * gib

        let critical = HealthReporter.classifyHostDisk(free: 10 * gib, total: total)
        XCTAssertEqual(critical.status, .fail)
        XCTAssertEqual(critical.code, "disk.host_critical")

        let spaciousLargeDisk = HealthReporter.classifyHostDisk(free: 30 * gib, total: total)
        XCTAssertEqual(spaciousLargeDisk.status, .warn)
        XCTAssertEqual(spaciousLargeDisk.code, "disk.host_low")

        let healthy = HealthReporter.classifyHostDisk(free: 200 * gib, total: total)
        XCTAssertEqual(healthy.status, .pass)
        XCTAssertEqual(healthy.code, "disk.host_ok")
    }

    func testReportUsesDoctorResultShapeForMissingSocketAndUnconfiguredEngine() throws {
        let base = "/tmp/dory-health-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let reporter = HealthReporter(
            socketPath: base + "/missing.sock",
            dockerTier: nil,
            remoteManager: RemoteMachineManager(keyStore: HealthFakeSSHKeyStore()),
            dockerAPIProbe: HealthFakeDockerAPIProbe(result: .unreachable("missing")),
            commandRunner: HealthFakeCommandRunner(),
            registryProbe: HealthFakeRegistryProbe(),
            environment: [
                "PATH": base + "/bin",
                "DORY_CONFIG": base + "/config.json",
                "DORY_DOMAIN_SUFFIX": "dory-test.invalid",
                "DORY_LOG_HARD_MAX_BYTES": "1000",
            ],
            home: base
        )

        let report = reporter.report(now: Date(timeIntervalSince1970: 1))
        let ids = Set(report.results.map(\.id))
        XCTAssertTrue(ids.contains("socket.exists"))
        XCTAssertTrue(ids.contains("socket.ping"))
        XCTAssertTrue(ids.contains("engine.status"))
        XCTAssertTrue(ids.contains("remote.machines"))

        let json = try JSONSerialization.jsonObject(with: report.jsonData()) as? [String: Any]
        let results = try XCTUnwrap(json?["results"] as? [[String: Any]])
        let socket = try XCTUnwrap(results.first { $0["id"] as? String == "socket.exists" })
        XCTAssertEqual(socket["status"] as? String, "fail")
        XCTAssertEqual(socket["code"] as? String, "socket.missing")
        let ping = try XCTUnwrap(results.first { $0["id"] as? String == "socket.ping" })
        XCTAssertEqual(ping["status"] as? String, "fail")
        XCTAssertEqual(ping["code"] as? String, "socket.unreachable")
        XCTAssertNotNil(json?["generated_at"] as? String)

        let doctor = reporter.doctorReport(now: Date(timeIntervalSince1970: 1))
        let doctorIDs = Set(doctor.results.map(\.id))
        XCTAssertFalse(doctorIDs.contains("engine.status"), "doctorJSON stays on the legacy doctor contract")
        XCTAssertFalse(doctorIDs.contains("remote.machines"), "doryd-only checks stay out of doctorJSON")
        let expectedDoctorIDs = [
            "socket.exists",
            "socket.ping",
            "docker.cli",
            "docker.context",
            "network.registry_dns",
            "network.registry_https",
            "network.proxy",
            "network.corporate",
            "network.lan_exposure",
            "network.container_dns",
            "network.published_ports",
            "network.domain_table",
            "network.resources",
            "mount.basic",
            "mount.lock",
            "mount.watch",
            "vm.clock",
            "disk.host",
            "disk.dory_drive",
            "disk.docker",
            "disk.reclaimable",
            "disk.dory_state",
            "disk.guest",
            "disk.dory_logs",
            "memory.footprint",
            "resources.processes",
            "resources.guest",
            "resources.file_service",
            "resources.trend",
            "helpers.resolver",
        ]
        XCTAssertEqual(doctor.results.map(\.id), expectedDoctorIDs)
        XCTAssertEqual(
            doctorIDs,
            Set(expectedDoctorIDs)
        )
        XCTAssertEqual(doctor.results.first { $0.id == "docker.cli" }?.code, "docker.cli_missing")
        XCTAssertEqual(doctor.results.first { $0.id == "docker.context" }?.code, "docker.cli_missing")
        XCTAssertEqual(doctor.results.first { $0.id == "network.container_dns" }?.code, "network.active_probe_skipped")
        XCTAssertEqual(doctor.results.first { $0.id == "mount.basic" }?.code, "mount.active_probe_skipped")
        XCTAssertEqual(doctor.results.first { $0.id == "vm.clock" }?.code, "vm.active_probe_skipped")
        XCTAssertEqual(doctor.results.first { $0.id == "disk.guest" }?.code, "disk.active_probe_skipped")
        XCTAssertEqual(doctor.results.first { $0.id == "disk.dory_drive" }?.code, "disk.dory_drive_not_initialized")
    }

    func testDataDriveHealthReportsManagedPathAndPhysicalAllocation() throws {
        let base = "/tmp/dory-health-drive-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let selectedRoot = base + "/Library/Application Support/Dory/Selected.dorydrive"
        let store = try DoryDataDriveSelectionStore(home: base)
        let drive = try store.prepareSelection(requestedRoot: selectedRoot)
        try Data(repeating: 0x44, count: 4096).write(to: URL(fileURLWithPath: drive.backupsDirectory + "/sample.bin"))

        let reporter = HealthReporter(
            socketPath: base + "/missing.sock",
            dockerTier: nil,
            remoteManager: nil,
            dockerAPIProbe: HealthFakeDockerAPIProbe(result: .unreachable("missing")),
            commandRunner: HealthFakeCommandRunner(),
            registryProbe: HealthFakeRegistryProbe(),
            environment: ["PATH": base + "/bin", "DORY_CONFIG": base + "/config.json"],
            home: base
        )

        let check = try XCTUnwrap(reporter.doctorReport().results.first { $0.id == "disk.dory_drive" })
        XCTAssertEqual(check.status, .pass)
        XCTAssertEqual(check.code, "disk.dory_drive_ok")
        XCTAssertEqual(check.data["path"], drive.root)
        XCTAssertEqual(check.data["available"], "true")
        XCTAssertEqual(check.data["drive_id"], try drive.readManifest().id.uuidString.lowercased())
        XCTAssertEqual(check.data["schema_version"], "1")
        XCTAssertNotNil(check.data["created_at"])
        XCTAssertNotNil(check.data["filesystem"])
        XCTAssertEqual(check.data["engine_disk_logical_bytes"], "0")
        XCTAssertEqual(check.data["engine_disk_allocated_bytes"], "0")
        XCTAssertGreaterThan(Int(check.data["allocated_bytes"] ?? "0") ?? 0, 0)
    }

    func testDataDriveHealthRefusesAnExistingDriveWithoutSelectionMetadata() throws {
        let base = "/tmp/dory-health-unselected-drive-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let drive = try DoryDataDrive(home: base)
        try drive.prepare()
        let reporter = HealthReporter(
            socketPath: base + "/missing.sock",
            dockerTier: nil,
            remoteManager: nil,
            dockerAPIProbe: HealthFakeDockerAPIProbe(result: .unreachable("missing")),
            commandRunner: HealthFakeCommandRunner(),
            registryProbe: HealthFakeRegistryProbe(),
            environment: ["PATH": base + "/bin", "DORY_CONFIG": base + "/config.json"],
            home: base
        )

        let check = try XCTUnwrap(reporter.doctorReport().results.first { $0.id == "disk.dory_drive" })
        XCTAssertEqual(check.status, .fail)
        XCTAssertEqual(check.code, "disk.dory_drive_unselected")
        XCTAssertEqual(check.data["path"], drive.root)
        XCTAssertTrue(check.action?.contains("dory data use") == true)
    }

    func testDockerCLIResolverFindsInstalledDoryBinOutsideLaunchdPath() throws {
        let base = "/tmp/dory-health-installed-cli-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let bin = base + "/.dory/bin"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let docker = bin + "/docker"
        FileManager.default.createFile(atPath: docker, contents: Data())
        chmod(docker, 0o755)

        let reporter = HealthReporter(
            socketPath: base + "/dory.sock",
            dockerTier: nil,
            remoteManager: nil,
            dockerAPIProbe: HealthFakeDockerAPIProbe(result: .ok),
            commandRunner: HealthFakeCommandRunner(),
            registryProbe: HealthFakeRegistryProbe(),
            environment: ["PATH": base + "/not-on-path", "DORY_CONFIG": base + "/config.json"],
            home: base
        )

        let cli = reporter.doctorReport().results.first { $0.id == "docker.cli" }
        XCTAssertEqual(cli?.code, "docker.cli_found")
        XCTAssertEqual(cli?.detail, docker)
    }

    func testReportPassesWhenSocketExistsAndEngineIsRunning() throws {
        let base = "/tmp/dory-health-socket-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let tier = DockerTier(configuration: DockerTierConfiguration(
            home: base + "/home",
            forwardSocketPath: base + "/forward.sock"
        ))
        try tier.start()
        defer { tier.stop() }

        let reporter = HealthReporter(
            socketPath: tier.socketPath,
            dockerTier: tier,
            remoteManager: nil,
            dockerAPIProbe: HealthFakeDockerAPIProbe(result: .ok),
            commandRunner: HealthFakeCommandRunner(),
            registryProbe: HealthFakeRegistryProbe(),
            environment: ["PATH": base + "/bin", "DORY_CONFIG": base + "/config.json"],
            home: base
        )
        let report = reporter.report()
        XCTAssertEqual(report.results.first { $0.id == "socket.exists" }?.status, .pass)
        XCTAssertEqual(report.results.first { $0.id == "socket.ping" }?.code, "socket.ping_ok")
        XCTAssertEqual(report.results.first { $0.id == "engine.status" }?.code, "engine.running")
        XCTAssertEqual(report.results.first { $0.id == "disk.docker" }?.code, "disk.docker_df_ok")
    }

    func testDoctorFailsDockerDiskCheckWhenSnapshotMetadataIsMissing() throws {
        let base = "/tmp/dory-health-storage-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let reporter = HealthReporter(
            socketPath: base + "/dory.sock",
            dockerTier: nil,
            remoteManager: nil,
            dockerAPIProbe: HealthFakeDockerAPIProbe(
                result: .ok,
                systemDFResult: .badResponse(
                    statusCode: 500,
                    body: #"{"message":"rw layer snapshot not found for container 846e"}"#
                )
            ),
            commandRunner: HealthFakeCommandRunner(),
            registryProbe: HealthFakeRegistryProbe(),
            environment: ["PATH": base + "/bin", "DORY_CONFIG": base + "/config.json"],
            home: base
        )

        let disk = try XCTUnwrap(reporter.doctorReport().results.first { $0.id == "disk.docker" })
        XCTAssertEqual(disk.status, .fail)
        XCTAssertEqual(disk.code, "disk.docker_snapshot_missing")
        XCTAssertEqual(disk.data["available"], "false")
        XCTAssertTrue(disk.action?.contains("dory cleanup --json") == true)
    }

    func testReportNeverPassesEngineAfterManagedChildExit() throws {
        let base = "/tmp/dory-health-dead-helper-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
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
                    restartPolicy: .none
                )
            ),
            idleController: IdleController(),
            dockerReadyWaiter: { _, _, _ in true }
        )
        try tier.start()
        defer { tier.stop() }
        let helperPID = try XCTUnwrap(tier.status().hvPID)
        XCTAssertEqual(kill(helperPID, SIGKILL), 0)

        let deadline = Date().addingTimeInterval(1)
        while tier.status().state != .failed, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertEqual(tier.status().state, .failed)
        XCTAssertNil(tier.status().hvPID)

        let reporter = HealthReporter(
            socketPath: tier.socketPath,
            dockerTier: tier,
            remoteManager: nil,
            dockerAPIProbe: HealthFakeDockerAPIProbe(result: .unreachable("missing")),
            commandRunner: HealthFakeCommandRunner(),
            registryProbe: HealthFakeRegistryProbe(),
            environment: ["PATH": base + "/bin", "DORY_CONFIG": base + "/config.json"],
            home: base
        )
        let engine = try XCTUnwrap(reporter.report().results.first { $0.id == "engine.status" })
        XCTAssertEqual(engine.status, .fail)
        XCTAssertEqual(engine.code, "engine.failed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tier.socketPath))
    }

    func testDoctorReportSkipsDockerVersionWhenDorydEngineIsSleeping() throws {
        let base = "/tmp/dory-health-sleeping-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let bin = base + "/bin"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let docker = bin + "/docker"
        FileManager.default.createFile(atPath: docker, contents: Data())
        chmod(docker, 0o755)

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
            idleController: IdleController(now: Date(timeIntervalSince1970: 0)),
            dockerReadyWaiter: { _, _, _ in true }
        )
        try tier.armSleeping()
        defer { tier.stop() }
        XCTAssertEqual(tier.status().state, .sleeping)
        XCTAssertNil(tier.status().hvPID)

        let expectedHost = "unix://\(tier.socketPath)"
        let runner = HealthFakeCommandRunner(outputs: [
            "compose version": HealthCommandOutput(exitCode: 0, stdout: "Docker Compose version test\n", stderr: ""),
            "context show": HealthCommandOutput(exitCode: 0, stdout: "dory\n", stderr: ""),
            "context inspect dory --format {{json .Endpoints.docker.Host}}": HealthCommandOutput(exitCode: 0, stdout: "\"\(expectedHost)\"\n", stderr: ""),
        ])
        let reporter = HealthReporter(
            socketPath: tier.socketPath,
            dockerTier: tier,
            remoteManager: nil,
            dockerAPIProbe: HealthFakeDockerAPIProbe(result: .ok),
            commandRunner: runner,
            registryProbe: HealthFakeRegistryProbe(),
            environment: ["PATH": bin, "DORY_CONFIG": base + "/config.json"],
            home: base
        )

        let doctor = reporter.doctorReport()
        XCTAssertEqual(doctor.results.first { $0.id == "docker.version" }?.status, .skip)
        XCTAssertEqual(doctor.results.first { $0.id == "docker.version" }?.code, "docker.version_sleeping")
        XCTAssertFalse(runner.invocations.contains("version --format {{json .Server}}"))
        XCTAssertEqual(tier.status().state, .sleeping)
        XCTAssertNil(tier.status().hvPID)
    }

    func testReportAndDoctorIncludeNonSecretLocalMachineRuntimeEvidence() throws {
        let base = "/tmp/dory-health-machine-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let manager = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: base + "/machines",
            baseArguments: ["30"],
            passMachineArguments: false,
            requiresReadyHandoff: false
        ))
        defer { try? manager.delete(id: "dev") }
        _ = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath,
            environment: [
                "OPAQUE_SECRET": "sk-opaque-value",
                "DORY_GPU_TRACE_RESOURCES": "1",
                "DORY_VIRGLRENDERER_PATH": "/private/opaque-renderer.dylib",
            ]
        ))
        _ = try manager.start(id: "dev")

        let reporter = HealthReporter(
            socketPath: base + "/missing.sock",
            dockerTier: nil,
            machineManager: manager,
            remoteManager: nil,
            dockerAPIProbe: HealthFakeDockerAPIProbe(result: .unreachable("missing")),
            commandRunner: HealthFakeCommandRunner(),
            registryProbe: HealthFakeRegistryProbe(),
            environment: ["PATH": base + "/bin", "DORY_CONFIG": base + "/config.json"],
            home: base
        )

        let health = reporter.report()
        let machine = try XCTUnwrap(health.results.first { $0.id == "machine.local" })
        XCTAssertEqual(machine.status, .pass)
        XCTAssertEqual(machine.code, "machine.running")
        XCTAssertEqual(machine.data["running"], "1")
        let runtime = try XCTUnwrap(health.results.first { $0.id == "machine.local.dev" })
        XCTAssertEqual(runtime.code, "machine.runtime_legacy_compatibility")
        XCTAssertEqual(runtime.data["runtime_identity_mode"], "legacy-compatibility")
        XCTAssertEqual(runtime.data["virtual_hardware_abi"], "1")
        XCTAssertEqual(
            runtime.data["diagnostic_overrides"],
            "gpu-resource-tracing"
        )
        XCTAssertNil(runtime.data["environment"])

        let doctor = reporter.doctorReport()
        XCTAssertTrue(doctor.results.contains { $0.id == "machine.local" })
        XCTAssertTrue(doctor.results.contains { $0.id == "machine.local.dev" })
        XCTAssertNil(try doctor.jsonString().range(of: "sk-opaque-value"))
        XCTAssertNil(try doctor.jsonString().range(of: "/private/opaque-renderer.dylib"))

        _ = try manager.pause(id: "dev")
        let pausedHealth = reporter.report()
        let pausedSummary = try XCTUnwrap(
            pausedHealth.results.first { $0.id == "machine.local" }
        )
        XCTAssertEqual(pausedSummary.status, .pass)
        XCTAssertEqual(pausedSummary.code, "machine.paused")
        XCTAssertEqual(pausedSummary.data["running"], "0")
        XCTAssertEqual(pausedSummary.data["paused"], "1")
    }

    func testResolvedMachineEvidencePinsPlanBackendMediaComponentsAndQualifications() throws {
        let plan = healthResolvedPlan()
        XCTAssertTrue(plan.validate().isEmpty, "\(plan.validate())")
        let identity = try DoryMachineRuntimeIdentity(
            resolvedPlan: plan,
            planSHA256: DoryMachineRuntimeIdentity.planSHA256(plan)
        )
        let check = HealthReporter.machineEvidenceCheck(DoryMachineStatus(
            id: "qualified",
            state: .running,
            runtimeIdentity: identity
        ))

        XCTAssertEqual(check.status, .pass)
        XCTAssertEqual(check.code, "machine.runtime_resolved")
        XCTAssertEqual(check.data["plan_sha256"], identity.resolvedPlanSHA256)
        XCTAssertEqual(check.data["plan_revision"], "2")
        XCTAssertEqual(check.data["spec_revision"], "7")
        XCTAssertEqual(check.data["backend"], "dory-hypervisor")
        XCTAssertEqual(check.data["backend_implementation"], "dory.raw-hv-linux.v1")
        XCTAssertEqual(check.data["backend_runtime_build"], "raw-runtime-1")
        XCTAssertEqual(check.data["virtual_hardware_abi"], "1")
        XCTAssertEqual(check.data["support_tier"], "supported")
        XCTAssertEqual(check.data["media_artifact_sha256"], healthDigest("a"))
        XCTAssertEqual(check.data["runtime_qualification"], "runtime-qualification-1")
        XCTAssertEqual(check.data["graphics_qualification"], "graphics-qualification-1")
        XCTAssertEqual(check.data["host_qualification"], "host-qualification-1")
        XCTAssertEqual(check.data["resource_admission"], "resource-admission-1")
        XCTAssertTrue(check.data["components"]?.contains(
            "dory-hv@raw-runtime-1:\(healthDigest("d"))"
        ) == true)
    }

    func testMachineToolsHealthUsesDaemonIntegrationProjection() throws {
        let capabilities = [
            "clock-sync", "exec", "exec-stdin", "lifecycle-receipt", "ports-watch",
            "sync-push", "telemetry",
        ].map { DoryAgentCapability(id: $0, version: 1) }
        let plan = healthResolvedPlan()
        let resolvedIdentity = try DoryMachineRuntimeIdentity(
            resolvedPlan: plan,
            planSHA256: DoryMachineRuntimeIdentity.planSHA256(plan)
        )
        let ready = HealthReporter.machineToolsCheck(DoryMachineStatus(
            id: "ready",
            state: .running,
            agentBuild: "dory-agent/1.0",
            agentProtocolVersion: DoryCore.protocolVersion(),
            agentCapabilities: capabilities,
            runtimeIdentity: resolvedIdentity
        ))
        XCTAssertEqual(ready.status, .pass)
        XCTAssertEqual(ready.code, "machine.tools.ready")
        XCTAssertEqual(ready.data["integration_state"], "healthy")
        XCTAssertEqual(ready.data["runtime_authority"], "resolved-plan")
        XCTAssertTrue(ready.data["features"]?.contains("telemetry=active@1") == true)

        let degraded = HealthReporter.machineToolsCheck(DoryMachineStatus(
            id: "degraded",
            state: .running,
            agentBuild: "dory-agent/0.9",
            agentProtocolVersion: DoryCore.protocolVersion()
        ))
        XCTAssertEqual(degraded.status, .warn)
        XCTAssertEqual(degraded.code, "machine.tools.partial")
        XCTAssertTrue(degraded.data["unavailable_required"]?.contains("clock-sync") == true)

        let compatibility = HealthReporter.machineToolsCheck(DoryMachineStatus(
            id: "compatibility",
            state: .running,
            agentBuild: "dory-agent/1.0",
            agentProtocolVersion: DoryCore.protocolVersion(),
            agentCapabilities: capabilities
        ))
        XCTAssertEqual(compatibility.status, .warn)
        XCTAssertEqual(compatibility.code, "machine.tools.compatibility")
        XCTAssertEqual(compatibility.data["integration_state"], "compatibility")

        let invalid = HealthReporter.machineToolsCheck(DoryMachineStatus(
            id: "invalid",
            state: .running,
            agentBuild: "dory-agent/tampered",
            agentProtocolVersion: DoryCore.protocolVersion(),
            agentCapabilities: [
                DoryAgentCapability(id: "exec", version: 1),
                DoryAgentCapability(id: "exec", version: 2),
            ]
        ))
        XCTAssertEqual(invalid.status, .fail)
        XCTAssertEqual(invalid.code, "machine.tools.invalid_handshake")
    }

    func testInvalidRuntimeIdentityFailsClosedWithoutProjectingUntrustedPlanFields() {
        let plan = healthResolvedPlan()
        let identity = DoryMachineRuntimeIdentity(
            mode: .resolvedPlan,
            virtualHardwareABIVersion: 1,
            resolvedPlanSHA256: healthDigest("0"),
            resolvedPlan: plan
        )
        let check = HealthReporter.machineEvidenceCheck(DoryMachineStatus(
            id: "tampered",
            state: .failed,
            lastError: "host path /Users/example and opaque-secret",
            environment: ["TOKEN": "opaque-secret"],
            runtimeIdentity: identity
        ))

        XCTAssertEqual(check.status, .fail)
        XCTAssertEqual(check.code, "machine.runtime_identity_invalid")
        XCTAssertEqual(check.data["runtime_identity_valid"], "false")
        XCTAssertNil(check.data["backend"])
        XCTAssertNil(check.data["plan_sha256"])
        XCTAssertFalse(check.detail.contains("opaque-secret"))
        XCTAssertFalse(check.data.values.contains { $0.contains("/Users/example") })
    }

    func testStructuredMachineFailureProjectsStableRecoveryEvidenceWithoutRawDetail() {
        let operationID = "01234567-89ab-4cde-8fab-0123456789ab"
        let failure = DoryMachineFailure(
            code: .helperExited,
            occurredAtUnixMilliseconds: 1_787_318_400_000,
            operationID: operationID,
            causalChain: [.processExit, .journal],
            recoveryDisposition: .retry,
            evidenceReferences: [
                .init(kind: .operation, identifier: operationID),
                .init(kind: .backend, identifier: "dory.raw-hv-linux.v1"),
            ]
        )
        let check = HealthReporter.machineEvidenceCheck(DoryMachineStatus(
            id: "failed",
            state: .failed,
            lastError: "helper failed at /Users/example with opaque-secret",
            failure: failure,
            activeOperationID: operationID,
            activeOperationKind: "starting"
        ))

        XCTAssertEqual(check.status, .fail)
        XCTAssertEqual(check.code, "machine.failure.helper-exited")
        XCTAssertEqual(check.data["failure_code"], "helper-exited")
        XCTAssertEqual(check.data["failure_recovery"], "retry")
        XCTAssertEqual(check.data["failure_causes"], "process-exit,journal")
        XCTAssertEqual(check.data["failure_operation_id"], operationID)
        XCTAssertEqual(check.data["active_operation_id"], operationID)
        XCTAssertEqual(check.data["active_operation_kind"], "starting")
        XCTAssertTrue(check.data["failure_evidence"]?.contains(
            "backend:dory.raw-hv-linux.v1"
        ) == true)
        XCTAssertFalse(check.detail.contains("opaque-secret"))
        XCTAssertFalse(check.data.values.contains { value in
            value.contains("opaque-secret") || value.contains("/Users/example")
        })
    }

    func testDoctorReportMatchesLegacyDockerCLIContextCodes() throws {
        let base = "/tmp/dory-health-cli-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let bin = base + "/bin"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let docker = bin + "/docker"
        FileManager.default.createFile(atPath: docker, contents: Data())
        chmod(docker, 0o755)

        let socketPath = base + "/dory.sock"
        let expectedHost = "unix://\(socketPath)"
        let reporter = HealthReporter(
            socketPath: socketPath,
            dockerTier: nil,
            remoteManager: nil,
            dockerAPIProbe: HealthFakeDockerAPIProbe(result: .ok),
            commandRunner: HealthFakeCommandRunner(outputs: [
                "version --format {{json .Server}}": HealthCommandOutput(exitCode: 0, stdout: #"{"Version":"test"}"#, stderr: ""),
                "compose version": HealthCommandOutput(exitCode: 0, stdout: "Docker Compose version test\n", stderr: ""),
                "context show": HealthCommandOutput(exitCode: 0, stdout: "dory\n", stderr: ""),
                "context inspect dory --format {{json .Endpoints.docker.Host}}": HealthCommandOutput(exitCode: 0, stdout: "\"\(expectedHost)\"\n", stderr: ""),
            ]),
            registryProbe: HealthFakeRegistryProbe(),
            environment: ["PATH": bin, "DORY_CONFIG": base + "/config.json"],
            home: base
        )

        let codesByID = Dictionary(uniqueKeysWithValues: reporter.doctorReport().results.map { ($0.id, $0.code) })
        XCTAssertEqual(codesByID["docker.cli"], "docker.cli_found")
        XCTAssertEqual(codesByID["docker.version"], "docker.version_ok")
        XCTAssertEqual(codesByID["docker.compose"], "docker.compose_ok")
        XCTAssertEqual(codesByID["docker.host_env"], "socket.docker_host_unset")
        XCTAssertEqual(codesByID["docker.context.current"], "context.active")
        XCTAssertEqual(codesByID["docker.context.dory"], "context.dory_ok")
    }

    func testMemoryCheckReportsCompletePhysicalFootprintForWholeProcessSet() throws {
        let daemonPID = getpid()
        let reporter = HealthReporter(
            socketPath: "/tmp/dory-health-memory-missing.sock",
            dockerTier: nil,
            remoteManager: nil,
            dockerAPIProbe: HealthFakeDockerAPIProbe(result: .unreachable("missing")),
            commandRunner: HealthFakeCommandRunner(),
            registryProbe: HealthFakeRegistryProbe(),
            environment: ["PATH": "/nonexistent"],
            home: "/tmp",
            memorySampler: HealthFakeMemorySampler(snapshot: DoryProcessMemorySnapshot(
                usages: [
                    DoryProcessMemoryUsage(
                        pid: daemonPID,
                        residentSizeBytes: 100,
                        physicalFootprintBytes: 200
                    ),
                    DoryProcessMemoryUsage(
                        pid: 91_001,
                        residentSizeBytes: 300,
                        physicalFootprintBytes: 500
                    ),
                    DoryProcessMemoryUsage(
                        pid: 91_002,
                        residentSizeBytes: 700,
                        physicalFootprintBytes: 1_100
                    ),
                ],
                managedHelperTreePIDs: [91_001, 91_002],
                complete: true,
                errors: []
            ))
        )

        let memory = try XCTUnwrap(reporter.doctorReport().results.first { $0.id == "memory.footprint" })
        XCTAssertEqual(memory.status, .pass)
        XCTAssertEqual(memory.code, "memory.footprint_ok")
        XCTAssertTrue(memory.detail.contains("summed physical footprint"))
        XCTAssertTrue(memory.detail.contains("shared pages may be counted more than once"))
        XCTAssertFalse(memory.detail.contains("host RSS"))
        XCTAssertEqual(memory.data["phys_footprint_bytes"], "1800")
        XCTAssertEqual(memory.data["daemon_phys_footprint_bytes"], "200")
        XCTAssertEqual(memory.data["managed_helper_tree_phys_footprint_bytes"], "1600")
        XCTAssertEqual(memory.data["rss_bytes"], "1100")
        XCTAssertEqual(memory.data["rss_kind"], "current_resident_size")
        XCTAssertEqual(memory.data["rss_scope"], "dory_process_set")
        XCTAssertEqual(memory.data["process_set_complete"], "true")
        XCTAssertEqual(
            memory.data["phys_footprint_aggregation"],
            "sum_of_per_process_charges_may_double_count_shared_pages"
        )
    }

    func testMemoryCheckLabelsPartialPhysicalFootprintAndWarns() throws {
        let daemonPID = getpid()
        let reporter = HealthReporter(
            socketPath: "/tmp/dory-health-memory-partial.sock",
            dockerTier: nil,
            remoteManager: nil,
            dockerAPIProbe: HealthFakeDockerAPIProbe(result: .unreachable("missing")),
            commandRunner: HealthFakeCommandRunner(),
            registryProbe: HealthFakeRegistryProbe(),
            environment: ["PATH": "/nonexistent"],
            home: "/tmp",
            memorySampler: HealthFakeMemorySampler(snapshot: DoryProcessMemorySnapshot(
                usages: [DoryProcessMemoryUsage(
                    pid: daemonPID,
                    residentSizeBytes: 100,
                    physicalFootprintBytes: 200
                )],
                managedHelperTreePIDs: [],
                complete: false,
                errors: ["pid 91001: No such process"]
            ))
        )

        let memory = try XCTUnwrap(reporter.doctorReport().results.first { $0.id == "memory.footprint" })
        XCTAssertEqual(memory.status, .warn)
        XCTAssertEqual(memory.code, "memory.footprint_partial")
        XCTAssertTrue(memory.detail.hasPrefix("at least 200 B summed physical footprint"))
        XCTAssertEqual(memory.data["phys_footprint_scope"], "partial_dory_process_set")
        XCTAssertEqual(memory.data["rss_scope"], "partial_dory_process_set")
        XCTAssertEqual(memory.data["process_set_complete"], "false")
        XCTAssertEqual(memory.data["sampling_errors"], "pid 91001: No such process")
    }

    func testMemoryCheckLabelsDaemonPeakRSSAsFallbackWhenFootprintUnavailable() throws {
        let reporter = HealthReporter(
            socketPath: "/tmp/dory-health-memory-unavailable.sock",
            dockerTier: nil,
            remoteManager: nil,
            dockerAPIProbe: HealthFakeDockerAPIProbe(result: .unreachable("missing")),
            commandRunner: HealthFakeCommandRunner(),
            registryProbe: HealthFakeRegistryProbe(),
            environment: ["PATH": "/nonexistent"],
            home: "/tmp",
            memorySampler: HealthFakeMemorySampler(snapshot: DoryProcessMemorySnapshot(
                usages: [],
                managedHelperTreePIDs: [],
                complete: false,
                errors: ["sampling unavailable"]
            ))
        )

        let memory = try XCTUnwrap(reporter.doctorReport().results.first { $0.id == "memory.footprint" })
        XCTAssertEqual(memory.status, .warn)
        XCTAssertEqual(memory.code, "memory.footprint_unavailable")
        XCTAssertTrue(memory.detail.contains("daemon-only peak RSS fallback"))
        XCTAssertEqual(memory.data["physical_footprint_available"], "false")
        XCTAssertEqual(memory.data["rss_kind"], "peak_resident_size")
        XCTAssertEqual(memory.data["rss_scope"], "daemon_self")
        XCTAssertEqual(memory.data["rss_source"], "getrusage.RUSAGE_SELF.ru_maxrss")
    }

    func testDarwinMemorySamplerIncludesManagedHelperDescendants() throws {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            "-c",
            "trap 'kill \"$child\" 2>/dev/null; wait \"$child\" 2>/dev/null' TERM EXIT; sleep 30 & child=$!; wait $child",
        ]
        try helper.run()
        defer {
            if helper.isRunning {
                helper.terminate()
                helper.waitUntilExit()
            }
        }

        let sampler = DarwinDoryProcessMemorySampler()
        var snapshot = sampler.snapshot(
            daemonPID: getpid(),
            managedHelperPID: helper.processIdentifier
        )
        let deadline = Date().addingTimeInterval(2)
        while snapshot.managedHelperTreePIDs.count < 2, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
            snapshot = sampler.snapshot(
                daemonPID: getpid(),
                managedHelperPID: helper.processIdentifier
            )
        }

        XCTAssertTrue(snapshot.complete, snapshot.errors.joined(separator: "; "))
        XCTAssertTrue(snapshot.managedHelperTreePIDs.contains(helper.processIdentifier))
        XCTAssertGreaterThanOrEqual(snapshot.managedHelperTreePIDs.count, 2)
        let helperTreeUsages = snapshot.usages.filter {
            snapshot.managedHelperTreePIDs.contains($0.pid)
        }
        XCTAssertGreaterThanOrEqual(helperTreeUsages.count, 2)
        XCTAssertTrue(helperTreeUsages.allSatisfy { $0.residentSizeBytes > 0 })
        XCTAssertTrue(helperTreeUsages.allSatisfy { $0.physicalFootprintBytes > 0 })
        XCTAssertTrue(helperTreeUsages.allSatisfy { ($0.openFileDescriptorCount ?? 0) > 0 })
        XCTAssertTrue(helperTreeUsages.allSatisfy { ($0.threadCount ?? 0) > 0 })
    }

    func testDockerReclaimPreviewIsConservativeAndNamesExactObjects() throws {
        let body = #"""
        {
          "Containers": [
            {"Id":"stopped-123456789", "State":"exited", "SizeRw":10},
            {"Id":"running-123456789", "State":"running", "SizeRw":999}
          ],
          "Volumes": [
            {"Name":"unused", "UsageData":{"RefCount":0,"Size":20}},
            {"Name":"live", "UsageData":{"RefCount":1,"Size":999}}
          ],
          "BuildCache": [
            {"ID":"cache-123456789", "InUse":false, "Size":30},
            {"ID":"live-cache", "InUse":true, "Size":999}
          ],
          "Images": [
            {"Id":"sha256:unused-image", "Containers":0, "Size":100, "SharedSize":40},
            {"Id":"sha256:live-image", "Containers":1, "Size":999, "SharedSize":0}
          ]
        }
        """#
        let estimate = try XCTUnwrap(HealthReporter.dockerReclaimableEstimate(body))
        XCTAssertEqual(estimate.reclaimableBytes, 120)
        XCTAssertEqual(estimate.objects.count, 4)
        XCTAssertTrue(estimate.objects.contains { $0.hasPrefix("container:stopped-123") })
        XCTAssertTrue(estimate.objects.contains("volume:unused:20"))
        XCTAssertFalse(estimate.objects.contains { $0.contains("running-123") || $0.contains("live-cache") })
    }

    func testResourceTrendWarnsBeforeAThreeSampleFdSlopeReachesTheLimit() {
        let tracker = DoryResourceTrendTracker()
        let base = Date(timeIntervalSince1970: 10_000)
        _ = tracker.record(DoryResourceTrendSample(
            at: base,
            openFileDescriptors: 100,
            threads: 20,
            physicalFootprintBytes: 1,
            fileServicePending: 0
        ))
        _ = tracker.record(DoryResourceTrendSample(
            at: base.addingTimeInterval(10),
            openFileDescriptors: 120,
            threads: 20,
            physicalFootprintBytes: 1,
            fileServicePending: 0
        ))
        let assessment = tracker.record(DoryResourceTrendSample(
            at: base.addingTimeInterval(20),
            openFileDescriptors: 140,
            threads: 20,
            physicalFootprintBytes: 1,
            fileServicePending: 0
        ))
        XCTAssertEqual(assessment.windowSeconds, 20)
        XCTAssertEqual(assessment.warnings, ["open file descriptors rose 100→140"])
    }
}

private func healthFileServiceSnapshot() -> DoryFileServiceResourceSnapshot {
    DoryFileServiceResourceSnapshot(
        schema: "dev.dory.file-service.resources",
        version: 1,
        generatedAt: Date(),
        running: true,
        cacheMode: "zero-validity",
        maximumCacheValiditySeconds: 0,
        configuredShareCount: 1,
        invalidationOnlyShareCount: 0,
        watcherNudgeShareCount: 1,
        frontendCount: 3,
        requestQueueCount: 3,
        observationRequired: true,
        observationActive: true,
        requiredObservationShareCount: 1,
        observedRequiredShareCount: 1,
        observationStreamCount: 1,
        pendingEventCount: 0,
        pendingEventLimit: 65_536,
        receivedEventCount: 1,
        deliveredBatchCount: 1,
        failedBatchCount: 0,
        eventLossCount: 0,
        invalidationCount: 1,
        invalidationFailureCount: 0,
        invalidationFailureLatched: false,
        rejectedRequestCount: 0,
        executedRequestCount: 1,
        terminalQueueFaultCount: 0,
        completedRequestCount: 1,
        failedRequestCount: 0,
        inFlightRequestCount: 0,
        peakInFlightRequestCount: 1,
        requestPayloadBytes: 64,
        workerResponsePayloadBytes: 64,
        guestPublishedResponseBytes: 64,
        totalRequestLatencyNanoseconds: 1_000,
        maximumRequestLatencyNanoseconds: 1_000,
        coherenceReceivedBatchCount: 1,
        coherenceReplayedBatchCount: 0,
        coherenceInFlightBatchCount: 0,
        coherenceFailedBatchCount: 0,
        coherenceTotalLatencyNanoseconds: 1_000,
        coherenceMaximumLatencyNanoseconds: 1_000,
        coherenceRequestBytes: 128,
        coherenceAcknowledgementBytes: 48,
        coherenceTerminalFailureLatched: false
    )
}

private enum HealthTestError: Error {
    case unavailable
}

private func portForwardTelemetry(
    configured: UInt64,
    active: UInt64,
    failures: UInt64
) -> DoryDeviceTelemetrySnapshot {
    DoryDeviceTelemetrySnapshot(
        machineID: "dev",
        operationID: "12345678-1234-4234-8234-123456789abc",
        backend: .doryHypervisor,
        sampleSequence: 1,
        sampledAtUnixMilliseconds: 1,
        monotonicNanoseconds: 1,
        devices: [
            DoryDeviceTelemetryDevice(
                id: "resolved-port-forwards",
                kind: .network,
                health: active == configured ? .healthy : .degraded,
                metrics: [
                    .measured(.configuredPortForwards, value: configured),
                    .measured(.activePortForwards, value: active),
                    .measured(.portForwardReconciliationFailures, value: failures),
                ]
            ),
        ]
    )
}

private func healthResolvedPlan() -> DoryResolvedMachinePlan {
    let artifact = healthDigest("a")
    let guest = DoryGuestPlatform(family: .linux, architecture: .arm64)
    let devices = DoryVirtualMachineDeviceCapabilityRequest(
        networkInterface: .stable(machineID: "qualified"),
        display: DoryVirtualMachineDisplayCapabilityRequest(
            widthPixels: 1_920,
            heightPixels: 1_080
        ),
        gracefulShutdown: true
    )
    let media = DoryBootMedia(
        kind: .installedLinuxBootBundle,
        source: .bundledByDory,
        artifactSHA256: artifact
    )
    return DoryResolvedMachinePlan(
        machineID: "qualified",
        definitionRevision: 7,
        definitionSHA256: healthDigest("1"),
        planRevision: 2,
        createdAtUnixMilliseconds: 1_700_000_000_000,
        updatedAtUnixMilliseconds: 1_700_000_000_000,
        guest: guest,
        backend: .doryHypervisor,
        backendImplementationIdentifier: "dory.raw-hv-linux.v1",
        backendRuntimeBuildIdentifier: "raw-runtime-1",
        virtualHardwareABIVersion: 1,
        rawHVVirtualHardwareTopology: healthSupportedRawHVTopology(),
        bootMedia: DoryResolvedMachineBootMedia(
            resolverReference: DoryVMResolverReference(
                namespace: "artifact",
                identifier: "qualified-linux"
            ),
            media: media
        ),
        launchArtifacts: resolvedBootLaunchArtifacts(
            reference: DoryVMResolverReference(
                namespace: "artifact", identifier: "qualified-linux"
            ),
            media: media
        ),
        components: [DoryResolvedBackendComponentEvidence(
            componentIdentifier: "dory-hv",
            buildIdentifier: "raw-runtime-1",
            artifactSHA256: healthDigest("d")
        )],
        devices: devices,
        graphics: .hostAcceleratedDisplay,
        supportTier: .supported,
        selectionEvidence: DoryResolvedMachineBackendSelectionEvidence(
            disposition: .primary,
            plannerRequest: DoryVirtualMachineBackendPlanRequest(
                guest: guest,
                bootMedia: media,
                acceptableGraphics: [.hostAcceleratedDisplay],
                devices: devices,
                backendPreferences: [.doryHypervisor],
                backendPreferencePolicy: .required
            ),
            selectedEvaluationIndex: 0,
            rejectedCandidates: []
        ),
        qualificationEvidence: DoryResolvedMachineQualificationEvidence(
            graphics: DorySignedArtifactQualificationEvidence(
                manifestIdentity: "graphics-qualification-1",
                artifactSHA256: artifact,
                manifestSHA256: healthDigest("b"),
                signingKeyID: "dory-release-1",
                manifestFormatVersion: 1
            ),
            runtime: DoryVirtualMachineRuntimeQualificationEvidence(
                qualificationIdentity: "runtime-qualification-1",
                qualificationReportSHA256: healthDigest("c"),
                signingKeyID: "dory-runtime-1",
                qualificationFormatVersion: 1,
                guest: guest,
                bootMediaKind: media.kind,
                immutableArtifactSHA256: artifact,
                backend: .doryHypervisor,
                backendRuntimeBuildID: "raw-runtime-1",
                virtualHardwareABIVersion: 1,
                graphics: .hostAcceleratedDisplay,
                devices: devices
            )
        ),
        resourceAdmission: DoryResolvedMachineResourceAdmissionEvidence(
            admittedVirtualCPUCount: 4,
            admittedMemoryBytes: 8 * 1_024 * 1_024 * 1_024,
            admittedStorageBytes: 64 * 1_024 * 1_024 * 1_024,
            hostLogicalCPUCount: 12,
            hostPhysicalMemoryBytes: 32 * 1_024 * 1_024 * 1_024,
            hostFreeStorageBytes: 512 * 1_024 * 1_024 * 1_024,
            existingVirtualCPUCommitment: 0,
            existingMemoryCommitmentBytes: 0,
            existingStorageReservationBytes: 0,
            hostReservedLogicalCPUCount: 2,
            hostReservedMemoryBytes: 8 * 1_024 * 1_024 * 1_024,
            hostReservedStorageBytes: 32 * 1_024 * 1_024 * 1_024,
            admissionIdentity: "resource-admission-1",
            admissionReportSHA256: healthDigest("e"),
            assessorIdentifier: "dory-resource-policy",
            assessorVersion: 1
        ),
        hostQualification: DoryResolvedHostQualificationEvidence(
            qualificationIdentity: "host-qualification-1",
            qualificationReportSHA256: healthDigest("f"),
            hostHardwareModelIdentifier: "Mac16.1",
            hostOperatingSystemBuild: "26A5406c",
            backend: .doryHypervisor,
            backendRuntimeBuildIdentifier: "raw-runtime-1",
            virtualHardwareABIVersion: 1,
            qualifierIdentifier: "dory-host-qualifier",
            qualifierVersion: 1
        )
    )
}

private func healthSupportedRawHVTopology() -> DoryRawHVVirtualHardwareTopology {
    try! DoryRawHVVirtualHardwareTopology(occupiedSlots: [
        DoryRawHVVirtualDeviceSlot(
            logicalID: DoryVirtualDeviceID.derived(
                namespace: .systemDisk,
                stableID: "qualified-system-disk"
            ),
            role: .systemDisk,
            mmioSlot: 0
        ),
        DoryRawHVVirtualDeviceSlot(
            logicalID: "rawhv-graphics",
            role: .graphics,
            mmioSlot: 1
        ),
        DoryRawHVVirtualDeviceSlot(
            logicalID: "rawhv-entropy",
            role: .entropy,
            mmioSlot: 2
        ),
        DoryRawHVVirtualDeviceSlot(
            logicalID: "rawhv-balloon",
            role: .balloon,
            mmioSlot: 3
        ),
        DoryRawHVVirtualDeviceSlot(
            logicalID: "rawhv-vsock",
            role: .vsock,
            mmioSlot: 4
        ),
        DoryRawHVVirtualDeviceSlot(
            logicalID: DoryVirtualDeviceID.derived(
                namespace: .network,
                stableID: "nic0"
            ),
            role: .network,
            mmioSlot: 8
        ),
    ])
}

private func healthDigest(_ character: Character) -> String {
    String(repeating: String(character), count: 64)
}

private final class HealthFakeSSHKeyStore: SSHKeyStore, @unchecked Sendable {
    func privateKey(for identifier: String) throws -> String {
        throw SSHKeyStoreError.notFound(identifier)
    }
}

private struct HealthFakeDockerAPIProbe: DockerAPIProbing {
    var result: DockerAPIPingResult
    var systemDFResult: DockerAPISystemDFResult = .ok

    func ping(socketPath: String) -> DockerAPIPingResult {
        result
    }

    func systemDF(socketPath: String) -> DockerAPISystemDFResult {
        systemDFResult
    }
}

private struct HealthFakeMemorySampler: DoryProcessMemorySampling {
    var snapshot: DoryProcessMemorySnapshot

    func snapshot(daemonPID: Int32, managedHelperPID: Int32?) -> DoryProcessMemorySnapshot {
        snapshot
    }
}

private final class HealthFakeCommandRunner: HealthCommandRunning, @unchecked Sendable {
    var outputs: [String: HealthCommandOutput]
    private(set) var invocations: [String] = []

    init(outputs: [String: HealthCommandOutput] = [:]) {
        self.outputs = outputs
    }

    func run(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) -> HealthCommandOutput {
        let key = arguments.joined(separator: " ")
        invocations.append(key)
        return outputs[key] ?? HealthCommandOutput(
            exitCode: 1,
            stdout: "",
            stderr: "unexpected command: \(key)"
        )
    }
}

private struct HealthFakeRegistryProbe: HealthRegistryProbing {
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
