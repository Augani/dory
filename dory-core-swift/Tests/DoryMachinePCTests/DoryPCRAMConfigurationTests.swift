import DoryDBTX86
import Testing

@testable import DoryMachinePC

@Suite struct DoryPCRAMConfigurationTests {
  @Test func publicBusInitializationRejectsInvalidRAMWithoutTrapping() throws {
    for memory in [DoryX86ByteArrayMemory(baseAddress: 1, bytes: [0]),
      DoryX86ByteArrayMemory(bytes: [])] {
      let expected = DoryPCPhysicalMemoryError.invalidRAMConfiguration(
        base: memory.baseAddress, byteCount: memory.byteCount,
        mmioHoleStart: DoryPCV1ABI.mmioHoleStart, above4GRAMStart: DoryPCV1ABI.above4GRAMStart)
      #expect(throws: expected) { try DoryPCPhysicalMemoryBus(ram: memory) }
      #expect(memory.snapshot() == (memory.byteCount == 0 ? [] : [0]))
    }
  }

  @Test func busInitializationRejectsInvalidAperturesAndAcceptsValidBackingKinds() throws {
    let memories: [any DoryX86PhysicalRAM] = [
      try DoryX86ByteArrayMemory(validatingByteCount: 4096),
      try DoryX86MmapMemory(byteCount: 4096),
    ]
    for memory in memories {
      for (hole, high): (UInt64, UInt64) in [(0, 4096), (4096, 4096), (8192, 4096)] {
        #expect(throws: DoryPCPhysicalMemoryError.invalidRAMConfiguration(
          base: 0, byteCount: 4096, mmioHoleStart: hole, above4GRAMStart: high)) {
          try DoryPCPhysicalMemoryBus(ram: memory, mmioHoleStart: hole, above4GRAMStart: high)
        }
      }
      let bus = try DoryPCPhysicalMemoryBus(ram: memory)
      bus.seal()
      try bus.writeScalar(at: 4088, value: 0x1234, byteCount: 8)
      #expect(try memory.readScalar(at: 4088, byteCount: 8) == 0x1234)
    }
  }
}
