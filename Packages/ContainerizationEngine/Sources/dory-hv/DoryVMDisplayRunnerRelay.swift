import Darwin
import DoryHV
import DoryRendererWorkerWireContracts
import DoryVMDisplayWireContracts
import Foundation
import Metal

protocol DoryVMDisplayRunnerTransport: AnyObject, Sendable {
    func publishFrame(
        _ frame: Data,
        descriptors: [FileHandle],
        sharedTextureHandle: MTLSharedTextureHandle?,
        reply: @escaping @Sendable (Bool, UInt64, String) -> Void
    )
    func publishCursor(
        _ cursor: Data,
        reply: @escaping @Sendable (Bool, String) -> Void
    )
    func nextCommand(
        machineID: String,
        operationID: String,
        afterSequence: UInt64,
        reply: @escaping @Sendable (Bool, Data, String) -> Void
    )
    func acknowledgeCommand(
        machineID: String,
        operationID: String,
        sequence: UInt64,
        applied: Bool,
        detail: String,
        reply: @escaping @Sendable (Bool, String) -> Void
    )
    func retireRunner(
        machineID: String,
        operationID: String,
        reply: @escaping @Sendable (Bool, String) -> Void
    )
    func retireCPUFrames(
        machineID: String,
        operationID: String,
        reply: @escaping @Sendable (Bool, String) -> Void
    )
    func retireCPUResource(
        machineID: String,
        operationID: String,
        resourceID: UInt32,
        throughGeneration: UInt64,
        reply: @escaping @Sendable (Bool, String) -> Void
    )
    func invalidate()
}

final class DoryVMDisplayRunnerXPCTransport: DoryVMDisplayRunnerTransport,
    @unchecked Sendable
{
    private let connection: NSXPCConnection

    init(
        serviceName: String,
        invalidationHandler: @escaping @Sendable () -> Void
    ) {
        let connection = NSXPCConnection(machServiceName: serviceName, options: [])
        connection.remoteObjectInterface = DoryVMDisplayBrokerXPCInterface.make()
        connection.interruptionHandler = invalidationHandler
        connection.invalidationHandler = invalidationHandler
        self.connection = connection
        connection.resume()
    }

    func publishFrame(
        _ frame: Data,
        descriptors: [FileHandle],
        sharedTextureHandle: MTLSharedTextureHandle?,
        reply: @escaping @Sendable (Bool, UInt64, String) -> Void
    ) {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            reply(false, 0, "display-broker-error: \(error)")
        }) as? DoryVMDisplayBrokerXPCProtocol else {
            reply(false, 0, "display-broker-proxy-unavailable")
            return
        }
        proxy.publishFrame(
            frame,
            descriptors: descriptors,
            sharedTextureHandle: sharedTextureHandle,
            withReply: reply
        )
    }

    func publishCursor(
        _ cursor: Data,
        reply: @escaping @Sendable (Bool, String) -> Void
    ) {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            reply(false, "display-broker-error: \(error)")
        }) as? DoryVMDisplayBrokerXPCProtocol else {
            reply(false, "display-broker-proxy-unavailable")
            return
        }
        proxy.publishCursor(cursor, withReply: reply)
    }

    func nextCommand(
        machineID: String,
        operationID: String,
        afterSequence: UInt64,
        reply: @escaping @Sendable (Bool, Data, String) -> Void
    ) {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            reply(false, Data(), "display-broker-error: \(error)")
        }) as? DoryVMDisplayBrokerXPCProtocol else {
            reply(false, Data(), "display-broker-proxy-unavailable")
            return
        }
        proxy.nextCommand(
            machineID,
            operationID: operationID,
            afterSequence: afterSequence,
            withReply: reply
        )
    }

    func acknowledgeCommand(
        machineID: String,
        operationID: String,
        sequence: UInt64,
        applied: Bool,
        detail: String,
        reply: @escaping @Sendable (Bool, String) -> Void
    ) {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            reply(false, "display-broker-error: \(error)")
        }) as? DoryVMDisplayBrokerXPCProtocol else {
            reply(false, "display-broker-proxy-unavailable")
            return
        }
        proxy.acknowledgeCommand(
            machineID,
            operationID: operationID,
            sequence: sequence,
            applied: applied,
            detail: detail,
            withReply: reply
        )
    }

    func retireRunner(
        machineID: String,
        operationID: String,
        reply: @escaping @Sendable (Bool, String) -> Void
    ) {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            reply(false, "display-broker-error: \(error)")
        }) as? DoryVMDisplayBrokerXPCProtocol else {
            reply(false, "display-broker-proxy-unavailable")
            return
        }
        proxy.retireRunner(machineID, operationID: operationID, withReply: reply)
    }

    func retireCPUFrames(
        machineID: String,
        operationID: String,
        reply: @escaping @Sendable (Bool, String) -> Void
    ) {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            reply(false, "display-broker-error: \(error)")
        }) as? DoryVMDisplayBrokerXPCProtocol else {
            reply(false, "display-broker-proxy-unavailable")
            return
        }
        proxy.retireCPUFrames(machineID, operationID: operationID, withReply: reply)
    }

    func retireCPUResource(
        machineID: String,
        operationID: String,
        resourceID: UInt32,
        throughGeneration: UInt64,
        reply: @escaping @Sendable (Bool, String) -> Void
    ) {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            reply(false, "display-broker-error: \(error)")
        }) as? DoryVMDisplayBrokerXPCProtocol else {
            reply(false, "display-broker-proxy-unavailable")
            return
        }
        proxy.retireCPUResource(
            machineID,
            operationID: operationID,
            resourceID: resourceID,
            throughGeneration: throughGeneration,
            withReply: reply
        )
    }

    func invalidate() {
        connection.invalidate()
    }
}

struct DoryVMDisplayRunnerCommandHandler: Sendable {
    var input: @Sendable (DoryVMDisplayInputEndpoint, [VirtioInputEvent]) -> Bool
    var resize: @Sendable (
        UInt32,
        UInt32,
        UInt32,
        UInt16,
        UInt16
    ) -> Bool
    var topology: @Sendable ([DoryVMDisplayTopologyEntry]) -> Bool = { _ in false }
    var restartGraphics: @Sendable () -> Bool = { false }
    var focus: @Sendable (UUID, Bool, UInt64?) -> Bool = { _, _, _ in false }
    var revokeFocus: @Sendable () -> Void = {}
    /// Durable device-owned reconciliation, not a best-effort ordinary input packet. Production
    /// handlers retain release debt even if the guest has exhausted its receive queue.
    var releaseInput: @Sendable () -> Void = {}

    @discardableResult
    func apply(_ command: DoryVMDisplayCommand) -> Bool {
        switch command.kind {
        case .input:
            guard let endpoint = command.inputEndpoint else { return false }
            return input(
                endpoint,
                command.inputEvents.map {
                    VirtioInputEvent(type: $0.type, code: $0.code, value: $0.value)
                }
            )
        case .resize:
            guard let scanoutID = command.scanoutID,
                  let width = command.width,
                  let height = command.height,
                  let physicalWidth = command.physicalWidthMillimeters,
                  let physicalHeight = command.physicalHeightMillimeters else { return false }
            return resize(scanoutID, width, height, physicalWidth, physicalHeight)
        case .topology:
            guard let displays = command.topology else { return false }
            return topology(displays)
        case .restartGraphics:
            return restartGraphics()
        case .focus:
            guard let lease = command.focusLeaseID.flatMap(UUID.init(uuidString:)),
                  let focused = command.focused else { return false }
            return focus(lease, focused, command.focusExpiresAtUptimeNanoseconds)
        }
    }
}

final class DoryVMDisplayRunnerRelaySlot: @unchecked Sendable {
    private let lock = NSLock()
    private var relay: DoryVMDisplayRunnerRelay?

    func install(_ relay: DoryVMDisplayRunnerRelay) {
        let accepted = lock.withLock { () -> Bool in
            guard self.relay == nil else { return false }
            self.relay = relay
            return true
        }
        precondition(accepted, "display relay may only be installed once")
    }

    func publish(_ update: VirtioGPUMetalScanoutUpdate) {
        guard let relay = lock.withLock({ relay }) else {
            update.rejectHostSubmission()
            update.presentation.discardWithoutPresentation()
            return
        }
        relay.publish(update)
    }

    @discardableResult
    func publish(_ update: DoryPCVirGLScanoutUpdate) -> Bool {
        guard let relay = lock.withLock({ relay }) else {
            update.retire()
            return false
        }
        return relay.publish(update)
    }

    func publish(_ frame: VirtioGPUScanoutFrame) {
        lock.withLock { relay }?.publish(frame)
    }

    func resetCPUFrames() -> Bool {
        lock.withLock { relay }?.resetCPUFrames() ?? true
    }

    func retireCPUResource(resourceID: UInt32, throughGeneration: UInt64) -> Bool {
        lock.withLock { relay }?.retireCPUResource(
            resourceID: resourceID,
            throughGeneration: throughGeneration
        ) ?? true
    }

    func canPublishCPUFrame(scanoutID: UInt32) -> Bool {
        lock.withLock { relay }?.canPublishCPUFrame(scanoutID: scanoutID) ?? false
    }

    func publishCursor(_ update: VirtioGPUCursorUpdate?, scanoutCount: Int) {
        lock.withLock { relay }?.publishCursor(update, scanoutCount: scanoutCount)
    }

    func publishHiddenCursor(scanoutID: UInt32) {
        lock.withLock { relay }?.publishHiddenCursor(scanoutID: scanoutID)
    }

    func start() {
        lock.withLock { relay }?.start()
    }

    func stop() {
        lock.withLock { relay }?.stop()
    }

    var presentationIntervalMetrics: DoryVMDisplayPresentationIntervalMetrics? {
        lock.withLock { relay }?.presentationIntervalMetrics
    }
}

struct DoryVMDisplayPresentationIntervalMetrics: Equatable, Sendable {
    var sampleCount: UInt64
    var p95Nanoseconds: UInt64
    var p99Nanoseconds: UInt64
}

struct DoryVMDisplayCPUFrameCompletion: Equatable, Sendable {
    let scanoutID: UInt32
    let resourceID: UInt32
    let resourceGeneration: UInt64
    let visibleContent: Bool
}

/// Bounded, per-scanout measurement of intervals between frames the Dory app actually presented.
/// Keeping independent last-presented timestamps avoids treating simultaneous updates on two
/// displays as an artificially short frame interval.
final class DoryVMDisplayPresentationIntervals: @unchecked Sendable {
    typealias Clock = @Sendable () -> UInt64

    private let maximumSampleCount: Int
    private let clock: Clock
    private let lock = NSLock()
    private var lastPresentedByScanout: [UInt32: UInt64] = [:]
    private var samples: [UInt64] = []
    private var nextReplacementIndex = 0

    init(
        maximumSampleCount: Int = 4_096,
        clock: @escaping Clock = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.maximumSampleCount = max(1, maximumSampleCount)
        self.clock = clock
        samples.reserveCapacity(max(1, maximumSampleCount))
    }

    func recordPresented(scanoutID: UInt32) {
        recordPresented(scanoutID: scanoutID, monotonicNanoseconds: clock())
    }

    func recordPresented(scanoutID: UInt32, monotonicNanoseconds: UInt64) {
        lock.withLock {
            defer { lastPresentedByScanout[scanoutID] = monotonicNanoseconds }
            guard let previous = lastPresentedByScanout[scanoutID],
                  monotonicNanoseconds > previous else { return }
            let interval = monotonicNanoseconds - previous
            if samples.count < maximumSampleCount {
                samples.append(interval)
                return
            }
            samples[nextReplacementIndex] = interval
            nextReplacementIndex = (nextReplacementIndex + 1) % maximumSampleCount
        }
    }

    var metrics: DoryVMDisplayPresentationIntervalMetrics {
        lock.withLock {
            let sorted = samples.sorted()
            return DoryVMDisplayPresentationIntervalMetrics(
                sampleCount: UInt64(sorted.count),
                p95Nanoseconds: Self.nearestRank(95, sorted: sorted),
                p99Nanoseconds: Self.nearestRank(99, sorted: sorted)
            )
        }
    }

    private static func nearestRank(_ percentile: Int, sorted: [UInt64]) -> UInt64 {
        guard !sorted.isEmpty else { return 0 }
        let rank = (sorted.count * percentile + 99) / 100
        return sorted[max(0, min(sorted.count - 1, rank - 1))]
    }
}

final class DoryVMDisplayRunnerResizeTarget: @unchecked Sendable {
    private struct Target {
        weak var gpu: VirtioGPU?
        weak var transport: VirtioMMIOTransport?
        let pointerTopology: DesktopPointerTopology
    }

    private let lock = NSLock()
    private var target: Target?

    func install(
        gpu: VirtioGPU,
        transport: VirtioMMIOTransport,
        pointerTopology: DesktopPointerTopology
    ) {
        lock.withLock {
            target = Target(
                gpu: gpu,
                transport: transport,
                pointerTopology: pointerTopology
            )
        }
    }

    func apply(
        scanoutID: UInt32,
        width: UInt32,
        height: UInt32,
        physicalWidthMillimeters: UInt16,
        physicalHeightMillimeters: UInt16
    ) -> Bool {
        guard let target = lock.withLock({ target }),
              let gpu = target.gpu,
              let transport = target.transport else { return false }
        guard gpu.updateScanoutSize(
            scanoutID: scanoutID,
            width: width,
            height: height,
            physicalWidthMillimeters: physicalWidthMillimeters,
            physicalHeightMillimeters: physicalHeightMillimeters,
            transport: transport
        ) else { return false }
        target.pointerTopology.update(scanoutID: scanoutID, width: width, height: height)
        return true
    }

    func apply(topology: [DoryVMDisplayTopologyEntry]) -> Bool {
        guard let target = lock.withLock({ target }),
              let gpu = target.gpu,
              let transport = target.transport else { return false }
        let sizes = topology.map {
            VirtioGPUScanoutSize(
                width: $0.width,
                height: $0.height,
                physicalWidthMillimeters: $0.physicalWidthMillimeters,
                physicalHeightMillimeters: $0.physicalHeightMillimeters
            )
        }
        guard gpu.updateScanoutTopology(sizes, transport: transport) else { return false }
        target.pointerTopology.updateActiveTopology(sizes)
        return true
    }
}

/// Runner-side owner of app-presented frame leases. A frame remains live in this process until
/// doryd reports that the app either committed or rejected it; only then is the existing GPU host
/// submission completed and the renderer presentation consumer retired.
enum DoryVMDisplayPresentationDisposition {
    static func isExpectedRetirement(_ detail: String) -> Bool {
        switch detail {
        case "frame-evicted", "scanout-removed", "application-disconnected",
             "runner-stopped", "runner-retired", "runner-disconnected":
            true
        default:
            false
        }
    }
}

enum DoryVMDisplayAcceleratedFrameAdmission {
    static func accepts<S: Sequence>(
        scanoutID: UInt32,
        pendingScanoutIDs: S,
        maximumPerScanout: Int
    ) -> Bool where S.Element == UInt32 {
        precondition(maximumPerScanout > 0)
        var count = 0
        for pendingScanoutID in pendingScanoutIDs where pendingScanoutID == scanoutID {
            count += 1
            if count >= maximumPerScanout { return false }
        }
        return true
    }
}

final class DoryVMDisplayRunnerRelay: @unchecked Sendable {
    private final class PendingFrame: @unchecked Sendable {
        let scanoutID: UInt32
        let descriptor: FileHandle?
        let sharedTextureHandle: MTLSharedTextureHandle?
        let requiresMetalCompletion: Bool
        let cpuResourceID: UInt32?
        let cpuResourceGeneration: UInt64?
        let completion: @Sendable (Bool, UInt64, String) -> Void

        private let lock = NSLock()
        private var completed = false

        init(
            update: VirtioGPUMetalScanoutUpdate,
            descriptor: FileHandle?,
            sharedTextureHandle: MTLSharedTextureHandle?,
            onPresentationCompleted: @escaping @Sendable (UInt64, UInt32) -> Void,
            onPresentationFailed: @escaping @Sendable (UInt64, String) -> Void
        ) {
            self.scanoutID = update.scanoutID
            self.descriptor = descriptor
            self.sharedTextureHandle = sharedTextureHandle
            self.requiresMetalCompletion = true
            self.cpuResourceID = nil
            self.cpuResourceGeneration = nil
            self.completion = { presented, completionID, detail in
                if presented {
                    update.recordPresentationCompleted(completionID: completionID)
                    update.acceptHostSubmission()
                    onPresentationCompleted(
                        update.presentation.workerGeneration.rawValue,
                        update.scanoutID
                    )
                } else {
                    update.rejectHostSubmission()
                    if !DoryVMDisplayPresentationDisposition.isExpectedRetirement(detail) {
                        onPresentationFailed(update.presentation.workerGeneration.rawValue, detail)
                    }
                }
                update.presentation.finishPresentation()
            }
        }

        init(
            scanoutID: UInt32,
            resourceID: UInt32,
            resourceGeneration: UInt64,
            descriptor: FileHandle,
            visibleContent: Bool,
            onPresentationCompleted: @escaping @Sendable (DoryVMDisplayCPUFrameCompletion) -> Void
        ) {
            self.scanoutID = scanoutID
            self.descriptor = descriptor
            self.sharedTextureHandle = nil
            self.requiresMetalCompletion = false
            self.cpuResourceID = resourceID
            self.cpuResourceGeneration = resourceGeneration
            self.completion = { presented, _, _ in
                if presented {
                    onPresentationCompleted(.init(
                        scanoutID: scanoutID,
                        resourceID: resourceID,
                        resourceGeneration: resourceGeneration,
                        visibleContent: visibleContent
                    ))
                }
            }
        }

        init(
            update: DoryPCVirGLScanoutUpdate,
            descriptor: FileHandle?,
            sharedTextureHandle: MTLSharedTextureHandle?,
            onPresentationCompleted: @escaping @Sendable (UInt64, UInt32) -> Void,
            onPresentationFailed: @escaping @Sendable (UInt64, String) -> Void
        ) {
            self.scanoutID = update.flush.scanoutID
            self.descriptor = descriptor
            self.sharedTextureHandle = sharedTextureHandle
            self.requiresMetalCompletion = true
            self.cpuResourceID = nil
            self.cpuResourceGeneration = nil
            self.completion = { presented, completionID, detail in
                if presented && update.isGenerationCurrent {
                    update.recordPresentationCompleted(completionID: completionID)
                    onPresentationCompleted(
                        update.workerGeneration.rawValue,
                        update.flush.scanoutID
                    )
                } else if !DoryVMDisplayPresentationDisposition.isExpectedRetirement(detail) {
                    onPresentationFailed(
                        update.workerGeneration.rawValue,
                        presented ? "renderer-generation-revoked-before-presentation" : detail
                    )
                }
                update.retire()
            }
        }

        func complete(
            presented: Bool,
            metalCommandBufferCompletionID: UInt64 = 0,
            detail: String = "presentation-rejected"
        ) {
            let shouldComplete = lock.withLock { () -> Bool in
                guard !completed else { return false }
                completed = true
                return true
            }
            guard shouldComplete else { return }
            completion(presented, metalCommandBufferCompletionID, detail)
            try? descriptor?.close()
        }

        deinit {
            complete(presented: false)
        }
    }

    private struct State {
        var nextFrameSequence: UInt64 = 1
        var nextCursorSequence: UInt64 = 1
        var cpuEpoch: UInt64 = 1
        var lastCommandSequence: UInt64 = 0
        var pending: [UUID: PendingFrame] = [:]
        var cpuSurfaces: [UInt32: CPUFrameSurface] = [:]
        var retiredCPUResourceGenerations: [UInt32: UInt64] = [:]
        var cpuResourceAdmissionExhausted = false
        var cpuFrameInFlightScanouts: Set<UInt32> = []
        var cpuFrameRefreshPendingScanouts: Set<UInt32> = []
        var started = false
        var stopped = false
        var pollInFlight = false
    }

    private final class RetirementReplyBox: @unchecked Sendable {
        private let lock = NSLock()
        private var response: (Bool, String)?
        private let semaphore = DispatchSemaphore(value: 0)

        func resolve(_ accepted: Bool, _ detail: String) {
            let first = lock.withLock { () -> Bool in
                guard response == nil else { return false }
                response = (accepted, detail)
                return true
            }
            if first { semaphore.signal() }
        }

        func wait() -> (Bool, String)? {
            guard semaphore.wait(timeout: .now() + 3) == .success else { return nil }
            return lock.withLock { response }
        }
    }

    private struct CPUFrameSurface {
        var resourceID: UInt32
        var resourceGeneration: UInt64
        var format: UInt32
        var width: UInt32
        var height: UInt32
        var stride: UInt32
        var bytes: Data
    }

    private struct CPUFrameSnapshot {
        var scanoutID: UInt32
        var sequence: UInt64
        var epoch: UInt64
        var surface: CPUFrameSurface
    }

    private let machineID: String
    private let operationID: String
    private let transport: any DoryVMDisplayRunnerTransport
    private let commandHandler: DoryVMDisplayRunnerCommandHandler
    private let log: @Sendable (String) -> Void
    private let onPresentationCompleted: @Sendable (UInt64, UInt32) -> Void
    private let onPresentationFailed: @Sendable (UInt64, String) -> Void
    private let onCPUPresentationCompleted: @Sendable (DoryVMDisplayCPUFrameCompletion) -> Void
    private let onDeferredCPUFrameRefresh: (@Sendable (UInt32) -> Void)?
    private let presentationIntervals: DoryVMDisplayPresentationIntervals
    private let maximumCPUSurfaceBytes: UInt64
    private let maximumPendingAcceleratedFramesPerScanout: Int
    private let pollQueue = DispatchQueue(
        label: "dev.dory.dory-hv.display-command-relay",
        qos: .userInteractive
    )
    private let cpuRefreshQueue = DispatchQueue(
        label: "dev.dory.dory-hv.display-cpu-refresh",
        qos: .userInitiated
    )
    private let lock = NSLock()
    private var state = State()
    // The handlers only submit bounded device work. Serialize that submission with revocation,
    // without invoking any device callback while the frame/resource state lock is held.
    private let commandApplicationLock = NSLock()

    static func connect(
        machineID: String,
        operationID: UUID,
        serviceName: String,
        commandHandler: DoryVMDisplayRunnerCommandHandler,
        onPresentationCompleted: @escaping @Sendable (UInt64, UInt32) -> Void = { _, _ in },
        onPresentationFailed: @escaping @Sendable (UInt64, String) -> Void = { _, _ in },
        onCPUPresentationCompleted: @escaping @Sendable (DoryVMDisplayCPUFrameCompletion) -> Void = { _ in },
        onDeferredCPUFrameRefresh: (@Sendable (UInt32) -> Void)? = nil,
        log: @escaping @Sendable (String) -> Void
    ) -> DoryVMDisplayRunnerRelay {
        final class TransportBox: @unchecked Sendable {
            weak var relay: DoryVMDisplayRunnerRelay?
        }
        let box = TransportBox()
        let transport = DoryVMDisplayRunnerXPCTransport(
            serviceName: serviceName,
            invalidationHandler: { [weak box] in
                box?.relay?.transportInvalidated()
            }
        )
        let relay = DoryVMDisplayRunnerRelay(
            machineID: machineID,
            operationID: operationID,
            transport: transport,
            commandHandler: commandHandler,
            onPresentationCompleted: onPresentationCompleted,
            onPresentationFailed: onPresentationFailed,
            onCPUPresentationCompleted: onCPUPresentationCompleted,
            onDeferredCPUFrameRefresh: onDeferredCPUFrameRefresh,
            log: log
        )
        box.relay = relay
        return relay
    }

    init(
        machineID: String,
        operationID: UUID,
        transport: any DoryVMDisplayRunnerTransport,
        commandHandler: DoryVMDisplayRunnerCommandHandler,
        onPresentationCompleted: @escaping @Sendable (UInt64, UInt32) -> Void = { _, _ in },
        onPresentationFailed: @escaping @Sendable (UInt64, String) -> Void = { _, _ in },
        onCPUPresentationCompleted: @escaping @Sendable (DoryVMDisplayCPUFrameCompletion) -> Void = { _ in },
        onDeferredCPUFrameRefresh: (@Sendable (UInt32) -> Void)? = nil,
        presentationIntervals: DoryVMDisplayPresentationIntervals = .init(),
        maximumCPUSurfaceBytes: UInt64 = DoryRendererWorkerLimits.production.maximumScanoutBytes,
        maximumPendingAcceleratedFramesPerScanout: Int = 3,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        precondition(maximumCPUSurfaceBytes > 0)
        precondition(maximumPendingAcceleratedFramesPerScanout > 0)
        self.machineID = machineID
        self.operationID = operationID.uuidString.lowercased()
        self.transport = transport
        self.commandHandler = commandHandler
        self.onPresentationCompleted = onPresentationCompleted
        self.onPresentationFailed = onPresentationFailed
        self.onCPUPresentationCompleted = onCPUPresentationCompleted
        self.onDeferredCPUFrameRefresh = onDeferredCPUFrameRefresh
        self.presentationIntervals = presentationIntervals
        self.maximumCPUSurfaceBytes = maximumCPUSurfaceBytes
        self.maximumPendingAcceleratedFramesPerScanout = maximumPendingAcceleratedFramesPerScanout
        self.log = log
    }

    /// Called with `lock` held. The broker independently retains at most two frames per scanout;
    /// one additional runner lease covers a frame still in transit over XPC.
    private func admitsAcceleratedFrame(scanoutID: UInt32) -> Bool {
        DoryVMDisplayAcceleratedFrameAdmission.accepts(
            scanoutID: scanoutID,
            pendingScanoutIDs: state.pending.values.lazy.filter(\.requiresMetalCompletion)
                .map(\.scanoutID),
            maximumPerScanout: maximumPendingAcceleratedFramesPerScanout
        )
    }

    var presentationIntervalMetrics: DoryVMDisplayPresentationIntervalMetrics {
        presentationIntervals.metrics
    }

    func start() {
        let shouldStart = lock.withLock { () -> Bool in
            guard !state.started, !state.stopped else { return false }
            state.started = true
            return true
        }
        if shouldStart { scheduleCommandPoll(after: 0) }
    }

    func publish(_ update: VirtioGPUMetalScanoutUpdate) {
        let prepared: (
            frame: DoryVMDisplayFrame,
            descriptor: FileHandle?,
            handle: MTLSharedTextureHandle?
        )
        do {
            let sequence = try nextFrameSequence()
            let payload: Data
            let transportKind: DoryVMDisplayFrameTransport
            let descriptor: FileHandle?
            let sharedTextureHandle: MTLSharedTextureHandle?
            switch update.presentation.transport {
            case .sharedMemory:
                let authority = try update.presentation.withSharedMemoryScanout {
                    lease, descriptor in
                    let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
                    guard duplicate >= 0 else {
                        throw CocoaError(.fileReadUnknown)
                    }
                    return (
                        DoryRendererScanoutLeaseCodec.encode(lease),
                        FileHandle(fileDescriptor: duplicate, closeOnDealloc: true)
                    )
                }
                payload = authority.0
                descriptor = authority.1
                sharedTextureHandle = nil
                transportKind = .sharedMemory
            case .sharedTexture:
                let authority = try update.presentation.withSharedTextureHandle { handle in
                    let lease = try DoryRendererSharedTextureScanoutLease(
                            workerGeneration: update.presentation.workerGeneration,
                            resourceID: update.presentation.resourceID,
                            resourceGeneration: update.presentation.resourceGeneration,
                            leaseID: update.presentation.leaseID,
                            releaseToken: update.presentation.releaseToken,
                            synchronization: .managedGuestProducerCompleteFlush,
                            pixelFormat: update.presentation.pixelFormat,
                            yOriginTop: update.presentation.yOriginTop,
                            width: update.presentation.width,
                            height: update.presentation.height
                        )
                    return (
                        DoryRendererSharedTextureScanoutLeaseCodec.encode(lease),
                        handle
                    )
                }
                payload = authority.0
                descriptor = nil
                sharedTextureHandle = authority.1
                transportKind = .sharedTexture
            }
            let sourceRect = DoryVMDisplayRect(
                x: update.sourceRect.x,
                y: update.sourceRect.y,
                width: update.sourceRect.width,
                height: update.sourceRect.height
            )
            let dirtyRect = DoryVMDisplayRect(
                x: update.dirtyRect.x,
                y: update.dirtyRect.y,
                width: update.dirtyRect.width,
                height: update.dirtyRect.height
            )
            prepared = (
                try DoryVMDisplayFrame(
                    machineID: machineID,
                    operationID: UUID(uuidString: operationID)!,
                    scanoutID: update.scanoutID,
                    sequence: sequence,
                    displayResourceGeneration: update.resourceGeneration,
                    transport: transportKind,
                    leasePayload: payload,
                    sourceRect: sourceRect,
                    dirtyRect: dirtyRect
                ),
                descriptor,
                sharedTextureHandle
            )
        } catch {
            update.rejectHostSubmission()
            update.presentation.discardWithoutPresentation()
            log("dory-hv display relay rejected frame preparation: \(error)")
            return
        }

        let pending = PendingFrame(
            update: update,
            descriptor: prepared.descriptor,
            sharedTextureHandle: prepared.handle,
            onPresentationCompleted: onPresentationCompleted,
            onPresentationFailed: onPresentationFailed
        )
        let leaseID = update.presentation.leaseID.rawValue
        let admitted = lock.withLock { () -> Bool in
            guard !state.stopped, state.pending[leaseID] == nil,
                  admitsAcceleratedFrame(scanoutID: pending.scanoutID)
            else { return false }
            state.pending[leaseID] = pending
            return true
        }
        guard admitted else {
            pending.complete(presented: false, detail: "frame-evicted")
            return
        }

        do {
            let encoded = try DoryVMDisplayFrameCodec.encode(prepared.frame)
            transport.publishFrame(
                encoded,
                descriptors: prepared.descriptor.map { [$0] } ?? [],
                sharedTextureHandle: prepared.handle
            ) { [weak self] presented, completionID, detail in
                self?.completeFrame(
                    leaseID: leaseID,
                    presented: presented,
                    metalCommandBufferCompletionID: completionID,
                    detail: detail
                )
            }
        } catch {
            completeFrame(
                leaseID: leaseID,
                presented: false,
                detail: "frame-encoding-failed: \(error)"
            )
        }
    }

    @discardableResult
    func publish(_ update: DoryPCVirGLScanoutUpdate) -> Bool {
        guard update.isCurrent else {
            update.retire()
            return false
        }
        let prepared: (
            frame: DoryVMDisplayFrame,
            leaseID: UUID,
            descriptor: FileHandle?,
            handle: MTLSharedTextureHandle?
        )
        do {
            let sequence = try nextFrameSequence()
            let payload: Data
            let leaseID: UUID
            let transportKind: DoryVMDisplayFrameTransport
            let descriptor: FileHandle?
            let sharedTextureHandle: MTLSharedTextureHandle?
            switch update.transport {
            case .sharedMemory:
                let authority = try update.withSharedMemory { lease, sourceDescriptor in
                    let duplicate = fcntl(sourceDescriptor, F_DUPFD_CLOEXEC, 0)
                    guard duplicate >= 0 else { throw CocoaError(.fileReadUnknown) }
                    return (
                        lease,
                        FileHandle(fileDescriptor: duplicate, closeOnDealloc: true)
                    )
                }
                payload = DoryRendererScanoutLeaseCodec.encode(authority.0)
                leaseID = authority.0.leaseID.rawValue
                descriptor = authority.1
                sharedTextureHandle = nil
                transportKind = .sharedMemory
            case .sharedTexture:
                let authority = try update.withSharedTextureAuthority { lease, handle in
                    (lease, handle)
                }
                payload = DoryRendererSharedTextureScanoutLeaseCodec.encode(authority.0)
                leaseID = authority.0.leaseID.rawValue
                descriptor = nil
                sharedTextureHandle = authority.1
                transportKind = .sharedTexture
            }
            let flush = update.flush
            prepared = (
                try DoryVMDisplayFrame(
                    machineID: machineID,
                    operationID: UUID(uuidString: operationID)!,
                    scanoutID: flush.scanoutID,
                    sequence: sequence,
                    displayResourceGeneration: update.rendererResourceGeneration,
                    transport: transportKind,
                    leasePayload: payload,
                    sourceRect: DoryVMDisplayRect(
                        x: flush.sourceRectangle.x,
                        y: flush.sourceRectangle.y,
                        width: flush.sourceRectangle.width,
                        height: flush.sourceRectangle.height
                    ),
                    dirtyRect: DoryVMDisplayRect(
                        x: flush.damagedRectangle.x,
                        y: flush.damagedRectangle.y,
                        width: flush.damagedRectangle.width,
                        height: flush.damagedRectangle.height
                    )
                ),
                leaseID,
                descriptor,
                sharedTextureHandle
            )
        } catch {
            update.retire()
            log("dory-hv display relay rejected DoryPC frame preparation: \(error)")
            return false
        }

        let pending = PendingFrame(
            update: update,
            descriptor: prepared.descriptor,
            sharedTextureHandle: prepared.handle,
            onPresentationCompleted: onPresentationCompleted,
            onPresentationFailed: onPresentationFailed
        )
        let admitted = lock.withLock { () -> Bool in
            guard !state.stopped, state.pending[prepared.leaseID] == nil,
                  admitsAcceleratedFrame(scanoutID: pending.scanoutID) else {
                return false
            }
            state.pending[prepared.leaseID] = pending
            return true
        }
        guard admitted else {
            pending.complete(presented: false, detail: "frame-evicted")
            return false
        }
        guard update.isCurrent else {
            completeFrame(
                leaseID: prepared.leaseID,
                presented: false,
                detail: "DoryPC-renderer-generation-revoked"
            )
            return false
        }
        let leaseID = prepared.leaseID
        do {
            transport.publishFrame(
                try DoryVMDisplayFrameCodec.encode(prepared.frame),
                descriptors: prepared.descriptor.map { [$0] } ?? [],
                sharedTextureHandle: prepared.handle
            ) { [weak self] presented, completionID, detail in
                self?.completeFrame(
                    leaseID: leaseID,
                    presented: presented,
                    metalCommandBufferCompletionID: completionID,
                    detail: detail
                )
            }
            return true
        } catch {
            completeFrame(
                leaseID: prepared.leaseID,
                presented: false,
                detail: "DoryPC-frame-encoding-failed: \(error)"
            )
            return false
        }
    }

    /// Relays the copied 2D scanout used by firmware, boot loaders, and early kernel modesetting.
    /// This path is deliberately distinct from renderer-backed presentation: its acknowledgement
    /// never satisfies the synchronized-renderer readiness boundary.
    func publish(_ frame: VirtioGPUScanoutFrame) {
        let snapshot: CPUFrameSnapshot?
        var claimedSnapshot: CPUFrameSnapshot?
        do {
            snapshot = try lock.withLock {
                guard !state.stopped, state.nextFrameSequence < UInt64.max else {
                    throw CancellationError()
                }
                guard !state.cpuResourceAdmissionExhausted,
                      frame.resourceID != 0,
                      frame.resourceGeneration > (state.retiredCPUResourceGenerations[
                        frame.resourceID] ?? 0) else {
                    throw DoryVMDisplayWireError.invalidFrameIdentity
                }
                guard frame.scanoutID < DoryVMDisplayFrame.maximumScanoutCount,
                      frame.width > 0, frame.height > 0,
                      frame.dirtyRect.x <= frame.width,
                      frame.dirtyRect.y <= frame.height,
                      frame.dirtyRect.width <= frame.width - frame.dirtyRect.x,
                      frame.dirtyRect.height <= frame.height - frame.dirtyRect.y,
                      let pixelFormat = Self.cpuPixelFormat(frame.format),
                      UInt64(frame.stride) >= UInt64(frame.dirtyRect.width) * 4,
                      UInt64(frame.bytes.count)
                        >= UInt64(frame.stride) * UInt64(frame.dirtyRect.height) else {
                    throw DoryVMDisplayWireError.invalidRectangle
                }
                let (fullStride, strideOverflow) = UInt64(frame.width)
                    .multipliedReportingOverflow(by: 4)
                let (fullBytes, surfaceOverflow) = fullStride
                    .multipliedReportingOverflow(by: UInt64(frame.height))
                guard !strideOverflow, !surfaceOverflow,
                      frame.width <= 16_384, frame.height <= 16_384,
                      fullStride <= UInt64(UInt32.max),
                      fullBytes <= UInt64(Int.max),
                      fullBytes <= DoryRendererWorkerLimits.production.maximumScanoutBytes else {
                    throw DoryVMDisplayWireError.frameTooLarge
                }
                let resourceGeneration = frame.resourceGeneration
                var surface = state.cpuSurfaces[frame.scanoutID]
                if surface?.resourceID != frame.resourceID
                    || surface?.resourceGeneration != resourceGeneration
                    || surface?.format != pixelFormat.rawValue
                    || surface?.width != frame.width
                    || surface?.height != frame.height {
                    let retainedBytes = state.cpuSurfaces.reduce(UInt64(0)) { total, entry in
                        entry.key == frame.scanoutID ? total : total + UInt64(entry.value.bytes.count)
                    }
                    guard fullBytes <= maximumCPUSurfaceBytes,
                          retainedBytes <= maximumCPUSurfaceBytes - fullBytes else {
                        throw DoryVMDisplayWireError.frameTooLarge
                    }
                    surface = CPUFrameSurface(
                        resourceID: frame.resourceID,
                        resourceGeneration: resourceGeneration,
                        format: pixelFormat.rawValue,
                        width: frame.width,
                        height: frame.height,
                        stride: UInt32(fullStride),
                        bytes: Data(repeating: 0, count: Int(fullBytes))
                    )
                }
                guard var surface else { throw DoryVMDisplayWireError.invalidFrameIdentity }
                let copiedRowBytes = Int(frame.dirtyRect.width) * 4
                surface.bytes.withUnsafeMutableBytes { destination in
                    frame.bytes.withUnsafeBytes { source in
                        guard let destinationBase = destination.baseAddress,
                              let sourceBase = source.baseAddress else { return }
                        for row in 0..<Int(frame.dirtyRect.height) {
                            let destinationOffset = (Int(frame.dirtyRect.y) + row)
                                * Int(surface.stride) + Int(frame.dirtyRect.x) * 4
                            let sourceOffset = row * Int(frame.stride)
                            destinationBase.advanced(by: destinationOffset).copyMemory(
                                from: sourceBase.advanced(by: sourceOffset),
                                byteCount: copiedRowBytes
                            )
                        }
                    }
                }
                state.cpuSurfaces[frame.scanoutID] = surface
                // Do not prepare another descriptor-backed lease while the app owns one. PC
                // submits dirty rows here and they coalesce into the canonical surface; ARM can
                // defer extraction in the GPU and request one current snapshot after the receipt.
                guard !state.cpuFrameInFlightScanouts.contains(frame.scanoutID) else {
                    state.cpuFrameRefreshPendingScanouts.insert(frame.scanoutID)
                    return nil
                }
                state.cpuFrameInFlightScanouts.insert(frame.scanoutID)
                let sequence = state.nextFrameSequence
                state.nextFrameSequence += 1
                return CPUFrameSnapshot(
                    scanoutID: frame.scanoutID,
                    sequence: sequence,
                    epoch: state.cpuEpoch,
                    surface: surface
                )
            }
            guard let snapshot else { return }
            claimedSnapshot = snapshot
            try publishCPUFrame(snapshot)
        } catch {
            if let claimedSnapshot { releaseCPUFrameClaimIfCurrent(claimedSnapshot) }
            log("dory-hv display relay rejected CPU frame: \(error)")
        }
    }

    private func releaseCPUFrameClaimIfCurrent(_ snapshot: CPUFrameSnapshot) {
        lock.withLock {
            guard state.cpuEpoch == snapshot.epoch,
                  state.cpuSurfaces[snapshot.scanoutID]?.resourceID
                    == snapshot.surface.resourceID,
                  state.cpuSurfaces[snapshot.scanoutID]?.resourceGeneration
                    == snapshot.surface.resourceGeneration else { return }
            state.cpuFrameInFlightScanouts.remove(snapshot.scanoutID)
        }
    }

    func canPublishCPUFrame(scanoutID: UInt32) -> Bool {
        lock.withLock {
            guard !state.stopped, !state.cpuResourceAdmissionExhausted,
                  state.nextFrameSequence < UInt64.max,
                  scanoutID < DoryVMDisplayFrame.maximumScanoutCount else { return false }
            guard state.cpuFrameInFlightScanouts.contains(scanoutID),
                  onDeferredCPUFrameRefresh != nil else { return true }
            // The caller is still under the virtio command lock. Record only a bounded signal;
            // the acknowledgement callback will request one fresh copy of the latest backing.
            state.cpuFrameRefreshPendingScanouts.insert(scanoutID)
            return false
        }
    }

    /// A guest reset revokes all CPU-copy surfaces from the previous boot. Retiring pending
    /// receipts also frees their descriptors and prevents a late Metal acknowledgement from
    /// publishing a coalesced frame that belonged to the old virtio-gpu generation.
    func resetCPUFrames() -> Bool {
        let retirement = lock.withLock { () -> [PendingFrame] in
            if state.cpuEpoch == .max {
                state.cpuResourceAdmissionExhausted = true
            } else {
                state.cpuEpoch += 1
            }
            state.cpuSurfaces.removeAll(keepingCapacity: false)
            state.cpuFrameInFlightScanouts.removeAll(keepingCapacity: false)
            state.cpuFrameRefreshPendingScanouts.removeAll(keepingCapacity: false)
            let leaseIDs = state.pending.compactMap { leaseID, frame in
                frame.requiresMetalCompletion ? nil : leaseID
            }
            return leaseIDs.compactMap { state.pending.removeValue(forKey: $0) }
        }
        for frame in retirement {
            frame.complete(presented: false, detail: "guest-reset")
        }
        let reply = RetirementReplyBox()
        transport.retireCPUFrames(machineID: machineID, operationID: operationID) {
            reply.resolve($0, $1)
        }
        guard let (accepted, detail) = reply.wait() else {
            log("dory-hv display relay CPU frame retirement timed out")
            return false
        }
        if !accepted {
            log("dory-hv display relay CPU frame retirement rejected: \(detail)")
        }
        return accepted && !lock.withLock { state.cpuResourceAdmissionExhausted }
    }

    /// Resource unref only revokes the matching copied incarnation; other scanouts remain live.
    /// The broker also records the tombstone before returning so an already-sent descriptor cannot
    /// be delivered after the guest has reused the numeric resource ID.
    func retireCPUResource(resourceID: UInt32, throughGeneration: UInt64) -> Bool {
        guard resourceID != 0, throughGeneration != 0 else { return false }
        let retirement = lock.withLock { () -> [PendingFrame] in
            if state.retiredCPUResourceGenerations[resourceID] == nil,
               state.retiredCPUResourceGenerations.count >= 1_048_576 {
                state.cpuResourceAdmissionExhausted = true
            } else {
                state.retiredCPUResourceGenerations[resourceID] = max(
                    state.retiredCPUResourceGenerations[resourceID] ?? 0,
                    throughGeneration
                )
            }
            let retiredScanouts = state.cpuSurfaces.compactMap { scanoutID, surface in
                surface.resourceID == resourceID
                    && surface.resourceGeneration <= throughGeneration ? scanoutID : nil
            }
            for scanoutID in retiredScanouts {
                state.cpuSurfaces.removeValue(forKey: scanoutID)
                state.cpuFrameInFlightScanouts.remove(scanoutID)
                state.cpuFrameRefreshPendingScanouts.remove(scanoutID)
            }
            let leaseIDs = state.pending.compactMap { leaseID, frame in
                frame.cpuResourceID == resourceID
                    && (frame.cpuResourceGeneration ?? .max) <= throughGeneration
                    ? leaseID : nil
            }
            return leaseIDs.compactMap { state.pending.removeValue(forKey: $0) }
        }
        for frame in retirement {
            frame.complete(presented: false, detail: "resource-retired")
        }
        let reply = RetirementReplyBox()
        transport.retireCPUResource(
            machineID: machineID,
            operationID: operationID,
            resourceID: resourceID,
            throughGeneration: throughGeneration
        ) { reply.resolve($0, $1) }
        guard let (accepted, detail) = reply.wait() else {
            log("dory-hv display relay CPU resource retirement timed out")
            return false
        }
        if !accepted {
            log("dory-hv display relay CPU resource retirement rejected: \(detail)")
        }
        return accepted && !lock.withLock { state.cpuResourceAdmissionExhausted }
    }

    func publishCursor(_ update: VirtioGPUCursorUpdate?, scanoutCount: Int) {
        let scanoutIDs: [UInt32]
        if let update {
            scanoutIDs = [update.scanoutID]
        } else {
            scanoutIDs = (0..<max(0, scanoutCount)).map(UInt32.init)
        }
        publishCursor(update, scanoutIDs: scanoutIDs)
    }

    func publishHiddenCursor(scanoutID: UInt32) {
        publishCursor(nil, scanoutIDs: [scanoutID])
    }

    private func publishCursor(
        _ update: VirtioGPUCursorUpdate?,
        scanoutIDs: [UInt32]
    ) {
        for scanoutID in scanoutIDs {
            do {
                let sequence = try nextCursorSequence()
                let operation = UUID(uuidString: operationID)!
                let cursor: DoryVMDisplayCursor
                if let update {
                    cursor = try .visible(
                        machineID: machineID,
                        operationID: operation,
                        scanoutID: update.scanoutID,
                        sequence: sequence,
                        resourceID: update.resourceID,
                        x: update.x,
                        y: update.y,
                        width: update.width,
                        height: update.height,
                        hotX: update.hotX,
                        hotY: update.hotY,
                        bytes: update.bytes
                    )
                } else {
                    cursor = try .hidden(
                        machineID: machineID,
                        operationID: operation,
                        scanoutID: scanoutID,
                        sequence: sequence
                    )
                }
                transport.publishCursor(try DoryVMDisplayCursorCodec.encode(cursor)) {
                    [log] accepted, detail in
                    if !accepted, !detail.isEmpty {
                        log("dory-hv display relay cursor: \(detail)")
                    }
                }
            } catch {
                log("dory-hv display relay rejected cursor: \(error)")
            }
        }
    }

    func stop() {
        let retirement = commandApplicationLock.withLock { () -> [PendingFrame]? in
            let pending = lock.withLock { () -> [PendingFrame]? in
                guard !state.stopped else { return nil }
                state.stopped = true
                let pending = Array(state.pending.values)
                state.pending.removeAll(keepingCapacity: false)
                state.cpuSurfaces.removeAll(keepingCapacity: false)
                state.cpuFrameInFlightScanouts.removeAll(keepingCapacity: false)
                state.cpuFrameRefreshPendingScanouts.removeAll(keepingCapacity: false)
                return pending
            }
            guard pending != nil else { return nil }
            commandHandler.revokeFocus()
            commandHandler.releaseInput()
            return pending
        }
        guard let pending = retirement else { return }
        for frame in pending { frame.complete(presented: false, detail: "runner-stopped") }
        transport.retireRunner(machineID: machineID, operationID: operationID) {
            [transport, log] accepted, detail in
            if !accepted, !detail.isEmpty {
                log("dory-hv display relay retirement: \(detail)")
            }
            transport.invalidate()
        }
    }

    private func nextFrameSequence() throws -> UInt64 {
        try lock.withLock {
            guard !state.stopped, state.nextFrameSequence < UInt64.max else {
                throw CancellationError()
            }
            let sequence = state.nextFrameSequence
            state.nextFrameSequence += 1
            return sequence
        }
    }

    private func nextCursorSequence() throws -> UInt64 {
        try lock.withLock {
            guard !state.stopped, state.nextCursorSequence < UInt64.max else {
                throw CancellationError()
            }
            let sequence = state.nextCursorSequence
            state.nextCursorSequence += 1
            return sequence
        }
    }

    private func completeFrame(
        leaseID: UUID,
        presented: Bool,
        metalCommandBufferCompletionID: UInt64 = 0,
        detail: String
    ) {
        let completed = lock.withLock { () -> (PendingFrame, CPUFrameSnapshot?, UInt64?)? in
            guard let pending = state.pending.removeValue(forKey: leaseID) else { return nil }
            var refresh: CPUFrameSnapshot?
            var deferredRefreshEpoch: UInt64?
            if !pending.requiresMetalCompletion {
                state.cpuFrameInFlightScanouts.remove(pending.scanoutID)
                if state.cpuFrameRefreshPendingScanouts.remove(pending.scanoutID) != nil,
                   !state.stopped,
                   state.nextFrameSequence < UInt64.max,
                   let surface = state.cpuSurfaces[pending.scanoutID] {
                    if onDeferredCPUFrameRefresh != nil {
                        deferredRefreshEpoch = state.cpuEpoch
                    } else {
                        state.cpuFrameInFlightScanouts.insert(pending.scanoutID)
                        refresh = CPUFrameSnapshot(
                            scanoutID: pending.scanoutID,
                            sequence: state.nextFrameSequence,
                            epoch: state.cpuEpoch,
                            surface: surface
                        )
                        state.nextFrameSequence += 1
                    }
                }
            }
            return (pending, refresh, deferredRefreshEpoch)
        }
        guard let (pending, refresh, deferredRefreshEpoch) = completed else {
            return
        }
        // Every app-owned display frame is rendered by Metal, including a descriptor-backed
        // CPU copy. The broker therefore proves a successful presentation with a nonzero command
        // buffer completion ID for both transports. CPU frames remain separate from renderer
        // synchronization: PendingFrame's CPU completion only signals visible installer output.
        let validCompletion = presented == (metalCommandBufferCompletionID > 0)
        let effectivePresented = presented && validCompletion
        let effectiveCompletionID = effectivePresented
            ? metalCommandBufferCompletionID
            : 0
        let effectiveDetail = validCompletion
            ? detail
            : "invalid-metal-command-buffer-completion"
        if effectivePresented {
            presentationIntervals.recordPresented(scanoutID: pending.scanoutID)
        }
        pending.complete(
            presented: effectivePresented,
            metalCommandBufferCompletionID: effectiveCompletionID,
            detail: effectiveDetail
        )
        if let deferredRefreshEpoch {
            let scanoutID = pending.scanoutID
            cpuRefreshQueue.async { [weak self] in
                guard let self,
                      self.lock.withLock({
                          !self.state.stopped && self.state.cpuEpoch == deferredRefreshEpoch
                      }) else { return }
                self.onDeferredCPUFrameRefresh?(scanoutID)
            }
        }
        if let refresh {
            do {
                try publishCPUFrame(refresh)
            } catch {
                releaseCPUFrameClaimIfCurrent(refresh)
                log("dory-hv display relay rejected coalesced CPU frame: \(error)")
            }
        }
        if !effectivePresented, !effectiveDetail.isEmpty {
            log(
                "dory-hv display relay frame \(leaseID.uuidString.lowercased()): "
                    + effectiveDetail
            )
        }
    }

    private func publishCPUFrame(_ snapshot: CPUFrameSnapshot) throws {
        let descriptor = try Self.makeCPUFrameDescriptor(snapshot.surface.bytes)
        let leaseID = UUID()
        let lease = try DoryVMDisplayCPUFrameLease(
            leaseID: leaseID,
            releaseToken: UUID(),
            resourceID: snapshot.surface.resourceID,
            resourceGeneration: snapshot.surface.resourceGeneration,
            cpuEpoch: snapshot.epoch,
            pixelFormat: snapshot.surface.format,
            yOriginTop: true,
            width: snapshot.surface.width,
            height: snapshot.surface.height,
            stride: snapshot.surface.stride,
            declaredFileSize: UInt64(snapshot.surface.bytes.count)
        )
        let fullRect = DoryVMDisplayRect(
            x: 0,
            y: 0,
            width: snapshot.surface.width,
            height: snapshot.surface.height
        )
        let relayed = try DoryVMDisplayFrame(
            machineID: machineID,
            operationID: UUID(uuidString: operationID)!,
            scanoutID: snapshot.scanoutID,
            sequence: snapshot.sequence,
            displayResourceGeneration: snapshot.surface.resourceGeneration,
            transport: .cpuCopy,
            leasePayload: try DoryVMDisplayCPUFrameLeaseCodec.encode(lease),
            sourceRect: fullRect,
            dirtyRect: fullRect
        )
        let pending = PendingFrame(
            scanoutID: snapshot.scanoutID,
            resourceID: snapshot.surface.resourceID,
            resourceGeneration: snapshot.surface.resourceGeneration,
            descriptor: descriptor,
            visibleContent: DesktopFrameContent.containsVisiblePixels(
                snapshot.surface.bytes
            ),
            onPresentationCompleted: onCPUPresentationCompleted
        )
        let admitted = lock.withLock { () -> Bool in
            guard !state.stopped,
                  state.cpuEpoch == snapshot.epoch,
                  !state.cpuResourceAdmissionExhausted,
                  snapshot.surface.resourceGeneration > (state.retiredCPUResourceGenerations[
                    snapshot.surface.resourceID] ?? 0),
                  state.cpuSurfaces[snapshot.scanoutID]?.resourceID
                    == snapshot.surface.resourceID,
                  state.cpuSurfaces[snapshot.scanoutID]?.resourceGeneration
                    == snapshot.surface.resourceGeneration,
                  state.pending[leaseID] == nil else { return false }
            state.pending[leaseID] = pending
            return true
        }
        guard admitted else {
            releaseCPUFrameClaimIfCurrent(snapshot)
            pending.complete(presented: false, detail: "runner-not-accepting-frames")
            return
        }
        transport.publishFrame(
            try DoryVMDisplayFrameCodec.encode(relayed),
            descriptors: [descriptor],
            sharedTextureHandle: nil
        ) { [weak self] presented, completionID, detail in
            self?.completeFrame(
                leaseID: leaseID,
                presented: presented,
                metalCommandBufferCompletionID: completionID,
                detail: detail
            )
        }
    }

    private static func cpuPixelFormat(
        _ virtioFormat: UInt32
    ) -> DoryRendererScanoutPixelFormat? {
        switch virtioFormat {
        case 1, 2: .bgra8Unorm
        case 3, 4, 67, 68, 121, 134: .rgba8Unorm
        default: nil
        }
    }

    private static func makeCPUFrameDescriptor(_ bytes: Data) throws -> FileHandle {
        var template = Array("/tmp/dory-display-cpu.XXXXXX".utf8CString)
        let descriptor = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        _ = template.withUnsafeBufferPointer { unlink($0.baseAddress!) }
        guard ftruncate(descriptor, off_t(bytes.count)) == 0 else {
            let code = errno
            close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        var written = 0
        let writeSucceeded = bytes.withUnsafeBytes { source -> Bool in
            guard let base = source.baseAddress else { return bytes.isEmpty }
            while written < bytes.count {
                let result = pwrite(
                    descriptor,
                    base.advanced(by: written),
                    bytes.count - written,
                    off_t(written)
                )
                if result <= 0 { return false }
                written += result
            }
            return true
        }
        guard writeSucceeded else {
            let code = errno
            close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private func scheduleCommandPoll(after delay: TimeInterval) {
        pollQueue.asyncAfter(deadline: .now() + max(0, delay)) { [weak self] in
            self?.pollForCommand()
        }
    }

    private func pollForCommand() {
        let afterSequence = lock.withLock { () -> UInt64? in
            guard state.started, !state.stopped, !state.pollInFlight else { return nil }
            state.pollInFlight = true
            return state.lastCommandSequence
        }
        guard let afterSequence else { return }
        transport.nextCommand(
            machineID: machineID,
            operationID: operationID,
            afterSequence: afterSequence
        ) { [weak self] found, data, detail in
            self?.receivedCommand(found: found, data: data, detail: detail)
        }
    }

    private func receivedCommand(found: Bool, data: Data, detail: String) {
        var nextDelay: TimeInterval = 1.0 / 60.0
        if found {
            do {
                let command = try DoryVMDisplayCommandCodec.decode(data)
                guard command.machineID == machineID, command.operationID == operationID else {
                    throw DoryVMDisplayWireError.invalidCommand
                }
                let result = commandApplicationLock.withLock { () -> Bool? in
                    let admitted = lock.withLock { () -> Bool in
                        guard state.started, !state.stopped,
                              command.sequence > state.lastCommandSequence else { return false }
                        state.lastCommandSequence = command.sequence
                        return true
                    }
                    return admitted ? commandHandler.apply(command) : nil
                }
                if let applied = result {
                    transport.acknowledgeCommand(
                        machineID: machineID,
                        operationID: operationID,
                        sequence: command.sequence,
                        applied: applied,
                        detail: applied ? "" : "runner-rejected-command"
                    ) { [log] accepted, detail in
                        if !accepted, !detail.isEmpty {
                            log("dory-hv display relay command acknowledgement: \(detail)")
                        }
                    }
                    nextDelay = 0
                }
            } catch {
                log("dory-hv display relay rejected command: \(error)")
                nextDelay = 0.25
            }
        } else if !detail.isEmpty, detail != "no-command" {
            log("dory-hv display relay command poll: \(detail)")
            nextDelay = 0.25
        }
        let shouldContinue = lock.withLock { () -> Bool in
            state.pollInFlight = false
            return state.started && !state.stopped
        }
        if shouldContinue { scheduleCommandPoll(after: nextDelay) }
    }

    func transportInvalidated() {
        let pending = commandApplicationLock.withLock { () -> [PendingFrame]? in
            let pending = lock.withLock { () -> [PendingFrame]? in
                guard !state.stopped else { return nil }
                let pending = Array(state.pending.values)
                state.pending.removeAll(keepingCapacity: false)
                state.stopped = true
                state.pollInFlight = false
                state.cpuSurfaces.removeAll(keepingCapacity: false)
                state.cpuFrameInFlightScanouts.removeAll(keepingCapacity: false)
                state.cpuFrameRefreshPendingScanouts.removeAll(keepingCapacity: false)
                return pending
            }
            guard pending != nil else { return nil }
            commandHandler.revokeFocus()
            commandHandler.releaseInput()
            return pending
        }
        guard let pending else { return }
        for frame in pending {
            frame.complete(presented: false, detail: "display-broker-disconnected")
        }
        log("dory-hv display relay connection invalidated")
    }
}
