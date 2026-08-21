import Darwin
import DoryCore
import DoryOperations
@testable import DorydKit
import Foundation
import XCTest

final class MachineManagerFileTransferTests: XCTestCase {
    func testTransferUsesUniqueDerivedDestinationAndGuestOwnership() throws {
        let fixture = try makeRunningFixture(tag: "success")
        defer { fixture.cleanup() }

        let result = try fixture.manager.transferStagedFiles(
            id: "desktop",
            privateStagingRoot: fixture.stagingRoot
        )

        XCTAssertEqual(result.transferID.utf8.count, 32)
        XCTAssertTrue(result.transferID.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        XCTAssertEqual(
            result.guestDestination,
            "/home/alice/Downloads/Dory Transfer \(result.transferID)"
        )
        XCTAssertEqual(result.filesSent, 2)
        XCTAssertEqual(result.bytesSent, 12)
        XCTAssertEqual(fixture.agent.pushes, [
            .init(localRoot: fixture.stagingRoot, remoteRoot: result.guestDestination),
        ])

        let mkdirs = fixture.agent.execs.filter { $0.argv.first == "/bin/mkdir" }
        XCTAssertEqual(mkdirs.count, 2)
        XCTAssertEqual(mkdirs[0].argv, ["/bin/mkdir", "-p", "--", "/home/alice/Downloads"])
        XCTAssertEqual(
            mkdirs[1].argv,
            ["/bin/mkdir", "--", result.guestDestination]
        )
        XCTAssertEqual(
            Set(mkdirs[1].env),
            Set([
                DoryExecEnvironment(key: "DORY_AGENT_RUN_UID", value: "1000"),
                DoryExecEnvironment(key: "DORY_AGENT_RUN_GID", value: "1000"),
            ])
        )
        XCTAssertTrue(fixture.agent.execs.contains {
            $0.argv == [
                "/bin/chown", "-R", "--", "1000:1000", result.guestDestination,
            ]
        })
        XCTAssertFalse(fixture.agent.execs.contains { $0.argv.first == "/bin/rm" })
    }

    func testTransferFailureRemovesOnlyTheUniqueGuestDirectory() throws {
        let fixture = try makeRunningFixture(tag: "failure", failPush: true)
        defer { fixture.cleanup() }

        XCTAssertThrowsError(try fixture.manager.transferStagedFiles(
            id: "desktop",
            privateStagingRoot: fixture.stagingRoot
        )) { error in
            XCTAssertEqual(
                error as? DoryMachineFileTransferError,
                .transferFailed("desktop")
            )
        }
        XCTAssertEqual(fixture.agent.pushes.count, 1)
        let destination = try XCTUnwrap(fixture.agent.pushes.first?.remoteRoot)
        XCTAssertTrue(fixture.agent.execs.contains {
            $0.argv == ["/bin/rm", "-rf", "--", destination]
        })
        XCTAssertFalse(fixture.agent.execs.contains { $0.argv.first == "/bin/chown" })
    }

    func testTransferRejectsNonPrivateSourceBeforeContactingGuest() throws {
        let fixture = try makeRunningFixture(tag: "public-source")
        defer { fixture.cleanup() }
        XCTAssertEqual(chmod(fixture.stagingRoot, 0o755), 0)
        let baselineExecCount = fixture.agent.execs.count

        XCTAssertThrowsError(try fixture.manager.transferStagedFiles(
            id: "desktop",
            privateStagingRoot: fixture.stagingRoot
        )) { error in
            XCTAssertEqual(
                error as? DoryMachineFileTransferError,
                .invalidPrivateStagingRoot
            )
        }
        XCTAssertEqual(fixture.agent.execs.count, baselineExecCount)
        XCTAssertTrue(fixture.agent.pushes.isEmpty)
    }

    private func makeRunningFixture(
        tag: String,
        failPush: Bool = false
    ) throws -> TransferFixture {
        let suffix = "\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let stateRoot = "/tmp/dory-machine-transfer-\(tag)-\(suffix)"
        let stagingRoot = "/tmp/dory-machine-transfer-stage-\(tag)-\(suffix)"
        try FileManager.default.createDirectory(
            atPath: stagingRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("hello".utf8).write(to: URL(fileURLWithPath: stagingRoot + "/hello.txt"))
        try FileManager.default.createDirectory(
            atPath: stagingRoot + "/nested",
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("world!!".utf8).write(to: URL(fileURLWithPath: stagingRoot + "/nested/world.txt"))

        let agent = TransferAgentRecorder(failPush: failPush)
        let manager = MachineManager(
            configuration: MachineManagerConfiguration(
                vmmExecutablePath: "/bin/sleep",
                stateDirectory: stateRoot,
                baseArguments: ["30"],
                passMachineArguments: false,
                requiresReadyHandoff: true
            ),
            agentConnector: agent.connect(socketPath:)
        )
        _ = try manager.create(DoryMachineConfiguration(
            id: "desktop",
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath,
            displayMode: .desktop,
            environment: [
                DoryVMGuestAccountIntent.legacyUsernameEnvironmentKey: "alice",
                DoryVMGuestAccountIntent.legacyNumericUserIDEnvironmentKey: "1000",
            ]
        ))
        let starting = try manager.start(id: "desktop")
        try sendVmmHandoff(
            path: try XCTUnwrap(starting.handoffSocketPath),
            ready: VmmReadyMessage(
                machineID: "desktop",
                agentBuild: "dory-agent/transfer-test",
                agentProtocolVersion: DoryCore.protocolVersion(),
                agentCapabilities: ["exec", "sync-push"].map {
                    DoryAgentCapability(id: $0, version: 1)
                },
                agentSocketPath: "/run/dory-agent.sock"
            ),
            fileDescriptors: []
        )
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, manager.status(id: "desktop")?.state != .running {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertEqual(manager.status(id: "desktop")?.state, .running)
        return TransferFixture(
            manager: manager,
            agent: agent,
            stateRoot: stateRoot,
            stagingRoot: stagingRoot
        )
    }
}

private struct TransferFixture {
    var manager: MachineManager
    var agent: TransferAgentRecorder
    var stateRoot: String
    var stagingRoot: String

    func cleanup() {
        try? manager.delete(id: "desktop")
        try? FileManager.default.removeItem(atPath: stateRoot)
        try? FileManager.default.removeItem(atPath: stagingRoot)
    }
}

private final class TransferAgentRecorder: @unchecked Sendable {
    struct Exec: Sendable, Equatable {
        var argv: [String]
        var cwd: String
        var env: [DoryExecEnvironment]
    }

    struct Push: Sendable, Equatable {
        var localRoot: String
        var remoteRoot: String
    }

    private let lock = NSLock()
    private let failPush: Bool
    private var recordedExecs: [Exec] = []
    private var recordedPushes: [Push] = []

    init(failPush: Bool) {
        self.failPush = failPush
    }

    var execs: [Exec] {
        lock.lock()
        defer { lock.unlock() }
        return recordedExecs
    }

    var pushes: [Push] {
        lock.lock()
        defer { lock.unlock() }
        return recordedPushes
    }

    func connect(socketPath: String) throws -> any AgentControlClient {
        _ = socketPath
        return TransferAgentClient(owner: self)
    }

    func execute(argv: [String], cwd: String, env: [DoryExecEnvironment]) -> DoryExecResult {
        lock.lock()
        recordedExecs.append(Exec(argv: argv, cwd: cwd, env: env))
        lock.unlock()
        let output = argv.prefix(2) == ["/usr/bin/id", "-u"]
            || argv.prefix(2) == ["/usr/bin/id", "-g"] ? "1000\n" : ""
        return DoryExecResult(
            exitCode: 0,
            stdout: Data(output.utf8),
            stderr: Data(),
            timedOut: false,
            stdoutTruncated: false,
            stderrTruncated: false
        )
    }

    func push(localRoot: String, remoteRoot: String) throws -> DoryPushStats {
        lock.lock()
        recordedPushes.append(Push(localRoot: localRoot, remoteRoot: remoteRoot))
        lock.unlock()
        if failPush {
            throw AgentControlError.capabilityUnavailable("injected-transfer-failure")
        }
        return DoryPushStats(filesSent: 2, bytesSent: 12, filesDeleted: 0)
    }
}

private final class TransferAgentClient: AgentControlClient, @unchecked Sendable {
    private let owner: TransferAgentRecorder

    init(owner: TransferAgentRecorder) {
        self.owner = owner
    }

    func info() throws -> DoryAgentInfo {
        DoryAgentInfo(
            protocolVersion: DoryCore.protocolVersion(),
            kernel: "Linux transfer-test",
            agentBuild: "dory-agent/transfer-test",
            uptimeSeconds: 1
        )
    }

    func clockSync(hostEpochNs: Int64) throws -> Bool { true }
    func portsWatch() throws -> DoryPortsSnapshot { .init(ports: [], added: [], removed: []) }
    func telemetry() throws -> DoryTelemetry {
        .init(memTotalKB: 1024, memAvailableKB: 512, psiSomeAvg10: 0, psiFullAvg10: 0)
    }
    func push(localRoot: String, remoteRoot: String) throws -> DoryPushStats {
        try owner.push(localRoot: localRoot, remoteRoot: remoteRoot)
    }
    func exec(
        argv: [String],
        cwd: String,
        env: [DoryExecEnvironment],
        timeoutMs: UInt64,
        outputLimitBytes: UInt64
    ) throws -> DoryExecResult {
        _ = timeoutMs
        _ = outputLimitBytes
        return owner.execute(argv: argv, cwd: cwd, env: env)
    }
    func close() {}
}
