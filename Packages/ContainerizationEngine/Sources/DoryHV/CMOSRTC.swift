import Foundation

/// MC146818-compatible CMOS RTC ports. This provides stable wall-clock values for Linux's early
/// time probe without modeling periodic interrupts or writable CMOS storage.
public final class CMOSRTC: PIODevice {
    public let basePort: UInt16
    public let portCount: UInt16 = 2

    private var selectedRegister: UInt8 = 0
    private let now: @Sendable () -> Date
    private let calendar: Calendar

    public init(basePort: UInt16 = 0x70, now: @escaping @Sendable () -> Date = Date.init) {
        self.basePort = basePort
        self.now = now
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        self.calendar = calendar
    }

    public func read(portOffset: UInt16, width: Int) -> UInt32 {
        switch portOffset {
        case 0: return UInt32(selectedRegister)
        case 1: return UInt32(readSelectedRegister())
        default: return 0xFF
        }
    }

    public func write(portOffset: UInt16, value: UInt32, width: Int) {
        if portOffset == 0 {
            selectedRegister = UInt8(truncatingIfNeeded: value) & 0x7F
        }
    }

    private func readSelectedRegister() -> UInt8 {
        let components = calendar.dateComponents(
            [.second, .minute, .hour, .weekday, .day, .month, .year],
            from: now()
        )
        switch selectedRegister {
        case 0x00: return bcd(components.second ?? 0)
        case 0x02: return bcd(components.minute ?? 0)
        case 0x04: return bcd(components.hour ?? 0)
        case 0x06: return bcd(components.weekday ?? 1)
        case 0x07: return bcd(components.day ?? 1)
        case 0x08: return bcd(components.month ?? 1)
        case 0x09: return bcd((components.year ?? 2000) % 100)
        case 0x0A: return 0x20
        case 0x0B: return 0x02
        case 0x0C: return 0
        case 0x0D: return 0x80
        case 0x32: return bcd((components.year ?? 2000) / 100)
        default: return 0
        }
    }

    private func bcd(_ value: Int) -> UInt8 {
        let clamped = max(0, min(value, 99))
        return UInt8((clamped / 10) << 4 | (clamped % 10))
    }
}
