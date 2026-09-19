import Dispatch
import Darwin
import Testing

@testable import DoryDBTX86

@Suite struct DoryX86MemoryAccessCoordinatorTests {
  @Test func exclusiveLeaseBlocksOnlyOverlappingOrdinaryRanges() throws {
    let coordinator = DoryX86MemoryAccessCoordinator()
    let exclusive = coordinator.acquireExclusive(ranges: [0x1000..<0x1020])
    defer { exclusive.release() }

    let overlappingStarted = DispatchSemaphore(value: 0)
    let overlappingFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      overlappingStarted.signal()
      let lease = coordinator.acquireOrdinary(ranges: [0x1010..<0x1018])
      lease.release()
      overlappingFinished.signal()
    }
    overlappingStarted.wait()

    let disjointFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      let lease = coordinator.acquireOrdinary(ranges: [0x2000..<0x2008])
      lease.release()
      disjointFinished.signal()
    }
    #expect(disjointFinished.wait(timeout: .now() + 2) == .success)
    #expect(overlappingFinished.wait(timeout: .now() + .milliseconds(25)) == .timedOut)

    exclusive.release()
    #expect(overlappingFinished.wait(timeout: .now() + 2) == .success)
  }

  @Test func waitingExclusiveLeasePreventsOverlappingReaderBarging() throws {
    let coordinator = DoryX86MemoryAccessCoordinator()
    let firstReader = coordinator.acquireOrdinary(ranges: [0x3000..<0x3040])
    let writerEntered = DispatchSemaphore(value: 0)
    let releaseWriter = DispatchSemaphore(value: 0)
    let writerFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      let lease = coordinator.acquireExclusive(ranges: [0x3010..<0x3020])
      writerEntered.signal()
      releaseWriter.wait()
      lease.release()
      writerFinished.signal()
    }
    try waitUntil(timeout: .now() + 2) { coordinator.waitingExclusiveCount == 1 }

    let secondReaderEntered = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      let lease = coordinator.acquireOrdinary(ranges: [0x3018..<0x301C])
      secondReaderEntered.signal()
      lease.release()
    }
    #expect(secondReaderEntered.wait(timeout: .now() + .milliseconds(25)) == .timedOut)

    firstReader.release()
    #expect(writerEntered.wait(timeout: .now() + 2) == .success)
    #expect(secondReaderEntered.wait(timeout: .now() + .milliseconds(25)) == .timedOut)
    releaseWriter.signal()
    #expect(writerFinished.wait(timeout: .now() + 2) == .success)
    #expect(secondReaderEntered.wait(timeout: .now() + 2) == .success)
  }

  @Test func oneMultiRangeLeaseIsAtomicAndReentrantForItsOwner() {
    let coordinator = DoryX86MemoryAccessCoordinator()
    let exclusive = coordinator.acquireExclusive(
      ranges: [0x5000..<0x5010, 0x1000..<0x1010, 0x1008..<0x1020])
    let nested = coordinator.acquireOrdinary(ranges: [0x100C..<0x1014])
    nested.release()
    exclusive.release()
  }

  @Test func nativeLeaseBoundaryUsesTheSameAuthority() throws {
    let coordinator = DoryX86MemoryAccessCoordinator()
    let nativeToken = doryX86MemoryAccessBegin(
      UnsafeMutableRawPointer(bitPattern: UInt(coordinator.opaqueReference)),
      0x7000,
      16,
      1
    )
    try #require(nativeToken != 0)
    let ordinaryFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      let lease = coordinator.acquireOrdinary(ranges: [0x7008..<0x7010])
      lease.release()
      ordinaryFinished.signal()
    }
    #expect(ordinaryFinished.wait(timeout: .now() + .milliseconds(25)) == .timedOut)
    doryX86MemoryAccessEnd(
      UnsafeMutableRawPointer(bitPattern: UInt(coordinator.opaqueReference)), nativeToken)
    #expect(ordinaryFinished.wait(timeout: .now() + 2) == .success)
  }

  private func waitUntil(
    timeout: DispatchTime,
    _ predicate: () -> Bool
  ) throws {
    while DispatchTime.now() < timeout {
      if predicate() { return }
      sched_yield()
    }
    Issue.record("Timed out waiting for coordinator state")
  }
}
