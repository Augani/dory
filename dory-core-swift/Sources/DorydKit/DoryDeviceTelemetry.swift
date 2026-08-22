import DoryCore
import DoryOperations
import Foundation

public enum DoryDeviceTelemetryKind: String, Codable, Sendable, CaseIterable, Hashable {
    case platform
    case storage
    case network
    case graphics
    case display
    case audio
    case sharedDirectory = "shared-directory"
    case balloon
    case entropy
    case input
    case socket
}

public enum DoryDeviceTelemetryHealth: String, Codable, Sendable, CaseIterable, Hashable {
    case healthy
    case degraded
    case failed
    case unavailable
}

public enum DoryDeviceTelemetryMetricKind: String, Codable, Sendable, CaseIterable, Hashable {
    case queueNotifications = "queue-notifications"
    case queueStateChanges = "queue-state-changes"
    case usedInterrupts = "used-interrupts"
    case configurationInterrupts = "configuration-interrupts"
    case deviceResets = "device-resets"
    case transmittedFrames = "transmitted-frames"
    case transmittedBytes = "transmitted-bytes"
    case transmitDrops = "transmit-drops"
    case receivedFrames = "received-frames"
    case receivedBytes = "received-bytes"
    case receiveDeferred = "receive-deferred"
    case receiveDrops = "receive-drops"
    case receiveTruncations = "receive-truncations"
    case reconnects
    case configuredPortForwards = "configured-port-forwards"
    case activePortForwards = "active-port-forwards"
    case portForwardReconciliationFailures = "port-forward-reconciliation-failures"
    case displayFrames = "display-frames"
    case displayDrops = "display-drops"
    case audioDrops = "audio-drops"
    case storageFlushes = "storage-flushes"
    case maximumStorageFlushLatencyNanoseconds = "maximum-storage-flush-latency-nanoseconds"
    case graphicsFences = "graphics-fences"
    case graphicsDeviceLosses = "graphics-device-losses"
    case shareInvalidations = "share-invalidations"
    case shareInvalidationFailures = "share-invalidation-failures"

    public var expectedUnit: DoryDeviceTelemetryMetricUnit {
        switch self {
        case .transmittedBytes, .receivedBytes:
            .bytes
        case .maximumStorageFlushLatencyNanoseconds:
            .nanoseconds
        default:
            .count
        }
    }
}

public enum DoryDeviceTelemetryMetricUnit: String, Codable, Sendable, CaseIterable, Hashable {
    case count
    case bytes
    case nanoseconds
}

public enum DoryDeviceTelemetryMetricAvailability: String, Codable, Sendable, Hashable {
    case measured
    case unavailable
}

public struct DoryDeviceTelemetryMetric: Codable, Sendable, Equatable, Hashable {
    public var kind: DoryDeviceTelemetryMetricKind
    public var unit: DoryDeviceTelemetryMetricUnit
    public var availability: DoryDeviceTelemetryMetricAvailability
    public var value: UInt64?
    public var unavailableReason: String?

    public init(
        kind: DoryDeviceTelemetryMetricKind,
        unit: DoryDeviceTelemetryMetricUnit,
        availability: DoryDeviceTelemetryMetricAvailability,
        value: UInt64? = nil,
        unavailableReason: String? = nil
    ) {
        self.kind = kind
        self.unit = unit
        self.availability = availability
        self.value = value
        self.unavailableReason = unavailableReason
    }

    public static func measured(
        _ kind: DoryDeviceTelemetryMetricKind,
        unit: DoryDeviceTelemetryMetricUnit? = nil,
        value: UInt64
    ) -> Self {
        Self(
            kind: kind,
            unit: unit ?? kind.expectedUnit,
            availability: .measured,
            value: value
        )
    }

    public static func unavailable(
        _ kind: DoryDeviceTelemetryMetricKind,
        unit: DoryDeviceTelemetryMetricUnit? = nil,
        reason: String
    ) -> Self {
        Self(
            kind: kind,
            unit: unit ?? kind.expectedUnit,
            availability: .unavailable,
            unavailableReason: reason
        )
    }

    public var isValid: Bool {
        guard unit == kind.expectedUnit else { return false }
        switch availability {
        case .measured:
            return value != nil && unavailableReason == nil
        case .unavailable:
            return value == nil && Self.isValidText(unavailableReason, maximumUTF8Bytes: 256)
        }
    }

    private static func isValidText(_ value: String?, maximumUTF8Bytes: Int) -> Bool {
        guard let value, !value.isEmpty, value.utf8.count <= maximumUTF8Bytes else { return false }
        return !value.contains("\0") && !value.contains("\n") && !value.contains("\r")
    }
}

public struct DoryDeviceTelemetryDevice: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var kind: DoryDeviceTelemetryKind
    public var health: DoryDeviceTelemetryHealth
    public var metrics: [DoryDeviceTelemetryMetric]

    public init(
        id: String,
        kind: DoryDeviceTelemetryKind,
        health: DoryDeviceTelemetryHealth,
        metrics: [DoryDeviceTelemetryMetric]
    ) {
        self.id = id
        self.kind = kind
        self.health = health
        self.metrics = metrics
    }

    public var isValid: Bool {
        guard !id.isEmpty,
              id.utf8.count <= 128,
              !id.contains("\0"),
              !id.contains("\n"),
              !id.contains("\r"),
              !metrics.isEmpty,
              metrics.count <= DoryDeviceTelemetryMetricKind.allCases.count,
              metrics.allSatisfy(\.isValid),
              Set(metrics.map(\.kind)).count == metrics.count else {
            return false
        }
        if health == .unavailable {
            return metrics.allSatisfy { $0.availability == .unavailable }
        }
        return metrics.contains { $0.availability == .measured }
    }
}

public enum DoryDeviceTelemetryEventKind: String, Codable, Sendable, CaseIterable, Hashable {
    case queueStall = "queue-stall"
    case reset
    case graphicsFenceTimeout = "graphics-fence-timeout"
    case graphicsDeviceLoss = "graphics-device-loss"
    case networkReconnect = "network-reconnect"
    case portForwardUnavailable = "port-forward-unavailable"
    case portForwardRecovered = "port-forward-recovered"
    case audioDrop = "audio-drop"
    case storageFlushSlow = "storage-flush-slow"
    case shareInvalidationFailure = "share-invalidation-failure"
}

public struct DoryDeviceTelemetryEvent: Codable, Sendable, Equatable, Hashable {
    public var sequence: UInt64
    public var monotonicNanoseconds: UInt64
    public var deviceID: String
    public var kind: DoryDeviceTelemetryEventKind
    public var occurrences: UInt64

    public init(
        sequence: UInt64,
        monotonicNanoseconds: UInt64,
        deviceID: String,
        kind: DoryDeviceTelemetryEventKind,
        occurrences: UInt64 = 1
    ) {
        self.sequence = sequence
        self.monotonicNanoseconds = monotonicNanoseconds
        self.deviceID = deviceID
        self.kind = kind
        self.occurrences = occurrences
    }

    public var isValid: Bool {
        sequence > 0
            && monotonicNanoseconds > 0
            && occurrences > 0
            && !deviceID.isEmpty
            && deviceID.utf8.count <= 128
            && !deviceID.contains("\0")
            && !deviceID.contains("\n")
            && !deviceID.contains("\r")
    }
}

public struct DoryDeviceTelemetrySnapshot: Codable, Sendable, Equatable, Hashable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var machineID: String
    public var operationID: String
    public var backend: DoryVirtualizationBackendIdentity
    public var sampleSequence: UInt64
    public var sampledAtUnixMilliseconds: UInt64
    public var monotonicNanoseconds: UInt64
    public var devices: [DoryDeviceTelemetryDevice]
    public var events: [DoryDeviceTelemetryEvent]

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        machineID: String,
        operationID: String,
        backend: DoryVirtualizationBackendIdentity,
        sampleSequence: UInt64,
        sampledAtUnixMilliseconds: UInt64,
        monotonicNanoseconds: UInt64,
        devices: [DoryDeviceTelemetryDevice],
        events: [DoryDeviceTelemetryEvent] = []
    ) {
        self.schemaVersion = schemaVersion
        self.machineID = machineID
        self.operationID = operationID
        self.backend = backend
        self.sampleSequence = sampleSequence
        self.sampledAtUnixMilliseconds = sampledAtUnixMilliseconds
        self.monotonicNanoseconds = monotonicNanoseconds
        self.devices = devices
        self.events = events
    }

    public var isValid: Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              !machineID.isEmpty,
              machineID.utf8.count <= 128,
              !machineID.contains("\0"),
              !machineID.contains("\n"),
              !machineID.contains("\r"),
              sampleSequence > 0,
              sampledAtUnixMilliseconds > 0,
              monotonicNanoseconds > 0,
              DoryOperationIdentity.parseCanonical(operationID) != nil,
              operationID != "00000000-0000-0000-0000-000000000000",
              !devices.isEmpty,
              devices.count <= 64,
              devices.allSatisfy(\.isValid),
              Set(devices.map(\.id)).count == devices.count,
              events.count <= 256,
              events.allSatisfy(\.isValid) else {
            return false
        }
        var lastEventSequence: UInt64 = 0
        for event in events {
            guard event.sequence > lastEventSequence,
                  devices.contains(where: { $0.id == event.deviceID }) else {
                return false
            }
            lastEventSequence = event.sequence
        }
        return true
    }
}
