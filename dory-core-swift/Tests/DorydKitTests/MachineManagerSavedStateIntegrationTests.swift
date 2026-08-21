import Darwin
import Foundation
import XCTest
@testable import DorydKit

final class MachineManagerSavedStateIntegrationTests: XCTestCase {
    func testVZSavedStateSurvivesRestartAndRestoresExactlyOnce() throws {
        let fixture = try SavedStateMachineFixture(name: #function)
        defer { fixture.remove() }
        let controller = RecordingSavedStateController(exitMarker: fixture.exitMarker)

        var firstManager: MachineManager? = fixture.manager(controller: controller)
        _ = try startAndAcceptHandoff(try XCTUnwrap(firstManager), fixture: fixture)
        let suspended = try XCTUnwrap(firstManager).suspend(id: fixture.machineID)
        XCTAssertEqual(suspended.state, .suspended)
        XCTAssertEqual(controller.saveCount, 1)
        XCTAssertNotNil(suspended.savedState)
        XCTAssertNil(suspended.pid)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.savedStatePath
        ))
        firstManager = nil

        let recovered = fixture.manager(controller: controller)
        let recoveredStatus = try XCTUnwrap(recovered.status(id: fixture.machineID))
        XCTAssertEqual(recoveredStatus.state, .suspended)
        XCTAssertEqual(recoveredStatus.savedState, suspended.savedState)

        try? FileManager.default.removeItem(atPath: fixture.exitMarker)
        let result = SavedStateLockedResult<DoryMachineStatus>()
        DispatchQueue.global(qos: .userInitiated).async {
            result.store(Result { try recovered.resume(id: fixture.machineID) })
        }
        let restoring = try waitForStatus(recovered, id: fixture.machineID) {
            $0.state == .starting && $0.handoffSocketPath != nil
        }
        try sendVmmHandoff(
            path: try XCTUnwrap(restoring.handoffSocketPath),
            ready: VmmReadyMessage(
                machineID: fixture.machineID,
                controlSocketPath: fixture.controlSocket
            ),
            fileDescriptors: []
        )
        let restored = try waitForResult(result).get()
        XCTAssertEqual(restored.state, .running)
        XCTAssertNil(restored.savedState)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.savedStateDirectory
        ))
        let arguments = try String(contentsOfFile: fixture.argumentsLog, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        let restoreIndex = try XCTUnwrap(arguments.firstIndex(of: "--restore-state"))
        XCTAssertEqual(arguments[restoreIndex + 1], fixture.savedStatePath)

        _ = try recovered.stop(id: fixture.machineID)
        try recovered.delete(id: fixture.machineID)
    }

    func testTamperedSavedStateFailsClosedAfterDaemonRestart() throws {
        let fixture = try SavedStateMachineFixture(name: #function)
        defer { fixture.remove() }
        let controller = RecordingSavedStateController(exitMarker: fixture.exitMarker)
        var manager: MachineManager? = fixture.manager(controller: controller)
        _ = try startAndAcceptHandoff(try XCTUnwrap(manager), fixture: fixture)
        _ = try XCTUnwrap(manager).suspend(id: fixture.machineID)
        manager = nil

        let fd = open(fixture.savedStatePath, O_WRONLY | O_TRUNC | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(fd, 0)
        if fd >= 0 {
            defer { close(fd) }
            let tampered = Data("tampered-vz-state".utf8)
            tampered.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                XCTAssertEqual(write(fd, base, raw.count), raw.count)
            }
            XCTAssertEqual(fsync(fd), 0)
        }

        let recovered = fixture.manager(controller: controller)
        let status = try XCTUnwrap(recovered.status(id: fixture.machineID))
        XCTAssertEqual(status.state, .failed)
        XCTAssertNil(status.savedState)
        XCTAssertTrue(status.lastError?.contains("saved-state") == true)
        XCTAssertThrowsError(try recovered.start(id: fixture.machineID))
        try recovered.delete(id: fixture.machineID)
    }

    func testRawHypervisorCannotClaimDurableSuspend() throws {
        let fixture = try SavedStateMachineFixture(name: #function)
        defer { fixture.remove() }
        let controller = RecordingSavedStateController(exitMarker: fixture.exitMarker)
        let manager = fixture.manager(
            controller: controller,
            acceleratedDesktopExecutablePath: fixture.executable
        )
        try manager.create(DoryMachineConfiguration(
            id: fixture.machineID,
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath,
            displayMode: .desktop
        ))
        _ = try startAndAcceptHandoff(manager, fixture: fixture, create: false)

        XCTAssertThrowsError(try manager.suspend(id: fixture.machineID)) { error in
            XCTAssertTrue("\(error)".contains("Apple Virtualization backend"))
        }
        XCTAssertEqual(controller.saveCount, 0)
        XCTAssertEqual(manager.status(id: fixture.machineID)?.state, .running)
        _ = try manager.stop(id: fixture.machineID)
        try manager.delete(id: fixture.machineID)
    }

    func testStoppingSuspendedMachineDiscardsSavedStateAndNextStartIsCold() throws {
        let fixture = try SavedStateMachineFixture(name: #function)
        defer { fixture.remove() }
        let controller = RecordingSavedStateController(exitMarker: fixture.exitMarker)
        let manager = fixture.manager(controller: controller)
        _ = try startAndAcceptHandoff(manager, fixture: fixture)
        _ = try manager.suspend(id: fixture.machineID)

        let stopped = try manager.stop(id: fixture.machineID)
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertNil(stopped.savedState)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.savedStateDirectory))

        let restarted = try startAndAcceptHandoff(manager, fixture: fixture, create: false)
        XCTAssertEqual(restarted.state, .running)
        let arguments = try String(contentsOfFile: fixture.argumentsLog, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertFalse(arguments.contains("--restore-state"))

        _ = try manager.stop(id: fixture.machineID)
        try manager.delete(id: fixture.machineID)
    }

    func testSavedStateMutationAtFinalPreSpawnBoundaryFailsClosed() throws {
        let fixture = try SavedStateMachineFixture(name: #function)
        defer { fixture.remove() }
        let controller = RecordingSavedStateController(exitMarker: fixture.exitMarker)
        let manager = fixture.manager(controller: controller)
        _ = try startAndAcceptHandoff(manager, fixture: fixture)
        _ = try manager.suspend(id: fixture.machineID)
        manager.installShareAuthorityPreSpawnHookForTesting {
            let fd = open(
                fixture.savedStatePath,
                O_WRONLY | O_TRUNC | O_CLOEXEC | O_NOFOLLOW
            )
            guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
            defer { close(fd) }
            let replacement = Data("changed-after-validation".utf8)
            try replacement.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                guard write(fd, base, raw.count) == raw.count, fsync(fd) == 0 else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
        }

        XCTAssertThrowsError(try manager.resume(id: fixture.machineID))
        let failed = try XCTUnwrap(manager.status(id: fixture.machineID))
        XCTAssertEqual(failed.state, .failed)
        XCTAssertNil(failed.savedState)
        let arguments = try String(contentsOfFile: fixture.argumentsLog, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertFalse(arguments.contains("--restore-state"))

        try manager.delete(id: fixture.machineID)
    }

    func testRejectedSaveCommandLeavesRunningHelperOwnedByMachine() throws {
        let fixture = try SavedStateMachineFixture(name: #function)
        defer { fixture.remove() }
        let manager = fixture.manager(controller: RejectingSavedStateController())
        let running = try startAndAcceptHandoff(manager, fixture: fixture)
        XCTAssertEqual(running.state, .running)
        XCTAssertNotNil(running.pid)

        XCTAssertThrowsError(try manager.suspend(id: fixture.machineID)) { error in
            XCTAssertTrue("\(error)".contains("fixture rejected saved-state command"))
        }
        let retained = try XCTUnwrap(manager.status(id: fixture.machineID))
        XCTAssertEqual(retained.state, .running)
        XCTAssertNotNil(retained.pid)
        XCTAssertNil(retained.savedState)

        _ = try manager.stop(id: fixture.machineID)
        try manager.delete(id: fixture.machineID)
    }

    func testInterruptedSuspendedStopCompletesColdStateOnRestart() throws {
        let fixture = try SavedStateMachineFixture(name: #function)
        defer { fixture.remove() }
        let controller = RecordingSavedStateController(exitMarker: fixture.exitMarker)
        var manager: MachineManager? = fixture.manager(controller: controller)
        _ = try startAndAcceptHandoff(try XCTUnwrap(manager), fixture: fixture)
        _ = try XCTUnwrap(manager).suspend(id: fixture.machineID)
        try XCTUnwrap(manager).installLifecycleFaultInjectorForTesting { point in
            if point == .stopAfterProcessStop { throw MachineLifecycleInjectedCrash() }
        }

        XCTAssertThrowsError(try XCTUnwrap(manager).stop(id: fixture.machineID)) { error in
            XCTAssertTrue(error is MachineLifecycleInjectedCrash)
        }
        manager = nil

        let recovered = fixture.manager(controller: controller)
        let status = try XCTUnwrap(recovered.status(id: fixture.machineID))
        XCTAssertEqual(status.state, .stopped)
        XCTAssertNil(status.savedState)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.savedStateDirectory))
        try recovered.delete(id: fixture.machineID)
    }

    private func startAndAcceptHandoff(
        _ manager: MachineManager,
        fixture: SavedStateMachineFixture,
        create: Bool = true
    ) throws -> DoryMachineStatus {
        if create {
            try manager.create(DoryMachineConfiguration(
                id: fixture.machineID,
                kernelPath: doryTestKernelPath,
                rootfsPath: doryTestRootfsPath
            ))
        }
        try? FileManager.default.removeItem(atPath: fixture.exitMarker)
        let starting = try manager.start(id: fixture.machineID)
        try sendVmmHandoff(
            path: try XCTUnwrap(starting.handoffSocketPath),
            ready: VmmReadyMessage(
                machineID: fixture.machineID,
                controlSocketPath: fixture.controlSocket
            ),
            fileDescriptors: []
        )
        return try waitForStatus(manager, id: fixture.machineID) { $0.state == .running }
    }

    private func waitForStatus(
        _ manager: MachineManager,
        id: String,
        timeout: TimeInterval = 5,
        predicate: (DoryMachineStatus) -> Bool
    ) throws -> DoryMachineStatus {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let status = manager.status(id: id), predicate(status) { return status }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTFail("timed out waiting for machine state")
        throw SavedStateTestError.timeout
    }

    private func waitForResult<T>(
        _ result: SavedStateLockedResult<T>,
        timeout: TimeInterval = 10
    ) throws -> Result<T, Error> {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = result.value { return value }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTFail("timed out waiting for saved-state restore")
        throw SavedStateTestError.timeout
    }
}

private struct SavedStateMachineFixture {
    let base: String
    let machineID = "saved-vm"
    let executable: String
    let exitMarker: String
    let argumentsLog: String
    let controlSocket: String

    init(name: String) throws {
        base = "/tmp/dory-saved-state-\(getpid())-\(name.hashValue.magnitude)-\(UInt32.random(in: 0...UInt32.max))"
        executable = base + "/fake-vmm.sh"
        exitMarker = base + "/helper-exit"
        argumentsLog = base + "/arguments.log"
        controlSocket = base + "/control.sock"
        try FileManager.default.createDirectory(
            atPath: base,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(argumentsLog)'
        while [ ! -f '\(exitMarker)' ]; do
          sleep 0.01
        done
        exit 0
        """
        guard FileManager.default.createFile(
            atPath: executable,
            contents: Data(script.utf8),
            attributes: [.posixPermissions: 0o700]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    var savedStateDirectory: String {
        base + "/state/" + machineID + "/" + DoryMachineSavedStateStore.directoryName
    }

    var savedStatePath: String {
        savedStateDirectory + "/" + DoryMachineSavedStateManifest.stateFileName
    }

    func manager(
        controller: any MachineVZLifecycleControlling,
        acceleratedDesktopExecutablePath: String? = nil
    ) -> MachineManager {
        MachineManager(
            configuration: MachineManagerConfiguration(
                vmmExecutablePath: executable,
                acceleratedDesktopExecutablePath: acceleratedDesktopExecutablePath,
                stateDirectory: base + "/state",
                runtimeDirectory: base + "/runtime",
                lifecycleJournalHome: base + "/journal",
                passMachineArguments: true,
                requiresReadyHandoff: true,
                handoffReadyTimeoutSeconds: 5,
                desktopHandoffReadyTimeoutSeconds: 5,
                startupRestartPolicy: .none
            ),
            vzLifecycleController: controller
        )
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: base)
    }
}

private struct RejectingSavedStateController: MachineVZLifecycleControlling {
    func pause(socketPath: String) throws {}
    func resume(socketPath: String) throws {}
    func saveMachineState(socketPath: String, statePath: String) throws {
        throw MachineManagerError.persistence("fixture rejected saved-state command")
    }
}

private final class RecordingSavedStateController: MachineVZLifecycleControlling,
    @unchecked Sendable {
    private let lock = NSLock()
    private let exitMarker: String
    private var saves = 0

    init(exitMarker: String) {
        self.exitMarker = exitMarker
    }

    var saveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return saves
    }

    func pause(socketPath: String) throws {}
    func resume(socketPath: String) throws {}

    func saveMachineState(socketPath: String, statePath: String) throws {
        let fd = open(
            statePath,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let payload = Data("vz-saved-state".utf8)
        defer { close(fd) }
        try payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            guard write(fd, base, raw.count) == raw.count else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        guard fsync(fd) == 0 else { throw CocoaError(.fileWriteUnknown) }
        lock.lock()
        saves += 1
        lock.unlock()
        guard FileManager.default.createFile(
            atPath: exitMarker,
            contents: Data(),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

private final class SavedStateLockedResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<Value, Error>?

    var value: Result<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func store(_ value: Result<Value, Error>) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}

private enum SavedStateTestError: Error {
    case timeout
}
