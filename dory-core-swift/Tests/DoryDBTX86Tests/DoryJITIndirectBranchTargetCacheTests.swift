import Darwin
@testable import DoryDBTX86
import Testing

@Suite struct DoryJITIndirectBranchTargetCacheTests {
  @Test func defaultsToThePlanSizeAndRequiresPowerOfTwoStorage() throws {
    let cache = try DoryJITIndirectBranchTargetCache()
    #expect(cache.entryCount == 4_096)
    #expect(cache.entryMask == 4_095)
    #expect(cache.entriesBaseAddress != 0)
    #expect(cache.entriesBaseAddress.isMultiple(of: UInt64(MemoryLayout<UInt64>.alignment)))
    var context = [UInt64](repeating: .max, count: DoryARM64Tier1ABI.contextWordCount)
    context.withUnsafeMutableBufferPointer {
      DoryARM64BaselineExecutor.populateExecutionContext(
        $0,
        from: .reset(),
        memory: nil,
        indirectBranchTargetCache: cache,
        codeCacheGeneration: 7
      )
    }
    #expect(context[DoryARM64Tier1ABI.ContextWord.ibtcEntriesBase.rawValue]
      == cache.entriesBaseAddress)
    #expect(context[DoryARM64Tier1ABI.ContextWord.ibtcEntryMask.rawValue] == 4_095)
    #expect(context[DoryARM64Tier1ABI.ContextWord.ibtcGeneration.rawValue] == 7)
    #expect(context[DoryARM64Tier1ABI.ContextWord.ibtcInlineHits.rawValue] == 0)
    #expect(context[DoryARM64Tier1ABI.ContextWord.ibtcInlineMisses.rawValue] == 0)
    #expect(DoryJITIndirectBranchTargetCache.defaultEntryCount == 4_096)
    #expect(throws: DoryJITIndirectBranchTargetCacheError.invalidEntryCount(0)) {
      _ = try DoryJITIndirectBranchTargetCache(entryCount: 0)
    }
    #expect(throws: DoryJITIndirectBranchTargetCacheError.invalidEntryCount(3)) {
      _ = try DoryJITIndirectBranchTargetCache(entryCount: 3)
    }
  }

  @Test func exactTargetAndGenerationProduceHits() throws {
    let cache = try DoryJITIndirectBranchTargetCache(entryCount: 8)
    #expect(try cache.lookup(guestRIP: 0x1234, generation: 7) == nil)
    try cache.fill(guestRIP: 0x1234, generation: 7, hostAddress: 0xABCD)
    #expect(try cache.lookup(guestRIP: 0x1234, generation: 7) == 0xABCD)
    #expect(try cache.lookup(guestRIP: 0x1234, generation: 8) == nil)

    let diagnostics = cache.diagnostics
    #expect(diagnostics.hits == 1)
    #expect(diagnostics.misses == 2)
    #expect(diagnostics.fills == 1)
    #expect(diagnostics.hitRate == 1.0 / 3.0)
  }

  @Test func directMappedCollisionAndClearFailClosed() throws {
    let cache = try DoryJITIndirectBranchTargetCache(entryCount: 4)
    let first: UInt64 = 0x1000
    let collision = first + UInt64(cache.entryCount * 4)
    #expect(cache.index(for: first) == cache.index(for: collision))

    try cache.fill(guestRIP: first, generation: 1, hostAddress: 0xA000)
    try cache.fill(guestRIP: collision, generation: 1, hostAddress: 0xB000)
    #expect(try cache.lookup(guestRIP: first, generation: 1) == nil)
    #expect(try cache.lookup(guestRIP: collision, generation: 1) == 0xB000)

    cache.removeAll()
    #expect(try cache.lookup(guestRIP: collision, generation: 1) == nil)
    #expect(cache.diagnostics.fills == 2)
  }

  @Test func rejectsZeroGenerationAndHostAddress() throws {
    let cache = try DoryJITIndirectBranchTargetCache(entryCount: 4)
    #expect(throws: DoryJITIndirectBranchTargetCacheError.unavailable(EINVAL)) {
      try cache.fill(guestRIP: 0x1000, generation: 0, hostAddress: 0x2000)
    }
    #expect(throws: DoryJITIndirectBranchTargetCacheError.unavailable(EINVAL)) {
      try cache.fill(guestRIP: 0x1000, generation: 1, hostAddress: 0)
    }
    #expect(throws: DoryJITIndirectBranchTargetCacheError.unavailable(EINVAL)) {
      _ = try cache.lookup(guestRIP: 0x1000, generation: 0)
    }
  }
}
