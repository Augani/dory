import DoryDBTX86
import DoryMachinePC
import dory_x86_decode_audit
import Foundation
import Testing

@testable import DoryDBTX86
@testable import dory_x86_decode_audit

// P2-05: Profile the accepted engine before redesigning it.
// Tests verify profile collection, cost report ranking, RPC stage timing,
// and the comparison harness.

@Suite struct ISAEngineProfileTests {
  private func makeSample(
    wallTime: UInt64 = 1_000_000_000,
    retiredInstructions: UInt64 = 1_000_000,
    compilationTime: UInt64 = 100_000_000,
    cacheHits: UInt64 = 9000,
    cacheMisses: UInt64 = 1000,
    cacheMaxBytes: UInt64 = 128 * 1024 * 1024,
    cacheAllocatedBytes: UInt64 = 64 * 1024 * 1024,
    tier1Attempts: UInt64 = 1000,
    tier1Declines: UInt64 = 100,
    chainAttempts: UInt64 = 500,
    chainAccepts: UInt64 = 400,
    helperCalls: UInt64 = 5000,
    codeCacheWraps: UInt64 = 2,
    codeCacheEvictedBlocks: UInt64 = 50,
    pendingWorkExits: UInt64 = 100
  ) -> ISAEngineProfileSample {
    ISAEngineProfileSample(
      configuration: .init(
        tier: "Tier1-direct-only", cpuProfile: "compatibleV1",
        schedulingMode: "serialized", firmwareVersion: "edk2-pc-v1",
        kernelInitrdDiskHash: String(repeating: "a", count: 64)),
      workloadName: "test-workload",
      workloadRevision: "abc123",
      wallTimeNanoseconds: wallTime,
      retiredGuestInstructions: retiredInstructions,
      compilationTimeNanoseconds: compilationTime,
      compilationAttempts: 1100,
      compilationDeclines: 100,
      translationCacheEntryCount: 500,
      translationCacheAllocatedBytes: cacheAllocatedBytes,
      translationCacheMaximumBytes: cacheMaxBytes,
      translationCacheHits: cacheHits,
      translationCacheMisses: cacheMisses,
      translationCacheInvalidations: 10,
      tier1DeclineInterpreterHelper: 50,
      tier1DeclineNativeEmitter: 50,
      tier1CompiledBlocks: 900,
      tier1CompilationAttempts: tier1Attempts,
      tier1CompilationDeclines: tier1Declines,
      nativeDispatcherEntries: 800,
      directlyChainedBlocks: 400,
      chainTargetAttempts: chainAttempts,
      chainTargetAccepts: chainAccepts,
      indirectBranchTargetCacheHits: 300,
      indirectBranchTargetCacheMisses: 50,
      shadowReturnStackHits: 200,
      shadowReturnStackMisses: 10,
      helperCalls: helperCalls,
      memoryFaultSlowPaths: 20,
      lazyFlagMaterializations: 100,
      codeCacheWraps: codeCacheWraps,
      codeCacheEvictedBlocks: codeCacheEvictedBlocks,
      negativeCacheHits: 80,
      negativeCacheMisses: 20,
      pendingWorkExits: pendingWorkExits)
  }

  @Test func legacyNumericProfileAPIAndPayloadDoNotEstablishFallbackEvidence() throws {
    let sample = makeSample()
    // These assignments and arithmetic must compile for pre-snapshot callers.
    let helper: UInt64 = sample.tier1DeclineInterpreterHelper
    let emitter: UInt64 = sample.tier1DeclineNativeEmitter
    #expect(helper + emitter == 100)
    var payload = try #require(JSONSerialization.jsonObject(
      with: JSONEncoder().encode(sample)) as? [String: Any])
    payload.removeValue(forKey: "confirmedInterpreterFallback")
    let legacy = try JSONDecoder().decode(ISAEngineProfileSample.self,
      from: JSONSerialization.data(withJSONObject: payload))
    #expect(legacy.tier1DeclineInterpreterHelper == helper)
    #expect(legacy.tier1DeclineNativeEmitter == emitter)
    #expect(legacy.confirmedInterpreterFallback == nil)
    #expect(ISAEngineComparisonHarness.attributeTier1Declines(from: legacy) == nil)
    let report = ISAEngineCostReportGenerator.generate(from: legacy)
    let category = try #require(report.costCategories.first { $0.name == "tier1Declines" })
    #expect(category.counterPressure == 0)
    #expect(category.evidence.contains("unavailable"))
    #expect(!report.optimizationOpportunities.contains { $0.targetCostCategory == "tier1Declines" })
  }

  @Test func profileSampleComputesDerivedMetrics() {
    let sample = makeSample()
    #expect(sample.instructionsPerNanosecond == 0.001)  // 1M / 1B
    #expect(sample.translationCacheHitRate == 0.9)  // 9000 / 10000
    #expect(sample.translationCacheOccupancy == 0.5)  // 64MB / 128MB
    #expect(sample.tier1DeclineRate == 0.1)  // 100 / 1000
    #expect(sample.chainTargetAcceptRate == 0.8)  // 400 / 500
    #expect(sample.compilationTimeFraction == 0.1)  // 100M / 1B
  }

  @Test func profileSampleHandlesZeroWallTime() {
    let sample = makeSample(wallTime: 0)
    #expect(sample.instructionsPerNanosecond == 0)
    #expect(sample.translationCacheHitRate == 0.9)
    #expect(sample.compilationTimeFraction == 0)
  }

  @Test func profileSampleHandlesZeroCacheLookups() {
    let sample = makeSample(cacheHits: 0, cacheMisses: 0)
    #expect(sample.translationCacheHitRate == 0)
  }

  @Test func profileConfigurationIsHashableAndEquatable() {
    let config1 = ISAEngineProfileConfiguration(
      tier: "Tier1", cpuProfile: "compatibleV1", schedulingMode: "serialized",
      firmwareVersion: "v1", kernelInitrdDiskHash: "abc")
    let config2 = ISAEngineProfileConfiguration(
      tier: "Tier1", cpuProfile: "compatibleV1", schedulingMode: "serialized",
      firmwareVersion: "v1", kernelInitrdDiskHash: "abc")
    let config3 = ISAEngineProfileConfiguration(
      tier: "Tier2", cpuProfile: "compatibleV1", schedulingMode: "serialized",
      firmwareVersion: "v1", kernelInitrdDiskHash: "abc")
    #expect(config1 == config2)
    #expect(config1 != config3)
    #expect(config1.hashValue == config2.hashValue)
  }
}

@Suite struct ISAEngineCostReportTests {
  @Test func costReportRanksCategoriesByEstimatedTime() {
    let sample = ISAEngineProfileSample(
      configuration: .init(
        tier: "Tier1-direct-only", cpuProfile: "compatibleV1",
        schedulingMode: "serialized", firmwareVersion: "v1",
        kernelInitrdDiskHash: String(repeating: "a", count: 64)),
      workloadName: "test", workloadRevision: "rev1",
      wallTimeNanoseconds: 1_000_000_000,
      retiredGuestInstructions: 1_000_000,
      compilationTimeNanoseconds: 200_000_000,
      compilationAttempts: 100, compilationDeclines: 10,
      translationCacheEntryCount: 500,
      translationCacheAllocatedBytes: 64 * 1024 * 1024,
      translationCacheMaximumBytes: 128 * 1024 * 1024,
      translationCacheHits: 8000, translationCacheMisses: 2000,
      translationCacheInvalidations: 5,
      tier1DeclineInterpreterHelper: 5, tier1DeclineNativeEmitter: 5,
      tier1CompiledBlocks: 90, tier1CompilationAttempts: 100,
      tier1CompilationDeclines: 10,
      nativeDispatcherEntries: 800, directlyChainedBlocks: 400,
      chainTargetAttempts: 500, chainTargetAccepts: 400,
      indirectBranchTargetCacheHits: 300, indirectBranchTargetCacheMisses: 50,
      shadowReturnStackHits: 200, shadowReturnStackMisses: 10,
      helperCalls: 5000, memoryFaultSlowPaths: 20,
      lazyFlagMaterializations: 100,
      codeCacheWraps: 3, codeCacheEvictedBlocks: 50,
      negativeCacheHits: 80, negativeCacheMisses: 20,
      pendingWorkExits: 100)

    let report = ISAEngineCostReportGenerator.generate(from: sample)

    // Cost categories should be sorted by estimated nanoseconds descending.
    for i in 0..<(report.costCategories.count - 1) {
      #expect(report.costCategories[i].estimatedNanoseconds >= report.costCategories[i + 1].estimatedNanoseconds)
    }

    // Guest execution should be the top category (800M of 1B wall time).
    #expect(report.costCategories.first?.name == "guestExecution")
    #expect(report.costCategories.first?.estimatedNanoseconds == 800_000_000)
  }

  @Test func costReportIdentifiesOptimizationOpportunities() {
    let sample = ISAEngineProfileSample(
      configuration: .init(
        tier: "Tier1-direct-only", cpuProfile: "compatibleV1",
        schedulingMode: "serialized", firmwareVersion: "v1",
        kernelInitrdDiskHash: String(repeating: "a", count: 64)),
      workloadName: "test", workloadRevision: "rev1",
      wallTimeNanoseconds: 1_000_000_000,
      retiredGuestInstructions: 1_000_000,
      compilationTimeNanoseconds: 100_000_000,
      compilationAttempts: 100, compilationDeclines: 10,
      translationCacheEntryCount: 500,
      translationCacheAllocatedBytes: 128 * 1024 * 1024,
      translationCacheMaximumBytes: 128 * 1024 * 1024,
      translationCacheHits: 5000, translationCacheMisses: 5000,
      translationCacheInvalidations: 5,
      tier1DeclineInterpreterHelper: 5, tier1DeclineNativeEmitter: 5,
      tier1CompiledBlocks: 90, tier1CompilationAttempts: 100,
      tier1CompilationDeclines: 20,
      nativeDispatcherEntries: 800, directlyChainedBlocks: 400,
      chainTargetAttempts: 500, chainTargetAccepts: 300,
      indirectBranchTargetCacheHits: 300, indirectBranchTargetCacheMisses: 50,
      shadowReturnStackHits: 200, shadowReturnStackMisses: 10,
      helperCalls: 50000, memoryFaultSlowPaths: 20,
      lazyFlagMaterializations: 100,
      codeCacheWraps: 5, codeCacheEvictedBlocks: 100,
      negativeCacheHits: 80, negativeCacheMisses: 20,
      pendingWorkExits: 100)

    let report = ISAEngineCostReportGenerator.generate(from: sample)

    // Should identify up to 3 optimization opportunities.
    #expect(!report.optimizationOpportunities.isEmpty)
    #expect(report.optimizationOpportunities.count <= 3)

    // Each opportunity should have a rank, title, and measurement plan.
    for opp in report.optimizationOpportunities {
      #expect(opp.rank > 0)
      #expect(!opp.title.isEmpty)
      #expect(!opp.rationale.isEmpty)
      #expect(!opp.measurementPlan.isEmpty)
    }
  }

  @Test func costReportSummaryIncludesKeyMetrics() {
    let sample = ISAEngineProfileSample(
      configuration: .init(
        tier: "Tier1", cpuProfile: "compatibleV1",
        schedulingMode: "serialized", firmwareVersion: "v1",
        kernelInitrdDiskHash: String(repeating: "a", count: 64)),
      workloadName: "my-workload", workloadRevision: "deadbeef",
      wallTimeNanoseconds: 2_000_000_000,
      retiredGuestInstructions: 2_000_000,
      compilationTimeNanoseconds: 200_000_000,
      compilationAttempts: 100, compilationDeclines: 10,
      translationCacheEntryCount: 500,
      translationCacheAllocatedBytes: 64 * 1024 * 1024,
      translationCacheMaximumBytes: 128 * 1024 * 1024,
      translationCacheHits: 9000, translationCacheMisses: 1000,
      translationCacheInvalidations: 5,
      tier1DeclineInterpreterHelper: 5, tier1DeclineNativeEmitter: 5,
      tier1CompiledBlocks: 90, tier1CompilationAttempts: 100,
      tier1CompilationDeclines: 10,
      nativeDispatcherEntries: 800, directlyChainedBlocks: 400,
      chainTargetAttempts: 500, chainTargetAccepts: 400,
      indirectBranchTargetCacheHits: 300, indirectBranchTargetCacheMisses: 50,
      shadowReturnStackHits: 200, shadowReturnStackMisses: 10,
      helperCalls: 5000, memoryFaultSlowPaths: 20,
      lazyFlagMaterializations: 100,
      codeCacheWraps: 0, codeCacheEvictedBlocks: 0,
      negativeCacheHits: 80, negativeCacheMisses: 20,
      pendingWorkExits: 100)

    let report = ISAEngineCostReportGenerator.generate(from: sample)
    #expect(report.summary.contains("my-workload"))
    #expect(report.summary.contains("deadbeef"))
    #expect(report.summary.contains("Tier1"))
    #expect(report.summary.contains("2000000"))
  }

  @Test func costReportHandlesZeroWallTime() {
    let sample = ISAEngineProfileSample(
      configuration: .init(
        tier: "Tier1", cpuProfile: "compatibleV1",
        schedulingMode: "serialized", firmwareVersion: "v1",
        kernelInitrdDiskHash: String(repeating: "a", count: 64)),
      workloadName: "test", workloadRevision: "rev1",
      wallTimeNanoseconds: 0,
      retiredGuestInstructions: 0,
      compilationTimeNanoseconds: 0,
      compilationAttempts: 0, compilationDeclines: 0,
      translationCacheEntryCount: 0,
      translationCacheAllocatedBytes: 0,
      translationCacheMaximumBytes: 128 * 1024 * 1024,
      translationCacheHits: 0, translationCacheMisses: 0,
      translationCacheInvalidations: 0,
      tier1DeclineInterpreterHelper: 0, tier1DeclineNativeEmitter: 0,
      tier1CompiledBlocks: 0, tier1CompilationAttempts: 0,
      tier1CompilationDeclines: 0,
      nativeDispatcherEntries: 0, directlyChainedBlocks: 0,
      chainTargetAttempts: 0, chainTargetAccepts: 0,
      indirectBranchTargetCacheHits: 0, indirectBranchTargetCacheMisses: 0,
      shadowReturnStackHits: 0, shadowReturnStackMisses: 0,
      helperCalls: 0, memoryFaultSlowPaths: 0,
      lazyFlagMaterializations: 0,
      codeCacheWraps: 0, codeCacheEvictedBlocks: 0,
      negativeCacheHits: 0, negativeCacheMisses: 0,
      pendingWorkExits: 0)

    let report = ISAEngineCostReportGenerator.generate(from: sample)
    #expect(report.wallTimeNanoseconds == 0)
    #expect(report.instructionsPerNanosecond == 0)
    // All fractions should be 0 when wall time is 0.
    for category in report.costCategories {
      #expect(category.fractionOfWallTime == 0)
    }
  }
}

@Suite struct ISARPCStageTimingTests {
  @Test func stageTimingComputesLatencyDeltas() {
    let timing = ISARPCStageTiming(
      commandSubmittedNanoseconds: 1000,
      daemonAcceptedNanoseconds: 1100,
      transportDeliveredNanoseconds: 1200,
      guestScheduledNanoseconds: 1300,
      commandStartedNanoseconds: 1400,
      processExitedNanoseconds: 2000,
      replyReceivedNanoseconds: 2100)

    #expect(timing.submissionToAcceptanceNanoseconds == 100)
    #expect(timing.acceptanceToDeliveryNanoseconds == 100)
    #expect(timing.deliveryToSchedulingNanoseconds == 100)
    #expect(timing.schedulingToStartNanoseconds == 100)
    #expect(timing.guestExecutionNanoseconds == 600)
    #expect(timing.exitToReplyNanoseconds == 100)
    #expect(timing.totalHostOrchestrationNanoseconds == 500)
    #expect(timing.totalLatencyNanoseconds == 1100)
  }

  @Test func stageTimingHandlesPartialStages() {
    let timing = ISARPCStageTiming(
      commandSubmittedNanoseconds: 1000,
      daemonAcceptedNanoseconds: 1100)

    #expect(timing.submissionToAcceptanceNanoseconds == 100)
    #expect(timing.acceptanceToDeliveryNanoseconds == nil)
    #expect(timing.guestExecutionNanoseconds == nil)
    #expect(timing.totalLatencyNanoseconds == nil)
  }

  @Test func stageTimingBuilderRecordsProgressively() {
    let builder = ISARPCStageTimingBuilder()
    // Small delay to ensure timestamps advance.
    Thread.sleep(forTimeInterval: 0.001)
    builder.recordDaemonAccepted()
    Thread.sleep(forTimeInterval: 0.001)
    builder.recordTransportDelivered()
    Thread.sleep(forTimeInterval: 0.001)
    builder.recordGuestScheduled()
    Thread.sleep(forTimeInterval: 0.001)
    builder.recordCommandStarted()
    Thread.sleep(forTimeInterval: 0.001)
    builder.recordProcessExited()
    Thread.sleep(forTimeInterval: 0.001)
    builder.recordReplyReceived()

    let timing = builder.build()
    #expect(timing.daemonAcceptedNanoseconds != nil)
    #expect(timing.transportDeliveredNanoseconds != nil)
    #expect(timing.guestScheduledNanoseconds != nil)
    #expect(timing.commandStartedNanoseconds != nil)
    #expect(timing.processExitedNanoseconds != nil)
    #expect(timing.replyReceivedNanoseconds != nil)
    #expect(timing.totalLatencyNanoseconds != nil)
    #expect(timing.totalLatencyNanoseconds! > 0)
  }
}

@Suite struct ISAEngineComparisonHarnessTests {
  private func makeSample(
    workloadName: String = "test-workload",
    workloadRevision: String = "rev1",
    wallTime: UInt64 = 1_000_000_000,
    retiredInstructions: UInt64 = 1_000_000
  ) -> ISAEngineProfileSample {
    ISAEngineProfileSample(
      configuration: .init(
        tier: "Tier1", cpuProfile: "compatibleV1",
        schedulingMode: "serialized", firmwareVersion: "v1",
        kernelInitrdDiskHash: String(repeating: "a", count: 64)),
      workloadName: workloadName, workloadRevision: workloadRevision,
      wallTimeNanoseconds: wallTime,
      retiredGuestInstructions: retiredInstructions,
      compilationTimeNanoseconds: 100_000_000,
      compilationAttempts: 100, compilationDeclines: 10,
      translationCacheEntryCount: 500,
      translationCacheAllocatedBytes: 64 * 1024 * 1024,
      translationCacheMaximumBytes: 128 * 1024 * 1024,
      translationCacheHits: 9000, translationCacheMisses: 1000,
      translationCacheInvalidations: 5,
      tier1DeclineInterpreterHelper: 5, tier1DeclineNativeEmitter: 5,
      tier1CompiledBlocks: 90, tier1CompilationAttempts: 100,
      tier1CompilationDeclines: 10,
      nativeDispatcherEntries: 800, directlyChainedBlocks: 400,
      chainTargetAttempts: 500, chainTargetAccepts: 400,
      indirectBranchTargetCacheHits: 300, indirectBranchTargetCacheMisses: 50,
      shadowReturnStackHits: 200, shadowReturnStackMisses: 10,
      helperCalls: 5000, memoryFaultSlowPaths: 20,
      lazyFlagMaterializations: 100,
      codeCacheWraps: 0, codeCacheEvictedBlocks: 0,
      negativeCacheHits: 80, negativeCacheMisses: 20,
      pendingWorkExits: 100)
  }

  @Test func comparisonComputesSpeedup() {
    let baseline = makeSample(wallTime: 2_000_000_000)
    let comparison = makeSample(wallTime: 1_000_000_000)

    let result = ISAEngineComparisonHarness.compare(
      baseline: baseline, comparison: comparison,
      baselineTier: .interpreter, comparisonTier: .tier1)

    #expect(result.valid)
    #expect(result.speedup == 2.0)  // baseline is 2x slower
    #expect(result.instructionDelta == 0)  // same retired count
  }

  @Test func comparisonInvalidForDifferentWorkloads() {
    let baseline = makeSample(workloadName: "workload-A")
    let comparison = makeSample(workloadName: "workload-B")

    let result = ISAEngineComparisonHarness.compare(
      baseline: baseline, comparison: comparison,
      baselineTier: .interpreter, comparisonTier: .tier1)

    #expect(!result.valid)
  }

  @Test func comparisonInvalidForDifferentRevisions() {
    let baseline = makeSample(workloadRevision: "rev1")
    let comparison = makeSample(workloadRevision: "rev2")

    let result = ISAEngineComparisonHarness.compare(
      baseline: baseline, comparison: comparison,
      baselineTier: .interpreter, comparisonTier: .tier1)

    #expect(!result.valid)
  }

  @Test func comparisonReportGeneratesPairwiseComparisons() {
    let interpreter = makeSample(wallTime: 3_000_000_000)
    let tier1 = makeSample(wallTime: 2_000_000_000)
    let tier2 = makeSample(wallTime: 1_500_000_000)

    let results = ISAEngineComparisonHarness.generateComparisonReport(
      samples: [
        (.interpreter, interpreter),
        (.tier1, tier1),
        (.tier2, tier2),
      ])

    #expect(results.count == 2)
    #expect(results[0].baselineTier == .interpreter)
    #expect(results[0].comparisonTier == .tier1)
    #expect(results[0].speedup == 1.5)  // 3B / 2B
    #expect(results[1].baselineTier == .interpreter)
    #expect(results[1].comparisonTier == .tier2)
    #expect(results[1].speedup == 2.0)  // 3B / 1.5B
  }

  @Test func tier1DeclineAttributionDoesNotInferWorkFromHotSites() {
    var diagnostics = DoryARM64BaselineExecutorDiagnostics(
      recentLookupHits: 0, blockCacheLookupHits: 0, dictionaryLookupHits: 0,
      lookupMisses: 0, memoryGenerationHits: 0, byteValidationHits: 0,
      sharedCodeHits: 0, compiledBlocks: 0, tier1CompilationAttempts: 100,
      tier1CompilationDeclines: 10, tier1CompiledBlocks: 90,
      lazyFlagMaterializations: 0, declinedCompilations: 10,
      negativeCacheHits: 80, negativeCacheMisses: 20,
      negativeGenerationMismatches: 0, negativeEntryCount: 2,
      negativeCacheHotSites: [
        .init(
          guestRIP: 0x1000, executionMode: .long64, instructionBudget: 64,
          addressSpaceID: 0, privilegeLevel: 0, pagingEnabled: true,
          guestByteCount: 3, instructionBytes: [0x48, 0x01, 0xC0],
          declineReason: .interpreterHelper, hitCount: 500),
        .init(
          guestRIP: 0x2000, executionMode: .long64, instructionBudget: 64,
          addressSpaceID: 0, privilegeLevel: 0, pagingEnabled: true,
          guestByteCount: 2, instructionBytes: [0x0F, 0x01],
          declineReason: .nativeEmitter, hitCount: 300),
      ],
      codeCacheWraps: 0, codeCacheEvictedBlocks: 0,
      nativeTraceAttempts: 0, nativeTraceReplays: 0,
      codeGenerationChecks: 0, codeGenerationMismatches: 0,
      chainedExecutionCalls: 0, chainedRequestedInstructions: 0,
      chainedRetiredInstructions: 0, pendingWorkExits: 0,
      pendingWorkMaximumRetiredInstructions: 0,
      nativeDispatcherEntries: 0, directChainPatches: 0,
      directChainUnlinks: 0, directlyChainedBlocks: 0,
      chainTargetAttempts: 0, chainTargetAccepts: 0,
      chainTargetSourceShapeRejections: 0,
      chainTargetBoundaryRejections: 0,
      chainTargetRestartableWriterRejections: 0,
      chainTargetMissingMemoryRejections: 0,
      chainTargetInterpreterGuardRejections: 0,
      chainTargetCompilerABIRejections: 0,
      chainTargetPublicationRejections: 0,
      indirectBranchTargetCacheHits: 0, indirectBranchTargetCacheMisses: 0,
      indirectBranchTargetCacheFills: 0, indirectBranchTargetCacheHitRate: nil,
      shadowReturnStackHits: 0, shadowReturnStackMisses: 0,
      shadowReturnStackPushes: 0, shadowReturnStackHitRate: nil,
      translationCacheEntryCount: 0, translationCacheAllocatedBytes: 0,
      translationCacheAddressSpaceGeneration: 0,
      translationCacheInvalidations: 0, translationCacheHits: 0,
      translationCacheMisses: 0, translationCacheFills: 0,
      translationCachePageFaults: 0, translationCacheFallbacks: 0,
      translationCacheHitRate: 0)

    // A typed function reference protects the legacy public return signature.
    let attribute: (DoryARM64BaselineExecutorDiagnostics) -> [ISATier1DeclineAttribution] =
      ISAEngineComparisonHarness.attributeTier1Declines(from:)
    let attributions: [ISATier1DeclineAttribution] = attribute(diagnostics)
    #expect(attributions.isEmpty)
    #expect(ISAEngineComparisonHarness.confirmedInterpreterFallbackCounters(from: diagnostics) == nil)
    let sample = ISAEngineProfiler.sample(
      configuration: .init(tier: "Tier1", cpuProfile: "compatibleV1", schedulingMode: "serialized",
        firmwareVersion: "v1", kernelInitrdDiskHash: "fixture"),
      workloadName: "w", workloadRevision: "r", wallTimeNanoseconds: 1,
      diagnostics: diagnostics, retiredInstructions: 100, compilationTimeNanoseconds: 0,
      translationCacheMaximumBytes: 4096)
    #expect(sample.confirmedInterpreterFallback == nil)
    #expect(sample.tier1DeclineInterpreterHelper == 0)
    #expect(sample.tier1DeclineNativeEmitter == 0)
    let report = ISAEngineCostReportGenerator.generate(from: sample)
    #expect(report.costCategories.first { $0.name == "tier1Declines" }?
      .evidence.contains("unavailable") == true)
    #expect(!report.optimizationOpportunities.contains { $0.targetCostCategory == "tier1Declines" })
    #expect(report.costCategories.first { $0.name == "tier1Declines" }?.counterPressure == 0)

    let helperSite = DoryARM64InterpreterFallbackSite(
      guestRIP: 0x1000, executionMode: .long64, addressSpaceID: 0,
      privilegeLevel: 0, pagingEnabled: true, declineReason: .interpreterHelper)
    let emitterSite = DoryARM64InterpreterFallbackSite(
      guestRIP: 0x2000, executionMode: .long64, addressSpaceID: 0,
      privilegeLevel: 0, pagingEnabled: true, declineReason: .nativeEmitter)
    let zeroSite = DoryARM64InterpreterFallbackSite(
      guestRIP: 0x3000, executionMode: .long64, addressSpaceID: 0,
      privilegeLevel: 0, pagingEnabled: true, declineReason: .nativeEmitter)
    diagnostics.confirmedInterpreterFallback = .init(work: [
      .init(site: helperSite, retiredInstructions: 7),
      .init(site: emitterSite, retiredInstructions: 3),
      .init(site: nil, retiredInstructions: 11),
      .init(site: zeroSite, retiredInstructions: 0),
    ])
    let confirmed = attribute(diagnostics)
    #expect(confirmed == [
      .init(guestRIP: 0x1000, executionMode: "long64", declineReason: "interpreterHelper",
        hitCount: 0, estimatedRuntimeExitCount: 7),
      .init(guestRIP: 0x2000, executionMode: "long64", declineReason: "nativeEmitter",
        hitCount: 0, estimatedRuntimeExitCount: 3),
    ])
    let counters: DoryARM64InterpreterFallbackCounters? =
      ISAEngineComparisonHarness.confirmedInterpreterFallbackCounters(from: diagnostics)
    #expect(counters == diagnostics.confirmedInterpreterFallback)
    #expect(counters?.retiredInstructions(for: nil) == 11)
    let confirmedSample = ISAEngineProfiler.sample(
      configuration: sample.configuration, workloadName: "w", workloadRevision: "r",
      wallTimeNanoseconds: 1, diagnostics: diagnostics, retiredInstructions: 100,
      compilationTimeNanoseconds: 0, translationCacheMaximumBytes: 4096)
    let helper: UInt64 = confirmedSample.tier1DeclineInterpreterHelper
    let emitter: UInt64 = confirmedSample.tier1DeclineNativeEmitter
    #expect(helper == 7)
    #expect(emitter == 3)

    diagnostics.confirmedInterpreterFallback = .init(work: [.init(site: nil, retiredInstructions: 11)])
    #expect(attribute(diagnostics).isEmpty)
    diagnostics.confirmedInterpreterFallback = .init()
    #expect(attribute(diagnostics).isEmpty)
    #expect(ISAEngineComparisonHarness.confirmedInterpreterFallbackCounters(from: diagnostics) != nil)
  }
}

// MARK: - P2-05 live receipt

@Suite struct ISAEngineRunResultMappingTests {
  @Test func mapsPoweredOffStop() {
    let result = ISAEngineRunResult(.poweredOff(instructionCount: 1234))
    if case .poweredOff(let n) = result {
      #expect(n == 1234)
    } else {
      Issue.record("expected poweredOff")
    }
    #expect(result.description == "poweredOff(instructions=1234)")
  }

  @Test func mapsHaltedStop() {
    let result = ISAEngineRunResult(.halted(instructionCount: 5678))
    if case .halted(let n) = result {
      #expect(n == 5678)
    } else {
      Issue.record("expected halted")
    }
  }

  @Test func mapsResetStop() {
    let result = ISAEngineRunResult(.reset(instructionCount: 9))
    if case .reset(let n) = result {
      #expect(n == 9)
    } else {
      Issue.record("expected reset")
    }
  }

  @Test func mapsInstructionBudgetStop() {
    let result = ISAEngineRunResult(.instructionBudget(1_000_000))
    if case .instructionBudget(let n) = result {
      #expect(n == 1_000_000)
    } else {
      Issue.record("expected instructionBudget")
    }
  }
}

@Suite struct ISAEngineReceiptOutcomeTests {
  private func zeroSample() -> ISAEngineProfileSample {
    ISAEngineProfileSample(
      configuration: .init(
        tier: "Tier1-direct-only", cpuProfile: "compatibleV1",
        schedulingMode: "serialized", firmwareVersion: "v1",
        kernelInitrdDiskHash: String(repeating: "a", count: 64)),
      workloadName: "w", workloadRevision: "r",
      wallTimeNanoseconds: 0, retiredGuestInstructions: 0,
      compilationTimeNanoseconds: 0, compilationAttempts: 0, compilationDeclines: 0,
      translationCacheEntryCount: 0, translationCacheAllocatedBytes: 0,
      translationCacheMaximumBytes: 128 * 1024 * 1024,
      translationCacheHits: 0, translationCacheMisses: 0, translationCacheInvalidations: 0,
      tier1DeclineInterpreterHelper: 0, tier1DeclineNativeEmitter: 0,
      tier1CompiledBlocks: 0, tier1CompilationAttempts: 0, tier1CompilationDeclines: 0,
      nativeDispatcherEntries: 0, directlyChainedBlocks: 0,
      chainTargetAttempts: 0, chainTargetAccepts: 0,
      indirectBranchTargetCacheHits: 0, indirectBranchTargetCacheMisses: 0,
      shadowReturnStackHits: 0, shadowReturnStackMisses: 0,
      helperCalls: 0, memoryFaultSlowPaths: 0, lazyFlagMaterializations: 0,
      codeCacheWraps: 0, codeCacheEvictedBlocks: 0,
      negativeCacheHits: 0, negativeCacheMisses: 0, pendingWorkExits: 0)
  }

  private func makeReceipt(result: ISAEngineRunResult, condition: ISAEngineCompletionCondition)
    -> ISAEngineProfileReceipt
  {
    ISAEngineReceiptBuilder.build(
      configuration: .init(
        tier: "Tier1-direct-only", cpuProfile: "compatibleV1",
        schedulingMode: "serialized", firmwareVersion: "v1",
        kernelInitrdDiskHash: String(repeating: "a", count: 64)),
      workloadName: "w", workloadRevision: "r",
      completionCondition: condition,
      startSample: zeroSample(), endSample: zeroSample(),
      hostTiming: .init(startNanoseconds: 0, endNanoseconds: 0),
      result: result)
  }

  @Test func completedWhenStopMatchesCondition() {
    let receipt = makeReceipt(
      result: .poweredOff(instructionCount: 100),
      condition: .poweredOff)
    #expect(receipt.outcome == .completed)
    #expect(receipt.isCompleted)
  }

  @Test func stoppedWhenStopDoesNotMatchCondition() {
    let receipt = makeReceipt(
      result: .halted(instructionCount: 100),
      condition: .poweredOff)
    #expect(receipt.outcome == .stopped)
    #expect(!receipt.isCompleted)
  }

  @Test func stoppedWhenInstructionBudgetExhaustedBeforePowerOff() {
    let receipt = makeReceipt(
      result: .instructionBudget(1_000_000),
      condition: .poweredOff)
    #expect(receipt.outcome == .stopped)
    #expect(!receipt.isCompleted)
  }

  @Test func completedForInstructionBudgetCondition() {
    let receipt = makeReceipt(
      result: .instructionBudget(1_000_000),
      condition: .instructionBudget(instructionCount: 1_000_000))
    #expect(receipt.outcome == .completed)
    #expect(receipt.isCompleted)
  }

  @Test func stopsWhenInstructionBudgetCountDoesNotMatchCondition() {
    let receipt = makeReceipt(
      result: .instructionBudget(999_999),
      condition: .instructionBudget(instructionCount: 1_000_000))
    #expect(receipt.outcome == .stopped)
    #expect(!receipt.isCompleted)
  }

  @Test func timeoutForWallTimeBudgetResult() {
    let receipt = makeReceipt(result: .wallTimeBudget, condition: .wallTimeBudget(seconds: 1))
    #expect(receipt.outcome == .timeout)
    #expect(!receipt.isCompleted)
  }

  @Test func failedForFailedResult() {
    let receipt = makeReceipt(result: .failed("boom"), condition: .poweredOff)
    #expect(receipt.outcome == .failed)
    #expect(!receipt.isCompleted)
  }

  @Test func stopReasonCarriesResultDescription() {
    let receipt = makeReceipt(result: .failed("boom"), condition: .poweredOff)
    #expect(receipt.stopReason == "failed(boom)")
  }
}

@Suite struct ISAEngineCostReportReceiptGatingTests {
  private func sample(retired: UInt64 = 1_000_000, wallTime: UInt64 = 1_000_000_000)
    -> ISAEngineProfileSample
  {
    ISAEngineProfileSample(
      configuration: .init(
        tier: "Tier1-direct-only", cpuProfile: "compatibleV1",
        schedulingMode: "serialized", firmwareVersion: "v1",
        kernelInitrdDiskHash: String(repeating: "a", count: 64)),
      workloadName: "w", workloadRevision: "r",
      wallTimeNanoseconds: wallTime, retiredGuestInstructions: retired,
      compilationTimeNanoseconds: 100_000_000, compilationAttempts: 100, compilationDeclines: 10,
      translationCacheEntryCount: 500, translationCacheAllocatedBytes: 64 * 1024 * 1024,
      translationCacheMaximumBytes: 128 * 1024 * 1024,
      translationCacheHits: 9000, translationCacheMisses: 1000, translationCacheInvalidations: 5,
      tier1DeclineInterpreterHelper: 5, tier1DeclineNativeEmitter: 5,
      tier1CompiledBlocks: 90, tier1CompilationAttempts: 100, tier1CompilationDeclines: 10,
      nativeDispatcherEntries: 800, directlyChainedBlocks: 400,
      chainTargetAttempts: 500, chainTargetAccepts: 400,
      indirectBranchTargetCacheHits: 300, indirectBranchTargetCacheMisses: 50,
      shadowReturnStackHits: 200, shadowReturnStackMisses: 10,
      helperCalls: 5000, memoryFaultSlowPaths: 20, lazyFlagMaterializations: 100,
      codeCacheWraps: 0, codeCacheEvictedBlocks: 0,
      negativeCacheHits: 80, negativeCacheMisses: 20, pendingWorkExits: 100)
  }

  private func makeReceipt(
    outcome: ISAEngineReceiptOutcome,
    tierEvidence: ISAEngineTierEvidence = .verified(observedTier: .baselineJIT)
  ) -> ISAEngineProfileReceipt {
    let result: ISAEngineRunResult = switch outcome {
    case .completed: .poweredOff(instructionCount: 1_000_000)
    case .timeout: .wallTimeBudget
    case .stopped: .halted(instructionCount: 100)
    case .failed: .failed("boom")
    }
    return ISAEngineReceiptBuilder.build(
      configuration: .init(
        tier: "Tier1-direct-only", cpuProfile: "compatibleV1",
        schedulingMode: "serialized", firmwareVersion: "v1",
        kernelInitrdDiskHash: String(repeating: "a", count: 64)),
      workloadName: "w", workloadRevision: "r",
      completionCondition: .poweredOff,
      startSample: sample(retired: 0, wallTime: 0), endSample: sample(),
      hostTiming: .init(startNanoseconds: 0, endNanoseconds: 1_000_000_000),
      result: result,
      observedTierEvidence: tierEvidence)
  }

  @Test func completedReceiptProducesCostReport() throws {
    let original = makeReceipt(outcome: .completed)
    let receipt = try JSONDecoder().decode(
      ISAEngineProfileReceipt.self, from: JSONEncoder().encode(original))
    #expect(receipt == original)
    #expect(receipt.isCompleted)
    #expect(receipt.isProvenanceVerified)
    let report = ISAEngineCostReportGenerator.generate(from: receipt)
    #expect(report != nil)
    #expect(report?.retiredGuestInstructions == 1_000_000)
    #expect(report?.wallTimeNanoseconds == 1_000_000_000)
  }

  @Test(arguments: ["startSample", "endSample"], [
    "tier", "cpuProfile", "schedulingMode", "firmwareVersion", "kernelInitrdDiskHash",
    "workloadName", "workloadRevision",
  ])
  func snapshotIdentityDriftProducesNoCostReport(snapshotKey: String, field: String) throws {
    let original = makeReceipt(outcome: .completed)
    #expect(original.isProvenanceVerified)
    #expect(ISAEngineCostReportGenerator.generate(from: original) != nil)

    // Change exactly one serialized identity field, retaining completed,
    // tier-verified evidence with monotonic counters and valid timing.
    var payload = try #require(JSONSerialization.jsonObject(
      with: JSONEncoder().encode(original)) as? [String: Any])
    var snapshot = try #require(payload[snapshotKey] as? [String: Any])
    if field == "workloadName" || field == "workloadRevision" {
      snapshot[field] = try #require(snapshot[field] as? String) + "-drift"
    } else {
      var configuration = try #require(snapshot["configuration"] as? [String: Any])
      configuration[field] = try #require(configuration[field] as? String) + "-drift"
      snapshot["configuration"] = configuration
    }
    payload[snapshotKey] = snapshot
    let forged = try JSONDecoder().decode(ISAEngineProfileReceipt.self,
      from: JSONSerialization.data(withJSONObject: payload))

    #expect(forged.isCompleted)
    #expect(forged.counterRegressions.isEmpty)
    #expect(forged.observedTierEvidence == original.observedTierEvidence)
    #expect(forged.hostTiming == original.hostTiming)
    #expect(!forged.isProvenanceVerified)
    #expect(ISAEngineCostReportGenerator.generate(from: forged) == nil)
  }

  @Test func timeoutReceiptProducesNoCostReport() {
    let receipt = makeReceipt(outcome: .timeout)
    #expect(ISAEngineCostReportGenerator.generate(from: receipt) == nil)
  }

  @Test func stoppedReceiptProducesNoCostReport() {
    let receipt = makeReceipt(outcome: .stopped)
    #expect(ISAEngineCostReportGenerator.generate(from: receipt) == nil)
  }

  @Test func failedReceiptProducesNoCostReport() {
    let receipt = makeReceipt(outcome: .failed)
    #expect(ISAEngineCostReportGenerator.generate(from: receipt) == nil)
  }

  @Test func mismatchedTierReceiptProducesNoCostReport() {
    let receipt = makeReceipt(
      outcome: .completed,
      tierEvidence: .mismatch(declaredTier: "Tier1-direct-only", observedTier: .interpreter))
    #expect(receipt.isCompleted)
    #expect(!receipt.isProvenanceVerified)
    #expect(ISAEngineCostReportGenerator.generate(from: receipt) == nil)
  }

  @Test func unverifiedTierReceiptProducesNoCostReport() {
    let receipt = makeReceipt(outcome: .completed, tierEvidence: .unverified)
    #expect(receipt.isCompleted)
    #expect(!receipt.isProvenanceVerified)
    #expect(ISAEngineCostReportGenerator.generate(from: receipt) == nil)
  }
}

// MARK: - P2-05 per-run delta evidence

@Suite struct ISAEngineRunDeltaTests {
  private let configuration = ISAEngineProfileConfiguration(
    tier: "Tier1-direct-only", cpuProfile: "compatibleV1",
    schedulingMode: "serialized", firmwareVersion: "v1",
    kernelInitrdDiskHash: String(repeating: "a", count: 64))

  private func sample(
    retired: UInt64 = 0, cacheHits: UInt64 = 0, cacheMisses: UInt64 = 0,
    helperCalls: UInt64 = 0, lazyFlags: UInt64 = 0,
    chainAttempts: UInt64 = 0, chainAccepts: UInt64 = 0,
    pendingExits: UInt64 = 0, wallTime: UInt64 = 0,
    fallback: DoryARM64InterpreterFallbackCounters? = nil
  ) -> ISAEngineProfileSample {
    ISAEngineProfileSample(
      configuration: configuration,
      workloadName: "w", workloadRevision: "r",
      wallTimeNanoseconds: wallTime, retiredGuestInstructions: retired,
      compilationTimeNanoseconds: 0, compilationAttempts: 0, compilationDeclines: 0,
      translationCacheEntryCount: 0, translationCacheAllocatedBytes: 0,
      translationCacheMaximumBytes: 128 * 1024 * 1024,
      translationCacheHits: cacheHits, translationCacheMisses: cacheMisses,
      translationCacheInvalidations: 0,
      tier1DeclineInterpreterHelper: 0, tier1DeclineNativeEmitter: 0,
      tier1CompiledBlocks: 0, tier1CompilationAttempts: 0, tier1CompilationDeclines: 0,
      nativeDispatcherEntries: 0, directlyChainedBlocks: 0,
      chainTargetAttempts: chainAttempts, chainTargetAccepts: chainAccepts,
      indirectBranchTargetCacheHits: 0, indirectBranchTargetCacheMisses: 0,
      shadowReturnStackHits: 0, shadowReturnStackMisses: 0,
      helperCalls: helperCalls, memoryFaultSlowPaths: 0,
      lazyFlagMaterializations: lazyFlags,
      codeCacheWraps: 0, codeCacheEvictedBlocks: 0,
      negativeCacheHits: 0, negativeCacheMisses: 0, pendingWorkExits: pendingExits,
      confirmedInterpreterFallback: fallback)
  }

  @Test func confirmedFallbackDeltasPreserveUnknownAndRejectRegression() throws {
    let site = DoryARM64InterpreterFallbackSite(
      guestRIP: 0x1000, executionMode: .long64, addressSpaceID: 0,
      privilegeLevel: 0, pagingEnabled: false, declineReason: .interpreterHelper)
    func counters(_ known: UInt64, _ unknown: UInt64) -> DoryARM64InterpreterFallbackCounters {
      .init(work: [.init(site: site, retiredInstructions: known),
                   .init(site: nil, retiredInstructions: unknown)])
    }
    func receipt(_ start: DoryARM64InterpreterFallbackCounters?,
                 _ end: DoryARM64InterpreterFallbackCounters?) -> ISAEngineProfileReceipt {
      .init(configuration: configuration, workloadName: "w", workloadRevision: "r",
        completionCondition: .instructionBudget(instructionCount: 10), outcome: .completed,
        startSample: sample(fallback: start), endSample: sample(retired: 10, fallback: end),
        hostTiming: .init(startNanoseconds: 0, endNanoseconds: 100), stopReason: "instructionBudget(10)",
        observedTierEvidence: .verified(observedTier: .baselineJIT))
    }
    let valid = receipt(counters(8, 2), counters(13, 4))
    let delta = try #require(ISAEngineComparisonHarness.attributeTier1Declines(from: valid))
    #expect(delta.retiredInstructions(for: .interpreterHelper) == 5)
    #expect(delta.retiredInstructions(for: nil) == 2)
    #expect(valid.runSample.tier1DeclineInterpreterHelper == 5)
    #expect(valid.isProvenanceVerified)
    let category = try #require(ISAEngineCostReportGenerator.generate(from: valid)?
      .costCategories.first { $0.name == "tier1Declines" })
    #expect(category.counterPressure == 5)
    #expect(category.evidence.contains("unattributedRetiredInstructions=2"))
    for missing in [receipt(nil, nil), receipt(nil, counters(13, 4))] {
      #expect(missing.runSample.confirmedInterpreterFallback == nil)
      #expect(missing.runSample.tier1DeclineInterpreterHelper == 0)
      #expect(missing.runSample.tier1DeclineNativeEmitter == 0)
      #expect(ISAEngineComparisonHarness.attributeTier1Declines(from: missing) == nil)
      let report = try #require(ISAEngineCostReportGenerator.generate(from: missing))
      let category = try #require(report.costCategories.first { $0.name == "tier1Declines" })
      #expect(category.counterPressure == 0)
      #expect(category.evidence.contains("unavailable"))
      #expect(!report.optimizationOpportunities.contains { $0.targetCostCategory == "tier1Declines" })
    }
    for invalid in [receipt(counters(8, 2), counters(7, 4)),
                    receipt(counters(8, 2), counters(13, 1)),
                    receipt(counters(8, 2), .init()), receipt(counters(8, 2), nil),
                    receipt(.init(), nil)] {
      #expect(!invalid.counterRegressions.isEmpty)
      #expect(!invalid.isProvenanceVerified)
      #expect(ISAEngineComparisonHarness.attributeTier1Declines(from: invalid) == nil)
      #expect(ISAEngineCostReportGenerator.generate(from: invalid) == nil)
    }
    let encoded = try JSONEncoder().encode(valid)
    let decoded = try JSONDecoder().decode(ISAEngineProfileReceipt.self, from: encoded)
    #expect(decoded.runSample.confirmedInterpreterFallback == delta)
    let legacy = sample()
    #expect(try JSONDecoder().decode(ISAEngineProfileSample.self,
      from: JSONEncoder().encode(legacy)).confirmedInterpreterFallback == nil)
  }

  @Test func runSampleSubtractsStartFromEnd() {
    let receipt = ISAEngineProfileReceipt(
      configuration: configuration,
      workloadName: "w", workloadRevision: "r",
      completionCondition: .instructionBudget(instructionCount: 100),
      outcome: .completed,
      startSample: sample(retired: 1000, cacheHits: 500, cacheMisses: 200,
                          helperCalls: 50, chainAttempts: 100, chainAccepts: 80,
                          pendingExits: 30),
      endSample: sample(retired: 1500, cacheHits: 700, cacheMisses: 350,
                        helperCalls: 70, chainAttempts: 180, chainAccepts: 150,
                        pendingExits: 55),
      hostTiming: .init(startNanoseconds: 1_000_000, endNanoseconds: 5_000_000),
      stopReason: "instructionBudget(100)",
      observedTierEvidence: .verified(observedTier: .baselineJIT))

    let delta = receipt.runSample
    #expect(delta.retiredGuestInstructions == 500)       // 1500 - 1000
    #expect(delta.translationCacheHits == 200)            // 700 - 500
    #expect(delta.translationCacheMisses == 150)          // 350 - 200
    #expect(delta.helperCalls == 20)                      // 70 - 50
    #expect(delta.chainTargetAttempts == 80)              // 180 - 100
    #expect(delta.chainTargetAccepts == 70)               // 150 - 80
    #expect(delta.pendingWorkExits == 25)                 // 55 - 30
    #expect(delta.wallTimeNanoseconds == 4_000_000)       // host timing, not counter
  }

  @Test func secondRunDeltaContainsOnlySecondRunCounters() {
    // Simulate two consecutive runs on the same machine.  The first run
    // retires 1000 instructions; the second run retires 500 more.  The
    // second receipt's runSample must contain only the second run's
    // delta (500), not the cumulative total (1500).
    let run1End = sample(retired: 1000, cacheHits: 500, cacheMisses: 200,
                          helperCalls: 50, pendingExits: 30)
    let run2End = sample(retired: 1500, cacheHits: 700, cacheMisses: 350,
                          helperCalls: 70, pendingExits: 55)

    let receipt1 = ISAEngineProfileReceipt(
      configuration: configuration, workloadName: "w", workloadRevision: "r",
      completionCondition: .instructionBudget(instructionCount: 1000),
      outcome: .completed,
      startSample: sample(),  // all zeros
      endSample: run1End,
      hostTiming: .init(startNanoseconds: 0, endNanoseconds: 1_000_000),
      stopReason: "instructionBudget(1000)",
      observedTierEvidence: .verified(observedTier: .baselineJIT))

    let receipt2 = ISAEngineProfileReceipt(
      configuration: configuration, workloadName: "w", workloadRevision: "r",
      completionCondition: .instructionBudget(instructionCount: 500),
      outcome: .completed,
      startSample: run1End,  // second run starts where first ended
      endSample: run2End,
      hostTiming: .init(startNanoseconds: 1_000_000, endNanoseconds: 2_000_000),
      stopReason: "instructionBudget(500)",
      observedTierEvidence: .verified(observedTier: .baselineJIT))

    let delta1 = receipt1.runSample
    let delta2 = receipt2.runSample

    // First receipt: delta equals the end snapshot (start was zero).
    #expect(delta1.retiredGuestInstructions == 1000)
    #expect(delta1.translationCacheHits == 500)
    #expect(delta1.translationCacheMisses == 200)

    // Second receipt: delta contains only the second run's counters.
    #expect(delta2.retiredGuestInstructions == 500)       // 1500 - 1000
    #expect(delta2.translationCacheHits == 200)            // 700 - 500
    #expect(delta2.translationCacheMisses == 150)          // 350 - 200
    #expect(delta2.helperCalls == 20)                      // 70 - 50
    #expect(delta2.pendingWorkExits == 25)                 // 55 - 30
  }

  @Test func counterRegressionIsRejectedNotUnderflowed() {
    // If a counter somehow regresses (end < start), the delta must
    // clamp to 0 rather than underflowing.
    let receipt = ISAEngineProfileReceipt(
      configuration: configuration, workloadName: "w", workloadRevision: "r",
      completionCondition: .instructionBudget(instructionCount: 100),
      outcome: .completed,
      startSample: sample(retired: 2000, cacheHits: 1000),
      endSample: sample(retired: 1500, cacheHits: 800),
      hostTiming: .init(startNanoseconds: 0, endNanoseconds: 1_000_000),
      stopReason: "instructionBudget(100)",
      observedTierEvidence: .verified(observedTier: .baselineJIT))

    #expect(receipt.counterRegressions.contains("retiredGuestInstructions"))
    #expect(receipt.counterRegressions.contains("translationCacheHits"))
    #expect(receipt.runSample.retiredGuestInstructions == 0)  // clamped, not underflowed
    #expect(receipt.runSample.translationCacheHits == 0)
    #expect(!receipt.isProvenanceVerified)
    #expect(ISAEngineCostReportGenerator.generate(from: receipt) == nil)
  }
}

// MARK: - P2-05 tier evidence

@Suite struct ISAEngineTierEvidenceTests {
  @Test func verifiedWhenDeclaredTierMatchesObserved() {
    let evidence = ISAEngineReceiptBuilder.resolveTierEvidence(
      declaredTier: "Tier1-direct-only", observedTier: .baselineJIT)
    if case .verified(let tier) = evidence {
      #expect(tier == .baselineJIT)
    } else {
      Issue.record("expected verified")
    }
  }

  @Test func mismatchWhenDeclaredTierDoesNotMatchObserved() {
    let evidence = ISAEngineReceiptBuilder.resolveTierEvidence(
      declaredTier: "Tier1-direct-only", observedTier: .interpreter)
    if case .mismatch(let declared, let observed) = evidence {
      #expect(declared == "Tier1-direct-only")
      #expect(observed == .interpreter)
    } else {
      Issue.record("expected mismatch")
    }
  }

  @Test func mismatchForUnknownDeclaredTier() {
    let evidence = ISAEngineReceiptBuilder.resolveTierEvidence(
      declaredTier: "unknown-tier", observedTier: .baselineJIT)
    if case .mismatch = evidence {
      // ok
    } else {
      Issue.record("expected mismatch for unknown tier")
    }
  }

  @Test func interpreterTierMapsCorrectly() {
    let evidence = ISAEngineReceiptBuilder.resolveTierEvidence(
      declaredTier: "interpreter", observedTier: .interpreter)
    if case .verified = evidence {
      // ok
    } else {
      Issue.record("expected verified for interpreter")
    }
  }

  @Test func tier2MapsToOptimizingJIT() {
    let evidence = ISAEngineReceiptBuilder.resolveTierEvidence(
      declaredTier: "Tier2", observedTier: .optimizingJIT)
    if case .verified = evidence {
      // ok
    } else {
      Issue.record("expected verified for Tier2/optimizingJIT")
    }
  }
}

// MARK: - P2-05 cost report honesty

@Suite struct ISAEngineCostReportHonestyTests {
  private func sample(
    wallTime: UInt64 = 1_000_000_000,
    compilationTime: UInt64 = 100_000_000,
    cacheMisses: UInt64 = 1000,
    helperCalls: UInt64 = 5000,
    lazyFlags: UInt64 = 100
  ) -> ISAEngineProfileSample {
    ISAEngineProfileSample(
      configuration: .init(
        tier: "Tier1-direct-only", cpuProfile: "compatibleV1",
        schedulingMode: "serialized", firmwareVersion: "v1",
        kernelInitrdDiskHash: String(repeating: "a", count: 64)),
      workloadName: "test", workloadRevision: "rev1",
      wallTimeNanoseconds: wallTime, retiredGuestInstructions: 1_000_000,
      compilationTimeNanoseconds: compilationTime,
      compilationAttempts: 100, compilationDeclines: 10,
      translationCacheEntryCount: 500,
      translationCacheAllocatedBytes: 64 * 1024 * 1024,
      translationCacheMaximumBytes: 128 * 1024 * 1024,
      translationCacheHits: 9000, translationCacheMisses: cacheMisses,
      translationCacheInvalidations: 5,
      tier1DeclineInterpreterHelper: 5, tier1DeclineNativeEmitter: 5,
      tier1CompiledBlocks: 90, tier1CompilationAttempts: 100,
      tier1CompilationDeclines: 10,
      nativeDispatcherEntries: 800, directlyChainedBlocks: 400,
      chainTargetAttempts: 500, chainTargetAccepts: 400,
      indirectBranchTargetCacheHits: 300, indirectBranchTargetCacheMisses: 50,
      shadowReturnStackHits: 200, shadowReturnStackMisses: 10,
      helperCalls: helperCalls, memoryFaultSlowPaths: 20,
      lazyFlagMaterializations: lazyFlags,
      codeCacheWraps: 0, codeCacheEvictedBlocks: 0,
      negativeCacheHits: 80, negativeCacheMisses: 20, pendingWorkExits: 100)
  }

  @Test func counterCategoriesHaveZeroNanoseconds() {
    let report = ISAEngineCostReportGenerator.generate(from: sample())

    // Only measured categories (guestExecution, compilation) should have
    // non-zero estimatedNanoseconds.  All counter-pressure categories
    // must have 0 — no fabricated nanosecond attribution.
    let measuredCategories = report.costCategories.filter { $0.measured }
    let counterCategories = report.costCategories.filter { !$0.measured }

    #expect(!measuredCategories.isEmpty)
    #expect(!counterCategories.isEmpty)

    for cat in counterCategories {
      #expect(cat.estimatedNanoseconds == 0)
      #expect(cat.fractionOfWallTime == 0)
    }

    // Measured categories should have non-zero ns (when wall time > 0).
    for cat in measuredCategories {
      #expect(cat.measured == true)
    }
  }

  @Test func helperCallsNotDoubleCountedWithLazyFlags() {
    let report = ISAEngineCostReportGenerator.generate(
      from: sample(helperCalls: 5000, lazyFlags: 100))

    let helperCategory = report.costCategories.first { $0.name == "helperCalls" }
    #expect(helperCategory != nil)
    // The evidence should mention lazy flags are tracked separately.
    #expect(helperCategory!.evidence.contains("not double-counted"))
    // Counter pressure should be the helper call count, not helper + lazy.
    #expect(helperCategory!.counterPressure == 5000)
  }

  @Test func measuredCategoriesRankedBeforeCounterCategories() {
    let report = ISAEngineCostReportGenerator.generate(from: sample())

    // Measured categories should appear before counter-pressure categories.
    let firstNonMeasuredIndex = report.costCategories.firstIndex { !$0.measured }
    let lastMeasuredIndex = report.costCategories.lastIndex { $0.measured }
    if let firstNonMeasured = firstNonMeasuredIndex, let lastMeasured = lastMeasuredIndex {
      #expect(lastMeasured < firstNonMeasured)
    }
  }

  @Test func insufficiencyStatementWhenFewerThanThreeOpportunities() {
    // A sample with no cache misses, no code cache churn, no tier1
    // declines, and no chain issues should produce fewer than 3
    // opportunities, and the summary should note the insufficiency.
    let s = ISAEngineProfileSample(
      configuration: .init(
        tier: "Tier1-direct-only", cpuProfile: "compatibleV1",
        schedulingMode: "serialized", firmwareVersion: "v1",
        kernelInitrdDiskHash: String(repeating: "a", count: 64)),
      workloadName: "clean", workloadRevision: "rev1",
      wallTimeNanoseconds: 1_000_000_000, retiredGuestInstructions: 1_000_000,
      compilationTimeNanoseconds: 100_000_000,
      compilationAttempts: 100, compilationDeclines: 0,
      translationCacheEntryCount: 500,
      translationCacheAllocatedBytes: 64 * 1024 * 1024,
      translationCacheMaximumBytes: 128 * 1024 * 1024,
      translationCacheHits: 10000, translationCacheMisses: 0,
      translationCacheInvalidations: 0,
      tier1DeclineInterpreterHelper: 0, tier1DeclineNativeEmitter: 0,
      tier1CompiledBlocks: 100, tier1CompilationAttempts: 100,
      tier1CompilationDeclines: 0,
      nativeDispatcherEntries: 800, directlyChainedBlocks: 400,
      chainTargetAttempts: 500, chainTargetAccepts: 500,
      indirectBranchTargetCacheHits: 300, indirectBranchTargetCacheMisses: 0,
      shadowReturnStackHits: 200, shadowReturnStackMisses: 0,
      helperCalls: 0, memoryFaultSlowPaths: 0,
      lazyFlagMaterializations: 0,
      codeCacheWraps: 0, codeCacheEvictedBlocks: 0,
      negativeCacheHits: 0, negativeCacheMisses: 0, pendingWorkExits: 0)

    let report = ISAEngineCostReportGenerator.generate(from: s)
    #expect(report.optimizationOpportunities.count < 3)
    #expect(report.summary.contains("insufficient evidence"))
  }
}

// MARK: - P2-05 wall-time timeout semantics

@Suite struct ISAEngineWallTimeTimeoutTests {
  private let configuration = ISAEngineProfileConfiguration(
    tier: "Tier1-direct-only", cpuProfile: "compatibleV1",
    schedulingMode: "serialized", firmwareVersion: "v1",
    kernelInitrdDiskHash: String(repeating: "a", count: 64))

  @Test func wallTimeBudgetReceiptRecordsQuantumAndBetweenQuanta() {
    // A wall-time-budget receipt should record the instruction quantum
    // and that the deadline was observed only between quanta.
    let receipt = ISAEngineProfileReceipt(
      configuration: configuration,
      workloadName: "w", workloadRevision: "r",
      completionCondition: .wallTimeBudget(seconds: 1),
      outcome: .timeout,
      startSample: ISAEngineProfileSample(
        configuration: configuration, workloadName: "w", workloadRevision: "r",
        wallTimeNanoseconds: 0, retiredGuestInstructions: 0,
        compilationTimeNanoseconds: 0, compilationAttempts: 0, compilationDeclines: 0,
        translationCacheEntryCount: 0, translationCacheAllocatedBytes: 0,
        translationCacheMaximumBytes: 128 * 1024 * 1024,
        translationCacheHits: 0, translationCacheMisses: 0, translationCacheInvalidations: 0,
        tier1DeclineInterpreterHelper: 0, tier1DeclineNativeEmitter: 0,
        tier1CompiledBlocks: 0, tier1CompilationAttempts: 0, tier1CompilationDeclines: 0,
        nativeDispatcherEntries: 0, directlyChainedBlocks: 0,
        chainTargetAttempts: 0, chainTargetAccepts: 0,
        indirectBranchTargetCacheHits: 0, indirectBranchTargetCacheMisses: 0,
        shadowReturnStackHits: 0, shadowReturnStackMisses: 0,
        helperCalls: 0, memoryFaultSlowPaths: 0, lazyFlagMaterializations: 0,
        codeCacheWraps: 0, codeCacheEvictedBlocks: 0,
        negativeCacheHits: 0, negativeCacheMisses: 0, pendingWorkExits: 0),
      endSample: ISAEngineProfileSample(
        configuration: configuration, workloadName: "w", workloadRevision: "r",
        wallTimeNanoseconds: 1_000_000_000, retiredGuestInstructions: 5_000_000,
        compilationTimeNanoseconds: 0, compilationAttempts: 100, compilationDeclines: 5,
        translationCacheEntryCount: 50, translationCacheAllocatedBytes: 1024,
        translationCacheMaximumBytes: 128 * 1024 * 1024,
        translationCacheHits: 400, translationCacheMisses: 100, translationCacheInvalidations: 2,
        tier1DeclineInterpreterHelper: 5, tier1DeclineNativeEmitter: 5,
        tier1CompiledBlocks: 90, tier1CompilationAttempts: 100, tier1CompilationDeclines: 10,
        nativeDispatcherEntries: 800, directlyChainedBlocks: 400,
        chainTargetAttempts: 500, chainTargetAccepts: 400,
        indirectBranchTargetCacheHits: 300, indirectBranchTargetCacheMisses: 50,
        shadowReturnStackHits: 200, shadowReturnStackMisses: 10,
        helperCalls: 0, memoryFaultSlowPaths: 20, lazyFlagMaterializations: 100,
        codeCacheWraps: 0, codeCacheEvictedBlocks: 0,
        negativeCacheHits: 80, negativeCacheMisses: 20, pendingWorkExits: 100),
      hostTiming: .init(startNanoseconds: 0, endNanoseconds: 1_000_000_000),
      stopReason: "wallTimeBudget",
      observedTierEvidence: .verified(observedTier: .baselineJIT),
      wallTimeInstructionQuantum: 10_000_000,
      deadlineObservedBetweenQuanta: true)

    #expect(receipt.outcome == .timeout)
    #expect(!receipt.isCompleted)
    #expect(receipt.wallTimeInstructionQuantum == 10_000_000)
    #expect(receipt.deadlineObservedBetweenQuanta == true)
    // A timeout receipt must not produce a cost report.
    #expect(ISAEngineCostReportGenerator.generate(from: receipt) == nil)
  }

  @Test func nonWallTimeReceiptHasNoQuantum() {
    let receipt = ISAEngineProfileReceipt(
      configuration: configuration,
      workloadName: "w", workloadRevision: "r",
      completionCondition: .instructionBudget(instructionCount: 100),
      outcome: .completed,
      startSample: ISAEngineProfileSample(
        configuration: configuration, workloadName: "w", workloadRevision: "r",
        wallTimeNanoseconds: 0, retiredGuestInstructions: 0,
        compilationTimeNanoseconds: 0, compilationAttempts: 0, compilationDeclines: 0,
        translationCacheEntryCount: 0, translationCacheAllocatedBytes: 0,
        translationCacheMaximumBytes: 128 * 1024 * 1024,
        translationCacheHits: 0, translationCacheMisses: 0, translationCacheInvalidations: 0,
        tier1DeclineInterpreterHelper: 0, tier1DeclineNativeEmitter: 0,
        tier1CompiledBlocks: 0, tier1CompilationAttempts: 0, tier1CompilationDeclines: 0,
        nativeDispatcherEntries: 0, directlyChainedBlocks: 0,
        chainTargetAttempts: 0, chainTargetAccepts: 0,
        indirectBranchTargetCacheHits: 0, indirectBranchTargetCacheMisses: 0,
        shadowReturnStackHits: 0, shadowReturnStackMisses: 0,
        helperCalls: 0, memoryFaultSlowPaths: 0, lazyFlagMaterializations: 0,
        codeCacheWraps: 0, codeCacheEvictedBlocks: 0,
        negativeCacheHits: 0, negativeCacheMisses: 0, pendingWorkExits: 0),
      endSample: ISAEngineProfileSample(
        configuration: configuration, workloadName: "w", workloadRevision: "r",
        wallTimeNanoseconds: 1_000_000, retiredGuestInstructions: 100,
        compilationTimeNanoseconds: 0, compilationAttempts: 10, compilationDeclines: 1,
        translationCacheEntryCount: 5, translationCacheAllocatedBytes: 512,
        translationCacheMaximumBytes: 128 * 1024 * 1024,
        translationCacheHits: 40, translationCacheMisses: 10, translationCacheInvalidations: 0,
        tier1DeclineInterpreterHelper: 0, tier1DeclineNativeEmitter: 0,
        tier1CompiledBlocks: 9, tier1CompilationAttempts: 10, tier1CompilationDeclines: 1,
        nativeDispatcherEntries: 80, directlyChainedBlocks: 40,
        chainTargetAttempts: 50, chainTargetAccepts: 40,
        indirectBranchTargetCacheHits: 30, indirectBranchTargetCacheMisses: 5,
        shadowReturnStackHits: 20, shadowReturnStackMisses: 1,
        helperCalls: 0, memoryFaultSlowPaths: 2, lazyFlagMaterializations: 10,
        codeCacheWraps: 0, codeCacheEvictedBlocks: 0,
        negativeCacheHits: 8, negativeCacheMisses: 2, pendingWorkExits: 10),
      hostTiming: .init(startNanoseconds: 0, endNanoseconds: 1_000_000),
      stopReason: "instructionBudget(100)",
      observedTierEvidence: .verified(observedTier: .baselineJIT))

    #expect(receipt.wallTimeInstructionQuantum == nil)
    #expect(receipt.deadlineObservedBetweenQuanta == nil)
  }
}

// MARK: - P2-05 device/RPC and host diagnostics availability

@Suite struct ISAEngineDiagnosticsAvailabilityTests {
  @Test func directMachineReceiptMarksDeviceRPCStagesUnavailable() {
    let receipt = ISAEngineProfileReceipt(
      configuration: ISAEngineProfileConfiguration(
        tier: "Tier1-direct-only", cpuProfile: "compatibleV1",
        schedulingMode: "serialized", firmwareVersion: "v1",
        kernelInitrdDiskHash: String(repeating: "a", count: 64)),
      workloadName: "w", workloadRevision: "r",
      completionCondition: .instructionBudget(instructionCount: 100),
      outcome: .completed,
      startSample: ISAEngineProfileSample(
        configuration: .init(
          tier: "Tier1-direct-only", cpuProfile: "compatibleV1",
          schedulingMode: "serialized", firmwareVersion: "v1",
          kernelInitrdDiskHash: String(repeating: "a", count: 64)),
        workloadName: "w", workloadRevision: "r",
        wallTimeNanoseconds: 0, retiredGuestInstructions: 0,
        compilationTimeNanoseconds: 0, compilationAttempts: 0, compilationDeclines: 0,
        translationCacheEntryCount: 0, translationCacheAllocatedBytes: 0,
        translationCacheMaximumBytes: 128 * 1024 * 1024,
        translationCacheHits: 0, translationCacheMisses: 0, translationCacheInvalidations: 0,
        tier1DeclineInterpreterHelper: 0, tier1DeclineNativeEmitter: 0,
        tier1CompiledBlocks: 0, tier1CompilationAttempts: 0, tier1CompilationDeclines: 0,
        nativeDispatcherEntries: 0, directlyChainedBlocks: 0,
        chainTargetAttempts: 0, chainTargetAccepts: 0,
        indirectBranchTargetCacheHits: 0, indirectBranchTargetCacheMisses: 0,
        shadowReturnStackHits: 0, shadowReturnStackMisses: 0,
        helperCalls: 0, memoryFaultSlowPaths: 0, lazyFlagMaterializations: 0,
        codeCacheWraps: 0, codeCacheEvictedBlocks: 0,
        negativeCacheHits: 0, negativeCacheMisses: 0, pendingWorkExits: 0),
      endSample: ISAEngineProfileSample(
        configuration: .init(
          tier: "Tier1-direct-only", cpuProfile: "compatibleV1",
          schedulingMode: "serialized", firmwareVersion: "v1",
          kernelInitrdDiskHash: String(repeating: "a", count: 64)),
        workloadName: "w", workloadRevision: "r",
        wallTimeNanoseconds: 1_000_000, retiredGuestInstructions: 100,
        compilationTimeNanoseconds: 0, compilationAttempts: 10, compilationDeclines: 1,
        translationCacheEntryCount: 5, translationCacheAllocatedBytes: 512,
        translationCacheMaximumBytes: 128 * 1024 * 1024,
        translationCacheHits: 40, translationCacheMisses: 10, translationCacheInvalidations: 0,
        tier1DeclineInterpreterHelper: 0, tier1DeclineNativeEmitter: 0,
        tier1CompiledBlocks: 9, tier1CompilationAttempts: 10, tier1CompilationDeclines: 1,
        nativeDispatcherEntries: 80, directlyChainedBlocks: 40,
        chainTargetAttempts: 50, chainTargetAccepts: 40,
        indirectBranchTargetCacheHits: 30, indirectBranchTargetCacheMisses: 5,
        shadowReturnStackHits: 20, shadowReturnStackMisses: 1,
        helperCalls: 0, memoryFaultSlowPaths: 2, lazyFlagMaterializations: 10,
        codeCacheWraps: 0, codeCacheEvictedBlocks: 0,
        negativeCacheHits: 8, negativeCacheMisses: 2, pendingWorkExits: 10),
      hostTiming: .init(startNanoseconds: 0, endNanoseconds: 1_000_000),
      stopReason: "instructionBudget(100)",
      observedTierEvidence: .verified(observedTier: .baselineJIT),
      deviceRPCStagesAvailable: false)

    #expect(receipt.deviceRPCStagesAvailable == false)
  }

  @Test func hostExecutionDiagnosticsSnapshotIsCodable() {
    let snapshot = ISAEngineHostExecutionDiagnosticsSnapshot(
      enabled: true, runCalls: 5,
      wall: .init(
        totalNanoseconds: 1_000_000, processorEventNanoseconds: 100_000,
        clockAdvancementNanoseconds: 200_000, interruptDeliveryNanoseconds: 50_000,
        processorExecutionNanoseconds: 600_000, idleWaitNanoseconds: 50_000),
      threadCPU: .init(
        totalNanoseconds: 800_000, processorEventNanoseconds: 80_000,
        clockAdvancementNanoseconds: 160_000, interruptDeliveryNanoseconds: 40_000,
        processorExecutionNanoseconds: 480_000, idleWaitNanoseconds: 40_000))

    let data = try! JSONEncoder().encode(snapshot)
    let decoded = try! JSONDecoder().decode(ISAEngineHostExecutionDiagnosticsSnapshot.self, from: data)
    #expect(decoded.enabled == true)
    #expect(decoded.runCalls == 5)
    #expect(decoded.wall.totalNanoseconds == 1_000_000)
    #expect(decoded.threadCPU.processorExecutionNanoseconds == 480_000)
  }
}

@Suite struct DoryPCDirectKernelMachineSnapshotTests {
  private let configuration = ISAEngineProfileConfiguration(
    tier: "Tier1-direct-only", cpuProfile: "compatibleV1",
    schedulingMode: "serialized", firmwareVersion: "edk2-pc-v1",
    kernelInitrdDiskHash: String(repeating: "a", count: 64))

  @Test func interpreterMachinePreRunSampleIsZero() throws {
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 64 * 1024 * 1024, executionTier: .interpreter)
    let sample = ISAEngineReceiptBuilder.sample(
      from: machine,
      configuration: configuration,
      workloadName: "pre-run",
      workloadRevision: "rev",
      wallTimeNanoseconds: 0,
      translationCacheMaximumBytes: 128 * 1024 * 1024)
    #expect(sample.retiredGuestInstructions == 0)
    #expect(sample.wallTimeNanoseconds == 0)
    #expect(sample.compilationAttempts == 0)
    #expect(sample.translationCacheMaximumBytes == 128 * 1024 * 1024)
    #expect(sample.translationCacheHits == 0)
    #expect(sample.translationCacheMisses == 0)
  }

  @Test func baselineJITMachinePreRunSampleIsZero() throws {
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 64 * 1024 * 1024, executionTier: .baselineJIT,
      instrumentationEnabled: true)
    let sample = ISAEngineReceiptBuilder.sample(
      from: machine,
      configuration: configuration,
      workloadName: "pre-run",
      workloadRevision: "rev",
      wallTimeNanoseconds: 0,
      translationCacheMaximumBytes: 128 * 1024 * 1024)
    #expect(sample.retiredGuestInstructions == 0)
    #expect(sample.compilationAttempts == 0)
    #expect(sample.translationCacheHits == 0)
    #expect(sample.translationCacheMisses == 0)
    #expect(sample.nativeDispatcherEntries == 0)
    #expect(sample.pendingWorkExits == 0)
  }

  @Test func runRejectsUnloadedMachine() throws {
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 64 * 1024 * 1024, executionTier: .interpreter)
    #expect(throws: DoryPCMachineError.notLoaded) {
      _ = try ISAEngineReceiptBuilder.run(
        machine: machine,
        configuration: configuration,
        workloadName: "unloaded",
        workloadRevision: "rev",
        completionCondition: .instructionBudget(instructionCount: 100),
        translationCacheMaximumBytes: 128 * 1024 * 1024)
    }
  }

  @Test func loadedMachineRunProducesCompletedLiveReceiptAndCostReport() throws {
    #if arch(arm64)
      let machine = try DoryPCDirectKernelMachine(
        memoryBytes: 2 * 1024 * 1024,
        executionTier: .baselineJIT,
        baselineJITMaximumCodeBytes: 16 * 1024,
        instrumentationEnabled: true)
      // NOP; JMP $: a deterministic, bounded direct-kernel workload that
      // retires through the real machine boundary until its declared budget.
      try machine.load(kernel: makeMinimalELF(code: [0x90, 0xEB, 0xFE]), commandLine: "x")

      let receipt = try ISAEngineReceiptBuilder.run(
        machine: machine,
        configuration: configuration,
        workloadName: "p2-05-live-budget",
        workloadRevision: "fixture-v1",
        completionCondition: .instructionBudget(instructionCount: 8),
        translationCacheMaximumBytes: 16 * 1024)

      #expect(receipt.outcome == .completed)
      #expect(receipt.isCompleted)
      #expect(receipt.endSample.retiredGuestInstructions == 8)
      #expect(machine.executionStatistics.baselineJITInstructions == 8)
      #expect(receipt.endSample.wallTimeNanoseconds == receipt.hostTiming.wallTimeNanoseconds)
      #expect(receipt.hostTiming.endNanoseconds >= receipt.hostTiming.startNanoseconds)
      #expect(ISAEngineCostReportGenerator.generate(from: receipt) != nil)
    #endif
  }

  @Test func repeatedCPUIDProducesPerRunConfirmedFallbackReceipts() throws {
    #if arch(arm64)
      let machine = try DoryPCDirectKernelMachine(
        memoryBytes: 2 * 1024 * 1024, executionTier: .baselineJIT,
        baselineJITMaximumCodeBytes: 16 * 1024)
      try machine.load(kernel: makeMinimalELF(code: [0x0F, 0xA2, 0xEB, 0xFC]), commandLine: "x")
      for budget: UInt64 in [130, 10] {
        let receipt = try ISAEngineReceiptBuilder.run(
          machine: machine, configuration: configuration, workloadName: "cpuid", workloadRevision: "r",
          completionCondition: .instructionBudget(instructionCount: budget),
          translationCacheMaximumBytes: 16 * 1024)
        let work = try #require(ISAEngineComparisonHarness.attributeTier1Declines(from: receipt))
        let confirmed = try #require(work.work.first { $0.site?.guestRIP == 0x10_0000 })
        #expect(confirmed.site?.declineReason == .interpreterHelper)
        #expect(confirmed.site?.executionMode == .protected32)
        #expect(confirmed.retiredInstructions == budget / 2)
        #expect(work.retiredInstructions(for: .nativeEmitter) == 0)
        #expect(receipt.runSample.tier1DeclineInterpreterHelper == budget / 2)
      }
      let diagnostics = try #require(machine.baselineJITDiagnostics)
      #expect(diagnostics.negativeCacheHotSites.first?.hitCount ?? 0 > 0)
      #expect(diagnostics.confirmedInterpreterFallback?.retiredInstructions(for: .interpreterHelper) == 70)
    #endif
  }

  @Test func nativePrefixThenCPUIDCountsOnlyConfirmedInterpreterRetirement() throws {
    #if arch(arm64)
      let machine = try DoryPCDirectKernelMachine(
        memoryBytes: 2 * 1024 * 1024, executionTier: .baselineJIT,
        baselineJITMaximumCodeBytes: 16 * 1024)
      // JMP to CPUID; CPUID; JMP back: each run retires two native branches and one
      // interpreter instruction. The first branch forces a separate native prefix.
      try machine.load(
        kernel: makeMinimalELF(code: [0xEB, 0x00, 0x0F, 0xA2, 0xEB, 0xFA]), commandLine: "x")
      var previousNegativeHits: UInt64 = 0
      for run: UInt64 in 1...2 {
        let receipt = try ISAEngineReceiptBuilder.run(
          machine: machine, configuration: configuration,
          workloadName: "native-prefix-cpuid", workloadRevision: "r",
          completionCondition: .instructionBudget(instructionCount: 3),
          translationCacheMaximumBytes: 16 * 1024)
        #expect(receipt.outcome == .completed)
        #expect(receipt.runSample.retiredGuestInstructions == 3)
        #expect(machine.state?.rip == 0x10_0000)
        #expect(machine.executionStatistics.baselineJITInstructions == 2 * run)
        #expect(machine.executionStatistics.interpreterInstructions == run)
        let work = try #require(ISAEngineComparisonHarness.attributeTier1Declines(from: receipt))
        #expect(work.work.count == 1)
        let confirmed = try #require(work.work.first)
        #expect(confirmed.site?.guestRIP == 0x10_0002)
        #expect(confirmed.site?.executionMode == .protected32)
        #expect(confirmed.site?.declineReason == .interpreterHelper)
        #expect(confirmed.retiredInstructions == 1)
        #expect(receipt.runSample.tier1DeclineInterpreterHelper == 1)
        #expect(receipt.runSample.tier1DeclineNativeEmitter == 0)
        let diagnostics = try #require(machine.baselineJITDiagnostics)
        #expect(diagnostics.negativeCacheHits > previousNegativeHits)
        #expect(diagnostics.confirmedInterpreterFallback?.retiredInstructions(for: .interpreterHelper) == run)
        previousNegativeHits = diagnostics.negativeCacheHits
      }
    #endif
  }

  @Test func interpreterRetirementWithoutTier1DeclineDoesNotCreateFallbackEvidence() throws {
    #if arch(arm64)
      // Protected-mode RDTSC fails a JIT admission guard before Tier1 compilation.
      // CPUID with Tier1 disabled reaches the legacy emitter but cannot report a Tier1 decline.
      let cases: [(code: [UInt8], tier1Enabled: Bool)] = [
        ([0x0F, 0x31], true),
        ([0x0F, 0xA2], false),
      ]
      for testCase in cases {
        let machine = try DoryPCDirectKernelMachine(
          memoryBytes: 2 * 1024 * 1024, executionTier: .baselineJIT,
          baselineJITMaximumCodeBytes: 16 * 1024,
          baselineJITTier1Enabled: testCase.tier1Enabled)
        try machine.load(kernel: makeMinimalELF(code: testCase.code), commandLine: "x")
        let receipt = try ISAEngineReceiptBuilder.run(
          machine: machine, configuration: configuration,
          workloadName: "generic-interpreter", workloadRevision: "r",
          completionCondition: .instructionBudget(instructionCount: 1),
          translationCacheMaximumBytes: 16 * 1024)
        #expect(receipt.outcome == .completed)
        #expect(machine.state?.rip == 0x10_0002)
        #expect(machine.executionStatistics.interpreterInstructions == 1)
        #expect(machine.executionStatistics.baselineJITInstructions == 0)
        let diagnostics = try #require(machine.baselineJITDiagnostics)
        #expect(diagnostics.declinedCompilations > 0)
        #expect(diagnostics.tier1CompilationAttempts == 0)
        #expect(diagnostics.tier1CompilationDeclines == 0)
        // Empty evidence, including no nil-site record, must survive profile and receipt mapping.
        #expect(try #require(diagnostics.confirmedInterpreterFallback).work.isEmpty)
        #expect(try #require(receipt.runSample.confirmedInterpreterFallback).work.isEmpty)
        #expect(receipt.runSample.tier1DeclineInterpreterHelper == 0)
        #expect(receipt.runSample.tier1DeclineNativeEmitter == 0)
      }
    #endif
  }

  @Test func legacyNativeRescueDoesNotCountAsInterpreterFallback() throws {
    #if arch(arm64)
      let machine = try DoryPCDirectKernelMachine(
        memoryBytes: 2 * 1024 * 1024, executionTier: .baselineJIT,
        baselineJITMaximumCodeBytes: 16 * 1024)
      // A standalone store is declined by Tier1 but handled by the legacy native emitter.
      try machine.load(kernel: makeMinimalELF(code: [0x89, 0x05, 0x00, 0x80, 0x00, 0x00]), commandLine: "x")
      let receipt = try ISAEngineReceiptBuilder.run(
        machine: machine, configuration: configuration, workloadName: "store", workloadRevision: "r",
        completionCondition: .instructionBudget(instructionCount: 1),
        translationCacheMaximumBytes: 16 * 1024)
      #expect(receipt.runSample.tier1CompilationDeclines == 1)
      #expect(machine.executionStatistics.baselineJITInstructions == 1)
      #expect(machine.executionStatistics.interpreterInstructions == 0)
      #expect(try #require(receipt.runSample.confirmedInterpreterFallback).work.isEmpty)
      let report = try #require(ISAEngineCostReportGenerator.generate(from: receipt))
      #expect(!report.optimizationOpportunities.contains { $0.targetCostCategory == "tier1Declines" })
    #endif
  }

  private func makeMinimalELF(code: [UInt8]) -> Data {
    let segmentOffset = 0x200
    var data = Data(repeating: 0, count: segmentOffset + code.count)
    data.replaceSubrange(0..<4, with: [0x7F, 0x45, 0x4C, 0x46])
    data[4] = 2
    data[5] = 1
    data[6] = 1
    writeLittleEndian(UInt16(2), to: &data, at: 16)
    writeLittleEndian(UInt16(0x3E), to: &data, at: 18)
    writeLittleEndian(UInt32(1), to: &data, at: 20)
    writeLittleEndian(UInt64(0x10_0000), to: &data, at: 24)
    writeLittleEndian(UInt64(0x40), to: &data, at: 32)
    writeLittleEndian(UInt16(64), to: &data, at: 52)
    writeLittleEndian(UInt16(56), to: &data, at: 54)
    writeLittleEndian(UInt16(2), to: &data, at: 56)
    writeELFProgramHeader(
      to: &data, at: 0x40, type: 1, fileOffset: UInt64(segmentOffset),
      physicalAddress: 0x10_0000, size: UInt64(code.count))
    writeELFProgramHeader(
      to: &data, at: 0x78, type: 4, fileOffset: 0x180,
      physicalAddress: 0, size: 20)
    writeLittleEndian(UInt32(4), to: &data, at: 0x180)
    writeLittleEndian(UInt32(4), to: &data, at: 0x184)
    writeLittleEndian(UInt32(0x12), to: &data, at: 0x188)
    data.replaceSubrange(0x18C..<0x190, with: [0x58, 0x65, 0x6E, 0])
    writeLittleEndian(UInt32(0x10_0000), to: &data, at: 0x190)
    data.replaceSubrange(segmentOffset..<(segmentOffset + code.count), with: code)
    return data
  }

  private func writeELFProgramHeader(
    to data: inout Data,
    at offset: Int,
    type: UInt32,
    fileOffset: UInt64,
    physicalAddress: UInt64,
    size: UInt64
  ) {
    writeLittleEndian(type, to: &data, at: offset)
    writeLittleEndian(fileOffset, to: &data, at: offset + 8)
    writeLittleEndian(physicalAddress, to: &data, at: offset + 24)
    writeLittleEndian(size, to: &data, at: offset + 32)
    writeLittleEndian(size, to: &data, at: offset + 40)
  }

  private func writeLittleEndian<T: FixedWidthInteger>(
    _ value: T, to data: inout Data, at offset: Int
  ) {
    for index in 0..<MemoryLayout<T>.size {
      data[offset + index] = UInt8(truncatingIfNeeded: value >> T(index * 8))
    }
  }
}

@Suite struct ISAConfirmedFallbackSourceTests {
  @Test func nativePrefixPreservesFreshAndNegativeCacheDeclineCallbacks() throws {
    #if arch(arm64)
      let executor = try DoryARM64BaselineExecutor(
        maximumCodeBytes: 4096, tier1Enabled: true, tracksInterpreterFallback: true)
      let code: [UInt8] = [0xEB, 0x00, 0x0F, 0xA2]  // JMP to CPUID; CPUID
      for attempt in 0..<2 {
        var state = try DoryX86ArchitecturalState(rip: 0x1000)
        var declines: [DoryARM64InterpreterFallbackSite] = []
        let before = executor.diagnostics
        let execution = try #require(executor.executeChainedSummary(
          byteProvider: { address, count in
            Array(code.dropFirst(Int(address - 0x1000)).prefix(count))
          }, codeGenerationProvider: { _, _ in 1 },
          at: 0x1000, mode: .long64, addressSpaceID: 0, maximumInstructions: 2,
          state: &state, onCompilationDecline: { declines.append($0) }))
        #expect(execution.exitCode == .dispatch)
        #expect(execution.guestInstructionCount == 1)
        #expect(execution.residentBlockCount == 1)
        #expect(state.rip == 0x1002)
        #expect(declines.count == 1)
        let site = try #require(declines.first)
        #expect(site.guestRIP == 0x1002)
        #expect(site.declineReason == .interpreterHelper)
        let after = executor.diagnostics
        if attempt == 0 {
          #expect(after.tier1CompilationDeclines == before.tier1CompilationDeclines + 1)
        } else {
          #expect(after.negativeCacheHits == before.negativeCacheHits + 1)
          #expect(after.tier1CompilationAttempts == before.tier1CompilationAttempts)
        }
        // A decline and the already-retired native branch are not interpreter work.
        #expect(try #require(after.confirmedInterpreterFallback).work.isEmpty)
      }
    #endif
  }

  @Test func declineWithoutRetirementIsNotWorkAndCacheResetPreservesConfirmation() throws {
    #if arch(arm64)
      let executor = try DoryARM64BaselineExecutor(
        maximumCodeBytes: 4096, tier1Enabled: true, tracksInterpreterFallback: true)
      var state = try DoryX86ArchitecturalState(rip: 0x1000)
      var site: DoryARM64InterpreterFallbackSite?
      let execution = try executor.executeChainedSummary(
        byteProvider: { _, _ in [0x0F, 0xA2] }, codeGenerationProvider: { _, _ in 1 },
        at: 0x1000, mode: .long64, addressSpaceID: 0, maximumInstructions: 1,
        state: &state, onCompilationDecline: { site = $0 })
      #expect(execution == nil)
      #expect(executor.diagnostics.negativeCacheMisses > 0)
      #expect(try #require(executor.diagnostics.confirmedInterpreterFallback).work.isEmpty)
      let declined = try #require(site)
      #expect(declined.guestRIP == 0x1000)
      #expect(declined.declineReason == .interpreterHelper)
      executor.recordInterpreterFallback(site: declined, retiredInstructions: 1)
      executor.invalidateAll()
      #expect(executor.diagnostics.negativeCacheHotSites.isEmpty)
      #expect(executor.diagnostics.confirmedInterpreterFallback?.retiredInstructions(for: .interpreterHelper) == 1)
    #endif
  }
}
