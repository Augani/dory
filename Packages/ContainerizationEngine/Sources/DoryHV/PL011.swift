import Foundation

/// ARM PrimeCell PL011 UART with a bounded host-to-guest receive queue.
///
/// Console output lands on the supplied sink. Host input is delivered through ``receive(_:)`` and
/// raises the level-high UART interrupt while both data and a guest receive-interrupt mask are
/// present. Raw-HV uses this path for the same private recovery-console contract as the VZ backend,
/// so a guest remains diagnosable even when Dory Tools are missing or broken.
public final class PL011: MMIODevice {
    public let baseAddress: UInt64
    public let size: UInt64 = 0x1000

    private var control: UInt64 = 0x300
    private var lineControl: UInt64 = 0
    private var integerBaud: UInt64 = 0
    private var fractionalBaud: UInt64 = 0
    private var interruptMask: UInt64 = 0
    private var fifoLevel: UInt64 = 0x12
    private var receiveBytes = [UInt8]()
    private var receiveOffset = 0
    private var interruptAsserted = false
    private let lock = NSLock()
    private let sink: (UInt8) -> Void
    private let setInterrupt: (Bool) -> Void

    private static let receiveInterrupt: UInt64 = 1 << 4
    private static let receiveTimeoutInterrupt: UInt64 = 1 << 6
    private static let maximumBufferedReceiveBytes = 64 * 1_024

    private static let peripheralID: [UInt64] = [0x11, 0x10, 0x14, 0x00]
    private static let cellID: [UInt64] = [0x0D, 0xF0, 0x05, 0xB1]

    public init(
        baseAddress: UInt64,
        sink: @escaping (UInt8) -> Void,
        setInterrupt: @escaping (Bool) -> Void = { _ in }
    ) {
        self.baseAddress = baseAddress
        self.sink = sink
        self.setInterrupt = setInterrupt
    }

    public func read(offset: UInt64, width: Int) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        switch offset {
        case 0x00:
            guard receiveOffset < receiveBytes.count else { return 0 }
            let byte = receiveBytes[receiveOffset]
            receiveOffset += 1
            if receiveOffset == receiveBytes.count {
                receiveBytes.removeAll(keepingCapacity: true)
                receiveOffset = 0
            } else if receiveOffset >= 4_096 {
                receiveBytes.removeFirst(receiveOffset)
                receiveOffset = 0
            }
            refreshInterruptLocked()
            return UInt64(byte)
        case 0x18:
            // FR: TXFE is always set; RXFE is set only when host input has drained.
            return receiveOffset < receiveBytes.count ? 0x80 : 0x90
        case 0x24: return integerBaud
        case 0x28: return fractionalBaud
        case 0x2C: return lineControl
        case 0x30: return control
        case 0x34: return fifoLevel
        case 0x38: return interruptMask
        case 0x3C: return rawInterruptStatusLocked
        case 0x40: return rawInterruptStatusLocked & interruptMask
        case 0xFE0...0xFEC: return Self.peripheralID[Int((offset - 0xFE0) / 4)]
        case 0xFF0...0xFFC: return Self.cellID[Int((offset - 0xFF0) / 4)]
        default: return 0
        }
    }

    public func write(offset: UInt64, value: UInt64, width: Int) {
        if offset == 0x00 {
            sink(UInt8(truncatingIfNeeded: value))
            return
        }
        lock.lock()
        defer { lock.unlock() }
        switch offset {
        case 0x24: integerBaud = value
        case 0x28: fractionalBaud = value
        case 0x2C: lineControl = value
        case 0x30: control = value
        case 0x34: fifoLevel = value
        case 0x38:
            interruptMask = value
            refreshInterruptLocked()
        case 0x44:
            // RX is level-derived from queued bytes, so clearing ICR cannot hide unread input.
            refreshInterruptLocked()
        default: break
        }
    }

    /// Queues one bounded input frame for the guest UART. Returns false without changing state
    /// when the frame would exceed the private recovery console's memory bound.
    @discardableResult
    public func receive(_ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty else { return true }
        lock.lock()
        defer { lock.unlock() }
        let unread = receiveBytes.count - receiveOffset
        guard bytes.count <= Self.maximumBufferedReceiveBytes - unread else { return false }
        if receiveOffset > 0 {
            receiveBytes.removeFirst(receiveOffset)
            receiveOffset = 0
        }
        receiveBytes.append(contentsOf: bytes)
        refreshInterruptLocked()
        return true
    }

    private var rawInterruptStatusLocked: UInt64 {
        receiveOffset < receiveBytes.count
            ? Self.receiveInterrupt | Self.receiveTimeoutInterrupt
            : 0
    }

    private func refreshInterruptLocked() {
        let shouldAssert = rawInterruptStatusLocked & interruptMask != 0
        guard shouldAssert != interruptAsserted else { return }
        interruptAsserted = shouldAssert
        setInterrupt(shouldAssert)
    }
}
