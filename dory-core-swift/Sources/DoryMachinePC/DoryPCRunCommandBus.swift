import Foundation

/// Sequenced coordinator-to-owner commands for one machine run.
///
/// The condition protects command metadata only. A worker removes its command before entering
/// guest code, so neither the coordinator nor another vCPU can retain this lock across execution,
/// device callbacks, RAM authority, or session handoffs. There is one lossless single-slot lane per
/// processor: publishing over an unread command fails closed instead of silently replacing work.
final class DoryPCRunCommandBus: @unchecked Sendable {
  enum Command: Sendable, Equatable {
    case execute(maximumInstructions: UInt64)
    case executeConcurrent(maximumInstructions: UInt64, batch: UInt64)
    case prepareFrozenInstruction
    case executeFrozenInstruction

    var maximumInstructions: UInt64 {
      switch self {
      case .execute(let maximumInstructions): maximumInstructions
      case .executeConcurrent(let maximumInstructions, _): maximumInstructions
      case .prepareFrozenInstruction, .executeFrozenInstruction: 1
      }
    }
  }

  struct Envelope: Sendable, Equatable {
    let runGeneration: UInt64
    let processor: Int
    let sequence: UInt64
    let command: Command
  }

  enum Poll: Sendable, Equatable {
    case command(Envelope)
    case empty
    case closed
  }

  enum CommandError: Error, Sendable, Equatable {
    case invalidProcessor(Int)
    case invalidMaximumInstructions(UInt64)
    case outstandingCommand(Int)
    case closed
  }

  private let condition = NSCondition()
  let processorCount: Int
  let runGeneration: UInt64
  private var sequences: [UInt64]
  private var pending: [Envelope?]
  private var isClosed = false

  init(processorCount: Int, runGeneration: UInt64, initialSequence: UInt64 = 0) {
    precondition(processorCount > 0)
    self.processorCount = processorCount
    self.runGeneration = runGeneration
    sequences = .init(repeating: initialSequence, count: processorCount)
    pending = .init(repeating: nil, count: processorCount)
  }

  /// Publishes exactly one execution command. Commands may be published before the owner parks;
  /// the stored envelope makes that early notification durable.
  @discardableResult
  func publishExecution(
    forProcessor processor: Int,
    maximumInstructions: UInt64
  ) throws -> Envelope {
    guard maximumInstructions > 0 else {
      throw CommandError.invalidMaximumInstructions(maximumInstructions)
    }
    return try publish(
      .execute(maximumInstructions: maximumInstructions),
      forProcessor: processor
    )
  }

  /// Publishes one member of an explicitly admitted concurrent batch. The batch identifier is
  /// consumed by the run-local start gate, which prevents either owner entering guest code until
  /// every member has secured its disjoint global-budget reservation.
  @discardableResult
  func publishConcurrentExecution(
    forProcessor processor: Int,
    maximumInstructions: UInt64,
    batch: UInt64
  ) throws -> Envelope {
    guard maximumInstructions > 0 else {
      throw CommandError.invalidMaximumInstructions(maximumInstructions)
    }
    return try publish(
      .executeConcurrent(maximumInstructions: maximumInstructions, batch: batch),
      forProcessor: processor
    )
  }

  /// Publishes one previously preflighted, register-only instruction. The plan itself remains in
  /// the machine's owner-state handoff; this envelope only grants the matching worker permission
  /// to consume it.
  @discardableResult
  func publishFrozenInstruction(forProcessor processor: Int) throws -> Envelope {
    try publish(
      .executeFrozenInstruction,
      forProcessor: processor
    )
  }

  /// Requests owner-thread preflight for the narrowly admitted register-only overlap path.
  @discardableResult
  func publishFrozenInstructionPreparation(forProcessor processor: Int) throws -> Envelope {
    try publish(
      .prepareFrozenInstruction,
      forProcessor: processor
    )
  }

  /// Waits for and removes the next command for one owner. `nil` is returned after close, including
  /// when close races an unread command; close is a cancellation boundary and never permits new
  /// guest entry.
  func nextCommand(forProcessor processor: Int) throws -> Envelope? {
    condition.lock()
    defer { condition.unlock() }
    try validate(processor)
    while pending[processor] == nil && !isClosed { condition.wait() }
    guard !isClosed else {
      pending[processor] = nil
      return nil
    }
    let command = pending[processor]
    pending[processor] = nil
    condition.broadcast()
    return command
  }

  /// Nonblocking observation used by owners whose park loop must also service translation
  /// maintenance. Command publication is paired with the machine pending-work wake condition.
  func poll(forProcessor processor: Int) throws -> Poll {
    condition.lock()
    defer { condition.unlock() }
    try validate(processor)
    guard !isClosed else {
      pending[processor] = nil
      return .closed
    }
    guard let command = pending[processor] else { return .empty }
    pending[processor] = nil
    condition.broadcast()
    return .command(command)
  }

  /// Permanently cancels the run and wakes every owner. Close is idempotent.
  func close() {
    condition.lock()
    isClosed = true
    pending = .init(repeating: nil, count: processorCount)
    condition.broadcast()
    condition.unlock()
  }

  private func validate(_ processor: Int) throws {
    guard pending.indices.contains(processor) else {
      throw CommandError.invalidProcessor(processor)
    }
  }

  private func publish(_ command: Command, forProcessor processor: Int) throws -> Envelope {
    condition.lock()
    defer { condition.unlock() }
    try validate(processor)
    guard !isClosed else { throw CommandError.closed }
    guard pending[processor] == nil else { throw CommandError.outstandingCommand(processor) }

    let sequence = sequences[processor] == .max ? 1 : sequences[processor] + 1
    let envelope = Envelope(
      runGeneration: runGeneration,
      processor: processor,
      sequence: sequence,
      command: command
    )
    sequences[processor] = sequence
    pending[processor] = envelope
    condition.broadcast()
    return envelope
  }
}
