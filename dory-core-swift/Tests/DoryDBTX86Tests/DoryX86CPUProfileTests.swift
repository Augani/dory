import Foundation
import Testing

@testable import DoryDBTX86

@Suite struct DoryX86CPUProfileTests {
  private func profile(_ features: Set<DoryX86Feature>) -> DoryX86CPUProfile {
    .init(
      identifier: "test.cpuid",
      features: features,
      physicalAddressBits: 40,
      linearAddressBits: 48,
      virtualTSCFrequencyHz: 1_000_000_000)
  }

  @Test func candidateIdentityDoesNotInventAHypervisorABI() {
    let cpu = DoryX86CPUProfile.compatibleV1
    let identity = cpu.cpuid(leaf: 0)
    let bytes = [identity.ebx, identity.edx, identity.ecx].flatMap { word in
      (0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) }
    }
    #expect(String(bytes: bytes, encoding: .ascii) == "DoryDoryDory")
    #expect(identity.eax == DoryX86CPUProfile.maximumBasicCPUIDLeaf)
    #expect(cpu.cpuid(leaf: 0x8000_0000).eax == DoryX86CPUProfile.maximumExtendedCPUIDLeaf)
    #expect(cpu.cpuid(leaf: 1).ecx & (1 << 31) == 0)
    for leaf in UInt32(0x4000_0000)...0x4000_00FF {
      #expect(cpu.cpuid(leaf: leaf) == .init())
    }
  }

  @Test func candidateLeavesLinuxPagingAndExtendedStateGapsVisible() {
    let cpu = DoryX86CPUProfile.compatibleV1
    let standard = cpu.cpuid(leaf: 1)
    let extended = cpu.cpuid(leaf: 0x8000_0001)
    // PSE, PAE and PGE are not unlocked by a boot fixture's feature requirements.
    #expect(standard.edx & ((1 << 3) | (1 << 6) | (1 << 13)) == 0)
    // VMX, SMX, XSAVE, OSXSAVE, AVX, and AMD SVM remain unadvertised.
    #expect(standard.ecx & ((1 << 5) | (1 << 6) | (7 << 26)) == 0)
    #expect(extended.ecx & (1 << 2) == 0)
    #expect(extended.edx & (1 << 27) == 0)
    #expect(cpu.cpuid(leaf: 7).ebx == 0)
    for subleaf in UInt32(0)...63 {
      #expect(cpu.cpuid(leaf: 0xD, subleaf: subleaf, cr4: 1 << 18, xcr0: 7) == .init())
    }
  }

  @Test func unmeasuredTimeAndCacheGeometryRemainUnadvertised() {
    let cpu = DoryX86CPUProfile.compatibleV1
    #expect(!cpu.supports(.invariantTSC))
    #expect(cpu.cpuid(leaf: 0x8000_0007) == .init())
    for leaf: UInt32 in [2, 4, 0x15, 0x16, 0x8000_0005, 0x8000_0006] {
      #expect(cpu.cpuid(leaf: leaf) == .init())
    }
  }

  @Test func unknownLeavesAndStructuredSubleavesReturnDefinedZeros() {
    let cpu = DoryX86CPUProfile.compatibleV1
    for leaf: UInt32 in [3, 5, 6, 8, 9, 0xA, 0xC, 0xE, 0xFFFF_FFFF, 0x8000_0009] {
      #expect(cpu.cpuid(leaf: leaf, subleaf: .max) == .init())
    }
    for subleaf: UInt32 in [1, 2, 255, .max] {
      #expect(cpu.cpuid(leaf: 7, subleaf: subleaf) == .init())
    }
    // Unstructured leaves ignore ECX rather than accidentally disappearing.
    for leaf: UInt32 in [0, 1, 0x8000_0000, 0x8000_0001, 0x8000_0007, 0x8000_0008] {
      #expect(cpu.cpuid(leaf: leaf) == cpu.cpuid(leaf: leaf, subleaf: .max))
    }
  }

  @Test func topologyHasOneThreadPerCoreAndConsistentCountBounds() {
    let cpu = DoryX86CPUProfile.compatibleV1
    for (requested, count, shift): (UInt16, UInt32, UInt32) in [
      (0, 1, 0), (1, 1, 0), (2, 2, 1), (3, 3, 2), (4, 4, 2),
      (255, 255, 8), (256, 255, 8), (.max, 255, 8),
    ] {
      let legacy = cpu.cpuid(leaf: 1, processorID: 3, logicalProcessorCount: requested)
      #expect((legacy.ebx >> 16) & 0xFF == count)
      #expect((legacy.ebx >> 24) == 3)
      #expect((legacy.edx & (1 << 28) != 0) == (count > 1))
      #expect(cpu.cpuid(leaf: 0xB, processorID: 3, logicalProcessorCount: requested)
        == .init(eax: 0, ebx: 1, ecx: 1 << 8, edx: 3))
      #expect(cpu.cpuid(leaf: 0xB, subleaf: 1, processorID: 3, logicalProcessorCount: requested)
        == .init(eax: shift, ebx: count, ecx: 2 << 8 | 1, edx: 3))
    }
    for subleaf: UInt32 in [2, 3, 255, 256, .max] {
      #expect(cpu.cpuid(leaf: 0xB, subleaf: subleaf, processorID: 7)
        == .init(ecx: subleaf & 0xFF, edx: 7))
    }
  }

  @Test func featureDependenciesDoNotAdvertiseOrphanedExtensions() {
    let cpu = profile([.avx2, .avx, .osxsave, .sse2, .sse42, .rdtscp, .invariantTSC])
    for feature: DoryX86Feature in [.avx2, .avx, .osxsave, .sse2, .sse42, .rdtscp, .invariantTSC] {
      #expect(!cpu.supports(feature))
    }
    #expect(cpu.cpuid(leaf: 1) == .init(eax: 0x0006_0f00, ebx: 1 << 16))
    #expect(cpu.cpuid(leaf: 7) == .init())
    #expect(cpu.cpuid(leaf: 0x8000_0001) == .init())
    #expect(cpu.cpuid(leaf: 0x8000_0007) == .init())
  }

  @Test func osxsaveReflectsGuestControlStateRatherThanRequestedFeature() {
    let cpu = profile([.xsave])
    #expect(cpu.cpuid(leaf: 1).ecx & (1 << 26) != 0)
    #expect(cpu.cpuid(leaf: 1).ecx & (1 << 27) == 0)
    #expect(cpu.cpuid(leaf: 1, cr4: 1 << 18).ecx & (1 << 27) != 0)
    #expect(profile([.osxsave]).cpuid(leaf: 1, cr4: 1 << 18).ecx & (3 << 26) == 0)
  }

  @Test func extendedStateSizesFollowEnabledComponents() {
    let cpu = profile([.x87, .fxsave, .sse, .sse2, .xsave, .avx, .avx2])
    #expect(cpu.cpuid(leaf: 1).ecx & (1 << 28) != 0)
    #expect(cpu.cpuid(leaf: 7).ebx == 1 << 5)
    #expect(cpu.cpuid(leaf: 0xD, xcr0: 1) == .init(eax: 7, ebx: 576, ecx: 832))
    #expect(cpu.cpuid(leaf: 0xD, xcr0: 3) == .init(eax: 7, ebx: 576, ecx: 832))
    #expect(cpu.cpuid(leaf: 0xD, xcr0: 7) == .init(eax: 7, ebx: 832, ecx: 832))
    #expect(cpu.cpuid(leaf: 0xD, subleaf: 2) == .init(eax: 256, ebx: 576))
    for subleaf: UInt32 in [1, 3, 63, .max] {
      #expect(cpu.cpuid(leaf: 0xD, subleaf: subleaf) == .init())
    }
    let legacy = profile([.xsave])
    #expect(legacy.cpuid(leaf: 0xD, xcr0: 7) == .init(eax: 3, ebx: 576, ecx: 576))
    #expect(legacy.cpuid(leaf: 0xD, subleaf: 2) == .init())
  }

  @Test func optionalTimingFeaturesRequireTSCAndRoundTripStably() throws {
    let cpu = profile([.tsc, .rdtscp, .invariantTSC])
    #expect(cpu.cpuid(leaf: 0x8000_0001).edx == 1 << 27)
    #expect(cpu.cpuid(leaf: 0x8000_0007).edx == 1 << 8)
    #expect(try JSONDecoder().decode(DoryX86CPUProfile.self, from: JSONEncoder().encode(cpu)) == cpu)
  }
}
