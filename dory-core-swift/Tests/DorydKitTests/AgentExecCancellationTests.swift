import DoryCore
import Foundation
import Testing
@testable import DorydKit

@Suite("Guest exec wait cancellation boundary")
struct AgentExecCancellationTests {
    @Test("pre-cancelled exec rejects before connecting")
    func cancelledBeforeConnection() throws {
        let token = DoryExecControl()
        token.cancel()
        let control = AgentControl(configuration: .init(directSocketPath: "/unused")) { _ in
            Issue.record("cancelled exec attempted to connect")
            throw CancellationFixtureError.unexpected
        }
        #expect(throws: DoryExecControlError.cancelledGuestStateUnknown) {
            try control.exec(argv: ["/bin/true"], control: token)
        }
        #expect(throws: DoryExecControlError.cancelledGuestStateUnknown) {
            try control.execWithInput(argv: ["/bin/cat"], stdin: Data([1]), control: token)
        }
    }

    @Test("clients without controlled exec fail closed instead of falling back")
    func unsupportedControlDoesNotCallLegacyExec() throws {
        let client = LegacyExecFixture()
        let control = AgentControl(configuration: .init(directSocketPath: "/unused")) { _ in client }
        #expect(throws: AgentControlError.capabilityUnavailable("exec-control")) {
            try control.exec(argv: ["/bin/true"], control: DoryExecControl())
        }
        #expect(throws: AgentControlError.capabilityUnavailable("exec-control")) {
            try control.execWithInput(argv: ["/bin/cat"], stdin: Data([1]), control: DoryExecControl())
        }
    }

    @Test("controlled exec forwards the exact token and preserves timeout, input and capability checks")
    func forwardsExactControl() throws {
        let token = DoryExecControl()
        let client = ControlledExecFixture(token: token)
        let control = AgentControl(configuration: .init(directSocketPath: "/unused")) { _ in client }
        let env = [DoryExecEnvironment(key: "CONTROL_TEST", value: "value")]
        _ = try control.exec(argv: ["/bin/true"], cwd: "/tmp", env: env,
                             timeoutMs: 75_123, outputLimitBytes: 1234, control: token)
        _ = try control.execWithInput(argv: ["/bin/cat"], stdin: Data([0, 255]), cwd: "/tmp", env: env,
                                      timeoutMs: 75_123, outputLimitBytes: 1234, control: token)
        let unsupported = AgentControl(configuration: .init(directSocketPath: "/unused")) { _ in
            ControlledExecFixture(token: token, capabilities: [])
        }
        #expect(throws: AgentControlError.capabilityUnavailable("exec")) {
            try unsupported.exec(argv: ["/bin/true"], control: token)
        }
    }
}

private enum CancellationFixtureError: Error { case unexpected }

private class LegacyExecFixture: AgentControlClient, @unchecked Sendable {
    let capabilities: [DoryAgentCapability]
    init(capabilities: [DoryAgentCapability] = [.init(id: "exec", version: 1), .init(id: "exec-stdin", version: 1)]) {
        self.capabilities = capabilities
    }
    func info() throws -> DoryAgentInfo {
        .init(protocolVersion: DoryCore.protocolVersion(), kernel: "test", agentBuild: "test",
              uptimeSeconds: 1, capabilities: capabilities)
    }
    func clockSync(hostEpochNs: Int64) throws -> Bool { throw CancellationFixtureError.unexpected }
    func portsWatch() throws -> DoryPortsSnapshot { throw CancellationFixtureError.unexpected }
    func telemetry() throws -> DoryTelemetry { throw CancellationFixtureError.unexpected }
    func exec(argv: [String], cwd: String, env: [DoryExecEnvironment], timeoutMs: UInt64,
              outputLimitBytes: UInt64) throws -> DoryExecResult {
        Issue.record("controlled request fell back to legacy exec")
        throw CancellationFixtureError.unexpected
    }
    func close() {}
}

private final class ControlledExecFixture: AgentControlClient, @unchecked Sendable {
    let token: DoryExecControl
    let capabilities: [DoryAgentCapability]
    init(token: DoryExecControl, capabilities: [DoryAgentCapability] = [.init(id: "exec", version: 1), .init(id: "exec-stdin", version: 1)]) {
        self.token = token
        self.capabilities = capabilities
    }
    func info() throws -> DoryAgentInfo {
        .init(protocolVersion: DoryCore.protocolVersion(), kernel: "test", agentBuild: "test",
              uptimeSeconds: 1, capabilities: capabilities)
    }
    func clockSync(hostEpochNs: Int64) throws -> Bool { throw CancellationFixtureError.unexpected }
    func portsWatch() throws -> DoryPortsSnapshot { throw CancellationFixtureError.unexpected }
    func telemetry() throws -> DoryTelemetry { throw CancellationFixtureError.unexpected }
    func exec(argv: [String], cwd: String, env: [DoryExecEnvironment], timeoutMs: UInt64,
              outputLimitBytes: UInt64) throws -> DoryExecResult {
        Issue.record("controlled request fell back to legacy exec")
        throw CancellationFixtureError.unexpected
    }
    func close() {}
    func exec(argv: [String], cwd: String, env: [DoryExecEnvironment], timeoutMs: UInt64,
              outputLimitBytes: UInt64, control: DoryExecControl) throws -> DoryExecResult {
        #expect(argv == ["/bin/true"])
        check(cwd: cwd, env: env, timeoutMs: timeoutMs, outputLimitBytes: outputLimitBytes, control: control)
        return result()
    }
    func execWithInput(argv: [String], stdin: Data, cwd: String, env: [DoryExecEnvironment], timeoutMs: UInt64,
                       outputLimitBytes: UInt64, control: DoryExecControl) throws -> DoryExecResult {
        #expect(argv == ["/bin/cat"])
        #expect(stdin == Data([0, 255]))
        check(cwd: cwd, env: env, timeoutMs: timeoutMs, outputLimitBytes: outputLimitBytes, control: control)
        return result()
    }
    private func check(cwd: String, env: [DoryExecEnvironment], timeoutMs: UInt64,
                       outputLimitBytes: UInt64, control: DoryExecControl) {
        #expect(control === token)
        #expect(cwd == "/tmp")
        #expect(env == [.init(key: "CONTROL_TEST", value: "value")])
        #expect(timeoutMs == 75_123)
        #expect(outputLimitBytes == 1234)
    }
    private func result() -> DoryExecResult {
        .init(exitCode: 0, stdout: Data(), stderr: Data(), timedOut: false,
              stdoutTruncated: false, stderrTruncated: false)
    }
}
