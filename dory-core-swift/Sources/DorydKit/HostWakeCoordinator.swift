import Darwin
import Foundation

public protocol PowerEventSource: Sendable {
    func start(
        onWillSleep: @escaping @Sendable () -> Void,
        onWake: @escaping @Sendable () -> Void
    ) throws
    func stop()
}

public protocol HostSleepHandling: Sendable {
    func prepareForHostSleep(now: Date) -> HostSleepActionResult
}

public protocol WakeClockSyncing: Sendable {
    func syncAgentClock(now: Date) -> AgentClockSyncResult
}

public struct HostSleepActionResult: Sendable, Equatable {
    public var name: String
    public var attempted: Bool
    public var slept: Bool
    public var detail: String?

    public init(name: String, attempted: Bool, slept: Bool, detail: String? = nil) {
        self.name = name
        self.attempted = attempted
        self.slept = slept
        self.detail = detail
    }
}

public struct AgentClockSyncResult: Sendable, Equatable {
    public var name: String
    public var attempted: Bool
    public var synced: Bool
    public var error: String?

    public init(name: String, attempted: Bool, synced: Bool, error: String? = nil) {
        self.name = name
        self.attempted = attempted
        self.synced = synced
        self.error = error
    }
}

public struct DNSProbeTarget: Sendable, Equatable {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16 = 443) {
        self.host = host
        self.port = port
    }
}

public struct DNSProbeResult: Sendable, Equatable {
    public var target: DNSProbeTarget
    public var resolved: Bool
    public var addresses: [String]
    public var error: String?

    public init(target: DNSProbeTarget, resolved: Bool, addresses: [String] = [], error: String? = nil) {
        self.target = target
        self.resolved = resolved
        self.addresses = addresses
        self.error = error
    }
}

public protocol DNSProbing: Sendable {
    func probe() -> [DNSProbeResult]
}

public final class SystemDNSProbe: DNSProbing, @unchecked Sendable {
    private let targets: [DNSProbeTarget]

    public init(targets: [DNSProbeTarget] = [DNSProbeTarget(host: "registry-1.docker.io", port: 443)]) {
        self.targets = targets
    }

    public func probe() -> [DNSProbeResult] {
        targets.map(resolve)
    }

    private func resolve(_ target: DNSProbeTarget) -> DNSProbeResult {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var info: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(target.host, String(target.port), &hints, &info)
        guard status == 0, let info else {
            return DNSProbeResult(
                target: target,
                resolved: false,
                error: String(cString: gai_strerror(status))
            )
        }
        defer { freeaddrinfo(info) }

        var addresses = Set<String>()
        var cursor: UnsafeMutablePointer<addrinfo>? = info
        while let current = cursor {
            if let address = numericAddress(current.pointee.ai_addr, current.pointee.ai_addrlen) {
                addresses.insert(address)
            }
            cursor = current.pointee.ai_next
        }

        return DNSProbeResult(
            target: target,
            resolved: !addresses.isEmpty,
            addresses: addresses.sorted()
        )
    }

    private func numericAddress(_ address: UnsafeMutablePointer<sockaddr>?, _ length: socklen_t) -> String? {
        guard let address else { return nil }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            address,
            length,
            &host,
            socklen_t(host.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        guard result == 0 else { return nil }
        let bytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

public struct HostWakeResult: Sendable, Equatable {
    public var at: Date
    public var clockSyncs: [AgentClockSyncResult]
    public var dnsProbes: [DNSProbeResult]
}

public struct HostSleepResult: Sendable, Equatable {
    public var at: Date
    public var actions: [HostSleepActionResult]
}

public final class HostWakeCoordinator: @unchecked Sendable {
    private let powerSource: PowerEventSource
    private let sleepHandlers: [HostSleepHandling]
    private let clockSyncers: [WakeClockSyncing]
    private let dnsProbe: DNSProbing
    private let incidentWriter: IncidentWriter?
    private let lock = NSLock()
    private var lastSleepResult: HostSleepResult?
    private var lastWakeResult: HostWakeResult?

    public init(
        powerSource: PowerEventSource = IOKitPowerEventSource(),
        sleepHandlers: [HostSleepHandling] = [],
        clockSyncers: [WakeClockSyncing] = [],
        dnsProbe: DNSProbing = SystemDNSProbe(),
        incidentWriter: IncidentWriter? = nil
    ) {
        self.powerSource = powerSource
        self.sleepHandlers = sleepHandlers
        self.clockSyncers = clockSyncers
        self.dnsProbe = dnsProbe
        self.incidentWriter = incidentWriter
    }

    public func start() throws {
        try powerSource.start(
            onWillSleep: { [weak self] in
                _ = self?.handleWillSleep()
            },
            onWake: { [weak self] in
                _ = self?.handleWake()
            }
        )
    }

    public func stop() {
        powerSource.stop()
    }

    @discardableResult
    public func handleWillSleep(now: Date = Date()) -> HostSleepResult {
        let actions = sleepHandlers.map { $0.prepareForHostSleep(now: now) }
        let result = HostSleepResult(at: now, actions: actions)

        lock.lock()
        lastSleepResult = result
        lock.unlock()

        incidentWriter?.record(type: "host.sleep", detail: sleepIncidentDetail(result), at: now)
        return result
    }

    @discardableResult
    public func handleWake(now: Date = Date()) -> HostWakeResult {
        let clockResults = clockSyncers.map { $0.syncAgentClock(now: now) }
        let dnsResults = dnsProbe.probe()
        let result = HostWakeResult(at: now, clockSyncs: clockResults, dnsProbes: dnsResults)

        lock.lock()
        lastWakeResult = result
        lock.unlock()

        incidentWriter?.record(type: "host.wake", detail: incidentDetail(result), at: now)
        return result
    }

    public var lastSleep: HostSleepResult? {
        lock.lock()
        defer { lock.unlock() }
        return lastSleepResult
    }

    public var lastWake: HostWakeResult? {
        lock.lock()
        defer { lock.unlock() }
        return lastWakeResult
    }

    private func sleepIncidentDetail(_ result: HostSleepResult) -> String {
        let attempted = result.actions.filter(\.attempted).count
        let slept = result.actions.filter(\.slept).count
        let details = result.actions.compactMap(\.detail).joined(separator: "; ")
        return "sleep_actions=\(attempted) slept=\(slept)/\(result.actions.count)" +
            (details.isEmpty ? "" : " \(details)")
    }

    private func incidentDetail(_ result: HostWakeResult) -> String {
        let attempted = result.clockSyncs.filter(\.attempted).count
        let failed = result.clockSyncs.filter { $0.error != nil }.count
        let dnsOK = result.dnsProbes.filter(\.resolved).count
        return "clock_syncs=\(attempted) clock_errors=\(failed) dns_ok=\(dnsOK)/\(result.dnsProbes.count)"
    }
}
