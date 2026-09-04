import DoryOperations
import Foundation
import Testing
@testable import DorydKit

@Suite("Production snapshot root", .serialized)
struct DoryProductionSnapshotCreationTests {
    @Test("snapshot owns quiescence, replacement planning, readiness and replay under one UUID",
          arguments: ["stopped", "running", "paused"])
    func successAndReplay(sourceState: String) throws {
        try withProductionIntegrationTestStack {
            let harness = try ProductionDesktopUpdateHarness(sourceState: sourceState)
            defer { harness.cleanup() }
            let manager = harness.context.machineManager
            let operationID = UUID()
            let before = try harness.journal.list().count
            // Ordinary guest writes invalidate a start snapshot, but do not relinquish the
            // source backing that a snapshot must quiesce and publish under fresh authority.
            let disk = try FileHandle(forWritingTo: URL(fileURLWithPath: harness.directory + "/rootfs.ext4"))
            try disk.write(contentsOf: Data("snapshot-workload".utf8))
            try disk.synchronize()
            try disk.close()
            let snapshot = try harness.drive {
                try manager.snapshot(id: harness.id, note: "root snapshot", operationID: operationID)
            }
            #expect(snapshot.id == "snapshot-" + operationID.uuidString.lowercased())
            #expect(snapshot.runtimeIdentity == harness.source.runtimeIdentity)
            #expect(snapshot.artifactEvidence?.isValid == true)
            let snapshotDisk = try FileHandle(forReadingFrom: URL(fileURLWithPath: snapshot.rootfsPath))
            #expect(try snapshotDisk.read(upToCount: 17) == Data("snapshot-workload".utf8))
            try snapshotDisk.close()
            let completed = try #require(manager.status(id: harness.id))
            #expect(completed.state.rawValue == sourceState)
            #expect(completed.activeOperationID == nil)
            #expect(completed.failure == nil)
            let plan = try harness.context.planning.plans.read(id: harness.id)
            #expect(completed.runtimeIdentity.resolvedPlan == plan)
            #expect(plan.definitionRevision == harness.sourceWorkspace.definition.lifecycle.revision)
            #expect(try Data(contentsOf: URL(fileURLWithPath: harness.directory + "/machine.json"))
                == harness.sourceConfigurationData)
            #expect(try DoryWorkspaceRepository(root: harness.fixture.machineConfiguration.stateDirectory)
                .readPersistedRecord(id: harness.id) == harness.sourceWorkspace)
            let record = try harness.journal.read(operationID)
            #expect(record.plan.kind == .workspaceSnapshot)
            #expect(record.state.status == .completed)
            #expect(record.state.result == .succeeded)
            #expect(try harness.journal.list().count == before + 1)
            try assertAdmission(harness.context, id: harness.id, sourceState: sourceState)
            if sourceState != "stopped" {
                #expect(try DoryRuntimeReconnectRecordStore(root: harness.fixture.machineConfiguration.stateDirectory)
                    .read(machineID: harness.id).launchIdentity.operationID == operationID.uuidString.lowercased())
            }
            let replay = try manager.snapshot(id: harness.id, note: "root snapshot",
                createdISO: "a later retry preserves the original timestamp", operationID: operationID)
            #expect(replay == snapshot)
            #expect(manager.status(id: harness.id)?.pid == completed.pid)
            #expect(try harness.context.planning.plans.read(id: harness.id) == plan)
            #expect(throws: (any Error).self) {
                try manager.snapshot(id: harness.id, note: "different input", operationID: operationID)
            }
            if sourceState == "stopped" {
                let kernel = URL(fileURLWithPath: snapshot.kernelPath)
                let bytes = try Data(contentsOf: kernel)
                let output = try FileHandle(forWritingTo: kernel)
                try output.write(contentsOf: Data([0x00]))
                try output.close()
                #expect(throws: (any Error).self) {
                    try manager.snapshot(id: harness.id, note: "root snapshot", operationID: operationID)
                }
                try bytes.write(to: kernel)
                #expect(manager.status(id: harness.id)?.pid == completed.pid)
            }
            #expect(try harness.journal.list().count == before + 1)
        }
    }

    @Test("fresh activation compensates interrupted snapshot copy and restores source power",
          arguments: ["stopped", "running", "paused"])
    func interruptedCopyRecovery(sourceState: String) throws {
        try withProductionIntegrationTestStack {
            let harness = try ProductionDesktopUpdateHarness(sourceState: sourceState)
            defer { harness.cleanup() }
            let operationID = UUID()
            let snapshotID = "interrupted-copy"
            let before = try harness.journal.list().count
            let observed = SnapshotCreationFaultObservation()
            harness.context.machineManager.installLifecycleFaultInjectorForTesting { point in
                if point == .snapshotAfterRootfs, observed.recordOnce() { throw MachineLifecycleInjectedCrash() }
            }
            #expect(throws: (any Error).self) {
                try harness.drive {
                    try harness.context.machineManager.snapshot(id: harness.id, note: "partial copy",
                        snapshotID: snapshotID, operationID: operationID)
                }
            }
            try #require(observed.wasObserved)
            #expect(FileManager.default.fileExists(atPath: harness.directory + "/snapshots/" + snapshotID + ".ext4"))
            let recovered = try reactivate(harness)
            defer { try? recovered.machineManager.delete(id: harness.id) }
            let result = try #require(recovered.machineManager.status(id: harness.id))
            #expect(result.state.rawValue == sourceState)
            #expect(result.failure?.recoveryDisposition == .rollbackCompleted)
            #expect(try harness.diskPrefix() == harness.sourceDiskPrefix)
            #expect(try Data(contentsOf: URL(fileURLWithPath: harness.managedKernelPath)) == harness.sourceKernel)
            for suffix in ["ext4", "kernel", "json"] {
                #expect(!FileManager.default.fileExists(atPath: harness.directory + "/snapshots/" + snapshotID + "." + suffix))
            }
            #expect(try harness.journal.read(operationID).state.status == .failed)
            #expect(try harness.journal.list().count == before + 1)
            try assertAdmission(recovered, id: harness.id, sourceState: sourceState)
            #expect(try recovered.planning.plans.read(id: harness.id) == result.runtimeIdentity.resolvedPlan)
            #expect(throws: (any Error).self) {
                try recovered.machineManager.snapshot(id: harness.id, note: "partial copy",
                    snapshotID: snapshotID, operationID: operationID)
            }
            #expect(try harness.journal.list().count == before + 1)
        }
    }

    @Test("fresh activation completes published snapshot without replacing its plan or helper",
          arguments: ["stopped", "running", "paused"])
    func completionRecovery(sourceState: String) throws {
        try withProductionIntegrationTestStack {
            let harness = try ProductionDesktopUpdateHarness(sourceState: sourceState)
            defer { harness.cleanup() }
            let operationID = UUID()
            let before = try harness.journal.list().count
            let observed = SnapshotCreationFaultObservation()
            harness.context.machineManager.installLifecycleFaultInjectorForTesting { point in
                if point == .completionBeforeJournalWrite(.snapshotting), observed.recordOnce() {
                    throw MachineLifecycleInjectedCrash()
                }
            }
            #expect(throws: (any Error).self) {
                try harness.drive {
                    try harness.context.machineManager.snapshot(id: harness.id, note: "published snapshot",
                        snapshotID: "published", operationID: operationID)
                }
            }
            try #require(observed.wasObserved)
            let finished = try #require(harness.context.machineManager.status(id: harness.id))
            let plan = try harness.context.planning.plans.read(id: harness.id)
            let metadata = try Data(contentsOf: URL(fileURLWithPath: harness.directory + "/snapshots/published.json"))
            #expect(try harness.journal.read(operationID).state.status != .completed)
            let recovered = try reactivate(harness)
            defer { try? recovered.machineManager.delete(id: harness.id) }
            let result = try #require(recovered.machineManager.status(id: harness.id))
            #expect(result.state.rawValue == sourceState)
            #expect(result.pid == finished.pid)
            #expect(result.activeOperationID == nil)
            #expect(result.failure == nil)
            #expect(try recovered.planning.plans.read(id: harness.id) == plan)
            #expect(try Data(contentsOf: URL(fileURLWithPath: harness.directory + "/snapshots/published.json")) == metadata)
            #expect(try harness.journal.read(operationID).state.status == .completed)
            #expect(try harness.journal.list().count == before + 1)
            try assertAdmission(recovered, id: harness.id, sourceState: sourceState)
            let replay = try recovered.machineManager.snapshot(id: harness.id, note: "published snapshot",
                snapshotID: "published", operationID: operationID)
            #expect(replay.runtimeIdentity == harness.source.runtimeIdentity)
            #expect(recovered.machineManager.status(id: harness.id)?.pid == result.pid)
            #expect(try harness.journal.list().count == before + 1)
        }
    }

    @Test("changed source or redirected snapshot directory blocks cleanup and permits repair",
          arguments: ["source-metadata", "snapshot-directory"])
    func compensationFailureCanBeRepairedAndRetried(change: String) throws {
        try withProductionIntegrationTestStack {
            let harness = try ProductionDesktopUpdateHarness(sourceState: "stopped")
            defer { harness.cleanup() }
            let manager = harness.context.machineManager
            let operationID = UUID()
            let observed = SnapshotCreationFaultObservation()
            let metadata = URL(fileURLWithPath: harness.directory + "/machine.json")
            let snapshots = URL(fileURLWithPath: harness.directory + "/snapshots")
            let redirected = harness.fixture.root.appendingPathComponent("redirected-snapshots")
            manager.installLifecycleFaultInjectorForTesting { point in
                if point == .snapshotAfterRootfs, observed.recordOnce() {
                    if change == "source-metadata" {
                        try (harness.sourceConfigurationData + Data("\n".utf8)).write(to: metadata)
                    } else {
                        try FileManager.default.moveItem(at: snapshots, to: redirected)
                        try FileManager.default.createSymbolicLink(at: snapshots, withDestinationURL: redirected)
                    }
                    throw SnapshotCreationTestInterruption.expected
                }
            }
            #expect(throws: (any Error).self) {
                try harness.drive {
                    try manager.snapshot(id: harness.id, note: "repairable snapshot",
                        snapshotID: "repairable", operationID: operationID)
                }
            }
            try #require(observed.wasObserved)
            let partial = harness.directory + "/snapshots/repairable.ext4"
            #expect(FileManager.default.fileExists(atPath: partial))
            #expect(try harness.journal.read(operationID).state.status != .failed)
            #expect(manager.status(id: harness.id)?.activeOperationID == nil)
            if change == "source-metadata" {
                try harness.sourceConfigurationData.write(to: metadata)
            } else {
                try FileManager.default.removeItem(at: snapshots)
                try FileManager.default.moveItem(at: redirected, to: snapshots)
            }
            manager.installLifecycleFaultInjectorForTesting { _ in }
            #expect(throws: (any Error).self) {
                try harness.drive {
                    try manager.snapshot(id: harness.id, note: "repairable snapshot",
                        snapshotID: "repairable", operationID: operationID)
                }
            }
            #expect(try harness.journal.read(operationID).state.status == .failed)
            #expect(!FileManager.default.fileExists(atPath: partial))
            #expect(manager.status(id: harness.id)?.state == .stopped)
            #expect(try harness.diskPrefix() == harness.sourceDiskPrefix)
        }
    }

    @Test("failed freeze and thaw replace the uncertain source only under the snapshot root",
          arguments: [false, true])
    func failedQuiescenceRecovery(interruptAfterStop: Bool) throws {
        try withProductionIntegrationTestStack {
            let harness = try ProductionDesktopUpdateHarness(
                sourceState: "running", snapshotQuiesceFailure: true
            )
            defer { harness.cleanup() }
            let manager = harness.context.machineManager
            let sourcePID = try #require(manager.status(id: harness.id)?.pid)
            let operationID = UUID()
            let before = try harness.journal.list().count
            let observed = SnapshotCreationFaultObservation()
            if interruptAfterStop {
                manager.installLifecycleFaultInjectorForTesting { point in
                    if point == .stopAfterProcessStop, observed.recordOnce() {
                        throw MachineLifecycleInjectedCrash()
                    }
                }
            }
            #expect(throws: (any Error).self) {
                try harness.drive {
                    try manager.snapshot(id: harness.id, note: "failed quiescence",
                        snapshotID: "quiescence", operationID: operationID)
                }
            }
            #expect(harness.snapshotFreezeReceiptIDs.count == 1)
            #expect(harness.snapshotThawReceiptIDs == harness.snapshotFreezeReceiptIDs)
            let context: DoryDaemonVirtualMachineProductionActivationContext
            if interruptAfterStop {
                try #require(observed.wasObserved)
                #expect(try harness.journal.read(operationID).state.status != .failed)
                context = try reactivate(harness)
            } else {
                context = harness.context
            }
            defer { if interruptAfterStop { try? context.machineManager.delete(id: harness.id) } }
            let result = try #require(context.machineManager.status(id: harness.id))
            #expect(result.state == .running)
            #expect(result.pid != sourcePID)
            #expect(result.failure?.recoveryDisposition == .rollbackCompleted)
            #expect(try harness.diskPrefix() == harness.sourceDiskPrefix)
            #expect(try harness.journal.read(operationID).state.status == .failed)
            #expect(try harness.journal.list().count == before + 1)
            #expect(harness.snapshotFreezeReceiptIDs.count == 1)
            #expect(harness.snapshotThawReceiptIDs == harness.snapshotFreezeReceiptIDs)
            #expect(try DoryRuntimeReconnectRecordStore(root: harness.fixture.machineConfiguration.stateDirectory)
                .read(machineID: harness.id).launchIdentity.operationID == operationID.uuidString.lowercased())
            #expect(!FileManager.default.fileExists(atPath: harness.directory + "/snapshots/quiescence.ext4"))
            #expect(!FileManager.default.fileExists(atPath: harness.directory + "/snapshots/quiescence.json"))
            try assertAdmission(context, id: harness.id, sourceState: "running")
            do {
                let lease = try harness.journal.acquire(operationID)
                let attempt: UUID? = try lease.snapshotCreationCheckpoint(.quiesceAttempted)
                #expect(attempt == operationID)
            }
        }
    }
}

private func reactivate(_ harness: ProductionDesktopUpdateHarness) throws
    -> DoryDaemonVirtualMachineProductionActivationContext {
    let result = harness.fixture.factory.activate(
        store: harness.fixture.store, machineConfiguration: harness.fixture.machineConfiguration,
        appVersion: harness.fixture.appVersion, publicKey: harness.fixture.publicKey,
        expectedArchitecture: "arm64")
    guard case .activated(let context) = result else {
        throw MachineManagerError.persistence("Snapshot recovery activation failed: \(result)")
    }
    return context
}

private func assertAdmission(_ context: DoryDaemonVirtualMachineProductionActivationContext,
    id: String, sourceState: String) throws {
    #expect(try context.planning.resourceLedger.snapshot().leases.first {
        $0.binding.machineID == id
    }?.state == (sourceState == "stopped" ? .stopped : .running))
}

private final class SnapshotCreationFaultObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var observed = false
    var wasObserved: Bool { lock.withLock { observed } }
    func recordOnce() -> Bool {
        lock.withLock {
            guard !observed else { return false }
            observed = true
            return true
        }
    }
}

private enum SnapshotCreationTestInterruption: Error { case expected }
