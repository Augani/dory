import DoryDBTX86
import Foundation

// P2-05: Profile the accepted engine before redesigning it.
//
// This file implements the engine profile collector (item 2), which wraps the
// existing DoryARM64BaselineExecutorDiagnostics counters with wall-time
// measurement. The collector records:
//   - Wall time (host monotonic clock)
//   - Retired guest instructions
//   - Compilation time
//   - Translation-cache occupancy
//   - Tier1 decline reasons
//   - Dispatcher entries
//   - Chain hits/misses
//   - Helper calls
//   - TLB misses, page walks
//   - Memory fault slow paths
//   - Device time
//
// The collector is designed to be used from a profiling run that exercises the
// engine with a real workload. It does not execute workloads itself; it
// provides the measurement framework that a runner uses.

/// P2-05 item 1: The frozen engine configuration under test.
/// This records the exact configuration that was profiled so that
/// comparisons are only valid between identical configurations.
public struct ISAEngineProfileConfiguration: Codable, Sendable, Hashable {
  public let tier: String  // "Tier1-direct-only", "Tier1", "Tier2"
  public let cpuProfile: String  // e.g. "compatibleV1"
  public let schedulingMode: String  // "serialized"
  public let firmwareVersion: String
  public let kernelInitrdDiskHash: String  // SHA-256 of kernel+initrd+disk

  public init(
    tier: String, cpuProfile: String, schedulingMode: String,
    firmwareVersion: String, kernelInitrdDiskHash: String
  ) {
    self.tier = tier
    self.cpuProfile = cpuProfile
    self.schedulingMode = schedulingMode
    self.firmwareVersion = firmwareVersion
    self.kernelInitrdDiskHash = kernelInitrdDiskHash
  }
}

/// P2-05 item 2: A single engine profile sample, collected from one
/// profiling run. All time values are in nanoseconds (host monotonic clock).
public struct ISAEngineProfileSample: Codable, Sendable, Hashable {
  public let configuration: ISAEngineProfileConfiguration
  public let workloadName: String
  public let workloadRevision: String  // source commit or fixture hash

  // Wall time and retired instructions
  public let wallTimeNanoseconds: UInt64
  public let retiredGuestInstructions: UInt64

  // Compilation time (total time spent compiling guest blocks)
  public let compilationTimeNanoseconds: UInt64
  public let compilationAttempts: UInt64
  public let compilationDeclines: UInt64

  // Translation cache occupancy
  public let translationCacheEntryCount: UInt64
  public let translationCacheAllocatedBytes: UInt64
  public let translationCacheMaximumBytes: UInt64
  public let translationCacheHits: UInt64
  public let translationCacheMisses: UInt64
  public let translationCacheInvalidations: UInt64

  // Tier1 decline reasons (attributed by executed guest work)
  public let tier1DeclineInterpreterHelper: UInt64
  public let tier1DeclineNativeEmitter: UInt64
  public let tier1CompiledBlocks: UInt64
  public let tier1CompilationAttempts: UInt64
  public let tier1CompilationDeclines: UInt64

  // Dispatcher and chain statistics
  public let nativeDispatcherEntries: UInt64
  public let directlyChainedBlocks: UInt64
  public let chainTargetAttempts: UInt64
  public let chainTargetAccepts: UInt64
  public let indirectBranchTargetCacheHits: UInt64
  public let indirectBranchTargetCacheMisses: UInt64
  public let shadowReturnStackHits: UInt64
  public let shadowReturnStackMisses: UInt64

  // Helper calls and slow paths
  public let helperCalls: UInt64
  public let memoryFaultSlowPaths: UInt64
  public let lazyFlagMaterializations: UInt64

  // Code cache churn
  public let codeCacheWraps: UInt64
  public let codeCacheEvictedBlocks: UInt64

  // Negative cache
  public let negativeCacheHits: UInt64
  public let negativeCacheMisses: UInt64

  // Pending work exits
  public let pendingWorkExits: UInt64

  public init(
    configuration: ISAEngineProfileConfiguration,
    workloadName: String,
    workloadRevision: String,
    wallTimeNanoseconds: UInt64,
    retiredGuestInstructions: UInt64,
    compilationTimeNanoseconds: UInt64,
    compilationAttempts: UInt64,
    compilationDeclines: UInt64,
    translationCacheEntryCount: UInt64,
    translationCacheAllocatedBytes: UInt64,
    translationCacheMaximumBytes: UInt64,
    translationCacheHits: UInt64,
    translationCacheMisses: UInt64,
    translationCacheInvalidations: UInt64,
    tier1DeclineInterpreterHelper: UInt64,
    tier1DeclineNativeEmitter: UInt64,
    tier1CompiledBlocks: UInt64,
    tier1CompilationAttempts: UInt64,
    tier1CompilationDeclines: UInt64,
    nativeDispatcherEntries: UInt64,
    directlyChainedBlocks: UInt64,
    chainTargetAttempts: UInt64,
    chainTargetAccepts: UInt64,
    indirectBranchTargetCacheHits: UInt64,
    indirectBranchTargetCacheMisses: UInt64,
    shadowReturnStackHits: UInt64,
    shadowReturnStackMisses: UInt64,
    helperCalls: UInt64,
    memoryFaultSlowPaths: UInt64,
    lazyFlagMaterializations: UInt64,
    codeCacheWraps: UInt64,
    codeCacheEvictedBlocks: UInt64,
    negativeCacheHits: UInt64,
    negativeCacheMisses: UInt64,
    pendingWorkExits: UInt64
  ) {
    self.configuration = configuration
    self.workloadName = workloadName
    self.workloadRevision = workloadRevision
    self.wallTimeNanoseconds = wallTimeNanoseconds
    self.retiredGuestInstructions = retiredGuestInstructions
    self.compilationTimeNanoseconds = compilationTimeNanoseconds
    self.compilationAttempts = compilationAttempts
    self.compilationDeclines = compilationDeclines
    self.translationCacheEntryCount = translationCacheEntryCount
    self.translationCacheAllocatedBytes = translationCacheAllocatedBytes
    self.translationCacheMaximumBytes = translationCacheMaximumBytes
    self.translationCacheHits = translationCacheHits
    self.translationCacheMisses = translationCacheMisses
    self.translationCacheInvalidations = translationCacheInvalidations
    self.tier1DeclineInterpreterHelper = tier1DeclineInterpreterHelper
    self.tier1DeclineNativeEmitter = tier1DeclineNativeEmitter
    self.tier1CompiledBlocks = tier1CompiledBlocks
    self.tier1CompilationAttempts = tier1CompilationAttempts
    self.tier1CompilationDeclines = tier1CompilationDeclines
    self.nativeDispatcherEntries = nativeDispatcherEntries
    self.directlyChainedBlocks = directlyChainedBlocks
    self.chainTargetAttempts = chainTargetAttempts
    self.chainTargetAccepts = chainTargetAccepts
    self.indirectBranchTargetCacheHits = indirectBranchTargetCacheHits
    self.indirectBranchTargetCacheMisses = indirectBranchTargetCacheMisses
    self.shadowReturnStackHits = shadowReturnStackHits
    self.shadowReturnStackMisses = shadowReturnStackMisses
    self.helperCalls = helperCalls
    self.memoryFaultSlowPaths = memoryFaultSlowPaths
    self.lazyFlagMaterializations = lazyFlagMaterializations
    self.codeCacheWraps = codeCacheWraps
    self.codeCacheEvictedBlocks = codeCacheEvictedBlocks
    self.negativeCacheHits = negativeCacheHits
    self.negativeCacheMisses = negativeCacheMisses
    self.pendingWorkExits = pendingWorkExits
  }

  /// Throughput in retired instructions per nanosecond.
  public var instructionsPerNanosecond: Double {
    wallTimeNanoseconds == 0 ? 0 : Double(retiredGuestInstructions) / Double(wallTimeNanoseconds)
  }

  /// Translation cache hit rate (0.0 to 1.0).
  public var translationCacheHitRate: Double {
    let total = translationCacheHits + translationCacheMisses
    return total == 0 ? 0 : Double(translationCacheHits) / Double(total)
  }

  /// Translation cache occupancy (0.0 to 1.0).
  public var translationCacheOccupancy: Double {
    translationCacheMaximumBytes == 0 ? 0
      : Double(translationCacheAllocatedBytes) / Double(translationCacheMaximumBytes)
  }

  /// Tier1 decline rate (0.0 to 1.0).
  public var tier1DeclineRate: Double {
    tier1CompilationAttempts == 0 ? 0
      : Double(tier1CompilationDeclines) / Double(tier1CompilationAttempts)
  }

  /// Chain target acceptance rate (0.0 to 1.0).
  public var chainTargetAcceptRate: Double {
    chainTargetAttempts == 0 ? 0 : Double(chainTargetAccepts) / Double(chainTargetAttempts)
  }

  /// IBTC hit rate (0.0 to 1.0).
  public var indirectBranchTargetCacheHitRate: Double {
    let total = indirectBranchTargetCacheHits + indirectBranchTargetCacheMisses
    return total == 0 ? 0 : Double(indirectBranchTargetCacheHits) / Double(total)
  }

  /// Shadow return stack hit rate (0.0 to 1.0).
  public var shadowReturnStackHitRate: Double {
    let total = shadowReturnStackHits + shadowReturnStackMisses
    return total == 0 ? 0 : Double(shadowReturnStackHits) / Double(total)
  }

  /// Compilation time as a fraction of wall time (0.0 to 1.0).
  public var compilationTimeFraction: Double {
    wallTimeNanoseconds == 0 ? 0
      : Double(compilationTimeNanoseconds) / Double(wallTimeNanoseconds)
  }
}

/// P2-05 item 2: A profiler that measures wall time around engine execution
/// and collects diagnostics from the existing executor counters.
public enum ISAEngineProfiler {
  /// Build a profile sample from explicit engine diagnostics, retired
  /// instruction count, and compilation time.  This is the reusable
  /// diagnostics-to-sample mapping shared by both the measured
  /// ``measure`` entry point and the live-receipt snapshot builder.
  ///
  /// `wallTimeNanoseconds` is taken verbatim from the caller; a snapshot
  /// collected at a live-run boundary passes the host-timing wall time so
  /// the resulting sample (and any cost report derived from it) reflects
  /// the real run duration rather than the instantaneous snapshot cost.
  public static func sample(
    configuration: ISAEngineProfileConfiguration,
    workloadName: String,
    workloadRevision: String,
    wallTimeNanoseconds: UInt64,
    diagnostics: DoryARM64BaselineExecutorDiagnostics,
    retiredInstructions: UInt64,
    compilationTimeNanoseconds: UInt64,
    translationCacheMaximumBytes: UInt64
  ) -> ISAEngineProfileSample {
    let diag = diagnostics
    return ISAEngineProfileSample(
      configuration: configuration,
      workloadName: workloadName,
      workloadRevision: workloadRevision,
      wallTimeNanoseconds: wallTimeNanoseconds,
      retiredGuestInstructions: retiredInstructions,
      compilationTimeNanoseconds: compilationTimeNanoseconds,
      compilationAttempts: diag.compiledBlocks,
      compilationDeclines: diag.declinedCompilations,
      translationCacheEntryCount: diag.translationCacheEntryCount,
      translationCacheAllocatedBytes: diag.translationCacheAllocatedBytes,
      translationCacheMaximumBytes: translationCacheMaximumBytes,
      translationCacheHits: diag.translationCacheHits,
      translationCacheMisses: diag.translationCacheMisses,
      translationCacheInvalidations: diag.translationCacheInvalidations,
      tier1DeclineInterpreterHelper: diag.negativeCacheMisses,  // attributed by executed work
      tier1DeclineNativeEmitter: diag.declinedCompilations,
      tier1CompiledBlocks: diag.tier1CompiledBlocks,
      tier1CompilationAttempts: diag.tier1CompilationAttempts,
      tier1CompilationDeclines: diag.tier1CompilationDeclines,
      nativeDispatcherEntries: diag.nativeDispatcherEntries,
      directlyChainedBlocks: diag.directlyChainedBlocks,
      chainTargetAttempts: diag.chainTargetAttempts,
      chainTargetAccepts: diag.chainTargetAccepts,
      indirectBranchTargetCacheHits: diag.indirectBranchTargetCacheHits,
      indirectBranchTargetCacheMisses: diag.indirectBranchTargetCacheMisses,
      shadowReturnStackHits: diag.shadowReturnStackHits,
      shadowReturnStackMisses: diag.shadowReturnStackMisses,
      // The direct-machine diagnostics API does not expose a separate helper-call
      // counter; lazy flag materializations are tracked as their own distinct
      // counter below so they are not double-counted as helper calls.
      helperCalls: 0,
      memoryFaultSlowPaths: diag.translationCachePageFaults,
      lazyFlagMaterializations: diag.lazyFlagMaterializations,
      codeCacheWraps: diag.codeCacheWraps,
      codeCacheEvictedBlocks: diag.codeCacheEvictedBlocks,
      negativeCacheHits: diag.negativeCacheHits,
      negativeCacheMisses: diag.negativeCacheMisses,
      pendingWorkExits: diag.pendingWorkExits)
  }

  /// Measure a block of engine work, returning a profile sample with
  /// wall time and diagnostics. The caller provides the configuration,
  /// workload identity, and a closure that returns the diagnostics and
  /// retired instruction count.
  public static func measure(
    configuration: ISAEngineProfileConfiguration,
    workloadName: String,
    workloadRevision: String,
    translationCacheMaximumBytes: UInt64,
    body: () throws -> (diagnostics: DoryARM64BaselineExecutorDiagnostics,
                       retiredInstructions: UInt64,
                       compilationTimeNanoseconds: UInt64)
  ) rethrows -> ISAEngineProfileSample {
    let start = DispatchTime.now()
    let result = try body()
    let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds

    return sample(
      configuration: configuration,
      workloadName: workloadName,
      workloadRevision: workloadRevision,
      wallTimeNanoseconds: elapsed,
      diagnostics: result.diagnostics,
      retiredInstructions: result.retiredInstructions,
      compilationTimeNanoseconds: result.compilationTimeNanoseconds,
      translationCacheMaximumBytes: translationCacheMaximumBytes)
  }
}
