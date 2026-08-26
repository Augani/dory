import Foundation
import Synchronization

public struct VirtioMMIOTransportStatistics: Equatable, Sendable {
    public var queueNotifications: UInt64
    public var queueStateChanges: UInt64
    public var usedInterrupts: UInt64
    public var configurationInterrupts: UInt64
    /// Calls that actually asserted the transport interrupt after coalescing an already-pending
    /// status bit. Request counters above remain the stable record of backend notification demand.
    public var emittedInterruptSignals: UInt64
    public var deviceResets: UInt64

    public init(
        queueNotifications: UInt64,
        queueStateChanges: UInt64,
        usedInterrupts: UInt64,
        configurationInterrupts: UInt64,
        emittedInterruptSignals: UInt64,
        deviceResets: UInt64
    ) {
        self.queueNotifications = queueNotifications
        self.queueStateChanges = queueStateChanges
        self.usedInterrupts = usedInterrupts
        self.configurationInterrupts = configurationInterrupts
        self.emittedInterruptSignals = emittedInterruptSignals
        self.deviceResets = deviceResets
    }
}

/// Defines which layer serializes queue notifications with device lifecycle changes.
public enum VirtioKickSynchronization: Equatable, Sendable {
    /// The transport invokes `handleKick` while holding its register/queue lock. This preserves the
    /// historical behavior and is the safe default for backends that directly touch queue state.
    case transportLocked
    /// The backend accepts kicks after the transport lock is released. It must serialize its own
    /// per-queue drains and use `withQueueLock` plus lifecycle generations around queue access.
    case backendManaged
}

/// A virtio device backend: owns semantics, the transport owns the rings and registers.
public protocol VirtioDeviceBackend: AnyObject {
    var deviceID: UInt32 { get }
    var deviceFeatures: UInt64 { get }
    var queueCount: Int { get }
    var configSpace: [UInt8] { get }
    var kickSynchronization: VirtioKickSynchronization { get }
    /// Called on a queue notify; process available chains and push used ones.
    func handleKick(queue: Int, transport: VirtioMMIOTransport)
    /// Driver finished feature negotiation and set DRIVER_OK.
    func deviceReady(transport: VirtioMMIOTransport)
    /// Driver reset the device. Called while transport access is serialized and before queues are
    /// cleared, so backends can release retained guest buffers and fail outstanding operations.
    func deviceReset(transport: VirtioMMIOTransport)
    /// A QueueReady write changed (or reconfigured) a queue. Called synchronously while transport
    /// access is serialized, after the queue has adopted its new ready state. Backends retaining
    /// guest-owned descriptors must discard them before this callback returns.
    func queueStateChanged(queue: Int, ready: Bool, transport: VirtioMMIOTransport)
    func writeConfig(offset: UInt64, value: UInt64, width: Int)
}

extension VirtioDeviceBackend {
    public var kickSynchronization: VirtioKickSynchronization { .transportLocked }
    public func deviceReady(transport: VirtioMMIOTransport) {}
    public func deviceReset(transport: VirtioMMIOTransport) {}
    public func queueStateChanged(queue: Int, ready: Bool, transport: VirtioMMIOTransport) {}
    public func writeConfig(offset: UInt64, value: UInt64, width: Int) {}
}

public struct VirtioSharedMemoryRegion: Equatable, Sendable {
    public var id: UInt32
    public var guestBase: UInt64
    public var length: UInt64

    public init(id: UInt32, guestBase: UInt64, length: UInt64) {
        self.id = id
        self.guestBase = guestBase
        self.length = length
    }
}

public protocol VirtioSharedMemoryRegionProvider: AnyObject {
    var sharedMemoryRegions: [VirtioSharedMemoryRegion] { get }
}

/// virtio-mmio v2 transport (virtio spec 1.2, section 4.2). One instance per bus slot.
public final class VirtioMMIOTransport: MMIODevice {
    public let baseAddress: UInt64
    public let size: UInt64 = GuestLayout.virtioSlotSize
    public let backend: VirtioDeviceBackend
    public private(set) var queues: [Virtqueue]
    public private(set) var negotiatedFeatures: UInt64 = 0

    private let memory: GuestMemory
    private let interrupt: () -> Void
    private var deviceFeatureSelect: UInt32 = 0
    private var driverFeatureSelect: UInt32 = 0
    private var driverFeatures: UInt64 = 0
    private var queueSelect: UInt64 = 0
    private var sharedMemorySelect: UInt32 = 0
    private var status: UInt32 = 0
    private var interruptStatus: UInt32 = 0
    private var configGeneration: UInt32 = 0
    private let interruptLock = NSLock()  // device backends may complete buffers off the vCPU thread
    private let registerLock = NSRecursiveLock()  // SMP: register access and kicks arrive from any vCPU thread
    private var pendingQueueLayout: [(descriptor: UInt64, avail: UInt64, used: UInt64, count: UInt64)]
    private let queueNotificationCount = Atomic<UInt64>(0)
    private let queueStateChangeCount = Atomic<UInt64>(0)
    private let usedInterruptCount = Atomic<UInt64>(0)
    private let configurationInterruptCount = Atomic<UInt64>(0)
    private let emittedInterruptSignalCount = Atomic<UInt64>(0)
    private let deviceResetCount = Atomic<UInt64>(0)

    private static let magic: UInt64 = 0x7472_6976  // "virt"
    private static let vendor: UInt64 = 0x792D_726F_64  // "dor-y"

    private enum DeviceStatus {
        static let driverOK: UInt32 = 1 << 2
        static let featuresOK: UInt32 = 1 << 3
    }

    private var offeredFeatures: UInt64 {
        backend.deviceFeatures
            | VirtqueueFeature.version1
            | VirtqueueFeature.indirectDescriptors
    }

    private var driverFeaturesAreValid: Bool {
        driverFeatures & VirtqueueFeature.version1 != 0
            && driverFeatures & ~offeredFeatures == 0
    }

    public init(
        baseAddress: UInt64,
        backend: VirtioDeviceBackend,
        memory: GuestMemory,
        queueLimits: VirtqueueLimits = .hardenedDefault,
        interrupt: @escaping () -> Void
    ) {
        self.baseAddress = baseAddress
        self.backend = backend
        self.memory = memory
        self.interrupt = interrupt
        let queueCount = max(0, backend.queueCount)
        self.queues = (0..<queueCount).map { _ in
            Virtqueue(memory: memory, limits: queueLimits)
        }
        self.pendingQueueLayout = Array(repeating: (0, 0, 0, 0), count: queueCount)
    }

    /// Signals a used-buffer interrupt to the guest.
    public func notifyUsed() {
        usedInterruptCount.wrappingAdd(1, ordering: .relaxed)
        publishInterruptStatus(1)
    }

    /// Signals that device configuration visible at 0x100 changed. Virtio drivers distinguish
    /// this from a used-ring interrupt through ISR bit 1 and use ConfigGeneration to take a
    /// coherent snapshot when the host changes multiple fields during one resize.
    public func notifyConfigChange() {
        configurationInterruptCount.wrappingAdd(1, ordering: .relaxed)
        registerLock.lock()
        configGeneration &+= 1
        let shouldEmit = markInterruptPending(2)
        registerLock.unlock()
        if shouldEmit { emitInterruptSignal() }
    }

    public func hostPointer(at guestAddress: UInt64, count: UInt64) throws -> UnsafeMutableRawPointer {
        try memory.hostPointer(at: guestAddress, count: count)
    }

    /// Returns an independently owned, path-free descriptor slice over guest RAM for an isolated
    /// device worker. The transport remains the address-to-backing authority; backends never infer
    /// descriptor offsets from raw host pointers.
    func duplicateGuestMemoryRegion(
        at guestAddress: UInt64,
        count: UInt64
    ) throws -> GuestMemorySharedRegion {
        try memory.duplicateSharedRegion(at: guestAddress, count: count)
    }

    func guestMemoryRegionBounds(
        at guestAddress: UInt64,
        count: UInt64
    ) throws -> (offset: UInt64, length: UInt64, declaredFileSize: UInt64) {
        try memory.sharedRegionBounds(at: guestAddress, count: count)
    }

    func duplicateGuestMemoryBackingDescriptor() throws -> FileHandle {
        try memory.duplicateSharedBackingDescriptor()
    }

    /// Runs `body` holding the register lock, so a device backend draining a queue off the vCPU
    /// thread (virtio-net RX) is serialized against guest MMIO that reconfigures or resets the same
    /// queue. Recursive: safe to call from inside handleKick, which already holds the lock.
    public func withQueueLock<T>(_ body: () -> T) -> T {
        registerLock.lock()
        defer { registerLock.unlock() }
        return body()
    }

    public func read(offset: UInt64, width: Int) -> UInt64 {
        registerLock.lock()
        defer { registerLock.unlock() }
        switch offset {
        case 0x000: return Self.magic
        case 0x004: return 2
        case 0x008: return UInt64(backend.deviceID)
        case 0x00C: return Self.vendor
        case 0x010:
            let features = offeredFeatures
            switch deviceFeatureSelect {
            case 0: return features & 0xFFFF_FFFF
            case 1: return (features >> 32) & 0xFFFF_FFFF
            default: return 0
            }
        case 0x034: return Virtqueue.maximumSize  // QueueNumMax
        case 0x044:
            guard let index = selectedQueueIndex else { return 0 }
            return queues[index].ready ? 1 : 0
        case 0x060:
            interruptLock.lock()
            defer { interruptLock.unlock() }
            return UInt64(interruptStatus)
        case 0x070: return UInt64(status)
        case 0x0B0: return selectedSharedMemoryRegion?.length.lowUInt32 ?? UInt64(UInt32.max)
        case 0x0B4: return selectedSharedMemoryRegion?.length.highUInt32 ?? UInt64(UInt32.max)
        case 0x0B8: return selectedSharedMemoryRegion?.guestBase.lowUInt32 ?? 0
        case 0x0BC: return selectedSharedMemoryRegion?.guestBase.highUInt32 ?? 0
        case 0x0FC: return UInt64(configGeneration)
        case 0x100...:
            return readConfig(offset: offset - 0x100, width: width)
        default:
            return 0
        }
    }

    public func write(offset: UInt64, value: UInt64, width: Int) {
        // Virtio-fs processes independent request queues concurrently and fences every actual ring
        // access itself. Validate the queue number under the transport lock, then invoke that
        // explicitly opted-in backend without pinning unrelated MMIO/reset traffic behind an entire
        // filesystem request. Every other backend retains the historical lock boundary below.
        if offset == 0x050, backend.kickSynchronization == .backendManaged {
            registerLock.lock()
            let queue = Int(exactly: value)
            let shouldKick = queue.map(queues.indices.contains) ?? false
            registerLock.unlock()
            if shouldKick, let queue {
                queueNotificationCount.wrappingAdd(1, ordering: .relaxed)
                backend.handleKick(queue: queue, transport: self)
            }
            return
        }

        registerLock.lock()
        defer { registerLock.unlock() }
        switch offset {
        case 0x014: deviceFeatureSelect = UInt32(truncatingIfNeeded: value)
        case 0x020:
            switch driverFeatureSelect {
            case 0:
                driverFeatures = (driverFeatures & ~0xFFFF_FFFF) | (value & 0xFFFF_FFFF)
            case 1:
                let highWord = value & 0xFFFF_FFFF
                driverFeatures = (driverFeatures & 0xFFFF_FFFF) | (highWord << 32)
            default:
                break
            }
        case 0x024: driverFeatureSelect = UInt32(truncatingIfNeeded: value)
        case 0x030: queueSelect = value
        case 0x038:
            withSelectedQueue { index in
                pendingQueueLayout[index].count = value
            }
        case 0x044:
            withSelectedQueue { index in
                queueStateChangeCount.wrappingAdd(1, ordering: .relaxed)
                let requestedReady = value == 1
                let ready: Bool
                if requestedReady {
                    let layout = pendingQueueLayout[index]
                    ready = queues[index].configure(
                        untrustedSize: layout.count,
                        descriptorTable: layout.descriptor,
                        availRing: layout.avail,
                        usedRing: layout.used
                    )
                        && queues[index].setReady(true)
                } else {
                    queues[index].setReady(false)
                    ready = false
                }
                // QueueReady=1 is also a reconfiguration event when the queue was already ready.
                // Notify on every write so a backend can synchronously revoke retained descriptors
                // and any policy whose safety depends on the old queue epoch.
                backend.queueStateChanged(queue: index, ready: ready, transport: self)
            }
        case 0x050:
            if let queue = Int(exactly: value), queues.indices.contains(queue) {
                queueNotificationCount.wrappingAdd(1, ordering: .relaxed)
                backend.handleKick(queue: queue, transport: self)
            }
        case 0x064:
            interruptLock.lock()
            interruptStatus &= ~UInt32(truncatingIfNeeded: value)
            interruptLock.unlock()
        case 0x070:
            let previousStatus = status
            status = UInt32(truncatingIfNeeded: value)
            if status == 0 {
                resetDevice()
                break
            }

            if status & DeviceStatus.featuresOK != 0 {
                if driverFeaturesAreValid {
                    negotiatedFeatures = driverFeatures
                    for queue in queues {
                        queue.setNegotiatedFeatures(negotiatedFeatures)
                    }
                } else {
                    // Virtio 1.2 section 3.1.1: the device clears FEATURES_OK when it cannot accept
                    // the complete feature set. Never silently mask unsupported driver bits.
                    status &= ~DeviceStatus.featuresOK
                    negotiatedFeatures = 0
                    for queue in queues { queue.setNegotiatedFeatures(0) }
                }
            }

            // DRIVER_OK is meaningful only after the driver observes FEATURES_OK still set. Reject
            // out-of-order readiness and call the backend once on the accepted rising edge.
            if status & DeviceStatus.driverOK != 0,
               status & DeviceStatus.featuresOK == 0 {
                status &= ~DeviceStatus.driverOK
            }
            if status & DeviceStatus.driverOK != 0,
               previousStatus & DeviceStatus.driverOK == 0 {
                backend.deviceReady(transport: self)
            }
        case 0x0AC: sharedMemorySelect = UInt32(truncatingIfNeeded: value)
        case 0x080: withSelectedQueue { pendingQueueLayout[$0].descriptor = merge(pendingQueueLayout[$0].descriptor, low: value) }
        case 0x084: withSelectedQueue { pendingQueueLayout[$0].descriptor = merge(pendingQueueLayout[$0].descriptor, high: value) }
        case 0x090: withSelectedQueue { pendingQueueLayout[$0].avail = merge(pendingQueueLayout[$0].avail, low: value) }
        case 0x094: withSelectedQueue { pendingQueueLayout[$0].avail = merge(pendingQueueLayout[$0].avail, high: value) }
        case 0x0A0: withSelectedQueue { pendingQueueLayout[$0].used = merge(pendingQueueLayout[$0].used, low: value) }
        case 0x0A4: withSelectedQueue { pendingQueueLayout[$0].used = merge(pendingQueueLayout[$0].used, high: value) }
        case 0x100...:
            backend.writeConfig(offset: offset - 0x100, value: value, width: width)
        default:
            break
        }
    }

    private func resetDevice() {
        deviceResetCount.wrappingAdd(1, ordering: .relaxed)
        backend.deviceReset(transport: self)
        for queue in queues { queue.reset() }
        pendingQueueLayout = Array(repeating: (0, 0, 0, 0), count: queues.count)
        interruptLock.lock()
        interruptStatus = 0
        interruptLock.unlock()
        negotiatedFeatures = 0
        driverFeatures = 0
    }

    public var statistics: VirtioMMIOTransportStatistics {
        VirtioMMIOTransportStatistics(
            queueNotifications: queueNotificationCount.load(ordering: .relaxed),
            queueStateChanges: queueStateChangeCount.load(ordering: .relaxed),
            usedInterrupts: usedInterruptCount.load(ordering: .relaxed),
            configurationInterrupts: configurationInterruptCount.load(ordering: .relaxed),
            emittedInterruptSignals: emittedInterruptSignalCount.load(ordering: .relaxed),
            deviceResets: deviceResetCount.load(ordering: .relaxed)
        )
    }

    /// Virtio-MMIO exposes one status bit per event class, not an event count. Keep the bit set
    /// until InterruptACK and emit only when this event class transitions from not-pending to
    /// pending. This suppresses redundant host IRQ injections without losing a distinct event class
    /// that becomes pending while another class is already set.
    private func markInterruptPending(_ bits: UInt32) -> Bool {
        interruptLock.lock()
        let newlyPending = bits & ~interruptStatus
        interruptStatus |= bits
        interruptLock.unlock()
        return newlyPending != 0
    }

    private func publishInterruptStatus(_ bits: UInt32) {
        guard markInterruptPending(bits) else { return }
        emitInterruptSignal()
    }

    private func emitInterruptSignal() {
        emittedInterruptSignalCount.wrappingAdd(1, ordering: .relaxed)
        interrupt()
    }

    private func withSelectedQueue(_ body: (Int) -> Void) {
        guard let index = selectedQueueIndex else { return }
        body(index)
    }

    private var selectedQueueIndex: Int? {
        guard queueSelect < UInt64(queues.count) else { return nil }
        return Int(queueSelect)
    }

    private func merge(_ current: UInt64, low: UInt64) -> UInt64 {
        (current & ~0xFFFF_FFFF) | (low & 0xFFFF_FFFF)
    }

    private func merge(_ current: UInt64, high: UInt64) -> UInt64 {
        (current & 0xFFFF_FFFF) | (high << 32)
    }

    private func readConfig(offset: UInt64, width: Int) -> UInt64 {
        let config = backend.configSpace
        guard width > 0, let start = Int(exactly: offset), start < config.count else { return 0 }
        var value: UInt64 = 0
        for byteIndex in 0..<min(width, MemoryLayout<UInt64>.size) {
            let (position, overflow) = start.addingReportingOverflow(byteIndex)
            guard !overflow, position < config.count else { break }
            value |= UInt64(config[position]) << (8 * byteIndex)
        }
        return value
    }

    private var selectedSharedMemoryRegion: VirtioSharedMemoryRegion? {
        (backend as? VirtioSharedMemoryRegionProvider)?.sharedMemoryRegions.first { $0.id == sharedMemorySelect }
    }
}

private extension UInt64 {
    var lowUInt32: UInt64 { self & 0xFFFF_FFFF }
    var highUInt32: UInt64 { self >> 32 }
}

extension VirtioMMIOTransport: @unchecked Sendable {}
