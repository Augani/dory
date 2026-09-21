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
    ) -> Void
    var topology: @Sendable ([DoryVMDisplayTopologyEntry]) -> Void = { _ in }
    var restartGraphics: @Sendable () -> Void = {}

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
            resize(scanoutID, width, height, physicalWidth, physicalHeight)
            return true
        case .topology:
            guard let displays = command.topology else { return false }
            topology(displays)
            return true
        case .restartGraphics:
            restartGraphics()
            return true
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

    func publish(_ frame: VirtioGPUScanoutFrame) {
        lock.withLock { relay }?.publish(frame)
    }

    func publishCursor(_ update: VirtioGPUCursorUpdate?, scanoutCount: Int) {
        lock.withLock { relay }?.publishCursor(update, scanoutCount: scanoutCount)
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
    ) {
        guard let target = lock.withLock({ target }),
              let gpu = target.gpu,
              let transport = target.transport else { return }
        target.pointerTopology.update(scanoutID: scanoutID, width: width, height: height)
        gpu.updateScanoutSize(
            scanoutID: scanoutID,
            width: width,
            height: height,
            physicalWidthMillimeters: physicalWidthMillimeters,
            physicalHeightMillimeters: physicalHeightMillimeters,
            transport: transport
        )
    }

    func apply(topology: [DoryVMDisplayTopologyEntry]) {
        guard let target = lock.withLock({ target }),
              let gpu = target.gpu,
              let transport = target.transport else { return }
        let sizes = topology.map {
            VirtioGPUScanoutSize(
                width: $0.width,
                height: $0.height,
                physicalWidthMillimeters: $0.physicalWidthMillimeters,
                physicalHeightMillimeters: $0.physicalHeightMillimeters
            )
        }
        for (index, size) in sizes.enumerated() {
            target.pointerTopology.update(
                scanoutID: UInt32(index),
                width: size.width,
                height: size.height
            )
        }
        gpu.updateScanoutTopology(sizes, transport: transport)
    }
}

/// Runner-side owner of app-presented frame leases. A frame remains live in this process until
/// doryd reports that the app either committed or rejected it; only then is the existing GPU host
/// submission completed and the renderer presentation consumer retired.
final class DoryVMDisplayRunnerRelay: @unchecked Sendable {
    private final class PendingFrame: @unchecked Sendable {
        let scanoutID: UInt32
        let descriptor: FileHandle?
        let sharedTextureHandle: MTLSharedTextureHandle?
        let requiresMetalCompletion: Bool
        let completion: @Sendable (Bool, UInt64, String) -> Void

        private let lock = NSLock()
        private var completed = false

        init(
            update: VirtioGPUMetalScanoutUpdate,
            descriptor: FileHandle?,
            sharedTextureHandle: MTLSharedTextureHandle?,
            onPresentationCompleted: @escaping @Sendable (UInt64) -> Void,
            onPresentationFailed: @escaping @Sendable (UInt64, String) -> Void
        ) {
            self.scanoutID = update.scanoutID
            self.descriptor = descriptor
            self.sharedTextureHandle = sharedTextureHandle
            self.requiresMetalCompletion = true
            self.completion = { presented, completionID, detail in
                if presented {
                    update.recordPresentationCompleted(completionID: completionID)
                    update.acceptHostSubmission()
                    onPresentationCompleted(update.presentation.workerGeneration.rawValue)
                } else {
                    update.rejectHostSubmission()
                    onPresentationFailed(update.presentation.workerGeneration.rawValue, detail)
                }
                update.presentation.finishPresentation()
            }
        }

        init(scanoutID: UInt32, descriptor: FileHandle) {
            self.scanoutID = scanoutID
            self.descriptor = descriptor
            self.sharedTextureHandle = nil
            self.requiresMetalCompletion = false
            self.completion = { _, _, _ in }
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
        var lastCommandSequence: UInt64 = 0
        var pending: [UUID: PendingFrame] = [:]
        var cpuSurfaces: [UInt32: CPUFrameSurface] = [:]
        var started = false
        var stopped = false
        var pollInFlight = false
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

    private let machineID: String
    private let operationID: String
    private let transport: any DoryVMDisplayRunnerTransport
    private let commandHandler: DoryVMDisplayRunnerCommandHandler
    private let log: @Sendable (String) -> Void
    private let onPresentationCompleted: @Sendable (UInt64) -> Void
    private let onPresentationFailed: @Sendable (UInt64, String) -> Void
    private let presentationIntervals: DoryVMDisplayPresentationIntervals
    private let pollQueue = DispatchQueue(
        label: "dev.dory.dory-hv.display-command-relay",
        qos: .userInteractive
    )
    private let lock = NSLock()
    private var state = State()

    static func connect(
        machineID: String,
        operationID: UUID,
        serviceName: String,
        commandHandler: DoryVMDisplayRunnerCommandHandler,
        onPresentationCompleted: @escaping @Sendable (UInt64) -> Void = { _ in },
        onPresentationFailed: @escaping @Sendable (UInt64, String) -> Void = { _, _ in },
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
        onPresentationCompleted: @escaping @Sendable (UInt64) -> Void = { _ in },
        onPresentationFailed: @escaping @Sendable (UInt64, String) -> Void = { _, _ in },
        presentationIntervals: DoryVMDisplayPresentationIntervals = .init(),
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.machineID = machineID
        self.operationID = operationID.uuidString.lowercased()
        self.transport = transport
        self.commandHandler = commandHandler
        self.onPresentationCompleted = onPresentationCompleted
        self.onPresentationFailed = onPresentationFailed
        self.presentationIntervals = presentationIntervals
        self.log = log
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
            guard !state.stopped, state.pending[leaseID] == nil else { return false }
            state.pending[leaseID] = pending
            return true
        }
        guard admitted else {
            pending.complete(presented: false, detail: "runner-not-accepting-frames")
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

    /// Relays the copied 2D scanout used by firmware, boot loaders, and early kernel modesetting.
    /// This path is deliberately distinct from renderer-backed presentation: its acknowledgement
    /// never satisfies the synchronized-renderer readiness boundary.
    func publish(_ frame: VirtioGPUScanoutFrame) {
        let snapshot: (sequence: UInt64, surface: CPUFrameSurface)
        do {
            snapshot = try lock.withLock {
                guard !state.stopped, state.nextFrameSequence < UInt64.max else {
                    throw CancellationError()
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
                let fullStride = UInt64(frame.width) * 4
                let fullBytes = fullStride * UInt64(frame.height)
                guard fullStride <= UInt64(UInt32.max),
                      fullBytes <= UInt64(Int.max),
                      fullBytes <= DoryRendererWorkerLimits.production.maximumScanoutBytes else {
                    throw DoryVMDisplayWireError.frameTooLarge
                }
                let resourceGeneration = max(1, frame.resourceGeneration)
                var surface = state.cpuSurfaces[frame.scanoutID]
                if surface?.resourceID != frame.resourceID
                    || surface?.resourceGeneration != resourceGeneration
                    || surface?.format != pixelFormat.rawValue
                    || surface?.width != frame.width
                    || surface?.height != frame.height {
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
                let sequence = state.nextFrameSequence
                state.nextFrameSequence += 1
                return (sequence, surface)
            }

            let descriptor = try Self.makeCPUFrameDescriptor(snapshot.surface.bytes)
            let leaseID = UUID()
            let releaseToken = UUID()
            let lease = try DoryVMDisplayCPUFrameLease(
                leaseID: leaseID,
                releaseToken: releaseToken,
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
                scanoutID: frame.scanoutID,
                sequence: snapshot.sequence,
                displayResourceGeneration: snapshot.surface.resourceGeneration,
                transport: .cpuCopy,
                leasePayload: try DoryVMDisplayCPUFrameLeaseCodec.encode(lease),
                sourceRect: fullRect,
                dirtyRect: fullRect
            )
            let pending = PendingFrame(scanoutID: frame.scanoutID, descriptor: descriptor)
            let admitted = lock.withLock { () -> Bool in
                guard !state.stopped, state.pending[leaseID] == nil else { return false }
                state.pending[leaseID] = pending
                return true
            }
            guard admitted else {
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
        } catch {
            log("dory-hv display relay rejected CPU frame: \(error)")
        }
    }

    func publishCursor(_ update: VirtioGPUCursorUpdate?, scanoutCount: Int) {
        let scanoutIDs: [UInt32]
        if let update {
            scanoutIDs = [update.scanoutID]
        } else {
            scanoutIDs = (0..<max(0, scanoutCount)).map(UInt32.init)
        }
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
        let retirement = lock.withLock { () -> [PendingFrame]? in
            guard !state.stopped else { return nil }
            state.stopped = true
            let pending = Array(state.pending.values)
            state.pending.removeAll(keepingCapacity: false)
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
        guard let pending = lock.withLock({ state.pending.removeValue(forKey: leaseID) }) else {
            return
        }
        let validCompletion = pending.requiresMetalCompletion
            ? presented == (metalCommandBufferCompletionID > 0)
            : metalCommandBufferCompletionID == 0
        let effectivePresented = presented && validCompletion
        let effectiveCompletionID = effectivePresented
            ? metalCommandBufferCompletionID
            : 0
        let effectiveDetail = validCompletion
            ? detail
            : "invalid-metal-command-buffer-completion"
        if effectivePresented, pending.requiresMetalCompletion {
            presentationIntervals.recordPresented(scanoutID: pending.scanoutID)
        }
        pending.complete(
            presented: effectivePresented,
            metalCommandBufferCompletionID: effectiveCompletionID,
            detail: effectiveDetail
        )
        if !effectivePresented, !effectiveDetail.isEmpty {
            log(
                "dory-hv display relay frame \(leaseID.uuidString.lowercased()): "
                    + effectiveDetail
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
                let shouldApply = lock.withLock { () -> Bool in
                    guard command.sequence > state.lastCommandSequence else { return false }
                    state.lastCommandSequence = command.sequence
                    return true
                }
                if shouldApply {
                    let applied = commandHandler.apply(command)
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

    private func transportInvalidated() {
        let pending = lock.withLock { () -> [PendingFrame] in
            let pending = Array(state.pending.values)
            state.pending.removeAll(keepingCapacity: false)
            state.stopped = true
            state.pollInFlight = false
            return pending
        }
        for frame in pending {
            frame.complete(presented: false, detail: "display-broker-disconnected")
        }
        log("dory-hv display relay connection invalidated")
    }
}
