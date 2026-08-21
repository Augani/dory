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

    @Test("support projection omits host share and daemon socket paths")
    func omitsHostPaths() throws {
        let privateRoot = "/Users/private-account/Confidential Client"
        let status: NSDictionary = [
            "id": "dev",
            "handoffSocketPath": privateRoot + "/handoff.sock",
            "agentSocketPath": privateRoot + "/agent.sock",
            "dockerdSocketPath": privateRoot + "/docker.sock",
            "shellSocketPath": privateRoot + "/shell.sock",
            "controlSocketPath": privateRoot + "/control.sock",
            "shares": [
                [
                    "tag": "project-src",
                    "hostPath": privateRoot,
                    "guestPath": "/workspace/src",
                    "readOnly": true,
                ] as NSDictionary,
            ],
        ]

        let projected = DoryMachineDiagnosticsProjection.supportSafeMachineStatus(status)
        let data = try JSONSerialization.data(withJSONObject: projected)
        let text = String(decoding: data, as: UTF8.self)
        let shares = try #require(projected["shares"] as? NSArray)
        let share = try #require(shares.firstObject as? NSDictionary)

        #expect(projected["handoffSocketPath"] == nil)
        #expect(projected["agentSocketPath"] == nil)
        #expect(projected["dockerdSocketPath"] == nil)
        #expect(projected["shellSocketPath"] == nil)
        #expect(projected["controlSocketPath"] == nil)
        #expect(share["hostPath"] == nil)
        #expect(share["tag"] as? String == "project-src")
        #expect(share["guestPath"] as? String == "/workspace/src")
        #expect(share["readOnly"] as? Bool == true)
        #expect(!text.contains(privateRoot))
    }
}
