import Foundation
import Testing

@testable import DoryMachinePC

@Suite(.serialized) struct DoryPCHostWorkerCompletionWakeTests {
  @Test func callbackObservesPublishedResultOutsideCompletionLockExactlyOnce() throws {
    let observation = CompletionObservation()
    let completion = DoryPCHostWorker.Completion<Int>(onFinished: { observation.record($0) })
    try finishAndJoinNotification(completion, result: .success(42))
    try finishAndJoinNotification(completion, result: .failure(CompletionFailure.expected))

    #expect(observation.snapshot == .init(count: 1, finished: true, value: 42))
    #expect(try completion.wait() == 42)
    #expect(completion.waitUntilFinished(until: .distantPast))
  }

  @Test func failedCompletionAlsoPublishesBeforeNotification() throws {
    let observation = CompletionObservation()
    let completion = DoryPCHostWorker.Completion<Int>(onFinished: { observation.record($0) })
    try finishAndJoinNotification(completion, result: .failure(CompletionFailure.expected))
    try finishAndJoinNotification(completion, result: .success(42))

    #expect(observation.snapshot == .init(count: 1, finished: true, value: nil))
    #expect(throws: CompletionFailure.expected) { try completion.wait() }
  }

  @Test func concurrentDuplicateFinishesPublishAndNotifyOnlyOnce() throws {
    let observation = CompletionObservation()
    let completion = DoryPCHostWorker.Completion<Int>(onFinished: { observation.record($0) })
    let finished = DispatchGroup()
    for value in 0..<8 {
      finished.enter()
      DispatchQueue.global().async {
        completion.finish(.success(value))
        finished.leave()
      }
    }
    try #require(finished.wait(timeout: .now() + 2) == .success)
    #expect(observation.snapshot.count == 1)
    #expect(observation.snapshot.finished)
    #expect(observation.snapshot.value == (try completion.wait()))
  }

  @Test func completionBeforeSessionWaitRetainsItsWakeWithoutChangingGuestState() throws {
    let session = DoryPCRunSession(processorCount: 2, instructionBudget: 10, runGeneration: 42)
    let initial = session.snapshot
    let observation = CompletionObservation()
    let completion = DoryPCHostWorker.Completion<Int>(onFinished: {
      observation.record($0)
      session.notifyWorkerCompletion()
    })
    try finishAndJoinNotification(completion, result: .success(7))

    // The wake happened before wait admission. Its generation remains visible even with a past
    // deadline, so this cannot pass by waiting for a timeout or an unrelated metadata event.
    let next = session.waitForChange(after: initial.changeGeneration, until: .distantPast)
    #expect(next.changeGeneration > initial.changeGeneration)
    #expect(observation.snapshot == .init(count: 1, finished: true, value: 7))
    #expect(next.runGeneration == initial.runGeneration)
    #expect(next.remainingInstructionBudget == initial.remainingInstructionBudget)
    #expect(next.workerResults == initial.workerResults)
    #expect(next.workerDirectives == initial.workerDirectives)
    #expect(next.outstandingReservations == initial.outstandingReservations)
    #expect(next.terminationReason == initial.terminationReason)
  }

  @Test func completionAfterSessionWaitAdmissionWakesTheExactParkedWaiter() throws {
    #if DEBUG
      let session = DoryPCRunSession(processorCount: 1, instructionBudget: 10)
      let initial = session.snapshot
      let parked = DispatchSemaphore(value: 0)
      let returned = DispatchSemaphore(value: 0)
      let observedGeneration = CompletionWakeValue<UInt64?>(nil)
      session.beforeChangeWaitForTesting = { parked.signal() }
      let completion = DoryPCHostWorker.Completion<Int>(onFinished: { _ in
        session.notifyWorkerCompletion()
      })
      DispatchQueue.global().async {
        let next = session.waitForChange(
          after: initial.changeGeneration, until: Date(timeIntervalSinceNow: 2))
        observedGeneration.set(next.changeGeneration)
        returned.signal()
      }
      // The hook runs while the session condition is held. Notification therefore cannot take
      // that condition until the waiter atomically parks and releases it: no scheduling guess.
      try #require(parked.wait(timeout: .now() + 2) == .success)
      try finishAndJoinNotification(completion, result: .success(42))
      try #require(returned.wait(timeout: .now() + 2) == .success)
      #expect(observedGeneration.value != initial.changeGeneration)
      #expect(try completion.wait() == 42)
    #endif
  }

  @Test func actualWorkerRunLoopSubmissionNotifiesOnlyAfterItsCompletion() throws {
    let session = DoryPCRunSession(processorCount: 1, instructionBudget: 10)
    let worker = DoryPCHostWorker(processor: 0, onExit: {})
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    defer {
      release.signal()
      worker.stopAndJoin()
    }
    let initial = session.snapshot
    let observation = CompletionObservation()
    let completion = worker.submit(kind: .runLoop, onFinished: {
      observation.record($0)
      session.notifyWorkerCompletion()
    }) {
      started.signal()
      _ = release.wait(timeout: .now() + 2)
      return 42
    }
    try #require(started.wait(timeout: .now() + 2) == .success)
    #expect(!completion.isFinished)
    #expect(session.snapshot.changeGeneration == initial.changeGeneration)
    release.signal()
    let next = session.waitForChange(
      after: initial.changeGeneration, until: Date(timeIntervalSinceNow: 2))
    #expect(next.changeGeneration > initial.changeGeneration)
    #expect(observation.snapshot == .init(count: 1, finished: true, value: 42))
    #expect(try completion.wait() == 42)
  }

  @Test func cancelledQueuedJobPublishesFailureAndWakesWithoutExecutingIt() throws {
    let session = DoryPCRunSession(processorCount: 1, instructionBudget: 10)
    let worker = DoryPCHostWorker(processor: 0, onExit: {})
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    defer {
      release.signal()
      worker.stopAndJoin()
    }
    let active = worker.submit {
      started.signal()
      _ = release.wait(timeout: .now() + 2)
      return 1
    }
    try #require(started.wait(timeout: .now() + 2) == .success)
    let initial = session.snapshot
    let observation = CompletionObservation()
    let executed = CompletionWakeValue(false)
    let cancelled = worker.submit(kind: .runLoop, onFinished: {
      observation.record($0)
      session.notifyWorkerCompletion()
    }) {
      executed.set(true)
      return 42
    }
    worker.requestStop()
    release.signal()
    let next = session.waitForChange(
      after: initial.changeGeneration, until: Date(timeIntervalSinceNow: 2))
    #expect(next.changeGeneration > initial.changeGeneration)
    #expect(cancelled.isFinished)
    #expect(observation.snapshot == .init(count: 1, finished: true, value: nil))
    #expect(!executed.value)
    #expect(throws: DoryPCHostWorker.StopError.self) { try cancelled.wait() }
    #expect(try active.wait() == 1)
    worker.stopAndJoin()
    #expect(observation.snapshot.count == 1)
  }

  private func finishAndJoinNotification(
    _ completion: DoryPCHostWorker.Completion<Int>, result: Result<Int, any Error>
  ) throws {
    let returned = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      completion.finish(result)
      returned.signal()
    }
    // A regression that calls notification under the completion mutex reports a bounded
    // assertion failure rather than hanging the synchronous test thread in its callback.
    try #require(returned.wait(timeout: .now() + 2) == .success)
  }
}

private enum CompletionFailure: Error, Sendable, Equatable { case expected }

private final class CompletionObservation: @unchecked Sendable {
  struct Snapshot: Equatable {
    let count: Int
    let finished: Bool
    let value: Int?
  }

  private let lock = NSLock()
  private var stored = Snapshot(count: 0, finished: false, value: nil)
  var snapshot: Snapshot { lock.withLock { stored } }

  func record(_ completion: DoryPCHostWorker.Completion<Int>) {
    // These both acquire the completion condition: a callback invoked under its lock deadlocks.
    let finished = completion.isFinished
    let value = try? completion.wait()
    lock.withLock { stored = .init(count: stored.count + 1, finished: finished, value: value) }
  }
}

private final class CompletionWakeValue<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value
  init(_ value: Value) { stored = value }
  var value: Value { lock.withLock { stored } }
  func set(_ value: Value) { lock.withLock { stored = value } }
}
