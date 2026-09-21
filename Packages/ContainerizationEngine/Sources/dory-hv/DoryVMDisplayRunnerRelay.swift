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
        reply: @escaping @Sendable (Bool, String) -> Void
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
        reply: @escaping @Sendable (Bool, String) -> Void
    ) {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            reply(false, "display-broker-error: \(error)")
        }) as? DoryVMDisplayBrokerXPCProtocol else {
            reply(false, "display-broker-proxy-unavailable")
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
    var input: @Sendable (DoryVMDisplayInputEndpoint, [VirtioInputEvent]) -> Void
    var resize: @Sendable (
        UInt32,
        UInt32,
        UInt32,
        UInt16,
        UInt16
    ) -> Void

    func apply(_ command: DoryVMDisplayCommand) {
        switch command.kind {
        case .input:
            guard let endpoint = command.inputEndpoint else { return }
            input(
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
                  let physicalHeight = command.physicalHeightMillimeters else { return }
            resize(scanoutID, width, height, physicalWidth, physicalHeight)
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

    func publishCursor(_ update: VirtioGPUCursorUpdate?, scanoutCount: Int) {
        lock.withLock { relay }?.publishCursor(update, scanoutCount: scanoutCount)
    }

    func start() {
        lock.withLock { relay }?.start()
    }

    func stop() {
        lock.withLock { relay }?.stop()
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
}

/// Runner-side owner of app-presented frame leases. A frame remains live in this process until
/// doryd reports that the app either committed or rejected it; only then is the existing GPU host
/// submission completed and the renderer presentation consumer retired.
final class DoryVMDisplayRunnerRelay: @unchecked Sendable {
    private final class PendingFrame: @unchecked Sendable {
        let update: VirtioGPUMetalScanoutUpdate
        let descriptor: FileHandle?
        let sharedTextureHandle: MTLSharedTextureHandle?
        let onPresentationCompleted: @Sendable (UInt64) -> Void
        let onPresentationFailed: @Sendable (UInt64, String) -> Void

        private let lock = NSLock()
        private var completed = false

        init(
            update: VirtioGPUMetalScanoutUpdate,
            descriptor: FileHandle?,
            sharedTextureHandle: MTLSharedTextureHandle?,
            onPresentationCompleted: @escaping @Sendable (UInt64) -> Void,
            onPresentationFailed: @escaping @Sendable (UInt64, String) -> Void
        ) {
            self.update = update
            self.descriptor = descriptor
            self.sharedTextureHandle = sharedTextureHandle
            self.onPresentationCompleted = onPresentationCompleted
            self.onPresentationFailed = onPresentationFailed
        }

        func complete(presented: Bool, detail: String = "presentation-rejected") {
            let shouldComplete = lock.withLock { () -> Bool in
                guard !completed else { return false }
                completed = true
                return true
            }
            guard shouldComplete else { return }
            if presented {
                update.acceptHostSubmission()
                onPresentationCompleted(update.presentation.workerGeneration.rawValue)
            } else {
                update.rejectHostSubmission()
                onPresentationFailed(update.presentation.workerGeneration.rawValue, detail)
            }
            update.presentation.finishPresentation()
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
        var started = false
        var stopped = false
        var pollInFlight = false
    }

    private let machineID: String
    private let operationID: String
    private let transport: any DoryVMDisplayRunnerTransport
    private let commandHandler: DoryVMDisplayRunnerCommandHandler
    private let log: @Sendable (String) -> Void
    private let onPresentationCompleted: @Sendable (UInt64) -> Void
    private let onPresentationFailed: @Sendable (UInt64, String) -> Void
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
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.machineID = machineID
        self.operationID = operationID.uuidString.lowercased()
        self.transport = transport
        self.commandHandler = commandHandler
        self.onPresentationCompleted = onPresentationCompleted
        self.onPresentationFailed = onPresentationFailed
        self.log = log
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
            ) { [weak self] presented, detail in
                self?.completeFrame(
                    leaseID: leaseID,
                    presented: presented,
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

    private func completeFrame(leaseID: UUID, presented: Bool, detail: String) {
        let pending = lock.withLock { state.pending.removeValue(forKey: leaseID) }
        pending?.complete(presented: presented, detail: detail)
        if !presented, !detail.isEmpty {
            log("dory-hv display relay frame \(leaseID.uuidString.lowercased()): \(detail)")
        }
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
                    commandHandler.apply(command)
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
