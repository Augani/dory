import Foundation

public struct DoryX86PagingContext: Sendable, Hashable {
  public let control: DoryX86ControlState
  public let rflags: DoryX86RFLAGS
  public let currentPrivilegeLevel: UInt8
  public let mode: DoryX86ExecutionMode

  public init(
    control: DoryX86ControlState,
    rflags: DoryX86RFLAGS,
    currentPrivilegeLevel: UInt8,
    mode: DoryX86ExecutionMode
  ) {
    self.control = control
    self.rflags = rflags
    self.currentPrivilegeLevel = currentPrivilegeLevel & 3
    self.mode = mode
  }

  public init(state: DoryX86ArchitecturalState, mode: DoryX86ExecutionMode) {
    self.init(
      control: state.control,
      rflags: state.rflags,
      currentPrivilegeLevel: UInt8(state.cs.selector & 3),
      mode: mode
    )
  }
}

public struct DoryX86Translation: Sendable, Hashable {
  public let linearAddress: UInt64
  public let physicalAddress: UInt64
  public let pageSize: UInt64
  public let userAccessible: Bool
  public let writable: Bool
  public let executable: Bool
}

/// Architectural x86 paging walker. The TLB is an implementation cache only: its key contains all
/// guest-visible permission inputs and every invalidation operation removes lookup visibility
/// synchronously before returning.
public final class DoryX86PagingUnit: @unchecked Sendable {
  private struct TLBKey: Hashable {
    let linearPage: UInt64
    let cr3: UInt64
    let cr0: UInt64
    let cr4: UInt64
    let efer: UInt64
    let cpl: UInt8
    let access: DoryX86MemoryAccessKind
    let alignmentCheck: Bool
    let generation: UInt64
  }

  private struct TLBValue {
    let physicalPage: UInt64
    let pageSize: UInt64
    let userAccessible: Bool
    let writable: Bool
    let executable: Bool
  }

  private let lock = NSLock()
  private var entries: [TLBKey: TLBValue] = [:]
  private var generation: UInt64 = 0
  private let physicalAddressBits: UInt8
  private let maximumEntryCount: Int

  public init(physicalAddressBits: UInt8 = 40, maximumEntryCount: Int = 4_096) {
    precondition((32...52).contains(physicalAddressBits))
    precondition(maximumEntryCount > 0)
    self.physicalAddressBits = physicalAddressBits
    self.maximumEntryCount = maximumEntryCount
  }

  public func invalidate(linearAddress: UInt64) {
    lock.lock()
    entries = entries.filter { $0.key.linearPage != linearAddress >> 12 }
    lock.unlock()
  }

  public func invalidateAll() {
    lock.lock()
    generation &+= 1
    entries.removeAll(keepingCapacity: true)
    lock.unlock()
  }

  public var cachedTranslationCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return entries.count
  }

  public func translate(
    linearAddress: UInt64,
    access: DoryX86MemoryAccessKind,
    context: DoryX86PagingContext,
    physicalMemory: any DoryX86Memory
  ) throws -> DoryX86Translation {
    guard isCanonical(linearAddress, bits: context.mode == .long64 ? 48 : 32) else {
      throw DoryX86MemoryError.addressOverflow(address: linearAddress, byteCount: 1)
    }
    guard context.control.cr0 & (1 << 31) != 0 else {
      return .init(
        linearAddress: linearAddress,
        physicalAddress: linearAddress,
        pageSize: 4_096,
        userAccessible: true,
        writable: true,
        executable: true
      )
    }

    lock.lock()
    defer { lock.unlock() }
    let key = TLBKey(
      linearPage: linearAddress >> 12,
      cr3: context.control.cr3,
      cr0: context.control.cr0,
      cr4: context.control.cr4,
      efer: context.control.efer,
      cpl: context.currentPrivilegeLevel,
      access: access,
      alignmentCheck: context.rflags.contains(.alignmentCheck),
      generation: generation
    )
    if let cached = entries[key] {
      return .init(
        linearAddress: linearAddress,
        physicalAddress: cached.physicalPage | (linearAddress & 0xfff),
        pageSize: cached.pageSize,
        userAccessible: cached.userAccessible,
        writable: cached.writable,
        executable: cached.executable
      )
    }

    let translation: DoryX86Translation
    if context.mode == .long64 {
      translation = try walkIA32e(
        linearAddress: linearAddress,
        access: access,
        context: context,
        physicalMemory: physicalMemory
      )
    } else if context.control.cr4 & (1 << 5) != 0 {
      translation = try walkPAE(
        linearAddress: linearAddress,
        access: access,
        context: context,
        physicalMemory: physicalMemory
      )
    } else {
      translation = try walkLegacy32(
        linearAddress: linearAddress,
        access: access,
        context: context,
        physicalMemory: physicalMemory
      )
    }
    if entries.count >= maximumEntryCount { entries.removeAll(keepingCapacity: true) }
    entries[key] = .init(
      physicalPage: translation.physicalAddress & ~0xfff,
      pageSize: translation.pageSize,
      userAccessible: translation.userAccessible,
      writable: translation.writable,
      executable: translation.executable
    )
    return translation
  }

  private func walkIA32e(
    linearAddress: UInt64,
    access: DoryX86MemoryAccessKind,
    context: DoryX86PagingContext,
    physicalMemory: any DoryX86Memory
  ) throws -> DoryX86Translation {
    guard context.control.cr4 & (1 << 5) != 0,
      context.control.efer & (1 << 10) != 0
    else {
      throw DoryX86MemoryError.pageFault(
        address: linearAddress,
        errorCode: faultCode(access: access, context: context, protection: true, reserved: true)
      )
    }
    let indices = [39, 30, 21, 12].map { (linearAddress >> UInt64($0)) & 0x1ff }
    var table = context.control.cr3 & physicalAddressMask & ~0xfff
    var user = true
    var writable = true
    var executable = true
    for (level, index) in indices.enumerated() {
      let entryAddress = table &+ index &* 8
      var entry = try readUInt64(
        at: entryAddress, physicalMemory: physicalMemory, linearAddress: linearAddress,
        access: access, context: context)
      guard entry & 1 != 0 else {
        throw pageFault(linearAddress, access, context, protection: false)
      }
      try validate64BitEntry(entry, linearAddress: linearAddress, access: access, context: context)
      user = user && entry & (1 << 2) != 0
      writable = writable && entry & (1 << 1) != 0
      executable = executable && entry & (1 << 63) == 0
      let huge = entry & (1 << 7) != 0
      if huge && level < 1 {
        throw pageFault(linearAddress, access, context, protection: true, reserved: true)
      }
      let isLeaf = level == 3 || huge
      let pageSize: UInt64 = huge ? (level == 1 ? 1 << 30 : 1 << 21) : 1 << 12
      if isLeaf {
        let rawAddressField = entry & physicalAddressMask & ~0xfff
        let permittedPATBit: UInt64 = huge ? 1 << 12 : 0
        guard rawAddressField & (pageSize - 1) & ~permittedPATBit == 0 else {
          throw pageFault(linearAddress, access, context, protection: true, reserved: true)
        }
        let addressField = rawAddressField & ~(pageSize - 1)
        try enforcePermissions(
          linearAddress: linearAddress,
          access: access,
          context: context,
          user: user,
          writable: writable,
          executable: executable
        )
        var changed = false
        if entry & (1 << 5) == 0 {
          entry |= 1 << 5
          changed = true
        }
        if access == .write, entry & (1 << 6) == 0 {
          entry |= 1 << 6
          changed = true
        }
        if changed { try writeUInt64(entry, at: entryAddress, physicalMemory: physicalMemory) }
        return .init(
          linearAddress: linearAddress,
          physicalAddress: addressField | (linearAddress & (pageSize - 1)),
          pageSize: pageSize,
          userAccessible: user,
          writable: writable,
          executable: executable
        )
      }
      if entry & (1 << 5) == 0 {
        entry |= 1 << 5
        try writeUInt64(entry, at: entryAddress, physicalMemory: physicalMemory)
      }
      table = entry & physicalAddressMask & ~0xfff
    }
    preconditionFailure("IA-32e walk must return at a leaf")
  }

  private func walkPAE(
    linearAddress: UInt64,
    access: DoryX86MemoryAccessKind,
    context: DoryX86PagingContext,
    physicalMemory: any DoryX86Memory
  ) throws -> DoryX86Translation {
    let indices = [
      (linearAddress >> 30) & 0x3, (linearAddress >> 21) & 0x1ff, (linearAddress >> 12) & 0x1ff,
    ]
    var table = context.control.cr3 & physicalAddressMask & ~0x1f
    var user = true
    var writable = true
    var executable = true
    for (level, index) in indices.enumerated() {
      let entryAddress = table &+ index &* 8
      var entry = try readUInt64(
        at: entryAddress, physicalMemory: physicalMemory, linearAddress: linearAddress,
        access: access, context: context)
      guard entry & 1 != 0 else {
        throw pageFault(linearAddress, access, context, protection: false)
      }
      try validate64BitEntry(entry, linearAddress: linearAddress, access: access, context: context)
      user = user && entry & (1 << 2) != 0
      writable = writable && entry & (1 << 1) != 0
      executable = executable && entry & (1 << 63) == 0
      let huge = level == 1 && entry & (1 << 7) != 0
      let isLeaf = level == 2 || huge
      let pageSize: UInt64 = huge ? 1 << 21 : 1 << 12
      if isLeaf {
        let rawAddressField = entry & physicalAddressMask & ~0xfff
        let permittedPATBit: UInt64 = huge ? 1 << 12 : 0
        guard rawAddressField & (pageSize - 1) & ~permittedPATBit == 0 else {
          throw pageFault(linearAddress, access, context, protection: true, reserved: true)
        }
        let addressField = rawAddressField & ~(pageSize - 1)
        try enforcePermissions(
          linearAddress: linearAddress, access: access, context: context, user: user,
          writable: writable, executable: executable)
        var changed = false
        if entry & (1 << 5) == 0 {
          entry |= 1 << 5
          changed = true
        }
        if access == .write, entry & (1 << 6) == 0 {
          entry |= 1 << 6
          changed = true
        }
        if changed { try writeUInt64(entry, at: entryAddress, physicalMemory: physicalMemory) }
        return .init(
          linearAddress: linearAddress,
          physicalAddress: addressField | (linearAddress & (pageSize - 1)),
          pageSize: pageSize,
          userAccessible: user,
          writable: writable,
          executable: executable
        )
      }
      if entry & (1 << 5) == 0 {
        entry |= 1 << 5
        try writeUInt64(entry, at: entryAddress, physicalMemory: physicalMemory)
      }
      table = entry & physicalAddressMask & ~0xfff
    }
    preconditionFailure("PAE walk must return at a leaf")
  }

  private func walkLegacy32(
    linearAddress: UInt64,
    access: DoryX86MemoryAccessKind,
    context: DoryX86PagingContext,
    physicalMemory: any DoryX86Memory
  ) throws -> DoryX86Translation {
    let directoryAddress =
      (context.control.cr3 & 0xffff_f000) &+ ((linearAddress >> 22) & 0x3ff) &* 4
    var directory = try readUInt32(
      at: directoryAddress, physicalMemory: physicalMemory, linearAddress: linearAddress,
      access: access, context: context)
    guard directory & 1 != 0 else {
      throw pageFault(linearAddress, access, context, protection: false)
    }
    var user = directory & (1 << 2) != 0
    var writable = directory & (1 << 1) != 0
    if directory & (1 << 5) == 0 {
      directory |= 1 << 5
      try writeUInt32(directory, at: directoryAddress, physicalMemory: physicalMemory)
    }
    if directory & (1 << 7) != 0 {
      guard context.control.cr4 & (1 << 4) != 0 else {
        throw pageFault(linearAddress, access, context, protection: true, reserved: true)
      }
      let pageSize: UInt64 = 1 << 22
      let addressField = UInt64(directory) & 0xffc0_0000
      try enforcePermissions(
        linearAddress: linearAddress, access: access, context: context, user: user,
        writable: writable, executable: true)
      if access == .write, directory & (1 << 6) == 0 {
        directory |= 1 << 6
        try writeUInt32(directory, at: directoryAddress, physicalMemory: physicalMemory)
      }
      return .init(
        linearAddress: linearAddress,
        physicalAddress: addressField | (linearAddress & (pageSize - 1)), pageSize: pageSize,
        userAccessible: user, writable: writable, executable: true)
    }
    let table = UInt64(directory & 0xffff_f000)
    let entryAddress = table &+ ((linearAddress >> 12) & 0x3ff) &* 4
    var entry = try readUInt32(
      at: entryAddress, physicalMemory: physicalMemory, linearAddress: linearAddress,
      access: access, context: context)
    guard entry & 1 != 0 else { throw pageFault(linearAddress, access, context, protection: false) }
    user = user && entry & (1 << 2) != 0
    writable = writable && entry & (1 << 1) != 0
    try enforcePermissions(
      linearAddress: linearAddress, access: access, context: context, user: user,
      writable: writable, executable: true)
    var changed = false
    if entry & (1 << 5) == 0 {
      entry |= 1 << 5
      changed = true
    }
    if access == .write, entry & (1 << 6) == 0 {
      entry |= 1 << 6
      changed = true
    }
    if changed { try writeUInt32(entry, at: entryAddress, physicalMemory: physicalMemory) }
    return .init(
      linearAddress: linearAddress,
      physicalAddress: UInt64(entry & 0xffff_f000) | (linearAddress & 0xfff), pageSize: 1 << 12,
      userAccessible: user, writable: writable, executable: true)
  }

  private func enforcePermissions(
    linearAddress: UInt64,
    access: DoryX86MemoryAccessKind,
    context: DoryX86PagingContext,
    user: Bool,
    writable: Bool,
    executable: Bool
  ) throws {
    let supervisor = context.currentPrivilegeLevel < 3
    let writeProtect = context.control.cr0 & (1 << 16) != 0
    let smep = context.control.cr4 & (1 << 20) != 0
    let smap = context.control.cr4 & (1 << 21) != 0
    let protectionViolation =
      (!supervisor && !user) || (access == .write && !writable && (!supervisor || writeProtect))
      || (access == .instructionFetch && !executable)
      || (supervisor && access == .instructionFetch && smep && user)
      || (supervisor && access != .instructionFetch && smap && user
        && !context.rflags.contains(.alignmentCheck))
    if protectionViolation { throw pageFault(linearAddress, access, context, protection: true) }
  }

  private func validate64BitEntry(
    _ entry: UInt64,
    linearAddress: UInt64,
    access: DoryX86MemoryAccessKind,
    context: DoryX86PagingContext
  ) throws {
    let nxe = context.control.efer & (1 << 11) != 0
    let addressBitsOutsideProfile = (entry & 0x000f_ffff_ffff_f000) & ~physicalAddressMask
    if addressBitsOutsideProfile != 0 || (!nxe && entry & (1 << 63) != 0) {
      throw pageFault(linearAddress, access, context, protection: true, reserved: true)
    }
  }

  private func pageFault(
    _ address: UInt64,
    _ access: DoryX86MemoryAccessKind,
    _ context: DoryX86PagingContext,
    protection: Bool,
    reserved: Bool = false
  ) -> DoryX86MemoryError {
    .pageFault(
      address: address,
      errorCode: faultCode(
        access: access, context: context, protection: protection, reserved: reserved))
  }

  private func faultCode(
    access: DoryX86MemoryAccessKind,
    context: DoryX86PagingContext,
    protection: Bool,
    reserved: Bool
  ) -> UInt32 {
    var code: UInt32 = protection ? 1 : 0
    if access == .write { code |= 1 << 1 }
    if context.currentPrivilegeLevel == 3 { code |= 1 << 2 }
    if reserved { code |= 1 << 3 }
    if access == .instructionFetch { code |= 1 << 4 }
    return code
  }

  private var physicalAddressMask: UInt64 {
    let lowMask = physicalAddressBits == 64 ? UInt64.max : (UInt64(1) << physicalAddressBits) - 1
    return lowMask & 0x000f_ffff_ffff_f000
  }

  private func isCanonical(_ address: UInt64, bits: Int) -> Bool {
    if bits == 32 { return address <= UInt64(UInt32.max) }
    let lowMask = (UInt64(1) << UInt64(bits)) - 1
    let sign = UInt64(1) << UInt64(bits - 1)
    let canonical = address & sign == 0 ? address & lowMask : address | ~lowMask
    return address == canonical
  }

  private func readUInt64(
    at address: UInt64,
    physicalMemory: any DoryX86Memory,
    linearAddress: UInt64,
    access: DoryX86MemoryAccessKind,
    context: DoryX86PagingContext
  ) throws -> UInt64 {
    do { return fromLittleEndian(try physicalMemory.read(at: address, byteCount: 8)) } catch {
      throw pageFault(linearAddress, access, context, protection: false)
    }
  }

  private func readUInt32(
    at address: UInt64,
    physicalMemory: any DoryX86Memory,
    linearAddress: UInt64,
    access: DoryX86MemoryAccessKind,
    context: DoryX86PagingContext
  ) throws -> UInt32 {
    do {
      return UInt32(
        truncatingIfNeeded: fromLittleEndian(try physicalMemory.read(at: address, byteCount: 4)))
    } catch { throw pageFault(linearAddress, access, context, protection: false) }
  }

  private func writeUInt64(_ value: UInt64, at address: UInt64, physicalMemory: any DoryX86Memory)
    throws
  {
    try physicalMemory.write(at: address, bytes: littleEndian(value, byteCount: 8))
  }

  private func writeUInt32(_ value: UInt32, at address: UInt64, physicalMemory: any DoryX86Memory)
    throws
  {
    try physicalMemory.write(at: address, bytes: littleEndian(UInt64(value), byteCount: 4))
  }

  private func littleEndian(_ value: UInt64, byteCount: Int) -> [UInt8] {
    (0..<byteCount).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
  }

  private func fromLittleEndian(_ bytes: [UInt8]) -> UInt64 {
    bytes.enumerated().reduce(0) { $0 | UInt64($1.element) << UInt64($1.offset * 8) }
  }
}

/// Per-step linear address-space view. It composes paging with physical memory while preserving
/// the interpreter's exact access kind and handling accesses that cross guest page boundaries.
public final class DoryX86TranslatedMemory: DoryX86Memory, @unchecked Sendable {
  private let physicalMemory: any DoryX86Memory
  private let pagingUnit: DoryX86PagingUnit
  private let context: DoryX86PagingContext

  public init(
    physicalMemory: any DoryX86Memory,
    pagingUnit: DoryX86PagingUnit,
    context: DoryX86PagingContext
  ) {
    self.physicalMemory = physicalMemory
    self.pagingUnit = pagingUnit
    self.context = context
  }

  public func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    try readLinear(
      at: address, byteCount: maximumCount, access: .instructionFetch, allowShortRead: true)
  }

  public func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    try readLinear(at: address, byteCount: byteCount, access: .read, allowShortRead: false)
  }

  public func write(at address: UInt64, bytes: [UInt8]) throws {
    var remaining = bytes[...]
    var cursor = address
    while !remaining.isEmpty {
      let translation = try pagingUnit.translate(
        linearAddress: cursor, access: .write, context: context, physicalMemory: physicalMemory)
      let pageRemaining = Int(4_096 - (cursor & 0xfff))
      let count = min(pageRemaining, remaining.count)
      try physicalMemory.write(
        at: translation.physicalAddress, bytes: Array(remaining.prefix(count)))
      remaining = remaining.dropFirst(count)
      cursor &+= UInt64(count)
    }
  }

  public func validateWrite(at address: UInt64, byteCount: Int) throws {
    guard byteCount > 0 else { return }
    var cursor = address
    var remaining = byteCount
    while remaining > 0 {
      let translation = try pagingUnit.translate(
        linearAddress: cursor,
        access: .write,
        context: context,
        physicalMemory: physicalMemory
      )
      let count = min(Int(4_096 - (cursor & 0xfff)), remaining)
      _ = try physicalMemory.read(at: translation.physicalAddress, byteCount: count)
      cursor &+= UInt64(count)
      remaining -= count
    }
  }

  public func synchronize() {
    physicalMemory.synchronize()
  }

  private func readLinear(
    at address: UInt64,
    byteCount: Int,
    access: DoryX86MemoryAccessKind,
    allowShortRead: Bool
  ) throws -> [UInt8] {
    guard byteCount > 0 else { return [] }
    var result: [UInt8] = []
    result.reserveCapacity(byteCount)
    var cursor = address
    while result.count < byteCount {
      do {
        let translation = try pagingUnit.translate(
          linearAddress: cursor, access: access, context: context, physicalMemory: physicalMemory)
        let count = min(Int(4_096 - (cursor & 0xfff)), byteCount - result.count)
        result += try physicalMemory.read(at: translation.physicalAddress, byteCount: count)
        cursor &+= UInt64(count)
      } catch {
        if allowShortRead, !result.isEmpty { return result }
        throw error
      }
    }
    return result
  }
}
