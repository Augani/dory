import DoryDBTX86
import Foundation

// P2-05 acceptance: A ranked cost report that explains where time goes
// and identifies the next three optimizations.
//
// The report ranks cost categories by their contribution to total wall time
// and identifies the top three optimization opportunities based on the
// measured data. No architecture change is justified solely by a
// microbenchmark or an old plan sentence.

/// P2-05 acceptance: A single cost category in the ranked cost report.
public struct ISAEngineCostCategory: Codable, Sendable, Hashable {
  public let name: String
  public let description: String
  public let estimatedNanoseconds: UInt64
  public let fractionOfWallTime: Double
  public let evidence: String

  public init(
    name: String, description: String,
    estimatedNanoseconds: UInt64, fractionOfWallTime: Double,
    evidence: String
  ) {
    self.name = name
    self.description = description
    self.estimatedNanoseconds = estimatedNanoseconds
    self.fractionOfWallTime = fractionOfWallTime
    self.evidence = evidence
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
  /// Returns `nil` unless the receipt's outcome is `.completed`.  A
  /// partial, timeout, stopped, or failed receipt must not masquerade as
  /// completed evidence, so it produces no comparable cost report.  When
  /// the receipt is completed, the report is built from the receipt's live
  /// end sample (collected at the terminal machine boundary), not from
  /// hand-assembled test data.
  public static func generate(from receipt: ISAEngineProfileReceipt) -> ISAEngineCostReport? {
    guard receipt.isCompleted else { return nil }
    return generate(from: receipt.endSample)
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

    // 1. Guest execution (estimated as wall time minus compilation time)
    let guestExecution = wallTime > sample.compilationTimeNanoseconds
      ? wallTime - sample.compilationTimeNanoseconds : 0
    categories.append(.init(
      name: "guestExecution",
      description: "Native guest instruction execution (wall time minus compilation time)",
      estimatedNanoseconds: guestExecution,
      fractionOfWallTime: fraction(guestExecution, wallTime),
      evidence: "wall=\(wallTime)ns - compilation=\(sample.compilationTimeNanoseconds)ns"))

    // 2. Compilation time
    categories.append(.init(
      name: "compilation",
      description: "Time spent translating and compiling guest blocks",
      estimatedNanoseconds: sample.compilationTimeNanoseconds,
      fractionOfWallTime: fraction(sample.compilationTimeNanoseconds, wallTime),
      evidence: "compilationTime=\(sample.compilationTimeNanoseconds)ns, attempts=\(sample.compilationAttempts), declines=\(sample.compilationDeclines)"))

    // 3. Translation cache misses (each miss triggers compilation)
    let cacheMissCost = sample.translationCacheMisses * 1000  // ~1μs per miss estimate
    categories.append(.init(
      name: "translationCacheMisses",
      description: "Translation cache misses triggering recompilation",
      estimatedNanoseconds: cacheMissCost,
      fractionOfWallTime: fraction(cacheMissCost, wallTime),
      evidence: "misses=\(sample.translationCacheMisses), hits=\(sample.translationCacheHits), hitRate=\(String(format: "%.1f%%", sample.translationCacheHitRate * 100))"))

    // 4. Code cache churn (evictions and wraps force recompilation)
    let churnCost = (sample.codeCacheWraps + sample.codeCacheEvictedBlocks) * 2000
    categories.append(.init(
      name: "codeCacheChurn",
      description: "Code cache eviction and wrap-around forcing recompilation",
      estimatedNanoseconds: churnCost,
      fractionOfWallTime: fraction(churnCost, wallTime),
      evidence: "wraps=\(sample.codeCacheWraps), evictedBlocks=\(sample.codeCacheEvictedBlocks), occupancy=\(String(format: "%.1f%%", sample.translationCacheOccupancy * 100))"))

    // 5. Helper calls and lazy flag materialization
    let helperCost = (sample.helperCalls + sample.lazyFlagMaterializations) * 500
    categories.append(.init(
      name: "helperCalls",
      description: "Helper calls and lazy flag materializations",
      estimatedNanoseconds: helperCost,
      fractionOfWallTime: fraction(helperCost, wallTime),
      evidence: "helperCalls=\(sample.helperCalls), lazyFlags=\(sample.lazyFlagMaterializations)"))

    // 6. Memory fault slow paths
    let faultCost = sample.memoryFaultSlowPaths * 5000
    categories.append(.init(
      name: "memoryFaultSlowPaths",
      description: "Memory fault slow-path handling",
      estimatedNanoseconds: faultCost,
      fractionOfWallTime: fraction(faultCost, wallTime),
      evidence: "faults=\(sample.memoryFaultSlowPaths)"))

    // 7. Chain target rejections (missed chaining opportunities)
    let chainRejections = sample.chainTargetAttempts > sample.chainTargetAccepts
      ? sample.chainTargetAttempts - sample.chainTargetAccepts : 0
    let chainCost = chainRejections * 200
    categories.append(.init(
      name: "chainTargetRejections",
      description: "Chain target rejections preventing direct block linking",
      estimatedNanoseconds: chainCost,
      fractionOfWallTime: fraction(chainCost, wallTime),
      evidence: "attempts=\(sample.chainTargetAttempts), accepts=\(sample.chainTargetAccepts), rejections=\(chainRejections), acceptRate=\(String(format: "%.1f%%", sample.chainTargetAcceptRate * 100))"))

    // 8. Pending work exits
    let pendingWorkCost = sample.pendingWorkExits * 1000
    categories.append(.init(
      name: "pendingWorkExits",
      description: "Exits from native execution to check pending work",
      estimatedNanoseconds: pendingWorkCost,
      fractionOfWallTime: fraction(pendingWorkCost, wallTime),
      evidence: "exits=\(sample.pendingWorkExits)"))

    // 9. Tier1 declines (forms that fell back to interpreter)
    let tier1DeclineCost = sample.tier1CompilationDeclines * 1500
    categories.append(.init(
      name: "tier1Declines",
      description: "Tier1 compilation declines falling back to interpreter",
      estimatedNanoseconds: tier1DeclineCost,
      fractionOfWallTime: fraction(tier1DeclineCost, wallTime),
      evidence: "attempts=\(sample.tier1CompilationAttempts), declines=\(sample.tier1CompilationDeclines), declineRate=\(String(format: "%.1f%%", sample.tier1DeclineRate * 100))"))

    // Sort by estimated nanoseconds descending
    return categories.sorted { $0.estimatedNanoseconds > $1.estimatedNanoseconds }
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

    // Opportunity 3: Reduce Tier1 declines
    if sample.tier1CompilationDeclines > 0 && sample.tier1DeclineRate > 0.05 {
      opportunities.append(.init(
        rank: opportunities.count + 1,
        title: "Expand Tier1 coverage for dominant decline reasons",
        rationale: "Tier1 decline rate is \(String(format: "%.1f%%", sample.tier1DeclineRate * 100)) with \(sample.tier1CompilationDeclines) declines out of \(sample.tier1CompilationAttempts) attempts. Declined forms fall back to the interpreter.",
        targetCostCategory: "tier1Declines",
        expectedBenefit: "Reduce interpreter fallback overhead",
        measurementPlan: "Identify top decline reasons from negative cache hot sites, add Tier1 support for those forms, measure decline rate"))
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

    // Opportunity 5: Reduce helper calls
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

    // Return top 3 (P2-05 acceptance: identify the next three optimizations)
    return Array(opportunities.prefix(3))
  }

  private static func generateSummary(
    from sample: ISAEngineProfileSample,
    categories: [ISAEngineCostCategory],
    opportunities: [ISAEngineOptimizationOpportunity]
  ) -> String {
    let topCategory = categories.first?.name ?? "unknown"
    let topFraction = categories.first.map { String(format: "%.1f%%", $0.fractionOfWallTime * 100) } ?? "0%"
    return """
    Workload '\(sample.workloadName)' (rev \(sample.workloadRevision)) under \(sample.configuration.tier) \
    retired \(sample.retiredGuestInstructions) instructions in \(sample.wallTimeNanoseconds / 1_000_000)ms \
    (\(String(format: "%.3f", sample.instructionsPerNanosecond * 1000)) ins/ns). \
    Top cost: \(topCategory) at \(topFraction) of wall time. \
    Next \(opportunities.count) optimization(s) identified.
    """
  }

  private static func fraction(_ part: UInt64, _ whole: UInt64) -> Double {
    whole == 0 ? 0 : Double(part) / Double(whole)
  }
}
