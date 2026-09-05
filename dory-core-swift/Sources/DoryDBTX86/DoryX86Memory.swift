import Foundation

public enum DoryX86MemoryAccessKind: String, Codable, Sendable, Hashable {
  case instructionFetch
  case read
  case write

  public func hash(into hasher: inout Hasher) {
    let discriminator: UInt8 =
      switch self {
      case .instructionFetch: 0
      case .read: 1
      case .write: 2
      }
    hasher.combine(discriminator)
  }
}

public enum DoryX86MemoryError: Error, Codable, Sendable, Hashable, CustomStringConvertible {
  case unmapped(address: UInt64, byteCount: Int, access: DoryX86MemoryAccessKind)
  case addressOverflow(address: UInt64, byteCount: Int)
  case pageFault(address: UInt64, errorCode: UInt32)

  public var description: String {
    switch self {
    case .unmapped(let address, let byteCount, let access):
      "x86 \(access.rawValue) touches unmapped memory at 0x\(String(address, radix: 16)) for \(byteCount) bytes"
    case .addressOverflow(let address, let byteCount):
      "x86 memory access overflows at 0x\(String(address, radix: 16)) for \(byteCount) bytes"
    case .pageFault(let address, let errorCode):
      "x86 page fault at 0x\(String(address, radix: 16)) with error code 0x\(String(errorCode, radix: 16))"
    }
  }
}

/// Invalid configuration and recoverable host mapping failures are distinct from guest faults.
public enum DoryX86MemoryAllocationError: Error, Sendable, Equatable {
  case invalidByteCount(Int)
  case addressOverflow(baseAddress: UInt64, byteCount: Int)
  case mappingFailed(byteCount: Int, errorNumber: Int32)
  case heapAllocationFailed(byteCount: Int, errorNumber: Int32)
}

/// Internal ownership seam: tests can fail allocation and observe release without exhausting the
/// process. The allocator and its matching deallocator stay attached to one backing instance.
struct DoryX86HeapAllocator: Sendable {
  let allocate: @Sendable (Int) -> (pointer: UnsafeMutableRawPointer?, errorNumber: Int32)
  let deallocate: @Sendable (UnsafeMutableRawPointer, Int) -> Void

  static let system = Self(
    allocate: { byteCount in
      let pointer = calloc(byteCount, 1)
      return (pointer, pointer == nil ? errno : 0)
    },
    deallocate: { pointer, _ in free(pointer) }
  )
}

func validateDoryX86RAMAllocation(baseAddress: UInt64, byteCount: Int) throws {
  guard byteCount > 0 else {
    throw DoryX86MemoryAllocationError.invalidByteCount(byteCount)
  }
  guard !baseAddress.addingReportingOverflow(UInt64(byteCount)).overflow else {
    throw DoryX86MemoryAllocationError.addressOverflow(
      baseAddress: baseAddress, byteCount: byteCount)
  }
}

public protocol DoryX86Memory: AnyObject, Sendable {
  /// Returns up to `maximumCount` bytes without faulting merely because a shorter instruction ends
  /// at the mapping boundary. The decoder decides whether the returned instruction is truncated.
  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8]
  func read(at address: UInt64, byteCount: Int) throws -> [UInt8]
  /// Checks read permissions without requiring ordinary RAM to allocate or copy the range.
  func validateRead(at address: UInt64, byteCount: Int) throws
  func write(at address: UInt64, bytes: [UInt8]) throws
  /// Proves that a complete write can commit before an instruction exposes any memory changes.
  func validateWrite(at address: UInt64, byteCount: Int) throws
  /// Joins prior and subsequent accesses at the memory implementation's ordering boundary.
  func synchronize()
}

public enum DoryX86ScalarMemoryError: Error, Sendable, Equatable {
  case invalidByteCount(Int)
}

/// Optional allocation-free path for the scalar loads and stores emitted by the ARM64 JIT.
/// Implementations must validate a complete store before committing any byte.
public protocol DoryX86ScalarMemory: DoryX86Memory {
  func readScalar(at address: UInt64, byteCount: Int) throws -> UInt64
  func writeScalar(at address: UInt64, value: UInt64, byteCount: Int) throws
}

/// Optional proof that a scalar read has no externally visible side effects and may therefore be
/// replayed if a later callback in the same translated block fails. Returning `nil` declines the
/// native block before touching MMIO or another non-restartable mapping.
public protocol DoryX86RestartableScalarMemory: DoryX86Memory {
  func readRestartableScalar(at address: UInt64, byteCount: Int) throws -> UInt64?
}

/// Optional path for x86 locked scalar read-modify-write operations. The caller must hold
/// DoryX86AtomicGate.shared so interpreter and native locked instructions share one
/// architectural serialization point before entering memory-owned locks. Implementations must
/// validate the complete write cycle before reading, serialize the compare and destination
/// write under one memory-owned critical section, and return the observed destination value.
/// Returning nil declines native execution before touching MMIO or unsupported memory.
public protocol DoryX86AtomicScalarMemory: DoryX86Memory {
  func compareExchangeScalar(
    at address: UInt64,
    expected: UInt64,
    desired: UInt64,
    byteCount: Int
  ) throws -> UInt64?
}

/// Optional change token for translated code resident in ordinary RAM. A token is valid only for
/// the exact address range supplied by the caller. Returning `nil` keeps the conservative byte
/// comparison path for MMIO, firmware flash, or memory implementations without write tracking.
public protocol DoryX86CodeGenerationMemory: DoryX86Memory {
  func codeGeneration(at address: UInt64, byteCount: Int) throws -> UInt64?
}

/// Optional exact fast path for forward, non-overlapping string copies. Implementations return
/// `nil` before mutation when either starting address is not proven ordinary RAM or when the
/// resolved backing ranges overlap. A positive result is a fully committed prefix, allowing the
/// interpreter to expose precise REP progress before retrying the next page or mapping boundary
/// through the architectural scalar path.
public protocol DoryX86BulkMemory: DoryX86Memory {
  /// Returns a positive prefix that is proven ordinary RAM without performing I/O or mutation.
  func bulkCopyRAMSpan(at address: UInt64, maximumByteCount: Int) -> Int?

  func copyForwardNonoverlapping(
    from sourceAddress: UInt64,
    to destinationAddress: UInt64,
    maximumByteCount: Int
  ) throws -> Int?

  /// Copies a positive prefix measured only in complete elements. Every exclusion range is in
  /// this memory object's address space. Implementations must return `nil` before mutation unless
  /// the source and destination are ordinary, non-overlapping RAM and the complete destination
  /// prefix is disjoint from every exclusion range.
  func copyForwardNonoverlappingElements(
    from sourceAddress: UInt64,
    to destinationAddress: UInt64,
    elementByteCount: Int,
    maximumElementCount: Int,
    excludingDestinationRanges: [Range<UInt64>]
  ) throws -> Int?

  /// Repeats one scalar-width pattern into ordinary RAM. The returned count is measured in
  /// complete pattern elements so a REP STOS caller can publish exact architectural progress.
  /// Returning `nil` declines the fast path before mutation.
  func fillRepeating(
    at destinationAddress: UInt64,
    pattern: [UInt8],
    maximumElementCount: Int
  ) throws -> Int?
}

/// Protocol uniting all memory protocols required by the physical RAM backing store.
/// Both `DoryX86ByteArrayMemory` and `DoryX86MmapMemory` conform.
public protocol DoryX86PhysicalRAM:
  DoryX86Memory, DoryX86ScalarMemory, DoryX86RestartableScalarMemory,
  DoryX86CodeGenerationMemory, DoryX86BulkMemory
{
  var baseAddress: UInt64 { get }
  var byteCount: Int { get }
}

extension DoryX86Memory {
  public func validateRead(at address: UInt64, byteCount: Int) throws {
    _ = try read(at: address, byteCount: byteCount)
  }

  public func validateWrite(at address: UInt64, byteCount: Int) throws {
    _ = try read(at: address, byteCount: byteCount)
  }

  public func synchronize() {}
}

extension DoryX86BulkMemory {
  public func copyForwardNonoverlappingElements(
    from sourceAddress: UInt64,
    to destinationAddress: UInt64,
    elementByteCount: Int,
    maximumElementCount: Int,
    excludingDestinationRanges: [Range<UInt64>]
  ) throws -> Int? {
    nil
  }

  public func fillRepeating(
    at destinationAddress: UInt64,
    pattern: [UInt8],
    maximumElementCount: Int
  ) throws -> Int? {
    nil
  }
}

extension DoryX86ScalarMemory {
  public func readScalar(at address: UInt64, byteCount: Int) throws -> UInt64 {
    guard [1, 2, 4, 8].contains(byteCount) else {
      throw DoryX86ScalarMemoryError.invalidByteCount(byteCount)
    }
    return try read(at: address, byteCount: byteCount).enumerated().reduce(0) {
      $0 | UInt64($1.element) << UInt64($1.offset * 8)
    }
  }

  public func writeScalar(at address: UInt64, value: UInt64, byteCount: Int) throws {
    guard [1, 2, 4, 8].contains(byteCount) else {
      throw DoryX86ScalarMemoryError.invalidByteCount(byteCount)
    }
    let bytes = (0..<byteCount).map {
      UInt8(truncatingIfNeeded: value >> UInt64($0 * 8))
    }
    try validateWrite(at: address, byteCount: byteCount)
    try write(at: address, bytes: bytes)
  }
}

/// Deterministic heap byte array for interpreter conformance, firmware bring-up, and replay.
/// Its checked calloc/free ownership is independent of mmap RAM. Array-returning read/snapshot
/// APIs still allocate diagnostic copies through Swift; those copies do not promise recoverable
/// allocation exhaustion. Product paging composes a translator over this exact bounds behavior.
public final class DoryX86ByteArrayMemory: DoryX86PhysicalRAM, DoryX86AtomicScalarMemory, @unchecked Sendable {
  public let baseAddress: UInt64
  public let byteCount: Int
  private let lock = NSLock()
  private let storage: UnsafeMutableBufferPointer<UInt8>
  private let allocator: DoryX86HeapAllocator
  // Reserve generation metadata only for pages actually written, independently of virtual size.
  private var codePageGenerations: [Int: UInt64] = [:]

  var trackedCodePageCount: Int { lock.withLock { codePageGenerations.count } }

  public convenience init(baseAddress: UInt64 = 0, bytes: [UInt8]) throws {
    try self.init(baseAddress: baseAddress, bytes: bytes, allocator: .system)
  }

  convenience init(baseAddress: UInt64 = 0, bytes: [UInt8], allocator: DoryX86HeapAllocator) throws {
    try self.init(baseAddress: baseAddress, byteCount: bytes.count, allocator: allocator)
    bytes.withUnsafeBufferPointer { source in
      storage.baseAddress!.update(from: source.baseAddress!, count: source.count)
    }
  }

  public convenience init(baseAddress: UInt64 = 0, byteCount: Int) throws {
    try self.init(baseAddress: baseAddress, byteCount: byteCount, allocator: .system)
  }

  /// Source-compatible label for callers already using validated construction.
  public convenience init(baseAddress: UInt64 = 0, validatingByteCount byteCount: Int) throws {
    try self.init(baseAddress: baseAddress, byteCount: byteCount)
  }

  init(baseAddress: UInt64 = 0, byteCount: Int, allocator: DoryX86HeapAllocator) throws {
    try validateDoryX86RAMAllocation(baseAddress: baseAddress, byteCount: byteCount)
    let allocation = allocator.allocate(byteCount)
    guard let pointer = allocation.pointer else {
      throw DoryX86MemoryAllocationError.heapAllocationFailed(
        byteCount: byteCount, errorNumber: allocation.errorNumber)
    }
    self.baseAddress = baseAddress
    self.byteCount = byteCount
    self.allocator = allocator
    storage = .init(start: pointer.bindMemory(to: UInt8.self, capacity: byteCount), count: byteCount)
  }

  deinit {
    allocator.deallocate(UnsafeMutableRawPointer(storage.baseAddress!), byteCount)
  }

  public func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    guard maximumCount >= 0 else {
      throw DoryX86MemoryError.addressOverflow(address: address, byteCount: maximumCount)
    }
    guard maximumCount > 0 else { return [] }
    lock.lock()
    defer { lock.unlock() }
    let offset = try checkedOffset(address: address, byteCount: 1, access: .instructionFetch)
    let available = min(
      maximumCount, storage.count - offset, Int(clamping: UInt64.max - address))
    return Array(storage[offset..<(offset + available)])
  }

  public func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    guard byteCount >= 0 else {
      throw DoryX86MemoryError.addressOverflow(address: address, byteCount: byteCount)
    }
    guard byteCount > 0 else { return [] }
    lock.lock()
    defer { lock.unlock() }
    let offset = try checkedOffset(address: address, byteCount: byteCount, access: .read)
    return Array(storage[offset..<(offset + byteCount)])
  }

  public func readScalar(at address: UInt64, byteCount: Int) throws -> UInt64 {
    guard [1, 2, 4, 8].contains(byteCount) else {
      throw DoryX86ScalarMemoryError.invalidByteCount(byteCount)
    }
    lock.lock()
    defer { lock.unlock() }
    let offset = try checkedOffset(address: address, byteCount: byteCount, access: .read)
    var value: UInt64 = 0
    for index in 0..<byteCount {
      value |= UInt64(storage[offset + index]) << UInt64(index * 8)
    }
    return value
  }

  public func validateRead(at address: UInt64, byteCount: Int) throws {
    guard byteCount >= 0 else {
      throw DoryX86MemoryError.addressOverflow(address: address, byteCount: byteCount)
    }
    guard byteCount > 0 else { return }
    try lock.withLock {
      _ = try checkedOffset(address: address, byteCount: byteCount, access: .read)
    }
  }

  public func write(at address: UInt64, bytes: [UInt8]) throws {
    guard !bytes.isEmpty else { return }
    lock.lock()
    defer { lock.unlock() }
    let offset = try checkedOffset(address: address, byteCount: bytes.count, access: .write)
    bytes.withUnsafeBufferPointer { source in
      storage.baseAddress!.advanced(by: offset).update(from: source.baseAddress!, count: source.count)
    }
    markCodePagesWritten(offset: offset, byteCount: bytes.count)
  }

  public func writeScalar(at address: UInt64, value: UInt64, byteCount: Int) throws {
    guard [1, 2, 4, 8].contains(byteCount) else {
      throw DoryX86ScalarMemoryError.invalidByteCount(byteCount)
    }
    lock.lock()
    defer { lock.unlock() }
    let offset = try checkedOffset(address: address, byteCount: byteCount, access: .write)
    for index in 0..<byteCount {
      storage[offset + index] = UInt8(truncatingIfNeeded: value >> UInt64(index * 8))
    }
    markCodePagesWritten(offset: offset, byteCount: byteCount)
  }

  public func compareExchangeScalar(
    at address: UInt64,
    expected: UInt64,
    desired: UInt64,
    byteCount: Int
  ) throws -> UInt64? {
    guard [1, 2, 4, 8].contains(byteCount) else {
      throw DoryX86ScalarMemoryError.invalidByteCount(byteCount)
    }
    lock.lock()
    defer { lock.unlock() }
    let offset = try checkedOffset(address: address, byteCount: byteCount, access: .write)
    var observed: UInt64 = 0
    for index in 0..<byteCount {
      observed |= UInt64(storage[offset + index]) << UInt64(index * 8)
    }
    let mask = byteCount == 8 ? UInt64.max : (UInt64(1) << UInt64(byteCount * 8)) - 1
    let stored = (observed & mask) == (expected & mask) ? desired : observed
    for index in 0..<byteCount {
      storage[offset + index] = UInt8(truncatingIfNeeded: stored >> UInt64(index * 8))
    }
    markCodePagesWritten(offset: offset, byteCount: byteCount)
    return observed & mask
  }

  public func validateWrite(at address: UInt64, byteCount: Int) throws {
    guard byteCount >= 0 else {
      throw DoryX86MemoryError.addressOverflow(address: address, byteCount: byteCount)
    }
    guard byteCount > 0 else { return }
    lock.lock()
    defer { lock.unlock() }
    _ = try checkedOffset(address: address, byteCount: byteCount, access: .write)
  }

  public func synchronize() {
    lock.lock()
    lock.unlock()
  }

  public func snapshot() -> [UInt8] {
    lock.lock()
    defer { lock.unlock() }
    return Array(storage)
  }

  private func checkedOffset(
    address: UInt64,
    byteCount: Int,
    access: DoryX86MemoryAccessKind
  ) throws -> Int {
    guard byteCount >= 0,
      !address.addingReportingOverflow(UInt64(byteCount)).overflow
    else {
      throw DoryX86MemoryError.addressOverflow(address: address, byteCount: byteCount)
    }
    guard address >= baseAddress else {
      throw DoryX86MemoryError.unmapped(address: address, byteCount: byteCount, access: access)
    }
    let distance = address - baseAddress
    guard distance <= UInt64(Int.max) else {
      throw DoryX86MemoryError.unmapped(address: address, byteCount: byteCount, access: access)
    }
    let offset = Int(distance)
    guard offset <= storage.count, byteCount <= storage.count - offset else {
      throw DoryX86MemoryError.unmapped(address: address, byteCount: byteCount, access: access)
    }
    return offset
  }

  private func markCodePagesWritten(offset: Int, byteCount: Int) {
    guard byteCount > 0 else { return }
    let first = offset / 4_096
    let last = (offset + byteCount - 1) / 4_096
    for page in first...last { codePageGenerations[page, default: 0] &+= 1 }
  }
}

extension DoryX86ByteArrayMemory: DoryX86CodeGenerationMemory {
  public func codeGeneration(at address: UInt64, byteCount: Int) throws -> UInt64? {
    guard byteCount >= 0 else {
      throw DoryX86MemoryError.addressOverflow(address: address, byteCount: byteCount)
    }
    guard byteCount > 0 else { return nil }
    return try lock.withLock {
      let offset = try checkedOffset(
        address: address,
        byteCount: byteCount,
        access: .instructionFetch
      )
      let first = offset / 4_096
      let last = (offset + byteCount - 1) / 4_096
      var token: UInt64 = 0xcbf2_9ce4_8422_2325
      for page in first...last {
        token ^= UInt64(page)
        token &*= 0x0000_0100_0000_01b3
        token ^= codePageGenerations[page, default: 0]
        token &*= 0x0000_0100_0000_01b3
      }
      token ^= UInt64(offset & 0xfff)
      token &*= 0x0000_0100_0000_01b3
      token ^= UInt64(byteCount)
      return token
    }
  }
}

extension DoryX86ByteArrayMemory: DoryX86RestartableScalarMemory {
  public func readRestartableScalar(at address: UInt64, byteCount: Int) throws -> UInt64? {
    try readScalar(at: address, byteCount: byteCount)
  }
}

extension DoryX86ByteArrayMemory: DoryX86BulkMemory {
  public func bulkCopyRAMSpan(at address: UInt64, maximumByteCount: Int) -> Int? {
    guard maximumByteCount > 0 else { return maximumByteCount == 0 ? 0 : nil }
    return lock.withLock {
      guard address >= baseAddress else { return nil }
      let distance = address - baseAddress
      guard distance < UInt64(storage.count), distance <= UInt64(Int.max) else { return nil }
      return min(
        maximumByteCount, storage.count - Int(distance), Int(clamping: UInt64.max - address))
    }
  }

  public func copyForwardNonoverlapping(
    from sourceAddress: UInt64,
    to destinationAddress: UInt64,
    maximumByteCount: Int
  ) throws -> Int? {
    guard maximumByteCount > 0 else { return maximumByteCount == 0 ? 0 : nil }
    return lock.withLock {
      guard sourceAddress >= baseAddress, destinationAddress >= baseAddress else { return nil }
      let sourceDistance = sourceAddress - baseAddress
      let destinationDistance = destinationAddress - baseAddress
      guard sourceDistance < UInt64(storage.count), destinationDistance < UInt64(storage.count),
        sourceDistance <= UInt64(Int.max), destinationDistance <= UInt64(Int.max)
      else { return nil }
      let sourceOffset = Int(sourceDistance)
      let destinationOffset = Int(destinationDistance)
      let count = min(
        maximumByteCount,
        storage.count - sourceOffset,
        storage.count - destinationOffset
      )
      guard count > 0,
        !sourceAddress.addingReportingOverflow(UInt64(count)).overflow,
        !destinationAddress.addingReportingOverflow(UInt64(count)).overflow
      else { return nil }
      guard sourceOffset + count <= destinationOffset || destinationOffset + count <= sourceOffset
      else { return nil }
      storage.baseAddress!.advanced(by: destinationOffset).update(
        from: storage.baseAddress!.advanced(by: sourceOffset), count: count)
      markCodePagesWritten(offset: destinationOffset, byteCount: count)
      return count
    }
  }

  public func copyForwardNonoverlappingElements(
    from sourceAddress: UInt64,
    to destinationAddress: UInt64,
    elementByteCount: Int,
    maximumElementCount: Int,
    excludingDestinationRanges: [Range<UInt64>]
  ) throws -> Int? {
    guard elementByteCount > 0, maximumElementCount > 0,
      maximumElementCount <= Int.max / elementByteCount
    else { return maximumElementCount == 0 ? 0 : nil }
    return lock.withLock {
      guard sourceAddress >= baseAddress, destinationAddress >= baseAddress else { return nil }
      let sourceDistance = sourceAddress - baseAddress
      let destinationDistance = destinationAddress - baseAddress
      guard sourceDistance < UInt64(storage.count), destinationDistance < UInt64(storage.count),
        sourceDistance <= UInt64(Int.max), destinationDistance <= UInt64(Int.max)
      else { return nil }
      let sourceOffset = Int(sourceDistance)
      let destinationOffset = Int(destinationDistance)
      let elementCount = min(
        maximumElementCount,
        (storage.count - sourceOffset) / elementByteCount,
        (storage.count - destinationOffset) / elementByteCount
      )
      guard elementCount > 0 else { return nil }
      let byteCount = elementCount * elementByteCount
      guard !sourceAddress.addingReportingOverflow(UInt64(byteCount)).overflow else { return nil }
      guard
        sourceOffset + byteCount <= destinationOffset
          || destinationOffset + byteCount <= sourceOffset
      else { return nil }
      let (destinationEnd, destinationOverflow) = destinationAddress.addingReportingOverflow(
        UInt64(byteCount))
      guard !destinationOverflow else { return nil }
      let destinationRange = destinationAddress..<destinationEnd
      guard
        !excludingDestinationRanges.contains(where: { !$0.isEmpty && $0.overlaps(destinationRange) }
        )
      else {
        return nil
      }
      storage.baseAddress!.advanced(by: destinationOffset).update(
        from: storage.baseAddress!.advanced(by: sourceOffset), count: byteCount)
      markCodePagesWritten(offset: destinationOffset, byteCount: byteCount)
      return elementCount
    }
  }

  public func fillRepeating(
    at destinationAddress: UInt64,
    pattern: [UInt8],
    maximumElementCount: Int
  ) throws -> Int? {
    guard maximumElementCount > 0, !pattern.isEmpty else {
      return maximumElementCount == 0 ? 0 : nil
    }
    return lock.withLock {
      guard destinationAddress >= baseAddress else { return nil }
      let distance = destinationAddress - baseAddress
      guard distance < UInt64(storage.count), distance <= UInt64(Int.max) else { return nil }
      let destinationOffset = Int(distance)
      let elementCount = min(
        maximumElementCount,
        (storage.count - destinationOffset) / pattern.count
      )
      guard elementCount > 0 else { return nil }
      let byteCount = elementCount * pattern.count
      guard !destinationAddress.addingReportingOverflow(UInt64(byteCount)).overflow else {
        return nil
      }
      pattern.withUnsafeBufferPointer { source in
        var offset = 0
        while offset < byteCount {
          storage.baseAddress!.advanced(by: destinationOffset + offset).update(
            from: source.baseAddress!, count: pattern.count)
          offset += pattern.count
        }
      }
      markCodePagesWritten(offset: destinationOffset, byteCount: byteCount)
      return elementCount
    }
  }
}
