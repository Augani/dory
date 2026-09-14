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

  @Test(arguments: [false, true])
  func deviceNeedsResetPreventsNotifyFromConsumingNewQueueWork(deferred: Bool) throws {
    let function = try makeFunction()
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      pciFunctions: [function]
    )
    let memory = TrackingVirtioGuestMemory(machine.physicalMemory)
    let processorCalls = LockedValue(0)
    if deferred {
      function.transport.connectDeferredQueueProcessor(memory: memory) { _, _, _, completion in
        processorCalls.value += 1
        completion.publish([9, 8, 7, 6])
      }
    } else {
      function.transport.connectQueueProcessor(memory: memory) { _, chain, memory in
        processorCalls.value += 1
        try memory.write(at: chain.descriptors[1].address, bytes: [9, 8, 7, 6])
        return 4
      }
    }
    try function.writeConfiguration(offset: 4, bytes: [2, 0])
    let bar: UInt64 = 0xD000_0000
    try configureSingleDescriptorQueue(machine, bar: bar)

    function.transport.deviceState.markDeviceNeedsReset()
    #expect(function.transport.deviceState.snapshot().status.contains(.driverOK))
    #expect(function.transport.deviceState.snapshot().status.contains(.deviceNeedsReset))
    try publishDeferredDescriptor(machine, bar: bar, availableIndex: 1, notify: false)
    let usedRing = try machine.physicalMemory.read(at: 0x3000, byteCount: 70)
    let accesses = memory.accessCount
    try write16(machine, bar + 0x100, 0)
    function.transport.processQueue(0)

    // Reasserting readiness and queue enable cannot clear the device-owned error bit.
    try write8(machine, bar + 0x14, 0x0F)
    try write16(machine, bar + 0x1C, 1)
    try write16(machine, bar + 0x100, 0)

    #expect(memory.accessCount == accesses)
    #expect(processorCalls.value == 0)
    #expect(function.transport.deviceState.snapshot().status.contains(.deviceNeedsReset))
    #expect(try machine.physicalMemory.read(at: 0x5000, byteCount: 4) == [0, 0, 0, 0])
    #expect(try machine.physicalMemory.read(at: 0x3000, byteCount: 70) == usedRing)
  }

  @Test func deviceNeedsResetRejectsCapturedDeferredCompletionBeforeGuestWrites() throws {
    let function = try makeFunction()
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      pciFunctions: [function]
    )
    let memory = TrackingVirtioGuestMemory(machine.physicalMemory)
    let completions = DeferredCompletionRecorder()
    function.transport.connectDeferredQueueProcessor(memory: memory) {
      _, _, _, completion in
      completions.append(completion)
    }
    try function.writeConfiguration(offset: 4, bytes: [2, 0])
    let bar: UInt64 = 0xD000_0000
    try configureSingleDescriptorQueue(machine, bar: bar)
    try publishDeferredDescriptor(machine, bar: bar, availableIndex: 1)
    let completion = try #require(completions.removeFirst())

    function.transport.deviceState.markDeviceNeedsReset()
    #expect(function.transport.deviceState.snapshot().status.contains(.driverOK))
    #expect(function.transport.deviceState.snapshot().status.contains(.deviceNeedsReset))
    let usedRing = try machine.physicalMemory.read(at: 0x3000, byteCount: 70)
    let accesses = memory.accessCount
    #expect(!completion.publish([9, 8, 7, 6]))
    #expect(memory.accessCount == accesses)
    #expect(try machine.physicalMemory.read(at: 0x5000, byteCount: 4) == [0, 0, 0, 0])
    #expect(try machine.physicalMemory.read(at: 0x3000, byteCount: 70) == usedRing)
  }

  @Test func resetAndReconfigurationAllowOneDeferredCompletionInFreshGeneration() throws {
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
    let staleCompletion = try #require(completions.removeFirst())
    function.transport.deviceState.markDeviceNeedsReset()

    try write8(machine, bar + 0x14, 0)
    #expect(function.transport.deviceState.snapshot().status.isEmpty)
    #expect(!(try function.transport.queueSnapshot(at: 0).enabled))
    try write16(machine, bar + 0x100, 0)
    #expect(completions.removeFirst() == nil)
    try configureSingleDescriptorQueue(machine, bar: bar)
    #expect(function.transport.deviceState.snapshot().status.contains(.driverOK))
    #expect(!function.transport.deviceState.snapshot().status.contains(.deviceNeedsReset))
    try publishDeferredDescriptor(machine, bar: bar, availableIndex: 1)
    let completion = try #require(completions.removeFirst())

    #expect(!staleCompletion.publish([5, 5, 5, 5]))
    #expect(try machine.physicalMemory.read(at: 0x5000, byteCount: 4) == [0, 0, 0, 0])
    #expect(try read16(machine, 0x3002) == 0)
    #expect(completion.publish([9, 8, 7, 6]))
    #expect(!completion.publish([5, 5, 5, 5]))
    try write16(machine, bar + 0x100, 0)
    function.transport.processQueue(0)
    #expect(completions.removeFirst() == nil)
    #expect(try machine.physicalMemory.read(at: 0x5000, byteCount: 4) == [9, 8, 7, 6])
    #expect(try read16(machine, 0x3002) == 1)
  }

  @Test func deferredProcessorPublishingSynchronouslyCompletesWithoutDeadlock() throws {
    let function = try makeFunction()
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      pciFunctions: [function]
    )
    function.transport.connectDeferredQueueProcessor(memory: machine.physicalMemory) {
      _, chain, memory, completion in
      let request = try memory.read(at: chain.descriptors[0].address, byteCount: 4)
      #expect(request == [1, 2, 3, 4])
      #expect(completion.publish([9, 8, 7, 6]))
    }
    try function.writeConfiguration(offset: 4, bytes: [2, 0])
    let bar: UInt64 = 0xD000_0000
    try configureSingleDescriptorQueue(machine, bar: bar)
    try publishDeferredDescriptor(machine, bar: bar, availableIndex: 1, notify: false)

    // Run the kick on a bounded worker so a reintroduced lifecycle
    // re-entrancy deadlock fails the test instead of hanging the suite.
    let kickResult = LockedValue<Result<Void, Error>?>(nil)
    let kickDone = DispatchSemaphore(value: 0)
    let kickThread = Thread {
      do {
        try function.transport.writeBAR(offset: 0x100, bytes: littleEndian(UInt16(0)))
        kickResult.value = .success(())
      } catch {
        kickResult.value = .failure(error)
      }
      kickDone.signal()
    }
    kickThread.start()
    #expect(kickDone.wait(timeout: .now() + 2) == .success)
    if case .failure(let error) = kickResult.value { throw error }
    #expect(kickResult.value != nil)
    #expect(try machine.physicalMemory.read(at: 0x5000, byteCount: 4) == [9, 8, 7, 6])
    #expect(try read16(machine, 0x3002) == 1)
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

  @Test func staleEpochCannotMarkFreshLifecycleAfterZeroStatusReset() throws {
    let function = try makeFunction()
    let state = function.transport.deviceState
    let staleEpoch = state.snapshot().lifecycleEpoch

    // A zero-status reset linearizes a fresh lifecycle with no NEEDS_RESET.
    state.writeStatus([])
    let freshEpoch = state.snapshot().lifecycleEpoch
    #expect(freshEpoch != staleEpoch)
    #expect(!state.snapshot().status.contains(.deviceNeedsReset))

    // The stale epoch must not poison the fresh lifecycle.
    #expect(state.markDeviceNeedsReset(expectedLifecycleEpoch: staleEpoch) == false)
    #expect(!state.snapshot().status.contains(.deviceNeedsReset))
    #expect(state.snapshot().lifecycleEpoch == freshEpoch)

    // The current lifecycle still transitions exactly once.
    #expect(state.markDeviceNeedsReset(expectedLifecycleEpoch: freshEpoch) == true)
    #expect(state.snapshot().status.contains(.deviceNeedsReset))
    #expect(state.markDeviceNeedsReset(expectedLifecycleEpoch: freshEpoch) == false)
    #expect(state.markDeviceNeedsReset() == false)
  }

  @Test func sameLifecycleConditionalMarkSurvivesConfigurationDidChange() throws {
    let function = try makeFunction()
    let state = function.transport.deviceState
    let epoch = state.snapshot().lifecycleEpoch
    let generationBefore = state.snapshot().configurationGeneration

    // Ordinary configuration changes never advance the lifecycle epoch.
    state.configurationDidChange()
    state.configurationDidChange()
    state.configurationDidChange()
    #expect(state.snapshot().lifecycleEpoch == epoch)
    #expect(state.snapshot().configurationGeneration != generationBefore)
    #expect(!state.snapshot().status.contains(.deviceNeedsReset))

    // A same-lifecycle conditional mark still succeeds exactly once.
    #expect(state.markDeviceNeedsReset(expectedLifecycleEpoch: epoch) == true)
    #expect(state.snapshot().status.contains(.deviceNeedsReset))
    #expect(state.markDeviceNeedsReset(expectedLifecycleEpoch: epoch) == false)
    #expect(state.markDeviceNeedsReset() == false)
  }

  @Test func staleEpochCannotMarkAfterGenerationWrapAndReset() throws {
    let function = try makeFunction()
    let state = function.transport.deviceState
    let staleEpoch = state.snapshot().lifecycleEpoch

    // Many visible generation changes wrap the UInt8 guest counter without
    // changing the lifecycle identity.
    for _ in 0..<300 { state.configurationDidChange() }
    #expect(state.snapshot().lifecycleEpoch == staleEpoch)
    #expect(!state.snapshot().status.contains(.deviceNeedsReset))

    // A zero-status reset opens a fresh lifecycle.
    state.writeStatus([])
    let freshEpoch = state.snapshot().lifecycleEpoch
    #expect(freshEpoch != staleEpoch)
    #expect(!state.snapshot().status.contains(.deviceNeedsReset))

    // The stale epoch cannot poison the fresh lifecycle even though the
    // visible counter has wrapped.
    #expect(state.markDeviceNeedsReset(expectedLifecycleEpoch: staleEpoch) == false)
    #expect(!state.snapshot().status.contains(.deviceNeedsReset))
    #expect(state.snapshot().lifecycleEpoch == freshEpoch)

    // The fresh lifecycle still transitions exactly once.
    #expect(state.markDeviceNeedsReset(expectedLifecycleEpoch: freshEpoch) == true)
    #expect(state.snapshot().status.contains(.deviceNeedsReset))
  }

  @Test func staleDeferredTerminalAfterResetLeavesFreshLifecycleUnpoisoned() throws {
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
    let configurationSignals = LockedValue(0)
    function.transport.connectInterruptSink { interrupt in
      if interrupt == .configuration { configurationSignals.value += 1 }
      return true
    }
    try function.writeConfiguration(offset: 4, bytes: [2, 0])
    let bar: UInt64 = 0xD000_0000
    try configureSingleDescriptorQueue(machine, bar: bar)
    try publishDeferredDescriptor(machine, bar: bar, availableIndex: 1)
    let staleCompletion = try #require(completions.removeFirst())

    // Zero-status reset linearizes a fresh lifecycle before the old deferred
    // terminal outcome is delivered. No threads or sleeps are involved: the
    // stale completion object itself carries the old lifecycle epoch.
    try function.transport.writeBAR(offset: 0x14, bytes: [0])
    #expect(!function.transport.deviceState.snapshot().status.contains(.deviceNeedsReset))
    let freshEpoch = function.transport.deviceState.snapshot().lifecycleEpoch

    // A stale deferred terminal failure must not poison the fresh lifecycle
    // nor manufacture a configuration-change signal.
    #expect(!staleCompletion.failDevice())
    #expect(!function.transport.deviceState.snapshot().status.contains(.deviceNeedsReset))
    #expect(function.transport.deviceState.snapshot().lifecycleEpoch == freshEpoch)
    #expect(configurationSignals.value == 0)
    #expect(try machine.physicalMemory.read(at: 0x5000, byteCount: 4) == [0, 0, 0, 0])
    #expect(try read16(machine, 0x3002) == 0)

    // The fresh lifecycle still signals a current terminal failure exactly once.
    try configureSingleDescriptorQueue(machine, bar: bar)
    try publishDeferredDescriptor(machine, bar: bar, availableIndex: 1)
    let freshCompletion = try #require(completions.removeFirst())
    #expect(freshCompletion.failDevice())
    #expect(function.transport.deviceState.snapshot().status.contains(.deviceNeedsReset))
    #expect(configurationSignals.value == 1)
    #expect(!freshCompletion.publish([9, 8, 7]))
    #expect(configurationSignals.value == 1)
  }

  @Test func staleDeferredAfterConfigChangesAndResetLeavesFreshLifecycleUnpoisoned() throws {
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
    let staleCompletion = try #require(completions.removeFirst())

    // Ordinary configuration changes do not open a new lifecycle, then a
    // zero-status reset does. No threads or sleeps are involved.
    for _ in 0..<10 { function.transport.deviceState.configurationDidChange() }
    try function.transport.writeBAR(offset: 0x14, bytes: [0])
    #expect(!function.transport.deviceState.snapshot().status.contains(.deviceNeedsReset))
    let freshEpoch = function.transport.deviceState.snapshot().lifecycleEpoch

    #expect(!staleCompletion.failDevice())
    #expect(!function.transport.deviceState.snapshot().status.contains(.deviceNeedsReset))
    #expect(function.transport.deviceState.snapshot().lifecycleEpoch == freshEpoch)

    // The fresh lifecycle still fails exactly once.
    try configureSingleDescriptorQueue(machine, bar: bar)
    try publishDeferredDescriptor(machine, bar: bar, availableIndex: 1)
    let freshCompletion = try #require(completions.removeFirst())
    #expect(freshCompletion.failDevice())
    #expect(function.transport.deviceState.snapshot().status.contains(.deviceNeedsReset))
  }

  @Test func staleDeferredPopEpochRejectedAfterResetWithoutGenerationChange() throws {
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
    let configurationSignals = LockedValue(0)
    function.transport.connectInterruptSink { interrupt in
      if interrupt == .configuration { configurationSignals.value += 1 }
      return true
    }
    try function.writeConfiguration(offset: 4, bytes: [2, 0])
    let bar: UInt64 = 0xD000_0000
    try configureSingleDescriptorQueue(machine, bar: bar)
    try publishDeferredDescriptor(machine, bar: bar, availableIndex: 1, descriptorIndex: 0)
    let stalePublish = try #require(completions.removeFirst())
    // Do not reuse the still-deferred head: modern virtio queue validation
    // rejects descriptor reuse while a completion remains outstanding.
    try publishDeferredDescriptor(machine, bar: bar, availableIndex: 2, descriptorIndex: 2)
    let staleFail = try #require(completions.removeFirst())
    #expect(try function.transport.queueSnapshot(at: 0).enabled)
    let staleEpoch = function.transport.deviceState.snapshot().lifecycleEpoch
    #expect(function.transport.deviceState.snapshot().status.contains(.driverOK))

    // Device-state status-zero reset opens a fresh lifecycle epoch without
    // touching queue registers, so the queue generation stays active. No
    // threads or sleeps are involved.
    function.transport.deviceState.writeStatus([])
    let freshEpoch = function.transport.deviceState.snapshot().lifecycleEpoch
    #expect(freshEpoch != staleEpoch)
    #expect(!function.transport.deviceState.snapshot().status.contains(.deviceNeedsReset))
    #expect(try function.transport.queueSnapshot(at: 0).enabled)

    // Re-negotiate status without touching queue registers.
    try write32(machine, bar + 0x08, 1)
    try write32(machine, bar + 0x0C, 1)
    try write8(machine, bar + 0x14, 0x0F)
    #expect(function.transport.deviceState.snapshot().lifecycleEpoch == freshEpoch)
    #expect(function.transport.deviceState.snapshot().status.contains(.driverOK))
    #expect(!function.transport.deviceState.snapshot().status.contains(.deviceNeedsReset))
    #expect(try function.transport.queueSnapshot(at: 0).enabled)

    // A stale pop-epoch publish performs no DMA, no used completion, and no
    // NEEDS_RESET signal even though the queue generation never changed.
    #expect(!stalePublish.publish([9, 8, 7, 6]))
    #expect(try machine.physicalMemory.read(at: 0x5000, byteCount: 4) == [0, 0, 0, 0])
    #expect(try read16(machine, 0x3002) == 0)
    #expect(!function.transport.deviceState.snapshot().status.contains(.deviceNeedsReset))
    #expect(function.transport.deviceState.snapshot().lifecycleEpoch == freshEpoch)
    #expect(configurationSignals.value == 0)

    // A stale pop-epoch terminal failure is rejected just as silently.
    #expect(!staleFail.failDevice())
    #expect(!function.transport.deviceState.snapshot().status.contains(.deviceNeedsReset))
    #expect(function.transport.deviceState.snapshot().lifecycleEpoch == freshEpoch)
    #expect(configurationSignals.value == 0)
    #expect(try machine.physicalMemory.read(at: 0x5000, byteCount: 4) == [0, 0, 0, 0])
    #expect(try read16(machine, 0x3002) == 0)

    // The fresh lifecycle still publishes exactly once.
    try publishDeferredDescriptor(machine, bar: bar, availableIndex: 3, descriptorIndex: 4)
    let freshCompletion = try #require(completions.removeFirst())
    #expect(freshCompletion.publish([9, 8, 7, 6]))
    #expect(try machine.physicalMemory.read(at: 0x5000, byteCount: 4) == [9, 8, 7, 6])
    #expect(try read16(machine, 0x3002) == 1)
    #expect(!function.transport.deviceState.snapshot().status.contains(.deviceNeedsReset))
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

  @Test func needsResetSerializesWithDrainAndRejectsLaterQueueWork() throws {
    let function = try makeFunction()
    let memory = BlockingVirtioGuestMemory(byteCount: 0x20_000, blockedWriteAddress: 0x5000)
    let processorCalls = LockedValue(0)
    function.transport.connectQueueProcessor(memory: memory) { _, chain, memory in
      processorCalls.value += 1
      try memory.write(at: chain.descriptors[1].address, bytes: [9, 8, 7, 6])
      return 4
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

    let drainResult = LockedValue<Result<Void, Error>?>(nil)
    let drainDone = DispatchSemaphore(value: 0)
    let drainThread = Thread {
      do {
        try function.transport.writeBAR(offset: 0x100, bytes: littleEndian(UInt16(0)))
        drainResult.value = .success(())
      } catch {
        drainResult.value = .failure(error)
      }
      drainDone.signal()
    }
    drainThread.start()
    #expect(memory.waitForBlockedWrite(timeout: 1))

    let resetStarted = DispatchSemaphore(value: 0)
    let resetDone = DispatchSemaphore(value: 0)
    let resetThread = Thread {
      resetStarted.signal()
      function.transport.deviceState.markDeviceNeedsReset()
      resetDone.signal()
    }
    resetThread.start()
    #expect(resetStarted.wait(timeout: .now() + 1) == .success)
    #expect(resetDone.wait(timeout: .now() + 0.2) == .timedOut)

    memory.releaseBlockedWrite()
    #expect(drainDone.wait(timeout: .now() + 1) == .success)
    #expect(resetDone.wait(timeout: .now() + 1) == .success)
    if case .failure(let error) = drainResult.value { throw error }
    #expect(try memory.read(at: 0x5000, byteCount: 4) == [9, 8, 7, 6])
    #expect(try readUsedIndex(memory) == 1)

    // A later kick observes NEEDS_RESET before it can touch either the response
    // buffer or the used ring.
    try memory.write(at: 0x5000, bytes: [0, 0, 0, 0])
    try memory.write(at: 0x2006, bytes: littleEndian(UInt16(0)))
    try memory.write(at: 0x2002, bytes: littleEndian(UInt16(2)))
    try function.transport.writeBAR(offset: 0x100, bytes: littleEndian(UInt16(0)))
    #expect(processorCalls.value == 1)
    #expect(try memory.read(at: 0x5000, byteCount: 4) == [0, 0, 0, 0])
    #expect(try readUsedIndex(memory) == 1)
  }

  @Test func deferredCompletionPreflightLeavesEarlyTargetUntouchedWhenLaterTargetIsRevoked()
    throws
  {
    let function = try makeFunction()
    let memory = RevokingVirtioGuestMemory(byteCount: 0x20_000)
    let completions = DeferredCompletionRecorder()
    function.transport.connectDeferredQueueProcessor(memory: memory) { _, _, _, completion in
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

    // Chain head 0: a readable request at 0x4000 followed by two writable
    // response targets, early at 0x5000 and later at 0x6000. Every target
    // validates when the chain is popped.
    try memory.write(
      at: 0x1000,
      bytes: littleEndian(UInt64(0x4000)) + littleEndian(UInt32(4))
        + littleEndian(UInt16(1)) + littleEndian(UInt16(1))
        + littleEndian(UInt64(0x5000)) + littleEndian(UInt32(4))
        + littleEndian(UInt16(3)) + littleEndian(UInt16(2))
        + littleEndian(UInt64(0x6000)) + littleEndian(UInt32(4))
        + littleEndian(UInt16(2)) + littleEndian(UInt16(0))
    )
    try memory.write(at: 0x4000, bytes: [1, 2, 3, 4])
    try memory.write(at: 0x5000, bytes: [0, 0, 0, 0])
    try memory.write(at: 0x6000, bytes: [0, 0, 0, 0])
    try memory.write(at: 0x2004, bytes: littleEndian(UInt16(0)))
    try memory.write(at: 0x2002, bytes: littleEndian(UInt16(1)))
    try function.transport.writeBAR(offset: 0x100, bytes: littleEndian(UInt16(0)))
    let failed = try #require(completions.removeFirst())
    #expect(!function.transport.deviceState.snapshot().status.contains(.deviceNeedsReset))

    // Revoke the later writable target only after the chain was popped. The
    // early target stays valid; only the later target is now unmapped for writes.
    memory.revokeWrite(at: 0x6000, byteCount: 4)

    // A response spanning both writable targets must publish nothing: the early
    // target is untouched and the used ring stays uncompleted, with no reset.
    #expect(!failed.publish([9, 8, 7, 6, 5, 4, 3, 2]))
    #expect(try memory.read(at: 0x5000, byteCount: 4) == [0, 0, 0, 0])
    #expect(try memory.read(at: 0x6000, byteCount: 4) == [0, 0, 0, 0])
    #expect(try readUsedIndex(memory) == 0)
    #expect(!function.transport.deviceState.snapshot().status.contains(.deviceNeedsReset))

    // A valid retry/control path on the same queue still publishes exactly once.
    try memory.write(
      at: 0x1010,
      bytes: littleEndian(UInt64(0x4000)) + littleEndian(UInt32(4))
        + littleEndian(UInt16(1)) + littleEndian(UInt16(3))
    )
    try memory.write(
      at: 0x1030,
      bytes: littleEndian(UInt64(0x5000)) + littleEndian(UInt32(4))
        + littleEndian(UInt16(2)) + littleEndian(UInt16(0))
    )
    try memory.write(at: 0x2006, bytes: littleEndian(UInt16(1)))
    try memory.write(at: 0x2002, bytes: littleEndian(UInt16(2)))
    try function.transport.writeBAR(offset: 0x100, bytes: littleEndian(UInt16(0)))
    let retry = try #require(completions.removeFirst())
    #expect(retry.publish([9, 8, 7, 6]))
    #expect(try memory.read(at: 0x5000, byteCount: 4) == [9, 8, 7, 6])
    #expect(try readUsedIndex(memory) == 1)
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
    availableIndex: UInt16,
    descriptorIndex: UInt16 = 0,
    notify: Bool = true
  ) throws {
    let responseDescriptorIndex = descriptorIndex + 1
    try machine.physicalMemory.write(
      at: 0x1000 + UInt64(descriptorIndex) * 16,
      bytes: littleEndian(UInt64(0x4000)) + littleEndian(UInt32(4))
        + littleEndian(UInt16(1)) + littleEndian(responseDescriptorIndex)
        + littleEndian(UInt64(0x5000)) + littleEndian(UInt32(4))
        + littleEndian(UInt16(2)) + littleEndian(UInt16(0))
    )
    try machine.physicalMemory.write(at: 0x4000, bytes: [1, 2, 3, 4])
    try machine.physicalMemory.write(at: 0x5000, bytes: [0, 0, 0, 0])
    try machine.physicalMemory.write(
      at: 0x2004 + UInt64((availableIndex - 1) % 8) * 2,
      bytes: littleEndian(descriptorIndex)
    )
    try machine.physicalMemory.write(at: 0x2002, bytes: littleEndian(availableIndex))
    if notify { try write16(machine, bar + 0x100, 0) }
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

  private func readUsedIndex(_ memory: any DoryVirtioGuestMemory) throws -> UInt16 {
    let bytes = try memory.read(at: 0x3002, byteCount: 2)
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

/// Counts transport accesses while fixture setup and assertions use the backing memory directly.
private final class TrackingVirtioGuestMemory: DoryVirtioGuestMemory, @unchecked Sendable {
  private let backing: any DoryVirtioGuestMemory
  private let lock = NSLock()
  private var accesses = 0

  init(_ backing: any DoryVirtioGuestMemory) { self.backing = backing }

  var accessCount: Int { lock.withLock { accesses } }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    lock.withLock { accesses += 1 }
    return try backing.read(at: address, byteCount: byteCount)
  }

  func validate(at address: UInt64, byteCount: Int, deviceWillWrite: Bool) throws {
    lock.withLock { accesses += 1 }
    try backing.validate(at: address, byteCount: byteCount, deviceWillWrite: deviceWillWrite)
  }

  func write(at address: UInt64, bytes: [UInt8]) throws {
    lock.withLock { accesses += 1 }
    try backing.write(at: address, bytes: bytes)
  }

  func synchronize() {
    lock.withLock { accesses += 1 }
    backing.synchronize()
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

/// A guest-memory backing that can revoke a writable target after a chain has
/// been popped, simulating a mapping revocation between pop and deferred
/// completion. Reads always succeed; only device-writes into a revoked range
/// fail validation.
private final class RevokingVirtioGuestMemory: DoryVirtioGuestMemory, @unchecked Sendable {
  private let lock = NSLock()
  private var bytes: [UInt8]
  private var revokedWriteRanges: [(address: UInt64, byteCount: Int)] = []

  init(byteCount: Int) {
    bytes = .init(repeating: 0, count: byteCount)
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
    guard deviceWillWrite else { return }
    for range in revokedWriteRanges {
      if address < range.address + UInt64(range.byteCount),
        address + UInt64(byteCount) > range.address
      {
        throw DoryVirtioQueueError.guestAddressOverflow(address: address, offset: UInt64(byteCount))
      }
    }
  }

  func write(at address: UInt64, bytes newBytes: [UInt8]) throws {
    try validate(at: address, byteCount: newBytes.count, deviceWillWrite: true)
    lock.withLock {
      let offset = Int(address)
      bytes.replaceSubrange(offset..<(offset + newBytes.count), with: newBytes)
    }
  }

  func synchronize() {}

  func revokeWrite(at address: UInt64, byteCount: Int) {
    lock.withLock { revokedWriteRanges.append((address, byteCount)) }
  }
}
