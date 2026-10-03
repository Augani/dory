import Darwin
import Dispatch
import DoryJITRuntimeC
import Foundation
import Testing

@testable import DoryDBTX86

@Suite struct DoryX86MemoryAccessReentryTests {
  @Test(arguments: [false, true])
  func coveredCheckedAccessFinishesBeforeWaitingWriter(exclusiveOuter: Bool) throws {
    try proveCoveredReentry(exclusiveOuter: exclusiveOuter, nativeInner: false)
  }

  @Test func nativeCheckedAccessUsesTheSameCoveredReentryAuthority() throws {
    try proveCoveredReentry(exclusiveOuter: true, nativeInner: true)
  }

  @Test func discontiguousOwnerLeasesDoNotAuthorizeTheirUnleasedGap() throws {
    let coordinator = DoryX86MemoryAccessCoordinator()
    let first = ReentryLeaseSlot()
    let second = ReentryLeaseSlot()
    let ownerReady = DispatchSemaphore(value: 0)
    let beginNested = DispatchSemaphore(value: 0)
    let nestedStarted = DispatchSemaphore(value: 0)
    let nestedEntered = DispatchSemaphore(value: 0)
    let ownerFinished = DispatchSemaphore(value: 0)
    let writerEntered = DispatchSemaphore(value: 0)
    let releaseWriter = DispatchSemaphore(value: 0)
    let writerFinished = DispatchSemaphore(value: 0)
    defer {
      beginNested.signal()
      first.release()
      second.release()
      releaseWriter.signal()
    }
    startReentryThread {
      defer { ownerFinished.signal() }
      let a = coordinator.acquireOrdinary(ranges: [0x1000..<0x1010])
      let b = coordinator.acquireOrdinary(ranges: [0x1020..<0x1030])
      first.store(a)
      second.store(b)
      ownerReady.signal()
      guard beginNested.wait(timeout: .now() + 5) == .success else {
        a.release()
        b.release()
        return
      }
      nestedStarted.signal()
      let inner = coordinator.acquireOrdinary(ranges: [0x1000..<0x1030])
      nestedEntered.signal()
      inner.release()
      a.release()
      b.release()
    }
    try #require(ownerReady.wait(timeout: .now() + 2) == .success)
    startReentryThread {
      defer { writerFinished.signal() }
      let lease = coordinator.acquireExclusive(ranges: [0x1000..<0x1030])
      writerEntered.signal()
      _ = releaseWriter.wait(timeout: .now() + 5)
      lease.release()
    }
    try #require(waitForReentryCondition { coordinator.waitingExclusiveCount == 1 })
    beginNested.signal()
    try #require(nestedStarted.wait(timeout: .now() + 2) == .success)
    #expect(nestedEntered.wait(timeout: .now() + .milliseconds(100)) == .timedOut)
    // Release the original owner leases explicitly: a request that expands into
    // new bytes has to relinquish its old admission before waiting for a writer.
    first.release()
    second.release()
    try #require(writerEntered.wait(timeout: .now() + 2) == .success)
    #expect(nestedEntered.wait(timeout: .now() + .milliseconds(25)) == .timedOut)
    releaseWriter.signal()
    #expect(nestedEntered.wait(timeout: .now() + 2) == .success)
    #expect(ownerFinished.wait(timeout: .now() + 2) == .success)
    #expect(writerFinished.wait(timeout: .now() + 2) == .success)
    #expect(coordinator.activeLeaseCount == 0)
  }

  private func proveCoveredReentry(exclusiveOuter: Bool, nativeInner: Bool) throws {
    let coordinator = DoryX86MemoryAccessCoordinator()
    let outerSlot = ReentryLeaseSlot()
    let ownerReady = DispatchSemaphore(value: 0)
    let beginNested = DispatchSemaphore(value: 0)
    let nestedEntered = DispatchSemaphore(value: 0)
    let releaseOwner = DispatchSemaphore(value: 0)
    let ownerFinished = DispatchSemaphore(value: 0)
    let writerEntered = DispatchSemaphore(value: 0)
    let releaseWriter = DispatchSemaphore(value: 0)
    let writerFinished = DispatchSemaphore(value: 0)
    let readerEntered = DispatchSemaphore(value: 0)
    let readerFinished = DispatchSemaphore(value: 0)
    defer {
      beginNested.signal()
      releaseOwner.signal()
      outerSlot.release()
      releaseWriter.signal()
    }
    startReentryThread {
      defer { ownerFinished.signal() }
      let outer = exclusiveOuter
        ? coordinator.acquireExclusive(ranges: [0x1000..<0x1010, 0x1010..<0x1030])
        : coordinator.acquireOrdinary(ranges: [0x1000..<0x1010, 0x1010..<0x1030])
      outerSlot.store(outer)
      ownerReady.signal()
      guard beginNested.wait(timeout: .now() + 5) == .success else {
        outer.release()
        return
      }
      if nativeInner {
        let reference = UnsafeMutableRawPointer(bitPattern: UInt(coordinator.opaqueReference))
        let token = doryX86MemoryAccessBegin(reference, 0x1008, 16, 0)
        nestedEntered.signal()
        doryX86MemoryAccessEnd(reference, token)
      } else {
        let inner = coordinator.acquireOrdinary(ranges: [0x1008..<0x1018, 0x1020..<0x1028])
        nestedEntered.signal()
        inner.release()
      }
      _ = releaseOwner.wait(timeout: .now() + 5)
      outer.release()
    }
    try #require(ownerReady.wait(timeout: .now() + 2) == .success)
    startReentryThread {
      defer { writerFinished.signal() }
      let lease = coordinator.acquireExclusive(ranges: [0x1000..<0x1030])
      writerEntered.signal()
      _ = releaseWriter.wait(timeout: .now() + 5)
      lease.release()
    }
    try #require(waitForReentryCondition { coordinator.waitingExclusiveCount == 1 })
    startReentryThread {
      defer { readerFinished.signal() }
      let lease = coordinator.acquireOrdinary(ranges: [0x1010..<0x1018])
      readerEntered.signal()
      lease.release()
    }
    beginNested.signal()
    let nestedResult = nestedEntered.wait(timeout: .now() + 2)
    #expect(nestedResult == .success)
    // A failed implementation must still drain its fixture instead of leaving
    // the test process with the original owner/waiting-writer lock cycle.
    if nestedResult != .success {
      outerSlot.release()
      releaseWriter.signal()
      releaseOwner.signal()
      #expect(ownerFinished.wait(timeout: .now() + 2) == .success)
      #expect(writerFinished.wait(timeout: .now() + 2) == .success)
      #expect(readerFinished.wait(timeout: .now() + 2) == .success)
      return
    }
    #expect(writerEntered.wait(timeout: .now() + .milliseconds(25)) == .timedOut)
    #expect(readerEntered.wait(timeout: .now() + .milliseconds(25)) == .timedOut)
    releaseOwner.signal()
    #expect(ownerFinished.wait(timeout: .now() + 2) == .success)
    try #require(writerEntered.wait(timeout: .now() + 2) == .success)
    #expect(readerEntered.wait(timeout: .now() + .milliseconds(25)) == .timedOut)
    releaseWriter.signal()
    #expect(writerFinished.wait(timeout: .now() + 2) == .success)
    #expect(readerEntered.wait(timeout: .now() + 2) == .success)
    #expect(readerFinished.wait(timeout: .now() + 2) == .success)
    #expect(coordinator.activeLeaseCount == 0)
  }
}

private final class ReentryLeaseSlot: @unchecked Sendable {
  private let lock = NSLock()
  private var lease: DoryX86MemoryAccessLease?

  func store(_ lease: DoryX86MemoryAccessLease) { lock.withLock { self.lease = lease } }
  func release() { lock.withLock { lease }?.release() }
}

private func startReentryThread(_ operation: @escaping @Sendable () -> Void) {
  Thread.detachNewThread(operation)
}

private func waitForReentryCondition(_ condition: () -> Bool) -> Bool {
  let deadline = DispatchTime.now() + 2
  while DispatchTime.now() < deadline {
    if condition() { return true }
    usleep(1_000)
  }
  return condition()
}
