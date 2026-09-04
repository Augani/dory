import Foundation
import Testing

@testable import DoryDBTX86

@Suite struct DoryX86HeapMemoryConstructionTests {
  @Test func everyPublicConstructorRejectsInvalidRangesBeforeBackingAllocation() throws {
    for count in [Int.min, -1, 0] {
      #expect(throws: DoryX86MemoryAllocationError.invalidByteCount(count)) {
        try DoryX86ByteArrayMemory(byteCount: count)
      }
      #expect(throws: DoryX86MemoryAllocationError.invalidByteCount(count)) {
        try DoryX86ByteArrayMemory(validatingByteCount: count)
      }
    }
    #expect(throws: DoryX86MemoryAllocationError.invalidByteCount(0)) {
      try DoryX86ByteArrayMemory(bytes: [])
    }
    let expected = DoryX86MemoryAllocationError.addressOverflow(baseAddress: .max - 1, byteCount: 2)
    #expect(throws: expected) { try DoryX86ByteArrayMemory(baseAddress: .max - 1, byteCount: 2) }
    #expect(throws: expected) { try DoryX86ByteArrayMemory(baseAddress: .max - 1, bytes: [1, 2]) }
    let tracker = HeapAllocationTracker(failure: ENOMEM)
    #expect(throws: expected) {
      try DoryX86ByteArrayMemory(baseAddress: .max - 1, byteCount: 2, allocator: tracker.allocator)
    }
    #expect(throws: DoryX86MemoryAllocationError.invalidByteCount(0)) {
      try DoryX86ByteArrayMemory(bytes: [], allocator: tracker.allocator)
    }
    #expect(tracker.snapshot.attempts.isEmpty)
    #expect(tracker.snapshot.released.isEmpty)
  }

  @Test func allocationFailurePropagatesExactSizeAndErrnoWithoutPublishingStorage() throws {
    let tracker = HeapAllocationTracker(failure: ENOMEM)
    let bytes: [UInt8] = [1, 2, 3, 4, 5]
    #expect(throws: DoryX86MemoryAllocationError.heapAllocationFailed(byteCount: 513, errorNumber: ENOMEM)) {
      try DoryX86ByteArrayMemory(byteCount: 513, allocator: tracker.allocator)
    }
    #expect(throws: DoryX86MemoryAllocationError.heapAllocationFailed(byteCount: bytes.count, errorNumber: ENOMEM)) {
      try DoryX86ByteArrayMemory(bytes: bytes, allocator: tracker.allocator)
    }
    #expect(bytes == [1, 2, 3, 4, 5])
    #expect(tracker.snapshot.attempts == [513, 5])
    #expect(tracker.snapshot.owned.isEmpty)
    #expect(tracker.snapshot.released.isEmpty)
  }

  @Test func heapBackingIsZeroedExactlySizedAndReleasedOnceAfterItsLastOwner() throws {
    let tracker = HeapAllocationTracker()
    weak var observed: DoryX86ByteArrayMemory?
    var retained: DoryX86ByteArrayMemory?
    do {
      let memory = try DoryX86ByteArrayMemory(
        baseAddress: 0x1003, byteCount: 8193, allocator: tracker.allocator)
      observed = memory
      retained = memory
      #expect(memory.baseAddress == 0x1003 && memory.byteCount == 8193)
      #expect(memory.snapshot() == Array(repeating: 0, count: 8193))
      try memory.writeScalar(at: 0x1004, value: 0x8877_6655_4433_2211, byteCount: 8)
      #expect(try memory.readScalar(at: 0x1004, byteCount: 8) == 0x8877_6655_4433_2211)
      #expect(tracker.snapshot.attempts == [8193])
      #expect(tracker.snapshot.owned.values.reduce(0, +) == memory.byteCount)
      #expect(tracker.snapshot.released.isEmpty)
    }
    #expect(observed != nil)
    withExtendedLifetime(retained) {}
    retained = nil
    #expect(observed == nil)
    #expect(tracker.snapshot.owned.isEmpty)
    #expect(tracker.snapshot.released == [8193])
  }

  @Test func initialBytesAndDiagnosticSnapshotsCannotAliasMutableHeapBacking() throws {
    let tracker = HeapAllocationTracker()
    do {
      var source: [UInt8] = [1, 2, 3, 4]
      let first = try DoryX86ByteArrayMemory(bytes: source, allocator: tracker.allocator)
      source[0] = 99
      let originalSnapshot = first.snapshot()
      let second = try DoryX86ByteArrayMemory(bytes: originalSnapshot, allocator: tracker.allocator)
      try first.write(at: 0, bytes: [7])
      #expect(source == [99, 2, 3, 4])
      #expect(originalSnapshot == [1, 2, 3, 4])
      #expect(first.snapshot() == [7, 2, 3, 4])
      #expect(second.snapshot() == originalSnapshot)
      #expect(tracker.snapshot.owned.count == 2)
      #expect(tracker.snapshot.owned.values.reduce(0, +) == 8)
    }
    #expect(tracker.snapshot.owned.isEmpty)
    #expect(tracker.snapshot.released == [4, 4])
  }
}

private final class HeapAllocationTracker: @unchecked Sendable {
  struct Snapshot {
    var attempts: [Int] = []
    var owned: [UInt: Int] = [:]
    var released: [Int] = []
  }

  private let lock = NSLock()
  private let failure: Int32?
  private var state = Snapshot()
  var snapshot: Snapshot { lock.withLock { state } }

  init(failure: Int32? = nil) { self.failure = failure }

  var allocator: DoryX86HeapAllocator {
    .init(
      allocate: { [self] byteCount in
        lock.withLock { state.attempts.append(byteCount) }
        if let failure { return (nil, failure) }
        let result = DoryX86HeapAllocator.system.allocate(byteCount)
        if let pointer = result.pointer {
          lock.withLock {
            #expect(state.owned.updateValue(byteCount, forKey: UInt(bitPattern: pointer)) == nil)
          }
        }
        return result
      },
      deallocate: { [self] pointer, byteCount in
        lock.withLock {
          #expect(state.owned.removeValue(forKey: UInt(bitPattern: pointer)) == byteCount)
          state.released.append(byteCount)
        }
        DoryX86HeapAllocator.system.deallocate(pointer, byteCount)
      }
    )
  }
}
