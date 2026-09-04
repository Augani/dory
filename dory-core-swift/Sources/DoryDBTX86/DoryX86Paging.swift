import Foundation

public struct DoryX86PagingContext: Sendable, Hashable {
  public let control: DoryX86ControlState
  public let rflags: DoryX86RFLAGS
  public let currentPrivilegeLevel: UInt8
  public let mode: DoryX86ExecutionMode
  public let isImplicitSupervisorAccess: Bool
  public let supportsOneGiBPages: Bool
  public let supportsPAT: Bool

  public init(
    control: DoryX86ControlState,
    rflags: DoryX86RFLAGS,
    currentPrivilegeLevel: UInt8,
    mode: DoryX86ExecutionMode,
    isImplicitSupervisorAccess: Bool = false,
    supportsOneGiBPages: Bool = true,
    supportsPAT: Bool = true
  ) {
    self.control = control
    self.rflags = rflags
    self.isImplicitSupervisorAccess = isImplicitSupervisorAccess
    self.supportsOneGiBPages = supportsOneGiBPages
    // Direct contexts retain the existing PAT mechanism by default. Product
    // contexts below instead use the selected profile's advertised capability.
    self.supportsPAT = supportsPAT
    // Implicit system-data reads use supervisor paging privileges even in v8086 mode.
    // Ordinary CPL remains fixed in real/v8086 modes, independent of CS selector low bits.
    if isImplicitSupervisorAccess || mode == .real16 {
      self.currentPrivilegeLevel = 0
    } else if mode != .long64, control.efer & (1 << 10) == 0,
      rflags.contains(.virtual8086) {
      self.currentPrivilegeLevel = 3
    } else {
      self.currentPrivilegeLevel = currentPrivilegeLevel & 3
    }
    self.mode = mode
  }

  public init(
    state: DoryX86ArchitecturalState,
    mode: DoryX86ExecutionMode,
    profile: DoryX86CPUProfile = .compatibleV1
  ) {
    self.init(
      control: state.control,
      rflags: state.rflags,
      currentPrivilegeLevel: UInt8(state.cs.selector & 3),
      mode: mode,
      supportsOneGiBPages: profile.supports(.oneGiBPages),
      supportsPAT: profile.cpuid(leaf: 1).edx & (1 << 16) != 0
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
    let legacyPAEPDPTEs: DoryX86PAEPDPTEs?
    let cpl: UInt8
    let access: DoryX86MemoryAccessKind
    let alignmentCheck: Bool
    let isImplicitSupervisorAccess: Bool
    let supportsOneGiBPages: Bool
    let supportsPAT: Bool
    let generation: UInt64
  }

  private struct TLBValue {
    let physicalPage: UInt64
    let pageSize: UInt64
    let userAccessible: Bool
    let writable: Bool
    let executable: Bool
  }

  private struct TLBEntry {
    let key: TLBKey
    let value: TLBValue
  }

  private let lock = NSLock()
  private var entries: [TLBKey: TLBValue] = [:]
  private var recentEntries: [TLBEntry?] = [nil, nil, nil]
  private var generation: UInt64 = 0
  public let physicalAddressBits: UInt8
  public let maximumEntryCount: Int

  public init(physicalAddressBits: UInt8 = 40, maximumEntryCount: Int = 4_096) {
    precondition((32...52).contains(physicalAddressBits))
    precondition(maximumEntryCount > 0)
    self.physicalAddressBits = physicalAddressBits
    self.maximumEntryCount = maximumEntryCount
  }

  public func invalidate(linearAddress: UInt64) {
    lock.lock()
    // A large translation may occupy several 4 KiB cache slots. INVLPG must remove
    // every slot belonging to the large page, including the hot lookup entries.
    func containsAddress(_ key: TLBKey, _ value: TLBValue) -> Bool {
      let pageMask = ~(value.pageSize - 1)
      return (key.linearPage << 12) & pageMask == linearAddress & pageMask
    }
    entries = entries.filter { !containsAddress($0.key, $0.value) }
    for index in recentEntries.indices {
      if let entry = recentEntries[index], containsAddress(entry.key, entry.value) {
        recentEntries[index] = nil
      }
    }
    lock.unlock()
  }

  public func invalidateAll() {
    lock.lock()
    generation &+= 1
    entries.removeAll(keepingCapacity: true)
    recentEntries = [nil, nil, nil]
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
    try context.control.validateLegacyPAEPDPTEs(physicalAddressBits: physicalAddressBits)
    let ia32eActive = context.control.efer & (1 << 10) != 0
    guard isCanonical(linearAddress, bits: ia32eActive ? 48 : 32) else {
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
      legacyPAEPDPTEs: context.control.legacyPAEPDPTEs,
      cpl: context.currentPrivilegeLevel,
      access: access,
      alignmentCheck: context.rflags.contains(.alignmentCheck),
      isImplicitSupervisorAccess: context.isImplicitSupervisorAccess,
      supportsOneGiBPages: context.supportsOneGiBPages,
      supportsPAT: context.supportsPAT,
      generation: generation
    )
    let recentIndex = recentEntryIndex(access)
    if let recent = recentEntries[recentIndex], recent.key == key {
      return makeTranslation(
        linearAddress: linearAddress,
        value: recent.value
      )
    }
    if let cached = entries[key] {
      recentEntries[recentIndex] = .init(key: key, value: cached)
      return makeTranslation(linearAddress: linearAddress, value: cached)
    }

    let translation: DoryX86Translation
    if ia32eActive {
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
    let value = TLBValue(
      physicalPage: translation.physicalAddress & ~0xfff,
      pageSize: translation.pageSize,
      userAccessible: translation.userAccessible,
      writable: translation.writable,
      executable: translation.executable
    )
    entries[key] = value
    recentEntries[recentIndex] = .init(key: key, value: value)
    return translation
  }

  private func recentEntryIndex(_ access: DoryX86MemoryAccessKind) -> Int {
    switch access {
    case .instructionFetch: 0
    case .read: 1
    case .write: 2
    }
  }

  private func makeTranslation(
    linearAddress: UInt64,
    value: TLBValue
  ) -> DoryX86Translation {
    .init(
      linearAddress: linearAddress,
      physicalAddress: value.physicalPage | (linearAddress & 0xfff),
      pageSize: value.pageSize,
      userAccessible: value.userAccessible,
      writable: value.writable,
      executable: value.executable
    )
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
      let bit7 = entry & (1 << 7) != 0
      // Intel SDM Vol. 3A §5.5.3/§5.5.5: PDPTE.PS is reserved when
      // CPUID.80000001H:EDX.Page1GB is absent. Check before any leaf A/D writes.
      if bit7 && (level == 0 || (level == 1 && !context.supportsOneGiBPages)) {
        throw pageFault(linearAddress, access, context, protection: true, reserved: true)
      }
      // Bit 7 is PS in a PDPTE/PDE, but PAT in a 4 KiB PTE.
      let huge = bit7 && (level == 1 || level == 2)
      let isLeaf = level == 3 || huge
      let pageSize: UInt64 = huge ? (level == 1 ? 1 << 30 : 1 << 21) : 1 << 12
      if isLeaf {
        // Intel's physical 4-level implementations all support PAT (§5.9.2).
        // An IA32e/PAT-absent virtual profile is therefore not a qualified Intel
        // hardware combination; conservatively reject its unsupported PAT index.
        try validatePATEntry(entry, large: huge, linearAddress: linearAddress,
          access: access, context: context)
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
    guard let pdptes = context.control.legacyPAEPDPTEs else {
      throw DoryX86StateError.missingLegacyPAEPDPTEs
    }
    // CR3 is consulted only by an architectural PDPTE load. RAM edits and TLB
    // invalidation cannot change these four processor-internal values.
    let pdpte = pdptes[Int((linearAddress >> 30) & 3)]
    guard pdpte & 1 != 0 else {
      throw pageFault(linearAddress, access, context, protection: false)
    }
    let indices = [(linearAddress >> 21) & 0x1ff, (linearAddress >> 12) & 0x1ff]
    var table = pdpte & physicalAddressMask & ~0xfff
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
      try validate64BitEntry(
        entry, linearAddress: linearAddress, access: access, context: context,
        paeDirectoryOrTable: true)
      // Only the PDE/PTE contribute R/W, U/S, NX and accessed/dirty flags.
      user = user && entry & (1 << 2) != 0
      writable = writable && entry & (1 << 1) != 0
      executable = executable && entry & (1 << 63) == 0
      let huge = level == 0 && entry & (1 << 7) != 0
      let isLeaf = level == 1 || huge
      let pageSize: UInt64 = huge ? 1 << 21 : 1 << 12
      if isLeaf {
        try validatePATEntry(entry, large: huge, linearAddress: linearAddress,
          access: access, context: context)
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
    let largePage = context.control.cr4 & (1 << 4) != 0 && directory & (1 << 7) != 0
    // PSE-36 is not modeled: bits 21:13 of a present 4 MiB PDE are reserved,
    // rather than high physical-address bits that can be silently discarded.
    if largePage, directory & 0x003f_e000 != 0 {
      throw pageFault(linearAddress, access, context, protection: true, reserved: true)
    }
    if largePage {
      try validatePATEntry(UInt64(directory), large: true, linearAddress: linearAddress,
        access: access, context: context)
    }
    if directory & (1 << 5) == 0 {
      directory |= 1 << 5
      try writeUInt32(directory, at: directoryAddress, physicalMemory: physicalMemory)
    }
    // With PSE clear, bit 7 is ignored and the PDE still points to a page table.
    if largePage {
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
    // SDM §5.3: with CR4.PSE=0 no bits are reserved in 32-bit paging.
    if context.control.cr4 & (1 << 4) != 0 {
      try validatePATEntry(UInt64(entry), large: false, linearAddress: linearAddress,
        access: access, context: context)
    }
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

  private func validatePATEntry(
    _ entry: UInt64, large: Bool, linearAddress: UInt64,
    access: DoryX86MemoryAccessKind, context: DoryX86PagingContext
  ) throws {
    // SDM 092 Vol. 3A §§5.3/5.4.2: unsupported PAT is reserved in a
    // present leaf: bit 7 for 4KiB, bit 12 for a large page. Nonleaf bit 7
    // is PS, and nonleaf bit 12 is a physical address bit, not a PAT index.
    if !context.supportsPAT, entry & (large ? 1 << 12 : 1 << 7) != 0 {
      throw pageFault(linearAddress, access, context, protection: true, reserved: true)
    }
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
        && (context.isImplicitSupervisorAccess || !context.rflags.contains(.alignmentCheck)))
    if protectionViolation { throw pageFault(linearAddress, access, context, protection: true) }
  }

  private func validate64BitEntry(
    _ entry: UInt64,
    linearAddress: UInt64,
    access: DoryX86MemoryAccessKind,
    context: DoryX86PagingContext,
    paeDirectoryOrTable: Bool = false
  ) throws {
    let nxe = context.control.efer & (1 << 11) != 0
    // PAE PDEs/PTEs reserve bits 62:MAXPHYADDR. IA-32e ignores bits 58:52 and
    // uses/ignores bits 62:59 according to protection-key controls, outside this mask.
    let checkedAddressBits: UInt64 = paeDirectoryOrTable
      ? 0x7fff_ffff_ffff_f000 : 0x000f_ffff_ffff_f000
    let addressBitsOutsideProfile = (entry & checkedAddressBits) & ~physicalAddressMask
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
    let reportsInstructionFetch = context.control.cr4 & (1 << 20) != 0
      || (context.control.cr4 & (1 << 5) != 0 && context.control.efer & (1 << 11) != 0)
    if access == .instructionFetch, reportsInstructionFetch { code |= 1 << 4 }
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
public final class DoryX86TranslatedMemory: DoryX86Memory, DoryX86ScalarMemory, @unchecked Sendable {
  private let physicalMemory: any DoryX86Memory
  private let scalarPhysicalMemory: (any DoryX86ScalarMemory)?
  private let restartableScalarPhysicalMemory: (any DoryX86RestartableScalarMemory)?
  private let bulkPhysicalMemory: (any DoryX86BulkMemory)?
  private let codeGenerationPhysicalMemory: (any DoryX86CodeGenerationMemory)?
  private let pagingUnit: DoryX86PagingUnit
  // Control-register instructions must invalidate the supplied translated-memory cache too.
  var translationUnit: DoryX86PagingUnit { pagingUnit }
  private var context: DoryX86PagingContext

  public init(
    physicalMemory: any DoryX86Memory,
    pagingUnit: DoryX86PagingUnit,
    context: DoryX86PagingContext
  ) {
    self.physicalMemory = physicalMemory
    scalarPhysicalMemory = physicalMemory as? any DoryX86ScalarMemory
    restartableScalarPhysicalMemory = physicalMemory as? any DoryX86RestartableScalarMemory
    bulkPhysicalMemory = physicalMemory as? any DoryX86BulkMemory
    codeGenerationPhysicalMemory = physicalMemory as? any DoryX86CodeGenerationMemory
    self.pagingUnit = pagingUnit
    self.context = context
  }

  /// Refreshes the architectural view before a serialized vCPU dispatch. The owning machine must
  /// never mutate this context concurrently with a memory operation.
  public func updateContext(_ context: DoryX86PagingContext) {
    self.context = context
  }

  public func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    try readLinear(
      at: address, byteCount: maximumCount, access: .instructionFetch, allowShortRead: true)
  }

  public func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    try readLinear(at: address, byteCount: byteCount, access: .read, allowShortRead: false)
  }

  /// Intel SDM Vol. 3A §5.6.1: implicit system-data accesses use supervisor paging
  /// privileges, and SMAP applies even with AC set. Do not change the operand context.
  func readImplicitSupervisor(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    let supervisorContext = DoryX86PagingContext(
      control: context.control, rflags: context.rflags, currentPrivilegeLevel: 0,
      mode: context.mode, isImplicitSupervisorAccess: true,
      supportsOneGiBPages: context.supportsOneGiBPages,
      supportsPAT: context.supportsPAT
    )
    return try readLinear(
      at: address, byteCount: byteCount, access: .read, allowShortRead: false,
      context: supervisorContext
    )
  }

  /// A separate view keeps implicit descriptor reads and busy-bit writes under
  /// supervisor/SMAP rules without changing the explicit instruction operand's context.
  func implicitSupervisorMemory() -> DoryX86TranslatedMemory {
    .init(physicalMemory: physicalMemory, pagingUnit: pagingUnit,
      context: .init(control: context.control, rflags: context.rflags,
        currentPrivilegeLevel: 0, mode: context.mode, isImplicitSupervisorAccess: true,
        supportsOneGiBPages: context.supportsOneGiBPages,
        supportsPAT: context.supportsPAT))
  }

  public func readScalar(at address: UInt64, byteCount: Int) throws -> UInt64 {
    guard [1, 2, 4, 8].contains(byteCount) else {
      throw DoryX86ScalarMemoryError.invalidByteCount(byteCount)
    }
    guard Int(4_096 - (address & 0xfff)) >= byteCount else {
      return try read(at: address, byteCount: byteCount).enumerated().reduce(0) {
        $0 | UInt64($1.element) << UInt64($1.offset * 8)
      }
    }
    let translation = try pagingUnit.translate(
      linearAddress: address,
      access: .read,
      context: context,
      physicalMemory: physicalMemory
    )
    if let scalarMemory = scalarPhysicalMemory {
      return try scalarMemory.readScalar(
        at: translation.physicalAddress, byteCount: byteCount)
    }
    return try physicalMemory.read(
      at: translation.physicalAddress, byteCount: byteCount
    ).enumerated().reduce(0) {
      $0 | UInt64($1.element) << UInt64($1.offset * 8)
    }
  }

  public func write(at address: UInt64, bytes: [UInt8]) throws {
    // A single architectural store may span multiple linear pages. Resolve and validate every
    // backing range before the first byte becomes visible so a later-page fault cannot leave a
    // partially committed store behind.
    try validateWrite(at: address, byteCount: bytes.count)
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

  public func writeScalar(at address: UInt64, value: UInt64, byteCount: Int) throws {
    guard [1, 2, 4, 8].contains(byteCount) else {
      throw DoryX86ScalarMemoryError.invalidByteCount(byteCount)
    }
    guard Int(4_096 - (address & 0xfff)) >= byteCount else {
      let bytes = (0..<byteCount).map {
        UInt8(truncatingIfNeeded: value >> UInt64($0 * 8))
      }
      try write(at: address, bytes: bytes)
      return
    }
    let translation = try pagingUnit.translate(
      linearAddress: address,
      access: .write,
      context: context,
      physicalMemory: physicalMemory
    )
    if let scalarMemory = scalarPhysicalMemory {
      try scalarMemory.writeScalar(
        at: translation.physicalAddress, value: value, byteCount: byteCount)
      return
    }
    let bytes = (0..<byteCount).map {
      UInt8(truncatingIfNeeded: value >> UInt64($0 * 8))
    }
    try physicalMemory.validateWrite(at: translation.physicalAddress, byteCount: byteCount)
    try physicalMemory.write(at: translation.physicalAddress, bytes: bytes)
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
      try physicalMemory.validateWrite(at: translation.physicalAddress, byteCount: count)
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
    allowShortRead: Bool,
    context overrideContext: DoryX86PagingContext? = nil
  ) throws -> [UInt8] {
    guard byteCount > 0 else { return [] }
    let readContext = overrideContext ?? context
    var result: [UInt8] = []
    result.reserveCapacity(byteCount)
    var cursor = address
    while result.count < byteCount {
      do {
        let translation = try pagingUnit.translate(
          linearAddress: cursor, access: access, context: readContext, physicalMemory: physicalMemory)
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

extension DoryX86TranslatedMemory: DoryX86RestartableScalarMemory {
  public func readRestartableScalar(at address: UInt64, byteCount: Int) throws -> UInt64? {
    guard [1, 2, 4, 8].contains(byteCount) else {
      throw DoryX86ScalarMemoryError.invalidByteCount(byteCount)
    }
    guard Int(4_096 - (address & 0xfff)) >= byteCount,
      let restartableScalarPhysicalMemory
    else { return nil }
    let translation = try pagingUnit.translate(
      linearAddress: address,
      access: .read,
      context: context,
      physicalMemory: physicalMemory
    )
    return try restartableScalarPhysicalMemory.readRestartableScalar(
      at: translation.physicalAddress,
      byteCount: byteCount
    )
  }
}

extension DoryX86TranslatedMemory: DoryX86CodeGenerationMemory {
  public func codeGeneration(at address: UInt64, byteCount: Int) throws -> UInt64? {
    guard byteCount > 0, let codeGenerationPhysicalMemory else { return nil }
    var cursor = address
    var remaining = byteCount
    var token: UInt64 = 0xcbf2_9ce4_8422_2325
    while remaining > 0 {
      let translation = try pagingUnit.translate(
        linearAddress: cursor,
        access: .instructionFetch,
        context: context,
        physicalMemory: physicalMemory
      )
      let count = min(Int(4_096 - (cursor & 0xfff)), remaining)
      guard let physicalGeneration = try codeGenerationPhysicalMemory.codeGeneration(
        at: translation.physicalAddress,
        byteCount: count
      ) else { return nil }
      token ^= translation.physicalAddress
      token &*= 0x0000_0100_0000_01b3
      token ^= physicalGeneration
      token &*= 0x0000_0100_0000_01b3
      cursor &+= UInt64(count)
      remaining -= count
    }
    token ^= UInt64(byteCount)
    return token
  }
}

extension DoryX86TranslatedMemory: DoryX86BulkMemory {
  public func bulkCopyRAMSpan(at address: UInt64, maximumByteCount: Int) -> Int? {
    // Linear eligibility depends on paging access kind, so callers must use the copy operation.
    nil
  }

  public func copyForwardNonoverlapping(
    from sourceAddress: UInt64,
    to destinationAddress: UInt64,
    maximumByteCount: Int
  ) throws -> Int? {
    guard maximumByteCount > 0,
      let physicalMemory = bulkPhysicalMemory
    else { return maximumByteCount == 0 ? 0 : nil }
    let source = try pagingUnit.translate(
      linearAddress: sourceAddress,
      access: .read,
      context: context,
      physicalMemory: physicalMemory
    )
    guard
      let sourceSpan = physicalMemory.bulkCopyRAMSpan(
        at: source.physicalAddress,
        maximumByteCount: maximumByteCount
      )
    else { return nil }
    let destination = try pagingUnit.translate(
      linearAddress: destinationAddress,
      access: .write,
      context: context,
      physicalMemory: physicalMemory
    )
    guard
      let destinationSpan = physicalMemory.bulkCopyRAMSpan(
        at: destination.physicalAddress,
        maximumByteCount: maximumByteCount
      )
    else { return nil }
    let count = min(
      maximumByteCount,
      sourceSpan,
      destinationSpan,
      Int(4_096 - (sourceAddress & 0xfff)),
      Int(4_096 - (destinationAddress & 0xfff))
    )
    return try physicalMemory.copyForwardNonoverlapping(
      from: source.physicalAddress,
      to: destination.physicalAddress,
      maximumByteCount: count
    )
  }

  public func copyForwardNonoverlappingElements(
    from sourceAddress: UInt64,
    to destinationAddress: UInt64,
    elementByteCount: Int,
    maximumElementCount: Int,
    excludingDestinationRanges: [Range<UInt64>]
  ) throws -> Int? {
    guard elementByteCount > 0, maximumElementCount > 0,
      maximumElementCount <= Int.max / elementByteCount,
      let physicalMemory = bulkPhysicalMemory
    else { return maximumElementCount == 0 ? 0 : nil }
    let requestedByteCount = maximumElementCount * elementByteCount
    let source = try pagingUnit.translate(
      linearAddress: sourceAddress,
      access: .read,
      context: context,
      physicalMemory: physicalMemory
    )
    let destination = try pagingUnit.translate(
      linearAddress: destinationAddress,
      access: .write,
      context: context,
      physicalMemory: physicalMemory
    )
    guard
      let sourceSpan = physicalMemory.bulkCopyRAMSpan(
        at: source.physicalAddress, maximumByteCount: requestedByteCount),
      let destinationSpan = physicalMemory.bulkCopyRAMSpan(
        at: destination.physicalAddress, maximumByteCount: requestedByteCount)
    else { return nil }
    let byteCount = min(
      requestedByteCount,
      sourceSpan,
      destinationSpan,
      Int(4_096 - (sourceAddress & 0xfff)),
      Int(4_096 - (destinationAddress & 0xfff))
    )
    let elementCount = byteCount / elementByteCount
    guard elementCount > 0 else { return nil }

    var physicalExclusions: [Range<UInt64>] = []
    for exclusion in excludingDestinationRanges where !exclusion.isEmpty {
      var cursor = exclusion.lowerBound
      while cursor < exclusion.upperBound {
        let pageRemaining = UInt64(4_096) - (cursor & 0xfff)
        let remaining = exclusion.upperBound - cursor
        let count = min(pageRemaining, remaining)
        let translated = try pagingUnit.translate(
          linearAddress: cursor,
          access: .instructionFetch,
          context: context,
          physicalMemory: physicalMemory
        )
        let (end, overflow) = translated.physicalAddress.addingReportingOverflow(count)
        guard !overflow else { return nil }
        physicalExclusions.append(translated.physicalAddress..<end)
        cursor += count
      }
    }
    return try physicalMemory.copyForwardNonoverlappingElements(
      from: source.physicalAddress,
      to: destination.physicalAddress,
      elementByteCount: elementByteCount,
      maximumElementCount: elementCount,
      excludingDestinationRanges: physicalExclusions
    )
  }

  public func fillRepeating(
    at destinationAddress: UInt64,
    pattern: [UInt8],
    maximumElementCount: Int
  ) throws -> Int? {
    guard maximumElementCount > 0, !pattern.isEmpty,
      let physicalMemory = bulkPhysicalMemory
    else { return maximumElementCount == 0 ? 0 : nil }
    let destination = try pagingUnit.translate(
      linearAddress: destinationAddress,
      access: .write,
      context: context,
      physicalMemory: physicalMemory
    )
    let pageElementCount = Int(4_096 - (destinationAddress & 0xfff)) / pattern.count
    guard pageElementCount > 0 else { return nil }
    return try physicalMemory.fillRepeating(
      at: destination.physicalAddress,
      pattern: pattern,
      maximumElementCount: min(maximumElementCount, pageElementCount)
    )
  }
}
