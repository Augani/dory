import Testing
@testable import DoryHV

struct HostPageTests {
    @Test func hostPageSizeIsUsableForGuestAccounting() {
        #expect(HostPage.size >= 4096)
        #expect(HostPage.size.isMultiple(of: 4096))
        #expect((HostPage.size & (HostPage.size - 1)) == 0)
        #if arch(arm64)
        #expect(HostPage.size == 16_384)
        #elseif arch(x86_64)
        #expect(HostPage.size == 4_096)
        #endif
        #expect(GuestMemory.pageSize == HostPage.size)
        #expect(DaxWindow.pageSize == HostPage.size)
    }
}
