import Foundation
import Testing

@testable import DoryMachinePC

@Suite struct DoryPCRunConcurrentExecutionGateTests {
  @Test func earlyArrivalCannotPassUntilEveryParticipantArrives() throws {
    let gate = DoryPCRunConcurrentExecutionGate()
    try gate.begin(batch: 11, participants: [0, 1])
    let firstFinished = DispatchSemaphore(value: 0)
    let secondFinished = DispatchSemaphore(value: 0)
    let failures = ConcurrentGateLockedValue<[String]>([])

    Thread.detachNewThread {
      do { try gate.arriveAndWait(processor: 0, batch: 11) } catch {
        failures.mutate { $0.append("first: \(error)") }
      }
      firstFinished.signal()
    }
    try #require(
      gate.waitUntilArrived(
        processor: 0,
        batch: 11,
        until: Date(timeIntervalSinceNow: 5)
      )
    )
    #expect(firstFinished.wait(timeout: .now() + 0.05) == .timedOut)

    Thread.detachNewThread {
      do { try gate.arriveAndWait(processor: 1, batch: 11) } catch {
        failures.mutate { $0.append("second: \(error)") }
      }
      secondFinished.signal()
    }
    #expect(firstFinished.wait(timeout: .now() + 5) == .success)
    #expect(secondFinished.wait(timeout: .now() + 5) == .success)
    #expect(failures.value.isEmpty)
    try gate.finish(batch: 11)

    try gate.begin(batch: 12, participants: [1, 0])
    #expect(
      throws: DoryPCRunConcurrentExecutionGate.GateError.staleBatch(
        expected: 12,
        actual: 11
      )
    ) {
      try gate.arriveAndWait(processor: 0, batch: 11)
    }
    #expect(
      throws: DoryPCRunConcurrentExecutionGate.GateError.unexpectedParticipant(2)
    ) {
      try gate.arriveAndWait(processor: 2, batch: 12)
    }
    #expect(
      throws: DoryPCRunConcurrentExecutionGate.GateError.incompleteBatch(12)
    ) {
      try gate.finish(batch: 12)
    }
    gate.close()
  }

  @Test func closeCancelsAnEarlyArrivalAndFutureBatches() throws {
    let gate = DoryPCRunConcurrentExecutionGate()
    try gate.begin(batch: 1, participants: [0, 1])
    let finished = DispatchSemaphore(value: 0)
    let outcome = ConcurrentGateLockedValue<
      DoryPCRunConcurrentExecutionGate.GateError?
    >(nil)

    Thread.detachNewThread {
      do { try gate.arriveAndWait(processor: 0, batch: 1) } catch let error
        as DoryPCRunConcurrentExecutionGate.GateError
      { outcome.set(error) } catch {}
      finished.signal()
    }
    try #require(
      gate.waitUntilArrived(
        processor: 0,
        batch: 1,
        until: Date(timeIntervalSinceNow: 5)
      )
    )
    gate.close()
    #expect(finished.wait(timeout: .now() + 5) == .success)
    #expect(outcome.value == .closed)
    #expect(throws: DoryPCRunConcurrentExecutionGate.GateError.closed) {
      try gate.begin(batch: 2, participants: [0, 1])
    }
    gate.close()
  }

  @Test func admissionRejectsMalformedAndOverlappingBatches() throws {
    let gate = DoryPCRunConcurrentExecutionGate()
    #expect(throws: DoryPCRunConcurrentExecutionGate.GateError.invalidBatch(0)) {
      try gate.begin(batch: 0, participants: [0, 1])
    }
    for participants in [[Int](), [0], [0, 0], [-1, 0]] {
      #expect(throws: DoryPCRunConcurrentExecutionGate.GateError.invalidParticipants) {
        try gate.begin(batch: 1, participants: participants)
      }
    }
    try gate.begin(batch: 3, participants: [0, 1])
    #expect(throws: DoryPCRunConcurrentExecutionGate.GateError.activeBatch(3)) {
      try gate.begin(batch: 4, participants: [0, 1])
    }
    gate.close()
  }
}

private final class ConcurrentGateLockedValue<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: Value

  init(_ value: Value) { storage = value }
  var value: Value { lock.withLock { storage } }
  func set(_ value: Value) { lock.withLock { storage = value } }
  func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&storage) } }
}
