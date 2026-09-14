import DoryDBTX86
import DoryMachinePC
import Foundation

// P2-05: Live engine-profile receipt.
//
// A production-facing, serializable receipt that records declared workload
// identity, terminal outcome, start/end engine snapshots, and host timing
// from a bounded, instrumented DoryPCDirectKernelMachine execution.  The
// receipt is derived from real engine evidence collected at an explicit
// live-run boundary; it does not synthesize retired instructions, cache
// counters, or wall time.
//
// Only a receipt whose outcome is .completed may be used to generate a
// comparable ranked cost report.  Partial/timeout/stopped/failed receipts
// remain explicit and must not masquerade as completed evidence.

/// The declared completion condition for a bounded engine run.
///
/// A run reaches its completion condition when the machine stop matches
/// the condition.  For example, a run with `.poweredOff` completes only
/// when the machine reports a powered-off stop; a run with
/// `.instructionBudget(n)` completes when the instruction budget is
/// exhausted.
public enum ISAEngineCompletionCondition: Codable, Sendable, Hashable {
  /// The run completes when the guest powers off the machine.
  case poweredOff
  /// The run completes when all processors halt.
  case halted
  /// The run completes when exactly `instructionCount` guest instructions
  /// have retired.
  case instructionBudget(instructionCount: UInt64)
  /// The run completes when it has executed for at least `seconds` of
  /// host wall time.
  case wallTimeBudget(seconds: UInt64)
}

/// Terminal outcome of a bounded engine run.
public enum ISAEngineReceiptOutcome: String, Codable, Sendable, Hashable {
  /// The run reached its declared completion condition.
  case completed
  /// The run exceeded its wall-time budget before completing.
  case timeout
  /// The run stopped (halted, exception, triple fault, reset) before
  /// reaching its declared completion condition.
  case stopped
  /// The run failed with an error before completing.
  case failed
}

/// The terminal stop result of a bounded engine run, translated from the
/// machine's native stop type into a receipt-level representation.
///
/// This type uses only values from `DoryDBTX86` so it can be adopted by
/// `DoryPCDirectKernelMachine` without adding a module dependency to
/// `dory-x86-decode-audit`.
public enum ISAEngineRunResult: Sendable, Hashable {
  /// The machine powered off.
  case poweredOff(instructionCount: UInt64)
  /// All processors halted.
  case halted(instructionCount: UInt64)
  /// The machine stopped on an architectural exception.
  case exception(instructionCount: UInt64)
  /// The machine triple-faulted.
  case tripleFault(instructionCount: UInt64)
  /// The machine reset.
  case reset(instructionCount: UInt64)
  /// The instruction budget was exhausted.
  case instructionBudget(UInt64)
  /// The wall-time budget was exceeded.
  case wallTimeBudget
  /// The run failed with an error.
  case failed(String)

  /// A short human-readable description suitable for the receipt's
  /// `stopReason` field.
  public var description: String {
    switch self {
    case .poweredOff(let n): "poweredOff(instructions=\(n))"
    case .halted(let n): "halted(instructions=\(n))"
    case .exception(let n): "exception(instructions=\(n))"
    case .tripleFault(let n): "tripleFault(instructions=\(n))"
    case .reset(let n): "reset(instructions=\(n))"
    case .instructionBudget(let n): "instructionBudget(\(n))"
    case .wallTimeBudget: "wallTimeBudget"
    case .failed(let msg): "failed(\(msg))"
    }
  }
}

extension ISAEngineRunResult {
  /// Translate the concrete machine's native stop type into the receipt-level
  /// run result.  This is the only bridge from `DoryMachinePC`'s stop enum to
  /// the receipt representation; it preserves the retired-instruction count
  /// reported by the machine without synthesizing any value.
  public init(_ stop: DoryPCMachineStop) {
    switch stop {
    case .halted(let instructionCount):
      self = .halted(instructionCount: instructionCount)
    case .exception(_, let instructionCount):
      self = .exception(instructionCount: instructionCount)
    case .tripleFault(_, let instructionCount):
      self = .tripleFault(instructionCount: instructionCount)
    case .poweredOff(let instructionCount):
      self = .poweredOff(instructionCount: instructionCount)
    case .reset(let instructionCount):
      self = .reset(instructionCount: instructionCount)
    case .instructionBudget(let instructionCount):
      self = .instructionBudget(instructionCount)
    }
  }
}

/// Host timing for a bounded engine run, recorded at explicit live-run
/// boundaries.
public struct ISAEngineHostTiming: Codable, Sendable, Hashable {
  /// Host monotonic nanoseconds at the start of the run.
  public let startNanoseconds: UInt64
  /// Host monotonic nanoseconds at the end of the run.
  public let endNanoseconds: UInt64

  public init(startNanoseconds: UInt64, endNanoseconds: UInt64) {
    self.startNanoseconds = startNanoseconds
    self.endNanoseconds = endNanoseconds
  }

  /// Wall time elapsed between start and end, in nanoseconds.
  public var wallTimeNanoseconds: UInt64 {
    endNanoseconds &- startNanoseconds
  }
}

/// Evidence about the observed execution tier versus the declared
/// profile tier.  A receipt must not silently accept a caller-provided
/// tier string that disagrees with the concrete machine's actual tier.
public enum ISAEngineTierEvidence: Codable, Sendable, Hashable {
  /// The concrete machine's execution tier matches the declared profile
  /// tier.
  case verified(observedTier: DoryPCExecutionTier)
  /// The concrete machine's execution tier does not match the declared
  /// profile tier.  The receipt records the mismatch; cost reports must
  /// treat this as unverified rather than silently accepting it.
  case mismatch(declaredTier: String, observedTier: DoryPCExecutionTier)
  /// The tier could not be verified from the available evidence.
  case unverified
}

/// Codable snapshot of a host time breakdown category, capturing the
/// wall and thread-CPU split available from the direct-machine API.
public struct ISAEngineHostTimeBreakdownSnapshot: Codable, Sendable, Hashable {
  public let totalNanoseconds: UInt64
  public let processorEventNanoseconds: UInt64
  public let clockAdvancementNanoseconds: UInt64
  public let interruptDeliveryNanoseconds: UInt64
  public let processorExecutionNanoseconds: UInt64
  public let idleWaitNanoseconds: UInt64

  public init(_ breakdown: DoryPCHostTimeBreakdown) {
    self.totalNanoseconds = breakdown.totalNanoseconds
    self.processorEventNanoseconds = breakdown.processorEventNanoseconds
    self.clockAdvancementNanoseconds = breakdown.clockAdvancementNanoseconds
    self.interruptDeliveryNanoseconds = breakdown.interruptDeliveryNanoseconds
    self.processorExecutionNanoseconds = breakdown.processorExecutionNanoseconds
    self.idleWaitNanoseconds = breakdown.idleWaitNanoseconds
  }

  public init(
    totalNanoseconds: UInt64, processorEventNanoseconds: UInt64,
    clockAdvancementNanoseconds: UInt64, interruptDeliveryNanoseconds: UInt64,
    processorExecutionNanoseconds: UInt64, idleWaitNanoseconds: UInt64
  ) {
    self.totalNanoseconds = totalNanoseconds
    self.processorEventNanoseconds = processorEventNanoseconds
    self.clockAdvancementNanoseconds = clockAdvancementNanoseconds
    self.interruptDeliveryNanoseconds = interruptDeliveryNanoseconds
    self.processorExecutionNanoseconds = processorExecutionNanoseconds
    self.idleWaitNanoseconds = idleWaitNanoseconds
  }
}

/// Codable snapshot of the host execution diagnostics available from the
/// direct-machine API.  This records the wall and thread-CPU timing split
/// when the machine supplies it; device/RPC stages are explicitly
/// unavailable for this direct-machine boundary and are not synthesized.
public struct ISAEngineHostExecutionDiagnosticsSnapshot: Codable, Sendable, Hashable {
  public let enabled: Bool
  public let runCalls: UInt64
  public let wall: ISAEngineHostTimeBreakdownSnapshot
  public let threadCPU: ISAEngineHostTimeBreakdownSnapshot

  public init(_ diagnostics: DoryPCHostExecutionDiagnostics) {
    self.enabled = diagnostics.enabled
    self.runCalls = diagnostics.runCalls
    self.wall = .init(diagnostics.wall)
    self.threadCPU = .init(diagnostics.threadCPU)
  }

  public init(
    enabled: Bool, runCalls: UInt64,
    wall: ISAEngineHostTimeBreakdownSnapshot,
    threadCPU: ISAEngineHostTimeBreakdownSnapshot
  ) {
    self.enabled = enabled
    self.runCalls = runCalls
    self.wall = wall
    self.threadCPU = threadCPU
  }
}

/// A serializable receipt recording live engine evidence from a bounded,
/// instrumented machine run.
///
/// The receipt stores declared workload identity, the terminal outcome,
/// start/end engine snapshots, and host timing.  All fields are derived
/// from real engine state; the receipt does not synthesize counters or
/// wall time.
public struct ISAEngineProfileReceipt: Codable, Sendable, Hashable {
  public let configuration: ISAEngineProfileConfiguration
  public let workloadName: String
  public let workloadRevision: String
  public let completionCondition: ISAEngineCompletionCondition
  public let outcome: ISAEngineReceiptOutcome
  /// Engine snapshot captured before the run begins.  Counters are
  /// typically zero for a freshly constructed machine.  This is a raw
  /// cumulative snapshot; it is retained for provenance but must not be
  /// used directly as the workload result.
  public let startSample: ISAEngineProfileSample
  /// Engine snapshot captured at the live-run boundary after the run
  /// ends.  This is a raw cumulative snapshot; it is retained for
  /// provenance but must not be used directly as the workload result.
  /// Use ``runSample`` for per-run delta evidence.
  public let endSample: ISAEngineProfileSample
  public let hostTiming: ISAEngineHostTiming
  /// Human-readable stop reason translated from the machine's native
  /// stop type.
  public let stopReason: String

  /// Evidence about the observed execution tier versus the declared
  /// profile tier.  A mismatch is recorded, not silently accepted.
  public let observedTierEvidence: ISAEngineTierEvidence

  /// Host execution diagnostics (wall and thread-CPU split) when the
  /// direct-machine API supplies them.  `nil` when unavailable.
  public let hostExecutionDiagnostics: ISAEngineHostExecutionDiagnosticsSnapshot?

  /// Always `false` for this direct-machine boundary: device and RPC
  /// stages are not available and are not synthesized.
  public let deviceRPCStagesAvailable: Bool

  /// The bounded instruction quantum used for wall-time-budget runs, or
  /// `nil` for non-wall-time runs.  The deadline is observed only between
  /// quanta, so real-time overshoot is bounded by one quantum.
  public let wallTimeInstructionQuantum: UInt64?

  /// `true` when the wall-time deadline was observed only between
  /// instruction quanta (not mid-quantum).  `nil` for non-wall-time runs.
  public let deadlineObservedBetweenQuanta: Bool?

  public init(
    configuration: ISAEngineProfileConfiguration,
    workloadName: String,
    workloadRevision: String,
    completionCondition: ISAEngineCompletionCondition,
    outcome: ISAEngineReceiptOutcome,
    startSample: ISAEngineProfileSample,
    endSample: ISAEngineProfileSample,
    hostTiming: ISAEngineHostTiming,
    stopReason: String,
    observedTierEvidence: ISAEngineTierEvidence = .unverified,
    hostExecutionDiagnostics: ISAEngineHostExecutionDiagnosticsSnapshot? = nil,
    deviceRPCStagesAvailable: Bool = false,
    wallTimeInstructionQuantum: UInt64? = nil,
    deadlineObservedBetweenQuanta: Bool? = nil
  ) {
    self.configuration = configuration
    self.workloadName = workloadName
    self.workloadRevision = workloadRevision
    self.completionCondition = completionCondition
    self.outcome = outcome
    self.startSample = startSample
    self.endSample = endSample
    self.hostTiming = hostTiming
    self.stopReason = stopReason
    self.observedTierEvidence = observedTierEvidence
    self.hostExecutionDiagnostics = hostExecutionDiagnostics
    self.deviceRPCStagesAvailable = deviceRPCStagesAvailable
    self.wallTimeInstructionQuantum = wallTimeInstructionQuantum
    self.deadlineObservedBetweenQuanta = deadlineObservedBetweenQuanta
  }

  // MARK: - Codable (backward-compatible with pre-existing receipts)

  private enum CodingKeys: String, CodingKey {
    case configuration, workloadName, workloadRevision
    case completionCondition, outcome
    case startSample, endSample, hostTiming, stopReason
    case observedTierEvidence, hostExecutionDiagnostics
    case deviceRPCStagesAvailable
    case wallTimeInstructionQuantum, deadlineObservedBetweenQuanta
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    configuration = try c.decode(ISAEngineProfileConfiguration.self, forKey: .configuration)
    workloadName = try c.decode(String.self, forKey: .workloadName)
    workloadRevision = try c.decode(String.self, forKey: .workloadRevision)
    completionCondition = try c.decode(ISAEngineCompletionCondition.self, forKey: .completionCondition)
    outcome = try c.decode(ISAEngineReceiptOutcome.self, forKey: .outcome)
    startSample = try c.decode(ISAEngineProfileSample.self, forKey: .startSample)
    endSample = try c.decode(ISAEngineProfileSample.self, forKey: .endSample)
    hostTiming = try c.decode(ISAEngineHostTiming.self, forKey: .hostTiming)
    stopReason = try c.decode(String.self, forKey: .stopReason)
    observedTierEvidence = try c.decodeIfPresent(ISAEngineTierEvidence.self, forKey: .observedTierEvidence) ?? .unverified
    hostExecutionDiagnostics = try c.decodeIfPresent(ISAEngineHostExecutionDiagnosticsSnapshot.self, forKey: .hostExecutionDiagnostics)
    deviceRPCStagesAvailable = try c.decodeIfPresent(Bool.self, forKey: .deviceRPCStagesAvailable) ?? false
    wallTimeInstructionQuantum = try c.decodeIfPresent(UInt64.self, forKey: .wallTimeInstructionQuantum)
    deadlineObservedBetweenQuanta = try c.decodeIfPresent(Bool.self, forKey: .deadlineObservedBetweenQuanta)
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(configuration, forKey: .configuration)
    try c.encode(workloadName, forKey: .workloadName)
    try c.encode(workloadRevision, forKey: .workloadRevision)
    try c.encode(completionCondition, forKey: .completionCondition)
    try c.encode(outcome, forKey: .outcome)
    try c.encode(startSample, forKey: .startSample)
    try c.encode(endSample, forKey: .endSample)
    try c.encode(hostTiming, forKey: .hostTiming)
    try c.encode(stopReason, forKey: .stopReason)
    try c.encode(observedTierEvidence, forKey: .observedTierEvidence)
    try c.encodeIfPresent(hostExecutionDiagnostics, forKey: .hostExecutionDiagnostics)
    try c.encode(deviceRPCStagesAvailable, forKey: .deviceRPCStagesAvailable)
    try c.encodeIfPresent(wallTimeInstructionQuantum, forKey: .wallTimeInstructionQuantum)
    try c.encodeIfPresent(deadlineObservedBetweenQuanta, forKey: .deadlineObservedBetweenQuanta)
  }

  // MARK: - Derived evidence

  /// True only when the run reached its declared completion condition.
  public var isCompleted: Bool { outcome == .completed }

  /// True only when the observed execution tier matches the declared
  /// profile tier, both snapshots match the receipt's configuration and
  /// workload identity, and all run counters remained monotonic. Cost
  /// reports require this in addition to ``isCompleted``; identity drift
  /// or a counter regression cannot become comparable evidence.
  public var isProvenanceVerified: Bool {
    guard isIdentityConsistent, counterRegressions.isEmpty else { return false }
    if case .verified = observedTierEvidence { return true }
    return false
  }

  private var isIdentityConsistent: Bool {
    startSample.configuration == configuration
      && endSample.configuration == configuration
      && startSample.workloadName == workloadName
      && endSample.workloadName == workloadName
      && startSample.workloadRevision == workloadRevision
      && endSample.workloadRevision == workloadRevision
  }

  /// Monotonic counters that regressed between the start and end
  /// snapshots.  A non-empty list means the delta evidence is suspect;
  /// the affected counter is clamped to zero in ``runSample`` rather
  /// than underflowing.
  public var counterRegressions: [String] {
    let s = startSample
    let e = endSample
    var regressions: [String] = []
    func check(_ name: String, _ end: UInt64, _ start: UInt64) {
      if end < start { regressions.append(name) }
    }
    check("retiredGuestInstructions", e.retiredGuestInstructions, s.retiredGuestInstructions)
    check("compilationTimeNanoseconds", e.compilationTimeNanoseconds, s.compilationTimeNanoseconds)
    check("compilationAttempts", e.compilationAttempts, s.compilationAttempts)
    check("compilationDeclines", e.compilationDeclines, s.compilationDeclines)
    check("translationCacheHits", e.translationCacheHits, s.translationCacheHits)
    check("translationCacheMisses", e.translationCacheMisses, s.translationCacheMisses)
    check("translationCacheInvalidations", e.translationCacheInvalidations, s.translationCacheInvalidations)
    check("tier1DeclineInterpreterHelper", e.tier1DeclineInterpreterHelper, s.tier1DeclineInterpreterHelper)
    check("tier1DeclineNativeEmitter", e.tier1DeclineNativeEmitter, s.tier1DeclineNativeEmitter)
    if let start = s.confirmedInterpreterFallback {
      if let end = e.confirmedInterpreterFallback {
        if end.hasRegression(since: start) { regressions.append("confirmedInterpreterFallback") }
      } else {
        regressions.append("confirmedInterpreterFallback.unavailable")
      }
    }
    check("tier1CompiledBlocks", e.tier1CompiledBlocks, s.tier1CompiledBlocks)
    check("tier1CompilationAttempts", e.tier1CompilationAttempts, s.tier1CompilationAttempts)
    check("tier1CompilationDeclines", e.tier1CompilationDeclines, s.tier1CompilationDeclines)
    check("nativeDispatcherEntries", e.nativeDispatcherEntries, s.nativeDispatcherEntries)
    check("directlyChainedBlocks", e.directlyChainedBlocks, s.directlyChainedBlocks)
    check("chainTargetAttempts", e.chainTargetAttempts, s.chainTargetAttempts)
    check("chainTargetAccepts", e.chainTargetAccepts, s.chainTargetAccepts)
    check("indirectBranchTargetCacheHits", e.indirectBranchTargetCacheHits, s.indirectBranchTargetCacheHits)
    check("indirectBranchTargetCacheMisses", e.indirectBranchTargetCacheMisses, s.indirectBranchTargetCacheMisses)
    check("shadowReturnStackHits", e.shadowReturnStackHits, s.shadowReturnStackHits)
    check("shadowReturnStackMisses", e.shadowReturnStackMisses, s.shadowReturnStackMisses)
    check("helperCalls", e.helperCalls, s.helperCalls)
    check("memoryFaultSlowPaths", e.memoryFaultSlowPaths, s.memoryFaultSlowPaths)
    check("lazyFlagMaterializations", e.lazyFlagMaterializations, s.lazyFlagMaterializations)
    check("codeCacheWraps", e.codeCacheWraps, s.codeCacheWraps)
    check("codeCacheEvictedBlocks", e.codeCacheEvictedBlocks, s.codeCacheEvictedBlocks)
    check("negativeCacheHits", e.negativeCacheHits, s.negativeCacheHits)
    check("negativeCacheMisses", e.negativeCacheMisses, s.negativeCacheMisses)
    check("pendingWorkExits", e.pendingWorkExits, s.pendingWorkExits)
    return regressions
  }

  /// Per-run delta sample: every monotonic counter is subtracted
  /// (end − start) with saturating subtraction that rejects regression
  /// rather than underflowing.  Snapshot fields (cache entry count,
  /// allocated bytes, maximum bytes) use the end-of-run value.  Wall
  /// time comes from ``hostTiming`` (host monotonic elapsed), not from a
  /// counter delta.  This is the evidence a cost report must use; the
  /// raw ``endSample`` is retained only for provenance.
  public var runSample: ISAEngineProfileSample {
    let s = startSample
    let e = endSample
    func delta(_ end: UInt64, _ start: UInt64) -> UInt64 {
      end >= start ? end - start : 0
    }
    let fallbackDelta = s.confirmedInterpreterFallback.flatMap { start in
      e.confirmedInterpreterFallback?.delta(since: start)
    }
    return ISAEngineProfileSample(
      configuration: e.configuration,
      workloadName: e.workloadName,
      workloadRevision: e.workloadRevision,
      wallTimeNanoseconds: hostTiming.wallTimeNanoseconds,
      retiredGuestInstructions: delta(e.retiredGuestInstructions, s.retiredGuestInstructions),
      compilationTimeNanoseconds: delta(e.compilationTimeNanoseconds, s.compilationTimeNanoseconds),
      compilationAttempts: delta(e.compilationAttempts, s.compilationAttempts),
      compilationDeclines: delta(e.compilationDeclines, s.compilationDeclines),
      translationCacheEntryCount: e.translationCacheEntryCount,
      translationCacheAllocatedBytes: e.translationCacheAllocatedBytes,
      translationCacheMaximumBytes: e.translationCacheMaximumBytes,
      translationCacheHits: delta(e.translationCacheHits, s.translationCacheHits),
      translationCacheMisses: delta(e.translationCacheMisses, s.translationCacheMisses),
      translationCacheInvalidations: delta(e.translationCacheInvalidations, s.translationCacheInvalidations),
      tier1DeclineInterpreterHelper: fallbackDelta?.retiredInstructions(for: .interpreterHelper) ?? 0,
      tier1DeclineNativeEmitter: fallbackDelta?.retiredInstructions(for: .nativeEmitter) ?? 0,
      tier1CompiledBlocks: delta(e.tier1CompiledBlocks, s.tier1CompiledBlocks),
      tier1CompilationAttempts: delta(e.tier1CompilationAttempts, s.tier1CompilationAttempts),
      tier1CompilationDeclines: delta(e.tier1CompilationDeclines, s.tier1CompilationDeclines),
      nativeDispatcherEntries: delta(e.nativeDispatcherEntries, s.nativeDispatcherEntries),
      directlyChainedBlocks: delta(e.directlyChainedBlocks, s.directlyChainedBlocks),
      chainTargetAttempts: delta(e.chainTargetAttempts, s.chainTargetAttempts),
      chainTargetAccepts: delta(e.chainTargetAccepts, s.chainTargetAccepts),
      indirectBranchTargetCacheHits: delta(e.indirectBranchTargetCacheHits, s.indirectBranchTargetCacheHits),
      indirectBranchTargetCacheMisses: delta(e.indirectBranchTargetCacheMisses, s.indirectBranchTargetCacheMisses),
      shadowReturnStackHits: delta(e.shadowReturnStackHits, s.shadowReturnStackHits),
      shadowReturnStackMisses: delta(e.shadowReturnStackMisses, s.shadowReturnStackMisses),
      helperCalls: delta(e.helperCalls, s.helperCalls),
      memoryFaultSlowPaths: delta(e.memoryFaultSlowPaths, s.memoryFaultSlowPaths),
      lazyFlagMaterializations: delta(e.lazyFlagMaterializations, s.lazyFlagMaterializations),
      codeCacheWraps: delta(e.codeCacheWraps, s.codeCacheWraps),
      codeCacheEvictedBlocks: delta(e.codeCacheEvictedBlocks, s.codeCacheEvictedBlocks),
      negativeCacheHits: delta(e.negativeCacheHits, s.negativeCacheHits),
      negativeCacheMisses: delta(e.negativeCacheMisses, s.negativeCacheMisses),
      pendingWorkExits: delta(e.pendingWorkExits, s.pendingWorkExits),
      confirmedInterpreterFallback: fallbackDelta)
  }
}

/// Integration seam for collecting live engine snapshots from a bounded,
/// instrumented machine run.
///
/// Conformers provide real diagnostics from an execution engine (e.g.
/// `DoryPCDirectKernelMachine` via an extension in `DoryMachinePC`).
/// Tests use controlled snapshots.  This protocol uses only types from
/// `DoryDBTX86` so it can be adopted without adding a module dependency
/// to `dory-x86-decode-audit`.
public protocol ISAEngineSnapshotProvider: Sendable {
  /// Baseline JIT executor diagnostics at the current live-run boundary,
  /// or `nil` for interpreter-only runs.
  var baselineDiagnostics: DoryARM64BaselineExecutorDiagnostics? { get }

  /// Total retired guest instructions across all execution tiers.
  var retiredGuestInstructions: UInt64 { get }

  /// Estimated compilation time in nanoseconds, or 0 if unavailable.
  var compilationTimeNanoseconds: UInt64 { get }

  /// Maximum translation cache bytes for the configured JIT.
  var translationCacheMaximumBytes: UInt64 { get }
}

/// Builds profile samples and receipts from live engine snapshots.
public enum ISAEngineReceiptBuilder {
  /// Build a profile sample from a snapshot provider at the current live
  /// engine state.
  ///
  /// `wallTimeNanoseconds` is taken verbatim so the caller can supply the
  /// host-timing wall time for the end-of-run snapshot (or 0 for a
  /// start-of-run snapshot).
  public static func sample(
    from provider: ISAEngineSnapshotProvider,
    configuration: ISAEngineProfileConfiguration,
    workloadName: String,
    workloadRevision: String,
    wallTimeNanoseconds: UInt64
  ) -> ISAEngineProfileSample {
    guard let diagnostics = provider.baselineDiagnostics else {
      return ISAEngineProfileSample(
        configuration: configuration,
        workloadName: workloadName,
        workloadRevision: workloadRevision,
        wallTimeNanoseconds: wallTimeNanoseconds,
        retiredGuestInstructions: provider.retiredGuestInstructions,
        compilationTimeNanoseconds: provider.compilationTimeNanoseconds,
        compilationAttempts: 0,
        compilationDeclines: 0,
        translationCacheEntryCount: 0,
        translationCacheAllocatedBytes: 0,
        translationCacheMaximumBytes: provider.translationCacheMaximumBytes,
        translationCacheHits: 0,
        translationCacheMisses: 0,
        translationCacheInvalidations: 0,
        tier1DeclineInterpreterHelper: 0,
        tier1DeclineNativeEmitter: 0,
        tier1CompiledBlocks: 0,
        tier1CompilationAttempts: 0,
        tier1CompilationDeclines: 0,
        nativeDispatcherEntries: 0,
        directlyChainedBlocks: 0,
        chainTargetAttempts: 0,
        chainTargetAccepts: 0,
        indirectBranchTargetCacheHits: 0,
        indirectBranchTargetCacheMisses: 0,
        shadowReturnStackHits: 0,
        shadowReturnStackMisses: 0,
        helperCalls: 0,
        memoryFaultSlowPaths: 0,
        lazyFlagMaterializations: 0,
        codeCacheWraps: 0,
        codeCacheEvictedBlocks: 0,
        negativeCacheHits: 0,
        negativeCacheMisses: 0,
        pendingWorkExits: 0)
    }

    return ISAEngineProfiler.sample(
      configuration: configuration,
      workloadName: workloadName,
      workloadRevision: workloadRevision,
      wallTimeNanoseconds: wallTimeNanoseconds,
      diagnostics: diagnostics,
      retiredInstructions: provider.retiredGuestInstructions,
      compilationTimeNanoseconds: provider.compilationTimeNanoseconds,
      translationCacheMaximumBytes: provider.translationCacheMaximumBytes)
  }

  /// Resolve the terminal outcome from a declared completion condition
  /// and the actual machine stop result.
  ///
  /// - A `.wallTimeBudget` stop is always a timeout.
  /// - A `.failed` stop is always a failure.
  /// - Otherwise the run is completed only when the stop matches the
  ///   declared completion condition; any other stop is `.stopped`.
  public static func resolveOutcome(
    completionCondition: ISAEngineCompletionCondition,
    result: ISAEngineRunResult
  ) -> ISAEngineReceiptOutcome {
    switch result {
    case .failed: return .failed
    case .wallTimeBudget: return .timeout
    default:
      return matches(completionCondition, result) ? .completed : .stopped
    }
  }

  /// Build a receipt from live engine snapshots, host timing, and the
  /// machine stop result.
  public static func build(
    configuration: ISAEngineProfileConfiguration,
    workloadName: String,
    workloadRevision: String,
    completionCondition: ISAEngineCompletionCondition,
    startSample: ISAEngineProfileSample,
    endSample: ISAEngineProfileSample,
    hostTiming: ISAEngineHostTiming,
    result: ISAEngineRunResult,
    observedTierEvidence: ISAEngineTierEvidence = .unverified,
    hostExecutionDiagnostics: ISAEngineHostExecutionDiagnosticsSnapshot? = nil,
    deviceRPCStagesAvailable: Bool = false,
    wallTimeInstructionQuantum: UInt64? = nil,
    deadlineObservedBetweenQuanta: Bool? = nil
  ) -> ISAEngineProfileReceipt {
    let outcome = resolveOutcome(
      completionCondition: completionCondition, result: result)
    return ISAEngineProfileReceipt(
      configuration: configuration,
      workloadName: workloadName,
      workloadRevision: workloadRevision,
      completionCondition: completionCondition,
      outcome: outcome,
      startSample: startSample,
      endSample: endSample,
      hostTiming: hostTiming,
      stopReason: result.description,
      observedTierEvidence: observedTierEvidence,
      hostExecutionDiagnostics: hostExecutionDiagnostics,
      deviceRPCStagesAvailable: deviceRPCStagesAvailable,
      wallTimeInstructionQuantum: wallTimeInstructionQuantum,
      deadlineObservedBetweenQuanta: deadlineObservedBetweenQuanta)
  }

  // MARK: - Concrete DoryPCDirectKernelMachine integration

  /// Build a profile sample from a concrete `DoryPCDirectKernelMachine`'s
  /// public execution, JIT, and timing counters at the current live-run
  /// boundary.
  ///
  /// The retired-instruction count is the sum of the machine's
  /// interpreter, baseline-JIT, and optimizing-JIT retired counters.
  /// JIT cache counters are read verbatim from the machine's
  /// `baselineJITDiagnostics` snapshot; an interpreter-only machine reports
  /// a zero-JIT sample.  `compilationTimeNanoseconds` is reported as 0
  /// because the machine does not expose compilation time as a separate
  /// public counter; the cost report treats unavailable compilation time
  /// honestly rather than synthesizing it.  No counter or wall time is
  /// synthesized.
  public static func sample(
    from machine: DoryPCDirectKernelMachine,
    configuration: ISAEngineProfileConfiguration,
    workloadName: String,
    workloadRevision: String,
    wallTimeNanoseconds: UInt64,
    translationCacheMaximumBytes: UInt64
  ) -> ISAEngineProfileSample {
    let execution = machine.executionStatistics
    let retired = execution.interpreterInstructions
      &+ execution.baselineJITInstructions
      &+ execution.optimizingJITInstructions

    guard let jit = machine.baselineJITDiagnostics else {
      return ISAEngineProfileSample(
        configuration: configuration,
        workloadName: workloadName,
        workloadRevision: workloadRevision,
        wallTimeNanoseconds: wallTimeNanoseconds,
        retiredGuestInstructions: retired,
        compilationTimeNanoseconds: 0,
        compilationAttempts: 0,
        compilationDeclines: 0,
        translationCacheEntryCount: 0,
        translationCacheAllocatedBytes: 0,
        translationCacheMaximumBytes: translationCacheMaximumBytes,
        translationCacheHits: 0,
        translationCacheMisses: 0,
        translationCacheInvalidations: 0,
        tier1DeclineInterpreterHelper: 0,
        tier1DeclineNativeEmitter: 0,
        tier1CompiledBlocks: 0,
        tier1CompilationAttempts: 0,
        tier1CompilationDeclines: 0,
        nativeDispatcherEntries: 0,
        directlyChainedBlocks: 0,
        chainTargetAttempts: 0,
        chainTargetAccepts: 0,
        indirectBranchTargetCacheHits: 0,
        indirectBranchTargetCacheMisses: 0,
        shadowReturnStackHits: 0,
        shadowReturnStackMisses: 0,
        helperCalls: 0,
        memoryFaultSlowPaths: 0,
        lazyFlagMaterializations: 0,
        codeCacheWraps: 0,
        codeCacheEvictedBlocks: 0,
        negativeCacheHits: 0,
        negativeCacheMisses: 0,
        pendingWorkExits: 0)
    }

    return sampleFromJITCacheStatistics(
      jit,
      configuration: configuration,
      workloadName: workloadName,
      workloadRevision: workloadRevision,
      wallTimeNanoseconds: wallTimeNanoseconds,
      retiredGuestInstructions: retired,
      translationCacheMaximumBytes: translationCacheMaximumBytes)
  }

  /// Run a bounded, instrumented `DoryPCDirectKernelMachine` execution and
  /// build a live receipt from real pre-run and terminal engine snapshots.
  ///
  /// The machine must already be loaded with the workload's boot state
  /// before this call.  The receipt's start sample is captured before the
  /// run, the end sample after, and host timing brackets the run with the
  /// host monotonic clock.  The terminal `DoryPCMachineStop` is translated
  /// to an `ISAEngineRunResult` and the outcome is resolved against the
  /// declared completion condition.
  ///
  /// The concrete machine's `executionTier` is read and validated against
  /// the declared profile configuration tier; a mismatch is recorded as
  /// `ISAEngineTierEvidence.mismatch` so cost reports treat it as
  /// unverified rather than silently accepting it.
  ///
  /// - For `.instructionBudget(n)` the machine is run with that budget.
  /// - For `.poweredOff` or `.halted` the machine is run with
  ///   `maximumInstructionBudget`; an exhausted budget yields a `.stopped`
  ///   receipt because the declared condition was not reached.
  /// - For `.wallTimeBudget(seconds)` the machine is run in bounded chunks
  ///   of `wallTimeChunkInstructions` until the wall-time deadline elapses
  ///   (`.timeout`) or the machine stops for another reason.  The deadline
  ///   is observed only between quanta, so real-time overshoot is bounded
  ///   by one quantum; this is recorded in the receipt.
  public static func run(
    machine: DoryPCDirectKernelMachine,
    configuration: ISAEngineProfileConfiguration,
    workloadName: String,
    workloadRevision: String,
    completionCondition: ISAEngineCompletionCondition,
    translationCacheMaximumBytes: UInt64,
    exceptionPolicy: DoryPCExceptionPolicy = .deliver,
    maximumInstructionBudget: UInt64 = 1_000_000_000,
    wallTimeChunkInstructions: UInt64 = 10_000_000
  ) throws -> ISAEngineProfileReceipt {
    let tierEvidence = resolveTierEvidence(
      declaredTier: configuration.tier, observedTier: machine.executionTier)

    let startHost = DispatchTime.now()
    let startSample = sample(
      from: machine,
      configuration: configuration,
      workloadName: workloadName,
      workloadRevision: workloadRevision,
      wallTimeNanoseconds: 0,
      translationCacheMaximumBytes: translationCacheMaximumBytes)

    let result: ISAEngineRunResult
    var wallTimeQuantum: UInt64? = nil
    var deadlineBetweenQuanta: Bool? = nil
    switch completionCondition {
    case .instructionBudget(let count):
      let stop = try machine.run(
        maximumInstructions: count, exceptionPolicy: exceptionPolicy)
      result = ISAEngineRunResult(stop)
    case .poweredOff, .halted:
      let stop = try machine.run(
        maximumInstructions: maximumInstructionBudget,
        exceptionPolicy: exceptionPolicy)
      result = ISAEngineRunResult(stop)
    case .wallTimeBudget(let seconds):
      // Conservative bounded instruction quantum: the deadline is
      // observed only between quanta, so real-time overshoot is bounded
      // by one quantum of wallTimeChunkInstructions.
      wallTimeQuantum = wallTimeChunkInstructions
      deadlineBetweenQuanta = true
      let deadline = startHost.uptimeNanoseconds &+ seconds &* 1_000_000_000
      var stop: DoryPCMachineStop = .instructionBudget(0)
      while DispatchTime.now().uptimeNanoseconds < deadline {
        stop = try machine.run(
          maximumInstructions: wallTimeChunkInstructions,
          exceptionPolicy: exceptionPolicy)
        if case .instructionBudget = stop { continue }
        break
      }
      if DispatchTime.now().uptimeNanoseconds >= deadline {
        result = .wallTimeBudget
      } else {
        result = ISAEngineRunResult(stop)
      }
    }

    let endHost = DispatchTime.now()
    let wallTime = endHost.uptimeNanoseconds &- startHost.uptimeNanoseconds
    let endSample = sample(
      from: machine,
      configuration: configuration,
      workloadName: workloadName,
      workloadRevision: workloadRevision,
      wallTimeNanoseconds: wallTime,
      translationCacheMaximumBytes: translationCacheMaximumBytes)
    let hostTiming = ISAEngineHostTiming(
      startNanoseconds: startHost.uptimeNanoseconds,
      endNanoseconds: endHost.uptimeNanoseconds)

    // Capture host execution diagnostics (wall and thread-CPU split)
    // when the machine supplies them.  Device/RPC stages are explicitly
    // unavailable for this direct-machine boundary.
    let hostDiag = ISAEngineHostExecutionDiagnosticsSnapshot(
      machine.hostExecutionDiagnostics)

    return build(
      configuration: configuration,
      workloadName: workloadName,
      workloadRevision: workloadRevision,
      completionCondition: completionCondition,
      startSample: startSample,
      endSample: endSample,
      hostTiming: hostTiming,
      result: result,
      observedTierEvidence: tierEvidence,
      hostExecutionDiagnostics: hostDiag,
      deviceRPCStagesAvailable: false,
      wallTimeInstructionQuantum: wallTimeQuantum,
      deadlineObservedBetweenQuanta: deadlineBetweenQuanta)
  }

  // MARK: - Tier evidence

  /// Map a declared profile tier string to the concrete
  /// `DoryPCExecutionTier` it claims, then validate it against the
  /// machine's observed tier.
  static func resolveTierEvidence(
    declaredTier: String,
    observedTier: DoryPCExecutionTier
  ) -> ISAEngineTierEvidence {
    let expected: DoryPCExecutionTier?
    switch declaredTier {
    case "interpreter": expected = .interpreter
    case "Tier1", "Tier1-direct-only": expected = .baselineJIT
    case "Tier2": expected = .optimizingJIT
    default: expected = nil
    }
    if let expected, expected == observedTier {
      return .verified(observedTier: observedTier)
    }
    return .mismatch(declaredTier: declaredTier, observedTier: observedTier)
  }

  // MARK: - Private

  /// Map the machine's public `DoryPCJITCacheStatistics` snapshot to a
  /// profile sample.  The field mapping mirrors `ISAEngineProfiler.sample`
  /// for `DoryARM64BaselineExecutorDiagnostics`; `DoryPCJITCacheStatistics`
  /// aggregates the same counters across vCPUs and exposes them publicly,
  /// so this reads them verbatim without synthesis.
  private static func sampleFromJITCacheStatistics(
    _ jit: DoryPCJITCacheStatistics,
    configuration: ISAEngineProfileConfiguration,
    workloadName: String,
    workloadRevision: String,
    wallTimeNanoseconds: UInt64,
    retiredGuestInstructions: UInt64,
    translationCacheMaximumBytes: UInt64
  ) -> ISAEngineProfileSample {
    ISAEngineProfileSample(
      configuration: configuration,
      workloadName: workloadName,
      workloadRevision: workloadRevision,
      wallTimeNanoseconds: wallTimeNanoseconds,
      retiredGuestInstructions: retiredGuestInstructions,
      compilationTimeNanoseconds: 0,
      compilationAttempts: jit.compiledBlocks,
      compilationDeclines: jit.declinedCompilations,
      translationCacheEntryCount: jit.translationCacheEntryCount,
      translationCacheAllocatedBytes: jit.translationCacheAllocatedBytes,
      translationCacheMaximumBytes: translationCacheMaximumBytes,
      translationCacheHits: jit.translationCacheHits,
      translationCacheMisses: jit.translationCacheMisses,
      translationCacheInvalidations: jit.translationCacheInvalidations,
      tier1DeclineInterpreterHelper: jit.confirmedInterpreterFallback?.retiredInstructions(for: .interpreterHelper) ?? 0,
      tier1DeclineNativeEmitter: jit.confirmedInterpreterFallback?.retiredInstructions(for: .nativeEmitter) ?? 0,
      tier1CompiledBlocks: jit.tier1CompiledBlocks,
      tier1CompilationAttempts: jit.tier1CompilationAttempts,
      tier1CompilationDeclines: jit.tier1CompilationDeclines,
      nativeDispatcherEntries: jit.nativeDispatcherEntries,
      directlyChainedBlocks: jit.directlyChainedBlocks,
      chainTargetAttempts: jit.chainTargetAttempts,
      chainTargetAccepts: jit.chainTargetAccepts,
      indirectBranchTargetCacheHits: jit.indirectBranchTargetCacheHits,
      indirectBranchTargetCacheMisses: jit.indirectBranchTargetCacheMisses,
      shadowReturnStackHits: jit.shadowReturnStackHits,
      shadowReturnStackMisses: jit.shadowReturnStackMisses,
      // The direct-machine JIT diagnostics API does not expose a separate
      // helper-call counter.  Lazy flag materializations are tracked as
      // their own distinct counter below; they must not be double-counted
      // as helper calls.
      helperCalls: 0,
      memoryFaultSlowPaths: jit.translationCachePageFaults,
      lazyFlagMaterializations: jit.lazyFlagMaterializations,
      codeCacheWraps: jit.codeCacheWraps,
      codeCacheEvictedBlocks: jit.codeCacheEvictedBlocks,
      negativeCacheHits: jit.negativeCacheHits,
      negativeCacheMisses: jit.negativeCacheMisses,
      pendingWorkExits: jit.pendingWorkExits,
      confirmedInterpreterFallback: jit.confirmedInterpreterFallback)
  }

  private static func matches(
    _ condition: ISAEngineCompletionCondition,
    _ result: ISAEngineRunResult
  ) -> Bool {
    switch (condition, result) {
    case (.poweredOff, .poweredOff): true
    case (.halted, .halted): true
    case (.instructionBudget(let expected), .instructionBudget(let actual)): expected == actual
    case (.wallTimeBudget, .wallTimeBudget): true
    default: false
    }
  }
}
