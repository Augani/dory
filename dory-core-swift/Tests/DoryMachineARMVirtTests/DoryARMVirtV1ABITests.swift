import Foundation
import Testing

@testable import DoryMachineARMVirt

@Suite struct DoryARMVirtV1ABITests {
  @Test func fixedRegionsAreOrderedNonoverlappingAndBelowRAM() {
    #expect(DoryARMVirtV1ABI.identity == "dory.armvirt@1")
    #expect(
      DoryARMVirtV1ABI.regions.map(\.kind) == [
        .gicDistributor,
        .gicRedistributors,
        .uart,
        .rtc,
        .virtioMMIO,
      ])
    for pair in zip(DoryARMVirtV1ABI.regions, DoryARMVirtV1ABI.regions.dropFirst()) {
      #expect(!pair.0.range.overlaps(pair.1.range))
      #expect(pair.0.range.base < pair.1.range.base)
    }
    #expect(DoryARMVirtV1ABI.regions.last!.range.endExclusive.rawValue < DoryARMVirtV1ABI.ramBase)
  }

  @Test func everyVirtioSlotHasExactAddressInterruptAndRole() {
    #expect(DoryARMVirtV1ABI.virtioSlots.count == 32)
    for slot in DoryARMVirtV1ABI.virtioSlots {
      #expect(slot.baseAddress == 0x0c10_0000 + UInt64(slot.index) * 0x200)
      #expect(slot.byteCount == 0x200)
      #expect(slot.spi == 16 + UInt32(slot.index))
      #expect(slot.interruptID == 48 + UInt32(slot.index))
      #expect(slot.role == DoryARMVirtV1ABI.role(forSlot: slot.index))
    }
    #expect(DoryARMVirtV1ABI.virtioSlots[30].role == .usbController)
    #expect(DoryARMVirtV1ABI.virtioSlots[31].role == .reserved)
  }

  @Test func resourceAdmissionProtectsBootAndDAXWindows() throws {
    try DoryARMVirtV1ABI.validateMemoryBytes(1 << 30)
    try DoryARMVirtV1ABI.validateMemoryBytes(DoryARMVirtV1ABI.maximumRAMBytes)
    try DoryARMVirtV1ABI.validateVCPUCount(1)
    try DoryARMVirtV1ABI.validateVCPUCount(256)

    #expect(
      throws: DoryARMVirtV1ABIError.memoryBelowMinimum(
        minimum: 1 << 30,
        actual: (1 << 30) - 1
      )
    ) {
      try DoryARMVirtV1ABI.validateMemoryBytes((1 << 30) - 1)
    }
    #expect(
      throws: DoryARMVirtV1ABIError.memoryOverlapsDAXWindow(
        maximum: DoryARMVirtV1ABI.maximumRAMBytes,
        actual: DoryARMVirtV1ABI.maximumRAMBytes + 1
      )
    ) {
      try DoryARMVirtV1ABI.validateMemoryBytes(DoryARMVirtV1ABI.maximumRAMBytes + 1)
    }
    #expect(throws: DoryARMVirtV1ABIError.invalidVCPUCount(maximum: 256, actual: 257)) {
      try DoryARMVirtV1ABI.validateVCPUCount(257)
    }
  }

  @Test func checkedInSpecificationMatchesSourceProjectionByteForByte() throws {
    let sourceFile = URL(fileURLWithPath: #filePath)
    let repositoryRoot =
      sourceFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let specificationURL =
      repositoryRoot
      .appendingPathComponent("docs/virtualization/dory-armvirt-v1-abi.md")
    let checkedIn = try String(contentsOf: specificationURL, encoding: .utf8)
    #expect(checkedIn == DoryARMVirtV1ABI.markdown + "\n")
  }
}
