import DoryOperations
import Foundation
import Testing
@testable import DorydKit

@Suite("Production pause and resume replay", .serialized)
struct MachineManagerPowerReplayIntegrationTests {
    @Test("completed power UUIDs return current state without repeating helper actions")
    func completedPowerReplay() throws {
        try withProductionIntegrationTestStack {
            let harness = try ProductionDesktopUpdateHarness(sourceState: "running")
            defer { harness.cleanup() }
            let manager = harness.context.machineManager
            let service = DorydService(socketPath: "/unused", machineManager: manager,
                                       productionPlanningController: harness.context.planningController)
            let plan = try harness.context.planning.plans.read(id: harness.id)
            let reconnectStore = DoryRuntimeReconnectRecordStore(root: harness.fixture.machineConfiguration.stateDirectory)
            let reconnect = try reconnectStore.read(machineID: harness.id)
            let before = Set(try harness.journal.list().map(\.plan.id))
            let pauseID = UUID()
            let resumeID = UUID()
            func invoke(_ operationID: UUID, pause: Bool) throws -> DoryMachineState {
                let reply = LockedPlanningCreateReply()
                if pause {
                    service.machinePause(harness.id, operationID: operationID.uuidString.lowercased()) {
                        reply.set(ok: $0, body: $1, message: $2)
                    }
                } else {
                    service.machineResume(harness.id, operationID: operationID.uuidString.lowercased()) {
                        reply.set(ok: $0, body: $1, message: $2)
                    }
                }
                try #require(reply.value.ok, Comment(rawValue: reply.value.message))
                return try #require(manager.status(id: harness.id)).state
            }
            func audit() throws -> Data {
                let url = harness.fixture.root.appendingPathComponent("runtime-events.log")
                return FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : Data()
            }
            #expect(try invoke(pauseID, pause: true) == .paused)
            let pausedAudit = try audit()
            #expect(try invoke(pauseID, pause: true) == .paused)
            #expect(try audit() == pausedAudit)
            #expect(try invoke(resumeID, pause: false) == .running)
            let runningAudit = try audit()
            #expect(try invoke(resumeID, pause: false) == .running)
            #expect(try invoke(pauseID, pause: true) == .running)
            #expect(try audit() == runningAudit)
            #expect(try reconnectStore.read(machineID: harness.id) == reconnect)
            #expect(try harness.context.planning.plans.read(id: harness.id) == plan)
            #expect(try harness.journal.read(pauseID).state.status == .completed)
            #expect(try harness.journal.read(resumeID).state.status == .completed)

            let secondPauseID = UUID()
            #expect(try manager.pause(id: harness.id, operationID: secondPauseID).state == .paused)
            let secondPauseAudit = try audit()
            #expect(try invoke(resumeID, pause: false) == .paused)
            #expect(try audit() == secondPauseAudit)
            let stopID = UUID()
            _ = try manager.stop(id: harness.id, operationID: stopID)
            let stoppedAudit = try audit()
            let journalAfterStop = try harness.journal.list()
            #expect(try invoke(pauseID, pause: true) == .stopped)
            #expect(try invoke(resumeID, pause: false) == .stopped)
            #expect(throws: (any Error).self) { try manager.pause(id: harness.id, operationID: resumeID) }
            #expect(throws: (any Error).self) { try manager.resume(id: harness.id, operationID: pauseID) }
            #expect(throws: (any Error).self) { try manager.pause(id: harness.id, operationID: stopID) }
            #expect(throws: (any Error).self) { try manager.resume(id: "another-machine", operationID: resumeID) }
            #expect(manager.status(id: harness.id)?.pid == nil)
            #expect(try audit() == stoppedAudit)
            #expect(try harness.journal.list() == journalAfterStop)
            #expect(try harness.context.planning.plans.read(id: harness.id) == plan)
            #expect(Set(journalAfterStop.map(\.plan.id)).subtracting(before)
                == [pauseID, resumeID, secondPauseID, stopID])
        }
    }
}
