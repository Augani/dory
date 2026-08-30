import DoryMachineARMVirt
import Foundation
import Testing

@Suite struct DoryARMVirtV1BootStateTests {
  @Test func directLinuxAndUEFIRegistersAreFrozen() throws {
    let direct = try DoryARMVirtV1InitialCPUState.directLinux(
      entryPoint: DoryARMVirtV1ABI.ramBase + 0x80000,
      deviceTreeAddress: DoryARMVirtV1ABI.ramBase + DoryARMVirtV1ABI.dtbOffset
    )

    #expect(direct.bootProtocol == .directLinux)
    #expect(direct.x0 == DoryARMVirtV1ABI.ramBase + DoryARMVirtV1ABI.dtbOffset)
    #expect(direct.x1 == 0 && direct.x2 == 0 && direct.x3 == 0)
    #expect(direct.pstate == DoryARMVirtV1InitialCPUState.resetPSTATE)
    #expect(DoryARMVirtV1InitialCPUState.uefi.bootProtocol == .uefi)
    #expect(DoryARMVirtV1InitialCPUState.uefi.programCounter == DoryARMVirtV1ABI.uefiResetAddress)
    #expect(DoryARMVirtV1InitialCPUState.uefi.x0 == 0)
  }

  @Test func decoderRejectsSubstitutedUEFIRegisters() throws {
    let data = Data(#"""
      {
        "bootProtocol":"uefi",
        "programCounter":4,
        "pstate":965,
        "x0":0,
        "x1":0,
        "x2":0,
        "x3":0
      }
      """#.utf8)
    #expect(throws: DoryARMVirtV1BootStateError.invalidUEFIState) {
      _ = try JSONDecoder().decode(DoryARMVirtV1InitialCPUState.self, from: data)
    }

    let unknown = Data(#"""
      {
        "bootProtocol":"uefi",
        "programCounter":0,
        "pstate":965,
        "x0":0,
        "x1":0,
        "x2":0,
        "x3":0,
        "future":true
      }
      """#.utf8)
    #expect(throws: DoryARMVirtV1BootStateError.unknownFields(["future"])) {
      _ = try JSONDecoder().decode(DoryARMVirtV1InitialCPUState.self, from: unknown)
    }
  }
}
