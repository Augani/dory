import Foundation

/// Large-address-space backing store using mmap. Virtual pages are lazily backed
/// by the host's VM system, so allocating 16 GB of guest RAM does not consume
/// 16 GB of host physical memory — only pages that are actually touched cost RAM.
public final class DoryX86MmapMemory: DoryX86PhysicalRAM, @unchecked Sendable {
  public let baseAddress: UInt64
  public let byteCount: Int
  private let lock = NSLock()
  private let pointer: UnsafeMutableRawPointer
  // Reserve generation metadata only for pages actually written, independently of virtual size.
  private var codePageGenerations: [Int: UInt64] = [:]

  var trackedCodePageCount: Int { lock.withLock { codePageGenerations.count } }

  /// Compatibility convenience for existing fixed-size fixtures. Caller-controlled allocations
  /// must use the throwing initializer so invalid configuration and mmap failures are recoverable.
  public convenience init(baseAddress: UInt64 = 0, byteCount: Int) {
    do {
      try self.init(baseAddress: baseAddress, validatingByteCount: byteCount)
    } catch {
      preconditionFailure("Unable to allocate x86 RAM: \(error)")
    }
  }

  public init(baseAddress: UInt64 = 0, validatingByteCount byteCount: Int) throws {
    try validateDoryX86RAMAllocation(baseAddress: baseAddress, byteCount: byteCount)
    let mapped = mmap(
      nil, byteCount,
      PROT_READ | PROT_WRITE,
      MAP_ANONYMOUS | MAP_PRIVATE,
      -1, 0
    )
    guard mapped != MAP_FAILED, let mapped else {
      throw DoryX86MemoryAllocationError.mappingFailed(byteCount: byteCount, errorNumber: errno)
    }
    self.baseAddress = baseAddress
    self.byteCount = byteCount
    pointer = mapped
  }

  deinit {
    munmap(pointer, byteCount)
  }

  private func checkedOffset(
    address: UInt64, byteCount: Int, access: DoryX86MemoryAccessKind
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
    guard offset <= self.byteCount, byteCount <= self.byteCount - offset else {
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

  public func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    guard maximumCount >= 0 else {
      throw DoryX86MemoryError.addressOverflow(address: address, byteCount: maximumCount)
    }
    guard maximumCount > 0 else { return [] }
    lock.lock()
    defer { lock.unlock() }
    let offset = try checkedOffset(address: address, byteCount: 1, access: .instructionFetch)
    let available = min(maximumCount, byteCount - offset)
    return Array(
      UnsafeBufferPointer(
        start: pointer.advanced(by: offset).assumingMemoryBound(to: UInt8.self),
        count: available))
  }

  public func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    guard byteCount >= 0 else {
      throw DoryX86MemoryError.addressOverflow(address: address, byteCount: byteCount)
    }
    guard byteCount > 0 else { return [] }
    lock.lock()
    defer { lock.unlock() }
    let offset = try checkedOffset(address: address, byteCount: byteCount, access: .read)
    return Array(
      UnsafeBufferPointer(
        start: pointer.advanced(by: offset).assumingMemoryBound(to: UInt8.self),
        count: byteCount))
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
      value |=
        UInt64(pointer.advanced(by: offset + index).assumingMemoryBound(to: UInt8.self).pointee)
        << UInt64(index * 8)
    }
    return value
  }

  public func readRestartableScalar(at address: UInt64, byteCount: Int) throws -> UInt64? {
    try readScalar(at: address, byteCount: byteCount)
  }

  public func write(at address: UInt64, bytes: [UInt8]) throws {
    guard !bytes.isEmpty else { return }
    lock.lock()
    defer { lock.unlock() }
    let offset = try checkedOffset(address: address, byteCount: bytes.count, access: .write)
    bytes.withUnsafeBufferPointer { buffer in
      pointer.advanced(by: offset).copyMemory(from: buffer.baseAddress!, byteCount: bytes.count)
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
      pointer.advanced(by: offset + index).assumingMemoryBound(to: UInt8.self).pointee =
        UInt8(truncatingIfNeeded: value >> UInt64(index * 8))
    }
    markCodePagesWritten(offset: offset, byteCount: byteCount)
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

  // MARK: - DoryX86CodeGenerationMemory

  public func codeGeneration(at address: UInt64, byteCount: Int) throws -> UInt64? {
    guard byteCount >= 0 else {
      throw DoryX86MemoryError.addressOverflow(address: address, byteCount: byteCount)
    }
    guard byteCount > 0 else { return nil }
    return try lock.withLock {
      let offset = try checkedOffset(
        address: address, byteCount: byteCount, access: .instructionFetch)
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

  // MARK: - DoryX86BulkMemory

  public func bulkCopyRAMSpan(at address: UInt64, maximumByteCount: Int) -> Int? {
    guard maximumByteCount > 0 else { return maximumByteCount == 0 ? 0 : nil }
    return lock.withLock {
      guard address >= baseAddress else { return nil }
      let distance = address - baseAddress
      guard distance < UInt64(byteCount), distance <= UInt64(Int.max) else { return nil }
      return min(maximumByteCount, byteCount - Int(distance))
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
      guard sourceDistance < UInt64(byteCount), destinationDistance < UInt64(byteCount),
        sourceDistance <= UInt64(Int.max), destinationDistance <= UInt64(Int.max)
      else { return nil }
      let sourceOffset = Int(sourceDistance)
      let destinationOffset = Int(destinationDistance)
      let count = min(
        maximumByteCount, byteCount - sourceOffset, byteCount - destinationOffset)
      guard count > 0 else { return nil }
      guard sourceOffset + count <= destinationOffset || destinationOffset + count <= sourceOffset
      else { return nil }
      pointer.advanced(by: destinationOffset).copyMemory(
        from: pointer.advanced(by: sourceOffset), byteCount: count)
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
      guard sourceDistance < UInt64(byteCount), destinationDistance < UInt64(byteCount),
        sourceDistance <= UInt64(Int.max), destinationDistance <= UInt64(Int.max)
      else { return nil }
      let sourceOffset = Int(sourceDistance)
      let destinationOffset = Int(destinationDistance)
      let elementCount = min(
        maximumElementCount,
        (byteCount - sourceOffset) / elementByteCount,
        (byteCount - destinationOffset) / elementByteCount)
      guard elementCount > 0 else { return nil }
      let totalBytes = elementCount * elementByteCount
      guard
        sourceOffset + totalBytes <= destinationOffset
          || destinationOffset + totalBytes <= sourceOffset
      else { return nil }
      let destinationRange = destinationAddress..<(destinationAddress + UInt64(totalBytes))
      guard
        !excludingDestinationRanges.contains(where: { !$0.isEmpty && $0.overlaps(destinationRange) }
        )
      else {
        return nil
      }
      pointer.advanced(by: destinationOffset).copyMemory(
        from: pointer.advanced(by: sourceOffset), byteCount: totalBytes)
      markCodePagesWritten(offset: destinationOffset, byteCount: totalBytes)
      return elementCount
    }
  }

  public func fillRepeating(
    at destinationAddress: UInt64,
    pattern: [UInt8],
    maximumElementCount: Int
  ) throws -> Int? {
    guard !pattern.isEmpty, maximumElementCount > 0 else {
      return maximumElementCount == 0 ? 0 : nil
    }
    return lock.withLock {
      guard destinationAddress >= baseAddress else { return nil }
      let distance = destinationAddress - baseAddress
      guard distance < UInt64(byteCount), distance <= UInt64(Int.max) else { return nil }
      let offset = Int(distance)
      let elementCount = min(maximumElementCount, (byteCount - offset) / pattern.count)
      guard elementCount > 0 else { return nil }
      let totalBytes = elementCount * pattern.count
      pattern.withUnsafeBufferPointer { buffer in
        let dest = pointer.advanced(by: offset)
        for i in 0..<elementCount {
          dest.advanced(by: i * pattern.count).copyMemory(
            from: buffer.baseAddress!, byteCount: pattern.count)
        }
      }
      markCodePagesWritten(offset: offset, byteCount: totalBytes)
      return elementCount
    }
  }
}
