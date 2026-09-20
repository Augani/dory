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
    case closed
  }

  private struct Batch {
    let identifier: UInt64
    let participants: Set<Int>
    var arrived: Set<Int> = []
  }

  private let condition = NSCondition()
  private var active: Batch?
  private var isClosed = false

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
    active = .init(identifier: identifier, participants: participantSet)
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
      if current.arrived == current.participants { return }
      condition.wait()
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
