import DoryDBTX86
import DoryMachinePC
import Foundation
import Testing

@Suite struct DoryPCRTCTests {
  @Test func exposesUTCWallClockInBCDAndBinaryModes() throws {
    let rtc = DoryPCRTC146818(initialDate: utcDate(2026, 8, 30, 21, 47, 58))

    #expect(try read(rtc, 0x00) == 0x58)
    #expect(try read(rtc, 0x02) == 0x47)
    #expect(try read(rtc, 0x04) == 0x21)
    #expect(try read(rtc, 0x07) == 0x30)
    #expect(try read(rtc, 0x08) == 0x08)
    #expect(try read(rtc, 0x09) == 0x26)
    #expect(try read(rtc, 0x32) == 0x20)

    try write(rtc, 0x0B, 0x06)
    #expect(try read(rtc, 0x00) == 58)
    #expect(try read(rtc, 0x04) == 21)
    #expect(try read(rtc, 0x09) == 26)
  }

  @Test func supportsTwelveHourModeAndGuestCalendarWrites() throws {
    let rtc = DoryPCRTC146818(initialDate: utcDate(2026, 8, 30, 21, 47, 58))
    try write(rtc, 0x0B, 0x00)
    #expect(try read(rtc, 0x04) == 0x89)

    try write(rtc, 0x0B, 0x82)
    try write(rtc, 0x00, 0x12)
    try write(rtc, 0x02, 0x34)
    try write(rtc, 0x04, 0x05)
    try write(rtc, 0x07, 0x14)
    try write(rtc, 0x08, 0x02)
    try write(rtc, 0x09, 0x27)
    try write(rtc, 0x32, 0x20)
    try write(rtc, 0x0B, 0x02)

    let components = utcCalendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second],
      from: rtc.snapshot().date
    )
    #expect(components.year == 2027)
    #expect(components.month == 2)
    #expect(components.day == 14)
    #expect(components.hour == 5)
    #expect(components.minute == 34)
    #expect(components.second == 12)
  }

  @Test func advancesDeterministicallyAndRaisesClearOnReadEvents() throws {
    let rtc = DoryPCRTC146818(initialDate: utcDate(2026, 8, 30, 21, 47, 58))
    let levels = LockedLevels()
    rtc.connectInterruptSink { levels.append($0) }
    try write(rtc, 0x0B, 0x52)

    rtc.advance(by: 32)
    #expect(try read(rtc, 0x0C) == 0xC0)

    rtc.advance(by: DoryPCRTC146818.oscillatorFrequency - 32)
    #expect(try read(rtc, 0x00) == 0x59)
    #expect(try read(rtc, 0x0C) == 0xD0)
    #expect(levels.values == [false, true, false, true, false])
  }

  @Test func alarmInterruptUsesDontCareFields() throws {
    let rtc = DoryPCRTC146818(initialDate: utcDate(2026, 8, 30, 21, 47, 58))
    try write(rtc, 0x01, 0x59)
    try write(rtc, 0x03, 0xC0)
    try write(rtc, 0x05, 0xC0)
    try write(rtc, 0x0B, 0x22)

    rtc.advance(by: DoryPCRTC146818.oscillatorFrequency)
    #expect(try read(rtc, 0x0C) == 0xF0)
  }

  @Test func calculatesTheNextEnabledInterruptDeadline() throws {
    let rtc = DoryPCRTC146818(initialDate: utcDate(2026, 8, 30, 21, 47, 58))
    #expect(rtc.ticksUntilNextInterrupt() == nil)

    try write(rtc, 0x0B, 0x42)
    #expect(rtc.ticksUntilNextInterrupt() == 32)
    rtc.advance(by: 7)
    #expect(rtc.ticksUntilNextInterrupt() == 25)
    _ = try read(rtc, 0x0C)

    try write(rtc, 0x0B, 0x12)
    #expect(rtc.ticksUntilNextInterrupt() == DoryPCRTC146818.oscillatorFrequency - 7)

    try write(rtc, 0x01, 0x00)
    try write(rtc, 0x03, 0x48)
    try write(rtc, 0x05, 0x21)
    try write(rtc, 0x0B, 0x22)
    #expect(rtc.ticksUntilNextInterrupt() == 2 * DoryPCRTC146818.oscillatorFrequency - 7)
  }

  @Test func machineRoutesRTCInterruptToLegacyIRQ8AndIOAPICPin8() throws {
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      initialRTCDate: utcDate(2026, 8, 30, 21, 47, 58)
    )
    try machine.localAPIC.configureSpuriousVector(0xFF, softwareEnabled: true)
    try machine.ioAPIC.configure(
      pin: 8,
      route: .init(
        vector: 0x38,
        destinationAPICID: 0,
        masked: false,
        levelTriggered: true
      )
    )
    try write(machine.rtc, 0x0B, 0x42)

    machine.rtc.advance(by: 32)

    #expect(machine.legacyPIC.snapshot().slaveRequest & 1 != 0)
    #expect(machine.localAPIC.snapshot().interruptRequest.contains(0x38))
    _ = try read(machine.rtc, 0x0C)
    #expect(machine.localAPIC.acknowledge(interruptsEnabled: true) == 0x38)
    #expect(machine.localAPIC.endOfInterrupt() == 0x38)
    try machine.ioAPIC.endOfInterrupt(vector: 0x38, destinationAPICID: 0)
    #expect(machine.localAPIC.acknowledge(interruptsEnabled: true) == nil)
  }

  @Test func indexPortTracksTheNMIEnableBit() throws {
    let rtc = DoryPCRTC146818(initialDate: utcDate(2026, 8, 30, 21, 47, 58))
    try rtc.write(portOffset: 0, value: 0x89, width: .byte)
    #expect(try rtc.read(portOffset: 0, width: .byte) == 0x89)
    #expect(rtc.snapshot().selectedRegister == 9)
    #expect(rtc.snapshot().nmiDisabled)
  }

  private func read(_ rtc: DoryPCRTC146818, _ register: UInt8) throws -> UInt8 {
    try rtc.write(portOffset: 0, value: UInt32(register), width: .byte)
    return UInt8(truncatingIfNeeded: try rtc.read(portOffset: 1, width: .byte))
  }

  private func write(_ rtc: DoryPCRTC146818, _ register: UInt8, _ value: UInt8) throws {
    try rtc.write(portOffset: 0, value: UInt32(register), width: .byte)
    try rtc.write(portOffset: 1, value: UInt32(value), width: .byte)
  }

  private func utcDate(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    _ hour: Int,
    _ minute: Int,
    _ second: Int
  ) -> Date {
    utcCalendar.date(
      from: .init(
        calendar: utcCalendar,
        timeZone: utcCalendar.timeZone,
        year: year,
        month: month,
        day: day,
        hour: hour,
        minute: minute,
        second: second
      ))!
  }

  private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }
}

private final class LockedLevels: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [Bool] = []

  var values: [Bool] { lock.withLock { storage } }
  func append(_ value: Bool) { lock.withLock { storage.append(value) } }
}
