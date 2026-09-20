import Darwin
import DoryJITRuntimeC
import Foundation

/// Machine-owned byte-range rendezvous for guest RAM.
///
/// Ordinary CPU, generated-code, DMA, and shared-mapping accesses enter as shared leases. A
/// split, unaligned, or otherwise non-lock-free locked transaction enters as an exclusive lease
/// over every physical backing range it may touch. Only overlapping ranges conflict; unrelated
/// guest RAM remains concurrent. Waiting exclusive leases participate in admission so a stream of
/// ordinary accesses cannot starve a locked transaction indefinitely.
public final class DoryX86MemoryAccessCoordinator: @unchecked Sendable {
  private struct LeaseRecord {
    let owner: UInt64
    let ranges: [Range<UInt64>]
    let exclusive: Bool
  }

  private let condition = NSCondition()
  private var nextToken: UInt64 = 1
  private var active: [UInt64: LeaseRecord] = [:]
  private var waitingExclusive: [UInt64: LeaseRecord] = [:]

  public init() {}

  /// Enters one ordinary access. The supplied ranges must use the shared backing-address
  /// coordinate system exposed by the owning memory object.
  public func acquireOrdinary(ranges: [Range<UInt64>]) -> DoryX86MemoryAccessLease {
    acquire(ranges: ranges, exclusive: false)
  }

  /// Enters one indivisible transaction over every supplied backing range.
  public func acquireExclusive(ranges: [Range<UInt64>]) -> DoryX86MemoryAccessLease {
    acquire(ranges: ranges, exclusive: true)
  }

  public func withOrdinaryAccess<Result>(
    ranges: [Range<UInt64>],
    _ operation: () throws -> Result
  ) rethrows -> Result {
    if isInsideCoveringOrdinaryBatch(ranges) { return try operation() }
    let lease = acquireOrdinary(ranges: ranges)
    defer { lease.release() }
    return try operation()
  }

  /// Coalesces a bounded owner-thread sequence of ordinary accesses beneath one admitted lease.
  /// Nested ordinary ranges covered by the batch bypass coordinator bookkeeping, but the outer
  /// lease remains active throughout: overlapping exclusive work still waits, and an exclusive
  /// access issued by this same thread retains the coordinator's existing reentrant semantics.
  public func withOrdinaryBatchAccess<Result>(
    range: Range<UInt64>,
    _ operation: () throws -> Result
  ) rethrows -> Result {
    precondition(!range.isEmpty, "memory access batch requires a nonempty range")
    let lease = acquireOrdinary(ranges: [range])
    let reference = UnsafeRawPointer(bitPattern: UInt(opaqueReference))
    precondition(
      dory_memory_access_batch_begin(reference, range.lowerBound, range.upperBound) == 0,
      "nested memory access batches are unsupported"
    )
    defer {
      dory_memory_access_batch_end(reference)
      lease.release()
    }
    return try operation()
  }

  public func withExclusiveAccess<Result>(
    ranges: [Range<UInt64>],
    _ operation: () throws -> Result
  ) rethrows -> Result {
    let lease = acquireExclusive(ranges: ranges)
    defer { lease.release() }
    return try operation()
  }

  var opaqueReference: UInt64 {
    UInt64(UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque()))
  }

  var waitingExclusiveCount: Int {
    condition.withLock { waitingExclusive.count }
  }

  var activeLeaseCount: Int {
    condition.withLock { active.count }
  }

  private func isInsideCoveringOrdinaryBatch(_ ranges: [Range<UInt64>]) -> Bool {
    guard !ranges.isEmpty else { return false }
    let reference = UnsafeRawPointer(bitPattern: UInt(opaqueReference))
    return ranges.allSatisfy {
      dory_memory_access_batch_contains(reference, $0.lowerBound, $0.upperBound) != 0
    }
  }

  private func acquire(
    ranges inputRanges: [Range<UInt64>],
    exclusive: Bool
  ) -> DoryX86MemoryAccessLease {
    let ranges = Self.normalized(inputRanges)
    precondition(!ranges.isEmpty, "memory access lease requires a nonempty range")
    let owner = UInt64(pthread_mach_thread_np(pthread_self()))
    condition.lock()
    let token = allocateToken()
    let record = LeaseRecord(owner: owner, ranges: ranges, exclusive: exclusive)
    if exclusive { waitingExclusive[token] = record }
    while conflicts(record, token: token) { condition.wait() }
    if exclusive { waitingExclusive.removeValue(forKey: token) }
    active[token] = record
    condition.unlock()
    return DoryX86MemoryAccessLease(coordinator: self, token: token)
  }

  fileprivate func release(token: UInt64) {
    condition.lock()
    precondition(active.removeValue(forKey: token) != nil, "unknown memory access lease")
    condition.broadcast()
    condition.unlock()
  }

  private func allocateToken() -> UInt64 {
    while nextToken == 0 || active[nextToken] != nil || waitingExclusive[nextToken] != nil {
      nextToken &+= 1
    }
    let token = nextToken
    nextToken &+= 1
    return token
  }

  private func conflicts(_ candidate: LeaseRecord, token: UInt64) -> Bool {
    for record in active.values where record.owner != candidate.owner {
      if (candidate.exclusive || record.exclusive), Self.overlaps(candidate.ranges, record.ranges) {
        return true
      }
    }
    guard !candidate.exclusive else { return false }
    // Give already-waiting overlapping writers priority over new ordinary accesses. A lease
    // owned by this thread is ignored so nested memory helpers cannot deadlock themselves.
    for (waitingToken, record) in waitingExclusive
    where waitingToken != token && record.owner != candidate.owner {
      if Self.overlaps(candidate.ranges, record.ranges) { return true }
    }
    return false
  }

  private static func normalized(_ ranges: [Range<UInt64>]) -> [Range<UInt64>] {
    let sorted = ranges.filter { !$0.isEmpty }.sorted {
      $0.lowerBound == $1.lowerBound
        ? $0.upperBound < $1.upperBound
        : $0.lowerBound < $1.lowerBound
    }
    guard var current = sorted.first else { return [] }
    var result: [Range<UInt64>] = []
    for range in sorted.dropFirst() {
      if range.lowerBound <= current.upperBound {
        current = current.lowerBound..<max(current.upperBound, range.upperBound)
      } else {
        result.append(current)
        current = range
      }
    }
    result.append(current)
    return result
  }

  private static func overlaps(
    _ lhs: [Range<UInt64>],
    _ rhs: [Range<UInt64>]
  ) -> Bool {
    var lhsIndex = 0
    var rhsIndex = 0
    while lhsIndex < lhs.count, rhsIndex < rhs.count {
      let left = lhs[lhsIndex]
      let right = rhs[rhsIndex]
      if left.lowerBound < right.upperBound, right.lowerBound < left.upperBound { return true }
      if left.upperBound <= right.lowerBound {
        lhsIndex += 1
      } else {
        rhsIndex += 1
      }
    }
    return false
  }
}

/// Explicit lease rather than a closure-only API lets translated memory resolve every backing
/// page first, acquire all ranges in one deadlock-free operation, and then execute its existing
/// precise-fault path. Release is idempotent so error unwinding and native helper exits are safe.
public final class DoryX86MemoryAccessLease: @unchecked Sendable {
  private let lock = NSLock()
  fileprivate var coordinator: DoryX86MemoryAccessCoordinator?
  fileprivate let token: UInt64

  fileprivate init(coordinator: DoryX86MemoryAccessCoordinator, token: UInt64) {
    self.coordinator = coordinator
    self.token = token
  }

  public func release() {
    let coordinator = lock.withLock { () -> DoryX86MemoryAccessCoordinator? in
      defer { self.coordinator = nil }
      return self.coordinator
    }
    coordinator?.release(token: token)
  }

  deinit { release() }
}

@_cdecl("dory_x86_memory_access_begin")
public func doryX86MemoryAccessBegin(
  _ opaque: UnsafeMutableRawPointer?,
  _ address: UInt64,
  _ byteCount: UInt32,
  _ exclusive: UInt8
) -> UInt64 {
  guard let opaque, byteCount > 0 else { return 0 }
  let (upperBound, overflow) = address.addingReportingOverflow(UInt64(byteCount))
  guard !overflow else { return 0 }
  let coordinator = Unmanaged<DoryX86MemoryAccessCoordinator>.fromOpaque(opaque)
    .takeUnretainedValue()
  let lease = exclusive == 0
    ? coordinator.acquireOrdinary(ranges: [address..<upperBound])
    : coordinator.acquireExclusive(ranges: [address..<upperBound])
  // The active record is coordinator-owned; native code carries only the stable token.
  let token = lease.token
  lease.coordinator = nil
  return token
}

@_cdecl("dory_x86_memory_access_end")
public func doryX86MemoryAccessEnd(
  _ opaque: UnsafeMutableRawPointer?,
  _ token: UInt64
) {
  guard let opaque, token != 0 else { return }
  Unmanaged<DoryX86MemoryAccessCoordinator>.fromOpaque(opaque).takeUnretainedValue()
    .release(token: token)
}
