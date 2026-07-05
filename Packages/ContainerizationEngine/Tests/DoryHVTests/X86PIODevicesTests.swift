import Foundation
import Testing
@testable import DoryHV

@Suite struct UART16550Tests {
    @Test func transmitsBytesAndReportsReadyLineStatus() {
        var output = [UInt8]()
        let uart = UART16550 { output.append($0) }

        uart.write(portOffset: 0, value: UInt32(UInt8(ascii: "O")), width: 1)
        uart.write(portOffset: 0, value: UInt32(UInt8(ascii: "K")), width: 1)

        #expect(output == [UInt8(ascii: "O"), UInt8(ascii: "K")])
        #expect(uart.read(portOffset: 5, width: 1) == 0x60)
        #expect(uart.read(portOffset: 2, width: 1) == 0x01)
    }

    @Test func divisorLatchShadowsDataAndInterruptRegisters() {
        var output = [UInt8]()
        let uart = UART16550 { output.append($0) }

        uart.write(portOffset: 3, value: 0x80, width: 1)
        uart.write(portOffset: 0, value: 0x34, width: 1)
        uart.write(portOffset: 1, value: 0x12, width: 1)

        #expect(output.isEmpty)
        #expect(uart.read(portOffset: 0, width: 1) == 0x34)
        #expect(uart.read(portOffset: 1, width: 1) == 0x12)

        uart.write(portOffset: 3, value: 0x03, width: 1)
        uart.write(portOffset: 1, value: 0x0F, width: 1)
        #expect(uart.read(portOffset: 1, width: 1) == 0x0F)
    }

    @Test func scratchRegisterRoundTrips() {
        let uart = UART16550 { _ in }

        uart.write(portOffset: 7, value: 0xA5, width: 1)

        #expect(uart.read(portOffset: 7, width: 1) == 0xA5)
    }
}

@Suite struct CMOSRTCTests {
    private func fixedDate() -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 7,
            day: 5,
            hour: 8,
            minute: 9,
            second: 10
        ))!
    }

    @Test func exposesSelectedTimeRegisterInBCD() {
        let rtc = CMOSRTC(now: fixedDate)

        rtc.write(portOffset: 0, value: 0x00, width: 1)
        #expect(rtc.read(portOffset: 1, width: 1) == 0x10)
        rtc.write(portOffset: 0, value: 0x02, width: 1)
        #expect(rtc.read(portOffset: 1, width: 1) == 0x09)
        rtc.write(portOffset: 0, value: 0x04, width: 1)
        #expect(rtc.read(portOffset: 1, width: 1) == 0x08)
        rtc.write(portOffset: 0, value: 0x07, width: 1)
        #expect(rtc.read(portOffset: 1, width: 1) == 0x05)
        rtc.write(portOffset: 0, value: 0x08, width: 1)
        #expect(rtc.read(portOffset: 1, width: 1) == 0x07)
        rtc.write(portOffset: 0, value: 0x09, width: 1)
        #expect(rtc.read(portOffset: 1, width: 1) == 0x26)
        rtc.write(portOffset: 0, value: 0x32, width: 1)
        #expect(rtc.read(portOffset: 1, width: 1) == 0x20)
    }

    @Test func exposesRtcStatusRegisters() {
        let rtc = CMOSRTC(now: fixedDate)

        rtc.write(portOffset: 0, value: 0x8A, width: 1)
        #expect(rtc.read(portOffset: 0, width: 1) == 0x0A)
        #expect(rtc.read(portOffset: 1, width: 1) == 0x20)
        rtc.write(portOffset: 0, value: 0x0B, width: 1)
        #expect(rtc.read(portOffset: 1, width: 1) == 0x02)
        rtc.write(portOffset: 0, value: 0x0D, width: 1)
        #expect(rtc.read(portOffset: 1, width: 1) == 0x80)
    }
}

@Suite struct I8042Tests {
    @Test func resetCommandInvokesResetPulse() {
        var resets = 0
        let controller = I8042 { resets += 1 }

        controller.write(portOffset: 4, value: 0xAD, width: 1)
        controller.write(portOffset: 0, value: 0xFE, width: 1)
        controller.write(portOffset: 4, value: 0xFE, width: 1)

        #expect(resets == 1)
    }

    @Test func statusReportsEmptyBuffers() {
        let controller = I8042 {}

        #expect(controller.read(portOffset: 4, width: 1) == 0)
        #expect(controller.read(portOffset: 0, width: 1) == 0)
    }

    @Test func doesNotClaimSystemControlPortB() {
        let bus = PIOBus()
        bus.attach(I8042 {})

        #expect(bus.device(for: 0x60) != nil)
        #expect(bus.device(for: 0x64) != nil)
        #expect(bus.device(for: 0x61) == nil)
        #expect(bus.device(for: 0x62) == nil)
        #expect(bus.device(for: 0x63) == nil)
        #expect(bus.read(port: 0x61, width: 1) == 0xFF)
    }
}
