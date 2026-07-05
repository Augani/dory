import Foundation

/// A virtio device backend: owns semantics, the transport owns the rings and registers.
public protocol VirtioDeviceBackend: AnyObject {
    var deviceID: UInt32 { get }
    var deviceFeatures: UInt64 { get }
    var queueCount: Int { get }
    var configSpace: [UInt8] { get }
    /// Called on a queue notify; process available chains and push used ones.
    func handleKick(queue: Int, transport: VirtioMMIOTransport)
    /// Driver finished feature negotiation and set DRIVER_OK.
    func deviceReady(transport: VirtioMMIOTransport)
    func writeConfig(offset: UInt64, value: UInt64, width: Int)
}

extension VirtioDeviceBackend {
    public func deviceReady(transport: VirtioMMIOTransport) {}
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
    private var queueSelect: Int = 0
    private var sharedMemorySelect: UInt32 = 0
    private var status: UInt32 = 0
    private var interruptStatus: UInt32 = 0
    private let interruptLock = NSLock()  // device backends may complete buffers off the vCPU thread
    private let registerLock = NSRecursiveLock()  // SMP: register access and kicks arrive from any vCPU thread
    private var pendingQueueLayout: [(descriptor: UInt64, avail: UInt64, used: UInt64, count: UInt16)]

    private static let magic: UInt64 = 0x7472_6976  // "virt"
    private static let vendor: UInt64 = 0x792D_726F_64  // "dor-y"
    private static let version1Feature: UInt64 = 1 << 32

    public init(
        baseAddress: UInt64,
        backend: VirtioDeviceBackend,
        memory: GuestMemory,
        interrupt: @escaping () -> Void
    ) {
        self.baseAddress = baseAddress
        self.backend = backend
        self.memory = memory
        self.interrupt = interrupt
        self.queues = (0..<backend.queueCount).map { _ in Virtqueue(memory: memory) }
        self.pendingQueueLayout = Array(repeating: (0, 0, 0, 0), count: backend.queueCount)
    }

    /// Signals a used-buffer interrupt to the guest.
    public func notifyUsed() {
        interruptLock.lock()
        interruptStatus |= 1
        interruptLock.unlock()
        interrupt()
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
            let features = backend.deviceFeatures | Self.version1Feature
            return deviceFeatureSelect == 0 ? features & 0xFFFF_FFFF : features >> 32
        case 0x034: return 256  // QueueNumMax
        case 0x044:
            guard queueSelect < queues.count else { return 0 }
            return queues[queueSelect].ready ? 1 : 0
        case 0x060:
            interruptLock.lock()
            defer { interruptLock.unlock() }
            return UInt64(interruptStatus)
        case 0x070: return UInt64(status)
        case 0x0B0: return selectedSharedMemoryRegion?.length.lowUInt32 ?? UInt64(UInt32.max)
        case 0x0B4: return selectedSharedMemoryRegion?.length.highUInt32 ?? UInt64(UInt32.max)
        case 0x0B8: return selectedSharedMemoryRegion?.guestBase.lowUInt32 ?? 0
        case 0x0BC: return selectedSharedMemoryRegion?.guestBase.highUInt32 ?? 0
        case 0x0FC: return 0  // ConfigGeneration
        case 0x100...:
            return readConfig(offset: offset - 0x100, width: width)
        default:
            return 0
        }
    }

    public func write(offset: UInt64, value: UInt64, width: Int) {
        registerLock.lock()
        defer { registerLock.unlock() }
        switch offset {
        case 0x014: deviceFeatureSelect = UInt32(truncatingIfNeeded: value)
        case 0x020:
            if driverFeatureSelect == 0 {
                driverFeatures = (driverFeatures & ~0xFFFF_FFFF) | (value & 0xFFFF_FFFF)
            } else {
                driverFeatures = (driverFeatures & 0xFFFF_FFFF) | (value << 32)
            }
        case 0x024: driverFeatureSelect = UInt32(truncatingIfNeeded: value)
        case 0x030: queueSelect = Int(value)
        case 0x038:
            withSelectedQueue { index in
                pendingQueueLayout[index].count = UInt16(clamping: value)
            }
        case 0x044:
            withSelectedQueue { index in
                if value & 1 == 1 {
                    let layout = pendingQueueLayout[index]
                    queues[index].configure(
                        size: layout.count,
                        descriptorTable: layout.descriptor,
                        availRing: layout.avail,
                        usedRing: layout.used
                    )
                    queues[index].setReady(true)
                } else {
                    queues[index].setReady(false)
                }
            }
        case 0x050:
            let queue = Int(value)
            if queue < queues.count {
                backend.handleKick(queue: queue, transport: self)
            }
        case 0x064:
            interruptLock.lock()
            interruptStatus &= ~UInt32(truncatingIfNeeded: value)
            interruptLock.unlock()
        case 0x070:
            status = UInt32(truncatingIfNeeded: value)
            if status == 0 {
                resetDevice()
            } else if status & 0x4 != 0 {  // DRIVER_OK
                negotiatedFeatures = driverFeatures
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
        for queue in queues { queue.reset() }
        pendingQueueLayout = Array(repeating: (0, 0, 0, 0), count: backend.queueCount)
        interruptStatus = 0
        negotiatedFeatures = 0
        driverFeatures = 0
    }

    private func withSelectedQueue(_ body: (Int) -> Void) {
        guard queueSelect < queues.count else { return }
        body(queueSelect)
    }

    private func merge(_ current: UInt64, low: UInt64) -> UInt64 {
        (current & ~0xFFFF_FFFF) | (low & 0xFFFF_FFFF)
    }

    private func merge(_ current: UInt64, high: UInt64) -> UInt64 {
        (current & 0xFFFF_FFFF) | (high << 32)
    }

    private func readConfig(offset: UInt64, width: Int) -> UInt64 {
        let config = backend.configSpace
        var value: UInt64 = 0
        for byteIndex in 0..<width {
            let position = Int(offset) + byteIndex
            guard position < config.count else { break }
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
