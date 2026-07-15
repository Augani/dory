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

    @Test func portURLUsesPublishedLoopbackPortWhenDomainExists() {
        let store = AppStore()
        let c = container("a", running: true, domain: "web-api.dory.local")
        let url = store.portURL(for: c, port: PublishedPort(hostPort: 8080, containerPort: 80, proto: "tcp"))
        #expect(url.absoluteString == "http://127.0.0.1:8080")
    }

    @Test func portURLUsesPublishedLoopbackPortWithoutDomain() {
        let store = AppStore()
        let c = container("a", running: true, domain: "")
        let url = store.portURL(for: c, port: PublishedPort(hostPort: 8080, containerPort: 80, proto: "tcp"))
        #expect(url.absoluteString == "http://127.0.0.1:8080")
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
        let store = AppStore(runtime: MockRuntime())
        await store.reload()
        #expect(!store.cpuHistory.isEmpty)
        let runningIDs = store.containers.filter(\.isRunning).map(\.id)
        let hasSamples = runningIDs.contains { !(store.cpuHistory[$0]?.isEmpty ?? true) }
        #expect(hasSamples)
    }

    @Test func createContainerRollsBackWhenStartFailsAndShowsDockerMessage() async {
        let runtime = RecordingRuntime()
        runtime.startError = HTTPError.status(
            code: 409,
            message: #"{"message":"host port 127.0.0.1:8080/tcp is unavailable"}"#
        )
        let store = AppStore(runtime: runtime)

        let error = await store.createContainer(
            name: "web",
            image: "nginx",
            ports: ["127.0.0.1:8080:80"],
            env: [:]
        )

        #expect(error == "host port 127.0.0.1:8080/tcp is unavailable")
        #expect(runtime.startedIDs == ["id1"])
        #expect(runtime.removedIDs == ["id1"])
        #expect(store.containers.isEmpty)
        #expect(store.selectedContainerID == nil)
    }

    @Test func createContainerReportsRollbackFailure() async {
        let runtime = RecordingRuntime()
        runtime.startError = HTTPError.status(code: 500, message: #"{"message":"start failed"}"#)
        runtime.removeError = HTTPError.status(code: 500, message: #"{"message":"remove failed"}"#)
        let store = AppStore(runtime: runtime)

        let error = await store.createContainer(name: "web", image: "nginx", ports: [], env: [:])

        #expect(error == "start failed Dory could not remove the incomplete container: remove failed")
        #expect(runtime.removedIDs == ["id1"])
    }

    @Test func onboardingDemoUsesAUniqueLoopbackPortInsteadOfTheDoryProxy() {
        let port = 49_123
        #expect(OnboardingDemo.command(port: port) == "docker run -d -p 127.0.0.1:49123:80 nginx")
        #expect(OnboardingDemo.portMapping(port: port) == "127.0.0.1:49123:80")
        #expect(OnboardingDemo.containerName(port: port) == "dory-welcome-49123")
        #expect(OnboardingDemo.url(port: port) == "http://127.0.0.1:49123")
        #expect(!OnboardingDemo.command(port: port).contains("8080:80"))
    }
}
