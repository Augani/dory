import Foundation

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

/// Converts AppKit's content-direction scroll deltas into Linux evdev wheel events while retaining
/// sub-tick movement. AppKit and evdev use opposite signs for the same visible scroll direction.
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
        let vertical = -verticalDelta * scale
        let horizontal = -horizontalDelta * scale
        verticalRemainder += vertical
        horizontalRemainder += horizontal

        let verticalTicks = Int32(verticalRemainder / 120)
        let horizontalTicks = Int32(horizontalRemainder / 120)
        verticalRemainder -= Double(verticalTicks) * 120
        horizontalRemainder -= Double(horizontalTicks) * 120

        var result = [VirtioInputEvent]()
        let verticalHighResolution = Int32(vertical.rounded())
        let horizontalHighResolution = Int32(horizontal.rounded())
        if verticalHighResolution != 0 {
            result.append(VirtioInputEvent(type: 2, code: 11, value: verticalHighResolution))
        }
        if verticalTicks != 0 {
            result.append(VirtioInputEvent(type: 2, code: 8, value: verticalTicks))
        }
        if horizontalHighResolution != 0 {
            result.append(VirtioInputEvent(type: 2, code: 12, value: horizontalHighResolution))
        }
        if horizontalTicks != 0 {
            result.append(VirtioInputEvent(type: 2, code: 6, value: horizontalTicks))
        }
        return result
    }
}

/// A combined virtio keyboard, absolute pointer, buttons, and high-resolution wheel device.
/// Host input is submitted as whole evdev frames ending in SYN_REPORT; a frame waits until the
/// guest has posted enough receive buffers, so Dory never delivers half of a pointer update.
public final class VirtioInput: VirtioDeviceBackend, @unchecked Sendable {
    public let deviceID: UInt32 = 18
    public let deviceFeatures: UInt64 = 0
    public let queueCount = 2

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

    private let lock = NSLock()
    private weak var transport: VirtioMMIOTransport?
    private var selectedConfig: UInt8 = 0
    private var selectedSubconfig: UInt8 = 0
    private var availableEventBuffers = [VirtqueueChain]()
    private var pendingFrames = [[VirtioInputEvent]]()
    private let maximumPendingFrames = 256
    private let statusHandler: (@Sendable (VirtioInputEvent) -> Void)?

    public init(statusHandler: (@Sendable (VirtioInputEvent) -> Void)? = nil) {
        self.statusHandler = statusHandler
    }

    public var configSpace: [UInt8] {
        lock.lock()
        let select = selectedConfig
        let subselect = selectedSubconfig
        lock.unlock()

        var payload = [UInt8]()
        switch select {
        case ConfigSelect.name where subselect == 0:
            payload = Array("Dory keyboard and pointer".utf8)
        case ConfigSelect.serial where subselect == 0:
            payload = Array("dory-input-0".utf8)
        case ConfigSelect.deviceIDs where subselect == 0:
            payload.appendLE(UInt16(0x06))  // BUS_VIRTUAL
            payload.appendLE(UInt16(0xD072))
            payload.appendLE(UInt16(0x0001))
            payload.appendLE(UInt16(0x0001))
        case ConfigSelect.propertyBits where subselect == 0:
            payload = [0]
        case ConfigSelect.eventBits:
            payload = Self.eventBitmap(type: subselect)
        case ConfigSelect.absoluteInfo where subselect == 0 || subselect == 1:
            payload.appendLE(UInt32(0))
            payload.appendLE(UInt32(32_767))
            payload.appendLE(UInt32(0))
            payload.appendLE(UInt32(0))
            payload.appendLE(UInt32(100))
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
        lock.lock()
        self.transport = transport
        lock.unlock()
    }

    public func deviceReset(transport: VirtioMMIOTransport) {
        lock.lock()
        self.transport = nil
        availableEventBuffers.removeAll()
        pendingFrames.removeAll()
        lock.unlock()
    }

    public func queueStateChanged(queue: Int, ready: Bool, transport: VirtioMMIOTransport) {
        guard queue == 0 else { return }
        lock.lock()
        availableEventBuffers.removeAll()
        if !ready { pendingFrames.removeAll() }
        lock.unlock()
    }

    public func handleKick(queue: Int, transport: VirtioMMIOTransport) {
        switch queue {
        case 0:
            drainEventQueue(transport: transport)
        case 1:
            drainStatusQueue(transport: transport)
        default:
            break
        }
    }

    /// Queues one atomic evdev update. `SYN_REPORT` is appended when the caller omitted it.
    public func send(frame events: [VirtioInputEvent]) {
        guard !events.isEmpty else { return }
        var complete = events
        if complete.last != .synchronize { complete.append(.synchronize) }

        lock.lock()
        pendingFrames.append(complete)
        if pendingFrames.count > maximumPendingFrames {
            pendingFrames.removeFirst(pendingFrames.count - maximumPendingFrames)
        }
        let transport = self.transport
        lock.unlock()

        if let transport {
            transport.withQueueLock {
                drainEventQueue(transport: transport)
            }
        }
    }

    private func drainEventQueue(transport: VirtioMMIOTransport) {
        let queue = transport.queues[0]
        var invalidBuffers = [VirtqueueChain]()
        while let chain = (try? queue.pop()) ?? nil {
            let writableCount = chain.writableSegments.reduce(0) { $0 + $1.length }
            if writableCount >= 8 {
                availableEventBuffers.append(chain)
            } else {
                invalidBuffers.append(chain)
            }
        }

        lock.lock()
        var publications = [(VirtqueueChain, VirtioInputEvent)]()
        while let frame = pendingFrames.first, availableEventBuffers.count >= frame.count {
            pendingFrames.removeFirst()
            for event in frame {
                publications.append((availableEventBuffers.removeFirst(), event))
            }
        }
        lock.unlock()

        var interrupt = false
        for chain in invalidBuffers {
            interrupt = ((try? queue.push(chain, written: 0)) ?? false) || interrupt
        }
        for (chain, event) in publications {
            let written = chain.writeBytes(event.bytes)
            interrupt = ((try? queue.push(chain, written: written)) ?? false) || interrupt
        }
        if interrupt { transport.notifyUsed() }
    }

    private func drainStatusQueue(transport: VirtioMMIOTransport) {
        let queue = transport.queues[1]
        var interrupt = false
        while let chain = (try? queue.pop()) ?? nil {
            let bytes = chain.readBytes(maximum: 8)
            if bytes.count == 8 {
                statusHandler?(VirtioInputEvent(
                    type: bytes.leUInt16(at: 0),
                    code: bytes.leUInt16(at: 2),
                    value: Int32(bitPattern: bytes.leUInt32(at: 4))
                ))
            }
            interrupt = ((try? queue.push(chain, written: 0)) ?? false) || interrupt
        }
        if interrupt { transport.notifyUsed() }
    }

    private static func eventBitmap(type: UInt8) -> [UInt8] {
        switch type {
        case EventType.synchronize:
            return bitmap(codes: [0])
        case EventType.key:
            // Standard keyboard range plus primary mouse buttons.
            return bitmap(codes: Array(1...255) + Array(272...276))
        case EventType.relative:
            // Horizontal/vertical wheels and their high-resolution companions.
            return bitmap(codes: [6, 8, 11, 12])
        case EventType.absolute:
            return bitmap(codes: [0, 1])
        case EventType.led:
            return bitmap(codes: [0, 1, 2])
        default:
            return []
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
}
