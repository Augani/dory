@testable import DorydKit
import Foundation
import XCTest

final class HostWakeCoordinatorTests: XCTestCase {
    func testSleepEventRunsHandlersAndIncidentWriter() throws {
        let base = "/tmp/dory-sleep-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let source = TestPowerEventSource()
        let handler = TestSleepHandler()
        let writer = IncidentWriter(path: base + "/incidents.jsonl")
        let coordinator = HostWakeCoordinator(
            powerSource: source,
            sleepHandlers: [handler],
            incidentWriter: writer
        )

        try coordinator.start()
        source.emitWillSleep()

        XCTAssertEqual(handler.sleepDates.count, 1)
        XCTAssertEqual(coordinator.lastSleep?.actions.first?.slept, true)
        let incident = try XCTUnwrap(writer.read(limit: 1).first)
        XCTAssertEqual(incident.type, "host.sleep")
        XCTAssertTrue(incident.detail?.contains("slept=1/1") ?? false)
    }

    func testWakeEventRunsClockSyncDnsProbeAndIncidentWriter() throws {
        let base = "/tmp/dory-wake-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let source = TestPowerEventSource()
        let clock = TestClockSyncer()
        let dns = TestDNSProbe(results: [
            DNSProbeResult(
                target: DNSProbeTarget(host: "registry.example.test", port: 443),
                resolved: true,
                addresses: ["127.0.0.1"]
            ),
        ])
        let writer = IncidentWriter(path: base + "/incidents.jsonl")
        let coordinator = HostWakeCoordinator(
            powerSource: source,
            clockSyncers: [clock],
            dnsProbe: dns,
            incidentWriter: writer
        )

        try coordinator.start()
        source.emitWake()

        XCTAssertEqual(clock.syncDates.count, 1)
        XCTAssertEqual(dns.probeCount, 1)
        XCTAssertEqual(coordinator.lastWake?.clockSyncs.first?.attempted, true)
        XCTAssertEqual(coordinator.lastWake?.dnsProbes.first?.resolved, true)
        let incident = try XCTUnwrap(writer.read(limit: 1).first)
        XCTAssertEqual(incident.type, "host.wake")
        XCTAssertTrue(incident.detail?.contains("dns_ok=1/1") ?? false)
    }

    func testSystemDNSProbeResolvesLocalhost() {
        let probe = SystemDNSProbe(targets: [DNSProbeTarget(host: "localhost", port: 80)])
        let result = probe.probe()
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].resolved, result[0].error ?? "unresolved")
        XCTAssertFalse(result[0].addresses.isEmpty)
    }
}

private final class TestPowerEventSource: PowerEventSource, @unchecked Sendable {
    private let lock = NSLock()
    private var onWillSleep: (@Sendable () -> Void)?
    private var onWake: (@Sendable () -> Void)?

    func start(
        onWillSleep: @escaping @Sendable () -> Void,
        onWake: @escaping @Sendable () -> Void
    ) throws {
        lock.lock()
        self.onWillSleep = onWillSleep
        self.onWake = onWake
        lock.unlock()
    }

    func stop() {
        lock.lock()
        onWillSleep = nil
        onWake = nil
        lock.unlock()
    }

    func emitWillSleep() {
        lock.lock()
        let callback = onWillSleep
        lock.unlock()
        callback?()
    }

    func emitWake() {
        lock.lock()
        let callback = onWake
        lock.unlock()
        callback?()
    }
}

private final class TestSleepHandler: HostSleepHandling, @unchecked Sendable {
    private let lock = NSLock()
    private var dates: [Date] = []

    var sleepDates: [Date] {
        lock.lock()
        defer { lock.unlock() }
        return dates
    }

    func prepareForHostSleep(now: Date) -> HostSleepActionResult {
        lock.lock()
        dates.append(now)
        lock.unlock()
        return HostSleepActionResult(name: "test", attempted: true, slept: true, detail: "slept")
    }
}

private final class TestClockSyncer: WakeClockSyncing, @unchecked Sendable {
    private let lock = NSLock()
    private var dates: [Date] = []

    var syncDates: [Date] {
        lock.lock()
        defer { lock.unlock() }
        return dates
    }

    func syncAgentClock(now: Date) -> AgentClockSyncResult {
        lock.lock()
        dates.append(now)
        lock.unlock()
        return AgentClockSyncResult(name: "test", attempted: true, synced: true)
    }
}

private final class TestDNSProbe: DNSProbing, @unchecked Sendable {
    private let lock = NSLock()
    private let results: [DNSProbeResult]
    private var count = 0

    init(results: [DNSProbeResult]) {
        self.results = results
    }

    var probeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func probe() -> [DNSProbeResult] {
        lock.lock()
        count += 1
        lock.unlock()
        return results
    }
}
