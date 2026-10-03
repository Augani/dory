import Dispatch
import Foundation
import Testing

@testable import DoryDBTX86

@Suite struct DoryX86MemoryAccessDiagnosticsTests {
  @Test func uncontendedAndCoveringBatchAdmissionsDoNotReadContentionClock() throws {
    let clock = ContentionClock([100, 175])
    let coordinator = DoryX86MemoryAccessCoordinator(contentionClock: { clock.now() })
    let exclusive = coordinator.acquireExclusive(ranges: [0x1000..<0x1010])
    let nested = coordinator.acquireOrdinary(ranges: [0x1004..<0x1008])
    #expect(coordinator.diagnostics.activeExclusiveLeases == 1)
    #expect(coordinator.diagnostics.activeOrdinaryLeases == 1)
    nested.release()
    exclusive.release()
    coordinator.withOrdinaryBatchAccess(range: 0x2000..<0x2100) {
      coordinator.withOrdinaryAccess(ranges: [0x2010..<0x2020]) {}
      coordinator.withOrdinaryAccess(ranges: [0x3000..<0x3010]) {}
    }
    let snapshot = coordinator.diagnostics
    #expect(snapshot.schemaVersion == 1)
    #expect(snapshot.ordinaryAcquisitions == 3)
    #expect(snapshot.exclusiveAcquisitions == 1)
    #expect(snapshot.contendedOrdinaryAcquisitions == 0)
    #expect(snapshot.contendedExclusiveAcquisitions == 0)
    #expect(snapshot.ordinaryWaitNanoseconds == 0 && snapshot.exclusiveWaitNanoseconds == 0)
    #expect(snapshot.activeOrdinaryLeases == 0 && snapshot.activeExclusiveLeases == 0)
    #expect(snapshot.waitingOrdinaryLeases == 0 && snapshot.waitingExclusiveLeases == 0)
    #expect(clock.callCount == 0)
    #expect(try JSONDecoder().decode(DoryX86MemoryAccessDiagnostics.self,
      from: JSONEncoder().encode(snapshot)) == snapshot)
  }

  @Test(arguments: [false, true])
  func oneBlockedRequestMeasuresOneCompletedWait(exclusiveRequest: Bool) throws {
    let clock = ContentionClock([100, 175])
    let coordinator = DoryX86MemoryAccessCoordinator(contentionClock: { clock.now() })
    let holder = exclusiveRequest
      ? coordinator.acquireOrdinary(ranges: [0x1000..<0x1020])
      : coordinator.acquireExclusive(ranges: [0x1000..<0x1020])
    defer { holder.release() }
    let finished = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      let lease = exclusiveRequest
        ? coordinator.acquireExclusive(ranges: [0x1010..<0x1018])
        : coordinator.acquireOrdinary(ranges: [0x1010..<0x1018])
      lease.release()
      finished.signal()
    }
    try #require(clock.waitStarted.wait(timeout: .now() + 2) == .success)
    let pending = coordinator.diagnostics
    #expect(pending.contendedOrdinaryAcquisitions == (exclusiveRequest ? 0 : 1))
    #expect(pending.contendedExclusiveAcquisitions == (exclusiveRequest ? 1 : 0))
    #expect(pending.waitingOrdinaryLeases == (exclusiveRequest ? 0 : 1))
    #expect(pending.waitingExclusiveLeases == (exclusiveRequest ? 1 : 0))
    #expect(pending.ordinaryWaitNanoseconds == 0 && pending.exclusiveWaitNanoseconds == 0)
    #expect(finished.wait(timeout: .now()) == .timedOut)
    // A disjoint release broadcasts while the request remains blocked. It must neither
    // inflate request counts nor require another timestamp for the same admission.
    let disjoint = coordinator.acquireOrdinary(ranges: [0x3000..<0x3008])
    disjoint.release()
    holder.release()
    try #require(finished.wait(timeout: .now() + 2) == .success)
    let completed = coordinator.diagnostics
    #expect(completed.ordinaryAcquisitions == 2)
    #expect(completed.exclusiveAcquisitions == 1)
    #expect(completed.ordinaryWaitNanoseconds == (exclusiveRequest ? 0 : 75))
    #expect(completed.exclusiveWaitNanoseconds == (exclusiveRequest ? 75 : 0))
    #expect(completed.waitingOrdinaryLeases == 0 && completed.waitingExclusiveLeases == 0)
    #expect(completed.activeOrdinaryLeases == 0 && completed.activeExclusiveLeases == 0)
    #expect(clock.callCount == 2)
    // Earlier snapshots are value observations, not mutable views of the coordinator.
    #expect(pending.ordinaryWaitNanoseconds == 0 && pending.exclusiveWaitNanoseconds == 0)
  }

  @Test func foreignDisjointAdmissionDoesNotReadClockOrWait() throws {
    let clock = ContentionClock([100, 175])
    let coordinator = DoryX86MemoryAccessCoordinator(contentionClock: { clock.now() })
    let holder = coordinator.acquireExclusive(ranges: [0x1000..<0x1010])
    defer { holder.release() }
    let finished = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      let lease = coordinator.acquireOrdinary(ranges: [0x2000..<0x2010])
      lease.release()
      finished.signal()
    }
    try #require(finished.wait(timeout: .now() + 2) == .success)
    let snapshot = coordinator.diagnostics
    #expect(snapshot.ordinaryAcquisitions == 1 && snapshot.exclusiveAcquisitions == 1)
    #expect(snapshot.contendedOrdinaryAcquisitions == 0)
    #expect(snapshot.contendedExclusiveAcquisitions == 0)
    #expect(clock.callCount == 0)
  }

  @Test(arguments: [false, true])
  func nativeAndCheckedRAMUseTheSameContentionCounters(native: Bool) throws {
    let clock = ContentionClock([10, 42])
    let coordinator = DoryX86MemoryAccessCoordinator(contentionClock: { clock.now() })
    let memory = try DoryX86ByteArrayMemory(byteCount: 64, memoryAccessCoordinator: coordinator)
    let ranges = try #require(try memory.memoryAccessRanges(at: 16, byteCount: 8, access: .read))
    let holder = coordinator.acquireExclusive(ranges: ranges)
    defer { holder.release() }
    let finished = DispatchSemaphore(value: 0)
    let failure = ContentionFailure()
    Thread.detachNewThread {
      defer { finished.signal() }
      if native {
        let reference = UnsafeMutableRawPointer(bitPattern: UInt(coordinator.opaqueReference))
        let token = doryX86MemoryAccessBegin(reference, ranges[0].lowerBound, 8, 0)
        if token == 0 { failure.record(.nativeLeaseRejected) }
        doryX86MemoryAccessEnd(reference, token)
      } else {
        do { _ = try memory.readScalar(at: 16, byteCount: 8) }
        catch { failure.record(error) }
      }
    }
    try #require(clock.waitStarted.wait(timeout: .now() + 2) == .success)
    #expect(coordinator.diagnostics.waitingOrdinaryLeases == 1)
    holder.release()
    try #require(finished.wait(timeout: .now() + 2) == .success)
    if let error = failure.error { throw error }
    let snapshot = coordinator.diagnostics
    #expect(snapshot.ordinaryAcquisitions == 1 && snapshot.exclusiveAcquisitions == 1)
    #expect(snapshot.contendedOrdinaryAcquisitions == 1)
    #expect(snapshot.contendedExclusiveAcquisitions == 0)
    #expect(snapshot.ordinaryWaitNanoseconds == 32)
    #expect(snapshot.exclusiveWaitNanoseconds == 0)
    #expect(snapshot.activeOrdinaryLeases == 0 && snapshot.activeExclusiveLeases == 0)
    #expect(clock.callCount == 2)
  }

  @Test func cumulativeWaitDurationSaturatesInsteadOfWrapping() throws {
    let clock = ContentionClock([0, .max, 0, 1])
    let coordinator = DoryX86MemoryAccessCoordinator(contentionClock: { clock.now() })
    for _ in 0..<2 {
      let holder = coordinator.acquireOrdinary(ranges: [0x1000..<0x1010])
      defer { holder.release() }
      let finished = DispatchSemaphore(value: 0)
      Thread.detachNewThread {
        let lease = coordinator.acquireExclusive(ranges: [0x1000..<0x1010])
        lease.release()
        finished.signal()
      }
      try #require(clock.waitStarted.wait(timeout: .now() + 2) == .success)
      holder.release()
      try #require(finished.wait(timeout: .now() + 2) == .success)
    }
    let snapshot = coordinator.diagnostics
    #expect(snapshot.exclusiveWaitNanoseconds == .max)
    #expect(snapshot.exclusiveAcquisitions == 2 && snapshot.ordinaryAcquisitions == 2)
    #expect(snapshot.contendedExclusiveAcquisitions == 2)
    #expect(snapshot.waitingExclusiveLeases == 0)
    #expect(clock.callCount == 4)
  }
}

private final class ContentionClock: @unchecked Sendable {
  let waitStarted = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private let samples: [UInt64]
  private var calls = 0
  init(_ samples: [UInt64]) { self.samples = samples }
  var callCount: Int { lock.withLock { calls } }
  func now() -> UInt64 {
    let result = lock.withLock { () -> (UInt64, Bool) in
      let index = calls
      calls += 1
      return (samples[min(index, samples.count - 1)], index % 2 == 0)
    }
    if result.1 { waitStarted.signal() }
    return result.0
  }
}

private final class ContentionFailure: @unchecked Sendable {
  enum Failure: Error { case nativeLeaseRejected }
  private let lock = NSLock()
  private var captured: (any Error)?
  var error: (any Error)? { lock.withLock { captured } }
  func record(_ error: any Error) { lock.withLock { captured = error } }
  func record(_ error: Failure) { record(error as any Error) }
}
