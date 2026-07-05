import Testing
@testable import DoryHV

@Suite struct GuestMemoryTests {
    @Test func boundsCheckedReadWrite() throws {
        let memory = try GuestMemory(guestBase: 0x8000_0000, size: 32 * HostPage.size)
        try memory.write(UInt64(0xDEAD_BEEF_CAFE_F00D), at: 0x8000_0100)
        #expect(try memory.read(UInt64.self, at: 0x8000_0100) == 0xDEAD_BEEF_CAFE_F00D)
        #expect(memory.contains(0x8000_0000, count: 32 * HostPage.size))
        #expect(!memory.contains(0x8000_0000, count: 32 * HostPage.size + 1))
        #expect(!memory.contains(0x7FFF_FFFF, count: 1))
        #expect(throws: VMError.self) {
            _ = try memory.read(UInt32.self, at: 0x8000_0000 + 32 * HostPage.size - 2)
        }
    }

    @Test func rejectsUnalignedSize() {
        #expect(throws: VMError.self) {
            _ = try GuestMemory(guestBase: 0x8000_0000, size: 12345)
        }
    }
}
