import Foundation
import Testing

@testable import DoryMachinePC

@Suite(.serialized) struct DoryPCRunSessionTests {
  @Test func budgetReservationsReturnUnusedWorkAndStopExactlyAtBudget() throws {
    let session = DoryPCRunSession(processorCount: 2, instructionBudget: 10)
    let first = try #require(try session.reserve(processor: 0, maximumInstructions: 6))
    let second = try #require(try session.reserve(processor: 1, maximumInstructions: 6))
    #expect(first.instructionCount == 6)
    #expect(second.instructionCount == 4)

    try session.complete(second, retired: 3)
    try session.complete(first, retired: 6)
    var snapshot = session.snapshot
    #expect(snapshot.remainingInstructionBudget == 1)
    #expect(snapshot.retiredInstructions == [6, 3])
    #expect(snapshot.totalRetiredInstructions == 9)
    #expect(snapshot.terminationReason == nil)

    let final = try #require(try session.reserve(processor: 1, maximumInstructions: 20))
    #expect(final.instructionCount == 1)
    try session.complete(final, retired: 1)
    snapshot = session.snapshot
    #expect(snapshot.remainingInstructionBudget == 0)
    #expect(snapshot.totalRetiredInstructions == 10)
    #expect(snapshot.terminationReason == .instructionBudget)
    #expect(snapshot.outstandingReservations.allSatisfy { $0 == nil })
    #expect(snapshot.pendingRequiredGenerations == [1, 1])
    #expect(snapshot.pendingAcknowledgedGenerations == [0, 0])
  }

  @Test func invalidCompletionFailsClosed() throws {
    let session = DoryPCRunSession(processorCount: 1, instructionBudget: 8)
    let reservation = try #require(try session.reserve(processor: 0, maximumInstructions: 4))
    let reserved = session.snapshot

    let stale = DoryPCRunSession.Reservation(
      processor: reservation.processor,
      sequence: reservation.sequence &+ 1,
      instructionCount: reservation.instructionCount
    )
    do {
      try session.complete(stale, retired: 1)
      Issue.record("stale completion was accepted")
    } catch let error as DoryPCRunSession.SessionError {
      #expect(
        error
          == .staleReservation(
            processor: 0,
            expected: reservation.sequence,
            actual: stale.sequence
          ))
    }
    #expect(session.snapshot == reserved)

    do {
      try session.complete(reservation, retired: 5)
      Issue.record("over-retired completion was accepted")
    } catch let error as DoryPCRunSession.SessionError {
      #expect(error == .retiredBeyondReservation(retired: 5, reserved: 4))
    }
    #expect(session.snapshot == reserved)

    try session.complete(reservation, retired: 4)
    #expect(session.snapshot.totalRetiredInstructions == 4)
    #expect(session.snapshot.remainingInstructionBudget == 4)
  }

  @Test func terminationSelectionIsStableAcrossArrivalOrder() throws {
    let first = DoryPCRunSession(processorCount: 4, instructionBudget: 100)
    for reason in [
      DoryPCRunSession.TerminationReason.instructionBudget,
      .cancelled,
      .powerOff,
      .reset,
      .tripleFault(processor: 3),
      .tripleFault(processor: 1),
      .hostFailure(processor: 3),
      .hostFailure(processor: 1),
    ] {
      try first.requestTermination(reason)
    }

    let second = DoryPCRunSession(processorCount: 4, instructionBudget: 100)
    for reason in [
      DoryPCRunSession.TerminationReason.hostFailure(processor: 1),
      .reset,
      .instructionBudget,
      .hostFailure(processor: 3),
      .tripleFault(processor: 0),
      .cancelled,
    ] {
      try second.requestTermination(reason)
    }

    #expect(first.snapshot.terminationReason == .hostFailure(processor: 1))
    #expect(second.snapshot.terminationReason == .hostFailure(processor: 1))
    #expect(try first.reserve(processor: 0, maximumInstructions: 1) == nil)
    #expect(try second.reserve(processor: 0, maximumInstructions: 1) == nil)
  }

  @Test func invalidTerminationProcessorFailsClosed() throws {
    let session = DoryPCRunSession(processorCount: 2, instructionBudget: 10)
    let original = session.snapshot

    #expect(throws: DoryPCRunSession.SessionError.invalidProcessor(-1)) {
      try session.requestTermination(.hostFailure(processor: -1))
    }
    #expect(throws: DoryPCRunSession.SessionError.invalidProcessor(2)) {
      try session.requestTermination(.tripleFault(processor: 2))
    }
    #expect(session.snapshot == original)
  }

  @Test func stalePendingAcknowledgementCannotClearNewerPublication() throws {
    let session = DoryPCRunSession(processorCount: 2, instructionBudget: 1)
    let first = try session.publishPendingWork(forProcessor: 0)[0]
    let second = try session.publishPendingWork(forProcessor: 0)[0]
    #expect(second == first + 1)
    #expect(try session.acknowledgePendingWork(processor: 0, generation: first) == false)
    #expect(try session.pendingWorkGeneration(forProcessor: 0) == second)
    #expect(try session.acknowledgePendingWork(processor: 0, generation: second))
    #expect(try session.pendingWorkGeneration(forProcessor: 0) == nil)
    #expect(try session.pendingWorkGeneration(forProcessor: 1) == nil)
  }

  @Test func publicationAtMaximumDefersWrapUntilOldGenerationIsAcknowledged() throws {
    let session = DoryPCRunSession(
      processorCount: 1,
      instructionBudget: 1,
      initialGeneration: .max - 1
    )
    #expect(try session.publishPendingWork(forProcessor: 0) == [.max])
    #expect(try session.publishPendingWork(forProcessor: 0) == [.max])
    #expect(session.snapshot.pendingRepublishAfterAcknowledgement == [true])

    #expect(try session.acknowledgePendingWork(processor: 0, generation: .max))
    #expect(try session.pendingWorkGeneration(forProcessor: 0) == 1)
    #expect(session.snapshot.pendingAcknowledgedGenerations == [.max])
    #expect(session.snapshot.pendingRepublishAfterAcknowledgement == [false])
    #expect(try session.acknowledgePendingWork(processor: 0, generation: 1))
    #expect(try session.pendingWorkGeneration(forProcessor: 0) == nil)
  }

  @Test func everyGenerationDomainWrapsOnlyFromQuiescentMaximum() throws {
    let session = DoryPCRunSession(
      processorCount: 2,
      instructionBudget: 2,
      initialGeneration: .max
    )
    let reservation = try #require(try session.reserve(processor: 0, maximumInstructions: 1))
    #expect(reservation.sequence == 1)
    try session.complete(reservation, retired: 1)

    let pending = try session.publishPendingWork()
    #expect(pending == [1, 1])
    #expect(try session.acknowledgePendingWork(processor: 0, generation: 1))
    #expect(try session.acknowledgePendingWork(processor: 1, generation: 1))

    let quiescence = session.requestQuiescence()
    #expect(quiescence == 1)
    #expect(try session.acknowledgeQuiescence(processor: 0, generation: quiescence))
    #expect(try session.acknowledgeQuiescence(processor: 1, generation: quiescence))
    #expect(
      session.waitForQuiescence(
        generation: quiescence,
        until: Date(timeIntervalSinceNow: 0.1)
      ))
    #expect(session.snapshot.changeGeneration != .max)
  }

  @Test func quiescenceWaitsForEveryWorkerAndCoalescesConcurrentRequests() throws {
    let session = DoryPCRunSession(processorCount: 2, instructionBudget: 10)
    let first = session.requestQuiescence()
    #expect(
      !session.waitForQuiescence(
        generation: first,
        until: Date(timeIntervalSinceNow: 0.025)
      ))

    let coalesced = LockedValue<[UInt64]>([])
    DispatchQueue.concurrentPerform(iterations: 10_000) { _ in
      coalesced.mutate { $0.append(session.requestQuiescence()) }
    }
    #expect(coalesced.value.allSatisfy { $0 == first })

    #expect(try session.acknowledgeQuiescence(processor: 0, generation: first))
    #expect(
      !session.waitForQuiescence(
        generation: first,
        until: Date(timeIntervalSinceNow: 0.025)
      ))
    #expect(try session.acknowledgeQuiescence(processor: 1, generation: first))
    #expect(
      session.waitForQuiescence(
        generation: first,
        until: Date(timeIntervalSinceNow: 0.1)
      ))

    let second = session.requestQuiescence()
    #expect(second == first + 1)
    #expect(try session.quiescenceGenerationRequired(forProcessor: 0) == second)
    #expect(try session.quiescenceGenerationRequired(forProcessor: 1) == second)
    #expect(try !session.acknowledgeQuiescence(processor: 0, generation: first))
    #expect(try session.acknowledgeQuiescence(processor: 0, generation: second))
    #expect(try session.acknowledgeQuiescence(processor: 1, generation: second))
  }

  @Test func tenThousandConcurrentTerminationRequestsSelectOneStableReason() {
    let session = DoryPCRunSession(processorCount: 4, instructionBudget: 10)
    let failures = LockedValue<[String]>([])

    DispatchQueue.concurrentPerform(iterations: 10_000) { index in
      let reason: DoryPCRunSession.TerminationReason =
        switch index % 6 {
        case 0: .instructionBudget
        case 1: .cancelled
        case 2: .powerOff
        case 3: .reset
        case 4: .tripleFault(processor: (index / 6) % 4)
        default: .hostFailure(processor: (index / 6) % 4)
        }
      do {
        try session.requestTermination(reason)
      } catch {
        failures.mutate { $0.append(String(describing: error)) }
      }
    }

    #expect(failures.value.isEmpty)
    #expect(session.snapshot.terminationReason == .hostFailure(processor: 0))
    #expect(session.snapshot.pendingRequiredGenerations.allSatisfy { $0 > 0 })
  }

  @Test func concurrentReservationsRetireTheExactGlobalBudget() {
    let session = DoryPCRunSession(processorCount: 4, instructionBudget: 100_003)
    let failures = LockedValue<[String]>([])

    DispatchQueue.concurrentPerform(iterations: 4) { processor in
      do {
        while let reservation = try session.reserve(
          processor: processor,
          maximumInstructions: 17
        ) {
          try session.complete(reservation, retired: reservation.instructionCount)
        }
      } catch {
        failures.mutate { $0.append(String(describing: error)) }
      }
    }

    let snapshot = session.snapshot
    #expect(failures.value.isEmpty)
    #expect(snapshot.totalRetiredInstructions == 100_003)
    #expect(snapshot.retiredInstructions.reduce(0, +) == 100_003)
    #expect(snapshot.remainingInstructionBudget == 0)
    #expect(snapshot.outstandingReservations.allSatisfy { $0 == nil })
    #expect(snapshot.terminationReason == .instructionBudget)
  }

  @Test func tenThousandConcurrentPublicationsCannotLosePendingWork() throws {
    let session = DoryPCRunSession(processorCount: 1, instructionBudget: 1)
    let producerFinished = LockedValue(false)
    let consumerFinished = DispatchSemaphore(value: 0)

    DispatchQueue.global().async {
      while true {
        if let generation = try! session.pendingWorkGeneration(forProcessor: 0) {
          _ = try! session.acknowledgePendingWork(processor: 0, generation: generation)
          continue
        }
        if producerFinished.value { break }
        let observed = session.snapshot.changeGeneration
        _ = session.waitForChange(
          after: observed,
          until: Date(timeIntervalSinceNow: 0.05)
        )
      }
      consumerFinished.signal()
    }

    for _ in 0..<10_000 {
      try session.publishPendingWork(forProcessor: 0)
    }
    producerFinished.set(true)
    try session.publishPendingWork(forProcessor: 0)
    #expect(consumerFinished.wait(timeout: .now() + 5) == .success)
    if let final = try session.pendingWorkGeneration(forProcessor: 0) {
      #expect(try session.acknowledgePendingWork(processor: 0, generation: final))
    }
    let snapshot = session.snapshot
    #expect(snapshot.pendingRequiredGenerations == snapshot.pendingAcknowledgedGenerations)
  }
}

private final class LockedValue<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: Value

  init(_ value: Value) { storage = value }

  var value: Value { lock.withLock { storage } }

  func set(_ value: Value) { lock.withLock { storage = value } }

  func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&storage) } }
}
