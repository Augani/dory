import Foundation

/// ARM PL031 real-time clock, read-only: hands the guest host wall-clock time so certificate
/// validation and image timestamps are correct without an NTP round trip.
public final class PL031: MMIODevice {
    public let baseAddress: UInt64
    public let size: UInt64 = 0x1000

    private static let peripheralID: [UInt64] = [0x31, 0x10, 0x14, 0x00]
    private static let cellID: [UInt64] = [0x0D, 0xF0, 0x05, 0xB1]
    /// The ARM board intentionally does not persist guest RTC writes. `now` is injected only
    /// for deterministic device tests; production reads the host wall clock at every DR/LR read.
    private let now: @Sendable () -> Int64

    public init(
        baseAddress: UInt64,
        now: @escaping @Sendable () -> Int64 = { Int64(time(nil)) }
    ) {
        self.baseAddress = baseAddress
        self.now = now
    }

    public func read(offset: UInt64, width: Int) -> UInt64 {
        switch offset {
        // DR and LR deliberately expose the current host-derived wall clock. The guest cannot
        // alter host time or create persistent time skew through this read-only board device.
        case 0x00, 0x08: return UInt64(max(0, now()))  // DR, LR
        case 0x0C: return 1  // CR: enabled
        case 0xFE0...0xFEC: return Self.peripheralID[Int((offset - 0xFE0) / 4)]
        case 0xFF0...0xFFC: return Self.cellID[Int((offset - 0xFF0) / 4)]
        default: return 0
        }
    }

    public func write(offset: UInt64, value: UInt64, width: Int) {}
}
