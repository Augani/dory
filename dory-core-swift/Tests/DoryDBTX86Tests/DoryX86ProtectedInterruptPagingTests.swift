import Testing

@testable import DoryDBTX86

// Intel SDM Vol. 3A §5.6.1 (implicit system-data accesses), §6.11.5
// (inner-privilege stack override), and §7.12.1 (entry/return frames).
// https://cdrdv2-public.intel.com/922487/253668-092-sdm-vol-3a.pdf
@Suite struct DoryX86ProtectedInterruptPagingTests {
  @Test func nonidentitySupervisorTablesAndInnerStackRoundTripThroughBothLegacyPagingModes() throws {
    for pae in [false, true] {
      let physical = try memory(pae: pae)
      var state = try userState(pae: pae)
      let initial = state
      let paging = DoryX86PagingUnit()
      try DoryX86InterruptDelivery().deliver(vector: 0x80, source: .software,
        state: &state, physicalMemory: physical, pagingUnit: paging, mode: .protected32)
      #expect(state.cs.selector == 8 && state.ss.selector == 16)
      #expect(state.ss.base == 0x30000 && state.rip == 0x1234)
      #expect(state.registers.rsp == 0xFEC)
      #expect(try physical.read(at: 0x7FEC, byteCount: 20)
        == words([initial.rip, 0x1B, initial.rflags.rawValue, 0x1000, 0x23], width: 4))
      #expect(try physical.read(at: 0x8FEC, byteCount: 20) == [UInt8](repeating: 0, count: 20))

      // IRET reads the old inner frame and descriptors; the restored outer
      // stack need not be paged in until a subsequent instruction accesses it.
      try map(0x40, to: 0x8000, flags: 0, pae: pae, memory: physical)
      paging.invalidateAll()
      try DoryX86InterruptDelivery().interruptReturn(state: &state,
        physicalMemory: physical, pagingUnit: paging, mode: .protected32)
      #expect(state.rip == initial.rip && state.registers == initial.registers)
      #expect(state.cs.selector == initial.cs.selector && state.ss.selector == initial.ss.selector)
      #expect(state.ss.base == initial.ss.base && state.rflags == initial.rflags)
    }
  }

  @Test func wordAndDoublewordSamePrivilegeEntriesKeepUserStackPermissions() throws {
    for width in [2, 4] {
      for userPage in [false, true] {
        let physical = try memory()
        try map(0x40, to: 0x8000, flags: userPage ? 7 : 3, memory: physical)
        var state = try userState()
        if width == 2 { state.cs.attributes = 0x00FB }
        let initial = state
        let stackBefore = try physical.read(at: 0x8000, byteCount: 0x1000)
        if userPage {
          try DoryX86InterruptDelivery().deliver(vector: width == 2 ? 0x83 : 0x81,
            source: .software, state: &state, physicalMemory: physical,
            pagingUnit: DoryX86PagingUnit(), mode: width == 2 ? .protected16 : .protected32)
          #expect(state.cs.selector == 0x1B && state.ss == initial.ss)
          #expect(state.registers.rsp == 0x1000 - UInt64(width * 3))
          #expect(try physical.read(at: 0x9000 - UInt64(width * 3), byteCount: width * 3)
            == words([initial.rip, 0x1B, initial.rflags.rawValue], width: width))
        } else {
          let address = UInt64(0x41000 - width)
          #expect(throws: DoryX86MemoryError.pageFault(address: address, errorCode: 7)) {
            try DoryX86InterruptDelivery().deliver(vector: width == 2 ? 0x83 : 0x81,
              source: .software, state: &state, physicalMemory: physical,
              pagingUnit: DoryX86PagingUnit(), mode: width == 2 ? .protected16 : .protected32)
          }
          #expect(state == initial)
          #expect(try physical.read(at: 0x8000, byteCount: 0x1000) == stackBefore)
        }
      }
    }
  }

  @Test func missingSystemPagesPropagateSupervisorFaultsBeforeFrameOrStateEffects() throws {
    for (page, address): (UInt64, UInt64) in [(0x21, 0x21400), (0x20, 0x20008), (0x22, 0x22004)] {
      let physical = try memory()
      try map(page, to: 0, flags: 0, memory: physical)
      var state = try userState()
      let initial = state
      let stackBefore = try physical.read(at: 0x7000, byteCount: 0x2000)
      #expect(throws: DoryX86MemoryError.pageFault(address: address, errorCode: 0)) {
        try DoryX86InterruptDelivery().deliver(vector: 0x80, source: .software,
          state: &state, physicalMemory: physical, pagingUnit: DoryX86PagingUnit(), mode: .protected32)
      }
      #expect(state == initial)
      #expect(try physical.read(at: 0x7000, byteCount: 0x2000) == stackBefore)
    }
  }

  @Test func localDescriptorTableCodeAndStackDescriptorsUseTheirLinearMappings() throws {
    for limit: UInt32 in [0x27, 0x1_0000, .max] {
      let physical = try memory()
      try map(0x23, to: 0xA000, flags: 3, memory: physical)
      try physical.write(at: 0xA000, bytes: physical.read(at: 0x4000, byteCount: 0x28))
      try map(0x20, to: 0, flags: 0, memory: physical) // No GDT read is needed for these selectors.
      try physical.writeScalar(at: 0x5400, value: 0x0000_EE00_000C_1234, byteCount: 8)
      try physical.writeScalar(at: 0x6008, value: 0x14, byteCount: 2)
      var state = try userState()
      state.ldtr = .init(selector: 0x30, attributes: 0x82, limit: limit, base: 0x23000)
      try DoryX86InterruptDelivery().deliver(vector: 0x80, source: .software,
        state: &state, physicalMemory: physical, pagingUnit: DoryX86PagingUnit(), mode: .protected32)
      #expect(state.cs.selector == 0xC && state.ss.selector == 0x14)
      #expect(state.ss.base == 0x30000 && state.registers.rsp == 0xFEC)
      #expect(state.rip == 0x1234)
    }
  }

  @Test func innerStackIsAnExplicitSupervisorAccessSoACControlsSMAP() throws {
    for ac in [false, true] {
      let physical = try memory()
      try map(0x30, to: 0x7000, flags: 7, memory: physical)
      var state = try userState()
      state.control.cr4 |= 1 << 21
      if ac { state.rflags.insert(.alignmentCheck) }
      let initial = state
      let stackBefore = try physical.read(at: 0x7000, byteCount: 0x1000)
      if ac {
        try DoryX86InterruptDelivery().deliver(vector: 0x80, source: .software,
          state: &state, physicalMemory: physical, pagingUnit: DoryX86PagingUnit(), mode: .protected32)
        #expect(state.cs.selector == 8 && state.registers.rsp == 0xFEC)
      } else {
        #expect(throws: DoryX86MemoryError.pageFault(address: 0x30FFC, errorCode: 3)) {
          try DoryX86InterruptDelivery().deliver(vector: 0x80, source: .software,
            state: &state, physicalMemory: physical, pagingUnit: DoryX86PagingUnit(), mode: .protected32)
        }
        #expect(state == initial)
        #expect(try physical.read(at: 0x7000, byteCount: 0x1000) == stackBefore)
      }
    }
  }

  @Test func smapRejectsImplicitIDTGDTAndTSSReadsEvenAfterExplicitACEnabledTLBHits() throws {
    for (page, backing, address): (UInt64, UInt64, UInt64) in [
      (0x21, 0x5000, 0x21400), (0x20, 0x4000, 0x20008), (0x22, 0x6000, 0x22004),
    ] {
      let physical = try memory()
      try map(page, to: backing, flags: 7, memory: physical)
      var state = try userState()
      state.control.cr4 |= 1 << 21
      state.rflags.insert(.alignmentCheck)
      let paging = DoryX86PagingUnit()
      let explicitSupervisor = DoryX86PagingContext(control: state.control,
        rflags: state.rflags, currentPrivilegeLevel: 0, mode: .protected32)
      _ = try paging.translate(linearAddress: address, access: .read,
        context: explicitSupervisor, physicalMemory: physical)
      let initial = state
      let stackBefore = try physical.read(at: 0x7000, byteCount: 0x2000)
      #expect(throws: DoryX86MemoryError.pageFault(address: address, errorCode: 1)) {
        try DoryX86InterruptDelivery().deliver(vector: 0x80, source: .software,
          state: &state, physicalMemory: physical, pagingUnit: paging, mode: .protected32)
      }
      #expect(state == initial)
      #expect(try physical.read(at: 0x7000, byteCount: 0x2000) == stackBefore)
    }
  }

  @Test func lateInnerStackProtectionFaultLeavesTheWholeFrameAndStateUnchanged() throws {
    let physical = try memory()
    try map(0x30, to: 0x7000, flags: 1, memory: physical) // CR0.WP protects this page.
    try map(0x31, to: 0x9000, flags: 3, memory: physical)
    try physical.writeScalar(at: 0x6004, value: 0x1004, byteCount: 4)
    var state = try userState()
    let initial = state
    let stackBefore = try physical.read(at: 0x7000, byteCount: 0x3000)
    // The first push at linear31000 is writable. The second at30FFC faults;
    // translation may update page A/D, but no guest frame bytes may be stored.
    #expect(throws: DoryX86MemoryError.pageFault(address: 0x30FFC, errorCode: 3)) {
      try DoryX86InterruptDelivery().deliver(vector: 0x80, source: .software,
        state: &state, physicalMemory: physical, pagingUnit: DoryX86PagingUnit(), mode: .protected32)
    }
    #expect(state == initial)
    #expect(try physical.read(at: 0x7000, byteCount: 0x3000) == stackBefore)
  }

  @Test func iretdUsesCurrentStackPrivilegesAndImplicitReturnDescriptors() throws {
    for supervisorStack in [false, true] {
      let physical = try memory()
      try map(0x40, to: 0x8000, flags: supervisorStack ? 3 : 7, memory: physical)
      var state = try userState()
      state.registers.rsp = 0xF00
      try physical.write(at: 0x8F00, bytes: words([0x5678, 0x1B, 2], width: 4))
      let initial = state
      if supervisorStack {
        #expect(throws: DoryX86MemoryError.pageFault(address: 0x40F00, errorCode: 5)) {
          try DoryX86InterruptDelivery().interruptReturn(state: &state, physicalMemory: physical,
            pagingUnit: DoryX86PagingUnit(), mode: .protected32)
        }
        #expect(state == initial)
      } else {
        try DoryX86InterruptDelivery().interruptReturn(state: &state, physicalMemory: physical,
          pagingUnit: DoryX86PagingUnit(), mode: .protected32)
        #expect(state.rip == 0x5678 && state.registers.rsp == 0xF0C)
        #expect(state.cs.selector == 0x1B && state.ss == initial.ss)
      }
    }
    let physical = try memory()
    var state = try userState()
    state.registers.rsp = 0xF00
    state.control.cr4 |= 1 << 21
    state.rflags.insert(.alignmentCheck)
    try physical.write(at: 0x8F00, bytes: words([0x5678, 0x1B, 2], width: 4))
    try map(0x20, to: 0x4000, flags: 7, memory: physical)
    let initial = state
    #expect(throws: DoryX86MemoryError.pageFault(address: 0x20018, errorCode: 1)) {
      try DoryX86InterruptDelivery().interruptReturn(state: &state, physicalMemory: physical,
        pagingUnit: DoryX86PagingUnit(), mode: .protected32)
    }
    #expect(state == initial)
  }

  @Test func rawLongModeStackPreflightRejectsAReadableButUnwritableTailBeforeAnyStore() throws {
    let backing = try DoryX86ByteArrayMemory(byteCount: 0x10000)
    try backing.writeScalar(at: 0x4008, value: 0x00AF_9A00_0000_FFFF, byteCount: 8)
    try backing.writeScalar(at: 0x5100, value: 0x0000_8E00_0008_1234, byteCount: 8)
    try backing.writeScalar(at: 0x5108, value: 0, byteCount: 8)
    let memory = DeniedInterruptTailMemory(backing: backing, denied: 0x7FF0..<0x7FF8)
    var state = try DoryX86ArchitecturalState(registers: .init(rsp: 0x8000), rip: 0x6000,
      cs: .init(selector: 8, attributes: 0xA09B, limit: .max),
      gdtr: .init(limit: 0x17, base: 0x4000), idtr: .init(limit: 0xFFF, base: 0x5000))
    let initial = state
    let snapshot = backing.snapshot()
    #expect(throws: DoryX86MemoryError.unmapped(address: 0x7FF0, byteCount: 8, access: .write)) {
      try DoryX86InterruptDelivery().deliver(vector: 16, source: .hardwareException,
        state: &state, physicalMemory: memory, mode: .long64)
    }
    #expect(memory.validationCount == 2 && memory.writeCount == 0)
    #expect(state == initial && backing.snapshot() == snapshot)
  }

  @Test func translatedProtectedStackPreflightPreservesBackingWriteAuthorityAndFrameAtomicity() throws {
    let backing = try memory()
    let physical = DeniedInterruptTailMemory(backing: backing, denied: 0x7FF8..<0x7FFC)
    var state = try userState()
    let initial = state
    let stackBefore = try backing.read(at: 0x7000, byteCount: 0x1000)
    #expect(throws: DoryX86MemoryError.unmapped(address: 0x7FF8, byteCount: 4, access: .write)) {
      try DoryX86InterruptDelivery().deliver(vector: 0x80, source: .software,
        state: &state, physicalMemory: physical, pagingUnit: DoryX86PagingUnit(), mode: .protected32)
    }
    #expect(state == initial)
    #expect(try backing.read(at: 0x7000, byteCount: 0x1000) == stackBefore)
    #expect(physical.stackWriteCount == 0)
  }

  @Test func longModeSystemViewsAlsoEnforceImplicitSMAPWithACSet() throws {
    for isReturn in [false, true] {
      let physical = try DoryX86ByteArrayMemory(byteCount: 0x10000)
      try physical.writeScalar(at: 0x1000, value: 0x2007, byteCount: 8)
      try physical.writeScalar(at: 0x2000, value: 0x3007, byteCount: 8)
      try physical.writeScalar(at: 0x3000, value: 0x87, byteCount: 8)
      try physical.writeScalar(at: 0x5008, value: 0x00AF_9A00_0000_FFFF, byteCount: 8)
      try physical.writeScalar(at: 0x6100, value: 0x0000_8E00_0008_1234, byteCount: 8)
      try physical.write(at: 0x8000, bytes: words([0x1234, 8, 2, 0x9000, 16], width: 8))
      var state = try DoryX86ArchitecturalState(registers: .init(rsp: 0x8000), rip: 0x7000,
        rflags: [.reservedOne, .alignmentCheck],
        cs: .init(selector: 8, attributes: 0xA09B, limit: .max),
        gdtr: .init(limit: 0x17, base: 0x5000), idtr: .init(limit: 0xFFF, base: 0x6000),
        control: .init(cr0: 0x8001_0011, cr3: 0x1000, cr4: (1 << 5) | (1 << 21),
          efer: (1 << 10) | (1 << 11)))
      let initial = state
      let stackBefore = try physical.read(at: 0x7000, byteCount: 0x2000)
      #expect(throws: DoryX86MemoryError.pageFault(address: isReturn ? 0x5008 : 0x6100, errorCode: 1)) {
        if isReturn {
          try DoryX86InterruptDelivery().interruptReturn(state: &state, physicalMemory: physical,
            pagingUnit: DoryX86PagingUnit(), mode: .long64)
        } else {
          try DoryX86InterruptDelivery().deliver(vector: 16, source: .hardwareException,
            state: &state, physicalMemory: physical, pagingUnit: DoryX86PagingUnit(), mode: .long64)
        }
      }
      #expect(state == initial)
      #expect(try physical.read(at: 0x7000, byteCount: 0x2000) == stackBefore)
    }
  }

  private func memory(pae: Bool = false) throws -> DoryX86ByteArrayMemory {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x10000)
    try memory.writeScalar(at: 0x1000, value: pae ? 0x2001 : 0x2007, byteCount: pae ? 8 : 4)
    if pae { try memory.writeScalar(at: 0x2000, value: 0x3007, byteCount: 8) }
    for (page, backing, flags): (UInt64, UInt64, UInt64) in [
      (0x20, 0x4000, 3), (0x21, 0x5000, 3), (0x22, 0x6000, 3),
      (0x30, 0x7000, 3), (0x40, 0x8000, 7),
    ] { try map(page, to: backing, flags: flags, pae: pae, memory: memory) }
    for (offset, base, limit, access): (UInt64, UInt64, UInt64, UInt64) in [
      (8, 0, 0xFFFF, 0x9B), (16, 0x30000, 0x1FFF, 0x93),
      (24, 0, 0xFFFF, 0xFB), (32, 0x40000, 0x1FFF, 0xF3),
    ] {
      let descriptor = (limit & 0xFFFF) | ((base & 0xFFFF) << 16)
        | (((base >> 16) & 0xFF) << 32) | (access << 40)
        | (((limit >> 16) & 15) << 48) | (UInt64(4) << 52) | (((base >> 24) & 255) << 56)
      try memory.writeScalar(at: 0x4000 + offset, value: descriptor, byteCount: 8)
    }
    for vector: UInt64 in 0x80...0x83 {
      let selector: UInt64 = vector & 1 == 0 ? 8 : 0x1B
      let attributes: UInt64 = vector >= 0x82 ? 0xE6 : 0xEE
      try memory.writeScalar(at: 0x5000 + vector * 8,
        value: 0x1234 | selector << 16 | attributes << 40, byteCount: 8)
    }
    try memory.writeScalar(at: 0x6004, value: 0x1000, byteCount: 4)
    try memory.writeScalar(at: 0x6008, value: 16, byteCount: 2)
    return memory
  }

  private func map(_ page: UInt64, to backing: UInt64, flags: UInt64,
    pae: Bool = false, memory: DoryX86ByteArrayMemory) throws {
    try memory.writeScalar(at: (pae ? 0x3000 : 0x2000) + page * (pae ? 8 : 4),
      value: backing | flags, byteCount: pae ? 8 : 4)
  }

  private func userState(pae: Bool = false) throws -> DoryX86ArchitecturalState {
    try .init(registers: .init(rsp: 0x1000), rip: 0x5678,
      rflags: [.reservedOne, .interruptEnable],
      cs: .init(selector: 0x1B, attributes: 0x40FB, limit: 0xFFFF),
      ss: .init(selector: 0x23, attributes: 0x40F3, limit: 0x1FFF, base: 0x40000),
      tr: .init(selector: 0x28, attributes: 0x8B, limit: 0x67, base: 0x22000),
      gdtr: .init(limit: 0x27, base: 0x20000), idtr: .init(limit: 0xFFF, base: 0x21000),
      control: .init(cr0: 0x8001_0011, cr3: 0x1000, cr4: pae ? 1 << 5 : 0,
        legacyPAEPDPTEs: pae ? .init(0x2001) : nil))
  }

  private func words(_ values: [UInt64], width: Int) -> [UInt8] {
    values.flatMap { value in (0..<width).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
  }
}

private final class DeniedInterruptTailMemory: DoryX86Memory, @unchecked Sendable {
  let backing: DoryX86ByteArrayMemory
  let denied: Range<UInt64>
  private(set) var validationCount = 0
  private(set) var writeCount = 0
  private(set) var stackWriteCount = 0

  init(backing: DoryX86ByteArrayMemory, denied: Range<UInt64>) {
    self.backing = backing
    self.denied = denied
  }

  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    try backing.instructionBytes(at: address, maximumCount: maximumCount)
  }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    try backing.read(at: address, byteCount: byteCount)
  }

  func validateWrite(at address: UInt64, byteCount: Int) throws {
    validationCount += 1
    if (address..<(address + UInt64(byteCount))).overlaps(denied) {
      throw DoryX86MemoryError.unmapped(address: address, byteCount: byteCount, access: .write)
    }
    try backing.validateWrite(at: address, byteCount: byteCount)
  }

  func write(at address: UInt64, bytes: [UInt8]) throws {
    try validateWrite(at: address, byteCount: bytes.count)
    writeCount += 1
    if address >= 0x7000 { stackWriteCount += 1 }
    try backing.write(at: address, bytes: bytes)
  }
}
