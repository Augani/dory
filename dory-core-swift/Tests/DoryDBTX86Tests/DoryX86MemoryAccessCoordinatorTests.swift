import Darwin
import Dispatch
import DoryJITRuntimeC
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

  @Test func checkedRAMAccessesEnterTheBackingRangeAuthority() throws {
    let memory = try DoryX86ByteArrayMemory(byteCount: 64)
    let ranges = try #require(
      try memory.memoryAccessRanges(at: 16, byteCount: 8, access: .write))
    let exclusive = memory.memoryAccessCoordinator.acquireExclusive(ranges: ranges)
    let writeStarted = DispatchSemaphore(value: 0)
    let writeFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      writeStarted.signal()
      try! memory.writeScalar(at: 16, value: 0x8877_6655_4433_2211, byteCount: 8)
      writeFinished.signal()
    }
    writeStarted.wait()
    #expect(writeFinished.wait(timeout: .now() + .milliseconds(25)) == .timedOut)

    exclusive.release()
    #expect(writeFinished.wait(timeout: .now() + 2) == .success)
    #expect(try memory.readScalar(at: 16, byteCount: 8) == 0x8877_6655_4433_2211)
  }

  @Test func sparseMmapRangesUseActualDiscontiguousHostBacking() throws {
    let pageByteCount = Int(getpagesize())
    let memory = try DoryX86MmapMemory(
      validatingByteCount: pageByteCount * 2,
      hostAddressSpaceByteCount: pageByteCount * 3,
      ramMappings: [
        .init(logicalOffset: 0, hostOffset: 0, byteCount: pageByteCount),
        .init(
          logicalOffset: pageByteCount,
          hostOffset: pageByteCount * 2,
          byteCount: pageByteCount),
      ]
    )
    let ranges = try #require(
      try memory.memoryAccessRanges(
        at: UInt64(pageByteCount - 4), byteCount: 8, access: .read))
    #expect(ranges.count == 2)
    #expect(ranges[0].count == 4)
    #expect(ranges[1].count == 4)
    #expect(ranges[0].lowerBound == memory.hostAddressSpaceBase + UInt64(pageByteCount - 4))
    #expect(ranges[1].lowerBound == memory.hostAddressSpaceBase + UInt64(pageByteCount * 2))
    #expect(ranges[0].upperBound < ranges[1].lowerBound)
  }

  @Test func nativeRangedScalarHelpersEnterTheSameBackingAuthority() throws {
    let coordinator = DoryX86MemoryAccessCoordinator()
    let fixture = NativeRangedScalarFixture(coordinator: coordinator)
    let lowerBound = UInt64(UInt(bitPattern: UnsafeRawPointer(fixture.value)))
    let exclusive = coordinator.acquireExclusive(
      ranges: [lowerBound..<(lowerBound + UInt64(MemoryLayout<UInt64>.size))])
    let storeStarted = DispatchSemaphore(value: 0)
    let storeFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      storeStarted.signal()
      fixture.storeResult = dory_jit_ranged_store_from_context(
        UnsafePointer(fixture.context),
        UnsafeMutableRawPointer(fixture.value),
        0x0123_4567_89AB_CDEF,
        UInt32(MemoryLayout<UInt64>.size)
      )
      storeFinished.signal()
    }
    storeStarted.wait()
    #expect(storeFinished.wait(timeout: .now() + .milliseconds(25)) == .timedOut)

    exclusive.release()
    #expect(storeFinished.wait(timeout: .now() + 2) == .success)
    #expect(fixture.storeResult == 0)
    #expect(fixture.value.pointee == 0x0123_4567_89AB_CDEF)

    var loaded: UInt64 = 0
    #expect(
      dory_jit_ranged_load_from_context(
        UnsafePointer(fixture.context),
        UnsafeRawPointer(fixture.value),
        UInt32(MemoryLayout<UInt64>.size),
        &loaded
      ) == 0)
    #expect(loaded == 0x0123_4567_89AB_CDEF)
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

private final class NativeRangedScalarFixture: @unchecked Sendable {
  let context: UnsafeMutablePointer<UInt64>
  let value: UnsafeMutablePointer<UInt64>
  var storeResult: Int32 = -1

  init(coordinator: DoryX86MemoryAccessCoordinator) {
    context = .allocate(capacity: DoryJITExecutableRegion.contextWordCount)
    context.initialize(repeating: 0, count: DoryJITExecutableRegion.contextWordCount)
    context[DoryJITExecutableRegion.memoryAccessCoordinatorWordIndex] =
      coordinator.opaqueReference
    value = .allocate(capacity: 1)
    value.initialize(to: 0)
  }

  deinit {
    context.deinitialize(count: DoryJITExecutableRegion.contextWordCount)
    context.deallocate()
    value.deinitialize(count: 1)
    value.deallocate()
  }
}
