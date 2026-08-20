import Foundation
import Testing
@testable import DorydKit

@Suite("Machine diagnostics projection")
struct DoryMachineDiagnosticsProjectionTests {
    @Test("support projection structurally omits opaque environment secrets")
    func omitsEnvironmentContainers() throws {
        let opaqueSecret = "opaque-machine-credential-7f3b"
        let statuses: NSArray = [
            [
                "id": "dev",
                "state": "running",
                "address": "dev.dory.local",
                "environment": [
                    ["key": "ANTHROPIC_API_KEY", "value": opaqueSecret],
                ],
                "nested": [
                    "env": ["OPENAI_API_KEY": opaqueSecret],
                    "runtime": "qualified",
                ],
            ] as NSDictionary,
        ]

        let projected = DoryMachineDiagnosticsProjection.supportSafeMachineList(statuses)
        let data = try JSONSerialization.data(withJSONObject: projected)
        let text = String(decoding: data, as: UTF8.self)
        let machine = try #require(projected.firstObject as? NSDictionary)
        let nested = try #require(machine["nested"] as? NSDictionary)

        #expect(machine["id"] as? String == "dev")
        #expect(machine["address"] as? String == "dev.dory.local")
        #expect(machine["environment"] == nil)
        #expect(nested["env"] == nil)
        #expect(nested["runtime"] as? String == "qualified")
        #expect(!text.contains(opaqueSecret))
    }

    @Test("single status projection recognizes alternate environment spellings")
    func omitsAlternateSpellings() {
        let status: NSDictionary = [
            "id": "dev",
            "ENV": ["SECRET": "opaque"],
            "environment_variables": ["SECRET": "opaque"],
            "environmentVariables": ["SECRET": "opaque"],
        ]

        let projected = DoryMachineDiagnosticsProjection.supportSafeMachineStatus(status)

        #expect(projected["id"] as? String == "dev")
        #expect(projected["ENV"] == nil)
        #expect(projected["environment_variables"] == nil)
        #expect(projected["environmentVariables"] == nil)
    }
}
