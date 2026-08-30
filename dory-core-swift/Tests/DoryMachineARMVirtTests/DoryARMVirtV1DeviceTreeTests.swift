import Testing

@testable import DoryMachineARMVirt

@Suite struct DoryARMVirtV1DeviceTreeTests {
  @Test func deterministicTreeCarriesFrozenMachineIdentityAndDevices() throws {
    let configuration = fixture()
    let first = try DoryARMVirtV1DeviceTree.build(configuration: configuration)
    let second = try DoryARMVirtV1DeviceTree.build(configuration: configuration)

    #expect(first == second)
    #expect(Array(first.prefix(4)) == [0xd0, 0x0d, 0xfe, 0xed])
    #expect(first.readBigEndianUInt32(at: 4) == UInt32(first.count))
    #expect(first.contains(bytes: Array("dory,armvirt-1".utf8) + [0]))
    #expect(first.contains(bytes: Array("linux,dummy-virt".utf8) + [0]))
    #expect(first.contains(bytes: Array("virtio_mmio@c100000".utf8) + [0]))
    #expect(first.contains(bytes: Array("virtio_mmio@c100800".utf8) + [0]))
    #expect(first.contains(bytes: Array("console=ttyAMA0".utf8) + [0]))
  }

  @Test func deviceAssignmentsMustMatchFrozenSlots() {
    var invalid = fixtureDevices()
    invalid[0] = DoryARMVirtV1MMIODevice(
      slot: 0,
      baseAddress: DoryARMVirtV1ABI.virtioBase + 1,
      byteCount: DoryARMVirtV1ABI.virtioSlotBytes,
      spi: DoryARMVirtV1ABI.virtioFirstSPI
    )
    #expect(throws: DoryARMVirtV1DeviceTreeError.invalidVirtioDevice(slot: 0)) {
      try DoryARMVirtV1DeviceTree.build(configuration: fixture(devices: invalid))
    }

    #expect(throws: DoryARMVirtV1DeviceTreeError.duplicateVirtioSlot(0)) {
      try DoryARMVirtV1DeviceTree.build(
        configuration: fixture(
          devices: [fixtureDevices()[0], fixtureDevices()[0]]
        ))
    }
  }

  @Test func initrdAndGICMustStayInsideAdvertisedABIWindows() {
    #expect(throws: DoryARMVirtV1DeviceTreeError.invalidInitrdRange) {
      try DoryARMVirtV1DeviceTree.build(
        configuration: DoryARMVirtV1DeviceTreeConfiguration(
          commandLine: "",
          memoryBytes: DoryARMVirtV1ABI.minimumMemoryBytes,
          vCPUCount: 1,
          initrdRange: 0x1000..<0x2000,
          gicDistributorBytes: 0x1_0000,
          gicRedistributorRegionBytes: 0x2_0000,
          gicRedistributorStride: 0x2_0000,
          virtioDevices: []
        ))
    }
    #expect(throws: DoryARMVirtV1DeviceTreeError.invalidGICLayout) {
      try DoryARMVirtV1DeviceTree.build(
        configuration: DoryARMVirtV1DeviceTreeConfiguration(
          commandLine: "",
          memoryBytes: DoryARMVirtV1ABI.minimumMemoryBytes,
          vCPUCount: 1,
          gicDistributorBytes: DoryARMVirtV1ABI.gicDistributorReservedBytes + 1,
          gicRedistributorRegionBytes: 0x2_0000,
          gicRedistributorStride: 0x2_0000,
          virtioDevices: []
        ))
    }
  }

  private func fixture(
    devices: [DoryARMVirtV1MMIODevice]? = nil
  ) -> DoryARMVirtV1DeviceTreeConfiguration {
    DoryARMVirtV1DeviceTreeConfiguration(
      commandLine: "console=ttyAMA0",
      memoryBytes: DoryARMVirtV1ABI.minimumMemoryBytes,
      vCPUCount: 4,
      initrdRange: (DoryARMVirtV1ABI.ramBase + DoryARMVirtV1ABI.initrdOffset)..<(DoryARMVirtV1ABI
        .ramBase + DoryARMVirtV1ABI.initrdOffset + 4096),
      gicDistributorBytes: 0x1_0000,
      gicRedistributorRegionBytes: 0x8_0000,
      gicRedistributorStride: 0x2_0000,
      virtioDevices: devices ?? fixtureDevices()
    )
  }

  private func fixtureDevices() -> [DoryARMVirtV1MMIODevice] {
    [0, 4].map { slot in
      let fixed = DoryARMVirtV1ABI.virtioSlots[slot]
      return DoryARMVirtV1MMIODevice(
        slot: slot,
        baseAddress: fixed.baseAddress,
        byteCount: fixed.byteCount,
        spi: fixed.spi
      )
    }
  }
}

extension Array where Element == UInt8 {
  fileprivate func contains(bytes: [UInt8]) -> Bool {
    guard !bytes.isEmpty, bytes.count <= count else { return false }
    return indices.dropLast(bytes.count - 1).contains { start in
      self[start..<(start + bytes.count)].elementsEqual(bytes)
    }
  }

  fileprivate func readBigEndianUInt32(at offset: Int) -> UInt32 {
    self[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
  }
}
