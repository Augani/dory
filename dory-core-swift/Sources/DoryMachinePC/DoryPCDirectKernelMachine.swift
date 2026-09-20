import Dispatch
import DoryDBTX86
import DoryPlatformC
import Foundation

/// Device callbacks may hold their own locks. This leaf lock never calls a device or acquires the
/// machine execution lock. Its synchronous closures may only publish or clear native atomic poll
/// bytes, coupling those bytes to the wake generation without a lost-clear window.
final class DoryPCPendingWorkWake: @unchecked Sendable {
  struct Snapshot: Sendable, Equatable {
    fileprivate let generations: [UInt64]
  }

  private let condition = NSCondition()
  private var generations: [UInt64]
  private var waiting: [Bool]
  private var coordinatorWaiting = false
  private var dispatchThreads: [Thread?]

  init(processorCount: Int = 1) {
    precondition(processorCount > 0)
    generations = .init(repeating: 0, count: processorCount)
    waiting = .init(repeating: false, count: processorCount)
    dispatchThreads = .init(repeating: nil, count: processorCount)
  }

  /// Marks every vCPU as synchronously dispatched by `thread`. The serialized fallback scheduler
  /// uses this while draining all controllers on the coordinator.
  func setDispatchThread(_ thread: Thread?) {
    condition.lock()
    dispatchThreads = .init(repeating: thread, count: dispatchThreads.count)
    condition.unlock()
  }

  /// Marks one vCPU as synchronously dispatched by `thread`. A publication for another vCPU is
  /// still asynchronous and must advance that target's generation.
  func setDispatchThread(_ thread: Thread?, forProcessor processor: Int) {
    condition.lock()
    precondition(dispatchThreads.indices.contains(processor))
    dispatchThreads[processor] = thread
    condition.unlock()
  }

  func snapshot() -> Snapshot {
    condition.withLock { Snapshot(generations: generations) }
  }

  func snapshot(forProcessor processor: Int) -> UInt64 {
    condition.lock()
    defer { condition.unlock() }
    precondition(generations.indices.contains(processor))
    return generations[processor]
  }

  func signal(forProcessor processor: Int, publishing publication: () -> Void) {
    condition.lock()
    precondition(generations.indices.contains(processor))
    publication()
    // Synchronous device work is already owned by this dispatch pass. In particular PIC
    // acknowledgement republishes masked requests: treating that as an asynchronous edge
    // would spin forever on an undeliverable IRQ (and advance deterministic time).
    if dispatchThreads[processor] !== Thread.current {
      generations[processor] = nextGeneration(after: generations[processor])
      condition.broadcast()
    }
    condition.unlock()
  }

  /// Publishes one shared edge to every vCPU that is not currently draining on this thread. A
  /// worker may consume its own synchronous controller callback without hiding the same request
  /// from remote workers.
  func signalAll(publishing publication: () -> Void) {
    condition.lock()
    publication()
    var changed = false
    for processor in generations.indices where dispatchThreads[processor] !== Thread.current {
      generations[processor] = nextGeneration(after: generations[processor])
      changed = true
    }
    if changed { condition.broadcast() }
    condition.unlock()
  }

  /// Clears native poll bytes only if no asynchronous edge was published after `observed`.
  /// Publication and acknowledgement use the same lock, so either the clear happens first and a
  /// later publisher restores the byte, or the publication happens first and the clear declines.
  @discardableResult
  func acknowledge(
    forProcessor processor: Int,
    after observed: UInt64,
    clearing clear: () -> Void
  ) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    precondition(generations.indices.contains(processor))
    guard generations[processor] == observed else { return false }
    clear()
    return true
  }

  /// Acknowledges the unchanged parts of a coordinator snapshot independently. Returning `false`
  /// means at least one target raced the drain; unchanged targets are still safely cleared.
  @discardableResult
  func acknowledge(after observed: Snapshot, clearing clear: (Int) -> Void) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    precondition(observed.generations.count == generations.count)
    var complete = true
    for processor in generations.indices {
      guard generations[processor] == observed.generations[processor] else {
        complete = false
        continue
      }
      clear(processor)
    }
    return complete
  }

  func wait(forProcessor processor: Int, after observed: UInt64, until deadline: Date) {
    condition.lock()
    defer {
      waiting[processor] = false
      condition.unlock()
    }
    precondition(generations.indices.contains(processor))
    // Compare with the generation captured BEFORE dispatch drained the controllers. An edge
    // between that drain and this wait must force another pass, even if its signal came early.
    while generations[processor] == observed {
      waiting[processor] = true
      condition.broadcast()
      if !condition.wait(until: deadline) { break }
    }
  }

  func wait(after observed: Snapshot, until deadline: Date) {
    condition.lock()
    defer {
      coordinatorWaiting = false
      condition.unlock()
    }
    precondition(observed.generations.count == generations.count)
    while generations == observed.generations {
      coordinatorWaiting = true
      condition.broadcast()
      if !condition.wait(until: deadline) { break }
    }
  }

  // Internal synchronization for production-boundary tests; no callbacks run under either lock.
  func waitUntilWaiting(until deadline: Date) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    while !coordinatorWaiting && !waiting.contains(true) {
      if !condition.wait(until: deadline) {
        return coordinatorWaiting || waiting.contains(true)
      }
    }
    return true
  }

  private func nextGeneration(after generation: UInt64) -> UInt64 {
    generation == .max ? 1 : generation + 1
  }
}

/// One vCPU's last architecturally published paging invalidation. Each worker owns one cursor;
/// the lock also permits quiescent diagnostics and the serialized fallback scheduler to inspect it
/// without relying on concurrent mutation of Swift Array storage.
final class DoryPCPagingInvalidationCursor: @unchecked Sendable {
  private let lock = NSLock()
  private var sequence: UInt64 = 0

  func load() -> UInt64 { lock.withLock { sequence } }

  func store(_ sequence: UInt64) { lock.withLock { self.sequence = sequence } }
}

public enum DoryPCMachineError: Error, Sendable, Equatable {
  case invalidMemorySize(Int)
  case invalidProcessorCount(Int)
  case invalidTSCFrequency(UInt64)
  case alreadyLoaded
  case notLoaded
  case invalidBootRange
  case bootArtifactOutsideRAM
  case overlappingBootArtifacts
}

public enum DoryPCExecutionTier: String, Codable, Sendable, Hashable {
  case interpreter
  case baselineJIT
  case optimizingJIT
}

/// Selects the source of guest machine time without changing the DoryPC-v1 clock frequencies.
/// Deterministic time is reserved for conformance, replay, and unit tests. Product UEFI machines
/// use host-monotonic time so a slow translated CPU cannot also make firmware timers run slowly.
public struct DoryPCClockSource: Sendable {
  fileprivate let monotonicNanoseconds: (@Sendable () -> UInt64)?
  fileprivate let discontinuityGeneration: @Sendable () -> UInt32

  public static let deterministic = Self(
    monotonicNanoseconds: nil,
    discontinuityGeneration: { 0 }
  )
  public static let hostMonotonic = Self(
    monotonicNanoseconds: { DispatchTime.now().uptimeNanoseconds },
    discontinuityGeneration: { dory_sigcont_generation() }
  )

  /// Injectable host-monotonic source for clock conformance tests. Values that move backwards are
  /// ignored; production uses `hostMonotonic`.
  public static func hostMonotonic(
    _ monotonicNanoseconds: @escaping @Sendable () -> UInt64,
    discontinuityGeneration: @escaping @Sendable () -> UInt32 = { 0 }
  ) -> Self {
    Self(
      monotonicNanoseconds: monotonicNanoseconds,
      discontinuityGeneration: discontinuityGeneration
    )
  }

  private init(
    monotonicNanoseconds: (@Sendable () -> UInt64)?,
    discontinuityGeneration: @escaping @Sendable () -> UInt32
  ) {
    self.monotonicNanoseconds = monotonicNanoseconds
    self.discontinuityGeneration = discontinuityGeneration
  }

  /// Installs the process-wide SIGCONT generation marker used to exclude explicit VM suspension
  /// from host-monotonic guest time. DoryPC runners host exactly one VM per process.
  public static func installProcessResumeTracking() -> Bool {
    dory_install_sigcont_generation_tracker() == 0
  }
}

public struct DoryPCExecutionStatistics: Codable, Sendable, Hashable {
  public struct InterruptVectorCount: Codable, Sendable, Hashable {
    public let vector: UInt8
    public let deliveries: UInt64

    public init(vector: UInt8, deliveries: UInt64) {
      self.vector = vector
      self.deliveries = deliveries
    }
  }

  public let interpreterInstructions: UInt64
  public let baselineJITInstructions: UInt64
  public let baselineJITBlocks: UInt64
  public let optimizingJITInstructions: UInt64
  public let optimizingJITBlocks: UInt64
  public let deliveredMaskableInterrupts: UInt64
  public let deliveredNonMaskableInterrupts: UInt64
  public let retiredInterruptReturns: UInt64
  public let deliveredInterruptVectors: [InterruptVectorCount]

  public init(
    interpreterInstructions: UInt64,
    baselineJITInstructions: UInt64,
    baselineJITBlocks: UInt64,
    optimizingJITInstructions: UInt64,
    optimizingJITBlocks: UInt64,
    deliveredMaskableInterrupts: UInt64 = 0,
    deliveredNonMaskableInterrupts: UInt64 = 0,
    retiredInterruptReturns: UInt64 = 0,
    deliveredInterruptVectors: [InterruptVectorCount] = []
  ) {
    self.interpreterInstructions = interpreterInstructions
    self.baselineJITInstructions = baselineJITInstructions
    self.baselineJITBlocks = baselineJITBlocks
    self.optimizingJITInstructions = optimizingJITInstructions
    self.optimizingJITBlocks = optimizingJITBlocks
    self.deliveredMaskableInterrupts = deliveredMaskableInterrupts
    self.deliveredNonMaskableInterrupts = deliveredNonMaskableInterrupts
    self.retiredInterruptReturns = retiredInterruptReturns
    self.deliveredInterruptVectors = deliveredInterruptVectors
  }

  private enum CodingKeys: String, CodingKey {
    case interpreterInstructions
    case baselineJITInstructions
    case baselineJITBlocks
    case optimizingJITInstructions
    case optimizingJITBlocks
    case deliveredMaskableInterrupts
    case deliveredNonMaskableInterrupts
    case retiredInterruptReturns
    case deliveredInterruptVectors
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      interpreterInstructions: try container.decode(UInt64.self, forKey: .interpreterInstructions),
      baselineJITInstructions: try container.decode(UInt64.self, forKey: .baselineJITInstructions),
      baselineJITBlocks: try container.decode(UInt64.self, forKey: .baselineJITBlocks),
      optimizingJITInstructions: try container.decode(
        UInt64.self, forKey: .optimizingJITInstructions),
      optimizingJITBlocks: try container.decode(UInt64.self, forKey: .optimizingJITBlocks),
      deliveredMaskableInterrupts: try container.decodeIfPresent(
        UInt64.self,
        forKey: .deliveredMaskableInterrupts
      ) ?? 0,
      deliveredNonMaskableInterrupts: try container.decodeIfPresent(
        UInt64.self,
        forKey: .deliveredNonMaskableInterrupts
      ) ?? 0,
      retiredInterruptReturns: try container.decodeIfPresent(
        UInt64.self,
        forKey: .retiredInterruptReturns
      ) ?? 0,
      deliveredInterruptVectors: try container.decodeIfPresent(
        [InterruptVectorCount].self,
        forKey: .deliveredInterruptVectors
      ) ?? []
    )
  }
}

/// Timer-origin interrupt requests. Counts are captured at the device source, before controller
/// coalescing or guest interrupt masking, so they remain distinct from delivered vector totals.
public struct DoryPCTimerInterruptDiagnostics: Sendable, Hashable {
  public let localAPICRequests: [UInt64]
  public let pitRequests: UInt64
  public let rtcRequests: UInt64
  public let hpetRequests: [UInt64]

  public var totalRequests: UInt64 {
    (localAPICRequests + [pitRequests, rtcRequests] + hpetRequests).reduce(0) { partial, value in
      let (sum, overflow) = partial.addingReportingOverflow(value)
      return overflow ? .max : sum
    }
  }
}

public struct DoryPCHostTimeBreakdown: Sendable, Hashable {
  public let totalNanoseconds: UInt64
  public let processorEventNanoseconds: UInt64
  public let clockAdvancementNanoseconds: UInt64
  public let interruptDeliveryNanoseconds: UInt64
  public let processorExecutionNanoseconds: UInt64
  public let idleWaitNanoseconds: UInt64

  public var attributedNanoseconds: UInt64 {
    [
      processorEventNanoseconds, clockAdvancementNanoseconds,
      interruptDeliveryNanoseconds, processorExecutionNanoseconds, idleWaitNanoseconds,
    ].reduce(0, saturatingSum)
  }

  public var unattributedNanoseconds: UInt64 {
    totalNanoseconds > attributedNanoseconds ? totalNanoseconds - attributedNanoseconds : 0
  }

  public var attributedBasisPoints: UInt64 {
    guard totalNanoseconds > 0 else { return 0 }
    let boundedAttributed = min(attributedNanoseconds, totalNanoseconds)
    return totalNanoseconds.dividingFullWidth(
      boundedAttributed.multipliedFullWidth(by: 10_000)
    ).quotient
  }

  private func saturatingSum(_ partial: UInt64, _ value: UInt64) -> UInt64 {
    let (sum, overflow) = partial.addingReportingOverflow(value)
    return overflow ? .max : sum
  }
}

/// Opt-in host timing for the coordinated machine run loop. Wall time measures elapsed time;
/// threadCPU aggregates coordinator and worker CPU time and can exceed wall time during overlap.
public struct DoryPCHostExecutionDiagnostics: Sendable, Hashable {
  public let enabled: Bool
  public let runCalls: UInt64
  public let wall: DoryPCHostTimeBreakdown
  public let threadCPU: DoryPCHostTimeBreakdown
}

public struct DoryPCJITCacheStatistics: Sendable, Hashable {
  public let recentLookupHits: UInt64
  public let blockCacheLookupHits: UInt64
  public let dictionaryLookupHits: UInt64
  public let lookupMisses: UInt64
  public let memoryGenerationHits: UInt64
  public let byteValidationHits: UInt64
  public let sharedCodeHits: UInt64
  public let compiledBlocks: UInt64
  public let optimizingCompilationAttempts: UInt64
  public let lookupVisibleOptimizedBlocks: UInt64
  public let lookupVisibleChangedOptimizedBlocks: UInt64
  public let publishedPropagatedConstants: UInt64
  public let publishedEliminatedStatements: UInt64
  public let tier1CompilationAttempts: UInt64
  public let tier1CompilationDeclines: UInt64
  public let tier1CompiledBlocks: UInt64
  public let lazyFlagMaterializations: UInt64
  public let declinedCompilations: UInt64
  public let negativeCacheHits: UInt64
  public let negativeCacheMisses: UInt64
  public let negativeGenerationMismatches: UInt64
  public let negativeEntryCount: UInt64
  public let negativeCacheHotSites: [DoryPCJITNegativeCacheHotSite]
  public let confirmedInterpreterFallback: DoryARM64InterpreterFallbackCounters?
  public let codeCacheWraps: UInt64
  public let codeCacheEvictedBlocks: UInt64
  public let nativeTraceAttempts: UInt64
  public let nativeTraceReplays: UInt64
  public let codeGenerationChecks: UInt64
  public let codeGenerationMismatches: UInt64
  public let chainedExecutionCalls: UInt64
  public let chainedRequestedInstructions: UInt64
  public let chainedRetiredInstructions: UInt64
  public let pendingWorkExits: UInt64
  public let pendingWorkMaximumRetiredInstructions: UInt64
  public let nativeDispatcherEntries: UInt64
  public let directChainPatches: UInt64
  public let directChainUnlinks: UInt64
  public let directlyChainedBlocks: UInt64
  public let chainTargetAttempts: UInt64
  public let chainTargetAccepts: UInt64
  public let chainTargetSourceShapeRejections: UInt64
  public let chainTargetBoundaryRejections: UInt64
  public let chainTargetRestartableWriterRejections: UInt64
  public let chainTargetMissingMemoryRejections: UInt64
  public let chainTargetInterpreterGuardRejections: UInt64
  public let chainTargetCompilerABIRejections: UInt64
  public let chainTargetPublicationRejections: UInt64
  public let indirectBranchTargetCacheHits: UInt64
  public let indirectBranchTargetCacheMisses: UInt64
  public let indirectBranchTargetCacheFills: UInt64
  public let indirectBranchTargetCacheHitRate: Double
  public let shadowReturnStackHits: UInt64
  public let shadowReturnStackMisses: UInt64
  public let shadowReturnStackPushes: UInt64
  public let shadowReturnStackHitRate: Double
  public let translationCacheEntryCount: UInt64
  public let translationCacheAllocatedBytes: UInt64
  public let translationCacheAddressSpaceGeneration: UInt64
  public let translationCacheInvalidations: UInt64
  public let translationCacheHits: UInt64
  public let translationCacheMisses: UInt64
  public let translationCacheFills: UInt64
  public let translationCachePageFaults: UInt64
  public let translationCacheFallbacks: UInt64
  public let translationCacheHitRate: Double

  fileprivate init(_ source: DoryARM64BaselineExecutorDiagnostics) {
    self.init([source])
  }

  fileprivate init(_ sources: [DoryARM64BaselineExecutorDiagnostics]) {
    precondition(!sources.isEmpty)
    func sum(_ keyPath: KeyPath<DoryARM64BaselineExecutorDiagnostics, UInt64>) -> UInt64 {
      sources.reduce(0) { partial, source in
        let addition = partial.addingReportingOverflow(source[keyPath: keyPath])
        return addition.overflow ? .max : addition.partialValue
      }
    }
    recentLookupHits = sum(\.recentLookupHits)
    blockCacheLookupHits = sum(\.blockCacheLookupHits)
    dictionaryLookupHits = sum(\.dictionaryLookupHits)
    lookupMisses = sum(\.lookupMisses)
    memoryGenerationHits = sum(\.memoryGenerationHits)
    byteValidationHits = sum(\.byteValidationHits)
    sharedCodeHits = sum(\.sharedCodeHits)
    compiledBlocks = sum(\.compiledBlocks)
    optimizingCompilationAttempts = sum(\.optimizingCompilationAttempts)
    lookupVisibleOptimizedBlocks = sum(\.lookupVisibleOptimizedBlocks)
    lookupVisibleChangedOptimizedBlocks = sum(\.lookupVisibleChangedOptimizedBlocks)
    publishedPropagatedConstants = sum(\.publishedPropagatedConstants)
    publishedEliminatedStatements = sum(\.publishedEliminatedStatements)
    tier1CompilationAttempts = sum(\.tier1CompilationAttempts)
    tier1CompilationDeclines = sum(\.tier1CompilationDeclines)
    tier1CompiledBlocks = sum(\.tier1CompiledBlocks)
    lazyFlagMaterializations = sum(\.lazyFlagMaterializations)
    declinedCompilations = sum(\.declinedCompilations)
    negativeCacheHits = sum(\.negativeCacheHits)
    negativeCacheMisses = sum(\.negativeCacheMisses)
    negativeGenerationMismatches = sum(\.negativeGenerationMismatches)
    negativeEntryCount = sum(\.negativeEntryCount)
    let fallbackSources = sources.compactMap(\.confirmedInterpreterFallback)
    confirmedInterpreterFallback =
      fallbackSources.count == sources.count
      ? .init(work: fallbackSources.flatMap(\.work)) : nil
    negativeCacheHotSites = Array(
      sources.flatMap(\.negativeCacheHotSites)
        .sorted { lhs, rhs in
          if lhs.hitCount != rhs.hitCount { return lhs.hitCount > rhs.hitCount }
          return lhs.guestRIP < rhs.guestRIP
        }
        .prefix(16)
        .map(DoryPCJITNegativeCacheHotSite.init)
    )
    codeCacheWraps = sum(\.codeCacheWraps)
    codeCacheEvictedBlocks = sum(\.codeCacheEvictedBlocks)
    nativeTraceAttempts = sum(\.nativeTraceAttempts)
    nativeTraceReplays = sum(\.nativeTraceReplays)
    codeGenerationChecks = sum(\.codeGenerationChecks)
    codeGenerationMismatches = sum(\.codeGenerationMismatches)
    chainedExecutionCalls = sum(\.chainedExecutionCalls)
    chainedRequestedInstructions = sum(\.chainedRequestedInstructions)
    chainedRetiredInstructions = sum(\.chainedRetiredInstructions)
    pendingWorkExits = sum(\.pendingWorkExits)
    pendingWorkMaximumRetiredInstructions =
      sources.map(\.pendingWorkMaximumRetiredInstructions).max() ?? 0
    nativeDispatcherEntries = sum(\.nativeDispatcherEntries)
    directChainPatches = sum(\.directChainPatches)
    directChainUnlinks = sum(\.directChainUnlinks)
    directlyChainedBlocks = sum(\.directlyChainedBlocks)
    chainTargetAttempts = sum(\.chainTargetAttempts)
    chainTargetAccepts = sum(\.chainTargetAccepts)
    chainTargetSourceShapeRejections = sum(\.chainTargetSourceShapeRejections)
    chainTargetBoundaryRejections = sum(\.chainTargetBoundaryRejections)
    chainTargetRestartableWriterRejections = sum(\.chainTargetRestartableWriterRejections)
    chainTargetMissingMemoryRejections = sum(\.chainTargetMissingMemoryRejections)
    chainTargetInterpreterGuardRejections = sum(\.chainTargetInterpreterGuardRejections)
    chainTargetCompilerABIRejections = sum(\.chainTargetCompilerABIRejections)
    chainTargetPublicationRejections = sum(\.chainTargetPublicationRejections)
    indirectBranchTargetCacheHits = sum(\.indirectBranchTargetCacheHits)
    indirectBranchTargetCacheMisses = sum(\.indirectBranchTargetCacheMisses)
    indirectBranchTargetCacheFills = sum(\.indirectBranchTargetCacheFills)
    let indirectLookups = indirectBranchTargetCacheHits.addingReportingOverflow(
      indirectBranchTargetCacheMisses)
    let indirectDenominator = indirectLookups.overflow ? UInt64.max : indirectLookups.partialValue
    indirectBranchTargetCacheHitRate =
      indirectDenominator == 0
      ? 0 : Double(indirectBranchTargetCacheHits) / Double(indirectDenominator)
    shadowReturnStackHits = sum(\.shadowReturnStackHits)
    shadowReturnStackMisses = sum(\.shadowReturnStackMisses)
    shadowReturnStackPushes = sum(\.shadowReturnStackPushes)
    let shadowLookups = shadowReturnStackHits.addingReportingOverflow(shadowReturnStackMisses)
    let shadowDenominator = shadowLookups.overflow ? UInt64.max : shadowLookups.partialValue
    shadowReturnStackHitRate =
      shadowDenominator == 0
      ? 0 : Double(shadowReturnStackHits) / Double(shadowDenominator)
    translationCacheEntryCount = sum(\.translationCacheEntryCount)
    translationCacheAllocatedBytes = sum(\.translationCacheAllocatedBytes)
    translationCacheAddressSpaceGeneration =
      sources.map(\.translationCacheAddressSpaceGeneration)
      .max() ?? 0
    translationCacheInvalidations = sum(\.translationCacheInvalidations)
    translationCacheHits = sum(\.translationCacheHits)
    translationCacheMisses = sum(\.translationCacheMisses)
    translationCacheFills = sum(\.translationCacheFills)
    translationCachePageFaults = sum(\.translationCachePageFaults)
    translationCacheFallbacks = sum(\.translationCacheFallbacks)
    let lookupCount = translationCacheHits.addingReportingOverflow(translationCacheMisses)
    let denominator = lookupCount.overflow ? UInt64.max : lookupCount.partialValue
    translationCacheHitRate =
      denominator == 0 ? 0 : Double(translationCacheHits) / Double(denominator)
  }
}

public struct DoryPCJITNegativeCacheHotSite: Sendable, Hashable {
  public let guestRIP: UInt64
  public let executionMode: DoryX86ExecutionMode
  public let instructionBudget: Int
  public let addressSpaceID: UInt64
  public let privilegeLevel: UInt8
  public let pagingEnabled: Bool
  public let guestByteCount: Int
  public let instructionBytes: [UInt8]
  public let declineReason: DoryARM64CompilationDeclineReason
  public let hitCount: UInt64

  fileprivate init(_ source: DoryARM64NegativeCacheHotSite) {
    guestRIP = source.guestRIP
    executionMode = source.executionMode
    instructionBudget = source.instructionBudget
    addressSpaceID = source.addressSpaceID
    privilegeLevel = source.privilegeLevel
    pagingEnabled = source.pagingEnabled
    guestByteCount = source.guestByteCount
    instructionBytes = source.instructionBytes
    declineReason = source.declineReason
    hitCount = source.hitCount
  }
}

public struct DoryPCProcessorExecutionSnapshot: Sendable, Hashable {
  public let index: Int
  public let lifecycle: DoryPCProcessorLifecycle
  public let isHalted: Bool
  public let state: DoryX86ArchitecturalState?
  public let executionMode: DoryX86ExecutionMode?
  public let privilegeLevel: UInt8?

  public init(
    index: Int,
    lifecycle: DoryPCProcessorLifecycle,
    isHalted: Bool,
    state: DoryX86ArchitecturalState?,
    executionMode: DoryX86ExecutionMode? = nil,
    privilegeLevel: UInt8? = nil
  ) {
    self.index = index
    self.lifecycle = lifecycle
    self.isHalted = isHalted
    self.state = state
    self.executionMode = executionMode
    self.privilegeLevel = privilegeLevel
  }
}

public struct DoryPCTripleFaultExceptionEvidence: Sendable, Hashable {
  public let exception: DoryX86Exception
  public let processor: Int
  public let executionMode: DoryX86ExecutionMode
  public let state: DoryX86ArchitecturalState
  public let instructionBytes: [UInt8]

  public init(
    exception: DoryX86Exception,
    processor: Int,
    executionMode: DoryX86ExecutionMode,
    state: DoryX86ArchitecturalState,
    instructionBytes: [UInt8]
  ) {
    self.exception = exception
    self.processor = processor
    self.executionMode = executionMode
    self.state = state
    self.instructionBytes = instructionBytes
  }
}

public enum DoryPCTripleFaultSource: Sendable, Hashable {
  case exception(DoryPCTripleFaultExceptionEvidence)
  case interrupt(vector: UInt8, source: DoryX86InterruptSource, processor: Int)
}

public enum DoryPCMachineStop: Sendable, Hashable {
  case halted(instructionCount: UInt64)
  case exception(DoryX86Exception, instructionCount: UInt64)
  case tripleFault(source: DoryPCTripleFaultSource, instructionCount: UInt64)
  case poweredOff(instructionCount: UInt64)
  case reset(instructionCount: UInt64)
  case instructionBudget(UInt64)
}

public enum DoryPCExceptionPolicy: Sendable, Hashable {
  /// Debugger/conformance mode: expose the first precise CPU exception to the caller.
  case stop
  /// Product mode: enter the guest IDT, including architectural double/triple-fault escalation.
  case deliver
}

/// Deterministic direct-kernel DoryPC machine shared by interpreter and translated execution tiers.
public final class DoryPCDirectKernelMachine: @unchecked Sendable {
  /// Raw host-address prediction is an explicit engineering experiment. Exact-candidate PVH
  /// repeats have reproduced non-returning native slices with both the combined configuration and
  /// tier-one direct chaining; production execution therefore keeps every raw predictor disabled.
  public static let defaultRawTargetPredictionOptions: DoryARM64RawTargetPredictionOptions = []

  private enum HostTimeCategory {
    case processorEvent
    case clockAdvancement
    case interruptDelivery
    case processorExecution
    case idleWait
  }

  private struct HostTimeSample {
    let wallNanoseconds: UInt64
    let threadCPUNanoseconds: UInt64
  }

  private struct HostTimeAccumulator {
    var totalNanoseconds: UInt64 = 0
    var processorEventNanoseconds: UInt64 = 0
    var clockAdvancementNanoseconds: UInt64 = 0
    var interruptDeliveryNanoseconds: UInt64 = 0
    var processorExecutionNanoseconds: UInt64 = 0
    var idleWaitNanoseconds: UInt64 = 0

    var snapshot: DoryPCHostTimeBreakdown {
      .init(
        totalNanoseconds: totalNanoseconds,
        processorEventNanoseconds: processorEventNanoseconds,
        clockAdvancementNanoseconds: clockAdvancementNanoseconds,
        interruptDeliveryNanoseconds: interruptDeliveryNanoseconds,
        processorExecutionNanoseconds: processorExecutionNanoseconds,
        idleWaitNanoseconds: idleWaitNanoseconds
      )
    }
  }

  private final class RunBudgetMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var maximumInstructions: UInt64?

    func publish(_ maximumInstructions: UInt64) {
      precondition(maximumInstructions > 0)
      lock.withLock {
        precondition(self.maximumInstructions == nil)
        self.maximumInstructions = maximumInstructions
      }
    }

    func consume() throws -> UInt64 {
      try lock.withLock {
        guard let maximumInstructions else { throw WorkerError.missingRunBudget }
        self.maximumInstructions = nil
        return maximumInstructions
      }
    }
  }

  private final class RunFailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: (any Error)?

    func store(_ failure: any Error) {
      lock.withLock {
        if self.failure == nil { self.failure = failure }
      }
    }

    var storedFailure: (any Error)? {
      lock.withLock { failure }
    }
  }

  private struct WorkerBoundaryService {
    let acknowledgedPendingWorkGeneration: UInt64
    let tripleFault: DoryPCTripleFaultSource?
    let eventCPUNanoseconds: UInt64
  }

  // A worker exclusively borrows its processor's state during a job. In the run-session path it
  // also owns that processor's lifecycle mailbox, interrupt delivery, and translation
  // acknowledgement. The coordinator may access architectural state only after completion.
  // Legacy multi-vCPU slices retain the older rendezvous until every worker has this boundary.
  // A parallel native job borrows only its own executor, with no guest-memory authority.
  final class ProcessorState: @unchecked Sendable {
    var value: DoryX86ArchitecturalState

    init(_ value: DoryX86ArchitecturalState) {
      self.value = value
    }
  }

  private struct JITHotnessEntry {
    var tag: UInt64 = 0
    var dispatchCount: UInt8 = 0
  }

  /// Mutable state with one architectural owner. Keeping every vCPU's control flags, hotness
  /// table, and interrupt counters in a distinct reference object avoids concurrent mutation of
  /// shared Swift collection storage when the multi-worker run loop is admitted. During a run,
  /// only this processor's worker may mutate its slot; the coordinator reads slots only after the
  /// workers have rendezvoused at an exact result or quiescence boundary.
  private final class ProcessorSlot: @unchecked Sendable {
    var state: ProcessorState?
    var isHalted = false
    var lifecycle: DoryPCProcessorLifecycle
    var hasPendingNMI = false
    var jitHotness = [JITHotnessEntry](repeating: .init(), count: 1 << 16)
    var deliveredMaskableInterrupts: UInt64 = 0
    var deliveredNonMaskableInterrupts: UInt64 = 0
    var retiredInterruptReturns: UInt64 = 0
    var deliveredInterruptVectors: [UInt8: UInt64] = [:]

    init(lifecycle: DoryPCProcessorLifecycle) {
      self.lifecycle = lifecycle
    }
  }

  public let memory: any DoryX86PhysicalRAM
  public let physicalMemory: DoryPCPhysicalMemoryBus
  public let physicalMemories: [DoryPCPhysicalMemoryBus]
  public let ioBus: DoryPCPortIOBus
  public let serial: DoryPCUART16550
  public let ps2Keyboard: DoryPCPS2KeyboardController
  public let localAPIC: DoryPCLocalAPIC
  public let localAPICs: [DoryPCLocalAPIC]
  public let multiprocessorController: DoryPCMultiprocessorController
  public let ioAPIC: DoryPCIOAPIC
  public let legacyPIC: DoryPCPIC8259Pair
  public let legacyPIT: DoryPCPIT8254
  public let systemControlPort: DoryPCSystemControlPortB
  public let rtc: DoryPCRTC146818
  public let hpet: DoryPCHPET
  public let pciExpress: DoryPCPCIExpressECAM
  public let pciBARWindow: DoryPCPCIBARWindow
  public let powerController: DoryPCPowerController
  public let pagingUnit: DoryX86PagingUnit
  public let pagingUnits: [DoryX86PagingUnit]
  /// Serialization authority shared by every vCPU execution engine in this machine.
  /// A distinct machine receives a distinct coordinator unless its caller explicitly shares one.
  public let atomicCoordinator: DoryX86AtomicCoordinator
  public let interpreter: DoryX86Interpreter
  public let interpreters: [DoryX86Interpreter]
  public let bootLayout: DoryPCPVHBootLayout
  public let acpiLayout: DoryPCACPILayout
  public let smbios: DoryPCSMBIOSTables
  public let firmwareConfiguration: DoryPCFirmwareConfiguration
  public let platformMMIODevices: [any DoryPCMMIODevice]
  public let memoryByteCount: Int
  /// Base of the guest-physical-shaped host reservation supplied to generated code.
  public let hostAddressSpaceBase: UInt64
  public let hostAddressSpaceByteCount: Int
  public let processorCount: Int
  public let executionTier: DoryPCExecutionTier
  public let jitWriteCoherencePolicy: DoryX86JITWriteCoherencePolicy

  private let lock = DoryPCExecutionGate()
  /// Persistent host threads owned for the complete machine lifetime. Public `run` calls borrow
  /// them through the execution gate and must rendezvous every submitted slice before returning.
  private let vcpuRuntime: DoryPCVCPURuntime
  private let pendingWorkWake: DoryPCPendingWorkWake
  private let translationInvalidationCoordinator: DoryPCTranslationInvalidationCoordinator
  // `run` reserves the execution gate while transferring ownership to dedicated workers.
  // No mutex remains held during guest execution. Observability must not
  // contend for that lock: a lifecycle telemetry request is served on another queue while the VM
  // is executing and would otherwise wait until the full quantum retired (or deadlock its socket
  // deadline). Publish an immutable snapshot after every quantum under a dedicated short lock.
  private let executionStatisticsLock = NSLock()
  private let hostExecutionDiagnosticsLock = NSLock()
  private let processorSlots: [ProcessorSlot]
  private var roundRobinCursor = 0
  private var runGeneration: UInt64 = 0
  private var consumedPayload = false
  private let baselineJITs: [DoryARM64BaselineExecutor]
  private let optimizingJITs: [DoryARM64BaselineExecutor]
  private let optimizingJITWarmupDispatches: UInt8
  private let translatedMemories: [DoryX86TranslatedMemory]
  private let reconciledPagingInvalidationSequences: [DoryPCPagingInvalidationCursor]
  private var interpreterInstructionCount: UInt64 = 0
  private var baselineJITInstructionCount: UInt64 = 0
  private var baselineJITBlockCount: UInt64 = 0
  private var optimizingJITInstructionCount: UInt64 = 0
  private var optimizingJITBlockCount: UInt64 = 0
  private var publishedExecutionStatistics = DoryPCExecutionStatistics(
    interpreterInstructions: 0,
    baselineJITInstructions: 0,
    baselineJITBlocks: 0,
    optimizingJITInstructions: 0,
    optimizingJITBlocks: 0
  )
  private let instrumentationEnabled: Bool
  private var hostTimeRunCalls: UInt64 = 0
  private var hostWallTime = HostTimeAccumulator()
  private var hostThreadCPUTime = HostTimeAccumulator()
  private var publishedHostExecutionDiagnostics = DoryPCHostExecutionDiagnostics(
    enabled: false,
    runCalls: 0,
    wall: .init(
      totalNanoseconds: 0,
      processorEventNanoseconds: 0,
      clockAdvancementNanoseconds: 0,
      interruptDeliveryNanoseconds: 0,
      processorExecutionNanoseconds: 0,
      idleWaitNanoseconds: 0
    ),
    threadCPU: .init(
      totalNanoseconds: 0,
      processorEventNanoseconds: 0,
      clockAdvancementNanoseconds: 0,
      interruptDeliveryNanoseconds: 0,
      processorExecutionNanoseconds: 0,
      idleWaitNanoseconds: 0
    )
  )
  private var pitClockRemainder: UInt64 = 0
  private var rtcClockRemainder: UInt64 = 0
  private var localAPICClockRemainder: UInt64 = 0
  private var pmTimerClockRemainder: UInt64 = 0
  private var tscClockRemainder: UInt64 = 0
  private let clockSource: DoryPCClockSource
  private var lastHostClockNanoseconds: UInt64?
  private var hostClockNanosecondRemainder: UInt64 = 0
  private var hostClockDiscontinuityGeneration: UInt32?

  // HPET exposes a 100 ns period, so one deterministic machine-clock tick is 100 ns. Keeping the
  // execution tiers on this shared timebase preserves the selected CPU's TSC rate
  // while the PIT, RTC, and ACPI PM timer receive their independent oscillator rates.
  private static let machineClockFrequencyHz: UInt64 = 10_000_000
  private static let localAPICClockFrequencyHz: UInt64 = 1_000_000_000
  private static let pitFrequencyHz: UInt64 = 1_193_182

  public init(
    memoryBytes: Int,
    processorCount: Int = 1,
    bootLayout: DoryPCPVHBootLayout = .init(),
    acpiLayout: DoryPCACPILayout = .init(),
    smbiosLayout: DoryPCSMBIOSLayout = .init(),
    smbiosIdentity: DoryPCSMBIOSIdentity = .init(),
    initialRTCDate: Date = Date(),
    firmwareConfigurationFlags: DoryPCFirmwareConfiguration.Flags = [],
    pciFunctions: [any DoryPCPCIFunction] = [],
    platformMMIODevices: [any DoryPCMMIODevice] = [],
    interpreter: DoryX86Interpreter = .init(),
    executionTier: DoryPCExecutionTier = .interpreter,
    baselineJITMaximumCodeBytes: Int = DoryARM64BaselineExecutor.defaultMaximumCodeBytes,
    baselineJITTier1Enabled: Bool = true,
    baselineJITRawTargetPredictionOptions: DoryARM64RawTargetPredictionOptions =
      DoryPCDirectKernelMachine.defaultRawTargetPredictionOptions,
    jitWriteCoherencePolicy: DoryX86JITWriteCoherencePolicy = .protectedHostPages,
    optimizingJITWarmupDispatches: UInt8 = 8,
    clockSource: DoryPCClockSource = .deterministic,
    instrumentationEnabled: Bool = false
  ) throws {
    // Validate the frozen physical address map before any JIT construction or RAM
    // allocation so a malformed ABI layout fails during admission rather than after
    // resources are committed. The ABI error propagates directly per PC convention.
    try DoryPCV1ABI.validateRegions()
    guard memoryBytes >= 1024 * 1024,
      memoryBytes % (1024 * 1024) == 0,
      UInt64(memoryBytes) <= DoryPCV1ABI.maximumMemoryBytes
    else {
      throw DoryPCMachineError.invalidMemorySize(memoryBytes)
    }
    guard (1...255).contains(processorCount) else {
      throw DoryPCMachineError.invalidProcessorCount(processorCount)
    }
    guard (32...52).contains(interpreter.profile.physicalAddressBits) else {
      throw DoryX86StateError.invalidPhysicalAddressBits(interpreter.profile.physicalAddressBits)
    }
    guard interpreter.profile.virtualTSCFrequencyHz > 0 else {
      throw DoryPCMachineError.invalidTSCFrequency(interpreter.profile.virtualTSCFrequencyHz)
    }
    let machineAtomicCoordinator = interpreter.atomicCoordinator
    self.processorCount = processorCount
    self.executionTier = executionTier
    self.jitWriteCoherencePolicy = jitWriteCoherencePolicy
    atomicCoordinator = machineAtomicCoordinator
    self.optimizingJITWarmupDispatches = optimizingJITWarmupDispatches
    self.clockSource = clockSource
    self.instrumentationEnabled = instrumentationEnabled
    vcpuRuntime = DoryPCVCPURuntime(
      processorCount: processorCount,
      instrumentationEnabled: instrumentationEnabled
    )
    pendingWorkWake = .init(processorCount: processorCount)
    translationInvalidationCoordinator = .init(processorCount: processorCount)
    reconciledPagingInvalidationSequences = (0..<processorCount).map { _ in
      DoryPCPagingInvalidationCursor()
    }
    publishedHostExecutionDiagnostics = .init(
      enabled: instrumentationEnabled,
      runCalls: 0,
      wall: hostWallTime.snapshot,
      threadCPU: hostThreadCPUTime.snapshot
    )
    let baselineCodeBytes =
      executionTier == .optimizingJIT
      ? max(4_096, baselineJITMaximumCodeBytes / 4)
      : baselineJITMaximumCodeBytes
    let perProcessorBaselineCodeBytes = max(4_096, baselineCodeBytes / processorCount)
    let createdBaselineJITs: [DoryARM64BaselineExecutor] =
      switch executionTier {
      case .interpreter:
        []
      case .baselineJIT, .optimizingJIT:
        try (0..<processorCount).map { _ in
          try DoryARM64BaselineExecutor(
            maximumCodeBytes: perProcessorBaselineCodeBytes,
            decoder: interpreter.decoder,
            cpuProfileIdentifier: interpreter.profile.identifier,
            physicalAddressBits: interpreter.profile.physicalAddressBits,
            profile: interpreter.profile,
            tier1Enabled: baselineJITTier1Enabled,
            rawTargetPredictionOptions: baselineJITRawTargetPredictionOptions,
            optimization: .baseline,
            tracksInterpreterFallback: true,
            atomicCoordinator: machineAtomicCoordinator
          )
        }
      }
    baselineJITs = createdBaselineJITs
    let optimizingCodeBytes = max(4_096, baselineJITMaximumCodeBytes * 3 / 4)
    let perProcessorOptimizingCodeBytes = max(4_096, optimizingCodeBytes / processorCount)
    let createdOptimizingJITs: [DoryARM64BaselineExecutor] =
      switch executionTier {
      case .interpreter, .baselineJIT:
        []
      case .optimizingJIT:
        try (0..<processorCount).map { _ in
          try DoryARM64BaselineExecutor(
            maximumCodeBytes: perProcessorOptimizingCodeBytes,
            decoder: interpreter.decoder,
            cpuProfileIdentifier: interpreter.profile.identifier,
            physicalAddressBits: interpreter.profile.physicalAddressBits,
            profile: interpreter.profile,
            rawTargetPredictionOptions: baselineJITRawTargetPredictionOptions,
            optimization: .optimizing,
            tracksInterpreterFallback: true,
            atomicCoordinator: machineAtomicCoordinator
          )
        }
      }
    optimizingJITs = createdOptimizingJITs
    firmwareConfiguration = DoryPCFirmwareConfiguration(
      totalRAMBytes: UInt64(memoryBytes),
      processorCount: processorCount,
      flags: firmwareConfigurationFlags,
      acpiRSDPAddress: acpiLayout.rsdp,
      smbiosEntryAddress: smbiosLayout.entryPoint
    )
    self.platformMMIODevices = [firmwareConfiguration] + platformMMIODevices
    // Physical machines need a recoverable host allocation boundary at every size.
    // Swift Array allocation traps on exhaustion; byte-array RAM remains a conformance fixture.
    let ramByteCount = UInt64(memoryBytes)
    let lowRAMByteCount = min(ramByteCount, DoryPCV1ABI.mmioHoleStart)
    let highRAMByteCount = ramByteCount - lowRAMByteCount
    var ramMappings = [
      DoryX86MmapRAMMapping(
        logicalOffset: 0,
        hostOffset: 0,
        byteCount: Int(lowRAMByteCount)
      )
    ]
    if highRAMByteCount > 0 {
      ramMappings.append(
        .init(
          logicalOffset: Int(DoryPCV1ABI.mmioHoleStart),
          hostOffset: Int(DoryPCV1ABI.above4GRAMStart),
          byteCount: Int(highRAMByteCount)
        ))
    }
    let readOnlyMappings: [DoryX86MmapReadOnlyMapping] = platformMMIODevices.compactMap { device in
      guard let flash = device as? DoryPCFirmwareFlash else { return nil }
      return DoryX86MmapReadOnlyMapping(
        hostOffset: Int(flash.baseAddress),
        byteCount: Int(flash.byteCount),
        contents: flash.image,
        contentsOffset: Int(flash.imageOffset),
        fillByte: 0xff
      )
    }
    let sharedMemory = try DoryX86MmapMemory(
      validatingByteCount: memoryBytes,
      hostAddressSpaceByteCount: Int(
        DoryPCV1ABI.guestPhysicalAddressSpaceBytes(memoryBytes: ramByteCount)),
      ramMappings: ramMappings,
      readOnlyMappings: readOnlyMappings
    )
    memory = sharedMemory
    hostAddressSpaceBase = sharedMemory.hostAddressSpaceBase
    hostAddressSpaceByteCount = sharedMemory.hostAddressSpaceByteCount
    physicalMemories = try (0..<processorCount).map {
      _ in
      try DoryPCPhysicalMemoryBus(ram: sharedMemory, diagnosticsEnabled: instrumentationEnabled)
    }
    physicalMemory = physicalMemories[0]
    memoryByteCount = memoryBytes
    ioBus = DoryPCPortIOBus()
    let requestPendingWorkForProcessor: @Sendable (Int) -> Void = {
      [createdBaselineJITs, createdOptimizingJITs, pendingWorkWake] processor in
      pendingWorkWake.signal(forProcessor: processor) {
        if createdBaselineJITs.indices.contains(processor) {
          createdBaselineJITs[processor].requestPendingWork()
        }
        if createdOptimizingJITs.indices.contains(processor) {
          createdOptimizingJITs[processor].requestPendingWork()
        }
      }
    }
    let requestPendingWorkForAllProcessors: @Sendable () -> Void = {
      [createdBaselineJITs, createdOptimizingJITs, pendingWorkWake] in
      pendingWorkWake.signalAll {
        for jit in createdBaselineJITs { jit.requestPendingWork() }
        for jit in createdOptimizingJITs { jit.requestPendingWork() }
      }
    }
    localAPICs = (0..<processorCount).map { processor in
      DoryPCLocalAPIC(
        apicID: UInt32(processor),
        diagnosticsEnabled: instrumentationEnabled,
        onPendingWork: { requestPendingWorkForProcessor(processor) }
      )
    }
    localAPIC = localAPICs[0]
    multiprocessorController = try .init(
      localAPICs: localAPICs,
      onPendingWork: { requestPendingWorkForProcessor(Int($0)) }
    )
    ioAPIC = DoryPCIOAPIC()
    for apic in localAPICs { try ioAPIC.attach(apic) }
    ioAPIC.seal()
    legacyPIC = DoryPCPIC8259Pair(onPendingWork: requestPendingWorkForAllProcessors)
    legacyPIT = DoryPCPIT8254(diagnosticsEnabled: instrumentationEnabled) { [legacyPIC, ioAPIC] in
      try? legacyPIC.raise(irq: 0)
      try? ioAPIC.setAsserted(true, pin: 2)
      try? ioAPIC.setAsserted(false, pin: 2)
    }
    systemControlPort = DoryPCSystemControlPortB(pit: legacyPIT)
    serial = DoryPCUART16550()
    serial.connectInterruptSink { [legacyPIC, ioAPIC] asserted in
      try? legacyPIC.setAsserted(asserted, irq: 4)
      try? ioAPIC.setAsserted(asserted, pin: 4)
    }
    ps2Keyboard = DoryPCPS2KeyboardController()
    ps2Keyboard.connectInterruptSink { [legacyPIC, ioAPIC] asserted in
      try? legacyPIC.setAsserted(asserted, irq: 1)
      try? ioAPIC.setAsserted(asserted, pin: 1)
    }
    rtc = DoryPCRTC146818(
      initialDate: initialRTCDate,
      diagnosticsEnabled: instrumentationEnabled
    )
    rtc.connectInterruptSink { [legacyPIC, ioAPIC] asserted in
      try? legacyPIC.setAsserted(asserted, irq: 8)
      try? ioAPIC.setAsserted(asserted, pin: 8)
    }
    hpet = DoryPCHPET(diagnosticsEnabled: instrumentationEnabled) {
      [legacyPIC, ioAPIC] _, route, asserted in
      if case .legacyIRQ(let irq) = route { try? legacyPIC.setAsserted(asserted, irq: irq) }
      try? ioAPIC.setAsserted(asserted, pin: Self.ioAPICPin(forHPETRoute: route))
    }
    pciExpress = DoryPCPCIExpressECAM()
    pciBARWindow = DoryPCPCIBARWindow()
    powerController = DoryPCPowerController(onPendingWork: requestPendingWorkForAllProcessors)
    let intxRouter = DoryPCPCIINTxRouter(ioAPIC: ioAPIC)
    for function in pciFunctions {
      try pciExpress.attach(function)
      if let barDevice = function as? any DoryPCPCIBARMemoryDevice {
        try pciBARWindow.attach(barDevice)
      }
      if let msiFunction = function as? any DoryPCPCIMSIControllable {
        msiFunction.connectMSISink { [localAPICs] address, data in
          guard let message = DoryPCPCIMSIMessage.decode(address: address, data: data),
            let target = localAPICs.first(where: { $0.apicID == message.destinationAPICID })
          else { return false }
          do {
            try target.inject(vector: message.vector)
            return true
          } catch {
            return false
          }
        }
      }
      if let intxFunction = function as? any DoryPCPCIINTxControllable {
        let source = ObjectIdentifier(intxFunction)
        intxFunction.connectINTxSink { [intxRouter] line, asserted in
          intxRouter.setAsserted(asserted, line: Int(line), source: source)
        }
      }
      if let memoryConsumer = function as? any DoryPCVirtioGuestMemoryConsumer {
        memoryConsumer.connectGuestMemory(physicalMemory)
      }
    }
    pciExpress.seal()
    pciBARWindow.seal()
    try ioBus.attach(DoryPCPIC8259Port(pair: legacyPIC, slave: false))
    try ioBus.attach(DoryPCPIC8259Port(pair: legacyPIC, slave: true))
    try ioBus.attach(DoryPCELCRPort(pic: legacyPIC))
    try ioBus.attach(legacyPIT)
    try ioBus.attach(systemControlPort)
    try ioBus.attach(DoryPCPS2KeyboardDataPort(controller: ps2Keyboard))
    try ioBus.attach(DoryPCPS2KeyboardStatusPort(controller: ps2Keyboard))
    try ioBus.attach(rtc)
    try ioBus.attach(serial)
    try ioBus.attach(DoryPCACPIPMEventPort(controller: powerController))
    try ioBus.attach(DoryPCACPIPMControlPort(controller: powerController))
    try ioBus.attach(DoryPCACPMPMTimerPort(controller: powerController))
    try ioBus.attach(DoryPCResetControlPort(controller: powerController))
    ioBus.seal()
    for (index, bus) in physicalMemories.enumerated() {
      let apic = localAPICs[index]
      try bus.attach(
        DoryPCLocalAPICMMIO(
          apic: apic,
          onEndOfInterrupt: { [ioAPIC] vector in
            try ioAPIC.endOfInterrupt(vector: vector, destinationAPICID: apic.apicID)
          },
          onInterruptCommand: { [multiprocessorController] high, low in
            try multiprocessorController.handleInterruptCommand(
              sourceAPICID: apic.apicID,
              high: high,
              low: low
            )
          }
        ))
      try bus.attach(DoryPCIOAPICMMIO(ioAPIC: ioAPIC))
      try bus.attach(hpet)
      try bus.attach(pciExpress)
      try bus.attach(pciBARWindow)
      for device in self.platformMMIODevices { try bus.attach(device) }
      bus.seal()
    }
    pagingUnits = (0..<processorCount).map { _ in
      DoryX86PagingUnit(
        physicalAddressBits: interpreter.profile.physicalAddressBits,
        diagnosticsEnabled: instrumentationEnabled
      )
    }
    pagingUnit = pagingUnits[0]
    translatedMemories = zip(physicalMemories, pagingUnits).map { physicalMemory, pagingUnit in
      DoryX86TranslatedMemory(
        physicalMemory: physicalMemory,
        pagingUnit: pagingUnit,
        context: .init(state: .reset(), mode: .real16, profile: interpreter.profile),
        jitWriteCoherencePolicy: jitWriteCoherencePolicy
      )
    }
    interpreters = (0..<processorCount).map {
      DoryX86Interpreter(
        profile: interpreter.profile,
        decoder: interpreter.decoder,
        processorID: UInt32($0),
        logicalProcessorCount: UInt16(processorCount),
        atomicCoordinator: machineAtomicCoordinator
      )
    }
    self.interpreter = interpreters[0]
    self.bootLayout = bootLayout
    self.acpiLayout = acpiLayout
    smbios = try DoryPCSMBIOSBuilder.build(
      layout: smbiosLayout,
      identity: smbiosIdentity,
      processorCount: processorCount,
      memoryBytes: memoryBytes,
      cpuProfile: interpreter.profile
    )
    processorSlots = (0..<processorCount).map {
      ProcessorSlot(lifecycle: $0 == 0 ? .running : .waitingForStartup)
    }
  }

  public func load(
    kernel: Data,
    initrd: [UInt8] = [],
    commandLine: String = "console=ttyS0 earlycon=uart,io,0x3f8,115200 panic=-1"
  ) throws {
    try lock.withLock {
      guard !consumedPayload else { throw DoryPCMachineError.alreadyLoaded }
      let kernelImage = try DoryPCPVHKernelImage(data: kernel)
      let acpi = try DoryPCACPIBuilder.build(
        layout: acpiLayout,
        processorCount: UInt8(processorCount)
      )
      let memoryMap = try DoryPCPVHBootBuilder.memoryMap(memoryBytes: UInt64(memoryByteCount))
      let bootImage = try DoryPCPVHBootBuilder.build(
        commandLine: commandLine,
        initrd: initrd,
        memoryMap: memoryMap,
        layout: bootLayout,
        rsdpPhysicalAddress: acpiLayout.rsdp
      )
      let initialState = try bootImage.initialState(entryPoint: kernelImage.physicalEntryPoint)
      try initialState.control.validateLegacyPAEPDPTEs(
        physicalAddressBits: interpreter.profile.physicalAddressBits
      )
      try validateDirectBoot(
        kernel: kernelImage, boot: bootImage, acpi: acpi, memoryMap: memoryMap
      )
      // All static layout and memory-authority rejection happens before any write or
      // consumption. An unexpected failure during installation remains non-retryable.
      consumedPayload = true
      try kernelImage.load(into: physicalMemory)
      try bootImage.install(into: physicalMemory)
      try acpi.install(into: physicalMemory)
      try smbios.install(into: physicalMemory)
      processorSlots[0].state = ProcessorState(initialState)
      for index in 1..<processorCount {
        processorSlots[index].state = ProcessorState(applicationProcessorResetState())
      }
      for slot in processorSlots { slot.isHalted = false }
    }
  }

  private func validateDirectBoot(
    kernel: DoryPCPVHKernelImage,
    boot: DoryPCPVHBootImage,
    acpi: DoryPCACPITables,
    memoryMap: [DoryPCMemoryMapEntry]
  ) throws {
    // The deterministic kernel-in-RAM and kernel/boot/reserved-overlap checks run first, before
    // any machine-specific DMA validation or RAM write. Preflight reuses the parsed artifacts so
    // the admission boundary is shared with callers that plan before constructing a machine.
    let preflight = try DoryPCBootPreflight.validate(
      kernel: kernel, boot: boot, memoryMap: memoryMap
    )
    func range(_ address: UInt64, _ count: UInt64) throws -> Range<UInt64> {
      let (end, overflow) = address.addingReportingOverflow(count)
      guard count > 0, count <= UInt64(Int.max), !overflow else {
        throw DoryPCMachineError.invalidBootRange
      }
      return address..<end
    }
    // ACPI and SMBIOS tables are planned by the machine after preflight because SMBIOS content
    // depends on the CPU profile. Their ranges join the kernel/boot ranges for the full overlap
    // and DMA checks that the RAM-backed physical memory bus must accept.
    let tables: [(UInt64, [UInt8])] = [
      (acpi.layout.rsdp, acpi.rsdp), (acpi.layout.xsdt, acpi.xsdt),
      (acpi.layout.madt, acpi.madt), (acpi.layout.hpet, acpi.hpet),
      (acpi.layout.mcfg, acpi.mcfg), (acpi.layout.fadt, acpi.fadt),
      (acpi.layout.facs, acpi.facs), (acpi.layout.dsdt, acpi.dsdt),
      (smbios.layout.entryPoint, smbios.entryPoint),
      (smbios.layout.structureTable, smbios.structureTable),
    ]
    let tableRanges = try tables.filter { !$0.1.isEmpty }.map {
      try range($0.0, UInt64($0.1.count))
    }
    let artifactRanges = preflight.bootArtifactRanges + tableRanges
    // Preserve the legacy first page and the explicitly supplied initial stack.
    let ranges = (preflight.kernelRanges + artifactRanges + [0..<0x1000, 0x7000..<0x8000])
      .sorted { $0.lowerBound < $1.lowerBound }
    guard !zip(ranges, ranges.dropFirst()).contains(where: { $0.0.overlaps($0.1) }) else {
      throw DoryPCMachineError.overlappingBootArtifacts
    }
    for item in preflight.kernelRanges + artifactRanges {
      // RAM-only validation rejects writable MMIO overlays as well as ROM, holes
      // and unmapped addresses; preflight cannot trigger a device write.
      try physicalMemory.validateDMA(
        at: item.lowerBound, byteCount: Int(item.count), deviceWillWrite: true
      )
    }
    try kernel.validate(into: physicalMemory)
    try boot.validate(into: physicalMemory)
  }

  /// Installs firmware discovery tables and enters the architectural x86 reset state. Firmware
  /// code must already be attached as an instruction-fetchable platform MMIO device.
  public func loadUEFI() throws {
    try lock.withLock {
      guard !consumedPayload else { throw DoryPCMachineError.alreadyLoaded }
      let initialState = DoryX86ArchitecturalState.reset()
      try initialState.control.validateLegacyPAEPDPTEs(
        physicalAddressBits: interpreter.profile.physicalAddressBits
      )
      let acpi = try DoryPCACPIBuilder.build(
        layout: acpiLayout,
        processorCount: UInt8(processorCount)
      )
      _ = try physicalMemory.instructionBytes(
        at: DoryPCV1ABI.uefiResetAddress,
        maximumCount: 1
      )
      // Combined ACPI/SMBIOS admission runs before any table write and before
      // consumedPayload changes so a custom SMBIOS range overlapping an ACPI
      // range is rejected atomically with the full firmware-table layout.
      try validateUEFITableLayout(acpi: acpi)
      consumedPayload = true
      do {
        try acpi.install(into: memory)
        try smbios.install(into: memory)
      } catch {
        throw error
      }
      processorSlots[0].state = ProcessorState(initialState)
      for index in 1..<processorCount {
        processorSlots[index].state = ProcessorState(applicationProcessorResetState())
      }
      for slot in processorSlots { slot.isHalted = false }
    }
  }

  /// Combined ACPI/SMBIOS table admission for UEFI boot. Every write range selected by
  /// the ACPI and SMBIOS layouts is collected and validated before any guest-RAM write
  /// or payload-consumption state change. Ranges must be non-empty, guest-RAM writable,
  /// and mutually non-overlapping across both table families, so a custom SMBIOS
  /// entry-point range that overlaps an ACPI range is rejected atomically instead of
  /// silently corrupting guest firmware discovery.
  private func validateUEFITableLayout(acpi: DoryPCACPITables) throws {
    func range(_ address: UInt64, _ count: UInt64) throws -> Range<UInt64> {
      let (end, overflow) = address.addingReportingOverflow(count)
      guard count > 0, count <= UInt64(Int.max), !overflow else {
        throw DoryPCMachineError.invalidBootRange
      }
      return address..<end
    }
    let tables: [(UInt64, [UInt8])] = [
      (acpi.layout.rsdp, acpi.rsdp), (acpi.layout.xsdt, acpi.xsdt),
      (acpi.layout.madt, acpi.madt), (acpi.layout.hpet, acpi.hpet),
      (acpi.layout.mcfg, acpi.mcfg), (acpi.layout.fadt, acpi.fadt),
      (acpi.layout.facs, acpi.facs), (acpi.layout.dsdt, acpi.dsdt),
      (smbios.layout.entryPoint, smbios.entryPoint),
      (smbios.layout.structureTable, smbios.structureTable),
    ]
    let tableRanges = try tables.filter { !$0.1.isEmpty }.map {
      try range($0.0, UInt64($0.1.count))
    }
    let ranges = tableRanges.sorted { $0.lowerBound < $1.lowerBound }
    guard !zip(ranges, ranges.dropFirst()).contains(where: { $0.0.overlaps($0.1) }) else {
      throw DoryPCMachineError.overlappingBootArtifacts
    }
    for item in tableRanges {
      // RAM-only validation rejects writable MMIO overlays as well as ROM, holes
      // and unmapped addresses; preflight cannot trigger a device write.
      try physicalMemory.validateDMA(
        at: item.lowerBound, byteCount: Int(item.count), deviceWillWrite: true
      )
    }
  }

  public var state: DoryX86ArchitecturalState? { state(forProcessor: 0) }

  public var executionStatistics: DoryPCExecutionStatistics {
    executionStatisticsLock.withLock { publishedExecutionStatistics }
  }

  public var baselineJITDiagnostics: DoryPCJITCacheStatistics? {
    baselineJITs.isEmpty ? nil : .init(baselineJITs.map(\.diagnostics))
  }

  public var optimizingJITDiagnostics: DoryPCJITCacheStatistics? {
    optimizingJITs.isEmpty ? nil : .init(optimizingJITs.map(\.diagnostics))
  }

  public var pagingDiagnostics: [DoryX86PagingDiagnostics] {
    pagingUnits.map(\.diagnostics)
  }

  public var timerInterruptDiagnostics: DoryPCTimerInterruptDiagnostics {
    .init(
      localAPICRequests: localAPICs.map(\.timerInterruptRequests),
      pitRequests: legacyPIT.timerInterruptRequests,
      rtcRequests: rtc.timerInterruptRequests,
      hpetRequests: hpet.timerInterruptRequests
    )
  }

  public var hostExecutionDiagnostics: DoryPCHostExecutionDiagnostics {
    hostExecutionDiagnosticsLock.withLock { publishedHostExecutionDiagnostics }
  }

  public func state(forProcessor index: Int) -> DoryX86ArchitecturalState? {
    lock.withLock {
      processorSlots.indices.contains(index) ? processorSlots[index].state?.value : nil
    }
  }

  public var processorExecutionSnapshots: [DoryPCProcessorExecutionSnapshot] {
    lock.withLock {
      processorSlots.indices.map { index in
        let slot = processorSlots[index]
        let state = slot.state?.value
        let mode = state.map { executionMode($0) }
        let privilegeLevel = state.flatMap { state in
          mode.map { currentPrivilegeLevel(state, mode: $0) }
        }
        return .init(
          index: index,
          lifecycle: slot.lifecycle,
          isHalted: slot.isHalted,
          state: state,
          executionMode: mode,
          privilegeLevel: privilegeLevel
        )
      }
    }
  }

  /// Reads instruction bytes through the processor's current linear-address translation. This is
  /// intended for precise diagnostics: callers must not treat `CS.base + RIP` as a physical
  /// address once paging is active.
  public func instructionBytes(
    forProcessor index: Int = 0,
    maximumCount: Int = 16
  ) throws -> [UInt8]? {
    guard maximumCount > 0 else { return [] }
    return try lock.withLock {
      guard processorSlots.indices.contains(index), let state = processorSlots[index].state?.value
      else {
        return nil
      }
      let translatedMemory = translatedMemories[index]
      translatedMemory.updateContext(
        .init(state: state, mode: executionMode(state), profile: interpreter.profile))
      return try translatedMemory.instructionBytes(
        at: state.cs.base &+ state.rip,
        maximumCount: maximumCount
      )
    }
  }

  /// Reads diagnostic data through the processor's current linear-address translation.
  public func memoryBytes(
    forProcessor index: Int = 0,
    atLinearAddress address: UInt64,
    maximumCount: Int
  ) throws -> [UInt8]? {
    guard maximumCount > 0 else { return [] }
    return try lock.withLock {
      guard processorSlots.indices.contains(index), let state = processorSlots[index].state?.value
      else {
        return nil
      }
      let translatedMemory = translatedMemories[index]
      translatedMemory.updateContext(
        .init(state: state, mode: executionMode(state), profile: interpreter.profile))
      return try translatedMemory.read(at: address, byteCount: maximumCount)
    }
  }

  public func run(
    maximumInstructions: UInt64,
    exceptionPolicy: DoryPCExceptionPolicy = .stop
  ) throws -> DoryPCMachineStop {
    guard maximumInstructions > 0 else { return .instructionBudget(0) }
    return try lock.withLock {
      guard processorSlots[0].state != nil else { throw DoryPCMachineError.notLoaded }
      pendingWorkWake.setDispatchThread(Thread.current)
      defer { pendingWorkWake.setDispatchThread(nil) }
      // Validate installed latches before consuming device events, advancing clocks, or
      // entering either execution tier. Guest RAM is not a substitute for latched state.
      for slot in processorSlots {
        try slot.state?.value.control.validateLegacyPAEPDPTEs(
          physicalAddressBits: interpreter.profile.physicalAddressBits
        )
      }
      let observer = workerObserver
      let workers = vcpuRuntime.workers
      let runTimeSample = hostTimeSample()
      defer {
        // Every submitted job has completed before control can reach a return/throw below. Consume
        // per-run CPU deltas without terminating the machine-owned worker threads.
        for (processor, worker) in workers.enumerated() {
          let cpuTime = worker.consumeCPUTime()
          saturatingAdd(cpuTime.executionNanoseconds, to: &hostThreadCPUTime.totalNanoseconds)
          saturatingAdd(cpuTime.eventNanoseconds, to: &hostThreadCPUTime.totalNanoseconds)
          saturatingAdd(
            cpuTime.executionNanoseconds, to: &hostThreadCPUTime.processorExecutionNanoseconds)
          saturatingAdd(
            cpuTime.eventNanoseconds, to: &hostThreadCPUTime.processorEventNanoseconds)
          // Retain the existing observation boundary: "stopped" means this run no longer lends
          // architectural state to the worker, not that its persistent host thread was destroyed.
          observer?(.stopped(processor))
        }
        recordTotalHostTime(since: runTimeSample)
        for memory in physicalMemories { memory.publishDiagnostics() }
        publishExecutionStatistics()
        publishHostExecutionDiagnostics()
      }
      if processorCount == 1 {
        return try runSingleProcessorSession(
          maximumInstructions: maximumInstructions,
          exceptionPolicy: exceptionPolicy,
          observer: observer,
          worker: workers[0]
        )
      }
      var completed: UInt64 = 0
      while completed < maximumInstructions {
        reconcilePendingPageTableWrites()
        let pendingWorkGeneration = pendingWorkWake.snapshot()
        if let stop = powerStop(instructionCount: completed) { return stop }
        if instrumentationEnabled {
          let sample = hostTimeSample()
          applyProcessorEvents()
          recordHostTime(.processorEvent, since: sample)
        } else {
          applyProcessorEvents()
        }
        if instrumentationEnabled {
          let sample = hostTimeSample()
          if clockSource.monotonicNanoseconds != nil {
            synchronizeHostClock()
          } else {
            // Deterministic conformance time advances with retired work and remains identical across
            // interpreter and JIT tiers. Product UEFI execution never uses this policy.
            advanceClocks(by: 1)
          }
          recordHostTime(.clockAdvancement, since: sample)
        } else {
          if clockSource.monotonicNanoseconds != nil {
            synchronizeHostClock()
          } else {
            advanceClocks(by: 1)
          }
        }
        let interruptStop: DoryPCMachineStop?
        if instrumentationEnabled {
          let sample = hostTimeSample()
          interruptStop = try deliverPendingInterrupts(instructionCount: completed)
          recordHostTime(.interruptDelivery, since: sample)
        } else {
          interruptStop = try deliverPendingInterrupts(instructionCount: completed)
        }
        if let interruptStop { return interruptStop }
        // Couple the native poll-byte clear to the generation captured before the drain. An edge
        // racing this boundary either prevents the clear or republishes the byte after it.
        let acknowledgedPendingWork = pendingWorkWake.acknowledge(
          after: pendingWorkGeneration
        ) { processor in
          if baselineJITs.indices.contains(processor) {
            baselineJITs[processor].clearPendingWork()
          }
          if optimizingJITs.indices.contains(processor) {
            optimizingJITs[processor].clearPendingWork()
          }
        }
        if !acknowledgedPendingWork { continue }
        guard let processor = nextRunnableProcessor() else {
          let resumed: Bool
          if instrumentationEnabled {
            let sample = hostTimeSample()
            resumed = waitForNextInterrupt(after: pendingWorkGeneration)
            recordHostTime(.idleWait, since: sample)
          } else {
            resumed = waitForNextInterrupt(after: pendingWorkGeneration)
          }
          if resumed { continue }
          if let stop = powerStop(instructionCount: completed) { return stop }
          if pendingWorkWake.snapshot() != pendingWorkGeneration { continue }
          return .halted(instructionCount: completed)
        }
        // A batch reserves at most one instruction per vCPU from the global budget. All
        // fetch/admission work finishes before any instruction overlaps; all completions are
        // collected before clocks, device delivery, lifecycle mutations, or serial execution resume.
        if clockSource.monotonicNanoseconds != nil {
          let sample = hostTimeSample()
          let plans = try prepareParallelInstructions(
            startingAt: processor, maximumCount: maximumInstructions - completed, workers: workers)
          if plans.count > 1 {
            let submissions = plans.map { plan in
              (
                plan,
                workers[plan.processor].submit { [self] in
                  observer?(.executing(plan.processor, concurrent: true))
                  defer { observer?(.executed(plan.processor, concurrent: true)) }
                  return try executeParallelInstruction(plan, observer: observer)
                }
              )
            }
            // Join every submitted vCPU even when one fails. No worker may retain architectural
            // state or guest-memory authority after this run releases the execution gate.
            var executions: [ProcessorExecution] = []
            var firstFailure: (any Error)?
            for submission in submissions {
              do {
                executions.append(try submission.1.wait())
              } catch {
                if firstFailure == nil { firstFailure = error }
              }
            }
            if let firstFailure { throw firstFailure }
            recordHostTime(.processorExecution, since: sample)
            for execution in executions {
              completed += execution.instructionCount
              recordExecution(execution)
            }
            roundRobinCursor = (plans.last!.processor + 1) % processorCount
            let clockSample = hostTimeSample()
            synchronizeHostClock()
            recordHostTime(.clockAdvancement, since: clockSample)
            if let stop = powerStop(instructionCount: completed) { return stop }
            continue
          }
          recordHostTime(.processorExecution, since: sample)
        }
        guard let processorState = processorSlots[processor].state else { continue }
        let remaining = maximumInstructions - completed
        let jitInstructionBudget =
          baselineJITs.isEmpty ? nil : baselineInstructionBudget(maximumInstructions: remaining)
        let execution: ProcessorExecution
        if instrumentationEnabled {
          let sample = hostTimeSample()
          execution = try workers[processor].perform { [self] in
            pendingWorkWake.setDispatchThread(Thread.current, forProcessor: processor)
            defer { pendingWorkWake.setDispatchThread(nil, forProcessor: processor) }
            observer?(.executing(processor, concurrent: false))
            defer { observer?(.executed(processor, concurrent: false)) }
            return try execute(
              processor: processor,
              state: &processorState.value,
              maximumInstructions: remaining,
              jitInstructionBudget: jitInstructionBudget
            )
          }
          pendingWorkWake.setDispatchThread(Thread.current)
          recordHostTime(.processorExecution, since: sample)
        } else {
          execution = try workers[processor].perform { [self] in
            pendingWorkWake.setDispatchThread(Thread.current, forProcessor: processor)
            defer { pendingWorkWake.setDispatchThread(nil, forProcessor: processor) }
            observer?(.executing(processor, concurrent: false))
            defer { observer?(.executed(processor, concurrent: false)) }
            return try execute(
              processor: processor,
              state: &processorState.value,
              maximumInstructions: remaining,
              jitInstructionBudget: jitInstructionBudget
            )
          }
          pendingWorkWake.setDispatchThread(Thread.current)
        }
        reconcileTranslationInvalidations(afterExecuting: processor)
        completed += execution.instructionCount
        recordExecution(execution)
        if instrumentationEnabled {
          let sample = hostTimeSample()
          if clockSource.monotonicNanoseconds != nil {
            synchronizeHostClock()
          } else {
            if execution.instructionCount > 1 {
              advanceClocks(by: execution.instructionCount - 1)
            }
            // Deterministic TSC progression is an explicit test/replay policy, not product time.
            advanceTSCs(byMachineTicks: execution.instructionCount)
          }
          recordHostTime(.clockAdvancement, since: sample)
        } else {
          if clockSource.monotonicNanoseconds != nil {
            synchronizeHostClock()
          } else {
            if execution.instructionCount > 1 {
              advanceClocks(by: execution.instructionCount - 1)
            }
            advanceTSCs(byMachineTicks: execution.instructionCount)
          }
        }
        if let stop = powerStop(instructionCount: completed) { return stop }
        switch execution.result {
        case .retired, .yielded:
          processorSlots[processor].isHalted = false
          continue
        case .halted:
          processorSlots[processor].isHalted = true
          continue
        case .exception(let exception):
          guard exceptionPolicy == .deliver else {
            return .exception(exception, instructionCount: completed - 1)
          }
          let faultMode = executionMode(processorState.value)
          translatedMemories[processor].updateContext(
            .init(state: processorState.value, mode: faultMode, profile: interpreter.profile)
          )
          let faultLinearInstructionPointer =
            faultMode == .long64
            ? exception.instructionPointer
            : processorState.value.cs.base &+ exception.instructionPointer
          let faultBytes =
            (try? translatedMemories[processor].instructionBytes(
              at: faultLinearInstructionPointer,
              maximumCount: 15
            )) ?? []
          let evidence = DoryPCTripleFaultExceptionEvidence(
            exception: exception,
            processor: processor,
            executionMode: faultMode,
            state: processorState.value,
            instructionBytes: faultBytes
          )
          do {
            if instrumentationEnabled {
              let sample = hostTimeSample()
              try DoryX86InterruptDelivery(profile: interpreter.profile).deliverException(
                exception,
                state: &processorState.value,
                physicalMemory: physicalMemories[processor],
                pagingUnit: pagingUnits[processor],
                mode: executionMode(processorState.value)
              )
              recordHostTime(.interruptDelivery, since: sample)
            } else {
              try DoryX86InterruptDelivery(profile: interpreter.profile).deliverException(
                exception,
                state: &processorState.value,
                physicalMemory: physicalMemories[processor],
                pagingUnit: pagingUnits[processor],
                mode: executionMode(processorState.value)
              )
            }
          } catch DoryX86InterruptDeliveryError.processorShutdown {
            return .tripleFault(
              source: .exception(evidence),
              instructionCount: completed - 1
            )
          }
        }
      }
      return .instructionBudget(maximumInstructions)
    }
  }

  /// Runs one vCPU as a single host-worker job. The owning worker drains its lifecycle mailbox,
  /// acknowledges translation invalidations, and delivers interrupts before every execution
  /// reservation. The coordinator owns clocks, machine stop selection, and exact directives while
  /// the worker is parked at a result boundary.
  private func runSingleProcessorSession(
    maximumInstructions: UInt64,
    exceptionPolicy: DoryPCExceptionPolicy,
    observer: (@Sendable (WorkerEvent) -> Void)?,
    worker: DoryPCHostWorker
  ) throws -> DoryPCMachineStop {
    // The coordinator no longer drains pending device work in this path. Timer/device callbacks
    // produced on this thread must therefore publish a real edge for the owning worker.
    pendingWorkWake.setDispatchThread(nil)
    runGeneration = runGeneration == .max ? 1 : runGeneration + 1
    let generation = runGeneration
    let session = DoryPCRunSession(
      processorCount: 1,
      instructionBudget: maximumInstructions,
      runGeneration: generation,
      exceptionPolicy: exceptionPolicy,
      clockMode: clockSource.monotonicNanoseconds == nil ? .deterministic : .hostMonotonic
    )
    let budgetMailbox = RunBudgetMailbox()
    let failureBox = RunFailureBox()
    var workerCompletion: DoryPCHostWorker.Completion<Void>?
    var outstandingResult: DoryPCRunSession.WorkerResult?
    var acknowledgedPendingWorkGeneration: UInt64?
    var completed: UInt64 = 0
    var advanceClockBeforeBoundary = true

    func stopWorker() throws {
      defer { pendingWorkWake.setDispatchThread(nil) }
      let result = try outstandingResult ?? session.workerResult(forProcessor: 0)
      if let result {
        _ = try session.respond(to: result, with: .stop)
        outstandingResult = nil
      }
      if let workerCompletion { _ = try workerCompletion.wait() }
    }

    func finish(
      _ stop: DoryPCMachineStop,
      termination: DoryPCRunSession.TerminationReason? = nil
    ) throws -> DoryPCMachineStop {
      if let termination { try session.requestTermination(termination) }
      try stopWorker()
      return stop
    }

    func dispatchWorker(maximumInstructions: UInt64) throws {
      budgetMailbox.publish(maximumInstructions)
      pendingWorkWake.setDispatchThread(nil)
      if let result = outstandingResult {
        _ = try session.respond(to: result, with: .resume)
        outstandingResult = nil
      } else {
        precondition(workerCompletion == nil)
        workerCompletion = worker.submit(kind: .runLoop) { [self] in
          try runSingleProcessorWorkerLoop(
            session: session,
            budgetMailbox: budgetMailbox,
            failureBox: failureBox,
            observer: observer
          )
        }
      }
    }

    do {
      while completed < maximumInstructions {
        if let stop = powerStop(instructionCount: completed) {
          let reason: DoryPCRunSession.TerminationReason =
            switch stop {
            case .poweredOff: .powerOff
            case .reset: .reset
            default: .cancelled
            }
          return try finish(stop, termination: reason)
        }
        if advanceClockBeforeBoundary {
          if instrumentationEnabled {
            let sample = hostTimeSample()
            if clockSource.monotonicNanoseconds != nil {
              synchronizeHostClock()
            } else {
              advanceClocks(by: 1)
            }
            recordHostTime(.clockAdvancement, since: sample)
          } else if clockSource.monotonicNanoseconds != nil {
            synchronizeHostClock()
          } else {
            advanceClocks(by: 1)
          }
        }
        let pendingWorkGeneration = pendingWorkWake.snapshot(forProcessor: 0)
        let hasPendingWork =
          acknowledgedPendingWorkGeneration == nil
          || pendingWorkGeneration != acknowledgedPendingWorkGeneration
        guard nextRunnableProcessor() != nil || hasPendingWork else {
          let resumed: Bool
          if instrumentationEnabled {
            let sample = hostTimeSample()
            resumed = waitForNextInterrupt(
              forProcessor: 0,
              after: acknowledgedPendingWorkGeneration ?? pendingWorkGeneration)
            recordHostTime(.idleWait, since: sample)
          } else {
            resumed = waitForNextInterrupt(
              forProcessor: 0,
              after: acknowledgedPendingWorkGeneration ?? pendingWorkGeneration)
          }
          if resumed { continue }
          if let stop = powerStop(instructionCount: completed) {
            let reason: DoryPCRunSession.TerminationReason =
              switch stop {
              case .poweredOff: .powerOff
              case .reset: .reset
              default: .cancelled
              }
            return try finish(stop, termination: reason)
          }
          if pendingWorkWake.snapshot(forProcessor: 0)
            != (acknowledgedPendingWorkGeneration ?? pendingWorkGeneration)
          {
            continue
          }
          return try finish(.halted(instructionCount: completed))
        }

        let remaining = maximumInstructions - completed
        let reservationLimit =
          baselineJITs.isEmpty
          ? UInt64(1)
          : UInt64(baselineInstructionBudget(maximumInstructions: remaining))
        let executionSample = hostTimeSample()
        try dispatchWorker(maximumInstructions: min(remaining, reservationLimit))
        let result = try waitForWorkerResult(session: session, completion: workerCompletion!)
        pendingWorkWake.setDispatchThread(nil)
        recordHostTime(.processorExecution, since: executionSample)
        outstandingResult = result
        acknowledgedPendingWorkGeneration = result.acknowledgedPendingWorkGeneration
        advanceClockBeforeBoundary = result.counters.instructionCount > 0
        recordSessionCounters(result.counters)

        if case .hostFailure = result.outcome {
          guard let failure = failureBox.storedFailure else { throw WorkerError.missingHostFailure }
          throw failure
        }

        completed += result.counters.instructionCount
        if instrumentationEnabled {
          let sample = hostTimeSample()
          if clockSource.monotonicNanoseconds != nil {
            synchronizeHostClock()
          } else {
            if result.counters.instructionCount > 1 {
              advanceClocks(by: result.counters.instructionCount - 1)
            }
            advanceTSCs(byMachineTicks: result.counters.instructionCount)
          }
          recordHostTime(.clockAdvancement, since: sample)
        } else if clockSource.monotonicNanoseconds != nil {
          synchronizeHostClock()
        } else {
          if result.counters.instructionCount > 1 {
            advanceClocks(by: result.counters.instructionCount - 1)
          }
          advanceTSCs(byMachineTicks: result.counters.instructionCount)
        }
        if let stop = powerStop(instructionCount: completed) {
          let reason: DoryPCRunSession.TerminationReason =
            switch stop {
            case .poweredOff: .powerOff
            case .reset: .reset
            default: .cancelled
            }
          return try finish(stop, termination: reason)
        }

        switch result.outcome {
        case .retired, .yielded:
          processorSlots[0].isHalted = false
        case .halted:
          processorSlots[0].isHalted = true
        case .tripleFault(let source):
          return try finish(
            .tripleFault(source: source, instructionCount: completed),
            termination: .tripleFault(processor: 0)
          )
        case .hostFailure:
          preconditionFailure("host failure handled before architectural result dispatch")
        case .exception(let exception):
          guard exceptionPolicy == .deliver else {
            return try finish(.exception(exception, instructionCount: completed - 1))
          }
          guard let processorState = processorSlots[0].state else {
            throw DoryPCMachineError.notLoaded
          }
          let faultMode = executionMode(processorState.value)
          translatedMemories[0].updateContext(
            .init(state: processorState.value, mode: faultMode, profile: interpreter.profile)
          )
          let faultLinearInstructionPointer =
            faultMode == .long64
            ? exception.instructionPointer
            : processorState.value.cs.base &+ exception.instructionPointer
          let faultBytes =
            (try? translatedMemories[0].instructionBytes(
              at: faultLinearInstructionPointer,
              maximumCount: 15
            )) ?? []
          let evidence = DoryPCTripleFaultExceptionEvidence(
            exception: exception,
            processor: 0,
            executionMode: faultMode,
            state: processorState.value,
            instructionBytes: faultBytes
          )
          do {
            if instrumentationEnabled {
              let sample = hostTimeSample()
              try DoryX86InterruptDelivery(profile: interpreter.profile).deliverException(
                exception,
                state: &processorState.value,
                physicalMemory: physicalMemories[0],
                pagingUnit: pagingUnits[0],
                mode: executionMode(processorState.value)
              )
              recordHostTime(.interruptDelivery, since: sample)
            } else {
              try DoryX86InterruptDelivery(profile: interpreter.profile).deliverException(
                exception,
                state: &processorState.value,
                physicalMemory: physicalMemories[0],
                pagingUnit: pagingUnits[0],
                mode: executionMode(processorState.value)
              )
            }
          } catch DoryX86InterruptDeliveryError.processorShutdown {
            return try finish(
              .tripleFault(source: .exception(evidence), instructionCount: completed - 1),
              termination: .tripleFault(processor: 0)
            )
          }
        }
      }
      return try finish(.instructionBudget(maximumInstructions), termination: .instructionBudget)
    } catch {
      let originalFailure = error
      try? session.requestTermination(.cancelled)
      try? stopWorker()
      throw originalFailure
    }
  }

  private func runSingleProcessorWorkerLoop(
    session: DoryPCRunSession,
    budgetMailbox: RunBudgetMailbox,
    failureBox: RunFailureBox,
    observer: (@Sendable (WorkerEvent) -> Void)?
  ) throws {
    let processor = 0
    observer?(.runLoopStarted(processor, generation: session.runGeneration))
    defer { observer?(.runLoopStopped(processor, generation: session.runGeneration)) }
    while true {
      let maximumInstructions = try budgetMailbox.consume()
      guard
        let reservation = try session.reserve(
          processor: processor,
          maximumInstructions: maximumInstructions
        )
      else { throw WorkerError.missingRunReservation }
      pendingWorkWake.setDispatchThread(Thread.current, forProcessor: processor)
      let result: DoryPCRunSession.WorkerResult
      var failureCounters = DoryPCRunSession.WorkerCounters.zero
      var executionStartedCPU: UInt64?
      do {
        let boundary = try serviceSingleProcessorBoundary(
          session: session,
          processor: processor,
          observer: observer
        )
        failureCounters.eventCPUNanoseconds = boundary.eventCPUNanoseconds
        if let source = boundary.tripleFault {
          pendingWorkWake.setDispatchThread(nil, forProcessor: processor)
          result = try session.completeAndPublish(
            reservation,
            outcome: .tripleFault(source),
            counters: .init(eventCPUNanoseconds: boundary.eventCPUNanoseconds),
            acknowledgedPendingWorkGeneration: boundary.acknowledgedPendingWorkGeneration
          )
        } else if processorSlots[processor].lifecycle != .running
          || processorSlots[processor].isHalted
        {
          pendingWorkWake.setDispatchThread(nil, forProcessor: processor)
          result = try session.completeAndPublish(
            reservation,
            outcome: .halted,
            counters: .init(eventCPUNanoseconds: boundary.eventCPUNanoseconds),
            acknowledgedPendingWorkGeneration: boundary.acknowledgedPendingWorkGeneration
          )
        } else {
          guard let processorState = processorSlots[processor].state else {
            throw DoryPCMachineError.notLoaded
          }
          if instrumentationEnabled {
            executionStartedCPU = dory_thread_cpu_time_nanoseconds()
          }
          observer?(.executing(processor, concurrent: false))
          let execution: ProcessorExecution
          do {
            execution = try execute(
              processor: processor,
              state: &processorState.value,
              maximumInstructions: reservation.instructionCount,
              jitInstructionBudget: baselineJITs.isEmpty
                ? nil : Int(reservation.instructionCount)
            )
          } catch {
            observer?(.executed(processor, concurrent: false))
            throw error
          }
          observer?(.executed(processor, concurrent: false))
          observeWorkerTranslationReconciliation(
            afterExecuting: processor,
            observer: observer
          )
          pendingWorkWake.setDispatchThread(nil, forProcessor: processor)
          let elapsedCPU =
            executionStartedCPU.map {
              dory_thread_cpu_time_nanoseconds() &- $0
            } ?? 0
          var counters = sessionCounters(
            for: execution,
            executionCPUNanoseconds: elapsedCPU
          )
          counters.eventCPUNanoseconds = boundary.eventCPUNanoseconds
          result = try session.completeAndPublish(
            reservation,
            outcome: sessionOutcome(for: execution.result),
            counters: counters,
            acknowledgedPendingWorkGeneration: boundary.acknowledgedPendingWorkGeneration
          )
        }
      } catch {
        pendingWorkWake.setDispatchThread(nil, forProcessor: processor)
        if let executionStartedCPU {
          failureCounters.executionCPUNanoseconds =
            dory_thread_cpu_time_nanoseconds() &- executionStartedCPU
        }
        failureBox.store(error)
        try session.requestTermination(.hostFailure(processor: processor))
        let failureResult = try session.completeAndPublish(
          reservation,
          outcome: .hostFailure,
          counters: failureCounters,
          acknowledgedPendingWorkGeneration: pendingWorkWake.snapshot(forProcessor: processor)
        )
        _ = try session.waitForDirective(
          processor: processor,
          forResultSequence: failureResult.sequence
        )
        return
      }
      switch try session.waitForDirective(
        processor: processor,
        forResultSequence: result.sequence
      ) {
      case .resume:
        continue
      case .stop:
        return
      }
    }
  }

  /// Drains one worker-owned architectural boundary. The session generation and the native poll
  /// byte are acknowledged only after lifecycle events, translation work, and interrupt delivery
  /// have all completed. A racing publisher either makes the wake acknowledgement fail or restores
  /// the poll byte after the clear, so the next execution cannot erase that edge.
  private func serviceSingleProcessorBoundary(
    session: DoryPCRunSession,
    processor: Int,
    observer: (@Sendable (WorkerEvent) -> Void)?
  ) throws -> WorkerBoundaryService {
    var eventCPUNanoseconds: UInt64 = 0
    var tripleFault: DoryPCTripleFaultSource?

    while true {
      let observedWakeGeneration = pendingWorkWake.snapshot(forProcessor: processor)
      _ = try session.observePendingWork(
        processor: processor,
        sourceGeneration: observedWakeGeneration
      )
      observer?(.servicingPendingWork(processor))
      let startedCPU = instrumentationEnabled ? dory_thread_cpu_time_nanoseconds() : 0
      _ = servicePendingTranslationInvalidation(forProcessor: processor, observer: observer)
      applyProcessorEvents(forProcessor: processor)
      _ = reconcilePendingPageTableWritesFromWorker(processor: processor, observer: observer)
      if tripleFault == nil,
        let stop = try deliverPendingInterrupt(
          forProcessor: processor,
          instructionCount: 0,
          observer: observer
        ),
        case .tripleFault(let source, _) = stop
      {
        tripleFault = source
      }
      _ = reconcilePendingPageTableWritesFromWorker(processor: processor, observer: observer)
      _ = servicePendingTranslationInvalidation(forProcessor: processor, observer: observer)
      if instrumentationEnabled {
        let elapsed = dory_thread_cpu_time_nanoseconds() &- startedCPU
        saturatingAdd(elapsed, to: &eventCPUNanoseconds)
      }

      let acknowledgedWake = pendingWorkWake.acknowledge(
        forProcessor: processor,
        after: observedWakeGeneration
      ) {
        if baselineJITs.indices.contains(processor) {
          baselineJITs[processor].clearPendingWork()
        }
        if optimizingJITs.indices.contains(processor) {
          optimizingJITs[processor].clearPendingWork()
        }
      }
      guard acknowledgedWake else {
        continue
      }
      if let required = try session.pendingWorkGeneration(forProcessor: processor) {
        _ = try session.acknowledgePendingWork(processor: processor, generation: required)
      }
      // Generation wrap may publish generation one while acknowledging UInt64.max. Drain that
      // representable edge before entering guest code.
      if try session.pendingWorkGeneration(forProcessor: processor) != nil { continue }
      return .init(
        acknowledgedPendingWorkGeneration: observedWakeGeneration,
        tripleFault: tripleFault,
        eventCPUNanoseconds: eventCPUNanoseconds
      )
    }
  }

  private func observeWorkerTranslationReconciliation(
    afterExecuting processor: Int,
    observer: (@Sendable (WorkerEvent) -> Void)?
  ) {
    reconcileTranslationInvalidationsFromWorker(
      afterExecuting: processor,
      observer: observer
    )
  }

  private func waitForWorkerResult(
    session: DoryPCRunSession,
    completion: DoryPCHostWorker.Completion<Void>
  ) throws -> DoryPCRunSession.WorkerResult {
    var snapshot = session.snapshot
    while true {
      if let result = snapshot.workerResults[0] { return result }
      if completion.isFinished {
        _ = try completion.wait()
        throw WorkerError.runLoopExitedWithoutResult
      }
      snapshot = session.waitForChange(
        after: snapshot.changeGeneration,
        until: Date(timeIntervalSinceNow: 0.05)
      )
    }
  }

  private func sessionOutcome(for result: ProcessorResult) -> DoryPCRunSession.WorkerOutcome {
    switch result {
    case .retired: .retired
    case .yielded: .yielded
    case .halted: .halted
    case .exception(let exception): .exception(exception)
    }
  }

  private func sessionCounters(
    for execution: ProcessorExecution,
    executionCPUNanoseconds: UInt64
  ) -> DoryPCRunSession.WorkerCounters {
    var counters = DoryPCRunSession.WorkerCounters(
      instructionCount: execution.instructionCount,
      interpreterInstructions: execution.interpreterInstructionCount,
      executionCPUNanoseconds: executionCPUNanoseconds
    )
    switch execution.jitTier {
    case .baseline, .tier1:
      counters.baselineJITInstructions = execution.jitInstructionCount
      counters.baselineJITBlocks = execution.jitBlockCount
    case .optimizing:
      counters.optimizingJITInstructions = execution.jitInstructionCount
      counters.optimizingJITBlocks = execution.jitBlockCount
    case .interpreterFallback:
      counters.interpreterFallbackJITInstructions = execution.jitInstructionCount
    case nil:
      break
    }
    return counters
  }

  private func recordSessionCounters(_ counters: DoryPCRunSession.WorkerCounters) {
    interpreterInstructionCount &+= counters.interpreterInstructions
    baselineJITInstructionCount &+= counters.baselineJITInstructions
    baselineJITBlockCount &+= counters.baselineJITBlocks
    optimizingJITInstructionCount &+= counters.optimizingJITInstructions
    optimizingJITBlockCount &+= counters.optimizingJITBlocks
    saturatingAdd(counters.executionCPUNanoseconds, to: &hostThreadCPUTime.totalNanoseconds)
    saturatingAdd(
      counters.executionCPUNanoseconds,
      to: &hostThreadCPUTime.processorExecutionNanoseconds
    )
    saturatingAdd(counters.eventCPUNanoseconds, to: &hostThreadCPUTime.totalNanoseconds)
    saturatingAdd(
      counters.eventCPUNanoseconds,
      to: &hostThreadCPUTime.processorEventNanoseconds
    )
  }

  // Test observation is installed only while quiescent and copied before workers start.
  // Callbacks must not reenter gate-protected public machine operations.
  enum WorkerEvent: Sendable {
    case runLoopStarted(Int, generation: UInt64)
    case runLoopStopped(Int, generation: UInt64)
    case servicingPendingWork(Int)
    case acknowledgedTranslationInvalidation(Int, generation: UInt64)
    case deliveringInterrupt(Int, vector: UInt8)
    case executing(Int, concurrent: Bool)
    case executed(Int, concurrent: Bool)
    case frozenInstructionFetch(Int)
    case nativeInstructionFetch(Int)
    case nativeInstructionExit(Int, retired: UInt64)
    case stopped(Int)
  }

  private var workerObserver: (@Sendable (WorkerEvent) -> Void)?

  func observeWorkers(_ observer: @escaping @Sendable (WorkerEvent) -> Void) {
    lock.withLock { workerObserver = observer }
  }

  private enum WorkerError: Error {
    case inconsistentFrozenInstruction, inconsistentNativeInstruction
    case missingRunBudget, missingRunReservation, runLoopExitedWithoutResult, missingHostFailure
  }

  struct ParallelInstruction: Sendable {
    let processor: Int
    let state: ProcessorState
    let mode: DoryX86ExecutionMode
    let memory: DoryPCFrozenInstructionMemory
    let jit: DoryARM64BaselineExecutor?
  }

  private func prepareParallelInstructions(
    startingAt first: Int, maximumCount: UInt64, workers: [DoryPCHostWorker]
  ) throws -> [ParallelInstruction] {
    guard processorCount > 1, maximumCount > 1 else { return [] }
    var plans: [ParallelInstruction] = []
    for displacement in 0..<processorCount {
      let processor = (first + displacement) % processorCount
      guard plans.count < Int(min(maximumCount, UInt64(processorCount))) else { break }
      let slot = processorSlots[processor]
      guard let state = slot.state, !slot.isHalted,
        slot.lifecycle == .running
      else { continue }
      let plan = try workers[processor].perform { [self] () -> ParallelInstruction? in
        guard let frozen = frozenParallelInstruction(state: state.value, processor: processor)
        else { return nil }
        let mode = executionMode(state.value)
        var jit: DoryARM64BaselineExecutor?
        if executionTier != .interpreter {
          // No paging, non-flat CS, hidden execution guards, or shared memory callbacks.
          // Selection mutates machine hotness, so it must finish before jobs overlap.
          guard mode == .protected32, state.value.cs.base == 0, state.value.cs.limit == .max,
            !state.value.rflags.contains(.virtual8086), !state.value.rflags.contains(.resume),
            !state.value.rflags.contains(.alignmentCheck),
            let selected = selectedJIT(forProcessor: processor, state: state.value, mode: mode)
          else { return nil }
          jit = selected
        }
        return .init(
          processor: processor, state: state,
          mode: mode, memory: frozen, jit: jit)
      }
      // Preserve runnable order across a sensitive instruction instead of skipping ahead.
      guard let plan else { break }
      plans.append(plan)
    }
    return plans
  }

  // Called only while quiescent or by the owning worker during serial admission.
  // Internal so tests can exercise invalid hidden CS caches without a public state mutator.
  func frozenParallelInstruction(
    state: DoryX86ArchitecturalState, processor: Int
  ) -> DoryPCFrozenInstructionMemory? {
    guard state.control.cr0 & (1 << 31) == 0,
      !state.rflags.contains(.trap), state.interruptShadow == nil
    else { return nil }
    let mode = executionMode(state)
    let mask: UInt64 = mode == .real16 ? 0xffff : (mode == .long64 ? .max : 0xffff_ffff)
    let offset = state.rip & mask
    let maximumFetchByteCount: Int
    // Match the interpreter's instructionFetchByteCount contract before raw RAM decoding.
    // Declining leaves fault selection and publication to ordinary serial execution.
    if mode == .long64 {
      guard DoryX86ArchitecturalState.isCanonical(state.rip) else { return nil }
      maximumFetchByteCount = 15
    } else {
      if mode == .protected16 || mode == .protected32 {
        let access = UInt8(truncatingIfNeeded: state.cs.attributes)
        guard access & 0x80 != 0, access & 0x10 != 0, access & 8 != 0 else { return nil }
      }
      guard offset <= UInt64(state.cs.limit) else { return nil }
      maximumFetchByteCount = Int(min(15, UInt64(state.cs.limit) - offset + 1))
    }
    let address = mode == .long64 ? state.rip : state.cs.base &+ offset
    guard let bytes = physicalMemories[processor].frozenRAMInstructionBytes(at: address),
      let opcode = bytes.first, opcode == 0x90 || (0xB8...0xBF).contains(opcode),
      let instruction = try? interpreters[processor].decoder.decode(
        Array(bytes.prefix(maximumFetchByteCount)), at: state.rip, mode: mode)
    else { return nil }
    // Deliberately small, prefix-free whitelist: NOP and MOV immediate to a GPR.
    // Paging, branches, memory operands, system state and IO always rendezvous.
    let frozen = DoryPCFrozenInstructionMemory(address: address, bytes: instruction.bytes)
    var candidate = state
    guard
      case .retired = interpreters[processor].step(
        state: &candidate, memory: frozen, mode: mode)
    else { return nil }
    return frozen
  }

  private func executeParallelInstruction(
    _ plan: ParallelInstruction, observer: (@Sendable (WorkerEvent) -> Void)?
  ) throws -> ProcessorExecution {
    if let jit = plan.jit {
      // Each executor owns its region, context, TLB, predictors and cache. Frozen fetches and
      // nil memory prevent compilation/execution from touching shared RAM or device metadata.
      // No generation provider means resident bytes must be validated and traces cannot replay.
      // One instruction also bounds old direct links: no budget remains for a second block.
      var observedFetch = false
      let execution = try jit.executeChainedSummary(
        byteProvider: { address, count in
          if !observedFetch {
            observedFetch = true
            observer?(.nativeInstructionFetch(plan.processor))
          }
          guard address == plan.memory.address else { return [] }
          return Array(plan.memory.bytes.prefix(count))
        },
        at: plan.state.value.rip, mode: plan.mode,
        addressSpaceID: plan.state.value.control.cr3, maximumInstructions: 1,
        state: &plan.state.value
      )
      if let execution {
        guard execution.exitCode == .dispatch || execution.exitCode == .pendingWork,
          execution.guestInstructionCount <= 1
        else { throw WorkerError.inconsistentNativeInstruction }
        // The sole block polls before its instruction. Legacy executors without chain
        // accounting report the resident size on this exit, even though nothing retired.
        let count = execution.exitCode == .pendingWork ? 0 : UInt64(execution.guestInstructionCount)
        observer?(.nativeInstructionExit(plan.processor, retired: count))
        return .init(
          result: execution.exitCode == .pendingWork ? .yielded : .retired,
          instructionCount: count, jitTier: execution.tier, jitInstructionCount: count,
          interpreterInstructionCount: 0, jitBlockCount: count)
      }
      if jit.hasPendingWork {
        observer?(.nativeInstructionExit(plan.processor, retired: 0))
        return .init(
          result: .yielded, instructionCount: 0, jitTier: nil,
          jitInstructionCount: 0, interpreterInstructionCount: 0, jitBlockCount: 0)
      }
      // A resident larger than this budget or a compiler decline still has the identical
      // preflighted, register-only interpreter step available; it cannot access shared memory.
    }
    let onFirstFetch: @Sendable () -> Void = {
      if plan.jit == nil { observer?(.frozenInstructionFetch(plan.processor)) }
    }
    let memory = DoryPCFrozenInstructionMemory(
      address: plan.memory.address, bytes: plan.memory.bytes, onFirstFetch: onFirstFetch)
    let result = interpreters[plan.processor].step(
      state: &plan.state.value, memory: memory, mode: plan.mode)
    guard case .retired = result else { throw WorkerError.inconsistentFrozenInstruction }
    return .init(
      result: .retired, instructionCount: 1, jitTier: nil,
      jitInstructionCount: 0, interpreterInstructionCount: 1, jitBlockCount: 0)
  }

  private func recordExecution(_ execution: ProcessorExecution) {
    switch execution.jitTier {
    case .baseline, .tier1:
      baselineJITInstructionCount &+= execution.jitInstructionCount
      baselineJITBlockCount &+= execution.jitBlockCount
    case .optimizing:
      optimizingJITInstructionCount &+= execution.jitInstructionCount
      optimizingJITBlockCount &+= execution.jitBlockCount
    case .interpreterFallback, nil:
      break
    }
    interpreterInstructionCount &+= execution.interpreterInstructionCount
  }

  private func publishExecutionStatistics() {
    let deliveredMaskableInterrupts = processorSlots.reduce(0) {
      $0 &+ $1.deliveredMaskableInterrupts
    }
    let deliveredNonMaskableInterrupts = processorSlots.reduce(0) {
      $0 &+ $1.deliveredNonMaskableInterrupts
    }
    let retiredInterruptReturns = processorSlots.reduce(0) {
      $0 &+ $1.retiredInterruptReturns
    }
    var deliveredInterruptVectors: [UInt8: UInt64] = [:]
    for slot in processorSlots {
      for (vector, deliveries) in slot.deliveredInterruptVectors {
        deliveredInterruptVectors[vector, default: 0] &+= deliveries
      }
    }
    let snapshot = DoryPCExecutionStatistics(
      interpreterInstructions: interpreterInstructionCount,
      baselineJITInstructions: baselineJITInstructionCount,
      baselineJITBlocks: baselineJITBlockCount,
      optimizingJITInstructions: optimizingJITInstructionCount,
      optimizingJITBlocks: optimizingJITBlockCount,
      deliveredMaskableInterrupts: deliveredMaskableInterrupts,
      deliveredNonMaskableInterrupts: deliveredNonMaskableInterrupts,
      retiredInterruptReturns: retiredInterruptReturns,
      deliveredInterruptVectors:
        deliveredInterruptVectors
        .sorted { lhs, rhs in
          if lhs.value == rhs.value { return lhs.key < rhs.key }
          return lhs.value > rhs.value
        }
        .map { .init(vector: $0.key, deliveries: $0.value) }
    )
    executionStatisticsLock.withLock { publishedExecutionStatistics = snapshot }
  }

  private func publishHostExecutionDiagnostics() {
    let snapshot = DoryPCHostExecutionDiagnostics(
      enabled: instrumentationEnabled,
      runCalls: hostTimeRunCalls,
      wall: hostWallTime.snapshot,
      threadCPU: hostThreadCPUTime.snapshot
    )
    hostExecutionDiagnosticsLock.withLock { publishedHostExecutionDiagnostics = snapshot }
  }

  @inline(__always)
  private func hostTimeSample() -> HostTimeSample? {
    guard instrumentationEnabled else { return nil }
    return .init(
      wallNanoseconds: DispatchTime.now().uptimeNanoseconds,
      threadCPUNanoseconds: dory_thread_cpu_time_nanoseconds()
    )
  }

  private func recordTotalHostTime(since sample: HostTimeSample?) {
    guard let sample, let elapsed = elapsedHostTime(since: sample) else { return }
    saturatingIncrement(&hostTimeRunCalls)
    saturatingAdd(elapsed.wallNanoseconds, to: &hostWallTime.totalNanoseconds)
    saturatingAdd(elapsed.threadCPUNanoseconds, to: &hostThreadCPUTime.totalNanoseconds)
  }

  @inline(__always)
  private func recordHostTime(_ category: HostTimeCategory, since sample: HostTimeSample?) {
    guard let sample, let elapsed = elapsedHostTime(since: sample) else { return }
    switch category {
    case .processorEvent:
      saturatingAdd(elapsed.wallNanoseconds, to: &hostWallTime.processorEventNanoseconds)
      saturatingAdd(elapsed.threadCPUNanoseconds, to: &hostThreadCPUTime.processorEventNanoseconds)
    case .clockAdvancement:
      saturatingAdd(elapsed.wallNanoseconds, to: &hostWallTime.clockAdvancementNanoseconds)
      saturatingAdd(
        elapsed.threadCPUNanoseconds, to: &hostThreadCPUTime.clockAdvancementNanoseconds)
    case .interruptDelivery:
      saturatingAdd(elapsed.wallNanoseconds, to: &hostWallTime.interruptDeliveryNanoseconds)
      saturatingAdd(
        elapsed.threadCPUNanoseconds, to: &hostThreadCPUTime.interruptDeliveryNanoseconds)
    case .processorExecution:
      saturatingAdd(elapsed.wallNanoseconds, to: &hostWallTime.processorExecutionNanoseconds)
      saturatingAdd(
        elapsed.threadCPUNanoseconds, to: &hostThreadCPUTime.processorExecutionNanoseconds)
    case .idleWait:
      saturatingAdd(elapsed.wallNanoseconds, to: &hostWallTime.idleWaitNanoseconds)
      saturatingAdd(elapsed.threadCPUNanoseconds, to: &hostThreadCPUTime.idleWaitNanoseconds)
    }
  }

  private func elapsedHostTime(since sample: HostTimeSample) -> HostTimeSample? {
    let wallNow = DispatchTime.now().uptimeNanoseconds
    let cpuNow = dory_thread_cpu_time_nanoseconds()
    guard wallNow >= sample.wallNanoseconds, cpuNow >= sample.threadCPUNanoseconds else {
      return nil
    }
    return .init(
      wallNanoseconds: wallNow - sample.wallNanoseconds,
      threadCPUNanoseconds: cpuNow - sample.threadCPUNanoseconds
    )
  }

  private func saturatingIncrement(_ value: inout UInt64) {
    if value < .max { value += 1 }
  }

  private func saturatingAdd(_ increment: UInt64, to value: inout UInt64) {
    let (sum, overflow) = value.addingReportingOverflow(increment)
    value = overflow ? .max : sum
  }

  enum ProcessorResult: Sendable {
    case retired
    case yielded
    case halted
    case exception(DoryX86Exception)
  }

  struct ProcessorExecution: Sendable {
    let result: ProcessorResult
    let instructionCount: UInt64
    let jitTier: DoryARM64CompilationTier?
    let jitInstructionCount: UInt64
    let interpreterInstructionCount: UInt64
    let jitBlockCount: UInt64
  }

  /// Publishes page-table writes that did not themselves execute an architectural invalidation.
  /// The execution gate has rendezvoused every submitted worker before this method is called, so
  /// applying and acknowledging the global flush here is synchronous with respect to every vCPU.
  func reconcilePendingPageTableWrites() {
    guard translatedMemories.first?.consumePendingPageTableWrite() == true else { return }
    publishTranslationInvalidation(
      sourceProcessor: nil,
      sourceAlreadyInvalidated: false,
      linearAddress: nil)
  }

  /// Imports one vCPU's architectural paging invalidation and acknowledges it on every remote
  /// paging unit and native TLB before the coordinator can dispatch another guest access.
  func reconcileTranslationInvalidations(afterExecuting processor: Int) {
    guard pagingUnits.indices.contains(processor) else { return }
    if translatedMemories[processor].consumePendingPageTableWrite() {
      publishTranslationInvalidation(
        sourceProcessor: nil,
        sourceAlreadyInvalidated: false,
        linearAddress: nil)
      return
    }
    let snapshot = pagingUnits[processor].invalidationSnapshot
    let previous = reconciledPagingInvalidationSequences[processor].load()
    guard snapshot.sequence != previous else { return }
    let next = previous.addingReportingOverflow(1)
    let linearAddress =
      !next.overflow && next.partialValue == snapshot.sequence
      ? snapshot.linearAddress : nil
    publishTranslationInvalidation(
      sourceProcessor: processor,
      sourceAlreadyInvalidated: true,
      linearAddress: linearAddress)
  }

  var translationInvalidationDiagnostics: DoryPCTranslationInvalidationCoordinator.Diagnostics {
    translationInvalidationCoordinator.diagnostics
  }

  private func publishTranslationInvalidation(
    sourceProcessor: Int?,
    sourceAlreadyInvalidated: Bool,
    linearAddress: UInt64?
  ) {
    let publication = translationInvalidationCoordinator.publish(linearAddress: linearAddress)
    for processor in pagingUnits.indices {
      guard let pending = translationInvalidationCoordinator.pending(for: processor) else {
        continue
      }
      acknowledgeTranslationInvalidation(
        pending,
        forProcessor: processor,
        pagingAlreadyInvalidated: sourceAlreadyInvalidated && processor == sourceProcessor
      )
    }
    translationInvalidationCoordinator.wait(for: publication)
  }

  private func acknowledgeTranslationInvalidation(
    _ publication: DoryPCTranslationInvalidationCoordinator.Publication,
    forProcessor processor: Int,
    pagingAlreadyInvalidated: Bool
  ) {
    if !pagingAlreadyInvalidated {
      if let linearAddress = publication.linearAddress {
        pagingUnits[processor].invalidate(linearAddress: linearAddress)
      } else {
        pagingUnits[processor].invalidateAll()
      }
    }
    if baselineJITs.indices.contains(processor) {
      baselineJITs[processor].synchronizeTranslationCache(with: pagingUnits[processor])
    }
    if optimizingJITs.indices.contains(processor) {
      optimizingJITs[processor].synchronizeTranslationCache(with: pagingUnits[processor])
    }
    reconciledPagingInvalidationSequences[processor].store(
      pagingUnits[processor].invalidationSnapshot.sequence)
    translationInvalidationCoordinator.acknowledge(
      processor: processor,
      generation: publication.generation)
  }

  private func publishTranslationPendingWork(excluding sourceProcessor: Int) {
    for processor in pagingUnits.indices where processor != sourceProcessor {
      pendingWorkWake.signal(forProcessor: processor) {
        if baselineJITs.indices.contains(processor) {
          baselineJITs[processor].requestPendingWork()
        }
        if optimizingJITs.indices.contains(processor) {
          optimizingJITs[processor].requestPendingWork()
        }
      }
    }
  }

  /// Publishes from an owning worker without ever blocking behind work that worker still owes.
  /// The source acknowledges only after leaving generated code and synchronizing its native TLB;
  /// the publication cannot complete until every remote worker performs the same boundary.
  private func publishTranslationInvalidationFromWorker(
    sourceProcessor: Int,
    sourceAlreadyInvalidated: Bool,
    linearAddress: UInt64?,
    observer: (@Sendable (WorkerEvent) -> Void)?
  ) {
    while true {
      switch translationInvalidationCoordinator.attemptPublication(
        linearAddress: linearAddress,
        forProcessor: sourceProcessor
      ) {
      case .published(let publication):
        publishTranslationPendingWork(excluding: sourceProcessor)
        acknowledgeTranslationInvalidation(
          publication,
          forProcessor: sourceProcessor,
          pagingAlreadyInvalidated: sourceAlreadyInvalidated
        )
        observer?(
          .acknowledgedTranslationInvalidation(
            sourceProcessor,
            generation: publication.generation
          ))
        translationInvalidationCoordinator.wait(for: publication)
        return
      case .drain(let publication):
        acknowledgeTranslationInvalidation(
          publication,
          forProcessor: sourceProcessor,
          pagingAlreadyInvalidated: false
        )
        observer?(
          .acknowledgedTranslationInvalidation(
            sourceProcessor,
            generation: publication.generation
          ))
      case .wait(let publication):
        translationInvalidationCoordinator.wait(for: publication)
      }
    }
  }

  @discardableResult
  private func servicePendingTranslationInvalidation(
    forProcessor processor: Int,
    observer: (@Sendable (WorkerEvent) -> Void)?
  ) -> Bool {
    guard let publication = translationInvalidationCoordinator.pending(for: processor) else {
      return false
    }
    acknowledgeTranslationInvalidation(
      publication,
      forProcessor: processor,
      pagingAlreadyInvalidated: false
    )
    observer?(
      .acknowledgedTranslationInvalidation(processor, generation: publication.generation))
    return true
  }

  @discardableResult
  private func reconcilePendingPageTableWritesFromWorker(
    processor: Int,
    observer: (@Sendable (WorkerEvent) -> Void)?
  ) -> Bool {
    guard translatedMemories[processor].consumePendingPageTableWrite() else { return false }
    publishTranslationInvalidationFromWorker(
      sourceProcessor: processor,
      sourceAlreadyInvalidated: false,
      linearAddress: nil,
      observer: observer
    )
    return true
  }

  private func reconcileTranslationInvalidationsFromWorker(
    afterExecuting processor: Int,
    observer: (@Sendable (WorkerEvent) -> Void)?
  ) {
    _ = servicePendingTranslationInvalidation(forProcessor: processor, observer: observer)
    if reconcilePendingPageTableWritesFromWorker(processor: processor, observer: observer) {
      return
    }
    let snapshot = pagingUnits[processor].invalidationSnapshot
    let previous = reconciledPagingInvalidationSequences[processor].load()
    guard snapshot.sequence != previous else { return }
    let next = previous.addingReportingOverflow(1)
    let linearAddress =
      !next.overflow && next.partialValue == snapshot.sequence
      ? snapshot.linearAddress : nil
    publishTranslationInvalidationFromWorker(
      sourceProcessor: processor,
      sourceAlreadyInvalidated: true,
      linearAddress: linearAddress,
      observer: observer
    )
  }

  private func execute(
    processor: Int,
    state: inout DoryX86ArchitecturalState,
    maximumInstructions: UInt64,
    jitInstructionBudget: Int?
  ) throws -> ProcessorExecution {
    let mode = executionMode(state)
    var deoptimizedPrefix: DoryARM64ExecutionSummary?
    var attemptedJIT: DoryARM64BaselineExecutor?
    var hadTier1Decline = false
    var declinedSite: DoryARM64InterpreterFallbackSite?
    if let jit = selectedJIT(forProcessor: processor, state: state, mode: mode),
      mode == .long64 || (mode == .protected32 && state.cs.base == 0),
      !state.rflags.contains(.trap),
      state.interruptShadow == nil
    {
      attemptedJIT = jit
      jit.synchronizeTranslationCache(with: pagingUnits[processor])
      let budget = jitInstructionBudget ?? 1
      let translatedMemory = translatedMemories[processor]
      translatedMemory.updateContext(.init(state: state, mode: mode, profile: interpreter.profile))
      let guestRIP = state.rip
      if let execution = try jit.executeChainedSummary(
        byteProvider: { address, maximumCount in
          // A speculative block fetch can cross an unmapped guest page even when the current
          // instruction itself is valid. Preserve the architectural path by declining JIT
          // execution and letting the interpreter perform its precise instruction fetch/fault.
          (try? translatedMemory.instructionBytes(at: address, maximumCount: maximumCount)) ?? []
        },
        codeGenerationProvider: { address, byteCount in
          // Generation tracking is speculative cache metadata, not an architectural fetch.
          // A missing/revoked page invalidates this proof; the precise fetch must fault through
          // the interpreter after any already-completed native chain has been published.
          try? translatedMemory.codeGeneration(at: address, byteCount: byteCount)
        },
        physicalRIPProvider: { address in
          // Cache compiled code by the permission-checked physical instruction address so the
          // same mapping can survive CR3 switches. A failed speculative walk leaves the precise
          // instruction-fetch fault to the interpreter.
          try? translatedMemory.physicalInstructionAddress(at: address)
        },
        at: guestRIP,
        mode: mode,
        addressSpaceID: state.control.cr3,
        maximumInstructions: budget,
        state: &state,
        memory: translatedMemory,
        onCompilationDecline: {
          hadTier1Decline = true
          declinedSite = $0
        }
      ) {
        let count = UInt64(execution.guestInstructionCount)
        switch execution.exitCode {
        case .dispatch:
          return .init(
            result: .retired,
            instructionCount: count,
            jitTier: execution.tier,
            jitInstructionCount: count,
            interpreterInstructionCount: 0,
            jitBlockCount: UInt64(execution.residentBlockCount)
          )
        case .pendingWork:
          return .init(
            result: .yielded,
            instructionCount: count,
            jitTier: execution.tier,
            jitInstructionCount: count,
            interpreterInstructionCount: 0,
            jitBlockCount: UInt64(execution.residentBlockCount)
          )
        case .halt:
          return .init(
            result: .halted,
            instructionCount: count,
            jitTier: execution.tier,
            jitInstructionCount: count,
            interpreterInstructionCount: 0,
            jitBlockCount: UInt64(execution.residentBlockCount)
          )
        case .interpreter:
          if execution.guestInstructionCount > 0 { deoptimizedPrefix = execution }
        case .system, .portIO:
          break
        }
      }
      if jit.hasPendingWork {
        return .init(
          result: .yielded,
          instructionCount: 0,
          jitTier: nil,
          jitInstructionCount: 0,
          interpreterInstructionCount: 0,
          jitBlockCount: 0
        )
      }
    }

    let result = interpreters[processor].step(
      state: &state,
      memory: physicalMemories[processor],
      mode: mode,
      pagingUnit: pagingUnits[processor],
      translatedMemory: translatedMemories[processor],
      ioBus: ioBus
    )
    // Confirmed fallback requires a Tier1 decline callback and architectural retirement,
    // including a successfully retired HLT. Keep causality separate from optional site identity:
    // generic JIT admission/runtime paths must not contribute to the unattributed bucket.
    if hadTier1Decline {
      switch result {
      case .retired, .halted:
        attemptedJIT?.recordInterpreterFallback(site: declinedSite, retiredInstructions: 1)
      case .yielded, .exception:
        break
      }
    }
    let machineResult: ProcessorResult
    switch result {
    case .retired(let instruction):
      if case .interruptReturn = instruction.operation {
        processorSlots[processor].retiredInterruptReturns &+= 1
      }
      machineResult = .retired
    case .yielded:
      machineResult = .yielded
    case .halted:
      machineResult = .halted
    case .exception(let exception):
      machineResult = .exception(exception)
    }
    let nativePrefixCount = UInt64(deoptimizedPrefix?.guestInstructionCount ?? 0)
    return .init(
      result: machineResult,
      instructionCount: nativePrefixCount + 1,
      jitTier: deoptimizedPrefix?.tier,
      jitInstructionCount: nativePrefixCount,
      interpreterInstructionCount: 1,
      jitBlockCount: UInt64(deoptimizedPrefix?.residentBlockCount ?? 0)
    )
  }

  private func selectedJIT(
    forProcessor processor: Int,
    state: DoryX86ArchitecturalState,
    mode: DoryX86ExecutionMode
  ) -> DoryARM64BaselineExecutor? {
    guard baselineJITs.indices.contains(processor) else { return nil }
    let baselineJIT = baselineJITs[processor]
    guard executionTier == .optimizingJIT, optimizingJITs.indices.contains(processor) else {
      return baselineJIT
    }
    let optimizingJIT = optimizingJITs[processor]
    guard optimizingJITWarmupDispatches > 0 else { return optimizingJIT }

    var tag = state.rip
    tag ^= state.control.cr3 &* 0x9e37_79b9_7f4a_7c15
    tag ^= UInt64(state.cs.selector & 3) << 57
    tag ^= UInt64(processor) &* 0xd6e8_feb8_6659_fd93
    tag ^= state.control.cr0 & (1 << 31) != 0 ? 1 << 56 : 0
    switch mode {
    case .real16: tag ^= 0x11
    case .protected16: tag ^= 0x22
    case .protected32: tag ^= 0x33
    case .long64: tag ^= 0x44
    }
    tag ^= tag >> 33
    tag &*= 0xff51_afd7_ed55_8ccd
    tag ^= tag >> 33
    // Reserve zero as the empty tag while retaining deterministic treatment of the one hash that
    // naturally maps there.
    if tag == 0 { tag = 1 }
    // A bounded direct-mapped table keeps full-system cold-start accounting independent of the
    // number of distinct firmware, kernel, and initramfs RIPs. Tables are per owner so concurrent
    // dispatch cannot race Swift Array value storage. A collision merely delays promotion.
    let slot = processorSlots[processor]
    let index = Int(tag & UInt64(slot.jitHotness.count - 1))
    if slot.jitHotness[index].tag != tag {
      slot.jitHotness[index] = .init(tag: tag, dispatchCount: 1)
      return baselineJIT
    }
    if slot.jitHotness[index].dispatchCount < optimizingJITWarmupDispatches {
      slot.jitHotness[index].dispatchCount &+= 1
    }
    return slot.jitHotness[index].dispatchCount >= optimizingJITWarmupDispatches
      ? optimizingJIT : baselineJIT
  }

  private func baselineInstructionBudget(maximumInstructions: UInt64) -> Int {
    // SMP fairness keeps a 64-instruction quantum while multiple processors can run. Once every
    // other processor has parked, a larger bounded quantum avoids needless Swift round trips.
    // Interrupt deadlines below still shorten either batch whenever observable work is due sooner.
    let runnableProcessorCount = processorSlots.lazy.filter {
      $0.state != nil && !$0.isHalted && $0.lifecycle == .running
    }.prefix(2).count
    let fairnessLimit: UInt64 = runnableProcessorCount == 1 ? 4_096 : 64
    var budget = Int(min(maximumInstructions, fairnessLimit))
    if let deadline = ticksUntilNextAcceptedInterrupt() {
      budget = min(budget, Int(min(deadline, UInt64(Int.max))))
    }
    return max(1, budget)
  }

  private func advanceClocks(by ticks: UInt64) {
    guard ticks > 0 else { return }
    let localAPICTicks = scaledDeviceTicks(
      machineTicks: ticks,
      frequencyHz: Self.localAPICClockFrequencyHz,
      remainder: &localAPICClockRemainder
    )
    for apic in localAPICs { apic.advanceTimer(byBaseClockTicks: localAPICTicks) }
    let pitTicks = scaledDeviceTicks(
      machineTicks: ticks,
      frequencyHz: Self.pitFrequencyHz,
      remainder: &pitClockRemainder
    )
    let rtcTicks = scaledDeviceTicks(
      machineTicks: ticks,
      frequencyHz: DoryPCRTC146818.oscillatorFrequency,
      remainder: &rtcClockRemainder
    )
    legacyPIT.advance(by: pitTicks)
    rtc.advance(by: rtcTicks)
    hpet.advance(by: ticks)
    let pmTimerTicks = scaledDeviceTicks(
      machineTicks: ticks,
      frequencyHz: DoryPCPowerController.pmTimerFrequencyHz,
      remainder: &pmTimerClockRemainder
    )
    powerController.advancePMTimer(by: pmTimerTicks)
  }

  private func advanceTSCs(byMachineTicks ticks: UInt64) {
    guard ticks > 0 else { return }
    let tscTicks = scaledDeviceTicks(
      machineTicks: ticks,
      frequencyHz: interpreter.profile.virtualTSCFrequencyHz,
      remainder: &tscClockRemainder
    )
    for slot in processorSlots {
      slot.state?.value.tsc &+= tscTicks
    }
  }

  /// Samples elapsed host time and advances one coherent 10 MHz machine epoch. The remainder is
  /// retained so repeated sub-100 ns samples cannot lose time. Guest-visible state stores only
  /// virtual ticks; the host uptime sample is disposable launch-local authority.
  private func synchronizeHostClock() {
    guard let sample = clockSource.monotonicNanoseconds else { return }
    let now = sample()
    let discontinuity = clockSource.discontinuityGeneration()
    guard hostClockDiscontinuityGeneration == discontinuity else {
      hostClockDiscontinuityGeneration = discontinuity
      lastHostClockNanoseconds = now
      hostClockNanosecondRemainder = 0
      return
    }
    guard let previous = lastHostClockNanoseconds else {
      lastHostClockNanoseconds = now
      return
    }
    guard now >= previous else { return }
    lastHostClockNanoseconds = now
    let elapsed = now - previous
    let wholeTicks = elapsed / 100
    let fractionalNanoseconds = hostClockNanosecondRemainder + elapsed % 100
    let ticks = wholeTicks &+ fractionalNanoseconds / 100
    hostClockNanosecondRemainder = fractionalNanoseconds % 100
    guard ticks > 0 else { return }
    advanceClocks(by: ticks)
    advanceTSCs(byMachineTicks: ticks)
  }

  private func scaledDeviceTicks(
    machineTicks: UInt64,
    frequencyHz: UInt64,
    remainder: inout UInt64
  ) -> UInt64 {
    let wholeSeconds = machineTicks / Self.machineClockFrequencyHz
    let fractionalMachineTicks = machineTicks % Self.machineClockFrequencyHz
    // Split both factors before multiplying: the fractional product is below 10^14
    // even for an arbitrary UInt64 TSC rate. Only the delivered counter may wrap.
    let wholeRate = frequencyHz / Self.machineClockFrequencyHz
    let fractionalRate = frequencyHz % Self.machineClockFrequencyHz
    let fractional = remainder + fractionalMachineTicks * fractionalRate
    remainder = fractional % Self.machineClockFrequencyHz
    return machineTicks &* wholeRate &+ wholeSeconds &* fractionalRate
      &+ fractional / Self.machineClockFrequencyHz
  }

  private func machineTicks(
    untilDeviceTicks deviceTicks: UInt64,
    frequencyHz: UInt64,
    remainder: UInt64
  ) -> UInt64 {
    guard deviceTicks > 0 else { return 0 }
    let numerator = deviceTicks &* Self.machineClockFrequencyHz
    guard numerator > remainder else { return 1 }
    let remaining = numerator - remainder
    return (remaining &+ frequencyHz - 1) / frequencyHz
  }

  private func ticksUntilNextAcceptedInterrupt() -> UInt64? {
    var deadlines: [UInt64] = []
    for (index, apic) in localAPICs.enumerated() {
      guard let state = processorSlots[index].state?.value else { continue }
      let timer = apic.snapshot().timer
      if !timer.masked, timer.currentCount > 0,
        apic.canAccept(
          vector: timer.vector,
          interruptsEnabled: maskableInterruptsEnabled(state),
          externalPriority: UInt8(truncatingIfNeeded: state.control.cr8) << 4
        )
      {
        if let baseClockTicks = apic.baseClockTicksUntilTimerExpiration() {
          deadlines.append(
            machineTicks(
              untilDeviceTicks: baseClockTicks,
              frequencyHz: Self.localAPICClockFrequencyHz,
              remainder: localAPICClockRemainder
            )
          )
        }
      }
    }
    if let bsp = processorSlots[0].state?.value {
      let interruptsEnabled = maskableInterruptsEnabled(bsp)
      let pit = legacyPIT.snapshot()
      let picAcceptsTimer = legacyPIC.canAccept(irq: 0, interruptsEnabled: interruptsEnabled)
      let ioAPICAcceptsTimer = ioAPICCanAccept(pin: 2)
      if pit.armed, pit.current > 0, picAcceptsTimer || ioAPICAcceptsTimer {
        deadlines.append(
          machineTicks(
            untilDeviceTicks: UInt64(pit.current),
            frequencyHz: Self.pitFrequencyHz,
            remainder: pitClockRemainder
          )
        )
      }
      if let ticks = rtc.ticksUntilNextInterrupt(), ticks > 0,
        legacyPIC.canAccept(irq: 8, interruptsEnabled: interruptsEnabled)
          || ioAPICCanAccept(pin: 8)
      {
        deadlines.append(
          machineTicks(
            untilDeviceTicks: ticks,
            frequencyHz: DoryPCRTC146818.oscillatorFrequency,
            remainder: rtcClockRemainder
          )
        )
      }
      for deadline in hpet.interruptDeadlines() {
        let picAccepts: Bool
        if case .legacyIRQ(let irq) = deadline.route {
          picAccepts = legacyPIC.canAccept(irq: irq, interruptsEnabled: interruptsEnabled)
        } else {
          picAccepts = false
        }
        if picAccepts || ioAPICCanAccept(pin: Self.ioAPICPin(forHPETRoute: deadline.route)) {
          deadlines.append(deadline.ticks)
        }
      }
    }
    return deadlines.min()
  }

  private static func ioAPICPin(forHPETRoute route: DoryPCHPETInterruptRoute) -> Int {
    switch route {
    // Match the PIT source and the IRQ0 -> GSI2 override in DoryPC-v1's MADT.
    case .legacyIRQ(0): 2
    case .legacyIRQ(let irq): Int(irq)
    case .ioAPICPin(let pin): pin
    }
  }

  private func ioAPICCanAccept(pin: Int) -> Bool {
    (try? ioAPIC.canDeliver(pin: pin) { [self] apic, vector in
      guard let index = processorIndex(apic.apicID),
        let state = processorSlots[index].state?.value
      else {
        return false
      }
      return apic.canAccept(
        vector: vector,
        interruptsEnabled: maskableInterruptsEnabled(state),
        externalPriority: UInt8(truncatingIfNeeded: state.control.cr8) << 4
      )
    }) ?? false
  }

  private func powerStop(instructionCount: UInt64) -> DoryPCMachineStop? {
    switch powerController.consumeRequestedAction() {
    case .powerOff: return .poweredOff(instructionCount: instructionCount)
    case .reset: return .reset(instructionCount: instructionCount)
    case nil: return nil
    }
  }

  private func applyProcessorEvents() {
    // Free-running workers publish a yield before the coordinator reaches this point, so the
    // execution gate owns every lifecycle transition and can drain destination mailboxes here.
    for processor in 0..<processorCount {
      applyProcessorEvents(forProcessor: processor)
    }
  }

  /// Applies only the control events owned by the selected processor's APIC.
  ///
  /// The caller owns the execution gate and has rendezvoused all other workers.
  func applyProcessorEvents(forProcessor processor: Int) {
    guard localAPICs.indices.contains(processor) else { return }
    let slot = processorSlots[processor]
    let apicID = localAPICs[processor].apicID
    for event in multiprocessorController.drainEvents(forAPICID: apicID) {
      switch event {
      case .initialize(let targetAPICID):
        guard targetAPICID == apicID else { continue }
        let coherentTSC = processorSlots[0].state?.value.tsc ?? slot.state?.value.tsc ?? 0
        slot.lifecycle = .waitingForStartup
        var state = applicationProcessorResetState()
        state.tsc = coherentTSC
        slot.state = ProcessorState(state)
        slot.isHalted = true
        slot.hasPendingNMI = false
      case .startup(let targetAPICID, let vector):
        guard targetAPICID == apicID else { continue }
        slot.lifecycle = .running
        var state = applicationProcessorResetState()
        state.tsc = processorSlots[0].state?.value.tsc ?? slot.state?.value.tsc ?? 0
        state.rip = 0
        state.cs = .init(
          selector: UInt16(vector) << 8,
          attributes: 0x009B,
          limit: 0xFFFF,
          base: UInt64(vector) << 12
        )
        slot.state = ProcessorState(state)
        slot.isHalted = false
      case .nonMaskableInterrupt(let targetAPICID):
        guard targetAPICID == apicID else { continue }
        slot.hasPendingNMI = true
      }
    }
  }

  private func deliverPendingInterrupts(instructionCount: UInt64) throws -> DoryPCMachineStop? {
    for index in processorSlots.indices {
      if let stop = try deliverPendingInterrupt(
        forProcessor: index,
        instructionCount: instructionCount
      ) {
        return stop
      }
    }
    return nil
  }

  /// Delivers only the selected processor's pending NMI or maskable interrupt. Callers must own
  /// that processor's architectural state. Device controllers retain their own synchronization;
  /// no session lock is held across acknowledgement or architectural delivery.
  private func deliverPendingInterrupt(
    forProcessor index: Int,
    instructionCount: UInt64,
    observer: (@Sendable (WorkerEvent) -> Void)? = nil
  ) throws -> DoryPCMachineStop? {
    guard processorSlots.indices.contains(index) else { return nil }
    let slot = processorSlots[index]
    guard let processorState = slot.state,
      slot.lifecycle == .running
    else { return nil }
    let source: DoryX86InterruptSource
    let vector: UInt8?
    if slot.hasPendingNMI, !processorState.value.nmiBlocked,
      processorState.value.interruptShadow != .movSS
    {
      // Recognition consumes the coalesced request before delivery. NMI blocking has already
      // been checked, so a deferred request remains queued until IRET unblocks the processor.
      slot.hasPendingNMI = false
      source = .nonMaskable
      vector = 2
    } else {
      source = .externalMaskable
      // Acknowledgement consumes controller state. Keep the vector pending while STI/MOV SS
      // inhibition prevents the processor accepting it.
      let enabled = maskableInterruptsEnabled(processorState.value)
      vector =
        localAPICs[index].acknowledge(
          interruptsEnabled: enabled,
          externalPriority: UInt8(truncatingIfNeeded: processorState.value.control.cr8) << 4
        ) ?? (index == 0 ? legacyPIC.acknowledge(interruptsEnabled: enabled) : nil)
    }
    guard let vector else { return nil }
    observer?(.deliveringInterrupt(index, vector: vector))
    do {
      try DoryX86InterruptDelivery(profile: interpreter.profile).deliverEvent(
        vector: vector,
        source: source,
        state: &processorState.value,
        physicalMemory: physicalMemories[index],
        pagingUnit: pagingUnits[index],
        mode: executionMode(processorState.value)
      )
      switch source {
      case .externalMaskable:
        slot.deliveredMaskableInterrupts &+= 1
      case .nonMaskable:
        slot.deliveredNonMaskableInterrupts &+= 1
      case .hardwareException, .software:
        break
      }
      slot.deliveredInterruptVectors[vector, default: 0] &+= 1
      slot.isHalted = false
      return nil
    } catch DoryX86InterruptDeliveryError.processorShutdown {
      return .tripleFault(
        source: .interrupt(vector: vector, source: source, processor: index),
        instructionCount: instructionCount
      )
    }
  }

  private func maskableInterruptsEnabled(_ state: DoryX86ArchitecturalState) -> Bool {
    state.interruptShadow == nil && state.rflags.contains(.interruptEnable)
  }

  private func nextRunnableProcessor() -> Int? {
    for displacement in 0..<processorCount {
      let index = (roundRobinCursor + displacement) % processorCount
      let slot = processorSlots[index]
      guard slot.state != nil, !slot.isHalted,
        slot.lifecycle == .running
      else { continue }
      roundRobinCursor = (index + 1) % processorCount
      return index
    }
    return nil
  }

  // Allows tests to coordinate asynchronous device requests with the actual condition wait.
  func waitUntilIdle(until deadline: Date) -> Bool {
    pendingWorkWake.waitUntilWaiting(until: deadline)
  }

  private func waitForNextInterrupt(after generation: DoryPCPendingWorkWake.Snapshot) -> Bool {
    let ticks = ticksUntilNextAcceptedInterrupt()
    if clockSource.monotonicNanoseconds != nil {
      // Timer waits retain their 1 ms cap. With no deadline, recheck lifecycle/device state at
      // least every 50 ms; timeout is never evidence that a production machine has stopped.
      let interval = ticks.map { Double(min($0, 10_000)) / 10_000_000 } ?? 0.05
      pendingWorkWake.wait(after: generation, until: Date(timeIntervalSinceNow: interval))
      synchronizeHostClock()
      return true
    }
    // Deterministic mode neither waits on host time nor invents a timer when none is armed.
    if pendingWorkWake.snapshot() != generation { return true }
    guard let ticks else { return false }
    advanceClocks(by: ticks)
    advanceTSCs(byMachineTicks: ticks)
    return true
  }

  private func waitForNextInterrupt(forProcessor processor: Int, after generation: UInt64) -> Bool {
    let ticks = ticksUntilNextAcceptedInterrupt()
    if clockSource.monotonicNanoseconds != nil {
      let interval = ticks.map { Double(min($0, 10_000)) / 10_000_000 } ?? 0.05
      pendingWorkWake.wait(
        forProcessor: processor,
        after: generation,
        until: Date(timeIntervalSinceNow: interval)
      )
      synchronizeHostClock()
      return true
    }
    if pendingWorkWake.snapshot(forProcessor: processor) != generation { return true }
    guard let ticks else { return false }
    advanceClocks(by: ticks)
    advanceTSCs(byMachineTicks: ticks)
    return true
  }

  private func applicationProcessorResetState() -> DoryX86ArchitecturalState {
    var state = DoryX86ArchitecturalState.reset()
    state.modelSpecific.apicBase &= ~(1 << 8)
    return state
  }

  private func processorIndex(_ apicID: UInt32) -> Int? {
    localAPICs.firstIndex(where: { $0.apicID == apicID })
  }

  private func executionMode(_ state: DoryX86ArchitecturalState) -> DoryX86ExecutionMode {
    guard state.control.cr0 & 1 != 0 else { return .real16 }
    if state.control.efer & (1 << 10) != 0, state.cs.attributes & 0x2000 != 0 {
      return .long64
    }
    return state.cs.attributes & 0x4000 == 0 ? .protected16 : .protected32
  }

  private func currentPrivilegeLevel(
    _ state: DoryX86ArchitecturalState,
    mode: DoryX86ExecutionMode
  ) -> UInt8 {
    if mode == .real16 { return 0 }
    if mode != .long64, state.control.efer & (1 << 10) == 0,
      state.rflags.contains(.virtual8086)
    {
      return 3
    }
    return UInt8(state.cs.selector & 3)
  }
}

private final class DoryPCPCIINTxRouter: @unchecked Sendable {
  private let ioAPIC: DoryPCIOAPIC
  private let lock = NSLock()
  private var sourcesByLine: [Int: Set<ObjectIdentifier>] = [:]

  init(ioAPIC: DoryPCIOAPIC) {
    self.ioAPIC = ioAPIC
  }

  func setAsserted(_ asserted: Bool, line: Int, source: ObjectIdentifier) {
    guard (0..<ioAPIC.pinCount).contains(line) else { return }
    let transition: Bool? = lock.withLock {
      let wasAsserted = !(sourcesByLine[line] ?? []).isEmpty
      if asserted {
        sourcesByLine[line, default: []].insert(source)
      } else {
        sourcesByLine[line]?.remove(source)
        if sourcesByLine[line]?.isEmpty == true { sourcesByLine[line] = nil }
      }
      let isAsserted = !(sourcesByLine[line] ?? []).isEmpty
      return wasAsserted == isAsserted ? nil : isAsserted
    }
    if let transition { try? ioAPIC.setAsserted(transition, pin: line) }
  }
}
