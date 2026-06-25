import Testing
import Foundation
@testable import Dory

@MainActor
struct EngineServicesTests {
    private func container(_ id: String, _ status: RunState) -> Container {
        Container(id: id, name: id, image: "img:latest", status: status, cpuPercent: 0,
                  memoryDisplay: "0 MB", memoryLimitDisplay: "—", memoryFraction: 0,
                  ports: "—", uptime: "—", created: "now", ipAddress: "—",
                  domain: "\(id).dory.local", command: "x", restartPolicy: "no")
    }

    // MARK: Health monitor

    @Test func singleSuccessBecomesHealthy() {
        var monitor = HealthMonitor(config: HealthcheckConfig(retries: 3, startPeriod: 0))
        monitor.record(success: true, elapsed: 1)
        #expect(monitor.state == .healthy)
    }

    @Test func unhealthyAfterRetriesExceeded() {
        var monitor = HealthMonitor(config: HealthcheckConfig(retries: 3, startPeriod: 0))
        monitor.record(success: false, elapsed: 1)
        #expect(monitor.state == .starting)
        monitor.record(success: false, elapsed: 2)
        #expect(monitor.state == .starting)
        monitor.record(success: false, elapsed: 3)
        #expect(monitor.state == .unhealthy)
    }

    @Test func failuresDuringStartPeriodAreIgnored() {
        var monitor = HealthMonitor(config: HealthcheckConfig(retries: 1, startPeriod: 10))
        monitor.record(success: false, elapsed: 2)
        monitor.record(success: false, elapsed: 5)
        #expect(monitor.state == .starting)
        #expect(monitor.failingStreak == 0)
        monitor.record(success: false, elapsed: 11)
        #expect(monitor.state == .unhealthy)
    }

    @Test func successResetsFailingStreak() {
        var monitor = HealthMonitor(config: HealthcheckConfig(retries: 3, startPeriod: 0))
        monitor.record(success: false, elapsed: 1)
        monitor.record(success: false, elapsed: 2)
        monitor.record(success: true, elapsed: 3)
        #expect(monitor.state == .healthy)
        #expect(monitor.failingStreak == 0)
    }

    // MARK: Event synthesis

    @Test func emitsStartWhenContainerStarts() {
        let before = [container("a", .stopped)]
        let after = [container("a", .running)]
        let events = EventSynthesizer.diff(previous: before, current: after)
        #expect(events == [DoryEvent(containerID: "a", name: "a", image: "img:latest", action: .start,
                                     attributes: ["name": "a", "image": "img:latest"])])
    }

    @Test func emitsDieAndStopWhenContainerStops() {
        let events = EventSynthesizer.diff(previous: [container("a", .running)], current: [container("a", .stopped)])
        #expect(events.map(\.action) == [.die, .stop])
    }

    @Test func emitsCreateStartForNewRunningContainer() {
        let events = EventSynthesizer.diff(previous: [], current: [container("b", .running)])
        #expect(events.map(\.action) == [.create, .start])
    }

    @Test func emitsDieDestroyForRemovedRunningContainer() {
        let events = EventSynthesizer.diff(previous: [container("c", .running)], current: [])
        #expect(events.map(\.action) == [.die, .destroy])
    }

    @Test func noEventsWhenUnchanged() {
        let snapshot = [container("a", .running), container("b", .stopped)]
        #expect(EventSynthesizer.diff(previous: snapshot, current: snapshot).isEmpty)
    }

    // MARK: Anonymous volumes

    @Test func reclaimsTrackedAnonymousVolumes() {
        let tracker = AnonymousVolumeTracker()
        tracker.register(container: "a", volume: "vol1")
        tracker.register(container: "a", volume: "vol2")
        tracker.register(container: "b", volume: "vol3")
        #expect(tracker.trackedCount == 3)
        let reclaimed = tracker.reclaim(container: "a")
        #expect(reclaimed == ["vol1", "vol2"])
        #expect(tracker.volumes(for: "a").isEmpty)
        #expect(tracker.trackedCount == 1)
    }
}
