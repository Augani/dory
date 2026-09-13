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

  @Test func tier1DeclineAttributionMapsHotSites() {
    let diagnostics = DoryARM64BaselineExecutorDiagnostics(
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

    let attributions = ISAEngineComparisonHarness.attributeTier1Declines(from: diagnostics)
    #expect(attributions.count == 2)
    #expect(attributions[0].guestRIP == 0x1000)
    #expect(attributions[0].declineReason == "interpreterHelper")
    #expect(attributions[0].estimatedRuntimeExitCount == 500)
    #expect(attributions[1].guestRIP == 0x2000)
    #expect(attributions[1].declineReason == "nativeEmitter")
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

  private func makeReceipt(outcome: ISAEngineReceiptOutcome) -> ISAEngineProfileReceipt {
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
      result: result)
  }

  @Test func completedReceiptProducesCostReport() {
    let receipt = makeReceipt(outcome: .completed)
    let report = ISAEngineCostReportGenerator.generate(from: receipt)
    #expect(report != nil)
    #expect(report?.retiredGuestInstructions == 1_000_000)
    #expect(report?.wallTimeNanoseconds == 1_000_000_000)
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
