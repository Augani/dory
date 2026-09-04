import DoryDBTX86
import DoryMachinePC
import Foundation
import Testing

@Suite struct DoryPCPhysicalMemoryConformanceTests {
  private func backends() throws -> [any DoryX86PhysicalRAM] {
    [
      try DoryX86ByteArrayMemory(validatingByteCount: 0x4000),
      try DoryX86MmapMemory(validatingByteCount: 0x4000),
    ]
  }

  @Test func invalidLengthsMatchRAMBeforeAnyUnsealedOrSealedDeviceAccess() throws {
    for ram in try backends() {
      let bus = try DoryPCPhysicalMemoryBus(ram: ram)
      let device = LengthConformanceMMIO()
      try bus.attach(device)
      for sealed in [false, true] {
        if sealed { bus.seal() }
        for address: UInt64 in [0x100, device.baseAddress, .max] {
          for count in [Int.min, -1] {
            let expected = DoryX86MemoryError.addressOverflow(address: address, byteCount: count)
            for memory in [ram, bus] as [any DoryX86Memory] {
              #expect(throws: expected) { try memory.read(at: address, byteCount: count) }
              #expect(throws: expected) { try memory.instructionBytes(at: address, maximumCount: count) }
              #expect(throws: expected) { try memory.validateRead(at: address, byteCount: count) }
              #expect(throws: expected) { try memory.validateWrite(at: address, byteCount: count) }
            }
            for memory in [ram, bus] as [any DoryX86CodeGenerationMemory] {
              #expect(throws: expected) { try memory.codeGeneration(at: address, byteCount: count) }
            }
            // DMA already rejects negative lengths; both its public entry points must stay exact.
            for writes in [false, true] {
              #expect(throws: expected) {
                try bus.validateDMA(at: address, byteCount: count, deviceWillWrite: writes)
              }
              #expect(throws: expected) {
                try bus.validate(at: address, byteCount: count, deviceWillWrite: writes)
              }
            }
          }
          for width in [Int.min, -1, 0, 3, 16, Int.max] {
            let expected = DoryX86ScalarMemoryError.invalidByteCount(width)
            for memory in [ram, bus] as [any DoryX86ScalarMemory] {
              #expect(throws: expected) { try memory.readScalar(at: address, byteCount: width) }
              #expect(throws: expected) {
                try memory.writeScalar(at: address, value: 0xA5, byteCount: width)
              }
            }
            #expect(throws: expected) {
              try bus.readRestartableScalar(at: address, byteCount: width)
            }
          }
        }
        #expect(device.accesses == 0)
        #expect(try ram.read(at: 0, byteCount: ram.byteCount) == .init(repeating: 0, count: ram.byteCount))
      }
    }
  }

  @Test func unsupportedBulkLengthsDeclineConsistentlyWithoutTouchingMMIO() throws {
    for ram in try backends() {
      let bus = try DoryPCPhysicalMemoryBus(ram: ram)
      let device = LengthConformanceMMIO()
      try bus.attach(device)
      for sealed in [false, true] {
        if sealed { bus.seal() }
        for memory in [ram, bus] as [any DoryX86BulkMemory] {
          for count in [Int.min, -1] {
            #expect(memory.bulkCopyRAMSpan(at: device.baseAddress, maximumByteCount: count) == nil)
            #expect(try memory.copyForwardNonoverlapping(
              from: device.baseAddress, to: 0x100, maximumByteCount: count) == nil)
            #expect(try memory.copyForwardNonoverlappingElements(
              from: 0x100, to: device.baseAddress, elementByteCount: 8,
              maximumElementCount: count, excludingDestinationRanges: []) == nil)
            #expect(try memory.fillRepeating(
              at: device.baseAddress, pattern: [0xAA], maximumElementCount: count) == nil)
          }
          for width in [Int.min, -1, 0, Int.max] {
            #expect(try memory.copyForwardNonoverlappingElements(
              from: device.baseAddress, to: 0x100, elementByteCount: width,
              maximumElementCount: 2, excludingDestinationRanges: []) == nil)
          }
          #expect(try memory.fillRepeating(
            at: device.baseAddress, pattern: [], maximumElementCount: 1) == nil)
        }
        #expect(device.accesses == 0)
        #expect(try ram.read(at: 0, byteCount: ram.byteCount) == .init(repeating: 0, count: ram.byteCount))
      }
    }
  }

  @Test func zeroLengthNoOpsRetainTheirDefinedBehaviorEvenAtUnmappedAddresses() throws {
    for ram in try backends() {
      let bus = try DoryPCPhysicalMemoryBus(ram: ram)
      let device = LengthConformanceMMIO()
      try bus.attach(device)
      bus.seal()
      for address: UInt64 in [0x100, device.baseAddress, .max] {
        for memory in [ram, bus] as [any DoryX86Memory] {
          #expect(try memory.read(at: address, byteCount: 0).isEmpty)
          #expect(try memory.instructionBytes(at: address, maximumCount: 0).isEmpty)
          try memory.validateRead(at: address, byteCount: 0)
          try memory.validateWrite(at: address, byteCount: 0)
          try memory.write(at: address, bytes: [])
        }
        for memory in [ram, bus] as [any DoryX86CodeGenerationMemory] {
          #expect(try memory.codeGeneration(at: address, byteCount: 0) == nil)
        }
        for memory in [ram, bus] as [any DoryX86BulkMemory] {
          #expect(memory.bulkCopyRAMSpan(at: address, maximumByteCount: 0) == 0)
          #expect(try memory.copyForwardNonoverlapping(
            from: address, to: address, maximumByteCount: 0) == 0)
          #expect(try memory.copyForwardNonoverlappingElements(
            from: address, to: address, elementByteCount: 0,
            maximumElementCount: 0, excludingDestinationRanges: []) == 0)
          #expect(try memory.fillRepeating(
            at: address, pattern: [], maximumElementCount: 0) == 0)
        }
      }
      #expect(device.accesses == 0)
    }
  }
}

/// Every device operation is observable, including validation and executable-region queries.
private final class LengthConformanceMMIO: DoryPCMMIODevice, @unchecked Sendable {
  let baseAddress: UInt64 = 0x2000
  let byteCount: UInt64 = 0x100
  let allowsInstructionFetch = true
  private let lock = NSLock()
  private var count = 0
  var accesses: Int { lock.withLock { count } }

  private func record() { lock.withLock { count += 1 } }
  func read(offset: UInt64, byteCount: Int) throws -> [UInt8] { record(); return [] }
  func readRestartableScalar(offset: UInt64, byteCount: Int) throws -> UInt64? { record(); return 0 }
  func codeGeneration(offset: UInt64, byteCount: Int) throws -> UInt64? { record(); return 0 }
  func write(offset: UInt64, bytes: [UInt8]) throws { record() }
  func validateWrite(offset: UInt64, byteCount: Int) throws { record() }
  func synchronize() { record() }
}
