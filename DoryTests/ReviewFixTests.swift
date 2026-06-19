import Testing
import Foundation
@testable import Dory

@MainActor
struct ReviewFixTests {
    // #1 + #2: shim create + lifecycle must not deadlock and must round-trip.
    @Test func shimCreateAndStartDoNotDeadlock() async throws {
        let path = NSTemporaryDirectory() + "dory-fix-\(UUID().uuidString).sock"
        let runtime = RecordingRuntime()
        let shim = DockerShim(runtime: runtime)
        let server = ShimHTTPServer(socketPath: path) { await shim.handle($0) }
        try server.start()
        defer { server.stop() }
        let client = UnixSocketHTTP(path: path)

        let body = Data(#"{"Image":"nginx:alpine","HostConfig":{"PortBindings":{"80/tcp":[{"HostPort":"8080"}]}}}"#.utf8)
        let create = try await client.send(HTTPRequest(method: "POST", path: "/v1.47/containers/create?name=web",
            headers: [(name: "Content-Type", value: "application/json")], body: body))
        #expect(create.statusCode == 201)
        struct CreateOut: Decodable { let Id: String }
        let created = try JSONDecoder().decode(CreateOut.self, from: create.body)
        let id = created.Id
        #expect(runtime.createdSpecs.first?.image == "nginx:alpine")
        #expect(runtime.createdSpecs.first?.ports == ["8080:80"])

        // The lifecycle path used to deadlock the MainActor via a semaphore — must now return 204.
        let start = try await client.send(HTTPRequest(method: "POST", path: "/v1.47/containers/\(id)/start"))
        #expect(start.statusCode == 204)
        #expect(runtime.startedIDs.contains(id))

        // Unknown action -> 404 (was 409 for everything).
        let bogus = try await client.send(HTTPRequest(method: "POST", path: "/v1.47/containers/\(id)/frobnicate"))
        #expect(bogus.statusCode == 404)
    }

    // Image references that begin with '-' must be rejected at the shim boundary so they can never
    // be smuggled in as an option to the underlying engine CLI.
    @Test func shimRejectsOptionInjectionImage() async throws {
        let path = NSTemporaryDirectory() + "dory-inject-\(UUID().uuidString).sock"
        let runtime = RecordingRuntime()
        let shim = DockerShim(runtime: runtime)
        let server = ShimHTTPServer(socketPath: path) { await shim.handle($0) }
        try server.start(); defer { server.stop() }
        let client = UnixSocketHTTP(path: path)

        let create = try await client.send(HTTPRequest(method: "POST", path: "/v1.47/containers/create?name=x",
            headers: [(name: "Content-Type", value: "application/json")], body: Data(#"{"Image":"--privileged"}"#.utf8)))
        #expect(create.statusCode == 400)
        #expect(runtime.createdSpecs.isEmpty)
    }

    // exec: create -> start (101 upgrade) -> inspect exit code.
    @Test func shimExecRoundTrips() async throws {
        let path = NSTemporaryDirectory() + "dory-exec-\(UUID().uuidString).sock"
        let shim = DockerShim(runtime: RecordingRuntime())
        let server = ShimHTTPServer(socketPath: path) { await shim.handle($0) }
        try server.start(); defer { server.stop() }
        let client = UnixSocketHTTP(path: path)

        let create = try await client.send(HTTPRequest(method: "POST", path: "/v1.47/containers/c1/exec",
            headers: [(name: "Content-Type", value: "application/json")], body: Data(#"{"Cmd":["echo","hi"]}"#.utf8)))
        #expect(create.statusCode == 201)
        struct ExecOut: Decodable { let Id: String }
        let execID = try JSONDecoder().decode(ExecOut.self, from: create.body).Id

        let start = try await client.send(HTTPRequest(method: "POST", path: "/v1.47/exec/\(execID)/start",
            headers: [(name: "Content-Type", value: "application/json")], body: Data("{}".utf8)))
        #expect(start.statusCode == 101)

        let inspect = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/exec/\(execID)/json"))
        struct ExecInspect: Decodable { let ExitCode: Int }
        let code = try JSONDecoder().decode(ExecInspect.self, from: inspect.body).ExitCode
        #expect(code == 0)
    }

    // #3: inspect must expose NetworkSettings.Ports for getMappedPort().
    @Test func inspectExposesPortMappings() async throws {
        let path = NSTemporaryDirectory() + "dory-fix2-\(UUID().uuidString).sock"
        let shim = DockerShim(runtime: MockRuntime())
        let server = ShimHTTPServer(socketPath: path) { await shim.handle($0) }
        try server.start(); defer { server.stop() }
        let client = UnixSocketHTTP(path: path)
        let resp = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/c1/json"))
        let json = try #require(try JSONSerialization.jsonObject(with: resp.body) as? [String: Any])
        let net = json["NetworkSettings"] as? [String: Any]
        let ports = net?["Ports"] as? [String: Any]
        #expect(ports?["5432/tcp"] != nil) // postgres-db publishes 5432→5432
        #expect((json["Created"] as? String)?.isEmpty == false)
    }

    // #12: interpolation operator precedence with a hyphen in the error message.
    @Test func interpolationHandlesHyphenInRequiredMessage() {
        #expect(ComposeInterpolation.interpolate("${VAR:?must-be-set}", variables: ["VAR": "x"]) == "x")
        #expect(ComposeInterpolation.interpolate("${VAR-a-b-c}", variables: [:]) == "a-b-c")
    }

    // #21: yes/no must remain strings (YAML 1.2 / compose), not become true/false.
    @Test func yamlYesNoStayStrings() throws {
        let root = try YAMLParser.parse("env:\n  FEATURE: yes\n  OTHER: no\n  REAL: true")
        #expect(root["env"]?["FEATURE"]?.stringValue == "yes")
        #expect(root["env"]?["OTHER"]?.stringValue == "no")
        #expect(root["env"]?["REAL"]?.boolValue == true)
    }

    // #14: nested block under an inline-map sequence item must not be dropped.
    @Test func yamlNestedBlockUnderSequenceItem() throws {
        let yaml = """
        ports:
          - target: 80
            published: 8080
            meta:
              key: val
        """
        let item = try #require(try YAMLParser.parse(yaml)["ports"]?.sequenceValue?.first)
        #expect(item["target"]?.stringValue == "80")
        #expect(item["published"]?.stringValue == "8080")
        #expect(item["meta"]?["key"]?.stringValue == "val") // previously dropped to null
    }

    // #13: service_completed_successfully must fail when the dependency exits non-zero.
    @Test func composeFailsOnNonZeroCompletedDependency() async throws {
        let yaml = """
        services:
          migrate:
            image: busybox
          app:
            image: nginx
            depends_on:
              migrate:
                condition: service_completed_successfully
        """
        let project = try ComposeParser.parse(yaml, projectName: "demo")
        let runtime = FailingCompletionRuntime()
        let engine = ComposeEngine(runtime: runtime, healthPollCap: 0.01, maxHealthAttempts: 3)
        await #expect(throws: ComposeError.self) { try await engine.up(project) }
    }
}

@MainActor
final class FailingCompletionRuntime: ContainerRuntime {
    let kind: RuntimeKind = .mock
    private var live: [Container] = []
    private var n = 0
    func snapshot() async throws -> RuntimeSnapshot { RuntimeSnapshot(containers: live) }
    func create(_ spec: ContainerSpec) async throws -> String {
        n += 1; let id = "id\(n)"
        // migrate is created already-stopped (completed); app would start after.
        let stopped = spec.name.contains("migrate")
        live.append(Container(id: id, name: spec.name, image: spec.image, status: stopped ? .stopped : .running,
            cpuPercent: 0, memoryDisplay: "0", memoryLimitDisplay: "—", memoryFraction: 0, ports: "—",
            uptime: "—", created: "now", ipAddress: "—", domain: "", command: "", restartPolicy: "no"))
        return id
    }
    func start(containerID: String) async throws {}
    func stop(containerID: String) async throws {}
    func restart(containerID: String) async throws {}
    func remove(containerID: String) async throws {}
    func logs(containerID: String) async throws -> [LogLine] { [] }
    func env(containerID: String) async throws -> [EnvVar] { [] }
    func exec(containerID: String, command: [String]) async throws -> ExecResult { ExecResult(exitCode: 0, output: "") }
    func containerExitCode(_ id: String) async -> Int? { 1 } // dependency failed
}
