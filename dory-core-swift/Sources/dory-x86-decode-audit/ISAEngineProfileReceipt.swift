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
  /// typically zero for a freshly constructed machine.
  public let startSample: ISAEngineProfileSample
  /// Engine snapshot captured at the live-run boundary after the run
  /// ends.  The `wallTimeNanoseconds` field of this sample carries the
  /// host-timing wall time so any cost report derived from the receipt
  /// reflects the real run duration.
  public let endSample: ISAEngineProfileSample
  public let hostTiming: ISAEngineHostTiming
  /// Human-readable stop reason translated from the machine's native
  /// stop type.
  public let stopReason: String

  public init(
    configuration: ISAEngineProfileConfiguration,
    workloadName: String,
    workloadRevision: String,
    completionCondition: ISAEngineCompletionCondition,
    outcome: ISAEngineReceiptOutcome,
    startSample: ISAEngineProfileSample,
    endSample: ISAEngineProfileSample,
    hostTiming: ISAEngineHostTiming,
    stopReason: String
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
  }

  /// True only when the run reached its declared completion condition.
  public var isCompleted: Bool { outcome == .completed }
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
    result: ISAEngineRunResult
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
      stopReason: result.description)
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
  /// - For `.instructionBudget(n)` the machine is run with that budget.
  /// - For `.poweredOff` or `.halted` the machine is run with
  ///   `maximumInstructionBudget`; an exhausted budget yields a `.stopped`
  ///   receipt because the declared condition was not reached.
  /// - For `.wallTimeBudget(seconds)` the machine is run in bounded chunks
  ///   until the wall-time deadline elapses (`.timeout`) or the machine
  ///   stops for another reason.
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
    let startHost = DispatchTime.now()
    let startSample = sample(
      from: machine,
      configuration: configuration,
      workloadName: workloadName,
      workloadRevision: workloadRevision,
      wallTimeNanoseconds: 0,
      translationCacheMaximumBytes: translationCacheMaximumBytes)

    let result: ISAEngineRunResult
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
    return build(
      configuration: configuration,
      workloadName: workloadName,
      workloadRevision: workloadRevision,
      completionCondition: completionCondition,
      startSample: startSample,
      endSample: endSample,
      hostTiming: hostTiming,
      result: result)
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
      tier1DeclineInterpreterHelper: jit.negativeCacheMisses,
      tier1DeclineNativeEmitter: jit.declinedCompilations,
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
      helperCalls: jit.lazyFlagMaterializations,
      memoryFaultSlowPaths: jit.translationCachePageFaults,
      lazyFlagMaterializations: jit.lazyFlagMaterializations,
      codeCacheWraps: jit.codeCacheWraps,
      codeCacheEvictedBlocks: jit.codeCacheEvictedBlocks,
      negativeCacheHits: jit.negativeCacheHits,
      negativeCacheMisses: jit.negativeCacheMisses,
      pendingWorkExits: jit.pendingWorkExits)
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
