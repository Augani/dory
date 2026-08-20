import Darwin
import DoryCore
import DoryOperations
@testable import DorydKit
import Foundation
import XCTest

final class MachineManagerLifecycleJournalIntegrationTests: XCTestCase {
    func testPauseAndResumePublishExactLifecycleTransitions() throws {
        let fixture = try LifecycleFixture(name: #function)
        defer { fixture.cleanup() }
        let manager = fixture.makeManager()
        _ = try fixture.createMachine(manager)
        XCTAssertEqual(try manager.start(id: fixture.machineID).state, .running)

        let paused = try manager.pause(id: fixture.machineID)
        XCTAssertEqual(paused.state, .paused)
        let pauseRecord = try waitForJournal(fixture, kind: .workspacePause, status: .completed)
        let pauseOperation = try fixture.store.acquire(pauseRecord.plan.id)
            .readWorkspaceLifecycleOperation()
        XCTAssertEqual(pauseOperation.kind, .pausing)
        XCTAssertEqual(pauseOperation.source.state, .running)
        XCTAssertEqual(pauseOperation.target.state, .paused)

        let resumed = try manager.resume(id: fixture.machineID)
        XCTAssertEqual(resumed.state, .running)
        let resumeRecord = try waitForJournal(fixture, kind: .workspaceResume, status: .completed)
        let resumeOperation = try fixture.store.acquire(resumeRecord.plan.id)
            .readWorkspaceLifecycleOperation()
        XCTAssertEqual(resumeOperation.kind, .resuming)
        XCTAssertEqual(resumeOperation.source.state, .paused)
        XCTAssertEqual(resumeOperation.target.state, .running)
    }

    func testStartJournalRemainsActiveUntilReadyAndFencesConcurrentMutation() throws {
        let fixture = try LifecycleFixture(name: #function, requiresReadyHandoff: true)
        defer { fixture.cleanup() }
        let manager = fixture.makeManager()
        _ = try fixture.createMachine(manager)

        let starting = try manager.start(id: fixture.machineID)
        XCTAssertEqual(starting.state, .starting)
        let pending = try XCTUnwrap(try fixture.records().last)
        XCTAssertEqual(pending.plan.kind, .workspaceStart)
        XCTAssertEqual(pending.state.status, .running)

        let competingStore = try DoryOperationJournalStore(home: fixture.journal)
        XCTAssertThrowsError(
            try competingStore.acquire(pending.plan.id, mutationScope: "different-vm")
        ) { error in
            guard case DoryOperationJournalError.invalidPlan = error else {
                return XCTFail("wrong scope was not rejected: \(error)")
            }
        }
        XCTAssertThrowsError(try competingStore.acquire(pending.plan.id)) { error in
            guard case DoryOperationJournalError.operationInUse = error else {
                return XCTFail("derived scope did not preserve the active fence: \(error)")
            }
        }

        XCTAssertThrowsError(
            try manager.snapshot(id: fixture.machineID, snapshotID: "while-starting")
        ) { error in
            XCTAssertTrue("\(error)".contains("active lifecycle mutation"))
        }

        try sendVmmHandoff(
            path: try XCTUnwrap(starting.handoffSocketPath),
            ready: VmmReadyMessage(machineID: fixture.machineID),
            fileDescriptors: []
        )
        XCTAssertEqual(try waitForState(manager, id: fixture.machineID, state: .running).state, .running)
        let completed = try waitForJournal(
            fixture,
            kind: .workspaceStart,
            status: .completed
        )
        let lease = try fixture.store.acquire(completed.plan.id)
        let operation = try lease.readWorkspaceLifecycleOperation()
        XCTAssertEqual(operation.kind, .starting)
        XCTAssertEqual(operation.source.runtime?.policy, .legacyCompatibility)
        XCTAssertEqual(operation.source.runtime?.authorizationState, .legacyCompatibility)
        XCTAssertEqual(operation.target.runtime?.policy, .legacyCompatibility)
        XCTAssertEqual(operation.target.runtime?.authorizationState, .legacyCompatibility)
        XCTAssertEqual(
            operation.target.runtime?.virtualHardwareABIVersion,
            DoryVirtualMachineDefinition.currentVirtualHardwareABIVersion
        )
    }

    func testPerMachineFenceAllowsDifferentMachinesToReachReadinessConcurrently() throws {
        let fixture = try LifecycleFixture(name: #function, requiresReadyHandoff: true)
        defer { fixture.cleanup() }
        let manager = fixture.makeManager()
        _ = try fixture.createMachine(manager)
        _ = try fixture.createMachine(manager, id: "lifecycle-vm-two")

        let first = try manager.start(id: fixture.machineID)
        let second = try manager.start(id: "lifecycle-vm-two")
        XCTAssertEqual(first.state, .starting)
        XCTAssertEqual(second.state, .starting)
        XCTAssertEqual(
            try fixture.records().filter {
                $0.plan.kind == .workspaceStart && $0.state.status == .running
            }.count,
            2
        )

        try sendVmmHandoff(
            path: try XCTUnwrap(first.handoffSocketPath),
            ready: VmmReadyMessage(machineID: fixture.machineID),
            fileDescriptors: []
        )
        try sendVmmHandoff(
            path: try XCTUnwrap(second.handoffSocketPath),
            ready: VmmReadyMessage(machineID: "lifecycle-vm-two"),
            fileDescriptors: []
        )
        _ = try waitForState(manager, id: fixture.machineID, state: .running)
        _ = try waitForState(manager, id: "lifecycle-vm-two", state: .running)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if try fixture.records().filter({
                $0.plan.kind == .workspaceStart && $0.state.status == .completed
            }).count == 2 {
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(
            try fixture.records().filter {
                $0.plan.kind == .workspaceStart && $0.state.status == .completed
            }.count,
            2
        )
    }

    func testReadinessTimeoutFailsStartJournalAndNeverPublishesRunning() throws {
        let fixture = try LifecycleFixture(
            name: #function,
            requiresReadyHandoff: true,
            readyTimeout: 0.05
        )
        defer { fixture.cleanup() }
        let manager = fixture.makeManager()
        _ = try fixture.createMachine(manager)

        XCTAssertEqual(try manager.start(id: fixture.machineID).state, .starting)
        let failed = try waitForState(manager, id: fixture.machineID, state: .failed)
        XCTAssertTrue(failed.lastError?.contains("ready handoff timed out") == true)
        _ = try waitForJournal(fixture, kind: .workspaceStart, status: .failed)
        XCTAssertFalse(try fixture.records().contains { record in
            record.plan.kind == .workspaceStart && record.state.status == .completed
        })
    }

    func testTerminalHelperExitFailsStartJournalWithoutWaitingForReadinessTimeout() throws {
        let fixture = try LifecycleFixture(
            name: #function,
            executable: "/usr/bin/false",
            requiresReadyHandoff: true,
            readyTimeout: 5,
            restartPolicy: .none
        )
        defer { fixture.cleanup() }
        let manager = fixture.makeManager()
        _ = try fixture.createMachine(manager)

        _ = try manager.start(id: fixture.machineID)
        let failed = try waitForState(manager, id: fixture.machineID, state: .failed, timeout: 1)
        XCTAssertTrue(failed.lastError?.contains("exited with status") == true)
        _ = try waitForJournal(
            fixture,
            kind: .workspaceStart,
            status: .failed,
            timeout: 1
        )
    }

    func testInterruptedStartRecoversStoppedWithoutFalseRunningState() throws {
        let fixture = try LifecycleFixture(name: #function, requiresReadyHandoff: true)
        defer { fixture.cleanup() }
        var manager: MachineManager? = fixture.makeManager()
        _ = try fixture.createMachine(try XCTUnwrap(manager))
        XCTAssertEqual(
            try XCTUnwrap(manager).start(id: fixture.machineID).state,
            .starting
        )
        manager = nil

        let recovered = fixture.makeManager()
        let status = try XCTUnwrap(recovered.status(id: fixture.machineID))
        XCTAssertEqual(status.state, .stopped)
        XCTAssertNil(status.pid)
        XCTAssertTrue(status.lastError?.contains("interrupted start") == true)
        _ = try waitForJournal(fixture, kind: .workspaceStart, status: .failed)
    }

    func testCrashAfterDurableStartPreparationHasJournalButNeverStartsHelper() throws {
        let fixture = try LifecycleFixture(name: #function)
        defer { fixture.cleanup() }
        var manager: MachineManager? = fixture.makeManager()
        _ = try fixture.createMachine(try XCTUnwrap(manager))
        try XCTUnwrap(manager).installLifecycleFaultInjectorForTesting { point in
            if point == .startAfterPreparation { throw MachineLifecycleInjectedCrash() }
        }

        XCTAssertThrowsError(try XCTUnwrap(manager).start(id: fixture.machineID)) { error in
            XCTAssertTrue(error is MachineLifecycleInjectedCrash)
        }
        XCTAssertEqual(try XCTUnwrap(manager).status(id: fixture.machineID)?.state, .created)
        XCTAssertEqual(
            try fixture.records().filter {
                $0.plan.kind == .workspaceResolve && $0.state.status == .running
            }.count,
            1
        )
        XCTAssertFalse(try fixture.records().contains { $0.plan.kind == .workspaceStart })
        manager = nil

        let recovered = fixture.makeManager()
        XCTAssertEqual(recovered.status(id: fixture.machineID)?.state, .stopped)
        _ = try waitForJournal(fixture, kind: .workspaceResolve, status: .completed)
        XCTAssertFalse(try fixture.records().contains { $0.plan.kind == .workspaceStart })
    }

    func testReadinessCompletionWriteFailureKeepsRunningTargetAndNonterminalJournal() throws {
        let fixture = try LifecycleFixture(name: #function, requiresReadyHandoff: true)
        defer { fixture.cleanup() }
        var manager: MachineManager? = fixture.makeManager()
        _ = try fixture.createMachine(try XCTUnwrap(manager))
        try XCTUnwrap(manager).installLifecycleFaultInjectorForTesting { point in
            if point == .completionBeforeJournalWrite(.starting) {
                throw MachineLifecycleInjectedCrash()
            }
        }

        let starting = try XCTUnwrap(manager).start(id: fixture.machineID)
        try sendVmmHandoff(
            path: try XCTUnwrap(starting.handoffSocketPath),
            ready: VmmReadyMessage(machineID: fixture.machineID),
            fileDescriptors: []
        )
        let running = try waitForState(
            try XCTUnwrap(manager),
            id: fixture.machineID,
            state: .running
        )
        XCTAssertTrue(running.lastError?.contains("unfinished readiness journal") == true)
        let unfinished = try XCTUnwrap(try fixture.records().last(where: {
            $0.plan.kind == .workspaceStart
        }))
        XCTAssertEqual(unfinished.state.status, .running)
        manager = nil

        let recovered = fixture.makeManager()
        XCTAssertEqual(recovered.status(id: fixture.machineID)?.state, .stopped)
        _ = try waitForJournal(fixture, kind: .workspaceStart, status: .failed)
    }

    func testInterruptedStopCompletesFromPersistedTargetAuthorityOnRestart() throws {
        let fixture = try LifecycleFixture(name: #function)
        defer { fixture.cleanup() }
        var manager: MachineManager? = fixture.makeManager()
        _ = try fixture.createMachine(try XCTUnwrap(manager))
        XCTAssertEqual(try XCTUnwrap(manager).start(id: fixture.machineID).state, .running)
        try XCTUnwrap(manager).installLifecycleFaultInjectorForTesting { point in
            if point == .stopAfterProcessStop { throw MachineLifecycleInjectedCrash() }
        }

        XCTAssertThrowsError(try XCTUnwrap(manager).stop(id: fixture.machineID)) { error in
            XCTAssertTrue(error is MachineLifecycleInjectedCrash)
        }
        XCTAssertEqual(try XCTUnwrap(manager).status(id: fixture.machineID)?.state, .stopped)
        manager = nil

        let recovered = fixture.makeManager()
        let status = try XCTUnwrap(recovered.status(id: fixture.machineID))
        XCTAssertEqual(status.state, .stopped)
        XCTAssertTrue(status.lastError?.contains("interrupted stop completed") == true)
        _ = try waitForJournal(fixture, kind: .workspaceStop, status: .completed)
    }

    func testInterruptedSnapshotRemovesOnlyOperationOwnedPartialArtifacts() throws {
        let fixture = try LifecycleFixture(name: #function)
        defer { fixture.cleanup() }
        var manager: MachineManager? = fixture.makeManager()
        _ = try fixture.createMachine(try XCTUnwrap(manager))
        try XCTUnwrap(manager).installLifecycleFaultInjectorForTesting { point in
            if point == .snapshotAfterRootfs { throw MachineLifecycleInjectedCrash() }
        }

        XCTAssertThrowsError(
            try XCTUnwrap(manager).snapshot(id: fixture.machineID, snapshotID: "partial")
        ) { error in
            XCTAssertTrue(error is MachineLifecycleInjectedCrash)
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.state + "/\(fixture.machineID)/snapshots/partial.ext4"
        ))
        manager = nil

        let recovered = fixture.makeManager()
        XCTAssertEqual(recovered.status(id: fixture.machineID)?.state, .stopped)
        XCTAssertTrue(try recovered.listSnapshots(machineID: fixture.machineID).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.state + "/\(fixture.machineID)/snapshots/partial.ext4"
        ))
        _ = try waitForJournal(fixture, kind: .workspaceSnapshot, status: .failed)
    }

    func testInterruptedRestoreRollsBackBackupsAndPreservesMachine() throws {
        let fixture = try LifecycleFixture(name: #function)
        defer { fixture.cleanup() }
        var manager: MachineManager? = fixture.makeManager()
        _ = try fixture.createMachine(try XCTUnwrap(manager))
        _ = try XCTUnwrap(manager).snapshot(id: fixture.machineID, snapshotID: "known-good")
        let managedDisk = fixture.state + "/\(fixture.machineID)/rootfs.ext4"
        try Data("current-before-restore".utf8).write(to: URL(fileURLWithPath: managedDisk))
        try XCTUnwrap(manager).installLifecycleFaultInjectorForTesting { point in
            if point == .restoreAfterBackups { throw MachineLifecycleInjectedCrash() }
        }

        XCTAssertThrowsError(
            try XCTUnwrap(manager).restoreSnapshot(
                machineID: fixture.machineID,
                snapshotID: "known-good"
            )
        ) { error in
            XCTAssertTrue(error is MachineLifecycleInjectedCrash)
        }
        manager = nil

        let recovered = fixture.makeManager()
        XCTAssertEqual(recovered.status(id: fixture.machineID)?.state, .stopped)
        XCTAssertEqual(
            try String(contentsOfFile: managedDisk, encoding: .utf8),
            "current-before-restore"
        )
        XCTAssertEqual(
            try recovered.listSnapshots(machineID: fixture.machineID).map(\.id),
            ["known-good"]
        )
        _ = try waitForJournal(fixture, kind: .workspaceRestore, status: .failed)
    }

    func testRestoreRejectsSnapshotMutationAfterAuthorityBindingAndRollsBack() throws {
        let fixture = try LifecycleFixture(name: #function)
        defer { fixture.cleanup() }
        let manager = fixture.makeManager()
        _ = try fixture.createMachine(manager)
        let managedDisk = fixture.state + "/\(fixture.machineID)/rootfs.ext4"
        try Data("snapshot-bound-state".utf8).write(to: URL(fileURLWithPath: managedDisk))
        let snapshot = try manager.snapshot(id: fixture.machineID, snapshotID: "bound")
        try Data("original-live-state".utf8).write(to: URL(fileURLWithPath: managedDisk))
        manager.installLifecycleFaultInjectorForTesting { point in
            if point == .restoreAfterBackups {
                try Data("mutated-after-authority-binding".utf8).write(
                    to: URL(fileURLWithPath: snapshot.rootfsPath)
                )
            }
        }

        XCTAssertThrowsError(
            try manager.restoreSnapshot(machineID: fixture.machineID, snapshotID: "bound")
        ) { error in
            XCTAssertTrue("\(error)".contains("bound snapshot evidence"))
        }
        XCTAssertEqual(
            try String(contentsOfFile: managedDisk, encoding: .utf8),
            "original-live-state"
        )
        let restoreRecords = try fixture.records().filter {
            $0.plan.kind == .workspaceRestore
        }
        XCTAssertEqual(restoreRecords.last?.state.status, .failed)
        XCTAssertFalse(restoreRecords.contains { $0.state.status == .completed })
    }

    func testRestoreCompletionWriteFailurePreservesRestoredTargetForRecovery() throws {
        let fixture = try LifecycleFixture(name: #function)
        defer { fixture.cleanup() }
        var manager: MachineManager? = fixture.makeManager()
        _ = try fixture.createMachine(try XCTUnwrap(manager))
        let managedDisk = fixture.state + "/\(fixture.machineID)/rootfs.ext4"
        try Data("snapshot-target".utf8).write(to: URL(fileURLWithPath: managedDisk))
        _ = try XCTUnwrap(manager).snapshot(id: fixture.machineID, snapshotID: "target")
        try Data("later-state".utf8).write(to: URL(fileURLWithPath: managedDisk))
        try XCTUnwrap(manager).installLifecycleFaultInjectorForTesting { point in
            if point == .completionBeforeJournalWrite(.restoring) {
                throw MachineLifecycleInjectedCrash()
            }
        }

        let restored = try XCTUnwrap(manager).restoreSnapshot(
            machineID: fixture.machineID,
            snapshotID: "target"
        )
        XCTAssertEqual(restored.state, .created)
        XCTAssertEqual(
            try String(contentsOfFile: managedDisk, encoding: .utf8),
            "snapshot-target"
        )
        XCTAssertTrue(
            try XCTUnwrap(manager).status(id: fixture.machineID)?.lastError?
                .contains("unfinished restore journal") == true
        )
        let unfinished = try XCTUnwrap(try fixture.records().last(where: {
            $0.plan.kind == .workspaceRestore
        }))
        XCTAssertEqual(unfinished.state.status, .running)
        manager = nil

        let recovered = fixture.makeManager()
        XCTAssertEqual(recovered.status(id: fixture.machineID)?.state, .stopped)
        XCTAssertEqual(
            try String(contentsOfFile: managedDisk, encoding: .utf8),
            "snapshot-target"
        )
        let recoveredJournal = try XCTUnwrap(try fixture.records().last(where: {
            $0.plan.kind == .workspaceRestore
        }))
        XCTAssertEqual(
            recoveredJournal.state.status,
            .completed,
            "recovery diagnostic: \(recovered.status(id: fixture.machineID)?.lastError ?? "none")"
        )
    }

    func testSnapshotCompletionRecoveryRejectsMissingBoundKernel() throws {
        let fixture = try LifecycleFixture(name: #function)
        defer { fixture.cleanup() }
        var manager: MachineManager? = fixture.makeManager()
        _ = try fixture.createMachine(try XCTUnwrap(manager))
        try XCTUnwrap(manager).installLifecycleFaultInjectorForTesting { point in
            if point == .completionBeforeJournalWrite(.snapshotting) {
                throw MachineLifecycleInjectedCrash()
            }
        }

        let snapshot = try XCTUnwrap(manager).snapshot(
            id: fixture.machineID,
            snapshotID: "bound-snapshot"
        )
        XCTAssertEqual(
            try XCTUnwrap(try fixture.records().last(where: {
                $0.plan.kind == .workspaceSnapshot
            })).state.status,
            .running
        )
        try FileManager.default.removeItem(atPath: snapshot.kernelPath)
        manager = nil

        let recovered = fixture.makeManager()
        XCTAssertEqual(recovered.status(id: fixture.machineID)?.state, .stopped)
        let recoveredJournal = try XCTUnwrap(try fixture.records().last(where: {
            $0.plan.kind == .workspaceSnapshot
        }))
        XCTAssertEqual(recoveredJournal.state.status, .failed)
        XCTAssertTrue(
            recovered.status(id: fixture.machineID)?.lastError?
                .contains("interrupted snapshot") == true
        )
        XCTAssertFalse(try recovered.listSnapshots(machineID: fixture.machineID).contains {
            $0.id == "bound-snapshot"
        })
    }

    func testRestoreCompletionRecoveryRejectsTamperedLiveRootfs() throws {
        let fixture = try LifecycleFixture(name: #function)
        defer { fixture.cleanup() }
        var manager: MachineManager? = fixture.makeManager()
        _ = try fixture.createMachine(try XCTUnwrap(manager))
        let managedDisk = fixture.state + "/\(fixture.machineID)/rootfs.ext4"
        try Data("snapshot-authority".utf8).write(to: URL(fileURLWithPath: managedDisk))
        _ = try XCTUnwrap(manager).snapshot(id: fixture.machineID, snapshotID: "authority")
        try Data("later-state".utf8).write(to: URL(fileURLWithPath: managedDisk))
        try XCTUnwrap(manager).installLifecycleFaultInjectorForTesting { point in
            if point == .completionBeforeJournalWrite(.restoring) {
                throw MachineLifecycleInjectedCrash()
            }
        }

        _ = try XCTUnwrap(manager).restoreSnapshot(
            machineID: fixture.machineID,
            snapshotID: "authority"
        )
        try Data("tampered-after-commit".utf8).write(to: URL(fileURLWithPath: managedDisk))
        manager = nil

        let recovered = fixture.makeManager()
        XCTAssertEqual(recovered.status(id: fixture.machineID)?.state, .stopped)
        XCTAssertEqual(
            try String(contentsOfFile: managedDisk, encoding: .utf8),
            "tampered-after-commit"
        )
        let recoveredJournal = try XCTUnwrap(try fixture.records().last(where: {
            $0.plan.kind == .workspaceRestore
        }))
        XCTAssertEqual(recoveredJournal.state.status, .failed)
        XCTAssertTrue(
            recovered.status(id: fixture.machineID)?.lastError?
                .contains("requires repair") == true
        )
    }

    func testInterruptedDeleteRestoresQuarantinedMachineOnRestart() throws {
        let fixture = try LifecycleFixture(name: #function)
        defer { fixture.cleanup() }
        var manager: MachineManager? = fixture.makeManager()
        _ = try fixture.createMachine(try XCTUnwrap(manager))
        try XCTUnwrap(manager).installLifecycleFaultInjectorForTesting { point in
            if point == .deleteAfterQuarantine { throw MachineLifecycleInjectedCrash() }
        }

        XCTAssertThrowsError(try XCTUnwrap(manager).delete(id: fixture.machineID)) { error in
            XCTAssertTrue(error is MachineLifecycleInjectedCrash)
        }
        XCTAssertNil(try XCTUnwrap(manager).status(id: fixture.machineID))
        manager = nil

        let recovered = fixture.makeManager()
        let status = try XCTUnwrap(recovered.status(id: fixture.machineID))
        XCTAssertEqual(status.state, .stopped)
        XCTAssertTrue(status.lastError?.contains("interrupted deletion") == true)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.state + "/\(fixture.machineID)/machine.json"
        ))
        _ = try waitForJournal(fixture, kind: .workspaceDelete, status: .failed)
    }
}

private final class LifecycleFixture {
    let machineID = "lifecycle-vm"
    let base: String
    let state: String
    let journal: String
    let store: DoryOperationJournalStore
    private let configuration: MachineManagerConfiguration

    init(
        name: String,
        executable: String = "/bin/sleep",
        requiresReadyHandoff: Bool = false,
        readyTimeout: TimeInterval = 2,
        restartPolicy: HvRestartPolicy = HvRestartPolicy(
            maxRestarts: 4,
            delaySeconds: 0.01,
            maximumDelaySeconds: 0.02,
            stableRunSeconds: 0
        )
    ) throws {
        _ = name
        base = "/tmp/dorylc-\(getpid())-\(UInt64.random(in: 0..<UInt64.max))"
        state = base + "/machines"
        journal = base + "/journal"
        configuration = MachineManagerConfiguration(
            vmmExecutablePath: executable,
            stateDirectory: state,
            runtimeDirectory: base + "/runtime",
            lifecycleJournalHome: journal,
            baseArguments: ["30"],
            passMachineArguments: false,
            requiresReadyHandoff: requiresReadyHandoff,
            handoffReadyTimeoutSeconds: readyTimeout,
            startupRestartPolicy: restartPolicy
        )
        store = try DoryOperationJournalStore(home: journal)
    }

    func makeManager() -> MachineManager {
        MachineManager(configuration: configuration)
    }

    @discardableResult
    func createMachine(
        _ manager: MachineManager,
        id: String? = nil
    ) throws -> DoryMachineStatus {
        try manager.create(DoryMachineConfiguration(
            id: id ?? machineID,
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath
        ))
    }

    func records() throws -> [DoryOperationRecord] {
        try store.list().sorted { $0.plan.createdAt < $1.plan.createdAt }
    }

    func cleanup() {
        try? FileManager.default.removeItem(atPath: base)
    }
}

private func waitForState(
    _ manager: MachineManager,
    id: String,
    state: DoryMachineState,
    timeout: TimeInterval = 3
) throws -> DoryMachineStatus {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let status = manager.status(id: id), status.state == state { return status }
        Thread.sleep(forTimeInterval: 0.01)
    }
    throw NSError(
        domain: "MachineManagerLifecycleJournalIntegrationTests",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "timed out waiting for machine state \(state)"]
    )
}

private func waitForJournal(
    _ fixture: LifecycleFixture,
    kind: DoryOperationKind,
    status: DoryOperationStatus,
    timeout: TimeInterval = 3
) throws -> DoryOperationRecord {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let record = try fixture.records().last(where: {
            $0.plan.kind == kind && $0.state.status == status
        }) {
            return record
        }
        Thread.sleep(forTimeInterval: 0.01)
    }
    throw NSError(
        domain: "MachineManagerLifecycleJournalIntegrationTests",
        code: 2,
        userInfo: [
            NSLocalizedDescriptionKey:
                "timed out waiting for lifecycle journal \(kind.rawValue) \(status.rawValue)",
        ]
    )
}
