import DoryFSWorkerContracts
import Foundation

/// Event totals wrap modulo 2^64. Depth fields are current gauges; high-watermarks and maximum
/// publication latency retain the largest observation for this device lifetime.
public struct VirtioInputStatistics: Equatable, Sendable {
    public var submittedFrames: UInt64
    public var publishedFrames: UInt64
    public var publishedEvents: UInt64
    public var coalescedMotionFrames: UInt64
    public var droppedFrames: UInt64
    public var rejectedFrames: UInt64
    public var stateReconciliationEvents: UInt64
    public var invalidEventBuffers: UInt64
    public var invalidStatusBuffers: UInt64
    public var statusEvents: UInt64
    public var queueFaults: UInt64
    public var boundedDrainStops: UInt64
    public var workerTurns: UInt64
    public var workerYields: UInt64
    public var coalescedWorkerRequests: UInt64
    public var revokedWorkerTurns: UInt64
    public var pendingFrameSaturationEvents: UInt64
    public var pendingFrameDepth: UInt64
    public var pendingFrameHighWatermark: UInt64
    public var availableEventBufferDepth: UInt64
    public var availableEventBufferHighWatermark: UInt64
    public var eventQueueDepth: UInt64
    public var eventQueueHighWatermark: UInt64
    public var statusQueueDepth: UInt64
    public var statusQueueHighWatermark: UInt64
    public var publicationLatencyNanoseconds: UInt64
    public var maximumPublicationLatencyNanoseconds: UInt64
}

struct VirtioInputLimits: Equatable, Sendable {
    static let production = VirtioInputLimits(
        maximumEventsPerFrame: 64,
        maximumPendingFrames: 256,
        maximumChainsPerWorkerTurn: 64,
        maximumPublishedEventsPerWorkerTurn: 64
    )

    let maximumEventsPerFrame: Int
    let maximumPendingFrames: Int
    let maximumChainsPerWorkerTurn: Int
    let maximumPublishedEventsPerWorkerTurn: Int

    init(
        maximumEventsPerFrame: Int,
        maximumPendingFrames: Int,
        maximumChainsPerWorkerTurn: Int,
        maximumPublishedEventsPerWorkerTurn: Int = 64
    ) {
        precondition(maximumEventsPerFrame >= 2)
        precondition(maximumPendingFrames > 0)
        precondition(maximumChainsPerWorkerTurn > 0)
        precondition(maximumChainsPerWorkerTurn <= Int(Virtqueue.maximumSize))
        precondition(maximumPublishedEventsPerWorkerTurn >= maximumEventsPerFrame)
        precondition(maximumPublishedEventsPerWorkerTurn <= Int(Virtqueue.maximumSize))
        self.maximumEventsPerFrame = maximumEventsPerFrame
        self.maximumPendingFrames = maximumPendingFrames
        self.maximumChainsPerWorkerTurn = maximumChainsPerWorkerTurn
        self.maximumPublishedEventsPerWorkerTurn = maximumPublishedEventsPerWorkerTurn
    }
}

struct VirtioInputWorkerHooks: @unchecked Sendable {
    var beforeWorkerTurn: (@Sendable () -> Void)?
    var beforeEventPublication: (@Sendable () -> Void)?

    static let none = VirtioInputWorkerHooks(
        beforeWorkerTurn: nil,
        beforeEventPublication: nil
    )
}

public struct VirtioInputEvent: Sendable, Equatable {
    public var type: UInt16
    public var code: UInt16
    public var value: Int32

    public init(type: UInt16, code: UInt16, value: Int32) {
        self.type = type
        self.code = code
        self.value = value
    }

    public static let synchronize = VirtioInputEvent(type: 0, code: 0, value: 0)

    fileprivate var bytes: [UInt8] {
        var result = [UInt8]()
        result.append(contentsOf: withUnsafeBytes(of: type.littleEndian, Array.init))
        result.append(contentsOf: withUnsafeBytes(of: code.littleEndian, Array.init))
        result.append(contentsOf: withUnsafeBytes(of: UInt32(bitPattern: value).littleEndian, Array.init))
        return result
    }
}

/// Converts AppKit scroll deltas into Linux evdev wheel events while retaining sub-tick movement.
/// `NSEvent.scrollingDelta*` already incorporates the host's natural-scrolling preference, and
/// Linux `REL_WHEEL*` uses the same sign for the resulting scroll gesture. Inverting here makes a
/// Linux desktop move opposite to the host gesture and also applies natural scrolling twice.
public struct VirtioInputScrollAccumulator: Sendable {
    private var verticalRemainder: Double = 0
    private var horizontalRemainder: Double = 0

    public init() {}

    public mutating func events(
        horizontalDelta: Double,
        verticalDelta: Double,
        hasPreciseDeltas: Bool
    ) -> [VirtioInputEvent] {
        let scale: Double = hasPreciseDeltas ? 12 : 120
        var result = [VirtioInputEvent]()
        Self.appendScrollEvents(
            delta: verticalDelta,
            scale: scale,
            remainder: &verticalRemainder,
            highResolutionCode: 11,
            discreteCode: 8,
            to: &result
        )
        Self.appendScrollEvents(
            delta: horizontalDelta,
            scale: scale,
            remainder: &horizontalRemainder,
            highResolutionCode: 12,
            discreteCode: 6,
            to: &result
        )
        return result
    }

    private static func appendScrollEvents(
        delta: Double,
        scale: Double,
        remainder: inout Double,
        highResolutionCode: UInt16,
        discreteCode: UInt16,
        to result: inout [VirtioInputEvent]
    ) {
        // AppKit values cross a UI/process boundary. NaN, infinity, or a finite value whose scale
        // overflows must never poison the retained remainder or trap an integer conversion.
        guard delta.isFinite else { return }
        let raw = delta * scale
        let integerLimit = Double(Int32.max) - 120
        let bounded: Double
        if raw.isFinite {
            bounded = min(integerLimit, max(-integerLimit, raw))
        } else {
            bounded = raw.sign == .minus ? -integerLimit : integerLimit
        }

        remainder += bounded
        let ticks = Int32(remainder / 120)
        remainder -= Double(ticks) * 120
        let highResolution = Int32(bounded.rounded())
        if highResolution != 0 {
            result.append(VirtioInputEvent(
                type: 2,
                code: highResolutionCode,
                value: highResolution
            ))
        }
        if ticks != 0 {
            result.append(VirtioInputEvent(type: 2, code: discreteCode, value: ticks))
        }
    }
}

/// Tracks key and pointer-button state at the host display boundary. AppKit can deactivate a
/// window without delivering the matching keyUp/mouseUp events, so the frontend drains this state
/// as one atomic release frame whenever its window or application loses focus.
public struct VirtioInputPressedState: Sendable {
    private var pressedCodes = Set<UInt16>()

    public init() {}

    public mutating func record(_ event: VirtioInputEvent) {
        guard event.type == 1 else { return }
        if event.value == 0 {
            pressedCodes.remove(event.code)
        } else if event.value > 0 {
            pressedCodes.insert(event.code)
        }
    }

    public mutating func releaseFrame() -> [VirtioInputEvent] {
        let releases = pressedCodes.sorted().map {
            VirtioInputEvent(type: 1, code: $0, value: 0)
        }
        pressedCodes.removeAll(keepingCapacity: true)
        return releases
    }
}

/// A virtio keyboard or absolute tablet endpoint.
///
/// Linux classifies an input node from its complete capability bitmap. A single node advertising
/// both a full keyboard and absolute pointer axes is not equivalent to two HID devices and can be
/// classified as a keyboard by desktop input stacks, leaving its absolute position disconnected
/// from pointer hit-testing. Production desktop VMs therefore attach one `.keyboard` endpoint and
/// one `.absolutePointer` endpoint, matching the device boundary used by QEMU's virtio keyboard and
/// tablet implementations. `.combinedCompatibility` remains available only for existing callers
/// that need the historical wire shape.
///
/// Host input is submitted as whole evdev frames ending in SYN_REPORT; a frame waits until the
/// guest has posted enough receive buffers, so Dory never delivers half of a pointer update.
public final class VirtioInput: VirtioDeviceBackend, @unchecked Sendable {
    public enum Profile: Sendable, Equatable {
        case keyboard
        case absolutePointer
        case combinedCompatibility
    }

    public let deviceID: UInt32 = 18
    public let deviceFeatures: UInt64 = 0
    public let queueCount = 2
    public let kickSynchronization: VirtioKickSynchronization = .backendManaged

    private enum ConfigSelect {
        static let name: UInt8 = 0x01
        static let serial: UInt8 = 0x02
        static let deviceIDs: UInt8 = 0x03
        static let propertyBits: UInt8 = 0x10
        static let eventBits: UInt8 = 0x11
        static let absoluteInfo: UInt8 = 0x12
    }

    private enum EventType {
        static let synchronize: UInt8 = 0
        static let key: UInt8 = 1
        static let relative: UInt8 = 2
        static let absolute: UInt8 = 3
        static let led: UInt8 = 17
    }

    private struct PendingFrame {
        let events: [VirtioInputEvent]
        let submittedAtNanoseconds: UInt64
    }

    private struct PublicationFrame {
        let chains: [VirtqueueChain]
        let events: [VirtioInputEvent]
        let submittedAtNanoseconds: UInt64?
        let isReconciliation: Bool
    }

    private struct WorkerRequest {
        let generation: UInt64
        let transport: VirtioMMIOTransport
    }

    private enum WorkerDrainOutcome {
        case drained
        case more
        case fault
        case stale
    }

    private let lock = NSLock()
    private let profile: Profile
    private let limits: VirtioInputLimits
    private let workerHooks: VirtioInputWorkerHooks
    private let monotonicNanoseconds: @Sendable () -> UInt64
    private let workerQueue = DispatchQueue(
        label: "com.dory.virtio-input.worker",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem
    )
    private let workerQueueKey = DispatchSpecificKey<UInt8>()
    private weak var transport: VirtioMMIOTransport?
    private var lifecycleGeneration: UInt64 = 1
    private var terminal = false
    private var deviceIsReady = false
    private var queueIsReady = [false, false]
    private var requestedQueueMask: UInt8 = 0
    private var workerScheduled = false
    private var selectedConfig: UInt8 = 0
    private var selectedSubconfig: UInt8 = 0
    private var availableEventBuffers = [VirtqueueChain]()
    private var pendingFrames = [PendingFrame]()
    private var desiredPressedCodes = Set<UInt16>()
    private var publishedPressedCodes = Set<UInt16>()
    private var needsStateReconciliation = false
    private var statisticsState = VirtioInputStatistics(
        submittedFrames: 0,
        publishedFrames: 0,
        publishedEvents: 0,
        coalescedMotionFrames: 0,
        droppedFrames: 0,
        rejectedFrames: 0,
        stateReconciliationEvents: 0,
        invalidEventBuffers: 0,
        invalidStatusBuffers: 0,
        statusEvents: 0,
        queueFaults: 0,
        boundedDrainStops: 0,
        workerTurns: 0,
        workerYields: 0,
        coalescedWorkerRequests: 0,
        revokedWorkerTurns: 0,
        pendingFrameSaturationEvents: 0,
        pendingFrameDepth: 0,
        pendingFrameHighWatermark: 0,
        availableEventBufferDepth: 0,
        availableEventBufferHighWatermark: 0,
        eventQueueDepth: 0,
        eventQueueHighWatermark: 0,
        statusQueueDepth: 0,
        statusQueueHighWatermark: 0,
        publicationLatencyNanoseconds: 0,
        maximumPublicationLatencyNanoseconds: 0
    )
    private let statusHandler: (@Sendable (VirtioInputEvent) -> Void)?

    public convenience init(
        profile: Profile = .combinedCompatibility,
        statusHandler: (@Sendable (VirtioInputEvent) -> Void)? = nil
    ) {
        self.init(profile: profile, limits: .production, statusHandler: statusHandler)
    }

    init(
        profile: Profile,
        limits: VirtioInputLimits,
        statusHandler: (@Sendable (VirtioInputEvent) -> Void)? = nil,
        workerHooks: VirtioInputWorkerHooks = .none,
        monotonicNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        self.profile = profile
        self.limits = limits
        self.statusHandler = statusHandler
        self.workerHooks = workerHooks
        self.monotonicNanoseconds = monotonicNanoseconds
        workerQueue.setSpecific(key: workerQueueKey, value: 1)
    }

    deinit {
        lock.lock()
        terminal = true
        advanceGenerationLocked()
        transport = nil
        deviceIsReady = false
        queueIsReady = [false, false]
        requestedQueueMask = 0
        workerScheduled = false
        availableEventBuffers.removeAll()
        pendingFrames.removeAll()
        updateDepthGaugesLocked()
        lock.unlock()
        if DispatchQueue.getSpecific(key: workerQueueKey) == nil {
            workerQueue.sync {}
        }
    }

    public var configSpace: [UInt8] {
        lock.lock()
        let select = selectedConfig
        let subselect = selectedSubconfig
        lock.unlock()

        var payload = [UInt8]()
        switch select {
        case ConfigSelect.name where subselect == 0:
            payload = Array(deviceName.utf8)
        case ConfigSelect.serial where subselect == 0:
            payload = Array(deviceSerial.utf8)
        case ConfigSelect.deviceIDs where subselect == 0:
            payload.appendLE(UInt16(0x06))  // BUS_VIRTUAL
            payload.appendLE(UInt16(0xD072))
            payload.appendLE(deviceProductID)
            payload.appendLE(profile == .combinedCompatibility ? UInt16(0x0001) : UInt16(0x0002))
        case ConfigSelect.propertyBits where subselect == 0:
            // QEMU's proven virtio-tablet contract omits PROP_BITS entirely. An
            // explicit one-byte zero bitmap is not the same wire shape and can
            // change how Linux input classifiers interpret an absolute device.
            payload = profile == .combinedCompatibility ? [0] : []
        case ConfigSelect.eventBits:
            payload = eventBitmap(type: subselect)
        case ConfigSelect.absoluteInfo
            where profile != .keyboard && (subselect == 0 || subselect == 1):
            payload.appendLE(UInt32(0))
            payload.appendLE(UInt32(32_767))
            payload.appendLE(UInt32(0))
            payload.appendLE(UInt32(0))
            // Match virtio-tablet's unspecified resolution. Advertising an
            // arbitrary physical resolution makes libinput apply dimensions
            // that do not describe this normalized virtual desktop.
            payload.appendLE(profile == .combinedCompatibility ? UInt32(100) : UInt32(0))
        default:
            break
        }

        payload = Array(payload.prefix(128))
        var config = [select, subselect, UInt8(payload.count), 0, 0, 0, 0, 0]
        config.append(contentsOf: payload)
        config.append(contentsOf: repeatElement(0, count: 136 - config.count))
        return config
    }

    public func writeConfig(offset: UInt64, value: UInt64, width: Int) {
        guard offset < 2, width > 0 else { return }
        lock.lock()
        for index in 0..<width {
            let position = Int(offset) + index
            guard position < 2 else { break }
            let byte = UInt8(truncatingIfNeeded: value >> UInt64(index * 8))
            if position == 0 { selectedConfig = byte }
            if position == 1 { selectedSubconfig = byte }
        }
        lock.unlock()
    }

    public func deviceReady(transport: VirtioMMIOTransport) {
        let request: WorkerRequest?
        lock.lock()
        guard !terminal else {
            lock.unlock()
            return
        }
        advanceGenerationLocked()
        self.transport = transport
        deviceIsReady = true
        queueIsReady = transport.queues.map(\.ready)
        requestedQueueMask = 0
        workerScheduled = false
        request = pendingFrames.isEmpty ? nil : requestWorkerLocked(queueMask: 1)
        lock.unlock()
        enqueueWorker(request)
    }

    public func deviceReset(transport: VirtioMMIOTransport) {
        lock.lock()
        advanceGenerationLocked()
        self.transport = nil
        deviceIsReady = false
        queueIsReady = [false, false]
        requestedQueueMask = 0
        workerScheduled = false
        availableEventBuffers.removeAll()
        pendingFrames.removeAll()
        desiredPressedCodes.removeAll()
        publishedPressedCodes.removeAll()
        needsStateReconciliation = false
        updateDepthGaugesLocked()
        statisticsState.eventQueueDepth = 0
        statisticsState.statusQueueDepth = 0
        lock.unlock()
    }

    public func queueStateChanged(queue: Int, ready: Bool, transport: VirtioMMIOTransport) {
        guard (0..<queueCount).contains(queue) else { return }
        let request: WorkerRequest?
        lock.lock()
        guard !terminal else {
            lock.unlock()
            return
        }
        advanceGenerationLocked()
        requestedQueueMask = 0
        workerScheduled = false
        queueIsReady[queue] = ready
        if queue == 0 {
            availableEventBuffers.removeAll()
            if !ready {
                pendingFrames.removeAll()
                desiredPressedCodes.removeAll()
                publishedPressedCodes.removeAll()
                needsStateReconciliation = false
            }
        }
        updateDepthGaugesLocked()
        request = deviceIsReady && self.transport === transport
            ? requestWorkerLocked(queueMask: readyQueueMaskLocked())
            : nil
        lock.unlock()
        enqueueWorker(request)
    }

    public func handleKick(queue: Int, transport: VirtioMMIOTransport) {
        guard (0..<queueCount).contains(queue) else { return }
        scheduleWorker(queueMask: UInt8(1 << queue), transport: transport)
    }

    /// Queues one atomic evdev update. `SYN_REPORT` is appended when the caller omitted it.
    /// This method never acquires the transport lock or walks a guest descriptor. AppKit callers
    /// perform only bounded validation and host-owned queue admission before returning.
    public func send(frame events: [VirtioInputEvent]) {
        guard !events.isEmpty else { return }
        var complete = events
        if complete.last != .synchronize { complete.append(.synchronize) }

        let submittedAt = monotonicNanoseconds()
        let request: WorkerRequest?
        lock.lock()
        guard complete.count <= limits.maximumEventsPerFrame,
              Self.isValidFrame(complete, profile: profile) else {
            statisticsState.rejectedFrames &+= 1
            lock.unlock()
            return
        }
        statisticsState.submittedFrames &+= 1
        Self.applyPressedState(events: complete, to: &desiredPressedCodes)
        if Self.isAbsolutePointerPositionFrame(complete),
           let last = pendingFrames.last,
           Self.isAbsolutePointerPositionFrame(last.events) {
            // AppKit may deliver motion faster than a guest replenishes virtio-input
            // buffers. Only a directly adjacent pure position frame is replaceable: no
            // key, button, or scroll transition can exist between the old and new position.
            pendingFrames[pendingFrames.count - 1] = PendingFrame(
                events: complete,
                submittedAtNanoseconds: submittedAt
            )
            statisticsState.coalescedMotionFrames &+= 1
        } else if pendingFrames.count < limits.maximumPendingFrames {
            pendingFrames.append(PendingFrame(
                events: complete,
                submittedAtNanoseconds: submittedAt
            ))
        } else {
            // The callback is nonblocking and the backlog is bounded. Once saturated, preserve
            // every already-admitted semantic frame in exact order and reject the newest frame.
            // Pressed-state reconciliation repairs a rejected key/button transition when buffers
            // return; scroll transitions are never silently reordered around older input.
            statisticsState.pendingFrameSaturationEvents &+= 1
            statisticsState.droppedFrames &+= 1
            if complete.contains(where: { $0.type == UInt16(EventType.key) }) {
                needsStateReconciliation = true
            }
        }
        updateDepthGaugesLocked()
        request = requestWorkerLocked(queueMask: 1)
        lock.unlock()
        enqueueWorker(request)
    }

    private static func isAbsolutePointerPositionFrame(_ events: [VirtioInputEvent]) -> Bool {
        events.count == 3
            && events[0].type == EventType.absolute
            && events[0].code == 0
            && events[1].type == EventType.absolute
            && events[1].code == 1
            && events[2] == .synchronize
    }

    private static func isValidFrame(_ events: [VirtioInputEvent], profile: Profile) -> Bool {
        guard events.last == .synchronize,
              !events.dropLast().contains(.synchronize) else { return false }
        return events.allSatisfy { event in
            switch event.type {
            case UInt16(EventType.synchronize):
                return event == .synchronize
            case UInt16(EventType.key):
                let supportsCode: Bool
                switch profile {
                case .keyboard:
                    supportsCode = (1...255).contains(event.code)
                case .absolutePointer:
                    supportsCode = (272...276).contains(event.code)
                case .combinedCompatibility:
                    supportsCode = (1...255).contains(event.code)
                        || (272...276).contains(event.code)
                }
                return supportsCode && (0...2).contains(event.value)
            case UInt16(EventType.relative):
                guard profile != .keyboard else { return false }
                return [UInt16(6), 8, 11, 12].contains(event.code)
            case UInt16(EventType.absolute):
                return profile != .keyboard
                    && (event.code == 0 || event.code == 1)
                    && (0...32_767).contains(event.value)
            default:
                return false
            }
        }
    }

    private static func applyPressedState(
        events: [VirtioInputEvent],
        to state: inout Set<UInt16>
    ) {
        for event in events where event.type == UInt16(EventType.key) {
            if event.value == 0 {
                state.remove(event.code)
            } else {
                state.insert(event.code)
            }
        }
    }

    private func advanceGenerationLocked() {
        lifecycleGeneration = lifecycleGeneration == UInt64.max ? 1 : lifecycleGeneration + 1
    }

    private func readyQueueMaskLocked() -> UInt8 {
        queueIsReady.enumerated().reduce(into: UInt8(0)) { mask, element in
            if element.element { mask |= UInt8(1 << element.offset) }
        }
    }

    private func scheduleWorker(queueMask: UInt8, transport: VirtioMMIOTransport) {
        let request: WorkerRequest?
        lock.lock()
        guard self.transport === transport else {
            lock.unlock()
            return
        }
        request = requestWorkerLocked(queueMask: queueMask)
        lock.unlock()
        enqueueWorker(request)
    }

    private func requestWorkerLocked(queueMask: UInt8) -> WorkerRequest? {
        guard !terminal, deviceIsReady, let transport else { return nil }
        let admittedMask = queueMask & readyQueueMaskLocked()
        guard admittedMask != 0 else { return nil }
        requestedQueueMask |= admittedMask
        if workerScheduled {
            statisticsState.coalescedWorkerRequests &+= 1
            return nil
        }
        workerScheduled = true
        return WorkerRequest(generation: lifecycleGeneration, transport: transport)
    }

    private func enqueueWorker(_ request: WorkerRequest?) {
        guard let request else { return }
        let generation = request.generation
        let transport = request.transport
        workerQueue.async { [weak self, weak transport] in
            guard let self, let transport else { return }
            self.runWorker(generation: generation, transport: transport)
        }
    }

    private func runWorker(generation: UInt64, transport: VirtioMMIOTransport) {
        let queueMask: UInt8
        lock.lock()
        guard isCurrentWorkerLocked(generation: generation, transport: transport) else {
            statisticsState.revokedWorkerTurns &+= 1
            lock.unlock()
            return
        }
        queueMask = requestedQueueMask
        requestedQueueMask = 0
        statisticsState.workerTurns &+= 1
        lock.unlock()

        workerHooks.beforeWorkerTurn?()
        var continuationMask: UInt8 = 0
        if queueMask & 1 != 0 {
            switch drainEventQueueTurn(generation: generation, transport: transport) {
            case .more:
                continuationMask |= 1
            case .stale:
                recordRevokedWorkerTurn()
                return
            case .drained, .fault:
                break
            }
        }
        if queueMask & 2 != 0 {
            switch drainStatusQueueTurn(generation: generation, transport: transport) {
            case .more:
                continuationMask |= 2
            case .stale:
                recordRevokedWorkerTurn()
                return
            case .drained, .fault:
                break
            }
        }

        let continuation: WorkerRequest?
        lock.lock()
        guard isCurrentWorkerLocked(generation: generation, transport: transport) else {
            statisticsState.revokedWorkerTurns &+= 1
            lock.unlock()
            return
        }
        requestedQueueMask |= continuationMask
        if requestedQueueMask == 0 {
            workerScheduled = false
            continuation = nil
        } else {
            statisticsState.workerYields &+= 1
            continuation = WorkerRequest(generation: generation, transport: transport)
        }
        lock.unlock()
        enqueueWorker(continuation)
    }

    private func isCurrentWorkerLocked(
        generation: UInt64,
        transport: VirtioMMIOTransport
    ) -> Bool {
        !terminal
            && deviceIsReady
            && workerScheduled
            && lifecycleGeneration == generation
            && self.transport === transport
    }

    private func recordRevokedWorkerTurn() {
        lock.lock()
        statisticsState.revokedWorkerTurns &+= 1
        lock.unlock()
    }

    private func drainEventQueueTurn(
        generation: UInt64,
        transport: VirtioMMIOTransport
    ) -> WorkerDrainOutcome {
        transport.withQueueLock {
            lock.lock()
            let current = isCurrentWorkerLocked(generation: generation, transport: transport)
                && queueIsReady[0]
            lock.unlock()
            guard current else { return .stale }

            let queue = transport.queues[0]
            var wantsInterrupt = false
            defer {
                if wantsInterrupt { transport.notifyUsed() }
            }
            var popped = 0
            var queueFault = false

            do {
                observeGuestQueueDepth(queue: 0, depth: Int(try queue.pendingCount()))
            } catch {
                recordQueueFault()
                return .fault
            }

            while popped < limits.maximumChainsPerWorkerTurn {
                let chain: VirtqueueChain
                do {
                    guard let next = try queue.pop() else { break }
                    chain = next
                } catch {
                    recordQueueFault()
                    queueFault = true
                    break
                }
                popped += 1
                let valid = chain.withLeaseHeld { access in
                    !chain.containsZeroLengthDescriptor
                        && access.readableSegmentCount == 0
                        && access.writableSegmentCount > 0
                        && access.writableByteCount >= 8
                } ?? false
                if valid {
                    lock.lock()
                    availableEventBuffers.append(chain)
                    updateDepthGaugesLocked()
                    lock.unlock()
                } else {
                    lock.lock()
                    statisticsState.invalidEventBuffers &+= 1
                    lock.unlock()
                    do {
                        wantsInterrupt = try queue.push(chain, written: 0) || wantsInterrupt
                    } catch {
                        recordQueueFault()
                        queueFault = true
                        break
                    }
                }
            }

            let guestDepth: Int
            do {
                guestDepth = Int(try queue.pendingCount())
            } catch {
                recordQueueFault()
                queueFault = true
                guestDepth = 0
            }
            observeGuestQueueDepth(queue: 0, depth: guestDepth)
            guard !queueFault else { return .fault }

            var publishedThisTurn = 0
            var publicationFault = false
            while publishedThisTurn < limits.maximumPublishedEventsPerWorkerTurn {
                let publication: PublicationFrame?
                lock.lock()
                publication = selectPublicationLocked(
                    eventBudget: limits.maximumPublishedEventsPerWorkerTurn - publishedThisTurn
                )
                lock.unlock()
                guard let publication else { break }

                workerHooks.beforeEventPublication?()
                var allWritesSucceeded = true
                for (chain, event) in zip(publication.chains, publication.events) {
                    if chain.writeBytes(event.bytes) != 8 {
                        allWritesSucceeded = false
                        break
                    }
                }
                if !allWritesSucceeded {
                    lock.lock()
                    statisticsState.queueFaults &+= 1
                    needsStateReconciliation = true
                    lock.unlock()
                }

                var publishedEntireFrame = allWritesSucceeded
                for (chain, event) in zip(publication.chains, publication.events) {
                    do {
                        wantsInterrupt = try queue.push(
                            chain,
                            written: allWritesSucceeded ? 8 : 0
                        ) || wantsInterrupt
                    } catch {
                        lock.lock()
                        statisticsState.queueFaults &+= 1
                        needsStateReconciliation = true
                        lock.unlock()
                        publicationFault = true
                        publishedEntireFrame = false
                        break
                    }
                    if allWritesSucceeded {
                        lock.lock()
                        Self.applyPressedState(events: [event], to: &publishedPressedCodes)
                        statisticsState.publishedEvents &+= 1
                        if publication.isReconciliation, event != .synchronize {
                            statisticsState.stateReconciliationEvents &+= 1
                        }
                        lock.unlock()
                    }
                }
                publishedThisTurn += publication.events.count
                if publishedEntireFrame {
                    recordPublishedFrame(publication)
                }
                if publicationFault { break }
            }
            guard !publicationFault else { return .fault }

            lock.lock()
            let publishable = hasPublishableFrameLocked()
            lock.unlock()
            let more = guestDepth > 0 || publishable
            if more {
                lock.lock()
                statisticsState.boundedDrainStops &+= 1
                lock.unlock()
                return .more
            }
            return .drained
        }
    }

    private func selectPublicationLocked(eventBudget: Int) -> PublicationFrame? {
        if let frame = pendingFrames.first {
            guard frame.events.count <= eventBudget,
                  availableEventBuffers.count >= frame.events.count else { return nil }
            pendingFrames.removeFirst()
            let chains = Array(availableEventBuffers.prefix(frame.events.count))
            availableEventBuffers.removeFirst(frame.events.count)
            updateDepthGaugesLocked()
            return PublicationFrame(
                chains: chains,
                events: frame.events,
                submittedAtNanoseconds: frame.submittedAtNanoseconds,
                isReconciliation: false
            )
        }
        guard needsStateReconciliation,
              let frame = Self.reconciliationFrames(
                from: publishedPressedCodes,
                to: desiredPressedCodes,
                maximumEventsPerFrame: limits.maximumEventsPerFrame
              ).first,
              frame.count <= eventBudget,
              availableEventBuffers.count >= frame.count else { return nil }
        let chains = Array(availableEventBuffers.prefix(frame.count))
        availableEventBuffers.removeFirst(frame.count)
        updateDepthGaugesLocked()
        return PublicationFrame(
            chains: chains,
            events: frame,
            submittedAtNanoseconds: nil,
            isReconciliation: true
        )
    }

    private func hasPublishableFrameLocked() -> Bool {
        if let frame = pendingFrames.first {
            return availableEventBuffers.count >= frame.events.count
        }
        guard needsStateReconciliation,
              let frame = Self.reconciliationFrames(
                from: publishedPressedCodes,
                to: desiredPressedCodes,
                maximumEventsPerFrame: limits.maximumEventsPerFrame
              ).first else { return false }
        return availableEventBuffers.count >= frame.count
    }

    private func recordPublishedFrame(_ publication: PublicationFrame) {
        let finishedAt = monotonicNanoseconds()
        lock.lock()
        statisticsState.publishedFrames &+= 1
        if let startedAt = publication.submittedAtNanoseconds {
            let latency = finishedAt >= startedAt ? finishedAt - startedAt : 0
            statisticsState.publicationLatencyNanoseconds &+= latency
            statisticsState.maximumPublicationLatencyNanoseconds = max(
                statisticsState.maximumPublicationLatencyNanoseconds,
                latency
            )
        }
        if pendingFrames.isEmpty, publishedPressedCodes == desiredPressedCodes {
            needsStateReconciliation = false
        }
        lock.unlock()
    }

    private func drainStatusQueueTurn(
        generation: UInt64,
        transport: VirtioMMIOTransport
    ) -> WorkerDrainOutcome {
        let result: (outcome: WorkerDrainOutcome, events: [VirtioInputEvent]) =
            transport.withQueueLock {
                lock.lock()
                let current = isCurrentWorkerLocked(
                    generation: generation,
                    transport: transport
                ) && queueIsReady[1]
                lock.unlock()
                guard current else { return (.stale, []) }

                let queue = transport.queues[1]
                var wantsInterrupt = false
                defer {
                    if wantsInterrupt { transport.notifyUsed() }
                }
                var acceptedEvents = [VirtioInputEvent]()
                var popped = 0
                var queueFault = false
                do {
                    observeGuestQueueDepth(queue: 1, depth: Int(try queue.pendingCount()))
                } catch {
                    recordQueueFault()
                    return (.fault, [])
                }
                while popped < limits.maximumChainsPerWorkerTurn {
                    let chain: VirtqueueChain
                    do {
                        guard let next = try queue.pop() else { break }
                        chain = next
                    } catch {
                        recordQueueFault()
                        queueFault = true
                        break
                    }
                    popped += 1
                    let bytes = chain.withLeaseHeld { access -> [UInt8]? in
                        guard !chain.containsZeroLengthDescriptor,
                              access.readableSegmentCount > 0,
                              access.writableSegmentCount == 0,
                              access.readableByteCount >= 8 else { return nil }
                        return access.readBytes(maximum: 8)
                    } ?? nil
                    var event: VirtioInputEvent?
                    if let bytes, bytes.count == 8 {
                        let candidate = VirtioInputEvent(
                            type: bytes.leUInt16(at: 0),
                            code: bytes.leUInt16(at: 2),
                            value: Int32(bitPattern: bytes.leUInt32(at: 4))
                        )
                        if isSupportedStatusEvent(candidate) { event = candidate }
                    }
                    if event == nil {
                        lock.lock()
                        statisticsState.invalidStatusBuffers &+= 1
                        lock.unlock()
                    }
                    do {
                        wantsInterrupt = try queue.push(chain, written: 0) || wantsInterrupt
                    } catch {
                        recordQueueFault()
                        queueFault = true
                        break
                    }
                    if let event { acceptedEvents.append(event) }
                }

                let guestDepth: Int
                do {
                    guestDepth = Int(try queue.pendingCount())
                } catch {
                    recordQueueFault()
                    queueFault = true
                    guestDepth = 0
                }
                observeGuestQueueDepth(queue: 1, depth: guestDepth)
                if queueFault { return (.fault, acceptedEvents) }
                if guestDepth > 0 {
                    lock.lock()
                    statisticsState.boundedDrainStops &+= 1
                    lock.unlock()
                    return (.more, acceptedEvents)
                }
                return (.drained, acceptedEvents)
            }

        var delivered = 0
        for event in result.events {
            lock.lock()
            let current = lifecycleGeneration == generation
                && self.transport === transport
                && deviceIsReady
                && !terminal
            lock.unlock()
            guard current else { break }
            statusHandler?(event)
            delivered += 1
        }
        if delivered > 0 {
            lock.lock()
            statisticsState.statusEvents &+= UInt64(delivered)
            lock.unlock()
        }
        return result.outcome
    }

    private func observeGuestQueueDepth(queue: Int, depth: Int) {
        lock.lock()
        let value = UInt64(max(0, depth))
        if queue == 0 {
            statisticsState.eventQueueDepth = value
            statisticsState.eventQueueHighWatermark = max(
                statisticsState.eventQueueHighWatermark,
                value
            )
        } else {
            statisticsState.statusQueueDepth = value
            statisticsState.statusQueueHighWatermark = max(
                statisticsState.statusQueueHighWatermark,
                value
            )
        }
        lock.unlock()
    }

    private func updateDepthGaugesLocked() {
        statisticsState.pendingFrameDepth = UInt64(pendingFrames.count)
        statisticsState.pendingFrameHighWatermark = max(
            statisticsState.pendingFrameHighWatermark,
            statisticsState.pendingFrameDepth
        )
        statisticsState.availableEventBufferDepth = UInt64(availableEventBuffers.count)
        statisticsState.availableEventBufferHighWatermark = max(
            statisticsState.availableEventBufferHighWatermark,
            statisticsState.availableEventBufferDepth
        )
    }

    private func isSupportedStatusEvent(_ event: VirtioInputEvent) -> Bool {
        profile != .absolutePointer
            && event.type == UInt16(EventType.led)
            && (0...2).contains(event.code)
            && (0...1).contains(event.value)
    }

    private static func reconciliationFrames(
        from published: Set<UInt16>,
        to desired: Set<UInt16>,
        maximumEventsPerFrame: Int
    ) -> [[VirtioInputEvent]] {
        let releases = published.subtracting(desired).sorted().map {
            VirtioInputEvent(type: UInt16(EventType.key), code: $0, value: 0)
        }
        let presses = desired.subtracting(published).sorted().map {
            VirtioInputEvent(type: UInt16(EventType.key), code: $0, value: 1)
        }
        let changes = releases + presses
        guard !changes.isEmpty else { return [] }
        let payloadLimit = maximumEventsPerFrame - 1
        return stride(from: 0, to: changes.count, by: payloadLimit).map { offset in
            var frame = Array(changes[offset..<min(offset + payloadLimit, changes.count)])
            frame.append(.synchronize)
            return frame
        }
    }

    private func recordQueueFault() {
        lock.lock()
        statisticsState.queueFaults &+= 1
        lock.unlock()
    }

    private func eventBitmap(type: UInt8) -> [UInt8] {
        Self.bitmap(type: type, profile: profile)
    }

    private static func bitmap(type: UInt8, profile: Profile) -> [UInt8] {
        switch type {
        case EventType.synchronize:
            return bitmap(codes: [0])
        case EventType.key:
            switch profile {
            case .keyboard:
                return bitmap(codes: Array(1...255))
            case .absolutePointer:
                return bitmap(codes: Array(272...276))
            case .combinedCompatibility:
                return bitmap(codes: Array(1...255) + Array(272...276))
            }
        case EventType.relative:
            switch profile {
            case .keyboard:
                return []
            case .absolutePointer:
                // Dory emits both discrete and high-resolution wheel events in each axis. The
                // capability bitmap must describe the stream Linux actually receives.
                return bitmap(codes: [6, 8, 11, 12])
            case .combinedCompatibility:
                return bitmap(codes: [6, 8, 11, 12])
            }
        case EventType.absolute:
            return profile == .keyboard ? [] : bitmap(codes: [0, 1])
        case EventType.led:
            return profile == .absolutePointer ? [] : bitmap(codes: [0, 1, 2])
        default:
            return []
        }
    }

    private var deviceName: String {
        switch profile {
        case .keyboard: "Dory Virtio Keyboard"
        case .absolutePointer: "Dory Virtio Tablet"
        case .combinedCompatibility: "Dory keyboard and pointer"
        }
    }

    private var deviceSerial: String {
        switch profile {
        case .keyboard: "dory-keyboard-0"
        case .absolutePointer: "dory-tablet-0"
        case .combinedCompatibility: "dory-input-0"
        }
    }

    private var deviceProductID: UInt16 {
        switch profile {
        case .keyboard: 0x0001
        case .absolutePointer: 0x0003
        case .combinedCompatibility: 0x0001
        }
    }

    private static func bitmap(codes: [Int]) -> [UInt8] {
        guard let maximum = codes.max(), maximum >= 0 else { return [] }
        var bytes = [UInt8](repeating: 0, count: maximum / 8 + 1)
        for code in codes where code >= 0 {
            bytes[code / 8] |= UInt8(1 << (code % 8))
        }
        while bytes.last == 0 { bytes.removeLast() }
        return bytes
    }

    public var statistics: VirtioInputStatistics {
        lock.lock()
        defer { lock.unlock() }
        return statisticsState
    }
}
