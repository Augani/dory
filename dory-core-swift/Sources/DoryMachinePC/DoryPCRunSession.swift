import DoryDBTX86
import Foundation

/// Machine-scoped coordination state for one free-running vCPU run.
///
/// The condition protects metadata only. Callers must not enter guest code, call a device, acquire
/// RAM range authority, or deliver an interrupt while holding it. Architectural state remains
/// owned by its vCPU worker; this object coordinates reservations, handoffs, counters, and
/// generations without taking architectural ownership.
final class DoryPCRunSession: @unchecked Sendable {
  enum ClockMode: Sendable, Equatable {
    case deterministic
    case hostMonotonic
  }

  struct Reservation: Sendable, Equatable {
    let processor: Int
    let sequence: UInt64
    let instructionCount: UInt64
  }

  enum WorkerOutcome: Sendable, Equatable {
    case preparedFrozenInstruction(Bool)
    case retired
    case yielded
    case halted
    case exception(DoryX86Exception)
    case tripleFault(DoryPCTripleFaultSource)
    case hostFailure
  }

  /// Run-local counters are published by the owning worker with its architectural result. The
  /// session merges them exactly once, before making that result visible to the coordinator.
  struct WorkerCounters: Sendable, Equatable {
    var instructionCount: UInt64 = 0
    var interpreterInstructions: UInt64 = 0
    var baselineJITInstructions: UInt64 = 0
    var baselineJITBlocks: UInt64 = 0
    var optimizingJITInstructions: UInt64 = 0
    var optimizingJITBlocks: UInt64 = 0
    var interpreterFallbackJITInstructions: UInt64 = 0
    var executionCPUNanoseconds: UInt64 = 0
    var eventCPUNanoseconds: UInt64 = 0

    static let zero = Self()
  }

  struct WorkerResult: Sendable, Equatable {
    let runGeneration: UInt64
    let processor: Int
    let sequence: UInt64
    let reservationSequence: UInt64
    /// Last machine pending-work generation drained by this worker before publishing the result.
    /// The coordinator uses this exact acknowledgement when deciding whether a halted worker may
    /// sleep; sampling the shared generation after publication could erase a racing device edge.
    let acknowledgedPendingWorkGeneration: UInt64
    let outcome: WorkerOutcome
    let counters: WorkerCounters
  }

  enum WorkerDirective: Sendable, Equatable {
    case resume
    case stop
  }

  struct WorkerDirectiveEnvelope: Sendable, Equatable {
    let runGeneration: UInt64
    let processor: Int
    let resultSequence: UInt64
    let directive: WorkerDirective
  }

  enum TerminationReason: Sendable, Equatable {
    case hostFailure(processor: Int)
    case tripleFault(processor: Int)
    case reset
    case powerOff
    case cancelled
    case instructionBudget

    fileprivate var priority: (Int, Int) {
      switch self {
      case .hostFailure(let processor): (0, processor)
      case .tripleFault(let processor): (1, processor)
      case .reset: (2, 0)
      case .powerOff: (3, 0)
      case .cancelled: (4, 0)
      case .instructionBudget: (5, 0)
      }
    }
  }

  enum SessionError: Error, Sendable, Equatable {
    case invalidProcessor(Int)
    case invalidMaximumReservation(UInt64)
    case outstandingReservation(Int)
    case missingReservation(Int)
    case staleReservation(processor: Int, expected: UInt64, actual: UInt64)
    case retiredBeyondReservation(retired: UInt64, reserved: UInt64)
    case inconsistentWorkerCounters(processor: Int)
    case counterOverflow(processor: Int)
    case outstandingWorkerResult(Int)
    case outstandingWorkerDirective(Int)
    case staleRunGeneration(expected: UInt64, actual: UInt64)
    case missingWorkerResult(Int)
    case staleWorkerResult(processor: Int, expected: UInt64, actual: UInt64)
    case mismatchedWorkerResult(processor: Int, sequence: UInt64)
    case missingWorkerDirective(Int)
    case staleWorkerDirective(processor: Int, expected: UInt64, actual: UInt64)
  }

  struct Snapshot: Sendable, Equatable {
    let runGeneration: UInt64
    let exceptionPolicy: DoryPCExceptionPolicy
    let clockMode: ClockMode
    let initialInstructionBudget: UInt64
    let remainingInstructionBudget: UInt64
    let outstandingReservations: [Reservation?]
    let retiredInstructions: [UInt64]
    let totalRetiredInstructions: UInt64
    let pendingSourceGenerations: [UInt64?]
    let pendingRequiredGenerations: [UInt64]
    let pendingAcknowledgedGenerations: [UInt64]
    let pendingRepublishAfterAcknowledgement: [Bool]
    let quiescenceGeneration: UInt64
    let quiescenceRequiredGenerations: [UInt64]
    let quiescenceAcknowledgedGenerations: [UInt64]
    let workerResults: [WorkerResult?]
    let workerDirectives: [WorkerDirectiveEnvelope?]
    let workerCounters: [WorkerCounters]
    let mergedWorkerCounters: WorkerCounters
    let terminationReason: TerminationReason?
    let changeGeneration: UInt64
  }

  private let condition = NSCondition()
  let processorCount: Int
  let runGeneration: UInt64
  let exceptionPolicy: DoryPCExceptionPolicy
  let clockMode: ClockMode
  private let initialInstructionBudget: UInt64
  private var remainingInstructionBudget: UInt64
  private var reservationSequences: [UInt64]
  private var reservations: [Reservation?]
  private var retiredInstructions: [UInt64]
  private var totalRetiredInstructions: UInt64 = 0
  private var pendingSourceGenerations: [UInt64?]
  private var pendingRequiredGenerations: [UInt64]
  private var pendingAcknowledgedGenerations: [UInt64]
  private var pendingRepublishAfterAcknowledgement: [Bool]
  private var hasRequestedQuiescence = false
  private var quiescenceGeneration: UInt64 = 0
  private var quiescenceRequiredGenerations: [UInt64]
  private var quiescenceAcknowledgedGenerations: [UInt64]
  private var workerResultSequences: [UInt64]
  private var workerResults: [WorkerResult?]
  private var workerDirectives: [WorkerDirectiveEnvelope?]
  private var workerCounters: [WorkerCounters]
  private var mergedWorkerCounters: WorkerCounters = .zero
  private var terminationReason: TerminationReason?
  private var changeGeneration: UInt64 = 0

  init(
    processorCount: Int,
    instructionBudget: UInt64,
    runGeneration: UInt64 = 1,
    exceptionPolicy: DoryPCExceptionPolicy = .stop,
    clockMode: ClockMode = .deterministic,
    initialGeneration: UInt64 = 0
  ) {
    precondition(processorCount > 0)
    self.processorCount = processorCount
    self.runGeneration = runGeneration
    self.exceptionPolicy = exceptionPolicy
    self.clockMode = clockMode
    initialInstructionBudget = instructionBudget
    remainingInstructionBudget = instructionBudget
    reservationSequences = .init(repeating: initialGeneration, count: processorCount)
    reservations = .init(repeating: nil, count: processorCount)
    retiredInstructions = .init(repeating: 0, count: processorCount)
    pendingSourceGenerations = .init(repeating: nil, count: processorCount)
    pendingRequiredGenerations = .init(repeating: initialGeneration, count: processorCount)
    pendingAcknowledgedGenerations = .init(repeating: initialGeneration, count: processorCount)
    pendingRepublishAfterAcknowledgement = .init(repeating: false, count: processorCount)
    quiescenceGeneration = initialGeneration
    quiescenceRequiredGenerations = .init(repeating: initialGeneration, count: processorCount)
    quiescenceAcknowledgedGenerations = .init(repeating: initialGeneration, count: processorCount)
    workerResultSequences = .init(repeating: initialGeneration, count: processorCount)
    workerResults = .init(repeating: nil, count: processorCount)
    workerDirectives = .init(repeating: nil, count: processorCount)
    workerCounters = .init(repeating: .zero, count: processorCount)
    changeGeneration = initialGeneration
    if instructionBudget == 0 { terminationReason = .instructionBudget }
  }

  /// Reserves budget before guest entry. At most one reservation may be outstanding per worker.
  /// Returning `nil` means no budget is currently available or a terminal reason is already set.
  func reserve(processor: Int, maximumInstructions: UInt64) throws -> Reservation? {
    condition.lock()
    defer { condition.unlock() }
    try validate(processor)
    guard maximumInstructions > 0 else {
      throw SessionError.invalidMaximumReservation(maximumInstructions)
    }
    guard reservations[processor] == nil else {
      throw SessionError.outstandingReservation(processor)
    }
    guard workerResults[processor] == nil else {
      throw SessionError.outstandingWorkerResult(processor)
    }
    guard workerDirectives[processor] == nil else {
      throw SessionError.outstandingWorkerDirective(processor)
    }
    guard terminationReason == nil, remainingInstructionBudget > 0 else { return nil }

    let instructionCount = min(maximumInstructions, remainingInstructionBudget)
    let sequence = nextGeneration(after: reservationSequences[processor])
    let reservation = Reservation(
      processor: processor,
      sequence: sequence,
      instructionCount: instructionCount
    )
    reservationSequences[processor] = sequence
    reservations[processor] = reservation
    remainingInstructionBudget -= instructionCount
    changedLocked()
    return reservation
  }

  /// Publishes retired work and returns the unused part of the reservation to the shared budget.
  /// Every validity check happens before mutation, so stale or over-retired completions fail closed.
  func complete(_ reservation: Reservation, retired: UInt64) throws {
    condition.lock()
    defer { condition.unlock() }
    try validateCompletionLocked(reservation, retired: retired)
    completeLocked(reservation, retired: retired)
    changedLocked()
  }

  /// Atomically completes one reservation, merges its counters, and publishes one result. A
  /// worker cannot overwrite an unread result or run ahead of an unconsumed directive.
  @discardableResult
  func completeAndPublish(
    _ reservation: Reservation,
    outcome: WorkerOutcome,
    counters: WorkerCounters,
    acknowledgedPendingWorkGeneration: UInt64 = 0
  ) throws -> WorkerResult {
    condition.lock()
    defer { condition.unlock() }
    let processor = reservation.processor
    try validateCompletionLocked(reservation, retired: counters.instructionCount)
    guard workerResults[processor] == nil else {
      throw SessionError.outstandingWorkerResult(processor)
    }
    guard workerDirectives[processor] == nil else {
      throw SessionError.outstandingWorkerDirective(processor)
    }
    try validateCountersLocked(counters, processor: processor)
    let processorCounters = try addingCountersLocked(
      workerCounters[processor], counters, processor: processor)
    let mergedCounters = try addingCountersLocked(
      mergedWorkerCounters, counters, processor: processor)
    let sequence = nextGeneration(after: workerResultSequences[processor])
    let result = WorkerResult(
      runGeneration: runGeneration,
      processor: processor,
      sequence: sequence,
      reservationSequence: reservation.sequence,
      acknowledgedPendingWorkGeneration: acknowledgedPendingWorkGeneration,
      outcome: outcome,
      counters: counters
    )

    completeLocked(reservation, retired: counters.instructionCount)
    workerCounters[processor] = processorCounters
    mergedWorkerCounters = mergedCounters
    workerResultSequences[processor] = sequence
    workerResults[processor] = result
    changedLocked()
    return result
  }

  func workerResult(forProcessor processor: Int) throws -> WorkerResult? {
    condition.lock()
    defer { condition.unlock() }
    try validate(processor)
    return workerResults[processor]
  }

  /// Responds to the exact unread result. Stale coordinator work cannot resume a worker after a
  /// newer handoff, and a response is never silently replaced.
  @discardableResult
  func respond(to result: WorkerResult, with directive: WorkerDirective) throws
    -> WorkerDirectiveEnvelope
  {
    condition.lock()
    defer { condition.unlock() }
    try validate(result.processor)
    guard result.runGeneration == runGeneration else {
      throw SessionError.staleRunGeneration(
        expected: runGeneration,
        actual: result.runGeneration
      )
    }
    let processor = result.processor
    guard let current = workerResults[processor] else {
      throw SessionError.missingWorkerResult(processor)
    }
    guard current.sequence == result.sequence else {
      throw SessionError.staleWorkerResult(
        processor: processor,
        expected: current.sequence,
        actual: result.sequence
      )
    }
    guard current == result else {
      throw SessionError.mismatchedWorkerResult(
        processor: processor,
        sequence: result.sequence
      )
    }
    guard workerDirectives[processor] == nil else {
      throw SessionError.outstandingWorkerDirective(processor)
    }
    let envelope = WorkerDirectiveEnvelope(
      runGeneration: runGeneration,
      processor: processor,
      resultSequence: result.sequence,
      directive: directive
    )
    workerResults[processor] = nil
    workerDirectives[processor] = envelope
    changedLocked()
    return envelope
  }

  /// Consumes only the directive paired with the caller's exact result sequence.
  func consumeDirective(processor: Int, forResultSequence sequence: UInt64) throws
    -> WorkerDirective?
  {
    condition.lock()
    defer { condition.unlock() }
    try validate(processor)
    guard let envelope = workerDirectives[processor] else { return nil }
    guard envelope.resultSequence == sequence else {
      throw SessionError.staleWorkerDirective(
        processor: processor,
        expected: envelope.resultSequence,
        actual: sequence
      )
    }
    workerDirectives[processor] = nil
    changedLocked()
    return envelope.directive
  }

  /// Waits for the coordinator response to an exact result without losing a response published
  /// before the worker parks. A timeout does not consume or fabricate a directive.
  func waitForDirective(
    processor: Int,
    forResultSequence sequence: UInt64,
    until deadline: Date
  ) throws -> WorkerDirective? {
    condition.lock()
    defer { condition.unlock() }
    try validate(processor)
    while true {
      if let envelope = workerDirectives[processor] {
        guard envelope.resultSequence == sequence else {
          throw SessionError.staleWorkerDirective(
            processor: processor,
            expected: envelope.resultSequence,
            actual: sequence
          )
        }
        workerDirectives[processor] = nil
        changedLocked()
        return envelope.directive
      }
      guard workerResults[processor]?.sequence == sequence else {
        throw SessionError.missingWorkerDirective(processor)
      }
      if !condition.wait(until: deadline) { return nil }
    }
  }

  /// Waits without a policy timeout. Production workers leave this boundary only after consuming
  /// the exact coordinator response paired with their published result.
  func waitForDirective(processor: Int, forResultSequence sequence: UInt64) throws
    -> WorkerDirective
  {
    condition.lock()
    defer { condition.unlock() }
    try validate(processor)
    while true {
      if let envelope = workerDirectives[processor] {
        guard envelope.resultSequence == sequence else {
          throw SessionError.staleWorkerDirective(
            processor: processor,
            expected: envelope.resultSequence,
            actual: sequence
          )
        }
        workerDirectives[processor] = nil
        changedLocked()
        return envelope.directive
      }
      guard workerResults[processor]?.sequence == sequence else {
        throw SessionError.missingWorkerDirective(processor)
      }
      condition.wait()
    }
  }

  /// Selects one stable terminal reason independent of arrival order. More authoritative reasons
  /// replace less authoritative ones; equal processor-scoped reasons choose the lower vCPU index.
  func requestTermination(_ reason: TerminationReason) throws {
    condition.lock()
    defer { condition.unlock() }
    switch reason {
    case .hostFailure(let processor), .tripleFault(let processor):
      try validate(processor)
    case .reset, .powerOff, .cancelled, .instructionBudget:
      break
    }
    let changed = selectTerminationLocked(reason)
    if changed {
      publishPendingLocked(processors: reservations.indices)
      changedLocked()
    }
  }

  /// Publishes pending work to one vCPU or every vCPU and returns the required generation vector.
  /// Multiple events may coalesce, but a stale acknowledgement can never clear a newer publication.
  @discardableResult
  func publishPendingWork(forProcessor processor: Int? = nil) throws -> [UInt64] {
    condition.lock()
    defer { condition.unlock() }
    let processors: any Sequence<Int>
    if let processor {
      try validate(processor)
      processors = CollectionOfOne(processor)
    } else {
      processors = reservations.indices
    }
    publishPendingLocked(processors: processors)
    changedLocked()
    return pendingRequiredGenerations
  }

  /// Imports a generation from the machine's per-vCPU wake source into this run. Re-observing the
  /// same source generation is idempotent, so coordinator handoffs cannot invent work; a changed
  /// source publishes exactly one session edge before the worker drains architectural state.
  @discardableResult
  func observePendingWork(processor: Int, sourceGeneration: UInt64) throws -> UInt64 {
    condition.lock()
    defer { condition.unlock() }
    try validate(processor)
    if pendingSourceGenerations[processor] != sourceGeneration {
      pendingSourceGenerations[processor] = sourceGeneration
      publishPendingLocked(processors: CollectionOfOne(processor))
      changedLocked()
    }
    return pendingRequiredGenerations[processor]
  }

  func pendingWorkGeneration(forProcessor processor: Int) throws -> UInt64? {
    condition.lock()
    defer { condition.unlock() }
    try validate(processor)
    let required = pendingRequiredGenerations[processor]
    return pendingAcknowledgedGenerations[processor] == required ? nil : required
  }

  @discardableResult
  func acknowledgePendingWork(processor: Int, generation: UInt64) throws -> Bool {
    condition.lock()
    defer { condition.unlock() }
    try validate(processor)
    guard pendingRequiredGenerations[processor] == generation,
      pendingAcknowledgedGenerations[processor] != generation
    else { return false }
    pendingAcknowledgedGenerations[processor] = generation
    if pendingRepublishAfterAcknowledgement[processor] {
      // A publication arrived while UInt64.max was still outstanding and could not be represented
      // by incrementing the required generation. Publish generation one now, after the old request
      // has an unambiguous acknowledgement, so that edge cannot be erased by wrap.
      pendingRequiredGenerations[processor] = 1
      pendingRepublishAfterAcknowledgement[processor] = false
    }
    changedLocked()
    return true
  }

  /// Starts or joins an all-worker quiescence barrier. Concurrent lifecycle requests coalesce on
  /// the active generation instead of blocking behind a worker that may have failed. A caller that
  /// requires a later architectural boundary must wait for this generation before requesting one.
  func requestQuiescence() -> UInt64 {
    condition.lock()
    defer { condition.unlock() }
    if quiescenceRequiredGenerations != quiescenceAcknowledgedGenerations {
      return quiescenceGeneration
    }
    hasRequestedQuiescence = true
    quiescenceGeneration = nextGeneration(after: quiescenceGeneration)
    quiescenceRequiredGenerations = .init(
      repeating: quiescenceGeneration,
      count: quiescenceRequiredGenerations.count
    )
    publishPendingLocked(processors: reservations.indices)
    changedLocked()
    return quiescenceGeneration
  }

  func quiescenceGenerationRequired(forProcessor processor: Int) throws -> UInt64? {
    condition.lock()
    defer { condition.unlock() }
    try validate(processor)
    let required = quiescenceRequiredGenerations[processor]
    return quiescenceAcknowledgedGenerations[processor] == required ? nil : required
  }

  @discardableResult
  func acknowledgeQuiescence(processor: Int, generation: UInt64) throws -> Bool {
    condition.lock()
    defer { condition.unlock() }
    try validate(processor)
    guard quiescenceRequiredGenerations[processor] == generation,
      quiescenceAcknowledgedGenerations[processor] != generation,
      pendingRequiredGenerations[processor] == pendingAcknowledgedGenerations[processor]
    else { return false }
    quiescenceAcknowledgedGenerations[processor] = generation
    changedLocked()
    return true
  }

  func waitForQuiescence(generation: UInt64, until deadline: Date) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    while !quiescenceCompleteLocked(generation: generation) {
      if !condition.wait(until: deadline) {
        return quiescenceCompleteLocked(generation: generation)
      }
    }
    return true
  }

  /// Waits for any session metadata change without permitting an early signal to be lost.
  func waitForChange(after observed: UInt64, until deadline: Date) -> Snapshot {
    condition.lock()
    defer { condition.unlock() }
    while changeGeneration == observed {
      if !condition.wait(until: deadline) { break }
    }
    return snapshotLocked()
  }

  var snapshot: Snapshot {
    condition.withLock { snapshotLocked() }
  }

  private func validate(_ processor: Int) throws {
    guard reservations.indices.contains(processor) else {
      throw SessionError.invalidProcessor(processor)
    }
  }

  private func validateCompletionLocked(_ reservation: Reservation, retired: UInt64) throws {
    try validate(reservation.processor)
    guard let current = reservations[reservation.processor] else {
      throw SessionError.missingReservation(reservation.processor)
    }
    guard current == reservation else {
      throw SessionError.staleReservation(
        processor: reservation.processor,
        expected: current.sequence,
        actual: reservation.sequence
      )
    }
    guard retired <= reservation.instructionCount else {
      throw SessionError.retiredBeyondReservation(
        retired: retired,
        reserved: reservation.instructionCount
      )
    }
  }

  private func completeLocked(_ reservation: Reservation, retired: UInt64) {
    reservations[reservation.processor] = nil
    let unused = reservation.instructionCount - retired
    remainingInstructionBudget += unused
    retiredInstructions[reservation.processor] += retired
    totalRetiredInstructions += retired
    if remainingInstructionBudget == 0, reservations.allSatisfy({ $0 == nil }),
      selectTerminationLocked(.instructionBudget)
    {
      publishPendingLocked(processors: reservations.indices)
    }
  }

  private func validateCountersLocked(_ counters: WorkerCounters, processor: Int) throws {
    let (translated, translatedOverflow) = counters.baselineJITInstructions.addingReportingOverflow(
      counters.optimizingJITInstructions)
    let (withFallback, fallbackOverflow) = translated.addingReportingOverflow(
      counters.interpreterFallbackJITInstructions)
    let (accounted, accountedOverflow) = withFallback.addingReportingOverflow(
      counters.interpreterInstructions)
    guard !translatedOverflow, !fallbackOverflow, !accountedOverflow,
      accounted == counters.instructionCount
    else {
      throw SessionError.inconsistentWorkerCounters(processor: processor)
    }
  }

  private func addingCountersLocked(
    _ lhs: WorkerCounters,
    _ rhs: WorkerCounters,
    processor: Int
  ) throws -> WorkerCounters {
    func add(_ first: UInt64, _ second: UInt64) throws -> UInt64 {
      let result = first.addingReportingOverflow(second)
      guard !result.overflow else { throw SessionError.counterOverflow(processor: processor) }
      return result.partialValue
    }
    return try WorkerCounters(
      instructionCount: add(lhs.instructionCount, rhs.instructionCount),
      interpreterInstructions: add(
        lhs.interpreterInstructions, rhs.interpreterInstructions),
      baselineJITInstructions: add(
        lhs.baselineJITInstructions, rhs.baselineJITInstructions),
      baselineJITBlocks: add(lhs.baselineJITBlocks, rhs.baselineJITBlocks),
      optimizingJITInstructions: add(
        lhs.optimizingJITInstructions, rhs.optimizingJITInstructions),
      optimizingJITBlocks: add(lhs.optimizingJITBlocks, rhs.optimizingJITBlocks),
      interpreterFallbackJITInstructions: add(
        lhs.interpreterFallbackJITInstructions, rhs.interpreterFallbackJITInstructions),
      executionCPUNanoseconds: add(
        lhs.executionCPUNanoseconds, rhs.executionCPUNanoseconds),
      eventCPUNanoseconds: add(lhs.eventCPUNanoseconds, rhs.eventCPUNanoseconds)
    )
  }

  @discardableResult
  private func selectTerminationLocked(_ reason: TerminationReason) -> Bool {
    if let current = terminationReason, current.priority <= reason.priority { return false }
    terminationReason = reason
    return true
  }

  private func publishPendingLocked<S: Sequence>(processors: S) where S.Element == Int {
    for processor in processors {
      let required = pendingRequiredGenerations[processor]
      let acknowledged = pendingAcknowledgedGenerations[processor]
      if required == .max && required != acknowledged {
        pendingRepublishAfterAcknowledgement[processor] = true
      } else {
        pendingRequiredGenerations[processor] = nextGeneration(after: required)
      }
      if hasRequestedQuiescence,
        quiescenceAcknowledgedGenerations[processor]
          == quiescenceRequiredGenerations[processor]
      {
        // Work published after this worker acknowledged the active barrier invalidates that
        // acknowledgement. Reuse the barrier generation so every waiter observes one continuous
        // quiescence request, but require the affected owner to drain and acknowledge again.
        let quiescence = quiescenceRequiredGenerations[processor]
        quiescenceAcknowledgedGenerations[processor] =
          quiescence == 1 ? .max : quiescence - 1
      }
    }
  }

  private func quiescenceCompleteLocked(generation: UInt64) -> Bool {
    for processor in reservations.indices
    where quiescenceRequiredGenerations[processor] == generation
      && quiescenceAcknowledgedGenerations[processor] != generation
    {
      return false
    }
    return true
  }

  private func changedLocked() {
    changeGeneration = nextGeneration(after: changeGeneration)
    condition.broadcast()
  }

  private func snapshotLocked() -> Snapshot {
    Snapshot(
      runGeneration: runGeneration,
      exceptionPolicy: exceptionPolicy,
      clockMode: clockMode,
      initialInstructionBudget: initialInstructionBudget,
      remainingInstructionBudget: remainingInstructionBudget,
      outstandingReservations: reservations,
      retiredInstructions: retiredInstructions,
      totalRetiredInstructions: totalRetiredInstructions,
      pendingSourceGenerations: pendingSourceGenerations,
      pendingRequiredGenerations: pendingRequiredGenerations,
      pendingAcknowledgedGenerations: pendingAcknowledgedGenerations,
      pendingRepublishAfterAcknowledgement: pendingRepublishAfterAcknowledgement,
      quiescenceGeneration: quiescenceGeneration,
      quiescenceRequiredGenerations: quiescenceRequiredGenerations,
      quiescenceAcknowledgedGenerations: quiescenceAcknowledgedGenerations,
      workerResults: workerResults,
      workerDirectives: workerDirectives,
      workerCounters: workerCounters,
      mergedWorkerCounters: mergedWorkerCounters,
      terminationReason: terminationReason,
      changeGeneration: changeGeneration
    )
  }

  private func nextGeneration(after generation: UInt64) -> UInt64 {
    generation == .max ? 1 : generation + 1
  }
}
