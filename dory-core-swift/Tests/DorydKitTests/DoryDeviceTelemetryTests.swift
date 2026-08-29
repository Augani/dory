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
                DoryDeviceTelemetryEvent(
                    sequence: 2,
                    monotonicNanoseconds: 2,
                    deviceID: device.id,
                    kind: .portForwardUnavailable
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
        XCTAssertEqual(
            DoryDeviceTelemetryMetric.measured(
                .graphicsPresentationResidentBytes,
                value: 4_096
            ).unit,
            .bytes
        )
        XCTAssertEqual(
            DoryDeviceTelemetryMetric.measured(
                .graphicsPresentationPeakResidentBytes,
                value: 8_192
            ).unit,
            .bytes
        )
        XCTAssertEqual(
            DoryDeviceTelemetryMetric.measured(
                .graphicsPresentationRejectedReservations,
                value: 3
            ).unit,
            .count
        )
        XCTAssertEqual(
            DoryDeviceTelemetryMetric.measured(
                .displayBudgetRejectedFrames,
                value: 2
            ).unit,
            .count
        )
        XCTAssertEqual(
            DoryDeviceTelemetryMetric.measured(
                .displayUploadedFrameBytes,
                value: 16_384
            ).unit,
            .bytes
        )
        XCTAssertEqual(
            DoryDeviceTelemetryMetric.measured(
                .displayPendingFrameDepth,
                value: 2
            ).unit,
            .count
        )
        XCTAssertEqual(
            DoryDeviceTelemetryMetric.measured(
                .shareRequestPayloadBytes,
                value: 4_096
            ).unit,
            .bytes
        )
        XCTAssertEqual(
            DoryDeviceTelemetryMetric.measured(
                .shareMaximumRequestLatencyNanoseconds,
                value: 3
            ).unit,
            .nanoseconds
        )
        XCTAssertEqual(
            DoryDeviceTelemetryMetric.measured(
                .shareCompletedRequests,
                value: 1
            ).unit,
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

    func testInputMetricWireCatalogIsStableAndVersionOneRoundTrips() throws {
        let catalog: [(
            kind: DoryDeviceTelemetryMetricKind,
            rawValue: String,
            unit: DoryDeviceTelemetryMetricUnit
        )] = [
            (.inputSubmittedFrames, "input-submitted-frames", .count),
            (.inputPublishedFrames, "input-published-frames", .count),
            (.inputPublishedEvents, "input-published-events", .count),
            (.inputCoalescedMotionFrames, "input-coalesced-motion-frames", .count),
            (.inputDroppedFrames, "input-dropped-frames", .count),
            (.inputRejectedFrames, "input-rejected-frames", .count),
            (
                .inputStateReconciliationEvents,
                "input-state-reconciliation-events",
                .count
            ),
            (.inputInvalidEventBuffers, "input-invalid-event-buffers", .count),
            (.inputInvalidStatusBuffers, "input-invalid-status-buffers", .count),
            (.inputStatusEvents, "input-status-events", .count),
            (.inputQueueFaults, "input-queue-faults", .count),
            (.inputBoundedDrainStops, "input-bounded-drain-stops", .count),
            (.inputWorkerTurns, "input-worker-turns", .count),
            (.inputWorkerYields, "input-worker-yields", .count),
            (.inputCoalescedWorkerRequests, "input-coalesced-worker-requests", .count),
            (.inputRevokedWorkerTurns, "input-revoked-worker-turns", .count),
            (
                .inputPendingFrameSaturationEvents,
                "input-pending-frame-saturation-events",
                .count
            ),
            (.inputPendingFrameDepth, "input-pending-frame-depth", .count),
            (
                .inputPendingFrameHighWatermark,
                "input-pending-frame-high-watermark",
                .count
            ),
            (
                .inputAvailableEventBufferDepth,
                "input-available-event-buffer-depth",
                .count
            ),
            (
                .inputAvailableEventBufferHighWatermark,
                "input-available-event-buffer-high-watermark",
                .count
            ),
            (.inputEventQueueDepth, "input-event-queue-depth", .count),
            (.inputEventQueueHighWatermark, "input-event-queue-high-watermark", .count),
            (.inputStatusQueueDepth, "input-status-queue-depth", .count),
            (.inputStatusQueueHighWatermark, "input-status-queue-high-watermark", .count),
            (
                .inputPublicationLatencyNanoseconds,
                "input-publication-latency-nanoseconds",
                .nanoseconds
            ),
            (
                .inputMaximumPublicationLatencyNanoseconds,
                "input-maximum-publication-latency-nanoseconds",
                .nanoseconds
            ),
        ]
        XCTAssertEqual(catalog.count, 27)
        for entry in catalog {
            XCTAssertEqual(entry.kind.rawValue, entry.rawValue)
            XCTAssertEqual(entry.kind.expectedUnit, entry.unit)
        }

        let inputMetrics = catalog.enumerated().map { offset, entry in
            DoryDeviceTelemetryMetric.measured(
                entry.kind,
                value: UInt64(offset + 1)
            )
        }
        let snapshot = DoryDeviceTelemetrySnapshot(
            machineID: "raw-input",
            operationID: operationID,
            backend: .doryHypervisor,
            sampleSequence: 1,
            sampledAtUnixMilliseconds: 2,
            monotonicNanoseconds: 3,
            devices: [
                DoryDeviceTelemetryDevice(
                    id: "virtio-input-8",
                    kind: .input,
                    health: .healthy,
                    metrics: inputMetrics
                ),
            ]
        )
        XCTAssertEqual(snapshot.schemaVersion, 1)
        XCTAssertTrue(snapshot.isValid)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(DoryDeviceTelemetrySnapshot.self, from: encoded), snapshot)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual((object["schemaVersion"] as? NSNumber)?.uint16Value, 1)
        let devices = try XCTUnwrap(object["devices"] as? [[String: Any]])
        let metrics = try XCTUnwrap(devices.first?["metrics"] as? [[String: Any]])
        XCTAssertEqual(metrics.compactMap { $0["kind"] as? String }, catalog.map(\.rawValue))

        let firstMetric = try encoder.encode(inputMetrics[0])
        XCTAssertEqual(
            String(decoding: firstMetric, as: UTF8.self),
            #"{"availability":"measured","kind":"input-submitted-frames","unit":"count","value":1}"#
        )
    }

    func testLegacyVersionOneSnapshotWithoutInputMetricsRemainsDecodable() throws {
        let legacy = Data(#"""
        {
          "schemaVersion": 1,
          "machineID": "raw-input",
          "operationID": "12345678-1234-4234-8234-123456789abc",
          "backend": "dory-hypervisor",
          "sampleSequence": 1,
          "sampledAtUnixMilliseconds": 2,
          "monotonicNanoseconds": 3,
          "devices": [{
            "id": "virtio-input-8",
            "kind": "input",
            "health": "healthy",
            "metrics": [{
              "kind": "queue-notifications",
              "unit": "count",
              "availability": "measured",
              "value": 4
            }]
          }],
          "events": []
        }
        """#.utf8)

        let snapshot = try JSONDecoder().decode(DoryDeviceTelemetrySnapshot.self, from: legacy)
        XCTAssertTrue(snapshot.isValid)
        XCTAssertEqual(snapshot.schemaVersion, 1)
        XCTAssertEqual(snapshot.devices.first?.metrics.first?.kind, .queueNotifications)
        XCTAssertEqual(snapshot.devices.first?.metrics.first?.value, 4)
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
