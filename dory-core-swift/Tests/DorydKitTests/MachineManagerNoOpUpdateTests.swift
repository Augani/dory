import DoryOperations
import Foundation
import Testing
@testable import DorydKit

@Suite("Unchanged production configuration requests", .serialized)
struct MachineManagerNoOpUpdateTests {
    @Test("unchanged settings preserve source power, admission and runtime authority",
          arguments: ["stopped", "running", "paused"])
    func unchangedUpdateDoesNotReplan(sourceState: String) throws {
        try withProductionIntegrationTestStack {
            let harness = try ProductionDesktopUpdateHarness(sourceState: sourceState)
            defer { harness.cleanup() }
            let manager = harness.context.machineManager
            let source = try #require(manager.status(id: harness.id))
            let configuration = try JSONDecoder().decode(
                DoryMachineConfiguration.self, from: harness.sourceConfigurationData
            )
            let plan = try harness.context.planning.plans.read(id: harness.id)
            let admission = try harness.context.planning.resourceLedger.snapshot()
            let operations = try harness.journal.list()
            let operationID = UUID()
            for _ in 0..<2 {
                let result = try manager.update(
                    id: harness.id, memoryMB: configuration.memoryMB,
                    cpuCount: configuration.cpuCount, operationID: operationID
                )
                #expect(result.state == source.state)
                #expect(result.pid == source.pid)
                #expect(result.runtimeIdentity == source.runtimeIdentity)
            }
            #expect(throws: (any Error).self) {
                try manager.update(id: harness.id, memoryMB: configuration.memoryMB,
                    operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
            }
            #expect(try harness.context.planning.plans.read(id: harness.id) == plan)
            #expect(try harness.context.planning.resourceLedger.snapshot() == admission)
            #expect(try harness.journal.list() == operations)
            #expect(try Data(contentsOf: URL(fileURLWithPath: harness.directory + "/machine.json"))
                == harness.sourceConfigurationData)
            #expect(manager.status(id: harness.id)?.pid == source.pid)
        }
    }
}
