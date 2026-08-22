import DorydKit
import Foundation
import Testing

@Suite struct DoryMachineDeviceTelemetryMonitorTests {
    @Test func samplesActiveMachinesAndReportsOnlyFailureTransitions() {
        let machines = FakeDeviceTelemetrySampler(
            activeMachineIDs: ["paused", "running", "running"],
            failedMachineIDs: ["paused"]
        )
        let events = LockedMonitorEvents()
        let monitor = DoryMachineDeviceTelemetryMonitor(machines: machines) { event in
            events.append(event)
        }

        let first = monitor.reconcileNow()
        #expect(first == DoryMachineDeviceTelemetrySamplingResult(
            attemptedMachineIDs: ["paused", "running"],
            sampledMachineIDs: ["running"],
            failedMachineIDs: ["paused"]
        ))
        #expect(events.value == [.samplingFailed(machineID: "paused")])
        #expect(machines.sampledMachineIDs == ["paused", "running"])

        _ = monitor.reconcileNow()
        #expect(events.value == [.samplingFailed(machineID: "paused")])

        machines.failedMachineIDs = []
        let recovered = monitor.reconcileNow()
        #expect(recovered.failedMachineIDs.isEmpty)
        #expect(events.value == [
            .samplingFailed(machineID: "paused"),
            .samplingRecovered(machineID: "paused"),
        ])
    }
}

private final class FakeDeviceTelemetrySampler:
    DoryMachineDeviceTelemetrySampling,
    @unchecked Sendable {
    private let lock = NSLock()
    private var storedActiveMachineIDs: [String]
    private var storedFailedMachineIDs: Set<String>
    private var storedSampledMachineIDs = [String]()

    init(activeMachineIDs: [String], failedMachineIDs: Set<String>) {
        storedActiveMachineIDs = activeMachineIDs
        storedFailedMachineIDs = failedMachineIDs
    }

    var failedMachineIDs: Set<String> {
        get { lock.withLock { storedFailedMachineIDs } }
        set { lock.withLock { storedFailedMachineIDs = newValue } }
    }

    var sampledMachineIDs: [String] {
        lock.withLock { storedSampledMachineIDs }
    }

    func activeMachineIDsForDeviceTelemetry() -> [String] {
        lock.withLock { storedActiveMachineIDs }
    }

    func sampleDeviceTelemetry(machineID: String) throws {
        let shouldFail = lock.withLock {
            storedSampledMachineIDs.append(machineID)
            return storedFailedMachineIDs.contains(machineID)
        }
        if shouldFail {
            throw CocoaError(.fileReadUnknown)
        }
    }
}

private final class LockedMonitorEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events = [DoryMachineDeviceTelemetryMonitorEvent]()

    var value: [DoryMachineDeviceTelemetryMonitorEvent] {
        lock.withLock { events }
    }

    func append(_ event: DoryMachineDeviceTelemetryMonitorEvent) {
        lock.withLock { events.append(event) }
    }
}
