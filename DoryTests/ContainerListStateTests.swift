import Testing
import Foundation
@testable import Dory

@MainActor
struct ContainerListStateTests {
    private func make(_ containers: [Container]) -> AppStore {
        let store = AppStore()
        store.containers = containers
        return store
    }

    private func container(_ id: String, running: Bool, project: String? = nil) -> Container {
        var labels: [String: String] = [:]
        if let project { labels["com.docker.compose.project"] = project }
        return Container(id: id, name: id, image: "img:\(id)", status: running ? .running : .stopped,
                         cpuPercent: 0, memoryDisplay: "0", memoryLimitDisplay: "0", memoryFraction: 0,
                         ports: "", uptime: "", created: "", ipAddress: "", domain: "", command: "",
                         restartPolicy: "", labels: labels)
    }

    @Test func noMockRowsAtInit() {
        let store = AppStore()
        #expect(store.containers.isEmpty)
        #expect(store.loadState == .connecting)
        #expect(store.selectedContainerID == nil)
    }

    @Test func runningFilterShowsOnlyRunning() {
        let store = make([container("a", running: true), container("b", running: false)])
        store.containerFilter = .running
        #expect(store.filteredContainers.map(\.id) == ["a"])
    }

    @Test func stoppedFilterShowsOnlyStopped() {
        let store = make([container("a", running: true), container("b", running: false)])
        store.containerFilter = .stopped
        #expect(store.filteredContainers.map(\.id) == ["b"])
    }

    @Test func allFilterWithSearch() {
        let store = make([container("alpha", running: true), container("beta", running: false)])
        store.containerFilter = .all
        store.filter = "alph"
        #expect(store.filteredContainers.map(\.id) == ["alpha"])
    }

    @Test func groupingByComposeProjectThenUngrouped() {
        let store = make([
            container("web", running: true, project: "shop"),
            container("db", running: true, project: "shop"),
            container("solo", running: true),
        ])
        store.containerFilter = .all
        let groups = store.groupedContainers
        #expect(groups.count == 2)
        #expect(groups[0].project == "shop")
        #expect(groups[0].containers.map(\.id) == ["web", "db"])
        #expect(groups[1].project == nil)
        #expect(groups[1].containers.map(\.id) == ["solo"])
    }

    @Test func filterPersists() {
        let priorValue = UserDefaults.standard.string(forKey: "containerFilter")
        defer { UserDefaults.standard.set(priorValue, forKey: "containerFilter") }
        let store = AppStore()
        store.containerFilter = .stopped
        #expect(UserDefaults.standard.string(forKey: "containerFilter") == "stopped")
        store.containerFilter = .running
    }

    @Test func reloadBecomesReadyWithMockRuntime() async {
        let store = AppStore()
        await store.reload()
        #expect(store.loadState == .ready)
        #expect(!store.containers.isEmpty)
    }
}
