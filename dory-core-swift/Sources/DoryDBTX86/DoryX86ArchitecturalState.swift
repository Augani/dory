import DoryExecutionContracts
import Foundation

public enum DoryX86StateError: Error, Sendable, Equatable, CustomStringConvertible {
  case invalidRFLAGS(UInt64)
  case invalidRegisterPayload(expected: Int, actual: Int)
  case invalidX87RegisterCount(Int)
  case invalidX87Opcode(UInt16)
  case invalidVectorRegisterCount(Int)
  case invalidXCR0(UInt64)
  case invalidPhysicalAddressBits(UInt8)
  case missingLegacyPAEPDPTEs
  case invalidLegacyPAEPDPTE(index: Int, value: UInt64)
  case noncanonicalAddress(UInt64)

  public var description: String {
    switch self {
    case .invalidRFLAGS(let value):
      "x86 RFLAGS contains reserved or unsupported bits: 0x\(String(value, radix: 16))"
    case .invalidRegisterPayload(let expected, let actual):
      "x86 register payload contains \(actual) bytes; expected \(expected)"
    case .invalidX87RegisterCount(let count):
      "x86 state contains \(count) x87 registers; expected 8"
    case .invalidX87Opcode(let value):
      "x87 last opcode exceeds 11 bits: 0x\(String(value, radix: 16))"
    case .invalidVectorRegisterCount(let count):
      "x86 state contains \(count) vector registers; expected 16"
    case .invalidXCR0(let value):
      "x86 XCR0 contains an invalid state-component mask: 0x\(String(value, radix: 16))"
    case .invalidPhysicalAddressBits(let value):
      "x86 physical address width is \(value); expected 32 through 52 bits"
    case .missingLegacyPAEPDPTEs:
      "Active legacy PAE paging requires the four latched PDPTEs"
    case .invalidLegacyPAEPDPTE(let index, let value):
      "Legacy PAE PDPTE\(index) contains reserved bits: 0x\(String(value, radix: 16))"
    case .noncanonicalAddress(let value):
      "x86 address is not canonical: 0x\(String(value, radix: 16))"
    }
  }
}

public enum DoryX86GeneralRegister: String, Codable, CaseIterable, Sendable, Hashable {
  case rax, rcx, rdx, rbx, rsp, rbp, rsi, rdi
  case r8, r9, r10, r11, r12, r13, r14, r15
}

public struct DoryX86GeneralRegisters: Codable, Sendable, Hashable {
  public var rax: UInt64
  public var rcx: UInt64
  public var rdx: UInt64
  public var rbx: UInt64
  public var rsp: UInt64
  public var rbp: UInt64
  public var rsi: UInt64
  public var rdi: UInt64
  public var r8: UInt64
  public var r9: UInt64
  public var r10: UInt64
  public var r11: UInt64
  public var r12: UInt64
  public var r13: UInt64
  public var r14: UInt64
  public var r15: UInt64

  public init(
    rax: UInt64 = 0, rcx: UInt64 = 0, rdx: UInt64 = 0, rbx: UInt64 = 0,
    rsp: UInt64 = 0, rbp: UInt64 = 0, rsi: UInt64 = 0, rdi: UInt64 = 0,
    r8: UInt64 = 0, r9: UInt64 = 0, r10: UInt64 = 0, r11: UInt64 = 0,
    r12: UInt64 = 0, r13: UInt64 = 0, r14: UInt64 = 0, r15: UInt64 = 0
  ) {
    self.rax = rax
    self.rcx = rcx
    self.rdx = rdx
    self.rbx = rbx
    self.rsp = rsp
    self.rbp = rbp
    self.rsi = rsi
    self.rdi = rdi
    self.r8 = r8
    self.r9 = r9
    self.r10 = r10
    self.r11 = r11
    self.r12 = r12
    self.r13 = r13
    self.r14 = r14
    self.r15 = r15
  }

  public subscript(_ register: DoryX86GeneralRegister) -> UInt64 {
    get {
      switch register {
      case .rax: rax
      case .rcx: rcx
      case .rdx: rdx
      case .rbx: rbx
      case .rsp: rsp
      case .rbp: rbp
      case .rsi: rsi
      case .rdi: rdi
      case .r8: r8
      case .r9: r9
      case .r10: r10
      case .r11: r11
      case .r12: r12
      case .r13: r13
      case .r14: r14
      case .r15: r15
      }
    }
    set {
      switch register {
      case .rax: rax = newValue
      case .rcx: rcx = newValue
      case .rdx: rdx = newValue
      case .rbx: rbx = newValue
      case .rsp: rsp = newValue
      case .rbp: rbp = newValue
      case .rsi: rsi = newValue
      case .rdi: rdi = newValue
      case .r8: r8 = newValue
      case .r9: r9 = newValue
      case .r10: r10 = newValue
      case .r11: r11 = newValue
      case .r12: r12 = newValue
      case .r13: r13 = newValue
      case .r14: r14 = newValue
      case .r15: r15 = newValue
      }
    }
  }
}

public struct DoryX86RFLAGS: OptionSet, Codable, Sendable, Hashable {
  public let rawValue: UInt64

  public init(rawValue: UInt64) { self.rawValue = rawValue }

  public static let carry = Self(rawValue: 1 << 0)
  public static let reservedOne = Self(rawValue: 1 << 1)
  public static let parity = Self(rawValue: 1 << 2)
  public static let auxiliaryCarry = Self(rawValue: 1 << 4)
  public static let zero = Self(rawValue: 1 << 6)
  public static let sign = Self(rawValue: 1 << 7)
  public static let trap = Self(rawValue: 1 << 8)
  public static let interruptEnable = Self(rawValue: 1 << 9)
  public static let direction = Self(rawValue: 1 << 10)
  public static let overflow = Self(rawValue: 1 << 11)
  public static let nestedTask = Self(rawValue: 1 << 14)
  public static let resume = Self(rawValue: 1 << 16)
  public static let virtual8086 = Self(rawValue: 1 << 17)
  public static let alignmentCheck = Self(rawValue: 1 << 18)
  public static let virtualInterrupt = Self(rawValue: 1 << 19)
  public static let virtualInterruptPending = Self(rawValue: 1 << 20)
  public static let identification = Self(rawValue: 1 << 21)

  public static let reset: Self = [.reservedOne]
  public static let architecturallyWritableMask: UInt64 = 0x0000_0000_003f_7fd7

  public func validated() throws -> Self {
    guard contains(.reservedOne), rawValue & ~Self.architecturallyWritableMask == 0 else {
      throw DoryX86StateError.invalidRFLAGS(rawValue)
    }
    return self
  }
}

public struct DoryX86SegmentState: Codable, Sendable, Hashable {
  public var selector: UInt16
  public var attributes: UInt16
  public var limit: UInt32
  public var base: UInt64

  public init(selector: UInt16 = 0, attributes: UInt16 = 0, limit: UInt32 = 0, base: UInt64 = 0) {
    self.selector = selector
    self.attributes = attributes
    self.limit = limit
    self.base = base
  }
}

public struct DoryX86DescriptorTableState: Codable, Sendable, Hashable {
  public var limit: UInt16
  public var base: UInt64

  public init(limit: UInt16 = 0, base: UInt64 = 0) {
    self.limit = limit
    self.base = base
  }
}

/// The four processor-internal PDPTE registers used by legacy PAE paging. Keeping a fixed
/// shape prevents a truncated snapshot from silently supplying fewer than four entries.
public struct DoryX86PAEPDPTEs: Codable, Sendable, Hashable {
  public let pdpte0: UInt64
  public let pdpte1: UInt64
  public let pdpte2: UInt64
  public let pdpte3: UInt64

  public init(_ pdpte0: UInt64 = 0, _ pdpte1: UInt64 = 0,
    _ pdpte2: UInt64 = 0, _ pdpte3: UInt64 = 0) {
    self.pdpte0 = pdpte0
    self.pdpte1 = pdpte1
    self.pdpte2 = pdpte2
    self.pdpte3 = pdpte3
  }

  public subscript(index: Int) -> UInt64 {
    switch index {
    case 0: pdpte0
    case 1: pdpte1
    case 2: pdpte2
    case 3: pdpte3
    default: preconditionFailure("A PAE PDPTE selector has two bits")
    }
  }

  public func validate(physicalAddressBits: UInt8) throws {
    guard (32...52).contains(physicalAddressBits) else {
      throw DoryX86StateError.invalidPhysicalAddressBits(physicalAddressBits)
    }
    // Intel SDM 092, Vol. 3A §5.4.1, Table 5-8: NX is reserved here even with NXE.
    let reservedMask = (UInt64.max << physicalAddressBits) | 0x1e6
    for index in 0..<4 {
      let value = self[index]
      if value & 1 != 0, value & reservedMask != 0 {
        throw DoryX86StateError.invalidLegacyPAEPDPTE(index: index, value: value)
      }
    }
  }
}

public struct DoryX86ControlState: Codable, Sendable, Hashable {
  public var cr0: UInt64
  public var cr2: UInt64
  public var cr3: UInt64
  public var cr4: UInt64
  public var cr8: UInt64
  public var efer: UInt64
  public var xcr0: UInt64
  /// Nil for reset/old non-PAE snapshots. Active legacy PAE must never rebuild this from RAM.
  public var legacyPAEPDPTEs: DoryX86PAEPDPTEs?

  public init(
    cr0: UInt64 = 0x6000_0010,
    cr2: UInt64 = 0,
    cr3: UInt64 = 0,
    cr4: UInt64 = 0,
    cr8: UInt64 = 0,
    efer: UInt64 = 0,
    xcr0: UInt64 = 1,
    legacyPAEPDPTEs: DoryX86PAEPDPTEs? = nil
  ) {
    self.cr0 = cr0
    self.cr2 = cr2
    self.cr3 = cr3
    self.cr4 = cr4
    self.cr8 = cr8
    self.efer = efer
    self.xcr0 = xcr0
    self.legacyPAEPDPTEs = legacyPAEPDPTEs
  }

  public var isLegacyPAEPagingActive: Bool {
    cr0 & (1 << 31) != 0 && cr4 & (1 << 5) != 0 && efer & (1 << 10) == 0
  }

  /// Snapshot construction uses the architectural maximum; dispatch applies its CPU's width.
  public func validateLegacyPAEPDPTEs(physicalAddressBits: UInt8 = 52) throws {
    guard (32...52).contains(physicalAddressBits) else {
      throw DoryX86StateError.invalidPhysicalAddressBits(physicalAddressBits)
    }
    guard isLegacyPAEPagingActive else { return }
    guard let legacyPAEPDPTEs else { throw DoryX86StateError.missingLegacyPAEPDPTEs }
    try legacyPAEPDPTEs.validate(physicalAddressBits: physicalAddressBits)
  }
}

public struct DoryX86DebugState: Codable, Sendable, Hashable {
  public var dr0: UInt64
  public var dr1: UInt64
  public var dr2: UInt64
  public var dr3: UInt64
  public var dr6: UInt64
  public var dr7: UInt64

  public init(
    dr0: UInt64 = 0, dr1: UInt64 = 0, dr2: UInt64 = 0, dr3: UInt64 = 0,
    dr6: UInt64 = 0xffff_0ff0, dr7: UInt64 = 0x400
  ) {
    self.dr0 = dr0
    self.dr1 = dr1
    self.dr2 = dr2
    self.dr3 = dr3
    self.dr6 = dr6
    self.dr7 = dr7
  }
}

public struct DoryX86ModelSpecificRegisterState: Codable, Sendable, Hashable {
  public var apicBase: UInt64
  public var systemEnterCS: UInt64
  public var systemEnterStackPointer: UInt64
  public var systemEnterInstructionPointer: UInt64
  public var pageAttributeTable: UInt64
  public var star: UInt64
  public var longStar: UInt64
  public var compatibilityStar: UInt64
  public var syscallFlagMask: UInt64
  public var fsBase: UInt64
  public var gsBase: UInt64
  public var kernelGSBase: UInt64
  /// Writable high DWORD of IA32_BIOS_SIGN_ID; no microcode update is installed.
  public var biosUpdateSignature: UInt32

  public init(
    apicBase: UInt64 = 0xfee0_0900,
    systemEnterCS: UInt64 = 0,
    systemEnterStackPointer: UInt64 = 0,
    systemEnterInstructionPointer: UInt64 = 0,
    pageAttributeTable: UInt64 = 0x0007_0406_0007_0406,
    star: UInt64 = 0,
    longStar: UInt64 = 0,
    compatibilityStar: UInt64 = 0,
    syscallFlagMask: UInt64 = 0,
    fsBase: UInt64 = 0,
    gsBase: UInt64 = 0,
    kernelGSBase: UInt64 = 0,
    biosUpdateSignature: UInt32 = 0
  ) {
    self.apicBase = apicBase
    self.systemEnterCS = systemEnterCS
    self.systemEnterStackPointer = systemEnterStackPointer
    self.systemEnterInstructionPointer = systemEnterInstructionPointer
    self.pageAttributeTable = pageAttributeTable
    self.star = star
    self.longStar = longStar
    self.compatibilityStar = compatibilityStar
    self.syscallFlagMask = syscallFlagMask
    self.fsBase = fsBase
    self.gsBase = gsBase
    self.kernelGSBase = kernelGSBase
    self.biosUpdateSignature = biosUpdateSignature
  }

  private enum CodingKeys: String, CodingKey {
    case apicBase, systemEnterCS, systemEnterStackPointer, systemEnterInstructionPointer
    case pageAttributeTable, star, longStar, compatibilityStar, syscallFlagMask
    case fsBase, gsBase, kernelGSBase, biosUpdateSignature
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      apicBase: values.decode(UInt64.self, forKey: .apicBase),
      systemEnterCS: values.decode(UInt64.self, forKey: .systemEnterCS),
      systemEnterStackPointer: values.decode(UInt64.self, forKey: .systemEnterStackPointer),
      systemEnterInstructionPointer: values.decode(UInt64.self, forKey: .systemEnterInstructionPointer),
      pageAttributeTable: values.decode(UInt64.self, forKey: .pageAttributeTable),
      star: values.decode(UInt64.self, forKey: .star),
      longStar: values.decode(UInt64.self, forKey: .longStar),
      compatibilityStar: values.decode(UInt64.self, forKey: .compatibilityStar),
      syscallFlagMask: values.decode(UInt64.self, forKey: .syscallFlagMask),
      fsBase: values.decode(UInt64.self, forKey: .fsBase),
      gsBase: values.decode(UInt64.self, forKey: .gsBase),
      kernelGSBase: values.decode(UInt64.self, forKey: .kernelGSBase),
      biosUpdateSignature: values.decodeIfPresent(UInt32.self, forKey: .biosUpdateSignature) ?? 0)
  }
}

/// Fixed-width byte payload used for x87 (10-byte) and YMM (32-byte) state. Arrays are validated
/// on every construction and decode so malformed snapshots cannot alter architectural shape.
public struct DoryX86RegisterBytes: Codable, Sendable, Hashable {
  public let bytes: [UInt8]

  public init(bytes: [UInt8], expectedByteCount: Int) throws {
    guard bytes.count == expectedByteCount else {
      throw DoryX86StateError.invalidRegisterPayload(
        expected: expectedByteCount,
        actual: bytes.count
      )
    }
    self.bytes = bytes
  }

  public static func x87Zero() -> Self {
    try! Self(bytes: .init(repeating: 0, count: 10), expectedByteCount: 10)
  }
  public static func ymmZero() -> Self {
    try! Self(bytes: .init(repeating: 0, count: 32), expectedByteCount: 32)
  }
}

public struct DoryX86FloatingPointState: Codable, Sendable, Hashable {
  public var x87: [DoryX86RegisterBytes]
  public var ymm: [DoryX86RegisterBytes]
  public var x87ControlWord: UInt16
  public var x87StatusWord: UInt16
  public var x87TagWord: UInt16
  public var x87InstructionPointer: UInt64
  public var x87InstructionSelector: UInt16
  public var x87DataPointer: UInt64
  public var x87DataSelector: UInt16
  public var x87Opcode: UInt16
  public var mxcsr: UInt32
  public var mxcsrMask: UInt32

  public init(
    x87: [DoryX86RegisterBytes] = .init(repeating: .x87Zero(), count: 8),
    ymm: [DoryX86RegisterBytes] = .init(repeating: .ymmZero(), count: 16),
    x87ControlWord: UInt16 = 0x037f,
    x87StatusWord: UInt16 = 0,
    x87TagWord: UInt16 = 0xffff,
    mxcsr: UInt32 = 0x1f80,
    mxcsrMask: UInt32 = 0xffff,
    x87InstructionPointer: UInt64 = 0,
    x87InstructionSelector: UInt16 = 0,
    x87DataPointer: UInt64 = 0,
    x87DataSelector: UInt16 = 0,
    x87Opcode: UInt16 = 0
  ) throws {
    guard x87.count == 8 else { throw DoryX86StateError.invalidX87RegisterCount(x87.count) }
    guard x87Opcode <= 0x7ff else { throw DoryX86StateError.invalidX87Opcode(x87Opcode) }
    guard ymm.count == 16 else { throw DoryX86StateError.invalidVectorRegisterCount(ymm.count) }
    for register in x87 {
      guard register.bytes.count == 10 else {
        throw DoryX86StateError.invalidRegisterPayload(expected: 10, actual: register.bytes.count)
      }
    }
    for register in ymm {
      guard register.bytes.count == 32 else {
        throw DoryX86StateError.invalidRegisterPayload(expected: 32, actual: register.bytes.count)
      }
    }
    self.x87 = x87
    self.ymm = ymm
    self.x87ControlWord = x87ControlWord
    self.x87StatusWord = x87StatusWord
    self.x87TagWord = x87TagWord
    self.x87InstructionPointer = x87InstructionPointer
    self.x87InstructionSelector = x87InstructionSelector
    self.x87DataPointer = x87DataPointer
    self.x87DataSelector = x87DataSelector
    self.x87Opcode = x87Opcode
    self.mxcsr = mxcsr
    self.mxcsrMask = mxcsrMask
  }

  private enum CodingKeys: String, CodingKey {
    case x87, ymm, x87ControlWord, x87StatusWord, x87TagWord, mxcsr, mxcsrMask
    case x87InstructionPointer, x87InstructionSelector, x87DataPointer, x87DataSelector, x87Opcode
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      x87: values.decode([DoryX86RegisterBytes].self, forKey: .x87),
      ymm: values.decode([DoryX86RegisterBytes].self, forKey: .ymm),
      x87ControlWord: values.decode(UInt16.self, forKey: .x87ControlWord),
      x87StatusWord: values.decode(UInt16.self, forKey: .x87StatusWord),
      x87TagWord: values.decode(UInt16.self, forKey: .x87TagWord),
      mxcsr: values.decode(UInt32.self, forKey: .mxcsr),
      mxcsrMask: values.decode(UInt32.self, forKey: .mxcsrMask),
      x87InstructionPointer: values.decodeIfPresent(UInt64.self, forKey: .x87InstructionPointer) ?? 0,
      x87InstructionSelector: values.decodeIfPresent(UInt16.self, forKey: .x87InstructionSelector) ?? 0,
      x87DataPointer: values.decodeIfPresent(UInt64.self, forKey: .x87DataPointer) ?? 0,
      x87DataSelector: values.decodeIfPresent(UInt16.self, forKey: .x87DataSelector) ?? 0,
      x87Opcode: values.decodeIfPresent(UInt16.self, forKey: .x87Opcode) ?? 0
    )
  }

  public func encode(to encoder: Encoder) throws {
    guard x87Opcode <= 0x7ff else { throw DoryX86StateError.invalidX87Opcode(x87Opcode) }
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(x87, forKey: .x87)
    try values.encode(ymm, forKey: .ymm)
    try values.encode(x87ControlWord, forKey: .x87ControlWord)
    try values.encode(x87StatusWord, forKey: .x87StatusWord)
    try values.encode(x87TagWord, forKey: .x87TagWord)
    try values.encode(mxcsr, forKey: .mxcsr)
    try values.encode(mxcsrMask, forKey: .mxcsrMask)
    // Keep the reset snapshot shape compatible with snapshots predating these
    // registers; missing fields decode to the architectural reset value.
    if x87InstructionPointer != 0 { try values.encode(x87InstructionPointer, forKey: .x87InstructionPointer) }
    if x87InstructionSelector != 0 { try values.encode(x87InstructionSelector, forKey: .x87InstructionSelector) }
    if x87DataPointer != 0 { try values.encode(x87DataPointer, forKey: .x87DataPointer) }
    if x87DataSelector != 0 { try values.encode(x87DataSelector, forKey: .x87DataSelector) }
    if x87Opcode != 0 { try values.encode(x87Opcode, forKey: .x87Opcode) }
  }
}

/// The one-instruction external-interrupt inhibition established by STI or an
/// SS load. The source remains explicit because MOV/POP SS also suppress debug
/// traps on real processors, even though Dory does not model that debug engine.
public enum DoryX86InterruptShadow: String, Codable, Sendable, Hashable {
  case sti
  case movSS
}

public struct DoryX86ArchitecturalState: Codable, Sendable, Hashable {
  public var registers: DoryX86GeneralRegisters
  public var rip: UInt64
  public var rflags: DoryX86RFLAGS
  public var cs: DoryX86SegmentState
  public var ds: DoryX86SegmentState
  public var es: DoryX86SegmentState
  public var fs: DoryX86SegmentState
  public var gs: DoryX86SegmentState
  public var ss: DoryX86SegmentState
  public var tr: DoryX86SegmentState
  public var ldtr: DoryX86SegmentState
  public var gdtr: DoryX86DescriptorTableState
  public var idtr: DoryX86DescriptorTableState
  public var control: DoryX86ControlState
  public var debug: DoryX86DebugState
  public var modelSpecific: DoryX86ModelSpecificRegisterState
  public var floatingPoint: DoryX86FloatingPointState
  /// Inhibits recognition of external maskable interrupts until one following
  /// instruction retires or another event is accepted for delivery.
  public var interruptShadow: DoryX86InterruptShadow?
  /// True from recognition of an NMI until the next attempted IRET. This is
  /// processor-internal interruptibility state, rather than an RFLAGS bit.
  public var nmiBlocked: Bool
  public var tsc: UInt64
  public var tscAux: UInt32

  public init(
    registers: DoryX86GeneralRegisters = .init(),
    rip: UInt64 = 0xfff0,
    rflags: DoryX86RFLAGS = .reset,
    cs: DoryX86SegmentState = .init(
      selector: 0xf000, attributes: 0x009b, limit: 0xffff, base: 0xffff_0000),
    ds: DoryX86SegmentState = .init(attributes: 0x0093, limit: 0xffff),
    es: DoryX86SegmentState = .init(attributes: 0x0093, limit: 0xffff),
    fs: DoryX86SegmentState = .init(attributes: 0x0093, limit: 0xffff),
    gs: DoryX86SegmentState = .init(attributes: 0x0093, limit: 0xffff),
    ss: DoryX86SegmentState = .init(attributes: 0x0093, limit: 0xffff),
    tr: DoryX86SegmentState = .init(),
    ldtr: DoryX86SegmentState = .init(),
    gdtr: DoryX86DescriptorTableState = .init(),
    idtr: DoryX86DescriptorTableState = .init(),
    control: DoryX86ControlState = .init(),
    debug: DoryX86DebugState = .init(),
    modelSpecific: DoryX86ModelSpecificRegisterState = .init(),
    floatingPoint: DoryX86FloatingPointState = try! .init(),
    interruptShadow: DoryX86InterruptShadow? = nil,
    nmiBlocked: Bool = false,
    tsc: UInt64 = 0,
    tscAux: UInt32 = 0
  ) throws {
    _ = try rflags.validated()
    guard Self.isCanonical(rip) || control.efer & (1 << 10) == 0 else {
      throw DoryX86StateError.noncanonicalAddress(rip)
    }
    // Intel SDM Vol. 1 §13.3: x87 state is mandatory, and AVX state cannot
    // be enabled unless SSE state is enabled. Match the XSETBV publication
    // boundary so a restored snapshot cannot manufacture unreachable XSTATE.
    guard control.xcr0 & ~0x7 == 0, control.xcr0 & 1 == 1,
      control.xcr0 & 4 == 0 || control.xcr0 & 2 != 0
    else {
      throw DoryX86StateError.invalidXCR0(control.xcr0)
    }
    try control.validateLegacyPAEPDPTEs()
    self.registers = registers
    self.rip = rip
    self.rflags = rflags
    self.cs = cs
    self.ds = ds
    self.es = es
    self.fs = fs
    self.gs = gs
    self.ss = ss
    self.tr = tr
    self.ldtr = ldtr
    self.gdtr = gdtr
    self.idtr = idtr
    self.control = control
    self.debug = debug
    self.modelSpecific = modelSpecific
    self.floatingPoint = floatingPoint
    self.interruptShadow = interruptShadow
    self.nmiBlocked = nmiBlocked
    self.tsc = tsc
    self.tscAux = tscAux
  }

  public static func reset() -> Self { try! Self() }

  private enum CodingKeys: String, CodingKey {
    case registers, rip, rflags, cs, ds, es, fs, gs, ss, tr, ldtr, gdtr, idtr
    case control, debug, modelSpecific, floatingPoint, interruptShadow, nmiBlocked, tsc, tscAux
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      registers: values.decode(DoryX86GeneralRegisters.self, forKey: .registers),
      rip: values.decode(UInt64.self, forKey: .rip),
      rflags: values.decode(DoryX86RFLAGS.self, forKey: .rflags),
      cs: values.decode(DoryX86SegmentState.self, forKey: .cs),
      ds: values.decode(DoryX86SegmentState.self, forKey: .ds),
      es: values.decode(DoryX86SegmentState.self, forKey: .es),
      fs: values.decode(DoryX86SegmentState.self, forKey: .fs),
      gs: values.decode(DoryX86SegmentState.self, forKey: .gs),
      ss: values.decode(DoryX86SegmentState.self, forKey: .ss),
      tr: values.decode(DoryX86SegmentState.self, forKey: .tr),
      ldtr: values.decode(DoryX86SegmentState.self, forKey: .ldtr),
      gdtr: values.decode(DoryX86DescriptorTableState.self, forKey: .gdtr),
      idtr: values.decode(DoryX86DescriptorTableState.self, forKey: .idtr),
      control: values.decode(DoryX86ControlState.self, forKey: .control),
      debug: values.decode(DoryX86DebugState.self, forKey: .debug),
      modelSpecific: values.decode(DoryX86ModelSpecificRegisterState.self, forKey: .modelSpecific),
      floatingPoint: values.decode(DoryX86FloatingPointState.self, forKey: .floatingPoint),
      interruptShadow: values.decodeIfPresent(
        DoryX86InterruptShadow.self, forKey: .interruptShadow),
      nmiBlocked: values.decodeIfPresent(Bool.self, forKey: .nmiBlocked) ?? false,
      tsc: values.decode(UInt64.self, forKey: .tsc),
      tscAux: values.decode(UInt32.self, forKey: .tscAux)
    )
  }

  public static func isCanonical(_ address: UInt64, linearAddressBits: UInt8 = 48) -> Bool {
    guard (1...63).contains(linearAddressBits) else { return false }
    let upperMask = UInt64.max << linearAddressBits
    let sign = UInt64(1) << (linearAddressBits - 1)
    return address & sign == 0 ? address & upperMask == 0 : address & upperMask == upperMask
  }
}
