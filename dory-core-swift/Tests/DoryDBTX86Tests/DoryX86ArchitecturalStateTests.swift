import Foundation
import Testing

@testable import DoryDBTX86

@Suite struct DoryX86ArchitecturalStateTests {
  @Test func resetStateHasArchitecturalShapeAndStableRoundTrip() throws {
    let state = DoryX86ArchitecturalState.reset()
    #expect(state.rip == 0xfff0)
    #expect(state.cs.selector == 0xf000)
    #expect(state.cs.base == 0xffff_0000)
    #expect(state.control.cr0 == 0x6000_0010)
    #expect(state.rflags == .reset)
    #expect(state.floatingPoint.x87.count == 8)
    #expect(state.floatingPoint.ymm.count == 16)

    let encoded = try JSONEncoder().encode(state)
    let decoded = try JSONDecoder().decode(DoryX86ArchitecturalState.self, from: encoded)
    #expect(decoded == state)
  }

  @Test func registerFileUsesArchitecturalEncodingOrder() {
    var registers = DoryX86GeneralRegisters()
    for (index, register) in DoryX86GeneralRegister.allCases.enumerated() {
      registers[register] = UInt64(index + 1)
    }
    for (index, register) in DoryX86GeneralRegister.allCases.enumerated() {
      #expect(registers[register] == UInt64(index + 1))
    }
  }

  @Test func malformedFlagsAndExtendedStateFailClosed() throws {
    #expect(throws: DoryX86StateError.invalidRFLAGS(0)) {
      try DoryX86ArchitecturalState(rflags: [])
    }
    #expect(throws: DoryX86StateError.invalidRegisterPayload(expected: 10, actual: 9)) {
      try DoryX86RegisterBytes(bytes: .init(repeating: 0, count: 9), expectedByteCount: 10)
    }
    #expect(throws: DoryX86StateError.invalidX87RegisterCount(7)) {
      try DoryX86FloatingPointState(x87: .init(repeating: .x87Zero(), count: 7))
    }

    let valid = try JSONEncoder().encode(DoryX86ArchitecturalState.reset())
    var object = try #require(
      JSONSerialization.jsonObject(with: valid) as? [String: Any]
    )
    object["rflags"] = 0
    let invalid = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: DoryX86StateError.invalidRFLAGS(0)) {
      try JSONDecoder().decode(DoryX86ArchitecturalState.self, from: invalid)
    }
  }

  @Test func longModeRejectsNoncanonicalInstructionPointers() throws {
    var control = DoryX86ControlState()
    control.efer = 1 << 10
    #expect(throws: DoryX86StateError.noncanonicalAddress(0x0000_8000_0000_0000)) {
      try DoryX86ArchitecturalState(rip: 0x0000_8000_0000_0000, control: control)
    }
    #expect(DoryX86ArchitecturalState.isCanonical(0xffff_8000_0000_0000))
  }

  @Test func compatibleProfileIsDenyByDefaultAndCPUIDIsSelfConsistent() {
    let profile = DoryX86CPUProfile.compatibleV1
    #expect(profile.identifier == "dory.x86_64.compat-v1")
    #expect(profile.supports(.longMode))
    #expect(profile.supports(.x87))
    #expect(profile.supports(.mmx))
    #expect(profile.supports(.fxsave))
    #expect(profile.supports(.sse))
    #expect(profile.supports(.sse2))
    #expect(!profile.supports(.sse3))
    #expect(!profile.supports(.sse42))
    #expect(profile.supports(.syscall))
    #expect(profile.supports(.msr))
    #expect(profile.supports(.tsc))
    #expect(profile.supports(.cmov))
    #expect(profile.supports(.cmpxchg8b))
    #expect(profile.supports(.cmpxchg16b))
    #expect(profile.supports(.apic))
    #expect(!profile.supports(.avx))
    #expect(!profile.supports(.avx2))
    #expect(profile.cpuid(leaf: 0).eax == 0xD)
    #expect(profile.cpuid(leaf: 1).ecx & (1 << 28) == 0)
    #expect(profile.cpuid(leaf: 1).edx & (1 << 0) != 0)
    #expect(profile.cpuid(leaf: 1).edx & (1 << 23) != 0)
    #expect(profile.cpuid(leaf: 1).edx & (1 << 24) != 0)
    #expect(profile.cpuid(leaf: 1).edx & (1 << 25) != 0)
    #expect(profile.cpuid(leaf: 1).edx & (1 << 26) != 0)
    #expect(profile.cpuid(leaf: 7).ebx & (1 << 5) == 0)
    #expect(profile.cpuid(leaf: 0x8000_0001).edx & (1 << 29) != 0)
    #expect(profile.cpuid(leaf: 0x8000_0008).eax == 40 | (48 << 8))

    let topology = profile.cpuid(
      leaf: 1,
      processorID: 3,
      logicalProcessorCount: 4
    )
    #expect(topology.ebx >> 16 & 0xFF == 4)
    #expect(topology.ebx >> 24 == 3)
    #expect(topology.edx & (1 << 28) != 0)
    #expect(profile.cpuid(leaf: 0xB, subleaf: 1, processorID: 3, logicalProcessorCount: 4).eax == 2)
    #expect(profile.cpuid(leaf: 0xB, subleaf: 1, processorID: 3, logicalProcessorCount: 4).edx == 3)
  }

  @Test func modelSpecificStateHasDeterministicArchitecturalDefaults() throws {
    var msrs = DoryX86ModelSpecificRegisterState()
    #expect(msrs.apicBase == 0xfee0_0900)
    #expect(msrs.pageAttributeTable == 0x0007_0406_0007_0406)
    msrs.longStar = 0xffff_8000_0000_1000
    let state = try DoryX86ArchitecturalState(modelSpecific: msrs)
    let restored = try JSONDecoder().decode(
      DoryX86ArchitecturalState.self,
      from: JSONEncoder().encode(state)
    )
    #expect(restored.modelSpecific == msrs)
  }
}
