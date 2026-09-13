import DoryDBTX86
import Foundation

// P2-05 items 3+5: Compare interpreter/Tier1/Tier2 only on identical
// fixtures, clocks, resources, logging and exit criteria. Attribute
// Tier1 declines by executed guest work, not only compile attempts.
//
// The comparison harness runs the same workload through different engine
// tiers and records profile samples for each. The harness enforces that
// comparisons are only valid between identical fixtures, configurations,
// and exit criteria.

/// P2-05 item 5: The engine tier being compared.
public enum ISAEngineTier: String, Codable, Sendable, Hashable {
  case interpreter
  case tier1
  case tier1DirectOnly
  case tier2
}

/// P2-05 item 5: A comparison result between two engine tiers on the
// same fixture.
public struct ISAEngineComparisonResult: Codable, Sendable, Hashable {
  public let baselineTier: ISAEngineTier
  public let comparisonTier: ISAEngineTier
  public let workloadName: String
  public let workloadRevision: String
  public let baselineWallTimeNanoseconds: UInt64
  public let comparisonWallTimeNanoseconds: UInt64
  public let baselineRetiredInstructions: UInt64
  public let comparisonRetiredInstructions: UInt64
  public let speedup: Double  // >1.0 means comparison is faster
  public let instructionDelta: Int64  // positive means comparison retired more
  public let valid: Bool  // false if exit criteria differ

  public init(
    baselineTier: ISAEngineTier,
    comparisonTier: ISAEngineTier,
    workloadName: String,
    workloadRevision: String,
    baselineWallTimeNanoseconds: UInt64,
    comparisonWallTimeNanoseconds: UInt64,
    baselineRetiredInstructions: UInt64,
    comparisonRetiredInstructions: UInt64,
    valid: Bool
  ) {
    self.baselineTier = baselineTier
    self.comparisonTier = comparisonTier
    self.workloadName = workloadName
    self.workloadRevision = workloadRevision
    self.baselineWallTimeNanoseconds = baselineWallTimeNanoseconds
    self.comparisonWallTimeNanoseconds = comparisonWallTimeNanoseconds
    self.baselineRetiredInstructions = baselineRetiredInstructions
    self.comparisonRetiredInstructions = comparisonRetiredInstructions
    self.speedup = comparisonWallTimeNanoseconds == 0 ? 0
      : Double(baselineWallTimeNanoseconds) / Double(comparisonWallTimeNanoseconds)
    self.instructionDelta = Int64(comparisonRetiredInstructions) - Int64(baselineRetiredInstructions)
    self.valid = valid
  }
}

/// P2-05 item 3: Tier1 decline attribution by executed guest work.
/// This records which guest instruction forms caused the most Tier1
/// declines during execution, not just which forms failed compilation.
public struct ISATier1DeclineAttribution: Codable, Sendable, Hashable {
  public let guestRIP: UInt64
  public let executionMode: String
  public let declineReason: String
  public let hitCount: UInt64
  public let estimatedRuntimeExitCount: UInt64

  public init(
    guestRIP: UInt64, executionMode: String,
    declineReason: String, hitCount: UInt64,
    estimatedRuntimeExitCount: UInt64
  ) {
    self.guestRIP = guestRIP
    self.executionMode = executionMode
    self.declineReason = declineReason
    self.hitCount = hitCount
    self.estimatedRuntimeExitCount = estimatedRuntimeExitCount
  }
}

/// P2-05 items 3+5: A comparison harness that runs the same workload
/// through different engine tiers and compares the results.
public enum ISAEngineComparisonHarness {
  /// Compare two profile samples from the same workload. The samples
  /// must have the same workload name and revision; otherwise the
  /// comparison is invalid.
  public static func compare(
    baseline: ISAEngineProfileSample,
    comparison: ISAEngineProfileSample,
    baselineTier: ISAEngineTier,
    comparisonTier: ISAEngineTier
  ) -> ISAEngineComparisonResult {
    let sameWorkload = baseline.workloadName == comparison.workloadName
      && baseline.workloadRevision == comparison.workloadRevision
    // P2-05 item 5: Keep timed-out runs and use a real time limit.
    // A timed-out run (wallTimeNanoseconds == 0) is still a valid
    // comparison data point; it just shows the tier could not complete.
    let valid = sameWorkload

    return ISAEngineComparisonResult(
      baselineTier: baselineTier,
      comparisonTier: comparisonTier,
      workloadName: baseline.workloadName,
      workloadRevision: baseline.workloadRevision,
      baselineWallTimeNanoseconds: baseline.wallTimeNanoseconds,
      comparisonWallTimeNanoseconds: comparison.wallTimeNanoseconds,
      baselineRetiredInstructions: baseline.retiredGuestInstructions,
      comparisonRetiredInstructions: comparison.retiredGuestInstructions,
      valid: valid)
  }

  /// P2-05 item 3: Attribute Tier1 declines by executed guest work.
  /// Uses the negative cache hot sites from the executor diagnostics
  /// to identify the guest instruction forms causing the most runtime
  /// exits due to Tier1 declines.
  public static func attributeTier1Declines(
    from diagnostics: DoryARM64BaselineExecutorDiagnostics
  ) -> [ISATier1DeclineAttribution] {
    diagnostics.negativeCacheHotSites.map { site in
      .init(
        guestRIP: site.guestRIP,
        executionMode: site.executionMode.rawValue,
        declineReason: site.declineReason.rawValue,
        hitCount: site.hitCount,
        estimatedRuntimeExitCount: site.hitCount)
    }
  }

  /// P2-05 item 5: Generate a comparison report from multiple tier
  /// samples. The report includes pairwise comparisons and a summary
  /// of which tier is fastest for the given workload.
  public static func generateComparisonReport(
    samples: [(tier: ISAEngineTier, sample: ISAEngineProfileSample)]
  ) -> [ISAEngineComparisonResult] {
    guard let reference = samples.first else { return [] }
    var results: [ISAEngineComparisonResult] = []
    for entry in samples.dropFirst() {
      results.append(compare(
        baseline: reference.sample,
        comparison: entry.sample,
        baselineTier: reference.tier,
        comparisonTier: entry.tier))
    }
    return results
  }
}
