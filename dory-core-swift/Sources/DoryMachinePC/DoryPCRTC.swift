import DoryDBTX86
import Foundation

public struct DoryPCRTCSnapshot: Sendable, Hashable {
  public let selectedRegister: UInt8
  public let nmiDisabled: Bool
  public let date: Date
  public let statusA: UInt8
  public let statusB: UInt8
  public let statusC: UInt8
}

/// Motorola MC146818-compatible real-time clock and CMOS register file.
///
/// The clock runs from a deterministic 32,768 Hz oscillator. The machine advances that oscillator
/// explicitly, which makes periodic, alarm, and update interrupts replayable while still allowing a
/// caller to choose the initial wall-clock instant.
public final class DoryPCRTC146818: DoryPCPortIODevice, @unchecked Sendable {
  public static let oscillatorFrequency: UInt64 = 32_768

  public let basePort: UInt16 = 0x70
  public let portCount: UInt16 = 2

  private let lock = NSLock()
  private var calendar: Calendar
  private var date: Date
  private var selectedRegister: UInt8 = 0
  private var nmiDisabled = false
  private var statusA: UInt8 = 0x26
  private var statusB: UInt8 = 0x02
  private var statusC: UInt8 = 0
  private var cmos = [UInt8](repeating: 0, count: 128)
  private var oscillatorTicks: UInt64 = 0
  private var interruptSink: (@Sendable (Bool) -> Void)?
  private var lastInterruptLevel = false

  public init(initialDate: Date = Date()) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    self.calendar = calendar
    date = initialDate
    cmos[0x0D] = 0x80
  }

  public func connectInterruptSink(_ sink: @escaping @Sendable (Bool) -> Void) {
    let level = lock.withLock {
      interruptSink = sink
      let level = interruptLevelLocked()
      lastInterruptLevel = level
      return level
    }
    sink(level)
  }

  public func advance(by ticks: UInt64) {
    guard ticks > 0 else { return }
    let notification = lock.withLock {
      let oldTicks = oscillatorTicks
      oscillatorTicks &+= ticks
      raisePeriodicInterruptsLocked(from: oldTicks, through: oscillatorTicks)
      advanceCalendarLocked(from: oldTicks, through: oscillatorTicks)
      return interruptNotificationLocked()
    }
    notify(notification)
  }

  public func snapshot() -> DoryPCRTCSnapshot {
    lock.withLock {
      .init(
        selectedRegister: selectedRegister,
        nmiDisabled: nmiDisabled,
        date: date,
        statusA: statusA,
        statusB: statusB,
        statusC: statusC
      )
    }
  }

  /// Returns oscillator ticks until the next enabled RTC event can assert IRQ8. This lets a halted
  /// virtual CPU jump directly to the next deterministic device deadline instead of busy waiting.
  public func ticksUntilNextInterrupt() -> UInt64? {
    lock.withLock {
      if interruptLevelLocked() { return 0 }
      var candidates: [UInt64] = []
      let phase = oscillatorTicks % Self.oscillatorFrequency
      let ticksToNextSecond =
        phase == 0 ? Self.oscillatorFrequency : Self.oscillatorFrequency - phase

      let rate = statusA & 0x0F
      if statusB & 0x40 != 0, rate >= 3, rate <= 15 {
        let period = UInt64(1) << UInt64(rate - 1)
        let periodicPhase = oscillatorTicks % period
        candidates.append(periodicPhase == 0 ? period : period - periodicPhase)
      }
      if !updatesInhibited, statusB & 0x10 != 0 {
        candidates.append(ticksToNextSecond)
      }
      if !updatesInhibited, statusB & 0x20 != 0 {
        for seconds in 1...86_400 {
          guard let candidateDate = calendar.date(byAdding: .second, value: seconds, to: date)
          else { break }
          if alarmMatchesLocked(at: candidateDate) {
            candidates.append(
              ticksToNextSecond + UInt64(seconds - 1) * Self.oscillatorFrequency
            )
            break
          }
        }
      }
      return candidates.min()
    }
  }

  public func read(portOffset: UInt16, width: DoryX86OperandWidth) throws -> UInt32 {
    guard width == .byte else { throw DoryPCPortIOError.unsupportedWidth(width) }
    guard portOffset == 1 else {
      return UInt32(selectedRegister | (nmiDisabled ? 0x80 : 0))
    }
    let (value, notification) = lock.withLock {
      let value = readRegisterLocked(selectedRegister)
      return (value, interruptNotificationLocked())
    }
    notify(notification)
    return UInt32(value)
  }

  public func write(
    portOffset: UInt16,
    value: UInt32,
    width: DoryX86OperandWidth
  ) throws {
    guard width == .byte else { throw DoryPCPortIOError.unsupportedWidth(width) }
    let byte = UInt8(truncatingIfNeeded: value)
    guard portOffset == 1 else {
      lock.withLock {
        selectedRegister = byte & 0x7F
        nmiDisabled = byte & 0x80 != 0
      }
      return
    }
    let notification = lock.withLock {
      writeRegisterLocked(selectedRegister, value: byte)
      return interruptNotificationLocked()
    }
    notify(notification)
  }

  private var binaryMode: Bool { statusB & 0x04 != 0 }
  private var twentyFourHourMode: Bool { statusB & 0x02 != 0 }
  private var updatesInhibited: Bool { statusB & 0x80 != 0 }

  private func readRegisterLocked(_ register: UInt8) -> UInt8 {
    switch register {
    case 0x00: return encode(calendar.component(.second, from: date))
    case 0x02: return encode(calendar.component(.minute, from: date))
    case 0x04: return encodeHour(calendar.component(.hour, from: date))
    case 0x06:
      // RTC weekdays are one-based with Sunday == 1, matching Foundation's Gregorian calendar.
      return encode(calendar.component(.weekday, from: date))
    case 0x07: return encode(calendar.component(.day, from: date))
    case 0x08: return encode(calendar.component(.month, from: date))
    case 0x09: return encode(calendar.component(.year, from: date) % 100)
    case 0x0A: return statusA & 0x7F
    case 0x0B: return statusB
    case 0x0C:
      let value = statusC
      statusC = 0
      return value
    case 0x0D: return 0x80
    case 0x32: return encode(calendar.component(.year, from: date) / 100)
    default: return cmos[Int(register)]
    }
  }

  private func writeRegisterLocked(_ register: UInt8, value: UInt8) {
    switch register {
    case 0x00: setDateComponent(.second, value: decode(value), validRange: 0...59)
    case 0x01, 0x03, 0x05: cmos[Int(register)] = value
    case 0x02: setDateComponent(.minute, value: decode(value), validRange: 0...59)
    case 0x04: setDateComponent(.hour, value: decodeHour(value), validRange: 0...23)
    case 0x06: break
    case 0x07: setDateComponent(.day, value: decode(value), validRange: 1...31)
    case 0x08: setDateComponent(.month, value: decode(value), validRange: 1...12)
    case 0x09:
      let century = calendar.component(.year, from: date) / 100
      setDateComponent(.year, value: century * 100 + decode(value), validRange: 1...9999)
    case 0x0A: statusA = (statusA & 0x80) | (value & 0x7F)
    case 0x0B: statusB = value
    case 0x0C, 0x0D: break
    case 0x32:
      let year = calendar.component(.year, from: date) % 100
      setDateComponent(.year, value: decode(value) * 100 + year, validRange: 1...9999)
    default: cmos[Int(register)] = value
    }
  }

  private func advanceCalendarLocked(from oldTicks: UInt64, through newTicks: UInt64) {
    guard !updatesInhibited else { return }
    let oldSeconds = oldTicks / Self.oscillatorFrequency
    let newSeconds = newTicks / Self.oscillatorFrequency
    guard newSeconds > oldSeconds else { return }
    for _ in oldSeconds..<newSeconds {
      guard let next = calendar.date(byAdding: .second, value: 1, to: date) else { break }
      date = next
      var event: UInt8 = 0x10
      if alarmMatchesLocked(at: date) { event |= 0x20 }
      if event & statusB & 0x70 != 0 { statusC |= 0x80 }
      statusC |= event
    }
  }

  private func raisePeriodicInterruptsLocked(from oldTicks: UInt64, through newTicks: UInt64) {
    let rate = statusA & 0x0F
    guard rate >= 3, rate <= 15 else { return }
    let period = UInt64(1) << UInt64(rate - 1)
    guard oldTicks / period != newTicks / period else { return }
    statusC |= 0x40
    if statusB & 0x40 != 0 { statusC |= 0x80 }
  }

  private func alarmMatchesLocked(at candidateDate: Date) -> Bool {
    alarmFieldMatches(
      cmos[0x01],
      value: calendar.component(.second, from: candidateDate),
      hour: false
    )
      && alarmFieldMatches(
        cmos[0x03],
        value: calendar.component(.minute, from: candidateDate),
        hour: false
      )
      && alarmFieldMatches(
        cmos[0x05],
        value: calendar.component(.hour, from: candidateDate),
        hour: true
      )
  }

  private func alarmFieldMatches(_ field: UInt8, value: Int, hour: Bool) -> Bool {
    guard field & 0xC0 != 0xC0 else { return true }
    return hour ? decodeHour(field) == value : decode(field) == value
  }

  private func setDateComponent(
    _ component: Calendar.Component,
    value: Int,
    validRange: ClosedRange<Int>
  ) {
    guard validRange.contains(value) else { return }
    var components = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second],
      from: date
    )
    components.calendar = calendar
    components.timeZone = calendar.timeZone
    components.setValue(value, for: component)
    guard let updated = calendar.date(from: components) else { return }
    date = updated
  }

  private func encode(_ value: Int) -> UInt8 {
    if binaryMode { return UInt8(truncatingIfNeeded: value) }
    return UInt8((value / 10) << 4 | (value % 10))
  }

  private func decode(_ value: UInt8) -> Int {
    if binaryMode { return Int(value) }
    return Int(value >> 4) * 10 + Int(value & 0x0F)
  }

  private func encodeHour(_ hour: Int) -> UInt8 {
    guard !twentyFourHourMode else { return encode(hour) }
    let isPM = hour >= 12
    let twelveHour = hour % 12 == 0 ? 12 : hour % 12
    return encode(twelveHour) | (isPM ? 0x80 : 0)
  }

  private func decodeHour(_ value: UInt8) -> Int {
    guard !twentyFourHourMode else { return decode(value) }
    let twelveHour = decode(value & 0x7F)
    return (twelveHour % 12) + (value & 0x80 != 0 ? 12 : 0)
  }

  private func interruptLevelLocked() -> Bool { statusC & 0x80 != 0 }

  private func interruptNotificationLocked() -> (sink: (@Sendable (Bool) -> Void), level: Bool)? {
    let level = interruptLevelLocked()
    guard level != lastInterruptLevel else { return nil }
    lastInterruptLevel = level
    return interruptSink.map { ($0, level) }
  }

  private func notify(_ notification: (sink: (@Sendable (Bool) -> Void), level: Bool)?) {
    if let notification { notification.sink(notification.level) }
  }
}
