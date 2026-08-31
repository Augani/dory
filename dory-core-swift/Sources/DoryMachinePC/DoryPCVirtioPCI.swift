import DoryVirtio
import Foundation

public enum DoryPCVirtioPCIError: Error, Sendable, Equatable {
  case invalidQueueCount(Int)
  case invalidBARAccess(offset: UInt64, byteCount: Int, write: Bool)
  case invalidQueue(UInt16)
}

public protocol DoryPCVirtioGuestMemoryConsumer: AnyObject, Sendable {
  func connectGuestMemory(_ memory: any DoryVirtioGuestMemory)
}

public enum DoryPCVirtioPCIInterrupt: Sendable, Hashable {
  case queue(UInt16)
  case configuration
}

public struct DoryPCVirtioPCIQueueSnapshot: Sendable, Hashable {
  public let size: UInt16
  public let enabled: Bool
  public let msixVector: UInt16
  public let notifyOffset: UInt16
  public let descriptorAddress: UInt64
  public let driverAddress: UInt64
  public let deviceAddress: UInt64
}

/// VirtIO 1.x PCI common configuration and BAR regions shared by every Dory PCI device model.
public final class DoryPCVirtioPCITransport: @unchecked Sendable {
  private struct QueueRegisters {
    var size: UInt16
    var enabled = false
    var msixVector: UInt16 = .max
    let notifyOffset: UInt16
    var descriptorAddress: UInt64 = 0
    var driverAddress: UInt64 = 0
    var deviceAddress: UInt64 = 0
    let queue: DoryVirtioSplitQueue
  }

  public let deviceState: DoryVirtioDeviceState
  public let queueCount: Int
  public let msixVectorCount: Int

  private let lock = NSLock()
  private var deviceFeatureSelect: UInt32 = 0
  private var driverFeatureSelect: UInt32 = 0
  private var configurationMSIXVector: UInt16 = .max
  private var selectedQueue: UInt16 = 0
  private var queues: [QueueRegisters]
  private var isrStatus: UInt8 = 0
  private var deviceConfiguration: [UInt8]
  private var notifySink: (@Sendable (UInt16) -> Void)?
  private var interruptSink: (@Sendable (DoryPCVirtioPCIInterrupt) -> Bool)?
  private var guestMemory: (any DoryVirtioGuestMemory)?
  private var queueProcessor:
    (@Sendable (UInt16, DoryVirtioDescriptorChain, any DoryVirtioGuestMemory) throws -> UInt32)?
  private var queueCanProcess: @Sendable (UInt16) -> Bool = { _ in true }
  private let processingLocks: [NSLock]

  public init(
    queueCount: Int,
    maximumQueueSize: UInt16 = 256,
    msixVectorCount: Int = 2048,
    offeredFeatures: DoryVirtioFeatures,
    deviceConfiguration: [UInt8] = [],
    onReset: @escaping @Sendable () -> Void = {}
  ) throws {
    guard (1...65_535).contains(queueCount) else {
      throw DoryPCVirtioPCIError.invalidQueueCount(queueCount)
    }
    guard (1...2048).contains(msixVectorCount) else {
      throw DoryPCVirtioPCIError.invalidQueueCount(msixVectorCount)
    }
    self.queueCount = queueCount
    self.msixVectorCount = msixVectorCount
    deviceState = .init(offeredFeatures: offeredFeatures, onReset: onReset)
    queues = (0..<queueCount).map {
      .init(
        size: maximumQueueSize,
        notifyOffset: UInt16(truncatingIfNeeded: $0),
        queue: .init(maximumSize: maximumQueueSize)
      )
    }
    processingLocks = (0..<queueCount).map { _ in NSLock() }
    self.deviceConfiguration = deviceConfiguration
  }

  public func connectNotifySink(_ sink: @escaping @Sendable (UInt16) -> Void) {
    lock.withLock { notifySink = sink }
  }

  public func connectInterruptSink(
    _ sink: @escaping @Sendable (DoryPCVirtioPCIInterrupt) -> Bool
  ) {
    lock.withLock { interruptSink = sink }
  }

  public func connectQueueProcessor(
    memory: any DoryVirtioGuestMemory,
    canProcess: @escaping @Sendable (UInt16) -> Bool = { _ in true },
    processor:
      @escaping @Sendable (
        UInt16,
        DoryVirtioDescriptorChain,
        any DoryVirtioGuestMemory
      ) throws -> UInt32
  ) {
    lock.withLock {
      guestMemory = memory
      queueCanProcess = canProcess
      queueProcessor = processor
    }
  }

  /// Rechecks a queue after host-side work becomes available, such as an inbound network frame.
  public func processQueue(_ index: UInt16) {
    guard Int(index) < queueCount else { return }
    drain(queue: index)
  }

  public func queue(at index: UInt16) throws -> DoryVirtioSplitQueue {
    try lock.withLock {
      guard queues.indices.contains(Int(index)) else {
        throw DoryPCVirtioPCIError.invalidQueue(index)
      }
      return queues[Int(index)].queue
    }
  }

  public func queueSnapshot(at index: UInt16) throws -> DoryPCVirtioPCIQueueSnapshot {
    try lock.withLock {
      guard queues.indices.contains(Int(index)) else {
        throw DoryPCVirtioPCIError.invalidQueue(index)
      }
      let queue = queues[Int(index)]
      return .init(
        size: queue.size,
        enabled: queue.enabled,
        msixVector: queue.msixVector,
        notifyOffset: queue.notifyOffset,
        descriptorAddress: queue.descriptorAddress,
        driverAddress: queue.driverAddress,
        deviceAddress: queue.deviceAddress
      )
    }
  }

  @discardableResult
  public func signalQueueInterrupt(queue: UInt16? = nil) -> Bool {
    let delivery = lock.withLock {
      isrStatus |= 1
      return (interruptSink, queue ?? selectedQueue)
    }
    return delivery.0?(.queue(delivery.1)) ?? false
  }

  public func signalConfigurationChange() {
    let sink = lock.withLock {
      isrStatus |= 2
      return interruptSink
    }
    _ = sink?(.configuration)
  }

  public func updateDeviceConfiguration(_ bytes: [UInt8], signalChange: Bool = true) {
    let changed = lock.withLock {
      guard deviceConfiguration != bytes else { return false }
      deviceConfiguration = bytes
      return true
    }
    guard changed else { return }
    deviceState.configurationDidChange()
    if signalChange { signalConfigurationChange() }
  }

  /// Restores read-only/write-only device configuration semantics after a guest write without
  /// manufacturing a host-side configuration generation change.
  public func normalizeDeviceConfigurationAfterGuestWrite(_ bytes: [UInt8]) {
    lock.withLock { deviceConfiguration = bytes }
  }

  public func readBAR(offset: UInt64, byteCount: Int) throws -> [UInt8] {
    try validate(offset: offset, byteCount: byteCount, write: false)
    if offset < 0x40 {
      let common = lock.withLock { commonConfigurationLocked() }
      return Array(common[Int(offset)..<(Int(offset) + byteCount)])
    }
    if offset == 0x200, byteCount == 1 {
      return [
        lock.withLock {
          let value = isrStatus
          isrStatus = 0
          return value
        }
      ]
    }
    if offset >= 0x300, offset + UInt64(byteCount) <= 0x300 + UInt64(deviceConfiguration.count) {
      return lock.withLock {
        Array(deviceConfiguration[Int(offset - 0x300)..<(Int(offset - 0x300) + byteCount)])
      }
    }
    return [UInt8](repeating: 0, count: byteCount)
  }

  public func writeBAR(offset: UInt64, bytes: [UInt8]) throws {
    try validate(offset: offset, byteCount: bytes.count, write: true)
    if offset < 0x40 {
      try writeCommon(offset: Int(offset), bytes: bytes)
      return
    }
    if (0x100..<0x200).contains(offset) && (bytes.count == 2 || bytes.count == 4) {
      let queue = UInt16(truncatingIfNeeded: uint64(bytes))
      let expected = UInt16(truncatingIfNeeded: (offset - 0x100) / 4)
      guard queue == expected, Int(queue) < queueCount else {
        throw DoryPCVirtioPCIError.invalidQueue(queue)
      }
      let sink = lock.withLock { notifySink }
      sink?(queue)
      drain(queue: queue)
      return
    }
    if offset >= 0x300, offset + UInt64(bytes.count) <= 0x300 + UInt64(deviceConfiguration.count) {
      lock.withLock {
        deviceConfiguration.replaceSubrange(
          Int(offset - 0x300)..<(Int(offset - 0x300) + bytes.count),
          with: bytes
        )
      }
    }
  }

  private func drain(queue index: UInt16) {
    let snapshot = deviceState.snapshot()
    guard snapshot.status.contains(.driverOK) else { return }
    let processing = lock.withLock { (guestMemory, queueCanProcess, queueProcessor) }
    guard let memory = processing.0, let processor = processing.2 else { return }
    let processingLock = processingLocks[Int(index)]
    processingLock.lock()
    defer { processingLock.unlock() }
    do {
      let queue = try queue(at: index)
      while processing.1(index),
        let chain = try queue.popAvailable(
          memory: memory,
          allowIndirectDescriptors: snapshot.negotiatedFeatures.contains(.indirectDescriptors)
        )
      {
        let bytesWritten = try processor(index, chain, memory)
        memory.synchronize()
        let notify = try queue.complete(
          chain,
          bytesWritten: bytesWritten,
          memory: memory,
          eventIndexNegotiated: snapshot.negotiatedFeatures.contains(.eventIndex)
        )
        if notify { _ = signalQueueInterrupt(queue: index) }
      }
    } catch {
      deviceState.markDeviceNeedsReset()
      signalConfigurationChange()
    }
  }

  private func writeCommon(offset: Int, bytes: [UInt8]) throws {
    if (0x20..<0x28).contains(offset), offset + bytes.count <= 0x28 {
      try writeSelectedQueueAddress(
        offset: offset,
        registerOffset: 0x20,
        bytes: bytes,
        keyPath: \.descriptorAddress
      )
      return
    }
    if (0x28..<0x30).contains(offset), offset + bytes.count <= 0x30 {
      try writeSelectedQueueAddress(
        offset: offset,
        registerOffset: 0x28,
        bytes: bytes,
        keyPath: \.driverAddress
      )
      return
    }
    if (0x30..<0x38).contains(offset), offset + bytes.count <= 0x38 {
      try writeSelectedQueueAddress(
        offset: offset,
        registerOffset: 0x30,
        bytes: bytes,
        keyPath: \.deviceAddress
      )
      return
    }
    switch (offset, bytes.count) {
    case (0x00, 4): lock.withLock { deviceFeatureSelect = uint32(bytes) }
    case (0x08, 4): lock.withLock { driverFeatureSelect = uint32(bytes) }
    case (0x0C, 4):
      let page = lock.withLock { driverFeatureSelect }
      deviceState.writeDriverFeatures(page: page, value: uint32(bytes))
    case (0x10, 2):
      lock.withLock {
        let vector = uint16(bytes)
        configurationMSIXVector = Int(vector) < msixVectorCount ? vector : .max
      }
    case (0x14, 1):
      let status = DoryVirtioDeviceStatus(rawValue: bytes[0])
      deviceState.writeStatus(status)
      if status.isEmpty {
        lock.withLock {
          configurationMSIXVector = .max
          isrStatus = 0
          for index in queues.indices {
            queues[index].enabled = false
            queues[index].msixVector = .max
            queues[index].queue.reset()
          }
        }
      }
    case (0x16, 2): lock.withLock { selectedQueue = uint16(bytes) }
    case (0x18, 2): try updateSelectedQueue { if !$0.enabled { $0.size = uint16(bytes) } }
    case (0x1A, 2):
      try updateSelectedQueue {
        let vector = uint16(bytes)
        $0.msixVector = Int(vector) < msixVectorCount ? vector : .max
      }
    case (0x1C, 2):
      let enable = uint16(bytes) & 1 != 0
      try updateSelectedQueue { queue in
        guard enable, !queue.enabled else { return }
        do {
          try queue.queue.configure(
            size: queue.size,
            descriptorAddress: queue.descriptorAddress,
            driverAddress: queue.driverAddress,
            deviceAddress: queue.deviceAddress,
            enabled: true
          )
          queue.enabled = true
        } catch {
          deviceState.markDeviceNeedsReset()
        }
      }
    default: break
    }
  }

  private func writeSelectedQueueAddress(
    offset: Int,
    registerOffset: Int,
    bytes: [UInt8],
    keyPath: WritableKeyPath<QueueRegisters, UInt64>
  ) throws {
    try updateSelectedQueue { queue in
      guard !queue.enabled else { return }
      var address = queue[keyPath: keyPath]
      for (index, byte) in bytes.enumerated() {
        let shift = UInt64((offset - registerOffset + index) * 8)
        let mask = UInt64(0xFF) << shift
        address = (address & ~mask) | UInt64(byte) << shift
      }
      queue[keyPath: keyPath] = address
    }
  }

  private func commonConfigurationLocked() -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 0x40)
    put(deviceFeatureSelect, at: 0x00, in: &bytes)
    put(deviceState.readDeviceFeatures(page: deviceFeatureSelect), at: 0x04, in: &bytes)
    put(driverFeatureSelect, at: 0x08, in: &bytes)
    put(configurationMSIXVector, at: 0x10, in: &bytes)
    put(UInt16(queueCount), at: 0x12, in: &bytes)
    bytes[0x14] = deviceState.snapshot().status.rawValue
    bytes[0x15] = deviceState.snapshot().configurationGeneration
    put(selectedQueue, at: 0x16, in: &bytes)
    if queues.indices.contains(Int(selectedQueue)) {
      let queue = queues[Int(selectedQueue)]
      put(queue.size, at: 0x18, in: &bytes)
      put(queue.msixVector, at: 0x1A, in: &bytes)
      put(UInt16(queue.enabled ? 1 : 0), at: 0x1C, in: &bytes)
      put(queue.notifyOffset, at: 0x1E, in: &bytes)
      put(queue.descriptorAddress, at: 0x20, in: &bytes)
      put(queue.driverAddress, at: 0x28, in: &bytes)
      put(queue.deviceAddress, at: 0x30, in: &bytes)
    }
    return bytes
  }

  fileprivate func msixVector(for interrupt: DoryPCVirtioPCIInterrupt) -> UInt16 {
    lock.withLock {
      switch interrupt {
      case .configuration:
        return configurationMSIXVector
      case .queue(let index):
        guard queues.indices.contains(Int(index)) else { return .max }
        return queues[Int(index)].msixVector
      }
    }
  }

  private func updateSelectedQueue(_ update: (inout QueueRegisters) -> Void) throws {
    try lock.withLock {
      guard queues.indices.contains(Int(selectedQueue)) else {
        throw DoryPCVirtioPCIError.invalidQueue(selectedQueue)
      }
      update(&queues[Int(selectedQueue)])
    }
  }

  private func validate(offset: UInt64, byteCount: Int, write: Bool) throws {
    guard byteCount > 0, offset < 0x1000, UInt64(byteCount) <= 0x1000 - offset else {
      throw DoryPCVirtioPCIError.invalidBARAccess(
        offset: offset, byteCount: byteCount, write: write)
    }
  }
}

public final class DoryPCVirtioBlockPCIDevice: DoryPCPCIFunction, DoryPCPCIMSIControllable,
  DoryPCPCIINTxControllable, DoryPCPCIBARMemoryDevice, DoryPCVirtioGuestMemoryConsumer,
  @unchecked Sendable
{
  public let pciFunction: DoryPCVirtioPCIFunction
  public let blockDevice: DoryVirtioBlockDevice

  public var pciAddress: DoryPCPCIAddress { pciFunction.pciAddress }
  public var configurationFunction: DoryPCPCIConfigurationFunction {
    pciFunction.configurationFunction
  }
  public var barIndex: Int { pciFunction.barIndex }
  public var transport: DoryPCVirtioPCITransport { pciFunction.transport }

  public init(
    address: DoryPCPCIAddress,
    initialBARAddress: UInt64,
    storage: any DoryVirtioBlockStorage,
    identifier: String,
    maximumQueueSize: UInt16 = 256
  ) throws {
    blockDevice = try .init(storage: storage, identifier: identifier)
    pciFunction = try .init(
      address: address,
      virtioDeviceID: 2,
      classCode: 0x010000,
      initialBARAddress: initialBARAddress,
      queueCount: 1,
      maximumQueueSize: maximumQueueSize,
      offeredFeatures: blockDevice.offeredFeatures.union([
        .indirectDescriptors, .eventIndex,
      ]),
      deviceConfiguration: blockDevice.configuration
    )
  }

  public func connectGuestMemory(_ memory: any DoryVirtioGuestMemory) {
    transport.connectQueueProcessor(memory: memory) { [blockDevice] queue, chain, memory in
      guard queue == 0 else { throw DoryPCVirtioPCIError.invalidQueue(queue) }
      return try blockDevice.process(chain, memory: memory).bytesWritten
    }
  }

  public func readConfiguration(offset: Int, byteCount: Int) throws -> [UInt8] {
    try pciFunction.readConfiguration(offset: offset, byteCount: byteCount)
  }

  public func writeConfiguration(offset: Int, bytes: [UInt8]) throws {
    try pciFunction.writeConfiguration(offset: offset, bytes: bytes)
  }

  public func connectMSISink(
    _ sink: @escaping @Sendable (_ messageAddress: UInt64, _ messageData: UInt16) -> Bool
  ) {
    pciFunction.connectMSISink(sink)
  }

  public func readBAR(offset: UInt64, byteCount: Int) throws -> [UInt8] {
    try pciFunction.readBAR(offset: offset, byteCount: byteCount)
  }

  public func writeBAR(offset: UInt64, bytes: [UInt8]) throws {
    try pciFunction.writeBAR(offset: offset, bytes: bytes)
  }
}

public final class DoryPCVirtioEntropyPCIDevice: DoryPCPCIFunction, DoryPCPCIMSIControllable,
  DoryPCPCIINTxControllable, DoryPCPCIBARMemoryDevice, DoryPCVirtioGuestMemoryConsumer,
  @unchecked Sendable
{
  public let pciFunction: DoryPCVirtioPCIFunction
  public let entropyDevice: DoryVirtioEntropyDevice

  public var pciAddress: DoryPCPCIAddress { pciFunction.pciAddress }
  public var configurationFunction: DoryPCPCIConfigurationFunction {
    pciFunction.configurationFunction
  }
  public var barIndex: Int { pciFunction.barIndex }
  public var transport: DoryPCVirtioPCITransport { pciFunction.transport }

  public init(
    address: DoryPCPCIAddress,
    initialBARAddress: UInt64,
    source: any DoryVirtioEntropySource = DoryVirtioSystemEntropySource(),
    maximumQueueSize: UInt16 = 256,
    maximumRequestBytes: UInt64 = 1024 * 1024
  ) throws {
    entropyDevice = .init(
      source: source,
      maximumRequestBytes: maximumRequestBytes
    )
    pciFunction = try .init(
      address: address,
      virtioDeviceID: 4,
      classCode: 0x088000,
      initialBARAddress: initialBARAddress,
      queueCount: 1,
      maximumQueueSize: maximumQueueSize,
      offeredFeatures: entropyDevice.offeredFeatures.union([
        .indirectDescriptors, .eventIndex,
      ]),
      deviceConfiguration: entropyDevice.configuration
    )
  }

  public func connectGuestMemory(_ memory: any DoryVirtioGuestMemory) {
    transport.connectQueueProcessor(memory: memory) { [entropyDevice] queue, chain, memory in
      guard queue == 0 else { throw DoryPCVirtioPCIError.invalidQueue(queue) }
      return try entropyDevice.process(chain, memory: memory)
    }
  }

  public func readConfiguration(offset: Int, byteCount: Int) throws -> [UInt8] {
    try pciFunction.readConfiguration(offset: offset, byteCount: byteCount)
  }

  public func writeConfiguration(offset: Int, bytes: [UInt8]) throws {
    try pciFunction.writeConfiguration(offset: offset, bytes: bytes)
  }

  public func connectMSISink(
    _ sink: @escaping @Sendable (_ messageAddress: UInt64, _ messageData: UInt16) -> Bool
  ) {
    pciFunction.connectMSISink(sink)
  }

  public func readBAR(offset: UInt64, byteCount: Int) throws -> [UInt8] {
    try pciFunction.readBAR(offset: offset, byteCount: byteCount)
  }

  public func writeBAR(offset: UInt64, bytes: [UInt8]) throws {
    try pciFunction.writeBAR(offset: offset, bytes: bytes)
  }
}

public final class DoryPCVirtioNetworkPCIDevice: DoryPCPCIFunction, DoryPCPCIMSIControllable,
  DoryPCPCIINTxControllable, DoryPCPCIBARMemoryDevice, DoryPCVirtioGuestMemoryConsumer,
  @unchecked Sendable
{
  public let pciFunction: DoryPCVirtioPCIFunction
  public let networkDevice: DoryVirtioNetworkDevice

  public var pciAddress: DoryPCPCIAddress { pciFunction.pciAddress }
  public var configurationFunction: DoryPCPCIConfigurationFunction {
    pciFunction.configurationFunction
  }
  public var barIndex: Int { pciFunction.barIndex }
  public var transport: DoryPCVirtioPCITransport { pciFunction.transport }

  public init(
    address: DoryPCPCIAddress,
    initialBARAddress: UInt64,
    backend: any DoryVirtioNetworkBackend,
    macAddress: [UInt8],
    mtu: UInt16 = 1500,
    maximumQueueSize: UInt16 = 256,
    maximumPendingReceiveFrames: Int = 1024
  ) throws {
    networkDevice = try .init(
      backend: backend,
      macAddress: macAddress,
      mtu: mtu,
      maximumPendingReceiveFrames: maximumPendingReceiveFrames
    )
    pciFunction = try .init(
      address: address,
      virtioDeviceID: 1,
      classCode: 0x020000,
      initialBARAddress: initialBARAddress,
      queueCount: 2,
      maximumQueueSize: maximumQueueSize,
      offeredFeatures: networkDevice.offeredFeatures.union([
        .indirectDescriptors, .eventIndex,
      ]),
      deviceConfiguration: networkDevice.configuration
    )
    networkDevice.connectReceiveReadySink { [weak transport = pciFunction.transport] in
      transport?.processQueue(DoryVirtioNetworkDevice.receiveQueue)
    }
  }

  public func connectGuestMemory(_ memory: any DoryVirtioGuestMemory) {
    transport.connectQueueProcessor(
      memory: memory,
      canProcess: { [networkDevice] queue in
        queue != DoryVirtioNetworkDevice.receiveQueue || networkDevice.canReceive
      },
      processor: { [networkDevice] queue, chain, memory in
        switch queue {
        case DoryVirtioNetworkDevice.receiveQueue:
          return try networkDevice.processReceive(chain, memory: memory)
        case DoryVirtioNetworkDevice.transmitQueue:
          return try networkDevice.processTransmit(chain, memory: memory)
        default:
          throw DoryPCVirtioPCIError.invalidQueue(queue)
        }
      }
    )
  }

  @discardableResult
  public func setLinkUp(_ isUp: Bool) -> Bool {
    guard networkDevice.setLinkUp(isUp) else { return false }
    transport.updateDeviceConfiguration(networkDevice.configuration)
    return true
  }

  public func readConfiguration(offset: Int, byteCount: Int) throws -> [UInt8] {
    try pciFunction.readConfiguration(offset: offset, byteCount: byteCount)
  }

  public func writeConfiguration(offset: Int, bytes: [UInt8]) throws {
    try pciFunction.writeConfiguration(offset: offset, bytes: bytes)
  }

  public func connectMSISink(
    _ sink: @escaping @Sendable (_ messageAddress: UInt64, _ messageData: UInt16) -> Bool
  ) {
    pciFunction.connectMSISink(sink)
  }

  public func readBAR(offset: UInt64, byteCount: Int) throws -> [UInt8] {
    try pciFunction.readBAR(offset: offset, byteCount: byteCount)
  }

  public func writeBAR(offset: UInt64, bytes: [UInt8]) throws {
    try pciFunction.writeBAR(offset: offset, bytes: bytes)
  }
}

public final class DoryPCVirtioGPUPCIDevice: DoryPCPCIFunction, DoryPCPCIMSIControllable,
  DoryPCPCIINTxControllable, DoryPCPCIBARMemoryDevice, DoryPCVirtioGuestMemoryConsumer,
  @unchecked Sendable
{
  public let pciFunction: DoryPCVirtioPCIFunction
  public let gpuDevice: DoryVirtioGPUDevice
  private let configurationLock = NSLock()

  public var pciAddress: DoryPCPCIAddress { pciFunction.pciAddress }
  public var configurationFunction: DoryPCPCIConfigurationFunction {
    pciFunction.configurationFunction
  }
  public var barIndex: Int { pciFunction.barIndex }
  public var transport: DoryPCVirtioPCITransport { pciFunction.transport }

  public init(
    address: DoryPCPCIAddress,
    initialBARAddress: UInt64,
    scanouts: [DoryVirtioGPUScanout],
    displaySink: (any DoryVirtioGPUDisplaySink)? = nil,
    accelerationAuthority: (any DoryVirtioGPUAccelerationAuthority)? = nil,
    maximumQueueSize: UInt16 = 256,
    maximumResourceBytes: UInt64 = 256 * 1024 * 1024
  ) throws {
    gpuDevice = try .init(
      scanouts: scanouts,
      maximumResourceBytes: maximumResourceBytes,
      displaySink: displaySink,
      accelerationAuthority: accelerationAuthority
    )
    pciFunction = try .init(
      address: address,
      virtioDeviceID: 16,
      classCode: 0x030000,
      initialBARAddress: initialBARAddress,
      queueCount: 2,
      maximumQueueSize: maximumQueueSize,
      offeredFeatures: gpuDevice.offeredFeatures.union([
        .indirectDescriptors, .eventIndex,
      ]),
      deviceConfiguration: gpuDevice.configuration,
      onReset: { [gpuDevice] in gpuDevice.reset() }
    )
  }

  public func connectGuestMemory(_ memory: any DoryVirtioGuestMemory) {
    transport.connectQueueProcessor(memory: memory) { [gpuDevice] queue, chain, memory in
      try gpuDevice.process(queue: queue, chain: chain, memory: memory)
    }
  }

  @discardableResult
  public func updateScanoutSize(scanoutID: UInt32, width: UInt32, height: UInt32) -> Bool {
    configurationLock.withLock {
      guard gpuDevice.updateScanoutSize(scanoutID: scanoutID, width: width, height: height)
      else { return false }
      transport.updateDeviceConfiguration(gpuDevice.configuration)
      return true
    }
  }

  public func readConfiguration(offset: Int, byteCount: Int) throws -> [UInt8] {
    try pciFunction.readConfiguration(offset: offset, byteCount: byteCount)
  }

  public func writeConfiguration(offset: Int, bytes: [UInt8]) throws {
    try pciFunction.writeConfiguration(offset: offset, bytes: bytes)
  }

  public func connectMSISink(
    _ sink: @escaping @Sendable (_ messageAddress: UInt64, _ messageData: UInt16) -> Bool
  ) {
    pciFunction.connectMSISink(sink)
  }

  public func readBAR(offset: UInt64, byteCount: Int) throws -> [UInt8] {
    try pciFunction.readBAR(offset: offset, byteCount: byteCount)
  }

  public func writeBAR(offset: UInt64, bytes: [UInt8]) throws {
    if offset < 0x310, offset + UInt64(bytes.count) > 0x304 {
      try configurationLock.withLock {
        try pciFunction.writeBAR(offset: offset, bytes: bytes)
        gpuDevice.writeConfiguration(offset: Int(offset) - 0x300, bytes: bytes)
        transport.normalizeDeviceConfigurationAfterGuestWrite(gpuDevice.configuration)
      }
    } else {
      try pciFunction.writeBAR(offset: offset, bytes: bytes)
    }
  }
}

public final class DoryPCVirtioInputPCIDevice: DoryPCPCIFunction, DoryPCPCIMSIControllable,
  DoryPCPCIINTxControllable, DoryPCPCIBARMemoryDevice, DoryPCVirtioGuestMemoryConsumer,
  @unchecked Sendable
{
  public let pciFunction: DoryPCVirtioPCIFunction
  public let inputDevice: DoryVirtioInputDevice

  public var pciAddress: DoryPCPCIAddress { pciFunction.pciAddress }
  public var configurationFunction: DoryPCPCIConfigurationFunction {
    pciFunction.configurationFunction
  }
  public var barIndex: Int { pciFunction.barIndex }
  public var transport: DoryPCVirtioPCITransport { pciFunction.transport }

  public init(
    address: DoryPCPCIAddress,
    initialBARAddress: UInt64,
    descriptor: DoryVirtioInputDescriptor,
    statusSink: (any DoryVirtioInputStatusSink)? = nil,
    maximumQueueSize: UInt16 = 256,
    maximumPendingEvents: Int = 4_096
  ) throws {
    inputDevice = try .init(
      descriptor: descriptor,
      maximumPendingEvents: maximumPendingEvents,
      statusSink: statusSink
    )
    pciFunction = try .init(
      address: address,
      virtioDeviceID: 18,
      classCode: 0x098000,
      initialBARAddress: initialBARAddress,
      queueCount: 2,
      maximumQueueSize: maximumQueueSize,
      offeredFeatures: inputDevice.offeredFeatures.union([
        .indirectDescriptors, .eventIndex,
      ]),
      deviceConfiguration: inputDevice.configuration(select: 0, subselect: 0),
      onReset: { [inputDevice] in inputDevice.reset() }
    )
    inputDevice.connectEventReadySink { [weak transport = pciFunction.transport] in
      transport?.processQueue(DoryVirtioInputDevice.eventQueue)
    }
  }

  public func connectGuestMemory(_ memory: any DoryVirtioGuestMemory) {
    transport.connectQueueProcessor(
      memory: memory,
      canProcess: { [inputDevice] queue in
        queue != DoryVirtioInputDevice.eventQueue || inputDevice.hasPendingEvent
      },
      processor: { [inputDevice] queue, chain, memory in
        switch queue {
        case DoryVirtioInputDevice.eventQueue:
          return try inputDevice.processEvent(chain, memory: memory)
        case DoryVirtioInputDevice.statusQueue:
          return try inputDevice.processStatus(chain, memory: memory)
        default:
          throw DoryPCVirtioPCIError.invalidQueue(queue)
        }
      }
    )
  }

  @discardableResult
  public func enqueue(_ events: [DoryVirtioInputEvent]) -> Bool {
    inputDevice.enqueue(events)
  }

  @discardableResult
  public func enqueueSynchronized(_ events: [DoryVirtioInputEvent]) -> Bool {
    inputDevice.enqueueSynchronized(events)
  }

  public func readConfiguration(offset: Int, byteCount: Int) throws -> [UInt8] {
    try pciFunction.readConfiguration(offset: offset, byteCount: byteCount)
  }

  public func writeConfiguration(offset: Int, bytes: [UInt8]) throws {
    try pciFunction.writeConfiguration(offset: offset, bytes: bytes)
  }

  public func connectMSISink(
    _ sink: @escaping @Sendable (_ messageAddress: UInt64, _ messageData: UInt16) -> Bool
  ) {
    pciFunction.connectMSISink(sink)
  }

  public func readBAR(offset: UInt64, byteCount: Int) throws -> [UInt8] {
    try pciFunction.readBAR(offset: offset, byteCount: byteCount)
  }

  public func writeBAR(offset: UInt64, bytes: [UInt8]) throws {
    try pciFunction.writeBAR(offset: offset, bytes: bytes)
    let end = offset + UInt64(bytes.count)
    guard offset < 0x302, end > 0x300 else { return }
    let selection = try transport.readBAR(offset: 0x300, byteCount: 2)
    transport.updateDeviceConfiguration(
      inputDevice.configuration(select: selection[0], subselect: selection[1]),
      signalChange: false
    )
  }
}

public final class DoryPCVirtioSoundPCIDevice: DoryPCPCIFunction, DoryPCPCIMSIControllable,
  DoryPCPCIINTxControllable, DoryPCPCIBARMemoryDevice, DoryPCVirtioGuestMemoryConsumer,
  @unchecked Sendable
{
  public let pciFunction: DoryPCVirtioPCIFunction
  public let soundDevice: DoryVirtioSoundDevice

  public var pciAddress: DoryPCPCIAddress { pciFunction.pciAddress }
  public var configurationFunction: DoryPCPCIConfigurationFunction {
    pciFunction.configurationFunction
  }
  public var barIndex: Int { pciFunction.barIndex }
  public var transport: DoryPCVirtioPCITransport { pciFunction.transport }

  public init(
    address: DoryPCPCIAddress,
    initialBARAddress: UInt64,
    backend: any DoryVirtioSoundBackend,
    maximumQueueSize: UInt16 = 256,
    maximumBufferBytes: UInt32 = 16 * 1024 * 1024,
    maximumPendingEvents: Int = 1_024
  ) throws {
    soundDevice = .init(
      backend: backend,
      maximumBufferBytes: maximumBufferBytes,
      maximumPendingEvents: maximumPendingEvents
    )
    pciFunction = try .init(
      address: address,
      virtioDeviceID: 25,
      classCode: 0x040100,
      initialBARAddress: initialBARAddress,
      queueCount: 4,
      maximumQueueSize: maximumQueueSize,
      offeredFeatures: soundDevice.offeredFeatures.union([
        .indirectDescriptors, .eventIndex,
      ]),
      deviceConfiguration: soundDevice.configuration,
      onReset: { [soundDevice] in soundDevice.reset() }
    )
    soundDevice.connectEventReadySink { [weak transport = pciFunction.transport] in
      transport?.processQueue(DoryVirtioSoundDevice.eventQueue)
    }
  }

  public func connectGuestMemory(_ memory: any DoryVirtioGuestMemory) {
    transport.connectQueueProcessor(
      memory: memory,
      canProcess: { [soundDevice] queue in
        queue != DoryVirtioSoundDevice.eventQueue || soundDevice.hasPendingEvent
      },
      processor: { [soundDevice] queue, chain, memory in
        switch queue {
        case DoryVirtioSoundDevice.controlQueue:
          return try soundDevice.processControl(chain, memory: memory)
        case DoryVirtioSoundDevice.eventQueue:
          return try soundDevice.processEvent(chain, memory: memory)
        case DoryVirtioSoundDevice.transmitQueue:
          return try soundDevice.processTransmit(chain, memory: memory)
        case DoryVirtioSoundDevice.receiveQueue:
          return try soundDevice.processReceive(chain, memory: memory)
        default:
          throw DoryPCVirtioPCIError.invalidQueue(queue)
        }
      }
    )
  }

  public func readConfiguration(offset: Int, byteCount: Int) throws -> [UInt8] {
    try pciFunction.readConfiguration(offset: offset, byteCount: byteCount)
  }

  public func writeConfiguration(offset: Int, bytes: [UInt8]) throws {
    try pciFunction.writeConfiguration(offset: offset, bytes: bytes)
  }

  public func connectMSISink(
    _ sink: @escaping @Sendable (_ messageAddress: UInt64, _ messageData: UInt16) -> Bool
  ) {
    pciFunction.connectMSISink(sink)
  }

  public func readBAR(offset: UInt64, byteCount: Int) throws -> [UInt8] {
    try pciFunction.readBAR(offset: offset, byteCount: byteCount)
  }

  public func writeBAR(offset: UInt64, bytes: [UInt8]) throws {
    try pciFunction.writeBAR(offset: offset, bytes: bytes)
  }
}

public final class DoryPCVirtioPCIFunction: DoryPCPCIFunction, DoryPCPCIMSIControllable,
  DoryPCPCIINTxControllable, DoryPCPCIBARMemoryDevice, @unchecked Sendable
{
  public let configurationFunction: DoryPCPCIConfigurationFunction
  public let transport: DoryPCVirtioPCITransport
  public let barIndex = 0
  public var pciAddress: DoryPCPCIAddress { configurationFunction.pciAddress }

  private let capabilities: [UInt8: UInt8]

  public init(
    address: DoryPCPCIAddress,
    virtioDeviceID: UInt16,
    classCode: UInt32,
    initialBARAddress: UInt64,
    queueCount: Int,
    maximumQueueSize: UInt16 = 256,
    offeredFeatures: DoryVirtioFeatures = [],
    deviceConfiguration: [UInt8] = [],
    onReset: @escaping @Sendable () -> Void = {}
  ) throws {
    guard (1...63).contains(queueCount) else {
      throw DoryPCVirtioPCIError.invalidQueueCount(queueCount)
    }
    let msixVectorCount = queueCount + 1
    configurationFunction = try .init(
      address: address,
      vendorID: 0x1AF4,
      deviceID: 0x1040 &+ virtioDeviceID,
      classCode: classCode,
      revisionID: 1,
      subsystemVendorID: 0x1AF4,
      subsystemID: 0x40 &+ virtioDeviceID,
      interruptLine: DoryPCV1ABI.interruptLine(device: address.device, pin: 1),
      interruptPin: 1,
      supportsMSI: true,
      msiNextCapabilityOffset: 0x60,
      msixVectorCount: msixVectorCount,
      msixCapabilityOffset: 0x60,
      msixNextCapabilityOffset: 0x70,
      msixTableBAR: 0,
      msixTableOffset: 0x800,
      msixPendingBAR: 0,
      msixPendingOffset: 0xC00,
      bars: [
        .init(
          index: 0,
          kind: .memory32(prefetchable: false),
          size: 0x1000,
          address: initialBARAddress
        )
      ]
    )
    transport = try .init(
      queueCount: queueCount,
      maximumQueueSize: maximumQueueSize,
      msixVectorCount: msixVectorCount,
      offeredFeatures: offeredFeatures,
      deviceConfiguration: deviceConfiguration,
      onReset: onReset
    )
    capabilities = Self.makeCapabilities(deviceConfigurationLength: deviceConfiguration.count)
    transport.connectInterruptSink { [configurationFunction, transport] interrupt in
      if configurationFunction.msixState?.enabled == true {
        let vector = transport.msixVector(for: interrupt)
        guard vector != .max else { return false }
        return configurationFunction.raiseMSIX(vector: vector)
      }
      if configurationFunction.msiState?.enabled == true {
        return configurationFunction.raiseMSI()
      }
      return configurationFunction.setINTx(asserted: true)
    }
  }

  public func readConfiguration(offset: Int, byteCount: Int) throws -> [UInt8] {
    var bytes = try configurationFunction.readConfiguration(offset: offset, byteCount: byteCount)
    for index in bytes.indices {
      if let value = capabilities[UInt8(offset + index)] { bytes[index] = value }
    }
    return bytes
  }

  public func writeConfiguration(offset: Int, bytes: [UInt8]) throws {
    try configurationFunction.writeConfiguration(offset: offset, bytes: bytes)
  }

  public func connectMSISink(
    _ sink: @escaping @Sendable (_ messageAddress: UInt64, _ messageData: UInt16) -> Bool
  ) {
    configurationFunction.connectMSISink(sink)
  }

  public func readBAR(offset: UInt64, byteCount: Int) throws -> [UInt8] {
    if let bytes = configurationFunction.readMSIXBAR(
      bar: barIndex,
      offset: offset,
      byteCount: byteCount
    ) {
      return bytes
    }
    let bytes = try transport.readBAR(offset: offset, byteCount: byteCount)
    if offset == 0x200, byteCount == 1 {
      configurationFunction.setINTx(asserted: false)
    }
    return bytes
  }

  public func writeBAR(offset: UInt64, bytes: [UInt8]) throws {
    if configurationFunction.writeMSIXBAR(bar: barIndex, offset: offset, bytes: bytes) {
      return
    }
    try transport.writeBAR(offset: offset, bytes: bytes)
    if offset == 0x14, bytes == [0] {
      configurationFunction.setINTx(asserted: false)
    }
  }

  private static func makeCapabilities(deviceConfigurationLength: Int) -> [UInt8: UInt8] {
    var result: [UInt8: UInt8] = [:]
    addCapability(at: 0x70, next: 0x80, type: 1, offset: 0, length: 0x40, to: &result)
    addCapability(
      at: 0x80, next: 0x94, type: 2, offset: 0x100, length: 0x100, to: &result, notify: true)
    addCapability(at: 0x94, next: 0xA4, type: 3, offset: 0x200, length: 1, to: &result)
    addCapability(
      at: 0xA4,
      next: 0,
      type: 4,
      offset: 0x300,
      length: UInt32(deviceConfigurationLength),
      to: &result
    )
    return result
  }

  private static func addCapability(
    at start: UInt8,
    next: UInt8,
    type: UInt8,
    offset: UInt32,
    length: UInt32,
    to result: inout [UInt8: UInt8],
    notify: Bool = false
  ) {
    var bytes: [UInt8] = [0x09, next, notify ? 20 : 16, type, 0, 0, 0, 0]
    bytes += littleEndian(offset)
    bytes += littleEndian(length)
    if notify { bytes += littleEndian(UInt32(4)) }
    for (index, byte) in bytes.enumerated() { result[start &+ UInt8(index)] = byte }
  }
}

private func uint16(_ bytes: [UInt8]) -> UInt16 {
  UInt16(bytes[0]) | UInt16(bytes[1]) << 8
}

private func uint32(_ bytes: [UInt8]) -> UInt32 {
  (0..<4).reduce(0) { $0 | UInt32(bytes[$1]) << UInt32($1 * 8) }
}

private func uint64(_ bytes: [UInt8]) -> UInt64 {
  bytes.enumerated().reduce(0) { $0 | UInt64($1.element) << UInt64($1.offset * 8) }
}

private func put<T: FixedWidthInteger>(_ value: T, at offset: Int, in bytes: inout [UInt8]) {
  for index in 0..<MemoryLayout<T>.size {
    bytes[offset + index] = UInt8(truncatingIfNeeded: value >> T(index * 8))
  }
}

private func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
  (0..<MemoryLayout<T>.size).map { UInt8(truncatingIfNeeded: value >> T($0 * 8)) }
}
