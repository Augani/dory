import Darwin
import Foundation
import Testing

@testable import DoryDBTX86

/// P2-06 focused tests for alias-safe translated-code invalidation when a host page covers
/// multiple 4-KiB guest pages, and for the checked guest-page generation/lifetime contract
/// suitable for future DMA/shared-mapping adapters.
@Suite struct DoryX86TranslatedCodeLifetimeTests {
  private static let guestPageByteCount = 4_096

  /// Returns the actual host page size; tests must not lie about host mappings.
  private static var hostPageByteCount: Int { Int(getpagesize()) }

  /// True when one host granule covers more than one 4-KiB guest page.
  private static var hostPageCoversMultipleGuestPages: Bool {
    hostPageByteCount > guestPageByteCount
  }

  /// Smallest allocation that always contains at least two 4-KiB guest pages, even
  /// on a 4-KiB host where one host granule covers only one guest page.
  private static var twoGuestPageByteCount: Int {
    max(hostPageByteCount, guestPageByteCount * 2)
  }

  @Test func aliasSafeInvalidationReleasesHostPageWithoutStaleSiblingState() throws {
    let memory = try DoryX86MmapMemory(validatingByteCount: Self.twoGuestPageByteCount)
    let pageA = UInt64(0)
    let pageB = UInt64(Self.guestPageByteCount)

    try memory.protectTranslatedCode(at: pageA, byteCount: 1)
    try memory.protectTranslatedCode(at: pageB, byteCount: 1)
    #expect(memory.protectedTranslatedCodePageCount == 2)

    let rawGenA = memory.rawCodePageGeneration(at: pageA)
    let rawGenB = memory.rawCodePageGeneration(at: pageB)

    if Self.hostPageCoversMultipleGuestPages {
      // On a host granule larger than 4 KiB, a write to page A must release the
      // shared host page so page B is not left logically protected with stale
      // host mprotect state.
      try memory.write(at: pageA, bytes: [0x90])
      #expect(memory.protectedTranslatedCodePageCount == 0)
    } else {
      // On a 4-KiB host page each guest page has its own host granule; a write to
      // page A releases only page A's host page, leaving page B protected.
      try memory.write(at: pageA, bytes: [0x90])
      #expect(memory.protectedTranslatedCodePageCount == 1)
    }

    // Exactly-once: page A's generation must increase by 1, not 0 or 2.
    #expect(memory.rawCodePageGeneration(at: pageA) == rawGenA + 1)
    // Page B's generation must not change because its bytes were not written.
    #expect(memory.rawCodePageGeneration(at: pageB) == rawGenB)
  }

  @Test func writeToEitherGuestPageInvalidatesOnlyIntersectingGeneration() throws {
    let memory = try DoryX86MmapMemory(validatingByteCount: Self.twoGuestPageByteCount)
    let pageA = UInt64(0)
    let pageB = UInt64(Self.guestPageByteCount)

    try memory.protectTranslatedCode(at: pageA, byteCount: 1)
    try memory.protectTranslatedCode(at: pageB, byteCount: 1)

    let genA = try #require(try memory.codeGeneration(at: pageA, byteCount: 1))
    let genB = try #require(try memory.codeGeneration(at: pageB, byteCount: 1))
    let rawGenA = memory.rawCodePageGeneration(at: pageA)
    let rawGenB = memory.rawCodePageGeneration(at: pageB)

    // Write to page A: only page A's generation must change, exactly once.
    try memory.write(at: pageA, bytes: [0xCC])
    #expect(try memory.codeGeneration(at: pageA, byteCount: 1) != genA)
    #expect(try memory.codeGeneration(at: pageB, byteCount: 1) == genB)
    #expect(memory.rawCodePageGeneration(at: pageA) == rawGenA + 1)
    #expect(memory.rawCodePageGeneration(at: pageB) == rawGenB)

    // Re-protect and write to page B: only page B's generation must change.
    try memory.protectTranslatedCode(at: pageA, byteCount: 1)
    try memory.protectTranslatedCode(at: pageB, byteCount: 1)
    let genA2 = try #require(try memory.codeGeneration(at: pageA, byteCount: 1))
    let genB2 = try #require(try memory.codeGeneration(at: pageB, byteCount: 1))
    let rawGenA2 = memory.rawCodePageGeneration(at: pageA)
    let rawGenB2 = memory.rawCodePageGeneration(at: pageB)

    try memory.write(at: pageB, bytes: [0xDD])
    #expect(try memory.codeGeneration(at: pageA, byteCount: 1) == genA2)
    #expect(try memory.codeGeneration(at: pageB, byteCount: 1) != genB2)
    #expect(memory.rawCodePageGeneration(at: pageA) == rawGenA2)
    #expect(memory.rawCodePageGeneration(at: pageB) == rawGenB2 + 1)
  }

  @Test func explicitInvalidationTouchesOnlyIntersectingGuestPage() throws {
    let memory = try DoryX86MmapMemory(validatingByteCount: Self.twoGuestPageByteCount)
    let pageA = UInt64(0)
    let pageB = UInt64(Self.guestPageByteCount)

    try memory.protectTranslatedCode(at: pageA, byteCount: 1)
    try memory.protectTranslatedCode(at: pageB, byteCount: 1)

    let genA = try #require(try memory.codeGeneration(at: pageA, byteCount: 1))
    let genB = try #require(try memory.codeGeneration(at: pageB, byteCount: 1))
    let rawGenA = memory.rawCodePageGeneration(at: pageA)
    let rawGenB = memory.rawCodePageGeneration(at: pageB)

    // Explicit invalidation of page A must not bump page B's generation.
    try memory.invalidateTranslatedCode(at: pageA, byteCount: 1)
    #expect(try memory.codeGeneration(at: pageA, byteCount: 1) != genA)
    #expect(try memory.codeGeneration(at: pageB, byteCount: 1) == genB)
    // Exactly-once: page A bumped by 1, page B unchanged.
    #expect(memory.rawCodePageGeneration(at: pageA) == rawGenA + 1)
    #expect(memory.rawCodePageGeneration(at: pageB) == rawGenB)
  }

  @Test func crossPageRangeInvalidationReleasesAllAffectedHostPages() throws {
    let byteCount = Self.hostPageByteCount * 3
    let memory = try DoryX86MmapMemory(validatingByteCount: byteCount)
    let page0 = UInt64(0)
    let page1 = UInt64(Self.guestPageByteCount)
    let page2 = UInt64(Self.guestPageByteCount * 2)

    try memory.protectTranslatedCode(at: page0, byteCount: 1)
    try memory.protectTranslatedCode(at: page1, byteCount: 1)
    try memory.protectTranslatedCode(at: page2, byteCount: 1)

    let gen0 = try #require(try memory.codeGeneration(at: page0, byteCount: 1))
    let gen1 = try #require(try memory.codeGeneration(at: page1, byteCount: 1))
    let gen2 = try #require(try memory.codeGeneration(at: page2, byteCount: 1))
    let rawGen0 = memory.rawCodePageGeneration(at: page0)
    let rawGen1 = memory.rawCodePageGeneration(at: page1)
    let rawGen2 = memory.rawCodePageGeneration(at: page2)

    // A range spanning pages 0 and 1 must invalidate both and release all affected
    // host pages. Page 2 (outside the range) must retain its generation.
    try memory.write(at: page0, bytes: [UInt8](repeating: 0xAA, count: Self.guestPageByteCount * 2))
    #expect(try memory.codeGeneration(at: page0, byteCount: 1) != gen0)
    #expect(try memory.codeGeneration(at: page1, byteCount: 1) != gen1)
    #expect(try memory.codeGeneration(at: page2, byteCount: 1) == gen2)
    // Exactly-once: pages 0 and 1 bumped by 1, page 2 unchanged.
    #expect(memory.rawCodePageGeneration(at: page0) == rawGen0 + 1)
    #expect(memory.rawCodePageGeneration(at: page1) == rawGen1 + 1)
    #expect(memory.rawCodePageGeneration(at: page2) == rawGen2)
  }

  @Test func invalidAndOverflowRangesAreRejectedWithoutPartialMutation() throws {
    let memory = try DoryX86MmapMemory(validatingByteCount: Self.hostPageByteCount)
    try memory.protectTranslatedCode(at: 0, byteCount: 1)
    let protectionCount = memory.protectedTranslatedCodePageCount
    let generation = try #require(try memory.codeGeneration(at: 0, byteCount: 1))

    // Zero byte count is rejected.
    #expect(throws: DoryX86MemoryError.self) {
      try memory.invalidateTranslatedCodeGenerations(
        in: DoryX86GuestCodePageRange(address: 0, byteCount: 0))
    }

    // Out-of-RAM address is rejected.
    #expect(throws: DoryX86MemoryError.self) {
      try memory.invalidateTranslatedCodeGenerations(
        in: DoryX86GuestCodePageRange(
          address: UInt64(Self.hostPageByteCount) + 1, byteCount: 1))
    }

    // Overflow range is rejected.
    #expect(throws: DoryX86MemoryError.self) {
      try memory.invalidateTranslatedCodeGenerations(
        in: DoryX86GuestCodePageRange(address: .max, byteCount: 2))
    }

    // No partial mutation occurred.
    #expect(memory.protectedTranslatedCodePageCount == protectionCount)
    #expect(try memory.codeGeneration(at: 0, byteCount: 1) == generation)
  }

  @Test func generationChangesAreVisibleToCodeGenerationToken() throws {
    let memory = try DoryX86MmapMemory(validatingByteCount: Self.hostPageByteCount)
    try memory.write(at: 0, bytes: [0x90])
    let token = try #require(try memory.codeGeneration(at: 0, byteCount: 1))
    let rawGen = memory.rawCodePageGeneration(at: 0)

    // A CPU store must change the token so existing JIT validation detects SMC.
    try memory.write(at: 0, bytes: [0xCC])
    #expect(try memory.codeGeneration(at: 0, byteCount: 1) != token)
    // Exactly-once for an unprotected CPU store.
    #expect(memory.rawCodePageGeneration(at: 0) == rawGen + 1)

    // The DMA lifetime hook must also change the token.
    let token2 = try #require(try memory.codeGeneration(at: 0, byteCount: 1))
    let rawGen2 = memory.rawCodePageGeneration(at: 0)
    _ = try memory.invalidateTranslatedCodeGenerations(
      in: DoryX86GuestCodePageRange(address: 0, byteCount: 1))
    #expect(try memory.codeGeneration(at: 0, byteCount: 1) != token2)
    // Exactly-once for the DMA lifetime hook on an unprotected page.
    #expect(memory.rawCodePageGeneration(at: 0) == rawGen2 + 1)
  }

  @Test func untrackedDataWritesDoNotSpuriouslyInvalidateCode() throws {
    let memory = try DoryX86MmapMemory(validatingByteCount: Self.twoGuestPageByteCount)
    let codePage = UInt64(0)
    let dataPage = UInt64(Self.guestPageByteCount)

    try memory.protectTranslatedCode(at: codePage, byteCount: 1)
    let codeGen = try #require(try memory.codeGeneration(at: codePage, byteCount: 1))
    let rawCodeGen = memory.rawCodePageGeneration(at: codePage)

    // Writing to a sibling data page under the same host page releases the host
    // page protection but must not bump the code page's generation because the
    // code bytes have not changed.
    try memory.write(at: dataPage, bytes: [0xFF])

    if Self.hostPageCoversMultipleGuestPages {
      // Same host page: protection released, generation preserved.
      #expect(memory.protectedTranslatedCodePageCount == 0)
      #expect(try memory.codeGeneration(at: codePage, byteCount: 1) == codeGen)
    } else {
      // Separate host pages: code page protection untouched, generation preserved.
      #expect(memory.protectedTranslatedCodePageCount == 1)
      #expect(try memory.codeGeneration(at: codePage, byteCount: 1) == codeGen)
    }
    // Raw generation must be unchanged regardless of host page size.
    #expect(memory.rawCodePageGeneration(at: codePage) == rawCodeGen)
  }

  @Test func dmaLifetimeInvalidationBumpsAllPagesInRange() throws {
    let byteCount = Self.twoGuestPageByteCount
    let memory = try DoryX86MmapMemory(validatingByteCount: byteCount)
    let page0 = UInt64(0)
    let page1 = UInt64(Self.guestPageByteCount)

    try memory.protectTranslatedCode(at: page0, byteCount: 1)
    try memory.protectTranslatedCode(at: page1, byteCount: 1)

    let gen0 = try #require(try memory.codeGeneration(at: page0, byteCount: 1))
    let gen1 = try #require(try memory.codeGeneration(at: page1, byteCount: 1))
    let rawGen0 = memory.rawCodePageGeneration(at: page0)
    let rawGen1 = memory.rawCodePageGeneration(at: page1)

    // A DMA adapter presents an owned range covering both pages and invokes the
    // same generation invalidation before backing reuse. Every page in the range
    // must have its generation bumped so no resident translation survives.
    let released = try memory.invalidateTranslatedCodeGenerations(
      in: DoryX86GuestCodePageRange(address: 0, byteCount: Self.guestPageByteCount * 2))
    #expect(released)
    #expect(memory.protectedTranslatedCodePageCount == 0)
    #expect(try memory.codeGeneration(at: page0, byteCount: 1) != gen0)
    #expect(try memory.codeGeneration(at: page1, byteCount: 1) != gen1)
    // Exactly-once: each protected page bumped by 1, not 0 or 2.
    #expect(memory.rawCodePageGeneration(at: page0) == rawGen0 + 1)
    #expect(memory.rawCodePageGeneration(at: page1) == rawGen1 + 1)
  }

  @Test func dmaLifetimeInvalidationRejectsOutOfRangeWithoutMutation() throws {
    let memory = try DoryX86MmapMemory(validatingByteCount: Self.hostPageByteCount)
    try memory.protectTranslatedCode(at: 0, byteCount: 1)
    let protectionCount = memory.protectedTranslatedCodePageCount
    let generation = try #require(try memory.codeGeneration(at: 0, byteCount: 1))

    #expect(throws: DoryX86MemoryError.self) {
      try memory.invalidateTranslatedCodeGenerations(
        in: DoryX86GuestCodePageRange(
          address: UInt64(Self.hostPageByteCount), byteCount: 1))
    }
    #expect(memory.protectedTranslatedCodePageCount == protectionCount)
    #expect(try memory.codeGeneration(at: 0, byteCount: 1) == generation)
  }

  @Test func guestCodePageByteCountIsExactlyFourKib() {
    #expect(DoryX86GuestCodePageRange.guestCodePageByteCount == 4_096)
  }
}
