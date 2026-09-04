import Foundation
import Testing

@testable import dory_pc_linux_boot_runner

@Suite struct PVHJITDiagnosticsTests {
  @Test func disabledDiagnosticsNeverReadProvidersEvenAtTermination() {
    var sampler = PVHJITDiagnosticsSampler(enabled: false)
    var providerReads = 0
    var clockReads = 0
    func clock() -> UInt64 { clockReads += 1; return 10 }
    func provider() -> PVHJITCacheSnapshot? { providerReads += 1; return nil }
    for terminal in [false, true] {
      #expect(sampler.sampleIfDue(
        retiredInstructions: .max, elapsedNanoseconds: clock(), terminal: terminal,
        baseline: provider, optimizing: provider) == nil)
    }
    #expect(providerReads == 0)
    #expect(clockReads == 0)
  }

  @Test func coarseSamplingDoesNotReadCachesOnEveryDispatchSlice() throws {
    var sampler = PVHJITDiagnosticsSampler(enabled: true)
    var providerReads = 0
    func provider() -> PVHJITCacheSnapshot? { providerReads += 1; return nil }
    for count in stride(from: UInt64(1000), to: 1_000_000, by: 1000) {
      #expect(sampler.sampleIfDue(
        retiredInstructions: count, elapsedNanoseconds: count * 2, terminal: false,
        baseline: provider, optimizing: provider) == nil)
    }
    #expect(providerReads == 0)
    let firstSample = sampler.sampleIfDue(
      retiredInstructions: 1_000_000, elapsedNanoseconds: 2_000_000, terminal: false,
      baseline: provider, optimizing: provider)
    let first = try #require(firstSample)
    #expect(first.sampleInstructionCount == 1_000_000)
    #expect(first.sampleElapsedNanoseconds == 2_000_000)
    #expect(first.sampleIntervalInstructions == 1_000_000)
    #expect(providerReads == 2)
    #expect(sampler.sampleIfDue(
      retiredInstructions: 1_999_999, elapsedNanoseconds: 4_000_000, terminal: false,
      baseline: provider, optimizing: provider) == nil)
    #expect(providerReads == 2)
    #expect(sampler.sampleIfDue(
      retiredInstructions: 2_000_000, elapsedNanoseconds: 4_000_001, terminal: false,
      baseline: provider, optimizing: provider) != nil)
    #expect(providerReads == 4)
    // Deadline arithmetic remains checked at the unsigned count limit.
    #expect(sampler.sampleIfDue(
      retiredInstructions: .max, elapsedNanoseconds: .max, terminal: false,
      baseline: provider, optimizing: provider) != nil)
    #expect(sampler.sampleIfDue(
      retiredInstructions: .max, elapsedNanoseconds: .max, terminal: false,
      baseline: provider, optimizing: provider) == nil)
    #expect(providerReads == 6)
  }

  @Test func terminalSampleCapturesBothTiersBeforeTheNextInterval() throws {
    var sampler = PVHJITDiagnosticsSampler(enabled: true)
    let baseline = snapshot(counter: 12)
    let optimizing = snapshot(counter: 27)
    let firstSample = sampler.sampleIfDue(
      retiredInstructions: 7, elapsedNanoseconds: 20, terminal: true,
      baseline: { baseline }, optimizing: { optimizing })
    let first = try #require(firstSample)
    #expect(first.sampleInstructionCount == 7)
    #expect(first.baseline?.cumulativeCounters["compiledBlocks"] == 12)
    #expect(first.optimizing?.cumulativeCounters["compiledBlocks"] == 27)
    let nextSample = sampler.sampleIfDue(
      retiredInstructions: 9, elapsedNanoseconds: 30, terminal: true,
      baseline: { snapshot(counter: 13) }, optimizing: { nil })
    let next = try #require(nextSample)
    #expect(next.sampleInstructionCount == 9)
    #expect(next.sampleElapsedNanoseconds == 30)
    #expect(next.baseline?.cumulativeCounters["compiledBlocks"] == 13)
    #expect(next.optimizing == nil)
  }

  @Test func serializationRetainsExactCountersAndCapsLiveSitesWithoutGuestBytes() throws {
    let counterNames = [
      "recentLookupHits", "dictionaryLookupHits", "lookupMisses", "memoryGenerationHits",
      "byteValidationHits", "sharedCodeHits", "compiledBlocks", "declinedCompilations",
      "negativeCacheHits", "negativeCacheMisses", "negativeGenerationMismatches",
      "codeCacheWraps", "nativeTraceAttempts", "nativeTraceReplays", "codeGenerationChecks",
      "codeGenerationMismatches", "chainedExecutionCalls", "chainedRequestedInstructions",
      "chainedRetiredInstructions",
    ]
    let counters = Dictionary(uniqueKeysWithValues: counterNames.enumerated().map {
      ($0.element, UInt64.max - UInt64($0.offset))
    })
    let cache = PVHJITCacheSnapshot(
      cumulativeCounters: counters, negativeEntryCount: 512,
      negativeCacheHotSites: (0..<512).map { site(index: $0) })
    let sample = PVHJITDiagnosticSample(
      sampleInstructionCount: 1_000_000, sampleElapsedNanoseconds: UInt64.max,
      sampleIntervalInstructions: PVHJITDiagnosticsSampler.intervalInstructions,
      baseline: cache, optimizing: nil)
    let data = try JSONEncoder().encode(sample)
    let decoded = try JSONDecoder().decode(PVHJITDiagnosticSample.self, from: data)
    let actual = try #require(decoded.baseline)
    #expect(actual.cumulativeCounters == counters)
    #expect(decoded.sampleElapsedNanoseconds == UInt64.max)
    #expect(actual.negativeEntryCount == 512)
    #expect(actual.negativeCacheHotSites.count == 16)
    #expect(actual.negativeCacheHotSites.first?.guestRIP == 0xFFFF_FFFF_8100_0000)
    #expect(actual.negativeCacheHotSites.last?.guestRIP == 0xFFFF_FFFF_8100_000F)
    #expect(actual.negativeCacheHotSites.first?.hitCount == UInt64.max)
    #expect(actual.negativeCacheHotSites.first?.declineReason == "interpreterHelper")
    #expect(actual.negativeCacheHotSites.last?.declineReason == "nativeEmitter")
    #expect(actual.negativeCacheHotSites.first?.addressSpaceID == 0x1000)
    #expect(actual.negativeCacheHotSites.first?.privilegeLevel == 3)
    #expect(actual.negativeCacheHotSites.first?.pagingEnabled == true)
    #expect(actual.negativeCacheHotSites.first?.guestByteCount == 15)
    #expect(actual.negativeCacheHotSites.first?.executionMode == "long64")
    #expect(actual.negativeCacheHotSites.first?.instructionBudget == 64)
    let text = String(decoding: data, as: UTF8.self)
    #expect(!text.contains("instructionBytes"))
    #expect(!actual.cumulativeCounters.keys.contains("negativeEntryCount"))
    #expect(decoded.observationScope.contains("not cumulative reason totals"))
    #expect(data.count < 16_384)
  }

  @Test func errorRecordKeepsSamplePositionSeparateFromFinalCompletedTotals() throws {
    let configuration = try PVHRunnerConfiguration(arguments: [
      "--kernel", "/kernel", "--kernel-sha256", String(repeating: "a", count: 64),
      "--initrd", "/initrd", "--initrd-sha256", String(repeating: "b", count: 64),
      "--command-line", "console=ttyS0 rdinit=/init", "--tier", "baseline-jit",
      "--memory-mib", "512", "--max-instructions", "3000000", "--wall-seconds", "10",
      "--run-id", "fe154770-27f1-4d31-93b5-790932bdf83c", "--workload", "file-io",
      "--diagnostics", "/receipt.json",
    ])
    var record = PVHDiagnosticRecord(configuration: configuration)
    var sampler = PVHJITDiagnosticsSampler(enabled: true)
    record.jitDiagnostics = sampler.sampleIfDue(
      retiredInstructions: 1_000_000, elapsedNanoseconds: 100, terminal: false,
      baseline: { snapshot(counter: 5) }, optimizing: { nil })
    let cached = record.jitDiagnostics
    #expect(sampler.sampleIfDue(
      retiredInstructions: 1_001_000, elapsedNanoseconds: 110, terminal: false,
      baseline: { snapshot(counter: 6) }, optimizing: { nil }) == nil)
    record.retiredInstructions = 1_001_000
    record.elapsedNanoseconds = 150
    record.outcome = .wallBudget
    record.error = "Error after the last completed slice"
    let data = try JSONEncoder().encode(record)
    let decoded = try JSONDecoder().decode(PVHDiagnosticRecord.self, from: data)
    #expect(decoded.retiredInstructions == 1_001_000)
    #expect(decoded.elapsedNanoseconds == 150)
    #expect(decoded.jitDiagnostics?.sampleInstructionCount == cached?.sampleInstructionCount)
    #expect(decoded.jitDiagnostics?.sampleElapsedNanoseconds == 100)
    #expect(decoded.jitDiagnostics?.baseline?.cumulativeCounters["compiledBlocks"] == 5)
    #expect(decoded.jitDiagnostics?.observationScope.contains("older sample") == true)
  }

  private func snapshot(counter: UInt64) -> PVHJITCacheSnapshot {
    .init(cumulativeCounters: ["compiledBlocks": counter], negativeEntryCount: 0, negativeCacheHotSites: [])
  }

  private func site(index: Int) -> PVHJITNegativeCacheSite {
    .init(
      guestRIP: 0xFFFF_FFFF_8100_0000 + UInt64(index), executionMode: "long64",
      instructionBudget: 64, addressSpaceID: 0x1000, privilegeLevel: 3,
      pagingEnabled: true, guestByteCount: 15,
      declineReason: index.isMultiple(of: 2) ? "interpreterHelper" : "nativeEmitter",
      hitCount: .max - UInt64(index))
  }
}
