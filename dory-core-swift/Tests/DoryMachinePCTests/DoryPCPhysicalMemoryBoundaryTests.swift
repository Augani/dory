import DoryDBTX86
import Foundation
import Testing

@testable import DoryMachinePC

@Suite struct DoryPCPhysicalMemoryBoundaryTests {
  private func backing(mmap: Bool, base: UInt64 = 0, count: Int = 0x2000) throws
    -> any DoryX86PhysicalRAM
  {
    if mmap { return try DoryX86MmapMemory(baseAddress: base, byteCount: count) }
    return try DoryX86ByteArrayMemory(baseAddress: base, validatingByteCount: count)
  }

  @Test(arguments: [false, true])
  func crossDeviceBoundaryPreservesAccessKindBeforeAnyDeviceEffect(mmap: Bool) throws {
    let ram = try backing(mmap: mmap)
    let bus = try DoryPCPhysicalMemoryBus(ram: ram)
    let device = BoundaryMMIO(baseAddress: 0x1000, byteCount: 0x10)
    try bus.attach(device)
    let address = device.baseAddress + device.byteCount - 1
    let read = DoryX86MemoryError.unmapped(address: address, byteCount: 2, access: .read)
    let write = DoryX86MemoryError.unmapped(address: address, byteCount: 2, access: .write)
    let fetch = DoryX86MemoryError.unmapped(
      address: address, byteCount: 2, access: .instructionFetch)
    for sealed in [false, true] {
      if sealed { bus.seal() }
      #expect(throws: read) { try bus.read(at: address, byteCount: 2) }
      #expect(throws: read) { try bus.readScalar(at: address, byteCount: 2) }
      #expect(throws: read) { try bus.readRestartableScalar(at: address, byteCount: 2) }
      #expect(throws: read) { try bus.validateRead(at: address, byteCount: 2) }
      #expect(throws: write) { try bus.write(at: address, bytes: [1, 2]) }
      #expect(throws: write) { try bus.writeScalar(at: address, value: 0x0201, byteCount: 2) }
      #expect(throws: write) { try bus.validateWrite(at: address, byteCount: 2) }
      #expect(throws: fetch) { try bus.codeGeneration(at: address, byteCount: 2) }
      #expect(throws: read) {
        try bus.validateDMA(at: address, byteCount: 2, deviceWillWrite: false)
      }
      #expect(throws: write) {
        try bus.validateDMA(at: address, byteCount: 2, deviceWillWrite: true)
      }
      #expect(device.accesses == 0)
      #expect(try ram.read(at: 0, byteCount: ram.byteCount) == Array(repeating: 0, count: ram.byteCount))
    }
  }

  @Test(arguments: [false, true])
  func executableMappingLargerThanIntDoesNotOverflowBoundedFetch(mmap: Bool) throws {
    let bus = try DoryPCPhysicalMemoryBus(ram: backing(mmap: mmap))
    let device = BoundaryMMIO(baseAddress: 0x8000, byteCount: UInt64(Int.max) + 1)
    try bus.attach(device)
    let lastAddress = device.baseAddress + device.byteCount - 1
    for sealed in [false, true] {
      if sealed { bus.seal() }
      #expect(try bus.instructionBytes(at: device.baseAddress, maximumCount: 15)
        == Array(repeating: 0x90, count: 15))
      #expect(try bus.instructionBytes(at: lastAddress, maximumCount: 15) == [0x90])
      #expect(try bus.instructionBytes(at: lastAddress, maximumCount: 0).isEmpty)
    }
    #expect(device.accesses == 4)
  }

  @Test(arguments: [false, true])
  func relocatedRAMMustFitItsCompletePhysicalAddressRange(mmap: Bool) throws {
    let ram = try backing(mmap: mmap)
    let high = UInt64.max - 0x0FFF
    #expect(throws: DoryPCPhysicalMemoryError.invalidRAMConfiguration(
      base: 0, byteCount: 0x2000, mmioHoleStart: 0x1000, above4GRAMStart: high)) {
      try DoryPCPhysicalMemoryBus(ram: ram, mmioHoleStart: 0x1000, above4GRAMStart: high)
    }
    // The adjacent non-overflowing configuration remains byte-exact at its last mapped byte.
    let bus = try DoryPCPhysicalMemoryBus(
      ram: ram, mmioHoleStart: 0x1000, above4GRAMStart: high - 1)
    for sealed in [false, true] {
      if sealed { bus.seal() }
      try bus.writeScalar(at: UInt64.max - 1, value: 0x5A, byteCount: 1)
      #expect(try bus.readScalar(at: UInt64.max - 1, byteCount: 1) == 0x5A)
      #expect(try ram.readScalar(at: 0x1FFF, byteCount: 1) == 0x5A)
      #expect(throws: DoryX86MemoryError.addressOverflow(address: .max, byteCount: 1)) {
        try bus.read(at: .max, byteCount: 1)
      }
    }
  }

  @Test(arguments: [false, true])
  func readValidationUsesExactLogicalBytesAndPreservesFaults(mmap: Bool) throws {
    let base: UInt64 = 0x123
    let ram = try backing(mmap: mmap, base: base, count: 4097)
    #expect(ram.baseAddress == base && ram.byteCount == 4097)
    #expect(try ram.read(at: base + 4095, byteCount: 2) == [0, 0])
    try ram.write(at: base + 4095, bytes: [0xA5, 0x5A])
    let generation = try ram.codeGeneration(at: base + 4095, byteCount: 2)
    try ram.validateRead(at: base, byteCount: ram.byteCount)
    try ram.validateRead(at: .max, byteCount: 0)
    for count in [Int.min, -1] {
      #expect(throws: DoryX86MemoryError.addressOverflow(address: base, byteCount: count)) {
        try ram.validateRead(at: base, byteCount: count)
      }
    }
    #expect(throws: DoryX86MemoryError.addressOverflow(address: .max, byteCount: 1)) {
      try ram.validateRead(at: .max, byteCount: 1)
    }
    for address in [base - 1, base + 4097] {
      #expect(throws: DoryX86MemoryError.unmapped(address: address, byteCount: 1, access: .read)) {
        try ram.validateRead(at: address, byteCount: 1)
      }
    }
    #expect(throws: DoryX86MemoryError.unmapped(address: base, byteCount: 4098, access: .read)) {
      try ram.validateRead(at: base, byteCount: 4098)
    }
    #expect(try ram.codeGeneration(at: base + 4095, byteCount: 2) == generation)
    #expect(try ram.read(at: base + 4095, byteCount: 2) == [0xA5, 0x5A])
  }

  @Test(arguments: [false, true])
  func DMAReadPreflightDoesNotMaterializeOrReadThePayload(mmap: Bool) throws {
    let memory = BoundaryCountingRAM(try backing(mmap: mmap))
    let bus = try DoryPCPhysicalMemoryBus(ram: memory)
    for sealed in [false, true] {
      if sealed { bus.seal() }
      try bus.validateDMA(at: 0, byteCount: memory.byteCount, deviceWillWrite: false)
      try bus.validateDMA(at: 0, byteCount: memory.byteCount, deviceWillWrite: true)
    }
    #expect(memory.readCalls == 0)
    #expect(memory.readValidations == 2)
    #expect(memory.writeValidations == 2)
  }

  @Test func defaultReadValidationPreservesCustomReadDenial() throws {
    let memory = BoundaryReadDeniedMemory()
    // A writable custom memory object must not acquire read permission through write validation.
    try memory.validateWrite(at: 0, byteCount: 8)
    #expect(throws: DoryX86MemoryError.unmapped(address: 0, byteCount: 8, access: .read)) {
      try memory.validateRead(at: 0, byteCount: 8)
    }
  }

  @Test(arguments: [false, true])
  func sealedBusReleasesItsOwnedBackingAndDevices(mmap: Bool) throws {
    weak var observedRAM: (any DoryX86PhysicalRAM)?
    weak var observedDevice: BoundaryMMIO?
    var retainedBus: DoryPCPhysicalMemoryBus?
    do {
      let ram = try backing(mmap: mmap)
      let device = BoundaryMMIO(baseAddress: 0x1000, byteCount: 0x100)
      let bus = try DoryPCPhysicalMemoryBus(ram: ram)
      try bus.attach(device)
      bus.seal()
      observedRAM = ram
      observedDevice = device
      retainedBus = bus
    }
    #expect(observedRAM != nil && observedDevice != nil)
    withExtendedLifetime(retainedBus) {}
    retainedBus = nil
    #expect(observedRAM == nil && observedDevice == nil)
  }
}

private final class BoundaryMMIO: DoryPCMMIODevice, @unchecked Sendable {
  let baseAddress: UInt64
  let byteCount: UInt64
  let allowsInstructionFetch = true
  private let lock = NSLock()
  private var count = 0
  var accesses: Int { lock.withLock { count } }
  init(baseAddress: UInt64, byteCount: UInt64) {
    self.baseAddress = baseAddress
    self.byteCount = byteCount
  }
  private func record() { lock.withLock { count += 1 } }
  func read(offset: UInt64, byteCount: Int) throws -> [UInt8] {
    record()
    return Array(repeating: 0x90, count: byteCount)
  }
  func readRestartableScalar(offset: UInt64, byteCount: Int) throws -> UInt64? { record(); return 0 }
  func codeGeneration(offset: UInt64, byteCount: Int) throws -> UInt64? { record(); return 0 }
  func write(offset: UInt64, bytes: [UInt8]) throws { record() }
  func validateWrite(offset: UInt64, byteCount: Int) throws { record() }
}

private final class BoundaryCountingRAM: DoryX86PhysicalRAM, @unchecked Sendable {
  let backing: any DoryX86PhysicalRAM
  var baseAddress: UInt64 { backing.baseAddress }
  var byteCount: Int { backing.byteCount }
  private let lock = NSLock()
  private var counts = (reads: 0, readValidations: 0, writeValidations: 0)
  var readCalls: Int { lock.withLock { counts.reads } }
  var readValidations: Int { lock.withLock { counts.readValidations } }
  var writeValidations: Int { lock.withLock { counts.writeValidations } }
  init(_ backing: any DoryX86PhysicalRAM) { self.backing = backing }
  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    lock.withLock { counts.reads += 1 }
    return try backing.read(at: address, byteCount: byteCount)
  }
  func validateRead(at address: UInt64, byteCount: Int) throws {
    lock.withLock { counts.readValidations += 1 }
    try backing.validateRead(at: address, byteCount: byteCount)
  }
  func validateWrite(at address: UInt64, byteCount: Int) throws {
    lock.withLock { counts.writeValidations += 1 }
    try backing.validateWrite(at: address, byteCount: byteCount)
  }
  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    try backing.instructionBytes(at: address, maximumCount: maximumCount)
  }
  func write(at address: UInt64, bytes: [UInt8]) throws { try backing.write(at: address, bytes: bytes) }
  func readRestartableScalar(at address: UInt64, byteCount: Int) throws -> UInt64? {
    try backing.readRestartableScalar(at: address, byteCount: byteCount)
  }
  func codeGeneration(at address: UInt64, byteCount: Int) throws -> UInt64? {
    try backing.codeGeneration(at: address, byteCount: byteCount)
  }
  func bulkCopyRAMSpan(at address: UInt64, maximumByteCount: Int) -> Int? {
    backing.bulkCopyRAMSpan(at: address, maximumByteCount: maximumByteCount)
  }
  func copyForwardNonoverlapping(
    from sourceAddress: UInt64, to destinationAddress: UInt64, maximumByteCount: Int
  ) throws -> Int? {
    try backing.copyForwardNonoverlapping(
      from: sourceAddress, to: destinationAddress, maximumByteCount: maximumByteCount)
  }
}

private final class BoundaryReadDeniedMemory: DoryX86Memory, @unchecked Sendable {
  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    throw DoryX86MemoryError.unmapped(address: address, byteCount: maximumCount, access: .instructionFetch)
  }
  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    throw DoryX86MemoryError.unmapped(address: address, byteCount: byteCount, access: .read)
  }
  func write(at address: UInt64, bytes: [UInt8]) throws {}
  func validateWrite(at address: UInt64, byteCount: Int) throws {}
}
