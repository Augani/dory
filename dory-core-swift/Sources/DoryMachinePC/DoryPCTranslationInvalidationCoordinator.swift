import Foundation

/// Machine-scoped publication and acknowledgement for architectural translation invalidations.
///
/// Only one publication may be in flight. This deliberately conservative rule gives generation
/// wrap a safe reset point: every older publication is acknowledged before generation one can be
/// reused, and the wrap publication is forced to a global flush. A future free-running dispatcher
/// can use the same pending/acknowledge boundary while delivering requests through per-vCPU
/// pending work instead of the current coordinator rendezvous.
final class DoryPCTranslationInvalidationCoordinator: @unchecked Sendable {
  struct Publication: Sendable, Equatable {
    let generation: UInt64
    let linearAddress: UInt64?
  }

  struct Diagnostics: Sendable, Equatable {
    let generation: UInt64
    let requiredGenerations: [UInt64]
    let acknowledgedGenerations: [UInt64]
  }

  private let condition = NSCondition()
  private var generation: UInt64 = 0
  private var requiredGenerations: [UInt64]
  private var acknowledgedGenerations: [UInt64]
  private var publication: Publication?

  init(processorCount: Int) {
    precondition(processorCount > 0)
    requiredGenerations = .init(repeating: 0, count: processorCount)
    acknowledgedGenerations = .init(repeating: 0, count: processorCount)
  }

  func publish(linearAddress requestedLinearAddress: UInt64?) -> Publication {
    condition.lock()
    while requiredGenerations != acknowledgedGenerations { condition.wait() }
    let linearAddress: UInt64?
    if generation == .max {
      // Every old request is acknowledged under the same lock, so reuse cannot mistake a delayed
      // acknowledgement for this publication. Force a global flush before recycling generation 1.
      generation = 1
      linearAddress = nil
    } else {
      generation += 1
      linearAddress = requestedLinearAddress
    }
    let next = Publication(generation: generation, linearAddress: linearAddress)
    publication = next
    requiredGenerations = .init(repeating: generation, count: requiredGenerations.count)
    condition.broadcast()
    condition.unlock()
    return next
  }

  func pending(for processor: Int) -> Publication? {
    condition.withLock {
      guard requiredGenerations.indices.contains(processor),
        acknowledgedGenerations[processor] != requiredGenerations[processor]
      else { return nil }
      return publication
    }
  }

  func acknowledge(processor: Int, generation: UInt64) {
    condition.lock()
    guard requiredGenerations.indices.contains(processor),
      requiredGenerations[processor] == generation,
      acknowledgedGenerations[processor] != generation
    else {
      condition.unlock()
      return
    }
    acknowledgedGenerations[processor] = generation
    if requiredGenerations == acknowledgedGenerations {
      publication = nil
      condition.broadcast()
    }
    condition.unlock()
  }

  func wait(for publication: Publication) {
    condition.lock()
    while requiredGenerations.contains(publication.generation)
      && acknowledgedGenerations != requiredGenerations
    {
      condition.wait()
    }
    condition.unlock()
  }

  var diagnostics: Diagnostics {
    condition.withLock {
      .init(
        generation: generation,
        requiredGenerations: requiredGenerations,
        acknowledgedGenerations: acknowledgedGenerations)
    }
  }
}
