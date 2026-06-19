import Testing
import Foundation
@testable import Dory

@MainActor
final class RecordingRuntime: ContainerRuntime {
    let kind: RuntimeKind = .mock
    var createdSpecs: [ContainerSpec] = []
    var startedIDs: [String] = []
    var execCalls: [(id: String, command: [String])] = []
    var networksCreated: [String] = []
    var stoppedIDs: [String] = []
    var removedIDs: [String] = []
    var execSucceeds = true
    private var counter = 0
    private var liveContainers: [Container] = []

    func snapshot() async throws -> RuntimeSnapshot { RuntimeSnapshot(containers: liveContainers) }

    func create(_ spec: ContainerSpec) async throws -> String {
        createdSpecs.append(spec)
        counter += 1
        let id = "id\(counter)"
        liveContainers.append(Container(id: id, name: spec.name, image: spec.image, status: .running,
            cpuPercent: 0, memoryDisplay: "0 MB", memoryLimitDisplay: "—", memoryFraction: 0,
            ports: "—", uptime: "now", created: "now", ipAddress: "—", domain: "", command: "", restartPolicy: "no"))
        return id
    }

    func start(containerID: String) async throws { startedIDs.append(containerID) }
    func stop(containerID: String) async throws { stoppedIDs.append(containerID) }
    func restart(containerID: String) async throws {}
    func remove(containerID: String) async throws { removedIDs.append(containerID); liveContainers.removeAll { $0.id == containerID } }
    func logs(containerID: String) async throws -> [LogLine] { [] }
    func env(containerID: String) async throws -> [EnvVar] { [] }
    func pull(image: String) async throws {}
    func exec(containerID: String, command: [String]) async throws -> ExecResult {
        execCalls.append((containerID, command))
        return ExecResult(exitCode: execSucceeds ? 0 : 1, output: "")
    }
    func createNetwork(name: String, labels: [String: String]) async throws { networksCreated.append(name) }
    func removeNetwork(name: String) async throws {}
    func removeVolume(name: String) async throws {}
}

@MainActor
struct ComposeEngineTests {
    let yaml = """
    services:
      web:
        image: nginx:alpine
        depends_on:
          api:
            condition: service_started
          db:
            condition: service_healthy
      api:
        image: dory/api:latest
        depends_on: [db, cache]
      db:
        image: postgres:16
        healthcheck:
          test: ["CMD", "pg_isready"]
          interval: 1s
          retries: 3
      cache:
        image: redis:7-alpine
    """

    private func service(_ name: String) -> (ContainerSpec) -> Bool { { $0.name.hasSuffix("-\(name)-1") } }

    @Test func upCreatesInDependencyOrderWaitingForHealth() async throws {
        let project = try ComposeParser.parse(yaml, projectName: "demo")
        let runtime = RecordingRuntime()
        let engine = ComposeEngine(runtime: runtime, healthPollCap: 0.02, maxHealthAttempts: 5)

        let ids = try await engine.up(project)

        #expect(ids.count == 4)
        #expect(runtime.networksCreated == ["demo_default"])

        let names = runtime.createdSpecs.map(\.name)
        func position(_ service: String) -> Int { names.firstIndex(of: "demo-\(service)-1")! }
        #expect(position("db") < position("api"))
        #expect(position("cache") < position("api"))
        #expect(position("api") < position("web"))
        #expect(position("db") < position("web"))

        // db's healthcheck was probed because web depends on it being healthy.
        #expect(runtime.execCalls.contains { $0.command == ["pg_isready"] })
        // every created container was also started and joined the project network.
        #expect(runtime.startedIDs.count == 4)
        #expect(runtime.createdSpecs.allSatisfy { $0.networks.contains("demo_default") })
        #expect(runtime.createdSpecs.first { $0.name == "demo-web-1" }?.labels["com.docker.compose.service"] == "web")
    }

    @Test func unhealthyDependencyFailsUp() async throws {
        let project = try ComposeParser.parse(yaml, projectName: "demo")
        let runtime = RecordingRuntime()
        runtime.execSucceeds = false
        let engine = ComposeEngine(runtime: runtime, healthPollCap: 0.01, maxHealthAttempts: 5)
        await #expect(throws: ComposeError.self) { try await engine.up(project) }
    }

    @Test func downStopsAndRemovesProjectContainers() async throws {
        let project = try ComposeParser.parse(yaml, projectName: "demo")
        let runtime = RecordingRuntime()
        let engine = ComposeEngine(runtime: runtime, healthPollCap: 0.02, maxHealthAttempts: 5)
        _ = try await engine.up(project)

        try await engine.down(project)
        #expect(runtime.removedIDs.count == 4)
        #expect(runtime.stoppedIDs.count == 4)
    }
}
