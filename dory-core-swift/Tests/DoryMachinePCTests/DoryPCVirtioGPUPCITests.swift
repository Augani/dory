import DoryMachinePC
import DoryVirtio
import Foundation
import Testing

@Suite struct DoryPCVirtioGPUPCITests {
  @Test func dynamicModePublishesDisplayEventAndGuestCanClearIt() throws {
    let gpu = try DoryPCVirtioGPUPCIDevice(
      address: DoryPCV1ABI.displayPCIAddress,
      initialBARAddress: DoryPCV1ABI.displayBARAddress,
      scanouts: [
        .init(id: 0, rectangle: .init(x: 0, y: 0, width: 1_280, height: 800))
      ]
    )
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      pciFunctions: [gpu]
    )
    try gpu.writeConfiguration(offset: 4, bytes: [2, 0])
    try gpu.writeConfiguration(offset: 0x54, bytes: littleEndian(UInt32(0xFEE0_0000)))
    try gpu.writeConfiguration(offset: 0x5C, bytes: [0x79, 0])
    try gpu.writeConfiguration(offset: 0x52, bytes: [1, 0])

    #expect(gpu.updateScanoutSize(scanoutID: 0, width: 2_560, height: 1_440))
    #expect(!gpu.updateScanoutSize(scanoutID: 0, width: 2_560, height: 1_440))
    #expect(!gpu.updateScanoutSize(scanoutID: 1, width: 2_560, height: 1_440))
    let bar = DoryPCV1ABI.displayBARAddress
    let published = try machine.physicalMemory.read(at: bar + 0x300, byteCount: 16)
    #expect(read32(published, 0) == 1)
    #expect(read32(published, 8) == 1)
    #expect(gpu.gpuDevice.scanouts[0].rectangle.width == 2_560)
    #expect(gpu.gpuDevice.scanouts[0].rectangle.height == 1_440)
    #expect(machine.localAPIC.snapshot().interruptRequest.contains(0x79))

    try write32(machine, bar + 0x304, 1)
    let cleared = try machine.physicalMemory.read(at: bar + 0x300, byteCount: 16)
    #expect(read32(cleared, 0) == 0)
    #expect(read32(cleared, 4) == 0)
  }

  @Test func pciQueueReturnsDisplayInfoAndRaisesMSI() throws {
    let gpu = try DoryPCVirtioGPUPCIDevice(
      address: DoryPCV1ABI.displayPCIAddress,
      initialBARAddress: DoryPCV1ABI.displayBARAddress,
      scanouts: [
        .init(id: 0, rectangle: .init(x: 0, y: 0, width: 1_920, height: 1_080))
      ]
    )
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      pciFunctions: [gpu]
    )
    #expect(try gpu.readConfiguration(offset: 0, byteCount: 4) == [0xF4, 0x1A, 0x50, 0x10])
    #expect(try gpu.readConfiguration(offset: 9, byteCount: 3) == [0, 0x80, 3])
    try gpu.writeConfiguration(offset: 4, bytes: [2, 0])
    try gpu.writeConfiguration(offset: 0x54, bytes: littleEndian(UInt32(0xFEE0_0000)))
    try gpu.writeConfiguration(offset: 0x5C, bytes: [0x78, 0])
    try gpu.writeConfiguration(offset: 0x52, bytes: [1, 0])

    let bar = DoryPCV1ABI.displayBARAddress
    try write32(machine, bar + 0x08, 1)
    try write32(machine, bar + 0x0C, 1)
    try write8(machine, bar + 0x14, 0x0F)
    try write16(machine, bar + 0x16, 0)
    try write16(machine, bar + 0x18, 8)
    try write64(machine, bar + 0x20, 0x1000)
    try write64(machine, bar + 0x28, 0x2000)
    try write64(machine, bar + 0x30, 0x3000)
    try write16(machine, bar + 0x1C, 1)

    try writeDescriptor(machine, at: 0x1000, address: 0x4000, length: 24, flags: 1, next: 1)
    try writeDescriptor(machine, at: 0x1010, address: 0x5000, length: 408, flags: 2, next: 0)
    try machine.physicalMemory.write(
      at: 0x4000,
      bytes: littleEndian(UInt32(0x0100)) + [UInt8](repeating: 0, count: 20)
    )
    try machine.physicalMemory.write(at: 0x2000, bytes: [0, 0, 1, 0, 0, 0])

    try write16(machine, bar + 0x100, 0)

    let response = try machine.physicalMemory.read(at: 0x5000, byteCount: 408)
    #expect(read32(response, 0) == 0x1101)
    #expect(read32(response, 32) == 1_920)
    #expect(read32(response, 36) == 1_080)
    #expect(read32(response, 40) == 1)
    #expect(read16(try machine.physicalMemory.read(at: 0x3002, byteCount: 2)) == 1)
    #expect(read32(try machine.physicalMemory.read(at: 0x3008, byteCount: 4)) == 408)
    #expect(machine.localAPIC.snapshot().interruptRequest.contains(0x78))
  }

  @Test func fencedAcceleratedSubmitPublishesUsedElementAfterFenceSignal() throws {
    let authority = try PCIGPUAccelerationAuthority(
      features: [.gpuVirgl, .gpuContextInit],
      capsets: [.init(id: 2, maximumVersion: 2, data: [1])]
    )
    let gpu = try DoryPCVirtioGPUPCIDevice(
      address: DoryPCV1ABI.displayPCIAddress,
      initialBARAddress: DoryPCV1ABI.displayBARAddress,
      scanouts: [.init(id: 0, rectangle: .init(x: 0, y: 0, width: 800, height: 600))],
      accelerationAuthority: authority
    )
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      pciFunctions: [gpu]
    )
    try gpu.writeConfiguration(offset: 4, bytes: [2, 0])
    try gpu.writeConfiguration(offset: 0x54, bytes: littleEndian(UInt32(0xFEE0_0000)))
    try gpu.writeConfiguration(offset: 0x5C, bytes: [0x78, 0])
    try gpu.writeConfiguration(offset: 0x52, bytes: [1, 0])

    let bar = DoryPCV1ABI.displayBARAddress
    try configureQueue(machine, bar: bar)

    let contextID: UInt32 = 17
    var contextName = [UInt8](repeating: 0, count: 64)
    contextName.replaceSubrange(0..<4, with: Array("mesa".utf8))
    let createContext =
      gpuHeader(0x0200, contextID: contextID) + littleEndian(UInt32(4))
      + littleEndian(UInt32(2)) + contextName
    try publishGPUCommand(
      machine,
      bar: bar,
      descriptorIndex: 0,
      availableIndex: 1,
      requestAddress: 0x4000,
      responseAddress: 0x5000,
      request: createContext
    )
    #expect(read32(try machine.physicalMemory.read(at: 0x5000, byteCount: 24)) == 0x1100)
    #expect(read16(try machine.physicalMemory.read(at: 0x3002, byteCount: 2)) == 1)

    let submit =
      gpuHeader(0x0207, flags: 3, fence: 0, contextID: contextID, ringIndex: 2)
      + littleEndian(UInt32(4)) + littleEndian(UInt32(0))
      + [0xAA, 0xBB, 0xCC, 0xDD]
    try publishGPUCommand(
      machine,
      bar: bar,
      descriptorIndex: 2,
      availableIndex: 2,
      requestAddress: 0x4200,
      responseAddress: 0x5100,
      request: submit
    )

    #expect(read16(try machine.physicalMemory.read(at: 0x3002, byteCount: 2)) == 1)
    #expect(authority.operations == ["context-create:17:2:mesa", "submit-fenced:17:4:17:2:0:true"])
    authority.completeFence(at: 0, with: .signaled)

    let response = try machine.physicalMemory.read(at: 0x5100, byteCount: 24)
    #expect(read32(response) == 0x1100)
    #expect(read32(response, 4) == 3)
    #expect(read64(response, 8) == 0)
    #expect(read32(response, 16) == contextID)
    #expect(response[20] == 2)
    #expect(read16(try machine.physicalMemory.read(at: 0x3002, byteCount: 2)) == 2)
    #expect(read32(try machine.physicalMemory.read(at: 0x3008, byteCount: 4)) == 24)
    #expect(machine.localAPIC.snapshot().interruptRequest.contains(0x78))
  }

  private func configureQueue(_ machine: DoryPCDirectKernelMachine, bar: UInt64) throws {
    try write32(machine, bar + 0x08, 1)
    try write32(machine, bar + 0x0C, 1)
    try write8(machine, bar + 0x14, 0x0F)
    try write16(machine, bar + 0x16, 0)
    try write16(machine, bar + 0x18, 8)
    try write64(machine, bar + 0x20, 0x1000)
    try write64(machine, bar + 0x28, 0x2000)
    try write64(machine, bar + 0x30, 0x3000)
    try write16(machine, bar + 0x1C, 1)
  }

  private func publishGPUCommand(
    _ machine: DoryPCDirectKernelMachine,
    bar: UInt64,
    descriptorIndex: UInt16,
    availableIndex: UInt16,
    requestAddress: UInt64,
    responseAddress: UInt64,
    request: [UInt8],
    responseByteCount: UInt32 = 24
  ) throws {
    try writeDescriptor(
      machine,
      at: 0x1000 + UInt64(descriptorIndex) * 16,
      address: requestAddress,
      length: UInt32(request.count),
      flags: 1,
      next: descriptorIndex + 1
    )
    try writeDescriptor(
      machine,
      at: 0x1000 + UInt64(descriptorIndex + 1) * 16,
      address: responseAddress,
      length: responseByteCount,
      flags: 2,
      next: 0
    )
    try machine.physicalMemory.write(at: requestAddress, bytes: request)
    try machine.physicalMemory.write(at: responseAddress, bytes: [UInt8](repeating: 0, count: Int(responseByteCount)))
    let slot = UInt64((availableIndex - 1) % 8)
    try machine.physicalMemory.write(at: 0x2004 + slot * 2, bytes: littleEndian(descriptorIndex))
    try machine.physicalMemory.write(at: 0x2002, bytes: littleEndian(availableIndex))
    try write16(machine, bar + 0x100, 0)
  }

  private func gpuHeader(
    _ command: UInt32,
    flags: UInt32 = 0,
    fence: UInt64 = 0,
    contextID: UInt32 = 0,
    ringIndex: UInt8 = 0
  ) -> [UInt8] {
    littleEndian(command) + littleEndian(flags) + littleEndian(fence)
      + littleEndian(contextID) + [ringIndex, 0, 0, 0]
  }

  @Test func oversizedDeferredGPUResponseMarksDeviceNeedsResetWithoutPublishingUsedRing() throws {
    let gpu = try DoryPCVirtioGPUPCIDevice(
      address: DoryPCV1ABI.displayPCIAddress,
      initialBARAddress: DoryPCV1ABI.displayBARAddress,
      scanouts: [.init(id: 0, rectangle: .init(x: 0, y: 0, width: 1_920, height: 1_080))]
    )
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      pciFunctions: [gpu]
    )
    try gpu.writeConfiguration(offset: 4, bytes: [2, 0])
    let bar = DoryPCV1ABI.displayBARAddress
    try configureQueue(machine, bar: bar)

    try publishGPUCommand(
      machine,
      bar: bar,
      descriptorIndex: 0,
      availableIndex: 1,
      requestAddress: 0x4000,
      responseAddress: 0x5000,
      request: gpuHeader(0x0100),
      responseByteCount: 24
    )

    #expect(try machine.physicalMemory.read(at: 0x5000, byteCount: 4) == [0, 0, 0, 0])
    #expect(read16(try machine.physicalMemory.read(at: 0x3002, byteCount: 2)) == 0)
    #expect(gpu.transport.deviceState.snapshot().status.contains(.deviceNeedsReset))
  }

  private func writeDescriptor(
    _ machine: DoryPCDirectKernelMachine,
    at tableAddress: UInt64,
    address: UInt64,
    length: UInt32,
    flags: UInt16,
    next: UInt16
  ) throws {
    try machine.physicalMemory.write(
      at: tableAddress,
      bytes: littleEndian(address) + littleEndian(length) + littleEndian(flags) + littleEndian(next)
    )
  }

  private func write8(_ machine: DoryPCDirectKernelMachine, _ address: UInt64, _ value: UInt8)
    throws
  {
    try machine.physicalMemory.write(at: address, bytes: [value])
  }

  private func write16(_ machine: DoryPCDirectKernelMachine, _ address: UInt64, _ value: UInt16)
    throws
  {
    try machine.physicalMemory.write(at: address, bytes: littleEndian(value))
  }

  private func write32(_ machine: DoryPCDirectKernelMachine, _ address: UInt64, _ value: UInt32)
    throws
  {
    try machine.physicalMemory.write(at: address, bytes: littleEndian(value))
  }

  private func write64(_ machine: DoryPCDirectKernelMachine, _ address: UInt64, _ value: UInt64)
    throws
  {
    try machine.physicalMemory.write(at: address, bytes: littleEndian(value))
  }
}

private func read16(_ bytes: [UInt8]) -> UInt16 {
  UInt16(bytes[0]) | UInt16(bytes[1]) << 8
}

private func read32(_ bytes: [UInt8], _ offset: Int = 0) -> UInt32 {
  (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << UInt32($1 * 8) }
}

private func read64(_ bytes: [UInt8], _ offset: Int = 0) -> UInt64 {
  (0..<8).reduce(0) { $0 | UInt64(bytes[offset + $1]) << UInt64($1 * 8) }
}

private func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
  (0..<MemoryLayout<T>.size).map { UInt8(truncatingIfNeeded: value >> T($0 * 8)) }
}

private final class PCIGPUAccelerationAuthority: DoryVirtioGPUAccelerationAuthority, @unchecked Sendable {
  let capabilities: DoryVirtioGPUAccelerationCapabilities
  private let lock = NSLock()
  private var operationStorage: [String] = []
  private var fenceCompletions: [@Sendable (DoryVirtioGPUFenceCompletion) -> Void] = []

  var operations: [String] { lock.withLock { operationStorage } }

  init(features: DoryVirtioFeatures, capsets: [DoryVirtioGPUCapset]) throws {
    capabilities = try .init(features: features, capsets: capsets)
  }

  func reset() {}

  func createContext(id: UInt32, capsetID: UInt32, name: String) {
    record("context-create:\(id):\(capsetID):\(name)")
  }

  func destroyContext(id: UInt32) { record("context-destroy:\(id)") }
  func attachResource(contextID: UInt32, resourceID: UInt32) {
    record("resource-attach:\(contextID):\(resourceID)")
  }
  func detachResource(contextID: UInt32, resourceID: UInt32) {
    record("resource-detach:\(contextID):\(resourceID)")
  }

  func submit3D(contextID: UInt32, command: [UInt8]) {
    record("submit:\(contextID):\(command.count)")
  }

  func submit3D(
    contextID: UInt32,
    command: [UInt8],
    fence: DoryVirtioGPUFenceRequest,
    completion: @escaping @Sendable (DoryVirtioGPUFenceCompletion) -> Void
  ) {
    lock.withLock { fenceCompletions.append(completion) }
    record(
      "submit-fenced:\(contextID):\(command.count):\(fence.contextID):"
        + "\(fence.ringIndex):\(fence.fenceID):\(fence.contextFence)"
    )
  }

  func createFence(
    _ fence: DoryVirtioGPUFenceRequest,
    completion: @escaping @Sendable (DoryVirtioGPUFenceCompletion) -> Void
  ) {
    lock.withLock { fenceCompletions.append(completion) }
    record("fence:\(fence.contextID):\(fence.ringIndex):\(fence.fenceID):\(fence.contextFence)")
  }

  func completeFence(at index: Int, with result: DoryVirtioGPUFenceCompletion) {
    let completion = lock.withLock { fenceCompletions.remove(at: index) }
    completion(result)
  }

  func createResource3D(_ resource: DoryVirtioGPUResource3D) {
    record("resource-create:\(resource.resourceID)")
  }
  func attachBacking(resourceID: UInt32, entries: [DoryVirtioGPUBackingEntry], memory: any DoryVirtioGuestMemory) {}
  func detachBacking(resourceID: UInt32) {}
  func transfer3D(_ transfer: DoryVirtioGPUTransfer3D, entries: [DoryVirtioGPUBackingEntry], memory: any DoryVirtioGuestMemory) {}
  func flush(_ flush: DoryVirtioGPUAcceleratedScanoutFlush) {}
  func unrefResource(id: UInt32) {}

  private func record(_ operation: String) { lock.withLock { operationStorage.append(operation) } }
}
