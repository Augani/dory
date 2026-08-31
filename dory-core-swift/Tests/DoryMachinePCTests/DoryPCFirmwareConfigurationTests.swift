import Testing

@testable import DoryMachinePC

@Suite struct DoryPCFirmwareConfigurationTests {
  @Test func publishesFrozenDiscoveryPage() throws {
    let totalRAM: UInt64 = DoryPCV1ABI.mmioHoleStart + (768 << 20)
    let device = DoryPCFirmwareConfiguration(
      totalRAMBytes: totalRAM,
      processorCount: 8,
      flags: [.qualificationBootProbe]
    )

    #expect(try read(UInt64.self, device, at: 0) == DoryPCFirmwareConfiguration.ABI.magic)
    #expect(try read(UInt32.self, device, at: 8) == 1)
    #expect(try read(UInt32.self, device, at: 12) == 144)
    #expect(
      try read(UInt32.self, device, at: 20)
        == DoryPCFirmwareConfiguration.Flags.qualificationBootProbe.rawValue
    )
    #expect(try read(UInt64.self, device, at: 24) == totalRAM)
    #expect(try read(UInt64.self, device, at: 32) == DoryPCV1ABI.mmioHoleStart)
    #expect(try read(UInt64.self, device, at: 40) == 768 << 20)
    #expect(try read(UInt32.self, device, at: 48) == 8)
    #expect(try read(UInt64.self, device, at: 56) == DoryPCV1ABI.pcieECAMBase)
    #expect(try read(UInt64.self, device, at: 88) == DoryPCV1ABI.acpiBase)
    #expect(try read(UInt64.self, device, at: 96) == DoryPCV1ABI.smbiosBase)
    #expect(try read(UInt64.self, device, at: 104) == DoryPCV1ABI.firmwareVariableBase)
    #expect(try read(UInt64.self, device, at: 136) == DoryPCV1ABI.above4GRAMStart)
  }

  @Test func isReadOnlyAndInstalledByMachine() throws {
    let machine = try DoryPCDirectKernelMachine(memoryBytes: 2 << 20, processorCount: 2)
    #expect(machine.platformMMIODevices.first is DoryPCFirmwareConfiguration)
    #expect(
      try read(
        UInt32.self,
        machine.physicalMemory,
        at: DoryPCV1ABI.firmwareConfigurationBase + 48
      ) == 2
    )
    #expect(throws: DoryPCPhysicalMemoryError.self) {
      try machine.physicalMemory.write(
        at: DoryPCV1ABI.firmwareConfigurationBase,
        bytes: [0]
      )
    }
  }

  private func read<T: FixedWidthInteger>(
    _ type: T.Type,
    _ device: DoryPCFirmwareConfiguration,
    at offset: UInt64
  ) throws -> T {
    T(
      littleEndian: try device.read(offset: offset, byteCount: MemoryLayout<T>.size)
        .withUnsafeBytes { $0.loadUnaligned(as: T.self) })
  }

  private func read<T: FixedWidthInteger>(
    _ type: T.Type,
    _ memory: DoryPCPhysicalMemoryBus,
    at address: UInt64
  ) throws -> T {
    T(
      littleEndian: try memory.read(at: address, byteCount: MemoryLayout<T>.size)
        .withUnsafeBytes { $0.loadUnaligned(as: T.self) })
  }
}
