import Dispatch
import DoryDBTX86
import DoryPlatformC
import Foundation

/// Device callbacks may hold their own locks. This leaf lock never calls out or acquires the
/// machine execution lock, and the dispatcher releases it before touching any device state.
private final class DoryPCPendingWorkWake: @unchecked Sendable {
  private let condition = NSCondition()
  private var generation: UInt64 = 0
  private var waiting = false
  private var dispatchThread: Thread?

  func setDispatchThread(_ thread: Thread?) {
    condition.lock()
    dispatchThread = thread
    condition.unlock()
  }

  func snapshot() -> UInt64 {
    condition.lock()
    defer { condition.unlock() }
    return generation
  }

  func signal() {
    condition.lock()
    // Synchronous device work is already owned by this dispatch pass. In particular PIC
    // acknowledgement republishes masked requests: treating that as an asynchronous edge
    // would spin forever on an undeliverable IRQ (and advance deterministic time).
    if dispatchThread !== Thread.current {
      generation &+= 1
      condition.broadcast()
    }
    condition.unlock()
  }

  func wait(after observed: UInt64, until deadline: Date) {
    condition.lock()
    defer {
      waiting = false
      condition.unlock()
    }
    // Compare with the generation captured BEFORE dispatch drained the controllers. An edge
    // between that drain and this wait must force another pass, even if its signal came early.
    while generation == observed {
      waiting = true
      condition.broadcast()
      if !condition.wait(until: deadline) { break }
    }
  }

  // Internal synchronization for production-boundary tests; no callbacks run under either lock.
  func waitUntilWaiting(until deadline: Date) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    while !waiting {
      if !condition.wait(until: deadline) { return waiting }
    }
    return true
  }
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
  /// The only raw-target boundary with retained repeated PVH acceptance. Legacy direct sources,
  /// the IBTC and the shadow-return stack remain explicit experiments after the combined-source
  /// configuration reproduced guest memory corruption and an unbounded native quantum.
  public static let defaultRawTargetPredictionOptions: DoryARM64RawTargetPredictionOptions =
    .tier1DirectChain

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

  // A worker exclusively borrows its processor's state during a job. The coordinator may
  // access it only after completion (including clock/interrupt delivery and lifecycle setup).
  // The same rendezvous protects shared translation metadata and collection mutations.
  // A parallel native job borrows only its own executor, with no guest-memory authority.
  final class ProcessorState: @unchecked Sendable {
    var value: DoryX86ArchitecturalState

    init(_ value: DoryX86ArchitecturalState) {
      self.value = value
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
  private let pendingWorkWake = DoryPCPendingWorkWake()
  // `run` reserves the execution gate while transferring ownership to dedicated workers.
  // No mutex remains held during guest execution. Observability must not
  // contend for that lock: a lifecycle telemetry request is served on another queue while the VM
  // is executing and would otherwise wait until the full quantum retired (or deadlock its socket
  // deadline). Publish an immutable snapshot after every quantum under a dedicated short lock.
  private let executionStatisticsLock = NSLock()
  private let hostExecutionDiagnosticsLock = NSLock()
  private var loadedStates: [ProcessorState?]
  private var haltedProcessors: [Bool]
  private var processorLifecycles: [DoryPCProcessorLifecycle]
  private var pendingNMIs: Set<Int> = []
  private var roundRobinCursor = 0
  private var consumedPayload = false
  private let baselineJITs: [DoryARM64BaselineExecutor]
  private let optimizingJITs: [DoryARM64BaselineExecutor]
  private let optimizingJITWarmupDispatches: UInt8
  private struct JITHotnessEntry {
    var tag: UInt64 = 0
    var dispatchCount: UInt8 = 0
  }
  // A bounded direct-mapped table keeps full-system cold-start accounting independent of the
  // number of distinct firmware, kernel, and initramfs RIPs. A collision merely delays promotion;
  // it cannot affect architectural behavior or cache correctness.
  private var jitHotness = [JITHotnessEntry](repeating: .init(), count: 1 << 16)
  private let translatedMemories: [DoryX86TranslatedMemory]
  private var interpreterInstructionCount: UInt64 = 0
  private var baselineJITInstructionCount: UInt64 = 0
  private var baselineJITBlockCount: UInt64 = 0
  private var optimizingJITInstructionCount: UInt64 = 0
  private var optimizingJITBlockCount: UInt64 = 0
  private var deliveredMaskableInterruptCount: UInt64 = 0
  private var deliveredNonMaskableInterruptCount: UInt64 = 0
  private var retiredInterruptReturnCount: UInt64 = 0
  private var deliveredInterruptVectorCounts: [UInt8: UInt64] = [:]
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
    self.processorCount = processorCount
    self.executionTier = executionTier
    self.jitWriteCoherencePolicy = jitWriteCoherencePolicy
    self.optimizingJITWarmupDispatches = optimizingJITWarmupDispatches
    self.clockSource = clockSource
    self.instrumentationEnabled = instrumentationEnabled
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
            tracksInterpreterFallback: true
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
            tracksInterpreterFallback: true
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
      if createdBaselineJITs.indices.contains(processor) {
        createdBaselineJITs[processor].requestPendingWork()
      }
      if createdOptimizingJITs.indices.contains(processor) {
        createdOptimizingJITs[processor].requestPendingWork()
      }
      pendingWorkWake.signal()
    }
    let requestPendingWorkForAllProcessors: @Sendable () -> Void = {
      [createdBaselineJITs, createdOptimizingJITs, pendingWorkWake] in
      for jit in createdBaselineJITs { jit.requestPendingWork() }
      for jit in createdOptimizingJITs { jit.requestPendingWork() }
      pendingWorkWake.signal()
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
        logicalProcessorCount: UInt16(processorCount)
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
    loadedStates = [ProcessorState?](repeating: nil, count: processorCount)
    haltedProcessors = [Bool](repeating: false, count: processorCount)
    processorLifecycles = (0..<processorCount).map {
      $0 == 0 ? .running : .waitingForStartup
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
      loadedStates[0] = ProcessorState(initialState)
      for index in 1..<processorCount {
        loadedStates[index] = ProcessorState(applicationProcessorResetState())
      }
      haltedProcessors = [Bool](repeating: false, count: processorCount)
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
      loadedStates[0] = ProcessorState(initialState)
      for index in 1..<processorCount {
        loadedStates[index] = ProcessorState(applicationProcessorResetState())
      }
      haltedProcessors = [Bool](repeating: false, count: processorCount)
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
    lock.withLock { loadedStates.indices.contains(index) ? loadedStates[index]?.value : nil }
  }

  public var processorExecutionSnapshots: [DoryPCProcessorExecutionSnapshot] {
    lock.withLock {
      loadedStates.indices.map { index in
        let state = loadedStates[index]?.value
        let mode = state.map { executionMode($0) }
        let privilegeLevel = state.flatMap { state in
          mode.map { currentPrivilegeLevel(state, mode: $0) }
        }
        return .init(
          index: index,
          lifecycle: processorLifecycles[index],
          isHalted: haltedProcessors[index],
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
      guard loadedStates.indices.contains(index), let state = loadedStates[index]?.value else {
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
      guard loadedStates.indices.contains(index), let state = loadedStates[index]?.value else {
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
      guard loadedStates[0] != nil else { throw DoryPCMachineError.notLoaded }
      pendingWorkWake.setDispatchThread(Thread.current)
      defer { pendingWorkWake.setDispatchThread(nil) }
      // Validate installed latches before consuming device events, advancing clocks, or
      // entering either execution tier. Guest RAM is not a substitute for latched state.
      for processorState in loadedStates {
        try processorState?.value.control.validateLegacyPAEPDPTEs(
          physicalAddressBits: interpreter.profile.physicalAddressBits
        )
      }
      let observer = workerObserver
      let workers = (0..<processorCount).map { processor in
        DoryPCHostWorker(processor: processor, instrumentationEnabled: instrumentationEnabled) {
          observer?(.stopped(processor))
        }
      }
      let freeRunCompletions = workers.map { $0.beginFreeRun() }
      let runTimeSample = hostTimeSample()
      defer {
        // Every return and throw joins every worker before publishing or releasing the gate.
        // A sticky stop wakes an empty mailbox as well as a worker finishing bounded work.
        for worker in workers { worker.stopFreeRun() }
        for worker in workers { worker.requestStop() }
        for worker in workers { worker.stopAndJoin() }
        // The free-running job is the only mailbox job at shutdown. Observe its completion so a
        // future change cannot accidentally conceal a worker-side failure after the join.
        for completion in freeRunCompletions { _ = try? completion.wait() }
        for worker in workers {
          saturatingAdd(worker.executionCPUNanoseconds, to: &hostThreadCPUTime.totalNanoseconds)
          saturatingAdd(worker.eventCPUNanoseconds, to: &hostThreadCPUTime.totalNanoseconds)
          saturatingAdd(
            worker.executionCPUNanoseconds, to: &hostThreadCPUTime.processorExecutionNanoseconds)
          saturatingAdd(
            worker.eventCPUNanoseconds, to: &hostThreadCPUTime.processorEventNanoseconds)
        }
        recordTotalHostTime(since: runTimeSample)
        for memory in physicalMemories { memory.publishDiagnostics() }
        publishExecutionStatistics()
        publishHostExecutionDiagnostics()
      }
      var completed: UInt64 = 0
      while completed < maximumInstructions {
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
        // Every pending controller and lifecycle source has crossed the dispatcher boundary. A
        // later device edge sets the byte again and is observed at the next native block entry.
        for jit in baselineJITs { jit.clearPendingWork() }
        for jit in optimizingJITs { jit.clearPendingWork() }
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
            for plan in plans {
              workers[plan.processor].scheduleFreeRunExecution { [self] in
                observer?(.executing(plan.processor, concurrent: true))
                defer { observer?(.executed(plan.processor, concurrent: true)) }
                return try executeParallelInstruction(plan, observer: observer)
              }
            }
            // Collect every result before publishing state-dependent machine accounting.
            let executions = try plans.map { try workers[$0.processor].awaitFreeRunExecution() }
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
        guard let processorState = loadedStates[processor] else { continue }
        let remaining = maximumInstructions - completed
        let jitInstructionBudget =
          baselineJITs.isEmpty ? nil : baselineInstructionBudget(maximumInstructions: remaining)
        let execution: ProcessorExecution
        if instrumentationEnabled {
          let sample = hostTimeSample()
          workers[processor].scheduleFreeRunExecution { [self] in
            pendingWorkWake.setDispatchThread(Thread.current)
            defer { pendingWorkWake.setDispatchThread(nil) }
            observer?(.executing(processor, concurrent: false))
            defer { observer?(.executed(processor, concurrent: false)) }
            return try execute(
              processor: processor,
              state: &processorState.value,
              maximumInstructions: remaining,
              jitInstructionBudget: jitInstructionBudget
            )
          }
          execution = try workers[processor].awaitFreeRunExecution()
          pendingWorkWake.setDispatchThread(Thread.current)
          recordHostTime(.processorExecution, since: sample)
        } else {
          workers[processor].scheduleFreeRunExecution { [self] in
            pendingWorkWake.setDispatchThread(Thread.current)
            defer { pendingWorkWake.setDispatchThread(nil) }
            observer?(.executing(processor, concurrent: false))
            defer { observer?(.executed(processor, concurrent: false)) }
            return try execute(
              processor: processor,
              state: &processorState.value,
              maximumInstructions: remaining,
              jitInstructionBudget: jitInstructionBudget
            )
          }
          execution = try workers[processor].awaitFreeRunExecution()
          pendingWorkWake.setDispatchThread(Thread.current)
        }
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
          haltedProcessors[processor] = false
          continue
        case .halted:
          haltedProcessors[processor] = true
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

  // Test observation is installed only while quiescent and copied before workers start.
  // Callbacks must not reenter gate-protected public machine operations.
  enum WorkerEvent: Sendable {
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
      guard let state = loadedStates[processor], !haltedProcessors[processor],
        processorLifecycles[processor] == .running
      else { continue }
      workers[processor].scheduleFreeRunAdmission { [self] () -> ParallelInstruction? in
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
      let plan = try workers[processor].awaitFreeRunAdmission()
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
    let snapshot = DoryPCExecutionStatistics(
      interpreterInstructions: interpreterInstructionCount,
      baselineJITInstructions: baselineJITInstructionCount,
      baselineJITBlocks: baselineJITBlockCount,
      optimizingJITInstructions: optimizingJITInstructionCount,
      optimizingJITBlocks: optimizingJITBlockCount,
      deliveredMaskableInterrupts: deliveredMaskableInterruptCount,
      deliveredNonMaskableInterrupts: deliveredNonMaskableInterruptCount,
      retiredInterruptReturns: retiredInterruptReturnCount,
      deliveredInterruptVectors:
        deliveredInterruptVectorCounts
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

  private func execute(
    processor: Int,
    state: inout DoryX86ArchitecturalState,
    maximumInstructions: UInt64,
    jitInstructionBudget: Int?
  ) throws -> ProcessorExecution {
    if translatedMemories[processor].consumePendingPageTableWrite() {
      for pagingUnit in pagingUnits { pagingUnit.invalidateAll() }
    }
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
        retiredInterruptReturnCount &+= 1
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
    let index = Int(tag & UInt64(jitHotness.count - 1))
    if jitHotness[index].tag != tag {
      jitHotness[index] = .init(tag: tag, dispatchCount: 1)
      return baselineJIT
    }
    if jitHotness[index].dispatchCount < optimizingJITWarmupDispatches {
      jitHotness[index].dispatchCount &+= 1
    }
    return jitHotness[index].dispatchCount >= optimizingJITWarmupDispatches
      ? optimizingJIT : baselineJIT
  }

  private func baselineInstructionBudget(maximumInstructions: UInt64) -> Int {
    // SMP fairness keeps a 64-instruction quantum while multiple processors can run. Once every
    // other processor has parked, a larger bounded quantum avoids needless Swift round trips.
    // Interrupt deadlines below still shorten either batch whenever observable work is due sooner.
    let runnableProcessorCount = loadedStates.indices.lazy.filter {
      self.loadedStates[$0] != nil && !self.haltedProcessors[$0]
        && self.processorLifecycles[$0] == .running
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
    for index in loadedStates.indices {
      loadedStates[index]?.value.tsc &+= tscTicks
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
      guard let state = loadedStates[index]?.value else { continue }
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
    if let bsp = loadedStates[0]?.value {
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
      guard let index = processorIndex(apic.apicID), let state = loadedStates[index]?.value else {
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
    let apicID = localAPICs[processor].apicID
    for event in multiprocessorController.drainEvents(forAPICID: apicID) {
      switch event {
      case .initialize(let targetAPICID):
        guard targetAPICID == apicID else { continue }
        let coherentTSC = loadedStates[0]?.value.tsc ?? loadedStates[processor]?.value.tsc ?? 0
        processorLifecycles[processor] = .waitingForStartup
        var state = applicationProcessorResetState()
        state.tsc = coherentTSC
        loadedStates[processor] = ProcessorState(state)
        haltedProcessors[processor] = true
        pendingNMIs.remove(processor)
      case .startup(let targetAPICID, let vector):
        guard targetAPICID == apicID else { continue }
        processorLifecycles[processor] = .running
        var state = applicationProcessorResetState()
        state.tsc = loadedStates[0]?.value.tsc ?? loadedStates[processor]?.value.tsc ?? 0
        state.rip = 0
        state.cs = .init(
          selector: UInt16(vector) << 8,
          attributes: 0x009B,
          limit: 0xFFFF,
          base: UInt64(vector) << 12
        )
        loadedStates[processor] = ProcessorState(state)
        haltedProcessors[processor] = false
      case .nonMaskableInterrupt(let targetAPICID):
        guard targetAPICID == apicID else { continue }
        pendingNMIs.insert(processor)
      }
    }
  }

  private func deliverPendingInterrupts(instructionCount: UInt64) throws -> DoryPCMachineStop? {
    for index in loadedStates.indices {
      guard let processorState = loadedStates[index],
        processorLifecycles[index] == .running
      else { continue }
      let source: DoryX86InterruptSource
      let vector: UInt8?
      if pendingNMIs.contains(index), !processorState.value.nmiBlocked,
        processorState.value.interruptShadow != .movSS
      {
        // Recognition consumes the coalesced request before delivery. NMI
        // blocking has already been checked, so a deferred request remains
        // queued and retains priority as soon as IRET unblocks the processor.
        pendingNMIs.remove(index)
        source = .nonMaskable
        vector = 2
      } else {
        source = .externalMaskable
        // Acknowledgement consumes controller state. Keep the vector pending
        // while STI/MOV SS inhibition prevents the processor accepting it.
        let enabled = maskableInterruptsEnabled(processorState.value)
        vector =
          localAPICs[index].acknowledge(
            interruptsEnabled: enabled,
            externalPriority: UInt8(truncatingIfNeeded: processorState.value.control.cr8) << 4
          ) ?? (index == 0 ? legacyPIC.acknowledge(interruptsEnabled: enabled) : nil)
      }
      guard let vector else { continue }
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
          deliveredMaskableInterruptCount &+= 1
        case .nonMaskable:
          deliveredNonMaskableInterruptCount &+= 1
        case .hardwareException, .software:
          break
        }
        deliveredInterruptVectorCounts[vector, default: 0] &+= 1
        haltedProcessors[index] = false
      } catch DoryX86InterruptDeliveryError.processorShutdown {
        return .tripleFault(
          source: .interrupt(vector: vector, source: source, processor: index),
          instructionCount: instructionCount
        )
      }
    }
    return nil
  }

  private func maskableInterruptsEnabled(_ state: DoryX86ArchitecturalState) -> Bool {
    state.interruptShadow == nil && state.rflags.contains(.interruptEnable)
  }

  private func nextRunnableProcessor() -> Int? {
    for displacement in 0..<processorCount {
      let index = (roundRobinCursor + displacement) % processorCount
      guard loadedStates[index] != nil, !haltedProcessors[index],
        processorLifecycles[index] == .running
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

  private func waitForNextInterrupt(after generation: UInt64) -> Bool {
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
