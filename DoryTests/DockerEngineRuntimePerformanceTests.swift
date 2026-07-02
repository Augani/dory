import Foundation
import Testing
@testable import Dory

struct DockerEngineRuntimePerformanceTests {
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
                  {"Id":"c1","Names":["/web"],"Image":"nginx","State":"running","Status":"Up 5 seconds","Created":1710000000}
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
