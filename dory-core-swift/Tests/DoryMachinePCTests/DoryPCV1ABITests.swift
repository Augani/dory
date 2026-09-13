import Foundation
import Testing

import DoryExecutionContracts
@testable import DoryMachinePC

@Suite struct DoryPCV1ABITests {
  @Test func freezesIdentityAddressMapAndResetVector() {
    #expect(DoryPCV1ABI.identity == "dory.pc@1")
    #expect(DoryPCV1ABI.firmwareABIIdentity == "dory.edk2.pc@1")
    #expect(DoryPCV1ABI.variableStoreFormatIdentity == "dory.uefi.variables.pc@1")
    #expect(DoryPCV1ABI.pcieMMIOBase == 0xD000_0000)
    #expect(DoryPCV1ABI.pcieECAMBase == 0xE000_0000)
    #expect(DoryPCV1ABI.firmwareCodeBase == 0xFF00_0000)
    #expect(DoryPCV1ABI.uefiResetAddress == 0xFFFF_FFF0)

    let ranges = DoryPCV1ABI.regions.map(\.range).sorted { $0.base < $1.base }
    for pair in zip(ranges, ranges.dropFirst()) {
      #expect(pair.0.endExclusive <= pair.1.base)
    }
  }

  @Test func validatesProductResourcesAndSwizzlesINTx() throws {
    try DoryPCV1ABI.validateProductMemoryBytes(512 << 20)
    try DoryPCV1ABI.validateProductMemoryBytes(512 << 30)
    try DoryPCV1ABI.validateVCPUCount(1)
    try DoryPCV1ABI.validateVCPUCount(255)

    #expect(DoryPCV1ABI.interruptLine(device: 1, pin: 1) == 17)
    #expect(DoryPCV1ABI.interruptLine(device: 1, pin: 4) == 20)
    #expect(DoryPCV1ABI.interruptLine(device: 9, pin: 1) == 17)
    #expect(throws: DoryPCV1ABIError.self) {
      try DoryPCV1ABI.validateProductMemoryBytes((512 << 20) - 1)
    }
    #expect(throws: DoryPCV1ABIError.unalignedMemory((512 << 20) + 4096)) {
      try DoryPCV1ABI.validateProductMemoryBytes((512 << 20) + 4096)
    }
    #expect(throws: DoryPCV1ABIError.invalidVCPUCount(maximum: 255, actual: 256)) {
      try DoryPCV1ABI.validateVCPUCount(256)
    }
  }

  @Test func selectsTheSmallestAdmittedPowerOfTwoGuestPhysicalSpace() {
    #expect(DoryPCV1ABI.guestPhysicalAddressBits(memoryBytes: 512 << 20) == 36)
    #expect(DoryPCV1ABI.guestPhysicalAddressSpaceBytes(memoryBytes: 512 << 20) == 64 << 30)
    #expect(DoryPCV1ABI.guestPhysicalAddressBits(memoryBytes: 60 << 30) == 36)
    #expect(DoryPCV1ABI.guestPhysicalAddressBits(memoryBytes: 64 << 30) == 37)
    #expect(DoryPCV1ABI.guestPhysicalAddressBits(memoryBytes: 512 << 30) == 40)
    #expect(DoryPCV1ABI.guestPhysicalAddressSpaceBytes(memoryBytes: 512 << 30) == 1 << 40)
  }

  @Test func checkedInABIProjectionMatchesSource() throws {
    let source = URL(fileURLWithPath: #filePath)
    let packageRoot = source.deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let document = packageRoot.deletingLastPathComponent()
      .appendingPathComponent("Firmware/DoryPC/abi.txt")
    let checkedIn = try String(contentsOf: document, encoding: .utf8)
    #expect(checkedIn == DoryPCV1ABI.markdown + "\n")
  }

  // MARK: - P2-01 region validation

  @Test func frozenRegionsPassValidation() throws {
    try DoryPCV1ABI.validateRegions()
  }

  @Test func overlappingRegionsAreRejected() {
    #expect(throws: DoryPCV1ABIError.self) {
      let overlapping = [
        try DoryPCV1Region(kind: .ioAPIC, base: 0x1000, byteCount: 0x2000),
        try DoryPCV1Region(kind: .hpet, base: 0x1000, byteCount: 0x1000),
      ]
      try DoryPCV1ABI.validateRegions(overlapping)
    }
  }

  @Test func zeroLengthRegionIsRejected() {
    #expect(throws: DoryExecutionContractError.self) {
      _ = try DoryPCV1Region(kind: .ioAPIC, base: 0x1000, byteCount: 0)
    }
  }

  @Test func adjacentRegionsDoNotOverlap() throws {
    let adjacent = [
      try DoryPCV1Region(kind: .ioAPIC, base: 0x1000, byteCount: 0x1000),
      try DoryPCV1Region(kind: .hpet, base: 0x2000, byteCount: 0x1000),
    ]
    try DoryPCV1ABI.validateRegions(adjacent)
  }
}
