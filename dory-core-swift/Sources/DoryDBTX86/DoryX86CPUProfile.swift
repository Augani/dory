import Foundation

public enum DoryX86Feature: String, Codable, CaseIterable, Sendable, Hashable {
  case x87
  case tsc
  case msr
  case cmpxchg8b
  case apic
  case sysenter
  case cmov
  case clflush
  case mmx
  case fxsave
  case sse
  case sse2
  case sse3
  case ssse3
  case sse41
  case sse42
  case popcnt
  case cmpxchg16b
  case syscall
  case executeDisable
  case longMode
  case lahf64
  case invariantTSC
  case xsave
  case osxsave
  case avx
  case avx2
}

public struct DoryX86CPUIDResult: Codable, Sendable, Hashable {
  public let eax: UInt32
  public let ebx: UInt32
  public let ecx: UInt32
  public let edx: UInt32

  public init(eax: UInt32 = 0, ebx: UInt32 = 0, ecx: UInt32 = 0, edx: UInt32 = 0) {
    self.eax = eax
    self.ebx = ebx
    self.ecx = ecx
    self.edx = edx
  }
}

public struct DoryX86CPUProfile: Codable, Sendable, Hashable {
  public static let compatibleV1Identifier = "dory.x86_64.compat-v1"

  public let identifier: String
  public let features: Set<DoryX86Feature>
  public let physicalAddressBits: UInt8
  public let linearAddressBits: UInt8
  public let virtualTSCFrequencyHz: UInt64

  public init(
    identifier: String,
    features: Set<DoryX86Feature>,
    physicalAddressBits: UInt8,
    linearAddressBits: UInt8,
    virtualTSCFrequencyHz: UInt64
  ) {
    self.identifier = identifier
    self.features = features
    self.physicalAddressBits = physicalAddressBits
    self.linearAddressBits = linearAddressBits
    self.virtualTSCFrequencyHz = virtualTSCFrequencyHz
  }

  /// Candidate Linux profile. Features are added only after their interpreter semantics and
  /// conformance tests land; the identifier is frozen at the Phase 4 exit gate, not before it.
  public static let compatibleV1 = Self(
    identifier: compatibleV1Identifier,
    features: [
      .x87, .tsc, .msr, .cmpxchg8b, .apic, .cmov, .clflush, .mmx, .fxsave, .sse, .sse2, .cmpxchg16b,
      .syscall, .executeDisable, .longMode, .invariantTSC,
    ],
    physicalAddressBits: 40,
    linearAddressBits: 48,
    virtualTSCFrequencyHz: 1_000_000_000
  )

  public func supports(_ feature: DoryX86Feature) -> Bool { features.contains(feature) }

  public func cpuid(
    leaf: UInt32,
    subleaf: UInt32 = 0,
    processorID: UInt32 = 0,
    logicalProcessorCount: UInt16 = 1
  ) -> DoryX86CPUIDResult {
    let logicalCount = max(1, logicalProcessorCount)
    switch (leaf, subleaf) {
    case (0, _):
      // "DoryDoryDory" in architectural EBX, EDX, ECX order.
      return .init(eax: 0xD, ebx: 0x7972_6f44, ecx: 0x7972_6f44, edx: 0x7972_6f44)
    case (1, _):
      var ecx: UInt32 = 0
      var edx: UInt32 = 0
      set(.sse3, bit: 0, in: &ecx)
      set(.ssse3, bit: 9, in: &ecx)
      set(.cmpxchg16b, bit: 13, in: &ecx)
      set(.sse41, bit: 19, in: &ecx)
      set(.sse42, bit: 20, in: &ecx)
      set(.popcnt, bit: 23, in: &ecx)
      set(.xsave, bit: 26, in: &ecx)
      set(.osxsave, bit: 27, in: &ecx)
      set(.avx, bit: 28, in: &ecx)
      set(.x87, bit: 0, in: &edx)
      set(.tsc, bit: 4, in: &edx)
      set(.msr, bit: 5, in: &edx)
      set(.cmpxchg8b, bit: 8, in: &edx)
      set(.apic, bit: 9, in: &edx)
      set(.sysenter, bit: 11, in: &edx)
      set(.cmov, bit: 15, in: &edx)
      set(.clflush, bit: 19, in: &edx)
      set(.mmx, bit: 23, in: &edx)
      set(.fxsave, bit: 24, in: &edx)
      set(.sse, bit: 25, in: &edx)
      set(.sse2, bit: 26, in: &edx)
      if logicalCount > 1 { edx |= 1 << 28 }
      return .init(
        eax: 0x0006_0f00,
        ebx: 8 << 8 | UInt32(min(logicalCount, 255)) << 16 | (processorID & 0xFF) << 24,
        ecx: ecx,
        edx: edx
      )
    case (7, 0):
      var ebx: UInt32 = 0
      set(.avx2, bit: 5, in: &ebx)
      return .init(ebx: ebx)
    case (0xD, _):
      guard supports(.xsave) else { return .init() }
      return subleaf == 0 ? .init(eax: supports(.avx) ? 0x7 : 0x3, ebx: 576, ecx: 576) : .init()
    case (0xB, 0):
      return .init(eax: 0, ebx: 1, ecx: 1 << 8, edx: processorID)
    case (0xB, 1):
      let shift = UInt32(16 - (logicalCount - 1).leadingZeroBitCount)
      return .init(
        eax: shift,
        ebx: UInt32(logicalCount),
        ecx: 2 << 8 | 1,
        edx: processorID
      )
    case (0xB, _):
      return .init(edx: processorID)
    case (0x8000_0000, _):
      return .init(eax: 0x8000_0008)
    case (0x8000_0001, _):
      var ecx: UInt32 = 0
      var edx: UInt32 = 0
      set(.lahf64, bit: 0, in: &ecx)
      set(.syscall, bit: 11, in: &edx)
      set(.executeDisable, bit: 20, in: &edx)
      set(.longMode, bit: 29, in: &edx)
      return .init(ecx: ecx, edx: edx)
    case (0x8000_0007, _):
      return .init(edx: supports(.invariantTSC) ? 1 << 8 : 0)
    case (0x8000_0008, _):
      return .init(eax: UInt32(physicalAddressBits) | UInt32(linearAddressBits) << 8)
    default:
      return .init()
    }
  }

  private func set(_ feature: DoryX86Feature, bit: UInt32, in value: inout UInt32) {
    if supports(feature) { value |= 1 << bit }
  }
}
