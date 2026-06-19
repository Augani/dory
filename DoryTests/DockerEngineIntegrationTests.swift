import Testing
import Foundation
@testable import Dory

struct DockerEngineIntegrationTests {
    @MainActor
    @Test func detectsAndSnapshotsLiveEngine() async throws {
        guard let runtime = await DockerEngineRuntime.detect() else {
            // No reachable Docker socket in this environment — nothing to assert.
            return
        }
        let snapshot = try await runtime.snapshot()
        #expect(snapshot.engineRunning)
        // A real engine should expose at least containers or images.
        let hasContent = !snapshot.containers.isEmpty || !snapshot.images.isEmpty
        #expect(hasContent)
        // Every container must have a non-empty, unique id (regression guard for ForEach dedup).
        let ids = snapshot.containers.map(\.id)
        let uniqueContainerIDs = Set(ids).count == ids.count
        let anyEmptyID = ids.contains { $0.isEmpty }
        #expect(uniqueContainerIDs)
        #expect(!anyEmptyID)
        // Image ids must be unique too.
        let imageIDs = snapshot.images.map(\.id)
        let uniqueImageIDs = Set(imageIDs).count == imageIDs.count
        #expect(uniqueImageIDs)
    }

    @MainActor
    @Test func streamsLogsFromLiveContainer() async throws {
        guard let runtime = await DockerEngineRuntime.detect() else { return }
        let snapshot = try await runtime.snapshot()
        guard let running = snapshot.containers.first(where: { $0.isRunning }) else { return }

        let staticLogs = (try? await runtime.logs(containerID: running.id)) ?? []
        var collected: [LogLine] = []
        let consumer = Task {
            for await line in runtime.streamLogs(containerID: running.id) {
                collected.append(line)
                if collected.count >= 3 { break }
            }
        }
        try? await Task.sleep(for: .seconds(3))
        consumer.cancel()

        // The streamed tail should deliver lines whenever the container has any logs.
        if !staticLogs.isEmpty {
            let gotLines = collected.count
            #expect(gotLines >= 1)
        }
    }
}
