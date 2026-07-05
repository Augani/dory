public enum X86InstructionFetch {
    private static let pagingEnabled: UInt64 = 1 << 31

    public static func readBytes(
        rip: UInt64,
        cr0: UInt64,
        cr3: UInt64,
        count: Int,
        memory: GuestMemory
    ) throws -> [UInt8] {
        guard count > 0 else { return [] }
        if cr0 & pagingEnabled == 0 {
            return try memory.readBytes(at: rip, count: count)
        }
        return try X86PageTableWalker(memory: memory).readBytes(virtualAddress: rip, count: count, cr3: cr3)
    }
}
