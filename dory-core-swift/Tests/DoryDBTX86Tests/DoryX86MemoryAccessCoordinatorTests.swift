import Darwin
import Dispatch
import DoryJITRuntimeC
import Foundation
import Testing

@testable import DoryDBTX86

@Suite struct DoryX86MemoryAccessCoordinatorTests {
  @Test func exclusiveLeaseBlocksOnlyOverlappingOrdinaryRanges() throws {
    let coordinator = DoryX86MemoryAccessCoordinator()
    let exclusive = coordinator.acquireExclusive(ranges: [0x1000..<0x1020])
    defer { exclusive.release() }

    let overlappingStarted = DispatchSemaphore(value: 0)
    let overlappingFinished = DispatchSemaphore(value: 0)
    startMemoryAccessThread {
      overlappingStarted.signal()
      let lease = coordinator.acquireOrdinary(ranges: [0x1010..<0x1018])
      lease.release()
      overlappingFinished.signal()
    }
    overlappingStarted.wait()

    let disjointFinished = DispatchSemaphore(value: 0)
    startMemoryAccessThread {
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
    startMemoryAccessThread {
      let lease = coordinator.acquireExclusive(ranges: [0x3010..<0x3020])
      writerEntered.signal()
      releaseWriter.wait()
      lease.release()
      writerFinished.signal()
    }
    try waitUntil(timeout: .now() + 2) { coordinator.waitingExclusiveCount == 1 }

    let secondReaderEntered = DispatchSemaphore(value: 0)
    startMemoryAccessThread {
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

  @Test func boundedOrdinaryBatchReusesItsCoveringLeaseButNotOutsideRanges() {
    let coordinator = DoryX86MemoryAccessCoordinator()
    coordinator.withOrdinaryBatchAccess(range: 0x1000..<0x2000) {
      #expect(coordinator.activeLeaseCount == 1)
      coordinator.withOrdinaryAccess(ranges: [0x1010..<0x1020, 0x1FF0..<0x2000]) {
        #expect(coordinator.activeLeaseCount == 1)
      }
      coordinator.withOrdinaryAccess(ranges: [0x3000..<0x3010]) {
        #expect(coordinator.activeLeaseCount == 2)
      }
      #expect(coordinator.activeLeaseCount == 1)
    }
    #expect(coordinator.activeLeaseCount == 0)
  }

  @Test func boundedOrdinaryBatchRetainsExclusiveConflictUntilItsBoundary() throws {
    let coordinator = DoryX86MemoryAccessCoordinator()
    let writerStarted = DispatchSemaphore(value: 0)
    let writerFinished = DispatchSemaphore(value: 0)
    coordinator.withOrdinaryBatchAccess(range: 0x1000..<0x2000) {
      startMemoryAccessThread {
        writerStarted.signal()
        let lease = coordinator.acquireExclusive(ranges: [0x1800..<0x1810])
        lease.release()
        writerFinished.signal()
      }
      writerStarted.wait()
      try! waitUntil(timeout: .now() + 2) { coordinator.waitingExclusiveCount == 1 }
      #expect(writerFinished.wait(timeout: .now() + .milliseconds(25)) == .timedOut)
    }
    #expect(writerFinished.wait(timeout: .now() + 2) == .success)
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
    startMemoryAccessThread {
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
    startMemoryAccessThread {
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
    startMemoryAccessThread {
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

  @Test func unalignedLockedInterpreterFallbackExcludesOverlappingOrdinaryAccess() throws {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x200)
    try memory.write(at: 0, bytes: [0xF0, 0x48, 0x01, 0x06])  // lock add [rsi],rax
    try memory.writeScalar(at: 0x101, value: 7, byteCount: 8)
    let ranges = try #require(
      try memory.memoryAccessRanges(at: 0x101, byteCount: 8, access: .write))
    let ordinary = memory.memoryAccessCoordinator.acquireOrdinary(ranges: ranges)
    let started = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    startMemoryAccessThread {
      var state = try! DoryX86ArchitecturalState(
        registers: .init(rax: 5, rsi: 0x101),
        rip: 0
      )
      started.signal()
      _ = DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
      finished.signal()
    }
    started.wait()
    #expect(finished.wait(timeout: .now() + .milliseconds(25)) == .timedOut)

    ordinary.release()
    #expect(finished.wait(timeout: .now() + 2) == .success)
    #expect(try memory.readScalar(at: 0x101, byteCount: 8) == 12)
  }

  @Test func interpreterCMPXCHG16BExcludesOverlappingOrdinaryAccess() throws {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x200)
    try memory.write(at: 0, bytes: [0xF0, 0x48, 0x0F, 0xC7, 0x0F])  // lock cmpxchg16b [rdi]
    try memory.writeScalar(at: 0x100, value: 0x1111, byteCount: 8)
    try memory.writeScalar(at: 0x108, value: 0x2222, byteCount: 8)
    let ranges = try #require(
      try memory.memoryAccessRanges(at: 0x100, byteCount: 16, access: .write))
    let ordinary = memory.memoryAccessCoordinator.acquireOrdinary(ranges: ranges)
    let started = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    startMemoryAccessThread {
      var state = try! DoryX86ArchitecturalState(
        registers: .init(
          rax: 0x1111,
          rcx: 0xBBBB,
          rdx: 0x2222,
          rbx: 0xAAAA,
          rdi: 0x100
        ),
        rip: 0
      )
      started.signal()
      _ = DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
      finished.signal()
    }
    started.wait()
    #expect(finished.wait(timeout: .now() + .milliseconds(25)) == .timedOut)

    ordinary.release()
    #expect(finished.wait(timeout: .now() + 2) == .success)
    #expect(try memory.readScalar(at: 0x100, byteCount: 8) == 0xAAAA)
    #expect(try memory.readScalar(at: 0x108, byteCount: 8) == 0xBBBB)
  }

  @Test func splitBackingLockedFallbackAcquiresOneMultiRangeLease() throws {
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
    try memory.write(at: 0, bytes: [0xF0, 0x48, 0x01, 0x06])  // lock add [rsi],rax
    let address = UInt64(pageByteCount - 4)
    try memory.writeScalar(at: address, value: 9, byteCount: 8)
    let ranges = try #require(
      try memory.memoryAccessRanges(at: address, byteCount: 8, access: .write))
    try #require(ranges.count == 2)
    let ordinary = memory.memoryAccessCoordinator.acquireOrdinary(ranges: [ranges[1]])
    let started = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    startMemoryAccessThread {
      var state = try! DoryX86ArchitecturalState(
        registers: .init(rax: 4, rsi: address),
        rip: 0
      )
      started.signal()
      _ = DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
      finished.signal()
    }
    started.wait()
    #expect(finished.wait(timeout: .now() + .milliseconds(25)) == .timedOut)

    ordinary.release()
    #expect(finished.wait(timeout: .now() + 2) == .success)
    #expect(try memory.readScalar(at: address, byteCount: 8) == 13)
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

private func startMemoryAccessThread(_ operation: @escaping @Sendable () -> Void) {
  let thread = Thread(block: operation)
  thread.name = "dev.dory.tests.x86-memory-access"
  thread.start()
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
