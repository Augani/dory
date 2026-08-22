import DoryCore
@testable import DorydKit
import Darwin
import Foundation
import XCTest

final class MachineDirectoryShareRuntimeTests: XCTestCase {
    func testRunningVZMachineReplacesExistingShareWithoutRestart() throws {
        let root = "/tmp/dory-live-share-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        let firstRoot = root + "/first"
        let secondRoot = root + "/second"
        try FileManager.default.createDirectory(
            atPath: firstRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            atPath: secondRoot,
            withIntermediateDirectories: true
        )
        let shares = RecordingDirectoryShareController()
        let manager = MachineManager(
            configuration: MachineManagerConfiguration(
                vmmExecutablePath: "/bin/sleep",
                stateDirectory: root + "/state",
                baseArguments: ["30"],
                passMachineArguments: false,
                requiresReadyHandoff: true
            ),
            directoryShareController: shares,
            vzLifecycleController: NoopVZLifecycleController()
        )
        defer {
            try? manager.delete(id: "dev")
            try? FileManager.default.removeItem(atPath: root)
        }

        _ = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath,
            shares: [DoryMachineShareConfiguration(
                tag: "src",
                hostPath: firstRoot,
                guestPath: "/workspace/src"
            )]
        ))
        let starting = try manager.start(id: "dev")
        try VmmHandoffClient.send(
            path: try XCTUnwrap(starting.handoffSocketPath),
            ready: VmmReadyMessage(
                machineID: "dev",
                operationID: try XCTUnwrap(starting.activeOperationID),
                agentBuild: "dory-agent/live-share-test",
                agentProtocolVersion: DoryCore.protocolVersion(),
                controlSocketPath: "/run/dory-live-share-control.sock"
            )
        )
        let running = try waitForState(manager, id: "dev", state: .running)
        let originalPID = try XCTUnwrap(running.pid)

        let updated = try manager.update(
            id: "dev",
            address: "192.168.215.44",
            updatesAddress: true,
            shares: [DoryMachineShareConfiguration(
                tag: "src",
                hostPath: secondRoot,
                guestPath: "/workspace/src",
                readOnly: true
            )],
            updatesShares: true
        )

        XCTAssertEqual(updated.state, .running)
        XCTAssertEqual(updated.pid, originalPID)
        XCTAssertEqual(updated.address, "192.168.215.44")
        XCTAssertEqual(shares.calls, [RecordingDirectoryShareController.Call(
            socketPath: "/run/dory-live-share-control.sock",
            shares: [VmmDirectoryShareReplacement(
                tag: "src",
                hostPath: "/private" + secondRoot,
                readOnly: true
            )]
        )])
        let stored = try JSONDecoder().decode(
            DoryMachineConfiguration.self,
            from: Data(contentsOf: URL(
                fileURLWithPath: root + "/state/dev/machine.json"
            ))
        )
        XCTAssertEqual(stored.shares, updated.shares)
    }

    func testRawHelperRejectsRuntimeShareReplacement() throws {
        let root = "/tmp/dory-raw-share-control-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        let socketPath = root + "/control.sock"
        let server = VmmLifecycleReceiptServer(socketPath: socketPath)
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: root)
        }
        try server.start()

        let response = try VmmControlClient.send(
            socketPath: socketPath,
            request: .replaceDirectoryShares([
                VmmDirectoryShareReplacement(
                    tag: "src",
                    hostPath: "/private/tmp/source",
                    readOnly: false
                ),
            ])
        )
        XCTAssertFalse(response.ok)
    }

    func testRejectedLiveReplacementFallsBackToDurableRestart() throws {
        let root = "/tmp/dory-live-share-fallback-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        let firstRoot = root + "/first"
        let secondRoot = root + "/second"
        try FileManager.default.createDirectory(
            atPath: firstRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            atPath: secondRoot,
            withIntermediateDirectories: true
        )
        let shares = RecordingDirectoryShareController(rejects: true)
        let manager = MachineManager(
            configuration: MachineManagerConfiguration(
                vmmExecutablePath: "/bin/sleep",
                stateDirectory: root + "/state",
                baseArguments: ["30"],
                passMachineArguments: false,
                requiresReadyHandoff: true
            ),
            directoryShareController: shares,
            vzLifecycleController: NoopVZLifecycleController()
        )
        defer {
            try? manager.delete(id: "dev")
            try? FileManager.default.removeItem(atPath: root)
        }

        _ = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath,
            shares: [DoryMachineShareConfiguration(
                tag: "src",
                hostPath: firstRoot,
                guestPath: "/workspace/src"
            )]
        ))
        let starting = try manager.start(id: "dev")
        try sendReadyHandoff(starting)
        let originalPID = try XCTUnwrap(
            waitForState(manager, id: "dev", state: .running).pid
        )

        let result = LockedMachineStatusResult()
        DispatchQueue.global(qos: .userInitiated).async {
            result.store(Result {
                try manager.update(
                    id: "dev",
                    shares: [DoryMachineShareConfiguration(
                        tag: "src",
                        hostPath: secondRoot,
                        guestPath: "/workspace/src"
                    )],
                    updatesShares: true
                )
            })
        }

        let deadline = Date().addingTimeInterval(5)
        var handedOffPID: Int32?
        while Date() < deadline, result.value == nil {
            if let status = manager.status(id: "dev"),
               status.state == .starting,
               let pid = status.pid,
               pid != originalPID,
               handedOffPID != pid {
                try sendReadyHandoff(status)
                handedOffPID = pid
            }
            Thread.sleep(forTimeInterval: 0.02)
        }

        let updated = try XCTUnwrap(result.value, "update restart timed out").get()
        XCTAssertEqual(updated.state, .running)
        XCTAssertNotEqual(updated.pid, originalPID)
        XCTAssertEqual(updated.shares.first?.hostPath, secondRoot)
        XCTAssertEqual(shares.calls.count, 1)
    }

    func testDirectoryShareReplacementRejectsDuplicateTagsBeforeConnecting() {
        let duplicate = VmmDirectoryShareReplacement(
            tag: "src",
            hostPath: "/private/tmp/source",
            readOnly: false
        )
        XCTAssertThrowsError(
            try UnixMachineDirectoryShareController().replaceDirectoryShares(
                socketPath: "/does/not/exist",
                shares: [duplicate, duplicate]
            )
        ) { error in
            XCTAssertEqual(
                String(describing: error),
                "invalid runtime directory-share replacement"
            )
        }
    }
}

private final class RecordingDirectoryShareController:
    MachineDirectoryShareControlling, @unchecked Sendable
{
    struct Call: Equatable {
        var socketPath: String
        var shares: [VmmDirectoryShareReplacement]
    }

    private let lock = NSLock()
    private let rejects: Bool
    private var recorded: [Call] = []

    init(rejects: Bool = false) {
        self.rejects = rejects
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func replaceDirectoryShares(
        socketPath: String,
        shares: [VmmDirectoryShareReplacement]
    ) throws {
        lock.lock()
        recorded.append(Call(socketPath: socketPath, shares: shares))
        lock.unlock()
        if rejects {
            throw VmmControlError.rejected("injected live-share rejection")
        }
    }
}

private struct NoopVZLifecycleController: MachineVZLifecycleControlling {
    func pause(socketPath: String) throws {}
    func resume(socketPath: String) throws {}
    func acknowledgeLifecycle(
        socketPath: String,
        action: DoryLifecycleReceiptAction,
        operationID: UUID
    ) throws {}
    func saveMachineState(socketPath: String, statePath: String) throws {}
}

private func waitForState(
    _ manager: MachineManager,
    id: String,
    state: DoryMachineState,
    timeout: TimeInterval = 3
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

private func sendReadyHandoff(_ status: DoryMachineStatus) throws {
    try VmmHandoffClient.send(
        path: try XCTUnwrap(status.handoffSocketPath),
        ready: VmmReadyMessage(
            machineID: status.id,
            operationID: try XCTUnwrap(status.activeOperationID),
            agentBuild: "dory-agent/live-share-test",
            agentProtocolVersion: DoryCore.protocolVersion(),
            controlSocketPath: "/run/dory-live-share-control.sock"
        )
    )
}

private final class LockedMachineStatusResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<DoryMachineStatus, Error>?

    var value: Result<DoryMachineStatus, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func store(_ value: Result<DoryMachineStatus, Error>) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}
