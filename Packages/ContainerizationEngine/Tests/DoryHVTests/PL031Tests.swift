import Testing
@testable import DoryHV

@Suite struct PL031Tests {
    @Test func readsInjectedHostTimeAndClampsPreEpochValues() {
        let rtc = PL031(baseAddress: 0x0901_0000, now: { 1_726_000_123 })
        #expect(rtc.read(offset: 0x00, width: 4) == 1_726_000_123)
        #expect(rtc.read(offset: 0x08, width: 4) == 1_726_000_123)
        #expect(PL031(baseAddress: 0x0901_0000, now: { -1 }).read(offset: 0x00, width: 4) == 0)
    }

    @Test func guestWritesCannotChangeHostDerivedTimeOrEnableState() {
        let rtc = PL031(baseAddress: 0x0901_0000, now: { 42 })
        rtc.write(offset: 0x08, value: 9_999, width: 4)  // LR
        rtc.write(offset: 0x0C, value: 0, width: 4)  // CR
        #expect(rtc.read(offset: 0x00, width: 4) == 42)
        #expect(rtc.read(offset: 0x08, width: 4) == 42)
        #expect(rtc.read(offset: 0x0C, width: 4) == 1)
    }

    @Test func preservesAMBAIdentificationRegisters() {
        let rtc = PL031(baseAddress: 0x0901_0000, now: { 0 })
        #expect([0xFE0, 0xFE4, 0xFE8, 0xFEC].map { rtc.read(offset: UInt64($0), width: 4) }
            == [0x31, 0x10, 0x14, 0x00])
        #expect([0xFF0, 0xFF4, 0xFF8, 0xFFC].map { rtc.read(offset: UInt64($0), width: 4) }
            == [0x0D, 0xF0, 0x05, 0xB1])
    }
}
