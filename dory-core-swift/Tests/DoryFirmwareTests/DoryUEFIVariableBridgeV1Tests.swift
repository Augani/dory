import DoryFirmware
import DoryMachineARMVirt
import Foundation
import Testing

@Suite struct DoryUEFIVariableBridgeV1Tests {
  @Test func ABIIsFrozenInsideTheReservedVariableWindow() throws {
    try DoryUEFIVariableBridgeV1ABI.validateLayout()
    #expect(DoryUEFIVariableBridgeV1ABI.identity == "dory.uefi.variable-bridge.armvirt@1")
    #expect(DoryUEFIVariableBridgeV1ABI.magic == 0x3152_4156_5952_4f44)
    #expect(DoryUEFIVariableBridgeV1ABI.baseAddress == DoryARMVirtV1ABI.firmwareVariableBase)
    #expect(DoryUEFIVariableBridgeV1ABI.byteCount == DoryARMVirtV1ABI.firmwareVariableBytes)
    #expect(
      DoryUEFIVariableBridgeV1ABI.dataOffset
        + UInt64(DoryUEFIVariableBridgeV1ABI.dataByteCount)
        <= DoryUEFIVariableBridgeV1ABI.byteCount
    )
  }

  @Test func servicePersistsSetGetEnumerateAndDelete() throws {
    let fixture = try StoreFixture()
    defer { fixture.remove() }
    let service = DoryUEFIVariableBridgeService(store: fixture.store)
    let firstVendor = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let secondVendor = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    let firstSet = service.execute(.init(
      command: .set,
      vendor: firstVendor,
      name: "BootOrder",
      attributes: [.nonVolatile, .bootServiceAccess],
      data: Data([0, 1])
    ))
    #expect(firstSet.status == .success)
    #expect(firstSet.generation == 2)

    let secondSet = service.execute(.init(
      command: .set,
      vendor: secondVendor,
      name: "DoryRecovery",
      attributes: [.nonVolatile, .runtimeAccess],
      data: Data([1])
    ))
    #expect(secondSet.status == .success)
    #expect(secondSet.generation == 3)

    let get = service.execute(.init(command: .get, vendor: firstVendor, name: "BootOrder"))
    #expect(get.status == .success)
    #expect(get.variable?.data == Data([0, 1]))
    #expect(service.execute(.init(command: .first)).variable?.key.vendor == firstVendor)
    #expect(
      service.execute(.init(command: .next, vendor: firstVendor, name: "BootOrder"))
        .variable?.key.vendor == secondVendor
    )

    let deleted = service.execute(.init(
      command: .delete,
      vendor: firstVendor,
      name: "BootOrder"
    ))
    #expect(deleted.status == .success)
    #expect(deleted.generation == 4)
    #expect(
      service.execute(.init(command: .get, vendor: firstVendor, name: "BootOrder")).status
        == .notFound
    )
  }

  @Test func invalidRequestsAndRecoveryAreExplicitStatuses() throws {
    let fixture = try StoreFixture()
    defer { fixture.remove() }
    let service = DoryUEFIVariableBridgeService(store: fixture.store)
    #expect(service.execute(.init(command: .get)).status == .invalidRequest)
    #expect(
      service.execute(.init(
        command: .set,
        vendor: UUID(),
        name: "Broken",
        attributes: [],
        data: Data()
      )).status == .invalidRequest
    )

    #expect(service.execute(.init(
      command: .set,
      vendor: UUID(),
      name: "RecoverySeed",
      attributes: [.nonVolatile],
      data: Data([1])
    )).status == .success)
    let primary = try FileHandle(forWritingTo: URL(fileURLWithPath: fixture.store.primaryPath))
    try primary.truncate(atOffset: 0)
    try primary.write(contentsOf: Data("corrupt\n".utf8))
    try primary.close()
    #expect(service.execute(.init(command: .first)).status == .recoveryRequired)
  }
}

private final class StoreFixture {
  let directory: String
  let store: DoryUEFIVariableStoreFile

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("dory-uefi-bridge-\(UUID().uuidString)", isDirectory: true).path
    store = try DoryUEFIVariableStoreFile(directory: directory)
    try store.initialize(DoryUEFIVariableStoreSnapshot())
  }

  func remove() {
    try? FileManager.default.removeItem(atPath: directory)
  }
}
