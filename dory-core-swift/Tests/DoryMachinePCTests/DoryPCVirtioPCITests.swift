import DoryMachinePC
import DoryVirtio
import Foundation
import Testing

@Suite struct DoryPCVirtioPCITests {
  @Test func publishesModernCapabilitiesAndVirtioIdentity() throws {
    let function = try makeFunction()
    #expect(try function.readConfiguration(offset: 0, byteCount: 4) == [0xF4, 0x1A, 0x42, 0x10])
    #expect(try function.readConfiguration(offset: 0x2C, byteCount: 4) == [0xF4, 0x1A, 0x42, 0])
    #expect(try function.readConfiguration(offset: 0x50, byteCount: 2) == [0x05, 0x60])
    #expect(try function.readConfiguration(offset: 0x60, byteCount: 4) == [0x11, 0x70, 2, 0])
    #expect(try function.readConfiguration(offset: 0x70, byteCount: 4) == [0x09, 0x80, 16, 1])
    #expect(try function.readConfiguration(offset: 0x80, byteCount: 4) == [0x09, 0x94, 20, 2])
    #expect(try function.readConfiguration(offset: 0x94, byteCount: 4) == [0x09, 0xA4, 16, 3])
    #expect(try function.readConfiguration(offset: 0xA4, byteCount: 4) == [0x09, 0, 16, 4])
  }

  @Test func programsFeaturesStatusAndSplitQueueThroughTheCommonRegion() throws {
    let function = try makeFunction()
    let bar = UInt64(0xD000_0000)
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      pciFunctions: [function]
    )
    try function.writeConfiguration(offset: 4, bytes: [2, 0])

    try write32(machine, bar + 0x00, 1)
    #expect(try read32(machine, bar + 0x04) & 1 == 1)
    try write32(machine, bar + 0x08, 1)
    try write32(machine, bar + 0x0C, 1)
    try write8(machine, bar + 0x14, 0x0F)
    #expect(try read8(machine, bar + 0x14) == 0x0F)

    try write16(machine, bar + 0x16, 1)
    try write16(machine, bar + 0x18, 128)
    try write64(machine, bar + 0x20, 0x10_0000)
    try write64(machine, bar + 0x28, 0x11_0000)
    try write64(machine, bar + 0x30, 0x12_0000)
    try write16(machine, bar + 0x1C, 1)

    let queue = try function.transport.queueSnapshot(at: 1)
    #expect(queue.enabled)
    #expect(queue.size == 128)
    #expect(queue.descriptorAddress == 0x10_0000)
    #expect(queue.driverAddress == 0x11_0000)
    #expect(queue.deviceAddress == 0x12_0000)

    let diagnostics = function.transport.registerDiagnostics
    #expect(diagnostics.readCount == 2)
    #expect(diagnostics.writeCount == 10)
    #expect(diagnostics.recentAccesses.first?.offset == 0)
    #expect(diagnostics.recentAccesses.first?.write == true)
    #expect(diagnostics.recentAccesses.last?.offset == 0x1C)
    #expect(diagnostics.recentAccesses.last?.bytes == [1, 0])
  }

  @Test func queueAddressesAcceptSplitMMIOWrites() throws {
    let function = try makeFunction()
    let bar = UInt64(0xD000_0000)
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      pciFunctions: [function]
    )
    try function.writeConfiguration(offset: 4, bytes: [2, 0])

    try write16(machine, bar + 0x16, 0)
    try write32(machine, bar + 0x20, 0x1234_5000)
    try write32(machine, bar + 0x24, 0x0000_0001)
    try write32(machine, bar + 0x28, 0x2345_6000)
    try write32(machine, bar + 0x2C, 0x0000_0002)
    try write32(machine, bar + 0x30, 0x3456_7000)
    try write32(machine, bar + 0x34, 0x0000_0003)

    let queue = try function.transport.queueSnapshot(at: 0)
    #expect(queue.descriptorAddress == 0x0000_0001_1234_5000)
    #expect(queue.driverAddress == 0x0000_0002_2345_6000)
    #expect(queue.deviceAddress == 0x0000_0003_3456_7000)
  }

  @Test func notifyRegionAndISRUseMSIAndClearOnRead() throws {
    let function = try makeFunction()
    let notifications = LockedQueueNotifications()
    function.transport.connectNotifySink { notifications.append($0) }
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      pciFunctions: [function]
    )
    try function.writeConfiguration(offset: 4, bytes: [2, 0])
    try function.writeConfiguration(offset: 0x54, bytes: littleEndian(UInt32(0xFEE0_0000)))
    try function.writeConfiguration(offset: 0x5C, bytes: [0x72, 0])
    try function.writeConfiguration(offset: 0x52, bytes: [1, 0])

    try write16(machine, 0xD000_0104, 1)
    #expect(notifications.values == [1])
    #expect(function.transport.signalQueueInterrupt())
    #expect(machine.localAPIC.snapshot().interruptRequest.contains(0x72))
    #expect(try read8(machine, 0xD000_0200) == 1)
    #expect(try read8(machine, 0xD000_0200) == 0)
  }

  @Test func msixRoutesConfigurationAndPerQueueEvents() throws {
    let function = try makeFunction()
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      pciFunctions: [function]
    )
    try function.writeConfiguration(offset: 4, bytes: [2, 0])
    try writeMSIXEntry(machine, at: 0xD000_0800, vector: 0x80)
    try writeMSIXEntry(machine, at: 0xD000_0810, vector: 0x81)
    try writeMSIXEntry(machine, at: 0xD000_0820, vector: 0x82)
    try function.writeConfiguration(offset: 0x62, bytes: [2, 0x80])
    try write16(machine, 0xD000_0010, 0)
    try write16(machine, 0xD000_0016, 1)
    try write16(machine, 0xD000_001A, 2)

    function.transport.signalConfigurationChange()
    #expect(function.transport.signalQueueInterrupt(queue: 1))
    let pending = machine.localAPIC.snapshot().interruptRequest
    #expect(pending.contains(0x80))
    #expect(pending.contains(0x82))
  }

  @Test func enabledUnmappedMSIXEventDoesNotFallBackToMSI() throws {
    let function = try makeFunction()
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      pciFunctions: [function]
    )
    try function.writeConfiguration(offset: 4, bytes: [2, 0])
    try function.writeConfiguration(offset: 0x54, bytes: littleEndian(UInt32(0xFEE0_0000)))
    try function.writeConfiguration(offset: 0x5C, bytes: [0x72, 0])
    try function.writeConfiguration(offset: 0x52, bytes: [1, 0])
    try function.writeConfiguration(offset: 0x62, bytes: [2, 0x80])

    #expect(!function.transport.signalQueueInterrupt(queue: 0))
    #expect(!machine.localAPIC.snapshot().interruptRequest.contains(0x72))

    try write16(machine, 0xD000_0016, 0)
    try write16(machine, 0xD000_001A, 3)
    #expect(try read16(machine, 0xD000_001A) == UInt16.max)
  }

  @Test func intxFallbackRaisesIOAPICAndISRReadDeassertsIt() throws {
    let function = try makeFunction()
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      pciFunctions: [function]
    )
    try machine.ioAPIC.configure(
      pin: 17,
      route: .init(
        vector: 0x90,
        destinationAPICID: 0,
        masked: false,
        levelTriggered: true,
        activeLow: true
      )
    )
    try machine.localAPIC.configureSpuriousVector(0xFF, softwareEnabled: true)
    try function.writeConfiguration(offset: 4, bytes: [2, 0])

    #expect(function.transport.signalQueueInterrupt(queue: 0))
    #expect(function.configurationFunction.intxState.externallyAsserted)
    #expect(try function.readConfiguration(offset: 6, byteCount: 1)[0] & 8 != 0)
    #expect(machine.localAPIC.acknowledge(interruptsEnabled: true) == 0x90)

    #expect(try read8(machine, 0xD000_0200) == 1)
    #expect(!function.configurationFunction.intxState.externallyAsserted)
    #expect(try function.readConfiguration(offset: 6, byteCount: 1)[0] & 8 == 0)
    #expect(machine.localAPIC.endOfInterrupt() == 0x90)
    try machine.ioAPIC.endOfInterrupt(vector: 0x90, destinationAPICID: 0)
    #expect(machine.localAPIC.acknowledge(interruptsEnabled: true) == nil)
  }

  @Test func pciInterruptDisableDefersPendingINTxUntilReenabled() throws {
    let function = try makeFunction()
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      pciFunctions: [function]
    )
    try machine.ioAPIC.configure(
      pin: 17,
      route: .init(
        vector: 0x91,
        destinationAPICID: 0,
        masked: false,
        levelTriggered: true
      )
    )
    try function.writeConfiguration(offset: 4, bytes: [2, 4])

    #expect(!function.transport.signalQueueInterrupt(queue: 0))
    #expect(function.configurationFunction.intxState.asserted)
    #expect(!function.configurationFunction.intxState.externallyAsserted)
    #expect(!machine.localAPIC.snapshot().interruptRequest.contains(0x91))

    try function.writeConfiguration(offset: 4, bytes: [2, 0])
    #expect(function.configurationFunction.intxState.externallyAsserted)
    #expect(machine.localAPIC.snapshot().interruptRequest.contains(0x91))
    #expect(try read8(machine, 0xD000_0200) == 1)
  }

  @Test func zeroStatusResetsEnabledQueues() throws {
    let function = try makeFunction()
    try function.transport.writeBAR(offset: 0x16, bytes: littleEndian(UInt16(0)))
    try function.transport.writeBAR(offset: 0x18, bytes: littleEndian(UInt16(64)))
    try function.transport.writeBAR(offset: 0x20, bytes: littleEndian(UInt64(0x1000)))
    try function.transport.writeBAR(offset: 0x28, bytes: littleEndian(UInt64(0x2000)))
    try function.transport.writeBAR(offset: 0x30, bytes: littleEndian(UInt64(0x3000)))
    try function.transport.writeBAR(offset: 0x1C, bytes: littleEndian(UInt16(1)))
    #expect(try function.transport.queueSnapshot(at: 0).enabled)

    try function.transport.writeBAR(offset: 0x14, bytes: [0])
    let resetQueue = try function.transport.queueSnapshot(at: 0)
    let queueState = try function.transport.queue(at: 0).snapshot()
    #expect(!resetQueue.enabled)
    #expect(queueState.size == 0)
  }

  @Test func deferredCompletionPublishesOnlyIntoItsOriginalQueueGeneration() throws {
    let function = try makeFunction()
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      pciFunctions: [function]
    )
    let completions = DeferredCompletionRecorder()
    function.transport.connectDeferredQueueProcessor(memory: machine.physicalMemory) {
      _, chain, memory, completion in
      let request = try memory.read(at: chain.descriptors[0].address, byteCount: 4)
      #expect(request == [1, 2, 3, 4])
      completions.append(completion)
    }
    try function.writeConfiguration(offset: 4, bytes: [2, 0])
    let bar: UInt64 = 0xD000_0000
    try write32(machine, bar + 0x08, 1)
    try write32(machine, bar + 0x0C, 1)
    try write8(machine, bar + 0x14, 0x0F)
    try write16(machine, bar + 0x16, 0)
    try write16(machine, bar + 0x18, 8)
    try write64(machine, bar + 0x20, 0x1000)
    try write64(machine, bar + 0x28, 0x2000)
    try write64(machine, bar + 0x30, 0x3000)
    try write16(machine, bar + 0x1C, 1)
    try machine.physicalMemory.write(
      at: 0x1000,
      bytes: littleEndian(UInt64(0x4000)) + littleEndian(UInt32(4))
        + littleEndian(UInt16(1)) + littleEndian(UInt16(1))
        + littleEndian(UInt64(0x5000)) + littleEndian(UInt32(4))
        + littleEndian(UInt16(2)) + littleEndian(UInt16(0))
    )
    try machine.physicalMemory.write(at: 0x4000, bytes: [1, 2, 3, 4])
    try machine.physicalMemory.write(at: 0x5000, bytes: [0, 0, 0, 0])
    try machine.physicalMemory.write(at: 0x2000, bytes: [0, 0, 1, 0, 0, 0])

    try write16(machine, bar + 0x100, 0)
    let first = try #require(completions.removeFirst())
    #expect(first.publish([9, 8, 7]))
    #expect(try machine.physicalMemory.read(at: 0x5000, byteCount: 4) == [9, 8, 7, 0])
    #expect(try read16(machine, 0x3002) == 1)

    try machine.physicalMemory.write(at: 0x2002, bytes: littleEndian(UInt16(2)))
    try machine.physicalMemory.write(at: 0x2006, bytes: littleEndian(UInt16(0)))
    try write16(machine, bar + 0x100, 0)
    let stale = try #require(completions.removeFirst())
    try write8(machine, bar + 0x14, 0)
    #expect(!stale.publish([6, 6, 6, 6]))
    #expect(try machine.physicalMemory.read(at: 0x5000, byteCount: 4) == [9, 8, 7, 0])
  }

  @Test func deferredCompletionPublishesAtMostOneTerminalOutcome() throws {
    let function = try makeFunction()
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      pciFunctions: [function]
    )
    let completions = DeferredCompletionRecorder()
    function.transport.connectDeferredQueueProcessor(memory: machine.physicalMemory) {
      _, _, _, completion in
      completions.append(completion)
    }
    try function.writeConfiguration(offset: 4, bytes: [2, 0])
    let bar: UInt64 = 0xD000_0000
    try configureSingleDescriptorQueue(machine, bar: bar)

    try publishDeferredDescriptor(machine, bar: bar, availableIndex: 1)
    let completion = try #require(completions.removeFirst())
    let copiedCompletion = completion
    #expect(completion.publish([9, 8, 7]))
    #expect(!copiedCompletion.publish([6, 6, 6, 6]))
    #expect(!copiedCompletion.failDevice())
    #expect(try machine.physicalMemory.read(at: 0x5000, byteCount: 4) == [9, 8, 7, 0])
    #expect(try read16(machine, 0x3002) == 1)
    #expect(!function.transport.deviceState.snapshot().status.contains(.deviceNeedsReset))
  }

  @Test func failureConsumesDeferredCompletion() throws {
    let function = try makeFunction()
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      pciFunctions: [function]
    )
    let completions = DeferredCompletionRecorder()
    function.transport.connectDeferredQueueProcessor(memory: machine.physicalMemory) {
      _, _, _, completion in
      completions.append(completion)
    }
    try function.writeConfiguration(offset: 4, bytes: [2, 0])
    let bar: UInt64 = 0xD000_0000
    try configureSingleDescriptorQueue(machine, bar: bar)

    try publishDeferredDescriptor(machine, bar: bar, availableIndex: 1)
    let completion = try #require(completions.removeFirst())
    #expect(completion.failDevice())
    #expect(!completion.publish([9, 8, 7]))
    #expect(try machine.physicalMemory.read(at: 0x5000, byteCount: 4) == [0, 0, 0, 0])
    #expect(try read16(machine, 0x3002) == 0)
    #expect(function.transport.deviceState.snapshot().status.contains(.deviceNeedsReset))
  }

  @Test func resetWaitsForInFlightDeferredPublication() throws {
    let function = try makeFunction()
    let memory = BlockingVirtioGuestMemory(byteCount: 0x20_000, blockedWriteAddress: 0x5000)
    let completions = DeferredCompletionRecorder()
    function.transport.connectDeferredQueueProcessor(memory: memory) {
      _, chain, memory, completion in
      let request = try memory.read(at: chain.descriptors[0].address, byteCount: 4)
      #expect(request == [1, 2, 3, 4])
      completions.append(completion)
    }

    try function.transport.writeBAR(offset: 0x08, bytes: littleEndian(UInt32(1)))
    try function.transport.writeBAR(offset: 0x0C, bytes: littleEndian(UInt32(1)))
    try function.transport.writeBAR(offset: 0x14, bytes: [0x0F])
    try function.transport.writeBAR(offset: 0x16, bytes: littleEndian(UInt16(0)))
    try function.transport.writeBAR(offset: 0x18, bytes: littleEndian(UInt16(8)))
    try function.transport.writeBAR(offset: 0x20, bytes: littleEndian(UInt64(0x1000)))
    try function.transport.writeBAR(offset: 0x28, bytes: littleEndian(UInt64(0x2000)))
    try function.transport.writeBAR(offset: 0x30, bytes: littleEndian(UInt64(0x3000)))
    try function.transport.writeBAR(offset: 0x1C, bytes: littleEndian(UInt16(1)))

    try memory.write(
      at: 0x1000,
      bytes: littleEndian(UInt64(0x4000)) + littleEndian(UInt32(4))
        + littleEndian(UInt16(1)) + littleEndian(UInt16(1))
        + littleEndian(UInt64(0x5000)) + littleEndian(UInt32(4))
        + littleEndian(UInt16(2)) + littleEndian(UInt16(0))
    )
    try memory.write(at: 0x4000, bytes: [1, 2, 3, 4])
    try memory.write(at: 0x5000, bytes: [0, 0, 0, 0])
    try memory.write(at: 0x2000, bytes: [0, 0, 1, 0, 0, 0])
    memory.armBlockedWrite()

    try function.transport.writeBAR(offset: 0x100, bytes: littleEndian(UInt16(0)))
    let completion = try #require(completions.removeFirst())

    let completionResult = LockedValue<Bool?>(nil)
    let completionDone = DispatchSemaphore(value: 0)
    let completionThread = Thread {
      completionResult.value = completion.publish([9, 8, 7])
      completionDone.signal()
    }
    completionThread.start()
    #expect(memory.waitForBlockedWrite(timeout: 1))

    let resetResult = LockedValue<Result<Void, Error>?>(nil)
    let resetDone = DispatchSemaphore(value: 0)
    let resetThread = Thread {
      do {
        try function.transport.writeBAR(offset: 0x14, bytes: [0])
        resetResult.value = .success(())
      } catch {
        resetResult.value = .failure(error)
      }
      resetDone.signal()
    }
    resetThread.start()

    #expect(resetDone.wait(timeout: .now() + 0.2) == .timedOut)
    memory.releaseBlockedWrite()
    #expect(completionDone.wait(timeout: .now() + 1) == .success)
    #expect(resetDone.wait(timeout: .now() + 1) == .success)
    #expect(completionResult.value == true)
    if case .failure(let error) = resetResult.value { throw error }
    #expect(try memory.read(at: 0x5000, byteCount: 4) == [9, 8, 7, 0])
    #expect(!(try function.transport.queueSnapshot(at: 0).enabled))
  }

  private func configureSingleDescriptorQueue(
    _ machine: DoryPCDirectKernelMachine,
    bar: UInt64
  ) throws {
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

  private func publishDeferredDescriptor(
    _ machine: DoryPCDirectKernelMachine,
    bar: UInt64,
    availableIndex: UInt16
  ) throws {
    try machine.physicalMemory.write(
      at: 0x1000,
      bytes: littleEndian(UInt64(0x4000)) + littleEndian(UInt32(4))
        + littleEndian(UInt16(1)) + littleEndian(UInt16(1))
        + littleEndian(UInt64(0x5000)) + littleEndian(UInt32(4))
        + littleEndian(UInt16(2)) + littleEndian(UInt16(0))
    )
    try machine.physicalMemory.write(at: 0x4000, bytes: [1, 2, 3, 4])
    try machine.physicalMemory.write(at: 0x5000, bytes: [0, 0, 0, 0])
    try machine.physicalMemory.write(
      at: 0x2004 + UInt64((availableIndex - 1) % 8) * 2,
      bytes: littleEndian(UInt16(0))
    )
    try machine.physicalMemory.write(at: 0x2002, bytes: littleEndian(availableIndex))
    try write16(machine, bar + 0x100, 0)
  }

  private func makeFunction() throws -> DoryPCVirtioPCIFunction {
    try .init(
      address: .init(bus: 0, device: 1, function: 0),
      virtioDeviceID: 2,
      classCode: 0x010000,
      initialBARAddress: 0xD000_0000,
      queueCount: 2,
      offeredFeatures: [.indirectDescriptors, .eventIndex],
      deviceConfiguration: [UInt8](repeating: 0, count: 64)
    )
  }

  private func read8(_ machine: DoryPCDirectKernelMachine, _ address: UInt64) throws -> UInt8 {
    try machine.physicalMemory.read(at: address, byteCount: 1)[0]
  }

  private func read32(_ machine: DoryPCDirectKernelMachine, _ address: UInt64) throws -> UInt32 {
    uint32(try machine.physicalMemory.read(at: address, byteCount: 4))
  }

  private func read16(_ machine: DoryPCDirectKernelMachine, _ address: UInt64) throws -> UInt16 {
    let bytes = try machine.physicalMemory.read(at: address, byteCount: 2)
    return UInt16(bytes[0]) | UInt16(bytes[1]) << 8
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

  private func writeMSIXEntry(
    _ machine: DoryPCDirectKernelMachine,
    at address: UInt64,
    vector: UInt32
  ) throws {
    try machine.physicalMemory.write(
      at: address,
      bytes: littleEndian(UInt64(0xFEE0_0000))
        + littleEndian(vector)
        + littleEndian(UInt32(0))
    )
  }
}

private final class LockedQueueNotifications: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [UInt16] = []
  var values: [UInt16] { lock.withLock { storage } }
  func append(_ value: UInt16) { lock.withLock { storage.append(value) } }
}

private final class DeferredCompletionRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [DoryPCVirtioPCIDeferredCompletion] = []
  func append(_ completion: DoryPCVirtioPCIDeferredCompletion) {
    lock.withLock { storage.append(completion) }
  }
  func removeFirst() -> DoryPCVirtioPCIDeferredCompletion? {
    lock.withLock { storage.isEmpty ? nil : storage.removeFirst() }
  }
}

private func uint32(_ bytes: [UInt8]) -> UInt32 {
  bytes.enumerated().reduce(0) { $0 | UInt32($1.element) << UInt32($1.offset * 8) }
}

private func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
  (0..<MemoryLayout<T>.size).map { UInt8(truncatingIfNeeded: value >> T($0 * 8)) }
}

private final class LockedValue<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: Value

  init(_ value: Value) { storage = value }

  var value: Value {
    get { lock.withLock { storage } }
    set { lock.withLock { storage = newValue } }
  }
}

private final class BlockingVirtioGuestMemory: DoryVirtioGuestMemory, @unchecked Sendable {
  private let lock = NSLock()
  private var bytes: [UInt8]
  private let blockedWriteAddress: UInt64
  private let blockedWriteStarted = DispatchSemaphore(value: 0)
  private let blockedWriteRelease = DispatchSemaphore(value: 0)
  private var shouldBlockWrite = false

  init(byteCount: Int, blockedWriteAddress: UInt64) {
    bytes = [UInt8](repeating: 0, count: byteCount)
    self.blockedWriteAddress = blockedWriteAddress
  }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    try validate(at: address, byteCount: byteCount, deviceWillWrite: false)
    return lock.withLock {
      let offset = Int(address)
      return Array(bytes[offset..<(offset + byteCount)])
    }
  }

  func validate(at address: UInt64, byteCount: Int, deviceWillWrite: Bool) throws {
    let (_, overflow) = address.addingReportingOverflow(UInt64(byteCount))
    guard byteCount >= 0, !overflow, address + UInt64(byteCount) <= UInt64(bytes.count) else {
      throw DoryVirtioQueueError.guestAddressOverflow(address: address, offset: UInt64(byteCount))
    }
  }

  func write(at address: UInt64, bytes newBytes: [UInt8]) throws {
    try validate(at: address, byteCount: newBytes.count, deviceWillWrite: true)
    let shouldBlock = lock.withLock { () -> Bool in
      guard address == blockedWriteAddress, shouldBlockWrite else { return false }
      shouldBlockWrite = false
      return true
    }
    if shouldBlock {
      blockedWriteStarted.signal()
      blockedWriteRelease.wait()
    }
    lock.withLock {
      let offset = Int(address)
      bytes.replaceSubrange(offset..<(offset + newBytes.count), with: newBytes)
    }
  }

  func synchronize() {}

  func armBlockedWrite() {
    lock.withLock { shouldBlockWrite = true }
  }

  func waitForBlockedWrite(timeout: TimeInterval) -> Bool {
    blockedWriteStarted.wait(timeout: .now() + timeout) == .success
  }

  func releaseBlockedWrite() { blockedWriteRelease.signal() }
}
