import Foundation
import Testing

@testable import DoryMachinePC

@Suite(.serialized) struct DoryPCRunSessionTests {
  @Test func immutableRunIdentityAndConfigurationArePublishedInEverySnapshot() {
    let session = DoryPCRunSession(
      processorCount: 2,
      instructionBudget: 10,
      runGeneration: 42,
      exceptionPolicy: .deliver,
      clockMode: .hostMonotonic
    )

    let snapshot = session.snapshot
    #expect(snapshot.runGeneration == 42)
    #expect(snapshot.exceptionPolicy == .deliver)
    #expect(snapshot.clockMode == .hostMonotonic)
    #expect(snapshot.workerResults == [nil, nil])
    #expect(snapshot.workerDirectives == [nil, nil])
    #expect(snapshot.workerCounters == [.zero, .zero])
    #expect(snapshot.mergedWorkerCounters == .zero)
    #expect(snapshot.pendingSourceGenerations == [nil, nil])
  }

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

  @Test func machinePendingSourcesPublishExactlyOneSessionEdgePerVCPU() throws {
    let session = DoryPCRunSession(processorCount: 2, instructionBudget: 1)

    let processor0 = try session.observePendingWork(processor: 0, sourceGeneration: 7)
    #expect(processor0 == 1)
    #expect(session.snapshot.pendingSourceGenerations == [7, nil])
    #expect(try session.pendingWorkGeneration(forProcessor: 0) == processor0)
    #expect(try session.acknowledgePendingWork(processor: 0, generation: processor0))

    let acknowledged = session.snapshot
    #expect(try session.observePendingWork(processor: 0, sourceGeneration: 7) == processor0)
    #expect(session.snapshot == acknowledged)

    let processor1 = try session.observePendingWork(processor: 1, sourceGeneration: 7)
    #expect(processor1 == 1)
    #expect(try session.pendingWorkGeneration(forProcessor: 0) == nil)
    #expect(try session.pendingWorkGeneration(forProcessor: 1) == processor1)

    let processor0Next = try session.observePendingWork(processor: 0, sourceGeneration: 8)
    #expect(processor0Next == processor0 + 1)
    #expect(session.snapshot.pendingSourceGenerations == [8, 7])
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
    let quiescencePending = session.snapshot.pendingRequiredGenerations
    #expect(
      try session.acknowledgePendingWork(processor: 0, generation: quiescencePending[0]))
    #expect(
      try session.acknowledgePendingWork(processor: 1, generation: quiescencePending[1]))
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

    let firstPending = session.snapshot.pendingRequiredGenerations
    #expect(try session.acknowledgePendingWork(processor: 0, generation: firstPending[0]))
    #expect(try session.acknowledgeQuiescence(processor: 0, generation: first))
    #expect(
      !session.waitForQuiescence(
        generation: first,
        until: Date(timeIntervalSinceNow: 0.025)
      ))
    #expect(try session.acknowledgePendingWork(processor: 1, generation: firstPending[1]))
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
    let secondPending = session.snapshot.pendingRequiredGenerations
    #expect(try session.acknowledgePendingWork(processor: 0, generation: secondPending[0]))
    #expect(try session.acknowledgePendingWork(processor: 1, generation: secondPending[1]))
    #expect(try session.acknowledgeQuiescence(processor: 0, generation: second))
    #expect(try session.acknowledgeQuiescence(processor: 1, generation: second))
  }

  @Test func pendingWorkReopensAnAcknowledgedQuiescenceBarrier() throws {
    let session = DoryPCRunSession(processorCount: 2, instructionBudget: 10)
    let quiescence = session.requestQuiescence()
    let initialPending = session.snapshot.pendingRequiredGenerations

    for processor in 0..<2 {
      #expect(
        try session.acknowledgePendingWork(
          processor: processor,
          generation: initialPending[processor]
        ))
    }
    #expect(try session.acknowledgeQuiescence(processor: 0, generation: quiescence))

    let republished = try session.publishPendingWork(forProcessor: 0)
    #expect(try !session.acknowledgeQuiescence(processor: 0, generation: quiescence))
    #expect(try session.acknowledgeQuiescence(processor: 1, generation: quiescence))
    #expect(
      !session.waitForQuiescence(
        generation: quiescence,
        until: Date(timeIntervalSinceNow: 0.025)
      ))

    #expect(
      try session.acknowledgePendingWork(
        processor: 0,
        generation: republished[0]
      ))
    #expect(try session.acknowledgeQuiescence(processor: 0, generation: quiescence))
    #expect(
      session.waitForQuiescence(
        generation: quiescence,
        until: Date(timeIntervalSinceNow: 0.1)
      ))
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

  @Test func workerResultsMergeCountersExactlyOnceAndRequireAnExactResponse() throws {
    let session = DoryPCRunSession(
      processorCount: 2,
      instructionBudget: 9,
      runGeneration: 17,
      exceptionPolicy: .deliver,
      clockMode: .hostMonotonic
    )
    let firstReservation = try #require(
      try session.reserve(processor: 0, maximumInstructions: 5))
    let secondReservation = try #require(
      try session.reserve(processor: 1, maximumInstructions: 5))
    let firstCounters = DoryPCRunSession.WorkerCounters(
      instructionCount: 5,
      interpreterInstructions: 2,
      baselineJITInstructions: 3,
      baselineJITBlocks: 1,
      optimizingJITInstructions: 0,
      optimizingJITBlocks: 0,
      executionCPUNanoseconds: 100,
      eventCPUNanoseconds: 10
    )
    let secondCounters = DoryPCRunSession.WorkerCounters(
      instructionCount: 4,
      interpreterInstructions: 0,
      baselineJITInstructions: 0,
      baselineJITBlocks: 0,
      optimizingJITInstructions: 4,
      optimizingJITBlocks: 2,
      executionCPUNanoseconds: 200,
      eventCPUNanoseconds: 20
    )

    let first = try session.completeAndPublish(
      firstReservation, outcome: .retired, counters: firstCounters)
    let second = try session.completeAndPublish(
      secondReservation, outcome: .yielded, counters: secondCounters)
    #expect(first.runGeneration == 17)
    #expect(second.runGeneration == 17)
    #expect(try session.workerResult(forProcessor: 0) == first)
    #expect(try session.workerResult(forProcessor: 1) == second)

    var snapshot = session.snapshot
    #expect(snapshot.totalRetiredInstructions == 9)
    #expect(snapshot.terminationReason == .instructionBudget)
    #expect(snapshot.workerCounters == [firstCounters, secondCounters])
    #expect(
      snapshot.mergedWorkerCounters
        == .init(
          instructionCount: 9,
          interpreterInstructions: 2,
          baselineJITInstructions: 3,
          baselineJITBlocks: 1,
          optimizingJITInstructions: 4,
          optimizingJITBlocks: 2,
          executionCPUNanoseconds: 300,
          eventCPUNanoseconds: 30
        ))

    let firstDirective = try session.respond(to: first, with: .resume)
    #expect(firstDirective.resultSequence == first.sequence)
    #expect(
      try session.consumeDirective(processor: 0, forResultSequence: first.sequence) == .resume)
    #expect(try session.respond(to: second, with: .stop).directive == .stop)
    #expect(try session.consumeDirective(processor: 1, forResultSequence: second.sequence) == .stop)
    snapshot = session.snapshot
    #expect(snapshot.workerResults == [nil, nil])
    #expect(snapshot.workerDirectives == [nil, nil])
  }

  @Test func invalidOrOverlappingWorkerPublicationFailsWithoutMutation() throws {
    let session = DoryPCRunSession(
      processorCount: 1,
      instructionBudget: 8,
      runGeneration: 7
    )
    let reservation = try #require(try session.reserve(processor: 0, maximumInstructions: 4))
    let reserved = session.snapshot
    let inconsistent = DoryPCRunSession.WorkerCounters(
      instructionCount: 4,
      interpreterInstructions: 1,
      baselineJITInstructions: 1
    )
    #expect(
      throws: DoryPCRunSession.SessionError.inconsistentWorkerCounters(processor: 0)
    ) {
      try session.completeAndPublish(
        reservation, outcome: .retired, counters: inconsistent)
    }
    #expect(session.snapshot == reserved)

    let counters = DoryPCRunSession.WorkerCounters(
      instructionCount: 4,
      interpreterInstructions: 4
    )
    let result = try session.completeAndPublish(
      reservation, outcome: .halted, counters: counters)
    let published = session.snapshot
    #expect(throws: DoryPCRunSession.SessionError.outstandingWorkerResult(0)) {
      try session.reserve(processor: 0, maximumInstructions: 1)
    }
    #expect(throws: DoryPCRunSession.SessionError.missingReservation(0)) {
      try session.completeAndPublish(
        reservation, outcome: .retired, counters: counters)
    }
    #expect(session.snapshot == published)

    let wrongRun = DoryPCRunSession.WorkerResult(
      runGeneration: 8,
      processor: result.processor,
      sequence: result.sequence,
      reservationSequence: result.reservationSequence,
      acknowledgedPendingWorkGeneration: result.acknowledgedPendingWorkGeneration,
      outcome: result.outcome,
      counters: result.counters
    )
    #expect(
      throws: DoryPCRunSession.SessionError.staleRunGeneration(
        expected: 7,
        actual: 8
      )
    ) {
      try session.respond(to: wrongRun, with: .stop)
    }
    #expect(session.snapshot == published)

    let mismatched = DoryPCRunSession.WorkerResult(
      runGeneration: result.runGeneration,
      processor: result.processor,
      sequence: result.sequence,
      reservationSequence: result.reservationSequence,
      acknowledgedPendingWorkGeneration: result.acknowledgedPendingWorkGeneration,
      outcome: .retired,
      counters: result.counters
    )
    #expect(
      throws: DoryPCRunSession.SessionError.mismatchedWorkerResult(
        processor: 0,
        sequence: result.sequence
      )
    ) {
      try session.respond(to: mismatched, with: .stop)
    }
    #expect(session.snapshot == published)

    let mismatchedAcknowledgement = DoryPCRunSession.WorkerResult(
      runGeneration: result.runGeneration,
      processor: result.processor,
      sequence: result.sequence,
      reservationSequence: result.reservationSequence,
      acknowledgedPendingWorkGeneration: result.acknowledgedPendingWorkGeneration &+ 1,
      outcome: result.outcome,
      counters: result.counters
    )
    #expect(
      throws: DoryPCRunSession.SessionError.mismatchedWorkerResult(
        processor: 0,
        sequence: result.sequence
      )
    ) {
      try session.respond(to: mismatchedAcknowledgement, with: .stop)
    }
    #expect(session.snapshot == published)

    let stale = DoryPCRunSession.WorkerResult(
      runGeneration: result.runGeneration,
      processor: result.processor,
      sequence: result.sequence &+ 1,
      reservationSequence: result.reservationSequence,
      acknowledgedPendingWorkGeneration: result.acknowledgedPendingWorkGeneration,
      outcome: result.outcome,
      counters: result.counters
    )
    #expect(
      throws: DoryPCRunSession.SessionError.staleWorkerResult(
        processor: 0,
        expected: result.sequence,
        actual: stale.sequence
      )
    ) {
      try session.respond(to: stale, with: .stop)
    }
    #expect(session.snapshot == published)

    _ = try session.respond(to: result, with: .stop)
    #expect(throws: DoryPCRunSession.SessionError.outstandingWorkerDirective(0)) {
      try session.reserve(processor: 0, maximumInstructions: 1)
    }
    #expect(
      throws: DoryPCRunSession.SessionError.staleWorkerDirective(
        processor: 0,
        expected: result.sequence,
        actual: result.sequence &+ 1
      )
    ) {
      try session.consumeDirective(
        processor: 0,
        forResultSequence: result.sequence &+ 1
      )
    }
    #expect(try session.consumeDirective(processor: 0, forResultSequence: result.sequence) == .stop)
    #expect(try session.reserve(processor: 0, maximumInstructions: 1) != nil)
  }

  @Test func earlyCoordinatorResponseCannotBeLostBeforeWorkerWaits() throws {
    let session = DoryPCRunSession(processorCount: 1, instructionBudget: 1)
    let reservation = try #require(try session.reserve(processor: 0, maximumInstructions: 1))
    let result = try session.completeAndPublish(
      reservation,
      outcome: .retired,
      counters: .init(instructionCount: 1, interpreterInstructions: 1)
    )
    _ = try session.respond(to: result, with: .stop)

    #expect(
      try session.waitForDirective(
        processor: 0,
        forResultSequence: result.sequence
      ) == .stop)
    #expect(session.snapshot.workerDirectives == [nil])
  }

  @Test func hostFailureCanReturnItsReservationAndCompleteTheExactStopHandshake() throws {
    let session = DoryPCRunSession(
      processorCount: 1,
      instructionBudget: 64,
      runGeneration: 23
    )
    let reservation = try #require(
      try session.reserve(processor: 0, maximumInstructions: 32))
    try session.requestTermination(.hostFailure(processor: 0))
    let result = try session.completeAndPublish(
      reservation,
      outcome: .hostFailure,
      counters: .init(executionCPUNanoseconds: 17)
    )
    #expect(session.snapshot.remainingInstructionBudget == 64)
    #expect(session.snapshot.terminationReason == .hostFailure(processor: 0))

    _ = try session.respond(to: result, with: .stop)
    #expect(
      try session.waitForDirective(
        processor: 0,
        forResultSequence: result.sequence
      ) == .stop)
    #expect(session.snapshot.workerResults == [nil])
    #expect(session.snapshot.workerDirectives == [nil])
  }

  @Test func tenThousandWorkerHandoffsRetireAndMergeTheExactBudget() throws {
    let processorCount = 4
    let instructionBudget: UInt64 = 10_000
    let session = DoryPCRunSession(
      processorCount: processorCount,
      instructionBudget: instructionBudget,
      runGeneration: 99,
      clockMode: .hostMonotonic
    )
    let failures = LockedValue<[String]>([])
    let finished = DispatchGroup()

    for processor in 0..<processorCount {
      finished.enter()
      DispatchQueue.global().async {
        defer { finished.leave() }
        do {
          while let reservation = try session.reserve(
            processor: processor,
            maximumInstructions: 1
          ) {
            let result = try session.completeAndPublish(
              reservation,
              outcome: .retired,
              counters: .init(instructionCount: 1, interpreterInstructions: 1)
            )
            guard
              let directive = try session.waitForDirective(
                processor: processor,
                forResultSequence: result.sequence,
                until: Date(timeIntervalSinceNow: 5)
              )
            else {
              failures.mutate { $0.append("worker \(processor) directive timeout") }
              return
            }
            if directive == .stop { return }
          }
        } catch {
          failures.mutate { $0.append("worker \(processor): \(error)") }
        }
      }
    }

    var responded: UInt64 = 0
    var observedChange = session.snapshot.changeGeneration
    while responded < instructionBudget {
      let snapshot = session.snapshot
      var madeProgress = false
      for result in snapshot.workerResults.compactMap({ $0 }) {
        let final = responded + 1 == instructionBudget
        _ = try session.respond(to: result, with: final ? .stop : .resume)
        responded += 1
        madeProgress = true
      }
      if !madeProgress {
        let next = session.waitForChange(
          after: observedChange,
          until: Date(timeIntervalSinceNow: 5)
        )
        #expect(next.changeGeneration != observedChange)
        observedChange = next.changeGeneration
      }
    }

    // A worker may already have published its final result when the coordinator reaches the exact
    // budget through another worker. Respond to every remaining mailbox so no owner is stranded.
    while session.snapshot.workerResults.contains(where: { $0 != nil }) {
      for result in session.snapshot.workerResults.compactMap({ $0 }) {
        _ = try session.respond(to: result, with: .stop)
      }
    }
    #expect(finished.wait(timeout: .now() + 5) == .success)
    let snapshot = session.snapshot
    #expect(failures.value.isEmpty)
    #expect(responded == instructionBudget)
    #expect(snapshot.totalRetiredInstructions == instructionBudget)
    #expect(snapshot.mergedWorkerCounters.instructionCount == instructionBudget)
    #expect(snapshot.mergedWorkerCounters.interpreterInstructions == instructionBudget)
    #expect(snapshot.workerCounters.map(\.instructionCount).reduce(0, +) == instructionBudget)
    #expect(snapshot.workerResults.allSatisfy { $0 == nil })
    #expect(snapshot.workerDirectives.allSatisfy { $0 == nil })
    #expect(snapshot.terminationReason == .instructionBudget)
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
