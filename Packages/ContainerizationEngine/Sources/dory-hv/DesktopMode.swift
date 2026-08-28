import AppKit
import Darwin
import DoryCore
import DoryFSWorkerContracts
import DoryHV
import DoryOperations
import DoryVMContracts
import DorydKit
import DoryVMMKit
import Foundation

private final class DoryDesktopCameraAttachment: @unchecked Sendable {
    enum Result: Sendable, Equatable {
        case attached
        case unavailable(String)

        var detailSuffix: String {
            switch self {
            case .attached:
                return "; Dory UVC Camera attached"
            case .unavailable(let detail):
                return "; camera unavailable: \(detail)"
            }
        }
    }

    private let backend: DoryMacCameraBackend
    private let handler: UsbControlHandler
    private let log: @Sendable (String) -> Void

    init(
        backend: DoryMacCameraBackend,
        handler: UsbControlHandler,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.backend = backend
        self.handler = handler
        self.log = log
    }

    /// Camera access is an optional host capability. A denied TCC grant, disconnected device, or
    /// failed UVC attach must be reported without tearing down an otherwise healthy desktop.
    func attachIfAvailable() async -> Result {
        log("dory-hv desktop: preparing Mac camera for Linux attachment")
        do {
            try backend.prepareAndAuthorize()
        } catch {
            backend.stop()
            let detail = String(describing: error)
            log("dory-hv desktop: camera unavailable: \(detail)")
            return .unavailable(detail)
        }
        do {
            let attachment = try await handler.attach(busID: DoryVirtualUVCCamera.busID)
            log(
                "dory-hv desktop: Dory UVC Camera attached on Linux VHCI port "
                    + "\(attachment.port)"
            )
            return .attached
        } catch {
            backend.stop()
            let detail = String(describing: error)
            log("dory-hv desktop: camera unavailable: \(detail)")
            return .unavailable(detail)
        }
    }

    func unavailableWithoutGuestTools() -> Result {
        let detail = "Dory Tools usb-vhci@1 is not installed in this Linux guest"
        backend.stop()
        log("dory-hv desktop: camera unavailable: \(detail)")
        return .unavailable(detail)
    }
}

final class RawDeviceTelemetryRegistry: @unchecked Sendable {
    private struct Entry {
        var id: String
        var kind: DoryDeviceTelemetryKind
        var transport: VirtioMMIOTransport
        var storage: VirtioBlk?
        var network: VirtioNet?
        var sharedDirectory: VirtioFS?
        var input: VirtioInput?
        var audioMetrics: (@Sendable () -> DoryMacAudioRuntimeMetrics?)?
        var displayMetrics: (@Sendable () -> DesktopFrameMailboxMetrics?)?
        var presentationBudgetMetrics:
            (@Sendable () -> DesktopCPUPresentationBudgetMetrics?)?
        var graphicsMetrics: (@Sendable () -> VirtioGPUStatistics?)?
        var unavailableMetrics: [(DoryDeviceTelemetryMetricKind, DoryDeviceTelemetryMetricUnit)]
        var previousTransportStatistics: VirtioMMIOTransportStatistics?
        var previousStorageStatistics: VirtioBlkStatistics?
        var previousAudioDrops: UInt64?
        var previousShareInvalidationFailures: UInt64?
        var previousDisplayDrops: UInt64?
        var previousGraphicsFenceRegistrationFailures: UInt64?
        var previousGraphicsFenceTimeouts: UInt64?
        var previousGraphicsDeviceLosses: UInt64?
        var consecutiveUncompletedNotificationSamples: UInt8
        var queueStallReported: Bool
    }

    private let machineID: String
    private let operationID: String
    private let lock = NSLock()
    private var sampleSequence: UInt64 = 0
    private var eventSequence: UInt64 = 0
    private var eventHistory = [DoryDeviceTelemetryEvent]()
    private var entries = [Entry]()
    private var resolvedPortForwardHealthProvider:
        (@Sendable () -> ResolvedPortForwardHealthSnapshot?)?
    private var previousResolvedPortForwardHealth: Bool?

    private static let queueStallSampleThreshold: UInt8 = 3
    private static let maximumEventHistory = 256

    init(machineID: String, operationID: UUID) {
        self.machineID = machineID
        self.operationID = DoryOperationIdentity.canonical(operationID)
    }

    func registerResolvedPortForwardHealth(
        _ provider: @escaping @Sendable () -> ResolvedPortForwardHealthSnapshot?
    ) {
        lock.withLock { resolvedPortForwardHealthProvider = provider }
    }

    func register(
        slot: Int,
        backend: any VirtioDeviceBackend,
        transport: VirtioMMIOTransport,
        audioMetrics: (@Sendable () -> DoryMacAudioRuntimeMetrics?)? = nil,
        displayMetrics: (@Sendable () -> DesktopFrameMailboxMetrics?)? = nil,
        presentationBudgetMetrics:
            (@Sendable () -> DesktopCPUPresentationBudgetMetrics?)? = nil,
        graphicsMetrics: (@Sendable () -> VirtioGPUStatistics?)? = nil
    ) {
        let effectiveGraphicsMetrics: (@Sendable () -> VirtioGPUStatistics?)?
        if let graphicsMetrics {
            effectiveGraphicsMetrics = graphicsMetrics
        } else if let graphics = backend as? VirtioGPU {
            effectiveGraphicsMetrics = { [weak graphics] in graphics?.statistics }
        } else {
            effectiveGraphicsMetrics = nil
        }
        let kind: DoryDeviceTelemetryKind
        var unavailable: [(DoryDeviceTelemetryMetricKind, DoryDeviceTelemetryMetricUnit)]
        switch backend {
        case is VirtioBlk:
            kind = .storage
            unavailable = []
        case is VirtioGPU:
            kind = .graphics
            unavailable = []
            if effectiveGraphicsMetrics == nil {
                unavailable.append(contentsOf: [
                    (.graphicsFences, .count),
                    (.graphicsDeviceLosses, .count),
                ])
            }
            if displayMetrics == nil {
                unavailable.append(contentsOf: [
                    (.displayFrames, .count),
                    (.displayDrops, .count),
                    (.displayBudgetRejectedFrames, .count),
                ])
            }
            if presentationBudgetMetrics == nil {
                unavailable.append(contentsOf: [
                    (.graphicsPresentationResidentBytes, .bytes),
                    (.graphicsPresentationPeakResidentBytes, .bytes),
                    (.graphicsPresentationRejectedReservations, .count),
                ])
            }
        case is VirtioSound:
            kind = .audio
            unavailable = audioMetrics == nil ? [(.audioDrops, .count)] : []
        case is VirtioFS:
            kind = .sharedDirectory
            unavailable = []
        case is VirtioNet, is VirtioDisconnectedNet:
            kind = .network
            unavailable = backend is VirtioNet ? [] : [
                (.transmittedFrames, .count),
                (.transmittedBytes, .bytes),
                (.transmitDrops, .count),
                (.transmitMalformed, .count),
                (.transmitOversized, .count),
                (.transmitInvalidDescriptors, .count),
                (.transmitBackpressure, .count),
                (.receivedFrames, .count),
                (.receivedBytes, .bytes),
                (.receiveDeferred, .count),
                (.receiveDrops, .count),
                (.receiveTruncations, .count),
                (.receiveMalformed, .count),
                (.receiveInvalidDescriptors, .count),
                (.receiveInsufficientCapacity, .count),
                (.receiveBacklogDrops, .count),
                (.receiveInactiveDrops, .count),
                (.receiveSocketErrors, .count),
                (.receiveActivationFailures, .count),
            ]
        case is VirtioBalloon:
            kind = .balloon
            unavailable = []
        case is VirtioRng:
            kind = .entropy
            unavailable = []
        case is VirtioInput:
            kind = .input
            unavailable = []
        case is VirtioVsock:
            kind = .socket
            unavailable = []
        default:
            kind = .platform
            unavailable = []
        }
        let entry = Entry(
            id: "virtio-\(kind.rawValue)-\(slot)",
            kind: kind,
            transport: transport,
            storage: backend as? VirtioBlk,
            network: backend as? VirtioNet,
            sharedDirectory: backend as? VirtioFS,
            input: backend as? VirtioInput,
            audioMetrics: audioMetrics,
            displayMetrics: displayMetrics,
            presentationBudgetMetrics: presentationBudgetMetrics,
            graphicsMetrics: effectiveGraphicsMetrics,
            unavailableMetrics: unavailable,
            previousTransportStatistics: nil,
            previousStorageStatistics: nil,
            previousAudioDrops: nil,
            previousShareInvalidationFailures: nil,
            previousDisplayDrops: nil,
            previousGraphicsFenceRegistrationFailures: nil,
            previousGraphicsFenceTimeouts: nil,
            previousGraphicsDeviceLosses: nil,
            consecutiveUncompletedNotificationSamples: 0,
            queueStallReported: false
        )
        lock.withLock { entries.append(entry) }
    }

    func snapshot() -> DoryDeviceTelemetrySnapshot {
        lock.withLock {
            sampleSequence &+= 1
            let sampledAtUnixMilliseconds = UInt64(Date().timeIntervalSince1970 * 1_000)
            let monotonicNanoseconds = DispatchTime.now().uptimeNanoseconds
            let unavailableReason = "raw-HV backend does not expose this counter yet"
            var devices = [DoryDeviceTelemetryDevice]()
            devices.reserveCapacity(entries.count + 1)

            for index in entries.indices {
                let transport = entries[index].transport.statistics
                var health = DoryDeviceTelemetryHealth.healthy
                if let previous = entries[index].previousTransportStatistics {
                    let resetCount = Self.monotonicDelta(
                        current: transport.deviceResets,
                        previous: previous.deviceResets
                    )
                    if resetCount > 0 {
                        appendEvent(
                            deviceID: entries[index].id,
                            kind: .reset,
                            occurrences: resetCount,
                            monotonicNanoseconds: monotonicNanoseconds
                        )
                        health = .degraded
                    }

                    let notificationsAdvanced =
                        transport.queueNotifications > previous.queueNotifications
                    let completionOrLifecycleAdvanced =
                        transport.usedInterrupts > previous.usedInterrupts
                        || transport.queueStateChanges > previous.queueStateChanges
                        || transport.deviceResets > previous.deviceResets
                    if completionOrLifecycleAdvanced {
                        entries[index].consecutiveUncompletedNotificationSamples = 0
                        entries[index].queueStallReported = false
                    } else if notificationsAdvanced
                        || entries[index].consecutiveUncompletedNotificationSamples > 0 {
                        if entries[index].consecutiveUncompletedNotificationSamples < UInt8.max {
                            entries[index].consecutiveUncompletedNotificationSamples += 1
                        }
                    }
                    if entries[index].consecutiveUncompletedNotificationSamples
                        >= Self.queueStallSampleThreshold {
                        health = .degraded
                        if !entries[index].queueStallReported {
                            appendEvent(
                                deviceID: entries[index].id,
                                kind: .queueStall,
                                occurrences: 1,
                                monotonicNanoseconds: monotonicNanoseconds
                            )
                            entries[index].queueStallReported = true
                        }
                    }
                }
                entries[index].previousTransportStatistics = transport

                var metrics: [DoryDeviceTelemetryMetric] = [
                    .measured(.queueNotifications, value: transport.queueNotifications),
                    .measured(.queueStateChanges, value: transport.queueStateChanges),
                    .measured(.usedInterrupts, value: transport.usedInterrupts),
                    .measured(.configurationInterrupts, value: transport.configurationInterrupts),
                    .measured(.deviceResets, value: transport.deviceResets),
                ]
                if let network = entries[index].network?.statistics {
                    metrics.append(contentsOf: Self.networkMetrics(network))
                }
                if let storage = entries[index].storage?.statistics {
                    let (storageQueueFaults, storageQueueFaultOverflow) =
                        storage.queuePopFaults.addingReportingOverflow(storage.completionFaults)
                    metrics.append(contentsOf: [
                        .measured(.storageFlushes, value: storage.flushes),
                        .measured(
                            .maximumStorageFlushLatencyNanoseconds,
                            value: storage.maximumFlushLatencyNanoseconds
                        ),
                        .measured(.storageInvalidRequests, value: storage.invalidRequests),
                        .measured(
                            .storageQueueFaults,
                            value: storageQueueFaultOverflow ? UInt64.max : storageQueueFaults
                        ),
                        .measured(
                            .storageBoundedDrainStops,
                            value: storage.boundedDrainStops
                        ),
                    ])
                    let previousSlowFlushes = entries[index].previousStorageStatistics?.slowFlushes ?? 0
                    let newSlowFlushes = Self.monotonicDelta(
                        current: storage.slowFlushes,
                        previous: previousSlowFlushes
                    )
                    if newSlowFlushes > 0 {
                        appendEvent(
                            deviceID: entries[index].id,
                            kind: .storageFlushSlow,
                            occurrences: newSlowFlushes,
                            monotonicNanoseconds: monotonicNanoseconds
                        )
                        health = .degraded
                    }
                    let previousQueueFaults: UInt64
                    if let previous = entries[index].previousStorageStatistics {
                        let (sum, overflow) = previous.queuePopFaults.addingReportingOverflow(
                            previous.completionFaults
                        )
                        previousQueueFaults = overflow ? UInt64.max : sum
                    } else {
                        previousQueueFaults = 0
                    }
                    let currentQueueFaults = storageQueueFaultOverflow
                        ? UInt64.max : storageQueueFaults
                    let newQueueFaults = Self.monotonicDelta(
                        current: currentQueueFaults,
                        previous: previousQueueFaults
                    )
                    if newQueueFaults > 0 {
                        appendEvent(
                            deviceID: entries[index].id,
                            kind: .storageQueueFault,
                            occurrences: newQueueFaults,
                            monotonicNanoseconds: monotonicNanoseconds
                        )
                        health = .degraded
                    }
                    entries[index].previousStorageStatistics = storage
                }
                if let audio = entries[index].audioMetrics?() {
                    let (sum, overflow) = audio.droppedPlaybackPeriods.addingReportingOverflow(
                        audio.droppedCapturePeriods
                    )
                    let drops = overflow ? UInt64.max : sum
                    metrics.append(.measured(.audioDrops, value: drops))
                    let previousDrops = entries[index].previousAudioDrops ?? 0
                    let newDrops = Self.monotonicDelta(current: drops, previous: previousDrops)
                    if newDrops > 0 {
                        appendEvent(
                            deviceID: entries[index].id,
                            kind: .audioDrop,
                            occurrences: newDrops,
                            monotonicNanoseconds: monotonicNanoseconds
                        )
                        health = .degraded
                    }
                    entries[index].previousAudioDrops = drops
                }
                if let share = entries[index].sharedDirectory?.statistics {
                    let performance = entries[index].sharedDirectory?.performanceStatistics
                    metrics.append(contentsOf: [
                        .measured(.shareInvalidations, value: share.invalidations),
                        .measured(
                            .shareInvalidationFailures,
                            value: share.invalidationFailures
                        ),
                    ])
                    if let performance {
                        metrics.append(contentsOf: [
                            .measured(
                                .shareRequestPayloadBytes,
                                value: performance.requestPayloadBytes
                            ),
                            .measured(
                                .shareWorkerResponsePayloadBytes,
                                value: performance.workerResponsePayloadBytes
                            ),
                            .measured(
                                .shareGuestPublishedResponseBytes,
                                value: performance.guestPublishedResponseBytes
                            ),
                            .measured(
                                .shareCompletedRequests,
                                value: performance.completedRequests
                            ),
                            .measured(
                                .shareFailedRequests,
                                value: performance.failedRequests
                            ),
                            .measured(
                                .shareInFlightRequests,
                                value: performance.inFlightRequests
                            ),
                            .measured(
                                .sharePeakInFlightRequests,
                                value: performance.peakInFlightRequests
                            ),
                            .measured(
                                .shareTotalRequestLatencyNanoseconds,
                                value: performance.totalRequestLatencyNanoseconds
                            ),
                            .measured(
                                .shareMaximumRequestLatencyNanoseconds,
                                value: performance.maximumRequestLatencyNanoseconds
                            ),
                        ])
                    }
                    let previousFailures =
                        entries[index].previousShareInvalidationFailures ?? 0
                    let newFailures = Self.monotonicDelta(
                        current: share.invalidationFailures,
                        previous: previousFailures
                    )
                    if newFailures > 0 {
                        appendEvent(
                            deviceID: entries[index].id,
                            kind: .shareInvalidationFailure,
                            occurrences: newFailures,
                            monotonicNanoseconds: monotonicNanoseconds
                        )
                        health = .degraded
                    }
                    if share.invalidationFailureLatched {
                        health = .failed
                    }
                    entries[index].previousShareInvalidationFailures =
                        share.invalidationFailures
                }
                if let input = entries[index].input?.statistics {
                    metrics.append(contentsOf: Self.inputMetrics(input))
                }
                if let display = entries[index].displayMetrics?() {
                    metrics.append(contentsOf: [
                        .measured(.displayFrames, value: display.presentedFrames),
                        .measured(.displayDrops, value: display.droppedFrames),
                        .measured(
                            .displayBudgetRejectedFrames,
                            value: display.budgetRejectedFrames
                        ),
                        .measured(
                            .displayReceivedFrameBytes,
                            value: display.receivedFrameBytes
                        ),
                        .measured(
                            .displayStagingCopyBytes,
                            value: display.stagingCopyBytes
                        ),
                        .measured(
                            .displayDrainCopyBytes,
                            value: display.drainCopyBytes
                        ),
                        .measured(
                            .displayUploadedFrameBytes,
                            value: display.uploadedFrameBytes
                        ),
                        .measured(
                            .displayDroppedFrameBytes,
                            value: display.droppedFrameBytes
                        ),
                        .measured(
                            .displayPendingFrameBytes,
                            value: display.pendingFrameBytes
                        ),
                        .measured(
                            .displayPendingFrameDepth,
                            value: display.pendingFrameDepth
                        ),
                    ])
                    let previousDrops = entries[index].previousDisplayDrops ?? 0
                    if Self.monotonicDelta(
                        current: display.droppedFrames,
                        previous: previousDrops
                    ) > 0 {
                        health = .degraded
                    }
                    entries[index].previousDisplayDrops = display.droppedFrames
                }
                if let budget = entries[index].presentationBudgetMetrics?() {
                    metrics.append(contentsOf: [
                        .measured(
                            .graphicsPresentationResidentBytes,
                            value: UInt64(max(0, budget.residentBytes))
                        ),
                        .measured(
                            .graphicsPresentationPeakResidentBytes,
                            value: UInt64(max(0, budget.peakResidentBytes))
                        ),
                        .measured(
                            .graphicsPresentationRejectedReservations,
                            value: budget.rejectedReservations
                        ),
                    ])
                }
                if let graphics = entries[index].graphicsMetrics?() {
                    metrics.append(contentsOf: [
                        .measured(.graphicsFences, value: graphics.fences),
                        .measured(
                            .graphicsDeviceLosses,
                            value: graphics.rendererDeviceLosses
                        ),
                    ])
                    let previousRegistrationFailures =
                        entries[index].previousGraphicsFenceRegistrationFailures ?? 0
                    if Self.monotonicDelta(
                        current: graphics.fenceRegistrationFailures,
                        previous: previousRegistrationFailures
                    ) > 0 {
                        health = .degraded
                    }
                    let previousTimeouts = entries[index].previousGraphicsFenceTimeouts ?? 0
                    let newTimeouts = Self.monotonicDelta(
                        current: graphics.fenceTimeouts,
                        previous: previousTimeouts
                    )
                    if newTimeouts > 0 {
                        appendEvent(
                            deviceID: entries[index].id,
                            kind: .graphicsFenceTimeout,
                            occurrences: newTimeouts,
                            monotonicNanoseconds: monotonicNanoseconds
                        )
                    }
                    if graphics.hasTimedOutPendingFence {
                        health = .failed
                    }
                    let previousDeviceLosses =
                        entries[index].previousGraphicsDeviceLosses ?? 0
                    let newDeviceLosses = Self.monotonicDelta(
                        current: graphics.rendererDeviceLosses,
                        previous: previousDeviceLosses
                    )
                    if newDeviceLosses > 0 {
                        appendEvent(
                            deviceID: entries[index].id,
                            kind: .graphicsDeviceLoss,
                            occurrences: newDeviceLosses,
                            monotonicNanoseconds: monotonicNanoseconds
                        )
                    }
                    if graphics.hasLostRendererDevice {
                        health = .failed
                    }
                    entries[index].previousGraphicsFenceRegistrationFailures =
                        graphics.fenceRegistrationFailures
                    entries[index].previousGraphicsFenceTimeouts = graphics.fenceTimeouts
                    entries[index].previousGraphicsDeviceLosses =
                        graphics.rendererDeviceLosses
                }
                metrics.append(contentsOf: entries[index].unavailableMetrics.map {
                    .unavailable($0.0, unit: $0.1, reason: unavailableReason)
                })
                devices.append(DoryDeviceTelemetryDevice(
                    id: entries[index].id,
                    kind: entries[index].kind,
                    health: health,
                    metrics: metrics
                ))
            }

            if let health = resolvedPortForwardHealthProvider?(), health.isValid {
                if let previous = previousResolvedPortForwardHealth,
                   previous != health.healthy {
                    appendEvent(
                        deviceID: "resolved-port-forwards",
                        kind: health.healthy
                            ? .portForwardRecovered : .portForwardUnavailable,
                        occurrences: 1,
                        monotonicNanoseconds: monotonicNanoseconds
                    )
                } else if previousResolvedPortForwardHealth == nil, !health.healthy {
                    appendEvent(
                        deviceID: "resolved-port-forwards",
                        kind: .portForwardUnavailable,
                        occurrences: 1,
                        monotonicNanoseconds: monotonicNanoseconds
                    )
                }
                previousResolvedPortForwardHealth = health.healthy
                devices.append(DoryDeviceTelemetryDevice(
                    id: "resolved-port-forwards",
                    kind: .network,
                    health: health.healthy ? .healthy : .degraded,
                    metrics: [
                        .measured(
                            .configuredPortForwards,
                            value: health.configuredForwards
                        ),
                        .measured(.activePortForwards, value: health.activeForwards),
                        .measured(
                            .portForwardReconciliationFailures,
                            value: health.failedReconciliations
                        ),
                    ]
                ))
            }

            return DoryDeviceTelemetrySnapshot(
                machineID: machineID,
                operationID: operationID,
                backend: .doryHypervisor,
                sampleSequence: sampleSequence,
                sampledAtUnixMilliseconds: sampledAtUnixMilliseconds,
                monotonicNanoseconds: monotonicNanoseconds,
                devices: devices,
                events: eventHistory
            )
        }
    }

    /// Keep the public diagnostic schema lossless with respect to the bounded virtio-net backend.
    /// Aggregate drops alone cannot distinguish malformed guest chains from host socket pressure,
    /// inactive queue epochs, or an activation failure—the exact distinction needed to repair a
    /// failed physical qualification without speculative changes to guest configuration.
    static func networkMetrics(
        _ network: VirtioNetStatistics
    ) -> [DoryDeviceTelemetryMetric] {
        [
            .measured(.transmittedFrames, value: network.transmitPackets),
            .measured(.transmittedBytes, value: network.transmitBytes),
            .measured(.transmitDrops, value: network.transmitDrops),
            .measured(.transmitMalformed, value: network.transmitMalformed),
            .measured(.transmitOversized, value: network.transmitOversized),
            .measured(
                .transmitInvalidDescriptors,
                value: network.transmitInvalidDescriptors
            ),
            .measured(.transmitBackpressure, value: network.transmitBackpressure),
            .measured(.receivedFrames, value: network.receivePackets),
            .measured(.receivedBytes, value: network.receiveBytes),
            .measured(.receiveDeferred, value: network.receiveDeferred),
            .measured(.receiveDrops, value: network.receiveDrops),
            .measured(.receiveTruncations, value: network.receiveTruncations),
            .measured(.receiveMalformed, value: network.receiveMalformed),
            .measured(
                .receiveInvalidDescriptors,
                value: network.receiveInvalidDescriptors
            ),
            .measured(
                .receiveInsufficientCapacity,
                value: network.receiveInsufficientCapacity
            ),
            .measured(.receiveBacklogDrops, value: network.receiveBacklogDrops),
            .measured(.receiveInactiveDrops, value: network.receiveInactiveDrops),
            .measured(.receiveSocketErrors, value: network.receiveSocketErrors),
            .measured(
                .receiveActivationFailures,
                value: network.receiveActivationFailures
            ),
        ]
    }

    /// A device-owned snapshot is copied under the input backend's small state lock. It never
    /// acquires the transport/register lock, walks the guest ring, or derives input behavior from
    /// transport counters. Keeping this projection one-to-one makes queue pressure and scheduling
    /// evidence diagnosable without giving the telemetry sampler lifecycle authority.
    static func inputMetrics(
        _ input: VirtioInputStatistics
    ) -> [DoryDeviceTelemetryMetric] {
        [
            .measured(.inputSubmittedFrames, value: input.submittedFrames),
            .measured(.inputPublishedFrames, value: input.publishedFrames),
            .measured(.inputPublishedEvents, value: input.publishedEvents),
            .measured(.inputCoalescedMotionFrames, value: input.coalescedMotionFrames),
            .measured(.inputDroppedFrames, value: input.droppedFrames),
            .measured(.inputRejectedFrames, value: input.rejectedFrames),
            .measured(
                .inputStateReconciliationEvents,
                value: input.stateReconciliationEvents
            ),
            .measured(.inputInvalidEventBuffers, value: input.invalidEventBuffers),
            .measured(.inputInvalidStatusBuffers, value: input.invalidStatusBuffers),
            .measured(.inputStatusEvents, value: input.statusEvents),
            .measured(.inputQueueFaults, value: input.queueFaults),
            .measured(.inputBoundedDrainStops, value: input.boundedDrainStops),
            .measured(.inputWorkerTurns, value: input.workerTurns),
            .measured(.inputWorkerYields, value: input.workerYields),
            .measured(.inputCoalescedWorkerRequests, value: input.coalescedWorkerRequests),
            .measured(.inputRevokedWorkerTurns, value: input.revokedWorkerTurns),
            .measured(
                .inputPendingFrameSaturationEvents,
                value: input.pendingFrameSaturationEvents
            ),
            .measured(.inputPendingFrameDepth, value: input.pendingFrameDepth),
            .measured(
                .inputPendingFrameHighWatermark,
                value: input.pendingFrameHighWatermark
            ),
            .measured(
                .inputAvailableEventBufferDepth,
                value: input.availableEventBufferDepth
            ),
            .measured(
                .inputAvailableEventBufferHighWatermark,
                value: input.availableEventBufferHighWatermark
            ),
            .measured(.inputEventQueueDepth, value: input.eventQueueDepth),
            .measured(.inputEventQueueHighWatermark, value: input.eventQueueHighWatermark),
            .measured(.inputStatusQueueDepth, value: input.statusQueueDepth),
            .measured(.inputStatusQueueHighWatermark, value: input.statusQueueHighWatermark),
            .measured(
                .inputPublicationLatencyNanoseconds,
                value: input.publicationLatencyNanoseconds
            ),
            .measured(
                .inputMaximumPublicationLatencyNanoseconds,
                value: input.maximumPublicationLatencyNanoseconds
            ),
        ]
    }

    private func appendEvent(
        deviceID: String,
        kind: DoryDeviceTelemetryEventKind,
        occurrences: UInt64,
        monotonicNanoseconds: UInt64
    ) {
        guard eventSequence < UInt64.max else { return }
        eventSequence += 1
        eventHistory.append(DoryDeviceTelemetryEvent(
            sequence: eventSequence,
            monotonicNanoseconds: monotonicNanoseconds,
            deviceID: deviceID,
            kind: kind,
            occurrences: occurrences
        ))
        if eventHistory.count > Self.maximumEventHistory {
            eventHistory.removeFirst(eventHistory.count - Self.maximumEventHistory)
        }
    }

    private static func monotonicDelta(current: UInt64, previous: UInt64) -> UInt64 {
        current >= previous ? current - previous : 0
    }
}

/// One-shot LIFO rollback for side effects acquired by a throwing initializer. Registered actions
/// remain armed until `commit`; an explicit rollback and `deinit` are both safe and idempotent.
final class DesktopInitializationRollback {
    private var actions = [() -> Void]()
    private var finished = false

    func register(_ action: @escaping () -> Void) {
        precondition(!finished, "cannot register initialization rollback after completion")
        actions.append(action)
    }

    func commit() {
        guard !finished else { return }
        finished = true
        actions.removeAll()
    }

    func performIfNeeded() {
        guard !finished else { return }
        finished = true
        let pending = Array(actions.reversed())
        actions.removeAll()
        for action in pending { action() }
    }

    deinit {
        performIfNeeded()
    }
}

enum DesktopGPUShutdownBoundaryResult: Equatable, Sendable {
    case completed(epoch: UInt64)
    case failed(epoch: UInt64, fault: VirtioGPURendererHealthFault)
    case timedOut(epoch: UInt64)

    var logDescription: String {
        switch self {
        case .completed(let epoch):
            return "completed at GPU epoch \(epoch)"
        case .failed(let epoch, let fault):
            return "failed at GPU epoch \(epoch): \(fault)"
        case .timedOut(let epoch):
            return "timed out at GPU epoch \(epoch)"
        }
    }

    var failure: VMError? {
        switch self {
        case .completed:
            return nil
        case .failed(let epoch, let fault):
            return .unexpectedExit(
                "GPU shutdown quiescence failed at epoch \(epoch): \(fault)"
            )
        case .timedOut(let epoch):
            return .unexpectedExit(
                "GPU shutdown quiescence timed out at epoch \(epoch)"
            )
        }
    }
}

/// The process-owned destruction boundary for virtio-gpu. Display detachment must run after the
/// device has published every release, but before a worker waits for renderer retirement. Keeping
/// these operations separate prevents AppKit release acknowledgements from being blocked by a
/// wait on the main actor.
enum DesktopGPUShutdownBoundary {
    static let timeoutSeconds: TimeInterval = 5

    static func begin(
        quiesce: () -> VirtioGPUQuiescence,
        detachPresentations: () -> Void
    ) -> VirtioGPUQuiescence {
        let receipt = quiesce()
        detachPresentations()
        return receipt
    }

    static func wait(
        for receipt: VirtioGPUQuiescence,
        timeout: TimeInterval = timeoutSeconds
    ) -> DesktopGPUShutdownBoundaryResult {
        guard let outcome = receipt.wait(timeout: timeout) else {
            return .timedOut(epoch: receipt.epoch)
        }
        switch outcome {
        case .completed:
            return .completed(epoch: receipt.epoch)
        case .failed(let fault):
            return .failed(epoch: receipt.epoch, fault: fault)
        }
    }
}

/// Orders guest setup against the first synchronized renderer presentation before readiness is
/// published. Generic media must prove graphics first because it has no Dory-owned boot barrier;
/// managed images must release their display-manager barrier first so a renderer-backed frame can
/// exist. Any failure escapes before `publish`, preserving the fail-closed handoff contract.
/// Optional host capabilities activate only after publication so a permission prompt or missing
/// device cannot keep an otherwise healthy desktop out of the running state.
enum DesktopGuestReadinessBoundary {
    static func complete<Prepared>(
        genericGuest: Bool,
        prepare: () throws -> Prepared,
        waitForSynchronizedPresentation: () throws -> Void,
        publish: (Prepared) async throws -> Void,
        activateOptionalCapabilities: (Prepared) async -> Void = { _ in }
    ) async rethrows {
        let prepared: Prepared
        if genericGuest {
            try waitForSynchronizedPresentation()
            prepared = try prepare()
        } else {
            prepared = try prepare()
            try waitForSynchronizedPresentation()
        }
        try await publish(prepared)
        await activateOptionalCapabilities(prepared)
    }
}

enum DesktopMachineExecutionState: Equatable, Sendable {
    case notStarted
    case running
    case ended

    var isTerminalBoundary: Bool {
        switch self {
        case .notStarted, .ended: true
        case .running: false
        }
    }
}

/// Dispatch signal sources run on a dedicated queue, while every controller operation is isolated
/// to the main actor. Keep the source callback itself nonisolated and use the AppKit run-loop relay
/// for the actor hop. Capturing a `Controller` directly in `setEventHandler` makes Swift annotate
/// the callback as main-actor code even though libdispatch invokes it on the signal queue, causing
/// a deliberate executor-precondition crash before SIGTERM can request a clean guest shutdown.
enum DesktopSignalEventRelay {
    static func makeHandler(
        _ operation: @escaping @MainActor @Sendable () -> Void
    ) -> @Sendable () -> Void {
        { DesktopAppRunLoop.perform(operation) }
    }
}

enum DesktopMode {
    enum RootDiskBacking: Equatable {
        case legacyPath(String)
        case resolvedDescriptor(descriptor: Int32, capacityBytes: UInt64)

        var virtualHardwareDiskAuthorityKind: RawHVVirtualHardwareDiskAuthorityKind {
            switch self {
            case .legacyPath: .legacyPath
            case .resolvedDescriptor: .resolvedDescriptor
            }
        }

        static func resolve(
            legacyPath: String?,
            runtimeLaunchEnvelope: RuntimeLaunchEnvelope?
        ) throws -> Self {
            switch (legacyPath, runtimeLaunchEnvelope) {
            case let (.some(path), nil) where !path.isEmpty:
                return .legacyPath(path)
            case let (nil, .some(envelope)):
                let slot = try envelope.validatedResolvedRawHVSystemDisk()
                guard fcntl(slot.descriptor, F_GETFD) >= 0 else {
                    throw VMError.invalidConfiguration(
                        "resolved systemDisk descriptor \(slot.descriptor) is not inherited"
                    )
                }
                return .resolvedDescriptor(
                    descriptor: slot.descriptor,
                    capacityBytes: slot.capacityBytes
                )
            default:
                throw VMError.invalidConfiguration(
                    "desktop requires exactly one root-disk authority mode"
                )
            }
        }

        func makeBackend(queueCount: Int) throws -> VirtioBlk {
            switch self {
            case .legacyPath(let path):
                return try VirtioBlk(
                    path: path,
                    identity: "dory-rootfs",
                    queueCount: queueCount
                )
            case .resolvedDescriptor(let descriptor, let capacityBytes):
                var info = stat()
                guard fstat(descriptor, &info) == 0,
                      (info.st_mode & S_IFMT) == S_IFREG,
                      info.st_uid == geteuid(),
                      info.st_nlink == 1,
                      info.st_size > 0,
                      (info.st_mode & 0o077) == 0,
                      UInt64(info.st_size) == capacityBytes else {
                    throw VMError.invalidConfiguration(
                        "inherited systemDisk failed owner/link/mode/capacity validation"
                    )
                }
                return try VirtioBlk(
                    fileDescriptor: descriptor,
                    identity: "dory-rootfs",
                    queueCount: queueCount
                )
            }
        }
    }

    struct Configuration {
        var machineID: String
        var operationID: UUID
        var stateDirectory: String
        var bootPayload: MachineBootPayload
        var rootDisk: RootDiskBacking
        var rootDevice: String
        var genericGuest: Bool
        var gvproxyPath: String
        var handoffSocketPath: String
        var agentSocketPath: String
        var shellSocketPath: String
        var consoleSocketPath: String
        var controlSocketPath: String
        var usbControlSocketPath: String?
        var sshAgentSocketPath: String?
        var memoryMB: UInt64
        var cpuCount: Int
        /// Exact guest-visible system-disk queue topology. Resolved launches take this value only
        /// from the canonical runtime envelope; legacy launches retain one queue.
        var systemDiskQueueCount: Int = 1
        var shares: [DoryMachineShareConfiguration]
        var environment: [String: String]
        var legacyGraphicsBackend: DoryDesktopGraphicsBackend? = nil
        var resolvedGraphics: DoryGraphicsAccelerationLevel?
        /// Fully authenticated before `DesktopMode.run`; nil for every software, host-display,
        /// and legacy launch. The controller never starts or discovers a renderer process.
        var rendererWorkerLaunch: DesktopRendererWorkerLaunch? = nil
        var resolvedPlanSHA256: String? = nil
        var resolvedPlanRevision: UInt64? = nil
        var resolvedDevices: DoryVirtualMachineDeviceCapabilityRequest?
        var resolvedPortForwards: [DoryVMPortForward]?
        var rawHVVirtualHardwareTopology: DoryRawHVVirtualHardwareTopology?
        var resolvedSystemDiskLogicalID: DoryVirtualDeviceID? = nil
        var displayPresentation: DoryMachineDisplayPresentation = .windowed

        /// Shares actually materialized by the resolved directory-sharing policy. Guest setup must
        /// consume this same inventory so it cannot try to mount a tag whose device was omitted.
        var attachedShares: [DoryMachineShareConfiguration] {
            resolvedDevices?.directorySharing == false ? [] : shares
        }

        var rawHVBootAuthorityKind: RawHVVirtualHardwareBootAuthorityKind {
            switch bootPayload {
            case .legacyPaths: .legacyPaths
            case .immutableBytes: .resolvedImmutableBytes
            }
        }
    }

    enum NetworkPlan: Equatable {
        case sharedNAT
        case hostOnly
        case disconnected

        init(resolvedDevices: DoryVirtualMachineDeviceCapabilityRequest?) throws {
            switch resolvedDevices?.networkAttachment ?? .sharedNAT {
            case .sharedNAT:
                self = .sharedNAT
            case .disconnected:
                self = .disconnected
            case .isolated:
                self = .hostOnly
            case .bridged:
                throw VMError.bootFailure(
                    "resolved device contract contains a network mode not implemented by raw-HV"
                )
            }
        }

        var startsGVProxy: Bool { self != .disconnected }
        var attachesNetworkDevice: Bool { true }
        var gvproxyConfigurationYAML: String? {
            self == .hostOnly ? GVProxyDesktopLaunchPlan.hostOnlyConfigurationYAML : nil
        }
    }

    struct DisplayPlan: Equatable {
        var id: String
        var scanoutID: UInt32
        var widthPixels: UInt32
        var heightPixels: UInt32
        var backingScaleFactor: UInt8
        var guestUIScaleFactor: UInt8

        private init(
            display: DoryVirtualMachineDisplayCapabilityRequest,
            scanoutID: UInt32
        ) throws {
            guard display.isValid, scanoutID < 16 else {
                throw VMError.bootFailure(
                    "resolved display geometry is outside the supported pixel bounds"
                )
            }
            id = display.id
            self.scanoutID = scanoutID
            widthPixels = display.widthPixels
            heightPixels = display.heightPixels
            backingScaleFactor = display.backingScaleFactor
            guestUIScaleFactor = display.guestUIScaleFactor
        }

        /// Source-compatible primary-display bridge for existing callers and tests.
        init(resolvedDevices: DoryVirtualMachineDeviceCapabilityRequest?) throws {
            self = try Self.resolve(resolvedDevices: resolvedDevices)[0]
        }

        static func resolve(
            resolvedDevices: DoryVirtualMachineDeviceCapabilityRequest?
        ) throws -> [DisplayPlan] {
            let displays = resolvedDevices?.displays ?? [DoryVMMDisplayDefaults.capability]
            guard !displays.isEmpty, displays.count <= 16 else {
                throw VMError.bootFailure(
                    "raw-HV desktop launch requires between one and sixteen displays"
                )
            }
            guard Set(displays.map(\.id)).count == displays.count else {
                throw VMError.bootFailure(
                    "resolved display identifiers must be unique"
                )
            }
            guard Set(displays.map(\.guestUIScaleFactor)).count == 1 else {
                throw VMError.bootFailure(
                    "raw-HV guest tools require one UI scale across all displays"
                )
            }
            return try displays.enumerated().map { index, display in
                try DisplayPlan(display: display, scanoutID: UInt32(index))
            }
        }

        var windowSize: NSSize {
            NSSize(
                width: max(1, CGFloat(widthPixels) / CGFloat(backingScaleFactor)),
                height: max(1, CGFloat(heightPixels) / CGFloat(backingScaleFactor))
            )
        }
    }

    struct ClipboardPlan: Equatable {
        var policy: DoryVMClipboardPolicy?

        init(
            resolvedDevices: DoryVirtualMachineDeviceCapabilityRequest?,
            environment: [String: String],
            genericGuest: Bool
        ) throws {
            guard let resolvedDevices else {
                policy = genericGuest ? nil
                    : DoryDesktopClipboardPolicy(
                        environment: environment
                    ).virtualMachinePolicy
                return
            }
            guard resolvedDevices.clipboard else {
                guard resolvedDevices.clipboardPolicy?.isEnabled != true else {
                    throw VMError.bootFailure(
                        "resolved clipboard device and directional policy disagree"
                    )
                }
                policy = nil
                return
            }
            let selected = resolvedDevices.clipboardPolicy
                ?? DoryDesktopClipboardPolicy(environment: environment).virtualMachinePolicy
            guard selected.isEnabled else {
                throw VMError.bootFailure(
                    "resolved clipboard device and directional policy disagree"
                )
            }
            // Files use the daemon-owned Dory Tools sync channel. Keep their direction in the
            // exact policy while this display-local coordinator handles only text and images.
            policy = selected
        }
    }

    enum GenericGuestShareReadiness: Equatable, Sendable {
        case mounted(Int)
        case unavailableMissingCapability([String])
        case unavailableMissingTools([String])

        var detailSuffix: String {
            switch self {
            case .mounted(let count):
                count == 0
                    ? ""
                    : "; \(count) virtio-fs share(s) proven mounted by Dory Tools"
            case .unavailableMissingCapability(let tags):
                "; requested virtio-fs shares unavailable because Dory Tools does not advertise virtiofs-mount@1: "
                    + tags.joined(separator: ", ")
            case .unavailableMissingTools(let tags):
                tags.isEmpty
                    ? ""
                    : "; requested virtio-fs shares unavailable because guest tools are not installed: "
                        + tags.joined(separator: ", ")
            }
        }
    }

    enum ShutdownPlan: Equatable {
        case guestAssisted
        case immediate

        init(resolvedDevices: DoryVirtualMachineDeviceCapabilityRequest?) {
            self = resolvedDevices?.gracefulShutdown == false
                ? .immediate : .guestAssisted
        }
    }

    private struct ResolvedGraphics {
        var backend: DoryDesktopGraphicsBackend
        var rendererWorkerLaunch: DesktopRendererWorkerLaunch?
    }

    @MainActor
    static func run(_ configuration: Configuration) throws {
        let controller = try Controller(configuration: configuration)
        try controller.run()
    }

    @MainActor
    private final class Controller: NSObject, NSApplicationDelegate, NSWindowDelegate {
        private struct MaterializedVirtioBackend {
            let request: DoryRawHVVirtualDeviceRequest
            let backend: any VirtioDeviceBackend
        }

        private let configuration: Configuration
        private let application = NSApplication.shared
        private let stateLock: EngineStateDirectoryLock
        private let serialLog: FileHandle
        private let serialOutput: BoundedSerialConsolePublisher
        #if arch(arm64)
        private let serialConsoleInput: RawHVSerialConsoleInput
        #endif
        private let machine: Machine
        private let machineRunner: RawHVMachineRunner
        private let gpu: VirtioGPU
        private let graphicsBackend: DoryDesktopGraphicsBackend
        private let rendererWorkerLaunch: DesktopRendererWorkerLaunch?
        private let rendererRuntimeFailureLatch: DesktopRendererRuntimeFailureLatch?
        private let keyboardInput: VirtioInput
        private let pointerInput: VirtioInput
        private let mailboxes: [DesktopFrameMailbox]
        private let displays: [DesktopDisplayView]
        private let windows: [NSWindow]
        private let displayAssignments: [DoryGuestDisplayPresentationAssignment?]
        private let vsock: VirtioVsock
        private let audio: DoryMacAudioBackend
        private let gvproxy: Process?
        private let networkSocketPaths: [String]
        private let resolvedPortForwardReconciler: ResolvedPortForwardReconciler?
        private let agentBridge: GuestVsockSocketBridge
        private let shellBridge: GuestVsockSocketBridge
        private let sshAgentBridge: HostSSHAgentBridge?
        private let usbipManager: UsbipManager
        private let cameraAttachment: DoryDesktopCameraAttachment?
        private let usbControlServer: UsbControlServer?
        private let clipboard: DoryDesktopClipboardCoordinator?
        private let firstFrame: FirstFrameGate
        private let deviceTelemetry: RawDeviceTelemetryRegistry
        private let lifecycleReceiptServer: VmmLifecycleReceiptServer
        private let graphicsSelection: DoryRuntimeGraphicsSelection?
        private let guestFSEventBridge: GuestFSEventBridge?
        private var filesystemWorker: DoryFilesystemWorkerLaunch?
        private var hostShareCoherence: DoryHostShareCoherenceBridge?
        private var signalSources = [DispatchSourceSignal]()
        private var stopError: Error?
        private var stopping = false
        private var gpuShutdownReceipt: VirtioGPUQuiescence?
        private var gpuShutdownResult: DesktopGPUShutdownBoundaryResult?
        private var gpuShutdownWaitScheduled = false
        private var machineExecutionState = DesktopMachineExecutionState.notStarted
        private let signalQueue = DispatchQueue(
            label: "dev.dory.dory-hv.desktop-signals",
            qos: .userInitiated
        )

        init(configuration: Configuration) throws {
            let virtualHardwareAttachmentMode = try RawHVVirtualHardwareAttachmentPlan.launchMode(
                diskAuthority: configuration.rootDisk.virtualHardwareDiskAuthorityKind,
                bootAuthority: configuration.rawHVBootAuthorityKind,
                topology: configuration.rawHVVirtualHardwareTopology,
                resolvedGraphics: configuration.resolvedGraphics,
                resolvedDevices: configuration.resolvedDevices,
                resolvedPortForwards: configuration.resolvedPortForwards,
                resolvedSystemDiskLogicalID: configuration.resolvedSystemDiskLogicalID,
                directoryShareStableIDs: configuration.shares.map(\.tag)
            )
            self.configuration = configuration
            let deviceTelemetry = RawDeviceTelemetryRegistry(
                machineID: configuration.machineID,
                operationID: configuration.operationID
            )
            self.deviceTelemetry = deviceTelemetry
            self.lifecycleReceiptServer = VmmLifecycleReceiptServer(
                socketPath: configuration.controlSocketPath,
                deviceTelemetryProvider: { deviceTelemetry.snapshot() }
            )
            try FileManager.default.createDirectory(
                atPath: configuration.stateDirectory,
                withIntermediateDirectories: true
            )
            self.stateLock = try EngineStateDirectoryLock(stateDirectory: configuration.stateDirectory)
            self.serialLog = try Self.openAppendLog("\(configuration.stateDirectory)/serial.log")
            try Self.appendBootSessionMarker(
                to: serialLog,
                machineID: configuration.machineID,
                operationID: configuration.operationID
            )
            self.serialOutput = try BoundedSerialConsolePublisher(destinations: [
                .init(fileHandle: FileHandle.standardError),
                .init(fileHandle: serialLog, synchronizeOnStop: true),
            ])
            let resolvedGraphics = try Self.resolveGraphics(
                legacyBackend: configuration.legacyGraphicsBackend,
                exactLevel: configuration.resolvedGraphics,
                rendererWorkerLaunch: configuration.rendererWorkerLaunch
            )
            self.graphicsBackend = resolvedGraphics.backend
            self.rendererWorkerLaunch = resolvedGraphics.rendererWorkerLaunch
            let rendererRuntimeFailureLatch = resolvedGraphics.rendererWorkerLaunch == nil
                ? nil : DesktopRendererRuntimeFailureLatch()
            self.rendererRuntimeFailureLatch = rendererRuntimeFailureLatch
            self.graphicsSelection = try Self.graphicsSelection(
                configuration: configuration,
                resolvedBackend: resolvedGraphics.backend,
                rendererWorkerLaunch: resolvedGraphics.rendererWorkerLaunch
            )
            let networkPlan = try NetworkPlan(resolvedDevices: configuration.resolvedDevices)
            let networkInterface = configuration.resolvedDevices?.networkInterface
            if let networkInterface, !networkInterface.isValid {
                throw VMError.bootFailure(
                    "resolved network interface identity or MTU is invalid"
                )
            }
            let displayPlans = try DisplayPlan.resolve(
                resolvedDevices: configuration.resolvedDevices
            )
            if let devices = configuration.resolvedDevices {
                guard devices.directorySharing == !configuration.shares.isEmpty else {
                    throw VMError.bootFailure(
                        "resolved directory-sharing contract does not match the launch shares"
                    )
                }
            }
            let clipboardPlan = try ClipboardPlan(
                resolvedDevices: configuration.resolvedDevices,
                environment: configuration.environment,
                genericGuest: configuration.genericGuest
            )
            let machine = try Machine(configuration: MachineConfiguration(
                bootPayload: configuration.bootPayload,
                commandLine: Self.kernelCommandLine(
                    machineID: configuration.machineID,
                    operationID: configuration.operationID,
                    rootDevice: configuration.rootDevice,
                    graphicsBackend: resolvedGraphics.backend,
                    genericGuest: configuration.genericGuest
                ),
                memoryBytes: configuration.memoryMB << 20,
                cpuCount: configuration.cpuCount
            ))
            self.machine = machine
            self.machineRunner = RawHVMachineRunner(
                machine: machine,
                threadName: "dory-hv.desktop.vcpu0"
            )
            #if arch(arm64)
            let uart = Self.attachPlatformDevices(to: machine, serialOutput: serialOutput)
            self.serialConsoleInput = try RawHVSerialConsoleInput(
                socketPath: configuration.consoleSocketPath,
                uart: uart
            )
            #endif

            self.keyboardInput = VirtioInput(profile: .keyboard)
            self.pointerInput = VirtioInput(profile: .absolutePointer)
            let rendererWorkerLaunch = resolvedGraphics.rendererWorkerLaunch
            var mailboxes = [DesktopFrameMailbox]()
            var cursorMailboxes = [DesktopCursorMailbox]()
            var displays = [DesktopDisplayView]()
            let presentationBudget = DesktopCPUPresentationBudget.processDefault
            let pointerTopology = DesktopPointerTopology(sizes: displayPlans.map {
                VirtioGPUScanoutSize(width: $0.widthPixels, height: $0.heightPixels)
            })
            for plan in displayPlans {
                let mailbox = DesktopFrameMailbox(
                    scanoutID: plan.scanoutID,
                    sharedCPUPresentationBudget: presentationBudget
                )
                let cursorMailbox = DesktopCursorMailbox()
                let metalDisplay = try DesktopMetalView(
                    frame: NSRect(origin: .zero, size: plan.windowSize),
                    keyboardInput: keyboardInput,
                    pointerInput: pointerInput,
                    guestBackingScaleFactor: CGFloat(plan.backingScaleFactor),
                    scanoutID: plan.scanoutID,
                    pointerTopology: pointerTopology
                )
                metalDisplay.onDeviceFailure = {
                    [
                        weak machine,
                        weak rendererWorkerLaunch,
                        rendererRuntimeFailureLatch,
                    ] reason in
                    rendererRuntimeFailureLatch?.record(
                        kind: .metalDevice,
                        reason: reason
                    )
                    rendererWorkerLaunch?.failSynchronizedPresentation(reason)
                    rendererWorkerLaunch?.teardown(reason: reason)
                    machine?.requestStop(.crash("Metal display failed closed: \(reason)"))
                }
                metalDisplay.onWorkerPresentationCompleted = {
                    [weak rendererWorkerLaunch] workerGeneration in
                    rendererWorkerLaunch?.recordSynchronizedPresentation(
                        workerGeneration: workerGeneration
                    )
                }
                let display: DesktopDisplayView = metalDisplay
                mailbox.view = display
                cursorMailbox.view = display
                mailboxes.append(mailbox)
                cursorMailboxes.append(cursorMailbox)
                displays.append(display)
            }
            self.mailboxes = mailboxes
            self.displays = displays
            let firstFrame = FirstFrameGate(requiredScanoutCount: displayPlans.count)
            self.firstFrame = firstFrame

            let hostVisibleMemory = try rendererWorkerLaunch != nil
                ? VirtioGPUHostVisibleMemory(guestBase: GuestLayout.daxWindowBase)
                : nil
            let gpu = VirtioGPU(
                hostMemoryBase: GuestLayout.daxWindowBase,
                scanoutSizes: displayPlans.map {
                    VirtioGPUScanoutSize(width: $0.widthPixels, height: $0.heightPixels)
                },
                rendererWorkerCandidate: rendererWorkerLaunch?.commandLane,
                hostVisibleMemory: hostVisibleMemory,
                onScanoutFrame: { [mailboxes, firstFrame] frame in
                    guard mailboxes.indices.contains(Int(frame.scanoutID)) else { return }
                    mailboxes[Int(frame.scanoutID)].submit(frame)
                    firstFrame.signal(scanoutID: frame.scanoutID)
                },
                onMetalScanout: { [mailboxes] update in
                    guard mailboxes.indices.contains(Int(update.scanoutID)) else {
                        update.presentation.discardWithoutPresentation()
                        return
                    }
                    mailboxes[Int(update.scanoutID)].submit(update)
                },
                onScanoutResourceReleased: { [mailboxes] release in
                    for mailbox in mailboxes {
                        mailbox.release(release)
                    }
                },
                onScanoutDisabled: { [mailboxes] scanoutID in
                    guard mailboxes.indices.contains(Int(scanoutID)) else { return }
                    mailboxes[Int(scanoutID)].disable()
                },
                onCursorUpdate: { [cursorMailboxes] update in
                    guard let update else {
                        for mailbox in cursorMailboxes { mailbox.submit(nil) }
                        return
                    }
                    guard cursorMailboxes.indices.contains(Int(update.scanoutID)) else { return }
                    cursorMailboxes[Int(update.scanoutID)].submit(update)
                },
                onRendererWorkerFailure: {
                    [
                        weak machine,
                        weak rendererWorkerLaunch,
                        rendererRuntimeFailureLatch,
                    ] reason in
                    rendererRuntimeFailureLatch?.record(
                        kind: .worker,
                        reason: reason
                    )
                    rendererWorkerLaunch?.failSynchronizedPresentation(reason)
                    rendererWorkerLaunch?.teardown(reason: reason)
                    machine?.requestStop(.crash(
                        "renderer worker failed closed: \(reason)"
                    ))
                }
            )
            self.gpu = gpu
            let initializationRollback = DesktopInitializationRollback()
            defer { initializationRollback.performIfNeeded() }
            initializationRollback.register {
                let receipt = DesktopGPUShutdownBoundary.begin(
                    quiesce: { gpu.quiesce(reason: .shutdown) },
                    detachPresentations: {
                        for mailbox in mailboxes { mailbox.deliver() }
                    }
                )
                let result = DesktopGPUShutdownBoundary.wait(for: receipt)
                Self.log(
                    "dory-hv desktop: GPU initialization rollback \(result.logDescription)"
                )
            }
            let vsock = VirtioVsock(guestCID: 3)
            self.vsock = vsock
            initializationRollback.register { _ = vsock.quiesce() }
            let usbipManager = UsbipManager(log: Self.log)
            try usbipManager.attachListener(to: vsock)
            initializationRollback.register {
                // Initialization rollback runs before startMachine(), so guest execution never
                // acquired vhci state. Use the same explicit terminal boundary as normal teardown.
                switch usbipManager.stopAfterGuestExecutionEnded() {
                case .completed:
                    break
                case .authorityRetained(let busIDs):
                    let detail = busIDs.isEmpty
                        ? "pending listener, bridge, or device drain"
                        : "claims: \(busIDs.joined(separator: ", "))"
                    Self.log(
                        "dory-hv desktop: USB/IP initialization retirement retained authority asynchronously (\(detail))"
                    )
                }
            }
            self.usbipManager = usbipManager
            let cameraBackend = configuration.resolvedDevices?.cameraInput == true
                ? DoryMacCameraBackend(log: Self.log) : nil
            if let cameraBackend {
                initializationRollback.register { cameraBackend.stop() }
            }
            let usbControlHandler = UsbControlHandler(
                manager: usbipManager,
                allowedOpenModes: [.userAuthorized],
                ensureSupported: {
                    Self.log("dory-hv desktop: USB camera opening Dory Tools capability channel")
                    let control = AgentControl(configuration: .init(
                        directSocketPath: configuration.agentSocketPath
                    ))
                    defer { control.disconnect() }
                    let info = try control.info()
                    guard info.protocolVersion == DoryCore.protocolVersion(),
                          info.capabilitiesAreCanonical,
                          info.supports("usb-vhci", minimumVersion: 1) else {
                        throw UsbControlError.guestAgentRPCUnavailable
                    }
                    Self.log("dory-hv desktop: USB camera confirmed Dory Tools usb-vhci@1")
                },
                openDevice: { busID, mode in
                    if busID == DoryVirtualUVCCamera.busID, let cameraBackend {
                        return HostUsbDevice(
                            descriptor: DoryVirtualUVCCamera.descriptor(),
                            backend: DoryVirtualUVCCameraBackend(frameSource: cameraBackend),
                            timeout: 5,
                            maxConcurrentRequests: 8,
                            maxInFlightBytes: 16 * 1_024 * 1_024,
                            shutdownTimeout: 2
                        )
                    }
                    return try HostUsbDeviceFactory.open(busID: busID, mode: mode)
                },
                notifyAttach: { request in
                    Self.log("dory-hv desktop: USB camera requesting Linux VHCI attachment")
                    let control = AgentControl(configuration: .init(
                        directSocketPath: configuration.agentSocketPath
                    ))
                    defer { control.disconnect() }
                    try control.usbVhciAttach(
                        busID: request.busid,
                        port: UInt32(request.port),
                        vsockPort: request.vsock_port,
                        deviceID: request.device_id,
                        speed: request.speed
                    )
                    Self.log("dory-hv desktop: USB camera Linux VHCI attachment acknowledged")
                },
                notifyDetach: { request in
                    Self.log("dory-hv desktop: USB camera requesting Linux VHCI detach")
                    let control = AgentControl(configuration: .init(
                        directSocketPath: configuration.agentSocketPath
                    ))
                    defer { control.disconnect() }
                    try control.usbVhciDetach(
                        busID: request.busid,
                        port: UInt32(request.port)
                    )
                    Self.log("dory-hv desktop: USB camera Linux VHCI detach acknowledged")
                },
                trace: { Self.log("dory-hv desktop: USB camera \($0)") }
            )
            self.cameraAttachment = cameraBackend.map {
                DoryDesktopCameraAttachment(
                    backend: $0,
                    handler: usbControlHandler,
                    log: Self.log
                )
            }
            self.usbControlServer = configuration.usbControlSocketPath.map {
                UsbControlServer(path: $0, handler: usbControlHandler)
            }
            self.audio = DoryMacAudioBackend(log: Self.log)
            var audioDirections = [VirtioSoundDirection]()
            if configuration.resolvedDevices?.audioOutput != false {
                audioDirections.append(.output)
            }
            if configuration.resolvedDevices?.audioInput != false {
                audioDirections.append(.input)
            }
            let sound = audioDirections.isEmpty
                ? nil
                : VirtioSound(
                    host: audio,
                    enabledDirections: audioDirections,
                    log: Self.log
                )
            let balloon = VirtioBalloon(memory: machine.memory) { message in
                Self.log(message)
            }

            let runtimeDirectory = (configuration.agentSocketPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: runtimeDirectory, withIntermediateDirectories: true)
            guard chmod(runtimeDirectory, 0o700) == 0 else {
                throw VMError.bootFailure(
                    "could not secure raw-HV runtime socket directory: \(errno)"
                )
            }
            let token = String(configuration.machineID.prefix(12))
            let networkRuntime = try Self.prepareNetwork(
                plan: networkPlan,
                networkInterface: networkInterface,
                gvproxyPath: configuration.gvproxyPath,
                runtimeDirectory: runtimeDirectory,
                token: token,
                resolvedPortForwards: configuration.resolvedPortForwards
            )
            initializationRollback.register {
                networkRuntime.portForwardReconciler?.stop()
                if let process = networkRuntime.process {
                    ChildProcessTerminator.terminateAndReap(process)
                }
                for path in networkRuntime.socketPaths { unlink(path) }
            }
            self.gvproxy = networkRuntime.process
            self.networkSocketPaths = networkRuntime.socketPaths
            self.resolvedPortForwardReconciler = networkRuntime.portForwardReconciler
            if let reconciler = networkRuntime.portForwardReconciler {
                deviceTelemetry.registerResolvedPortForwardHealth { [weak reconciler] in
                    reconciler?.healthSnapshot()
                }
            }
            do {
                let rootDisk = try configuration.rootDisk.makeBackend(
                    queueCount: configuration.systemDiskQueueCount
                )
                let entropy = VirtioRng()
                var backends: [any VirtioDeviceBackend] = [
                    rootDisk,
                    gpu,
                    entropy,
                    balloon,
                    vsock,
                ]
                if configuration.resolvedDevices?.keyboard != false {
                    backends.append(keyboardInput)
                }
                if configuration.resolvedDevices?.pointer != false {
                    backends.append(pointerInput)
                }
                if let sound {
                    backends.append(sound)
                }
                let attachedShares = configuration.attachedShares
                let rawShares = try attachedShares.map { share in
                    try VirtioFSShareConfiguration(
                        tag: share.tag,
                        path: share.hostPath,
                        readOnly: share.readOnly,
                        guestMountPoint: share.guestPath
                    )
                }
                try VirtioFSShareConfiguration.validateWritableTopology(rawShares)
                let coherencePolicyByTag = Dictionary(uniqueKeysWithValues: rawShares.map {
                    share in
                    (
                        share.tag,
                        share.readOnly || configuration.genericGuest
                            ? DoryFSShareCoherencePolicy.invalidationOnly
                            : .invalidationAndWatcherNudge
                    )
                })
                let filesystemWorker = rawShares.isEmpty
                    ? nil
                    : try DoryFilesystemWorkerLauncher.startBlocking(
                        shares: rawShares,
                        coherencePolicyByTag: coherencePolicyByTag
                    )
                self.filesystemWorker = filesystemWorker
                if let filesystemWorker {
                    initializationRollback.register {
                        filesystemWorker.client.invalidate()
                    }
                }
                var shareBackends = [(share: DoryMachineShareConfiguration,
                                      backend: any VirtioDeviceBackend)]()
                var coherenceEndpoints = [DoryHostShareCoherenceEndpoint]()
                for (share, rawShare) in zip(attachedShares, rawShares) {
                    guard let filesystemWorker else {
                        throw VMError.invalidConfiguration(
                            "filesystem worker missing for attached share"
                        )
                    }
                    let backend = try rawShare.makeBackend(
                        broker: filesystemWorker.broker(for: rawShare),
                        requestQueueCount: min(8, max(1, configuration.cpuCount)),
                        onWorkerLifecycle: { [weak machine] event in
                            Self.log("dory-hv desktop: \(event.diagnostic)")
                            if case .failure(let reason) = event {
                                machine?.requestStop(.crash(reason))
                            }
                        }
                    )
                    backends.append(backend)
                    shareBackends.append((share, backend))
                    coherenceEndpoints.append(try DoryHostShareCoherenceEndpoint(
                        capabilityID: filesystemWorker.capability(for: rawShare),
                        backend: backend,
                        guestRoot: share.guestPath,
                        policy: coherencePolicyByTag[share.tag] ?? .disabled
                    ))
                }
                var configuredGuestFSEventBridge: GuestFSEventBridge?
                if let filesystemWorker {
                    let guestFSEventBridge = GuestFSEventBridge(vsock: vsock)
                    let hostShareCoherence = DoryHostShareCoherenceBridge(
                        endpoints: coherenceEndpoints,
                        guestEvents: guestFSEventBridge
                    ) { [weak machine] reason in
                        Self.log("dory-hv desktop: \(reason)")
                        machine?.requestStop(.crash(reason))
                    }
                    guard filesystemWorker.installCoherenceHandler({ batch in
                        try await hostShareCoherence.process(batch)
                    }) else {
                        throw VMError.invalidConfiguration(
                            "desktop filesystem coherence handler was already installed"
                        )
                    }
                    filesystemWorker.installLifecycleHandler { [weak hostShareCoherence] event in
                        hostShareCoherence?.failStop(
                            "filesystem worker coherence channel \(event)"
                        )
                    }
                    try filesystemWorker.client.prepareCoherence()
                    self.hostShareCoherence = hostShareCoherence
                    if coherenceEndpoints.contains(where: {
                        $0.policy == .invalidationAndWatcherNudge
                    }) {
                        configuredGuestFSEventBridge = guestFSEventBridge
                    }
                }
                guestFSEventBridge = configuredGuestFSEventBridge
                if let network = networkRuntime.backend {
                    backends.append(network)
                }

                let attachments: [(slot: Int, backend: any VirtioDeviceBackend)]
                let resolvedAssignments: [RawHVVirtualHardwareAttachmentAssignment]?
                switch virtualHardwareAttachmentMode {
                case .legacy:
                    resolvedAssignments = nil
                case .resolved(let assignments):
                    resolvedAssignments = assignments
                }
                if let preflightAssignments = resolvedAssignments {
                    let authorizedDevices = preflightAssignments.map(\.request)
                    var materialized = [MaterializedVirtioBackend]()
                    materialized.append(try Self.singletonMaterialization(
                        role: .systemDisk,
                        authorizedDevices: authorizedDevices,
                        backend: rootDisk
                    ))
                    materialized.append(try Self.singletonMaterialization(
                        role: .graphics,
                        authorizedDevices: authorizedDevices,
                        backend: gpu
                    ))
                    materialized.append(try Self.singletonMaterialization(
                        role: .entropy,
                        authorizedDevices: authorizedDevices,
                        backend: entropy
                    ))
                    materialized.append(try Self.singletonMaterialization(
                        role: .balloon,
                        authorizedDevices: authorizedDevices,
                        backend: balloon
                    ))
                    materialized.append(try Self.singletonMaterialization(
                        role: .vsock,
                        authorizedDevices: authorizedDevices,
                        backend: vsock
                    ))
                    if configuration.resolvedDevices?.keyboard == true {
                        materialized.append(try Self.singletonMaterialization(
                            role: .keyboard,
                            authorizedDevices: authorizedDevices,
                            backend: keyboardInput
                        ))
                    }
                    if configuration.resolvedDevices?.pointer == true {
                        materialized.append(try Self.singletonMaterialization(
                            role: .pointer,
                            authorizedDevices: authorizedDevices,
                            backend: pointerInput
                        ))
                    }
                    if let sound {
                        materialized.append(try Self.singletonMaterialization(
                            role: .audio,
                            authorizedDevices: authorizedDevices,
                            backend: sound
                        ))
                    }
                    for entry in shareBackends {
                        materialized.append(MaterializedVirtioBackend(
                            request: DoryRawHVVirtualDeviceRequest(
                                logicalID: try DoryVirtualDeviceID.derived(
                                    namespace: .directoryShare,
                                    stableID: entry.share.tag
                                ),
                                role: .directoryShare
                            ),
                            backend: entry.backend
                        ))
                    }
                    guard let network = networkRuntime.backend,
                          let networkInterface = configuration.resolvedDevices?.networkInterface else {
                        throw VMError.invalidConfiguration(
                            "resolved RawHV topology requires its stable network function"
                        )
                    }
                    materialized.append(MaterializedVirtioBackend(
                        request: DoryRawHVVirtualDeviceRequest(
                            logicalID: try DoryVirtualDeviceID.derived(
                                namespace: .network,
                                stableID: networkInterface.id
                            ),
                            role: .network
                        ),
                        backend: network
                    ))
                    guard let topology = configuration.rawHVVirtualHardwareTopology else {
                        throw VMError.invalidConfiguration(
                            "resolved RawHV preflight lost its durable topology"
                        )
                    }
                    let assignments = try RawHVVirtualHardwareAttachmentPlan.assignments(
                        topology: topology,
                        materializedDevices: materialized.map(\.request)
                    )
                    guard assignments == preflightAssignments else {
                        throw VMError.invalidConfiguration(
                            "materialized RawHV assignments differ from preflight"
                        )
                    }
                    attachments = try assignments.map { assignment in
                        guard let materializedBackend = materialized.first(where: {
                            $0.request == assignment.request
                        }) else {
                            throw VMError.invalidConfiguration(
                                "authorized RawHV device has no materialized backend"
                            )
                        }
                        return (assignment.mmioSlot, materializedBackend.backend)
                    }
                } else {
                    attachments = backends.enumerated().map { ($0.offset, $0.element) }
                }

                for attachment in attachments {
                    let slot = attachment.slot
                    let backend = attachment.backend
                    let transport = try Self.attachBackend(
                        backend,
                        to: machine,
                        slot: slot
                    )
                    let audioMetrics: (@Sendable () -> DoryMacAudioRuntimeMetrics?)?
                    if let sound, backend === sound {
                        audioMetrics = { [weak audio] in audio?.runtimeMetrics }
                    } else {
                        audioMetrics = nil
                    }
                    let displayMetrics: (@Sendable () -> DesktopFrameMailboxMetrics?)?
                    if backend === gpu {
                        displayMetrics = { [mailboxes] in
                            mailboxes.map(\.metrics).reduce(
                                DesktopFrameMailboxMetrics(
                                    presentedFrames: 0,
                                    droppedFrames: 0,
                                    budgetRejectedFrames: 0
                                )
                            ) { partial, next in
                                DesktopFrameMailboxMetrics(
                                    presentedFrames: partial.presentedFrames.addingClamped(
                                        next.presentedFrames
                                    ),
                                    droppedFrames: partial.droppedFrames.addingClamped(
                                        next.droppedFrames
                                    ),
                                    budgetRejectedFrames:
                                        partial.budgetRejectedFrames.addingClamped(
                                            next.budgetRejectedFrames
                                        ),
                                    receivedFrameBytes: partial.receivedFrameBytes.addingClamped(
                                        next.receivedFrameBytes
                                    ),
                                    stagingCopyBytes: partial.stagingCopyBytes.addingClamped(
                                        next.stagingCopyBytes
                                    ),
                                    drainCopyBytes: partial.drainCopyBytes.addingClamped(
                                        next.drainCopyBytes
                                    ),
                                    uploadedFrameBytes: partial.uploadedFrameBytes.addingClamped(
                                        next.uploadedFrameBytes
                                    ),
                                    droppedFrameBytes: partial.droppedFrameBytes.addingClamped(
                                        next.droppedFrameBytes
                                    ),
                                    pendingFrameBytes: partial.pendingFrameBytes.addingClamped(
                                        next.pendingFrameBytes
                                    ),
                                    pendingFrameDepth: partial.pendingFrameDepth.addingClamped(
                                        next.pendingFrameDepth
                                    )
                                )
                            }
                        }
                    } else {
                        displayMetrics = nil
                    }
                    let presentationBudgetMetrics:
                        (@Sendable () -> DesktopCPUPresentationBudgetMetrics?)?
                    if backend === gpu {
                        presentationBudgetMetrics = { presentationBudget.metrics }
                    } else {
                        presentationBudgetMetrics = nil
                    }
                    deviceTelemetry.register(
                        slot: slot,
                        backend: backend,
                        transport: transport,
                        audioMetrics: audioMetrics,
                        displayMetrics: displayMetrics,
                        presentationBudgetMetrics: presentationBudgetMetrics
                    )
                    if backend === gpu, configuration.resolvedDevices?.dynamicDisplay != false {
                        for (index, display) in displays.enumerated() {
                            let scanoutID = UInt32(index)
                            display.onDrawableSizeChange = {
                                [weak gpu, weak transport] width, height in
                                guard let gpu, let transport else { return }
                                pointerTopology.update(
                                    scanoutID: scanoutID,
                                    width: width,
                                    height: height
                                )
                                gpu.updateScanoutSize(
                                    scanoutID: scanoutID,
                                    width: width,
                                    height: height,
                                    transport: transport
                                )
                            }
                        }
                    }
                }
                if let resolvedAssignments {
                    guard machine.attachedVirtioSlots.map(\.slot)
                            == resolvedAssignments.map(\.mmioSlot) else {
                        throw VMError.invalidConfiguration(
                            "materialized MMIO layout differs from the durable RawHV topology"
                        )
                    }
                }
                try machine.loadBootPayload()
            } catch {
                initializationRollback.performIfNeeded()
                throw error
            }

            self.agentBridge = GuestVsockSocketBridge(
                socketPath: configuration.agentSocketPath,
                guestPort: VsockPorts.agent,
                service: .agentSocket,
                log: Self.log
            )
            self.shellBridge = GuestVsockSocketBridge(
                socketPath: configuration.shellSocketPath,
                guestPort: 1027,
                service: .shell,
                log: Self.log
            )
            let rollbackAgentBridge = self.agentBridge
            let rollbackShellBridge = self.shellBridge
            initializationRollback.register {
                rollbackAgentBridge.stop()
                rollbackShellBridge.stop()
            }
            try agentBridge.attach(to: vsock)
            try shellBridge.attach(to: vsock)
            if let sshAgentSocketPath = configuration.sshAgentSocketPath {
                let bridge = try HostSSHAgentBridge(
                    socketPath: sshAgentSocketPath,
                    log: Self.log
                )
                initializationRollback.register { bridge.stop() }
                try bridge.attach(to: vsock)
                self.sshAgentBridge = bridge
            } else {
                self.sshAgentBridge = nil
            }
            if let clipboardPolicy = clipboardPlan.policy {
                let clipboardControl = DorydKit.AgentControl(configuration: .init(
                    directSocketPath: configuration.agentSocketPath
                ))
                let clipboardInput = self.keyboardInput
                self.clipboard = DoryDesktopClipboardCoordinator(
                    policy: clipboardPolicy,
                    execute: { argv, stdin, timeoutMs, outputLimitBytes in
                        try clipboardControl.execWithInput(
                            argv: argv,
                            stdin: stdin,
                            timeoutMs: timeoutMs,
                            outputLimitBytes: outputLimitBytes
                        )
                    },
                    sendShortcut: { keyCode in
                        clipboardInput.send(frame: [
                            VirtioInputEvent(type: 1, code: 125, value: 0),
                            VirtioInputEvent(type: 1, code: 126, value: 0),
                            VirtioInputEvent(type: 1, code: 29, value: 1),
                            VirtioInputEvent(type: 1, code: keyCode, value: 1),
                            VirtioInputEvent(type: 1, code: keyCode, value: 0),
                            VirtioInputEvent(type: 1, code: 29, value: 0),
                        ])
                    },
                    log: Self.log
                )
            } else {
                self.clipboard = nil
            }

            var windows = [NSWindow]()
            let displayAssignments = displayPlans.map {
                configuration.displayPresentation.assignment(forGuestDisplayID: $0.id)
            }
            for (index, plan) in displayPlans.enumerated() {
                let window = NSWindow(
                    contentRect: NSRect(origin: .zero, size: plan.windowSize),
                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                    backing: .buffered,
                    defer: false
                )
                window.title = displayPlans.count == 1
                    ? "\(configuration.machineID) — Dory Desktop"
                    : "\(configuration.machineID) — Dory Desktop — Display \(index + 1)"
                // Keep the Metal surface bound to the window's *actual* content layout. A
                // dedicated display can transiently remain a normal titled window while AppKit
                // enters its fullscreen Space. Installing a fixed-size display view directly as the
                // content view left its original 1920x1080 bounds clipped inside a 1920x1020
                // visible content area, so the framebuffer and absolute tablet normalized
                // different coordinate spaces. The AppKit-managed container always follows the
                // titlebar/fullscreen transition; constraints then make display pixels and input
                // use the same rectangle.
                let contentView = NSView(
                    frame: NSRect(origin: .zero, size: window.contentLayoutRect.size)
                )
                let display = displays[index]
                display.translatesAutoresizingMaskIntoConstraints = false
                contentView.addSubview(display)
                window.contentView = contentView
                NSLayoutConstraint.activate([
                    display.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                    display.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                    display.topAnchor.constraint(equalTo: contentView.topAnchor),
                    display.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                ])
                window.minSize = NSSize(width: 640, height: 400)
                window.collectionBehavior.insert(.fullScreenPrimary)
                window.tabbingMode = .disallowed
                window.center()
                if index > 0, let first = windows.first {
                    window.setFrameOrigin(NSPoint(
                        x: first.frame.minX + CGFloat(index * 36),
                        y: first.frame.minY - CGFloat(index * 36)
                    ))
                }
                windows.append(window)
            }
            self.windows = windows
            self.displayAssignments = displayAssignments
            super.init()
            for window in windows { window.delegate = self }
            for display in displays {
                display.onMacShortcut = { [weak clipboard] event in
                    clipboard?.handleMacShortcut(event) ?? false
                }
            }
            clipboard?.start()
            initializationRollback.commit()
        }

        func run() throws {
            defer {
                ensureGPUShutdownBeforeTeardown()
                cleanup()
            }
            try usbControlServer?.start()
            do {
                try lifecycleReceiptServer.start()
            } catch {
                usbControlServer?.stop()
                throw error
            }
            DoryDesktopApplicationIdentity.install(on: application)
            application.setActivationPolicy(.regular)
            application.delegate = self
            installApplicationMenu()
            installSignalHandlers()
            for window in windows { window.makeKeyAndOrderFront(nil) }
            application.activate()
            DesktopAppRunLoop.perform { [weak self] in
                guard let self else { return }
                for (window, assignment) in zip(self.windows, self.displayAssignments) {
                    _ = DoryHostDisplayPresentation.enterDedicatedFullscreen(
                        window: window,
                        assignment: assignment
                    )
                }
            }
            try startMachine()
            application.run()
            if let stopError { throw stopError }
        }

        private func installApplicationMenu() {
            let mainMenu = NSMenu()

            let applicationItem = NSMenuItem(title: "Dory Desktop", action: nil, keyEquivalent: "")
            let applicationMenu = NSMenu(title: "Dory Desktop")
            applicationMenu.addItem(
                withTitle: "Quit Dory Desktop",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
            applicationItem.submenu = applicationMenu
            mainMenu.addItem(applicationItem)

            let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
            let viewMenu = NSMenu(title: "View")
            let fullScreenItem = NSMenuItem(
                title: "Enter Full Screen",
                action: #selector(toggleFullScreen(_:)),
                keyEquivalent: "f"
            )
            fullScreenItem.keyEquivalentModifierMask = [.command, .control]
            fullScreenItem.target = self
            viewMenu.addItem(fullScreenItem)
            viewItem.submenu = viewMenu
            mainMenu.addItem(viewItem)

            application.mainMenu = mainMenu
        }

        func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
            for window in windows { window.makeKeyAndOrderFront(nil) }
            return true
        }

        func applicationDidChangeScreenParameters(_ notification: Notification) {
            for (window, assignment) in zip(windows, displayAssignments) {
                _ = DoryHostDisplayPresentation.recoverDisconnectedDisplay(
                    window: window,
                    assignment: assignment
                )
            }
        }

        @objc private func toggleFullScreen(_ sender: Any?) {
            (application.keyWindow ?? windows.first)?.toggleFullScreen(sender)
        }

        func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
            requestGuestShutdown()
            return .terminateCancel
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            sender.orderOut(nil)
            return false
        }

        func windowDidResignKey(_ notification: Notification) {
            guard let window = notification.object as? NSWindow,
                  let index = windows.firstIndex(of: window) else { return }
            displays[index].releasePressedInput()
        }

        func applicationDidResignActive(_ notification: Notification) {
            for display in displays { display.releasePressedInput() }
        }

        private func startMachine() throws {
            let machine = self.machine
            machineExecutionState = .running
            do {
                try machineRunner.start { [weak self] result in
                    DesktopAppRunLoop.perform {
                        switch result {
                        case .success(let reason):
                            self?.finish(
                                error: Self.error(for: reason),
                                machineExecutionEnded: true
                            )
                        case .failure(let error):
                            self?.finish(error: error, machineExecutionEnded: true)
                        }
                    }
                }
            } catch {
                machineExecutionState = .notStarted
                throw error
            }

            let configuration = self.configuration
            let graphicsDisplayName = graphicsBackend.displayName
            let firstFrame = self.firstFrame
            let cameraAttachment = self.cameraAttachment
            let guestFSEventBridge = self.guestFSEventBridge
            let filesystemWorker = self.filesystemWorker
            Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    if let guestFSEventBridge {
                        try await guestFSEventBridge.establishReadiness()
                        Self.log(
                            "dory-hv desktop: host-share watcher bridge ready on guest vsock:\(VsockPorts.fsevents)"
                        )
                    }
                    try filesystemWorker?.client.activateCoherence()
                    if filesystemWorker != nil {
                        Self.log("dory-hv desktop: host-share coherence delivery active")
                    }
                    if configuration.genericGuest {
                        try await DesktopGuestReadinessBoundary.complete(
                            genericGuest: true,
                            prepare: {
                                guard configuration.rendererWorkerLaunch != nil
                                        || firstFrame.wait(timeout: 90) else {
                                    throw VMError.bootFailure(
                                        "generic Linux guest did not publish a graphics frame within 90s"
                                    )
                                }
                                return try Self.prepareGenericGuestIntegration(
                                    configuration: configuration,
                                    timeout: 15
                                )
                            },
                            waitForSynchronizedPresentation: {
                                if let rendererWorkerLaunch =
                                    configuration.rendererWorkerLaunch {
                                    // Generic media has no Dory-owned display-manager barrier, so
                                    // retain the existing renderer-first readiness contract.
                                    try rendererWorkerLaunch
                                        .waitForFirstSynchronizedPresentation(timeout: 90)
                                }
                            },
                            publish: { integration in
                                switch integration {
                                case let .tools(info, shareState):
                                    DesktopAppRunLoop.perform { [weak self] in
                                        self?.clipboard?.markGuestReady()
                                    }
                                    try configuration.rendererWorkerLaunch?
                                        .claimSynchronizedPresentationForPublication()
                                    try VmmHandoffClient.send(
                                        path: configuration.handoffSocketPath,
                                        ready: VmmReadyMessage(
                                            machineID: configuration.machineID,
                                            operationID: DoryOperationIdentity.canonical(
                                                configuration.operationID
                                            ),
                                            agentBuild: info.agentBuild,
                                            agentProtocolVersion: info.protocolVersion,
                                            agentCapabilities: info.capabilities,
                                            agentSocketPath: configuration.agentSocketPath,
                                            shellSocketPath: configuration.shellSocketPath,
                                            controlSocketPath: configuration.controlSocketPath,
                                            graphicsSelection: self?.graphicsSelection,
                                            detail: "raw-HV generic Linux running with \(graphicsDisplayName) graphics and Dory Tools protocol \(info.protocolVersion)\(shareState.detailSuffix)"
                                        )
                                    )
                                case .unavailable:
                                    let shareState = GenericGuestShareReadiness
                                        .unavailableMissingTools(
                                            configuration.attachedShares.map(\.tag)
                                        )
                                    try configuration.rendererWorkerLaunch?
                                        .claimSynchronizedPresentationForPublication()
                                    try VmmHandoffClient.send(
                                        path: configuration.handoffSocketPath,
                                        ready: VmmReadyMessage(
                                            machineID: configuration.machineID,
                                            operationID: DoryOperationIdentity.canonical(
                                                configuration.operationID
                                            ),
                                            agentBuild: "dory-hv/generic-linux",
                                            controlSocketPath: configuration.controlSocketPath,
                                            graphicsSelection: self?.graphicsSelection,
                                            detail: "raw-HV generic Linux running with \(graphicsDisplayName) graphics; guest tools are not installed\(shareState.detailSuffix)"
                                        )
                                    )
                                }
                            },
                            activateOptionalCapabilities: { integration in
                                switch integration {
                                case .tools:
                                    _ = await cameraAttachment?.attachIfAvailable()
                                case .unavailable:
                                    _ = cameraAttachment?.unavailableWithoutGuestTools()
                                }
                            }
                        )
                        return
                    }
                    try await DesktopGuestReadinessBoundary.complete(
                        genericGuest: false,
                        prepare: {
                            // prepareGuest writes /var/lib/dory/host-configured. The managed
                            // display manager is deliberately blocked on that marker, so it must
                            // exist before a renderer-backed presentation can be required.
                            try Self.prepareGuest(configuration: configuration)
                        },
                        waitForSynchronizedPresentation: {
                            if let rendererWorkerLaunch =
                                configuration.rendererWorkerLaunch {
                                // The immutable receipt and kernel/fence authority select the
                                // candidate, but handoff still requires a real worker-backed frame
                                // across the producer-fence wait and Metal completion boundary.
                                try rendererWorkerLaunch
                                    .waitForFirstSynchronizedPresentation(timeout: 90)
                            }
                        },
                        publish: { info in
                            DesktopAppRunLoop.perform { [weak self] in
                                self?.clipboard?.markGuestReady()
                            }
                            try configuration.rendererWorkerLaunch?
                                .claimSynchronizedPresentationForPublication()
                            try VmmHandoffClient.send(
                                path: configuration.handoffSocketPath,
                                ready: VmmReadyMessage(
                                    machineID: configuration.machineID,
                                    operationID: DoryOperationIdentity.canonical(
                                        configuration.operationID
                                    ),
                                    agentBuild: info.agentBuild,
                                    agentProtocolVersion: info.protocolVersion,
                                    agentCapabilities: info.capabilities,
                                    agentSocketPath: configuration.agentSocketPath,
                                    shellSocketPath: configuration.shellSocketPath,
                                    controlSocketPath: configuration.controlSocketPath,
                                    graphicsSelection: self?.graphicsSelection,
                                    detail: "raw-HV desktop running with \(graphicsDisplayName) graphics; dory-agent answered protocol \(info.protocolVersion)"
                                )
                            )
                        },
                        activateOptionalCapabilities: { _ in
                            _ = await cameraAttachment?.attachIfAvailable()
                        }
                    )
                } catch {
                    configuration.rendererWorkerLaunch?.teardown(
                        reason: "desktop readiness failed: \(error)"
                    )
                    machine.requestStop(.crash("desktop readiness failed: \(error)"))
                    DesktopAppRunLoop.perform {
                        self?.finish(error: error)
                    }
                }
            }
        }

        private enum GenericGuestIntegration: Sendable {
            case tools(DoryAgentInfo, GenericGuestShareReadiness)
            case unavailable
        }

        private nonisolated static func prepareGenericGuestIntegration(
            configuration: Configuration,
            timeout: TimeInterval
        ) throws -> GenericGuestIntegration {
            let deadline = Date().addingTimeInterval(timeout)
            var lastToolsError: Error?
            repeat {
                let control = AgentControl(configuration: .init(
                    directSocketPath: configuration.agentSocketPath
                ))
                var toolsAnswered = false
                do {
                    defer { control.disconnect() }
                    let info = try control.info()
                    toolsAnswered = true
                    guard info.protocolVersion == DoryCore.protocolVersion() else {
                        throw AgentControlError.incompatibleProtocol(
                            expected: DoryCore.protocolVersion(),
                            actual: info.protocolVersion
                        )
                    }
                    guard info.capabilitiesAreCanonical else {
                        throw AgentControlError.invalidCapabilities
                    }
                    guard !configuration.attachedShares.isEmpty else {
                        return .tools(info, .mounted(0))
                    }
                    guard info.supports("virtiofs-mount", minimumVersion: 1) else {
                        return .tools(
                            info,
                            .unavailableMissingCapability(
                                configuration.attachedShares.map(\.tag)
                            )
                        )
                    }
                    for share in configuration.attachedShares {
                        _ = try control.virtioFSMount(
                            tag: share.tag,
                            mountPath: share.guestPath,
                            readOnly: share.readOnly
                        )
                    }
                    return .tools(info, .mounted(configuration.attachedShares.count))
                } catch {
                    if toolsAnswered {
                        // The typed operation is idempotent. A lost response can therefore retry
                        // until readiness expires without an Exec fallback or an extra mount layer.
                        lastToolsError = error
                    }
                }
                Thread.sleep(forTimeInterval: 0.25)
            } while Date() < deadline
            if let lastToolsError {
                throw VMError.bootFailure(
                    "generic Linux virtio-fs integration failed after Dory Tools answered: \(lastToolsError)"
                )
            }
            return .unavailable
        }

        private func requestGuestShutdown() {
            guard !stopping else { return }
            stopping = true
            for window in windows { window.orderOut(nil) }
            let machine = self.machine
            if ShutdownPlan(resolvedDevices: configuration.resolvedDevices) == .immediate {
                machine.requestStop(.powerOff)
                return
            }
            if configuration.genericGuest {
                // Linux maps KEY_POWER to logind's normal power-button action. This provides a
                // clean integration-free shutdown path until Dory guest tools are installed.
                keyboardInput.send(frame: [
                    VirtioInputEvent(type: 1, code: 116, value: 1),
                    VirtioInputEvent(type: 1, code: 116, value: 0),
                ])
            } else {
                do {
                    let control = AgentControl(configuration: .init(
                        directSocketPath: configuration.agentSocketPath
                    ))
                    defer { control.disconnect() }
                    try Self.requireSuccess(control.exec(
                        argv: ["/bin/sh", "-c", GuestShutdownCommand.detachedDesktopRequest()],
                        timeoutMs: 5_000,
                        outputLimitBytes: 64 * 1024
                    ), operation: "desktop guest shutdown request")
                } catch {
                    Self.log("dory-hv desktop: graceful guest shutdown request failed: \(error)")
                }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + DoryEngineShutdownTiming.helperWatchdogSeconds
            ) {
                machine.requestStop(.crash("guest shutdown timed out"))
            }
        }

        private func finish(error: Error?, machineExecutionEnded: Bool = false) {
            if machineExecutionEnded {
                machineExecutionState = .ended
            }
            if stopError == nil {
                stopError = rendererRuntimeFailureLatch?.failure ?? error
            }
            let receipt = beginGPUShutdownIfNeeded()
            guard !gpuShutdownWaitScheduled else {
                stopApplicationAfterGPUShutdown()
                return
            }
            gpuShutdownWaitScheduled = true
            DispatchQueue.global(qos: .userInitiated).async { [weak self, receipt] in
                let result = DesktopGPUShutdownBoundary.wait(for: receipt)
                DesktopAppRunLoop.perform { [weak self] in
                    guard let self else { return }
                    self.recordGPUShutdownResult(result)
                    self.stopApplicationAfterGPUShutdown()
                }
            }
        }

        private func beginGPUShutdownIfNeeded() -> VirtioGPUQuiescence {
            if let gpuShutdownReceipt { return gpuShutdownReceipt }
            let receipt = DesktopGPUShutdownBoundary.begin(
                quiesce: { gpu.quiesce(reason: .shutdown) },
                detachPresentations: {
                    for mailbox in mailboxes { mailbox.deliver() }
                }
            )
            gpuShutdownReceipt = receipt
            Self.log(
                "dory-hv desktop: waiting for GPU shutdown quiescence at epoch \(receipt.epoch)"
            )
            return receipt
        }

        private func ensureGPUShutdownBeforeTeardown() {
            guard gpuShutdownResult == nil else { return }
            let receipt = beginGPUShutdownIfNeeded()
            // This is the setup-failure and abnormal-run-loop fallback. A final main-actor drain
            // makes every release acknowledgement visible before the bounded synchronous wait.
            for mailbox in mailboxes { mailbox.deliver() }
            recordGPUShutdownResult(DesktopGPUShutdownBoundary.wait(for: receipt))
        }

        private func recordGPUShutdownResult(_ result: DesktopGPUShutdownBoundaryResult) {
            guard gpuShutdownResult == nil else { return }
            gpuShutdownResult = result
            Self.log("dory-hv desktop: GPU shutdown quiescence \(result.logDescription)")
            if stopError == nil {
                stopError = desktopGPUShutdownFailure(
                    result,
                    rendererFailureLatch: rendererRuntimeFailureLatch
                )
            }
        }

        private func stopApplicationAfterGPUShutdown() {
            guard machineExecutionState.isTerminalBoundary, gpuShutdownResult != nil else {
                return
            }
            application.stop(nil)
            if let wakeEvent = NSEvent.otherEvent(
                with: .applicationDefined,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 0,
                data1: 0,
                data2: 0
            ) {
                application.postEvent(wakeEvent, atStart: false)
            }
        }

        private func cleanup() {
            if machineExecutionState == .running {
                machine.requestStop(.crash("AppKit run loop ended before guest execution"))
            }
            if machineExecutionState != .notStarted {
                do {
                    _ = try machineRunner.wait()
                } catch {
                    Self.log("dory-hv desktop: machine owner-thread join failed: \(error)")
                    if stopError == nil { stopError = error }
                }
                machineExecutionState = .ended
            }
            filesystemWorker?.client.close()
            filesystemWorker = nil
            hostShareCoherence = nil
            lifecycleReceiptServer.stop()
            #if arch(arm64)
            serialConsoleInput.stop()
            #endif
            usbControlServer?.stop()
            precondition(
                machineExecutionState.isTerminalBoundary,
                "desktop USB authority cannot retire while Machine.run() is executing"
            )
            // application.run() is stopped only by finish(), which is published after Machine.run()
            // returns. The guest is therefore terminal before physical USB authority is released.
            switch usbipManager.stopAfterGuestExecutionEnded() {
            case .completed:
                break
            case .authorityRetained(let busIDs):
                let detail = busIDs.isEmpty
                    ? "pending listener, bridge, or device drain"
                    : "claims: \(busIDs.joined(separator: ", "))"
                Self.log(
                    "dory-hv desktop: USB/IP terminal retirement retained authority asynchronously (\(detail))"
                )
            }
            clipboard?.stop()
            agentBridge.stop()
            shellBridge.stop()
            sshAgentBridge?.stop()
            _ = vsock.quiesce()
            resolvedPortForwardReconciler?.stop()
            signalSources.forEach { $0.cancel() }
            signalSources.removeAll()
            if let gvproxy {
                ChildProcessTerminator.terminateAndReap(gvproxy)
            }
            for path in networkSocketPaths { unlink(path) }
            let serialReceipt = serialOutput.stop()
            if !serialReceipt.isClean {
                Self.log(
                    "dory-hv desktop: serial publisher retired with faults: "
                        + serialReceipt.diagnosticSummary
                )
            }
            try? serialLog.close()
        }

        private func installSignalHandlers() {
            for number in [SIGTERM, SIGINT] {
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(
                    signal: number,
                    queue: signalQueue
                )
                source.setEventHandler(handler: DesktopSignalEventRelay.makeHandler {
                    [weak self] in self?.requestGuestShutdown()
                })
                source.resume()
                signalSources.append(source)
            }

            // dory-hv is a command-line helper rather than an app bundle, so LaunchServices cannot
            // reliably activate it from Dory.app. Give the UI a narrow same-user signal that asks
            // the helper itself to raise its hidden or covered display window.
            signal(SIGUSR1, SIG_IGN)
            let raiseSource = DispatchSource.makeSignalSource(
                signal: SIGUSR1,
                queue: signalQueue
            )
            raiseSource.setEventHandler(handler: DesktopSignalEventRelay.makeHandler {
                [weak self] in
                guard let self else { return }
                for window in self.windows { window.makeKeyAndOrderFront(nil) }
                self.windows.first?.makeKey()
                self.application.activate()
            })
            raiseSource.resume()
            signalSources.append(raiseSource)
        }

        private nonisolated static func prepareGuest(configuration: Configuration) throws -> DoryAgentInfo {
            let deadline = Date().addingTimeInterval(90)
            var lastError: Error?
            while Date() < deadline {
                do {
                    let control = AgentControl(configuration: .init(
                        directSocketPath: configuration.agentSocketPath
                    ))
                    let info = try control.info()
                    let operationToken = DoryOperationIdentity.canonical(
                        configuration.operationID
                    )
                    try requireSuccess(control.exec(
                        argv: [
                            "/bin/sh", "-c",
                            "mkdir -p /run/dory && chmod 700 /run/dory && umask 077 && printf '%s\\n' \"$DORY_OPERATION_ID\" > /run/dory/operation-id",
                        ],
                        env: [DoryExecEnvironment(
                            key: "DORY_OPERATION_ID",
                            value: operationToken
                        )],
                        timeoutMs: 10_000,
                        outputLimitBytes: 16 * 1_024
                    ), operation: "bind lifecycle operation")
                    if let display = configuration.resolvedDevices?.display {
                        guard let command = DoryVMMGuestDisplayScale.persistenceCommand(
                            scaleFactor: display.guestUIScaleFactor
                        ) else {
                            throw VMError.bootFailure(
                                "resolved guest UI scale is not supported by Dory Tools"
                            )
                        }
                        try requireSuccess(control.exec(
                            argv: command,
                            timeoutMs: 10_000,
                            outputLimitBytes: 64 * 1_024
                        ), operation: "persist guest UI scale")
                    }
                    var guestEnvironment = configuration.environment
                    guestEnvironment["DORY_OPERATION_ID"] = operationToken
                    try requireSuccess(control.exec(
                        argv: ["/usr/lib/dory/configure-machine"],
                        env: guestEnvironment.sorted(by: { $0.key < $1.key }).map {
                            DoryExecEnvironment(key: $0.key, value: $0.value)
                        },
                        timeoutMs: 30_000,
                        outputLimitBytes: 64 * 1024
                    ), operation: "guest account configuration")
                    for share in configuration.attachedShares {
                        _ = try control.virtioFSMount(
                            tag: share.tag,
                            mountPath: share.guestPath,
                            readOnly: share.readOnly
                        )
                    }
                    try requireSuccess(control.exec(
                        argv: ["/usr/bin/touch", "/var/lib/dory/host-configured"],
                        timeoutMs: 10_000,
                        outputLimitBytes: 64 * 1024
                    ), operation: "complete desktop configuration")
                    return info
                } catch {
                    lastError = error
                    Thread.sleep(forTimeInterval: 0.25)
                }
            }
            throw lastError ?? VMError.bootFailure("desktop agent did not become ready")
        }

        private nonisolated static func requireSuccess(_ result: DoryExecResult, operation: String) throws {
            guard !result.timedOut, result.exitCode == 0 else {
                let stderr = String(decoding: result.stderr.prefix(4_096), as: UTF8.self)
                throw VMError.bootFailure(
                    "\(operation) failed (exit=\(result.exitCode), timedOut=\(result.timedOut)): \(stderr)"
                )
            }
        }

        private static func waitForSocket(path: String, process: Process) throws {
            for _ in 0..<100 {
                if FileManager.default.fileExists(atPath: path) { return }
                guard process.isRunning else {
                    throw VMError.bootFailure("gvproxy exited before publishing its network socket")
                }
                usleep(50_000)
            }
            throw VMError.bootFailure("gvproxy did not publish its network socket")
        }

        private struct NetworkRuntime {
            let process: Process?
            let socketPaths: [String]
            let backend: (any VirtioDeviceBackend)?
            let portForwardReconciler: ResolvedPortForwardReconciler?
        }

        private static func prepareNetwork(
            plan: NetworkPlan,
            networkInterface: DoryVirtualMachineNetworkInterfaceCapabilityRequest?,
            gvproxyPath: String,
            runtimeDirectory: String,
            token: String,
            resolvedPortForwards: [DoryVMPortForward]?
        ) throws -> NetworkRuntime {
            guard resolvedPortForwards == nil || networkInterface != nil else {
                throw VMError.bootFailure(
                    "resolved port forwards require an exact resolved network device contract"
                )
            }
            let portIntents = resolvedPortForwards ?? []
            guard let portForwards = PublishedPortForwardPlan.resolvedForwards(
                portIntents,
                guestIP: "192.168.127.2"
            ) else {
                throw VMError.bootFailure("resolved port-forward contract is invalid")
            }
            if !portIntents.isEmpty, plan == .disconnected {
                throw VMError.bootFailure("disconnected networking cannot publish host ports")
            }
            if plan != .sharedNAT,
               portIntents.contains(where: { $0.exposure == .lan }) {
                throw VMError.bootFailure("LAN port exposure requires shared NAT")
            }
            let resolvedMTU = networkInterface?.maximumTransmissionUnit
                ?? UInt16(DoryNetworkMTU.resolved())
            if plan == .disconnected {
                let mac = networkInterface?.macAddressOctets ?? VirtioNet.guestMAC
                return NetworkRuntime(
                    process: nil,
                    socketPaths: [],
                    backend: VirtioDisconnectedNet(
                        macAddress: mac,
                        maximumTransmissionUnit: resolvedMTU
                    ),
                    portForwardReconciler: nil
                )
            }
            guard plan.startsGVProxy, plan.attachesNetworkDevice else {
                return NetworkRuntime(
                    process: nil,
                    socketPaths: [],
                    backend: nil,
                    portForwardReconciler: nil
                )
            }
            let gvproxySocket = "\(runtimeDirectory)/\(token)-gv.sock"
            let vmNetworkSocket = "\(runtimeDirectory)/\(token)-vm.sock"
            let apiSocket = "\(runtimeDirectory)/\(token)-api.sock"
            let configurationYAML: String?
            if let networkInterface {
                configurationYAML = GVProxyDesktopLaunchPlan.configurationYAML(
                    hostOnly: plan == .hostOnly,
                    guestMAC: networkInterface.macAddress
                )
            } else {
                configurationYAML = plan.gvproxyConfigurationYAML
            }
            let configurationPath = configurationYAML.map { _ in
                "\(runtimeDirectory)/\(token)-network.yaml"
            }
            let socketPaths = [gvproxySocket, vmNetworkSocket, apiSocket]
                + [configurationPath].compactMap { $0 }
            for path in socketPaths { unlink(path) }
            if let configurationPath, let yaml = configurationYAML {
                try yaml.write(toFile: configurationPath, atomically: true, encoding: .utf8)
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: gvproxyPath)
            process.arguments = GVProxyDesktopLaunchPlan.arguments(
                mtu: Int(resolvedMTU),
                datapathSocket: gvproxySocket,
                apiSocket: apiSocket,
                configurationPath: configurationPath
            )
            process.standardOutput = FileHandle.standardError
            process.standardError = FileHandle.standardError
            do {
                try process.run()
                try waitForSocket(path: gvproxySocket, process: process)
                try publishResolvedPortForwards(portForwards, apiSocket: apiSocket)
                let reconciler = portForwards.isEmpty ? nil : ResolvedPortForwardReconciler(
                    desired: portForwards,
                    apiSocketPath: apiSocket,
                    log: Self.log
                )
                if let reconciler, !reconciler.reconcileNow() {
                    throw VMError.bootFailure(
                        "could not verify the resolved gvproxy port-forward registry"
                    )
                }
                reconciler?.start()
                return NetworkRuntime(
                    process: process,
                    socketPaths: socketPaths,
                    backend: try VirtioNet(
                        socketPath: vmNetworkSocket,
                        remotePath: gvproxySocket,
                        macAddress: networkInterface?.macAddressOctets ?? VirtioNet.guestMAC,
                        maximumTransmissionUnit: resolvedMTU
                    ),
                    portForwardReconciler: reconciler
                )
            } catch {
                ChildProcessTerminator.terminateAndReap(process)
                for path in socketPaths { unlink(path) }
                throw error
            }
        }

        private static func publishResolvedPortForwards(
            _ forwards: Set<PublishedPortForward>,
            apiSocket: String
        ) throws {
            for forward in forwards.sorted(by: portForwardOrder) {
                let bodyData = try JSONSerialization.data(withJSONObject: [
                    "local": forward.localEndpoint,
                    "remote": forward.remoteEndpoint,
                    "protocol": forward.protocol.rawValue,
                ])
                guard let body = String(data: bodyData, encoding: .utf8) else {
                    throw VMError.bootFailure("could not encode resolved gvproxy forward")
                }
                var published = false
                for _ in 0..<100 {
                    let curl = Process()
                    curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                    curl.arguments = [
                        "--fail", "--silent", "--show-error",
                        "--connect-timeout", "1", "--max-time", "1",
                        "--unix-socket", apiSocket,
                        "--request", "POST",
                        "--data-binary", body,
                        "http://gvproxy/services/forwarder/expose",
                    ]
                    curl.standardOutput = FileHandle.nullDevice
                    curl.standardError = FileHandle.nullDevice
                    if (try? curl.run()) != nil {
                        curl.waitUntilExit()
                        if curl.terminationStatus == 0 {
                            published = true
                            break
                        }
                    }
                    usleep(20_000)
                }
                guard published else {
                    throw VMError.bootFailure(
                        "gvproxy could not publish \(forward.localEndpoint)/\(forward.protocol.rawValue)"
                    )
                }
            }
        }

        private static func portForwardOrder(
            _ lhs: PublishedPortForward,
            _ rhs: PublishedPortForward
        ) -> Bool {
            if lhs.protocol != rhs.protocol {
                return lhs.protocol.rawValue < rhs.protocol.rawValue
            }
            if lhs.localHost != rhs.localHost { return lhs.localHost < rhs.localHost }
            return lhs.localPort < rhs.localPort
        }

        private static func singletonMaterialization(
            role: DoryVirtualDeviceRole,
            authorizedDevices: [DoryRawHVVirtualDeviceRequest],
            backend: any VirtioDeviceBackend
        ) throws -> MaterializedVirtioBackend {
            let matches = authorizedDevices.filter { $0.role == role }
            guard matches.count == 1, let request = matches.first else {
                throw VMError.invalidConfiguration(
                    "authorized RawHV materialization requires exactly one \(role.rawValue) function"
                )
            }
            return MaterializedVirtioBackend(
                request: request,
                backend: backend
            )
        }

        @discardableResult
        private static func attachBackend(
            _ backend: any VirtioDeviceBackend,
            to machine: Machine,
            slot: Int
        ) throws -> VirtioMMIOTransport {
            let interrupt = GuestLayout.virtioFirstIRQ + UInt32(slot)
            let transport = VirtioMMIOTransport(
                baseAddress: GuestLayout.virtioBase + UInt64(slot) * GuestLayout.virtioSlotSize,
                backend: backend,
                memory: machine.memory
            ) { [weak machine] in
                machine?.raiseGSI(interrupt)
            }
            try machine.attachVirtioSlot(transport, at: slot)
            return transport
        }

        #if arch(arm64)
        private static func attachPlatformDevices(
            to machine: Machine,
            serialOutput: BoundedSerialConsolePublisher
        ) -> PL011 {
            machine.bus.attach(PL031(baseAddress: GuestLayout.rtcBase))
            let uart = PL011(
                baseAddress: GuestLayout.uartBase,
                sink: { byte in
                    serialOutput.enqueue(byte)
                },
                setInterrupt: { [weak machine] asserted in
                    machine?.setGSI(GuestLayout.uartIRQ, asserted: asserted)
                }
            )
            machine.attachConsole(uart)
            return uart
        }
        #endif

        private static func resolveGraphics(
            legacyBackend: DoryDesktopGraphicsBackend?,
            exactLevel: DoryGraphicsAccelerationLevel?,
            rendererWorkerLaunch: DesktopRendererWorkerLaunch?
        ) throws -> ResolvedGraphics {
            if let exactLevel {
                guard legacyBackend == nil else {
                    throw VMError.bootFailure(
                        "resolved graphics cannot coexist with a legacy graphics selection"
                    )
                }
                switch exactLevel {
                case .hardwareAccelerated3D:
                    guard let rendererWorkerLaunch else {
                        throw VMError.bootFailure(
                            "resolved Venus launch is missing its authenticated renderer worker"
                        )
                    }
                    return ResolvedGraphics(
                        backend: .virglVenus,
                        rendererWorkerLaunch: rendererWorkerLaunch
                    )
                case .hostAcceleratedDisplay:
                    guard rendererWorkerLaunch == nil else {
                        throw VMError.bootFailure(
                            "host-display graphics cannot carry renderer-worker authority"
                        )
                    }
                    throw VMError.bootFailure(
                        "resolved host-accelerated display is not implemented by the RawHV Metal display contract"
                    )
                case .software:
                    guard rendererWorkerLaunch == nil else {
                        throw VMError.bootFailure(
                            "software graphics cannot carry renderer-worker authority"
                        )
                    }
                    return ResolvedGraphics(
                        backend: .software,
                        rendererWorkerLaunch: nil
                    )
                case .none:
                    throw VMError.bootFailure(
                        "raw-HV desktop cannot satisfy a no-graphics resolved plan"
                    )
                }
            }

            guard let legacyBackend else {
                throw VMError.bootFailure("desktop launch is missing typed graphics authority")
            }
            guard rendererWorkerLaunch == nil else {
                throw VMError.bootFailure(
                    "legacy graphics cannot carry renderer-worker authority"
                )
            }
            switch legacyBackend {
            case .virgl:
                throw VMError.bootFailure(
                    "legacy in-process VirGL desktop presentation was removed; "
                        + "launch with a resolved signed renderer worker or select software graphics"
                )
            case .software:
                return ResolvedGraphics(
                    backend: .software,
                    rendererWorkerLaunch: nil
                )
            case .virglVenus:
                throw VMError.bootFailure(
                    "legacy in-process VirGL2 + Venus desktop presentation was removed; "
                        + "launch with a resolved signed renderer worker or select software graphics"
                )
            }
        }

        private static func graphicsSelection(
            configuration: Configuration,
            resolvedBackend: DoryDesktopGraphicsBackend,
            rendererWorkerLaunch: DesktopRendererWorkerLaunch?
        ) throws -> DoryRuntimeGraphicsSelection? {
            guard let exactLevel = configuration.resolvedGraphics else {
                // Legacy software compatibility launches have no immutable plan generation. Their
                // display can remain available for migration, but never becomes resolved evidence.
                return nil
            }
            guard let planSHA256 = configuration.resolvedPlanSHA256,
                  let planRevision = configuration.resolvedPlanRevision,
                  planRevision > 0 else {
                throw VMError.bootFailure(
                    "resolved graphics selection is missing plan-generation authority"
                )
            }
            let selection: DoryRuntimeGraphicsSelection
            switch (exactLevel, resolvedBackend, rendererWorkerLaunch) {
            case (.software, .software, nil):
                selection = DoryRuntimeGraphicsSelection.resolvedSoftware(
                    operationID: configuration.operationID,
                    resolvedPlanSHA256: planSHA256,
                    planRevision: planRevision
                )
            case let (.hardwareAccelerated3D, .virglVenus, launch?):
                selection = DoryRuntimeGraphicsSelection(
                    operationID: DoryOperationIdentity.canonical(
                        configuration.operationID
                    ),
                    resolvedPlanSHA256: planSHA256,
                    planRevision: planRevision,
                    accelerationLevel: .hardwareAccelerated3D,
                    backend: .virglVenus,
                    rendererGeneration: launch.workerGeneration.rawValue,
                    rendererWorkerReceiptSHA256:
                        launch.rendererWorkerReceiptSHA256,
                    guestProducerFenceProofSHA256:
                        launch.qualifiedProducerFenceAuthoritySHA256
                )
            default:
                throw VMError.bootFailure(
                    "resolved graphics selection lacks its exact renderer authority"
                )
            }
            guard selection.isValid else {
                throw VMError.bootFailure("resolved software graphics selection is invalid")
            }
            return selection
        }

        private static func kernelCommandLine(
            machineID: String,
            operationID: UUID,
            rootDevice: String,
            graphicsBackend: DoryDesktopGraphicsBackend,
            genericGuest: Bool
        ) -> String {
            var arguments = [
                "console=ttyAMA0",
                "earlycon=pl011,mmio32,0x0c000000",
                "root=\(rootDevice)",
                "rw",
                "rootwait",
                "panic=1",
                "dory.machine_id=\(machineID)",
                "dory.operation_id=\(DoryOperationIdentity.canonical(operationID))",
                graphicsBackend.kernelArgument,
            ]
            if genericGuest {
                // Installer initramfs images commonly default to their live-media boot path
                // (Ubuntu's casper is one example). The same kernel/initramfs can boot the
                // installed root directly when the local-root path is selected explicitly.
                arguments.append("boot=local")
                // Direct-kernel boot does not consume the EFI System Partition. Installer
                // kernels can omit optional FAT/NLS modules that a distro's installed fstab
                // expects for /boot/efi, so keep that nonessential mount out of the boot
                // transaction without modifying the guest filesystem.
                arguments.append("systemd.mask=boot-efi.mount")
            }
            return arguments.joined(separator: " ")
        }

        private static func openAppendLog(_ path: String) throws -> FileHandle {
            if !FileManager.default.fileExists(atPath: path) {
                guard FileManager.default.createFile(atPath: path, contents: nil) else {
                    throw VMError.bootFailure("could not create serial log: \(path)")
                }
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            }
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            try handle.seekToEnd()
            return handle
        }

        private static func appendBootSessionMarker(
            to log: FileHandle,
            machineID: String,
            operationID: UUID
        ) throws {
            let marker = "\n--- DORY BOOT \(Date().formatted(.iso8601)) machine=\(machineID) operation=\(DoryOperationIdentity.canonical(operationID)) runtime=raw-hv-desktop ---\n"
            try log.write(contentsOf: Data(marker.utf8))
            try log.synchronize()
        }

        private static func error(for reason: GuestStopReason) -> Error? {
            switch reason {
            case .powerOff: nil
            case .reset: VMError.unexpectedExit("desktop guest requested reset")
            case let .crash(detail): VMError.unexpectedExit(detail)
            }
        }

        private nonisolated static func log(_ message: String) {
            FileHandle.standardError.write(Data("dory-hv desktop: \(message)\n".utf8))
        }
    }
}

private final class FirstFrameGate: @unchecked Sendable {
    private let condition = NSCondition()
    private let requiredScanoutCount: Int
    private var readyScanoutIDs = Set<UInt32>()

    init(requiredScanoutCount: Int = 1) {
        self.requiredScanoutCount = max(1, requiredScanoutCount)
    }

    func signal(scanoutID: UInt32 = 0) {
        condition.lock()
        readyScanoutIDs.insert(scanoutID)
        condition.broadcast()
        condition.unlock()
    }

    func wait(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        while readyScanoutIDs.count < requiredScanoutCount {
            if !condition.wait(until: deadline) { break }
        }
        let result = readyScanoutIDs.count >= requiredScanoutCount
        condition.unlock()
        return result
    }
}

private extension UInt64 {
    func addingClamped(_ other: UInt64) -> UInt64 {
        let (result, overflow) = addingReportingOverflow(other)
        return overflow ? .max : result
    }
}
