import DoryDBTX86
import Foundation

// P2-05 acceptance: A ranked cost report that explains where time goes
// and identifies the next three optimizations.
//
// The report distinguishes measured timing components (wall time,
// compilation time) from counter pressure signals (cache misses, helper
// calls, chain rejections, etc.).  Only measured timing components carry
// nanosecond estimates; counter categories expose their raw counts and
// rates as evidence/ranking signals without fabricated nanosecond
// attribution.  No architecture change is justified solely by a
// microbenchmark or an old plan sentence.

/// P2-05 acceptance: A single cost category in the ranked cost report.
public struct ISAEngineCostCategory: Codable, Sendable, Hashable {
  public let name: String
  public let description: String
  /// Measured nanosecond estimate.  Only non-zero for categories with
  /// directly measured timing (wall time, compilation time).  Counter
  /// pressure categories have this set to 0; their ranking comes from
  /// ``counterPressure``.
  public let estimatedNanoseconds: UInt64
  public let fractionOfWallTime: Double
  public let evidence: String
  /// `true` when ``estimatedNanoseconds`` is from a measured timing
  /// component.  `false` for counter-pressure categories that do not
  /// have a measured nanosecond cost.
  public let measured: Bool
  /// Ranking signal for counter-pressure categories: the raw counter
  /// magnitude or rate that indicates pressure.  Measured categories
  /// use 0; the value is never displayed as nanoseconds.
  public let counterPressure: Double

  public init(
    name: String, description: String,
    estimatedNanoseconds: UInt64, fractionOfWallTime: Double,
    evidence: String,
    measured: Bool = false,
    counterPressure: Double = 0
  ) {
    self.name = name
    self.description = description
    self.estimatedNanoseconds = estimatedNanoseconds
    self.fractionOfWallTime = fractionOfWallTime
    self.evidence = evidence
    self.measured = measured
    self.counterPressure = counterPressure
  }
}

/// P2-05 acceptance: An optimization opportunity identified from the cost report.
public struct ISAEngineOptimizationOpportunity: Codable, Sendable, Hashable {
  public let rank: Int
  public let title: String
  public let rationale: String
  public let targetCostCategory: String
  public let expectedBenefit: String
  public let measurementPlan: String

  public init(
    rank: Int, title: String, rationale: String,
    targetCostCategory: String, expectedBenefit: String,
    measurementPlan: String
  ) {
    self.rank = rank
    self.title = title
    self.rationale = rationale
    self.targetCostCategory = targetCostCategory
    self.expectedBenefit = expectedBenefit
    self.measurementPlan = measurementPlan
  }
}

/// P2-05 acceptance: The ranked cost report.
public struct ISAEngineCostReport: Codable, Sendable, Hashable {
  public let configuration: ISAEngineProfileConfiguration
  public let workloadName: String
  public let workloadRevision: String
  public let wallTimeNanoseconds: UInt64
  public let retiredGuestInstructions: UInt64
  public let instructionsPerNanosecond: Double
  public let costCategories: [ISAEngineCostCategory]
  public let optimizationOpportunities: [ISAEngineOptimizationOpportunity]
  public let summary: String

  public init(
    configuration: ISAEngineProfileConfiguration,
    workloadName: String,
    workloadRevision: String,
    wallTimeNanoseconds: UInt64,
    retiredGuestInstructions: UInt64,
    instructionsPerNanosecond: Double,
    costCategories: [ISAEngineCostCategory],
    optimizationOpportunities: [ISAEngineOptimizationOpportunity],
    summary: String
  ) {
    self.configuration = configuration
    self.workloadName = workloadName
    self.workloadRevision = workloadRevision
    self.wallTimeNanoseconds = wallTimeNanoseconds
    self.retiredGuestInstructions = retiredGuestInstructions
    self.instructionsPerNanosecond = instructionsPerNanosecond
    self.costCategories = costCategories
    self.optimizationOpportunities = optimizationOpportunities
    self.summary = summary
  }
}

/// P2-05 acceptance: Generates a ranked cost report from a profile sample.
public enum ISAEngineCostReportGenerator {
  /// Generate a comparable ranked cost report from a live receipt.
  ///
  /// Returns `nil` unless the receipt is completed **and** its observed
  /// execution tier matches the declared profile tier
  /// (``ISAEngineProfileReceipt/isProvenanceVerified``).  A partial,
  /// timeout, stopped, or failed receipt must not masquerade as
  /// completed evidence.  A mismatched-tier receipt is unverified and
  /// also produces no comparable cost report.
  ///
  /// When the receipt is completed and provenance-verified, the report
  /// is built from the receipt's per-run delta sample
  /// (``ISAEngineProfileReceipt/runSample``), not from the raw
  /// end-of-run cumulative snapshot.
  public static func generate(from receipt: ISAEngineProfileReceipt) -> ISAEngineCostReport? {
    guard receipt.isCompleted, receipt.isProvenanceVerified else { return nil }
    return generate(from: receipt.runSample)
  }

  public static func generate(from sample: ISAEngineProfileSample) -> ISAEngineCostReport {
    let wall = sample.wallTimeNanoseconds
    let categories = rankCostCategories(from: sample, wallTime: wall)
    let opportunities = identifyOptimizationOpportunities(from: sample, categories: categories)
    let summary = generateSummary(from: sample, categories: categories, opportunities: opportunities)

    return ISAEngineCostReport(
      configuration: sample.configuration,
      workloadName: sample.workloadName,
      workloadRevision: sample.workloadRevision,
      wallTimeNanoseconds: wall,
      retiredGuestInstructions: sample.retiredGuestInstructions,
      instructionsPerNanosecond: sample.instructionsPerNanosecond,
      costCategories: categories,
      optimizationOpportunities: opportunities,
      summary: summary)
  }

  private static func rankCostCategories(
    from sample: ISAEngineProfileSample, wallTime: UInt64
  ) -> [ISAEngineCostCategory] {
    var categories: [ISAEngineCostCategory] = []

    // 1. Guest execution (measured: wall time minus compilation time)
    let guestExecution = wallTime > sample.compilationTimeNanoseconds
      ? wallTime - sample.compilationTimeNanoseconds : 0
    categories.append(.init(
      name: "guestExecution",
      description: "Native guest instruction execution (wall time minus compilation time)",
      estimatedNanoseconds: guestExecution,
      fractionOfWallTime: fraction(guestExecution, wallTime),
      evidence: "wall=\(wallTime)ns - compilation=\(sample.compilationTimeNanoseconds)ns",
      measured: true))

    // 2. Compilation time (measured)
    categories.append(.init(
      name: "compilation",
      description: "Time spent translating and compiling guest blocks",
      estimatedNanoseconds: sample.compilationTimeNanoseconds,
      fractionOfWallTime: fraction(sample.compilationTimeNanoseconds, wallTime),
      evidence: "compilationTime=\(sample.compilationTimeNanoseconds)ns, attempts=\(sample.compilationAttempts), declines=\(sample.compilationDeclines)",
      measured: true))

    // 3. Translation cache misses (counter pressure — no fabricated ns)
    categories.append(.init(
      name: "translationCacheMisses",
      description: "Translation cache misses triggering recompilation (counter pressure, not measured time)",
      estimatedNanoseconds: 0,
      fractionOfWallTime: 0,
      evidence: "misses=\(sample.translationCacheMisses), hits=\(sample.translationCacheHits), hitRate=\(String(format: "%.1f%%", sample.translationCacheHitRate * 100))",
      measured: false,
      counterPressure: Double(sample.translationCacheMisses)))

    // 4. Code cache churn (counter pressure — no fabricated ns)
    categories.append(.init(
      name: "codeCacheChurn",
      description: "Code cache eviction and wrap-around forcing recompilation (counter pressure, not measured time)",
      estimatedNanoseconds: 0,
      fractionOfWallTime: 0,
      evidence: "wraps=\(sample.codeCacheWraps), evictedBlocks=\(sample.codeCacheEvictedBlocks), occupancy=\(String(format: "%.1f%%", sample.translationCacheOccupancy * 100))",
      measured: false,
      counterPressure: Double(sample.codeCacheWraps + sample.codeCacheEvictedBlocks)))

    // 5. Helper calls (counter pressure — lazy flags are NOT counted
    //    as helper calls to avoid double counting)
    categories.append(.init(
      name: "helperCalls",
      description: "Helper calls exiting native execution (counter pressure, not measured time). Lazy flag materializations are tracked separately.",
      estimatedNanoseconds: 0,
      fractionOfWallTime: 0,
      evidence: "helperCalls=\(sample.helperCalls), lazyFlagMaterializations=\(sample.lazyFlagMaterializations) (tracked separately, not double-counted)",
      measured: false,
      counterPressure: Double(sample.helperCalls)))

    // 6. Memory fault slow paths (counter pressure — no fabricated ns)
    categories.append(.init(
      name: "memoryFaultSlowPaths",
      description: "Memory fault slow-path handling (counter pressure, not measured time)",
      estimatedNanoseconds: 0,
      fractionOfWallTime: 0,
      evidence: "faults=\(sample.memoryFaultSlowPaths)",
      measured: false,
      counterPressure: Double(sample.memoryFaultSlowPaths)))

    // 7. Chain target rejections (counter pressure — no fabricated ns)
    let chainRejections = sample.chainTargetAttempts > sample.chainTargetAccepts
      ? sample.chainTargetAttempts - sample.chainTargetAccepts : 0
    categories.append(.init(
      name: "chainTargetRejections",
      description: "Chain target rejections preventing direct block linking (counter pressure, not measured time)",
      estimatedNanoseconds: 0,
      fractionOfWallTime: 0,
      evidence: "attempts=\(sample.chainTargetAttempts), accepts=\(sample.chainTargetAccepts), rejections=\(chainRejections), acceptRate=\(String(format: "%.1f%%", sample.chainTargetAcceptRate * 100))",
      measured: false,
      counterPressure: Double(chainRejections)))

    // 8. Pending work exits (counter pressure — no fabricated ns)
    categories.append(.init(
      name: "pendingWorkExits",
      description: "Exits from native execution to check pending work (counter pressure, not measured time)",
      estimatedNanoseconds: 0,
      fractionOfWallTime: 0,
      evidence: "exits=\(sample.pendingWorkExits)",
      measured: false,
      counterPressure: Double(sample.pendingWorkExits)))

    // 9. Confirmed interpreter retirement after Tier1 decline. Unknown work stays explicit;
    // compilation attempts and live negative-cache hits cannot establish this ranking signal.
    let fallback = sample.confirmedInterpreterFallback
    let helperWork = fallback?.retiredInstructions(for: .interpreterHelper)
    let emitterWork = fallback?.retiredInstructions(for: .nativeEmitter)
    let pressure = helperWork.map { Double($0) + Double(emitterWork ?? 0) }
    let fallbackEvidence: String
    if let fallback, let helperWork, let emitterWork {
      fallbackEvidence = "interpreterHelperRetiredInstructions=\(helperWork), nativeEmitterRetiredInstructions=\(emitterWork), unattributedRetiredInstructions=\(fallback.retiredInstructions(for: nil))"
    } else {
      fallbackEvidence = "confirmed interpreter fallback attribution unavailable/unverified"
    }
    categories.append(.init(
      name: "tier1Declines",
      description: "Confirmed interpreter work after Tier1 decline (instruction counts, not measured time)",
      estimatedNanoseconds: 0,
      fractionOfWallTime: 0,
      evidence: fallbackEvidence,
      measured: false,
      // The legacy numeric ranking field has no optional representation. Unavailable categories
      // receive no ranking weight; the evidence above must not present that weight as zero work.
      counterPressure: pressure ?? 0))

    // Sort: measured categories first (by ns desc), then counter-pressure
    // categories (by pressure desc).
    return categories.sorted { a, b in
      if a.measured != b.measured { return a.measured && !b.measured }
      if a.measured { return a.estimatedNanoseconds > b.estimatedNanoseconds }
      return a.counterPressure > b.counterPressure
    }
  }

  private static func identifyOptimizationOpportunities(
    from sample: ISAEngineProfileSample,
    categories: [ISAEngineCostCategory]
  ) -> [ISAEngineOptimizationOpportunity] {
    var opportunities: [ISAEngineOptimizationOpportunity] = []

    // Opportunity 1: Reduce translation cache misses
    if sample.translationCacheMisses > 0 && sample.translationCacheHitRate < 0.9 {
      opportunities.append(.init(
        rank: 1,
        title: "Increase translation cache capacity or improve eviction policy",
        rationale: "Translation cache hit rate is \(String(format: "%.1f%%", sample.translationCacheHitRate * 100)) with \(sample.translationCacheMisses) misses. Each miss triggers recompilation. Cache occupancy is \(String(format: "%.1f%%", sample.translationCacheOccupancy * 100)).",
        targetCostCategory: "translationCacheMisses",
        expectedBenefit: "Reduce compilation time by improving cache hit rate",
        measurementPlan: "Increase cache size by 2x, measure hit rate and compilation time on the same workload"))
    }

    // Opportunity 2: Reduce code cache churn
    if sample.codeCacheWraps > 0 || sample.codeCacheEvictedBlocks > 0 {
      opportunities.append(.init(
        rank: opportunities.count + 1,
        title: "Reduce code cache churn by increasing cache size or improving eviction",
        rationale: "Code cache has \(sample.codeCacheWraps) wraps and \(sample.codeCacheEvictedBlocks) evicted blocks. Evicted blocks must be recompiled, wasting compilation time.",
        targetCostCategory: "codeCacheChurn",
        expectedBenefit: "Reduce recompilation overhead from cache eviction",
        measurementPlan: "Increase code cache size, measure wraps and evictions on the same workload"))
    }

    // Opportunity 3: Reduce confirmed interpreter work caused by Tier1 declines.
    if let fallback = sample.confirmedInterpreterFallback,
      fallback.work.contains(where: { $0.site != nil && $0.retiredInstructions > 0 })
    {
      opportunities.append(.init(
        rank: opportunities.count + 1,
        title: "Expand Tier1 coverage for confirmed interpreter fallback sites",
        rationale: "Confirmed retired instructions: interpreterHelper=\(fallback.retiredInstructions(for: .interpreterHelper)), nativeEmitter=\(fallback.retiredInstructions(for: .nativeEmitter)); unattributed=\(fallback.retiredInstructions(for: nil)).",
        targetCostCategory: "tier1Declines",
        expectedBenefit: "Reduce interpreter fallback overhead",
        measurementPlan: "Rank confirmed per-run retired instructions by decline site/reason, add support for the dominant forms, and remeasure the same workload"))
    }

    // Opportunity 4: Improve chain target acceptance
    if sample.chainTargetAttempts > 0 && sample.chainTargetAcceptRate < 0.8 {
      opportunities.append(.init(
        rank: opportunities.count + 1,
        title: "Improve chain target acceptance rate",
        rationale: "Chain target acceptance rate is \(String(format: "%.1f%%", sample.chainTargetAcceptRate * 100)). Rejected chain targets force dispatcher re-entry.",
        targetCostCategory: "chainTargetRejections",
        expectedBenefit: "Reduce dispatcher overhead by improving direct chaining",
        measurementPlan: "Identify dominant rejection reasons, relax constraints where safe, measure accept rate"))
    }

    // Opportunity 5: Reduce helper calls (helper calls only, not lazy flags)
    if sample.helperCalls > 0 && sample.retiredGuestInstructions > 0 {
      let helperRate = Double(sample.helperCalls) / Double(sample.retiredGuestInstructions)
      if helperRate > 0.01 {
        opportunities.append(.init(
          rank: opportunities.count + 1,
          title: "Reduce helper call frequency",
          rationale: "Helper call rate is \(String(format: "%.2f%%", helperRate * 100)) of retired instructions. Each helper call exits native execution.",
          targetCostCategory: "helperCalls",
          expectedBenefit: "Reduce native-to-helper transition overhead",
          measurementPlan: "Identify top helper call sites, inline where safe, measure call rate"))
      }
    }

    // Return top 3 (P2-05 acceptance: identify the next three optimizations).
    // When fewer than 3 are justified, preserve the useful ones and note
    // the insufficiency in the summary.
    return Array(opportunities.prefix(3))
  }

  private static func generateSummary(
    from sample: ISAEngineProfileSample,
    categories: [ISAEngineCostCategory],
    opportunities: [ISAEngineOptimizationOpportunity]
  ) -> String {
    let topCategory = categories.first?.name ?? "unknown"
    let topFraction = categories.first.map { String(format: "%.1f%%", $0.fractionOfWallTime * 100) } ?? "0%"
    let insufficiency = opportunities.count < 3
      ? " Only \(opportunities.count) optimization(s) identified; insufficient evidence for \(3 - opportunities.count) more."
      : ""
    return """
    Workload '\(sample.workloadName)' (rev \(sample.workloadRevision)) under \(sample.configuration.tier) \
    retired \(sample.retiredGuestInstructions) instructions in \(sample.wallTimeNanoseconds / 1_000_000)ms \
    (\(String(format: "%.3f", sample.instructionsPerNanosecond * 1000)) ins/ns). \
    Top cost: \(topCategory) at \(topFraction) of wall time. \
    Next \(opportunities.count) optimization(s) identified.\(insufficiency)
    """
  }

  private static func fraction(_ part: UInt64, _ whole: UInt64) -> Double {
    whole == 0 ? 0 : Double(part) / Double(whole)
  }
}
