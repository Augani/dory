import Testing

@testable import DoryDBTX86

// Intel SDM 092 Vol. 3A §5.3 p5-10, §5.4.2 pp5-15/16 and §5.9.2:
// https://cdrdv2-public.intel.com/922487/253668-092-sdm-vol-3a.pdf
// Physical Intel implementations of 4-level paging all support PAT. IA32e with
// PAT masked below is a conservative virtual-profile policy, not that hardware
// combination's qualification. No PAT memory-type semantics are advertised here.
@Suite struct DoryX86PATReservedBitsTests {
  @Test func presentLeafPATBitsFaultBeforeLeafAccessedDirtyUpdates() throws {
    for shape in Shape.allCases {
      for cpl: UInt8 in [0, 3] {
        for nxe in [false, true] {
          for access: DoryX86MemoryAccessKind in [.read, .write, .instructionFetch] {
            let fixture = try fixture(shape)
            let before = try word(fixture.memory, at: fixture.leaf, width: shape.entryWidth)
            let paging = DoryX86PagingUnit()
            let context = context(fixture, supportsPAT: false, cpl: cpl, nxe: nxe)
            let code = faultCode(shape, cpl: cpl, nxe: nxe, access: access, reserved: true)
            #expect(throws: DoryX86MemoryError.pageFault(address: 0x123, errorCode: code)) {
              try paging.translate(linearAddress: 0x123, access: access,
                context: context, physicalMemory: fixture.memory)
            }
            #expect(try word(fixture.memory, at: fixture.leaf, width: shape.entryWidth) == before)
            #expect(paging.cachedTranslationCount == 0)
          }
        }
      }
    }
  }

  @Test func nonpresentLeafPATBitsNeverBecomeReservedFaults() throws {
    for shape in Shape.allCases {
      let fixture = try fixture(shape)
      let absent = try word(fixture.memory, at: fixture.leaf, width: shape.entryWidth) & ~UInt64(1)
      try fixture.memory.writeScalar(at: fixture.leaf, value: absent, byteCount: shape.entryWidth)
      for access: DoryX86MemoryAccessKind in [.read, .write, .instructionFetch] {
        let code = faultCode(shape, cpl: 3, nxe: true, access: access, reserved: false)
        #expect(throws: DoryX86MemoryError.pageFault(address: 0x123, errorCode: code)) {
          try DoryX86PagingUnit().translate(linearAddress: 0x123, access: access,
            context: context(fixture, supportsPAT: false, cpl: 3, nxe: true), physicalMemory: fixture.memory)
        }
        #expect(try word(fixture.memory, at: fixture.leaf, width: shape.entryWidth) == absent)
      }
    }
  }

  @Test func PATMechanismOptInAndOrdinaryPageSizeAddressBitsRemainDistinct() throws {
    for shape in Shape.allCases {
      for pat in [false, true] {
        let fixture = try fixture(shape, pat: pat)
        let result = try DoryX86PagingUnit().translate(linearAddress: 0x123, access: .read,
          context: context(fixture, supportsPAT: pat, cpl: 3), physicalMemory: fixture.memory)
        #expect(result.physicalAddress == fixture.physicalBase + 0x123)
        #expect(result.pageSize == shape.pageSize)
        // Large leaves still recognize bit7 as PS even when PAT is unavailable;
        // nonleaf table addresses deliberately contain physical address bit12.
        #expect(try word(fixture.memory, at: fixture.leaf, width: shape.entryWidth) & 0x20 != 0)
      }
    }
  }

  @Test func legacyPSEClearIgnoresPATAndPDEPageSizeBits() throws {
    let fixture = try fixture(.legacy4K)
    try fixture.memory.writeScalar(at: 0x1000, value: 0x3087, byteCount: 4)
    var control = fixture.control
    control.cr4 = 0 // §5.3: no reserved bits with CR4.PSE=0.
    let context = DoryX86PagingContext(control: control, rflags: .reset,
      currentPrivilegeLevel: 3, mode: .protected32, supportsPAT: false)
    let result = try DoryX86PagingUnit().translate(linearAddress: 0x123, access: .write,
      context: context, physicalMemory: fixture.memory)
    #expect(result.pageSize == 4096 && result.physicalAddress == 0x5123)
    #expect(try word(fixture.memory, at: 0x3000, width: 4) & 0x60 == 0x60)
  }

  @Test func warmedTLBAndImplicitSupervisorCopiesRetainThePATCapability() throws {
    for shape in Shape.allCases {
      let fixture = try fixture(shape)
      let paging = DoryX86PagingUnit()
      let enabled = context(fixture, supportsPAT: true, cpl: 3)
      let disabled = context(fixture, supportsPAT: false, cpl: 3)
      #expect(enabled != disabled)
      for access: DoryX86MemoryAccessKind in [.read, .write] {
        _ = try paging.translate(linearAddress: 0x123, access: access,
          context: enabled, physicalMemory: fixture.memory)
        #expect(throws: DoryX86MemoryError.pageFault(address: 0x123,
          errorCode: access == .write ? 15 : 13)) {
          try paging.translate(linearAddress: 0x123, access: access,
            context: disabled, physicalMemory: fixture.memory)
        }
      }
      let translated = DoryX86TranslatedMemory(physicalMemory: fixture.memory,
        pagingUnit: paging, context: disabled)
      #expect(throws: DoryX86MemoryError.pageFault(address: 0x123, errorCode: 9)) {
        try translated.readImplicitSupervisor(at: 0x123, byteCount: 1)
      }
      let implicit = translated.implicitSupervisorMemory()
      #expect(throws: DoryX86MemoryError.pageFault(address: 0x123, errorCode: 9)) {
        try implicit.read(at: 0x123, byteCount: 1)
      }
      #expect(throws: DoryX86MemoryError.pageFault(address: 0x123, errorCode: 11)) {
        try implicit.validateWrite(at: 0x123, byteCount: 1)
      }
      #expect(throws: DoryX86MemoryError.pageFault(address: 0x123, errorCode: 11)) {
        try implicit.write(at: 0x123, bytes: [0xCC])
      }
      // Returning to the explicitly enabled mechanism context still permits it.
      translated.updateContext(enabled)
      #expect(try translated.read(at: 0x123, byteCount: 1) == [0])
    }
  }

  @Test func bothSelectedProfilesFaultInstructionFetchPreciselyWithoutPATPromotion() throws {
    for profile in [DoryX86CPUProfile.compatibleV1, .intelCompatibleV1] {
      #expect(profile.cpuid(leaf: 1).edx & (1 << 16) == 0)
      for shape in Shape.allCases {
        let fixture = try fixture(shape)
        var state = try DoryX86ArchitecturalState(rip: 0x123,
          cs: .init(selector: 0xB, attributes: shape.mode == .long64 ? 0xA0FB : 0xC0FB, limit: .max),
          control: fixture.control)
        let selected = DoryX86PagingContext(state: state, mode: shape.mode, profile: profile)
        #expect(!selected.supportsPAT)
        let before = state
        let leafBefore = try word(fixture.memory, at: fixture.leaf, width: shape.entryWidth)
        #expect(DoryX86Interpreter(profile: profile).step(state: &state, memory: fixture.memory,
          mode: shape.mode, pagingUnit: .init()) == .exception(.init(
            kind: .pageFault, vector: 14, errorCode: 13,
            instructionPointer: 0x123, linearAddress: 0x123)))
        var expected = before
        expected.control.cr2 = 0x123
        #expect(state == expected)
        #expect(try word(fixture.memory, at: fixture.leaf, width: shape.entryWidth) == leafBefore)
      }
    }
  }

  private enum Shape: CaseIterable {
    case legacy4K, legacy4M, pae4K, pae2M, ia32e4K, ia32e2M, ia32e1G
    var entryWidth: Int { self == .legacy4K || self == .legacy4M ? 4 : 8 }
    var mode: DoryX86ExecutionMode {
      self == .ia32e4K || self == .ia32e2M || self == .ia32e1G ? .long64 : .protected32
    }
    var pageSize: UInt64 {
      switch self {
      case .legacy4K, .pae4K, .ia32e4K: 4096
      case .legacy4M: 1 << 22
      case .pae2M, .ia32e2M: 1 << 21
      case .ia32e1G: 1 << 30
      }
    }
  }

  private struct Fixture {
    let shape: Shape
    let memory: DoryX86ByteArrayMemory
    let control: DoryX86ControlState
    let leaf: UInt64
    let physicalBase: UInt64
  }

  private func fixture(_ shape: Shape, pat: Bool = true) throws -> Fixture {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x10000)
    var control = DoryX86ControlState(cr0: 0x8001_0011, cr3: 0x1000)
    let leaf: UInt64
    let base: UInt64
    switch shape {
    case .legacy4K, .pae4K:
      try memory.writeScalar(at: 0x1000, value: 0x3007, byteCount: shape.entryWidth)
      leaf = 0x3000
      base = 0x5000
    case .legacy4M, .pae2M:
      leaf = 0x1000
      base = 0
    case .ia32e4K, .ia32e2M, .ia32e1G:
      try memory.writeScalar(at: 0x1000, value: 0x3007, byteCount: 8)
      if shape != .ia32e1G { try memory.writeScalar(at: 0x3000, value: 0x5007, byteCount: 8) }
      if shape == .ia32e4K { try memory.writeScalar(at: 0x5000, value: 0x7007, byteCount: 8) }
      leaf = shape == .ia32e4K ? 0x7000 : (shape == .ia32e2M ? 0x5000 : 0x3000)
      base = shape == .ia32e4K ? 0x9000 : 0
    }
    if shape.entryWidth == 4 {
      control.cr4 = 1 << 4
    } else {
      control.cr4 = 1 << 5
      if shape.mode == .long64 { control.efer = (1 << 8) | (1 << 10) }
      else {
        control.cr3 = 0xF000
        control.legacyPAEPDPTEs = .init(0x1001)
      }
    }
    let large = shape.pageSize != 4096
    let flags: UInt64 = 7 | (large ? 0x80 : 0) | (pat ? (large ? 0x1000 : 0x80) : 0)
    try memory.writeScalar(at: leaf, value: base | flags, byteCount: shape.entryWidth)
    return .init(shape: shape, memory: memory, control: control, leaf: leaf, physicalBase: base)
  }

  private func context(_ fixture: Fixture, supportsPAT: Bool, cpl: UInt8,
    nxe: Bool = false) -> DoryX86PagingContext {
    var control = fixture.control
    if nxe { control.efer |= 1 << 11 }
    return .init(control: control, rflags: .reset, currentPrivilegeLevel: cpl,
      mode: fixture.shape.mode, supportsPAT: supportsPAT)
  }

  private func faultCode(_ shape: Shape, cpl: UInt8, nxe: Bool,
    access: DoryX86MemoryAccessKind, reserved: Bool) -> UInt32 {
    (reserved ? 9 : 0) | (cpl == 3 ? 4 : 0) | (access == .write ? 2 : 0)
      | (access == .instructionFetch && shape.entryWidth == 8 && nxe ? 16 : 0)
  }

  private func word(_ memory: DoryX86ByteArrayMemory, at address: UInt64, width: Int) throws -> UInt64 {
    try memory.readScalar(at: address, byteCount: width)
  }
}
