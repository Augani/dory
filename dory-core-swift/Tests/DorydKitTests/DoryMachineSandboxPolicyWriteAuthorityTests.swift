import DoryOperations
import Foundation
import Testing
@testable import DorydKit

@Suite("Sandbox policy write authority")
struct DoryMachineSandboxPolicyWriteAuthorityTests {
    @Test("CLI and XPC round trip one exact non-secret policy")
    func cliAndXPCRoundTrip() throws {
        var arguments = [
            "--sandbox",
            "--sandbox-expires-at", "2000",
            "--sandbox-ssh-agent", "granted",
            "--sandbox-profile", "agent-ready",
            "--sandbox-tool", "node",
            "--sandbox-tool", "agent-core",
            "--sandbox-baseline", "baseline-v1",
            "--kernel", "/private/staged/kernel",
        ]
        let decoded = try DoryMachineSandboxPolicyWriteAuthority
            .consumeCLIArguments(&arguments)
        let policy = try #require(decoded)

        #expect(arguments == ["--kernel", "/private/staged/kernel"])
        #expect(policy.expiresAtUnixSeconds == 2_000)
        #expect(policy.sshAgentAccess == .granted)
        #expect(policy.profile == .agentReady)
        #expect(policy.tools == [.agentCore, .node])
        #expect(policy.baselineSnapshotID == "baseline-v1")

        let wire: NSDictionary = [
            DoryMachineSandboxPolicyWriteAuthority.xpcKey:
                try DoryMachineSandboxPolicyWriteAuthority.xpcDictionary(policy),
        ]
        #expect(
            try DoryMachineSandboxPolicyWriteAuthority.decodeXPC(wire) == policy
        )
        #expect(wire.description.contains("/private/staged/kernel") == false)
    }

    @Test("sandbox fields require the explicit marker and a canonical profile")
    func rejectsImplicitOrNoncanonicalPolicy() {
        var implicit = ["--sandbox-expires-at", "2000"]
        #expect(throws: (any Error).self) {
            try DoryMachineSandboxPolicyWriteAuthority.consumeCLIArguments(&implicit)
        }

        var incomplete = [
            "--sandbox",
            "--sandbox-profile", "agent-ready",
            "--sandbox-tool", "agent-core",
        ]
        #expect(throws: (any Error).self) {
            try DoryMachineSandboxPolicyWriteAuthority.consumeCLIArguments(&incomplete)
        }

        var duplicate = [
            "--sandbox",
            "--sandbox-profile", "agent-ready",
            "--sandbox-tool", "agent-core",
            "--sandbox-tool", "agent-core",
            "--sandbox-baseline", "baseline-v1",
        ]
        #expect(throws: (any Error).self) {
            try DoryMachineSandboxPolicyWriteAuthority.consumeCLIArguments(&duplicate)
        }
    }

    @Test("XPC sandbox policy rejects unknown keys, wrong types, and future schemas")
    func rejectsMalformedXPC() {
        let valid: [String: Any] = [
            "schemaVersion": UInt16(1),
            "sshAgentAccess": "denied",
            "profile": "standard",
            "tools": [] as [String],
        ]
        let malformed: [[String: Any]] = [
            valid.merging(["secret": "opaque"]) { _, new in new },
            valid.merging(["schemaVersion": UInt16(2)]) { _, new in new },
            valid.merging(["schemaVersion": true]) { _, new in new },
            valid.merging(["expiresAtUnixSeconds": "tomorrow"]) { _, new in new },
            valid.merging(["sshAgentAccess": "implicit"]) { _, new in new },
            valid.merging(["tools": ["unknown"]]) { _, new in new },
        ]
        for policy in malformed {
            let wire: NSDictionary = [
                DoryMachineSandboxPolicyWriteAuthority.xpcKey:
                    policy as NSDictionary,
            ]
            #expect(throws: (any Error).self) {
                try DoryMachineSandboxPolicyWriteAuthority.decodeXPC(wire)
            }
        }
    }

    @Test("legacy projection is bounded to sandbox compatibility keys")
    func legacyProjection() throws {
        let policy = DoryVMSandboxPolicy(
            expiresAtUnixSeconds: 2_000,
            sshAgentAccess: .granted,
            profile: .agentReady,
            tools: [.agentCore, .pythonML],
            baselineSnapshotID: "baseline-v1"
        )
        let environment = try DoryMachineSandboxPolicyWriteAuthority
            .legacyEnvironment(for: policy)

        #expect(environment.count == 6)
        #expect(environment["DORY_SANDBOX"] == "1")
        #expect(environment["DORY_SANDBOX_EXPIRES_AT"] == "2000")
        #expect(environment["DORY_SANDBOX_SSH_AGENT"] == "1")
        #expect(DoryVMSandboxPolicy.legacyEnvironment(environment) == policy)
    }
}
