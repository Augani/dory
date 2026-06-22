import Testing
import Foundation
@testable import Dory

@MainActor
struct ContainerActionsTests {
    private func container(_ id: String, running: Bool, domain: String = "", ports: String = "") -> Container {
        Container(id: id, name: id, image: "img", status: running ? .running : .stopped,
                  cpuPercent: 0, memoryDisplay: "0", memoryLimitDisplay: "0", memoryFraction: 0,
                  ports: ports, uptime: "", created: "", ipAddress: "", domain: domain, command: "",
                  restartPolicy: "", labels: [:])
    }

    @Test func portURLPrefersDomain() {
        let store = AppStore()
        let c = container("a", running: true, domain: "web-api.dory.local")
        let url = store.portURL(for: c, port: PublishedPort(hostPort: 8080, containerPort: 80, proto: "tcp"))
        #expect(url.absoluteString == "https://web-api.dory.local")
    }

    @Test func portURLFallsBackToLocalhost() {
        let store = AppStore()
        let c = container("a", running: true, domain: "")
        let url = store.portURL(for: c, port: PublishedPort(hostPort: 8080, containerPort: 80, proto: "tcp"))
        #expect(url.absoluteString == "http://localhost:8080")
    }

    @Test func cpuHistoryAppendsAndCaps() {
        let store = AppStore()
        for i in 0..<30 { store.recordCPU("a", Double(i)) }
        #expect((store.cpuHistory["a"]?.count ?? 0) <= 20)
        #expect(store.cpuHistory["a"]?.last == 29)
    }

    @Test func reclaimableSumsUnusedOnly() {
        let store = AppStore()
        store.images = [
            DockerImage(repository: "a", tag: "1", imageID: "1", size: "", created: "", usedByCount: 0, sizeBytes: 100),
            DockerImage(repository: "b", tag: "1", imageID: "2", size: "", created: "", usedByCount: 2, sizeBytes: 500),
            DockerImage(repository: "c", tag: "1", imageID: "3", size: "", created: "", usedByCount: 0, sizeBytes: 400),
        ]
        #expect(store.reclaimableImageBytes == 500)
        #expect(store.reclaimLabel != nil)
    }

    @Test func reclaimLabelNilWhenNothingToReclaim() {
        let store = AppStore()
        store.images = [DockerImage(repository: "b", tag: "1", imageID: "2", size: "", created: "", usedByCount: 1, sizeBytes: 500)]
        #expect(store.reclaimLabel == nil)
    }

    @Test func performToggleClearsPending() async {
        let store = AppStore()
        store.containers = [container("a", running: false)]
        await store.performToggle(store.containers[0])
        #expect(!store.pendingContainerIDs.contains("a"))
    }

    @Test func reloadPopulatesCpuHistoryForRunningContainers() async {
        let store = AppStore()
        await store.reload()
        #expect(!store.cpuHistory.isEmpty)
        let runningIDs = store.containers.filter(\.isRunning).map(\.id)
        let hasSamples = runningIDs.contains { !(store.cpuHistory[$0]?.isEmpty ?? true) }
        #expect(hasSamples)
    }
}
