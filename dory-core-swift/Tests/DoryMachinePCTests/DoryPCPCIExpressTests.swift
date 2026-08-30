import DoryMachinePC
import Foundation
import Testing

@Suite struct DoryPCPCIExpressTests {
  @Test func ecamEnumeratesFunctionsAndReturnsOnesForAbsentDevices() throws {
    let ecam = DoryPCPCIExpressECAM(baseAddress: 0xE000_0000, endBus: 1)
    let function = try DoryPCPCIConfigurationFunction(
      address: .init(bus: 1, device: 3, function: 2),
      vendorID: 0x1AF4,
      deviceID: 0x1042,
      classCode: 0x010000,
      revisionID: 1
    )
    try ecam.attach(function)
    ecam.seal()
    let offset = UInt64(1 << 20 | 3 << 15 | 2 << 12)

    #expect(try ecam.read(offset: offset, byteCount: 4) == [0xF4, 0x1A, 0x42, 0x10])
    #expect(try ecam.read(offset: 0, byteCount: 4) == [0xFF, 0xFF, 0xFF, 0xFF])
    #expect(throws: DoryPCPCIError.sealed) { try ecam.attach(function) }
  }

  @Test func configurationHeaderProtectsIdentityAndAcceptsCommandWrites() throws {
    let function = try DoryPCPCIConfigurationFunction(
      address: .init(bus: 0, device: 1, function: 0),
      vendorID: 0x1AF4,
      deviceID: 0x1041,
      classCode: 0x020000,
      subsystemVendorID: 0x1AF4,
      subsystemID: 1,
      interruptPin: 1
    )

    try function.writeConfiguration(offset: 0, bytes: [0, 0, 0, 0])
    #expect(try function.readConfiguration(offset: 0, byteCount: 4) == [0xF4, 0x1A, 0x41, 0x10])
    try function.writeConfiguration(offset: 4, bytes: [0x07, 0])
    #expect(function.command == 7)
    try function.writeConfiguration(offset: 0x3C, bytes: [0x2A])
    #expect(try function.readConfiguration(offset: 0x3C, byteCount: 2) == [0x2A, 1])
  }

  @Test func barsReportSizingMasksAndAlignGuestAssignments() throws {
    let function = try DoryPCPCIConfigurationFunction(
      address: .init(bus: 0, device: 2, function: 0),
      vendorID: 0x1AF4,
      deviceID: 0x1042,
      classCode: 0x010000,
      bars: [
        .init(index: 0, kind: .memory32(prefetchable: false), size: 0x1000),
        .init(index: 2, kind: .memory64(prefetchable: true), size: 0x20_0000),
        .init(index: 4, kind: .io, size: 0x20),
      ]
    )

    try function.writeConfiguration(offset: 0x10, bytes: [0xFF, 0xFF, 0xFF, 0xFF])
    #expect(read32(try function.readConfiguration(offset: 0x10, byteCount: 4)) == 0xFFFF_F000)
    try function.writeConfiguration(offset: 0x10, bytes: littleEndian(UInt32(0xD000_1234)))
    #expect(try function.bar(at: 0)?.address == 0xD000_1000)

    try function.writeConfiguration(offset: 0x18, bytes: littleEndian(UInt32.max))
    try function.writeConfiguration(offset: 0x1C, bytes: littleEndian(UInt32.max))
    #expect(read32(try function.readConfiguration(offset: 0x18, byteCount: 4)) == 0xFFE0_000C)
    #expect(read32(try function.readConfiguration(offset: 0x1C, byteCount: 4)) == 0xFFFF_FFFF)
    try function.writeConfiguration(offset: 0x18, bytes: littleEndian(UInt32(0x4000_0000)))
    try function.writeConfiguration(offset: 0x1C, bytes: littleEndian(UInt32(1)))
    #expect(try function.bar(at: 2)?.address == 0x1_4000_0000)

    try function.writeConfiguration(offset: 0x20, bytes: littleEndian(UInt32.max))
    #expect(read32(try function.readConfiguration(offset: 0x20, byteCount: 4)) == 0xFFFF_FFE1)
  }

  @Test func machineMapsTheFrozenFullDomainECAMWindow() throws {
    let function = try DoryPCPCIConfigurationFunction(
      address: .init(bus: 0, device: 4, function: 0),
      vendorID: 0x1AF4,
      deviceID: 0x1044,
      classCode: 0x000200
    )
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      pciFunctions: [function]
    )
    let functionAddress = UInt64(4 << 15)
    #expect(
      try machine.physicalMemory.read(
        at: 0xE000_0000 + functionAddress,
        byteCount: 4
      ) == [0xF4, 0x1A, 0x44, 0x10])
    #expect(
      try machine.physicalMemory.read(at: 0xE000_0000, byteCount: 4)
        == [UInt8](repeating: 0xFF, count: 4))
    #expect(machine.pciExpress.byteCount == 256 * 1024 * 1024)
  }

  @Test func msiCapabilityProgramsAndDeliversA64BitFixedMessage() throws {
    let function = try DoryPCPCIConfigurationFunction(
      address: .init(bus: 0, device: 5, function: 0),
      vendorID: 0x1AF4,
      deviceID: 0x1044,
      classCode: 0x000200,
      supportsMSI: true
    )
    let recorder = MSIDeliveryRecorder()
    function.connectMSISink { address, data in
      recorder.append(address: address, data: data)
      return true
    }

    #expect(try function.readConfiguration(offset: 0x34, byteCount: 1) == [0x50])
    #expect(try function.readConfiguration(offset: 0x50, byteCount: 4) == [0x05, 0, 0x80, 0])
    try function.writeConfiguration(offset: 0x54, bytes: littleEndian(UInt32(0xFEE0_0000)))
    try function.writeConfiguration(offset: 0x58, bytes: littleEndian(UInt32(0)))
    try function.writeConfiguration(offset: 0x5C, bytes: [0x52, 0])
    try function.writeConfiguration(offset: 0x52, bytes: [1, 0])

    #expect(function.raiseMSI())
    #expect(function.msiState?.enabled == true)
    #expect(recorder.values == [.init(address: 0xFEE0_0000, data: 0x52)])
  }

  @Test func msixTableMasksQueuesAndDeliversPendingVectors() throws {
    let function = try DoryPCPCIConfigurationFunction(
      address: .init(bus: 0, device: 8, function: 0),
      vendorID: 0x1AF4,
      deviceID: 0x1044,
      classCode: 0x000200,
      supportsMSI: true,
      msiNextCapabilityOffset: 0x60,
      msixVectorCount: 2,
      bars: [
        .init(index: 0, kind: .memory32(prefetchable: false), size: 0x1000)
      ]
    )
    let recorder = MSIDeliveryRecorder()
    function.connectMSISink { address, data in
      recorder.append(address: address, data: data)
      return true
    }

    #expect(try function.readConfiguration(offset: 0x50, byteCount: 2) == [0x05, 0x60])
    #expect(
      try function.readConfiguration(offset: 0x60, byteCount: 12) == [
        0x11, 0, 1, 0, 0, 8, 0, 0, 0, 12, 0, 0,
      ])
    #expect(
      function.writeMSIXBAR(
        bar: 0,
        offset: 0x810,
        bytes: littleEndian(UInt64(0xFEE0_1000))
          + littleEndian(UInt32(0x66))
          + littleEndian(UInt32(0))
      ))
    try function.writeConfiguration(offset: 0x62, bytes: [1, 0x80])

    #expect(function.raiseMSIX(vector: 1))
    #expect(recorder.values == [.init(address: 0xFEE0_1000, data: 0x66)])
    #expect(function.msixState?.enabled == true)
    #expect(function.msixState?.entries[1].masked == false)

    #expect(function.writeMSIXBAR(bar: 0, offset: 0x81C, bytes: littleEndian(UInt32(1))))
    #expect(!function.raiseMSIX(vector: 1))
    #expect(function.msixState?.entries[1].pending == true)
    #expect(function.readMSIXBAR(bar: 0, offset: 0xC00, byteCount: 8) == [2, 0, 0, 0, 0, 0, 0, 0])

    #expect(function.writeMSIXBAR(bar: 0, offset: 0x81C, bytes: littleEndian(UInt32(0))))
    #expect(recorder.values.count == 2)
    #expect(function.msixState?.entries[1].pending == false)
    #expect(!function.raiseMSIX(vector: 2))
  }

  @Test func msixFunctionMaskDefersDeliveryAndSuppressesMSI() throws {
    let function = try makeMSIXFunction(device: 9)
    let recorder = MSIDeliveryRecorder()
    function.connectMSISink { address, data in
      recorder.append(address: address, data: data)
      return true
    }
    #expect(
      function.writeMSIXBAR(
        bar: 0,
        offset: 0x800,
        bytes: littleEndian(UInt64(0xFEE0_0000))
          + littleEndian(UInt32(0x70))
          + littleEndian(UInt32(0))
      ))
    try function.writeConfiguration(offset: 0x54, bytes: littleEndian(UInt32(0xFEE0_0000)))
    try function.writeConfiguration(offset: 0x5C, bytes: [0x71, 0])
    try function.writeConfiguration(offset: 0x52, bytes: [1, 0])
    try function.writeConfiguration(offset: 0x62, bytes: [0, 0xC0])

    #expect(!function.raiseMSI())
    #expect(!function.raiseMSIX(vector: 0))
    #expect(function.msixState?.entries[0].pending == true)
    #expect(recorder.values.isEmpty)

    try function.writeConfiguration(offset: 0x63, bytes: [0x80])
    #expect(recorder.values == [.init(address: 0xFEE0_0000, data: 0x70)])

    try function.writeConfiguration(offset: 0x63, bytes: [0])
    #expect(function.raiseMSI())
    #expect(recorder.values.last == .init(address: 0xFEE0_0000, data: 0x71))
  }

  @Test func msixRejectsMisalignedOrOutOfRangeTableRegions() throws {
    #expect(throws: DoryPCPCIError.invalidMSIXConfiguration) {
      try DoryPCPCIConfigurationFunction(
        address: .init(bus: 0, device: 10, function: 0),
        vendorID: 0x1AF4,
        deviceID: 0x1044,
        classCode: 0x000200,
        msixVectorCount: 2,
        msixTableOffset: 0xFF8,
        bars: [.init(index: 0, kind: .memory32(prefetchable: false), size: 0x1000)]
      )
    }
    #expect(throws: DoryPCPCIError.invalidMSIXConfiguration) {
      try DoryPCPCIConfigurationFunction(
        address: .init(bus: 0, device: 10, function: 0),
        vendorID: 0x1AF4,
        deviceID: 0x1044,
        classCode: 0x000200,
        msixVectorCount: 2,
        msixTableOffset: 0x801,
        bars: [.init(index: 0, kind: .memory32(prefetchable: false), size: 0x1000)]
      )
    }
  }

  @Test func machineRoutesValidMSIMessagesAndRejectsInvalidDeliveryModes() throws {
    let function = try DoryPCPCIConfigurationFunction(
      address: .init(bus: 0, device: 6, function: 0),
      vendorID: 0x1AF4,
      deviceID: 0x1044,
      classCode: 0x000200,
      supportsMSI: true
    )
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      pciFunctions: [function]
    )
    try function.writeConfiguration(offset: 0x54, bytes: littleEndian(UInt32(0xFEE0_0000)))
    try function.writeConfiguration(offset: 0x5C, bytes: [0x61, 0])
    try function.writeConfiguration(offset: 0x52, bytes: [1, 0])

    #expect(function.raiseMSI())
    #expect(machine.localAPIC.snapshot().interruptRequest.contains(0x61))

    try function.writeConfiguration(offset: 0x5C, bytes: [0x62, 1])
    #expect(!function.raiseMSI())
    #expect(!machine.localAPIC.snapshot().interruptRequest.contains(0x62))
  }

  @Test func barWindowFollowsGuestAssignmentsAndMemorySpaceEnable() throws {
    let function = try DoryPCPCIConfigurationFunction(
      address: .init(bus: 0, device: 7, function: 0),
      vendorID: 0x1AF4,
      deviceID: 0x1044,
      classCode: 0x000200,
      bars: [
        .init(index: 0, kind: .memory32(prefetchable: false), size: 0x1000, address: 0xD000_0000)
      ]
    )
    let device = TestBARDevice(configurationFunction: function)
    let window = DoryPCPCIBARWindow()
    try window.attach(device)
    window.seal()

    #expect(throws: (any Error).self) { try window.read(offset: 0x20, byteCount: 4) }
    try function.writeConfiguration(offset: 4, bytes: [2, 0])
    try window.write(offset: 0x20, bytes: [1, 2, 3, 4])
    #expect(try window.read(offset: 0x20, byteCount: 4) == [1, 2, 3, 4])

    try function.writeConfiguration(offset: 0x10, bytes: littleEndian(UInt32(0xD001_0000)))
    #expect(throws: (any Error).self) { try window.read(offset: 0x20, byteCount: 4) }
    #expect(try window.read(offset: 0x1_0020, byteCount: 4) == [1, 2, 3, 4])
  }

  private func read32(_ bytes: [UInt8]) -> UInt32 {
    bytes.enumerated().reduce(0) { $0 | UInt32($1.element) << UInt32($1.offset * 8) }
  }

  private func littleEndian(_ value: UInt32) -> [UInt8] {
    (0..<4).map { UInt8(truncatingIfNeeded: value >> UInt32($0 * 8)) }
  }

  private func littleEndian(_ value: UInt64) -> [UInt8] {
    (0..<8).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
  }

  private func makeMSIXFunction(device: UInt8) throws -> DoryPCPCIConfigurationFunction {
    try DoryPCPCIConfigurationFunction(
      address: .init(bus: 0, device: device, function: 0),
      vendorID: 0x1AF4,
      deviceID: 0x1044,
      classCode: 0x000200,
      supportsMSI: true,
      msiNextCapabilityOffset: 0x60,
      msixVectorCount: 2,
      bars: [.init(index: 0, kind: .memory32(prefetchable: false), size: 0x1000)]
    )
  }
}

private struct MSIDelivery: Sendable, Hashable {
  let address: UInt64
  let data: UInt16
}

private final class MSIDeliveryRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [MSIDelivery] = []

  var values: [MSIDelivery] { lock.withLock { storage } }

  func append(address: UInt64, data: UInt16) {
    lock.withLock { storage.append(.init(address: address, data: data)) }
  }
}

private final class TestBARDevice: DoryPCPCIBARMemoryDevice, @unchecked Sendable {
  let configurationFunction: DoryPCPCIConfigurationFunction
  let barIndex = 0
  private let lock = NSLock()
  private var bytes = [UInt8](repeating: 0, count: 0x1000)

  init(configurationFunction: DoryPCPCIConfigurationFunction) {
    self.configurationFunction = configurationFunction
  }

  func readBAR(offset: UInt64, byteCount: Int) throws -> [UInt8] {
    lock.withLock { Array(bytes[Int(offset)..<(Int(offset) + byteCount)]) }
  }

  func writeBAR(offset: UInt64, bytes: [UInt8]) throws {
    lock.withLock {
      self.bytes.replaceSubrange(Int(offset)..<(Int(offset) + bytes.count), with: bytes)
    }
  }
}
