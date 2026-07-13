import Foundation
import Testing
@testable import Dory

@MainActor
struct DockerEngineRuntimePerformanceTests {
    @Test func imageLoadReturnsTheExactEngineReceipt() async throws {
        let path = Self.shortSocketPath("dory-image-load-receipt")
        let archive = Data("streamed image archive".utf8)
        let receipt = Data(
            (#"{"stream":"Loaded image ID: sha256:"}"#
                + String(repeating: "d", count: 64)
                + #"\n"}"#
                + "\r\n").utf8
        )
        let server = ShimHTTPServer(socketPath: path) { request in
            guard request.method == "POST",
                  request.path == "/images/load",
                  request.headers["content-type"] == "application/x-tar",
                  request.body == archive else {
                return .text("unexpected image-load request", status: 400)
            }
            return ShimResponse(
                status: 200,
                headers: [(name: "Content-Type", value: "application/json")],
                body: receipt
            )
        }
        try server.start()
        defer { server.stop() }
        let runtime = DockerEngineRuntime(socketPath: path)
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(archive.prefix(7))
            continuation.yield(archive.dropFirst(7))
            continuation.finish()
        }

        let response = try await runtime.loadImageThrowingWithResponse(stream: stream)

        #expect(runtime.supportsImageLoadReceipt)
        #expect(response == receipt)
    }

    @Test func statsCollectionCapsConcurrentProbes() async {
        let limit = 4
        let containers = (0..<20).map { index in
            DockerContainerSummary(
                id: "c\(index)",
                names: nil,
                image: "busybox",
                command: nil,
                created: nil,
                state: "running",
                status: nil,
                ports: nil,
                networkSettings: nil,
                labels: nil
            )
        }
        let tracker = StatsProbeTracker()

        let stats = await DockerEngineRuntime.boundedStatsByID(for: containers, limit: limit) { container in
            await tracker.begin(container.id)
            try? await Task.sleep(for: .milliseconds(10))
            await tracker.end()

            let usage = Int64(String(container.id.dropFirst())) ?? 0
            return DockerStats(
                cpuStats: nil,
                precpuStats: nil,
                memoryStats: DockerMemoryStats(usage: usage, limit: 1024)
            )
        }

        let snapshot = await tracker.snapshot()
        #expect(snapshot.maxActive <= limit)
        #expect(Set(snapshot.seen) == Set(containers.map(\.id)))
        #expect(stats.count == containers.count)
        #expect(stats["c7"]?.memoryStats?.usage == 7)
    }

    @Test func snapshotDoesNotWaitForHungStatsProbe() async throws {
        let path = Self.shortSocketPath("dory-stats-timeout")
        let server = ShimHTTPServer(socketPath: path) { request in
            switch request.path {
            case "/containers/json":
                return .json(Data(#"""
                [
                  {
                    "Id":"c1","Names":["/web"],"Image":"nginx","State":"running",
                    "Status":"Up 5 seconds","Created":1710000000
                  },
                  {
                    "Id":"c2","Names":["/database"],"Image":"postgres","State":"restarting",
                    "Status":"Restarting (1)","Created":1710000001
                  }
                ]
                """#.utf8))
            case "/containers/c1/stats":
                return .streaming(contentType: "application/json") { _ in
                    try? await Task.sleep(for: .seconds(10))
                }
            case "/images/json", "/networks":
                return .json(Data("[]".utf8))
            case "/volumes":
                return .json(Data(#"{"Volumes":[]}"#.utf8))
            case "/version":
                return .json(Data(#"{"Version":"29.0.0","ApiVersion":"1.47"}"#.utf8))
            default:
                return .empty(status: 404)
            }
        }
        try server.start()
        defer { server.stop() }

        let runtime = DockerEngineRuntime(socketPath: path)
        let started = Date()
        let snapshot = try await runtime.snapshot()

        #expect(Date().timeIntervalSince(started) < 5)
        let container = try #require(snapshot.containers.first)
        #expect(container.name == "web")
        #expect(container.cpuPercent == 0)
        #expect(container.memoryBytes == 0)
        #expect(snapshot.containers.first { $0.id == "c2" }?.status == .running)
    }

    @Test func snapshotPreservesPausedContainerStateForMigration() async throws {
        let path = Self.shortSocketPath("dory-paused-state")
        let server = ShimHTTPServer(socketPath: path) { request in
            switch request.path {
            case "/containers/json":
                return .json(Data(#"""
                [{
                  "Id":"paused-db","Names":["/database"],"Image":"postgres:16",
                  "State":"Paused","Status":"Up 1 minute (Paused)","Created":1710000000
                }]
                """#.utf8))
            case "/images/json", "/networks":
                return .json(Data("[]".utf8))
            case "/volumes":
                return .json(Data(#"{"Volumes":[]}"#.utf8))
            case "/version":
                return .json(Data(#"{"Version":"29.0.0","ApiVersion":"1.47"}"#.utf8))
            default:
                return .empty(status: 404)
            }
        }
        try server.start()
        defer { server.stop() }

        let snapshot = try await DockerEngineRuntime(socketPath: path).migrationSnapshot()

        #expect(snapshot.containers.first?.status == .paused)
    }

    @Test func writableLayerInventoryNormalizesOnlyCreatedContainersToZero() async throws {
        let path = Self.shortSocketPath("dory-writable-sizes")
        let server = ShimHTTPServer(socketPath: path) { request in
            guard request.path == "/containers/json" else { return .empty(status: 404) }
            return .json(Data(#"""
            [
              {"Id":"exited","Image":"busybox","State":"exited","SizeRw":4096},
              {"Id":"created","Image":"busybox","State":"created"}
            ]
            """#.utf8))
        }
        try server.start()
        defer { server.stop() }

        let sizes = try await DockerEngineRuntime(socketPath: path).migrationContainerWritableSizes()

        #expect(sizes == ["exited": 4096, "created": 0])
    }

    @Test func writableLayerInventoryFailsClosedForMissingStoppedSize() async throws {
        let path = Self.shortSocketPath("dory-writable-missing")
        let server = ShimHTTPServer(socketPath: path) { request in
            guard request.path == "/containers/json" else { return .empty(status: 404) }
            return .json(Data(#"[{"Id":"stopped","Image":"busybox","State":"exited"}]"#.utf8))
        }
        try server.start()
        defer { server.stop() }

        await #expect(throws: RuntimeFeatureError.self) {
            _ = try await DockerEngineRuntime(socketPath: path).migrationContainerWritableSizes()
        }
    }

    private static func shortSocketPath(_ prefix: String) -> String {
        let path = "/tmp/\(prefix)-\(UUID().uuidString.prefix(8)).sock"
        try? FileManager.default.removeItem(atPath: path)
        return path
    }
}

private actor StatsProbeTracker {
    private var active = 0
    private var maxActive = 0
    private var seen: [String] = []

    func begin(_ id: String) {
        active += 1
        maxActive = max(maxActive, active)
        seen.append(id)
    }

    func end() {
        active -= 1
    }

    func snapshot() -> (maxActive: Int, seen: [String]) {
        (maxActive, seen)
    }
}
