import DoryDBTX86
import DoryFirmware
import DoryMachinePC
import Foundation
import Testing

@Suite struct DoryPCUEFIVariableBridgeMMIOTests {
  @Test func executesPersistentVariableRequestsThroughThePCPhysicalBus() throws {
    let fixture = try PCBridgeStoreFixture(platform: .pcV1)
    defer { fixture.remove() }
    let device = try DoryPCUEFIVariableBridgeMMIO(
      service: DoryUEFIVariableBridgeService(store: fixture.store)
    )
    let bus = DoryPCPhysicalMemoryBus(ram: DoryX86ByteArrayMemory(byteCount: 1 << 20))
    try bus.attach(device)
    bus.seal()
    let base = DoryPCV1ABI.firmwareVariableBase

    #expect(
      try readUInt64(bus, base + DoryUEFIVariableBridgeV1ABI.magicOffset) == 0x3152_4156_5952_4f44)
    #expect(try readUInt32(bus, base + DoryUEFIVariableBridgeV1ABI.versionOffset) == 1)
    #expect(
      try readUInt32(bus, base + DoryUEFIVariableBridgeV1ABI.statusOffset)
        == DoryUEFIVariableBridgeStatus.idle.rawValue
    )

    let vendor = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
    let name = Array("BootOrder".utf8)
    let data: [UInt8] = [0, 1]
    try bus.write(
      at: base + DoryUEFIVariableBridgeV1ABI.vendorOffset,
      bytes: uuidBytes(vendor)
    )
    try bus.write(at: base + DoryUEFIVariableBridgeV1ABI.nameOffset, bytes: name)
    try bus.write(at: base + DoryUEFIVariableBridgeV1ABI.dataOffset, bytes: data)
    try writeUInt32(
      bus,
      base + DoryUEFIVariableBridgeV1ABI.nameLengthOffset,
      UInt32(name.count)
    )
    try writeUInt32(
      bus,
      base + DoryUEFIVariableBridgeV1ABI.dataLengthOffset,
      UInt32(data.count)
    )
    try writeUInt32(
      bus,
      base + DoryUEFIVariableBridgeV1ABI.attributesOffset,
      DoryUEFIVariableAttributes.nonVolatile.union(.bootServiceAccess).rawValue
    )
    try writeUInt32(
      bus,
      base + DoryUEFIVariableBridgeV1ABI.commandOffset,
      DoryUEFIVariableBridgeCommand.set.rawValue
    )

    #expect(
      try readUInt32(bus, base + DoryUEFIVariableBridgeV1ABI.statusOffset)
        == DoryUEFIVariableBridgeStatus.success.rawValue
    )
    #expect(try readUInt64(bus, base + DoryUEFIVariableBridgeV1ABI.generationOffset) == 2)
    let persisted = try fixture.store.load().snapshot
    #expect(persisted.platform == .pcV1)
    #expect(persisted.variables.first?.key.vendor == vendor)
    #expect(persisted.variables.first?.key.name == "BootOrder")
    #expect(persisted.variables.first?.data == Data(data))

    try writeUInt32(bus, base + DoryUEFIVariableBridgeV1ABI.dataLengthOffset, 0)
    try writeUInt32(
      bus,
      base + DoryUEFIVariableBridgeV1ABI.commandOffset,
      DoryUEFIVariableBridgeCommand.get.rawValue
    )
    #expect(try readUInt32(bus, base + DoryUEFIVariableBridgeV1ABI.dataLengthOffset) == 2)
    #expect(
      try bus.read(at: base + DoryUEFIVariableBridgeV1ABI.dataOffset, byteCount: 2) == data
    )
  }

  @Test func rejectsReadOnlyWritesAndReportsMalformedRequestsToTheGuest() throws {
    let fixture = try PCBridgeStoreFixture(platform: .pcV1)
    defer { fixture.remove() }
    let device = try DoryPCUEFIVariableBridgeMMIO(
      service: DoryUEFIVariableBridgeService(store: fixture.store)
    )

    #expect(throws: DoryPCPhysicalMemoryError.self) {
      try device.write(
        offset: DoryUEFIVariableBridgeV1ABI.statusOffset,
        bytes: littleEndianBytes(UInt32(1))
      )
    }
    try device.write(
      offset: DoryUEFIVariableBridgeV1ABI.nameLengthOffset,
      bytes: littleEndianBytes(UInt32(DoryUEFIVariableBridgeV1ABI.nameByteCount + 1))
    )
    try device.write(
      offset: DoryUEFIVariableBridgeV1ABI.commandOffset,
      bytes: littleEndianBytes(DoryUEFIVariableBridgeCommand.get.rawValue)
    )
    #expect(
      try readUInt32(device, DoryUEFIVariableBridgeV1ABI.statusOffset)
        == DoryUEFIVariableBridgeStatus.invalidRequest.rawValue
    )
    #expect(try fixture.store.load().snapshot.generation == 1)
  }

  @Test func rejectsAnARMVariableStoreAtThePCBinding() throws {
    let fixture = try PCBridgeStoreFixture(platform: .armVirtV1)
    defer { fixture.remove() }
    #expect(
      throws: DoryPCUEFIVariableBridgeMMIOError.incompatibleVariableStorePlatform(.armVirtV1)
    ) {
      _ = try DoryPCUEFIVariableBridgeMMIO(
        service: DoryUEFIVariableBridgeService(store: fixture.store)
      )
    }
  }
}

private final class PCBridgeStoreFixture {
  let directory: String
  let store: DoryUEFIVariableStoreFile

  init(platform: DoryFirmwarePlatform) throws {
    directory =
      FileManager.default.temporaryDirectory
      .appendingPathComponent("dory-pc-uefi-bridge-\(UUID().uuidString)", isDirectory: true).path
    store = try DoryUEFIVariableStoreFile(directory: directory)
    try store.initialize(DoryUEFIVariableStoreSnapshot(platform: platform))
  }

  func remove() { try? FileManager.default.removeItem(atPath: directory) }
}

private func littleEndianBytes(_ value: UInt32) -> [UInt8] {
  (0..<4).map { UInt8(truncatingIfNeeded: value >> UInt32($0 * 8)) }
}

private func uuidBytes(_ uuid: UUID) -> [UInt8] {
  withUnsafeBytes(of: uuid.uuid) { Array($0) }
}

private func writeUInt32(_ bus: DoryPCPhysicalMemoryBus, _ address: UInt64, _ value: UInt32) throws
{
  try bus.write(at: address, bytes: littleEndianBytes(value))
}

private func readUInt32(_ bus: DoryPCPhysicalMemoryBus, _ address: UInt64) throws -> UInt32 {
  try decodeUInt32(bus.read(at: address, byteCount: 4))
}

private func readUInt64(_ bus: DoryPCPhysicalMemoryBus, _ address: UInt64) throws -> UInt64 {
  try decodeUInt64(bus.read(at: address, byteCount: 8))
}

private func readUInt32(_ device: DoryPCUEFIVariableBridgeMMIO, _ offset: UInt64) throws -> UInt32 {
  try decodeUInt32(device.read(offset: offset, byteCount: 4))
}

private func decodeUInt32(_ bytes: [UInt8]) throws -> UInt32 {
  guard bytes.count == 4 else {
    throw DoryPCPhysicalMemoryError.unsupportedAccess(
      offset: 0, byteCount: bytes.count, write: false)
  }
  return bytes.enumerated().reduce(into: 0) {
    $0 |= UInt32($1.element) << UInt32($1.offset * 8)
  }
}

private func decodeUInt64(_ bytes: [UInt8]) throws -> UInt64 {
  guard bytes.count == 8 else {
    throw DoryPCPhysicalMemoryError.unsupportedAccess(
      offset: 0, byteCount: bytes.count, write: false)
  }
  return bytes.enumerated().reduce(into: 0) {
    $0 |= UInt64($1.element) << UInt64($1.offset * 8)
  }
}
