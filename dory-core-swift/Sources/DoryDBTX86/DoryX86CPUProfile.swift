import Foundation

public enum DoryX86Feature: String, Codable, CaseIterable, Sendable, Hashable {
  case x87
  case tsc
  case rdtscp
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
  case oneGiBPages
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
  public static let maximumBasicCPUIDLeaf: UInt32 = 0xD
  public static let maximumExtendedCPUIDLeaf: UInt32 = 0x8000_0008

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

  /// Engineering candidate, not a qualified Linux or x86-64-v2 baseline. PAE/PSE/PGE
  /// remain absent pending paging conformance; x86-64 Linux cannot qualify without PAE.
  /// XSAVE/AVX are absent while extended-state save/restore remains unsupported.
  /// A retirement counter is not an invariant-frequency architectural clock.
  public static let compatibleV1 = Self(
    identifier: compatibleV1Identifier,
    features: [
      .x87, .tsc, .msr, .cmpxchg8b, .apic, .sysenter, .cmov, .clflush, .mmx, .fxsave, .sse, .sse2, .cmpxchg16b,
      .syscall, .executeDisable, .oneGiBPages, .longMode, .lahf64,
    ],
    physicalAddressBits: 40,
    linearAddressBits: 48,
    virtualTSCFrequencyHz: 1_000_000_000
  )

  public func supports(_ feature: DoryX86Feature) -> Bool {
    guard features.contains(feature) else { return false }
    switch feature {
    case .rdtscp, .invariantTSC: return supports(.tsc)
    case .osxsave: return supports(.xsave)
    case .sse2: return supports(.sse)
    case .sse3, .ssse3, .sse41, .sse42: return supports(.sse2)
    case .avx: return supports(.xsave) && supports(.sse2) && supports(.fxsave)
    case .avx2: return supports(.avx)
    default: return true
    }
  }

  public func cpuid(
    leaf: UInt32,
    subleaf: UInt32 = 0,
    processorID: UInt32 = 0,
    logicalProcessorCount: UInt16 = 1,
    cr4: UInt64 = 0,
    xcr0: UInt64 = 1
  ) -> DoryX86CPUIDResult {
    // One package, one thread per core, with legacy eight-bit APIC identifiers.
    // Clamp the supplied count consistently in both legacy and extended topology.
    let logicalCount = min(255, max(1, logicalProcessorCount))
    switch (leaf, subleaf) {
    case (0, _):
      // "DoryDoryDory" in architectural EBX, EDX, ECX order.
      return .init(
        eax: Self.maximumBasicCPUIDLeaf,
        ebx: 0x7972_6f44, ecx: 0x7972_6f44, edx: 0x7972_6f44)
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
      // CPUID.1:ECX.OSXSAVE reports guest CR4.OSXSAVE, not a static profile bit.
      if supports(.xsave), cr4 & (1 << 18) != 0 { ecx |= 1 << 27 }
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
        ebx: (supports(.clflush) ? 8 << 8 : 0)
          | UInt32(logicalCount) << 16 | (processorID & 0xFF) << 24,
        ecx: ecx,
        edx: edx
      )
    case (7, 0):
      var ebx: UInt32 = 0
      set(.avx2, bit: 5, in: &ebx)
      return .init(ebx: ebx)
    case (0xD, _):
      guard supports(.xsave) else { return .init() }
      switch subleaf {
      case 0:
        // Standard XSAVE layout: 512-byte legacy area + 64-byte header,
        // followed by the 256-byte YMM_Hi128 component when AVX is enabled.
        let avx = supports(.avx)
        return .init(
          eax: avx ? 0x7 : 0x3,
          ebx: avx && xcr0 & 4 != 0 ? 832 : 576,
          ecx: avx ? 832 : 576)
      case 2 where supports(.avx):
        return .init(eax: 256, ebx: 576)
      default:
        return .init()
      }
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
      return .init(ecx: subleaf & 0xFF, edx: processorID)
    case (0x8000_0000, _):
      return .init(eax: Self.maximumExtendedCPUIDLeaf)
    case (0x8000_0001, _):
      var ecx: UInt32 = 0
      var edx: UInt32 = 0
      set(.lahf64, bit: 0, in: &ecx)
      set(.syscall, bit: 11, in: &edx)
      set(.executeDisable, bit: 20, in: &edx)
      set(.oneGiBPages, bit: 26, in: &edx)
      set(.rdtscp, bit: 27, in: &edx)
      set(.longMode, bit: 29, in: &edx)
      return .init(ecx: ecx, edx: edx)
    case (0x8000_0007, _):
      return .init(edx: supports(.invariantTSC) ? 1 << 8 : 0)
    case (0x8000_0008, _):
      return .init(eax: UInt32(physicalAddressBits) | UInt32(linearAddressBits) << 8)
    default:
      // No Xen/other hypervisor ABI, fabricated cache geometry or crystal/TSC
      // frequency is exposed. The profile's configured TSC rate is not clock proof.
      return .init()
    }
  }

  private func set(_ feature: DoryX86Feature, bit: UInt32, in value: inout UInt32) {
    if supports(feature) { value |= 1 << bit }
  }
}
