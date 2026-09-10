import Foundation

/// Places one contiguous portion of the RAM object's compact logical storage at an offset in a
/// larger host reservation. Logical ranges must cover the RAM object exactly; host ranges may
/// leave gaps that remain inaccessible.
public struct DoryX86MmapRAMMapping: Sendable, Equatable {
  public let logicalOffset: Int
  public let hostOffset: Int
  public let byteCount: Int

  public init(logicalOffset: Int, hostOffset: Int, byteCount: Int) {
    self.logicalOffset = logicalOffset
    self.hostOffset = hostOffset
    self.byteCount = byteCount
  }
}

/// Installs immutable bytes inside a sparse host reservation without adding the range to the
/// compact interpreter-facing RAM object. Unoccupied bytes receive `fillByte` before the complete
/// range is protected read-only.
public struct DoryX86MmapReadOnlyMapping: Sendable, Equatable {
  public let hostOffset: Int
  public let byteCount: Int
  public let contents: Data
  public let contentsOffset: Int
  public let fillByte: UInt8

  public init(
    hostOffset: Int,
    byteCount: Int,
    contents: Data,
    contentsOffset: Int = 0,
    fillByte: UInt8 = 0
  ) {
    self.hostOffset = hostOffset
    self.byteCount = byteCount
    self.contents = contents
    self.contentsOffset = contentsOffset
    self.fillByte = fillByte
  }
}

/// Large-address-space backing store using mmap. Virtual pages are lazily backed
/// by the host's VM system, so allocating 16 GB of guest RAM does not consume
/// 16 GB of host physical memory — only pages that are actually touched cost RAM.
public final class DoryX86MmapMemory: DoryX86PhysicalRAM, DoryX86AtomicScalarMemory,
  DoryX86DirectHostAddressSpaceMemory, DoryX86PageTableWriteTrackingMemory,
  DoryX86TranslatedCodeProtectionMemory, @unchecked Sendable
{
  public let baseAddress: UInt64
  public let byteCount: Int
  public let hostAddressSpaceByteCount: Int
  private let lock = NSLock()
  private let pointer: UnsafeMutableRawPointer
  private let ramMappings: [DoryX86MmapRAMMapping]
  // Reserve generation metadata only for pages actually written, independently of virtual size.
  private var codePageGenerations: [Int: UInt64] = [:]
  private var trackedPageTablePages: Set<Int> = []
  private var pageTableWalkerWriteDepth = 0
  private var pendingPageTableWrite = false
  private var protectedCodePagesByHostPage: [Int: Set<Int>] = [:]
  private var codeProtectionGeneration: UInt64 = 0

  var trackedCodePageCount: Int { lock.withLock { codePageGenerations.count } }

  public var protectedTranslatedCodePageCount: Int {
    lock.withLock { protectedCodePagesByHostPage.values.reduce(0) { $0 + $1.count } }
  }

  public var translatedCodeProtectionGeneration: UInt64 {
    lock.withLock { codeProtectionGeneration }
  }

  public var hostAddressSpaceBase: UInt64 {
    UInt64(UInt(bitPattern: pointer))
  }

  /// Both public allocation spellings preserve configuration and host mapping errors.
  public convenience init(baseAddress: UInt64 = 0, byteCount: Int) throws {
    try self.init(baseAddress: baseAddress, validatingByteCount: byteCount)
  }

  public convenience init(baseAddress: UInt64 = 0, validatingByteCount byteCount: Int) throws {
    try validateDoryX86RAMAllocation(baseAddress: baseAddress, byteCount: byteCount)
    try self.init(
      validatedBaseAddress: baseAddress,
      byteCount: byteCount,
      hostAddressSpaceByteCount: byteCount,
      ramMappings: [.init(logicalOffset: 0, hostOffset: 0, byteCount: byteCount)],
      readOnlyMappings: [],
      reserveThenCommit: false
    )
  }

  /// Reserves a guest-physical-shaped host address space and commits only the declared RAM ranges.
  /// Mapping offsets and the reservation size must be host-page aligned. The compact logical ranges
  /// remain the public `DoryX86PhysicalRAM` address space used by interpreter and device helpers.
  public convenience init(
    baseAddress: UInt64 = 0,
    validatingByteCount byteCount: Int,
    hostAddressSpaceByteCount: Int,
    ramMappings: [DoryX86MmapRAMMapping],
    readOnlyMappings: [DoryX86MmapReadOnlyMapping] = []
  ) throws {
    try validateDoryX86RAMAllocation(baseAddress: baseAddress, byteCount: byteCount)
    let pageByteCount = Int(getpagesize())
    guard hostAddressSpaceByteCount > 0,
      hostAddressSpaceByteCount.isMultiple(of: pageByteCount)
    else {
      throw DoryX86MemoryAllocationError.invalidHostAddressSpace(
        byteCount: hostAddressSpaceByteCount)
    }
    let sorted = ramMappings.sorted { lhs, rhs in
      lhs.logicalOffset == rhs.logicalOffset
        ? lhs.hostOffset < rhs.hostOffset
        : lhs.logicalOffset < rhs.logicalOffset
    }
    var expectedLogicalOffset = 0
    var committedHostRanges: [Range<Int>] = []
    for mapping in sorted {
      let logicalEnd = mapping.logicalOffset.addingReportingOverflow(mapping.byteCount)
      let hostEnd = mapping.hostOffset.addingReportingOverflow(mapping.byteCount)
      let hostPageEnd = hostEnd.partialValue.addingReportingOverflow(pageByteCount - 1)
      guard mapping.logicalOffset == expectedLogicalOffset,
        mapping.hostOffset >= 0,
        mapping.byteCount > 0,
        mapping.logicalOffset.isMultiple(of: pageByteCount),
        mapping.hostOffset.isMultiple(of: pageByteCount),
        !logicalEnd.overflow,
        !hostEnd.overflow,
        !hostPageEnd.overflow,
        hostEnd.partialValue <= hostAddressSpaceByteCount
      else {
        throw DoryX86MemoryAllocationError.invalidHostAddressSpaceMapping(
          logicalOffset: mapping.logicalOffset,
          hostOffset: mapping.hostOffset,
          byteCount: mapping.byteCount
        )
      }
      let committedHostEnd = hostPageEnd.partialValue / pageByteCount * pageByteCount
      let committedRange = mapping.hostOffset..<committedHostEnd
      guard !committedHostRanges.contains(where: { $0.overlaps(committedRange) }) else {
        throw DoryX86MemoryAllocationError.invalidHostAddressSpaceMapping(
          logicalOffset: mapping.logicalOffset,
          hostOffset: mapping.hostOffset,
          byteCount: mapping.byteCount
        )
      }
      committedHostRanges.append(committedRange)
      expectedLogicalOffset = logicalEnd.partialValue
    }
    guard expectedLogicalOffset == byteCount else {
      let mapping = sorted.last ?? .init(logicalOffset: 0, hostOffset: 0, byteCount: 0)
      throw DoryX86MemoryAllocationError.invalidHostAddressSpaceMapping(
        logicalOffset: mapping.logicalOffset,
        hostOffset: mapping.hostOffset,
        byteCount: mapping.byteCount
      )
    }
    var protectedHostRanges: [Range<Int>] = []
    for mapping in readOnlyMappings {
      let hostEnd = mapping.hostOffset.addingReportingOverflow(mapping.byteCount)
      guard mapping.hostOffset >= 0,
        mapping.byteCount > 0,
        mapping.contentsOffset >= 0,
        mapping.hostOffset.isMultiple(of: pageByteCount),
        mapping.byteCount.isMultiple(of: pageByteCount),
        !hostEnd.overflow,
        hostEnd.partialValue <= hostAddressSpaceByteCount,
        mapping.contentsOffset <= mapping.byteCount,
        mapping.contents.count <= mapping.byteCount - mapping.contentsOffset
      else {
        throw DoryX86MemoryAllocationError.invalidHostReadOnlyMapping(
          hostOffset: mapping.hostOffset,
          byteCount: mapping.byteCount,
          contentsOffset: mapping.contentsOffset,
          contentsByteCount: mapping.contents.count
        )
      }
      let protectedRange = mapping.hostOffset..<hostEnd.partialValue
      guard !committedHostRanges.contains(where: { $0.overlaps(protectedRange) }),
        !protectedHostRanges.contains(where: { $0.overlaps(protectedRange) })
      else {
        throw DoryX86MemoryAllocationError.invalidHostReadOnlyMapping(
          hostOffset: mapping.hostOffset,
          byteCount: mapping.byteCount,
          contentsOffset: mapping.contentsOffset,
          contentsByteCount: mapping.contents.count
        )
      }
      protectedHostRanges.append(protectedRange)
    }
    try self.init(
      validatedBaseAddress: baseAddress,
      byteCount: byteCount,
      hostAddressSpaceByteCount: hostAddressSpaceByteCount,
      ramMappings: sorted,
      readOnlyMappings: readOnlyMappings,
      reserveThenCommit: true
    )
  }

  private init(
    validatedBaseAddress baseAddress: UInt64,
    byteCount: Int,
    hostAddressSpaceByteCount: Int,
    ramMappings: [DoryX86MmapRAMMapping],
    readOnlyMappings: [DoryX86MmapReadOnlyMapping],
    reserveThenCommit: Bool
  ) throws {
    let mapped = mmap(
      nil, hostAddressSpaceByteCount,
      reserveThenCommit ? PROT_NONE : PROT_READ | PROT_WRITE,
      MAP_ANONYMOUS | MAP_PRIVATE,
      -1, 0
    )
    guard mapped != MAP_FAILED, let mapped else {
      throw DoryX86MemoryAllocationError.mappingFailed(
        byteCount: hostAddressSpaceByteCount, errorNumber: errno)
    }
    if reserveThenCommit {
      for mapping in ramMappings {
        guard
          mprotect(
            mapped.advanced(by: mapping.hostOffset),
            mapping.byteCount,
            PROT_READ | PROT_WRITE
          ) == 0
        else {
          let errorNumber = errno
          munmap(mapped, hostAddressSpaceByteCount)
          throw DoryX86MemoryAllocationError.protectionFailed(
            offset: mapping.hostOffset,
            byteCount: mapping.byteCount,
            errorNumber: errorNumber
          )
        }
      }
      for mapping in readOnlyMappings {
        let region = mapped.advanced(by: mapping.hostOffset)
        guard mprotect(region, mapping.byteCount, PROT_READ | PROT_WRITE) == 0 else {
          let errorNumber = errno
          munmap(mapped, hostAddressSpaceByteCount)
          throw DoryX86MemoryAllocationError.protectionFailed(
            offset: mapping.hostOffset,
            byteCount: mapping.byteCount,
            errorNumber: errorNumber
          )
        }
        memset(region, Int32(mapping.fillByte), mapping.byteCount)
        mapping.contents.withUnsafeBytes { contents in
          guard let contentsBase = contents.baseAddress else { return }
          region.advanced(by: mapping.contentsOffset).copyMemory(
            from: contentsBase,
            byteCount: contents.count
          )
        }
        guard mprotect(region, mapping.byteCount, PROT_READ) == 0 else {
          let errorNumber = errno
          munmap(mapped, hostAddressSpaceByteCount)
          throw DoryX86MemoryAllocationError.protectionFailed(
            offset: mapping.hostOffset,
            byteCount: mapping.byteCount,
            errorNumber: errorNumber
          )
        }
      }
    }
    self.baseAddress = baseAddress
    self.byteCount = byteCount
    self.hostAddressSpaceByteCount = hostAddressSpaceByteCount
    self.ramMappings = ramMappings
    pointer = mapped
  }

  deinit {
    munmap(pointer, hostAddressSpaceByteCount)
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

  private func resolvedHostOffset(forLogicalOffset logicalOffset: Int) -> (
    offset: Int, availableByteCount: Int
  ) {
    if ramMappings.count == 1 {
      let mapping = ramMappings[0]
      return (
        mapping.hostOffset + logicalOffset - mapping.logicalOffset,
        mapping.logicalOffset + mapping.byteCount - logicalOffset
      )
    }
    let mapping = ramMappings.first {
      $0.logicalOffset <= logicalOffset && logicalOffset < $0.logicalOffset + $0.byteCount
    }!
    return (
      mapping.hostOffset + logicalOffset - mapping.logicalOffset,
      mapping.logicalOffset + mapping.byteCount - logicalOffset
    )
  }

  public func hostAddressSpaceOffset(
    at address: UInt64,
    byteCount: Int,
    access: DoryX86MemoryAccessKind
  ) -> UInt64? {
    guard byteCount > 0,
      let logicalOffset = try? checkedOffset(
        address: address,
        byteCount: byteCount,
        access: access
      )
    else { return nil }
    let resolved = resolvedHostOffset(forLogicalOffset: logicalOffset)
    guard byteCount <= resolved.availableByteCount else { return nil }
    return UInt64(resolved.offset)
  }

  private func copyBytes(fromLogicalOffset offset: Int, byteCount: Int, into output: inout [UInt8])
  {
    output.withUnsafeMutableBytes { destination in
      var logicalOffset = offset
      var destinationOffset = 0
      while destinationOffset < byteCount {
        let resolved = resolvedHostOffset(forLogicalOffset: logicalOffset)
        let count = min(resolved.availableByteCount, byteCount - destinationOffset)
        destination.baseAddress!.advanced(by: destinationOffset).copyMemory(
          from: pointer.advanced(by: resolved.offset), byteCount: count)
        logicalOffset += count
        destinationOffset += count
      }
    }
  }

  private func copyBytes(_ bytes: [UInt8], toLogicalOffset offset: Int) {
    bytes.withUnsafeBytes { source in
      var logicalOffset = offset
      var sourceOffset = 0
      while sourceOffset < bytes.count {
        let resolved = resolvedHostOffset(forLogicalOffset: logicalOffset)
        let count = min(resolved.availableByteCount, bytes.count - sourceOffset)
        pointer.advanced(by: resolved.offset).copyMemory(
          from: source.baseAddress!.advanced(by: sourceOffset), byteCount: count)
        logicalOffset += count
        sourceOffset += count
      }
    }
  }

  private func markCodePagesWritten(offset: Int, byteCount: Int) {
    guard byteCount > 0 else { return }
    let first = offset / 4_096
    let last = (offset + byteCount - 1) / 4_096
    for page in first...last {
      codePageGenerations[page, default: 0] &+= 1
      if pageTableWalkerWriteDepth == 0, trackedPageTablePages.contains(page) {
        pendingPageTableWrite = true
      }
    }
  }

  public func protectTranslatedCode(at address: UInt64, byteCount: Int) throws -> Bool {
    guard byteCount > 0 else { return false }
    return try lock.withLock {
      let offset = try checkedOffset(
        address: address,
        byteCount: byteCount,
        access: .instructionFetch
      )
      let firstPage = offset / 4_096
      let lastPage = (offset + byteCount - 1) / 4_096
      let hostPageByteCount = Int(getpagesize())
      var changed = false
      for logicalPage in firstPage...lastPage {
        let logicalOffset = logicalPage * 4_096
        let hostOffset = resolvedHostOffset(forLogicalOffset: logicalOffset).offset
        let hostPage = hostOffset / hostPageByteCount
        if protectedCodePagesByHostPage[hostPage] == nil {
          guard
            mprotect(
              pointer.advanced(by: hostPage * hostPageByteCount),
              hostPageByteCount,
              PROT_READ
            ) == 0
          else {
            throw DoryX86MemoryAllocationError.protectionFailed(
              offset: hostPage * hostPageByteCount,
              byteCount: hostPageByteCount,
              errorNumber: errno
            )
          }
          codeProtectionGeneration &+= 1
          changed = true
        }
        protectedCodePagesByHostPage[hostPage, default: []].insert(logicalPage)
      }
      return changed
    }
  }

  public func invalidateTranslatedCode(at address: UInt64, byteCount: Int) throws -> Bool {
    guard byteCount > 0 else { return false }
    return try lock.withLock {
      let offset = try checkedOffset(address: address, byteCount: byteCount, access: .write)
      return try prepareTranslatedCodePagesForWrite(offset: offset, byteCount: byteCount)
    }
  }

  @discardableResult
  private func prepareTranslatedCodePagesForWrite(offset: Int, byteCount: Int) throws -> Bool {
    guard byteCount > 0, !protectedCodePagesByHostPage.isEmpty else { return false }
    let hostPageByteCount = Int(getpagesize())
    let firstLogicalPage = offset / 4_096
    let lastLogicalPage = (offset + byteCount - 1) / 4_096
    var hostPages: Set<Int> = []
    var changed = false
    for logicalPage in firstLogicalPage...lastLogicalPage {
      let hostOffset = resolvedHostOffset(forLogicalOffset: logicalPage * 4_096).offset
      hostPages.insert(hostOffset / hostPageByteCount)
    }
    for hostPage in hostPages {
      guard let codePages = protectedCodePagesByHostPage[hostPage] else { continue }
      guard
        mprotect(
          pointer.advanced(by: hostPage * hostPageByteCount),
          hostPageByteCount,
          PROT_READ | PROT_WRITE
        ) == 0
      else {
        throw DoryX86MemoryAllocationError.protectionFailed(
          offset: hostPage * hostPageByteCount,
          byteCount: hostPageByteCount,
          errorNumber: errno
        )
      }
      protectedCodePagesByHostPage.removeValue(forKey: hostPage)
      for codePage in codePages { codePageGenerations[codePage, default: 0] &+= 1 }
      changed = true
    }
    if changed { codeProtectionGeneration &+= 1 }
    return changed
  }

  public func trackPageTablePage(containing address: UInt64) {
    lock.withLock {
      guard address >= baseAddress, address - baseAddress < UInt64(byteCount) else { return }
      trackedPageTablePages.insert(Int((address - baseAddress) / 4_096))
    }
  }

  public func isTrackedPageTablePage(containing address: UInt64) -> Bool {
    lock.withLock {
      guard address >= baseAddress, address - baseAddress < UInt64(byteCount) else { return false }
      return trackedPageTablePages.contains(Int((address - baseAddress) / 4_096))
    }
  }

  public func beginPageTableWalkerWrite() {
    lock.withLock { pageTableWalkerWriteDepth += 1 }
  }

  public func endPageTableWalkerWrite() {
    lock.withLock {
      precondition(pageTableWalkerWriteDepth > 0)
      pageTableWalkerWriteDepth -= 1
    }
  }

  public var hasPendingPageTableWrite: Bool {
    lock.withLock { pendingPageTableWrite }
  }

  public func consumePendingPageTableWrite() -> Bool {
    lock.withLock {
      let pending = pendingPageTableWrite
      pendingPageTableWrite = false
      return pending
    }
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
    var result = [UInt8](repeating: 0, count: available)
    copyBytes(fromLogicalOffset: offset, byteCount: available, into: &result)
    return result
  }

  public func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    guard byteCount >= 0 else {
      throw DoryX86MemoryError.addressOverflow(address: address, byteCount: byteCount)
    }
    guard byteCount > 0 else { return [] }
    lock.lock()
    defer { lock.unlock() }
    let offset = try checkedOffset(address: address, byteCount: byteCount, access: .read)
    var result = [UInt8](repeating: 0, count: byteCount)
    copyBytes(fromLogicalOffset: offset, byteCount: byteCount, into: &result)
    return result
  }

  public func readScalar(at address: UInt64, byteCount: Int) throws -> UInt64 {
    guard [1, 2, 4, 8].contains(byteCount) else {
      throw DoryX86ScalarMemoryError.invalidByteCount(byteCount)
    }
    lock.lock()
    defer { lock.unlock() }
    let offset = try checkedOffset(address: address, byteCount: byteCount, access: .read)
    let resolved = resolvedHostOffset(forLogicalOffset: offset)
    var value: UInt64 = 0
    if byteCount <= resolved.availableByteCount {
      for index in 0..<byteCount {
        value |=
          UInt64(
            pointer.advanced(by: resolved.offset + index).assumingMemoryBound(to: UInt8.self)
              .pointee
          ) << UInt64(index * 8)
      }
    } else {
      for index in 0..<byteCount {
        let hostOffset = resolvedHostOffset(forLogicalOffset: offset + index).offset
        value |=
          UInt64(pointer.advanced(by: hostOffset).assumingMemoryBound(to: UInt8.self).pointee)
          << UInt64(index * 8)
      }
    }
    return value
  }

  public func readRestartableScalar(at address: UInt64, byteCount: Int) throws -> UInt64? {
    try readScalar(at: address, byteCount: byteCount)
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
    try prepareTranslatedCodePagesForWrite(offset: offset, byteCount: bytes.count)
    copyBytes(bytes, toLogicalOffset: offset)
    markCodePagesWritten(offset: offset, byteCount: bytes.count)
  }

  public func writeScalar(at address: UInt64, value: UInt64, byteCount: Int) throws {
    guard [1, 2, 4, 8].contains(byteCount) else {
      throw DoryX86ScalarMemoryError.invalidByteCount(byteCount)
    }
    lock.lock()
    defer { lock.unlock() }
    let offset = try checkedOffset(address: address, byteCount: byteCount, access: .write)
    try prepareTranslatedCodePagesForWrite(offset: offset, byteCount: byteCount)
    let resolved = resolvedHostOffset(forLogicalOffset: offset)
    if byteCount <= resolved.availableByteCount {
      for index in 0..<byteCount {
        pointer.advanced(by: resolved.offset + index).assumingMemoryBound(to: UInt8.self).pointee =
          UInt8(truncatingIfNeeded: value >> UInt64(index * 8))
      }
    } else {
      for index in 0..<byteCount {
        let hostOffset = resolvedHostOffset(forLogicalOffset: offset + index).offset
        pointer.advanced(by: hostOffset).assumingMemoryBound(to: UInt8.self).pointee =
          UInt8(truncatingIfNeeded: value >> UInt64(index * 8))
      }
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
    try prepareTranslatedCodePagesForWrite(offset: offset, byteCount: byteCount)
    let resolved = resolvedHostOffset(forLogicalOffset: offset)
    var observed: UInt64 = 0
    if byteCount <= resolved.availableByteCount {
      for index in 0..<byteCount {
        observed |=
          UInt64(
            pointer.advanced(by: resolved.offset + index).assumingMemoryBound(to: UInt8.self)
              .pointee
          ) << UInt64(index * 8)
      }
    } else {
      for index in 0..<byteCount {
        let hostOffset = resolvedHostOffset(forLogicalOffset: offset + index).offset
        observed |=
          UInt64(pointer.advanced(by: hostOffset).assumingMemoryBound(to: UInt8.self).pointee)
          << UInt64(index * 8)
      }
    }
    let mask = byteCount == 8 ? UInt64.max : (UInt64(1) << UInt64(byteCount * 8)) - 1
    let stored = (observed & mask) == (expected & mask) ? desired : observed
    if byteCount <= resolved.availableByteCount {
      for index in 0..<byteCount {
        pointer.advanced(by: resolved.offset + index).assumingMemoryBound(to: UInt8.self).pointee =
          UInt8(truncatingIfNeeded: stored >> UInt64(index * 8))
      }
    } else {
      for index in 0..<byteCount {
        let hostOffset = resolvedHostOffset(forLogicalOffset: offset + index).offset
        pointer.advanced(by: hostOffset).assumingMemoryBound(to: UInt8.self).pointee =
          UInt8(truncatingIfNeeded: stored >> UInt64(index * 8))
      }
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
      let offset = Int(distance)
      return min(
        maximumByteCount,
        byteCount - offset,
        resolvedHostOffset(forLogicalOffset: offset).availableByteCount
      )
    }
  }

  public func copyForwardNonoverlapping(
    from sourceAddress: UInt64,
    to destinationAddress: UInt64,
    maximumByteCount: Int
  ) throws -> Int? {
    guard maximumByteCount > 0 else { return maximumByteCount == 0 ? 0 : nil }
    return try lock.withLock {
      guard sourceAddress >= baseAddress, destinationAddress >= baseAddress else { return nil }
      let sourceDistance = sourceAddress - baseAddress
      let destinationDistance = destinationAddress - baseAddress
      guard sourceDistance < UInt64(byteCount), destinationDistance < UInt64(byteCount),
        sourceDistance <= UInt64(Int.max), destinationDistance <= UInt64(Int.max)
      else { return nil }
      let sourceOffset = Int(sourceDistance)
      let destinationOffset = Int(destinationDistance)
      let sourceResolved = resolvedHostOffset(forLogicalOffset: sourceOffset)
      let destinationResolved = resolvedHostOffset(forLogicalOffset: destinationOffset)
      let count = min(
        maximumByteCount, byteCount - sourceOffset, byteCount - destinationOffset,
        sourceResolved.availableByteCount, destinationResolved.availableByteCount)
      guard count > 0 else { return nil }
      guard sourceOffset + count <= destinationOffset || destinationOffset + count <= sourceOffset
      else { return nil }
      try prepareTranslatedCodePagesForWrite(offset: destinationOffset, byteCount: count)
      pointer.advanced(by: destinationResolved.offset).copyMemory(
        from: pointer.advanced(by: sourceResolved.offset), byteCount: count)
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
    return try lock.withLock {
      guard sourceAddress >= baseAddress, destinationAddress >= baseAddress else { return nil }
      let sourceDistance = sourceAddress - baseAddress
      let destinationDistance = destinationAddress - baseAddress
      guard sourceDistance < UInt64(byteCount), destinationDistance < UInt64(byteCount),
        sourceDistance <= UInt64(Int.max), destinationDistance <= UInt64(Int.max)
      else { return nil }
      let sourceOffset = Int(sourceDistance)
      let destinationOffset = Int(destinationDistance)
      let sourceResolved = resolvedHostOffset(forLogicalOffset: sourceOffset)
      let destinationResolved = resolvedHostOffset(forLogicalOffset: destinationOffset)
      let elementCount = min(
        maximumElementCount,
        (byteCount - sourceOffset) / elementByteCount,
        (byteCount - destinationOffset) / elementByteCount,
        sourceResolved.availableByteCount / elementByteCount,
        destinationResolved.availableByteCount / elementByteCount)
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
      try prepareTranslatedCodePagesForWrite(offset: destinationOffset, byteCount: totalBytes)
      pointer.advanced(by: destinationResolved.offset).copyMemory(
        from: pointer.advanced(by: sourceResolved.offset), byteCount: totalBytes)
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
    return try lock.withLock {
      guard destinationAddress >= baseAddress else { return nil }
      let distance = destinationAddress - baseAddress
      guard distance < UInt64(byteCount), distance <= UInt64(Int.max) else { return nil }
      let offset = Int(distance)
      let resolved = resolvedHostOffset(forLogicalOffset: offset)
      let elementCount = min(
        maximumElementCount,
        (byteCount - offset) / pattern.count,
        resolved.availableByteCount / pattern.count
      )
      guard elementCount > 0 else { return nil }
      let totalBytes = elementCount * pattern.count
      try prepareTranslatedCodePagesForWrite(offset: offset, byteCount: totalBytes)
      pattern.withUnsafeBufferPointer { buffer in
        let dest = pointer.advanced(by: resolved.offset)
        dest.copyMemory(from: buffer.baseAddress!, byteCount: pattern.count)
        var filled = pattern.count
        // Replicate the initialized prefix. Each copy is disjoint and ends on
        // an element boundary, including the final partial doubling.
        while filled < totalBytes {
          let count = min(filled, totalBytes - filled)
          dest.advanced(by: filled).copyMemory(from: dest, byteCount: count)
          filled += count
        }
      }
      markCodePagesWritten(offset: offset, byteCount: totalBytes)
      return elementCount
    }
  }
}
