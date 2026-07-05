import Testing
@testable import DoryHV

@Suite struct X86InstructionFetchTests {
    private let present: UInt64 = 1
    private let writable: UInt64 = 1 << 1
    private let paging: UInt64 = 1 << 31

    @Test func readsPhysicalBytesWhenPagingIsDisabled() throws {
        let memory = try makeMemory()
        try memory.write([0x8B, 0x03, 0x90], at: 0x7000)

        let bytes = try X86InstructionFetch.readBytes(
            rip: 0x7000,
            cr0: 0x21,
            cr3: 0,
            count: 3,
            memory: memory
        )

        #expect(bytes == [0x8B, 0x03, 0x90])
    }

    @Test func walksGuestPageTablesWhenPagingIsEnabled() throws {
        let memory = try makeMemory()
        try map4K(memory, virtual: 0xFFFF_8000_0000_0FFE, physical: 0x0008_0000)
        try map4K(memory, virtual: 0xFFFF_8000_0000_1000, physical: 0x0009_0000)
        try memory.write([0x8B, 0x03], at: 0x0008_0FFE)
        try memory.write([0x90, 0x90], at: 0x0009_0000)

        let bytes = try X86InstructionFetch.readBytes(
            rip: 0xFFFF_8000_0000_0FFE,
            cr0: paging,
            cr3: 0x1000,
            count: 4,
            memory: memory
        )

        #expect(bytes == [0x8B, 0x03, 0x90, 0x90])
    }

    private func makeMemory() throws -> GuestMemory {
        try GuestMemory(guestBase: 0, size: 256 * HostPage.size)
    }

    private func map4K(_ memory: GuestMemory, virtual: UInt64, physical: UInt64) throws {
        let pml4Index = (virtual >> 39) & 0x1FF
        let pdptIndex = (virtual >> 30) & 0x1FF
        let pdIndex = (virtual >> 21) & 0x1FF
        let ptIndex = (virtual >> 12) & 0x1FF
        try memory.write(UInt64(0x2000 | present | writable), at: 0x1000 + pml4Index * 8)
        try memory.write(UInt64(0x3000 | present | writable), at: 0x2000 + pdptIndex * 8)
        try memory.write(UInt64(0x4000 | present | writable), at: 0x3000 + pdIndex * 8)
        try memory.write(UInt64((physical & 0x000F_FFFF_FFFF_F000) | present | writable), at: 0x4000 + ptIndex * 8)
    }
}
