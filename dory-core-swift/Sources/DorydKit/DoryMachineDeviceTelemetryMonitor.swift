import Foundation

public protocol DoryMachineDeviceTelemetrySampling: Sendable {
    func activeMachineIDsForDeviceTelemetry() -> [String]
    func sampleDeviceTelemetry(machineID: String) throws
}

extension MachineManager: DoryMachineDeviceTelemetrySampling {
    public func activeMachineIDsForDeviceTelemetry() -> [String] {
        list()
            .filter { [.running, .paused].contains($0.state) }
            .map(\.id)
            .sorted()
    }

    public func sampleDeviceTelemetry(machineID: String) throws {
        _ = try deviceTelemetry(id: machineID)
    }
}

public struct DoryMachineDeviceTelemetrySamplingResult: Sendable, Equatable {
    public var attemptedMachineIDs: [String]
    public var sampledMachineIDs: [String]
    public var failedMachineIDs: [String]

    public init(
        attemptedMachineIDs: [String],
        sampledMachineIDs: [String],
        failedMachineIDs: [String]
    ) {
        self.attemptedMachineIDs = attemptedMachineIDs
        self.sampledMachineIDs = sampledMachineIDs
        self.failedMachineIDs = failedMachineIDs
    }
}

public enum DoryMachineDeviceTelemetryMonitorEvent: Sendable, Equatable {
    case samplingFailed(machineID: String)
    case samplingRecovered(machineID: String)
}

/// Daemon-owned sampler that drains helper event history into each workspace flight recorder.
/// Failures are reported only on state transitions so an unavailable helper cannot flood incidents.
public final class DoryMachineDeviceTelemetryMonitor: @unchecked Sendable {
    private let machines: any DoryMachineDeviceTelemetrySampling
    private let interval: TimeInterval
    private let eventHandler: @Sendable (DoryMachineDeviceTelemetryMonitorEvent) -> Void
    private let queue = DispatchQueue(label: "dev.dory.machine-device-telemetry", qos: .utility)
    private let timerLock = NSLock()
    private let reconcileLock = NSLock()
    private var timer: DispatchSourceTimer?
    private var failedMachineIDs = Set<String>()

    public init(
        machines: any DoryMachineDeviceTelemetrySampling,
        interval: TimeInterval = 5,
        eventHandler: @escaping @Sendable (DoryMachineDeviceTelemetryMonitorEvent) -> Void = { _ in }
    ) {
        self.machines = machines
        self.interval = max(0.25, interval)
        self.eventHandler = eventHandler
    }

    @discardableResult
    public func reconcileNow() -> DoryMachineDeviceTelemetrySamplingResult {
        reconcileLock.lock()
        defer { reconcileLock.unlock() }

        let attempted = Array(Set(machines.activeMachineIDsForDeviceTelemetry())).sorted()
        let attemptedSet = Set(attempted)
        var sampled = [String]()
        var failed = [String]()
        for machineID in attempted {
            do {
                try machines.sampleDeviceTelemetry(machineID: machineID)
                sampled.append(machineID)
            } catch {
                failed.append(machineID)
            }
        }

        let nextFailed = Set(failed)
        for machineID in nextFailed.subtracting(failedMachineIDs).sorted() {
            eventHandler(.samplingFailed(machineID: machineID))
        }
        for machineID in failedMachineIDs.subtracting(nextFailed)
            .intersection(attemptedSet)
            .sorted() {
            eventHandler(.samplingRecovered(machineID: machineID))
        }
        failedMachineIDs = nextFailed
        return DoryMachineDeviceTelemetrySamplingResult(
            attemptedMachineIDs: attempted,
            sampledMachineIDs: sampled,
            failedMachineIDs: failed
        )
    }

    public func start() {
        timerLock.lock()
        guard timer == nil else {
            timerLock.unlock()
            return
        }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(250))
        source.setEventHandler { [weak self] in
            _ = self?.reconcileNow()
        }
        timer = source
        timerLock.unlock()
        source.resume()
    }

    public func stop() {
        timerLock.lock()
        let source = timer
        timer = nil
        timerLock.unlock()
        source?.setEventHandler {}
        source?.cancel()
    }

    deinit {
        stop()
    }
}
