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
        let baselineTransferExecCount = fixture.agent.execs.filter {
            $0.argv != ["/sbin/ip", "-o", "-4", "addr", "show", "scope", "global"]
        }.count

        XCTAssertThrowsError(try fixture.manager.transferStagedFiles(
            id: "desktop",
            privateStagingRoot: fixture.stagingRoot
        )) { error in
            XCTAssertEqual(
                error as? DoryMachineFileTransferError,
                .invalidPrivateStagingRoot
            )
        }
        XCTAssertEqual(
            fixture.agent.execs.filter {
                $0.argv != ["/sbin/ip", "-o", "-4", "addr", "show", "scope", "global"]
            }.count,
            baselineTransferExecCount
        )
        XCTAssertTrue(fixture.agent.pushes.isEmpty)
    }

    func testTransferRejectsUnrelatedPrivateDirectoryWithoutDeletingIt() throws {
        let fixture = try makeRunningFixture(tag: "unrelated-private")
        defer { fixture.cleanup() }
        let unrelated = fixture.stateRoot + "/private-user-data"
        try FileManager.default.createDirectory(
            atPath: unrelated,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("keep".utf8).write(to: URL(fileURLWithPath: unrelated + "/keep.txt"))

        XCTAssertThrowsError(try fixture.manager.transferStagedFiles(
            id: "desktop",
            privateStagingRoot: unrelated
        )) { error in
            XCTAssertEqual(
                error as? DoryMachineFileTransferError,
                .invalidPrivateStagingRoot
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: unrelated + "/keep.txt")),
            Data("keep".utf8)
        )
        XCTAssertTrue(fixture.agent.pushes.isEmpty)
    }

    func testAsynchronousTransferPublishesTerminalResult() throws {
        let fixture = try makeRunningFixture(tag: "async-success")
        defer { fixture.cleanup() }

        let started = try fixture.manager.beginStagedFileTransfer(
            id: "desktop",
            privateStagingRoot: fixture.stagingRoot
        )
        XCTAssertEqual(started.machineID, "desktop")
        XCTAssertEqual(started.operationID.utf8.count, 32)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.stagingRoot))

        let completed = try waitForTransfer(
            manager: fixture.manager,
            machineID: "desktop",
            operationID: started.operationID
        )
        XCTAssertEqual(completed.phase, .completed)
        XCTAssertEqual(completed.result?.transferID, started.operationID)
        XCTAssertEqual(completed.result?.filesSent, 2)
        XCTAssertEqual(completed.result?.bytesSent, 12)
        XCTAssertEqual(completed.filesCompleted, 2)
        XCTAssertEqual(completed.bytesCompleted, 12)
        XCTAssertEqual(completed.fractionCompleted, 1)
        XCTAssertNil(completed.currentPath)
        XCTAssertEqual(fixture.agent.controlledPushCount, 1)
        let claimedRoot = try XCTUnwrap(fixture.agent.pushes.first?.localRoot)
        XCTAssertTrue(claimedRoot.contains("/owned-"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: claimedRoot))
        XCTAssertThrowsError(try fixture.manager.stagedFileTransferStatus(
            id: "another-machine",
            operationID: started.operationID
        )) { error in
            XCTAssertEqual(
                error as? DoryMachineFileTransferError,
                .unknownTransfer("another-machine", started.operationID)
            )
        }
    }

    func testAsynchronousTransferCancellationCleansDestinationAndFencesSecondTransfer() throws {
        let fixture = try makeRunningFixture(
            tag: "async-cancel",
            blockControlledPush: true
        )
        defer {
            fixture.agent.releaseControlledPush()
            fixture.cleanup()
        }

        let started = try fixture.manager.beginStagedFileTransfer(
            id: "desktop",
            privateStagingRoot: fixture.stagingRoot
        )
        XCTAssertTrue(fixture.agent.waitForControlledPush())
        XCTAssertEqual(
            fixture.manager.currentStagedFileTransferStatus(id: "desktop")?.operationID,
            started.operationID
        )
        XCTAssertThrowsError(try fixture.manager.beginStagedFileTransfer(
            id: "desktop",
            privateStagingRoot: fixture.stagingRoot
        )) { error in
            XCTAssertEqual(
                error as? DoryMachineFileTransferError,
                .transferAlreadyInProgress("desktop")
            )
        }
        XCTAssertThrowsError(try fixture.manager.transferStagedFiles(
            id: "desktop",
            privateStagingRoot: fixture.stagingRoot
        )) { error in
            XCTAssertEqual(
                error as? DoryMachineFileTransferError,
                .transferAlreadyInProgress("desktop")
            )
        }

        let cancelling = try fixture.manager.cancelStagedFileTransfer(
            id: "desktop",
            operationID: started.operationID
        )
        XCTAssertEqual(cancelling.phase, .cancelling)
        fixture.agent.releaseControlledPush()

        let cancelled = try waitForTransfer(
            manager: fixture.manager,
            machineID: "desktop",
            operationID: started.operationID
        )
        XCTAssertEqual(cancelled.phase, .cancelled)
        XCTAssertNil(cancelled.result)
        XCTAssertNil(cancelled.failure)
        let destination = try XCTUnwrap(cancelled.guestDestination)
        XCTAssertTrue(fixture.agent.execs.contains {
            $0.argv == ["/bin/rm", "-rf", "--", destination]
        })
        XCTAssertFalse(fixture.agent.execs.contains { $0.argv.first == "/bin/chown" })
        let claimedRoot = try XCTUnwrap(fixture.agent.pushes.first?.localRoot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: claimedRoot))
        XCTAssertNil(fixture.manager.currentStagedFileTransferStatus(id: "desktop"))
    }

    func testAsynchronousTransferFailureUsesStableSafeEvidence() throws {
        let fixture = try makeRunningFixture(tag: "async-failure", failPush: true)
        defer { fixture.cleanup() }

        let started = try fixture.manager.beginStagedFileTransfer(
            id: "desktop",
            privateStagingRoot: fixture.stagingRoot
        )
        let failed = try waitForTransfer(
            manager: fixture.manager,
            machineID: "desktop",
            operationID: started.operationID
        )
        XCTAssertEqual(failed.phase, .failed)
        XCTAssertEqual(failed.failure?.code, .transferFailed)
        XCTAssertEqual(failed.failure?.message, "File transfer failed for desktop.")
        XCTAssertNil(failed.result)
        XCTAssertFalse(failed.failure?.message.contains(fixture.stagingRoot) == true)
        let claimedRoot = try XCTUnwrap(fixture.agent.pushes.first?.localRoot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: claimedRoot))
    }

    func testInitializationReapsAStageClaimedByDeadDaemon() throws {
        let suffix = "\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let root = URL(fileURLWithPath: "/tmp/dory-machine-transfer-reap-\(suffix)")
        let source = root.appendingPathComponent("source.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data("secret".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: root) }
        let staged = try DoryMachineFileTransferStager.stage(fileURLs: [source])
        let claimed = try DoryMachineFileTransferStager.claimForDaemon(
            staged.rootPath,
            operationID: String(repeating: "a", count: 32),
            ownerProcessID: 2_000_000_000
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: claimed))

        _ = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: root.appendingPathComponent("state").path,
            baseArguments: ["30"],
            passMachineArguments: false
        ))

        XCTAssertFalse(FileManager.default.fileExists(atPath: claimed))
    }

    func testGuestExportStagesOnlyAHomeTreeAndRequiresExplicitDiscard() throws {
        let fixture = try makeRunningFixture(tag: "guest-export")
        defer { fixture.cleanup() }

        let started = try fixture.manager.beginGuestFileExport(
            id: "desktop",
            guestSource: "/home/alice/Documents/project"
        )
        let completed = try waitForGuestExport(
            manager: fixture.manager,
            machineID: "desktop",
            operationID: started.operationID
        )

        XCTAssertEqual(completed.phase, .completed)
        XCTAssertEqual(completed.result?.exportID, started.operationID)
        XCTAssertEqual(completed.result?.filesReceived, 1)
        XCTAssertEqual(completed.result?.directoriesReceived, 0)
        XCTAssertEqual(completed.result?.bytesReceived, 12)
        XCTAssertEqual(completed.filesCompleted, 1)
        XCTAssertEqual(completed.bytesCompleted, 12)
        XCTAssertEqual(completed.fractionCompleted, 1)
        XCTAssertNil(completed.currentPath)
        let root = try XCTUnwrap(completed.result?.privateStagingRoot)
        XCTAssertTrue(root.contains("/export-\(getpid())-"))
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: root + "/guest-file.txt")),
            Data("guest-export".utf8)
        )
        XCTAssertEqual(fixture.agent.pulls.map(\.remoteRoot), [
            "/home/alice/Documents/project",
        ])
        let recovered = try XCTUnwrap(
            fixture.manager.currentGuestFileExportStatus(id: "desktop")
        )
        XCTAssertEqual(recovered.operationID, started.operationID)
        XCTAssertEqual(recovered.phase, .completed)
        XCTAssertEqual(recovered.result, completed.result)

        try fixture.manager.discardGuestFileExport(
            id: "desktop",
            operationID: started.operationID
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: root))
        XCTAssertNil(fixture.manager.currentGuestFileExportStatus(id: "desktop"))
        XCTAssertThrowsError(try fixture.manager.guestFileExportStatus(
            id: "desktop",
            operationID: started.operationID
        )) { error in
            XCTAssertEqual(
                error as? DoryMachineFileTransferError,
                .unknownTransfer("desktop", started.operationID)
            )
        }
    }

    func testGuestExportRejectsTraversalAndPathsOutsideManagedHome() throws {
        let fixture = try makeRunningFixture(tag: "guest-export-paths")
        defer { fixture.cleanup() }

        for path in [
            "/etc",
            "/home/alice/../bob/private",
            "/home/alice-other/private",
            "/home/alice/Documents/",
        ] {
            XCTAssertThrowsError(try fixture.manager.beginGuestFileExport(
                id: "desktop",
                guestSource: path
            )) { error in
                XCTAssertEqual(
                    error as? DoryMachineFileTransferError,
                    .invalidGuestSource("desktop")
                )
            }
        }
        XCTAssertTrue(fixture.agent.pulls.isEmpty)
    }

    func testGuestExportCancellationRemovesPrivateOutputAndFencesPush() throws {
        let fixture = try makeRunningFixture(
            tag: "guest-export-cancel",
            blockControlledPull: true
        )
        defer {
            fixture.agent.releaseControlledPull()
            fixture.cleanup()
        }

        let started = try fixture.manager.beginGuestFileExport(
            id: "desktop",
            guestSource: "/home/alice/Documents"
        )
        XCTAssertTrue(fixture.agent.waitForControlledPull())
        XCTAssertThrowsError(try fixture.manager.beginStagedFileTransfer(
            id: "desktop",
            privateStagingRoot: fixture.stagingRoot
        )) { error in
            XCTAssertEqual(
                error as? DoryMachineFileTransferError,
                .transferAlreadyInProgress("desktop")
            )
        }
        let cancelling = try fixture.manager.cancelGuestFileExport(
            id: "desktop",
            operationID: started.operationID
        )
        XCTAssertEqual(cancelling.phase, .cancelling)
        fixture.agent.releaseControlledPull()

        let cancelled = try waitForGuestExport(
            manager: fixture.manager,
            machineID: "desktop",
            operationID: started.operationID
        )
        XCTAssertEqual(cancelled.phase, .cancelled)
        XCTAssertNil(cancelled.result)
        XCTAssertNil(cancelled.failure)
        let localRoot = try XCTUnwrap(fixture.agent.pulls.first?.localRoot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: localRoot))
        XCTAssertNil(fixture.manager.currentGuestFileExportStatus(id: "desktop"))
    }

    private func waitForTransfer(
        manager: MachineManager,
        machineID: String,
        operationID: String
    ) throws -> DoryMachineFileTransferOperationStatus {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let status = try manager.stagedFileTransferStatus(
                id: machineID,
                operationID: operationID
            )
            if status.phase.isTerminal {
                return status
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return try manager.stagedFileTransferStatus(
            id: machineID,
            operationID: operationID
        )
    }

    private func waitForGuestExport(
        manager: MachineManager,
        machineID: String,
        operationID: String
    ) throws -> DoryMachineGuestFileExportOperationStatus {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let status = try manager.guestFileExportStatus(
                id: machineID,
                operationID: operationID
            )
            if status.phase.isTerminal {
                return status
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return try manager.guestFileExportStatus(
            id: machineID,
            operationID: operationID
        )
    }

    private func makeRunningFixture(
        tag: String,
        failPush: Bool = false,
        blockControlledPush: Bool = false,
        failPull: Bool = false,
        blockControlledPull: Bool = false
    ) throws -> TransferFixture {
        let suffix = "\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let stateRoot = "/tmp/dory-machine-transfer-\(tag)-\(suffix)"
        let stagingDirectory = DoryMachineFileTransferStager.defaultStagingDirectory
        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertEqual(chmod(stagingDirectory.path, 0o700), 0)
        let stagingRoot = stagingDirectory
            .appendingPathComponent(
                "transfer-" + UUID().uuidString.lowercased(),
                isDirectory: true
            ).path
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

        let agent = TransferAgentRecorder(
            failPush: failPush,
            blockControlledPush: blockControlledPush,
            failPull: failPull,
            blockControlledPull: blockControlledPull
        )
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
                operationID: try XCTUnwrap(starting.activeOperationID),
                agentBuild: "dory-agent/transfer-test",
                agentProtocolVersion: DoryCore.protocolVersion(),
                agentCapabilities: ["exec", "sync-pull", "sync-push"].map {
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

    struct Pull: Sendable, Equatable {
        var remoteRoot: String
        var localRoot: String
        var limits: DoryPullLimits
    }

    private let lock = NSLock()
    private let failPush: Bool
    private let blockControlledPush: Bool
    private let failPull: Bool
    private let blockControlledPull: Bool
    private let controlledPushStarted = DispatchSemaphore(value: 0)
    private let controlledPushRelease = DispatchSemaphore(value: 0)
    private let controlledPullStarted = DispatchSemaphore(value: 0)
    private let controlledPullRelease = DispatchSemaphore(value: 0)
    private var recordedExecs: [Exec] = []
    private var recordedPushes: [Push] = []
    private var recordedControlledPushCount = 0
    private var recordedPulls: [Pull] = []

    init(
        failPush: Bool,
        blockControlledPush: Bool,
        failPull: Bool,
        blockControlledPull: Bool
    ) {
        self.failPush = failPush
        self.blockControlledPush = blockControlledPush
        self.failPull = failPull
        self.blockControlledPull = blockControlledPull
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

    var controlledPushCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedControlledPushCount
    }

    var pulls: [Pull] {
        lock.lock()
        defer { lock.unlock() }
        return recordedPulls
    }

    func waitForControlledPush() -> Bool {
        controlledPushStarted.wait(timeout: .now() + 2) == .success
    }

    func releaseControlledPush() {
        controlledPushRelease.signal()
    }

    func waitForControlledPull() -> Bool {
        controlledPullStarted.wait(timeout: .now() + 2) == .success
    }

    func releaseControlledPull() {
        controlledPullRelease.signal()
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

    func push(
        localRoot: String,
        remoteRoot: String,
        control: DoryPushControl
    ) throws -> DoryPushStats {
        _ = control
        lock.lock()
        recordedControlledPushCount += 1
        lock.unlock()
        controlledPushStarted.signal()
        if blockControlledPush {
            _ = controlledPushRelease.wait(timeout: .now() + 2)
        }
        return try push(localRoot: localRoot, remoteRoot: remoteRoot)
    }

    func pull(
        remoteRoot: String,
        localRoot: String,
        limits: DoryPullLimits,
        controlled: Bool
    ) throws -> DoryPullStats {
        lock.lock()
        recordedPulls.append(Pull(
            remoteRoot: remoteRoot,
            localRoot: localRoot,
            limits: limits
        ))
        lock.unlock()
        if controlled {
            controlledPullStarted.signal()
        }
        try FileManager.default.createDirectory(
            atPath: localRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("guest-export".utf8).write(
            to: URL(fileURLWithPath: localRoot + "/guest-file.txt")
        )
        if controlled, blockControlledPull {
            _ = controlledPullRelease.wait(timeout: .now() + 2)
        }
        if failPull {
            throw AgentControlError.capabilityUnavailable("injected-pull-failure")
        }
        return DoryPullStats(filesReceived: 1, directoriesReceived: 0, bytesReceived: 12)
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
    func push(
        localRoot: String,
        remoteRoot: String,
        control: DoryPushControl
    ) throws -> DoryPushStats {
        try owner.push(
            localRoot: localRoot,
            remoteRoot: remoteRoot,
            control: control
        )
    }
    func pull(
        remoteRoot: String,
        localRoot: String,
        limits: DoryPullLimits
    ) throws -> DoryPullStats {
        try owner.pull(
            remoteRoot: remoteRoot,
            localRoot: localRoot,
            limits: limits,
            controlled: false
        )
    }
    func pull(
        remoteRoot: String,
        localRoot: String,
        limits: DoryPullLimits,
        control: DoryPullControl
    ) throws -> DoryPullStats {
        _ = control
        return try owner.pull(
            remoteRoot: remoteRoot,
            localRoot: localRoot,
            limits: limits,
            controlled: true
        )
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
