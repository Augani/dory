import Testing
@testable import Dory

struct EventSynthesizerTests {
    @Test func createRunningContainerEmitsCreateAndStartWithAttributes() {
        let container = makeContainer(status: .running, labels: [
            "com.docker.compose.project": "demo",
            "com.docker.compose.service": "web",
            "com.docker.compose.container-number": "1",
            "tier": "frontend",
        ])

        let events = EventSynthesizer.diff(previous: [], current: [container])

        #expect(events.map(\.action) == [.create, .start])
        #expect(events.first?.attributes["name"] == "web")
        #expect(events.first?.attributes["image"] == "nginx:alpine")
        #expect(events.first?.attributes["com.docker.compose.service"] == "web")
        #expect(events.first?.attributes["tier"] == "frontend")
    }

    @Test func runningToStoppedEmitsDieThenStop() {
        let previous = makeContainer(status: .running)
        let current = makeContainer(status: .stopped)

        #expect(EventSynthesizer.diff(previous: [previous], current: [current]).map(\.action) == [.die, .stop])
    }

    @Test func removedRunningContainerEmitsDieThenDestroy() {
        let previous = makeContainer(status: .running)

        #expect(EventSynthesizer.diff(previous: [previous], current: []).map(\.action) == [.die, .destroy])
    }

    @Test func healthTransitionsEmitDockerActionsWhenHealthIsKnown() {
        let starting = makeContainer(status: .running, labels: ["dory.health": "starting"])
        let healthy = makeContainer(status: .running, labels: ["dory.health": "healthy"])
        let unhealthy = makeContainer(status: .running, labels: ["dory.health": "unhealthy"])

        let becameHealthy = EventSynthesizer.diff(previous: [starting], current: [healthy])
        #expect(becameHealthy.map(\.action.rawValue) == ["health_status: healthy"])

        let becameUnhealthy = EventSynthesizer.diff(previous: [healthy], current: [unhealthy])
        #expect(becameUnhealthy.map(\.action.rawValue) == ["health_status: unhealthy"])
    }

    @Test func missingHealthDoesNotEmitHealthEvents() {
        let previous = makeContainer(status: .running)
        let current = makeContainer(status: .running)

        #expect(EventSynthesizer.diff(previous: [previous], current: [current]).isEmpty)
    }

    @Test func dockerEventFiltersMatchDockerSelectors() {
        let event = DoryEvent(
            containerID: "abcdef123456",
            name: "web",
            image: "nginx:alpine",
            action: .start,
            attributes: [
                "name": "web",
                "image": "nginx:alpine",
                "tier": "frontend",
            ]
        )

        let matching = DockerListFilters.parse(#"{"type":["container"],"event":["start"],"container":["abc"],"image":["nginx"],"label":["tier=frontend"]}"#)
        #expect(DockerShim.eventMatches(event, filters: matching))

        let wrongAction = DockerListFilters.parse(#"{"event":["stop"]}"#)
        #expect(!DockerShim.eventMatches(event, filters: wrongAction))

        let wrongLabel = DockerListFilters.parse(#"{"label":["tier=api"]}"#)
        #expect(!DockerShim.eventMatches(event, filters: wrongLabel))
    }

    private func makeContainer(status: RunState, labels: [String: String] = [:]) -> Container {
        Container(id: "c1", name: "web", image: "nginx:alpine", status: status,
                  cpuPercent: 0, memoryDisplay: "0", memoryLimitDisplay: "—", memoryFraction: 0,
                  ports: "—", uptime: "1s", created: "now", ipAddress: "—", domain: "",
                  command: "nginx", restartPolicy: "no", labels: labels)
    }
}
