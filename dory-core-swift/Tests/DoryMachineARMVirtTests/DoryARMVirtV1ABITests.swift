import Foundation
import Testing

import DoryExecutionContracts
@testable import DoryMachineARMVirt

@Suite struct DoryARMVirtV1ABITests {
  @Test func fixedRegionsAreOrderedNonoverlappingAndBelowRAM() {
    #expect(DoryARMVirtV1ABI.identity == "dory.armvirt@1")
    #expect(
      DoryARMVirtV1ABI.regions.map(\.kind) == [
        .firmwareCode,
        .firmwareVariables,
        .gicDistributor,
        .gicRedistributors,
        .uart,
        .rtc,
        .powerController,
        .virtioMMIO,
        .pcieECAM,
        .pcieMMIO,
      ])
    for pair in zip(DoryARMVirtV1ABI.regions, DoryARMVirtV1ABI.regions.dropFirst()) {
      #expect(!pair.0.range.overlaps(pair.1.range))
      #expect(pair.0.range.base < pair.1.range.base)
    }
    #expect(DoryARMVirtV1ABI.regions.last!.range.endExclusive.rawValue <= DoryARMVirtV1ABI.ramBase)
  }

  @Test func bootAndFirmwareIdentitiesAreFrozen() {
    #expect(DoryARMVirtV1BootProtocol.allCases == [.directLinux, .uefi])
    #expect(DoryARMVirtV1ABI.directLinuxDeviceTreeRegister == 0)
    #expect(DoryARMVirtV1ABI.uefiResetAddress == DoryARMVirtV1ABI.firmwareCodeBase)
    #expect(DoryARMVirtV1ABI.firmwareABIIdentity == "dory.edk2.armvirt@1")
    #expect(
      DoryARMVirtV1ABI.variableStoreFormatIdentity
        == "dory.uefi.variables.armvirt@1"
    )
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
      .appendingPathComponent("Firmware/DoryARMVirt/abi.txt")
    let checkedIn = try String(contentsOf: specificationURL, encoding: .utf8)
    #expect(checkedIn == DoryARMVirtV1ABI.markdown + "\n")
  }

  // MARK: - P2-01 region validation

  @Test func frozenRegionsPassValidation() throws {
    try DoryARMVirtV1ABI.validateRegions()
  }

  @Test func overlappingRegionsAreRejected() {
    #expect(throws: DoryARMVirtV1ABIError.self) {
      let overlapping = [
        try DoryARMVirtV1Region(kind: .uart, base: 0x1000, byteCount: 0x2000),
        try DoryARMVirtV1Region(kind: .rtc, base: 0x1000, byteCount: 0x1000),
      ]
      try DoryARMVirtV1ABI.validateRegions(overlapping)
    }
  }

  @Test func zeroLengthRegionIsRejected() {
    #expect(throws: DoryExecutionContractError.self) {
      _ = try DoryARMVirtV1Region(kind: .uart, base: 0x1000, byteCount: 0)
    }
  }

  @Test func adjacentRegionsDoNotOverlap() throws {
    let adjacent = [
      try DoryARMVirtV1Region(kind: .uart, base: 0x1000, byteCount: 0x1000),
      try DoryARMVirtV1Region(kind: .rtc, base: 0x2000, byteCount: 0x1000),
    ]
    try DoryARMVirtV1ABI.validateRegions(adjacent)
  }

  @Test func unsortedNonAdjacentOverlapIsRejected() {
    // A=0x1000..<0x3000, B=0x4000..<0x5000, C=0x2000..<0x2800.
    // In caller order, B does not overlap either neighbor, but A and C overlap.
    // The previous pairwise-only check missed this; sorting by base must catch it.
    #expect(throws: DoryARMVirtV1ABIError.self) {
      let unsorted = [
        try DoryARMVirtV1Region(kind: .uart, base: 0x1000, byteCount: 0x2000),
        try DoryARMVirtV1Region(kind: .rtc, base: 0x4000, byteCount: 0x1000),
        try DoryARMVirtV1Region(kind: .powerController, base: 0x2000, byteCount: 0x0800),
      ]
      try DoryARMVirtV1ABI.validateRegions(unsorted)
    }
  }

  @Test func unsortedNonOverlappingLayoutStillValidates() throws {
    // Same three regions as above but with C moved out of A's range, in unsorted order.
    let unsorted = [
      try DoryARMVirtV1Region(kind: .uart, base: 0x1000, byteCount: 0x2000),
      try DoryARMVirtV1Region(kind: .rtc, base: 0x4000, byteCount: 0x1000),
      try DoryARMVirtV1Region(kind: .powerController, base: 0x3000, byteCount: 0x0800),
    ]
    try DoryARMVirtV1ABI.validateRegions(unsorted)
  }
}
