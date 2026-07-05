import Foundation

/// Minimal 16550A-compatible UART for the x86 boot console. The guest sees an always-empty
/// receiver and an always-ready transmitter; bytes written to THR are forwarded to `sink`.
public final class UART16550: PIODevice {
    public let basePort: UInt16
    public let portCount: UInt16 = 8

    private var interruptEnable: UInt8 = 0
    private var interruptIdentification: UInt8 = 0x01
    private var fifoControl: UInt8 = 0
    private var lineControl: UInt8 = 0
    private var modemControl: UInt8 = 0
    private var scratch: UInt8 = 0
    private var divisorLatchLow: UInt8 = 0x0C
    private var divisorLatchHigh: UInt8 = 0
    private let sink: (UInt8) -> Void

    public init(basePort: UInt16 = 0x3F8, sink: @escaping (UInt8) -> Void) {
        self.basePort = basePort
        self.sink = sink
    }

    public func read(portOffset: UInt16, width: Int) -> UInt32 {
        UInt32(readByte(portOffset: portOffset))
    }

    public func write(portOffset: UInt16, value: UInt32, width: Int) {
        writeByte(portOffset: portOffset, value: UInt8(truncatingIfNeeded: value))
    }

    private var divisorLatchAccess: Bool {
        lineControl & 0x80 != 0
    }

    private func readByte(portOffset: UInt16) -> UInt8 {
        switch portOffset {
        case 0 where divisorLatchAccess: return divisorLatchLow
        case 0: return 0
        case 1 where divisorLatchAccess: return divisorLatchHigh
        case 1: return interruptEnable
        case 2: return interruptIdentification
        case 3: return lineControl
        case 4: return modemControl
        case 5: return 0x60
        case 6: return 0xB0
        case 7: return scratch
        default: return 0xFF
        }
    }

    private func writeByte(portOffset: UInt16, value: UInt8) {
        switch portOffset {
        case 0 where divisorLatchAccess: divisorLatchLow = value
        case 0: sink(value)
        case 1 where divisorLatchAccess: divisorLatchHigh = value
        case 1: interruptEnable = value
        case 2:
            fifoControl = value
            interruptIdentification = 0x01
        case 3: lineControl = value
        case 4: modemControl = value
        case 7: scratch = value
        default: break
        }
    }
}
