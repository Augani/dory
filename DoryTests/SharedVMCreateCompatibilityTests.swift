import Foundation
import Testing
@testable import Dory

@Suite
struct SharedVMCreateCompatibilityTests {
    @Test func sharedVMCreateInjectsHostServiceAliasesAndNormalizesLoopbackPorts() async throws {
        let capture = SharedVMProxyCapture()
        let shim = DockerShim(runtime: SharedVMProxyRuntime(capture: capture))
        let body = Data(#"""
        {
          "Image":"alpine:3.20",
          "HostConfig":{
            "AutoRemove":true,
            "ExtraHosts":["host.dory.internal:host-gateway","custom.internal:203.0.113.7"],
            "PortBindings":{"3000/tcp":[{"HostIp":"127.0.0.1","HostPort":"18081"}]}
          }
        }
        """#.utf8)

        let response = await shim.handle(ParsedRequest(
            method: "POST",
            target: "/v1.47/containers/create?name=web",
            headers: ["content-type": "application/json"],
            body: body
        ))

        #expect(response.status == 201)
        let json = try #require(capture.lastJSON)
        let hostConfig = try #require(json["HostConfig"] as? [String: Any])
        #expect(hostConfig["AutoRemove"] as? Bool == true)
        let extraHosts = try #require(hostConfig["ExtraHosts"] as? [String])
        #expect(extraHosts.contains("host.dory.internal:host-gateway"))
        #expect(extraHosts.contains("host.docker.internal:host-gateway"))
        #expect(extraHosts.contains("custom.internal:203.0.113.7"))
        let portBindings = try #require(hostConfig["PortBindings"] as? [String: [[String: String]]])
        #expect(portBindings["3000/tcp"]?.first?["HostIp"] == "")
        #expect(portBindings["3000/tcp"]?.first?["HostPort"] == "18081")
    }

    @Test func sharedVMCreateRebindsOnlyDoryProxySocketMountsToTheGuestDaemon() async throws {
        let capture = SharedVMProxyCapture()
        let shim = DockerShim(runtime: SharedVMProxyRuntime(capture: capture))
        let body = Data(#"""
        {
          "Image":"supabase/vector:test",
          "HostConfig":{
            "Binds":[
              "/Users/test/.dory/engine.sock:/var/run/docker.sock:ro",
              "/Users/test/work:/workspace:rw"
            ],
            "Mounts":[
              {"Type":"bind","Source":"/Users/test/.dory/dory.sock","Target":"/var/run/docker.sock","ReadOnly":true},
              {"Type":"bind","Source":"/Users/test/.docker/run/docker.sock","Target":"/var/run/docker.sock"},
              {"Type":"bind","Source":"/Users/test/.dory/engine.sock","Target":"/workspace"}
            ]
          }
        }
        """#.utf8)

        let response = await shim.handle(ParsedRequest(
            method: "POST",
            target: "/v1.47/containers/create?name=vector",
            headers: ["content-type": "application/json"],
            body: body
        ))

        #expect(response.status == 201)
        let json = try #require(capture.lastJSON)
        let hostConfig = try #require(json["HostConfig"] as? [String: Any])
        let binds = try #require(hostConfig["Binds"] as? [String])
        #expect(binds == [
            "/var/run/docker.sock:/var/run/docker.sock:ro",
            "/Users/test/work:/workspace:rw",
        ])
        let mounts = try #require(hostConfig["Mounts"] as? [[String: Any]])
        #expect(mounts[0]["Source"] as? String == "/var/run/docker.sock")
        #expect(mounts[1]["Source"] as? String == "/Users/test/.docker/run/docker.sock")
        #expect(mounts[2]["Source"] as? String == "/Users/test/.dory/engine.sock")
    }

    @Test func sharedVMCreatePreservesDeviceRequestsForDaemonAdmission() async throws {
        let capture = SharedVMProxyCapture()
        let shim = DockerShim(runtime: SharedVMProxyRuntime(capture: capture))
        let body = Data(#"{"HostConfig":{"DeviceRequests":[{"Count":-1,"Capabilities":[["gpu"]]},{"Driver":"example","Capabilities":[["example"]]}]}}"#.utf8)
        let response = await shim.handle(ParsedRequest(
            method: "POST", target: "/v1.47/containers/create?name=gpu",
            headers: ["content-type": "application/json"], body: body
        ))
        #expect(response.status == 201)
        let original = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let expected = try #require(original["HostConfig"] as? [String: Any])
        let forwarded = try #require(capture.lastJSON?["HostConfig"] as? [String: Any])
        #expect(NSDictionary(dictionary: ["requests": forwarded["DeviceRequests"] as Any])
            .isEqual(to: ["requests": expected["DeviceRequests"] as Any]))
        #expect(forwarded["Devices"] == nil)
        #expect(forwarded["DeviceCgroupRules"] == nil)
    }

}

private final class SharedVMProxyCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [Data] = []

    var lastJSON: [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        guard let body = bodies.last else { return nil }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    func record(_ body: Data) {
        lock.lock()
        bodies.append(body)
        lock.unlock()
    }
}

private struct SharedVMProxyRuntime: ContainerRuntime {
    let kind: RuntimeKind = .sharedVM
    let capture: SharedVMProxyCapture
    var supportsRawProxy: Bool { true }

    func snapshot() async throws -> RuntimeSnapshot { RuntimeSnapshot() }
    func start(containerID: String) async throws {}
    func stop(containerID: String) async throws {}
    func restart(containerID: String) async throws {}
    func remove(containerID: String) async throws {}
    func logs(containerID: String) async throws -> [LogLine] { [] }
    func env(containerID: String) async throws -> [EnvVar] { [] }
    func create(_ spec: ContainerSpec) async throws -> String { spec.name }
    func exec(containerID: String, command: [String]) async throws -> ExecResult { ExecResult(exitCode: 0, output: "") }

    func proxyRequest(method: String, path: String, headers: [(name: String, value: String)], body: Data) async -> HTTPResponse? {
        capture.record(body)
        return HTTPResponse(
            statusCode: 201,
            reason: "Created",
            headers: ["content-type": "application/json"],
            body: Data(#"{"Id":"created","Warnings":[]}"#.utf8)
        )
    }
}
