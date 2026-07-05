import Foundation

/// ARM PL031 real-time clock, read-only: hands the guest host wall-clock time so certificate
/// validation and image timestamps are correct without an NTP round trip.
public final class PL031: MMIODevice {
    public let baseAddress: UInt64
    public let size: UInt64 = 0x1000

    private static let peripheralID: [UInt64] = [0x31, 0x10, 0x14, 0x00]
    private static let cellID: [UInt64] = [0x0D, 0xF0, 0x05, 0xB1]

    public init(baseAddress: UInt64) {
        self.baseAddress = baseAddress
    }

    public func read(offset: UInt64, width: Int) -> UInt64 {
        switch offset {
        case 0x00, 0x08: return UInt64(max(0, time(nil)))  // DR, LR
        case 0x0C: return 1  // CR: enabled
        case 0xFE0...0xFEC: return Self.peripheralID[Int((offset - 0xFE0) / 4)]
        case 0xFF0...0xFFC: return Self.cellID[Int((offset - 0xFF0) / 4)]
        default: return 0
        }
    }

    public func write(offset: UInt64, value: UInt64, width: Int) {}
}
