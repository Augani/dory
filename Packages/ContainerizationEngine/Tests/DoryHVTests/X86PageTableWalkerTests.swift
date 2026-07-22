import Testing
@testable import DoryHV

@Suite struct X86PageTableWalkerTests {
    private let present: UInt64 = 1
    private let writable: UInt64 = 1 << 1
    private let huge: UInt64 = 1 << 7

    @Test func translatesFourKilobytePage() throws {
        let memory = try makeMemory()
        try map4K(memory, virtual: 0x4000_1234, physical: 0x0009_8000)

        let result = try X86PageTableWalker(memory: memory).translate(virtualAddress: 0x4000_1234, cr3: 0x1000)

        #expect(result.physicalAddress == 0x0009_8234)
        #expect(result.pageSize == 0x1000)
    }

    @Test func translatesTwoMegabytePage() throws {
        let memory = try makeMemory()
        try writePageTables(memory)
        let virtual: UInt64 = 0x0000_0000_0045_6789
        let pdIndex = (virtual >> 21) & 0x1FF
        try memory.write(UInt64(0x0060_0000 | present | writable | huge), at: 0x3000 + pdIndex * 8)

        let result = try X86PageTableWalker(memory: memory).translate(virtualAddress: virtual, cr3: 0x1000)

        #expect(result.physicalAddress == 0x0065_6789)
        #expect(result.pageSize == 0x20_0000)
    }

    @Test func translatesOneGigabytePage() throws {
        let memory = try makeMemory()
        try memory.write(UInt64(0x2000 | present | writable), at: 0x1000)
        let virtual: UInt64 = 0x0000_0000_1234_5678
        let pdptIndex = (virtual >> 30) & 0x1FF
        try memory.write(UInt64(0x4000_0000 | present | writable | huge), at: 0x2000 + pdptIndex * 8)

        let result = try X86PageTableWalker(memory: memory).translate(virtualAddress: virtual, cr3: 0x1000)

        #expect(result.physicalAddress == 0x5234_5678)
        #expect(result.pageSize == 0x4000_0000)
    }

    @Test func readsBytesAcrossVirtualPageBoundary() throws {
        let memory = try makeMemory()
        try map4K(memory, virtual: 0x7000_0000, physical: 0x000A_0000)
        try map4K(memory, virtual: 0x7000_1000, physical: 0x000B_0000)
        try memory.write([1, 2], at: 0x000A_0FFE)
        try memory.write([3, 4, 5], at: 0x000B_0000)

        let bytes = try X86PageTableWalker(memory: memory).readBytes(virtualAddress: 0x7000_0FFE, count: 5, cr3: 0x1000)

        #expect(bytes == [1, 2, 3, 4, 5])
    }

    @Test func rejectsNonCanonicalVirtualAddress() throws {
        let memory = try makeMemory()

        #expect(throws: X86PageWalkError.nonCanonical(0x0001_0000_0000_0000)) {
            _ = try X86PageTableWalker(memory: memory).translate(virtualAddress: 0x0001_0000_0000_0000, cr3: 0x1000)
        }
    }

    @Test func reportsMissingPageTableEntryLevel() throws {
        let memory = try makeMemory()
        try memory.write(UInt64(0x2000 | present | writable), at: 0x1000)

        #expect(throws: X86PageWalkError.notPresent(level: "PDPT", address: 0x2000)) {
            _ = try X86PageTableWalker(memory: memory).translate(virtualAddress: 0, cr3: 0x1000)
        }
    }

    @Test func rejectsReservedHugePageAddressBits() throws {
        let memory = try makeMemory()
        try writePageTables(memory)
        try memory.write(UInt64(0x0020_2000 | present | writable | huge), at: 0x3000)

        #expect(throws: X86PageWalkError.reservedHugePage(level: "PD", address: 0x0020_0000)) {
            _ = try X86PageTableWalker(memory: memory).translate(virtualAddress: 0, cr3: 0x1000)
        }
    }

    @Test func acceptsHugePageWithPatBitSet() throws {
        let memory = try makeMemory()
        try writePageTables(memory)
        try memory.write(UInt64(0x0020_1000 | present | writable | huge), at: 0x3000)

        let result = try X86PageTableWalker(memory: memory).translate(virtualAddress: 0x1234, cr3: 0x1000)
        #expect(result.physicalAddress == 0x0020_1234)
        #expect(result.pageSize == 0x20_0000)
    }

    private func makeMemory() throws -> GuestMemory {
        // Physical page fixtures reach 0xB0000, independent of the host's 4 KB or 16 KB page size.
        try GuestMemory(guestBase: 0, size: 0x10_0000)
    }

    private func writePageTables(_ memory: GuestMemory) throws {
        try memory.write(UInt64(0x2000 | present | writable), at: 0x1000)
        try memory.write(UInt64(0x3000 | present | writable), at: 0x2000)
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
