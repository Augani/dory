import DoryDBTX86
import Testing

@testable import DoryMachinePC

@Suite struct DoryPCRAMConfigurationTests {
  @Test func publicBusInitializationRejectsInvalidRAMWithoutTrapping() throws {
    for memory in [InvalidConfigurationRAM(baseAddress: 1, byteCount: 1),
      InvalidConfigurationRAM(baseAddress: 0, byteCount: 0),
      InvalidConfigurationRAM(baseAddress: 0, byteCount: -1)] {
      let expected = DoryPCPhysicalMemoryError.invalidRAMConfiguration(
        base: memory.baseAddress, byteCount: memory.byteCount,
        mmioHoleStart: DoryPCV1ABI.mmioHoleStart, above4GRAMStart: DoryPCV1ABI.above4GRAMStart)
      #expect(throws: expected) { try DoryPCPhysicalMemoryBus(ram: memory) }
      #expect(memory.accesses == 0)
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

/// Invalid metadata is injected explicitly: production backings now reject these configurations.
private final class InvalidConfigurationRAM: DoryX86PhysicalRAM, @unchecked Sendable {
  let baseAddress: UInt64
  let byteCount: Int
  private(set) var accesses = 0

  init(baseAddress: UInt64, byteCount: Int) {
    self.baseAddress = baseAddress
    self.byteCount = byteCount
  }

  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] { accesses += 1; return [] }
  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] { accesses += 1; return [] }
  func write(at address: UInt64, bytes: [UInt8]) throws { accesses += 1 }
  func codeGeneration(at address: UInt64, byteCount: Int) throws -> UInt64? { accesses += 1; return nil }
  func readRestartableScalar(at address: UInt64, byteCount: Int) throws -> UInt64? { accesses += 1; return nil }
  func bulkCopyRAMSpan(at address: UInt64, maximumByteCount: Int) -> Int? { accesses += 1; return nil }
  func copyForwardNonoverlapping(
    from sourceAddress: UInt64, to destinationAddress: UInt64, maximumByteCount: Int
  ) throws -> Int? { accesses += 1; return nil }
}
