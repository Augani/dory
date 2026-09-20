import Foundation

/// Machine-scoped coordination state for one future free-running vCPU run.
///
/// The condition protects metadata only. Callers must not enter guest code, call a device, acquire
/// RAM range authority, or deliver an interrupt while holding it. Architectural state remains
/// owned by its vCPU worker; this object only coordinates reservations and generations.
final class DoryPCRunSession: @unchecked Sendable {
  struct Reservation: Sendable, Equatable {
    let processor: Int
    let sequence: UInt64
    let instructionCount: UInt64
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
  }

  struct Snapshot: Sendable, Equatable {
    let initialInstructionBudget: UInt64
    let remainingInstructionBudget: UInt64
    let outstandingReservations: [Reservation?]
    let retiredInstructions: [UInt64]
    let totalRetiredInstructions: UInt64
    let pendingRequiredGenerations: [UInt64]
    let pendingAcknowledgedGenerations: [UInt64]
    let pendingRepublishAfterAcknowledgement: [Bool]
    let quiescenceGeneration: UInt64
    let quiescenceRequiredGenerations: [UInt64]
    let quiescenceAcknowledgedGenerations: [UInt64]
    let terminationReason: TerminationReason?
    let changeGeneration: UInt64
  }

  private let condition = NSCondition()
  let processorCount: Int
  private let initialInstructionBudget: UInt64
  private var remainingInstructionBudget: UInt64
  private var reservationSequences: [UInt64]
  private var reservations: [Reservation?]
  private var retiredInstructions: [UInt64]
  private var totalRetiredInstructions: UInt64 = 0
  private var pendingRequiredGenerations: [UInt64]
  private var pendingAcknowledgedGenerations: [UInt64]
  private var pendingRepublishAfterAcknowledgement: [Bool]
  private var quiescenceGeneration: UInt64 = 0
  private var quiescenceRequiredGenerations: [UInt64]
  private var quiescenceAcknowledgedGenerations: [UInt64]
  private var terminationReason: TerminationReason?
  private var changeGeneration: UInt64 = 0

  init(
    processorCount: Int,
    instructionBudget: UInt64,
    initialGeneration: UInt64 = 0
  ) {
    precondition(processorCount > 0)
    self.processorCount = processorCount
    initialInstructionBudget = instructionBudget
    remainingInstructionBudget = instructionBudget
    reservationSequences = .init(repeating: initialGeneration, count: processorCount)
    reservations = .init(repeating: nil, count: processorCount)
    retiredInstructions = .init(repeating: 0, count: processorCount)
    pendingRequiredGenerations = .init(repeating: initialGeneration, count: processorCount)
    pendingAcknowledgedGenerations = .init(repeating: initialGeneration, count: processorCount)
    pendingRepublishAfterAcknowledgement = .init(repeating: false, count: processorCount)
    quiescenceGeneration = initialGeneration
    quiescenceRequiredGenerations = .init(repeating: initialGeneration, count: processorCount)
    quiescenceAcknowledgedGenerations = .init(repeating: initialGeneration, count: processorCount)
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
    changedLocked()
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
      quiescenceAcknowledgedGenerations[processor] != generation
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
      initialInstructionBudget: initialInstructionBudget,
      remainingInstructionBudget: remainingInstructionBudget,
      outstandingReservations: reservations,
      retiredInstructions: retiredInstructions,
      totalRetiredInstructions: totalRetiredInstructions,
      pendingRequiredGenerations: pendingRequiredGenerations,
      pendingAcknowledgedGenerations: pendingAcknowledgedGenerations,
      pendingRepublishAfterAcknowledgement: pendingRepublishAfterAcknowledgement,
      quiescenceGeneration: quiescenceGeneration,
      quiescenceRequiredGenerations: quiescenceRequiredGenerations,
      quiescenceAcknowledgedGenerations: quiescenceAcknowledgedGenerations,
      terminationReason: terminationReason,
      changeGeneration: changeGeneration
    )
  }

  private func nextGeneration(after generation: UInt64) -> UInt64 {
    generation == .max ? 1 : generation + 1
  }
}
