import Darwin
import DoryCore
@testable import DorydKit
import Foundation
import XCTest

final class HealthReporterTests: XCTestCase {
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
            "network.lan_exposure",
            "network.container_dns",
            "network.published_ports",
            "network.domain_table",
            "mount.basic",
            "mount.lock",
            "mount.watch",
            "vm.clock",
            "disk.host",
            "disk.dory_drive",
            "disk.docker",
            "disk.dory_state",
            "disk.guest",
            "disk.dory_logs",
            "memory.footprint",
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

    func testReportIncludesLocalMachineHealthOutsideDoctorContract() throws {
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
            rootfsPath: doryTestRootfsPath
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

        let doctor = reporter.doctorReport()
        XCTAssertFalse(doctor.results.contains { $0.id == "machine.local" })
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
    }
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
