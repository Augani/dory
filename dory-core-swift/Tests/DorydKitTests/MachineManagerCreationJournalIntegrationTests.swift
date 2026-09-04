import DoryOperations
import Foundation
import Testing
@testable import DorydKit

/// Authenticated process/control-plane tests reuse the signed production composition fixture.
/// The helper is synthetic and does not qualify a physical guest.
@Suite("Production creation caller journals", .serialized)
struct MachineManagerCreationJournalIntegrationTests {
    @Test("public creation plans under one UUID and replays after caller staging disappears")
    func publicCreateReplay() throws {
        try withProductionIntegrationTestStack {
            let harness = try ProductionDesktopUpdateHarness(sourceState: "stopped")
            defer { harness.cleanup() }
            let id = "new-root"
            let source = try creationInput(harness: harness, id: id)
            let operationID = UUID()
            let service = creationService(harness)
            let before = Set(try harness.journal.list().map(\.plan.id))
            let first = LockedPlanningCreateReply()
            service.machineCreate(source.xpc, operationID: operationID.uuidString.lowercased()) {
                first.set(ok: $0, body: $1, message: $2)
            }
            #expect(first.value.ok, Comment(rawValue: first.value.message))
            let manager = harness.context.machineManager
            let created = try #require(manager.status(id: id))
            #expect(created.runtimeIdentity.mode == .resolvedPlan)
            #expect([DoryMachineState.created, .stopped].contains(created.state))
            let record = try harness.journal.read(operationID)
            #expect(record.plan.kind == .workspaceProvision)
            #expect(record.state.status == .completed)
            #expect(Set(try harness.journal.list().map(\.plan.id)).subtracting(before) == [operationID])
            let plan = try harness.context.planning.plans.read(id: id)
            try FileManager.default.removeItem(atPath: source.diskPath)
            let replay = LockedPlanningCreateReply()
            service.machineCreate(source.xpc, operationID: operationID.uuidString.lowercased()) {
                replay.set(ok: $0, body: $1, message: $2)
            }
            #expect(replay.value.ok, Comment(rawValue: replay.value.message))
            #expect(try harness.context.planning.plans.read(id: id) == plan)
            let conflict = LockedPlanningCreateReply()
            let changed = try #require(source.xpc.mutableCopy() as? NSMutableDictionary)
            changed["cpuCount"] = 2
            service.machineCreate(changed, operationID: operationID.uuidString.lowercased()) {
                conflict.set(ok: $0, body: $1, message: $2)
            }
            #expect(!conflict.value.ok)
            #expect(try harness.journal.read(operationID).state == record.state)
            try manager.delete(id: id)
        }
    }

    @Test("fresh production activation resumes the original retained creation root")
    func planningFailureReplay() throws {
        try withProductionIntegrationTestStack {
            let harness = try ProductionDesktopUpdateHarness(sourceState: "stopped")
            defer { harness.cleanup() }
            let id = "retry-root"
            let source = try creationInput(harness: harness, id: id)
            let operationID = UUID()
            let manager = harness.context.machineManager
            let machine = source.machine
            let typed = try DoryMachineTypedSettingsPatch(xpcDictionary: source.xpc, allowsClears: false)
            #expect(throws: (any Error).self) {
                try manager.create(machine, typedSettings: typed, operationID: operationID,
                    productionPlanningController: RejectCreationPlanning())
            }
            let configurationPath = harness.fixture.machineConfiguration.stateDirectory + "/" + id + "/machine.json"
            let original = try Data(contentsOf: URL(fileURLWithPath: configurationPath))
            let pending = try harness.journal.read(operationID)
            #expect(pending.state.status != .completed && pending.state.status != .failed)
            #expect(manager.status(id: id)?.runtimeIdentity.mode == .requiresReplanning)
            let activation = harness.fixture.factory.activate(
                store: harness.fixture.store, machineConfiguration: harness.fixture.machineConfiguration,
                appVersion: harness.fixture.appVersion, publicKey: harness.fixture.publicKey,
                expectedArchitecture: "arm64")
            guard case .activated(let recoveredContext) = activation else {
                Issue.record("Creation recovery failed: \(activation)"); return
            }
            let recoveredManager = recoveredContext.machineManager
            defer { try? recoveredManager.delete(id: id) }
            let recovered = try #require(recoveredManager.status(id: id))
            #expect(recovered.runtimeIdentity.mode == .resolvedPlan)
            #expect(try recoveredManager.create(machine, typedSettings: typed, operationID: operationID) == recovered)
            #expect(try Data(contentsOf: URL(fileURLWithPath: configurationPath)) == original)
            #expect(try harness.journal.read(operationID).state.status == .completed)
            #expect(try harness.journal.list().filter { $0.plan.target.id == id }.count == 1)
        }
    }

    @Test("public stop cancels creation only after exact owned staging compensation")
    func stopCancelsStaging() throws {
        try withProductionIntegrationTestStack {
            let harness = try ProductionDesktopUpdateHarness(sourceState: "stopped")
            defer { harness.cleanup() }
            let id = "cancel-root"
            let input = try creationInput(harness: harness, id: id)
            let machine = input.machine
            let operationID = UUID()
            let manager = harness.context.machineManager
            let entered = DispatchSemaphore(value: 0)
            let resume = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0)
            let stopFinished = DispatchSemaphore(value: 0)
            let result = LockedPlanningCreateReply()
            manager.installLifecycleFaultInjectorForTesting { point in
                if point == .creationAfterTargetOwnership {
                    entered.signal()
                    guard resume.wait(timeout: .now() + 30) == .success else {
                        throw MachineManagerError.persistence("creation cancellation barrier timed out")
                    }
                }
            }
            defer { resume.signal(); manager.installLifecycleFaultInjectorForTesting { _ in } }
            let creator = Thread {
                defer { finished.signal() }
                do {
                    _ = try manager.create(machine, operationID: operationID)
                    result.set(ok: true, body: [:], message: "unexpected success")
                } catch { result.set(ok: false, body: [:], message: "\(error)") }
            }
            creator.stackSize = 8 * 1_024 * 1_024
            creator.start()
            #expect(entered.wait(timeout: .now() + 30) == .success)
            let stopper = Thread {
                defer { stopFinished.signal() }
                _ = try? manager.stop(id: id)
            }
            stopper.stackSize = 8 * 1_024 * 1_024
            stopper.start()
            let deadline = Date().addingTimeInterval(15)
            while !manager.creationCancellationRequestedForTesting(id: id, operationID: operationID), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            #expect(manager.creationCancellationRequestedForTesting(id: id, operationID: operationID))
            resume.signal()
            #expect(finished.wait(timeout: .now() + 30) == .success)
            #expect(stopFinished.wait(timeout: .now() + 30) == .success)
            #expect(!result.value.ok)
            #expect(manager.status(id: id) == nil)
            #expect(!FileManager.default.fileExists(atPath: harness.fixture.machineConfiguration.stateDirectory + "/" + id))
            let record = try harness.journal.read(operationID)
            #expect(record.state.status == .failed && record.state.result == .cancelled)
            #expect(try harness.journal.list().filter { $0.plan.target.id == id }.count == 1)
        }
    }

    @Test("public clone owns target planning while retaining source workspace and snapshot authority")
    func publicCloneSourcePreserved() throws {
        try withProductionIntegrationTestStack {
            let harness = try ProductionDesktopUpdateHarness(sourceState: "stopped")
            defer { harness.cleanup() }
            let manager = harness.context.machineManager
            let snapshot = try manager.snapshot(id: harness.id, snapshotID: "clone-source")
            let sourceConfiguration = try Data(contentsOf: URL(fileURLWithPath: harness.directory + "/machine.json"))
            let sourceRuntime = try #require(manager.status(id: harness.id)).runtimeIdentity
            let sourceWorkspace = try DoryWorkspaceRepository(root: harness.fixture.machineConfiguration.stateDirectory)
                .readPersistedRecord(id: harness.id)
            let before = Set(try harness.journal.list().map(\.plan.id))
            let id = "cloned-root"
            let operationID = UUID()
            let service = creationService(harness)
            let reply = LockedPlanningCreateReply()
            service.machineCloneSnapshot(harness.id, snapshotID: snapshot.id, newID: id,
                operationID: operationID.uuidString.lowercased()) { reply.set(ok: $0, body: $1, message: $2) }
            #expect(reply.value.ok, Comment(rawValue: reply.value.message))
            let clone = try #require(manager.status(id: id))
            #expect(clone.runtimeIdentity.mode == .resolvedPlan)
            #expect(clone.cloneReceipt?.sourceSnapshotID == snapshot.id)
            #expect(Set(try harness.journal.list().map(\.plan.id)).subtracting(before) == [operationID])
            let record = try harness.journal.read(operationID)
            #expect(record.plan.kind == .workspaceClone && record.state.status == .completed)
            #expect(manager.status(id: harness.id)?.runtimeIdentity == sourceRuntime)
            #expect(try Data(contentsOf: URL(fileURLWithPath: harness.directory + "/machine.json")) == sourceConfiguration)
            #expect(try DoryWorkspaceRepository(root: harness.fixture.machineConfiguration.stateDirectory)
                .readPersistedRecord(id: harness.id) == sourceWorkspace)
            #expect(try harness.diskPrefix() == harness.sourceDiskPrefix)
            let replay = LockedPlanningCreateReply()
            service.machineCloneSnapshot(harness.id, snapshotID: snapshot.id, newID: id,
                operationID: operationID.uuidString.lowercased()) { replay.set(ok: $0, body: $1, message: $2) }
            #expect(replay.value.ok, Comment(rawValue: replay.value.message))
            #expect(try harness.journal.read(operationID).state == record.state)
            try manager.delete(id: id)
        }
    }

    @Test("public clone binds an imported snapshot whose source workspace is absent")
    func detachedImportedClone() throws {
        try withProductionIntegrationTestStack {
            let harness = try ProductionDesktopUpdateHarness(sourceState: "stopped")
            defer { harness.cleanup() }
            let manager = harness.context.machineManager
            let snapshot = try manager.snapshot(id: harness.id, snapshotID: "detached-source")
            let bundle = harness.fixture.root.appendingPathComponent("detached.dorymachine").path
            try manager.exportSnapshot(machineID: harness.id, snapshotID: snapshot.id, toPath: bundle)
            try manager.delete(id: harness.id)
            let imported = try manager.importSnapshot(fromPath: bundle)
            #expect(manager.status(id: harness.id) == nil)
            #expect(imported.runtimeIdentity.mode == .requiresReplanning)
            let before = Set(try harness.journal.list().map(\.plan.id))
            let operationID = UUID()
            let reply = LockedPlanningCreateReply()
            creationService(harness).machineCloneSnapshot(imported.machineID, snapshotID: imported.id,
                newID: "detached-clone", operationID: operationID.uuidString.lowercased()) {
                reply.set(ok: $0, body: $1, message: $2)
            }
            #expect(reply.value.ok, Comment(rawValue: reply.value.message))
            let clone = try #require(manager.status(id: "detached-clone"))
            defer { try? manager.delete(id: "detached-clone") }
            #expect(clone.runtimeIdentity.mode == .resolvedPlan)
            #expect(clone.cloneReceipt?.sourceSnapshotID == imported.id)
            #expect(clone.cloneReceipt?.sourceRootfsSHA256 == imported.artifactEvidence?.rootfs.sha256)
            #expect(manager.status(id: imported.machineID) == nil)
            #expect(try manager.listSnapshots(machineID: imported.machineID) == [imported])
            #expect(Set(try harness.journal.list().map(\.plan.id)).subtracting(before) == [operationID])
            let record = try harness.journal.read(operationID)
            #expect(record.plan.kind == .workspaceClone && record.state.status == .completed)
            let operation = try {
                let lease = try harness.journal.acquire(operationID)
                return try lease.readWorkspaceLifecycleOperation()
            }()
            #expect(operation.source.state == .absent)
            #expect(operation.source.runtime == nil)
            #expect(operation.targetSnapshotAuthority != nil)
        }
    }
}

private struct CreationIntegrationInput {
    let xpc: NSDictionary
    let diskPath: String
    let machine: DoryMachineConfiguration
}

private func creationInput(harness: ProductionDesktopUpdateHarness, id: String) throws -> CreationIntegrationInput {
    let disk = harness.fixture.root.appendingPathComponent(id + ".raw")
    try Data("creation-input".utf8).write(to: disk)
    let handle = try FileHandle(forWritingTo: disk)
    try handle.truncate(atOffset: 32 * 1_024 * 1_024 * 1_024)
    try handle.close()
    return .init(xpc: [
        "id": id, "kernelPath": harness.fixture.directKernelPath, "rootfsPath": disk.path,
        "displayMode": "desktop", "memoryMB": UInt64(4_096), "cpuCount": 4,
        "guestIdentityIntent": ["desktop": ["distributionIdentifier": "ubuntu"]],
        "desktopGraphicsPreference": "software"
    ], diskPath: disk.path, machine: .init(id: id, kernelPath: harness.fixture.directKernelPath,
        rootfsPath: disk.path, memoryMB: 4096, cpuCount: 4, displayMode: .desktop))
}

private func creationService(_ harness: ProductionDesktopUpdateHarness) -> DorydService {
    DorydService(socketPath: "/unused", machineManager: harness.context.machineManager,
        productionPlanningController: harness.context.planningController)
}

private struct RejectCreationPlanning: DoryDaemonVirtualMachineProductionPlanningControlling {
    func authorityRevision(for reference: DoryVMResolverReference) throws -> UInt64? { nil }
    func publishResolvedPlan(_ request: DoryDaemonVirtualMachinePlanningTransactionRequest,
        artifacts: [DoryDaemonVirtualMachinePlanningArtifactPublication]) throws {
        throw MachineManagerError.persistence("injected creation planning failure")
    }
}
