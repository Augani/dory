import DoryOperations
import Foundation
import Testing
@testable import DorydKit

@Suite("Production start caller journals", .serialized)
struct MachineManagerStartJournalIntegrationTests {
    @Test("stopped admission renewal and start share the caller root")
    func stoppedStartReplay() throws {
        try withProductionIntegrationTestStack {
            let harness = try ProductionDesktopUpdateHarness(sourceState: "stopped")
            defer { harness.cleanup() }
            let manager = harness.context.machineManager
            let source = try harness.context.planning.plans.read(id: harness.id)
            let before = Set(try harness.journal.list().map(\.plan.id))
            let operationID = UUID()
            let result = LockedPlanningCreateReply()
            DorydService(socketPath: "/unused", machineManager: manager,
                productionPlanningController: harness.context.planningController)
                .machineStart(harness.id, operationID: operationID.uuidString.lowercased()) {
                    result.set(ok: $0, body: $1, message: $2)
                }
            try #require(result.value.ok, Comment(rawValue: result.value.message))
            try awaitStart(harness, operationID: operationID)
            let plan = try harness.context.planning.plans.read(id: harness.id)
            #expect(plan.planRevision > source.planRevision)
            let reconnectStore = DoryRuntimeReconnectRecordStore(root: harness.fixture.machineConfiguration.stateDirectory)
            let reconnect = try reconnectStore.read(machineID: harness.id)
            let replay = try manager.start(id: harness.id, operationID: operationID)
            #expect(replay.state == .running)
            #expect(try reconnectStore.read(machineID: harness.id) == reconnect)
            #expect(try harness.context.planning.plans.read(id: harness.id) == plan)
            #expect(Set(try harness.journal.list().map(\.plan.id)).subtracting(before) == [operationID])
            #expect(reconnect.launchIdentity.operationID == operationID.uuidString.lowercased())
            do {
                let lease = try harness.journal.acquire(operationID)
                let root = try lease.readWorkspaceLifecycleOperation()
                #expect(root.kind == .starting && root.target.plannedRuntime != nil)
                #expect(root.source.configurationAuthority == root.target.configurationAuthority)
                #expect(try lease.startPlanCheckpoint() == plan)
            }
            let stopID = UUID()
            _ = try manager.stop(id: harness.id, operationID: stopID)
            let stoppedPlan = try harness.context.planning.plans.read(id: harness.id)
            #expect(try manager.start(id: harness.id, operationID: operationID).state == .stopped)
            #expect(throws: (any Error).self) { try manager.start(id: harness.id, operationID: stopID) }
            #expect(manager.status(id: harness.id)?.pid == nil)
            #expect(try harness.context.planning.plans.read(id: harness.id) == stoppedPlan)
            #expect(Set(try harness.journal.list().map(\.plan.id)).subtracting(before) == [operationID, stopID])
        }
    }

    @Test("altered immutable source or plan is rejected before a start journal", arguments: ["kernel", "plan"])
    func sourceRejectionHasNoMutation(artifact: String) throws {
        try withProductionIntegrationTestStack {
            let harness = try ProductionDesktopUpdateHarness(sourceState: "stopped")
            defer { harness.cleanup() }
            let manager = harness.context.machineManager
            let path = artifact == "kernel" ? harness.managedKernelPath
                : harness.directory + "/" + DoryResolvedMachinePlanRepository.recordFileName
            let original = try Data(contentsOf: URL(fileURLWithPath: path))
            defer { try? original.write(to: URL(fileURLWithPath: path)) }
            let before = try harness.journal.list()
            let source = try #require(manager.status(id: harness.id))
            try Data("altered start authority".utf8).write(to: URL(fileURLWithPath: path))
            #expect(throws: (any Error).self) { try manager.start(id: harness.id, operationID: UUID()) }
            #expect(try harness.journal.list() == before)
            #expect(manager.status(id: harness.id)?.runtimeIdentity == source.runtimeIdentity)
            #expect(manager.status(id: harness.id)?.state == .stopped)
            #expect(manager.status(id: harness.id)?.pid == nil)
        }
    }

    @Test("unplanned staged workspace resolves inside the public start UUID")
    func unplannedStart() throws {
        try withProductionIntegrationTestStack {
            let harness = try ProductionDesktopUpdateHarness(sourceState: "stopped")
            defer { harness.cleanup() }
            let manager = harness.context.machineManager
            let id = "unplanned-start"
            let config = DoryMachineConfiguration(id: id, kernelPath: harness.fixture.directKernelPath,
                rootfsPath: harness.fixture.root.appendingPathComponent("desktop.raw").path,
                memoryMB: 4_096, cpuCount: 4, displayMode: .desktop)
            let settings = try DoryMachineTypedSettingsPatch(xpcDictionary: [
                "guestIdentityIntent": ["desktop": ["distributionIdentifier": "ubuntu"]],
                "desktopGraphicsPreference": "software",
            ], allowsClears: false)
            _ = try manager.stageMachineForBootstrap(config, typedSettings: settings)
            defer { try? manager.delete(id: id) }
            #expect(manager.status(id: id)?.runtimeIdentity.mode == .requiresReplanning)
            let before = Set(try harness.journal.list().map(\.plan.id))
            let operationID = UUID()
            _ = try harness.drive { try manager.start(id: id, operationID: operationID) }
            try awaitStart(harness, machineID: id, operationID: operationID)
            #expect(Set(try harness.journal.list().map(\.plan.id)).subtracting(before) == [operationID])
            #expect(manager.status(id: id)?.runtimeIdentity.mode == .resolvedPlan)
            #expect(try harness.journal.read(operationID).state.status == .completed)
        }
    }

    @Test("failed production planning retries the same root after source bytes return")
    func planningFailureRetry() throws {
        try withProductionIntegrationTestStack {
            let harness = try ProductionDesktopUpdateHarness(sourceState: "stopped")
            defer { harness.cleanup() }
            let manager = harness.context.machineManager
            let operationID = UUID()
            let before = Set(try harness.journal.list().map(\.plan.id))
            let kernel = harness.managedKernelPath
            let hidden = kernel + ".start-test-hidden"
            let moved = StartFaultObservation()
            manager.installLifecycleFaultInjectorForTesting { point in
                if point == .startBeforePlanning, moved.recordOnce() {
                    try FileManager.default.moveItem(atPath: kernel, toPath: hidden)
                }
            }
            #expect(throws: (any Error).self) { try manager.start(id: harness.id, operationID: operationID) }
            try #require(moved.observed)
            #expect(manager.status(id: harness.id)?.pid == nil)
            #expect(try harness.journal.read(operationID).state.status != .completed)
            try FileManager.default.moveItem(atPath: hidden, toPath: kernel)
            manager.installLifecycleFaultInjectorForTesting { _ in }
            _ = try harness.drive { try manager.start(id: harness.id, operationID: operationID) }
            try awaitStart(harness, operationID: operationID)
            #expect(Set(try harness.journal.list().map(\.plan.id)).subtracting(before) == [operationID])
        }
    }

    @Test("fresh activation retains start UUID across planning and completed readiness", arguments: [false, true])
    func interruptedStartRecovery(afterReadiness: Bool) throws {
        try withProductionIntegrationTestStack {
            let harness = try ProductionDesktopUpdateHarness(sourceState: "stopped")
            defer { harness.cleanup() }
            let manager = harness.context.machineManager
            let operationID = UUID()
            let before = Set(try harness.journal.list().map(\.plan.id))
            let fault = StartFaultObservation()
            manager.installLifecycleFaultInjectorForTesting { point in
                if point == (afterReadiness ? .completionBeforeJournalWrite(.starting) : .startAfterPlanning),
                   fault.recordOnce() { throw MachineLifecycleInjectedCrash() }
            }
            if afterReadiness {
                _ = try harness.drive { try manager.start(id: harness.id, operationID: operationID) }
                let deadline = Date().addingTimeInterval(20)
                while !fault.observed && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            } else {
                #expect(throws: (any Error).self) { try manager.start(id: harness.id, operationID: operationID) }
            }
            try #require(fault.observed)
            manager.installLifecycleFaultInjectorForTesting { _ in }
            let plan = try harness.context.planning.plans.read(id: harness.id)
            let reconnectStore = DoryRuntimeReconnectRecordStore(root: harness.fixture.machineConfiguration.stateDirectory)
            let previous = afterReadiness ? try reconnectStore.read(machineID: harness.id) : nil
            let activation = harness.fixture.factory.activate(store: harness.fixture.store,
                machineConfiguration: harness.fixture.machineConfiguration,
                appVersion: harness.fixture.appVersion, publicKey: harness.fixture.publicKey,
                expectedArchitecture: "arm64")
            guard case .activated(let recovered) = activation else {
                throw MachineManagerError.persistence("start recovery failed: \(activation)")
            }
            defer { try? recovered.machineManager.delete(id: harness.id) }
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline,
                  try harness.journal.read(operationID).state.status != .completed
                    || recovered.machineManager.status(id: harness.id)?.state != .running {
                Thread.sleep(forTimeInterval: 0.01)
            }
            #expect(try harness.journal.read(operationID).state.status == .completed)
            #expect(recovered.machineManager.status(id: harness.id)?.state == .running)
            #expect(try recovered.planning.plans.read(id: harness.id) == plan)
            let reconnect = try reconnectStore.read(machineID: harness.id)
            #expect(reconnect.launchIdentity.operationID == operationID.uuidString.lowercased())
            if let previous { #expect(reconnect.processIdentity == previous.processIdentity) }
            _ = try recovered.machineManager.start(id: harness.id, operationID: operationID)
            #expect(try reconnectStore.read(machineID: harness.id) == reconnect)
            #expect(Set(try harness.journal.list().map(\.plan.id)).subtracting(before) == [operationID])
        }
    }
}

private func awaitStart(_ harness: ProductionDesktopUpdateHarness, machineID: String? = nil, operationID: UUID) throws {
    let id = machineID ?? harness.id
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline,
          try harness.journal.read(operationID).state.status != .completed
            || harness.context.machineManager.status(id: id)?.state != .running {
        if harness.context.machineManager.status(id: id)?.state == .failed { break }
        Thread.sleep(forTimeInterval: 0.01)
    }
    guard harness.context.machineManager.status(id: id)?.state == .running,
          try harness.journal.read(operationID).state.status == .completed else {
        throw MachineManagerError.persistence("start did not complete: \(harness.context.machineManager.status(id: id)?.lastError ?? "no running state")")
    }
}

private final class StartFaultObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var observed: Bool { lock.withLock { value } }
    func recordOnce() -> Bool { lock.withLock { if value { return false }; value = true; return true } }
}
