import Foundation

/// Run-local start barrier for explicitly admitted concurrent owner slices.
///
/// The coordinator installs one batch before publishing its commands. Each member first reserves
/// its portion of the shared instruction budget, then arrives here. No member can enter guest code
/// until every participant has arrived, which prevents a fast failure from denying a slower owner
/// the reservation required to publish a terminal result. The condition protects only barrier
/// metadata and is never held during guest execution.
final class DoryPCRunConcurrentExecutionGate: @unchecked Sendable {
  enum GateError: Error, Sendable, Equatable {
    case invalidBatch(UInt64)
    case invalidParticipants
    case activeBatch(UInt64)
    case noActiveBatch
    case staleBatch(expected: UInt64, actual: UInt64)
    case unexpectedParticipant(Int)
    case duplicateArrival(Int)
    case incompleteBatch(UInt64)
    case aborted(batch: UInt64, processor: Int)
    case arrivalTimeout(UInt64)
    case closed
  }

  private struct Batch {
    let identifier: UInt64
    let participants: Set<Int>
    let arrivalDeadlineUptimeNanoseconds: UInt64
    var arrived: Set<Int> = []
    var abortedBy: Int?
    var timedOut = false
  }

  private let condition = NSCondition()
  private let arrivalTimeoutNanoseconds: UInt64
  private var active: Batch?
  private var isClosed = false

  init(arrivalTimeout: TimeInterval = DoryPCHostWorker.stopJoinTimeout) {
    precondition(arrivalTimeout > 0 && arrivalTimeout <= 60)
    arrivalTimeoutNanoseconds = UInt64(arrivalTimeout * 1_000_000_000)
  }

  /// Installs one batch while all owners are parked at command/result boundaries.
  func begin(batch identifier: UInt64, participants: [Int]) throws {
    condition.lock()
    defer { condition.unlock() }
    guard !isClosed else { throw GateError.closed }
    guard identifier > 0 else { throw GateError.invalidBatch(identifier) }
    let participantSet = Set(participants)
    guard participantSet.count == participants.count, participantSet.count > 1,
      participantSet.allSatisfy({ $0 >= 0 })
    else { throw GateError.invalidParticipants }
    guard active == nil else { throw GateError.activeBatch(active!.identifier) }
    let now = DispatchTime.now().uptimeNanoseconds
    let (deadline, overflow) = now.addingReportingOverflow(arrivalTimeoutNanoseconds)
    active = .init(
      identifier: identifier, participants: participantSet,
      arrivalDeadlineUptimeNanoseconds: overflow ? .max : deadline
    )
  }

  /// Arrives after reserving budget and waits losslessly for every member of this exact batch.
  func arriveAndWait(processor: Int, batch identifier: UInt64) throws {
    condition.lock()
    defer { condition.unlock() }
    guard !isClosed else { throw GateError.closed }
    guard var batch = active else { throw GateError.noActiveBatch }
    guard batch.identifier == identifier else {
      throw GateError.staleBatch(expected: batch.identifier, actual: identifier)
    }
    guard batch.participants.contains(processor) else {
      throw GateError.unexpectedParticipant(processor)
    }
    if let abortedBy = batch.abortedBy {
      throw GateError.aborted(batch: identifier, processor: abortedBy)
    }
    if batch.timedOut { throw GateError.arrivalTimeout(identifier) }
    if DispatchTime.now().uptimeNanoseconds >= batch.arrivalDeadlineUptimeNanoseconds {
      batch.timedOut = true
      active = batch
      condition.broadcast()
      throw GateError.arrivalTimeout(identifier)
    }
    guard batch.arrived.insert(processor).inserted else {
      throw GateError.duplicateArrival(processor)
    }
    active = batch
    condition.broadcast()

    while true {
      guard !isClosed else { throw GateError.closed }
      guard let current = active else { throw GateError.noActiveBatch }
      guard current.identifier == identifier else {
        throw GateError.staleBatch(expected: current.identifier, actual: identifier)
      }
      if let abortedBy = current.abortedBy {
        throw GateError.aborted(batch: identifier, processor: abortedBy)
      }
      if current.timedOut { throw GateError.arrivalTimeout(identifier) }
      if current.arrived == current.participants { return }
      let now = DispatchTime.now().uptimeNanoseconds
      if now >= current.arrivalDeadlineUptimeNanoseconds {
        var timedOut = current
        timedOut.timedOut = true
        active = timedOut
        condition.broadcast()
        throw GateError.arrivalTimeout(identifier)
      }
      let remaining = current.arrivalDeadlineUptimeNanoseconds - now
      _ = condition.wait(until: Date(timeIntervalSinceNow:
        TimeInterval(min(remaining, 50_000_000)) / 1_000_000_000
      ))
    }
  }

  /// A worker that fails before entering guest code must release every peer waiting at the
  /// barrier. The first failed participant remains the diagnostic authority for this batch.
  func abort(batch identifier: UInt64, processor: Int) {
    condition.lock()
    defer { condition.unlock() }
    guard !isClosed, var batch = active, batch.identifier == identifier,
      !batch.timedOut,
      batch.participants.contains(processor)
    else { return }
    if batch.abortedBy == nil { batch.abortedBy = processor }
    active = batch
    condition.broadcast()
  }

  func abortedProcessor(batch identifier: UInt64) -> Int? {
    condition.withLock {
      guard active?.identifier == identifier else { return nil }
      return active?.abortedBy
    }
  }

  /// Retires a batch only after the coordinator has received every member's result.
  func finish(batch identifier: UInt64) throws {
    condition.lock()
    defer { condition.unlock() }
    guard !isClosed else { throw GateError.closed }
    guard let batch = active else { throw GateError.noActiveBatch }
    guard batch.identifier == identifier else {
      throw GateError.staleBatch(expected: batch.identifier, actual: identifier)
    }
    if let abortedBy = batch.abortedBy {
      throw GateError.aborted(batch: identifier, processor: abortedBy)
    }
    if batch.timedOut { throw GateError.arrivalTimeout(identifier) }
    guard batch.arrived == batch.participants else {
      throw GateError.incompleteBatch(identifier)
    }
    active = nil
    condition.broadcast()
  }

  /// Internal observation boundary for qualification tests. It observes metadata only and never
  /// changes admission, releases a worker, or runs a callback while holding the condition.
  func waitUntilArrived(processor: Int, batch identifier: UInt64, until deadline: Date) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    while !isClosed, let current = active, current.identifier == identifier,
      !current.arrived.contains(processor)
    {
      if !condition.wait(until: deadline) { break }
    }
    guard !isClosed, let current = active, current.identifier == identifier else { return false }
    return current.arrived.contains(processor)
  }

  /// Permanently cancels this run and releases every early arrival. Close is idempotent.
  func close() {
    condition.lock()
    isClosed = true
    active = nil
    condition.broadcast()
    condition.unlock()
  }
}
