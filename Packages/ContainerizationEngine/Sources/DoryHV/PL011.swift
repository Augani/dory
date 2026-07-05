import Foundation

/// ARM PrimeCell PL011 UART, transmit-only. Console output lands on the supplied sink; the guest
/// sees an always-empty receive FIFO and an always-ready transmit FIFO.
public final class PL011: MMIODevice {
    public let baseAddress: UInt64
    public let size: UInt64 = 0x1000

    private var control: UInt64 = 0x300
    private var lineControl: UInt64 = 0
    private var integerBaud: UInt64 = 0
    private var fractionalBaud: UInt64 = 0
    private var interruptMask: UInt64 = 0
    private var fifoLevel: UInt64 = 0x12
    private let sink: (UInt8) -> Void

    private static let peripheralID: [UInt64] = [0x11, 0x10, 0x14, 0x00]
    private static let cellID: [UInt64] = [0x0D, 0xF0, 0x05, 0xB1]

    public init(baseAddress: UInt64, sink: @escaping (UInt8) -> Void) {
        self.baseAddress = baseAddress
        self.sink = sink
    }

    public func read(offset: UInt64, width: Int) -> UInt64 {
        switch offset {
        case 0x00: return 0
        case 0x18: return 0x90  // FR: TXFE | RXFE
        case 0x24: return integerBaud
        case 0x28: return fractionalBaud
        case 0x2C: return lineControl
        case 0x30: return control
        case 0x34: return fifoLevel
        case 0x38: return interruptMask
        case 0x3C, 0x40: return 0  // RIS, MIS
        case 0xFE0...0xFEC: return Self.peripheralID[Int((offset - 0xFE0) / 4)]
        case 0xFF0...0xFFC: return Self.cellID[Int((offset - 0xFF0) / 4)]
        default: return 0
        }
    }

    public func write(offset: UInt64, value: UInt64, width: Int) {
        switch offset {
        case 0x00: sink(UInt8(truncatingIfNeeded: value))
        case 0x24: integerBaud = value
        case 0x28: fractionalBaud = value
        case 0x2C: lineControl = value
        case 0x30: control = value
        case 0x34: fifoLevel = value
        case 0x38: interruptMask = value
        default: break  // ICR and friends: write-ignored
        }
    }
}
