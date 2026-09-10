import Darwin
@testable import DoryDBTX86
import Testing

@Suite struct DoryJITShadowReturnStackTests {
  @Test func defaultsToBoundedPowerOfTwoStorage() throws {
    let stack = try DoryJITShadowReturnStack()
    #expect(stack.entryCount == 64)
    #expect(stack.entryMask == 63)
    #expect(stack.entriesBaseAddress != 0)
    #expect(stack.topAddress != 0)
    var context = [UInt64](repeating: .max, count: DoryARM64Tier1ABI.contextWordCount)
    context.withUnsafeMutableBufferPointer {
      DoryARM64BaselineExecutor.populateExecutionContext(
        $0,
        from: .reset(),
        memory: nil,
        shadowReturnStack: stack,
        codeCacheGeneration: 7
      )
    }
    #expect(context[DoryARM64Tier1ABI.ContextWord.shadowReturnEntriesBase.rawValue]
      == stack.entriesBaseAddress)
    #expect(context[DoryARM64Tier1ABI.ContextWord.shadowReturnEntryMask.rawValue] == 63)
    #expect(context[DoryARM64Tier1ABI.ContextWord.shadowReturnTopAddress.rawValue]
      == stack.topAddress)
    #expect(context[DoryARM64Tier1ABI.ContextWord.shadowReturnGeneration.rawValue] == 7)
    #expect(context[DoryARM64Tier1ABI.ContextWord.shadowReturnHits.rawValue] == 0)
    #expect(context[DoryARM64Tier1ABI.ContextWord.shadowReturnMisses.rawValue] == 0)
    #expect(context[DoryARM64Tier1ABI.ContextWord.shadowReturnPushes.rawValue] == 0)
    #expect(throws: DoryJITShadowReturnStackError.invalidEntryCount(0)) {
      _ = try DoryJITShadowReturnStack(entryCount: 0)
    }
    #expect(throws: DoryJITShadowReturnStackError.invalidEntryCount(3)) {
      _ = try DoryJITShadowReturnStack(entryCount: 3)
    }
  }

  @Test func nestedReturnsPopInLastInFirstOutOrder() throws {
    let stack = try DoryJITShadowReturnStack(entryCount: 4)
    try stack.push(guestRSP: 0xFF8, guestRIP: 0x1005, hostAddress: 0xA000, generation: 7)
    try stack.push(guestRSP: 0xFF0, guestRIP: 0x2005, hostAddress: 0xB000, generation: 7)
    #expect(
      try stack.lookupAndPop(guestRSP: 0xFF0, guestRIP: 0x2005, generation: 7) == 0xB000)
    #expect(
      try stack.lookupAndPop(guestRSP: 0xFF8, guestRIP: 0x1005, generation: 7) == 0xA000)
    #expect(try stack.lookupAndPop(guestRSP: 0x1000, guestRIP: 0, generation: 7) == nil)
  }

  @Test func mismatchConsumesPredictionAndClearResetsDepth() throws {
    let stack = try DoryJITShadowReturnStack(entryCount: 2)
    try stack.push(guestRSP: 0xFF8, guestRIP: 0x1005, hostAddress: 0xA000, generation: 7)
    #expect(
      try stack.lookupAndPop(guestRSP: 0xFF8, guestRIP: 0x1006, generation: 7) == nil)
    #expect(
      try stack.lookupAndPop(guestRSP: 0xFF8, guestRIP: 0x1005, generation: 7) == nil)

    try stack.push(guestRSP: 0xFF8, guestRIP: 0x1005, hostAddress: 0, generation: 7)
    #expect(
      try stack.lookupAndPop(guestRSP: 0xFF8, guestRIP: 0x1005, generation: 7) == nil)
    try stack.push(guestRSP: 0xFF8, guestRIP: 0x1005, hostAddress: 0xA000, generation: 7)
    stack.removeAll()
    #expect(
      try stack.lookupAndPop(guestRSP: 0xFF8, guestRIP: 0x1005, generation: 7) == nil)
  }

  @Test func generationAndArgumentsFailClosed() throws {
    let stack = try DoryJITShadowReturnStack(entryCount: 2)
    #expect(throws: DoryJITShadowReturnStackError.unavailable(EINVAL)) {
      try stack.push(guestRSP: 0, guestRIP: 0, hostAddress: 0, generation: 0)
    }
    try stack.push(guestRSP: 8, guestRIP: 0x1000, hostAddress: 0x2000, generation: 2)
    #expect(try stack.lookupAndPop(guestRSP: 8, guestRIP: 0x1000, generation: 3) == nil)
    #expect(throws: DoryJITShadowReturnStackError.unavailable(EINVAL)) {
      _ = try stack.lookupAndPop(guestRSP: 8, guestRIP: 0x1000, generation: 0)
    }
  }
}
