import DoryCore
import DoryOperations
@testable import DorydKit
import Darwin
import Foundation
import XCTest

final class DoryDeviceTelemetryTests: XCTestCase {
    private let operationID = "12345678-1234-4234-8234-123456789abc"

    func testSnapshotRequiresExactMeasuredAndUnavailableShapes() {
        let device = DoryDeviceTelemetryDevice(
            id: "virtio-network-1",
            kind: .network,
            health: .healthy,
            metrics: [
                .measured(.receivedFrames, value: 7),
                .unavailable(.reconnects, reason: "counter is not exposed"),
            ]
        )
        let snapshot = DoryDeviceTelemetrySnapshot(
            machineID: "machine-a",
            operationID: operationID,
            backend: .doryHypervisor,
            sampleSequence: 1,
            sampledAtUnixMilliseconds: 1,
            monotonicNanoseconds: 1,
            devices: [device],
            events: [
                DoryDeviceTelemetryEvent(
                    sequence: 1,
                    monotonicNanoseconds: 1,
                    deviceID: device.id,
                    kind: .networkReconnect
                ),
            ]
        )

        XCTAssertTrue(snapshot.isValid)

        var duplicateMetric = snapshot
        duplicateMetric.devices[0].metrics.append(.measured(.receivedFrames, value: 8))
        XCTAssertFalse(duplicateMetric.isValid)

        var falseZero = snapshot
        falseZero.devices[0].metrics[1].value = 0
        XCTAssertFalse(falseZero.isValid)

        var wrongUnit = snapshot
        wrongUnit.devices[0].metrics[0].unit = .bytes
        XCTAssertFalse(wrongUnit.isValid)

        XCTAssertEqual(
            DoryDeviceTelemetryMetric.measured(.receivedBytes, value: 7).unit,
            .bytes
        )
        XCTAssertEqual(
            DoryDeviceTelemetryMetric.unavailable(
                .maximumStorageFlushLatencyNanoseconds,
                reason: "not exposed"
            ).unit,
            .nanoseconds
        )
        XCTAssertEqual(
            DoryDeviceTelemetryMetric.measured(.configuredPortForwards, value: 2).unit,
            .count
        )

        var unknownEventDevice = snapshot
        unknownEventDevice.events[0].deviceID = "not-present"
        XCTAssertFalse(unknownEventDevice.isValid)
    }

    func testUnavailableDeviceCannotPresentMeasuredZero() {
        let device = DoryDeviceTelemetryDevice(
            id: "virtualization-framework",
            kind: .platform,
            health: .unavailable,
            metrics: [.measured(.deviceResets, value: 0)]
        )
        XCTAssertFalse(device.isValid)
    }

    func testRawControlServerReturnsExactHelperTelemetry() throws {
        let root = "/tmp/dory-helper-telemetry-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        let socketPath = root + "/control.sock"
        let expected = DoryDeviceTelemetrySnapshot(
            machineID: "raw-machine",
            operationID: operationID,
            backend: .doryHypervisor,
            sampleSequence: 3,
            sampledAtUnixMilliseconds: 4,
            monotonicNanoseconds: 5,
            devices: [
                DoryDeviceTelemetryDevice(
                    id: "virtio-storage-0",
                    kind: .storage,
                    health: .healthy,
                    metrics: [.measured(.queueNotifications, value: 9)]
                ),
            ]
        )
        let server = VmmLifecycleReceiptServer(
            socketPath: socketPath,
            deviceTelemetryProvider: { expected }
        )
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: root)
        }
        try server.start()

        XCTAssertEqual(
            try UnixMachineDeviceTelemetryController().snapshot(socketPath: socketPath),
            expected
        )
    }

    func testControlServerRejectsInvalidProviderSnapshot() throws {
        let root = "/tmp/dory-helper-telemetry-invalid-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        let socketPath = root + "/control.sock"
        let invalid = DoryDeviceTelemetrySnapshot(
            machineID: "raw-machine",
            operationID: operationID,
            backend: .doryHypervisor,
            sampleSequence: 0,
            sampledAtUnixMilliseconds: 4,
            monotonicNanoseconds: 5,
            devices: []
        )
        let server = VmmLifecycleReceiptServer(
            socketPath: socketPath,
            deviceTelemetryProvider: { invalid }
        )
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: root)
        }
        try server.start()

        XCTAssertThrowsError(
            try UnixMachineDeviceTelemetryController().snapshot(socketPath: socketPath)
        )
    }
}
