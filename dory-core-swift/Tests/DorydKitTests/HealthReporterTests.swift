import Darwin
@testable import DorydKit
import Foundation
import XCTest

final class HealthReporterTests: XCTestCase {
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
            dockerReadyWaiter: { _, _ in true }
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
            kernelPath: "/tmp/kernel",
            rootfsPath: "/tmp/rootfs"
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
}

private final class HealthFakeSSHKeyStore: SSHKeyStore, @unchecked Sendable {
    func privateKey(for identifier: String) throws -> String {
        throw SSHKeyStoreError.notFound(identifier)
    }
}

private struct HealthFakeDockerAPIProbe: DockerAPIProbing {
    var result: DockerAPIPingResult

    func ping(socketPath: String) -> DockerAPIPingResult {
        result
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
